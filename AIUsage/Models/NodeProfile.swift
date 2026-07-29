import Foundation
import QuotaBackend

enum CommonConfigMode: String, Codable, CaseIterable {
    case followGlobal
    case alwaysMerge
    case neverMerge

    var label: String {
        switch self {
        case .followGlobal: return AppSettings.shared.t("Follow Global", "跟随全局")
        case .alwaysMerge: return AppSettings.shared.t("Always Merge", "始终合并")
        case .neverMerge: return AppSettings.shared.t("Never Merge", "从不合并")
        }
    }

    var description: String {
        switch self {
        case .followGlobal:
            return AppSettings.shared.t(
                "Use the global common config switch.",
                "使用全局通用配置开关。"
            )
        case .alwaysMerge:
            return AppSettings.shared.t(
                "Merge common config for this node even if the global switch is off.",
                "即使全局开关关闭，也为该节点合并通用配置。"
            )
        case .neverMerge:
            return AppSettings.shared.t(
                "Do not merge common config for this node.",
                "该节点不合并通用配置。"
            )
        }
    }

    func shouldMerge(globalEnabled: Bool) -> Bool {
        switch self {
        case .followGlobal: return globalEnabled
        case .alwaysMerge: return true
        case .neverMerge: return false
        }
    }
}

// MARK: - Node Profile
// Each node profile is a standalone JSON file at ~/.config/aiusage/profiles/<id>.json.
// The file contains a `_metadata` wrapper (proxy config, name, timestamps) alongside
// the full settings.json content. Activating a profile writes everything except `_metadata`
// into ~/.claude/settings.json.

struct NodeProfile: Identifiable, Equatable {
    var metadata: Metadata
    var settings: [String: Any]

    var id: String { metadata.id }

    static func == (lhs: NodeProfile, rhs: NodeProfile) -> Bool {
        guard lhs.metadata == rhs.metadata else { return false }
        guard let lData = try? JSONSerialization.data(withJSONObject: lhs.settings, options: .sortedKeys),
              let rData = try? JSONSerialization.data(withJSONObject: rhs.settings, options: .sortedKeys) else {
            return false
        }
        return lData == rData
    }

    // MARK: - Metadata

    struct Metadata: Codable, Equatable {
        var id: String
        var name: String
        var nodeType: NodeType
        var createdAt: Date
        var lastUsedAt: Date?
        var sortOrder: Int
        var proxy: ProxySettings
        /// 若该节点由「API 提供商」分发而来，记录其主配置 id；nil = 手动创建的独立节点。
        var linkedProviderId: String?
        /// 已被用户在本节点局部覆盖、不再跟随主配置同步的共享字段键集合（见 APIProviderSharedKey）。
        var overriddenKeys: Set<String>?

        init(
            id: String = UUID().uuidString,
            name: String = "",
            nodeType: NodeType = .openaiProxy,
            createdAt: Date = Date(),
            lastUsedAt: Date? = nil,
            sortOrder: Int = Int.max,
            proxy: ProxySettings = .defaultOpenAI,
            linkedProviderId: String? = nil,
            overriddenKeys: Set<String>? = nil
        ) {
            self.id = id
            self.name = name
            self.nodeType = nodeType
            self.createdAt = createdAt
            self.lastUsedAt = lastUsedAt
            self.sortOrder = sortOrder
            self.proxy = proxy
            self.linkedProviderId = linkedProviderId
            self.overriddenKeys = overriddenKeys
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            nodeType = try container.decode(NodeType.self, forKey: .nodeType)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
            sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? Int.max
            proxy = try container.decode(ProxySettings.self, forKey: .proxy)
            linkedProviderId = try container.decodeIfPresent(String.self, forKey: .linkedProviderId)
            overriddenKeys = try container.decodeIfPresent(Set<String>.self, forKey: .overriddenKeys)
        }
    }

    // MARK: Serialize / Deserialize

    private static let metadataKey = "_metadata"

    func toFileData() throws -> Data {
        var root = settings
        let metaData = try JSONEncoder.profileEncoder.encode(metadata)
        guard let metaObj = try JSONSerialization.jsonObject(with: metaData) as? [String: Any] else {
            throw NodeProfileError.serializationFailed
        }
        root[Self.metadataKey] = metaObj
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func fromFileData(_ data: Data) throws -> NodeProfile {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NodeProfileError.invalidRootObject
        }
        guard let metaObj = root[metadataKey] as? [String: Any] else {
            throw NodeProfileError.missingMetadata
        }
        let metaData = try JSONSerialization.data(withJSONObject: metaObj)
        let metadata = try JSONDecoder.profileDecoder.decode(Metadata.self, from: metaData)

        var settings = root
        settings.removeValue(forKey: metadataKey)
        return NodeProfile(metadata: metadata, settings: settings)
    }

    /// Settings content suitable for writing into ~/.claude/settings.json (everything except _metadata).
    var settingsData: Data {
        get throws {
            try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        }
    }

    /// Readable JSON string of the settings portion (for the raw JSON editor).
    var settingsJSONString: String {
        guard let data = try? settingsData,
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    // MARK: Factory

    static func defaultProfile(nodeType: NodeType = .openaiProxy) -> NodeProfile {
        let proxy: ProxySettings
        let defaultModel: String
        switch nodeType {
        case .openaiProxy:
            proxy = .defaultOpenAI
            defaultModel = "gpt-5.5"
        case .anthropicDirect:
            proxy = .defaultAnthropic
            defaultModel = "claude-sonnet-4-6"
        case .codexProxy:
            proxy = .defaultCodex
            defaultModel = ProxyConfiguration.ModelMapping.codexDefault.bigModel.name
        }

        // Codex 节点不写 ~/.claude/settings.json（改写 ~/.codex/config.toml），落盘保持空 settings，
        // 避免 profile 文件里塞一份运行时用不上的 Claude blob（$schema / env / model）。
        if nodeType.isCodex {
            return NodeProfile(metadata: Metadata(nodeType: nodeType, proxy: proxy), settings: [:])
        }

        let envConfig = proxy.buildEnvConfig(nodeType: nodeType)
        var settings: [String: Any] = [
            "$schema": "https://json.schemastore.org/claude-code-settings.json",
        ]
        if !defaultModel.isEmpty {
            settings["model"] = defaultModel
        }
        var env: [String: String] = [:]
        if let v = envConfig.baseURL { env["ANTHROPIC_BASE_URL"] = v }
        if let v = envConfig.authToken { env["ANTHROPIC_AUTH_TOKEN"] = v }
        if let v = envConfig.opusModel { env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = v }
        if let v = envConfig.sonnetModel { env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = v }
        if let v = envConfig.haikuModel { env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = v }
        if !env.isEmpty { settings["env"] = env }

        return NodeProfile(
            metadata: Metadata(nodeType: nodeType, proxy: proxy),
            settings: settings
        )
    }

    // MARK: - Migration from legacy ProxyConfiguration

    static func fromLegacyConfiguration(_ config: ProxyConfiguration) -> NodeProfile {
        let proxy = ProxySettings(from: config)
        let metadata = Metadata(
            id: config.id,
            name: config.name,
            nodeType: config.nodeType,
            createdAt: config.createdAt,
            lastUsedAt: config.lastUsedAt,
            proxy: proxy
        )

        // Codex 节点落盘保持空 settings（同 defaultProfile）。
        if config.nodeType.isCodex {
            return NodeProfile(metadata: metadata, settings: [:])
        }

        let envConfig = proxy.buildEnvConfig(nodeType: config.nodeType)
        var settings: [String: Any] = [
            "$schema": "https://json.schemastore.org/claude-code-settings.json",
        ]
        if !config.defaultModel.isEmpty {
            settings["model"] = config.defaultModel
        }
        var env: [String: String] = [:]
        if let v = envConfig.baseURL { env["ANTHROPIC_BASE_URL"] = v }
        if let v = envConfig.authToken { env["ANTHROPIC_AUTH_TOKEN"] = v }
        if let v = envConfig.opusModel { env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = v }
        if let v = envConfig.sonnetModel { env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = v }
        if let v = envConfig.haikuModel { env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = v }
        if !env.isEmpty { settings["env"] = env }

        return NodeProfile(metadata: metadata, settings: settings)
    }

    // MARK: - Sync helpers

    /// Reverse-syncs model names from the settings dictionary into metadata.proxy.
    /// Called after applying JSON edits so that metadata stays consistent with settings content.
    mutating func syncProxyFromSettings() {
        if let model = settings["model"] as? String, !model.isEmpty {
            metadata.proxy.defaultModel = model
        }
        guard let env = settings["env"] as? [String: Any] else { return }
        if let opus = env["ANTHROPIC_DEFAULT_OPUS_MODEL"] as? String, !opus.isEmpty {
            metadata.proxy.modelMapping.bigModel.name = opus
        }
        if let sonnet = env["ANTHROPIC_DEFAULT_SONNET_MODEL"] as? String, !sonnet.isEmpty {
            metadata.proxy.modelMapping.middleModel.name = sonnet
        }
        if let haiku = env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] as? String, !haiku.isEmpty {
            metadata.proxy.modelMapping.smallModel.name = haiku
        }
    }

    /// Rebuilds the `env` keys managed by the proxy from the current proxy settings,
    /// preserving any user-added env keys.
    mutating func syncEnvFromProxy() {
        // Codex 节点不写 Claude settings.json，落盘保持空；配置全在 metadata.proxy / extraTOML。
        if metadata.nodeType.isCodex {
            settings = [:]
            return
        }
        let envConfig = metadata.proxy.buildEnvConfig(nodeType: metadata.nodeType)
        var env = settings["env"] as? [String: Any] ?? [:]

        let managedKeys = [
            "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        ]
        for key in managedKeys { env.removeValue(forKey: key) }

        let pairs: [(String, String?)] = [
            ("ANTHROPIC_BASE_URL", envConfig.baseURL),
            ("ANTHROPIC_AUTH_TOKEN", envConfig.authToken),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL", envConfig.opusModel),
            ("ANTHROPIC_DEFAULT_SONNET_MODEL", envConfig.sonnetModel),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL", envConfig.haikuModel),
        ]
        for (key, value) in pairs {
            if let value { env[key] = value }
        }
        settings["env"] = env.isEmpty ? nil : env

        if let dm = envConfig.defaultModel, !dm.isEmpty {
            settings["model"] = dm
        }
    }
}

// MARK: - Proxy Settings

/// Proxy-specific configuration extracted from the legacy ProxyConfiguration.
/// Stored inside `_metadata.proxy` in profile JSON files.
struct ProxySettings: Codable, Equatable {
    var host: String
    var port: Int
    var allowLAN: Bool
    var upstreamBaseURL: String
    var openAIUpstreamAPI: OpenAIUpstreamAPI
    var upstreamAPIKey: String
    var expectedClientKey: String
    var maxOutputTokens: Int
    var defaultModel: String
    var modelMapping: ProxyConfiguration.ModelMapping
    /// 节点模型目录：可用模型与费用规则分离，费用规则缺失即“未定价”。
    var modelCatalog: ProxyConfiguration.ModelCatalog

    var anthropicBaseURL: String
    var anthropicAPIKey: String
    var usePassthroughProxy: Bool
    var enableModelAliasMapping: Bool?
    /// Legacy per-node listener fields. Claude Desktop uses the single
    /// `GlobalProxyConfig.claudeDesktopHTTPSPort`; keep these optional values
    /// decodable until the profile schema has a dedicated migration.
    var enableHTTPS: Bool?
    var httpsPort: Int?
    var commonConfigMode: CommonConfigMode?

    /// Codex 专用：该节点的额外 TOML 顶层键（如 model_reasoning_effort、request_max_retries）。
    /// 激活时与全局通用配置按顶层键合并（节点键覆盖全局），注入受管理 BASE 块。可选以兼容旧档。
    var extraTOML: String?

    var effectiveHTTPSPort: Int { httpsPort ?? (port + 1) }

    static var defaultOpenAI: ProxySettings {
        ProxySettings(
            host: "127.0.0.1", port: 8080, allowLAN: false,
            upstreamBaseURL: "https://api.openai.com",
            openAIUpstreamAPI: .chatCompletions,
            upstreamAPIKey: "", expectedClientKey: "",
            maxOutputTokens: 0, defaultModel: "gpt-5.5",
            modelMapping: .openAIDefault,
            anthropicBaseURL: "https://api.anthropic.com",
            anthropicAPIKey: "", usePassthroughProxy: true,
            enableModelAliasMapping: false,
            enableHTTPS: false, httpsPort: nil
        )
    }

    static var defaultAnthropic: ProxySettings {
        ProxySettings(
            host: "127.0.0.1", port: 8080, allowLAN: false,
            upstreamBaseURL: "https://api.openai.com",
            openAIUpstreamAPI: .chatCompletions,
            upstreamAPIKey: "", expectedClientKey: "",
            maxOutputTokens: 0, defaultModel: "claude-sonnet-4-6",
            modelMapping: .anthropicDefault,
            anthropicBaseURL: "https://api.anthropic.com",
            anthropicAPIKey: "", usePassthroughProxy: false,
            enableModelAliasMapping: false,
            enableHTTPS: false, httpsPort: nil
        )
    }

    /// Codex 节点默认：端口 4319（避开 Claude 默认 8080），单模型存 modelMapping.bigModel，
    /// 上游走 Responses（Codex 的 wire_api），不启用 HTTPS（本地 http 即可，Codex 不信任自签证书）。
    static var defaultCodex: ProxySettings {
        ProxySettings(
            host: "127.0.0.1", port: 4319, allowLAN: false,
            upstreamBaseURL: "https://api.openai.com",
            openAIUpstreamAPI: .responses,
            upstreamAPIKey: "", expectedClientKey: "",
            maxOutputTokens: 0,
            defaultModel: ProxyConfiguration.ModelMapping.codexDefault.bigModel.name,
            modelMapping: .codexDefault,
            anthropicBaseURL: "https://api.anthropic.com",
            anthropicAPIKey: "", usePassthroughProxy: false,
            enableModelAliasMapping: false,
            enableHTTPS: false, httpsPort: nil
        )
    }

    init(from config: ProxyConfiguration) {
        host = config.host
        port = config.port
        allowLAN = config.allowLAN
        upstreamBaseURL = config.upstreamBaseURL
        openAIUpstreamAPI = config.openAIUpstreamAPI
        upstreamAPIKey = config.upstreamAPIKey
        expectedClientKey = config.expectedClientKey
        maxOutputTokens = config.maxOutputTokens
        defaultModel = config.defaultModel
        modelMapping = config.modelMapping
        modelCatalog = config.modelCatalog
        anthropicBaseURL = config.anthropicBaseURL
        anthropicAPIKey = config.anthropicAPIKey
        usePassthroughProxy = config.usePassthroughProxy
        enableModelAliasMapping = config.enableModelAliasMapping
        enableHTTPS = config.enableHTTPS
        httpsPort = config.httpsPort
        extraTOML = nil
    }

    init(
        host: String, port: Int, allowLAN: Bool,
        upstreamBaseURL: String, openAIUpstreamAPI: OpenAIUpstreamAPI,
        upstreamAPIKey: String, expectedClientKey: String,
        maxOutputTokens: Int, defaultModel: String,
        modelMapping: ProxyConfiguration.ModelMapping,
        modelCatalog: ProxyConfiguration.ModelCatalog = .empty,
        anthropicBaseURL: String, anthropicAPIKey: String, usePassthroughProxy: Bool,
        enableModelAliasMapping: Bool = false,
        enableHTTPS: Bool? = nil, httpsPort: Int? = nil,
        commonConfigMode: CommonConfigMode? = nil,
        extraTOML: String? = nil
    ) {
        self.host = host
        self.port = port
        self.allowLAN = allowLAN
        self.upstreamBaseURL = upstreamBaseURL
        self.openAIUpstreamAPI = openAIUpstreamAPI
        self.upstreamAPIKey = upstreamAPIKey
        self.expectedClientKey = expectedClientKey
        self.maxOutputTokens = maxOutputTokens
        self.defaultModel = defaultModel
        self.modelMapping = modelMapping
        self.modelCatalog = modelCatalog
        self.anthropicBaseURL = anthropicBaseURL
        self.anthropicAPIKey = anthropicAPIKey
        self.usePassthroughProxy = usePassthroughProxy
        self.enableModelAliasMapping = enableModelAliasMapping
        self.enableHTTPS = enableHTTPS
        self.httpsPort = httpsPort
        self.commonConfigMode = commonConfigMode
        self.extraTOML = extraTOML
    }

    private enum CodingKeys: String, CodingKey {
        case host, port, allowLAN
        case upstreamBaseURL, openAIUpstreamAPI, upstreamAPIKey, expectedClientKey
        case maxOutputTokens, defaultModel, modelMapping, modelCatalog
        case modelLibrary // 0.15.x 及更早，仅解码迁移
        case anthropicBaseURL, anthropicAPIKey, usePassthroughProxy
        case enableModelAliasMapping, enableHTTPS, httpsPort
        case commonConfigMode, extraTOML
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 8080
        allowLAN = try container.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? false
        upstreamBaseURL = ClaudeProxyConfiguration.normalizeOpenAIBaseURL(
            try container.decodeIfPresent(String.self, forKey: .upstreamBaseURL) ?? "https://api.openai.com"
        )
        openAIUpstreamAPI = try container.decodeIfPresent(OpenAIUpstreamAPI.self, forKey: .openAIUpstreamAPI) ?? .chatCompletions
        upstreamAPIKey = try container.decodeIfPresent(String.self, forKey: .upstreamAPIKey) ?? ""
        expectedClientKey = try container.decodeIfPresent(String.self, forKey: .expectedClientKey) ?? ""
        maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? 0
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel) ?? ""

        let legacyMapping = try container.decodeIfPresent(
            ProxyConfiguration.LegacyModelMapping.self,
            forKey: .modelMapping
        ) ?? ProxyConfiguration.LegacyModelMapping(current: .openAIDefault)
        modelMapping = legacyMapping.current

        if let currentCatalog = try container.decodeIfPresent(
            ProxyConfiguration.ModelCatalog.self,
            forKey: .modelCatalog
        ) {
            modelCatalog = .init(
                models: currentCatalog.models,
                pricingOverrides: currentCatalog.pricingOverrides
            )
        } else {
            let legacyLibrary = try container.decodeIfPresent(
                [ProxyConfiguration.MappedModel].self,
                forKey: .modelLibrary
            ) ?? []
            modelCatalog = .migrated(
                legacyLibrary: legacyLibrary,
                legacyMapping: legacyMapping,
                defaultModel: defaultModel
            )
        }

        anthropicBaseURL = try container.decodeIfPresent(String.self, forKey: .anthropicBaseURL) ?? "https://api.anthropic.com"
        anthropicAPIKey = try container.decodeIfPresent(String.self, forKey: .anthropicAPIKey) ?? ""
        usePassthroughProxy = try container.decodeIfPresent(Bool.self, forKey: .usePassthroughProxy) ?? false
        enableModelAliasMapping = try container.decodeIfPresent(Bool.self, forKey: .enableModelAliasMapping)
        enableHTTPS = try container.decodeIfPresent(Bool.self, forKey: .enableHTTPS)
        httpsPort = try container.decodeIfPresent(Int.self, forKey: .httpsPort)
        commonConfigMode = try container.decodeIfPresent(CommonConfigMode.self, forKey: .commonConfigMode)
        extraTOML = try container.decodeIfPresent(String.self, forKey: .extraTOML)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(allowLAN, forKey: .allowLAN)
        try container.encode(upstreamBaseURL, forKey: .upstreamBaseURL)
        try container.encode(openAIUpstreamAPI, forKey: .openAIUpstreamAPI)
        try container.encode(upstreamAPIKey, forKey: .upstreamAPIKey)
        try container.encode(expectedClientKey, forKey: .expectedClientKey)
        try container.encode(maxOutputTokens, forKey: .maxOutputTokens)
        try container.encode(defaultModel, forKey: .defaultModel)
        try container.encode(modelMapping, forKey: .modelMapping)
        try container.encode(modelCatalog, forKey: .modelCatalog)
        try container.encode(anthropicBaseURL, forKey: .anthropicBaseURL)
        try container.encode(anthropicAPIKey, forKey: .anthropicAPIKey)
        try container.encode(usePassthroughProxy, forKey: .usePassthroughProxy)
        try container.encodeIfPresent(enableModelAliasMapping, forKey: .enableModelAliasMapping)
        try container.encodeIfPresent(enableHTTPS, forKey: .enableHTTPS)
        try container.encodeIfPresent(httpsPort, forKey: .httpsPort)
        try container.encodeIfPresent(commonConfigMode, forKey: .commonConfigMode)
        try container.encodeIfPresent(extraTOML, forKey: .extraTOML)
    }

    var bindAddress: String { allowLAN ? "0.0.0.0" : host }

    var displayURL: String { "http://\(host):\(port)" }

    var normalizedUpstreamBaseURL: String {
        ClaudeProxyConfiguration.normalizeOpenAIBaseURL(upstreamBaseURL)
    }

    func needsProxyProcess(nodeType: NodeType) -> Bool {
        true
    }

    func shouldMergeClaudeCommonConfig(globalEnabled: Bool) -> Bool {
        (commonConfigMode ?? .followGlobal).shouldMerge(globalEnabled: globalEnabled)
    }

    /// 费用规则仅按真实模型名精确匹配；没有规则即未定价。
    func pricingForModel(_ model: String) -> ProxyConfiguration.ModelPricing? {
        modelCatalog.pricingOverrides[model.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// 新节点或缺少目录的旧节点用应用映射名称播种；不会自动创建费用规则。
    mutating func seedModelCatalogIfEmpty() {
        guard modelCatalog.models.isEmpty else { return }
        modelCatalog.mergeModels([
            defaultModel,
            modelMapping.bigModel.name,
            modelMapping.middleModel.name,
            modelMapping.smallModel.name,
        ])
    }

    /// Build the env config that will be written to settings.json.
    func buildEnvConfig(nodeType: NodeType) -> ClaudeSettingsManager.EnvConfig {
        let m = modelMapping
        let dm = defaultModel.isEmpty ? nil : defaultModel
        let opus = m.bigModel.name.isEmpty ? nil : m.bigModel.name
        let sonnet = m.middleModel.name.isEmpty ? nil : m.middleModel.name
        let haiku = m.smallModel.name.isEmpty ? nil : m.smallModel.name

        switch nodeType {
        case .anthropicDirect:
            // Anthropic-compatible nodes use the same fixed local runtime
            // contract as conversion nodes. Apps never bypass the node port.
            let clientToken = expectedClientKey.isEmpty ? "proxy-key" : expectedClientKey
            return .init(baseURL: displayURL, authToken: clientToken,
                         defaultModel: dm, opusModel: opus, sonnetModel: sonnet, haikuModel: haiku)
        case .openaiProxy:
            let proxyKey = expectedClientKey.isEmpty ? "proxy-key" : expectedClientKey
            return .init(baseURL: displayURL, authToken: proxyKey,
                         defaultModel: dm, opusModel: opus, sonnetModel: sonnet, haikuModel: haiku)
        case .codexProxy:
            // Codex 节点不写 ~/.claude/settings.json（改写 ~/.codex/config.toml），
            // 故此处返回空 env，profile 的 settings 内容对 Codex 运行时无影响。
            return .init(baseURL: nil, authToken: nil,
                         defaultModel: nil, opusModel: nil, sonnetModel: nil, haikuModel: nil,
                         nodeExtraCACerts: nil)
        }
    }

    /// Convert back to legacy ProxyConfiguration (for runtime compatibility).
    func toProxyConfiguration(metadata: NodeProfile.Metadata) -> ProxyConfiguration {
        ProxyConfiguration(
            id: metadata.id,
            name: metadata.name,
            nodeType: metadata.nodeType,
            isEnabled: false,
            anthropicBaseURL: anthropicBaseURL,
            anthropicAPIKey: anthropicAPIKey,
            usePassthroughProxy: usePassthroughProxy,
            host: host,
            port: port,
            allowLAN: allowLAN,
            upstreamBaseURL: upstreamBaseURL,
            openAIUpstreamAPI: openAIUpstreamAPI,
            upstreamAPIKey: upstreamAPIKey,
            expectedClientKey: expectedClientKey,
            defaultModel: defaultModel,
            modelMapping: modelMapping,
            modelCatalog: modelCatalog,
            maxOutputTokens: maxOutputTokens,
            createdAt: metadata.createdAt,
            lastUsedAt: metadata.lastUsedAt,
            enableModelAliasMapping: enableModelAliasMapping ?? false,
            enableHTTPS: enableHTTPS ?? false,
            httpsPort: httpsPort
        )
    }
}

// MARK: - Profile Errors

enum NodeProfileError: LocalizedError {
    case invalidRootObject
    case missingMetadata
    case serializationFailed
    case fileWriteFailed
    case directoryCreationFailed

    var errorDescription: String? {
        switch self {
        case .invalidRootObject:
            return AppSettings.shared.t("Profile JSON must be a top-level object.", "配置文件 JSON 必须是顶层对象。")
        case .missingMetadata:
            return AppSettings.shared.t("Profile is missing the _metadata field.", "配置文件缺少 _metadata 字段。")
        case .serializationFailed:
            return AppSettings.shared.t("Failed to serialize profile.", "序列化配置文件失败。")
        case .fileWriteFailed:
            return AppSettings.shared.t("Failed to write profile file.", "写入配置文件失败。")
        case .directoryCreationFailed:
            return AppSettings.shared.t("Failed to create profiles directory.", "创建配置文件目录失败。")
        }
    }
}

// MARK: - JSON Coder Helpers

extension JSONEncoder {
    static let profileEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let profileDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
