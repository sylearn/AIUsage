import Foundation
import os.log
import QuotaBackend
import UserNotifications

extension ProviderRefreshCoordinator {
    // MARK: - QuotaBackend → ProviderData conversion

    // nonisolated（模块默认 MainActor 隔离）：纯结构映射，可在后台批处理里调用以避免阻塞主线程（issue #28）。
    nonisolated func convertSummary(_ s: QuotaBackend.ProviderSummary) -> ProviderData {
        func convertTimelinePoint(_ point: QuotaBackend.CostTimelinePoint) -> CostTimelinePoint {
            CostTimelinePoint(
                bucket: point.bucket,
                label: point.label,
                usd: point.usd,
                tokens: point.tokens,
                inputTokens: point.inputTokens,
                outputTokens: point.outputTokens,
                cacheReadTokens: point.cacheReadTokens,
                cacheCreateTokens: point.cacheCreateTokens
            )
        }

        return ProviderData(
            id: s.id,
            providerId: s.providerId,
            accountId: s.accountId,
            name: s.name,
            label: s.label,
            description: s.description,
            category: s.category,
            channel: s.channel,
            status: ProviderStatus(rawValue: s.status) ?? .healthy,
            statusLabel: s.statusLabel,
            theme: ProviderTheme(accent: s.theme.accent, glow: s.theme.glow),
            sourceLabel: s.sourceLabel,
            sourceType: s.sourceType,
            fetchedAt: s.fetchedAt,
            accountLabel: s.accountLabel,
            membershipLabel: s.membershipLabel,
            workspaceLabel: s.workspaceLabel,
            workspaceUserId: s.workspaceUserId,
            headline: Headline(eyebrow: s.headline.eyebrow, primary: s.headline.primary, secondary: s.headline.secondary, supporting: s.headline.supporting),
            metrics: s.metrics.map { Metric(label: $0.label, value: $0.value, note: $0.note) },
            windows: s.windows.map { QuotaWindow(label: $0.label, remainingPercent: $0.remainingPercent, usedPercent: $0.usedPercent, value: $0.value, note: $0.note, resetAt: $0.resetAt) },
            remainingPercent: s.remainingPercent,
            nextResetAt: s.nextResetAt,
            nextResetLabel: s.nextResetLabel,
            spotlight: s.spotlight,
            models: s.models?.map { ModelInfo(label: $0.label, value: $0.value, note: $0.note) },
            costSummary: s.costSummary.map { cs in
                CostSummary(
                    today: cs.today.map { CostPeriod(usd: $0.usd, tokens: $0.tokens, rangeLabel: $0.rangeLabel) },
                    week: cs.week.map { CostPeriod(usd: $0.usd, tokens: $0.tokens, rangeLabel: $0.rangeLabel) },
                    month: cs.month.map { CostPeriod(usd: $0.usd, tokens: $0.tokens, rangeLabel: $0.rangeLabel) },
                    overall: cs.overall.map { CostPeriod(usd: $0.usd, tokens: $0.tokens, rangeLabel: $0.rangeLabel) },
                    timeline: cs.timeline.map { timeline in
                        CostTimeline(
                            hourly: timeline.hourly.map(convertTimelinePoint),
                            daily: timeline.daily.map(convertTimelinePoint)
                        )
                    },
                    modelBreakdown: cs.modelBreakdown?.map {
                        ModelCostBreakdown(model: $0.model, totalTokens: $0.totalTokens, inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, cacheReadTokens: $0.cacheReadTokens, cacheCreateTokens: $0.cacheCreateTokens, estimatedCostUsd: $0.estimatedCostUsd, percentage: $0.percentage)
                    },
                    modelBreakdownToday: cs.modelBreakdownToday?.map {
                        ModelCostBreakdown(model: $0.model, totalTokens: $0.totalTokens, inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, cacheReadTokens: $0.cacheReadTokens, cacheCreateTokens: $0.cacheCreateTokens, estimatedCostUsd: $0.estimatedCostUsd, percentage: $0.percentage)
                    },
                    modelBreakdownWeek: cs.modelBreakdownWeek?.map {
                        ModelCostBreakdown(model: $0.model, totalTokens: $0.totalTokens, inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, cacheReadTokens: $0.cacheReadTokens, cacheCreateTokens: $0.cacheCreateTokens, estimatedCostUsd: $0.estimatedCostUsd, percentage: $0.percentage)
                    },
                    modelBreakdownOverall: cs.modelBreakdownOverall?.map {
                        ModelCostBreakdown(model: $0.model, totalTokens: $0.totalTokens, inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, cacheReadTokens: $0.cacheReadTokens, cacheCreateTokens: $0.cacheCreateTokens, estimatedCostUsd: $0.estimatedCostUsd, percentage: $0.percentage)
                    },
                    modelTimelines: cs.modelTimelines?.map {
                        ModelTimelineSeries(
                            model: $0.model,
                            hourly: $0.hourly.map(convertTimelinePoint),
                            daily: $0.daily.map(convertTimelinePoint)
                        )
                    }
                )
            },
            sourceFilePath: s.sourceFilePath,
            errorCode: s.errorCode
        )
    }

    nonisolated func convertOverview(_ o: QuotaBackend.DashboardOverview) -> DashboardOverview {
        DashboardOverview(
            generatedAt: o.generatedAt,
            activeProviders: o.activeProviders,
            attentionProviders: o.attentionProviders,
            criticalProviders: o.criticalProviders,
            resetSoonProviders: o.resetSoonProviders,
            localCostMonthUsd: o.localCostMonthUsd,
            localWeekTokens: o.localWeekTokens,
            stats: o.stats.map { OverviewStat(label: $0.label, value: $0.value, note: $0.note) },
            alerts: o.alerts.map {
                Alert(id: $0.id, tone: $0.tone, providerId: $0.providerId, title: $0.title, body: $0.body)
            }
        )
    }

    @MainActor var language: String { settings.language }

    // nonisolated + 显式 language：本地化是正则密集型纯变换，挪出主线程批处理（issue #28）。
    // 模块默认 MainActor 隔离，故 nonisolated 上下文不能读 settings.language，语言一律由调用方在主线程取值后传入。
    nonisolated func localizeProviderData(_ provider: ProviderData, language: String) -> ProviderData {
        guard language == "zh" else { return provider }

        return ProviderData(
            id: provider.id,
            providerId: provider.providerId,
            accountId: provider.accountId,
            name: provider.name,
            label: provider.label,
            description: localizedDynamicText(provider.description, language),
            category: provider.category,
            channel: provider.channel,
            status: provider.status,
            statusLabel: provider.statusLabel,
            theme: provider.theme,
            sourceLabel: localizedDynamicText(provider.sourceLabel, language),
            sourceType: provider.sourceType,
            fetchedAt: provider.fetchedAt,
            accountLabel: provider.accountLabel,
            membershipLabel: provider.membershipLabel,
            workspaceLabel: provider.workspaceLabel,
            workspaceUserId: provider.workspaceUserId,
            headline: Headline(
                eyebrow: localizedDynamicText(provider.headline.eyebrow, language),
                primary: localizedDynamicText(provider.headline.primary, language),
                secondary: localizedDynamicText(provider.headline.secondary, language),
                supporting: provider.headline.supporting.map { localizedDynamicText($0, language) }
            ),
            metrics: provider.metrics.map {
                Metric(
                    label: localizedDynamicText($0.label, language),
                    value: localizedDynamicText($0.value, language),
                    note: $0.note.map { localizedDynamicText($0, language) }
                )
            },
            windows: provider.windows.map {
                QuotaWindow(
                    label: localizedDynamicText($0.label, language),
                    remainingPercent: $0.remainingPercent,
                    usedPercent: $0.usedPercent,
                    value: localizedDynamicText($0.value, language),
                    note: localizedDynamicText($0.note, language),
                    resetAt: $0.resetAt
                )
            },
            remainingPercent: provider.remainingPercent,
            nextResetAt: provider.nextResetAt,
            nextResetLabel: provider.nextResetLabel,
            spotlight: provider.spotlight.map { localizedDynamicText($0, language) },
            models: provider.models?.map {
                ModelInfo(
                    label: $0.label,
                    value: localizedDynamicText($0.value, language),
                    note: $0.note.map { localizedDynamicText($0, language) }
                )
            },
            costSummary: provider.costSummary.map { summary in
                CostSummary(
                    today: summary.today.map { localizedCostPeriod($0, language: language) },
                    week: summary.week.map { localizedCostPeriod($0, language: language) },
                    month: summary.month.map { localizedCostPeriod($0, language: language) },
                    overall: summary.overall.map { localizedCostPeriod($0, language: language) },
                    timeline: summary.timeline.map { timeline in
                        CostTimeline(
                            hourly: timeline.hourly.map { localizedTimelinePoint($0, language: language) },
                            daily: timeline.daily.map { localizedTimelinePoint($0, language: language) }
                        )
                    },
                    modelBreakdown: summary.modelBreakdown,
                    modelBreakdownToday: summary.modelBreakdownToday,
                    modelBreakdownWeek: summary.modelBreakdownWeek,
                    modelBreakdownOverall: summary.modelBreakdownOverall,
                    modelTimelines: summary.modelTimelines
                )
            },
            sourceFilePath: provider.sourceFilePath,
            errorCode: provider.errorCode
        )
    }

    nonisolated func localizedCostPeriod(_ period: CostPeriod, language: String) -> CostPeriod {
        CostPeriod(
            usd: period.usd,
            tokens: period.tokens,
            rangeLabel: period.rangeLabel.map { localizedDynamicText($0, language) }
        )
    }

    nonisolated func localizedTimelinePoint(_ point: CostTimelinePoint, language: String) -> CostTimelinePoint {
        CostTimelinePoint(
            bucket: point.bucket,
            label: localizedDynamicText(point.label, language),
            usd: point.usd,
            tokens: point.tokens,
            inputTokens: point.inputTokens,
            outputTokens: point.outputTokens,
            cacheReadTokens: point.cacheReadTokens,
            cacheCreateTokens: point.cacheCreateTokens
        )
    }

    nonisolated func localizeOverview(_ overview: DashboardOverview, language: String) -> DashboardOverview {
        guard language == "zh" else { return overview }

        return DashboardOverview(
            generatedAt: overview.generatedAt,
            activeProviders: overview.activeProviders,
            attentionProviders: overview.attentionProviders,
            criticalProviders: overview.criticalProviders,
            resetSoonProviders: overview.resetSoonProviders,
            localCostMonthUsd: overview.localCostMonthUsd,
            localWeekTokens: overview.localWeekTokens,
            stats: overview.stats.map {
                OverviewStat(
                    label: localizedDynamicText($0.label, language),
                    value: localizedDynamicText($0.value, language),
                    note: localizedDynamicText($0.note, language)
                )
            },
            alerts: overview.alerts.map {
                Alert(
                    id: $0.id,
                    tone: $0.tone,
                    providerId: $0.providerId,
                    title: localizedDynamicText($0.title, language),
                    body: localizedDynamicText($0.body, language)
                )
            }
        )
    }

    // MARK: - Off-main batch convert + localize (issue #28 Fix B)
    // 这些是纯函数（nonisolated 同步），把正则密集型的转换 + 本地化集中成一批；
    // 调用方在 `Task.detached { ... }.value` 里执行它们，确保整批跑在全局执行器（后台线程）。
    //
    // 为什么用 Task.detached 而不是 @concurrent：CI 用 Xcode 16.4（Swift 6.0），不识别 `@concurrent`
    // （Swift 6.2 才有）；本地用 Xcode 26（Swift 6.2，启用了 NonisolatedNonsendingByDefault，此时
    // 普通 `nonisolated async` 会留在调用方主线程）。Task.detached 在两套工具链下都编译且都真正切后台，
    // 是唯一跨版本一致的写法。入参/产物均为 Sendable，可安全跨线程回传；主线程只做赋值与 UI 协调。

    nonisolated func localizedProviderResults(
        from results: [QuotaBackend.ProviderResult],
        language: String
    ) -> [(provider: ProviderData, ok: Bool)] {
        results.compactMap { result in
            guard let summary = result.summary else { return nil }
            return (localizeProviderData(convertSummary(summary), language: language), result.ok)
        }
    }

    nonisolated func localizedDashboard(
        from snapshot: QuotaBackend.DashboardSnapshot,
        language: String
    ) -> (providers: [(provider: ProviderData, ok: Bool)], overview: DashboardOverview) {
        let providers = snapshot.providers.compactMap { result -> (provider: ProviderData, ok: Bool)? in
            guard let summary = result.summary else { return nil }
            return (localizeProviderData(convertSummary(summary), language: language), result.ok)
        }
        let overview = localizeOverview(convertOverview(snapshot.overview), language: language)
        return (providers, overview)
    }

    // 远程模式：APIService 返回的已是 ProviderData / DashboardOverview（无需 convertSummary），仅做本地化。

    nonisolated func localizedProviderList(
        _ items: [(provider: ProviderData, ok: Bool)],
        language: String
    ) -> [(provider: ProviderData, ok: Bool)] {
        items.map { (localizeProviderData($0.provider, language: language), $0.ok) }
    }

    nonisolated func localizedRemoteDashboard(
        _ items: [(provider: ProviderData, ok: Bool)],
        overview: DashboardOverview,
        language: String
    ) -> (providers: [(provider: ProviderData, ok: Bool)], overview: DashboardOverview) {
        let providers = items.map { (provider: localizeProviderData($0.provider, language: language), ok: $0.ok) }
        return (providers, localizeOverview(overview, language: language))
    }

    // 规则#9：高成本对象（130+ 项字典、正则编译）只建一次复用，不在每次本地化里重建/重编译。
    // 这是数据刷新期间主线程的头号 CPU 热点（见 issue #28 Instruments profile）。
    private static let exactTranslations: [String: String] = [
            "Connected Sources": "监控服务",
            "Attention Queue": "状态提醒",
            "Tracked Local Cost": "费用追踪",
            "Resets In 24h": "即将刷新",
            "Tracked Services": "监控服务",
            "Live Accounts": "在线账号",
            "Cost Tracking": "费用追踪",
            "Status Alerts": "状态提醒",
            "Live snapshot": "实时快照",
            "Fetched successfully": "抓取成功",
            "This provider is connected.": "该服务已连接。",
            "Collection failed": "采集失败",
            "Unavailable": "不可用",
            "Check local auth or provider session": "请检查本地登录态或服务会话",
            "Unknown source": "未知来源",
            "Environment variable": "环境变量",
            "Manual credentials": "手动凭证",
            "Browser session": "浏览器会话",
            "Desktop cache": "桌面缓存",
            "CLIProxy auth file": "CLIProxy 授权文件",
            "GitHub CLI": "GitHub CLI",
            "Local CLI session": "本地 CLI 会话",
            "Local Claude logs": "本地 Claude 日志",
            "Proxy usage ledger": "代理用量账本",
            "Proxy + subscription ledger": "代理 + 非代理账本",
            "Proxy + non-proxy ledger": "代理 + 非代理账本",
            "Gemini CLI OAuth": "Gemini CLI OAuth",
            "Kiro IDE session": "Kiro IDE 会话",
            "Stored credential": "已存凭证",
            "WebView session": "WebView 会话",
            "Pasted cookie": "粘贴的 Cookie",
            "Stored session": "已存会话",
            "Imported credential": "导入的凭证",
            "Saved": "已保存",
            "Awaiting a live session": "等待在线会话",
            "Unknown": "未知",
            "None": "无",
            "Connected": "已连接",
            "Unlimited": "无限",
            "Not available": "暂无",
            "Tracked": "已跟踪",
            "No fixed cap detected": "未检测到固定上限",
            "No cap detected": "未检测到上限",
            "main request reserve": "主额度余量",
            "quota snapshot": "配额快照",
            "Antigravity quota snapshot": "Antigravity 配额快照",
            "lowest remaining model": "剩余最低的模型",
            "Most Copilot lanes are unlimited": "Copilot 大多数通道为无限制",
            "tightest Copilot lane": "最紧张的 Copilot 通道",
            "Kiro usage snapshot": "Kiro 用量快照",
            "tightest Kiro lane": "最紧张的 Kiro 通道",
            "Usage snapshot ready": "用量快照已就绪",
            "lowest remaining window": "剩余最低的窗口",
            "Gemini quota snapshot": "Gemini 配额快照",
            "lowest remaining family": "剩余最低的模型组",
            "Cursor usage snapshot": "Cursor 用量快照",
            "tightest remaining allowance": "最紧张的额度窗口",
            "Token telemetry ready": "Token 统计已就绪",
            "lowest remaining token pool": "剩余最低的 Token 池",
            "Unlimited mode": "无限模式",
            "Desktop quota cache": "桌面配额缓存",
            "Local cost telemetry": "本地费用统计",
            "Local spend ledger": "本地费用账本",
            "Account": "账号",
            "Email": "邮箱",
            "Plan": "计划",
            "Workspace": "工作空间",
            "Reset": "重置",
            "Source": "来源",
            "Project": "项目",
            "Tracked Models": "跟踪模型",
            "Main Pool": "主额度",
            "Assistant Pool": "助手额度",
            "Bonus Credits": "奖励额度",
            "Premium": "Premium",
            "Chat": "聊天",
            "Completions": "补全",
            "Auth": "认证",
            "Region": "区域",
            "Today": "今天",
            "This Week": "本周",
            "This Month": "本月",
            "Scanned Calls": "扫描调用数",
            "Scanned Turns": "扫描轮次",
            "Requests": "请求数",
            "Assistant Credits": "助手额度",
            "Main Plan": "主计划",
            "Named Models": "具名模型",
            "Free Quota": "免费额度",
            "Used": "已用",
            "Remaining": "剩余",
            "Hourly Refill": "每小时回补",
            "Included Plan": "套餐额度",
            "On-demand": "按量",
            "Lowest Remaining": "最低剩余",
            "Billing Period": "计费周期",
            "Billing cycle detected": "已检测到账期",
            "Standard Tokens": "标准 Tokens",
            "Premium Tokens": "高级 Tokens",
            "GitHub account": "GitHub 账号",
            "OpenAI account": "OpenAI 账号",
            "Gemini CLI account": "Gemini CLI 账号",
            "Kiro account": "Kiro 账号",
            "Local Codex logs": "本地 Codex 日志",
            "Reset unavailable": "重置时间未知",
            "Reset date unknown": "重置日期未知",
            "Everything is within normal range": "目前都在正常范围内",
            "No urgent resets detected": "暂无即将重置的窗口",
            "A few windows are about to roll over": "有些窗口即将重置",
            "Warp can read from local app cache, which makes the panel feel instantaneous and keeps the design centered on what is actually left right now.": "Warp 可以直接读取本地应用缓存，所以面板刷新很快，重点也能放在当前还剩多少。",
            "This tracker reads AIUsage's Claude proxy usage archive. Token and cost totals are frozen when each proxy request is logged, so it works as a local cost ledger rather than an official subscription meter.": "这个追踪源会读取 AIUsage 的 Claude 代理用量归档。每条代理请求写入时就会冻结 Token 与费用，所以它是本地费用账本，而不是官方订阅额度计量器。",
            "This tracker combines priced Codex proxy archive usage with token-only non-proxy Codex session logs. Proxy JSONL rows are ignored here to avoid double counting.": "这个追踪源会合并已计价的 Codex 代理归档用量与仅统计 Token 的非代理 Codex 会话日志。这里会忽略代理 JSONL 行，避免重复统计。",
            "Claude proxy usage archive token and cost ledger": "Claude 代理用量归档的 Token 与费用账本",
            "Claude Gateway usage archive token and cost ledger": "Claude Gateway 用量归档的 Token 与费用账本",
            "Code, Desktop and Science usage recorded by Claude Gateway": "Claude Gateway 记录的 Code、Desktop 与 Science 用量",
            "Local token and cost ledger from Claude proxy usage": "基于 Claude 代理用量的本地 Token 与费用账本",
            "Proxy cost ledger plus non-proxy Codex token usage": "Codex 代理费用账本与非代理 Token 用量",
            "Codex": "Codex",
            "Local token ledger": "本地 Token 账本",
            "Codex proxy + non-proxy usage this month": "本月 Codex 代理 + 非代理用量",
            "Local ledgers and usage-derived spend": "本地账本与用量推导费用",
            "Copilot can mix unlimited and metered lanes. The dashboard keeps unlimited channels visible, but only metered windows affect watch and critical states.": "Copilot 同时存在无限和限额通道。面板会保留无限通道的可见性，但只有有限额的窗口会影响偏低和告急状态。",
            "Codex has multiple overlapping guardrails, so the UI surfaces all windows together and uses the tightest one to drive alerting.": "Codex 有多层重叠的限制窗口，所以界面会把它们一起展示，并用最紧张的那个来驱动提醒。",
            "Gemini quota is model-family based, so the dashboard groups the lowest remaining family first and keeps the project context attached.": "Gemini 的配额是按模型族划分的，所以面板会优先展示剩余最低的模型组，并保留项目上下文。",
            "Cursor mixes percent-based allowances with dollar-based plan spend, so the card pairs remaining percentages with included and on-demand spend signals.": "Cursor 同时存在百分比额度和按美元计的套餐消耗，所以卡片会同时展示剩余百分比、套餐内额度和按量消耗信号。",
            "Droid usage is token-heavy, so the panel keeps raw token counts visible next to the percentage-based pools.": "Droid 的用量以 token 为主，所以面板会在百分比池旁边保留原始 token 数量。",
            "Factory Individual plans share three rolling windows. A request needs headroom in the 5-hour, weekly, and monthly buckets.": "Factory Individual 共用三个滚动窗口。发请求需要 5 小时、周限和月限都还有余量。",
            "lowest remaining rate-limit window": "剩余最少的频控窗口",
            "5h Window": "5 小时",
            "Weekly Window": "7 天",
            "Monthly Window": "1 个月",
            "Extra Usage": "额外用量",
            "When Limit Hits": "额度用尽后",
            "Model": "模型",
            "5h Reset": "5 小时额度重置",
            "Weekly Reset": "周限重置",
            "tightest Kimi Code window": "最紧张的 Kimi Code 窗口",
            "Kimi Code subscription usage": "Kimi Code 订阅用量",
            "Kimi Code shares one quota across CLI, IDE, and API keys. The weekly window resets every 7 days; the rolling rate-limit window recovers within a few hours.": "Kimi Code 的 CLI、IDE 与 API Key 共用同一份额度。周限每 7 天重置；5 小时滚动频控窗口会在数小时内回补。",
            "GitHub Education access": "GitHub 教育权益",
            "Personal": "个人",
            "Team": "团队",
            "Business": "商业",
            "Enterprise": "企业",
            "Edu": "教育"
    ]

    nonisolated func localizedDynamicText(_ text: String, _ language: String) -> String {
        guard language == "zh", !text.isEmpty else { return text }
        if let mapped = Self.exactTranslations[text] { return mapped }

        var result = text
        result = replacingRegex(#"^Plan · (.+)$"#, in: result, template: "计划 · $1")
        result = replacingRegex(#"^Membership · (.+)$"#, in: result, template: "会员 · $1")
        result = replacingRegex(#"^(.+) left$"#, in: result, template: "剩余 $1")
        result = replacingRegex(#"^(.+) used$"#, in: result, template: "已用 $1")
        result = replacingRegex(#"^(\d[\d,]*) total$"#, in: result, template: "总量 $1")
        result = replacingRegex(#"^(\d[\d,]*) duplicate rows removed$"#, in: result, template: "已去重 $1 条")
        result = replacingRegex(#"^(\d[\d,]*) tokens$"#, in: result, template: "$1 个 tokens")
        result = replacingRegex(#"^(\d[\d,]*) tokens this month$"#, in: result, template: "本月 $1 tokens")
        result = replacingRegex(#"^(\d[\d,]*) tokens observed this week$"#, in: result, template: "本周记录 $1 tokens")
        result = replacingRegex(#"^(\d[\d,]*) providers in the mesh$"#, in: result, template: "当前连接 $1 个服务")
        result = replacingRegex(#"^(\d[\d,]*) critical right now$"#, in: result, template: "当前有 $1 个告急")
        result = replacingRegex(#"^(\d[\d,]*) lanes tracked$"#, in: result, template: "跟踪 $1 个通道")
        result = replacingRegex(#"^token expires (.+)$"#, in: result, template: "token 将于 $1 过期")
        result = replacingRegex(#"^(.+) needs attention$"#, in: result, template: "$1 需要关注")
        result = replacingRegex(#"^(.+) is getting tight$"#, in: result, template: "$1 余额趋紧")
        result = replacingRegex(#"^(.+) has unpriced models$"#, in: result, template: "$1 有未定价模型")
        result = replacingRegex(#"^(.+) • Reset unavailable$"#, in: result, template: "$1 • 重置时间未知")
        result = replacingRegex(#"^(.+) • Resets soon$"#, in: result, template: "$1 • 即将重置")
        result = replacingRegex(#"^(.+) • Resets in (\d+)d (\d+)h$"#, in: result, template: "$1 • $2天$3小时后重置")
        result = replacingRegex(#"^(.+) • Resets in (\d+)h (\d+)m$"#, in: result, template: "$1 • $2小时$3分钟后重置")
        result = replacingRegex(#"^(.+) • Resets in (\d+)m$"#, in: result, template: "$1 • $2分钟后重置")
        result = replacingRegex(#"^Resets soon$"#, in: result, template: "即将重置")
        result = replacingRegex(#"^Resets in (\d+)d (\d+)h$"#, in: result, template: "$1天$2小时后重置")
        result = replacingRegex(#"^Resets in (\d+)h (\d+)m$"#, in: result, template: "$1小时$2分钟后重置")
        result = replacingRegex(#"^Resets in (\d+)m$"#, in: result, template: "$1分钟后重置")
        result = replacingRegex(#"^Antigravity auth files detected: (\d[\d,]*)\. This snapshot uses the most recently updated file \((.+)\)\.$"#,
                                in: result,
                                template: "检测到 $1 个 Antigravity 授权文件，当前快照使用的是最近更新的那个（$2）。")
        result = replacingRegex(#"^Antigravity exposes per-model quotas, so the dashboard keeps each model separate and puts the tightest ones first\.$"#,
                                in: result,
                                template: "Antigravity 提供按模型拆分的配额，所以面板会保留每个模型的独立窗口，并把最紧张的那些放在前面。")
        result = replacingRegex(#"^Kiro reported (\d[\d,]*) usage lanes\. This card shows the three tightest ones first so attention stays on the lanes that will run out soonest\.$"#,
                                in: result,
                                template: "Kiro 报告了 $1 个用量通道，这张卡片会优先展示最紧张的三个，方便你先关注最先见底的通道。")
        result = replacingRegex(#"^Kiro usage is pulled from the same AWS-backed endpoint the desktop app uses, so this snapshot reflects the live agentic request lanes exposed by the app\.$"#,
                                in: result,
                                template: "Kiro 的用量来自桌面应用同一个 AWS 接口，所以这个快照能反映应用当前暴露出来的实时 agent 请求通道。")
        result = replacingRegex(#"^Resets (.+) at (.+)$"#, in: result, template: "重置于 $1 $2")
        result = replacingRegex(#"^(.+) bonus credits remain$"#, in: result, template: "剩余 $1 奖励额度")
        result = replacingRegex(#"^Week (.+) • Today (.+)$"#, in: result, template: "本周 $1 • 今日 $2")
        return result
    }

    /// 模式恒为编译期字面量，编译一次即缓存复用（规则#9）。NSCache 线程安全，
    /// NSRegularExpression 不可变且线程安全，可跨刷新/线程共享。
    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    nonisolated func replacingRegex(_ pattern: String, in text: String, template: String) -> String {
        let regex: NSRegularExpression
        if let cached = Self.regexCache.object(forKey: pattern as NSString) {
            regex = cached
        } else if let compiled = try? NSRegularExpression(pattern: pattern) {
            Self.regexCache.setObject(compiled, forKey: pattern as NSString)
            regex = compiled
        } else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    // MARK: - Claude threshold + notifications

    func checkClaudeDailyThreshold() {
        guard settings.claudeDailyThreshold > 0 else {
            return
        }

        let today = SharedFormatters.iso8601String(from: Date()).prefix(10)
        if settings.lastNotifiedDate == String(today) {
            return
        }

        guard let claudeProvider = providers.first(where: { $0.baseProviderId == "claude" }),
              let todayCost = claudeProvider.costSummary?.today?.usd else {
            return
        }

        guard todayCost >= settings.claudeDailyThreshold else {
            return
        }

        providerRefreshLog.info("Sending Claude threshold notification: $\(todayCost, privacy: .public) > $\(self.settings.claudeDailyThreshold, privacy: .public)")
        sendClaudeDailyThresholdNotification(cost: todayCost, threshold: settings.claudeDailyThreshold)
        settings.lastNotifiedDate = String(today)
    }

    func sendClaudeDailyThresholdNotification(cost: Double, threshold: Double) {
        let content = UNMutableNotificationContent()
        content.title = settings.t("Claude daily cost alert", "Claude 每日消费提醒")
        content.body = settings.t(
            "Today's cost $\(String(format: "%.2f", cost)) has exceeded the threshold of $\(String(format: "%.2f", threshold))",
            "今日消费 $\(String(format: "%.2f", cost)) 已超过阈值 $\(String(format: "%.2f", threshold))"
        )
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "claude-code-threshold-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        DispatchQueue.main.async {
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    providerRefreshLog.error("Failed to send notification: \(error.localizedDescription)")
                } else {
                    providerRefreshLog.info("Claude threshold notification sent: $\(cost, privacy: .public) > $\(threshold, privacy: .public)")
                }
            }
        }
    }

    func sendErrorNotification(_ message: String) {
        let redactedMessage = SensitiveDataRedactor.redactPaths(in: message)
        providerRefreshLog.error("AIUsage error: \(redactedMessage)")
    }
}
