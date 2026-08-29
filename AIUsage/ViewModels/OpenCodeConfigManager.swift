import Foundation
import os.log
import QuotaBackend

// MARK: - OpenCode Config Manager
// 管理 ~/.config/opencode/opencode.json：注入受管的 provider["aiusage-<节点>"] 块
// （npm 按节点协议选择 @ai-sdk/openai-compatible|anthropic|openai + baseURL/apiKey/models），
// 并把顶层 model 指向 "aiusage-<节点>/<模型>"；停用时从备份完整还原原文。
// 直连模式 OpenCode 原生直连上游；代理模式经 baseURLOverride 指向本地透传代理（路线 B）。
// provider id 按节点区分（node.managedProviderId）——opencode.db 的消息会携带它作为
// providerID，Phase 1 统计据此把用量/费用归因到具体节点。
//
// 数据来源/写入目标: $XDG_CONFIG_HOME/opencode/opencode.json（默认 ~/.config/opencode/）；
//          存在 opencode.jsonc 时优先接管它（OpenCode 实际读取的文件）。
// 工作方式: 激活前把「干净原文逐字备份」到 <配置>.aiusage.bak（备份即真相源，重复激活幂等），
//          还原即整文覆盖回原文。
// 密钥: 直连模式的上游 API Key 走 OpenCode 官方位置 ~/.local/share/opencode/auth.json（0600，
//       见 OpenCodeAuthStore），受管块不写明文 apiKey；auth.json 写不动时回退内联（issue #65）。
// JSONC: 接管 opencode.jsonc 时——逐字备份原文 → 以备份原文为基底，用 JSONCEditor 做「保注释的
//        结构化文本注入」（仅注入/替换 provider[受管键]、顶层 model、$schema），输出仍是带注释的
//        合法 JSONC（OpenCode 能解析）。即接管期间用户注释也始终保留（issue #42）。
//        JSONCEditor 解析失败或写后自校验不过时，回退为无注释结构化写回（保证语义正确）。
//        停用时从备份完整还原。
// 安全: 写入的配置含 API Key，落盘后恢复 0600 权限。

private let openCodeConfigLog = Logger(subsystem: "com.aiusage.desktop", category: "OpenCodeConfig")

enum OpenCodeConfigError: LocalizedError {
    case invalidJSON
    case nodeIncomplete
    case failedToWriteFile
    case failedToRestore

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return AppSettings.shared.t(
                "The opencode config could not be parsed as JSON, refusing to take over.",
                "opencode 配置无法解析为 JSON，已拒绝接管。"
            )
        case .nodeIncomplete:
            return AppSettings.shared.t(
                "The node is missing a base URL or model list.",
                "节点缺少 Base URL 或模型列表。"
            )
        case .failedToWriteFile:
            return AppSettings.shared.t("Failed to write opencode.json.", "写入 opencode.json 失败。")
        case .failedToRestore:
            return AppSettings.shared.t(
                "Failed to restore opencode.json from backup.",
                "从备份还原 opencode.json 失败。"
            )
        }
    }
}

final class OpenCodeConfigManager {
    static let shared = OpenCodeConfigManager()

    /// 受管 provider id 前缀。OpenCode 内置 provider 无此前缀，不冲突。
    /// 实际键为 `aiusage-<节点 slug>`（兼容剥离早期固定的 `aiusage`）。
    static let providerIdPrefix = "aiusage"

    /// 是否为本应用注入的受管 provider 键。
    static func isManagedProviderKey(_ key: String) -> Bool {
        key == providerIdPrefix || key.hasPrefix(providerIdPrefix + "-")
    }

    /// 受管块里的 API Key 落在哪。
    enum ManagedAPIKeyPlacement {
        /// 交给 ~/.local/share/opencode/auth.json（0600），配置里不出现明文 key（issue #65）。
        case externalAuthFile
        /// 内联进 provider options。用于自带配置的启动命令导出，以及 auth.json 写不动时的兜底。
        case inlineOptions
    }

    private let fileManager = FileManager.default
    private let authStore = OpenCodeAuthStore.shared

    // MARK: - Paths

    var configDirectory: String {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]?.nilIfBlank {
            return (xdg as NSString).appendingPathComponent("opencode")
        }
        let home = fileManager.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/opencode")
    }

    /// OpenCode 实际读取并由本类接管的配置文件：存在 opencode.jsonc 时优先它，否则 opencode.json。
    var configPath: String {
        usesJSONC ? jsoncPath : jsonPath
    }

    private var jsonPath: String {
        (configDirectory as NSString).appendingPathComponent("opencode.json")
    }

    private var jsoncPath: String {
        (configDirectory as NSString).appendingPathComponent("opencode.jsonc")
    }

    private var backupPath: String {
        configPath + ".aiusage.bak"
    }

    // MARK: - State

    /// 用户使用 opencode.jsonc（带注释）作为配置文件。接管期间以无注释 JSON 改写，停用从备份还原注释。
    var usesJSONC: Bool {
        fileManager.fileExists(atPath: jsoncPath)
    }

    /// 当前 opencode.json 是否处于受管理（已注入节点）状态。
    var isManaged: Bool {
        guard let root = try? readConfigObjectIfExists() else { return false }
        guard let provider = root["provider"] as? [String: Any] else { return false }
        return provider.keys.contains(where: Self.isManagedProviderKey)
    }

    /// 是否存在我们的备份（代表接管态/未正常还原）。
    var hasBackup: Bool {
        fileManager.fileExists(atPath: backupPath)
    }

    // MARK: - Activation

    /// 注入节点配置：provider["aiusage-<节点>"]（baseURL/apiKey/models）+ 顶层 model 指向受管 provider。
    /// - Parameter baseURLOverride: 代理模式下指向本地透传代理（如 http://127.0.0.1:4321/v1），
    ///   上游真实 baseURL/Key 由代理进程持有，不再出现在 opencode.json。
    /// - Parameter commonSettings: 通用配置片段（按节点合并策略由调用方决定传入与否）。
    ///   合并顺序：用户原文 ← 通用配置 ← 受管块（受管键始终最终生效）。
    func activate(node: OpenCodeNode, baseURLOverride: String? = nil, commonSettings: [String: Any]? = nil) throws {
        guard let defaultModel = node.effectiveDefaultModel, node.isComplete else {
            throw OpenCodeConfigError.nodeIncomplete
        }

        // 密钥先落 auth.json（0600），再写配置。代理模式下受管块放的是 client key，不算密钥，
        // 但仍要清掉本节点可能残留的直连凭据——auth.json 里的 key 会覆盖配置里的。
        let directAPIKey = baseURLOverride == nil ? node.apiKey.nilIfBlank : nil
        let credentials = directAPIKey.map { [node.managedProviderId: $0] } ?? [:]
        let credentialsStored = authStore.syncManagedCredentials(credentials)
        let keyPlacement: ManagedAPIKeyPlacement = credentialsStored ? .externalAuthFile : .inlineOptions
        if !credentialsStored {
            openCodeConfigLog.error("auth.json write failed, falling back to inline apiKey in opencode config")
        }

        let pristine = try establishBackupAndLoadPristine()
        let root = injectManagedEntries(
            into: mergedBase(pristine: pristine, commonSettings: commonSettings),
            node: node,
            defaultModel: defaultModel,
            baseURLOverride: baseURLOverride,
            keyPlacement: keyPlacement
        )

        try writeManagedRoot(root)
        openCodeConfigLog.info("opencode config managed provider injected (provider=\(node.managedProviderId, privacy: .public), models=\(node.models.count), jsonc=\(self.usesJSONC, privacy: .public), keyInAuthFile=\(keyPlacement == .externalAuthFile, privacy: .public))")
    }

    // MARK: - Global Unified Proxy Activation

    /// 全局统一代理受管 provider 键：固定为裸前缀 `aiusage`（per-node 受管键恒为 `aiusage-<slug>`，
    /// 永不与之冲突）。统计页据此把全局模式流量与 per-node 流量区分开。
    static let globalProviderId = providerIdPrefix

    /// 接管 opencode.json 为「全局统一代理」固定入口：单一受管 provider 指向常驻代理端口，
    /// 仅暴露一个固定虚拟模型；切换激活节点只在代理内热替换上游、改写 model，opencode.json 不变。
    /// - interface: 选定接口协议（决定 npm 包：openai-compatible / anthropic / openai）。
    /// - baseURL: 含 /v1 的本地代理地址（SDK 在其后拼 /chat/completions、/messages、/responses）。
    /// - clientKey: 固定 client key（写入受管块 apiKey；代理据此鉴权）。
    /// - virtualModel: 固定虚拟模型名（CLI 永远发它，由代理改写为激活节点真实模型）。
    func activateGlobal(interface: OpenCodeProtocol, baseURL: String, clientKey: String, virtualModel: String) throws {
        let model = virtualModel.nilIfBlank ?? "model"

        // 受管块放的是 client key（代理鉴权用，非上游密钥），留在配置里即可；但要清掉
        // per-node 直连留下的凭据，否则 auth.json 里的 key 会覆盖它。
        authStore.removeManagedCredentials()

        // 备份即真相源（与 per-node activate 同语义，幂等）。
        var root = try establishBackupAndLoadPristine()
        if root["$schema"] == nil {
            root["$schema"] = "https://opencode.ai/config.json"
        }
        var provider = root["provider"] as? [String: Any] ?? [:]
        provider[Self.globalProviderId] = [
            "npm": interface.npmPackage,
            "name": "AIUsage Global Proxy",
            "options": ["baseURL": baseURL, "apiKey": clientKey],
            "models": [model: ["name": model]],
        ]
        root["provider"] = provider
        root["model"] = "\(Self.globalProviderId)/\(model)"

        try writeManagedRoot(root)
        openCodeConfigLog.info("opencode config global proxy provider injected (interface=\(interface.rawValue, privacy: .public), model=\(model, privacy: .public), jsonc=\(self.usesJSONC, privacy: .public))")
    }

    /// 首次接管时建立「备份即真相源」并返回干净原文（已剥离受管块）。
    /// - 已有备份：以备份为准（重复激活/切换节点幂等，不把受管文件当原文）。
    /// - 首次接管且无残留受管块：逐字复制原文为备份，保真保留注释/格式（opencode.jsonc 还原必需）。
    /// - 首次接管但残留旧受管块（异常）：剥离后写回作备份（此罕见路径不保真注释，可接受）。
    private func establishBackupAndLoadPristine() throws -> [String: Any] {
        if hasBackup {
            return stripManagedEntries(from: try readObject(atPath: backupPath) ?? [:])
        }
        guard fileManager.fileExists(atPath: configPath) else { return [:] }
        let current = try readObject(atPath: configPath) ?? [:]
        let clean = stripManagedEntries(from: current)
        if managedKeysPresent(in: current) {
            try writeObject(clean, toPath: backupPath)
        } else {
            try copyFileVerbatim(from: configPath, to: backupPath)
        }
        return clean
    }

    /// 用户原文 + 通用配置片段的深合并（通用片段优先，剥离其中可能误带的受管键）。
    private func mergedBase(pristine: [String: Any], commonSettings: [String: Any]?) -> [String: Any] {
        guard let common = commonSettings, !common.isEmpty else { return pristine }
        return GlobalConfig.deepMerge(base: pristine, override: stripManagedEntries(from: common))
    }

    // MARK: - Managed Block Building

    /// 受管 provider 条目（写进 provider[managedProviderId] 的值）。激活与编辑器 JSON 预览共用。
    func managedProviderEntry(
        node: OpenCodeNode,
        baseURLOverride: String? = nil,
        keyPlacement: ManagedAPIKeyPlacement = .externalAuthFile
    ) -> [String: Any] {
        // 每模型独立定价写入各自的 cost 块（USD/百万 token，CNY 录入按近似汇率折算），
        // OpenCode 据此把费用算进 opencode.db——金额单一来源，不在本地重复计费。
        let generationOptions = node.modelGenerationOptions
        var modelsBlock: [String: Any] = [:]
        for model in node.modelEntries where !model.id.isEmpty {
            var entry: [String: Any] = ["name": model.id]
            var limit: [String: Any] = [:]
            if node.contextLimit > 0 { limit["context"] = node.contextLimit }
            if node.outputLimit > 0 { limit["output"] = node.outputLimit }
            if !limit.isEmpty { entry["limit"] = limit }
            // 生成参数（temperature/topP/…）统一写入每个模型 options，OpenCode 透传给上游 SDK。
            if !generationOptions.isEmpty { entry["options"] = generationOptions }
            // 每模型 modalities（issue #24）：任一侧非空才写，否则由 OpenCode 取模型默认。
            if model.hasModalities {
                var modalities: [String: Any] = [:]
                if !model.inputModalities.isEmpty {
                    modalities["input"] = model.inputModalities.map(\.rawValue)
                }
                if !model.outputModalities.isEmpty {
                    modalities["output"] = model.outputModalities.map(\.rawValue)
                }
                entry["modalities"] = modalities
            }
            if node.pricingCurrency != .none, model.hasPricing {
                let currency = node.pricingCurrency
                var costBlock: [String: Any] = [
                    "input": currency.toUSD(model.priceInputPerMillion),
                    "output": currency.toUSD(model.priceOutputPerMillion),
                ]
                if model.priceCacheReadPerMillion > 0 {
                    costBlock["cache_read"] = currency.toUSD(model.priceCacheReadPerMillion)
                }
                if model.priceCacheWritePerMillion > 0 {
                    costBlock["cache_write"] = currency.toUSD(model.priceCacheWritePerMillion)
                }
                entry["cost"] = costBlock
            }
            modelsBlock[model.id] = entry
        }

        var options: [String: Any] = ["baseURL": baseURLOverride ?? node.baseURL]
        if baseURLOverride != nil {
            // 代理模式：真实 Key 留在代理进程环境里，配置里只放客户端 Key（设了则代理据此鉴权），
            // 留空时回退占位符（AI SDK 各包都需要非空 apiKey 才不会去找环境变量）。
            options["apiKey"] = node.expectedClientKey.nilIfBlank ?? "aiusage-proxy"
        } else if let apiKey = node.apiKey.nilIfBlank, keyPlacement == .inlineOptions {
            options["apiKey"] = apiKey
        }

        return [
            "npm": node.protocolType.npmPackage,
            "name": node.displayName,
            "options": options,
            "models": modelsBlock,
        ]
    }

    /// 把受管块注入干净原文：provider[managedId] + 顶层 model 指向（含 $schema 补齐）。
    private func injectManagedEntries(
        into cleanRoot: [String: Any],
        node: OpenCodeNode,
        defaultModel: String,
        baseURLOverride: String?,
        keyPlacement: ManagedAPIKeyPlacement = .externalAuthFile
    ) -> [String: Any] {
        var root = cleanRoot
        if root["$schema"] == nil {
            root["$schema"] = "https://opencode.ai/config.json"
        }
        let managedId = node.managedProviderId
        var provider = root["provider"] as? [String: Any] ?? [:]
        provider[managedId] = managedProviderEntry(
            node: node,
            baseURLOverride: baseURLOverride,
            keyPlacement: keyPlacement
        )
        root["provider"] = provider
        root["model"] = "\(managedId)/\(defaultModel)"
        return root
    }

    /// 当前的干净原文（备份优先；未接管时为现行文件剥离受管键），供预览/分层标注。
    func pristineConfig() -> [String: Any] {
        let pristine: [String: Any]
        if hasBackup {
            pristine = (try? readObject(atPath: backupPath)) ?? [:]
        } else {
            pristine = (try? readConfigObjectIfExists()) ?? [:]
        }
        return stripManagedEntries(from: pristine)
    }

    /// 编辑器 JSON 预览：激活该节点后 opencode.json 的完整内容（基于备份/当前原文合成，不落盘）。
    /// 节点缺默认模型时顶层 model 留空字符串占位，仅供预览。
    func previewMergedConfig(
        node: OpenCodeNode,
        baseURLOverride: String? = nil,
        commonSettings: [String: Any]? = nil,
        keyPlacement: ManagedAPIKeyPlacement = .externalAuthFile
    ) -> [String: Any] {
        previewMergedConfig(
            node: node,
            baseURLOverride: baseURLOverride,
            commonSettings: commonSettings,
            pristine: pristineConfig(),
            keyPlacement: keyPlacement
        )
    }

    /// 预读 pristine 复用版：调用方（如预览页同时算行标注）已读过一次干净原文时传入，
    /// 避免同一次刷新里重复读盘 + 重复剥离。
    func previewMergedConfig(
        node: OpenCodeNode,
        baseURLOverride: String?,
        commonSettings: [String: Any]?,
        pristine: [String: Any],
        keyPlacement: ManagedAPIKeyPlacement = .externalAuthFile
    ) -> [String: Any] {
        injectManagedEntries(
            into: mergedBase(pristine: pristine, commonSettings: commonSettings),
            node: node,
            defaultModel: node.effectiveDefaultModel ?? "",
            baseURLOverride: baseURLOverride,
            keyPlacement: keyPlacement
        )
    }

    // MARK: - Launch Command Export

    /// 「复制启动命令」：导出与激活完全同口径的合并配置（不碰全局 opencode.json），
    /// 写到 ~/.config/aiusage/opencode-configs/<slug>.json（0600），返回
    /// `OPENCODE_CONFIG="<path>" opencode`。代理模式节点指向本地代理（需代理在运行）。
    func makeLaunchCommand(node: OpenCodeNode, commonSettings: [String: Any]? = nil) throws -> String {
        guard node.isComplete else { throw OpenCodeConfigError.nodeIncomplete }
        // 导出的是自带凭据的独立配置（0600），不依赖 auth.json 里有没有本节点的项。
        let merged = previewMergedConfig(
            node: node,
            baseURLOverride: node.proxyEnabled ? node.proxyLocalBaseURL : nil,
            commonSettings: commonSettings,
            keyPlacement: .inlineOptions
        )
        let home = fileManager.homeDirectoryForCurrentUser.path
        let dir = (home as NSString).appendingPathComponent(".config/aiusage/opencode-configs")
        let slug = node.providerSlug?.nilIfBlank ?? node.preferredSlug()
        let path = (dir as NSString).appendingPathComponent("\(slug).json")
        try writeObject(merged, toPath: path, restrictPermissions: true)
        return "OPENCODE_CONFIG=\"\(path)\" opencode"
    }

    /// 预览用的稳定序列化（与落盘格式一致：pretty + sortedKeys + 不转义斜杠）。
    static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Deactivation

    /// 还原 opencode.json：有备份则整文覆盖回原文并删除备份；无备份则剥离受管块（必要时删文件）。
    /// 同时清掉 auth.json 里的受管凭据——密钥不该在停用后留在盘上。
    func restore() throws {
        authStore.removeManagedCredentials()
        if hasBackup {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: backupPath))
                try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
                applyRestrictivePermissions(toPath: configPath)
                try? fileManager.removeItem(atPath: backupPath)
                openCodeConfigLog.info("opencode.json restored from backup")
            } catch {
                openCodeConfigLog.error("Failed to restore opencode.json: \(String(describing: error), privacy: .public)")
                throw OpenCodeConfigError.failedToRestore
            }
            return
        }

        // 无备份：可能是我们新建的文件（仅受管块），或本就未受管理。
        guard let root = try? readConfigObjectIfExists() else { return }
        let stripped = stripManagedEntries(from: root)
        let meaningfulKeys = stripped.keys.filter { $0 != "$schema" }
        if meaningfulKeys.isEmpty {
            try? fileManager.removeItem(atPath: configPath)
            openCodeConfigLog.info("opencode.json removed (was managed-only, no backup)")
        } else {
            try writeObject(stripped, toPath: configPath, restrictPermissions: true)
            openCodeConfigLog.info("opencode.json managed entries stripped (no backup)")
        }
    }

    // MARK: - Transform

    /// 剥离全部受管条目：`aiusage*` provider 键（空了则连 provider 键一起删）与指向它们的顶层 model。
    func stripManagedEntries(from root: [String: Any]) -> [String: Any] {
        var result = root
        if var provider = result["provider"] as? [String: Any] {
            for key in provider.keys where Self.isManagedProviderKey(key) {
                provider.removeValue(forKey: key)
            }
            if provider.isEmpty {
                result.removeValue(forKey: "provider")
            } else {
                result["provider"] = provider
            }
        }
        if let model = result["model"] as? String,
           let modelProvider = model.split(separator: "/", maxSplits: 1).first,
           Self.isManagedProviderKey(String(modelProvider)) {
            result.removeValue(forKey: "model")
        }
        return result
    }

    /// 配置是否已含本应用注入的受管条目（受管 provider 键或指向它的顶层 model）。
    private func managedKeysPresent(in root: [String: Any]) -> Bool {
        if let provider = root["provider"] as? [String: Any],
           provider.keys.contains(where: Self.isManagedProviderKey) {
            return true
        }
        if let model = root["model"] as? String,
           let modelProvider = model.split(separator: "/", maxSplits: 1).first {
            return Self.isManagedProviderKey(String(modelProvider))
        }
        return false
    }

    // MARK: - File IO

    /// 读取 opencode.json 为字典；文件不存在返回 nil，存在但非合法 JSON 对象时抛错。
    private func readConfigObjectIfExists() throws -> [String: Any]? {
        guard fileManager.fileExists(atPath: configPath) else { return nil }
        return try readObject(atPath: configPath)
    }

    private func readObject(atPath path: String) throws -> [String: Any]? {
        guard let data = fileManager.contents(atPath: path) else {
            throw OpenCodeConfigError.invalidJSON
        }
        if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return root
        }
        // JSONC 回退：去注释/尾随逗号后再解析（opencode.jsonc 及其逐字备份走这里）。
        let sanitized = JSONCSanitizer.sanitize(String(decoding: data, as: UTF8.self))
        guard let sanitizedData = sanitized.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: sanitizedData)) as? [String: Any] else {
            throw OpenCodeConfigError.invalidJSON
        }
        return root
    }

    /// 逐字复制文件（保真保留注释/格式），用于把 opencode.jsonc 原文备份为「真相源」。
    private func copyFileVerbatim(from source: String, to destination: String) throws {
        let dir = (destination as NSString).deletingLastPathComponent
        do {
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try Data(contentsOf: URL(fileURLWithPath: source))
            try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
        } catch {
            openCodeConfigLog.error("Failed to back up \((source as NSString).lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            throw OpenCodeConfigError.failedToWriteFile
        }
    }

    /// 写入受管配置：opencode.jsonc 时以「逐字备份原文」为基底做保注释的结构化文本注入
    /// （issue #42——接管期间也保留用户注释）；JSONCEditor 解析失败/自校验不过，或非 JSONC 文件时，
    /// 回退为无注释结构化写回（语义恒正确）。
    private func writeManagedRoot(_ root: [String: Any]) throws {
        if usesJSONC,
           let baseText = try? String(contentsOfFile: backupPath, encoding: .utf8),
           let patched = JSONCEditor.merge(baseText: baseText, target: root) {
            try writeText(patched, toPath: configPath, restrictPermissions: true)
            return
        }
        try writeObject(root, toPath: configPath, restrictPermissions: true)
    }

    private func writeText(_ text: String, toPath path: String, restrictPermissions: Bool = false) throws {
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            if restrictPermissions {
                applyRestrictivePermissions(toPath: path)
            }
        } catch {
            openCodeConfigLog.error("Failed to write \((path as NSString).lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            throw OpenCodeConfigError.failedToWriteFile
        }
    }

    private func writeObject(_ object: [String: Any], toPath path: String, restrictPermissions: Bool = false) throws {
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            if restrictPermissions {
                applyRestrictivePermissions(toPath: path)
            }
        } catch {
            openCodeConfigLog.error("Failed to write \((path as NSString).lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            throw OpenCodeConfigError.failedToWriteFile
        }
    }

    /// 配置可能含 API Key，写入后恢复 0600 权限。
    private func applyRestrictivePermissions(toPath path: String) {
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
