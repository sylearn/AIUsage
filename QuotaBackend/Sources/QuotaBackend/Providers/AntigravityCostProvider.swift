import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Antigravity Cost Provider
// Antigravity 用量统计 = 两轨合并，与 Codex 架构对齐：
//   • 代理轨   = 代理用量永久归档（proxy-usage-antigravity；成本逐条冻结）
//   • 非代理轨 = 本地 Antigravity 会话 transcript.jsonl，只统计 token，成本恒 0（今天之前冻结、今天重算）
// 数据来源: ~/.gemini/antigravity/brain/*/transcript.jsonl 以及 ~/.config/aiusage/usage-archive/proxy-usage-antigravity-v1.json

public struct AntigravityCostProvider: ProviderFetcher {
    public let id = "antigravity-cost"
    public let displayName = "Antigravity"
    public let description = "Two-track Antigravity ledger: proxy usage + non-proxy session tokens"

    let homeDirectory: String
    let timeZone: TimeZone
    let environment: [String: String]

    static let nonProxyArchive = AntigravityNonProxyUsageArchiveStore()

    public func requestFullHistoryImport() async {
        _ = await Self.nonProxyArchive.needsFullHistoryImport(homeDirectory: homeDirectory)
    }

    public func needsFullHistoryImport() async -> Bool {
        await Self.nonProxyArchive.needsFullHistoryImport(homeDirectory: homeDirectory)
    }

    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        timeZone: TimeZone = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.timeZone = timeZone
        self.environment = environment
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let now = Date()
        let todayKey = dayKey(now)
        let proxyDays = loadProxyArchive()

        let shouldImportFullHistory = await Self.nonProxyArchive.consumeFullHistoryImportRequest(homeDirectory: homeDirectory)
        let scanWindowCutoff: Date? = shouldImportFullHistory ? nil : calendar().date(byAdding: .day, value: -1, to: calendar().startOfDay(for: now))

        let brainDir = resolveBrainDirectory()
        let files = brainDir.flatMap { collectTranscriptFiles(brainDirectory: $0, scanWindowCutoff: scanWindowCutoff) } ?? []

        let scannedByFile = files.isEmpty ? [:] : scanFilesByPath(files)
        var computedNonProxy: [String: CodexAggregateBucket] = [:]
        for fileBuckets in scannedByFile.values {
            for (dKey, bucket) in fileBuckets {
                computedNonProxy[dKey, default: .empty].merge(bucket)
            }
        }

        let nonProxyDays = await Self.nonProxyArchive.freeze(
            homeDirectory: homeDirectory,
            computed: computedNonProxy,
            scannedByFile: scannedByFile,
            todayKey: todayKey,
            completedFullHistory: shouldImportFullHistory
        )

        let combined = combineTrackDays(proxy: proxyDays, nonProxy: nonProxyDays)
        guard !combined.isEmpty else {
            throw ProviderError("no_usage_data", "No Antigravity usage recorded (neither session logs nor proxy archive)")
        }

        let weekRangeInfo = weekRange(now)
        let monthKey = monthKeyStr(now)

        let today = combined[todayKey] ?? .empty
        let currentWeek = aggregateDays(combined) { weekRangeInfo.dayKeys.contains($0) }
        let currentMonth = aggregateDays(combined) { $0.hasPrefix(monthKey) }
        let overall = aggregateDays(combined) { _ in true }
        let proxyOverall = aggregateDays(proxyDays) { _ in true }
        let nonProxyOverall = aggregateDays(nonProxyDays) { _ in true }

        let archiveDayCount = max(combined.count, 182) // 26 weeks for heatmap
        let overallRangeLabel = "All history"

        var extra: [String: AnyCodable] = [:]
        extra["today.estimatedCostUsd"] = AnyCodable(roundUsd(today.estimatedCostUsd))
        extra["today.totalTokens"] = AnyCodable(today.totalTokens)
        extra["today.key"] = AnyCodable(todayKey)

        extra["currentWeek.estimatedCostUsd"] = AnyCodable(roundUsd(currentWeek.estimatedCostUsd))
        extra["currentWeek.totalTokens"] = AnyCodable(currentWeek.totalTokens)
        extra["currentWeek.key"] = AnyCodable("\(weekRangeInfo.start)..\(weekRangeInfo.end)")

        extra["currentMonth.estimatedCostUsd"] = AnyCodable(roundUsd(currentMonth.estimatedCostUsd))
        extra["currentMonth.totalTokens"] = AnyCodable(currentMonth.totalTokens)
        extra["currentMonth.key"] = AnyCodable(monthKey)

        extra["timeline.hourly"] = AnyCodable([AnyCodable]())
        extra["timeline.daily"] = AnyCodable(encodeTimeline(trailingDailyTimeline(bucketsByDay: combined, now: now, dayCount: archiveDayCount)))

        extra["overall.estimatedCostUsd"] = AnyCodable(roundUsd(overall.estimatedCostUsd))
        extra["overall.totalTokens"] = AnyCodable(overall.totalTokens)
        extra["overall.usageRows"] = AnyCodable(overall.usageRows)
        extra["overall.rangeLabel"] = AnyCodable(overallRangeLabel)
        extra["overall.sessionCount"] = AnyCodable(files.count)

        extra["overall.proxy.estimatedCostUsd"] = AnyCodable(roundUsd(proxyOverall.estimatedCostUsd))
        extra["overall.proxy.totalTokens"] = AnyCodable(proxyOverall.totalTokens)
        extra["overall.nonProxy.estimatedCostUsd"] = AnyCodable(0.0)
        extra["overall.nonProxy.totalTokens"] = AnyCodable(nonProxyOverall.totalTokens)

        func encodeModelBreakdown(_ agg: CodexAggregateBucket) -> [AnyCodable] {
            let sorted = agg.models.values.sorted {
                if $0.estimatedCostUsd != $1.estimatedCostUsd { return $0.estimatedCostUsd > $1.estimatedCostUsd }
                return $0.totalTokens > $1.totalTokens
            }
            let totalCost = agg.estimatedCostUsd
            let totalTokens = agg.totalTokens
            return sorted.map { model -> AnyCodable in
                let pct = totalCost > 0
                    ? roundUsd(model.estimatedCostUsd / totalCost * 100)
                    : (totalTokens > 0 ? roundUsd(Double(model.totalTokens) / Double(totalTokens) * 100) : 0)
                return AnyCodable([
                    "model": AnyCodable(model.model),
                    "totalTokens": AnyCodable(model.totalTokens),
                    "inputTokens": AnyCodable(model.inputTokens),
                    "outputTokens": AnyCodable(model.outputTokens),
                    "cacheReadTokens": AnyCodable(model.cacheReadTokens),
                    "cacheCreateTokens": AnyCodable(model.cacheCreateTokens),
                    "estimatedCostUsd": AnyCodable(roundUsd(model.estimatedCostUsd)),
                    "estimatedCostDisplay": AnyCodable(formatCurrency(roundUsd(model.estimatedCostUsd))),
                    "percentage": AnyCodable(pct)
                ] as [String: AnyCodable])
            }
        }

        extra["currentMonth.models"] = AnyCodable(encodeModelBreakdown(currentMonth))
        extra["today.models"] = AnyCodable(encodeModelBreakdown(today))
        extra["currentWeek.models"] = AnyCodable(encodeModelBreakdown(currentWeek))
        extra["overall.models"] = AnyCodable(encodeModelBreakdown(overall))

        var modelTimelines: [AnyCodable] = []
        let archivedModelNames = Set(combined.values.flatMap { $0.models.keys })
        for modelName in archivedModelNames.sorted() {
            let daily = trailingDailyTimeline(bucketsByDay: combined, now: now, dayCount: archiveDayCount, model: modelName)
            guard !daily.isEmpty else { continue }
            modelTimelines.append(AnyCodable([
                "model": AnyCodable(modelName),
                "hourly": AnyCodable([AnyCodable]()),
                "daily": AnyCodable(encodeTimeline(daily, includeDetail: true))
            ] as [String: AnyCodable]))
        }
        extra["timeline.byModel"] = AnyCodable(modelTimelines)

        var usage = ProviderUsage(provider: id, label: displayName, extra: extra)
        var source = SourceInfo(mode: "auto", type: "antigravity-proxy-non-proxy")
        if let brainDir {
            source.roots = [brainDir]
        }
        usage.source = source
        return usage
    }
}
