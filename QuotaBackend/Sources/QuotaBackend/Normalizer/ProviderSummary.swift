import Foundation

// MARK: - Normalized Provider Summary
// This matches the JSON shape the SwiftUI frontend already expects (ProviderData in ProviderModels.swift)

/// Canonical values the normalizer writes into `ProviderSummary.category`.
/// Kept as raw strings so the on-disk JSON shape is unchanged, but referenced
/// via this enum to stop magic strings from leaking into UI filter logic.
public enum ProviderCategory {
    public static let localCost = "local-cost"
    public static let quota = "quota"
}

public struct ProviderSummary: Codable, Sendable {
    public var id: String
    public var providerId: String
    public var accountId: String?
    public let name: String
    public var label: String
    public var description: String
    public var category: String
    public var channel: String?
    public var status: String
    public var statusLabel: String
    public var theme: ThemeInfo
    public var sourceLabel: String
    public var sourceType: String
    public var fetchedAt: String?
    public var accountLabel: String?
    public var membershipLabel: String?
    public var workspaceLabel: String?
    public var workspaceUserId: String?
    public var remainingPercent: Double?
    public var nextResetAt: String?
    public var nextResetLabel: String?
    public var headline: HeadlineInfo
    public var metrics: [MetricInfo]
    public var windows: [WindowInfo]
    public var costSummary: CostSummaryInfo?
    public var models: [ModelInfo]?
    public var spotlight: String
    public var unpricedModels: [String]?
    public var raw: ProviderUsage?
    public var sourceFilePath: String?
    /// 机器可读的错误码（仅错误态填写），如 `not_logged_in` / `missing_token` / `invalid_credentials`。
    /// 供 UI 区分「未连接（引导去添加凭证）」与「真实抓取失败」。成功态恒为 nil。
    public var errorCode: String?
}

public struct ThemeInfo: Codable, Sendable {
    public let accent: String
    public let glow: String
}

public struct HeadlineInfo: Codable, Sendable {
    public let eyebrow: String
    public let primary: String
    public let secondary: String
    public let supporting: String
}

public struct MetricInfo: Codable, Sendable {
    public let label: String
    public let value: String
    public var note: String?
}

public struct WindowInfo: Codable, Sendable {
    public let label: String
    public var remainingPercent: Double?
    public var usedPercent: Double?
    public let value: String
    public let note: String
    public var resetAt: String?
}

public struct CostSummaryInfo: Codable, Sendable {
    public var today: CostPeriod?
    public var week: CostPeriod?
    public var month: CostPeriod?
    public var overall: CostPeriod?
    public var timeline: CostTimelineInfo?
    public var modelBreakdown: [ModelCostInfo]?
    public var modelBreakdownToday: [ModelCostInfo]?
    public var modelBreakdownWeek: [ModelCostInfo]?
    public var modelBreakdownOverall: [ModelCostInfo]?
    public var modelTimelines: [ModelTimelineSeries]?
}

public struct ModelCostInfo: Codable, Sendable {
    public let model: String
    public let totalTokens: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreateTokens: Int
    public let estimatedCostUsd: Double
    public let percentage: Double

    public init(model: String, totalTokens: Int, inputTokens: Int = 0, outputTokens: Int = 0,
                cacheReadTokens: Int = 0, cacheCreateTokens: Int = 0,
                estimatedCostUsd: Double, percentage: Double) {
        self.model = model; self.totalTokens = totalTokens
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens; self.cacheCreateTokens = cacheCreateTokens
        self.estimatedCostUsd = estimatedCostUsd; self.percentage = percentage
    }
}

public struct ModelTimelineSeries: Codable, Sendable {
    public let model: String
    public let hourly: [CostTimelinePoint]
    public let daily: [CostTimelinePoint]

    public init(model: String, hourly: [CostTimelinePoint], daily: [CostTimelinePoint]) {
        self.model = model; self.hourly = hourly; self.daily = daily
    }
}

public struct CostPeriod: Codable, Sendable {
    public let usd: Double
    public let tokens: Int
    public let rangeLabel: String
}

public struct CostTimelineInfo: Codable, Sendable {
    public var hourly: [CostTimelinePoint]
    public var daily: [CostTimelinePoint]
}

public struct CostTimelinePoint: Codable, Sendable {
    public let bucket: String
    public let label: String
    public let usd: Double
    public let tokens: Int
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheCreateTokens: Int?
}

public struct ModelInfo: Codable, Sendable {
    public let label: String
    public let value: String
    public var note: String?
}

// MARK: - Dashboard Response (matches existing Node.js API shape)

public struct DashboardSnapshot: Codable, Sendable {
    public let generatedAt: String
    public let overview: DashboardOverview
    public let providers: [ProviderResult]
}

public struct DashboardOverview: Codable, Sendable {
    public let generatedAt: String
    public let activeProviders: Int
    public let attentionProviders: Int
    public let criticalProviders: Int
    public let resetSoonProviders: Int
    public let localCostMonthUsd: Double
    public let localWeekTokens: Int
    public let stats: [StatInfo]
    public let alerts: [AlertInfo]
}

public struct StatInfo: Codable, Sendable {
    public let label: String
    public let value: String
    public let note: String
}

public struct AlertInfo: Codable, Sendable {
    public let id: String
    public let tone: String
    public let providerId: String
    public let title: String
    public let body: String
}
