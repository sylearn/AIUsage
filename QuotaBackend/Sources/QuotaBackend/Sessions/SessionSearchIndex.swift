import Foundation

// MARK: - Session Center · Full-text index
// 用户开启「全文搜索」后，在 ~/Library/Caches/AIUsage/Sessions/ 建一份 SQLite FTS5 索引，搜索也能命中回复与工具调用。
// 索引的就是阅读视图显示的内容：提问、回复、工具步骤（名称、命令或路径、失败原因）。工具的原始输出（整份文件、命令输出）
// 不进索引：它会让索引膨胀数倍，常见词还会命中几乎每个会话。每条正文一行并记下序号，命中后阅读视图能跳过去。
// 分词用 trigram：中文没有空格也能按子串查。不足 3 个字的词（如「登录」）用不上 trigram 索引，退回 LIKE 逐行比对，
// 实测几十 MB 正文也在百毫秒内。
// 按会话增量更新：更新时间、提问数都没变就跳过；正在运行的会话等它停下再索引；已不在列表里的会话删掉。
// 目录 0700、文件 0600。它只是缓存，被删掉或被系统清理后会重建；关闭全文搜索时整个删除。

public struct SessionExcerpt: Hashable, Sendable {
    public enum Kind: Int, Sendable {
        case prompt = 0
        case reply = 1
        case steps = 2
    }

    /// 命中的那一条在正文里的序号（TranscriptItem.id）。
    public let itemID: Int
    public let kind: Kind
    /// 命中词前后的一小段，压成一行。
    public let text: String
}

public struct SessionSearchMatch: Hashable, Sendable {
    /// 正文里的命中；只命中了列表上看得到的标题、项目、分支时为 nil。
    public let excerpt: SessionExcerpt?
}

public struct SessionIndexProgress: Equatable, Sendable {
    public let done: Int
    public let total: Int
}

public final class SessionSearchIndex: @unchecked Sendable {
    /// 正文的解析规则或表结构变了就加一，旧索引整个重建。
    static let schemaVersion: Int64 = 1

    public static var defaultURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIUsage/Sessions/search-index.sqlite")
    }

    public let url: URL
    private let catalog: SessionCatalog
    private let lock = NSLock()
    private var db: SessionSQLite?
    private var destroyed = false

    public init(url: URL = SessionSearchIndex.defaultURL, catalog: SessionCatalog = .shared) {
        self.url = url
        self.catalog = catalog
    }

    // MARK: Update

    /// 把索引同步到这些会话，返回是否改动了索引。阻塞调用，请在后台线程调用。
    /// progress 每索引完一个会话回调一次；isCancelled 返回 true 时在两个会话之间停下。
    @discardableResult
    public func update(
        with sessions: [SessionSummary],
        progress: ((SessionIndexProgress) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) -> Bool {
        // locked 在索引已删除时返回 nil；versions 在打不开库时返回 nil。
        guard let opened = locked({ versions() }), let indexed = opened else { return false }
        let current = Set(sessions.map(\.id))
        let stale = indexed.keys.filter { !current.contains($0) }
        var changed = false
        if !stale.isEmpty {
            changed = locked { remove(stale) } ?? false
        }

        let pending = sessions.filter { $0.activity != .working && indexed[$0.id] != Self.version(of: $0) }
        for (offset, session) in pending.enumerated() {
            if isCancelled() { break }
            let rows = session.hasTranscript
                ? ((try? catalog.transcript(for: session, limit: .max, cached: false)).map(Self.rows) ?? [])
                : []
            guard locked({ replace(session, rows: rows) }) == true else { break }
            changed = true
            progress?(SessionIndexProgress(done: offset + 1, total: pending.count))
        }
        return changed
    }

    /// 索引文件（含 -wal）占用的字节数。
    public var fileSize: Int64 {
        [url.path, url.path + "-wal"].reduce(0) { total, path in
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
            return total + (size ?? 0)
        }
    }

    /// 关掉连接并删除索引文件；之后这个实例不再可用。
    public func destroy() {
        lock.lock()
        defer { lock.unlock() }
        destroyed = true
        db = nil
        Self.removeFiles(at: url)
    }

    static func version(of session: SessionSummary) -> String {
        "\(Int64(session.updatedAt.timeIntervalSince1970 * 1000))|\(session.promptCount ?? -1)|\(session.hasTranscript ? 1 : 0)"
    }

    /// 正文的每一条变成一行：提问、回复原文；一组步骤每步一行（名称、说明、失败原因）。提示不进索引。
    static func rows(_ transcript: SessionTranscript) -> [(position: Int, kind: SessionExcerpt.Kind, text: String)] {
        transcript.items.compactMap { item in
            switch item.entry {
            case .prompt(let text):
                return (item.id, .prompt, text)
            case .reply(let text):
                return (item.id, .reply, text)
            case .steps(let steps):
                let lines = steps.map { step in
                    [step.name, step.detail, step.failureNote ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
                }
                return (item.id, .steps, lines.joined(separator: "\n"))
            case .notice:
                return nil
            }
        }
    }

    private func versions() -> [String: String]? {
        guard let db = connection() else { return nil }
        var result: [String: String] = [:]
        db.query("SELECT key, version FROM sessions") { row in
            if let key = row.string("key"), let version = row.string("version") { result[key] = version }
        }
        return result
    }

    private func remove(_ keys: [String]) -> Bool {
        guard let db = connection(), db.execute("BEGIN") else { return false }
        for key in keys {
            db.execute("DELETE FROM items WHERE session = ?", [.text(key)])
            db.execute("DELETE FROM sessions WHERE key = ?", [.text(key)])
        }
        return db.execute("COMMIT")
    }

    private func replace(_ session: SessionSummary, rows: [(position: Int, kind: SessionExcerpt.Kind, text: String)]) -> Bool {
        guard let db = connection(), db.execute("BEGIN") else { return false }
        var ok = db.execute("DELETE FROM items WHERE session = ?", [.text(session.id)])
        for row in rows where ok && !row.text.isEmpty {
            ok = db.execute("INSERT INTO items (session, position, kind, text) VALUES (?, ?, ?, ?)", [
                .text(session.id), .int64(Int64(row.position)), .int64(Int64(row.kind.rawValue)), .text(row.text)
            ])
        }
        ok = ok && db.execute("INSERT OR REPLACE INTO sessions (key, version) VALUES (?, ?)", [
            .text(session.id), .text(Self.version(of: session))
        ])
        guard ok, db.execute("COMMIT") else {
            db.execute("ROLLBACK")
            return false
        }
        return true
    }

    // MARK: Search

    /// 多个关键词之间是「且」：每个词要么出现在列表信息（标题、目录、分支、ID、提问）里，要么出现在正文里。
    /// 返回匹配的会话（以 SessionSummary.id 为键）；索引还没建完时只会少，不会错。
    public func search(_ query: String, in sessions: [SessionSummary]) -> [String: SessionSearchMatch] {
        let terms = Self.terms(query)
        guard !terms.isEmpty else { return [:] }
        let emptyHits: [[String: Int]] = terms.map { _ in [:] }
        let hits: [[String: Int]] = locked { terms.map { contentHits($0) } } ?? emptyHits

        var result: [String: SessionSearchMatch] = [:]
        for session in sessions {
            var excerptHit: (term: String, position: Int)?
            var matched = true
            for (index, term) in terms.enumerated() {
                let position = hits[index][session.id]
                guard position != nil || session.searchText.contains(term) else {
                    matched = false
                    break
                }
                if excerptHit == nil, let position, !Self.isVisible(term, in: session) {
                    excerptHit = (term, position)
                }
            }
            guard matched else { continue }
            var found: SessionExcerpt?
            if let hit = excerptHit, let fetched = locked({ self.excerpt(session: session.id, position: hit.position, term: hit.term) }) {
                found = fetched
            }
            result[session.id] = SessionSearchMatch(excerpt: found)
        }
        return result
    }

    static func terms(_ query: String) -> [String] {
        var seen = Set<String>()
        return query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init).filter { seen.insert($0).inserted }
    }

    /// 词已经出现在列表行上（标题、项目目录、分支），不必再给摘录。
    private static func isVisible(_ term: String, in session: SessionSummary) -> Bool {
        [session.title, session.directory ?? "", session.gitBranch ?? ""].contains { $0.lowercased().contains(term) }
    }

    /// 正文里含这个词的会话 → 最早命中的条目序号。
    private func contentHits(_ term: String) -> [String: Int] {
        guard let db = connection() else { return [:] }
        let sql: String
        let value: String
        if term.unicodeScalars.count >= 3 {
            sql = """
                SELECT i.session AS session, MIN(i.position) AS position
                FROM items_fts JOIN items i ON i.id = items_fts.rowid
                WHERE items_fts MATCH ? GROUP BY i.session
                """
            value = "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        } else {
            sql = "SELECT session, MIN(position) AS position FROM items WHERE text LIKE ? ESCAPE '\\' GROUP BY session"
            let escaped = term.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            value = "%" + escaped + "%"
        }
        var result: [String: Int] = [:]
        db.query(sql, [.text(value)]) { row in
            if let session = row.string("session"), let position = row.int64("position") { result[session] = Int(position) }
        }
        return result
    }

    private func excerpt(session: String, position: Int, term: String) -> SessionExcerpt? {
        guard let db = connection() else { return nil }
        var found: SessionExcerpt?
        db.query("SELECT kind, text FROM items WHERE session = ? AND position = ?", [.text(session), .int64(Int64(position))]) { row in
            guard let text = row.string("text"),
                  let kind = row.int64("kind").flatMap({ SessionExcerpt.Kind(rawValue: Int($0)) }) else { return }
            // 步骤组每步一行，摘录只取命中的那一步。
            let source = kind == .steps
                ? text.split(separator: "\n").first { $0.range(of: term, options: .caseInsensitive) != nil }.map(String.init) ?? text
                : text
            found = SessionExcerpt(itemID: position, kind: kind, text: Self.snippet(source, around: term))
        }
        return found
    }

    /// 压成一行，从命中词前一小段开始：列表只显示两行，命中词要落在第一行。
    /// 起点尽量退到词首或句读之后；离开头很近就直接从头开始。摘录按纯文本显示，去掉 Markdown 的粗体与行内代码标记
    /// （搜索词本身含这些符号时保留）。
    static func snippet(_ text: String, around term: String, before: Int = 24, length: Int = 120) -> String {
        var cleaned = text
        for mark in ["**", "`"] where !term.contains(mark) {
            cleaned = cleaned.replacingOccurrences(of: mark, with: "")
        }
        let flat = Array(cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        guard let hit = String(flat).range(of: term, options: .caseInsensitive) else {
            return flat.count > length ? String(flat.prefix(length)) + "…" : String(flat)
        }
        var start = max(0, String(flat).distance(from: String(flat).startIndex, to: hit.lowerBound) - before)
        // 退到最近的空格或中文标点之后（不认 . 和 :，免得把路径、网址拆开）。
        if let boundary = (max(0, start - 12)..<start).last(where: { " ，。；：！？、".contains(flat[$0]) }) { start = boundary + 1 }
        if start <= 8 { start = 0 }
        let end = min(flat.count, start + length)
        return (start > 0 ? "…" : "") + String(flat[start..<end]) + (end < flat.count ? "…" : "")
    }

    // MARK: Storage

    private func locked<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return destroyed ? nil : body()
    }

    /// 首次使用时打开；打不开或版本不对就删掉重建一次。只在持有锁时调用。
    private func connection() -> SessionSQLite? {
        if let db { return db }
        for attempt in 0..<2 {
            if let opened = open(), Self.prepare(opened) {
                db = opened
                return opened
            }
            if attempt == 0 { Self.removeFiles(at: url) }
        }
        return nil
    }

    private func open() -> SessionSQLite? {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !fileManager.fileExists(atPath: url.path) {
            // 先以 0600 建空文件：SQLite 会沿用数据库文件的权限创建 -wal / -shm。
            guard fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
        }
        return SessionSQLite.writable(path: url.path)
    }

    private static func prepare(_ db: SessionSQLite) -> Bool {
        var version: Int64 = 0
        db.query("PRAGMA user_version") { version = $0.int64("user_version") ?? 0 }
        guard version == 0 || version == schemaVersion else { return false }
        return db.execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS sessions (key TEXT PRIMARY KEY, version TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS items (
              id INTEGER PRIMARY KEY,
              session TEXT NOT NULL,
              position INTEGER NOT NULL,
              kind INTEGER NOT NULL,
              text TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS items_session ON items (session, position);
            CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(text, content='items', content_rowid='id', tokenize='trigram');
            CREATE TRIGGER IF NOT EXISTS items_insert AFTER INSERT ON items BEGIN
              INSERT INTO items_fts (rowid, text) VALUES (new.id, new.text);
            END;
            CREATE TRIGGER IF NOT EXISTS items_delete AFTER DELETE ON items BEGIN
              INSERT INTO items_fts (items_fts, rowid, text) VALUES ('delete', old.id, old.text);
            END;
            PRAGMA user_version = \(schemaVersion);
            """)
    }

    private static func removeFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}
