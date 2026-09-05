import Foundation
import Combine
import os.log
import QuotaBackend

internal let providerRefreshLog = Logger(subsystem: "com.aiusage.desktop", category: "ProviderRefresh")

// MARK: - ProviderRefreshCoordinator
// Owns provider snapshot refresh, dashboard fetch, localization of fetched data, and account-registry reconciliation.

final class ProviderRefreshCoordinator: ObservableObject {
    static let shared = ProviderRefreshCoordinator()

    @Published var providers: [ProviderData] = []
    @Published var overview: DashboardOverview?
    @Published var isLoading = true
    /// 是否完成过首次全量刷新。用于区分「首次加载中（还没拿到任何网络数据）」与
    /// 「确实没有数据」——前者不应展示「凭证过期/没有账号」这类吓人的空态。
    @Published private(set) var hasCompletedInitialLoad = false
    @Published var errorMessage: String?
    @Published var lastRefreshTime: Date?
    @Published var isRefreshingAllProviders = false
    @Published private(set) var refreshingProviderIDs: Set<String> = []
    @Published private(set) var refreshingAccountIDs: Set<String> = []
    @Published var providerRefreshTimes: [String: Date] = [:]
    @Published var accountRefreshTimes: [String: Date] = [:]

    let engine = ProviderEngine()
    private var refreshTimer: Timer?
    private var claudeCodeRefreshTimer: Timer?
    private var isCodexFullHistoryRefreshInProgress = false

    /// Used by toolbar / menu bar "Refresh All" buttons to decide between the
    /// spinner and the affordance. Intentionally narrow: single-provider or
    /// single-account refreshes can run for several minutes (Codex archive
    /// import has a 300s timeout), so they must NOT lock out the global
    /// "Refresh All" affordance. Callers that need a stricter "any refresh in
    /// progress" check should compose `refreshingProviderIDs` and
    /// `refreshingAccountIDs` explicitly at the call site.
    var isAnyRefreshInProgress: Bool {
        isLoading || isRefreshingAllProviders
    }

    let settings = AppSettings.shared
    let accountStore = AccountStore.shared

    var discoveryFailureBackoff: [String: Date] = [:]
    let discoveryFailureCooldown: TimeInterval = 5 * 60

    var selectedProviderIds: () -> Set<String> = { [] }
    var providerCatalogIds: () -> [String] = { [] }
    var ensureProviderSelected: (String) -> Void = { _ in }
    var providerTitleForId: (String) -> String = { $0 }

    private init() {
        setupAutoRefresh()
        setupClaudeCodeAutoRefresh()
    }

    func configure(
        selectedProviderIds: @escaping () -> Set<String>,
        providerCatalogIds: @escaping () -> [String],
        ensureProviderSelected: @escaping (String) -> Void,
        providerTitleForId: @escaping (String) -> String
    ) {
        self.selectedProviderIds = selectedProviderIds
        self.providerCatalogIds = providerCatalogIds
        self.ensureProviderSelected = ensureProviderSelected
        self.providerTitleForId = providerTitleForId
    }

    // MARK: - Timers

    func setupAutoRefresh() {
        refreshTimer?.invalidate()
        let normalized = AppSettings.normalizedAutoRefreshInterval(settings.autoRefreshInterval)
        if settings.autoRefreshInterval != normalized {
            settings.autoRefreshInterval = normalized
        }

        if settings.autoRefreshInterval > 0 {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.autoRefreshInterval), repeats: true) { [weak self] _ in
                self?.refreshAllProviders()
            }
        }
    }

    func setupClaudeCodeAutoRefresh() {
        claudeCodeRefreshTimer?.invalidate()
        let normalized = AppSettings.normalizedClaudeCodeRefreshInterval(settings.claudeCodeRefreshInterval)
        if settings.claudeCodeRefreshInterval != normalized {
            settings.claudeCodeRefreshInterval = normalized
        }

        if settings.claudeCodeRefreshInterval > 0 {
            claudeCodeRefreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.claudeCodeRefreshInterval), repeats: true) { [weak self] _ in
                self?.refreshLocalTokenStatsOnly()
            }
        }
    }

    // MARK: - Public refresh API

    func refreshAllProviders() {
        Task { @MainActor in
            guard !isRefreshingAllProviders else { return }
            isRefreshingAllProviders = true
            defer { isRefreshingAllProviders = false }
            _ = await fetchDashboard()
        }
    }

    func refreshLocalTokenStatsOnly() {
        Task { @MainActor in
            // Claude（及 Codex 代理轨）统计读取代理用量永久归档；先把待写入的脏日期
            // 入档落盘（异步等待后台写盘完成），确保引擎随后读到的归档反映最新请求。
            await ProxyViewModel.shared.flushPersistenceAsync()
            // Fan-out so a slow `codex-cost` (300s archive timeout) cannot
            // hold up Claude's refresh. Each call goes through
            // `refreshingProviderIDs` so concurrent refreshes of the same
            // provider still deduplicate inside `refreshProviderNow`.
            let active = ["claude", "codex-cost", "opencode"].filter(selectedProviderIds().contains)
            await withTaskGroup(of: Void.self) { group in
                for providerId in active {
                    group.addTask { @MainActor [weak self] in
                        await self?.refreshProviderNow(providerId)
                    }
                }
            }
            checkClaudeDailyThreshold()
        }
    }

    func refreshCodexCostFullHistoryIfNeeded() {
        Task { @MainActor in
            let providerId = "codex-cost"

            // Front-load the cheap guards so we don't flip the in-progress
            // flag for refreshes that would have bailed anyway. The flag now
            // only covers the actual async work that competes with itself.
            guard settings.backendMode == "local",
                  selectedProviderIds().contains(providerId),
                  !refreshingProviderIDs.contains(providerId),
                  let provider = ProviderRegistry.provider(for: providerId) as? CodexCostProvider,
                  !isCodexFullHistoryRefreshInProgress else {
                return
            }

            isCodexFullHistoryRefreshInProgress = true
            defer { isCodexFullHistoryRefreshInProgress = false }

            guard await provider.needsFullHistoryImport() else { return }
            await provider.requestFullHistoryImport()
            await refreshProviderNow(providerId)
        }
    }

    func refreshProvider(_ providerId: String) {
        Task { @MainActor in
            await refreshProviderNow(providerId)
        }
    }

    func refreshProviderCard(_ provider: ProviderData) {
        Task {
            await refreshProviderCardNow(provider)
        }
    }

    @MainActor
    func refreshProviderCardNow(_ provider: ProviderData) async {
        if let credentialId = credentialID(for: provider) {
            await refreshAccountNow(credentialId: credentialId, providerId: provider.baseProviderId)
        } else {
            await refreshProviderNow(provider.baseProviderId)
        }
    }

    func refreshAccount(credentialId: String, providerId: String) {
        Task {
            await refreshAccountNow(credentialId: credentialId, providerId: providerId)
        }
    }

    @MainActor
    func refreshProviderNow(_ providerId: String) async {
        guard selectedProviderIds().contains(providerId),
              !refreshingProviderIDs.contains(providerId) else { return }
        refreshingProviderIDs.insert(providerId)
        defer { refreshingProviderIDs.remove(providerId) }
        errorMessage = nil
        let result = await fetchSingleProvider(providerId)
        completeProviderRefresh(providerId: providerId, result: result)
        errorMessage = result.userMessage
    }

    @MainActor
    func refreshAccountNow(credentialId: String, providerId: String) async {
        guard selectedProviderIds().contains(providerId) else { return }
        let refreshKey = accountRefreshKey(providerId: providerId, credentialId: credentialId)
        guard !refreshingAccountIDs.contains(refreshKey) else { return }
        refreshingAccountIDs.insert(refreshKey)
        defer { refreshingAccountIDs.remove(refreshKey) }
        errorMessage = nil
        let result = await fetchAccountByCredential(
            credentialId: credentialId,
            providerId: providerId
        )
        completeAccountRefresh(refreshKey: refreshKey, result: result)
        errorMessage = result.userMessage
    }

    @MainActor
    func fetchSingleProvider(_ providerId: String) async -> ProviderRefreshResult {
        guard selectedProviderIds().contains(providerId) else {
            return .failure()
        }
        if settings.backendMode == "local" {
            return await fetchSingleProviderLocal(providerId)
        } else {
            return await fetchSingleProviderRemote(providerId)
        }
    }

    @MainActor
    @discardableResult
    func fetchDashboard() async -> ProviderRefreshResult {
        let isInitialLoad = providers.isEmpty && overview == nil
        if isInitialLoad { isLoading = true }
        errorMessage = nil

        guard !selectedProviderIds().isEmpty else {
            providers = []
            overview = localizeOverview(convertOverview(UsageNormalizer.createDashboardOverview(
                summaries: [],
                generatedAt: SharedFormatters.iso8601String(from: Date())
            )), language: language)
            isLoading = false
            hasCompletedInitialLoad = true
            return .emptySuccess()
        }

        let result: ProviderRefreshResult
        if settings.backendMode == "local" {
            result = await fetchDashboardLocal()
        } else {
            result = await fetchDashboardRemote(showMessageOnFailure: providers.isEmpty)
        }

        completeGlobalRefresh(result)
        errorMessage = result.userMessage
        isLoading = false
        hasCompletedInitialLoad = true
        return result
    }

    func registerAuthenticatedCredential(
        _ credential: AccountCredential,
        usage: ProviderUsage,
        note: String?,
        providerDisplayTitle: String
    ) throws {
        try accountStore.registerAuthenticatedCredential(
            credential,
            usage: usage,
            note: note,
            providerDisplayTitle: providerDisplayTitle,
            insertImmediateProviderData: { [weak self] providerId, credentialId, accountLabel, usage in
                self?.insertImmediateProviderData(
                    providerId: providerId,
                    credentialId: credentialId,
                    accountLabel: accountLabel,
                    usage: usage
                )
            },
            ensureProviderSelected: ensureProviderSelected
        )
    }

    func insertImmediateProviderData(
        providerId: String,
        credentialId: String,
        accountLabel: String?,
        usage: ProviderUsage
    ) {
        guard let providerFetcher = ProviderRegistry.provider(for: providerId) else { return }

        var summary = UsageNormalizer.normalize(provider: providerFetcher, usage: usage)
        summary.id = "\(providerId):cred:\(credentialId)"
        summary.providerId = providerId
        summary.accountId = usage.usageAccountId
        if summary.accountLabel?.nilIfBlank == nil {
            summary.accountLabel = accountLabel
        }

        let providerData = localizeProviderData(convertSummary(summary), language: language)

        // 用户首次连接时，旧的「未连接」占位（`not_logged_in` / `missing_token`）必须随凭证写入立刻清掉。
        // 否则 fetchSingleProvider 完成前 UI 会渲染「占位 ghost + 真卡片」两张，连接成功后看到「多出一张空卡」。
        providers.removeAll { $0.baseProviderId == providerId && $0.needsCredentialConnection }

        if let index = providers.firstIndex(where: { $0.id == providerData.id }) {
            providers[index] = providerData
        } else {
            providers.append(providerData)
            providers = providers.sorted(by: providerSort)
        }
    }

    func removeProviders(matchingBaseProviderIds removed: Set<String>) {
        providers.removeAll { removed.contains($0.baseProviderId) }
    }

    func removeProviders(matchingBaseProviderId providerId: String) {
        providers.removeAll { $0.baseProviderId == providerId }
    }

    /// Drop in-memory live rows for a deleted/hidden account so the UI updates before the next refresh.
    func removeLiveProviders(matching entry: ProviderAccountEntry) {
        if let live = entry.liveProvider {
            let identity = liveProviderIdentity(live)
            providers.removeAll {
                if live.baseProviderId == "codex" {
                    return $0.baseProviderId == "codex" && AccountIdentityPolicy.codexLiveAccountsMatch($0, live)
                }
                return $0.id == live.id || liveProviderIdentity($0) == identity
            }
            return
        }

        providers.removeAll { provider in
            guard provider.baseProviderId == entry.providerId else { return false }
            if let stored = entry.storedAccount {
                return accountStore.matchesStoredWithLive(stored, provider: provider)
            }
            return false
        }
    }

    func removeLiveProviders(matching entries: [ProviderAccountEntry]) {
        for entry in entries {
            removeLiveProviders(matching: entry)
        }
    }

    func reapplyVisibleSortedProviders() {
        providers = visibleProviders(from: providers).sorted(by: providerSort)
    }

    func buildProviderEntries(
        providerId: String,
        providerTitle: String,
        providerSubtitle: String?,
        liveProviders: [ProviderData],
        storedAccounts: [StoredProviderAccount]
    ) -> [ProviderAccountEntry] {
        var remainingLive = liveProviders
        var entries: [ProviderAccountEntry] = []
        var codexOwners: [String: String] = [:]
        if providerId == "codex" {
            // 与刷新协调使用同一归属规则，旧记录不能抢走原生身份完整的另一张卡片。
            for live in liveProviders {
                if let owner = AccountIdentityPolicy.bestStoredAccountIndex(
                    in: storedAccounts, for: live, excluding: [], allowUnseenCredentialFallback: false
                ) {
                    codexOwners[live.id] = storedAccounts[owner].id
                }
            }
        }

        for stored in storedAccounts {
            let matches = remainingLive.filter { live in
                if providerId == "codex" {
                    return codexOwners[live.id] == stored.id
                }
                return accountStore.matchesStoredWithLive(stored, provider: live)
            }

            if let preferredLive = preferredLiveProvider(among: matches, storedAccount: stored) {
                let consumedIDs = Set(matches.map(\.id))
                remainingLive.removeAll { consumedIDs.contains($0.id) }
                entries.append(
                    ProviderAccountEntry(
                        id: stored.id,
                        providerId: providerId,
                        providerTitle: providerTitle,
                        providerSubtitle: providerSubtitle,
                        liveProvider: preferredLive,
                        storedAccount: stored
                    )
                )
            } else {
                entries.append(
                    ProviderAccountEntry(
                        id: stored.id,
                        providerId: providerId,
                        providerTitle: providerTitle,
                        providerSubtitle: providerSubtitle,
                        liveProvider: nil,
                        storedAccount: stored
                    )
                )
            }
        }

        let unmatchedLive = Dictionary(grouping: remainingLive, by: liveProviderIdentity(_:))
            .values
            .compactMap { preferredLiveProvider(among: Array($0), storedAccount: nil) }

        for live in unmatchedLive {
            entries.append(
                ProviderAccountEntry(
                    id: live.id,
                    providerId: providerId,
                    providerTitle: providerTitle,
                    providerSubtitle: providerSubtitle,
                    liveProvider: live,
                    storedAccount: nil
                )
            )
        }

        return entries
    }

    func providerRefreshDate(for providerId: String) -> Date? {
        if let refreshedAt = providerRefreshTimes[providerId] {
            return refreshedAt
        }

        return providers
            .filter { $0.baseProviderId == providerId }
            .compactMap { accountRefreshDate(for: $0) }
            .max()
    }

    func accountRefreshDate(for provider: ProviderData) -> Date? {
        for key in accountRefreshKeys(for: provider) {
            if let refreshedAt = accountRefreshTimes[key] {
                return refreshedAt
            }
        }

        guard let fetchedAt = provider.fetchedAt else { return nil }
        return parseISO8601(fetchedAt)
    }

    func isProviderRefreshInFlight(_ providerId: String) -> Bool {
        isRefreshingAllProviders || refreshingProviderIDs.contains(providerId)
    }

    func isRefreshInProgress(for provider: ProviderData) -> Bool {
        if isRefreshingAllProviders || refreshingProviderIDs.contains(provider.baseProviderId) {
            return true
        }

        return accountRefreshKeys(for: provider).contains { refreshingAccountIDs.contains($0) }
    }
}
