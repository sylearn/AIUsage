import Foundation
import SQLite3
import XCTest
@testable import QuotaBackend

/// 会话中心：三家 CLI 的列表、正文、继续命令与导出。
/// Claude / OpenCode JSON 用 Fixtures/sessions 下的脱敏样本，数据库在测试里现场构造。
final class SessionCatalogTests: XCTestCase {
    private var home: String!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "session-catalog-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home + "/app/sub", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    // MARK: Claude Code

    func testClaudeSummaryUsesTitlePriorityAndCountsOnlyRealPrompts() throws {
        try installFixture("claude", as: ".claude")
        let sessions = catalog().scan()

        XCTAssertEqual(sessions.count, 1, "空会话、memory 目录与子代理文件都不应列出")
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.tool, .claude)
        XCTAssertEqual(session.sessionID, "11111111-2222-4333-8444-555555555555")
        XCTAssertEqual(session.title, "Login bug (renamed)")
        XCTAssertEqual(session.promptCount, 4, "提问、斜杠命令、! 命令、带图提问；不含 meta、工具结果、命令输出与子代理")
        XCTAssertEqual(session.directory, home + "/app", "取会话开始时的目录，中途 cd 不影响")
        XCTAssertEqual(session.projectName, "app")
        XCTAssertEqual(session.gitBranch, "feat/login")
        XCTAssertEqual(session.model, "claude-opus-5-5", "<synthetic> 不覆盖真实模型")
        XCTAssertEqual(session.tokens, 138, "同一消息 ID 的重复 usage 只算一次")
        XCTAssertEqual(session.createdAt, iso("2026-10-30T08:00:00.000Z"))
        XCTAssertEqual(session.updatedAt, iso("2026-10-30T09:00:00.000Z"))
        XCTAssertNil(session.resumeBlocker)
        XCTAssertTrue(session.matches("LOGIN fix"))
        XCTAssertTrue(session.matches("git status"))
        XCTAssertFalse(session.matches("sidechain"))
        XCTAssertFalse(session.matches("blob"))
    }

    func testClaudeTranscriptGroupsStepsAndMarksFailures() throws {
        try installFixture("claude", as: ".claude")
        let catalog = catalog()
        let session = try XCTUnwrap(catalog.scan().first)
        let transcript = try catalog.transcript(for: session)

        XCTAssertEqual(transcript.items.map(\.entry), [
            .prompt("Fix the login bug"),
            .reply("Looking into it."),
            .steps([
                step("Read", "Sources/Login.swift", .read, paths: [home + "/app/Sources/Login.swift"]),
                step("Edit", "Sources/Login.swift", .edit, failed: true, note: "String to replace not found",
                     paths: [home + "/app/Sources/Login.swift"]),
                step("Bash", "swift test", .command)
            ]),
            .reply("Fixed the comparison."),
            .steps([step("Write", "Tests/LoginTests.swift", .edit, paths: [home + "/app/Tests/LoginTests.swift"])]),
            .prompt("/model opus"),
            .prompt("! git status"),
            .notice(.interrupted),
            .notice(.contextCompacted),
            .prompt("Now add a test\n[image]")
        ])
        XCTAssertEqual(transcript.stats, TranscriptStats(prompts: 4, toolCalls: 4, failures: 1, filesChanged: 1))
        XCTAssertEqual(transcript.omittedCount, 0)
    }

    func testClaudeRescansOnlyChangedFiles() throws {
        try installFixture("claude", as: ".claude")
        let catalog = catalog()
        XCTAssertEqual(catalog.scan().first?.title, "Login bug (renamed)")

        let path = home + "/.claude/projects/-Users-test-app/11111111-2222-4333-8444-555555555555.jsonl"
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        handle.write(Data(#"{"type":"custom-title","customTitle":"Renamed again"}"#.utf8 + [0x0A]))
        try handle.close()

        XCTAssertEqual(catalog.scan().first?.title, "Renamed again")
    }

    // MARK: Codex

    func testCodexListsThreadsAndBuildsTranscriptFromHistory() throws {
        let codex = home + "/.codex"
        try FileManager.default.createDirectory(atPath: codex + "/sessions", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: codex + "/sessions/r1.jsonl.zst", contents: Data())
        try makeCodexState(at: codex + "/state_4.sqlite", rows: [
            ["id": "019a0000-0000-7000-8000-000000000009", "title": "Stale database", "first_user_message": "x", "updated_at_ms": "1"]
        ])
        try makeCodexState(at: codex + "/state_5.sqlite", rows: [
            ["id": "019a0000-0000-7000-8000-000000000001", "title": "Codex title", "first_user_message": "first ask",
             "cwd": home + "/app", "git_branch": "feat/x", "model": "gpt-5.5-codex", "tokens_used": "1200",
             "is_pinned": "1", "updated_at_ms": "1767423600000", "created_at_ms": "1767423000000",
             "rollout_path": codex + "/sessions/r1.jsonl", "source": "cli"],
            ["id": "019a0000-0000-7000-8000-000000000002", "name": "Renamed", "title": "Old", "first_user_message": "hello",
             "updated_at_ms": "1767420000000", "rollout_path": codex + "/sessions/gone.jsonl", "source": "vscode"],
            ["id": "019a0000-0000-7000-8000-000000000003", "title": "Archived", "first_user_message": "a",
             "updated_at_ms": "1", "archived": "1"],
            ["id": "019a0000-0000-7000-8000-000000000004", "title": "Guardian review", "first_user_message": "g",
             "updated_at_ms": "1", "source": #"{"subagent":{"other":"guardian"}}"#],
            ["id": "019a0000-0000-7000-8000-000000000005", "updated_at_ms": "1"]
        ])
        let t1 = "019a0000-0000-7000-8000-000000000001"
        try makeCodexHistory(at: codex + "/thread_history_1.sqlite", items: [
            (t1, "userMessage", #"{"type":"userMessage","content":[{"type":"text","text":"first ask"}]}"#),
            (t1, "reasoning", #"{"type":"reasoning","summary":[],"content":[]}"#),
            (t1, "commandExecution", #"{"type":"commandExecution","command":"/bin/zsh -lc 'make build'","cwd":"\#(home!)/app","status":"failed","exitCode":2,"aggregatedOutput":"compiling\nerror: boom\n","commandActions":[{"type":"unknown","command":"make build"}]}"#),
            (t1, "commandExecution", #"{"type":"commandExecution","command":"cat a.swift","cwd":"\#(home!)/app","status":"completed","exitCode":0,"aggregatedOutput":"","commandActions":[{"type":"read","command":"cat a.swift","path":"\#(home!)/app/a.swift"}]}"#),
            (t1, "fileChange", #"{"type":"fileChange","status":"completed","changes":[{"path":"\#(home!)/app/a.swift","kind":{"type":"update"},"diff":""}]}"#),
            (t1, "mcpToolCall", #"{"type":"mcpToolCall","server":"exa","tool":"search","status":"failed","error":{"message":"rate limited"}}"#),
            (t1, "webSearch", #"{"type":"webSearch","query":"swift testing"}"#),
            (t1, "contextCompaction", #"{"type":"contextCompaction"}"#),
            (t1, "agentMessage", #"{"type":"agentMessage","text":"Done."}"#),
            (t1, "userMessage", #"{"type":"userMessage","content":[{"type":"text","text":"second ask"}]}"#)
        ])

        let catalog = catalog()
        let sessions = catalog.scan()
        XCTAssertEqual(sessions.map(\.sessionID), [t1, "019a0000-0000-7000-8000-000000000002"],
                       "只读最新版本的 state 库；归档、guardian 子代理、空线程都不列出；按更新时间倒序")

        let first = sessions[0]
        XCTAssertEqual(first.title, "Codex title")
        XCTAssertEqual(first.promptCount, 2)
        XCTAssertEqual(first.tokens, 1200)
        XCTAssertTrue(first.isPinned)
        XCTAssertTrue(first.hasTranscript)
        XCTAssertNil(first.resumeBlocker, ".jsonl.zst 也算记录还在")
        XCTAssertTrue(first.matches("second ask"), "历史库里的提问进入搜索文本")

        let second = sessions[1]
        XCTAssertEqual(second.title, "Renamed")
        XCTAssertNil(second.promptCount)
        XCTAssertFalse(second.hasTranscript)
        XCTAssertEqual(second.resumeBlocker, .recordMissing)
        XCTAssertThrowsError(try catalog.transcript(for: second)) { error in
            XCTAssertEqual(error as? SessionTranscriptError, .unavailable)
        }

        let transcript = try catalog.transcript(for: first)
        XCTAssertEqual(transcript.items.map(\.entry), [
            .prompt("first ask"),
            .steps([
                step("Shell", "make build", .command, failed: true, note: "error: boom"),
                step("Read", "a.swift", .read, paths: [home + "/app/a.swift"]),
                step("Edit", "a.swift", .edit, paths: [home + "/app/a.swift"]),
                step("MCP", "exa · search", .mcp, failed: true, note: "rate limited"),
                step("Web Search", "swift testing", .web)
            ]),
            .notice(.contextCompacted),
            .reply("Done."),
            .prompt("second ask")
        ])
        XCTAssertEqual(transcript.stats, TranscriptStats(prompts: 2, toolCalls: 5, failures: 2, filesChanged: 1))
    }

    func testReadsWALDatabaseAfterOwnerRemovedSidecarFiles() throws {
        // Codex 退出时会删掉 -wal / -shm，库仍是 WAL 模式；只读连接不能重建 -shm，必须退回 immutable。
        let path = home + "/wal.sqlite"
        let db = try openWritable(path)
        try exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE t (v TEXT); INSERT INTO t VALUES ('kept');")
        sqlite3_close(db)
        // 系统 SQLite 默认保留 WAL 伴随文件；按 Codex 自带 SQLite 的行为手动删掉（关闭后 -wal 已清空）。
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")

        let reader = try XCTUnwrap(SessionSQLite(path: path))
        var values: [String] = []
        XCTAssertTrue(reader.query("SELECT v FROM t") { values.append($0.string("v") ?? "") })
        XCTAssertEqual(values, ["kept"])
        XCTAssertNil(SessionSQLite(path: home + "/missing.sqlite"))
    }

    // MARK: OpenCode

    func testOpenCodeJSONStorage() throws {
        try installFixture("opencode", as: ".local/share/opencode")
        let catalog = catalog()
        let sessions = catalog.scan()

        XCTAssertEqual(sessions.map(\.sessionID), ["ses_AAA111"], "子会话（有 parentID）不列出")
        let session = sessions[0]
        XCTAssertEqual(session.title, "List the files", "占位标题改用第一句提问")
        XCTAssertEqual(session.promptCount, 1)
        XCTAssertEqual(session.tokens, 160)
        XCTAssertEqual(session.model, "gpt-5.5")
        XCTAssertFalse(session.matches("synthetic"))

        let transcript = try catalog.transcript(for: session)
        XCTAssertEqual(transcript.items.map(\.entry), [
            .prompt("List the files"),
            .steps([step("bash", "ls missing", .command, failed: true, note: "No such file or directory")]),
            .reply("The directory is missing.")
        ])
    }

    func testOpenCodeDatabaseV1WinsOverJSONAndSkipsChildAndArchived() throws {
        try installFixture("opencode", as: ".local/share/opencode")
        let db = try openWritable(home + "/.local/share/opencode/opencode.db")
        defer { sqlite3_close(db) }
        try exec(db, """
            CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, slug TEXT, directory TEXT,
              title TEXT, version TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER);
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
            INSERT INTO session VALUES ('ses_AAA111', 'p', NULL, 's', '\(home!)/app', 'From database', '1.0', 1767423000000, 1767429000000, NULL);
            INSERT INTO session VALUES ('ses_CHILD2', 'p', 'ses_AAA111', 's', '\(home!)/app', 'child', '1.0', 1, 2, NULL);
            INSERT INTO session VALUES ('ses_OLD', 'p', NULL, 's', '\(home!)/app', 'archived', '1.0', 1, 2, 3);
            INSERT INTO message VALUES ('msg_d1', 'ses_AAA111', 1767423000000, 1767423000000, '{"role":"user","time":{"created":1767423000000}}');
            INSERT INTO message VALUES ('msg_d2', 'ses_AAA111', 1767423005000, 1767423005000,
              '{"role":"assistant","modelID":"claude-sonnet-5-5","time":{"created":1767423005000},"tokens":{"input":5,"output":5,"reasoning":0,"cache":{"read":0,"write":0}}}');
            INSERT INTO message VALUES ('msg_c1', 'ses_CHILD2', 1, 1, '{"role":"user","time":{"created":1}}');
            INSERT INTO message VALUES ('msg_o1', 'ses_OLD', 1, 1, '{"role":"user","time":{"created":1}}');
            INSERT INTO part VALUES ('prt_d1', 'msg_d1', 'ses_AAA111', 1, 1, '{"type":"text","text":"Database prompt"}');
            INSERT INTO part VALUES ('prt_d2', 'msg_d2', 'ses_AAA111', 2, 2, '{"type":"tool","tool":"read","state":{"status":"completed","input":{"filePath":"\(home!)/app/a.swift"}}}');
            INSERT INTO part VALUES ('prt_d3', 'msg_d2', 'ses_AAA111', 3, 3, '{"type":"text","text":"Read it."}');
            """)

        let catalog = catalog()
        let sessions = catalog.scan()
        XCTAssertEqual(sessions.map(\.sessionID), ["ses_AAA111"])
        XCTAssertEqual(sessions[0].title, "From database")
        XCTAssertEqual(sessions[0].tokens, 10)
        XCTAssertTrue(sessions[0].matches("database prompt"))

        let transcript = try catalog.transcript(for: sessions[0])
        XCTAssertEqual(transcript.items.map(\.entry), [
            .prompt("Database prompt"),
            .steps([step("read", "a.swift", .read, paths: [home + "/app/a.swift"])]),
            .reply("Read it.")
        ])
    }

    func testOpenCodeDatabaseV2ReadsInlineContent() throws {
        let directory = home + "/.local/share/opencode"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let db = try openWritable(directory + "/opencode.db")
        defer { sqlite3_close(db) }
        try exec(db, """
            CREATE TABLE session_v2 (id TEXT PRIMARY KEY, slug TEXT, directory TEXT, title TEXT, version TEXT, parent_id TEXT,
              time_created INTEGER, time_updated INTEGER, time_archived INTEGER, tokens_input INTEGER, tokens_output INTEGER);
            CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER,
              time_created INTEGER, time_updated INTEGER, data TEXT);
            INSERT INTO session_v2 VALUES ('ses_V2A', 's', '\(home!)/app', 'Version two', '2.0', NULL, 1767423000000, 1767425000000, NULL, 70, 30);
            INSERT INTO session_message VALUES ('m1', 'ses_V2A', 'user', 1, 1767423000000, 1767423000000,
              '{"content":[{"type":"text","text":"Hi v2"}]}');
            INSERT INTO session_message VALUES ('m2', 'ses_V2A', 'assistant', 2, 1767423001000, 1767423001000,
              '{"model":{"id":"claude-sonnet-5-5","providerID":"anthropic"},"content":[{"type":"text","text":"Hello from v2"},{"type":"tool","name":"edit","state":{"status":"error","input":{"filePath":"\(home!)/app/b.swift"},"error":"conflict"}}]}');
            """)

        let catalog = catalog()
        let session = try XCTUnwrap(catalog.scan().first)
        XCTAssertEqual(session.title, "Version two")
        XCTAssertEqual(session.tokens, 100, "v2 直接读 session_v2 的 token 列")
        XCTAssertEqual(session.model, "claude-sonnet-5-5")
        XCTAssertEqual(try catalog.transcript(for: session).items.map(\.entry), [
            .prompt("Hi v2"),
            .reply("Hello from v2"),
            .steps([step("edit", "b.swift", .edit, failed: true, note: "conflict", paths: [home + "/app/b.swift"])])
        ])
    }

    // MARK: Resume

    func testResumePlanValidatesIDsAndQuotesPaths() throws {
        let quotedDirectory = home + "/it's here"
        try FileManager.default.createDirectory(atPath: quotedDirectory, withIntermediateDirectories: true)

        let claude = try SessionResumePlan.make(
            for: summary(.claude, id: "11111111-2222-4333-8444-555555555555", directory: quotedDirectory), homeDirectory: home)
        XCTAssertEqual(claude.arguments, ["claude", "--resume", "11111111-2222-4333-8444-555555555555"])
        XCTAssertEqual(claude.commandLine, "cd '\(home!)/it'\\''s here' && claude --resume 11111111-2222-4333-8444-555555555555")
        let script = claude.script(shell: "/bin/zsh")
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh -il\n"))
        XCTAssertTrue(script.contains("rm -f -- \"$0\"\n"))
        XCTAssertTrue(script.contains("cd -- '\(home!)/it'\\''s here' || {"))
        XCTAssertTrue(script.contains("\n'claude' '--resume' '11111111-2222-4333-8444-555555555555'\n"))

        let codex = try SessionResumePlan.make(
            for: summary(.codex, id: "019a0000-0000-7000-8000-000000000001", directory: home + "/gone"), homeDirectory: home)
        XCTAssertEqual(codex.directory, home, "Codex 目录不在时退回家目录")
        XCTAssertEqual(codex.arguments, ["codex", "resume", "019a0000-0000-7000-8000-000000000001"])

        let openCode = try SessionResumePlan.make(for: summary(.opencode, id: "ses_47d61c905ffesCirj", directory: home + "/app"), homeDirectory: home)
        XCTAssertEqual(openCode.arguments, ["opencode", "--session", "ses_47d61c905ffesCirj"])

        XCTAssertThrowsError(try SessionResumePlan.make(for: summary(.claude, id: "x; rm -rf ~", directory: home + "/app"))) {
            XCTAssertEqual($0 as? SessionResumeError, .invalidSessionID)
        }
        XCTAssertThrowsError(try SessionResumePlan.make(for: summary(.opencode, id: "ses_a$(id)", directory: home + "/app"))) {
            XCTAssertEqual($0 as? SessionResumeError, .invalidSessionID)
        }
        XCTAssertThrowsError(try SessionResumePlan.make(for: summary(.claude, id: "11111111-2222-4333-8444-555555555555", directory: home + "/gone"))) {
            XCTAssertEqual($0 as? SessionResumeError, .directoryMissing)
        }
    }

    // MARK: Terminals

    func testTerminalsKeepStoredValuesAndOpenScriptsDirectly() {
        // 已发布版本存过这三个值，改名会让用户的选择失效。
        XCTAssertEqual(SessionTerminal(rawValue: "ghostty"), .ghostty)
        XCTAssertEqual(SessionTerminal(rawValue: "warp"), .warp)
        XCTAssertEqual(SessionTerminal(rawValue: "terminal"), .terminal)
        XCTAssertEqual(SessionTerminal.allCases.last, .terminal, "系统终端只做兜底")
        XCTAssertEqual(Set(SessionTerminal.allCases.map(\.bundleIdentifier)).count, SessionTerminal.allCases.count)

        for terminal in [SessionTerminal.ghostty, .iterm2, .warp, .terminal] {
            XCTAssertEqual(terminal.launchMethod(scriptPath: "/tmp/x.command"), .openScript, terminal.rawValue)
        }
    }

    func testNewInstanceTerminalsRunTheExactScript() throws {
        let directory = home + "/it's a dir"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let script = directory + "/resume me.command"
        let marker = home + "/marker"
        try "#!/bin/sh\nprintf '%s' \"$0\" > \(SessionResumePlan.quote(marker))\n"
            .write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script)

        for terminal in [SessionTerminal.wezterm, .kaku, .kitty, .alacritty] {
            guard case .newInstance(let arguments) = terminal.launchMethod(scriptPath: script) else {
                return XCTFail("\(terminal.rawValue) 应新开实例")
            }
            XCTAssertFalse(arguments.contains(script), "脚本路径单独出现在参数里会被 macOS 当成要打开的文件")
            XCTAssertEqual(Array(arguments.suffix(3).prefix(2)), ["/bin/sh", "-c"])

            try? FileManager.default.removeItem(atPath: marker)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = Array(arguments.suffix(2))
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, terminal.rawValue)
            XCTAssertEqual(try String(contentsOfFile: marker, encoding: .utf8), script, terminal.rawValue)
        }

        guard case .newInstance(let wezterm) = SessionTerminal.wezterm.launchMethod(scriptPath: script),
              case .newInstance(let kaku) = SessionTerminal.kaku.launchMethod(scriptPath: script),
              case .newInstance(let kitty) = SessionTerminal.kitty.launchMethod(scriptPath: script),
              case .newInstance(let alacritty) = SessionTerminal.alacritty.launchMethod(scriptPath: script) else { return }
        XCTAssertEqual(Array(wezterm.prefix(2)), ["start", "--"], "start 在 WezTerm 已运行时会转交给原实例")
        XCTAssertEqual(kaku, wezterm)
        XCTAssertEqual(Array(kitty.prefix(2)), ["-o", "macos_quit_when_last_window_closed=yes"])
        XCTAssertEqual(alacritty.first, "-e", "Alacritty 的 -e 必须是最后一个选项，后面整段都是命令")
    }

    // MARK: Export

    func testMarkdownExport() throws {
        try installFixture("claude", as: ".claude")
        let catalog = catalog()
        let session = try XCTUnwrap(catalog.scan().first)
        let markdown = SessionMarkdownExporter.markdown(
            summary: session, transcript: try catalog.transcript(for: session), timeZone: TimeZone(identifier: "UTC")!)

        XCTAssertTrue(markdown.hasPrefix("# Login bug (renamed)\n"))
        XCTAssertTrue(markdown.contains("- Claude Code · Session `11111111-2222-4333-8444-555555555555`"))
        XCTAssertTrue(markdown.contains("### You · 2026-10-30 08:00\n\nFix the login bug\n"))
        XCTAssertTrue(markdown.contains("### Claude Code · 2026-10-30 08:00\n\nLooking into it.\n"))
        XCTAssertTrue(markdown.contains("- ✗ Edit `Sources/Login.swift` — String to replace not found"))
        XCTAssertTrue(markdown.contains("> Interrupted"))
        XCTAssertEqual(SessionMarkdownExporter.code("a`b"), "`` a`b ``")
    }

    // MARK: Helpers

    private func catalog() -> SessionCatalog {
        SessionCatalog(environment: SessionEnvironment(homeDirectory: home, variables: [:]))
    }

    /// 把 Fixtures/sessions/<name> 复制到临时 HOME，并把 `__HOME__` 换成真实路径。
    private func installFixture(_ name: String, as relativePath: String) throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
            .appendingPathComponent("sessions/\(name)")
        let destination = URL(fileURLWithPath: home).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        let files = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            try text.replacingOccurrences(of: "__HOME__", with: home).write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private func step(_ name: String, _ detail: String, _ kind: ToolStep.Kind, failed: Bool = false,
                      note: String? = nil, paths: [String] = []) -> ToolStep {
        ToolStep(name: name, detail: detail, kind: kind, failed: failed, failureNote: note, paths: paths)
    }

    private func summary(_ tool: SessionTool, id: String, directory: String?) -> SessionSummary {
        SessionSummary(tool: tool, sessionID: id, title: "t", directory: directory, gitBranch: nil, model: nil,
                       createdAt: nil, updatedAt: Date(), promptCount: 1, tokens: nil, isPinned: false,
                       hasTranscript: true, resumeBlocker: nil, searchText: "", locator: .claudeFile(""))
    }

    private func iso(_ text: String) -> Date? {
        SessionText.date(iso: text)
    }

    private func makeCodexState(at path: String, rows: [[String: String]]) throws {
        let columns = ["id", "name", "title", "first_user_message", "cwd", "git_branch", "model", "tokens_used",
                       "is_pinned", "archived", "source", "thread_source", "rollout_path", "created_at_ms", "updated_at_ms"]
        let db = try openWritable(path)
        defer { sqlite3_close(db) }
        try exec(db, "CREATE TABLE threads (\(columns.joined(separator: ", ")), has_user_event INTEGER DEFAULT 0)")
        for row in rows {
            let values = columns.map { row[$0].map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL" }
            try exec(db, "INSERT INTO threads (\(columns.joined(separator: ", "))) VALUES (\(values.joined(separator: ", ")))")
        }
    }

    private func makeCodexHistory(at path: String, items: [(String, String, String)]) throws {
        let db = try openWritable(path)
        defer { sqlite3_close(db) }
        try exec(db, """
            CREATE TABLE thread_items (thread_id TEXT, turn_id TEXT, item_id TEXT, rollout_ordinal INTEGER,
              created_at_ms INTEGER, item_json TEXT, item_type TEXT)
            """)
        for (index, item) in items.enumerated() {
            let json = item.2.replacingOccurrences(of: "'", with: "''")
            try exec(db, "INSERT INTO thread_items VALUES ('\(item.0)', 't', 'i\(index)', \(index), \(1767423000000 + index), '\(json)', '\(item.1)')")
        }
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
