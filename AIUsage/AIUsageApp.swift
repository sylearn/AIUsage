import SwiftUI
import Combine
import Sparkle
import UserNotifications
import AppKit
import os
import QuotaBackend

private let appDelegateLog = Logger(subsystem: "com.aiusage.desktop", category: "AppDelegate")
private let sparkleLog = Logger(subsystem: "com.aiusage.desktop", category: "Sparkle")

// MARK: - Sparkle Controller
// 封装 Sparkle 自动更新：启动静默探测 + Sparkle 2 「温和提醒」。
// 后台/计划内发现新版本时不弹系统大窗，只点亮 `availableUpdateVersion`，
// 由侧边栏底部的更新按钮承接；用户点击后再走 Sparkle 标准更新流程（发行说明 → 安装并自动重启）。
final class SparkleController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    /// 发现的新版本号（`displayVersionString`）。非空 → 左下角浮现更新按钮。
    @Published private(set) var availableUpdateVersion: String?

    private var updaterController: SPUStandardUpdaterController?
    /// 上次静默探测的时间，对「同一个 SparkleController 实例期间反复触发探测」做最小间隔节流：
    /// 既覆盖关窗→重开、切应用回来等场景，又避免被 SwiftUI 视图反复 appear/disappear 时打爆 appcast。
    private var lastLaunchProbeAt: Date?
    /// 同一进程内两次静默探测之间的最小间隔。15 分钟兼顾「切回前台能很快发现新版本」与「不刷爆 GitHub raw」。
    private static let launchProbeMinInterval: TimeInterval = 900
    private var didBecomeActiveObserver: NSObjectProtocol?

    override init() {
        super.init()
        // Debug 独立 bundle 不跑 Sparkle，避免误更到正式包或污染生产更新通道。
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        guard !bundleID.hasSuffix(".debug") else {
            sparkleLog.notice("Sparkle disabled for debug bundle")
            return
        }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        guard let updaterController else { return }
        let updater = updaterController.updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)

        // 应用从后台/被遮挡状态切回前台时也探测一次。
        // SwiftUI Window 在「关窗→重开」时并不保证 .task 会重新 fire，靠这个 fallback 兜底。
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.startLaunchUpdateProbeIfNeeded()
        }
    }

    deinit {
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
    }

    /// 启动 / 主窗口重新可见 / 应用切回前台时调用：不弹任何 UI，发现新版本则点亮更新按钮。
    /// 距离上次探测不足 `launchProbeMinInterval` 时直接跳过。
    func startLaunchUpdateProbeIfNeeded() {
        guard let updaterController else { return }
        if let last = lastLaunchProbeAt,
           Date().timeIntervalSince(last) < Self.launchProbeMinInterval {
            return
        }
        lastLaunchProbeAt = Date()
        sparkleLog.info("Launch probe firing")
        updaterController.updater.checkForUpdateInformation()
    }

    /// 用户主动点击「检查更新」或左下角更新按钮：走 Sparkle 标准更新流程。
    func checkForUpdates() {
        updaterController?.updater.checkForUpdates()
    }

    func setAutoCheckEnabled(_ enabled: Bool) {
        updaterController?.updater.automaticallyChecksForUpdates = enabled
    }

    // MARK: - SPUStandardUserDriverDelegate (温和提醒)

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // 计划内（后台）更新一律交给我们的温和提醒，不抢焦点弹大窗。
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // 标准驱动将自行展示（用户主动检查）时不点亮按钮，避免重复提示。
        guard !handleShowingUpdate else { return }
        publishAvailableUpdate(update)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableUpdateVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableUpdateVersion = nil
    }

    // MARK: - SPUUpdaterDelegate (静默探测结果)

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        sparkleLog.info("Found valid update: \(item.displayVersionString, privacy: .public)")
        publishAvailableUpdate(item)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableUpdateVersion = nil
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let ns = error as NSError
        sparkleLog.error("Updater aborted: \(ns.domain, privacy: .public) #\(ns.code, privacy: .public) — \(ns.localizedDescription, privacy: .public)")
    }

    /// Sparkle may resume a scheduled update session persisted by an older app
    /// build. Never surface that stale item as an upgrade after the running app
    /// has already moved past it.
    private func publishAvailableUpdate(_ item: SUAppcastItem) {
        guard let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String else {
            availableUpdateVersion = item.displayVersionString
            return
        }
        let comparison = SUStandardVersionComparator.default.compareVersion(
            currentVersion,
            toVersion: item.versionString
        )
        guard comparison == .orderedAscending else {
            sparkleLog.info(
                "Ignoring stale update item \(item.versionString, privacy: .public); running \(currentVersion, privacy: .public)"
            )
            availableUpdateVersion = nil
            return
        }
        availableUpdateVersion = item.displayVersionString
    }
}

@main
struct AIUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    @ObservedObject private var appSettings = AppSettings.shared
    // 注意：根 Scene 故意不订阅 ProxyViewModel（不用 @ObservedObject）。
    // 代理活跃时它每 0.5s 发一次 objectWillChange，根层订阅会导致整个窗口树重算。
    // 这里只持有实例用于 environmentObject 注入，由需要的子视图自行订阅。
    private let proxyViewModel = ProxyViewModel.shared
    @StateObject private var sparkle = SparkleController()

    init() {
        #if DEBUG
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        precondition(
            ManagedAuthImportBoundary.isBundleIdentityValid(
                bundleIdentifier: bundleID,
                isDebugBuild: true
            ),
            "Debug builds must use an isolated bundle identifier; refusing to start with the production identity."
        )
        #endif
    }
    
    var body: some Scene {
        Window("AIUsage", id: AppState.mainWindowID) {
            ContentView()
                .environmentObject(appState)
                .environmentObject(ProviderActivationManager.shared)
                .environmentObject(ProviderRefreshCoordinator.shared)
                .environmentObject(AccountStore.shared)
                .environmentObject(appSettings)
                .environmentObject(proxyViewModel)
                .environmentObject(sparkle)
                .frame(minWidth: 900, idealWidth: 1100, minHeight: 600, idealHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    sparkle.checkForUpdates()
                }
                .disabled(!sparkle.canCheckForUpdates)
                Divider()
                Button("Preferences...") {
                    appState.presentMainWindow(section: .settings)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        
        // 不再声明 SwiftUI `Settings {}` 场景：它会额外生成一个系统偏好设置弹窗（issue #26 里的英文小窗），
        // 与 App 自带的嵌入式「设置」区段重复。统一走 `presentMainWindow(section: .settings)`（见上方
        // 「Preferences…」命令与菜单栏入口），保持单一入口、语言与交互一致。
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?
    private var statusBarHostingView: NSHostingView<StatusBarItemView>?
    private var settingsCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        requestNotificationPermission()

        // 触发 OpenCode 节点 store 初始化：激活中的代理模式节点需要在启动时
        // 恢复本地透传进程（opencode.json 指向本地端口，进程不在则 OpenCode 请求失败）。
        _ = OpenCodeNodeStore.shared

        // CPA 是独立 sidecar：仅在用户开启自动启动且已安装时恢复。运行时会记录受管 PID，
        // 下次启动只清理路径与参数都严格匹配的孤儿，不会终止未知进程。
        Task { @MainActor in
            await CLIProxyGatewayManager.shared.runtime.startIfConfigured()
        }

        if UserDefaults.standard.bool(forKey: DefaultsKey.hideDockIcon) {
            NSApp.setActivationPolicy(.accessory)
        }

        // issue #30：静默自启动——开启后启动即收起主窗口，仅驻留菜单栏。
        // SwiftUI 的 Window 场景会在启动流程中自动创建并显示，didFinishLaunching 时可能尚未建好，
        // 故轮询等它出现后立刻 orderOut（隐藏而非关闭，避免触发关窗退出、且后台数据刷新照常进行）。
        if UserDefaults.standard.bool(forKey: DefaultsKey.launchHidden) {
            hideMainWindowForSilentLaunch()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            AppState.shared.refreshAllProviders()
        }
    }

    /// 启动静默：等主窗口创建后立即收起到菜单栏。轮询上限约 0.5s，超时则放弃（不影响正常使用）。
    private func hideMainWindowForSilentLaunch(attempt: Int = 0) {
        let mainWindows = NSApp.windows.filter { !($0 is NSPanel) && $0.canBecomeMain }
        if !mainWindows.isEmpty {
            mainWindows.forEach { $0.orderOut(nil) }
            return
        }
        guard attempt < 50 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            self?.hideMainWindowForSilentLaunch(attempt: attempt + 1)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // issue #31：Dock 显示与后台运行解耦。
        // 隐藏 Dock（仅菜单栏模式）必须常驻，否则关窗即无入口；
        if UserDefaults.standard.bool(forKey: DefaultsKey.hideDockIcon) { return false }
        // issue #39：关闭时最小化到托盘——关窗即隐藏 Dock 图标、常驻菜单栏，不退出；
        // 从菜单栏唤起主窗口时再恢复 Dock 图标（见 AppState.presentMainWindow）。
        if UserDefaults.standard.bool(forKey: DefaultsKey.closeToTray) {
            NSApp.setActivationPolicy(.accessory)
            return false
        }
        // Dock 可见时按用户的「保持后台运行」开关，缺省 true（保持历史行为，关窗不退出）。
        let keepRunning = UserDefaults.standard.object(forKey: DefaultsKey.keepRunningInBackground) as? Bool ?? true
        return !keepRunning
    }

    // 代理 helper 的退出清理刻意不放在 applicationWillTerminate：纯 SwiftUI App 的该回调在
    // quit / Cmd-Q / Sparkle 更新等路径并不可靠触发（实测不触发），崩溃 / 被强杀更没有任何
    // App 侧钩子能兜底。改由 helper（QuotaServer）自带「父进程死亡看门狗」保证随 App 一起退出，
    // 不留占端口的孤儿——见 QuotaBackend 的 ParentWatchdog；残留孤儿则由下次启动的 reap 兜底。

    func applicationWillTerminate(_ notification: Notification) {
        CLIProxyGatewayManager.shared.runtime.stopSynchronouslyForTermination()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        AppState.shared.presentMainWindow(section: AppState.shared.selectedSection)
        return true
    }

    func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error {
                    appDelegateLog.error("Notification permission error: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            let hostingView = NSHostingView(
                rootView: StatusBarItemView(
                    appState: AppState.shared,
                    refreshCoordinator: ProviderRefreshCoordinator.shared,
                    settings: AppSettings.shared
                )
            )
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 2),
                hostingView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
                hostingView.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])
            statusBarHostingView = hostingView

            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            updateStatusBarSize()
            settingsCancellable = AppSettings.shared.objectWillChange
                .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.updateStatusBarSize()
                }
        }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover?.performClose(nil)
        }
    }

    private func updateStatusBarSize() {
        guard let hostingView = statusBarHostingView else { return }
        let fittingSize = hostingView.fittingSize
        statusItem?.length = max(fittingSize.width + 8, 28)
    }

    @objc func togglePopover(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu(from: sender)
            return
        }

        if let popover, popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 420, height: 700)
        popover.behavior = .transient
        popover.animates = true

        popover.contentViewController = NSHostingController(
            rootView: MenuBarView()
                .environmentObject(AppState.shared)
                .environmentObject(ProviderActivationManager.shared)
                .environmentObject(ProviderRefreshCoordinator.shared)
        )
        self.popover = popover

        if let button = statusItem?.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }

        DispatchQueue.main.async {
            ProviderActivationManager.shared.detectActiveCodexAccount()
            ProviderActivationManager.shared.detectActiveGeminiAccount()
        }
    }

    private func showContextMenu(from sender: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L("Show Main Window", "显示主窗口"), action: #selector(showMainWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L("Open Dashboard", "打开仪表盘"), action: #selector(openDashboard), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L("Open Cost Tracking", "打开费用追踪"), action: #selector(openCostTracking), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L("Refresh All", "全部刷新"), action: #selector(refreshAll), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L("Refresh Token Stats", "刷新 Token 统计"), action: #selector(refreshClaudeCode), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L("Settings...", "设置..."), action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L("Quit AIUsage", "退出 AIUsage"), action: #selector(quit), keyEquivalent: ""))

        for item in menu.items { item.target = self }

        statusItem?.menu = menu
        sender.performClick(nil)
        statusItem?.menu = nil
    }

    @objc func showMainWindow() {
        revealMainWindow(section: AppState.shared.selectedSection)
    }

    @objc func openDashboard() {
        revealMainWindow(section: .dashboard)
    }

    @objc func openCostTracking() {
        revealMainWindow(section: .costTracking)
    }

    func revealMainWindow(section: AppSection) {
        popover?.performClose(nil)
        AppState.shared.presentMainWindow(section: section)
    }

    @objc func refreshAll() {
        AppState.shared.refreshAllProviders()
    }

    @objc func refreshClaudeCode() {
        ProviderRefreshCoordinator.shared.refreshLocalTokenStatsOnly()
    }

    @objc func openSettings() {
        revealMainWindow(section: .settings)
    }

    @objc func quit() {
        CLIProxyGatewayManager.shared.runtime.stopSynchronouslyForTermination()
        NSApplication.shared.terminate(nil)
    }
}
