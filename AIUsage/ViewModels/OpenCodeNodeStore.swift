import Foundation
import SwiftUI
import Combine
import os.log
import QuotaBackend

// MARK: - OpenCode Node Store
// OpenCode 节点的持久化与激活状态。节点列表 + activeNodeId 存为单文件
// ~/.config/aiusage/opencode-nodes.json（含 API Key，0600 权限）。
// 激活/停用委托 OpenCodeConfigManager 写受管全局层；启动时与配置文件实际状态对账。
// 代理模式节点：激活前先经 OpenCodeProxyRuntime 拉起本地透传进程，受管层指向
// 127.0.0.1；App 重启后对账时自动恢复代理进程（否则 OpenCode 请求会失败）。

private let openCodeStoreLog = Logger(subsystem: "com.aiusage.desktop", category: "OpenCodeNodeStore")

enum OpenCodeNodeStoreError: LocalizedError {
    case proxyRequiresAPIKey
    case managedByGlobalProxy

    var errorDescription: String? {
        switch self {
        case .proxyRequiresAPIKey:
            return AppSettings.shared.t(
                "Proxy mode with the OpenAI Responses protocol requires an API key.",
                "OpenAI Responses 协议的代理模式需要填写 API Key。"
            )
        case .managedByGlobalProxy:
            return AppSettings.shared.t(
                "The OpenCode global proxy is enabled and manages the active configuration. Switch the active node from the global proxy panel, or disable it first.",
                "OpenCode 全局代理已启用并接管当前配置。请在全局代理面板切换激活节点，或先停用全局代理。"
            )
        }
    }
}

@MainActor
final class OpenCodeNodeStore: ObservableObject {
    static let shared = OpenCodeNodeStore()

    @Published private(set) var nodes: [OpenCodeNode] = []
    @Published private(set) var activeNodeId: String?
    /// 「仅代理」运行中的节点集合（不接管全局配置，仅拉起本地透传进程暴露端口，
    /// 供启动命令等外部接入使用）。与 Claude/Codex 同语义：可多个并行（各占一端口）、
    /// 与激活互不影响；激活某节点时该节点退出仅代理（代理随激活运行）。
    @Published private(set) var proxyOnlyNodeIds: Set<String> = []
    /// 通用配置片段（与 Claude 页同构）：激活时按节点合并策略深合并进受管层，
    /// 受管块与用户原文之间的中间层。持久化于 ~/.config/aiusage/opencode-global-config.json。
    @Published var globalConfig: GlobalConfig = .empty

    private let configManager = OpenCodeConfigManager.shared
    private let proxyRuntime = OpenCodeProxyRuntime.shared
    private let fileManager = FileManager.default

    private struct StoreFile: Codable {
        var version: Int
        var nodes: [OpenCodeNode]
        var activeNodeId: String?
        var proxyOnlyNodeIds: [String]?
    }

    private static let storeVersion = 1

    static var storePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/opencode-nodes.json")
    }

    static var globalConfigPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/opencode-global-config.json")
    }

    init() {
        load()
        loadGlobalConfig()
        reconcileWithConfigFile()
        restoreProxyIfNeeded()
    }

    // MARK: - Derived State

    var activeNode: OpenCodeNode? {
        guard let activeNodeId else { return nil }
        return nodes.first { $0.id == activeNodeId }
    }

    var configPath: String { configManager.configPath }
    var configFileName: String { configManager.configFileName }
    var configDisplayPath: String { configManager.configDisplayPath }
    var configResolution: OpenCodeConfigResolution { configManager.configResolution }
    var configManagementState: OpenCodeConfigManagementState { configManager.managementState }
    var lowerPriorityConfigFileNames: [String] { configManager.lowerPriorityConfigFileNames }
    var customConfigPath: String? { configResolution.customConfigPath }
    var customConfigDirectory: String? { configResolution.customConfigDirectory }
    var hasInlineConfigContent: Bool { configResolution.inlineConfigParseStatus != .missing }
    var inlineConfigContentIsInvalid: Bool { configResolution.inlineConfigParseStatus == .invalid }

    /// True when the selected global target is JSONC.
    var usesJSONC: Bool { configManager.usesJSONC }

    // MARK: - CRUD

    func upsert(_ node: OpenCodeNode) {
        var updated = node
        ensureProviderSlug(&updated)
        if let index = nodes.firstIndex(where: { $0.id == node.id }) {
            nodes[index] = updated
        } else {
            if updated.sortOrder == Int.max {
                let minOrder = nodes.map(\.sortOrder).min() ?? 0
                updated.sortOrder = minOrder - 1
            }
            nodes.insert(updated, at: 0)
            sortNodes()
        }
        save()

        // 编辑当前激活节点后立即重新激活（重写受管层；代理参数未变时进程原地复用）。
        if updated.id == activeNodeId {
            Task { [weak self] in
                try? await self?.activate(updated)
            }
        } else if proxyOnlyNodeIds.contains(updated.id) {
            // 仅代理运行中的节点被编辑：按新参数滚动重启（关掉代理模式则直接停止）。
            Task { [weak self] in
                if updated.proxyEnabled {
                    try? await self?.startProxyOnly(updated)
                } else {
                    self?.stopProxyOnly(updated)
                }
            }
        }
    }

    func delete(_ node: OpenCodeNode) throws {
        if node.id == activeNodeId {
            // 恢复失败时必须保留节点和恢复入口，不能留下“节点已删、接管会话仍在”的孤儿状态。
            try deactivate()
        }
        if proxyOnlyNodeIds.contains(node.id) {
            stopProxyOnly(node)
        }
        // 清理该节点的全局统一代理归因残留（永久累计 + 请求日志），避免 JSON 长期堆积。
        OpenCodeProxyRuntime.shared.purgeNode(node.id)
        nodes.removeAll { $0.id == node.id }
        save()
    }

    /// 复制节点：新 id/slug（归因独立），插在原节点之后；代理端口避让已占用端口。
    func duplicate(_ node: OpenCodeNode) {
        var copy = node
        copy.id = UUID().uuidString
        copy.name = node.displayName + " " + AppSettings.shared.t("(Copy)", "(副本)")
        copy.providerSlug = nil
        copy.createdAt = Date()
        copy.lastUsedAt = nil
        if copy.proxyEnabled {
            let usedPorts = Set(nodes.filter(\.proxyEnabled).map(\.proxyPort))
            while usedPorts.contains(copy.proxyPort) && copy.proxyPort < 65_535 {
                copy.proxyPort += 1
            }
        }
        ensureProviderSlug(&copy)
        if let index = nodes.firstIndex(where: { $0.id == node.id }) {
            nodes.insert(copy, at: index + 1)
        } else {
            nodes.append(copy)
        }
        for index in nodes.indices {
            nodes[index].sortOrder = index
        }
        save()
    }

    // MARK: - Common Config

    /// 按节点合并策略给出通用配置片段（不合并时为 nil），激活/预览/启动命令共用同一口径。
    func commonSettings(for node: OpenCodeNode) -> [String: Any]? {
        let mode = node.commonConfigMode ?? .followGlobal
        guard mode.shouldMerge(globalEnabled: globalConfig.enabled),
              !globalConfig.settings.isEmpty else { return nil }
        return globalConfig.settings
    }

    private func loadGlobalConfig() {
        guard let data = fileManager.contents(atPath: Self.globalConfigPath),
              let config = try? GlobalConfig.fromFileData(data) else { return }
        globalConfig = config
    }

    func saveGlobalConfig() {
        do {
            let data = try globalConfig.toFileData()
            let dir = (Self.globalConfigPath as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: Self.globalConfigPath), options: .atomic)
        } catch {
            openCodeStoreLog.error("Failed to save OpenCode global config: \(String(describing: error), privacy: .public)")
        }
        // 通用配置变化即时反映到生效中的节点。
        if let node = activeNode {
            Task { try? await activate(node) }
        }
    }

    /// Force SwiftUI to refresh file-resolution labels after an external file edit.
    func refreshConfigContext() {
        objectWillChange.send()
    }

    /// The user explicitly reviewed the current managed file and chose to keep
    /// those edits as the new pristine restore baseline.
    func acceptExternalConfigChanges() throws {
        try configManager.acceptExternalChanges()
        objectWillChange.send()
    }

    /// Explicit recovery path used after the user chooses to discard edits made
    /// outside AIUsage. Normal deactivation remains fail-closed.
    func discardExternalConfigChanges() throws {
        try configManager.restoreDiscardingExternalChanges()
        if let active = activeNode, active.proxyEnabled, !proxyOnlyNodeIds.contains(active.id) {
            proxyRuntime.stop(nodeId: active.id)
        }
        activeNodeId = nil
        save()
        objectWillChange.send()
    }

    // MARK: - Activation

    func activate(_ node: OpenCodeNode) async throws {
        // 与全局统一代理互斥：全局启用时由它独占受管层，每节点激活会覆盖全局受管块。
        if GlobalProxyManager.opencode.config.isEnabled {
            throw OpenCodeNodeStoreError.managedByGlobalProxy
        }
        let common = commonSettings(for: node)
        if node.proxyEnabled {
            // Codex 轨道（responses 透传）启动时强制要求 Key，缺失会让 QuotaServer
            // 静默不挂载代理路由，请求全 404——提前拦截给出可读错误。
            if node.protocolType == .openAIResponses, node.apiKey.nilIfBlank == nil {
                throw OpenCodeNodeStoreError.proxyRequiresAPIKey
            }
            // 该节点此前以仅代理运行：升级为激活（参数没变时进程原地复用，不闪断）。
            if proxyOnlyNodeIds.remove(node.id) != nil {
                save()
            }
            stopPreviousActiveProxyProcess(except: node.id)
            // 代理模式：先拉起本地透传进程，再把受管层指向它；写配置失败则回收进程。
            try await proxyRuntime.start(node: node)
            do {
                try configManager.activate(node: node, baseURLOverride: node.proxyLocalBaseURL, commonSettings: common)
            } catch {
                proxyRuntime.stop(nodeId: node.id)
                throw error
            }
        } else {
            stopPreviousActiveProxyProcess(except: node.id)
            try configManager.activate(node: node, commonSettings: common)
        }
        if let index = nodes.firstIndex(where: { $0.id == node.id }) {
            nodes[index].lastUsedAt = Date()
        }
        activeNodeId = node.id
        save()
        objectWillChange.send()
    }

    func deactivate() throws {
        try configManager.restore()
        // 先成功恢复配置再停代理；恢复被外部修改拦截时保持原路由可用。
        if let active = activeNode, active.proxyEnabled, !proxyOnlyNodeIds.contains(active.id) {
            proxyRuntime.stop(nodeId: active.id)
        }
        activeNodeId = nil
        save()
        objectWillChange.send()
    }

    /// 切换激活目标时回收上一个激活的代理节点进程（其进程随激活存在，
    /// 不属于仅代理集合时没人再需要它）。
    private func stopPreviousActiveProxyProcess(except newId: String) {
        guard let previous = activeNode, previous.proxyEnabled,
              previous.id != newId,
              !proxyOnlyNodeIds.contains(previous.id) else { return }
        proxyRuntime.stop(nodeId: previous.id)
    }

    // MARK: - Proxy-Only Mode
    // 与 Claude/Codex 节点的「仅代理」同语义：拉起本地透传进程暴露端口，但不接管
    // OpenCode 全局配置。可多个节点并行（各占一端口，端口冲突由运行时报可读错误）；
    // 激活节点的代理随激活运行，故激活中的节点不可（也无需）开仅代理。

    func toggleProxyOnly(_ node: OpenCodeNode) async throws {
        if proxyOnlyNodeIds.contains(node.id) {
            stopProxyOnly(node)
        } else {
            try await startProxyOnly(node)
        }
    }

    func startProxyOnly(_ node: OpenCodeNode) async throws {
        guard node.proxyEnabled, node.id != activeNodeId else { return }
        if node.protocolType == .openAIResponses, node.apiKey.nilIfBlank == nil {
            throw OpenCodeNodeStoreError.proxyRequiresAPIKey
        }
        try await proxyRuntime.start(node: node)
        proxyOnlyNodeIds.insert(node.id)
        save()
    }

    func stopProxyOnly(_ node: OpenCodeNode) {
        guard proxyOnlyNodeIds.remove(node.id) != nil else { return }
        proxyRuntime.stop(nodeId: node.id)
        save()
    }

    /// 启动对账：管理目标已不在受管状态（用户手动还原/删除）时清掉激活标记；
    /// 仅代理集合里不存在或已关掉代理模式的节点一并清理。
    func reconcileWithConfigFile() {
        var changed = false
        if activeNodeId != nil,
           configManager.managementState == .unmanaged,
           !configManager.isManaged {
            activeNodeId = nil
            changed = true
        }
        let validProxyOnlyIds = proxyOnlyNodeIds.filter { id in
            nodes.first { $0.id == id }?.proxyEnabled == true
        }
        if validProxyOnlyIds != proxyOnlyNodeIds {
            proxyOnlyNodeIds = validProxyOnlyIds
            changed = true
        }
        if changed { save() }
    }

    /// App 重启后恢复代理：激活中的代理模式节点其子进程已随上次退出而消亡，
    /// 而受管配置层仍指向本地端口，必须重新拉起，否则 OpenCode 请求全部失败。
    /// 仅代理节点同样恢复（外部工具可能仍指向这些端口）。
    private func restoreProxyIfNeeded() {
        // 与 Claude/Codex 一致：受「启动时自动恢复代理」设置控制。关闭时不接管，
        // 并还原受管配置层（避免它仍指向不会被拉起的本地端口）。
        guard AppSettings.shared.proxyAutoRestoreOnLaunch else {
            if activeNodeId != nil {
                do { try deactivate() } catch {
                    openCodeStoreLog.error("Failed to deactivate OpenCode node while auto-restore disabled: \(SensitiveDataRedactor.redactedMessage(for: error), privacy: .public)")
                }
            }
            return
        }

        // A missing/modified/precedence-shifted config is not a valid active
        // route. Keep the state visible for recovery, but do not start a proxy
        // that OpenCode cannot currently reach. The isManaged fallback keeps
        // pre-session versions recoverable after upgrade.
        let state = configManager.managementState
        guard state == .managed || (state == .unmanaged && configManager.isManaged) else { return }

        var toRestore: [OpenCodeNode] = []
        if let active = activeNode, active.proxyEnabled {
            toRestore.append(active)
        }
        for id in proxyOnlyNodeIds where id != activeNodeId {
            if let node = nodes.first(where: { $0.id == id && $0.proxyEnabled }) {
                toRestore.append(node)
            }
        }
        guard !toRestore.isEmpty else { return }
        // 预标记待恢复节点为「启动中」，覆盖 reap→launch 整段窗口，避免横幅闪现。
        let restoreIds = toRestore.map(\.id)
        proxyRuntime.beginRestoring(nodeIds: restoreIds)
        Task { [proxyRuntime] in
            // 先回收上次会话残留的孤儿 helper（与 Claude/Codex 启动恢复同序），再拉起，
            // 避免端口被自家孤儿占住导致绑定失败、横幅误报。
            await ProxyProcessInspector.shared.reapOrphanedHelpers()
            for node in toRestore {
                do {
                    try await proxyRuntime.start(node: node)
                } catch {
                    openCodeStoreLog.error("Failed to restore OpenCode proxy after relaunch: \(SensitiveDataRedactor.redactedMessage(for: error), privacy: .public)")
                }
            }
            proxyRuntime.endRestoring(nodeIds: restoreIds)
        }
    }

    /// 拖拽重排：按展示顺序整表重写 sortOrder 并保存。
    func applyOrder(ids: [String]) {
        let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        for index in nodes.indices {
            if let order = rank[nodes[index].id] {
                nodes[index].sortOrder = order
            }
        }
        sortNodes()
        save()
    }

    // MARK: - Import / Export

    /// 导出文件结构（与 StoreFile 区分：不带激活状态，便于跨机分享）。
    private struct ExportFile: Codable {
        var version: Int
        var nodes: [OpenCodeNode]
    }

    /// 导出全部节点为 JSON（含 API Key，与 Claude/Codex 节点导出同语义）。
    func exportNodes() throws -> Data {
        let file = ExportFile(version: Self.storeVersion, nodes: nodes)
        return try JSONEncoder.profileEncoder.encode(file)
    }

    /// 从导出 JSON 导入节点。重复判定：同 baseURL + 协议 + API Key 视为已存在并跳过。
    /// 返回 (导入数, 跳过数)。
    func importNodes(from data: Data) throws -> (imported: Int, skipped: Int) {
        let decoded: [OpenCodeNode]
        if let file = try? JSONDecoder.profileDecoder.decode(ExportFile.self, from: data) {
            decoded = file.nodes
        } else {
            // 容忍裸数组格式。
            decoded = try JSONDecoder.profileDecoder.decode([OpenCodeNode].self, from: data)
        }

        var imported = 0
        var skipped = 0
        for var node in decoded {
            let exists = nodes.contains {
                $0.baseURL == node.baseURL && $0.protocolType == node.protocolType && $0.apiKey == node.apiKey
            }
            if exists {
                skipped += 1
                continue
            }
            // 新身份落库：避免跨机 id/slug 冲突，归因 slug 按本机已有节点重新生成。
            node.id = UUID().uuidString
            node.providerSlug = nil
            node.createdAt = Date()
            node.lastUsedAt = nil
            node.sortOrder = (nodes.map(\.sortOrder).max() ?? 0) + 1
            ensureProviderSlug(&node)
            nodes.append(node)
            imported += 1
        }
        if imported > 0 {
            sortNodes()
            save()
        }
        return (imported, skipped)
    }

    /// 首次保存时生成稳定的节点 slug（统计归因键，改名不再变动）；同名冲突追加序号。
    private func ensureProviderSlug(_ node: inout OpenCodeNode) {
        guard node.providerSlug?.nilIfBlank == nil else { return }
        let base = node.preferredSlug()
        var candidate = base
        var suffix = 2
        let taken = Set(nodes.filter { $0.id != node.id }.compactMap { $0.providerSlug?.nilIfBlank })
        while taken.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        node.providerSlug = candidate
    }

    // MARK: - Persistence

    private func load() {
        guard let data = fileManager.contents(atPath: Self.storePath) else { return }
        do {
            let file = try JSONDecoder.profileDecoder.decode(StoreFile.self, from: data)
            nodes = file.nodes
            activeNodeId = file.activeNodeId
            proxyOnlyNodeIds = Set(file.proxyOnlyNodeIds ?? [])
            sortNodes()
            backfillProviderSlugs()
        } catch {
            openCodeStoreLog.error("Failed to load OpenCode nodes: \(String(describing: error), privacy: .public)")
        }
    }

    /// 给早期版本（无 providerSlug 字段）落库的节点补齐稳定 slug。
    private func backfillProviderSlugs() {
        var changed = false
        for index in nodes.indices where nodes[index].providerSlug?.nilIfBlank == nil {
            var node = nodes[index]
            ensureProviderSlug(&node)
            nodes[index] = node
            changed = true
        }
        if changed { save() }
    }

    private func save() {
        let file = StoreFile(
            version: Self.storeVersion,
            nodes: nodes,
            activeNodeId: activeNodeId,
            proxyOnlyNodeIds: proxyOnlyNodeIds.isEmpty ? nil : Array(proxyOnlyNodeIds).sorted()
        )
        do {
            let dir = (Self.storePath as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder.profileEncoder.encode(file)
            try data.write(to: URL(fileURLWithPath: Self.storePath), options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.storePath)
        } catch {
            openCodeStoreLog.error("Failed to save OpenCode nodes: \(String(describing: error), privacy: .public)")
        }
    }

    private func sortNodes() {
        nodes.sort {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.createdAt < $1.createdAt
        }
    }
}
