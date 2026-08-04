import SwiftUI
import Combine

// MARK: - Codex Subscription Order Store
// 持久化 Codex 订阅账号的自定义展示顺序（账号 id 列表，存 UserDefaults）。
// 订阅账号本身由发现/导入生成、无内建排序字段，故单独维护顺序，菜单栏与代理页共用。

@MainActor
final class CodexSubscriptionOrderStore: ObservableObject {
    static let shared = CodexSubscriptionOrderStore()

    @Published private(set) var order: [String]
    private let key = "codexSubscriptionOrder"

    private init() {
        order = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// 按持久顺序排序：已知 id 按存储次序在前；未知（新增）条目保持传入相对序、追加在后。
    func ordered(_ entries: [ProviderAccountEntry]) -> [ProviderAccountEntry] {
        guard !order.isEmpty else { return entries }
        let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        return entries.enumerated().sorted { lhs, rhs in
            switch (rank[lhs.element.id], rank[rhs.element.id]) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// 用「当前展示顺序」整表持久化（手势拖拽结束时一次性提交最终顺序）。
    /// 保留不在当前展示集合中的历史顺序项，避免误丢。
    func reorder(_ displayedIds: [String]) {
        let extra = order.filter { !displayedIds.contains($0) }
        order = displayedIds + extra
        UserDefaults.standard.set(order, forKey: key)
    }
}

// MARK: - Codex Proxy Management View
// 侧边栏「Codex 代理」菜单。复用 ProxyManagementView 的卡片/列表/统计 UI，
// 通过 family = .codex 过滤只展示 Codex 节点，并走 Codex 专用编辑器与独立激活轨道。
//
// 本文件还承载 Codex 专属的统一切换 UI 组件：
//   - CodexSubscriptionSection：列出订阅账号（~/.codex/auth.json），与 API 节点单一互斥激活
//   - CodexGlobalConfigSection：通用配置卡片，入口指向 config.toml 编辑器（见 CodexConfigEditorView.swift）

struct CodexProxyManagementView: View {
    var body: some View {
        ProxyManagementView(family: .codex)
    }
}

// MARK: - Subscription Accounts Section (unified switcher, app side)
// 与「节点配置」并列的订阅账号区。激活订阅账号会通过 ProviderActivationManager 写
// ~/.codex/auth.json，并自动停用正在运行的 Codex 代理节点（互斥），反之亦然。

struct CodexSubscriptionSection: View {
    let entries: [ProviderAccountEntry]
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var activation = ProviderActivationManager.shared
    @ObservedObject private var proxyVM = ProxyViewModel.shared
    @ObservedObject private var globalProxy = GlobalProxyManager.shared
    @ObservedObject private var orderStore = CodexSubscriptionOrderStore.shared
    @Environment(\.colorScheme) private var colorScheme

    // 手势驱动的实时重排状态：仅记录被拖行 id 与跟手位移，行高由 PreferenceKey 测量。
    @State private var draggingId: String?
    @State private var dragTranslation: CGFloat = 0
    @State private var rowHeights: [String: CGFloat] = [:]
    @State private var editingNoteEntry: ProviderAccountEntry?

    private let rowSpacing: CGFloat = 8
    private let fallbackRowHeight: CGFloat = 64
    // 与节点列表的 codexProxy 品牌色一致。
    private static let codexBrand = Color(red: 0.40, green: 0.52, blue: 0.92)

    /// 代理占用 config.toml（每节点代理 或 全局统一代理）时即为生效身份，订阅一律视为未激活
    /// （与菜单栏一致，杜绝双高亮）。全局代理启用时还会禁用激活开关（单独激活被互斥拦截）。
    private var proxyActive: Bool { proxyVM.activatedId(isCodex: true) != nil || globalProxy.isEnabled }

    var body: some View {
        let ordered = orderStore.ordered(entries)
        let ids = ordered.map(\.id)
        let srcIdx = draggingId.flatMap { ids.firstIndex(of: $0) }
        let target = srcIdx.map { computeTarget(ids: ids, srcIdx: $0, translation: dragTranslation) }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProviderIconView("codex", size: 16)
                Text(L("Account List", "账号列表"))
                    .font(.headline.weight(.bold))
                Spacer()
                Text("~/.codex/auth.json")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            LazyVStack(spacing: rowSpacing) {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, entry in
                    let isDragging = draggingId == entry.id
                    subscriptionRow(entry)
                        .background {
                            if draggingId != nil {
                                rowHeightReader(for: entry.id)
                            }
                        }
                        .offset(y: rowOffset(index: index, id: entry.id, srcIdx: srcIdx, target: target))
                        .scaleEffect(isDragging ? 1.02 : 1, anchor: .center)
                        .shadow(color: .black.opacity(isDragging ? 0.22 : 0),
                                radius: isDragging ? 9 : 0, y: isDragging ? 5 : 0)
                        .zIndex(isDragging ? 1 : 0)
                        .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.82), value: target)
                        .animation(.interactiveSpring(response: 0.30, dampingFraction: 0.85), value: draggingId)
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
        .onPreferenceChange(SubscriptionRowHeightKey.self) { heights in
            guard draggingId != nil, rowHeights != heights else { return }
            rowHeights = heights
        }
        .onChange(of: draggingId) { _, id in
            if id == nil, !rowHeights.isEmpty {
                rowHeights.removeAll()
            }
        }
        .sheet(item: $editingNoteEntry) { entry in
            AccountNoteEditorView(
                providerTitle: entry.providerTitle,
                accountLabel: entry.accountPrimaryLabel,
                note: entry.accountNote
            ) { updatedNote in
                appState.updateAccountNote(for: entry, note: updatedNote)
            }
            .environmentObject(appState)
        }
    }

    private func rowHeightReader(for id: String) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: SubscriptionRowHeightKey.self, value: [id: geo.size.height])
        }
    }

    // MARK: - Reorder geometry

    private func stride(of id: String) -> CGFloat {
        (rowHeights[id] ?? fallbackRowHeight) + rowSpacing
    }

    /// 各行在基础布局中的中心 Y（被拖行仍按原槽位计入），用于阈值判断。
    private func baseCenters(ids: [String]) -> [CGFloat] {
        var centers: [CGFloat] = []
        var top: CGFloat = 0
        for id in ids {
            let h = (rowHeights[id] ?? fallbackRowHeight)
            centers.append(top + h / 2)
            top += h + rowSpacing
        }
        return centers
    }

    /// 由跟手位移推出被拖行应落入的目标整表索引（与相邻行中心比较，支持变高行）。
    private func computeTarget(ids: [String], srcIdx: Int, translation: CGFloat) -> Int {
        guard !ids.isEmpty else { return srcIdx }
        let centers = baseCenters(ids: ids)
        let draggedCenter = centers[srcIdx] + translation
        var t = srcIdx
        while t < ids.count - 1 && draggedCenter > centers[t + 1] { t += 1 }
        while t > 0 && draggedCenter < centers[t - 1] { t -= 1 }
        return t
    }

    /// 单行的 y 位移：被拖行跟手；其余行按「让位」规则平移一个被拖行步幅。
    private func rowOffset(index: Int, id: String, srcIdx: Int?, target: Int?) -> CGFloat {
        if id == draggingId { return dragTranslation }
        guard let srcIdx, let target, let dragId = draggingId else { return 0 }
        let step = stride(of: dragId)
        if target > srcIdx, index > srcIdx, index <= target { return -step }
        if target < srcIdx, index >= target, index < srcIdx { return step }
        return 0
    }

    private func dragGesture(for entry: ProviderAccountEntry) -> some Gesture {
        // 用 .global 坐标系测位移：被拖行自身在做 offset，若用 .local 会随行移动产生反馈抖动。
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if draggingId != entry.id { draggingId = entry.id }
                dragTranslation = value.translation.height
            }
            .onEnded { _ in commitDrag() }
    }

    private func commitDrag() {
        defer {
            // onEnded 一定触发，故拖拽态必被复位 —— 杜绝旧实现「松手卡黑」。
            draggingId = nil
            dragTranslation = 0
        }
        guard let id = draggingId else { return }
        let ids = orderStore.ordered(entries).map(\.id)
        guard let srcIdx = ids.firstIndex(of: id) else { return }
        let target = computeTarget(ids: ids, srcIdx: srcIdx, translation: dragTranslation)
        guard target != srcIdx else { return }
        var newOrder = ids
        newOrder.remove(at: srcIdx)
        newOrder.insert(id, at: min(max(target, 0), newOrder.count))
        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.85)) {
            orderStore.reorder(newOrder)
        }
    }

    // 色彩 plan 标签（对齐服务商卡片样式）：Free/Plus/Pro/Business/Enterprise 用统一色板。
    @ViewBuilder
    private func planBadge(_ label: String) -> some View {
        let tint = membershipBadgeTint(for: label)
        Text(label)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay(Capsule().stroke(tint.opacity(0.30), lineWidth: 1))
    }

    // 可编辑备注栏：标题已展示邮箱、徽标展示 plan，这里只放用户自定义备注（点击编辑）。
    private func noteRow(_ entry: ProviderAccountEntry) -> some View {
        Button {
            editingNoteEntry = entry
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "pencil")
                    .font(.system(size: 9))
                if let note = entry.accountNote?.nilIfBlank {
                    Text(note)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(L("Add note", "添加备注"))
                        .italic()
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Edit note", "编辑备注"))
    }

    // 订阅账号的配额/用量监控（与「服务商」页同源）：订阅走 OAuth 直连，拿不到代理请求日志，
    // 故改用 ChatGPT 用量窗口（5h / Weekly / Code Review 的剩余百分比 + 重置信息）作为监控指标。
    @ViewBuilder
    private func usageWindowPills(_ entry: ProviderAccountEntry) -> some View {
        let windows = entry.liveProvider?.windows ?? []
        if !windows.isEmpty {
            HStack(spacing: 6) {
                ForEach(windows.prefix(3)) { usagePill($0) }
            }
            .padding(.top, 1)
        }
    }

    private func usagePill(_ window: QuotaWindow) -> some View {
        let shortLabel = window.label.replacingOccurrences(of: " Window", with: "")
        let remaining = window.remainingPercent
        let tint: Color = {
            guard let remaining else { return .secondary }
            if remaining > 50 { return .green }
            if remaining > 20 { return .orange }
            return .red
        }()
        return HStack(spacing: 3) {
            Text(shortLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            if let remaining {
                Text("\(Int(remaining.rounded()))%")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
            } else {
                Image(systemName: "infinity")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
        .help("\(window.label): \(window.value) · \(window.note)")
    }

    @ViewBuilder
    private func subscriptionRow(_ entry: ProviderAccountEntry) -> some View {
        let isActive = !proxyActive && activation.isActiveAccount(entry)
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(draggingId == entry.id ? .primary : .tertiary)
                .frame(width: 22, height: 30)
                .contentShape(Rectangle())
                .help(L("Drag to reorder", "拖动可排序"))
                .onHover { hovering in
                    if hovering { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                .gesture(dragGesture(for: entry))

            ProviderIconView("codex", size: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.accountPrimaryLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let plan = entry.liveProvider?.membershipLabel?.nilIfBlank {
                        planBadge(plan)
                    }
                }
                noteRow(entry)
                usageWindowPills(entry)
            }

            Spacer(minLength: 8)

            // 与节点列表统一的激活开关：开=激活该账号（互斥切换），关=停用（清除激活标记）。
            // 全局代理启用时单独激活被互斥拦截，开关禁用并提示去全局代理面板切换。
            Toggle("", isOn: Binding(
                get: { isActive },
                set: { newValue in
                    if newValue {
                        try? activation.activateAccount(entry: entry)
                    } else {
                        activation.deactivateAccount(entry: entry)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(ProxyActivationToggleStyle(brandColor: Self.codexBrand, isBusy: false))
            .disabled(globalProxy.isEnabled)
            .help(globalProxy.isEnabled
                  ? L("Global proxy is enabled; switch the active node in the global proxy card.",
                      "全局代理已启用，请在全局代理卡片切换激活节点。")
                  : "")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isActive ? Self.codexBrand.opacity(0.12) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isActive ? Self.codexBrand.opacity(0.50) : Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Subscription Row Height Key
// 测量每个订阅行真实高度（含可选用量 pill 行），供变高行的拖拽阈值/让位步幅计算。

private struct SubscriptionRowHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Codex Global Config Section
// 通用配置基底片段（CodexGlobalConfig）—— 激活节点/订阅时按顶层键合并写入 config.toml，
// 节点 extraTOML 优先级更高；带 Merge 开关，可编辑原文 TOML（高亮 + 轻量检查）。
// 实时 ~/.codex/config.toml 文件入口统一放在 ProxyManagementView 顶部工具栏。

struct CodexGlobalConfigSection: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var store = NodeProfileStore.shared
    @State private var showingFragmentEditor = false

    private var fragment: CodexGlobalConfig { store.codexGlobalConfig }
    private var keyCount: Int { CodexGlobalConfig.topLevelEntryCount(in: fragment.tomlText) }

    var body: some View {
        fragmentCard
        .sheet(isPresented: $showingFragmentEditor) {
            CodexGlobalConfigEditorView(store: store)
        }
    }

    // 通用配置基底片段卡片（Merge 开关 + 编辑原文 TOML）
    private var fragmentCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 14))
                .foregroundStyle(.indigo)

            VStack(alignment: .leading, spacing: 2) {
                Text(L("Common Config", "通用配置"))
                    .font(.subheadline.weight(.semibold))
                Text(keyCount > 0
                     ? L("\(keyCount) top-level entries · merged on activation", "\(keyCount) 个顶层条目 · 激活时合并")
                     : L("Not configured", "未配置"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showingFragmentEditor = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 10, weight: .semibold))
                    Text(L("Edit", "编辑"))
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)

            Toggle(isOn: Binding(
                get: { store.codexGlobalConfig.enabled },
                set: { newValue in
                    store.codexGlobalConfig.enabled = newValue
                    store.saveCodexGlobalConfig()
                }
            )) {
                Text(L("Merge", "合并"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
    }
}

#Preview {
    CodexProxyManagementView()
        .environmentObject(AppState.shared)
        .environmentObject(ProxyViewModel())
        .frame(width: 1100, height: 700)
}
