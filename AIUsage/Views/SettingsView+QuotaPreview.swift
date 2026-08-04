import SwiftUI

extension SettingsView {

    var previewRemainingPercent: Double {
        68
    }

    var previewDisplayPercent: Double {
        settings.quotaIndicatorMetric == .remaining ? previewRemainingPercent : 100 - previewRemainingPercent
    }

    var previewValueText: String {
        let rounded = (previewDisplayPercent * 10).rounded() / 10
        if abs(rounded.rounded() - rounded) < 0.05 {
            return "\(Int(rounded.rounded()))%"
        }
        return String(format: "%.1f%%", rounded)
    }

    var quotaIndicatorPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Cursor")
                            .font(.headline)
                            .bold()

                        Text("Pro")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    Text(L("Sample Card", "示例卡片"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(previewValueText)
                        .font(.system(size: 28, weight: .bold, design: .rounded))

                    Text(
                        settings.quotaIndicatorMetric == .remaining
                        ? L("Healthy reserve for the current cycle", "当前周期余量依然充足")
                        : L("Usage is visible without feeling alarming", "使用趋势清晰，但还不紧张")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                QuotaIndicatorView(remainingPercent: previewRemainingPercent, accentColor: .blue)
                    .frame(width: settings.quotaIndicatorStyle == .ring ? 120 : 220)
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
}
