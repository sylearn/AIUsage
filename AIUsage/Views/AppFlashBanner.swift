import AppKit
import SwiftUI

// MARK: - App Flash Banner
// 顶部轻横幅反馈（成功 / 提示 / 失败），与 API 提供商列表同款交互：
// 顶栏滑入 + 约 2.4s 自动消失，不打断当前操作流。

struct AppFlash: Equatable, Identifiable {
    enum Kind: Equatable {
        case success
        case error
        case info
    }

    let id = UUID()
    let kind: Kind
    let message: String

    static func success(_ message: String) -> AppFlash { .init(kind: .success, message: message) }
    static func error(_ message: String) -> AppFlash { .init(kind: .error, message: message) }
    static func info(_ message: String) -> AppFlash { .init(kind: .info, message: message) }
}

struct AppFlashBanner: View {
    let flash: AppFlash
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
            Text(flash.message)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppContent.primary(colorScheme))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(bannerBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tint.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.14), radius: 12, y: 5)
    }

    private var bannerBackground: Color {
        switch colorScheme {
        case .dark:
            return Color(nsColor: .controlBackgroundColor).opacity(0.96)
        case .light:
            fallthrough
        @unknown default:
            return AppSurface.elevated(colorScheme)
        }
    }

    private var icon: String {
        switch flash.kind {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var tint: Color {
        switch flash.kind {
        case .success: return .green
        case .error: return .orange
        case .info: return .accentColor
        }
    }
}

extension View {
    /// 顶部浮层 + 弹簧动画；`flash` 由调用方在约 2.4s 后清空。
    func appFlashOverlay(_ flash: AppFlash?) -> some View {
        overlay(alignment: .top) {
            if let flash {
                AppFlashBanner(flash: flash)
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: flash)
    }
}

@MainActor
enum AppFlashPresenter {
    static func present(
        _ flash: AppFlash,
        into binding: Binding<AppFlash?>,
        durationNanoseconds: UInt64 = 2_400_000_000
    ) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            binding.wrappedValue = flash
        }
        let token = flash.id
        Task {
            try? await Task.sleep(nanoseconds: durationNanoseconds)
            await MainActor.run {
                guard binding.wrappedValue?.id == token else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    binding.wrappedValue = nil
                }
            }
        }
    }
}
