import SwiftUI
import os.log
import QuotaBackend

// MARK: - Local Settings Editor View
// In-app editor for a live JSON config file (syntax highlighting via JSONRawEditorView).
// 默认指向 ~/.claude/settings.json（Claude 页），其他页（如 OpenCode 的
// OpenCode 受管层）通过参数复用同一查看/编辑体验。

private let localSettingsLog = Logger(subsystem: "com.aiusage.desktop", category: "LocalSettingsEditor")

struct LocalSettingsEditorView: View {
    @Environment(\.dismiss) private var dismiss

    /// 要编辑的 JSON 文件绝对路径。
    var filePath: String = LocalSettingsEditorView.claudeSettingsPath
    /// 头部展示的文件名（默认按 home 缩写）。
    var displayTitle: String = "~/.claude/settings.json"
    var subtitle: String = L("Live configuration file for Claude Code", "Claude Code 当前生效的配置文件")
    /// 保存成功后通知拥有者刷新其配置真相源状态（例如 OpenCode 的接管哈希）。
    var onSaved: (() -> Void)? = nil

    @State private var jsonText = ""
    @State private var jsonError: String?
    @State private var hasUnsavedChanges = false
    @State private var showSaveSuccess = false
    @State private var isLoadingFile = false

    static var claudeSettingsPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".claude/settings.json")
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            JSONRawEditorView(jsonText: $jsonText, error: $jsonError)
                .onChange(of: jsonText) { _, _ in
                    guard !isLoadingFile else { return }
                    hasUnsavedChanges = true
                    showSaveSuccess = false
                }
            Divider()
            footerBar
        }
        .frame(minWidth: 600, idealWidth: 700, minHeight: 500, idealHeight: 600)
        .onAppear { loadFile() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 14))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text(subtitle)
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
                saveFile()
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

    // MARK: - File I/O

    private func loadFile() {
        isLoadingFile = true
        let path = filePath
        guard let data = FileManager.default.contents(atPath: path) else {
            jsonText = "{\n  \n}"
            hasUnsavedChanges = false
            DispatchQueue.main.async { isLoadingFile = false }
            return
        }
        if filePath.hasSuffix(".jsonc") {
            jsonText = String(data: data, encoding: .utf8) ?? "{}"
        } else if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(
               withJSONObject: obj,
               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
           ), let str = String(data: pretty, encoding: .utf8) {
            jsonText = str
        } else {
            jsonText = String(data: data, encoding: .utf8) ?? "{}"
        }
        hasUnsavedChanges = false
        DispatchQueue.main.async { isLoadingFile = false }
    }

    private func saveFile() {
        guard let data = jsonText.data(using: .utf8) else {
            jsonError = L("Invalid text encoding", "文本编码无效")
            return
        }
        do {
            if filePath.hasSuffix(".jsonc") {
                guard JSONCEditor.parseObject(jsonText) != nil else {
                    jsonError = L("Root must be a valid JSONC object", "根节点必须是有效的 JSONC 对象")
                    return
                }
                try persist(data)
            } else if let strict = try? JSONSerialization.jsonObject(with: data) {
                // 纯 JSON：沿用「美化 + 排序」写盘（如 ~/.claude/settings.json）。
                guard strict is [String: Any] else {
                    jsonError = L("Root must be a JSON object", "根节点必须是 JSON 对象")
                    return
                }
                let prettyData = try JSONSerialization.data(
                    withJSONObject: strict,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                )
                try persist(prettyData)
            } else {
                jsonError = L("Root must be a valid JSON object", "根节点必须是有效的 JSON 对象")
                return
            }
            markSaved()
            onSaved?()
        } catch {
            jsonError = error.localizedDescription
        }
    }

    private func persist(_ data: Data) throws {
        let path = filePath
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        localSettingsLog.info("\((path as NSString).lastPathComponent, privacy: .public) saved via local editor")
    }

    private func markSaved() {
        jsonError = nil
        hasUnsavedChanges = false
        withAnimation(.easeInOut(duration: 0.25)) { showSaveSuccess = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeOut(duration: 0.3)) { showSaveSuccess = false }
        }
    }
}
