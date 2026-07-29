import SwiftUI
import UniformTypeIdentifiers
import QuotaBackend

// MARK: - Proxy Management View
// 节点管理主视图：容器与生命周期（family 过滤、空态、各类 sheet/alert）。
// 工具栏/汇总条、节点列表/拖拽、展开统计、节点卡片分别拆到 ProxyManagementView+*.swift。

struct ProxyManagementView: View {
    /// 节点家族过滤：Claude 菜单只列 Claude 家族节点，Codex 菜单只列 Codex 节点。
    var family: ProxyNodeFamily = .claude
    var showsClaudeProductConfiguration = true

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var viewModel: ProxyViewModel
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var codexGateway = GlobalProxyManager.codex
    @ObservedObject var claudeGateway = GlobalProxyManager.claude
    @ObservedObject var desktopGateway = GlobalProxyManager.desktop
    @ObservedObject var openCodeGateway = GlobalProxyManager.opencode
    @ObservedObject var claudeGatewayRuntime = GlobalProxyRuntime.claude
    @ObservedObject var desktopGatewayRuntime = GlobalProxyRuntime.desktop
    @ObservedObject var scienceProxy = ScienceProxyManager.shared
    @State var showingNewConfigEditor = false
    @State var editingConfig: ProxyConfiguration?
    @State var editingProfile: NodeProfile?
    @State var selectedConfigId: String?
    @State var pendingDeletionConfig: ProxyConfiguration?
    @State var draggingConfigId: String?
    @State var dragTranslation: CGFloat = 0
    @State var nodeRowHeights: [String: CGFloat] = [:]
    @State var showingImporter = false
    @State var showingExporter = false
    @State var importResult: NodeProfileStore.ImportResult?
    @State var showImportResult = false
    @State var exportSelectedIds: Set<String> = []
    @State var showingSettingsEditor = false
    @State var isSyncingCCSwitch = false

    // MARK: - Family Filtering

    /// 当前家族下展示的节点（Claude 家族过滤掉 codex，Codex 家族只留 codex）。
    var displayConfigs: [ProxyConfiguration] {
        viewModel.configurations.filter { family.contains($0.nodeType) }
    }

    /// Codex 订阅账号（OAuth，~/.codex/auth.json）。仅 Codex 家族用于统一切换器的「订阅账号」区。
    private var codexSubscriptionEntries: [ProviderAccountEntry] {
        guard family.isCodex else { return [] }
        return appState.providerAccountGroups.first { $0.providerId == "codex" }?.accounts ?? []
    }

    /// 是否有任何可展示内容：API 节点，或（Codex）订阅账号。决定显示空态还是列表。
    private var hasAnyContent: Bool {
        !displayConfigs.isEmpty || !codexSubscriptionEntries.isEmpty
    }

    /// 当前家族的激活节点 id（Claude 走 activatedConfigId，Codex 走 activatedCodexConfigId）。
    var familyActivatedId: String? {
        viewModel.activatedId(isCodex: family.isCodex)
    }

    /// 把过滤后列表的插入槽位换算为全局 `configurations` 数组下标，保证拖拽重排正确。
    func globalSlotIndex(forDisplayedIndex i: Int) -> Int {
        let displayed = displayConfigs
        if i < displayed.count {
            return viewModel.configurations.firstIndex(where: { $0.id == displayed[i].id })
                ?? viewModel.configurations.count
        }
        if let last = displayed.last,
           let gi = viewModel.configurations.firstIndex(where: { $0.id == last.id }) {
            return gi + 1
        }
        return viewModel.configurations.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Codex 专属：系统代理会拦截 codex 发往本地的请求导致 502，开启时顶部提示+一键修复。
            if family.isCodex {
                SystemProxyWarningBanner()
            }
            if !hasAnyContent {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        proxyRuntimeDownBanner
                        actionBar
                        summaryStrip
                        if family.isCodex {
                            // Codex 通用配置只管理激活时合并进 config.toml 的片段；实时文件入口统一放在顶部工具栏。
                            CodexGlobalConfigSection()
                            // 全局统一代理：固定入口 + 热切换激活节点（启用时接管 config.toml）。
                            CodexGlobalProxySection()
                            // 统一切换器（订阅账号 + API 节点，单一互斥激活）。
                            if !codexSubscriptionEntries.isEmpty {
                                CodexSubscriptionSection(entries: codexSubscriptionEntries)
                            }
                            // 订阅制不按 token 计费 → 不再设订阅定价，订阅用量仅在统计页按 token 呈现。
                        } else if showsClaudeProductConfiguration {
                            // 通用配置仅作用于 Claude 的 ~/.claude/settings.json。
                            GlobalConfigSection()
                            // 全局统一代理：固定入口 + 热切换激活节点（启用时接管 settings.json）。
                            ClaudeGlobalProxySection()
                        }
                        if !displayConfigs.isEmpty {
                            configurationsList
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json, .folder],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                let accessingURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
                let importResult = viewModel.profileStore.importProfiles(from: urls)
                for url in accessingURLs { url.stopAccessingSecurityScopedResource() }
                self.importResult = importResult
                self.showImportResult = true
                viewModel.loadConfigurations()
            case .failure:
                break
            }
        }
        .sheet(isPresented: $showingExporter) {
            ProfileExportView(
                profiles: viewModel.profileStore.profiles,
                selectedIds: $exportSelectedIds
            )
            .environmentObject(viewModel)
        }
        .alert(
            L("Import Result", "导入结果"),
            isPresented: $showImportResult,
            presenting: importResult
        ) { _ in
            Button("OK") { importResult = nil }
        } message: { result in
            Text(importResultMessage(result))
        }
        .sheet(isPresented: $showingSettingsEditor) {
            if family.isCodex {
                CodexConfigEditorView()
            } else {
                LocalSettingsEditorView()
            }
        }
        .sheet(isPresented: $showingNewConfigEditor) {
            if family.isCodex {
                CodexProxyEditorView()
                    .environmentObject(viewModel)
                    .environmentObject(appState)
            } else {
                ProxyConfigEditorView()
                    .environmentObject(viewModel)
                    .environmentObject(appState)
            }
        }
        .sheet(item: $editingProfile) { profile in
            if profile.metadata.nodeType.isCodex {
                CodexProxyEditorView(profile: profile)
                    .environmentObject(viewModel)
                    .environmentObject(appState)
            } else {
                ProxyConfigEditorView(profile: profile)
                    .environmentObject(viewModel)
                    .environmentObject(appState)
            }
        }
        .sheet(item: $editingConfig) { config in
            if config.nodeType.isCodex {
                CodexProxyEditorView(config: config)
                    .environmentObject(viewModel)
                    .environmentObject(appState)
            } else {
                ProxyConfigEditorView(config: config)
                    .environmentObject(viewModel)
                    .environmentObject(appState)
            }
        }
        .alert(
            L("Node Operation Failed", "节点操作失败"),
            isPresented: Binding(
                get: { viewModel.operationErrorMessage != nil },
                set: { newValue in
                    if !newValue {
                        viewModel.operationErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                viewModel.operationErrorMessage = nil
            }
        } message: {
            Text(viewModel.operationErrorMessage ?? "")
        }
        .alert(
            L("Delete Node?", "确认删除节点？"),
            isPresented: Binding(
                get: { pendingDeletionConfig != nil },
                set: { newValue in
                    if !newValue {
                        pendingDeletionConfig = nil
                    }
                }
            ),
            presenting: pendingDeletionConfig
        ) { config in
            Button(L("Delete", "删除"), role: .destructive) {
                let deletingConfig = config
                pendingDeletionConfig = nil
                Task { await deleteConfig(deletingConfig) }
            }
            Button(L("Cancel", "取消"), role: .cancel) {
                pendingDeletionConfig = nil
            }
        } message: { config in
            Text(
                L(
                    "This will permanently remove the node \"\(config.name)\" and its local proxy stats/logs.",
                    "这会永久删除节点“\(config.name)”及其本地代理统计和日志。"
                )
            )
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(L("No Nodes", "暂无节点"))
                .font(.title3.weight(.bold))
            Text(family.isCodex
                 ? L("Add a Codex proxy node to route Codex through an OpenAI-compatible upstream.",
                     "添加 Codex 代理节点，把 Codex 接入 OpenAI 兼容上游。")
                 : L("Add an Anthropic or OpenAI-compatible node to manage Claude Code endpoints.",
                     "添加 Anthropic 或 OpenAI 兼容节点来管理 Claude Code 端点。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: { showingNewConfigEditor = true }) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text(L("Add Node", "添加节点"))
                }
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: { syncCCSwitch() }) {
                HStack {
                    if isSyncingCCSwitch {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "tray.and.arrow.down.fill")
                    }
                    Text(isSyncingCCSwitch ? L("Importing cc-switch", "正在导入 cc-switch") : L("Import cc-switch", "导入 cc-switch"))
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05))
                .foregroundStyle(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSyncingCCSwitch)
            .help(L("Import nodes and common config from cc-switch.", "从 cc-switch 导入节点和通用配置。"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    func duplicateConfig(_ config: ProxyConfiguration) {
        if let duplicated = viewModel.profileStore.duplicate(config.id) {
            let newConfig = duplicated.metadata.proxy.toProxyConfiguration(metadata: duplicated.metadata)
            viewModel.configurations.insert(newConfig, at: 0)
            if newConfig.nodeType == .openaiProxy || newConfig.nodeType == .codexProxy {
                viewModel.statistics[newConfig.id] = .empty
                viewModel.recentLogs[newConfig.id] = []
            }
            viewModel.flushLogsRefresh()
        } else {
            let usedPorts = Set(viewModel.configurations.map(\.port))
            var newPort = config.port + 1
            while usedPorts.contains(newPort) && newPort < 65535 { newPort += 1 }

            let copy = ProxyConfiguration(
                name: config.name + " " + L("(Copy)", "(副本)"),
                nodeType: config.nodeType,
                anthropicBaseURL: config.anthropicBaseURL,
                anthropicAPIKey: config.anthropicAPIKey,
                usePassthroughProxy: config.usePassthroughProxy,
                host: config.host,
                port: newPort,
                allowLAN: config.allowLAN,
                upstreamBaseURL: config.upstreamBaseURL,
                openAIUpstreamAPI: config.openAIUpstreamAPI,
                upstreamAPIKey: config.upstreamAPIKey,
                expectedClientKey: config.expectedClientKey,
                defaultModel: config.defaultModel,
                modelMapping: config.modelMapping,
                modelCatalog: config.modelCatalog,
                maxOutputTokens: config.maxOutputTokens
            )
            viewModel.addConfiguration(copy)
        }
    }

    private func deleteConfig(_ config: ProxyConfiguration) async {
        if selectedConfigId == config.id { selectedConfigId = nil }
        await viewModel.deleteConfiguration(config.id)
    }

    // MARK: - Helpers

    /// 拼接导入结果提示文案（含通用配置导入说明）。
    /// 抽成普通函数，避免在 alert 的 @ViewBuilder message 闭包内做字符串累加导致类型推断失败。
    private func importResultMessage(_ result: NodeProfileStore.ImportResult) -> String {
        var notes = ""
        if result.importedGlobalConfig {
            notes += "\n" + L("Claude common config imported.", "Claude 通用配置已导入。")
        }
        if result.skippedGlobalConfig {
            notes += "\n" + L("Claude common config already exists, skipped.", "已有 Claude 通用配置，已跳过。")
        }
        if result.importedCodexGlobalConfig {
            notes += "\n" + L("Codex common config imported.", "Codex 通用配置已导入。")
        }
        var head = L(
            "\(result.succeeded) imported, \(result.failed) failed, \(result.skipped) skipped",
            "\(result.succeeded) 个导入成功，\(result.failed) 个失败，\(result.skipped) 个跳过"
        )
        if result.updated > 0 {
            head += L(", \(result.updated) updated", "，\(result.updated) 个已更新")
        }
        return head + notes
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    func formatRelativeTime(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Format Helpers

// formatCompactNumber is defined in Utilities.swift

func formatProxyCurrency(_ value: Double) -> String {
    formatCurrency(value)
}

#Preview {
    ProxyManagementView()
        .environmentObject(AppState.shared)
        .environmentObject(ProxyViewModel())
        .frame(width: 1100, height: 700)
}
