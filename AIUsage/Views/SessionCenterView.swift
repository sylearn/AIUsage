import Combine
import QuotaBackend
import SwiftUI

// MARK: - Session Center
// 主窗口「会话」页：左侧会话列表（搜索 / 工具筛选 / 分组），右侧阅读视图与大纲。
// 状态见 SessionCenterStore；设计文档 docs/SESSION_CENTER_DESIGN.md §5。

struct SessionCenterView: View {
    @ObservedObject private var store = SessionCenterStore.shared
    @Environment(\.colorScheme) private var colorScheme

    /// 页面可见时每 30 秒增量刷新一次（未变化的文件不会重新解析）。
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
                    SessionPlaceholder(isEmpty: store.hasScanned && store.sessions.isEmpty)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .appPageBackground(colorScheme)
        .appFlashOverlay(store.flash)
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Sessions", "会话", key: "nav.sessions"))
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                if store.isScanning {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await store.refresh(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppContent.secondary(colorScheme))
                .help(L("Rescan local sessions", "重新扫描本机会话", key: "sessions.refresh"))
                .disabled(store.isScanning)
            }
            searchField
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

    private var toolFilter: some View {
        HStack(spacing: 2) {
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
                    .fixedSize()
            }
            .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? AppContent.primary(colorScheme) : AppContent.secondary(colorScheme))
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
        .help(L("\(store.count(for: tool)) sessions", "\(store.count(for: tool)) 个会话"))
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
            VStack(spacing: 6) {
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
                                    SessionRow(store: store, session: session, isSelected: store.selectedID == session.id)
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(L("Read-only. Nothing is uploaded or modified.", "只读本机记录，不上传，不修改原文件",
                    key: "sessions.footer.privacy"), systemImage: "lock")
            Text(L("↑↓ select · ↩ resume · right-click for more", "↑↓ 选择 · ↩ 继续对话 · 右键查看更多",
                   key: "sessions.footer.keys"))
        }
        .font(.system(size: 11))
        .foregroundStyle(AppContent.tertiary(colorScheme))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }
}

// MARK: - Row

private struct SessionRow: View {
    @ObservedObject var store: SessionCenterStore
    let session: SessionSummary
    let isSelected: Bool
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
                HStack(spacing: 5) {
                    if let project = session.projectName {
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
                HStack(spacing: 4) {
                    Text(SessionDateText.short(session.updatedAt))
                    if let prompts = session.promptCount {
                        Text("·")
                        Text(L("\(prompts) prompts", "\(prompts) 轮"))
                    }
                    if session.resumeBlocker != nil {
                        Image(systemName: "exclamationmark.circle")
                            .help(SessionReaderView.blockerText(session.resumeBlocker))
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(AppContent.tertiary(colorScheme))
                .monospacedDigit()
            }
            Spacer(minLength: 0)
            if (hovering || isSelected), session.resumeBlocker == nil {
                Button {
                    Task { await store.resume(session) }
                } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 11.5, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(AppSurface.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(AppStroke.subtle(colorScheme)))
                }
                .buttonStyle(.plain)
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
        .onHover { hovering = $0 }
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
