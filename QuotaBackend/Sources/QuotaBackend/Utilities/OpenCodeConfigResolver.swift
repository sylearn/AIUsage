import Foundation

// MARK: - OpenCode Config Discovery
// OpenCode 的全局配置层解析真相源。App、统计和诊断必须共用这里的加载顺序，
// 不能分别猜测某一个 opencode.json / opencode.jsonc 文件。

public enum OpenCodeConfigFormat: String, Codable, Sendable {
    case json
    case jsonc
}

public enum OpenCodeConfigParseStatus: String, Codable, Sendable {
    case missing
    case valid
    case invalid
}

public struct OpenCodeConfigFileInfo: Equatable, Sendable {
    public let path: String
    public let format: OpenCodeConfigFormat
    public let exists: Bool
    public let parseStatus: OpenCodeConfigParseStatus

    public var fileName: String { (path as NSString).lastPathComponent }

    public init(
        path: String,
        format: OpenCodeConfigFormat,
        exists: Bool,
        parseStatus: OpenCodeConfigParseStatus
    ) {
        self.path = path
        self.format = format
        self.exists = exists
        self.parseStatus = parseStatus
    }
}

public struct OpenCodeConfigResolution: Equatable, Sendable {
    public let configDirectory: String
    /// OpenCode 按低到高优先级加载的全局层：config.json → opencode.json → opencode.jsonc。
    /// 缺失文件也保留在列表中，便于 UI 解释“哪一层可管理、哪一层尚未创建”。
    public let globalLayers: [OpenCodeConfigFileInfo]
    /// AIUsage 可管理的专用全局层：优先复用 opencode.jsonc，其次 opencode.json；
    /// 两者都缺失时按 OpenCode 当前默认创建 opencode.jsonc。低优先级 legacy
    /// config.json 只读不改。
    public let managementTarget: OpenCodeConfigFileInfo
    /// 当前进程显式指定的附加配置层；它叠加在全局层之上，但不由 AIUsage 擅自修改。
    public let customConfigPath: String?
    /// OPENCODE_CONFIG_DIR 是附加目录，不替换 XDG 全局目录。OpenCode 会在后续阶段加载其中两层。
    public let customConfigDirectory: String?
    public let customDirectoryLayers: [OpenCodeConfigFileInfo]
    /// OPENCODE_CONFIG_CONTENT 是最后加载的内联配置层。这里只暴露解析状态，
    /// 不把可能含密钥的原文带进 UI 状态。
    public let inlineConfigParseStatus: OpenCodeConfigParseStatus

    public var existingGlobalLayers: [OpenCodeConfigFileInfo] {
        globalLayers.filter { $0.exists }
    }

    public var lowerPriorityGlobalLayers: [OpenCodeConfigFileInfo] {
        globalLayers.filter { $0.exists && $0.path != managementTarget.path }
    }

    public init(
        configDirectory: String,
        globalLayers: [OpenCodeConfigFileInfo],
        managementTarget: OpenCodeConfigFileInfo,
        customConfigPath: String?,
        customConfigDirectory: String?,
        customDirectoryLayers: [OpenCodeConfigFileInfo],
        inlineConfigParseStatus: OpenCodeConfigParseStatus
    ) {
        self.configDirectory = configDirectory
        self.globalLayers = globalLayers
        self.managementTarget = managementTarget
        self.customConfigPath = customConfigPath
        self.customConfigDirectory = customConfigDirectory
        self.customDirectoryLayers = customDirectoryLayers
        self.inlineConfigParseStatus = inlineConfigParseStatus
    }
}

public struct OpenCodeConfigResolver {
    public let homeDirectory: String
    public let environment: [String: String]

    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    public var configDirectory: String {
        if let xdg = normalizedPath(environment["XDG_CONFIG_HOME"]),
           !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("opencode")
        }
        return (homeDirectory as NSString).appendingPathComponent(".config/opencode")
    }

    public func resolve() -> OpenCodeConfigResolution {
        // OpenCode 1.17.x 按此顺序加载并合并全局文件；后加载层只覆盖自己定义的键。
        let configPath = (configDirectory as NSString).appendingPathComponent("config.json")
        let jsonPath = (configDirectory as NSString).appendingPathComponent("opencode.json")
        let jsoncPath = (configDirectory as NSString).appendingPathComponent("opencode.jsonc")
        let legacy = inspect(path: configPath, format: .json)
        let json = inspect(path: jsonPath, format: .json)
        let jsonc = inspect(path: jsoncPath, format: .jsonc)

        let layers = [legacy, json, jsonc]
        // config.json 是兼容旧版的低优先级层。AIUsage 只写最高优先级的专用文件。
        let target = jsonc.exists ? jsonc : (json.exists ? json : jsonc)
        let custom = normalizedPath(environment["OPENCODE_CONFIG"])
        let customDirectory = normalizedPath(environment["OPENCODE_CONFIG_DIR"])
        let inlineContent = normalizedContent(environment["OPENCODE_CONFIG_CONTENT"])
        let customLayers: [OpenCodeConfigFileInfo]
        if let customDirectory {
            customLayers = [
                inspect(
                    path: (customDirectory as NSString).appendingPathComponent("opencode.json"),
                    format: .json
                ),
                inspect(
                    path: (customDirectory as NSString).appendingPathComponent("opencode.jsonc"),
                    format: .jsonc
                ),
            ]
        } else {
            customLayers = []
        }

        return OpenCodeConfigResolution(
            configDirectory: configDirectory,
            globalLayers: layers,
            managementTarget: target,
            customConfigPath: custom?.isEmpty == false ? custom : nil,
            customConfigDirectory: customDirectory,
            customDirectoryLayers: customLayers,
            inlineConfigParseStatus: inlineContent.map {
                JSONCEditor.parseObject($0) == nil ? .invalid : .valid
            } ?? .missing
        )
    }

    /// 合并当前进程能够确定的全局与环境配置层。项目配置、远端组织策略等依赖
    /// OpenCode 启动上下文的层不在这里猜测；任一已知层非法时直接失败，不静默丢弃。
    public func readEffectiveObject() -> [String: Any]? {
        let resolution = resolve()
        var result: [String: Any] = [:]
        for layer in resolution.globalLayers where layer.exists {
            guard let object = readObject(atPath: layer.path) else { return nil }
            result = merge(base: result, override: object)
        }
        if let customPath = resolution.customConfigPath,
           !resolution.globalLayers.contains(where: { $0.path == customPath }),
           FileManager.default.fileExists(atPath: customPath) {
            guard let object = readObject(atPath: customPath) else { return nil }
            result = merge(base: result, override: object)
        }
        for layer in resolution.customDirectoryLayers where layer.exists {
            guard let object = readObject(atPath: layer.path) else { return nil }
            result = merge(base: result, override: object)
        }
        if let object = readInlineConfigObject() {
            result = merge(base: result, override: object)
        } else if resolution.inlineConfigParseStatus == .invalid {
            return nil
        }
        return result
    }

    public func readInlineConfigObject() -> [String: Any]? {
        guard let content = normalizedContent(environment["OPENCODE_CONFIG_CONTENT"]) else { return nil }
        return JSONCEditor.parseObject(content)
    }

    public func readObject(atPath path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return JSONCEditor.parseObject(text)
    }

    private func inspect(path: String, format: OpenCodeConfigFormat) -> OpenCodeConfigFileInfo {
        let exists = FileManager.default.fileExists(atPath: path)
        let status: OpenCodeConfigParseStatus
        if !exists {
            status = .missing
        } else {
            status = readObject(atPath: path) == nil ? .invalid : .valid
        }
        return OpenCodeConfigFileInfo(path: path, format: format, exists: exists, parseStatus: status)
    }

    private func normalizedPath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "~" { return homeDirectory }
        if trimmed.hasPrefix("~/") {
            return (homeDirectory as NSString).appendingPathComponent(String(trimmed.dropFirst(2)))
        }
        return trimmed
    }

    private func normalizedContent(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private func merge(base: [String: Any], override: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in override {
            if let baseObject = result[key] as? [String: Any],
               let overrideObject = value as? [String: Any] {
                result[key] = merge(base: baseObject, override: overrideObject)
            } else {
                result[key] = value
            }
        }
        return result
    }
}
