import SwiftUI
import Charts

// MARK: - Distribution & Model Details
// 模型分布饼图 + 模型详情表格，数据来源为 JSONL modelBreakdown。

extension ProxyStatsView {

    // MARK: - Data

    var modelData: [StatsDataAdapter.ModelAggregate] {
        Self.adapter.modelAggregates(from: summary, period: period)
            .sorted { lhs, rhs in
                let lv = effectiveMetric == .cost ? lhs.cost : Double(lhs.tokens)
                let rv = effectiveMetric == .cost ? rhs.cost : Double(rhs.tokens)
                if lv == rv { return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending }
                return lv > rv
            }
    }

    func distributionValue(_ item: StatsDataAdapter.ModelAggregate) -> Double {
        effectiveMetric == .cost ? item.cost : Double(item.tokens)
    }

    func distributionShare(_ item: StatsDataAdapter.ModelAggregate, total: Double) -> Double {
        guard total > 0 else { return 0 }
        return distributionValue(item) / total * 100
    }

    func distributionValueText(_ item: StatsDataAdapter.ModelAggregate) -> String {
        effectiveMetric == .cost
            ? modelCostText(item)
            : formatCompactNumber(Double(item.tokens))
    }

    /// 非代理模型（合计轨里带 " (Non-Proxy)" 后缀）不监控价格，费用列以 "—" 呈现而非 $0.0000。
    func modelCostText(_ item: StatsDataAdapter.ModelAggregate) -> String {
        UsageTrack.isNonProxy(item.model) ? "—" : formatCurrency(item.cost)
    }

    // MARK: - Layout

    var splitDistributionWidth: CGFloat {
        let available = max(contentWidth, 980)
        return min(max(available * 0.34, 320), 380)
    }

    func distributionChartHeight(for layout: InsightsLayout) -> CGFloat {
        layout == .split ? 210 : 225
    }

    // MARK: - Panels

    func insightPanelsSection(colorMap: [String: Color], sparklineMap: [String: [Double]]) -> some View {
        let data = modelData
        let distTotal = data.reduce(0.0) { $0 + distributionValue($1) }
        return Group {
            if usesStackedInsightsLayout {
                VStack(alignment: .leading, spacing: 16) {
                    modelDistribution(layout: .stacked, data: data, colorMap: colorMap, distTotal: distTotal)
                    modelTable(layout: .stacked, data: data, colorMap: colorMap, distTotal: distTotal, sparklineMap: sparklineMap)
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    modelDistribution(layout: .split, data: data, colorMap: colorMap, distTotal: distTotal)
                        .frame(width: splitDistributionWidth, alignment: .topLeading)
                    modelTable(layout: .split, data: data, colorMap: colorMap, distTotal: distTotal, sparklineMap: sparklineMap)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .layoutPriority(1)
                }
            }
        }
    }

    // MARK: - Distribution Pie Chart

    func modelDistribution(layout: InsightsLayout, data: [StatsDataAdapter.ModelAggregate], colorMap: [String: Color], distTotal: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Model Distribution", "模型分布"))
                    .font(.headline.weight(.bold))
                Spacer()
                // 时间段/口径已统一到顶部控制台，这里仅以小字回显当前视图。
                Text(distributionContextLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if data.isEmpty {
                Text(L("No data yet", "暂无数据"))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else {
                Chart(Array(data.prefix(6)), id: \.id) { item in
                    SectorMark(
                        angle: .value(effectiveMetric == .cost ? "Cost" : "Tokens", max(distributionValue(item), 0.001)),
                        innerRadius: .ratio(0.55),
                        angularInset: 1.5
                    )
                    .foregroundStyle(colorForModel(item.model, from: colorMap))
                    .cornerRadius(4)
                    .annotation(position: .overlay) {
                        let share = distributionShare(item, total: distTotal)
                        if share >= 10 {
                            Text(String(format: "%.0f%%", share))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .frame(height: distributionChartHeight(for: layout))

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(data.prefix(6)), id: \.id) { item in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(colorForModel(item.model, from: colorMap))
                                .frame(width: 8, height: 8)
                            Text(item.model)
                                .font(.caption).lineLimit(1).truncationMode(.middle)
                                .help(item.model)
                            Spacer()
                            Text(distributionValueText(item))
                                .font(.caption.weight(.medium).monospacedDigit())
                                .foregroundStyle(colorForModel(item.model, from: colorMap))
                            Text(String(format: "%.1f%%", distributionShare(item, total: distTotal)))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18).fill(AppSurface.card(colorScheme)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppStroke.card(colorScheme), lineWidth: 1))
    }

    /// 模型分布/详情当前视图回显：时间段 · 口径（非代理轨只显示 Tokens 口径）。
    var distributionContextLabel: String {
        let metricLabel = effectiveMetric == .cost ? L("Cost", "费用") : "Tokens"
        return "\(period.label) · \(metricLabel)"
    }

    // MARK: - Model Table

    // 模型名列：自适应但封顶——既不再独吞整行（旧 maxWidth:.infinity 会留大片空白），
    // 又给到足够宽度完整显示常见模型全称（超长才中间截断）；多余空间交给趋势列。
    var modelNameColumnMinWidth: CGFloat { 140 }
    var modelNameColumnMaxWidth: CGFloat { 320 }

    func modelTable(layout: InsightsLayout, data: [StatsDataAdapter.ModelAggregate], colorMap: [String: Color], distTotal: Double, sparklineMap: [String: [Double]]) -> some View {
        let costW = showsCost ? tableColumnWidth(.cost, layout: layout) : 0
        let tokensW = tableColumnWidth(.tokens, layout: layout)
        let shareW = tableColumnWidth(.share, layout: layout)

        return VStack(alignment: .leading, spacing: 12) {
            Text(L("Model Details", "模型详情"))
                .font(.headline.weight(.bold))

            if data.isEmpty {
                Text(L("No data yet", "暂无数据"))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else {
                LazyVStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text(L("Model", "模型"))
                            .frame(minWidth: modelNameColumnMinWidth, maxWidth: modelNameColumnMaxWidth, alignment: .leading)
                        if showsCost {
                            Text(L("Cost", "费用")).frame(width: costW, alignment: .trailing)
                        }
                        Text("Tokens").frame(width: tokensW, alignment: .trailing)
                        Text(L("Share", "占比")).frame(width: shareW, alignment: .trailing)
                        Text(L("Trend", "趋势")).frame(maxWidth: .infinity, alignment: .center)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)

                    Divider()

                    ForEach(Array(data.enumerated()), id: \.element.id) { index, item in
                        let itemColor = colorForModel(item.model, from: colorMap)
                        modelRow(item, color: itemColor,
                                 costWidth: costW, tokensWidth: tokensW,
                                 shareWidth: shareW,
                                 distTotal: distTotal,
                                 sparkValues: sparklineMap[item.model] ?? [])

                        if expandedModels.contains(item.model) {
                            modelDetailRow(item, color: itemColor)
                        }

                        if index < data.count - 1 {
                            Divider().padding(.horizontal, 8)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18).fill(AppSurface.card(colorScheme)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppStroke.card(colorScheme), lineWidth: 1))
    }

    func tableColumnWidth(_ column: TableColumn, layout: InsightsLayout) -> CGFloat {
        switch (layout, column) {
        case (.split, .cost): return 88
        case (.split, .tokens): return 86
        case (.split, .share): return 62
        case (.split, .trend): return 70
        case (.stacked, .cost): return 94
        case (.stacked, .tokens): return 92
        case (.stacked, .share): return 68
        case (.stacked, .trend): return 76
        }
    }

    enum TableColumn { case cost, tokens, share, trend }

    // MARK: - Model Row

    func modelRow(
        _ item: StatsDataAdapter.ModelAggregate,
        color: Color,
        costWidth: CGFloat, tokensWidth: CGFloat,
        shareWidth: CGFloat,
        distTotal: Double,
        sparkValues: [Double]
    ) -> some View {
        let isExpanded = expandedModels.contains(item.model)

        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Circle().fill(color).frame(width: 8, height: 8)
                Text(item.model)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .help(item.model)
                Spacer(minLength: 0)
            }
            .frame(minWidth: modelNameColumnMinWidth, maxWidth: modelNameColumnMaxWidth, alignment: .leading)

            if showsCost {
                let isNonProxy = UsageTrack.isNonProxy(item.model)
                Text(modelCostText(item))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(isNonProxy ? Color.secondary : Color.primary)
                    .frame(width: costWidth, alignment: .trailing)
            }

            Text(formatCompactNumber(Double(item.tokens)))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: tokensWidth, alignment: .trailing)

            Text(String(format: "%.1f%%", distributionShare(item, total: distTotal)))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(color)
                .frame(width: shareWidth, alignment: .trailing)

            MiniSparkline(values: sparkValues, color: color)
                .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
                .padding(.leading, 8)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isExpanded { expandedModels.remove(item.model) }
                else { expandedModels.insert(item.model) }
            }
        }
        .background(
            (isExpanded || selectedModels.contains(item.model))
                ? RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08))
                : nil
        )
    }

    // MARK: - Model Detail Row

    func modelDetailRow(_ item: StatsDataAdapter.ModelAggregate, color: Color) -> some View {
        let cacheEligible = item.inputTokens + item.cacheReadTokens + item.cacheCreationTokens
        let hitRate = cacheEligible > 0 ? String(format: "%.1f%%", item.cacheHitRate) : "—"
        let details: [(String, String, Color)] = [
            (L("Input", "输入"), formatCompactNumber(Double(item.inputTokens)), .blue),
            (L("Output", "输出"), formatCompactNumber(Double(item.outputTokens)), .green),
            (L("Cache Read", "缓存读取"), formatCompactNumber(Double(item.cacheReadTokens)), .orange),
            (L("Cache Write", "缓存写入"), formatCompactNumber(Double(item.cacheCreationTokens)), .purple),
            (L("Hit Rate", "命中率"), hitRate, .teal)
        ]

        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(details, id: \.0) { detail in
                    metricPill(label: detail.0, value: detail.1, color: detail.2)
                }
            }

            HStack {
                Spacer()
                Button {
                    toggleModel(item.model)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: selectedModels.contains(item.model) ? "checkmark.circle.fill" : "circle")
                        Text(L("Compare", "对比"))
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(selectedModels.contains(item.model) ? color : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(color.opacity(0.04))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    func metricPill(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.10)))
    }
}
