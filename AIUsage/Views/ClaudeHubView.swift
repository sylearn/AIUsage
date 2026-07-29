import SwiftUI

enum ClaudeHubTab: String, CaseIterable, Identifiable {
    case node
    case code
    case desktop
    case science

    var id: String { rawValue }

    var title: String {
        switch self {
        case .node: return "Node"
        case .code: return "Code"
        case .desktop: return "Desktop"
        case .science: return "Science"
        }
    }

    var symbol: String {
        switch self {
        case .node: return "point.3.connected.trianglepath.dotted"
        case .code: return "terminal"
        case .desktop: return "macwindow"
        case .science: return "atom"
        }
    }

    var tint: Color {
        switch self {
        case .node: return .teal
        case .code: return .indigo
        case .desktop: return ClaudeDesktopIntegrationView.brand
        case .science: return ScienceProxyManagementView.brand
        }
    }
}

/// One Claude ecosystem entry with four explicit ownership boundaries: Node
/// runtimes plus independent Code, Desktop and Science product gateways.
struct ClaudeHubView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(DefaultsKey.claudeHubSelectedTab) private var selectedTabRawValue = ClaudeHubTab.desktop.rawValue
    private let initialTab: ClaudeHubTab?

    init(initialTab: ClaudeHubTab? = nil) {
        self.initialTab = initialTab
    }

    private var selectedTab: ClaudeHubTab {
        ClaudeHubTab(rawValue: selectedTabRawValue) ?? .desktop
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                switch selectedTab {
                case .node:
                    ProxyManagementView(showsClaudeProductConfiguration: false)
                case .code:
                    ClaudeCodeRoutingView()
                case .desktop:
                    ClaudeDesktopIntegrationView()
                case .science:
                    ScienceProxyManagementView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // The normal sidebar entry restores the last product. Legacy routes may
            // still request a specific product and become the new remembered value.
            let restoredTab = initialTab ?? ClaudeHubTab(rawValue: selectedTabRawValue) ?? .desktop
            if selectedTabRawValue != restoredTab.rawValue {
                selectedTabRawValue = restoredTab.rawValue
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(ClaudeHubTab.allCases) { tab in
                productButton(tab)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func productButton(_ tab: ClaudeHubTab) -> some View {
        let selected = selectedTab == tab
        return Button {
            if reduceMotion {
                selectedTabRawValue = tab.rawValue
            } else {
                withAnimation(.easeOut(duration: 0.18)) { selectedTabRawValue = tab.rawValue }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? tab.tint : Color.secondary)
                    .frame(width: 20, height: 22)
                Text(tab.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? tab.tint.opacity(0.10) : Color.primary.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? tab.tint.opacity(0.38) : Color.primary.opacity(0.055), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Claude \(tab.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Code owns only application configuration and its fixed product gateway.
/// Node creation, runtime state and upstream credentials live in the Node tab.
private struct ClaudeCodeRoutingView: View {
    @ObservedObject private var gateway = GlobalProxyManager.claude
    @ObservedObject private var proxyVM = ProxyViewModel.shared
    @State private var showSettingsEditor = false
    @State private var showSettingsHelp = false
    @State private var showModelHelp = false
    @State private var selectedNodeID = ""
    @State private var effortLevel: ClaudeCodePersistentEffort = .auto
    @State private var effortError: String?

    private var nodes: [GlobalProxyNodeRef] { gateway.availableNodes() }

    private var resolvedNodeID: String? {
        if gateway.isRuntimeEnabled,
           let active = gateway.activeNodeId,
           nodes.contains(where: { $0.id == active }) { return active }
        if nodes.contains(where: { $0.id == selectedNodeID }) { return selectedNodeID }
        if let active = gateway.activeNodeId,
           nodes.contains(where: { $0.id == active }) { return active }
        return nodes.first?.id
    }

    private var selectedNode: ProxyConfiguration? {
        guard let resolvedNodeID else { return nil }
        return proxyVM.configurations.first(where: { $0.id == resolvedNodeID })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ClaudeGlobalProxySection(selectedNodeId: $selectedNodeID)
                codeModelsCard
                applicationConfigCard
            }
            .frame(maxWidth: 960)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if selectedNodeID.isEmpty { selectedNodeID = resolvedNodeID ?? "" }
            reloadEffortLevel()
        }
        .onChange(of: gateway.activeNodeId) { _, newValue in
            guard let newValue else { return }
            selectedNodeID = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadEffortLevel()
        }
        .sheet(isPresented: $showSettingsEditor) {
            LocalSettingsEditorView()
        }
    }

    private var applicationConfigCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.gearshape")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(0.10)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Claude Code configuration", "Claude Code 配置"))
                        .font(.headline)
                    Text("~/.claude/settings.json")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showSettingsHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showSettingsHelp, arrowEdge: .top) {
                    Text(L(
                        "AIUsage manages the Gateway endpoint, model routes and the startup effort default. A running Claude Code session keeps its current effort until you change it inside Claude Code.",
                        "AIUsage 管理 Gateway 地址、模型映射和启动默认强度。正在运行的 Claude Code 会话会保持当前强度，除非你在 Claude Code 内修改。"
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(width: 340)
                }
                Button(L("Edit…", "编辑…")) { showSettingsEditor = true }
                    .buttonStyle(.bordered)
            }

            Divider()
            effortControl
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06)))
    }

    private var effortControl: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.indigo.opacity(0.10)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Default effort", "默认思考强度"))
                        .font(.caption.weight(.semibold))
                    Text(L(
                        "Takes effect the next time Claude Code starts · does not change the current session",
                        "下次启动 Claude Code 时生效 · 不会改变当前会话"
                    ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Picker("", selection: Binding(
                    get: { effortLevel },
                    set: { saveEffortLevel($0) }
                )) {
                    ForEach(ClaudeCodePersistentEffort.allCases) { level in
                        Text(effortTitle(level)).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 440)
            }

            if let effortError {
                Label(effortError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private func effortTitle(_ level: ClaudeCodePersistentEffort) -> String {
        switch level {
        case .auto: return L("Auto", "自动")
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "XHigh"
        }
    }

    private func reloadEffortLevel() {
        do {
            effortLevel = try ClaudeSettingsManager.shared.readPersistentEffort()
            effortError = nil
        } catch {
            effortError = error.localizedDescription
        }
    }

    private func saveEffortLevel(_ level: ClaudeCodePersistentEffort) {
        do {
            try ClaudeSettingsManager.shared.writePersistentEffort(level)
            effortLevel = level
            effortError = nil
        } catch {
            let failure = error.localizedDescription
            effortLevel = (try? ClaudeSettingsManager.shared.readPersistentEffort()) ?? .auto
            effortError = failure
        }
    }

    private var codeModelsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.indigo.opacity(0.11)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Code models", "Code 模型"))
                        .font(.headline)
                    Text(L(
                        gateway.config.effectiveClaudeCodeCatalogMode == .smartRoutes
                            ? "Four stable routes · live mapping"
                            : "Four Code aliases · real model names",
                        gateway.config.effectiveClaudeCodeCatalogMode == .smartRoutes
                            ? "四条固定路由 · 映射即时生效"
                            : "四个 Code 别名 · 使用真实模型名"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let selectedNode {
                    Text(L(
                        "\(selectedNode.runtimeModelCatalog.count) models",
                        "\(selectedNode.runtimeModelCatalog.count) 个模型"
                    ))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.indigo)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.indigo.opacity(0.10)))
                }
                Button { showModelHelp.toggle() } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showModelHelp, arrowEdge: .top) {
                    codeModelHelpPopover
                }
            }

            if let node = selectedNode {
                let nodeDefaults = ClaudeAppResolvedModels(
                    defaultModel: node.defaultModel,
                    opus: node.modelMapping.bigModel.name,
                    sonnet: node.modelMapping.middleModel.name,
                    haiku: node.modelMapping.smallModel.name
                )
                let resolved = gateway.config.effectiveClaudeCodeModels(for: node)
                ClaudeModelRouteBoard(
                    productName: "Code",
                    brand: .indigo,
                    showsStableRouteNames: gateway.config.effectiveClaudeCodeCatalogMode == .smartRoutes,
                    catalog: node.runtimeModelCatalog,
                    nodeDefaults: nodeDefaults,
                    resolved: resolved,
                    overrides: gateway.config.claudeCodeModelOverride(for: node.id),
                    isDisabled: gateway.isBusy,
                    onSelect: { route, model in
                        Task {
                            await gateway.updateClaudeCodeModelOverride(
                                nodeID: node.id,
                                route: route,
                                model: model
                            )
                        }
                    },
                    onReset: {
                        Task { await gateway.resetClaudeCodeModelOverrides(nodeID: node.id) }
                    }
                )
            } else {
                Text(L(
                    "Choose a node with at least one available model.",
                    "请选择至少包含一个可用模型的节点。"
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private var codeModelHelpPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Code model ownership", "Code 模型归属"))
                .font(.headline)
            Label(
                L(
                    "Node defaults are shared and are never changed here.",
                    "节点默认配置仍由 Node 管理，此处不会修改。"
                ),
                systemImage: "server.rack"
            )
            Label(
                L(
                    "A Code override is stored only for this node and takes effect in the Code Gateway immediately.",
                    "Code 覆盖只属于当前节点的 Code 路由，并立即应用到 Code 网关。"
                ),
                systemImage: "terminal"
            )
            Label(
                L(
                    "Reset removes every override and follows the node defaults again.",
                    "恢复默认会删除覆盖，重新跟随节点配置。"
                ),
                systemImage: "arrow.counterclockwise"
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }
}

struct ClaudeDesktopIntegrationView: View {
    static let brand = Color(red: 0.78, green: 0.35, blue: 0.24)

    @ObservedObject private var manager = ClaudeDesktopIntegrationManager.shared
    @ObservedObject private var gateway = GlobalProxyManager.desktop
    @ObservedObject private var proxyVM = ProxyViewModel.shared
    @State private var selectedNodeID = ""
    @State private var showConnectionHelp = false
    @State private var showModelModeHelp = false
    @State private var showModelManager = false
    @State private var desktopPortDraft = ""
    @State private var portSaveMessage: String?
    @State private var portSaveError: String?
    @State private var pendingCatalogMode: ClaudeDesktopCatalogMode?
    @FocusState private var isPortFieldFocused: Bool

    private var nodes: [GlobalProxyNodeRef] { gateway.availableNodes() }

    private var resolvedNodeID: String? {
        if nodes.contains(where: { $0.id == selectedNodeID }) { return selectedNodeID }
        if let active = gateway.activeNodeId, nodes.contains(where: { $0.id == active }) { return active }
        return nodes.first?.id
    }

    private var selectedNode: ProxyConfiguration? {
        guard let id = resolvedNodeID else { return nil }
        return proxyVM.configurations.first(where: { $0.id == id })
    }

    private var catalogMode: ClaudeDesktopCatalogMode {
        gateway.config.effectiveClaudeDesktopCatalogMode
    }

    private var previewModels: [ClaudeDesktopCatalogEntry] {
        if manager.isConfigured, !manager.configuredModels.isEmpty { return manager.configuredModels }
        guard let selectedNode else { return [] }
        return ClaudeDesktopProfileStore.catalog(
            for: selectedNode,
            mode: catalogMode,
            supports1M: gateway.config.claudeDesktopSupports1MModels(for: selectedNode.id),
            routes: gateway.config.effectiveClaudeDesktopModels(for: selectedNode)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                desktopGatewayCard
                modelCard
            }
            .frame(maxWidth: 960)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            manager.refreshInstallation()
            if selectedNodeID.isEmpty { selectedNodeID = resolvedNodeID ?? "" }
            if desktopPortDraft.isEmpty { syncDesktopPortDraft() }
        }
        .onChange(of: gateway.activeNodeId) { _, newValue in
            guard let newValue else { return }
            selectedNodeID = newValue
        }
        .onChange(of: gateway.config.effectiveClaudeDesktopHTTPSPort) { _, _ in
            if !isPortFieldFocused { syncDesktopPortDraft() }
        }
        .confirmationDialog(
            L("Change the Desktop model mode?", "切换 Desktop 模型模式？"),
            isPresented: Binding(
                get: { pendingCatalogMode != nil },
                set: { if !$0 { pendingCatalogMode = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(catalogModeConfirmationTitle) {
                guard let mode = pendingCatalogMode else { return }
                pendingCatalogMode = nil
                Task { await gateway.updateClaudeDesktopCatalogMode(mode) }
            }
            Button(L("Cancel", "取消"), role: .cancel) {
                pendingCatalogMode = nil
            }
        } message: {
            Text(catalogModeConfirmationMessage)
        }
        .sheet(isPresented: $showModelManager) {
            if let selectedNode {
                ClaudeDesktopModelManagerSheet(node: selectedNode)
            }
        }
    }

    private var desktopGatewayCard: some View {
        ClaudeProductGatewayCard(
            brand: Self.brand,
            systemImage: "macwindow",
            title: L("Desktop Gateway", "Desktop 网关"),
            subtitle: "Claude Desktop · v\(manager.versionLabel)",
            statusText: statusTitle,
            statusColor: statusColor,
            isEnabled: manager.isConfigured,
            isBusy: manager.isBusy,
            hasNodes: !nodes.isEmpty,
            emptyHint: L("Create a Claude node first.", "请先创建 Claude 节点。"),
            endpoint: "127.0.0.1:\(gateway.config.effectiveClaudeDesktopHTTPSPort)",
            mode: catalogMode,
            effectText: catalogMode == .smartRoutes
                ? L("Live", "即时生效")
                : L("Auto reload", "自动重载"),
            effectSymbol: catalogMode == .smartRoutes ? "bolt.fill" : "arrow.clockwise",
            effectColor: catalogMode == .smartRoutes ? .green : .orange,
            isToggleDisabled: (!manager.isConfigured && (resolvedNodeID == nil || !manager.installation.isInstalled)),
            toggle: desktopGatewayToggle,
            onModeSelect: requestCatalogMode,
            nodeControl: { desktopNodeControl },
            config: { desktopGatewayConfig },
            extraAction: { desktopOpenButton },
            message: { stateMessage }
        )
    }

    private var desktopNodeControl: some View {
        GlobalProxyChipMenu(
            brand: Self.brand,
            title: nodes.first(where: { $0.id == resolvedNodeID })?.name ?? L("Choose node", "选择节点"),
            systemImage: "bolt.fill",
            isDisabled: manager.isBusy || nodes.isEmpty,
            items: nodes.map { GlobalProxyPickerItem(id: $0.id, name: $0.name) },
            selectedId: resolvedNodeID ?? "",
            onSelect: selectNode
        )
    }

    private var desktopGatewayToggle: Binding<Bool> {
        Binding(
            get: { manager.isConfigured },
            set: { enabled in
                if enabled {
                    guard let nodeID = resolvedNodeID else { return }
                    Task { await manager.connect(activeNodeId: nodeID) }
                } else {
                    Task { await manager.disconnect() }
                }
            }
        )
    }

    @ViewBuilder
    private var desktopOpenButton: some View {
        if manager.installation.isInstalled {
            Button {
                Task { await manager.openClaudeDesktop() }
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Self.brand)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Self.brand.opacity(0.09)))
                    .overlay(Circle().stroke(Self.brand.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .disabled(manager.isBusy)
            .help(L("Open Claude Desktop", "打开 Claude Desktop"))
        }
    }

    private var desktopGatewayConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(L("Local gateway", "本机网关"), systemImage: "lock.shield")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showConnectionHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showConnectionHelp, arrowEdge: .top) {
                    connectionHelpPopover
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                GlobalProxyField(label: L("Local HTTPS port", "本机 HTTPS 端口")) {
                    TextField("14403", text: $desktopPortDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                        .frame(width: 118)
                        .focused($isPortFieldFocused)
                        .onChange(of: desktopPortDraft) { _, newValue in
                            let filtered = String(newValue.filter(\.isNumber).prefix(5))
                            if filtered != newValue { desktopPortDraft = filtered }
                            portSaveMessage = nil
                            portSaveError = nil
                        }
                }

                Button(L("Restore default", "恢复默认")) {
                    desktopPortDraft = String(GlobalProxyConfig.defaultClaudeDesktopHTTPSPort)
                }
                .buttonStyle(.bordered)
                .disabled(manager.isBusy)

                Button(L("Save", "保存")) {
                    saveDesktopPort()
                }
                .buttonStyle(.borderedProminent)
                .tint(Self.brand)
                .disabled(!canSaveDesktopPort)
                Spacer(minLength: 0)
            }

            if let portValidationMessage {
                inlinePortMessage(symbol: "exclamationmark.triangle.fill", text: portValidationMessage, color: .orange)
            } else if let portSaveError {
                inlinePortMessage(symbol: "xmark.circle.fill", text: portSaveError, color: .red)
            } else if let portSaveMessage {
                inlinePortMessage(symbol: "checkmark.circle.fill", text: portSaveMessage, color: .green)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10).fill(Self.brand.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Self.brand.opacity(0.10)))
    }

    @ViewBuilder
    private var stateMessage: some View {
        switch manager.state {
        case .unavailable:
            messageRow(
                symbol: "exclamationmark.triangle.fill",
                text: L("Claude Desktop was not found in Applications.", "未在「应用程序」中找到 Claude Desktop。"),
                color: .orange
            )
        case .disconnected, .ready, .connected:
            EmptyView()
        case .preparing(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        case .conflict(let text):
            messageRow(symbol: "hand.raised.fill", text: text, color: .orange)
        case .failed(let text):
            messageRow(symbol: "xmark.octagon.fill", text: text, color: .red)
        }
    }

    private func messageRow(symbol: String, text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(L("Desktop models", "Desktop 模型"))
                    .font(.headline)
                Spacer(minLength: 8)
                if let selectedNode {
                    Label(
                        catalogMode == .smartRoutes
                            ? L("4 routes", "4 条路由")
                            : L(
                                "\(selectedNode.runtimeModelCatalog.count) models",
                                "\(selectedNode.runtimeModelCatalog.count) 个模型"
                            ),
                        systemImage: "square.stack.3d.up"
                    )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(L("Visible Desktop model surface", "Desktop 可见模型"))
                    let contextCount = previewModels.filter(\.supports1M).count
                    if contextCount > 0 {
                        Text("\(contextCount) × 1M")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                modelManagerCompactButton
                Button {
                    showModelModeHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("Model modes", "模型模式说明"))
                .popover(isPresented: $showModelModeHelp, arrowEdge: .top) {
                    modelModeHelpPopover
                }
            }

            if catalogMode == .smartRoutes, let node = selectedNode {
                let nodeDefaults = ClaudeAppResolvedModels(
                    defaultModel: node.defaultModel,
                    opus: node.modelMapping.bigModel.name,
                    sonnet: node.modelMapping.middleModel.name,
                    haiku: node.modelMapping.smallModel.name
                )
                ClaudeModelRouteBoard(
                    productName: "Desktop",
                    brand: Self.brand,
                    catalog: node.runtimeModelCatalog,
                    nodeDefaults: nodeDefaults,
                    resolved: gateway.config.effectiveClaudeDesktopModels(for: node),
                    overrides: gateway.config.claudeDesktopModelOverride(for: node.id),
                    isDisabled: gateway.isBusy || manager.isBusy,
                    onSelect: { route, model in
                        Task {
                            await gateway.updateClaudeDesktopModelOverride(
                                nodeID: node.id,
                                route: route,
                                model: model
                            )
                        }
                    },
                    onReset: {
                        Task { await gateway.resetClaudeDesktopModelOverrides(nodeID: node.id) }
                    }
                )
            } else if catalogMode == .fullNodeCatalog, !previewModels.isEmpty {
                ClaudeSearchableModelDirectory(
                    items: previewModels.map { model in
                        ClaudeModelCatalogItem(
                            id: model.id,
                            title: model.displayName,
                            subtitle: model.displayName == model.upstreamModel ? nil : model.upstreamModel,
                            badge: model.supports1M ? "1M" : nil,
                            help: model.displayName == model.upstreamModel
                                ? model.displayName
                                : "\(model.displayName) → \(model.upstreamModel)",
                            isDefault: model.upstreamModel == selectedNode?.defaultModel
                        )
                    },
                    brand: Self.brand,
                    title: L("Node model catalog", "节点模型目录")
                )
                .id(selectedNode?.id)
            } else if previewModels.isEmpty {
                Text(L("Choose a node with at least one available model.", "请选择至少包含一个可用模型的节点。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }

            ClaudeEffortOwnershipRow(
                productName: "Desktop",
                brand: Self.brand,
                detail: L(
                    "Choose effort and Thinking in Desktop's model menu",
                    "请在 Desktop 的模型菜单中选择 Effort 与 Thinking"
                )
            )
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private var modelManagerCompactButton: some View {
        Button {
            showModelManager = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(L("Model settings", "模型设置"))
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(Self.brand)
            .padding(.horizontal, 9)
            .frame(height: 29)
            .background(Capsule().fill(Self.brand.opacity(0.085)))
            .overlay(Capsule().stroke(Self.brand.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(selectedNode == nil)
        .opacity(selectedNode == nil ? 0.5 : 1)
        .help(L("Configure model capabilities", "配置模型能力"))
    }

    private func requestCatalogMode(_ mode: ClaudeDesktopCatalogMode) {
        guard mode != catalogMode else { return }
        if manager.isConfigured {
            pendingCatalogMode = mode
        } else {
            Task { await gateway.updateClaudeDesktopCatalogMode(mode) }
        }
    }

    private var modelModeHelpPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Desktop model modes", "Desktop 模型模式"))
                .font(.headline)
            helpItem(
                symbol: "arrow.triangle.2.circlepath",
                title: L("Hot switch", "热切换"),
                detail: L(
                    "Desktop keeps four stable routes. Each can follow the node or use a Desktop-only override; node switches stay live.",
                    "Desktop 保留四条固定路由；每条都可跟随节点或使用 Desktop 独立覆盖，切换节点仍无需重启。"
                )
            )
            helpItem(
                symbol: "square.stack.3d.up",
                title: L("Node models", "节点模型"),
                detail: L(
                    "Desktop shows only the selected node's complete real model catalog. Switching the node automatically reloads Desktop.",
                    "Desktop 仅显示当前节点的完整真实模型目录；切换节点后会自动重新加载 Desktop。"
                )
            )
        }
        .padding(16)
        .frame(width: 350, alignment: .leading)
    }

    private var catalogModeConfirmationTitle: String {
        pendingCatalogMode == .smartRoutes
            ? L("Use hot switch", "使用热切换")
            : L("Show node models", "显示节点模型")
    }

    private var catalogModeConfirmationMessage: String {
        pendingCatalogMode == .smartRoutes
            ? L(
                "Desktop reloads once. Later node switches stay live.",
                "Desktop 将重载一次；之后切换节点无需重启。"
            )
            : L(
                "Desktop reloads now and whenever its visible model list changes.",
                "Desktop 现在会重载；以后可见模型列表变化时也会自动重载。"
            )
    }

    private var connectionHelpPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("About Desktop access", "关于 Desktop 接入"))
                .font(.headline)

            helpItem(
                symbol: "poweron",
                title: L("After restarting AIUsage", "AIUsage 重启后"),
                detail: L(
                    "An attached Desktop profile automatically restores its localhost HTTPS port. Attached means the profile and port are ready; Connected means a real Desktop request was observed during this launch.",
                    "已接入的 Desktop 会自动恢复本机 HTTPS 端口。“已接入”表示配置与端口就绪；“已连接”表示本次启动后已收到 Desktop 的真实请求。"
                )
            )

            helpItem(
                symbol: "shield.lefthalf.filled",
                title: L("Security boundary", "安全边界"),
                detail: L(
                    "The endpoint listens on localhost only, uses a dedicated Desktop key, and never exposes your upstream API key.",
                    "入口仅监听本机，使用 Desktop 独立密钥，不会向 Desktop 暴露上游 API Key。"
                )
            )

            helpItem(
                symbol: "arrow.uturn.backward",
                title: L("When you disconnect", "断开时会做什么"),
                detail: L(
                    "AIUsage restores the previous profile, closes only the Desktop gateway, and quits Desktop without reopening it. Code and Science are independent.",
                    "AIUsage 会恢复接入前配置，仅关闭 Desktop 网关，并退出 Desktop 且不再重开；Code 与 Science 不受影响。"
                )
            )

            Text(manager.endpointLabel)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(width: 350, alignment: .leading)
    }

    private func helpItem(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Self.brand)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func inlinePortMessage(symbol: String, text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var parsedDesktopPort: Int? { Int(desktopPortDraft) }

    private var portValidationMessage: String? {
        guard let port = parsedDesktopPort else {
            return L("Enter a port from 1024 to 65535.", "请输入 1024 到 65535 之间的端口。")
        }
        guard (1_024...65_535).contains(port) else {
            return L("Port must be between 1024 and 65535.", "端口必须在 1024 到 65535 之间。")
        }
        guard port != gateway.config.port else {
            return L("Desktop HTTPS cannot share its internal gateway port.", "Desktop HTTPS 不能与内部网关端口相同。")
        }
        if let conflict = ProxyPortArbiter.conflict(
            forPorts: [port],
            excluding: "claude-desktop-port-settings"
        ) {
            let owner = conflict.label.isEmpty ? conflict.track : "\(conflict.track) · \(conflict.label)"
            return L(
                "Port \(port) is already used by \(owner).",
                "端口 \(port) 已被 \(owner) 使用。"
            )
        }
        return nil
    }

    private var canSaveDesktopPort: Bool {
        !manager.isConfigured
            && !manager.isBusy
            && portValidationMessage == nil
            && parsedDesktopPort != gateway.config.effectiveClaudeDesktopHTTPSPort
    }

    private func syncDesktopPortDraft() {
        desktopPortDraft = String(gateway.config.effectiveClaudeDesktopHTTPSPort)
        portSaveMessage = nil
        portSaveError = nil
    }

    private func saveDesktopPort() {
        guard let port = parsedDesktopPort, portValidationMessage == nil else { return }
        if gateway.updateClaudeDesktopHTTPSPort(port) {
            desktopPortDraft = String(port)
            portSaveError = nil
            portSaveMessage = L("Port saved. Desktop will use it on the next connection.", "端口已保存，下次接入 Desktop 时生效。")
        } else {
            portSaveMessage = nil
            portSaveError = gateway.operationError
                ?? L("Disconnect Desktop before changing this port.", "请先断开 Desktop，再修改端口。")
        }
    }

    private func selectNode(_ nodeID: String) {
        selectedNodeID = nodeID
        if manager.isConfigured {
            Task { await gateway.switchActiveNode(to: nodeID) }
        }
    }

    private var statusTitle: String {
        switch manager.state {
        case .unavailable: return L("Not installed", "未安装")
        case .disconnected: return L("Not connected", "未接入")
        case .preparing: return L("Preparing", "准备中")
        case .ready: return L("Attached", "已接入")
        case .connected: return L("Connected", "已连接")
        case .conflict: return L("Protected", "已保护")
        case .failed: return L("Needs attention", "需要处理")
        }
    }

    private var statusSymbol: String {
        switch manager.state {
        case .connected: return "checkmark.circle.fill"
        case .ready: return "checkmark.circle.fill"
        case .preparing: return "arrow.triangle.2.circlepath"
        case .conflict: return "hand.raised.fill"
        case .failed: return "exclamationmark.octagon.fill"
        case .unavailable: return "app.dashed"
        case .disconnected: return "circle"
        }
    }

    private var statusColor: Color {
        switch manager.state {
        case .connected: return .green
        case .ready: return Self.brand
        case .preparing: return .orange
        case .conflict: return .orange
        case .failed: return .red
        case .unavailable, .disconnected: return .secondary
        }
    }
}

private struct ClaudeDesktopModelManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var gateway = GlobalProxyManager.desktop
    let node: ProxyConfiguration

    @State private var searchText = ""
    @State private var enabled1M: Set<String> = []
    @State private var showHelp = false

    private var catalog: [ClaudeDesktopCatalogEntry] {
        ClaudeDesktopProfileStore.realCatalog(
            for: node,
            supports1M: enabled1M
        )
    }

    private var filteredCatalog: [ClaudeDesktopCatalogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return catalog }
        return catalog.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
                || $0.upstreamModel.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            searchBar
            modelList
            Divider()
            footer
        }
        .frame(width: 720, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            enabled1M = gateway.config.claudeDesktopSupports1MModels(for: node.id)
        }
    }

    private var sheetHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "macwindow.and.cursorarrow")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(ClaudeDesktopIntegrationView.brand)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(ClaudeDesktopIntegrationView.brand.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Desktop model catalog", "Desktop 模型目录"))
                    .font(.title3.weight(.bold))
                Text(node.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("Model settings help", "模型设置说明"))
            .popover(isPresented: $showHelp, arrowEdge: .top) {
                modelHelpPopover
            }
            Button(L("Done", "完成")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private var searchBar: some View {
        TextField(L("Search models", "搜索模型"), text: $searchText)
            .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var modelList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredCatalog) { model in
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ClaudeDesktopIntegrationView.brand)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(ClaudeDesktopIntegrationView.brand.opacity(0.10)))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.displayName)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            if model.displayName != model.upstreamModel {
                                Text(L("Current target · \(model.upstreamModel)", "当前目标 · \(model.upstreamModel)"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                            }
                            Text("Model ID · \(model.id)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 12)
                        Toggle("1M", isOn: Binding(
                            get: { enabled1M.contains(model.upstreamModel) },
                            set: { enabled in
                                if enabled {
                                    enabled1M.insert(model.upstreamModel)
                                } else {
                                    enabled1M.remove(model.upstreamModel)
                                }
                                Task {
                                    let saved = await gateway.updateClaudeDesktopSupports1M(
                                        nodeID: node.id,
                                        modelID: model.upstreamModel,
                                        enabled: enabled
                                    )
                                    if !saved {
                                        if enabled {
                                            enabled1M.remove(model.upstreamModel)
                                        } else {
                                            enabled1M.insert(model.upstreamModel)
                                        }
                                    }
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(gateway.isBusy)
                        .accessibilityLabel(L(
                            "Offer 1M-context variant for \(model.displayName)",
                            "为 \(model.displayName) 提供 1M 上下文版本"
                        ))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Color.primary.opacity(0.055), lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .overlay {
            if filteredCatalog.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(L("Real node models", "节点真实模型"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(L("\(catalog.count) models", "\(catalog.count) 个模型"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var modelHelpPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Model settings", "模型设置"))
                .font(.headline)
            Text(L(
                "This list manages the node's real Desktop models and 1M capability. Application route mappings are configured on the main Desktop page.",
                "此处管理节点在 Desktop 中可用的真实模型及 1M 能力；应用模型映射请在 Desktop 主页面设置。"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("1M")
                .font(.caption.weight(.semibold))
            Text(L(
                "Enable only for targets that truly support a 1M context window. Capability changes refresh Desktop automatically.",
                "仅为确实支持 1M 上下文的目标开启；能力变化会自动刷新 Desktop。"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 330, alignment: .leading)
    }
}
