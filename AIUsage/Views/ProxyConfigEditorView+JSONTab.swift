import SwiftUI
import QuotaBackend

// MARK: - ProxyConfigEditorView: JSON / Layered Settings Tab
// 第三个标签页（节点 settings.json + 分层最终配置）的视图与 JSON 同步/分层合并逻辑。
// 从 ProxyConfigEditorView 抽离，控制单文件规模（>800 行必拆分）。
extension ProxyConfigEditorView {
    private var commonConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Common Config", "通用配置"))
                .font(.headline.weight(.bold))

            CapsuleSegmentedPicker(
                options: CommonConfigMode.allCases.map { CapsuleSegmentOption($0, title: $0.label) },
                selection: Binding(
                    get: { profile.metadata.proxy.commonConfigMode ?? .followGlobal },
                    set: {
                        profile.metadata.proxy.commonConfigMode = $0
                        refreshFinalSettingsPreview()
                    }
                )
            )

            Text((profile.metadata.proxy.commonConfigMode ?? .followGlobal).description)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Image(systemName: viewModel.profileStore.globalConfig.enabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(viewModel.profileStore.globalConfig.enabled ? .green : .secondary)
                Text(viewModel.profileStore.globalConfig.enabled
                     ? L("Global common config is enabled.", "全局通用配置已开启。")
                     : L("Global common config is disabled.", "全局通用配置已关闭。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            HStack(spacing: 8) {
                sourceLegend(L("Common", "通用配置"), .blue)
                sourceLegend(L("Node", "节点配置"), .green)
                sourceLegend(L("Override", "节点覆盖"), .orange)
                Spacer()
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppSurface.card(colorScheme)))
    }

    private func sourceLegend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(0.18))
                .frame(width: 22, height: 10)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Tab 3: JSON Editor

    var jsonEditorTab: some View {
        VStack(spacing: 12) {
            commonConfigSection
                .padding(.horizontal, 16)
                .padding(.top, 12)

            HStack(spacing: 12) {
                JSONRawEditorView(
                    jsonText: $jsonText,
                    error: $jsonError,
                    title: L("Node settings.json", "节点 settings.json")
                )

                JSONRawEditorView(
                    jsonText: Binding(
                        get: { finalJSONText.isEmpty ? finalSettingsPreviewText : finalJSONText },
                        set: { applyFinalJSONEdit($0) }
                    ),
                    error: $finalJSONError,
                    title: L("Layered final settings", "分层最终配置"),
                    isEditable: true,
                    showsActions: true,
                    lineMarkers: finalJSONLineMarkers
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .onAppear {
            ensureGlobalDraft()
            refreshFinalSettingsPreview()
        }
        .onChange(of: jsonText) { _, _ in
            guard selectedTab == .json, !isApplyingFinalJSONEdit else { return }
            refreshFinalSettingsPreview()
        }
    }

    private var finalSettingsPreviewText: String {
        let finalSettings = shouldMergeCommonConfig
            ? GlobalConfig.deepMerge(
                base: currentGlobalSettings,
                override: currentNodeSettings
            )
            : currentNodeSettings
        return prettyJSONString(finalSettings)
    }

    private var currentGlobalSettings: [String: Any] {
        globalConfigDraftSettings ?? viewModel.profileStore.globalConfig.settings
    }

    private var currentNodeSettings: [String: Any] {
        parsedJSONSettings(from: jsonText) ?? profile.settings
    }

    private var shouldMergeCommonConfig: Bool {
        profile.metadata.proxy.shouldMergeClaudeCommonConfig(
            globalEnabled: viewModel.profileStore.globalConfig.enabled
        )
    }

    private var finalJSONLineMarkers: [Int: String] {
        lineMarkers(
            for: finalJSONText.isEmpty ? finalSettingsPreviewText : finalJSONText,
            global: currentGlobalSettings,
            node: currentNodeSettings,
            shouldMerge: shouldMergeCommonConfig
        )
    }

    // MARK: - JSON Sync

    func syncToJSON() {
        profile.syncEnvFromProxy()
        jsonText = profile.settingsJSONString
        jsonError = nil
        ensureGlobalDraft()
        refreshFinalSettingsPreview()
    }

    func syncFromJSON() {
        guard let obj = parsedJSONSettings(from: jsonText) else {
            return
        }
        profile.settings = obj
        profile.syncProxyFromSettings()
        refreshFinalSettingsPreview()
    }

    /// Validate JSON, apply to profile, and reverse-sync metadata. Returns false on invalid JSON.
    func validateAndApplyJSON() -> Bool {
        guard let data = jsonText.data(using: .utf8) else {
            jsonError = L("Invalid text encoding", "文本编码无效")
            return false
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data)
            guard let dict = obj as? [String: Any] else {
                jsonError = L("Root must be a JSON object", "根节点必须是 JSON 对象")
                return false
            }
            profile.settings = dict
            profile.syncProxyFromSettings()
            jsonError = nil
            return true
        } catch {
            jsonError = error.localizedDescription
            return false
        }
    }

    private func parsedJSONSettings(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private func ensureGlobalDraft() {
        if globalConfigDraftSettings == nil {
            globalConfigDraftSettings = viewModel.profileStore.globalConfig.settings
        }
    }

    private func refreshFinalSettingsPreview() {
        finalJSONText = finalSettingsPreviewText
        finalJSONError = nil
    }

    private func applyFinalJSONEdit(_ text: String) {
        finalJSONText = text
        guard let finalSettings = parsedJSONSettings(from: text) else {
            finalJSONError = L("Final settings must be valid JSON before it can update common/node config.",
                               "最终配置必须是有效 JSON，才能回写通用配置/节点配置。")
            return
        }

        finalJSONError = nil
        ensureGlobalDraft()
        let split = splitFinalSettingsEdit(
            finalSettings,
            global: currentGlobalSettings,
            node: currentNodeSettings,
            shouldMerge: shouldMergeCommonConfig
        )

        isApplyingFinalJSONEdit = true
        globalConfigDraftSettings = split.global
        jsonText = prettyJSONString(split.node)
        profile.settings = split.node
        profile.syncProxyFromSettings()
        isApplyingFinalJSONEdit = false
    }

    private func prettyJSONString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ),
        let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private enum SettingsSource {
        case common
        case node
        case override

        var marker: String {
            switch self {
            case .common: return "C"
            case .node: return "N"
            case .override: return "O"
            }
        }
    }

    private struct SettingsSourceScope {
        let depth: Int
        let key: String
        let source: SettingsSource
    }

    private func splitFinalSettingsEdit(
        _ finalSettings: [String: Any],
        global: [String: Any],
        node: [String: Any],
        shouldMerge: Bool
    ) -> (global: [String: Any], node: [String: Any]) {
        var nextGlobal = global
        var nextNode = node

        let oldFinal = shouldMerge
            ? GlobalConfig.deepMerge(base: global, override: node)
            : node
        let oldLeaves = flattenedJSONLeaves(oldFinal)
        let newLeaves = flattenedJSONLeaves(finalSettings)

        for path in oldLeaves.keys where newLeaves[path] == nil {
            switch sourceForPath(path, global: global, node: node, shouldMerge: shouldMerge) {
            case .common:
                removeJSONValue(at: path, from: &nextGlobal)
            case .node, .override:
                removeJSONValue(at: path, from: &nextNode)
            }
        }

        for (path, value) in newLeaves {
            let source = oldLeaves[path] == nil
                ? (shouldMerge ? SettingsSource.common : SettingsSource.node)
                : sourceForPath(path, global: global, node: node, shouldMerge: shouldMerge)
            switch source {
            case .common:
                setJSONValue(value, at: path, in: &nextGlobal)
            case .node, .override:
                setJSONValue(value, at: path, in: &nextNode)
            }
        }

        return (nextGlobal, nextNode)
    }

    private func lineMarkers(
        for text: String,
        global: [String: Any],
        node: [String: Any],
        shouldMerge: Bool
    ) -> [Int: String] {
        var markers: [Int: String] = [:]
        var stack: [SettingsSourceScope] = []
        let lines = text.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let indent = line.prefix { $0 == " " }.count
            let depth = max(0, indent / 2)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("}") || trimmed.hasPrefix("]") {
                if let source = stack.last?.source {
                    markers[index + 1] = source.marker
                }
                while let last = stack.last, last.depth >= depth {
                    stack.removeLast()
                }
                continue
            }

            while let last = stack.last, last.depth >= depth {
                stack.removeLast()
            }

            guard let key = jsonKey(in: line) else {
                if let source = stack.last?.source {
                    markers[index + 1] = source.marker
                }
                continue
            }

            let path = stack.map(\.key) + [key]
            let source = sourceForPath(path, global: global, node: node, shouldMerge: shouldMerge)
            markers[index + 1] = source.marker

            if lineContainsContainerStart(line) {
                stack.append(SettingsSourceScope(depth: depth, key: key, source: source))
            }
        }

        return markers
    }

    private func sourceForPath(
        _ path: [String],
        global: [String: Any],
        node: [String: Any],
        shouldMerge: Bool
    ) -> SettingsSource {
        guard shouldMerge else { return .node }
        let hasGlobal = jsonValue(at: path, in: global) != nil
        let hasNode = jsonValue(at: path, in: node) != nil
        if hasGlobal && hasNode { return .override }
        if hasNode { return .node }
        return .common
    }

    private func flattenedJSONLeaves(_ object: [String: Any]) -> [[String]: Any] {
        var result: [[String]: Any] = [:]
        flattenJSONValue(object, path: [], into: &result)
        return result
    }

    private func flattenJSONValue(_ value: Any, path: [String], into result: inout [[String]: Any]) {
        if let dict = value as? [String: Any], !dict.isEmpty {
            for (key, child) in dict {
                flattenJSONValue(child, path: path + [key], into: &result)
            }
            return
        }
        result[path] = value
    }

    private func jsonValue(at path: [String], in object: [String: Any]) -> Any? {
        guard !path.isEmpty else { return object }
        var current: Any = object
        for key in path {
            guard let dict = current as? [String: Any],
                  let next = dict[key] else {
                return nil
            }
            current = next
        }
        return current
    }

    private func setJSONValue(_ value: Any, at path: [String], in object: inout [String: Any]) {
        guard let first = path.first else { return }
        if path.count == 1 {
            object[first] = value
            return
        }
        var child = object[first] as? [String: Any] ?? [:]
        setJSONValue(value, at: Array(path.dropFirst()), in: &child)
        object[first] = child
    }

    private func removeJSONValue(at path: [String], from object: inout [String: Any]) {
        guard let first = path.first else { return }
        if path.count == 1 {
            object.removeValue(forKey: first)
            return
        }
        guard var child = object[first] as? [String: Any] else { return }
        removeJSONValue(at: Array(path.dropFirst()), from: &child)
        if child.isEmpty {
            object.removeValue(forKey: first)
        } else {
            object[first] = child
        }
    }

    private func jsonKey(in line: String) -> String? {
        let pattern = #"^\s*"((?:\\.|[^"\\])*)"\s*:"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        let raw = String(line[range])
        if let data = "\"\(raw)\"".data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? String {
            return decoded
        }
        return raw
    }

    private func lineContainsContainerStart(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        let tail = line[line.index(after: colon)...]
        return tail.contains("{") || tail.contains("[")
    }
}
