import Foundation
import Combine
import os.log
import QuotaBackend

// MARK: - Global Proxy Manager (track-generic)
// 编排某条轨的「全局统一代理」：把激活节点投影为上游、驱动 GlobalProxyRuntime 启停/热切换、
// 一次性接管/还原 CLI 配置（config.toml / settings.json / opencode.json）、持久化 GlobalProxyConfig。
// 只做调度，轨道差异（节点筛选、env/payload 投影、CLI 写入）全部下沉到 GlobalProxyTrackAdapter。
//
// 与每节点激活互斥：启用时停掉本轨当前激活节点并接管 CLI 配置；启用期间每节点激活被
// performActivationTransaction 兜底拦截。切换激活节点走 admin 热替换，不重写 CLI 配置、不重启进程。

private let globalProxyManagerLog = Logger(subsystem: "com.aiusage.desktop", category: "GlobalProxyManager")

@MainActor
final class GlobalProxyManager: ObservableObject {
    // 每条轨一个实例（独立持久化、独立常驻进程，可同时启用）。
    static let codex = GlobalProxyManager(track: .codex, adapter: CodexGlobalProxyAdapter())
    static let claude = GlobalProxyManager(track: .claude, adapter: ClaudeGlobalProxyAdapter(track: .claude))
    static let desktop = GlobalProxyManager(track: .desktop, adapter: ClaudeGlobalProxyAdapter(track: .desktop))
    static let opencode = GlobalProxyManager(track: .opencode, adapter: OpenCodeGlobalProxyAdapter())

    /// 兼容别名：既有 Codex 调用点（菜单栏 / 激活闸门 / 启动恢复）继续用 `.shared`。
    static var shared: GlobalProxyManager { codex }

    let track: GlobalProxyTrack
    private let adapter: GlobalProxyTrackAdapter
    private var runtime: GlobalProxyRuntime { adapter.runtime }

    @Published private(set) var config: GlobalProxyConfig
    @Published var operationError: String?
    @Published private(set) var isBusy = false
    private var leasedNodeId: String?

    private var nodeRuntimeConsumer: NodeRuntimeConsumer? {
        switch track {
        case .claude: return .code
        case .desktop: return .desktop
        default: return nil
        }
    }

    private init(track: GlobalProxyTrack, adapter: GlobalProxyTrackAdapter) {
        self.track = track
        self.adapter = adapter
        self.config = GlobalProxyStore.load(track: track)
        if (track == .claude || track == .desktop), config.effectiveAllowLAN {
            config.allowLAN = false
            _ = GlobalProxyStore.save(config, track: track)
        }
    }

    /// For the Claude page this remains the Claude Code consumer state; the
    /// shared runtime may continue running for Desktop after Code disconnects.
    var isEnabled: Bool {
        track == .claude ? config.effectiveClaudeCodeEnabled : config.isEnabled
    }
    /// Runtime ownership is broader than the visible Code connection state.
    /// Claude Desktop can be the only active consumer while `isEnabled` is
    /// intentionally false on the Code tab.
    var isRuntimeEnabled: Bool {
        track == .claude ? config.hasClaudeConsumers : config.isEnabled
    }
    var claudeConsumers: Set<ClaudeGatewayConsumer> {
        track == .claude ? config.claudeConsumers : []
    }
    func isClaudeConsumerAttached(_ consumer: ClaudeGatewayConsumer) -> Bool {
        claudeConsumers.contains(consumer)
    }
    var activeNodeId: String? { config.activeNodeId }
    var isProxyRunning: Bool { runtime.isProcessRunning }

    /// Rewrites only the CLI configuration after an external edit was accepted
    /// as the new baseline. The running proxy process is left untouched.
    func reapplyCLIConfig() throws {
        try adapter.activateCLIConfig(config)
    }

    /// 可参与全局代理的节点（由适配器按轨/接口筛选）。
    func availableNodes() -> [GlobalProxyNodeRef] { adapter.availableNodes(config: config) }

    func node(for id: String?) -> GlobalProxyNodeRef? {
        guard let id else { return nil }
        return adapter.availableNodes(config: config).first { $0.id == id }
    }

    /// 切换 OpenCode 接口协议（仅 OpenCode 轨；切换会清空已选激活节点，因为节点集合随之变化）。仅停用态可改。
    func updateOpenCodeInterface(_ interface: OpenCodeProtocol) {
        guard !config.isEnabled, track == .opencode else { return }
        guard config.openCodeInterface != interface else { return }
        config.openCodeInterface = interface
        config.activeNodeId = nil
        persist()
    }

    // MARK: - Settings (editable only while disabled)

    /// 更新端口 / 主虚拟模型 / client key。仅在停用态可改（运行态改端口会让 CLI 失联）。
    /// Codex/OpenCode 用此单模型入口；Claude 见 `updateClaudeModels`。
    func updateSettings(port: Int, virtualModel: String, clientKey: String) {
        guard !config.isEnabled else { return }
        config.port = max(1, min(65_535, port))
        config.virtualModel = virtualModel.trimmingCharacters(in: .whitespacesAndNewlines)
        config.clientKey = clientKey.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    /// 更新是否允许局域网访问。仅停用态可改（运行态改绑定地址需重启进程）。
    func updateAllowLAN(_ allowLAN: Bool) {
        guard !config.isEnabled else { return }
        config.allowLAN = allowLAN
        persist()
    }

    /// 更新 Claude 三层虚拟模型（写入 settings.json 的 opus/sonnet/haiku）。仅停用态可改。
    func updateClaudeModels(port: Int, opus: String, sonnet: String, haiku: String) {
        guard !config.isEnabled else { return }
        config.port = max(1, min(65_535, port))
        config.virtualModel = opus.trimmingCharacters(in: .whitespacesAndNewlines)
        config.sonnetModel = sonnet.trimmingCharacters(in: .whitespacesAndNewlines)
        config.haikuModel = haiku.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    func updateClaudeCodeCatalogMode(_ mode: ClaudeDesktopCatalogMode) async {
        guard track == .claude, !isBusy,
              config.effectiveClaudeCodeCatalogMode != mode else { return }
        operationError = nil
        let previousMode = config.claudeCodeCatalogMode
        config.claudeCodeCatalogMode = mode
        guard persist() else {
            config.claudeCodeCatalogMode = previousMode
            operationError = AppSettings.shared.t(
                "Could not save the Code model mode.",
                "无法保存 Code 模型模式。"
            )
            return
        }
        guard isEnabled else { return }
        // Reproject both sides of the product boundary: the Gateway tier
        // mapping changes with the mode, while settings.json controls the
        // model names loaded by new Claude Code processes.
        await reapplyActiveUpstream()
        if let failure = operationError {
            config.claudeCodeCatalogMode = previousMode
            _ = persist()
            await reapplyActiveUpstream()
            operationError = failure
            return
        }
        do {
            try adapter.activateCLIConfig(config)
        } catch {
            config.claudeCodeCatalogMode = previousMode
            _ = persist()
            await reapplyActiveUpstream()
            try? adapter.activateCLIConfig(config)
            operationError = error.localizedDescription
        }
    }

    /// Overrides one Code route for one node. The sparse override lives only
    /// in Code's product config; choosing the node default removes that route
    /// so later Node edits continue to flow through automatically.
    @discardableResult
    func updateClaudeCodeModelOverride(
        nodeID: String,
        route: ClaudeAppModelRoute,
        model: String
    ) async -> Bool {
        guard track == .claude, !isBusy,
              let node = ProxyViewModel.shared.configurations.first(where: {
                  $0.id == nodeID && ProxyNodeFamily.claude.contains($0.nodeType)
              }) else { return false }
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, node.runtimeModelCatalog.contains(normalized) else { return false }

        operationError = nil
        let previousOverrides = config.claudeCodeModelOverridesByNode
        var byNode = previousOverrides ?? [:]
        var override = byNode[nodeID] ?? ClaudeAppNodeModelOverride()
        let nodeDefault = nodeModelDefault(for: route, node: node)
        override.setModel(normalized == nodeDefault ? nil : normalized, for: route)
        if override.isEmpty {
            byNode.removeValue(forKey: nodeID)
        } else {
            byNode[nodeID] = override
        }
        config.claudeCodeModelOverridesByNode = byNode.isEmpty ? nil : byNode
        return await commitClaudeCodeModelOverrideChange(
            previousOverrides: previousOverrides,
            nodeID: nodeID
        )
    }

    /// Restores all Code tiers for this node to the node-owned defaults.
    @discardableResult
    func resetClaudeCodeModelOverrides(nodeID: String) async -> Bool {
        guard track == .claude, !isBusy,
              config.claudeCodeModelOverride(for: nodeID) != nil else { return false }
        operationError = nil
        let previousOverrides = config.claudeCodeModelOverridesByNode
        var byNode = previousOverrides ?? [:]
        byNode.removeValue(forKey: nodeID)
        config.claudeCodeModelOverridesByNode = byNode.isEmpty ? nil : byNode
        return await commitClaudeCodeModelOverrideChange(
            previousOverrides: previousOverrides,
            nodeID: nodeID
        )
    }

    private func commitClaudeCodeModelOverrideChange(
        previousOverrides: [String: ClaudeAppNodeModelOverride]?,
        nodeID: String
    ) async -> Bool {
        guard persist() else {
            config.claudeCodeModelOverridesByNode = previousOverrides
            operationError = AppSettings.shared.t(
                "Could not save the Code model override.",
                "无法保存 Code 模型覆盖。"
            )
            return false
        }
        guard isEnabled, config.activeNodeId == nodeID else { return true }

        if runtime.isProcessRunning {
            await reapplyActiveUpstream()
            if let failure = operationError {
                config.claudeCodeModelOverridesByNode = previousOverrides
                _ = persist()
                await reapplyActiveUpstream()
                operationError = failure
                return false
            }
        }
        do {
            try adapter.activateCLIConfig(config)
            return true
        } catch {
            let failure = error.localizedDescription
            config.claudeCodeModelOverridesByNode = previousOverrides
            _ = persist()
            if runtime.isProcessRunning { await reapplyActiveUpstream() }
            try? adapter.activateCLIConfig(config)
            operationError = failure
            return false
        }
    }

    /// Desktop overrides belong only to the four stable hot-switch routes.
    /// Full-catalog mode is an exact read-only view of the selected node.
    @discardableResult
    func updateClaudeDesktopModelOverride(
        nodeID: String,
        route: ClaudeAppModelRoute,
        model: String
    ) async -> Bool {
        guard track == .desktop, !isBusy,
              let node = ProxyViewModel.shared.configurations.first(where: {
                  $0.id == nodeID && ProxyNodeFamily.claude.contains($0.nodeType)
              }) else { return false }
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, node.runtimeModelCatalog.contains(normalized) else { return false }

        operationError = nil
        let previousOverrides = config.claudeDesktopModelOverridesByNode
        var byNode = previousOverrides ?? [:]
        var override = byNode[nodeID] ?? ClaudeAppNodeModelOverride()
        let nodeDefault = nodeModelDefault(for: route, node: node)
        override.setModel(normalized == nodeDefault ? nil : normalized, for: route)
        if override.isEmpty {
            byNode.removeValue(forKey: nodeID)
        } else {
            byNode[nodeID] = override
        }
        config.claudeDesktopModelOverridesByNode = byNode.isEmpty ? nil : byNode
        return await commitClaudeDesktopModelOverrideChange(
            previousOverrides: previousOverrides,
            nodeID: nodeID
        )
    }

    @discardableResult
    func resetClaudeDesktopModelOverrides(nodeID: String) async -> Bool {
        guard track == .desktop, !isBusy,
              config.claudeDesktopModelOverride(for: nodeID) != nil else { return false }
        operationError = nil
        let previousOverrides = config.claudeDesktopModelOverridesByNode
        var byNode = previousOverrides ?? [:]
        byNode.removeValue(forKey: nodeID)
        config.claudeDesktopModelOverridesByNode = byNode.isEmpty ? nil : byNode
        return await commitClaudeDesktopModelOverrideChange(
            previousOverrides: previousOverrides,
            nodeID: nodeID
        )
    }

    private func commitClaudeDesktopModelOverrideChange(
        previousOverrides: [String: ClaudeAppNodeModelOverride]?,
        nodeID: String
    ) async -> Bool {
        guard persist() else {
            config.claudeDesktopModelOverridesByNode = previousOverrides
            operationError = AppSettings.shared.t(
                "Could not save the Desktop model override.",
                "无法保存 Desktop 模型覆盖。"
            )
            return false
        }
        guard config.isEnabled,
              config.effectiveClaudeDesktopCatalogMode == .smartRoutes,
              config.activeNodeId == nodeID,
              runtime.isProcessRunning else { return true }

        await reapplyActiveUpstream()
        guard let failure = operationError else { return true }
        config.claudeDesktopModelOverridesByNode = previousOverrides
        _ = persist()
        await reapplyActiveUpstream()
        operationError = failure
        return false
    }

    private func nodeModelDefault(
        for route: ClaudeAppModelRoute,
        node: ProxyConfiguration
    ) -> String {
        switch route {
        case .defaultModel: return node.defaultModel
        case .opus: return node.modelMapping.bigModel.name
        case .sonnet: return node.modelMapping.middleModel.name
        case .haiku: return node.modelMapping.smallModel.name
        }
    }

    /// Stores the single localhost HTTPS endpoint used by Claude Desktop.
    /// It is intentionally independent from every upstream node: switching
    /// nodes changes only the gateway's upstream projection, never Desktop's
    /// endpoint. Active Desktop sessions must disconnect before this changes.
    @discardableResult
    func updateClaudeDesktopHTTPSPort(_ port: Int) -> Bool {
        guard track == .desktop,
              !isBusy,
              !config.isEnabled,
              (1_024...65_535).contains(port),
              port != config.port else { return false }
        operationError = nil
        let previousPort = config.claudeDesktopHTTPSPort
        config.claudeDesktopHTTPSPort = port
        guard persist() else {
            config.claudeDesktopHTTPSPort = previousPort
            operationError = AppSettings.shared.t(
                "Could not save the Desktop HTTPS port.",
                "无法保存 Desktop HTTPS 端口。"
            )
            return false
        }
        return true
    }

    /// 声明/取消节点某个上游模型的 1M 上下文能力。
    ///
    /// 能力存在节点上（`ProxyConfiguration.modelCatalog.supports1MModels`），Code 与 Desktop
    /// 共用同一份声明，所以写成功后要让**两条轨道**都热下发新目录——只刷一条会让另一条继续
    /// 拿旧能力表对外声明。两轨的 GlobalProxyConfig 是各自独立的文件，这里不碰它们。
    @discardableResult
    static func applyNodeSupports1M(
        nodeID: String,
        modelID: String,
        enabled: Bool
    ) async -> Bool {
        let claudeTracks = [GlobalProxyManager.claude, GlobalProxyManager.desktop]
        guard claudeTracks.allSatisfy({ !$0.isBusy }) else { return false }
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty,
              let node = ProxyViewModel.shared.configurations.first(where: { $0.id == nodeID }) else {
            return false
        }
        let previousEnabled = node.modelCatalog.supports1MModels.contains(normalizedModelID)
        let shouldRestartNodeRuntime = nodeRuntimeRequiresRestart(nodeID: nodeID)
        guard ProxyViewModel.shared.setSupports1M(
            nodeID: nodeID,
            modelID: normalizedModelID,
            enabled: enabled
        ) else { return false }

        var failure: String?
        for manager in claudeTracks {
            manager.operationError = nil
            guard manager.config.isEnabled,
                  manager.config.activeNodeId == nodeID,
                  manager.runtime.isProcessRunning else { continue }
            await manager.reapplyActiveUpstream()
            if let error = manager.operationError { failure = error }
        }

        if failure == nil, shouldRestartNodeRuntime {
            do {
                try await restartLeasedNodeRuntime(nodeID: nodeID)
            } catch {
                failure = SensitiveDataRedactor.redactedMessage(for: error)
            }
        }
        guard let failure else { return true }

        // 至少一条轨道没接受新目录：回滚声明并把两轨拉回与磁盘一致的状态，避免「UI 说开了、
        // 运行中的代理还按旧目录对外声明」这种半生效。
        guard ProxyViewModel.shared.setSupports1M(
            nodeID: nodeID,
            modelID: normalizedModelID,
            enabled: previousEnabled
        ) else {
            let rollbackFailure = AppSettings.shared.t(
                "The 1M setting failed and its saved value could not be rolled back.",
                "1M 设置应用失败，且无法回滚已保存的值。"
            )
            claudeTracks.forEach { $0.operationError = rollbackFailure }
            ProxyViewModel.shared.operationErrorMessage = rollbackFailure
            return false
        }
        for manager in claudeTracks where manager.config.isEnabled
            && manager.config.activeNodeId == nodeID
            && manager.runtime.isProcessRunning {
            await manager.reapplyActiveUpstream()
        }
        var finalFailure = failure
        if shouldRestartNodeRuntime {
            do {
                try await restartLeasedNodeRuntime(nodeID: nodeID)
            } catch {
                let rollbackRuntimeFailure = SensitiveDataRedactor.redactedMessage(for: error)
                finalFailure += AppSettings.shared.t(
                    " Rollback restart also failed: \(rollbackRuntimeFailure)",
                    " 回滚后的运行时重启也失败：\(rollbackRuntimeFailure)"
                )
            }
        }
        claudeTracks.forEach { $0.operationError = finalFailure }
        ProxyViewModel.shared.operationErrorMessage = finalFailure
        return false
    }

    /// 节点运行时没有 admin 热切换；被全局轨租借或直接激活时，1M 声明变更后需重启进程
    /// 才能让 QuotaServer 重新读取 `AIUSAGE_CLAUDE_SUPPORTS_1M_JSON`。
    private static func nodeRuntimeRequiresRestart(nodeID: String) -> Bool {
        let viewModel = ProxyViewModel.shared
        guard let config = viewModel.configurations.first(where: { $0.id == nodeID }),
              config.needsProxyProcess,
              viewModel.runtimeService.isProxyRunning(nodeID) else { return false }
        let leased = !viewModel.nodeRuntimeConsumers[nodeID, default: []].isEmpty
        let directlyActivated = viewModel.activatedConfigId == nodeID
        return leased || directlyActivated
    }

    private static func restartLeasedNodeRuntime(nodeID: String) async throws {
        let viewModel = ProxyViewModel.shared
        guard let config = viewModel.configurations.first(where: { $0.id == nodeID }),
              config.needsProxyProcess else { return }
        viewModel.runtimeService.stopProxyOnly(for: config)
        do {
            try await viewModel.runtimeService.startProxyOnly(for: config)
            viewModel.proxyRuntimeDownConfigIds.remove(nodeID)
        } catch {
            viewModel.proxyRuntimeDownConfigIds.insert(nodeID)
            globalProxyManagerLog.error(
                "Failed to restart node runtime after 1M catalog change for \(nodeID, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    /// Changes the public model surface exposed to Claude Desktop while
    /// preserving its product Gateway endpoint and active node. The subsequent
    /// upstream reapply drives the same profile refresh path as a node switch:
    /// smart routes normally remain live, while a changed full catalog reloads
    /// a running Desktop so its picker cannot become stale.
    func updateClaudeDesktopCatalogMode(_ mode: ClaudeDesktopCatalogMode) async {
        guard track == .desktop,
              !isBusy,
              config.effectiveClaudeDesktopCatalogMode != mode else { return }
        let previousMode = config.claudeDesktopCatalogMode
        config.claudeDesktopCatalogMode = mode
        guard persist() else {
            config.claudeDesktopCatalogMode = previousMode
            operationError = AppSettings.shared.t(
                "Could not save the Desktop model mode.",
                "无法保存 Desktop 模型模式。"
            )
            return
        }

        guard config.isEnabled,
              config.activeNodeId != nil,
              runtime.isProcessRunning else { return }
        await reapplyActiveUpstream()
        if let failure = operationError {
            config.claudeDesktopCatalogMode = previousMode
            _ = persist()
            await reapplyActiveUpstream()
            operationError = failure
        }
    }

    // MARK: - Enable / Disable / Switch

    func enable(activeNodeId nodeId: String) async {
        guard !isBusy else { return }
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        guard let node = node(for: nodeId),
              let env = runtimeEnvironment(nodeId: nodeId) else {
            operationError = AppSettings.shared.t("Selected node not found.", "未找到所选节点。")
            return
        }
        let previousConfig = config

        // 与每节点激活互斥：接管 CLI 配置前先停掉本轨当前激活的节点（干净交接）。
        let activePerNode = adapter.currentPerNodeActiveId()
        if let activePerNode {
            await adapter.deactivatePerNode(activePerNode)
            guard adapter.currentPerNodeActiveId() != activePerNode else {
                operationError = AppSettings.shared.t(
                    "Could not release the previous product route. Try again before starting the Gateway.",
                    "无法释放之前的应用路由，请重试后再启动 Gateway。"
                )
                return
            }
        }

        let previousNodeId = config.activeNodeId
        let previousLease = leasedNodeId
        var acquiredLease = false
        do {
            if let consumer = nodeRuntimeConsumer, previousLease != nodeId {
                try await ProxyViewModel.shared.acquireNodeRuntime(nodeId, consumer: consumer)
                acquiredLease = true
            }

            if runtime.isProcessRunning, previousNodeId != nodeId {
                guard let payload = adapter.switchPayload(config: config, nodeId: nodeId) else {
                    throw GlobalProxyRuntimeError.startFailed("selected node has no gateway route")
                }
                try await runtime.switchUpstream(
                    payload: payload,
                    adminPath: adapter.adminPath(config: config),
                    nodeId: node.id,
                    nodeName: node.name
                )
            } else {
                try await runtime.start(
                    port: config.port,
                    bindHost: runtimeBindAddress,
                    env: env,
                    nodeId: node.id,
                    nodeName: node.name,
                    httpsPort: track == .desktop ? config.effectiveClaudeDesktopHTTPSPort : nil,
                    tlsIdentityPath: track == .desktop ? TLSCertificateManager.shared.identityFilePath : nil
                )
            }
            config.activeNodeId = nodeId
            if track == .claude { config.claudeCodeEnabled = true }
            config.isEnabled = true
            try adapter.activateCLIConfig(config)
            guard persist() else {
                throw GlobalProxyRuntimeError.startFailed("failed to save Gateway state")
            }
            if let consumer = nodeRuntimeConsumer,
               let previousLease, previousLease != nodeId {
                ProxyViewModel.shared.releaseNodeRuntime(previousLease, consumer: consumer)
            }
            leasedNodeId = nodeRuntimeConsumer == nil ? nil : nodeId
            if track == .desktop {
                NotificationCenter.default.post(name: .claudeGatewayActiveNodeDidChange, object: nodeId)
            }
            globalProxyManagerLog.info("Global proxy (\(self.track.rawValue, privacy: .public)) enabled with node \(nodeId, privacy: .public)")
        } catch {
            let wasCancelled = error is CancellationError
            config = previousConfig
            if runtime.isProcessRunning,
               let previousNodeId,
               previousNodeId != nodeId,
               let previousNode = self.node(for: previousNodeId),
               let rollback = adapter.switchPayload(config: config, nodeId: previousNodeId) {
                try? await runtime.switchUpstream(
                    payload: rollback,
                    adminPath: adapter.adminPath(config: config),
                    nodeId: previousNode.id,
                    nodeName: previousNode.name
                )
            }
            if acquiredLease, let consumer = nodeRuntimeConsumer {
                ProxyViewModel.shared.releaseNodeRuntime(nodeId, consumer: consumer, promptWhenUnused: false)
            }
            if !wasCancelled, previousConfig.isEnabled == false { runtime.stop() }
            try? adapter.restoreCLIConfig()
            if let activePerNode {
                await adapter.activatePerNode(activePerNode)
            }
            // Cancellation is an internal hand-off, not a user-facing failure,
            // but it still needs the same direct-route rollback as any error.
            if wasCancelled { return }
            operationError = error.localizedDescription
            globalProxyManagerLog.error("Failed to enable global proxy (\(self.track.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
        }
    }

    @discardableResult
    func switchActiveNode(to nodeId: String) async -> Bool {
        guard !isBusy else { return false }
        guard isRuntimeEnabled, runtime.isProcessRunning else {
            await enable(activeNodeId: nodeId)
            return isRuntimeEnabled && runtime.isProcessRunning && config.activeNodeId == nodeId && operationError == nil
        }
        guard nodeId != config.activeNodeId else { return true }
        let previousNodeId = config.activeNodeId
        let previousConfig = config
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        guard let selectedNode = node(for: nodeId), let payload = adapter.switchPayload(config: config, nodeId: nodeId) else {
            operationError = AppSettings.shared.t("Selected node not found.", "未找到所选节点。")
            return false
        }

        var acquiredNewLease = false
        do {
            if let consumer = nodeRuntimeConsumer, leasedNodeId != nodeId {
                try await ProxyViewModel.shared.acquireNodeRuntime(nodeId, consumer: consumer)
                acquiredNewLease = true
            }
            try await runtime.switchUpstream(
                payload: payload,
                adminPath: adapter.adminPath(config: config),
                nodeId: selectedNode.id,
                nodeName: selectedNode.name
            )
            config.activeNodeId = nodeId
            if track == .codex || (track == .claude && config.effectiveClaudeCodeCatalogMode == .fullNodeCatalog) {
                try adapter.activateCLIConfig(config)
            }
            guard persist() else {
                config = previousConfig
                if let previousNodeId,
                   let previousNode = node(for: previousNodeId),
                   let rollback = adapter.switchPayload(config: config, nodeId: previousNodeId) {
                    try? await runtime.switchUpstream(
                        payload: rollback,
                        adminPath: adapter.adminPath(config: config),
                        nodeId: previousNode.id,
                        nodeName: previousNode.name
                    )
                }
                if track == .codex || (track == .claude && config.effectiveClaudeCodeCatalogMode == .fullNodeCatalog) {
                    try? adapter.activateCLIConfig(config)
                }
                throw GlobalProxyRuntimeError.startFailed("failed to save Gateway route")
            }
            if let consumer = nodeRuntimeConsumer,
               let previousNodeId, previousNodeId != nodeId {
                ProxyViewModel.shared.releaseNodeRuntime(previousNodeId, consumer: consumer)
            }
            leasedNodeId = nodeRuntimeConsumer == nil ? nil : nodeId
            if track == .desktop {
                NotificationCenter.default.post(name: .claudeGatewayActiveNodeDidChange, object: nodeId)
            }
            return true
        } catch {
            config = previousConfig
            if let previousNodeId,
               previousNodeId != nodeId,
               let previousNode = node(for: previousNodeId),
               let rollback = adapter.switchPayload(config: config, nodeId: previousNodeId) {
                try? await runtime.switchUpstream(
                    payload: rollback,
                    adminPath: adapter.adminPath(config: config),
                    nodeId: previousNode.id,
                    nodeName: previousNode.name
                )
            }
            if track == .codex || (track == .claude && config.effectiveClaudeCodeCatalogMode == .fullNodeCatalog) {
                try? adapter.activateCLIConfig(config)
            }
            if acquiredNewLease, let consumer = nodeRuntimeConsumer {
                ProxyViewModel.shared.releaseNodeRuntime(nodeId, consumer: consumer, promptWhenUnused: false)
            }
            operationError = error.localizedDescription
            globalProxyManagerLog.error("Failed to switch global proxy node (\(self.track.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// 节点配置已变（例如 CPA 从 convert 切到 Anthropic 透传）时，对当前激活节点强制再推上游。
    func reapplyActiveUpstream() async {
        guard !Task.isCancelled, !isBusy else { return }
        guard isRuntimeEnabled, runtime.isProcessRunning,
              let nodeId = config.activeNodeId else { return }
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        guard let node = node(for: nodeId),
              let payload = adapter.switchPayload(config: config, nodeId: nodeId) else { return }
        do {
            try await runtime.switchUpstream(
                payload: payload,
                adminPath: adapter.adminPath(config: config),
                nodeId: node.id,
                nodeName: node.name
            )
            if track == .desktop {
                NotificationCenter.default.post(name: .claudeGatewayActiveNodeDidChange, object: nodeId)
            }
        } catch is CancellationError {
            // 页面/任务生命周期取消不是代理不可达，不写入卡片错误或全局弹窗。
        } catch {
            operationError = error.localizedDescription
            globalProxyManagerLog.error(
                "Failed to reapply global proxy upstream (\(self.track.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)"
            )
        }
    }

    func disable() async {
        await disable(forceExternalChanges: false)
    }

    /// Explicit recovery path for a CLI config changed outside AIUsage. Only the
    /// user-facing recovery action should call this; ordinary disable remains
    /// fail-closed to avoid overwriting someone else's edit.
    func disableDiscardingExternalConfigChanges() async {
        await disable(forceExternalChanges: true)
    }

    private func disable(forceExternalChanges: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        let previousConfig = config
        do {
            if forceExternalChanges {
                try adapter.restoreCLIConfigDiscardingExternalChanges()
            } else {
                try adapter.restoreCLIConfig()
            }
        } catch {
            globalProxyManagerLog.error("Failed to restore CLI config on global proxy disable (\(self.track.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
            operationError = error.localizedDescription
            return
        }
        var stoppedRuntime = false
        if track == .claude {
            config.claudeCodeEnabled = false
            config.isEnabled = false
            runtime.stop()
            stoppedRuntime = true
        } else {
            runtime.stop()
            stoppedRuntime = true
            config.isEnabled = false
        }
        guard persist() else {
            config = previousConfig
            if stoppedRuntime { await restoreRuntimeBestEffort() }
            try? adapter.activateCLIConfig(config)
            operationError = AppSettings.shared.t(
                "Could not save the disconnected state; the previous route was restored.",
                "无法保存断开状态，已恢复之前的路由。"
            )
            return
        }
        if let consumer = nodeRuntimeConsumer, let leasedNodeId {
            ProxyViewModel.shared.releaseNodeRuntime(leasedNodeId, consumer: consumer)
            self.leasedNodeId = nil
        }
        globalProxyManagerLog.info("Global proxy (\(self.track.rawValue, privacy: .public)) disabled")
    }

    // MARK: - Launch Restore

    /// 启动时恢复：持久化为启用且激活节点仍存在 → 重新拉起进程；否则优雅停用并清理 CLI 配置。
    func restoreOnLaunch() async {
        let shouldRestore = track == .claude ? config.effectiveClaudeCodeEnabled : config.isEnabled
        guard shouldRestore else { return }
        let desktopRequiresRuntime = track == .desktop
        guard desktopRequiresRuntime || AppSettings.shared.proxyAutoRestoreOnLaunch else { return }

        guard let node = node(for: config.activeNodeId),
              let env = runtimeEnvironment(nodeId: node.id) else {
            let message = AppSettings.shared.t(
                "The previously selected node no longer exists. Choose another node to reconnect.",
                "之前选择的节点已不存在，请选择其它节点重新连接。"
            )
            globalProxyManagerLog.notice("Global proxy (\(self.track.rawValue, privacy: .public)) active node missing on launch")
            if track == .desktop { config.isEnabled = false; _ = persist() }
            await disable()
            operationError = message
            return
        }

        var acquiredLease = false
        do {
            if track == .desktop { try await TLSCertificateManager.shared.ensureCertificate() }
            if let consumer = nodeRuntimeConsumer {
                try await ProxyViewModel.shared.acquireNodeRuntime(node.id, consumer: consumer)
                acquiredLease = true
            }
            try await runtime.start(
                port: config.port,
                bindHost: runtimeBindAddress,
                env: env,
                nodeId: node.id,
                nodeName: node.name,
                httpsPort: track == .desktop ? config.effectiveClaudeDesktopHTTPSPort : nil,
                tlsIdentityPath: track == .desktop ? TLSCertificateManager.shared.identityFilePath : nil
            )
            try adapter.activateCLIConfig(config)
            leasedNodeId = nodeRuntimeConsumer == nil ? nil : node.id
            globalProxyManagerLog.info("Global proxy (\(self.track.rawValue, privacy: .public)) restored on launch with node \(node.id, privacy: .public)")
        } catch is CancellationError {
            if acquiredLease, let consumer = nodeRuntimeConsumer {
                ProxyViewModel.shared.releaseNodeRuntime(node.id, consumer: consumer, promptWhenUnused: false)
            }
            return
        } catch {
            if acquiredLease, let consumer = nodeRuntimeConsumer {
                ProxyViewModel.shared.releaseNodeRuntime(node.id, consumer: consumer, promptWhenUnused: false)
            }
            globalProxyManagerLog.error("Failed to restore global proxy (\(self.track.rawValue, privacy: .public)) on launch: \(String(describing: error), privacy: .public)")
            operationError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    /// Attach Desktop to its own product gateway. The selected Node Runtime may
    /// already be shared with Code or Science; only one node process exists.
    func attachClaudeDesktop(
        activeNodeId nodeId: String,
        httpsPort: Int,
        clientKey: String,
        tlsIdentityPath: String
    ) async throws {
        guard track == .desktop else { return }
        guard !isBusy else { throw GlobalProxyRuntimeError.startFailed("operation in progress") }
        guard (1_024...65_535).contains(httpsPort), httpsPort != config.port else {
            throw GlobalProxyRuntimeError.startFailed("invalid Claude Desktop HTTPS port")
        }
        let normalizedClientKey = clientKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedClientKey.isEmpty else {
            throw GlobalProxyRuntimeError.startFailed("Claude Desktop client key is unavailable")
        }
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        let previousConfig = config
        config.claudeDesktopHTTPSPort = httpsPort
        config.claudeDesktopClientKey = normalizedClientKey
        config.clientKey = normalizedClientKey
        guard let node = node(for: nodeId), let env = runtimeEnvironment(nodeId: nodeId) else {
            config = previousConfig
            throw GlobalProxyRuntimeError.startFailed(AppSettings.shared.t("Selected node not found.", "未找到所选节点。"))
        }

        let previousLease = leasedNodeId
        var acquiredLease = false
        do {
            if previousLease != nodeId {
                try await ProxyViewModel.shared.acquireNodeRuntime(nodeId, consumer: .desktop)
                acquiredLease = true
            }
            if runtime.isClaudeDesktopListenerRunning, previousConfig.activeNodeId != nodeId {
                guard let payload = adapter.switchPayload(config: config, nodeId: nodeId) else {
                    throw GlobalProxyRuntimeError.startFailed("selected node has no gateway route")
                }
                try await runtime.switchUpstream(
                    payload: payload,
                    adminPath: adapter.adminPath(config: config),
                    nodeId: node.id,
                    nodeName: node.name
                )
            } else if !runtime.isClaudeDesktopListenerRunning {
                try await runtime.start(
                    port: config.port,
                    bindHost: "127.0.0.1",
                    env: env,
                    nodeId: node.id,
                    nodeName: node.name,
                    httpsPort: config.effectiveClaudeDesktopHTTPSPort,
                    tlsIdentityPath: tlsIdentityPath
                )
            }
            config.activeNodeId = nodeId
            config.isEnabled = true
            guard persist() else {
                throw GlobalProxyRuntimeError.startFailed("failed to save Claude Desktop runtime state")
            }
            if let previousLease, previousLease != nodeId {
                ProxyViewModel.shared.releaseNodeRuntime(previousLease, consumer: .desktop)
            }
            leasedNodeId = nodeId
            NotificationCenter.default.post(name: .claudeGatewayActiveNodeDidChange, object: nodeId)
        } catch {
            config = previousConfig
            if acquiredLease {
                ProxyViewModel.shared.releaseNodeRuntime(nodeId, consumer: .desktop, promptWhenUnused: false)
            }
            await restoreRuntimeBestEffort()
            throw error
        }
    }

    func detachClaudeDesktop() async throws {
        guard track == .desktop else { return }
        guard !isBusy else { throw GlobalProxyRuntimeError.startFailed("operation in progress") }
        isBusy = true
        defer { isBusy = false }

        let previousConfig = config
        config.isEnabled = false
        do {
            runtime.stop()
            guard persist() else {
                throw GlobalProxyRuntimeError.startFailed("failed to save Claude Desktop runtime state")
            }
            if let leasedNodeId {
                ProxyViewModel.shared.releaseNodeRuntime(leasedNodeId, consumer: .desktop)
                self.leasedNodeId = nil
            }
        } catch {
            config = previousConfig
            await restoreRuntimeBestEffort()
            throw error
        }
    }

    private func restoreRuntimeBestEffort() async {
        guard isRuntimeEnabled,
              let nodeId = config.activeNodeId,
              let node = node(for: nodeId),
              let env = runtimeEnvironment(nodeId: nodeId) else {
            runtime.stop()
            return
        }
        try? await runtime.start(
            port: config.port,
            bindHost: runtimeBindAddress,
            env: env,
            nodeId: node.id,
            nodeName: node.name,
            httpsPort: track == .desktop ? config.effectiveClaudeDesktopHTTPSPort : nil,
            tlsIdentityPath: track == .desktop ? TLSCertificateManager.shared.identityFilePath : nil
        )
    }

    private func runtimeEnvironment(nodeId: String) -> [String: String]? {
        guard var env = adapter.startEnv(config: config, nodeId: nodeId) else { return nil }
        guard track == .desktop else { return env }
        env["ANTHROPIC_DESKTOP_API_KEY"] = config.effectiveClaudeDesktopClientKey
        return env
    }

    private var runtimeBindAddress: String {
        switch track {
        case .claude, .desktop, .science:
            return "127.0.0.1"
        case .codex, .opencode:
            return config.bindAddress
        }
    }

    @discardableResult
    private func persist() -> Bool {
        if track == .claude { config.ensureClaudeDesktopDefaults() }
        if track == .desktop { config.ensureDesktopDefaults() }
        return GlobalProxyStore.save(config, track: track)
    }
}

extension Notification.Name {
    static let claudeGatewayActiveNodeDidChange = Notification.Name("AIUsage.ClaudeGatewayActiveNodeDidChange")
}
