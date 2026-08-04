import SwiftUI
import QuotaBackend

// MARK: - OpenCode Stats Sections
// 管理页的统计区块（与 Claude/Codex 页同一套视觉语言）：
// 1. OpenCodeOverviewStrip —— 顶部汇总条（节点数/已激活/总请求/成功率/总 Tokens/总费用）。
// 2. OpenCodeNodeStatisticsSection —— 选中节点卡片下方内联的「统计信息」网格。
// 3. OpenCodeNodeRecentRequestsSection —— 选中节点卡片下方内联的「最近请求」列表。
// 用量/费用来自 opencode.db 节点归因（直连/代理都有）；成功/失败计数来自
// 代理日志（仅代理模式有数据，缺失时显示 —）；平均响应优先取 db 单条耗时。

// MARK: - Overview Strip

struct OpenCodeOverviewStrip: View {
    @ObservedObject var store: OpenCodeNodeStore
    @ObservedObject var statsStore: OpenCodeNodeStatsStore
    @ObservedObject var proxyRuntime: OpenCodeProxyRuntime
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let totals = aggregateTotals()
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            cell(
                icon: "point.3.connected.trianglepath.dotted",
                title: L("Nodes", "节点数"),
                value: "\(store.nodes.count)",
                tint: .blue
            )
            cell(
                icon: "checkmark.circle.fill",
                title: L("Active", "已激活"),
                value: store.activeNodeId != nil ? "1" : "0",
                tint: .green
            )
            cell(
                icon: "arrow.up.arrow.down",
                title: L("Total Requests", "总请求"),
                value: formatCompactNumber(Double(totals.requests)),
                tint: .orange
            )
            cell(
                icon: "checkmark.shield.fill",
                title: L("Success Rate", "成功率"),
                value: proxySuccessRate(),
                tint: .purple
            )
            cell(
                icon: "bolt.fill",
                title: L("Total Tokens", "总 Tokens"),
                value: formatCompactNumber(Double(totals.tokens)),
                tint: .pink
            )
            cell(
                icon: "dollarsign.circle.fill",
                title: L("Total Cost", "总费用"),
                value: formatProxyCurrency(totals.cost),
                tint: .red
            )
        }
    }

    /// 只统计当前列表里节点的归因数据（已删除节点的历史归因不计入，避免对不上）。
    /// db（直连/路线 B）+ 全局统一代理永久累计两源相加（来源互斥，不双计）。
    private func aggregateTotals() -> (requests: Int, tokens: Int, cost: Double) {
        var requests = 0
        var tokens = 0
        var cost: Double = 0
        for node in store.nodes {
            if let stats = statsStore.stats(for: node) {
                requests += stats.requestCount
                tokens += stats.totalTokens
                cost += stats.costUsd
            }
            if let global = proxyRuntime.globalStats(forNodeId: node.id) {
                requests += global.requestCount
                tokens += global.totalTokens
                cost += global.costUsd
            }
        }
        return (requests, tokens, cost)
    }

    /// 当前列表节点的代理日志成功率（按 configId=节点 id 过滤，与汇总口径一致，
    /// 不被已删除节点的历史日志稀释）；无代理日志（纯直连）时显示 —。
    private func proxySuccessRate() -> String {
        let nodeIds = Set(store.nodes.map(\.id))
        let logs = proxyRuntime.requestLogs.filter { nodeIds.contains($0.configId) }
        guard !logs.isEmpty else { return "—" }
        let successful = logs.filter(\.success).count
        return String(format: "%.1f%%", Double(successful) / Double(logs.count) * 100)
    }

    private func cell(icon: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.12)))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
    }
}

// MARK: - Statistics Section (inline under selected card)

struct OpenCodeNodeStatisticsSection: View {
    let node: OpenCodeNode
    @ObservedObject var statsStore: OpenCodeNodeStatsStore
    @ObservedObject var proxyRuntime: OpenCodeProxyRuntime
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dbStats = statsStore.stats(for: node)
        let global = proxyRuntime.globalStats(forNodeId: node.id)
        let proxyLogs = proxyRuntime.logs(forNodeId: node.id)

        // 直连/路线 B 用量来自 opencode.db；全局统一代理用量来自代理日志的永久累计（按节点定价）。
        // 两者来源互斥（db 已排除全局 provider），相加即该节点的真实总用量。
        let hasUsage = dbStats != nil || global != nil
        let totalRequests = (dbStats?.requestCount ?? 0) + (global?.requestCount ?? 0)
        let inputTokens = (dbStats?.inputTokens ?? 0) + (global?.inputTokens ?? 0)
        let outputTokens = (dbStats?.outputTokens ?? 0) + (global?.outputTokens ?? 0)
        let cacheReadTokens = (dbStats?.cacheReadTokens ?? 0) + (global?.cacheReadTokens ?? 0)
        let cacheCreateTokens = (dbStats?.cacheCreateTokens ?? 0) + (global?.cacheCreateTokens ?? 0)
        let totalCost = (dbStats?.costUsd ?? 0) + (global?.costUsd ?? 0)

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Statistics", "统计信息"))
                    .font(.headline.weight(.bold))
                Spacer()
                if statsStore.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        statsStore.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help(L("Refresh statistics from opencode.db", "从 opencode.db 重新读取统计"))
                }
            }

            HStack(spacing: 12) {
                statsCard(
                    title: L("Total Requests", "总请求"),
                    value: hasUsage ? "\(totalRequests)" : "—",
                    icon: "arrow.up.arrow.down",
                    color: .blue
                )
                statsCard(
                    title: L("Successful", "成功"),
                    value: proxyLogs.isEmpty ? "—" : "\(proxyLogs.filter(\.success).count)",
                    icon: "checkmark.circle",
                    color: .green,
                    help: L("From local proxy logs (proxy / global proxy mode).", "来自本地代理日志（代理 / 全局代理模式）。")
                )
                statsCard(
                    title: L("Failed", "失败"),
                    value: proxyLogs.isEmpty ? "—" : "\(proxyLogs.filter { !$0.success }.count)",
                    icon: "xmark.circle",
                    color: .red,
                    help: L("From local proxy logs (proxy / global proxy mode).", "来自本地代理日志（代理 / 全局代理模式）。")
                )
                statsCard(
                    title: L("Avg Duration", "平均生成耗时"),
                    value: averageResponse(proxyLogs: proxyLogs),
                    icon: "timer",
                    color: .orange,
                    help: L(
                        "Average full generation time per message (from opencode.db). Not time-to-first-token.",
                        "每条消息的平均整段生成耗时（来自 opencode.db），并非首字时间。"
                    )
                )
            }

            HStack(spacing: 12) {
                statsCard(
                    title: L("Input Tokens", "输入 Tokens"),
                    value: hasUsage ? formatCompactNumber(Double(inputTokens)) : "—",
                    icon: "arrow.down.circle",
                    color: .purple
                )
                statsCard(
                    title: L("Output Tokens", "输出 Tokens"),
                    value: hasUsage ? formatCompactNumber(Double(outputTokens)) : "—",
                    icon: "arrow.up.circle",
                    color: .pink
                )
                statsCard(
                    title: L("Cache Read", "缓存读取"),
                    value: hasUsage ? formatCompactNumber(Double(cacheReadTokens)) : "—",
                    icon: "arrow.down.doc",
                    color: .orange
                )
                statsCard(
                    title: L("Cache Write", "缓存写入"),
                    value: hasUsage ? formatCompactNumber(Double(cacheCreateTokens)) : "—",
                    icon: "square.and.arrow.down",
                    color: .indigo
                )
            }

            HStack(spacing: 12) {
                statsCard(
                    title: L("Hit Rate", "命中率"),
                    value: cacheHitRate(input: inputTokens, cacheRead: cacheReadTokens, cacheCreate: cacheCreateTokens),
                    icon: "scope",
                    color: .teal
                )
                statsCard(
                    title: L("Cost", "费用"),
                    value: hasUsage ? formatProxyCurrency(totalCost) : "—",
                    icon: "dollarsign.circle",
                    color: .red,
                    help: global != nil
                        ? L("Includes global proxy spend, estimated from this node's pricing (via proxy logs).", "含全局代理消费，按本节点定价估算（来自代理日志）。")
                        : (node.hasPricing
                            ? L("Pre-computed by OpenCode (opencode.db), same as Usage Stats.", "OpenCode 预计算（opencode.db），与用量统计页同口径。")
                            : L(
                                "This node is unpriced — set per-token prices in the node editor and OpenCode will record real spend for new messages.",
                                "该节点未计价——在节点编辑器中填写单价后，OpenCode 会为新消息记录真实消费。"
                            ))
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
    }

    /// 平均生成耗时：优先 db 单条整段生成耗时（直连/代理都有），无则回退代理日志总耗时。非首字时间。
    private func averageResponse(proxyLogs: [ProxyRequestLog]) -> String {
        let durations = statsStore.recentMessages(for: node).compactMap(\.durationMs)
        if !durations.isEmpty {
            return "\(durations.reduce(0, +) / durations.count)ms"
        }
        guard !proxyLogs.isEmpty else { return "—" }
        let avg = proxyLogs.map(\.responseTimeMs).reduce(0, +) / Double(proxyLogs.count)
        return "\(Int(avg))ms"
    }

    private func cacheHitRate(input: Int, cacheRead: Int, cacheCreate: Int) -> String {
        let eligible = input + cacheRead + cacheCreate
        guard eligible > 0 else { return "—" }
        return String(format: "%.1f%%", Double(cacheRead) / Double(eligible) * 100)
    }

    private func statsCard(title: String, value: String, icon: String, color: Color, help: String? = nil) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(Circle().fill(color.opacity(0.12)))

            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))

            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(0.05))
        )
        .help(help ?? "")
    }
}

// MARK: - Recent Requests Section (inline under selected card)

struct OpenCodeNodeRecentRequestsSection: View {
    let node: OpenCodeNode
    @ObservedObject var statsStore: OpenCodeNodeStatsStore
    @ObservedObject var proxyRuntime: OpenCodeProxyRuntime
    @Environment(\.colorScheme) private var colorScheme

    private static let rowLimit = 10

    /// 统一明细行，按时间合并三类来源（互斥不重复）：
    /// - `.message`        db 成功消息（直连 / 路线B，含费用/耗时）。
    /// - `.proxyFailure`   路线B 代理失败行（成功明细以 db 为准，故只取失败）。
    /// - `.proxyGlobal`    全局统一代理日志（成功+失败都取，db 不记全局流量，代理日志是唯一来源）。
    private enum Entry: Identifiable {
        case message(OpenCodeNodeStatsFetcher.RecentMessage)
        case proxyFailure(ProxyRequestLog)
        case proxyGlobal(ProxyRequestLog)

        var id: String {
            switch self {
            case .message(let m): return "db-\(m.id)"
            case .proxyFailure(let log): return "proxy-\(log.id)"
            case .proxyGlobal(let log): return "global-\(log.id)"
            }
        }

        var date: Date {
            switch self {
            case .message(let m): return m.date
            case .proxyFailure(let log): return log.timestamp
            case .proxyGlobal(let log): return log.timestamp
            }
        }
    }

    private var entries: [Entry] {
        var merged: [Entry] = statsStore.recentMessages(for: node).map { .message($0) }
        for log in proxyRuntime.logs(forNodeId: node.id) {
            if log.isGlobalProxy {
                merged.append(.proxyGlobal(log))
            } else if !log.success {
                merged.append(.proxyFailure(log))
            }
        }
        return Array(merged.sorted { $0.date > $1.date }.prefix(Self.rowLimit))
    }

    var body: some View {
        let displayed = entries
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Recent Requests", "最近请求"))
                    .font(.headline.weight(.bold))
                Spacer()
            }

            if displayed.isEmpty {
                Text(L(
                    "No requests yet. Run an OpenCode conversation after activating this node.",
                    "暂无请求。激活该节点后跑一次 OpenCode 对话即可看到。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(displayed.enumerated()), id: \.element.id) { index, entry in
                        entryRow(entry)
                        if index < displayed.count - 1 {
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func entryRow(_ entry: Entry) -> some View {
        switch entry {
        case .message(let message): messageRow(message)
        case .proxyFailure(let log): failureRow(log)
        case .proxyGlobal(let log):
            // 全局代理：成功行按 db 消息样式（模型/tokens/费用/耗时），失败行复用错误样式。
            if log.success { globalSuccessRow(log) } else { failureRow(log) }
        }
    }

    /// 全局统一代理的成功请求行：db 不记全局流量，明细取自代理日志（费用按节点定价估算）。
    private func globalSuccessRow(_ log: ProxyRequestLog) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(log.upstreamModel.nilIfBlank ?? log.claudeModel)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if log.tokensCacheRead > 0 { cacheIndicator(L("Read", "读"), color: .green) }
                    if log.tokensCacheCreation > 0 { cacheIndicator(L("Write", "写"), color: .purple) }
                }
                HStack(spacing: 6) {
                    tokenLabel("In", value: log.tokensInput, color: .blue)
                    tokenLabel("Out", value: log.tokensOutput, color: .cyan)
                    if log.tokensCacheRead > 0 { tokenLabel("CR", value: log.tokensCacheRead, color: .green) }
                    if log.tokensCacheCreation > 0 { tokenLabel("CW", value: log.tokensCacheCreation, color: .purple) }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Text(String(format: "%.0fms", log.responseTimeMs))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                if log.estimatedCostUSD > 0 {
                    Text(formatProxyCurrency(log.estimatedCostUSD))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                }
            }

            Text(Self.relativeFormatter.localizedString(for: log.timestamp, relativeTo: Date()))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func messageRow(_ message: OpenCodeNodeStatsFetcher.RecentMessage) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(message.modelID)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if message.cacheReadTokens > 0 {
                        cacheIndicator(L("Read", "读"), color: .green)
                    }
                    if message.cacheCreateTokens > 0 {
                        cacheIndicator(L("Write", "写"), color: .purple)
                    }
                }
                HStack(spacing: 6) {
                    tokenLabel("In", value: message.inputTokens, color: .blue)
                    tokenLabel("Out", value: message.outputTokens, color: .cyan)
                    if message.cacheReadTokens > 0 {
                        tokenLabel("CR", value: message.cacheReadTokens, color: .green)
                    }
                    if message.cacheCreateTokens > 0 {
                        tokenLabel("CW", value: message.cacheCreateTokens, color: .purple)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if let durationMs = message.durationMs {
                    Text("\(durationMs)ms")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(formatProxyCurrency(message.costUsd))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
            }

            Text(Self.relativeFormatter.localizedString(for: message.date, relativeTo: Date()))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func failureRow(_ log: ProxyRequestLog) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(log.upstreamModel.nilIfBlank ?? log.claudeModel)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if let errorType = log.errorType {
                        errorTypeBadge(errorType)
                    }
                }
                if let errorMsg = log.errorMessage, !errorMsg.isEmpty {
                    Text(errorMsg)
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.8))
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Text(String(format: "%.0fms", log.responseTimeMs))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                if let code = log.statusCode {
                    Text("HTTP \(code)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red.opacity(0.7))
                }
            }

            Text(Self.relativeFormatter.localizedString(for: log.timestamp, relativeTo: Date()))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.04))
        .help(log.errorMessage ?? "")
    }

    // MARK: - Row Pieces

    private func cacheIndicator(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func tokenLabel(_ tag: String, value: Int, color: Color) -> some View {
        Text("\(tag) \(formatCompactNumber(Double(value)))")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(color.opacity(0.85))
    }

    private func errorTypeBadge(_ type: String) -> some View {
        Text(type)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.red)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.red.opacity(0.12)))
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}
