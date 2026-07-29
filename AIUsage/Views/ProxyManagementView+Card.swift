import SwiftUI
import QuotaBackend

// MARK: - Configuration Card (Equatable)

enum ClaudeCodeNodeRoute: Equatable {
    case direct
    case gateway
}

struct ClaudeNodeUsage: Equatable {
    var codeRoute: ClaudeCodeNodeRoute?
    var codeRunning = false
    var desktop = false
    var desktopRunning = false
    var science = false
    var scienceRunning = false

    static let none = ClaudeNodeUsage()
    var isEmpty: Bool { codeRoute == nil && !desktop && !science }
}

/// Standalone Equatable View so SwiftUI can skip re-rendering cards whose inputs haven't changed.
/// When `selectedConfigId` changes, only the previously-selected and newly-selected cards re-render;
/// the rest are skipped entirely. Same optimization applies during drag-and-drop state changes.
struct ConfigurationCardView: View, Equatable {
    let config: ProxyConfiguration
    let isActive: Bool
    let isProxyOnlyRunning: Bool
    let isRuntimeManuallyHeld: Bool
    let showsActivationControl: Bool
    let isBusy: Bool
    let isActivationManaged: Bool
    let canAttachCodeToGateway: Bool
    let claudeUsage: ClaudeNodeUsage
    let deletionBlockReason: String?
    let isSelected: Bool
    let statsRequests: Int
    let statsSuccessRate: Double
    let lastRequestAt: Date?
    let connectivityState: ProxyConnectivityTestState?

    var onDragChanged: (CGFloat) -> Void = { _ in }
    var onDragEnded: () -> Void = {}
    var onToggleActivation: () -> Void = {}
    var onToggleProxyOnly: () -> Void = {}
    var onCopyLaunchCommand: () -> Void = {}
    var onTestConnectivity: () -> Void = {}
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}
    var onDuplicate: () -> Void = {}
    var onSelectDefaultModel: (String) -> Void = { _ in }
    var onToggleSelection: () -> Void = {}

    /// 失败明细 Popover 的展开态。属于本卡片局部 UI 状态，不参与 Equatable 比较。
    /// 注意：必须为 internal（非 private），否则会把结构体的成员初始化器降级为 private，
    /// 破坏 `ProxyManagementView+List` 跨文件的卡片构造。
    @State var showConnectivityDetail = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.config == rhs.config &&
        lhs.isActive == rhs.isActive &&
        lhs.isProxyOnlyRunning == rhs.isProxyOnlyRunning &&
        lhs.isRuntimeManuallyHeld == rhs.isRuntimeManuallyHeld &&
        lhs.showsActivationControl == rhs.showsActivationControl &&
        lhs.isBusy == rhs.isBusy &&
        lhs.isActivationManaged == rhs.isActivationManaged &&
        lhs.canAttachCodeToGateway == rhs.canAttachCodeToGateway &&
        lhs.claudeUsage == rhs.claudeUsage &&
        lhs.deletionBlockReason == rhs.deletionBlockReason &&
        lhs.isSelected == rhs.isSelected &&
        lhs.statsRequests == rhs.statsRequests &&
        lhs.statsSuccessRate == rhs.statsSuccessRate &&
        lhs.lastRequestAt == rhs.lastRequestAt &&
        lhs.connectivityState == rhs.connectivityState
    }

    private static let anthropicBrand = Color(red: 0.85, green: 0.47, blue: 0.34)
    private static let openAIBrand = Color(red: 0.29, green: 0.73, blue: 0.56)
    private static let codexBrand = Color(red: 0.40, green: 0.52, blue: 0.92)
    private static let nodeRuntimeBrand = Color.teal

    private var brandColor: Color {
        switch config.nodeType {
        case .anthropicDirect: return Self.anthropicBrand
        case .openaiProxy: return Self.openAIBrand
        case .codexProxy: return Self.codexBrand
        }
    }

    // MARK: - Activation Labels (node-type aware)
    // Codex 节点写 ~/.codex/config.toml，Claude/OpenAI 代理节点写 ~/.claude/settings.json，
    // 所以激活相关文案要按目标 CLI 区分，不能一律写「Claude」。

    /// 激活所针对的目标 CLI 名称：Codex 节点为 "Codex"，其余为 "Claude"。
    private var activationTargetName: String {
        config.nodeType.isCodex ? "Codex" : "Claude Code"
    }

    private var applyLabel: String {
        L("Apply to \(activationTargetName)", "接入 \(activationTargetName)")
    }

    private var disconnectLabel: String {
        L("Disconnect \(activationTargetName)", "断开 \(activationTargetName)")
    }

    private var connectedUnavailableLabel: String {
        L("Unavailable while connected to \(activationTargetName)", "接入 \(activationTargetName) 时不可用")
    }

    private var productRuntimeOwners: [String] {
        var owners: [String] = []
        if claudeUsage.codeRoute == .gateway { owners.append("Code") }
        if claudeUsage.desktop { owners.append("Desktop") }
        if claudeUsage.science { owners.append("Science") }
        return owners
    }

    private var runtimeStopIsProductOwned: Bool {
        !showsActivationControl && isProxyOnlyRunning && !isRuntimeManuallyHeld && !productRuntimeOwners.isEmpty
    }

    private var nodeSwitchHelp: String {
        if runtimeStopIsProductOwned {
            return L(
                "This node is currently used by \(productRuntimeOwners.joined(separator: " · "))",
                "该节点正由 \(productRuntimeOwners.joined(separator: " · ")) 使用"
            )
        }
        return isProxyOnlyRunning
            ? L("Turn off this node", "关闭节点")
            : L("Turn on this node for Code, Desktop and Science", "开启节点，供 Code、Desktop 与 Science 使用")
    }

    private var launchCommandLabel: String {
        config.nodeType.isCodex
            ? L("Copy Codex Launch Command", "复制 Codex 启动命令")
            : L("Copy Claude Code Launch Command", "复制 Claude Code 启动命令")
    }

    // MARK: - Model Quick Switch（模型目录多于一个模型时提供）

    /// 模型目录中的可切换模型（去空名）。
    private var libraryModels: [String] {
        config.modelCatalog.models.filter { !$0.isEmpty }
    }

    /// 当前生效模型：Codex = config.toml 的 model；Claude 家族 = settings.json 的 model。
    private var currentDefaultModel: String {
        config.nodeType.isCodex ? config.codexModel : config.defaultModel
    }

    /// 切换候选：当前模型不在库中（手输的自定义名）时补到首位，避免 Picker 选中态丢失。
    private var modelSwitchOptions: [String] {
        if currentDefaultModel.isEmpty || libraryModels.contains(currentDefaultModel) {
            return libraryModels
        }
        return [currentDefaultModel] + libraryModels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                nodeTypeBadge
                if !claudeUsage.isEmpty {
                    consumerBadges
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.quaternary)
                    .frame(width: 16, height: 28)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.openHand.push() }
                        else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 3, coordinateSpace: .global)
                            .onChanged { onDragChanged($0.translation.height) }
                            .onEnded { _ in onDragEnded() }
                    )

                VStack(alignment: .trailing, spacing: 4) {
                    statPill(icon: "arrow.up.arrow.down", value: "\(statsRequests)", color: .blue)
                        .help(L("Total Requests", "总请求数"))
                    statPill(icon: "checkmark.circle", value: String(format: "%.0f%%", statsSuccessRate), color: .green)
                        .help(L("Success Rate", "成功率"))
                }
                .frame(width: 80)
                .opacity(config.needsProxyProcess ? 1 : 0)

                VStack(alignment: .leading, spacing: 2) {
                    Text(config.name)
                        .font(.system(size: 15, weight: .bold))
                    Text(config.displayURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    connectivityStatusLine
                }

                Spacer()

                HStack(spacing: 6) {
                    if showsActivationControl {
                        Toggle("", isOn: Binding(
                            get: { isActive },
                            set: { newValue in if newValue != isActive { onToggleActivation() } }
                        ))
                        .toggleStyle(ProxyActivationToggleStyle(
                            brandColor: brandColor,
                            isBusy: isBusy
                        ))
                        .disabled(isBusy || isActivationManaged)
                        .instantTooltip(isActivationManaged
                            ? L("Claude Code is managed by Code Gateway", "Claude Code 正由 Code 网关管理")
                            : (isActive ? disconnectLabel : applyLabel))
                    }

                    if config.needsProxyProcess {
                        HStack(spacing: 5) {
                            Text(isProxyOnlyRunning ? L("On", "已开启") : L("Off", "未开启"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isProxyOnlyRunning ? Color.green : Color.secondary)
                            Toggle("", isOn: Binding(
                                get: { isProxyOnlyRunning },
                                set: { newValue in
                                    if newValue != isProxyOnlyRunning { onToggleProxyOnly() }
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .tint(.teal)
                        }
                        .disabled(isBusy || isActive || runtimeStopIsProductOwned)
                        .instantTooltip(isActive ? connectedUnavailableLabel : nodeSwitchHelp)
                    }

                    connectivityControl

                    Button(action: onEdit) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .instantTooltip(L("Edit", "编辑"))

                    Button(action: onDelete) {
                        Image(systemName: "trash.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy || deletionBlockReason != nil)
                    .instantTooltip(deletionBlockReason ?? L("Delete", "删除"))
                }
            }

            if isSelected {
                Divider()
                detailContent
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(cardBackgroundColor)
        )
        .overlay(alignment: .leading) {
            if isActive || isProxyOnlyRunning {
                let statusColor = isActive ? brandColor : Self.nodeRuntimeBrand
                Capsule()
                    .fill(statusColor)
                    .frame(width: 3)
                    .padding(.vertical, 10)
                    .padding(.leading, 3)
                    .shadow(color: statusColor.opacity(0.4), radius: 4, x: 0, y: 0)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(cardBorderColor, lineWidth: (isActive || isProxyOnlyRunning) ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleSelection)
        .contextMenu { cardContextMenu }
    }

    // MARK: - Card Styling

    private var cardBackgroundColor: Color {
        if isActive { return brandColor.opacity(0.06) }
        if isProxyOnlyRunning { return Self.nodeRuntimeBrand.opacity(0.04) }
        if isSelected { return brandColor.opacity(0.04) }
        return Color(nsColor: .controlBackgroundColor).opacity(0.5)
    }

    private var cardBorderColor: Color {
        if isActive { return brandColor.opacity(0.5) }
        if isProxyOnlyRunning { return Self.nodeRuntimeBrand.opacity(0.35) }
        if isSelected { return brandColor.opacity(0.25) }
        return Color.primary.opacity(0.06)
    }

    // MARK: - Connectivity Test

    /// 未测试 = 中性灰；成功 = 绿；失败 = 红。状态明细由名称下方的状态行承载。
    private var connectivityTint: Color {
        guard let succeeded = connectivityState?.lastSucceeded else { return .secondary }
        return succeeded ? .green : .red
    }

    /// tooltip 仅保留简短动作标签；长错误改由失败状态行的 Popover 承载。
    private var connectivityActionLabel: String {
        connectivityState?.isTesting == true
            ? L("Testing Connectivity", "正在测试连通性")
            : L("Test Connectivity", "测试连通性")
    }

    /// 右侧动作区里只保留等宽的「测试」触发按钮（着色：灰=未测/绿=通/红=败），
    /// 结果明细移到节点名/URL 下方的状态行，避免可变宽度撑动作图标导致跨行错位。
    private var connectivityControl: some View {
        Button(action: onTestConnectivity) {
            Group {
                if connectivityState?.isTesting == true {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(connectivityTint)
                }
            }
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .disabled(isBusy || connectivityState?.isTesting == true)
        .instantTooltip(connectivityActionLabel)
    }

    /// 连通性结果状态行（在节点名/URL 下方常驻）：状态点 + 摘要 + 上次测试时间。
    /// 失败时整行可点开 Popover 查看完整报文。
    @ViewBuilder
    private var connectivityStatusLine: some View {
        if let state = connectivityState, !state.isTesting, let succeeded = state.lastSucceeded {
            if succeeded {
                connectivityStatusContent(
                    state: state,
                    color: .green,
                    systemImage: "checkmark.circle.fill",
                    text: connectivitySuccessText(state)
                )
            } else {
                Button {
                    showConnectivityDetail = true
                } label: {
                    HStack(spacing: 4) {
                        connectivityStatusContent(
                            state: state,
                            color: .red,
                            systemImage: "exclamationmark.circle.fill",
                            text: connectivityFailureText(state)
                        )
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .instantTooltip(L("View error details", "查看错误详情"))
                .popover(isPresented: $showConnectivityDetail, arrowEdge: .bottom) {
                    connectivityDetailPopover(state)
                }
            }
        }
    }

    private func connectivityStatusContent(state: ProxyConnectivityTestState, color: Color, systemImage: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
            if let testedAt = state.testedAt {
                Text(Self.relativeFormatter.localizedString(for: testedAt, relativeTo: Date()))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    private func connectivitySuccessText(_ state: ProxyConnectivityTestState) -> String {
        switch (state.statusCode, state.latencyMs) {
        case let (code?, ms?): return "\(code) · \(ms)ms"
        case let (code?, nil): return "\(code)"
        case let (nil, ms?): return "\(ms)ms"
        case (nil, nil): return L("OK", "正常")
        }
    }

    private func connectivityFailureText(_ state: ProxyConnectivityTestState) -> String {
        if let code = state.statusCode { return "\(code)" }
        return L("Failed", "失败")
    }

    private func connectivityDetailPopover(_ state: ProxyConnectivityTestState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(L("Connectivity Test Failed", "连通性测试失败"))
                    .font(.system(size: 13, weight: .bold))
                Spacer(minLength: 8)
                if let code = state.statusCode {
                    Text("HTTP \(code)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            ScrollView {
                Text((state.message?.isEmpty == false ? state.message : nil) ?? L("Unknown error", "未知错误"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)

            HStack(spacing: 8) {
                if let testedAt = state.testedAt {
                    Text(Self.relativeFormatter.localizedString(for: testedAt, relativeTo: Date()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(state.message ?? "", forType: .string)
                } label: {
                    Label(L("Copy", "复制"), systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                Button {
                    showConnectivityDetail = false
                    onTestConnectivity()
                } label: {
                    Label(L("Retry", "重试"), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(isBusy)
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var cardContextMenu: some View {
        Button { onToggleActivation() } label: {
            Label(
                isActive ? disconnectLabel : applyLabel,
                systemImage: isActive ? "stop.circle" : "power.circle"
            )
        }
        .disabled(isBusy || isActivationManaged)

        if config.needsProxyProcess {
            Button { onToggleProxyOnly() } label: {
                Label(
                    isActive
                        ? connectedUnavailableLabel
                        : isProxyOnlyRunning ? L("Turn Off Node", "关闭节点") : L("Turn On Node", "开启节点"),
                    systemImage: isProxyOnlyRunning ? "power.circle.fill" : "power.circle"
                )
            }
            .disabled(isBusy || isActive || runtimeStopIsProductOwned)
        }

        Button { onCopyLaunchCommand() } label: {
            Label(launchCommandLabel, systemImage: "doc.on.clipboard")
        }

        Button { onTestConnectivity() } label: {
            Label(L("Test Connectivity", "测试连通性"), systemImage: "bolt.horizontal.circle")
        }
        .disabled(isBusy || connectivityState?.isTesting == true)

        if libraryModels.count > 1 {
            Menu {
                ForEach(modelSwitchOptions, id: \.self) { model in
                    Button {
                        onSelectDefaultModel(model)
                    } label: {
                        if model == currentDefaultModel {
                            Label(model, systemImage: "checkmark")
                        } else {
                            Text(model)
                        }
                    }
                }
            } label: {
                Label(L("Default Model", "默认模型"), systemImage: "cpu")
            }
            .disabled(isBusy)
        }

        Divider()

        Button { onEdit() } label: {
            Label(L("Edit", "编辑"), systemImage: "pencil")
        }
        Button { onDuplicate() } label: {
            Label(L("Duplicate", "复制节点"), systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) { onDelete() } label: {
            Label(L("Delete", "删除"), systemImage: "trash")
        }
        .disabled(isBusy || deletionBlockReason != nil)
    }

    // MARK: - Subviews

    private var nodeTypeBadge: some View {
        let (icon, color): (String, Color) = {
            switch config.nodeType {
            case .anthropicDirect:
                return ("bolt.shield.fill", Self.anthropicBrand)
            case .openaiProxy:
                return ("arrow.triangle.swap", Self.openAIBrand)
            case .codexProxy:
                return ("terminal.fill", Self.codexBrand)
            }
        }()

        return HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 7, weight: .bold))
            Text(config.nodeType.badgeProtocolName)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private var consumerBadges: some View {
        HStack(spacing: 4) {
            if let route = claudeUsage.codeRoute {
                consumerBadge(
                    title: "Code",
                    icon: route == .gateway ? "point.3.connected.trianglepath.dotted" : "terminal",
                    color: .indigo,
                    isRunning: claudeUsage.codeRunning,
                    help: route == .gateway
                        ? L("Claude Code uses this node through Code Gateway", "Claude Code 正通过 Code 网关使用此节点")
                        : L("Claude Code is connected directly to this node", "Claude Code 正直连接入此节点")
                )
            }
            if claudeUsage.desktop {
                consumerBadge(
                    title: "Desktop",
                    icon: "macwindow",
                    color: Self.anthropicBrand,
                    isRunning: claudeUsage.desktopRunning,
                    help: L("Claude Desktop uses this node through Desktop Gateway", "Claude Desktop 正通过 Desktop 网关使用此节点")
                )
            }
            if claudeUsage.science {
                consumerBadge(
                    title: "Science",
                    icon: "atom",
                    color: .purple,
                    isRunning: claudeUsage.scienceRunning,
                    help: L("Claude Science uses this node on its independent runtime", "Claude Science 正通过独立运行时使用此节点")
                )
            }
        }
    }

    private func consumerBadge(
        title: String,
        icon: String,
        color: Color,
        isRunning: Bool,
        help: String
    ) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 7, weight: .bold))
            Text(title)
            if !isRunning {
                Image(systemName: "clock")
                    .font(.system(size: 6, weight: .bold))
            }
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(isRunning ? color : Color.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill((isRunning ? color : Color.orange).opacity(0.10)))
        .overlay(Capsule().stroke((isRunning ? color : Color.orange).opacity(0.18), lineWidth: 0.5))
        .help(isRunning ? help : L("Configured, but its runtime is not ready", "已配置，但运行时尚未就绪"))
    }

    private func statPill(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch config.nodeType {
            case .anthropicDirect:
                detailItem(label: "Base URL", value: config.anthropicBaseURL)
                detailItem(label: L("Local Endpoint", "本地地址"), value: "http://\(config.host):\(config.port)")
                detailItem(label: L("LAN Access", "局域网访问"), value: config.allowLAN ? L("Enabled", "已启用") : L("Disabled", "已禁用"))
            case .openaiProxy:
                detailItem(label: L("Upstream", "上游"), value: config.normalizedUpstreamBaseURL)
                detailItem(label: L("Upstream API", "上游接口"), value: config.openAIUpstreamAPI == .chatCompletions ? "Chat Completions" : "Responses")
                detailItem(
                    label: L("Model Mapping", "模型映射"),
                    value: "Opus\u{2192}\(config.modelMapping.bigModel.name), Sonnet\u{2192}\(config.modelMapping.middleModel.name), Haiku\u{2192}\(config.modelMapping.smallModel.name)"
                )
                detailItem(label: L("Local Proxy", "本地代理"), value: "http://\(config.host):\(config.port)")
                detailItem(label: L("LAN Access", "局域网访问"), value: config.allowLAN ? L("Enabled", "已启用") : L("Disabled", "已禁用"))
            case .codexProxy:
                detailItem(label: L("Upstream", "上游"), value: config.normalizedUpstreamBaseURL)
                detailItem(label: L("Upstream API", "上游接口"), value: "Responses")
                if libraryModels.count <= 1 {
                    detailItem(label: L("Model", "模型"), value: config.codexModel.isEmpty ? "—" : config.codexModel)
                }
                detailItem(label: L("Codex Endpoint", "Codex 接入"), value: "http://\(config.host):\(config.port)/v1")
                detailItem(label: L("LAN Access", "局域网访问"), value: config.allowLAN ? L("Enabled", "已启用") : L("Disabled", "已禁用"))
            }
            defaultModelRow
            if let lastUsed = lastRequestAt ?? config.lastUsedAt {
                detailItem(label: L("Last Used", "最后使用"), value: Self.relativeFormatter.localizedString(for: lastUsed, relativeTo: Date()))
            }
        }
        .font(.caption)
    }

    /// 默认模型行：模型目录多于一个模型时内联单选切换（保存即生效，激活中节点自动滚动重载）。
    @ViewBuilder
    private var defaultModelRow: some View {
        if libraryModels.count > 1 {
            HStack(spacing: 8) {
                Text(L("Default Model", "默认模型"))
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { currentDefaultModel },
                    set: { onSelectDefaultModel($0) }
                )) {
                    ForEach(modelSwitchOptions, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .disabled(isBusy)
                Text(L("(\(libraryModels.count) models)", "（共 \(libraryModels.count) 个）"))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func detailItem(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
}

// MARK: - Proxy Activation Toggle Style

// 复用：Codex 账号列表的激活开关也用此样式，保持与节点列表一致。
struct ProxyActivationToggleStyle: ToggleStyle {
    let brandColor: Color
    let isBusy: Bool

    private let trackWidth: CGFloat = 40
    private let trackHeight: CGFloat = 22
    private let thumbDiameter: CGFloat = 16
    private let thumbPadding: CGFloat = 3

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn

        Button {
            guard !isBusy else { return }
            configuration.isOn.toggle()
        } label: {
            ZStack {
                Capsule()
                    .fill(isOn ? brandColor : Color.gray.opacity(0.35))
                    .frame(width: trackWidth, height: trackHeight)

                Capsule()
                    .strokeBorder(isOn ? brandColor.opacity(0.6) : Color.gray.opacity(0.2), lineWidth: 0.5)
                    .frame(width: trackWidth, height: trackHeight)

                HStack {
                    if isOn { Spacer() }

                    Group {
                        if isBusy {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(width: thumbDiameter, height: thumbDiameter)
                        } else {
                            Circle()
                                .fill(.white)
                                .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                                .frame(width: thumbDiameter, height: thumbDiameter)
                        }
                    }

                    if !isOn { Spacer() }
                }
                .padding(.horizontal, thumbPadding)
                .frame(width: trackWidth)
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isOn)
    }
}

// MARK: - Instant Tooltip Modifier

private struct InstantTooltip: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content
            .help(text)
    }
}

extension View {
    fileprivate func instantTooltip(_ text: String) -> some View {
        modifier(InstantTooltip(text: text))
    }
}
