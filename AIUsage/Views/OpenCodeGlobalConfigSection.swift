import SwiftUI

// MARK: - OpenCode Global Config Section
// 节点列表上方的「通用配置」卡片（与 Claude 页 GlobalConfigSection 同款视觉）：
// 开关 + 编辑按钮，编辑打开语法高亮 JSON 编辑器。
// 片段在激活节点时深合并进当前 OpenCode 全局配置文件（用户原文 ← 通用配置 ← 受管块），
// 节点可用合并策略（跟随全局/始终合并/从不合并）覆盖全局开关。

struct OpenCodeGlobalConfigSection: View {
    @ObservedObject var store: OpenCodeNodeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingEditor = false

    private var keyCount: Int { store.globalConfig.settings.count }
    private var targetFileName: String { store.configFileName }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 14))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(L("Common Config", "通用配置"))
                    .font(.subheadline.weight(.semibold))
                Text(keyCount > 0
                     ? L("\(keyCount) top-level keys", "\(keyCount) 个顶层字段")
                     : L("Not configured", "未配置"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showingEditor = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 10, weight: .semibold))
                    Text(L("Edit", "编辑"))
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)

            Toggle(isOn: Binding(
                get: { store.globalConfig.enabled },
                set: { newValue in
                    store.globalConfig.enabled = newValue
                    store.saveGlobalConfig()
                }
            )) {
                Text(L("Merge", "合并"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
        .sheet(isPresented: $showingEditor) {
            OpenCodeGlobalConfigEditorView(store: store)
        }
    }
}

// MARK: - Editor Sheet

private struct OpenCodeGlobalConfigEditorView: View {
    let store: OpenCodeNodeStore
    @Environment(\.dismiss) private var dismiss
    @State private var jsonText = ""
    @State private var jsonError: String?
    @State private var hasUnsavedChanges = false
    @State private var isLoading = false

    private var targetFileName: String { store.configFileName }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            JSONRawEditorView(jsonText: $jsonText, error: $jsonError, title: L("Common fragment", "通用配置片段"))
                .onChange(of: jsonText) { _, _ in
                    guard !isLoading else { return }
                    hasUnsavedChanges = true
                }
            Divider()
            footerBar
        }
        .frame(minWidth: 600, idealWidth: 700, minHeight: 500, idealHeight: 600)
        .onAppear { loadFromStore() }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 14))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Common Config", "通用配置"))
                    .font(.system(size: 13, weight: .semibold))
                Text(L(
                    "AIUsage fragment merged into \(targetFileName) on activation (your config ← common ← managed node block).",
                    "激活节点时，AIUsage 片段会合并进 \(targetFileName)（用户配置 ← 通用配置 ← 受管节点块）。"
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                if !store.lowerPriorityConfigFileNames.isEmpty {
                    let lower = store.lowerPriorityConfigFileNames.joined(separator: ", ")
                    Text(L(
                        "Also merged before \(targetFileName): \(lower). Later keys override earlier keys.",
                        "\(targetFileName) 之前还会合并：\(lower)。同名字段以后加载的配置为准。"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if let custom = store.customConfigPath {
                    Text(L(
                        "OPENCODE_CONFIG adds \(custom) after the global layers for launches that set it.",
                        "设置 OPENCODE_CONFIG 的启动会在全局配置层之后再合并 \(custom)。"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
                if let directory = store.customConfigDirectory {
                    Text(L(
                        "OPENCODE_CONFIG_DIR adds config from \(directory) later; AIUsage manages the global layer above.",
                        "OPENCODE_CONFIG_DIR 会在后续追加 \(directory) 中的配置；AIUsage 管理的是上面的全局配置层。"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
                if store.hasInlineConfigContent {
                    Text(L(
                        store.inlineConfigContentIsInvalid
                            ? "OPENCODE_CONFIG_CONTENT is present but invalid."
                            : "OPENCODE_CONFIG_CONTENT adds an inline configuration layer last.",
                        store.inlineConfigContentIsInvalid
                            ? "OPENCODE_CONFIG_CONTENT 已设置，但内容无法解析。"
                            : "OPENCODE_CONFIG_CONTENT 会在最后追加一层内联配置。"
                    ))
                    .font(.caption2)
                    .foregroundStyle(store.inlineConfigContentIsInvalid ? Color.red : Color.orange)
                }
            }
            Spacer()
            if hasUnsavedChanges {
                Text(L("Unsaved", "未保存"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var footerBar: some View {
        HStack {
            Button(L("Close", "关闭")) { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 6)

            Spacer()

            Button {
                saveToStore()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                    Text(L("Save", "保存"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(!hasUnsavedChanges || jsonError != nil)
            .opacity(hasUnsavedChanges && jsonError == nil ? 1 : 0.5)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func loadFromStore() {
        isLoading = true
        let settings = store.globalConfig.settings
        if settings.isEmpty {
            jsonText = "{\n  \n}"
        } else {
            jsonText = OpenCodeConfigManager.jsonString(settings)
        }
        hasUnsavedChanges = false
        DispatchQueue.main.async { isLoading = false }
    }

    private func saveToStore() {
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            jsonError = L("Root must be a JSON object", "根节点必须是 JSON 对象")
            return
        }
        store.globalConfig.settings = dict
        store.saveGlobalConfig()
        jsonError = nil
        hasUnsavedChanges = false
        dismiss()
    }
}
