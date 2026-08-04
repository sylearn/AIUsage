import SwiftUI

// MARK: - Dashboard State Cards
// 仪表盘各种「状态卡」：告警条、骨架占位、加载中账号卡、未连接引导卡。
// 从 DashboardView 拆出以控制单文件规模；均为纯展示型组件。

// MARK: - Alert Banner Component

struct AlertBanner: View {
    let alert: Alert

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundColor(alertColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(alert.title)
                    .font(.headline)

                Text(alert.body)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(alertColor.opacity(0.1))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(alertColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var alertColor: Color {
        switch alert.tone {
        case "critical": return .red
        case "watch": return .orange
        default: return .blue
        }
    }

    private var iconName: String {
        switch alert.tone {
        case "critical": return "exclamationmark.triangle.fill"
        case "watch": return "exclamationmark.circle.fill"
        default: return "info.circle.fill"
        }
    }
}

// MARK: - Skeleton Components

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: max(0, phase - 0.3)),
                        .init(color: .white.opacity(0.12), location: phase),
                        .init(color: .clear, location: min(1, phase + 0.3))
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blendMode(.screen)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    phase = 2
                }
            }
    }
}

private extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

struct SkeletonPill: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2)
            .fill(Color.primary.opacity(0.06))
            .frame(width: width, height: height)
            .shimmer()
    }
}

struct SkeletonBlock: View {
    let height: CGFloat
    var cornerRadius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.primary.opacity(0.05))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .shimmer()
    }
}

// MARK: - Loading Account Card
// 首次刷新还没拿到 live 数据时，已知账号显示「正在获取用量…」占位卡（含骨架/转圈），
// 取代 SavedAccountCard 的「凭证可能已过期」误导态，避免用户以为数据丢失。
struct LoadingAccountCard: View {
    let providerId: String
    let title: String
    let accountLabel: String?
    var account: ProviderAccountEntry? = nil
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var pendingAccountDeletion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ProviderIconView(providerId, size: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .bold()
                }

                Spacer()

                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                    Text(L("Loading", "加载中"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SkeletonPill(width: 120, height: 22)
                SkeletonBlock(height: 10, cornerRadius: 5)
                SkeletonBlock(height: 10, cornerRadius: 5)
                    .padding(.trailing, 40)
            }

            Spacer(minLength: 0)

            HStack {
                if let accountLabel {
                    Label(accountLabel, systemImage: accountIdentityIcon(for: accountLabel))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(L("Fetching latest usage…", "正在获取最新用量…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 148)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
        .contextMenu {
            if let account {
                SubscriptionAccountDestructiveMenuItems(
                    onHide: { appState.hideAccount(account) },
                    onRequestDelete: { pendingAccountDeletion = true }
                )
            }
        }
        .subscriptionAccountDeleteConfirmation(isPresented: $pendingAccountDeletion) {
            if let account {
                appState.deleteAccount(account)
            }
        }
    }
}

// MARK: - Needs Connection Card
// 凭证型服务商已勾选但还没连接（缺 Key / 未登录）时显示的引导卡：
// 用中性的「未连接」措辞 + 主操作按钮，避免 SavedAccountCard / 错误卡的「采集失败」误导。
struct NeedsConnectionCard: View {
    let providerId: String
    let title: String
    let accountLabel: String?
    let onConnect: () -> Void
    var account: ProviderAccountEntry? = nil
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var pendingAccountDeletion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ProviderIconView(providerId, size: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .bold()
                }

                Spacer()

                Text(L("Not connected", "未连接"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.10))
                    .clipShape(Capsule())
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Connect to start tracking", "连接后即可监控"))
                    .font(.title3)
                    .bold()
                Text(L(
                    "Connect this account to see live quota and usage here.",
                    "连接该账号后，就能在这里看到实时额度与用量。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                if let accountLabel {
                    Label(accountLabel, systemImage: accountIdentityIcon(for: accountLabel))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: onConnect) {
                    Label(L("Connect account", "连接账号"), systemImage: "link.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .frame(minHeight: 148)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
        .contextMenu {
            Button(action: onConnect) {
                Label(L("Connect account", "连接账号"), systemImage: "link.badge.plus")
            }
            if let account {
                SubscriptionAccountDestructiveMenuItems(
                    onHide: { appState.hideAccount(account) },
                    onRequestDelete: { pendingAccountDeletion = true }
                )
            }
        }
        .subscriptionAccountDeleteConfirmation(isPresented: $pendingAccountDeletion) {
            if let account {
                appState.deleteAccount(account)
            }
        }
    }
}
