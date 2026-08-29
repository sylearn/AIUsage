import Foundation

// MARK: - Kimi Code Provider
// 监控 Kimi Code 订阅套餐的用量配额（本周用量 + 频控窗口），与官方 CLI `/usage` 命令同源。
// 数据来源: GET https://api.kimi.com/coding/v1/usages（国内区）
//          GET https://api.moonshot.ai/v1/usages（全球区回退）
//   Header: Authorization: Bearer <Kimi Code API Key 或 OAuth access token>
// 返回结构: { usage: {used, limit, reset_at/reset_in, ...},
//            limits: [{ name, detail:{used, limit}, window:{duration, timeUnit} }] }
//   - usage  → 本周/总额度（primary）
//   - limits → 频控窗口（如 5 小时滚动窗口）（secondary / tertiary）
// 认证: Kimi Code API Key（sk-...，从 https://www.kimi.com/code/console 创建），
//      或从本地 ~/.kimi/config.toml 自动发现。

public struct KimiProvider: ProviderFetcher, CredentialAcceptingProvider {
    public let id = "kimi"
    public let displayName = "Kimi Code"
    public let description = "Kimi Code subscription usage and rate limits"

    /// 用量端点：先国内区，失败再全球区。
    static let usageEndpoints = [
        "https://api.kimi.com/coding/v1/usages",
        "https://api.moonshot.ai/v1/usages"
    ]
    static let userAgent = "AIUsage-KimiMonitor/1.0"

    let timeoutSeconds: Double

    public var supportedAuthMethods: [AuthMethod] { [.apiKey, .auto] }

    public init(timeoutSeconds: Double = 15) {
        self.timeoutSeconds = timeoutSeconds
    }

    // MARK: - Fetch Entry Points

    public func fetchUsage() async throws -> ProviderUsage {
        guard let local = Self.discoverLocalCredentials().first else {
            throw ProviderError(
                "not_logged_in",
                "No Kimi Code API key found. Connect a Kimi Code account in Settings, or run `kimi` to sign in."
            )
        }
        return try await fetchUsage(
            apiKey: local.apiKey,
            source: SourceInfo(mode: "auto", type: "kimi-config"),
            region: .auto
        )
    }

    public func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage {
        guard supportedAuthMethods.contains(credential.authMethod) else {
            throw ProviderError("unsupported_auth_method", "Kimi Code does not support \(credential.authMethod) credentials.")
        }
        let key = credential.credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw ProviderError("missing_token", "Kimi Code API key is empty.")
        }
        let sourceType = credential.authMethod == .apiKey ? "manual-api-key" : "stored-credential"
        let region = ProviderAPIRegion(metadataValue: credential.metadata[ProviderAPIRegion.metadataKey])
        return try await fetchUsage(
            apiKey: key,
            source: SourceInfo(mode: "manual", type: sourceType),
            region: region
        )
    }

    // MARK: - Core

    private func fetchUsage(
        apiKey: String,
        source: SourceInfo,
        region: ProviderAPIRegion
    ) async throws -> ProviderUsage {
        let (root, resolvedRegion) = try await fetchUsageRoot(apiKey: apiKey, region: region)
        let now = Date()

        var usage = ProviderUsage(provider: id, label: displayName)
        usage.source = source

        // 账号身份与会员/模型权限（仅在接口确有返回时填写，不臆造）。
        let email = Self.firstString(root, ["email", "user_email"])
            ?? Self.firstString(Self.dict(root["user"]), ["email"])
        let accountId = Self.firstString(root, ["account_id", "user_id", "id", "uid"])
            ?? Self.firstString(Self.dict(root["user"]), ["id", "user_id"])
        usage.accountEmail = email
        usage.usageAccountId = accountId
            ?? email
            ?? "kimi-\(Self.stableFingerprint(apiKey))"

        if let plan = Self.resolvePlan(root) {
            usage.accountPlan = plan
        }

        // 解析配额窗口。
        let weekly = Self.parseWeeklyWindow(root, now: now)
        var rateLimits = Self.parseRateLimitWindows(root, now: now) // 按时长升序，最短（5 小时）在前

        // 对齐 Codex：主窗口 = 最紧的滚动频控窗口（官方「5 小时内最多可使用额度」），
        // 次窗口 = 周限。这样卡片首行就是 5 小时额度、第二行才是 7 天/本周。
        var extra: [String: AnyCodable] = [:]
        if !rateLimits.isEmpty {
            usage.primary = rateLimits.removeFirst().window
            extra["primaryLabel"] = AnyCodable("5h Window")
            if let w = weekly {
                usage.secondary = w.window
                extra["secondaryLabel"] = AnyCodable("Weekly Window")
            }
            if let next = rateLimits.first {
                usage.tertiary = next.window
                extra["tertiaryLabel"] = AnyCodable(next.label)
            }
        } else if let w = weekly {
            // 没有频控窗口时退回只展示周限。
            usage.primary = w.window
            extra["primaryLabel"] = AnyCodable("Weekly Window")
        }

        if let model = Self.resolveModelEntitlement(root) { extra["modelEntitlement"] = AnyCodable(model) }
        extra[ProviderAPIRegion.metadataKey] = AnyCodable(resolvedRegion.rawValue)
        usage.extra = extra

        guard usage.primary != nil else {
            throw ProviderError("empty_usage", "Kimi Code usage response did not include any quota windows.")
        }
        return usage
    }

    private func fetchUsageRoot(
        apiKey: String,
        region: ProviderAPIRegion
    ) async throws -> (root: [String: Any], resolved: ProviderAPIRegion) {
        var sawAuthFailure = false
        var lastError: Error?
        let endpoints = region.orderedEndpoints(
            Self.usageEndpoints,
            chinaContains: ["api.kimi.com"],
            internationalContains: ["moonshot.ai"]
        )
        let candidates = region.allowsCrossRegionFallback ? endpoints : Array(endpoints.prefix(1))

        for endpoint in candidates {
            guard let url = URL(string: endpoint) else { continue }
            var request = QuotaHTTP.request(url: url, timeout: timeoutSeconds)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await QuotaHTTP.data(for: request)
                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 401 || http.statusCode == 403 {
                        // 可能只是区域不匹配（国内 key 打到了全球端点），换下一个端点重试。
                        sawAuthFailure = true
                        continue
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        lastError = ProviderError("http_error", "Kimi Code usage request failed (HTTP \(http.statusCode)).")
                        continue
                    }
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    lastError = ProviderError("parse_failed", "Kimi Code usage endpoint returned invalid JSON.")
                    continue
                }

                let root = Self.dict(json["data"]) ?? json
                if root["usage"] != nil || root["limits"] != nil {
                    let resolved: ProviderAPIRegion = endpoint.contains("api.kimi.com") ? .china : .international
                    return (root, resolved)
                }
                lastError = ProviderError("empty_usage", "Kimi Code usage response did not include any quota windows.")
            } catch {
                lastError = error
            }
        }

        if sawAuthFailure {
            throw ProviderError("invalid_credentials", regionAuthFailureMessage(region))
        }
        throw lastError ?? ProviderError("unknown_error", "Kimi Code usage request failed.")
    }

    private func regionAuthFailureMessage(_ region: ProviderAPIRegion) -> String {
        switch region {
        case .china:
            return "Kimi Code API key was rejected by the China endpoint (api.kimi.com). Check the key, or switch to International."
        case .international:
            return "Kimi Code API key was rejected by the International endpoint (api.moonshot.ai). Check the key, or switch to China."
        case .auto:
            return "Kimi Code API key is invalid or unauthorized for both the China and global endpoints."
        }
    }

    // MARK: - Parsing

    struct ParsedWindow {
        let label: String
        let durationSeconds: Double?
        let window: RawQuotaWindow
    }

    static func parseWeeklyWindow(_ root: [String: Any], now: Date) -> ParsedWindow? {
        guard let usage = dict(root["usage"]) else { return nil }
        guard let window = makeWindow(detail: usage, windowMeta: dict(usage["window"]), now: now) else { return nil }
        let label = firstString(usage, ["name", "title", "label"]) ?? "Weekly"
        return ParsedWindow(label: label, durationSeconds: 7 * 86400, window: window)
    }

    /// 解析 `limits` 数组，按窗口时长升序（最短/最紧的频控窗口排前）。
    static func parseRateLimitWindows(_ root: [String: Any], now: Date) -> [ParsedWindow] {
        guard let limits = root["limits"] as? [Any] else { return [] }
        var parsed: [ParsedWindow] = []
        for item in limits {
            guard let item = item as? [String: Any] else { continue }
            let detail = dict(item["detail"]) ?? item
            let meta = dict(item["window"])
            guard let window = makeWindow(detail: detail, windowMeta: meta, now: now) else { continue }
            let durationSeconds = windowDurationSeconds(meta)
            let label = firstString(item, ["name", "title", "scope"])
                ?? firstString(detail, ["name", "title"])
                ?? durationLabel(meta)
                ?? "Rate limit"
            parsed.append(ParsedWindow(label: label, durationSeconds: durationSeconds, window: window))
        }
        parsed.sort { (lhs, rhs) in
            switch (lhs.durationSeconds, rhs.durationSeconds) {
            case let (l?, r?): return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.label < rhs.label
            }
        }
        return parsed
    }

    static func makeWindow(detail: [String: Any], windowMeta: [String: Any]?, now: Date) -> RawQuotaWindow? {
        let limit = num(detail["limit"]) ?? num(detail["total"]) ?? num(detail["quota"])
        var used = num(detail["used"]) ?? num(detail["consumed"])
        let remaining = num(detail["remaining"]) ?? num(detail["left"])
        if used == nil, let r = remaining, let l = limit { used = max(0, l - r) }

        guard used != nil || limit != nil || remaining != nil else { return nil }

        var window = RawQuotaWindow()
        if let l = limit { window.entitlement = Int(l.rounded()) }

        if let u = used, let l = limit, l > 0 {
            let usedPct = min(100, max(0, u / l * 100))
            window.usedPercent = usedPct
            window.remainingPercent = 100 - usedPct
            window.remaining = Int(max(0, l - u).rounded())
        } else if let r = remaining, let l = limit, l > 0 {
            let remPct = min(100, max(0, r / l * 100))
            window.remainingPercent = remPct
            window.usedPercent = 100 - remPct
            window.remaining = Int(r.rounded())
        } else if let r = remaining {
            window.remaining = Int(r.rounded())
        }

        if let resetDate = parseResetDate(detail, now: now) ?? windowMeta.flatMap({ parseResetDate($0, now: now) }) {
            window.resetAt = SharedFormatters.iso8601String(from: resetDate)
        }
        return window
    }

    // MARK: - Reset / Duration Helpers

    static func parseResetDate(_ data: [String: Any], now: Date) -> Date? {
        let timeKeys = ["reset_at", "resetAt", "reset_time", "resetTime", "next_reset_at"]
        for key in timeKeys {
            guard let value = data[key] else { continue }
            if let text = value as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                if let date = SharedFormatters.parseISO8601(text) { return date }
                if let epoch = Double(text.trimmingCharacters(in: .whitespaces)) {
                    return epochDate(epoch)
                }
            }
            if let epoch = num(value) { return epochDate(epoch) }
        }
        let secondKeys = ["reset_in", "resetIn", "reset_in_seconds", "ttl", "remaining_seconds"]
        for key in secondKeys {
            if let seconds = num(data[key]), seconds >= 0 {
                return now.addingTimeInterval(seconds)
            }
        }
        return nil
    }

    private static func epochDate(_ value: Double) -> Date {
        // > 10^12 视为毫秒级。
        let seconds = value > 1_000_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    static func windowDurationSeconds(_ meta: [String: Any]?) -> Double? {
        guard let meta, let duration = num(meta["duration"]) else { return nil }
        let unit = (firstString(meta, ["timeUnit", "time_unit", "unit"]) ?? "").uppercased()
        if unit.contains("MINUTE") { return duration * 60 }
        if unit.contains("HOUR") { return duration * 3600 }
        if unit.contains("DAY") { return duration * 86400 }
        if unit.contains("SECOND") { return duration }
        return duration
    }

    static func durationLabel(_ meta: [String: Any]?) -> String? {
        guard let meta, let duration = num(meta["duration"]) else { return nil }
        let unit = (firstString(meta, ["timeUnit", "time_unit", "unit"]) ?? "").uppercased()
        let n = Int(duration.rounded())
        if unit.contains("MINUTE") {
            if n >= 60, n % 60 == 0 { return "\(n / 60)h limit" }
            return "\(n)m limit"
        }
        if unit.contains("HOUR") { return "\(n)h limit" }
        if unit.contains("DAY") { return "\(n)d limit" }
        if unit.contains("SECOND") { return "\(n)s limit" }
        return nil
    }

    // MARK: - Plan / Model Entitlement

    private static func resolvePlan(_ root: [String: Any]) -> String? {
        let keys = ["plan", "plan_name", "subscription_plan", "tier", "membership", "level", "product"]
        for key in keys {
            if let value = firstString(root, [key]) { return value }
        }
        if let sub = dict(root["subscription"]) {
            return firstString(sub, ["name", "plan", "tier", "level"])
        }
        return nil
    }

    private static func resolveModelEntitlement(_ root: [String: Any]) -> String? {
        if let value = firstString(root, ["model", "model_name", "default_model", "flagship_model"]) {
            return value
        }
        if let models = root["models"] as? [Any] {
            let names = models.compactMap { ($0 as? [String: Any]).flatMap { firstString($0, ["name", "id", "display_name"]) } ?? ($0 as? String) }
            if !names.isEmpty { return names.joined(separator: ", ") }
        }
        return nil
    }

    // MARK: - Local Discovery (~/.kimi/config.toml)

    public struct KimiLocalCredential: Sendable {
        public let apiKey: String
        public let sourcePath: String
        public let providerSection: String?
    }

    /// 从 `~/.kimi/config.toml` 里发现 Kimi Code 的 API Key（kimi-cli `/login` 后写入）。
    public static func discoverLocalCredentials() -> [KimiLocalCredential] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/.kimi/config.toml"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }

        var results: [KimiLocalCredential] = []
        var section: String?
        var sectionType: String?
        var sectionBaseURL: String?
        var sectionKey: String?

        func flush() {
            defer { sectionType = nil; sectionBaseURL = nil; sectionKey = nil }
            guard let key = sectionKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
            let lowerSection = section?.lowercased() ?? ""
            let lowerBase = sectionBaseURL?.lowercased() ?? ""
            let isKimiCode = sectionType?.lowercased() == "kimi"
                || lowerSection.contains("kimi")
                || lowerBase.contains("kimi.com/coding")
                || lowerBase.contains("moonshot")
                || key.hasPrefix("sk-kimi")
            guard isKimiCode else { return }
            results.append(KimiLocalCredential(apiKey: key, sourcePath: path, providerSection: section))
        }

        for rawLine in content.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                flush()
                section = String(line.dropFirst().dropLast())
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let rawKey = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let rawValue = tomlString(String(line[line.index(after: eq)...]))
            switch rawKey {
            case "api_key", "apikey": sectionKey = rawValue
            case "type": sectionType = rawValue
            case "base_url", "baseurl": sectionBaseURL = rawValue
            default: break
            }
        }
        flush()

        // 按 apiKey 去重，保留首次出现。
        var seen = Set<String>()
        return results.filter { seen.insert($0.apiKey).inserted }
    }

    private static func tomlString(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        guard let first = value.first, first == "\"" || first == "'" else {
            if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
            return value.trimmingCharacters(in: .whitespaces)
        }
        value.removeFirst()
        if let end = value.firstIndex(of: first) { return String(value[..<end]) }
        return value
    }

    // MARK: - Value Helpers

    static func dict(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func num(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : Double(trimmed)
        default: return nil
        }
    }

    static func firstString(_ dict: [String: Any]?, _ keys: [String]) -> String? {
        guard let dict else { return nil }
        for key in keys {
            switch dict[key] {
            case let s as String:
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            case let n as NSNumber:
                return n.stringValue
            default:
                continue
            }
        }
        return nil
    }

    /// 稳定指纹（FNV-1a），用于在无账号标识时区分不同 API Key 账号。
    static func stableFingerprint(_ string: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash))
    }
}
