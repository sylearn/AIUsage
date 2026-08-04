import SwiftUI
import QuotaBackend

struct InboxView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @Environment(\.colorScheme) private var colorScheme
    private var alerts: [Alert] {
        refreshCoordinator.overview?.alerts ?? []
    }

    // 即将重置的 provider
    private var resettingSoon: [ProviderData] {
        refreshCoordinator.providers.filter { p in
            guard let next = p.nextResetAt else { return false }
            guard let date = SharedFormatters.parseISO8601(next) else { return false }
            let diff = date.timeIntervalSinceNow
            return diff > 0 && diff <= 86400
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if alerts.isEmpty && resettingSoon.isEmpty {
                    emptyState
                } else {
                    // 告警
                    if !alerts.isEmpty {
                        sectionHeader(L("Alerts", "告警"), icon: "exclamationmark.triangle.fill", color: .orange) {
                            if appState.unreadAlertCount > 0 {
                                Button(action: { appState.markAllAlertsRead() }) {
                                    Label(L("Mark all read", "全部已读"), systemImage: "checkmark.circle")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }
                        VStack(spacing: 10) {
                            ForEach(alerts) { alert in
                                AlertRow(alert: alert, isRead: appState.readAlertIds.contains(alert.id)) {
                                    appState.markAlertRead(alert.id)
                                }
                            }
                        }
                    }

                    // 即将重置
                    if !resettingSoon.isEmpty {
                        sectionHeader(L("Resetting Soon", "即将重置"), icon: "clock.fill", color: .teal)
                        VStack(spacing: 10) {
                            ForEach(resettingSoon) { p in
                                ResetSoonRow(provider: p)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .appPageChrome(colorScheme)
    }

    private func sectionHeader(_ title: String, icon: String, color: Color, @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.subheadline)
            Text(title)
                .font(.title3)
                .bold()
            Spacer()
            trailing()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "tray.fill")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text(L("All clear", "一切正常"))
                .font(.title2)
                .bold()
                .foregroundStyle(.secondary)
            Text(L("No alerts or notifications right now.", "当前没有任何告警或通知。"))
                .font(.body)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}

// MARK: - Alert Row

struct AlertRow: View {
    let alert: Alert
    let isRead: Bool
    let onMarkRead: () -> Void
    @EnvironmentObject var appState: AppState

    private var color: Color {
        alert.tone == "critical" ? .red : alert.tone == "watch" ? .orange : .blue
    }

    private var icon: String {
        alert.tone == "critical" ? "exclamationmark.triangle.fill" :
        alert.tone == "watch"    ? "exclamationmark.circle.fill" : "info.circle.fill"
    }

    var body: some View {
        HStack(spacing: 12) {
            // 未读圆点（已读后消失）
            Circle()
                .fill(isRead ? Color.clear : color)
                .frame(width: 8, height: 8)

            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(alert.title)
                    .font(.subheadline)
                    .bold()
                Text(alert.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // 已读标识 / 未读时显示标记已读按钮
            if isRead {
                Label(appState.language == "zh" ? "已读" : "Read", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .labelStyle(.iconOnly)
            } else {
                Button(action: onMarkRead) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help(appState.language == "zh" ? "标记为已读" : "Mark as read")
            }

            Text(appState.language == "zh"
                 ? (alert.tone == "critical" ? "告急" : alert.tone == "watch" ? "偏低" : "信息")
                 : (alert.tone == "critical" ? "Critical" : alert.tone == "watch" ? "Watch" : "Info"))
                .font(.caption2)
                .bold()
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color.opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(12)
        .background(color.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.2), lineWidth: 1))
        .animation(.easeInOut(duration: 0.2), value: isRead)
    }
}

// MARK: - Reset Soon Row

struct ResetSoonRow: View {
    let provider: ProviderData

    var body: some View {
        HStack(spacing: 12) {
            ProviderIconView(provider.providerId, size: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 3) {
                Text(provider.label)
                    .font(.subheadline)
                    .bold()
                if let label = provider.nextResetLabel {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.teal)
                .font(.title3)
        }
        .padding(12)
        .background(Color.teal.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.teal.opacity(0.2), lineWidth: 1))
    }
}

#Preview {
    InboxView()
        .environmentObject(AppState.shared)
        .frame(width: 700, height: 600)
}
