import Foundation
import SwiftUI

// MARK: - Shared Public Pricing Import

/// 三类模型编辑器共用的公开价格匹配结果。
struct PublicModelPriceMatch: Identifiable {
    let model: String
    let provider: String
    let pricing: ProxyConfiguration.ModelPricing

    var id: String { model }
}

private struct PublicModelPricePreview {
    let matches: [PublicModelPriceMatch]
    let unmatched: [String]
}

extension ProxyConfiguration.ModelPricing {
    /// 模型价格编辑器统一使用的币种换算；来源信息不变。
    func converted(to targetCurrency: ProxyConfiguration.PricingCurrency) -> Self {
        guard currency != targetCurrency else { return self }
        let factor = targetCurrency == .cny
            ? AppSettings.cnyPerUSD
            : (1 / AppSettings.cnyPerUSD)
        return .init(
            inputPerMillion: inputPerMillion * factor,
            outputPerMillion: outputPerMillion * factor,
            cacheCreatePerMillion: cacheCreatePerMillion * factor,
            cacheReadPerMillion: cacheReadPerMillion * factor,
            currency: targetCurrency,
            source: source
        )
    }
}

/// 节点、API 提供商、OpenCode 共用的紧凑入口与确认预览。
///
/// - 精确匹配 models.dev 的模型 ID。
/// - 预览价格已经换算为当前编辑器的显示币种。
/// - 是否覆盖、如何写入由调用方决定；目前三个调用方都只填空白价格。
struct PublicModelPricingImportControl: View {
    let models: [String]
    let upstreamBaseURL: String?
    let displayCurrency: ProxyConfiguration.PricingCurrency
    var applyNote: String?
    let onApply: ([PublicModelPriceMatch]) -> Void

    @State private var isLoading = false
    @State private var preview: PublicModelPricePreview?
    @State private var isPreviewPresented = false
    @State private var errorMessage: String?

    private var normalizedModels: [String] {
        var seen = Set<String>()
        return models.compactMap { rawModel in
            let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, seen.insert(model).inserted else { return nil }
            return model
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Button {
                fetchPreview()
            } label: {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "globe.badge.chevron.backward")
                    }
                    Text(L("Match Public Prices", "匹配公开价格"))
                }
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(.teal)
            .disabled(isLoading || normalizedModels.isEmpty)
            .help(L(
                "Match exact model IDs against models.dev. Review the result before applying; existing prices are never overwritten.",
                "按精确模型 ID 匹配 models.dev。确认预览后才会应用，已有价格不会被覆盖。"
            ))

            if let errorMessage {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(errorMessage)
                    .accessibilityLabel(errorMessage)
            }
        }
        .sheet(isPresented: $isPreviewPresented) {
            previewSheet
        }
    }

    private func fetchPreview() {
        errorMessage = nil
        isLoading = true
        let requestedModels = normalizedModels
        Task {
            do {
                let result = try await ModelsDevPricingService.preview(
                    models: requestedModels,
                    upstreamBaseURL: upstreamBaseURL
                )
                let convertedMatches = result.matches.map {
                    PublicModelPriceMatch(
                        model: $0.model,
                        provider: $0.provider,
                        pricing: $0.pricing.converted(to: displayCurrency)
                    )
                }
                await MainActor.run {
                    preview = .init(matches: convertedMatches, unmatched: result.unmatched)
                    isLoading = false
                    isPreviewPresented = true
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    @ViewBuilder
    private var previewSheet: some View {
        if let preview {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.teal.opacity(0.12))
                        Image(systemName: "globe.badge.chevron.backward")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.teal)
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Public Price Matches", "公开价格匹配"))
                            .font(.title3.weight(.bold))
                        Text(L(
                            "Exact model IDs · models.dev · existing prices stay unchanged",
                            "精确匹配模型 ID · 来源 models.dev · 已有价格保持不变"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(L(
                        "\(preview.matches.count) matched",
                        "匹配 \(preview.matches.count) 个"
                    ))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.teal)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.teal.opacity(0.12)))
                }
                .padding(18)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(preview.matches) { match in
                            matchedRow(match)
                            Divider().opacity(0.38)
                        }
                        ForEach(preview.unmatched, id: \.self) { model in
                            unmatchedRow(model)
                            if model != preview.unmatched.last {
                                Divider().opacity(0.28)
                            }
                        }
                    }
                }

                Divider()

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L(
                            "Only models without a price will be filled.",
                            "只填充尚未设置价格的模型。"
                        ))
                        .font(.caption.weight(.medium))
                        if let applyNote {
                            Text(applyNote)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button(L("Cancel", "取消")) {
                        isPreviewPresented = false
                    }
                    Button(L("Apply Matches", "应用匹配")) {
                        onApply(preview.matches)
                        isPreviewPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
                    .disabled(preview.matches.isEmpty)
                }
                .padding(16)
            }
            .frame(width: 640, height: 510)
        }
    }

    private func matchedRow(_ match: PublicModelPriceMatch) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 3) {
                Text(match.model)
                    .font(.system(.callout, design: .monospaced, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(match.provider)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text(priceSummary(match.pricing))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                if match.pricing.cacheCreatePerMillion > 0 || match.pricing.cacheReadPerMillion > 0 {
                    Text(cacheSummary(match.pricing))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 17)
        .frame(minHeight: 52)
    }

    private func unmatchedRow(_ model: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "minus.circle")
                .foregroundStyle(.tertiary)
            Text(model)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(L("No exact match", "无精确匹配"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 17)
        .frame(minHeight: 44)
    }

    private func priceSummary(_ pricing: ProxyConfiguration.ModelPricing) -> String {
        "\(L("In", "输入")) \(formatted(pricing.inputPerMillion, currency: pricing.currency))  ·  \(L("Out", "输出")) \(formatted(pricing.outputPerMillion, currency: pricing.currency))"
    }

    private func cacheSummary(_ pricing: ProxyConfiguration.ModelPricing) -> String {
        "\(L("Cache W", "缓存写")) \(formatted(pricing.cacheCreatePerMillion, currency: pricing.currency))  ·  \(L("Cache R", "缓存读")) \(formatted(pricing.cacheReadPerMillion, currency: pricing.currency))"
    }

    private func formatted(
        _ value: Double,
        currency: ProxyConfiguration.PricingCurrency
    ) -> String {
        let symbol = currency == .usd ? "$" : "¥"
        return "\(symbol)\(value.formatted(.number.precision(.fractionLength(0...6))))"
    }
}

/// 价格来源的紧凑、统一展示。无价格时不把全零误标为“手动”。
struct PricingSourceIndicator: View {
    let pricing: ProxyConfiguration.ModelPricing
    var width: CGFloat = 70

    var body: some View {
        HStack(spacing: 3) {
            if !pricing.hasAnyRate {
                Text("—")
                    .foregroundStyle(.tertiary)
            } else if pricing.source?.kind == .modelsDev {
                Image(systemName: "globe")
                Text(L("Public", "公开"))
                    .foregroundStyle(.teal)
            } else {
                Image(systemName: "pencil")
                Text(L("Manual", "手动"))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 9.5, weight: .medium))
        .lineLimit(1)
        .frame(width: width, alignment: .leading)
        .clipped()
        .help(pricing.source?.label ?? "")
    }
}
