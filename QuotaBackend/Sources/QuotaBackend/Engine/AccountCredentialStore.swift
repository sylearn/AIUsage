import Foundation
import Security
import os

public struct AccountCredentialReference: Hashable, Sendable {
    public let providerId: String
    public let credentialId: String

    public init(providerId: String, credentialId: String) {
        self.providerId = providerId
        self.credentialId = credentialId
    }
}

public struct AccountCredentialDeduplicationPlan: Equatable, Sendable {
    public let providerId: String?
    public let remappedCredentialIDs: [String: String]

    public var isEmpty: Bool { remappedCredentialIDs.isEmpty }

    fileprivate init(providerId: String?, remappedCredentialIDs: [String: String]) {
        self.providerId = providerId
        self.remappedCredentialIDs = remappedCredentialIDs
    }
}

private let credentialLog = Logger(subsystem: "com.aiusage.desktop", category: "CredentialStore")

/// Secure credential store backed by macOS Keychain.
/// Stores AccountCredential objects (cookies, tokens, auth file paths, API keys)
/// per provider+account, enabling multi-account and manual auth flows.
public final class AccountCredentialStore: @unchecked Sendable {
    public static let shared = AccountCredentialStore()

    // 唯一正式凭据仓库：单条 Keychain 条目（文件型 login 钥匙串）。账号注册表等其他
    // store 的数据以 auxiliary blob 折叠进同一条目，使全 App 只保留一个 Keychain
    // 条目、至多一次"始终允许"授权。历史布局的迁移与清理全部封装在
    // `LegacyKeychainCutover`，本类正常路径不含任何旧逻辑。
    //
    // 正式版固定 service；Debug（独立 bundle）与测试宿主用各自 service，避免 Agent
    // Debug 与正式安装共用同一账号库。
    private static let service: String = {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.aiusage.desktop"
        if bundleID == "com.aiusage.desktop" {
            return "com.aiusage.desktop.providerCredentials"
        }
        return "\(bundleID).providerCredentials"
    }()
    private static let credentialVaultAccount = "__credential_vault_v2__"
    /// 正式版与 Debug 隔离目录均视为托管导入路径（用于凭据评分，不参与删除）。
    private static let managedAuthImportsPathMarkers = [
        "/Library/Application Support/AIUsage/AuthImports/",
        "/Library/Application Support/AIUsage/AuthImports-"
    ]
    private static let keychainAccessibility = kSecAttrAccessibleAfterFirstUnlock
    private let lock = NSLock()
    private var cachedCredentialsByStorageKey: [String: AccountCredential]?
    /// Opaque blobs from other stores folded into the same single keychain item
    /// (e.g. the account registry from SecureAccountVault), so the whole app keeps
    /// exactly one keychain item and at most one "Always Allow" prompt.
    private var cachedAuxiliary: [String: Data] = [:]
    /// `true` only after a definitive Keychain read (`errSecSuccess` or
    /// `errSecItemNotFound`). Permission / decode failures must stay `false`
    /// so we never persist an empty stand-in vault over real credentials.
    private var vaultIsAuthoritative = false

    private init() {}

    private struct CredentialVault: Codable {
        let credentials: [AccountCredential]
        /// Auxiliary blobs co-located in the same keychain item (key → opaque Data).
        /// Optional so older vault JSON (credentials only) still decodes unchanged.
        var auxiliary: [String: Data]?
    }

    private enum KeychainVaultRead {
        case found(CredentialVault)
        case notFound
        case failed(CredentialStoreError)
    }

    // MARK: - CRUD

    public func saveCredential(_ credential: AccountCredential) throws {
        lock.lock()
        defer { lock.unlock() }

        let key = storageKey(credential)
        var vault = loadCredentialVaultUnsafe()
        vault[key] = credential
        do {
            try saveCredentialVaultUnsafe(vault)
        } catch {
            credentialLog.error("Keychain write failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        cachedCredentialsByStorageKey = vault
    }

    public func loadCredentials(for providerId: String) -> [AccountCredential] {
        lock.lock()
        defer { lock.unlock() }

        let allCreds = Array(loadCredentialVaultUnsafe().values)
        let providerCreds = allCreds.filter { $0.providerId == providerId }
        return canonicalizedCredentials(providerCreds)
    }

    public func loadAllCredentials() -> [AccountCredential] {
        lock.lock()
        defer { lock.unlock() }
        return canonicalizedCredentials(Array(loadCredentialVaultUnsafe().values))
    }

    public func loadCredential(providerId: String, credentialId: String) -> AccountCredential? {
        lock.lock()
        defer { lock.unlock() }
        return loadCredentialVaultUnsafe()[storageKey(providerId: providerId, credentialId: credentialId)]
    }

    public func deleteCredential(_ credential: AccountCredential) {
        lock.lock()
        defer { lock.unlock() }

        let key = storageKey(credential)
        var vault = loadCredentialVaultUnsafe()
        vault.removeValue(forKey: key)
        do {
            try saveCredentialVaultUnsafe(vault)
        } catch {
            credentialLog.error("Keychain write failed: \(error.localizedDescription, privacy: .public)")
        }
        cachedCredentialsByStorageKey = vault
    }

    public func deleteCredentials(for providerId: String) {
        lock.lock()
        defer { lock.unlock() }

        var vault = loadCredentialVaultUnsafe()
        let keysToRemove = vault.keys.filter { $0.hasPrefix(providerId.lowercased() + ":") }
        if !keysToRemove.isEmpty {
            for key in keysToRemove {
                vault.removeValue(forKey: key)
            }
            do {
                try saveCredentialVaultUnsafe(vault)
            } catch {
                credentialLog.error("Keychain write failed: \(error.localizedDescription, privacy: .public)")
            }
            cachedCredentialsByStorageKey = vault
        }
    }

    public func updateLastUsed(_ credential: AccountCredential, codexIdentity: CodexAccountIdentity? = nil) {
        lock.lock()
        defer { lock.unlock() }
        var vault = loadCredentialVaultUnsafe()
        let key = storageKey(credential)
        // 请求完成前账号可能已删除或重新登录；只更新当前记录，不能复活旧凭据或覆盖新 token。
        guard var updated = vault[key] else { return }
        updated.lastUsedAt = SharedFormatters.iso8601String(from: Date())
        if credential.providerId == "codex", let codexIdentity,
           updated.credential == credential.credential,
           CodexAccountIdentity(credential: updated) == CodexAccountIdentity(credential: credential) {
            // 只在原请求仍对应当前凭据时落盘已验证的原生身份，补全旧版 ID 字段。
            if let accountId = codexIdentity.accountId { updated.metadata["accountId"] = accountId }
            if let userId = codexIdentity.userId { updated.metadata["workspaceUserId"] = userId }
            if let email = codexIdentity.email { updated.metadata["accountEmail"] = email }
        }
        vault[key] = updated
        do {
            try saveCredentialVaultUnsafe(vault)
            cachedCredentialsByStorageKey = vault
        } catch {
            credentialLog.error("Keychain write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func bootstrapCredentialIndex(references: [AccountCredentialReference]) {
        lock.lock()
        defer { lock.unlock() }

        // Legacy no-op. We no longer rely on a per-credential keychain index at startup,
        // because it caused repeated access prompts for every stored credential.
        if cachedCredentialsByStorageKey == nil {
            _ = loadCredentialVaultUnsafe()
        }
    }

    /// Stage credential deduplication without mutating the Keychain vault.
    /// The returned remap can first be persisted by registry consumers and is
    /// revalidated against current vault state by `commitCredentialDeduplication`.
    public func planCredentialDeduplication(
        for providerId: String? = nil
    ) -> AccountCredentialDeduplicationPlan {
        lock.lock()
        defer { lock.unlock() }

        return makeCredentialDeduplicationPlan(
            for: loadAllCredentialsUnsafe(),
            providerId: providerId
        )
    }

    /// Commit a previously staged plan. A stale plan is rejected rather than
    /// deleting credentials based on an obsolete registry remap.
    @discardableResult
    public func commitCredentialDeduplication(
        _ plan: AccountCredentialDeduplicationPlan
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let allCredentials = loadAllCredentialsUnsafe()
        guard credentialDeduplicationPlan(plan, isValidFor: allCredentials) else {
            return false
        }
        guard !plan.isEmpty else { return true }

        let targetCredentials = credentials(
            allCredentials,
            scopedTo: plan.providerId
        )
        let retiredIDs = Set(plan.remappedCredentialIDs.keys)
        let storageKeysToRemove = Set(
            targetCredentials
                .filter { retiredIDs.contains($0.id) }
                .map(storageKey)
        )
        guard storageKeysToRemove.count == retiredIDs.count else {
            return false
        }

        var vault = loadCredentialVaultUnsafe()
        for key in storageKeysToRemove {
            guard vault.removeValue(forKey: key) != nil else {
                return false
            }
        }

        do {
            try saveCredentialVaultUnsafe(vault)
        } catch {
            credentialLog.error("Keychain write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        cachedCredentialsByStorageKey = vault
        return true
    }

    /// Compatibility wrapper for callers that do not own a related registry.
    /// Registry-backed flows must use the staged APIs so their references are
    /// persisted before retired credentials are deleted.
    @discardableResult
    public func deduplicateCredentials(for providerId: String? = nil) -> [String: String] {
        let plan = planCredentialDeduplication(for: providerId)
        guard commitCredentialDeduplication(plan) else { return [:] }
        return plan.remappedCredentialIDs
    }

    func makeCredentialDeduplicationPlan(
        for allCredentials: [AccountCredential],
        providerId: String? = nil
    ) -> AccountCredentialDeduplicationPlan {
        let targetCredentials = credentials(allCredentials, scopedTo: providerId)
        let (_, remappedIDs) = canonicalizationResult(for: targetCredentials)
        return AccountCredentialDeduplicationPlan(
            providerId: providerId,
            remappedCredentialIDs: remappedIDs
        )
    }

    func credentialDeduplicationPlan(
        _ plan: AccountCredentialDeduplicationPlan,
        isValidFor allCredentials: [AccountCredential]
    ) -> Bool {
        makeCredentialDeduplicationPlan(
            for: allCredentials,
            providerId: plan.providerId
        ) == plan
    }

    private func credentials(
        _ allCredentials: [AccountCredential],
        scopedTo providerId: String?
    ) -> [AccountCredential] {
        providerId.map { id in
            allCredentials.filter { $0.providerId == id }
        } ?? allCredentials
    }

    // MARK: - Internal

    private func storageKey(_ credential: AccountCredential) -> String {
        storageKey(providerId: credential.providerId, credentialId: credential.id)
    }

    private func storageKey(providerId: String, credentialId: String) -> String {
        "\(providerId):\(credentialId)"
    }

    private func loadAllCredentialsUnsafe() -> [AccountCredential] {
        Array(loadCredentialVaultUnsafe().values)
    }

    private func loadCredentialVaultUnsafe() -> [String: AccountCredential] {
        if vaultIsAuthoritative, let cachedCredentialsByStorageKey {
            return cachedCredentialsByStorageKey
        }

        switch readVaultFromKeychainUnsafe() {
        case .found(let vault):
            vaultIsAuthoritative = true
            let dict = applyLoadedVaultUnsafe(vault)
            return finishVaultLoadUnsafe(dict)
        case .notFound:
            // First launch / wiped item: empty vault is legitimate and writable.
            vaultIsAuthoritative = true
            let dict = applyLoadedVaultUnsafe(CredentialVault(credentials: [], auxiliary: nil))
            return finishVaultLoadUnsafe(dict)
        case .failed(let error):
            // Fail closed: do not cache an empty stand-in. Reads look empty for
            // this attempt; writes must refuse until a definitive load succeeds.
            vaultIsAuthoritative = false
            cachedCredentialsByStorageKey = nil
            cachedAuxiliary = [:]
            credentialLog.error(
                "Keychain vault read failed; refusing to treat vault as empty: \(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
    }

    private func finishVaultLoadUnsafe(_ dict: [String: AccountCredential]) -> [String: AccountCredential] {
        // One-time cutover from every historical Keychain layout. Gated by a
        // sentinel stored in the vault's auxiliary, so after the first successful
        // run no legacy item is ever read again.
        //
        // 仅正式 Bundle（com.aiusage.desktop）可执行 cutover：其 purge 目标是正式
        // Keychain 服务名。Debug / 测试宿主若跑同一逻辑，会误扫正式库旧条目。
        if cachedAuxiliary[LegacyKeychainCutover.sentinelAuxiliaryKey] == nil {
            let bundleID = Bundle.main.bundleIdentifier ?? ""
            if bundleID == "com.aiusage.desktop" {
                return performLegacyCutoverUnsafe()
            }
            markLegacyCutoverSkippedForNonProductionUnsafe()
        }
        return dict
    }

    private func requireAuthoritativeVaultForWriteUnsafe() throws {
        if vaultIsAuthoritative { return }
        _ = loadCredentialVaultUnsafe()
        guard vaultIsAuthoritative else {
            throw CredentialStoreError.vaultUnavailable
        }
    }

    /// Debug / 非生产宿主：只在本进程自己的 vault 里记 sentinel，绝不 collect/purge 正式 Keychain。
    private func markLegacyCutoverSkippedForNonProductionUnsafe() {
        cachedAuxiliary[LegacyKeychainCutover.sentinelAuxiliaryKey] = Data([1])
        do {
            try writeVaultUnsafe(encodeCurrentVaultUnsafe())
        } catch {
            cachedAuxiliary.removeValue(forKey: LegacyKeychainCutover.sentinelAuxiliaryKey)
            credentialLog.error(
                "Non-production cutover skip deferred (vault write failed): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Fold any data still living in legacy Keychain layouts into the canonical
    /// vault, then mark the cutover done and delete the legacy items. The canonical
    /// vault always wins; legacy data only fills gaps. The sentinel is committed
    /// (and legacy items purged) ONLY after the vault write succeeds, so a failed
    /// write leaves no sentinel and the next launch retries — nothing is lost.
    private func performLegacyCutoverUnsafe() -> [String: AccountCredential] {
        let legacy = LegacyKeychainCutover.collect()

        var dict = cachedCredentialsByStorageKey ?? [:]
        for credential in legacy.credentials {
            let key = storageKey(credential)
            if dict[key] == nil {
                dict[key] = credential
            }
        }
        cachedCredentialsByStorageKey = dict

        if cachedAuxiliary[LegacyKeychainCutover.registryAuxiliaryKey] == nil,
           let blob = legacy.registryBlob {
            cachedAuxiliary[LegacyKeychainCutover.registryAuxiliaryKey] = blob
        }

        cachedAuxiliary[LegacyKeychainCutover.sentinelAuxiliaryKey] = Data([1])
        do {
            try writeVaultUnsafe(encodeCurrentVaultUnsafe())
            LegacyKeychainCutover.purge()
        } catch {
            cachedAuxiliary.removeValue(forKey: LegacyKeychainCutover.sentinelAuxiliaryKey)
            credentialLog.error("Legacy keychain cutover deferred (vault write failed): \(error.localizedDescription, privacy: .public)")
        }
        return dict
    }

    /// Cache the decoded vault (credentials + auxiliary blobs) and return the
    /// credential dictionary keyed by storage key.
    @discardableResult
    private func applyLoadedVaultUnsafe(_ vault: CredentialVault) -> [String: AccountCredential] {
        let dict = Dictionary(
            uniqueKeysWithValues: vault.credentials.map { (storageKey($0), $0) }
        )
        cachedCredentialsByStorageKey = dict
        cachedAuxiliary = vault.auxiliary ?? [:]
        return dict
    }

    private func encodeCurrentVaultUnsafe() throws -> Data {
        let orderedCredentials = (cachedCredentialsByStorageKey ?? [:]).values.sorted(by: credentialSort)
        return try JSONEncoder().encode(
            CredentialVault(credentials: orderedCredentials, auxiliary: cachedAuxiliary.isEmpty ? nil : cachedAuxiliary)
        )
    }

    // MARK: - Auxiliary blob storage (folded into the single vault item)

    /// Read an opaque blob co-located in the credential vault item.
    /// Used by app-side stores (e.g. SecureAccountVault) so the whole app keeps
    /// a single keychain item and at most one access prompt.
    ///
    /// When Keychain is temporarily unreadable, returns `nil` without poisoning
    /// the in-memory vault. Callers that must mutate storage should use
    /// `saveAuxiliaryData`, which fail-closes instead of writing an empty vault.
    public func loadAuxiliaryData(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        _ = loadCredentialVaultUnsafe()
        guard vaultIsAuthoritative else { return nil }
        return cachedAuxiliary[key]
    }

    /// Write (or clear, when `data` is nil) an opaque blob into the credential
    /// vault item, preserving the stored credentials.
    public func saveAuxiliaryData(_ data: Data?, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let vault = loadCredentialVaultUnsafe()
        try requireAuthoritativeVaultForWriteUnsafe()
        let previous = cachedAuxiliary[key]
        if let data {
            cachedAuxiliary[key] = data
        } else {
            cachedAuxiliary.removeValue(forKey: key)
        }
        do {
            try saveCredentialVaultUnsafe(vault)
        } catch {
            if let previous {
                cachedAuxiliary[key] = previous
            } else {
                cachedAuxiliary.removeValue(forKey: key)
            }
            throw error
        }
    }

    private func readVaultFromKeychainUnsafe() -> KeychainVaultRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.credentialVaultAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                return .failed(.keychainReadFailed(status))
            }
            do {
                return .found(try JSONDecoder().decode(CredentialVault.self, from: data))
            } catch {
                return .failed(.vaultDecodeFailed)
            }
        case errSecItemNotFound:
            return .notFound
        default:
            return .failed(.keychainReadFailed(status))
        }
    }

    private func saveCredentialVaultUnsafe(_ credentialsByStorageKey: [String: AccountCredential]) throws {
        try requireAuthoritativeVaultForWriteUnsafe()
        let orderedCredentials = credentialsByStorageKey.values.sorted(by: credentialSort)
        let data = try JSONEncoder().encode(
            CredentialVault(credentials: orderedCredentials, auxiliary: cachedAuxiliary.isEmpty ? nil : cachedAuxiliary)
        )
        try writeVaultUnsafe(data)
    }

    private func writeVaultUnsafe(_ data: Data) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.credentialVaultAccount
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: Self.keychainAccessibility
        ]

        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var create = baseQuery
            create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = Self.keychainAccessibility
            let addStatus = SecItemAdd(create as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialStoreError.keychainWriteFailed(addStatus)
            }
        } else if status != errSecSuccess {
            throw CredentialStoreError.keychainWriteFailed(status)
        }
    }

    private func canonicalizedCredentials(_ credentials: [AccountCredential]) -> [AccountCredential] {
        canonicalizationResult(for: credentials).canonical.sorted(by: credentialSort)
    }

    /// Collapse credentials that refer to the same provider-native account.
    ///
    /// Identity equivalence intentionally cannot be represented by one dictionary
    /// key: complete provider-native identities can match across imported auth-file
    /// copies, while incomplete tuples may match only on the same normalized path.
    /// Groups retain every member and accept a new credential only when it is
    /// compatible with all of them, preventing an incomplete record from bridging
    /// two conflicting stable identities.
    func canonicalizationResult(for credentials: [AccountCredential]) -> (canonical: [AccountCredential], remappedIDs: [String: String]) {
        guard !credentials.isEmpty else { return ([], [:]) }

        let orderedCredentials = credentials.sorted { lhs, rhs in
            let lhsSpecificity = Self.identitySpecificity(lhs)
            let rhsSpecificity = Self.identitySpecificity(rhs)
            if lhsSpecificity != rhsSpecificity {
                return lhsSpecificity > rhsSpecificity
            }
            return shouldPreferCredential(lhs, over: rhs)
        }

        var groups: [[AccountCredential]] = []
        var preferredCredentials: [AccountCredential] = []

        for credential in orderedCredentials {
            if let groupIndex = groups.firstIndex(where: { group in
                group.allSatisfy {
                    Self.credentialsShareCanonicalIdentity(credential, $0)
                }
            }) {
                groups[groupIndex].append(credential)
                if shouldPreferCredential(credential, over: preferredCredentials[groupIndex]) {
                    preferredCredentials[groupIndex] = credential
                }
            } else {
                groups.append([credential])
                preferredCredentials.append(credential)
            }
        }

        var remappedIDs: [String: String] = [:]
        for (group, preferred) in zip(groups, preferredCredentials) {
            for credential in group where credential.id != preferred.id {
                remappedIDs[credential.id] = preferred.id
            }
        }

        return (preferredCredentials, remappedIDs)
    }

    /// Single source of truth for providers whose accounts cannot be deduped by a
    /// display handle alone. Codex needs account+user identity, while Antigravity
    /// needs project+email identity. All identity layers — credential store,
    /// provider engine, app-side AccountIdentityPolicy — must consult this set
    /// rather than keeping their own copies.
    public static let multiWorkspaceProviders: Set<String> = ["codex", "antigravity"]

    public static func isMultiWorkspace(_ providerId: String) -> Bool {
        multiWorkspaceProviders.contains(providerId.lowercased())
    }

    /// 规则#9：`resolvingSymlinksInPath()` 每次都做 lstat/realpath（文件系统往返）。
    /// 该归一化在账号匹配的 O(n²) 循环里被反复调用，是数据刷新期间主线程的头号文件系统热点
    /// （见 issue #28 Instruments profile）。auth 路径在一次会话内稳定、同路径恒等结果，故缓存复用。
    /// NSCache 线程安全，可跨 actor/线程共享；缓存条目数受唯一路径数约束（极小）。
    private static let normalizedAuthPathCache = NSCache<NSString, NSString>()

    /// Normalize an auth-file path for identity comparison.
    /// - Expands `~`, removes `//` / `.` / `..`, resolves symlinks so two credentials
    ///   pointing at the same underlying file dedupe.
    /// - Lowercased because macOS default FS (APFS) is case-insensitive; case-sensitive
    ///   volumes accept a false positive here but that is preferable to a missed merge.
    public static func normalizedAuthFilePath(_ rawPath: String) -> String {
        let key = rawPath as NSString
        if let cached = normalizedAuthPathCache.object(forKey: key) {
            return cached as String
        }
        let expanded = NSString(string: rawPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let normalized = url.path.precomposedStringWithCanonicalMapping.lowercased()
        normalizedAuthPathCache.setObject(normalized as NSString, forKey: key)
        return normalized
    }

    /// Stable, secret-free descriptor of the identity information carried by a
    /// credential. This is intended for diagnostics and tests; callers must use
    /// `credentialsShareCanonicalIdentity` for comparison because incomplete
    /// identities are allowed to match only through the normalized auth-file path.
    public static func canonicalIdentityKey(for credential: AccountCredential) -> String {
        let provider = normalizedIdentityComponent(credential.providerId)
            ?? credential.providerId.lowercased()

        if provider == "codex" {
            let identity = CodexAccountIdentity(credential: credential)
            if let nativeKey = identity.nativeKey { return nativeKey }
            if credential.authMethod == .authFile {
                let accountId = normalizedIdentityComponent(credential.metadata["accountId"]) ?? "*"
                let userId = codexUserId(for: credential) ?? "*"
                return "\(provider):incomplete:account:\(accountId)"
                    + ":user:\(userId)"
                    + ":email:\(identity.email ?? "*")"
                    + ":authfile:\(normalizedAuthFilePath(credential.credential))"
            }
            return "\(provider):raw:\(credential.id.lowercased())"
        }

        if provider == "antigravity" {
            if let identity = antigravityNativeIdentity(for: credential) {
                return "\(provider):project:\(identity.projectId)"
                    + ":email:\(identity.email)"
            }
            if credential.authMethod == .authFile {
                let projectId = antigravityProjectId(for: credential) ?? "*"
                let email = antigravityEmail(for: credential) ?? "*"
                return "\(provider):incomplete:project:\(projectId)"
                    + ":email:\(email)"
                    + ":authfile:\(normalizedAuthFilePath(credential.credential))"
            }
            return "\(provider):raw:\(credential.id.lowercased())"
        }

        if let accountId = normalizedIdentityComponent(credential.metadata["accountId"]) {
            return "\(provider):account:\(accountId)"
        }

        if let handle = normalizedIdentityComponent(
            credential.metadata["accountEmail"]
                ?? credential.metadata["accountHandle"]
                ?? credential.accountLabel
        ) {
            return "\(provider):handle:\(handle)"
        }

        if credential.authMethod == .authFile {
            return "\(provider):authfile:\(normalizedAuthFilePath(credential.credential))"
        }

        return "\(provider):raw:\(credential.id.lowercased())"
    }

    /// Returns whether two credentials represent the same canonical account.
    ///
    /// Codex uses `accountId + userId`; Antigravity uses `projectId + email`.
    /// Every component must be present and equal to match across different files.
    /// If any stable component is missing, credentials can match only on the same
    /// normalized auth-file path and only when their known components do not
    /// conflict. Codex workspace and plan metadata are deliberately excluded
    /// because subscriptions can be upgraded, downgraded, or renamed.
    public static func credentialsShareCanonicalIdentity(
        _ lhs: AccountCredential,
        _ rhs: AccountCredential
    ) -> Bool {
        let lhsProvider = normalizedIdentityComponent(lhs.providerId)
        let rhsProvider = normalizedIdentityComponent(rhs.providerId)
        guard lhsProvider == rhsProvider, let provider = lhsProvider else {
            return false
        }

        if provider == "antigravity" {
            return antigravityCredentialsShareCanonicalIdentity(lhs, rhs)
        }

        guard provider == "codex" else {
            return canonicalIdentityKey(for: lhs) == canonicalIdentityKey(for: rhs)
        }

        let lhsIdentity = CodexAccountIdentity(credential: lhs)
        let rhsIdentity = CodexAccountIdentity(credential: rhs)
        guard !lhsIdentity.conflicts(with: rhsIdentity) else { return false }
        if let lhsNative = lhsIdentity.nativeKey, let rhsNative = rhsIdentity.nativeKey {
            return lhsNative == rhsNative
        }

        return authFilePathsMatch(lhs, rhs)
    }

    private static func codexUserId(for credential: AccountCredential) -> String? {
        CodexAccountIdentity(credential: credential).userId
    }

    private struct AntigravityNativeIdentity: Equatable {
        let projectId: String
        let email: String
    }

    private static func antigravityCredentialsShareCanonicalIdentity(
        _ lhs: AccountCredential,
        _ rhs: AccountCredential
    ) -> Bool {
        let lhsProjectId = antigravityProjectId(for: lhs)
        let rhsProjectId = antigravityProjectId(for: rhs)
        let lhsEmail = antigravityEmail(for: lhs)
        let rhsEmail = antigravityEmail(for: rhs)

        if knownIdentityValuesConflict(lhsProjectId, rhsProjectId)
            || knownIdentityValuesConflict(lhsEmail, rhsEmail) {
            return false
        }

        if let lhsNative = antigravityNativeIdentity(for: lhs),
           let rhsNative = antigravityNativeIdentity(for: rhs) {
            return lhsNative == rhsNative
        }

        return authFilePathsMatch(lhs, rhs)
    }

    private static func antigravityNativeIdentity(
        for credential: AccountCredential
    ) -> AntigravityNativeIdentity? {
        guard let projectId = antigravityProjectId(for: credential),
              let email = antigravityEmail(for: credential) else {
            return nil
        }
        return AntigravityNativeIdentity(projectId: projectId, email: email)
    }

    private static func antigravityProjectId(for credential: AccountCredential) -> String? {
        normalizedIdentityComponent(
            credential.metadata["projectId"] ?? credential.metadata["project_id"]
        )
    }

    private static func antigravityEmail(for credential: AccountCredential) -> String? {
        let candidates = [
            credential.metadata["accountEmail"],
            credential.metadata["accountHandle"],
            credential.accountLabel,
        ]
        return candidates.lazy
            .compactMap(normalizedIdentityComponent)
            .first(where: { $0.contains("@") })
    }

    private static func knownIdentityValuesConflict(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs != rhs
    }

    private static func authFilePathsMatch(
        _ lhs: AccountCredential,
        _ rhs: AccountCredential
    ) -> Bool {
        guard lhs.authMethod == .authFile, rhs.authMethod == .authFile else {
            return false
        }
        return normalizedAuthFilePath(lhs.credential) == normalizedAuthFilePath(rhs.credential)
    }

    private static func identitySpecificity(_ credential: AccountCredential) -> Int {
        switch credential.providerId.lowercased() {
        case "codex":
            return (normalizedIdentityComponent(credential.metadata["accountId"]) == nil ? 0 : 1)
                + (codexUserId(for: credential) == nil ? 0 : 1)
        case "antigravity":
            return (antigravityProjectId(for: credential) == nil ? 0 : 1)
                + (antigravityEmail(for: credential) == nil ? 0 : 1)
        default:
            return 0
        }
    }

    private static func normalizedIdentityComponent(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func shouldPreferCredential(_ candidate: AccountCredential, over existing: AccountCredential) -> Bool {
        let candidateScore = credentialScore(candidate)
        let existingScore = credentialScore(existing)
        if candidateScore != existingScore {
            return candidateScore > existingScore
        }

        let candidateImported = recencyTimestamp(for: candidate)
        let existingImported = recencyTimestamp(for: existing)
        if candidateImported != existingImported {
            return candidateImported > existingImported
        }

        let candidateLastUsed = timestamp(for: candidate.lastUsedAt)
        let existingLastUsed = timestamp(for: existing.lastUsedAt)
        if candidateLastUsed != existingLastUsed {
            return candidateLastUsed > existingLastUsed
        }

        let candidateCreated = timestamp(for: candidate.createdAt)
        let existingCreated = timestamp(for: existing.createdAt)
        if candidateCreated != existingCreated {
            return candidateCreated > existingCreated
        }

        return candidate.id < existing.id
    }

    private func credentialScore(_ credential: AccountCredential) -> Int {
        var score = 0

        if normalizedLookup(credential.metadata["accountId"]) != nil {
            score += 80
        }
        if Self.isMultiWorkspace(credential.providerId) {
            // Keep the most identity-rich copy as canonical so a later refresh
            // does not lose the stable account/user discriminator.
            score += Self.identitySpecificity(credential) * 10
        }
        if normalizedLookup(credential.metadata["accountEmail"] ?? credential.metadata["accountHandle"] ?? credential.accountLabel) != nil {
            score += 40
        }

        switch credential.authMethod {
        case .authFile:
            let path = NSString(string: credential.credential).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) {
                score += 35
            } else {
                score -= 120
            }
            if Self.managedAuthImportsPathMarkers.contains(where: { path.contains($0) }) {
                score += 25
            }
            if normalizedLookup(credential.metadata["sourcePath"]) == normalizedLookup(path) {
                score += 10
            }
        case .cookie, .webSession, .token, .apiKey, .oauth:
            score += 15
        case .auto:
            break
        }

        if normalizedLookup(credential.metadata["sourceIdentifier"]) != nil {
            score += 5
        }

        return score
    }

    private func recencyTimestamp(for credential: AccountCredential) -> Date {
        if let validated = timestampOrNil(for: credential.metadata["lastValidatedAt"]) {
            return validated
        }
        if let imported = timestampOrNil(for: credential.metadata["importedAt"]) {
            return imported
        }
        return timestamp(for: credential.createdAt)
    }

    private func timestampOrNil(for value: String?) -> Date? {
        guard let value,
              let date = SharedFormatters.parseISO8601(value) else {
            return nil
        }
        return date
    }

    private func timestamp(for value: String?) -> Date {
        guard let value,
              let date = SharedFormatters.parseISO8601(value) else {
            return .distantPast
        }
        return date
    }

    private func normalizedLookup(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func credentialSort(_ lhs: AccountCredential, _ rhs: AccountCredential) -> Bool {
        if lhs.providerId != rhs.providerId {
            return lhs.providerId < rhs.providerId
        }

        let lhsLabel = normalizedLookup(lhs.metadata["accountEmail"] ?? lhs.metadata["accountHandle"] ?? lhs.accountLabel) ?? lhs.id.lowercased()
        let rhsLabel = normalizedLookup(rhs.metadata["accountEmail"] ?? rhs.metadata["accountHandle"] ?? rhs.accountLabel) ?? rhs.id.lowercased()
        if lhsLabel != rhsLabel {
            return lhsLabel < rhsLabel
        }

        return shouldPreferCredential(lhs, over: rhs)
    }
}

// MARK: - Errors

public enum CredentialStoreError: LocalizedError {
    case keychainWriteFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case vaultDecodeFailed
    /// Keychain vault could not be loaded authoritatively; refusing to write
    /// so a transient read failure cannot overwrite real credentials with `[]`.
    case vaultUnavailable

    public var errorDescription: String? {
        switch self {
        case .keychainWriteFailed(let status):
            return "Keychain write failed (OSStatus: \(status))"
        case .keychainReadFailed(let status):
            return "Keychain read failed (OSStatus: \(status))"
        case .vaultDecodeFailed:
            return "Keychain credential vault is corrupt and could not be decoded"
        case .vaultUnavailable:
            return "Keychain credential vault is temporarily unavailable; write refused"
        }
    }
}
