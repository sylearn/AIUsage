import SwiftUI

// MARK: - Code Gateway Section
// Claude Code 轨「全局统一代理」配置卡片：常驻固定端口对外暴露稳定入口。
// Claude Code 一次性指向它即可；四路模型映射由上方 Code 模型卡负责。
// 启用期间接管 settings.json，并禁用每节点单独激活（节点开关由本卡片统一切换激活节点）。

struct ClaudeGlobalProxySection: View {
    @ObservedObject private var manager = GlobalProxyManager.claude
    @ObservedObject private var runtime = GlobalProxyRuntime.claude

    @State private var localSelectedNodeId = ""
    private let externalSelectedNodeId: Binding<String>?
    @State private var pendingRestartNodeId: String?

    private static let claudeBrand = Color.indigo

    init(selectedNodeId: Binding<String>? = nil) {
        externalSelectedNodeId = selectedNodeId
    }

    private var selectedNodeId: String {
        get { externalSelectedNodeId?.wrappedValue ?? localSelectedNodeId }
        nonmutating set {
            if let externalSelectedNodeId {
                externalSelectedNodeId.wrappedValue = newValue
            } else {
                localSelectedNodeId = newValue
            }
        }
    }

    private var nodes: [GlobalProxyNodeRef] { manager.availableNodes() }
    private var isEnabled: Bool { manager.isEnabled }
    private var modelMode: ClaudeDesktopCatalogMode { manager.config.effectiveClaudeCodeCatalogMode }

    var body: some View {
        ClaudeProductGatewayCard(
            brand: Self.claudeBrand,
            systemImage: "terminal",
            title: L("Code Gateway", "Code 网关"),
            subtitle: "Claude Code",
            statusText: gatewayStatusText,
            statusColor: gatewayStatusColor,
            isEnabled: isEnabled,
            isBusy: manager.isBusy,
            hasNodes: !nodes.isEmpty,
            emptyHint: L("Create a Claude node first.", "请先创建 Claude 节点。"),
            endpoint: "127.0.0.1:\(manager.config.port)",
            mode: modelMode,
            effectText: modelMode == .smartRoutes
                ? L("Live", "即时生效")
                : L("New session", "新会话生效"),
            effectSymbol: modelMode == .smartRoutes ? "bolt.fill" : "arrow.clockwise",
            effectColor: modelMode == .smartRoutes ? .green : .orange,
            isToggleDisabled: (!nodes.isEmpty ? false : !isEnabled),
            toggle: enableBinding,
            onModeSelect: { mode in
                Task { await manager.updateClaudeCodeCatalogMode(mode) }
            },
            nodeControl: { nodeControl },
            config: { configContent },
            extraAction: { EmptyView() },
            message: {
                if let error = manager.operationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        )
        .onAppear(perform: syncFromConfig)
        .confirmationDialog(
            L("Switch Code to another node?", "切换 Code 节点？"),
            isPresented: Binding(
                get: { pendingRestartNodeId != nil },
                set: { if !$0 { pendingRestartNodeId = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("Switch Node", "切换节点")) {
                guard let nodeId = pendingRestartNodeId else { return }
                selectedNodeId = nodeId
                pendingRestartNodeId = nil
                Task { await manager.switchActiveNode(to: nodeId) }
            }
            Button(L("Cancel", "取消"), role: .cancel) {
                pendingRestartNodeId = nil
            }
        } message: {
            Text(L(
                "Node models expose real model names. The route will switch now; restart running Claude Code sessions so they reload the new catalog.",
                "“节点模型”会暴露真实模型名。路由将立即切换；请重启正在运行的 Claude Code 会话以重新加载模型目录。"
            ))
        }
    }

    // MARK: - Active Node (header; hot-switch when enabled)

    private var nodeControl: some View {
        GlobalProxyChipMenu(
            brand: Self.claudeBrand,
            title: currentNodeName,
            systemImage: "bolt.fill",
            isDisabled: manager.isBusy,
            items: nodes.map { GlobalProxyPickerItem(id: $0.id, name: $0.name) },
            selectedId: nodeBinding.wrappedValue,
            onSelect: { nodeBinding.wrappedValue = $0 }
        )
        .help(L("Choose the Code Gateway route", "选择 Code 网关路由"))
    }

    private var currentNodeName: String {
        let id = nodeBinding.wrappedValue
        return nodes.first(where: { $0.id == id })?.name ?? L("Select", "选择")
    }

    // MARK: - Configuration

    private var configContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("Local gateway", "本机网关"), systemImage: "network")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            GlobalProxyField(label: L("Local port", "本机端口")) {
                TextField(
                    "14400",
                    value: portBinding,
                    format: IntegerFormatStyle<Int>.number.grouping(.never)
                )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
            }

            Text(L(
                "Used only by Claude Code on this Mac. Change it only when the port conflicts.",
                "仅供本机 Claude Code 使用；只有端口冲突时才需要修改。"
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10).fill(Self.claudeBrand.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Self.claudeBrand.opacity(0.10)))
    }

    private var portBinding: Binding<Int> {
        Binding(
            get: { manager.config.port },
            set: {
                manager.updateClaudeModels(
                    port: $0,
                    opus: manager.config.claudeOpus,
                    sonnet: manager.config.claudeSonnet,
                    haiku: manager.config.claudeHaiku
                )
            }
        )
    }

    private var enableBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { newValue in
                if newValue {
                    let target = resolvedSelection
                    guard !target.isEmpty else { return }
                    Task { await manager.enable(activeNodeId: target) }
                } else {
                    Task { await manager.disable() }
                }
            }
        )
    }

    private var nodeBinding: Binding<String> {
        Binding(
            get: { manager.isRuntimeEnabled ? (manager.activeNodeId ?? resolvedSelection) : resolvedSelection },
            set: { newId in
                if isEnabled, modelMode == .fullNodeCatalog,
                   newId != manager.activeNodeId {
                    pendingRestartNodeId = newId
                } else {
                    selectedNodeId = newId
                }
                if manager.isRuntimeEnabled && pendingRestartNodeId == nil {
                    Task { await manager.switchActiveNode(to: newId) }
                }
            }
        )
    }

    // MARK: - Helpers

    /// 当前选定节点（兜底到首个可用节点），保证 Picker/启用按钮总有合法目标。
    private var resolvedSelection: String {
        if manager.isRuntimeEnabled,
           let active = manager.activeNodeId,
           nodes.contains(where: { $0.id == active }) {
            return active
        }
        if !selectedNodeId.isEmpty, nodes.contains(where: { $0.id == selectedNodeId }) {
            return selectedNodeId
        }
        return manager.activeNodeId ?? nodes.first?.id ?? ""
    }

    private var gatewayStatusText: String {
        if manager.isBusy { return L("Working", "处理中") }
        if isEnabled, runtime.isRunning { return L("Connected", "已接入") }
        if isEnabled { return L("Starting", "启动中") }
        return L("Off", "未接入")
    }

    private var gatewayStatusColor: Color {
        if manager.isBusy { return .orange }
        if isEnabled, runtime.isRunning { return .green }
        if isEnabled { return .orange }
        return .secondary
    }

    private func syncFromConfig() {
        selectedNodeId = resolvedSelection
    }
}
