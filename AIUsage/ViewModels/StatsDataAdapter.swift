import SwiftUI
import QuotaBackend

// MARK: - StatsDataAdapter
// 将多个 ProviderData.costSummary 聚合为统计页所需格式，
// 替代 ProxyViewModel+Aggregation 作为用量统计页的数据源，
// 统一全应用本地 costSummary 口径。

@MainActor
final class StatsDataAdapter {

    // MARK: - Family Filter

    enum SourceFamily: String, CaseIterable {
        case all, claude, codex, opencode, antigravity

        func matches(_ provider: ProviderData) -> Bool {
            switch self {
            case .all:         return true
            case .claude:      return provider.baseProviderId == "claude"
            case .codex:       return provider.baseProviderId == "codex-cost"
            case .opencode:    return provider.baseProviderId == "opencode"
            case .antigravity: return provider.baseProviderId == "antigravity-cost"
            }
        }
    }

    // MARK: - Result Types

    struct OverallStats {
        var cost: Double = 0
        var tokens: Int = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheReadTokens: Int = 0
        var cacheCreationTokens: Int = 0
        var modelCount: Int = 0

        var cacheTokens: Int { cacheReadTokens + cacheCreationTokens }

        var cacheHitRate: Double {
            let denom = inputTokens + cacheReadTokens + cacheCreationTokens
            guard denom > 0 else { return 0 }
            return Double(cacheReadTokens) / Double(denom) * 100
        }
    }

    struct ModelTimePoint: Identifiable {
        let id: String
        let date: Date
        let model: String
        var cost: Double
        var tokens: Int
    }

    struct ModelAggregate: Identifiable {
        let id: String
        let model: String
        var cost: Double
        var tokens: Int
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheCreationTokens: Int

        var cacheTokens: Int { cacheReadTokens + cacheCreationTokens }

        var cacheHitRate: Double {
            let denom = inputTokens + cacheReadTokens + cacheCreationTokens
            guard denom > 0 else { return 0 }
            return Double(cacheReadTokens) / Double(denom) * 100
        }
    }

    // MARK: - Aggregation

    func aggregatedSummary(
        providers: [ProviderData],
        family: SourceFamily = .all
    ) -> CostSummary? {
        let items = providers
            .filter { family.matches($0) }
            .compactMap { provider -> (provider: ProviderData, summary: CostSummary)? in
                guard let summary = provider.costSummary else { return nil }
                return (provider, summary)
            }
        guard !items.isEmpty else { return nil }

        let summaries = items.map(\.summary)

        // 仅「综合」需要家族前缀（如「Codex / gpt-5」）来区分多家族同名模型；
        // 单选 Claude / Codex 时只有一个家族，模型名不加前缀，更干净。
        let qualify = family == .all

        let timeline = Self.aggregateTimeline(summaries.compactMap(\.timeline))
        let monthBreakdown = Self.aggregateModelBreakdowns(
            items.flatMap { Self.qualifiedBreakdowns($0.summary.modelBreakdown, provider: $0.provider, qualify: qualify) }
        )
        let todayBreakdown = Self.aggregateModelBreakdowns(
            items.flatMap { Self.qualifiedBreakdowns($0.summary.modelBreakdownToday, provider: $0.provider, qualify: qualify) }
        )
        let weekBreakdown = Self.aggregateModelBreakdowns(
            items.flatMap { Self.qualifiedBreakdowns($0.summary.modelBreakdownWeek, provider: $0.provider, qualify: qualify) }
        )
        let overallBreakdown = Self.aggregateModelBreakdowns(
            items.flatMap { Self.qualifiedBreakdowns($0.summary.modelBreakdownOverall, provider: $0.provider, qualify: qualify) }
        )
        let modelTimelines = Self.aggregateModelTimelines(
            items.flatMap { Self.qualifiedTimelines($0.summary.modelTimelines, provider: $0.provider, qualify: qualify) }
        )

        return CostSummary(
            today: Self.aggregatePeriod(summaries.map(\.today), label: L("Today", "今天")),
            week: Self.aggregatePeriod(summaries.map(\.week), label: L("This Week", "本周")),
            month: Self.aggregatePeriod(summaries.map(\.month), label: L("This Month", "本月")),
            overall: Self.aggregatePeriod(summaries.map(\.overall), label: L("All Sources", "综合")),
            timeline: timeline,
            modelBreakdown: monthBreakdown.isEmpty ? nil : monthBreakdown,
            modelBreakdownToday: todayBreakdown.isEmpty ? nil : todayBreakdown,
            modelBreakdownWeek: weekBreakdown.isEmpty ? nil : weekBreakdown,
            modelBreakdownOverall: overallBreakdown.isEmpty ? nil : overallBreakdown,
            modelTimelines: modelTimelines.isEmpty ? nil : modelTimelines
        )
    }

    // MARK: - Memoized Pipeline
    // 统计页一次渲染会多处读取 summary（摘要/分布/趋势/热力图），切换轨道/家族还会整页重渲。
    // 这里按「家族 + 轨道 + provider 内容指纹（id@fetchedAt）」缓存最终过滤结果：数据未变时直接命中，
    // 避免对全年 timeline 反复重聚合压垮主线程，导致顶部切换器点不动 / 切不动。

    private var summaryCacheKey: String?
    private var summaryCacheValue: CostSummary?
    /// 每当 summary 内容真正改变（缓存未命中）就自增，作为下游 timeline 记忆化的廉价版本号。
    private var summaryVersion: UInt64 = 0

    func summary(
        providers: [ProviderData],
        family: SourceFamily,
        track: UsageTrack
    ) -> CostSummary? {
        let key = Self.summarySignature(providers: providers, family: family, track: track)
        if key == summaryCacheKey { return summaryCacheValue }
        let filtered = aggregatedSummary(providers: providers, family: family)?.filtered(by: track)
        summaryCacheKey = key
        summaryCacheValue = filtered
        summaryVersion &+= 1
        return filtered
    }

    /// provider 内容指纹：仅用 id + fetchedAt（每次刷新都会变），生成成本极低且能在数据未变时稳定命中。
    private static func summarySignature(
        providers: [ProviderData],
        family: SourceFamily,
        track: UsageTrack
    ) -> String {
        let fingerprint = providers
            .filter { family.matches($0) }
            .map { "\($0.id)@\($0.fetchedAt ?? "-")" }
            .sorted()
            .joined(separator: ",")
        return "\(family.rawValue)|\(track.rawValue)|\(fingerprint)"
    }

    // MARK: - Derived Stats

    func overallStats(from summary: CostSummary?, period: DistributionPeriod = .overall) -> OverallStats {
        let costPeriod: CostPeriod?
        let breakdowns: [ModelCostBreakdown]?

        switch period {
        case .today:
            costPeriod = summary?.today
            breakdowns = summary?.modelBreakdownToday
        case .week:
            costPeriod = summary?.week
            breakdowns = summary?.modelBreakdownWeek
        case .month:
            costPeriod = summary?.month
            breakdowns = summary?.modelBreakdown
        case .overall:
            costPeriod = summary?.overall
            breakdowns = summary?.modelBreakdownOverall
        }

        let models = breakdowns ?? []
        return OverallStats(
            cost: costPeriod?.usd ?? 0,
            tokens: costPeriod?.tokens ?? models.reduce(0) { $0 + $1.totalTokens },
            inputTokens: models.reduce(0) { $0 + $1.inputTokens },
            outputTokens: models.reduce(0) { $0 + $1.outputTokens },
            cacheReadTokens: models.reduce(0) { $0 + $1.cacheReadTokens },
            cacheCreationTokens: models.reduce(0) { $0 + $1.cacheCreateTokens },
            modelCount: models.count
        )
    }

    private var timeSeriesCacheKey: String?
    private var timeSeriesCacheValue: [ModelTimePoint] = []

    /// 模型时间序列。趋势图虽已移除，详情表的 sparkline/配色仍依赖它；
    /// 而展开行、勾选对比、改变窗口宽度都会触发整页重渲，若每次都重遍历全量 timeline 会拖慢交互。
    /// 这里按「summary 版本 + 粒度 + 时间范围」记忆化：数据未变时（仅 UI 状态变化）直接命中。
    /// 契约：调用前先取过 `summary(...)`（视图 body 即如此），故 `summaryVersion` 与传入 summary 对应。
    func modelTimeSeries(
        from summary: CostSummary?,
        granularity: CostGranularity,
        timeRange: ChartTimeRange
    ) -> [ModelTimePoint] {
        let key = "\(summaryVersion)|\(granularity.rawValue)|\(timeRange.rawValue)"
        if key == timeSeriesCacheKey { return timeSeriesCacheValue }
        let result = computeModelTimeSeries(from: summary, granularity: granularity, timeRange: timeRange)
        timeSeriesCacheKey = key
        timeSeriesCacheValue = result
        return result
    }

    private func computeModelTimeSeries(
        from summary: CostSummary?,
        granularity: CostGranularity,
        timeRange: ChartTimeRange
    ) -> [ModelTimePoint] {
        guard let modelTimelines = summary?.modelTimelines else { return [] }

        let startDate = timeRange.startDate()
        var result: [ModelTimePoint] = []

        for series in modelTimelines {
            let raw = granularity == .hourly
                ? (!series.hourly.isEmpty ? series.hourly : series.daily)
                : (!series.daily.isEmpty ? series.daily : series.hourly)

            for point in raw {
                guard let date = BucketDateParser.parseOptional(point.bucket) else { continue }
                if let start = startDate, date < start { continue }

                result.append(ModelTimePoint(
                    id: "\(point.bucket)|\(series.model)",
                    date: date,
                    model: Self.displayModelLabel(series.model),
                    cost: point.usd,
                    tokens: point.tokens
                ))
            }
        }

        return result.sorted { ($0.date, $0.model) < ($1.date, $1.model) }
    }

    func modelAggregates(
        from summary: CostSummary?,
        period: DistributionPeriod
    ) -> [ModelAggregate] {
        let breakdowns: [ModelCostBreakdown]?
        switch period {
        case .today:   breakdowns = summary?.modelBreakdownToday
        case .week:    breakdowns = summary?.modelBreakdownWeek
        case .month:   breakdowns = summary?.modelBreakdown
        case .overall: breakdowns = summary?.modelBreakdownOverall
        }

        return (breakdowns ?? []).map { item in
            let label = Self.displayModelLabel(item.model)
            return ModelAggregate(
                id: label,
                model: label,
                cost: item.estimatedCostUsd,
                tokens: item.totalTokens,
                inputTokens: item.inputTokens,
                outputTokens: item.outputTokens,
                cacheReadTokens: item.cacheReadTokens,
                cacheCreationTokens: item.cacheCreateTokens
            )
        }
    }

    func dataDateRange(
        from summary: CostSummary?
    ) -> (earliest: Date?, latest: Date?, days: Int) {
        guard let timeline = summary?.timeline else { return (nil, nil, 0) }

        let points = !timeline.daily.isEmpty ? timeline.daily : timeline.hourly
        let dates = points.compactMap { BucketDateParser.parseOptional($0.bucket) }
        guard let earliest = dates.min(), let latest = dates.max() else { return (nil, nil, 0) }

        let cal = Calendar.current
        let days = max(1, (cal.dateComponents([.day], from: cal.startOfDay(for: earliest),
                                              to: cal.startOfDay(for: latest)).day ?? 0) + 1)
        return (earliest, latest, days)
    }

    func allModels(from summary: CostSummary?) -> [String] {
        guard let timelines = summary?.modelTimelines else { return [] }
        return timelines.map { Self.displayModelLabel($0.model) }.sorted()
    }

    // MARK: - Private Aggregation Helpers

    static let sourceQualifierSeparator = " / "

    private static func qualifiedBreakdowns(
        _ breakdowns: [ModelCostBreakdown]?,
        provider: ProviderData,
        qualify: Bool
    ) -> [ModelCostBreakdown] {
        guard let breakdowns else { return [] }
        guard qualify else { return breakdowns }
        return breakdowns.map { item in
            ModelCostBreakdown(
                model: sourceQualifiedModel(displayModelLabel(item.model), provider: provider),
                totalTokens: item.totalTokens,
                inputTokens: item.inputTokens,
                outputTokens: item.outputTokens,
                cacheReadTokens: item.cacheReadTokens,
                cacheCreateTokens: item.cacheCreateTokens,
                estimatedCostUsd: item.estimatedCostUsd,
                percentage: item.percentage
            )
        }
    }

    private static func qualifiedTimelines(
        _ series: [ModelTimelineSeries]?,
        provider: ProviderData,
        qualify: Bool
    ) -> [ModelTimelineSeries] {
        guard let series else { return [] }
        guard qualify else { return series }
        return series.map { item in
            ModelTimelineSeries(
                model: sourceQualifiedModel(displayModelLabel(item.model), provider: provider),
                hourly: item.hourly,
                daily: item.daily
            )
        }
    }

    private static func sourceQualifiedModel(_ model: String, provider: ProviderData) -> String {
        "\(provider.label)\(sourceQualifierSeparator)\(model)"
    }

    /// 展示用模型名清洗：OpenCode 受管节点用量的模型键带内部归因前缀 `aiusage-<slug>/<model>`
    /// （数据键保留以做节点归因 + 跨路径合并），展示时剥掉 `aiusage-` 前缀更干净。
    /// 非 OpenCode 受管模型名不以此开头，等价 no-op。
    static func displayModelLabel(_ model: String) -> String {
        let prefix = "aiusage-"
        guard model.hasPrefix(prefix) else { return model }
        return String(model.dropFirst(prefix.count))
    }

    private static func aggregatePeriod(
        _ periods: [CostPeriod?],
        label: String
    ) -> CostPeriod? {
        let resolved = periods.compactMap { $0 }
        guard !resolved.isEmpty else { return nil }
        let hasTokens = resolved.contains { $0.tokens != nil }
        return CostPeriod(
            usd: resolved.reduce(0) { $0 + $1.usd },
            tokens: hasTokens ? resolved.reduce(0) { $0 + ($1.tokens ?? 0) } : nil,
            rangeLabel: label
        )
    }

    private static func aggregateTimeline(
        _ timelines: [CostTimeline]
    ) -> CostTimeline? {
        guard !timelines.isEmpty else { return nil }
        return CostTimeline(
            hourly: aggregateTimelinePoints(timelines.map(\.hourly)),
            daily: aggregateTimelinePoints(timelines.map(\.daily))
        )
    }

    private static func aggregateTimelinePoints(
        _ pointGroups: [[CostTimelinePoint]]
    ) -> [CostTimelinePoint] {
        var buckets: [String: (label: String, usd: Double, tokens: Int,
                               inp: Int, out: Int, cR: Int, cC: Int)] = [:]
        for point in pointGroups.flatMap({ $0 }) {
            guard BucketDateParser.parseOptional(point.bucket) != nil else { continue }
            var c = buckets[point.bucket] ?? (point.label, 0, 0, 0, 0, 0, 0)
            c.usd += point.usd
            c.tokens += point.tokens
            c.inp += point.inputTokens ?? 0
            c.out += point.outputTokens ?? 0
            c.cR += point.cacheReadTokens ?? 0
            c.cC += point.cacheCreateTokens ?? 0
            buckets[point.bucket] = c
        }

        return buckets
            .map { bucket, v in
                CostTimelinePoint(
                    bucket: bucket, label: v.label, usd: v.usd, tokens: v.tokens,
                    inputTokens: v.inp > 0 ? v.inp : nil,
                    outputTokens: v.out > 0 ? v.out : nil,
                    cacheReadTokens: v.cR > 0 ? v.cR : nil,
                    cacheCreateTokens: v.cC > 0 ? v.cC : nil
                )
            }
            .sorted { BucketDateParser.parse($0.bucket) < BucketDateParser.parse($1.bucket) }
    }

    private static func aggregateModelBreakdowns(
        _ breakdowns: [ModelCostBreakdown]
    ) -> [ModelCostBreakdown] {
        guard !breakdowns.isEmpty else { return [] }

        var byModel: [String: (totalTokens: Int, inputTokens: Int, outputTokens: Int,
                               cacheRead: Int, cacheCreate: Int, cost: Double)] = [:]
        for item in breakdowns {
            var c = byModel[item.model] ?? (0, 0, 0, 0, 0, 0)
            c.totalTokens += item.totalTokens
            c.inputTokens += item.inputTokens
            c.outputTokens += item.outputTokens
            c.cacheRead += item.cacheReadTokens
            c.cacheCreate += item.cacheCreateTokens
            c.cost += item.estimatedCostUsd
            byModel[item.model] = c
        }

        let totalUsd = byModel.values.reduce(0) { $0 + $1.cost }
        let totalTokens = byModel.values.reduce(0) { $0 + $1.totalTokens }

        return byModel.map { model, t in
            let pct: Double
            if totalUsd > 0 {
                pct = t.cost / totalUsd * 100
            } else if totalTokens > 0 {
                pct = Double(t.totalTokens) / Double(totalTokens) * 100
            } else {
                pct = 0
            }

            return ModelCostBreakdown(
                model: model,
                totalTokens: t.totalTokens,
                inputTokens: t.inputTokens,
                outputTokens: t.outputTokens,
                cacheReadTokens: t.cacheRead,
                cacheCreateTokens: t.cacheCreate,
                estimatedCostUsd: t.cost,
                percentage: pct
            )
        }
        .sorted {
            if $0.estimatedCostUsd != $1.estimatedCostUsd { return $0.estimatedCostUsd > $1.estimatedCostUsd }
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            return $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending
        }
    }

    private static func aggregateModelTimelines(
        _ series: [ModelTimelineSeries]
    ) -> [ModelTimelineSeries] {
        guard !series.isEmpty else { return [] }
        let grouped = Dictionary(grouping: series, by: \.model)
        return grouped.map { model, items in
            ModelTimelineSeries(
                model: model,
                hourly: aggregateTimelinePoints(items.map(\.hourly)),
                daily: aggregateTimelinePoints(items.map(\.daily))
            )
        }
        .sorted { $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending }
    }
}

// MARK: - BucketDateParser (shared)

enum BucketDateParser {
    private final class CachedDate {
        let date: Date?
        init(_ date: Date?) { self.date = date }
    }

    private static let lock = NSLock()
    private static let cache: NSCache<NSString, CachedDate> = {
        let cache = NSCache<NSString, CachedDate>()
        cache.countLimit = 2_048
        return cache
    }()

    private static let hourly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HH"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let daily: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func parseOptional(_ bucket: String) -> Date? {
        let cacheKey = bucket as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached.date }

        lock.lock()
        defer { lock.unlock() }

        if let cached = cache.object(forKey: cacheKey) { return cached.date }

        let parsed = hourly.date(from: bucket) ?? daily.date(from: bucket)
        cache.setObject(CachedDate(parsed), forKey: cacheKey)
        return parsed
    }

    static func parse(_ bucket: String) -> Date {
        parseOptional(bucket) ?? .distantPast
    }
}
