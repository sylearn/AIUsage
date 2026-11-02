import Foundation

// MARK: - Session Center · OpenCode
// 三种存储都读：
//   • 旧版 JSON：storage/session/<project>/<id>.json，storage/message/<session>/*.json，storage/part/<message>/*.json
//   • opencode.db v1：session / message / part 表（data 列与 JSON 文件同形）
//   • opencode.db v2：session_v2 / session_message（工具调用内联在 data.content）/ session_part
// 表结构按列探测；parent_id 非空的子会话与已归档会话不列出；JSON 与数据库重复的会话以数据库为准。
// 「进行中」只看 v1 数据库：最后一条消息是还没完成（没有 time.completed）的助手消息，且在 30 分钟内。
// 旧版 JSON 存储原地改写消息文件、目录修改时间不变，扫描缓存看不到消息完成，不做判断；v2 的完成标记还没有样本。

final class OpenCodeSessionSource {
    private let environment: SessionEnvironment
    private var jsonCache: [String: (key: [FileFingerprint?], summary: SessionSummary?)] = [:]
    private var databaseKey: [FileFingerprint?] = []
    private var databaseCached: [SessionSummary] = []
    /// 数据库里最后一条消息还没完成的会话，及那条消息的开始时间。
    private var databaseOpenSince: [String: Date] = [:]

    init(environment: SessionEnvironment) {
        self.environment = environment
    }

    func scan(now: Date = Date()) -> [SessionSummary] {
        let dataDirectory = environment.openCodeDataDirectory
        var byID: [String: SessionSummary] = [:]
        for summary in scanJSON(storageRoot: (dataDirectory as NSString).appendingPathComponent("storage")) {
            byID[summary.sessionID] = summary
        }
        for var summary in scanDatabase(path: (dataDirectory as NSString).appendingPathComponent("opencode.db")) {
            if let since = databaseOpenSince[summary.sessionID], now.timeIntervalSince(since) < SessionText.activityWindow {
                summary.activity = .working
            }
            byID[summary.sessionID] = summary
        }
        return Array(byID.values)
    }

    // MARK: JSON storage

    private func scanJSON(storageRoot: String) -> [SessionSummary] {
        let sessionRoot = (storageRoot as NSString).appendingPathComponent("session")
        let fileManager = FileManager.default
        guard let projects = try? fileManager.contentsOfDirectory(atPath: sessionRoot) else {
            jsonCache.removeAll()
            return []
        }
        var fresh: [String: (key: [FileFingerprint?], summary: SessionSummary?)] = [:]
        for project in projects {
            let projectPath = (sessionRoot as NSString).appendingPathComponent(project)
            guard let files = try? fileManager.contentsOfDirectory(atPath: projectPath) else { continue }
            for file in files where file.hasSuffix(".json") {
                let path = (projectPath as NSString).appendingPathComponent(file)
                let sessionID = (file as NSString).deletingPathExtension
                let messageDirectory = (storageRoot as NSString).appendingPathComponent("message/\(sessionID)")
                let key = [FileFingerprint(path: path), FileFingerprint(path: messageDirectory)]
                if let cached = jsonCache[path], cached.key == key {
                    fresh[path] = cached
                } else {
                    fresh[path] = (key, summarizeJSON(sessionPath: path, storageRoot: storageRoot))
                }
            }
        }
        jsonCache = fresh
        return fresh.values.compactMap(\.summary)
    }

    private func summarizeJSON(sessionPath: String, storageRoot: String) -> SessionSummary? {
        guard let info = SessionJSON.object(atPath: sessionPath),
              let id = info["id"] as? String, !id.isEmpty,
              info["parentID"] == nil else { return nil }
        let time = info["time"] as? [String: Any]
        guard time?["archived"] == nil else { return nil }

        var aggregate = Aggregate()
        for message in Self.jsonMessages(sessionID: id, storageRoot: storageRoot) {
            let parts = message.role == "user" ? Self.jsonParts(messageID: message.id, storageRoot: storageRoot) : []
            aggregate.add(role: message.role, info: message.info, parts: parts)
        }
        let updatedAt = SessionText.date(epoch: time?["updated"]) ?? aggregate.lastDate
        return Self.makeSummary(
            id: id,
            title: info["title"] as? String,
            directory: info["directory"] as? String,
            createdAt: SessionText.date(epoch: time?["created"]),
            updatedAt: updatedAt,
            aggregate: aggregate,
            tokens: aggregate.tokens,
            locator: .openCodeJSON(storageRoot: storageRoot)
        )
    }

    private struct JSONMessage {
        let id: String
        let role: String
        let info: [String: Any]
        let created: Double
    }

    private static func jsonMessages(sessionID: String, storageRoot: String) -> [JSONMessage] {
        let directory = (storageRoot as NSString).appendingPathComponent("message/\(sessionID)")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return files.filter { $0.hasSuffix(".json") }.compactMap { file -> JSONMessage? in
            guard let info = SessionJSON.object(atPath: (directory as NSString).appendingPathComponent(file)),
                  let id = info["id"] as? String, let role = info["role"] as? String else { return nil }
            let created = ((info["time"] as? [String: Any])?["created"] as? NSNumber)?.doubleValue ?? 0
            return JSONMessage(id: id, role: role, info: info, created: created)
        }
        .sorted { ($0.created, $0.id) < ($1.created, $1.id) }
    }

    private static func jsonParts(messageID: String, storageRoot: String) -> [[String: Any]] {
        let directory = (storageRoot as NSString).appendingPathComponent("part/\(messageID)")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        // 部件 ID 按时间递增（prt_…），按文件名排序即调用顺序。
        return files.filter { $0.hasSuffix(".json") }.sorted()
            .compactMap { SessionJSON.object(atPath: (directory as NSString).appendingPathComponent($0)) }
    }

    // MARK: Database

    private func scanDatabase(path: String) -> [SessionSummary] {
        let key = SessionSQLite.fingerprint(path)
        guard key.first.flatMap({ $0 }) != nil else {
            databaseKey = []
            databaseCached = []
            databaseOpenSince = [:]
            return []
        }
        if key == databaseKey { return databaseCached }
        let (summaries, openSince) = Self.readDatabase(path: path)
        databaseKey = key
        databaseCached = summaries
        databaseOpenSince = openSince
        return summaries
    }

    static func layout(of db: SessionSQLite) -> OpenCodeSessionLayout? {
        if db.tableExists("session_v2"), db.tableExists("session_message") { return .v2 }
        if db.tableExists("session"), db.tableExists("message") { return .v1 }
        return nil
    }

    private static func readDatabase(path: String) -> (summaries: [SessionSummary], openSince: [String: Date]) {
        guard let db = SessionSQLite(path: path), let layout = layout(of: db) else { return ([], [:]) }
        let table = layout == .v2 ? "session_v2" : "session"
        let columns = db.columns(of: table)
        guard columns.contains("id") else { return ([], [:]) }
        let wanted = [
            "id", "title", "directory", "parent_id", "time_created", "time_updated", "time_archived",
            "tokens_input", "tokens_output", "tokens_reasoning", "tokens_cache_read", "tokens_cache_write"
        ].filter(columns.contains)
        let aggregates = layout == .v2 ? v2Aggregates(db) : v1Aggregates(db)

        var summaries: [SessionSummary] = []
        var openSince: [String: Date] = [:]
        db.query("SELECT \(wanted.joined(separator: ", ")) FROM \(table)") { row in
            guard let id = row.string("id"), !id.isEmpty,
                  row.string("parent_id")?.isEmpty ?? true,
                  row.int64("time_archived") == nil else { return }
            let aggregate = aggregates[id] ?? Aggregate()
            let columnTokens = ["tokens_input", "tokens_output", "tokens_reasoning", "tokens_cache_read", "tokens_cache_write"]
                .compactMap { row.int64($0) }.reduce(0, +)
            let summary = makeSummary(
                id: id,
                title: row.string("title"),
                directory: row.string("directory"),
                createdAt: SessionText.date(epoch: row.int64("time_created").map { NSNumber(value: $0) }),
                updatedAt: SessionText.date(epoch: row.int64("time_updated").map { NSNumber(value: $0) }) ?? aggregate.lastDate,
                aggregate: aggregate,
                tokens: columnTokens > 0 ? Int(columnTokens) : aggregate.tokens,
                locator: .openCodeDatabase(path: path, layout: layout)
            )
            if let summary {
                summaries.append(summary)
                if layout == .v1, let latest = aggregate.latest, latest.open { openSince[id] = latest.date }
            }
        }
        return (summaries, openSince)
    }

    private static func v1Aggregates(_ db: SessionSQLite) -> [String: Aggregate] {
        var aggregates: [String: Aggregate] = [:]
        var sessionByUserMessage: [String: String] = [:]
        var pendingUser: [(messageID: String, sessionID: String, info: [String: Any])] = []
        db.query("SELECT id, session_id, data FROM message ORDER BY time_created, id") { row in
            guard let sessionID = row.string("session_id"), let info = SessionJSON.object(row.string("data")) else { return }
            let role = info["role"] as? String ?? ""
            if role == "user", let messageID = row.string("id") {
                sessionByUserMessage[messageID] = sessionID
                pendingUser.append((messageID, sessionID, info))
            } else {
                aggregates[sessionID, default: Aggregate()].add(role: role, info: info, parts: [])
            }
        }
        // 用户提问的文字在 part 表；没有 message_id 列时只计数不取文字。
        var partsByMessage: [String: [[String: Any]]] = [:]
        if db.columns(of: "part").contains("message_id") {
            db.query("SELECT message_id, data FROM part WHERE data LIKE '%\"type\":\"text\"%' ORDER BY id") { row in
                guard let messageID = row.string("message_id"), sessionByUserMessage[messageID] != nil,
                      let part = SessionJSON.object(row.string("data")) else { return }
                partsByMessage[messageID, default: []].append(part)
            }
        }
        for user in pendingUser {
            aggregates[user.sessionID, default: Aggregate()].add(role: "user", info: user.info, parts: partsByMessage[user.messageID] ?? [])
        }
        return aggregates
    }

    private static func v2Aggregates(_ db: SessionSQLite) -> [String: Aggregate] {
        var aggregates: [String: Aggregate] = [:]
        db.query("SELECT session_id, type, data, time_created FROM session_message ORDER BY session_id, time_created") { row in
            guard let sessionID = row.string("session_id"), var info = SessionJSON.object(row.string("data")) else { return }
            if info["time"] == nil, let created = row.int64("time_created") {
                info["time"] = ["created": NSNumber(value: created)]
            }
            let role = row.string("type") ?? ""
            aggregates[sessionID, default: Aggregate()].add(role: role, info: info, parts: contentParts(info))
        }
        return aggregates
    }

    // MARK: Summary helpers

    /// 一个会话的提问数、搜索文本、模型、token 与最后活动时间。
    struct Aggregate {
        var prompts = 0
        var firstPrompt: String?
        var search = SessionText.SearchBuffer()
        var model: String?
        var tokenSum = 0
        var lastDate: Date?
        /// 时间最晚的一条消息：开始时间，以及它是不是还没完成的助手消息。
        var latest: (date: Date, open: Bool)?

        var tokens: Int? { tokenSum > 0 ? tokenSum : nil }

        mutating func add(role: String, info: [String: Any], parts: [[String: Any]]) {
            let time = info["time"] as? [String: Any]
            if let date = SessionText.date(epoch: time?["created"]) {
                lastDate = max(lastDate ?? date, date)
                if latest.map({ date >= $0.date }) ?? true {
                    let open = role == "assistant" && time?["completed"] == nil && info["error"] == nil
                    latest = (date, open)
                }
            }
            if role == "user" {
                prompts += 1
                let text = OpenCodeSessionSource.promptText(info: info, parts: parts)
                if let text, !text.isEmpty {
                    firstPrompt = firstPrompt ?? text
                    search.append(text)
                }
            } else if role == "assistant" {
                if let name = OpenCodeSessionSource.modelName(info) { model = name }
                if let tokens = info["tokens"] as? [String: Any] {
                    let cache = tokens["cache"] as? [String: Any]
                    tokenSum += ["input", "output", "reasoning"].compactMap { SessionJSON.int(tokens[$0]) }.reduce(0, +)
                    tokenSum += ["read", "write"].compactMap { SessionJSON.int(cache?[$0]) }.reduce(0, +)
                }
            }
        }
    }

    static func makeSummary(
        id: String, title: String?, directory: String?, createdAt: Date?, updatedAt: Date?,
        aggregate: Aggregate, tokens: Int?, locator: SessionLocator
    ) -> SessionSummary? {
        guard aggregate.prompts > 0, let updatedAt else { return nil }
        let explicitTitle = title.map { SessionText.title(fromPrompt: $0) }.flatMap { isPlaceholderTitle($0) ? nil : $0 }
        let resolvedTitle = explicitTitle ?? SessionText.title(fromPrompt: aggregate.firstPrompt ?? id)
        let directory = directory.flatMap { $0.isEmpty ? nil : $0 }
        var search = SessionText.SearchBuffer()
        search.append([resolvedTitle, directory, id].compactMap { $0 }.joined(separator: " "))
        search.append(aggregate.search.text)
        return SessionSummary(
            tool: .opencode,
            sessionID: id,
            title: resolvedTitle,
            directory: directory,
            gitBranch: nil,
            model: aggregate.model,
            createdAt: createdAt,
            updatedAt: updatedAt,
            promptCount: aggregate.prompts,
            tokens: tokens,
            isPinned: false,
            hasTranscript: true,
            resumeBlocker: directory.map { FileManager.default.fileExists(atPath: $0) } == true ? nil : .directoryMissing,
            searchText: search.text,
            locator: locator
        )
    }

    // MARK: Transcript

    static func transcript(summary: SessionSummary, home: String, limit: Int = TranscriptBuilder.renderLimit) throws -> SessionTranscript {
        var builder = TranscriptBuilder()
        let base = summary.directory
        switch summary.locator {
        case .openCodeJSON(let storageRoot):
            let messages = jsonMessages(sessionID: summary.sessionID, storageRoot: storageRoot)
            guard !messages.isEmpty else { throw SessionTranscriptError.unavailable }
            for message in messages {
                let parts = jsonParts(messageID: message.id, storageRoot: storageRoot)
                append(role: message.role, info: message.info, parts: parts, base: base, home: home, to: &builder)
            }
        case .openCodeDatabase(let path, let layout):
            guard let db = SessionSQLite(path: path) else { throw SessionTranscriptError.unreadable }
            let found = layout == .v2
                ? appendV2(db: db, sessionID: summary.sessionID, base: base, home: home, to: &builder)
                : appendV1(db: db, sessionID: summary.sessionID, base: base, home: home, to: &builder)
            guard found else { throw SessionTranscriptError.unavailable }
        default:
            throw SessionTranscriptError.unavailable
        }
        return builder.build(limit: limit)
    }

    private static func appendV1(db: SessionSQLite, sessionID: String, base: String?, home: String, to builder: inout TranscriptBuilder) -> Bool {
        var messages: [(id: String, info: [String: Any])] = []
        db.query("SELECT id, data, time_created FROM message WHERE session_id = ? ORDER BY time_created, id", [.text(sessionID)]) { row in
            guard let id = row.string("id"), var info = SessionJSON.object(row.string("data")) else { return }
            if info["time"] == nil, let created = row.int64("time_created") {
                info["time"] = ["created": NSNumber(value: created)]
            }
            messages.append((id, info))
        }
        guard !messages.isEmpty else { return false }
        var partsByMessage: [String: [[String: Any]]] = [:]
        let partColumns = db.columns(of: "part")
        if partColumns.contains("message_id") {
            let filter = partColumns.contains("session_id")
                ? "session_id = ?"
                : "message_id IN (SELECT id FROM message WHERE session_id = ?)"
            db.query("SELECT message_id, data FROM part WHERE \(filter) ORDER BY id", [.text(sessionID)]) { row in
                guard let messageID = row.string("message_id"), let part = SessionJSON.object(row.string("data")) else { return }
                partsByMessage[messageID, default: []].append(part)
            }
        }
        for message in messages {
            let role = message.info["role"] as? String ?? ""
            append(role: role, info: message.info, parts: partsByMessage[message.id] ?? [], base: base, home: home, to: &builder)
        }
        return true
    }

    private static func appendV2(db: SessionSQLite, sessionID: String, base: String?, home: String, to builder: inout TranscriptBuilder) -> Bool {
        var messages: [(id: String, role: String, info: [String: Any])] = []
        let order = db.columns(of: "session_message").contains("seq") ? "seq" : "time_created"
        db.query("SELECT id, type, data, time_created FROM session_message WHERE session_id = ? ORDER BY \(order)", [.text(sessionID)]) { row in
            guard let id = row.string("id"), var info = SessionJSON.object(row.string("data")) else { return }
            if info["time"] == nil, let created = row.int64("time_created") {
                info["time"] = ["created": NSNumber(value: created)]
            }
            messages.append((id, row.string("type") ?? "", info))
        }
        guard !messages.isEmpty else { return false }
        var partsByMessage: [String: [[String: Any]]] = [:]
        if db.tableExists("session_part") {
            db.query("SELECT message_id, data, type FROM session_part WHERE session_id = ? ORDER BY message_id, ordinal", [.text(sessionID)]) { row in
                guard let messageID = row.string("message_id"), var part = SessionJSON.object(row.string("data")) else { return }
                if part["type"] == nil { part["type"] = row.string("type") }
                partsByMessage[messageID, default: []].append(part)
            }
        }
        for message in messages {
            let parts = partsByMessage[message.id] ?? contentParts(message.info)
            append(role: message.role, info: message.info, parts: parts, base: base, home: home, to: &builder)
        }
        return true
    }

    /// 一条消息（JSON / v1 / v2 共用）写进正文。
    private static func append(role: String, info: [String: Any], parts: [[String: Any]], base: String?, home: String, to builder: inout TranscriptBuilder) {
        let date = SessionText.date(epoch: (info["time"] as? [String: Any])?["created"])
        if role == "user" {
            if let text = promptText(info: info, parts: parts) {
                builder.prompt(SessionText.clean(text), date: date)
            }
            return
        }
        guard role == "assistant" else { return }
        for part in parts {
            switch part["type"] as? String {
            case "text":
                guard part["synthetic"] as? Bool != true else { continue }
                builder.reply(SessionText.clean(part["text"] as? String ?? ""), date: date)
            case "tool":
                let state = part["state"] as? [String: Any]
                var step = ToolStepFactory.make(
                    name: (part["tool"] ?? part["name"]) as? String ?? "",
                    input: state?["input"] as? [String: Any] ?? [:],
                    base: base,
                    home: home
                )
                if (state?["status"] as? String)?.lowercased() == "error" {
                    step.failed = true
                    step.failureNote = (state?["error"] as? String).map { SessionText.oneLine($0, limit: 200) }
                }
                builder.step(step, date: date)
            default:
                // reasoning、step-start、step-finish、patch、snapshot 不进入正文。
                break
            }
        }
        if let error = info["error"] as? [String: Any], (error["name"] as? String)?.contains("Abort") == true {
            builder.notice(.interrupted, date: date)
        }
    }

    // MARK: Field helpers

    /// OpenCode 在生成标题前用「New session - <ISO 时间>」占位（子会话为 Child session）。
    static func isPlaceholderTitle(_ title: String) -> Bool {
        title.isEmpty || title.hasPrefix("New session - ") || title.hasPrefix("Child session - ")
    }

    static func promptText(info: [String: Any], parts: [[String: Any]]) -> String? {
        var texts = parts.compactMap { part -> String? in
            switch part["type"] as? String {
            case "text": return part["synthetic"] as? Bool == true ? nil : part["text"] as? String
            case "file": return "[" + ((part["filename"] as? String) ?? "file") + "]"
            default: return nil
            }
        }
        if texts.isEmpty, let text = info["text"] as? String { texts = [text] }
        if texts.isEmpty, let content = info["content"] as? String { texts = [content] }
        let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// v2 把内容内联在 data.content；字符串内容视为一段文字。
    static func contentParts(_ info: [String: Any]) -> [[String: Any]] {
        if let content = info["content"] as? [[String: Any]] { return content }
        if let text = info["content"] as? String { return [["type": "text", "text": text]] }
        return []
    }

    static func modelName(_ info: [String: Any]) -> String? {
        if let id = info["modelID"] as? String, !id.isEmpty { return id }
        if let model = info["model"] as? [String: Any] {
            return ((model["modelID"] ?? model["id"]) as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return (info["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
