import SwiftUI
import QuotaBackend

// MARK: - Status Bar Item View
// Displays provider icons + quota/cost metrics in the macOS menu bar.
// Embedded via NSHostingView in AppDelegate.setupMenuBar().

struct StatusBarItemView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var refreshCoordinator: ProviderRefreshCoordinator
    @ObservedObject var settings: AppSettings

    static let recommendedMaxAccounts = 4

    private var displayMode: MenuBarDisplayMode { settings.menuBarDisplayMode }
    private var metricType: MenuBarMetricType { settings.menuBarMetricType }
    private var pinnedQuotaIds: Set<String> { settings.menuBarPinnedQuotaAccountIds }
    private var pinnedCostIds: Set<String> { settings.menuBarPinnedCostSourceIds }

    private var items: [StatusBarMetricItem] {
        var result: [StatusBarMetricItem] = []

        if metricType.showsQuota {
            result.append(contentsOf: quotaItems)
        }
        if metricType.showsCost {
            result.append(contentsOf: costItems)
        }

        return result
    }

    private var quotaItems: [StatusBarMetricItem] {
        let hidden = settings.hiddenSidebarSections
        let groups = appState.providerAccountGroups
        var all: [StatusBarMetricItem] = []

        for group in groups {
            guard !AgentVisibility.isProviderHidden(group.providerId, hidden: hidden) else { continue }
            for entry in group.accounts where entry.isConnected {
                guard AgentVisibility.isQuotaAccount(
                    providerId: group.providerId,
                    category: entry.liveProvider?.category
                ) else { continue }
                guard let quota = entry.liveProvider?.remainingPercent else { continue }

                all.append(StatusBarMetricItem(
                    id: entry.id,
                    providerId: group.providerId,
                    kind: .quota(quota),
                    icon: nil
                ))
            }
        }

        if pinnedQuotaIds.isEmpty { return [] }
        return all.filter { pinnedQuotaIds.contains($0.id) }
    }

    private var costItems: [StatusBarMetricItem] {
        let hidden = settings.hiddenSidebarSections
        let groups = appState.providerAccountGroups
        var all: [StatusBarMetricItem] = []

        for group in groups {
            guard !AgentVisibility.isProviderHidden(group.providerId, hidden: hidden) else { continue }
            for entry in group.accounts where entry.isConnected {
                guard AgentVisibility.isCostAccount(
                    providerId: group.providerId,
                    category: entry.liveProvider?.category
                ) else { continue }
                guard pinnedCostIds.contains(entry.id) else { continue }
                guard let summary = entry.liveProvider?.costSummary else { continue }

                let config = settings.costSourceConfig(for: entry.id)
                guard let kind = costKindFromSummary(summary: summary, config: config) else { continue }

                all.append(StatusBarMetricItem(
                    id: entry.id,
                    providerId: group.providerId,
                    kind: kind,
                    icon: nil
                ))
            }
        }

        if pinnedCostIds.contains("proxy-stats") {
            let config = settings.costSourceConfig(for: "proxy-stats")
            let stats = ProxyViewModel.shared.overallStats(
                nodeFilter: nil,
                modelFilter: nil,
                since: config.period.sinceDate()
            )
            let hasValue = config.metric == .cost ? stats.cost > 0 : stats.tokens > 0
            if hasValue {
                let kind: StatusBarMetricItem.Kind = config.metric == .cost
                    ? .cost(stats.cost)
                    : .tokens(stats.tokens)
                all.append(StatusBarMetricItem(
                    id: "proxy-stats",
                    providerId: "proxy",
                    kind: kind,
                    icon: "point.3.connected.trianglepath.dotted"
                ))
            }
        }

        return all
    }

    private func costKindFromSummary(summary: CostSummary, config: MenuBarCostSourceConfig) -> StatusBarMetricItem.Kind? {
        let period: CostPeriod?
        switch config.period {
        case .today:   period = summary.today
        case .week:    period = summary.week
        case .month:   period = summary.month
        case .overall: period = summary.overall
        }
        guard let period else { return nil }
        switch config.metric {
        case .cost:   return .cost(period.usd)
        case .tokens:
            guard let tokens = period.tokens else { return nil }
            return .tokens(tokens)
        }
    }

    var body: some View {
        if items.isEmpty {
            fallbackIcon
        } else {
            HStack(spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { statusBarDivider }
                    statusBarEntry(item)
                }
            }
            .fixedSize()
        }
    }

    // MARK: - Subviews

    private var fallbackIcon: some View {
        Image("MenuBarIcon")
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 18, height: 18)
    }

    private var statusBarDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.2))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func statusBarEntry(_ item: StatusBarMetricItem) -> some View {
        HStack(spacing: 4) {
            if displayMode != .metricOnly {
                if let icon = item.icon {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                } else {
                    StatusBarProviderIcon(providerId: item.providerId, size: 16)
                }
            }

            if displayMode != .iconOnly {
                switch item.kind {
                case .quota(let quota):
                    Text("\(Int(quota))%")
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(quotaColor(quota))
                case .cost(let cost):
                    Text(formatCostCompact(cost))
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.orange)
                case .tokens(let tokens):
                    Text(formatCompactNumber(Double(tokens)))
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.purple)
                }
            }
        }
    }

    // MARK: - Helpers

    private func quotaColor(_ percent: Double) -> Color {
        if percent >= 70 { return Color(red: 0.15, green: 0.78, blue: 0.40) }
        if percent >= 35 { return Color(red: 0.96, green: 0.64, blue: 0.18) }
        return Color(red: 0.92, green: 0.25, blue: 0.28)
    }

    private func formatCostCompact(_ usd: Double) -> String {
        // 跟随「显示货币」（USD/CNY），与菜单栏/仪表盘币种一致。
        formatCurrencyCompact(usd)
    }
}

// MARK: - Data

private struct StatusBarMetricItem: Identifiable {
    let id: String
    let providerId: String
    let kind: Kind
    let icon: String?

    enum Kind {
        case quota(Double)
        case cost(Double)
        case tokens(Int)
    }
}

// MARK: - Status Bar Provider Icon

struct StatusBarProviderIcon: View {
    let providerId: String
    let size: CGFloat

    private var assetName: String {
        switch providerId {
        case "codex": return "codex"
        default: return providerId
        }
    }

    var body: some View {
        Group {
            if let img = NSImage(named: assetName) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: size * 0.8))
            }
        }
        .frame(width: size, height: size)
    }
}
