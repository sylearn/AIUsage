import Darwin
import Foundation

// MARK: - Session Center · Claude Code
// 数据来源：$CLAUDE_CONFIG_DIR 或 ~/.claude 下的 projects/<编码目录>/<uuid>.jsonl（只认第二层）。
// 标题优先级：custom-title > ai-title > 旧版 summary > 第一句提问；都取文件里最后一条。
// 用户消息分四种：普通提问、斜杠命令、系统注入（isMeta）、工具结果（tool_result 块），只有前两种算一轮。
// isSidechain 为 true 的记录属于子代理，不进入主时间线。
// 增量解析：会话文件只会追加。同一个文件（inode 不变）变大时，从上次停下的位置接着读，列表摘要与正文的中间状态都留在内存里；
// 文件变小、换了 inode，或停下的位置不在一条记录末尾时整份重读。
// 「进行中」来自 ClaudeSessionRegistry（Claude Code 的进程登记），每次扫描现查。

final class ClaudeSessionSource {
    private let environment: SessionEnvironment
    /// 列表缓存：只在 scan 里读写（SessionCatalog 串行化扫描）。
    private var cache: [String: SummaryEntry] = [:]
    /// 正文缓存：最近打开的几份会话，会话进行中时只读新增的行。
    private var transcripts: [String: TranscriptEntry] = [:]
    private var transcriptOrder: [String] = []
    private let transcriptLock = NSLock()
    private static let transcriptCacheLimit = 4

    /// 列表与正文都只需要这些类型的行；其余（api-request、file-history 等大块记录）直接跳过。
    private static let needles = ["user", "assistant", "ai-title", "custom-title", "summary"]
        .map { Data("\"type\":\"\($0)\"".utf8) }
    private static let maxLineBytes = 4 * 1024 * 1024

    private struct SummaryEntry {
        let fingerprint: FileFingerprint
        let offset: UInt64
        let state: SummaryState
        let summary: SessionSummary?
    }

    private struct TranscriptEntry {
        let fingerprint: FileFingerprint
        let offset: UInt64
        let state: TranscriptState
    }

    init(environment: SessionEnvironment) {
        self.environment = environment
    }

    func scan() -> [SessionSummary] {
        let projectsRoot = (environment.claudeRoot as NSString).appendingPathComponent("projects")
        let fileManager = FileManager.default
        guard let projectNames = try? fileManager.contentsOfDirectory(atPath: projectsRoot) else {
            cache.removeAll()
            return []
        }

        var fresh: [String: SummaryEntry] = [:]
        for project in projectNames {
            let projectPath = (projectsRoot as NSString).appendingPathComponent(project)
            guard let files = try? fileManager.contentsOfDirectory(atPath: projectPath) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = (projectPath as NSString).appendingPathComponent(file)
                guard let fingerprint = FileFingerprint(path: path) else { continue }
                if let cached = cache[path], cached.fingerprint == fingerprint {
                    fresh[path] = cached
                } else {
                    fresh[path] = summarize(path: path, fingerprint: fingerprint, previous: cache[path])
                }
            }
        }
        cache = fresh

        let live = ClaudeSessionRegistry.activities(root: environment.claudeRoot)
        return fresh.values.compactMap { entry in
            guard var summary = entry.summary else { return nil }
            summary.activity = live[summary.sessionID]
            return summary
        }
    }

    // MARK: Summary

    private func summarize(path: String, fingerprint: FileFingerprint, previous: SummaryEntry?) -> SummaryEntry {
        var state = SummaryState()
        var offset: UInt64 = 0
        if let previous, Self.canContinue(from: previous.fingerprint, offset: previous.offset, to: fingerprint, path: path) {
            state = previous.state
            offset = previous.offset
        }
        let end = SessionLineReader.read(path: path, from: offset, needles: Self.needles, maxLineBytes: Self.maxLineBytes) { line in
            guard let record = SessionJSON.object(line) else { return false }
            state.consume(record)
            return true
        } ?? offset
        let sessionID = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return SummaryEntry(fingerprint: fingerprint, offset: end, state: state, summary: state.summary(sessionID: sessionID, path: path))
    }

    /// 一份会话文件读到某处为止的累计结果。
    struct SummaryState {
        var customTitle: String?
        var aiTitle: String?
        var legacySummary: String?
        var firstPrompt: String?
        var prompts = 0
        var directory: String?
        var branch: String?
        var model: String?
        var firstDate: Date?
        var lastDate: Date?
        var usageByMessage: [String: Int] = [:]
        var search = SessionText.SearchBuffer()

        mutating func consume(_ record: [String: Any]) {
            guard let type = record["type"] as? String else { return }
            switch type {
            case "custom-title":
                customTitle = (record["customTitle"] as? String).flatMap(ClaudeSessionSource.nonEmpty) ?? customTitle
            case "ai-title":
                aiTitle = (record["aiTitle"] as? String).flatMap(ClaudeSessionSource.nonEmpty) ?? aiTitle
            case "summary":
                legacySummary = (record["summary"] as? String).flatMap(ClaudeSessionSource.nonEmpty) ?? legacySummary
            case "user", "assistant":
                guard record["isSidechain"] as? Bool != true else { return }
                // 会话按开始时的目录存放，--resume 必须回到那里；中途 cd 不影响。
                if directory == nil, let cwd = record["cwd"] as? String, !cwd.isEmpty { directory = cwd }
                if let gitBranch = record["gitBranch"] as? String, !gitBranch.isEmpty, gitBranch != "HEAD" {
                    branch = gitBranch
                }
                if let date = SessionText.date(iso: record["timestamp"] as? String) {
                    firstDate = firstDate ?? date
                    lastDate = date
                }
                if type == "user" {
                    if case .text(let text)? = ClaudeSessionSource.prompt(in: record) {
                        prompts += 1
                        firstPrompt = firstPrompt ?? text
                        search.append(text)
                    }
                } else if let message = record["message"] as? [String: Any] {
                    if let name = message["model"] as? String, !name.isEmpty, name != "<synthetic>" { model = name }
                    // 同一条消息的每个内容块各占一行并重复 usage，按消息 ID 去重。
                    if let id = message["id"] as? String, let usage = message["usage"] as? [String: Any] {
                        usageByMessage[id] = ClaudeSessionSource.totalTokens(usage)
                    }
                }
            default:
                break
            }
        }

        func summary(sessionID: String, path: String) -> SessionSummary? {
            guard prompts > 0, let updatedAt = lastDate else { return nil }
            let title = customTitle ?? aiTitle ?? legacySummary ?? SessionText.title(fromPrompt: firstPrompt ?? "")
            var searchText = SessionText.SearchBuffer()
            searchText.append([title, directory, branch, sessionID].compactMap { $0 }.joined(separator: " "))
            searchText.append(search.text)
            let tokens = usageByMessage.values.reduce(0, +)

            return SessionSummary(
                tool: .claude,
                sessionID: sessionID,
                title: title,
                directory: directory,
                gitBranch: branch,
                model: model,
                createdAt: firstDate,
                updatedAt: updatedAt,
                promptCount: prompts,
                tokens: tokens > 0 ? tokens : nil,
                isPinned: false,
                hasTranscript: true,
                resumeBlocker: directory.map { FileManager.default.fileExists(atPath: $0) } == true ? nil : .directoryMissing,
                searchText: searchText.text,
                locator: .claudeFile(path)
            )
        }
    }

    /// 同一个文件只追加过：inode 不变、没有变小，且上次停下的位置紧跟在一条完整记录后面。
    static func canContinue(from old: FileFingerprint, offset: UInt64, to new: FileFingerprint, path: String) -> Bool {
        guard offset > 0, old.inode == new.inode, new.size >= offset else { return false }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var byte: UInt8 = 0
        guard pread(fd, &byte, 1, off_t(offset - 1)) == 1 else { return false }
        return byte == 0x0A || byte == UInt8(ascii: "}")
    }

    // MARK: Transcript

    /// cached 为 true 时记住解析进度（阅读视图用）；全文索引一次读很多会话，不进缓存。
    func transcript(path: String, home: String, limit: Int, cached: Bool) throws -> SessionTranscript {
        guard FileManager.default.isReadableFile(atPath: path), let fingerprint = FileFingerprint(path: path) else {
            throw SessionTranscriptError.unreadable
        }
        guard cached else {
            var state = TranscriptState()
            _ = Self.readTranscript(path: path, from: 0, home: home, into: &state)
            return state.builder.build(limit: limit)
        }

        transcriptLock.lock()
        defer { transcriptLock.unlock() }
        var state = TranscriptState()
        var offset: UInt64 = 0
        if let previous = transcripts[path] {
            if previous.fingerprint == fingerprint { return previous.state.builder.build(limit: limit) }
            if Self.canContinue(from: previous.fingerprint, offset: previous.offset, to: fingerprint, path: path) {
                state = previous.state
                offset = previous.offset
            }
        }
        let end = Self.readTranscript(path: path, from: offset, home: home, into: &state) ?? offset
        transcripts[path] = TranscriptEntry(fingerprint: fingerprint, offset: end, state: state)
        transcriptOrder.removeAll { $0 == path }
        transcriptOrder.append(path)
        while transcriptOrder.count > Self.transcriptCacheLimit {
            transcripts.removeValue(forKey: transcriptOrder.removeFirst())
        }
        return state.builder.build(limit: limit)
    }

    private static func readTranscript(path: String, from offset: UInt64, home: String, into state: inout TranscriptState) -> UInt64? {
        SessionLineReader.read(path: path, from: offset, needles: needles, maxLineBytes: maxLineBytes) { line in
            guard let record = SessionJSON.object(line) else { return false }
            state.consume(record, home: home)
            return true
        }
    }

    /// 正文读到某处为止的构建状态。
    struct TranscriptState {
        var builder = TranscriptBuilder()
        var directory: String?

        mutating func consume(_ record: [String: Any], home: String) {
            guard let type = record["type"] as? String,
                  type == "user" || type == "assistant",
                  record["isSidechain"] as? Bool != true else { return }
            if directory == nil, let cwd = record["cwd"] as? String, !cwd.isEmpty { directory = cwd }
            let date = SessionText.date(iso: record["timestamp"] as? String)
            let content = (record["message"] as? [String: Any])?["content"]

            if type == "user" {
                for block in content as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
                    guard block["is_error"] as? Bool == true, let id = block["tool_use_id"] as? String else { continue }
                    builder.markFailed(callID: id, note: ClaudeSessionSource.resultText(block["content"]).map { SessionText.oneLine($0, limit: 200) })
                }
                switch ClaudeSessionSource.prompt(in: record) {
                case .text(let text)?: builder.prompt(text, date: date)
                case .notice(let notice)?: builder.notice(notice, date: date)
                case nil: break
                }
                return
            }

            for block in content as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    let text = SessionText.clean(block["text"] as? String ?? "")
                    if text != "(no content)" { builder.reply(text, date: date) }
                case "tool_use":
                    let step = ToolStepFactory.make(
                        name: block["name"] as? String ?? "",
                        input: block["input"] as? [String: Any] ?? [:],
                        base: directory,
                        home: home
                    )
                    builder.step(step, callID: block["id"] as? String, date: date)
                default:
                    break
                }
            }
        }
    }

    // MARK: Record helpers

    enum Prompt: Equatable {
        case text(String)
        case notice(TranscriptNotice)
    }

    /// 用户消息里属于「一轮提问」的部分；系统注入、工具结果、命令输出返回 nil。
    static func prompt(in record: [String: Any]) -> Prompt? {
        guard record["isMeta"] as? Bool != true else { return nil }
        if record["isCompactSummary"] as? Bool == true { return .notice(.contextCompacted) }
        let content = (record["message"] as? [String: Any])?["content"]

        if let text = content as? String {
            return prompt(fromText: text)
        }
        guard let blocks = content as? [[String: Any]],
              !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
        let parts = blocks.compactMap { block -> String? in
            switch block["type"] as? String {
            case "text": return block["text"] as? String
            case "image": return "[image]"
            default: return nil
            }
        }
        return prompt(fromText: parts.joined(separator: "\n"))
    }

    private static func prompt(fromText raw: String) -> Prompt? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[Request interrupted") { return .notice(.interrupted) }
        if let name = tag("command-name", in: trimmed) {
            let args = tag("command-args", in: trimmed) ?? ""
            let command = name.hasPrefix("/") ? name : "/" + name
            return .text(args.isEmpty ? command : command + " " + args)
        }
        if let input = tag("bash-input", in: trimmed) {
            return .text("! " + input)
        }
        // 命令输出与 Claude Code 自动注入的后台任务通知不是用户提问。
        for noise in ["<local-command-", "<bash-stdout>", "<bash-stderr>", "<command-message>", "<task-notification>"]
        where trimmed.hasPrefix(noise) {
            return nil
        }
        let text = SessionText.clean(trimmed)
        return text.isEmpty ? nil : .text(text)
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(name)>"),
              let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex) else { return nil }
        return text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func resultText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        let texts = (content as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    static func totalTokens(_ usage: [String: Any]) -> Int {
        ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
            .compactMap { SessionJSON.int(usage[$0]) }
            .reduce(0, +)
    }

    static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
