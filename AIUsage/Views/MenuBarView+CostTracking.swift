import SwiftUI
import QuotaBackend

// MARK: - MenuBarView Cost Tracking Section
// 各本地 cost 账本（Claude / Codex / OpenCode）的「费用 + 用量」汇总（今日 / 本月 / 总计）。
// 数据源统一为对应本地 cost provider 的 costSummary（refreshCoordinator 已聚合）：
//   · Claude：来自代理用量永久归档（费用与 token 同源）。
//   · Codex：费用 = 代理轨（代理归档）；token = 代理 + 非代理合计，
//     这样非代理用量在费用看不出时也能从 token 列直接看到。
//   · OpenCode：来自本地会话库归档（cost 为 models.dev 定价冻结值，订阅渠道为 0）。
// 「总计」口径 = 归档全历史（比旧的代理保留窗求和更完整）。

extension MenuBarView {

    @ViewBuilder
    var costTrackingSection: some View {
        let rows = costSourceRows
        if !rows.isEmpty {
            let expanded = AppSettings.shared.menuBarCostExpanded
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                MenuBarCollapsibleHeader(
                    title: L("Cost & Usage", "费用 · 用量"),
                    isExpanded: Binding(
                        get: { AppSettings.shared.menuBarCostExpanded },
                        set: { AppSettings.shared.menuBarCostExpanded = $0 }
                    ),
                    collapsedSummary: costCollapsedSummary(rows),
                    summaryColor: Color(red: 0.96, green: 0.55, blue: 0.18)
                )

                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rows) { row in
                            costSourceRow(row)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    /// 收起时的摘要：各工具今日 / 本月费用合计。
    private func costCollapsedSummary(_ rows: [CostSourceRow]) -> String {
        let today = rows.reduce(0) { $0 + ($1.summary.today?.usd ?? 0) }
        let month = rows.reduce(0) { $0 + ($1.summary.month?.usd ?? 0) }
        return L(
            "Today \(formatCostCompact(today)) · Month \(formatCostCompact(month))",
            "今日 \(formatCostCompact(today)) · 本月 \(formatCostCompact(month))"
        )
    }

    /// 一个本地 cost 工具的费用/用量行（数据驱动，新增工具时只需补 descriptor）。
    struct CostSourceRow: Identifiable {
        let id: String
        let label: String
        let iconAsset: String
        let tint: Color
        let summary: CostSummary
    }

    /// 各工具的展示描述：provider id → 品牌名 / 图标 / 配色。
    private static let costSourceDescriptors: [(providerId: String, label: String, iconAsset: String, tint: Color)] = [
        ("claude", "Claude", "claude", Color(red: 0.85, green: 0.45, blue: 0.25)),
        ("codex-cost", "Codex", "codex", Color(red: 0.40, green: 0.52, blue: 0.92)),
        ("opencode", "OpenCode", "opencode", Color(red: 0.18, green: 0.83, blue: 0.75)),
        ("antigravity-cost", "Antigravity", "antigravity", Color(red: 0.20, green: 0.75, blue: 0.95))
    ]

    /// 有费用/用量数据的本地 cost 工具及其 costSummary。
    /// 用 cost provider 而非代理节点判定，故仅有非代理用量（无代理节点）也会展示。
    var costSourceRows: [CostSourceRow] {
        let providers = appState.localCostProviders(from: refreshCoordinator.providers)
        let hiddenIds = AgentVisibility.hiddenCostProviderIds(hidden: AppSettings.shared.hiddenSidebarSections)
        return Self.costSourceDescriptors.compactMap { descriptor in
            guard !hiddenIds.contains(descriptor.providerId) else { return nil }
            guard let summary = providers.first(where: { $0.baseProviderId == descriptor.providerId })?.costSummary else {
                return nil
            }
            return CostSourceRow(
                id: descriptor.providerId,
                label: descriptor.label,
                iconAsset: descriptor.iconAsset,
                tint: descriptor.tint,
                summary: summary
            )
        }
    }

    private func costSourceRow(_ row: CostSourceRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderIconView(row.iconAsset, size: 14)
                Text(row.label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }

            // 今日 / 本月 / 总计：三枚等宽胶囊卡片，各工具上下对齐。
            HStack(spacing: 6) {
                metricChip(L("Today", "今日"), cost: row.summary.today?.usd, tokens: row.summary.today?.tokens, tint: row.tint)
                metricChip(L("Month", "本月"), cost: row.summary.month?.usd, tokens: row.summary.month?.tokens, tint: row.tint)
                metricChip(L("Total", "总计"), cost: row.summary.overall?.usd, tokens: row.summary.overall?.tokens, tint: row.tint)
            }
        }
    }

    /// 单个周期的指标胶囊：内联「标签 · 费用(橙) · 用量」，等宽自适应、不换行不裁切。
    private func metricChip(_ label: String, cost: Double?, tokens: Int?, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(formatCostCompact(cost ?? 0))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
            Text("·")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text((tokens ?? 0) > 0 ? formatCompactNumber(Double(tokens ?? 0)) : "—")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
        )
    }
}
