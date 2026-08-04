import SwiftUI
import AppKit

// MARK: - App Surface Tokens
// 全局界面色阶。浅色模式采用低亮度雾蓝灰，降低大面积纯白带来的眩光；
// 深色模式继续沿用系统材质，仅统一表面层级与描边语义。

enum AppSurface {
    /// 页面底：浅色为雾蓝灰工作台，深色用系统窗口底。
    static func page(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color(nsColor: .windowBackgroundColor)
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.941, green: 0.953, blue: 0.969)
        }
    }

    /// 主侧栏与页面内二级导航，比页面底再沉一级。
    static func sidebar(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color(nsColor: .underPageBackgroundColor)
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.902, green: 0.925, blue: 0.953)
        }
    }

    /// 卡片/面板抬升面。
    static func card(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.white.opacity(0.055)
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.982, green: 0.988, blue: 0.996)
        }
    }

    /// 浮层与输入区域；只在需要比卡片再高一级时使用。
    static func elevated(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.white.opacity(0.075)
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.996, green: 0.998, blue: 1.0)
        }
    }

    /// 芯片 / 胶囊 / 轻量行底。
    static func chip(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.primary.opacity(0.08)
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.890, green: 0.918, blue: 0.953)
        }
    }

    /// 告警摘要行、次级列表行。
    static func row(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.primary.opacity(0.04)
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.922, green: 0.941, blue: 0.965)
        }
    }

    /// 工具栏略高于页面底，但不回到刺眼纯白。
    static func toolbar(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return page(scheme)
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.957, green: 0.969, blue: 0.982)
        }
    }

    /// 选中菜单和聚焦区域的低饱和蓝底。
    static func selection(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.accentColor.opacity(0.18)
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.835, green: 0.890, blue: 0.965)
        }
    }
}

enum AppStroke {
    static func card(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.white.opacity(0.10)
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.745, green: 0.788, blue: 0.847)
        }
    }

    static func subtle(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.white.opacity(0.08)
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.816, green: 0.851, blue: 0.898)
        }
    }

    static func strong(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.white.opacity(0.16)
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.655, green: 0.714, blue: 0.792)
        }
    }
}

enum AppContent {
    /// 主标题/正文：浅色加深，避免发灰。
    static func primary(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.primary
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.090, green: 0.129, blue: 0.200)
        }
    }

    /// 次要说明：浅色略深于系统 secondary。
    static func secondary(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.secondary
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.310, green: 0.373, blue: 0.467)
        }
    }

    /// 时间戳等三级信息。
    static func tertiary(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.secondary.opacity(0.85)
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.435, green: 0.498, blue: 0.588)
        }
    }
}

enum AppAccent {
    static func control(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.accentColor
            : Color(red: 0.216, green: 0.408, blue: 0.741)
    }
}

enum AppShadow {
    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.black.opacity(0.22)
            : Color(red: 0.16, green: 0.23, blue: 0.34).opacity(0.08)
    }
}

extension View {
    func appPageBackground(_ scheme: ColorScheme) -> some View {
        background(AppSurface.page(scheme))
    }

    func appPageChrome(_ scheme: ColorScheme) -> some View {
        foregroundStyle(AppContent.primary(scheme))
            .background(AppSurface.page(scheme))
    }
}
