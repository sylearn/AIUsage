import Foundation
import SwiftUI
import Combine
import os.log
import SQLite3
import CryptoKit
import QuotaBackend

// MARK: - Node Profile Store
// File-based persistence for NodeProfile objects. Each profile is a standalone JSON file
// at ~/.config/aiusage/profiles/<id>.json. Supports CRUD, batch import/export, and
// migration from the legacy UserDefaults-based ProxyConfiguration storage.

private let storeLog = Logger(subsystem: "com.aiusage.desktop", category: "NodeProfileStore")

@MainActor
class NodeProfileStore: ObservableObject {
    static let shared = NodeProfileStore()

    @Published var profiles: [NodeProfile] = []
    @Published var activatedProfileId: String?
    @Published var globalConfig: GlobalConfig = .empty
    @Published var codexGlobalConfig: CodexGlobalConfig = .empty

    private let fileManager = FileManager.default

    static var profilesDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/profiles")
    }

    static var globalConfigPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/global-config.json")
    }

    static var codexGlobalConfigPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/codex-global-config.json")
    }

    // MARK: - Lifecycle

    init() {
        ensureDirectoryExists()
        migrateFromUserDefaultsIfNeeded()
        loadAll()
        loadGlobalConfig()
        loadCodexGlobalConfig()
        restoreActivatedId()
    }

    // MARK: - Directory

    private func ensureDirectoryExists() {
        let dir = Self.profilesDirectory
        if !fileManager.fileExists(atPath: dir) {
            do {
                try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            } catch {
                storeLog.error("Failed to create profiles directory: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Load

    func loadAll() {
        let dir = Self.profilesDirectory
        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir) else {
            storeLog.info("No profiles directory or empty")
            return
        }

        var loaded: [NodeProfile] = []
        for entry in entries where entry.hasSuffix(".json") {
            let path = (dir as NSString).appendingPathComponent(entry)
            guard let data = fileManager.contents(atPath: path) else { continue }
            do {
                let profile = try NodeProfile.fromFileData(data)
                loaded.append(profile)
            } catch {
                storeLog.error("Failed to load profile \(entry, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        loaded.sort {
            if $0.metadata.sortOrder != $1.metadata.sortOrder {
                return $0.metadata.sortOrder < $1.metadata.sortOrder
            }
            return $0.metadata.createdAt < $1.metadata.createdAt
        }
        profiles = loaded
    }

    // MARK: - CRUD

    @discardableResult
    func save(_ profile: NodeProfile) -> Bool {
        ensureDirectoryExists()
        var p = profile
        // Codex 节点的 settings（Claude settings.json blob）运行时不使用，落盘统一清空保持干净；
        // 也顺带清理历史档案里残留的 Claude blob（下次保存即收敛）。
        if p.metadata.nodeType.isCodex, !p.settings.isEmpty {
            p.settings = [:]
        }
        let isNew = !profiles.contains(where: { $0.id == p.id })
        if isNew && p.metadata.sortOrder == Int.max {
            // 新建/复制节点默认排到列表最前（取最小 sortOrder - 1）。
            let minOrder = profiles.map { $0.metadata.sortOrder }.min() ?? 0
            p.metadata.sortOrder = minOrder - 1
        }
        let path = filePath(for: p.id)
        do {
            let data = try p.toFileData()
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            if let index = profiles.firstIndex(where: { $0.id == p.id }) {
                profiles[index] = p
            } else {
                profiles.insert(p, at: 0)
            }
            return true
        } catch {
            storeLog.error("Failed to save profile \(profile.metadata.name, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func delete(_ id: String) {
        let path = filePath(for: id)
        try? fileManager.removeItem(atPath: path)
        profiles.removeAll { $0.id == id }
        if activatedProfileId == id {
            activatedProfileId = nil
            saveActivatedId()
        }
    }

    func profile(for id: String) -> NodeProfile? {
        profiles.first { $0.id == id }
    }

    func duplicate(_ id: String) -> NodeProfile? {
        guard let source = profile(for: id) else { return nil }
        var copy = source
        copy.metadata.id = UUID().uuidString
        copy.metadata.name = source.metadata.name + " (Copy)"
        copy.metadata.createdAt = Date()
        copy.metadata.lastUsedAt = nil
        copy.metadata.sortOrder = Int.max

        if copy.metadata.proxy.needsProxyProcess(nodeType: copy.metadata.nodeType) {
            copy.metadata.proxy.port = nextAvailablePort()
            copy.syncEnvFromProxy()
        }

        if save(copy) { return copy }
        return nil
    }

    func move(fromId: String, toIndex: Int) {
        guard let fromIndex = profiles.firstIndex(where: { $0.id == fromId }) else { return }
        let clamped = min(max(toIndex, 0), profiles.count)
        guard fromIndex != clamped, fromIndex != clamped - 1 else { return }
        let item = profiles.remove(at: fromIndex)
        let insertAt = clamped > fromIndex ? clamped - 1 : clamped
        profiles.insert(item, at: insertAt)
        persistSortOrder()
    }

    /// 增量持久化排序：仅把 `sortOrder` 与新下标不一致的节点落盘，避免每次拖拽全量重写。
    private func persistSortOrder() {
        for index in profiles.indices where profiles[index].metadata.sortOrder != index {
            profiles[index].metadata.sortOrder = index
            save(profiles[index])
        }
    }

    // MARK: - Activation State

    private static let activatedIdKey = "proxyActivatedConfigId"

    func saveActivatedId() {
        UserDefaults.standard.set(activatedProfileId, forKey: Self.activatedIdKey)
    }

    private func restoreActivatedId() {
        let shouldRestore = AppSettings.shared.proxyAutoRestoreOnLaunch
        activatedProfileId = shouldRestore
            ? UserDefaults.standard.string(forKey: Self.activatedIdKey)
            : nil
    }

    // MARK: - Batch Import

    struct ImportResult {
        var succeeded: Int = 0
        var updated: Int = 0
        var failed: Int = 0
        var skipped: Int = 0
        var importedGlobalConfig = false
        var importedCodexGlobalConfig = false
        var skippedGlobalConfig = false
        var errors: [String] = []
    }

    // 导出/导入用的「通用配置」文件名（家族区分、语义直白）。
    // 与磁盘内部存储路径（global-config.json / codex-global-config.json）解耦——
    // 导出包里只用这两个名字，导入也只认这两个名字。
    static let claudeCommonConfigExportName = "claude-common-config.json"
    static let codexCommonConfigExportName = "codex-common-config.json"

    func importProfiles(from urls: [URL]) -> ImportResult {
        var result = ImportResult()
        var filesToImport: [URL] = []

        for url in urls {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if let contents = try? fileManager.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
                ) {
                    filesToImport.append(contentsOf: contents.filter { $0.pathExtension == "json" })
                }
            } else if url.pathExtension == "json" {
                filesToImport.append(url)
            }
        }

        for fileURL in filesToImport {
            if fileURL.lastPathComponent == Self.claudeCommonConfigExportName {
                if let data = try? Data(contentsOf: fileURL),
                   let imported = try? GlobalConfig.fromFileData(data) {
                    globalConfig = imported
                    saveGlobalConfig()
                    result.importedGlobalConfig = true
                }
                continue
            }

            if fileURL.lastPathComponent == Self.codexCommonConfigExportName {
                if let data = try? Data(contentsOf: fileURL),
                   let imported = try? CodexGlobalConfig.fromFileData(data) {
                    codexGlobalConfig = imported
                    saveCodexGlobalConfig()
                    result.importedCodexGlobalConfig = true
                }
                continue
            }

            guard let data = try? Data(contentsOf: fileURL) else {
                result.failed += 1
                result.errors.append("\(fileURL.lastPathComponent): unreadable")
                continue
            }

            do {
                let profile = try NodeProfile.fromFileData(data)
                // 去重：同 id 视为同一节点（导出文件内嵌的 id 稳定，跨设备保持一致），
                // 已存在则跳过，避免重复导入同一份导出文件生成多份重复节点。
                if profiles.contains(where: { $0.id == profile.id }) {
                    result.skipped += 1
                    continue
                }
                if save(profile) {
                    result.succeeded += 1
                } else {
                    result.failed += 1
                    result.errors.append("\(fileURL.lastPathComponent): save failed")
                }
            } catch {
                result.failed += 1
                result.errors.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return result
    }

    // MARK: - cc-switch Import
    // 与 cc-switch 的 Claude 供应商保持「镜像同步」：节点 id 由 cc-switch 供应商 id 派生为
    // 确定性 UUID（stableProfileId），重复同步对同一供应商执行 upsert（保留已分配端口、
    // 创建时间、排序），因此不会产生重复节点。磁盘 IO（SQLite 读取）放到后台线程，仅把
    // 纯字符串/数值的原始行（Sendable）跨回主线程，再在主线程解析 JSON、建档、落盘。

    func importCCSwitchClaudeProfiles(dbPath: String? = nil) async -> ImportResult {
        let path = dbPath ?? Self.defaultCCSwitchDBPath
        let output = await Task.detached(priority: .userInitiated) {
            Self.readCCSwitchClaudeData(dbPath: path)
        }.value

        var result = ImportResult()

        if output.dbMissing {
            result.failed = 1
            result.errors.append("cc-switch database not found: \(path)")
            return result
        }
        if output.openFailed {
            result.failed = 1
            result.errors.append("failed to open cc-switch database")
            return result
        }
        if output.rawRows.isEmpty {
            result.errors.append("no cc-switch Claude providers found")
            return result
        }

        var reservedPorts = Set<Int>()
        let importDate = Date()
        for raw in output.rawRows {
            let row = Self.parseRawRow(raw)
            let stableId = Self.stableProfileId(forCCSwitchRowId: row.id)
            let existing = profile(for: stableId)
            let port: Int
            if let existing {
                port = existing.metadata.proxy.port
            } else {
                port = nextAvailablePort(startingAt: 4320, reserving: reservedPorts)
                reservedPorts.insert(port)
            }
            let profile = Self.makeProfile(
                from: row,
                id: stableId,
                port: port,
                existing: existing,
                importDate: importDate
            )
            if save(profile) {
                if existing == nil { result.succeeded += 1 } else { result.updated += 1 }
            } else {
                result.failed += 1
                result.errors.append("\(row.name): save failed")
            }
        }

        if let commonText = output.commonConfigText,
           let commonSettings = Self.jsonObject(from: commonText), !commonSettings.isEmpty {
            if globalConfig.settings.isEmpty {
                globalConfig = GlobalConfig(enabled: true, settings: commonSettings)
                if saveGlobalConfig() {
                    result.importedGlobalConfig = true
                } else {
                    result.errors.append("failed to save cc-switch common config")
                }
            } else {
                result.skippedGlobalConfig = true
            }
        }

        return result
    }

    /// 与 cc-switch 的 Codex 供应商「镜像同步」。Codex 配置存于 `settings_config = { auth.OPENAI_API_KEY,
    /// config(=config.toml 文本) }`：解析出激活 provider 的 base_url、顶层 model、API Key，其余用户配置
    /// （`model_reasoning_effort`、`[mcp_servers.*]` 等）保真存入节点 `extraTOML`。节点 id 由供应商 id 派生
    /// 为确定性 UUID（codex 专用盐）+ upsert，重复同步不产生重复节点。SQLite 读取放后台线程。
    func importCCSwitchCodexProfiles(dbPath: String? = nil) async -> ImportResult {
        let path = dbPath ?? Self.defaultCCSwitchDBPath
        let output = await Task.detached(priority: .userInitiated) {
            Self.readCCSwitchCodexData(dbPath: path)
        }.value

        var result = ImportResult()

        if output.dbMissing {
            result.failed = 1
            result.errors.append("cc-switch database not found: \(path)")
            return result
        }
        if output.openFailed {
            result.failed = 1
            result.errors.append("failed to open cc-switch database")
            return result
        }
        if output.rawRows.isEmpty {
            result.errors.append("no cc-switch Codex providers found")
            return result
        }

        var reservedPorts = Set<Int>()
        let importDate = Date()
        for raw in output.rawRows {
            guard let row = Self.parseCodexRawRow(raw) else {
                result.failed += 1
                result.errors.append("\(raw.name.nilIfBlank ?? "cc-switch Codex"): invalid Codex config")
                continue
            }
            let stableId = Self.stableCodexProfileId(forCCSwitchRowId: row.id)
            let existing = profile(for: stableId)
            let port: Int
            if let existing {
                port = existing.metadata.proxy.port
            } else {
                port = nextAvailablePort(startingAt: 4319, reserving: reservedPorts)
                reservedPorts.insert(port)
            }
            let profile = Self.makeCodexProfile(
                from: row,
                id: stableId,
                port: port,
                existing: existing,
                importDate: importDate
            )
            if save(profile) {
                if existing == nil { result.succeeded += 1 } else { result.updated += 1 }
            } else {
                result.failed += 1
                result.errors.append("\(row.name): save failed")
            }
        }

        // cc-switch 的 Codex 通用配置（common_config_codex）为 TOML 片段；本地为空时导入。
        if let commonTOML = output.commonConfigText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !commonTOML.isEmpty {
            if codexGlobalConfig.tomlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                codexGlobalConfig = CodexGlobalConfig(enabled: true, tomlText: commonTOML)
                if saveCodexGlobalConfig() {
                    result.importedCodexGlobalConfig = true
                } else {
                    result.errors.append("failed to save cc-switch Codex common config")
                }
            }
        }

        return result
    }

    // MARK: - Batch Export

    @discardableResult
    func exportProfiles(ids: [String], to directory: URL) throws -> Int {
        var exported = 0
        var hasClaudeNode = false
        var hasCodexNode = false

        for id in ids {
            guard let profile = profile(for: id) else { continue }
            let isCodex = profile.metadata.nodeType.isCodex
            if isCodex { hasCodexNode = true } else { hasClaudeNode = true }

            let data = try profile.toFileData()
            let sanitizedName = profile.metadata.name
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            // 家族前缀让文件夹里一眼区分 Claude / Codex 节点。
            let familyPrefix = isCodex ? "codex" : "claude"
            let fileName = "\(familyPrefix)_\(sanitizedName)_\(profile.id.prefix(8)).json"
            let fileURL = directory.appendingPathComponent(fileName)
            try data.write(to: fileURL, options: .atomic)
            exported += 1
        }

        // 按家族携带对应「通用配置」：导出集合含 Claude 节点才带 Claude 通用配置，
        // 含 Codex 节点才带 Codex 通用配置（不再无条件混入 Claude 配置）。
        if hasClaudeNode, !globalConfig.settings.isEmpty {
            let data = try globalConfig.toFileData()
            let url = directory.appendingPathComponent(Self.claudeCommonConfigExportName)
            try data.write(to: url, options: .atomic)
        }
        if hasCodexNode,
           !codexGlobalConfig.tomlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let data = try codexGlobalConfig.toFileData()
            let url = directory.appendingPathComponent(Self.codexCommonConfigExportName)
            try data.write(to: url, options: .atomic)
        }

        return exported
    }

    // MARK: - Migration from UserDefaults

    private static let migrationKey = "proxyProfileMigrationCompleted"

    private func migrateFromUserDefaultsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.migrationKey) else { return }
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.proxyConfigurations) else {
            UserDefaults.standard.set(true, forKey: Self.migrationKey)
            return
        }

        storeLog.info("Starting migration from UserDefaults to profile files")
        do {
            let configs = try JSONDecoder().decode([ProxyConfiguration].self, from: data)
            for config in configs {
                let profile = NodeProfile.fromLegacyConfiguration(config)
                save(profile)
            }
            UserDefaults.standard.set(true, forKey: Self.migrationKey)
            storeLog.info("Migration completed: \(configs.count, privacy: .public) profiles migrated")
        } catch {
            storeLog.error("Migration failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Global Config

    func loadGlobalConfig() {
        let path = Self.globalConfigPath
        guard let data = fileManager.contents(atPath: path) else {
            globalConfig = .empty
            return
        }
        do {
            globalConfig = try GlobalConfig.fromFileData(data)
        } catch {
            storeLog.error("Failed to load global config: \(String(describing: error), privacy: .public)")
            globalConfig = .empty
        }
    }

    @discardableResult
    func saveGlobalConfig(_ config: GlobalConfig? = nil) -> Bool {
        if let config { globalConfig = config }
        let path = Self.globalConfigPath
        do {
            let data = try globalConfig.toFileData()
            let dir = (path as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            storeLog.error("Failed to save global config: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - Codex Global Config

    func loadCodexGlobalConfig() {
        let path = Self.codexGlobalConfigPath
        guard let data = fileManager.contents(atPath: path) else {
            codexGlobalConfig = .empty
            return
        }
        do {
            codexGlobalConfig = try CodexGlobalConfig.fromFileData(data)
        } catch {
            storeLog.error("Failed to load Codex global config: \(String(describing: error), privacy: .public)")
            codexGlobalConfig = .empty
        }
    }

    @discardableResult
    func saveCodexGlobalConfig(_ config: CodexGlobalConfig? = nil) -> Bool {
        if let config { codexGlobalConfig = config }
        let path = Self.codexGlobalConfigPath
        do {
            let data = try codexGlobalConfig.toFileData()
            let dir = (path as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            storeLog.error("Failed to save Codex global config: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - Clean Settings Export

    private static var cleanSettingsDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/claude-settings")
    }

    /// Writes a clean settings file (without `_metadata`) for use with `claude --settings <path>`.
    /// Returns the file path on success, nil on failure.
    @discardableResult
    static func exportCleanSettings(for profile: NodeProfile, settings: [String: Any]) -> String? {
        let dir = cleanSettingsDirectory
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            storeLog.error("Failed to create claude-settings directory: \(String(describing: error), privacy: .public)")
            return nil
        }

        let allowedChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let sanitizedName = profile.metadata.name.unicodeScalars
            .map { allowedChars.contains($0) ? String($0) : "_" }
            .joined()
        let fileName = "\(sanitizedName).json"
        let filePath = (dir as NSString).appendingPathComponent(fileName)

        do {
            let data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
            return filePath
        } catch {
            storeLog.error("Failed to export clean settings for \(profile.metadata.name, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static var codexHomeBaseDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/codex-home")
    }

    /// 为 Codex 节点导出一个独立的 CODEX_HOME 目录（内含 `config.toml`），供 `CODEX_HOME=<dir> codex` 启动。
    /// 与 Claude 的 `exportCleanSettings` 对称：不改用户真实 `~/.codex/config.toml`。
    /// 成功返回**目录**路径（CODEX_HOME 指向目录而非文件），失败返回 nil。
    /// config.toml 含 `experimental_bearer_token`，写入后限制为 0600。
    @discardableResult
    static func exportCodexHome(
        for profile: NodeProfile,
        configTOML: String,
        proxyBaseURL: String? = nil,
        proxyAPIKey: String? = nil
    ) -> String? {
        let allowedChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let sanitizedID = profile.id.unicodeScalars
            .map { allowedChars.contains($0) ? String($0) : "_" }
            .joined()
        guard !sanitizedID.isEmpty else {
            storeLog.error("Cannot export Codex home for a profile with an empty id")
            return nil
        }
        let digest = SHA256.hash(data: Data(profile.id.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let dirName = "\(sanitizedID.prefix(48))-\(digest)"
        let dir = (codexHomeBaseDirectory as NSString).appendingPathComponent(dirName)
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            storeLog.error("Failed to create codex-home directory: \(String(describing: error), privacy: .public)")
            return nil
        }

        let filePath = (dir as NSString).appendingPathComponent("config.toml")
        do {
            try configTOML.write(toFile: filePath, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filePath)
        } catch {
            storeLog.error("Failed to export codex home for \(profile.metadata.name, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }

        // 独立 CODEX_HOME 不能继承 ~/.codex/auth.json 的 ChatGPT 登录，否则自定义 base_url 仍会被忽略。
        let isolatedAuth = (dir as NSString).appendingPathComponent("auth.json")
        var stubObject: [String: Any] = ["auth_mode": "apikey"]
        if let key = proxyAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            stubObject["OPENAI_API_KEY"] = key
        }
        if let stub = try? JSONSerialization.data(
            withJSONObject: stubObject,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? stub.write(to: URL(fileURLWithPath: isolatedAuth), options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: isolatedAuth)
        }

        // 与激活态同一套节点身份：OPENAI_BASE_URL 指向本地代理 + 同一把 client key + no_proxy。
        let envPath = (dir as NSString).appendingPathComponent(".env")
        do {
            try CodexNoProxyFixer.writeIsolatedEnv(
                to: envPath,
                openAIBaseURL: proxyBaseURL,
                openAIAPIKey: proxyAPIKey
            )
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envPath)
        } catch {
            storeLog.error("Failed to write CODEX_HOME .env for \(profile.metadata.name, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        return dir
    }

    /// 主线程解析后的 cc-switch 行（含已解码 JSON）。
    private struct CCSwitchClaudeRow {
        var id: String
        var name: String
        var settingsConfig: [String: Any]
        var isCurrent: Bool
        var createdAtMs: Int64?
        var meta: [String: Any]
    }

    /// 主线程解析后的 cc-switch Codex 行（config.toml 已抽取为结构化字段）。
    private struct CCSwitchCodexRow {
        var id: String
        var name: String
        var baseURL: String       // 已规范化（去 /v1）的上游地址
        var apiKey: String
        var model: String
        var extraTOML: String?
        var isCurrent: Bool
        var createdAtMs: Int64?
    }

    /// 后台读取的原始行：只含 Sendable 标量/字符串，可安全跨线程回主线程再解析。
    private struct CCSwitchRawRow: Sendable {
        let id: String
        let name: String
        let settingsText: String
        let isCurrent: Bool
        let createdAtMs: Int64?
        let metaText: String
    }

    /// 后台 SQLite 读取的整体产物（Sendable）。
    private struct CCSwitchReadOutput: Sendable {
        var rawRows: [CCSwitchRawRow] = []
        var commonConfigText: String?
        var dbMissing: Bool = false
        var openFailed: Bool = false
    }

    /// cc-switch 数据库路径：尊重 cc-switch 的自定义配置目录（CCSwitchLocator），
    /// 否则用户迁移过目录后这里会读到陈旧库。
    private static var defaultCCSwitchDBPath: String {
        CCSwitchLocator.databasePath()
    }

    /// 在后台线程执行：打开只读库、读取原始行与通用配置文本。不触碰任何主线程状态。
    nonisolated private static func readCCSwitchClaudeData(dbPath: String) -> CCSwitchReadOutput {
        var output = CCSwitchReadOutput()
        guard FileManager.default.fileExists(atPath: dbPath) else {
            output.dbMissing = true
            return output
        }
        guard let db = openReadonlySQLiteDB(at: dbPath) else {
            output.openFailed = true
            return output
        }
        defer { sqlite3_close(db) }
        output.rawRows = readCCSwitchClaudeRawRows(db: db)
        output.commonConfigText = readCCSwitchClaudeCommonConfigText(db: db)
        return output
    }

    /// 后台读取 cc-switch 的 Codex 供应商行与 Codex 通用配置（TOML 片段）。不触碰主线程状态。
    nonisolated private static func readCCSwitchCodexData(dbPath: String) -> CCSwitchReadOutput {
        var output = CCSwitchReadOutput()
        guard FileManager.default.fileExists(atPath: dbPath) else {
            output.dbMissing = true
            return output
        }
        guard let db = openReadonlySQLiteDB(at: dbPath) else {
            output.openFailed = true
            return output
        }
        defer { sqlite3_close(db) }
        output.rawRows = readCCSwitchRawRows(db: db, appType: "codex")
        output.commonConfigText = readCCSwitchCommonConfigText(db: db, key: "common_config_codex")
        return output
    }

    nonisolated private static func openReadonlySQLiteDB(at path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        return db
    }

    nonisolated private static func readCCSwitchClaudeRawRows(db: OpaquePointer) -> [CCSwitchRawRow] {
        readCCSwitchRawRows(db: db, appType: "claude")
    }

    /// 按 app_type 读取 cc-switch 供应商行。appType 为编译期常量（claude / codex），无注入风险。
    nonisolated private static func readCCSwitchRawRows(db: OpaquePointer, appType: String) -> [CCSwitchRawRow] {
        let sql = """
        SELECT id, name, settings_config, is_current, created_at, meta
        FROM providers
        WHERE app_type = '\(appType)'
        ORDER BY sort_index, name
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var rows: [CCSwitchRawRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqliteText(stmt, 0) ?? UUID().uuidString
            let name = sqliteText(stmt, 1) ?? ""
            let settingsText = sqliteText(stmt, 2) ?? "{}"
            let metaText = sqliteText(stmt, 5) ?? "{}"
            let createdAt = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 4)
            rows.append(CCSwitchRawRow(
                id: id,
                name: name,
                settingsText: settingsText,
                isCurrent: sqlite3_column_int(stmt, 3) == 1,
                createdAtMs: createdAt,
                metaText: metaText
            ))
        }
        return rows
    }

    nonisolated private static func readCCSwitchClaudeCommonConfigText(db: OpaquePointer) -> String? {
        readCCSwitchCommonConfigText(db: db, key: "common_config_claude")
    }

    /// 读取 settings 表中某通用配置键的值。key 为编译期常量，无注入风险。
    nonisolated private static func readCCSwitchCommonConfigText(db: OpaquePointer, key: String) -> String? {
        let sql = "SELECT value FROM settings WHERE key = '\(key)' LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqliteText(stmt, 0)
    }

    /// 主线程解析：把后台读到的原始文本行解码为带 JSON 的行。
    private static func parseRawRow(_ raw: CCSwitchRawRow) -> CCSwitchClaudeRow {
        CCSwitchClaudeRow(
            id: raw.id,
            name: raw.name.nilIfBlank ?? "cc-switch Claude",
            settingsConfig: jsonObject(from: raw.settingsText) ?? [:],
            isCurrent: raw.isCurrent,
            createdAtMs: raw.createdAtMs,
            meta: jsonObject(from: raw.metaText) ?? [:]
        )
    }

    /// 解析 cc-switch Codex 行：`settings_config = { auth.OPENAI_API_KEY, config:"<config.toml>" }`。
    /// 用 CodexConfigManager 解析 config.toml 抽取 base_url / model / extraTOML。缺少 TOML 视为无效。
    private static func parseCodexRawRow(_ raw: CCSwitchRawRow) -> CCSwitchCodexRow? {
        guard let settingsConfig = jsonObject(from: raw.settingsText) else { return nil }
        let auth = settingsConfig["auth"] as? [String: Any]
        let apiKey = stringValue(auth?["OPENAI_API_KEY"]) ?? ""
        guard let configTOML = stringValue(settingsConfig["config"]) else { return nil }

        let parsed = CodexConfigManager.shared.parseImportedConfig(configTOML)
        let baseURL = ClaudeProxyConfiguration.normalizeOpenAIBaseURL(parsed.providerBaseURL ?? "")

        return CCSwitchCodexRow(
            id: raw.id,
            name: raw.name.nilIfBlank ?? "cc-switch Codex",
            baseURL: baseURL,
            apiKey: apiKey,
            model: parsed.model ?? "",
            extraTOML: parsed.extraTOML.nilIfBlank,
            isCurrent: raw.isCurrent,
            createdAtMs: raw.createdAtMs
        )
    }

    /// 由 cc-switch 供应商 id + 家族盐派生确定性节点 id（SHA-256 → UUID 形态），保证多次同步命中同一节点。
    /// Claude / Codex 用不同盐，避免两家族行 id 偶然相同时互相覆盖。
    private static func deriveStableId(salt: String, rowId: String) -> String {
        let digest = SHA256.hash(data: Data("\(salt).\(rowId)".utf8))
        let hex = digest.prefix(16).map { String(format: "%02X", Int($0)) }.joined()
        func seg(_ lo: Int, _ hi: Int) -> Substring {
            hex[hex.index(hex.startIndex, offsetBy: lo)..<hex.index(hex.startIndex, offsetBy: hi)]
        }
        return "\(seg(0, 8))-\(seg(8, 12))-\(seg(12, 16))-\(seg(16, 20))-\(seg(20, 32))"
    }

    private static func stableProfileId(forCCSwitchRowId rowId: String) -> String {
        deriveStableId(salt: "aiusage.ccswitch.claude", rowId: rowId)
    }

    private static func stableCodexProfileId(forCCSwitchRowId rowId: String) -> String {
        deriveStableId(salt: "aiusage.ccswitch.codex", rowId: rowId)
    }

    private static func makeProfile(
        from row: CCSwitchClaudeRow,
        id: String,
        port: Int,
        existing: NodeProfile?,
        importDate: Date
    ) -> NodeProfile {
        var settings = row.settingsConfig
        var env = settings["env"] as? [String: Any] ?? [:]

        let upstreamBaseURL = stringValue(env["ANTHROPIC_BASE_URL"]) ?? "https://api.anthropic.com"
        let upstreamKey = stringValue(env["ANTHROPIC_AUTH_TOKEN"]) ?? stringValue(env["ANTHROPIC_API_KEY"]) ?? ""
        let defaultModel = stringValue(env["ANTHROPIC_MODEL"])
            ?? stringValue(settings["model"])
            ?? stringValue(env["ANTHROPIC_DEFAULT_SONNET_MODEL"])
            ?? ""
        let opus = stringValue(env["ANTHROPIC_DEFAULT_OPUS_MODEL"]) ?? defaultModel
        let sonnet = stringValue(env["ANTHROPIC_DEFAULT_SONNET_MODEL"]) ?? defaultModel
        let haiku = stringValue(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"]) ?? defaultModel

        env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:\(port)"
        env["ANTHROPIC_AUTH_TOKEN"] = upstreamKey
        if !opus.isEmpty { env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = opus }
        if !sonnet.isEmpty { env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = sonnet }
        if !haiku.isEmpty { env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = haiku }
        settings["env"] = env
        settings["$schema"] = settings["$schema"] ?? "https://json.schemastore.org/claude-code-settings.json"
        if !defaultModel.isEmpty { settings["model"] = defaultModel }

        let commonMode: CommonConfigMode?
        if let enabled = boolValue(row.meta["commonConfigEnabled"]) ?? boolValue(row.meta["common_config_enabled"]) {
            commonMode = enabled ? .alwaysMerge : .neverMerge
        } else {
            commonMode = .followGlobal
        }

        let proxy = ProxySettings(
            host: "127.0.0.1",
            port: port,
            allowLAN: false,
            upstreamBaseURL: "https://api.openai.com",
            openAIUpstreamAPI: .chatCompletions,
            upstreamAPIKey: "",
            expectedClientKey: "",
            maxOutputTokens: 0,
            defaultModel: defaultModel,
            modelMapping: ProxyConfiguration.ModelMapping(
                bigModel: .init(name: opus),
                middleModel: .init(name: sonnet),
                smallModel: .init(name: haiku)
            ),
            anthropicBaseURL: upstreamBaseURL,
            anthropicAPIKey: upstreamKey,
            usePassthroughProxy: true,
            enableModelAliasMapping: false,
            enableHTTPS: false,
            httpsPort: nil,
            commonConfigMode: commonMode
        )

        // upsert：已存在节点保留创建时间与排序，避免重复同步把节点重排或重计时。
        let createdAt = existing?.metadata.createdAt
            ?? row.createdAtMs.flatMap { dateFromCCSwitchTimestamp($0) }
            ?? importDate
        let metadata = NodeProfile.Metadata(
            id: id,
            name: "\(row.name) (cc-switch)",
            nodeType: .anthropicDirect,
            createdAt: createdAt,
            lastUsedAt: row.isCurrent ? importDate : existing?.metadata.lastUsedAt,
            sortOrder: existing?.metadata.sortOrder ?? Int.max,
            proxy: proxy
        )
        return NodeProfile(metadata: metadata, settings: settings)
    }

    /// 由 cc-switch Codex 行建档：复用 Codex 默认（端口本地分配、Responses、不启 HTTPS），
    /// 写入上游 base_url / API Key / 单模型 + extraTOML 保真。Codex 节点 settings 落盘恒空。
    private static func makeCodexProfile(
        from row: CCSwitchCodexRow,
        id: String,
        port: Int,
        existing: NodeProfile?,
        importDate: Date
    ) -> NodeProfile {
        var proxy = ProxySettings.defaultCodex
        proxy.host = "127.0.0.1"
        proxy.port = port
        if !row.baseURL.isEmpty { proxy.upstreamBaseURL = row.baseURL }
        proxy.upstreamAPIKey = row.apiKey
        if !row.model.isEmpty {
            proxy.defaultModel = row.model
            proxy.modelMapping.bigModel.name = row.model
        }
        proxy.extraTOML = row.extraTOML

        let createdAt = existing?.metadata.createdAt
            ?? row.createdAtMs.flatMap { dateFromCCSwitchTimestamp($0) }
            ?? importDate
        let metadata = NodeProfile.Metadata(
            id: id,
            name: "\(row.name) (cc-switch)",
            nodeType: .codexProxy,
            createdAt: createdAt,
            lastUsedAt: row.isCurrent ? importDate : existing?.metadata.lastUsedAt,
            sortOrder: existing?.metadata.sortOrder ?? Int.max,
            proxy: proxy
        )
        return NodeProfile(metadata: metadata, settings: [:])
    }

    nonisolated private static func sqliteText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private static func jsonObject(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        return string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    private static func dateFromCCSwitchTimestamp(_ timestamp: Int64) -> Date? {
        guard timestamp > 0 else { return nil }
        if timestamp > 10_000_000_000 {
            return Date(timeIntervalSince1970: Double(timestamp) / 1000.0)
        }
        return Date(timeIntervalSince1970: Double(timestamp))
    }

    // MARK: - Helpers

    private func filePath(for id: String) -> String {
        (Self.profilesDirectory as NSString).appendingPathComponent("\(id).json")
    }

    func nextAvailablePort(startingAt startPort: Int = 8080, reserving reservedPorts: Set<Int> = []) -> Int {
        let usedPorts = Set(profiles.map(\.metadata.proxy.port)).union(reservedPorts)
        var port = startPort
        while usedPorts.contains(port) { port += 1 }
        return port
    }
}
