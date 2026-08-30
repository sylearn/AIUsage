import SwiftUI

// MARK: - Codex Global Proxy Section
// Codex 轨「全局统一代理」配置卡片：常驻固定端口对外暴露一个稳定入口（端口 + client key + 虚拟模型），
// Codex CLI 一次性指向它即可。切换激活节点走进程内热替换，CLI 无感（无需重启 / 端口不变）。
// 启用期间接管 config.toml；节点列表的接入开关会热切换本卡片的激活节点。

struct CodexGlobalProxySection: View {
    @ObservedObject private var manager = GlobalProxyManager.shared
    @ObservedObject private var runtime = GlobalProxyRuntime.codex
    @ObservedObject private var proxyVM = ProxyViewModel.shared

    @State private var virtualModel: String = ""
    @State private var selectedNodeId: String = ""

    private static let codexBrand = Color(red: 0.40, green: 0.52, blue: 0.92)

    private var nodes: [GlobalProxyNodeRef] { manager.availableNodes() }
    private var isEnabled: Bool { manager.isEnabled }

    var body: some View {
        GlobalProxySectionScaffold(
            brand: Self.codexBrand,
            title: L("Global Proxy", "全局代理"),
            subtitle: L("One stable endpoint; choose a node and start.", "一个固定入口，选择节点即可启动。"),
            isEnabled: isEnabled,
            isRunning: runtime.isRunning,
            isRuntimeOwnedByAnotherConsumer: false,
            otherConsumerStatus: nil,
            isBusy: manager.isBusy,
            port: manager.config.port,
            bindHost: manager.config.displayBindHost,
            allowLAN: allowLANBinding,
            hasNodes: !nodes.isEmpty,
            emptyHint: L("Create a Codex node first to use the global proxy.", "请先创建 Codex 节点后再使用全局代理。"),
            errorText: manager.operationError,
            toggle: enableBinding,
            nodeControl: { nodeControl },
            config: { configContent },
            runningSummary: { runningSummary }
        )
        .onAppear(perform: syncFromConfig)
    }

    // MARK: - Active Node (header; hot-switch when enabled)

    private var nodeControl: some View {
        HStack(spacing: 6) {
            GlobalProxyInlineLabel(text: L("Active Node", "激活节点"))
            GlobalProxyChipMenu(
                brand: Self.codexBrand,
                title: currentNodeName,
                systemImage: "bolt.fill",
                isDisabled: manager.isBusy,
                items: nodes.map { GlobalProxyPickerItem(id: $0.id, name: $0.name) },
                selectedId: nodeBinding.wrappedValue,
                onSelect: { nodeBinding.wrappedValue = $0 }
            )
        }
    }

    private var currentNodeName: String {
        let id = nodeBinding.wrappedValue
        return nodes.first(where: { $0.id == id })?.name ?? L("Select", "选择")
    }

    // MARK: - Running Summary (read-only chips when enabled)

    @ViewBuilder private var runningSummary: some View {
        GlobalProxySummaryChip(label: L("Model", "模型"), value: manager.config.virtualModel)
    }

    // MARK: - Configuration (port / virtual model; editable only while disabled)

    private var configContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                GlobalProxyField(label: L("Port", "端口")) {
                    TextField(
                        "14399",
                        value: portBinding,
                        format: IntegerFormatStyle<Int>.number.grouping(.never)
                    )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                GlobalProxyField(label: L("Model", "模型")) {
                    TextField(GlobalProxyConfig.defaultVirtualModel, text: $virtualModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                        .onChange(of: virtualModel) { _, _ in commitSettings() }
                }
                Spacer(minLength: 0)
            }
            GlobalProxyTip(text: L(
                "Model is just the fixed entry name Codex sends — name it anything. Each request is rewritten to the active node's real upstream model.",
                "模型仅作 Codex 固定入口名，可任意取名；每次请求会被改写为激活节点的真实上游模型。"
            ))
        }
    }

    private var allowLANBinding: Binding<Bool> {
        Binding(
            get: { manager.config.effectiveAllowLAN },
            set: { manager.updateAllowLAN($0) }
        )
    }

    private var portBinding: Binding<Int> {
        Binding(
            get: { manager.config.port },
            set: {
                manager.updateSettings(
                    port: $0,
                    virtualModel: virtualModel,
                    clientKey: manager.config.clientKey
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
            get: { isEnabled ? (manager.activeNodeId ?? resolvedSelection) : resolvedSelection },
            set: { newId in
                selectedNodeId = newId
                if isEnabled {
                    Task { await manager.switchActiveNode(to: newId) }
                }
            }
        )
    }

    // MARK: - Helpers

    /// 当前选定节点（兜底到首个可用节点），保证 Picker/启用按钮总有合法目标。
    private var resolvedSelection: String {
        if !selectedNodeId.isEmpty, nodes.contains(where: { $0.id == selectedNodeId }) {
            return selectedNodeId
        }
        return manager.activeNodeId ?? nodes.first?.id ?? ""
    }

    private func syncFromConfig() {
        virtualModel = manager.config.virtualModel
        selectedNodeId = resolvedSelection
    }

    private func commitSettings() {
        guard !isEnabled else { return }
        manager.updateSettings(
            port: manager.config.port,
            virtualModel: virtualModel,
            clientKey: manager.config.clientKey
        )
    }
}
