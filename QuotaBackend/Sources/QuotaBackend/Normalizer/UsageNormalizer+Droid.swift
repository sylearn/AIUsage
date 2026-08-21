import Foundation

extension UsageNormalizer {

    // MARK: - Droid

    static func normalizeDroid(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        let isRateLimitModel = extraString(usage, "billingModel") == "rate-limits"
        var windows: [WindowInfo] = []
        if let w = usage.primary {
            windows.append(createPercentWindow(label: w.label ?? (isRateLimitModel ? "5h Window" : "Standard"), window: w))
        }
        if let w = usage.secondary {
            windows.append(createPercentWindow(label: w.label ?? (isRateLimitModel ? "Weekly Window" : "Premium"), window: w))
        }
        if isRateLimitModel, let w = usage.tertiary {
            windows.append(createPercentWindow(label: w.label ?? "Monthly Window", window: w))
        }

        let remainingPercent = pickSmallestRemaining(windows)
        let (status, statusLabel) = resolveStatus(remainingPercent)
        let planName = extraString(usage, "planName") ?? "Factory usage"
        let orgName = extraString(usage, "organizationName")
        let periodEnd = extraString(usage, "periodEnd")
        let nextReset = usage.primary?.resetAt
            ?? usage.secondary?.resetAt
            ?? usage.tertiary?.resetAt
            ?? periodEnd

        base.accountLabel = preferredAccountEmail(usage)
        base.membershipLabel = membershipBadge(from: planName)
        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = nextReset
        base.nextResetLabel = formatShortDateTime(nextReset)
        base.headline = HeadlineInfo(
            eyebrow: "Plan · \(planName)",
            primary: remainingPercent.map { formatPercent($0) } ?? "Connected",
            secondary: remainingPercent == nil
                ? "Token telemetry ready"
                : (isRateLimitModel ? "lowest remaining rate-limit window" : "lowest remaining token pool"),
            supporting: orgName ?? usage.accountEmail ?? "Factory account"
        )
        base.metrics = droidMetrics(usage: usage, isRateLimitModel: isRateLimitModel, periodEnd: periodEnd)
        base.windows = windows
        base.spotlight = isRateLimitModel
            ? "Factory Individual plans share three rolling windows. A request needs headroom in the 5-hour, weekly, and monthly buckets."
            : "Droid usage is token-heavy, so the panel keeps raw token counts visible next to the percentage-based pools."
        return base
    }

    private static func droidMetrics(
        usage: ProviderUsage,
        isRateLimitModel: Bool,
        periodEnd: String?
    ) -> [MetricInfo] {
        var metrics: [MetricInfo] = []
        if isRateLimitModel {
            if let cents = extraInt(usage, "extraUsageBalanceCents") {
                let dollars = Double(cents) / 100
                metrics.append(MetricInfo(label: "Extra Usage", value: String(format: "$%.2f", dollars)))
            }
            if let preference = extraString(usage, "overagePreference") {
                metrics.append(MetricInfo(label: "When Limit Hits", value: droidOverageLabel(preference)))
            }
        } else {
            let stdUserTokens = extraInt(usage, "standard.userTokens") ?? 0
            let stdTotalAllowance = extraInt(usage, "standard.totalAllowance") ?? 0
            let stdUnlimited = extra(usage, "standard.unlimited") as? Bool ?? false
            let premUserTokens = extraInt(usage, "premium.userTokens") ?? 0
            let premTotalAllowance = extraInt(usage, "premium.totalAllowance") ?? 0
            let premUnlimited = extra(usage, "premium.unlimited") as? Bool ?? false
            let periodStart = extraString(usage, "periodStart")
            metrics.append(MetricInfo(
                label: "Standard Tokens",
                value: "\(formatInt(stdUserTokens)) / \(stdUnlimited ? "Unlimited" : formatInt(stdTotalAllowance))"
            ))
            metrics.append(MetricInfo(
                label: "Premium Tokens",
                value: "\(formatInt(premUserTokens)) / \(premUnlimited ? "Unlimited" : formatInt(premTotalAllowance))"
            ))
            metrics.append(MetricInfo(label: "Billing Period", value: formatRange(periodStart, periodEnd)))
        }
        metrics.append(MetricInfo(label: "Source", value: formatSourceLabel(usage.source)))
        return metrics
    }

    private static func droidOverageLabel(_ preference: String) -> String {
        switch preference {
        case "droidCore": return "Droid Core"
        case "extraUsage": return "Extra Usage"
        default: return preference
        }
    }
}
