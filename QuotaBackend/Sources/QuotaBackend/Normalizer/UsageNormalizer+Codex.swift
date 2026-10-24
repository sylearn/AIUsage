import Foundation

extension UsageNormalizer {

    // MARK: - Codex

    static func normalizeCodex(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        var windows: [WindowInfo] = []
        if let w = usage.primary   { windows.append(createPercentWindow(label: w.label ?? "5h Window", window: w)) }
        if let w = usage.secondary { windows.append(createPercentWindow(label: w.label ?? "Weekly Window", window: w)) }
        if let w = usage.tertiary  { windows.append(createPercentWindow(label: "Code Review", window: w)) }

        // 月度消费上限计入告警；按模型的额外限额只列在末尾，和官方 TUI 一样不影响账号状态。
        let extraWindows = codexExtraWindows(usage)
        windows += extraWindows.filter(\.affectsStatus).map(\.info)
        let remainingPercent = pickSmallestRemaining(windows)
        windows += extraWindows.filter { !$0.affectsStatus }.map(\.info)
        let (status, statusLabel) = resolveStatus(remainingPercent)
        let plan = usage.accountPlan.map { titleCase($0) } ?? "Unknown"

        let wsType = (usage.extra["workspaceType"]?.value as? String) ?? CodexProvider.workspaceType(fromPlan: usage.accountPlan)
        let email = usage.accountEmail ?? "OpenAI account"
        let supportingText = wsType == "Personal" ? email : "\(wsType) · \(email)"

        base.accountLabel = preferredAccountEmail(usage)
        base.membershipLabel = membershipBadge(from: plan)
        base.workspaceLabel = wsType
        base.workspaceUserId = usage.extra["userId"]?.value as? String
        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = usage.primary?.resetAt ?? usage.secondary?.resetAt
        base.nextResetLabel = formatShortDateTime(base.nextResetAt)
        base.headline = HeadlineInfo(
            eyebrow: "Plan · \(plan)",
            primary: remainingPercent.map { formatPercent($0) } ?? "Connected",
            secondary: remainingPercent == nil ? "Usage snapshot ready" : "lowest remaining window",
            supporting: supportingText
        )

        var metrics = [
            MetricInfo(label: "Account", value: usage.accountEmail ?? "Unknown"),
            MetricInfo(label: "Plan",    value: plan),
        ]
        if wsType != "Personal" {
            metrics.append(MetricInfo(label: "Workspace", value: wsType))
        }
        if let credits = extraString(usage, "credits") {
            metrics.append(MetricInfo(label: "Credits", value: credits))
        }
        metrics.append(MetricInfo(label: "Source", value: formatSourceLabel(usage.source)))
        base.metrics = metrics

        base.windows = windows
        base.spotlight = "Codex has multiple overlapping guardrails, so the UI surfaces all windows together and uses the tightest one to drive alerting."

        let isTripped = (usage.extra["circuitBreakerTripped"]?.value as? Bool) == true
        if isTripped {
            base.status = "watch"
            base.statusLabel = "Protected (CPA Paused)"
            let reason = extraString(usage, "circuitBreakerReason") ?? "Quota <= 5%"
            base.spotlight = "🛡️ Cầu dao thông minh: Đã tự động tạm ngắt tài khoản này khỏi CLIProxyAPI để bảo toàn hạn mức (\(reason)). Khi quota hồi phục (> 5%), tài khoản sẽ tự động kích hoạt lại."
        }

        return base
    }

    private static func codexExtraWindows(_ usage: ProviderUsage) -> [(info: WindowInfo, affectsStatus: Bool)] {
        guard let items = usage.extra["extraWindows"]?.value as? [AnyCodable] else { return [] }
        return items.compactMap { item in
            guard let dict = item.value as? [String: AnyCodable],
                  let label = dict["label"]?.value as? String,
                  // AnyCodable 解码时先试 Int：整数百分比经过一次编解码会变成 Int。
                  let usedPercent = (dict["usedPercent"]?.value as? NSNumber)?.doubleValue else { return nil }
            var window = RawQuotaWindow()
            window.usedPercent = usedPercent
            window.remainingPercent = max(0, 100 - usedPercent)
            window.resetAt = (dict["resetAt"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 }
            window.resetDescription = (dict["resetDescription"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 }
            let affectsStatus = dict["affectsStatus"]?.value as? Bool ?? false
            return (createPercentWindow(label: label, window: window), affectsStatus)
        }
    }
}
