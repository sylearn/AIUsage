import Foundation
import os.log

private let antigravityNonProxyArchiveLog = Logger(subsystem: "com.aiusage.quotabackend", category: "AntigravityNonProxyUsageArchive")

// MARK: - Antigravity Non-Proxy Usage Archive Store
// 非代理轨的「永久每日用量归档」：Antigravity 会话 transcript.jsonl 非代理行只统计 token、成本恒 0，并逐日冻结。
// 账号无关、每个 home 一张（按 homeDirectory 区分以隔离测试 / 多配置）。
//
// 冻结规则：
// - 「今天之前」的日期：首次写入后即冻结，之后改价 / 重扫都不再变动 → 历史不可篡改。
// - 「今天」：仍在累加，每次扫描用当前日志 token 重算并覆盖；跨天后自然冻结。
//
// 持久化:
//   <home>/.config/aiusage/usage-archive/antigravity-non-proxy-usage-v<version>.json

struct AntigravityUsageArchive: Codable, Sendable {
    let version: Int
    var updatedAt: String
    var days: [String: CodexAggregateBucket]
    var fullHistoryImportedAt: String?
    /// Per-file daily contributions (`[filePath: [dayKey: bucket]]`) so incremental mtime scans
    /// can apply exact per-file deltas to historical days without losing un-scanned closed files.
    var fileDays: [String: [String: CodexAggregateBucket]]?
}

actor AntigravityNonProxyUsageArchiveStore {
    static let artifactVersion = 2

    private var archives: [String: AntigravityUsageArchive] = [:]
    private var loaded: Set<String> = []

    func needsFullHistoryImport(homeDirectory: String) -> Bool {
        load(homeDirectory).fullHistoryImportedAt == nil
    }

    func consumeFullHistoryImportRequest(homeDirectory: String) -> Bool {
        load(homeDirectory).fullHistoryImportedAt == nil
    }

    func freeze(
        homeDirectory: String,
        computed: [String: CodexAggregateBucket],
        scannedByFile: [String: [String: CodexAggregateBucket]]? = nil,
        todayKey: String,
        completedFullHistory: Bool
    ) -> [String: CodexAggregateBucket] {
        var archive = load(homeDirectory)
        var changed = false
        let useIncrementalFileDeltas = !completedFullHistory && scannedByFile != nil && archive.fileDays != nil

        if !useIncrementalFileDeltas {
            for (day, bucket) in computed where !bucket.models.isEmpty {
                if day == todayKey {
                    archive.days[day] = bucket
                    changed = true
                } else if completedFullHistory {
                    if let existing = archive.days[day], bucket.totalTokens < existing.totalTokens {
                        // Preserve unrepresented historical tokens from purged transcripts during v1 -> v2 migration
                        let merged = Self.mergingPreservedRemainder(existing: existing, rescanned: bucket)
                        archive.days[day] = merged
                    } else {
                        archive.days[day] = bucket
                    }
                    changed = true
                } else if archive.days[day] == nil {
                    archive.days[day] = bucket
                    changed = true
                }
            }
        }

        if useIncrementalFileDeltas, let scannedByFile {
            var trackedFiles = Self.canonicalizeFileDays(archive.fileDays ?? [:])
            for (rawFilePath, newDayMap) in scannedByFile {
                let filePath = AntigravityCostProvider.canonicalTranscriptKey(rawFilePath)
                var updatedDayMap = trackedFiles[filePath] ?? [:]
                var fileUpdated = trackedFiles[filePath] == nil
                for (day, newFileBucket) in newDayMap where !newFileBucket.models.isEmpty {
                    let oldFileBucket = updatedDayMap[day] ?? .empty
                    guard newFileBucket.totalTokens > oldFileBucket.totalTokens else { continue }
                    let delta = Self.positiveDelta(from: oldFileBucket, to: newFileBucket)
                    guard delta.totalTokens > 0 else { continue }
                    var dayBucket = archive.days[day] ?? .empty
                    dayBucket.merge(delta)
                    archive.days[day] = dayBucket
                    var nextFileBucket = oldFileBucket
                    nextFileBucket.merge(delta)
                    updatedDayMap[day] = nextFileBucket
                    fileUpdated = true
                    changed = true
                }
                if fileUpdated {
                    trackedFiles[filePath] = updatedDayMap
                    changed = true
                }
            }
            archive.fileDays = trackedFiles
        } else if let scannedByFile, !scannedByFile.isEmpty {
            archive.fileDays = Self.canonicalizeFileDays(scannedByFile)
            changed = true
        }

        if !useIncrementalFileDeltas,
           computed[todayKey]?.models.isEmpty != false,
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

    /// Computes `new - old` for a single transcript file's contribution on a past day.
    private static func positiveDelta(from old: CodexAggregateBucket, to new: CodexAggregateBucket) -> CodexAggregateBucket {
        guard old.totalTokens > 0 else { return new }
        var delta = CodexAggregateBucket.empty
        for (modelKey, newModel) in new.models {
            let oldModel = old.models[modelKey]
            let dIn = max(0, newModel.inputTokens - (oldModel?.inputTokens ?? 0))
            let dOut = max(0, newModel.outputTokens - (oldModel?.outputTokens ?? 0))
            let dRead = max(0, newModel.cacheReadTokens - (oldModel?.cacheReadTokens ?? 0))
            let dCreate = max(0, newModel.cacheCreateTokens - (oldModel?.cacheCreateTokens ?? 0))
            let dTotal = max(0, newModel.totalTokens - (oldModel?.totalTokens ?? 0))
            guard dTotal > 0 else { continue }
            let m = CodexModelAggregate(
                model: modelKey,
                totalTokens: dTotal,
                inputTokens: dIn,
                outputTokens: dOut,
                cacheReadTokens: dRead,
                cacheCreateTokens: dCreate,
                estimatedCostUsd: 0
            )
            delta.models[modelKey] = m
            delta.totalTokens += dTotal
        }
        delta.usageRows = max(0, new.usageRows - old.usageRows)
        return delta
    }

    /// When a full rescan finds fewer tokens than an existing v1 day (because old transcripts were deleted),
    /// keeps the rescanned model buckets and preserves the missing historical token remainder from `existing`.
    private static func mergingPreservedRemainder(
        existing: CodexAggregateBucket,
        rescanned: CodexAggregateBucket
    ) -> CodexAggregateBucket {
        let missingTotal = existing.totalTokens - rescanned.totalTokens
        guard missingTotal > 0 else { return rescanned }
        var merged = rescanned
        let fallbackModelKey = existing.models.values.max(by: { $0.totalTokens < $1.totalTokens })?.model
            ?? ("gemini-3.8-flash" + AntigravityCostProvider.nonProxySourceSuffix)
        let rescannedIn = rescanned.models.values.reduce(0) { $0 + $1.inputTokens }
        let rescannedOut = rescanned.models.values.reduce(0) { $0 + $1.outputTokens }
        let rescannedRead = rescanned.models.values.reduce(0) { $0 + $1.cacheReadTokens }
        let rescannedCreate = rescanned.models.values.reduce(0) { $0 + $1.cacheCreateTokens }
        let existingIn = existing.models.values.reduce(0) { $0 + $1.inputTokens }
        let existingOut = existing.models.values.reduce(0) { $0 + $1.outputTokens }
        let existingRead = existing.models.values.reduce(0) { $0 + $1.cacheReadTokens }
        let existingCreate = existing.models.values.reduce(0) { $0 + $1.cacheCreateTokens }

        var remainder = CodexModelAggregate(
            model: fallbackModelKey,
            totalTokens: missingTotal,
            inputTokens: max(0, existingIn - rescannedIn),
            outputTokens: max(0, existingOut - rescannedOut),
            cacheReadTokens: max(0, existingRead - rescannedRead),
            cacheCreateTokens: max(0, existingCreate - rescannedCreate),
            estimatedCostUsd: 0
        )
        if var current = merged.models[fallbackModelKey] {
            current.merge(remainder)
            merged.models[fallbackModelKey] = current
        } else {
            remainder.model = fallbackModelKey
            merged.models[fallbackModelKey] = remainder
        }
        merged.totalTokens = existing.totalTokens
        merged.usageRows = max(existing.usageRows, rescanned.usageRows)
        return merged
    }

    private static func canonicalizeFileDays(
        _ raw: [String: [String: CodexAggregateBucket]]
    ) -> [String: [String: CodexAggregateBucket]] {
        var out: [String: [String: CodexAggregateBucket]] = [:]
        for (rawKey, dayMap) in raw {
            let key = AntigravityCostProvider.canonicalTranscriptKey(rawKey)
            guard var existingMap = out[key] else {
                out[key] = dayMap
                continue
            }
            for (day, bucket) in dayMap {
                if let existingBucket = existingMap[day] {
                    if bucket.totalTokens > existingBucket.totalTokens {
                        existingMap[day] = bucket
                    }
                } else {
                    existingMap[day] = bucket
                }
            }
            out[key] = existingMap
        }
        return out
    }

    // MARK: - Disk Operations

    private func load(_ homeDirectory: String) -> AntigravityUsageArchive {
        if let archive = archives[homeDirectory], loaded.contains(homeDirectory) { return archive }
        loaded.insert(homeDirectory)

        let url = Self.fileURL(homeDirectory: homeDirectory)
        if let data = try? Data(contentsOf: url),
           var decoded = try? JSONDecoder().decode(AntigravityUsageArchive.self, from: data),
           decoded.version == Self.artifactVersion {
            if let existingFiles = decoded.fileDays {
                decoded.fileDays = Self.canonicalizeFileDays(existingFiles)
            }
            if decoded.fullHistoryImportedAt != nil && decoded.fileDays == nil {
                decoded.fullHistoryImportedAt = nil
            }
            archives[homeDirectory] = decoded
            return decoded
        }

        // Seed days from v1 if present, keeping fullHistoryImportedAt = nil so v2 runs a full rescan
        // while preserving any historical tokens from purged transcripts via mergingPreservedRemainder.
        let v1URL = Self.fileURL(homeDirectory: homeDirectory, version: 1)
        if let data = try? Data(contentsOf: v1URL),
           let decodedV1 = try? JSONDecoder().decode(CodexUsageArchive.self, from: data) {
            let seeded = AntigravityUsageArchive(
                version: Self.artifactVersion,
                updatedAt: decodedV1.updatedAt,
                days: decodedV1.days,
                fullHistoryImportedAt: nil,
                fileDays: nil
            )
            archives[homeDirectory] = seeded
            return seeded
        }

        let fresh = AntigravityUsageArchive(version: Self.artifactVersion, updatedAt: "", days: [:])
        archives[homeDirectory] = fresh
        return fresh
    }

    private func save(_ homeDirectory: String, _ archive: AntigravityUsageArchive) {
        let normalized = AntigravityUsageArchive(
            version: Self.artifactVersion,
            updatedAt: archive.updatedAt,
            days: archive.days,
            fullHistoryImportedAt: archive.fullHistoryImportedAt,
            fileDays: archive.fileDays
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
            antigravityNonProxyArchiveLog.warning("Failed to save Antigravity non-proxy usage archive: \(String(describing: error), privacy: .public)")
        }
    }

    static func fileURL(homeDirectory: String, version: Int = artifactVersion) -> URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".config/aiusage/usage-archive/antigravity-non-proxy-usage-v\(version).json")
    }
}
