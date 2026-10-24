import Foundation

/// 一个用户在一个工作区中的订阅身份。名称、套餐和导入路径都不是原生身份。
public struct CodexAccountIdentity: Equatable, Sendable {
    public let accountId: String?
    public let userId: String?
    public let email: String?

    public init(accountId: String?, userId: String?, email: String? = nil) {
        self.accountId = Self.normalized(accountId)
        self.userId = Self.normalized(userId)
        let email = Self.normalized(email)
        self.email = email?.contains("@") == true ? email : nil
    }

    public init(credential: AccountCredential) {
        self.init(
            accountId: credential.metadata["accountId"],
            userId: Self.normalized(credential.metadata["workspaceUserId"]) ?? credential.metadata["userId"],
            email: Self.normalized(credential.metadata["accountEmail"])
                ?? Self.normalized(credential.metadata["accountHandle"]) ?? credential.accountLabel
        )
    }

    /// 同时支持 Codex 原生 auth.json 和 CPA 扁平文件；先取当前生效 token 组的用户原生 ID，最后才取 sub。
    public init(authJSON json: [String: Any]) {
        let tokens = json["tokens"] as? [String: Any] ?? [:]
        let flatAccess = (json["access_token"] ?? json["accessToken"]) as? String
        let nestedAccess = (tokens["access_token"] ?? tokens["accessToken"]) as? String
        let flatId = (json["id_token"] ?? json["idToken"]) as? String
        let nestedId = (tokens["id_token"] ?? tokens["idToken"]) as? String

        let hasFlatTokens = flatAccess != nil || flatId != nil
        let hasNestedTokens = nestedAccess != nil || nestedId != nil
        let preferFlat: Bool
        if hasFlatTokens && hasNestedTokens {
            preferFlat = Self.tokenIssuedAt(flatAccess) >= Self.tokenIssuedAt(nestedAccess)
        } else {
            preferFlat = hasFlatTokens
        }

        let rawIdToken = preferFlat ? (flatId ?? (hasFlatTokens ? nil : nestedId)) : (nestedId ?? (hasNestedTokens ? nil : flatId))
        let activeAccessToken = preferFlat ? (flatAccess ?? (hasFlatTokens ? nil : nestedAccess)) : (nestedAccess ?? (hasNestedTokens ? nil : flatAccess))
        let accessIdentity = Self.tokenIdentity(activeAccessToken)
        let idTokenIdentity = Self.tokenIdentity(rawIdToken)
        let internalConflict = activeAccessToken != nil && rawIdToken != nil && accessIdentity.conflicts(with: idTokenIdentity)
        if internalConflict {
            self.init(accountId: nil, userId: nil, email: nil)
            return
        }
        let activeIdToken = rawIdToken

        let claims = [activeIdToken, activeAccessToken].compactMap { Self.jwtPayload($0) }
        let auth = claims.compactMap { $0["https://api.openai.com/auth"] as? [String: Any] }
        func first(_ values: [Any?]) -> String? {
            values.lazy.compactMap { Self.normalized($0 as? String) }.first
        }
        let accountCandidates: [Any?] = preferFlat
            ? [json["account_id"], json["accountId"], json["chatgpt_account_id"], tokens["account_id"], tokens["accountId"]]
            : [tokens["account_id"], tokens["accountId"], json["account_id"], json["accountId"], json["chatgpt_account_id"]]
        let accountId = first(auth.map { $0["chatgpt_account_id"] } + claims.map { $0["chatgpt_account_id"] } + accountCandidates)
        let rootUserCandidates: [Any?] = internalConflict ? [] : [json["chatgpt_user_id"], json["user_id"]]
        let userId = first(auth.map { $0["chatgpt_user_id"] } + claims.map { $0["chatgpt_user_id"] }
            + auth.map { $0["user_id"] } + claims.map { $0["user_id"] }
            + rootUserCandidates + claims.map { $0["sub"] })
        let rootEmailCandidates: [Any?] = internalConflict ? [] : [json["email"]]
        let email = first(claims.map { $0["email"] }
            + claims.map { ($0["https://api.openai.com/profile"] as? [String: Any])?["email"] }
            + rootEmailCandidates)
        self.init(accountId: accountId, userId: userId, email: email)
    }

    static func tokenIdentity(_ token: String?) -> Self {
        guard let claim = jwtPayload(token) else {
            return Self(accountId: nil, userId: nil, email: nil)
        }
        let auth = claim["https://api.openai.com/auth"] as? [String: Any]
        func first(_ values: [Any?]) -> String? {
            values.lazy.compactMap { Self.normalized($0 as? String) }.first
        }
        let accountId = first([auth?["chatgpt_account_id"], claim["chatgpt_account_id"]])
        let userId = first([auth?["chatgpt_user_id"], claim["chatgpt_user_id"], auth?["user_id"], claim["user_id"], claim["sub"]])
        let email = first([claim["email"], (claim["https://api.openai.com/profile"] as? [String: Any])?["email"]])
        return Self(accountId: accountId, userId: userId, email: email)
    }

    private static func tokenIssuedAt(_ token: String?) -> Double {
        let payload = jwtPayload(token)
        return (payload?["iat"] as? Double) ?? (payload?["exp"] as? Double) ?? 0
    }

    public var nativeKey: String? {
        guard let accountId, let userId else { return nil }
        return "codex:account:\(accountId):user:\(userId)"
    }

    /// 旧数据缺少 userId 时，工作区 + 有效邮箱可用于关联；邮箱永远不能单独匹配。
    public var key: String? {
        if let nativeKey { return nativeKey }
        guard let accountId, let email else { return nil }
        return "codex:account:\(accountId):email:\(email)"
    }

    public func conflicts(with other: Self) -> Bool {
        if let accountId, let otherId = other.accountId, accountId != otherId { return true }
        if let userId, let otherUser = other.userId { return userId != otherUser }
        if let email, let otherEmail = other.email, email != otherEmail { return true }
        return false
    }

    public func matches(_ other: Self) -> Bool {
        guard !conflicts(with: other), let accountId, accountId == other.accountId else { return false }
        if let userId, let otherUser = other.userId { return userId == otherUser }
        return email != nil && email == other.email
    }

    /// 不完整身份的路径/UUID 回退也保留已知字段，防止同路径的不同账号碰撞。
    public func key(fallback: String) -> String {
        key ?? "codex:incomplete:account:\(accountId ?? "*"):user:\(userId ?? "*"):email:\(email ?? "*"):\(fallback)"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping.lowercased(), !normalized.isEmpty else { return nil }
        return normalized
    }

    private static func jwtPayload(_ token: String?) -> [String: Any]? {
        guard let pieces = token?.split(separator: "."), pieces.count >= 2 else { return nil }
        var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

enum CodexCredentialPolicy {
    static func belongsToSameWorkspace(
        lhsAccountID: String?,
        lhsUserID: String?,
        rhsAccountID: String?,
        rhsUserID: String?
    ) -> Bool {
        let lhs = CodexAccountIdentity(accountId: lhsAccountID, userId: lhsUserID)
        let rhs = CodexAccountIdentity(accountId: rhsAccountID, userId: rhsUserID)
        return lhs.nativeKey != nil && lhs.nativeKey == rhs.nativeKey
    }

    static func refreshFailure(statusCode: Int, data: Data) -> ProviderError {
        let details = oauthErrorDetails(from: data)
        let code = normalized(details.code)?.replacingOccurrences(of: "-", with: "_")
        let description = normalized(details.description) ?? ""
        let combined = [code, description].compactMap { $0 }.joined(separator: " ")

        if combined.contains("reused")
            || combined.contains("already used")
            || combined.contains("rotat") {
            return ProviderError(
                "refresh_token_reused",
                "The Codex refresh token was already rotated by another session. Sign in again to replace this credential."
            )
        }

        if combined.contains("expired") || combined.contains("revoked") {
            return ProviderError(
                "refresh_token_expired",
                "The Codex refresh token expired or was revoked. Sign in again to reconnect this account."
            )
        }

        if code == "invalid_grant"
            || code == "invalid_token"
            || statusCode == 400
            || statusCode == 401 {
            return ProviderError(
                "refresh_token_invalid",
                "The Codex refresh token was rejected. Sign in again if the account does not recover automatically."
            )
        }

        if statusCode == 429 {
            return ProviderError(
                "oauth_rate_limited",
                "Codex OAuth is temporarily rate limited. Wait a moment and try again."
            )
        }

        if (500..<600).contains(statusCode) {
            return ProviderError(
                "oauth_server_error",
                "Codex OAuth is temporarily unavailable (HTTP \(statusCode))."
            )
        }

        return ProviderError(
            "oauth_refresh_failed",
            "Codex OAuth refresh failed (HTTP \(statusCode))."
        )
    }

    static func refreshTransportFailure(_ error: Error) -> ProviderError {
        guard let urlError = error as? URLError else {
            return ProviderError(
                "oauth_network_error",
                "Codex OAuth refresh could not complete because of a network error."
            )
        }

        switch urlError.code {
        case .timedOut:
            return ProviderError(
                "oauth_network_timeout",
                "Codex OAuth refresh timed out. Check the network or proxy and try again."
            )
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed:
            return ProviderError(
                "oauth_network_unavailable",
                "Codex OAuth could not reach the authentication service. Check the network or proxy."
            )
        default:
            return ProviderError(
                "oauth_network_error",
                "Codex OAuth refresh failed because of a network error."
            )
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func oauthErrorDetails(from data: Data) -> (code: String?, description: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }

        if let code = object["error"] as? String {
            return (code, object["error_description"] as? String ?? object["message"] as? String)
        }
        if let nested = object["error"] as? [String: Any] {
            return (
                nested["code"] as? String ?? nested["type"] as? String,
                nested["message"] as? String ?? object["error_description"] as? String
            )
        }
        return (nil, object["error_description"] as? String ?? object["message"] as? String)
    }
}
