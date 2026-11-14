import SwiftUI

// MARK: - Provider Presets
// 「快速接入」服务商预设：新建 API 提供商 / Claude / Codex / OpenCode 节点时一键填好地址，
// 用户只需粘贴 API Key。合作服务商同时出现在侧边栏左下角的推荐位（按天轮换）。
//
// 新增一家服务商：
//   1. 在 `ProviderPresetCatalog.all` 里加一项；
//   2. 把 logo 放进 Assets.xcassets（imageset 名与 `logoAsset` 一致）。
// logo 刻意打包进 App、不在运行时从服务商 CDN 加载：每次启动都去请求第三方图片，
// 等于把每位用户的 IP 和使用时间交给了服务商，对开源工具来说不合适。

struct ProviderPreset: Identifiable, Equatable {
    struct Phrase: Equatable {
        let en: String
        let zh: String

        @MainActor var localized: String { L(en, zh) }
    }

    let id: String
    let name: String
    /// 一句话卖点（tile 副标题 / 推荐位第二行）。
    let tagline: Phrase
    /// 悬停提示里的补充说明。
    let detail: Phrase
    /// Assets.xcassets 中的图片名。
    let logoAsset: String
    /// 品牌主色（取自 logo，用于选中态与悬停态）。
    let brandColor: Color
    let website: URL
    /// 控制台里创建 API Key 的页面路径。
    let apiKeyPath: String
    /// 注册页路径。
    let signupPath: String
    /// OpenAI 兼容入口（含 /v1）：Chat Completions 与 Responses 共用。
    let openAIBaseURL: String
    /// Anthropic Messages 入口（不含 /v1，Claude Code 的 ANTHROPIC_BASE_URL 语义）；nil = 不支持。
    let anthropicBaseURL: String?
    let supportsResponses: Bool
    /// 推广码；nil 时链接不带推广参数。
    let referralCode: String?
    /// 推广码的查询参数名（new-api 系为 `aff`）。
    let referralParameter: String
    /// 合作推荐：界面上明确标注「赞助」，并出现在侧边栏推荐位。
    let isSponsored: Bool

    // MARK: Endpoints

    func supports(_ format: APIFormat) -> Bool {
        switch format {
        case .openAIChatCompletions: return true
        case .openAIResponses: return supportsResponses
        case .anthropic: return anthropicBaseURL != nil
        }
    }

    /// API 提供商 / Claude / Codex 节点使用的 Base URL。
    func baseURL(for format: APIFormat) -> String {
        switch format {
        case .anthropic: return anthropicBaseURL ?? openAIBaseURL
        case .openAIChatCompletions, .openAIResponses: return openAIBaseURL
        }
    }

    /// OpenCode 节点的 Base URL：AI SDK 在其后直接拼 /messages，所以 Anthropic 协议也要带 /v1。
    func openCodeBaseURL(for protocolType: OpenCodeProtocol) -> String {
        switch protocolType {
        case .anthropic:
            guard let anthropicBaseURL else { return openAIBaseURL }
            return Self.normalized(anthropicBaseURL).hasSuffix("/v1")
                ? anthropicBaseURL
                : Self.trimmingTrailingSlash(anthropicBaseURL) + "/v1"
        case .openAICompatible, .openAIResponses:
            return openAIBaseURL
        }
    }

    /// 是否为本预设自动填入的某个地址（用户改过地址后预设选中态随之取消）。
    func isEndpoint(_ url: String) -> Bool {
        let value = Self.normalized(url)
        guard !value.isEmpty else { return false }
        var endpoints = [openAIBaseURL]
        if let anthropicBaseURL {
            endpoints.append(anthropicBaseURL)
            endpoints.append(openCodeBaseURL(for: .anthropic))
        }
        return endpoints.map(Self.normalized).contains(value)
    }

    /// Base URL 是否指向本服务商（同主机或子域名），用于识别已有节点。
    func owns(baseURL: String) -> Bool {
        guard let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased(),
              let ownHost = website.host?.lowercased() else { return false }
        return host == ownHost || host.hasSuffix("." + ownHost)
    }

    // MARK: Links

    /// 带推广码与来源标记的链接。utm 让服务商能区分 AIUsage 带来的流量（推荐位 / 快速接入），
    /// 推广码保证注册与充值归属到作者。
    func link(path: String = "/", campaign: String) -> URL {
        var components = URLComponents(url: website, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.path = path
        var items: [URLQueryItem] = []
        if let referralCode, !referralCode.isEmpty {
            items.append(URLQueryItem(name: referralParameter, value: referralCode))
        }
        items.append(URLQueryItem(name: "utm_source", value: "aiusage"))
        items.append(URLQueryItem(name: "utm_medium", value: "app"))
        items.append(URLQueryItem(name: "utm_campaign", value: campaign))
        components.queryItems = items
        return components.url ?? website
    }

    func apiKeyURL(campaign: String) -> URL { link(path: apiKeyPath, campaign: campaign) }
    func signupURL(campaign: String) -> URL { link(path: signupPath, campaign: campaign) }
    /// 推荐位落地页：直接到带推广码的注册页，渠道注册统计最准确。
    /// （new-api 系前端在任意页面都会读取 `aff` 写入本地存储，所以「获取 API Key」等链接也带上推广码。）
    func promoURL(campaign: String) -> URL { signupURL(campaign: campaign) }

    // MARK: Helpers

    nonisolated private static func normalized(_ url: String) -> String {
        trimmingTrailingSlash(url.trimmingCharacters(in: .whitespacesAndNewlines)).lowercased()
    }

    nonisolated private static func trimmingTrailingSlash(_ url: String) -> String {
        var value = url
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

// MARK: - Catalog

enum ProviderPresetCatalog {
    static let apiModels = ProviderPreset(
        id: "api-models",
        name: "API Models",
        tagline: .init(en: "Low-cost AI models", zh: "低价 AI 模型"),
        detail: .init(
            en: "Claude, GPT, Gemini and more through one key, at low prices. Works with Claude Code, Codex and OpenCode.",
            zh: "一个 Key 用遍 Claude、GPT、Gemini 等主流模型，价格低。支持 Claude Code、Codex 与 OpenCode。"
        ),
        logoAsset: "sponsor-api-models",
        brandColor: Color(red: 0.24, green: 0.42, blue: 0.95),
        website: URL(string: "https://api-models.com")!,
        apiKeyPath: "/keys",
        signupPath: "/sign-up",
        openAIBaseURL: "https://api-models.com/v1",
        anthropicBaseURL: "https://api-models.com",
        supportsResponses: true,
        referralCode: "p1vl",
        referralParameter: "aff",
        isSponsored: true
    )

    /// 展示顺序即数组顺序。
    static let all: [ProviderPreset] = [apiModels]

    static var sponsors: [ProviderPreset] { all.filter(\.isSponsored) }

    static func preset(id: String?) -> ProviderPreset? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// 已有节点的 Base URL 属于哪家预设服务商。
    static func preset(owning baseURL: String) -> ProviderPreset? {
        all.first { $0.owns(baseURL: baseURL) }
    }

    /// 名称是否仍是某个预设自动填入的名字（切换 / 取消预设时可以安全替换）。
    static func isPresetName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.contains { $0.name == trimmed }
    }

    /// 侧边栏推荐位：多家赞助时按自然日轮换，每家曝光均等，且同一天内稳定不跳变。
    static func featuredSponsor(on date: Date = Date(), calendar: Calendar = .current) -> ProviderPreset? {
        let pool = sponsors
        guard !pool.isEmpty else { return nil }
        let day = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
        return pool[day % pool.count]
    }
}
