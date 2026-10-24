import SwiftUI

struct ProviderIconView: View {
    let providerId: String
    let size: CGFloat

    init(_ providerId: String, size: CGFloat = 32) {
        self.providerId = providerId
        self.size = size
    }

    /// 服务商别名 → 品牌图片。主界面与菜单栏共用，新增服务商 ID 只需在这里登记。
    static func assetName(for providerId: String) -> String {
        switch providerId {
        case "codex", "codex-cost": return "codex"
        case "anthropic", "claude-subscription": return "claude"
        case "gemini-cli": return "gemini"
        case "github-copilot": return "copilot"
        case "antigravity-cost": return "antigravity"
        default: return providerId
        }
    }

    private var assetName: String { Self.assetName(for: providerId) }

    @Environment(\.colorScheme) private var colorScheme

    /// 已按目标点尺寸归一化的 NSImage 缓存（线程安全）。同一 asset+size 的归一化结果跨渲染复用，
    /// 避免每次 body 重算 copy/resize（拖拽等高频重绘场景尤甚）。
    private static let resizedCache = NSCache<NSString, NSImage>()

    private var brandImage: NSImage? {
        let cacheKey = "\(assetName)@\(Int(size.rounded()))" as NSString
        if let cached = Self.resizedCache.object(forKey: cacheKey) { return cached }

        guard let base = NSImage(named: assetName) else { return nil }
        // Normalize the logical size to the requested point size. Some
        // AppKit-backed contexts (notably a `.menuStyle(.borderlessButton)`
        // Menu label) lay out the image using the NSImage's intrinsic size and
        // ignore SwiftUI's `.frame`, which makes raster assets (e.g. 256px PNGs)
        // render enormous. Returning a copy sized to the target keeps every
        // render path constrained to `size` regardless of the asset's pixels.
        guard let normalized = base.copy() as? NSImage else { return base }
        let intrinsic = base.size
        if intrinsic.width > 0, intrinsic.height > 0 {
            let aspect = intrinsic.width / intrinsic.height
            normalized.size = aspect >= 1
                ? NSSize(width: size, height: size / aspect)
                : NSSize(width: size * aspect, height: size)
        } else {
            normalized.size = NSSize(width: size, height: size)
        }
        normalized.isTemplate = base.isTemplate
        Self.resizedCache.setObject(normalized, forKey: cacheKey)
        return normalized
    }

    var body: some View {
        Group {
            if let img = brandImage {
                if img.isTemplate {
                    // 单色品牌标志（如 OpenCode 官方黑白 mark）：强制按模板渲染并用 .primary 着色，
                    // 随系统外观自适应（浅色黑、深色白），避免在深色菜单里渲染成纯黑而不可见。
                    Image(nsImage: img)
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(.primary)
                } else {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            } else {
                Image(systemName: fallbackSymbol)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(accentColor)
                    .padding(size * 0.2)
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }

    private var fallbackSymbol: String {
        switch providerId {
        case "antigravity", "antigravity-cost": return "atom"
        case "copilot": return "chevron.left.forwardslash.chevron.right"
        case "claude", "claude-subscription": return "sparkles"
        case "claude-science": return "atom"
        case "cursor":  return "cursorarrow.rays"
        case "gemini":  return "star.fill"
        case "kimi":    return "moon.stars.fill"
        case "kiro":    return "cloud.fill"
        case "codex", "codex-cost": return "brain.head.profile"
        case "droid":   return "cpu"
        case "minimax": return "m.circle.fill"
        case "opencode": return "terminal.fill"
        case "warp":    return "terminal"
        case "xai":     return "xmark"
        case "vertex":  return "triangle.3.layers.3d"
        case "qwen":    return "cloud.fill"
        case "iflow":   return "arrow.triangle.branch"
        default:        return "cube.fill"
        }
    }

    private var accentColor: Color {
        switch providerId {
        case "antigravity", "antigravity-cost": return .cyan
        case "copilot": return .blue
        case "claude":  return .purple
        case "claude-subscription": return .orange
        case "claude-science": return .purple
        case "cursor":  return .green
        case "gemini":  return .orange
        case "kimi":    return Color(red: 0.09, green: 0.51, blue: 1.0)
        case "kiro":    return .purple
        case "codex", "codex-cost": return .indigo
        case "droid":   return .yellow
        case "minimax": return Color(red: 0.886, green: 0.087, blue: 0.494)
        case "opencode": return Color(red: 0.18, green: 0.83, blue: 0.75)
        case "warp":    return .pink
        case "xai":     return .primary
        case "vertex":  return .blue
        case "qwen":    return .purple
        case "iflow":   return .cyan
        default:        return .gray
        }
    }
}

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
