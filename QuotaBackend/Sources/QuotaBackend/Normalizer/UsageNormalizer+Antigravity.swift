import Foundation

extension UsageNormalizer {

    // MARK: - Antigravity

    static func normalizeAntigravity(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        let trackedModels = extraTrackedModels(usage)
        let windows = trackedModels.map { model in
            WindowInfo(
                label: model.label,
                remainingPercent: model.remainingPercent,
                usedPercent: max(0, 100 - model.remainingPercent),
                value: "\(formatPercent(model.remainingPercent)) left",
                note: joinParts([model.providerLabel, formatShortDateTime(model.resetAt)]) ?? formatShortDateTime(model.resetAt) ?? "Live snapshot",
                resetAt: model.resetAt
            )
        }

        let coreModels = trackedModels.filter {
            !$0.label.localizedCaseInsensitiveContains("argon")
        }
        let primaryModels = coreModels.isEmpty ? trackedModels : coreModels
        let remainingPercent = primaryModels.map(\.remainingPercent).min() ?? pickSmallestRemaining(windows)
        let (status, statusLabel) = resolveStatus(remainingPercent)
        let plan = usage.accountPlan ?? "Unknown"
        let projectId = extraString(usage, "projectId")
        let modelCount = extraInt(usage, "modelCount") ?? trackedModels.count
        let authFileCount = extraInt(usage, "authFileCount") ?? 1
        let selectedAuthFile = extraString(usage, "selectedAuthFile")
        let isGrouped = extraString(usage, "quotaSource") == "groups"

        base.accountLabel = preferredAccountEmail(usage)
        base.membershipLabel = membershipBadge(from: plan)
        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = primaryModels.compactMap { $0.resetAt }.compactMap(parseDate).min().map { SharedFormatters.iso8601String(from: $0) }
        base.nextResetLabel = formatShortDateTime(base.nextResetAt)
        base.headline = HeadlineInfo(
            eyebrow: "Plan · \(plan)",
            primary: remainingPercent.map { formatPercent($0) } ?? "Connected",
            secondary: remainingPercent == nil
                ? "Antigravity quota snapshot"
                : (isGrouped ? "lowest remaining window" : "lowest remaining model"),
            supporting: usage.accountEmail ?? projectId ?? "CLIProxy auth file"
        )
        base.metrics = [
            MetricInfo(label: "Account", value: usage.accountEmail ?? "Unknown"),
            MetricInfo(label: "Project", value: projectId ?? "Unknown"),
            MetricInfo(label: isGrouped ? "Quota Windows" : "Tracked Models", value: formatInt(modelCount)),
            MetricInfo(label: "Source", value: formatSourceLabel(usage.source))
        ]
        base.windows = windows
        // retrieveUserQuotaSummary 返回的 4-5 个分组窗口已在 `windows` 区完整展示，
        // 再复制到 `models` 区会造成同屏重复；仅对旧 per-model 回退路径保留模型列表。
        base.models = trackedModels.isEmpty || isGrouped ? nil : trackedModels.map {
            ModelInfo(
                label: $0.label,
                value: formatPercent($0.remainingPercent),
                note: joinParts([$0.providerLabel, formatShortDateTime($0.resetAt)])
            )
        }
        base.spotlight = authFileCount > 1
            ? "Antigravity auth files detected: \(formatInt(authFileCount)). This snapshot uses the most recently updated file (\(selectedAuthFile ?? "unknown"))."
            : (isGrouped
                ? "Antigravity groups models into shared 5-hour and weekly pools, and places the tightest window first."
                : "Antigravity exposes per-model quotas, so the dashboard keeps each model separate and puts the tightest ones first.")

        let isTripped = (usage.extra["circuitBreakerTripped"]?.value as? Bool) == true
        let isPartialTripped = (usage.extra["circuitBreakerPartialTripped"]?.value as? Bool) == true
        let trippedPool = extraString(usage, "circuitBreakerTrippedPool")
        let reason = extraString(usage, "circuitBreakerReason") ?? "Quota <= 5%"

        if isTripped {
            base.status = "watch"
            base.statusLabel = "Protected (CPA Paused)"
            base.spotlight = "🛡️ Cầu dao thông minh: Đã tự động tạm ngắt toàn bộ tài khoản này khỏi CLIProxyAPI để chống ban (\(reason)). Khi quota hồi phục, tài khoản sẽ tự động kích hoạt lại."
        } else if isPartialTripped {
            base.status = "watch"
            if trippedPool == "claude" {
                base.statusLabel = "Claude Paused (Gemini Active)"
                base.spotlight = "🛡️ Cầu dao thông minh (Đa tầng): Đã tạm ngắt model Claude khỏi CLIProxyAPI (\(reason)). Các model Gemini của tài khoản này vẫn hoạt động bình thường cho bot RonC & Hermes."
            } else if trippedPool == "gemini" {
                base.statusLabel = "Gemini Paused (Claude Active)"
                base.spotlight = "🛡️ Cầu dao thông minh (Đa tầng): Đã tạm ngắt model Gemini khỏi CLIProxyAPI (\(reason)). Các model Claude của tài khoản này vẫn hoạt động bình thường."
            }
        }

        return base
    }
}
