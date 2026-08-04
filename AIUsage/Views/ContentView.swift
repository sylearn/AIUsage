import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @EnvironmentObject var sparkle: SparkleController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var proxyVM = ProxyViewModel.shared
    private var sectionBinding: Binding<AppSection> {
        Binding(
            get: { appState.selectedSection },
            set: { appState.selectedSection = $0 }
        )
    }

    // MARK: - Sidebar Visibility

    private var hiddenSections: Set<String> {
        appState.settings.hiddenSidebarSections
    }

    private var visiblePrimaryTop: [SidebarNavItem] {
        SidebarNavigation.visible(SidebarNavigation.primaryTop, hidden: hiddenSections)
    }

    private var visibleProxies: [SidebarNavItem] {
        SidebarNavigation.visible(SidebarNavigation.proxies, hidden: hiddenSections)
    }

    private var visiblePrimaryBottom: [SidebarNavItem] {
        SidebarNavigation.visible(SidebarNavigation.primaryBottom, hidden: hiddenSections)
    }

    private var visibleSecondary: [SidebarNavItem] {
        SidebarNavigation.visible(SidebarNavigation.secondary, hidden: hiddenSections)
    }

    private var hasVisiblePrimary: Bool {
        !(visiblePrimaryTop.isEmpty && visibleProxies.isEmpty && visiblePrimaryBottom.isEmpty)
    }

    private var proxiesGroupExpanded: Binding<Bool> {
        Binding(
            get: { appState.settings.sidebarProxiesGroupExpanded },
            set: { appState.settings.sidebarProxiesGroupExpanded = $0 }
        )
    }

    private func hideSection(_ section: AppSection) {
        var hidden = appState.settings.hiddenSidebarSections
        hidden.insert(section.rawValue)
        appState.settings.hiddenSidebarSections = hidden
        if appState.selectedSection == section {
            appState.selectedSection = .dashboard
        }
    }

    // MARK: - Row Rendering

    @ViewBuilder
    private func navIcon(_ item: SidebarNavItem) -> some View {
        switch item.icon {
        case .system(let name):
            // 消息条目有未读时改用带角标的铃铛图标。
            let symbol = (item.section == .inbox && appState.unreadAlertCount > 0) ? "bell.badge.fill" : name
            Image(systemName: symbol)
                .foregroundStyle(item.tint)
        case .providerAsset(let asset):
            ProviderIconView(asset, size: 18)
        }
    }

    @ViewBuilder
    private func navRow(_ item: SidebarNavItem) -> some View {
        Group {
            if item.section == .inbox {
                HStack {
                    Label { Text(item.title) } icon: { navIcon(item) }
                    Spacer()
                    if appState.unreadAlertCount > 0 {
                        Text("\(appState.unreadAlertCount)")
                            .font(.caption2)
                            .bold()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red)
                            .clipShape(Capsule())
                    }
                }
            } else {
                Label { Text(item.title) } icon: { navIcon(item) }
            }
        }
        .tag(item.section)
        .contextMenu {
            if item.isHideable {
                Button {
                    hideSection(item.section)
                } label: {
                    Label(L("Hide", "隐藏", key: "sidebar.hide"), systemImage: "eye.slash")
                }
            }
            Button {
                appState.selectedSection = .settings
            } label: {
                Label(L("Manage Sidebar…", "管理侧边栏…", key: "sidebar.manage"), systemImage: "slider.horizontal.3")
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: sectionBinding) {
                ForEach(visiblePrimaryTop) { navRow($0) }

                // 四条代理入口收进一个可折叠分组，分组标题表达“代理”语义，
                // 条目只显示应用名；展开状态持久化，重启后保持。
                if !visibleProxies.isEmpty {
                    Section(isExpanded: proxiesGroupExpanded) {
                        ForEach(visibleProxies) { navRow($0) }
                    } header: {
                        Text(SidebarNavigation.proxiesGroupTitle)
                    }
                }

                ForEach(visiblePrimaryBottom) { navRow($0) }

                if hasVisiblePrimary && !visibleSecondary.isEmpty {
                    Divider()
                }

                ForEach(visibleSecondary) { navRow($0) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(AppSurface.sidebar(colorScheme))
            .foregroundStyle(AppContent.primary(colorScheme))
            .frame(minWidth: 200)
            .navigationTitle("AIUsage")
            .onChange(of: hiddenSections) { _, hidden in
                // 若当前分区被（在设置页等处）隐藏，回退到常驻的仪表盘，避免停在空白详情。
                if hidden.contains(appState.selectedSection.rawValue) {
                    appState.selectedSection = .dashboard
                }
            }
            .onChange(of: appState.selectedSection) { _, section in
                // 从菜单栏/设置等处跳转到代理页时自动展开分组，避免选中项藏在收起的组里。
                if SidebarNavigation.proxies.contains(where: { $0.section == section }),
                   !appState.settings.sidebarProxiesGroupExpanded {
                    appState.settings.sidebarProxiesGroupExpanded = true
                }
            }
            .safeAreaInset(edge: .bottom) {
                SidebarFooterView()
            }
        } detail: {
            ZStack {
                switch appState.selectedSection {
                case .dashboard:
                    DashboardView()
                        .navigationTitle(L("Dashboard", "仪表盘"))
                case .providerAccounts:
                    ProvidersView(category: .accounts)
                        .navigationTitle(L("Subscriptions", "订阅账号"))
                case .subscriptionGateway:
                    SubscriptionGatewayView()
                        .navigationTitle(L("CPA Gateway", "CPA 网关"))
                case .apiProviders:
                    ProvidersView(category: .apiProviders)
                        .navigationTitle(L("API Providers", "API 提供商"))
                case .costTracking:
                    StatsHubView()
                        .navigationTitle(L("Usage Stats", "用量统计"))
                case .callAnalytics:
                    CallAnalyticsView()
                        .navigationTitle(L("Call Analytics", "调用分析"))
                case .proxyManagement:
                    ClaudeHubView()
                        .navigationTitle("Claude")
                case .codexProxyManagement:
                    CodexProxyManagementView()
                        .navigationTitle(L("Codex Proxy", "Codex 代理"))
                case .opencodeManagement:
                    OpenCodeManagementView()
                        .navigationTitle(L("OpenCode Proxy", "OpenCode 代理"))
                case .scienceProxyManagement:
                    ClaudeHubView(initialTab: .science)
                        .navigationTitle("Claude")
                case .inbox:
                    InboxView()
                        .navigationTitle(L("Inbox", "消息"))
                case .settings:
                    SettingsView()
                        .navigationTitle(L("Settings", "设置"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppSurface.page(colorScheme).ignoresSafeArea())
        }
        .tint(AppAccent.control(colorScheme))
        .background(AppSurface.page(colorScheme).ignoresSafeArea())
        .task {
            await appState.performStartupFlowIfNeeded()
        }
        .task {
            sparkle.startLaunchUpdateProbeIfNeeded()
        }
        .onAppear {
            appState.registerMainWindowPresenter { section in
                appState.selectedSection = section
                openWindow(id: AppState.mainWindowID)
                DispatchQueue.main.async {
                    appState.bringMainWindowToFront()
                }
            }
        }
        .sheet(item: $appState.providerPickerMode) { mode in
            ProviderPickerView(mode: mode)
                .environmentObject(appState)
                .interactiveDismissDisabled(mode == .initialSetup)
        }
        .alert(
            L("Node is no longer in use", "节点已不再使用"),
            isPresented: Binding(
                get: { proxyVM.unusedNodeRuntimePrompt != nil },
                set: { if !$0 { proxyVM.unusedNodeRuntimePrompt = nil } }
            ),
            presenting: proxyVM.unusedNodeRuntimePrompt
        ) { _ in
            Button(L("Stop Node", "关闭节点"), role: .destructive) {
                proxyVM.resolveUnusedNodeRuntimePrompt(keepRunning: false)
            }
            Button(L("Keep Running", "保持运行")) {
                proxyVM.resolveUnusedNodeRuntimePrompt(keepRunning: true)
            }
        } message: { prompt in
            Text(L(
                "Code, Desktop and Science have all disconnected from \"\(prompt.nodeName)\". Turn off this node?",
                "Code、Desktop 与 Science 均已断开“\(prompt.nodeName)”。是否关闭该节点？"
            ))
        }
    }
}

// MARK: - Sidebar Footer
// 侧边栏左下角：常驻当前版本号；后台探测到新版本时浮现「更新」胶囊按钮，
// 点击走 Sparkle 标准更新流程（发行说明 → 安装并自动重启）。
private struct SidebarFooterView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var sparkle: SparkleController
    @Environment(\.colorScheme) private var colorScheme
    @State private var pulse = false

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return "v\(short ?? "—")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let version = sparkle.availableUpdateVersion {
                updateButton(version: version)
            }

            HStack(spacing: 5) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(appVersion)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppSurface.sidebar(colorScheme))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: sparkle.availableUpdateVersion)
    }

    private func updateButton(version: String) -> some View {
        Button {
            sparkle.checkForUpdates()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Update available", "有新版本", key: "update.available"))
                        .font(.caption.weight(.semibold))
                    Text(version)
                        .font(.system(size: 10))
                        .opacity(0.9)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [Color.blue, Color.indigo],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: Color.blue.opacity(pulse ? 0.45 : 0.2), radius: pulse ? 8 : 4, y: 2)
        }
        .buttonStyle(.plain)
        .help(L("A new version is ready. Click to view release notes and install.", "已检测到新版本，点击查看更新内容并安装。", key: "update.available.help"))
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState.shared)
        .environmentObject(ProviderRefreshCoordinator.shared)
        .environmentObject(AccountStore.shared)
        .environmentObject(ProviderActivationManager.shared)
        .environmentObject(AppSettings.shared)
        .environmentObject(ProxyViewModel())
        .environmentObject(SparkleController())
        .frame(width: 1100, height: 700)
}
