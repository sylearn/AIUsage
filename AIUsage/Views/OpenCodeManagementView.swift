import SwiftUI
import UniformTypeIdentifiers
import QuotaBackend

// MARK: - OpenCode Management View
// 「OpenCode 代理」主视图，与 Claude/Codex 节点管理页同一套骨架：
// 状态横幅 → 工具栏（opencode.json / 导入 / 导出 / 新建）→ 汇总条 → 节点列表。
// 单击节点卡片内联展开：配置明细（卡片内）+ 统计信息 + 最近请求（卡片下方）。
// 直连模式: 激活即把节点写入受管 provider 块，停用即整文还原。
// 代理模式（路线 B）: 激活同时拉起本地透传进程，opencode.json 指向 127.0.0.1。
// 用量/费用来自 opencode.db 节点归因（直连/代理都有）；成功率/失败明细来自代理日志。

struct OpenCodeManagementView: View {
    // 注：部分成员为 internal（去掉 private），以便横幅/工具栏拆分到
    // OpenCodeManagementView+Toolbar.swift 后仍可访问（Swift private 为文件级）。
    @ObservedObject var store = OpenCodeNodeStore.shared
    @ObservedObject var proxyRuntime = OpenCodeProxyRuntime.shared
    @ObservedObject var statsStore = OpenCodeNodeStatsStore.shared
    @Environment(\.colorScheme) var colorScheme

    @State var editingNode: OpenCodeNode?
    @State private var pendingDeletion: OpenCodeNode?
    @State var actionError: String?
    @State var importSummary: String?
    @State var isSyncingCCSwitch = false
    /// opencode.json 内嵌编辑器（语法高亮，与 Claude 页 settings.json 同款）。
    @State var showConfigFileEditor = false
    @State private var activationInProgress = false
    /// 单击展开详情的节点 id（再次单击收起）。
    @State private var selectedNodeId: String?
    /// 节点连通性测试状态（与 Claude/Codex 节点同构，会话内有效）。
    @State private var connectivityStates: [String: ProxyConnectivityTestState] = [:]

    // 手势驱动的「拖拽实时让位」重排状态（与 Claude/Codex 节点列表同一套手感）。
    @State private var draggingNodeId: String?
    @State private var dragTranslation: CGFloat = 0
    @State private var nodeRowHeights: [String: CGFloat] = [:]

    static let brand = Color(red: 0.18, green: 0.83, blue: 0.75)

    var body: some View {
        VStack(spacing: 0) {
            if store.nodes.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        proxyErrorBanner
                        actionBar
                        OpenCodeOverviewStrip(store: store, statsStore: statsStore, proxyRuntime: proxyRuntime)
                        OpenCodeGlobalConfigSection(store: store)
                        OpenCodeGlobalProxySection()
                        nodeListSection
                    }
                    .padding(20)
                }
            }
        }
        .appPageChrome(colorScheme)
        .onAppear {
            statsStore.refreshIfStale()
            statsStore.startPolling()
        }
        .onDisappear {
            statsStore.stopPolling()
        }
        .sheet(item: $editingNode) { node in
            OpenCodeNodeEditorView(node: node) { saved in
                store.upsert(saved)
            }
        }
        .sheet(isPresented: $showConfigFileEditor) {
            LocalSettingsEditorView(
                filePath: store.configPath,
                displayTitle: "~/.config/opencode/\((store.configPath as NSString).lastPathComponent)",
                subtitle: L("Live configuration file for OpenCode", "OpenCode 当前生效的配置文件")
            )
        }
        .alert(
            L("Import Finished", "导入完成"),
            isPresented: Binding(get: { importSummary != nil }, set: { if !$0 { importSummary = nil } })
        ) {
            Button("OK") { importSummary = nil }
        } message: {
            Text(importSummary ?? "")
        }
        .alert(
            L("Delete this node?", "删除该节点？"),
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button(L("Delete", "删除"), role: .destructive) {
                if let node = pendingDeletion {
                    if selectedNodeId == node.id { selectedNodeId = nil }
                    store.delete(node)
                }
                pendingDeletion = nil
            }
            Button(L("Cancel", "取消"), role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(L(
                "The node and its API key will be removed. If it is active, opencode.json will be restored first.",
                "节点及其 API Key 将被移除。若该节点正在生效，将先还原 opencode.json。"
            ))
        }
        .alert(
            L("Operation Failed", "操作失败"),
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - Node List

    private var nodeListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Node List", "节点列表"))
                    .font(.headline.weight(.bold))
                Spacer()
            }

            LazyVStack(spacing: 0) {
                let ids = store.nodes.map(\.id)
                let srcIdx = draggingNodeId.flatMap { id in ids.firstIndex(of: id) }
                let target = srcIdx.map { dragTarget(ids: ids, srcIdx: $0) }
                ForEach(Array(store.nodes.enumerated()), id: \.element.id) { index, node in
                    let isDragging = draggingNodeId == node.id
                    nodeRow(node)
                        .offset(y: rowOffset(index: index, id: node.id, srcIdx: srcIdx, target: target))
                        .scaleEffect(isDragging ? 1.02 : 1, anchor: .center)
                        .shadow(color: .black.opacity(isDragging ? 0.22 : 0),
                                radius: isDragging ? 9 : 0, y: isDragging ? 5 : 0)
                        .zIndex(isDragging ? 1 : 0)
                        .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.82), value: target)
                        .animation(.interactiveSpring(response: 0.30, dampingFraction: 0.85), value: draggingNodeId)
                }
            }
            .onPreferenceChange(OpenCodeNodeRowHeightKey.self) { heights in
                guard draggingNodeId != nil, nodeRowHeights != heights else { return }
                nodeRowHeights = heights
            }
            .onChange(of: draggingNodeId) { _, id in
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

    /// 单个节点行：卡片 + 选中态的内联统计/最近请求。
    /// 拆成独立函数避免 ForEach 内的巨型表达式（编译器类型检查超时）。
    @ViewBuilder
    private func nodeRow(_ node: OpenCodeNode) -> some View {
        let isSelected = selectedNodeId == node.id
        let stats = statsStore.stats(for: node)
        VStack(spacing: 0) {
            nodeCard(node, isSelected: isSelected, stats: stats)
                .equatable()
                .background {
                    if draggingNodeId != nil {
                        rowHeightReader(for: node.id)
                    }
                }
                .padding(.vertical, 4)

            if isSelected {
                OpenCodeNodeStatisticsSection(
                    node: node,
                    statsStore: statsStore,
                    proxyRuntime: proxyRuntime
                )
                .padding(.top, 8)
                .padding(.bottom, 4)
                OpenCodeNodeAvailabilitySection(
                    node: node,
                    proxyRuntime: proxyRuntime
                )
                .padding(.bottom, 4)
                OpenCodeNodeRecentRequestsSection(
                    node: node,
                    statsStore: statsStore,
                    proxyRuntime: proxyRuntime
                )
                .padding(.bottom, 4)
            }
        }
    }

    private func nodeCard(
        _ node: OpenCodeNode,
        isSelected: Bool,
        stats: OpenCodeNodeStatsFetcher.NodeStats?
    ) -> OpenCodeNodeCard {
        // pills = opencode.db 节点归因（直连/路线B）+ 全局统一代理永久累计（按节点定价）。
        // 两源互斥（db 已排除裸 aiusage 全局流量），相加即该节点真实总量，全局代理下也持续更新。
        let global = proxyRuntime.globalStats(forNodeId: node.id)
        let mergedRequests = (stats?.requestCount ?? 0) + (global?.requestCount ?? 0)
        let mergedCost = (stats?.costUsd ?? 0) + (global?.costUsd ?? 0)
        let mergedLastUsed = [stats?.lastUsedAt, global?.lastRequestAt].compactMap { $0 }.max()
        return OpenCodeNodeCard(
            node: node,
            isActive: node.id == store.activeNodeId,
            isProxyOnlyRunning: store.proxyOnlyNodeIds.contains(node.id),
            isSelected: isSelected,
            isBusy: activationInProgress,
            activationDisabled: !node.isComplete,
            statsRequests: mergedRequests,
            statsCostUsd: mergedCost,
            lastRequestAt: mergedLastUsed,
            connectivityState: connectivityStates[node.id],
            onDragChanged: { translation in
                if draggingNodeId != node.id {
                    draggingNodeId = node.id
                    if selectedNodeId != nil { selectedNodeId = nil }
                }
                dragTranslation = translation
            },
            onDragEnded: { commitNodeDrag() },
            onToggleActivation: { toggleActivation(node) },
            onToggleProxyMode: { toggleProxyMode(node) },
            onToggleProxyOnly: { toggleProxyOnly(node) },
            onTestConnectivity: { testConnectivity(node) },
            onCopyLaunchCommand: { copyLaunchCommand(node) },
            onSelectDefaultModel: { selectDefaultModel(node, model: $0) },
            onEdit: { editingNode = node },
            onDuplicate: { store.duplicate(node) },
            onDelete: { pendingDeletion = node },
            onToggleSelection: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedNodeId = isSelected ? nil : node.id
                }
            }
        )
    }

    // MARK: - Drag Reorder Helpers

    // 节点卡片在 LazyVStack(spacing:0) 中各带 .padding(.vertical,4)，上下合计 8 作为行间距。
    private static let nodeRowSpacing: CGFloat = 8
    private static let nodeFallbackHeight: CGFloat = 96

    private func rowHeightReader(for id: String) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: OpenCodeNodeRowHeightKey.self, value: [id: geo.size.height])
        }
    }

    private func rowStride(_ id: String) -> CGFloat {
        (nodeRowHeights[id] ?? Self.nodeFallbackHeight) + Self.nodeRowSpacing
    }

    /// 各行在基础布局中的中心 Y（被拖行仍按原槽位计入），用于阈值判断。
    private func rowBaseCenters(_ ids: [String]) -> [CGFloat] {
        var centers: [CGFloat] = []
        var top: CGFloat = 0
        for id in ids {
            let height = nodeRowHeights[id] ?? Self.nodeFallbackHeight
            centers.append(top + height / 2)
            top += height + Self.nodeRowSpacing
        }
        return centers
    }

    /// 由跟手位移推出被拖行应落入的目标条目下标。
    private func dragTarget(ids: [String], srcIdx: Int) -> Int {
        guard !ids.isEmpty, srcIdx < ids.count else { return srcIdx }
        let centers = rowBaseCenters(ids)
        let draggedCenter = centers[srcIdx] + dragTranslation
        var target = srcIdx
        while target < ids.count - 1 && draggedCenter > centers[target + 1] { target += 1 }
        while target > 0 && draggedCenter < centers[target - 1] { target -= 1 }
        return target
    }

    /// 单行 y 位移：被拖行跟手；其余行按「让位」规则平移一个被拖行步幅。
    private func rowOffset(index: Int, id: String, srcIdx: Int?, target: Int?) -> CGFloat {
        if id == draggingNodeId { return dragTranslation }
        guard let srcIdx, let target, let dragId = draggingNodeId else { return 0 }
        let step = rowStride(dragId)
        if target > srcIdx, index > srcIdx, index <= target { return -step }
        if target < srcIdx, index >= target, index < srcIdx { return step }
        return 0
    }

    /// 松手时把被拖卡片落到目标下标并整表持久化顺序。
    private func commitNodeDrag() {
        let ids = store.nodes.map(\.id)
        defer {
            draggingNodeId = nil
            dragTranslation = 0
        }
        guard let id = draggingNodeId, let srcIdx = ids.firstIndex(of: id) else { return }
        let target = dragTarget(ids: ids, srcIdx: srcIdx)
        guard target != srcIdx else { return }
        var reordered = ids
        reordered.remove(at: srcIdx)
        reordered.insert(id, at: target)
        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.85)) {
            store.applyOrder(ids: reordered)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            ProviderIconView("opencode", size: 46)
            Text(L("No OpenCode nodes yet", "还没有 OpenCode 节点"))
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text(L(
                "Add an upstream endpoint (OpenAI-compatible, Anthropic, or OpenAI Responses). Activating a node writes it into opencode.json — directly, or through a local proxy when you want per-request logs.",
                "添加一个上游接入点（OpenAI 兼容 / Anthropic / OpenAI Responses）。激活节点会把它写入 opencode.json——默认直连；需要请求日志时可开启本地代理模式。"
            ))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)

            HStack(spacing: 10) {
                Button {
                    editingNode = OpenCodeNode()
                } label: {
                    Label(L("Add Node", "添加节点"), systemImage: "plus")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Self.brand)

                Button {
                    syncCCSwitch()
                } label: {
                    if isSyncingCCSwitch {
                        Label { Text(L("Importing cc-switch", "正在导入 cc-switch")) } icon: {
                            ProgressView().controlSize(.small)
                        }
                    } else {
                        Label(L("Import cc-switch", "导入 cc-switch"), systemImage: "tray.and.arrow.down.fill")
                    }
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .disabled(isSyncingCCSwitch)
                .help(L(
                    "Mirror-sync OpenCode providers from cc-switch.",
                    "从 cc-switch 镜像同步 OpenCode 供应商。"
                ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func toggleActivation(_ node: OpenCodeNode) {
        if node.id == store.activeNodeId {
            deactivate()
        } else {
            activate(node)
        }
    }

    private func activate(_ node: OpenCodeNode) {
        guard !activationInProgress else { return }
        activationInProgress = true
        Task {
            defer { activationInProgress = false }
            do {
                try await store.activate(node)
                statsStore.refresh()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func deactivate() {
        do {
            try store.deactivate()
            statsStore.refresh()
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// 切换节点的代理模式开关；若该节点正在生效，upsert 会自动按新模式重新激活。
    private func toggleProxyMode(_ node: OpenCodeNode) {
        var updated = node
        updated.proxyEnabled.toggle()
        if !(1...65_535).contains(updated.proxyPort) {
            updated.proxyPort = OpenCodeNode.defaultProxyPort
        }
        store.upsert(updated)
    }

    /// 「仅代理」启停：拉起/停止本地透传进程但不接管 opencode.json（配合启动命令使用）。
    private func toggleProxyOnly(_ node: OpenCodeNode) {
        guard !activationInProgress else { return }
        activationInProgress = true
        Task {
            defer { activationInProgress = false }
            do {
                try await store.toggleProxyOnly(node)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// 卡片上的默认模型快速切换：保存即生效（激活中节点由 upsert 自动重写 opencode.json）。
    private func selectDefaultModel(_ node: OpenCodeNode, model: String) {
        guard node.models.contains(model), node.defaultModel != model else { return }
        var updated = node
        updated.defaultModel = model
        store.upsert(updated)
    }

    private func testConnectivity(_ node: OpenCodeNode) {
        guard connectivityStates[node.id]?.isTesting != true else { return }
        var state = connectivityStates[node.id] ?? ProxyConnectivityTestState()
        state.isTesting = true
        connectivityStates[node.id] = state
        Task {
            let result = await OpenCodeConnectivityTester.test(node: node)
            connectivityStates[node.id] = result
        }
    }

    /// 复制「不改全局配置即可启动」的命令（OPENCODE_CONFIG 指向导出的独立配置）。
    private func copyLaunchCommand(_ node: OpenCodeNode) {
        do {
            let command = try OpenCodeConfigManager.shared.makeLaunchCommand(
                node: node,
                commonSettings: store.commonSettings(for: node)
            )
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(command, forType: .string)
        } catch {
            actionError = error.localizedDescription
        }
    }

}

#Preview {
    OpenCodeManagementView()
        .frame(width: 900, height: 700)
}
