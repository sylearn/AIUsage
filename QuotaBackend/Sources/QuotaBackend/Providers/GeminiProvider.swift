import Foundation

// MARK: - Gemini Provider
// 读取 ~/.gemini/oauth_creds.json，刷新 token 后调用 Google Cloud Code Assist API

public struct GeminiProvider: ProviderFetcher, CredentialAcceptingProvider {
    public let id = "gemini"
    public let displayName = "Gemini CLI"
    public let description = "Google Gemini CLI quota usage"

    let homeDirectory: String
    let timeoutSeconds: Double

    static let quotaURL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
    static let loadCodeAssistURL = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    static let projectsURL = "https://cloudresourcemanager.googleapis.com/v1/projects"
    static let oauthRefreshURL = "https://oauth2.googleapis.com/token"

    public var supportedAuthMethods: [AuthMethod] { [.authFile, .auto] }

    public init(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
                timeoutSeconds: Double = 15) {
        self.homeDirectory = homeDirectory
        self.timeoutSeconds = timeoutSeconds
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let credentialPath = "\(homeDirectory)/.gemini/oauth_creds.json"
        let creds = try loadCredentials(from: credentialPath)
        return try await fetchUsageWithRetry(creds: creds, source: SourceInfo(mode: "oauth", type: "gemini-cli"), credentialPath: credentialPath)
    }

    public func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage {
        guard credential.authMethod == .authFile else {
            throw ProviderError("unsupported_auth_method", "Gemini CLI supports auth file imports only.")
        }

        let path = NSString(string: credential.credential).expandingTildeInPath

        if !FileManager.default.fileExists(atPath: path) {
            if let resynced = resyncFromOriginalSource(credential: credential, managedPath: path) {
                let creds = try loadCredentials(from: resynced)
                return try await fetchUsageWithRetry(creds: creds, source: SourceInfo(mode: "manual", type: "auth-file"), credentialPath: resynced)
            }
        }

        let creds = try loadCredentials(from: path)
        return try await fetchUsageWithRetry(creds: creds, source: SourceInfo(mode: "manual", type: "auth-file"), credentialPath: path)
    }

    private func resyncFromOriginalSource(credential: AccountCredential, managedPath: String) -> String? {
        let originalPath: String
        if let sourceId = credential.metadata["sourceIdentifier"], sourceId.hasPrefix("file:") {
            originalPath = String(sourceId.dropFirst("file:".count))
        } else {
            originalPath = "\(homeDirectory)/.gemini/oauth_creds.json"
        }

        let expanded = NSString(string: originalPath).expandingTildeInPath
        guard expanded != managedPath, FileManager.default.fileExists(atPath: expanded) else { return nil }

        

        let dir = (managedPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(atPath: expanded, toPath: managedPath)

        return FileManager.default.fileExists(atPath: managedPath) ? managedPath : expanded
    }

    private func fetchUsageWithRetry(creds: GeminiCredentials, source: SourceInfo, credentialPath: String) async throws -> ProviderUsage {
        let (accessToken, didRefresh) = try await resolveAccessToken(creds: creds, credentialPath: credentialPath)

        async let codeAssistTask = loadCodeAssist(accessToken: accessToken)
        let codeAssist = await codeAssistTask
        let projectId: String?
        if let p = codeAssist.projectId {
            projectId = p
        } else {
            projectId = await discoverProjectId(accessToken: accessToken)
        }

        do {
            let quotaResponse = try await retrieveQuota(accessToken: accessToken, projectId: projectId)
            return parseQuotaResponse(quotaResponse, creds: creds, projectId: projectId, tierId: codeAssist.tierId, source: source)
        } catch let error as ProviderError where error.code == "not_logged_in" && !didRefresh {
            guard let refreshToken = creds.refreshToken, !refreshToken.isEmpty else { throw error }
            let result = try await refreshAndPersist(refreshToken: refreshToken, creds: creds, credentialPath: credentialPath)
            let retryCodeAssist = await loadCodeAssist(accessToken: result.accessToken)
            let retryProjectId: String?
            if let p = retryCodeAssist.projectId {
                retryProjectId = p
            } else if let p = projectId {
                retryProjectId = p
            } else {
                retryProjectId = await discoverProjectId(accessToken: result.accessToken)
            }
            let quotaResponse = try await retrieveQuota(accessToken: result.accessToken, projectId: retryProjectId)
            return parseQuotaResponse(quotaResponse, creds: creds, projectId: retryProjectId, tierId: retryCodeAssist.tierId ?? codeAssist.tierId, source: source)
        }
    }

    // MARK: - Credentials

    private struct GeminiCredentials {
        let accessToken: String?
        let idToken: String?
        let refreshToken: String?
        let expiryDate: Date?
        let directEmail: String?
        let clientId: String?
        let clientSecret: String?

        var accountEmail: String? {
            if let jwtEmail = jwtEmail() { return jwtEmail }
            return directEmail
        }

        private func jwtEmail() -> String? {
            guard let token = idToken, token.contains(".") else { return nil }
            let parts = token.split(separator: ".")
            guard parts.count >= 2 else { return nil }
            var payload = String(parts[1])
            let rem = payload.count % 4
            if rem > 0 { payload += String(repeating: "=", count: 4 - rem) }
            payload = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            guard let data = Data(base64Encoded: payload),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json["email"] as? String
        }
    }

    private func loadCredentials() throws -> GeminiCredentials {
        try loadCredentials(from: "\(homeDirectory)/.gemini/oauth_creds.json")
    }

    private func loadCredentials(from path: String) throws -> GeminiCredentials {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ProviderError("not_logged_in", "\(path) not found. Start `gemini`, choose “Sign in with Google”, and finish the browser login first.")
        }
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError("invalid_credentials_file", "\(path) could not be parsed.")
        }

        let expiryDate: Date?
        if let ed = json["expiry_date"] as? Double {
            expiryDate = Date(timeIntervalSince1970: ed / 1000)
        } else if let eds = json["expiry_date"] as? String, let ed = Double(eds) {
            expiryDate = Date(timeIntervalSince1970: ed / 1000)
        } else {
            expiryDate = nil
        }

        return GeminiCredentials(
            accessToken: json["access_token"] as? String,
            idToken: json["id_token"] as? String,
            refreshToken: json["refresh_token"] as? String,
            expiryDate: expiryDate,
            directEmail: json["email"] as? String,
            clientId: json["client_id"] as? String,
            clientSecret: json["client_secret"] as? String
        )
    }

    private func resolveAccessToken(creds: GeminiCredentials, credentialPath: String) async throws -> (String, Bool) {
        guard let accessToken = creds.accessToken, !accessToken.isEmpty else {
            throw ProviderError("not_logged_in", "Gemini CLI access token is missing. Start `gemini`, choose “Sign in with Google”, and finish the browser login first.")
        }

        let shouldRefresh: Bool
        if let expiry = creds.expiryDate {
            shouldRefresh = expiry.timeIntervalSinceNow <= 60
        } else {
            shouldRefresh = true
        }

        if shouldRefresh, let refreshToken = creds.refreshToken, !refreshToken.isEmpty {
            if let result = try? await refreshAndPersist(refreshToken: refreshToken, creds: creds, credentialPath: credentialPath) {
                return (result.accessToken, true)
            }
        }
        return (accessToken, false)
    }

    private struct RefreshResult {
        let accessToken: String
        let idToken: String?
        let expiresIn: Int?
    }

    private func refreshAndPersist(refreshToken: String, creds: GeminiCredentials, credentialPath: String) async throws -> RefreshResult {
        let result = try await performTokenRefresh(refreshToken: refreshToken, creds: creds)
        persistRefreshedCredentials(result: result, refreshToken: refreshToken, to: credentialPath)
        return result
    }

    private func performTokenRefresh(refreshToken: String, creds: GeminiCredentials) async throws -> RefreshResult {
        if let embeddedId = creds.clientId, !embeddedId.isEmpty,
           let embeddedSecret = creds.clientSecret, !embeddedSecret.isEmpty {
            if let result = try? await attemptTokenRefresh(refreshToken: refreshToken, clientId: embeddedId, clientSecret: embeddedSecret) {
                return result
            }
        }

        let discoveredCreds = await Task.detached(priority: .userInitiated) {
            self.findOAuthCredentials()
        }.value

        if let (clientId, clientSecret) = discoveredCreds {
            if let result = try? await attemptTokenRefresh(refreshToken: refreshToken, clientId: clientId, clientSecret: clientSecret) {
                return result
            }
        }

        throw ProviderError("refresh_failed", "Failed to refresh Gemini OAuth token.")
    }

    private func attemptTokenRefresh(refreshToken: String, clientId: String, clientSecret: String) async throws -> RefreshResult {
        guard let url = URL(string: Self.oauthRefreshURL) else {
            throw ProviderError("invalid_url", "Gemini OAuth refresh URL is invalid.")
        }
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=refresh_token&client_id=\(clientId)&client_secret=\(clientSecret)&refresh_token=\(refreshToken)"
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newToken = json["access_token"] as? String else {
            throw ProviderError("refresh_failed", "Token refresh returned invalid response.")
        }
        return RefreshResult(accessToken: newToken, idToken: json["id_token"] as? String, expiresIn: json["expires_in"] as? Int)
    }

    private func persistRefreshedCredentials(result: RefreshResult, refreshToken: String, to path: String) {
        var json: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }
        json["access_token"] = result.accessToken
        if let newIdToken = result.idToken { json["id_token"] = newIdToken }
        json["refresh_token"] = refreshToken
        if let expiresIn = result.expiresIn {
            json["expiry_date"] = Int64(Date().timeIntervalSince1970 * 1000) + Int64(expiresIn) * 1000
        }
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private func findOAuthCredentials() -> (String, String)? {
        let environment = ProcessInfo.processInfo.environment
        if let clientId = environment["AIUSAGE_GEMINI_OAUTH_CLIENT_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let clientSecret = environment["AIUSAGE_GEMINI_OAUTH_CLIENT_SECRET"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !clientId.isEmpty,
           !clientSecret.isEmpty {
            return (clientId, clientSecret)
        }

        // 1. 从 gemini binary 位置反推（最可靠）
        if let binaryPath = runCommand("/usr/bin/which", args: ["gemini"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !binaryPath.isEmpty {
            let binaryURL = URL(fileURLWithPath: binaryPath)
            // binary 通常在 .../bin/gemini，向上找 lib/node_modules
            let roots = [
                binaryURL.deletingLastPathComponent().deletingLastPathComponent().path, // ../
                binaryURL.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().path
            ]
            let candidates = [
                "lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
                "node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"
            ]
            for root in roots {
                for candidate in candidates {
                    let full = "\(root)/\(candidate)"
                    if let content = try? String(contentsOfFile: full, encoding: .utf8),
                       let id = extractConstant("OAUTH_CLIENT_ID", from: content),
                       let secret = extractConstant("OAUTH_CLIENT_SECRET", from: content) {
                        return (id, secret)
                    }
                }
            }
        }

        // 2. 固定搜索路径（fallback）
        let searchRoots = [
            "/opt/homebrew/lib/node_modules/@google/gemini-cli",
            "/usr/local/lib/node_modules/@google/gemini-cli",
            "\(homeDirectory)/.npm/global/lib/node_modules/@google/gemini-cli",
        ]
        let oauthRelPath = "node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"
        for root in searchRoots {
            let full = "\(root)/\(oauthRelPath)"
            if let content = try? String(contentsOfFile: full, encoding: .utf8),
               let id = extractConstant("OAUTH_CLIENT_ID", from: content),
               let secret = extractConstant("OAUTH_CLIENT_SECRET", from: content) {
                return (id, secret)
            }
        }

        // 3. Bundle directory (新版 gemini-cli 打包格式)
        let bundleCandidates = [
            "/opt/homebrew/lib/node_modules/@google/gemini-cli/bundle",
            "/usr/local/lib/node_modules/@google/gemini-cli/bundle"
        ]
        for bundlePath in bundleCandidates {
            let bundleURL = URL(fileURLWithPath: bundlePath, isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: bundleURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "js" {
                guard let content = try? String(contentsOf: file, encoding: .utf8),
                      let id = extractConstant("OAUTH_CLIENT_ID", from: content),
                      let secret = extractConstant("OAUTH_CLIENT_SECRET", from: content) else {
                    continue
                }
                return (id, secret)
            }
        }

        return nil
    }

    private func runCommand(_ path: String, args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run(); task.waitUntilExit() } catch { return nil }
        guard task.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    private func extractConstant(_ name: String, from content: String) -> String? {
        // Match patterns like: const OAUTH_CLIENT_ID = "value" or OAUTH_CLIENT_ID="value"
        let patterns = [
            "\(name)\\s*=\\s*[\"']([^\"']+)[\"']",
            "\(name):\\s*[\"']([^\"']+)[\"']"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
               let range = Range(match.range(at: 1), in: content) {
                return String(content[range])
            }
        }
        return nil
    }

    // MARK: - API Requests

    private struct CodeAssistInfo {
        let tierId: String?
        let projectId: String?
    }

    // These two are best-effort only — mirror JS where both failures are caught and return null
    // Use short timeout so they don't eat into the quota fetch budget
    private static let optionalRequestTimeout: Double = 5

    private func loadCodeAssist(accessToken: String) async -> CodeAssistInfo {
        guard let url = URL(string: Self.loadCodeAssistURL) else { return CodeAssistInfo(tierId: nil, projectId: nil) }
        var request = URLRequest(url: url, timeoutInterval: Self.optionalRequestTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "metadata": ["ideType": "GEMINI_CLI", "pluginType": "GEMINI"]
        ])

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CodeAssistInfo(tierId: nil, projectId: nil)
        }

        let tierId = (json["currentTier"] as? [String: Any])?["id"] as? String
        let projectId = normalizeProjectId(json["cloudaicompanionProject"])
        return CodeAssistInfo(tierId: tierId, projectId: projectId)
    }

    private func discoverProjectId(accessToken: String) async -> String? {
        guard let url = URL(string: Self.projectsURL) else { return nil }
        var request = QuotaHTTP.request(url: url, timeout: Self.optionalRequestTimeout)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        guard let (data, _) = try? await QuotaHTTP.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [[String: Any]] else { return nil }

        for project in projects {
            if let id = project["projectId"] as? String {
                if id.hasPrefix("gen-lang-client") { return id }
                if let labels = project["labels"] as? [String: Any], labels["generative-language"] != nil { return id }
            }
        }
        return nil
    }

    private func retrieveQuota(accessToken: String, projectId: String?) async throws -> [String: Any] {
        guard let url = URL(string: Self.quotaURL) else {
            throw ProviderError("invalid_url", "Gemini quota URL is invalid.")
        }
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [:]
        if let p = projectId { body["project"] = p }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, (http.statusCode == 401 || http.statusCode == 403) {
            throw ProviderError("not_logged_in", "Gemini OAuth token is invalid or expired. Re-authenticate with `gemini`.")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError("parse_failed", "Gemini quota API returned invalid JSON.")
        }
        return json
    }

    // MARK: - Response Parsing

    private func parseQuotaResponse(_ response: [String: Any], creds: GeminiCredentials, projectId: String?, tierId: String?, source: SourceInfo) -> ProviderUsage {
        let buckets = response["buckets"] as? [[String: Any]] ?? []

        // Group by modelId, keep lowest remainingFraction
        var byModel: [String: (remainingFraction: Double, resetTime: String?, tokenType: String?)] = [:]
        for bucket in buckets {
            guard let modelId = bucket["modelId"] as? String,
                  let remainingFraction = bucket["remainingFraction"] as? Double else { continue }
            if let existing = byModel[modelId], existing.remainingFraction <= remainingFraction { continue }
            byModel[modelId] = (
                remainingFraction: remainingFraction,
                resetTime: bucket["resetTime"] as? String,
                tokenType: bucket["tokenType"] as? String
            )
        }

        let models = byModel.map { (modelId, info) -> [String: Any] in
            let percentLeft = info.remainingFraction * 100
            return [
                "modelId": modelId,
                "tokenType": info.tokenType ?? "",
                "percentLeft": percentLeft,
                "usedPercent": max(0, 100 - percentLeft),
                "resetAt": info.resetTime ?? "",
                "resetDescription": formatGeminiReset(info.resetTime)
            ]
        }.sorted { ($0["modelId"] as? String ?? "") < ($1["modelId"] as? String ?? "") }

        // Select model groups
        let proModels    = models.filter { ($0["modelId"] as? String ?? "").lowercased().contains("pro") }
        let flashModels  = models.filter { let id = ($0["modelId"] as? String ?? "").lowercased(); return id.contains("flash") && !id.contains("flash-lite") }
        let liteModels   = models.filter { ($0["modelId"] as? String ?? "").lowercased().contains("flash-lite") }

        let lowestPercent = models.compactMap { $0["percentLeft"] as? Double }.min() ?? 100

        var usage = ProviderUsage(provider: "gemini", label: "Gemini CLI")
        usage.accountEmail = creds.accountEmail
        usage.usageAccountId = projectId ?? creds.accountEmail
        usage.accountPlan = parsePlan(tierId, email: creds.accountEmail)
        usage.primary   = selectGeminiWindow(from: proModels)
        usage.secondary = selectGeminiWindow(from: flashModels)
        usage.tertiary  = selectGeminiWindow(from: liteModels)

        usage.extra["projectId"]        = AnyCodable(projectId ?? "")
        usage.extra["lowestPercentLeft"] = AnyCodable(lowestPercent)

        usage.source = source
        return usage
    }

    private func selectGeminiWindow(from models: [[String: Any]]) -> RawQuotaWindow? {
        guard let lowest = models.min(by: { ($0["percentLeft"] as? Double ?? 100) < ($1["percentLeft"] as? Double ?? 100) }) else { return nil }
        let percentLeft = lowest["percentLeft"] as? Double ?? 100
        var window = RawQuotaWindow()
        window.remainingPercent = percentLeft
        window.usedPercent = max(0, 100 - percentLeft)
        window.resetAt = lowest["resetAt"] as? String
        window.resetDescription = lowest["resetDescription"] as? String
        return window
    }

    private func formatGeminiReset(_ resetTime: String?) -> String {
        guard let s = resetTime, let date = SharedFormatters.parseISO8601(s) else { return "Resets soon" }
        let diff = date.timeIntervalSinceNow
        if diff <= 0 { return "Resets soon" }
        let totalMin = Int(diff / 60)
        let hours = totalMin / 60
        let mins = totalMin % 60
        return hours > 0 ? "Resets in \(hours)h \(mins)m" : "Resets in \(mins)m"
    }

    private func parsePlan(_ tierId: String?, email: String?) -> String? {
        guard let tier = tierId else { return email?.hasSuffix(".edu") == true ? "Education" : nil }
        switch tier.lowercased() {
        case "free": return "Free"
        case "standard": return "Standard"
        case "enterprise": return "Enterprise"
        default: return tier.capitalized
        }
    }

    private func normalizeProjectId(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let d = value as? [String: Any] {
            return d["id"] as? String ?? d["projectId"] as? String
        }
        return nil
    }

}
