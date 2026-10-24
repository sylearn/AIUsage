import Foundation
import os.log
import QuotaBackend

private let claudeSettingsLog = Logger(subsystem: "com.aiusage.desktop", category: "ClaudeSettings")

/// Values Claude Code accepts in the durable `effortLevel` setting. This
/// startup default is loaded by a new Claude Code process; it does not mutate
/// the effort of a process that is already running.
enum ClaudeCodePersistentEffort: String, CaseIterable, Identifiable {
    case auto
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }
}

enum ClaudeSettingsError: LocalizedError {
    case invalidRootObject
    case unreadableSettings
    case failedToSerialize
    case failedToCreateDirectory
    case failedToWriteFile

    var errorDescription: String? {
        switch self {
        case .invalidRootObject:
            return AppSettings.shared.t("Claude settings.json must contain a top-level object.", "Claude settings.json 必须是顶层对象。")
        case .unreadableSettings:
            return AppSettings.shared.t("Claude settings.json is unreadable or contains invalid JSON.", "Claude settings.json 无法读取或 JSON 已损坏。")
        case .failedToSerialize:
            return AppSettings.shared.t("Failed to serialize Claude settings.", "序列化 Claude 设置失败。")
        case .failedToCreateDirectory:
            return AppSettings.shared.t("Failed to create the Claude settings directory.", "创建 Claude 设置目录失败。")
        case .failedToWriteFile:
            return AppSettings.shared.t("Failed to write Claude settings.json.", "写入 Claude settings.json 失败。")
        }
    }
}

// MARK: - Claude Settings Manager

class ClaudeSettingsManager {
    static let shared = ClaudeSettingsManager()

    private let directory: URL

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.directory = directory
    }

    private var settingsPath: String {
        directory.appendingPathComponent("settings.json").path
    }

    private var backupPath: String {
        directory.appendingPathComponent("settings.backup.json").path
    }

    private var overlayStateURL: URL { directory.appendingPathComponent("settings.aiusage-common.json") }

    func readSettings() throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: settingsPath) else {
            return [:]
        }

        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let json = object as? [String: Any] else {
                claudeSettingsLog.error("Failed to read Claude settings: root object is not a dictionary")
                throw ClaudeSettingsError.invalidRootObject
            }
            return json
        } catch let error as ClaudeSettingsError {
            throw error
        } catch {
            claudeSettingsLog.error("Failed to read Claude settings from \(self.settingsPath, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .public)")
            throw ClaudeSettingsError.unreadableSettings
        }
    }

    private let managedEnvKeys = [
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_DEFAULT_FABLE_MODEL",
        "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME",
        "ANTHROPIC_DEFAULT_FABLE_MODEL_DESCRIPTION",
        "ANTHROPIC_DEFAULT_FABLE_MODEL_SUPPORTED_CAPABILITIES",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME",
        "ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION",
        "ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME",
        "ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION",
        "ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES",
        "ANTHROPIC_CUSTOM_MODEL_OPTION",
        "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME",
        "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION",
        "ANTHROPIC_CUSTOM_MODEL_OPTION_SUPPORTED_CAPABILITIES",
        "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY",
        "NODE_EXTRA_CA_CERTS",
    ]

    /// Capabilities Claude Code honors for pinned 3P models that are not in
    /// its baked family table. A firstParty custom BASE_URL also falls back
    /// to enabling effort for unknown IDs; this list keeps Bedrock/Vertex
    /// and `/effort` aligned if that fallback changes.
    private static let virtualRouteCapabilities = "thinking,adaptive_thinking,effort,max_effort,xhigh_effort"

    struct EnvConfig {
        enum ModelPresentation: Equatable {
            case aiUsageRoutes
        }

        var baseURL: String?
        var authToken: String?
        var defaultModel: String?
        var opusModel: String?
        var sonnetModel: String?
        var haikuModel: String?
        var modelPresentation: ModelPresentation? = nil
        var enableGatewayModelDiscovery: Bool = false
        var nodeExtraCACerts: String?
    }

    /// 通用/节点片段先合并，路由键最后写入；保留用户其它设置。
    func writeEnv(_ config: EnvConfig, settingsOverlay: [String: Any]? = nil) throws {
        let original = try removingPreviousOverlay(from: readSettings())
        var overlay = settingsOverlay ?? [:]
        overlay.removeValue(forKey: "model")
        if var env = overlay["env"] as? [String: Any] {
            for key in managedEnvKeys { env.removeValue(forKey: key) }
            // Gateway 使用自己的 token，不能被节点遗留的 API key 抢占。
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
            overlay["env"] = env
        }
        var settings = GlobalConfig.deepMerge(base: original, override: overlay)
        var env = settings["env"] as? [String: Any] ?? [:]

        let routeDescription = AppSettings.shared.t(
            "Stable route hot-switched inside AIUsage Gateway",
            "由 AIUsage Gateway 热切换的稳定路由"
        )
        let presentsAIUsageRoutes = config.modelPresentation == .aiUsageRoutes
        let capabilities = presentsAIUsageRoutes ? Self.virtualRouteCapabilities : nil
        let pairs: [(String, String?)] = [
            ("ANTHROPIC_BASE_URL", config.baseURL),
            ("ANTHROPIC_AUTH_TOKEN", config.authToken),
            ("ANTHROPIC_DEFAULT_FABLE_MODEL", presentsAIUsageRoutes ? config.defaultModel : nil),
            ("ANTHROPIC_DEFAULT_FABLE_MODEL_NAME", presentsAIUsageRoutes ? "AIUsage" : nil),
            ("ANTHROPIC_DEFAULT_FABLE_MODEL_DESCRIPTION", presentsAIUsageRoutes ? routeDescription : nil),
            ("ANTHROPIC_DEFAULT_FABLE_MODEL_SUPPORTED_CAPABILITIES", capabilities),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL", config.opusModel),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL_NAME", presentsAIUsageRoutes ? "AIUsage Opus" : nil),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION", presentsAIUsageRoutes ? routeDescription : nil),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES", capabilities),
            ("ANTHROPIC_DEFAULT_SONNET_MODEL", config.sonnetModel),
            ("ANTHROPIC_DEFAULT_SONNET_MODEL_NAME", presentsAIUsageRoutes ? "AIUsage Sonnet" : nil),
            ("ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION", presentsAIUsageRoutes ? routeDescription : nil),
            ("ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES", capabilities),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL", config.haikuModel),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME", presentsAIUsageRoutes ? "AIUsage Haiku" : nil),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION", presentsAIUsageRoutes ? routeDescription : nil),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES", capabilities),
            // Keep the extra picker row for the default virtual route. Family
            // alias `fable` is pinned separately so `/model fable` cannot fall
            // back to the baked "Fable 5" SKU.
            ("ANTHROPIC_CUSTOM_MODEL_OPTION", presentsAIUsageRoutes ? config.defaultModel : nil),
            ("ANTHROPIC_CUSTOM_MODEL_OPTION_NAME", presentsAIUsageRoutes ? "AIUsage" : nil),
            ("ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION", presentsAIUsageRoutes ? routeDescription : nil),
            ("ANTHROPIC_CUSTOM_MODEL_OPTION_SUPPORTED_CAPABILITIES", capabilities),
            ("CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY", config.enableGatewayModelDiscovery ? "1" : nil),
            ("NODE_EXTRA_CA_CERTS", config.nodeExtraCACerts),
        ]
        for (key, value) in pairs {
            if let value = value {
                env[key] = value
            } else {
                env.removeValue(forKey: key)
            }
        }

        settings["env"] = env

        if let model = config.defaultModel, !model.isEmpty {
            settings["model"] = model
        } else {
            settings.removeValue(forKey: "model")
        }

        settings = try preserveSubscriptionStatusLine(settings)
        // 只记录片段覆盖的字段；重启后关闭合并/删除字段也能恢复原值。
        // 文件写入失败时回滚记录，不将未应用的片段当作已生效。
        let previousState = try readOverlayStateData()
        let state: [String: Any] = [
            "original": Self.overlayProjection(original, keys: overlay),
            "applied": Self.overlayProjection(settings, keys: overlay),
        ]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stateData = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        do {
            try stateData.write(to: overlayStateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: overlayStateURL.path)
            try writeSettings(settings)
        } catch {
            if let previousState {
                try previousState.write(to: overlayStateURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: overlayStateURL.path) {
                try FileManager.default.removeItem(at: overlayStateURL)
            }
            throw error
        }
    }

    /// Claude Code accepts only low...xhigh as a durable settings value.
    /// `auto` is represented by removing the key. Max and Ultracode remain
    /// session-only and are changed inside Claude Code via `/effort`.
    func readPersistentEffort() throws -> ClaudeCodePersistentEffort {
        let settings = try readSettings()
        guard let raw = settings["effortLevel"] as? String,
              let level = ClaudeCodePersistentEffort(rawValue: raw),
              level != .auto else { return .auto }
        return level
    }

    func writePersistentEffort(_ level: ClaudeCodePersistentEffort) throws {
        var settings = try readSettings()
        if level == .auto {
            settings.removeValue(forKey: "effortLevel")
        } else {
            settings["effortLevel"] = level.rawValue
        }
        try writeSettings(settings)
    }

    /// Full replacement write: backs up current file (unless reapplying while already active), then writes the entire settings dict.
    func writeFullSettings(_ settings: [String: Any], preserveExistingBackup: Bool = false) throws {
        let preserved = try preserveSubscriptionStatusLine(settings)
        if !preserveExistingBackup {
            backupCurrentSettings()
        }
        try writeSettings(preserved)
        claudeSettingsLog.info("Full settings.json replacement written successfully")
    }

    func clearEnv() throws {
        var settings = try removingPreviousOverlay(from: readSettings())
        var env = settings["env"] as? [String: Any] ?? [:]
        for key in managedEnvKeys {
            env.removeValue(forKey: key)
        }
        settings["env"] = env
        settings.removeValue(forKey: "model")
        try writeSettings(settings)
        if FileManager.default.fileExists(atPath: overlayStateURL.path) {
            try FileManager.default.removeItem(at: overlayStateURL)
        }
    }

    private func readOverlayStateData() throws -> Data? {
        guard FileManager.default.fileExists(atPath: overlayStateURL.path) else { return nil }
        return try Data(contentsOf: overlayStateURL)
    }

    private func removingPreviousOverlay(from current: [String: Any]) throws -> [String: Any] {
        guard let data = try readOverlayStateData() else { return current }
        guard let state = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let original = state["original"] as? [String: Any],
              let applied = state["applied"] as? [String: Any] else {
            throw ClaudeSettingsError.unreadableSettings
        }
        return Self.removingOverlay(current: current, original: original, applied: applied)
    }

    /// 只还原仍等于上次写入值的字段，保留用户在外部修改的值及新增字段。
    private static func removingOverlay(current: [String: Any], original: [String: Any],
                                        applied: [String: Any]) -> [String: Any] {
        var result = current
        for (key, value) in applied {
            guard let live = current[key] else { continue }
            if let liveObject = live as? [String: Any], let appliedObject = value as? [String: Any],
               original[key] == nil || original[key] is [String: Any] {
                let restored = removingOverlay(current: liveObject,
                                               original: original[key] as? [String: Any] ?? [:],
                                               applied: appliedObject)
                result[key] = restored.isEmpty && original[key] == nil ? nil : restored
            } else if NSDictionary(dictionary: [key: live]).isEqual(to: [key: value]) {
                result[key] = original[key]
            }
        }
        return result
    }

    private static func overlayProjection(_ source: [String: Any], keys: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in keys {
            if let nested = value as? [String: Any], let sourceObject = source[key] as? [String: Any] {
                result[key] = overlayProjection(sourceObject, keys: nested)
            } else {
                result[key] = source[key]
            }
        }
        return result
    }

    /// Restore settings.json from the backup created before the last full write.
    func restoreFromBackup() throws {
        guard let data = FileManager.default.contents(atPath: backupPath) else {
            claudeSettingsLog.info("No backup file to restore from, clearing managed keys instead")
            try clearEnv()
            return
        }
        do {
            guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ClaudeSettingsError.invalidRootObject
            }
            try writeSettings(preserveSubscriptionStatusLine(settings))
            claudeSettingsLog.info("Restored settings.json from backup")
        } catch {
            claudeSettingsLog.error("Failed to restore settings.json from backup: \(String(describing: error), privacy: .public)")
            try clearEnv()
        }
    }

    // MARK: - Internal

    private func preserveSubscriptionStatusLine(_ settings: [String: Any]) throws -> [String: Any] {
        try ClaudeSubscriptionConnection().preservingStatusLine(in: settings, current: readSettings(),
            directory: URL(fileURLWithPath: settingsPath).deletingLastPathComponent().path)
    }

    private func backupCurrentSettings() {
        guard FileManager.default.fileExists(atPath: settingsPath) else { return }
        do {
            if FileManager.default.fileExists(atPath: backupPath) {
                try FileManager.default.removeItem(atPath: backupPath)
            }
            try FileManager.default.copyItem(atPath: settingsPath, toPath: backupPath)
        } catch {
            claudeSettingsLog.error("Failed to backup settings.json: \(String(describing: error), privacy: .public)")
        }
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            claudeSettingsLog.error("Failed to serialize Claude settings: \(String(describing: error), privacy: .public)")
            throw ClaudeSettingsError.failedToSerialize
        }

        let dir = (settingsPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            claudeSettingsLog.error("Failed to create Claude settings directory \(dir, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .public)")
            throw ClaudeSettingsError.failedToCreateDirectory
        }

        do {
            try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        } catch {
            claudeSettingsLog.error("Failed to write Claude settings at \(self.settingsPath, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .public)")
            throw ClaudeSettingsError.failedToWriteFile
        }
    }
}
