import SwiftUI
import Charts
import QuotaBackend

// MARK: - ProxyStatsView
// 用量统计页主视图。数据源为各产品的本地永久账本（通过 StatsDataAdapter 聚合），
// 与仪表盘热力图/概览共享同一口径。Claude 账本来自 Gateway 请求归档。

struct ProxyStatsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @Environment(\.colorScheme) var colorScheme

    // 统一控制台口径：metric（费用/Tokens）与 period（今日/本周/本月/全部）全页共用，均持久化。
    @AppStorage(DefaultsKey.proxyStatsMetric) var metric: StatMetric = .cost
    @AppStorage(DefaultsKey.proxyStatsChartRange) var chartTimeRange: ChartTimeRange = .today
    @AppStorage(DefaultsKey.proxyStatsPeriod) var period: DistributionPeriod = .overall
    @AppStorage(DefaultsKey.proxyStatsFamily) var familyRaw: String = SourceFamily.all.rawValue
    @AppStorage(DefaultsKey.proxyStatsTrack) var trackRaw: String = UsageTrack.combined.rawValue
    @State var contentWidth: CGFloat = 0
    @State var expandedModels: Set<String> = []
    @State var selectedModels: Set<String> = []
    @State var activeHeatmapID: String?

    // MARK: - Types

    enum StatMetric: String, CaseIterable { case cost, tokens }

    enum SourceFamily: String, CaseIterable {
        case all, claude, codex, opencode

        var adapterFamily: StatsDataAdapter.SourceFamily {
            switch self {
            case .all:      return .all
            case .claude:   return .claude
            case .codex:    return .codex
            case .opencode: return .opencode
            }
        }

        /// 对应的 agent（用于侧边栏隐藏联动）；`.all` 无对应 agent。
        var agentKind: AgentKind? {
            switch self {
            case .all:      return nil
            case .claude:   return .claude
            case .codex:    return .codex
            case .opencode: return .opencode
            }
        }
    }

    // MARK: - Data

    static let adapter = StatsDataAdapter()

    /// 用户在侧边栏隐藏的 section（隐藏 agent 据此从本页彻底剔除）。
    private var hiddenSections: Set<String> { appState.settings.hiddenSidebarSections }

    /// 排除被隐藏 agent 后的本地 cost provider——「综合」聚合、热力图、空态判断均以此为准。
    var localProviders: [ProviderData] {
        let hiddenIds = AgentVisibility.hiddenCostProviderIds(hidden: hiddenSections)
        let all = appState.localCostProviders(from: refreshCoordinator.providers)
        guard !hiddenIds.isEmpty else { return all }
        return all.filter { !hiddenIds.contains($0.baseProviderId) }
    }

    /// 数据源分段仅列出未隐藏的 agent（「综合」常驻）。
    var visibleSourceFamilies: [SourceFamily] {
        SourceFamily.allCases.filter { family in
            guard let agent = family.agentKind else { return true }
            return AgentVisibility.isVisible(agent, hidden: hiddenSections)
        }
    }

    var claudeLocalProviders: [ProviderData] {
        localProviders.filter { $0.baseProviderId == "claude" }
    }

    var codexLocalProviders: [ProviderData] {
        localProviders.filter { $0.baseProviderId == "codex-cost" }
    }

    var opencodeLocalProviders: [ProviderData] {
        localProviders.filter { $0.baseProviderId == "opencode" }
    }

    /// 持久化选中的家族若其 agent 已被隐藏，则回退到「综合」（不改写偏好，取消隐藏后自动恢复）。
    var sourceFamily: SourceFamily {
        let stored = SourceFamily(rawValue: familyRaw) ?? .all
        if let agent = stored.agentKind, AgentVisibility.isHidden(agent, hidden: hiddenSections) {
            return .all
        }
        return stored
    }

    var familyBinding: Binding<SourceFamily> {
        Binding(get: { sourceFamily }, set: { familyRaw = $0.rawValue })
    }

    var selectedTrack: UsageTrack {
        UsageTrack(storedRawValue: trackRaw)
    }

    var trackBinding: Binding<UsageTrack> {
        Binding(get: { selectedTrack }, set: { trackRaw = $0.rawValue })
    }

    /// 仅 Codex 家族才有代理/非代理两轨；其它家族强制合计。
    var effectiveTrack: UsageTrack {
        sourceFamily == .codex ? selectedTrack : .combined
    }

    /// 轨道切换器仅在 Codex 家族显示（Claude 单轨、综合含无后缀的 Claude 行不宜按轨过滤）。
    var showsTrackPicker: Bool {
        sourceFamily == .codex && !codexLocalProviders.isEmpty
    }

    /// 非代理轨不监控价格 → 选「非代理」轨时全页隐藏费用相关 UI（费用 tile / 费用-Tokens 切换 /
    /// 费用列 / 按费用的占比与饼图），只呈现 token 用量。其它轨道正常显示费用。
    var showsCost: Bool {
        effectiveTrack != .nonProxy
    }

    /// 隐藏费用时（非代理轨），分布/详情/趋势一律按 Tokens 口径（不改持久化的 metric 偏好）。
    var effectiveMetric: StatMetric {
        showsCost ? metric : .tokens
    }

    var summary: CostSummary? {
        Self.adapter.summary(
            providers: localProviders,
            family: sourceFamily.adapterFamily,
            track: effectiveTrack
        )
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if localProviders.isEmpty {
                emptyState
            } else {
                ScrollView {
                    let ranked = rankedTrendSeries
                    let colorMap = buildModelColorMap(from: ranked)
                    LazyVStack(spacing: 16) {
                        controlDeck
                        summaryStrip
                        heatmapSection
                            // 抬高层级，让热力图 tooltip 绘制在下方分布/详情卡片之上，不被遮挡。
                            .zIndex(1)
                        insightPanelsSection(colorMap: colorMap, sparklineMap: buildSparklineMap(from: ranked))
                    }
                    .padding(20)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .preference(key: StatsContentWidthKey.self, value: proxy.size.width)
                        }
                    )
                }
            }
        }
        .appPageChrome(colorScheme)
        .onChange(of: familyRaw) { _, _ in
            pruneSelectedModels()
        }
        .onChange(of: trackRaw) { _, _ in
            pruneSelectedModels()
        }
        .onPreferenceChange(StatsContentWidthKey.self) { newWidth in
            if abs(newWidth - contentWidth) > 8 {
                contentWidth = newWidth
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(L("No usage data", "暂无用量数据"))
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text(L("Usage data will appear after Claude Gateway, Codex or OpenCode records local usage.",
                   "Claude Gateway、Codex 或 OpenCode 记录本地用量后，数据会自动展示。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Control Deck
    // 统一控制台：左「数据源」（家族 + Codex 轨道），右「视图」（时间段 + 费用/Tokens）。
    // 使用自定义等宽分段控件，避免原生 segmented picker 在 Codex 组合下被压缩变形。

    var controlDeck: some View {
        Group {
            if usesStackedControlLayout {
                VStack(alignment: .leading, spacing: 9) {
                    controlCluster(L("Source", "数据源"), systemImage: "square.stack.3d.up") { scopeControls }
                    controlCluster(L("View", "视图"), systemImage: "slider.horizontal.3") { lensControls }
                }
            } else {
                wideControlDeck
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppStroke.card(colorScheme), lineWidth: 1)
        )
    }

    private var wideControlDeck: some View {
        HStack(alignment: .center, spacing: 18) {
            controlCluster(L("Source", "数据源"), systemImage: "square.stack.3d.up") { scopeControls }
            Spacer(minLength: 12)
            controlCluster(L("View", "视图"), systemImage: "slider.horizontal.3") { lensControls }
        }
    }

    /// 何时把「数据源 / 视图」两簇竖排：宽度不足以左右并排时。Codex 选中时多出轨道选择器，所需宽度更大。
    private var usesStackedControlLayout: Bool {
        let needed: CGFloat = showsTrackPicker ? 1080 : 880
        return contentWidth == 0 || contentWidth < needed
    }

    private func controlCluster<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)

            content()
        }
    }

    // 控制簇内的两个分段控件：窄宽下用 ViewThatFits 自动从「并排」回退为「上下两行」，永不横向溢出。
    private var familyControl: some View {
        StatsSegmentedControl(
            visibleSourceFamilies,
            selection: familyBinding,
            segmentWidth: 84,
            tint: .indigo
        ) { family in
            switch family {
            case .all: return L("Combined", "综合")
            case .claude: return "Claude"
            case .codex: return "Codex"
            case .opencode: return "OpenCode"
            }
        }
    }

    @ViewBuilder
    private var trackControl: some View {
        if showsTrackPicker {
            StatsSegmentedControl(
                UsageTrack.allCases,
                selection: trackBinding,
                segmentWidth: 66,
                tint: .teal
            ) { track in
                track.label
            }
            .help(L("Split Codex usage into Proxy (priced archive) and Non-Proxy (token-only local logs) tracks.",
                    "将 Codex 用量拆分为代理（可计价归档）与非代理（仅 Token 本地日志）两轨。"))
        }
    }

    private var scopeControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { familyControl; trackControl }
            VStack(alignment: .leading, spacing: 6) { familyControl; trackControl }
        }
    }

    private var periodControl: some View {
        StatsSegmentedControl(
            DistributionPeriod.allCases,
            selection: $period,
            segmentWidth: 50,
            tint: .blue
        ) { period in
            period.label
        }
    }

    @ViewBuilder
    private var metricControl: some View {
        if showsCost {
            StatsSegmentedControl(
                StatMetric.allCases,
                selection: $metric,
                segmentWidth: 64,
                tint: .orange
            ) { metric in
                switch metric {
                case .cost: return L("Cost", "费用")
                case .tokens: return "Tokens"
                }
            }
        }
    }

    private var lensControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { periodControl; metricControl }
            VStack(alignment: .leading, spacing: 6) { periodControl; metricControl }
        }
    }

    // MARK: - Heatmap

    /// Codex 热力图标题：单轨时附带轨道名（如「Codex · 非代理」），合计时仅品牌名。
    var codexHeatmapLabel: String {
        effectiveTrack == .combined ? "Codex" : "Codex · \(effectiveTrack.label)"
    }

    @ViewBuilder
    var heatmapSection: some View {
        let showClaude = sourceFamily == .all || sourceFamily == .claude
        let showCodex = sourceFamily == .all || sourceFamily == .codex
        let showOpenCode = sourceFamily == .all || sourceFamily == .opencode

        VStack(spacing: 16) {
            if showClaude && !claudeLocalProviders.isEmpty {
                LocalTokenUsageHeatmap(
                    providers: claudeLocalProviders,
                    brandLabel: "Claude",
                    brandAsset: "claude",
                    accent: HeatmapBrandColor.claude(colorScheme),
                    onHoverStateChange: { isShowingTooltip in
                        if isShowingTooltip {
                            activeHeatmapID = "claude"
                        } else if activeHeatmapID == "claude" {
                            activeHeatmapID = nil
                        }
                    }
                )
                .zIndex(activeHeatmapID == "claude" ? 1_000 : 0)
            }
            if showCodex && !codexLocalProviders.isEmpty {
                LocalTokenUsageHeatmap(
                    providers: codexLocalProviders,
                    brandLabel: codexHeatmapLabel,
                    brandAsset: "codex",
                    accent: HeatmapBrandColor.codex(colorScheme),
                    track: effectiveTrack,
                    onHoverStateChange: { isShowingTooltip in
                        if isShowingTooltip {
                            activeHeatmapID = "codex"
                        } else if activeHeatmapID == "codex" {
                            activeHeatmapID = nil
                        }
                    }
                )
                .zIndex(activeHeatmapID == "codex" ? 1_000 : 0)
            }
            if showOpenCode && !opencodeLocalProviders.isEmpty {
                LocalTokenUsageHeatmap(
                    providers: opencodeLocalProviders,
                    brandLabel: "OpenCode",
                    brandAsset: "opencode",
                    accent: HeatmapBrandColor.openCode(colorScheme),
                    onHoverStateChange: { isShowingTooltip in
                        if isShowingTooltip {
                            activeHeatmapID = "opencode"
                        } else if activeHeatmapID == "opencode" {
                            activeHeatmapID = nil
                        }
                    }
                )
                .zIndex(activeHeatmapID == "opencode" ? 1_000 : 0)
            }
        }
    }

    // MARK: - Shared Helpers

    /// 家族 / 轨道切换后，模型名集合会变（订阅/API 过滤、剥后缀），剔除已不存在的对比选择。
    func pruneSelectedModels() {
        let available = Set(Self.adapter.allModels(from: summary))
        selectedModels = selectedModels.filter { available.contains($0) }
    }

    let chartColors: [Color] = [.blue, .orange, .green, .purple, .pink, .cyan, .red, .yellow, .mint, .indigo]

    func colorForModel(_ model: String, from colorMap: [String: Color]) -> Color {
        colorMap[model] ?? chartColors[stablePaletteIndex(for: model, paletteCount: chartColors.count)]
    }

    func buildModelColorMap(from ranked: [TrendSeriesDescriptor]) -> [String: Color] {
        var map: [String: Color] = [:]
        for (idx, descriptor) in ranked.enumerated() {
            map[descriptor.model] = chartColors[idx % chartColors.count]
        }
        return map
    }

    // 宽度未知（contentWidth == 0，首帧）时默认竖排：避免首帧用并排布局，分布+详情两卡的刚性最小宽度
    // 超过窄窗口可用宽度，导致内容溢出窗口右缘（用量统计页缩窄时被截断的根因）。
    var usesStackedInsightsLayout: Bool {
        contentWidth == 0 || contentWidth < 1080
    }

    var granularity: CostGranularity { chartTimeRange.isHourly ? .hourly : .daily }

    enum InsightsLayout {
        case split
        case stacked
    }
}

/// 紧凑等宽分段控件，App 内统一的「分段切换」外观（用量统计 / 调用分析共用）。
/// 比原生 segmented picker 更可控：固定每段宽度，避免在多选项时被压缩变形。
struct StatsSegmentedControl<Option: Hashable>: View {
    @Environment(\.colorScheme) private var colorScheme

    let options: [Option]
    @Binding var selection: Option
    let segmentWidth: CGFloat
    let tint: Color
    let title: (Option) -> String

    init(
        _ options: [Option],
        selection: Binding<Option>,
        segmentWidth: CGFloat,
        tint: Color,
        title: @escaping (Option) -> String
    ) {
        self.options = options
        self._selection = selection
        self.segmentWidth = segmentWidth
        self.tint = tint
        self.title = title
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06), lineWidth: 0.5)
        )
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = selection == option
        return Button {
            withAnimation(.easeOut(duration: 0.14)) {
                selection = option
            }
        } label: {
            Text(title(option))
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .allowsTightening(true)
                .foregroundStyle(isSelected ? tint : Color.primary.opacity(0.70))
                .frame(width: segmentWidth, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? selectedFill : Color.clear)
                        .shadow(
                            color: isSelected ? Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08) : .clear,
                            radius: isSelected ? 2 : 0,
                            y: isSelected ? 1 : 0
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? tint.opacity(0.22) : Color.clear, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title(option))
    }

    private var selectedFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.88)
    }
}

// MARK: - PreferenceKey

struct StatsContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    ProxyStatsView()
        .environmentObject(AppState.shared)
        .environmentObject(ProviderRefreshCoordinator.shared)
        .frame(width: 900, height: 700)
}
