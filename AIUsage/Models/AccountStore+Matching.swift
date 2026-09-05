import Foundation
import Combine
import QuotaBackend

extension AccountStore {
    // MARK: - Account matching & lookup
    //
    // These are thin delegates to `AccountIdentityPolicy` — the single source of
    // truth for identity / matching rules (see AccountStore+Persistence.swift).
    // Keep the instance-method surface so existing callers throughout the app
    // stay unchanged; the logic is centralized in the policy.

    func bestCredentialMatch(
        for account: StoredProviderAccount,
        candidates: [AccountCredential]
    ) -> AccountCredential? {
        AccountIdentityPolicy.bestCredentialMatch(for: account, candidates: candidates)
    }

    func bestStoredAccountIndex(
        for provider: ProviderData,
        excluding reservedStoredIDs: Set<String>,
        allowUnseenCredentialFallback: Bool
    ) -> Int? {
        AccountIdentityPolicy.bestStoredAccountIndex(
            in: accountRegistry,
            for: provider,
            excluding: reservedStoredIDs,
            allowUnseenCredentialFallback: allowUnseenCredentialFallback
        )
    }

    func storedAccountMatchesLive(_ stored: StoredProviderAccount, provider: ProviderData) -> Bool {
        AccountIdentityPolicy.matchesLive(stored: stored, provider: provider)
    }

    func normalizedLiveAccountID(for provider: ProviderData) -> String? {
        AccountIdentityPolicy.normalizedLiveAccountID(for: provider)
    }

    func normalizedAccountIdentifier(for provider: ProviderData) -> String? {
        AccountIdentityPolicy.normalizedAccountIdentifier(for: provider)
    }

    func providerSort(_ lhs: ProviderData, _ rhs: ProviderData) -> Bool {
        AccountIdentityPolicy.providerSort(lhs, rhs, catalogOrder: providerCatalogOrder)
    }

    // MARK: - Entry-scoped lookups (not duplicated in the worker snapshot)

    func bestStoredAccountIndex(for entry: ProviderAccountEntry) -> Int? {
        if let storedID = entry.storedAccount?.id,
           let exactIndex = accountRegistry.firstIndex(where: { $0.id == storedID }) {
            return exactIndex
        }

        if let liveProvider = entry.liveProvider,
           let liveIndex = accountRegistry.firstIndex(where: {
               AccountIdentityPolicy.matchesLive(stored: $0, provider: liveProvider)
           }) {
            return liveIndex
        }

        if AccountIdentityPolicy.isMultiWorkspace(entry.providerId) {
            if entry.providerId == "codex" { return nil }
            let livePath = entry.liveProvider?.sourceFilePath ?? entry.storedAccount?.sourceFilePath
            guard let livePath else { return nil }
            return accountRegistry.firstIndex(where: {
                $0.providerId == entry.providerId &&
                AccountIdentityPolicy.sourceFilePathsMatch($0.sourceFilePath, livePath)
            })
        }

        let normalizedTokens = Set([
            entry.accountEmail?.lowercased().nilIfBlank,
            entry.accountDisplayName?.lowercased().nilIfBlank,
            entry.liveProvider?.accountId?.lowercased().nilIfBlank,
            entry.storedAccount?.normalizedEmail,
            entry.storedAccount?.normalizedAccountId
        ].compactMap { $0 })

        guard !normalizedTokens.isEmpty else { return nil }
        return accountRegistry.firstIndex { stored in
            guard stored.providerId == entry.providerId else { return false }
            return normalizedTokens.contains(stored.normalizedEmail)
                || (stored.normalizedAccountId.map(normalizedTokens.contains) ?? false)
        }
    }

    func makeStoredAccount(
        from entry: ProviderAccountEntry,
        note: String?,
        isHidden: Bool,
        lastSeenAt: String?,
        isPermanentlyRemoved: Bool = false
    ) -> StoredProviderAccount? {
        let now = SharedFormatters.iso8601String(from: Date())
        let label = entry.accountEmail?.nilIfBlank
            ?? entry.accountDisplayName?.nilIfBlank
            ?? entry.liveProvider?.accountId?.nilIfBlank
            ?? entry.storedAccount?.email.nilIfBlank
            ?? entry.providerTitle.nilIfBlank

        guard let label else { return nil }

        return StoredProviderAccount(
            id: entry.storedAccount?.id ?? UUID().uuidString,
            providerId: entry.providerId,
            email: label,
            displayName: entry.storedAccount?.displayName?.nilIfBlank ?? entry.accountDisplayName?.nilIfBlank,
            note: note,
            accountId: entry.liveProvider?.accountId?.nilIfBlank ?? entry.storedAccount?.accountId,
            providerResultId: entry.liveProvider?.id ?? entry.storedAccount?.providerResultId,
            credentialId: isPermanentlyRemoved ? nil : entry.storedAccount?.credentialId,
            createdAt: entry.storedAccount?.createdAt ?? now,
            lastSeenAt: lastSeenAt ?? entry.storedAccount?.lastSeenAt,
            isHidden: isHidden || isPermanentlyRemoved,
            isPermanentlyRemoved: isPermanentlyRemoved,
            sourceFilePath: entry.liveProvider?.sourceFilePath ?? entry.storedAccount?.sourceFilePath,
            workspaceUserId: entry.liveProvider?.workspaceUserId ?? entry.storedAccount?.workspaceUserId
        )
    }

    func matchingCredentialsImpl(for entry: ProviderAccountEntry) -> [AccountCredential] {
        if entry.providerId == "codex" {
            let identity = entry.liveProvider.map(AccountIdentityPolicy.codexIdentity(for:))
                ?? entry.storedAccount.map { AccountIdentityPolicy.codexIdentity(for: $0) }
                ?? CodexAccountIdentity(accountId: nil, userId: nil)
            let boundId = entry.storedAccount?.credentialId
                ?? entry.liveProvider.flatMap { AccountIdentityPolicy.extractCredentialId(from: $0.id) }
            let path = entry.liveProvider?.sourceFilePath ?? entry.storedAccount?.sourceFilePath
            return AccountCredentialStore.shared.loadCredentials(for: "codex").filter { credential in
                let candidate = CodexAccountIdentity(credential: credential)
                guard !identity.conflicts(with: candidate) else { return false }
                if identity.matches(candidate) { return true }
                if let boundId { return credential.id == boundId }
                return AccountIdentityPolicy.sourceFilePathsMatch(
                    AccountIdentityPolicy.credentialAuthFilePath(credential), path
                )
            }
        }
        if let credentialId = entry.storedAccount?.credentialId?.nilIfBlank,
           let directMatch = AccountCredentialStore.shared.loadCredential(
            providerId: entry.providerId,
            credentialId: credentialId
           ) {
            return [directMatch]
        }

        // Live multi-account rows are often `provider:cred:<id>` without a stored credentialId yet.
        if let liveId = entry.liveProvider?.id,
           let credentialId = AccountIdentityPolicy.extractCredentialId(from: liveId),
           let directMatch = AccountCredentialStore.shared.loadCredential(
            providerId: entry.providerId,
            credentialId: credentialId
           ) {
            return [directMatch]
        }

        let credentials = AccountCredentialStore.shared.loadCredentials(for: entry.providerId)

        // Antigravity 保留路径回退；Codex 已在上方完成原生身份核对。
        if AccountIdentityPolicy.isMultiWorkspace(entry.providerId) {
            let livePath = entry.liveProvider?.sourceFilePath ?? entry.storedAccount?.sourceFilePath
            if let livePath {
                let pathMatches = credentials.filter { credential in
                    AccountIdentityPolicy.sourceFilePathsMatch(
                        AccountIdentityPolicy.credentialAuthFilePath(credential),
                        livePath
                    )
                }
                if !pathMatches.isEmpty {
                    return pathMatches
                }
            }

            return []
        }

        let identityTokens = accountIdentityTokens(for: entry)
        guard !identityTokens.isEmpty else { return [] }
        return credentials.filter { credential in
            let credentialTokens = Set([
                credential.metadata["accountId"]?.lowercased().nilIfBlank,
                credential.metadata["accountEmail"]?.lowercased().nilIfBlank,
                credential.metadata["accountHandle"]?.lowercased().nilIfBlank,
                credential.accountLabel?.lowercased().nilIfBlank
            ].compactMap { $0 })
            return !identityTokens.isDisjoint(with: credentialTokens)
        }
    }

    func matchingStoredAccountIndices(for entry: ProviderAccountEntry) -> [Int] {
        var indices = Set<Int>()

        if let storedId = entry.storedAccount?.id,
           let exactIndex = accountRegistry.firstIndex(where: { $0.id == storedId }) {
            indices.insert(exactIndex)
        }

        if let liveProvider = entry.liveProvider {
            for (index, stored) in accountRegistry.enumerated() where
                AccountIdentityPolicy.matchesLive(stored: stored, provider: liveProvider) {
                indices.insert(index)
            }
        }

        if AccountIdentityPolicy.isMultiWorkspace(entry.providerId) {
            if entry.providerId == "codex" {
                if let account = entry.storedAccount {
                    for (index, stored) in accountRegistry.enumerated() where stored.providerId == "codex" {
                        if AccountIdentityPolicy.codexAccountsMatch(stored, account) { indices.insert(index) }
                    }
                }
                return indices.sorted()
            }
            let livePath = entry.liveProvider?.sourceFilePath ?? entry.storedAccount?.sourceFilePath
            if let livePath {
                for (index, stored) in accountRegistry.enumerated() where stored.providerId == entry.providerId {
                    if AccountIdentityPolicy.sourceFilePathsMatch(stored.sourceFilePath, livePath) {
                        indices.insert(index)
                    }
                }
            }
            return indices.sorted()
        }

        let identityTokens = accountIdentityTokens(for: entry)
        if !identityTokens.isEmpty {
            for (index, stored) in accountRegistry.enumerated() where stored.providerId == entry.providerId {
                let storedTokens = Set([
                    stored.normalizedEmail.nilIfBlank,
                    stored.normalizedAccountId,
                    stored.displayName?.lowercased().nilIfBlank,
                    stored.credentialId?.lowercased().nilIfBlank
                ].compactMap { $0 })
                if !identityTokens.isDisjoint(with: storedTokens) {
                    indices.insert(index)
                }
            }
        }

        return indices.sorted()
    }

    func accountIdentityTokens(for entry: ProviderAccountEntry) -> Set<String> {
        Set([
            entry.storedAccount?.normalizedEmail.nilIfBlank,
            entry.storedAccount?.normalizedAccountId,
            entry.storedAccount?.displayName?.lowercased().nilIfBlank,
            entry.storedAccount?.credentialId?.lowercased().nilIfBlank,
            entry.accountEmail?.lowercased().nilIfBlank,
            entry.accountDisplayName?.lowercased().nilIfBlank,
            entry.liveProvider?.accountId?.lowercased().nilIfBlank,
            entry.liveProvider?.accountLabel?.lowercased().nilIfBlank
        ].compactMap { $0 })
    }
}
