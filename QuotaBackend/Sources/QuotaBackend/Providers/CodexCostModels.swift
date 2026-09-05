import Foundation

struct CodexScanWindow: Sendable {
    let sinceKey: String
    let untilKey: String
    let scanSinceKey: String
    let scanUntilKey: String
    let dayCount: Int
    let rangeLabel: String

    func containsReportDay(_ dayKey: String) -> Bool {
        dayKey >= sinceKey && dayKey <= untilKey
    }

    func containsScanDay(_ dayKey: String) -> Bool {
        dayKey >= scanSinceKey && dayKey <= scanUntilKey
    }
}

struct SessionMetadata: Codable, Sendable {
    let sessionId: String?
    let forkedFromId: String?
    let forkTimestamp: String?
    var modelProvider: String?
}

struct CodexTotals: Codable, Sendable {
    var input: Int
    var cached: Int
    var output: Int
}

struct CodexProxyTokenCoverage: Sendable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheCreateTokens = 0

    mutating func merge(_ other: Self) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheCreateTokens += other.cacheCreateTokens
    }
}

/// 实际经过 AIUsage 网关的 Codex token 覆盖，以及旧 provider 会话迁移的统计分界。
struct CodexProxyRoutingSnapshot: Sendable {
    typealias Models = [String: CodexProxyTokenCoverage]
    typealias Days = [String: Models]

    var sessions: [String: Days] = [:]
    var legacyProxyCutoffs: [String: Date] = [:]

    func coverage(for sessionID: String?) -> Days {
        guard let sessionID else { return [:] }
        return sessions[sessionID] ?? [:]
    }

    func isLegacyProxyRow(sessionID: String?, timestamp: Date) -> Bool {
        guard let sessionID, let cutoff = legacyProxyCutoffs[sessionID] else { return false }
        return timestamp <= cutoff
    }

    /// 文件扫描缓存必须随该会话的代理覆盖变化而失效，否则刚写入的路由凭据不会参与去重。
    func signature(for sessionID: String?) -> String {
        guard let sessionID else { return "no-session" }
        var parts = ["routing-v1"]
        if let cutoff = legacyProxyCutoffs[sessionID] {
            parts.append("legacy:\(cutoff.timeIntervalSince1970)")
        }
        for day in (sessions[sessionID] ?? [:]).keys.sorted() {
            parts.append(day)
            for model in (sessions[sessionID]?[day] ?? [:]).keys.sorted() {
                guard let value = sessions[sessionID]?[day]?[model] else { continue }
                parts.append(
                    "\(model):\(value.inputTokens):\(value.cacheReadTokens):\(value.cacheCreateTokens):\(value.outputTokens)"
                )
            }
        }
        return parts.joined(separator: "|")
    }
}

struct TimestampedTotals: Codable, Sendable {
    let timestamp: String
    let date: Date?
    let totals: CodexTotals
}

struct CodexRow: Codable, Sendable {
    let dayKey: String
    let model: String
    let inputTokens: Int
    let cacheReadTokens: Int
    var cacheCreateTokens = 0
    let outputTokens: Int
    let totalTokens: Int
    let estimatedCostUsd: Double?
}

struct CodexFileFingerprint: Codable, Equatable, Sendable {
    let path: String
    let size: UInt64
    let modifiedAt: TimeInterval
    let scanSignature: String
}

struct CodexModelAggregate: Codable, Sendable {
    var model: String
    var totalTokens = 0
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheCreateTokens = 0
    var unpricedRequests = 0
    var estimatedCostUsd = 0.0

    init(
        model: String,
        totalTokens: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreateTokens: Int = 0,
        unpricedRequests: Int = 0,
        estimatedCostUsd: Double = 0
    ) {
        self.model = model
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreateTokens = cacheCreateTokens
        self.unpricedRequests = unpricedRequests
        self.estimatedCostUsd = estimatedCostUsd
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case totalTokens
        case inputTokens
        case outputTokens
        case cacheReadTokens
        case cacheCreateTokens
        case unpricedRequests
        case estimatedCostUsd
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        cacheCreateTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreateTokens) ?? 0
        unpricedRequests = try c.decodeIfPresent(Int.self, forKey: .unpricedRequests) ?? 0
        estimatedCostUsd = try c.decodeIfPresent(Double.self, forKey: .estimatedCostUsd) ?? 0
    }

    mutating func record(row: CodexRow) {
        totalTokens += row.totalTokens
        inputTokens += row.inputTokens
        outputTokens += row.outputTokens
        cacheReadTokens += row.cacheReadTokens
        cacheCreateTokens += row.cacheCreateTokens
        estimatedCostUsd += row.estimatedCostUsd ?? 0
    }

    mutating func merge(_ other: CodexModelAggregate) {
        totalTokens += other.totalTokens
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheCreateTokens += other.cacheCreateTokens
        unpricedRequests += other.unpricedRequests
        estimatedCostUsd += other.estimatedCostUsd
    }
}

struct CodexAggregateBucket: Codable, Sendable {
    var usageRows = 0
    var totalTokens = 0
    var estimatedCostUsd = 0.0
    var models: [String: CodexModelAggregate] = [:]

    static var empty: CodexAggregateBucket { CodexAggregateBucket() }

    mutating func record(row: CodexRow) {
        usageRows += 1
        totalTokens += row.totalTokens
        estimatedCostUsd += row.estimatedCostUsd ?? 0

        var model = models[row.model] ?? CodexModelAggregate(model: row.model)
        model.record(row: row)
        models[row.model] = model
    }

    mutating func merge(_ other: CodexAggregateBucket) {
        usageRows += other.usageRows
        totalTokens += other.totalTokens
        estimatedCostUsd += other.estimatedCostUsd
        for (modelName, otherModel) in other.models {
            var model = models[modelName] ?? CodexModelAggregate(model: modelName)
            model.merge(otherModel)
            models[modelName] = model
        }
    }
}

struct CodexFileAggregate: Codable, Sendable {
    var sessionId: String?
    var unpricedModels: Set<String> = []
    var overall = CodexAggregateBucket.empty
    var days: [String: CodexAggregateBucket] = [:]
    var hours: [String: CodexAggregateBucket] = [:]

    init(sessionId: String? = nil) {
        self.sessionId = sessionId
    }

    mutating func record(row: CodexRow, hourKey: String) {
        if row.estimatedCostUsd == nil {
            unpricedModels.insert(row.model)
        }

        overall.record(row: row)
        days[row.dayKey, default: .empty].record(row: row)
        hours[hourKey, default: .empty].record(row: row)
    }
}

struct CodexUsageSnapshot: Sendable {
    var overall = CodexAggregateBucket.empty
    var days: [String: CodexAggregateBucket] = [:]
    var hours: [String: CodexAggregateBucket] = [:]
    var sessionIds: Set<String> = []
    var unpricedModels: Set<String> = []

    mutating func merge(_ file: CodexFileAggregate) {
        guard file.overall.usageRows > 0 else { return }

        overall.merge(file.overall)
        for (day, bucket) in file.days {
            days[day, default: .empty].merge(bucket)
        }
        for (hour, bucket) in file.hours {
            hours[hour, default: .empty].merge(bucket)
        }
        if let sessionId = file.sessionId {
            sessionIds.insert(sessionId)
        }
        unpricedModels.formUnion(file.unpricedModels)
    }
}

struct CodexParsedFile: Codable, Sendable {
    let fingerprint: CodexFileFingerprint
    let metadata: SessionMetadata?
    let aggregate: CodexFileAggregate
    let snapshots: [TimestampedTotals]?
}

struct CodexCostPersistentCache: Codable, Sendable {
    let version: Int
    var files: [String: CodexParsedFile]
}

struct CodexUsageArchive: Codable, Sendable {
    let version: Int
    var updatedAt: String
    var days: [String: CodexAggregateBucket]
    var fullHistoryImportedAt: String?
}
