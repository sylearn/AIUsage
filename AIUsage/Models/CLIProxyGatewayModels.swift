import CryptoKit
import Foundation

nonisolated enum CLIProxyArchitecture: String, Codable, Sendable {
    case arm64
    case x86_64

    static var current: CLIProxyArchitecture {
#if arch(arm64)
        .arm64
#elseif arch(x86_64)
        .x86_64
#else
#error("CLIProxyAPI updater only supports Apple Silicon and Intel macOS builds")
#endif
    }

    var releaseToken: String {
        switch self {
        case .arm64: "aarch64"
        case .x86_64: "amd64"
        }
    }

    var acceptedReleaseTokens: [String] {
        switch self {
        case .arm64: ["aarch64", "arm64"]
        case .x86_64: ["amd64", "x86_64"]
        }
    }

    var lipoToken: String { rawValue }
}

nonisolated struct CLIProxyGitHubAsset: Decodable, Sendable {
    let name: String
    let browserDownloadURL: URL
    let digest: String?
    let size: Int64

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case digest
        case size
    }

    var sha256: String? {
        guard let digest else { return nil }
        let prefix = "sha256:"
        guard digest.hasPrefix(prefix) else { return nil }
        let value = String(digest.dropFirst(prefix.count)).lowercased()
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            return nil
        }
        return value
    }
}

nonisolated struct CLIProxyGitHubRelease: Decodable, Sendable {
    let tagName: String
    let name: String?
    let body: String?
    let prerelease: Bool
    let publishedAt: Date?
    let assets: [CLIProxyGitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case prerelease
        case publishedAt = "published_at"
        case assets
    }

    var version: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }

    func fullMacOSAsset(for architecture: CLIProxyArchitecture) -> CLIProxyGitHubAsset? {
        return assets.first { asset in
            matchesFullMacOSAsset(asset, architecture: architecture) && asset.sha256 != nil
        }
    }

    func hasFullMacOSAsset(for architecture: CLIProxyArchitecture) -> Bool {
        assets.contains { matchesFullMacOSAsset($0, architecture: architecture) }
    }

    private func matchesFullMacOSAsset(
        _ asset: CLIProxyGitHubAsset,
        architecture: CLIProxyArchitecture
    ) -> Bool {
        let lowercased = asset.name.lowercased()
        guard !lowercased.contains("no-plugin") else { return false }
        return architecture.acceptedReleaseTokens.contains { token in
            lowercased.hasSuffix("_darwin_\(token).tar.gz")
        }
    }
}

nonisolated struct CLIProxyRelease: Identifiable, Sendable, Equatable {
    let tagName: String
    let version: String
    let assetName: String
    let downloadURL: URL
    let sha256: String
    let size: Int64
    let releaseNotes: String?
    let publishedAt: Date?

    var id: String { version }

    init(
        tagName: String,
        version: String,
        assetName: String,
        downloadURL: URL,
        sha256: String,
        size: Int64,
        releaseNotes: String? = nil,
        publishedAt: Date? = nil
    ) {
        self.tagName = tagName
        self.version = version
        self.assetName = assetName
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.size = size
        self.releaseNotes = releaseNotes
        self.publishedAt = publishedAt
    }

    init?(githubRelease: CLIProxyGitHubRelease, architecture: CLIProxyArchitecture) {
        guard !githubRelease.prerelease,
              CLIProxyVersion.isSafePathComponent(githubRelease.version),
              let asset = githubRelease.fullMacOSAsset(for: architecture),
              let sha256 = asset.sha256 else {
            return nil
        }
        tagName = githubRelease.tagName
        version = githubRelease.version
        assetName = asset.name
        downloadURL = asset.browserDownloadURL
        self.sha256 = sha256
        size = asset.size
        releaseNotes = githubRelease.body
        publishedAt = githubRelease.publishedAt
    }
}

nonisolated struct CLIProxyInstalledVersion: Identifiable, Sendable, Equatable {
    let version: String
    let binaryURL: URL
    let installedAt: Date
    let isCurrent: Bool

    var id: String { version }
}

nonisolated enum CLIProxyGatewayOperation: Equatable {
    case idle
    case checking
    case downloading(version: String)
    case verifying(version: String)
    case installing(version: String)
    case activating(version: String)

    var isBusy: Bool { self != .idle }
}

nonisolated enum CLIProxyRoutingStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    case roundRobin = "round-robin"
    case fillFirst = "fill-first"

    var id: String { rawValue }
}

nonisolated struct CLIProxyGatewaySettings: Codable, Equatable, Sendable {
    var port: Int = 14420
    var autoStart: Bool = false
    var allowLANAccess: Bool = false
    var routingStrategy: CLIProxyRoutingStrategy = .roundRobin
    /// CPA `request-retry`：单次请求在可用凭据上的重试次数上限（含 429 冷却等待场景）。
    /// 官方示例默认 3；与「额度用尽换号」互补，不是二选一。
    var requestRetry: Int = 3
    /// CPA `max-retry-interval`（秒）。为 0 时上游会跳过冷却等待重试，429 几乎无法换号。
    var maxRetryInterval: Int = 30
    /// CPA `max-retry-credentials`：单次请求最多尝试几把凭据；0 = 尝试全部可用凭据。
    var maxRetryCredentials: Int = 0
    /// CPA `quota-exceeded.switch-project`。缺省写入 true：额度/429 时切到其它可用凭据。
    var quotaSwitchProject: Bool = true
    /// CPA `quota-exceeded.switch-preview-model`。
    var quotaSwitchPreviewModel: Bool = true
    /// CPA `quota-exceeded.antigravity-credits`。
    var quotaAntigravityCredits: Bool = true
    var proxyURL: String = ""
    var enablePlugins: Bool = false
    /// AIUsage 侧：定时用「列模型」复检账号连通（不写 CPA yaml，无需重启进程）。
    var accountModelProbeEnabled: Bool = true
    /// 复检间隔（秒）。
    var accountModelProbeIntervalSeconds: Int = 60

    static let `default` = CLIProxyGatewaySettings()

    init(
        port: Int = 14420,
        autoStart: Bool = false,
        allowLANAccess: Bool = false,
        routingStrategy: CLIProxyRoutingStrategy = .roundRobin,
        requestRetry: Int = 3,
        maxRetryInterval: Int = 30,
        maxRetryCredentials: Int = 0,
        quotaSwitchProject: Bool = true,
        quotaSwitchPreviewModel: Bool = true,
        quotaAntigravityCredits: Bool = true,
        proxyURL: String = "",
        enablePlugins: Bool = false,
        accountModelProbeEnabled: Bool = true,
        accountModelProbeIntervalSeconds: Int = 60
    ) {
        self.port = port
        self.autoStart = autoStart
        self.allowLANAccess = allowLANAccess
        self.routingStrategy = routingStrategy
        self.requestRetry = requestRetry
        self.maxRetryInterval = maxRetryInterval
        self.maxRetryCredentials = maxRetryCredentials
        self.quotaSwitchProject = quotaSwitchProject
        self.quotaSwitchPreviewModel = quotaSwitchPreviewModel
        self.quotaAntigravityCredits = quotaAntigravityCredits
        self.proxyURL = proxyURL
        self.enablePlugins = enablePlugins
        self.accountModelProbeEnabled = accountModelProbeEnabled
        self.accountModelProbeIntervalSeconds = accountModelProbeIntervalSeconds
    }

    enum CodingKeys: String, CodingKey {
        case port, autoStart, allowLANAccess, routingStrategy, requestRetry
        case maxRetryInterval, maxRetryCredentials
        case quotaSwitchProject, quotaSwitchPreviewModel, quotaAntigravityCredits
        case proxyURL, enablePlugins
        case accountModelProbeEnabled, accountModelProbeIntervalSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 14420
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        allowLANAccess = try container.decodeIfPresent(Bool.self, forKey: .allowLANAccess) ?? false
        routingStrategy = try container.decodeIfPresent(CLIProxyRoutingStrategy.self, forKey: .routingStrategy) ?? .roundRobin
        // 缺省与 CPA config.example.yaml 对齐：request-retry=3, max-retry-interval=30, max-retry-credentials=0
        requestRetry = try container.decodeIfPresent(Int.self, forKey: .requestRetry) ?? 3
        maxRetryInterval = try container.decodeIfPresent(Int.self, forKey: .maxRetryInterval) ?? 30
        maxRetryCredentials = try container.decodeIfPresent(Int.self, forKey: .maxRetryCredentials) ?? 0
        quotaSwitchProject = try container.decodeIfPresent(Bool.self, forKey: .quotaSwitchProject) ?? true
        quotaSwitchPreviewModel = try container.decodeIfPresent(Bool.self, forKey: .quotaSwitchPreviewModel) ?? true
        quotaAntigravityCredits = try container.decodeIfPresent(Bool.self, forKey: .quotaAntigravityCredits) ?? true
        proxyURL = try container.decodeIfPresent(String.self, forKey: .proxyURL) ?? ""
        enablePlugins = try container.decodeIfPresent(Bool.self, forKey: .enablePlugins) ?? false
        accountModelProbeEnabled = try container.decodeIfPresent(Bool.self, forKey: .accountModelProbeEnabled) ?? true
        accountModelProbeIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .accountModelProbeIntervalSeconds) ?? 60
    }

    var normalized: CLIProxyGatewaySettings {
        var value = self
        value.port = min(max(value.port, 1_024), 65_535)
        value.requestRetry = min(max(value.requestRetry, 0), 10)
        // CPA：max-retry-interval<=0 时 shouldRetryAfterError 直接放弃，429 几乎无法换号。
        value.maxRetryInterval = min(max(value.maxRetryInterval, 1), 1_800)
        value.maxRetryCredentials = min(max(value.maxRetryCredentials, 0), 64)
        // 额度/429 换号是网关应有行为，不开放成用户选项；始终强制开启。
        value.quotaSwitchProject = true
        value.quotaSwitchPreviewModel = true
        value.quotaAntigravityCredits = true
        value.accountModelProbeIntervalSeconds = min(max(value.accountModelProbeIntervalSeconds, 15), 3_600)
        value.proxyURL = value.proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    var bindHost: String { allowLANAccess ? "0.0.0.0" : "127.0.0.1" }

    /// Three-way merge for settings edited in one tab while another CPA action
    /// updates runtime settings. Fields the user changed relative to `base`
    /// remain in the draft; untouched fields follow the latest runtime value.
    func mergingExternalChange(
        from base: CLIProxyGatewaySettings,
        to external: CLIProxyGatewaySettings
    ) -> CLIProxyGatewaySettings {
        var merged = self
        if port == base.port { merged.port = external.port }
        if autoStart == base.autoStart { merged.autoStart = external.autoStart }
        if allowLANAccess == base.allowLANAccess { merged.allowLANAccess = external.allowLANAccess }
        if routingStrategy == base.routingStrategy { merged.routingStrategy = external.routingStrategy }
        if requestRetry == base.requestRetry { merged.requestRetry = external.requestRetry }
        if maxRetryInterval == base.maxRetryInterval { merged.maxRetryInterval = external.maxRetryInterval }
        if maxRetryCredentials == base.maxRetryCredentials {
            merged.maxRetryCredentials = external.maxRetryCredentials
        }
        if quotaSwitchProject == base.quotaSwitchProject {
            merged.quotaSwitchProject = external.quotaSwitchProject
        }
        if quotaSwitchPreviewModel == base.quotaSwitchPreviewModel {
            merged.quotaSwitchPreviewModel = external.quotaSwitchPreviewModel
        }
        if quotaAntigravityCredits == base.quotaAntigravityCredits {
            merged.quotaAntigravityCredits = external.quotaAntigravityCredits
        }
        if proxyURL == base.proxyURL { merged.proxyURL = external.proxyURL }
        if enablePlugins == base.enablePlugins { merged.enablePlugins = external.enablePlugins }
        if accountModelProbeEnabled == base.accountModelProbeEnabled {
            merged.accountModelProbeEnabled = external.accountModelProbeEnabled
        }
        if accountModelProbeIntervalSeconds == base.accountModelProbeIntervalSeconds {
            merged.accountModelProbeIntervalSeconds = external.accountModelProbeIntervalSeconds
        }
        return merged
    }

    /// 相对 `other`，是否改动了必须重启 CPA 进程才能生效的字段。
    func requiresCPAProcessRestart(comparedTo other: CLIProxyGatewaySettings) -> Bool {
        let a = normalized
        let b = other.normalized
        return a.port != b.port
            || a.allowLANAccess != b.allowLANAccess
            || a.routingStrategy != b.routingStrategy
            || a.requestRetry != b.requestRetry
            || a.maxRetryInterval != b.maxRetryInterval
            || a.maxRetryCredentials != b.maxRetryCredentials
            || a.quotaSwitchProject != b.quotaSwitchProject
            || a.quotaSwitchPreviewModel != b.quotaSwitchPreviewModel
            || a.quotaAntigravityCredits != b.quotaAntigravityCredits
            || a.proxyURL != b.proxyURL
            || a.enablePlugins != b.enablePlugins
        // accountModelProbe* 仅 AIUsage 侧定时任务，不需重启 CPA。
    }

}

/// AIUsage 托管的 CPA `api-keys` 命名空间前缀。
/// 配置同步时只回收这些前缀下、且不在当前启用列表中的值；其它 key 原样保留。
nonisolated enum CLIProxyManagedAPIKeyNamespace: Sendable {
    static let prefixes = ["cpa-client-", "cpa-key-"]

    /// Select only a key AIUsage can prove it owns. Arbitrary preserved keys
    /// in a shared CPA config may belong to another client and must never be
    /// copied into AIUsage-managed providers.
    static func ownedKey(in configured: [String], preferred: String?) -> String? {
        if let preferred, configured.contains(preferred) { return preferred }
        return configured.first { candidate in
            prefixes.contains(where: candidate.hasPrefix)
        }
    }
}

nonisolated struct CLIProxySecrets: Sendable, Equatable {
    let managementKey: String
    let clientAPIKey: String
}

nonisolated enum CLIProxyRuntimeState: Equatable, Sendable {
    case stopped
    case starting
    case running(pid: Int32)
    case stopping
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var isTransitioning: Bool {
        self == .starting || self == .stopping
    }
}

nonisolated struct CLIProxyRecentRequest: Codable, Equatable, Sendable {
    let time: String
    let success: Int64
    let failed: Int64

    enum CodingKeys: String, CodingKey {
        case time, success, failed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = container.lossyString(forKey: .time) ?? ""
        success = container.lossyInt64(forKey: .success) ?? 0
        failed = container.lossyInt64(forKey: .failed) ?? 0
    }
}

nonisolated struct CLIProxyAuthFile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let authIndex: String?
    let name: String
    let type: String?
    let provider: String?
    let label: String?
    let email: String?
    let status: String?
    let statusMessage: String?
    let disabled: Bool
    let unavailable: Bool
    let runtimeOnly: Bool
    let source: String?
    let path: String?
    let size: Int64?
    let modTime: Date?
    let updatedAt: Date?
    let createdAt: Date?
    let lastRefresh: Date?
    let nextRetryAfter: Date?
    let projectID: String?
    let accountType: String?
    let account: String?
    let priority: Int?
    let note: String?
    let websockets: Bool?
    let success: Int64
    let failed: Int64
    let recentRequests: [CLIProxyRecentRequest]

    enum CodingKeys: String, CodingKey {
        case id, name, type, provider, label, email, status, disabled, unavailable, source, path, size
        case priority, note, websockets, success, failed
        case authIndex = "auth_index"
        case statusMessage = "status_message"
        case runtimeOnly = "runtime_only"
        case modTime = "modtime"
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case lastRefresh = "last_refresh"
        case nextRetryAfter = "next_retry_after"
        case projectID = "project_id"
        case accountType = "account_type"
        case account
        case recentRequests = "recent_requests"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "unknown.json"
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? name
        authIndex = container.lossyString(forKey: .authIndex)
        type = container.lossyString(forKey: .type)
        provider = container.lossyString(forKey: .provider)
        label = container.lossyString(forKey: .label)
        email = container.lossyString(forKey: .email)
        status = container.lossyString(forKey: .status)
        statusMessage = container.lossyString(forKey: .statusMessage)
        disabled = container.lossyBool(forKey: .disabled) ?? false
        unavailable = container.lossyBool(forKey: .unavailable) ?? false
        runtimeOnly = container.lossyBool(forKey: .runtimeOnly) ?? false
        source = container.lossyString(forKey: .source)
        path = container.lossyString(forKey: .path)
        size = container.lossyInt64(forKey: .size)
        modTime = container.lossyDate(forKey: .modTime)
        updatedAt = container.lossyDate(forKey: .updatedAt)
        createdAt = container.lossyDate(forKey: .createdAt)
        lastRefresh = container.lossyDate(forKey: .lastRefresh)
        nextRetryAfter = container.lossyDate(forKey: .nextRetryAfter)
        projectID = container.lossyString(forKey: .projectID)
        accountType = container.lossyString(forKey: .accountType)
        account = container.lossyString(forKey: .account)
        priority = container.lossyInt(forKey: .priority)
        note = container.lossyString(forKey: .note)
        websockets = container.lossyBool(forKey: .websockets)
        success = container.lossyInt64(forKey: .success) ?? 0
        failed = container.lossyInt64(forKey: .failed) ?? 0
        recentRequests = (try? container.decodeIfPresent([CLIProxyRecentRequest].self, forKey: .recentRequests)) ?? []
    }

    init(openAICompatible provider: CLIProxyOpenAICompatibleProvider) {
        let normalizedName = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        id = "openai-compatible:\(normalizedName.lowercased())"
        authIndex = nil
        name = "openai-compatible-\(normalizedName).runtime"
        type = "openai-compatibility"
        self.provider = "openai-compatibility"
        label = normalizedName
        email = nil
        status = provider.disabled ? "disabled" : "ready"
        statusMessage = nil
        disabled = provider.disabled
        unavailable = false
        runtimeOnly = true
        source = "config"
        path = nil
        size = nil
        modTime = nil
        updatedAt = nil
        createdAt = nil
        lastRefresh = nil
        nextRetryAfter = nil
        projectID = nil
        accountType = "openai-compatible"
        account = normalizedName
        priority = provider.priority
        note = nil
        websockets = nil
        success = 0
        failed = 0
        recentRequests = []
    }

    var displayProvider: String { provider ?? type ?? "unknown" }
    /// Runtime identities (for example Gemini CLI project routes) carry the
    /// discriminating project name in `label`. Prefer it so sheets, flashes,
    /// and accessibility text do not collapse every route to the same email.
    var displayLabel: String {
        runtimeOnly ? (label ?? email ?? name) : (email ?? label ?? name)
    }
    var isOpenAICompatibleRuntime: Bool {
        let value = (provider ?? type ?? "").lowercased()
        return runtimeOnly && (value == "openai-compatibility" || value.hasPrefix("openai-compatible-"))
    }
}

/// Raw result returned by CPA's credential-scoped management request. The body
/// is inspected only to validate that the upstream returned its expected JSON;
/// it is never persisted or displayed because it can contain account details.
nonisolated struct CLIProxyUpstreamCallResult: Decodable, Sendable {
    let statusCode: Int
    let body: String

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case body
    }
}

/// A point-in-time, user-triggered upstream check. Model-catalog loading is a
/// separate concern and must never be interpreted as proof that OAuth works.
nonisolated enum CLIProxyAccountConnectivityState: Equatable, Sendable {
    case checking
    case connected(checkedAt: Date)
    case failed(code: String, message: String, checkedAt: Date)
    case unsupported(reason: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var needsAttention: Bool {
        if case .failed = self { return true }
        return false
    }
}

nonisolated struct CLIProxyAccountConnectivityResult: Equatable, Sendable {
    let state: CLIProxyAccountConnectivityState
    let detail: String
}

nonisolated struct CLIProxyModel: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String?
    let type: String?
    let ownedBy: String?

    enum CodingKeys: String, CodingKey {
        case id, type
        case displayName = "display_name"
        case ownedBy = "owned_by"
    }

    init(id: String, displayName: String? = nil, type: String? = nil, ownedBy: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.type = type
        self.ownedBy = ownedBy
    }
}

nonisolated enum CLIProxyModelProtocol: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case openAI
    case anthropic
    case gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: "OpenAI API"
        case .anthropic: "Anthropic API"
        case .gemini: "Gemini API"
        }
    }

    var sortOrder: Int {
        switch self {
        case .openAI: 0
        case .anthropic: 1
        case .gemini: 2
        }
    }
}

nonisolated struct CLIProxyModelCatalogEntry: Identifiable, Equatable, Sendable {
    let model: CLIProxyModel
    private let modelsByProtocol: [CLIProxyModelProtocol: [CLIProxyModel]]

    var id: String { model.id }
    var protocols: Set<CLIProxyModelProtocol> { Set(modelsByProtocol.keys) }
    var providerID: String { CLIProxyModelBrandResolver.providerID(for: model) }
    var routeIDs: [CLIProxyModelProtocol: [String]] {
        modelsByProtocol.mapValues { $0.map(\.id) }
    }

    init(model: CLIProxyModel, protocols: Set<CLIProxyModelProtocol>) {
        self.model = model
        self.modelsByProtocol = Dictionary(
            uniqueKeysWithValues: protocols.map { ($0, [model]) }
        )
    }

    init(
        model: CLIProxyModel,
        modelsByProtocol: [CLIProxyModelProtocol: [CLIProxyModel]]
    ) {
        self.model = model
        self.modelsByProtocol = modelsByProtocol
    }

    func models(for modelProtocol: CLIProxyModelProtocol) -> [CLIProxyModel] {
        modelsByProtocol[modelProtocol] ?? []
    }

    func routeID(for modelProtocol: CLIProxyModelProtocol) -> String? {
        models(for: modelProtocol).first?.id
    }
}

nonisolated struct CLIProxyModelCatalogSnapshot: Equatable, Sendable {
    let openAIModels: [CLIProxyModel]
    let entries: [CLIProxyModelCatalogEntry]
    let unavailableProtocols: Set<CLIProxyModelProtocol>
}

/// Converts protocol-specific route IDs into one stable model identity.
///
/// CLIProxyAPI deliberately rewrites non-Claude model IDs in its Anthropic
/// `/v1/models` response. The transformed ID is a client-facing route alias,
/// not a distinct model. Keep the exact alias on the route while using the
/// decoded value to merge the catalog.
nonisolated enum CLIProxyModelIdentity {
    static let anthropicCompatibilityPrefix = "claude-fable-5-dd-"

    static func canonicalID(
        for routeID: String,
        protocol modelProtocol: CLIProxyModelProtocol
    ) -> String {
        let trimmed = routeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard modelProtocol == .anthropic else {
            if modelProtocol == .gemini, trimmed.hasPrefix("models/") {
                return String(trimmed.dropFirst("models/".count))
            }
            return trimmed
        }

        let split = splitThinkingSuffix(trimmed)
        guard split.base.hasPrefix(anthropicCompatibilityPrefix) else { return trimmed }
        let payload = String(split.base.dropFirst(anthropicCompatibilityPrefix.count))
        guard !payload.isEmpty else { return trimmed }

        let decoded = reverseUnicodeScalars(payload)
        return split.suffix.map { "\(decoded)(\($0))" } ?? decoded
    }

    static func normalizedKey(for canonicalID: String) -> String {
        canonicalID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func splitThinkingSuffix(_ modelID: String) -> (base: String, suffix: String?) {
        guard modelID.hasSuffix(")"),
              let opening = modelID.lastIndex(of: "(") else {
            return (modelID, nil)
        }
        let suffixStart = modelID.index(after: opening)
        let suffixEnd = modelID.index(before: modelID.endIndex)
        return (String(modelID[..<opening]), String(modelID[suffixStart..<suffixEnd]))
    }

    private static func reverseUnicodeScalars(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.reversed()))
    }
}

/// Resolves a model vendor for brand presentation without consulting the API
/// format used to reach it. A compatibility route must never change the logo.
nonisolated enum CLIProxyModelBrandResolver {
    static func providerID(for model: CLIProxyModel) -> String {
        if let provider = recognizedProvider(in: model.ownedBy) { return provider }
        if let provider = recognizedProvider(in: model.id) { return provider }
        if let provider = recognizedProvider(in: model.displayName) { return provider }
        return "cliproxyapi"
    }

    private static func recognizedProvider(in value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        if normalized.contains("openai")
            || normalized.contains("chatgpt")
            || normalized.contains("gpt-")
            || normalized.hasPrefix("gpt ")
            || normalized.contains("codex")
            || normalized.hasPrefix("o1")
            || normalized.hasPrefix("o3")
            || normalized.hasPrefix("o4")
            || normalized.contains("dall-e") {
            return "openai"
        }
        if normalized.contains("anthropic") || normalized.contains("claude") {
            return "claude"
        }
        if normalized.contains("google")
            || normalized.contains("gemini")
            || normalized.contains("imagen")
            || normalized.hasPrefix("veo") {
            return "gemini"
        }
        if normalized == "xai"
            || normalized == "x.ai"
            || normalized.contains("x.ai")
            || normalized.contains("grok") {
            return "xai"
        }
        if normalized.contains("minimax") { return "minimax" }
        if normalized.contains("kimi") || normalized.contains("moonshot") { return "kimi" }
        return nil
    }
}

/// Pure catalog construction used by both the live client and offline
/// regression fixtures. `openAIModels` is intentionally returned byte-for-byte
/// equivalent at the value level because it remains the managed distribution
/// source for Responses-compatible clients.
nonisolated enum CLIProxyModelCatalogBuilder {
    private struct Accumulator {
        var model: CLIProxyModel
        var modelsByProtocol: [CLIProxyModelProtocol: [CLIProxyModel]]
    }

    static func build(
        openAIModels: [CLIProxyModel],
        anthropicModels: [CLIProxyModel]?,
        geminiModels: [CLIProxyModel]?
    ) -> CLIProxyModelCatalogSnapshot {
        var entries: [String: Accumulator] = [:]
        merge(openAIModels, protocol: .openAI, into: &entries)
        if let anthropicModels {
            merge(anthropicModels, protocol: .anthropic, into: &entries)
        }
        if let geminiModels {
            merge(geminiModels, protocol: .gemini, into: &entries)
        }

        var unavailableProtocols = Set<CLIProxyModelProtocol>()
        if anthropicModels == nil { unavailableProtocols.insert(.anthropic) }
        if geminiModels == nil { unavailableProtocols.insert(.gemini) }

        let catalogEntries = entries.values.map { accumulator in
            CLIProxyModelCatalogEntry(
                model: accumulator.model,
                modelsByProtocol: accumulator.modelsByProtocol.mapValues { models in
                    models.sorted {
                        $0.id.localizedStandardCompare($1.id) == .orderedAscending
                    }
                }
            )
        }.sorted {
            $0.model.id.localizedStandardCompare($1.model.id) == .orderedAscending
        }

        return CLIProxyModelCatalogSnapshot(
            openAIModels: openAIModels,
            entries: catalogEntries,
            unavailableProtocols: unavailableProtocols
        )
    }

    private static func merge(
        _ models: [CLIProxyModel],
        protocol modelProtocol: CLIProxyModelProtocol,
        into entries: inout [String: Accumulator]
    ) {
        for rawModel in models {
            let routeID = rawModel.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !routeID.isEmpty else { continue }

            let canonicalID = CLIProxyModelIdentity.canonicalID(
                for: routeID,
                protocol: modelProtocol
            )
            let key = CLIProxyModelIdentity.normalizedKey(for: canonicalID)
            guard !key.isEmpty else { continue }

            let canonicalModel = CLIProxyModel(
                id: canonicalID,
                displayName: rawModel.displayName,
                type: rawModel.type,
                ownedBy: rawModel.ownedBy
            )
            let routeModel = CLIProxyModel(
                id: routeID,
                displayName: rawModel.displayName,
                type: rawModel.type,
                ownedBy: rawModel.ownedBy
            )

            if var existing = entries[key] {
                existing.model = preferredModel(existing.model, canonicalModel)
                var protocolModels = existing.modelsByProtocol[modelProtocol] ?? []
                mergeRoute(routeModel, into: &protocolModels)
                existing.modelsByProtocol[modelProtocol] = protocolModels
                entries[key] = existing
            } else {
                entries[key] = Accumulator(
                    model: canonicalModel,
                    modelsByProtocol: [modelProtocol: [routeModel]]
                )
            }
        }
    }

    private static func mergeRoute(_ route: CLIProxyModel, into models: inout [CLIProxyModel]) {
        if let index = models.firstIndex(where: { $0.id == route.id }) {
            models[index] = preferredModel(models[index], route)
        } else {
            models.append(route)
        }
    }

    private static func preferredModel(_ lhs: CLIProxyModel, _ rhs: CLIProxyModel) -> CLIProxyModel {
        CLIProxyModel(
            id: lhs.id,
            displayName: nonBlank(lhs.displayName) ?? nonBlank(rhs.displayName),
            type: nonBlank(lhs.type) ?? nonBlank(rhs.type),
            ownedBy: nonBlank(lhs.ownedBy) ?? nonBlank(rhs.ownedBy)
        )
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

nonisolated struct CLIProxyPluginMetadata: Codable, Equatable, Sendable {
    let name: String?
    let version: String?
    let author: String?
    let githubRepository: String?
    let logo: String?

    enum CodingKeys: String, CodingKey {
        case name, version, author, logo
        case githubRepository = "github_repository"
    }
}

nonisolated struct CLIProxyPlugin: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let configured: Bool
    let registered: Bool
    let enabled: Bool
    let effectiveEnabled: Bool
    let supportsOAuth: Bool
    let oauthProvider: String?
    let logo: String?
    let metadata: CLIProxyPluginMetadata?

    enum CodingKeys: String, CodingKey {
        case id, configured, registered, enabled, logo, metadata
        case effectiveEnabled = "effective_enabled"
        case supportsOAuth = "supports_oauth"
        case oauthProvider = "oauth_provider"
    }

    var displayName: String {
        guard let value = metadata?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return id }
        return value
    }
    var providerID: String {
        guard let value = oauthProvider?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return id }
        return value
    }
}

nonisolated struct CLIProxyPluginStoreEntry: Codable, Identifiable, Equatable, Sendable {
    let storeID: String
    let sourceID: String
    let id: String
    let name: String
    let description: String
    let author: String
    let version: String
    let repository: String
    let logo: String?
    let homepage: String?
    let license: String?
    let tags: [String]
    let installed: Bool
    let installedVersion: String?
    let configured: Bool
    let registered: Bool
    let enabled: Bool
    let effectiveEnabled: Bool
    let updateAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, description, author, version, repository, logo, homepage, license, tags
        case installed, configured, registered, enabled
        case storeID = "store_id"
        case sourceID = "source_id"
        case installedVersion = "installed_version"
        case effectiveEnabled = "effective_enabled"
        case updateAvailable = "update_available"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        storeID = try container.decodeIfPresent(String.self, forKey: .storeID) ?? "official"
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID) ?? storeID
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        repository = try container.decodeIfPresent(String.self, forKey: .repository) ?? ""
        logo = try container.decodeIfPresent(String.self, forKey: .logo)
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        license = try container.decodeIfPresent(String.self, forKey: .license)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        installed = try container.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        installedVersion = try container.decodeIfPresent(String.self, forKey: .installedVersion)
        configured = try container.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        registered = try container.decodeIfPresent(Bool.self, forKey: .registered) ?? false
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        effectiveEnabled = try container.decodeIfPresent(Bool.self, forKey: .effectiveEnabled) ?? false
        updateAvailable = try container.decodeIfPresent(Bool.self, forKey: .updateAvailable) ?? false
    }

    var isProvider: Bool { tags.contains { $0.caseInsensitiveCompare("provider") == .orderedSame } }
}

nonisolated struct CLIProxyOpenAICompatibleProvider: Codable, Equatable, Sendable {
    struct APIKeyEntry: Codable, Equatable, Sendable {
        let apiKey: String
        let proxyURL: String?

        enum CodingKeys: String, CodingKey {
            case apiKey = "api-key"
            case proxyURL = "proxy-url"
        }
    }

    struct Model: Codable, Equatable, Sendable {
        let name: String
        let alias: String
        let forceMapping: Bool

        init(name: String, alias: String = "", forceMapping: Bool = false) {
            self.name = name
            self.alias = alias
            self.forceMapping = forceMapping
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            alias = try container.decodeIfPresent(String.self, forKey: .alias) ?? ""
            forceMapping = try container.decodeIfPresent(Bool.self, forKey: .forceMapping) ?? false
        }

        enum CodingKeys: String, CodingKey {
            case name, alias
            case forceMapping = "force-mapping"
        }
    }

    let name: String
    let priority: Int
    let disabled: Bool
    let prefix: String
    let baseURL: String
    let apiKeyEntries: [APIKeyEntry]
    let models: [Model]
    let headers: [String: String]?
    let disableCooling: Bool

    enum CodingKeys: String, CodingKey {
        case name, priority, disabled, prefix, models, headers
        case baseURL = "base-url"
        case apiKeyEntries = "api-key-entries"
        case disableCooling = "disable-cooling"
    }

    init(
        name: String,
        priority: Int = 0,
        disabled: Bool = false,
        prefix: String = "",
        baseURL: String,
        apiKeyEntries: [APIKeyEntry] = [],
        models: [Model] = [],
        headers: [String: String]? = nil,
        disableCooling: Bool = false
    ) {
        self.name = name
        self.priority = priority
        self.disabled = disabled
        self.prefix = prefix
        self.baseURL = baseURL
        self.apiKeyEntries = apiKeyEntries
        self.models = models
        self.headers = headers
        self.disableCooling = disableCooling
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        baseURL = try container.decode(String.self, forKey: .baseURL)
        apiKeyEntries = try container.decodeIfPresent([APIKeyEntry].self, forKey: .apiKeyEntries) ?? []
        models = try container.decodeIfPresent([Model].self, forKey: .models) ?? []
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
        disableCooling = try container.decodeIfPresent(Bool.self, forKey: .disableCooling) ?? false
    }
}

nonisolated enum CLIProxyOAuthProvider: String, CaseIterable, Identifiable, Sendable {
    case codex
    case anthropic
    case antigravity
    case kimi
    case xai

    var id: String { rawValue }
    var endpoint: String { self == .anthropic ? "anthropic-auth-url" : "\(rawValue)-auth-url" }

    /// CPA writes Anthropic OAuth credentials with the historical `claude` provider value.
    var authFileProviderIDs: Set<String> {
        self == .anthropic ? ["anthropic", "claude"] : [rawValue]
    }
}

nonisolated struct CLIProxyOAuthSession: Decodable, Equatable, Sendable {
    let status: String
    let url: URL
    let state: String
    let flow: String?
    let userCode: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case status, url, state, flow
        case userCode = "user_code"
        case expiresIn = "expires_in"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.lossyString(forKey: .status) ?? "ok"
        state = try container.decode(String.self, forKey: .state)
        if let decodedURL = try? container.decode(URL.self, forKey: .url) {
            url = decodedURL
        } else if let rawURL = container.lossyString(forKey: .url), let decodedURL = URL(string: rawURL) {
            url = decodedURL
        } else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: container, debugDescription: "invalid OAuth URL")
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: container, debugDescription: "unsupported OAuth URL scheme")
        }
        flow = container.lossyString(forKey: .flow)
        userCode = container.lossyString(forKey: .userCode)
        expiresIn = container.lossyInt(forKey: .expiresIn)
    }

    var isDeviceFlow: Bool { flow?.caseInsensitiveCompare("device") == .orderedSame }
}

nonisolated struct CLIProxyOAuthStatus: Decodable, Sendable {
    let status: String
    let error: String?
}

nonisolated enum CLIProxyOAuthFlowState: Equatable, Sendable {
    case idle
    case starting(CLIProxyOAuthProvider)
    case waiting(CLIProxyOAuthProvider, CLIProxyOAuthSession)
    case succeeded(CLIProxyOAuthProvider)
    case cancelled(CLIProxyOAuthProvider?)
    case failed(CLIProxyOAuthProvider?, String)
    case pluginStarting(String)
    case pluginWaiting(String, CLIProxyOAuthSession)
    case pluginSucceeded(String)
    case pluginFailed(String, String)

    var isActive: Bool {
        switch self {
        case .starting, .waiting, .pluginStarting, .pluginWaiting: true
        default: false
        }
    }
}

nonisolated struct CLIProxyAccountSyncCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let providerId: String
    let label: String
    let credentialId: String
    let accountIdentity: CLIProxyAccountIdentity?
    let compatibility: Compatibility

    init(
        id: String,
        providerId: String,
        label: String,
        credentialId: String,
        accountIdentity: CLIProxyAccountIdentity? = nil,
        compatibility: Compatibility
    ) {
        self.id = id
        self.providerId = providerId
        self.label = label
        self.credentialId = credentialId
        self.accountIdentity = accountIdentity
        self.compatibility = compatibility
    }

    /// Structured sync readiness. Candidates only exist for providers with a
    /// verified conversion adapter; other providers never appear as candidates
    /// (see `CLIProxyCapabilityMatrix`). There is deliberately no generic
    /// "unsupported, sign in with CPA" state.
    nonisolated enum Compatibility: Equatable, Sendable {
        case compatible
        /// The managed credential file is gone; fix it under Subscription Accounts.
        case credentialMissing
        /// The credential exists but cannot be converted; re-login in AIUsage.
        case credentialInvalid(String)
    }
}

/// 同步模式。产品已取消自动推送；`keepUpdated` 仅保留解码兼容，落盘一律 `manualCopy`。
nonisolated enum CLIProxyAccountSyncMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case manualCopy
    /// Legacy. Decoded from old manifests then normalized to `manualCopy`.
    case keepUpdated

    var id: String { rawValue }

    /// 写入 manifest 前的规范值：历史 keepUpdated 一律降为手动。
    var normalizedForPersistence: CLIProxyAccountSyncMode { .manualCopy }
}

nonisolated enum CLIProxyAccountSyncState: String, Codable, Equatable, Sendable {
    case notSynced
    case current
    case sourceChanged
    case cpaChanged
    case conflict
    case missing
}

/// Contains only identity metadata and one-way content fingerprints. Credential JSON is never persisted here.
nonisolated struct CLIProxyAccountSyncRecord: Codable, Identifiable, Equatable, Sendable {
    let providerId: String
    let credentialId: String
    let authFileName: String
    let accountIdentity: String?
    let sourceFingerprint: String
    let lastCopiedFingerprint: String
    /// AIUsage 源侧语义指纹（基于「即将上传的转换副本」；忽略易变 token 字段）。
    let lastSourceSemanticFingerprint: String?
    /// CPA 落盘内容的语义指纹（忽略 access_token / last_refresh 等易变字段）。
    /// 用于判定「CPA 副本是否被有意义地改过」；旧 manifest 可能缺失。
    let lastCopiedSemanticFingerprint: String?
    let lastSyncedAt: Date
    var mode: CLIProxyAccountSyncMode

    var id: String { "\(providerId):\(credentialId)" }

    init(
        providerId: String,
        credentialId: String,
        authFileName: String,
        accountIdentity: String? = nil,
        sourceFingerprint: String,
        lastCopiedFingerprint: String,
        lastSourceSemanticFingerprint: String? = nil,
        lastCopiedSemanticFingerprint: String? = nil,
        lastSyncedAt: Date,
        mode: CLIProxyAccountSyncMode
    ) {
        self.providerId = providerId
        self.credentialId = credentialId
        self.authFileName = authFileName
        self.accountIdentity = accountIdentity
        self.sourceFingerprint = sourceFingerprint
        self.lastCopiedFingerprint = lastCopiedFingerprint
        self.lastSourceSemanticFingerprint = lastSourceSemanticFingerprint
        self.lastCopiedSemanticFingerprint = lastCopiedSemanticFingerprint
        self.lastSyncedAt = lastSyncedAt
        self.mode = mode.normalizedForPersistence
    }

    enum CodingKeys: String, CodingKey {
        case providerId
        case credentialId
        case authFileName
        case accountIdentity
        case sourceFingerprint
        case lastCopiedFingerprint
        case lastSourceSemanticFingerprint
        case lastCopiedSemanticFingerprint
        case lastSyncedAt
        case mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerId = try container.decode(String.self, forKey: .providerId)
        credentialId = try container.decode(String.self, forKey: .credentialId)
        authFileName = try container.decode(String.self, forKey: .authFileName)
        accountIdentity = try container.decodeIfPresent(String.self, forKey: .accountIdentity)
        sourceFingerprint = try container.decode(String.self, forKey: .sourceFingerprint)
        lastCopiedFingerprint = try container.decode(String.self, forKey: .lastCopiedFingerprint)
        lastSourceSemanticFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .lastSourceSemanticFingerprint
        )
        lastCopiedSemanticFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .lastCopiedSemanticFingerprint
        )
        lastSyncedAt = try container.decode(Date.self, forKey: .lastSyncedAt)
        let decodedMode = try container.decode(CLIProxyAccountSyncMode.self, forKey: .mode)
        mode = decodedMode.normalizedForPersistence
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerId, forKey: .providerId)
        try container.encode(credentialId, forKey: .credentialId)
        try container.encode(authFileName, forKey: .authFileName)
        try container.encodeIfPresent(accountIdentity, forKey: .accountIdentity)
        try container.encode(sourceFingerprint, forKey: .sourceFingerprint)
        try container.encode(lastCopiedFingerprint, forKey: .lastCopiedFingerprint)
        try container.encodeIfPresent(
            lastSourceSemanticFingerprint,
            forKey: .lastSourceSemanticFingerprint
        )
        try container.encodeIfPresent(
            lastCopiedSemanticFingerprint,
            forKey: .lastCopiedSemanticFingerprint
        )
        try container.encode(lastSyncedAt, forKey: .lastSyncedAt)
        try container.encode(mode.normalizedForPersistence, forKey: .mode)
    }
}

nonisolated struct CLIProxyAccountSyncManifest: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var records: [CLIProxyAccountSyncRecord]

    static let empty = CLIProxyAccountSyncManifest(schemaVersion: 1, records: [])
}

/// Pure structural validation for decoded sync manifests. File I/O and size
/// limits stay at the caller boundary so this logic is regression-testable.
nonisolated enum CLIProxyAccountSyncManifestValidator {
    static func validate(
        _ manifest: CLIProxyAccountSyncManifest
    ) throws -> CLIProxyAccountSyncManifest {
        guard manifest.schemaVersion == 1 else {
            throw CLIProxyGatewayError.fileSystem("unsupported account sync manifest version")
        }

        var seenRecordIDs = Set<String>()
        for record in manifest.records {
            guard seenRecordIDs.insert(record.id.lowercased()).inserted,
                  isValidFingerprint(record.sourceFingerprint),
                  isValidFingerprint(record.lastCopiedFingerprint),
                  record.lastSourceSemanticFingerprint.map(isValidFingerprint) ?? true,
                  record.lastCopiedSemanticFingerprint.map(isValidFingerprint) ?? true,
                  isSafeAuthFileName(record.authFileName),
                  record.accountIdentity.map({
                      isSafeAccountIdentity($0, providerID: record.providerId)
                  }) ?? true else {
                throw CLIProxyGatewayError.fileSystem(
                    "account sync manifest contains an invalid or duplicate record; existing data was left unchanged"
                )
            }
        }
        return manifest
    }

    private static func isValidFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    private static func isSafeAuthFileName(_ value: String) -> Bool {
        !value.isEmpty && value.lowercased().hasSuffix(".json") &&
            value == URL(fileURLWithPath: value).lastPathComponent && !value.contains("\\")
    }

    private static func isSafeAccountIdentity(_ value: String, providerID: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              String(parts[0]).caseInsensitiveCompare(providerID) == .orderedSame,
              parts[0].unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
              }) else { return false }
        return isValidFingerprint(String(parts[1]))
    }
}

/// A non-secret, rotation-stable identity extracted from a CPA auth file.
///
/// The key intentionally excludes access tokens, refresh tokens, and AIUsage's
/// credential ID. It is safe to use for reconciliation only when
/// `canAutomaticallyMerge` is true.
nonisolated struct CLIProxyAccountIdentity: Equatable, Sendable {
    let key: String
    let providerID: String
    let sourceCredentialID: String?
    let canAutomaticallyMerge: Bool
    let accountID: String?
    let projectID: String?
    let userID: String?
    let email: String?
    let planType: String?

    var planDisplayName: String? {
        guard let planType else { return nil }
        switch planType.lowercased() {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro"
        // OpenAI 产品侧原 Team 已更名为 Business；JWT/CPA 仍可能下发 team。
        case "team" where providerID.lowercased() == "codex": return "Business"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu", "education": return "Education"
        default:
            return planType
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    var shortAccountID: String? { Self.shortIdentifier(accountID) }
    var shortProjectID: String? { Self.shortIdentifier(projectID) }

    static func parse(data: Data, providerHint: String? = nil) throws -> CLIProxyAccountIdentity {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CLIProxyGatewayError.invalidAuthFile("credential file is not valid JSON")
        }
        guard let root = object as? [String: Any] else {
            throw CLIProxyGatewayError.invalidAuthFile("credential file must contain a JSON object")
        }

        let hintedProvider = normalizedProviderID(providerHint)
        let embeddedProvider = normalizedProviderID(string(root["type"]) ?? string(root["provider"]))
        guard let providerID = hintedProvider ?? embeddedProvider else {
            throw CLIProxyGatewayError.unsupportedAccount("a supported OAuth provider is required")
        }
        if let hintedProvider, let embeddedProvider, hintedProvider != embeddedProvider {
            throw CLIProxyGatewayError.invalidAuthFile("provider hint does not match the credential file")
        }

        let tokens = (root["tokens"] as? [String: Any]) ?? (root["token"] as? [String: Any])
        let tokenClaims = [
            string(root["id_token"]),
            string(tokens?["id_token"]),
            string(root["access_token"]),
            string(tokens?["access_token"])
        ].compactMap { $0 }.compactMap(jwtClaims)
        let sourceCredentialID = firstString([
            root["aiusage_credential_id"],
            tokens?["aiusage_credential_id"]
        ])

        switch providerID {
        case "codex":
            let authNamespaces = tokenClaims.compactMap {
                $0["https://api.openai.com/auth"] as? [String: Any]
            }
            let account = resolveEquivalentClaims(
                [root["account_id"], tokens?["account_id"], root["chatgpt_account_id"]]
                    + tokenClaims.flatMap { claims in
                        [
                            claims["chatgpt_account_id"],
                            claims["https://api.openai.com/auth.chatgpt_account_id"],
                            claims["https://api.openai.com/auth/chatgpt_account_id"]
                        ]
                    }
                    + authNamespaces.map { $0["chatgpt_account_id"] },
                lowercased: true
            )
            let chatGPTUser = resolveEquivalentClaims(
                [root["chatgpt_user_id"]]
                    + tokenClaims.flatMap { claims in
                        [
                            claims["chatgpt_user_id"],
                            claims["https://api.openai.com/auth.chatgpt_user_id"],
                            claims["https://api.openai.com/auth/chatgpt_user_id"]
                        ]
                    }
                    + authNamespaces.map { $0["chatgpt_user_id"] },
                lowercased: true
            )
            let genericUser = resolveEquivalentClaims(
                [root["user_id"]]
                    + authNamespaces.map { $0["user_id"] }
                    + tokenClaims.map { $0["user_id"] },
                lowercased: true
            )
            let subject = resolveEquivalentClaims(
                [root["sub"]] + tokenClaims.map { $0["sub"] },
                lowercased: true
            )
            let selectedUser = chatGPTUser.value ?? genericUser.value ?? subject.value
            let selectedUserConflict = chatGPTUser.value != nil
                ? chatGPTUser.hasConflict
                : (genericUser.value != nil ? genericUser.hasConflict : subject.hasConflict)
            let plan = resolveEquivalentClaims(
                [root["plan_type"], root["chatgpt_plan_type"]]
                    + tokenClaims.flatMap { claims in
                        [
                            claims["plan_type"],
                            claims["chatgpt_plan_type"],
                            claims["https://api.openai.com/auth.chatgpt_plan_type"],
                            claims["https://api.openai.com/auth/chatgpt_plan_type"]
                        ]
                    }
                    + authNamespaces.map { $0["chatgpt_plan_type"] },
                lowercased: true
            )
            let email = resolveEquivalentClaims(
                [root["email"]] + tokenClaims.map { $0["email"] },
                lowercased: true
            )
            let isStrong = account.value != nil
                && selectedUser != nil
                && !account.hasConflict
                && !selectedUserConflict
            let material = identityMaterial(
                providerID: providerID,
                fields: [
                    ("account", account.material),
                    ("user", selectedUser)
                ]
            )
            return CLIProxyAccountIdentity(
                key: identityKey(providerID: providerID, material: material),
                providerID: providerID,
                sourceCredentialID: sourceCredentialID,
                canAutomaticallyMerge: isStrong,
                accountID: account.value,
                projectID: nil,
                userID: selectedUser,
                email: email.value,
                planType: plan.value
            )

        case "antigravity":
            let project = resolveEquivalentClaims(
                [root["project_id"], root["projectId"], tokens?["project_id"]],
                lowercased: true
            )
            let email = resolveEquivalentClaims(
                [root["email"], tokens?["email"]] + tokenClaims.map { $0["email"] },
                lowercased: true
            )
            let isStrong = project.value != nil
                && email.value != nil
                && !project.hasConflict
                && !email.hasConflict
            let material = identityMaterial(
                providerID: providerID,
                fields: [("project", project.material), ("email", email.material)]
            )
            return CLIProxyAccountIdentity(
                key: identityKey(providerID: providerID, material: material),
                providerID: providerID,
                sourceCredentialID: sourceCredentialID,
                canAutomaticallyMerge: isStrong,
                accountID: nil,
                projectID: project.value,
                userID: nil,
                email: email.value,
                planType: nil
            )

        case "gemini":
            // A Gemini login owns a set of Google Cloud projects. Projects are
            // runtime children, not separate subscription identities, so the
            // parent Google email is the stable reconciliation key.
            let email = resolveEquivalentClaims(
                [root["email"], tokens?["email"]] + tokenClaims.map { $0["email"] },
                lowercased: true
            )
            let subject = resolveEquivalentClaims(
                [root["sub"], tokens?["sub"]] + tokenClaims.map { $0["sub"] },
                lowercased: true
            )
            let isStrong = email.value?.contains("@") == true && !email.hasConflict
            let material = identityMaterial(
                providerID: providerID,
                fields: [("email", email.material)]
            )
            return CLIProxyAccountIdentity(
                key: identityKey(providerID: providerID, material: material),
                providerID: providerID,
                sourceCredentialID: sourceCredentialID,
                canAutomaticallyMerge: isStrong,
                accountID: nil,
                projectID: nil,
                userID: subject.value,
                email: email.value,
                planType: nil
            )

        default:
            throw CLIProxyGatewayError.unsupportedAccount("stable identity is not available for \(providerID)")
        }
    }

    private struct ResolvedClaim {
        let value: String?
        let values: [String]

        var hasConflict: Bool { values.count > 1 }
        var material: String? { values.isEmpty ? nil : values.joined(separator: ",") }
    }

    private static func resolveEquivalentClaims(
        _ candidates: [Any?],
        lowercased: Bool
    ) -> ResolvedClaim {
        var values: [String] = []
        for candidate in candidates {
            guard var value = string(candidate)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            if lowercased { value = value.lowercased() }
            if !values.contains(value) { values.append(value) }
        }
        return ResolvedClaim(value: values.first, values: values)
    }

    private static func firstString(_ candidates: [Any?]) -> String? {
        for candidate in candidates {
            if let value = string(candidate)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty { return value }
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            return value.stringValue
        }
        return nil
    }

    private static func normalizedProviderID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        switch value {
        case "codex", "chatgpt", "openai": return "codex"
        case "antigravity", "google-antigravity": return "antigravity"
        case "gemini", "gemini-cli": return "gemini"
        default: return value
        }
    }

    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - payload.count % 4) % 4
        payload += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data),
              let claims = object as? [String: Any] else { return nil }
        return claims
    }

    private static func identityMaterial(
        providerID: String,
        fields: [(String, String?)]
    ) -> String {
        (["schema=1", "provider=\(providerID)"] + fields.compactMap { name, value in
            value.map { "\(name)=\($0)" }
        }).joined(separator: "\u{1F}")
    }

    private static func identityKey(providerID: String, material: String) -> String {
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(providerID):\(digest)"
    }

    private static func shortIdentifier(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.count > 14 else { return value }
        return "\(value.prefix(7))…\(value.suffix(5))"
    }
}

/// Computes a non-secret proof that two managed auth files have the same
/// refresh credential and the same persistent CPA behavior.
nonisolated enum CLIProxyManagedAuthSafety {
    /// 同步状态用：只比身份与持久字段，忽略 access/refresh token 轮换。
    /// 用于「源已更新 / 副本已改」判定，避免 OAuth 刷新造成假告警。
    static func syncStabilityFingerprint(for data: Data) throws -> String? {
        let root = try jsonObject(from: data)
        guard let sanitizedRoot = sanitize(root) as? [String: Any] else { return nil }
        var material: [String: Any] = [
            "schema": 2,
            "persistent_auth": sanitizedRoot
        ]
        if let identity = try? CLIProxyAccountIdentity.parse(data: data),
           let planType = identity.planType {
            material["codex_plan_type"] = planType
        }
        return try hashMaterial(material)
    }

    /// 合并安全用：在持久字段之外绑定唯一 refresh_token，证明「同一登录会话」。
    static func destructiveMergeFingerprint(for data: Data) throws -> String? {
        let root = try jsonObject(from: data)

        var refreshTokens: [String] = []
        collectRefreshTokens(in: root, into: &refreshTokens)
        let uniqueRefreshTokens = refreshTokens.reduce(into: [String]()) { result, token in
            if !result.contains(token) { result.append(token) }
        }
        guard uniqueRefreshTokens.count == 1, let refreshToken = uniqueRefreshTokens.first else {
            return nil
        }

        let refreshDigest = SHA256.hash(data: Data(refreshToken.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        guard let sanitizedRoot = sanitize(root) as? [String: Any] else { return nil }
        var material: [String: Any] = [
            "schema": 1,
            "refresh_token_sha256": refreshDigest,
            "persistent_auth": sanitizedRoot
        ]
        if let identity = try? CLIProxyAccountIdentity.parse(data: data),
           let planType = identity.planType {
            material["codex_plan_type"] = planType
        }
        return try hashMaterial(material)
    }

    private static func jsonObject(from data: Data) throws -> [String: Any] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CLIProxyGatewayError.invalidAuthFile("credential file is not valid JSON")
        }
        guard let root = object as? [String: Any] else {
            throw CLIProxyGatewayError.invalidAuthFile("credential file must contain a JSON object")
        }
        return root
    }

    private static func hashMaterial(_ material: [String: Any]) throws -> String? {
        guard JSONSerialization.isValidJSONObject(material) else { return nil }
        let canonical = try JSONSerialization.data(withJSONObject: material, options: [.sortedKeys])
        return SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func collectRefreshTokens(in value: Any, into result: inout [String]) {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if compactKey(key) == "refreshtoken" {
                    if let token = child as? String, !token.isEmpty { result.append(token) }
                } else {
                    collectRefreshTokens(in: child, into: &result)
                }
            }
        } else if let array = value as? [Any] {
            for child in array { collectRefreshTokens(in: child, into: &result) }
        }
    }

    private static func sanitize(_ value: Any) -> Any? {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, child) in dictionary where !isExcludedKey(key) {
                if shouldNormalizeIdentityValue(key), let string = child as? String {
                    result[key] = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                } else if let sanitized = sanitize(child) {
                    result[key] = sanitized
                }
            }
            return result
        }
        if let array = value as? [Any] {
            return array.compactMap(sanitize)
        }
        if value is String || value is NSNumber || value is NSNull { return value }
        return nil
    }

    private static func isExcludedKey(_ key: String) -> Bool {
        let normalized = compactKey(key)
        if normalized == "refreshtoken"
            || normalized == "accesstoken"
            || normalized == "idtoken"
            || normalized == "aiusagecredentialid" {
            return true
        }
        if normalized.contains("expire")
            || normalized.contains("expiry")
            || normalized.contains("timestamp") {
            return true
        }
        return [
            "lastrefresh",
            "lastrefreshed",
            "lastupdated",
            "updatedat",
            "createdat",
            "modtime",
            "nextretryafter",
            "success",
            "failed",
            "recentrequests",
            "status",
            "statusmessage",
            "unavailable",
            // 启停是运行时控制位，不算「凭据被改过」。
            "disabled"
        ].contains(normalized)
    }

    private static func shouldNormalizeIdentityValue(_ key: String) -> Bool {
        [
            "type",
            "provider",
            "email",
            "accountid",
            "chatgptaccountid",
            "projectid",
            "userid",
            "chatgptuserid",
            "sub",
            "plantype",
            "chatgptplantype"
        ].contains(compactKey(key))
    }

    private static func compactKey(_ key: String) -> String {
        key.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}

nonisolated struct CLIProxyManagedAuthCopy: Equatable, Sendable {
    let fileName: String
    let identity: CLIProxyAccountIdentity
    let modifiedAt: Date?
    let isManifestTracked: Bool
    let destructiveMergeFingerprint: String?

    var hasStrongOwnership: Bool {
        if isManifestTracked { return true }
        guard let credentialID = identity.sourceCredentialID else { return false }
        let safeCredentialID = credentialID.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .prefix(24)
        guard !safeCredentialID.isEmpty else { return false }
        let legacyName = "aiusage-\(identity.providerID)-\(String(safeCredentialID)).json"
        let digest = identity.key.split(separator: ":").last.map(String.init) ?? ""
        let identityName = "aiusage-\(identity.providerID)-\(digest.prefix(24)).json"
        return fileName.caseInsensitiveCompare(legacyName) == .orderedSame
            || fileName.caseInsensitiveCompare(identityName) == .orderedSame
    }
}

nonisolated struct CLIProxyManagedAuthDeduplicationPlan: Equatable, Sendable {
    let canonicalFileByIdentity: [String: String]
    let duplicateFileNames: [String]
    let conflictingIdentityKeys: [String]
}

/// Produces a deletion plan without touching disk or the CPA Management API.
nonisolated enum CLIProxyManagedAuthDeduplicator {
    static func plan(for copies: [CLIProxyManagedAuthCopy]) -> CLIProxyManagedAuthDeduplicationPlan {
        let managedStrongCopies = copies.filter {
            $0.identity.canAutomaticallyMerge
                && $0.hasStrongOwnership
        }
        let grouped = Dictionary(grouping: managedStrongCopies, by: { $0.identity.key })
        var canonicalFileByIdentity: [String: String] = [:]
        var duplicateFileNames = Set<String>()
        var conflictingIdentityKeys: [String] = []

        for identityKey in grouped.keys.sorted() {
            guard let candidates = grouped[identityKey] else { continue }
            let ordered = candidates.sorted(by: isPreferredCanonical)
            guard let canonical = ordered.first else { continue }
            let fingerprints = Set(ordered.compactMap(\.destructiveMergeFingerprint))
            guard fingerprints.count == 1,
                  ordered.allSatisfy({ $0.destructiveMergeFingerprint != nil }) else {
                if ordered.count > 1 { conflictingIdentityKeys.append(identityKey) }
                continue
            }
            canonicalFileByIdentity[identityKey] = canonical.fileName
            guard ordered.count > 1 else { continue }
            for duplicate in ordered.dropFirst() where duplicate.fileName != canonical.fileName {
                duplicateFileNames.insert(duplicate.fileName)
            }
        }

        return CLIProxyManagedAuthDeduplicationPlan(
            canonicalFileByIdentity: canonicalFileByIdentity,
            duplicateFileNames: duplicateFileNames.sorted(by: stableFileNameOrder),
            conflictingIdentityKeys: conflictingIdentityKeys
        )
    }

    private static func isPreferredCanonical(
        _ lhs: CLIProxyManagedAuthCopy,
        _ rhs: CLIProxyManagedAuthCopy
    ) -> Bool {
        let lhsDate = lhs.modifiedAt ?? .distantPast
        let rhsDate = rhs.modifiedAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        if lhs.isManifestTracked != rhs.isManifestTracked { return lhs.isManifestTracked }
        return stableFileNameOrder(lhs.fileName, rhs.fileName)
    }

    private static func stableFileNameOrder(_ lhs: String, _ rhs: String) -> Bool {
        let normalizedLeft = lhs.lowercased()
        let normalizedRight = rhs.lowercased()
        if normalizedLeft != normalizedRight { return normalizedLeft < normalizedRight }
        return lhs < rhs
    }
}

/// Canonicalizes JSON before hashing so formatting and object-key order do not look like credential changes.
nonisolated enum CLIProxyJSONFingerprint {
    static func canonicalData(_ data: Data, requireObject: Bool = false) throws -> Data {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CLIProxyGatewayError.invalidResponse("auth file is not valid JSON")
        }
        if requireObject, !(object is [String: Any]) {
            throw CLIProxyGatewayError.invalidResponse("auth file must contain a JSON object")
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CLIProxyGatewayError.invalidResponse("auth file contains unsupported JSON values")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func hash(_ data: Data, requireObject: Bool = false) throws -> String {
        let digest = SHA256.hash(data: try canonicalData(data, requireObject: requireObject))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum CLIProxyVersion {
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("v")
    }

    static func isSafePathComponent(_ value: String) -> Bool {
        let normalized = normalized(value)
        guard !normalized.isEmpty, normalized.count <= 64 else { return false }
        return normalized.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789.-_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ").contains($0)
        } && normalized != "." && normalized != ".."
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(lhs)
        let right = components(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue < rightValue { return .orderedAscending }
            if leftValue > rightValue { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func components(_ value: String) -> [Int] {
        normalized(value)
            .split(whereSeparator: { !$0.isNumber })
            .map { Int($0) ?? 0 }
    }
}

nonisolated enum CLIProxyGatewayError: LocalizedError {
    case invalidRelease(String)
    case incompatibleAsset
    case missingDigest
    case network(String)
    case invalidHTTPStatus(Int)
    case githubRateLimited(resetAt: Date?)
    case checksumMismatch(expected: String, actual: String)
    case unsafeArchive(String)
    case extractionFailed(String)
    case signingFailed(String)
    case incompatibleBinary(String)
    case dryRunFailed(String)
    case versionNotInstalled(String)
    case cannotDeleteCurrentVersion
    case fileSystem(String)
    case notInstalled
    case alreadyRunning
    case invalidPort(Int)
    case portInUse(Int, String)
    case secretStorage(String)
    case configuration(String)
    case process(String)
    case managementAPI(Int, String)
    case invalidResponse(String)
    case unsupportedAccount(String)
    case invalidAuthFile(String)
    case authFileTooLarge(maxBytes: Int)
    case authFileConflict(String)
    case syncConflict(String)

    var errorDescription: String? {
        switch self {
        case .invalidRelease(let reason): "Invalid CLIProxyAPI release: \(reason)"
        case .incompatibleAsset: "No full CLIProxyAPI macOS asset matches this Mac."
        case .missingDigest: "The selected release asset does not include a valid SHA-256 digest."
        case .network(let reason): "CLIProxyAPI update request failed: \(reason)"
        case .invalidHTTPStatus(let status): "CLIProxyAPI update server returned HTTP \(status)."
        case .githubRateLimited: "GitHub API rate limit reached. Unauthenticated clients get about 60 requests per hour; try again later."
        case .checksumMismatch(let expected, let actual):
            "CLIProxyAPI checksum mismatch (expected \(expected), got \(actual))."
        case .unsafeArchive(let reason): "Unsafe CLIProxyAPI archive: \(reason)"
        case .extractionFailed(let reason): "Could not extract CLIProxyAPI: \(reason)"
        case .signingFailed(let reason): "Could not sign CLIProxyAPI: \(reason)"
        case .incompatibleBinary(let reason): "Incompatible CLIProxyAPI binary: \(reason)"
        case .dryRunFailed(let reason): "CLIProxyAPI dry run failed: \(reason)"
        case .versionNotInstalled(let version): "CLIProxyAPI \(version) is not installed."
        case .cannotDeleteCurrentVersion: "The active CLIProxyAPI version cannot be deleted."
        case .fileSystem(let reason): "CLIProxyAPI storage error: \(reason)"
        case .notInstalled: "CLIProxyAPI is not installed."
        case .alreadyRunning: "CLIProxyAPI is already running."
        case .invalidPort(let port): "CLIProxyAPI port \(port) is invalid."
        case .portInUse(let port, let owner): "CLIProxyAPI port \(port) is already used by \(owner)."
        case .secretStorage(let reason): "CLIProxyAPI secret storage failed: \(reason)"
        case .configuration(let reason): "CLIProxyAPI configuration failed: \(reason)"
        case .process(let reason): "CLIProxyAPI process failed: \(reason)"
        case .managementAPI(_, let reason):
            reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown error" : reason
        case .invalidResponse(let reason): "CLIProxyAPI returned an invalid response: \(reason)"
        case .unsupportedAccount(let reason): "This account cannot be synchronized to CLIProxyAPI: \(reason)"
        case .invalidAuthFile(let reason): "Invalid CLIProxyAPI auth file: \(reason)"
        case .authFileTooLarge(let maxBytes): "The auth file exceeds the \(maxBytes / 1_048_576) MB import limit."
        case .authFileConflict(let name): "An auth file named \(name) already exists in CLIProxyAPI."
        case .syncConflict(let reason): "The AIUsage and CLIProxyAPI copies both changed: \(reason)"
        }
    }
}

nonisolated private extension KeyedDecodingContainer {
    func lossyString(forKey key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Int64.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        return nil
    }

    func lossyInt(forKey key: Key) -> Int? {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = lossyString(forKey: key) { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    func lossyInt64(forKey key: Key) -> Int64? {
        if let value = try? decode(Int64.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key) { return Int64(value) }
        if let value = lossyString(forKey: key) { return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    func lossyBool(forKey key: Key) -> Bool? {
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = lossyInt(forKey: key) { return value != 0 }
        guard let value = lossyString(forKey: key)?.lowercased() else { return nil }
        switch value {
        case "true", "yes", "on": return true
        case "false", "no", "off": return false
        default: return nil
        }
    }

    func lossyDate(forKey key: Key) -> Date? {
        if let seconds = try? decode(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let value = lossyString(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

nonisolated private extension String {
    func trimmingPrefix(_ prefix: Character) -> String {
        first == prefix ? String(dropFirst()) : self
    }
}
