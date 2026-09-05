import Foundation

// MARK: - Codex Cost Provider: Proxy Usage Archive Source
// Codex 代理轨数据源 = 代理用量永久归档（proxy-usage-codex-v<v>.json，App 侧 ProxyUsageArchiveStore
// 从 ProxyRequestLog 折叠写出，成本逐条冻结、支持同模型不同节点不同价、不可篡改）。
// QuotaBackend 只读该 JSON（无法 import App，故在此定义匹配 DTO）。模型名加 " (Proxy)" 标签以便和非代理轨区分。
//
// 数据来源: ~/.config/aiusage/usage-archive/proxy-usage-codex-v<version>.json

extension CodexCostProvider {
    static let proxyUsageArchiveVersion = 1

    struct LoadedProxyArchive {
        var days: [String: CodexAggregateBucket] = [:]
        var routing = CodexProxyRoutingSnapshot()
    }

    private struct ProxyUsageSessionAggDTO: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheCreateTokens: Int
    }

    private struct ProxyUsageModelAggDTO: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheCreateTokens: Int
        let costUSD: Double
        let requests: Int
        let pricingResolvedRequests: Int?
        /// session/conversation id → Codex 请求模型 → token。
        let sessions: [String: [String: ProxyUsageSessionAggDTO]]?
    }

    private struct ProxyUsageDayDTO: Decodable {
        let models: [String: ProxyUsageModelAggDTO]
    }

    private struct ProxyUsageArchiveDTO: Decodable {
        let version: Int
        let updatedAt: String
        let days: [String: ProxyUsageDayDTO]
    }

    func proxyUsageArchivePath() -> String {
        (homeDirectory as NSString)
            .appendingPathComponent(".config/aiusage/usage-archive/proxy-usage-codex-v\(Self.proxyUsageArchiveVersion).json")
    }

    /// 一次读取代理总量和会话路由凭据，确保展示与 JSONL 去重使用同一份归档快照。
    func loadProxyArchive() -> LoadedProxyArchive {
        let path = proxyUsageArchivePath()
        guard let data = FileManager.default.contents(atPath: path),
              let dto = try? JSONDecoder().decode(ProxyUsageArchiveDTO.self, from: data) else {
            var empty = LoadedProxyArchive()
            empty.routing.legacyProxyCutoffs = CodexSessionProviderMigrator.legacyProxyCutoffs(
                homeDirectory: homeDirectory
            )
            return empty
        }

        var result = LoadedProxyArchive()
        result.routing.legacyProxyCutoffs = CodexSessionProviderMigrator.legacyProxyCutoffs(
            homeDirectory: homeDirectory
        )
        for (day, dayDTO) in dto.days {
            var bucket = CodexAggregateBucket.empty
            for (modelName, agg) in dayDTO.models {
                let total = agg.inputTokens + agg.outputTokens + agg.cacheReadTokens + agg.cacheCreateTokens
                guard total > 0 else { continue }

                let tagged = "\(modelName)\(Self.proxySourceSuffix)"
                var m = CodexModelAggregate(model: tagged)
                m.inputTokens = agg.inputTokens
                m.outputTokens = agg.outputTokens
                m.cacheReadTokens = agg.cacheReadTokens
                m.cacheCreateTokens = agg.cacheCreateTokens
                m.totalTokens = total
                m.estimatedCostUsd = agg.costUSD
                let requestCount = max(agg.requests, 0)
                let resolvedCount = agg.pricingResolvedRequests ?? (agg.costUSD > 0 ? requestCount : 0)
                m.unpricedRequests = max(0, requestCount - resolvedCount)

                bucket.models[tagged] = m
                bucket.usageRows += requestCount
                bucket.totalTokens += total
                bucket.estimatedCostUsd += agg.costUSD

                for (sessionID, requestedModels) in agg.sessions ?? [:] {
                    for (requestedModel, usage) in requestedModels {
                        let normalized = normalizeModel(requestedModel)
                        var existing = result.routing.sessions[sessionID]?[day]?[normalized]
                            ?? CodexProxyTokenCoverage()
                        existing.merge(CodexProxyTokenCoverage(
                            inputTokens: usage.inputTokens,
                            outputTokens: usage.outputTokens,
                            cacheReadTokens: usage.cacheReadTokens,
                            cacheCreateTokens: usage.cacheCreateTokens
                        ))
                        result.routing.sessions[sessionID, default: [:]][day, default: [:]][normalized] = existing
                    }
                }
            }
            if !bucket.models.isEmpty { result.days[day] = bucket }
        }
        return result
    }
}
