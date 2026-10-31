import Foundation
import SQLite3

/// Read-only setup evidence. Never equates saved rules or global history with agent compliance.
public enum TokenSaverOnboarding {
    public enum Harness: String, CaseIterable, Sendable {
        case codex = "Codex", claude = "Claude Code", antigravity = "Antigravity", openCode = "OpenCode", hermes = "Hermes"
        public func rulesURL(home: URL) -> URL? {
            switch self {
            case .codex: TokenSaverAgentRules.rulePaths(home: home)[2]
            case .claude: TokenSaverAgentRules.rulePaths(home: home)[1]
            case .antigravity: TokenSaverAgentRules.rulePaths(home: home)[0]
            case .openCode: TokenSaverAgentRules.rulePaths(home: home)[3]
            case .hermes: TokenSaverAgentRules.hermesGlobalRuleURL(home: home)
            }
        }
    }
    public enum RulesState: String, Sendable { case current, missing, stale, off, unreadable, unsupported }
    public struct Snapshot: Sendable {
        public let rules: RulesState
        public let wrapperReady: Bool
        public let historyRecords: Int64?
        public let agentCommands: String?
    }
    public static func inspect(
        home: URL,
        harness: Harness,
        includeHistory: Bool = true,
        cachedHistoryRecords: Int64? = nil
    ) -> Snapshot {
        let wrapper = home.appendingPathComponent("Library/Application Support/AIUsage/bin/token-saver-rtk")
        let ready = (try? TokenSaverSettingsStore.contents(wrapper)) == Data(TokenSaverAgentRules.rtkWrapper.utf8)
            && FileManager.default.isExecutableFile(atPath: wrapper.path)
        var state = RulesState.unsupported
        var commands: String?
        if let url = harness.rulesURL(home: home) {
            do {
                let settings = try TokenSaverSettingsStore.load(home: home)
                let expected = try (harness == .hermes)
                    ? TokenSaverAgentRules.hermesBlock(settings, home: home)
                    : TokenSaverAgentRules.block(settings, home: home)
                let data = try TokenSaverSettingsStore.contents(url)
                guard let text = data.flatMap({ String(data: $0, encoding: .utf8) }) ?? (data == nil ? "" : nil) else {
                    throw TokenSaverSettingsStore.Failure.changed
                }
                if expected.isEmpty { state = text.contains(TokenSaverAgentRules.begin) ? .stale : .off }
                else if data == nil { state = .missing }
                else {
                    state = text.contains(expected)
                        && text.components(separatedBy: TokenSaverAgentRules.begin).count == 2
                        && text.components(separatedBy: TokenSaverAgentRules.end).count == 2 ? .current : .stale
                }
                let quotedRules = "'" + url.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
                // Optional self-report / terminal diagnostic only; never claims proof of automatic prompt loading.
                if state == .current, !settings.rtkEnabled || ready {
                    let base = "Optional diagnostic (self-report only, not proof of automatic prompt loading): without reading \(quotedRules) or any file on disk, state what coding-only output or code-simplicity instructions and active mode are in your current system instructions."
                    if settings.rtkEnabled {
                        let quotedWrapper = TokenSaverAgentRules.settingsPathForWrapper(home)
                        commands = "\(base) Then run \(quotedWrapper) --version once in your terminal tool to check RTK PATH resolution."
                    } else {
                        commands = base
                    }
                }
            } catch { state = .unreadable }
        }
        let history = includeHistory ? historyCount(home: home) : cachedHistoryRecords
        return Snapshot(rules: state, wrapperReady: ready, historyRecords: history, agentCommands: commands)
    }
    /// Only the default macOS RTK history. Missing/custom/unknown schemas stay unknown, never zero.
    private static func historyCount(home: URL) -> Int64? {
        let url = home.appendingPathComponent("Library/Application Support/rtk/history.db")
        guard (try? TokenSaverSettingsStore.rejectSymlinks(url)) != nil,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.int64Value <= 128 * 1024 * 1024,
              let modified = attrs[.modificationDate] as? Date,
              let inode = attrs[.systemFileNumber] as? NSNumber else { return nil }
        // ponytail: skip journal/WAL activity; coordinated live snapshots if this becomes necessary.
        let sidecars = ["-wal", "-shm", "-journal"].map { url.path + $0 }
        guard !sidecars.contains(where: FileManager.default.fileExists(atPath:)),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 128 * 1024 * 1024 + 1), bytes.count == size.intValue,
              let after = try? FileManager.default.attributesOfItem(atPath: url.path),
              after[.size] as? NSNumber == size,
              after[.modificationDate] as? Date == modified,
              after[.systemFileNumber] as? NSNumber == inode,
              !sidecars.contains(where: FileManager.default.fileExists(atPath:)) else { return nil }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("aiusage-rtk-" + UUID().uuidString)
        let snapshot = temporary.appendingPathComponent("history.sqlite")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try bytes.write(to: snapshot, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
        } catch { return nil }
        // Never open the source DB with SQLite: even READONLY can create its WAL/SHM sidecars.
        var db: OpaquePointer?
        guard sqlite3_open_v2(snapshot.absoluteString + "?mode=ro&immutable=1", &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        sqlite3_exec(db, "PRAGMA trusted_schema=OFF", nil, nil, nil)
        var deadline = Date.timeIntervalSinceReferenceDate + 0.5
        return withUnsafeMutablePointer(to: &deadline) { pointer in
            sqlite3_progress_handler(db, 1000, { context in
                guard let context else { return 1 }
                return Date.timeIntervalSinceReferenceDate > context.assumingMemoryBound(to: Double.self).pointee ? 1 : 0
            }, pointer)
            defer { sqlite3_progress_handler(db, 0, nil, nil) }
            var integrity: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA quick_check(1)", -1, &integrity, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(integrity) }
            guard sqlite3_step(integrity) == SQLITE_ROW,
                  let result = sqlite3_column_text(integrity, 0), String(cString: result) == "ok" else { return nil }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM commands", -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_int64(statement, 0)
        }
    }
}
