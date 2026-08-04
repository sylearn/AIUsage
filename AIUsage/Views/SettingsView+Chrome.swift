import SwiftUI

extension SettingsView {

    func settingsCard<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AppContent.primary(colorScheme))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(AppContent.secondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
        .shadow(color: AppShadow.card(colorScheme), radius: colorScheme == .dark ? 0 : 12, y: 5)
    }

    func settingsBlock<Content: View>(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppContent.primary(colorScheme))

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AppContent.secondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func settingsToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppContent.primary(colorScheme))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AppContent.secondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func settingsValueRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppContent.primary(colorScheme))
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(AppContent.secondary(colorScheme))
        }
    }
}
