import SwiftUI
import QuotaBackend

// MARK: - MenuBarView Proxy Track Switcher
// 顶部控制台的三条轨道切换器（Codex / OpenCode / Claude Code）。每条都是一颗品牌色胶囊 chip，
// 点击在面板内弹出「自定义内嵌覆盖层」（非原生 Menu，因为菜单栏宿主是 transient NSPopover，
// 嵌套系统 popover 不可靠）。面板统一支持两种模式：
// Claude Code 始终通过自己的产品 Gateway；模型模式决定节点切换是热切换还是需要重启 Code。
// Codex/OpenCode 保留原有的每节点 / 全局代理两种生命周期。
// 三条轨道各自观察自己的 GlobalProxyManager（codex/claude/opencode），不再只认 Codex 一条。
// 依赖主视图的 proxyVM / openCodeStore / globalCodex / globalClaude / globalOpenCode / appState / openPanelTrack。

extension MenuBarView {

    // MARK: - Chip 触发器（控制台一行三颗）

    /// Claude / Codex 轨道的胶囊 chip：点击展开 / 收起本轨面板。
    func proxyTrackSwitcher(family: ProxyNodeFamily) -> some View {
        let track: GlobalProxyTrack = family.isCodex ? .codex : .claude
        let manager = family.isCodex ? globalCodex : globalClaude
        let globalEnabled = manager.isEnabled
        // The Claude Code chip reports the Code route only. A Desktop-only
        // Gateway must never make Code look enabled or hide its direct node.
        let routeManaged = globalEnabled
        let globalActiveNode = routeManaged ? manager.node(for: manager.activeNodeId) : nil

        let activeId = proxyVM.activatedId(isCodex: family.isCodex)
        let activeNode = proxyVM.configurations.first { $0.id == activeId }
        let title = family.isCodex ? "Codex" : "Claude Code"
        let brandAsset = family.isCodex ? "codex" : "claude"
        let accent = accentColor(family: family)

        // Codex 订阅账号也算「已生效」，用于 chip 文案。
        let subEntries = codexSubscriptionEntries(family: family)
        let activeSub = (activeNode == nil && !routeManaged)
            ? subEntries.first { ProviderActivationManager.shared.isActiveAccount($0) }
            : nil
        let isOn = activeNode != nil || activeSub != nil || routeManaged
        let activeLabel: String = {
            if routeManaged { return globalActiveNode?.name ?? L("Global proxy", "全局代理") }
            return activeNode?.name ?? activeSub?.accountPrimaryLabel ?? L("Off", "未启用")
        }()

        return chipButton(track: track) {
            trackSwitcherLabel(title: title, brandAsset: brandAsset, accent: accent,
                               isOn: isOn, activeLabel: activeLabel,
                               isGlobal: globalEnabled, isSelected: openPanelTrack == track)
        }
    }

    /// OpenCode 轨道的胶囊 chip。
    func openCodeTrackSwitcher() -> some View {
        let manager = globalOpenCode
        let globalEnabled = manager.isEnabled
        let globalActiveNode = globalEnabled ? manager.node(for: manager.activeNodeId) : nil

        let activeNode = openCodeStore.activeNode
        let isOn = activeNode != nil || globalEnabled
        let accent = OpenCodeManagementView.brand
        let activeLabel = globalEnabled
            ? (globalActiveNode?.name ?? L("Global proxy", "全局代理"))
            : (activeNode?.displayName ?? L("Off", "未启用"))

        return chipButton(track: .opencode) {
            trackSwitcherLabel(title: "OpenCode", brandAsset: "opencode", accent: accent,
                               isOn: isOn, activeLabel: activeLabel,
                               isGlobal: globalEnabled, isSelected: openPanelTrack == .opencode)
        }
    }

    /// chip 通用外壳：点击 toggle 本轨面板。
    private func chipButton<Label: View>(track: GlobalProxyTrack,
                                         @ViewBuilder label: () -> Label) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                openPanelTrack = (openPanelTrack == track) ? nil : track
            }
        } label: {
            label()
        }
        .buttonStyle(.plain)
    }

    func closePanel() {
        withAnimation(.easeOut(duration: 0.15)) { openPanelTrack = nil }
    }

    // MARK: - 内嵌覆盖层（自定义面板）

    /// 在控制台下方弹出的轨道面板覆盖层：上半部分（头部+chip 行）保持可点以便直接换轨，
    /// 其余区域半透明遮罩，点击即收起。
    @ViewBuilder
    func trackPanelOverlay(track: GlobalProxyTrack) -> some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.black.opacity(0.12))
                .padding(.top, 86)
                .contentShape(Rectangle())
                .onTapGesture { closePanel() }

            panelFor(track: track)
                .frame(width: 304)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
                .padding(.top, 90)
                .frame(maxWidth: .infinity)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func panelFor(track: GlobalProxyTrack) -> some View {
        switch track {
        case .codex:    codexClaudePanel(family: .codex)
        case .claude:   codexClaudePanel(family: .claude)
        case .opencode: openCodePanel()
        // Science 轨不在顶部控制台切换（其生命周期含沙箱/虚拟登录，统一在侧边栏「Claude Science 代理」页管理）。
        case .desktop, .science:  EmptyView()
        }
    }

    // MARK: - Claude / Codex 面板

    private func codexClaudePanel(family: ProxyNodeFamily) -> some View {
        let manager = family.isCodex ? globalCodex : globalClaude
        let globalEnabled = manager.isEnabled
        let routeManaged = globalEnabled
        let globalNodes = manager.availableNodes()
        let activeId = proxyVM.activatedId(isCodex: family.isCodex)
        let familyNodes = proxyVM.configurations.filter { family.contains($0.nodeType) }
        let title = family.isCodex ? "Codex" : "Claude Code"
        let brandAsset = family.isCodex ? "codex" : "claude"
        let accent = accentColor(family: family)

        var sections: [MenuBarTrackPanelSection] = []
        var onDeactivate: (() -> Void)?

        if routeManaged {
            sections = [hotSwapSection(manager: manager, nodes: globalNodes)]
        } else if family.isCodex {
            let subEntries = codexSubscriptionEntries(family: family)
            if !subEntries.isEmpty {
                sections.append(MenuBarTrackPanelSection(
                    id: "sub", title: L("Subscription", "订阅账号"),
                    rows: subEntries.map { entry in
                        let isActive = activeId == nil
                            && ProviderActivationManager.shared.isActiveAccount(entry)
                        let viewOnly = ProviderActivationManager.shared.isRemoteViewOnly(entry)
                        return MenuBarTrackPanelRow(id: entry.id, name: entry.accountPrimaryLabel,
                                                    subtitle: viewOnly ? ProviderActivationManager.remoteViewOnlyLabel : nil,
                                                    isActive: isActive, isDisabled: viewOnly) {
                            try? ProviderActivationManager.shared.activateAccount(entry: entry)
                            closePanel()
                        }
                    }))
            }
            if !familyNodes.isEmpty {
                sections.append(MenuBarTrackPanelSection(
                    id: "nodes", title: L("API Nodes", "API 节点"),
                    rows: familyNodes.map { perNodeRow($0) }))
            }
            onDeactivate = deactivateProxyClosure(activeId: activeId)
        } else {
            let mode = manager.config.effectiveClaudeCodeCatalogMode
            sections = [MenuBarTrackPanelSection(
                id: "code-gateway",
                title: mode == .smartRoutes
                    ? L("Code route · hot-switch", "Code 路由 · 热切换")
                    : L("Code route · restart required", "Code 路由 · 需重启"),
                rows: globalNodes.map { node in
                    MenuBarTrackPanelRow(
                        id: node.id,
                        name: node.name,
                        isActive: manager.activeNodeId == node.id && manager.isEnabled
                    ) {
                        Task {
                            if manager.isEnabled {
                                await manager.switchActiveNode(to: node.id)
                            } else {
                                await manager.enable(activeNodeId: node.id)
                            }
                        }
                        closePanel()
                    }
                }
            )]
            onDeactivate = nil
        }
        if sections.isEmpty {
            sections = [MenuBarTrackPanelSection(id: "empty", rows: [])]
        }

        let preferred = manager.activeNodeId ?? activeId ?? globalNodes.first?.id
        let picker: MenuBarModelPicker?
        if family.isCodex {
            picker = routeManaged
                ? globalRouteModelPicker(manager: manager)
                : codexNodeModelPicker(activeId: activeId)
        } else {
            picker = claudeCodeModelPicker(manager: manager)
        }
        return MenuBarTrackPanel(
            title: title, brandAsset: brandAsset, accent: accent, manager: manager,
            canEnableGlobal: !globalNodes.isEmpty,
            sections: sections,
            onDeactivateActiveNode: onDeactivate,
            onEnableGlobal: { guard let id = preferred else { return }
                Task { await manager.enable(activeNodeId: id) } },
            onDisableGlobal: { Task { await manager.disable() } },
            modelPicker: picker
        )
    }

    // MARK: - 模型选择（面板底部「模型」区）

    /// Codex / OpenCode 全局代理：在常驻代理里热替换上游真实模型，CLI 侧入口名不变。
    private func globalRouteModelPicker(manager: GlobalProxyManager) -> MenuBarModelPicker? {
        guard manager.isEnabled,
              let nodeId = manager.activeNodeId,
              let node = manager.node(for: nodeId) else { return nil }
        let models = manager.availableModels(for: nodeId)
        guard models.count > 1 else { return nil }
        return MenuBarModelPicker(
            nodeName: node.name,
            models: models,
            current: manager.routedModel(for: nodeId),
            note: L("Hot-swapped · running sessions keep working", "热切换 · 运行中的会话不受影响"),
            onSelect: { _, model in
                Task { await manager.switchRoutedModel(to: model, for: nodeId) }
            }
        )
    }

    /// Codex 每节点接入：改节点模型并重写 config.toml，新开的 Codex 会话生效。
    private func codexNodeModelPicker(activeId: String?) -> MenuBarModelPicker? {
        guard let activeId,
              let node = proxyVM.configurations.first(where: { $0.id == activeId }) else { return nil }
        let models = node.runtimeModelCatalog
        guard models.count > 1 else { return nil }
        return MenuBarModelPicker(
            nodeName: node.name,
            models: models,
            current: node.modelMapping.bigModel.name,
            note: L("Applies to new Codex sessions", "新开的 Codex 会话生效"),
            onSelect: { _, model in
                Task { await proxyVM.switchDefaultModel(nodeID: activeId, to: model) }
            }
        )
    }

    /// Claude Code Gateway：按「默认 / Opus / Sonnet / Haiku」四条路由分别覆盖当前节点的模型。
    /// 选回节点自身的默认值会移除覆盖，之后节点编辑仍会自动生效。
    private func claudeCodeModelPicker(manager: GlobalProxyManager) -> MenuBarModelPicker? {
        guard manager.isEnabled,
              let nodeId = manager.activeNodeId,
              let node = proxyVM.configurations.first(where: { $0.id == nodeId }) else { return nil }
        let models = node.runtimeModelCatalog
        guard models.count > 1 else { return nil }
        let resolved = manager.config.effectiveClaudeCodeModels(for: node)
        let routes = ClaudeAppModelRoute.allCases.map { route in
            MenuBarModelPicker.Route(
                id: route.rawValue,
                title: route == .defaultModel ? L("Default", "默认") : route.title,
                current: resolved.model(for: route)
            )
        }
        let hotSwitch = manager.config.effectiveClaudeCodeCatalogMode == .smartRoutes
        return MenuBarModelPicker(
            nodeName: node.name,
            models: models,
            routes: routes,
            note: hotSwitch
                ? L("Smart routes · applies immediately", "智能路由 · 立即生效")
                : L("Node catalog · restart Claude Code to apply", "节点目录 · 重启 Claude Code 后生效"),
            onSelect: { routeID, model in
                guard let route = routeID.flatMap(ClaudeAppModelRoute.init(rawValue:)) else { return }
                Task { await manager.updateClaudeCodeModelOverride(nodeID: nodeId, route: route, model: model) }
            }
        )
    }

    /// OpenCode 每节点接入：改「默认模型节点」的默认模型（即 opencode.json 顶层 model）。
    /// 节点解析与 OpenCodeNodeStore.rewriteManagedConfig 一致：手选的默认节点优先，否则取列表中第一个激活节点。
    private func openCodeNodeModelPicker() -> MenuBarModelPicker? {
        let activeIds = Set(openCodeStore.activeNodeIds)
        let chosen = openCodeStore.openCodeDefaultNodeId.flatMap { id in
            activeIds.contains(id) ? openCodeStore.nodes.first { $0.id == id } : nil
        }
        guard let node = chosen ?? openCodeStore.nodes.first(where: { activeIds.contains($0.id) }) else { return nil }
        let models = node.models
        guard models.count > 1 else { return nil }
        return MenuBarModelPicker(
            nodeName: node.displayName,
            models: models,
            current: node.effectiveDefaultModel,
            note: L("Applies to new OpenCode sessions", "新开的 OpenCode 会话生效"),
            onSelect: { _, model in
                guard let latest = openCodeStore.nodes.first(where: { $0.id == node.id }),
                      latest.models.contains(model), latest.defaultModel != model else { return }
                var updated = latest
                updated.defaultModel = model
                openCodeStore.upsert(updated)
            }
        )
    }

    // MARK: - OpenCode 面板

    private func openCodePanel() -> some View {
        let manager = globalOpenCode
        let globalEnabled = manager.isEnabled
        let globalNodes = manager.availableNodes()
        let accent = OpenCodeManagementView.brand
        let activeId = openCodeStore.activeNodeIds.last

        var sections: [MenuBarTrackPanelSection] = []
        var onDeactivate: (() -> Void)?

        if globalEnabled {
            sections = [hotSwapSection(manager: manager, nodes: globalNodes)]
        } else {
            let rows = openCodeStore.nodes.map { node -> MenuBarTrackPanelRow in
                let isActive = openCodeStore.activeNodeIds.contains(node.id)
                return MenuBarTrackPanelRow(
                    id: node.id, name: node.displayName, isActive: isActive,
                    isDisabled: !node.isComplete
                ) {
                    if isActive { try? openCodeStore.deactivate(node) }
                    else { Task { try? await openCodeStore.activate(node) } }
                    closePanel()
                }
            }
            sections = [MenuBarTrackPanelSection(id: "nodes", rows: rows)]
            if !openCodeStore.activeNodeIds.isEmpty {
                onDeactivate = { try? openCodeStore.deactivate(); closePanel() }
            }
        }

        let preferred = manager.activeNodeId ?? activeId ?? globalNodes.first?.id
        return MenuBarTrackPanel(
            title: "OpenCode", brandAsset: "opencode", accent: accent, manager: manager,
            canEnableGlobal: !globalNodes.isEmpty,
            sections: sections,
            onDeactivateActiveNode: onDeactivate,
            onEnableGlobal: { guard let id = preferred else { return }
                Task { await manager.enable(activeNodeId: id) } },
            onDisableGlobal: { Task { await manager.disable() } },
            modelPicker: globalEnabled
                ? globalRouteModelPicker(manager: manager)
                : openCodeNodeModelPicker()
        )
    }

    // MARK: - Section / Row 构造

    /// 全局代理 ON 时的「激活节点 · 热切换」分区。
    private func hotSwapSection(manager: GlobalProxyManager,
                                nodes: [GlobalProxyNodeRef]) -> MenuBarTrackPanelSection {
        let title = manager.track == .claude
            && manager.config.effectiveClaudeCodeCatalogMode == .fullNodeCatalog
            ? L("Active node · restart Code", "激活节点 · 需重启 Code")
            : L("Active node · hot-swap", "激活节点 · 热切换")
        return MenuBarTrackPanelSection(
            id: "hotswap",
            title: title,
            rows: nodes.map { node in
                MenuBarTrackPanelRow(id: node.id, name: node.name,
                                     isActive: manager.activeNodeId == node.id) {
                    Task { await manager.switchActiveNode(to: node.id) }
                    closePanel()
                }
            })
    }

    /// 每节点激活模式下的代理节点行（点击 = 写 CLI 配置激活 / 停用）。
    private func perNodeRow(_ config: ProxyConfiguration) -> MenuBarTrackPanelRow {
        MenuBarTrackPanelRow(id: config.id, name: config.name,
                             isActive: proxyVM.isNodeActivated(config.id)) {
            Task { await proxyVM.toggleActivation(config.id) }
            closePanel()
        }
    }

    private func deactivateProxyClosure(activeId: String?) -> (() -> Void)? {
        guard let activeId else { return nil }
        return { Task { await proxyVM.deactivateConfiguration(activeId) }; closePanel() }
    }

    private func codexSubscriptionEntries(family: ProxyNodeFamily) -> [ProviderAccountEntry] {
        guard family.isCodex else { return [] }
        return CodexSubscriptionOrderStore.shared.ordered(
            appState.providerAccountGroups.first { $0.providerId == "codex" }?.accounts ?? [])
    }

    private func accentColor(family: ProxyNodeFamily) -> Color {
        family.isCodex
            ? Color(red: 0.40, green: 0.52, blue: 0.92)
            : Color(red: 0.85, green: 0.45, blue: 0.25)
    }

    // MARK: - Chip 外观（单行品牌色药丸）

    /// 三个轨道 chip 共用的单行胶囊：品牌图标 + 文本（未启用=轨道名 / 已生效=生效名）。
    /// 全局态用一个极小的品牌色闪电图标标识；面板展开时描边加粗高亮。胶囊随内容收紧、在槽内居中。
    private func trackSwitcherLabel(
        title: String,
        brandAsset: String,
        accent: Color,
        isOn: Bool,
        activeLabel: String,
        isGlobal: Bool = false,
        isSelected: Bool = false
    ) -> some View {
        let primaryText = isOn ? activeLabel : title
        return HStack(spacing: 5) {
            ProviderIconView(brandAsset, size: 13)
                .opacity(isOn ? 1.0 : 0.5)

            if isGlobal {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(accent)
            }

            Text(primaryText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(isOn ? accent : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(accent.opacity(isSelected ? 0.18 : (isOn ? 0.12 : 0.05)))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(accent.opacity(isSelected ? 0.75 : (isOn ? 0.42 : 0.16)),
                              lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(Capsule(style: .continuous))
    }
}
