import Foundation
import Combine
import QuotaBackend
import os.log

internal let accountPersistenceLog = Logger(subsystem: "com.aiusage.desktop", category: "AccountPersistence")

/// Single source of truth for account identity / dedup rules.
///
/// Provider-native accounts cannot always be identified by email: Codex uses a
/// workspace + user tuple, while Antigravity uses project + email. Registry
/// identity for Codex prefers **accountId + userId** (then accountId + email),
/// matching `AccountCredentialStore` / `ProviderEngine`. Path is only a fallback
/// when native components are incomplete — otherwise AuthImports copies of the
/// same `~/.codex/auth.json` become duplicate dashboard cards. Providers without
/// native multi-account identity keep the prior account/email fallback.
///
/// All matching and dedup logic lives here so the `AccountRegistryRefreshSnapshot`
/// (reconcile worker) and `AccountStore` extensions can share exactly one
/// implementation — the two used to be hand-kept in sync and were drifting.
nonisolated enum AccountIdentityPolicy {
    /// Delegates to the QuotaBackend definition so the credential store,
    /// provider engine, and app-side policy all agree on which providers
    /// are multi-workspace without three copies drifting out of sync.
    static var multiWorkspaceProviders: Set<String> {
        AccountCredentialStore.multiWorkspaceProviders
    }

    static func isMultiWorkspace(_ providerId: String) -> Bool {
        AccountCredentialStore.isMultiWorkspace(providerId)
    }

    // MARK: - Normalization

    static func normalizedLookupValue(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    static func extractCredentialId(from providerDataId: String) -> String? {
        guard let range = providerDataId.range(of: ":cred:") else { return nil }
        return String(providerDataId[range.upperBound...]).nilIfBlank
    }

    static func normalizedLiveAccountID(for provider: ProviderData) -> String? {
        normalizedLookupValue(provider.accountId)
    }

    static func normalizedAccountIdentifier(for provider: ProviderData) -> String? {
        normalizedLookupValue(provider.accountLabel)
    }

    static func normalizedSourceFilePath(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        return AccountCredentialStore.normalizedAuthFilePath(path)
    }

    static func sourceFilePathsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let a = normalizedSourceFilePath(lhs),
              let b = normalizedSourceFilePath(rhs) else { return false }
        return a == b
    }

    /// Codex 绑定实际托管副本；原始 sourcePath 是可切换账号的共享入口，不能作为绑定身份。
    /// 其他 Provider 保持原有路径策略。
    static func credentialAuthFilePath(_ credential: AccountCredential) -> String? {
        guard credential.authMethod == .authFile else { return nil }
        if credential.providerId == "codex" { return credential.credential.nilIfBlank }
        return credential.metadata["sourcePath"]?.nilIfBlank
            ?? credential.credential.nilIfBlank
    }

    static func codexIdentity(for provider: ProviderData) -> CodexAccountIdentity {
        CodexAccountIdentity(accountId: provider.accountId, userId: provider.workspaceUserId, email: provider.accountLabel)
    }

    static func codexIdentity(
        for account: StoredProviderAccount,
        credentialLookup: [String: AccountCredential] = [:]
    ) -> CodexAccountIdentity {
        CodexAccountIdentity(
            accountId: account.accountId,
            userId: resolvedCodexUserId(for: account, credentialLookup: credentialLookup),
            email: account.email
        )
    }

    static func codexAccountsMatch(_ lhs: StoredProviderAccount, _ rhs: StoredProviderAccount) -> Bool {
        let left = codexIdentity(for: lhs)
        let right = codexIdentity(for: rhs)
        guard !left.conflicts(with: right) else { return false }
        if left.matches(right) { return true }
        if let lhsId = lhs.credentialId, let rhsId = rhs.credentialId { return lhsId == rhsId }
        return sourceFilePathsMatch(lhs.sourceFilePath, rhs.sourceFilePath)
    }

    static func liveIdentityKey(for provider: ProviderData) -> String {
        let pid = provider.baseProviderId
        if pid == "codex" {
            let fallback = extractCredentialId(from: provider.id).map { "cred:\($0.lowercased())" }
                ?? normalizedSourceFilePath(provider.sourceFilePath).map { "path:\($0)" }
                ?? "result:\(provider.id.lowercased())"
            return codexIdentity(for: provider).key(fallback: fallback)
        }
        if isMultiWorkspace(pid) {
            return normalizedSourceFilePath(provider.sourceFilePath).map { "\(pid):path:\($0)" }
                ?? "\(pid):result:\(provider.id.lowercased())"
        }
        if let accountId = normalizedLiveAccountID(for: provider) { return "\(pid):id:\(accountId)" }
        if let label = normalizedAccountIdentifier(for: provider) { return "\(pid):label:\(label)" }
        return "\(pid):result:\(provider.id.lowercased())"
    }

    static func codexLiveAccountsMatch(_ lhs: ProviderData, _ rhs: ProviderData) -> Bool {
        let left = codexIdentity(for: lhs)
        let right = codexIdentity(for: rhs)
        guard !left.conflicts(with: right) else { return false }
        if left.matches(right) { return true }
        if let lhsId = extractCredentialId(from: lhs.id), let rhsId = extractCredentialId(from: rhs.id) {
            return lhsId == rhsId
        }
        return lhs.id == rhs.id || sourceFilePathsMatch(lhs.sourceFilePath, rhs.sourceFilePath)
    }

    static func codexSubscriptionAlreadyContains(
        identity: CodexAccountIdentity,
        sourcePath: String?,
        registry: [StoredProviderAccount],
        credentialLookup: [String: AccountCredential],
        respectRemoval: Bool
    ) -> Bool {
        registry.contains { account in
            guard account.providerId == "codex", respectRemoval || !account.isHidden else { return false }
            let existing = codexIdentity(for: account, credentialLookup: credentialLookup)
            guard !existing.conflicts(with: identity) else { return false }
            return existing.matches(identity) || sourceFilePathsMatch(account.sourceFilePath, sourcePath)
        }
    }

    static func maxTimestampString(_ values: String?...) -> String? {
        values
            .compactMap { $0?.nilIfBlank }
            .max {
                (SharedFormatters.parseISO8601($0) ?? .distantPast)
                    < (SharedFormatters.parseISO8601($1) ?? .distantPast)
            }
    }

    // MARK: - Dedup key

    static func identityKey(
        for account: StoredProviderAccount,
        credentialLookup: [String: AccountCredential] = [:]
    ) -> String {
        let providerId = account.providerId.lowercased()
        if isMultiWorkspace(providerId) {
            if providerId == "codex" {
                let fallback = account.credentialId.map { "cred:\($0.lowercased())" }
                    ?? normalizedSourceFilePath(account.sourceFilePath).map { "path:\($0)" }
                    ?? "stored:\(account.id.lowercased())"
                return codexIdentity(for: account, credentialLookup: credentialLookup).key(fallback: fallback)
            }

            // Path next (same as ProviderEngine fallback): scan + credential branches.
            let resolvedPath = normalizedSourceFilePath(account.sourceFilePath)
                ?? account.credentialId.flatMap { credentialLookup[$0] }
                    .flatMap(credentialAuthFilePath)
                    .flatMap(normalizedSourceFilePath)
            if let resolvedPath {
                return "\(providerId):path:\(resolvedPath)"
            }
            if let credentialId = account.credentialId?.lowercased().nilIfBlank {
                return "\(providerId):cred:\(credentialId)"
            }
            return "\(providerId):stored:\(account.id.lowercased())"
        }
        if let accountId = account.normalizedAccountId {
            return "\(providerId):account:\(accountId)"
        }
        if !account.normalizedEmail.isEmpty {
            return "\(providerId):email:\(account.normalizedEmail)"
        }
        if let credentialId = account.credentialId?.lowercased().nilIfBlank {
            return "\(providerId):cred:\(credentialId)"
        }
        return "\(providerId):stored:\(account.id.lowercased())"
    }

    private static func resolvedCodexUserId(
        for account: StoredProviderAccount,
        credentialLookup: [String: AccountCredential]
    ) -> String? {
        if let userId = normalizedLookupValue(account.workspaceUserId) {
            return userId
        }
        guard let credentialId = account.credentialId?.nilIfBlank,
              let credential = credentialLookup[credentialId] else {
            return nil
        }
        return normalizedLookupValue(
            credential.metadata["workspaceUserId"] ?? credential.metadata["userId"]
        )
    }

    // MARK: - Preference / merge

    static func shouldPrefer(
        _ lhs: StoredProviderAccount,
        over rhs: StoredProviderAccount,
        credentialLookup: [String: AccountCredential]
    ) -> Bool {
        // Permanent-delete tombstones must win over empty rediscovered shells, but lose to
        // an explicit credential-backed re-add (same workspace imported again).
        if lhs.isPermanentlyRemoved != rhs.isPermanentlyRemoved {
            let lhsHasCredential = lhs.credentialId.flatMap { credentialLookup[$0] } != nil
            let rhsHasCredential = rhs.credentialId.flatMap { credentialLookup[$0] } != nil
            if lhs.isPermanentlyRemoved, rhsHasCredential, !rhs.isHidden { return false }
            if rhs.isPermanentlyRemoved, lhsHasCredential, !lhs.isHidden { return true }
            return lhs.isPermanentlyRemoved
        }

        if lhs.isHidden != rhs.isHidden {
            return !lhs.isHidden
        }

        let lhsHasCredential = lhs.credentialId.flatMap { credentialLookup[$0] } != nil
        let rhsHasCredential = rhs.credentialId.flatMap { credentialLookup[$0] } != nil
        if lhsHasCredential != rhsHasCredential {
            return lhsHasCredential
        }

        let lhsPathScore = canonicalAuthPathScore(lhs.sourceFilePath)
        let rhsPathScore = canonicalAuthPathScore(rhs.sourceFilePath)
        if lhsPathScore != rhsPathScore {
            return lhsPathScore > rhsPathScore
        }

        let lhsCredentialBound = extractCredentialId(from: lhs.providerResultId ?? "") != nil
        let rhsCredentialBound = extractCredentialId(from: rhs.providerResultId ?? "") != nil
        if lhsCredentialBound != rhsCredentialBound {
            return lhsCredentialBound
        }

        let lhsSeen = SharedFormatters.parseISO8601(lhs.lastSeenAt ?? "") ?? .distantPast
        let rhsSeen = SharedFormatters.parseISO8601(rhs.lastSeenAt ?? "") ?? .distantPast
        if lhsSeen != rhsSeen {
            return lhsSeen > rhsSeen
        }

        let lhsCreated = SharedFormatters.parseISO8601(lhs.createdAt) ?? .distantPast
        let rhsCreated = SharedFormatters.parseISO8601(rhs.createdAt) ?? .distantPast
        if lhsCreated != rhsCreated {
            return lhsCreated > rhsCreated
        }

        return lhs.id < rhs.id
    }

    static func merged(
        preferred: StoredProviderAccount,
        secondary: StoredProviderAccount,
        credentialLookup: [String: AccountCredential]
    ) -> StoredProviderAccount {
        var merged = preferred

        if merged.displayName?.nilIfBlank == nil {
            merged.displayName = secondary.displayName?.nilIfBlank
        }
        if merged.note?.nilIfBlank == nil {
            merged.note = secondary.note?.nilIfBlank
        }
        if merged.accountId?.nilIfBlank == nil {
            merged.accountId = secondary.accountId?.nilIfBlank
        }
        if merged.credentialId?.nilIfBlank == nil,
           let fallbackCredentialId = secondary.credentialId?.nilIfBlank,
           credentialLookup[fallbackCredentialId] != nil {
            merged.credentialId = fallbackCredentialId
        }
        if merged.providerResultId?.nilIfBlank == nil {
            merged.providerResultId = secondary.providerResultId?.nilIfBlank
        }
        if merged.sourceFilePath?.nilIfBlank == nil {
            merged.sourceFilePath = secondary.sourceFilePath?.nilIfBlank
        }
        if merged.workspaceUserId?.nilIfBlank == nil {
            merged.workspaceUserId = secondary.workspaceUserId?.nilIfBlank
        }
        // Codex 优先保留已绑定凭据的副本路径，不能再把共享 CLI 路径提升为身份锚点。
        if merged.providerId == "codex",
           let credential = merged.credentialId.flatMap({ credentialLookup[$0] }),
           let path = credentialAuthFilePath(credential) {
            merged.sourceFilePath = path
        } else if let preferredPath = preferredCanonicalAuthPath(
            merged.sourceFilePath,
            secondary.sourceFilePath
        ) {
            merged.sourceFilePath = preferredPath
        }
        merged.lastSeenAt = maxTimestampString(preferred.lastSeenAt, secondary.lastSeenAt)
        merged.isPermanentlyRemoved = preferred.providerId == "codex"
            ? preferred.isPermanentlyRemoved
            : preferred.isPermanentlyRemoved || secondary.isPermanentlyRemoved
        merged.isHidden = (preferred.isHidden && secondary.isHidden) || merged.isPermanentlyRemoved
        if merged.isPermanentlyRemoved {
            merged.credentialId = nil
            merged.note = nil
        }
        return merged
    }

    /// Prefer `~/.codex/auth.json` (or non-AuthImports paths) when merging duplicates.
    private static func preferredCanonicalAuthPath(_ lhs: String?, _ rhs: String?) -> String? {
        let left = canonicalAuthPathScore(lhs)
        let right = canonicalAuthPathScore(rhs)
        if left < 0, right < 0 { return nil }
        if left >= right { return lhs?.nilIfBlank ?? rhs?.nilIfBlank }
        return rhs?.nilIfBlank ?? lhs?.nilIfBlank
    }

    private static func canonicalAuthPathScore(_ path: String?) -> Int {
        guard let normalized = normalizedSourceFilePath(path) else { return -1 }
        if normalized.hasSuffix("/.codex/auth.json") { return 3 }
        if normalized.contains("/authimports/") { return 0 }
        return 1
    }

    // MARK: - Live matching

    static func matchesLive(stored: StoredProviderAccount, provider: ProviderData) -> Bool {
        guard stored.providerId == provider.baseProviderId else { return false }

        if stored.providerId == "codex" {
            let saved = codexIdentity(for: stored)
            let live = codexIdentity(for: provider)
            guard !saved.conflicts(with: live) else { return false }
            if saved.matches(live) { return true }
            if let savedId = stored.credentialId, let liveId = extractCredentialId(from: provider.id) {
                return savedId == liveId
            }
            return sourceFilePathsMatch(stored.sourceFilePath, provider.sourceFilePath)
        }

        if let credentialId = stored.credentialId?.nilIfBlank {
            let expectedId = "\(stored.providerId):cred:\(credentialId)"
            if provider.id.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(expectedId) == .orderedSame {
                return true
            }
        }

        if isMultiWorkspace(stored.providerId) {
            if sourceFilePathsMatch(stored.sourceFilePath, provider.sourceFilePath) {
                return true
            }
            return false
        }

        if let storedResultId = stored.normalizedProviderResultId {
            let liveId = provider.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if storedResultId == liveId {
                return true
            }
            if liveId.hasPrefix(storedResultId + ":") || storedResultId.hasPrefix(liveId + ":") {
                return true
            }
        }

        if let storedAccountId = stored.normalizedAccountId,
           let liveAccountId = normalizedLiveAccountID(for: provider) {
            if storedAccountId == liveAccountId {
                return true
            }
            return false
        }

        if let liveEmail = normalizedAccountIdentifier(for: provider),
           stored.normalizedEmail == liveEmail {
            return true
        }

        return false
    }

    // MARK: - Index lookup

    static func bestStoredAccountIndex(
        in registry: [StoredProviderAccount],
        for provider: ProviderData,
        excluding reservedStoredIDs: Set<String>,
        allowUnseenCredentialFallback: Bool
    ) -> Int? {
        if provider.baseProviderId == "codex" {
            let candidates = registry.indices.filter {
                !registry[$0].isHidden && matchesLive(stored: registry[$0], provider: provider)
            }
            let match: Int?
            if let credentialId = extractCredentialId(from: provider.id),
               let exact = candidates.first(where: { registry[$0].credentialId == credentialId }) {
                match = exact
            } else if let nativeKey = codexIdentity(for: provider).nativeKey,
               let exact = candidates.first(where: { codexIdentity(for: registry[$0]).nativeKey == nativeKey }) {
                match = exact
            } else {
                // 旧数据缺用户 ID 时，不能从多个同邮箱成员中随便选第一个。
                match = candidates.count == 1 ? candidates[0] : nil
            }
            // 已消费的精确匹配应走重复结果分支，不能退到另一个含糊候选。
            guard let match, !reservedStoredIDs.contains(registry[match].id) else { return nil }
            return match
        }
        // Step 0: credentialId — 最精确，不受 accountId 格式影响
        if let liveCredentialId = extractCredentialId(from: provider.id) {
            if let credMatch = registry.firstIndex(where: {
                !reservedStoredIDs.contains($0.id) && !$0.isHidden &&
                $0.providerId == provider.baseProviderId &&
                $0.credentialId == liveCredentialId
            }) {
                return credMatch
            }
        }

        let liveIsMultiWs = isMultiWorkspace(provider.baseProviderId)

        // Step 0.6: sourceFilePath 归一化路径匹配（仅 multi-workspace provider）
        if liveIsMultiWs {
            if let livePath = provider.sourceFilePath {
                return registry.firstIndex(where: {
                    !reservedStoredIDs.contains($0.id) && !$0.isHidden &&
                    $0.providerId == provider.baseProviderId &&
                    sourceFilePathsMatch($0.sourceFilePath, livePath)
                })
            }
            return nil
        }

        // Step 1: accountId 精确匹配
        let liveAccountId = normalizedLiveAccountID(for: provider)
        if let liveAccountId {
            if let accountIdMatch = registry.firstIndex(where: {
                guard !reservedStoredIDs.contains($0.id), !$0.isHidden,
                      $0.providerId == provider.baseProviderId,
                      $0.normalizedAccountId == liveAccountId else { return false }
                return true
            }) {
                return accountIdMatch
            }
        }

        // Step 2: providerResultId / email 模糊匹配
        if let exactIndex = registry.firstIndex(where: {
            !reservedStoredIDs.contains($0.id) && !$0.isHidden && matchesLive(stored: $0, provider: provider)
        }) {
            return exactIndex
        }

        guard allowUnseenCredentialFallback,
              extractCredentialId(from: provider.id) != nil else {
            return nil
        }

        let fallbackCandidates = registry.enumerated().filter { _, stored in
            !reservedStoredIDs.contains(stored.id) &&
            stored.providerId == provider.baseProviderId &&
            !stored.isHidden &&
            stored.credentialId != nil &&
            stored.lastSeenAt == nil
        }

        guard fallbackCandidates.count == 1 else { return nil }
        return fallbackCandidates[0].offset
    }

    // MARK: - Credential match

    static func bestCredentialMatch(
        for account: StoredProviderAccount,
        candidates: [AccountCredential]
    ) -> AccountCredential? {
        if let credId = account.providerResultId.flatMap(extractCredentialId),
           let directMatch = candidates.first(where: {
               $0.id == credId && (account.providerId != "codex"
                   || !codexIdentity(for: account).conflicts(with: CodexAccountIdentity(credential: $0)))
           }) {
            return directMatch
        }

        if isMultiWorkspace(account.providerId) {
            return nil
        }

        let normalizedAccountId = account.normalizedAccountId

        if let normalizedAccountId,
           let accountIDMatch = candidates.first(where: {
               normalizedLookupValue($0.metadata["accountId"]) == normalizedAccountId
           }) {
            return accountIDMatch
        }

        if !account.normalizedEmail.isEmpty,
           let emailMatch = candidates.first(where: {
               let credAccountId = normalizedLookupValue($0.metadata["accountId"])
               if let normalizedAccountId, let credAccountId, credAccountId != normalizedAccountId {
                   return false
               }
               return normalizedLookupValue(
                   $0.metadata["accountEmail"]
                       ?? $0.metadata["accountHandle"]
                       ?? $0.accountLabel
               ) == account.normalizedEmail
           }) {
            return emailMatch
        }

        return nil
    }

    // MARK: - Dedup whole registry

    static func deduplicate(
        registry: inout [StoredProviderAccount],
        credentialLookup: [String: AccountCredential]
    ) {
        var seen: [String: Int] = [:]
        var indicesToRemove: [Int] = []

        for (index, account) in registry.enumerated() {
            let key = identityKey(for: account, credentialLookup: credentialLookup)
            if let existingIndex = seen[key] {
                let existing = registry[existingIndex]
                let keepExisting = shouldPrefer(existing, over: account, credentialLookup: credentialLookup)

                if keepExisting {
                    registry[existingIndex] = merged(preferred: existing, secondary: account, credentialLookup: credentialLookup)
                    indicesToRemove.append(index)
                } else {
                    registry[index] = merged(preferred: account, secondary: existing, credentialLookup: credentialLookup)
                    indicesToRemove.append(existingIndex)
                    seen[key] = index
                }
            } else {
                seen[key] = index
            }
        }

        if !indicesToRemove.isEmpty {
            for index in indicesToRemove.sorted(by: >) {
                registry.remove(at: index)
            }
        }
    }

    // MARK: - Sort

    static func providerSort(
        _ lhs: ProviderData,
        _ rhs: ProviderData,
        catalogOrder: [String]
    ) -> Bool {
        let lhsIndex = catalogOrder.firstIndex(of: lhs.baseProviderId) ?? Int.max
        let rhsIndex = catalogOrder.firstIndex(of: rhs.baseProviderId) ?? Int.max

        if lhsIndex != rhsIndex {
            return lhsIndex < rhsIndex
        }

        let lhsIdentity = (lhs.accountLabel ?? lhs.accountId ?? lhs.id).lowercased()
        let rhsIdentity = (rhs.accountLabel ?? rhs.accountId ?? rhs.id).lowercased()
        return lhsIdentity.localizedCaseInsensitiveCompare(rhsIdentity) == .orderedAscending
    }
}


struct AccountRegistryReconcileResult: Sendable {
    let accounts: [StoredProviderAccount]
    let didChange: Bool
}

actor AccountRegistryRefreshWorker {
    static let shared = AccountRegistryRefreshWorker()

    private var latestRequestedRevision: UInt64 = 0
    private var lastPersistedRevision: UInt64 = 0
    private var lastPersistedAccounts: [StoredProviderAccount]?

    func reconcile(
        currentRegistry: [StoredProviderAccount],
        providers: [ProviderData],
        providerCatalogOrder: [String]
    ) -> AccountRegistryReconcileResult {
        let allCredentials = AccountCredentialStore.shared.loadAllCredentials()
        var snapshot = AccountRegistryRefreshSnapshot(
            accountRegistry: currentRegistry,
            providerCatalogOrder: providerCatalogOrder,
            allCredentials: allCredentials
        )
        let didChange = snapshot.reconcile(with: providers)
        return AccountRegistryReconcileResult(accounts: snapshot.accountRegistry,
                                             didChange: didChange || snapshot.accountRegistry != currentRegistry)
    }

    func schedulePersist(_ accounts: [StoredProviderAccount], revision: UInt64) async {
        latestRequestedRevision = max(latestRequestedRevision, revision)

        try? await Task.sleep(nanoseconds: 350_000_000)
        guard revision == latestRequestedRevision else { return }
        guard revision > lastPersistedRevision else { return }
        guard lastPersistedAccounts != accounts else { return }

        do {
            try SecureAccountVault.shared.saveAccounts(accounts)
            lastPersistedRevision = revision
            lastPersistedAccounts = accounts
        } catch {
            Logger(subsystem: "com.aiusage.desktop", category: "AccountPersistence").error(
                "Failed to persist account registry from background refresh worker (state kept in memory): \(String(describing: error), privacy: .public)"
            )
        }
    }

    func notePersistedSnapshot(_ accounts: [StoredProviderAccount], revision: UInt64) {
        latestRequestedRevision = max(latestRequestedRevision, revision)
        if revision >= lastPersistedRevision {
            lastPersistedRevision = revision
            lastPersistedAccounts = accounts
        }
    }
}

private struct AccountRegistryRefreshSnapshot {
    var accountRegistry: [StoredProviderAccount]
    let providerCatalogOrder: [String]
    let credentialLookup: [String: AccountCredential]
    let credentialsByProvider: [String: [AccountCredential]]

    nonisolated init(
        accountRegistry: [StoredProviderAccount],
        providerCatalogOrder: [String],
        allCredentials: [AccountCredential]
    ) {
        self.accountRegistry = accountRegistry
        self.providerCatalogOrder = providerCatalogOrder
        self.credentialLookup = Dictionary(uniqueKeysWithValues: allCredentials.map { ($0.id, $0) })
        self.credentialsByProvider = Dictionary(grouping: allCredentials, by: \.providerId)
        // 已验证凭据是绑定记录的事实来源。先补齐旧版 ID，再匹配本轮结果，避免生成重复卡片。
        for index in self.accountRegistry.indices {
            let account = self.accountRegistry[index]
            guard account.providerId == "codex", !account.isHidden,
                  let id = account.credentialId, let credential = credentialLookup[id],
                  credential.providerId == "codex" else { continue }
            let identity = CodexAccountIdentity(credential: credential)
            if let accountId = identity.accountId { self.accountRegistry[index].accountId = accountId }
            if let userId = identity.userId { self.accountRegistry[index].workspaceUserId = userId }
        }
    }

    nonisolated mutating func reconcile(with providers: [ProviderData]) -> Bool {
        var didChange = false
        let now = SharedFormatters.iso8601String(from: Date())
        var reservedStoredIDs = Set<String>()
        let allowUnseenCredentialFallback = providers.count == 1
        let orderedProviders = providers.sorted { lhs, rhs in
            let lhsCredentialBacked = AccountIdentityPolicy.extractCredentialId(from: lhs.id) != nil
            let rhsCredentialBacked = AccountIdentityPolicy.extractCredentialId(from: rhs.id) != nil
            if lhsCredentialBacked != rhsCredentialBacked {
                return lhsCredentialBacked && !rhsCredentialBacked
            }
            return AccountIdentityPolicy.providerSort(lhs, rhs, catalogOrder: providerCatalogOrder)
        }

        for provider in orderedProviders {
            let label = provider.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                ?? provider.accountId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                ?? provider.label.nilIfBlank

            guard let label else {
                continue
            }

            let inferredCredentialId = AccountIdentityPolicy.extractCredentialId(from: provider.id).flatMap { id in
                // 删除前已发出的请求可能稍后返回；失效凭据不能借刷新结果复活删除记录。
                provider.baseProviderId != "codex" || credentialLookup[id] != nil ? id : nil
            }

            if let hiddenIndex = accountRegistry.firstIndex(where: {
                !$0.id.isEmpty && !reservedStoredIDs.contains($0.id) && $0.isHidden &&
                AccountIdentityPolicy.matchesLive(stored: $0, provider: provider)
            }) {
                var hidden = accountRegistry[hiddenIndex]

                // Credential-backed live row means the user re-imported / reconnected —
                // revive permanent tombstones instead of keeping them suppressed forever.
                if hidden.isPermanentlyRemoved, inferredCredentialId != nil {
                    hidden.isPermanentlyRemoved = false
                    hidden.isHidden = false
                    hidden.credentialId = inferredCredentialId
                    if hidden.providerResultId != provider.id {
                        hidden.providerResultId = provider.id
                    }
                    let isLiveSuccess = provider.status != .error
                    if isLiveSuccess, hidden.accountId != provider.accountId {
                        hidden.accountId = provider.accountId
                    }
                    if let userId = provider.workspaceUserId { hidden.workspaceUserId = userId }
                    if let livePath = provider.sourceFilePath,
                       !AccountIdentityPolicy.sourceFilePathsMatch(hidden.sourceFilePath, livePath) {
                        hidden.sourceFilePath = livePath
                    }
                    hidden.lastSeenAt = now
                    accountRegistry[hiddenIndex] = hidden
                    reservedStoredIDs.insert(hidden.id)
                    didChange = true
                    continue
                }

                if hidden.providerResultId != provider.id {
                    hidden.providerResultId = provider.id
                    didChange = true
                }
                let isLiveSuccess = provider.status != .error
                if isLiveSuccess, hidden.accountId != provider.accountId {
                    hidden.accountId = provider.accountId
                    didChange = true
                }
                if let userId = provider.workspaceUserId, hidden.workspaceUserId != userId {
                    hidden.workspaceUserId = userId
                    didChange = true
                }
                if hidden.providerId != "codex", hidden.credentialId == nil, let inferredCredentialId, !hidden.isPermanentlyRemoved {
                    hidden.credentialId = inferredCredentialId
                    didChange = true
                }
                if let livePath = provider.sourceFilePath,
                   !AccountIdentityPolicy.sourceFilePathsMatch(hidden.sourceFilePath, livePath) {
                    hidden.sourceFilePath = livePath
                    didChange = true
                }
                if hidden.lastSeenAt != now {
                    hidden.lastSeenAt = now
                    didChange = true
                }
                accountRegistry[hiddenIndex] = hidden
                reservedStoredIDs.insert(hidden.id)
                continue
            }

            if let index = AccountIdentityPolicy.bestStoredAccountIndex(
                in: accountRegistry,
                for: provider,
                excluding: reservedStoredIDs,
                allowUnseenCredentialFallback: allowUnseenCredentialFallback
            ) {
                var updated = accountRegistry[index]
                if updated.email != label {
                    updated.email = label
                    didChange = true
                }
                let isLiveSuccess = provider.status != .error
                if isLiveSuccess, updated.accountId != provider.accountId {
                    updated.accountId = provider.accountId
                    didChange = true
                }
                if let userId = provider.workspaceUserId, updated.workspaceUserId != userId {
                    updated.workspaceUserId = userId
                    didChange = true
                }
                if updated.providerResultId != provider.id {
                    updated.providerResultId = provider.id
                    didChange = true
                }
                if updated.credentialId == nil, let inferredCredentialId {
                    updated.credentialId = inferredCredentialId
                    didChange = true
                }
                if let livePath = provider.sourceFilePath,
                   !AccountIdentityPolicy.sourceFilePathsMatch(updated.sourceFilePath, livePath) {
                    updated.sourceFilePath = livePath
                    didChange = true
                }
                if updated.lastSeenAt != now {
                    updated.lastSeenAt = now
                    didChange = true
                }
                if updated.isHidden {
                    updated.isHidden = false
                    didChange = true
                }
                accountRegistry[index] = updated
                reservedStoredIDs.insert(updated.id)
            } else {
                let normalizedNewEmail = label.lowercased()
                let normalizedNewAccountId = AccountIdentityPolicy.normalizedLookupValue(provider.accountId)
                let isMultiWs = AccountIdentityPolicy.isMultiWorkspace(provider.baseProviderId)
                let dupeIndex = provider.baseProviderId == "codex"
                    ? AccountIdentityPolicy.bestStoredAccountIndex(
                        in: accountRegistry,
                        for: provider,
                        excluding: [],
                        allowUnseenCredentialFallback: false
                    )
                    : accountRegistry.firstIndex(where: {
                    guard $0.providerId == provider.baseProviderId, !$0.isHidden else { return false }
                    if isMultiWs {
                        if let inferredCredentialId {
                            return $0.credentialId == inferredCredentialId
                        }
                        return AccountIdentityPolicy.sourceFilePathsMatch($0.sourceFilePath, provider.sourceFilePath)
                    }
                    if let normalizedNewAccountId, $0.normalizedAccountId == normalizedNewAccountId {
                        return true
                    }
                    if let normalizedNewAccountId, let storedAccountId = $0.normalizedAccountId,
                       storedAccountId != normalizedNewAccountId {
                        return false
                    }
                    return $0.normalizedEmail == normalizedNewEmail
                })
                if let dupeIndex {
                    var existing = accountRegistry[dupeIndex]
                    if existing.providerResultId != provider.id {
                        existing.providerResultId = provider.id
                        didChange = true
                    }
                    if provider.status != .error, existing.accountId != provider.accountId {
                        existing.accountId = provider.accountId
                        didChange = true
                    }
                    if let userId = provider.workspaceUserId, existing.workspaceUserId != userId {
                        existing.workspaceUserId = userId
                        didChange = true
                    }
                    if existing.credentialId == nil, let inferredCredentialId {
                        existing.credentialId = inferredCredentialId
                        didChange = true
                    }
                    if let livePath = provider.sourceFilePath,
                       !AccountIdentityPolicy.sourceFilePathsMatch(existing.sourceFilePath, livePath) {
                        existing.sourceFilePath = livePath
                        didChange = true
                    }
                    if existing.lastSeenAt != now {
                        existing.lastSeenAt = now
                        didChange = true
                    }
                    accountRegistry[dupeIndex] = existing
                    reservedStoredIDs.insert(existing.id)
                } else {
                    let stored = StoredProviderAccount(
                        id: UUID().uuidString,
                        providerId: provider.baseProviderId,
                        email: label,
                        displayName: nil,
                        note: nil,
                        accountId: provider.accountId,
                        providerResultId: provider.id,
                        credentialId: inferredCredentialId,
                        createdAt: now,
                        lastSeenAt: now,
                        isHidden: false,
                        sourceFilePath: provider.sourceFilePath,
                        workspaceUserId: provider.workspaceUserId
                    )
                    accountRegistry.append(stored)
                    reservedStoredIDs.insert(stored.id)
                    didChange = true
                }
            }
        }

        let beforeDedup = accountRegistry.count
        AccountIdentityPolicy.deduplicate(registry: &accountRegistry, credentialLookup: credentialLookup)
        if accountRegistry.count != beforeDedup {
            didChange = true
        }

        return didChange
    }
}

extension AccountStore {
    // MARK: - Persistence & normalization

    func normalizePersistedState() {
        bootstrapCredentialIndexFromRegistry()
        let credentialStore = AccountCredentialStore.shared
        let deduplicationPlan = credentialStore.planCredentialDeduplication()
        var didChange = applyCredentialRemapping(deduplicationPlan.remappedCredentialIDs)
        if normalizeAccountRegistryAgainstCredentials() {
            didChange = true
        }
        if stripCompositeAccountIds() {
            didChange = true
        }
        if removeAutoDiscoveredDuplicates() {
            didChange = true
        }
        let beforeDedup = accountRegistry.count
        deduplicateAccountRegistry()
        if accountRegistry.count != beforeDedup {
            didChange = true
        }

        let requiresRegistryBarrier = !deduplicationPlan.isEmpty
        let registryPersisted: Bool
        if didChange || requiresRegistryBarrier {
            registryPersisted = persistAccountRegistry()
        } else {
            registryPersisted = true
        }

        var credentialVaultCommitted = true
        if registryPersisted, requiresRegistryBarrier {
            credentialVaultCommitted = credentialStore.commitCredentialDeduplication(deduplicationPlan)
            if !credentialVaultCommitted {
                accountPersistenceLog.error("Credential deduplication commit deferred because the staged plan changed or the vault write failed.")
            }
        }

        if registryPersisted, credentialVaultCommitted {
            cleanupManagedCredentialArtifacts()
        }
    }

    private func stripCompositeAccountIds() -> Bool {
        var didChange = false
        for index in accountRegistry.indices {
            guard let accountId = accountRegistry[index].accountId?.nilIfBlank,
                  accountId.contains(":"),
                  !AccountIdentityPolicy.isMultiWorkspace(accountRegistry[index].providerId) else { continue }
            let parts = accountId.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let rawId = String(parts[0])
            let emailPart = String(parts[1]).lowercased()
            let storedEmail = accountRegistry[index].email.lowercased().nilIfBlank
            if storedEmail == emailPart || emailPart.contains("@") {
                accountRegistry[index].accountId = rawId
                didChange = true
            }
        }
        return didChange
    }

    /// Remove redundant accounts: non-credentialed when a credentialed account
    /// exists for the same email, and accounts with invalid emails when a valid
    /// account exists for the same provider.
    private func removeAutoDiscoveredDuplicates() -> Bool {
        var credentialedEmails: [String: Set<String>] = [:]
        var providersWithValidEmail: Set<String> = []
        for account in accountRegistry where !account.isHidden {
            let key = account.providerId.lowercased()
            let email = account.email.lowercased()
            if account.credentialId != nil {
                credentialedEmails[key, default: []].insert(email)
            }
            if email.contains("@") {
                providersWithValidEmail.insert(key)
            }
        }
        let before = accountRegistry.count
        accountRegistry.removeAll { account in
            guard !account.isHidden else { return false }
            let key = account.providerId.lowercased()
            let email = account.email.lowercased()
            if account.credentialId == nil,
               !AccountIdentityPolicy.isMultiWorkspace(key),
               credentialedEmails[key]?.contains(email) == true {
                return true
            }
            if !email.contains("@"),
               !AccountIdentityPolicy.isMultiWorkspace(key),
               providersWithValidEmail.contains(key),
               account.normalizedAccountId == nil {
                return true
            }
            return false
        }
        return accountRegistry.count != before
    }

    @discardableResult
    func applyCredentialRemapping(_ remappedCredentialIDs: [String: String]) -> Bool {
        guard !remappedCredentialIDs.isEmpty else { return false }

        var didChange = false
        for index in accountRegistry.indices {
            var updated = accountRegistry[index]

            if let credentialId = updated.credentialId,
               let canonicalID = remappedCredentialIDs[credentialId],
               canonicalID != credentialId {
                updated.credentialId = canonicalID
                didChange = true
            }

            if let providerResultId = updated.providerResultId,
               let resultCredentialId = extractCredentialId(from: providerResultId),
               let canonicalID = remappedCredentialIDs[resultCredentialId],
               canonicalID != resultCredentialId {
                updated.providerResultId = "\(updated.providerId):cred:\(canonicalID)"
                didChange = true
            }

            accountRegistry[index] = updated
        }

        return didChange
    }

    func normalizedAccountLookupValue(_ value: String?) -> String? {
        AccountIdentityPolicy.normalizedLookupValue(value)
    }

    func existingAuthenticatedCredential(
        incomingCredential: AccountCredential,
        providerId: String,
        accountHandle: String,
        accountId: String?,
        sessionFingerprint: String?,
        sourceIdentifier: String?,
        sourceIdentifierIsStable: Bool
    ) -> AccountCredential? {
        let normalizedHandle = normalizedAccountLookupValue(accountHandle)
        let normalizedAccountId = normalizedAccountLookupValue(accountId)
        let normalizedFingerprint = normalizedAccountLookupValue(sessionFingerprint)
        let normalizedSourceIdentifier = normalizedAccountLookupValue(sourceIdentifier)

        return AccountCredentialStore.shared.loadCredentials(for: providerId).first { credential in
            if AccountCredentialStore.credentialsShareCanonicalIdentity(
                credential,
                incomingCredential
            ) {
                return true
            }
            let isMultiWs = AccountIdentityPolicy.isMultiWorkspace(providerId)

            if !isMultiWs,
               sourceIdentifierIsStable,
               let normalizedSourceIdentifier,
               credential.metadata["identityScope"] == ProviderAuthCandidate.IdentityScope.accountScoped.rawValue,
               normalizedAccountLookupValue(credential.metadata["sourceIdentifier"]) == normalizedSourceIdentifier {
                return true
            }

            if !isMultiWs,
               let normalizedFingerprint,
               normalizedAccountLookupValue(credential.metadata["sessionFingerprint"]) == normalizedFingerprint {
                return true
            }

            if let normalizedAccountId,
               normalizedAccountLookupValue(credential.metadata["accountId"]) == normalizedAccountId {
                if isMultiWs {
                    return false
                }
                return true
            }

            if let normalizedAccountId,
               let credentialAccountId = normalizedAccountLookupValue(credential.metadata["accountId"]),
               credentialAccountId != normalizedAccountId {
                return false
            }

            if isMultiWs {
                return false
            }

            return normalizedAccountLookupValue(
                credential.metadata["accountEmail"]
                    ?? credential.metadata["accountHandle"]
                    ?? credential.accountLabel
            ) == normalizedHandle
        }
    }

    func extractCredentialId(from providerDataId: String) -> String? {
        AccountIdentityPolicy.extractCredentialId(from: providerDataId)
    }

    struct CredentialAccountSnapshot {
        let accountHandle: String?
        let displayName: String?
        let accountId: String?
        let validatedAt: String?
        let workspaceUserId: String?

        var normalizedAccountId: String? {
            accountId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
        }
    }

    func credentialAccountSnapshot(providerId: String, credentialId: String) -> CredentialAccountSnapshot? {
        guard let credential = AccountCredentialStore.shared
            .loadCredential(providerId: providerId, credentialId: credentialId) else {
            return nil
        }

        return CredentialAccountSnapshot(
            accountHandle: credential.metadata["accountEmail"]?.nilIfBlank
                ?? credential.metadata["accountHandle"]?.nilIfBlank
                ?? credential.accountLabel?.nilIfBlank,
            displayName: credential.metadata["displayName"]?.nilIfBlank,
            accountId: credential.metadata["accountId"]?.nilIfBlank,
            validatedAt: credential.metadata["lastValidatedAt"]?.nilIfBlank
                ?? credential.lastUsedAt?.nilIfBlank,
            workspaceUserId: CodexAccountIdentity(credential: credential).userId
        )
    }

    @discardableResult
    func normalizeAccountRegistryAgainstCredentials() -> Bool {
        let allCredentials = AccountCredentialStore.shared.loadAllCredentials()
        let credentialLookup = Dictionary(uniqueKeysWithValues: allCredentials.map { ($0.id, $0) })
        let credentialsByProvider = Dictionary(grouping: allCredentials, by: \.providerId)
        var didChange = false

        for index in accountRegistry.indices {
            var account = accountRegistry[index]
            // 隐藏/删除记录保留身份，但不能通过旧 providerResultId 自动重新绑定凭据。
            if account.providerId == "codex", account.isHidden { continue }
            var resolvedCredentialId = account.credentialId?.nilIfBlank

            if resolvedCredentialId == nil,
               let resultCredentialId = account.providerResultId.flatMap(extractCredentialId),
               let credential = credentialLookup[resultCredentialId],
               credential.providerId == account.providerId {
                resolvedCredentialId = credential.id
                account.credentialId = credential.id
                didChange = true
            }

            if resolvedCredentialId == nil,
               let matchedCredential = AccountIdentityPolicy.bestCredentialMatch(
                for: account,
                candidates: credentialsByProvider[account.providerId] ?? []
               ) {
                resolvedCredentialId = matchedCredential.id
                account.credentialId = matchedCredential.id
                didChange = true
            }

            guard let credentialId = resolvedCredentialId else { continue }
            guard let credential = credentialLookup[credentialId] else {
                if account.credentialId != nil {
                    account.credentialId = nil
                    account.providerResultId = nil
                    didChange = true
                }
                accountRegistry[index] = account
                continue
            }

            guard credential.providerId == account.providerId else { continue }

            let accountHandle = credential.metadata["accountEmail"]?.nilIfBlank
                ?? credential.metadata["accountHandle"]?.nilIfBlank
                ?? credential.accountLabel?.nilIfBlank
            let displayName = credential.metadata["displayName"]?.nilIfBlank
            let accountId = credential.metadata["accountId"]?.nilIfBlank
            let validatedAt = credential.metadata["lastValidatedAt"]?.nilIfBlank
                ?? credential.lastUsedAt?.nilIfBlank
            let expectedResultId = "\(account.providerId):cred:\(credential.id)"

            if let accountHandle, account.email != accountHandle {
                account.email = accountHandle
                didChange = true
            }
            if let displayName, account.displayName != displayName {
                account.displayName = displayName
                didChange = true
            }
            if let accountId, account.accountId != accountId {
                account.accountId = accountId
                didChange = true
            }
            let workspaceUserId = credential.metadata["workspaceUserId"]?.nilIfBlank
                ?? credential.metadata["userId"]?.nilIfBlank
            if let workspaceUserId, account.workspaceUserId != workspaceUserId {
                account.workspaceUserId = workspaceUserId
                didChange = true
            }
            let credSourcePath = AccountIdentityPolicy.credentialAuthFilePath(credential)
            if let credSourcePath,
               !AccountIdentityPolicy.sourceFilePathsMatch(account.sourceFilePath, credSourcePath) {
                account.sourceFilePath = credSourcePath
                didChange = true
            }
            if account.providerResultId != expectedResultId {
                account.providerResultId = expectedResultId
                didChange = true
            }
            let normalizedSeenAt = maxTimestampString(account.lastSeenAt, validatedAt)
            if account.lastSeenAt != normalizedSeenAt {
                account.lastSeenAt = normalizedSeenAt
                didChange = true
            }

            accountRegistry[index] = account
        }

        return didChange
    }

    func bootstrapCredentialIndexFromRegistry() {
        let references = Set(
            accountRegistry.flatMap { account -> [AccountCredentialReference] in
                var refs: [AccountCredentialReference] = []
                if let credentialId = account.credentialId?.nilIfBlank {
                    refs.append(AccountCredentialReference(providerId: account.providerId, credentialId: credentialId))
                }
                if let providerResultCredentialId = account.providerResultId.flatMap(extractCredentialId) {
                    refs.append(AccountCredentialReference(providerId: account.providerId, credentialId: providerResultCredentialId))
                }
                return refs
            }
        )
        AccountCredentialStore.shared.bootstrapCredentialIndex(references: Array(references))
    }

    func deduplicateAccountRegistry() {
        let credentialLookup = Dictionary(
            uniqueKeysWithValues: AccountCredentialStore.shared.loadAllCredentials().map { ($0.id, $0) }
        )
        AccountIdentityPolicy.deduplicate(registry: &accountRegistry, credentialLookup: credentialLookup)
    }

    func maxTimestampString(_ values: String?...) -> String? {
        values
            .compactMap { $0?.nilIfBlank }
            .max {
                (SharedFormatters.parseISO8601($0) ?? .distantPast) < (SharedFormatters.parseISO8601($1) ?? .distantPast)
            }
    }

    @discardableResult
    func persistAccountRegistry() -> Bool {
        let snapshot = accountRegistry
        let revision = accountRegistryRevision
        do {
            try SecureAccountVault.shared.saveAccounts(snapshot)
            Task.detached(priority: .utility) {
                await AccountRegistryRefreshWorker.shared.notePersistedSnapshot(snapshot, revision: revision)
            }
            return true
        } catch {
            accountPersistenceLog.error("Failed to persist account registry (state kept in memory): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func cleanupManagedCredentialArtifacts() {
        let credentials = AccountCredentialStore.shared.loadAllCredentials()
        guard !credentials.isEmpty else { return }
        ProviderManagedImportStore.cleanupOrphanedManagedImports(referencedBy: credentials)
    }
}
