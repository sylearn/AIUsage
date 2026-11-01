import Foundation

// MARK: - Session Center · Claude Code
// 数据来源：$CLAUDE_CONFIG_DIR 或 ~/.claude 下的 projects/<编码目录>/<uuid>.jsonl（只认第二层）。
// 标题优先级：custom-title > ai-title > 旧版 summary > 第一句提问；都取文件里最后一条。
// 用户消息分四种：普通提问、斜杠命令、系统注入（isMeta）、工具结果（tool_result 块），只有前两种算一轮。
// isSidechain 为 true 的记录属于子代理，不进入主时间线。

final class ClaudeSessionSource {
    private let environment: SessionEnvironment
    private var cache: [String: (FileFingerprint, SessionSummary?)] = [:]

    /// 列表与正文都只需要这些类型的行；其余（api-request、file-history 等大块记录）直接跳过。
    private static let needles = ["user", "assistant", "ai-title", "custom-title", "summary"]
        .map { Data("\"type\":\"\($0)\"".utf8) }
    private static let maxLineBytes = 4 * 1024 * 1024

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

        var fresh: [String: (FileFingerprint, SessionSummary?)] = [:]
        for project in projectNames {
            let projectPath = (projectsRoot as NSString).appendingPathComponent(project)
            guard let files = try? fileManager.contentsOfDirectory(atPath: projectPath) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = (projectPath as NSString).appendingPathComponent(file)
                guard let fingerprint = FileFingerprint(path: path) else { continue }
                if let cached = cache[path], cached.0 == fingerprint {
                    fresh[path] = cached
                } else {
                    fresh[path] = (fingerprint, summarize(path: path))
                }
            }
        }
        cache = fresh
        return fresh.values.compactMap(\.1)
    }

    // MARK: Summary

    private func summarize(path: String) -> SessionSummary? {
        let sessionID = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
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

        CallAnalyticsLineReader.forEachLine(path: path, needles: Self.needles, maxLineBytes: Self.maxLineBytes) { line in
            guard let record = SessionJSON.object(line), let type = record["type"] as? String else { return }
            switch type {
            case "custom-title":
                customTitle = (record["customTitle"] as? String).flatMap(Self.nonEmpty) ?? customTitle
            case "ai-title":
                aiTitle = (record["aiTitle"] as? String).flatMap(Self.nonEmpty) ?? aiTitle
            case "summary":
                legacySummary = (record["summary"] as? String).flatMap(Self.nonEmpty) ?? legacySummary
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
                    if case .text(let text)? = Self.prompt(in: record) {
                        prompts += 1
                        firstPrompt = firstPrompt ?? text
                        search.append(text)
                    }
                } else if let message = record["message"] as? [String: Any] {
                    if let name = message["model"] as? String, !name.isEmpty, name != "<synthetic>" { model = name }
                    // 同一条消息的每个内容块各占一行并重复 usage，按消息 ID 去重。
                    if let id = message["id"] as? String, let usage = message["usage"] as? [String: Any] {
                        usageByMessage[id] = Self.totalTokens(usage)
                    }
                }
            default:
                break
            }
        }

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

    // MARK: Transcript

    static func transcript(path: String, home: String) throws -> SessionTranscript {
        guard FileManager.default.isReadableFile(atPath: path) else { throw SessionTranscriptError.unreadable }
        var builder = TranscriptBuilder()
        var directory: String?

        CallAnalyticsLineReader.forEachLine(path: path, needles: needles, maxLineBytes: maxLineBytes) { line in
            guard let record = SessionJSON.object(line),
                  let type = record["type"] as? String,
                  type == "user" || type == "assistant",
                  record["isSidechain"] as? Bool != true else { return }
            if directory == nil, let cwd = record["cwd"] as? String, !cwd.isEmpty { directory = cwd }
            let date = SessionText.date(iso: record["timestamp"] as? String)
            let content = (record["message"] as? [String: Any])?["content"]

            if type == "user" {
                for block in content as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
                    guard block["is_error"] as? Bool == true, let id = block["tool_use_id"] as? String else { continue }
                    builder.markFailed(callID: id, note: resultText(block["content"]).map { SessionText.oneLine($0, limit: 200) })
                }
                switch prompt(in: record) {
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
        return builder.build()
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
        for noise in ["<local-command-", "<bash-stdout>", "<bash-stderr>", "<command-message>"] where trimmed.hasPrefix(noise) {
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

    private static func resultText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        let texts = (content as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func totalTokens(_ usage: [String: Any]) -> Int {
        ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
            .compactMap { SessionJSON.int(usage[$0]) }
            .reduce(0, +)
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
