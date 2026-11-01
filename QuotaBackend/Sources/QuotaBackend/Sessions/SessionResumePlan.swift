import Foundation

// MARK: - Session Center · Resume
// 构造「继续对话」的命令与一次性启动脚本。
// 会话 ID 先按工具校验格式，不合格直接拒绝；目录与 ID 一律单引号转义，杜绝命令注入。
// Claude Code 与 OpenCode 的会话按项目目录存放，必须回到原目录；Codex 会话全局可恢复，目录不在时退回家目录。

public enum SessionResumeError: Error, Equatable {
    case invalidSessionID
    case directoryMissing
}

public struct SessionResumePlan: Equatable, Sendable {
    public let tool: SessionTool
    public let sessionID: String
    public let directory: String
    /// 不含 shell 转义的参数，第一个是 CLI 名。
    public let arguments: [String]

    public static func make(
        for summary: SessionSummary,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) throws -> SessionResumePlan {
        guard isValidSessionID(summary.sessionID, tool: summary.tool) else { throw SessionResumeError.invalidSessionID }
        let existing = summary.directory.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }

        let directory: String
        let arguments: [String]
        switch summary.tool {
        case .claude:
            guard let existing else { throw SessionResumeError.directoryMissing }
            directory = existing
            arguments = ["claude", "--resume", summary.sessionID]
        case .codex:
            directory = existing ?? homeDirectory
            arguments = ["codex", "resume", summary.sessionID]
        case .opencode:
            guard let existing else { throw SessionResumeError.directoryMissing }
            directory = existing
            arguments = ["opencode", "--session", summary.sessionID]
        }
        return SessionResumePlan(tool: summary.tool, sessionID: summary.sessionID, directory: directory, arguments: arguments)
    }

    static func isValidSessionID(_ id: String, tool: SessionTool) -> Bool {
        switch tool {
        case .claude, .codex:
            return UUID(uuidString: id) != nil
        case .opencode:
            return id.hasPrefix("ses_") && id.count > 4 && id.dropFirst(4).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }

    /// 复制到剪贴板的一行命令。
    public var commandLine: String {
        "cd " + Self.quoteIfNeeded(directory) + " && " + arguments.map(Self.quoteIfNeeded).joined(separator: " ")
    }

    /// 一次性 `.command` 脚本：交互式登录 shell 运行（与用户自己的终端环境一致），
    /// 启动后先删除自己，CLI 退出后留在项目目录的 shell 里。
    public func script(shell: String = SessionResumePlan.preferredShell()) -> String {
        let fallbackShell = "\"${SHELL:-\(shell)}\""
        return """
        #!\(shell) -il
        # AIUsage: resume \(tool.displayName) session \(sessionID)
        rm -f -- "$0"
        cd -- \(Self.quote(directory)) || { echo "AIUsage: directory not found:" \(Self.quote(directory)); exec \(fallbackShell) -l; }
        \(arguments.map(Self.quote).joined(separator: " "))
        exec \(fallbackShell) -l

        """
    }

    /// 用户登录 shell 是 zsh 或 bash 时沿用它，其余（fish 等语法不同）退回 /bin/zsh。
    public static func preferredShell() -> String {
        guard let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell else { return "/bin/zsh" }
        let shell = String(cString: raw)
        return shell.hasSuffix("/zsh") || shell.hasSuffix("/bash") ? shell : "/bin/zsh"
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func quoteIfNeeded(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:@%+=,-")
        return !value.isEmpty && value.unicodeScalars.allSatisfy(safe.contains) ? value : quote(value)
    }
}
