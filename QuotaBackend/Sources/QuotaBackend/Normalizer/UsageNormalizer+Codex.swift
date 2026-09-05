import Foundation

extension UsageNormalizer {

    // MARK: - Codex

    static func normalizeCodex(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        var windows: [WindowInfo] = []
        if let w = usage.primary   { windows.append(createPercentWindow(label: w.label ?? "5h Window", window: w)) }
        if let w = usage.secondary { windows.append(createPercentWindow(label: w.label ?? "Weekly Window", window: w)) }
        if let w = usage.tertiary  { windows.append(createPercentWindow(label: "Code Review", window: w)) }

        let remainingPercent = pickSmallestRemaining(windows)
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
        metrics.append(MetricInfo(label: "Source", value: formatSourceLabel(usage.source)))
        base.metrics = metrics

        base.windows = windows
        base.spotlight = "Codex has multiple overlapping guardrails, so the UI surfaces all windows together and uses the tightest one to drive alerting."
        return base
    }
}
