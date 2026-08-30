import SwiftUI
import QuotaBackend

// MARK: - ProxyManagementView Node List & Drag Reorder
// 节点卡片列表（展开时内联统计/最近请求）与手势驱动的「拖拽实时让位」重排逻辑。
// 拆出以控制单文件规模；与主视图共享 family-scoped 的 @State 拖拽状态。

extension ProxyManagementView {

    // MARK: - Configurations List

    var configurationsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Node List", "节点列表"))
                    .font(.headline.weight(.bold))
                Spacer()
            }

            LazyVStack(spacing: 0) {
                let ids = displayConfigs.map(\.id)
                let srcIdx = draggingConfigId.flatMap { id in ids.firstIndex(of: id) }
                let target = srcIdx.map { nodeTarget(ids: ids, srcIdx: $0) }
                ForEach(Array(displayConfigs.enumerated()), id: \.element.id) { index, config in
                    let stats = viewModel.statistics[config.id] ?? .empty
                    let isSelected = selectedConfigId == config.id
                    let isDragging = draggingConfigId == config.id
                    let claudeUsage = claudeNodeUsage(for: config.id)
                    let codexUsage = codexNodeUsage(for: config.id)
                    let canAttachCodeToGateway = shouldAttachCodeToGateway(nodeID: config.id)
                    let deletionBlockReason = viewModel.managedRuntimeDeletionBlockReason(for: config.id)
                    VStack(spacing: 0) {
                        ConfigurationCardView(
                            config: config,
                            isActive: nodeIsRoutedToClient(config),
                            isProxyOnlyRunning: showsClaudeProductConfiguration
                                ? viewModel.proxyOnlyRunningIds.contains(config.id)
                                : viewModel.isNodeRuntimeRunning(config.id),
                            isRuntimeManuallyHeld: viewModel.proxyOnlyRunningIds.contains(config.id),
                            showsActivationControl: showsClaudeProductConfiguration || family.isCodex,
                            isBusy: viewModel.isOperationInProgress(config.id)
                                || isManagedRuntimeBusy(nodeID: config.id),
                            isActivationManaged: !family.isCodex && claudeGateway.isEnabled,
                            canAttachCodeToGateway: canAttachCodeToGateway,
                            claudeUsage: claudeUsage,
                            codexUsage: codexUsage,
                            deletionBlockReason: deletionBlockReason,
                            isSelected: isSelected,
                            statsRequests: stats.totalRequests,
                            statsSuccessRate: stats.successRate,
                            lastRequestAt: stats.lastRequestAt,
                            connectivityState: viewModel.connectivityTestStates[config.id],
                            onDragChanged: { t in
                                if draggingConfigId != config.id {
                                    draggingConfigId = config.id
                                    if selectedConfigId != nil { selectedConfigId = nil }
                                }
                                dragTranslation = t
                            },
                            onDragEnded: { commitNodeDrag() },
                            onToggleActivation: { toggleCodeRoute(for: config) },
                            onToggleProxyOnly: {
                                Task {
                                    if showsClaudeProductConfiguration || family.isCodex {
                                        await viewModel.toggleProxyOnly(config.id)
                                    } else {
                                        await viewModel.toggleNodeRuntimeManually(config.id)
                                    }
                                }
                            },
                            onCopyLaunchCommand: { viewModel.copyLaunchCommand(for: config.id) },
                            onTestConnectivity: { Task { await viewModel.testConnectivity(config.id) } },
                            onEdit: {
                                if let profile = viewModel.profileStore.profile(for: config.id) {
                                    editingProfile = profile
                                } else {
                                    editingConfig = config
                                }
                            },
                            onDelete: { pendingDeletionConfig = config },
                            onDuplicate: { duplicateConfig(config) },
                            onSelectDefaultModel: { model in switchDefaultModel(config, to: model) },
                            onToggleSelection: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedConfigId = selectedConfigId == config.id ? nil : config.id
                                }
                            }
                        )
                        .equatable()
                        .background {
                            if draggingConfigId != nil {
                                nodeRowHeightReader(for: config.id)
                            }
                        }
                        .padding(.vertical, 4)

                        if isSelected && config.needsProxyProcess {
                            statisticsSection(for: config)
                                .padding(.top, 8)
                                .padding(.bottom, 4)
                            modelAvailabilitySection(for: config)
                                .padding(.bottom, 4)
                            recentRequestsSection(for: config)
                                .padding(.bottom, 4)
                        }
                    }
                    .offset(y: nodeRowOffset(index: index, id: config.id, srcIdx: srcIdx, target: target))
                    .scaleEffect(isDragging ? 1.02 : 1, anchor: .center)
                    .shadow(color: .black.opacity(isDragging ? 0.22 : 0),
                            radius: isDragging ? 9 : 0, x: 0, y: isDragging ? 5 : 0)
                    .zIndex(isDragging ? 1 : 0)
                    .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.82), value: target)
                    .animation(.interactiveSpring(response: 0.30, dampingFraction: 0.85), value: draggingConfigId)
                }
            }
            .onPreferenceChange(NodeRowHeightKey.self) { heights in
                guard draggingConfigId != nil, nodeRowHeights != heights else { return }
                nodeRowHeights = heights
            }
            .onChange(of: draggingConfigId) { _, id in
                if id == nil, !nodeRowHeights.isEmpty {
                    nodeRowHeights.removeAll()
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
    }

    private func nodeIsRoutedToClient(_ config: ProxyConfiguration) -> Bool {
        if family.isCodex {
            if codexGateway.isEnabled {
                return codexGateway.activeNodeId == config.id
            }
            return viewModel.isNodeActivated(config.id)
        }
        guard showsClaudeProductConfiguration else { return false }
        return viewModel.isNodeActivated(config.id)
    }

    private func claudeNodeUsage(for nodeID: String) -> ClaudeNodeUsage {
        guard !family.isCodex else { return .none }
        let directCode = viewModel.isNodeActivated(nodeID)
        let gatewayCode = claudeGateway.isEnabled && claudeGateway.activeNodeId == nodeID
        let node = viewModel.configurations.first(where: { $0.id == nodeID })
        let directCodeRunning = directCode && (node?.needsProxyProcess != true || viewModel.isProxyRunning(nodeID))
        let gatewayRunning = claudeGatewayRuntime.isProcessRunning
        let desktop = desktopGateway.isEnabled && desktopGateway.activeNodeId == nodeID
        let science = scienceProxy.isEnabled && scienceProxy.activeNodeId == nodeID
        return ClaudeNodeUsage(
            codeRoute: gatewayCode ? .gateway : (directCode ? .direct : nil),
            codeRunning: gatewayCode ? gatewayRunning : directCodeRunning,
            desktop: desktop,
            desktopRunning: desktop && desktopGatewayRuntime.isClaudeDesktopListenerRunning,
            science: science,
            scienceRunning: science && scienceProxy.isProxyRunning && scienceProxy.sandboxHealthy
        )
    }

    private func codexNodeUsage(for nodeID: String) -> CodexNodeUsage {
        guard family.isCodex else { return .none }
        if codexGateway.isEnabled, codexGateway.activeNodeId == nodeID {
            return CodexNodeUsage(route: .gateway, running: codexGatewayRuntime.isRunning)
        }
        if viewModel.isNodeActivated(nodeID) {
            let node = viewModel.configurations.first { $0.id == nodeID }
            let running = node?.needsProxyProcess != true || viewModel.isProxyRunning(nodeID)
            return CodexNodeUsage(route: .direct, running: running)
        }
        return .none
    }

    private func isManagedRuntimeBusy(nodeID: String) -> Bool {
        if codexGateway.activeNodeId == nodeID, codexGateway.isBusy { return true }
        if claudeGateway.activeNodeId == nodeID, claudeGateway.isBusy { return true }
        if desktopGateway.activeNodeId == nodeID, desktopGateway.isBusy { return true }
        if scienceProxy.activeNodeId == nodeID, scienceProxy.isBusy { return true }
        if openCodeGateway.activeNodeId == nodeID, openCodeGateway.isBusy { return true }
        return false
    }

    private func shouldAttachCodeToGateway(nodeID: String) -> Bool {
        false
    }

    private func toggleCodeRoute(for config: ProxyConfiguration) {
        if family.isCodex {
            Task { await toggleCodexRoute(config) }
            return
        }
        if shouldAttachCodeToGateway(nodeID: config.id) {
            Task { await claudeGateway.enable(activeNodeId: config.id) }
        } else {
            Task { await viewModel.toggleActivation(config.id) }
        }
    }

    /// 全局代理开着时，节点开关热切换上游；关掉当前节点则停用全局代理。未开全局代理时走每节点接入。
    private func toggleCodexRoute(_ config: ProxyConfiguration) async {
        if codexGateway.isEnabled {
            if codexGateway.activeNodeId == config.id {
                await codexGateway.disable()
            } else {
                await viewModel.activateConfiguration(config.id)
            }
            if let failure = codexGateway.operationError {
                viewModel.operationErrorMessage = failure
            }
            return
        }
        await viewModel.toggleActivation(config.id)
    }

    // MARK: - Model Quick Switch

    /// 卡片上的默认模型快速切换：从模型目录点选 → 写入 profile 并走滚动重载。
    /// 激活中节点自动断开→保存→重新接入；费用规则按真实模型名独立匹配。
    func switchDefaultModel(_ config: ProxyConfiguration, to model: String) {
        guard var profile = viewModel.profileStore.profile(for: config.id) else { return }
        if profile.metadata.nodeType.isCodex {
            // Codex 单模型：config.toml 的 model 即 bigModel。
            profile.metadata.proxy.modelMapping.bigModel.name = model
        }
        profile.metadata.proxy.defaultModel = model
        profile.metadata.proxy.modelCatalog.mergeModels([model])
        profile.syncEnvFromProxy()
        Task { await viewModel.updateProfile(profile) }
    }

    // MARK: - Drag & Drop Helpers (手势驱动「拖拽实时让位」，与订阅账号列表同一套手感)

    // 节点卡片在 LazyVStack(spacing:0) 中各带 .padding(.vertical,4)，上下合计 8 作为行间距。
    private static let nodeRowSpacing: CGFloat = 8
    private static let nodeFallbackHeight: CGFloat = 96

    private func nodeRowHeightReader(for id: String) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: NodeRowHeightKey.self, value: [id: geo.size.height])
        }
    }

    /// 被拖行的步幅（实测卡片高度 + 行间距），即让位时其余行平移的距离。
    private func nodeStride(_ id: String) -> CGFloat {
        (nodeRowHeights[id] ?? Self.nodeFallbackHeight) + Self.nodeRowSpacing
    }

    /// 各行在基础布局中的中心 Y（被拖行仍按原槽位计入），用于阈值判断。
    private func nodeBaseCenters(_ ids: [String]) -> [CGFloat] {
        var centers: [CGFloat] = []
        var top: CGFloat = 0
        for id in ids {
            let h = nodeRowHeights[id] ?? Self.nodeFallbackHeight
            centers.append(top + h / 2)
            top += h + Self.nodeRowSpacing
        }
        return centers
    }

    /// 由跟手位移推出被拖行应落入的目标「条目下标」（与相邻行中心比较，支持变高行）。
    private func nodeTarget(ids: [String], srcIdx: Int) -> Int {
        guard !ids.isEmpty, srcIdx < ids.count else { return srcIdx }
        let centers = nodeBaseCenters(ids)
        let draggedCenter = centers[srcIdx] + dragTranslation
        var t = srcIdx
        while t < ids.count - 1 && draggedCenter > centers[t + 1] { t += 1 }
        while t > 0 && draggedCenter < centers[t - 1] { t -= 1 }
        return t
    }

    /// 单行的 y 位移：被拖行跟手；其余行按「让位」规则平移一个被拖行步幅。
    private func nodeRowOffset(index: Int, id: String, srcIdx: Int?, target: Int?) -> CGFloat {
        if id == draggingConfigId { return dragTranslation }
        guard let srcIdx, let target, let dragId = draggingConfigId else { return 0 }
        let step = nodeStride(dragId)
        if target > srcIdx, index > srcIdx, index <= target { return -step }
        if target < srcIdx, index >= target, index < srcIdx { return step }
        return 0
    }

    /// 松手时把被拖卡片落到目标条目下标（换算为全局插入下标），并清空拖拽状态。
    private func commitNodeDrag() {
        let ids = displayConfigs.map(\.id)
        defer {
            draggingConfigId = nil
            dragTranslation = 0
        }
        guard let id = draggingConfigId, let srcIdx = ids.firstIndex(of: id) else { return }
        let target = nodeTarget(ids: ids, srcIdx: srcIdx)
        guard target != srcIdx else { return }
        // 目标「条目下标」→ 当前展示列表的插入间隙 → 全局插入下标（moveConfiguration 用间隙语义）。
        let displayedGap = target > srcIdx ? target + 1 : target
        let globalTo = globalSlotIndex(forDisplayedIndex: displayedGap)
        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.85)) {
            viewModel.moveConfiguration(fromId: id, toIndex: globalTo)
        }
    }
}

// MARK: - Node Row Height Preference

/// 收集每张节点卡片的实测高度，供手势拖拽计算落点/让位偏移。
private struct NodeRowHeightKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
