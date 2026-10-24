import Foundation

// MARK: - Provider Registry
// Central list of all providers. Add new providers here.

public enum ProviderRegistry {

    private static let all: [any ProviderFetcher] = [
        AntigravityCostProvider(),
        AntigravityProvider(),
        ClaudeProvider(),
        ClaudeSubscriptionProvider(),
        CodexCostProvider(),
        CodexProvider(),
        CopilotProvider(),
        CursorProvider(),
        DroidProvider(),
        GeminiProvider(),
        KimiProvider(),
        KiroProvider(),
        MiniMaxProvider(),
        OpenCodeCostProvider(),
        WarpProvider()
    ]

    private static let byId: [String: any ProviderFetcher] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    public static func allProviders() -> [any ProviderFetcher] {
        all
    }

    public static func providers(for ids: [String]) -> [any ProviderFetcher] {
        guard !ids.isEmpty else { return [] }
        let wanted = Set(ids)
        return all.filter { wanted.contains($0.id) }
    }

    public static func provider(for id: String) -> (any ProviderFetcher)? {
        byId[id]
    }
}
