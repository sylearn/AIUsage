import SwiftUI
import AppKit

// MARK: - Claude Science Proxy Management View
// Science 只有一套完整节点模型目录，不暴露 Code/Desktop 的模型模式概念。
// 首屏只保留运行、模型和常用设置；接管真实实例等低频选项收进整行可点击的高级设置。

struct ScienceProxyManagementView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var manager = ScienceProxyManager.shared
    @ObservedObject private var proxyVM = ProxyViewModel.shared

    @State private var proxyPortText = ""
    @State private var sciencePortText = ""
    @State private var selectedNodeId = ""
    @State private var adoptReal = false
    @State private var showAdvanced = false
    @State private var showPortHelp = false
    @State private var showWorkspaceHelp = false
    @State private var showModelHelp = false
    @State private var showAllModels = false
    @State private var modelSearchText = ""
    @State private var showNewWorkspaceAlert = false
    @State private var showRenameWorkspaceAlert = false
    @State private var showDeleteWorkspaceConfirm = false
    @State private var showResetWorkspaceConfirm = false
    @State private var workspaceNameDraft = ""
    @State private var workspacePendingRenameId: String?

    static let brand = Color(red: 0.55, green: 0.36, blue: 0.96)

    private var nodes: [GlobalProxyNodeRef] { manager.availableNodes() }
    private var isEnabled: Bool { manager.isEnabled }
    private var workspaces: [ScienceWorkspace] { manager.config.effectiveScienceWorkspaces }
    private var activeWorkspace: ScienceWorkspace { manager.config.effectiveActiveScienceWorkspace }
    private var workspaceControlsEnabled: Bool { !adoptReal }
    private var selectedModelCatalog: ScienceModelCatalog? {
        guard !resolvedSelection.isEmpty else { return nil }
        return manager.modelCatalog(for: resolvedSelection)
    }
    private var filteredModels: [ScienceModelCatalog.Model] {
        guard let catalog = selectedModelCatalog else { return [] }
        let query = modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return catalog.models }
        return catalog.models.filter {
            $0.upstreamModel.localizedCaseInsensitiveContains(query)
                || $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
        }
    }
    private var visibleModels: ArraySlice<ScienceModelCatalog.Model> {
        if !modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || showAllModels {
            return filteredModels[...]
        }
        return filteredModels.prefix(4)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = manager.operationError {
                    errorBanner(error)
                }
                if !manager.scienceInstalled {
                    notInstalledCard
                }
                heroCard
                if nodes.isEmpty {
                    noNodesCard
                }
                modelCatalogCard
                configCard
            }
            .frame(maxWidth: 960)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: syncFromConfig)
        .onChange(of: resolvedSelection) { _, _ in
            showAllModels = false
            modelSearchText = ""
        }
        .alert(L("New Workspace", "新建工作区"), isPresented: $showNewWorkspaceAlert) {
            TextField(L("Name", "名称"), text: $workspaceNameDraft)
            Button(L("Cancel", "取消"), role: .cancel) { workspaceNameDraft = "" }
            Button(L("Create", "创建")) {
                manager.addWorkspace(named: workspaceNameDraft)
                workspaceNameDraft = ""
            }
        } message: {
            Text(L("Each workspace keeps its own conversations and local login.",
                     "每个工作区有独立的对话与本地登录状态。"))
        }
        .alert(L("Rename Workspace", "重命名工作区"), isPresented: $showRenameWorkspaceAlert) {
            TextField(L("Name", "名称"), text: $workspaceNameDraft)
            Button(L("Cancel", "取消"), role: .cancel) {
                workspaceNameDraft = ""
                workspacePendingRenameId = nil
            }
            Button(L("Save", "保存")) {
                if let id = workspacePendingRenameId {
                    manager.renameWorkspace(id: id, to: workspaceNameDraft)
                }
                workspaceNameDraft = ""
                workspacePendingRenameId = nil
            }
        }
        .confirmationDialog(
            L("Delete this workspace?", "删除此工作区？"),
            isPresented: $showDeleteWorkspaceConfirm,
            titleVisibility: .visible
        ) {
            Button(L("Delete", "删除"), role: .destructive) {
                manager.deleteWorkspace(id: activeWorkspace.id)
            }
            Button(L("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(L("Its local data folder will be removed. This cannot be undone.",
                     "将删除其本地数据目录，且不可恢复。"))
        }
        .confirmationDialog(
            L("Reset this workspace?", "重置当前工作区？"),
            isPresented: $showResetWorkspaceConfirm,
            titleVisibility: .visible
        ) {
            Button(L("Reset", "重置"), role: .destructive) {
                manager.resetSandbox()
            }
            Button(L("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(L(
                "Conversations and local login in “\(displayName(for: activeWorkspace))” will be cleared. The workspace itself stays.",
                "将清空「\(displayName(for: activeWorkspace))」中的对话与本地登录，工作区本身保留。"
            ))
        }
    }

    private var notInstalledCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(L(
                "Claude Science is not installed. Install it to /Applications first.",
                "未检测到 Claude Science，请先安装到「应用程序」。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.10)))
    }

    // MARK: - Hero Card

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "atom")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Self.brand)
                Text("Claude Science")
                    .font(.headline.weight(.bold))
                Spacer(minLength: 12)
                if !nodes.isEmpty {
                    GlobalProxyChipMenu(
                        brand: Self.brand,
                        title: currentNodeName,
                        systemImage: "bolt.fill",
                        isDisabled: manager.isBusy,
                        items: nodes.map { GlobalProxyPickerItem(id: $0.id, name: $0.name) },
                        selectedId: nodeBinding.wrappedValue,
                        onSelect: { nodeBinding.wrappedValue = $0 }
                    )
                }
                if manager.isBusy { ProgressView().controlSize(.small) }
            }

            statusLine

            HStack(spacing: 10) {
                primaryButton
                if isEnabled {
                    Button {
                        manager.openInBrowser()
                    } label: {
                        Label(L("Open in Browser", "打开浏览器"), systemImage: "safari")
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isEnabled ? Self.brand.opacity(0.5) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.2), value: isEnabled)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isEnabled ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            if isEnabled {
                let sciLabel = manager.adoptReal
                    ? L("real instance", "真实实例")
                    : L("sandbox", "隔离沙箱")
                Text(L(
                    "Running · \(sciLabel) · web 127.0.0.1:\(manager.listenPort)",
                    "运行中 · \(sciLabel) · 网页 127.0.0.1:\(manager.listenPort)"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                if !manager.sandboxHealthy {
                    Text(L("(starting…)", "（启动中…）"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } else {
                Text(L("Stopped", "已停用"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if isEnabled {
            Button {
                Task { await manager.stop() }
            } label: {
                Label(L("Stop", "停止"), systemImage: "stop.fill")
                    .frame(minWidth: 120)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(manager.isBusy)
        } else {
            Button {
                let target = resolvedSelection
                guard !target.isEmpty else { return }
                Task { await manager.start(activeNodeId: target) }
            } label: {
                Label(L("One-Click Start", "一键开始"), systemImage: "play.fill")
                    .frame(minWidth: 120)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(Self.brand)
            .disabled(manager.isBusy || nodes.isEmpty || !manager.scienceInstalled)
        }
    }

    private var currentNodeName: String {
        let id = nodeBinding.wrappedValue
        return nodes.first(where: { $0.id == id })?.name ?? L("Select", "选择")
    }

    // MARK: - No Nodes

    private var noNodesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("No upstream node yet", "还没有可用的上游节点"))
                .font(.subheadline.weight(.semibold))
            Text(L(
                "Claude Science reuses your Claude family nodes. Add one on the “Claude Code Proxy” page first (any OpenAI-compatible or Anthropic upstream).",
                "Claude Science 复用你的 Claude 家族节点。请先在「Claude Code 代理」页添加一个上游节点（任意 OpenAI 兼容 / Anthropic 上游）。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - Model Catalog

    private var modelCatalogCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            modelCatalogHeader

            if let catalog = selectedModelCatalog, !catalog.models.isEmpty {
                if filteredModels.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                        Text(L("No matching models", "没有匹配的模型"))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 58)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(visibleModels, id: \.id) { model in
                            scienceModelRow(model)
                        }
                    }

                    if modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       catalog.models.count > 4 {
                        Button {
                            if reduceMotion {
                                showAllModels.toggle()
                            } else {
                                withAnimation(.easeOut(duration: 0.16)) { showAllModels.toggle() }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showAllModels ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                Text(showAllModels
                                    ? L("Show less", "收起")
                                    : L("Show all \(catalog.models.count) models", "显示全部 \(catalog.models.count) 个模型"))
                                    .font(.caption.weight(.semibold))
                            }
                            .frame(minHeight: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Self.brand)
                    }
                }
            } else {
                Text(L(
                    "Choose a node with at least one available model.",
                    "请选择至少包含一个可用模型的节点。"
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private var modelCatalogHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Self.brand)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10).fill(Self.brand.opacity(0.11)))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(L("Science models", "Science 模型"))
                        .font(.headline)
                    if let count = selectedModelCatalog?.models.count {
                        Text(L("\(count) models", "\(count) 个"))
                            .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(Self.brand)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Self.brand.opacity(0.10)))
                    }
                }
                Text(L(
                    "All models from the active node; switch inside Science at any time",
                    "完整展示当前节点模型，可随时在 Science 内切换"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)
            modelSearchField
            modelHelpButton
        }
    }

    private var modelSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(L("Search models", "搜索模型"), text: $modelSearchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            if !modelSearchText.isEmpty {
                Button {
                    modelSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Clear search", "清除搜索"))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(width: 210, height: 32)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.065)))
    }

    private var modelHelpButton: some View {
        Button {
            showModelHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("About Science models", "关于 Science 模型"))
        .popover(isPresented: $showModelHelp, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 9) {
                Label(L("One complete catalog", "一个完整模型目录"), systemImage: "square.stack.3d.up.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Self.brand)
                helpRow(
                    "arrow.left.arrow.right",
                    L(
                        "There is no hot-switch/node-model mode here. Every model is equal and selectable in Science.",
                        "这里没有热切换与节点模型模式；所有模型平级，均可在 Science 内选择。"
                    )
                )
                helpRow(
                    "textformat.123",
                    L(
                        "Science decides its 1M beta from model identity and account capability; it does not expose Desktop's per-model 1M switch.",
                        "Science 会按模型身份与账号能力决定 1M beta，并未开放 Desktop 那种逐模型 1M 开关。"
                    )
                )
            }
            .padding(14)
            .frame(width: 310, alignment: .leading)
        }
    }

    private func scienceModelRow(_ model: ScienceModelCatalog.Model) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "atom")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Self.brand.opacity(0.88))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Self.brand.opacity(0.10)))
            Text(model.upstreamModel)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.033)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.055), lineWidth: 1))
        .help(model.description)
        .accessibilityLabel(model.upstreamModel)
    }

    // MARK: - Config Card

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Self.brand)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Self.brand.opacity(0.11)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Science settings", "Science 设置"))
                        .font(.headline)
                    Text(isEnabled
                        ? L("Stop Science to edit these settings", "停止 Science 后可修改设置")
                        : L("Workspace and local connection settings", "工作区与本地连接设置"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if isEnabled {
                runningSettingsGrid
            } else {
                workspaceSection
                advancedSettingsButton
                if showAdvanced {
                    VStack(alignment: .leading, spacing: 10) {
                        portsSettingRow
                        Divider()
                        adoptToggle
                        Divider()
                        dataLocationRow
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.022))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Self.brand.opacity(0.11), lineWidth: 1)
                    )
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private var runningSettingsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 190, maximum: 300), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            settingsSummaryTile(
                icon: manager.adoptReal ? "macwindow.on.rectangle" : "shippingbox.fill",
                title: L("Mode", "运行方式"),
                value: manager.adoptReal ? L("Real instance", "真实实例") : L("Sandbox", "隔离沙箱")
            )
            if !manager.adoptReal {
                settingsSummaryTile(
                    icon: "square.stack.3d.up.fill",
                    title: L("Workspace", "工作区"),
                    value: displayName(for: activeWorkspace)
                )
            }
            settingsSummaryTile(
                icon: "arrow.triangle.branch",
                title: L("Inference proxy", "推理代理"),
                value: "127.0.0.1:\(manager.config.port)"
            )
            settingsSummaryTile(
                icon: "safari.fill",
                title: L("Web Access", "网页访问"),
                value: "127.0.0.1:\(manager.listenPort)"
            )
        }
    }

    private func settingsSummaryTile(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.brand)
                .frame(width: 25, height: 25)
                .background(RoundedRectangle(cornerRadius: 7).fill(Self.brand.opacity(0.09)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.05), lineWidth: 1))
    }

    private var portsSettingRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                settingIcon("network")
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Local ports", "本地端口"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(L(
                        "Used only on this Mac. Change them only when a port conflicts.",
                        "仅供本机使用；只有端口冲突时才需要修改。"
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                portsHelpButton
            }

            HStack(alignment: .bottom, spacing: 12) {
                compactPortField(
                    label: L("Inference proxy", "推理代理"),
                    placeholder: "14402",
                    text: $proxyPortText
                )
                if adoptReal {
                    fixedPortField(
                        label: L("Web access", "网页访问"),
                        port: GlobalProxyConfig.realInstancePort
                    )
                } else {
                    compactPortField(
                        label: L("Web access", "网页访问"),
                        placeholder: "14410",
                        text: $sciencePortText
                    )
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .background(settingRowBackground)
    }

    private func compactPortField(
        label: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11).monospacedDigit())
                .frame(width: 104)
                .onChange(of: text.wrappedValue) { _, newValue in
                    let filtered = String(newValue.filter(\.isNumber).prefix(5))
                    if filtered != newValue {
                        text.wrappedValue = filtered
                    } else {
                        commitSettings()
                    }
                }
        }
    }

    private func fixedPortField(label: String, port: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(L("Fixed", "固定"))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Self.brand)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Self.brand.opacity(0.10)))
            }
            Text("\(port)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(width: 104, height: 23, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.06)))
        }
    }

    private var portsHelpButton: some View {
        Button {
            showPortHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("About local ports", "关于本地端口"))
        .popover(isPresented: $showPortHelp, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 9) {
                Label(L("What are these ports for?", "这两个端口有什么用？"), systemImage: "network")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Self.brand)
                helpRow(
                    "arrow.triangle.branch",
                    L(
                        "Inference proxy: Science sends model requests here, then AIUsage forwards them to the active node.",
                        "推理代理：Science 把模型请求发到这里，再由 AIUsage 转发给当前节点。"
                    )
                )
                helpRow(
                    "safari",
                    L(
                        "Web access: this is the address opened in your browser.",
                        "网页访问：浏览器打开 Science 时使用这个地址。"
                    )
                )
                helpRow(
                    "lock.fill",
                    L(
                        "Both listen on 127.0.0.1 only. They are not exposed to your local network.",
                        "两个端口都只监听 127.0.0.1，不会开放给局域网。"
                    )
                )
                helpRow(
                    "arrow.clockwise",
                    adoptReal
                        ? L(
                            "Real-instance mode fixes web access at 8765. The inference proxy remains configurable.",
                            "接管真实实例时，网页访问固定为 8765；推理代理仍可修改。"
                        )
                        : L(
                            "Changes take effect the next time Science starts.",
                            "修改后会在下次启动 Science 时生效。"
                        )
                )
            }
            .padding(14)
            .frame(width: 330, alignment: .leading)
        }
    }

    private var advancedSettingsButton: some View {
        Button {
            if reduceMotion {
                showAdvanced.toggle()
            } else {
                withAnimation(.easeOut(duration: 0.16)) { showAdvanced.toggle() }
            }
        } label: {
            HStack(spacing: 12) {
                settingIcon("gearshape.2.fill")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(L("Advanced settings", "高级设置"))
                            .font(.system(size: 12, weight: .semibold))
                        if adoptReal {
                            Text(L("Real instance on", "已接管真实实例"))
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Self.brand)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Self.brand.opacity(0.10)))
                        }
                    }
                    Text(L("Local ports, real-instance adoption, and data location", "本地端口、真实实例接管与数据目录"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(showAdvanced ? 180 : 0))
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .contentShape(Rectangle())
            .background(settingRowBackground)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("Advanced settings", "高级设置"))
        .accessibilityValue(showAdvanced ? L("Expanded", "已展开") : L("Collapsed", "已收起"))
    }

    // MARK: - Workspace

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                settingIcon("square.stack.3d.up.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Workspace", "工作区"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(L("Independent conversations and local login", "独立对话与本地登录"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                GlobalProxyChipMenu(
                    brand: Self.brand,
                    title: displayName(for: activeWorkspace),
                    systemImage: "square.stack.3d.up.fill",
                    isDisabled: !workspaceControlsEnabled || manager.isBusy,
                    items: workspaces.map {
                        GlobalProxyPickerItem(id: $0.id, name: displayName(for: $0))
                    },
                    selectedId: activeWorkspace.id,
                    onSelect: { id in
                        Task { await manager.selectWorkspace(id: id) }
                    },
                    footerActions: workspaceFooterActions,
                    emptyMessage: L("No workspaces", "暂无工作区")
                )
                Button {
                    manager.openSandboxFolder()
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help(L("Show in Finder", "在 Finder 中显示"))
                .disabled(!workspaceControlsEnabled)

                workspaceHelpButton
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(settingRowBackground)

            if adoptReal {
                Text(L("Workspaces are available in sandbox mode only.", "工作区仅在隔离沙箱模式下可用。"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
        }
    }

    private func settingIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Self.brand)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 9).fill(Self.brand.opacity(0.09)))
    }

    private var settingRowBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.026))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
    }

    private var workspaceFooterActions: [GlobalProxyChipMenuAction] {
        [
            GlobalProxyChipMenuAction(
                id: "new",
                title: L("New Workspace…", "新建工作区…"),
                systemImage: "plus",
                action: {
                    workspaceNameDraft = ""
                    showNewWorkspaceAlert = true
                }
            ),
            GlobalProxyChipMenuAction(
                id: "rename",
                title: L("Rename…", "重命名…"),
                systemImage: "pencil",
                isDisabled: workspaces.isEmpty,
                action: {
                    workspacePendingRenameId = activeWorkspace.id
                    workspaceNameDraft = displayName(for: activeWorkspace)
                    showRenameWorkspaceAlert = true
                }
            ),
            GlobalProxyChipMenuAction(
                id: "reset",
                title: L("Reset Workspace…", "重置工作区…"),
                systemImage: "arrow.counterclockwise",
                isDestructive: true,
                isDisabled: isEnabled,
                action: { showResetWorkspaceConfirm = true }
            ),
            GlobalProxyChipMenuAction(
                id: "delete",
                title: L("Delete…", "删除…"),
                systemImage: "trash",
                isDestructive: true,
                isDisabled: workspaces.count <= 1 || isEnabled,
                action: { showDeleteWorkspaceConfirm = true }
            ),
        ]
    }

    private var dataLocationRow: some View {
        HStack(spacing: 10) {
            settingIcon("externaldrive.fill")
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Data folder", "数据目录"))
                    .font(.system(size: 11.5, weight: .semibold))
                Text(manager.sandboxHome.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(manager.sandboxHome, forType: .string)
            } label: {
                Label(L("Copy", "复制"), systemImage: "doc.on.doc")
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.055)))
            }
            .buttonStyle(.plain)
        }
        .opacity(adoptReal ? 0.45 : 1)
    }

    private func displayName(for workspace: ScienceWorkspace) -> String {
        if workspace.id == GlobalProxyConfig.defaultScienceWorkspaceId,
           workspace.name == GlobalProxyConfig.defaultScienceWorkspaceName {
            return L("Default", "默认")
        }
        return workspace.name
    }

    private var workspaceHelpButton: some View {
        Button {
            showWorkspaceHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("About workspaces", "关于工作区"))
        .popover(isPresented: $showWorkspaceHelp, arrowEdge: .bottom) {
            workspaceHelpBubble
        }
    }

    private var workspaceHelpBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("Sandbox workspaces", "沙箱工作区"), systemImage: "square.stack.3d.up.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Self.brand)
            helpRow("externaldrive", L("Each workspace has its own data folder and conversation history.",
                                       "每个工作区有独立数据目录与对话历史。"))
            helpRow("wifi.slash", L("Local login only — never contacts Anthropic.",
                                    "仅本地登录，绝不联系 Anthropic。"))
            helpRow("arrow.triangle.2.circlepath", L("Switching workspaces restarts Science with that folder.",
                                                     "切换工作区会用对应目录重启 Science。"))
            helpRow("trash", L("Reset clears only the current workspace.",
                               "重置只清空当前工作区。"))
        }
        .padding(14)
        .frame(width: 288, alignment: .leading)
    }

    private func helpRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var adoptToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { adoptReal },
                set: { newValue in
                    adoptReal = newValue
                    manager.setAdoptReal(newValue)
                }
            )) {
                HStack(spacing: 10) {
                    settingIcon("macwindow.on.rectangle")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Adopt real instance", "接管真实实例"))
                            .font(.system(size: 12, weight: .semibold))
                        Text(L(
                            "Make Claude Science.app login-free · uses port 8765 · disables workspaces",
                            "让 Claude Science.app 免登录 · 占用 8765 · 停用工作区"
                        ))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentShape(Rectangle())
            }
            .toggleStyle(.switch)
            .tint(Self.brand)

            if adoptReal {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(L(
                        "Runs an isolated daemon and only rewrites the runtime lock; your real login is never touched.",
                        "在独立目录起 daemon，仅改写运行期锁文件，不触碰你的真实登录。"
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.10)))
    }

    // MARK: - Bindings

    private var nodeBinding: Binding<String> {
        Binding(
            get: { isEnabled ? (manager.activeNodeId ?? resolvedSelection) : resolvedSelection },
            set: { newId in
                selectedNodeId = newId
                if isEnabled {
                    Task { await manager.switchActiveNode(to: newId) }
                }
            }
        )
    }

    private var resolvedSelection: String {
        if !selectedNodeId.isEmpty, nodes.contains(where: { $0.id == selectedNodeId }) {
            return selectedNodeId
        }
        return manager.activeNodeId ?? nodes.first?.id ?? ""
    }

    // MARK: - Helpers

    private func syncFromConfig() {
        proxyPortText = "\(manager.config.port)"
        sciencePortText = "\(manager.config.effectiveSciencePort)"
        adoptReal = manager.adoptReal
        selectedNodeId = resolvedSelection
        showAdvanced = manager.adoptReal
    }

    private func commitSettings() {
        guard !isEnabled else { return }
        let proxyPort = Int(proxyPortText.trimmingCharacters(in: .whitespaces)) ?? manager.config.port
        let sciencePort = Int(sciencePortText.trimmingCharacters(in: .whitespaces)) ?? manager.config.effectiveSciencePort
        manager.updateSettings(proxyPort: proxyPort, sciencePort: sciencePort)
    }
}

#Preview {
    ScienceProxyManagementView()
        .frame(width: 900, height: 700)
}
