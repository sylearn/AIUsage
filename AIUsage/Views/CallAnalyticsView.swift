import SwiftUI
import QuotaBackend

// MARK: - Call Analytics View
// 「调用分析」主页：解析 Claude Code / Codex / OpenCode 本地会话日志，
// 统计 MCP / Skill / 工具调用频次，提供 Top-N 排行、每日趋势与零调用（僵尸技能/MCP）检测。
// 数据只读、零埋点；规则命中因原理不可得不在此统计。设计见 docs/CALL_ANALYTICS_DESIGN.md。

struct CallAnalyticsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @StateObject var store = CallAnalyticsStore.shared

    @AppStorage("callAnalytics.range") private var windowRaw = CallWindow.month.rawValue
    @AppStorage("callAnalytics.scope") private var scopeRaw = CallScope.all.rawValue
    /// 自定义区间起止（参考时间，0 = 未设置→回退到默认「最近 7 天」）。
    @AppStorage("callAnalytics.customStart") private var customStartTS: Double = 0
    @AppStorage("callAnalytics.customEnd") private var customEndTS: Double = 0
    @State var lens: CallLens = .mcp
    /// MCP 排行里已展开（下钻查看 tool 列表）的 server。
    @State var expandedServers: Set<String> = []
    /// 自定义区间的日期选择弹层是否展开。
    @State private var showCustomPopover = false
    @State private var showSourceHelp = false

    var window: CallWindow { CallWindow(rawValue: windowRaw) ?? .month }

    /// 被侧边栏隐藏的来源——「来源」分段隐藏其选项，「全部」聚合也排除它。
    private var hiddenSources: Set<CallSourceKind> {
        AgentVisibility.hiddenCallSources(hidden: appState.settings.hiddenSidebarSections)
    }

    /// 持久化选中的来源若其 agent 已被隐藏，则回退到「全部」（取消隐藏后自动恢复）。
    var scope: CallScope {
        let stored = CallScope(rawValue: scopeRaw) ?? .all
        if let kind = stored.sourceKind, hiddenSources.contains(kind) { return .all }
        return stored
    }

    /// 来源分段仅列出未隐藏的 agent（「全部」常驻）。
    var visibleScopes: [CallScope] {
        CallScope.allCases.filter { item in
            guard let kind = item.sourceKind else { return true }
            return !hiddenSources.contains(kind)
        }
    }

    /// 排行图例/页脚用：未隐藏的来源种类。
    var visibleSourceKinds: [CallSourceKind] {
        CallSourceKind.allCases.filter { !hiddenSources.contains($0) }
    }

    var derived: CallAnalyticsDerived {
        CallAnalyticsDerived(snapshot: store.snapshot, scope: scope, hiddenSources: hiddenSources)
    }

    /// 解析后的时间范围规格：稳定标识 + 闭区间起止界（传给 store/engine）。
    /// 前四档走 `CallWindow.cutoff`；`custom` 用用户所选起止日期（起 > 止时自动对调）。
    private struct RangeSpec { let rangeKey: String; let cutoff: Date?; let end: Date? }

    private var rangeSpec: RangeSpec {
        guard window == .custom else {
            return RangeSpec(rangeKey: window.rangeKey, cutoff: window.cutoff(), end: nil)
        }
        let cal = Calendar.current
        let a = cal.startOfDay(for: customStartBinding.wrappedValue)
        let b = cal.startOfDay(for: customEndBinding.wrappedValue)
        let lo = min(a, b), hi = max(a, b)
        let key = "custom:\(Self.dayKeyFormatter.string(from: lo)):\(Self.dayKeyFormatter.string(from: hi))"
        return RangeSpec(rangeKey: key, cutoff: lo, end: hi)
    }

    /// 可见范围是否坐实为「单天」（今日，或起止同一天的自定义）——此时隐藏「每日调用」卡（单根条无意义）。
    private var isSingleDayRange: Bool {
        switch window {
        case .today:
            return true
        case .custom:
            return Calendar.current.isDate(customStartBinding.wrappedValue,
                                           inSameDayAs: customEndBinding.wrappedValue)
        default:
            return false
        }
    }

    /// 仅用于拼接稳定缓存键的日期串（实际过滤由引擎按本地时区 dayKey 完成）。
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 胶囊按钮上的紧凑日期（同年只显示 MM-dd）。
    private static let pillDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd"
        return f
    }()

    /// 胶囊按钮文案：`起 → 止`；跨年时退回 `yyyy-MM-dd`。
    private var customRangeLabel: String {
        let lo = min(customStartBinding.wrappedValue, customEndBinding.wrappedValue)
        let hi = max(customStartBinding.wrappedValue, customEndBinding.wrappedValue)
        let cal = Calendar.current
        let sameYear = cal.component(.year, from: lo) == cal.component(.year, from: hi)
        let fmt = sameYear ? Self.pillDateFormatter : Self.dayKeyFormatter
        return "\(fmt.string(from: lo)) → \(fmt.string(from: hi))"
    }

    /// 自定义区间默认值：最近 7 天（今天往前 6 天 ~ 今天）。
    private static func defaultCustomRange() -> (start: Date, end: Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -6, to: today) ?? today
        return (start, today)
    }

    private var customStartBinding: Binding<Date> {
        Binding(
            get: { customStartTS > 0 ? Date(timeIntervalSinceReferenceDate: customStartTS)
                                     : Self.defaultCustomRange().start },
            set: { customStartTS = $0.timeIntervalSinceReferenceDate }
        )
    }

    private var customEndBinding: Binding<Date> {
        Binding(
            get: { customEndTS > 0 ? Date(timeIntervalSinceReferenceDate: customEndTS)
                                   : Self.defaultCustomRange().end },
            set: { customEndTS = $0.timeIntervalSinceReferenceDate }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                controlDeck
                if store.snapshot.isEmpty && !store.isRefreshing {
                    emptyState
                } else {
                    kpiStrip
                    if !isSingleDayRange { trendCard }
                    rankingCard
                    if derived.hasSubagentActivity {
                        agentCard
                    }
                    zeroCallCard
                }
                sourceFooter
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appPageChrome(colorScheme)
        .task(id: rangeSpec.rangeKey) {
            let spec = rangeSpec
            await store.refreshIfNeeded(rangeKey: spec.rangeKey, cutoff: spec.cutoff, end: spec.end)
        }
    }

    // MARK: - Control deck
    // 统一控制台：左「来源」、中「时间范围」（紧凑等宽分段控件，与「用量统计」同款），右「重新扫描」。
    // 窄宽时 ViewThatFits 自动从「单行」回退为「两行」，永不横向溢出。

    // 固定两行（对齐「用量统计」的稳定布局）：第一行「来源」+「重新扫描」，第二行「时间范围」。
    // 不做单行/两行自适应切换——避免拉伸时布局来回跳变。两簇标签等宽，分段控件左缘对齐。
    private var controlDeck: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                sourceCluster
                Spacer(minLength: 8)
                refreshControl
            }
            windowCluster
            if window == .custom {
                customRangeRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppStroke.card(colorScheme), lineWidth: 1)
        )
    }

    private func controlCluster<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            content()
        }
    }

    private var sourceCluster: some View {
        controlCluster(L("Source", "来源", key: "calls.source"), systemImage: "square.stack.3d.up") {
            StatsSegmentedControl(
                visibleScopes,
                selection: scopeBinding,
                segmentWidth: 84,
                tint: .indigo
            ) { $0.title }
        }
    }

    private var windowCluster: some View {
        controlCluster(L("Range", "时间范围", key: "calls.range"), systemImage: "calendar") {
            StatsSegmentedControl(
                CallWindow.allCases,
                selection: windowBinding,
                segmentWidth: 56,
                tint: .blue
            ) { $0.title }
        }
    }

    // 仅在「自定义」档显示：一个与其它控件同款的胶囊按钮，点开弹层选日期（含快捷预设）。
    private var customRangeRow: some View {
        controlCluster(L("Dates", "起止", key: "calls.range.custom"), systemImage: "calendar.badge.clock") {
            Button {
                showCustomPopover.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(customRangeLabel)
                        .font(.caption.monospacedDigit())
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showCustomPopover, arrowEdge: .bottom) {
                customRangePopover
            }
        }
    }

    // 自定义区间弹层：快捷预设（最近 7/30 天、本月）+ 起止两个日期选择器（UI 即约束 起 ≤ 止 ≤ 今天）。
    private var customRangePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Quick ranges", "快捷范围", key: "calls.range.presets"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                presetChip(L("7 days", "最近 7 天", key: "calls.preset.7d")) { applyPreset(days: 7) }
                presetChip(L("30 days", "最近 30 天", key: "calls.preset.30d")) { applyPreset(days: 30) }
                presetChip(L("Month", "本月", key: "calls.preset.month")) { applyThisMonth() }
            }
            Divider()
            datePickerRow(L("From", "起始", key: "calls.range.from"),
                          binding: customStartBinding,
                          in: ...customEndBinding.wrappedValue)
            datePickerRow(L("To", "结束", key: "calls.range.to"),
                          binding: customEndBinding,
                          in: customStartBinding.wrappedValue...Date())
        }
        .padding(14)
        .frame(width: 248)
    }

    private func datePickerRow(_ title: String, binding: Binding<Date>, in range: ClosedRange<Date>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            DatePicker("", selection: binding, in: range, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
        }
    }

    private func datePickerRow(_ title: String, binding: Binding<Date>, in range: PartialRangeThrough<Date>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            DatePicker("", selection: binding, in: range, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
        }
    }

    private func presetChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    /// 预设：最近 N 天（今天往前 N-1 天 ~ 今天）。
    private func applyPreset(days: Int) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        customStartTS = start.timeIntervalSinceReferenceDate
        customEndTS = today.timeIntervalSinceReferenceDate
    }

    /// 预设：本月 1 号 ~ 今天。
    private func applyThisMonth() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.dateInterval(of: .month, for: today)?.start ?? today
        customStartTS = start.timeIntervalSinceReferenceDate
        customEndTS = today.timeIntervalSinceReferenceDate
    }

    private var refreshControl: some View {
        HStack(spacing: 8) {
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                let spec = rangeSpec
                Task { await store.refresh(rangeKey: spec.rangeKey, cutoff: spec.cutoff, end: spec.end) }
            } label: {
                Label(L("Rescan", "重新扫描", key: "calls.rescan"), systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(store.isRefreshing)
        }
    }

    /// @AppStorage 存的是 rawValue，这里桥接成枚举 Binding 供分段控件使用。
    private var scopeBinding: Binding<CallScope> {
        Binding(
            get: { CallScope(rawValue: scopeRaw) ?? .all },
            set: { scopeRaw = $0.rawValue }
        )
    }

    private var windowBinding: Binding<CallWindow> {
        Binding(
            get: { CallWindow(rawValue: windowRaw) ?? .month },
            set: { windowRaw = $0.rawValue }
        )
    }

    // MARK: - KPI

    private var kpiStrip: some View {
        let d = derived
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            kpiCell(title: L("Total Calls", "总调用", key: "calls.kpi.total"),
                    value: "\(d.totalCalls)", icon: "wrench.and.screwdriver", tint: .secondary)
            kpiCell(title: L("MCP Calls", "MCP 调用", key: "calls.kpi.mcp"),
                    value: "\(d.mcpCalls)", icon: "puzzlepiece.extension", tint: .purple)
            kpiCell(title: L("Skill Calls", "技能调用", key: "calls.kpi.skill"),
                    value: "\(d.skillCalls)", icon: "sparkles", tint: .pink)
            kpiCell(title: L("Active MCP Servers", "活跃 MCP", key: "calls.kpi.servers"),
                    value: "\(d.usedServers.count)", icon: "server.rack", tint: .blue)
            kpiCell(title: L("Zombie Skills", "僵尸技能", key: "calls.kpi.zombie"),
                    value: "\(d.zombieSkillCount)", icon: "moon.zzz", tint: .orange)
        }
    }

    private func kpiCell(title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint == .secondary ? Color.primary : tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppSurface.card(colorScheme)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppStroke.card(colorScheme), lineWidth: 1))
    }

    // MARK: - Daily trend

    /// 趋势卡副标题：与所选时间范围口径一致（今日/本周/本月/全部历史）。
    private var trendSubtitle: String {
        switch window {
        case .today: return L("Today", "今日", key: "calls.trend.today")
        case .week:  return L("This week", "本周", key: "calls.trend.week")
        case .month: return L("This month", "本月", key: "calls.trend.month")
        case .all:   return L("All history", "全部历史", key: "calls.trend.all")
        case .custom:
            let lo = min(customStartBinding.wrappedValue, customEndBinding.wrappedValue)
            let hi = max(customStartBinding.wrappedValue, customEndBinding.wrappedValue)
            return "\(Self.dayKeyFormatter.string(from: lo)) – \(Self.dayKeyFormatter.string(from: hi))"
        }
    }

    private var trendCard: some View {
        let points = derived.dailyCounts
        return cardContainer(
            title: L("Daily Calls", "每日调用", key: "calls.trend.title"),
            subtitle: trendSubtitle
        ) {
            if points.isEmpty {
                Text(L("No calls in range", "范围内暂无调用", key: "calls.trend.empty"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                CallTrendBars(points: points)
                    .frame(height: 64)
            }
        }
    }

    // MARK: - Agent breakdown (Claude main vs subagent)

    private var agentCard: some View {
        let rows = derived.agentBreakdown()
        let total = max(rows.reduce(0) { $0 + $1.count }, 1)
        return cardContainer(
            title: L("By Agent (Claude)", "按 Agent 分组（Claude）", key: "calls.agent.title"),
            subtitle: L("Invocations of the main session and each subagent type (by session) — only Claude exposes this", "主会话与各子代理类型的调用次数（按会话计）· 仅 Claude 提供该维度", key: "calls.agent.sub")
        ) {
            VStack(spacing: 8) {
                ForEach(rows) { agentRow($0, total: total) }
            }
        }
    }

    private func agentRow(_ row: AgentBreakdownRow, total: Int) -> some View {
        // id: "main" = 主会话；"subagent" = 类型未知的子代理；其余 = 具体子代理类型名（Explore/Plan…）。
        let isMain = row.id == "main"
        let label: String
        if isMain {
            label = L("Main", "主会话", key: "calls.agent.label.main")
        } else if row.id == "subagent" {
            label = L("Subagents", "子代理", key: "calls.agent.label.sub")
        } else {
            label = row.id
        }
        let style = CallAnalyticsView.agentStyle(for: row.id)
        let ratio = CGFloat(row.count) / CGFloat(total)
        // 主会话齐左、加粗、条更高；子代理整体右移并带「↳」层级线索、字号与条高更小，凸显从属关系。
        return HStack(spacing: 8) {
            if !isMain {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
            }
            Label {
                Text(label).lineLimit(1).truncationMode(.tail)
            } icon: {
                Image(systemName: style.icon).foregroundStyle(style.color)
            }
            .font(isMain ? .callout.weight(.semibold) : .caption)
            .labelStyle(.titleAndIcon)
            .frame(width: 150, alignment: .leading)
            .help(label)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    Capsule().fill(style.color.opacity(isMain ? 0.9 : 0.6))
                        .frame(width: max(4, proxy.size.width * ratio))
                }
            }
            .frame(height: isMain ? 14 : 11)
            Text("\(row.count)")
                .font((isMain ? Font.callout : Font.caption).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
                .help(L("Invocations (by session)", "被调用次数（按会话计）", key: "calls.agent.count.help"))
        }
        .padding(.leading, isMain ? 0 : 14)
    }

    /// 按 agent id 给出稳定的图标 + 颜色：主会话/通用子代理固定，具体子代理类型按关键词选图标、按名称哈希取调色板色。
    /// 关键词按「- / _ / 空格 等非字母数字」分词后整词比对（不是子串），避免「guide 命中 ui」这类误判。
    static func agentStyle(for id: String) -> (icon: String, color: Color) {
        if id == "main" { return ("person.crop.circle.fill", .blue) }
        if id == "subagent" { return ("person.2.fill", .gray) }

        let tokens = Set(
            id.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
        func has(_ keywords: String...) -> Bool { keywords.contains(where: tokens.contains) }

        let icon: String
        if has("explore", "explorer") {
            icon = "magnifyingglass"
        } else if has("plan", "planner", "planning") {
            icon = "list.bullet.rectangle"
        } else if has("review", "reviewer") {
            icon = "checkmark.seal"
        } else if has("bug", "debug", "debugger") {
            icon = "ladybug"
        } else if has("test", "tester", "testing") {
            icon = "checkmark.diamond"
        } else if has("doc", "docs", "documentation") {
            icon = "doc.text"
        } else if has("ui", "sketch", "sketcher", "design", "designer") {
            icon = "paintbrush.pointed"
        } else if has("research", "researcher", "search") {
            icon = "magnifyingglass.circle"
        } else if has("story", "write", "writer", "writing") {
            icon = "square.and.pencil"
        } else if has("shell", "command", "terminal") {
            icon = "terminal"
        } else if has("general", "purpose") {
            icon = "sparkles"
        } else {
            icon = "person.2"
        }

        let palette: [Color] = [.orange, .purple, .green, .pink, .teal, .indigo, .mint, .cyan]
        var hash: UInt64 = 1469598103934665603 // FNV-1a 偏移基
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return (icon, palette[Int(hash % UInt64(palette.count))])
    }

    // MARK: - Source footer

    private var sourceFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(L("Data Sources", "数据来源", key: "calls.sources.title"))
                    .font(.subheadline.weight(.semibold))
                Text(L("Local CLI logs", "本地 CLI 日志"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Button {
                    showSourceHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("About data sources", "数据来源说明"))
                .popover(isPresented: $showSourceHelp, arrowEdge: .top) {
                    sourceHelpPopover
                }
                Spacer()
            }

            ForEach(store.snapshot.sources.filter { !hiddenSources.contains($0.source) }, id: \.source) { status in
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.errorCode != nil ? Color.red : (status.available ? Color.green : Color.secondary.opacity(0.4)))
                        .frame(width: 7, height: 7)
                    Text(status.source.displayName).font(.caption2.weight(.medium))
                    Text(sourceDetail(status)).font(.caption2).foregroundStyle(.secondary)
                }
                .help(sourceHelp(status))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceHelpPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("About call data", "关于调用数据"))
                .font(.headline)
            Text(L(
                "This page scans local Claude Code, Codex and OpenCode session logs. It is independent from Gateway usage statistics; Claude Desktop and Science traffic is not included.",
                "本页扫描 Claude Code、Codex 与 OpenCode 的本地会话日志，与 Gateway 用量统计相互独立；不包含 Claude Desktop 与 Science 流量。"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(L(
                "Rules-hit counts are unavailable because rules are injected as context rather than recorded as discrete calls.",
                "规则以上下文形式注入，并不会记录为独立调用，因此无法统计规则命中次数。"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 350, alignment: .leading)
    }

    /// 单行简述：绿点正常时显示「扫 N 个会话 · M 次调用」。
    private func sourceDetail(_ status: CallSourceStatus) -> String {
        if let code = status.errorCode {
            return L("error: \(code)", "采集失败: \(code)", key: "calls.source.error")
        }
        if !status.available {
            return L("not installed / no data", "未安装 / 无数据", key: "calls.source.absent")
        }
        return L("scanned \(status.filesScanned) sessions · \(status.eventCount) calls",
                 "扫 \(status.filesScanned) 个会话 · \(status.eventCount) 次调用",
                 key: "calls.source.ok")
    }

    /// 悬停完整说明：解释「会话文件」与「调用次数」分别是什么。
    private func sourceHelp(_ status: CallSourceStatus) -> String {
        if let code = status.errorCode {
            return L("Collection failed (\(code)).",
                     "采集失败（\(code)）。", key: "calls.source.help.error")
        }
        if !status.available {
            return L("\(status.source.displayName) not installed, or no local session logs found.",
                     "未检测到 \(status.source.displayName)，或本地没有会话日志。",
                     key: "calls.source.help.absent")
        }
        let summary = L(
            "Scanned \(status.filesScanned) \(status.source.displayName) session file(s) and counted \(status.eventCount) tool / MCP / skill calls within the selected range.",
            "在所选时间范围内，扫描了 \(status.filesScanned) 个 \(status.source.displayName) 会话文件，统计到 \(status.eventCount) 次工具 / MCP / 技能调用。",
            key: "calls.source.help.ok"
        )
        guard status.source == .claude else { return summary }
        return summary + L(
            " This source contains Claude Code sessions only; Desktop and Science Gateway traffic is excluded.",
            " 此来源仅包含 Claude Code 会话，不含 Desktop 与 Science 的 Gateway 流量。"
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(L("No tool/MCP/Skill calls found locally.",
                   "本地未发现工具 / MCP / 技能调用。",
                   key: "calls.empty.title"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(L("Use Claude Code, Codex or OpenCode, then rescan.",
                   "使用 Claude Code、Codex 或 OpenCode 后重新扫描。",
                   key: "calls.empty.hint"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Shared card container

    func cardContainer<Content: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(AppSurface.card(colorScheme)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppStroke.card(colorScheme), lineWidth: 1))
    }

    static func color(for source: CallSourceKind) -> Color {
        switch source {
        case .claude: return .orange
        case .codex: return .green
        case .opencode: return .blue
        }
    }
}

// MARK: - Daily trend bars

private struct CallTrendBars: View {
    let points: [(day: String, count: Int)]

    var body: some View {
        let maxCount = max(points.map(\.count).max() ?? 1, 1)
        GeometryReader { proxy in
            let spacing: CGFloat = 2
            let count = points.count
            let barWidth = max(2, (proxy.size.width - spacing * CGFloat(max(count - 1, 0))) / CGFloat(max(count, 1)))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(points, id: \.day) { point in
                    let ratio = CGFloat(point.count) / CGFloat(maxCount)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor.opacity(0.25 + 0.75 * ratio))
                        .frame(width: barWidth, height: max(2, proxy.size.height * ratio))
                        .help("\(point.day): \(point.count)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}
