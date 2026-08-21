import SwiftUI
import AppKit
import QuotaBackend

struct ProviderCard: View {
    let provider: ProviderData
    let titleOverride: String?
    let subtitleOverride: String?
    let footerAccountLabelOverride: String?
    let accountEntry: ProviderAccountEntry?
    let refreshAction: (() async -> Void)?
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @EnvironmentObject var activationManager: ProviderActivationManager
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var cpaGateway = CLIProxyGatewayManager.shared
    @State private var isHovered = false
    @State private var showingDetail = false
    @State private var showingNoteEditor = false
    @State private var activationMessage: String?
    @State private var showActivationAlert = false
    @State private var pendingAccountDeletion = false

    init(
        provider: ProviderData,
        titleOverride: String? = nil,
        subtitleOverride: String? = nil,
        footerAccountLabelOverride: String? = nil,
        accountEntry: ProviderAccountEntry? = nil,
        refreshAction: (() async -> Void)? = nil
    ) {
        self.provider = provider
        self.titleOverride = titleOverride
        self.subtitleOverride = subtitleOverride
        self.footerAccountLabelOverride = footerAccountLabelOverride
        self.accountEntry = accountEntry
        self.refreshAction = refreshAction
    }
    private var isRefreshing: Bool {
        refreshCoordinator.isRefreshInProgress(for: provider)
    }

    private var refreshTimestamp: Date? {
        refreshCoordinator.accountRefreshDate(for: provider)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                providerIcon

                Text(headerTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                if isActiveProviderAccount && canActivateProvider {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .help(L("Active CLI account", "当前 CLI 账号"))
                }

                if isPinnedToMenuBar {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(accentColor.opacity(0.7))
                        .rotationEffect(.degrees(45))
                }

                Spacer(minLength: 8)

                if let membership = provider.membershipLabel {
                    GatewayQuietBadge(text: membership, tint: membershipBadgeTint(for: membership))
                }
                if shouldShowStatusBadge {
                    GatewayQuietBadge(text: localizedStatusLabel(provider.statusLabel), tint: statusColor)
                }
            }

            if let headlineValue = compactHeadlineValue {
                Text(headlineValue)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if let secondary = provider.headline.secondary.nilIfBlank {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if useMultiWindowLayout {
                MultiWindowQuotaView(
                    windows: provider.windows,
                    accentColor: accentColor,
                    visibleWindowLimit: Self.multiWindowVisibleLimit(for: provider.providerId)
                )
            } else if let remaining = provider.remainingPercent {
                QuotaIndicatorView(remainingPercent: remaining, accentColor: accentColor, resetAt: provider.nextResetAt)
            }

            HStack(alignment: .center, spacing: 8) {
                if let account = footerAccountLabel {
                    Label(account, systemImage: accountIdentityIcon(for: account))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let subtitle = headerSubtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if isRefreshing {
                    SmallProgressView()
                        .frame(width: 12, height: 12)
                } else if let refreshTimestamp {
                    RefreshableTimeView(
                        date: refreshTimestamp,
                        language: appState.language,
                        font: .caption2,
                        foregroundStyle: .secondary,
                        style: .relativeOnly
                    )
                }
            }
        }
        .frame(minHeight: 124)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(cardBorderColor, lineWidth: 1)
        )
        .shadow(color: cardShadowColor, radius: isHovered ? 10 : 3, x: 0, y: isHovered ? 4 : 1)
        .animation(.easeInOut(duration: 0.18), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            showingDetail = true
        }
        .contextMenu {
            if canActivateProvider {
                if isActiveProviderAccount {
                    Label(L("Active Account", "当前账号"), systemImage: "checkmark.circle.fill")
                } else {
                    Button {
                        activateThisAccount()
                    } label: {
                        Label(L("Activate", "激活"), systemImage: "bolt.fill")
                    }
                }
                Divider()
            }

            Button {
                showingDetail = true
            } label: {
                Label(L("Open Details", "查看详情"), systemImage: "doc.text.magnifyingglass")
            }

            if let accountEntry, accountEntry.canEditNote {
                Button {
                    showingNoteEditor = true
                } label: {
                    Label(L("Edit Note", "编辑注释"), systemImage: "square.and.pencil")
                }
            }

            Button {
                Task {
                    if let refreshAction {
                        await refreshAction()
                    } else {
                        await refreshCoordinator.refreshProviderCardNow(provider)
                    }
                }
            } label: {
                Label(L("Refresh This Account", "刷新此账号"), systemImage: "arrow.clockwise")
            }

            if let candidate = cpaSyncCandidate {
                Divider()
                if cpaGateway.runtime.state.isRunning, case .compatible = candidate.compatibility {
                    Button {
                        Task { await cpaGateway.syncAccount(candidate) }
                    } label: {
                        Label(
                            cpaGateway.isSynced(candidate)
                                ? L("Resync to CPA", "重新同步到 CPA")
                                : L("Sync Copy to CPA", "同步副本到 CPA"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                } else {
                    Button {
                        CLIProxyGatewayNavigation.shared.showAccounts()
                        appState.presentMainWindow(section: .subscriptionGateway)
                    } label: {
                        Label(L("Open CPA Accounts", "打开 CPA 账号"), systemImage: "person.2")
                    }
                }
            }

            if let account = footerAccountLabel {
                Button {
                    copyToPasteboard(account)
                } label: {
                    Label(L("Copy Account", "复制账号"), systemImage: "doc.on.doc")
                }
            }

            if let accountEntry {
                let pinned = settings.menuBarPinnedQuotaAccountIds.contains(accountEntry.id)
                Button {
                    var ids = settings.menuBarPinnedQuotaAccountIds
                    if pinned { ids.remove(accountEntry.id) } else { ids.insert(accountEntry.id) }
                    settings.menuBarPinnedQuotaAccountIds = ids
                } label: {
                    if pinned {
                        Label(L("Unpin from Menu Bar", "从菜单栏取消固定"), systemImage: "pin.slash")
                    } else {
                        Label(L("Pin to Menu Bar", "固定到菜单栏"), systemImage: "pin")
                    }
                }

                SubscriptionAccountDestructiveMenuItems(
                    onHide: {
                        appState.hideAccount(accountEntry)
                    },
                    onRequestDelete: {
                        pendingAccountDeletion = true
                    }
                )
            }
        }
        .subscriptionAccountDeleteConfirmation(isPresented: $pendingAccountDeletion) {
            if let accountEntry {
                appState.deleteAccount(accountEntry)
            }
        }
        .sheet(isPresented: $showingDetail) {
            ProviderDetailView(
                provider: provider,
                titleOverride: titleOverride,
                subtitleOverride: subtitleOverride,
                accountDisplayOverride: footerAccountLabelOverride,
                accountEntry: accountEntry
            )
        }
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
        .alert(L("Account Switch", "账号切换"), isPresented: $showActivationAlert) {
            Button("OK") { activationMessage = nil }
        } message: {
            Text(activationMessage ?? "")
        }
    }
    
    // MARK: - Components
    
    private var providerIcon: some View {
        ProviderIconView(provider.providerId, size: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(width: 34, height: 34)
    }

    private var isPinnedToMenuBar: Bool {
        guard let accountEntry else { return false }
        return settings.menuBarPinnedQuotaAccountIds.contains(accountEntry.id)
    }

    private var headerTitle: String {
        titleOverride?.nilIfBlank ?? provider.label
    }

    private var headerSubtitle: String? {
        subtitleOverride?.nilIfBlank
    }

    private var footerAccountLabel: String? {
        // 右上角已有 membership badge（Business / Edu 等）时，不再在邮箱前拼 workspace，避免重复。
        let emailOnly = preferredAccountIdentityLabel(
            [
                footerAccountLabelOverride,
                provider.accountLabel,
                provider.accountId
            ],
            excluding: headerTitle
        )
        if provider.membershipLabel?.nilIfBlank != nil {
            return emailOnly
        }
        if let wsLabel = provider.workspaceLabel, wsLabel != "Personal",
           let email = emailOnly {
            return "\(wsLabel) · \(email)"
        }
        return emailOnly
    }

    private var compactHeadlineValue: String? {
        guard let primary = provider.headline.primary.nilIfBlank else { return nil }
        if provider.remainingPercent != nil {
            return nil
        }
        return primary
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

    private var statusBadge: some View {
        badge(text: localizedStatusLabel(provider.statusLabel), tint: statusColor)
    }
    
    // MARK: - Helpers
    
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

    private var canActivateProvider: Bool {
        activationManager.canActivateProvider(provider.providerId) && accountEntry != nil
    }

    private var cpaSyncCandidate: CLIProxyAccountSyncCandidate? {
        guard let entry = accountEntry,
              let credentialID = entry.storedAccount?.credentialId else { return nil }
        return cpaGateway.syncCandidate(
            providerId: entry.providerId,
            label: entry.accountPrimaryLabel,
            credentialId: credentialID
        )
    }

    private var isActiveProviderAccount: Bool {
        guard let entry = accountEntry else { return false }
        return activationManager.isActiveAccount(entry)
    }

    private var canActivateCodex: Bool { canActivateProvider }
    private var isCodexActiveAccount: Bool { isActiveProviderAccount }

    private func activateThisAccount() {
        guard let entry = accountEntry else { return }
        do {
            try activationManager.activateAccount(entry: entry)
        } catch {
            if activationManager.activationResult == nil {
                activationMessage = SensitiveDataRedactor.redactedMessage(for: error)
                showActivationAlert = true
            }
        }
        if let result = activationManager.activationResult {
            switch result {
            case .success(let msg), .failure(let msg):
                activationMessage = msg
                showActivationAlert = true
            }
            activationManager.activationResult = nil
        }
    }

    private func activateThisCodexAccount() { activateThisAccount() }

    private var useMultiWindowLayout: Bool {
        Self.multiWindowProviderIds.contains(provider.providerId)
            && provider.windows.count >= 2
            && provider.windows.contains(where: { $0.remainingPercent != nil })
    }

    /// 采用多窗口进度布局的服务商。
    /// Codex / Kimi / MiniMax：卡片只展示 5 小时 + 周窗口两条（第三条如 Code Review 进详情）。
    /// Droid Individual：5 小时 / 周 / 月都是硬限制，卡片展示三条。
    private static let multiWindowProviderIds: Set<String> = ["codex", "kimi", "minimax", "droid"]

    private static func multiWindowVisibleLimit(for providerId: String) -> Int {
        providerId == "droid" ? 3 : 2
    }

    private var shouldShowStatusBadge: Bool {
        switch provider.status {
        case .critical, .error, .tracking, .idle:
            return true
        case .healthy, .watch:
            return false
        }
    }

    private var cardBackgroundColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(isHovered ? 0.09 : 0.065)
        }
        return AppSurface.card(.light)
    }

    private var cardBorderColor: Color {
        if isHovered {
            return accentColor.opacity(colorScheme == .dark ? 0.55 : 0.32)
        }
        return AppStroke.card(colorScheme)
    }

    private var cardShadowColor: Color {
        if colorScheme == .dark {
            return Color.black.opacity(isHovered ? 0.35 : 0.2)
        }
        return isHovered ? Color.black.opacity(0.10) : Color.black.opacity(0.04)
    }
    
    private var statusColor: Color { provider.statusColor }

    private func badge(text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption)
            .bold()
            .foregroundColor(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(colorScheme == .dark ? 0.18 : 0.12))
            .overlay(
                Capsule()
                    .stroke(tint.opacity(colorScheme == .dark ? 0.35 : 0.18), lineWidth: 1)
            )
            .clipShape(Capsule())
    }

    private var quotaIndicatorPlaceholderHeight: CGFloat {
        switch settings.quotaIndicatorStyle {
        case .bar:
            return 24
        case .ring:
            return 92
        case .segments:
            return 50
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

#Preview {
    let sampleProvider = ProviderData(
        id: "copilot",
        providerId: "copilot",
        accountId: nil,
        name: "GitHub Copilot",
        label: "Copilot",
        description: "GitHub Copilot usage",
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
            eyebrow: "Plan · Individual",
            primary: "85%",
            secondary: "remaining in this cycle",
            supporting: "GitHub account"
        ),
        metrics: [],
        windows: [],
        remainingPercent: 85,
        nextResetAt: nil,
        nextResetLabel: nil,
        spotlight: nil,
        models: nil,
        costSummary: nil
    )
    
    ProviderCard(provider: sampleProvider)
        .frame(width: 400, height: 300)
        .padding()
}
