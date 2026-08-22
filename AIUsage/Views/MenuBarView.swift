import SwiftUI
import QuotaBackend

// MARK: - Menu Bar View (Main Container)
// Redesigned popover inspired by Quotio: status header, summary stats, multi-window quota bars, cost card, action footer.
// 轨道切换器 / 费用追踪 / 账号行 / 共享工具分别拆到 MenuBarView+*.swift、MenuBar*.swift。

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @ObservedObject var proxyVM = ProxyViewModel.shared
    @ObservedObject var openCodeStore = OpenCodeNodeStore.shared
    // 三条全局代理轨道各自独立观察：菜单栏切换器、Codex 账号行托管态都需要按轨实时反映。
    @ObservedObject var globalCodex = GlobalProxyManager.codex
    @ObservedObject var globalClaude = GlobalProxyManager.claude
    @ObservedObject var globalOpenCode = GlobalProxyManager.opencode
    @ObservedObject private var settings = AppSettings.shared
    @State private var activationMessage: String?
    @State private var activationSuccess = true
    // 当前展开的轨道面板（自定义内嵌覆盖层，取代原生 Menu 下拉）。nil = 全部收起。
    @State var openPanelTrack: GlobalProxyTrack?

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                menuBarHeader
                Divider()
                controlDeck
                Divider()
                menuBarContent
                costTrackingSection
                Divider()
                menuBarFooter
            }
            if let track = openPanelTrack, isMenuBarTrackVisible(track) {
                trackPanelOverlay(track: track)
            }
        }
        .frame(width: 420)
        .background(VisualEffectBlur())
    }

    // 轨道顺序与侧边栏一致：Codex → OpenCode → Claude Code。被侧边栏隐藏的 agent 同步隐藏其切换器。
    private var controlDeck: some View {
        let hidden = settings.hiddenSidebarSections
        return HStack(spacing: 0) {
            compactAccountsBadge
                .frame(maxWidth: .infinity)
            if AgentVisibility.isVisible(.codex, hidden: hidden) {
                proxyTrackSwitcher(family: .codex)
                    .frame(maxWidth: .infinity)
            }
            if AgentVisibility.isVisible(.opencode, hidden: hidden) {
                openCodeTrackSwitcher()
                    .frame(maxWidth: .infinity)
            }
            if AgentVisibility.isVisible(.claude, hidden: hidden) {
                proxyTrackSwitcher(family: .claude)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Header

    private var overallStatus: OverallHealthStatus {
        let hidden = settings.hiddenSidebarSections
        let groups = visibleQuotaProviderGroups
        let providers = refreshCoordinator.providers.filter {
            !AgentVisibility.isProviderHidden($0.baseProviderId, hidden: hidden)
        }
        let hasCritical = providers.contains { $0.status == .error }
        let hasWarning = providers.contains { ($0.remainingPercent ?? 100) < 35 }
        if hasCritical { return .critical }
        if hasWarning { return .warning }
        if groups.isEmpty && !refreshCoordinator.isLoading { return .idle }
        return .healthy
    }

    private var menuBarHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("AIUsage")
                            .font(.system(size: 14, weight: .bold, design: .rounded))

                        Circle()
                            .fill(overallStatus.color)
                            .frame(width: 7, height: 7)
                    }

                    if let lastRefresh = refreshCoordinator.lastRefreshTime {
                        RefreshableTimeView(
                            date: lastRefresh,
                            language: appState.language,
                            font: .system(size: 10),
                            foregroundStyle: .secondary
                        )
                    } else {
                        Text(L("Not refreshed yet", "尚未刷新"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button {
                refreshCoordinator.refreshAllProviders()
            } label: {
                Group {
                    if refreshCoordinator.isAnyRefreshInProgress {
                        SmallProgressView().frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.06))
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(refreshCoordinator.isAnyRefreshInProgress)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Compact Badges

    private var compactAccountsBadge: some View {
        let groups = visibleQuotaProviderGroups
        let totalAccounts = groups.reduce(0) { $0 + $1.accounts.count }
        let connectedAccounts = groups.reduce(0) { $0 + $1.connectedCount }

        let iconColor: Color = connectedAccounts == totalAccounts && totalAccounts > 0
            ? Color(red: 0.15, green: 0.78, blue: 0.40)
            : connectedAccounts > 0 ? .orange : .secondary

        return HStack(spacing: 4) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(iconColor)
            Text("\(connectedAccounts)/\(totalAccounts)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(connectedAccounts > 0 ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private var quotaProviderGroups: [ProviderAccountGroup] { visibleQuotaProviderGroups }

    private var visibleQuotaProviderGroups: [ProviderAccountGroup] {
        let hidden = settings.hiddenSidebarSections
        return appState.providerAccountGroups.filter { group in
            !AgentVisibility.isProviderHidden(group.providerId, hidden: hidden)
                && group.accounts.contains {
                    AgentVisibility.isQuotaAccount(
                        providerId: group.providerId,
                        category: $0.liveProvider?.category
                    )
                }
        }
    }

    private func isMenuBarTrackVisible(_ track: GlobalProxyTrack) -> Bool {
        let hidden = settings.hiddenSidebarSections
        switch track {
        case .codex: return AgentVisibility.isVisible(.codex, hidden: hidden)
        case .opencode: return AgentVisibility.isVisible(.opencode, hidden: hidden)
        case .claude, .desktop, .science: return AgentVisibility.isVisible(.claude, hidden: hidden)
        }
    }

    // MARK: - Content

    private var menuBarContent: some View {
        Group {
            if refreshCoordinator.isLoading && refreshCoordinator.providers.isEmpty {
                VStack(spacing: 12) {
                    SmallProgressView().frame(width: 20, height: 20)
                    Text(L("Loading...", "加载中..."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else if quotaProviderGroups.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(L("No providers", "暂无服务"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(quotaProviderGroups) { group in
                            MenuBarProviderSection(
                                group: group,
                                codexProxyActive: proxyVM.activatedId(isCodex: true) != nil,
                                codexGlobalProxyManaged: globalCodex.isEnabled,
                                activationMessage: $activationMessage,
                                activationSuccess: $activationSuccess
                            )
                            .environmentObject(appState)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 600)
                .overlay(alignment: .bottom) {
                    if let message = activationMessage {
                        activationToast(message: message, success: activationSuccess)
                    }
                }
            }
        }
    }

    private func activationToast(message: String, success: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(success ? .green : .red)
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.easeOut(duration: 0.3)) {
                    activationMessage = nil
                }
            }
        }
    }

    // MARK: - Footer

    private var menuBarFooter: some View {
        HStack(spacing: 6) {
            footerButton(L("Open AIUsage", "打开 AIUsage"), shortcut: "⌘O") {
                openMainWindow(section: .dashboard)
            }

            Spacer()

            footerButton(L("Refresh", "刷新"), shortcut: "⌘R") {
                refreshCoordinator.refreshAllProviders()
            }

            footerButton(L("Quit", "退出"), shortcut: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func footerButton(_ title: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(shortcut)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private func openMainWindow(section: AppSection) {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.revealMainWindow(section: section)
        } else {
            appState.presentMainWindow(section: section)
        }
    }

    func formatCostCompact(_ usd: Double) -> String { MenuBarHelpers.formatCostCompact(usd) }
}

// MARK: - Overall Health Status

private enum OverallHealthStatus {
    case healthy, warning, critical, idle

    var color: Color {
        switch self {
        case .healthy: return .green
        case .warning: return .orange
        case .critical: return .red
        case .idle: return .gray
        }
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState.shared)
        .environmentObject(ProviderRefreshCoordinator.shared)
        .environmentObject(ProviderActivationManager.shared)
}
