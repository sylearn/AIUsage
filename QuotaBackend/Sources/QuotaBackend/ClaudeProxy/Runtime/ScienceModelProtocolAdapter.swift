import Foundation

/// The single compatibility boundary between an AIUsage node catalog and the
/// model protocol understood by Claude Science.
///
/// Raw upstream IDs stay in `upstreamModel`; only `id` is sent back by Science
/// in requests, and only `displayName` contains presentation workarounds.
public struct ScienceModelProtocolAdapter: Sendable {
    public enum RouteStyle: String, Sendable, Codable {
        case science
        case desktop
        /// Claude Code full-catalog mode deliberately publishes the exact
        /// upstream ids returned by the selected Node. Unlike Desktop and
        /// Science, Code can learn arbitrary Claude-shaped ids from the
        /// Gateway `/v1/models` endpoint.
        case code
    }

    public struct Model: Sendable, Equatable {
        public let id: String
        public let upstreamModel: String
        public let displayName: String
        public let supports1M: Bool

        public init(id: String, upstreamModel: String, displayName: String, supports1M: Bool = false) {
            self.id = id
            self.upstreamModel = upstreamModel
            self.displayName = displayName
            self.supports1M = supports1M
        }
    }

    /// Science wrote this built-in selection ID into existing session frames.
    /// Keeping it as the one default selection identity avoids mutating history
    /// or publishing a duplicate compatibility row.
    static let persistentDefaultSelectionID = "claude-opus-4-8"

    /// Some Science releases accept only Claude-shaped model IDs.
    static let generatedIDPrefix = "claude-aiusage-v1-"
    /// Desktop infers Effort / Thinking from Claude family SKUs
    /// (`claude-opus-*`, `claude-sonnet-*`, `claude-haiku-*`, `claude-fable-*`).
    /// Compact `claude-aiusage*` IDs pass the third-party blacklist but never
    /// match that capability table, so the product routes use current Desktop
    /// menu SKUs. `claude-sonnet-4-6` remains a Sonnet alias so already-open
    /// sessions keep mapping to the Sonnet tier after the sonnet-5 cutover.
    public static let defaultRouteID = "claude-fable-5"
    public static let opusRouteID = "claude-opus-5"
    public static let sonnetRouteID = "claude-sonnet-5"
    public static let haikuRouteID = "claude-haiku-4-5"

    public static let previousSonnetRouteID = "claude-sonnet-4-6"
    public static let legacyDefaultRouteID = "claude-aiusage"
    public static let legacyOpusRouteID = "claude-aiusage-opus"
    public static let legacySonnetRouteID = "claude-aiusage-sonnet"
    public static let legacyHaikuRouteID = "claude-aiusage-haiku"

    public enum ProductTier: Sendable {
        case defaultRoute
        case opus
        case sonnet
        case haiku
    }

    public static func productTier(for model: String) -> ProductTier? {
        switch model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case defaultRouteID, legacyDefaultRouteID:
            return .defaultRoute
        case opusRouteID, legacyOpusRouteID:
            return .opus
        case sonnetRouteID, previousSonnetRouteID, legacySonnetRouteID:
            return .sonnet
        case haikuRouteID, legacyHaikuRouteID:
            return .haiku
        default:
            return nil
        }
    }

    public static func isStableProductTierRoute(_ model: String) -> Bool {
        productTier(for: model) != nil
    }

    /// Prevents Science's display-only `Internal` heuristic from matching.
    /// It must never be used as an upstream model ID.
    static let presentationGuard = "\u{2060}"

    public let models: [Model]
    public let defaultModelID: String?
    public let defaultUpstreamModel: String?

    private let upstreamBySelectionID: [String: String]
    private let upstreamModels: Set<String>

    public init(
        upstreamModels: [String],
        requestedDefault: String?,
        routeStyle: RouteStyle = .science,
        supports1MUpstreamModels: Set<String> = []
    ) {
        let normalized = Self.normalize(upstreamModels)
        let requested = requestedDefault?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferred = requested.flatMap { normalized.contains($0) ? $0 : nil }
            ?? normalized.first

        var routing: [String: String] = [:]
        let builtModels = normalized.map { upstream in
            let id: String
            switch routeStyle {
            case .science:
                id = upstream == preferred
                    ? Self.persistentDefaultSelectionID
                    : Self.generatedSelectionID(for: upstream)
            case .desktop:
                id = Self.desktopSelectionID(for: upstream)
            case .code:
                id = upstream
            }
            let displayName: String
            switch routeStyle {
            case .science:
                displayName = Self.presentationName(for: upstream)
            case .desktop:
                displayName = Self.productPresentationName(for: upstream)
            case .code:
                displayName = Self.productPresentationName(for: upstream)
            }
            routing[id] = upstream
            return Model(
                id: id,
                upstreamModel: upstream,
                displayName: displayName,
                supports1M: supports1MUpstreamModels.contains(upstream)
            )
        }
        self.models = builtModels
        self.defaultModelID = preferred.flatMap { selected in
            builtModels.first(where: { $0.upstreamModel == selected })?.id
        }
        self.defaultUpstreamModel = preferred
        self.upstreamBySelectionID = routing
        self.upstreamModels = Set(normalized)
    }

    /// Resolves live picker selections, optionally accepted raw catalog IDs,
    /// and generated selections retained after a node switch, in that order.
    /// Legacy Claude family IDs are deliberately left to the caller's normal
    /// routing policy.
    public func resolveRequestModel(
        _ requestModel: String,
        acceptingRawUpstreamIDs: Bool
    ) -> String? {
        if let upstream = upstreamBySelectionID[requestModel] {
            return upstream
        }
        if acceptingRawUpstreamIDs, upstreamModels.contains(requestModel) {
            return requestModel
        }
        if requestModel.hasPrefix(Self.generatedIDPrefix)
            || requestModel.contains("-aiusage-v1-") {
            return defaultUpstreamModel
        }
        return nil
    }

    static func normalize(_ models: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(min(models.count, 1_000))

        for raw in models {
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty,
                  model.utf8.count <= 512,
                  !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  seen.insert(model).inserted else { continue }
            result.append(model)
            if result.count == 1_000 { break }
        }
        return result
    }

    static func generatedSelectionID(for upstreamModel: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in upstreamModel.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        var slug = ""
        var previousWasDash = false
        for scalar in upstreamModel.lowercased().unicodeScalars {
            let isASCIIAlphaNumeric = (48...57).contains(scalar.value)
                || (97...122).contains(scalar.value)
            if isASCIIAlphaNumeric {
                slug.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash, !slug.isEmpty {
                slug.append("-")
                previousWasDash = true
            }
            if slug.utf8.count >= 40 { break }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "model" }
        return "\(generatedIDPrefix)\(slug)-\(String(hash, radix: 16))"
    }

    /// Claude Desktop validates the complete model list and accepts only
    /// Anthropic-shaped role routes. Preserve an already valid route;
    /// otherwise create a stable role-shaped identity while keeping the real
    /// upstream model exclusively in the gateway mapping.
    public static func desktopSelectionID(for upstreamModel: String) -> String {
        let trimmed = upstreamModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if shouldPreserveDesktopModelID(trimmed) { return trimmed }

        let lower = trimmed.lowercased()
        let role: String
        if lower.contains("haiku") {
            role = "haiku"
        } else if lower.contains("opus") {
            role = "opus"
        } else {
            role = "sonnet"
        }
        // Claude Desktop 1.12603.1 rejects a route before checking its
        // Claude-shaped prefix when the route contains a known third-party
        // marker such as `codex`, `gpt`, `gemini`, `glm`, or `qwen`. Never
        // leak the upstream slug into the public identity. Decimal digits are
        // deterministic and cannot accidentally spell one of those markers.
        return "claude-\(role)-4-6-aiusage-v1-\(stableHashDecimal(trimmed))"
    }

    private static func shouldPreserveDesktopModelID(_ model: String) -> Bool {
        guard isDesktopSafeModelID(model) else { return false }
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("claude-")
            || normalized.hasPrefix("anthropic/claude-")
            || normalized.range(
                of: #"^(sonnet|opus|haiku|fable|mythos)(-[\d.]+)?$"#,
                options: .regularExpression
            ) != nil
    }

    public static func isDesktopSafeModelID(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.contains("[1m]") else { return false }
        let thirdPartyMarkers = #"ark-code|astron|command-r|deepseek|doubao|gemini|gemma|glm|gpt|grok|hermes|hy3|kimi|lfm|\bling\b|llama|longcat|mimo|minimax|mistral|mixtral|moonshot|nemotron|openai|phi-|qianfan|qwen|tc-code|\bunic\b|yi-|stepfun|step-3|seed-|bytedance|hunyuan|granite|amazon\.nova|nova-|devstral|ministral|ernie|codex|arcee|trinity|abab|phi\d|\bk2\.|\bm2\.|jamba|arctic|solar|mercury|zamba|kat-coder|\bds-|dpsk"#
        guard normalized.range(of: thirdPartyMarkers, options: .regularExpression) == nil else {
            return false
        }
        if normalized.range(
            of: #"^(sonnet|opus|haiku|fable|mythos)(-[\d.]+)?$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        return ["claude", "sonnet", "opus", "haiku", "fable", "mythos", "anthropic"]
            .contains(where: normalized.contains)
    }

    private static func productPresentationName(for model: String) -> String {
        switch productTier(for: model) {
        case .defaultRoute: return "AIUsage"
        case .opus: return "AIUsage Opus"
        case .sonnet: return "AIUsage Sonnet"
        case .haiku: return "AIUsage Haiku"
        case .none: return model
        }
    }

    private static func stableHashDecimal(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash)
    }

    static func presentationName(for upstreamModel: String) -> String {
        presentationNameNeedsGuard(upstreamModel)
            ? presentationGuard + upstreamModel
            : upstreamModel
    }

    static func presentationNameNeedsGuard(_ upstreamModel: String) -> Bool {
        if wouldBeMaskedByScience(upstreamModel) { return true }
        if let range = upstreamModel.range(
            of: #"^Claude\s+"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            return wouldBeMaskedByScience(String(upstreamModel[range.upperBound...]))
        }
        return false
    }

    private static func wouldBeMaskedByScience(_ value: String) -> Bool {
        if let first = value.unicodeScalars.first,
           !first.isASCII,
           first.properties.isEmoji {
            return true
        }

        let segments = value.split(separator: "-", omittingEmptySubsequences: false)
        guard segments.count >= 2,
              let firstByte = segments[0].utf8.first,
              (97...122).contains(firstByte) else {
            return false
        }
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.utf8.allSatisfy { byte in
                (97...122).contains(byte) || (48...57).contains(byte)
            }
        }
    }
}
