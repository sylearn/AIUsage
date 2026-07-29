import Foundation
import QuotaBackend

// MARK: - API Provider
// 「API 提供商」是一份与具体代理无关的统一上游配置（baseURL + apiKey + 格式 + 模型/定价）。
// 它是分发到 Codex / Claude / OpenCode 三套代理的「主配置/真相源」：
//   - distribute：把主配置映射成各代理的节点（链接节点，携带 linkedProviderId）。
//   - 同步模型（继承 + 局部覆盖）：主配置改了，链接节点里未被局部覆盖的共享字段跟随同步；
//     代理专属字段（端口、Claude 槽位、OpenCode slug/生成参数等）始终本地独立。
// 持久化: ~/.config/aiusage/api-providers.json（APIProviderStore）。

/// API 接口格式：决定可分发到哪些代理、以及映射出的节点类型/上游协议。
enum APIFormat: String, Codable, CaseIterable, Identifiable {
    /// OpenAI Chat Completions（绝大多数兼容上游：DeepSeek、Ollama、第三方网关…）。
    case openAIChatCompletions = "openai-chat-completions"
    /// Anthropic Messages（官方或 Anthropic 兼容网关）。
    case anthropic = "anthropic"
    /// OpenAI Responses（官方 /v1/responses 或同协议网关；Codex 仅支持此格式）。
    case openAIResponses = "openai-responses"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAIChatCompletions: return AppSettings.shared.t("OpenAI Chat Completions", "OpenAI Chat Completions")
        case .anthropic: return "Anthropic"
        case .openAIResponses: return "OpenAI Responses"
        }
    }

    var badgeName: String {
        switch self {
        case .openAIChatCompletions: return "OpenAI Chat"
        case .anthropic: return "Anthropic"
        case .openAIResponses: return "Responses"
        }
    }

    /// 映射到 OpenCode 受管 provider 协议。
    var openCodeProtocol: OpenCodeProtocol {
        switch self {
        case .openAIChatCompletions: return .openAICompatible
        case .anthropic: return .anthropic
        case .openAIResponses: return .openAIResponses
        }
    }

    /// 映射到 OpenAI 上游接口模式（Anthropic 格式无对应，返回 nil）。
    var openAIUpstreamAPI: OpenAIUpstreamAPI? {
        switch self {
        case .openAIChatCompletions: return .chatCompletions
        case .openAIResponses: return .responses
        case .anthropic: return nil
        }
    }
}

/// CPA 托管 Claude Code（含 Science）节点的上游协议，与 Claude 节点编辑器三卡片对齐。
enum ManagedClaudeProtocol: String, Codable, CaseIterable, Identifiable {
    /// Anthropic Messages 透传（默认；避免 Science 复杂载荷撞本地 convert）。
    case anthropicPassthrough = "anthropic-passthrough"
    /// 经本地代理转成 OpenAI Chat Completions。
    case openAIChatCompletions = "openai-chat-completions"
    /// 经本地代理转成 OpenAI Responses。
    case openAIResponses = "openai-responses"

    var id: String { rawValue }

    /// 兼容旧 UserDefaults：`openai-convert`（拆分前的笼统 OpenAI 转换，CPA 主配置为 Responses）。
    static func resolved(rawValue: String) -> ManagedClaudeProtocol? {
        if rawValue == "openai-convert" { return .openAIResponses }
        return ManagedClaudeProtocol(rawValue: rawValue)
    }

    var displayName: String {
        switch self {
        case .anthropicPassthrough:
            return "Anthropic"
        case .openAIChatCompletions:
            return "OpenAI Chat Completions"
        case .openAIResponses:
            return "OpenAI Responses"
        }
    }

    var badgeName: String {
        switch self {
        case .anthropicPassthrough: return "Anthropic"
        case .openAIChatCompletions: return "Chat Completions"
        case .openAIResponses: return "Responses"
        }
    }

    var openAIUpstreamAPI: OpenAIUpstreamAPI? {
        switch self {
        case .anthropicPassthrough: return nil
        case .openAIChatCompletions: return .chatCompletions
        case .openAIResponses: return .responses
        }
    }
}

/// 可分发到的代理目标。
enum ProxyTarget: String, Codable, CaseIterable, Identifiable {
    case codex
    case claude
    case openCode
    /// CPA 网关的 OpenAI 兼容上游池（非本地代理节点）。
    case cpa

    var id: String { rawValue }

    /// Codex / Claude / OpenCode 本地代理（不含 CPA）。CPA 接入页只用这三项。
    static var localProxyTargets: [ProxyTarget] { [.codex, .claude, .openCode] }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .openCode: return "OpenCode"
        case .cpa: return "CPA"
        }
    }

    /// 兼容性：Codex 上游锁定 Responses；CPA 首期仅 OpenAI 兼容（Chat / Responses）；
    /// Claude/OpenCode 三格式皆可（Claude：OpenAI→转换代理，Anthropic→透传）。
    func supports(_ format: APIFormat) -> Bool {
        switch self {
        case .codex: return format == .openAIResponses
        case .claude: return true
        case .openCode: return true
        case .cpa:
            return format == .openAIChatCompletions || format == .openAIResponses
        }
    }

    /// 该格式不被支持时给用户的原因说明。
    func incompatibilityReason(for format: APIFormat) -> String? {
        guard !supports(format) else { return nil }
        switch self {
        case .codex:
            return AppSettings.shared.t(
                "Codex only speaks the OpenAI Responses API upstream.",
                "Codex 上游仅支持 OpenAI Responses 接口。"
            )
        case .cpa:
            return AppSettings.shared.t(
                "CPA API upstream currently accepts OpenAI-compatible formats only.",
                "CPA 的 API 上游目前仅支持 OpenAI 兼容格式。"
            )
        default:
            return AppSettings.shared.t("Incompatible format.", "格式不兼容。")
        }
    }
}

/// 可被用户在链接节点上「局部覆盖」、覆盖后不再跟随主配置同步的共享字段键。
/// 格式（format）决定节点类型，不可单独覆盖，始终跟随主配置。
enum APIProviderSharedKey {
    static let name = "name"
    static let baseURL = "baseURL"
    static let apiKey = "apiKey"
    static let models = "models"
    static let defaultModel = "defaultModel"

    static let all: Set<String> = [name, baseURL, apiKey, models, defaultModel]
}

struct APIProvider: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var baseURL: String
    var apiKey: String
    var format: APIFormat
    /// 提供商模型清单及其默认价格；分发到节点后，模型目录与节点费用规则彼此独立。
    var models: [ProxyConfiguration.MappedModel]
    /// 顶层默认模型（应在 models 中）。
    var defaultModel: String

    // MARK: 可选共享参数（主要用于 OpenCode 映射，Codex/Claude 节点不消费）
    var contextLimit: Int
    var outputLimit: Int
    var temperature: Double?
    var topP: Double?
    var maxOutputTokens: Int
    var frequencyPenalty: Double?
    var presencePenalty: Double?

    var createdAt: Date
    var lastUsedAt: Date?
    var sortOrder: Int

    init(
        id: String = UUID().uuidString,
        name: String = "",
        baseURL: String = "",
        apiKey: String = "",
        format: APIFormat = .openAIChatCompletions,
        models: [ProxyConfiguration.MappedModel] = [],
        defaultModel: String = "",
        contextLimit: Int = 0,
        outputLimit: Int = 0,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxOutputTokens: Int = 0,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        sortOrder: Int = Int.max
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.format = format
        self.models = models
        self.defaultModel = defaultModel
        self.contextLimit = contextLimit
        self.outputLimit = outputLimit
        self.temperature = temperature
        self.topP = topP
        self.maxOutputTokens = maxOutputTokens
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.sortOrder = sortOrder
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, apiKey, format, models, defaultModel
        case contextLimit, outputLimit, temperature, topP, maxOutputTokens, frequencyPenalty, presencePenalty
        case createdAt, lastUsedAt, sortOrder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        apiKey = try c.decode(String.self, forKey: .apiKey)
        format = try c.decodeIfPresent(APIFormat.self, forKey: .format) ?? .openAIChatCompletions
        models = try c.decodeIfPresent([ProxyConfiguration.MappedModel].self, forKey: .models) ?? []
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel) ?? ""
        contextLimit = try c.decodeIfPresent(Int.self, forKey: .contextLimit) ?? 0
        outputLimit = try c.decodeIfPresent(Int.self, forKey: .outputLimit) ?? 0
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        topP = try c.decodeIfPresent(Double.self, forKey: .topP)
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? 0
        frequencyPenalty = try c.decodeIfPresent(Double.self, forKey: .frequencyPenalty)
        presencePenalty = try c.decodeIfPresent(Double.self, forKey: .presencePenalty)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? Int.max
    }

    // MARK: - Derived

    /// 展示名：未命名时回退到 baseURL 的 host。
    var displayName: String {
        if let name = name.nilIfBlank { return name }
        if let host = URL(string: baseURL)?.host { return host }
        return AppSettings.shared.t("Untitled Provider", "未命名提供商")
    }

    /// 实际生效的默认模型：defaultModel 失配时回退到列表首个。
    var effectiveDefaultModel: String {
        let names = models.map(\.name)
        if names.contains(defaultModel) { return defaultModel }
        return names.first ?? defaultModel
    }

    /// 是否填齐分发所需字段。
    var isComplete: Bool {
        baseURL.nilIfBlank != nil && !models.contains(where: { $0.name.nilIfBlank == nil }) && !models.isEmpty
    }

    /// 兼容的分发目标。
    var compatibleTargets: [ProxyTarget] {
        ProxyTarget.allCases.filter { $0.supports(format) }
    }
}

// MARK: - CPA Loop Guard
// 防止「API 提供商 → CPA」回环：
// 1) CPA 受管主配置（把 CPA 当分发出去）不能再写回 CPA；
// 2) Base URL 已指向本机 CPA 端口时也不能分发回 CPA。

enum APIProviderCPALoopGuard {
    @MainActor
    static func blockReason(for provider: APIProvider) -> String? {
        blockReason(
            for: provider,
            cpaPort: CLIProxyRuntimeController.shared.settings.normalized.port
        )
    }

    static func blockReason(for provider: APIProvider, cpaPort: Int) -> String? {
        if provider.id == CLIProxyGatewayManager.managedProviderID {
            return AppSettings.shared.t(
                "The CPA Gateway provider cannot be distributed back to CPA (loop).",
                "「CPA 网关」主配置不能再分发回 CPA（会形成回环）。"
            )
        }
        if pointsToLocalCPA(baseURL: provider.baseURL, cpaPort: cpaPort) {
            return AppSettings.shared.t(
                "Base URL points at local CPA; distributing back would loop.",
                "Base URL 指向本机 CPA，分发回去会形成回环。"
            )
        }
        return nil
    }

    static func pointsToLocalCPA(baseURL: String, cpaPort: Int) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return false }
        let loopback: Set<String> = ["localhost", "127.0.0.1", "::1", "0.0.0.0", "[::1]"]
        guard loopback.contains(host) else { return false }
        let port = url.port ?? ((url.scheme?.lowercased() == "https") ? 443 : 80)
        return port == cpaPort
    }
}
