import SwiftUI
import QuotaBackend

// MARK: - OpenCode Model Availability Section (issue #27)
// 与 Claude/Codex 节点详情的「模型可用性」分区同款视觉，但数据源是 OpenCodeProxyRuntime
// 的请求日志（按 configId=节点 id 切片）。仅代理模式有逐条日志；直连模式无数据，分区自动隐藏。
// OpenCode 代理日志未记录首字时间（TTFT），故延迟仅展示成功请求的平均响应耗时。

struct OpenCodeNodeAvailabilitySection: View {
    let node: OpenCodeNode
    @ObservedObject var proxyRuntime: OpenCodeProxyRuntime
    @Environment(\.colorScheme) private var colorScheme

    /// 按上游模型聚合的可用率 / 延迟信号。全部来自现有 ProxyRequestLog，无额外埋点。
    private struct ModelStat: Identifiable {
        let id: String
        let model: String
        let requests: Int
        let successful: Int
        /// 成功请求的平均响应耗时（ms）；失败请求不计入，避免错误耗时污染延迟信号。
        let avgResponseMs: Double

        var availability: Double {
            guard requests > 0 else { return 0 }
            return Double(successful) / Double(requests) * 100
        }
    }

    private var models: [ModelStat] {
        let logs = proxyRuntime.logs(forNodeId: node.id)
        guard !logs.isEmpty else { return [] }

        var map: [String: (requests: Int, successful: Int, respTotal: Double)] = [:]
        for log in logs {
            let key = log.upstreamModel.nilIfBlank ?? log.claudeModel
            var acc = map[key] ?? (0, 0, 0)
            acc.requests += 1
            if log.success {
                acc.successful += 1
                acc.respTotal += log.responseTimeMs
            }
            map[key] = acc
        }

        return map.map { key, value in
            ModelStat(
                id: key,
                model: key,
                requests: value.requests,
                successful: value.successful,
                avgResponseMs: value.successful > 0 ? value.respTotal / Double(value.successful) : 0
            )
        }
        .sorted {
            if $0.availability != $1.availability { return $0.availability > $1.availability }
            if $0.requests != $1.requests { return $0.requests > $1.requests }
            return $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending
        }
    }

    var body: some View {
        let stats = models
        if !stats.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text(L("Model Availability", "模型可用性"))
                        .font(.headline.weight(.bold))
                    Spacer()
                    legend
                }

                VStack(spacing: 0) {
                    ForEach(Array(stats.enumerated()), id: \.element.id) { index, model in
                        row(model)
                        if index < stats.count - 1 {
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

    // MARK: - Row & Legend

    private var legend: some View {
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

    private func row(_ model: ModelStat) -> some View {
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
                Text(subtitle(model))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 132, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// 延迟 + 样本量副标题。OpenCode 代理日志无 TTFT，故只展示成功请求的平均响应耗时。
    private func subtitle(_ model: ModelStat) -> String {
        let reqs = L("\(model.requests) reqs", "\(model.requests) 次")
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
}
