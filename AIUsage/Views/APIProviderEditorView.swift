import SwiftUI

// MARK: - API Provider Editor
// 新建/编辑「API 提供商」主配置的 sheet：名称 / 格式 / Base URL / API Key /
// 提供商模型与默认定价 / 默认模型 / 共享高级参数 + 「分发到」勾选。
// 保存交由调用方（APIProviderListView）落库并触发分发/同步。

struct APIProviderEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (APIProvider, Set<ProxyTarget>) -> Void

    @State private var draft: APIProvider
    @State private var library: [ProxyConfiguration.MappedModel]
    @State private var currency: ProxyConfiguration.PricingCurrency
    @State private var defaultModel: String
    @State private var selectedTargets: Set<ProxyTarget>
    @State private var temperatureText: String
    @State private var topPText: String
    @State private var showAdvanced = false
    @StateObject private var modelFetch = ModelFetchState()
    private let initialProvider: APIProvider
    private let initialTargets: Set<ProxyTarget>
    private let isNew: Bool
    @State private var confirmDiscard = false

    init(
        provider: APIProvider,
        initialTargets: Set<ProxyTarget>,
        onSave: @escaping (APIProvider, Set<ProxyTarget>) -> Void
    ) {
        self.onSave = onSave
        self.initialProvider = provider
        self.initialTargets = Self.sanitizedTargets(initialTargets, for: provider)
        _draft = State(initialValue: provider)
        _library = State(initialValue: provider.models)
        _currency = State(initialValue: provider.models.first?.pricing.currency ?? .usd)
        _defaultModel = State(initialValue: provider.defaultModel)
        _selectedTargets = State(initialValue: Self.sanitizedTargets(initialTargets, for: provider))
        _temperatureText = State(initialValue: Self.decimalText(provider.temperature))
        _topPText = State(initialValue: Self.decimalText(provider.topP))
        isNew = provider.name.isEmpty && provider.baseURL.isEmpty && provider.models.isEmpty
    }

    @MainActor
    private static func sanitizedTargets(_ targets: Set<ProxyTarget>, for provider: APIProvider) -> Set<ProxyTarget> {
        var result = targets.filter { $0.supports(provider.format) }
        if APIProviderCPALoopGuard.blockReason(for: provider) != nil {
            result.remove(.cpa)
        }
        return result
    }

    private static func decimalText(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%g", value)
    }

    private func parsedOptionalDouble(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    private var fetchStyle: ModelListEndpointStyle {
        draft.format == .anthropic ? .anthropic : .openAICompatible
    }

    private var canSave: Bool {
        draft.baseURL.trimmingCharacters(in: .whitespaces).nilIfBlank != nil && !library.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    EditorCard(L("API Format", "接口格式")) { formatSection }
                    EditorCard(L("Basic Information", "基本信息")) { basicSection }
                    EditorCard { modelsSection }
                    EditorCard { advancedSection }
                    EditorCard(L("Distribute To", "分发到")) { distributionSection }
                }
                .padding(18)
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 760, height: 820)
        .onChange(of: draft.format) { _, newFormat in
            selectedTargets = selectedTargets.filter { $0.supports(newFormat) }
        }
        .confirmationDialog(
            L("Discard changes?", "放弃更改？"),
            isPresented: $confirmDiscard
        ) {
            Button(L("Discard", "放弃"), role: .destructive) { dismiss() }
            Button(L("Keep Editing", "继续编辑"), role: .cancel) {}
        } message: {
            Text(L("You have unsaved changes.", "当前有未保存的修改。"))
        }
    }

    private var isDirty: Bool {
        draft.name != initialProvider.name
            || draft.baseURL != initialProvider.baseURL
            || draft.apiKey != initialProvider.apiKey
            || draft.format != initialProvider.format
            || library != initialProvider.models
            || defaultModel != initialProvider.defaultModel
            || selectedTargets != initialTargets
            || draft.contextLimit != initialProvider.contextLimit
            || draft.outputLimit != initialProvider.outputLimit
            || draft.maxOutputTokens != initialProvider.maxOutputTokens
            || temperatureText != Self.decimalText(initialProvider.temperature)
            || topPText != Self.decimalText(initialProvider.topP)
    }

    private func requestDismiss() {
        if isDirty { confirmDiscard = true } else { dismiss() }
    }

    // MARK: - Header / Footer

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(Color.accentColor)
            Text(isNew ? L("New API Provider", "新建 API 提供商") : L("Edit API Provider", "编辑 API 提供商"))
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var footer: some View {
        HStack {
            if !canSave {
                Text(L("Base URL and at least one model are required.", "需要填写 Base URL，并至少添加一个模型。"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button(L("Cancel", "取消")) { requestDismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L("Save", "保存")) { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Sections

    private var formatSection: some View {
        CapsuleInterfacePicker(
            options: [
                SelectableCardOption(
                    APIFormat.openAIChatCompletions,
                    title: "OpenAI Chat",
                    subtitle: L("OpenAI /chat/completions (DeepSeek, Ollama, gateways…).",
                                "OpenAI /chat/completions（DeepSeek、Ollama、第三方网关…）。"),
                    systemImage: "arrow.triangle.swap",
                    tint: ProxyBrand.openAI
                ),
                SelectableCardOption(
                    APIFormat.anthropic,
                    title: "Anthropic",
                    subtitle: L("Anthropic /v1/messages (official or compatible gateways).",
                                "Anthropic /v1/messages（官方或兼容网关）。"),
                    systemImage: "bolt.horizontal.fill",
                    tint: ProxyBrand.anthropic
                ),
                SelectableCardOption(
                    APIFormat.openAIResponses,
                    title: "OpenAI Responses",
                    subtitle: L("OpenAI /v1/responses (the only format Codex accepts).",
                                "OpenAI /v1/responses（Codex 仅支持此格式）。"),
                    systemImage: "arrow.up.forward.app.fill",
                    tint: ProxyBrand.codex
                )
            ],
            selection: $draft.format
        )
    }

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel(L("Name", "名称"), required: false)
                TextField(L("e.g. DeepSeek Official", "如：DeepSeek 官方"), text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                fieldLabel(L("Base URL", "Base URL"), required: true)
                TextField("https://api.example.com/v1", text: $draft.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
            }

            VStack(alignment: .leading, spacing: 4) {
                fieldLabel(L("API Key", "API Key"), required: false)
                SecureKeyField("sk-...", text: $draft.apiKey)
            }
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModelFetchControls(
                state: modelFetch,
                baseURL: draft.baseURL,
                apiKey: draft.apiKey,
                style: fetchStyle,
                requiresAPIKey: false
            )

            ProviderModelLibraryEditor(
                library: $library,
                currency: $currency,
                modelFetch: modelFetch,
                upstreamBaseURL: draft.baseURL
            )

            VStack(alignment: .leading, spacing: 4) {
                fieldLabel(L("Default Model", "默认模型"), required: false)
                HStack(spacing: 6) {
                    TextField(L("falls back to first model", "缺省回退到首个模型"), text: $defaultModel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    ModelLibrarySlotPicker(selection: $defaultModel, library: library)
                }
            }
        }
    }

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L(
                    "These generation defaults only apply to OpenCode-distributed nodes.",
                    "以下生成参数仅对分发到 OpenCode 的节点生效。"
                ))
                .font(.caption2)
                .foregroundStyle(.tertiary)

                HStack(spacing: 12) {
                    labeledIntField(L("Context Limit", "上下文上限"), value: $draft.contextLimit)
                    labeledIntField(L("Output Limit", "输出上限"), value: $draft.outputLimit)
                    labeledIntField(L("Max Output Tokens", "最大输出 token"), value: $draft.maxOutputTokens)
                }
                HStack(spacing: 12) {
                    labeledTextField(L("Temperature", "温度"), text: $temperatureText, placeholder: "0.7")
                    labeledTextField(L("Top P", "Top P"), text: $topPText, placeholder: "1")
                    Spacer()
                }
            }
            .padding(.top, 8)
        } label: {
            Text(L("Advanced Parameters", "高级参数"))
                .font(.subheadline.weight(.semibold))
        }
    }

    private var distributionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L(
                "Selected targets get a linked node (or CPA upstream) mapped from this provider. Unchecking removes that link.",
                "勾选的目标会生成由本提供商映射的链接节点（或 CPA 上游）；取消勾选会移除该链接。"
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(ProxyTarget.allCases) { target in
                distributionRow(target)
            }
        }
    }

    private func distributionRow(_ target: ProxyTarget) -> some View {
        let supported = target.supports(draft.format)
        let loopReason = target == .cpa ? APIProviderCPALoopGuard.blockReason(for: draft) : nil
        let enabled = supported && loopReason == nil
        return HStack(alignment: .top, spacing: 8) {
            Toggle(isOn: Binding(
                get: { selectedTargets.contains(target) },
                set: { on in
                    if on {
                        guard enabled else { return }
                        selectedTargets.insert(target)
                    } else {
                        selectedTargets.remove(target)
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.displayName)
                        .font(.body)
                    if let reason = loopReason ?? target.incompatibilityReason(for: draft.format) {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!enabled)
        }
        .onChange(of: draft.baseURL) { _, _ in
            if target == .cpa, APIProviderCPALoopGuard.blockReason(for: draft) != nil {
                selectedTargets.remove(.cpa)
            }
        }
        .onChange(of: draft.format) { _, _ in
            if target == .cpa, !enabled {
                selectedTargets.remove(.cpa)
            }
        }
    }

    // MARK: - Helpers

    private func fieldLabel(_ title: String, required: Bool) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if required {
                Text("*").font(.caption.weight(.bold)).foregroundStyle(.red)
            }
        }
    }

    private func labeledIntField(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField("0", value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
        }
    }

    private func labeledTextField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
        }
    }

    // MARK: - Save

    private func save() {
        var provider = draft
        provider.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.models = library
        provider.defaultModel = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.temperature = parsedOptionalDouble(temperatureText).map { min(max($0, 0), 2) }
        provider.topP = parsedOptionalDouble(topPText).map { min(max($0, 0), 1) }
        provider.maxOutputTokens = max(0, provider.maxOutputTokens)
        provider.contextLimit = max(0, provider.contextLimit)
        provider.outputLimit = max(0, provider.outputLimit)
        onSave(provider, selectedTargets)
        dismiss()
    }
}
