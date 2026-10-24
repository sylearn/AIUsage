import SwiftUI
import Combine
import QuotaBackend

// 全局应用状态
class AppState: ObservableObject {
    static let shared = AppState()
    static let mainWindowID = "main-window"
    let settings = AppSettings.shared
    let refreshCoordinator = ProviderRefreshCoordinator.shared

    private struct InitialState {
        let accounts: [StoredProviderAccount]
        let selectedProviderIds: Set<String>
    }

    /// One-shot migration that auto-enrolls existing installs into newly-added
    /// `kind == .costTracking` catalog items. Without this, upgrading users keep their
    /// previously-saved `selectedProviderIds` set forever and never see new local-source
    /// providers (Codex etc.) until they manually opt in via Settings.
    ///
    /// Bumped to `v2` because the original `v1` flag was rolled back in an earlier
    /// review-fix commit; users who already toggled it manually still control their
    /// selection because we only insert, never remove.
    private static let costTrackingSelectionMigrationKey = "selectedProviderIdsMigration.costTracking.v4"

    private static let providerCatalogItems: [ProviderCatalogItem] = [
        ProviderCatalogItem(id: "codex", titleEn: "Codex", titleZh: "Codex", summaryEn: "Official OpenAI subscription windows and quotas", summaryZh: "OpenAI 官方订阅窗口与配额", channel: "cli", kind: .official),
        ProviderCatalogItem(id: "claude-subscription", titleEn: "Claude Subscription", titleZh: "Claude 订阅", summaryEn: "Code subscription quota", summaryZh: "Code 订阅额度", channel: "cli", kind: .official),
        ProviderCatalogItem(id: "copilot", titleEn: "Copilot", titleZh: "Copilot", summaryEn: "GitHub Copilot account entitlements and premium lanes", summaryZh: "GitHub Copilot 账号权益与高级通道", channel: "ide", kind: .official),
        ProviderCatalogItem(id: "cursor", titleEn: "Cursor", titleZh: "Cursor", summaryEn: "Cursor membership allowances and plan usage", summaryZh: "Cursor 会员额度与计划用量", channel: "ide", kind: .official),
        ProviderCatalogItem(id: "antigravity", titleEn: "Antigravity", titleZh: "Antigravity", summaryEn: "Per-model IDE subscription quotas across many model families", summaryZh: "按模型拆分的 IDE 订阅配额", channel: "ide", kind: .official),
        ProviderCatalogItem(id: "kiro", titleEn: "Kiro", titleZh: "Kiro", summaryEn: "Kiro IDE request lanes from the live app account", summaryZh: "来自 Kiro 应用账号的实时请求通道", channel: "ide", kind: .official),
        ProviderCatalogItem(id: "warp", titleEn: "Warp", titleZh: "Warp", summaryEn: "Warp AI credits and bonus grants via the official API", summaryZh: "通过官方接口追踪 Warp AI 积分与奖励积分", channel: "ide", kind: .official),
        ProviderCatalogItem(id: "kimi", titleEn: "Kimi Code", titleZh: "Kimi Code", summaryEn: "Kimi Code subscription weekly usage and rolling rate-limit windows", summaryZh: "Kimi Code 订阅的本周用量与滚动频控窗口", channel: "cli", kind: .official),
        ProviderCatalogItem(id: "minimax", titleEn: "MiniMax Token Plan", titleZh: "MiniMax Token Plan", summaryEn: "MiniMax Token Plan 5-hour rolling and weekly subscription credits", summaryZh: "MiniMax Token Plan 5 小时滚动与周窗口的订阅额度", channel: "cli", kind: .official),
        ProviderCatalogItem(id: "droid", titleEn: "Droid", titleZh: "Droid", summaryEn: "Token-heavy usage pools and remaining allowances", summaryZh: "以 token 为主的额度池与剩余额度", channel: "cli", kind: .official),
        // Google 于 2026-06-18 停止个人账号（免费 / AI Pro / Ultra）使用 Gemini CLI，只剩 Code Assist Standard / Enterprise 可用：保留并标注，排在官方来源末尾。
        ProviderCatalogItem(id: "gemini", titleEn: "Gemini CLI", titleZh: "Gemini CLI", summaryEn: "Gemini Code Assist Standard / Enterprise quotas. Google ended personal-account access on June 18, 2026", summaryZh: "Gemini Code Assist Standard / Enterprise 配额；个人账号已于 2026-06-18 被 Google 停用", channel: "cli", kind: .official, restrictionEn: "Enterprise only", restrictionZh: "仅企业版"),
        ProviderCatalogItem(id: "claude", titleEn: "Claude", titleZh: "Claude", summaryEn: "Proxy costs and Claude Code non-proxy tokens", summaryZh: "Claude 代理费用与 Code 非代理 Token", channel: "local", kind: .costTracking),
        ProviderCatalogItem(id: "codex-cost", titleEn: "Codex", titleZh: "Codex", summaryEn: "Proxy cost ledger plus non-proxy Codex token usage", summaryZh: "Codex 代理费用账本与非代理 Token 用量", channel: "local", kind: .costTracking),
        ProviderCatalogItem(id: "opencode", titleEn: "OpenCode", titleZh: "OpenCode", summaryEn: "Local token and cost ledger from OpenCode sessions", summaryZh: "基于 OpenCode 本地会话的 Token 与费用账本", channel: "local", kind: .costTracking),
        ProviderCatalogItem(id: "antigravity-cost", titleEn: "Antigravity", titleZh: "Antigravity", summaryEn: "Proxy cost ledger plus non-proxy Antigravity token usage", summaryZh: "Antigravity 代理费用账本与非代理 Token 用量", channel: "local", kind: .costTracking)
    ]

    private static let initialState: InitialState = {
        let defaults = UserDefaults.standard
        let accounts = SecureAccountVault.shared.loadAccounts()
        let hasSavedProviderSelection = defaults.object(forKey: DefaultsKey.selectedProviderIds) != nil
        let saved = Set(defaults.stringArray(forKey: DefaultsKey.selectedProviderIds) ?? [])
        let storedProviderIDs = accounts.filter { !$0.isHidden }.map(\.providerId)
        let validIDs = Set(providerCatalogItems.map(\.id))
        var merged = Set(saved.union(storedProviderIDs).filter { validIDs.contains($0) })

        // Auto-enroll existing installs into any newly-added cost-tracking catalog item
        // exactly once. Skip first-launch installs (no saved selection AND no accounts) so
        // the onboarding picker still gets to drive the initial selection. Persist the
        // expanded selection back so future launches see it via the normal saved path.
        if !defaults.bool(forKey: costTrackingSelectionMigrationKey) {
            if hasSavedProviderSelection || !accounts.isEmpty {
                let costTrackingIds = providerCatalogItems
                    .filter { $0.kind == .costTracking }
                    .map(\.id)
                var didInsert = false
                for id in costTrackingIds where !merged.contains(id) {
                    merged.insert(id)
                    didInsert = true
                }
                if didInsert {
                    let orderedSelection = providerCatalogItems.map(\.id).filter { merged.contains($0) }
                    defaults.set(orderedSelection, forKey: DefaultsKey.selectedProviderIds)
                }
            }
            defaults.set(true, forKey: costTrackingSelectionMigrationKey)
        }

        return InitialState(accounts: accounts, selectedProviderIds: merged)
    }()

    var providers: [ProviderData] { refreshCoordinator.providers }
    var overview: DashboardOverview? { refreshCoordinator.overview }
    var isLoading: Bool { refreshCoordinator.isLoading }
    var errorMessage: String? { refreshCoordinator.errorMessage }
    var lastRefreshTime: Date? { refreshCoordinator.lastRefreshTime }
    var isRefreshingAllProviders: Bool { refreshCoordinator.isRefreshingAllProviders }
    let accountStore = AccountStore.shared
    let activationManager = ProviderActivationManager.shared

    typealias ActivationResult = ProviderActivationManager.ActivationResult

    var language: String { settings.language }

    @Published var showSettings = false
    @Published var selectedProviderId: String?
    @Published var selectedSection: AppSection = .dashboard
    @Published var providerPickerMode: ProviderPickerMode?
    @Published var selectedProviderIds: Set<String> = AppState.initialState.selectedProviderIds {
        didSet { providerGroupsCacheDirty = true }
    }

    @Published var readAlertIds: Set<String> = {
        let arr = UserDefaults.standard.stringArray(forKey: DefaultsKey.readAlertIds) ?? []
        return Set(arr)
    }()

    var unreadAlertCount: Int {
        let alerts = overview?.alerts ?? []
        return alerts.filter { !readAlertIds.contains($0.id) }.count
    }

    func markAlertRead(_ id: String) {
        readAlertIds.insert(id)
        UserDefaults.standard.set(Array(readAlertIds), forKey: DefaultsKey.readAlertIds)
    }

    func markAllAlertsRead() {
        let ids = (overview?.alerts ?? []).map { $0.id }
        readAlertIds.formUnion(ids)
        UserDefaults.standard.set(Array(readAlertIds), forKey: DefaultsKey.readAlertIds)
    }

    private var cancellables = Set<AnyCancellable>()
    private var didRunStartupFlow = false
    private var mainWindowPresenter: ((AppSection) -> Void)?

    // MARK: - providerAccountGroups memoization (issue #28)
    // `providerAccountGroups` 是 O(账号×live) 的账号匹配+排序，原先每个视图 body 一读就全量重算，
    // 是数据刷新撞上滑动时主线程的头号热点。改为「失效式记忆化」：任一输入源
    // （selectedProviderIds / accountStore / settings / refreshCoordinator / activationManager）
    // 变更即置脏，读取命中缓存直接返回。internal 以便同模块的 AppState+ProviderGrouping 扩展读写。
    var cachedProviderAccountGroups: [ProviderAccountGroup]?
    var providerGroupsCacheDirty = true

    private init() {
        settings.onRemoteSettingsChanged = { url in
            APIService.shared.updateBaseURL(url)
        }

        accountStore.bootstrapFromDisk(providerCatalogOrder: Self.providerCatalogItems.map(\.id))

        // 补回 AuthImports 中尚未进入订阅列表的 Codex（已存在 / 永久删除则跳过）。
        Task { @MainActor in
            await CLIProxyGatewayManager.shared.backfillSubscriptionAccountsFromAuthImportsIfNeeded()
        }

        // 「共享给其他设备」跟随设置启停；关闭时不监听任何端口。
        Task { @MainActor in
            QuotaShareService.shared.activate()
        }

        refreshCoordinator.configure(
            selectedProviderIds: { [weak self] in self?.selectedProviderIds ?? [] },
            providerCatalogIds: { Self.providerCatalogItems.map(\.id) },
            ensureProviderSelected: { [weak self] providerId in
                guard let self else { return }
                self.selectedProviderIds.insert(providerId)
                self.saveSelectedProviderIds()
            },
            providerTitleForId: { [weak self] id in
                self?.providerCatalogItem(for: id)?.title(for: self?.settings.language ?? "en") ?? id
            }
        )

        activationManager.detectActiveCodexAccount()
        activationManager.detectActiveGeminiAccount()

        // 任一上游源变更都可能改变 providerAccountGroups 的输入，先置脏再转发 objectWillChange。
        activationManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.providerGroupsCacheDirty = true
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        accountStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.providerGroupsCacheDirty = true
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.providerGroupsCacheDirty = true
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        refreshCoordinator.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.providerGroupsCacheDirty = true
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func registerMainWindowPresenter(_ presenter: @escaping (AppSection) -> Void) {
        mainWindowPresenter = presenter
    }

    func presentMainWindow(section: AppSection) {
        selectedSection = section
        restoreDockIconIfMinimizedToTray()

        if let mainWindowPresenter {
            mainWindowPresenter(section)
            return
        }

        bringMainWindowToFront()
    }

    /// issue #39：「关闭时最小化到托盘」收起后从菜单栏唤起主窗口时，把因关窗切到 .accessory 的
    /// Dock 图标恢复回 .regular。用户显式选择「隐藏 Dock 图标」时不恢复（尊重该设置）。
    private func restoreDockIconIfMinimizedToTray() {
        guard !UserDefaults.standard.bool(forKey: DefaultsKey.hideDockIcon) else { return }
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
    }

    func bringMainWindowToFront() {
        NSApp.activate(ignoringOtherApps: true)
        let candidateWindows = NSApp.windows.filter { !($0 is NSPanel) }
        let window = candidateWindows.max(by: { $0.frame.width < $1.frame.width }) ?? candidateWindows.first
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    @MainActor
    func performStartupFlowIfNeeded() async {
        if !didRunStartupFlow {
            didRunStartupFlow = true
            if needsInitialProviderSetup {
                await Task.yield()
                providerPickerMode = .initialSetup
            }
            // 本地 Token 统计（Claude/Codex 日志）不依赖网络，先单独并发拉取，
            // 让热力图/费用卡尽快出现，而不必等所有网络账号刷新完成。
            refreshCoordinator.refreshLocalTokenStatsOnly()
        }
        await refreshCoordinator.fetchDashboard()
    }

    var providerCatalog: [ProviderCatalogItem] {
        Self.providerCatalogItems
    }

    func providerCatalogItem(for id: String) -> ProviderCatalogItem? {
        providerCatalog.first { $0.id == id }
    }

    /// Single source of truth for "is this provider a local token / cost tracking source?".
    /// Treats normalized `category == ProviderCategory.localCost` and catalog
    /// `kind == .costTracking` as equivalent so DashboardView, StatsHubView and
    /// MenuBarView can never drift apart.
    func isLocalCostProvider(_ provider: ProviderData) -> Bool {
        if provider.category == ProviderCategory.localCost { return true }
        return providerCatalogItem(for: provider.baseProviderId)?.kind == .costTracking
    }

    /// Convenience: filter a provider list down to local cost / token tracking sources.
    func localCostProviders(from providers: [ProviderData]) -> [ProviderData] {
        providers.filter(isLocalCostProvider)
    }

    var unselectedProviderCatalog: [ProviderCatalogItem] {
        providerCatalog.filter { !selectedProviderIds.contains($0.id) }
    }

    var needsInitialProviderSetup: Bool {
        selectedProviderIds.isEmpty && accountStore.accountRegistry.isEmpty
    }

    func presentAddProviderPicker() {
        guard !unselectedProviderCatalog.isEmpty else { return }
        providerPickerMode = .add
    }

    func presentManageProviderPicker() {
        providerPickerMode = .manage
    }

    func dismissProviderPicker() {
        providerPickerMode = nil
    }

    func completeInitialProviderSetup(with ids: Set<String>) {
        selectedProviderIds = sanitizedProviderIDs(ids)
        saveSelectedProviderIds()
        providerPickerMode = nil
        refreshAllProviders()
    }

    func addProviders(_ ids: Set<String>) {
        guard !ids.isEmpty else {
            providerPickerMode = nil
            return
        }
        selectedProviderIds.formUnion(sanitizedProviderIDs(ids))
        saveSelectedProviderIds()
        providerPickerMode = nil
        refreshAllProviders()
    }

    func updateProviderSelection(with ids: Set<String>) {
        let sanitized = sanitizedProviderIDs(ids)
        let removed = selectedProviderIds.subtracting(sanitized)

        selectedProviderIds = sanitized
        saveSelectedProviderIds()
        providerPickerMode = nil

        if !removed.isEmpty {
            refreshCoordinator.removeProviders(matchingBaseProviderIds: removed)
        }

        refreshAllProviders()
    }

    func setProviderScanningEnabled(_ providerId: String, isEnabled: Bool) {
        guard providerCatalog.contains(where: { $0.id == providerId }) else { return }

        if isEnabled {
            guard !selectedProviderIds.contains(providerId) else { return }
            selectedProviderIds.insert(providerId)
            saveSelectedProviderIds()
            refreshProvider(providerId)
        } else {
            guard selectedProviderIds.contains(providerId) else { return }
            selectedProviderIds.remove(providerId)
            refreshCoordinator.removeProviders(matchingBaseProviderId: providerId)
            saveSelectedProviderIds()
        }
    }

    func saveAccount(
        providerId: String,
        email: String,
        displayName: String?,
        note: String? = nil,
        accountId: String? = nil,
        credentialId: String? = nil,
        providerResultId: String? = nil
    ) {
        accountStore.saveAccount(
            providerId: providerId,
            email: email,
            displayName: displayName,
            note: note,
            accountId: accountId,
            credentialId: credentialId,
            providerResultId: providerResultId,
            ensureProviderSelected: { [weak self] providerId in
                guard let self else { return }
                self.selectedProviderIds.insert(providerId)
                self.saveSelectedProviderIds()
            }
        )
    }

    /// 返回新账号在仪表盘中的 provider result id，连接弹窗据此展示首批额度。
    @discardableResult
    func registerAuthenticatedCredential(
        _ credential: AccountCredential,
        usage: ProviderUsage,
        note: String? = nil
    ) throws -> String {
        let providerTitle = providerCatalogItem(for: credential.providerId)?.title(for: language) ?? credential.providerId
        return try refreshCoordinator.registerAuthenticatedCredential(
            credential,
            usage: usage,
            note: note,
            providerDisplayTitle: providerTitle
        )
    }

    func updateAccountNote(for entry: ProviderAccountEntry, note: String?) {
        accountStore.updateAccountNote(for: entry, note: note) { [weak self] providerId in
            guard let self else { return }
            if self.selectedProviderIds.insert(providerId).inserted {
                self.saveSelectedProviderIds()
            }
        }
    }

    func restoreAccount(_ storedAccountId: String) {
        accountStore.restoreAccount(storedAccountId) { [weak self] providerId in
            guard let self else { return }
            self.selectedProviderIds.insert(providerId)
            self.saveSelectedProviderIds()
            self.refreshProvider(providerId)
        }
    }

    func deleteAccount(_ entry: ProviderAccountEntry) {
        ClaudeSubscriptionManager.shared.releaseDeletedAccounts([entry])
        accountStore.deleteAccount(entry) { [weak self] in
            self?.refreshCoordinator.removeLiveProviders(matching: entry)
            self?.refreshCoordinator.reapplyVisibleSortedProviders()
        }
    }

    func hideAccount(_ entry: ProviderAccountEntry) {
        hideAccounts([entry])
    }

    func hideAccounts(_ entries: [ProviderAccountEntry]) {
        // 订阅与 CPA 账号池彼此独立：隐藏/删除只影响订阅侧，不联动 disable CPA 副本。
        accountStore.hideAccounts(entries) { [weak self] in
            self?.refreshCoordinator.removeLiveProviders(matching: entries)
            self?.refreshCoordinator.reapplyVisibleSortedProviders()
        }
    }

    func deleteAccounts(_ entries: [ProviderAccountEntry]) {
        ClaudeSubscriptionManager.shared.releaseDeletedAccounts(entries)
        accountStore.deleteAccounts(entries) { [weak self] in
            self?.refreshCoordinator.removeLiveProviders(matching: entries)
            self?.refreshCoordinator.reapplyVisibleSortedProviders()
        }
    }

    func accountNote(for provider: ProviderData) -> String? {
        accountStore.accountNote(for: provider)
    }

    // `providerAccountGroups` and `hiddenAccounts` live in
    // `AppState+ProviderGrouping.swift`.

    func setupAutoRefresh() {
        refreshCoordinator.setupAutoRefresh()
    }

    func setupClaudeCodeAutoRefresh() {
        refreshCoordinator.setupClaudeCodeAutoRefresh()
    }

    func refreshAllProviders() {
        refreshCoordinator.refreshAllProviders()
    }

    func refreshProvider(_ providerId: String) {
        refreshCoordinator.refreshProvider(providerId)
    }

    private func saveSelectedProviderIds() {
        UserDefaults.standard.set(selectedProviderIDList(), forKey: DefaultsKey.selectedProviderIds)
    }

    private func selectedProviderIDList() -> [String] {
        providerCatalog.map(\.id).filter { selectedProviderIds.contains($0) }
    }

    private func sanitizedProviderIDs<S: Sequence>(_ ids: S) -> Set<String> where S.Element == String {
        let validIDs = Set(Self.providerCatalogItems.map(\.id))
        return Set(ids.filter { validIDs.contains($0) })
    }

    // MARK: - Activation (still used by Views via appState)

    var activationResult: ActivationResult? {
        get { activationManager.activationResult }
        set { activationManager.activationResult = newValue }
    }

    func canActivateProvider(_ providerId: String) -> Bool {
        activationManager.canActivateProvider(providerId)
    }

    func activateAccount(entry: ProviderAccountEntry) throws {
        try activationManager.activateAccount(entry: entry)
    }

    func isActiveAccount(_ entry: ProviderAccountEntry) -> Bool {
        activationManager.isActiveAccount(entry)
    }
}
