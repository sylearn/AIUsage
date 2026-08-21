import Foundation
import QuotaBackend

extension ProviderRefreshCoordinator {
    // MARK: - Fetch pipeline

    @MainActor
    func fetchAccountByCredential(
        credentialId: String,
        providerId: String
    ) async -> ProviderRefreshResult {
        guard settings.backendMode == "local" else {
            return .failure()
        }
        guard let result = await engine.fetchForCredential(providerId: providerId, credentialId: credentialId),
              result.summary != nil else {
            return .failure()
        }
        // convert + localize 在后台执行器完成（Task.detached），主线程只拿回结果。
        let language = self.language
        let convertedBatch = await Task.detached { [self] in
            localizedProviderResults(from: [result], language: language)
        }.value
        guard let converted = convertedBatch.first?.provider else {
            return .failure()
        }
        await accountStore.reconcileAccountRegistry(with: [converted])

        if let index = providers.firstIndex(where: { $0.id == converted.id }) {
            providers[index] = converted
        } else if let index = providers.firstIndex(where: {
            $0.baseProviderId == providerId && $0.id.contains(credentialId)
        }) {
            providers[index] = converted
        } else if !isProviderHidden(converted) {
            providers.append(converted)
            providers = providers.sorted(by: providerSort)
        }

        guard result.ok,
              let refreshedProvider = currentProviderMatchingRefresh(converted) else {
            return .failure()
        }
        return .success(refreshedProviders: [refreshedProvider])
    }

    @MainActor
    func syncUnifiedManagedAccounts(for providerIds: [String]) async {
        guard settings.backendMode == "local" else { return }

        let uniqueProviderIDs = Array(Set(providerIds)).sorted()
        guard !uniqueProviderIDs.isEmpty else { return }

        for providerId in uniqueProviderIDs {
            let candidates = ProviderAuthManager.unmanagedCandidates(for: providerId)
            guard !candidates.isEmpty else { continue }

            for candidate in candidates {
                let backoffKey = discoveryBackoffKey(for: candidate)
                if let retryAfter = discoveryFailureBackoff[backoffKey], retryAfter > Date() {
                    continue
                }

                do {
                    let (credential, usage) = try await ProviderAuthManager.authenticateCandidate(candidate)
                    if shouldSuppressAutoManagedAccount(
                        providerId: providerId,
                        usage: usage,
                        credential: credential
                    ) {
                        discoveryFailureBackoff[backoffKey] = Date().addingTimeInterval(discoveryFailureCooldown)
                        continue
                    }

                    try registerAuthenticatedCredential(
                        credential,
                        usage: usage,
                        note: nil,
                        providerDisplayTitle: providerTitleForId(providerId)
                    )
                    discoveryFailureBackoff.removeValue(forKey: backoffKey)
                } catch {
                    discoveryFailureBackoff[backoffKey] = Date().addingTimeInterval(discoveryFailureCooldown)
                }
            }
        }
    }

    func discoveryBackoffKey(for candidate: ProviderAuthCandidate) -> String {
        [
            candidate.providerId,
            candidate.sourceIdentifier,
            candidate.sessionFingerprint ?? "",
            candidate.title.lowercased()
        ].joined(separator: "|")
    }

    func normalizedAccountLookupValue(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    func shouldSuppressAutoManagedAccount(
        providerId: String,
        usage: ProviderUsage,
        credential: AccountCredential? = nil
    ) -> Bool {
        let normalizedEmail = normalizedAccountLookupValue(
            usage.accountEmail?.nilIfBlank
                ?? usage.accountLogin?.nilIfBlank
                ?? usage.accountName?.nilIfBlank
        )
        let normalizedAccountId = normalizedAccountLookupValue(
            usage.usageAccountId?.nilIfBlank
                ?? usage.accountLogin?.nilIfBlank
        )
        let sourceFilePath = credential.flatMap(AccountIdentityPolicy.credentialAuthFilePath)

        return accountStore.hasHiddenRegistryMatch(
            providerId: providerId,
            normalizedEmail: normalizedEmail,
            normalizedAccountId: normalizedAccountId,
            sourceFilePath: sourceFilePath
        )
    }

    @MainActor
    func fetchSingleProviderLocal(_ providerId: String) async -> ProviderRefreshResult {
        let refreshedAt = Date()
        await syncUnifiedManagedAccounts(for: [providerId])
        let language = self.language

        if let results = await engine.fetchMultiAccountProvider(id: providerId) {
            // convert + localize 在后台执行器完成（Task.detached），主线程只拿回结果。
            let convertedResults = await Task.detached { [self] in
                localizedProviderResults(from: results, language: language)
            }.value
            let stabilizedResults = stabilizedBulkRefreshProviders(
                convertedResults.map(\.provider),
                preservingExistingFor: providerId
            )
            await accountStore.reconcileAccountRegistry(with: stabilizedResults)
            let visible = visibleProviders(from: stabilizedResults)
            replaceProviderEntries(for: providerId, with: visible)
            return .classified(
                totalResults: results.count,
                refreshedProviders: timestampableProviders(
                    for: convertedResults.filter(\.ok).map(\.provider)
                ),
                at: refreshedAt
            )
        } else if let result = await engine.fetchSingle(id: providerId),
                  result.summary != nil {
            let convertedResults = await Task.detached { [self] in
                localizedProviderResults(from: [result], language: language)
            }.value
            guard let converted = convertedResults.first?.provider else { return .failure() }
            await accountStore.reconcileAccountRegistry(with: [converted])
            replaceProviderEntries(for: providerId, with: visibleProviders(from: [converted]))
            return .classified(
                totalResults: 1,
                refreshedProviders: result.ok ? timestampableProviders(for: [converted]) : [],
                at: refreshedAt
            )
        }
        return .failure()
    }

    @MainActor
    func fetchSingleProviderRemote(_ providerId: String) async -> ProviderRefreshResult {
        let refreshedAt = Date()
        APIService.shared.updateBaseURL("http://\(settings.remoteHost):\(settings.remotePort)")
        do {
            let results = try await APIService.shared.fetchProviderResults(providerId)
            // 主线程仅重组为 Sendable 元组（无正则），本地化在后台执行器完成。
            let language = self.language
            let remoteItems = results.map { (provider: $0.summary, ok: $0.ok) }
            let localizedProviders = await Task.detached { [self] in
                localizedProviderList(remoteItems, language: language)
            }.value
            await accountStore.reconcileAccountRegistry(with: localizedProviders.map(\.provider))
            replaceProviderEntries(
                for: providerId,
                with: visibleProviders(from: localizedProviders.map(\.provider))
            )
            return .classified(
                totalResults: results.count,
                refreshedProviders: timestampableProviders(
                    for: localizedProviders.filter(\.ok).map(\.provider)
                ),
                at: refreshedAt
            )
        } catch {
            let redactedError = SensitiveDataRedactor.redactedMessage(for: error)
            sendErrorNotification("Remote refresh failed for \(providerId): \(redactedError)")
            return .failure(
                userMessage: !providers.contains(where: { $0.baseProviderId == providerId })
                    ? redactedError
                    : nil
            )
        }
    }

    @MainActor
    func fetchDashboardLocal() async -> ProviderRefreshResult {
        let refreshedAt = Date()
        await syncUnifiedManagedAccounts(for: selectedProviderIDList())

        let snapshot = await engine.fetchAll(ids: selectedProviderIDList())
        // 整批 convert + localize（含 overview）在后台执行器完成，主线程只做赋值与 UI 协调。
        let language = self.language
        let batch = await Task.detached { [self] in
            localizedDashboard(from: snapshot, language: language)
        }.value
        let localizedProviders = batch.providers
        let stabilizedProviders = stabilizedBulkRefreshProviders(localizedProviders.map(\.provider))
        await accountStore.reconcileAccountRegistry(with: stabilizedProviders)
        providers = visibleProviders(from: stabilizedProviders)
        overview = batch.overview
        return .classified(
            totalResults: snapshot.providers.count,
            refreshedProviders: localizedProviders.filter(\.ok).map(\.provider),
            at: refreshedAt
        )
    }

    @MainActor
    func fetchDashboardRemote(showMessageOnFailure: Bool) async -> ProviderRefreshResult {
        let refreshedAt = Date()
        APIService.shared.updateBaseURL("http://\(settings.remoteHost):\(settings.remotePort)")
        do {
            let dashboard = try await APIService.shared.fetchDashboard(providerIds: selectedProviderIDList())
            // 主线程仅重组为 Sendable 元组（无正则）；providers + overview 本地化在后台执行器完成。
            let language = self.language
            let remoteItems = dashboard.providers.map { (provider: $0.summary, ok: $0.ok) }
            let remoteOverview = dashboard.overview
            let batch = await Task.detached { [self] in
                localizedRemoteDashboard(remoteItems, overview: remoteOverview, language: language)
            }.value
            let localizedProviders = batch.providers
            let stabilizedProviders = stabilizedBulkRefreshProviders(localizedProviders.map(\.provider))
            await accountStore.reconcileAccountRegistry(with: stabilizedProviders)
            providers = visibleProviders(from: stabilizedProviders)
            overview = batch.overview
            return .classified(
                totalResults: dashboard.providers.count,
                refreshedProviders: localizedProviders.filter(\.ok).map(\.provider),
                at: refreshedAt
            )
        } catch {
            return .failure(
                userMessage: showMessageOnFailure
                    ? SensitiveDataRedactor.redactedMessage(for: error)
                    : nil
            )
        }
    }

    func selectedProviderIDList() -> [String] {
        providerCatalogIds().filter { selectedProviderIds().contains($0) }
    }

    func replaceProviderEntries(for providerId: String, with replacements: [ProviderData]) {
        providers.removeAll { $0.baseProviderId == providerId }
        providers.append(contentsOf: replacements)
        providers = providers.sorted(by: providerSort)
    }

    func completeGlobalRefresh(_ result: ProviderRefreshResult) {
        guard result.shouldUpdateTimestamps,
              let refreshedAt = result.refreshedAt else {
            return
        }

        let currentProviders = timestampableProviders(for: result.refreshedProviders)
        guard !currentProviders.isEmpty else { return }

        lastRefreshTime = refreshedAt
        for providerId in Set(currentProviders.map(\.baseProviderId)) {
            providerRefreshTimes[providerId] = refreshedAt
        }
        for provider in currentProviders {
            markAccountRefreshed(provider, at: refreshedAt)
        }
    }

    func completeProviderRefresh(providerId: String, result: ProviderRefreshResult) {
        guard result.shouldUpdateTimestamps,
              let refreshedAt = result.refreshedAt else {
            return
        }

        let currentProviders = timestampableProviders(for: result.refreshedProviders)
        guard !currentProviders.isEmpty else { return }

        providerRefreshTimes[providerId] = refreshedAt
        for provider in currentProviders where provider.baseProviderId == providerId {
            markAccountRefreshed(provider, at: refreshedAt)
        }
    }

    func completeAccountRefresh(refreshKey: String, result: ProviderRefreshResult) {
        guard result.shouldUpdateTimestamps,
              let refreshedAt = result.refreshedAt else {
            return
        }

        accountRefreshTimes[refreshKey] = refreshedAt
        for provider in result.refreshedProviders {
            markAccountRefreshed(provider, at: refreshedAt)
        }
    }

    func markAccountRefreshed(_ provider: ProviderData, at refreshedAt: Date) {
        for key in accountRefreshKeys(for: provider) {
            accountRefreshTimes[key] = refreshedAt
        }
    }

    func accountRefreshKeys(for provider: ProviderData) -> [String] {
        var keys: [String] = []

        func append(_ key: String?) {
            guard let key, !keys.contains(key) else { return }
            keys.append(key)
        }

        if let credentialId = credentialID(for: provider)?.nilIfBlank {
            append(accountRefreshKey(providerId: provider.baseProviderId, credentialId: credentialId))
        }

        if let storedAccount = accountStore.accountRegistry.first(where: {
            !$0.isHidden && accountStore.matchesStoredWithLive($0, provider: provider)
        }) {
            append(accountRefreshKey(providerId: provider.baseProviderId, storedAccountId: storedAccount.id))
        }

        if let normalizedAccountId = normalizedAccountLookupValue(provider.accountId) {
            append(accountRefreshKey(providerId: provider.baseProviderId, identity: "account:\(normalizedAccountId)"))
        }

        if let normalizedLabel = normalizedAccountLookupValue(provider.accountLabel ?? provider.label) {
            append(accountRefreshKey(providerId: provider.baseProviderId, identity: "label:\(normalizedLabel)"))
        }

        append(accountRefreshKey(providerId: provider.baseProviderId, providerDataId: provider.id))
        return keys
    }

    func accountRefreshKey(providerId: String, credentialId: String) -> String {
        "\(providerId):cred:\(credentialId.lowercased())"
    }

    func accountRefreshKey(providerId: String, storedAccountId: String) -> String {
        "\(providerId):stored:\(storedAccountId.lowercased())"
    }

    func accountRefreshKey(providerId: String, identity: String) -> String {
        "\(providerId):identity:\(identity.lowercased())"
    }

    func accountRefreshKey(providerId: String, providerDataId: String) -> String {
        "\(providerId):live:\(providerDataId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    func timestampableProviders(for refreshedProviders: [ProviderData]) -> [ProviderData] {
        providers.filter { provider in
            refreshedProviders.contains { refreshed in
                providerMatchesRefresh(provider, refreshed: refreshed)
            }
        }
    }

    func currentProviderMatchingRefresh(_ refreshedProvider: ProviderData) -> ProviderData? {
        providers.first { provider in
            providerMatchesRefresh(provider, refreshed: refreshedProvider)
        }
    }

    func providerMatchesRefresh(_ current: ProviderData, refreshed: ProviderData) -> Bool {
        guard current.baseProviderId == refreshed.baseProviderId else { return false }

        if current.id.caseInsensitiveCompare(refreshed.id) == .orderedSame {
            return true
        }

        if let currentCredential = credentialID(for: current)?.lowercased().nilIfBlank,
           let refreshedCredential = credentialID(for: refreshed)?.lowercased().nilIfBlank,
           currentCredential == refreshedCredential {
            return true
        }

        if let currentAccountId = normalizedAccountLookupValue(current.accountId),
           let refreshedAccountId = normalizedAccountLookupValue(refreshed.accountId),
           currentAccountId == refreshedAccountId {
            return true
        }

        if let currentLabel = normalizedAccountLookupValue(current.accountLabel ?? current.label),
           let refreshedLabel = normalizedAccountLookupValue(refreshed.accountLabel ?? refreshed.label),
           currentLabel == refreshedLabel {
            return true
        }

        return false
    }

    func stabilizedBulkRefreshProviders(
        _ incomingProviders: [ProviderData],
        preservingExistingFor targetProviderId: String? = nil
    ) -> [ProviderData] {
        let groupedIncoming = Dictionary(grouping: incomingProviders, by: \.baseProviderId)
        let providerIDs = targetProviderId.map { [$0] } ?? Array(Set(incomingProviders.map(\.baseProviderId)))

        var stabilized: [ProviderData] = []
        for providerId in providerIDs {
            let incoming = groupedIncoming[providerId] ?? []
            stabilized.append(contentsOf: stabilizedBulkRefreshProviders(for: providerId, incoming: incoming))
        }

        return deduplicatedProvidersByID(stabilized).sorted(by: providerSort)
    }

    func stabilizedBulkRefreshProviders(
        for providerId: String,
        incoming: [ProviderData]
    ) -> [ProviderData] {
        let storedAccounts = accountStore.accountRegistry.filter { $0.providerId == providerId && !$0.isHidden }
        guard !storedAccounts.isEmpty else {
            return deduplicatedProvidersByID(incoming)
        }

        let existingProviders = providers.filter { $0.baseProviderId == providerId }
        var remainingIncoming = incoming
        var selected: [ProviderData] = []

        for storedAccount in storedAccounts {
            let incomingMatches = remainingIncoming.filter { accountStore.matchesStoredWithLive(storedAccount, provider: $0) }
            let existingMatches = existingProviders.filter { accountStore.matchesStoredWithLive(storedAccount, provider: $0) }

            let incomingBest = preferredLiveProvider(among: incomingMatches, storedAccount: storedAccount)
            let existingBest = preferredLiveProvider(among: existingMatches, storedAccount: storedAccount)
            if let chosen = preferredBulkRefreshProvider(incoming: incomingBest, existing: existingBest) {
                selected.append(chosen)
            }

            if !incomingMatches.isEmpty {
                let consumedIDs = Set(incomingMatches.map(\.id))
                remainingIncoming.removeAll { consumedIDs.contains($0.id) }
            }
        }

        let unmatchedIncoming = Dictionary(grouping: remainingIncoming, by: liveProviderIdentity(_:))
            .values
            .compactMap { preferredLiveProvider(among: Array($0), storedAccount: nil) }
            .filter { candidate in
                // Drop generic "not connected" placeholders once a healthy live exists for this provider.
                guard candidate.needsCredentialConnection else { return true }
                let hasHealthyLive = selected.contains {
                    $0.status != .error && !$0.needsCredentialConnection
                }
                if hasHealthyLive { return false }
                // Path-less auto placeholders (e.g. codex:auto:default) are not real accounts.
                if candidate.sourceFilePath == nil,
                   candidate.id.localizedCaseInsensitiveContains(":auto:") {
                    return false
                }
                return true
            }

        selected.append(contentsOf: unmatchedIncoming)
        return deduplicatedProvidersByID(selected)
    }

    func preferredBulkRefreshProvider(
        incoming: ProviderData?,
        existing: ProviderData?
    ) -> ProviderData? {
        // A completed refresh must be able to replace the on-screen card,
        // including when the new result is an error. Keeping a previous
        // healthy card here made Codex look like bulk refresh did nothing.
        if let incoming { return incoming }
        return existing
    }

    func deduplicatedProvidersByID(_ providers: [ProviderData]) -> [ProviderData] {
        var seen = Set<String>()
        var deduplicated: [ProviderData] = []

        for provider in providers where seen.insert(provider.id).inserted {
            deduplicated.append(provider)
        }

        return deduplicated
    }

    func providerSort(_ lhs: ProviderData, _ rhs: ProviderData) -> Bool {
        let providerOrder = providerCatalogIds()
        let lhsProviderIndex = providerOrder.firstIndex(of: lhs.baseProviderId) ?? Int.max
        let rhsProviderIndex = providerOrder.firstIndex(of: rhs.baseProviderId) ?? Int.max

        if lhsProviderIndex != rhsProviderIndex {
            return lhsProviderIndex < rhsProviderIndex
        }

        let lhsIdentity = (lhs.accountLabel ?? lhs.accountId ?? lhs.id).lowercased()
        let rhsIdentity = (rhs.accountLabel ?? rhs.accountId ?? rhs.id).lowercased()
        return lhsIdentity.localizedCaseInsensitiveCompare(rhsIdentity) == .orderedAscending
    }

    func extractCredentialId(from providerDataId: String) -> String? {
        guard let range = providerDataId.range(of: ":cred:") else { return nil }
        return String(providerDataId[range.upperBound...]).nilIfBlank
    }

    func credentialID(for provider: ProviderData) -> String? {
        if let direct = extractCredentialId(from: provider.id) {
            return direct
        }

        return accountStore.accountRegistry.first(where: {
            !$0.isHidden && accountStore.matchesStoredWithLive($0, provider: provider)
        })?.credentialId?.nilIfBlank
    }

    func visibleProviders(from providers: [ProviderData]) -> [ProviderData] {
        providers.filter { !isProviderHidden($0) }
    }

    func isProviderHidden(_ provider: ProviderData) -> Bool {
        let hasHiddenMatch = accountStore.accountRegistry.contains {
            $0.isHidden && accountStore.matchesStoredWithLive($0, provider: provider)
        }
        guard hasHiddenMatch else { return false }
        let hasVisibleMatch = accountStore.accountRegistry.contains {
            !$0.isHidden && accountStore.matchesStoredWithLive($0, provider: provider)
        }
        return !hasVisibleMatch
    }

    func normalizedLiveAccountID(for provider: ProviderData) -> String? {
        provider.accountId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    func normalizedAccountIdentifier(for provider: ProviderData) -> String? {
        guard let raw = provider.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw.lowercased()
    }

    func liveProviderIdentity(_ provider: ProviderData) -> String {
        let pid = provider.baseProviderId
        if AccountIdentityPolicy.isMultiWorkspace(pid) {
            // Codex: same workspace (accountId) collapses AuthImports vs ~/.codex;
            // different workspaces keep different accountIds → separate cards.
            if pid.lowercased() == "codex",
               let accountId = normalizedLiveAccountID(for: provider) {
                return "\(pid):account:\(accountId)"
            }
            if let path = provider.sourceFilePath?.nilIfBlank {
                return "\(pid):path:\(AccountCredentialStore.normalizedAuthFilePath(path))"
            }
            return "\(pid):result:\(provider.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        }
        if let accountId = normalizedLiveAccountID(for: provider) {
            return "\(pid):id:\(accountId)"
        }
        if let label = normalizedAccountIdentifier(for: provider) {
            return "\(pid):label:\(label)"
        }
        return "\(pid):result:\(provider.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    func preferredLiveProvider(
        among candidates: [ProviderData],
        storedAccount: StoredProviderAccount?
    ) -> ProviderData? {
        candidates.max { lhs, rhs in
            let lhsScore = liveProviderScore(lhs, storedAccount: storedAccount)
            let rhsScore = liveProviderScore(rhs, storedAccount: storedAccount)
            if lhsScore != rhsScore {
                return lhsScore < rhsScore
            }
            return providerSort(lhs, rhs)
        }
    }

    func liveProviderScore(
        _ provider: ProviderData,
        storedAccount: StoredProviderAccount?
    ) -> Int {
        var score = 0

        if provider.status != .error {
            score += 80
        }
        if provider.accountId?.nilIfBlank != nil {
            score += 20
        }
        if provider.accountLabel?.nilIfBlank != nil {
            score += 20
        }
        if provider.membershipLabel?.nilIfBlank != nil {
            score += 10
        }
        if provider.remainingPercent != nil {
            score += 5
        }
        score += min(provider.metrics.count, 3) * 2
        score += min(provider.windows.count, 3) * 3

        if provider.id.contains(":cred:") {
            score += 8
        }
        if provider.id.contains(":auto:") {
            score += 4
        }

        guard let storedAccount else { return score }

        let liveID = provider.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let credentialId = storedAccount.credentialId?.nilIfBlank,
           extractCredentialId(from: provider.id) == credentialId {
            score += 400
        }

        if let storedResultId = storedAccount.normalizedProviderResultId {
            if storedResultId == liveID {
                score += 300
            } else if liveID.hasPrefix(storedResultId + ":") || storedResultId.hasPrefix(liveID + ":") {
                score += 240
            }
        }

        if let storedAccountId = storedAccount.normalizedAccountId,
           let liveAccountId = normalizedLiveAccountID(for: provider),
           storedAccountId == liveAccountId {
            score += 160
        }

        if storedAccount.normalizedEmail == normalizedAccountIdentifier(for: provider) {
            score += 120
        }

        return score
    }
}
