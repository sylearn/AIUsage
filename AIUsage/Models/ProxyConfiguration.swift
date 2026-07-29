import Foundation
import SwiftUI
import QuotaBackend

// MARK: - Node Type

enum NodeType: String, Codable, CaseIterable {
    case anthropicDirect
    case openaiProxy
    case codexProxy

    /// Codex 节点：把 OpenAI 兼容上游接入 Codex（写 ~/.codex/config.toml，本地起 QuotaServer）。
    var isCodex: Bool { self == .codexProxy }

    /// 列表卡片徽章里的协议短名（比接口类型名更紧凑）。
    var badgeProtocolName: String {
        switch self {
        case .anthropicDirect: return "Anthropic"
        case .openaiProxy: return "OpenAI"
        case .codexProxy: return "Codex"
        }
    }

    /// 接口类型图标（编辑器卡片 / 列表徽章共用）。
    var iconName: String {
        switch self {
        case .anthropicDirect: return "bolt.horizontal.fill"
        case .openaiProxy: return "arrow.triangle.swap"
        case .codexProxy: return "terminal.fill"
        }
    }
}

// MARK: - Node Family
// 节点家族决定它们在 UI / 激活轨道上的归属：
// Claude 家族写 ~/.claude/settings.json，Codex 家族写 ~/.codex/config.toml，二者互不影响。

enum ProxyNodeFamily: Hashable {
    case claude   // anthropicDirect + openaiProxy
    case codex    // codexProxy

    func contains(_ type: NodeType) -> Bool {
        switch self {
        case .claude: return type != .codexProxy
        case .codex: return type == .codexProxy
        }
    }

    var isCodex: Bool { self == .codex }
}

// MARK: - Proxy Configuration

struct ProxyConfiguration: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var nodeType: NodeType
    var isEnabled: Bool

    // Anthropic Direct fields
    var anthropicBaseURL: String
    var anthropicAPIKey: String
    var usePassthroughProxy: Bool

    // OpenAI Proxy fields
    var host: String
    var port: Int
    var allowLAN: Bool
    var upstreamBaseURL: String
    var openAIUpstreamAPI: OpenAIUpstreamAPI
    var upstreamAPIKey: String
    var expectedClientKey: String
    var defaultModel: String
    var modelMapping: ModelMapping
    /// 节点模型目录。可用模型与费用规则是两套独立数据：
    /// - `models` 决定 Code / Desktop / Science 可选择和转发哪些真实模型；
    /// - `pricingOverrides` 只影响费用估算，缺失即“未定价”，不会被误判为免费。
    var modelCatalog: ModelCatalog
    var maxOutputTokens: Int // 0 = no cap, pass through original value
    var enableModelAliasMapping: Bool
    /// Legacy per-node HTTPS contract retained for imported profiles and
    /// standalone compatibility. It is not used to configure Claude Desktop.
    var enableHTTPS: Bool
    var httpsPort: Int?
    var createdAt: Date
    var lastUsedAt: Date?

    enum PricingCurrency: String, Codable, CaseIterable {
        case usd
        case cny
    }

    struct ModelPricing: Codable, Equatable {
        struct Source: Codable, Equatable {
            enum Kind: String, Codable {
                case manual
                case modelsDev
            }

            var kind: Kind
            var label: String
            var referenceURL: String?
            var updatedAt: Date

            static var manual: Source {
                Source(
                    kind: .manual,
                    label: L("Manual", "手动"),
                    referenceURL: nil,
                    updatedAt: Date()
                )
            }
        }

        var inputPerMillion: Double         // per 1M input tokens (in configured currency)
        var outputPerMillion: Double        // per 1M output tokens
        var cacheCreatePerMillion: Double   // per 1M cache write tokens (~1.25× input by default)
        var cacheReadPerMillion: Double     // per 1M cache read tokens (~0.1× input by default)
        var currency: PricingCurrency
        var source: Source?

        static let defaultCacheWriteMultiplier: Double = 1.25
        static let defaultCacheReadMultiplier: Double = 0.1

        static var zero: ModelPricing {
            ModelPricing(inputPerMillion: 0, outputPerMillion: 0, cacheCreatePerMillion: 0, cacheReadPerMillion: 0, currency: .usd)
        }

        /// 仅用于迁移旧配置：旧 UI 会为同步模型自动写入全零价格，
        /// 这种记录应迁移为“未设置”，而不是明确免费。
        var hasAnyRate: Bool {
            inputPerMillion != 0
                || outputPerMillion != 0
                || cacheCreatePerMillion != 0
                || cacheReadPerMillion != 0
        }

        /// CNY → USD 折算用用户配置的全局汇率（AppSettings.cnyPerUSD，默认 7），
        /// 与 OpenCode 定价、费用显示共用同一汇率，保证录入与显示口径一致。
        private static var cnyToUsdRate: Double { 1.0 / AppSettings.cnyPerUSD }

        var inputPerMillionUSD: Double {
            currency == .usd ? inputPerMillion : inputPerMillion * Self.cnyToUsdRate
        }
        var outputPerMillionUSD: Double {
            currency == .usd ? outputPerMillion : outputPerMillion * Self.cnyToUsdRate
        }
        var cacheCreatePerMillionUSD: Double {
            currency == .usd ? cacheCreatePerMillion : cacheCreatePerMillion * Self.cnyToUsdRate
        }
        var cacheReadPerMillionUSD: Double {
            currency == .usd ? cacheReadPerMillion : cacheReadPerMillion * Self.cnyToUsdRate
        }

        /// `input` must be non-cached input. Cached input is charged only through
        /// `cacheRead`; callers should normalize provider usage before pricing.
        func costForTokens(input: Int, output: Int, cacheRead: Int, cacheCreate: Int) -> Double {
            (Double(input) * inputPerMillionUSD
             + Double(output) * outputPerMillionUSD
             + Double(cacheCreate) * cacheCreatePerMillionUSD
             + Double(cacheRead) * cacheReadPerMillionUSD) / 1_000_000
        }

        init(
            inputPerMillion: Double = 0,
            outputPerMillion: Double = 0,
            cacheCreatePerMillion: Double = 0,
            cacheReadPerMillion: Double = 0,
            currency: PricingCurrency = .usd,
            source: Source? = nil
        ) {
            self.inputPerMillion = inputPerMillion
            self.outputPerMillion = outputPerMillion
            self.cacheCreatePerMillion = cacheCreatePerMillion
            self.cacheReadPerMillion = cacheReadPerMillion
            self.currency = currency
            self.source = source
        }

        private enum CodingKeys: String, CodingKey {
            case inputPerMillion
            case outputPerMillion
            case cachePerMillion             // legacy (combined cache)
            case cacheCreatePerMillion
            case cacheReadPerMillion
            case currency
            case source
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            inputPerMillion = try container.decode(Double.self, forKey: .inputPerMillion)
            outputPerMillion = try container.decode(Double.self, forKey: .outputPerMillion)

            let legacy = try container.decodeIfPresent(Double.self, forKey: .cachePerMillion)
            let splitWrite = try container.decodeIfPresent(Double.self, forKey: .cacheCreatePerMillion)
            let splitRead = try container.decodeIfPresent(Double.self, forKey: .cacheReadPerMillion)

            // Prefer split fields; fall back to legacy scalar: treat it as a blended cache price,
            // then synthesize cache-read = legacy and cache-write = legacy × 1.25.
            if splitWrite != nil || splitRead != nil {
                cacheCreatePerMillion = splitWrite ?? ((legacy ?? 0) * Self.defaultCacheWriteMultiplier)
                cacheReadPerMillion = splitRead ?? (legacy ?? 0)
            } else if let legacy, legacy > 0 {
                cacheReadPerMillion = legacy
                cacheCreatePerMillion = legacy * Self.defaultCacheWriteMultiplier
            } else {
                cacheReadPerMillion = 0
                cacheCreatePerMillion = 0
            }

            currency = try container.decodeIfPresent(PricingCurrency.self, forKey: .currency) ?? .usd
            source = try container.decodeIfPresent(Source.self, forKey: .source)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(inputPerMillion, forKey: .inputPerMillion)
            try container.encode(outputPerMillion, forKey: .outputPerMillion)
            try container.encode(cacheCreatePerMillion, forKey: .cacheCreatePerMillion)
            try container.encode(cacheReadPerMillion, forKey: .cacheReadPerMillion)
            try container.encode(cacheReadPerMillion, forKey: .cachePerMillion)
            try container.encode(currency, forKey: .currency)
            try container.encodeIfPresent(source, forKey: .source)
        }
    }

    struct MappedModel: Codable, Equatable {
        var name: String
        var pricing: ModelPricing

        init(name: String, pricing: ModelPricing = .zero) {
            self.name = name
            self.pricing = pricing
        }
    }

    struct ModelCatalog: Codable, Equatable {
        var models: [String]
        var pricingOverrides: [String: ModelPricing]

        private enum CodingKeys: String, CodingKey {
            case models, pricingOverrides
        }

        static var empty: ModelCatalog {
            ModelCatalog(models: [], pricingOverrides: [:])
        }

        init(models: [String] = [], pricingOverrides: [String: ModelPricing] = [:]) {
            var seen = Set<String>()
            var normalizedModels = models
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }

            var normalizedPricing: [String: ModelPricing] = [:]
            for (rawName, pricing) in pricingOverrides {
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                normalizedPricing[name] = pricing
                if seen.insert(name).inserted {
                    normalizedModels.append(name)
                }
            }

            self.models = normalizedModels
            self.pricingOverrides = normalizedPricing
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                models: try container.decodeIfPresent([String].self, forKey: .models) ?? [],
                pricingOverrides: try container.decodeIfPresent(
                    [String: ModelPricing].self,
                    forKey: .pricingOverrides
                ) ?? [:]
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(models, forKey: .models)
            try container.encode(pricingOverrides, forKey: .pricingOverrides)
        }

        init(mappedModels: [MappedModel]) {
            var pricing: [String: ModelPricing] = [:]
            for model in mappedModels {
                let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, model.pricing.hasAnyRate else { continue }
                pricing[name] = model.pricing
            }
            self.init(models: mappedModels.map(\.name), pricingOverrides: pricing)
        }

        static func migrated(
            legacyLibrary: [MappedModel],
            legacyMapping: LegacyModelMapping,
            defaultModel: String
        ) -> ModelCatalog {
            var prices: [String: ModelPricing] = [:]
            for entry in legacyLibrary where entry.pricing.hasAnyRate {
                let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { prices[name] = entry.pricing }
            }
            for route in legacyMapping.routes {
                let name = route.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, prices[name] == nil else { continue }
                if let pricing = route.pricing, pricing.hasAnyRate {
                    prices[name] = pricing
                }
            }
            return ModelCatalog(
                models: legacyLibrary.map(\.name) + legacyMapping.routes.map(\.name) + [defaultModel],
                pricingOverrides: prices
            )
        }

        mutating func mergeModels(_ names: [String]) {
            self = ModelCatalog(models: models + names, pricingOverrides: pricingOverrides)
        }
    }

    /// 应用模型槽位只负责“别名 → 真实模型名”，不再携带价格副本。
    struct ModelRoute: Codable, Equatable {
        var name: String

        init(name: String) {
            self.name = name
        }
    }

    struct ModelMapping: Codable, Equatable {
        var bigModel: ModelRoute      // opus -> this
        var middleModel: ModelRoute   // sonnet -> this
        var smallModel: ModelRoute    // haiku -> this

        static var openAIDefault: ModelMapping {
            ModelMapping(
                bigModel: ModelRoute(name: "gpt-5.5"),
                middleModel: ModelRoute(name: "gpt-5.4-mini"),
                smallModel: ModelRoute(name: "gpt-4o-mini")
            )
        }

        static var anthropicDefault: ModelMapping {
            ModelMapping(
                bigModel: ModelRoute(name: "claude-opus-4-6"),
                middleModel: ModelRoute(name: "claude-sonnet-4-6"),
                smallModel: ModelRoute(name: "claude-haiku-4-5")
            )
        }

        /// Codex 节点只有一个有效模型（存 bigModel），middle/small 留空不参与定价/统计。
        static var codexDefault: ModelMapping {
            ModelMapping(
                bigModel: ModelRoute(name: "gpt-5.5"),
                middleModel: ModelRoute(name: ""),
                smallModel: ModelRoute(name: "")
            )
        }

        static var `default`: ModelMapping { openAIDefault }
    }

    /// 仅用于读取 0.15.x 及更早的槽位价格；新配置不会再写入这些价格副本。
    struct LegacyModelRoute: Codable {
        var name: String
        var pricing: ModelPricing?
    }

    struct LegacyModelMapping: Codable {
        var bigModel: LegacyModelRoute
        var middleModel: LegacyModelRoute
        var smallModel: LegacyModelRoute

        init(current: ModelMapping) {
            bigModel = LegacyModelRoute(name: current.bigModel.name, pricing: nil)
            middleModel = LegacyModelRoute(name: current.middleModel.name, pricing: nil)
            smallModel = LegacyModelRoute(name: current.smallModel.name, pricing: nil)
        }

        var current: ModelMapping {
            ModelMapping(
                bigModel: ModelRoute(name: bigModel.name),
                middleModel: ModelRoute(name: middleModel.name),
                smallModel: ModelRoute(name: smallModel.name)
            )
        }

        var routes: [LegacyModelRoute] {
            [bigModel, middleModel, smallModel].filter {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        nodeType: NodeType = .openaiProxy,
        isEnabled: Bool = false,
        anthropicBaseURL: String = "https://api.anthropic.com",
        anthropicAPIKey: String = "",
        usePassthroughProxy: Bool = true,
        host: String = "127.0.0.1",
        port: Int = 8080,
        allowLAN: Bool = false,
        upstreamBaseURL: String = "https://api.openai.com",
        openAIUpstreamAPI: OpenAIUpstreamAPI = .chatCompletions,
        upstreamAPIKey: String = "",
        expectedClientKey: String = "",
        defaultModel: String = "",
        modelMapping: ModelMapping = .default,
        modelCatalog: ModelCatalog = .empty,
        maxOutputTokens: Int = 0,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        enableModelAliasMapping: Bool = false,
        enableHTTPS: Bool = false,
        httpsPort: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.nodeType = nodeType
        self.isEnabled = isEnabled
        self.anthropicBaseURL = anthropicBaseURL
        self.anthropicAPIKey = anthropicAPIKey
        // 0.16+: every Claude node owns one local runtime endpoint. Keep the
        // persisted legacy field for backward compatibility, but normalize
        // Anthropic nodes to the uniform runtime contract.
        self.usePassthroughProxy = nodeType == .anthropicDirect ? true : usePassthroughProxy
        self.host = host
        self.port = port
        self.allowLAN = allowLAN
        self.upstreamBaseURL = ClaudeProxyConfiguration.normalizeOpenAIBaseURL(upstreamBaseURL)
        self.openAIUpstreamAPI = openAIUpstreamAPI
        self.upstreamAPIKey = upstreamAPIKey
        self.expectedClientKey = expectedClientKey
        self.defaultModel = defaultModel
        self.modelMapping = modelMapping
        self.modelCatalog = modelCatalog
        self.maxOutputTokens = maxOutputTokens
        self.enableModelAliasMapping = enableModelAliasMapping
        self.enableHTTPS = enableHTTPS
        self.httpsPort = httpsPort
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, nodeType, isEnabled
        case anthropicBaseURL, anthropicAPIKey, usePassthroughProxy
        case host, port, allowLAN
        case upstreamBaseURL, openAIUpstreamAPI, upstreamAPIKey, expectedClientKey
        case defaultModel, modelMapping, modelCatalog
        case modelLibrary // 0.15.x 及更早，仅解码迁移
        case maxOutputTokens, enableModelAliasMapping, enableHTTPS, httpsPort
        case createdAt, lastUsedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        nodeType = try container.decodeIfPresent(NodeType.self, forKey: .nodeType) ?? .openaiProxy
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        anthropicBaseURL = try container.decodeIfPresent(String.self, forKey: .anthropicBaseURL) ?? "https://api.anthropic.com"
        anthropicAPIKey = try container.decodeIfPresent(String.self, forKey: .anthropicAPIKey) ?? ""
        usePassthroughProxy = nodeType == .anthropicDirect
            ? true
            : (try container.decodeIfPresent(Bool.self, forKey: .usePassthroughProxy) ?? false)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 8080
        allowLAN = try container.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? false
        upstreamBaseURL = ClaudeProxyConfiguration.normalizeOpenAIBaseURL(
            try container.decodeIfPresent(String.self, forKey: .upstreamBaseURL) ?? "https://api.openai.com"
        )
        openAIUpstreamAPI = try container.decodeIfPresent(OpenAIUpstreamAPI.self, forKey: .openAIUpstreamAPI) ?? .chatCompletions
        upstreamAPIKey = try container.decodeIfPresent(String.self, forKey: .upstreamAPIKey) ?? ""
        expectedClientKey = try container.decodeIfPresent(String.self, forKey: .expectedClientKey) ?? ""
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel) ?? ""
        let defaultMapping: ModelMapping = nodeType.isCodex ? .codexDefault
            : (nodeType == .anthropicDirect ? .anthropicDefault : .openAIDefault)
        let legacyMapping = try container.decodeIfPresent(LegacyModelMapping.self, forKey: .modelMapping)
            ?? LegacyModelMapping(current: defaultMapping)
        modelMapping = legacyMapping.current
        if let currentCatalog = try container.decodeIfPresent(ModelCatalog.self, forKey: .modelCatalog) {
            modelCatalog = ModelCatalog(
                models: currentCatalog.models,
                pricingOverrides: currentCatalog.pricingOverrides
            )
        } else {
            let legacyLibrary = try container.decodeIfPresent([MappedModel].self, forKey: .modelLibrary) ?? []
            modelCatalog = .migrated(
                legacyLibrary: legacyLibrary,
                legacyMapping: legacyMapping,
                defaultModel: defaultModel
            )
        }
        maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? 0
        enableModelAliasMapping = try container.decodeIfPresent(Bool.self, forKey: .enableModelAliasMapping) ?? false
        enableHTTPS = try container.decodeIfPresent(Bool.self, forKey: .enableHTTPS) ?? false
        httpsPort = try container.decodeIfPresent(Int.self, forKey: .httpsPort)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(nodeType, forKey: .nodeType)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(anthropicBaseURL, forKey: .anthropicBaseURL)
        try container.encode(anthropicAPIKey, forKey: .anthropicAPIKey)
        try container.encode(usePassthroughProxy, forKey: .usePassthroughProxy)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(allowLAN, forKey: .allowLAN)
        try container.encode(upstreamBaseURL, forKey: .upstreamBaseURL)
        try container.encode(openAIUpstreamAPI, forKey: .openAIUpstreamAPI)
        try container.encode(upstreamAPIKey, forKey: .upstreamAPIKey)
        try container.encode(expectedClientKey, forKey: .expectedClientKey)
        try container.encode(defaultModel, forKey: .defaultModel)
        try container.encode(modelMapping, forKey: .modelMapping)
        try container.encode(modelCatalog, forKey: .modelCatalog)
        try container.encode(maxOutputTokens, forKey: .maxOutputTokens)
        try container.encode(enableModelAliasMapping, forKey: .enableModelAliasMapping)
        try container.encode(enableHTTPS, forKey: .enableHTTPS)
        try container.encodeIfPresent(httpsPort, forKey: .httpsPort)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
    }

    var bindAddress: String {
        allowLAN ? "0.0.0.0" : host
    }

    var displayURL: String {
        "http://\(host):\(port)"
    }

    var effectiveHTTPSPort: Int { httpsPort ?? (port + 1) }

    /// 该节点代理进程实际监听的端口集合（用于跨轨端口仲裁）：HTTP 入站端口恒占用；
    /// 开启 HTTPS 时进程会额外监听 HTTPS 端口（QuotaServer 同时起 HTTP + HTTPS 两个 listener）。
    /// Every node owns its configured port, including Anthropic-compatible
    /// upstreams. This is the core invariant used by all product gateways.
    var listeningPorts: [Int] {
        var ports = [port]
        if enableHTTPS { ports.append(effectiveHTTPSPort) }
        return ports
    }

    var needsProxyProcess: Bool {
        true
    }

    /// Exact upstream model IDs accepted by the node runtime. Product
    /// gateways resolve aliases before forwarding; this catalog prevents the
    /// node from applying a second tier mapping.
    var runtimeModelCatalog: [String] {
        var seen = Set<String>()
        return (modelCatalog.models + [
            defaultModel,
            modelMapping.bigModel.name,
            modelMapping.middleModel.name,
            modelMapping.smallModel.name,
        ])
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Codex 节点：单一模型 + 价格存放在 `modelMapping.bigModel`。
    /// 该模型同时作为写入 `config.toml` 的 `model`、上游模型名与定价键。
    var codexModel: String {
        modelMapping.bigModel.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 客户端向本地代理鉴权用的 key；留空时回退到约定的 "proxy-key"。
    var effectiveClientKey: String {
        expectedClientKey.isEmpty ? "proxy-key" : expectedClientKey
    }

    /// 费用规则只做真实模型名精确匹配。没有规则即“未定价”；
    /// 不再从应用槽位或模型家族猜价，避免模型同步后被误记为免费。
    func pricingForModel(_ model: String) -> ModelPricing? {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return modelCatalog.pricingOverrides[name]
    }

    var normalizedUpstreamBaseURL: String {
        ClaudeProxyConfiguration.normalizeOpenAIBaseURL(upstreamBaseURL)
    }

    func normalizedForPersistence() -> ProxyConfiguration {
        var copy = self
        copy.upstreamBaseURL = normalizedUpstreamBaseURL
        return copy
    }

}

// MARK: - Proxy Statistics

struct ProxyStatistics: Codable, Equatable {
    var totalRequests: Int
    var successfulRequests: Int
    var failedRequests: Int
    var totalTokensInput: Int
    var totalTokensOutput: Int
    var totalTokensCacheRead: Int
    var totalTokensCacheCreation: Int
    var estimatedCostUSD: Double
    var requestsByModel: [String: Int]
    var lastRequestAt: Date?
    /// 整段响应平均总耗时（ms），受输出长度影响。
    var averageResponseTime: Double
    /// 平均首字时间 TTFT（ms），仅基于带 firstTokenMs 的流式请求。
    var averageFirstTokenTime: Double
    /// 参与 TTFT 平均的样本数（非流式 / 旧日志不计入）。
    var firstTokenSamples: Int

    static var empty: ProxyStatistics {
        ProxyStatistics(
            totalRequests: 0,
            successfulRequests: 0,
            failedRequests: 0,
            totalTokensInput: 0,
            totalTokensOutput: 0,
            totalTokensCacheRead: 0,
            totalTokensCacheCreation: 0,
            estimatedCostUSD: 0,
            requestsByModel: [:],
            lastRequestAt: nil,
            averageResponseTime: 0,
            averageFirstTokenTime: 0,
            firstTokenSamples: 0
        )
    }

    var successRate: Double {
        guard totalRequests > 0 else { return 0 }
        return Double(successfulRequests) / Double(totalRequests) * 100
    }

    var totalTokensCache: Int { totalTokensCacheRead + totalTokensCacheCreation }

    var totalTokens: Int {
        totalTokensInput + totalTokensOutput + totalTokensCache
    }

    /// Cache hit rate: cache_read / (input + cache_read + cache_creation).
    /// Measures how much of the billable input surface is served from cache.
    var cacheHitRate: Double {
        let denom = totalTokensInput + totalTokensCacheRead + totalTokensCacheCreation
        guard denom > 0 else { return 0 }
        return Double(totalTokensCacheRead) / Double(denom) * 100
    }

    private enum CodingKeys: String, CodingKey {
        case totalRequests
        case successfulRequests
        case failedRequests
        case totalTokensInput
        case totalTokensOutput
        case totalTokensCache             // legacy combined cache
        case totalTokensCacheRead
        case totalTokensCacheCreation
        case estimatedCostUSD
        case requestsByModel
        case lastRequestAt
        case averageResponseTime
        case averageFirstTokenTime
        case firstTokenSamples
    }

    init(
        totalRequests: Int,
        successfulRequests: Int,
        failedRequests: Int,
        totalTokensInput: Int,
        totalTokensOutput: Int,
        totalTokensCacheRead: Int,
        totalTokensCacheCreation: Int,
        estimatedCostUSD: Double,
        requestsByModel: [String: Int],
        lastRequestAt: Date?,
        averageResponseTime: Double,
        averageFirstTokenTime: Double = 0,
        firstTokenSamples: Int = 0
    ) {
        self.totalRequests = totalRequests
        self.successfulRequests = successfulRequests
        self.failedRequests = failedRequests
        self.totalTokensInput = totalTokensInput
        self.totalTokensOutput = totalTokensOutput
        self.totalTokensCacheRead = totalTokensCacheRead
        self.totalTokensCacheCreation = totalTokensCacheCreation
        self.estimatedCostUSD = estimatedCostUSD
        self.requestsByModel = requestsByModel
        self.lastRequestAt = lastRequestAt
        self.averageResponseTime = averageResponseTime
        self.averageFirstTokenTime = averageFirstTokenTime
        self.firstTokenSamples = firstTokenSamples
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalRequests = try c.decode(Int.self, forKey: .totalRequests)
        successfulRequests = try c.decode(Int.self, forKey: .successfulRequests)
        failedRequests = try c.decode(Int.self, forKey: .failedRequests)
        totalTokensInput = try c.decode(Int.self, forKey: .totalTokensInput)
        totalTokensOutput = try c.decode(Int.self, forKey: .totalTokensOutput)

        let legacyCache = try c.decodeIfPresent(Int.self, forKey: .totalTokensCache)
        let splitRead = try c.decodeIfPresent(Int.self, forKey: .totalTokensCacheRead)
        let splitCreate = try c.decodeIfPresent(Int.self, forKey: .totalTokensCacheCreation)

        if splitRead != nil || splitCreate != nil {
            totalTokensCacheRead = splitRead ?? 0
            totalTokensCacheCreation = splitCreate ?? 0
        } else {
            // Legacy migration: attribute the old combined total to cache-read (no way to split historical data).
            totalTokensCacheRead = legacyCache ?? 0
            totalTokensCacheCreation = 0
        }

        estimatedCostUSD = try c.decode(Double.self, forKey: .estimatedCostUSD)
        requestsByModel = try c.decode([String: Int].self, forKey: .requestsByModel)
        lastRequestAt = try c.decodeIfPresent(Date.self, forKey: .lastRequestAt)
        averageResponseTime = try c.decode(Double.self, forKey: .averageResponseTime)
        averageFirstTokenTime = try c.decodeIfPresent(Double.self, forKey: .averageFirstTokenTime) ?? 0
        firstTokenSamples = try c.decodeIfPresent(Int.self, forKey: .firstTokenSamples) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(totalRequests, forKey: .totalRequests)
        try c.encode(successfulRequests, forKey: .successfulRequests)
        try c.encode(failedRequests, forKey: .failedRequests)
        try c.encode(totalTokensInput, forKey: .totalTokensInput)
        try c.encode(totalTokensOutput, forKey: .totalTokensOutput)
        try c.encode(totalTokensCacheRead, forKey: .totalTokensCacheRead)
        try c.encode(totalTokensCacheCreation, forKey: .totalTokensCacheCreation)
        try c.encode(totalTokensCacheRead + totalTokensCacheCreation, forKey: .totalTokensCache)
        try c.encode(estimatedCostUSD, forKey: .estimatedCostUSD)
        try c.encode(requestsByModel, forKey: .requestsByModel)
        try c.encodeIfPresent(lastRequestAt, forKey: .lastRequestAt)
        try c.encode(averageResponseTime, forKey: .averageResponseTime)
        try c.encode(averageFirstTokenTime, forKey: .averageFirstTokenTime)
        try c.encode(firstTokenSamples, forKey: .firstTokenSamples)
    }
}

// MARK: - Proxy Request Log

struct ProxyRequestLog: Codable, Identifiable {
    let id: String
    let configId: String
    let timestamp: Date
    let method: String
    let path: String
    let claudeModel: String
    let upstreamModel: String
    let success: Bool
    /// 整段响应总耗时（请求开始到流式结束）。衡量「这次答了多长」，受输出长度影响。
    let responseTimeMs: Double
    /// 首字时间 TTFT（请求开始到收到第一个上游响应分片）。衡量「响应快不快」。
    /// 仅流式代理路径可采，非流式 / 旧日志为 nil。
    let firstTokenMs: Double?
    let tokensInput: Int
    let tokensOutput: Int
    let tokensCacheRead: Int
    let tokensCacheCreation: Int
    let estimatedCostUSD: Double
    let pricingResolved: Bool
    let errorMessage: String?
    let errorType: String?
    let statusCode: Int?
    /// 发起请求的 Claude 产品面。后端根据专用 header / 监听入口识别，旧日志为 nil。
    /// 原始值与 QuotaBackend.ClaudeClientSurface 保持一致：
    /// `claude_code` / `claude_desktop` / `claude_science` / `unknown`。
    let clientSurface: String?
    /// 是否来自「全局统一代理」（一个常驻进程随激活节点轮转）。OpenCode 轨用它区分两类日志：
    /// 全局代理日志是该节点用量/成功率/最近请求的唯一来源（opencode.db 不记全局流量）；
    /// 而每节点「仅代理 / 路线 B」日志仅作观测（成功明细以 opencode.db 为准），故展示口径不同。
    /// 旧档案缺该键时解码为 false（向后兼容）。
    let isGlobalProxy: Bool

    /// Combined cache total (read + creation). Retained for display and aggregation convenience.
    var tokensCache: Int { tokensCacheRead + tokensCacheCreation }

    init(
        id: String = UUID().uuidString,
        configId: String,
        timestamp: Date = Date(),
        method: String,
        path: String,
        claudeModel: String,
        upstreamModel: String,
        success: Bool,
        responseTimeMs: Double,
        firstTokenMs: Double? = nil,
        tokensInput: Int = 0,
        tokensOutput: Int = 0,
        tokensCacheRead: Int = 0,
        tokensCacheCreation: Int = 0,
        estimatedCostUSD: Double = 0,
        pricingResolved: Bool = false,
        errorMessage: String? = nil,
        errorType: String? = nil,
        statusCode: Int? = nil,
        clientSurface: String? = nil,
        isGlobalProxy: Bool = false
    ) {
        self.id = id
        self.configId = configId
        self.timestamp = timestamp
        self.method = method
        self.path = path
        self.claudeModel = claudeModel
        self.upstreamModel = upstreamModel
        self.success = success
        self.responseTimeMs = responseTimeMs
        self.firstTokenMs = firstTokenMs
        self.tokensInput = tokensInput
        self.tokensOutput = tokensOutput
        self.tokensCacheRead = tokensCacheRead
        self.tokensCacheCreation = tokensCacheCreation
        self.estimatedCostUSD = estimatedCostUSD
        self.pricingResolved = pricingResolved
        self.errorMessage = errorMessage
        self.errorType = errorType
        self.statusCode = statusCode
        self.clientSurface = clientSurface
        self.isGlobalProxy = isGlobalProxy
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case configId
        case timestamp
        case method
        case path
        case claudeModel
        case upstreamModel
        case success
        case responseTimeMs
        case firstTokenMs
        case tokensInput
        case tokensOutput
        case tokensCache              // legacy combined cache
        case tokensCacheRead
        case tokensCacheCreation
        case estimatedCostUSD
        case pricingResolved
        case errorMessage
        case errorType
        case statusCode
        case clientSurface
        case isGlobalProxy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        configId = try c.decode(String.self, forKey: .configId)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        method = try c.decode(String.self, forKey: .method)
        path = try c.decode(String.self, forKey: .path)
        claudeModel = try c.decode(String.self, forKey: .claudeModel)
        upstreamModel = try c.decode(String.self, forKey: .upstreamModel)
        success = try c.decode(Bool.self, forKey: .success)
        responseTimeMs = try c.decode(Double.self, forKey: .responseTimeMs)
        firstTokenMs = try c.decodeIfPresent(Double.self, forKey: .firstTokenMs)
        tokensInput = try c.decode(Int.self, forKey: .tokensInput)
        tokensOutput = try c.decode(Int.self, forKey: .tokensOutput)

        let legacyCache = try c.decodeIfPresent(Int.self, forKey: .tokensCache)
        let splitRead = try c.decodeIfPresent(Int.self, forKey: .tokensCacheRead)
        let splitCreate = try c.decodeIfPresent(Int.self, forKey: .tokensCacheCreation)
        if splitRead != nil || splitCreate != nil {
            tokensCacheRead = splitRead ?? 0
            tokensCacheCreation = splitCreate ?? 0
        } else {
            tokensCacheRead = legacyCache ?? 0
            tokensCacheCreation = 0
        }

        estimatedCostUSD = try c.decode(Double.self, forKey: .estimatedCostUSD)
        pricingResolved = try c.decodeIfPresent(Bool.self, forKey: .pricingResolved) ?? (estimatedCostUSD > 0)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        errorType = try c.decodeIfPresent(String.self, forKey: .errorType)
        statusCode = try c.decodeIfPresent(Int.self, forKey: .statusCode)
        clientSurface = try c.decodeIfPresent(String.self, forKey: .clientSurface)
        isGlobalProxy = try c.decodeIfPresent(Bool.self, forKey: .isGlobalProxy) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(configId, forKey: .configId)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(method, forKey: .method)
        try c.encode(path, forKey: .path)
        try c.encode(claudeModel, forKey: .claudeModel)
        try c.encode(upstreamModel, forKey: .upstreamModel)
        try c.encode(success, forKey: .success)
        try c.encode(responseTimeMs, forKey: .responseTimeMs)
        try c.encodeIfPresent(firstTokenMs, forKey: .firstTokenMs)
        try c.encode(tokensInput, forKey: .tokensInput)
        try c.encode(tokensOutput, forKey: .tokensOutput)
        try c.encode(tokensCacheRead, forKey: .tokensCacheRead)
        try c.encode(tokensCacheCreation, forKey: .tokensCacheCreation)
        try c.encode(tokensCacheRead + tokensCacheCreation, forKey: .tokensCache)
        try c.encode(estimatedCostUSD, forKey: .estimatedCostUSD)
        try c.encode(pricingResolved, forKey: .pricingResolved)
        try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try c.encodeIfPresent(errorType, forKey: .errorType)
        try c.encodeIfPresent(statusCode, forKey: .statusCode)
        try c.encodeIfPresent(clientSurface, forKey: .clientSurface)
        if isGlobalProxy { try c.encode(isGlobalProxy, forKey: .isGlobalProxy) }
    }
}
