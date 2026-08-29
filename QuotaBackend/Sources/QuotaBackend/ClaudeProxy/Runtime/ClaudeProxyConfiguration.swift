import Foundation

// MARK: - Proxy Configuration for QuotaBackend

public enum ProxyMode: String, Sendable {
    case openaiConvert
    case anthropicPassthrough
}

/// Claude family clients sharing the same inference gateway.  The value is
/// emitted in privacy-safe request logs and is never accepted from a client
/// supplied header.
public enum ClaudeClientSurface: String, Sendable, Codable, Equatable {
    case code = "claude_code"
    case desktop = "claude_desktop"
    case science = "claude_science"
    case unknown
}

public enum OpenAIUpstreamAPI: String, Sendable, Codable, CaseIterable {
    case chatCompletions = "chat_completions"
    case responses

    public static func fromEnvironment(_ value: String?) -> OpenAIUpstreamAPI {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "responses", "response":
            return .responses
        default:
            return .chatCompletions
        }
    }
}

public struct ClaudeProxyConfiguration: Sendable {
    public let enabled: Bool
    /// TCP port this proxy configuration is intended to bind on (1–65535).
    public let bindPort: Int
    public let mode: ProxyMode
    public let upstreamBaseURL: String
    public let openAIUpstreamAPI: OpenAIUpstreamAPI
    public let upstreamAPIKey: String
    public let expectedClientKey: String?
    /// Claude Desktop owns a separate local credential even though it shares
    /// the same upstream/runtime with Claude Code.
    public let expectedDesktopClientKey: String?
    public let bigModel: String
    public let middleModel: String
    public let smallModel: String
    public let maxOutputTokens: Int?
    public let enableModelAliasMapping: Bool
    /// Active node model ids made available to Claude Science. Empty for normal
    /// Claude Code proxy processes, so `/v1/models` remains unexposed there.
    public let availableModels: [String]
    public let defaultModel: String?
    public let exposeScienceModelCatalog: Bool
    /// Science may retain a raw model id in browser storage. When enabled, an
    /// exact active-catalog id wins over the legacy opus/sonnet/haiku mapping.
    public let preferExactCatalogModels: Bool
    /// The catalog transport is shared, but Science and Desktop intentionally
    /// use different public model identities. Desktop requires role-shaped
    /// Anthropic routes while Science keeps its compatibility selection IDs.
    public let catalogRouteStyle: ScienceModelProtocolAdapter.RouteStyle
    /// Product hot-switch modes interpret the four stable public route IDs as
    /// app-side aliases. Full-catalog mode must route an identically named real
    /// upstream model exactly instead of guessing from the string.
    public let mapDesktopTierRoutes: Bool
    /// Real upstream model IDs explicitly advertised with a 1M-context picker
    /// variant. The route adapter projects this onto the public catalog rows.
    public let catalogSupports1M: Set<String>
    private let scienceModelProtocol: ScienceModelProtocolAdapter
    /// 全局统一代理（OpenCode anthropic 接口）模式下，把入站请求体的 `model` 无条件改写为该真实上游模型名，
    /// 优先于三层别名映射。nil = 不强制（普通 Claude Code 轨）。
    public let forcedModel: String?
    public let requestTimeout: TimeInterval
    public let customHeaders: [String: String]

    public init(
        enabled: Bool,
        bindPort: Int = 4318,
        mode: ProxyMode = .openaiConvert,
        upstreamBaseURL: String,
        openAIUpstreamAPI: OpenAIUpstreamAPI = .chatCompletions,
        upstreamAPIKey: String,
        expectedClientKey: String? = nil,
        expectedDesktopClientKey: String? = nil,
        bigModel: String = "gpt-4o",
        middleModel: String = "gpt-4o-mini",
        smallModel: String = "gpt-3.5-turbo",
        maxOutputTokens: Int? = nil,
        enableModelAliasMapping: Bool = false,
        availableModels: [String] = [],
        defaultModel: String? = nil,
        exposeScienceModelCatalog: Bool = false,
        preferExactCatalogModels: Bool = false,
        catalogRouteStyle: ScienceModelProtocolAdapter.RouteStyle = .science,
        mapDesktopTierRoutes: Bool = false,
        catalogSupports1M: Set<String> = [],
        forcedModel: String? = nil,
        requestTimeout: TimeInterval = 60,
        customHeaders: [String: String] = [:]
    ) {
        self.enabled = enabled
        self.bindPort = bindPort
        self.mode = mode
        self.upstreamBaseURL = mode == .openaiConvert
            ? Self.normalizeOpenAIBaseURL(upstreamBaseURL)
            : upstreamBaseURL
        self.openAIUpstreamAPI = openAIUpstreamAPI
        self.upstreamAPIKey = upstreamAPIKey
        self.expectedClientKey = Self.nonBlank(expectedClientKey)
        self.expectedDesktopClientKey = Self.nonBlank(expectedDesktopClientKey)
        self.bigModel = bigModel
        self.middleModel = middleModel
        self.smallModel = smallModel
        self.maxOutputTokens = maxOutputTokens
        self.enableModelAliasMapping = enableModelAliasMapping
        let scienceModelProtocol = ScienceModelProtocolAdapter(
            upstreamModels: availableModels,
            requestedDefault: defaultModel,
            routeStyle: catalogRouteStyle,
            supports1MUpstreamModels: catalogSupports1M
        )
        self.scienceModelProtocol = scienceModelProtocol
        self.availableModels = scienceModelProtocol.models.map(\.upstreamModel)
        let trimmedDefault = defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.defaultModel = (trimmedDefault?.isEmpty == false) ? trimmedDefault : nil
        self.exposeScienceModelCatalog = exposeScienceModelCatalog && !self.availableModels.isEmpty
        self.preferExactCatalogModels = preferExactCatalogModels
        self.catalogRouteStyle = catalogRouteStyle
        self.mapDesktopTierRoutes = mapDesktopTierRoutes
        self.catalogSupports1M = catalogSupports1M
        let trimmedForced = forcedModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.forcedModel = (trimmedForced?.isEmpty == false) ? trimmedForced : nil
        self.requestTimeout = requestTimeout
        self.customHeaders = customHeaders
    }

    /// Reduces a Claude-style model id to a coarse family label (`haiku`, `sonnet`, `opus`) when detectable.
    public static func normalizeModelName(_ model: String) -> String {
        let lower = model.lowercased()
        if lower.contains("haiku") {
            return "haiku"
        } else if lower.contains("sonnet") {
            return "sonnet"
        } else if lower.contains("opus") {
            return "opus"
        }
        return model
    }

    public func mapToUpstreamModel(_ requestModel: String) -> String {
        if exposeScienceModelCatalog,
           let resolved = scienceModelProtocol.resolveRequestModel(
               requestModel,
               acceptingRawUpstreamIDs: preferExactCatalogModels
           ) {
            // Code/Desktop publish stable Default/Opus/Sonnet/Haiku identities.
            // The route itself must pass through the current node's tier map;
            // returning it as a literal upstream model would couple Desktop to
            // one node and defeat Gateway hot switching.
            if mapDesktopTierRoutes,
               ScienceModelProtocolAdapter.isStableProductTierRoute(resolved) {
                return mapTierRouteToUpstream(resolved)
            }
            return resolved
        }
        if preferExactCatalogModels, availableModels.contains(requestModel) {
            if mapDesktopTierRoutes,
               ScienceModelProtocolAdapter.isStableProductTierRoute(requestModel) {
                return mapTierRouteToUpstream(requestModel)
            }
            return requestModel
        }
        // The literal id lost, so a trailing `[1m]` is this proxy's own
        // long-context marker rather than part of an upstream name. Route on the
        // base id; the 1M request itself travels as an `anthropic-beta` value.
        let base = ClaudeContext1M.baseModel(requestModel)
        if base != requestModel,
           preferExactCatalogModels,
           availableModels.contains(base) {
            if mapDesktopTierRoutes,
               ScienceModelProtocolAdapter.isStableProductTierRoute(base) {
                return mapTierRouteToUpstream(base)
            }
            return base
        }
        return mapTierRouteToUpstream(base)
    }

    private func mapTierRouteToUpstream(_ requestModel: String) -> String {
        let normalized = requestModel.lowercased()
        if mapDesktopTierRoutes, let tier = ScienceModelProtocolAdapter.productTier(for: normalized) {
            switch tier {
            case .defaultRoute:
                return defaultModel ?? middleModel
            case .opus:
                return bigModel
            case .sonnet:
                return middleModel
            case .haiku:
                return smallModel
            }
        }
        if normalized.contains("opus") {
            return bigModel
        } else if normalized.contains("sonnet") {
            return middleModel
        } else if normalized.contains("haiku") {
            return smallModel
        } else if normalized.contains("fable") {
            return defaultModel ?? middleModel
        } else if normalized.contains("claude") {
            return middleModel
        }
        return requestModel
    }

    public var effectiveCatalogDefault: String {
        scienceModelProtocol.defaultUpstreamModel ?? middleModel
    }

    public var scienceCatalogModels: [ScienceModelProtocolAdapter.Model] {
        scienceModelProtocol.models
    }

    public var scienceDefaultModelID: String? {
        scienceModelProtocol.defaultModelID
    }

    public static func normalizeOpenAIBaseURL(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if var components = URLComponents(string: trimmed) {
            var segments = components.path.split(separator: "/").map(String.init)
            let normalizedSegments = segments.map { $0.lowercased() }

            if normalizedSegments.suffix(3) == ["v1", "chat", "completions"] {
                segments.removeLast(3)
            } else if normalizedSegments.suffix(2) == ["v1", "responses"] {
                segments.removeLast(2)
            } else if normalizedSegments.suffix(2) == ["v1", "models"] {
                segments.removeLast(2)
            } else if normalizedSegments.last == "v1" {
                segments.removeLast()
            }

            components.path = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
            return components.string ?? trimmed
        }

        let legacySuffixes = [
            "/v1/chat/completions",
            "/v1/responses",
            "/v1/models",
            "/v1/",
            "/v1"
        ]

        for suffix in legacySuffixes where trimmed.lowercased().hasSuffix(suffix.lowercased()) {
            return String(trimmed.dropLast(suffix.count))
        }

        return trimmed
    }

    public func validate() throws {
        if upstreamAPIKey.isEmpty {
            throw ConfigurationError.missingAPIKey
        }
        if upstreamBaseURL.isEmpty {
            throw ConfigurationError.invalidURL
        }
        guard (1...65_535).contains(bindPort) else {
            throw ConfigurationError.invalidPort
        }
    }

    public var expectedClientAPIKey: String? {
        return expectedClientKey
    }

    /// Resolve authentication and surface without trusting client metadata.
    /// A prefixed Desktop route is intentionally strict: a Claude Code key is
    /// not interchangeable with the Desktop profile key.
    public func authenticatedSurface(
        headers: [String: String],
        hintedSurface: ClaudeClientSurface = .unknown
    ) -> ClaudeClientSurface? {
        let supplied = [
            headers["x-api-key"],
            Self.bearerToken(from: headers["authorization"]),
        ].compactMap { $0 }

        if hintedSurface == .desktop {
            guard let expectedDesktopClientKey else { return nil }
            return supplied.contains(expectedDesktopClientKey) ? .desktop : nil
        }

        if let expectedDesktopClientKey, supplied.contains(expectedDesktopClientKey) {
            return .desktop
        }
        if let expectedClientKey, supplied.contains(expectedClientKey) {
            return .code
        }
        if expectedClientKey == nil, expectedDesktopClientKey == nil {
            return .science
        }
        return nil
    }

    private static func bearerToken(from authorization: String?) -> String? {
        guard let authorization else { return nil }
        let parts = authorization.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2,
              String(parts[0]).caseInsensitiveCompare("Bearer") == .orderedSame else { return nil }
        return String(parts[1])
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func loadFromEnvironment() -> ClaudeProxyConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        let catalogModelsJSON = environment["AIUSAGE_CLAUDE_MODELS_JSON"]
            ?? environment["AIUSAGE_SCIENCE_MODELS_JSON"]
        let catalogModels: [String] = catalogModelsJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) }
            ?? []
        let catalogDefault = environment["AIUSAGE_CLAUDE_DEFAULT_MODEL"]
            ?? environment["AIUSAGE_SCIENCE_DEFAULT_MODEL"]
        let exposeCatalog = environment["AIUSAGE_CLAUDE_MODEL_CATALOG"] == "1"
            || environment["AIUSAGE_SCIENCE_MODEL_CATALOG"] == "1"
        let preferExactCatalog = environment["AIUSAGE_CLAUDE_EXACT_MODELS"] == "1"
            || environment["AIUSAGE_SCIENCE_EXACT_MODELS"] == "1"
        let catalogRouteStyle = ScienceModelProtocolAdapter.RouteStyle(
            rawValue: environment["AIUSAGE_CLAUDE_ROUTE_STYLE"] ?? "science"
        ) ?? .science
        let mapDesktopTierRoutes = environment["AIUSAGE_CLAUDE_DESKTOP_TIER_ROUTES"] == "1"
        let catalogSupports1M: Set<String> = Set(
            environment["AIUSAGE_CLAUDE_SUPPORTS_1M_JSON"]
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) }
                ?? []
        )
        let desktopClientKey = environment["ANTHROPIC_DESKTOP_API_KEY"]
        let proxyModeStr = ProcessInfo.processInfo.environment["PROXY_MODE"] ?? "openai"
        let proxyMode: ProxyMode = proxyModeStr == "passthrough" ? .anthropicPassthrough : .openaiConvert

        if proxyMode == .anthropicPassthrough {
            let baseURL = ProcessInfo.processInfo.environment["ANTHROPIC_UPSTREAM_URL"] ?? "https://api.anthropic.com"
            let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_UPSTREAM_KEY"] ?? ""
            let clientKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]

            let aliasMapping = ProcessInfo.processInfo
                .environment["ENABLE_MODEL_ALIAS_MAPPING"] == "1"
            let bigModel = ProcessInfo.processInfo.environment["BIG_MODEL"] ?? "claude-opus-4-6"
            let middleModel = ProcessInfo.processInfo.environment["MIDDLE_MODEL"] ?? "claude-sonnet-4-6"
            let smallModel = ProcessInfo.processInfo.environment["SMALL_MODEL"] ?? "claude-haiku-4-5"
            // 全局统一代理（OpenCode anthropic 接口）随启动注入初始真实模型 → 无条件改写入站 model。
            let forcedModel = ProcessInfo.processInfo.environment["ANTHROPIC_FORCED_MODEL"]

            return ClaudeProxyConfiguration(
                enabled: true,
                mode: .anthropicPassthrough,
                upstreamBaseURL: baseURL,
                upstreamAPIKey: apiKey,
                expectedClientKey: clientKey,
                expectedDesktopClientKey: desktopClientKey,
                bigModel: bigModel,
                middleModel: middleModel,
                smallModel: smallModel,
                enableModelAliasMapping: aliasMapping,
                availableModels: catalogModels,
                defaultModel: catalogDefault,
                exposeScienceModelCatalog: exposeCatalog,
                preferExactCatalogModels: preferExactCatalog,
                catalogRouteStyle: catalogRouteStyle,
                mapDesktopTierRoutes: mapDesktopTierRoutes,
                catalogSupports1M: catalogSupports1M,
                forcedModel: forcedModel
            )
        }

        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            return nil
        }

        let baseURL = ProcessInfo.processInfo.environment["OPENAI_BASE_URL"] ?? "https://api.openai.com"
        let openAIUpstreamAPI = OpenAIUpstreamAPI.fromEnvironment(
            ProcessInfo.processInfo.environment["OPENAI_API_MODE"]
        )
        let clientKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        let bigModel = ProcessInfo.processInfo.environment["BIG_MODEL"] ?? "gpt-4o"
        let middleModel = ProcessInfo.processInfo.environment["MIDDLE_MODEL"] ?? "gpt-4o-mini"
        let smallModel = ProcessInfo.processInfo.environment["SMALL_MODEL"] ?? "gpt-3.5-turbo"
        let maxOutputTokens = ProcessInfo.processInfo.environment["MAX_OUTPUT_TOKENS"].flatMap { Int($0) }

        return ClaudeProxyConfiguration(
            enabled: true,
            mode: .openaiConvert,
            upstreamBaseURL: baseURL,
            openAIUpstreamAPI: openAIUpstreamAPI,
            upstreamAPIKey: apiKey,
            expectedClientKey: clientKey,
            expectedDesktopClientKey: desktopClientKey,
            bigModel: bigModel,
            middleModel: middleModel,
            smallModel: smallModel,
            maxOutputTokens: maxOutputTokens,
            availableModels: catalogModels,
            defaultModel: catalogDefault,
            exposeScienceModelCatalog: exposeCatalog,
            preferExactCatalogModels: preferExactCatalog,
            catalogRouteStyle: catalogRouteStyle,
            mapDesktopTierRoutes: mapDesktopTierRoutes,
            catalogSupports1M: catalogSupports1M
        )
    }
}

// MARK: - Configuration Error

public enum ConfigurationError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case invalidURL
    case invalidModel
    case invalidPort

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Missing API key"
        case .invalidURL:
            return "Invalid upstream URL"
        case .invalidModel:
            return "Invalid model configuration"
        case .invalidPort:
            return "Invalid bind port; use a value from 1 through 65535"
        }
    }
}
