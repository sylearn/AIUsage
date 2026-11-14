import SwiftUI

// MARK: - Menu Bar Track Panel
// 顶部菜单栏三轨切换器的自定义面板（取代原生 Menu 行）。以内嵌覆盖层形式弹出，
// 因为菜单栏宿主是 transient NSPopover，嵌套系统 popover 不可靠。
// 组成：头部「全局代理」开关 + 端口/热切换说明（仅 ON）+ 高亮节点行 + 底部停用。
// 轨道差异（节点来源、订阅、动作）由调用方算成 section/closure 注入，本视图只渲染。

/// 面板内一行（节点 / 订阅账号）。
struct MenuBarTrackPanelRow: Identifiable {
    let id: String
    let name: String
    var subtitle: String? = nil
    var isActive: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void
}

/// 面板内一个分区（可选标题 + 若干行）。
struct MenuBarTrackPanelSection: Identifiable {
    let id: String
    var title: String? = nil
    let rows: [MenuBarTrackPanelRow]
}

/// 面板底部的「模型」区：当前生效节点的可选模型。
/// - 单模型轨（Codex / OpenCode）：`routes` 为空，直接切换 `current`。
/// - Claude Code：按「默认 / Opus / Sonnet / Haiku」四条路由分别覆盖，`routes` 给出各路由当前模型。
struct MenuBarModelPicker {
    struct Route: Identifiable, Equatable {
        let id: String
        let title: String
        let current: String
    }

    /// 模型所属节点名（标题里提示「改的是哪个节点」）。
    let nodeName: String
    let models: [String]
    var routes: [Route] = []
    var current: String? = nil
    /// 生效方式说明，如「热切换」「新会话生效」。
    var note: String? = nil
    /// (路由 id，单模型轨为 nil；模型名)
    let onSelect: (_ routeID: String?, _ model: String) -> Void
}

struct MenuBarTrackPanel: View {
    let title: String
    let brandAsset: String
    let accent: Color
    @ObservedObject var manager: GlobalProxyManager

    /// 该轨是否有可参与全局代理的节点（决定能否开启全局）。
    let canEnableGlobal: Bool
    /// 各分区（调用方按「全局开/关」模式算好）。
    let sections: [MenuBarTrackPanelSection]
    /// 每节点激活模式下的「停用当前节点」；无激活时为 nil。
    let onDeactivateActiveNode: (() -> Void)?
    /// 开启全局代理（调用方算好初始激活节点）。
    let onEnableGlobal: () -> Void
    /// 停用全局代理。
    let onDisableGlobal: () -> Void
    /// 当前生效节点的模型选择；nil = 无生效节点或只有一个模型。
    var modelPicker: MenuBarModelPicker? = nil

    @State private var isModelListExpanded = false
    @State private var selectedRouteID: String?
    @State private var modelQuery = ""

    private var isGlobal: Bool { manager.isEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isGlobal {
                Text(routeSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            if let t = section.title {
                                Text(t)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 2)
                            }
                            if section.rows.isEmpty {
                                Text(L("None", "暂无"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                            } else {
                                ForEach(section.rows) { row in
                                    MenuBarPanelRowView(row: row, accent: accent)
                                        .disabled(manager.isBusy)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            // 有模型区时节点列表让出一些高度，整个面板不至于超出菜单栏弹窗。
            .frame(maxHeight: modelPicker == nil ? 300 : 210)
            if let modelPicker {
                Divider()
                modelSection(modelPicker)
            }
            footer
        }
    }

    // MARK: - Model Section

    private func activeRoute(in picker: MenuBarModelPicker) -> MenuBarModelPicker.Route? {
        picker.routes.first { $0.id == selectedRouteID } ?? picker.routes.first
    }

    private func currentModel(in picker: MenuBarModelPicker) -> String? {
        activeRoute(in: picker)?.current ?? picker.current
    }

    @ViewBuilder
    private func modelSection(_ picker: MenuBarModelPicker) -> some View {
        let current = currentModel(in: picker)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { isModelListExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent)
                    Text(L("Model", "模型"))
                        .font(.system(size: 11, weight: .semibold))
                    Text(picker.nodeName)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text(current?.nilIfBlank ?? L("Not set", "未设置"))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(current?.nilIfBlank == nil ? Color.secondary : accent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isModelListExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(current ?? "")

            if !picker.routes.isEmpty {
                routeChips(picker)
            }

            if isModelListExpanded {
                modelList(picker, current: current)
            }

            if let note = picker.note {
                Text(note)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .disabled(manager.isBusy)
    }

    /// Claude Code 的四条路由：点选决定下方列表改哪一条，胶囊里直接显示该路由当前模型。
    private func routeChips(_ picker: MenuBarModelPicker) -> some View {
        let selected = activeRoute(in: picker)?.id
        return HStack(spacing: 4) {
            ForEach(picker.routes) { route in
                let isSelected = route.id == selected
                Button {
                    selectedRouteID = route.id
                    withAnimation(.easeInOut(duration: 0.16)) { isModelListExpanded = true }
                } label: {
                    VStack(spacing: 1) {
                        Text(route.title)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(isSelected ? accent : .secondary)
                        Text(Self.shortModelName(route.current))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(isSelected ? .primary : .tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? accent.opacity(0.14) : Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(isSelected ? accent.opacity(0.5) : Color.clear, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(route.current)
            }
        }
    }

    @ViewBuilder
    private func modelList(_ picker: MenuBarModelPicker, current: String?) -> some View {
        let query = modelQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let models = query.isEmpty
            ? picker.models
            : picker.models.filter { $0.localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: 4) {
            if picker.models.count > 8 {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    TextField(L("Filter models", "筛选模型"), text: $modelQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(models, id: \.self) { model in
                        modelRow(model, isCurrent: model == current) {
                            picker.onSelect(activeRoute(in: picker)?.id, model)
                            withAnimation(.easeInOut(duration: 0.16)) { isModelListExpanded = false }
                            modelQuery = ""
                        }
                    }
                    if models.isEmpty {
                        Text(L("No matching models", "没有匹配的模型"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 6)
                    }
                }
            }
            .frame(maxHeight: 156)
        }
    }

    private func modelRow(_ model: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: isCurrent ? "checkmark" : "circle")
                    .font(.system(size: isCurrent ? 9.5 : 6, weight: .bold))
                    .foregroundStyle(isCurrent ? accent : Color.secondary.opacity(0.4))
                    .frame(width: 12)
                Text(model)
                    .font(.system(size: 11, weight: isCurrent ? .semibold : .regular, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCurrent ? accent.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 路由胶囊里放不下完整模型名：去掉常见厂商前缀与日期后缀。
    private static func shortModelName(_ model: String) -> String {
        guard let trimmed = model.nilIfBlank else { return "—" }
        var name = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        for prefix in ["claude-", "gpt-"] where name.hasPrefix(prefix) && name.count > prefix.count + 3 {
            name.removeFirst(prefix.count)
        }
        if let range = name.range(of: #"-\d{8}$"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        return name
    }

    private var header: some View {
        HStack(spacing: 8) {
            ProviderIconView(brandAsset, size: 18)
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(accent)
                .lineLimit(1)
            Spacer(minLength: 8)
            if manager.isBusy {
                SmallProgressView().frame(width: 12, height: 12)
            }
            Text(manager.track == .claude ? L("Use Gateway", "接入 Gateway") : L("Global", "全局代理"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Toggle("", isOn: Binding(
                get: { isGlobal },
                set: { newValue in newValue ? onEnableGlobal() : onDisableGlobal() }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .tint(accent)
            .disabled(manager.isBusy || (!isGlobal && !canEnableGlobal))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var footer: some View {
        if isGlobal {
            Divider()
            footerButton(title: manager.track == .claude
                         ? L("Disconnect Code Gateway", "断开 Code Gateway")
                         : L("Disable global proxy", "停用全局代理"),
                         icon: "bolt.slash.fill", tint: .red, action: onDisableGlobal)
                .disabled(manager.isBusy)
        } else if let onDeactivateActiveNode {
            Divider()
            footerButton(title: L("Deactivate node", "停用当前节点"),
                         icon: "stop.circle", tint: .secondary, action: onDeactivateActiveNode)
        }
    }

    private var routeSummary: String {
        if manager.track == .claude,
           manager.config.effectiveClaudeCodeCatalogMode == .fullNodeCatalog {
            return L(
                "Fixed port :\(manager.config.port) · node models · restart Code",
                "固定端口 :\(manager.config.port) · 节点模型 · 需重启 Code"
            )
        }
        return L(
            "Fixed port :\(manager.config.port) · hot-swap",
            "固定端口 :\(manager.config.port) · 热切换"
        )
    }

    private func footerButton(title: String, icon: String, tint: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Row

private struct MenuBarPanelRowView: View {
    let row: MenuBarTrackPanelRow
    let accent: Color
    @State private var hovered = false

    var body: some View {
        Button(action: row.action) {
            HStack(spacing: 9) {
                Image(systemName: row.isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(row.isActive ? accent : Color.secondary.opacity(0.45))
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .font(.system(size: 12, weight: row.isActive ? .semibold : .regular))
                        .foregroundStyle(row.isDisabled ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let sub = row.subtitle {
                        Text(sub)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(row.isActive ? accent.opacity(0.16)
                          : (hovered ? Color.primary.opacity(0.06) : Color.clear))
            )
            .overlay(alignment: .leading) {
                if row.isActive {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(accent)
                        .frame(width: 3, height: 16)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.isDisabled)
        .padding(.horizontal, 8)
        .onHover { hovered = $0 }
    }
}
