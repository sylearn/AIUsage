import SwiftUI
import QuotaBackend

// MARK: - ProxyManagementView Statistics & Recent Requests
// 选中节点展开时的统计卡片网格与最近请求列表（含错误类型徽章）。
// 拆出以控制单文件规模；供 configurationsList 内联调用（family-scoped）。

extension ProxyManagementView {

    // MARK: - Statistics Section

    func statisticsSection(for config: ProxyConfiguration) -> some View {
        let stats = viewModel.statistics[config.id] ?? .empty

        return VStack(alignment: .leading, spacing: 12) {
            Text(L("Statistics", "统计信息"))
                .font(.headline.weight(.bold))

            HStack(spacing: 12) {
                statsCard(
                    title: L("Total Requests", "总请求"),
                    value: "\(stats.totalRequests)",
                    icon: "arrow.up.arrow.down",
                    color: .blue
                )
                statsCard(
                    title: L("Successful", "成功"),
                    value: "\(stats.successfulRequests)",
                    icon: "checkmark.circle",
                    color: .green
                )
                statsCard(
                    title: L("Failed", "失败"),
                    value: "\(stats.failedRequests)",
                    icon: "xmark.circle",
                    color: .red
                )
                statsCard(
                    title: L("Avg TTFT", "平均首字"),
                    value: stats.firstTokenSamples > 0
                        ? String(format: "%.0fms", stats.averageFirstTokenTime)
                        : "—",
                    icon: "bolt.horizontal",
                    color: .orange
                )
            }

            HStack(spacing: 12) {
                statsCard(
                    title: L("Input Tokens", "输入 Tokens"),
                    value: formatCompactNumber(Double(stats.totalTokensInput)),
                    icon: "arrow.down.circle",
                    color: .purple
                )
                statsCard(
                    title: L("Output Tokens", "输出 Tokens"),
                    value: formatCompactNumber(Double(stats.totalTokensOutput)),
                    icon: "arrow.up.circle",
                    color: .pink
                )
                statsCard(
                    title: L("Cache Read", "缓存读取"),
                    value: formatCompactNumber(Double(stats.totalTokensCacheRead)),
                    icon: "arrow.down.doc",
                    color: .orange
                )
                statsCard(
                    title: L("Cache Write", "缓存写入"),
                    value: formatCompactNumber(Double(stats.totalTokensCacheCreation)),
                    icon: "square.and.arrow.down",
                    color: .indigo
                )
            }

            HStack(spacing: 12) {
                let cacheEligible = stats.totalTokensInput + stats.totalTokensCacheRead + stats.totalTokensCacheCreation
                statsCard(
                    title: L("Hit Rate", "命中率"),
                    value: cacheEligible > 0 ? String(format: "%.1f%%", stats.cacheHitRate) : "—",
                    icon: "scope",
                    color: .teal
                )
                statsCard(
                    title: L("Estimated Cost", "预估费用"),
                    value: formatProxyCurrency(stats.estimatedCostUSD),
                    icon: "dollarsign.circle",
                    color: .red
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
    }

    // MARK: - Model Availability Section (issue #27)
    // 按上游模型聚合该节点请求日志的「可用率 + 延迟」信号，帮助在多模型间快速识别哪些更可靠。
    // 数据全部来自现有 ProxyRequestLog（success / responseTimeMs / firstTokenMs），无额外埋点。

    @ViewBuilder
    func modelAvailabilitySection(for config: ProxyConfiguration) -> some View {
        let models = viewModel
            .modelAggregates(nodeFilter: config.id, modelFilter: nil)
            .filter { $0.requests > 0 }
            .sorted {
                if $0.availability != $1.availability { return $0.availability > $1.availability }
                if $0.requests != $1.requests { return $0.requests > $1.requests }
                return $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending
            }

        if !models.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text(L("Model Availability", "模型可用性"))
                        .font(.headline.weight(.bold))
                    Spacer()
                    availabilityLegend
                }

                VStack(spacing: 0) {
                    ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                        modelAvailabilityRow(model)
                        if index < models.count - 1 {
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(AppSurface.card(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(AppStroke.card(colorScheme), lineWidth: 1)
            )
        }
    }

    private var availabilityLegend: some View {
        HStack(spacing: 10) {
            legendDot(color: .green, text: "≥90%")
            legendDot(color: .yellow, text: "50–89%")
            legendDot(color: .red, text: "<50%")
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
    }

    private func modelAvailabilityRow(_ model: ProxyViewModel.ModelAggregate) -> some View {
        let color = availabilityColor(model.availability)
        return HStack(spacing: 12) {
            Image(systemName: availabilityIcon(model.availability))
                .font(.system(size: 14))
                .foregroundStyle(color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.model)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(color)
                            .frame(width: max(2, proxy.size.width * CGFloat(model.availability / 100)))
                    }
                }
                .frame(height: 4)
            }

            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "%.0f%%", model.availability))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text(availabilitySubtitle(model))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 132, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// 延迟 + 样本量副标题：优先展示 TTFT（首字时间，更能反映响应快慢），无流式样本则退回平均总耗时。
    private func availabilitySubtitle(_ model: ProxyViewModel.ModelAggregate) -> String {
        let reqs = L("\(model.requests) reqs", "\(model.requests) 次")
        if let ttft = model.avgFirstTokenMs {
            return "TTFT \(Int(ttft))ms · \(reqs)"
        }
        if model.avgResponseMs > 0 {
            return String(format: "%@ %dms · %@", L("Resp", "响应"), Int(model.avgResponseMs), reqs)
        }
        return reqs
    }

    private func availabilityColor(_ availability: Double) -> Color {
        if availability >= 90 { return .green }
        if availability >= 50 { return .yellow }
        return .red
    }

    private func availabilityIcon(_ availability: Double) -> String {
        if availability >= 90 { return "checkmark.circle.fill" }
        if availability >= 50 { return "exclamationmark.triangle.fill" }
        return "xmark.octagon.fill"
    }

    private func statsCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(Circle().fill(color.opacity(0.12)))

            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))

            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(0.05))
        )
    }

    // MARK: - Recent Requests Section

    func recentRequestsSection(for config: ProxyConfiguration) -> some View {
        let logs = viewModel.recentLogs[config.id] ?? []

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Recent Requests", "最近请求"))
                    .font(.headline.weight(.bold))
                Spacer()
                if !logs.isEmpty {
                    Button(L("Clear", "清除")) {
                        viewModel.clearLogs(for: config.id)
                    }
                    .font(.caption.weight(.semibold))
                }
            }

            if logs.isEmpty {
                Text(L("No requests yet", "暂无请求"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                VStack(spacing: 0) {
                    let displayedLogs = Array(logs.suffix(10).reversed())
                    ForEach(Array(displayedLogs.enumerated()), id: \.element.id) { index, log in
                        requestLogRow(log)
                        if index < displayedLogs.count - 1 {
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
    }

    private func requestLogRow(_ log: ProxyRequestLog) -> some View {
        HStack(spacing: 12) {
            Image(systemName: log.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(log.success ? .green : .red)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(log.upstreamModel)
                        .font(.caption.weight(.semibold))
                    if let surface = requestSurfaceLabel(log.clientSurface) {
                        cacheIndicator(surface, color: requestSurfaceColor(log.clientSurface))
                    }
                    if log.tokensCacheRead > 0 {
                        cacheIndicator(L("Read", "读"), color: .green)
                    }
                    if log.tokensCacheCreation > 0 {
                        cacheIndicator(L("Write", "写"), color: .purple)
                    }
                    if !log.success, let errorType = log.errorType {
                        errorTypeBadge(errorType)
                    }
                }
                if log.success {
                    HStack(spacing: 6) {
                        tokenLabel("In", value: log.tokensInput, color: .blue)
                        tokenLabel("Out", value: log.tokensOutput, color: .cyan)
                        if log.tokensCacheRead > 0 {
                            tokenLabel("CR", value: log.tokensCacheRead, color: .green)
                        }
                        if log.tokensCacheCreation > 0 {
                            tokenLabel("CW", value: log.tokensCacheCreation, color: .purple)
                        }
                    }
                }
                if !log.success, let errorMsg = log.errorMessage, !errorMsg.isEmpty {
                    Text(errorMsg)
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.8))
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Text(String(format: "%.0fms", log.responseTimeMs))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                if log.success {
                    Text(formatProxyCurrency(log.estimatedCostUSD))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                } else if let code = log.statusCode {
                    Text("HTTP \(code)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red.opacity(0.7))
                }
            }

            Text(formatRelativeTime(log.timestamp))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(log.success ? Color.clear : Color.red.opacity(0.04))
        .help(log.success ? "" : (log.errorMessage ?? ""))
    }

    private func requestSurfaceLabel(_ rawValue: String?) -> String? {
        switch rawValue {
        case "claude_code": return "Code"
        case "claude_desktop": return "Desktop"
        case "claude_science": return "Science"
        default: return nil
        }
    }

    private func requestSurfaceColor(_ rawValue: String?) -> Color {
        switch rawValue {
        case "claude_desktop": return Color(red: 0.85, green: 0.45, blue: 0.25)
        case "claude_science": return .purple
        default: return .indigo
        }
    }

    private func cacheIndicator(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func tokenLabel(_ tag: String, value: Int, color: Color) -> some View {
        Text("\(tag) \(formatCompactNumber(Double(value)))")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(color.opacity(0.85))
    }

    // MARK: - Error Type Display

    private func errorTypeBadge(_ type: String) -> some View {
        Text(errorTypeLabel(type))
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(errorTypeColor(type))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(errorTypeColor(type).opacity(0.12)))
    }

    private func errorTypeLabel(_ type: String) -> String {
        switch type {
        case "rate_limit_error": return L("Rate Limited", "限流")
        case "authentication_error": return L("Auth Error", "认证错误")
        case "billing_error": return L("Billing", "计费错误")
        case "permission_error": return L("Permission", "权限错误")
        case "not_found_error": return L("Not Found", "未找到")
        case "request_too_large": return L("Too Large", "请求过大")
        case "timeout_error": return L("Timeout", "超时")
        case "overloaded_error": return L("Overloaded", "过载")
        case "invalid_request_error": return L("Bad Request", "请求无效")
        case "network_error": return L("Network", "网络错误")
        case "api_error": return L("API Error", "API 错误")
        default: return type
        }
    }

    private func errorTypeColor(_ type: String) -> Color {
        switch type {
        case "rate_limit_error": return .orange
        case "authentication_error": return .purple
        case "billing_error": return .red
        case "timeout_error": return .yellow
        case "overloaded_error": return .orange
        case "network_error": return .gray
        default: return .red
        }
    }
}
