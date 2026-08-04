import SwiftUI

// MARK: - Dashboard Card (used by DashboardView)

struct CostTrackingCard: View {
    let provider: ProviderData

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @State private var showingDetail = false
    @Environment(\.colorScheme) private var colorScheme

    private var color: Color {
        switch provider.providerId {
        case "claude": return .orange
        case "codex-cost": return .indigo
        case "opencode": return Color(red: 0.18, green: 0.83, blue: 0.75)
        default: return .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(color.opacity(colorScheme == .dark ? 0.18 : 0.10))
                        .frame(width: 50, height: 50)
                    ProviderIconView(provider.providerId, size: 26)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.label)
                        .font(.headline.weight(.bold))
                    Text(provider.sourceLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(.secondary)
            }

            Text(provider.costSummary?.month.map { formatCurrency($0.usd) } ?? "—")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            HStack(spacing: 10) {
                dashboardMetric(title: "Today", value: provider.costSummary?.today.map { formatCurrency($0.usd) } ?? "—")
                dashboardMetric(title: "Week", value: provider.costSummary?.week.map { formatCurrency($0.usd) } ?? "—")
                dashboardMetric(title: "Tokens", value: provider.costSummary?.month?.tokens.map { formatCompactNumber(Double($0)) } ?? "—")
            }

            if let refreshTimestamp = refreshCoordinator.accountRefreshDate(for: provider) {
                RefreshableTimeView(
                    date: refreshTimestamp,
                    language: appState.language,
                    font: .caption2,
                    foregroundStyle: .secondary
                )
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(colorScheme == .dark ? color.opacity(0.24) : AppStroke.card(colorScheme), lineWidth: 1)
        )
        .shadow(color: AppShadow.card(colorScheme), radius: colorScheme == .dark ? 0 : 10, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .onTapGesture { showingDetail = true }
        .sheet(isPresented: $showingDetail) {
            ProviderDetailView(provider: provider)
        }
    }

    private func dashboardMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(colorScheme == .dark ? 0.12 : 0.08))
        )
    }
}
