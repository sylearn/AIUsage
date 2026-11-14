import SwiftUI

// MARK: - API Provider List
// 「服务商 → API 提供商」分类下的列表：新增/编辑统一上游配置，并分发到 Codex / Claude / OpenCode / CPA。
// 操作反馈：行内按钮即时态 + 顶部轻横幅。

struct APIProviderListView: View {
    var searchText: String = ""
    /// 顶部工具栏「新增」触发信号：置 true 即打开新建编辑器（由本视图复位）。
    @Binding var requestNew: Bool
    var onClearSearch: (() -> Void)?

    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = APIProviderStore.shared
    @ObservedObject private var profileStore = NodeProfileStore.shared
    @ObservedObject private var openCodeStore = OpenCodeNodeStore.shared
    @ObservedObject private var cpaLinks = APIProviderCPALinkStore.shared
    @ObservedObject private var gatewayNavigation = CLIProxyGatewayNavigation.shared

    @State private var editorContext: EditorContext?
    @State private var deletingProvider: APIProvider?
    @State private var flash: AppFlash?
    @State private var syncPhases: [String: APIProviderCard.SyncPhase] = [:]
    @State private var listFilter: APIProviderListFilter = .all

    // 手势驱动的「拖拽实时让位」重排状态（与三套代理节点列表同一套手感）。
    @State private var draggingId: String?
    @State private var dragTranslation: CGFloat = 0
    @State private var rowHeights: [String: CGFloat] = [:]

    private var distributor: APIProviderDistributor { APIProviderDistributor.shared }

    private enum APIProviderListFilter: String, CaseIterable, Identifiable {
        case all
        case distributed
        case idle

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return L("All", "全部")
            case .distributed: return L("Distributed", "已分发")
            case .idle: return L("Not distributed", "未分发")
            }
        }
    }

    private struct EditorContext: Identifiable {
        let id: String
        let provider: APIProvider
        let initialTargets: Set<ProxyTarget>
    }

    private var searchedProviders: [APIProvider] {
        guard !searchText.isEmpty else { return store.providers }
        return store.providers.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.baseURL.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredProviders: [APIProvider] {
        searchedProviders.filter { provider in
            let isDistributed = !distributor.currentTargets(for: provider.id).isEmpty
            switch listFilter {
            case .all: return true
            case .distributed: return isDistributed
            case .idle: return !isDistributed
            }
        }
    }

    private var distributedCount: Int {
        store.providers.filter { !distributor.currentTargets(for: $0.id).isEmpty }.count
    }

    private var idleCount: Int {
        store.providers.count - distributedCount
    }

    var body: some View {
        content
        .appFlashOverlay(flash)
        .modelSyncFlashOverlay()
        .onChange(of: requestNew) { _, newValue in
            guard newValue else { return }
            editorContext = EditorContext(id: "new", provider: APIProvider(), initialTargets: [])
            requestNew = false
        }
        .sheet(item: $editorContext) { ctx in
            APIProviderEditorView(provider: ctx.provider, initialTargets: ctx.initialTargets) { provider, targets in
                let saved = store.upsert(provider)
                Task {
                    let error = await distributor.setDistribution(saved, targets: targets)
                    if let error {
                        showFlash(.error(error))
                    } else if targets.isEmpty {
                        showFlash(.success(L("Provider saved", "已保存提供商")))
                    } else {
                        showFlash(.success(L("Saved and distributed", "已保存并分发")))
                    }
                }
            }
        }
        .confirmationDialog(
            L("Delete API Provider", "删除 API 提供商"),
            isPresented: Binding(get: { deletingProvider != nil }, set: { if !$0 { deletingProvider = nil } }),
            presenting: deletingProvider
        ) { provider in
            Button(L("Delete linked nodes too", "一并删除链接节点"), role: .destructive) {
                deleteProvider(provider, deleteChildren: true)
            }
            Button(L("Unlink, keep nodes", "解除链接，保留节点")) {
                deleteProvider(provider, deleteChildren: false)
            }
            Button(L("Cancel", "取消"), role: .cancel) {}
        } message: { provider in
            Text(L(
                "\"\(provider.displayName)\" is distributed to its linked proxy nodes. Choose how to handle them.",
                "「\(provider.displayName)」已分发到代理的链接节点，请选择如何处理它们。"
            ))
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.providers.isEmpty {
            emptyState
        } else if searchedProviders.isEmpty {
            searchEmptyState
        } else if filteredProviders.isEmpty {
            filterEmptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    overviewRow
                    providerList
                }
                .padding(18)
            }
        }
    }

    private var overviewRow: some View {
        GatewayStatCapsuleRow(
            items: [
                .init(
                    id: "all",
                    value: "\(store.providers.count)",
                    title: L("providers", "提供商"),
                    systemImage: "shippingbox.fill",
                    tint: .indigo
                ),
                .init(
                    id: "distributed",
                    value: "\(distributedCount)",
                    title: L("distributed", "已分发"),
                    systemImage: "arrow.triangle.branch",
                    tint: .green
                ),
                .init(
                    id: "idle",
                    value: "\(idleCount)",
                    title: L("idle", "未分发"),
                    systemImage: "circle.dashed",
                    tint: .secondary
                ),
            ],
            selectedId: listFilter.rawValue,
            onSelect: { id in
                if let next = APIProviderListFilter(rawValue: id) {
                    withAnimation(.easeInOut(duration: 0.15)) { listFilter = next }
                }
            }
        )
    }

    private var searchEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(L("No matching providers", "没有匹配的提供商"))
                .font(.title3.weight(.semibold))
            Text(L("Try a different keyword, or clear the search.", "试试其他关键词，或清除搜索。"))
                .font(.body)
                .foregroundStyle(.secondary)
            if let onClearSearch {
                Button(L("Clear Search", "清除搜索"), action: onClearSearch)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var filterEmptyState: some View {
        VStack(spacing: 14) {
            overviewRow
                .padding(.horizontal, 18)
                .padding(.top, 18)
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(L("Nothing in this filter", "此筛选下没有条目"))
                .font(.title3.weight(.semibold))
            Button(L("Show all", "显示全部")) {
                listFilter = .all
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 条目列表 + 跟手让位拖拽重排。搜索过滤时禁用拖拽（避免对部分列表整表重写顺序）。
    private var providerList: some View {
        let reorderEnabled = searchText.isEmpty
        let ids = filteredProviders.map(\.id)
        let srcIdx = draggingId.flatMap { id in ids.firstIndex(of: id) }
        let target = srcIdx.map { dragTarget(ids: ids, srcIdx: $0) }
        return LazyVStack(spacing: 0) {
            ForEach(Array(filteredProviders.enumerated()), id: \.element.id) { index, provider in
                let isDragging = draggingId == provider.id
                providerRow(provider, reorderEnabled: reorderEnabled)
                    .offset(y: reorderEnabled ? rowOffset(index: index, id: provider.id, srcIdx: srcIdx, target: target) : 0)
                    .scaleEffect(isDragging ? 1.02 : 1, anchor: .center)
                    .shadow(color: .black.opacity(isDragging ? 0.22 : 0),
                            radius: isDragging ? 9 : 0, y: isDragging ? 5 : 0)
                    .zIndex(isDragging ? 1 : 0)
                    .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.82), value: target)
                    .animation(.interactiveSpring(response: 0.30, dampingFraction: 0.85), value: draggingId)
            }
        }
        .onPreferenceChange(APIProviderRowHeightKey.self) { heights in
            guard draggingId != nil, rowHeights != heights else { return }
            rowHeights = heights
        }
        .onChange(of: draggingId) { _, id in
            if id == nil, !rowHeights.isEmpty { rowHeights.removeAll() }
        }
    }

    @ViewBuilder
    private func providerRow(_ provider: APIProvider, reorderEnabled: Bool) -> some View {
        APIProviderCard(
            provider: provider,
            distributedTargets: distributor.currentTargets(for: provider.id),
            syncPhase: syncPhases[provider.id] ?? .idle,
            onDragChanged: { translation in
                guard reorderEnabled else { return }
                if draggingId != provider.id { draggingId = provider.id }
                dragTranslation = translation
            },
            onDragEnded: {
                if reorderEnabled {
                    commitDrag()
                } else {
                    draggingId = nil
                    dragTranslation = 0
                }
            },
            onEdit: {
                editorContext = EditorContext(
                    id: provider.id,
                    provider: provider,
                    initialTargets: distributor.currentTargets(for: provider.id)
                )
            },
            onSync: {
                syncProvider(provider)
            },
            onDuplicate: {
                duplicateProvider(provider)
            },
            onDelete: {
                if distributor.currentTargets(for: provider.id).isEmpty {
                    store.delete(id: provider.id)
                    showFlash(.success(L("Provider deleted", "已删除提供商")))
                } else {
                    deletingProvider = provider
                }
            },
            onCopied: { message in
                showFlash(.info(message))
            },
            onOpenTarget: { target in
                openDistributedTarget(target)
            }
        )
        .background {
            if draggingId != nil { rowHeightReader(for: provider.id) }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Drag Reorder Helpers

    private static let rowSpacing: CGFloat = 8
    private static let fallbackHeight: CGFloat = 84

    private func rowHeightReader(for id: String) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: APIProviderRowHeightKey.self, value: [id: geo.size.height])
        }
    }

    private func rowStride(_ id: String) -> CGFloat {
        (rowHeights[id] ?? Self.fallbackHeight) + Self.rowSpacing
    }

    private func rowBaseCenters(_ ids: [String]) -> [CGFloat] {
        var centers: [CGFloat] = []
        var top: CGFloat = 0
        for id in ids {
            let height = rowHeights[id] ?? Self.fallbackHeight
            centers.append(top + height / 2)
            top += height + Self.rowSpacing
        }
        return centers
    }

    private func dragTarget(ids: [String], srcIdx: Int) -> Int {
        guard !ids.isEmpty, srcIdx < ids.count else { return srcIdx }
        let centers = rowBaseCenters(ids)
        let draggedCenter = centers[srcIdx] + dragTranslation
        var target = srcIdx
        while target < ids.count - 1 && draggedCenter > centers[target + 1] { target += 1 }
        while target > 0 && draggedCenter < centers[target - 1] { target -= 1 }
        return target
    }

    private func rowOffset(index: Int, id: String, srcIdx: Int?, target: Int?) -> CGFloat {
        if id == draggingId { return dragTranslation }
        guard let srcIdx, let target, let dragId = draggingId else { return 0 }
        let step = rowStride(dragId)
        if target > srcIdx, index > srcIdx, index <= target { return -step }
        if target < srcIdx, index >= target, index < srcIdx { return step }
        return 0
    }

    private func commitDrag() {
        let ids = store.providers.map(\.id)
        defer {
            draggingId = nil
            dragTranslation = 0
        }
        guard let id = draggingId, let srcIdx = ids.firstIndex(of: id) else { return }
        let target = dragTarget(ids: ids, srcIdx: srcIdx)
        guard target != srcIdx else { return }
        var reordered = ids
        reordered.remove(at: srcIdx)
        reordered.insert(id, at: target)
        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.85)) {
            store.applyOrder(ids: reordered)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(L("No API providers yet", "还没有 API 提供商"))
                .font(.title3.weight(.semibold))
            Text(L(
                "Create one unified upstream config and distribute it to Codex / Claude / OpenCode / CPA at once.",
                "创建一份统一的上游配置，一键分发到 Codex / Claude / OpenCode / CPA。"
            ))
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 480)
            Button {
                editorContext = EditorContext(id: "new", provider: APIProvider(), initialTargets: [])
            } label: {
                ProviderActionLabel(
                    title: L("New API Provider", "新增 API 提供商"),
                    systemImage: "plus",
                    style: .primary,
                    minWidth: 120
                )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Actions

    private func syncProvider(_ provider: APIProvider) {
        guard syncPhases[provider.id] != .syncing else { return }
        store.markUsed(id: provider.id)
        syncPhases[provider.id] = .syncing
        showFlash(.info(L("Syncing “\(provider.displayName)”…", "正在同步「\(provider.displayName)」…")))
        Task {
            let error = await distributor.syncFromMaster(provider)
            if let error {
                syncPhases[provider.id] = .failure
                showFlash(.error(error))
            } else {
                syncPhases[provider.id] = .success
                showFlash(.success(L("Synced “\(provider.displayName)”", "已同步「\(provider.displayName)」")))
            }
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if syncPhases[provider.id] != .syncing {
                syncPhases[provider.id] = .idle
            }
        }
    }

    private func duplicateProvider(_ provider: APIProvider) {
        var copy = provider
        copy.id = UUID().uuidString
        copy.name = provider.name.isEmpty
            ? L("Copy", "副本")
            : L("\(provider.name) copy", "\(provider.name) 副本")
        copy.createdAt = Date()
        copy.lastUsedAt = nil
        copy.sortOrder = Int.max
        let saved = store.upsert(copy)
        showFlash(.success(L("Duplicate created — review and save", "已创建副本，请确认后保存")))
        editorContext = EditorContext(id: saved.id, provider: saved, initialTargets: [])
    }

    private func deleteProvider(_ provider: APIProvider, deleteChildren: Bool) {
        Task {
            await distributor.handleProviderDeletion(provider, deleteChildren: deleteChildren)
            store.delete(id: provider.id)
            syncPhases[provider.id] = nil
            showFlash(.success(
                deleteChildren
                    ? L("Provider and linked nodes deleted", "已删除提供商及链接节点")
                    : L("Provider deleted; linked nodes kept", "已删除提供商，链接节点已保留")
            ))
        }
    }

    private func openDistributedTarget(_ target: ProxyTarget) {
        switch target {
        case .codex:
            appState.selectedSection = .codexProxyManagement
        case .claude:
            appState.selectedSection = .proxyManagement
        case .openCode:
            appState.selectedSection = .opencodeManagement
        case .cpa:
            appState.selectedSection = .subscriptionGateway
            gatewayNavigation.showAccounts()
        }
    }

    private func showFlash(_ flash: AppFlash) {
        AppFlashPresenter.present(flash, into: $flash)
    }
}
