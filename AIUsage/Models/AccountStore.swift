import Foundation
import Combine
import QuotaBackend
import os.log

// MARK: - AccountStore
// Persists multi-provider account registry (SecureAccountVault), normalizes against
// AccountCredentialStore, deduplicates, and reconciles with live ProviderData snapshots.

final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published var accountRegistry: [StoredProviderAccount] = [] {
        didSet { accountRegistryRevision &+= 1 }
    }

    /// Base provider ids in UI/catalog order; must match `AppState.providerCatalogItems`.
    var providerCatalogOrder: [String] = []
    private(set) var accountRegistryRevision: UInt64 = 0

    private init() {
        accountRegistry = SecureAccountVault.shared.loadAccounts()
    }

    /// Call once at app launch after `AppState` can supply catalog order (before refresh).
    func bootstrapFromDisk(providerCatalogOrder: [String]) {
        self.providerCatalogOrder = providerCatalogOrder
        bootstrapCredentialIndexFromRegistry()
        normalizePersistedState()
    }

    func updateProviderCatalogOrder(_ ids: [String]) {
        providerCatalogOrder = ids
    }

    // MARK: - Public account API

    @discardableResult
    func saveAccount(
        providerId: String,
        email: String,
        displayName: String?,
        note: String? = nil,
        accountId: String? = nil,
        credentialId: String? = nil,
        providerResultId: String? = nil,
        sourceFilePath: String? = nil,
        ensureProviderSelected: (String) -> Void
    ) -> Bool {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty else { return false }

        let now = SharedFormatters.iso8601String(from: Date())
        let credentialSnapshot = credentialId.flatMap {
            credentialAccountSnapshot(providerId: providerId, credentialId: $0)
        }
        let effectiveEmail = credentialSnapshot?.accountHandle ?? normalizedEmail
        let normalizedLookup = effectiveEmail.lowercased()
        let normalizedAccountId = accountId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
            ?? credentialSnapshot?.normalizedAccountId
        let normalizedProviderResultId = providerResultId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
            ?? credentialId.map { "\(providerId):cred:\($0)".lowercased() }
        let effectiveDisplayName = displayName?.nilIfBlank ?? credentialSnapshot?.displayName
        let requiresCredentialBoundIdentity = AccountIdentityPolicy.isMultiWorkspace(providerId)
        let resolvedSourcePath = sourceFilePath?.nilIfBlank
            ?? credentialId.flatMap {
                AccountCredentialStore.shared.loadCredential(providerId: providerId, credentialId: $0)
            }.flatMap(AccountIdentityPolicy.credentialAuthFilePath)
        let incomingIdentity = CodexAccountIdentity(
            accountId: normalizedAccountId, userId: credentialSnapshot?.workspaceUserId, email: effectiveEmail
        )

        if let index = accountRegistry.firstIndex(where: {
            guard $0.providerId == providerId else { return false }
            if providerId == "codex" {
                let storedIdentity = AccountIdentityPolicy.codexIdentity(for: $0)
                guard !storedIdentity.conflicts(with: incomingIdentity) else { return false }
                if storedIdentity.matches(incomingIdentity) { return true }
                if let credentialId, let storedId = $0.credentialId { return credentialId == storedId }
                return AccountIdentityPolicy.sourceFilePathsMatch($0.sourceFilePath, resolvedSourcePath)
            }
            if let credentialId, $0.credentialId == credentialId { return true }
            if let normalizedProviderResultId, $0.normalizedProviderResultId == normalizedProviderResultId { return true }
            if requiresCredentialBoundIdentity {
                // Same auth-file path = same Codex/Antigravity workspace (scan vs credential).
                if let resolvedSourcePath,
                   AccountIdentityPolicy.sourceFilePathsMatch($0.sourceFilePath, resolvedSourcePath) {
                    return true
                }
                // CPA→订阅会 copy 到 AuthImports；墓碑常记着 CPA 原路径，用 metadata.sourcePath 对齐。
                if let credentialId,
                   let cred = AccountCredentialStore.shared.loadCredential(
                    providerId: providerId,
                    credentialId: credentialId
                   ),
                   let metaSource = cred.metadata["sourcePath"],
                   AccountIdentityPolicy.sourceFilePathsMatch($0.sourceFilePath, metaSource) {
                    return true
                }
                return false
            }
            if let normalizedAccountId, $0.normalizedAccountId == normalizedAccountId { return true }
            if let normalizedAccountId, let storedAccountId = $0.normalizedAccountId,
               storedAccountId != normalizedAccountId {
                return false
            }
            return $0.normalizedEmail == normalizedLookup
        }) {
            let existing = accountRegistry[index]
            accountRegistry[index] = StoredProviderAccount(
                id: existing.id,
                providerId: existing.providerId,
                email: effectiveEmail,
                displayName: effectiveDisplayName ?? existing.displayName,
                note: note?.nilIfBlank ?? existing.note,
                accountId: normalizedAccountId ?? existing.accountId,
                providerResultId: normalizedProviderResultId ?? existing.providerResultId,
                credentialId: credentialId ?? existing.credentialId,
                createdAt: existing.createdAt,
                lastSeenAt: maxTimestampString(now, existing.lastSeenAt, credentialSnapshot?.validatedAt),
                isHidden: false,
                isPermanentlyRemoved: false,
                sourceFilePath: resolvedSourcePath ?? existing.sourceFilePath,
                workspaceUserId: credentialSnapshot?.workspaceUserId ?? existing.workspaceUserId
            )
        } else {
            accountRegistry.append(
                StoredProviderAccount(
                    id: UUID().uuidString,
                    providerId: providerId,
                    email: effectiveEmail,
                    displayName: effectiveDisplayName,
                    note: note?.nilIfBlank,
                    accountId: normalizedAccountId,
                    providerResultId: normalizedProviderResultId,
                    credentialId: credentialId,
                    createdAt: now,
                    lastSeenAt: maxTimestampString(now, credentialSnapshot?.validatedAt),
                    isHidden: false,
                    isPermanentlyRemoved: false,
                    sourceFilePath: resolvedSourcePath,
                    workspaceUserId: credentialSnapshot?.workspaceUserId
                )
            )
        }

        _ = normalizeAccountRegistryAgainstCredentials()
        deduplicateAccountRegistry()
        ensureProviderSelected(providerId)
        return persistAccountRegistry()
    }

    func registerAuthenticatedCredential(
        _ credential: AccountCredential,
        usage: ProviderUsage,
        note: String?,
        providerDisplayTitle: String,
        insertImmediateProviderData: (_ providerId: String, _ credentialId: String, _ accountLabel: String?, _ usage: ProviderUsage) -> Void,
        ensureProviderSelected: (String) -> Void
    ) throws {
        let providerId = credential.providerId
        let accountHandle: String = {
            if let v = usage.accountEmail?.nilIfBlank { return v }
            if let v = usage.accountLogin?.nilIfBlank { return v }
            if let v = usage.accountName?.nilIfBlank { return v }
            if let v = credential.accountLabel?.nilIfBlank { return v }
            if let v = usage.usageAccountId?.nilIfBlank { return v }
            return "\(providerDisplayTitle) Account"
        }()
        let displayName: String? = usage.accountName?.nilIfBlank
            ?? credential.accountLabel?.nilIfBlank
            ?? usage.accountLogin?.nilIfBlank
        // Codex / Antigravity：accountId 必须是 workspace/project 原生 id。
        // accountLogin 常是 user-xxx，写进 registry 会把墓碑和去重搞乱（Free/Business 互挡）。
        let accountId: String? = {
            if let usageAccountId = usage.usageAccountId?.nilIfBlank {
                return usageAccountId
            }
            if AccountIdentityPolicy.isMultiWorkspace(providerId) {
                return nil
            }
            return usage.accountLogin?.nilIfBlank
        }()

        var enrichedCredential = credential
        let validatedAt = SharedFormatters.iso8601String(from: Date())
        enrichedCredential.metadata["accountHandle"] = accountHandle
        enrichedCredential.metadata["lastValidatedAt"] = validatedAt
        if let accountEmail = usage.accountEmail?.nilIfBlank {
            enrichedCredential.metadata["accountEmail"] = accountEmail
        }
        if let displayName {
            enrichedCredential.metadata["displayName"] = displayName
        }
        if let accountId {
            enrichedCredential.metadata["accountId"] = accountId
        }
        if let accountPlan = usage.accountPlan?.nilIfBlank {
            enrichedCredential.metadata["accountPlan"] = accountPlan
        }
        if let workspaceType = (usage.extra["workspaceType"]?.value as? String)?.nilIfBlank {
            enrichedCredential.metadata["workspaceType"] = workspaceType
        }
        if let workspaceUserId = (usage.extra["userId"]?.value as? String)?.nilIfBlank {
            enrichedCredential.metadata["workspaceUserId"] = workspaceUserId
        }
        if providerId == "antigravity",
           let projectId = (usage.extra["projectId"]?.value as? String)?.nilIfBlank {
            enrichedCredential.metadata["projectId"] = projectId
        }
        if let apiRegion = (usage.extra[ProviderAPIRegion.metadataKey]?.value as? String)?.nilIfBlank {
            enrichedCredential.metadata[ProviderAPIRegion.metadataKey] = apiRegion
        }
        enrichedCredential.lastUsedAt = validatedAt

        if let existingCredential = existingAuthenticatedCredential(
            incomingCredential: enrichedCredential,
            providerId: providerId,
            accountHandle: accountHandle,
            accountId: accountId,
            sessionFingerprint: enrichedCredential.metadata["sessionFingerprint"],
            sourceIdentifier: enrichedCredential.metadata["sourceIdentifier"],
            sourceIdentifierIsStable: enrichedCredential.metadata["identityScope"]
                == ProviderAuthCandidate.IdentityScope.accountScoped.rawValue
        ) {
            var mergedMetadata = existingCredential.metadata
            enrichedCredential.metadata.forEach { mergedMetadata[$0.key] = $0.value }
            enrichedCredential = AccountCredential(
                id: existingCredential.id,
                providerId: existingCredential.providerId,
                accountLabel: enrichedCredential.accountLabel ?? existingCredential.accountLabel,
                authMethod: enrichedCredential.authMethod,
                credential: enrichedCredential.credential,
                metadata: mergedMetadata
            )
            enrichedCredential.lastUsedAt = validatedAt
            ProviderManagedImportStore.reuseManagedImportIfPossible(
                existingCredential: existingCredential,
                incomingCredential: &enrichedCredential
            )
        }

        let credentialStore = AccountCredentialStore.shared
        try credentialStore.saveCredential(enrichedCredential)
        let deduplicationPlan = credentialStore.planCredentialDeduplication(for: providerId)
        let credentialRemapping = deduplicationPlan.remappedCredentialIDs
        if !credentialRemapping.isEmpty {
            applyCredentialRemapping(credentialRemapping)
            if let remappedID = credentialRemapping[enrichedCredential.id] {
                let canonicalCredential = credentialStore
                    .loadCredentials(for: providerId)
                    .first(where: { $0.id == remappedID })
                var rewrittenCanonicalCredential = AccountCredential(
                    id: remappedID,
                    providerId: enrichedCredential.providerId,
                    accountLabel: enrichedCredential.accountLabel,
                    authMethod: enrichedCredential.authMethod,
                    credential: enrichedCredential.credential,
                    metadata: enrichedCredential.metadata
                )
                rewrittenCanonicalCredential.lastUsedAt = validatedAt
                if let canonicalCredential {
                    ProviderManagedImportStore.reuseManagedImportIfPossible(
                        existingCredential: canonicalCredential,
                        incomingCredential: &rewrittenCanonicalCredential
                    )
                }
                try credentialStore.saveCredential(rewrittenCanonicalCredential)
                enrichedCredential = rewrittenCanonicalCredential
            }
        }

        let registryPersisted = saveAccount(
            providerId: providerId,
            email: accountHandle,
            displayName: displayName,
            note: note,
            accountId: accountId,
            credentialId: enrichedCredential.id,
            providerResultId: "\(providerId):cred:\(enrichedCredential.id)",
            sourceFilePath: AccountIdentityPolicy.credentialAuthFilePath(enrichedCredential),
            ensureProviderSelected: ensureProviderSelected
        )

        if registryPersisted,
           !deduplicationPlan.isEmpty,
           !credentialStore.commitCredentialDeduplication(deduplicationPlan) {
            accountPersistenceLog.error("Credential deduplication commit deferred because the staged plan changed or the vault write failed.")
        }

        insertImmediateProviderData(
            providerId,
            enrichedCredential.id,
            enrichedCredential.accountLabel ?? accountHandle,
            usage
        )
    }

    func updateAccountNote(
        for entry: ProviderAccountEntry,
        note: String?,
        onProviderActivated: (String) -> Void
    ) {
        let now = SharedFormatters.iso8601String(from: Date())

        if let index = bestStoredAccountIndex(for: entry) {
            accountRegistry[index].note = note?.nilIfBlank
            accountRegistry[index].isHidden = false
            accountRegistry[index].providerResultId = entry.liveProvider?.id ?? accountRegistry[index].providerResultId
            accountRegistry[index].accountId = entry.liveProvider?.accountId ?? accountRegistry[index].accountId
            accountRegistry[index].lastSeenAt = entry.liveProvider == nil ? accountRegistry[index].lastSeenAt : now
        } else if let created = makeStoredAccount(
            from: entry,
            note: note?.nilIfBlank,
            isHidden: false,
            lastSeenAt: entry.liveProvider == nil ? nil : now
        ) {
            accountRegistry.append(created)
        } else {
            return
        }

        onProviderActivated(entry.providerId)
        persistAccountRegistry()
    }

    func restoreAccount(_ storedAccountId: String, onRestored: (String) -> Void) {
        guard let index = accountRegistry.firstIndex(where: { $0.id == storedAccountId }) else { return }
        accountRegistry[index].isHidden = false
        persistAccountRegistry()
        onRestored(accountRegistry[index].providerId)
    }

    func hideAccount(
        _ entry: ProviderAccountEntry,
        onPostRegistryChange: () -> Void
    ) {
        hideAccounts([entry], onPostRegistryChange: onPostRegistryChange)
    }

    /// Soft-hide multiple accounts with a single registry persist.
    func hideAccounts(
        _ entries: [ProviderAccountEntry],
        onPostRegistryChange: () -> Void
    ) {
        guard !entries.isEmpty else { return }

        for entry in entries {
            applyHideMutation(entry)
        }

        // Soft-hide keeps Keychain credentials; only suppress dashboard listing.
        _ = normalizeAccountRegistryAgainstCredentials()
        deduplicateAccountRegistry()
        persistAccountRegistry()
        onPostRegistryChange()
    }

    private func applyHideMutation(_ entry: ProviderAccountEntry) {
        let matchingIndices = matchingStoredAccountIndices(for: entry)
        if !matchingIndices.isEmpty {
            for index in matchingIndices {
                var updated = accountRegistry[index]
                updated.note = nil
                updated.credentialId = nil
                updated.providerResultId = entry.liveProvider?.id ?? updated.providerResultId
                updated.accountId = entry.liveProvider?.accountId ?? updated.accountId
                updated.workspaceUserId = entry.liveProvider?.workspaceUserId ?? updated.workspaceUserId
                updated.sourceFilePath = entry.liveProvider?.sourceFilePath
                    ?? entry.storedAccount?.sourceFilePath
                    ?? updated.sourceFilePath
                updated.isHidden = true
                updated.isPermanentlyRemoved = false
                updated.lastSeenAt = maxTimestampString(
                    SharedFormatters.iso8601String(from: Date()),
                    updated.lastSeenAt
                )
                accountRegistry[index] = updated
            }
        } else if let hiddenEntry = makeStoredAccount(
            from: entry,
            note: nil,
            isHidden: true,
            lastSeenAt: SharedFormatters.iso8601String(from: Date())
        ) {
            accountRegistry.append(hiddenEntry)
        }
    }

    /// Permanent delete: remove linked Keychain credentials and suppress rediscovery.
    /// Multi-workspace providers (Codex) can come back from ~/.codex or AuthImports unless
    /// a permanently-removed tombstone remains — those are hidden from the Hidden Accounts UI.
    func deleteAccount(
        _ entry: ProviderAccountEntry,
        onPostRegistryDelete: () -> Void
    ) {
        let matchedCredentials = matchingCredentialsImpl(for: entry)
        for credential in matchedCredentials {
            AccountCredentialStore.shared.deleteCredential(credential)
        }

        let matchingIndices = matchingStoredAccountIndices(for: entry)
        for index in matchingIndices.sorted(by: >) {
            accountRegistry.remove(at: index)
        }

        if let tombstone = makeStoredAccount(
            from: entry,
            note: nil,
            isHidden: true,
            lastSeenAt: SharedFormatters.iso8601String(from: Date()),
            isPermanentlyRemoved: true
        ) {
            accountRegistry.append(tombstone)
        }

        _ = normalizeAccountRegistryAgainstCredentials()
        deduplicateAccountRegistry()
        persistAccountRegistry()

        onPostRegistryDelete()

        cleanupManagedCredentialArtifacts()
    }

    func deleteAccounts(
        _ entries: [ProviderAccountEntry],
        onPostRegistryDelete: () -> Void
    ) {
        guard !entries.isEmpty else { return }

        for entry in entries {
            let matchedCredentials = matchingCredentialsImpl(for: entry)
            for credential in matchedCredentials {
                AccountCredentialStore.shared.deleteCredential(credential)
            }

            let matchingIndices = matchingStoredAccountIndices(for: entry)
            for index in matchingIndices.sorted(by: >) {
                accountRegistry.remove(at: index)
            }

            if let tombstone = makeStoredAccount(
                from: entry,
                note: nil,
                isHidden: true,
                lastSeenAt: SharedFormatters.iso8601String(from: Date()),
                isPermanentlyRemoved: true
            ) {
                accountRegistry.append(tombstone)
            }
        }

        _ = normalizeAccountRegistryAgainstCredentials()
        deduplicateAccountRegistry()
        persistAccountRegistry()

        onPostRegistryDelete()

        cleanupManagedCredentialArtifacts()
    }

    func accountNote(for provider: ProviderData) -> String? {
        accountRegistry.first(where: { !$0.isHidden && storedAccountMatchesLive($0, provider: provider) })?.note?.nilIfBlank
    }

    /// Credentials that plausibly belong to this account entry (used for CLI path resolution, etc.).
    func matchingCredentials(for entry: ProviderAccountEntry) -> [AccountCredential] {
        matchingCredentialsImpl(for: entry)
    }

    func hiddenAccounts() -> [StoredProviderAccount] {
        let providerOrder = providerCatalogOrder
        return accountRegistry
            .filter { $0.isHidden && !$0.isPermanentlyRemoved }
            .sorted {
                if $0.providerId != $1.providerId {
                    let lhsIndex = providerOrder.firstIndex(of: $0.providerId) ?? Int.max
                    let rhsIndex = providerOrder.firstIndex(of: $1.providerId) ?? Int.max
                    return lhsIndex < rhsIndex
                }
                return $0.preferredLabel.localizedCaseInsensitiveCompare($1.preferredLabel) == .orderedAscending
            }
    }

    @MainActor
    func reconcileAccountRegistry(with providers: [ProviderData]) async {
        let providerOrder = providerCatalogOrder
        var baselineRegistry = accountRegistry
        var baselineRevision = accountRegistryRevision
        var attempts = 0

        while attempts < 2 {
            attempts += 1
            let result = await AccountRegistryRefreshWorker.shared.reconcile(
                currentRegistry: baselineRegistry,
                providers: providers,
                providerCatalogOrder: providerOrder
            )

            if accountRegistryRevision != baselineRevision || accountRegistry != baselineRegistry {
                baselineRegistry = accountRegistry
                baselineRevision = accountRegistryRevision
                continue
            }

            if result.accounts != accountRegistry {
                accountRegistry = result.accounts
            }

            if result.didChange {
                let revision = accountRegistryRevision
                Task.detached(priority: .utility) {
                    await AccountRegistryRefreshWorker.shared.schedulePersist(
                        result.accounts,
                        revision: revision
                    )
                }
            }
            return
        }

        accountPersistenceLog.warning(
            "Skipped applying background account reconciliation because local registry changed concurrently"
        )
    }

    func hasHiddenRegistryMatch(
        providerId: String,
        normalizedEmail: String?,
        normalizedAccountId: String?,
        sourceFilePath: String? = nil,
        workspaceUserId: String? = nil
    ) -> Bool {
        accountRegistry.contains { stored in
            guard stored.providerId == providerId, stored.isHidden else { return false }
            if providerId == "codex" {
                let saved = AccountIdentityPolicy.codexIdentity(for: stored)
                let incoming = CodexAccountIdentity(accountId: normalizedAccountId, userId: workspaceUserId, email: normalizedEmail)
                guard !saved.conflicts(with: incoming) else { return false }
                return saved.matches(incoming)
                    || AccountIdentityPolicy.sourceFilePathsMatch(stored.sourceFilePath, sourceFilePath)
            }
            if AccountIdentityPolicy.isMultiWorkspace(providerId) {
                // Codex / Antigravity: email alone can hide the wrong workspace.
                if AccountIdentityPolicy.sourceFilePathsMatch(stored.sourceFilePath, sourceFilePath) {
                    return true
                }
                return false
            }
            if let normalizedAccountId,
               stored.normalizedAccountId == normalizedAccountId {
                return true
            }
            if let normalizedEmail,
               stored.normalizedEmail == normalizedEmail {
                return true
            }
            return false
        }
    }

    /// Whether `stored` refers to the same logical account as live `provider` data.
    func matchesStoredWithLive(_ stored: StoredProviderAccount, provider: ProviderData) -> Bool {
        storedAccountMatchesLive(stored, provider: provider)
    }
}
