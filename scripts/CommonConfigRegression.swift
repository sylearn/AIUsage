import Foundation
import os.log
import QuotaBackend

// 不启动 App、不读用户配置、不访问上游。生产方法由运行器原样提取。
let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("common-config-\(UUID().uuidString)")
let storeLog = Logger(subsystem: "com.aiusage.regression", category: "Store")
let openCodeStoreLog = storeLog
let openCodeConfigLog = storeLog
let codexConfigLog = storeLog

final class AppSettings {
    static let shared = AppSettings()
    func t(_ en: String, _ zh: String) -> String { zh }
}
extension JSONEncoder { static var profileEncoder: JSONEncoder { JSONEncoder() } }
extension JSONDecoder { static var profileDecoder: JSONDecoder { JSONDecoder() } }
extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
enum FixtureError: Error { case failed(String) }
enum CodexConfigError: Error { case failedToWriteFile, failedToCreateDirectory }
enum OpenCodeConfigError: Error { case failedToWriteFile }
enum CodexSessionProviderMigrator {
    static let currentProvider = "openai"
    static let legacyAIUsageProvider = "aiusage"
}
enum CommonConfigMode {
    case followGlobal, alwaysMerge, neverMerge
    func shouldMerge(globalEnabled: Bool) -> Bool {
        switch self { case .followGlobal: return globalEnabled; case .alwaysMerge: return true; case .neverMerge: return false }
    }
}
struct FixtureProxy {
    var extraTOML: String?
    var mode = CommonConfigMode.followGlobal
    func shouldMergeClaudeCommonConfig(globalEnabled: Bool) -> Bool { mode.shouldMerge(globalEnabled: globalEnabled) }
}
struct FixtureMetadata { var proxy = FixtureProxy() }
struct FixtureProfile { var settings: [String: Any] = [:]; var metadata = FixtureMetadata() }
struct FixtureNode { let id: String; var commonConfigMode: CommonConfigMode? }
typealias OpenCodeNode = FixtureNode
struct FixtureConfig {
    var id = "active"
    var enableHTTPS = false
    var effectiveHTTPSPort = 14398
    var port = 14399
    var host = "127.0.0.1"
    var effectiveClientKey = "fixture-key"
    var codexModel = "fixture-model"
}
enum FixtureTrack { case codex, claude, desktop, opencode }
enum FixtureCatalog { case smartRoutes, fullNodeCatalog }
struct FixtureRoutes { var defaultModel = "default"; var opus = "opus"; var sonnet = "sonnet"; var haiku = "haiku" }
struct GlobalProxyConfig {
    var activeNodeId: String? = "active"
    var codexBaseURL = "http://127.0.0.1:14399/v1"
    var localBaseURL = "http://127.0.0.1:14400"
    var effectiveClientKey = "fixture-client"
    var virtualModel = "LLM"
    var effectiveOpenCodeInterface = OpenCodeProtocol.openAIResponses
    var effectiveClaudeCodeCatalogMode = FixtureCatalog.smartRoutes
    var claudeOpus = "opus"; var claudeSonnet = "sonnet"; var claudeHaiku = "haiku"
    func effectiveClaudeCodeModels(for node: FixtureNode) -> FixtureRoutes { FixtureRoutes() }
}
enum ClaudeDesktopProfileStore {
    static let codeDefaultRouteID = "default"
    static let codeOpusRouteID = "opus"
    static let codeSonnetRouteID = "sonnet"
    static let codeHaikuRouteID = "haiku"
}
struct TLSCertificateManager { static let shared = TLSCertificateManager(); var certFilePath: String { "fixture.crt" } }
struct CodexGlobalProxyAdapter {}
struct ClaudeGlobalProxyAdapter {
    var track = FixtureTrack.claude
    func node(_ id: String) -> FixtureNode? { FixtureNode(id: id) }
}
struct OpenCodeGlobalProxyAdapter {}

// Claude 使用完整生产类；适配器只把 shared 重定向到隔离目录。
// 由脚本给适配器添加 fixture 实例，确保绝不触碰真实 ~/.claude。
let fixtureClaude = ClaudeSettingsManager(directory: fixtureRoot.appendingPathComponent("claude"))

final class GlobalProxyManager {
    static let codex = GlobalProxyManager(.codex)
    static let claude = GlobalProxyManager(.claude)
    static let opencode = GlobalProxyManager(.opencode)
    let track: FixtureTrack
    var isEnabled = true
    var writes = 0
    var fail = false
    init(_ track: FixtureTrack) { self.track = track }
    func reapplyCLIConfig() throws {
        if fail { throw FixtureError.failed("injected write failure") }
        switch track {
        case .codex: try CodexGlobalProxyAdapter().activateCLIConfig(.init())
        case .claude: try ClaudeGlobalProxyAdapter().activateCLIConfig(.init())
        case .opencode: try OpenCodeGlobalProxyAdapter().activateCLIConfig(.init())
        case .desktop: break
        }
        writes += 1
    }
}
final class ProxyViewModel {
    static let shared = ProxyViewModel()
    var configurations = [FixtureConfig()]
    var activeID: String?
    func activatedId(isCodex: Bool) -> String? { activeID }
}
final class NodeProfileStore {
    static let shared = NodeProfileStore()
    static var globalConfigPath: String { fixtureRoot.appendingPathComponent("global.json").path }
    static var codexGlobalConfigPath: String { fixtureRoot.appendingPathComponent("codex-global.json").path }
    let fileManager = FileManager.default
    var globalConfig = GlobalConfig.empty
    var codexGlobalConfig = CodexGlobalConfig.empty
    var commonConfigError: String?
    var activeProfile = FixtureProfile()
    func profile(for id: String) -> FixtureProfile? { activeProfile }
}
final class OpenCodeNodeStore {
    static let shared = OpenCodeNodeStore()
    static var globalConfigPath: String { fixtureRoot.appendingPathComponent("opencode-global.json").path }
    let fileManager = FileManager.default
    var globalConfig = GlobalConfig.empty
    var commonConfigError: String?
    var nodes = [FixtureNode(id: "active")]
    var activeNodeIds: [String] = []
    var perNodeWrites = 0
    func rewriteManagedConfig() throws { perNodeWrites += 1 }
}
final class CodexConfigManager {
    static let shared = CodexConfigManager()
    static let providerId = "openai"
    static let headerBegin = "# >>> AIUSAGE-CODEX-PROXY BEGIN (managed, do not edit) >>>"
    static let headerEnd = "# <<< AIUSAGE-CODEX-PROXY END <<<"
    static let baseBegin = "# >>> AIUSAGE-CODEX-BASE BEGIN (managed, do not edit) >>>"
    static let baseEnd = "# <<< AIUSAGE-CODEX-BASE END <<<"
    static let providerBegin = "# >>> AIUSAGE-CODEX-PROVIDER BEGIN (managed, do not edit) >>>"
    static let providerEnd = "# <<< AIUSAGE-CODEX-PROVIDER END <<<"
    let fileManager = FileManager.default
    var configPath: String { fixtureRoot.appendingPathComponent("config.toml").path }
    var backupPath: String { configPath + ".aiusage.bak" }
    let pristine = "model_reasoning_effort = \"xhigh\"\nkeep = true\n"
    func activate(baseURL: String, bearerToken: String, model: String, restrictModelCatalog: Bool = false,
                  globalTOML: String? = nil, nodeTOML: String? = nil) throws {
        let merged = mergeBaseFragments(global: globalTOML ?? "", node: nodeTOML ?? "")
        try writeConfig(injectManagedConfig(into: pristine, baseURL: baseURL, bearerToken: bearerToken,
                                           model: model, baseTopLevel: merged.topLevel, baseTables: merged.tables))
    }
}
enum OpenCodeProtocol: String {
    case openAIResponses, anthropic, openAICompatible
    var npmPackage: String { "@ai-sdk/" + rawValue }
}
enum FixtureSchema { case v1, v2 }
struct FixtureAuthStore {
    func snapshotManagedCredentials() -> [String: String] { [:] }
    func removeManagedCredentials() -> Bool { true }
    func syncManagedCredentials(_ values: [String: String]) -> Bool { true }
}
final class OpenCodeConfigManager {
    static let shared = OpenCodeConfigManager()
    static let globalProviderId = "aiusage"
    static let openCodeProviderKeys = ["provider", "providers"]
    static func isManagedProviderKey(_ key: String) -> Bool { key == "aiusage" || key.hasPrefix("aiusage-") }
    let authStore = FixtureAuthStore()
    var openCodeSchema = FixtureSchema.v1
    var session: Bool? = true
    let fileManager = FileManager.default
    var usesJSONC = false
    var configURL: URL { fixtureRoot.appendingPathComponent(usesJSONC ? "opencode.jsonc" : "opencode.json") }
    var configPath: String { configURL.path }
    var backupPath: String? { nil }
    func establishBackupAndLoadPristine() throws -> [String: Any] { ["theme": "original", "keep": true] }
    func withManagedFilesTransaction(_ action: () throws -> Void) throws { try action() }
    func verifyEffectiveManagedProjection(target: [String: Any]) throws {}
    func recordManagedHash() throws {}
    func discardSessionFiles() {}
}

@main struct CommonConfigRegression {
    static var assertions = 0
    static func expect(_ condition: Bool, _ message: String) throws {
        assertions += 1
        if !condition { throw FixtureError.failed(message) }
    }
    static func json(_ url: URL) throws -> [String: Any] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return JSONCEditor.parseObject(text)!
    }
    static func codexText() throws -> String {
        try String(contentsOfFile: CodexConfigManager.shared.configPath, encoding: .utf8)
    }
    static func main() {
        do { try run() } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
    static func run() throws {
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let track = CommandLine.arguments.dropFirst().first
        if track == nil || track == "codex" { try codex() }
        if track == nil || track == "claude" { try claude() }
        if track == nil || track == "opencode" { try opencode() }
        if track == nil { try failuresAndInactive() }
        print("Common config regression passed (\(assertions) assertions): Codex, Claude, OpenCode; isolated file readback.")
    }

    static func codex() throws {
        let store = NodeProfileStore.shared
        store.codexGlobalConfig = .init(enabled: true, tomlText: "model_reasoning_effort = \"high\"")
        try expect(store.saveCodexGlobalConfig(), "Codex save failed")
        try expect(try codexText().contains("model_reasoning_effort = \"high\""), "Codex global fragment missing")
        try expect(try !codexText().contains("\"xhigh\""), "Codex duplicate original key")
        store.activeProfile.metadata.proxy.extraTOML = "model_reasoning_effort = \"low\""
        try expect(store.saveCodexGlobalConfig(), "Codex node override save")
        try expect(try codexText().contains("\"low\""), "Codex node override lost")
        store.activeProfile.metadata.proxy.extraTOML = nil
        store.codexGlobalConfig.enabled = false
        try expect(store.saveCodexGlobalConfig(), "Codex toggle off failed")
        try expect(try codexText().contains("\"xhigh\""), "Codex toggle off failed to restore baseline")
        store.codexGlobalConfig.enabled = true
        store.codexGlobalConfig.tomlText = ""
        try expect(store.saveCodexGlobalConfig(), "Codex empty fragment save")
        try expect(try !codexText().contains("AIUSAGE-CODEX-BASE"), "Codex deleted fragment left stale block")
        GlobalProxyManager.codex.isEnabled = false
        ProxyViewModel.shared.activeID = "active"
        store.codexGlobalConfig.tomlText = "model_reasoning_effort = \"medium\""
        try expect(store.saveCodexGlobalConfig(), "Codex per-node save")
        try expect(try codexText().contains("\"medium\""), "Codex per-node did not update")
        ProxyViewModel.shared.activeID = nil
        GlobalProxyManager.codex.isEnabled = true
    }

    static func claude() throws {
        let directory = fixtureRoot.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["effortLevel": "xhigh", "env": ["KEEP": "original"]])
            .write(to: file)
        let store = NodeProfileStore.shared
        store.globalConfig = .init(enabled: true, settings: ["effortLevel": "high", "env": ["ADDED": "yes"]])
        try expect(store.saveGlobalConfig(), "Claude save failed")
        var live = try json(file)
        try expect(live["effortLevel"] as? String == "high", "Claude global fragment missing")
        try expect((live["env"] as? [String: Any])?["KEEP"] as? String == "original", "Claude unrelated env lost")
        store.activeProfile.settings = ["effortLevel": "low", "model": "bad-route", "env": ["ANTHROPIC_BASE_URL": "bad-url"]]
        try expect(store.saveGlobalConfig(), "Claude node settings save")
        live = try json(file)
        try expect(live["effortLevel"] as? String == "low", "Claude node priority lost")
        try expect(live["model"] as? String == "default", "Claude managed model overwritten")
        try expect((live["env"] as? [String: Any])?["ANTHROPIC_BASE_URL"] as? String == "http://127.0.0.1:14400", "Claude route overwritten")
        store.activeProfile.settings = [:]
        store.globalConfig.enabled = false
        try expect(store.saveGlobalConfig(), "Claude toggle off failed")
        live = try json(file)
        try expect(live["effortLevel"] as? String == "xhigh", "Claude baseline not restored")
        try expect((live["env"] as? [String: Any])?["ADDED"] == nil, "Claude disabled key remains")
        store.activeProfile.metadata.proxy.mode = .alwaysMerge
        try expect(store.saveGlobalConfig(), "Claude alwaysMerge save")
        try expect(try json(file)["effortLevel"] as? String == "high", "Claude alwaysMerge ignored")
        store.activeProfile.metadata.proxy.mode = .neverMerge
        store.globalConfig.enabled = true
        try expect(store.saveGlobalConfig(), "Claude neverMerge save")
        try expect(try json(file)["effortLevel"] as? String == "xhigh", "Claude neverMerge ignored")
        store.activeProfile.metadata.proxy.mode = .followGlobal
        try expect(store.saveGlobalConfig(), "Claude reenable save")
        store.globalConfig.settings = ["effortLevel": "high"]
        try expect(store.saveGlobalConfig(), "Claude remove fragment key save")
        live = try json(file)
        try expect((live["env"] as? [String: Any])?["ADDED"] == nil, "Claude deleted fragment key remains")
        store.globalConfig.settings = ["effortLevel": "high", "env": ["ADDED": "yes"]]
        try expect(store.saveGlobalConfig(), "Claude restore fragment key save")
        // 重建 manager 模拟重启，关闭片段仍须还原，同时保留外部修改。
        live = try json(file)
        live["external"] = true
        live["effortLevel"] = "medium"
        try JSONSerialization.data(withJSONObject: live).write(to: file)
        let restarted = ClaudeSettingsManager(directory: directory)
        try restarted.clearEnv()
        live = try json(file)
        try expect(live["effortLevel"] as? String == "medium", "Claude external edit overwritten on restore")
        try expect(live["external"] as? Bool == true, "Claude external field lost")
        try expect((live["env"] as? [String: Any])?["ADDED"] == nil, "Claude restart lost overlay cleanup")
        try expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("settings.aiusage-common.json").path), "Claude overlay state not removed")
        // 配置目标无法写入时，保留上次 ledger；重试后仍可还原原值。
        let blockedDirectory = fixtureRoot.appendingPathComponent("blocked-claude")
        let blockedTarget = blockedDirectory.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: blockedTarget, withIntermediateDirectories: true)
        let blocked = ClaudeSettingsManager(directory: blockedDirectory)
        var rejected = false
        do {
            try blocked.writeEnv(.init(baseURL: "http://fixture", authToken: "fixture", nodeExtraCACerts: nil),
                                 settingsOverlay: ["effortLevel": "high"])
        } catch { rejected = true }
        try expect(rejected, "Claude real write failure swallowed")
        try expect(!FileManager.default.fileExists(atPath: blockedDirectory.appendingPathComponent("settings.aiusage-common.json").path), "Claude failed write left an applied ledger")

        // 激活直接节点 → 重复应用通用配置（preserveExistingBackup: true）→ 停用节点：必须恢复激活前的原始设置，而非节点设置。
        let directDir = fixtureRoot.appendingPathComponent("direct-claude-backup")
        try FileManager.default.createDirectory(at: directDir, withIntermediateDirectories: true)
        let directFile = directDir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["effortLevel": "xhigh", "userBaseline": true]).write(to: directFile)
        let directManager = ClaudeSettingsManager(directory: directDir)
        try directManager.writeFullSettings(["effortLevel": "low", "env": ["ANTHROPIC_BASE_URL": "http://127.0.0.1:15500"]])
        try directManager.writeFullSettings(["effortLevel": "high", "env": ["ANTHROPIC_BASE_URL": "http://127.0.0.1:15500"]], preserveExistingBackup: true)
        try directManager.restoreFromBackup()
        let restoredDirect = try json(directFile)
        try expect(restoredDirect["userBaseline"] as? Bool == true, "Direct Claude node pre-activation baseline lost after reapply")
        try expect((restoredDirect["env"] as? [String: Any])?["ANTHROPIC_BASE_URL"] == nil, "Direct Claude node proxy route leaked into restored backup")

        // 首次激活前无 settings.json → 重复应用通用配置（preserveExistingBackup: true）→ 停用节点：不得生成代理备份，必须清理代理路由。
        let noBaselineDir = fixtureRoot.appendingPathComponent("direct-claude-no-baseline")
        let noBaselineManager = ClaudeSettingsManager(directory: noBaselineDir)
        try noBaselineManager.writeFullSettings(["effortLevel": "low", "env": ["ANTHROPIC_BASE_URL": "http://127.0.0.1:15500"]])
        try noBaselineManager.writeFullSettings(["effortLevel": "high", "env": ["ANTHROPIC_BASE_URL": "http://127.0.0.1:15500"]], preserveExistingBackup: true)
        try noBaselineManager.restoreFromBackup()
        let restoredNoBaseline = try noBaselineManager.readSettings()
        try expect((restoredNoBaseline["env"] as? [String: Any])?["ANTHROPIC_BASE_URL"] == nil, "No-baseline Claude reapply leaked proxy route after restore")
        try expect(!FileManager.default.fileExists(atPath: noBaselineDir.appendingPathComponent("settings.backup.json").path), "No-baseline Claude reapply manufactured a backup file")
    }

    static func opencode() throws {
        let store = OpenCodeNodeStore.shared
        for (schema, jsonc) in [(FixtureSchema.v1, false), (.v2, false), (.v1, true), (.v2, true)] {
            OpenCodeConfigManager.shared.openCodeSchema = schema
            OpenCodeConfigManager.shared.usesJSONC = jsonc
            try "{\n// retained user comment\n\"theme\": \"original\", \"keep\": true\n}\n"
                .write(to: OpenCodeConfigManager.shared.configURL, atomically: true, encoding: .utf8)
            store.nodes[0].commonConfigMode = .followGlobal
            store.globalConfig = .init(enabled: true, settings: ["theme": "dark", "model": "bad", "permission": ["edit": "ask"]])
            try expect(store.saveGlobalConfig(), "OpenCode save failed")
            var live = try json(OpenCodeConfigManager.shared.configURL)
            try expect(live["theme"] as? String == "dark", "OpenCode global fragment missing")
            try expect(live["model"] as? String == "aiusage/LLM", "OpenCode managed model overwritten")
            try expect(live["keep"] as? Bool == true, "OpenCode original key lost")
            let providerKey = schema == .v2 ? "providers" : "provider"
            try expect((live[providerKey] as? [String: Any])?["aiusage"] != nil, "OpenCode provider missing")
            store.globalConfig.enabled = false
            try expect(store.saveGlobalConfig(), "OpenCode toggle off failed")
            live = try json(OpenCodeConfigManager.shared.configURL)
            try expect(live["theme"] as? String == "original", "OpenCode baseline not restored")
            try expect(live["permission"] == nil, "OpenCode disabled key remains")
            if jsonc {
                let text = try String(contentsOf: OpenCodeConfigManager.shared.configURL, encoding: .utf8)
                try expect(text.contains("// retained user comment"), "OpenCode JSONC comment lost")
            }
            store.nodes[0].commonConfigMode = .alwaysMerge
            try expect(store.saveGlobalConfig(), "OpenCode alwaysMerge save")
            try expect(try json(OpenCodeConfigManager.shared.configURL)["theme"] as? String == "dark", "OpenCode alwaysMerge ignored")
            store.nodes[0].commonConfigMode = .neverMerge
            store.globalConfig.enabled = true
            try expect(store.saveGlobalConfig(), "OpenCode neverMerge save")
            try expect(try json(OpenCodeConfigManager.shared.configURL)["theme"] as? String == "original", "OpenCode neverMerge ignored")
        }
        GlobalProxyManager.opencode.isEnabled = false
        store.activeNodeIds = ["active"]
        try expect(store.saveGlobalConfig(), "OpenCode per-node save")
        try expect(store.perNodeWrites == 1, "OpenCode per-node reapply lost")
        store.activeNodeIds = []
        GlobalProxyManager.opencode.isEnabled = true
    }

    static func failuresAndInactive() throws {
        let store = NodeProfileStore.shared
        for manager in [GlobalProxyManager.codex, .claude, .opencode] {
            manager.fail = true
            let success: Bool
            switch manager.track {
            case .codex: success = store.saveCodexGlobalConfig()
            case .claude: success = store.saveGlobalConfig()
            default: success = OpenCodeNodeStore.shared.saveGlobalConfig()
            }
            try expect(!success, "Write failure reported as saved")
            let message = manager.track == .opencode ? OpenCodeNodeStore.shared.commonConfigError : store.commonConfigError
            try expect(message != nil, "Write failure not surfaced")
            manager.fail = false
            manager.isEnabled = false
        }
        let counts = [GlobalProxyManager.codex.writes, GlobalProxyManager.claude.writes, GlobalProxyManager.opencode.writes]
        try expect(store.saveGlobalConfig() && store.saveCodexGlobalConfig() && OpenCodeNodeStore.shared.saveGlobalConfig(), "Inactive save failed")
        try expect(counts == [GlobalProxyManager.codex.writes, GlobalProxyManager.claude.writes, GlobalProxyManager.opencode.writes], "Inactive save took over client configuration")
    }
}
