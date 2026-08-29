import Foundation

/// The 1M-context variant of a published model.
///
/// `/v1/models` advertises the capability with `supports1m: true`; the client
/// then asks for the long-context variant by appending `[1m]` to the model id
/// it was given. The suffix is a client-side capability marker — Anthropic
/// gates 1M context on the `anthropic-beta` header instead and rejects the
/// bracketed id as an unknown model — so the proxy has to translate between
/// the two conventions on the way upstream.
public enum ClaudeContext1M: Sendable {
    /// Anthropic's 1M-context beta token.
    public static let beta = "context-1m-2025-08-07"

    /// The variant marker clients append to a published model id.
    public static let variantSuffix = "[1m]"

    /// True when `model` names the 1M-context variant of another model.
    public static func requestsVariant(_ model: String) -> Bool {
        baseModel(model) != model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The model id with the `[1m]` marker removed, or the trimmed input when
    /// it carries no marker. Some gateways publish literal `…[1m]` model names,
    /// so callers should try the unmodified id against their catalog first and
    /// fall back to this base only when that lookup misses.
    public static func baseModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > variantSuffix.count,
              trimmed.lowercased().hasSuffix(variantSuffix) else { return trimmed }
        return String(trimmed.dropLast(variantSuffix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `existing` with the 1M beta added, preserving any betas the client
    /// already asked for (interleaved thinking, fine-grained tool streaming)
    /// and their order. Returns `existing` unchanged when the beta is present.
    public static func mergingBeta(into existing: String?) -> String {
        let values = (existing ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !values.contains(where: { $0.caseInsensitiveCompare(beta) == .orderedSame }) else {
            return values.joined(separator: ",")
        }
        return (values + [beta]).joined(separator: ",")
    }
}
