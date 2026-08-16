import Foundation
import os.log

private let codexNonProxyArchiveLog = Logger(subsystem: "com.aiusage.quotabackend", category: "CodexNonProxyUsageArchive")

// MARK: - Codex Non-Proxy Usage Archive Store
// 非代理轨的「永久每日用量归档」：Codex JSONL 非代理行只统计 token、成本恒 0，并逐日冻结。
// 账号无关、每个 home 一张（按 homeDirectory 区分以隔离测试 / 多配置）。
//
// 冻结规则（与用户确认一致）：
// - 「今天之前」的日期：首次写入后即冻结，之后改价 / 重扫都不再变动 → 历史不可篡改。
// - 「今天」：仍在累加，每次扫描用当前 JSONL token 重算并覆盖；跨天后自然冻结。
//
// 持久化（永久、放 ~/.config/aiusage 避免被系统清理）:
//   <home>/.config/aiusage/usage-archive/codex-non-proxy-usage-v<version>.json
// 会读取并迁移旧 codex-subscription-usage-v<version>.json，避免既有历史 token 丢失。
// 复用 CodexUsageArchive 结构（历史不重算，按 fullHistoryImportedAt 标记一次性全量冻结）。

actor CodexNonProxyUsageArchiveStore {
    static let artifactVersion = 2
    private static let legacySubSourceSuffix = " (Sub)"
    private static let legacyApiSourceSuffix = " (API)"

    private var archives: [String: CodexUsageArchive] = [:]
    private var loaded: Set<String> = []

    /// 是否需要全量历史导入（首次：该 home 的归档从未完成全量扫描）。
    func needsFullHistoryImport(homeDirectory: String) -> Bool {
        load(homeDirectory).fullHistoryImportedAt == nil
    }

    /// 首次返回 true（触发一次全量扫描以冻结所有历史非代理日），完成后恒 false。
    func consumeFullHistoryImportRequest(homeDirectory: String) -> Bool {
        load(homeDirectory).fullHistoryImportedAt == nil
    }

    /// 冻结合并：past(<today) 仅在缺失时首次写入；today 每次覆盖重算；已冻结的 past 保持不动。
    /// 返回合并后的全部归档日，供 costSummary 聚合。
    func freeze(
        homeDirectory: String,
        computed: [String: CodexAggregateBucket],
        todayKey: String,
        completedFullHistory: Bool
    ) -> [String: CodexAggregateBucket] {
        var archive = load(homeDirectory)
        var changed = false

        for (day, bucket) in computed where !bucket.models.isEmpty {
            if day == todayKey {
                archive.days[day] = bucket
                changed = true
            } else if archive.days[day] == nil {
                archive.days[day] = bucket
                changed = true
            }
        }

        if computed[todayKey]?.models.isEmpty != false,
           archive.days.removeValue(forKey: todayKey) != nil {
            changed = true
        }

        if completedFullHistory, archive.fullHistoryImportedAt == nil {
            archive.fullHistoryImportedAt = SharedFormatters.iso8601String(from: Date())
            changed = true
        }

        if changed {
            archive.updatedAt = SharedFormatters.iso8601String(from: Date())
            archives[homeDirectory] = archive
            save(homeDirectory, archive)
        } else {
            archives[homeDirectory] = archive
        }
        return archive.days
    }

    // MARK: Disk

    private func load(_ homeDirectory: String) -> CodexUsageArchive {
        if let archive = archives[homeDirectory], loaded.contains(homeDirectory) { return archive }
        loaded.insert(homeDirectory)

        if let decoded = decodeArchive(at: Self.fileURL(homeDirectory: homeDirectory)) {
            let migrated = sanitizeArchive(decoded)
            archives[homeDirectory] = migrated
            if archiveNeedsSanitization(decoded) {
                save(homeDirectory, migrated)
            }
            return migrated
        }

        if let decoded = decodeArchive(at: Self.legacyFileURL(homeDirectory: homeDirectory)) {
            let migrated = sanitizeArchive(decoded)
            archives[homeDirectory] = migrated
            save(homeDirectory, migrated)
            return migrated
        }

        if Self.artifactVersion > 1,
           let decoded = decodeArchive(
            at: Self.legacyFileURL(homeDirectory: homeDirectory, version: Self.artifactVersion - 1),
            expectedVersion: Self.artifactVersion - 1
           ) {
            let migrated = sanitizeArchive(decoded)
            archives[homeDirectory] = migrated
            save(homeDirectory, migrated)
            return migrated
        }

        let fresh = CodexUsageArchive(version: Self.artifactVersion, updatedAt: "", days: [:])
        archives[homeDirectory] = fresh
        return fresh
    }

    private func decodeArchive(at url: URL, expectedVersion: Int? = nil) -> CodexUsageArchive? {
        let version = expectedVersion ?? Self.artifactVersion
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CodexUsageArchive.self, from: data),
              decoded.version == version else {
            return nil
        }
        return decoded
    }

    private func save(_ homeDirectory: String, _ archive: CodexUsageArchive) {
        let normalized = CodexUsageArchive(
            version: Self.artifactVersion,
            updatedAt: archive.updatedAt,
            days: archive.days,
            fullHistoryImportedAt: archive.fullHistoryImportedAt
        )
        let url = Self.fileURL(homeDirectory: homeDirectory)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(normalized)
            try data.write(to: url, options: .atomic)
        } catch {
            codexNonProxyArchiveLog.warning("Failed to save Codex non-proxy usage archive: \(String(describing: error), privacy: .public)")
        }
    }

    private func archiveNeedsSanitization(_ archive: CodexUsageArchive) -> Bool {
        archive.days.values.contains { bucket in
            bucket.estimatedCostUsd != 0 || bucket.models.contains { element in
                let modelKey = element.key
                let model = element.value
                return model.estimatedCostUsd != 0
                    || model.model != modelKey
                    || modelKey.hasSuffix(Self.legacySubSourceSuffix)
                    || modelKey.hasSuffix(Self.legacyApiSourceSuffix)
                    || modelKey.hasSuffix(CodexCostProvider.proxySourceSuffix)
                    || !modelKey.hasSuffix(CodexCostProvider.nonProxySourceSuffix)
            }
        }
    }

    private func sanitizeArchive(_ archive: CodexUsageArchive) -> CodexUsageArchive {
        var sanitized = archive
        sanitized.days = archive.days.compactMapValues { bucket in
            let sanitizedBucket = sanitizeBucket(bucket)
            return sanitizedBucket.models.isEmpty ? nil : sanitizedBucket
        }
        return sanitized
    }

    private func sanitizeBucket(_ bucket: CodexAggregateBucket) -> CodexAggregateBucket {
        var sanitized = CodexAggregateBucket.empty

        for (modelKey, var model) in bucket.models {
            guard let newKey = nonProxyModelKey(from: modelKey) else { continue }
            model.model = newKey
            model.estimatedCostUsd = 0
            if var existing = sanitized.models[newKey] {
                existing.merge(model)
                existing.estimatedCostUsd = 0
                sanitized.models[newKey] = existing
            } else {
                sanitized.models[newKey] = model
            }
            sanitized.totalTokens += model.totalTokens
            sanitized.usageRows += 1
        }

        sanitized.estimatedCostUsd = 0
        return sanitized
    }

    private func nonProxyModelKey(from modelKey: String) -> String? {
        if modelKey.hasSuffix(Self.legacySubSourceSuffix) {
            return "\(modelKey.dropLast(Self.legacySubSourceSuffix.count))\(CodexCostProvider.nonProxySourceSuffix)"
        }
        if modelKey.hasSuffix(Self.legacyApiSourceSuffix) {
            return nil
        }
        if modelKey.hasSuffix(CodexCostProvider.proxySourceSuffix) {
            return nil
        }
        if modelKey.hasSuffix(CodexCostProvider.nonProxySourceSuffix) {
            return modelKey
        }
        return nil
    }

    static func fileURL(homeDirectory: String) -> URL {
        let dir = (homeDirectory as NSString).appendingPathComponent(".config/aiusage/usage-archive")
        return URL(fileURLWithPath: dir, isDirectory: true)
            .appendingPathComponent("codex-non-proxy-usage-v\(artifactVersion).json")
    }

    static func legacyFileURL(homeDirectory: String, version: Int = artifactVersion) -> URL {
        let dir = (homeDirectory as NSString).appendingPathComponent(".config/aiusage/usage-archive")
        return URL(fileURLWithPath: dir, isDirectory: true)
            .appendingPathComponent("codex-subscription-usage-v\(version).json")
    }
}
