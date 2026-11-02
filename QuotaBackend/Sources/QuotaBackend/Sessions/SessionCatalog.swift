import Foundation

// MARK: - Session Center · Catalog
// 会话中心的唯一入口：并行扫描三个来源，增量缓存只在内存里，正文按需加载。
// 两个方法都是阻塞调用，请在后台线程调用。

public final class SessionCatalog: @unchecked Sendable {
    public static let shared = SessionCatalog()

    private let environment: SessionEnvironment
    private let claude: ClaudeSessionSource
    private let codex: CodexSessionSource
    private let openCode: OpenCodeSessionSource
    /// 各来源的缓存只在扫描时读写；扫描串行化即可保证线程安全。
    private let scanLock = NSLock()

    public init(environment: SessionEnvironment = SessionEnvironment()) {
        self.environment = environment
        claude = ClaudeSessionSource(environment: environment)
        codex = CodexSessionSource(environment: environment)
        openCode = OpenCodeSessionSource(environment: environment)
    }

    /// 全部会话，按最后活动时间倒序。
    public func scan() -> [SessionSummary] {
        scanLock.lock()
        defer { scanLock.unlock() }

        var results = [[SessionSummary]](repeating: [], count: 3)
        let resultLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 3) { index in
            let found: [SessionSummary]
            switch index {
            case 0: found = claude.scan()
            case 1: found = codex.scan()
            default: found = openCode.scan()
            }
            resultLock.lock()
            results[index] = found
            resultLock.unlock()
        }
        return results.joined().sorted {
            $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id
        }
    }

    /// 阅读视图用：最多 3 000 条，Claude Code 会话记住解析进度。
    public func transcript(for summary: SessionSummary) throws -> SessionTranscript {
        try transcript(for: summary, limit: TranscriptBuilder.renderLimit, cached: true)
    }

    func transcript(for summary: SessionSummary, limit: Int, cached: Bool) throws -> SessionTranscript {
        let home = environment.homeDirectory
        switch summary.locator {
        case .claudeFile(let path):
            return try claude.transcript(path: path, home: home, limit: limit, cached: cached)
        case .codexThread(let historyDatabase):
            return try CodexSessionSource.transcript(
                threadID: summary.sessionID, historyPath: historyDatabase, base: summary.directory, home: home, limit: limit)
        case .openCodeJSON, .openCodeDatabase:
            return try OpenCodeSessionSource.transcript(summary: summary, home: home, limit: limit)
        }
    }
}
