import Foundation
import SwiftUI

// MARK: - Node Pricing Rules

/// 价格输入框的文本格式：固定小数点、不分组。跟随系统区域格式时 1250 会显示成 "1,250"，
/// 而输入框按 Double(text) 解析，读回来就成了 0。
enum PriceTextFormat {
    static let style = FloatingPointFormatStyle<Double>.number
        .precision(.fractionLength(0...6))
        .grouping(.never)
        .locale(Locale(identifier: "en_US_POSIX"))
}

/// Claude / Codex 节点共用的高密度费用表。
/// 模型目录决定“可用什么”，这里只保存明确配置过的单价；清除价格不会删除模型。
struct ProxyPricingRulesEditor: View {
    @Binding var catalog: ProxyConfiguration.ModelCatalog
    @Binding var currency: ProxyConfiguration.PricingCurrency
    var upstreamBaseURL: String?

    private struct RuleDraft: Identifiable, Equatable {
        let id: String
        var input: String
        var output: String
        var cacheWrite: String
        var cacheRead: String
        var isFree: Bool
        var source: ProxyConfiguration.ModelPricing.Source?

        init(
            model: String,
            pricing: ProxyConfiguration.ModelPricing?,
            displayCurrency: ProxyConfiguration.PricingCurrency
        ) {
            id = model
            let converted = pricing.map { $0.converted(to: displayCurrency) }
            let explicitlyFree = converted.map { !$0.hasAnyRate } ?? false
            input = explicitlyFree ? "" : Self.format(converted?.inputPerMillion)
            output = explicitlyFree ? "" : Self.format(converted?.outputPerMillion)
            cacheWrite = explicitlyFree ? "" : Self.format(converted?.cacheCreatePerMillion)
            cacheRead = explicitlyFree ? "" : Self.format(converted?.cacheReadPerMillion)
            isFree = explicitlyFree
            source = converted?.source
        }

        var hasEnteredRate: Bool {
            [input, output, cacheWrite, cacheRead].contains {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }

        func pricing(currency: ProxyConfiguration.PricingCurrency) -> ProxyConfiguration.ModelPricing? {
            if isFree {
                // 保留来源：models.dev 上标价为 0 的模型仍按公开价格跟随更新；手动标记免费时来源为手动。
                return ProxyConfiguration.ModelPricing(currency: currency, source: source)
            }
            guard hasEnteredRate else { return nil }
            return ProxyConfiguration.ModelPricing(
                inputPerMillion: Self.value(input),
                outputPerMillion: Self.value(output),
                cacheCreatePerMillion: Self.value(cacheWrite),
                cacheReadPerMillion: Self.value(cacheRead),
                currency: currency,
                source: source ?? .manual
            )
        }

        mutating func clear() {
            input = ""
            output = ""
            cacheWrite = ""
            cacheRead = ""
            isFree = false
            source = nil
        }

        private static func value(_ text: String) -> Double {
            max(0, Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        }

        fileprivate static func format(_ value: Double?) -> String {
            guard let value, value != 0 else { return "" }
            return value.formatted(PriceTextFormat.style)
        }

    }

    private enum PriceFilter: String, CaseIterable, Identifiable {
        case all
        case unpriced
        case priced

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return L("All", "全部")
            case .unpriced: return L("Unpriced", "未定价")
            case .priced: return L("Priced", "已定价")
            }
        }
    }

    @State private var drafts: [RuleDraft]
    @State private var searchText = ""
    @State private var filter: PriceFilter = .all
    @State private var isApplyingInternalChange = false
    @State private var lastCurrency: ProxyConfiguration.PricingCurrency

    init(
        catalog: Binding<ProxyConfiguration.ModelCatalog>,
        currency: Binding<ProxyConfiguration.PricingCurrency>,
        upstreamBaseURL: String? = nil
    ) {
        _catalog = catalog
        _currency = currency
        self.upstreamBaseURL = upstreamBaseURL
        let orderedNames = Self.orderedModelNames(in: catalog.wrappedValue)
        _drafts = State(initialValue: orderedNames.map {
            RuleDraft(
                model: $0,
                pricing: catalog.wrappedValue.pricingOverrides[$0],
                displayCurrency: currency.wrappedValue
            )
        })
        _lastCurrency = State(initialValue: currency.wrappedValue)
    }

    /// 列宽必须能在 Claude 编辑器最小内容区里放下（窗口 760 − 侧栏 148 − 内边距）。
    /// 模型列吃剩余宽度并中间截断；价格/来源固定，禁止把「来源」顶出卡片。
    private enum Metrics {
        static let rowSpacing: CGFloat = 6
        static let rowPadding: CGFloat = 10
        static let priceWidth: CGFloat = 70
        static let sourceWidth: CGFloat = 64
        static let menuWidth: CGFloat = 22
        static var priceClusterWidth: CGFloat { priceWidth * 4 + rowSpacing * 3 }
    }

    var body: some View {
        // 过滤结果每次渲染只算一次。旧写法在每一行里重新过滤全部模型（O(n²)），
        // 几百个模型时每敲一个键都要做数万次字符串比较，是编辑页卡顿的主因。
        let visibleIDs = filteredDraftIDs
        let visibleSet = Set(visibleIDs)
        let lastVisibleID = visibleIDs.last

        VStack(alignment: .leading, spacing: 12) {
            toolbar

            VStack(spacing: 0) {
                columnHeader
                if visibleIDs.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach($drafts) { $draft in
                            if visibleSet.contains(draft.id) {
                                pricingRow($draft)
                                if draft.id != lastVisibleID {
                                    Divider().opacity(0.45)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(L(
                "Per million tokens. A blank price means “not estimated”; zero is reserved for models explicitly marked free.",
                "单价均按每百万 Token 计算。留空表示“不估算金额”；只有明确标记为免费时才按 0 计费。"
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: drafts) { _, _ in
            persistDrafts()
        }
        .onChange(of: currency) { _, newCurrency in
            convertRules(to: newCurrency)
        }
        .onChange(of: catalog.models) { _, _ in
            syncDraftsWithCatalog()
        }
        // 「获取模型和价格」与后台同步会从外部改写费用规则，草稿需跟上，
        // 否则下一次按键保存会把刚填好的价格覆盖回去。
        .onChange(of: catalog.pricingOverrides) { _, _ in
            syncDraftsWithCatalog()
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(
                        "\(activeRuleCount) of \(catalog.models.count) models priced",
                        "\(catalog.models.count) 个模型 · 已定价 \(activeRuleCount) 个"
                    ))
                    .font(.subheadline.weight(.semibold))
                    Text(L(
                        "Prices affect amount estimates only",
                        "价格只影响金额估算"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                Spacer()

                CapsuleSegmentedPicker(
                    options: [
                        CapsuleSegmentOption(ProxyConfiguration.PricingCurrency.usd, title: "USD ($)"),
                        CapsuleSegmentOption(ProxyConfiguration.PricingCurrency.cny, title: "CNY (¥)")
                    ],
                    selection: $currency
                )
                .frame(width: 170)

                PublicModelPricingImportControl(
                    models: drafts.map(\.id),
                    upstreamBaseURL: upstreamBaseURL,
                    displayCurrency: currency,
                    onApply: applyPublicPrices
                )
            }

            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                    TextField(L("Search models", "搜索模型"), text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .frame(minWidth: 140, idealWidth: 260, maxWidth: 260, minHeight: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

                Picker("", selection: $filter) {
                    ForEach(PriceFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(minWidth: 168, maxWidth: 220)

                Spacer()
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: Metrics.rowSpacing) {
            Text(L("Model", "模型"))
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            priceHeader(L("Input", "输入"))
            priceHeader(L("Output", "输出"))
            priceHeader(L("Cache W", "缓存写"))
            priceHeader(L("Cache R", "缓存读"))
            Text(L("Source", "来源"))
                .frame(width: Metrics.sourceWidth, alignment: .leading)
            Color.clear.frame(width: Metrics.menuWidth)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Metrics.rowPadding)
        .padding(.vertical, 8)
    }

    private func priceHeader(_ title: String) -> some View {
        Text(title)
            .lineLimit(1)
            .frame(width: Metrics.priceWidth, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: drafts.isEmpty ? "cube.transparent" : "magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.teal)
            Text(drafts.isEmpty
                 ? L("Sync models first", "请先同步模型")
                 : L("No matching models", "没有符合条件的模型"))
                .font(.subheadline.weight(.semibold))
            Text(drafts.isEmpty
                 ? L("Model availability and pricing are managed separately.", "模型可用性与费用彼此独立。")
                 : L("Try another keyword or filter.", "请更换关键词或筛选条件。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private func pricingRow(_ draft: Binding<RuleDraft>) -> some View {
        HStack(spacing: Metrics.rowSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.wrappedValue.id)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if draft.wrappedValue.isFree {
                    Text(L("Explicitly free", "明确免费"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                } else if !draft.wrappedValue.hasEnteredRate {
                    Text(L("No estimate", "未估算"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if draft.wrappedValue.isFree {
                HStack {
                    Text("0")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.green)
                    Spacer(minLength: 0)
                }
                .frame(width: Metrics.priceClusterWidth)
            } else {
                compactPriceField(draft.input, draft: draft)
                compactPriceField(draft.output, draft: draft)
                compactPriceField(draft.cacheWrite, draft: draft)
                compactPriceField(draft.cacheRead, draft: draft)
            }

            sourceLabel(draft.wrappedValue)

            Menu {
                Button {
                    draft.wrappedValue.isFree.toggle()
                    draft.wrappedValue.input = ""
                    draft.wrappedValue.output = ""
                    draft.wrappedValue.cacheWrite = ""
                    draft.wrappedValue.cacheRead = ""
                    draft.wrappedValue.source = .manual
                } label: {
                    Label(
                        draft.wrappedValue.isFree ? L("Cancel Free", "取消免费") : L("Mark as Free", "标记为免费"),
                        systemImage: draft.wrappedValue.isFree ? "arrow.uturn.backward" : "gift"
                    )
                }
                if draft.wrappedValue.isFree || draft.wrappedValue.hasEnteredRate {
                    Divider()
                    Button(role: .destructive) {
                        draft.wrappedValue.clear()
                    } label: {
                        Label(L("Clear Price", "清除价格"), systemImage: "eraser")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: Metrics.menuWidth, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Price actions", "价格操作"))
        }
        .padding(.horizontal, Metrics.rowPadding)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func compactPriceField(
        _ text: Binding<String>,
        draft: Binding<RuleDraft>
    ) -> some View {
        HStack(spacing: 4) {
            Text(currency == .usd ? "$" : "¥")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField("—", text: numericTextBinding(text, draft: draft))
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 6)
        .frame(width: Metrics.priceWidth, height: 28)
        .clipped()
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.66))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.primary.opacity(0.075), lineWidth: 1)
        )
        .layoutPriority(0)
    }

    private func sourceLabel(_ draft: RuleDraft) -> some View {
        HStack(spacing: 3) {
            if draft.isFree {
                Text(L("Manual", "手动"))
                    .foregroundStyle(.green)
            } else if let source = draft.source {
                Image(systemName: source.kind == .modelsDev ? "globe" : "pencil")
                Text(source.kind == .modelsDev ? L("Public", "公开") : L("Manual", "手动"))
                    .foregroundStyle(source.kind == .modelsDev ? Color.teal : Color.secondary)
            } else if draft.hasEnteredRate {
                Image(systemName: "pencil")
                Text(L("Manual", "手动"))
                    .foregroundStyle(.secondary)
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 9.5, weight: .medium))
        .lineLimit(1)
        .frame(width: Metrics.sourceWidth, alignment: .leading)
        .clipped()
        .help(draft.source?.label ?? "")
    }

    private func numericTextBinding(
        _ source: Binding<String>,
        draft: Binding<RuleDraft>
    ) -> Binding<String> {
        Binding(
            get: { source.wrappedValue },
            set: { rawValue in
                let normalized = rawValue.replacingOccurrences(of: ",", with: ".")
                let allowed = normalized.filter { $0.isNumber || $0 == "." }
                guard allowed.filter({ $0 == "." }).count <= 1 else { return }
                source.wrappedValue = allowed
                draft.wrappedValue.source = .manual
            }
        )
    }

    private var filteredDraftIDs: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return drafts.filter { draft in
            let matchesSearch = query.isEmpty || draft.id.localizedCaseInsensitiveContains(query)
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .unpriced: matchesFilter = !draft.isFree && !draft.hasEnteredRate
            case .priced: matchesFilter = draft.isFree || draft.hasEnteredRate
            }
            return matchesSearch && matchesFilter
        }
        .map(\.id)
    }

    private var activeRuleCount: Int {
        drafts.filter { $0.isFree || $0.hasEnteredRate }.count
    }

    private static func orderedModelNames(in catalog: ProxyConfiguration.ModelCatalog) -> [String] {
        var seen = Set<String>()
        return (catalog.models + catalog.pricingOverrides.keys.sorted()).filter {
            seen.insert($0).inserted
        }
    }

    private func syncDraftsWithCatalog() {
        let existing = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0) })
        let updated = Self.orderedModelNames(in: catalog).map { model -> RuleDraft in
            let stored = catalog.pricingOverrides[model]
            // 草稿与目录价格一致时保留草稿（保住输入中的文本，如 "1."）；不一致说明是外部改写。
            if let draft = existing[model], Self.draft(draft, matches: stored, currency: currency) {
                return draft
            }
            return RuleDraft(model: model, pricing: stored, displayCurrency: currency)
        }
        guard updated != drafts else { return }
        drafts = updated
    }

    private static func draft(
        _ draft: RuleDraft,
        matches stored: ProxyConfiguration.ModelPricing?,
        currency: ProxyConfiguration.PricingCurrency
    ) -> Bool {
        switch (draft.pricing(currency: currency), stored) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.hasAnyRate == rhs.hasAnyRate && PublicPriceUpdate.sameRates(lhs, rhs)
        default:
            return false
        }
    }

    private func persistDrafts() {
        guard !isApplyingInternalChange else { return }
        var pricing: [String: ProxyConfiguration.ModelPricing] = [:]
        for draft in drafts {
            if let rule = draft.pricing(currency: currency) {
                pricing[draft.id] = rule
            }
        }
        catalog = .init(
            models: catalog.models,
            pricingOverrides: pricing,
            supports1MModels: catalog.supports1MModels
        )
    }

    private func convertRules(to newCurrency: ProxyConfiguration.PricingCurrency) {
        guard lastCurrency != newCurrency else { return }
        let factor = newCurrency == .cny ? AppSettings.cnyPerUSD : (1 / AppSettings.cnyPerUSD)
        isApplyingInternalChange = true
        drafts = drafts.map { draft in
            guard !draft.isFree else { return draft }
            var converted = draft
            converted.input = convertedValue(draft.input, factor: factor)
            converted.output = convertedValue(draft.output, factor: factor)
            converted.cacheWrite = convertedValue(draft.cacheWrite, factor: factor)
            converted.cacheRead = convertedValue(draft.cacheRead, factor: factor)
            return converted
        }
        lastCurrency = newCurrency
        isApplyingInternalChange = false
        persistDrafts()
    }

    private func convertedValue(_ raw: String, factor: Double) -> String {
        guard let value = Double(raw), !raw.isEmpty else { return raw }
        return (value * factor).formatted(PriceTextFormat.style)
    }

    private func applyPublicPrices(_ matches: [PublicModelPriceMatch]) {
        let matchesByModel = Dictionary(uniqueKeysWithValues: matches.map { ($0.model, $0) })
        isApplyingInternalChange = true
        drafts = drafts.map { draft in
            guard !draft.isFree, !draft.hasEnteredRate, let match = matchesByModel[draft.id] else {
                return draft
            }
            return RuleDraft(model: draft.id, pricing: match.pricing, displayCurrency: currency)
        }
        isApplyingInternalChange = false
        persistDrafts()
    }
}

// MARK: - Provider Model Library

/// API 提供商仍需同时管理“分发哪些模型”与提供商默认价格，所以保留批量获取/添加能力。
/// 节点编辑器不得使用此组件。
struct ProviderModelLibraryEditor: View {
    @Binding var library: [ProxyConfiguration.MappedModel]
    @Binding var currency: ProxyConfiguration.PricingCurrency
    @ObservedObject var modelFetch: ModelFetchState
    let upstreamBaseURL: String?
    var apiKey: String = ""
    var fetchStyle: ModelListEndpointStyle = .openAICompatible

    private struct Row: Identifiable {
        let id = UUID()
        var model: ProxyConfiguration.MappedModel
    }

    @State private var rows: [Row]
    @State private var expandedExtraRows: Set<UUID> = []
    @State private var fetchSummary: String?

    init(
        library: Binding<[ProxyConfiguration.MappedModel]>,
        currency: Binding<ProxyConfiguration.PricingCurrency>,
        modelFetch: ModelFetchState,
        upstreamBaseURL: String? = nil,
        apiKey: String = "",
        fetchStyle: ModelListEndpointStyle = .openAICompatible
    ) {
        _library = library
        _currency = currency
        _modelFetch = ObservedObject(wrappedValue: modelFetch)
        self.upstreamBaseURL = upstreamBaseURL
        self.apiKey = apiKey
        self.fetchStyle = fetchStyle
        _rows = State(initialValue: library.wrappedValue.map { Row(model: $0) })
    }

    private var parsedLibrary: [ProxyConfiguration.MappedModel] {
        var seen = Set<String>()
        return rows.compactMap { row in
            var model = row.model
            model.name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.name.isEmpty, seen.insert(model.name).inserted else { return nil }
            return model
        }
    }

    private var existingNames: Set<String> {
        Set(rows.map { $0.model.name.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Provider Models & Default Pricing", "提供商模型与默认定价"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                CapsuleSegmentedPicker(
                    options: [
                        CapsuleSegmentOption(ProxyConfiguration.PricingCurrency.usd, title: "USD ($)"),
                        CapsuleSegmentOption(ProxyConfiguration.PricingCurrency.cny, title: "CNY (¥)")
                    ],
                    selection: $currency
                )
            }

            HStack(spacing: 10) {
                ModelFetchControls(
                    state: modelFetch,
                    baseURL: upstreamBaseURL ?? "",
                    apiKey: apiKey,
                    style: fetchStyle,
                    requiresAPIKey: false,
                    resultSummary: fetchSummary
                )

                Spacer(minLength: 8)

                Button {
                    autoFillCache()
                } label: {
                    Label(L("Fill Blank Cache Prices", "填充空白缓存价格"), systemImage: "wand.and.stars")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .disabled(!rows.contains { $0.model.pricing.inputPerMillion > 0 })
                .help(L(
                    "For blank cache prices only, use 1.25× input for cache writes and 0.1× input for cache reads.",
                    "只填充空白缓存价格：缓存写入按输入价的 1.25 倍，缓存读取按 0.1 倍。"
                ))
            }

            FetchedModelAppendList(
                state: modelFetch,
                existingModels: existingNames,
                onAppend: { appendModels([$0]) },
                onAppendAll: { appendModels($0) },
                priceLookup: { modelFetch.publicPrice(for: $0) }
            )

            if !rows.isEmpty {
                columnHeaders
                // 懒加载：几百个模型时只构建可见行（每行 5 个格式化输入框）。
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach($rows) { $row in
                        rowView($row)
                    }
                }
            }

            Button {
                rows.append(Row(model: .init(name: "", pricing: emptyPricing)))
            } label: {
                Label(L("Add Model", "添加模型"), systemImage: "plus.circle")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
        }
        // MappedModel 本身可比较；不再每次渲染为每行拼接排序后的指纹字符串。
        .onChange(of: rows.map(\.model)) { _, _ in library = parsedLibrary }
        .onChange(of: modelFetch.completedRevision) { _, _ in applyFetchResult() }
        .onChange(of: currency) { _, newCurrency in
            for index in rows.indices {
                rows[index].model.pricing = rows[index].model.pricing.converted(to: newCurrency)
            }
            library = parsedLibrary
        }
    }

    private var emptyPricing: ProxyConfiguration.ModelPricing {
        ProxyConfiguration.ModelPricing(currency: currency)
    }

    private var columnHeaders: some View {
        HStack(spacing: 6) {
            Text(L("Model", "模型")).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Group {
                Text(L("Input", "输入"))
                Text(L("Output", "输出"))
                Text(L("Cache W", "缓存写"))
                Text(L("Cache R", "缓存读"))
            }
            .frame(width: 64, alignment: .leading)
            Text(L("Source", "来源")).frame(width: 60, alignment: .leading)
            Spacer().frame(width: 40)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.tertiary)
    }

    private func rowView(_ row: Binding<Row>) -> some View {
        let rowId = row.wrappedValue.id
        let isExpanded = expandedExtraRows.contains(rowId)
        let hasExtra = !row.wrappedValue.model.extraParameters.isEmpty
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField("gpt-5.5", text: row.model.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .layoutPriority(1)
                    .autocorrectionDisabled()
                providerPriceField(row.model.pricing.inputPerMillion, pricing: row.model.pricing)
                providerPriceField(row.model.pricing.outputPerMillion, pricing: row.model.pricing)
                providerPriceField(row.model.pricing.cacheCreatePerMillion, pricing: row.model.pricing)
                providerPriceField(row.model.pricing.cacheReadPerMillion, pricing: row.model.pricing)
                PricingSourceIndicator(pricing: row.wrappedValue.model.pricing, width: 60)
                Button {
                    if isExpanded { expandedExtraRows.remove(rowId) }
                    else { expandedExtraRows.insert(rowId) }
                } label: {
                    Image(systemName: hasExtra ? "gearshape.2.fill" : "gearshape.2")
                        .font(.system(size: 12))
                        .foregroundStyle(hasExtra ? Color.accentColor : Color.secondary.opacity(isExpanded ? 0.9 : 0.5))
                }
                .buttonStyle(.plain)
                .frame(width: 20)
                .help(L("Configure extra parameters for this model", "为该模型配置追加参数"))
                Button {
                    rows.removeAll { $0.id == rowId }
                    expandedExtraRows.remove(rowId)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .frame(width: 20)
                .help(L("Remove provider model", "移除提供商模型"))
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ModelExtraParametersEditor(parameters: row.model.extraParameters)
                    Text(L(
                        "Keys support dot paths (e.g. \"limit.context\") or top-level keys (e.g. \"temperature\"). Written into this model's config, overriding node-level defaults.",
                        "键支持点路径（如 \"limit.context\"）或顶级键（如 \"temperature\"），会写入该模型配置并覆盖节点级默认值。"
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .padding(.leading, 24)
            }
        }
    }

    private func providerPriceField(
        _ value: Binding<Double>,
        pricing: Binding<ProxyConfiguration.ModelPricing>
    ) -> some View {
        TextField(
            "0",
            value: Binding(
                get: { value.wrappedValue },
                set: {
                    value.wrappedValue = max(0, $0)
                    pricing.wrappedValue.source = .manual
                }
            ),
            format: .number.precision(.fractionLength(0...6))
        )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 64)
            .clipped()
    }

    /// 追加模型行；默认立即带上公开价格（不必再单独「匹配公开价格」）。
    @discardableResult
    private func appendModels(_ names: [String], applyPrices: Bool = true) -> Int {
        var existing = existingNames
        var added = 0
        for rawName in names {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, existing.insert(name).inserted else { continue }
            rows.append(Row(model: .init(name: name, pricing: emptyPricing)))
            added += 1
        }
        if applyPrices, added > 0 { applyPublicPricesToRows() }
        return added
    }

    /// 一次「获取模型和价格」完成后：空列表且模型不多时直接全部加入，然后回填空白价格。
    private func applyFetchResult() {
        let fetched = modelFetch.availableModels
        var added = 0
        if parsedLibrary.isEmpty, !fetched.isEmpty, fetched.count <= ModelFetchSummary.autoAddLimit {
            rows.removeAll { $0.model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            added = appendModels(fetched, applyPrices: false)
        }
        let priced = applyPublicPricesToRows()
        guard modelFetch.errorMessage == nil || priced > 0 else {
            fetchSummary = nil
            return
        }
        let names = existingNames
        fetchSummary = ModelFetchSummary.text(
            added: added,
            priced: priced,
            notAdded: fetched.filter { !names.contains($0) }.count
        )
    }

    @discardableResult
    private func applyPublicPricesToRows() -> Int {
        guard modelFetch.hasPriceCatalog else { return 0 }
        var changed = 0
        for index in rows.indices {
            let name = rows[index].model.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  let updated = PublicPriceUpdate.updatedPricing(
                    forProviderModel: rows[index].model.pricing,
                    candidate: modelFetch.publicPrice(for: name),
                    targetCurrency: currency
                  ) else { continue }
            rows[index].model.pricing = updated
            changed += 1
        }
        return changed
    }

    private func autoFillCache() {
        for index in rows.indices where rows[index].model.pricing.inputPerMillion > 0 {
            let input = rows[index].model.pricing.inputPerMillion
            var changed = false
            if rows[index].model.pricing.cacheCreatePerMillion == 0 {
                rows[index].model.pricing.cacheCreatePerMillion =
                    input * ProxyConfiguration.ModelPricing.defaultCacheWriteMultiplier
                changed = true
            }
            if rows[index].model.pricing.cacheReadPerMillion == 0 {
                rows[index].model.pricing.cacheReadPerMillion =
                    input * ProxyConfiguration.ModelPricing.defaultCacheReadMultiplier
                changed = true
            }
            if changed {
                rows[index].model.pricing.source = .manual
            }
        }
    }

}

// MARK: - Provider Library Slot Picker

struct ModelLibrarySlotPicker: View {
    @Binding var selection: String
    let library: [ProxyConfiguration.MappedModel]

    var body: some View {
        if !library.isEmpty {
            Menu {
                ForEach(library, id: \.name) { model in
                    Button {
                        selection = model.name
                    } label: {
                        if model.name == selection {
                            Label(model.name, systemImage: "checkmark")
                        } else {
                            Text(model.name)
                        }
                    }
                }
            } label: {
                Image(systemName: "books.vertical")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .help(L("Pick from provider models", "从提供商模型中选择"))
        }
    }
}
