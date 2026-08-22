import SwiftUI
import QuotaBackend

// MARK: - Menu Bar Pin & Cost-Source Helpers
// 菜单栏「配额账号 / 费用来源」固定选择器与每来源的周期/指标配置，以及固定计数校验。
// 从 SettingsView+Cards.swift 拆出以控制单文件规模；供 menuBarSection 调用。

extension SettingsView {

    func pruneStaleMenuBarPins() {
        let allEntries = appState.providerAccountGroups.flatMap { group in
            group.accounts.map { (providerId: group.providerId, entry: $0) }
        }
        let quotaIds = Set(allEntries.compactMap { pair in
            AgentVisibility.isQuotaAccount(providerId: pair.providerId, category: pair.entry.liveProvider?.category)
                ? pair.entry.id : nil
        })
        let costIds = Set(allEntries.compactMap { pair in
            AgentVisibility.isCostAccount(providerId: pair.providerId, category: pair.entry.liveProvider?.category)
                ? pair.entry.id : nil
        })
        settings.pruneMenuBarPinnedIds(validQuotaIds: quotaIds, validCostIds: costIds)
    }

    var menuBarQuotaAccountsPicker: some View {
        settingsBlock(
            title: L("Quota accounts", "配额账号"),
            subtitle: L("Select quota-based accounts to show in the menu bar. Empty = icon only. You can also right-click accounts in the popover to pin.", "选择显示在菜单栏的配额账号。不选则仅显示图标。也可在弹窗中右键账号进行固定。")
        ) {
            let hidden = settings.hiddenSidebarSections
            let groups = appState.providerAccountGroups.filter {
                !AgentVisibility.isProviderHidden($0.providerId, hidden: hidden)
            }
            let quotaEntries = groups.flatMap { group in
                group.accounts
                    .filter {
                        AgentVisibility.isQuotaAccount(
                            providerId: group.providerId,
                            category: $0.liveProvider?.category
                        )
                    }
                    .map { (group: group, entry: $0) }
            }

            if quotaEntries.isEmpty {
                Text(L("No quota accounts available", "暂无配额账号"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                pinnedAccountList(
                    entries: quotaEntries,
                    selectedIds: $settings.menuBarPinnedQuotaAccountIds
                )
            }
        }
    }

    var menuBarCostSourcesPicker: some View {
        settingsBlock(
            title: L("Cost sources", "费用来源"),
            subtitle: L("Select cost sources to show in the menu bar.", "选择显示在菜单栏的费用来源。")
        ) {
            let hidden = settings.hiddenSidebarSections
            let groups = appState.providerAccountGroups.filter {
                !AgentVisibility.isProviderHidden($0.providerId, hidden: hidden)
            }
            let costEntries = groups.flatMap { group in
                group.accounts
                    .filter {
                        AgentVisibility.isCostAccount(
                            providerId: group.providerId,
                            category: $0.liveProvider?.category
                        )
                    }
                    .map { (group: group, entry: $0) }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(costEntries, id: \.entry.id) { pair in
                    let isSelected = settings.menuBarPinnedCostSourceIds.contains(pair.entry.id)
                    HStack(spacing: 8) {
                        Button {
                            var ids = settings.menuBarPinnedCostSourceIds
                            if isSelected { ids.remove(pair.entry.id) } else { ids.insert(pair.entry.id) }
                            settings.menuBarPinnedCostSourceIds = ids
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? Color.orange : Color.secondary)
                                    .font(.system(size: 14))
                                ProviderIconView(pair.group.providerId, size: 14)
                                Text(pair.entry.accountEmail ?? pair.entry.accountDisplayName ?? pair.entry.providerTitle)
                                    .font(.caption).lineLimit(1)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if isSelected {
                            costSourceConfigMenu(for: pair.entry.id)
                        }
                    }
                }

                let proxySelected = settings.menuBarPinnedCostSourceIds.contains("proxy-stats")
                HStack(spacing: 8) {
                    Button {
                        var ids = settings.menuBarPinnedCostSourceIds
                        if proxySelected { ids.remove("proxy-stats") } else { ids.insert("proxy-stats") }
                        settings.menuBarPinnedCostSourceIds = ids
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: proxySelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(proxySelected ? Color.blue : Color.secondary)
                                .font(.system(size: 14))
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.system(size: 12))
                                .frame(width: 14, height: 14)
                            Text(L("Proxy Stats", "代理统计"))
                                .font(.caption).lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if proxySelected {
                        costSourceConfigMenu(for: "proxy-stats")
                    }
                }

                if costEntries.isEmpty && !proxySelected {
                    Text(L("No cost sources available", "暂无费用来源"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func costSourceConfigMenu(for sourceId: String) -> some View {
        let config = settings.costSourceConfig(for: sourceId)
        HStack(spacing: 6) {
            Menu {
                ForEach(MenuBarCostPeriod.allCases, id: \.self) { period in
                    Button {
                        var next = config
                        next.period = period
                        settings.setCostSourceConfig(next, for: sourceId)
                    } label: {
                        Label {
                            Text(periodDisplayLabel(period))
                        } icon: {
                            Image(systemName: period == config.period ? "checkmark" : "")
                        }
                    }
                }
            } label: {
                Text(periodDisplayLabel(config.period))
                    .font(.caption)
                    .frame(minWidth: 44)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                ForEach(MenuBarCostMetric.allCases, id: \.self) { metric in
                    Button {
                        var next = config
                        next.metric = metric
                        settings.setCostSourceConfig(next, for: sourceId)
                    } label: {
                        Label {
                            Text(metricDisplayLabel(metric))
                        } icon: {
                            Image(systemName: metric == config.metric ? "checkmark" : "")
                        }
                    }
                }
            } label: {
                Text(metricDisplayLabel(config.metric))
                    .font(.caption)
                    .frame(minWidth: 44)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func periodDisplayLabel(_ period: MenuBarCostPeriod) -> String {
        switch period {
        case .today:   return L("Today", "今日")
        case .week:    return L("Week", "本周")
        case .month:   return L("Month", "本月")
        case .overall: return L("All", "全部")
        }
    }

    private func metricDisplayLabel(_ metric: MenuBarCostMetric) -> String {
        switch metric {
        case .cost:   return L("Cost", "费用")
        case .tokens: return L("Tokens", "Tokens")
        }
    }

    var totalPinnedCount: Int {
        validPinnedQuotaIds.count + validPinnedCostIds.count
    }

    private var validPinnedQuotaIds: Set<String> {
        let hidden = settings.hiddenSidebarSections
        let allEntryIds = Set(
            appState.providerAccountGroups.flatMap { group -> [String] in
                guard !AgentVisibility.isProviderHidden(group.providerId, hidden: hidden) else { return [] }
                return group.accounts.compactMap { entry in
                    AgentVisibility.isQuotaAccount(
                        providerId: group.providerId,
                        category: entry.liveProvider?.category
                    ) ? entry.id : nil
                }
            }
        )
        return settings.menuBarPinnedQuotaAccountIds.intersection(allEntryIds)
    }

    private var validPinnedCostIds: Set<String> {
        let hidden = settings.hiddenSidebarSections
        let allEntryIds = Set(
            appState.providerAccountGroups.flatMap { group -> [String] in
                guard !AgentVisibility.isProviderHidden(group.providerId, hidden: hidden) else { return [] }
                return group.accounts.compactMap { entry in
                    AgentVisibility.isCostAccount(
                        providerId: group.providerId,
                        category: entry.liveProvider?.category
                    ) ? entry.id : nil
                }
            }
        )
        return settings.menuBarPinnedCostSourceIds.intersection(allEntryIds)
    }

    private func pinnedAccountList(
        entries: [(group: ProviderAccountGroup, entry: ProviderAccountEntry)],
        selectedIds: Binding<Set<String>>
    ) -> some View {
        let grouped = Dictionary(grouping: entries, by: { $0.group.providerId })
        let orderedProviderIds: [String] = {
            var seen = Set<String>()
            return entries.compactMap { pair in
                seen.insert(pair.group.providerId).inserted ? pair.group.providerId : nil
            }
        }()

        return VStack(alignment: .leading, spacing: 8) {
            ForEach(orderedProviderIds, id: \.self) { providerId in
                let items = grouped[providerId] ?? []
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        ProviderIconView(providerId, size: 12)
                        Text(items.first?.group.title ?? providerId)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 1)

                    let columns = [GridItem(.adaptive(minimum: 180), spacing: 6)]
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
                        ForEach(items, id: \.entry.id) { pair in
                            let isSelected = selectedIds.wrappedValue.contains(pair.entry.id)
                            Button {
                                var ids = selectedIds.wrappedValue
                                if isSelected { ids.remove(pair.entry.id) } else { ids.insert(pair.entry.id) }
                                selectedIds.wrappedValue = ids
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                                        .font(.system(size: 13))
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(pair.entry.accountEmail ?? pair.entry.accountDisplayName ?? pair.entry.providerTitle)
                                            .font(.caption).lineLimit(1)
                                        if let ws = pair.entry.workspaceLabel, ws != "Personal" {
                                            Text(ws)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
