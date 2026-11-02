import Foundation

// MARK: - Session Center · Models
// 三家编程 CLI（Claude Code / Codex / OpenCode）的本地会话统一成「列表摘要 + 正文」两层。
// 本模块只读，不写也不删原工具的任何文件。设计文档：docs/SESSION_CENTER_DESIGN.md

public enum SessionTool: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case codex
    case opencode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }
}

/// 原工具已经无法继续这段会话的原因。
public enum SessionResumeBlocker: String, Sendable, Hashable {
    /// 项目目录已不存在（Claude Code 只能在原目录下恢复会话）。
    case directoryMissing
    /// 原工具的会话记录已不在磁盘上。
    case recordMissing
}

/// 原工具此刻在用这个会话（每次扫描现算，不进缓存）。
public enum SessionActivity: String, Sendable, Hashable {
    /// 正在回复或执行工具。
    case working
    /// CLI 开着这个会话，在等用户输入（只有 Claude Code 登记了进程，能判断这一种）。
    case waiting
}

/// 列表里的一条会话。
public struct SessionSummary: Identifiable, Hashable, Sendable {
    public var id: String { tool.rawValue + ":" + sessionID }

    public let tool: SessionTool
    public let sessionID: String
    public let title: String
    public let directory: String?
    public let gitBranch: String?
    public let model: String?
    public let createdAt: Date?
    public let updatedAt: Date
    /// 提问轮数；拿不到正文的会话为 nil。
    public let promptCount: Int?
    public let tokens: Int?
    public let isPinned: Bool
    /// 能否预览正文（Codex 只剩压缩包的会话为 false，但仍可继续）。
    public let hasTranscript: Bool
    public let resumeBlocker: SessionResumeBlocker?
    /// 小写搜索文本：标题、目录、分支、会话 ID 与提问（截断到 8 KB）。
    let searchText: String
    /// 正文所在位置，只供本模块加载正文。
    let locator: SessionLocator
    /// nil 表示没有在进行。
    public internal(set) var activity: SessionActivity? = nil

    public var projectName: String? {
        guard let directory, !directory.isEmpty else { return nil }
        let name = (directory as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? directory : name
    }

    /// 多个关键词之间是「且」，不区分大小写。
    public func matches(_ query: String) -> Bool {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        return terms.allSatisfy { searchText.contains($0) }
    }
}

enum SessionLocator: Hashable, Sendable {
    case claudeFile(String)
    case codexThread(historyDatabase: String?)
    case openCodeJSON(storageRoot: String)
    case openCodeDatabase(path: String, layout: OpenCodeSessionLayout)
}

enum OpenCodeSessionLayout: String, Hashable, Sendable {
    /// 已发布版本：`session` / `message` / `part`。
    case v1
    /// 新结构：`session_v2` / `session_message`（工具调用内联在 data.content）。
    case v2
}

// MARK: - Transcript

public struct ToolStep: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case read, edit, command, search, web, mcp, agent, other
    }

    public let name: String
    /// 一行说明：文件路径、命令、搜索词或 MCP 工具名。
    public let detail: String
    public let kind: Kind
    public internal(set) var failed: Bool
    /// 失败原因的第一行。
    public internal(set) var failureNote: String?
    /// 读写涉及的文件（用于统计改动文件数）。
    public let paths: [String]
}

public enum TranscriptNotice: String, Sendable, Hashable {
    case contextCompacted
    case interrupted
}

public enum TranscriptEntry: Hashable, Sendable {
    case prompt(String)
    case reply(String)
    case steps([ToolStep])
    case notice(TranscriptNotice)
}

public struct TranscriptItem: Identifiable, Hashable, Sendable {
    public let id: Int
    public let entry: TranscriptEntry
    public let date: Date?
}

public struct TranscriptStats: Equatable, Sendable {
    public let prompts: Int
    public let toolCalls: Int
    public let failures: Int
    public let filesChanged: Int
}

public struct SessionTranscript: Equatable, Sendable {
    public let items: [TranscriptItem]
    /// 超过渲染上限而省略的早期条目数。
    public let omittedCount: Int
    public let stats: TranscriptStats
}

public enum SessionTranscriptError: Error, Equatable {
    /// 原工具没有留下可读的正文（例如 Codex 只剩 `.jsonl.zst` 压缩包）。
    case unavailable
    /// 文件或数据库读不了。
    case unreadable
}
