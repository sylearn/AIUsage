import Combine
import QuotaBackend
import SwiftUI

// MARK: - Session Center
// 主窗口「会话」页：左侧会话列表（搜索 / 工具筛选 / 分组），右侧阅读视图与大纲。
// 状态见 SessionCenterStore；设计文档 docs/SESSION_CENTER_DESIGN.md §5。
// 页面可见期间实时更新（文件监听），另有 30 秒定时扫描兜底：进程退出、「进行中」过期不一定伴随文件变化。

struct SessionCenterView: View {
    @ObservedObject private var store = SessionCenterStore.shared
    @Environment(\.colorScheme) private var colorScheme

    private let autoRefresh = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            SessionListColumn(store: store)
                .frame(width: 340)
                .background(AppSurface.sidebar(colorScheme))
            Divider()
            Group {
                if let session = store.selectedSession {
                    SessionReaderView(store: store, session: session)
                        .id(session.id)
                } else {
                    SessionPlaceholder(isEmpty: store.hasScanned && store.sessions.isEmpty, count: store.sessions.count)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .appPageBackground(colorScheme)
        .appFlashOverlay(store.flash)
        .onAppear { store.beginObserving() }
        .onDisappear { store.endObserving() }
        .task { await store.refresh() }
        .onReceive(autoRefresh) { _ in Task { await store.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refresh() }
        }
    }
}

// MARK: - List column

private struct SessionListColumn: View {
    @ObservedObject var store: SessionCenterStore
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    @State private var confirmingFullText = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            list
            footer
        }
        .background(alignment: .topLeading) {
            // ⌘F 聚焦搜索框（与系统「查找」习惯一致）。
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .alert(L("Search replies and tool calls too?", "也搜索回复和工具调用？", key: "sessions.full_text.confirm_title"),
               isPresented: $confirmingFullText) {
            Button(L("Turn On", "开启", key: "sessions.full_text.turn_on")) { store.setFullTextSearch(true) }
            Button(L("Cancel", "取消", key: "sessions.resume_active.cancel"), role: .cancel) {}
        } message: {
            Text(L("AIUsage builds an index of session text in ~/Library/Caches/AIUsage. It stays on this Mac, is never uploaded, and is deleted when you turn this off.",
                   "AIUsage 会在本机缓存目录（~/Library/Caches/AIUsage）为会话正文建一份索引。索引只留在这台 Mac 上，不上传；关闭全文搜索时一并删除。",
                   key: "sessions.full_text.confirm_message"))
        }
    }

    private var fullTextBinding: Binding<Bool> {
        Binding(
            get: { store.isFullTextEnabled },
            set: { enabled in
                if enabled {
                    confirmingFullText = true
                } else {
                    store.setFullTextSearch(false)
                }
            }
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Sessions", "会话", key: "nav.sessions"))
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                if store.isRescanning {
                    ProgressView().controlSize(.small)
                }
                Menu {
                    Button(L("Rescan Local Sessions", "重新扫描本机会话", key: "sessions.refresh")) {
                        Task { await store.rescan() }
                    }
                    Divider()
                    Toggle(L("Search Replies and Tool Calls", "搜索回复和工具调用", key: "sessions.full_text.toggle"),
                           isOn: fullTextBinding)
                    if let size = store.indexFileSize {
                        Text(L("Index uses \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))",
                               "索引占用 \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"))
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(SessionIconButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("More", "更多", key: "sessions.action.more"))
            }
            searchField
            if store.isSearching {
                searchScope
            }
            toolFilter
            HStack(spacing: 14) {
                ForEach(SessionCenterStore.Grouping.allCases, id: \.self) { grouping in
                    Button {
                        store.grouping = grouping
                    } label: {
                        Text(grouping == .time
                             ? L("By time", "按时间", key: "sessions.group_by.time")
                             : L("By project", "按项目", key: "sessions.group_by.project"))
                            .font(.system(size: 12, weight: store.grouping == grouping ? .semibold : .regular))
                            .foregroundStyle(store.grouping == grouping
                                             ? AppContent.primary(colorScheme) : AppContent.secondary(colorScheme))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text(L("\(store.filteredSessions.count) shown", "\(store.filteredSessions.count) 个"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppContent.tertiary(colorScheme))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppContent.tertiary(colorScheme))
            TextField(L("Title, folder, branch or prompt", "搜索标题、目录、分支或提问", key: "sessions.search.placeholder"),
                      text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onExitCommand { store.query = "" }
            if !store.query.isEmpty {
                Button {
                    store.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppContent.tertiary(colorScheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Clear search", "清除搜索", key: "sessions.search.clear"))
            } else {
                Text("⌘F")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppContent.tertiary(colorScheme))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppStroke.subtle(colorScheme)))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(AppSurface.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(searchFocused ? AppAccent.control(colorScheme).opacity(0.6) : AppStroke.subtle(colorScheme)))
    }

    /// 搜索时说明搜了哪些内容：没开全文搜索时给开启入口，首次建索引时显示进度。
    @ViewBuilder
    private var searchScope: some View {
        switch store.indexState {
        case .off:
            HStack(spacing: 4) {
                Text(L("Titles, folders and prompts only.", "只搜了标题、目录和提问。", key: "sessions.search.scope_basic"))
                    .foregroundStyle(AppContent.tertiary(colorScheme))
                Button(L("Include replies", "也搜回复", key: "sessions.search.include_replies")) {
                    confirmingFullText = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppAccent.control(colorScheme))
            }
            .font(.system(size: 11.5))
            .lineLimit(1)
        case .building(let done, let total):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(total > 0
                     ? L("Indexing \(done)/\(total) sessions; results may be incomplete",
                         "正在建立全文索引 \(done)/\(total)，结果可能不全")
                     : L("Preparing the full-text index…", "正在准备全文索引…", key: "sessions.search.index_preparing"))
                    .monospacedDigit()
            }
            .font(.system(size: 11.5))
            .foregroundStyle(AppContent.tertiary(colorScheme))
            .lineLimit(1)
        case .ready:
            EmptyView()
        }
    }

    private var toolFilter: some View {
        SessionSegmentRow(spacing: 2) {
            filterButton(nil, title: L("All", "全部", key: "sessions.filter.all"))
            ForEach(SessionTool.allCases) { tool in
                filterButton(tool, title: tool == .claude ? "Claude" : tool.displayName)
            }
        }
        .padding(3)
        .background(AppSurface.chip(colorScheme), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func filterButton(_ tool: SessionTool?, title: String) -> some View {
        let selected = store.toolFilter == tool
        return Button {
            store.toolFilter = tool
        } label: {
            HStack(spacing: 5) {
                if let tool {
                    ProviderIconView(tool.rawValue, size: 12)
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? AppContent.primary(colorScheme) : AppContent.secondary(colorScheme))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(AppSurface.elevated(colorScheme))
                        .shadow(color: AppShadow.card(colorScheme), radius: 2, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L(SessionPlural.en(store.count(for: tool), "session"), "\(store.count(for: tool)) 个会话"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var list: some View {
        if !store.hasScanned {
            VStack(spacing: 10) {
                ProgressView()
                Text(L("Reading local sessions…", "正在读取本机会话…", key: "sessions.loading"))
                    .font(.system(size: 12))
                    .foregroundStyle(AppContent.secondary(colorScheme))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.filteredSessions.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: store.sessions.isEmpty ? "tray" : "magnifyingglass")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(AppContent.tertiary(colorScheme))
                    .padding(.bottom, 2)
                Text(store.sessions.isEmpty
                     ? L("No sessions yet", "还没有会话记录", key: "sessions.empty.title")
                     : L("No matching sessions", "没有匹配的会话", key: "sessions.empty.filtered"))
                    .font(.system(size: 13, weight: .semibold))
                Text(store.sessions.isEmpty
                     ? L("Sessions from Claude Code, Codex and OpenCode on this Mac appear here.",
                         "本机 Claude Code、Codex、OpenCode 的会话会出现在这里。", key: "sessions.empty.hint")
                     : L("Try another keyword or switch back to All.", "换个关键词，或者切回「全部」。",
                         key: "sessions.empty.filtered_hint"))
                    .font(.system(size: 12))
                    .foregroundStyle(AppContent.secondary(colorScheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if !store.sessions.isEmpty {
                    // 直接给出能走通的下一步，不用用户自己找入口。
                    HStack(spacing: 8) {
                        if store.toolFilter != nil {
                            Button(L("Show All Tools", "显示全部工具", key: "sessions.empty.show_all")) { store.toolFilter = nil }
                        }
                        if store.isSearching, store.indexState == .off {
                            Button(L("Include replies", "也搜回复", key: "sessions.search.include_replies")) { confirmingFullText = true }
                        }
                        if store.isSearching {
                            Button(L("Clear Search", "清除搜索", key: "sessions.empty.clear_search")) { store.query = "" }
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 自绘列表：选中与悬停用 AppSurface 色阶，键盘 ↑↓ 选择、↩ 继续（系统 List 的失焦选中色与本应用风格不一致）。
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(store.groups) { group in
                            Section {
                                ForEach(group.sessions) { session in
                                    SessionRow(store: store, session: session, isSelected: store.selectedID == session.id,
                                               excerpt: store.excerpt(for: session), terms: store.highlightTerms,
                                               showsProject: store.grouping != .project)
                                        .id(session.id)
                                        .onTapGesture {
                                            listFocused = true
                                            store.select(session.id)
                                        }
                                }
                            } header: {
                                groupHeader(group)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($listFocused)
                .onKeyPress(.upArrow) { store.selectAdjacent(-1); return .handled }
                .onKeyPress(.downArrow) { store.selectAdjacent(1); return .handled }
                .onKeyPress(.return) {
                    guard let session = store.selectedSession else { return .ignored }
                    Task { await store.resume(session) }
                    return .handled
                }
                .onChange(of: store.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func groupHeader(_ group: SessionGroup) -> some View {
        HStack {
            Text(group.title)
            Spacer()
            Text("\(group.sessions.count)").monospacedDigit()
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(AppContent.secondary(colorScheme))
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .background(AppSurface.sidebar(colorScheme))
    }

    /// 底栏一行：左边隐私说明（悬停看完整说明），右边快捷键；放不下时只留隐私说明。
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            footerRow(showsKeys: true)
            footerRow(showsKeys: false)
        }
        .font(.system(size: 11))
        .foregroundStyle(AppContent.tertiary(colorScheme))
        .padding(.horizontal, 16)
        .frame(height: 34)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }

    private func footerRow(showsKeys: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text(L("Read-only · local", "只读 · 不上传", key: "sessions.footer.privacy_short"))
                    .lineLimit(1)
                    .fixedSize()
            }
            .help(L("Read-only. Nothing is uploaded or modified.", "只读本机记录，不上传，不修改原文件",
                    key: "sessions.footer.privacy"))
            Spacer(minLength: 0)
            if showsKeys {
                SessionKeyHint(keys: "↑↓", label: L("select", "选择", key: "sessions.footer.select"))
                SessionKeyHint(keys: "↩", label: L("resume", "继续", key: "sessions.footer.resume"))
            }
        }
    }
}

// MARK: - Row

private struct SessionRow: View {
    @ObservedObject var store: SessionCenterStore
    let session: SessionSummary
    let isSelected: Bool
    let excerpt: SessionExcerpt?
    let terms: [String]
    /// 按项目分组时组标题已经是项目名，行里不再重复。
    var showsProject = true
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProviderIconView(session.tool.rawValue, size: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppContent.primary(colorScheme))
                    .lineLimit(2)
                if (showsProject && session.projectName != nil) || session.gitBranch != nil {
                    HStack(spacing: 5) {
                        if showsProject, let project = session.projectName {
                            Text(project)
                                .foregroundStyle(AppContent.secondary(colorScheme))
                        }
                        if let branch = session.gitBranch {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text(branch)
                                .font(.system(size: 11, design: .monospaced))
                                .truncationMode(.middle)
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppContent.tertiary(colorScheme))
                    .lineLimit(1)
                }
                HStack(spacing: 4) {
                    if let activity = session.activity {
                        SessionActivityLabel(activity: activity, tool: session.tool)
                            .fontWeight(.medium)
                            .foregroundStyle(SessionActivityDot.tint(activity, colorScheme))
                        Text("·")
                    }
                    Text(SessionDateText.short(session.updatedAt))
                    if let prompts = session.promptCount {
                        Text("·")
                        Text(L(SessionPlural.en(prompts, "prompt"), "\(prompts) 轮"))
                    }
                    if session.resumeBlocker != nil {
                        Image(systemName: "exclamationmark.circle")
                            .help(SessionReaderView.blockerText(session.resumeBlocker))
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(AppContent.tertiary(colorScheme))
                .monospacedDigit()
                .lineLimit(1)
                if let excerpt {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: SessionHighlight.symbol(for: excerpt.kind))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(AppContent.tertiary(colorScheme))
                        Text(SessionHighlight.attributed(excerpt.text, terms: terms, scheme: colorScheme))
                            .font(.system(size: 11.5))
                            .foregroundStyle(AppContent.secondary(colorScheme))
                            .lineLimit(2)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            if (hovering || isSelected), session.resumeBlocker == nil {
                Button {
                    Task { await store.resume(session) }
                } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AppContent.secondary(colorScheme))
                        .frame(width: 26, height: 26)
                        .background(AppSurface.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(AppStroke.subtle(colorScheme)))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
                .help(L("Resume in \(store.terminal.displayName)", "在 \(store.terminal.displayName) 中继续"))
                .accessibilityLabel(L("Resume in \(store.terminal.displayName)", "在 \(store.terminal.displayName) 中继续"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? AppSurface.selection(colorScheme) : hovering ? AppSurface.row(colorScheme) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .contextMenu { SessionActionsMenu(store: store, session: session) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 列表右键菜单与阅读视图「更多」菜单共用。
struct SessionActionsMenu: View {
    @ObservedObject var store: SessionCenterStore
    let session: SessionSummary

    var body: some View {
        Button(L("Resume in \(store.terminal.displayName)", "在 \(store.terminal.displayName) 中继续")) {
            Task { await store.resume(session) }
        }
        .disabled(session.resumeBlocker != nil)
        Button(L("Copy Resume Command", "复制恢复命令", key: "sessions.action.copy_command")) {
            store.copyCommand(session)
        }
        .disabled(session.resumeBlocker == .directoryMissing)
        Button(L("Copy Session ID", "复制会话 ID", key: "sessions.action.copy_id")) {
            store.copySessionID(session)
        }
        Divider()
        Button(L("Show Project in Finder", "在 Finder 中显示项目", key: "sessions.action.reveal")) {
            store.revealInFinder(session)
        }
        Button(L("Export as Markdown…", "导出为 Markdown…", key: "sessions.action.export")) {
            Task { await store.exportMarkdown(session) }
        }
        .disabled(!session.hasTranscript)
    }
}

// MARK: - Placeholder

private struct SessionPlaceholder: View {
    let isEmpty: Bool
    let count: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(AppContent.tertiary(colorScheme))
            Text(isEmpty
                 ? L("No local sessions found", "没有找到本机会话", key: "sessions.placeholder.empty")
                 : L("Select a session", "选择一个会话", key: "sessions.placeholder.select"))
                .font(.system(size: 15, weight: .semibold))
            if !isEmpty {
                Text(L(SessionPlural.en(count, "session") + " on this Mac", "本机共 \(count) 个会话"))
                    .font(.system(size: 12))
                    .foregroundStyle(AppContent.secondary(colorScheme))
                    .monospacedDigit()
                HStack(spacing: 14) {
                    SessionKeyHint(keys: "⌘F", label: L("search", "搜索", key: "sessions.placeholder.search"))
                    SessionKeyHint(keys: "↑↓", label: L("select", "选择", key: "sessions.footer.select"))
                    SessionKeyHint(keys: "↩", label: L("resume", "继续", key: "sessions.footer.resume"))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(AppContent.tertiary(colorScheme))
                .padding(.top, 6)
            }
            if isEmpty {
                Text(L("Claude Code keeps sessions for 30 days by default (cleanupPeriodDays in settings.json).",
                       "Claude Code 默认只保留 30 天会话（settings.json 的 cleanupPeriodDays 可调）。",
                       key: "sessions.placeholder.retention"))
                    .font(.system(size: 12))
                    .foregroundStyle(AppContent.secondary(colorScheme))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .padding(32)
    }
}

// MARK: - Small pieces

/// 键帽样式的快捷键提示。
struct SessionKeyHint: View {
    let keys: String
    let label: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .frame(minWidth: 17, minHeight: 16)
                .background(AppSurface.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(AppStroke.subtle(colorScheme)))
            Text(label)
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// 分段控件的排布：每段先拿到自己需要的宽度，剩下的平均分；空间不够时按比例压缩（文字截断），不会挤出边界。
struct SessionSegmentRow: Layout {
    var spacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        let total = ideals.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: proposal.width ?? total, height: ideals.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        guard !subviews.isEmpty else { return }
        let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let sum = ideals.reduce(0, +)
        let available = bounds.width - spacing * CGFloat(subviews.count - 1)
        let widths = available >= sum
            ? ideals.map { $0 + (available - sum) / CGFloat(ideals.count) }
            : ideals.map { $0 * available / max(sum, 1) }
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}
