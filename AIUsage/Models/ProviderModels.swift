import SwiftUI

// MARK: - Provider Data Models

enum ProviderCatalogKind: String, CaseIterable, Hashable, Identifiable {
    case official
    case costTracking

    var id: String { rawValue }
}

struct ProviderCatalogItem: Identifiable, Hashable {
    let id: String
    let titleEn: String
    let titleZh: String
    let summaryEn: String
    let summaryZh: String
    let channel: String?
    let kind: ProviderCatalogKind
}

enum ProviderPickerMode: String, Identifiable {
    case initialSetup
    case add
    case manage

    var id: String { rawValue }
}

struct StoredProviderAccount: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let providerId: String
    var email: String
    var displayName: String?
    var note: String?
    var accountId: String?
    var providerResultId: String?
    var credentialId: String?
    let createdAt: String
    var lastSeenAt: String?
    var isHidden: Bool
    /// Permanent delete tombstone: suppresses rediscovery like hide, but never listed under Hidden Accounts.
    var isPermanentlyRemoved: Bool
    var sourceFilePath: String?
    /// Codex workspace member id (`user-…`); used with `accountId` for native dedup.
    var workspaceUserId: String?

    nonisolated init(
        id: String,
        providerId: String,
        email: String,
        displayName: String?,
        note: String?,
        accountId: String?,
        providerResultId: String? = nil,
        credentialId: String?,
        createdAt: String,
        lastSeenAt: String?,
        isHidden: Bool = false,
        isPermanentlyRemoved: Bool = false,
        sourceFilePath: String? = nil,
        workspaceUserId: String? = nil
    ) {
        self.id = id
        self.providerId = providerId
        self.email = email
        self.displayName = displayName
        self.note = note
        self.accountId = accountId
        self.providerResultId = providerResultId
        self.credentialId = credentialId
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.isHidden = isHidden
        self.isPermanentlyRemoved = isPermanentlyRemoved
        self.sourceFilePath = sourceFilePath
        self.workspaceUserId = workspaceUserId
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        providerId = try container.decode(String.self, forKey: .providerId)
        email = try container.decode(String.self, forKey: .email)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        accountId = try container.decodeIfPresent(String.self, forKey: .accountId)
        providerResultId = try container.decodeIfPresent(String.self, forKey: .providerResultId)
        credentialId = try container.decodeIfPresent(String.self, forKey: .credentialId)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        lastSeenAt = try container.decodeIfPresent(String.self, forKey: .lastSeenAt)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        isPermanentlyRemoved = try container.decodeIfPresent(Bool.self, forKey: .isPermanentlyRemoved) ?? false
        sourceFilePath = try container.decodeIfPresent(String.self, forKey: .sourceFilePath)
        workspaceUserId = try container.decodeIfPresent(String.self, forKey: .workspaceUserId)
    }

    nonisolated var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    nonisolated var normalizedAccountId: String? {
        accountId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    nonisolated var normalizedProviderResultId: String? {
        providerResultId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    nonisolated var preferredLabel: String {
        displayName?.nilIfBlank ?? email.nilIfBlank ?? accountId ?? providerId
    }
}

struct ProviderAccountEntry: Identifiable {
    let id: String
    let providerId: String
    let providerTitle: String
    let providerSubtitle: String?
    let liveProvider: ProviderData?
    let storedAccount: StoredProviderAccount?

    var accountEmail: String? {
        liveProvider?.accountLabel ?? storedAccount?.email
    }

    var accountDisplayName: String? {
        storedAccount?.displayName
    }

    var accountNote: String? {
        storedAccount?.note?.nilIfBlank
    }

    var isConnected: Bool {
        liveProvider != nil
    }

    var canDelete: Bool {
        true
    }

    var canEditNote: Bool {
        true
    }

    var accountPrimaryLabel: String {
        accountEmail?.nilIfBlank
            ?? accountDisplayName?.nilIfBlank
            ?? liveProvider?.accountId?.nilIfBlank
            ?? storedAccount?.accountId?.nilIfBlank
            ?? providerTitle
    }

    var cardTitle: String {
        accountNote?.nilIfBlank ?? providerTitle
    }

    var cardSubtitle: String {
        accountEmail?.nilIfBlank ?? providerTitle
    }

    var workspaceLabel: String? {
        liveProvider?.workspaceLabel
    }

    var footerAccountLabel: String? {
        let email = accountEmail?.nilIfBlank
            ?? storedAccount?.email.nilIfBlank
            ?? liveProvider?.accountLabel?.nilIfBlank
        let title = cardTitle
        if let email, email != title { return email }
        return nil
    }

    /// Composite label for disambiguation: "Team · user@email.com" or just the email.
    var compositeFooterLabel: String? {
        guard let email = footerAccountLabel else { return nil }
        if let ws = workspaceLabel, ws != "Personal" {
            return "\(ws) · \(email)"
        }
        return email
    }
}

struct ProviderAccountGroup: Identifiable {
    let id: String
    let providerId: String
    let title: String
    let subtitle: String
    let channel: String?
    let isScanningEnabled: Bool
    let accounts: [ProviderAccountEntry]

    var connectedCount: Int {
        accounts.filter(\.isConnected).count
    }
}

extension ProviderCatalogItem {
    func title(for language: String) -> String {
        language == "zh" ? titleZh : titleEn
    }

    func summary(for language: String) -> String {
        language == "zh" ? summaryZh : summaryEn
    }
}

extension String {
    nonisolated var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Optional where Wrapped == String {
    nonisolated var nilIfBlank: String? {
        switch self {
        case .some(let value):
            return value.nilIfBlank
        case .none:
            return nil
        }
    }
}

struct ProviderData: Identifiable, Codable, Sendable {
    let id: String
    let providerId: String
    let accountId: String?
    let name: String
    let label: String
    let description: String
    let category: String
    let channel: String?
    let status: ProviderStatus
    let statusLabel: String
    let theme: ProviderTheme
    let sourceLabel: String
    let sourceType: String
    let fetchedAt: String?
    let accountLabel: String?
    let membershipLabel: String?
    let workspaceLabel: String?
    let workspaceUserId: String?
    let headline: Headline
    let metrics: [Metric]
    let windows: [QuotaWindow]
    let remainingPercent: Double?
    let nextResetAt: String?
    let nextResetLabel: String?
    let spotlight: String?
    let models: [ModelInfo]?
    let costSummary: CostSummary?
    let sourceFilePath: String?
    /// 机器可读错误码（仅错误态非空），用于区分「未连接」与「真实抓取失败」。
    let errorCode: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        providerId = try container.decodeIfPresent(String.self, forKey: .providerId) ?? id
        accountId = try container.decodeIfPresent(String.self, forKey: .accountId)
        name = try container.decode(String.self, forKey: .name)
        label = try container.decode(String.self, forKey: .label)
        description = try container.decode(String.self, forKey: .description)
        category = try container.decode(String.self, forKey: .category)
        channel = try container.decodeIfPresent(String.self, forKey: .channel)
        status = try container.decode(ProviderStatus.self, forKey: .status)
        statusLabel = try container.decode(String.self, forKey: .statusLabel)
        theme = try container.decode(ProviderTheme.self, forKey: .theme)
        sourceLabel = try container.decode(String.self, forKey: .sourceLabel)
        sourceType = try container.decode(String.self, forKey: .sourceType)
        fetchedAt = try container.decodeIfPresent(String.self, forKey: .fetchedAt)
        accountLabel = try container.decodeIfPresent(String.self, forKey: .accountLabel)
        membershipLabel = try container.decodeIfPresent(String.self, forKey: .membershipLabel)
        workspaceLabel = try container.decodeIfPresent(String.self, forKey: .workspaceLabel)
        workspaceUserId = try container.decodeIfPresent(String.self, forKey: .workspaceUserId)
        headline = try container.decode(Headline.self, forKey: .headline)
        metrics = try container.decode([Metric].self, forKey: .metrics)
        windows = try container.decode([QuotaWindow].self, forKey: .windows)
        remainingPercent = try container.decodeIfPresent(Double.self, forKey: .remainingPercent)
        nextResetAt = try container.decodeIfPresent(String.self, forKey: .nextResetAt)
        nextResetLabel = try container.decodeIfPresent(String.self, forKey: .nextResetLabel)
        spotlight = try container.decodeIfPresent(String.self, forKey: .spotlight)
        models = try container.decodeIfPresent([ModelInfo].self, forKey: .models)
        costSummary = try container.decodeIfPresent(CostSummary.self, forKey: .costSummary)
        sourceFilePath = try container.decodeIfPresent(String.self, forKey: .sourceFilePath)
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
    }

    nonisolated init(id: String, providerId: String, accountId: String?, name: String, label: String, description: String, category: String, channel: String?, status: ProviderStatus, statusLabel: String, theme: ProviderTheme, sourceLabel: String, sourceType: String, fetchedAt: String?, accountLabel: String?, membershipLabel: String?, workspaceLabel: String? = nil, workspaceUserId: String? = nil, headline: Headline, metrics: [Metric], windows: [QuotaWindow], remainingPercent: Double?, nextResetAt: String?, nextResetLabel: String?, spotlight: String?, models: [ModelInfo]?, costSummary: CostSummary?, sourceFilePath: String? = nil, errorCode: String? = nil) {
        self.id = id
        self.providerId = providerId
        self.accountId = accountId
        self.name = name
        self.label = label
        self.description = description
        self.category = category
        self.channel = channel
        self.status = status
        self.statusLabel = statusLabel
        self.theme = theme
        self.sourceLabel = sourceLabel
        self.sourceType = sourceType
        self.fetchedAt = fetchedAt
        self.accountLabel = accountLabel
        self.membershipLabel = membershipLabel
        self.workspaceLabel = workspaceLabel
        self.workspaceUserId = workspaceUserId
        self.headline = headline
        self.metrics = metrics
        self.windows = windows
        self.remainingPercent = remainingPercent
        self.nextResetAt = nextResetAt
        self.nextResetLabel = nextResetLabel
        self.spotlight = spotlight
        self.models = models
        self.costSummary = costSummary
        self.sourceFilePath = sourceFilePath
        self.errorCode = errorCode
    }
    
    var remainingPercentValue: Double {
        remainingPercent ?? 100.0
    }

    /// 是否为「尚未连接凭证」型错误（缺 Key / 未登录），而非真实抓取失败。
    /// 这类状态应引导用户去添加凭证，而不是展示吓人的「采集失败」。
    var needsCredentialConnection: Bool {
        status == .error && Self.needsConnectionErrorCodes.contains(errorCode ?? "")
    }

    private static let needsConnectionErrorCodes: Set<String> = ["not_logged_in", "missing_token"]
    
    var statusColor: Color {
        switch status {
        case .healthy: return .green
        case .watch: return .orange
        case .critical: return .red
        case .error: return .gray
        case .idle: return .secondary
        case .tracking: return .blue
        }
    }

    /// Grouping key for providers. Normalized summaries already use the base provider ID,
    /// while account-level uniqueness lives in `id` / `accountId`.
    nonisolated var baseProviderId: String {
        providerId
    }

    var isMultiAccount: Bool {
        accountId != nil
    }
}

enum ProviderStatus: String, Codable, Sendable {
    case healthy
    case watch
    case critical
    case error
    case idle
    case tracking
}

struct ProviderTheme: Codable, Sendable {
    let accent: String
    let glow: String
}

struct Headline: Codable, Sendable {
    let eyebrow: String
    let primary: String
    let secondary: String
    let supporting: String?
}

struct Metric: Identifiable, Codable, Sendable {
    let label: String
    let value: String
    let note: String?
    
    var id: String { label }
}

struct QuotaWindow: Identifiable, Codable, Sendable {
    let label: String
    let remainingPercent: Double?
    let usedPercent: Double?
    let value: String
    let note: String
    let resetAt: String?
    
    var id: String { label }
    
    var displayRemainingPercent: Double {
        remainingPercent ?? 0.0
    }
    
    var displayUsedPercent: Double {
        usedPercent ?? 0.0
    }
}

struct ModelInfo: Identifiable, Codable, Sendable {
    let label: String
    let value: String
    let note: String?
    
    var id: String { label }
}

struct CostSummary: Codable, Sendable {
    let today: CostPeriod?
    let week: CostPeriod?
    let month: CostPeriod?
    let overall: CostPeriod?
    let timeline: CostTimeline?
    let modelBreakdown: [ModelCostBreakdown]?
    let modelBreakdownToday: [ModelCostBreakdown]?
    let modelBreakdownWeek: [ModelCostBreakdown]?
    let modelBreakdownOverall: [ModelCostBreakdown]?
    let modelTimelines: [ModelTimelineSeries]?
}

struct ModelCostBreakdown: Codable, Identifiable, Sendable {
    let model: String
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreateTokens: Int
    let estimatedCostUsd: Double
    let percentage: Double

    var id: String { model }
}

struct ModelTimelineSeries: Codable, Identifiable, Sendable {
    let model: String
    let hourly: [CostTimelinePoint]
    let daily: [CostTimelinePoint]

    var id: String { model }
}

struct CostPeriod: Codable, Sendable {
    let usd: Double
    let tokens: Int?
    let rangeLabel: String?
}

struct CostTimeline: Codable, Sendable {
    let hourly: [CostTimelinePoint]
    let daily: [CostTimelinePoint]
}

struct CostTimelinePoint: Codable, Identifiable, Sendable {
    let bucket: String
    let label: String
    let usd: Double
    let tokens: Int
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheCreateTokens: Int?

    var id: String { bucket }
}

// MARK: - Dashboard Response

struct DashboardResponse: Codable, Sendable {
    let generatedAt: String
    let overview: DashboardOverview
    let providers: [ProviderWrapper]
}

struct ProviderWrapper: Codable, Sendable {
    let id: String
    let providerId: String
    let accountId: String?
    let ok: Bool
    let error: String?
    let summary: ProviderData

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        providerId = try container.decodeIfPresent(String.self, forKey: .providerId) ?? id
        accountId = try container.decodeIfPresent(String.self, forKey: .accountId)
        ok = try container.decode(Bool.self, forKey: .ok)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        summary = try container.decode(ProviderData.self, forKey: .summary)
    }
}

struct DashboardOverview: Codable, Sendable {
    let generatedAt: String
    let activeProviders: Int
    let attentionProviders: Int
    let criticalProviders: Int
    let resetSoonProviders: Int
    let localCostMonthUsd: Double
    let localWeekTokens: Int
    let stats: [OverviewStat]
    let alerts: [Alert]
}

struct OverviewStat: Identifiable, Codable, Sendable {
    let label: String
    let value: String
    let note: String
    
    var id: String { label }
}

struct Alert: Identifiable, Codable, Sendable {
    let id: String
    let tone: String
    let providerId: String
    let title: String
    let body: String

    private enum CodingKeys: String, CodingKey {
        case id
        case tone
        case providerId
        case title
        case body
    }

    init(id: String, tone: String, providerId: String, title: String, body: String) {
        self.id = id
        self.tone = tone
        self.providerId = providerId
        self.title = title
        self.body = body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tone = try container.decode(String.self, forKey: .tone)
        let providerId = try container.decode(String.self, forKey: .providerId)
        let title = try container.decode(String.self, forKey: .title)
        let body = try container.decode(String.self, forKey: .body)

        self.id = try container.decodeIfPresent(String.self, forKey: .id)
            // Legacy payloads did not include IDs. Prefer collision-free rendering over
            // cross-refresh identity stability for that compatibility path.
            ?? UUID().uuidString
        self.tone = tone
        self.providerId = providerId
        self.title = title
        self.body = body
    }

    var color: String {
        switch tone {
        case "critical": return "red"
        case "watch": return "orange"
        default: return "blue"
        }
    }
}
