import SwiftUI
import Combine
import QuotaBackend

/// 所有积分入口共用文案，明确区分数值、可用标记和未返回数据。
@MainActor
enum CodexCreditsText {
    static func full(_ value: String?) -> String {
        switch value {
        case nil: return L("Not provided", "未提供")
        case "Available", "可用": return L("Available · amount not provided", "可用 · 数额未提供")
        case "No available credits", "无可用积分": return L("No available credits", "无可用积分")
        default: return value ?? L("Not provided", "未提供")
        }
    }
    static func compact(_ value: String?) -> String {
        let text = full(value)
        for suffix in [" credits", " 积分"] where text.hasSuffix(suffix) {
            return String(text.dropLast(suffix.count))
        }
        return text
    }
}

/// 积分余额独立于配额百分比与重置卡，不额外发送请求。
struct CodexCreditsBalanceView: View {
    let value: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "creditcard")
                .font(.system(size: 11, weight: .medium))
                .accessibilityHidden(true)
            Text(L("Credit balance", "积分余额"))
                .font(.caption)
            Spacer(minLength: 8)
            Text(CodexCreditsText.full(value))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(AppContent.secondary(colorScheme))
        .padding(.horizontal, 8)
        .frame(height: 22)
        .accessibilityElement(children: .combine)
        .help(L("The provider may report only availability, without a numeric balance. Missing data is not zero. Credits are separate from reset cards.",
                "上游可能只返回可用标记，不提供具体积分数；缺失数据不等于零。积分独立于重置卡。"))
    }
}

/// 将重置卡状态观察限制在 Codex 入口，避免其他订阅卡片跟随更新。
struct CodexResetCreditsControl: View {
    let target: CodexResetCreditsCoordinator.Target
    let knownCount: Int?
    let summaryFetchedAt: String?
    let refreshUsage: () async -> Bool
    @ObservedObject private var coordinator = CodexResetCreditsCoordinator.shared
    @State private var showingDetails = false

    var body: some View {
        CodexResetCreditsEntry(count: coordinator.availableCount(for: target, summaryCount: knownCount, summaryFetchedAt: summaryFetchedAt)) {
            showingDetails = true
        }
        .popover(isPresented: $showingDetails) {
            CodexResetCreditsView(target: target, knownCount: knownCount, summaryFetchedAt: summaryFetchedAt,
                                  refreshUsage: refreshUsage, coordinator: coordinator)
        }
        .contextMenu {
            Button(L("View / use reset cards…", "查看 / 使用重置卡…")) { showingDetails = true }
        }
    }
}

/// 账号卡片与真实渲染 fixture 共用的紧凑入口；不读取明细、不触发消费。
struct CodexResetCreditsEntry: View {
    let count: Int?
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var hasCards: Bool { (count ?? 0) > 0 }
    private var countText: String { count.map(String.init) ?? "—" }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "ticket")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hasCards ? Color.indigo : AppContent.secondary(colorScheme))
                Text(L("Reset cards", "重置卡"))
                    .font(.caption.weight(.medium))
                Spacer(minLength: 8)
                Text(countText)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(hasCards ? Color.indigo.opacity(0.12) : AppSurface.chip(colorScheme), in: Capsule())
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(AppContent.tertiary(colorScheme))
            }
            .foregroundStyle(AppContent.secondary(colorScheme))
            .padding(.horizontal, 8)
            .frame(height: hasCards ? 26 : 22)
            .background((hasCards ? Color.indigo : Color.primary).opacity(isHovered ? 0.10 : (hasCards ? 0.065 : 0)),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(L("View Codex reset cards", "查看 Codex 重置卡") + " " + (count.map(String.init) ?? L("count unknown", "数量未知")))
        .help(L("View reset cards and expiration dates", "查看重置卡及到期时间"))
    }
}

struct CodexResetCreditsView: View {
    let target: CodexResetCreditsCoordinator.Target
    let knownCount: Int?
    var summaryFetchedAt: String? = nil
    let refreshUsage: () async -> Bool
    @ObservedObject var coordinator: CodexResetCreditsCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedCard: CodexResetCredit?
    @State private var showingConfirmation = false
    @State private var hoveredCreditID: String?

    private var state: CodexResetCreditsCoordinator.State { coordinator.state(for: target) }
    private var busy: Bool { state.isLoading || state.isConsuming || state.isRefreshing }
    private var canOperate: Bool { coordinator.canOperate(target) }
    private var availableCount: Int? {
        coordinator.availableCount(for: target, summaryCount: knownCount, summaryFetchedAt: summaryFetchedAt)
    }
    private var countText: String {
        availableCount.map { L("\($0) available", "\($0) 张可用") } ?? L("Count unknown", "数量未知")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(L("Card details", "卡片明细"))
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    if let list = state.list {
                        Text(L("\(list.credits.count) shown", "显示 \(list.credits.count) 张明细"))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(AppContent.secondary(colorScheme))
                    }
                    if busy { ProgressView().controlSize(.mini).frame(width: 16, height: 16) }
                    Button { Task { await coordinator.load(target) } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppContent.secondary(colorScheme))
                    .disabled(busy || !canOperate)
                    .help(L("Refresh card details only", "仅刷新卡片明细"))
                    .accessibilityLabel(L("Refresh card details", "刷新卡片明细"))
                }
                if let list = state.list, !list.credits.isEmpty {
                    creditList(list.sortedCredits)
                } else {
                    emptyState
                }
            }
            if state.listFailed {
                messageRow("exclamationmark.arrow.circlepath", state.list == nil
                    ? L("Could not load card details. Try refreshing.", "暂时无法读取明细，请刷新重试。")
                    : L("Details could not be refreshed. Last known data is shown.", "明细刷新失败，保留上次数据。"), tint: .orange)
            }
            if let message = feedback {
                messageRow(feedbackIsSuccess ? "checkmark.circle" : "exclamationmark.circle", message,
                           tint: feedbackIsSuccess ? .green : .orange)
            }
            footer
        }
        .padding(16)
        .frame(width: 410)
        .foregroundStyle(AppContent.primary(colorScheme))
        .background(AppSurface.page(colorScheme))
        .task { await coordinator.load(target) }
        .alert(L("Use this reset card?", "确认使用这张重置卡？"), isPresented: $showingConfirmation) {
            Button(L("Cancel", "取消"), role: .cancel) { selectedCard = nil }
            Button(L("Confirm use", "确认使用")) {
                guard let card = selectedCard else { return }
                selectedCard = nil
                Task { await coordinator.confirm(card, for: target, refresh: refreshUsage) }
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: "ticket")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.indigo)
                    .frame(width: 28, height: 28)
                    .background(Color.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(L("Reset cards", "重置卡"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 8)
                GatewayQuietBadge(text: countText)
            }
            HStack(spacing: 6) {
                Text(target.label)
                    .font(.caption)
                    .foregroundStyle(AppContent.secondary(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(target.label)
                if !canOperate { GatewayQuietBadge(text: L("View only", "只读")) }
            }
        }
    }

    private func creditList(_ cards: [CodexResetCredit]) -> some View {
        // 每行 56pt；短列表随内容收缩，超过上限才需要滚动。
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    creditRow(card)
                    if index < cards.count - 1 {
                        Rectangle().fill(AppStroke.subtle(colorScheme)).frame(height: 1).padding(.leading, 40).padding(.trailing, 11)
                    }
                }
            }
        }
        .frame(height: min(CGFloat(cards.count * 56 + max(0, cards.count - 1)), 260))
        .background(AppSurface.card(colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AppStroke.subtle(colorScheme), lineWidth: 1))
    }

    private func creditRow(_ card: CodexResetCredit) -> some View {
        let redeemed = state.redeemedCreditIDs.contains(card.id)
        let usable = coordinator.canConsume(card, for: target)
        let title = card.title?.nilIfBlank ?? L("Codex quota reset", "Codex 额度重置")
        return HStack(spacing: 9) {
            Image(systemName: "ticket")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(usable ? Color.indigo : AppContent.secondary(colorScheme))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(usable ? AppContent.primary(colorScheme) : AppContent.secondary(colorScheme))
                    .lineLimit(1)
                    .help(title)
                Text(expiration(card) + (redeemed ? L(" · Used", " · 已使用") : (!card.canConsume(at: Date()) && (card.hasExplicitUnlimitedExpiry || card.expirationDate != nil) ? L(" · Unavailable", " · 不可使用") : "")))
                    .font(.system(size: 10))
                    .foregroundStyle(usable && expiringSoon(card) ? expiryWarningColor : AppContent.secondary(colorScheme))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(redeemed ? L("Used", "已使用") : L("Use", "使用")) { selectedCard = card; showingConfirmation = true }
                .buttonStyle(CodexResetActionButtonStyle())
                .disabled(busy || !canOperate || !usable)
        }
        .padding(.horizontal, 11)
        .frame(height: 56)
        .background(Color.indigo.opacity(hoveredCreditID == card.id ? 0.04 : 0))
        .onHover { hoveredCreditID = $0 ? card.id : nil }
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: !canOperate ? "lock" : "ticket")
                .font(.system(size: 13))
                .foregroundStyle(AppContent.secondary(colorScheme))
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(emptyTitle).font(.system(size: 12, weight: .medium))
                Text(emptyDetail)
                    .font(.caption2)
                    .foregroundStyle(AppContent.secondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppSurface.card(colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var emptyTitle: String {
        if state.isLoading { return L("Loading cards…", "正在读取卡片…") }
        if availableCount == 0 { return L("No reset cards available", "暂无可用重置卡") }
        if availableCount == nil { return L("Card count is unknown", "重置卡数量未知") }
        return L("No card details yet", "暂无卡片明细")
    }

    private var emptyDetail: String {
        if !canOperate {
            return target.isLocal
                ? L("Connect this account locally to view and use cards.", "在本机连接此账号后，可查看明细并使用。")
                : L("Remote account. Connect locally to view and use cards.", "远程账号，仅供查看；在本机连接后可操作。")
        }
        if state.isLoading { return L("Checking this account's available cards.", "正在核对此账号的可用卡片。") }
        if availableCount == 0 { return L("New cards will appear here when available.", "获得新卡后会显示在这里。") }
        return L("Refresh card details to check availability.", "刷新明细，查看可用卡片。")
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Rectangle().fill(AppStroke.subtle(colorScheme)).frame(height: 1)
            HStack(spacing: 8) {
                Text(L("Only affects this account", "仅作用于此账号"))
                    .font(.caption2)
                    .foregroundStyle(AppContent.secondary(colorScheme))
                Spacer(minLength: 4)
                Button(L("Refresh account", "刷新此账号")) {
                    Task { await coordinator.retryRefresh(target, refresh: refreshUsage) }
                }
                .buttonStyle(CodexResetActionButtonStyle(accented: false))
                .disabled(busy || !canOperate)
                .help(L("Refresh this account's quota and reset cards", "刷新此账号的配额和重置卡"))
            }
        }
    }

    private func messageRow(_ icon: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon).frame(width: 14)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(tint)
    }

    private var confirmationMessage: String {
        let expiry = selectedCard.map { expiration($0) } ?? ""
        let scope = L("Resets this account's Codex quota windows only.", "仅重置此账号的 Codex 配额窗口。")
        return [target.label, expiry, scope].joined(separator: "\n")
    }

    private func expiration(_ card: CodexResetCredit) -> String {
        if card.hasExplicitUnlimitedExpiry { return L("Does not expire", "无到期限制") }
        guard let date = card.expirationDate else { return L("Expiry unknown · Unavailable", "到期时间未知 · 不可使用") }
        return L("Expires ", "到期 ") + date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: L("en_US", "zh_CN")))
        )
    }

    private func expiringSoon(_ card: CodexResetCredit) -> Bool {
        guard let date = card.expirationDate else { return false }
        return date > Date() && date.timeIntervalSinceNow < 7 * 86_400
    }

    private var expiryWarningColor: Color {
        colorScheme == .dark ? .orange : Color(red: 0.64, green: 0.29, blue: 0.025)
    }

    private var feedbackIsSuccess: Bool { state.errorCode == nil && state.outcome?.code == .reset && !state.refreshFailed }

    private var feedback: String? {
        if let code = state.errorCode {
            switch code {
            case "reset_ambiguous":
                return state.refreshedAfterError
                    ? L("Account data refreshed. The previous reset result is still unconfirmed; check quota and card details.", "账号数据已刷新；上次重置结果仍待确认，请核对配额和卡片明细。")
                    : L("Result unconfirmed. Refresh this account to check quota and card details.", "结果待确认，请刷新此账号，核对配额和卡片明细。")
            case "reset_card_unavailable": return L("This card is no longer available. Refresh details.", "此卡已不可使用，请刷新明细。")
            case "reset_journal_failed": return L("Could not save the operation record. No card was submitted.", "无法保存操作记录，未提交卡片。")
            default: return L("Could not submit. Check this account's local connection and refresh details.", "无法提交，请检查此账号的本地连接并刷新明细。")
            }
        }
        guard let outcome = state.outcome else {
            return state.refreshFailed ? L("Account refresh failed. Try again below.", "账号刷新失败，请在下方重试。") : nil
        }
        let result: String
        switch outcome.code {
        case .reset: result = L("Reset succeeded.", "重置成功。")
        case .nothingToReset: result = L("Nothing to reset right now.", "当前无须重置。")
        case .noCredit: result = L("No available credit for this card.", "此卡无可用重置额度。")
        case .alreadyRedeemed: result = L("This card was already used.", "此卡已使用。")
        }
        return result + (state.refreshFailed ? L(" Account refresh failed; retry below.", " 账号刷新失败，可在下方重试。") : "")
    }
}

private struct CodexResetActionButtonStyle: ButtonStyle {
    var accented = true
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isEnabled && accented ? Color.indigo : AppContent.secondary(colorScheme))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(isEnabled && accented ? Color.indigo.opacity(configuration.isPressed ? 0.22 : 0.10) : AppSurface.chip(colorScheme),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// 9router 风格的一键重置卡胶囊按钮（↻ + 可用张数），悬停提示剩余可用张数。
struct CodexQuickResetButton: View {
    let count: Int?
    let enabled: Bool
    var isBusy: Bool = false
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var availableCount: Int { max(0, count ?? 0) }
    private var hasCards: Bool { availableCount > 0 && enabled }
    private var countLabel: String { count.map(String.init) ?? "—" }
    private var tooltip: String {
        if let count {
            return L("Use one Codex reset credit. Available: \(count)", "使用 1 张 Codex 重置卡。可用：\(count)")
        }
        return L("Use one Codex reset credit. Available: unknown", "使用 1 张 Codex 重置卡。可用：未知")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3.5) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 8.5, weight: .semibold))
                Text(countLabel)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(hasCards ? Color.orange : AppContent.secondary(colorScheme))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (hasCards ? Color.orange : Color.primary)
                    .opacity(isHovered && enabled ? 0.18 : (hasCards ? 0.12 : 0.04)),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        hasCards ? Color.orange.opacity(0.55) : AppStroke.subtle(colorScheme),
                        lineWidth: 0.8
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || isBusy)
        .onHover { isHovered = $0 }
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }
}

/// 账号列表与菜单栏共用的余额摘要；明细消费后会立即反映失效计数。
struct CodexAccountBalanceSummary: View {
    let provider: ProviderData
    let target: CodexResetCreditsCoordinator.Target
    var onViewCards: (() -> Void)? = nil
    var onQuickReset: (() -> Void)? = nil
    @ObservedObject private var coordinator = CodexResetCreditsCoordinator.shared

    private var availableCount: Int? {
        coordinator.availableCount(for: target, summaryCount: provider.codexResetCreditsAvailableCount,
                                   summaryFetchedAt: provider.fetchedAt)
    }
    private var countText: String { availableCount.map(String.init) ?? "—" }
    private var creditText: String { CodexCreditsText.compact(provider.codexCreditsDisplayValue) }
    private var state: CodexResetCreditsCoordinator.State { coordinator.state(for: target) }
    private var busy: Bool { state.isLoading || state.isConsuming || state.isRefreshing }
    var body: some View {
        HStack(spacing: 8) {
            if let onViewCards {
                Button(action: onViewCards) {
                    Label(L("Reset cards ", "重置卡 ") + countText, systemImage: "ticket")
                }
                .buttonStyle(.plain)
                .help(L("View / use reset cards", "查看 / 使用重置卡"))
            } else {
                Label(L("Reset cards ", "重置卡 ") + countText, systemImage: "ticket")
            }
            if let quickAction = onQuickReset ?? onViewCards {
                CodexQuickResetButton(
                    count: availableCount,
                    enabled: coordinator.canOperate(target),
                    isBusy: busy,
                    action: quickAction
                )
            }
            Label(L("Credits ", "积分 ") + creditText, systemImage: "creditcard")
                .lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}

/// Shared confirmation/outcome presenter for quick reset actions across main window and menu bar.
@MainActor
final class CodexQuickResetPresenter: ObservableObject {
    @Published var selectedCard: CodexResetCredit?
    @Published var confirmedTarget: CodexResetCreditsCoordinator.Target?
    @Published var showingAlert = false
    @Published var message = ""

    var alertTitle: String {
        selectedCard == nil ? L("Reset cards", "重置卡") : L("Use this reset card?", "确认使用这张重置卡？")
    }

    func cancelSelection() {
        selectedCard = nil
        confirmedTarget = nil
    }

    func prepareReset(
        for target: CodexResetCreditsCoordinator.Target,
        coordinator: CodexResetCreditsCoordinator
    ) async {
        guard let card = await coordinator.prepareEarliestCredit(for: target) else {
            let state = coordinator.state(for: target)
            selectedCard = nil
            confirmedTarget = nil
            message = state.listFailed
                ? L("Could not load fresh card details. No card was submitted.", "无法读取最新卡片明细，未提交使用。")
                : L("No usable reset card is available for this account.", "此账号暂无可使用的重置卡。")
            showingAlert = true
            return
        }
        selectedCard = card
        confirmedTarget = target
        let expiry = card.expirationDate.map { $0.formatted(date: .abbreviated, time: .shortened) }
            ?? L("Does not expire", "无到期限制")
        message = [target.label, L("Expires: ", "到期：") + expiry,
                   L("Resets this account's Codex quota windows only.", "仅重置此账号的 Codex 配额窗口。")].joined(separator: "\n")
        showingAlert = true
    }

    func confirmSelected(
        fallbackTarget: CodexResetCreditsCoordinator.Target,
        coordinator: CodexResetCreditsCoordinator,
        refresh: @escaping () async -> Bool
    ) async {
        guard let card = selectedCard else { return }
        let target = confirmedTarget ?? fallbackTarget
        selectedCard = nil
        confirmedTarget = nil
        await coordinator.confirm(card, for: target, refresh: refresh)
        let state = coordinator.state(for: target)
        if let error = state.errorCode {
            message = error == "reset_ambiguous"
                ? L("Result unconfirmed. Refresh this account to check quota and card details.", "结果待确认，请刷新此账号核对配额和卡片明细。")
                : L("Could not use this card. Refresh this account and try again.", "未能使用此卡，请刷新此账号后重试。")
        } else {
            switch state.outcome?.code {
            case .reset: message = L("Reset succeeded.", "重置成功。")
            case .nothingToReset: message = L("Nothing to reset right now.", "当前无须重置。")
            case .noCredit: message = L("No available credit for this card.", "此卡无可用重置额度。")
            case .alreadyRedeemed: message = L("This card was already used.", "此卡已使用。")
            case nil: message = L("No card was submitted. Refresh this account to check.", "未提交使用，请刷新此账号核对。")
            }
            if state.refreshFailed || state.listFailed {
                message += L(" Some data could not be refreshed; refresh this account to verify.", " 部分数据刷新失败，请刷新此账号核对。")
            }
        }
        showingAlert = true
    }
}

/// Codex 代理页订阅账号的紧凑入口，复用正式卡片明细与定向刷新。
struct CodexSubscriptionBalanceControl: View {
    let provider: ProviderData
    let accountLabel: String
    @EnvironmentObject private var refreshCoordinator: ProviderRefreshCoordinator
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var coordinator = CodexResetCreditsCoordinator.shared
    @StateObject private var quickReset = CodexQuickResetPresenter()
    @State private var showingDetails = false

    private var target: CodexResetCreditsCoordinator.Target {
        .init(identity: CodexAccountIdentity(accountId: provider.accountId, userId: provider.workspaceUserId),
              credentialID: settings.backendMode == "local" ? refreshCoordinator.credentialID(for: provider) : nil,
              label: [accountLabel, provider.workspaceLabel, provider.accountId].compactMap { $0?.nilIfBlank }.joined(separator: " · "),
              isLocal: settings.backendMode == "local")
    }

    private func refreshAccountUsage(for resetTarget: CodexResetCreditsCoordinator.Target) async -> Bool {
        guard let id = resetTarget.credentialID ?? refreshCoordinator.credentialID(for: provider) else { return false }
        return await refreshCoordinator.refreshCodexAccountAfterReset(credentialId: id, identity: resetTarget.identity)
    }

    var body: some View {
        let currentTarget = target
        CodexAccountBalanceSummary(
            provider: provider,
            target: currentTarget,
            onViewCards: { showingDetails = true },
            onQuickReset: {
                Task { await quickReset.prepareReset(for: currentTarget, coordinator: coordinator) }
            }
        )
        .popover(isPresented: $showingDetails) {
            CodexResetCreditsView(
                target: currentTarget,
                knownCount: provider.codexResetCreditsAvailableCount,
                summaryFetchedAt: provider.fetchedAt,
                refreshUsage: { await refreshAccountUsage(for: currentTarget) },
                coordinator: coordinator
            )
        }
        .alert(quickReset.alertTitle, isPresented: $quickReset.showingAlert) {
            if quickReset.selectedCard != nil {
                Button(L("Cancel", "取消"), role: .cancel) { quickReset.cancelSelection() }
                Button(L("Confirm use", "确认使用")) {
                    let activeTarget = quickReset.confirmedTarget ?? currentTarget
                    Task {
                        await quickReset.confirmSelected(
                            fallbackTarget: activeTarget,
                            coordinator: coordinator,
                            refresh: { await refreshAccountUsage(for: activeTarget) }
                        )
                    }
                }
            } else {
                Button(L("OK", "确定"), role: .cancel) {}
            }
        } message: {
            Text(quickReset.message)
        }
    }
}

/// 菜单栏复用同一账号状态和消费流程，常规展示不读取重置卡明细。
struct CodexMenuBarAccountControl<Content: View>: View {
    let provider: ProviderData
    let target: CodexResetCreditsCoordinator.Target
    let pinned: Bool
    let togglePin: () -> Void
    let refreshUsage: () async -> Bool
    @ViewBuilder let content: () -> Content
    @ObservedObject private var coordinator = CodexResetCreditsCoordinator.shared
    @StateObject private var quickReset = CodexQuickResetPresenter()
    @State private var showingDetails = false

    private var state: CodexResetCreditsCoordinator.State { coordinator.state(for: target) }
    private var busy: Bool { state.isLoading || state.isConsuming || state.isRefreshing }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
            HStack(spacing: 10) {
                CodexAccountBalanceSummary(
                    provider: provider,
                    target: target,
                    onViewCards: { showingDetails = true },
                    onQuickReset: { Task { await quickReset.prepareReset(for: target, coordinator: coordinator) } }
                )
                if busy { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .popover(isPresented: $showingDetails) {
            CodexResetCreditsView(
                target: target,
                knownCount: provider.codexResetCreditsAvailableCount,
                summaryFetchedAt: provider.fetchedAt,
                refreshUsage: refreshUsage,
                coordinator: coordinator
            )
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                Task { await quickReset.prepareReset(for: target, coordinator: coordinator) }
            } label: {
                Label(L("Use earliest-expiring reset card…", "使用最早到期的重置卡…"), systemImage: "ticket")
            }
            .disabled(busy || !coordinator.canOperate(target))
            Button {
                Task {
                    await coordinator.retryRefresh(target, refresh: refreshUsage)
                    quickReset.cancelSelection()
                    quickReset.message = state.refreshFailed || state.listFailed
                        ? L("Some account data could not be refreshed. Try again.", "部分账号数据刷新失败，请重试。")
                        : L("Account quota and reset cards refreshed.", "已刷新此账号的配额和重置卡。")
                    quickReset.showingAlert = true
                }
            } label: {
                Label(L("Refresh this account", "刷新此账号"), systemImage: "arrow.clockwise")
            }
            .disabled(busy || !coordinator.canOperate(target))
            Divider()
            Button(action: togglePin) {
                Label(pinned ? L("Unpin from Menu Bar", "从菜单栏取消固定") : L("Pin to Menu Bar", "固定到菜单栏"),
                      systemImage: pinned ? "pin.slash" : "pin")
            }
        }
        .alert(quickReset.alertTitle, isPresented: $quickReset.showingAlert) {
            if quickReset.selectedCard != nil {
                Button(L("Cancel", "取消"), role: .cancel) { quickReset.cancelSelection() }
                Button(L("Confirm use", "确认使用")) {
                    let activeTarget = quickReset.confirmedTarget ?? target
                    Task {
                        await quickReset.confirmSelected(
                            fallbackTarget: activeTarget,
                            coordinator: coordinator,
                            refresh: refreshUsage
                        )
                    }
                }
            } else {
                Button(L("OK", "确定"), role: .cancel) {}
            }
        } message: {
            Text(quickReset.message)
        }
    }
}
