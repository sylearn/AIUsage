import AppKit
import QuotaBackend
import SwiftUI

// MARK: - Editor Tabs

enum EditorTab: String, CaseIterable {
    case proxy
    case settings
    case json

    var label: String {
        switch self {
        case .proxy: return L("Proxy", "代理设置")
        case .settings: return L("Settings", "可视化配置")
        case .json: return L("JSON", "JSON 编辑")
        }
    }

    var icon: String {
        switch self {
        case .proxy: return "network"
        case .settings: return "slider.horizontal.3"
        case .json: return "curlybraces"
        }
    }
}

private enum NodeEditorSection: String, CaseIterable, Identifiable {
    case identity
    case connection
    case models
    case pricing

    var id: String { rawValue }
    var title: String {
        switch self {
        case .identity: return L("Basics", "基本信息")
        case .connection: return L("Connection", "连接")
        case .models: return L("Models", "模型")
        case .pricing: return L("Pricing", "模型费用")
        }
    }
    var symbol: String {
        switch self {
        case .identity: return "slider.horizontal.3"
        case .connection: return "arrow.left.arrow.right"
        case .models: return "square.stack.3d.up"
        case .pricing: return "dollarsign.circle"
        }
    }
    var help: String {
        switch self {
        case .identity:
            return L("Choose the upstream API protocol and give this reusable node a recognizable name.", "选择上游 API 协议，并为可复用节点设置清晰名称。")
        case .connection:
            return L(
                "Set the node endpoint, upstream credentials and access key here. LAN clients must provide the same access key.",
                "在这里设置节点端点、上游凭据与访问密钥；局域网设备也必须提供同一访问密钥。"
            )
        case .models:
            return L(
                "Sync exact model IDs from upstream, then choose the defaults offered to Code and Desktop. The node runtime does not remap aliases.",
                "从上游同步真实模型名称，再设置提供给 Code 与 Desktop 的默认映射；节点运行时不会二次转换别名。"
            )
        case .pricing:
            return L(
                "Optional prices only affect usage-cost estimates. Blank prices do not block a model; public matches are reviewed before they are applied.",
                "模型价格仅用于用量金额估算；留空不会影响模型使用，公开价格也会先预览再写入。"
            )
        }
    }
}

// MARK: - Interface Choice
// 接口类型三选一（与 OpenCode 的三卡片一致）。openaiProxy 内部的 Chat/Responses
// 子选项在此被拍平成两张卡，映射到 (nodeType, openAIUpstreamAPI)。
enum ClaudeInterfaceChoice: Hashable {
    case anthropic
    case openAIChatCompletions
    case openAIResponses
}

// MARK: - Proxy Config Editor

struct ProxyConfigEditorView: View {
    @EnvironmentObject var viewModel: ProxyViewModel
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme

    // 注：部分 @State 为 internal（去掉 private），以便 JSON 标签页/定价子区拆分到
    // ProxyConfigEditorView+JSONTab.swift / +Pricing.swift 后仍可访问（Swift private 为文件级）。
    @State var profile: NodeProfile
    @State private var isNew: Bool
    @State var selectedTab: EditorTab = .proxy
    @StateObject private var modelFetch = ModelFetchState()
    @State var jsonText: String = ""
    @State var jsonError: String?
    @State var finalJSONText: String = ""
    @State var finalJSONError: String?
    @State var globalConfigDraftSettings: [String: Any]?
    @State var isApplyingFinalJSONEdit = false
    @State private var selectedSection: NodeEditorSection = .identity
    @State private var helpSection: NodeEditorSection?
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var deletionError: String?
    @State private var copiedClientKey = false

    init(profile: NodeProfile? = nil) {
        if var profile {
            profile.metadata.proxy.seedModelCatalogIfEmpty()
            _profile = State(initialValue: profile)
            _isNew = State(initialValue: false)
            _jsonText = State(initialValue: profile.settingsJSONString)
            _pricingCurrency = State(
                initialValue: profile.metadata.proxy.modelCatalog.pricingOverrides.values.first?.currency ?? .usd
            )
        } else {
            var newProfile = NodeProfile.defaultProfile()
            newProfile.metadata.proxy.port = NodeProfileStore.shared.nextAvailablePort()
            newProfile.metadata.proxy.seedModelCatalogIfEmpty()
            _profile = State(initialValue: newProfile)
            _isNew = State(initialValue: true)
            _jsonText = State(initialValue: newProfile.settingsJSONString)
            _pricingCurrency = State(initialValue: .usd)
        }
    }

    /// Legacy init wrapping a ProxyConfiguration for callers not yet migrated.
    init(config: ProxyConfiguration) {
        var p = NodeProfile.fromLegacyConfiguration(config)
        p.metadata.proxy.seedModelCatalogIfEmpty()
        _profile = State(initialValue: p)
        _isNew = State(initialValue: false)
        _jsonText = State(initialValue: p.settingsJSONString)
        _pricingCurrency = State(
            initialValue: p.metadata.proxy.modelCatalog.pricingOverrides.values.first?.currency ?? .usd
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            proxyTab
            .frame(maxHeight: .infinity)

            Divider()
            footerBar
        }
        // Cap size so the sheet fits smaller displays; the section ScrollView
        // absorbs overflow while header/footer stay on screen.
        .frame(minWidth: 760, idealWidth: 900, maxWidth: 980,
               minHeight: 480, idealHeight: 660, maxHeight: 680)
        .confirmationDialog(
            L("Delete “\(profile.metadata.name)”?", "删除「\(profile.metadata.name)」？"),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L("Delete Node", "删除节点"), role: .destructive) {
                Task { await deleteNode() }
            }
            Button(L("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(deleteConfirmationMessage)
        }
        .alert(
            L("Could Not Delete Node", "无法删除节点"),
            isPresented: Binding(
                get: { deletionError != nil },
                set: { if !$0 { deletionError = nil } }
            )
        ) {
            Button(L("OK", "好")) { deletionError = nil }
        } message: {
            Text(deletionError ?? "")
        }
        .onChange(of: modelFetch.availableModels) { _, models in
            mergeFetchedModelsIntoCatalog(models)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isNew ? L("New Node", "新建节点") : L("Edit Node", "编辑节点"))
                        .font(.title2.weight(.bold))
                    Text(L("Manage this node’s connection, access, and available models", "管理此节点的连接、访问与可用模型"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            routePreview
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(EditorTab.allCases, id: \.self) { tab in
                Button {
                    if selectedTab == .json && tab != .json {
                        syncFromJSON()
                    }
                    if tab == .json && selectedTab != .json {
                        syncToJSON()
                    }
                    // 平滑过渡窗口宽度（JSON 双栏 1100 ↔ 表单 750），避免切换时骤变。
                    withAnimation(.easeInOut(duration: 0.28)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                        Text(tab.label)
                    }
                    .font(.subheadline.weight(selectedTab == tab ? .semibold : .regular))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            if !isNew {
                Button(role: .destructive) {
                    if let deletionBlockReason {
                        deletionError = deletionBlockReason
                    } else {
                        showDeleteConfirmation = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isDeleting {
                            ProgressView().controlSize(.small)
                        }
                        Text(L("Delete", "删除"))
                    }
                }
                .disabled(isDeleting)
                .help(deletionBlockReason ?? L("Delete this node", "删除此节点"))
            }
            Spacer()
            Button(L("Cancel", "取消")) { dismiss() }
            Button(isNew ? L("Create", "创建") : L("Save", "保存")) {
                saveProfile()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isValid || (selectedTab == .json && finalJSONError != nil))
        }
        .padding(16)
    }

    // MARK: - Tab 1: Proxy Settings

    private var proxyTab: some View {
        HStack(spacing: 0) {
            sectionRail
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let providerName = linkedProviderName {
                        InheritanceBanner(providerName: providerName) {
                            let providerId = profile.metadata.linkedProviderId
                            dismiss()
                            if let providerId {
                                Task { await APIProviderDistributor.shared.resetToInherit(providerId: providerId, target: .claude) }
                            }
                        }
                    }
                    sectionHeader(selectedSection)
                    sectionContent
                }
                .padding(18)
                .frame(maxWidth: 790, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var sectionRail: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(NodeEditorSection.allCases) { section in
                let selected = selectedSection == section
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: section.symbol).frame(width: 18)
                        Text(section.title)
                        Spacer(minLength: 0)
                    }
                    .font(.callout.weight(selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.teal : Color.secondary)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.teal.opacity(0.10) : .clear))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Label(L("Fixed endpoint", "固定端点"), systemImage: "pin.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
        }
        .padding(10)
        .frame(width: 148)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.55))
    }

    @ViewBuilder private var sectionContent: some View {
        switch selectedSection {
        case .identity:
            nodeTypeSection
            basicSection
        case .connection:
            networkSection
            upstreamCredentialsSection
            accessProtectionSection
        case .models:
            modelMappingSection
        case .pricing:
            pricingRulesSection
        }
    }

    private func sectionHeader(_ section: NodeEditorSection) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(section.title, systemImage: section.symbol)
                .font(.title3.weight(.bold))
            Spacer()
            Button {
                helpSection = section
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .popover(isPresented: Binding(
                get: { helpSection == section },
                set: { if !$0 { helpSection = nil } }
            ), arrowEdge: .top) {
                Text(section.help)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(width: 330, alignment: .leading)
            }
        }
    }

    private var routePreview: some View {
        HStack(spacing: 0) {
            routeChip("rectangle.3.group", L("Product gateways", "应用网关"), tint: .indigo)
            routePreviewLine
            routeChip("network", "\(profile.metadata.proxy.host):\(profile.metadata.proxy.port)", tint: .teal)
            routePreviewLine
            routeChip("cloud", upstreamPreviewLabel, tint: .orange)
        }
    }

    private func routeChip(_ symbol: String, _ text: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(0.10)))
    }

    private var routePreviewLine: some View {
        Rectangle().fill(Color.secondary.opacity(0.24)).frame(height: 1).frame(maxWidth: .infinity)
    }

    private var upstreamPreviewLabel: String {
        let raw = profile.metadata.nodeType == .anthropicDirect
            ? profile.metadata.proxy.anthropicBaseURL : profile.metadata.proxy.normalizedUpstreamBaseURL
        return URL(string: raw)?.host ?? L("Upstream", "上游")
    }

    // MARK: - Tab 2: Visual Settings

    private var settingsVisualTab: some View {
        SettingsVisualEditorView(settings: $profile.settings)
    }

    // MARK: - Node Type Section

    private var nodeTypeSection: some View {
        EditorCard(L("Interface Type", "接口类型")) {
            CapsuleInterfacePicker(
                options: [
                    SelectableCardOption(
                        ClaudeInterfaceChoice.anthropic,
                        title: "Anthropic",
                        subtitle: L("Connect to Anthropic or a compatible API.",
                                    "连接 Anthropic 或兼容 API。"),
                        systemImage: "bolt.horizontal.fill",
                        tint: ProxyBrand.anthropic
                    ),
                    SelectableCardOption(
                        ClaudeInterfaceChoice.openAIChatCompletions,
                        title: L("OpenAI Chat", "OpenAI Chat"),
                        subtitle: L("Convert to OpenAI /chat/completions via a local proxy.",
                                    "经本地代理转成 OpenAI /chat/completions。"),
                        systemImage: "arrow.triangle.swap",
                        tint: ProxyBrand.openAI
                    ),
                    SelectableCardOption(
                        ClaudeInterfaceChoice.openAIResponses,
                        title: L("OpenAI Responses", "OpenAI Responses"),
                        subtitle: L("Convert to OpenAI /responses via a local proxy.",
                                    "经本地代理转成 OpenAI /responses。"),
                        systemImage: "arrow.up.forward.app.fill",
                        tint: ProxyBrand.codex
                    )
                ],
                selection: interfaceChoice,
                fillWidth: false
            )
        }
    }

    /// 接口类型三卡片 ↔ (nodeType, openAIUpstreamAPI) 的双向映射。
    private var interfaceChoice: Binding<ClaudeInterfaceChoice> {
        Binding(
            get: {
                switch profile.metadata.nodeType {
                case .anthropicDirect: return .anthropic
                case .openaiProxy:
                    return profile.metadata.proxy.openAIUpstreamAPI == .responses
                        ? .openAIResponses : .openAIChatCompletions
                case .codexProxy:
                    return .openAIChatCompletions
                }
            },
            set: { choice in
                let oldType = profile.metadata.nodeType
                switch choice {
                case .anthropic:
                    profile.metadata.nodeType = .anthropicDirect
                case .openAIChatCompletions:
                    profile.metadata.nodeType = .openaiProxy
                    profile.metadata.proxy.openAIUpstreamAPI = .chatCompletions
                case .openAIResponses:
                    profile.metadata.nodeType = .openaiProxy
                    profile.metadata.proxy.openAIUpstreamAPI = .responses
                }
                // 新建时仅在接口族切换（Anthropic ↔ OpenAI）时重置默认模型/映射；
                // Chat ↔ Responses 同属 openaiProxy，不重置用户已填的模型。
                if isNew, oldType != profile.metadata.nodeType {
                    switch profile.metadata.nodeType {
                    case .anthropicDirect:
                        profile.metadata.proxy.modelMapping = .anthropicDefault
                        profile.metadata.proxy.defaultModel = "claude-sonnet-4-6"
                    case .openaiProxy:
                        profile.metadata.proxy.modelMapping = .openAIDefault
                        profile.metadata.proxy.defaultModel = "gpt-5.5"
                    case .codexProxy:
                        break
                    }
                }
                profile.syncEnvFromProxy()
            }
        )
    }

    // MARK: - Basic Section

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Basic Information", "基本信息"))
                .font(.headline.weight(.bold))

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Name", "名称"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField(
                    profile.metadata.nodeType == .anthropicDirect
                        ? L("e.g., Anthropic Official", "例如：Anthropic 官方")
                        : L("e.g., OpenAI / DeepSeek", "例如：OpenAI / DeepSeek"),
                    text: $profile.metadata.name
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 340)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppSurface.card(colorScheme)))
    }

    // MARK: - Anthropic Direct Section

    private var anthropicDirectSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Upstream · Anthropic Messages", "上游 · Anthropic Messages"))
                .font(.headline.weight(.bold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Base URL")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("https://api.anthropic.com", text: $profile.metadata.proxy.anthropicBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 430)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("API Key")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                SecureKeyField("sk-ant-...", text: $profile.metadata.proxy.anthropicAPIKey)
                    .frame(width: 430)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppSurface.card(colorScheme)))
    }

    // MARK: - Network Section (OpenAI Proxy)

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Node Endpoint", "节点地址"))
                .font(.headline.weight(.bold))

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Listen Address", "监听地址")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("127.0.0.1", text: $profile.metadata.proxy.host)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Port", "端口")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("8080", value: $profile.metadata.proxy.port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 100)
                }
                Spacer(minLength: 10)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Network", "访问范围"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Toggle(
                        L("LAN access", "局域网访问"),
                        isOn: $profile.metadata.proxy.allowLAN
                    )
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.teal)
                }
            }
            .onChange(of: profile.metadata.proxy.allowLAN) { _, enabled in
                if enabled, usesDefaultClientKey {
                    generateClientKey()
                }
            }

            if profile.metadata.proxy.allowLAN {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(L(
                        "Devices on your local network can reach this port, but must still provide the node access key.",
                        "同一局域网内的设备可以连接此端口，但仍必须提供节点访问密钥。"
                    ))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            }

        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppSurface.card(colorScheme)))
    }

    @ViewBuilder private var upstreamCredentialsSection: some View {
        switch profile.metadata.nodeType {
        case .anthropicDirect:
            anthropicDirectSection
        case .openaiProxy, .codexProxy:
            upstreamSection
        }
    }

    // MARK: - Upstream Section (OpenAI Proxy)

    private var upstreamSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Upstream Provider", "上游服务"))
                .font(.headline.weight(.bold))

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Base URL", "基础 URL")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("https://api.openai.com", text: $profile.metadata.proxy.upstreamBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 430)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("API Key").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                SecureKeyField("sk-...", text: $profile.metadata.proxy.upstreamAPIKey)
                    .frame(width: 430)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppSurface.card(colorScheme)))
    }

    // MARK: - Model Configuration Section

    private var modelMappingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            modelDiscoveryPanel
            applicationModelDefaults
            maximumOutputSection
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppSurface.card(colorScheme)))
    }

    private var modelDiscoveryPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.teal)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.teal.opacity(0.10)))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(L("Available Models", "可用模型"))
                            .font(.subheadline.weight(.semibold))
                        Text("\(currentModelCatalog.count)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.teal)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.teal.opacity(0.10)))
                    }
                    Text(L(
                        "Sync exact names from \(upstreamPreviewLabel). Pricing is optional.",
                        "从 \(upstreamPreviewLabel) 同步真实名称；无需设置价格即可使用。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 10)
                Button {
                    Task { await fetchModelsFromUpstream() }
                } label: {
                    HStack(spacing: 5) {
                        if modelFetch.isFetching {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(L("Sync", "同步"))
                    }
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .disabled(!canFetchModels)
            }

            if let error = modelFetch.errorMessage {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !modelFetch.availableModels.isEmpty {
                Label(
                    L(
                        "Synced \(modelFetch.availableModels.count) models from upstream",
                        "已从上游同步 \(modelFetch.availableModels.count) 个模型"
                    ),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption2)
                .foregroundStyle(.green)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.teal.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.teal.opacity(0.14), lineWidth: 1))
    }

    private var applicationModelDefaults: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("App Default Mapping", "应用默认映射"))
                    .font(.subheadline.weight(.semibold))
                Text(L(
                    "Initial choices for Code and Desktop. App-level overrides do not change this node.",
                    "作为 Code 与 Desktop 的初始选择；应用内覆盖不会修改此节点。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            modelSlotRow(
                label: L("Default", "默认"),
                symbol: "sparkles",
                tint: .indigo,
                binding: $profile.metadata.proxy.defaultModel,
                placeholder: profile.metadata.nodeType == .openaiProxy ? "gpt-5.5" : "claude-sonnet-4-6"
            )
            modelSlotRow(
                label: "Opus",
                symbol: "diamond.fill",
                tint: .purple,
                binding: $profile.metadata.proxy.modelMapping.bigModel.name,
                placeholder: profile.metadata.nodeType == .openaiProxy ? "gpt-5.5" : "claude-opus-4-6"
            )
            modelSlotRow(
                label: "Sonnet",
                symbol: "waveform.path",
                tint: .orange,
                binding: $profile.metadata.proxy.modelMapping.middleModel.name,
                placeholder: profile.metadata.nodeType == .openaiProxy ? "gpt-5.4-mini" : "claude-sonnet-4-6"
            )
            modelSlotRow(
                label: "Haiku",
                symbol: "bolt.fill",
                tint: .teal,
                binding: $profile.metadata.proxy.modelMapping.smallModel.name,
                placeholder: profile.metadata.nodeType == .openaiProxy ? "gpt-4o-mini" : "claude-haiku-4-5"
            )
        }
    }

    private func modelSlotRow(
        label: String,
        symbol: String,
        tint: Color,
        binding: Binding<String>,
        placeholder: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(tint.opacity(0.11)))
            Text(label)
                .font(.caption.weight(.semibold))
                .frame(width: 50, alignment: .leading)
            modelTextField(text: binding, placeholder: placeholder)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 42)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.11), lineWidth: 1))
    }

    private func modelTextField(text: Binding<String>, placeholder: String) -> some View {
        ModelSuggestionField(
            text: text,
            placeholder: placeholder,
            state: modelFetch,
            catalogModels: currentModelCatalog
        )
        .frame(maxWidth: .infinity)
    }

    /// 当前节点持久化的真实模型目录（价格允许全部留空）。
    var currentModelCatalog: [String] {
        profile.metadata.proxy.modelCatalog.models.filter { !$0.isEmpty }
    }

    @ViewBuilder
    private var maximumOutputSection: some View {
        if profile.metadata.nodeType == .openaiProxy {
            HStack(spacing: 12) {
                Image(systemName: "text.line.last.and.arrowtriangle.forward")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Maximum Output", "最大输出 Token"))
                        .font(.caption.weight(.semibold))
                    Text(L("0 keeps the upstream limit", "0 表示沿用上游限制"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TextField(
                    "0",
                    value: $profile.metadata.proxy.maxOutputTokens,
                    format: .number.grouping(.never)
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
        }
    }

    private var canFetchModels: Bool {
        let baseURL = profile.metadata.nodeType == .anthropicDirect
            ? profile.metadata.proxy.anthropicBaseURL
            : profile.metadata.proxy.normalizedUpstreamBaseURL
        let apiKey = profile.metadata.nodeType == .anthropicDirect
            ? profile.metadata.proxy.anthropicAPIKey
            : profile.metadata.proxy.upstreamAPIKey
        return !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelFetch.isFetching
    }

    private func fetchModelsFromUpstream() async {
        if profile.metadata.nodeType == .anthropicDirect {
            await modelFetch.fetch(
                baseURL: profile.metadata.proxy.anthropicBaseURL,
                apiKey: profile.metadata.proxy.anthropicAPIKey,
                style: .anthropic
            )
        } else {
            await modelFetch.fetch(
                baseURL: profile.metadata.proxy.normalizedUpstreamBaseURL,
                apiKey: profile.metadata.proxy.upstreamAPIKey,
                style: .openAICompatible
            )
        }
    }

    // MARK: - Pricing Sub-section

    @State var pricingCurrency: ProxyConfiguration.PricingCurrency = .usd

    var pricingRulesSection: some View {
        ProxyPricingRulesEditor(
            catalog: $profile.metadata.proxy.modelCatalog,
            currency: $pricingCurrency,
            upstreamBaseURL: profile.metadata.nodeType == .anthropicDirect
                ? profile.metadata.proxy.anthropicBaseURL
                : profile.metadata.proxy.normalizedUpstreamBaseURL
        )
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppSurface.card(colorScheme))
        )
    }

    // MARK: - Access Protection

    private var accessProtectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Access Protection", "访问保护"))
                    .font(.headline.weight(.bold))
                Spacer()
                if copiedClientKey {
                    Label(L("Copied", "已复制"), systemImage: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Node Access Key", "节点访问密钥"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    SecureKeyField(
                        L("Empty uses the local default key", "留空则使用本机默认密钥"),
                        text: $profile.metadata.proxy.expectedClientKey
                    )
                    .frame(maxWidth: .infinity)

                    Button {
                        copyClientKey()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .help(L("Copy access key", "复制访问密钥"))

                    Button {
                        generateClientKey()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .help(L("Generate a new access key", "生成新的访问密钥"))
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(profile.metadata.proxy.allowLAN ? .orange : .green)
                Text(profile.metadata.proxy.allowLAN
                    ? L(
                        "AIUsage apps and LAN clients must provide this key when connecting to the node.",
                        "AIUsage 应用与局域网客户端连接节点时都必须提供此密钥。"
                    )
                    : L(
                        "Code, Desktop and Science use this key automatically. It is never sent to the upstream provider.",
                        "Code、Desktop 与 Science 会自动使用此密钥；它不会发送给上游服务。"
                    ))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if profile.metadata.proxy.allowLAN, usesDefaultClientKey {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(L(
                        "Generate a dedicated key before exposing this node to your local network.",
                        "局域网访问不能使用默认密钥，请先生成独立访问密钥。"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(L("Generate", "生成")) { generateClientKey() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.orange.opacity(0.09)))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppSurface.card(colorScheme)))
    }

    // MARK: - Validation

    private var isValid: Bool {
        let nameValid = !profile.metadata.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let proxy = profile.metadata.proxy
        let accessValid = !proxy.allowLAN || !usesDefaultClientKey

        switch profile.metadata.nodeType {
        case .anthropicDirect:
            return nameValid && !proxy.anthropicBaseURL.isEmpty && !proxy.anthropicAPIKey.isEmpty
                && !proxy.host.isEmpty && proxy.port > 0 && proxy.port < 65536 && accessValid
        case .openaiProxy:
            return nameValid &&
                !proxy.host.isEmpty &&
                proxy.port > 0 && proxy.port < 65536 &&
                accessValid &&
                !proxy.normalizedUpstreamBaseURL.isEmpty &&
                !proxy.upstreamAPIKey.isEmpty &&
                !proxy.modelMapping.bigModel.name.isEmpty &&
                !proxy.modelMapping.middleModel.name.isEmpty &&
                !proxy.modelMapping.smallModel.name.isEmpty
        case .codexProxy:
            // Codex 单模型：仅校验 bigModel（middle/small 留空）。
            return nameValid &&
                !proxy.host.isEmpty &&
                proxy.port > 0 && proxy.port < 65536 &&
                accessValid &&
                !proxy.normalizedUpstreamBaseURL.isEmpty &&
                !proxy.upstreamAPIKey.isEmpty &&
                !proxy.modelMapping.bigModel.name.isEmpty
        }
    }

    private var usesDefaultClientKey: Bool {
        let key = profile.metadata.proxy.expectedClientKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty || key == "proxy-key"
    }

    private var deletionBlockReason: String? {
        viewModel.managedRuntimeDeletionBlockReason(for: profile.id)
    }

    private var deleteConfirmationMessage: String {
        var message = L(
            "This permanently removes the node configuration and closes its local endpoint. Archived usage remains available. This action cannot be undone.",
            "这会永久删除节点配置并关闭其本地端点；历史用量归档仍会保留。此操作无法撤销。"
        )
        if linkedProviderName != nil {
            message += L(
                " The source API provider will not be deleted.",
                " 来源 API 提供商不会被删除。"
            )
        }
        return message
    }

    private func generateClientKey() {
        let first = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let second = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        profile.metadata.proxy.expectedClientKey = first + second
        copiedClientKey = false
    }

    private func copyClientKey() {
        let key = profile.metadata.proxy.expectedClientKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = key.isEmpty ? "proxy-key" : key
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(effective, forType: .string)
        copiedClientKey = true
    }

    private func mergeFetchedModelsIntoCatalog(_ models: [String]) {
        guard !models.isEmpty else { return }
        profile.metadata.proxy.modelCatalog.mergeModels(models)
    }

    private func deleteNode() async {
        if let deletionBlockReason {
            deletionError = deletionBlockReason
            return
        }

        isDeleting = true
        viewModel.operationErrorMessage = nil
        await viewModel.deleteConfiguration(profile.id)
        isDeleting = false

        if viewModel.configurations.contains(where: { $0.id == profile.id }) {
            deletionError = viewModel.operationErrorMessage ?? L(
                "The node was not deleted. Try again after disconnecting its apps.",
                "节点未被删除。请断开正在使用它的应用后重试。"
            )
        } else {
            dismiss()
        }
    }

    /// 链接到的「API 提供商」名称（非链接节点为 nil）。
    private var linkedProviderName: String? {
        guard let id = profile.metadata.linkedProviderId,
              let master = APIProviderStore.shared.provider(id: id) else { return nil }
        return master.displayName
    }

    // MARK: - Save

    private func saveProfile() {
        if selectedTab == .json {
            guard validateAndApplyJSON() else { return }
            guard finalJSONError == nil else { return }
        } else {
            profile.syncEnvFromProxy()
        }
        profile.metadata.proxy.expectedClientKey = profile.metadata.proxy.expectedClientKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Node Runtime is now mandatory for every Claude protocol. Alias
        // mapping belongs to Code/Desktop/Science gateways, never the node.
        profile.metadata.proxy.usePassthroughProxy = true
        profile.metadata.proxy.enableModelAliasMapping = false
        // Claude Desktop now owns one stable HTTPS gateway endpoint. Per-node
        // HTTPS remains decodable for old profiles, but editing a node migrates
        // it to the simpler HTTP-only local-node contract used by Code.
        profile.metadata.proxy.enableHTTPS = false
        profile.metadata.proxy.httpsPort = nil
        // 链接节点：与主配置比对，标记本次编辑产生的本地覆盖（未链接则清空）。
        profile = APIProviderDistributor.shared.stampOverrides(profile)

        Task {
            if isNew {
                viewModel.addProfile(profile)
            } else {
                await viewModel.updateProfile(profile)
            }
            if let globalConfigDraftSettings {
                var draft = viewModel.profileStore.globalConfig
                draft.settings = globalConfigDraftSettings
                viewModel.profileStore.saveGlobalConfig(draft)
            }
            dismiss()
        }
    }
}

#Preview {
    ProxyConfigEditorView()
        .environmentObject(ProxyViewModel())
        .environmentObject(AppState.shared)
}
