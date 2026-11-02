import Foundation

// MARK: - Session Center · Support
// 三个来源共用的环境、文本清理、正文构建与工具步骤归类。

/// 定位各工具数据目录所需的环境；测试时注入临时 HOME。
public struct SessionEnvironment: Sendable {
    public let homeDirectory: String
    public let variables: [String: String]

    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        variables: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.variables = variables
    }

    var claudeRoot: String {
        override("CLAUDE_CONFIG_DIR") ?? (homeDirectory as NSString).appendingPathComponent(".claude")
    }

    var codexRoot: String {
        override("CODEX_HOME") ?? (homeDirectory as NSString).appendingPathComponent(".codex")
    }

    var openCodeDataDirectory: String {
        resolveOpenCodeDataDirectory(homeDirectory: homeDirectory, environment: variables)
    }

    private func override(_ key: String) -> String? {
        guard let value = variables[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return (value as NSString).expandingTildeInPath
    }
}

/// 文件指纹：修改时间与大小都没变就复用上次的解析结果。
/// inode 用来区分「原文件追加」和「换了一个文件」（后者不能接着上次的位置读）。
struct FileFingerprint: Hashable, Sendable {
    let inode: UInt64
    let size: UInt64
    /// 修改时间，纳秒。
    let modified: Int64

    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        inode = UInt64(info.st_ino)
        size = UInt64(max(0, info.st_size))
        modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }
}

enum SessionText {
    /// 没有进程登记的工具（Codex、OpenCode）按记录推断「进行中」：最后一次动静超过这么久就不算了，
    /// 免得崩溃后残留的未完成记录一直显示进行中。
    static let activityWindow: TimeInterval = 30 * 60
    static let maxMessageLength = 20_000
    static let maxSearchLength = 8_192

    /// 去掉工具注入的 `<system-reminder>` 片段，裁掉首尾空白，超长截断。
    static func clean(_ raw: String) -> String {
        var text = raw
        while let start = text.range(of: "<system-reminder>"),
              let end = text.range(of: "</system-reminder>", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maxMessageLength {
            text = String(text.prefix(maxMessageLength)) + "\n…"
        }
        return text
    }

    /// 第一行非空文本，压缩空白后截断到 `limit` 个字符。
    static func oneLine(_ raw: String, limit: Int) -> String {
        let line = raw.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit - 1)) + "…" : collapsed
    }

    /// 最后一行非空文本（命令失败时错误通常在输出末尾）。
    static func lastLine(_ raw: String, limit: Int) -> String? {
        let line = raw.split(whereSeparator: \.isNewline)
            .reversed()
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line.map { oneLine($0, limit: limit) }
    }

    static func title(fromPrompt prompt: String) -> String {
        oneLine(prompt, limit: 80)
    }

    /// 项目内路径显示为相对路径，家目录显示为 `~`。
    static func displayPath(_ path: String, base: String?, home: String) -> String {
        if let base, !base.isEmpty, path.hasPrefix(base + "/") {
            return String(path.dropFirst(base.count + 1))
        }
        if !home.isEmpty, path == home || path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// 搜索文本累加器：超过上限后丢弃后续内容。
    struct SearchBuffer {
        private(set) var text = ""

        mutating func append(_ part: String?) {
            guard let part, !part.isEmpty, text.utf8.count < SessionText.maxSearchLength else { return }
            text += (text.isEmpty ? "" : "\n") + part.lowercased()
        }
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func date(iso text: String?) -> Date? {
        guard let text else { return nil }
        return isoFractional.date(from: text) ?? isoPlain.date(from: text)
    }

    /// 毫秒或秒时间戳都接受（大于 1e11 视为毫秒）。
    static func date(epoch value: Any?) -> Date? {
        guard let number = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init),
              number > 0 else { return nil }
        return Date(timeIntervalSince1970: number > 1e11 ? number / 1000 : number)
    }
}

/// 把逐条记录拼成正文：两次文字之间的连续工具调用合成一组。
struct TranscriptBuilder {
    private enum Draft {
        case entry(TranscriptEntry, Date?)
        case group(Int, Date?)
    }

    private var drafts: [Draft] = []
    private var groups: [[ToolStep]] = []
    private var stepLocation: [String: (group: Int, index: Int)] = [:]

    mutating func prompt(_ text: String, date: Date?) {
        guard !text.isEmpty else { return }
        drafts.append(.entry(.prompt(text), date))
    }

    mutating func reply(_ text: String, date: Date?) {
        guard !text.isEmpty else { return }
        drafts.append(.entry(.reply(text), date))
    }

    mutating func notice(_ notice: TranscriptNotice, date: Date?) {
        if case .entry(.notice(notice), _)? = drafts.last { return }
        drafts.append(.entry(.notice(notice), date))
    }

    mutating func step(_ step: ToolStep, callID: String? = nil, date: Date?) {
        let groupIndex: Int
        if case .group(let open, _)? = drafts.last {
            groupIndex = open
        } else {
            groupIndex = groups.count
            groups.append([])
            drafts.append(.group(groupIndex, date))
        }
        groups[groupIndex].append(step)
        if let callID, !callID.isEmpty {
            stepLocation[callID] = (groupIndex, groups[groupIndex].count - 1)
        }
    }

    /// 工具结果晚于调用到达时（Claude 的 tool_result）回填失败状态。
    mutating func markFailed(callID: String, note: String?) {
        guard let location = stepLocation[callID] else { return }
        groups[location.group][location.index].failed = true
        groups[location.group][location.index].failureNote = note
    }

    /// 阅读视图最多渲染的条目数；全文索引不设上限。
    static let renderLimit = 3_000

    func build(limit: Int = TranscriptBuilder.renderLimit) -> SessionTranscript {
        let all: [(TranscriptEntry, Date?)] = drafts.map { draft in
            switch draft {
            case .entry(let entry, let date): return (entry, date)
            case .group(let index, let date): return (.steps(groups[index]), date)
            }
        }
        let omitted = max(0, all.count - limit)
        let items = all.dropFirst(omitted).enumerated().map { offset, pair in
            TranscriptItem(id: omitted + offset, entry: pair.0, date: pair.1)
        }

        var prompts = 0
        var steps: [ToolStep] = []
        for (entry, _) in all {
            switch entry {
            case .prompt: prompts += 1
            case .steps(let group): steps.append(contentsOf: group)
            case .reply, .notice: break
            }
        }
        let changed = Set(steps.filter { $0.kind == .edit && !$0.failed }.flatMap(\.paths))
        let stats = TranscriptStats(
            prompts: prompts,
            toolCalls: steps.count,
            failures: steps.filter(\.failed).count,
            filesChanged: changed.count
        )
        return SessionTranscript(items: Array(items), omittedCount: omitted, stats: stats)
    }
}

/// 按工具名与入参归类步骤（Claude / OpenCode 的工具调用共用）。
enum ToolStepFactory {
    private static let pathKeys = ["file_path", "filePath", "notebook_path", "path", "filename"]

    static func make(name rawName: String, input: [String: Any], base: String?, home: String) -> ToolStep {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        let key = name.lowercased()
        let paths = pathKeys.compactMap { input[$0] as? String }.filter { !$0.isEmpty }
        let shownPath = paths.first.map { SessionText.displayPath($0, base: base, home: home) }

        if key.hasPrefix("mcp__") {
            let parts = name.dropFirst(5).components(separatedBy: "__")
            let server = parts.first ?? ""
            let tool = parts.dropFirst().joined(separator: "__")
            let label = tool.isEmpty ? server : "\(server) · \(tool)"
            return ToolStep(name: "MCP", detail: label, kind: .mcp, failed: false, failureNote: nil, paths: [])
        }

        let kind: ToolStep.Kind
        var detail: String?
        switch key {
        case "read", "view", "read_file", "notebookread":
            kind = .read
            detail = shownPath
        case "edit", "multiedit", "write", "notebookedit", "patch", "apply_patch", "str_replace_editor", "create":
            kind = .edit
            detail = shownPath
        case "bash", "shell", "exec_command", "local_shell", "command", "run":
            kind = .command
            detail = commandText(input["command"] ?? input["cmd"])
        case "grep", "glob", "search", "list", "ls", "find", "codesearch", "toolsearch":
            kind = .search
            let pattern = (input["pattern"] ?? input["query"]) as? String
            detail = [pattern, shownPath].compactMap { $0 }.joined(separator: "  ")
        case "webfetch", "websearch", "web_search", "fetch":
            kind = .web
            detail = (input["url"] ?? input["query"]) as? String
        case "task", "agent", "subagent":
            kind = .agent
            detail = (input["description"] ?? input["subagent_type"] ?? input["prompt"]) as? String
        default:
            kind = .other
            detail = shownPath ?? firstString(in: input)
        }
        let line = SessionText.oneLine(detail ?? "", limit: 160)
        return ToolStep(
            name: name.isEmpty ? "Tool" : name,
            detail: line,
            kind: kind,
            failed: false,
            failureNote: nil,
            paths: kind == .read || kind == .edit ? paths : []
        )
    }

    /// 命令可能是字符串或参数数组；去掉 `zsh -lc '…'` 这类外壳。
    static func commandText(_ value: Any?) -> String? {
        var command: String?
        if let text = value as? String {
            command = text
        } else if let parts = value as? [String] {
            command = parts.joined(separator: " ")
        }
        guard var text = command?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        for shell in ["/bin/zsh -lc ", "/bin/bash -lc ", "zsh -lc ", "bash -lc ", "/bin/sh -c ", "sh -c "]
        where text.hasPrefix(shell) {
            text = String(text.dropFirst(shell.count))
            if let first = text.first, first == "'" || first == "\"", text.last == first, text.count >= 2 {
                text = String(text.dropFirst().dropLast())
            }
            break
        }
        return text
    }

    private static func firstString(in input: [String: Any]) -> String? {
        for key in input.keys.sorted() {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}

/// 只读 JSON 小工具。
enum SessionJSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func object(_ text: String?) -> [String: Any]? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return object(data)
    }

    static func object(atPath path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return object(data)
    }

    static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init)
    }
}
