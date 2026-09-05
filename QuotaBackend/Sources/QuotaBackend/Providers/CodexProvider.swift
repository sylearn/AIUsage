import Foundation
import os

// MARK: - Codex Provider
// Reads ~/.codex/auth.json, refreshes OAuth
// when needed, and fetches ChatGPT Codex quota windows for one or many accounts.

private let codexLog = Logger(subsystem: "com.aiusage.quotabackend", category: "CodexProvider")

public struct CodexProvider: MultiAccountProviderFetcher, CredentialAcceptingProvider {
    public let id = "codex"
    public let displayName = "Codex"
    public let description = "OpenAI Codex CLI quota windows"

    let homeDirectory: String
    let timeoutSeconds: Double
    static let refreshURL = "https://auth.openai.com/oauth/token"
    static let oauthClientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let defaultBaseURL = "https://chatgpt.com/backend-api/"
    /// Provider id of the AIUsage-managed Codex proxy block in `config.toml`.
    /// Must mirror `CodexConfigManager.providerId` in the app target.
    static let proxyProviderId = "aiusage-proxy"

    public var supportedAuthMethods: [AuthMethod] { [.token, .authFile, .auto] }

    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        timeoutSeconds: Double = 20
    ) {
        self.homeDirectory = homeDirectory
        self.timeoutSeconds = timeoutSeconds
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let authContext = try resolvePrimaryAuthContext()
        return try await fetchForAuthContext(authContext)
    }

    public func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage {
        let creds: Credentials
        let source: SourceInfo
        let credentialPath: String?

        switch credential.authMethod {
        case .authFile:
            let path = NSString(string: credential.credential).expandingTildeInPath
            creds = try loadCredentials(from: path)
            let expected = CodexAccountIdentity(credential: credential)
            guard credentialIdentityIsCompatible(expected, with: creds) else {
                throw ProviderError("account_mismatch", "The auth file belongs to a different Codex account. Reconnect this account.")
            }
            source = sourceInfo(for: URL(fileURLWithPath: path), mode: "manual")
            credentialPath = path
        case .token, .apiKey:
            let token = credential.credential.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                throw ProviderError("missing_token", "Codex token is empty.")
            }
            let label = normalizedLabel(credential.accountLabel)
            creds = Credentials(
                authFile: "manual-token",
                accessToken: token,
                refreshToken: nil,
                idToken: nil,
                accountId: label,
                accountEmail: label,
                jwtPlanType: nil,
                jwtUserId: nil,
                needsRefresh: false,
                isApiKeyMode: true
            )
            source = SourceInfo(mode: "manual", type: "api-token")
            credentialPath = nil
        default:
            throw ProviderError("unsupported_auth_method", "Codex does not support \(credential.authMethod.rawValue) credentials.")
        }

        var effectiveCreds = creds
        var proactiveRefreshFailure: ProviderError?
        if !creds.isApiKeyMode, creds.needsRefresh, let refreshToken = creds.refreshToken {
            do {
                effectiveCreds = try await refreshCredentials(
                    creds,
                    refreshToken: refreshToken,
                    persistTo: credentialRefreshPaths(credentialPath: credentialPath, sourcePath: credential.metadata["sourcePath"])
                )
            } catch let refreshError as ProviderError {
                // A managed copy may hold a refresh token that another Codex
                // session already rotated. Keep the precise failure, but still
                // try its current access token and the authoritative source file
                // before declaring the credential expired.
                proactiveRefreshFailure = refreshError
            } catch {
                proactiveRefreshFailure = CodexCredentialPolicy.refreshTransportFailure(error)
            }
        }

        let usageURL = try resolveUsageURL()

        do {
            let response = try await requestUsage(creds: effectiveCreds, url: usageURL)
            return parseResponse(
                response,
                accountId: effectiveCreds.accountId ?? normalizedLabel(credential.accountLabel),
                source: source,
                fallbackEmail: effectiveCreds.accountEmail ?? normalizedLabel(credential.accountLabel),
                jwtPlanType: effectiveCreds.jwtPlanType,
                jwtUserId: effectiveCreds.jwtUserId
            )
        } catch let error as ProviderError where error.code == "unauthorized" {
            var credentialFailure = proactiveRefreshFailure
            var refreshedCredentials: Credentials?
            if credentialFailure == nil,
               !effectiveCreds.isApiKeyMode,
               let refreshToken = effectiveCreds.refreshToken ?? creds.refreshToken {
                do {
                    let refreshed = try await refreshCredentials(
                        effectiveCreds,
                        refreshToken: refreshToken,
                        persistTo: credentialRefreshPaths(credentialPath: credentialPath, sourcePath: credential.metadata["sourcePath"])
                    )
                    refreshedCredentials = refreshed
                } catch let refreshError as ProviderError {
                    credentialFailure = refreshError
                } catch {
                    credentialFailure = CodexCredentialPolicy.refreshTransportFailure(error)
                }
            }

            if let refreshed = refreshedCredentials {
                do {
                    let response = try await requestUsage(creds: refreshed, url: usageURL)
                    return parseResponse(
                        response,
                        accountId: refreshed.accountId ?? normalizedLabel(credential.accountLabel),
                        source: source,
                        fallbackEmail: refreshed.accountEmail ?? normalizedLabel(credential.accountLabel),
                        jwtPlanType: refreshed.jwtPlanType,
                        jwtUserId: refreshed.jwtUserId
                    )
                } catch let retryError as ProviderError where retryError.code == "unauthorized" {
                    credentialFailure = ProviderError(
                        "unauthorized_after_refresh",
                        "Codex rejected the refreshed access token. Sign in again to reconnect this account."
                    )
                }
            }

            do {
                return try await recoverFromSourceAndFetch(
                    staleCreds: creds,
                    credentialPath: credentialPath,
                    sourcePath: credential.metadata["sourcePath"],
                    usageURL: usageURL,
                    fallbackLabel: credential.accountLabel
                )
            } catch let recoveryError as ProviderError {
                if credentialFailure == nil,
                   !["no_source", "source_same_as_copy", "source_missing"].contains(recoveryError.code) {
                    credentialFailure = recoveryError
                }
            }

            throw credentialFailure ?? error
        }
    }

    /// Rescue path for managed-import copies whose refresh_token has been
    /// rotated out by the Codex CLI/App. When the authoritative auth file
    /// (credential.metadata["sourcePath"], typically ~/.codex/auth.json)
    /// belongs to the same workspace, overwrite the stale copy and retry.
    /// Workspace identity = accountId + userId. Plan is mutable display metadata
    /// and must never block recovery after an upgrade or downgrade.
    private func recoverFromSourceAndFetch(
        staleCreds: Credentials,
        credentialPath: String?,
        sourcePath: String?,
        usageURL: URL,
        fallbackLabel: String?
    ) async throws -> ProviderUsage {
        guard let credentialPath,
              let rawSource = stringValue(sourcePath) else {
            throw ProviderError("no_source", "No sourcePath metadata available for recovery.")
        }

        let expandedSource = NSString(string: rawSource).expandingTildeInPath
        let expandedCredential = NSString(string: credentialPath).expandingTildeInPath
        guard expandedSource != expandedCredential else {
            throw ProviderError("source_same_as_copy", "Credential already points at the authoritative source.")
        }
        guard FileManager.default.fileExists(atPath: expandedSource) else {
            throw ProviderError("source_missing", "Original auth file not found; cannot recover.")
        }

        guard let sourceData = FileManager.default.contents(atPath: expandedSource) else {
            throw ProviderError("source_missing", "Original auth file could not be read.")
        }
        let sourceCreds = try loadCredentials(from: expandedSource, data: sourceData)
        guard sameCodexWorkspace(staleCreds, sourceCreds) else {
            throw ProviderError("workspace_mismatch", "Source auth file is a different Codex workspace.")
        }

        guard let targetData = FileManager.default.contents(atPath: expandedCredential),
              let targetCreds = try? loadCredentials(from: expandedCredential, data: targetData),
              canReuseCredentials(staleCreds, targetCreds) else {
            throw ProviderError("account_mismatch", "The managed auth file changed accounts during recovery.")
        }
        if targetData != sourceData {
            do {
                guard FileManager.default.contents(atPath: expandedCredential) == targetData else {
                    throw ProviderError("account_mismatch", "The auth file changed during recovery.")
                }
                try sourceData.write(to: URL(fileURLWithPath: expandedCredential), options: .atomic)
            } catch {
                codexLog.warning("Failed to sync authoritative auth to managed copy at \(expandedCredential, privacy: .private): \(error.localizedDescription)")
            }
        }

        var effective = sourceCreds
        if !sourceCreds.isApiKeyMode, sourceCreds.needsRefresh, let rt = sourceCreds.refreshToken {
            do {
                let refreshed = try await refreshCredentials(
                    sourceCreds,
                    refreshToken: rt,
                    persistTo: [expandedSource, expandedCredential]
                )
                effective = refreshed
            } catch {
                codexLog.warning("Recovery refresh failed for \(expandedCredential, privacy: .private): \(error.localizedDescription)")
                throw ProviderError("recovery_refresh_failed", "Source credential refresh failed: \(error.localizedDescription)")
            }
        }

        let response = try await requestUsage(creds: effective, url: usageURL)
        return parseResponse(
            response,
            accountId: effective.accountId ?? normalizedLabel(fallbackLabel),
            source: sourceInfo(for: URL(fileURLWithPath: expandedCredential), mode: "manual"),
            fallbackEmail: effective.accountEmail ?? normalizedLabel(fallbackLabel),
            jwtPlanType: effective.jwtPlanType,
            jwtUserId: effective.jwtUserId
        )
    }

    private func sameCodexWorkspace(_ lhs: Credentials, _ rhs: Credentials) -> Bool {
        CodexCredentialPolicy.belongsToSameWorkspace(
            lhsAccountID: lhs.accountId,
            lhsUserID: lhs.jwtUserId,
            rhsAccountID: rhs.accountId,
            rhsUserID: rhs.jwtUserId
        )
    }

    private func canReuseCredentials(_ lhs: Credentials, _ rhs: Credentials) -> Bool {
        let left = CodexAccountIdentity(accountId: lhs.accountId, userId: lhs.jwtUserId, email: lhs.accountEmail)
        let right = CodexAccountIdentity(accountId: rhs.accountId, userId: rhs.jwtUserId, email: rhs.accountEmail)
        guard !left.conflicts(with: right) else { return false }
        return sameCodexWorkspace(lhs, rhs)
            || (lhs.accessToken == rhs.accessToken && lhs.refreshToken == rhs.refreshToken)
    }

    func credentialIdentityIsCompatible(_ expected: CodexAccountIdentity, with creds: Credentials) -> Bool {
        let actual = CodexAccountIdentity(accountId: creds.accountId, userId: creds.jwtUserId, email: creds.accountEmail)
        if !expected.conflicts(with: actual) { return true }
        // 旧版曾把 JWT sub 当作 userId；只在工作区完全一致且 JWT 能证明旧 subject 时升级。
        // 工作区本身冲突时不能根据同邮箱或同用户猜测，应重新连接明确的工作区。
        let subject = (decodeJWTPayload(token: creds.idToken)?["sub"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let legacyUser = subject != nil && expected.userId == subject
        guard expected.accountId != nil, expected.accountId == actual.accountId, legacyUser else { return false }
        let upgraded = CodexAccountIdentity(
            accountId: expected.accountId,
            userId: actual.userId,
            email: expected.email
        )
        return upgraded.matches(actual)
    }

    public func fetchAllAccounts() async -> [AccountFetchResult] {
        let contexts: [AuthContext]
        do {
            contexts = try resolveAllAuthContexts()
        } catch {
            return [AccountFetchResult(accountId: "default", accountLabel: nil, result: .failure(error))]
        }

        guard !contexts.isEmpty else {
            return [AccountFetchResult(
                accountId: "default",
                accountLabel: nil,
                result: .failure(ProviderError("not_logged_in", "No Codex auth files found. Run `codex login` and sign in with ChatGPT first."))
            )]
        }

        return await withTaskGroup(of: AccountFetchResult.self) { group in
            for context in contexts {
                group.addTask {
                    let accountId = context.creds.accountId
                        ?? context.creds.accountEmail
                        ?? context.url.lastPathComponent
                    let filePath = context.url.path
                    do {
                        let usage = try await fetchForAuthContext(context)
                        return AccountFetchResult(
                            accountId: accountId,
                            accountLabel: context.creds.accountEmail,
                            result: .success(usage),
                            sourceFilePath: filePath,
                            workspaceUserId: context.creds.jwtUserId
                        )
                    } catch {
                        return AccountFetchResult(
                            accountId: accountId,
                            accountLabel: context.creds.accountEmail,
                            result: .failure(error),
                            sourceFilePath: filePath,
                            workspaceUserId: context.creds.jwtUserId
                        )
                    }
                }
            }

            var results: [AccountFetchResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    // MARK: - Credentials

    struct Credentials: Sendable {
        let authFile: String
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let accountId: String?
        let accountEmail: String?
        let jwtPlanType: String?
        let jwtUserId: String?
        let needsRefresh: Bool
        let isApiKeyMode: Bool
    }

    private struct AuthContext {
        let url: URL
        let creds: Credentials
    }

    private func resolvePrimaryAuthContext() throws -> AuthContext {
        let contexts = try resolveAllAuthContexts()
        if let first = contexts.first {
            return first
        }

        let fallbackURL = URL(fileURLWithPath: "\(homeDirectory)/.codex/auth.json")
        return AuthContext(url: fallbackURL, creds: try loadCredentials(from: fallbackURL.path))
    }

    private func resolveAllAuthContexts() throws -> [AuthContext] {
        let env = ProcessInfo.processInfo.environment

        if let explicitFile = env["CODEX_AUTH_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitFile.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: explicitFile).expandingTildeInPath)
            return [AuthContext(url: url, creds: try loadCredentials(from: url.path))]
        }

        var candidates: [URL] = []

        let defaultAuthFile = URL(fileURLWithPath: "\(homeDirectory)/.codex/auth.json")
        if FileManager.default.fileExists(atPath: defaultAuthFile.path) {
            candidates.append(defaultAuthFile)
        }

        if let authDirectoryRaw = env["CODEX_AUTH_DIR"], !authDirectoryRaw.isEmpty {
            let authDirectory = NSString(string: authDirectoryRaw).expandingTildeInPath
            let directoryURL = URL(fileURLWithPath: authDirectory, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            candidates.append(contentsOf: files.filter {
                $0.lastPathComponent.hasPrefix("codex-") && $0.pathExtension == "json"
            })
        }

        var seen = Set<String>()
        return candidates
            .sorted { modificationDate(for: $0) > modificationDate(for: $1) }
            .compactMap { url in
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard seen.insert(resolved).inserted else { return nil }
                guard let creds = try? loadCredentials(from: resolved) else { return nil }
                return AuthContext(url: URL(fileURLWithPath: resolved), creds: creds)
            }
    }

    func loadCredentials(from path: String) throws -> Credentials {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ProviderError("not_logged_in", "\(path) not found. Run `codex login` and sign in with ChatGPT first.")
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ProviderError("invalid_auth_file", "\(path) could not be read.")
        }
        return try loadCredentials(from: path, data: data)
    }

    private func loadCredentials(from path: String, data: Data) throws -> Credentials {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError("invalid_auth_file", "\(path) could not be parsed.")
        }

        if let apiKey = stringValue(json["OPENAI_API_KEY"]) {
            return Credentials(
                authFile: path,
                accessToken: apiKey,
                refreshToken: nil,
                idToken: nil,
                accountId: nil,
                accountEmail: stringValue(json["email"]),
                jwtPlanType: nil,
                jwtUserId: nil,
                needsRefresh: false,
                isApiKeyMode: true
            )
        }

        let tokens = json["tokens"] as? [String: Any] ?? [:]
        let accessToken = stringValue(tokens["access_token"])
            ?? stringValue(tokens["accessToken"])
            ?? stringValue(json["access_token"])
            ?? stringValue(json["accessToken"])

        guard let accessToken else {
            throw ProviderError("missing_tokens", "\(path) exists but has no access token.")
        }

        let refreshToken = stringValue(tokens["refresh_token"])
            ?? stringValue(tokens["refreshToken"])
            ?? stringValue(json["refresh_token"])
            ?? stringValue(json["refreshToken"])
        let idToken = stringValue(tokens["id_token"])
            ?? stringValue(tokens["idToken"])
            ?? stringValue(json["id_token"])
            ?? stringValue(json["idToken"])
        let identity = CodexAccountIdentity(authJSON: json)
        let accountId = identity.accountId
        let accountEmail = stringValue(json["email"])
            ?? decodeEmail(fromJWT: idToken)
            ?? decodeEmail(fromJWT: accessToken)
        let jwtPlanType = decodePlanType(fromJWT: idToken) ?? decodePlanType(fromJWT: accessToken)
        let jwtUserId = identity.userId

        let lastRefresh = stringValue(json["last_refresh"]).flatMap(parseDate)
        let expiryDate = stringValue(json["expired"]).flatMap(parseDate)
        var needsRefresh: Bool
        if let expiryDate {
            needsRefresh = expiryDate.timeIntervalSinceNow <= 300
        } else if let lastRefresh {
            needsRefresh = Date().timeIntervalSince(lastRefresh) > 8 * 86400
        } else {
            needsRefresh = true
        }

        if !needsRefresh, let payload = decodeJWTPayload(token: accessToken),
           let exp = payload["exp"] as? Double, Date(timeIntervalSince1970: exp).timeIntervalSinceNow <= 60 {
            needsRefresh = true
        }

        return Credentials(
            authFile: path,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountId: accountId,
            accountEmail: accountEmail,
            jwtPlanType: jwtPlanType,
            jwtUserId: jwtUserId,
            needsRefresh: needsRefresh,
            isApiKeyMode: false
        )
    }

    private func refreshCredentials(
        _ creds: Credentials,
        refreshToken: String,
        persistTo paths: [String]
    ) async throws -> Credentials {
        let key = Self.refreshLockKey(creds: creds, path: paths.first, refreshToken: refreshToken)
        return try await CodexOAuthRefreshSerializer.shared.run(key: key) {
            try await self.performSerializedRefresh(
                creds,
                fallbackRefreshToken: refreshToken,
                persistTo: paths
            )
        }
    }

    func performSerializedRefresh(
        _ creds: Credentials,
        fallbackRefreshToken: String,
        persistTo paths: [String]
    ) async throws -> Credentials {
        var current = creds
        if let path = paths.first, let disk = try? loadCredentials(from: path), !disk.isApiKeyMode {
            guard canReuseCredentials(creds, disk) else {
                throw ProviderError("account_mismatch", "The auth file now belongs to a different Codex account.")
            }
            current = disk
            if !disk.needsRefresh {
                return disk
            }
        }
        let token = current.refreshToken ?? fallbackRefreshToken
        let refreshed = try await performOAuthRefresh(current, refreshToken: token)
        for path in uniqueRefreshPaths(paths) {
            persistRefreshedCredentials(refreshed, replacing: current, to: path)
        }
        return refreshed
    }

    private func credentialRefreshPaths(credentialPath: String?, sourcePath: String?) -> [String] {
        uniqueRefreshPaths([credentialPath, sourcePath].compactMap { raw in
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return nil }
            return NSString(string: trimmed).expandingTildeInPath
        })
    }

    private func uniqueRefreshPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for path in paths {
            let normalized = AccountCredentialStore.normalizedAuthFilePath(path)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            unique.append(path)
        }
        return unique
    }

    private static func refreshLockKey(creds: Credentials, path: String?, refreshToken: String) -> String {
        if let account = creds.accountId?.trimmingCharacters(in: .whitespacesAndNewlines), !account.isEmpty,
           let user = creds.jwtUserId?.trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty {
            return "ws:\(account.lowercased()):\(user.lowercased())"
        }
        let token = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            return "rt:\(token)"
        }
        if let path, !path.isEmpty {
            return "path:\(AccountCredentialStore.normalizedAuthFilePath(path))"
        }
        return "codex-oauth"
    }

    private func performOAuthRefresh(_ creds: Credentials, refreshToken: String) async throws -> Credentials {
        guard let url = URL(string: Self.refreshURL) else {
            throw ProviderError("invalid_url", "Codex OAuth refresh URL is invalid.")
        }
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "client_id": Self.oauthClientId,
            "refresh_token": refreshToken
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CodexCredentialPolicy.refreshTransportFailure(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError(
                "oauth_invalid_response",
                "Codex OAuth refresh returned a non-HTTP response."
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CodexCredentialPolicy.refreshFailure(statusCode: http.statusCode, data: data)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccess = stringValue(json["access_token"]) else {
            throw ProviderError(
                "oauth_invalid_response",
                "Codex OAuth refresh succeeded but returned no access token."
            )
        }

        let newRefresh = stringValue(json["refresh_token"]) ?? refreshToken
        let newIdToken = stringValue(json["id_token"]) ?? creds.idToken
        let refreshedIdentity = CodexAccountIdentity(authJSON: ["tokens": [
            "account_id": creds.accountId ?? "", "id_token": newIdToken ?? "", "access_token": newAccess
        ]])
        let originalIdentity = CodexAccountIdentity(accountId: creds.accountId, userId: creds.jwtUserId, email: creds.accountEmail)
        guard !originalIdentity.conflicts(with: refreshedIdentity) else {
            throw ProviderError("account_mismatch", "Codex OAuth returned credentials for a different account.")
        }
        return Credentials(
            authFile: creds.authFile,
            accessToken: newAccess,
            refreshToken: newRefresh,
            idToken: newIdToken,
            accountId: creds.accountId,
            accountEmail: creds.accountEmail,
            jwtPlanType: decodePlanType(fromJWT: newIdToken) ?? creds.jwtPlanType,
            jwtUserId: refreshedIdentity.userId ?? creds.jwtUserId,
            needsRefresh: false,
            isApiKeyMode: false
        )
    }

    func persistRefreshedCredentials(_ creds: Credentials, replacing original: Credentials, to path: String) {
        guard !creds.isApiKeyMode else { return }
        // sourcePath 常是共享的 ~/.codex/auth.json；写回前核对当前内容，不能覆盖后来登录的成员。
        guard let originalData = FileManager.default.contents(atPath: path),
              let disk = try? loadCredentials(from: path, data: originalData), !disk.isApiKeyMode,
              canReuseCredentials(original, disk) else { return }
        guard var json = try? JSONSerialization.jsonObject(with: originalData) as? [String: Any] else { return }

        if var tokens = json["tokens"] as? [String: Any] {
            tokens["access_token"] = creds.accessToken
            if let rt = creds.refreshToken { tokens["refresh_token"] = rt }
            if let it = creds.idToken { tokens["id_token"] = it }
            json["tokens"] = tokens
        } else {
            json["access_token"] = creds.accessToken
            if let rt = creds.refreshToken { json["refresh_token"] = rt }
            if let it = creds.idToken { json["id_token"] = it }
        }
        json["last_refresh"] = SharedFormatters.iso8601String(from: Date())

        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            guard FileManager.default.contents(atPath: path) == originalData else { return }
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private func resolveUsageURL() throws -> URL {
        try Self.resolveUsageEndpointURL(homeDirectory: homeDirectory)
    }

    /// ChatGPT subscription quota endpoint. Never derived from Codex inference `base_url`.
    static func resolveUsageEndpointURL(homeDirectory _: String) throws -> URL {
        guard let url = URL(string: "\(Self.defaultBaseURL)wham/usage") else {
            throw ProviderError("invalid_url", "Codex usage URL is invalid.")
        }
        return url
    }

    private func requestUsage(creds: Credentials, url: URL) async throws -> [String: Any] {
        // The usage URL is identical for every account; identity lives in the
        // headers below. Cached responses would leak across accounts, so this
        // goes through the cache-free quota session.
        var request = QuotaHTTP.request(url: url, timeout: timeoutSeconds)
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIUsage", forHTTPHeaderField: "User-Agent")
        if let accountId = creds.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await QuotaHTTP.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ProviderError("unauthorized", "Codex OAuth token is invalid or expired.")
            }
            if !((200..<300).contains(http.statusCode)) {
                throw ProviderError("api_error", "Codex usage API returned HTTP \(http.statusCode).")
            }
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError("parse_failed", "Codex usage API returned invalid JSON.")
        }
        return json
    }

    private func fetchForAuthContext(_ authContext: AuthContext) async throws -> ProviderUsage {
        var creds = authContext.creds

        if !creds.isApiKeyMode, creds.needsRefresh, let refreshToken = creds.refreshToken {
            creds = try await refreshCredentials(
                creds,
                refreshToken: refreshToken,
                persistTo: [authContext.url.path]
            )
        }

        let usageURL = try resolveUsageURL()

        do {
            let response = try await requestUsage(creds: creds, url: usageURL)
            return parseResponse(
                response,
                accountId: creds.accountId,
                source: sourceInfo(for: authContext.url, mode: "oauth"),
                fallbackEmail: creds.accountEmail,
                jwtPlanType: creds.jwtPlanType,
                jwtUserId: creds.jwtUserId
            )
        } catch let error as ProviderError where error.code == "unauthorized" {
            guard !creds.isApiKeyMode,
                  let refreshToken = creds.refreshToken ?? authContext.creds.refreshToken else { throw error }
            let refreshed = try await refreshCredentials(
                creds,
                refreshToken: refreshToken,
                persistTo: [authContext.url.path]
            )
            let response = try await requestUsage(creds: refreshed, url: usageURL)
            return parseResponse(
                response,
                accountId: refreshed.accountId,
                source: sourceInfo(for: authContext.url, mode: "oauth"),
                fallbackEmail: refreshed.accountEmail,
                jwtPlanType: refreshed.jwtPlanType,
                jwtUserId: refreshed.jwtUserId
            )
        }
    }

    func parseResponse(
        _ json: [String: Any],
        accountId: String?,
        source: SourceInfo,
        fallbackEmail: String?,
        jwtPlanType: String? = nil,
        jwtUserId: String? = nil
    ) -> ProviderUsage {
        let rateLimit = json["rate_limit"] as? [String: Any] ?? [:]
        let codeReviewLimit = json["code_review_rate_limit"] as? [String: Any] ?? [:]

        var usage = ProviderUsage(provider: "codex", label: "Codex")
        usage.accountEmail = stringValue(json["email"]) ?? fallbackEmail

        // 请求使用的工作区 ID 是身份锚点；响应中的 account_id 可能是旧式用户级 ID。
        let rawAccountId = accountId ?? stringValue(json["account_id"])
        usage.usageAccountId = rawAccountId

        let apiPlan = stringValue(json["plan_type"])
        let rawPlan = apiPlan ?? jwtPlanType
        // 规范成展示名（Plus/Pro/Business/...），未知值原样保留。
        usage.accountPlan = Self.planDisplayName(forRaw: rawPlan) ?? rawPlan

        // 工作区归类仍以原始 plan 计算（兼容 *_usage_based / hc 等变体）。
        let wsType = Self.workspaceType(fromPlan: rawPlan)
        usage.extra["workspaceType"] = AnyCodable(wsType)
        if let rawAccountId { usage.extra["workspaceId"] = AnyCodable(rawAccountId) }
        if let jwtUserId { usage.extra["userId"] = AnyCodable(jwtUserId) }

        usage.primary = parseWindow(rateLimit["primary_window"] as? [String: Any])
        usage.secondary = parseWindow(rateLimit["secondary_window"] as? [String: Any])
        usage.tertiary = parseWindow(codeReviewLimit["primary_window"] as? [String: Any])
        usage.source = source

        return usage
    }

    private func parseWindow(_ window: [String: Any]?) -> RawQuotaWindow? {
        guard let window,
              let usedPercent = window["used_percent"] as? Double else {
            return nil
        }
        var result = RawQuotaWindow()
        result.usedPercent = usedPercent
        result.remainingPercent = max(0, 100 - usedPercent)
        result.label = Self.windowLabel(
            forLimitSeconds: (window["limit_window_seconds"] as? NSNumber)?.doubleValue
        )

        if let resetAtRaw = window["reset_at"] as? Double, resetAtRaw > 0 {
            let resetDate = Date(timeIntervalSince1970: resetAtRaw)
            result.resetAt = SharedFormatters.iso8601String(from: resetDate)
            result.resetDescription = formatResetDescription(resetDate)
        }
        return result
    }

    /// OpenAI may temporarily move a remaining quota window into `primary_window`.
    /// The reported duration is therefore the source of truth, not its position.
    static func windowLabel(forLimitSeconds seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }

        let totalSeconds = Int(seconds.rounded())
        let minute = 60
        let hour = 60 * minute
        let day = 24 * hour
        let week = 7 * day

        if totalSeconds == week { return "Weekly Window" }
        if totalSeconds.isMultiple(of: day) { return "\(totalSeconds / day)d Window" }
        if totalSeconds.isMultiple(of: hour) { return "\(totalSeconds / hour)h Window" }
        if totalSeconds.isMultiple(of: minute) { return "\(totalSeconds / minute)m Window" }
        return "Quota Window"
    }

    private func formatResetDescription(_ date: Date) -> String {
        let diff = date.timeIntervalSinceNow
        if diff <= 0 { return "Resets soon" }
        let totalMinutes = Int(diff / 60)
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "Resets in \(days)d \(hours)h" }
        if hours > 0 { return "Resets in \(hours)h \(minutes)m" }
        return "Resets in \(minutes)m"
    }

    private func parseDate(_ value: String) -> Date? {
        SharedFormatters.parseISO8601(value)
    }

    private func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func sourceInfo(for url: URL, mode: String) -> SourceInfo {
        let defaultAuthPath = "\(homeDirectory)/.codex/auth.json"
        var info = SourceInfo(
            mode: mode,
            type: url.path == defaultAuthPath ? "codex-auth-json" : "imported-auth-file"
        )
        info.roots = [url.path]
        return info
    }

    private func normalizedLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func decodeJWTPayload(token: String?) -> [String: Any]? {
        guard let token, token.contains(".") else { return nil }
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        var payload = String(segments[1])
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        payload = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func decodeEmail(fromJWT token: String?) -> String? {
        guard let payload = decodeJWTPayload(token: token) else { return nil }
        if let email = stringValue(payload["email"]) {
            return email
        }
        if let profile = payload["https://api.openai.com/profile"] as? [String: Any] {
            return stringValue(profile["email"])
        }
        return nil
    }

    private func decodePlanType(fromJWT token: String?) -> String? {
        guard let payload = decodeJWTPayload(token: token) else { return nil }
        if let auth = payload["https://api.openai.com/auth"] as? [String: Any] {
            return stringValue(auth["chatgpt_plan_type"])
        }
        return nil
    }

    // MARK: - ChatGPT / Codex Plan Mapping
    // 基于 openai/codex 的 KnownPlan（codex-rs/login/src/token_data.rs）做映射，但展示名贴合
    // ChatGPT 现行方案命名。要点：
    //   - 旧的 "team" 已更名为 "ChatGPT Business"，统一展示为 Business（旧账号 JWT 仍可能下发 team）；
    //   - "hc" → Enterprise；含 *_usage_based 的按需计费变体归并到 Business / Enterprise；
    //   - 个人计划：free / go / plus / pro。

    /// 规范化原始 plan 键：小写、去空白、空格/连字符→下划线，
    /// 以便同时兼容原始值（"self_serve_business_usage_based"）与展示名（"Self Serve Business Usage Based"）。
    private static func normalizePlanKey(_ raw: String) -> String {
        raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    /// 展示名（贴合 ChatGPT 现行方案命名）。未知值原样返回。
    static func planDisplayName(forRaw raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        switch normalizePlanKey(raw) {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro"
        // ChatGPT Team 已更名为 Business，旧 team 值统一展示为 Business。
        case "team", "self_serve_business_usage_based", "business": return "Business"
        case "enterprise_cbp_usage_based", "enterprise", "hc": return "Enterprise"
        case "education", "edu": return "Edu"
        default: return raw
        }
    }

    /// Derive a workspace type label from the plan string.
    /// 个人计划 (free/go/plus/pro) → "Personal"；团队/企业/教育 → 对应工作区名。
    static func workspaceType(fromPlan plan: String?) -> String {
        guard let plan, !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Personal"
        }
        switch normalizePlanKey(plan) {
        case "team", "self_serve_business_usage_based", "business": return "Business"
        case "enterprise_cbp_usage_based", "enterprise", "hc": return "Enterprise"
        case "education", "edu": return "Edu"
        default: return "Personal"
        }
    }
}

/// Serializes Codex OAuth refresh per workspace so parallel account fetches
/// cannot rotate the same refresh_token. Callers must reload/persist inside
/// `run`; awaiting across the actor boundary is not a lock.
private actor CodexOAuthRefreshSerializer {
    static let shared = CodexOAuthRefreshSerializer()
    private var tails: [String: Task<Void, Never>] = [:]

    func run<T: Sendable>(
        key: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = tails[key]
        let current = Task {
            await previous?.value
            return try await operation()
        }
        tails[key] = Task { _ = try? await current.value }
        return try await current.value
    }
}

// ProviderUsage doesn't have accountId by default, add it via extra
extension ProviderUsage {
    var accountId: String? {
        get { extra["accountId"]?.value as? String }
        set { extra["accountId"] = newValue.map { AnyCodable($0) } }
    }
}
