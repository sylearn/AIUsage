import AppKit
import Combine
import Foundation
import QuotaBackend
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Session Center Store
// 会话中心的状态层：后台扫描三家 CLI 的本地会话、筛选分组、按需加载正文，以及继续 / 复制 / 导出等动作。
// 主窗口与菜单栏共用同一实例。设计文档：docs/SESSION_CENTER_DESIGN.md

struct SessionGroup: Identifiable {
    let id: String
    let title: String
    let sessions: [SessionSummary]
}

@MainActor
final class SessionCenterStore: ObservableObject {
    static let shared = SessionCenterStore()

    enum Grouping: String, CaseIterable {
        case time
        case project
    }

    enum TranscriptState: Equatable {
        case idle
        case loading
        case loaded(SessionTranscript)
        case unavailable
        case failed
    }

    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published var query = ""
    /// nil 表示全部工具。
    @Published var toolFilter: SessionTool?
    @Published var grouping: Grouping = .time
    @Published private(set) var selectedID: String?
    @Published private(set) var transcriptState: TranscriptState = .idle
    @Published var flash: AppFlash?
    /// 已安装的终端（查询 LaunchServices），启动时取一次，之后随扫描刷新。
    @Published private(set) var availableTerminals: [SessionTerminal]
    /// 「继续对话」使用的终端。
    @Published private(set) var terminal: SessionTerminal

    private let catalog = SessionCatalog.shared
    private let settings = AppSettings.shared
    private var lastScan: Date?
    private var transcriptCache: [String: (updatedAt: Date, transcript: SessionTranscript)] = [:]
    private var transcriptOrder: [String] = []
    private var transcriptTask: Task<Void, Never>?
    private static let transcriptCacheLimit = 8
    private static let minimumScanInterval: TimeInterval = 5

    private init() {
        let installed = SessionTerminal.installed
        availableTerminals = installed
        terminal = Self.resolvedTerminal(installed: installed)
        Task.detached(priority: .background) { TerminalLauncher.removeStaleScripts() }
    }

    // MARK: Derived state

    var filteredSessions: [SessionSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.filter { session in
            (toolFilter == nil || session.tool == toolFilter) && (trimmed.isEmpty || session.matches(trimmed))
        }
    }

    var groups: [SessionGroup] {
        let list = filteredSessions
        switch grouping {
        case .project:
            var order: [String] = []
            var buckets: [String: [SessionSummary]] = [:]
            for session in list {
                let key = session.projectName ?? L("No project", "未知项目", key: "sessions.group.no_project")
                if buckets[key] == nil { order.append(key) }
                buckets[key, default: []].append(session)
            }
            return order.map { SessionGroup(id: "project:" + $0, title: $0, sessions: buckets[$0] ?? []) }
        case .time:
            var result: [SessionGroup] = []
            let pinned = list.filter(\.isPinned)
            if !pinned.isEmpty {
                result.append(SessionGroup(id: "pinned", title: L("Pinned", "置顶", key: "sessions.group.pinned"), sessions: pinned))
            }
            var buckets: [SessionDateText.Bucket: [SessionSummary]] = [:]
            for session in list where !session.isPinned {
                buckets[SessionDateText.bucket(for: session.updatedAt), default: []].append(session)
            }
            for bucket in SessionDateText.Bucket.allCases {
                if let sessions = buckets[bucket], !sessions.isEmpty {
                    result.append(SessionGroup(id: bucket.rawValue, title: bucket.title, sessions: sessions))
                }
            }
            return result
        }
    }

    /// 列表里从上到下的顺序（置顶组在前），供 ↑↓ 键导航。
    func selectAdjacent(_ offset: Int) {
        let order = groups.flatMap(\.sessions)
        guard !order.isEmpty else { return }
        let current = selectedID.flatMap { id in order.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + offset, 0), order.count - 1) } ?? 0
        select(order[next].id)
    }

    func count(for tool: SessionTool?) -> Int {
        tool.map { tool in sessions.filter { $0.tool == tool }.count } ?? sessions.count
    }

    var selectedSession: SessionSummary? {
        selectedID.flatMap { id in sessions.first { $0.id == id } }
    }

    var recentSessions: [SessionSummary] { Array(sessions.prefix(4)) }

    func setTerminal(_ terminal: SessionTerminal) {
        self.terminal = terminal
        settings.sessionResumeTerminal = terminal.rawValue
    }

    /// 记住的终端仍已安装就用它，否则按 SessionTerminal 的顺序取第一个已安装的，系统终端兜底。
    private static func resolvedTerminal(installed: [SessionTerminal]) -> SessionTerminal {
        SessionTerminal(rawValue: AppSettings.shared.sessionResumeTerminal).flatMap { installed.contains($0) ? $0 : nil }
            ?? installed.first ?? .terminal
    }

    /// 用户装上或卸载终端后，菜单与默认终端跟着更新。
    private func refreshTerminals() {
        let installed = SessionTerminal.installed
        if installed != availableTerminals { availableTerminals = installed }
        if !installed.contains(terminal) { terminal = Self.resolvedTerminal(installed: installed) }
    }

    // MARK: Loading

    /// 扫描三家 CLI；5 秒内的重复调用直接跳过（视图出现、菜单栏打开、定时器都会调用）。
    func refresh(force: Bool = false) async {
        if isScanning { return }
        if !force, let lastScan, Date().timeIntervalSince(lastScan) < Self.minimumScanInterval { return }
        refreshTerminals()
        isScanning = true
        let catalog = catalog
        let result = await Task.detached(priority: .userInitiated) { catalog.scan() }.value
        sessions = result
        lastScan = Date()
        isScanning = false
        hasScanned = true

        if let selectedID, !result.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
            transcriptState = .idle
        }
        if selectedID == nil, let first = result.first {
            select(first.id)
        } else if let selected = selectedSession, transcriptCache[selected.id]?.updatedAt != selected.updatedAt {
            loadTranscript(for: selected)
        }
    }

    func select(_ id: String?) {
        guard id != selectedID || transcriptState == .idle else { return }
        selectedID = id
        guard let session = selectedSession else {
            transcriptTask?.cancel()
            transcriptState = .idle
            return
        }
        loadTranscript(for: session)
    }

    /// 菜单栏点一条会话：选中后由调用方打开主窗口。
    func reveal(_ session: SessionSummary) {
        query = ""
        toolFilter = nil
        select(session.id)
    }

    private func loadTranscript(for session: SessionSummary) {
        transcriptTask?.cancel()
        guard session.hasTranscript else {
            transcriptState = .unavailable
            return
        }
        if let cached = transcriptCache[session.id], cached.updatedAt == session.updatedAt {
            transcriptState = .loaded(cached.transcript)
            return
        }
        transcriptState = .loading
        let catalog = catalog
        transcriptTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try catalog.transcript(for: session) }
            }.value
            guard let self, !Task.isCancelled, self.selectedID == session.id else { return }
            switch result {
            case .success(let transcript):
                self.remember(transcript, for: session)
                self.transcriptState = .loaded(transcript)
            case .failure(let error):
                self.transcriptState = (error as? SessionTranscriptError) == .unavailable ? .unavailable : .failed
            }
        }
    }

    private func remember(_ transcript: SessionTranscript, for session: SessionSummary) {
        transcriptCache[session.id] = (session.updatedAt, transcript)
        transcriptOrder.removeAll { $0 == session.id }
        transcriptOrder.append(session.id)
        while transcriptOrder.count > Self.transcriptCacheLimit {
            transcriptCache.removeValue(forKey: transcriptOrder.removeFirst())
        }
    }

    // MARK: Actions

    func resume(_ session: SessionSummary) async {
        let plan: SessionResumePlan
        do {
            plan = try SessionResumePlan.make(for: session)
        } catch SessionResumeError.directoryMissing {
            show(.error(L("The project folder no longer exists, so this session can't be resumed.",
                          "项目目录已不存在，无法继续这个会话。", key: "sessions.error.directory_missing")))
            return
        } catch {
            show(.error(L("This session ID can't be resumed safely.", "会话 ID 格式异常，已停止继续。",
                          key: "sessions.error.invalid_id")))
            return
        }

        let terminal = terminal
        do {
            try await TerminalLauncher.launch(plan, in: terminal)
            let opened = L("Opened in \(terminal.displayName)", "已在 \(terminal.displayName) 中打开")
            show(.success(terminal.confirmationNote.map { opened + " · " + $0 } ?? opened))
        } catch {
            copyToPasteboard(plan.commandLine)
            show(.error(L("Couldn't open \(terminal.displayName). The resume command was copied.",
                          "无法打开 \(terminal.displayName)，已复制恢复命令。")))
        }
    }

    func copyCommand(_ session: SessionSummary) {
        do {
            copyToPasteboard(try SessionResumePlan.make(for: session).commandLine)
            show(.success(L("Resume command copied", "已复制恢复命令", key: "sessions.flash.command_copied")))
        } catch {
            show(.error(L("The project folder no longer exists, so this session can't be resumed.",
                          "项目目录已不存在，无法继续这个会话。", key: "sessions.error.directory_missing")))
        }
    }

    func copySessionID(_ session: SessionSummary) {
        copyToPasteboard(session.sessionID)
        show(.success(L("Session ID copied", "已复制会话 ID", key: "sessions.flash.id_copied")))
    }

    func revealInFinder(_ session: SessionSummary) {
        guard let directory = session.directory, FileManager.default.fileExists(atPath: directory) else {
            show(.error(L("The project folder no longer exists.", "项目目录已不存在。", key: "sessions.error.folder_gone")))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
    }

    func exportMarkdown(_ session: SessionSummary) async {
        let catalog = catalog
        let result = await Task.detached(priority: .userInitiated) {
            Result { try catalog.transcript(for: session) }
        }.value
        guard case .success(let transcript) = result else {
            show(.error(L("This session has no readable content to export.", "这个会话没有可导出的内容。",
                          key: "sessions.error.export_empty")))
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = Self.fileName(for: session) + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let markdown = SessionMarkdownExporter.markdown(summary: session, transcript: transcript, labels: Self.markdownLabels)
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            show(.success(L("Exported", "已导出", key: "sessions.flash.exported")))
        } catch {
            show(.error(error.localizedDescription))
        }
    }

    private func show(_ flash: AppFlash) {
        let binding = Binding<AppFlash?>(get: { [weak self] in self?.flash }, set: { [weak self] in self?.flash = $0 })
        AppFlashPresenter.present(flash, into: binding)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func fileName(for session: SessionSummary) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines)
        let cleaned = session.title.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? session.sessionID : cleaned).prefix(80))
    }

    private static var markdownLabels: SessionMarkdownExporter.Labels {
        var labels = SessionMarkdownExporter.Labels()
        labels.you = L("You", "你", key: "sessions.you")
        labels.session = L("Session", "会话", key: "sessions.label.session")
        labels.directory = L("Directory", "目录", key: "sessions.label.directory")
        labels.branch = L("Branch", "分支", key: "sessions.label.branch")
        labels.model = L("Model", "模型", key: "sessions.label.model")
        labels.updated = L("Updated", "更新于", key: "sessions.label.updated")
        labels.contextCompacted = L("Context compacted", "上下文已压缩", key: "sessions.notice.compacted")
        labels.interrupted = L("Interrupted", "已中断", key: "sessions.notice.interrupted")
        let omitted = L("earlier items omitted", "条较早的内容已省略", key: "sessions.notice.omitted")
        labels.omitted = { "\($0) \(omitted)" }
        return labels
    }
}

// MARK: - Date text

enum SessionDateText {
    enum Bucket: String, CaseIterable {
        case today, yesterday, week, earlier

        var title: String {
            switch self {
            case .today: return L("Today", "今天", key: "sessions.group.today")
            case .yesterday: return L("Yesterday", "昨天", key: "sessions.group.yesterday")
            case .week: return L("This week", "本周", key: "sessions.group.week")
            case .earlier: return L("Earlier", "更早", key: "sessions.group.earlier")
            }
        }
    }

    static func bucket(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bucket {
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day,
           days < 7 { return .week }
        return .earlier
    }

    /// 今天「14:27」，昨天「昨天 22:58」，本周「周三」，今年「10月26日」，更早「2025/10/23」。
    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AppSettings.shared.language == "zh" ? "zh_CN" : "en_US")
        switch bucket(for: date, now: now, calendar: calendar) {
        case .today:
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        case .yesterday:
            formatter.dateFormat = "HH:mm"
            return Bucket.yesterday.title + " " + formatter.string(from: date)
        case .week:
            formatter.setLocalizedDateFormatFromTemplate("EEE")
            return formatter.string(from: date)
        case .earlier:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yyyyMMdd")
            return formatter.string(from: date)
        }
    }

    static func full(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AppSettings.shared.language == "zh" ? "zh_CN" : "en_US")
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMMd HH:mm")
        return formatter.string(from: date)
    }
}
