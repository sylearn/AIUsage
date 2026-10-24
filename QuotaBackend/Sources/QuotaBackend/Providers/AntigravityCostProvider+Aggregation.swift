import Foundation

// MARK: - Antigravity Cost Provider: Aggregation & Date Utils
// 按日聚合与时间线编码，复用通用聚合结构（CodexAggregateBucket / CodexModelAggregate）。
// 本地时区日界、timeline 提供 26 周（182 天）每日桶以支撑 Dashboard 热力图与用量统计。

extension AntigravityCostProvider {

    struct TimelineBucket {
        let bucket: String
        let label: String
        let estimatedCostUsd: Double
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheReadTokens: Int = 0
        var cacheCreateTokens: Int = 0
        let totalTokens: Int
    }

    static let proxySourceSuffix = " (Proxy)"
    static let nonProxySourceSuffix = " (Non-Proxy)"

    // MARK: - Aggregation

    func aggregateDays(
        _ bucketsByDay: [String: CodexAggregateBucket],
        matching: (String) -> Bool
    ) -> CodexAggregateBucket {
        var result = CodexAggregateBucket.empty
        for (day, bucket) in bucketsByDay where matching(day) {
            result.merge(bucket)
        }
        return result
    }

    typealias BucketMetrics = (
        estimatedCostUsd: Double,
        totalTokens: Int,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreateTokens: Int
    )

    func bucketMetrics(
        _ bucket: CodexAggregateBucket?,
        model: String?
    ) -> BucketMetrics {
        guard let bucket else { return (0, 0, 0, 0, 0, 0) }
        if let model {
            guard let m = bucket.models[model] else { return (0, 0, 0, 0, 0, 0) }
            return (
                m.estimatedCostUsd,
                m.totalTokens,
                m.inputTokens,
                m.outputTokens,
                m.cacheReadTokens,
                m.cacheCreateTokens
            )
        }
        var totalIn = 0
        var totalOut = 0
        var totalRead = 0
        var totalCreate = 0
        for m in bucket.models.values {
            totalIn += m.inputTokens
            totalOut += m.outputTokens
            totalRead += m.cacheReadTokens
            totalCreate += m.cacheCreateTokens
        }
        return (
            bucket.estimatedCostUsd,
            bucket.totalTokens,
            totalIn,
            totalOut,
            totalRead,
            totalCreate
        )
    }

    func trailingDailyTimeline(
        bucketsByDay: [String: CodexAggregateBucket],
        now: Date,
        dayCount: Int,
        model: String? = nil
    ) -> [TimelineBucket] {
        let cal = calendar()
        let today = cal.startOfDay(for: now)
        let count = max(dayCount, 1)
        let start = cal.date(byAdding: .day, value: -(count - 1), to: today) ?? today

        return (0..<count).compactMap { offset -> TimelineBucket? in
            guard let day = cal.date(byAdding: .day, value: offset, to: start) else { return nil }
            let key = dayKey(day)
            let m = bucketMetrics(bucketsByDay[key], model: model)
            return TimelineBucket(
                bucket: key,
                label: dayBucketLabel(day),
                estimatedCostUsd: roundUsd(m.estimatedCostUsd),
                inputTokens: m.inputTokens,
                outputTokens: m.outputTokens,
                cacheReadTokens: m.cacheReadTokens,
                cacheCreateTokens: m.cacheCreateTokens,
                totalTokens: m.totalTokens
            )
        }
    }

    func encodeTimeline(_ timeline: [TimelineBucket], includeDetail: Bool = false) -> [AnyCodable] {
        timeline.map { bucket in
            var dict: [String: AnyCodable] = [
                "bucket": AnyCodable(bucket.bucket),
                "label": AnyCodable(bucket.label),
                "usd": AnyCodable(bucket.estimatedCostUsd),
                "tokens": AnyCodable(bucket.totalTokens),
                "estimatedCostUsd": AnyCodable(bucket.estimatedCostUsd),
                "totalTokens": AnyCodable(bucket.totalTokens)
            ]
            if includeDetail || bucket.inputTokens > 0 || bucket.outputTokens > 0 {
                dict["inputTokens"] = AnyCodable(bucket.inputTokens)
                dict["outputTokens"] = AnyCodable(bucket.outputTokens)
                dict["cacheReadTokens"] = AnyCodable(bucket.cacheReadTokens)
                dict["cacheCreateTokens"] = AnyCodable(bucket.cacheCreateTokens)
            }
            return AnyCodable(dict)
        }
    }

    func combineTrackDays(
        proxy: [String: CodexAggregateBucket],
        nonProxy: [String: CodexAggregateBucket]
    ) -> [String: CodexAggregateBucket] {
        var out = proxy
        for (day, bucket) in nonProxy {
            out[day, default: .empty].merge(bucket)
        }
        return out
    }

    // MARK: - Date Helpers

    func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    func dayKey(_ date: Date) -> String {
        let comps = calendar().dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    func monthKeyStr(_ date: Date) -> String {
        let comps = calendar().dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", comps.year ?? 1970, comps.month ?? 1)
    }

    func dayBucketLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar()
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    func weekRange(_ date: Date) -> (start: String, end: String, dayKeys: Set<String>) {
        let cal = calendar()
        let weekday = cal.component(.weekday, from: date)
        let daysFromMonday = (weekday + 5) % 7
        let startOfWeek = cal.date(byAdding: .day, value: -daysFromMonday, to: cal.startOfDay(for: date)) ?? date

        var dayKeys = Set<String>()
        for i in 0..<7 {
            if let day = cal.date(byAdding: .day, value: i, to: startOfWeek) {
                dayKeys.insert(dayKey(day))
            }
        }

        let endOfWeek = cal.date(byAdding: .day, value: 6, to: startOfWeek) ?? date
        return (dayKey(startOfWeek), dayKey(endOfWeek), dayKeys)
    }

    func roundUsd(_ val: Double) -> Double {
        (val * 10000).rounded() / 10000
    }

    func formatCurrency(_ val: Double) -> String {
        String(format: "$%.2f", val)
    }
}
