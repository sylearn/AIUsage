import Foundation

// MARK: - Provider Protocol

public protocol ProviderFetcher: Sendable {
    var id: String { get }
    var displayName: String { get }
    var description: String { get }
    func fetchUsage() async throws -> ProviderUsage
}

/// Providers that can fetch usage for multiple accounts in parallel
public protocol MultiAccountProviderFetcher: ProviderFetcher {
    func fetchAllAccounts() async -> [AccountFetchResult]
}

/// Providers that accept externally injected credentials
public protocol CredentialAcceptingProvider: ProviderFetcher {
    var supportedAuthMethods: [AuthMethod] { get }
    func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage
}

// MARK: - Account Credential

public enum AuthMethod: String, Codable, Sendable {
    case cookie
    case token
    case authFile
    case apiKey
    case oauth
    case webSession
    case auto
}

public struct AccountCredential: Codable, Sendable, Identifiable {
    public let id: String
    public let providerId: String
    public let accountLabel: String?
    public let authMethod: AuthMethod
    public let credential: String
    public let createdAt: String
    public var lastUsedAt: String?
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        providerId: String,
        accountLabel: String? = nil,
        authMethod: AuthMethod,
        credential: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.providerId = providerId
        self.accountLabel = accountLabel
        self.authMethod = authMethod
        self.credential = credential
        self.createdAt = SharedFormatters.iso8601String(from: Date())
        self.lastUsedAt = nil
        self.metadata = metadata
    }
}

// MARK: - Account Fetch Result

public struct AccountFetchResult: Sendable {
    public let accountId: String
    public let accountLabel: String?
    public let result: Result<ProviderUsage, Error>
    public let sourceFilePath: String?
    public let workspaceUserId: String?

    public init(accountId: String, accountLabel: String?, result: Result<ProviderUsage, Error>, sourceFilePath: String? = nil, workspaceUserId: String? = nil) {
        self.accountId = accountId
        self.accountLabel = accountLabel
        self.result = result
        self.sourceFilePath = sourceFilePath
        self.workspaceUserId = workspaceUserId
    }
}

// MARK: - Provider Error

public struct ProviderError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { "[\(code)] \(message)" }
}

// MARK: - Source Info

public struct SourceInfo: Codable, Sendable {
    public let mode: String
    public let type: String
    public var browserName: String?
    public var profile: String?
    public var defaultsDomain: String?
    public var roots: [String]?
    public var envVar: String?

    public init(mode: String, type: String) {
        self.mode = mode
        self.type = type
    }
}

// MARK: - Quota Window (raw from provider)

public struct RawQuotaWindow: Codable, Sendable {
    public var usedPercent: Double?
    public var remainingPercent: Double?
    public var resetAt: String?
    public var resetDescription: String?
    public var entitlement: Int?
    public var remaining: Int?
    public var unlimited: Bool?
    public var label: String?

    public init() {}
}

// MARK: - Provider Usage (raw data from each provider)

public struct ProviderUsage: Codable, Sendable {
    public let provider: String
    public let label: String
    public var usageAccountId: String?
    public var fetchedAt: String
    public var source: SourceInfo?

    public var accountEmail: String?
    public var accountName: String?
    public var accountLogin: String?
    public var accountPlan: String?

    public var primary: RawQuotaWindow?
    public var secondary: RawQuotaWindow?
    public var tertiary: RawQuotaWindow?

    public var extra: [String: AnyCodable]

    private enum CodingKeys: String, CodingKey {
        case provider, label
        case usageAccountId = "accountId"
        case fetchedAt, source
        case accountEmail, accountName, accountLogin, accountPlan
        case primary, secondary, tertiary, extra
    }

    public init(provider: String, label: String, accountId: String? = nil, extra: [String: AnyCodable] = [:]) {
        self.provider = provider
        self.label = label
        self.usageAccountId = accountId
        self.fetchedAt = SharedFormatters.iso8601String(from: Date())
        self.extra = extra
    }
}

// MARK: - Provider Result (after normalization)

public struct ProviderResult: Codable, Sendable {
    public let id: String
    public let providerId: String
    public let resultAccountId: String?
    public let ok: Bool
    public var usage: ProviderUsage?
    public var summary: ProviderSummary?
    public var error: String?

    private enum CodingKeys: String, CodingKey {
        case id, providerId
        case resultAccountId = "accountId"
        case ok, usage, summary, error
    }

    public init(id: String, providerId: String? = nil, accountId: String? = nil, ok: Bool, usage: ProviderUsage? = nil, summary: ProviderSummary? = nil, error: String? = nil) {
        self.id = id
        self.providerId = providerId ?? id
        self.resultAccountId = accountId
        self.ok = ok
        self.usage = usage
        self.summary = summary
        self.error = error
    }
}

// MARK: - AnyCodable helper

/// JSON-value wrapper that only holds immutable primitives (Bool, Int, Double,
/// String) and nested AnyCodable arrays/dicts — all value types. Swift cannot
/// statically prove `Any` is Sendable, so `@unchecked` is required. The init
/// path guarantees only Codable-safe values enter; mutation after init is
/// impossible (`let value`).
public struct AnyCodable: Codable, @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    /// Recursively unwraps nested `AnyCodable` into plain Foundation types
    /// that `JSONSerialization` can handle.
    public var foundationValue: Any {
        switch value {
        case let dict as [String: AnyCodable]:
            return dict.mapValues(\.foundationValue)
        case let array as [AnyCodable]:
            return array.map(\.foundationValue)
        default:
            return value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { value = v }
        else if let v = try? container.decode(Int.self) { value = v }
        else if let v = try? container.decode(Double.self) { value = v }
        else if let v = try? container.decode(String.self) { value = v }
        else if let v = try? container.decode([String: AnyCodable].self) { value = v }
        else if let v = try? container.decode([AnyCodable].self) { value = v }
        else { value = NSNull() }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as String: try container.encode(v)
        case let v as [String: AnyCodable]: try container.encode(v)
        case let v as [AnyCodable]: try container.encode(v)
        default: try container.encodeNil()
        }
    }
}
