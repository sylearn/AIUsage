import Darwin
import Foundation

/// 把旧版 AIUsage 会话固定下来的自定义 provider 改为 Codex 内置 `openai`。
///
/// 迁移只原位覆盖 `session_meta.payload.model_provider` 的几个字节，并用 JSON 空白补齐长度：
/// 文件大小与后续内容偏移均不改变，因此不会和仍在追加 JSONL 的 Codex 进程争抢整文件替换。
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

        public init(scannedFiles: Int, migratedFiles: Int) {
            self.scannedFiles = scannedFiles
            self.migratedFiles = migratedFiles
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
            if let candidate = try migrationCandidate(at: path) {
                candidates.append(candidate)
            }
        }

        guard !candidates.isEmpty else {
            return Report(scannedFiles: paths.count, migratedFiles: 0)
        }

        var archive = try loadArchive(homeDirectory: homeDirectory)
        let migratedAt = timestamp(Date())
        for candidate in candidates {
            archive.files[candidate.path] = MigrationRecord(
                sessionID: candidate.sessionID,
                originalProvider: candidate.originalProvider,
                migratedAt: migratedAt,
                valueOffset: candidate.valueOffset,
                valueLength: candidate.originalValue.count
            )
        }
        archive.updatedAt = migratedAt

        // 迁移记录先落盘：即使随后进程退出，统计仍知道该会话迁移前的真实来源。
        try saveArchive(archive, homeDirectory: homeDirectory)

        var migrated = 0
        for candidate in candidates {
            try patchInPlace(candidate)
            migrated += 1
        }
        return Report(scannedFiles: paths.count, migratedFiles: migrated)
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

    private static func migrationCandidate(at path: String) throws -> Candidate? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw MigrationError.failedToRead((path as NSString).lastPathComponent)
        }
        var firstLine = Data()
        firstLine.reserveCapacity(16 * 1024)
        do {
            while firstLine.count < maximumMetadataBytes {
                let remaining = maximumMetadataBytes - firstLine.count
                let chunk = try handle.read(upToCount: min(64 * 1024, remaining)) ?? Data()
                if chunk.isEmpty { break }
                if let newline = chunk.firstIndex(of: 0x0A) {
                    firstLine.append(chunk[..<newline])
                    break
                }
                firstLine.append(chunk)
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw MigrationError.failedToRead((path as NSString).lastPathComponent)
        }

        // Codex rollout 的 session_meta 是第一行。只读取这一行，避免应用启动时为每个历史
        // rollout 吞掉最多 1 MB；超长或非标准文件保持原样，不做猜测性改写。
        guard let parsed = parseSessionMetadata(firstLine), legacyProviders.contains(parsed.provider),
              let valueRange = jsonStringValueRange(
                  fields: ["model_provider", "modelProvider"],
                  expectedValue: parsed.provider,
                  in: firstLine
              ) else { return nil }

        let original = firstLine.subdata(in: valueRange)
        let replacementText = "\"\(currentProvider)\""
        guard original.count >= replacementText.utf8.count else {
            throw MigrationError.failedToPatch((path as NSString).lastPathComponent)
        }
        let replacement = Data(
            (replacementText + String(repeating: " ", count: original.count - replacementText.utf8.count)).utf8
        )
        return Candidate(
            path: path,
            sessionID: parsed.sessionID,
            originalProvider: parsed.provider,
            valueOffset: UInt64(valueRange.lowerBound),
            originalValue: original,
            replacementValue: replacement
        )
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

    // MARK: - Journal

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
