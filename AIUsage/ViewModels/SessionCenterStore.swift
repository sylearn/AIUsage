import AppKit
import Combine
import Foundation
import QuotaBackend
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Session Center Store
// 会话中心的状态层：后台扫描三家 CLI 的本地会话、筛选分组、按需加载正文，以及继续 / 复制 / 导出等动作。
// 主窗口与菜单栏共用同一实例。设计文档：docs/SESSION_CENTER_DESIGN.md
// 实时更新：会话页或菜单栏「最近会话」可见时（beginObserving / endObserving 计数）用 FSEvents 监听三家的数据目录，
// 有变化 1.5 秒内重扫；都不可见时停掉监听，不在后台空转。
// 全文搜索：用户确认开启后维护 SessionSearchIndex，每次扫描后增量更新；搜索在后台跑，结果按查询词缓存。

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

    enum IndexState: Equatable {
        case off
        /// 第一次建索引；total 为 0 表示还在比对要索引哪些会话。
        case building(done: Int, total: Int)
        case ready
    }

    /// 选中搜索结果后，阅读视图要滚到的那一条。
    struct TranscriptFocus: Equatable {
        let sessionID: String
        let itemID: Int
        /// 每次点选都不同：再点一次同一条结果也会重新滚过去。
        let token: Int
    }

    private struct SearchResults: Equatable {
        let query: String
        let matches: [String: SessionSearchMatch]
    }

    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var hasScanned = false
    /// 用户点了重新扫描；实时更新触发的扫描不显示进度。
    @Published private(set) var isRescanning = false
    @Published var query = ""
    /// nil 表示全部工具。
    @Published var toolFilter: SessionTool?
    @Published var grouping: Grouping = .time
    @Published private(set) var selectedID: String?
    @Published private(set) var transcriptState: TranscriptState = .idle
    @Published private(set) var focus: TranscriptFocus?
    @Published private(set) var indexState: IndexState = .off
    @Published private var searchResults: SearchResults?
    @Published var flash: AppFlash?
    /// 已安装的终端（查询 LaunchServices），启动时取一次，之后随扫描刷新。
    @Published private(set) var availableTerminals: [SessionTerminal]
    /// 「继续对话」使用的终端。
    @Published private(set) var terminal: SessionTerminal

    private let catalog = SessionCatalog.shared
    private let settings = AppSettings.shared
    private var isScanning = false
    private var rescanRequested = false
    private var lastScan: Date?
    private var transcriptCache: [String: (updatedAt: Date, transcript: SessionTranscript)] = [:]
    private var transcriptOrder: [String] = []
    private var transcriptTask: Task<Void, Never>?
    /// 当前 .loaded 的正文属于哪个会话；同一会话有新内容时先留着旧正文。
    private var loadedTranscriptID: String?
    private var focusCounter = 0
    private var observers = 0
    private var pendingRefresh: Task<Void, Never>?
    private lazy var monitor = SessionSourceMonitor { [weak self] in
        // 回调在监听队列上：先取强引用，再回主线程。
        guard let self else { return }
        Task { @MainActor in self.sourcesChanged() }
    }
    private var searchIndex: SessionSearchIndex?
    private var indexTask: Task<Void, Never>?
    private var indexCancellation: CancellationFlag?
    private var indexPending = false
    private var searchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private static let transcriptCacheLimit = 8
    private static let minimumScanInterval: TimeInterval = 5
    /// 实时更新时两次扫描的最短间隔（FSEvents 已把 1 秒内的变化合并成一次）。
    private static let liveScanInterval: TimeInterval = 1.5
    private static let searchDelay: TimeInterval = 0.15

    private init() {
        let installed = SessionTerminal.installed
        availableTerminals = installed
        terminal = Self.resolvedTerminal(installed: installed)
        Task.detached(priority: .background) { TerminalLauncher.removeStaleScripts() }

        // $query 在赋值前发出新值，这里直接用传进来的值。
        $query.removeDuplicates().dropFirst()
            .sink { [weak self] text in self?.scheduleSearch(text, delay: Self.searchDelay) }
            .store(in: &cancellables)
        settings.$sessionFullTextSearch.removeDuplicates()
            .sink { [weak self] enabled in self?.configureIndex(enabled: enabled) }
            .store(in: &cancellables)
    }

    // MARK: Derived state

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSearching: Bool { !trimmedQuery.isEmpty }

    /// 搜索框里的词（小写），列表摘录与阅读视图里高亮用。
    var highlightTerms: [String] {
        trimmedQuery.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// 当前查询的全文搜索结果；查询词刚变、结果还没回来时为 nil，先按列表信息过滤。
    private var currentMatches: [String: SessionSearchMatch]? {
        guard let searchResults, searchResults.query == trimmedQuery else { return nil }
        return searchResults.matches
    }

    var filteredSessions: [SessionSummary] {
        let trimmed = trimmedQuery
        let matches = trimmed.isEmpty ? nil : currentMatches
        return sessions.filter { session in
            (toolFilter == nil || session.tool == toolFilter)
                && (trimmed.isEmpty || matches?[session.id] != nil || session.matches(trimmed))
        }
    }

    /// 全文搜索在正文里命中的那一段（只命中列表信息时为 nil）。
    func excerpt(for session: SessionSummary) -> SessionExcerpt? {
        currentMatches?[session.id]?.excerpt
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

    /// 扫描三家 CLI；非强制调用 5 秒内重复直接跳过（视图出现、菜单栏打开、定时器都会调用）。
    func refresh(force: Bool = false) async {
        if isScanning {
            if force { rescanRequested = true }
            return
        }
        if !force, let lastScan, Date().timeIntervalSince(lastScan) < Self.minimumScanInterval { return }
        refreshTerminals()
        // 工具装好后数据目录才出现，每次扫描时顺手让监听接上新目录。
        if observers > 0 { monitor.start() }
        isScanning = true
        let catalog = catalog
        let result = await Task.detached(priority: .userInitiated) { catalog.scan() }.value
        if result != sessions { sessions = result }
        lastScan = Date()
        isScanning = false
        hasScanned = true

        if let selectedID, !result.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
            transcriptState = .idle
            loadedTranscriptID = nil
        }
        if selectedID == nil, let first = result.first {
            select(first.id)
        } else if let selected = selectedSession, transcriptCache[selected.id]?.updatedAt != selected.updatedAt {
            loadTranscript(for: selected)
        }
        if searchIndex != nil { updateIndex() }
        if isSearching { scheduleSearch(query, delay: 0) }
        if rescanRequested {
            rescanRequested = false
            sourcesChanged()
        }
    }

    /// 列表头部的「重新扫描」。
    func rescan() async {
        isRescanning = true
        await refresh(force: true)
        isRescanning = false
    }

    /// 会话页、菜单栏「最近会话」出现时调用：可见期间监听数据目录，有变化自动重扫。
    func beginObserving() {
        observers += 1
        if observers == 1 { monitor.start() }
    }

    func endObserving() {
        observers = max(0, observers - 1)
        guard observers == 0 else { return }
        monitor.stop()
        pendingRefresh?.cancel()
        pendingRefresh = nil
    }

    /// FSEvents 报告会话记录有变化：距上次扫描不足 1.5 秒就等一等，期间的变化合并成一次扫描。
    private func sourcesChanged() {
        guard observers > 0, pendingRefresh == nil else { return }
        let elapsed = lastScan.map { Date().timeIntervalSince($0) } ?? .infinity
        let wait = max(0, Self.liveScanInterval - elapsed)
        pendingRefresh = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let self, !Task.isCancelled else { return }
            self.pendingRefresh = nil
            await self.refresh(force: true)
        }
    }

    func select(_ id: String?) {
        // 从全文搜索结果点进来：阅读视图滚到命中的那一条。
        var target: TranscriptFocus?
        if let id, let session = sessions.first(where: { $0.id == id }), let match = excerpt(for: session) {
            focusCounter += 1
            target = TranscriptFocus(sessionID: session.id, itemID: match.itemID, token: focusCounter)
        }
        guard id != selectedID || transcriptState == .idle else {
            // 已经选中的会话：换了搜索词或再点一次，只滚到命中处，不重新加载。
            if let target { focus = target }
            return
        }
        selectedID = id
        focus = target
        guard let session = selectedSession else {
            transcriptTask?.cancel()
            transcriptState = .idle
            loadedTranscriptID = nil
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
            loadedTranscriptID = nil
            return
        }
        if let cached = transcriptCache[session.id], cached.updatedAt == session.updatedAt {
            transcriptState = .loaded(cached.transcript)
            loadedTranscriptID = session.id
            return
        }
        // 正在看的会话有了新内容：旧正文留到新的读完，不闪加载中，滚动位置也不回到顶部。
        var refreshing = false
        if case .loaded = transcriptState, loadedTranscriptID == session.id { refreshing = true }
        if !refreshing { transcriptState = .loading }
        let catalog = catalog
        transcriptTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try catalog.transcript(for: session) }
            }.value
            guard let self, !Task.isCancelled, self.selectedID == session.id else { return }
            switch result {
            case .success(let transcript):
                self.remember(transcript, for: session)
                if self.transcriptState != .loaded(transcript) { self.transcriptState = .loaded(transcript) }
                self.loadedTranscriptID = session.id
            case .failure(let error):
                // 刷新时没读成（文件可能正写到一半）就保留旧正文，下次变化再读。
                guard !refreshing else { return }
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

    // MARK: Full-text search

    var isFullTextEnabled: Bool { settings.sessionFullTextSearch }

    /// 开启前由界面向用户说明并确认；关闭时删除索引文件。
    func setFullTextSearch(_ enabled: Bool) {
        settings.sessionFullTextSearch = enabled
    }

    /// 索引文件占用的空间；未开启时为 nil。
    var indexFileSize: Int64? {
        searchIndex?.fileSize
    }

    private func configureIndex(enabled: Bool) {
        if enabled {
            guard searchIndex == nil else { return }
            searchIndex = SessionSearchIndex(catalog: catalog)
            indexState = .building(done: 0, total: 0)
            if hasScanned { updateIndex() }
            if isSearching { scheduleSearch(query, delay: 0) }
            return
        }
        indexCancellation?.cancel()
        indexCancellation = nil
        indexTask = nil
        indexPending = false
        searchTask?.cancel()
        searchResults = nil
        indexState = .off
        // 没开过也删一次：清掉上次关闭时没删干净的旧索引。
        let index = searchIndex ?? SessionSearchIndex(catalog: catalog)
        searchIndex = nil
        Task.detached(priority: .utility) { index.destroy() }
    }

    /// 每次扫描后把索引同步到最新的会话列表；上一轮还没跑完就排队等它。
    private func updateIndex() {
        guard let index = searchIndex else { return }
        guard indexTask == nil else {
            indexPending = true
            return
        }
        let sessions = sessions
        let cancellation = CancellationFlag()
        indexCancellation = cancellation
        let reportsProgress = indexState != .ready
        indexTask = Task { [weak self] in
            let changed = await Task.detached(priority: .utility) {
                index.update(with: sessions, progress: { progress in
                    guard reportsProgress else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.searchIndex === index, self.indexState != .ready else { return }
                        self.indexState = .building(done: progress.done, total: progress.total)
                    }
                }, isCancelled: { cancellation.isCancelled })
            }.value
            guard let self, self.searchIndex === index else { return }
            self.indexTask = nil
            self.indexState = .ready
            if changed, self.isSearching { self.scheduleSearch(self.query, delay: 0) }
            if self.indexPending {
                self.indexPending = false
                self.updateIndex()
            }
        }
    }

    private func scheduleSearch(_ text: String, delay: TimeInterval) {
        searchTask?.cancel()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = searchIndex, !query.isEmpty else {
            if searchResults != nil { searchResults = nil }
            return
        }
        let sessions = sessions
        searchTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            let matches = await Task.detached(priority: .userInitiated) { index.search(query, in: sessions) }.value
            guard let self, !Task.isCancelled, self.searchIndex === index else { return }
            let results = SearchResults(query: query, matches: matches)
            if self.searchResults != results { self.searchResults = results }
        }
    }

    // MARK: Actions

    func resume(_ session: SessionSummary) async {
        if let activity = session.activity, !confirmResumeWhileActive(session, activity: activity) { return }
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

    /// 会话还开着时再继续，两个进程会同时写同一份记录：先问一句。
    private func confirmResumeWhileActive(_ session: SessionSummary, activity: SessionActivity) -> Bool {
        let tool = session.tool.displayName
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("This session is still open", "这个会话还开着", key: "sessions.resume_active.title")
        alert.informativeText = activity == .waiting
            ? L("\(tool) has it open in another terminal. Resuming here means two processes write to the same session.",
                "\(tool) 正在另一个终端里开着这个会话。在这里再继续，两边会同时写同一份记录。")
            : L("\(tool) is still working on it. Resuming here means two processes write to the same session.",
                "\(tool) 还在处理这个会话。在这里再继续，两边会同时写同一份记录。")
        alert.addButton(withTitle: L("Resume Anyway", "仍然继续", key: "sessions.resume_active.confirm"))
        alert.addButton(withTitle: L("Cancel", "取消", key: "sessions.resume_active.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
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

/// 跨线程的取消标记：后台建索引时在两个会话之间检查（App 默认 MainActor 隔离，这里显式 nonisolated）。
private nonisolated final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
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
