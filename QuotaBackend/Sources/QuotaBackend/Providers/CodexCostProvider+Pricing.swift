import Foundation

extension CodexCostProvider {
    /// Known model names are only used for date-suffix normalization. Backend
    /// Codex JSONL rows are token-only; priced proxy usage comes from the app
    /// archive with already-frozen costs.
    static let knownModels: Set<String> = [
        "gpt-5",
        "gpt-5-codex",
        "gpt-5-mini",
        "gpt-5-nano",
        "gpt-5-pro",
        "gpt-5.1",
        "gpt-5.1-codex",
        "gpt-5.1-codex-max",
        "gpt-5.1-codex-mini",
        "gpt-5.2",
        "gpt-5.2-codex",
        "gpt-5.2-pro",
        "gpt-5.3-codex",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.4-nano",
        "gpt-5.4-pro",
        "gpt-5.5",
        "gpt-5.5-pro",
        "codex-mini-latest"
    ]

    func scanCacheSignature(routingSignature: String = "") -> String {
        "\(Self.scanCacheSchemaVersion):\(Self.knownModels.sorted().joined(separator: ",")):\(routingSignature)"
    }

    func normalizeModel(_ raw: String) -> String {
        Self.normalizeModelStatic(raw)
    }

    static func normalizeModelStatic(_ raw: String) -> String {
        var model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.hasPrefix("openai/") {
            model = String(model.dropFirst("openai/".count))
        }
        if knownModels.contains(model) { return model }
        if let range = model.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            let base = String(model[..<range.lowerBound])
            if knownModels.contains(base) { return base }
        }
        if let range = model.range(of: #"-\d{8}$"#, options: .regularExpression) {
            let base = String(model[..<range.lowerBound])
            if knownModels.contains(base) { return base }
        }
        return model
    }

    // MARK: - Source Tagging

    /// 按来源给模型名打标签，区分代理 / 非代理。
    ///   - 旧 model_provider == "aiusage-proxy": 走代理归档计费，JSONL 行丢弃避免双计。
    ///   - 其它 Codex JSONL: 归入非代理轨，只统计 token，不估价，也不依赖 rate_limits。
    func sourceTaggedModel(_ baseModel: String, provider: String?) -> String? {
        if provider == CodexProvider.legacyProxyProviderId {
            return nil
        }
        return "\(baseModel)\(Self.nonProxySourceSuffix)"
    }

    // MARK: - Date and misc helpers
}
