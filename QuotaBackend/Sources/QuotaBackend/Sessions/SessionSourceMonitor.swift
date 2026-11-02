import CoreServices
import Foundation

// MARK: - Session Center · Live updates
// 用 FSEvents 监听三家的数据目录，会话记录有变化就回调（latency 秒内的变化合并成一次）。
// 只认会话记录本身：Claude 的 projects/<目录>/<id>.jsonl 与进程登记 sessions/*.json；Codex 的 state_* / thread_history_*
// 数据库；OpenCode 的 storage/session|message|part 与 opencode.db。Codex 的日志库、Claude 的调试日志等每秒都在写，
// 一律过滤掉，免得白白重扫。-shm 只是共享内存索引，读库时也会变，同样忽略。
// 目录不存在就不监听；start() 可以反复调用，目录集合变了才重建监听，所以工具装好后下次刷新就能接上。

public final class SessionSourceMonitor: @unchecked Sendable {
    struct Roots: Equatable {
        var claude: String
        var codex: String
        var openCode: String
    }

    private let environment: SessionEnvironment
    private let latency: CFTimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "AIUsage.SessionSourceMonitor")
    private var stream: FSEventStreamRef?
    private var watched: [String] = []
    private var roots = Roots(claude: "", codex: "", openCode: "")

    public init(
        environment: SessionEnvironment = SessionEnvironment(),
        latency: TimeInterval = 1,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.environment = environment
        self.latency = latency
        self.onChange = onChange
    }

    deinit {
        if let stream { Self.release(stream) }
    }

    public func start() {
        queue.sync {
            let roots = Self.resolvedRoots(environment)
            let paths = [roots.claude, roots.codex, roots.openCode].filter { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            if stream != nil, paths == watched { return }
            stopLocked()
            self.roots = roots
            watched = paths
            guard !paths.isEmpty else { return }

            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
            guard let created = FSEventStreamCreate(
                nil, Self.callback, &context, paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                Self.release(created)
                return
            }
            stream = created
        }
    }

    public func stop() {
        queue.sync { stopLocked() }
    }

    public var isRunning: Bool {
        queue.sync { stream != nil }
    }

    private func stopLocked() {
        if let stream { Self.release(stream) }
        stream = nil
        watched = []
    }

    private static func release(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let monitor = Unmanaged<SessionSourceMonitor>.fromOpaque(info).takeUnretainedValue()
        let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        let flagList = Array(UnsafeBufferPointer(start: flags, count: count))
        monitor.handle(paths: list, flags: flagList)
    }

    /// 在 queue 上调用。
    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        // 事件丢失或需要整目录重扫时一律当作有变化。
        let rescan = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        if flags.contains(where: { $0 & rescan != 0 }) || paths.contains(where: { Self.isRelevant($0, roots: roots) }) {
            onChange()
        }
    }

    static func resolvedRoots(_ environment: SessionEnvironment) -> Roots {
        // FSEvents 报告的是真实路径，比较前用 realpath 解开符号链接（如 ~/.claude 链到 dotfiles 仓库）。
        // 不用 URL.resolvingSymlinksInPath：它会特意去掉 /private 前缀，与 FSEvents 报告的 /private/var/… 对不上。
        func resolve(_ path: String) -> String {
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return Roots(
            claude: resolve(environment.claudeRoot),
            codex: resolve(environment.codexRoot),
            openCode: resolve(environment.openCodeDataDirectory)
        )
    }

    static func isRelevant(_ path: String, roots: Roots) -> Bool {
        if path.hasSuffix("-shm") { return false }
        if let parts = components(of: path, under: roots.claude) {
            switch parts.first {
            case "projects":
                // projects、项目目录本身（新建或删除）或第二层的会话文件；更深的 subagents、tool-results 不算。
                return parts.count <= 2 || (parts.count == 3 && parts[2].hasSuffix(".jsonl"))
            case "sessions":
                return parts.count == 1 || (parts.count == 2 && parts[1].hasSuffix(".json"))
            default:
                return false
            }
        }
        if let parts = components(of: path, under: roots.codex) {
            return parts.count == 1 && (parts[0].hasPrefix("state_") || parts[0].hasPrefix("thread_history_"))
        }
        if let parts = components(of: path, under: roots.openCode) {
            if parts.count == 1 { return parts[0].hasPrefix("opencode.db") }
            return parts.count >= 2 && parts[0] == "storage" && ["session", "message", "part"].contains(parts[1])
        }
        return false
    }

    /// path 在 root 之下时返回相对路径的各段（root 本身返回空数组）。/private/var 与 /var 视为同一处。
    private static func components(of path: String, under root: String) -> [String]? {
        guard !root.isEmpty else { return nil }
        let candidates = path.hasPrefix("/private/") ? [path, String(path.dropFirst("/private".count))] : [path]
        for candidate in candidates {
            if candidate == root { return [] }
            if candidate.hasPrefix(root + "/") {
                return candidate.dropFirst(root.count + 1).split(separator: "/").map(String.init)
            }
        }
        return nil
    }
}
