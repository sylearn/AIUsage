import SwiftUI

// MARK: - Local Token Usage Heatmap

struct LocalTokenUsageHeatmap: View {
    let providers: [ProviderData]
    /// 品牌口径：按账本家族（Claude / Codex / OpenCode）拆分展示时传入品牌名 + 图标 asset + 强调色。
    /// 强调色用于色阶与图例，让两块热力图各自带上自家品牌特色；为 nil 时回退到通用绿色。
    var brandLabel: String? = nil
    var brandAsset: String? = nil
    var accent: Color = .green
    /// 用量轨道：合计用 timeline.daily 合计口径；代理/非代理按模型名后缀从 modelTimelines 过滤汇总。
    var track: UsageTrack = .combined

    /// 展示的周数：仪表盘传 26（半年），统计页用默认 52（全年）。
    var weeks: Int = 52

    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hoveredCell: HeatmapCellID?
    /// tooltip 卡片实测高度，用于「靠底行向上翻转」时精确定位（避免被页面底部遮挡）。
    @State private var tooltipHeight: CGFloat = 0
    /// GeometryReader 本身没有内容固有高度；由实际格子尺寸回传精确高度，避免小格子仍占用最大网格高度。
    @State private var gridContentHeight: CGFloat = 108

    /// 上层容器通过该回调提升当前卡片的 zIndex；只在 tooltip 显隐切换时触发。
    var onHoverStateChange: ((Bool) -> Void)? = nil

    private static let tooltipMinWidth: CGFloat = 240
    private static let tooltipMaxWidth: CGFloat = 316

    // MARK: - Data

    /// 每日 Token 量聚合。直接使用 provider costSummary：Claude 为代理归档，
    /// Codex 合计为代理归档 + 非代理 token-only 日志，单轨从 modelTimelines 后缀过滤。
    private var dailyTotals: [Date: Int] {
        let calendar = Calendar.current
        var result: [Date: Int] = [:]

        // 单轨：合计口径无分轨数据，改从带后缀的 modelTimelines 过滤汇总。
        if track != .combined {
            for provider in providers {
                guard let timelines = provider.costSummary?.modelTimelines else { continue }
                for series in timelines where track.matches(series.model) {
                    for point in series.daily {
                        guard let pointDate = point.resolvedDate, point.tokens > 0 else { continue }
                        let day = calendar.startOfDay(for: pointDate)
                        result[day, default: 0] += point.tokens
                    }
                }
            }
            return result
        }

        for provider in providers {
            guard let daily = provider.costSummary?.timeline?.daily else { continue }
            for point in daily {
                guard let pointDate = point.resolvedDate, point.tokens > 0 else { continue }
                let day = calendar.startOfDay(for: pointDate)
                result[day, default: 0] += point.tokens
            }
        }
        return result
    }

    struct ModelDetail {
        let model: String
        var tokens: Int = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheReadTokens: Int = 0
        var cacheCreateTokens: Int = 0
    }

    private func modelBreakdown(for targetDate: Date) -> [ModelDetail] {
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: targetDate)

        var detailMap: [String: ModelDetail] = [:]

        for provider in providers {
            guard let timelines = provider.costSummary?.modelTimelines else { continue }
            for series in timelines where track.matches(series.model) {
                // 先按轨剥后缀（Codex），再剥 OpenCode 受管前缀 `aiusage-`，让热力图 tooltip 模型名干净统一。
                let base = track == .combined ? series.model : UsageTrack.stripSuffix(series.model)
                let modelName = StatsDataAdapter.displayModelLabel(base)
                for point in series.daily {
                    guard let pointDate = point.resolvedDate, point.tokens > 0 else { continue }
                    if calendar.startOfDay(for: pointDate) == targetDay {
                        var detail = detailMap[modelName] ?? ModelDetail(model: modelName)
                        detail.tokens += point.tokens
                        detail.inputTokens += point.inputTokens ?? 0
                        detail.outputTokens += point.outputTokens ?? 0
                        detail.cacheReadTokens += point.cacheReadTokens ?? 0
                        detail.cacheCreateTokens += point.cacheCreateTokens ?? 0
                        detailMap[modelName] = detail
                    }
                }
            }
        }

        return detailMap.values.sorted { $0.tokens > $1.tokens }
    }

    private var startDate: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // 周一作为每列（每周）的第一行：weekday 1=周日…7=周六 → 距本周一的天数。
        let weekday = calendar.component(.weekday, from: today)
        let daysFromMonday = (weekday + 5) % 7
        let currentWeekStart = calendar.date(byAdding: .day, value: -daysFromMonday, to: today) ?? today
        return calendar.date(byAdding: .day, value: -(weeks - 1) * 7, to: currentWeekStart) ?? today
    }

    private func date(forWeek week: Int, day: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: week * 7 + day, to: startDate) ?? .distantPast
    }

    private func bin(for tokens: Int, thresholds: [Int]) -> Int {
        guard tokens > 0 else { return 0 }
        guard thresholds.count == 3 else { return 1 }
        if tokens <= thresholds[0] { return 1 }
        if tokens <= thresholds[1] { return 2 }
        if tokens <= thresholds[2] { return 3 }
        return 4
    }

    /// 每个格子先铺不透明底色，再叠品牌色。这样强度仍有层次，但不会把卡片内容透到格子里。
    private func cellBaseColor(active: Bool) -> Color {
        if colorScheme == .dark {
            return active
                ? Color(red: 0.196, green: 0.208, blue: 0.235)
                : Color(red: 0.145, green: 0.153, blue: 0.173)
        }
        return active
            ? Color(red: 0.871, green: 0.894, blue: 0.925)
            : Color(red: 0.929, green: 0.945, blue: 0.965)
    }

    private func accentOpacity(for bin: Int) -> Double {
        switch bin {
        case 1: return colorScheme == .dark ? 0.44 : 0.38
        case 2: return colorScheme == .dark ? 0.62 : 0.56
        case 3: return colorScheme == .dark ? 0.80 : 0.74
        case 4: return colorScheme == .dark ? 0.98 : 0.92
        default: return 0
        }
    }

    // MARK: - Precomputed Heatmap Data

    private struct HeatmapSnapshot {
        let tokens: [Date: Int]
        let thresholds: [Int]
        let totalTokens: Int
        let activeDayCount: Int
        let maxDayTokens: (date: Date, tokens: Int)?
    }

    // snapshot/dailyTotals 仅依赖 providers + track，但 body 会因 hover（hoveredCell 变化）频繁重算。
    // 用静态缓存按「日 + 轨道 + provider 指纹(id@fetchedAt)」记忆：移动鼠标 / 切换轨道时直接命中，
    // 不再每次都重聚合全年数据。指纹含 fetchedAt（刷新即变）和日桶（跨午夜即变），保证不取到陈旧网格。
    private static var snapshotCache: [String: HeatmapSnapshot] = [:]

    private var snapshotSignature: String {
        let dayBucket = Int(Date().timeIntervalSince1970 / 86_400)
        let fingerprint = providers
            .map { "\($0.id)@\($0.fetchedAt ?? "-")" }
            .sorted()
            .joined(separator: ",")
        return "\(dayBucket)|\(track.rawValue)|\(fingerprint)"
    }

    private var snapshot: HeatmapSnapshot {
        let key = snapshotSignature
        if let cached = Self.snapshotCache[key] { return cached }
        let snap = computeSnapshot()
        if Self.snapshotCache.count > 16 { Self.snapshotCache.removeAll() }
        Self.snapshotCache[key] = snap
        return snap
    }

    private func computeSnapshot() -> HeatmapSnapshot {
        let tokens = dailyTotals
        let values = tokens.values.filter { $0 > 0 }.sorted()
        let computedThresholds: [Int]
        if values.count < 2 {
            computedThresholds = values.isEmpty ? [] : [values[0], values[0], values[0]]
        } else {
            func percentile(_ p: Double) -> Int {
                let idx = Int((Double(values.count) - 1) * p)
                return values[max(0, min(values.count - 1, idx))]
            }
            computedThresholds = [percentile(0.25), percentile(0.50), percentile(0.75)]
        }
        return HeatmapSnapshot(
            tokens: tokens,
            thresholds: computedThresholds,
            totalTokens: tokens.values.reduce(0, +),
            activeDayCount: values.count,
            maxDayTokens: tokens.max(by: { $0.value < $1.value }).map { ($0.key, $0.value) }
        )
    }

    // MARK: - Body

    var body: some View {
        let snap = snapshot
        VStack(alignment: .leading, spacing: 0) {
            header
            if snap.tokens.isEmpty {
                emptyState
                    .padding(.top, 8)
            } else {
                gridSection(snap: snap)
                    .padding(.top, 8)
                    .zIndex(1)
                footerView(snap: snap)
                    .padding(.top, 10)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(AppSurface.card(colorScheme)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppStroke.card(colorScheme), lineWidth: 1))
        .onDisappear {
            hoveredCell = nil
            onHoverStateChange?(false)
        }
    }

    // MARK: - Header
    // 极简品牌标签：小图标 + 品牌名（品牌色），不再放「活动热力图」大标题与灰色副标题。

    private var header: some View {
        HStack(spacing: 6) {
            if let brandAsset {
                ProviderIconView(brandAsset, size: 15)
            }
            Text(brandLabel ?? L("Local Token Usage", "本地 Token 用量"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent)
        }
    }

    // MARK: - Grid

    /// 格子边长上下限：7pt 以下难以稳定辨识强度与 hover；放不下时宁可少显示最早几周。
    private static let minCellSide: CGFloat = 7
    private static let maxCellSide: CGFloat = 16
    private static let compactGridSpacing: CGFloat = 2
    private static let regularGridSpacing: CGFloat = 3
    private static let weekdayLabelWidth: CGFloat = 28
    private static let monthLabelHeight: CGFloat = 14
    private static let monthToGridSpacing: CGFloat = 4

    /// 用 GeometryReader 实测可用宽度，自适应推导格子边长与显示周数：
    /// 宽窗口铺满整年（16pt 格子），窄窗口先压缩格子、连最小格子都放不下时再从最近周向前裁剪，永不溢出卡片。
    private func gridSection(snap: HeatmapSnapshot) -> some View {
        GeometryReader { proxy in
            let weekdayLabelWidth = Self.weekdayLabelWidth
            let monthLabelHeight = Self.monthLabelHeight
            let availableWidth = max(0, proxy.size.width - weekdayLabelWidth)
            let spacing = proxy.size.width < 340 ? Self.compactGridSpacing : Self.regularGridSpacing

            // 先按「最小格子」算出最多能放下多少周，再据此反推真实格子边长。
            let fitWeeks = max(1, Int((availableWidth + spacing) / (Self.minCellSide + spacing)))
            let visibleWeeks = max(1, min(weeks, fitWeeks))
            let weekOffset = weeks - visibleWeeks
            let cellSide = max(
                Self.minCellSide,
                min(Self.maxCellSide, (availableWidth - CGFloat(visibleWeeks - 1) * spacing) / CGFloat(visibleWeeks))
            )
            let columnPitch = cellSide + spacing
            let gridHeight = cellSide * 7 + spacing * 6
            let contentHeight = monthLabelHeight + Self.monthToGridSpacing + gridHeight

            VStack(alignment: .leading, spacing: Self.monthToGridSpacing) {
                monthLabelsRow(
                    cellSide: cellSide,
                    columnPitch: columnPitch,
                    height: monthLabelHeight,
                    visibleWeeks: visibleWeeks,
                    weekOffset: weekOffset
                )
                .frame(height: monthLabelHeight)

                HStack(alignment: .top, spacing: 0) {
                    weekdayLabels(cellSide: cellSide, spacing: spacing)
                        .frame(width: weekdayLabelWidth, height: gridHeight, alignment: .topLeading)

                    gridColumns(cellSide: cellSide, spacing: spacing, snap: snap, visibleWeeks: visibleWeeks, weekOffset: weekOffset)
                }
            }
            .frame(maxWidth: .infinity, minHeight: contentHeight, maxHeight: contentHeight, alignment: .topLeading)
            .preference(key: HeatmapGridHeightKey.self, value: contentHeight)
            .overlay {
                if let hovered = hoveredCell, hovered.week < visibleWeeks {
                    heatmapTooltipOverlay(
                        cell: hovered,
                        snap: snap,
                        cellSide: cellSide,
                        spacing: spacing,
                        columnPitch: columnPitch,
                        weekdayLabelWidth: weekdayLabelWidth,
                        monthLabelHeight: monthLabelHeight,
                        containerWidth: proxy.size.width,
                        weekOffset: weekOffset
                    )
                }
            }
        }
        .frame(height: gridContentHeight)
        .onPreferenceChange(HeatmapGridHeightKey.self) { height in
            guard height > 0, abs(height - gridContentHeight) > 0.5 else { return }
            gridContentHeight = height
        }
    }

    private static let monthFormatterZh: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月"
        return f
    }()

    private static let monthFormatterEn: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM"
        return f
    }()

    private func monthLabelsRow(cellSide: CGFloat, columnPitch: CGFloat, height: CGFloat, visibleWeeks: Int, weekOffset: Int) -> some View {
        let weekdayLabelWidth = Self.weekdayLabelWidth
        let formatter = appState.language == "zh" ? Self.monthFormatterZh : Self.monthFormatterEn

        let calendar = Calendar.current
        var labels: [(column: Int, text: String)] = []
        var previousMonth = -1
        for column in 0..<visibleWeeks {
            let day = date(forWeek: column + weekOffset, day: 0)
            let month = calendar.component(.month, from: day)
            if month != previousMonth {
                labels.append((column, formatter.string(from: day)))
                previousMonth = month
            }
        }

        // 可见区若从月底开始，首月标签可能与下个月只差一两列；优先保留区间起始月份，
        // 跳过距离过近的下一个标签，避免碰撞又不让半年范围看起来被截短。
        let minimumLabelDistance: CGFloat = appState.language == "zh" ? 18 : 24
        var visibleLabels: [(column: Int, text: String)] = []
        for entry in labels {
            guard let previous = visibleLabels.last else {
                visibleLabels.append(entry)
                continue
            }
            let distance = CGFloat(entry.column - previous.column) * columnPitch
            if distance >= minimumLabelDistance {
                visibleLabels.append(entry)
            }
        }

        return ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(visibleLabels, id: \.column) { entry in
                Text(entry.text)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: weekdayLabelWidth + CGFloat(entry.column) * columnPitch, y: 0)
            }
        }
    }

    private func weekdayLabels(cellSide: CGFloat, spacing: CGFloat) -> some View {
        // 周一起始：行 0=周一…行 6=周日；显示一、三、五（行 0/2/4）。
        let visibleRows: Set<Int> = [0, 2, 4]
        let names: [String] = [
            L("Mon", "一"),
            L("Tue", "二"),
            L("Wed", "三"),
            L("Thu", "四"),
            L("Fri", "五"),
            L("Sat", "六"),
            L("Sun", "日")
        ]
        return VStack(spacing: spacing) {
            ForEach(0..<7, id: \.self) { row in
                ZStack(alignment: .leading) {
                    Color.clear.frame(height: cellSide)
                    if visibleRows.contains(row) {
                        Text(names[row])
                            .font(.system(size: cellSide < 9 ? 8 : 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func gridColumns(cellSide: CGFloat, spacing: CGFloat, snap: HeatmapSnapshot, visibleWeeks: Int, weekOffset: Int) -> some View {
        let tokens = snap.tokens
        let computedThresholds = snap.thresholds
        let today = Calendar.current.startOfDay(for: Date())

        return HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<visibleWeeks, id: \.self) { week in
                VStack(spacing: spacing) {
                    ForEach(0..<7, id: \.self) { day in
                        let cellDate = date(forWeek: week + weekOffset, day: day)
                        let isActive = cellDate <= today
                        let count = isActive ? (tokens[cellDate] ?? 0) : 0
                        let binIndex = bin(for: count, thresholds: computedThresholds)
                        let isToday = isActive && cellDate == today
                        let isHovered = hoveredCell?.week == week && hoveredCell?.day == day
                        let cornerRadius = max(2, min(4, cellSide * 0.24))

                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(cellBaseColor(active: isActive))
                            .frame(width: cellSide, height: cellSide)
                            .overlay {
                                if binIndex > 0 {
                                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                        .fill(accent.opacity(accentOpacity(for: binIndex)))
                                }
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                    .stroke(
                                        isHovered
                                            ? AppContent.primary(colorScheme).opacity(0.92)
                                            : (isToday ? accent : Color.clear),
                                        lineWidth: isHovered ? 1.5 : (isToday ? 1.2 : 0)
                                    )
                            )
                            .shadow(color: isHovered ? accent.opacity(0.50) : .clear, radius: 3)
                            .scaleEffect(isHovered && !reduceMotion ? 1.16 : 1.0)
                            .zIndex(isHovered ? 10 : 0)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: isHovered)
                            .onHover { hovering in
                                updateHoveredCell(hovering ? HeatmapCellID(week: week, day: day) : nil)
                            }
                    }
                }
            }
        }
    }

    // MARK: - Tooltip Overlay

    @ViewBuilder
    private func heatmapTooltipOverlay(
        cell: HeatmapCellID,
        snap: HeatmapSnapshot,
        cellSide: CGFloat,
        spacing: CGFloat,
        columnPitch: CGFloat,
        weekdayLabelWidth: CGFloat,
        monthLabelHeight: CGFloat,
        containerWidth: CGFloat,
        weekOffset: Int
    ) -> some View {
        // cell.week 是相对列号（0..<visibleWeeks）：定位用相对列，取日期用绝对周（含偏移）。
        let cellDate = date(forWeek: cell.week + weekOffset, day: cell.day)
        let today = Calendar.current.startOfDay(for: Date())
        let isActive = cellDate <= today
        let tokens = isActive ? (snap.tokens[cellDate] ?? 0) : 0
        let models = (isActive && tokens > 0) ? modelBreakdown(for: cellDate) : []

        let cellCenterX = weekdayLabelWidth + CGFloat(cell.week) * columnPitch + cellSide / 2
        let gridTopY = monthLabelHeight + Self.monthToGridSpacing
        let cellTopY = gridTopY + CGFloat(cell.day) * (cellSide + spacing)
        let cellBottomY = cellTopY + cellSide

        let tw = max(Self.tooltipMinWidth, min(Self.tooltipMaxWidth, containerWidth - 8))
        let xClamped = max(4, min(containerWidth - tw - 4, cellCenterX - tw / 2))

        // 靠底部三行（周五/六/日）向上翻转，避免 tooltip 被页面底部裁掉；其余行仍朝下。
        let flipUp = cell.day >= 4
        let measuredHeight = tooltipHeight > 0 ? tooltipHeight : 160
        let yPos = flipUp ? (cellTopY - 8 - measuredHeight) : (cellBottomY + 8)

        heatmapTooltipCard(
            date: cellDate,
            isActive: isActive,
            tokens: tokens,
            models: models
        )
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: tw, alignment: .topLeading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: TooltipHeightKey.self, value: proxy.size.height)
            }
        )
        .offset(x: xClamped, y: yPos)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .zIndex(1_000)
        .allowsHitTesting(false)
        .onPreferenceChange(TooltipHeightKey.self) { tooltipHeight = $0 }
    }

    private func heatmapTooltipCard(
        date: Date,
        isActive: Bool,
        tokens: Int,
        models: [ModelDetail]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            tooltipDateHeader(date: date, isActive: isActive)

            if isActive {
                tooltipMetrics(tokens: tokens)

                if !models.isEmpty {
                    Divider()
                        .overlay(AppStroke.subtle(colorScheme))
                        .padding(.vertical, 6)

                    tooltipModelList(models: models)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .foregroundStyle(AppContent.floatingPrimary(colorScheme))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppSurface.floatingPanel(colorScheme))
                .shadow(color: AppShadow.floatingPanel(colorScheme), radius: 22, y: 9)
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.06), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppStroke.floatingPanel(colorScheme), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(accent)
                .frame(width: 3)
                .padding(.vertical, 12)
                .padding(.leading, 1)
        }
    }

    private static let tooltipDateFormatterZh: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 EEE"
        return f
    }()

    private static let tooltipDateFormatterEn: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, MMM d, yyyy"
        return f
    }()

    private func tooltipDateHeader(date: Date, isActive: Bool) -> some View {
        let formatter = appState.language == "zh" ? Self.tooltipDateFormatterZh : Self.tooltipDateFormatterEn
        let dateStr = formatter.string(from: date)

        return HStack(spacing: 4) {
            Text(dateStr)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppContent.floatingPrimary(colorScheme))
            Spacer()
            if !isActive {
                Text(L("Future", "尚未到达"))
                    .font(.caption2)
                    .foregroundStyle(AppContent.floatingTertiary(colorScheme))
            }
        }
        .padding(.bottom, isActive ? 6 : 0)
    }

    private func tooltipMetrics(tokens: Int) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Tokens", "Tokens"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(AppContent.floatingTertiary(colorScheme))
                Text(formatNumber(tokens))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(AppContent.floatingPrimary(colorScheme))
            }
            Spacer()
        }
    }

    private func tooltipModelList(models: [ModelDetail]) -> some View {
        let detailFont = Font.system(size: 9).monospacedDigit()
        let detailLabelFont = Font.system(size: 8)

        return VStack(alignment: .leading, spacing: 6) {
            Text(L("Models", "模型"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(AppContent.floatingTertiary(colorScheme))

            ForEach(Array(models.prefix(5).enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(accent)
                            .frame(width: 6, height: 6)
                        Text(entry.model)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(AppContent.floatingPrimary(colorScheme))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(formatCompactNumber(Double(entry.tokens)))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(AppContent.floatingSecondary(colorScheme))
                            .fixedSize()
                    }

                    if entry.cacheReadTokens > 0 || entry.inputTokens > 0 || entry.outputTokens > 0 {
                        HStack(spacing: 0) {
                            Spacer().frame(width: 10)
                            tokenDetailCell(L("Cache", "缓存"), entry.cacheReadTokens, detailFont, detailLabelFont)
                            tokenDetailCell(L("Input", "输入"), entry.inputTokens, detailFont, detailLabelFont)
                            tokenDetailCell(L("Output", "输出"), entry.outputTokens, detailFont, detailLabelFont)
                            if entry.cacheCreateTokens > 0 {
                                tokenDetailCell(L("Write", "写入"), entry.cacheCreateTokens, detailFont, detailLabelFont)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            if models.count > 5 {
                Text(L("+\(models.count - 5) more", "+\(models.count - 5) 更多"))
                    .font(.system(size: 9))
                    .foregroundStyle(AppContent.floatingTertiary(colorScheme))
            }
        }
    }

    private func tokenDetailCell(_ label: String, _ value: Int, _ valFont: Font, _ lblFont: Font) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(lblFont)
                .foregroundStyle(AppContent.floatingTertiary(colorScheme))
            Text(formatCompactNumber(Double(value)))
                .font(valFont)
                .foregroundStyle(AppContent.floatingSecondary(colorScheme))
        }
        .frame(minWidth: 52, alignment: .leading)
    }

    // MARK: - Footer

    private func footerView(snap: HeatmapSnapshot) -> some View {
        let totalText = L("Total \(formatCompactNumber(Double(snap.totalTokens))) tokens",
                          "合计 \(formatCompactNumber(Double(snap.totalTokens))) tokens")
        let peakText = snap.maxDayTokens.map { peakSummaryText(for: $0, activeDays: snap.activeDayCount) }

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 6) {
                Text(totalText)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let peakText {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(peakText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(totalText)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let peakText {
                    Text(peakText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.3x3")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("No usage recorded yet", "暂无使用记录"))
                    .font(.subheadline.weight(.semibold))
                Text(L("Local daily token data will appear here once logs are imported.",
                       "当本地日志被导入后，这里将显示每日 Token 数据。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func updateHoveredCell(_ cell: HeatmapCellID?) {
        let wasShowingTooltip = hoveredCell != nil
        let isShowingTooltip = cell != nil
        hoveredCell = cell
        if wasShowingTooltip != isShowingTooltip {
            onHoverStateChange?(isShowingTooltip)
        }
    }

    private static let peakDateFormatterZh: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    private static let peakDateFormatterEn: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()

    private func peakSummaryText(for peak: (date: Date, tokens: Int), activeDays: Int) -> String {
        let formatter = appState.language == "zh" ? Self.peakDateFormatterZh : Self.peakDateFormatterEn
        let peakDate = formatter.string(from: peak.date)
        let peakValue = formatCompactNumber(Double(peak.tokens))
        return L(
            "\(activeDays) active days · peak \(peakValue) on \(peakDate)",
            "活跃 \(activeDays) 天 · 最高 \(peakValue) 于 \(peakDate)"
        )
    }
}

// MARK: - Supporting Types

private struct HeatmapCellID: Equatable {
    let week: Int
    let day: Int
}

/// 热力图品牌色需要同时承担标题、焦点描边和色阶端点，因此按主题分别校准。
/// 浅色版本加深以满足小字号文字对比；深色版本提亮，避免在炭灰表面发闷。
enum HeatmapBrandColor {
    static func claude(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.902, green: 0.510, blue: 0.290)
            : Color(red: 0.659, green: 0.310, blue: 0.149)
    }

    static func codex(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.537, green: 0.584, blue: 1.000)
            : Color(red: 0.310, green: 0.361, blue: 0.784)
    }

    static func openCode(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.208, green: 0.804, blue: 0.745)
            : Color(red: 0.000, green: 0.490, blue: 0.459)
    }
}

private struct TooltipHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct HeatmapGridHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
