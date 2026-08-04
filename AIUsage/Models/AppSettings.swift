import Foundation
import SwiftUI
import Combine
import AppKit

// MARK: - Navigation (used by AppState.selectedSection)

enum AppSection: String, Hashable {
    case dashboard
    /// 订阅账号：监控登录类账号（Claude / Codex / Cursor 等）的订阅额度与用量。
    case providerAccounts
    /// CPA 网关：管理官方 CLIProxyAPI sidecar、版本更新与多订阅账号池。
    case subscriptionGateway
    /// API 提供商：统一上游配置，分发到三套代理。
    case apiProviders
    case costTracking
    case callAnalytics
    case proxyManagement
    case codexProxyManagement
    case opencodeManagement
    /// Claude Science 代理：免订阅启动 Science（隔离沙箱 + 本地虚拟登录），推理走第三方模型。
    case scienceProxyManagement
    case inbox
    case settings

    /// 旧版「服务商」入口的 rawValue。v0.11 后拆成 `providerAccounts` + `apiProviders`，
    /// 仅用于迁移历史持久化数据（隐藏状态等），不再作为有效导航分区。
    static let legacyProvidersRawValue = "providers"
}

// MARK: - Quota card appearance

enum CardQuotaIndicatorStyle: String, CaseIterable {
    case bar
    case ring
    case segments
}

enum CardQuotaIndicatorMetric: String, CaseIterable {
    case remaining
    case used
}

// MARK: - Menu bar display

enum MenuBarDisplayMode: String, CaseIterable {
    case iconOnly
    case iconAndMetric
    case metricOnly
}

enum MenuBarMetricType: String, CaseIterable {
    case quota
    case cost
    case both

    var showsQuota: Bool { self == .quota || self == .both }
    var showsCost: Bool { self == .cost || self == .both }
}

// MARK: - Menu bar cost source config (per-source period + metric)

enum MenuBarCostPeriod: String, CaseIterable, Codable {
    case today
    case week
    case month
    case overall
}

enum MenuBarCostMetric: String, CaseIterable, Codable {
    case cost
    case tokens
}

struct MenuBarCostSourceConfig: Codable, Equatable {
    var period: MenuBarCostPeriod
    var metric: MenuBarCostMetric

    static let `default` = MenuBarCostSourceConfig(period: .month, metric: .cost)
}

extension MenuBarCostPeriod {
    /// Lower bound for filtering timestamped data, or nil for "all time".
    func sinceDate(calendar: Calendar = .current, now: Date = Date()) -> Date? {
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.start
                ?? calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now))
        case .month:
            return calendar.dateInterval(of: .month, for: now)?.start
                ?? calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now))
        case .overall:
            return nil
        }
    }
}

// MARK: - UserDefaults keys

/// Central namespace for `UserDefaults` / `@AppStorage` keys (values must stay stable for migration).
enum DefaultsKey {
    static let activeCodexAccountId = "activeCodexAccountId"
    static let activeProviderAccountIds = "activeProviderAccountIds"
    static let appLanguage = "appLanguage"
    static let autoRefreshInterval = "autoRefreshInterval"
    static let backendMode = "backendMode"
    static let ccSwitchConfigDirOverride = "ccSwitchConfigDirOverride"
    static let claudeCodeDailyThreshold = "claudeCodeDailyThreshold"
    static let claudeCodeLastNotifiedDate = "claudeCodeLastNotifiedDate"
    static let claudeCodeRefreshInterval = "claudeCodeRefreshInterval"
    static let claudeHubSelectedTab = "claudeHubSelectedTab"
    /// 关闭主窗口时最小化到托盘（issue #39）：Dock 可见时关窗即隐藏 Dock 图标并常驻菜单栏，
    /// 从菜单栏唤起时再恢复 Dock 图标。缺省=false。
    static let closeToTray = "closeToTray"
    static let cnyExchangeRate = "cnyExchangeRate"
    static let displayCurrency = "displayCurrency"
    static let hiddenSidebarSections = "hiddenSidebarSections"
    static let hideDockIcon = "hideDockIcon"
    /// 关闭主窗口后是否保持后台运行（issue #31，与隐藏 Dock 解耦）。缺省=true（保持历史行为）。
    static let keepRunningInBackground = "keepRunningInBackground"
    /// 启动后是否隐藏主窗口、仅驻留菜单栏（issue #30 静默自启动）。缺省=false。
    static let launchHidden = "launchHidden"
    static let lowQuotaThreshold = "lowQuotaThreshold"
    static let menuBarDisplayMode = "menuBarDisplayMode"
    static let menuBarMetricType = "menuBarMetricType"
    static let menuBarPinnedQuotaAccountIds = "menuBarPinnedQuotaAccountIds"
    static let menuBarPinnedCostSourceIds = "menuBarPinnedCostSourceIds"
    static let menuBarCostSourceConfigs = "menuBarCostSourceConfigs"
    static let proxyActivatedConfigId = "proxyActivatedConfigId"
    static let proxyActivatedCodexConfigId = "proxyActivatedCodexConfigId"
    static let proxyAutoRestoreOnLaunch = "proxyAutoRestoreOnLaunch"
    static let proxyOnlyRunningIds = "proxyOnlyRunningIds"
    static let proxyConnectivityResults = "proxyConnectivityResults"
    static let proxyConfigurations = "proxyConfigurations"
    static let proxyLogRetentionDays = "proxyLogRetentionDays"
    static let proxyLogs = "proxyLogs"
    static let proxyStatistics = "proxyStatistics"
    static let proxyStatsChartRange = "proxyStatsChartRange"
    static let proxyStatsMetric = "proxyStatsMetric"
    static let proxyStatsPeriod = "proxyStatsPeriod"
    static let proxyStatsFamily = "proxyStatsFamily"
    static let proxyStatsTrack = "proxyStatsTrack"
    static let quotaIndicatorMetric = "quotaIndicatorMetric"
    static let quotaIndicatorStyle = "quotaIndicatorStyle"
    static let readAlertIds = "readAlertIds"
    static let remoteHost = "remoteHost"
    static let remotePort = "remotePort"
    static let selectedProviderIds = "selectedProviderIds"
    static let showNotifications = "showNotifications"
    /// 侧边栏「代理」分组的展开/收起状态。缺省=true（展开）。
    static let sidebarProxiesGroupExpanded = "sidebarProxiesGroupExpanded"
    static let themeMode = "themeMode"
}

// MARK: - AppSettings

/// User-facing preferences persisted in `UserDefaults` (non-secret): theme, language, refresh cadence, remote backend, quota card UI.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let supportedAutoRefreshIntervals: [Int] = [30, 60, 180, 300, 600, 900, 1800, 3600, 0]
    static let defaultAutoRefreshInterval = 300

    static let supportedClaudeCodeRefreshIntervals: [Int] = [10, 30, 60, 180, 300, 600, 0]
    static let defaultClaudeCodeRefreshInterval = 30

    /// CNY/USD 近似汇率默认值（1 USD ≈ 7 CNY）。仅用于把人民币录入价折算成 USD 落盘、
    /// 以及费用以人民币显示时的换算；非真实计费汇率，可由用户在设置里调整。
    static let defaultCNYPerUSD: Double = 7.0

    /// 线程安全读取当前 CNY/USD 汇率（模型/工具层折算可能跑在非主线程，故直接读 UserDefaults，
    /// 与 `formatCurrency` 同源）。未设置或非正数时回退默认 7。
    static var cnyPerUSD: Double {
        let raw = UserDefaults.standard.double(forKey: DefaultsKey.cnyExchangeRate)
        return raw > 0 ? raw : defaultCNYPerUSD
    }

    @Published var themeMode: String = UserDefaults.standard.string(forKey: DefaultsKey.themeMode) ?? "system"

    @Published var autoRefreshInterval: Int = {
        let defaults = UserDefaults.standard
        let storedValue = defaults.object(forKey: DefaultsKey.autoRefreshInterval) != nil
            ? defaults.integer(forKey: DefaultsKey.autoRefreshInterval)
            : AppSettings.defaultAutoRefreshInterval
        return AppSettings.normalizedAutoRefreshInterval(storedValue)
    }()

    @Published var claudeCodeRefreshInterval: Int = {
        let defaults = UserDefaults.standard
        let storedValue = defaults.object(forKey: DefaultsKey.claudeCodeRefreshInterval) != nil
            ? defaults.integer(forKey: DefaultsKey.claudeCodeRefreshInterval)
            : AppSettings.defaultClaudeCodeRefreshInterval
        return AppSettings.normalizedClaudeCodeRefreshInterval(storedValue)
    }()

    /// CNY/USD 汇率（1 USD = ? CNY），默认 7；设置页可调，三处折算（OpenCode 定价录入、
    /// 费用显示、Claude/Codex 代理定价）统一读它，保证录入与显示口径一致。
    @Published var cnyExchangeRate: Double = {
        let raw = UserDefaults.standard.double(forKey: DefaultsKey.cnyExchangeRate)
        return raw > 0 ? raw : AppSettings.defaultCNYPerUSD
    }()

    @Published var language: String = UserDefaults.standard.string(forKey: DefaultsKey.appLanguage) ?? "en"
    @Published var quotaIndicatorStyle: CardQuotaIndicatorStyle = CardQuotaIndicatorStyle(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.quotaIndicatorStyle) ?? "") ?? .bar
    @Published var quotaIndicatorMetric: CardQuotaIndicatorMetric = CardQuotaIndicatorMetric(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.quotaIndicatorMetric) ?? "") ?? .remaining

    /// Claude Gateway ledger threshold. The persisted key retains its legacy
    /// name so existing user preferences migrate without a reset.
    @Published var claudeDailyThreshold: Double = {
        let defaults = UserDefaults.standard
        let storedValue = defaults.object(forKey: DefaultsKey.claudeCodeDailyThreshold) != nil
            ? defaults.double(forKey: DefaultsKey.claudeCodeDailyThreshold)
            : 0.0
        return storedValue
    }()

    /// Persisted calendar day string (YYYY-MM-DD) for Claude cost alert de-duplication.
    var lastNotifiedDate: String? {
        get { UserDefaults.standard.string(forKey: DefaultsKey.claudeCodeLastNotifiedDate) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.claudeCodeLastNotifiedDate) }
    }

    @Published var menuBarDisplayMode: MenuBarDisplayMode = MenuBarDisplayMode(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.menuBarDisplayMode) ?? "") ?? .iconAndMetric
    @Published var menuBarMetricType: MenuBarMetricType = MenuBarMetricType(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.menuBarMetricType) ?? "") ?? .quota
    @Published var menuBarPinnedQuotaAccountIds: Set<String> = {
        let stored = UserDefaults.standard.stringArray(forKey: DefaultsKey.menuBarPinnedQuotaAccountIds) ?? []
        return Set(stored)
    }()
    @Published var menuBarPinnedCostSourceIds: Set<String> = {
        let stored = UserDefaults.standard.stringArray(forKey: DefaultsKey.menuBarPinnedCostSourceIds) ?? []
        return Set(stored)
    }()
    @Published var menuBarCostSourceConfigs: [String: MenuBarCostSourceConfig] = {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.menuBarCostSourceConfigs),
              let decoded = try? JSONDecoder().decode([String: MenuBarCostSourceConfig].self, from: data) else {
            return [:]
        }
        return decoded
    }()

    func costSourceConfig(for id: String) -> MenuBarCostSourceConfig {
        menuBarCostSourceConfigs[id] ?? .default
    }

    func setCostSourceConfig(_ config: MenuBarCostSourceConfig, for id: String) {
        var next = menuBarCostSourceConfigs
        next[id] = config
        menuBarCostSourceConfigs = next
    }

    @Published var backendMode: String = UserDefaults.standard.string(forKey: DefaultsKey.backendMode) ?? "local"
    @Published var remoteHost: String = UserDefaults.standard.string(forKey: DefaultsKey.remoteHost) ?? "127.0.0.1"
    @Published var remotePort: Int = UserDefaults.standard.integer(forKey: DefaultsKey.remotePort) == 0 ? 4318 : UserDefaults.standard.integer(forKey: DefaultsKey.remotePort)

    @Published var proxyAutoRestoreOnLaunch: Bool = UserDefaults.standard.bool(forKey: DefaultsKey.proxyAutoRestoreOnLaunch)

    /// 侧边栏中被用户隐藏的导航分区（存 `AppSection.rawValue`）。常驻分区即使被写入也不会真正隐藏。
    @Published var hiddenSidebarSections: Set<String> = {
        let defaults = UserDefaults.standard
        var stored = Set(defaults.stringArray(forKey: DefaultsKey.hiddenSidebarSections) ?? [])
        // 迁移：旧版「服务商」(providers) 已拆成「订阅账号」+「API 提供商」两个入口。
        // 曾隐藏旧入口的用户，两个新入口都继承隐藏；同时清除不再有效的孤儿键并落盘。
        if stored.remove(AppSection.legacyProvidersRawValue) != nil {
            stored.insert(AppSection.providerAccounts.rawValue)
            stored.insert(AppSection.apiProviders.rawValue)
            defaults.set(Array(stored), forKey: DefaultsKey.hiddenSidebarSections)
        }
        return stored
    }()

    /// 侧边栏「代理」分组是否展开；默认展开，保持与折叠前的可见性一致。
    @Published var sidebarProxiesGroupExpanded: Bool =
        UserDefaults.standard.object(forKey: DefaultsKey.sidebarProxiesGroupExpanded) as? Bool ?? true

    private var cancellables = Set<AnyCancellable>()

    func pruneMenuBarPinnedIds(validQuotaIds: Set<String>, validCostIds: Set<String>) {
        let cleanedQuota = menuBarPinnedQuotaAccountIds.intersection(validQuotaIds)
        let cleanedCost = menuBarPinnedCostSourceIds.intersection(validCostIds)
        if cleanedQuota != menuBarPinnedQuotaAccountIds {
            menuBarPinnedQuotaAccountIds = cleanedQuota
        }
        if cleanedCost != menuBarPinnedCostSourceIds {
            menuBarPinnedCostSourceIds = cleanedCost
        }
    }

    private init() {
        autoRefreshInterval = Self.normalizedAutoRefreshInterval(autoRefreshInterval)
        claudeCodeRefreshInterval = Self.normalizedClaudeCodeRefreshInterval(claudeCodeRefreshInterval)

        menuBarDisplayMode = .iconAndMetric
        menuBarMetricType = .both

        setupAutoPersist()
        applyAppearance(for: themeMode)
    }

    /// 使用 AppKit 的应用级 appearance 作为唯一主题入口。
    /// `nil` 会原生继承 macOS，并持续跟随系统变化；不会出现 SwiftUI 从显式值切回 nil 时残留旧主题的问题。
    private func applyAppearance(for mode: String) {
        switch mode {
        case "light":
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApplication.shared.appearance = nil
        }
    }

    private func setupAutoPersist() {
        let defaults = UserDefaults.standard

        $themeMode
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                defaults.set(mode, forKey: DefaultsKey.themeMode)
                self?.applyAppearance(for: mode)
            }
            .store(in: &cancellables)
        $language.dropFirst().sink { defaults.set($0, forKey: DefaultsKey.appLanguage) }.store(in: &cancellables)
        $quotaIndicatorStyle.dropFirst().sink { defaults.set($0.rawValue, forKey: DefaultsKey.quotaIndicatorStyle) }.store(in: &cancellables)
        $quotaIndicatorMetric.dropFirst().sink { defaults.set($0.rawValue, forKey: DefaultsKey.quotaIndicatorMetric) }.store(in: &cancellables)
        $claudeDailyThreshold.dropFirst().sink { defaults.set($0, forKey: DefaultsKey.claudeCodeDailyThreshold) }.store(in: &cancellables)
        $cnyExchangeRate.dropFirst().sink { defaults.set($0, forKey: DefaultsKey.cnyExchangeRate) }.store(in: &cancellables)
        $menuBarDisplayMode.dropFirst().sink { defaults.set($0.rawValue, forKey: DefaultsKey.menuBarDisplayMode) }.store(in: &cancellables)
        $menuBarMetricType.dropFirst().sink { defaults.set($0.rawValue, forKey: DefaultsKey.menuBarMetricType) }.store(in: &cancellables)
        $menuBarPinnedQuotaAccountIds.dropFirst().sink { defaults.set(Array($0), forKey: DefaultsKey.menuBarPinnedQuotaAccountIds) }.store(in: &cancellables)
        $menuBarPinnedCostSourceIds.dropFirst().sink { defaults.set(Array($0), forKey: DefaultsKey.menuBarPinnedCostSourceIds) }.store(in: &cancellables)
        $menuBarCostSourceConfigs.dropFirst().sink { configs in
            guard let data = try? JSONEncoder().encode(configs) else { return }
            defaults.set(data, forKey: DefaultsKey.menuBarCostSourceConfigs)
        }.store(in: &cancellables)
        $backendMode.dropFirst().sink { defaults.set($0, forKey: DefaultsKey.backendMode) }.store(in: &cancellables)
        $autoRefreshInterval.dropFirst().sink { [weak self] val in
            let normalized = Self.normalizedAutoRefreshInterval(val)
            if normalized != val { self?.autoRefreshInterval = normalized }
            defaults.set(normalized, forKey: DefaultsKey.autoRefreshInterval)
        }.store(in: &cancellables)
        $claudeCodeRefreshInterval.dropFirst().sink { [weak self] val in
            let normalized = Self.normalizedClaudeCodeRefreshInterval(val)
            if normalized != val { self?.claudeCodeRefreshInterval = normalized }
            defaults.set(normalized, forKey: DefaultsKey.claudeCodeRefreshInterval)
        }.store(in: &cancellables)
        $remoteHost.dropFirst().sink { [weak self] host in
            defaults.set(host, forKey: DefaultsKey.remoteHost)
            guard let self else { return }
            self.onRemoteSettingsChanged?("http://\(host):\(self.remotePort)")
        }.store(in: &cancellables)
        $remotePort.dropFirst().sink { [weak self] port in
            defaults.set(port, forKey: DefaultsKey.remotePort)
            guard let self else { return }
            self.onRemoteSettingsChanged?("http://\(self.remoteHost):\(port)")
        }.store(in: &cancellables)
        $proxyAutoRestoreOnLaunch.dropFirst().sink { defaults.set($0, forKey: DefaultsKey.proxyAutoRestoreOnLaunch) }.store(in: &cancellables)
        $hiddenSidebarSections.dropFirst().sink { defaults.set(Array($0), forKey: DefaultsKey.hiddenSidebarSections) }.store(in: &cancellables)
        $sidebarProxiesGroupExpanded.dropFirst().sink { defaults.set($0, forKey: DefaultsKey.sidebarProxiesGroupExpanded) }.store(in: &cancellables)
    }

    static func normalizedAutoRefreshInterval(_ value: Int) -> Int {
        guard value > 0 else { return 0 }
        guard !supportedAutoRefreshIntervals.contains(value) else { return value }

        return supportedAutoRefreshIntervals
            .filter { $0 > 0 }
            .min(by: { abs($0 - value) < abs($1 - value) })
            ?? defaultAutoRefreshInterval
    }

    static func normalizedClaudeCodeRefreshInterval(_ value: Int) -> Int {
        guard value > 0 else { return 0 }
        guard !supportedClaudeCodeRefreshIntervals.contains(value) else { return value }

        return supportedClaudeCodeRefreshIntervals
            .filter { $0 > 0 }
            .min(by: { abs($0 - value) < abs($1 - value) })
            ?? defaultClaudeCodeRefreshInterval
    }

    /// Kept for backward compatibility; auto-persist via Combine now handles all @Published properties.
    func saveSettings() {
        autoRefreshInterval = Self.normalizedAutoRefreshInterval(autoRefreshInterval)
        claudeCodeRefreshInterval = Self.normalizedClaudeCodeRefreshInterval(claudeCodeRefreshInterval)
    }

    /// Called when remote backend URL changes. Wired in AppState init.
    var onRemoteSettingsChanged: ((String) -> Void)?

    func t(_ en: String, _ zh: String) -> String {
        language == "zh" ? zh : en
    }

    static func localized(_ en: String, _ zh: String) -> String {
        AppSettings.shared.language == "zh" ? zh : en
    }
}

/// Localization bridge used while the app migrates from inline bilingual strings to
/// stable `.strings` keys. Prefer passing `key:` for new static UI copy so generated
/// `Localizable.strings` entries are no longer tied to call-site file paths.
/// Strategy note: `docs/LOCALIZATION_STRATEGY.md`.
func L(_ en: String, _ zh: String, key: String? = nil, file: StaticString = #fileID) -> String {
    let fallback = AppSettings.localized(en, zh)
    let language = AppSettings.shared.language == "zh" ? "zh_CN" : "en"

    guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
          let bundle = Bundle(path: path) else {
        return fallback
    }

    let contextualKey = key ?? "\(String(describing: file))::\(en)"
    let contextualValue = bundle.localizedString(forKey: contextualKey, value: nil, table: "Localizable")
    if contextualValue != contextualKey {
        return contextualValue
    }

    let plainValue = bundle.localizedString(forKey: en, value: nil, table: "Localizable")
    if plainValue != en {
        return plainValue
    }

    return fallback
}
