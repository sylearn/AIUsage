import Foundation
import Combine
import AppKit
import os.log
import QuotaBackend

// MARK: - Science Proxy Manager
// 编排「Claude Science 代理」轨：一键开始 = 起代理（复用 GlobalProxyRuntime.science）→ 确保虚拟登录
// （ScienceVirtualLogin）→ 准备并启动隔离沙箱（ScienceSandbox）→ 打开浏览器。切换激活节点走进程内
// 热替换上游（复用 Claude 轨 admin 路由），Science 无感、端口不变。
//
// 只做调度：协议转换/上游客户端复用现成 QuotaServer；节点筛选与 env/payload 投影复用
// ClaudeGlobalProxyAdapter（Science 推理即 Anthropic Messages API）。CPA 网关节点默认 Anthropic
// 透传；其它 OpenAI 兼容节点仍走 convert。
// 与 Claude Code 轨完全独立（独立端口 14402、独立进程、不写 ~/.claude/settings.json）。

private let scienceMgrLog = Logger(subsystem: "com.aiusage.desktop", category: "ScienceProxyManager")

@MainActor
final class ScienceProxyManager: ObservableObject {
    static let shared = ScienceProxyManager()

    private let track: GlobalProxyTrack = .science
    private let adapter = ClaudeGlobalProxyAdapter(track: .science)
    private var runtime: GlobalProxyRuntime { .science }
    private var leasedNodeId: String?

    @Published private(set) var config: GlobalProxyConfig
    @Published var operationError: String?
    @Published private(set) var isBusy = false
    /// 沙箱 Science 是否已就绪（/health 探测）。
    @Published private(set) var sandboxHealthy = false

    private init() {
        self.config = GlobalProxyStore.load(track: .science)
        // Science is an application-local adapter. Network exposure belongs
        // to Node runtimes, while both the inference bridge and web surface
        // stay on loopback.
        if config.effectiveAllowLAN {
            config.allowLAN = false
            _ = GlobalProxyStore.save(config, track: .science)
        }
    }

    // MARK: - Derived

    var isEnabled: Bool { config.isEnabled }
    var activeNodeId: String? { config.activeNodeId }
    var isProxyRunning: Bool { runtime.isProcessRunning }
    var scienceInstalled: Bool { ScienceSandbox.isInstalled }
    var sandboxHome: String { sandboxPaths.home }
    /// 当前沙箱工作区路径集（接管模式仍返回沙箱路径，仅供打开/重置沙箱目录用）。
    var sandboxPaths: ScienceSandboxPaths {
        ScienceSandboxPaths.make(workspaceId: config.effectiveActiveScienceWorkspaceId)
    }
    /// 是否接管真实实例（双击桌面 app 也免登录）。
    var adoptReal: Bool { config.effectiveAdoptReal }
    /// 浏览器实际访问的公开端口。两种模式都由 `ScienceAuthProxy` 监听。
    var listenPort: Int { endpointPlan.publicPort }

    /// Science owns two additional listeners beyond its inference Gateway.
    /// Publishing them to the central arbiter prevents another product from
    /// killing or colliding with the public/auth and daemon ports.
    func runningPortOwners() -> [ProxyPortArbiter.Owner] {
        guard config.isEnabled, sandboxHealthy, ScienceAuthProxy.shared.isRunning else { return [] }
        let plan = endpointPlan
        return [ProxyPortArbiter.Owner(
            id: "__aiusage_science_surface__",
            ports: [plan.publicPort, plan.daemonPort],
            track: AppSettings.shared.t("Claude Science", "Claude Science"),
            label: node(for: config.activeNodeId)?.name ?? ""
        )]
    }

    /// 浏览器永远只接触公开反代；daemon 留在独立内部端口。
    /// 这样 sandbox 与 adopt 共用同一条即时 `/api/models` 与免登录链路。
    private var endpointPlan: ScienceProxyEndpointPlan {
        if config.effectiveAdoptReal {
            return ScienceProxyEndpointPlan(
                mode: .adopt,
                publicPort: GlobalProxyConfig.realInstancePort,
                daemonPort: GlobalProxyConfig.realInstanceInternalPort,
                dataDir: ScienceRealAdopt.adoptDataDir
            )
        }
        let paths = sandboxPaths
        return ScienceProxyEndpointPlan(
            mode: .sandbox,
            publicPort: config.effectiveSciencePort,
            daemonPort: GlobalProxyConfig.defaultScienceSandboxInternalPort,
            dataDir: paths.dataDir
        )
    }

    /// 可参与的上游节点（Claude 家族节点，与「Claude Code 代理」共享节点池）。
    func availableNodes() -> [GlobalProxyNodeRef] { adapter.availableNodes(config: config) }

    func node(for id: String?) -> GlobalProxyNodeRef? {
        guard let id else { return nil }
        return availableNodes().first { $0.id == id }
    }

    /// Build the Science picker from the node's authoritative model catalog.
    /// Legacy nodes with an empty catalog fall back to the
    /// configured default and three tier mappings.
    /// The exact catalog exposed by Science for a selected node. The management
    /// view uses the same value so its preview cannot drift from the HTTP API.
    func modelCatalog(for nodeId: String) -> ScienceModelCatalog? {
        guard let node = ProxyViewModel.shared.configurations.first(where: {
            $0.id == nodeId && ProxyNodeFamily.claude.contains($0.nodeType)
        }) else { return nil }

        var protocolCatalog = ScienceModelProtocolAdapter(
            upstreamModels: node.modelCatalog.models,
            requestedDefault: node.defaultModel
        )
        if protocolCatalog.models.isEmpty {
            protocolCatalog = ScienceModelProtocolAdapter(
                upstreamModels: [
                    node.defaultModel,
                    node.modelMapping.bigModel.name,
                    node.modelMapping.middleModel.name,
                    node.modelMapping.smallModel.name,
                ],
                requestedDefault: node.defaultModel
            )
        }
        guard let defaultModelID = protocolCatalog.defaultModelID,
              let defaultUpstream = protocolCatalog.defaultUpstreamModel else { return nil }

        let models = protocolCatalog.models.map { model -> ScienceModelCatalog.Model in
            return ScienceModelCatalog.Model(
                id: model.id,
                upstreamModel: model.upstreamModel,
                displayName: model.displayName,
                description: scienceModelDescription(node: node, upstreamModel: model.upstreamModel),
                overflow: false
            )
        }
        return ScienceModelCatalog(
            nodeID: node.id,
            nodeName: node.name,
            models: models,
            defaultModelID: defaultModelID,
            defaultUpstreamModel: defaultUpstream
        )
    }

    /// The node exists but no usable model catalog could be produced (empty
    /// model library and blank default/tier mappings). Distinct from a deleted
    /// node so the user knows to fix the node's model configuration.
    private static func emptyCatalogMessage(nodeName: String) -> String {
        AppSettings.shared.t(
            "Node \"\(nodeName)\" has no usable models. Sync available models in the node editor (or set a default model) and try again.",
            "节点「\(nodeName)」没有可用模型。请先在节点编辑器中同步可用模型（或设置默认模型）后重试。"
        )
    }

    private func scienceModelDescription(node: ProxyConfiguration, upstreamModel: String) -> String {
        guard let pricing = node.pricingForModel(upstreamModel),
              pricing.inputPerMillion > 0 || pricing.outputPerMillion > 0 else {
            return "AIUsage node · \(node.name)"
        }
        let symbol = pricing.currency == .usd ? "$" : "¥"
        let input = Self.compactPrice(pricing.inputPerMillion)
        let output = Self.compactPrice(pricing.outputPerMillion)
        return "\(node.name) · \(symbol)\(input) input / \(symbol)\(output) output per 1M"
    }

    private static func compactPrice(_ value: Double) -> String {
        String(format: "%.6g", value)
    }

    private func injectCatalog(_ catalog: ScienceModelCatalog, into environment: inout [String: String]) {
        let upstreamModels = catalog.models.map(\.upstreamModel)
        if let data = try? JSONEncoder().encode(upstreamModels),
           let json = String(data: data, encoding: .utf8) {
            environment["AIUSAGE_SCIENCE_MODELS_JSON"] = json
        }
        environment["AIUSAGE_SCIENCE_DEFAULT_MODEL"] = catalog.defaultUpstreamModel
        environment["AIUSAGE_SCIENCE_MODEL_CATALOG"] = "1"
        environment["AIUSAGE_SCIENCE_EXACT_MODELS"] = "1"
    }

    private func normalizePersistedSelections(
        for catalog: ScienceModelCatalog,
        dataDir: String
    ) async throws -> ScienceSelectionNormalizer.Result {
        let modelIDs = Set(catalog.models.map(\.id))
        do {
            return try await Self.runNormalization(dataDir: dataDir, modelIDs: modelIDs)
        } catch let error as ScienceSelectionNormalizer.NormalizationError
            where Self.isTransientDatabaseContention(error) {
            // Hot-switch normalizes while the daemon still holds the database.
            // One short backoff absorbs a daemon write transaction that
            // outlives the normalizer's SQLite busy timeout.
            try? await Task.sleep(nanoseconds: 700_000_000)
            return try await Self.runNormalization(dataDir: dataDir, modelIDs: modelIDs)
        }
    }

    private static func runNormalization(
        dataDir: String,
        modelIDs: Set<String>
    ) async throws -> ScienceSelectionNormalizer.Result {
        try await Task.detached(priority: .utility) {
            try ScienceSelectionNormalizer.normalize(
                dataDir: dataDir,
                currentModelIDs: modelIDs
            )
        }.value
    }

    private static func isTransientDatabaseContention(
        _ error: ScienceSelectionNormalizer.NormalizationError
    ) -> Bool {
        guard case .database(let message) = error else { return false }
        let value = message.lowercased()
        return value.contains("database is locked") || value.contains("busy")
    }

    private func endpointValidationError(for plan: ScienceProxyEndpointPlan) -> String? {
        let reservedInternalPorts = Set([
            GlobalProxyConfig.realInstancePort,
            GlobalProxyConfig.realInstanceInternalPort,
            GlobalProxyConfig.defaultScienceSandboxInternalPort,
        ])
        switch plan.validationIssue(proxyPort: config.port, reservedPorts: reservedInternalPorts) {
        case .duplicatePort:
            return AppSettings.shared.t(
                "Port conflict: the inference proxy (\(config.port)), Science entry (\(plan.publicPort)), and internal daemon (\(plan.daemonPort)) must use different ports.",
                "端口冲突：推理代理（\(config.port)）、Science 入口（\(plan.publicPort)）和内部 daemon（\(plan.daemonPort)）必须使用不同端口。"
            )
        case .reservedPort:
            let reserved = reservedInternalPorts.sorted().map(String.init).joined(separator: ", ")
            return AppSettings.shared.t(
                "The selected port is reserved by Claude Science. Use a different proxy/Science port (reserved: \(reserved)).",
                "所选端口已被 Claude Science 内部链路保留。请更换代理或 Science 端口（保留：\(reserved)）。"
            )
        case nil:
            if let conflict = ProxyPortArbiter.conflict(
                forPorts: [plan.publicPort, plan.daemonPort],
                excluding: "__aiusage_science_surface__"
            ) {
                let owner = conflict.label.isEmpty ? conflict.track : "\(conflict.track) · \(conflict.label)"
                return AppSettings.shared.t(
                    "Science port \(conflict.port) is already used by \(owner). Stop it or choose another Science port.",
                    "Science 端口 \(conflict.port) 已被 \(owner) 占用。请先停用该服务，或更换 Science 端口。"
                )
            }
            return nil
        }
    }

    // MARK: - Settings（仅停用态可改）

    func updateSettings(proxyPort: Int, sciencePort: Int) {
        guard !config.isEnabled else { return }
        config.port = max(1, min(65_535, proxyPort))
        let sp = max(1, min(65_535, sciencePort))
        config.sciencePort = (sp == 8765) ? GlobalProxyConfig.defaultScienceListenPort : sp
        config.ensureScienceWorkspaceDefaults()
        persist()
    }

    /// 切换「接管真实实例」（仅停用态可改）。开启后双击桌面 app 也免登录；工作区切换在接管态不可用。
    func setAdoptReal(_ on: Bool) {
        guard !config.isEnabled else { return }
        config.adoptRealInstance = on
        persist()
    }

    /// Compatibility shim for older callers/configurations. Science remains local-only.
    func updateAllowLAN(_ allowLAN: Bool) {
        guard !config.isEnabled else { return }
        config.allowLAN = false
        persist()
    }

    // MARK: - Workspaces（仅沙箱；接管态忽略）

    func addWorkspace(named name: String) {
        guard !config.isEnabled, !config.effectiveAdoptReal else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        config.ensureScienceWorkspaceDefaults()
        let id = UUID().uuidString.lowercased()
        var list = config.effectiveScienceWorkspaces
        list.append(ScienceWorkspace(id: id, name: trimmed))
        config.scienceWorkspaces = list
        config.activeScienceWorkspaceId = id
        config.ensureScienceWorkspaceDefaults()
        persist()
    }

    func renameWorkspace(id: String, to name: String) {
        guard !config.isEnabled, !config.effectiveAdoptReal else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        config.ensureScienceWorkspaceDefaults()
        guard var list = config.scienceWorkspaces,
              let idx = list.firstIndex(where: { $0.id == id }) else { return }
        list[idx].name = trimmed
        config.scienceWorkspaces = list
        persist()
    }

    func deleteWorkspace(id: String) {
        guard !config.isEnabled, !config.effectiveAdoptReal else { return }
        config.ensureScienceWorkspaceDefaults()
        var list = config.effectiveScienceWorkspaces
        guard list.count > 1, list.contains(where: { $0.id == id }) else {
            operationError = AppSettings.shared.t(
                "Keep at least one workspace.",
                "至少保留一个工作区。"
            )
            return
        }
        list.removeAll { $0.id == id }
        config.scienceWorkspaces = list
        if config.activeScienceWorkspaceId == id {
            config.activeScienceWorkspaceId = list[0].id
        }
        config.ensureScienceWorkspaceDefaults()
        persist()
        // 删除磁盘目录（护栏：必须在 workspaces/<id>/home 下）
        let home = ScienceSandboxPaths.homePath(forWorkspaceId: id)
        let root = ScienceSandboxPaths.sandboxRoot
        let resolved = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let expectedPrefix = (resolvedRoot as NSString).appendingPathComponent("workspaces") + "/"
        guard resolved.hasPrefix(expectedPrefix) else { return }
        let workspaceRoot = (home as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: workspaceRoot)
    }

    /// 切换激活工作区。运行中会停掉再以新目录重启。
    func selectWorkspace(id: String) async {
        guard !config.effectiveAdoptReal else { return }
        config.ensureScienceWorkspaceDefaults()
        guard config.effectiveScienceWorkspaces.contains(where: { $0.id == id }) else { return }
        guard id != config.effectiveActiveScienceWorkspaceId else { return }

        let wasRunning = config.isEnabled
        let nodeId = config.activeNodeId
        if wasRunning {
            await stop()
        }
        config.activeScienceWorkspaceId = id
        config.ensureScienceWorkspaceDefaults()
        persist()
        if wasRunning, let nodeId {
            await start(activeNodeId: nodeId)
        }
    }

    // MARK: - Start / Stop / Switch

    /// 一键开始：起推理代理 → 起内部 Science daemon → 起公开认证/目录反代 → （可选）开浏览器。
    func start(activeNodeId nodeId: String, openBrowserOnReady: Bool = true) async {
        guard !isBusy else { return }
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        // restoreOnLaunch 进入时持久态仍是 enabled。先降为停用，只有完整公开链路
        // 自探成功后再重新提交，保证任何早退/崩溃都不会留下“界面显示运行、实际已回滚”。
        let wasPersistedAsEnabled = config.isEnabled
        if wasPersistedAsEnabled {
            config.isEnabled = false
            persist()
        }
        let endpoints = endpointPlan

        // Every start attempt begins from one known-empty stack. This also
        // cleans detached daemon/lock leftovers before restore-time guards can
        // return (missing app, deleted node, or invalid ports).
        await teardownScienceStack(endpoints)
        guard scienceInstalled else {
            operationError = ScienceSandboxError.scienceNotInstalled.errorDescription
            return
        }

        guard let node = node(for: nodeId),
              var env = adapter.startEnv(config: config, nodeId: nodeId) else {
            operationError = AppSettings.shared.t("Selected node not found.", "未找到所选节点。")
            return
        }
        guard let catalog = modelCatalog(for: nodeId) else {
            operationError = Self.emptyCatalogMessage(nodeName: node.name)
            return
        }
        // Science 与 Claude Code 的关键差异：Science daemon 每次推理都带它自造的虚拟 OAuth Bearer，
        // 而非我们的固定 client key。若代理要求 client key（ANTHROPIC_API_KEY），入站会被判 401，
        // Science 误报「session no longer valid」。因此这里剥掉 client key → 代理对入站鉴权放行、
        // 剥离并忽略 Science 的 Bearer，再注入节点真实上游 key（对齐 CSswitch 的 strip-and-ignore）。
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        injectCatalog(catalog, into: &env)

        if let validationError = endpointValidationError(for: endpoints) {
            operationError = validationError
            return
        }
        sandboxHealthy = false

        // The daemon is stopped here, so normalize stale AIUsage transport
        // aliases before SQLite is reopened. Schema/trigger guards fail closed;
        // a failed migration never launches a partially compatible session.
        do {
            let result = try await normalizePersistedSelections(for: catalog, dataDir: endpoints.dataDir)
            if result.normalizedFrameCount > 0 || result.skippedSchemaCount > 0 {
                scienceMgrLog.info(
                    "Science selection normalization: databases=\(result.databaseCount), normalized=\(result.normalizedFrameCount), skippedSchemas=\(result.skippedSchemaCount)"
                )
            }
        } catch {
            operationError = AppSettings.shared.t(
                "Couldn't update saved Claude Science model selections: \(error.localizedDescription)",
                "无法更新 Claude Science 已保存的模型选择：\(error.localizedDescription)"
            )
            scienceMgrLog.error("Science selection normalization failed: \(String(describing: error), privacy: .public)")
            return
        }

        // 与 Claude Code 每节点激活互斥性无关（Science 不写 settings.json），此处不接管任何 CLI 配置。
        // 1) 起代理进程（固定端口，复用 Claude 转换链路）。
        do {
            try await ProxyViewModel.shared.acquireNodeRuntime(nodeId, consumer: .science)
            leasedNodeId = nodeId
            try await runtime.start(port: config.port, bindHost: "127.0.0.1", env: env, nodeId: node.id, nodeName: node.name)
        } catch is CancellationError {
            // Release the Node Runtime lease acquired by this start attempt.
            // A newer lifecycle operation will acquire its own lease.
            await teardownScienceStack(endpoints)
            return
        } catch {
            await teardownScienceStack(endpoints)
            operationError = error.localizedDescription
            scienceMgrLog.error("Failed to start Science proxy: \(String(describing: error), privacy: .public)")
            return
        }

        // 2) 两种模式都只在内部端口启动 daemon；浏览器入口稍后统一交给 ScienceAuthProxy。
        let proxyPort = config.port
        let email = config.effectiveSandboxEmail
        do {
            if endpoints.adopting {
                try await Task.detached(priority: .userInitiated) {
                    // 解耦版：清场（退桌面 app + 腾端口 + 删残留劫持锁）→ 独立 data-dir 起虚拟登录 daemon（内部端口）。
                    // 绝不碰真实 ~/.claude-science 凭证；仅劫持它的 operon.lock（运行期文件，停用即删）。
                    ScienceRealAdopt.prepareForAdopt()
                    try ScienceRealAdopt.startInternalDaemon(proxyPort: proxyPort, email: email)
                }.value
            } else {
                let paths = ScienceSandboxPaths.make(workspaceId: config.effectiveActiveScienceWorkspaceId)
                try await Task.detached(priority: .userInitiated) {
                    // 迁移旧版“daemon 直接监听公开端口”的残留实例，然后在专用内部端口重启。
                    try? ScienceSandbox.stop(paths: paths)
                    try ScienceSandbox.prepare(paths: paths)
                    _ = try ScienceVirtualLogin.ensure(authDir: paths.dataDir, email: email, sandboxRoot: paths.home)
                    try ScienceSandbox.launch(
                        paths: paths,
                        sciencePort: endpoints.daemonPort,
                        proxyPort: proxyPort
                    )
                }.value
            }
        } catch {
            await teardownScienceStack(endpoints)
            operationError = error.localizedDescription
            scienceMgrLog.error("Failed to launch Science: \(String(describing: error), privacy: .public)")
            return
        }

        // 3) 内部 daemon 必须健康；sandbox 不再允许“未就绪但仍落激活态”。
        guard await ScienceSandbox.waitForHealth(sciencePort: endpoints.daemonPort) else {
            await teardownScienceStack(endpoints)
            operationError = endpoints.adopting
                ? AppSettings.shared.t(
                    "The adopted Claude Science daemon didn't become healthy in time.",
                    "被接管的 Claude Science daemon 未能在预期时间内就绪。"
                )
                : ScienceSandboxError.healthTimeout.errorDescription
            scienceMgrLog.error("Science start aborted: internal daemon unhealthy on :\(endpoints.daemonPort)")
            return
        }

        // 4) 公开入口统一由反代提供：注入本地会话、拦截最终 /api/models，并设置 no-store。
        do {
            try await ScienceAuthProxy.shared.start(
                listenPort: endpoints.publicPort,
                upstreamPort: endpoints.daemonPort,
                dataDir: endpoints.dataDir,
                modelCatalog: catalog
            )
        } catch {
            await teardownScienceStack(endpoints)
            operationError = error.localizedDescription
            scienceMgrLog.error("Science start aborted: auth proxy startup failed: \(String(describing: error), privacy: .public)")
            return
        }

        if endpoints.adopting {
            await Task.detached(priority: .userInitiated) { ScienceRealAdopt.hijackLock() }.value
        }

        // 5) 从浏览器真正访问的公开端口自探，只有完整链路返回已登录页才落激活态。
        let probe = await ScienceAuthProxy.shared.probe(listenPort: endpoints.publicPort)
        guard probe.succeeded else {
            await teardownScienceStack(endpoints)
            let baseMessage = endpoints.adopting
                ? AppSettings.shared.t(
                    "The login-free proxy on 8765 didn't serve a logged-in page. Aborted and restored your real login.",
                    "8765 免登录反代未能返回已登录页，已中止并还原真实登录。"
                )
                : AppSettings.shared.t(
                    "The sandbox Science entry didn't serve a logged-in page. Startup was rolled back.",
                    "沙箱 Science 入口未能返回已登录页，已回滚本次启动。"
                )
            operationError = "\(baseMessage)\n\(probe.summary)"
            scienceMgrLog.error("Science start aborted: public endpoint :\(endpoints.publicPort) self-probe failed: \(probe.summary, privacy: .public)")
            return
        }
        sandboxHealthy = true

        // 6) 持久化激活态；公开入口已通过自探，可直接打开裸地址。
        config.isEnabled = true
        config.activeNodeId = nodeId
        persist()
        scienceMgrLog.info("Science proxy started (proxy=\(proxyPort), public=\(endpoints.publicPort), daemon=\(endpoints.daemonPort), adoptReal=\(endpoints.adopting))")
        if openBrowserOnReady {
            openInBrowser()
        }
    }

    /// 统一回滚：先停公开反代，再按模式停止独立 daemon。只有 adopt 会删除被劫持的真实运行期 lock；
    /// sandbox 始终只操作自己的 data-dir，绝不触碰真实 ~/.claude-science。
    private func teardownScience(_ endpoints: ScienceProxyEndpointPlan) async {
        ScienceAuthProxy.shared.stop()
        let sandboxPaths = self.sandboxPaths
        await Task.detached(priority: .userInitiated) {
            if endpoints.adopting {
                ScienceRealAdopt.stopAdoptedDaemon()
            } else {
                try? ScienceSandbox.stop(paths: sandboxPaths)
            }
        }.value
        sandboxHealthy = false
    }

    /// Idempotent full-stack teardown used by every startup rollback and
    /// restore guard. Keeping runtime ownership beside endpoint teardown avoids
    /// a detached daemon/lock surviving an early return.
    private func teardownScienceStack(_ endpoints: ScienceProxyEndpointPlan) async {
        await teardownScience(endpoints)
        // A crash while the *other* mode was active can leave its detached
        // daemon running (modes use distinct ports, so it would linger
        // silently). The strict managed-lock stopper only ever touches
        // AIUsage-owned data dirs, so sweeping here is safe and idempotent.
        let otherModeDataDir = endpoints.adopting
            ? sandboxPaths.dataDir
            : ScienceManagedDaemonStopper.managedAdoptDataDir
        await Task.detached(priority: .utility) {
            ScienceManagedDaemonStopper.stopFromManagedLock(dataDir: otherModeDataDir)
        }.value
        runtime.stop()
        if let leasedNodeId {
            ProxyViewModel.shared.releaseNodeRuntime(leasedNodeId, consumer: .science)
            self.leasedNodeId = nil
        }
    }

    /// 热切换激活上游节点：进程不重启、Science 无感。
    func switchActiveNode(to nodeId: String) async {
        guard !isBusy else { return }
        guard config.isEnabled, runtime.isProcessRunning else {
            await start(activeNodeId: nodeId)
            return
        }
        guard nodeId != config.activeNodeId else { return }
        let previousNodeId = leasedNodeId ?? config.activeNodeId
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        guard let node = node(for: nodeId),
              var payload = adapter.switchPayload(config: config, nodeId: nodeId) else {
            operationError = AppSettings.shared.t("Selected node not found.", "未找到所选节点。")
            return
        }
        guard let catalog = modelCatalog(for: nodeId) else {
            operationError = Self.emptyCatalogMessage(nodeName: node.name)
            return
        }
        payload["availableModels"] = catalog.models.map(\.upstreamModel)
        payload["defaultModel"] = catalog.defaultUpstreamModel
        var acquiredNewLease = false
        do {
            if leasedNodeId != nodeId {
                try await ProxyViewModel.shared.acquireNodeRuntime(nodeId, consumer: .science)
                acquiredNewLease = true
            }
            try await runtime.switchUpstream(
                payload: payload,
                adminPath: adapter.adminPath(config: config),
                nodeId: node.id,
                nodeName: node.name
            )
            ScienceAuthProxy.shared.updateModelCatalog(catalog)
            config.activeNodeId = nodeId
            persist()
            if let previousNodeId, previousNodeId != nodeId {
                ProxyViewModel.shared.releaseNodeRuntime(previousNodeId, consumer: .science)
            }
            leasedNodeId = nodeId

            do {
                let result = try await normalizePersistedSelections(
                    for: catalog,
                    dataDir: endpointPlan.dataDir
                )
                if result.normalizedFrameCount > 0 || result.skippedSchemaCount > 0 {
                    scienceMgrLog.info(
                        "Science hot-switch selection normalization: databases=\(result.databaseCount), normalized=\(result.normalizedFrameCount), skippedSchemas=\(result.skippedSchemaCount)"
                    )
                }
            } catch {
                operationError = AppSettings.shared.t(
                    "The node switched, but saved Claude Science model selections couldn't be updated: \(error.localizedDescription)",
                    "节点已切换，但无法更新 Claude Science 已保存的模型选择：\(error.localizedDescription)"
                )
                scienceMgrLog.error("Science hot-switch selection normalization failed: \(String(describing: error), privacy: .public)")
            }
        } catch {
            if acquiredNewLease {
                ProxyViewModel.shared.releaseNodeRuntime(nodeId, consumer: .science, promptWhenUnused: false)
            }
            operationError = error.localizedDescription
            scienceMgrLog.error("Failed to hot-switch Science node: \(String(describing: error), privacy: .public)")
        }
    }

    /// CPA/节点配置变更后强制再推当前激活上游（允许同 nodeId）。
    func reapplyActiveUpstream() async {
        guard !isBusy else { return }
        guard config.isEnabled, runtime.isProcessRunning,
              let nodeId = config.activeNodeId else { return }
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        guard let node = node(for: nodeId),
              var payload = adapter.switchPayload(config: config, nodeId: nodeId),
              let catalog = modelCatalog(for: nodeId) else { return }
        payload["availableModels"] = catalog.models.map(\.upstreamModel)
        payload["defaultModel"] = catalog.defaultUpstreamModel
        do {
            try await runtime.switchUpstream(
                payload: payload,
                adminPath: adapter.adminPath(config: config),
                nodeId: node.id,
                nodeName: node.name
            )
            ScienceAuthProxy.shared.updateModelCatalog(catalog)
        } catch {
            operationError = error.localizedDescription
            scienceMgrLog.error("Failed to reapply Science upstream: \(String(describing: error), privacy: .public)")
        }
    }

    /// 停止：停沙箱 Science（只停沙箱 data-dir）+ 停代理进程。绝不影响真实实例 8765。
    func stop() async {
        guard !isBusy else { return }
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        let endpoints = endpointPlan
        await teardownScienceStack(endpoints)
        config.isEnabled = false
        persist()
        scienceMgrLog.info("Science proxy stopped (adoptReal=\(endpoints.adopting))")
    }

    // MARK: - Launch Restore

    func restoreOnLaunch() async {
        guard config.isEnabled else { return }
        let endpoints = endpointPlan
        guard AppSettings.shared.proxyAutoRestoreOnLaunch else {
            await teardownScienceStack(endpoints)
            config.isEnabled = false
            persist()
            return
        }
        guard scienceInstalled else {
            await teardownScienceStack(endpoints)
            config.isEnabled = false
            persist()
            operationError = ScienceSandboxError.scienceNotInstalled.errorDescription
            scienceMgrLog.notice("Science restore disabled because Claude Science is not installed")
            return
        }
        guard let nodeId = config.activeNodeId, node(for: nodeId) != nil else {
            await teardownScienceStack(endpoints)
            scienceMgrLog.notice("Science proxy active node missing on launch; disabling")
            config.isEnabled = false
            persist()
            return
        }
        await start(activeNodeId: nodeId, openBrowserOnReady: false)
    }

    // MARK: - Browser / Sandbox utilities

    /// 打开已登录的 Science。两种模式都访问公开反代；反代注入当前会话，
    /// 因此不再依赖一次性 nonce URL，也不会绕过即时模型目录。
    func openInBrowser() {
        if let url = URL(string: "http://localhost:\(listenPort)/") {
            NSWorkspace.shared.open(url)
        }
    }

    func openSandboxFolder() {
        let path = sandboxPaths.home
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// 重置当前沙箱工作区（仅停用态）：删除该工作区 HOME，下次启动重新克隆运行时并新铸虚拟登录。
    /// 护栏：路径必须落在 ~/.config/aiusage/science-sandbox/workspaces 之下（或旧版 home）。
    func resetSandbox() {
        guard !config.isEnabled else { return }
        let home = sandboxPaths.home
        let root = ScienceSandboxPaths.sandboxRoot
        let resolved = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        guard resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/") else {
            operationError = AppSettings.shared.t("Refused: sandbox path is outside the managed directory.", "拒绝：沙箱路径不在受管目录内。")
            return
        }
        do {
            if FileManager.default.fileExists(atPath: home) {
                try FileManager.default.removeItem(atPath: home)
            }
            sandboxHealthy = false
        } catch {
            operationError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func persist() {
        GlobalProxyStore.save(config, track: track)
    }
}
