import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @State private var activeHeatmapID: String?
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                // 本地数据（概览/热力图/聚合）始终立即渲染，不再被网络刷新的全局骨架屏遮挡。
                if let error = refreshCoordinator.errorMessage {
                    inlineErrorBanner(error)
                }

                overviewSection

                if !costTrackingProviders.isEmpty {
                    heatmapSection
                        // 让热力图悬浮提示卡片绘制在下方统计卡片之上（同级 VStack 中
                        // 后声明的视图默认覆盖先声明的，故抬高热力图层级）。
                        .zIndex(1)
                } else if isAwaitingLocalStats {
                    skeletonHeatmap
                }

                if !isAccountsModuleHidden {
                    providersSection
                }
            }
            .padding()
        }
        .background(AppSurface.page(colorScheme))
    }

    /// 订阅账号模块被隐藏（设置 → 侧边栏可见性）时，仪表盘的额度告警区随之消失。
    private var isAccountsModuleHidden: Bool {
        appState.settings.hiddenSidebarSections.contains(AppSection.providerAccounts.rawValue)
    }

    /// 首次加载中、本地 Token 统计还没扫到时，仅对热力图区域显示骨架（而非整页）。
    private var isAwaitingLocalStats: Bool {
        !refreshCoordinator.hasCompletedInitialLoad
            && costTrackingProviders.isEmpty
            && appState.selectedProviderIds.contains(where: { $0 == "claude" || $0 == "codex-cost" || $0 == "opencode" })
    }

    // MARK: - Overview Section

    private var overviewSection: some View {
        let agg = overviewCostAggregates
        return DashboardOverviewStatRow(
            todayTokens: formatCompactNumber(Double(agg.todayTokens)),
            monthTokens: formatCompactNumber(Double(agg.monthTokens)),
            todayCost: AIUsage.formatCurrency(agg.todayCost),
            monthCost: AIUsage.formatCurrency(agg.monthCost)
        )
    }

    private struct OverviewCostAggregates {
        var overallTokens = 0
        var overallCost = 0.0
        var todayTokens = 0
        var todayCost = 0.0
        var monthTokens = 0
        var monthCost = 0.0
    }

    /// 从本地 cost provider (Claude + Codex + OpenCode) 的 costSummary 中汇总 Token/费用。
    /// 各 provider 保持自身账本边界：Claude 为 Gateway 归档，Codex 合并代理与非代理轨。
    private var overviewCostAggregates: OverviewCostAggregates {
        var agg = OverviewCostAggregates()
        for provider in costTrackingProviders {
            guard let summary = provider.costSummary else { continue }
            agg.overallTokens += summary.overall?.tokens ?? 0
            agg.overallCost += summary.overall?.usd ?? 0
            agg.todayTokens += summary.today?.tokens ?? 0
            agg.todayCost += summary.today?.usd ?? 0
            agg.monthTokens += summary.month?.tokens ?? 0
            agg.monthCost += summary.month?.usd ?? 0
        }
        return agg
    }
    
    // MARK: - Providers Grid

    /// 排除被侧边栏隐藏的 agent——其概览 Token/费用、热力图随之从仪表盘消失（全隐藏则回到空态）。
    private var costTrackingProviders: [ProviderData] {
        let hiddenIds = AgentVisibility.hiddenCostProviderIds(hidden: appState.settings.hiddenSidebarSections)
        let providers = deduplicatedProviders(appState.localCostProviders(from: refreshCoordinator.providers))
        guard !hiddenIds.isEmpty else { return providers }
        return providers.filter { !hiddenIds.contains($0.baseProviderId) }
    }

    private var claudeLocalProviders: [ProviderData] {
        costTrackingProviders.filter { $0.baseProviderId == "claude" }
    }

    private var codexLocalProviders: [ProviderData] {
        costTrackingProviders.filter { $0.baseProviderId == "codex-cost" }
    }

    private var opencodeLocalProviders: [ProviderData] {
        costTrackingProviders.filter { $0.baseProviderId == "opencode" }
    }

    /// 顶部活动热力图：按账本家族（Claude / Codex / OpenCode）拆块展示，
    /// 各自带上自家品牌色，与卡片/图标/菜单栏口径一致。
    /// 数据源统一为本地 costSummary：Claude 来自代理归档，Codex 来自代理归档 + 非代理 token 日志，
    /// OpenCode 来自本地会话库归档。
    private var dashboardHeatmapWeeks: Int { 26 }

    /// 单块热力图描述：数据驱动取代家族二元硬编码，新增本地 cost 工具时只需补一行。
    private struct HeatmapSpec: Identifiable {
        let id: String
        let providers: [ProviderData]
        let label: String
        let asset: String
        let accent: Color
    }

    private var heatmapSpecs: [HeatmapSpec] {
        [
            HeatmapSpec(id: "claude", providers: claudeLocalProviders, label: "Claude", asset: "claude", accent: HeatmapBrandColor.claude(colorScheme)),
            HeatmapSpec(id: "codex-cost", providers: codexLocalProviders, label: "Codex", asset: "codex", accent: HeatmapBrandColor.codex(colorScheme)),
            HeatmapSpec(id: "opencode", providers: opencodeLocalProviders, label: "OpenCode", asset: "opencode", accent: HeatmapBrandColor.openCode(colorScheme))
        ].filter { !$0.providers.isEmpty }
    }

    private func heatmap(for spec: HeatmapSpec) -> some View {
        LocalTokenUsageHeatmap(
            providers: spec.providers,
            brandLabel: spec.label,
            brandAsset: spec.asset,
            accent: spec.accent,
            weeks: dashboardHeatmapWeeks,
            onHoverStateChange: { isShowingTooltip in
                if isShowingTooltip {
                    activeHeatmapID = spec.id
                } else if activeHeatmapID == spec.id {
                    activeHeatmapID = nil
                }
            }
        )
    }

    /// 仪表盘热力图采用自适应卡片网格：
    /// 窄窗口单列保证格子可读，中等窗口双列，超宽窗口三列，避免固定双列在两端尺寸下
    /// 分别出现「格子过小」或「末行空半屏」。300pt 是半年热力图仍能保持完整月份标尺的下限。
    private var heatmapSection: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 300, maximum: 560), spacing: 16, alignment: .top)],
            alignment: .leading,
            spacing: 16
        ) {
            ForEach(heatmapSpecs) { spec in
                heatmap(for: spec)
                    .frame(maxWidth: .infinity)
                    .zIndex(activeHeatmapID == spec.id ? 1_000 : 0)
            }
        }
        .zIndex(1)
    }


    /// 官方订阅账号条目（Keychain 注册表 + live 合并）。
    private var officialAccountEntries: [ProviderAccountEntry] {
        officialAccountGroups.flatMap(\.accounts)
    }

    private var officialAccountGroups: [ProviderAccountGroup] {
        appState.providerAccountGroups.filter {
            appState.providerCatalogItem(for: $0.providerId)?.kind == .official
        }
    }

    private func deduplicatedProviders(_ providers: [ProviderData]) -> [ProviderData] {
        var seen = Set<String>()
        var unique: [ProviderData] = []

        for provider in providers {
            if seen.insert(provider.id).inserted {
                unique.append(provider)
            }
        }

        return unique
    }

    // MARK: - Quota Attention Section

    @ViewBuilder
    private var providersSection: some View {
        if officialAccountEntries.isEmpty {
            providersCallToAction
        } else {
            DashboardQuotaAttentionSection(
                entries: officialAccountEntries,
                isLoading: { entry in
                    !refreshCoordinator.hasCompletedInitialLoad
                        || refreshCoordinator.isProviderRefreshInFlight(entry.providerId)
                },
                onOpenSubscriptions: { appState.selectedSection = .providerAccounts }
            )
        }
    }

    private var providersCallToAction: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Subscription Quota", "订阅额度", key: "dashboard.providers"))
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 10) {
                Text(appState.selectedProviderIds.isEmpty
                     ? L("No sources selected yet", "尚未选择扫描来源")
                     : L("No accounts connected yet", "还没有连接账号"))
                    .font(.headline)

                Text(L(
                    "Choose the apps you use and connect an account on the Subscriptions page to start monitoring usage.",
                    "选择你在用的应用，并在「订阅账号」页连接账号，即可开始监控用量。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        appState.providerPickerMode = appState.needsInitialProviderSetup ? .initialSetup : .manage
                    } label: {
                        Label(L("Choose Sources", "选择来源"), systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        appState.selectedSection = .providerAccounts
                    } label: {
                        Label(L("Open Subscriptions", "打开订阅账号"), systemImage: "person.2")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppSurface.card(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppStroke.card(colorScheme), lineWidth: 1)
            )
        }
    }

    // MARK: - State Views

    /// 网络刷新失败时的轻量提示条（不再整页报错），有已知账号时仍能看到其它本地内容。
    private func inlineErrorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(AppContent.secondary(colorScheme))
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(L("Retry", "重试")) {
                refreshCoordinator.refreshAllProviders()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(refreshCoordinator.isAnyRefreshInProgress)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.25), lineWidth: 1))
    }

    private var skeletonHeatmap: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkeletonPill(width: 180, height: 16)
            SkeletonPill(width: 100, height: 10)
            SkeletonBlock(height: 130, cornerRadius: 8)
                .padding(.top, 4)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
    }

}

#Preview {
    DashboardView()
        .environmentObject(AppState.shared)
        .environmentObject(ProxyViewModel())
        .frame(width: 900, height: 700)
}
