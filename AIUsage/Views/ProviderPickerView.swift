import SwiftUI

struct ProviderPickerView: View {
    let mode: ProviderPickerMode

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: Set<String> = []
    @State private var searchText = ""
    @State private var hoveredProviderID: String?
    private var items: [ProviderCatalogItem] {
        switch mode {
        case .initialSetup:
            return appState.providerCatalog
        case .add:
            return appState.unselectedProviderCatalog
        case .manage:
            return appState.providerCatalog
        }
    }

    private var filteredItems: [ProviderCatalogItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }

        return items.filter { item in
            item.title(for: appState.language).localizedCaseInsensitiveContains(query)
                || item.summary(for: appState.language).localizedCaseInsensitiveContains(query)
                || (item.channel?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var officialItems: [ProviderCatalogItem] {
        filteredItems.filter { $0.kind == .official }
    }

    private var costTrackingItems: [ProviderCatalogItem] {
        filteredItems.filter { $0.kind == .costTracking }
    }

    private var hasFilteredResults: Bool {
        !officialItems.isEmpty || !costTrackingItems.isEmpty
    }

    private var previewItem: ProviderCatalogItem? {
        if let hoveredProviderID,
           let hoveredItem = filteredItems.first(where: { $0.id == hoveredProviderID }) {
            return hoveredItem
        }

        if let selectedItem = filteredItems.first(where: { selection.contains($0.id) }) {
            return selectedItem
        }

        return filteredItems.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if items.isEmpty {
                emptyState
            } else if !hasFilteredResults {
                filteredEmptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !officialItems.isEmpty {
                            sectionView(
                                title: L("Official Providers", "官方服务"),
                                subtitle: L("Subscription and account-based quotas", "订阅制与账号制配额"),
                                items: officialItems
                            )
                        }

                        if !costTrackingItems.isEmpty {
                            sectionView(
                                title: L("Local Token Stats", "本地 Token 统计"),
                                subtitle: L("Usage ledgers from proxy archives and local logs", "基于代理归档与本地日志的用量账本"),
                                items: costTrackingItems
                            )
                        }
                    }
                    .padding(20)
                }
            }

            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 840, minHeight: 520, idealHeight: 600)
        .appPageChrome(colorScheme)
        .onAppear {
            switch mode {
            case .initialSetup:
                selection = appState.selectedProviderIds
            case .add:
                selection = []
            case .manage:
                selection = appState.selectedProviderIds
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(headerTitle)
                        .font(.title2)
                        .bold()

                    Text(headerDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !items.isEmpty {
                    HStack(spacing: 8) {
                        Button {
                            selection = Set(items.map(\.id))
                        } label: {
                            ProviderActionLabel(
                                title: L("Select All", "全选"),
                                systemImage: "checkmark.circle"
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(selection.count == items.count)

                        Button {
                            selection.removeAll()
                        } label: {
                            ProviderActionLabel(
                                title: L("Clear", "清空"),
                                systemImage: "xmark.circle"
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(selection.isEmpty)
                    }
                    .font(.subheadline)
                }
            }

            HStack(spacing: 10) {
                summaryBadge(
                    text: L("\(selection.count) selected", "已选 \(selection.count) 项"),
                    tint: .blue
                )

                summaryBadge(
                    text: L("\(filteredItems.count) visible", "显示 \(filteredItems.count) 项"),
                    tint: .secondary
                )

                Spacer()

                if !items.isEmpty {
                    ProviderSearchControl(
                        placeholder: L("Search apps", "搜索应用"),
                        text: $searchText
                    )
                        .frame(maxWidth: 260)
                }
            }

            if let previewItem {
                previewPanel(for: previewItem)
            }
        }
        .padding(20)
    }

    private func sectionView(title: String, subtitle: String, items: [ProviderCatalogItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .bold()

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(L("\(items.count) apps", "\(items.count) 个应用"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 152), spacing: 12)], spacing: 12) {
                ForEach(items) { item in
                    SourceSelectionCard(
                        item: item,
                        isSelected: selection.contains(item.id),
                        language: appState.language,
                        colorScheme: colorScheme
                    ) {
                        toggleSelection(for: item.id)
                    }
                    .onHover { isHovering in
                        if isHovering {
                            hoveredProviderID = item.id
                        } else if hoveredProviderID == item.id {
                            hoveredProviderID = nil
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.seal")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)

            Text(L("Everything is already added", "已全部添加完成"))
                .font(.title3)
                .bold()

            Text(L("All supported sources are already part of your scan list.", "当前支持的来源都已经加入扫描列表了。"))
                .font(.body)
                .foregroundStyle(.secondary)

            Button {
                close()
            } label: {
                ProviderActionLabel(
                    title: L("Close", "关闭"),
                    systemImage: "xmark",
                    style: .primary,
                    minWidth: 96
                )
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)

            Text(L("No matching apps", "没有匹配的应用"))
                .font(.title3)
                .bold()

            Text(L("Try another keyword or clear the current filter.", "试试别的关键词，或者清空当前筛选。"))
                .font(.body)
                .foregroundStyle(.secondary)

            Button {
                searchText = ""
            } label: {
                ProviderActionLabel(
                    title: L("Clear Search", "清空搜索"),
                    systemImage: "xmark.circle",
                    minWidth: 102
                )
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: footerStatusIcon)
                    .font(.system(size: 12, weight: .semibold))

                Text(footerStatusText)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSubmitDisabled ? Color.secondary : Color.accentColor)

            Spacer(minLength: 16)

            if mode == .add || mode == .manage {
                Button {
                    close()
                } label: {
                    ProviderActionLabel(
                        title: L("Cancel", "取消"),
                        systemImage: "xmark",
                        minWidth: 82
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            Button {
                submit()
            } label: {
                ProviderActionLabel(
                    title: submitButtonTitle,
                    systemImage: submitButtonIcon,
                    style: .primary,
                    minWidth: 132
                )
            }
            .buttonStyle(.plain)
            .disabled(isSubmitDisabled)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(
            Rectangle()
                .fill(AppSurface.toolbar(colorScheme))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(AppStroke.subtle(colorScheme))
                        .frame(height: 0.5)
                }
        )
    }

    private func toggleSelection(for id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func submit() {
        switch mode {
        case .initialSetup:
            appState.completeInitialProviderSetup(with: selection)
        case .add:
            appState.addProviders(selection)
        case .manage:
            appState.updateProviderSelection(with: selection)
        }
        dismiss()
    }

    private func close() {
        appState.dismissProviderPicker()
        dismiss()
    }

    private func summaryBadge(text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: tint == .secondary ? "eye" : "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))

            Text(text)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint == .secondary ? .secondary : tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background((tint == .secondary ? Color.secondary : tint).opacity(colorScheme == .dark ? 0.18 : 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func previewPanel(for item: ProviderCatalogItem) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(selectionAccent(for: item).opacity(colorScheme == .dark ? 0.18 : 0.10))
                    .frame(width: 56, height: 56)

                ProviderIconView(item.id, size: 30)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.title(for: appState.language))
                        .font(.headline)
                        .foregroundStyle(.primary)

                    compactTag(
                        text: channelLabel(for: item),
                        tint: selectionAccent(for: item)
                    )

                    compactTag(
                        text: item.kind == .official ? L("Official", "官方") : L("Local", "本地"),
                        tint: item.kind == .official ? .secondary : .orange
                    )
                }

                Text(item.summary(for: appState.language))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text(L("Hover or click a tile to preview it here.", "悬停或点击下方磁贴，可以在这里查看简介。"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(AppSurface.card(colorScheme).opacity(colorScheme == .dark ? 0.72 : 1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
    }

    private func compactTag(text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint == .secondary ? .secondary : tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((tint == .secondary ? Color.secondary : tint).opacity(colorScheme == .dark ? 0.16 : 0.10))
            .clipShape(Capsule())
    }

    private func selectionAccent(for item: ProviderCatalogItem) -> Color {
        switch item.id {
        case "antigravity": return .cyan
        case "copilot": return .blue
        case "claude": return .orange
        case "cursor": return .green
        case "gemini": return .teal
        case "kimi": return Color(red: 0.09, green: 0.51, blue: 1.0)
        case "kiro": return .purple
        case "codex": return .indigo
        case "droid": return .yellow
        case "minimax": return Color(red: 0.886, green: 0.087, blue: 0.494)
        case "opencode": return Color(red: 0.18, green: 0.83, blue: 0.75)
        case "warp": return .pink
        default:
            switch item.channel {
            case "ide": return .green
            case "local": return .orange
            default: return .blue
            }
        }
    }

    private func channelLabel(for item: ProviderCatalogItem) -> String {
        switch item.channel {
        case "ide":
            return "IDE"
        case "local":
            return L("Local", "本地")
        default:
            return "CLI"
        }
    }

    private var headerDescription: String {
        switch mode {
        case .initialSetup:
            return L("Only checked apps and sources will be scanned when the dashboard refreshes.", "只有勾选的应用和来源会在刷新时被扫描。")
        case .add:
            return L("Add newly installed apps at any time without changing your current setup.", "以后安装了新应用，也可以随时追加，不会影响当前配置。")
        case .manage:
            return L("Turn sources on or off without deleting saved accounts. Disabled sources stay in your account list but stop refreshing.", "你可以随时启用或停用扫描来源，而不必删除已保存账号。停用后账号仍会保留，但不会继续刷新。")
        }
    }

    private var headerTitle: String {
        switch mode {
        case .initialSetup:
            return L("Choose Sources to Scan", "选择要扫描的来源")
        case .add:
            return L("Add More Sources", "添加更多来源")
        case .manage:
            return L("Manage Scan Sources", "管理扫描来源")
        }
    }

    private var submitButtonTitle: String {
        switch mode {
        case .initialSetup:
            return L("Start Scanning", "开始扫描")
        case .add:
            return L("Add Selected", "添加所选")
        case .manage:
            return L("Apply Changes", "应用变更")
        }
    }

    private var submitButtonIcon: String {
        switch mode {
        case .initialSetup:
            return "play.fill"
        case .add:
            return "plus"
        case .manage:
            return "checkmark"
        }
    }

    private var footerStatusIcon: String {
        isSubmitDisabled ? "circle.dashed" : "checkmark.circle.fill"
    }

    private var footerStatusText: String {
        switch mode {
        case .initialSetup:
            return selection.isEmpty
                ? L("Choose at least one source", "至少选择一个来源")
                : L("\(selection.count) sources ready", "已准备 \(selection.count) 个来源")
        case .add:
            return selection.isEmpty
                ? L("No apps selected", "未选择应用")
                : L("\(selection.count) apps selected", "已选 \(selection.count) 个应用")
        case .manage:
            return selection == appState.selectedProviderIds
                ? L("No changes to apply", "没有需要应用的变更")
                : L("\(selection.count) sources enabled", "已启用 \(selection.count) 个来源")
        }
    }

    private var isSubmitDisabled: Bool {
        switch mode {
        case .initialSetup:
            return selection.isEmpty
        case .add:
            return selection.isEmpty
        case .manage:
            return selection == appState.selectedProviderIds
        }
    }
}

private struct SourceSelectionCard: View {
    let item: ProviderCatalogItem
    let isSelected: Bool
    let language: String
    let colorScheme: ColorScheme
    let action: () -> Void

    private var title: String {
        language == "zh" ? item.titleZh : item.titleEn
    }

    private var accentColor: Color {
        switch item.id {
        case "antigravity": return .cyan
        case "copilot": return .blue
        case "claude": return .orange
        case "cursor": return .green
        case "gemini": return .teal
        case "kimi": return Color(red: 0.09, green: 0.51, blue: 1.0)
        case "kiro": return .purple
        case "codex": return .indigo
        case "droid": return .yellow
        case "minimax": return Color(red: 0.886, green: 0.087, blue: 0.494)
        case "opencode": return Color(red: 0.18, green: 0.83, blue: 0.75)
        case "warp": return .pink
        default:
            switch item.channel {
            case "ide": return .green
            case "local": return .orange
            default: return .blue
            }
        }
    }

    private var channelText: String {
        switch item.channel {
        case "ide":
            return "IDE"
        case "local":
            return language == "zh" ? "本地" : "Local"
        default:
            return "CLI"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                HStack {
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? accentColor : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(accentColor.opacity(colorScheme == .dark ? 0.18 : 0.10))
                        .frame(width: 52, height: 52)

                    ProviderIconView(item.id, size: 28)
                }

                VStack(spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity)

                    pill(text: channelText, tint: accentColor)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .top)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(isSelected ? accentColor.opacity(colorScheme == .dark ? 0.18 : 0.08) : cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(isSelected ? accentColor.opacity(0.9) : borderColor, lineWidth: isSelected ? 1.6 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var cardBackground: Color {
        AppSurface.card(colorScheme)
    }

    private var borderColor: Color {
        AppStroke.card(colorScheme)
    }

    private func pill(text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(colorScheme == .dark ? 0.16 : 0.10))
            .clipShape(Capsule())
    }
}
