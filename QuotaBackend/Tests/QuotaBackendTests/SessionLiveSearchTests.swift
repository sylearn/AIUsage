import Darwin
import Foundation
import SQLite3
import XCTest
@testable import QuotaBackend

/// 会话中心的实时更新与全文搜索：增量解析、「进行中」、全文索引、文件监听。
final class SessionLiveSearchTests: XCTestCase {
    private var home: String!
    private let claudeID = "11111111-2222-4333-8444-555555555555"

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "session-live-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home + "/app/sub", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    private var claudeFile: String { home + "/.claude/projects/-Users-test-app/\(claudeID).jsonl" }

    // MARK: Line reader

    func testLineReaderStopsBeforeAHalfWrittenLine() throws {
        let path = home + "/lines.jsonl"
        try (#"{"type":"user","n":1}"# + "\n" + #"{"type":"user","n":2}"# + "\n" + #"{"type":"user","n":"#)
            .write(toFile: path, atomically: true, encoding: .utf8)

        var seen: [Int] = []
        let accept: (Data) -> Bool = { line in
            guard let n = SessionJSON.int(SessionJSON.object(line)?["n"]) else { return false }
            seen.append(n)
            return true
        }
        let first = try XCTUnwrap(SessionLineReader.read(path: path, needles: [], maxLineBytes: 1024, onLine: accept))
        XCTAssertEqual(seen, [1, 2])
        XCTAssertEqual(first, UInt64(#"{"type":"user","n":1}"#.utf8.count * 2 + 2), "半行不算读过")

        try append("3}\n{\"type\":\"user\",\"n\":4}", to: path)
        let second = try XCTUnwrap(SessionLineReader.read(path: path, from: first, needles: [], maxLineBytes: 1024, onLine: accept))
        XCTAssertEqual(seen, [1, 2, 3, 4], "补完的行只读一次；末尾没有换行但完整的记录也算")
        XCTAssertEqual(second, try fileSize(path))
        XCTAssertNil(SessionLineReader.read(path: home + "/missing", needles: [], maxLineBytes: 10) { _ in true })
    }

    // MARK: Claude incremental parsing

    func testClaudeAppendedRecordsParseIncrementallyLikeAFullRead() throws {
        try installClaudeFixture()
        let catalog = catalog()
        let before = try XCTUnwrap(catalog.scan().first)
        _ = try catalog.transcript(for: before)

        try append("""
            {"type":"user","cwd":"\(home!)/app","timestamp":"2026-10-30T10:00:00.000Z","message":{"role":"user","content":"Ship it"}}
            {"type":"assistant","cwd":"\(home!)/app","timestamp":"2026-10-30T10:00:05.000Z","message":{"id":"msg_9","model":"claude-opus-5-5","content":[{"type":"text","text":"Shipped."}],"usage":{"input_tokens":1,"output_tokens":1}}}

            """, to: claudeFile)

        let incremental = try XCTUnwrap(catalog.scan().first)
        let fresh = self.catalog()
        let full = try XCTUnwrap(fresh.scan().first)
        XCTAssertEqual(incremental, full)
        XCTAssertEqual(incremental.promptCount, 5)
        XCTAssertEqual(incremental.tokens, 140)
        XCTAssertTrue(incremental.matches("ship it"))
        XCTAssertEqual(try catalog.transcript(for: incremental), try fresh.transcript(for: full))
        XCTAssertEqual(try catalog.transcript(for: incremental).items.last?.entry, .reply("Shipped."))
    }

    func testClaudeRewrittenFileIsReadFromTheStart() throws {
        try installClaudeFixture()
        let catalog = catalog()
        let session = try XCTUnwrap(catalog.scan().first)
        _ = try catalog.transcript(for: session)

        // 原地截短重写（inode 不变、文件变小）。
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: claudeFile))
        try handle.truncate(atOffset: 0)
        handle.write(Data("""
            {"type":"user","cwd":"\(home!)/app","timestamp":"2026-10-31T08:00:00.000Z","message":{"role":"user","content":"Brand new"}}

            """.utf8))
        try handle.close()

        let rewritten = try XCTUnwrap(catalog.scan().first)
        XCTAssertEqual(rewritten.title, "Brand new")
        XCTAssertEqual(rewritten.promptCount, 1)
        XCTAssertEqual(try catalog.transcript(for: rewritten).items.map(\.entry), [.prompt("Brand new")])

        // 换成另一个文件（新 inode），即使更大也要从头读。
        try String(repeating: """
            {"type":"user","cwd":"\(home!)/app","timestamp":"2026-11-01T08:00:00.000Z","message":{"role":"user","content":"Replaced"}}

            """, count: 3).write(toFile: claudeFile, atomically: true, encoding: .utf8)
        let replaced = try XCTUnwrap(catalog.scan().first)
        XCTAssertEqual(replaced.promptCount, 3)
        XCTAssertEqual(replaced.title, "Replaced")
    }

    // MARK: Activity

    func testClaudeRegistryMarksSessionsOpenInALiveProcess() throws {
        try installClaudeFixture()
        let started = try XCTUnwrap(ClaudeSessionRegistry.startTime(of: getpid()))
        try register(pid: Int(getpid()), status: "busy", procStart: ctime(started))
        XCTAssertEqual(catalog().scan().first?.activity, .working)

        try register(pid: Int(getpid()), status: "idle", procStart: ctime(started))
        XCTAssertEqual(catalog().scan().first?.activity, .waiting)

        try register(pid: Int(getpid()), status: "busy", procStart: "Mon Jan  1 00:00:00 2001")
        XCTAssertNil(catalog().scan().first?.activity, "PID 被别的进程复用了")

        try register(pid: Int(Int32.max - 1), status: "busy", procStart: nil)
        XCTAssertNil(catalog().scan().first?.activity, "进程已退出，登记文件是残留")

        try register(pid: Int(getpid()), status: "busy", procStart: ctime(started), parked: true)
        XCTAssertNil(catalog().scan().first?.activity, "转入后台的会话不算")
    }

    func testProcStartParsesThePaddedCtimeFormat() throws {
        let date = try XCTUnwrap(ClaudeSessionRegistry.parseProcStart("Mon Nov  2 01:12:05 2026"))
        XCTAssertEqual(date, SessionText.date(iso: "2026-11-02T01:12:05Z"))
    }

    func testCodexInProgressTurnIsWorkingOnlyWhileRecent() throws {
        let codex = home + "/.codex"
        try FileManager.default.createDirectory(atPath: codex, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_793_500_000)
        let ids = ["019a0000-0000-7000-8000-00000000000a", "019a0000-0000-7000-8000-00000000000b", "019a0000-0000-7000-8000-00000000000c"]
        let state = try openWritable(codex + "/state_5.sqlite")
        try exec(state, "CREATE TABLE threads (id TEXT, title TEXT, first_user_message TEXT, updated_at_ms INTEGER)")
        for id in ids {
            try exec(state, "INSERT INTO threads VALUES ('\(id)', 't', 'ask', \(Int64(now.timeIntervalSince1970 * 1000)))")
        }
        sqlite3_close(state)

        let history = try openWritable(codex + "/thread_history_1.sqlite")
        let ms = { (date: Date) in Int64(date.timeIntervalSince1970 * 1000) }
        try exec(history, """
            CREATE TABLE thread_items (thread_id TEXT, turn_id TEXT, item_id TEXT, rollout_ordinal INTEGER,
              created_at_ms INTEGER, item_json TEXT, item_type TEXT);
            CREATE TABLE thread_turns (thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER, status TEXT,
              started_at INTEGER, completed_at INTEGER);
            INSERT INTO thread_turns VALUES ('\(ids[0])', 'a1', 1, 'completed', \(Int(now.timeIntervalSince1970) - 900), \(Int(now.timeIntervalSince1970) - 800));
            INSERT INTO thread_turns VALUES ('\(ids[0])', 'a2', 2, 'inProgress', \(Int(now.timeIntervalSince1970) - 3000), NULL);
            INSERT INTO thread_items VALUES ('\(ids[0])', 'a2', 'i1', 3, \(ms(now.addingTimeInterval(-60))), '{}', 'commandExecution');
            INSERT INTO thread_turns VALUES ('\(ids[1])', 'b1', 1, 'inProgress', \(Int(now.timeIntervalSince1970) - 7200), NULL);
            INSERT INTO thread_turns VALUES ('\(ids[2])', 'c1', 1, 'inProgress', NULL, NULL);
            INSERT INTO thread_turns VALUES ('\(ids[2])', 'c2', 2, 'completed', \(Int(now.timeIntervalSince1970) - 30), \(Int(now.timeIntervalSince1970) - 10));
            """)
        sqlite3_close(history)

        let source = CodexSessionSource(environment: environment())
        let activity = Dictionary(uniqueKeysWithValues: source.scan(now: now).map { ($0.sessionID, $0.activity) })
        XCTAssertEqual(activity[ids[0]], .working, "轮次开始得早，但最近一条条目在 1 分钟前")
        XCTAssertEqual(activity[ids[1]], .some(nil), "两小时前开始、之后没有动静：崩溃残留")
        XCTAssertEqual(activity[ids[2]], .some(nil), "最新一轮已经完成，旧的 inProgress 不算")

        let later = source.scan(now: now.addingTimeInterval(SessionText.activityWindow))
        XCTAssertNil(later.first { $0.sessionID == ids[0] }?.activity, "数据库没变也要按时过期")
    }

    func testOpenCodeDatabaseUnfinishedAssistantIsWorking() throws {
        let directory = home + "/.local/share/opencode"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_793_500_000)
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let db = try openWritable(directory + "/opencode.db")
        try exec(db, """
            CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT, time_created INTEGER,
              time_updated INTEGER, time_archived INTEGER);
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, data TEXT);
            INSERT INTO session VALUES ('ses_RUN', NULL, '\(home!)/app', 'Running', \(ms - 60000), \(ms), NULL);
            INSERT INTO session VALUES ('ses_DONE', NULL, '\(home!)/app', 'Done', \(ms - 60000), \(ms), NULL);
            INSERT INTO message VALUES ('m1', 'ses_RUN', \(ms - 60000), '{"role":"user","time":{"created":\(ms - 60000)}}');
            INSERT INTO message VALUES ('m2', 'ses_RUN', \(ms - 30000), '{"role":"assistant","time":{"created":\(ms - 30000)}}');
            INSERT INTO message VALUES ('m3', 'ses_DONE', \(ms - 60000), '{"role":"user","time":{"created":\(ms - 60000)}}');
            INSERT INTO message VALUES ('m4', 'ses_DONE', \(ms - 30000), '{"role":"assistant","time":{"created":\(ms - 30000),"completed":\(ms - 1000)}}');
            INSERT INTO part VALUES ('p1', 'm1', 'ses_RUN', '{"type":"text","text":"go"}');
            INSERT INTO part VALUES ('p3', 'm3', 'ses_DONE', '{"type":"text","text":"go"}');
            """)
        sqlite3_close(db)

        let source = OpenCodeSessionSource(environment: environment())
        let activity = Dictionary(uniqueKeysWithValues: source.scan(now: now).map { ($0.sessionID, $0.activity) })
        XCTAssertEqual(activity["ses_RUN"], .working)
        XCTAssertEqual(activity["ses_DONE"], .some(nil))
        XCTAssertNil(source.scan(now: now.addingTimeInterval(SessionText.activityWindow)).first { $0.sessionID == "ses_RUN" }?.activity)
    }

    // MARK: Full-text index

    func testIndexFindsRepliesAndToolStepsWithExcerpts() throws {
        try installClaudeFixture()
        let catalog = catalog()
        let sessions = catalog.scan()
        let index = SessionSearchIndex(url: indexURL, catalog: catalog)
        var progress: [SessionIndexProgress] = []
        XCTAssertTrue(index.update(with: sessions) { progress.append($0) })
        XCTAssertEqual(progress.last, SessionIndexProgress(done: 1, total: 1))

        let session = try XCTUnwrap(sessions.first)
        let transcript = try catalog.transcript(for: session)

        let reply = try XCTUnwrap(index.search("COMPARISON", in: sessions)[session.id]?.excerpt)
        XCTAssertEqual(reply.kind, .reply)
        XCTAssertEqual(reply.text, "Fixed the comparison.")
        XCTAssertEqual(transcript.items.first { $0.id == reply.itemID }?.entry, .reply("Fixed the comparison."),
                       "摘录的序号就是阅读视图里那一条")

        let step = try XCTUnwrap(index.search("replace", in: sessions)[session.id]?.excerpt)
        XCTAssertEqual(step.kind, .steps)
        XCTAssertEqual(step.text, "Edit Sources/Login.swift String to replace not found", "只取命中的那一步")

        XCTAssertNotNil(index.search("app comparison", in: sessions)[session.id], "一个词在目录、一个词在正文，也算命中")
        XCTAssertNil(index.search("comparison nowhere", in: sessions)[session.id])
        let titleOnly = try XCTUnwrap(index.search("renamed", in: sessions)[session.id])
        XCTAssertNil(titleOnly.excerpt, "列表上看得到的词不给摘录")
        XCTAssertTrue(index.search("   ", in: sessions).isEmpty)
    }

    func testIndexMatchesShortChineseTermsAndSpecialCharacters() throws {
        try writeClaudeSession(id: "33333333-2222-4333-8444-555555555555", prompt: "看一下这个问题", reply: "已经修复登录问题，100% 通过 a_b")
        let catalog = catalog()
        let sessions = catalog.scan()
        let index = SessionSearchIndex(url: indexURL, catalog: catalog)
        index.update(with: sessions)
        let id = try XCTUnwrap(sessions.first?.id)

        XCTAssertEqual(index.search("登录", in: sessions)[id]?.excerpt?.text, "已经修复登录问题，100% 通过 a_b", "两个字走 LIKE")
        XCTAssertNotNil(index.search("修复登录", in: sessions)[id], "三个字以上走 trigram")
        XCTAssertNotNil(index.search("0%", in: sessions)[id], "% 按字面匹配")
        XCTAssertNil(index.search("1_", in: sessions)[id], "_ 不是通配符")
        XCTAssertNotNil(index.search("a_b", in: sessions)[id])
        XCTAssertNil(index.search("\"quoted\"", in: sessions)[id], "引号不会破坏 FTS 查询")
    }

    func testIndexUpdatesIncrementallySkipsRunningSessionsAndDropsGoneOnes() throws {
        try installClaudeFixture()
        let catalog = catalog()
        let index = SessionSearchIndex(url: indexURL, catalog: catalog)
        XCTAssertTrue(index.update(with: catalog.scan()))
        XCTAssertFalse(index.update(with: catalog.scan()), "没有变化就不动索引")

        try append("""
            {"type":"assistant","cwd":"\(home!)/app","timestamp":"2026-10-30T10:00:00.000Z","message":{"id":"msg_9","content":[{"type":"text","text":"Deployed to staging."}]}}

            """, to: claudeFile)
        var running = try XCTUnwrap(catalog.scan().first)
        running.activity = .working
        XCTAssertFalse(index.update(with: [running]), "正在运行的会话等它停下再索引")
        XCTAssertNil(index.search("staging", in: [running])[running.id])

        running.activity = .waiting
        XCTAssertTrue(index.update(with: [running]))
        XCTAssertNotNil(index.search("staging", in: [running])[running.id])

        XCTAssertTrue(index.update(with: []))
        XCTAssertNil(index.search("staging", in: [running])[running.id], "会话不在了，索引里也删掉")
    }

    func testIndexRebuildsOnSchemaChangeAndIsPrivate() throws {
        try installClaudeFixture()
        let catalog = catalog()
        let sessions = catalog.scan()
        SessionSearchIndex(url: indexURL, catalog: catalog).update(with: sessions)

        let attributes = try FileManager.default.attributesOfItem(atPath: indexURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directory = try FileManager.default.attributesOfItem(atPath: indexURL.deletingLastPathComponent().path)
        XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        let db = try openWritable(indexURL.path)
        try exec(db, "PRAGMA user_version = 99")
        sqlite3_close(db)
        let rebuilt = SessionSearchIndex(url: indexURL, catalog: catalog)
        XCTAssertTrue(rebuilt.update(with: sessions), "版本不对就整个重建")
        XCTAssertNotNil(rebuilt.search("comparison", in: sessions)[sessions[0].id])

        rebuilt.destroy()
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path))
        XCTAssertFalse(rebuilt.update(with: sessions))
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path), "删除后不会被后台更新重新建出来")
    }

    func testSnippetCentersOnTheTerm() {
        let text = String(repeating: "a ", count: 40) + "needle\nhere " + String(repeating: "b ", count: 100)
        let snippet = SessionSearchIndex.snippet(text, around: "NEEDLE")
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertTrue(snippet.contains("needle here"), "换行压成空格")
        XCTAssertEqual(SessionSearchIndex.snippet("short", around: "x"), "short")
        let tail = SessionSearchIndex.snippet(String(repeating: "c ", count: 100) + "end", around: "end")
        XCTAssertTrue(tail.hasPrefix("…") && tail.hasSuffix("c end"))
        XCTAssertLessThan(tail.count, 30, "命中靠后时也从命中词前一点开始，列表两行里看得到")
        XCTAssertEqual(SessionSearchIndex.snippet("Release 构建脚本阶段，这一步耗时正常。继续等最终 `BUILD SUCCEEDED/FAILED`。", around: "failed"),
                       "…这一步耗时正常。继续等最终 BUILD SUCCEEDED/FAILED。")
    }

    // MARK: Monitor

    func testMonitorOnlyCaresAboutSessionRecords() {
        let roots = SessionSourceMonitor.Roots(claude: "/h/.claude", codex: "/h/.codex", openCode: "/h/oc")
        let relevant = [
            "/h/.claude/projects/-Users-me-app/\(claudeID).jsonl",
            "/h/.claude/projects/-Users-me-app",
            "/h/.claude/sessions/123.json",
            "/h/.codex/state_5.sqlite-wal",
            "/h/.codex/thread_history_1.sqlite",
            "/h/oc/opencode.db-wal",
            "/h/oc/storage/message/ses_1/msg_1.json"
        ]
        let temporary = SessionSourceMonitor.Roots(claude: "/var/t/.claude", codex: "", openCode: "")
        XCTAssertTrue(SessionSourceMonitor.isRelevant("/private/var/t/.claude/sessions/1.json", roots: temporary),
                      "FSEvents 报告 /private/var，根目录可能写成 /var")
        let ignored = [
            "/h/.claude/projects/-Users-me-app/\(claudeID)/subagents/agent-1.jsonl",
            "/h/.claude/projects/-Users-me-app/memory/MEMORY.md",
            "/h/.claude/sessions/123.abc.key",
            "/h/.claude/debug/log.txt",
            "/h/.codex/logs_2.sqlite-wal",
            "/h/.codex/state_5.sqlite-shm",
            "/h/.codex/sessions/2026/11/02/rollout.jsonl",
            "/h/oc/log/2026.log",
            "/h/.claudette/projects/x/y.jsonl"
        ]
        for path in relevant { XCTAssertTrue(SessionSourceMonitor.isRelevant(path, roots: roots), path) }
        for path in ignored { XCTAssertFalse(SessionSourceMonitor.isRelevant(path, roots: roots), path) }
    }

    func testMonitorReportsAnAppendedClaudeRecord() throws {
        try installClaudeFixture()
        let changed = expectation(description: "change reported")
        changed.assertForOverFulfill = false
        let monitor = SessionSourceMonitor(environment: environment(), latency: 0.1) { changed.fulfill() }
        monitor.start()
        defer { monitor.stop() }
        XCTAssertTrue(monitor.isRunning)
        // FSEvents 从 start 之后才开始记，给它一点时间接上。
        Thread.sleep(forTimeInterval: 0.3)
        try append(#"{"type":"custom-title","customTitle":"Live"}"# + "\n", to: claudeFile)
        wait(for: [changed], timeout: 10)
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
    }

    // MARK: Helpers

    private var indexURL: URL { URL(fileURLWithPath: home + "/cache/Sessions/search-index.sqlite") }

    private func environment() -> SessionEnvironment {
        SessionEnvironment(homeDirectory: home, variables: [:])
    }

    private func catalog() -> SessionCatalog {
        SessionCatalog(environment: environment())
    }

    private func installClaudeFixture() throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
            .appendingPathComponent("sessions/claude/projects/-Users-test-app/\(claudeID).jsonl")
        try FileManager.default.createDirectory(atPath: (claudeFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try String(contentsOf: source, encoding: .utf8).replacingOccurrences(of: "__HOME__", with: home)
            .write(toFile: claudeFile, atomically: true, encoding: .utf8)
    }

    private func writeClaudeSession(id: String, prompt: String, reply: String) throws {
        let directory = home + "/.claude/projects/-Users-test-app"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        // 目录固定写成 /work/app：临时目录的随机名可能恰好含有要搜的字符。
        let prompt = try JSONSerialization.data(withJSONObject: [
            "type": "user", "cwd": "/work/app", "timestamp": "2026-10-30T08:00:00.000Z",
            "message": ["role": "user", "content": prompt]
        ])
        let answer = try JSONSerialization.data(withJSONObject: [
            "type": "assistant", "cwd": "/work/app", "timestamp": "2026-10-30T08:00:05.000Z",
            "message": ["id": "m1", "content": [["type": "text", "text": reply]]]
        ])
        try (String(decoding: prompt, as: UTF8.self) + "\n" + String(decoding: answer, as: UTF8.self) + "\n")
            .write(toFile: directory + "/\(id).jsonl", atomically: true, encoding: .utf8)
    }

    private func register(pid: Int, status: String, procStart: String?, parked: Bool = false) throws {
        let directory = home + "/.claude/sessions"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var record: [String: Any] = ["pid": pid, "sessionId": claudeID, "status": status, "kind": "interactive"]
        if let procStart { record["procStart"] = procStart }
        if parked { record["parkedJobId"] = "job_1" }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for file in files { try FileManager.default.removeItem(atPath: directory + "/" + file) }
        try JSONSerialization.data(withJSONObject: record).write(to: URL(fileURLWithPath: directory + "/\(pid).json"))
    }

    /// Claude Code 写进 procStart 的格式：UTC，个位数日期前补空格。
    private func ctime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM"
        let head = formatter.string(from: date)
        formatter.dateFormat = "HH:mm:ss yyyy"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return head + " " + String(format: "%2d", calendar.component(.day, from: date)) + " " + formatter.string(from: date)
    }

    private func append(_ text: String, to path: String) throws {
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        handle.write(Data(text.utf8))
        try handle.close()
    }

    private func fileSize(_ path: String) throws -> UInt64 {
        try XCTUnwrap((FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value)
    }

    private func openWritable(_ path: String) throws -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw XCTSkip("sqlite open failed") }
        return db
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            XCTFail("SQL failed: \(message)")
            return
        }
    }
}
