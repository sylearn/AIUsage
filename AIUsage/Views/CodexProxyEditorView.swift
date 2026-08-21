import SwiftUI
import QuotaBackend

// MARK: - Codex Proxy Editor
// Codex 节点编辑器（单模型）。把 OpenAI 兼容上游接入 Codex：激活时写 ~/.codex/config.toml
// 的 model / model_provider=aiusage-proxy + [model_providers.aiusage-proxy]，本地起 QuotaServer。
// 单模型写入 modelMapping.bigModel；可用目录与可选费用规则独立保存。

struct CodexProxyEditorView: View {
    @EnvironmentObject var viewModel: ProxyViewModel
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var profile: NodeProfile
    @State private var isNew: Bool
    @StateObject private var modelFetch = ModelFetchState()
    @State private var pricingCurrency: ProxyConfiguration.PricingCurrency
    @State private var isPricingEditorPresented = false
    @State private var extraTOMLCheck: TOMLCheckResult = .ok

    init(profile: NodeProfile? = nil) {
        if let profile {
            var p = profile
            // Codex 固定使用 Responses（其 wire_api），纠正历史误存的 chat_completions。
            p.metadata.proxy.openAIUpstreamAPI = .responses
            p.metadata.proxy.seedModelCatalogIfEmpty()
            _profile = State(initialValue: p)
            _isNew = State(initialValue: false)
            _pricingCurrency = State(
                initialValue: p.metadata.proxy.modelCatalog.pricingOverrides.values.first?.currency ?? .usd
            )
            _extraTOMLCheck = State(initialValue: TOMLLinter.validate(p.metadata.proxy.extraTOML ?? ""))
        } else {
            var newProfile = NodeProfile.defaultProfile(nodeType: .codexProxy)
            newProfile.metadata.proxy.seedModelCatalogIfEmpty()
            _profile = State(initialValue: newProfile)
            _isNew = State(initialValue: true)
            _pricingCurrency = State(initialValue: .usd)
        }
    }

    /// 兼容未迁移到 profile 的调用方。
    init(config: ProxyConfiguration) {
        var p = NodeProfile.fromLegacyConfiguration(config)
        p.metadata.proxy.openAIUpstreamAPI = .responses
        p.metadata.proxy.seedModelCatalogIfEmpty()
        _profile = State(initialValue: p)
        _isNew = State(initialValue: false)
        _pricingCurrency = State(
            initialValue: p.metadata.proxy.modelCatalog.pricingOverrides.values.first?.currency ?? .usd
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let providerName = linkedProviderName {
                        InheritanceBanner(providerName: providerName) {
                            let providerId = profile.metadata.linkedProviderId
                            dismiss()
                            if let providerId {
                                Task { await APIProviderDistributor.shared.resetToInherit(providerId: providerId, target: .codex) }
                            }
                        }
                    }
                    introBanner
                    basicSection
                    networkSection
                    upstreamSection
                    modelSection
                    securitySection
                    advancedTOMLSection
                }
                .padding(20)
            }
            .frame(maxHeight: .infinity)
            Divider()
            footerBar
        }
        // Cap height so header/footer stay reachable on smaller displays;
        // ScrollView absorbs overflow.
        .frame(minWidth: 640, idealWidth: 760, maxWidth: 800,
               minHeight: 480, idealHeight: 660, maxHeight: 680)
        .sheet(isPresented: $isPricingEditorPresented) {
            pricingRulesSheet
        }
        .onChange(of: modelFetch.availableModels) { _, models in
            profile.metadata.proxy.modelCatalog.mergeModels(models)
        }
    }

    // MARK: - Header / Footer

    private var headerBar: some View {
        HStack {
            Label {
                Text(isNew ? L("New Codex Node", "新建 Codex 节点") : L("Edit Codex Node", "编辑 Codex 节点"))
                    .font(.title2.weight(.bold))
            } icon: {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(Self.codexBrand)
            }
            Spacer()
            Button(L("Cancel", "取消")) { dismiss() }
        }
        .padding(20)
    }

    private var footerBar: some View {
        HStack {
            if !isNew {
                Button(L("Delete", "删除"), role: .destructive) {
                    Task {
                        await viewModel.deleteConfiguration(profile.id)
                        dismiss()
                    }
                }
            }
            Spacer()
            Button(L("Cancel", "取消")) { dismiss() }
            Button(isNew ? L("Create", "创建") : L("Save", "保存")) {
                saveProfile()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isValid)
        }
        .padding(20)
    }

    private var introBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(Self.codexBrand)
            Text(L(
                "When activated, AIUsage injects model_provider=aiusage-proxy into ~/.codex/config.toml and starts a local proxy. Codex then reaches your OpenAI-compatible upstream through it (Responses inbound).",
                "激活时会向 ~/.codex/config.toml 注入 model_provider=aiusage-proxy 并启动本地代理，Codex 经由它访问你的 OpenAI 兼容上游（Responses 入站）。"
            ))
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Self.codexBrand.opacity(0.08)))
    }

    // MARK: - Basic

    private var basicSection: some View {
        sectionCard(title: L("Basic Information", "基本信息")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Name", "名称")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField(L("e.g., Codex Proxy", "例如：Codex 代理"), text: $profile.metadata.name)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - Local Proxy

    private var networkSection: some View {
        sectionCard(title: L("Local Proxy", "本地代理")) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Host", "主机")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("127.0.0.1", text: $profile.metadata.proxy.host).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Port", "端口")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("4319", value: $profile.metadata.proxy.port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 100)
                }
            }

            Toggle(L("Allow LAN Access (0.0.0.0)", "允许局域网访问 (0.0.0.0)"), isOn: $profile.metadata.proxy.allowLAN)
                .font(.caption.weight(.medium))

            if profile.metadata.proxy.allowLAN {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(L("Warning: This will expose the proxy to your local network",
                           "警告：这将把代理暴露到你的局域网"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            }

            HStack(spacing: 6) {
                Image(systemName: "link").foregroundStyle(.secondary)
                Text(verbatim: "config.toml base_url = http://\(profile.metadata.proxy.host):\(profile.metadata.proxy.port)/v1")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Upstream

    private var upstreamSection: some View {
        sectionCard(title: L("Upstream Provider", "上游服务")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Base URL", "基础 URL")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("https://api.openai.com", text: $profile.metadata.proxy.upstreamBaseURL)
                    .textFieldStyle(.roundedBorder)
                Text(L(
                    "Enter only the provider root URL. AIUsage appends /v1 and the selected endpoint automatically.",
                    "这里只填写服务根地址，AIUsage 会自动补上 /v1 与具体端点。"
                ))
                .font(.caption2).foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Upstream API", "上游接口")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Responses (wire_api)").font(.callout.weight(.semibold))
                }
                Text(L(
                    "Codex always uses the Responses API. AIUsage forwards Codex requests faithfully (only model + auth are adjusted).",
                    "Codex 固定使用 Responses 接口。AIUsage 忠实转发 Codex 请求（仅调整模型与鉴权），与直连一致。"
                ))
                .font(.caption2).foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("API Key").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                SecureKeyField("sk-...", text: $profile.metadata.proxy.upstreamAPIKey)
            }

            ModelFetchControls(
                state: modelFetch,
                baseURL: profile.metadata.proxy.normalizedUpstreamBaseURL,
                apiKey: profile.metadata.proxy.upstreamAPIKey,
                style: .openAICompatible
            )
        }
    }

    // MARK: - Single Model + Pricing

    private var modelSection: some View {
        sectionCard(title: L("Model & Pricing", "模型与定价")) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Model", "模型")).font(.subheadline.weight(.semibold))
                modelTextField(text: $profile.metadata.proxy.modelMapping.bigModel.name, placeholder: "gpt-5.5")
                Text(L(
                    "Written as `model` in config.toml and used as the exact upstream model name. Switchable from the node card when the catalog has multiple models.",
                    "将写入 config.toml 的 `model`，并作为真实上游模型名；模型目录有多个模型时可在节点卡片上切换。"
                ))
                .font(.caption2).foregroundStyle(.tertiary)
            }

            Divider()
            costRulesSummary

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Max Output Tokens", "最大输出 Token")).font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    TextField("0", value: $profile.metadata.proxy.maxOutputTokens, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 120)
                    Text(L("0 = unlimited", "0 = 不限制")).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var currentModelCatalog: [String] {
        profile.metadata.proxy.modelCatalog.models.filter { !$0.isEmpty }
    }

    private var costRulesSummary: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.line.text.clipboard")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Cost Estimates", "费用估算"))
                    .font(.subheadline.weight(.semibold))
                Text(L(
                    "\(profile.metadata.proxy.modelCatalog.pricingOverrides.count) rules · optional",
                    "已设置 \(profile.metadata.proxy.modelCatalog.pricingOverrides.count) 条 · 可选"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Configure…", "设置…")) {
                isPricingEditorPresented = true
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
    }

    private var pricingRulesSheet: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Cost Estimate Rules", "费用估算规则"))
                        .font(.title3.weight(.bold))
                    Text(L(
                        "Prices are optional and never affect model availability.",
                        "价格为可选项，不会影响模型是否可用。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Done", "完成")) { isPricingEditorPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(18)
            Divider()
            ScrollView {
                ProxyPricingRulesEditor(
                    catalog: $profile.metadata.proxy.modelCatalog,
                    currency: $pricingCurrency
                )
                .padding(16)
            }
        }
        .frame(width: 760, height: 560)
    }

    // MARK: - Security

    private var securitySection: some View {
        sectionCard(title: L("Security", "安全设置")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Client API Key (Optional)", "客户端 API Key（可选）"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                SecureKeyField(L("Leave empty to use a default key", "留空则使用默认 Key"), text: $profile.metadata.proxy.expectedClientKey)
            }
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill").foregroundStyle(.green)
                Text(L("Sent to the local proxy via config.toml experimental_bearer_token. Leave empty to use \"proxy-key\".",
                       "通过 config.toml 的 experimental_bearer_token 下发给本地代理。留空则使用 \"proxy-key\"。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Advanced (raw TOML)

    /// 该节点的额外顶层 TOML 键。激活时与全局通用配置按顶层键合并（本节点键覆盖全局），
    /// 注入受管理 BASE 块。提供语法高亮 + 轻量检查；写 nil/"" 表示不附加。
    private var extraTOMLBinding: Binding<String> {
        Binding(
            get: { profile.metadata.proxy.extraTOML ?? "" },
            set: { profile.metadata.proxy.extraTOML = $0.nilIfBlank }
        )
    }

    private var advancedTOMLSection: some View {
        sectionCard(title: L("Advanced · Extra TOML", "高级 · 额外 TOML")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.fill").foregroundStyle(.indigo)
                    Text(L(
                        "Extra top-level TOML keys for this node (e.g., model_reasoning_effort = \"high\"). Merged on activation; node keys override Common Config.",
                        "本节点的额外顶层 TOML 键（如 model_reasoning_effort = \"high\"）。激活时合并，节点键覆盖通用配置。"
                    ))
                    .font(.caption2).foregroundStyle(.secondary)
                }
                TOMLSyntaxTextView(text: extraTOMLBinding) {
                    extraTOMLCheck = TOMLLinter.validate(extraTOMLBinding.wrappedValue)
                }
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1)))

                HStack(spacing: 6) {
                    switch extraTOMLCheck {
                    case .ok:
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text(L("TOML syntax OK", "TOML 语法检查通过")).foregroundStyle(.secondary)
                    case let .issue(line, message):
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(L("Line \(line): \(message)", "第 \(line) 行：\(message)")).foregroundStyle(.orange)
                    }
                    Spacer()
                }
                .font(.caption2.weight(.medium))
            }
        }
    }

    // MARK: - Reusable bits

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline.weight(.bold))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppSurface.card(colorScheme)))
    }

    private func modelTextField(text: Binding<String>, placeholder: String) -> some View {
        ModelSuggestionField(
            text: text,
            placeholder: placeholder,
            state: modelFetch,
            catalogModels: currentModelCatalog
        )
    }

    // MARK: - Validation / Save

    private var isValid: Bool {
        let proxy = profile.metadata.proxy
        return !profile.metadata.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !proxy.host.isEmpty
            && proxy.port > 0 && proxy.port < 65536
            && !proxy.normalizedUpstreamBaseURL.isEmpty
            && !proxy.upstreamAPIKey.isEmpty
            && !proxy.modelMapping.bigModel.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 链接到的「API 提供商」名称（非链接节点为 nil）。
    private var linkedProviderName: String? {
        guard let id = profile.metadata.linkedProviderId,
              let master = APIProviderStore.shared.provider(id: id) else { return nil }
        return master.displayName
    }

    private func saveProfile() {
        // 单模型：defaultModel 与 bigModel 对齐；middle/small 留空不参与定价/统计。
        let model = profile.metadata.proxy.modelMapping.bigModel.name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.metadata.proxy.modelMapping.bigModel.name = model
        profile.metadata.proxy.modelMapping.middleModel.name = ""
        profile.metadata.proxy.modelMapping.smallModel.name = ""
        profile.metadata.proxy.defaultModel = model
        profile.metadata.proxy.modelCatalog.mergeModels([model])
        profile.metadata.proxy.expectedClientKey = profile.metadata.proxy.expectedClientKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
        profile.syncEnvFromProxy()
        // 链接节点：与主配置比对，标记本次编辑产生的本地覆盖（未链接则清空）。
        profile = APIProviderDistributor.shared.stampOverrides(profile)

        Task {
            if isNew {
                viewModel.addProfile(profile)
            } else {
                await viewModel.updateProfile(profile)
            }
            dismiss()
        }
    }

    private static let codexBrand = Color(red: 0.40, green: 0.52, blue: 0.92)
}

#Preview {
    CodexProxyEditorView()
        .environmentObject(ProxyViewModel())
        .environmentObject(AppState.shared)
}
