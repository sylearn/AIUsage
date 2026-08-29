import Foundation

// MARK: - Copilot Provider
// 通过 `gh auth token` 获取 GitHub token，再调用 GitHub Copilot API

public struct CopilotProvider: ProviderFetcher, CredentialAcceptingProvider {
    public let id = "copilot"
    public let displayName = "GitHub Copilot"
    public let description = "GitHub Copilot quota usage"

    static let editorPluginVersion = "GitHubCopilotChat/0.26.7"
    static let editorVersion = "vscode/1.96.2"
    static let githubApiVersion = "2025-04-01"

    let timeoutSeconds: Double

    public var supportedAuthMethods: [AuthMethod] { [.token, .auto] }

    public init(timeoutSeconds: Double = 15) {
        self.timeoutSeconds = timeoutSeconds
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let token = try await resolveToken()
        return try await fetchUsage(token: token, source: SourceInfo(mode: "auto", type: "gh-cli"))
    }

    public func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage {
        guard supportedAuthMethods.contains(credential.authMethod) else {
            throw ProviderError("unsupported_auth_method", "Copilot does not support \(credential.authMethod) credentials.")
        }
        let token = credential.credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ProviderError("missing_token", "GitHub token is empty.")
        }
        let sourceType = credential.authMethod == .token ? "manual-token" : "stored-credential"
        return try await fetchUsage(token: token, source: SourceInfo(mode: "manual", type: sourceType))
    }

    private func fetchUsage(token: String, source: SourceInfo) async throws -> ProviderUsage {
        let (payload, email) = try await fetchCopilotData(token: token)
        let quotaSnapshots = normalizeQuotaSnapshots(payload)
        let planResolution = resolvePlan(payload: payload, quotaSnapshots: quotaSnapshots)

        var usage = ProviderUsage(provider: "copilot", label: "GitHub Copilot")
        usage.accountEmail = email
        usage.accountLogin = payload["login"] as? String
        usage.usageAccountId = usage.accountLogin?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        usage.accountPlan = planResolution.displayName

        let quotaResetAt = parseDate(payload["quota_reset_date_utc"] as? String)
            ?? parseDate(payload["quota_reset_date"] as? String)
        let resetDesc = formatResetDescription(quotaResetAt)

        if let primary = quotaSnapshots.premiumInteractions {
            usage.primary = createWindow(primary, resetAt: quotaResetAt, resetDesc: resetDesc)
        }
        if let chat = quotaSnapshots.chat {
            usage.secondary = createWindow(chat, resetAt: quotaResetAt, resetDesc: resetDesc)
        }
        if let completions = quotaSnapshots.completions {
            usage.tertiary = createWindow(completions, resetAt: quotaResetAt, resetDesc: resetDesc)
        }

        var extra: [String: AnyCodable] = [:]
        extra["quotaResetAt"]     = AnyCodable(quotaResetAt.map { SharedFormatters.iso8601String(from: $0) } ?? "")
        extra["resetDescription"] = AnyCodable(resetDesc ?? "")
        extra["copilotPlan"] = AnyCodable(payload["copilot_plan"] as? String ?? "")
        extra["accessTypeSKU"] = AnyCodable(payload["access_type_sku"] as? String ?? "")
        extra["planNote"] = AnyCodable(planResolution.note ?? "")
        usage.extra = extra
        usage.source = source

        return usage
    }

    // MARK: - Token Resolution

    private func resolveToken() async throws -> String {
        // Try gh CLI first (`which` + common paths via shared resolution)
        if let ghPath = CLIExecutableResolution.resolvedExecutable(named: "gh"),
           let token = runCLI(ghPath, args: ["auth", "token"]) {
            let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }

        // Try env var
        if let env = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !env.isEmpty { return env }
        if let env = ProcessInfo.processInfo.environment["GH_TOKEN"], !env.isEmpty { return env }

        // Try hosts.yml
        if let token = readGHHosts() { return token }

        throw ProviderError("not_logged_in", "No GitHub token found. Connect a Copilot account in Settings, or run `gh auth login`.")
    }

    private func runCLI(_ path: String, args: [String]) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch { return nil }
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private func readGHHosts() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [
            "\(home)/.config/gh/hosts.yml",
            "\(home)/.config/gh/hosts.yaml"
        ]
        for path in paths {
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                for prefix in ["oauth_token:", "token:"] {
                    guard trimmed.hasPrefix(prefix) else { continue }
                    var value = String(trimmed.dropFirst(prefix.count))
                    if let commentRange = value.range(of: " #") {
                        value = String(value[..<commentRange.lowerBound])
                    }
                    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if (value.hasPrefix("\"") && value.hasSuffix("\""))
                        || (value.hasPrefix("'") && value.hasSuffix("'")) {
                        value = String(value.dropFirst().dropLast())
                    }
                    if !value.isEmpty { return value }
                }
            }
        }
        return nil
    }

    // MARK: - API Requests

    private func fetchCopilotData(token: String) async throws -> ([String: Any], String?) {
        guard let copilotURL = URL(string: "https://api.github.com/copilot_internal/user") else {
            throw ProviderError("invalid_url", "GitHub Copilot API URL is invalid.")
        }
        var request = QuotaHTTP.request(url: copilotURL, timeout: timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.editorPluginVersion, forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue(Self.editorVersion, forHTTPHeaderField: "Editor-Version")
        request.setValue(Self.editorPluginVersion, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.githubApiVersion, forHTTPHeaderField: "X-Github-Api-Version")

        let (data, response) = try await QuotaHTTP.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderError("invalid_credentials", "GitHub token is invalid or lacks Copilot access.")
        }

        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError("parse_failed", "GitHub Copilot API returned invalid JSON.")
        }

        // Also try to fetch email
        let email = await fetchGitHubEmail(token: token)
        return (payload, email)
    }

    private func fetchGitHubEmail(token: String) async -> String? {
        guard let url = URL(string: "https://api.github.com/user") else { return nil }
        var req = QuotaHTTP.request(url: url, timeout: timeoutSeconds)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.editorPluginVersion, forHTTPHeaderField: "User-Agent")

        guard let (data, _) = try? await QuotaHTTP.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let email = json["email"] as? String, !email.isEmpty { return email }

        // Try /user/emails
        guard let emailsURL = URL(string: "https://api.github.com/user/emails") else { return nil }
        var emailsReq = QuotaHTTP.request(url: emailsURL, timeout: timeoutSeconds)
        emailsReq.setValue("application/json", forHTTPHeaderField: "Accept")
        emailsReq.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        emailsReq.setValue(Self.editorPluginVersion, forHTTPHeaderField: "User-Agent")

        guard let (emailsData, _) = try? await QuotaHTTP.data(for: emailsReq),
              let emails = try? JSONSerialization.jsonObject(with: emailsData) as? [[String: Any]] else { return nil }

        return emails.first(where: { ($0["primary"] as? Bool) == true && ($0["verified"] as? Bool) == true })?["email"] as? String
            ?? emails.first(where: { ($0["verified"] as? Bool) == true })?["email"] as? String
    }

    // MARK: - Quota Snapshot Parsing

    private struct QuotaSnapshots {
        var premiumInteractions: [String: Any]?
        var chat: [String: Any]?
        var completions: [String: Any]?
    }

    private struct PlanResolution {
        let displayName: String?
        let note: String?
    }

    private func resolvePlan(payload: [String: Any], quotaSnapshots: QuotaSnapshots) -> PlanResolution {
        let rawPlan = stringValue(payload["copilot_plan"])
        let accessTypeSKU = stringValue(payload["access_type_sku"])
        let premiumEntitlement = quotaSnapshots.premiumInteractions.map { intValue($0["entitlement"]) }
        let premiumUnlimited = quotaSnapshots.premiumInteractions?["unlimited"] as? Bool ?? false

        if let skuPlan = resolvePlanFromSKU(accessTypeSKU,
                                            premiumEntitlement: premiumEntitlement,
                                            premiumUnlimited: premiumUnlimited) {
            return skuPlan
        }

        if rawPlan?.lowercased() == "individual", let entitlement = premiumEntitlement, entitlement >= 300 {
            return PlanResolution(displayName: "Pro", note: nil)
        }

        return PlanResolution(displayName: formatPlan(rawPlan), note: nil)
    }

    private func resolvePlanFromSKU(_ sku: String?,
                                    premiumEntitlement: Int?,
                                    premiumUnlimited: Bool) -> PlanResolution? {
        guard let sku = sku?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sku.isEmpty else { return nil }

        let normalized = sku.lowercased()
        if normalized.contains("enterprise") {
            return PlanResolution(displayName: "Enterprise", note: nil)
        }
        if normalized.contains("business") || normalized.contains("team") || normalized.contains("organization") {
            return PlanResolution(displayName: "Business", note: nil)
        }
        if normalized.contains("pro_plus") || normalized.contains("plus") {
            return PlanResolution(displayName: "Pro+", note: nil)
        }
        if normalized.contains("educational") || normalized.contains("student") || normalized.contains("teacher") {
            return PlanResolution(displayName: "Pro", note: "GitHub Education access")
        }
        if normalized.contains("pro") || normalized.contains("individual") {
            return PlanResolution(displayName: "Pro", note: nil)
        }
        if normalized.contains("free") {
            if premiumUnlimited || (premiumEntitlement ?? 0) >= 300 {
                return PlanResolution(displayName: "Pro", note: nil)
            }
            return PlanResolution(displayName: "Free", note: nil)
        }
        return nil
    }

    private func normalizeQuotaSnapshots(_ payload: [String: Any]) -> QuotaSnapshots {
        var result = QuotaSnapshots()

        if let snapshots = payload["quota_snapshots"] as? [String: Any] {
            for (key, raw) in snapshots {
                guard let snap = raw as? [String: Any] else { continue }
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                switch normalized {
                case "premiuminteractions": result.premiumInteractions = snap
                case "chat":               result.chat = snap
                case "completions":        result.completions = snap
                default: break
                }
            }
        }

        // Fallback: monthly quotas
        if result.premiumInteractions == nil, result.chat == nil, result.completions == nil {
            if let monthly = payload["monthly_quotas"] as? [String: Any],
               let limited = payload["limited_user_quotas"] as? [String: Any] {
                if let mChat = monthly["chat"] as? Int, let lChat = limited["chat"] as? Int {
                    let pct = mChat > 0 ? Double(lChat) / Double(mChat) * 100 : 0
                    result.chat = ["entitlement": mChat, "remaining": lChat,
                                   "percent_remaining": pct]
                }
                if let mComp = monthly["completions"] as? Int, let lComp = limited["completions"] as? Int {
                    let pct = mComp > 0 ? Double(lComp) / Double(mComp) * 100 : 0
                    result.completions = ["entitlement": mComp, "remaining": lComp,
                                          "percent_remaining": pct]
                }
            }
        }

        // If still no premiumInteractions but have completions, promote it
        if result.premiumInteractions == nil, let c = result.completions {
            result.premiumInteractions = c
            result.completions = nil
        }

        return result
    }

    private func createWindow(_ snap: [String: Any], resetAt: Date?, resetDesc: String?) -> RawQuotaWindow {
        let unlimited = snap["unlimited"] as? Bool ?? false
        let entitlement = intValue(snap["entitlement"])
        let remaining = intValue(snap["remaining"] ?? snap["quota_remaining"])
        let providedPct = doubleValue(snap["percent_remaining"])

        let percentRemaining: Double
        if unlimited {
            percentRemaining = 100
        } else if let p = providedPct {
            percentRemaining = min(100, max(0, p))
        } else if entitlement > 0 {
            percentRemaining = min(100, max(0, Double(remaining) / Double(entitlement) * 100))
        } else {
            percentRemaining = 0
        }

        var window = RawQuotaWindow()
        window.unlimited = unlimited
        window.entitlement = entitlement
        window.remaining = remaining
        window.usedPercent = unlimited ? 0 : max(0, 100 - percentRemaining)
        window.remainingPercent = percentRemaining
        window.resetAt = resetAt.map { SharedFormatters.iso8601String(from: $0) }
        window.resetDescription = resetDesc
        return window
    }

    // MARK: - Helpers

    private func formatPlan(_ raw: String?) -> String? {
        guard let r = raw, !r.isEmpty else { return nil }
        return r.components(separatedBy: CharacterSet(charactersIn: "_-")).map { $0.capitalized }.joined(separator: " ")
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private func formatResetDescription(_ date: Date?) -> String? {
        guard let d = date else { return nil }
        let day = DateFormat.string(from: d, format: "MMM d")
        let time = DateFormat.string(from: d, format: "h:mma")
        return "Resets \(day) at \(time)"
    }

    private func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = SharedFormatters.parseISO8601(s) { return d }
        if let ts = Double(s), ts > 0 {
            let ms = ts > 1_000_000_000_000 ? ts : ts * 1000
            return Date(timeIntervalSince1970: ms / 1000)
        }
        return nil
    }

    private func intValue(_ v: Any?) -> Int {
        switch v {
        case let n as Int: return n
        case let d as Double: return Int(d)
        default: return 0
        }
    }

    private func doubleValue(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let n as Int: return Double(n)
        default: return nil
        }
    }
}
