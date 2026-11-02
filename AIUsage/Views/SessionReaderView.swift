import QuotaBackend
import SwiftUI

// MARK: - Session Reader
// 会话中心右侧：头部（工具、标题、元信息、动作）、正文（提问 / 回复 / 步骤组 / 提示）与大纲。
// 步骤组默认折叠，含失败步骤的组默认展开并用橙色标出。
// 搜索时高亮搜索词；从全文搜索结果点进来会滚到命中的那一条。会话进行中、视图停在底部时跟着新内容滚动。

struct SessionReaderView: View {
    @ObservedObject var store: SessionCenterStore
    let session: SessionSummary
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            content
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                ProviderIconView(session.tool.rawValue, size: 16)
                Text(session.tool.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Text(session.sessionID)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(AppContent.tertiary(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if session.isPinned {
                    badge(L("Pinned", "已置顶", key: "sessions.badge.pinned"), tint: AppContent.secondary(colorScheme))
                }
                if let activity = session.activity {
                    SessionActivityLabel(activity: activity, tool: session.tool)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppContent.secondary(colorScheme))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SessionActivityDot.tint(activity, colorScheme).opacity(0.13), in: Capsule())
                }
                if let blocker = session.resumeBlocker {
                    badge(Self.blockerText(blocker), tint: .orange)
                }
                Spacer(minLength: 12)
                actions
            }
            Text(session.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(AppContent.primary(colorScheme))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                if let directory = session.directory {
                    chip(systemImage: "folder", text: Self.abbreviated(directory), monospaced: true)
                        .help(directory)
                }
                if let branch = session.gitBranch {
                    chip(systemImage: "arrow.triangle.branch", text: branch, monospaced: true)
                }
                if let model = session.model {
                    chip(systemImage: "cpu", text: model)
                }
                if let prompts = session.promptCount {
                    chip(systemImage: "text.bubble", text: L("\(prompts) prompts", "\(prompts) 轮提问"))
                }
                if let tokens = session.tokens {
                    chip(systemImage: "number", text: formatCompactNumber(Double(tokens)) + " tokens")
                        .help(L("Cumulative tokens recorded by the tool, cache reads included.",
                                "工具记录的累计 token，含缓存读取。", key: "sessions.tokens.help"))
                }
                chip(systemImage: "clock", text: L("Updated ", "更新于 ", key: "sessions.updated_prefix")
                     + SessionDateText.full(session.updatedAt))
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button {
                store.copyCommand(session)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help(L("Copy Resume Command", "复制恢复命令", key: "sessions.action.copy_command"))
            .accessibilityLabel(L("Copy Resume Command", "复制恢复命令", key: "sessions.action.copy_command"))
            .disabled(session.resumeBlocker == .directoryMissing)

            Menu {
                SessionActionsMenu(store: store, session: session)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("More", "更多", key: "sessions.action.more"))

            Button {
                Task { await store.resume(session) }
            } label: {
                Label(L("Resume in \(store.terminal.displayName)", "在 \(store.terminal.displayName) 中继续"),
                      systemImage: "terminal")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(session.resumeBlocker != nil)
            .help(session.resumeBlocker.map { Self.blockerText($0) }
                  ?? (L("Resume this session (⌘↩)", "继续这个会话（⌘↩）", key: "sessions.action.resume_help")
                      + (store.terminal.confirmationNote.map { " · " + $0 } ?? "")))

            Menu {
                Section(L("Resume in", "在哪个终端继续", key: "sessions.terminal.menu_title")) {
                    ForEach(store.availableTerminals) { terminal in
                        Button {
                            store.setTerminal(terminal)
                        } label: {
                            if terminal == store.terminal {
                                Label(terminal.displayName, systemImage: "checkmark")
                            } else {
                                Text(terminal.displayName)
                            }
                        }
                    }
                }
                if let note = store.terminal.confirmationNote {
                    Text(note)
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Choose terminal", "选择终端", key: "sessions.terminal.choose"))
        }
        .controlSize(.regular)
    }

    private func chip(systemImage: String, text: String, monospaced: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppContent.tertiary(colorScheme))
            Text(text)
                .font(.system(size: 11.5, design: monospaced ? .monospaced : .default))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(AppContent.secondary(colorScheme))
        .padding(.horizontal, 8)
        .frame(height: 22)
        .frame(maxWidth: 420, alignment: .leading)
        .background(AppSurface.chip(colorScheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch store.transcriptState {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            message(
                systemImage: "archivebox",
                title: L("Preview not available", "无法预览这个会话", key: "sessions.unavailable.title"),
                detail: session.tool == .codex
                    ? L("Codex kept only a compressed copy of this session. You can still resume it.",
                        "Codex 只保留了这个会话的压缩记录，无法预览，仍可继续对话。", key: "sessions.unavailable.codex")
                    : L("The tool left no readable content for this session.", "原工具没有留下可读的内容。",
                        key: "sessions.unavailable.generic")
            )
        case .failed:
            message(
                systemImage: "exclamationmark.triangle",
                title: L("Couldn't read this session", "读取这个会话失败", key: "sessions.failed.title"),
                detail: L("The file may be in use or in a newer format. Try rescanning.",
                          "文件可能正被占用，或格式较新。可以重新扫描后再试。", key: "sessions.failed.detail")
            )
        case .loaded(let transcript):
            SessionTranscriptView(
                session: session,
                transcript: transcript,
                terms: store.highlightTerms,
                focus: store.focus?.sessionID == session.id ? store.focus : nil
            )
        }
    }

    private func message(systemImage: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(AppContent.tertiary(colorScheme))
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(AppContent.secondary(colorScheme))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Text helpers

    static func blockerText(_ blocker: SessionResumeBlocker?) -> String {
        switch blocker {
        case .directoryMissing?:
            return L("Project folder is gone", "项目目录已不存在", key: "sessions.blocker.directory")
        case .recordMissing?:
            return L("Session record is gone", "会话记录已不在磁盘上", key: "sessions.blocker.record")
        case nil:
            return ""
        }
    }

    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Transcript

private struct SessionTranscriptView: View {
    let session: SessionSummary
    let transcript: SessionTranscript
    let terms: [String]
    let focus: SessionCenterStore.TranscriptFocus?
    @Environment(\.colorScheme) private var colorScheme
    /// 正文末尾是否在可见范围内（会话进行中时据此决定要不要跟着新内容滚动）。
    @State private var atBottom = false
    /// 条目序号从 0 开始，用 -1 标记末尾。
    private static let bottomID = -1

    private var outline: [(index: Int, item: TranscriptItem, text: String)] {
        var number = 0
        return transcript.items.compactMap { item in
            guard case .prompt(let text) = item.entry else { return nil }
            number += 1
            return (number, item, text)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if transcript.omittedCount > 0 {
                                Text(L("\(transcript.omittedCount) earlier items omitted", "已省略 \(transcript.omittedCount) 条较早的内容"))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(AppContent.tertiary(colorScheme))
                                    .frame(maxWidth: .infinity)
                            }
                            ForEach(transcript.items) { item in
                                TranscriptItemView(tool: session.tool, item: item, terms: terms)
                                    .id(item.id)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(Self.bottomID)
                                .onAppear { atBottom = true }
                                .onDisappear { atBottom = false }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 22)
                        .frame(maxWidth: 920, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    if geometry.size.width > 860 {
                        Divider().opacity(0.6)
                        outlineColumn(proxy: proxy)
                            .frame(width: 236)
                    }
                }
            }
            .task(id: focus) {
                guard let focus, let item = transcript.items.first(where: { $0.id == focus.itemID }) else { return }
                // 长回复里命中词可能在末尾：把这一条按命中词在文中的相对位置对齐到视口的同一位置，命中处就在屏幕上。
                let anchor = UnitPoint(x: 0.5, y: Self.hitFraction(in: item, terms: terms))
                // 等 LazyVStack 完成首轮布局再滚；按估算高度滚一次后再校正一次。
                try? await Task.sleep(nanoseconds: 80_000_000)
                proxy.scrollTo(focus.itemID, anchor: anchor)
                try? await Task.sleep(nanoseconds: 150_000_000)
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(focus.itemID, anchor: anchor) }
            }
            .onChange(of: transcript.items.last) { _, _ in
                guard atBottom else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
        }
    }

    /// 第一个搜索词在这一条文字里的相对位置（0 为开头）。
    static func hitFraction(in item: TranscriptItem, terms: [String]) -> CGFloat {
        let text: String
        switch item.entry {
        case .prompt(let value), .reply(let value):
            text = value
        case .steps(let steps):
            text = steps.map { [$0.name, $0.detail, $0.failureNote ?? ""].joined(separator: " ") }.joined(separator: "\n")
        case .notice:
            return 0
        }
        let hits = terms.compactMap { text.range(of: $0, options: .caseInsensitive)?.lowerBound }
        guard let first = hits.min(), !text.isEmpty else { return 0 }
        return CGFloat(text.distance(from: text.startIndex, to: first)) / CGFloat(text.count)
    }

    private func outlineColumn(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Outline", "大纲", key: "sessions.outline"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppContent.secondary(colorScheme))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(outline, id: \.item.id) { entry in
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(entry.item.id, anchor: .top) }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(entry.index)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(AppContent.tertiary(colorScheme))
                                    .frame(width: 18, alignment: .trailing)
                                    .monospacedDigit()
                                Text(entry.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? entry.text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppContent.primary(colorScheme))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            stats
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 18)
        .background(AppSurface.sidebar(colorScheme).opacity(colorScheme == .dark ? 0.35 : 0.45))
    }

    private var stats: some View {
        let stats = transcript.stats
        let items: [(String, Int, Bool)] = [
            (L("prompts", "轮提问", key: "sessions.stats.prompts"), stats.prompts, false),
            (L("tool calls", "次工具调用", key: "sessions.stats.tools"), stats.toolCalls, false),
            (L("files changed", "个文件改动", key: "sessions.stats.files"), stats.filesChanged, false),
            (L("failures", "次失败", key: "sessions.stats.failures"), stats.failures, stats.failures > 0)
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                         alignment: .leading, spacing: 10) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(item.1)")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(item.2 ? Color.orange : AppContent.primary(colorScheme))
                        .monospacedDigit()
                    Text(item.0)
                        .font(.system(size: 11))
                        .foregroundStyle(AppContent.tertiary(colorScheme))
                }
            }
        }
        .padding(12)
        .background(AppSurface.card(colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppStroke.subtle(colorScheme)))
    }
}

private struct TranscriptItemView: View {
    let tool: SessionTool
    let item: TranscriptItem
    let terms: [String]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch item.entry {
        case .prompt(let text):
            HStack {
                Spacer(minLength: 72)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(L("You", "你", key: "sessions.you") + (item.date.map { " · " + Self.time($0) } ?? ""))
                        .font(.system(size: 11))
                        .foregroundStyle(AppContent.tertiary(colorScheme))
                    Text(SessionHighlight.attributed(text, terms: terms, scheme: colorScheme))
                        .font(.system(size: 13.5))
                        .foregroundStyle(AppContent.primary(colorScheme))
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(promptBubble, in: UnevenRoundedRectangle(
                            topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14,
                            style: .continuous))
                }
            }
        case .reply(let text):
            HStack(alignment: .top, spacing: 10) {
                ProviderIconView(tool.rawValue, size: 20)
                    .padding(.top, 1)
                MessageText(text: text, terms: terms)
            }
            .padding(.trailing, 40)
        case .steps(let steps):
            StepGroupView(steps: steps, terms: terms)
                .padding(.leading, 30)
        case .notice(let notice):
            HStack(spacing: 6) {
                Image(systemName: notice == .contextCompacted ? "arrow.down.right.and.arrow.up.left" : "stop.circle")
                Text(notice == .contextCompacted
                     ? L("Context compacted", "上下文已压缩", key: "sessions.notice.compacted")
                     : L("Interrupted", "已中断", key: "sessions.notice.interrupted"))
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(AppContent.tertiary(colorScheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(AppSurface.chip(colorScheme), in: Capsule())
            .frame(maxWidth: .infinity)
        }
    }

    private var promptBubble: Color {
        colorScheme == .dark ? Color.accentColor.opacity(0.24) : AppSurface.selection(colorScheme)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}

// MARK: - Steps

private struct StepGroupView: View {
    let steps: [ToolStep]
    let terms: [String]
    @State private var expanded: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// 有失败步骤，或搜索词命中某一步时默认展开。
    init(steps: [ToolStep], terms: [String]) {
        self.steps = steps
        self.terms = terms
        let hit = !terms.isEmpty && steps.contains { step in
            terms.contains { term in
                [step.name, step.detail, step.failureNote ?? ""].contains { $0.range(of: term, options: .caseInsensitive) != nil }
            }
        }
        _expanded = State(initialValue: hit || steps.contains(where: \.failed))
    }

    private var failures: Int { steps.filter(\.failed).count }

    private var summary: String {
        var parts = [L("\(steps.count) steps", "\(steps.count) 步")]
        let reads = Set(steps.filter { $0.kind == .read }.flatMap(\.paths)).count
        let edits = Set(steps.filter { $0.kind == .edit && !$0.failed }.flatMap(\.paths)).count
        let commands = steps.filter { $0.kind == .command }.count
        if reads > 0 { parts.append(L("read \(reads) files", "读 \(reads) 个文件")) }
        if edits > 0 { parts.append(L("changed \(edits) files", "改 \(edits) 个文件")) }
        if commands > 0 { parts.append(L("ran \(commands) commands", "运行 \(commands) 条命令")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(AppContent.tertiary(colorScheme))
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 11))
                        .foregroundStyle(AppContent.tertiary(colorScheme))
                    Text(summary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(AppContent.secondary(colorScheme))
                    Spacer(minLength: 8)
                    if failures > 0 {
                        Label(L("\(failures) failed", "\(failures) 次失败"), systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.13), in: Capsule())
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(summary)
            .accessibilityValue(expanded ? L("Expanded", "已展开", key: "sessions.a11y.expanded") : L("Collapsed", "已折叠", key: "sessions.a11y.collapsed"))

            if expanded {
                Divider().opacity(0.6)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        StepRow(step: step, terms: terms)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(AppSurface.card(colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(failures > 0 ? Color.orange.opacity(0.35) : AppStroke.subtle(colorScheme)))
    }
}

private struct StepRow: View {
    let step: ToolStep
    let terms: [String]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: step.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(step.failed ? Color.orange : Color.green.opacity(0.85))
                .accessibilityLabel(step.failed ? L("Failed", "失败", key: "sessions.step.failed") : L("Succeeded", "成功", key: "sessions.step.ok"))
            Text(step.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppContent.primary(colorScheme))
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if !step.detail.isEmpty {
                    Text(SessionHighlight.attributed(step.detail, terms: terms, scheme: colorScheme))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(AppContent.secondary(colorScheme))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                if let note = step.failureNote, !note.isEmpty {
                    Text(SessionHighlight.attributed(note, terms: terms, scheme: colorScheme))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - Message text

/// 回复正文：``` 代码块用等宽底色块显示，其余按行内 Markdown 渲染（粗体、行内代码、链接）。
private struct MessageText: View {
    let text: String
    let terms: [String]
    @Environment(\.colorScheme) private var colorScheme

    private enum Segment: Hashable {
        case prose(String)
        case code(String)
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var inCode = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    result.append(.code(code.joined(separator: "\n")))
                    code = []
                } else if !prose.isEmpty {
                    result.append(.prose(prose.joined(separator: "\n")))
                    prose = []
                }
                inCode.toggle()
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inCode, !code.isEmpty { result.append(.code(code.joined(separator: "\n"))) }
        let rest = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { result.append(.prose(rest)) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let prose):
                    Text(highlighted(Self.attributed(prose)))
                        .font(.system(size: 13.5))
                        .foregroundStyle(AppContent.primary(colorScheme))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(SessionHighlight.attributed(code, terms: terms, scheme: colorScheme))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(AppContent.primary(colorScheme))
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppSurface.chip(colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private func highlighted(_ string: AttributedString) -> AttributedString {
        var string = string
        SessionHighlight.apply(to: &string, terms: terms, scheme: colorScheme)
        return string
    }

    /// 行内 Markdown 之外，把列表符号换成「•」，标题行加粗。
    private static func attributed(_ text: String) -> AttributedString {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.drop(while: { $0 == " " })
            let indent = String(line.prefix(line.count - trimmed.count))
            if let marker = trimmed.first, "-*+".contains(marker), trimmed.dropFirst().first == " " {
                return indent + "• " + trimmed.dropFirst(2)
            }
            if trimmed.hasPrefix("#") {
                let heading = trimmed.drop(while: { $0 == "#" })
                if heading.first == " ", trimmed.count - heading.count <= 6 {
                    return "**" + heading.trimmingCharacters(in: .whitespaces) + "**"
                }
            }
            return String(line)
        }
        let source = lines.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Search highlight

/// 搜索词高亮：列表摘录与阅读视图共用。不区分大小写，与搜索的匹配规则一致。
enum SessionHighlight {
    static func color(_ scheme: ColorScheme) -> Color {
        Color.yellow.opacity(scheme == .dark ? 0.32 : 0.42)
    }

    static func attributed(_ text: String, terms: [String], scheme: ColorScheme) -> AttributedString {
        var string = AttributedString(text)
        apply(to: &string, terms: terms, scheme: scheme)
        return string
    }

    static func apply(to string: inout AttributedString, terms: [String], scheme: ColorScheme) {
        let color = color(scheme)
        for term in terms where !term.isEmpty {
            var lower = string.startIndex
            while lower < string.endIndex, let range = string[lower...].range(of: term, options: .caseInsensitive) {
                string[range].backgroundColor = color
                lower = range.upperBound
            }
        }
    }

    static func symbol(for kind: SessionExcerpt.Kind) -> String {
        switch kind {
        case .prompt: return "person"
        case .reply: return "text.bubble"
        case .steps: return "wrench.and.screwdriver"
        }
    }
}

// MARK: - Activity

/// 「进行中」：圆点（运行时呼吸）加文字，悬停说明判断依据。列表行、阅读视图头部、菜单栏共用。
struct SessionActivityLabel: View {
    let activity: SessionActivity
    let tool: SessionTool

    var body: some View {
        // 文字颜色随所在位置（列表行、菜单栏、头部徽标）。
        HStack(spacing: 4) {
            SessionActivityDot(activity: activity)
            Text(Self.title(activity))
        }
        .help(Self.detail(activity, tool: tool))
        .accessibilityElement(children: .combine)
    }

    static func title(_ activity: SessionActivity) -> String {
        switch activity {
        case .working: return L("In progress", "进行中", key: "sessions.activity.working")
        case .waiting: return L("Waiting for input", "等待输入", key: "sessions.activity.waiting")
        }
    }

    static func detail(_ activity: SessionActivity, tool: SessionTool) -> String {
        switch (activity, tool) {
        case (.waiting, _):
            return L("Open in Claude Code and waiting for your input.", "Claude Code 开着这个会话，在等你输入。",
                     key: "sessions.activity.waiting_help")
        case (.working, .claude):
            return L("Claude Code is working on this session right now.", "Claude Code 正在处理这个会话。",
                     key: "sessions.activity.claude_help")
        case (.working, _):
            return L("\(tool.displayName) started a turn here in the last 30 minutes that hasn't finished.",
                     "\(tool.displayName) 在这个会话里有一轮还没结束（30 分钟内有动静）。")
        }
    }
}

struct SessionActivityDot: View {
    let activity: SessionActivity
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(Self.tint(activity, colorScheme))
            .frame(width: 6, height: 6)
            .opacity(dimmed ? 0.3 : 1)
            .onAppear {
                guard activity == .working, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dimmed = true }
            }
    }

    static func tint(_ activity: SessionActivity, _ scheme: ColorScheme) -> Color {
        activity == .working ? Color.green : AppContent.tertiary(scheme)
    }
}
