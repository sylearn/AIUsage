import SwiftUI

// MARK: - Shared Helpers
// 菜单栏共享的颜色/格式化工具与背景模糊视图。

enum MenuBarHelpers {
    static func quotaColor(_ percent: Double) -> Color {
        if percent >= 70 { return Color(red: 0.15, green: 0.78, blue: 0.40) }
        if percent >= 35 { return Color(red: 0.96, green: 0.64, blue: 0.18) }
        return Color(red: 0.92, green: 0.25, blue: 0.28)
    }

    static func formatCostCompact(_ usd: Double) -> String {
        // 跟随「显示货币」（USD/CNY）并保持紧凑档位，与仪表盘/统计页币种一致。
        formatCurrencyCompact(usd)
    }
}

enum MenuBarColors {
    static func accent(for providerId: String) -> Color {
        switch providerId {
        case "antigravity", "antigravity-cost": return .cyan
        case "copilot": return .blue
        case "claude": return .purple
        case "claude-subscription": return .orange
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
}

// MARK: - Visual Effect Blur

struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Collapsible Section Header

/// 菜单栏可折叠区块的统一标题行（与「最近会话」同款：箭头 + 标题，状态由调用方持久化）。
/// 收起时右侧显示一行摘要，保证关键数字不用展开也能看到。
struct MenuBarCollapsibleHeader<Trailing: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    var collapsedSummary: String? = nil
    var summaryColor: Color = .secondary
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 8)
                    if !isExpanded, let collapsedSummary {
                        Text(collapsedSummary)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(summaryColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}

extension MenuBarCollapsibleHeader where Trailing == EmptyView {
    init(
        title: String,
        isExpanded: Binding<Bool>,
        collapsedSummary: String? = nil,
        summaryColor: Color = .secondary
    ) {
        self.title = title
        self._isExpanded = isExpanded
        self.collapsedSummary = collapsedSummary
        self.summaryColor = summaryColor
        self.trailing = { EmptyView() }
    }
}
