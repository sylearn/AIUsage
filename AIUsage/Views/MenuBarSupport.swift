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
