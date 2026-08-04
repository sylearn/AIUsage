import SwiftUI

// MARK: - Summary Strip
// 统计摘要条：费用、Tokens、缓存命中率、输入/输出 Tokens、模型数。

extension ProxyStatsView {

    var summaryStrip: some View {
        // 时间段与口径已统一到顶部控制台：摘要条同样跟随选定的 period。
        let overall = Self.adapter.overallStats(from: summary, period: period)
        let range = Self.adapter.dataDateRange(from: summary)

        return VStack(spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                if showsCost {
                    summaryCell(
                        icon: "dollarsign.circle.fill",
                        title: "\(L("Cost", "费用")) · \(period.label)",
                        value: formatCurrency(overall.cost),
                        tint: .orange
                    )
                }
                summaryCell(
                    icon: "bolt.fill",
                    title: "Tokens · \(period.label)",
                    value: formatCompactNumber(Double(overall.tokens)),
                    tint: .purple
                )
                summaryCell(
                    icon: "scope",
                    title: L("Cache Hit Rate", "缓存命中率"),
                    value: overall.cacheTokens + overall.inputTokens > 0
                        ? String(format: "%.1f%%", overall.cacheHitRate)
                        : "—",
                    tint: .teal
                )
                summaryCell(
                    icon: "arrow.down.doc.fill",
                    title: L("Input Tokens", "输入 Tokens"),
                    value: formatCompactNumber(Double(overall.inputTokens)),
                    tint: .blue
                )
                summaryCell(
                    icon: "arrow.up.doc.fill",
                    title: L("Output Tokens", "输出 Tokens"),
                    value: formatCompactNumber(Double(overall.outputTokens)),
                    tint: .green
                )
                summaryCell(
                    icon: "cpu",
                    title: L("Models", "模型数"),
                    value: "\(overall.modelCount)",
                    tint: .pink
                )
            }
            dataRangeBanner(range: range)
        }
    }

    func summaryCell(icon: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(AppSurface.card(colorScheme)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppStroke.card(colorScheme), lineWidth: 1))
    }

    // MARK: - Data Range Banner

    private static let bannerDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd"
        return df
    }()

    @ViewBuilder
    func dataRangeBanner(range: (earliest: Date?, latest: Date?, days: Int)) -> some View {
        if let earliest = range.earliest {
            let df = Self.bannerDateFormatter
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(L("Data covers \(range.days) day(s) (\(df.string(from: earliest)) – \(df.string(from: range.latest ?? Date()))).",
                       "数据覆盖 \(range.days) 天（\(df.string(from: earliest)) – \(df.string(from: range.latest ?? Date()))）。"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
        }
    }
}
