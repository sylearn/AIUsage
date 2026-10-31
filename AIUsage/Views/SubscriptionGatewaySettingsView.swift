import SwiftUI
import Combine
import QuotaBackend

// MARK: - CPA Settings Categories

private enum GatewaySettingsCategory: String, CaseIterable, Identifiable {
    case runtime
    case tokenSaver
    case keys
    case updates
    case versions
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .runtime: return L("Runtime", "运行")
        case .tokenSaver: return L("Token Saver", "Token 节省")
        case .keys: return L("API Keys", "密钥")
        case .updates: return L("Updates", "更新")
        case .versions: return L("Versions", "版本")
        case .diagnostics: return L("Diagnostics", "诊断")
        }
    }

    var icon: String {
        switch self {
        case .runtime: return "gearshape"
        case .tokenSaver: return "bolt.fill"
        case .keys: return "key.fill"
        case .updates: return "arrow.down.circle"
        case .versions: return "shippingbox"
        case .diagnostics: return "stethoscope"
        }
    }

    var color: Color {
        switch self {
        case .runtime: return .gray
        case .tokenSaver: return .purple
        case .keys: return .indigo
        case .updates: return .blue
        case .versions: return .orange
        case .diagnostics: return .teal
        }
    }
}

// MARK: - Settings View

struct SubscriptionGatewaySettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var manager: CLIProxyGatewayManager
    @ObservedObject var runtime: CLIProxyRuntimeController
    @ObservedObject private var navigation = CLIProxyGatewayNavigation.shared
    @Binding var draftSettings: CLIProxyGatewaySettings
    @Binding var pendingVersionDeletion: CLIProxyInstalledVersion?

    @StateObject private var tokenSaverReleases = TokenSaverReleaseManager()
    @State private var selectedCategory: GatewaySettingsCategory = .runtime
    @State private var showLANConfirmation = false

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
            Divider()
            settingsDetail
        }
        .onAppear { consumeSettingsDestination() }
        .onChange(of: navigation.settingsDestination) { _, _ in
            consumeSettingsDestination()
        }
        .alert(L("Enable Local Network Access?", "开启局域网访问？"), isPresented: $showLANConfirmation) {
            Button(L("Enable and Apply", "开启并应用"), role: .destructive) {
                applySettings()
            }
            Button(L("Cancel", "取消"), role: .cancel) {
                draftSettings.allowLANAccess = runtime.settings.allowLANAccess
            }
        } message: {
            Text(L(
                "CPA will listen on all IPv4 interfaces over HTTP. Keep keys private; use only on trusted networks.",
                "CPA 将通过 HTTP 监听所有 IPv4 接口。请妥善保管密钥，仅在可信网络中开启。"
            ))
        }
    }

    private func consumeSettingsDestination() {
        guard let destination = navigation.settingsDestination,
              let category = GatewaySettingsCategory(rawValue: destination.rawValue) else { return }
        selectedCategory = category
        navigation.settingsDestination = nil
    }

    // MARK: - Sidebar

    private var settingsSidebar: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(GatewaySettingsCategory.allCases) { category in
                    categoryRow(category)
                }
            }
            .padding(10)
        }
        .frame(width: 168)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppSurface.sidebar(colorScheme))
    }

    private func categoryRow(_ category: GatewaySettingsCategory) -> some View {
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
                    .foregroundStyle(selectedCategory == category ? .white : .primary)
                Spacer(minLength: 0)
                if category == .runtime, hasUnappliedChanges {
                    Circle()
                        .fill(selectedCategory == category ? Color.white.opacity(0.9) : Color.orange)
                        .frame(width: 6, height: 6)
                } else if category == .updates, manager.hasUpdate {
                    Circle()
                        .fill(selectedCategory == category ? Color.white.opacity(0.9) : Color.orange)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selectedCategory == category ? Color.accentColor : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail

    @ViewBuilder
    private var settingsDetail: some View {
        switch selectedCategory {
        case .runtime:
            VStack(alignment: .leading, spacing: 12) {
                errorBanners
                SubscriptionGatewaySettingsRuntimePane(
                    runtime: runtime,
                    draftSettings: $draftSettings,
                    onApply: requestApplySettings
                )
                .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .tokenSaver:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    errorBanners
                    SubscriptionGatewaySettingsTokenSaverPane()
                }
                .padding(22)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        case .keys:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    errorBanners
                    SubscriptionGatewayClientKeysPane(runtime: runtime)
                }
                .padding(22)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        case .updates, .versions, .diagnostics:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    errorBanners
                    switch selectedCategory {
                    case .updates:
                        updatesSection
                        TokenSaverUpdatesSection(manager: tokenSaverReleases, onOpenRuntime: { selectedCategory = .tokenSaver })
                    case .versions: versionsSection
                    case .diagnostics: diagnosticsSection
                    default: EmptyView()
                    }
                }
                .padding(22)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private var errorBanners: some View {
        if let error = manager.lastError { GatewayErrorBanner(message: error) }
        if case .failed(let error) = runtime.state { GatewayErrorBanner(message: error) }
    }

    // Runtime / Keys panes live in dedicated files.

    // MARK: - Updates

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: L("Updates", "更新")) {
                updateStatusPill
            }

            GatewayCard(padding: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        versionChip(
                            title: L("Installed", "已装"),
                            value: manager.currentVersion.map { "v\($0)" } ?? "—"
                        )
                        versionChip(
                            title: L("Latest", "最新"),
                            value: manager.latestRelease.map { "v\($0.version)" } ?? "—"
                        )
                    }

                    if manager.operation.isBusy {
                        ProgressView(operationLabel)
                    }

                    HStack {
                        if let checkedAt = manager.lastCheckedAt {
                            Text(checkedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Check", "检查")) {
                            Task { await manager.checkForUpdates(force: true) }
                        }
                        .disabled(manager.operation.isBusy)
                        Button(primaryUpdateActionTitle) {
                            Task { await manager.installOrUpdateLatest() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            manager.operation.isBusy
                                || (manager.latestRelease != nil && !manager.hasUpdate && manager.isInstalled)
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var updateStatusPill: some View {
        if manager.hasUpdate {
            GatewayQuietBadge(text: L("Update available", "有更新"), tint: .orange)
        } else if manager.isInstalled, manager.latestRelease != nil {
            GatewayQuietBadge(text: L("Up to date", "已最新"), tint: .green)
        } else if manager.isInstalled {
            GatewayQuietBadge(text: L("Not checked", "未检查"), tint: .secondary)
        }
    }

    // MARK: - Versions

    private var versionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: L("Versions & rollback", "版本与回退"))

            GatewayCard(padding: 4) {
                if manager.installedVersions.isEmpty {
                    Text(L("No CPA versions installed.", "尚未安装 CPA。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 72)
                } else {
                    VStack(spacing: 0) {
                        ForEach(manager.installedVersions) { version in
                            HStack(spacing: 10) {
                                Image(systemName: version.isCurrent ? "checkmark.seal.fill" : "shippingbox")
                                    .foregroundStyle(version.isCurrent ? .green : .secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("v\(version.version)")
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                    Text(version.installedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if version.isCurrent {
                                    GatewayQuietBadge(text: L("Active", "当前"), tint: .green)
                                }
                                Spacer(minLength: 8)
                                if !version.isCurrent {
                                    Button(L("Activate", "切换")) {
                                        Task { await manager.activate(version) }
                                    }
                                    Button(role: .destructive) {
                                        pendingVersionDeletion = version
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(L("Delete", "删除"))
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            if version.id != manager.installedVersions.last?.id {
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: L("Diagnostics", "诊断"))

            GatewayCard(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView {
                        Text(runtime.recentLogs.isEmpty
                             ? L("No logs yet.", "暂无日志。")
                             : runtime.recentLogs.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                            .padding(10)
                    }
                    .frame(maxHeight: 280)
                    .background(
                        Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                    HStack {
                        Button {
                            manager.revealStorage()
                        } label: {
                            Label(L("Managed files", "托管文件"), systemImage: "folder")
                        }
                        Spacer()
                        Link(
                            L("Repository", "仓库"),
                            destination: URL(string: "https://github.com/router-for-me/CLIProxyAPI")!
                        )
                        .font(.caption)
                        Button(L("Notices", "许可")) {
                            manager.openThirdPartyNotices()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Shared chrome

    private func sectionHeader<Trailing: View>(
        title: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack {
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer()
            trailing()
        }
    }

    private func settingsRow<Trailing: View>(
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
    }

    private func versionChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var hasUnappliedChanges: Bool {
        draftSettings.normalized != runtime.settings.normalized
    }

    private func requestApplySettings() {
        if draftSettings.allowLANAccess, !runtime.settings.allowLANAccess {
            showLANConfirmation = true
        } else {
            applySettings()
        }
    }

    private func applySettings() {
        Task {
            await runtime.applySettings(draftSettings)
            draftSettings = runtime.settings
            if runtime.state.isRunning { await manager.refreshAccounts() }
        }
    }

    private var primaryUpdateActionTitle: String {
        if !manager.isInstalled { return L("Install", "安装") }
        if manager.latestRelease == nil { return L("Check & Update", "检查并更新") }
        if manager.hasUpdate { return L("Update", "更新") }
        return L("Up to date", "已最新")
    }

    private var operationLabel: String {
        switch manager.operation {
        case .idle: ""
        case .checking: L("Checking…", "检查中…")
        case .downloading(let version): L("Downloading v\(version)…", "下载 v\(version)…")
        case .verifying(let version): L("Verifying v\(version)…", "校验 v\(version)…")
        case .installing(let version): L("Installing v\(version)…", "安装 v\(version)…")
        case .activating(let version): L("Activating v\(version)…", "切换到 v\(version)…")
        }
    }
}

// MARK: - Token Saver updates section

struct TokenSaverUpdatesSection: View {
    @ObservedObject private var manager: TokenSaverReleaseManager
    @State private var pendingInstall: TokenSaverReleaseTool?
    @State private var showRTKSetup = false
    private let onOpenRuntime: () -> Void

    @MainActor
    init(manager: TokenSaverReleaseManager, onOpenRuntime: @escaping () -> Void) {
        self.manager = manager
        self.onOpenRuntime = onOpenRuntime
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Token Saver updates", "Token Saver 更新")).font(.title3.weight(.semibold))
            Label(L("1. Install RTK (Homebrew) → 2. Enable tools in Token Saver → 3. Optional: check RTK updates", "1. 安装 RTK (Homebrew) → 2. 在 Token 节省页启用工具 → 3. 可选：检查 RTK 更新"), systemImage: "list.number")
                .font(.subheadline.weight(.medium))
            Text(L("Caveman and Ponytail use built-in compact rules directly in AIUsage — no reference downloads or updates are needed. RTK requires installing the binary via Homebrew. Reload a new coding session after changes. No downloaded scripts are executed.",
                   "Caveman 和 Ponytail 直接使用 AIUsage 内置精简规则——无需下载或更新参考文档。RTK 需通过 Homebrew 安装二进制文件。更改后请开启新的编程会话。不会执行下载的脚本。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(action: onOpenRuntime) {
                Label(L("Open Token Saver to enable tools", "打开 Token 节省页以启用工具"), systemImage: "bolt.fill")
            }.accessibilityIdentifier("token-saver-open-runtime")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let coolingDown = manager.retryAfter.map { $0 > context.date } ?? false
                VStack(alignment: .leading, spacing: 12) {
                    if let retry = manager.retryAfter, coolingDown {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L("GitHub checks paused", "GitHub 检查已暂停")).fontWeight(.semibold)
                                Text(L("Try again after \(retry.formatted(date: .abbreviated, time: .standard)) (local time). Checks resume then; nothing retries automatically. This shared GitHub API limit is not your AI quota.",
                                       "请在本地时间 \(retry.formatted(date: .abbreviated, time: .standard)) 后重试。届时可再次检查，不会自动重试。此共享 GitHub API 限制不是 AI 配额。"))
                            }
                        } icon: { Image(systemName: "clock.badge.exclamationmark") }
                        .font(.caption).padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("token-saver-cooldown")
                    }
                    ForEach(TokenSaverReleaseTool.allCases) { tool in
                        toolRow(tool, coolingDown: coolingDown)
                    }
                }
            }
        }
        .sheet(isPresented: $showRTKSetup) { rtkSetup }
        .alert(L("Upgrade RTK with Homebrew?", "通过 Homebrew 更新 RTK？"), isPresented: Binding(
            get: { pendingInstall == .rtk }, set: { if !$0 { pendingInstall = nil } }
        )) {
            Button(L("Run brew upgrade rtk", "运行 brew upgrade rtk")) {
                pendingInstall = nil
                Task { await manager.updateRTK() }
            }
            Button(L("Cancel", "取消"), role: .cancel) { pendingInstall = nil }
        } message: {
            Text(L("Runs only brew upgrade rtk using trusted Homebrew. RTK must already be installed. Homebrew may update RTK and required dependencies outside AIUsage storage. No brew install or downloaded shell installer is run.", "仅通过可信 Homebrew 运行 brew upgrade rtk。RTK 必须已安装。Homebrew 可能在 AIUsage 存储之外更新 RTK 及必要依赖；不会运行 brew install 或下载的 Shell 安装器。"))
        }
    }

    private func toolRow(_ tool: TokenSaverReleaseTool, coolingDown: Bool) -> some View {
        let status = manager.statuses[tool] ?? .init()
        return GatewayCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(tool.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Link(L("View source & docs ↗", "查看源码和文档 ↗"), destination: tool.upstreamURL).font(.caption)
                }
                Text(toolSummary(tool)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if tool == .rtk {
                    HStack(alignment: .top, spacing: 16) {
                        versionLabel(L("Installed version", "已安装版本"),
                                     status.installedBinaryVersion ?? (status.binaryInspected ? L("Not installed in Homebrew", "Homebrew 未安装") : L("Unknown · not inspected", "未知 · 未检测")))
                        versionLabel(L("Latest (GitHub)", "最新（GitHub）"), status.latest?.version ?? L("Not checked", "未检查"))
                    }
                    if let notice = status.notice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = status.error, !coolingDown {
                        Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("token-saver-\(tool.rawValue)-error")
                    }
                    Label(actionHint(tool, status: status, coolingDown: coolingDown), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("token-saver-\(tool.rawValue)-guidance")
                    HStack {
                        if status.isBusy { ProgressView().controlSize(.small) }
                        if let checked = status.checkedAt {
                            Text(checked.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("How to install…", "如何安装…")) { showRTKSetup = true }
                            .accessibilityIdentifier("token-saver-rtk-setup")
                        Button(status.isBusy ? L("Working…", "处理中…") : L("Check versions", "检查版本")) { Task { await manager.check(tool) } }
                            .disabled(status.isBusy || coolingDown).help(L("Look up GitHub versions; RTK also reads its Homebrew version. Nothing is installed.", "查询 GitHub 版本；RTK 同时读取 Homebrew 版本。不会安装任何内容。")).accessibilityIdentifier("token-saver-\(tool.rawValue)-check")
                        Button(L("Update RTK", "更新 RTK")) { pendingInstall = tool }
                            .disabled(status.isBusy || status.latest == nil || !status.brewAvailable || status.installedBinaryVersion == nil)
                            .accessibilityIdentifier("token-saver-\(tool.rawValue)-update")
                    }
                } else {
                    versionLabel(L("Policy source", "策略来源"),
                                 L("Built-in compact rules · Enable in Token Saver", "内置精简规则 · 在 Token 节省页启用"))
                    Label(L("Included directly in AIUsage. No reference download is needed — enable in Token Saver and start a new coding session.", "已直接内置于 AIUsage，无需下载参考文档——在 Token 节省页启用并开启新的编程会话即可。"), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("token-saver-\(tool.rawValue)-guidance")
                }
            }
        }
        .accessibilityIdentifier("token-saver-\(tool.rawValue)-release")
    }

    private func toolSummary(_ tool: TokenSaverReleaseTool) -> String {
        switch tool {
        case .rtk: return L("Command-line tool that compresses coding command output. Requires RTK on your coding agent’s PATH; AIUsage does not intercept commands.", "压缩编程命令输出的命令行工具。需在编程代理的 PATH 中安装 RTK；AIUsage 不会拦截命令。")
        case .caveman: return L("Instruction rules for shorter coding explanations, without rewriting your code or API traffic.", "通过指令规则缩短编程说明，不重写代码或 API 流量。")
        case .ponytail: return L("Instruction rules that favor reuse, standard libraries and minimal, verified code.", "优先复用、标准库和最少且经过验证的代码的指令规则。")
        }
    }

    private func actionHint(_ tool: TokenSaverReleaseTool, status: TokenSaverReleaseManager.Status, coolingDown: Bool) -> String {
        if status.isBusy { return L("Operation in progress. Please wait.", "操作进行中，请稍候。") }
        if tool == .rtk && !status.brewAvailable { return L("Homebrew unavailable. Open How to install for setup options; version checks still work.", "Homebrew 不可用。打开“如何安装”查看设置选项；仍可检查最新版本。") }
        if tool == .rtk && status.binaryInspected && status.installedBinaryVersion == nil { return L("Update unavailable: install RTK with Homebrew first, then Check versions. Other installations are not managed here.", "暂不能更新：先通过 Homebrew 安装 RTK，再检查版本。此处不管理其他安装方式。") }
        if coolingDown { return L("GitHub checks and rule downloads are paused until the local time shown above.", "GitHub 检查和规则下载已暂停至上方显示的本地时间。") }
        if status.latest == nil { return L("Start with Check versions to unlock downloads. This does not enable the tool.", "先检查版本以解锁下载。此操作不会启用工具。") }
        if tool == .rtk { return L("Update RTK runs brew upgrade rtk after confirmation. Homebrew may lag behind GitHub. Then enable RTK in Token Saver and start a new coding session.", "确认后通过 brew upgrade rtk 更新。Homebrew 版本可能落后于 GitHub。之后在 Token 节省页启用 RTK 并开始新的编程会话。") }
        if status.isCurrent && status.error == nil { return L("Latest checked reference saved. Compact built-in policy is separate; enable it in Token Saver and start a new coding session. No further download needed.", "已保存最新检查的参考文档。精简内置策略单独生效；请在 Token 节省页启用并开始新会话，无需再次下载。") }
        return L("Download reference asks for confirmation; it does not inject full upstream text. Compact built-in policies work without downloads. Enable tools in Token Saver and start a new coding session.", "下载参考文档需要确认，不会注入完整上游文本。精简内置策略无需下载即可使用。请在 Token 节省页启用工具并开始新会话。")
    }

    private var rtkSetup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L("Set up RTK", "设置 RTK"), systemImage: "terminal").font(.title2.weight(.semibold))
            Text(L("AIUsage does not install Homebrew or run downloaded installers. Review and run the command yourself in Terminal. Installing RTK alone does not enable AIUsage’s coding rules.", "AIUsage 不会安装 Homebrew 或执行下载的安装器。请自行审核并在终端运行命令。仅安装 RTK 不会启用 AIUsage 编程规则。"))
                .fixedSize(horizontal: false, vertical: true)
            Link(L("1. Install Homebrew if needed, then restart AIUsage ↗", "1. 如需安装 Homebrew，安装后重启 AIUsage ↗"), destination: URL(string: "https://brew.sh")!)
            Text(L("2. Install RTK in Terminal", "2. 在终端安装 RTK")).fontWeight(.semibold)
            Text("brew install rtk").font(.body.monospaced()).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text(L("3. Verify rtk --version in your coding agent’s terminal. Return here and Check versions to detect the Homebrew installation. Enable Compress tool output (RTK) in Token Saver, then start a new coding session.", "3. 在编程代理的终端验证 rtk --version。返回此处检查版本以识别 Homebrew 安装。在 Token 节省页启用 RTK 压缩工具输出，然后开始新的编程会话。"))
                .fixedSize(horizontal: false, vertical: true)
            Text(L("Already installed another way? Keep that setup and update it externally. AIUsage only manages upgrades for the Homebrew rtk package; it does not install hooks or change your PATH.", "已通过其他方式安装？可保留现有设置并自行更新。AIUsage 仅管理 Homebrew rtk 软件包的更新，不会安装钩子或修改 PATH。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Link(L("RTK installation docs ↗", "RTK 安装文档 ↗"), destination: TokenSaverReleaseTool.rtk.upstreamURL)
                Spacer()
                Button(L("Done", "完成")) { showRTKSetup = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 530)
        .accessibilityIdentifier("token-saver-rtk-setup-guide")
    }

    private func versionLabel(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit()).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
