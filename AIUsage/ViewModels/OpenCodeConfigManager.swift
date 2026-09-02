import Foundation
import CryptoKit
import os.log
import QuotaBackend

// MARK: - OpenCode Config Manager
// 管理 resolver 选定的 OpenCode 专用全局层：注入 provider["aiusage-<节点>"] 块
// （npm 按节点协议选择 @ai-sdk/openai-compatible|anthropic|openai + baseURL/apiKey/models），
// 并把顶层 model 指向 "aiusage-<节点>/<模型>"；停用时从备份完整还原原文。
// 直连模式 OpenCode 原生直连上游；代理模式经 baseURLOverride 指向本地透传代理（路线 B）。
// provider id 按节点区分（node.managedProviderId）——opencode.db 的消息会携带它作为
// providerID，Phase 1 统计据此把用量/费用归因到具体节点。
//
// 数据来源: OpenCode 按 config.json → opencode.json → opencode.jsonc 合并全局层；
// 写入目标: 最高优先级的专用全局层（优先现有 opencode.jsonc，其次 opencode.json，
//          两者都缺失时创建 opencode.jsonc）。低优先级 config.json 只读不改。
// 工作方式: 首次接管把「干净原文逐字备份」并持久化固定目标（备份即真相源，重复激活幂等），
//          还原始终回到同一文件，不因之后出现其它配置层而改道。
// 密钥: 直连模式的上游 API Key 走 OpenCode 官方位置 ~/.local/share/opencode/auth.json（0600，
//       见 OpenCodeAuthStore），受管块不写明文 apiKey；auth.json 写不动时回退内联（issue #65）。
// JSONC: 接管 opencode.jsonc 时——逐字备份原文 → 以备份原文为基底，用 JSONCEditor 做「保注释的
//        结构化文本注入」（仅注入/替换 provider[受管键]、顶层 model、$schema），输出仍是带注释的
//        合法 JSONC（OpenCode 能解析）。即接管期间用户注释也始终保留（issue #42）。
//        JSONCEditor 解析失败或写后自校验不过时，回退为无注释结构化写回（保证语义正确）。
//        停用时从备份完整还原。
// 安全: 写入的配置含 API Key，落盘后恢复 0600 权限。

private let openCodeConfigLog = Logger(subsystem: "com.aiusage.desktop", category: "OpenCodeConfig")

// MARK: - Stable takeover state

/// A persisted binding between one AIUsage takeover and one concrete OpenCode file.
/// It deliberately outlives the resolver: creating/deleting a .jsonc file while a
/// takeover is active must never silently redirect restore to another file.
private struct OpenCodeTakeoverSession: Codable {
    let version: Int
    let id: UUID
    let targetPath: String
    let targetFormat: OpenCodeConfigFormat
    var backupPath: String?
    var originalExists: Bool
    var originalHash: String?
    var originalPermissions: UInt16?
    var managedHash: String?
    let createdAt: Date
}

enum OpenCodeConfigManagementState: Equatable {
    case unmanaged
    case managed
    case targetMissing
    case externallyModified
    case precedenceChanged(activeFileName: String)
    case overriddenByLaterLayer
    case invalidConfigurationLayer
}

enum OpenCodeConfigError: LocalizedError {
    case invalidJSON
    case nodeIncomplete
    case failedToWriteFile
    case failedToRestore
    case externalModification
    case effectiveConfigOverridden

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
            return AppSettings.shared.t("Failed to write the OpenCode configuration.", "写入 OpenCode 配置失败。")
        case .failedToRestore:
            return AppSettings.shared.t(
                "OpenCode configuration could not be restored safely because the managed file changed outside AIUsage.",
                "OpenCode 配置在 AIUsage 外部发生了修改，已停止自动还原以避免覆盖用户内容。"
            )
        case .externalModification:
            return AppSettings.shared.t(
                "OpenCode configuration changed outside AIUsage. Review the file before applying or restoring it.",
                "OpenCode 配置已在 AIUsage 外部修改，请检查文件后再应用或还原。"
            )
        case .effectiveConfigOverridden:
            return AppSettings.shared.t(
                "A later OpenCode configuration layer overrides the AIUsage route. Review OPENCODE_CONFIG, OPENCODE_CONFIG_DIR, OPENCODE_CONFIG_CONTENT, or project configuration before activating it.",
                "后加载的 OpenCode 配置层覆盖了 AIUsage 路由。请先检查 OPENCODE_CONFIG、OPENCODE_CONFIG_DIR、OPENCODE_CONFIG_CONTENT 或项目配置。"
            )
        }
    }
}

final class OpenCodeConfigManager {
    static let shared = OpenCodeConfigManager()

    /// 受管 provider id 前缀。OpenCode 内置 provider 无此前缀，不冲突。
    /// 实际键为 `aiusage-<节点 slug>`（兼容剥离早期固定的 `aiusage`）。
    nonisolated static let providerIdPrefix = "aiusage"

    /// 是否为本应用注入的受管 provider 键。
    nonisolated static func isManagedProviderKey(_ key: String) -> Bool {
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
    private var session: OpenCodeTakeoverSession?

    private init() {
        session = nil
        session = loadSession() ?? adoptLegacySessionIfNeeded()
    }

    // MARK: - Paths

    var configDirectory: String {
        configResolution.configDirectory
    }

    /// Resolver 当前发现的全局配置上下文。所有展示和读写均以此对象为入口。
    var configResolution: OpenCodeConfigResolution {
        OpenCodeConfigResolver().resolve()
    }

    /// 当前接管目标；有活动 session 时必须使用 session 固定路径。
    var configPath: String {
        session?.targetPath ?? configResolution.managementTarget.path
    }

    var configFileName: String { (configPath as NSString).lastPathComponent }
    var configDisplayPath: String {
        let home = fileManager.homeDirectoryForCurrentUser.path
        return configPath.hasPrefix(home) ? "~" + configPath.dropFirst(home.count) : configPath
    }
    var configFormat: OpenCodeConfigFormat {
        session?.targetFormat ?? configResolution.managementTarget.format
    }
    var lowerPriorityConfigFileNames: [String] {
        guard configResolution.managementTarget.path == configPath else { return [] }
        return configResolution.lowerPriorityGlobalLayers.map { $0.fileName }
    }

    private var sessionManifestPath: String {
        let home = fileManager.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/opencode-takeover.json")
    }

    private var backupRoot: String {
        let home = fileManager.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/opencode-takeover-backup")
    }

    private var backupPath: String? { session?.backupPath }

    // MARK: - State

    /// 当前接管目标是否为 JSONC；读写期间保留注释与排版。
    var usesJSONC: Bool {
        configFormat == .jsonc
    }

    /// 当前管理目标是否已注入受管节点。
    var isManaged: Bool {
        guard let root = try? readConfigObjectIfExists() else { return false }
        guard let provider = root["provider"] as? [String: Any] else { return false }
        return provider.keys.contains(where: Self.isManagedProviderKey)
    }

    /// 是否存在我们的备份（代表接管态/未正常还原）。
    var hasBackup: Bool {
        guard let backupPath else { return false }
        return fileManager.fileExists(atPath: backupPath)
    }

    var managementState: OpenCodeConfigManagementState {
        guard let session else { return .unmanaged }
        guard let data = fileManager.contents(atPath: session.targetPath) else {
            return .targetMissing
        }
        if let managedHash = session.managedHash, sha256(data) != managedHash {
            return .externallyModified
        }
        let currentlyPreferred = configResolution.managementTarget.path
        if currentlyPreferred != session.targetPath {
            return .precedenceChanged(activeFileName: configResolution.managementTarget.fileName)
        }
        let resolver = OpenCodeConfigResolver()
        guard let target = try? readObject(atPath: session.targetPath),
              let effective = resolver.readEffectiveObject() else {
            return .invalidConfigurationLayer
        }
        guard managedKeysPresent(in: target) else {
            return .externallyModified
        }
        if !managedProjectionMatches(target: target, effective: effective) {
            return .overriddenByLaterLayer
        }
        return .managed
    }

    /// Explicitly rebase the takeover on the current file after the user has
    /// reviewed an external edit. Managed provider keys are removed from the new
    /// pristine snapshot; all other user content becomes the new restore baseline.
    func acceptExternalChanges() throws {
        guard let previousSession = session else {
            throw OpenCodeConfigError.invalidJSON
        }

        // Deletion can also be an intentional external edit. Accepting it makes
        // "no original file" the new restore baseline; the caller then reapplies
        // the active route to recreate only AIUsage's managed content.
        guard let data = fileManager.contents(atPath: configPath) else {
            let oldBackup = previousSession.backupPath
            do {
                try withFileTransaction(paths: [sessionManifestPath] + [oldBackup].compactMap { $0 }) {
                    try updateSession {
                        $0.backupPath = nil
                        $0.originalExists = false
                        $0.originalHash = nil
                        $0.originalPermissions = nil
                        $0.managedHash = nil
                    }
                    if let oldBackup { try fileManager.removeItem(atPath: oldBackup) }
                }
            } catch {
                session = previousSession
                throw error
            }
            return
        }
        guard let root = try readObject(atPath: configPath) else {
            throw OpenCodeConfigError.invalidJSON
        }
        let clean = stripManagedEntries(from: root)
        let path = backupPath ?? (backupRoot as NSString)
            .appendingPathComponent("\(previousSession.id.uuidString).original")
        let originalPermissions = permissions(atPath: configPath)
        let cleanedText: String?
        if usesJSONC, let text = String(data: data, encoding: .utf8) {
            cleanedText = JSONCEditor.merge(baseText: text, target: clean)
        } else {
            cleanedText = nil
        }
        try fileManager.createDirectory(atPath: backupRoot, withIntermediateDirectories: true)

        do {
            try withFileTransaction(paths: [path, configPath, sessionManifestPath]) {
                if let cleanedText {
                    try writeText(cleanedText, toPath: path, restrictPermissions: true)
                    try writeText(cleanedText, toPath: configPath, restrictPermissions: true)
                } else {
                    try writeObject(clean, toPath: path, restrictPermissions: true)
                    try writeObject(clean, toPath: configPath, restrictPermissions: true)
                }

                try updateSession {
                    $0.backupPath = path
                    $0.originalExists = true
                    $0.originalHash = fileManager.contents(atPath: path).map(sha256)
                    $0.originalPermissions = originalPermissions
                    $0.managedHash = fileManager.contents(atPath: configPath).map(sha256)
                }
            }
        } catch {
            session = previousSession
            throw error
        }
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
        let hadSession = session != nil
        do {
            let pristine = try establishBackupAndLoadPristine()
            try withManagedFilesTransaction {
                // 密钥与配置属于同一次事务。代理模式下清掉残留直连凭据，避免 auth.json 覆盖 client key。
                let directAPIKey = baseURLOverride == nil ? node.apiKey.nilIfBlank : nil
                let credentials = directAPIKey.map { [node.managedProviderId: $0] } ?? [:]
                let credentialsStored = authStore.syncManagedCredentials(credentials)
                let keyPlacement: ManagedAPIKeyPlacement = credentialsStored ? .externalAuthFile : .inlineOptions
                if !credentialsStored {
                    openCodeConfigLog.error("auth.json write failed, falling back to inline apiKey in opencode config")
                }

                let root = injectManagedEntries(
                    into: mergedBase(pristine: pristine, commonSettings: commonSettings),
                    node: node,
                    defaultModel: defaultModel,
                    baseURLOverride: baseURLOverride,
                    keyPlacement: keyPlacement
                )

                try writeManagedRoot(root)
                try verifyEffectiveManagedProjection(target: root)
                try recordManagedHash()
                openCodeConfigLog.info("opencode config managed provider injected (provider=\(node.managedProviderId, privacy: .public), models=\(node.models.count), jsonc=\(self.usesJSONC, privacy: .public), keyInAuthFile=\(keyPlacement == .externalAuthFile, privacy: .public))")
            }
        } catch {
            if !hadSession { discardSessionFiles() }
            throw error
        }
    }

    // MARK: - Global Unified Proxy Activation

    /// 全局统一代理受管 provider 键：固定为裸前缀 `aiusage`（per-node 受管键恒为 `aiusage-<slug>`，
    /// 永不与之冲突）。统计页据此把全局模式流量与 per-node 流量区分开。
    static let globalProviderId = providerIdPrefix

    /// 接管 OpenCode 专用全局层为「全局统一代理」固定入口：单一受管 provider 指向常驻代理端口，
    /// 仅暴露一个固定虚拟模型；切换激活节点只在代理内热替换上游，配置层不变。
    /// - interface: 选定接口协议（决定 npm 包：openai-compatible / anthropic / openai）。
    /// - baseURL: 含 /v1 的本地代理地址（SDK 在其后拼 /chat/completions、/messages、/responses）。
    /// - clientKey: 固定 client key（写入受管块 apiKey；代理据此鉴权）。
    /// - virtualModel: 固定虚拟模型名（CLI 永远发它，由代理改写为激活节点真实模型）。
    func activateGlobal(interface: OpenCodeProtocol, baseURL: String, clientKey: String, virtualModel: String) throws {
        let model = virtualModel.nilIfBlank ?? "model"
        let hadSession = session != nil
        do {
            let pristine = try establishBackupAndLoadPristine()
            try withManagedFilesTransaction {
                guard authStore.removeManagedCredentials() else { throw OpenCodeConfigError.failedToWriteFile }

                var root = pristine
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
                try verifyEffectiveManagedProjection(target: root)
                try recordManagedHash()
                openCodeConfigLog.info("opencode config global proxy provider injected (interface=\(interface.rawValue, privacy: .public), model=\(model, privacy: .public), jsonc=\(self.usesJSONC, privacy: .public))")
            }
        } catch {
            if !hadSession { discardSessionFiles() }
            throw error
        }
    }

    /// 首次接管时建立「备份即真相源」并返回干净原文（已剥离受管块）。
    /// - 已有备份：以备份为准（重复激活/切换节点幂等，不把受管文件当原文）。
    /// - 首次接管且无残留受管块：逐字复制原文为备份，保真保留注释/格式（opencode.jsonc 还原必需）。
    /// - 首次接管但残留旧受管块（异常）：剥离后写回作备份（此罕见路径不保真注释，可接受）。
    private func establishBackupAndLoadPristine() throws -> [String: Any] {
        try validateVisibleLayers()
        let active = try ensureSession()
        guard let backupPath = active.backupPath,
              let pristine = try readObject(atPath: backupPath) else { return [:] }
        return stripManagedEntries(from: pristine)
    }

    private func validateVisibleLayers() throws {
        let resolution = configResolution
        for layer in resolution.globalLayers where layer.exists {
            guard try readObject(atPath: layer.path) != nil else {
                throw OpenCodeConfigError.invalidJSON
            }
        }
        if let path = resolution.customConfigPath,
           !resolution.globalLayers.contains(where: { $0.path == path }),
           fileManager.fileExists(atPath: path),
           try readObject(atPath: path) == nil {
            throw OpenCodeConfigError.invalidJSON
        }
        for layer in resolution.customDirectoryLayers where layer.exists {
            guard try readObject(atPath: layer.path) != nil else {
                throw OpenCodeConfigError.invalidJSON
            }
        }
        if resolution.inlineConfigParseStatus == .invalid {
            throw OpenCodeConfigError.invalidJSON
        }
    }

    /// Create and persist a takeover session exactly once. The session binds the
    /// operation to one path and one original byte snapshot.
    private func ensureSession() throws -> OpenCodeTakeoverSession {
        if let session {
            if let managedHash = session.managedHash {
                guard let data = fileManager.contents(atPath: session.targetPath),
                      sha256(data) == managedHash else {
                    throw OpenCodeConfigError.externalModification
                }
            }
            return session
        }

        let target = configResolution.managementTarget
        let targetPath = target.path
        let originalExists = fileManager.fileExists(atPath: targetPath)
        var backupPath: String?
        var originalHash: String?
        var originalPermissions: UInt16?

        if originalExists {
            guard let data = fileManager.contents(atPath: targetPath),
                  let _ = try? readObject(atPath: targetPath) else {
                throw OpenCodeConfigError.invalidJSON
            }
            originalHash = sha256(data)
            originalPermissions = permissions(atPath: targetPath)
            let id = UUID()
            let path = (backupRoot as NSString).appendingPathComponent("\(id.uuidString).original")
            let current = try readObject(atPath: targetPath) ?? [:]
            try fileManager.createDirectory(atPath: backupRoot, withIntermediateDirectories: true)
            if managedKeysPresent(in: current) {
                try writeObject(stripManagedEntries(from: current), toPath: path, restrictPermissions: true)
            } else {
                try copyFileVerbatim(from: targetPath, to: path)
            }
            backupPath = path
            let created = OpenCodeTakeoverSession(
                version: 1, id: id, targetPath: targetPath, targetFormat: target.format,
                backupPath: backupPath, originalExists: true, originalHash: originalHash,
                originalPermissions: originalPermissions, managedHash: nil, createdAt: Date()
            )
            do {
                try saveSession(created)
                session = created
            } catch {
                try? fileManager.removeItem(atPath: path)
                throw error
            }
            return created
        }

        let created = OpenCodeTakeoverSession(
            version: 1, id: UUID(), targetPath: targetPath, targetFormat: target.format,
            backupPath: nil, originalExists: false, originalHash: nil,
            originalPermissions: nil, managedHash: nil, createdAt: Date()
        )
        try saveSession(created)
        session = created
        return created
    }

    private func loadSession() -> OpenCodeTakeoverSession? {
        guard let data = fileManager.contents(atPath: sessionManifestPath) else { return nil }
        return try? JSONDecoder().decode(OpenCodeTakeoverSession.self, from: data)
    }

    /// Migrate legacy sidecar backups without changing the user's file. The old
    /// suffix itself tells us which target was managed, so no extension probing is
    /// needed during the migration.
    private func adoptLegacySessionIfNeeded() -> OpenCodeTakeoverSession? {
        let candidates = [
            (configDirectory as NSString).appendingPathComponent("opencode.jsonc.aiusage.bak"),
            (configDirectory as NSString).appendingPathComponent("opencode.json.aiusage.bak")
        ]
        guard let legacyBackup = candidates.first(where: { fileManager.fileExists(atPath: $0) }) else { return nil }
        let target = legacyBackup.replacingOccurrences(of: ".aiusage.bak", with: "")
        let format: OpenCodeConfigFormat = target.hasSuffix(".jsonc") ? .jsonc : .json
        let originalData = fileManager.contents(atPath: legacyBackup)
        let created = OpenCodeTakeoverSession(
            version: 1, id: UUID(), targetPath: target, targetFormat: format,
            backupPath: legacyBackup, originalExists: originalData != nil,
            originalHash: originalData.map(Self.sha256), originalPermissions: permissions(atPath: legacyBackup),
            managedHash: fileManager.contents(atPath: target).map(Self.sha256), createdAt: Date()
        )
        try? saveSession(created)
        return created
    }

    private func saveSession(_ session: OpenCodeTakeoverSession) throws {
        let directory = (sessionManifestPath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(session)
        try data.write(to: URL(fileURLWithPath: sessionManifestPath), options: .atomic)
        applyRestrictivePermissions(toPath: sessionManifestPath)
    }

    private func updateSession(_ update: (inout OpenCodeTakeoverSession) -> Void) throws {
        guard var current = session else { return }
        update(&current)
        try saveSession(current)
        session = current
    }

    private func recordManagedHash() throws {
        guard let data = fileManager.contents(atPath: configPath) else { throw OpenCodeConfigError.failedToWriteFile }
        try updateSession { $0.managedHash = sha256(data) }
    }

    private struct FileSnapshot {
        let path: String
        let data: Data?
        let permissions: NSNumber?
    }

    /// Keep config and auth changes all-or-nothing. A failed activation must not
    /// leave a provider block without its credential, or vice versa.
    private func withManagedFilesTransaction(_ operation: () throws -> Void) throws {
        try withFileTransaction(paths: [configPath, authStore.path], operation)
    }

    private func withFileTransaction(paths: [String], _ operation: () throws -> Void) throws {
        let snapshots = paths.map { path -> FileSnapshot in
            FileSnapshot(
                path: path,
                data: fileManager.contents(atPath: path),
                permissions: (try? fileManager.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber
            )
        }
        do {
            try operation()
        } catch {
            for snapshot in snapshots {
                if let data = snapshot.data {
                    let directory = (snapshot.path as NSString).deletingLastPathComponent
                    try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    try? data.write(to: URL(fileURLWithPath: snapshot.path), options: .atomic)
                    if let permissions = snapshot.permissions {
                        try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: snapshot.path)
                    }
                } else {
                    try? fileManager.removeItem(atPath: snapshot.path)
                }
            }
            throw error
        }
    }

    private func discardSessionFiles() {
        if let backupPath = session?.backupPath { try? fileManager.removeItem(atPath: backupPath) }
        try? fileManager.removeItem(atPath: sessionManifestPath)
        session = nil
    }

    nonisolated private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sha256(_ data: Data) -> String { Self.sha256(data) }

    private func permissions(atPath path: String) -> UInt16? {
        guard let value = try? fileManager.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber else { return nil }
        return UInt16(truncating: value)
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

    /// 当前全局层的合并结果。接管目标使用备份中的原始内容，其他低优先级层按
    /// OpenCode 的真实顺序合并；只用于预览/独立启动配置，不会写回并扁平化用户层级。
    func pristineConfig() -> [String: Any] {
        var merged: [String: Any] = [:]
        let resolver = OpenCodeConfigResolver()
        let resolution = resolver.resolve()
        let layers = resolution.globalLayers
        for layer in layers where layer.exists || layer.path == configPath {
            let object: [String: Any]?
            if layer.path == configPath, let backupPath, hasBackup {
                object = try? readObject(atPath: backupPath)
            } else if fileManager.fileExists(atPath: layer.path) {
                object = try? readObject(atPath: layer.path)
            } else {
                object = nil
            }
            if let object {
                merged = GlobalConfig.deepMerge(base: merged, override: stripManagedEntries(from: object))
            }
        }
        if let customPath = resolution.customConfigPath,
           !layers.contains(where: { $0.path == customPath }),
           fileManager.fileExists(atPath: customPath),
           let custom = try? readObject(atPath: customPath) {
            merged = GlobalConfig.deepMerge(base: merged, override: stripManagedEntries(from: custom))
        }
        for layer in resolution.customDirectoryLayers where layer.exists {
            if let object = try? readObject(atPath: layer.path) {
                merged = GlobalConfig.deepMerge(base: merged, override: stripManagedEntries(from: object))
            }
        }
        if let inline = resolver.readInlineConfigObject() {
            merged = GlobalConfig.deepMerge(base: merged, override: stripManagedEntries(from: inline))
        }
        return stripManagedEntries(from: merged)
    }

    /// 编辑器 JSON 预览：激活该节点后的完整配置（基于备份/当前原文合成，不落盘）。
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

    /// 「复制启动命令」：导出与激活完全同口径的合并配置（不修改全局配置层），
    /// 写到 ~/.config/aiusage/opencode-configs/<slug>.json（0600），返回
    /// 同时屏蔽项目、目录和内联覆盖层，保证该命令固定使用导出的受管路由。
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
        return "OPENCODE_DISABLE_PROJECT_CONFIG=1 OPENCODE_CONFIG_DIR= OPENCODE_CONFIG_CONTENT= OPENCODE_CONFIG=\"\(path)\" opencode"
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

    /// 还原当前接管 session 绑定的文件；不根据文件扩展名重新选择目标。
    /// 同时清掉 auth.json 里的受管凭据——密钥不该在停用后留在盘上。
    func restore() throws {
        try restore(forceExternalChanges: false)
    }

    /// Restore after the user explicitly chose to discard edits made outside
    /// AIUsage. The normal restore path remains fail-closed.
    func restoreDiscardingExternalChanges() throws {
        try restore(forceExternalChanges: true)
    }

    private func restore(forceExternalChanges: Bool) throws {
        guard let active = session else {
            guard authStore.removeManagedCredentials() else {
                throw OpenCodeConfigError.failedToRestore
            }
            guard let root = try? readConfigObjectIfExists() else { return }
            let stripped = stripManagedEntries(from: root)
            let meaningfulKeys = stripped.keys.filter { $0 != "$schema" }
            if meaningfulKeys.isEmpty {
                try? fileManager.removeItem(atPath: configPath)
            } else {
                try writeCleanRoot(stripped, toPath: configPath)
            }
            return
        }

        let targetExists = fileManager.fileExists(atPath: active.targetPath)
        if !targetExists {
            guard forceExternalChanges else { throw OpenCodeConfigError.externalModification }
            if active.originalExists, active.backupPath != nil {
                try restoreFromSession(active)
            } else {
                try finishManagedOnlyRestore(active)
            }
            return
        }

        if let managedHash = active.managedHash {
            guard let data = fileManager.contents(atPath: active.targetPath) else {
                throw OpenCodeConfigError.failedToRestore
            }
            if sha256(data) != managedHash, !forceExternalChanges {
                throw OpenCodeConfigError.externalModification
            }
        }

        if active.backupPath != nil, active.originalExists {
            try restoreFromSession(active)
            return
        }

        try finishManagedOnlyRestore(active)
    }

    private func restoreFromSession(_ active: OpenCodeTakeoverSession) throws {
        guard let backupPath = active.backupPath, active.originalExists else {
            throw OpenCodeConfigError.failedToRestore
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: backupPath))
            try withFileTransaction(paths: [active.targetPath, authStore.path, sessionManifestPath, backupPath]) {
                let directory = (active.targetPath as NSString).deletingLastPathComponent
                try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: active.targetPath), options: .atomic)
                guard fileManager.contents(atPath: active.targetPath) == data else {
                    throw OpenCodeConfigError.failedToRestore
                }
                if let permissions = active.originalPermissions {
                    try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: active.targetPath)
                }
                guard authStore.removeManagedCredentials() else {
                    throw OpenCodeConfigError.failedToRestore
                }
                try fileManager.removeItem(atPath: sessionManifestPath)
                try fileManager.removeItem(atPath: backupPath)
            }
            session = nil
            openCodeConfigLog.info("OpenCode config restored from takeover session")
        } catch let error as OpenCodeConfigError {
            throw error
        } catch {
            openCodeConfigLog.error("Failed to restore OpenCode config: \(String(describing: error), privacy: .public)")
            throw OpenCodeConfigError.failedToRestore
        }
    }

    private func finishManagedOnlyRestore(_ active: OpenCodeTakeoverSession) throws {
        do {
            try withFileTransaction(paths: [active.targetPath, authStore.path, sessionManifestPath]) {
                if let root = try readConfigObjectIfExists() {
                    let stripped = stripManagedEntries(from: root)
                    let meaningfulKeys = stripped.keys.filter { $0 != "$schema" }
                    if meaningfulKeys.isEmpty {
                        try fileManager.removeItem(atPath: active.targetPath)
                    } else {
                        try writeCleanRoot(stripped, toPath: active.targetPath)
                    }
                }
                guard authStore.removeManagedCredentials() else {
                    throw OpenCodeConfigError.failedToRestore
                }
                try fileManager.removeItem(atPath: sessionManifestPath)
            }
            session = nil
            openCodeConfigLog.info("OpenCode managed-only config restored")
        } catch {
            session = active
            throw OpenCodeConfigError.failedToRestore
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

    private func verifyEffectiveManagedProjection(target: [String: Any]) throws {
        guard let effective = OpenCodeConfigResolver().readEffectiveObject(),
              managedProjectionMatches(target: target, effective: effective) else {
            throw OpenCodeConfigError.effectiveConfigOverridden
        }
    }

    private func managedProjectionMatches(target: [String: Any], effective: [String: Any]) -> Bool {
        let targetProvider = target["provider"] as? [String: Any] ?? [:]
        let effectiveProvider = effective["provider"] as? [String: Any] ?? [:]
        for (key, value) in targetProvider where Self.isManagedProviderKey(key) {
            guard let effectiveValue = effectiveProvider[key],
                  canonicalJSON(value) == canonicalJSON(effectiveValue) else { return false }
        }
        if let model = target["model"] as? String,
           let provider = model.split(separator: "/", maxSplits: 1).first,
           Self.isManagedProviderKey(String(provider)) {
            return effective["model"] as? String == model
        }
        return true
    }

    private func canonicalJSON(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    // MARK: - File IO

    /// 读取当前管理目标；文件不存在返回 nil，存在但非合法 JSON/JSONC 对象时抛错。
    private func readConfigObjectIfExists() throws -> [String: Any]? {
        guard fileManager.fileExists(atPath: configPath) else { return nil }
        return try readObject(atPath: configPath)
    }

    private func readObject(atPath path: String) throws -> [String: Any]? {
        guard let data = fileManager.contents(atPath: path) else {
            throw OpenCodeConfigError.invalidJSON
        }
        guard let text = String(data: data, encoding: .utf8),
              let root = JSONCEditor.parseObject(text) else {
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

    /// 写入受管配置：opencode.jsonc 时优先以当前已验证的受管文件为基底，
    /// 没有当前文件时再用逐字备份做保注释的结构化文本注入。
    /// （issue #42——接管期间也保留用户注释）；JSONCEditor 解析失败/自校验不过，或非 JSONC 文件时，
    /// 回退为无注释结构化写回（语义恒正确）。
    private func writeManagedRoot(_ root: [String: Any]) throws {
        let jsoncBasePath = fileManager.fileExists(atPath: configPath) ? configPath : backupPath
        if usesJSONC,
           let jsoncBasePath,
           let baseText = try? String(contentsOfFile: jsoncBasePath, encoding: .utf8),
           let patched = JSONCEditor.merge(baseText: baseText, target: root) {
            try writeText(patched, toPath: configPath, restrictPermissions: true)
            return
        }
        try writeObject(root, toPath: configPath, restrictPermissions: true)
    }

    private func writeCleanRoot(_ root: [String: Any], toPath path: String) throws {
        if path.hasSuffix(".jsonc"),
           let text = try? String(contentsOfFile: path, encoding: .utf8),
           let patched = JSONCEditor.merge(baseText: text, target: root) {
            try writeText(patched, toPath: path, restrictPermissions: true)
        } else {
            try writeObject(root, toPath: path, restrictPermissions: true)
        }
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
