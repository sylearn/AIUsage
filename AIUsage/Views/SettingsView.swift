import SwiftUI
import Sparkle
import ServiceManagement

// MARK: - Settings Category

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case dataRefresh
    case menuBar
    case cardAppearance
    case proxy
    case notifications
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("General", "通用")
        case .dataRefresh: return L("Data & Refresh", "数据与刷新")
        case .menuBar: return L("Menu Bar", "菜单栏")
        case .cardAppearance: return L("Card Appearance", "卡片外观")
        case .proxy: return L("Proxy", "代理")
        case .notifications: return L("Notifications", "通知")
        case .about: return L("About", "关于")
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .dataRefresh: return "arrow.triangle.2.circlepath"
        case .menuBar: return "menubar.rectangle"
        case .cardAppearance: return "rectangle.on.rectangle"
        case .proxy: return "server.rack"
        case .notifications: return "bell"
        case .about: return "info.circle"
        }
    }

    // 品牌化强调色：未选中时图标用各自的色，选中时转白底色。
    var color: Color {
        switch self {
        case .general: return .gray
        case .dataRefresh: return .blue
        case .menuBar: return .indigo
        case .cardAppearance: return .teal
        case .proxy: return .orange
        case .notifications: return .red
        case .about: return .gray
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var sparkle: SparkleController
    @Environment(\.colorScheme) var colorScheme
    @State var hideDockIcon = UserDefaults.standard.bool(forKey: DefaultsKey.hideDockIcon)
    /// 关窗后保持后台运行（issue #31）。缺省 true，与隐藏 Dock 解耦。
    @State var keepRunningInBackground = UserDefaults.standard.object(forKey: DefaultsKey.keepRunningInBackground) as? Bool ?? true
    /// 启动后隐藏主窗口、仅驻留菜单栏（issue #30）。缺省 false。
    @State var launchHidden = UserDefaults.standard.bool(forKey: DefaultsKey.launchHidden)
    /// 关闭主窗口时最小化到托盘（issue #39）。缺省 false，与隐藏 Dock 解耦。
    @State var closeToTray = UserDefaults.standard.bool(forKey: DefaultsKey.closeToTray)
    @State var launchAtLogin: Bool = {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }()
    @State var showNotifications = UserDefaults.standard.bool(forKey: DefaultsKey.showNotifications)
    @State var lowQuotaThreshold: Double = UserDefaults.standard.double(forKey: DefaultsKey.lowQuotaThreshold)
    @State var remoteHostInput: String = ""
    @State var remotePortInput: String = ""
    @State var ccSwitchDirInput: String = UserDefaults.standard.string(forKey: DefaultsKey.ccSwitchConfigDirOverride) ?? ""
    @State var isTestingRemoteConnection = false
    @State var remoteConnectionState: RemoteConnectionState = .idle
    @State var remoteConnectionMessage: String?
    @AppStorage(DefaultsKey.proxyLogRetentionDays) var proxyLogRetentionDays: Int = 30

    @State private var selectedCategory: SettingsCategory = .general

    enum RemoteConnectionState {
        case idle
        case success
        case failure
    }

    init() {
        if _lowQuotaThreshold.wrappedValue == 0 {
            _lowQuotaThreshold = State(initialValue: 20.0)
        }
    }

    var repositoryURL: URL? {
        if let raw = Bundle.main.infoDictionary?["ProjectRepositoryURL"] as? String,
           let url = URL(string: raw) {
            return url
        }
        guard let owner = gitHubOwner, let repository = gitHubRepository else { return nil }
        return URL(string: "https://github.com/\(owner)/\(repository)")
    }

    var gitHubOwner: String? {
        (Bundle.main.infoDictionary?["ProjectGitHubOwner"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }

    var gitHubRepository: String? {
        (Bundle.main.infoDictionary?["ProjectGitHubRepository"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsHero
            Divider()
            HStack(spacing: 0) {
                settingsSidebar
                Divider()
                settingsContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(settingsBackground.ignoresSafeArea())
        .onAppear {
            remoteHostInput = settings.remoteHost
            remotePortInput = "\(settings.remotePort)"
        }
        .onChange(of: hideDockIcon) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.hideDockIcon)
            updateDockIconVisibility(hidden: newValue)
        }
        .onChange(of: launchAtLogin) { _, newValue in
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }
        }
        .onChange(of: showNotifications) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.showNotifications)
        }
        .onChange(of: lowQuotaThreshold) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.lowQuotaThreshold)
        }
        .onChange(of: settings.autoRefreshInterval) { _, _ in
            settings.saveSettings()
            refreshCoordinator.setupAutoRefresh()
        }
        .onChange(of: settings.claudeCodeRefreshInterval) { _, _ in
            settings.saveSettings()
            refreshCoordinator.setupClaudeCodeAutoRefresh()
        }
        .onChange(of: settings.themeMode) { _, _ in
            settings.saveSettings()
        }
        .onChange(of: settings.quotaIndicatorStyle) { _, _ in
            settings.saveSettings()
        }
        .onChange(of: settings.quotaIndicatorMetric) { _, _ in
            settings.saveSettings()
        }
        .onChange(of: settings.language) { _, _ in
            settings.saveSettings()
            refreshCoordinator.refreshAllProviders()
        }
    }

    // MARK: - Hero

    var settingsHero: some View {
        HStack(spacing: 14) {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: Color.accentColor.opacity(0.2), radius: 8, y: 3)
            } else {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("AIUsage")
                    .font(.system(size: 20, weight: .bold, design: .rounded))

                Text(L("Your AI workspace", "你的 AI 工作台"))
                    .font(.caption)
                    .foregroundStyle(AppContent.secondary(colorScheme))
            }

            Spacer()

            // 「检查更新」入口统一收敛到「软件更新」设置卡片（含自动更新开关），此处只留版本标签。
            Label(L("Version", "版本") + " " + appVersion, systemImage: "tag")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(AppContent.secondary(colorScheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(AppSurface.chip(colorScheme)))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(AppSurface.toolbar(colorScheme))
    }

    // MARK: - Sidebar

    var settingsSidebar: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(SettingsCategory.allCases) { category in
                    settingsCategoryRow(category)
                }
            }
            .padding(10)
        }
        .frame(width: 180)
        .background(AppSurface.sidebar(colorScheme))
    }

    private func settingsCategoryRow(_ category: SettingsCategory) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedCategory = category
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: category.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(selectedCategory == category ? .white : category.color)
                    .frame(width: 20)

                Text(category.title)
                    .font(.system(size: 13, weight: selectedCategory == category ? .semibold : .regular))
                    .foregroundStyle(selectedCategory == category ? .white : AppContent.primary(colorScheme))

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedCategory == category ? AppAccent.control(colorScheme) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content Router

    @ViewBuilder
    var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch selectedCategory {
                case .general:
                    generalSection
                case .dataRefresh:
                    dataRefreshSection
                case .menuBar:
                    menuBarSection
                case .cardAppearance:
                    cardAppearanceSection
                case .proxy:
                    proxySection
                case .notifications:
                    notificationsSection
                case .about:
                    aboutSection
                }
            }
            .padding(24)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Background

    var settingsBackground: some View {
        LinearGradient(
            colors: [
                AppSurface.page(colorScheme),
                AppSurface.selection(colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.42),
                AppSurface.page(colorScheme)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    func updateDockIconVisibility(hidden: Bool) {
        if hidden {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState.shared)
        .environmentObject(AppSettings.shared)
}
