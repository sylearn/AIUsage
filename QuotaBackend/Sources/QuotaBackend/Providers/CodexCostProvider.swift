import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Codex Cost Provider
// Codex 用量统计 = 两轨合并，皆「成本冻结、不可篡改」：
//   • 代理轨   = 代理用量永久归档（proxy-usage-codex；成本逐条冻结、同模型不同节点不同价）
//   • 非代理轨 = 本地 Codex JSONL 非代理行，只统计 token，成本恒 0（今天之前冻结、今天重算）
// JSONL 里的代理行被丢弃（已在代理用量归档里，避免双计）。
// 数据来源: ~/.codex/sessions、archived_sessions 或 $CODEX_HOME；以及 ~/.config/aiusage/usage-archive。

public struct CodexCostProvider: ProviderFetcher {
    public let id = "codex-cost"
    public let displayName = "Codex"
    public let description = "Two-track Codex ledger: proxy usage + non-proxy token usage"

    let homeDirectory: String
    let timeZone: TimeZone
    let environment: [String: String]

    static let sessionMetaNeedle = Data("\"session_meta\"".utf8)
    static let tokenCountNeedle = Data("\"token_count\"".utf8)
    static let turnContextNeedle = Data("\"turn_context\"".utf8)
    static let compactTurnContextTypeNeedle = Data("\"type\":\"turn_context\"".utf8)
    static let compactEventMsgTypeNeedle = Data("\"type\":\"event_msg\"".utf8)
    static let fileScanCache = CodexCostFileScanCache()
    /// 非代理轨永久归档（账号无关、每个 home 一张）。代理轨直接读代理用量归档文件。
    static let nonProxyArchive = CodexNonProxyUsageArchiveStore()
    static let scanCacheSchemaVersion = 5
    static let defaultScanDays = 30
    static let filenameDateRegex = try? NSRegularExpression(pattern: "(\\d{4}-\\d{2}-\\d{2})")

    public func requestFullHistoryImport() async {
        // 非代理归档自带「首次即全量」语义，这里无需额外标记；保留接口供 App 调用。
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

        // 首次（非代理归档从未完成全量）触发全量扫描以冻结所有历史非代理日；之后只扫窗口。
        let shouldImportFullHistory = await Self.nonProxyArchive.consumeFullHistoryImportRequest(homeDirectory: homeDirectory)
        let scanWindow = shouldImportFullHistory ? nil : currentScanWindow(now: now)

        // 1) 扫描 JSONL（非代理轨数据源）。无 Codex 日志也允许：代理轨可能仍有代理归档数据。
        let roots = resolveSessionRoots().filter { FileManager.default.fileExists(atPath: $0) }
        let files = roots.isEmpty ? [] : collectJSONLFiles(roots: roots, scanWindow: scanWindow)
        let snapshot = files.isEmpty ? CodexUsageSnapshot() : await scanFiles(files)
        relieveMallocPressure()

        // 2) 非代理轨：(Non-Proxy) 模型仅统计 token、成本恒 0 → 逐日冻结进永久归档。
        //    冻结的是 token 用量（今天之前冻结、今天重算），确保删本地日志后历史用量不丢。
        let computedNonProxy = buildNonProxyDays(snapshot: snapshot)
        let nonProxyDays = await Self.nonProxyArchive.freeze(
            homeDirectory: homeDirectory,
            computed: computedNonProxy,
            todayKey: todayKey,
            completedFullHistory: shouldImportFullHistory
        )

        // 3) 代理轨：读代理用量永久归档（成本逐条冻结）。
        let proxyDays = loadProxyDays()

        // 4) 合并两轨。
        let combined = combineTrackDays(proxy: proxyDays, nonProxy: nonProxyDays)
        guard !combined.isEmpty else {
            throw ProviderError("no_usage_data", "No Codex usage recorded (neither non-proxy logs nor proxy archive)")
        }

        let weekRange = currentWeekRange(now)
        let monthKey = monthKeyStr(now)

        let today = combined[todayKey] ?? .empty
        let currentWeek = aggregateDays(combined) { weekRange.dayKeys.contains($0) }
        let currentMonth = aggregateDays(combined) { $0.hasPrefix(monthKey) }
        let overall = aggregateDays(combined) { _ in true }
        let proxyOverall = aggregateDays(proxyDays) { _ in true }
        let nonProxyOverall = aggregateDays(nonProxyDays) { _ in true }

        let fallbackDays = max(combined.count, Self.defaultScanDays)
        let archiveDayCount = archivedDayCount(combined, now: now, fallback: fallbackDays)
        let overallRangeLabel = archivedRangeLabel(combined, fallback: scanWindow?.rangeLabel ?? "All history")

        var extra: [String: AnyCodable] = [:]
        extra["today.estimatedCostUsd"] = AnyCodable(roundUsd(today.estimatedCostUsd))
        extra["today.totalTokens"] = AnyCodable(today.totalTokens)
        extra["today.key"] = AnyCodable(todayKey)

        extra["currentWeek.estimatedCostUsd"] = AnyCodable(roundUsd(currentWeek.estimatedCostUsd))
        extra["currentWeek.totalTokens"] = AnyCodable(currentWeek.totalTokens)
        extra["currentWeek.key"] = AnyCodable("\(weekRange.start)..\(weekRange.end)")

        extra["currentMonth.estimatedCostUsd"] = AnyCodable(roundUsd(currentMonth.estimatedCostUsd))
        extra["currentMonth.totalTokens"] = AnyCodable(currentMonth.totalTokens)
        extra["currentMonth.key"] = AnyCodable(monthKey)

        // 代理归档无小时粒度、非代理小时口径与逐日冻结不一致 → hourly 留空，统计页按日呈现。
        extra["timeline.hourly"] = AnyCodable([AnyCodable]())
        extra["timeline.daily"] = AnyCodable(encodeTimeline(trailingDailyTimeline(bucketsByDay: combined, now: now, dayCount: archiveDayCount)))

        // 非代理轨不计费，不算「未定价」；仅代理轨可能因节点当时没配价而未定价（只看今天）。
        let unpriced = proxyUnpricedModels(proxyDays, todayKey: todayKey)
        extra["overall.estimatedCostUsd"] = AnyCodable(roundUsd(overall.estimatedCostUsd))
        extra["overall.totalTokens"] = AnyCodable(overall.totalTokens)
        extra["overall.usageRows"] = AnyCodable(overall.usageRows)
        extra["overall.rangeLabel"] = AnyCodable(overallRangeLabel)
        extra["overall.unpricedModels"] = AnyCodable(unpriced.sorted().map { AnyCodable($0) })
        extra["overall.sessionCount"] = AnyCodable(snapshot.sessionIds.count)

        // 两轨总计（统计页两轨 + 合计呈现用）。非代理轨不计费，故 nonProxy 成本恒 0，
        // 合计成本(overall.estimatedCostUsd) = 代理成本；非代理仅贡献 token 用量。
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
        var source = SourceInfo(mode: "auto", type: "codex-proxy-non-proxy")
        source.roots = roots
        usage.source = source
        return usage
    }
}
