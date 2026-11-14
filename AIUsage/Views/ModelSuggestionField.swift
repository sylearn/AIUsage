import Combine
import SwiftUI

// MARK: - Shared Model Fetch & Suggestion Components
// 三个代理编辑器（Claude / Codex / OpenCode）共用的「获取模型 + 输入补全」组件，
// 取代原先 ProxyConfigEditorView 与 CodexProxyEditorView 里的两份重复实现。
// 数据来源: 上游 GET /v1/models（OpenAI 兼容）或 GET <base>/models（Anthropic 风格）。

/// 拉取到的模型列表、公开价格与请求状态（每个编辑器持有一个实例）。
/// 一次「获取模型和价格」并行读取上游 /v1/models 与 models.dev 目录：
/// 编辑器拿到结果后自行决定加入哪些模型，并用 `publicPrice(for:)` 回填空白价格，
/// 不再需要「获取模型 → 匹配公开价格 → 预览 → 应用」四步。
@MainActor
final class ModelFetchState: ObservableObject {
    @Published private(set) var availableModels: [String] = []
    @Published private(set) var isFetching = false
    @Published private(set) var errorMessage: String?
    /// 公开价格目录不可用时的说明（模型列表仍可正常使用）。
    @Published private(set) var pricingErrorMessage: String?
    /// 每次获取结束（无论成败）+1。编辑器监听它在一次获取后统一合并模型、回填价格。
    @Published private(set) var completedRevision = 0

    private var priceCatalog: ModelsDevPricingService.Catalog?
    private var priceBaseURL: String?
    private var priceCache: [String: ProxyConfiguration.ModelPricing?] = [:]

    var hasPriceCatalog: Bool { priceCatalog != nil }

    func fetch(baseURL: String, apiKey: String, style: ModelListEndpointStyle) async {
        guard UpstreamModelListClient.modelsURL(baseURL: baseURL) != nil else { return }
        guard !isFetching else { return }

        isFetching = true
        errorMessage = nil
        pricingErrorMessage = nil
        defer {
            isFetching = false
            completedRevision += 1
        }

        async let modelsResult = Self.loadModels(baseURL: baseURL, apiKey: apiKey, style: style)
        async let catalogResult = Self.loadCatalog()
        let (models, catalog) = await (modelsResult, catalogResult)

        switch models {
        case .success(let names):
            availableModels = names
        case .failure(let error):
            errorMessage = error.localizedDescription
        }

        switch catalog {
        case .success(let loaded):
            priceCatalog = loaded
            priceBaseURL = baseURL
            priceCache = [:]
        case .failure:
            pricingErrorMessage = L(
                "Public prices (models.dev) are unavailable right now; models can still be added.",
                "暂时无法读取 models.dev 公开价格，模型仍可正常添加。"
            )
        }
    }

    /// 某个模型的公开价格（USD）。基于本次获取时的 Base URL 优先匹配对应提供商；
    /// 手动输入、不在上游列表里的模型同样可以命中。
    func publicPrice(for model: String) -> ProxyConfiguration.ModelPricing? {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let priceCatalog else { return nil }
        if let cached = priceCache[name] { return cached }
        let price = ModelsDevPricingService.pricingMap(
            models: [name],
            upstreamBaseURL: priceBaseURL,
            in: priceCatalog
        )[name]
        priceCache[name] = price
        return price
    }

    private static func loadModels(
        baseURL: String,
        apiKey: String,
        style: ModelListEndpointStyle
    ) async -> Result<[String], Error> {
        do {
            return .success(try await UpstreamModelListClient.fetchModelIDs(
                baseURL: baseURL,
                apiKey: apiKey,
                style: style
            ))
        } catch {
            return .failure(error)
        }
    }

    private static func loadCatalog() async -> Result<ModelsDevPricingService.Catalog, Error> {
        do {
            return .success(try await ModelsDevPricingService.catalog())
        } catch {
            return .failure(error)
        }
    }

    func filteredModels(for text: String) -> [String] {
        guard !text.isEmpty else { return availableModels }
        return availableModels.filter { $0.localizedCaseInsensitiveContains(text) }
    }
}

// MARK: - Fetch Button + Status Row

struct ModelFetchControls: View {
    @ObservedObject var state: ModelFetchState
    let baseURL: String
    let apiKey: String
    var style: ModelListEndpointStyle = .openAICompatible
    /// 上游必须配 Key 才允许拉取（本地上游如 Ollama 可置 false）。
    var requiresAPIKey = true
    /// 获取完成后由编辑器回报的结果摘要（如「新增 3 个 · 定价 5 个」）；nil 时显示默认计数。
    var resultSummary: String?

    private var disabled: Bool {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (requiresAPIKey && apiKey.isEmpty)
            || state.isFetching
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await state.fetch(baseURL: baseURL, apiKey: apiKey, style: style) }
            } label: {
                HStack(spacing: 5) {
                    if state.isFetching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(L("Fetch Models & Prices", "获取模型和价格"))
                }
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .controlSize(.small)
            .disabled(disabled)
            .help(L(
                "Reads the upstream model list and models.dev public prices in one go. Blank prices are filled automatically; manual prices are never overwritten.",
                "一次读取上游模型列表与 models.dev 公开价格。空白价格自动填入，手动价格不会被覆盖。"
            ))

            statusText
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        if state.isFetching {
            Text(L("Reading upstream…", "正在读取上游…"))
                .font(.caption2).foregroundStyle(.secondary)
        } else if let error = state.errorMessage {
            Text(error).font(.caption2).foregroundStyle(.red)
                .help(error)
        } else if let resultSummary {
            Text(resultSummary).font(.caption2).foregroundStyle(.green)
                .help(state.pricingErrorMessage ?? resultSummary)
        } else if !state.availableModels.isEmpty {
            Text(L("\(state.availableModels.count) models available", "已获取 \(state.availableModels.count) 个模型"))
                .font(.caption2).foregroundStyle(.green)
        }
    }
}

// MARK: - Text Field with Suggestions

/// 单模型输入框 + 可搜索完整目录。目录可来自已保存模型，也可来自本次上游同步；
/// 用户始终可以直接输入列表之外的真实模型名称。
struct ModelSuggestionField: View {
    @Binding var text: String
    let placeholder: String
    @ObservedObject var state: ModelFetchState
    var catalogModels: [String] = []

    @State private var isPickerPresented = false
    @State private var pickerQuery = ""
    @State private var suppressNextTextPresentation = false
    @FocusState private var isTextFieldFocused: Bool

    private var allModels: [String] {
        var seen = Set<String>()
        return (state.availableModels + catalogModels)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var filteredModels: [String] {
        let query = pickerQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allModels }
        return allModels.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        HStack(spacing: 0) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .focused($isTextFieldFocused)
                .padding(.leading, 9)
                .padding(.vertical, 6)
                .onChange(of: text) { _, newValue in
                    if suppressNextTextPresentation {
                        suppressNextTextPresentation = false
                        return
                    }
                    guard isTextFieldFocused, !allModels.isEmpty else { return }
                    pickerQuery = newValue
                    isPickerPresented = true
                }

            Divider()
                .frame(height: 18)

            Button {
                pickerQuery = ""
                isPickerPresented.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 28)
            }
            .buttonStyle(.plain)
            .help(L("Search available models", "搜索可用模型"))
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.14), lineWidth: 1))
        .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
            modelPicker
        }
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField(L("Search models", "搜索模型"), text: $pickerQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .autocorrectionDisabled()
                if !pickerQuery.isEmpty {
                    Button { pickerQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Capsule().fill(Color.primary.opacity(0.06)))

            if allModels.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("No synced models yet", "尚未同步模型"))
                        .font(.subheadline.weight(.semibold))
                    Text(L(
                        "Use “Sync” above, or type an exact model name directly.",
                        "请先点击上方“同步”，也可以直接输入真实模型名称。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else if filteredModels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("No matching models", "没有匹配的模型"))
                        .font(.subheadline.weight(.semibold))
                    Text(L(
                        "Press Return in the field to keep the name you entered.",
                        "可以保留输入框中手动填写的模型名称。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredModels, id: \.self) { model in
                            Button {
                                suppressNextTextPresentation = true
                                text = model
                                isPickerPresented = false
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: model == text ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(model == text ? Color.teal : Color.secondary.opacity(0.45))
                                    Text(model)
                                        .font(.system(size: 12, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(model == text ? Color.teal.opacity(0.08) : Color.clear)
                            )
                        }
                    }
                }
                .frame(maxHeight: 240)
            }

            HStack {
                Text(L(
                    "\(allModels.count) available · manual input is allowed",
                    "共 \(allModels.count) 个 · 支持手动输入"
                ))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(12)
        .frame(width: 390)
    }
}

// MARK: - Fetched Model Picker List (search + full-row append)

/// 已获取模型的可搜索列表：顶部搜索框 + 计数 + 全部添加；整行点击即添加，
/// 左侧状态图标（加号→对勾），hover 高亮，右侧留白避开滚动条，字号更大、行高更舒展。
/// 仅用于需要把上游结果加入持久列表的编辑器（API 提供商 / OpenCode）。
/// Claude 与 Codex 节点同步后直接合并到模型目录，不再展示重复的“已添加”列表。
struct FetchedModelAppendList: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var state: ModelFetchState
    /// 当前已在列表中的模型（用于标记「已添加」并禁止重复添加）。
    let existingModels: Set<String>
    let onAppend: (String) -> Void
    let onAppendAll: ([String]) -> Void
    /// 可选：查询某模型的公开价格（USD），在行尾展示，添加时会一并写入。
    var priceLookup: ((String) -> ProxyConfiguration.ModelPricing?)? = nil

    @State private var query = ""
    @State private var hovered: String?

    private var filtered: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return state.availableModels }
        return state.availableModels.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    private var addedCount: Int {
        state.availableModels.filter { existingModels.contains($0) }.count
    }

    private var allAdded: Bool {
        !state.availableModels.isEmpty && state.availableModels.allSatisfy { existingModels.contains($0) }
    }

    var body: some View {
        if !state.availableModels.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                header
                listBody
            }
        }
    }

    // MARK: Header (search + counts + add all)

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(L("Search models", "搜索模型"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: 240)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))

            Text(L("\(state.availableModels.count) fetched · \(addedCount) added",
                   "已获取 \(state.availableModels.count) · 已添加 \(addedCount)"))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer(minLength: 6)

            Button {
                onAppendAll(state.availableModels.filter { !existingModels.contains($0) })
            } label: {
                Label(L("Add All", "全部添加"), systemImage: "plus.square.on.square")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            .disabled(allAdded)
        }
    }

    // MARK: List

    private var listBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if filtered.isEmpty {
                    Text(L("No models match \"\(query)\"", "没有匹配「\(query)」的模型"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                } else {
                    ForEach(filtered, id: \.self) { model in
                        row(model)
                    }
                }
            }
            .padding(.vertical, 5)
            .padding(.trailing, 10)
            .padding(.leading, 5)
        }
        .frame(maxHeight: 220)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppSurface.card(colorScheme)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
    }

    private static func priceHint(_ price: ProxyConfiguration.ModelPricing) -> String {
        func amount(_ value: Double) -> String {
            "$" + value.formatted(.number.precision(.fractionLength(0...3)))
        }
        return "\(amount(price.inputPerMillionUSD)) / \(amount(price.outputPerMillionUSD))"
    }

    private func row(_ model: String) -> some View {
        let added = existingModels.contains(model)
        let isHovered = hovered == model
        return Button {
            guard !added else { return }
            onAppend(model)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(added ? Color.green : Color.accentColor)
                Text(model)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(added ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if let price = priceLookup?(model) {
                    Text(Self.priceHint(price))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(L("Public price per 1M tokens (input / output)", "每百万 token 公开价（输入 / 输出）"))
                }
                if added {
                    Text(L("Added", "已添加"))
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered && !added ? Color.accentColor.opacity(0.10) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(added)
        .onHover { hovering in
            hovered = hovering ? model : (hovered == model ? nil : hovered)
        }
    }
}

// MARK: - Fetch Summary

/// 「获取模型和价格」完成后的一句话结果。
enum ModelFetchSummary {
    /// 空列表（新节点）一键获取时，上游模型不多于此数就直接全部加入；
    /// 聚合网关动辄几百个模型，超过时仍让用户在列表里挑选。
    static let autoAddLimit = 60

    static func text(added: Int, priced: Int, notAdded: Int) -> String {
        var parts: [String] = []
        if added > 0 { parts.append(L("\(added) added", "新增 \(added) 个")) }
        if priced > 0 { parts.append(L("\(priced) priced", "定价 \(priced) 个")) }
        if notAdded > 0 { parts.append(L("\(notAdded) more below", "另有 \(notAdded) 个可在下方添加")) }
        return parts.isEmpty ? L("Up to date", "已是最新") : parts.joined(separator: " · ")
    }
}
