import Foundation

// MARK: - models.dev Pricing Service
// models.dev 公开价格目录：下载、后台解析建索引、进程内缓存（过期后释放内存），以及按模型名精确匹配。
// 编辑器的「获取模型和价格」/「匹配公开价格」与后台自动同步共用。

enum ModelsDevPricingService {
    struct Match {
        let model: String
        let provider: String
        let pricing: ProxyConfiguration.ModelPricing
    }

    struct Preview {
        let matches: [Match]
        let unmatched: [String]
    }

    fileprivate struct ProviderInfo: Sendable {
        let id: String?
        let name: String?
        let apiHost: String?
        let models: [String: ModelInfo]
    }

    fileprivate struct ModelInfo: Sendable {
        let id: String?
        let name: String?
        let cost: CostInfo?
    }

    fileprivate struct CostInfo: Sendable {
        let input: Double?
        let output: Double?
        let cacheRead: Double?
        let cacheWrite: Double?

        var hasAnyValue: Bool {
            input != nil || output != nil || cacheRead != nil || cacheWrite != nil
        }
    }

    fileprivate struct IndexEntry: Sendable {
        let providerID: String
        let modelKey: String
    }

    /// 已下载并建好索引的 models.dev 目录。api.json 有数 MB：解析与建索引在后台线程完成，
    /// 之后单个模型的匹配是字典查找，不再对每个模型遍历全部提供商。
    struct Catalog: Sendable {
        fileprivate let providers: [String: ProviderInfo]
        fileprivate let idIndex: [String: [IndexEntry]]
        fileprivate let nameIndex: [String: [IndexEntry]]
        let fetchedAt: Date
    }

    /// 进程内缓存 + 并发请求合并：编辑器与后台同步同时要价格时只下载一次。
    /// 目录建好索引后约占数 MB；菜单栏应用常驻，过期即释放，下次用到再下载。
    private actor CatalogCache {
        private var catalog: Catalog?
        private var inFlight: Task<Catalog, Error>?
        private var eviction: Task<Void, Never>?

        func get(maxAge: TimeInterval) async throws -> Catalog {
            if let catalog, Date().timeIntervalSince(catalog.fetchedAt) < maxAge {
                return catalog
            }
            if let inFlight {
                return try await inFlight.value
            }
            let task = Task { try await ModelsDevPricingService.download() }
            inFlight = task
            defer { inFlight = nil }
            let fresh = try await task.value
            catalog = fresh
            scheduleEviction(after: maxAge)
            return fresh
        }

        private func scheduleEviction(after interval: TimeInterval) {
            eviction?.cancel()
            eviction = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(interval, 60) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.evict()
            }
        }

        private func evict() {
            catalog = nil
            eviction = nil
        }
    }

    private static let cache = CatalogCache()

    static func catalog(maxAge: TimeInterval = 60 * 60) async throws -> Catalog {
        try await cache.get(maxAge: maxAge)
    }

    private static func download() async throws -> Catalog {
        guard let url = URL(string: "https://models.dev/api.json") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("AIUsage", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        // 与 ProviderRefreshCoordinator 相同的跨工具链写法：Task.detached 保证真正离开主线程。
        return try await Task.detached(priority: .utility) {
            try Self.parseCatalog(data, fetchedAt: Date())
        }.value
    }

    /// 后台线程执行：只用 JSONSerialization 与 Sendable 值类型，不触碰主线程状态。
    nonisolated fileprivate static func parseCatalog(_ data: Data, fetchedAt: Date) throws -> Catalog {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        func number(_ value: Any?) -> Double? {
            (value as? NSNumber)?.doubleValue
        }

        var providers: [String: ProviderInfo] = [:]
        var idIndex: [String: [IndexEntry]] = [:]
        var nameIndex: [String: [IndexEntry]] = [:]

        for (providerID, rawProvider) in root {
            guard let provider = rawProvider as? [String: Any] else { continue }
            var models: [String: ModelInfo] = [:]
            for (modelKey, rawModel) in (provider["models"] as? [String: Any]) ?? [:] {
                guard let model = rawModel as? [String: Any] else { continue }
                let cost = (model["cost"] as? [String: Any]).map {
                    CostInfo(
                        input: number($0["input"]),
                        output: number($0["output"]),
                        cacheRead: number($0["cache_read"]),
                        cacheWrite: number($0["cache_write"])
                    )
                }
                let info = ModelInfo(id: model["id"] as? String, name: model["name"] as? String, cost: cost)
                models[modelKey] = info

                let entry = IndexEntry(providerID: providerID, modelKey: modelKey)
                var keys: Set<String> = [modelKey.lowercased()]
                if let id = info.id?.lowercased(), !id.isEmpty { keys.insert(id) }
                for key in keys { idIndex[key, default: []].append(entry) }
                if let name = info.name?.lowercased(), !name.isEmpty {
                    nameIndex[name, default: []].append(entry)
                }
            }
            providers[providerID] = ProviderInfo(
                id: provider["id"] as? String,
                name: provider["name"] as? String,
                apiHost: (provider["api"] as? String).flatMap { URL(string: $0)?.host?.lowercased() },
                models: models
            )
        }

        return Catalog(providers: providers, idIndex: idIndex, nameIndex: nameIndex, fetchedAt: fetchedAt)
    }

    static func preview(models: [String], upstreamBaseURL: String?) async throws -> Preview {
        let catalog = try await catalog()
        return preview(models: models, upstreamBaseURL: upstreamBaseURL, in: catalog)
    }

    static func preview(models: [String], upstreamBaseURL: String?, in catalog: Catalog) -> Preview {
        let preferred = preferredProviders(in: catalog, upstreamBaseURL: upstreamBaseURL)
        var matches: [Match] = []
        var unmatched: [String] = []
        for requestedModel in models {
            if let resolved = resolve(requestedModel, catalog: catalog, preferredProviderIDs: preferred) {
                matches.append(resolved)
            } else {
                unmatched.append(requestedModel)
            }
        }
        return Preview(matches: matches, unmatched: unmatched)
    }

    /// 模型名（去空白）→ 公开价格（USD）。只含精确匹配成功的模型。
    static func pricingMap(
        models: [String],
        upstreamBaseURL: String?,
        in catalog: Catalog
    ) -> [String: ProxyConfiguration.ModelPricing] {
        let preferred = preferredProviders(in: catalog, upstreamBaseURL: upstreamBaseURL)
        var result: [String: ProxyConfiguration.ModelPricing] = [:]
        for raw in models {
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, result[model] == nil,
                  let match = resolve(model, catalog: catalog, preferredProviderIDs: preferred) else { continue }
            result[model] = match.pricing
        }
        return result
    }

    private static func preferredProviders(in catalog: Catalog, upstreamBaseURL: String?) -> [String] {
        guard
            let upstreamBaseURL,
            let upstreamHost = URL(string: upstreamBaseURL)?.host?.lowercased()
        else { return [] }
        return catalog.providers.compactMap { providerID, provider in
            guard let providerHost = provider.apiHost,
                  providerHost == upstreamHost
                    || providerHost.hasSuffix(".\(upstreamHost)")
                    || upstreamHost.hasSuffix(".\(providerHost)")
            else { return nil }
            return providerID
        }
        .sorted()
    }

    private static func resolve(
        _ requestedModel: String,
        catalog: Catalog,
        preferredProviderIDs: [String]
    ) -> Match? {
        let normalized = requestedModel.lowercased()
        let explicitParts = requestedModel.split(separator: "/", maxSplits: 1).map(String.init)
        let explicitProvider = explicitParts.count == 2 ? explicitParts[0].lowercased() : nil
        let bareModel = (explicitParts.count == 2 ? explicitParts[1] : requestedModel).lowercased()

        // 同一 (provider, model) 只计一次：完整名与去前缀名可能命中同一条目。
        var seen = Set<String>()
        var allCandidates: [IndexEntry] = []
        for key in [normalized, bareModel] {
            for entry in catalog.idIndex[key] ?? [] where seen.insert("\(entry.providerID)\u{0}\(entry.modelKey)").inserted {
                allCandidates.append(entry)
            }
        }

        // 显式前缀与 Base URL 对应的提供商优先：第一个有命中的优先提供商即为结果集。
        var priority = preferredProviderIDs
        if let explicitProvider { priority.insert(explicitProvider, at: 0) }
        var candidates = allCandidates
        var visited = Set<String>()
        for providerID in priority where visited.insert(providerID).inserted {
            let hits = allCandidates.filter { $0.providerID == providerID }
            if !hits.isEmpty {
                candidates = hits
                break
            }
        }

        if candidates.isEmpty {
            candidates = catalog.nameIndex[normalized] ?? []
        }

        if candidates.count > 1,
           let canonicalProviderID = canonicalProviderID(for: bareModel),
           let canonical = candidates.first(where: { $0.providerID == canonicalProviderID }) {
            candidates = [canonical]
        }

        guard candidates.count == 1,
              let provider = catalog.providers[candidates[0].providerID],
              let model = provider.models[candidates[0].modelKey],
              let cost = model.cost,
              cost.hasAnyValue
        else { return nil }

        let providerID = candidates[0].providerID
        let providerName = provider.name ?? provider.id ?? providerID
        let pricing = ProxyConfiguration.ModelPricing(
            inputPerMillion: cost.input ?? 0,
            outputPerMillion: cost.output ?? 0,
            cacheCreatePerMillion: cost.cacheWrite ?? 0,
            cacheReadPerMillion: cost.cacheRead ?? 0,
            currency: .usd,
            source: .init(
                kind: .modelsDev,
                label: providerName,
                referenceURL: "https://models.dev",
                updatedAt: Date()
            )
        )
        return Match(model: requestedModel, provider: providerName, pricing: pricing)
    }

    private static func canonicalProviderID(for model: String) -> String? {
        let name = model.lowercased()
        if name.hasPrefix("claude-") { return "anthropic" }
        if name.hasPrefix("gpt-")
            || name.hasPrefix("chatgpt-")
            || name.range(of: #"^o[1-9]([-.]|$)"#, options: .regularExpression) != nil {
            return "openai"
        }
        if name.hasPrefix("gemini-") { return "google" }
        if name.hasPrefix("deepseek-") { return "deepseek" }
        if name.hasPrefix("grok-") { return "xai" }
        if name.hasPrefix("command-") { return "cohere" }
        if name.hasPrefix("mistral-")
            || name.hasPrefix("codestral-")
            || name.hasPrefix("pixtral-") {
            return "mistral"
        }
        if name.hasPrefix("qwen") { return "alibaba" }
        if name.hasPrefix("glm-") { return "zhipuai" }
        if name.hasPrefix("kimi-") { return "moonshotai" }
        if name.hasPrefix("minimax-") { return "minimax" }
        return nil
    }
}
