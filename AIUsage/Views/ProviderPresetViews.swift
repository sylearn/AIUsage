import AppKit
import SwiftUI

// MARK: - Provider Preset Views
// 「快速接入」卡片（四个新建编辑器共用）与侧边栏合作推荐位。
// 设计原则：
// - 只在「新建」时出现；默认选中「自定义」，不替用户做决定；
// - 赞助内容明确标注，并说明通过它注册对用户价格没有影响；
// - 推荐位低对比、单行信息、悬停才强调，可随时右键关闭。

// MARK: - Logo

struct ProviderPresetLogo: View {
    let preset: ProviderPreset
    var size: CGFloat = 28

    var body: some View {
        Group {
            if NSImage(named: preset.logoAsset) != nil {
                Image(preset.logoAsset)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                // 忘了放 logo 时的兜底：品牌色首字母，不留空洞。
                ZStack {
                    preset.brandColor.opacity(0.16)
                    Text(String(preset.name.prefix(1)))
                        .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
                        .foregroundStyle(preset.brandColor)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }
}

// MARK: - Sponsor Badge

struct SponsorBadge: View {
    var tint: Color = .secondary

    var body: some View {
        Text(L("Sponsor", "赞助"))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(0.12)))
            .accessibilityLabel(L("Sponsored", "赞助推荐"))
    }
}

// MARK: - Quick Setup Card

/// 新建节点 / 提供商时的「快速接入」：选服务商 → 地址自动填好 → 粘贴 Key → 一键获取模型和价格。
struct ProviderPresetQuickSetup: View {
    /// 选中「获取模型和价格」时需要的上下文；nil 时不显示该按钮。
    struct FetchContext {
        let state: ModelFetchState
        let baseURL: String
        let style: ModelListEndpointStyle
        var summary: String?
    }

    @Binding var selectedID: String?
    @Binding var apiKey: String
    var presets: [ProviderPreset] = ProviderPresetCatalog.all
    /// 当前自动填入的地址与接口说明，如「https://api-models.com · Anthropic」。
    var endpointSummary: String?
    var fetch: FetchContext?
    /// 选中预设（nil = 自定义）后由编辑器写入各自的字段。
    let onSelect: (ProviderPreset?) -> Void

    @State private var hoveredID: String?
    @Environment(\.openURL) private var openURL

    private static let customID = "__custom__"
    private var selected: ProviderPreset? { presets.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.badge.checkmark")
                        .foregroundStyle(.teal)
                    Text(L("Quick Setup", "快速接入"))
                        .font(.headline.weight(.bold))
                }
                Text(L(
                    "Pick a provider and the address is filled in. Just paste your API key.",
                    "选择服务商即可自动填好地址，只需粘贴 API Key。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                ForEach(presets) { preset in
                    presetTile(preset)
                }
                customTile
            }

            if let selected {
                selectedPanel(selected)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if presets.contains(where: \.isSponsored) {
                Text(L(
                    "Providers marked “Sponsor” support AIUsage development when you sign up through them. Your price stays the same.",
                    "标有「赞助」的服务商为合作推荐：通过这里注册可以支持 AIUsage 持续开发，你的价格不受影响。"
                ))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selectedID)
    }

    // MARK: Tiles

    private func presetTile(_ preset: ProviderPreset) -> some View {
        let isSelected = selectedID == preset.id
        return tileShell(id: preset.id, isSelected: isSelected, tint: preset.brandColor) {
            selectedID = preset.id
            onSelect(preset)
        } content: {
            ProviderPresetLogo(preset: preset, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(preset.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if preset.isSponsored {
                        SponsorBadge(tint: preset.brandColor)
                    }
                }
                Text(preset.tagline.localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help(preset.detail.localized)
    }

    private var customTile: some View {
        tileShell(id: Self.customID, isSelected: selectedID == nil, tint: .teal) {
            selectedID = nil
            onSelect(nil)
        } content: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Custom", "自定义"))
                    .font(.system(size: 13, weight: .semibold))
                Text(L("Enter the Base URL yourself", "手动填写 Base URL"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func tileShell<Content: View>(
        id: String,
        isSelected: Bool,
        tint: Color,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isHovered = hoveredID == id
        return Button(action: action) {
            HStack(spacing: 10) {
                content()
                Spacer(minLength: 4)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? tint : Color.secondary.opacity(0.35))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected
                          ? tint.opacity(0.09)
                          : Color.primary.opacity(isHovered ? 0.05 : 0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? tint.opacity(0.55) : Color.primary.opacity(isHovered ? 0.14 : 0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredID = hovering ? id : (hoveredID == id ? nil : hoveredID)
        }
    }

    // MARK: Selected Panel

    private func selectedPanel(_ preset: ProviderPreset) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("API Key")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                linkButton(L("Get API Key", "获取 API Key"), url: preset.apiKeyURL(campaign: "quick-setup"), tint: preset.brandColor)
                linkButton(L("Sign Up", "注册账号"), url: preset.signupURL(campaign: "quick-setup"), tint: .secondary)
            }

            SecureKeyField(L("Paste your \(preset.name) key", "粘贴 \(preset.name) 的 Key"), text: $apiKey)

            if let endpointSummary {
                Label(endpointSummary, systemImage: "link")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let fetch {
                ModelFetchControls(
                    state: fetch.state,
                    baseURL: fetch.baseURL,
                    apiKey: apiKey,
                    style: fetch.style,
                    requiresAPIKey: true,
                    resultSummary: fetch.summary
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(preset.brandColor.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(preset.brandColor.opacity(0.18), lineWidth: 1)
        )
    }

    private func linkButton(_ title: String, url: URL, tint: Color) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
    }
}

// MARK: - Sidebar Sponsor Spot

/// 侧边栏左下角的合作推荐位：两行小字、低对比底色，悬停时才显出品牌色与跳转箭头。
/// 卡片上不写「赞助」字样，保持安静；赞助说明放在悬停提示与无障碍标签里，保持透明。
struct SidebarSponsorSpot: View {
    let preset: ProviderPreset
    let onHide: () -> Void

    @State private var isHovered = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(preset.promoURL(campaign: "sidebar"))
        } label: {
            HStack(spacing: 8) {
                ProviderPresetLogo(preset: preset, size: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(preset.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isHovered ? AnyShapeStyle(preset.brandColor) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    Text(preset.tagline.localized)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            // 箭头浮在右侧而不占布局：侧边栏最窄时第二行文案也能完整显示，悬停时文字不跳动。
            .overlay(alignment: .trailing) {
                if isHovered {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(preset.brandColor)
                        .padding(.trailing, 9)
                        .transition(.opacity)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHovered ? preset.brandColor.opacity(0.10) : Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isHovered ? preset.brandColor.opacity(0.28) : Color.primary.opacity(0.06),
                        lineWidth: 0.5
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .help(L(
            "\(preset.detail.en)\nSponsored · signing up here supports AIUsage.",
            "\(preset.detail.zh)\n赞助推荐 · 通过这里注册可以支持 AIUsage。"
        ))
        .contextMenu {
            Button {
                openURL(preset.promoURL(campaign: "sidebar"))
            } label: {
                Label(L("Visit \(preset.name)", "访问 \(preset.name)"), systemImage: "safari")
            }
            Button {
                openURL(preset.apiKeyURL(campaign: "sidebar"))
            } label: {
                Label(L("Get API Key", "获取 API Key"), systemImage: "key")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(preset.promoURL(campaign: "sidebar-share").absoluteString, forType: .string)
            } label: {
                Label(L("Copy Link", "复制链接"), systemImage: "link")
            }
            Divider()
            Button(action: onHide) {
                Label(L("Hide Recommendation", "隐藏推荐"), systemImage: "eye.slash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L(
            "Sponsored: \(preset.name), \(preset.tagline.en)",
            "赞助推荐：\(preset.name)，\(preset.tagline.zh)"
        ))
    }
}
