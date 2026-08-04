import SwiftUI

// MARK: - Proxy Editor Controls
// 四端编辑器（Claude / Codex / OpenCode 代理 + API 提供商）共用的现代化控件，
// 统一替换系统 `.segmented` Picker 与各自的分区/标签写法：
// - CapsuleSegmentedPicker：货币 / 合并策略这类二三选一的胶囊分段。
// - CapsuleInterfacePicker：接口类型胶囊分段 + 随选中变化的一行说明（复用 SelectableCardOption）。
// - EditorCard / EditorFieldLabel：统一的圆角分区卡片与字段标签。
// 同时集中各代理的品牌色，消除各卡片文件里重复定义的颜色常量。

// MARK: - Brand Palette

enum ProxyBrand {
    static let anthropic = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let openAI = Color(red: 0.29, green: 0.73, blue: 0.56)
    static let codex = Color(red: 0.40, green: 0.52, blue: 0.92)
    static let openCode = Color(red: 0.18, green: 0.83, blue: 0.75)
}

// MARK: - Selectable Card Picker

/// 单张可选卡片的数据模型。`Value` 即绑定的选中值（NodeType / OpenCodeProtocol 等）。
struct SelectableCardOption<Value: Hashable>: Identifiable {
    let id: Value
    let title: String
    let subtitle: String?
    let systemImage: String
    let tint: Color

    init(_ id: Value, title: String, subtitle: String? = nil, systemImage: String, tint: Color) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
    }
}

// MARK: - Capsule Segmented Picker

/// 胶囊分段的单项。
struct CapsuleSegmentOption<Value: Hashable>: Identifiable {
    let id: Value
    let title: String

    init(_ id: Value, title: String) {
        self.id = id
        self.title = title
    }
}

/// 药丸轨道 + 选中段实心填充的分段控件，替换 `.segmented` Picker 的二/三选一场景。
/// 默认按内容收紧（不撑满整行）；`fillWidth = true` 时各段等宽铺满。
struct CapsuleSegmentedPicker<Value: Hashable>: View {
    let options: [CapsuleSegmentOption<Value>]
    @Binding var selection: Value
    var tint: Color = .accentColor
    var fillWidth: Bool = false
    var onChange: ((Value) -> Void)? = nil

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options) { option in
                segment(option)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .fixedSize(horizontal: !fillWidth, vertical: false)
        .animation(.easeInOut(duration: 0.15), value: selection)
    }

    private func segment(_ option: CapsuleSegmentOption<Value>) -> some View {
        let isSelected = option.id == selection
        return Button {
            guard selection != option.id else { return }
            selection = option.id
            onChange?(option.id)
        } label: {
            Text(option.title)
                .font(.caption.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, fillWidth ? 4 : 16)
                .frame(maxWidth: fillWidth ? .infinity : nil)
                .padding(.vertical, 6)
                .background(Capsule().fill(isSelected ? tint : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Capsule Interface Picker

/// 「接口类型」专用：胶囊分段（每段一个接口）+ 下方随选中变化的一行说明（图标 + 副标题）。
/// 复用 SelectableCardOption 的数据（标题做段名、副标题做说明、tint 做选中色），
/// 三个代理编辑器与 API 提供商共用，替换原先占高的大卡片，更紧凑、更防过宽。
struct CapsuleInterfacePicker<Value: Hashable>: View {
    let options: [SelectableCardOption<Value>]
    @Binding var selection: Value
    var fillWidth = true
    var onChange: ((Value) -> Void)? = nil

    private var selected: SelectableCardOption<Value>? {
        options.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CapsuleSegmentedPicker(
                options: options.map { CapsuleSegmentOption($0.id, title: $0.title) },
                selection: $selection,
                tint: selected?.tint ?? .accentColor,
                fillWidth: fillWidth,
                onChange: onChange
            )

            if let selected, let subtitle = selected.subtitle {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: selected.systemImage)
                        .font(.caption)
                        .foregroundStyle(selected.tint)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: selection)
    }
}

// MARK: - Editor Section Card

/// 四端编辑器共用的圆角分区卡片（统一视觉：标题 + 圆角浅底容器）。
struct EditorCard<Content: View>: View {
    var title: String?
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    init(_ title: String? = nil, spacing: CGFloat = 12, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let title {
                Text(title).font(.headline.weight(.bold))
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppSurface.card(colorScheme)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppStroke.card(colorScheme), lineWidth: 1))
    }
}

// MARK: - Editor Field Label

/// 四端编辑器共用的字段标签（统一字号/字重，可选必填星号）。
struct EditorFieldLabel: View {
    let title: String
    var required: Bool = false

    init(_ title: String, required: Bool = false) {
        self.title = title
        self.required = required
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if required {
                Text("*")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.red)
            }
        }
    }
}
