import SwiftUI
import AppKit
import QuotaBackend

struct ProviderDetailView: View {
    let provider: ProviderData
    let titleOverride: String?
    let subtitleOverride: String?
    let accountDisplayOverride: String?
    let accountEntry: ProviderAccountEntry?
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) var dismiss
    @State private var copiedMessage: String?
    @State private var showingNoteEditor = false
    @State private var showingRemovalAlert = false

    init(
        provider: ProviderData,
        titleOverride: String? = nil,
        subtitleOverride: String? = nil,
        accountDisplayOverride: String? = nil,
        accountEntry: ProviderAccountEntry? = nil
    ) {
        self.provider = provider
        self.titleOverride = titleOverride
        self.subtitleOverride = subtitleOverride
        self.accountDisplayOverride = accountDisplayOverride
        self.accountEntry = accountEntry
    }
    private var isRefreshing: Bool {
        refreshCoordinator.isRefreshInProgress(for: provider)
    }

    private var refreshTimestamp: Date? {
        refreshCoordinator.accountRefreshDate(for: provider)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            inspectorTopBar

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    compactHero

                    if !provider.windows.isEmpty {
                        windowsSection
                    }

                    if !provider.metrics.isEmpty {
                        metricsSection
                    }

                    if let costSummary = provider.costSummary {
                        costSection(costSummary)
                    }

                    if let models = provider.models, !models.isEmpty {
                        modelsSection(models)
                    }

                    if let spotlight = provider.spotlight {
                        spotlightSection(spotlight)
                    }

                    if provider.windows.isEmpty,
                       provider.metrics.isEmpty,
                       provider.costSummary == nil,
                       (provider.models ?? []).isEmpty,
                       provider.spotlight == nil {
                        Text(L(
                            "No extra detail beyond the card. Use the menu for account actions.",
                            "卡片以外暂无更多明细。账号操作请用右上角菜单。"
                        ))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 420, height: 560)
        .appPageChrome(colorScheme)
        .sheet(isPresented: $showingNoteEditor) {
            if let accountEntry {
                AccountNoteEditorView(
                    providerTitle: accountEntry.providerTitle,
                    accountLabel: accountEntry.accountPrimaryLabel,
                    note: accountEntry.accountNote
                ) { updatedNote in
                    appState.updateAccountNote(for: accountEntry, note: updatedNote)
                }
                .environmentObject(appState)
            }
        }
        .subscriptionAccountDeleteConfirmation(isPresented: $showingRemovalAlert) {
            if let accountEntry {
                appState.deleteAccount(accountEntry)
            }
            dismiss()
        }
    }

    // MARK: - Inspector Chrome

    private var inspectorTopBar: some View {
        HStack(spacing: 10) {
            ProviderIconView(provider.providerId, size: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(detailTitle)
                    .font(.headline)
                    .lineLimit(1)
                if let account = detailAccountLabel {
                    Text(account)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Menu {
                Button {
                    Task { await refreshCoordinator.refreshProviderCardNow(provider) }
                } label: {
                    Label(
                        isRefreshing ? L("Refreshing…", "刷新中…") : L("Refresh Account", "刷新账号"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(isRefreshing)

                if let copyTarget = copyTargetValue {
                    Button {
                        copyToPasteboard(copyTarget)
                        copiedMessage = L("Copied", "已复制")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copiedMessage = nil
                        }
                    } label: {
                        Label(L("Copy Account", "复制账号"), systemImage: "doc.on.doc")
                    }
                }

                if accountEntry != nil {
                    Button {
                        showingNoteEditor = true
                    } label: {
                        Label(L("Edit Note", "编辑注释"), systemImage: "square.and.pencil")
                    }

                    Divider()

                    Button {
                        if let accountEntry {
                            appState.hideAccount(accountEntry)
                        }
                        dismiss()
                    } label: {
                        Label(SubscriptionAccountActionCopy.hideTitle, systemImage: "eye.slash")
                    }

                    Button(role: .destructive) {
                        showingRemovalAlert = true
                    } label: {
                        Label(SubscriptionAccountActionCopy.deleteTitle, systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .help(L("Account actions", "账号操作"))

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(L("Close", "关闭"))
            .accessibilityLabel(L("Close", "关闭"))
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var compactHero: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let membership = provider.membershipLabel {
                    badge(text: membership, tint: membershipBadgeTint(for: membership))
                }
                if shouldShowStatusBadge {
                    badge(text: localizedStatusLabel(provider.statusLabel), tint: statusColor)
                }
                Spacer(minLength: 0)
                if let refreshTimestamp {
                    RefreshableTimeView(
                        date: refreshTimestamp,
                        language: appState.language,
                        font: .caption2,
                        foregroundStyle: .secondary
                    )
                }
            }

            Text(provider.headline.primary)
                .font(.title2.weight(.bold))
                .lineLimit(2)

            Text(provider.headline.secondary)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let supporting = provider.headline.supporting {
                Text(supporting)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let copiedMessage {
                Text(copiedMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppSurface.card(colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Windows Section
    
    private var windowsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Quota Windows", "配额窗口"))
                .font(.headline)
            
            VStack(spacing: 10) {
                ForEach(provider.windows) { window in
                    QuotaWindowRow(window: window)
                }
            }
        }
    }
    
    // MARK: - Metrics Section
    
    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Metrics", "指标"))
                .font(.headline)
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                ForEach(provider.metrics) { metric in
                    MetricCard(metric: metric)
                }
            }
        }
    }
    
    // MARK: - Cost Section
    
    private func costSection(_ costSummary: CostSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Token Stats", "Token 统计"))
                .font(.headline)
            
            HStack(spacing: 10) {
                if let today = costSummary.today {
                    CostPeriodCard(label: L("Today", "今天"), period: today)
                }
                if let week = costSummary.week {
                    CostPeriodCard(label: L("This Week", "本周"), period: week)
                }
                if let month = costSummary.month {
                    CostPeriodCard(label: L("This Month", "本月"), period: month)
                }
            }
        }
    }
    
    // MARK: - Models Section
    
    private func modelsSection(_ models: [ModelInfo]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Models", "模型"))
                .font(.headline)
            
            VStack(spacing: 6) {
                ForEach(models) { model in
                    HStack {
                        Text(model.label)
                            .font(.callout)
                        
                        Spacer()
                        
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(model.value)
                                .font(.caption.weight(.semibold))
                            
                            if let note = model.note {
                                Text(note)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(AppSurface.card(colorScheme))
                    .cornerRadius(8)
                }
            }
        }
    }
    
    // MARK: - Spotlight Section
    
    private func spotlightSection(_ spotlight: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                provider.category == ProviderCategory.localCost
                    ? L("About This Tracker", "关于此追踪源")
                    : L("About This Provider", "关于此服务商"),
                systemImage: "lightbulb.fill"
            )
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.orange)
            
            Text(spotlight)
                .font(.callout)
                .foregroundColor(.secondary)
                .lineSpacing(3)
        }
        .padding(12)
        .background(Color.orange.opacity(0.05))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        )
    }
    
    // MARK: - Helpers

    private var detailSubtitle: String? {
        if let subtitleOverride = subtitleOverride?.nilIfBlank {
            return subtitleOverride
        }
        if provider.name != provider.label {
            return provider.name
        }
        return nil
    }

    private var detailTitle: String {
        titleOverride?.nilIfBlank ?? provider.label
    }

    private var detailAccountLabel: String? {
        preferredAccountIdentityLabel(
            [
                accountDisplayOverride,
                provider.accountLabel,
                provider.accountId
            ],
            excluding: detailTitle
        )
    }
    
    private func localizedStatusLabel(_ label: String) -> String {
        guard appState.language == "zh" else { return label }
        switch label {
        case "Healthy":  return "正常"
        case "Watch":    return "偏低"
        case "Critical": return "告急"
        case "Error":    return "错误"
        case "Tracking": return "追踪中"
        case "Idle":     return "空闲"
        case "Active":   return "活跃"
        default: return label
        }
    }

    private var accentColor: Color {
        switch provider.providerId {
        case "antigravity": return .cyan
        case "copilot": return .blue
        case "claude": return .purple
        case "cursor": return .green
        case "gemini": return .orange
        case "kimi": return Color(red: 0.09, green: 0.51, blue: 1.0)
        case "kiro": return .purple
        case "codex": return .indigo
        case "droid": return .yellow
        case "minimax": return Color(red: 0.886, green: 0.087, blue: 0.494)
        case "opencode": return Color(red: 0.18, green: 0.83, blue: 0.75)
        case "warp": return .pink
        default: return .gray
        }
    }
    
    private var statusColor: Color { provider.statusColor
    }

    private var shouldShowStatusBadge: Bool {
        switch provider.status {
        case .critical, .error, .tracking, .idle:
            return true
        case .healthy, .watch:
            return false
        }
    }

    private func badge(text: String, tint: Color) -> some View {
        Text(text)
            .font(.callout)
            .bold()
            .foregroundColor(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tint.opacity(colorScheme == .dark ? 0.18 : 0.12))
            .overlay(
                Capsule()
                    .stroke(tint.opacity(colorScheme == .dark ? 0.35 : 0.18), lineWidth: 1)
            )
            .clipShape(Capsule())
    }

    private var copyTargetValue: String? {
        let candidates: [String?] = [
            detailAccountLabel,
            provider.accountLabel,
            provider.accountId,
            titleOverride,
            detailSubtitle,
            provider.sourceLabel
        ]
        return candidates.compactMap(\.nilIfBlank).first
    }
    
    
    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

// MARK: - Supporting Components

struct QuotaWindowRow: View {
    let window: QuotaWindow
    @Environment(\.colorScheme) private var colorScheme

    private var isUnlimited: Bool {
        window.remainingPercent == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(window.label)
                    .font(.headline)

                Spacer()

                if isUnlimited {
                    Image(systemName: "infinity")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.secondary)
                }

                Text(window.value)
                    .font(.callout)
                    .bold()
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 8)

                    if let remaining = window.remainingPercent {
                        // Metered: green→red fill proportional to remaining
                        RoundedRectangle(cornerRadius: 4)
                            .fill(progressColor(remaining))
                            .frame(width: geometry.size.width * (remaining / 100), height: 8)
                    } else {
                        // Unlimited: full neutral bar so it doesn't look like 0%
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: geometry.size.width, height: 8)
                    }
                }
            }
            .frame(height: 8)

            Text(window.note)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(AppSurface.card(colorScheme))
        .cornerRadius(12)
    }

    private func progressColor(_ remaining: Double) -> Color {
        if remaining > 50 {
            return .green
        } else if remaining > 20 {
            return .orange
        } else {
            return .red
        }
    }
}

struct MetricCard: View {
    let metric: Metric
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.label)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text(metric.value)
                .font(.title3)
                .bold()
            
            if let note = metric.note {
                Text(note)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(AppSurface.card(colorScheme))
        .cornerRadius(8)
    }
}

struct CostPeriodCard: View {
    let label: String
    let period: CostPeriod
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            Text(formatCurrency(period.usd))
                .font(.title2)
                .bold()

            if let tokens = period.tokens {
                Text("\(formatNumber(tokens)) \(L("tokens", "个 tokens"))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let rangeLabel = period.rangeLabel {
                Text(rangeLabel)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(AppSurface.card(colorScheme))
        .cornerRadius(12)
    }
}


#Preview {
    let sampleProvider = ProviderData(
        id: "copilot",
        providerId: "copilot",
        accountId: nil,
        name: "GitHub Copilot",
        label: "Copilot",
        description: "GitHub Copilot usage tracking",
        category: "quota",
        channel: "ide",
        status: .healthy,
        statusLabel: "Healthy",
        theme: ProviderTheme(accent: "blue", glow: "#5aa2ff"),
        sourceLabel: "GitHub CLI",
        sourceType: "gh-cli",
        fetchedAt: SharedFormatters.iso8601String(from: Date()),
        accountLabel: "copilot@example.com",
        membershipLabel: "Pro",
        headline: Headline(
            eyebrow: "Plan · Individual Pro",
            primary: "72%",
            secondary: "tightest remaining allowance",
            supporting: "Billing cycle: Mar 1 → Mar 31"
        ),
        metrics: [
            Metric(label: "Account", value: "octocat", note: nil),
            Metric(label: "Plan", value: "Individual Pro", note: nil),
            Metric(label: "Reset", value: "Mar 31, 11:59 PM", note: nil),
            Metric(label: "Source", value: "GitHub CLI", note: nil)
        ],
        windows: [
            QuotaWindow(label: "Premium", remainingPercent: 72, usedPercent: 28, value: "72% left", note: "1,200 total • Resets Mar 31", resetAt: nil),
            QuotaWindow(label: "Chat", remainingPercent: nil, usedPercent: nil, value: "Unlimited", note: "No fixed cap detected", resetAt: nil),
            QuotaWindow(label: "Completions", remainingPercent: 85, usedPercent: 15, value: "850 left", note: "1,000 total • Resets Mar 31", resetAt: nil)
        ],
        remainingPercent: 72,
        nextResetAt: "2026-03-31T23:59:59Z",
        nextResetLabel: "Mar 31, 11:59 PM",
        spotlight: "Copilot can mix unlimited and metered lanes. The dashboard keeps unlimited channels visible, but only metered windows affect watch and critical states.",
        models: nil,
        costSummary: nil
    )
    
    ProviderDetailView(provider: sampleProvider)
        .environmentObject(AppState.shared)
        .environmentObject(ProviderRefreshCoordinator.shared)
}
