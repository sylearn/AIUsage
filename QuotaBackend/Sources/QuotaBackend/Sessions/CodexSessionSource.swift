import Foundation

// MARK: - Session Center · Codex
// 列表：$CODEX_HOME 或 ~/.codex 下版本号最大的 state_<N>.sqlite 的 threads 表。
// 正文：thread_history_<N>.sqlite 的 thread_items（结构化条目，不解析会话文件）。
// Codex 会把旧会话文件压成 .jsonl.zst，而 threads.rollout_path 仍写 .jsonl，两种后缀都算「记录还在」。
// 子代理线程（source 含 subagent，如 guardian 审查）与已归档线程不列出。
// 「进行中」：线程最新一轮在 thread_turns 里是 inProgress，且最后一次动静在 30 分钟内（崩溃会留下永远 inProgress 的旧轮次）。

final class CodexSessionSource {
    private let environment: SessionEnvironment
    private var cacheKey: [FileFingerprint?] = []
    private var cached: [SessionSummary] = []
    /// 最新一轮还没结束的线程，及其最后一次动静的时间。
    private var cachedInProgress: [String: Date] = [:]

    init(environment: SessionEnvironment) {
        self.environment = environment
    }

    func scan(now: Date = Date()) -> [SessionSummary] {
        let root = environment.codexRoot
        guard let statePath = SessionSQLite.newestVersionedDatabase(in: root, prefix: "state_") else {
            cached = []
            cacheKey = []
            cachedInProgress = [:]
            return []
        }
        let historyPath = SessionSQLite.newestVersionedDatabase(in: root, prefix: "thread_history_")
        let key = SessionSQLite.fingerprint(statePath) + SessionSQLite.fingerprint(historyPath)
        if key != cacheKey {
            cached = Self.readThreads(statePath: statePath, historyPath: historyPath)
            cachedInProgress = historyPath.map(Self.inProgressThreads(historyPath:)) ?? [:]
            cacheKey = key
        }
        guard !cachedInProgress.isEmpty else { return cached }
        // 时间窗口每次扫描现算：数据库没变，残留的未完成轮次也会按时过期。
        return cached.map { summary in
            guard let last = cachedInProgress[summary.sessionID],
                  now.timeIntervalSince(last) < SessionText.activityWindow else { return summary }
            var summary = summary
            summary.activity = .working
            return summary
        }
    }

    /// 最新一轮是 inProgress 的线程 → 最后一次动静（轮次开始或最近一条条目）。
    static func inProgressThreads(historyPath: String) -> [String: Date] {
        guard let history = SessionSQLite(path: historyPath), history.tableExists("thread_turns") else { return [:] }
        let columns = history.columns(of: "thread_turns")
        guard columns.isSuperset(of: ["thread_id", "status", "rollout_ordinal"]) else { return [:] }
        let started = columns.contains("started_at") ? "t.started_at" : "NULL"
        var result: [String: Date] = [:]
        history.query("""
            SELECT t.thread_id AS thread_id, \(started) AS started_at,
                   (SELECT MAX(created_at_ms) FROM thread_items i WHERE i.thread_id = t.thread_id) AS last_item_ms
            FROM thread_turns t
            WHERE t.status = 'inProgress'
              AND t.rollout_ordinal = (SELECT MAX(rollout_ordinal) FROM thread_turns WHERE thread_id = t.thread_id)
            """) { row in
            guard let thread = row.string("thread_id") else { return }
            let dates = [
                SessionText.date(epoch: row.int64("started_at").map { NSNumber(value: $0) }),
                SessionText.date(epoch: row.int64("last_item_ms").map { NSNumber(value: $0) })
            ].compactMap { $0 }
            if let last = dates.max() { result[thread] = last }
        }
        return result
    }

    // MARK: Summary

    private static func readThreads(statePath: String, historyPath: String?) -> [SessionSummary] {
        guard let state = SessionSQLite(path: statePath), state.tableExists("threads") else { return [] }
        let columns = state.columns(of: "threads")
        guard columns.contains("id") else { return [] }
        let wanted = [
            "id", "name", "title", "first_user_message", "preview", "cwd", "git_branch", "model",
            "created_at", "created_at_ms", "updated_at", "updated_at_ms", "tokens_used", "is_pinned",
            "archived", "source", "thread_source", "rollout_path"
        ].filter(columns.contains)
        let prompts = historyPath.map(promptIndex(historyPath:)) ?? [:]

        var summaries: [SessionSummary] = []
        state.query("SELECT \(wanted.joined(separator: ", ")) FROM threads") { row in
            guard let id = row.string("id"), !id.isEmpty,
                  row.int64("archived") != 1 else { return }
            let source = (row.string("source") ?? "") + " " + (row.string("thread_source") ?? "")
            guard !source.contains("subagent"), !source.contains("guardian") else { return }

            let history = prompts[id]
            let firstMessage = row.string("first_user_message").flatMap { $0.isEmpty ? nil : $0 }
            // 没有任何提问的空线程不列出（has_user_event 列在实测中恒为 0，不可用）。
            guard firstMessage != nil || history != nil else { return }
            let title = [row.string("name"), row.string("title"), firstMessage, row.string("preview")]
                .lazy
                .compactMap { $0.map { SessionText.title(fromPrompt: $0) } }
                .first { !$0.isEmpty } ?? id
            let updatedAt = SessionText.date(epoch: row.int64("updated_at_ms").map { NSNumber(value: $0) })
                ?? SessionText.date(epoch: row.int64("updated_at").map { NSNumber(value: $0) })
            guard let updatedAt else { return }
            let createdAt = SessionText.date(epoch: row.int64("created_at_ms").map { NSNumber(value: $0) })
                ?? SessionText.date(epoch: row.int64("created_at").map { NSNumber(value: $0) })
            let directory = row.string("cwd").flatMap { $0.isEmpty ? nil : $0 }
            let branch = row.string("git_branch").flatMap { $0.isEmpty ? nil : $0 }

            var search = SessionText.SearchBuffer()
            search.append([title, directory, branch, id].compactMap { $0 }.joined(separator: " "))
            search.append(firstMessage)
            search.append(history?.search)

            summaries.append(SessionSummary(
                tool: .codex,
                sessionID: id,
                title: title,
                directory: directory,
                gitBranch: branch,
                model: row.string("model").flatMap { $0.isEmpty ? nil : $0 },
                createdAt: createdAt,
                updatedAt: updatedAt,
                promptCount: history?.count,
                tokens: row.int64("tokens_used").flatMap { $0 > 0 ? Int($0) : nil },
                isPinned: row.int64("is_pinned") == 1,
                hasTranscript: history != nil,
                resumeBlocker: recordExists(row.string("rollout_path")) ? nil : .recordMissing,
                searchText: search.text,
                locator: .codexThread(historyDatabase: historyPath)
            ))
        }
        return summaries
    }

    /// 每个线程的提问数与提问文本（搜索用）。
    private static func promptIndex(historyPath: String) -> [String: (count: Int, search: String)] {
        guard let history = SessionSQLite(path: historyPath), history.tableExists("thread_items") else { return [:] }
        var counts: [String: Int] = [:]
        var buffers: [String: SessionText.SearchBuffer] = [:]
        history.query("""
            SELECT thread_id, item_json FROM thread_items
            WHERE item_type = 'userMessage'
            ORDER BY thread_id, rollout_ordinal
            """) { row in
            guard let thread = row.string("thread_id") else { return }
            counts[thread, default: 0] += 1
            var buffer = buffers[thread] ?? SessionText.SearchBuffer()
            guard buffer.text.utf8.count < SessionText.maxSearchLength else { return }
            buffer.append(userText(SessionJSON.object(row.string("item_json"))))
            buffers[thread] = buffer
        }
        return counts.reduce(into: [:]) { result, pair in
            result[pair.key] = (pair.value, buffers[pair.key]?.text ?? "")
        }
    }

    private static func recordExists(_ rolloutPath: String?) -> Bool {
        guard let path = rolloutPath, !path.isEmpty else { return false }
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: path) || fileManager.fileExists(atPath: path + ".zst")
    }

    // MARK: Transcript

    static func transcript(threadID: String, historyPath: String?, base: String?, home: String,
                           limit: Int = TranscriptBuilder.renderLimit) throws -> SessionTranscript {
        guard let historyPath else { throw SessionTranscriptError.unavailable }
        guard let history = SessionSQLite(path: historyPath) else { throw SessionTranscriptError.unreadable }
        var builder = TranscriptBuilder()
        var found = false
        let ok = history.query("""
            SELECT item_type, item_json, created_at_ms FROM thread_items
            WHERE thread_id = ?
            ORDER BY rollout_ordinal, created_at_ms
            """, [.text(threadID)]) { row in
            found = true
            guard let item = SessionJSON.object(row.string("item_json")) else { return }
            let date = SessionText.date(epoch: row.int64("created_at_ms").map { NSNumber(value: $0) })
            append(item, type: row.string("item_type") ?? item["type"] as? String ?? "", date: date, base: base, home: home, to: &builder)
        }
        guard ok else { throw SessionTranscriptError.unreadable }
        guard found else { throw SessionTranscriptError.unavailable }
        return builder.build(limit: limit)
    }

    static func append(_ item: [String: Any], type: String, date: Date?, base: String?, home: String, to builder: inout TranscriptBuilder) {
        // 条目自带 cwd 时以它为准，否则用会话目录，路径显示为项目内相对路径。
        let base = item["cwd"] as? String ?? base
        let failed = (item["status"] as? String) == "failed"
        switch type {
        case "userMessage":
            builder.prompt(SessionText.clean(userText(item) ?? ""), date: date)
        case "agentMessage":
            builder.reply(SessionText.clean(item["text"] as? String ?? ""), date: date)
        case "commandExecution":
            builder.step(commandStep(item, base: base, home: home), date: date)
        case "fileChange":
            let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            var detail = paths.first.map { SessionText.displayPath($0, base: base, home: home) } ?? ""
            if paths.count > 1 { detail += " +\(paths.count - 1)" }
            builder.step(ToolStep(name: "Edit", detail: detail, kind: .edit, failed: failed, failureNote: nil, paths: paths), date: date)
        case "mcpToolCall":
            let server = item["server"] as? String ?? ""
            let tool = item["tool"] as? String ?? ""
            let error = errorText(item["error"])
            builder.step(ToolStep(
                name: "MCP",
                detail: [server, tool].filter { !$0.isEmpty }.joined(separator: " · "),
                kind: .mcp,
                failed: failed || error != nil,
                failureNote: error.map { SessionText.oneLine($0, limit: 200) },
                paths: []
            ), date: date)
        case "webSearch":
            let query = item["query"] as? String ?? ""
            builder.step(ToolStep(name: "Web Search", detail: SessionText.oneLine(query, limit: 160), kind: .web, failed: failed, failureNote: nil, paths: []), date: date)
        case "imageView":
            let path = item["path"] as? String ?? ""
            builder.step(ToolStep(name: "View Image", detail: SessionText.displayPath(path, base: nil, home: home), kind: .read, failed: failed, failureNote: nil, paths: []), date: date)
        case "contextCompaction":
            builder.notice(.contextCompacted, date: date)
        default:
            // reasoning、sleep、imageGeneration 等不进入正文。
            break
        }
    }

    private static func commandStep(_ item: [String: Any], base: String?, home: String) -> ToolStep {
        let actions = item["commandActions"] as? [[String: Any]] ?? []
        let command = (actions.first?["command"] as? String) ?? ToolStepFactory.commandText(item["command"]) ?? ""
        let types = Set(actions.compactMap { $0["type"] as? String })
        let paths = actions.compactMap { $0["path"] as? String }

        let kind: ToolStep.Kind
        if !types.isEmpty, types.isSubset(of: ["read"]) {
            kind = .read
        } else if !types.isEmpty, types.isSubset(of: ["search", "listFiles"]) {
            kind = .search
        } else {
            kind = .command
        }
        let exitCode = SessionJSON.int(item["exitCode"])
        let failed = (item["status"] as? String) == "failed" || (exitCode ?? 0) != 0
        let output = item["aggregatedOutput"] as? String ?? ""
        var note: String?
        if failed {
            note = SessionText.lastLine(output, limit: 200) ?? exitCode.map { "exit \($0)" }
        }
        let detail = kind == .read && !paths.isEmpty
            ? paths.map { SessionText.displayPath($0, base: base, home: home) }.joined(separator: ", ")
            : command
        return ToolStep(
            name: kind == .read ? "Read" : kind == .search ? "Search" : "Shell",
            detail: SessionText.oneLine(detail, limit: 160),
            kind: kind,
            failed: failed,
            failureNote: note,
            paths: kind == .read ? paths : []
        )
    }

    static func userText(_ item: [String: Any]?) -> String? {
        guard let content = item?["content"] as? [[String: Any]] else { return nil }
        let parts = content.compactMap { part -> String? in
            switch part["type"] as? String {
            case "text": return part["text"] as? String
            case "image", "localImage": return "[image]"
            default: return nil
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func errorText(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let object = value as? [String: Any] { return (object["message"] as? String) ?? (object["error"] as? String) }
        return nil
    }
}
