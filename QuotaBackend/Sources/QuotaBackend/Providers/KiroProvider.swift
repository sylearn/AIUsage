import Foundation

// MARK: - Kiro Provider
// Reads Kiro IDE local auth or imported auth files,
// 必要时刷新 token，再调用 Kiro/AWS usage endpoint 获取用量。

public struct KiroProvider: MultiAccountProviderFetcher, CredentialAcceptingProvider {
    public let id = "kiro"
    public let displayName = "Kiro"
    public let description = "Kiro app quota usage"

    let homeDirectory: String
    let timeoutSeconds: Double

    static let defaultRegion = "us-east-1"
    static let refreshBufferSeconds: TimeInterval = 5 * 60
    static let kiroVersion = "0.10.32"

    public var supportedAuthMethods: [AuthMethod] { [.authFile, .auto] }

    public init(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
                timeoutSeconds: Double = 20) {
        self.homeDirectory = homeDirectory
        self.timeoutSeconds = timeoutSeconds
    }

    /// Default single-account fetch (picks latest auth file)
    public func fetchUsage() async throws -> ProviderUsage {
        let authContext = try resolveAuthContext()
        return try await fetchForAuthContext(authContext)
    }

    public func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage {
        guard credential.authMethod == .authFile else {
            throw ProviderError("unsupported_auth_method", "Kiro currently supports auth file imports only.")
        }

        let authContext = try resolveCredentialAuthContext(credential)
        var usage = try await fetchForAuthContext(authContext)
        usage.usageAccountId = stableAccountId(usage: usage, context: authContext)
        if usage.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            usage.accountEmail = credential.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return usage
    }

    /// Multi-account: fetch ALL auth files in parallel
    public func fetchAllAccounts() async -> [AccountFetchResult] {
        let allContexts: [AuthContext]
        do {
            allContexts = try resolveAllAuthContexts()
        } catch {
            return [AccountFetchResult(accountId: "default", accountLabel: nil, result: .failure(error))]
        }

        guard !allContexts.isEmpty else {
            return [AccountFetchResult(
                accountId: "default",
                accountLabel: nil,
                result: .failure(ProviderError("not_logged_in", "No Kiro auth files found."))
            )]
        }

        if allContexts.count == 1 {
            let ctx = allContexts[0]
            let filePath = ctx.url.path
            do {
                let usage = try await fetchForAuthContext(ctx)
                let accountId = stableAccountId(usage: usage, context: ctx)
                return [AccountFetchResult(accountId: accountId, accountLabel: usage.accountEmail ?? ctx.tokenData.email, result: .success(usage), sourceFilePath: filePath)]
            } catch {
                let accountId = fallbackAccountId(for: ctx)
                return [AccountFetchResult(accountId: accountId, accountLabel: ctx.tokenData.email, result: .failure(error), sourceFilePath: filePath)]
            }
        }

        return await withTaskGroup(of: AccountFetchResult.self) { group in
            for ctx in allContexts {
                group.addTask {
                    let filePath = ctx.url.path
                    do {
                        let usage = try await fetchForAuthContext(ctx)
                        let accountId = stableAccountId(usage: usage, context: ctx)
                        return AccountFetchResult(accountId: accountId, accountLabel: usage.accountEmail ?? ctx.tokenData.email, result: .success(usage), sourceFilePath: filePath)
                    } catch {
                        let accountId = fallbackAccountId(for: ctx)
                        return AccountFetchResult(accountId: accountId, accountLabel: ctx.tokenData.email, result: .failure(error), sourceFilePath: filePath)
                    }
                }
            }
            var results: [AccountFetchResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    /// Core fetch logic for a single auth context
    private func fetchForAuthContext(_ authContext: AuthContext) async throws -> ProviderUsage {
        var auth = authContext.tokenData
        let originalData = authContext.rawData

        if needsRefresh(auth.expiresAt), let refreshed = try? await refreshToken(tokenData: auth, authContext: authContext, originalData: originalData) {
            auth.accessToken = refreshed.accessToken
            if let refreshToken = refreshed.refreshToken {
                auth.refreshToken = refreshToken
            }
            auth.expiresAt = iso8601String(refreshed.expiryDate)
        }

        let response = try await fetchUsageResponse(tokenData: auth, authContext: authContext, allowRetry: true)
        return buildUsage(authContext: authContext, tokenData: auth, response: response)
    }

    // MARK: - Internal Types

    struct AuthContext {
        let url: URL
        let tokenData: KiroTokenData
        let rawData: Data
        let fileCount: Int
        let sourceDirectory: String
        let sourceType: String
    }

    struct KiroTokenData {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: String?
        var clientId: String?
        var clientSecret: String?
        var authMethod: String
        var region: String
        var profileArn: String?
        var authProvider: String?
        var email: String?
    }

    struct RefreshedToken {
        let accessToken: String
        let refreshToken: String?
        let expiryDate: Date
    }

    struct KiroTokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        let tokenType: String?
        let refreshToken: String?
    }

    struct KiroUsageResponse: Decodable {
        let usageBreakdownList: [KiroUsageBreakdown]?
        let subscriptionInfo: KiroSubscriptionInfo?
        let userInfo: KiroUserInfo?
        let nextDateReset: Double?

        struct KiroUsageBreakdown: Decodable {
            let displayName: String?
            let resourceType: String?
            let currentUsage: Double?
            let currentUsageWithPrecision: Double?
            let usageLimit: Double?
            let usageLimitWithPrecision: Double?
            let nextDateReset: Double?
            let freeTrialInfo: KiroFreeTrialInfo?
        }

        struct KiroFreeTrialInfo: Decodable {
            let currentUsage: Double?
            let currentUsageWithPrecision: Double?
            let usageLimit: Double?
            let usageLimitWithPrecision: Double?
            let freeTrialStatus: String?
            let freeTrialExpiry: Double?
        }

        struct KiroSubscriptionInfo: Decodable {
            let subscriptionTitle: String?
            let type: String?
        }

        struct KiroUserInfo: Decodable {
            let email: String?
            let userId: String?
        }
    }

    struct UsageEntry {
        let label: String
        let remainingPercent: Double
        let resetAt: Date?
    }

    // MARK: - Fetch Usage

    private func fetchUsageResponse(tokenData: KiroTokenData,
                                    authContext: AuthContext,
                                    allowRetry: Bool) async throws -> KiroUsageResponse {
        let result = try await fetchUsageOnce(tokenData: tokenData)
        if result.statusCode == 200, let response = result.response {
            return response
        }

        if allowRetry, (result.statusCode == 401 || result.statusCode == 403) {
            guard let refreshed = try? await refreshToken(tokenData: tokenData, authContext: authContext, originalData: authContext.rawData) else {
                throw ProviderError("unauthorized", "Kiro OAuth token is invalid or expired.")
            }
            var retryToken = tokenData
            retryToken.accessToken = refreshed.accessToken
            if let refreshToken = refreshed.refreshToken {
                retryToken.refreshToken = refreshToken
            }
            retryToken.expiresAt = iso8601String(refreshed.expiryDate)

            let retryResult = try await fetchUsageOnce(tokenData: retryToken)
            if retryResult.statusCode == 200, let response = retryResult.response {
                return response
            }
        }

        switch result.statusCode {
        case 401, 403:
            throw ProviderError("unauthorized", "Kiro OAuth token is invalid or expired.")
        case 0:
            throw ProviderError("network_error", "Failed to reach the Kiro usage endpoint.")
        default:
            throw ProviderError("api_error", "Kiro usage API returned HTTP \(result.statusCode).")
        }
    }

    private struct UsageAPIResult {
        let statusCode: Int
        let response: KiroUsageResponse?
    }

    private func fetchUsageOnce(tokenData: KiroTokenData) async throws -> UsageAPIResult {
        guard var components = URLComponents(string: usageEndpoint(region: tokenData.region)) else {
            throw ProviderError("invalid_url", "Failed to build the Kiro usage URL.")
        }

        var queryItems = [
            URLQueryItem(name: "origin", value: "AI_EDITOR"),
            URLQueryItem(name: "resourceType", value: "AGENTIC_REQUEST")
        ]
        if let profileArn = tokenData.profileArn, !profileArn.isEmpty {
            queryItems.append(URLQueryItem(name: "profileArn", value: profileArn))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw ProviderError("invalid_url", "Failed to build the Kiro usage URL.")
        }

        var request = QuotaHTTP.request(url: url, timeout: timeoutSeconds)
        request.httpMethod = "GET"
        request.setValue("Bearer \(tokenData.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("q.\(tokenData.region).amazonaws.com", forHTTPHeaderField: "Host")
        request.setValue(kiroUserAgent(for: tokenData), forHTTPHeaderField: "User-Agent")
        request.setValue(kiroAmzUserAgent(for: tokenData), forHTTPHeaderField: "x-amz-user-agent")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "amz-sdk-invocation-id")
        request.setValue("attempt=1; max=1", forHTTPHeaderField: "amz-sdk-request")

        let (data, response) = try await QuotaHTTP.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return UsageAPIResult(statusCode: 0, response: nil)
        }
        guard http.statusCode == 200 else {
            return UsageAPIResult(statusCode: http.statusCode, response: nil)
        }

        guard let decoded = try? JSONDecoder().decode(KiroUsageResponse.self, from: data) else {
            throw ProviderError("parse_failed", "Kiro usage API returned invalid JSON.")
        }

        return UsageAPIResult(statusCode: 200, response: decoded)
    }
}
