import SwiftUI
import QuotaBackend

// MARK: - Multi-Window Quota View
// Codex / Kimi / MiniMax 默认展示两条；Droid Individual 展示 5 小时 / 周 / 月三条。

struct MultiWindowQuotaView: View {
    let windows: [QuotaWindow]
    let accentColor: Color
    var visibleWindowLimit: Int = 2

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    private var displayedWindows: [QuotaWindow] {
        Array(windows.prefix(visibleWindowLimit))
    }

    private var ringSize: CGFloat {
        displayedWindows.count >= 3 ? 52 : 62
    }

    private var ringSpacing: CGFloat {
        displayedWindows.count >= 3 ? 12 : 20
    }

    private func windowLabel(_ label: String) -> String {
        guard appState.language == "zh" else { return label }
        switch label {
        case "5h Window", "5-hour": return "5小时剩余"
        case "Weekly Window", "Weekly": return "7天剩余"
        case "Monthly Window", "Monthly": return "月限额剩余"
        case "Code Review":    return "代码审查"
        case "Rate Limit":     return "频限明细"
        default:               return label
        }
    }

    var body: some View {
        switch settings.quotaIndicatorStyle {
        case .bar:
            barLayout
        case .ring:
            ringLayout
        case .segments:
            segmentsLayout
        }
    }

    // MARK: - Bar Layout

    private var barLayout: some View {
        VStack(spacing: 10) {
            ForEach(displayedWindows) { window in
                MultiWindowBarRow(window: window, label: windowLabel(window.label), accentColor: accentColor)
                    .environmentObject(appState)
                    .environmentObject(settings)
            }
        }
    }

    // MARK: - Ring Layout

    private var ringLayout: some View {
        HStack(spacing: ringSpacing) {
            ForEach(displayedWindows) { window in
                MultiWindowRingItem(
                    window: window,
                    label: windowLabel(window.label),
                    accentColor: accentColor,
                    ringSize: ringSize
                )
                    .environmentObject(appState)
                    .environmentObject(settings)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Segments Layout

    private var segmentsLayout: some View {
        VStack(spacing: 10) {
            ForEach(displayedWindows) { window in
                MultiWindowSegmentsRow(window: window, label: windowLabel(window.label), accentColor: accentColor)
                    .environmentObject(appState)
                    .environmentObject(settings)
            }
        }
    }
}

// MARK: - Bar Row

struct MultiWindowBarRow: View {
    let window: QuotaWindow
    let label: String
    let accentColor: Color

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    private var clampedRemaining: Double {
        min(max(window.remainingPercent ?? 0, 0), 100)
    }

    private var displayPercent: Double {
        settings.quotaIndicatorMetric == .remaining ? clampedRemaining : 100 - clampedRemaining
    }

    private var displayText: String {
        let rounded = (displayPercent * 10).rounded() / 10
        if abs(rounded.rounded() - rounded) < 0.05 {
            return "\(Int(rounded.rounded()))%"
        }
        return String(format: "%.1f%%", rounded)
    }

    private var riskColor: Color {
        switch clampedRemaining {
        case 70...: return Color(red: 0.15, green: 0.78, blue: 0.40)
        case 35...: return Color(red: 0.96, green: 0.64, blue: 0.18)
        default:    return Color(red: 0.92, green: 0.25, blue: 0.28)
        }
    }

    private var gradientColors: [Color] {
        switch clampedRemaining {
        case 70...: return [Color(red: 0.37, green: 0.94, blue: 0.62), Color(red: 0.11, green: 0.74, blue: 0.39)]
        case 35...: return [Color(red: 1.00, green: 0.84, blue: 0.34), Color(red: 0.96, green: 0.56, blue: 0.17)]
        default:    return [Color(red: 1.00, green: 0.54, blue: 0.28), Color(red: 0.90, green: 0.20, blue: 0.29)]
        }
    }

    private var trackColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(displayText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing))

                if let resetText = compactResetText {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(resetText)
                        .font(.caption2)
                        .foregroundStyle(resetHighlightColor)
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(trackColor)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(borderColor, lineWidth: 1))

                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(colors: gradientColors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(geometry.size.width * (displayPercent / 100), displayPercent > 0 ? 8 : 0))
                        .shadow(color: riskColor.opacity(colorScheme == .dark ? 0.28 : 0.12), radius: 6, x: 0, y: 2)
                }
            }
            .frame(height: 8)
        }
    }

    private var compactResetText: String? {
        QuotaResetFormatter.compactText(resetAt: window.resetAt, language: appState.language)
    }

    private var resetHighlightColor: Color {
        QuotaResetFormatter.highlightColor(resetAt: window.resetAt)
    }
}

// MARK: - Ring Item

struct MultiWindowRingItem: View {
    let window: QuotaWindow
    let label: String
    let accentColor: Color
    var ringSize: CGFloat = 62

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    private var clampedRemaining: Double {
        min(max(window.remainingPercent ?? 0, 0), 100)
    }

    private var displayPercent: Double {
        settings.quotaIndicatorMetric == .remaining ? clampedRemaining : 100 - clampedRemaining
    }

    private var displayText: String {
        let rounded = (displayPercent * 10).rounded() / 10
        if abs(rounded.rounded() - rounded) < 0.05 {
            return "\(Int(rounded.rounded()))%"
        }
        return String(format: "%.1f%%", rounded)
    }

    private var gradientColors: [Color] {
        switch clampedRemaining {
        case 70...: return [Color(red: 0.37, green: 0.94, blue: 0.62), Color(red: 0.11, green: 0.74, blue: 0.39)]
        case 35...: return [Color(red: 1.00, green: 0.84, blue: 0.34), Color(red: 0.96, green: 0.56, blue: 0.17)]
        default:    return [Color(red: 1.00, green: 0.54, blue: 0.28), Color(red: 0.90, green: 0.20, blue: 0.29)]
        }
    }

    private var riskColor: Color {
        switch clampedRemaining {
        case 70...: return Color(red: 0.15, green: 0.78, blue: 0.40)
        case 35...: return Color(red: 0.96, green: 0.64, blue: 0.18)
        default:    return Color(red: 0.92, green: 0.25, blue: 0.28)
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(colorScheme == .dark ? 0.08 : 0.06))
                Circle()
                    .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: displayPercent / 100)
                    .stroke(
                        AngularGradient(colors: [
                            gradientColors.first?.opacity(0.45) ?? riskColor.opacity(0.45),
                            gradientColors.first ?? riskColor,
                            gradientColors.last ?? riskColor,
                            gradientColors.last?.opacity(0.45) ?? riskColor.opacity(0.45)
                        ], center: .center),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                Text(displayText)
                    .font(.system(size: ringSize >= 62 ? 15 : 12, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .frame(width: ringSize, height: ringSize)

            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let resetText = compactResetText {
                Text(resetText)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(resetHighlightColor)
            }
        }
    }

    private var compactResetText: String? {
        QuotaResetFormatter.compactText(resetAt: window.resetAt, language: appState.language)
    }

    private var resetHighlightColor: Color {
        QuotaResetFormatter.highlightColor(resetAt: window.resetAt)
    }
}

// MARK: - Segments Row

struct MultiWindowSegmentsRow: View {
    let window: QuotaWindow
    let label: String
    let accentColor: Color

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    private let segmentHeights: [CGFloat] = [10, 13, 17, 22, 28, 32, 32, 28, 22, 17, 13, 10]

    private var clampedRemaining: Double {
        min(max(window.remainingPercent ?? 0, 0), 100)
    }

    private var displayPercent: Double {
        settings.quotaIndicatorMetric == .remaining ? clampedRemaining : 100 - clampedRemaining
    }

    private var displayText: String {
        let rounded = (displayPercent * 10).rounded() / 10
        if abs(rounded.rounded() - rounded) < 0.05 {
            return "\(Int(rounded.rounded()))%"
        }
        return String(format: "%.1f%%", rounded)
    }

    private var gradientColors: [Color] {
        switch clampedRemaining {
        case 70...: return [Color(red: 0.37, green: 0.94, blue: 0.62), Color(red: 0.11, green: 0.74, blue: 0.39)]
        case 35...: return [Color(red: 1.00, green: 0.84, blue: 0.34), Color(red: 0.96, green: 0.56, blue: 0.17)]
        default:    return [Color(red: 1.00, green: 0.54, blue: 0.28), Color(red: 0.90, green: 0.20, blue: 0.29)]
        }
    }

    private var trackColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }

    private var riskColor: Color {
        switch clampedRemaining {
        case 70...: return Color(red: 0.15, green: 0.78, blue: 0.40)
        case 35...: return Color(red: 0.96, green: 0.64, blue: 0.18)
        default:    return Color(red: 0.92, green: 0.25, blue: 0.28)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(displayText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                if let resetText = compactResetText {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(resetText)
                        .font(.caption2)
                        .foregroundStyle(resetHighlightColor)
                }
            }

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(segmentHeights.enumerated()), id: \.offset) { index, height in
                    segmentView(at: index, height: height)
                }
            }
            .frame(height: 36)
        }
    }

    private var compactResetText: String? {
        QuotaResetFormatter.compactText(resetAt: window.resetAt, language: appState.language)
    }

    private var resetHighlightColor: Color {
        QuotaResetFormatter.highlightColor(resetAt: window.resetAt)
    }

    private func segmentView(at index: Int, height: CGFloat) -> some View {
        let ratio = segmentFillRatio(for: index)
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 4)
                .fill(trackColor)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(borderColor, lineWidth: 1))
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: gradientColors, startPoint: .leading, endPoint: .trailing))
                .frame(height: max(height * ratio, ratio > 0 ? 6 : 0))
                .shadow(color: riskColor.opacity(colorScheme == .dark ? 0.2 : 0.08), radius: 3, x: 0, y: 1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .bottom)
    }

    private func segmentFillRatio(for index: Int) -> CGFloat {
        let count = Double(segmentHeights.count)
        let start = (Double(index) / count) * 100
        let end = (Double(index + 1) / count) * 100
        if displayPercent >= end { return 1 }
        if displayPercent <= start { return 0 }
        return CGFloat(min(max((displayPercent - start) / (end - start), 0), 1))
    }
}
