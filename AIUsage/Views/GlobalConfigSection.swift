import SwiftUI
import os.log

// MARK: - Global Config Section
// Compact card with toggle and edit button. Clicking edit opens a sheet
// with a full JSON editor for the shared settings.json fragment.

private let globalConfigLog = Logger(subsystem: "com.aiusage.desktop", category: "GlobalConfig")

struct GlobalConfigSection: View {
    @EnvironmentObject var viewModel: ProxyViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingEditor = false

    private var store: NodeProfileStore { viewModel.profileStore }
    private var keyCount: Int { store.globalConfig.settings.count }

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
            GlobalConfigEditorView(store: store)
        }
    }
}

// MARK: - Global Config Editor View (Sheet)

private struct GlobalConfigEditorView: View {
    let store: NodeProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var jsonText = ""
    @State private var jsonError: String?
    @State private var hasUnsavedChanges = false
    @State private var showSaveSuccess = false
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            JSONRawEditorView(jsonText: $jsonText, error: $jsonError)
                .onChange(of: jsonText) { _ in
                    guard !isLoading else { return }
                    hasUnsavedChanges = true
                    showSaveSuccess = false
                }
            Divider()
            footerBar
        }
        .frame(minWidth: 600, idealWidth: 700, minHeight: 500, idealHeight: 600)
        .onAppear { loadFromStore() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 14))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Common Config", "通用配置"))
                    .font(.system(size: 13, weight: .semibold))
                Text(L(
                    "Shared fragment merged into settings.json on activation. Node values override.",
                    "激活节点时合并写入 settings.json，节点配置优先级更高。"
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if showSaveSuccess {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(L("Saved", "已保存"))
                        .foregroundStyle(.green)
                }
                .font(.caption.weight(.medium))
                .transition(.opacity)
            }

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

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Text(L("Close", "关闭"))
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

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

    // MARK: - Persistence

    private func loadFromStore() {
        isLoading = true
        let settings = store.globalConfig.settings
        if settings.isEmpty {
            jsonText = "{\n  \n}"
        } else if let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let str = String(data: data, encoding: .utf8) {
            jsonText = str
        }
        hasUnsavedChanges = false
        DispatchQueue.main.async { isLoading = false }
    }

    private func saveToStore() {
        guard let data = jsonText.data(using: .utf8) else {
            jsonError = L("Invalid text encoding", "文本编码无效")
            return
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data)
            guard let dict = obj as? [String: Any] else {
                jsonError = L("Root must be a JSON object", "根节点必须是 JSON 对象")
                return
            }
            store.globalConfig.settings = dict
            store.saveGlobalConfig()
            jsonError = nil
            hasUnsavedChanges = false
            withAnimation(.easeInOut(duration: 0.25)) { showSaveSuccess = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeOut(duration: 0.3)) { showSaveSuccess = false }
            }
            globalConfigLog.info("Global config saved")
        } catch {
            jsonError = error.localizedDescription
        }
    }
}
