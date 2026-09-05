import Darwin
import Foundation
import SQLite3

/// 把旧版 AIUsage 会话固定下来的自定义 provider 改为 Codex 内置 `openai`。
///
/// 会话元数据只原位覆盖 `session_meta.payload.model_provider` 的几个字节，并用 JSON 空白补齐长度：
/// 文件大小与后续内容偏移均不改变；同时精确更新 Codex 已知索引表中同名的旧 provider 引用。
public enum CodexSessionProviderMigrator {
    public static let currentProvider = "openai"
    public static let legacyAIUsageProvider = "aiusage-proxy"

    private static let archiveVersion = 1
    private static let maximumMetadataBytes = 1024 * 1024
    // 只迁移 AIUsage 自己曾写入的 provider。其它工具创建的自定义 provider 不属于
    // AIUsage 的状态，不能在应用启动时擅自改写。
    private static let legacyProviders: Set<String> = [legacyAIUsageProvider]

    public struct Report: Sendable {
        public let scannedFiles: Int
        public let migratedFiles: Int
        public let migratedDatabaseRows: Int

        public init(scannedFiles: Int, migratedFiles: Int, migratedDatabaseRows: Int = 0) {
            self.scannedFiles = scannedFiles
            self.migratedFiles = migratedFiles
            self.migratedDatabaseRows = migratedDatabaseRows
        }
    }

    struct MigrationRecord: Codable, Sendable {
        let sessionID: String
        let originalProvider: String
        let migratedAt: String
        let valueOffset: UInt64
        let valueLength: Int
    }

    private struct MigrationArchive: Codable, Sendable {
        let version: Int
        var updatedAt: String
        var files: [String: MigrationRecord]
    }

    private struct Candidate {
        let path: String
        let sessionID: String
        let originalProvider: String
        let valueOffset: UInt64
        let originalValue: Data
        let replacementValue: Data
    }

    public enum MigrationError: LocalizedError {
        case invalidArchive
        case failedToRead(String)
        case failedToWriteArchive
        case fileChanged(String)
        case failedToPatch(String)
        case failedToMigrateIndex(String)

        public var errorDescription: String? {
            switch self {
            case .invalidArchive:
                return "AIUsage Codex 会话迁移记录无法读取。"
            case .failedToRead(let name):
                return "无法读取 Codex 会话文件：\(name)"
            case .failedToWriteArchive:
                return "无法写入 AIUsage Codex 会话迁移记录。"
            case .fileChanged(let name):
                return "Codex 会话文件在迁移期间发生变化：\(name)"
            case .failedToPatch(let name):
                return "无法迁移 Codex 会话文件：\(name)"
            case .failedToMigrateIndex(let name):
                return "无法迁移 Codex 会话索引：\(name)"
            }
        }
    }

    /// 幂等迁移默认 `~/.codex` 下的普通与已归档会话。
    @discardableResult
    public static func migrate(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) throws -> Report {
        let paths = sessionFiles(homeDirectory: homeDirectory)
        var candidates: [Candidate] = []
        candidates.reserveCapacity(paths.count / 8)

        for path in paths {
            candidates.append(contentsOf: try migrationCandidates(at: path))
        }

        if !candidates.isEmpty {
            var archive = try loadArchive(homeDirectory: homeDirectory)
            let migratedAt = timestamp(Date())
            var migratedAtBySession = archive.files.values.reduce(into: [String: String]()) { result, record in
                if let existing = result[record.sessionID] {
                    result[record.sessionID] = min(existing, record.migratedAt)
                } else {
                    result[record.sessionID] = record.migratedAt
                }
            }
            for candidate in candidates {
                let recordMigratedAt = migratedAtBySession[candidate.sessionID] ?? migratedAt
                archive.files[archiveKey(for: candidate)] = MigrationRecord(
                    sessionID: candidate.sessionID,
                    originalProvider: candidate.originalProvider,
                    migratedAt: recordMigratedAt,
                    valueOffset: candidate.valueOffset,
                    valueLength: candidate.originalValue.count
                )
                migratedAtBySession[candidate.sessionID] = recordMigratedAt
            }
            archive.updatedAt = migratedAt

            // 迁移记录先落盘：即使随后进程退出，统计仍知道该会话迁移前的真实来源。
            try saveArchive(archive, homeDirectory: homeDirectory)
        }

        for candidate in candidates {
            try patchInPlace(candidate)
        }
        let migratedDatabaseRows = try migrateDatabaseProviderReferences(homeDirectory: homeDirectory)
        return Report(
            scannedFiles: paths.count,
            migratedFiles: Set(candidates.map(\.path)).count,
            migratedDatabaseRows: migratedDatabaseRows
        )
    }

    /// 供 CodexCostProvider 使用：迁移前属于 AIUsage 代理的 token 行仍由代理归档负责，不能重复计入。
    static func legacyProxyCutoffs(homeDirectory: String) -> [String: Date] {
        guard let archive = try? loadArchive(homeDirectory: homeDirectory) else { return [:] }
        var result: [String: Date] = [:]
        for record in archive.files.values where record.originalProvider == legacyAIUsageProvider {
            guard let date = parseTimestamp(record.migratedAt) else { continue }
            if let existing = result[record.sessionID] {
                result[record.sessionID] = max(existing, date)
            } else {
                result[record.sessionID] = date
            }
        }
        return result
    }

    static func archiveURL(homeDirectory: String) -> URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".config/aiusage", isDirectory: true)
            .appendingPathComponent("codex-session-provider-migration-v\(archiveVersion).json")
    }

    // MARK: - Discovery

    private static func sessionFiles(homeDirectory: String) -> [String] {
        let codexHome = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
        let roots = [
            codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexHome.appendingPathComponent("archived_sessions", isDirectory: true),
        ]

        var paths: [String] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let item as URL in enumerator {
                guard item.pathExtension.lowercased() == "jsonl",
                      let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else {
                    continue
                }
                paths.append(item.path)
            }
        }
        return paths.sorted()
    }

    private static func migrationCandidates(at path: String) throws -> [Candidate] {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw MigrationError.failedToRead((path as NSString).lastPathComponent)
        }
        var candidates: [Candidate] = []
        var pending = Data()
        pending.reserveCapacity(64 * 1024)
        var pendingOffset: UInt64 = 0
        var reachedHistory = false
        do {
            while !reachedHistory {
                let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty {
                    if !pending.isEmpty {
                        try appendMigrationCandidate(
                            from: pending,
                            at: pendingOffset,
                            path: path,
                            to: &candidates,
                            reachedHistory: &reachedHistory
                        )
                    }
                    break
                }
                pending.append(chunk)

                while !reachedHistory, let newline = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending[..<newline])
                    try appendMigrationCandidate(
                        from: line,
                        at: pendingOffset,
                        path: path,
                        to: &candidates,
                        reachedHistory: &reachedHistory
                    )
                    let next = pending.index(after: newline)
                    let consumed = pending.distance(from: pending.startIndex, to: next)
                    pending.removeSubrange(pending.startIndex..<next)
                    pendingOffset += UInt64(consumed)
                }
                if pending.count > maximumMetadataBytes {
                    reachedHistory = true
                }
            }
            try handle.close()
        } catch let error as MigrationError {
            try? handle.close()
            throw error
        } catch {
            try? handle.close()
            throw MigrationError.failedToRead((path as NSString).lastPathComponent)
        }
        return candidates
    }

    private static func appendMigrationCandidate(
        from line: Data,
        at lineOffset: UInt64,
        path: String,
        to candidates: inout [Candidate],
        reachedHistory: inout Bool
    ) throws {
        guard line.count <= maximumMetadataBytes,
              let parsed = parseSessionMetadata(line) else {
            reachedHistory = true
            return
        }
        guard legacyProviders.contains(parsed.provider),
              let valueRange = jsonStringValueRange(
                  fields: ["model_provider", "modelProvider"],
                  expectedValue: parsed.provider,
                  in: line
              ) else { return }

        let original = line.subdata(in: valueRange)
        let replacementText = "\"\(currentProvider)\""
        guard original.count >= replacementText.utf8.count else {
            throw MigrationError.failedToPatch((path as NSString).lastPathComponent)
        }
        let replacement = Data(
            (replacementText + String(repeating: " ", count: original.count - replacementText.utf8.count)).utf8
        )
        let valueOffsetInLine = line.distance(from: line.startIndex, to: valueRange.lowerBound)
        candidates.append(Candidate(
            path: path,
            sessionID: parsed.sessionID,
            originalProvider: parsed.provider,
            valueOffset: lineOffset + UInt64(valueOffsetInLine),
            originalValue: original,
            replacementValue: replacement
        ))
    }

    private static func parseSessionMetadata(_ line: Data) -> (sessionID: String, provider: String)? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any] else {
            return nil
        }
        let provider = (payload["model_provider"] as? String) ?? (payload["modelProvider"] as? String)
        let sessionID = (payload["session_id"] as? String)
            ?? (payload["sessionId"] as? String)
            ?? (payload["id"] as? String)
        guard let provider, !provider.isEmpty, let sessionID, !sessionID.isEmpty else { return nil }
        return (sessionID, provider)
    }

    /// 返回包含双引号的 JSON 字符串值范围。
    private static func jsonStringValueRange(
        fields: [String],
        expectedValue: String,
        in data: Data
    ) -> Range<Data.Index>? {
        for field in fields {
            let needle = Data("\"\(field)\"".utf8)
            var searchStart = data.startIndex
            while searchStart < data.endIndex,
                  let keyRange = data.range(of: needle, options: [], in: searchStart..<data.endIndex) {
                var cursor = keyRange.upperBound
                skipWhitespace(data, cursor: &cursor)
                guard cursor < data.endIndex, data[cursor] == 0x3A else {
                    searchStart = keyRange.upperBound
                    continue
                }
                cursor += 1
                skipWhitespace(data, cursor: &cursor)
                guard cursor < data.endIndex, data[cursor] == 0x22 else {
                    searchStart = keyRange.upperBound
                    continue
                }
                let quoteStart = cursor
                cursor += 1
                let contentStart = cursor
                var escaped = false
                while cursor < data.endIndex {
                    let byte = data[cursor]
                    if escaped {
                        escaped = false
                    } else if byte == 0x5C {
                        escaped = true
                    } else if byte == 0x22 {
                        let raw = data.subdata(in: contentStart..<cursor)
                        if String(data: raw, encoding: .utf8) == expectedValue {
                            return quoteStart..<data.index(after: cursor)
                        }
                        break
                    }
                    cursor += 1
                }
                searchStart = keyRange.upperBound
            }
        }
        return nil
    }

    private static func skipWhitespace(_ data: Data, cursor: inout Data.Index) {
        while cursor < data.endIndex, [0x20, 0x09, 0x0D, 0x0A].contains(data[cursor]) {
            cursor += 1
        }
    }

    // MARK: - In-place patch

    private static func patchInPlace(_ candidate: Candidate) throws {
        let fd = open(candidate.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw MigrationError.failedToPatch((candidate.path as NSString).lastPathComponent)
        }
        defer { close(fd) }

        var current = [UInt8](repeating: 0, count: candidate.originalValue.count)
        let readCount = current.withUnsafeMutableBytes { buffer in
            pread(fd, buffer.baseAddress, buffer.count, off_t(candidate.valueOffset))
        }
        guard readCount == current.count else {
            throw MigrationError.failedToPatch((candidate.path as NSString).lastPathComponent)
        }
        guard Data(current) == candidate.originalValue else {
            throw MigrationError.fileChanged((candidate.path as NSString).lastPathComponent)
        }

        guard writeAll(candidate.replacementValue, to: fd, at: candidate.valueOffset), fsync(fd) == 0 else {
            // 常规文件几乎不会短写；仍在失败路径恢复原字节，避免留下半个 JSON 字符串。
            _ = writeAll(candidate.originalValue, to: fd, at: candidate.valueOffset)
            _ = fsync(fd)
            throw MigrationError.failedToPatch((candidate.path as NSString).lastPathComponent)
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32, at offset: UInt64) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return data.isEmpty }
            var total = 0
            while total < buffer.count {
                let written = pwrite(
                    fd,
                    base.advanced(by: total),
                    buffer.count - total,
                    off_t(offset) + off_t(total)
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                total += written
            }
            return true
        }
    }

    // MARK: - Codex thread indexes

    private struct DatabaseTarget: Hashable {
        let path: String
        let table: String
    }

    private static func migrateDatabaseProviderReferences(homeDirectory: String) throws -> Int {
        var migrated = 0
        for target in databaseTargets(homeDirectory: homeDirectory) {
            migrated += try updateProvider(in: target)
        }
        return migrated
    }

    private static func databaseTargets(homeDirectory: String) -> [DatabaseTarget] {
        let codexHome = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
        let roots = [codexHome, codexHome.appendingPathComponent("sqlite", isDirectory: true)]
        var targets = Set<DatabaseTarget>()

        for root in roots {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for item in items {
                guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else { continue }
                let name = item.lastPathComponent
                if name.hasPrefix("state_"), item.pathExtension.lowercased() == "sqlite" {
                    targets.insert(DatabaseTarget(path: item.path, table: "threads"))
                } else if name == "codex-dev.db" {
                    targets.insert(DatabaseTarget(path: item.path, table: "local_thread_catalog"))
                }
            }
        }
        return targets.sorted { lhs, rhs in lhs.path < rhs.path }
    }

    private static func updateProvider(in target: DatabaseTarget) throws -> Int {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(target.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw MigrationError.failedToMigrateIndex((target.path as NSString).lastPathComponent)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)

        guard try tableHasModelProvider(target.table, database: database) else { return 0 }
        let sql = "UPDATE \(target.table) SET model_provider = 'openai' WHERE model_provider = 'aiusage-proxy'"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw MigrationError.failedToMigrateIndex((target.path as NSString).lastPathComponent)
        }
        return Int(sqlite3_changes(database))
    }

    private static func tableHasModelProvider(_ table: String, database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw MigrationError.failedToMigrateIndex(table)
        }
        defer { sqlite3_finalize(statement) }

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let name = sqlite3_column_text(statement, 1) else { continue }
                if String(cString: name) == "model_provider" { return true }
            case SQLITE_DONE:
                return false
            default:
                throw MigrationError.failedToMigrateIndex(table)
            }
        }
    }

    // MARK: - Journal

    private static func archiveKey(for candidate: Candidate) -> String {
        "\(candidate.path)#\(candidate.valueOffset)"
    }

    private static func loadArchive(homeDirectory: String) throws -> MigrationArchive {
        let url = archiveURL(homeDirectory: homeDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return MigrationArchive(version: archiveVersion, updatedAt: "", files: [:])
        }
        guard let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(MigrationArchive.self, from: data),
              archive.version == archiveVersion else {
            throw MigrationError.invalidArchive
        }
        return archive
    }

    private static func saveArchive(_ archive: MigrationArchive, homeDirectory: String) throws {
        let url = archiveURL(homeDirectory: homeDirectory)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(archive)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw MigrationError.failedToWriteArchive
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
