import Foundation

// MARK: - Upstream Model List
// 上游模型列表的无 UI 读取逻辑。编辑器里的「获取模型」（ModelFetchState）与后台自动同步
// （ModelAutoSyncCoordinator）共用这一份，避免两套端点拼接 / 认证头 / 解析规则各自漂移。

/// 模型列表端点风格。两种风格的端点路径都是 <root>/v1/models
/// （base 末尾已含 /v1 则拼 /models，否则拼 /v1/models），区别在认证头。
enum ModelListEndpointStyle {
    /// OpenAI 兼容：Authorization: Bearer。
    case openAICompatible
    /// Anthropic 风格：附加 x-api-key + anthropic-version 头。
    case anthropic
}

enum UpstreamModelListError: LocalizedError, Equatable {
    case invalidURL
    case http(Int)
    case invalidResponse
    case emptyList

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return L("The Base URL is not valid.", "Base URL 无效。")
        case .http(401), .http(403):
            return L(
                "Authentication failed. Check the upstream API key.",
                "认证失败，请检查上游 API Key。"
            )
        case .http(404):
            return L(
                "This upstream does not expose a model list. You can still enter model names manually.",
                "该上游未提供模型列表，仍可手动输入模型名称。"
            )
        case .http(let status):
            return L(
                "Could not read models (HTTP \(status)).",
                "无法读取模型（HTTP \(status)）。"
            )
        case .invalidResponse:
            return L(
                "The upstream did not return a model list. Check the Base URL.",
                "上游返回的不是模型列表，请检查 Base URL 是否正确。"
            )
        case .emptyList:
            return L(
                "No model names were returned. You can still enter one manually.",
                "上游没有返回模型名称，仍可手动输入。"
            )
        }
    }
}

enum UpstreamModelListClient {
    /// 两种风格的端点路径都是 <root>/v1/models（base 末尾已含 /v1 则拼 /models）。
    static func modelsURL(baseURL: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        let path = trimmed.lowercased().hasSuffix("/v1") ? "/models" : "/v1/models"
        return URL(string: trimmed + path)
    }

    /// 读取上游模型 ID（去重、按自然序排序）。空列表视为错误，调用方据此不更新基线。
    static func fetchModelIDs(
        baseURL: String,
        apiKey: String,
        style: ModelListEndpointStyle,
        timeout: TimeInterval = 10
    ) async throws -> [String] {
        guard let url = modelsURL(baseURL: baseURL) else { throw UpstreamModelListError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if style == .anthropic {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            }
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpstreamModelListError.http(http.statusCode)
        }
        // 地址填错时常拿到 200 的 HTML 页面：给出可操作的提示，而不是 JSON 解析错误。
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw UpstreamModelListError.invalidResponse
        }
        let models = extractModelIDs(from: object)
        guard !models.isEmpty else { throw UpstreamModelListError.emptyList }
        return models
    }

    static func extractModelIDs(from object: Any) -> [String] {
        var names: [String] = []

        func appendRows(_ rows: [[String: Any]]) {
            names.append(contentsOf: rows.compactMap { row in
                (row["id"] as? String) ?? (row["name"] as? String)
            })
        }

        if let root = object as? [String: Any] {
            if let rows = root["data"] as? [[String: Any]] {
                appendRows(rows)
            } else if let rows = root["models"] as? [[String: Any]] {
                appendRows(rows)
            } else if let values = root["models"] as? [String] {
                names.append(contentsOf: values)
            }
        } else if let rows = object as? [[String: Any]] {
            appendRows(rows)
        } else if let values = object as? [String] {
            names.append(contentsOf: values)
        }

        var seen = Set<String>()
        return names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 基线比对用的上游标识：大小写、末尾斜杠与 /v1 差异不算换了上游。
    static func upstreamIdentity(baseURL: String) -> String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix("/v1") {
            value.removeLast(3)
            while value.hasSuffix("/") { value.removeLast() }
        }
        return value
    }
}

// MARK: - Public Price Update Rule

/// 自动定价的唯一裁决规则（编辑器一键获取与后台同步共用）：
/// - 未定价 → 填入候选价；
/// - 来源为 models.dev 的价格 → 候选价变了才更新（候选价可能来自提供商的手动价，此时随之转为手动）；
/// - 手动价格、明确免费 → 永不覆盖。
enum PublicPriceUpdate {
    /// - Parameters:
    ///   - existing: 当前生效价格；nil 表示未定价。
    ///   - candidate: 候选价（models.dev 匹配或提供商默认价）；nil 表示没有可用价格。
    ///   - targetCurrency: 未定价时写入使用的币种。已有价格沿用原币种。
    /// - Returns: 需要写入的新价格；nil 表示保持不变。
    static func resolve(
        existing: ProxyConfiguration.ModelPricing?,
        candidate: ProxyConfiguration.ModelPricing?,
        targetCurrency: ProxyConfiguration.PricingCurrency
    ) -> ProxyConfiguration.ModelPricing? {
        guard let candidate else { return nil }
        guard let existing else { return candidate.converted(to: targetCurrency) }
        guard existing.source?.kind == .modelsDev else { return nil }
        guard !sameRates(existing, candidate) else { return nil }
        return candidate.converted(to: existing.currency)
    }

    /// 按 USD 比较四项单价。允许极小的相对误差，避免 CNY 折算往返的浮点尾差引起反复改写。
    static func sameRates(
        _ lhs: ProxyConfiguration.ModelPricing,
        _ rhs: ProxyConfiguration.ModelPricing
    ) -> Bool {
        func close(_ a: Double, _ b: Double) -> Bool {
            abs(a - b) <= max(abs(a), abs(b)) * 1e-6 + 1e-12
        }
        return close(lhs.inputPerMillionUSD, rhs.inputPerMillionUSD)
            && close(lhs.outputPerMillionUSD, rhs.outputPerMillionUSD)
            && close(lhs.cacheCreatePerMillionUSD, rhs.cacheCreatePerMillionUSD)
            && close(lhs.cacheReadPerMillionUSD, rhs.cacheReadPerMillionUSD)
    }

    /// 一组价格里最常用的币种；没有价格时按 USD。新填入的价格跟随它，避免同一表格混币种。
    static func dominantCurrency(
        _ prices: [ProxyConfiguration.ModelPricing]
    ) -> ProxyConfiguration.PricingCurrency {
        let priced = prices.filter(\.hasAnyRate)
        let cny = priced.filter { $0.currency == .cny }.count
        return cny * 2 > priced.count ? .cny : .usd
    }
}

// MARK: - Applying Prices to Each Storage Shape
// 三类节点各自的价格存法不同；这里把「怎样算未定价 / 怎样写回」集中成一处，
// 编辑器一键获取与后台同步共用，保证两条路径行为一致。

extension PublicPriceUpdate {
    /// API 提供商模型：全零价格即未定价（来源为 models.dev 的零价除外）。
    static func updatedPricing(
        forProviderModel pricing: ProxyConfiguration.ModelPricing,
        candidate: ProxyConfiguration.ModelPricing?,
        targetCurrency: ProxyConfiguration.PricingCurrency
    ) -> ProxyConfiguration.ModelPricing? {
        let existing = (pricing.hasAnyRate || pricing.source?.kind == .modelsDev) ? pricing : nil
        return resolve(existing: existing, candidate: candidate, targetCurrency: targetCurrency)
    }

    /// OpenCode 模型条目：单价以节点币种存储（none 按 USD）。返回改写后的条目；nil 表示不变。
    static func updatedEntry(
        _ entry: OpenCodeModelEntry,
        nodeCurrency: OpenCodePricingCurrency,
        candidate: ProxyConfiguration.ModelPricing?
    ) -> OpenCodeModelEntry? {
        let currency: ProxyConfiguration.PricingCurrency = nodeCurrency == .cny ? .cny : .usd
        let existing: ProxyConfiguration.ModelPricing? =
            (entry.hasPricing || entry.pricingSource?.kind == .modelsDev)
            ? ProxyConfiguration.ModelPricing(
                inputPerMillion: entry.priceInputPerMillion,
                outputPerMillion: entry.priceOutputPerMillion,
                cacheCreatePerMillion: entry.priceCacheWritePerMillion,
                cacheReadPerMillion: entry.priceCacheReadPerMillion,
                currency: currency,
                source: entry.pricingSource
            )
            : nil
        guard let updated = resolve(existing: existing, candidate: candidate, targetCurrency: currency) else {
            return nil
        }
        var result = entry
        result.priceInputPerMillion = updated.inputPerMillion
        result.priceOutputPerMillion = updated.outputPerMillion
        result.priceCacheWritePerMillion = updated.cacheCreatePerMillion
        result.priceCacheReadPerMillion = updated.cacheReadPerMillion
        result.pricingSource = updated.source
        return result
    }
}

extension ProxyConfiguration.ModelCatalog {
    /// Claude / Codex 节点费用规则：缺失即未定价，存在的全零规则是「明确免费」，不会被改写。
    /// - Returns: 改动的模型数。
    @discardableResult
    mutating func applyPublicPrices(
        candidate: (String) -> ProxyConfiguration.ModelPricing?
    ) -> Int {
        let target = PublicPriceUpdate.dominantCurrency(Array(pricingOverrides.values))
        var changed = 0
        for model in models {
            guard let updated = PublicPriceUpdate.resolve(
                existing: pricingOverrides[model],
                candidate: candidate(model),
                targetCurrency: target
            ) else { continue }
            pricingOverrides[model] = updated
            changed += 1
        }
        return changed
    }
}
