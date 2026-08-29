import Foundation

// MARK: - MiniMax Token Plan Provider
// 监控 MiniMax Token Plan（订阅 Key 形如 sk-cp-…）的用量额度：5 小时滚动窗口 + 周窗口。
// 数据来源:
//   GET https://api.minimaxi.com/v1/token_plan/remains       （国内区，platform.minimaxi.com）
//   GET https://api.minimax.io/v1/token_plan/remains         （国际区，platform.minimax.io）
//   Header: Authorization: Bearer <Subscription Key (sk-cp-…)>
// 响应结构（取自官方文档 + 实测）：
//   { "model_remains": [
//        {
//          "model_name": "general",                              // 文本/语言模型，主卡片用这个
//          "start_time", "end_time", "remains_time",             // 5h 窗口边界（Unix ms / ms）
//          "current_interval_total_count", "current_interval_usage_count",
//          "current_interval_remaining_percent",
//          "current_interval_status",
//          "weekly_start_time", "weekly_end_time", "weekly_remains_time",
//          "current_weekly_total_count", "current_weekly_usage_count",
//          "current_weekly_remaining_percent",
//          "current_weekly_status",
//          "interval_boost_permille", "weekly_boost_permille"
//        },
//        { "model_name": "video", ... }                         // 视频额度等其它资源
//     ],
//     "base_resp": { "status_code": 0, "status_msg": "success" }
//   }
// 认证: 仅支持订阅 Key（sk-cp-…）。普通按量付费的 sk-… Key 不能查询此接口。

public struct MiniMaxProvider: ProviderFetcher, CredentialAcceptingProvider {
    public let id = "minimax"
    public let displayName = "MiniMax Token Plan"
    public let description = "MiniMax Token Plan subscription usage and rate limits"

    /// 端点：国内区优先，失败后回退国际区。
    static let usageEndpoints = [
        "https://api.minimaxi.com/v1/token_plan/remains",
        "https://api.minimax.io/v1/token_plan/remains"
    ]
    static let userAgent = "AIUsage-MiniMaxMonitor/1.0"

    let timeoutSeconds: Double

    public var supportedAuthMethods: [AuthMethod] { [.apiKey] }

    public init(timeoutSeconds: Double = 15) {
        self.timeoutSeconds = timeoutSeconds
    }

    // MARK: - Fetch Entry Points

    public func fetchUsage() async throws -> ProviderUsage {
        throw ProviderError(
            "not_logged_in",
            "No MiniMax Token Plan key found. Paste a Subscription Key (sk-cp-…) from platform.minimaxi.com → Subscription."
        )
    }

    public func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage {
        guard supportedAuthMethods.contains(credential.authMethod) else {
            throw ProviderError(
                "unsupported_auth_method",
                "MiniMax Token Plan only accepts API key credentials (sk-cp-…)."
            )
        }
        let key = credential.credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw ProviderError("missing_token", "MiniMax Token Plan API key is empty.")
        }
        let region = ProviderAPIRegion(metadataValue: credential.metadata[ProviderAPIRegion.metadataKey])
        return try await fetchUsage(
            apiKey: key,
            source: SourceInfo(mode: "manual", type: "manual-api-key"),
            region: region
        )
    }

    // MARK: - Core

    private func fetchUsage(apiKey: String, source: SourceInfo, region: ProviderAPIRegion) async throws -> ProviderUsage {
        let (root, resolvedRegion) = try await fetchUsageRoot(apiKey: apiKey, region: region)
        let now = Date()

        var usage = ProviderUsage(provider: id, label: displayName)
        usage.source = source
        usage.accountPlan = "Token Plan"

        // 不返回邮箱/账号 ID，用 key 指纹做稳定标识。
        usage.usageAccountId = "minimax-\(KimiProvider.stableFingerprint(apiKey))"

        // 选 model_remains 数组中的 general（文本/语言模型）作为主卡片。
        guard let entry = pickPrimaryEntry(root) else {
            throw ProviderError("empty_usage", "MiniMax Token Plan response did not include any quota entries.")
        }

        // 主窗口 = 5h 滚动；次窗口 = 周。和 Codex/Kimi 卡片保持一致。
        var extra: [String: AnyCodable] = [:]
        let interval = parseIntervalWindow(entry, now: now)
        let weekly = parseWeeklyWindow(entry, now: now)

        if let interval {
            usage.primary = interval
            extra["primaryLabel"] = AnyCodable("5h Window")
            if let weekly {
                usage.secondary = weekly
                extra["secondaryLabel"] = AnyCodable("Weekly Window")
            }
        } else if let weekly {
            usage.primary = weekly
            extra["primaryLabel"] = AnyCodable("Weekly Window")
        }

        guard usage.primary != nil else {
            throw ProviderError("empty_usage", "MiniMax Token Plan response did not include a usable quota window.")
        }

        extra[ProviderAPIRegion.metadataKey] = AnyCodable(resolvedRegion.rawValue)
        usage.extra = extra
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
            chinaContains: ["minimaxi.com"],
            internationalContains: ["minimax.io"]
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
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    lastError = ProviderError("http_error", "MiniMax Token Plan request failed (HTTP \(http.statusCode)).")
                    continue
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    lastError = ProviderError("parse_failed", "MiniMax Token Plan returned invalid JSON.")
                    continue
                }

                // MiniMax 业务层错误编码在 base_resp 里（HTTP 仍是 200）。
                if let base = json["base_resp"] as? [String: Any],
                   let code = KimiProvider.num(base["status_code"])?.rounded(), code != 0 {
                    let msg = KimiProvider.firstString(base, ["status_msg"]) ?? "MiniMax Token Plan error"
                    if Int(code) == 2049 || Int(code) == 1004 {
                        // 2049 invalid api key / 1004 cookie is missing → 跨区域 key，换下一个端点试。
                        sawAuthFailure = true
                        continue
                    }
                    lastError = ProviderError("api_error", msg)
                    continue
                }

                if json["model_remains"] != nil {
                    let resolved: ProviderAPIRegion = endpoint.contains("minimaxi.com") ? .china : .international
                    return (json, resolved)
                }
                lastError = ProviderError("empty_usage", "MiniMax Token Plan response did not include `model_remains`.")
            } catch {
                lastError = error
            }
        }

        if sawAuthFailure {
            throw ProviderError(
                "invalid_credentials",
                regionAuthFailureMessage(region)
            )
        }
        throw lastError ?? ProviderError("unknown_error", "MiniMax Token Plan request failed.")
    }

    private func regionAuthFailureMessage(_ region: ProviderAPIRegion) -> String {
        switch region {
        case .china:
            return "MiniMax Token Plan key was rejected by the China endpoint (api.minimaxi.com). Check the key, or switch to International."
        case .international:
            return "MiniMax Token Plan key was rejected by the International endpoint (api.minimax.io). Check the key, or switch to China."
        case .auto:
            return "MiniMax Token Plan key is invalid or for a different region (China / International)."
        }
    }

    // MARK: - Parsing

    /// 优先取 `model_name == "general"`（文本/语言模型）。其它情况退到数组第一个非 video 的条目。
    private func pickPrimaryEntry(_ root: [String: Any]) -> [String: Any]? {
        guard let list = root["model_remains"] as? [Any] else { return nil }
        let entries = list.compactMap { $0 as? [String: Any] }
        if let general = entries.first(where: { ($0["model_name"] as? String)?.lowercased() == "general" }) {
            return general
        }
        if let nonVideo = entries.first(where: { ($0["model_name"] as? String)?.lowercased() != "video" }) {
            return nonVideo
        }
        return entries.first
    }

    private func parseIntervalWindow(_ entry: [String: Any], now: Date) -> RawQuotaWindow? {
        let limit = KimiProvider.num(entry["current_interval_total_count"])
        let used = KimiProvider.num(entry["current_interval_usage_count"])
        let remainingPercent = KimiProvider.num(entry["current_interval_remaining_percent"])
        let endTime = KimiProvider.num(entry["end_time"])
        let remainsMs = KimiProvider.num(entry["remains_time"])

        if !hasSignal(limit: limit, used: used, remainingPercent: remainingPercent) { return nil }

        var window = RawQuotaWindow()
        applyQuotaSignals(to: &window, limit: limit, used: used, remainingPercent: remainingPercent)
        window.resetAt = resetISOString(endTimeMs: endTime, remainsMs: remainsMs, now: now)
        return window
    }

    private func parseWeeklyWindow(_ entry: [String: Any], now: Date) -> RawQuotaWindow? {
        let limit = KimiProvider.num(entry["current_weekly_total_count"])
        let used = KimiProvider.num(entry["current_weekly_usage_count"])
        let remainingPercent = KimiProvider.num(entry["current_weekly_remaining_percent"])
        let endTime = KimiProvider.num(entry["weekly_end_time"])
        let remainsMs = KimiProvider.num(entry["weekly_remains_time"])

        if !hasSignal(limit: limit, used: used, remainingPercent: remainingPercent) { return nil }

        var window = RawQuotaWindow()
        applyQuotaSignals(to: &window, limit: limit, used: used, remainingPercent: remainingPercent)
        window.resetAt = resetISOString(endTimeMs: endTime, remainsMs: remainsMs, now: now)
        return window
    }

    /// 任一信号存在就值得展示——0/0 但带 99% remaining 也保留，UI 能告知「尚未消耗」。
    private func hasSignal(limit: Double?, used: Double?, remainingPercent: Double?) -> Bool {
        if let limit, limit > 0 { return true }
        if let used, used > 0 { return true }
        if let remainingPercent, remainingPercent >= 0 { return true }
        return false
    }

    private func applyQuotaSignals(
        to window: inout RawQuotaWindow,
        limit: Double?,
        used: Double?,
        remainingPercent: Double?
    ) {
        if let limit { window.entitlement = Int(limit.rounded()) }

        if let limit, limit > 0, let used {
            let usedPct = min(100, max(0, used / limit * 100))
            window.usedPercent = usedPct
            window.remainingPercent = 100 - usedPct
            window.remaining = Int(max(0, limit - used).rounded())
        } else if let remainingPercent {
            // MiniMax 在未激活/未消耗时常返回 percent=99/100 即使 count 为 0。
            // 保留 percent 信号以便 UI 显示「健康」，不臆造 used / remaining 绝对值。
            let clamped = min(100, max(0, remainingPercent))
            window.remainingPercent = clamped
            window.usedPercent = 100 - clamped
        }
    }

    private func resetISOString(endTimeMs: Double?, remainsMs: Double?, now: Date) -> String? {
        if let endTimeMs, endTimeMs > 0 {
            return SharedFormatters.iso8601String(from: Date(timeIntervalSince1970: endTimeMs / 1000))
        }
        if let remainsMs, remainsMs > 0 {
            return SharedFormatters.iso8601String(from: now.addingTimeInterval(remainsMs / 1000))
        }
        return nil
    }
}
