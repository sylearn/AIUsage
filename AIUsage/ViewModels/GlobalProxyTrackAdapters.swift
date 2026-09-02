import Foundation
import QuotaBackend

// MARK: - Global Proxy Track Adapter
// 把「全局统一代理」的轨道差异收敛到一个协议：节点筛选、常驻进程启动 env、admin 热切换 payload、
// admin 端点路径、CLI 配置接管/还原、以及与「每节点激活」轨的互斥停用。GlobalProxyManager 只依赖本协议做调度。
//
// 节点类型无关：协议只暴露 GlobalProxyNodeRef（id + 展示名）与 nodeId，各轨适配器内部解析自己的
// 具体节点类型（Codex/Claude 用 ProxyConfiguration，OpenCode 用 OpenCodeNode），互不渗透。
//
// 三个进程 env 契约对齐 QuotaServer 各 Configuration.loadFromEnvironment：
//   - Codex   : PROXY_TARGET=codex + OPENAI_* + CODEX_CLIENT_KEY + CODEX_UPSTREAM_MODEL
//   - Claude  : PROXY_MODE=openai|passthrough + (OPENAI_*|ANTHROPIC_UPSTREAM_*) + ANTHROPIC_API_KEY + 三模型
//   - OpenCode: 按选定接口复用上面任一轨道（responses→codex / anthropic→claude passthrough / chat→opencode）
// admin key / node id 由 GlobalProxyRuntime 注入，适配器不负责。

/// 轨道无关的节点投影：UI 选择器与 manager 编排只需要 id + 展示名。
struct GlobalProxyNodeRef: Identifiable, Equatable {
    let id: String
    let name: String
}

@MainActor
protocol GlobalProxyTrackAdapter {
    var track: GlobalProxyTrack { get }
    var runtime: GlobalProxyRuntime { get }

    /// 可参与全局代理的节点（按轨/接口筛选）。
    func availableNodes(config: GlobalProxyConfig) -> [GlobalProxyNodeRef]

    /// 常驻进程启动 env（不含 GLOBAL_PROXY_ADMIN_KEY / GLOBAL_PROXY_NODE_ID，由 runtime 注入）。
    /// 节点不存在时返回 nil。
    func startEnv(config: GlobalProxyConfig, nodeId: String) -> [String: String]?
    /// admin 热切换 payload（POST 到 adminPath）。节点不存在时返回 nil。
    func switchPayload(config: GlobalProxyConfig, nodeId: String) -> [String: Any]?
    /// admin 端点路径（OpenCode 按接口复用不同轨道的 admin 路由）。
    func adminPath(config: GlobalProxyConfig) -> String

    /// 接管 CLI 配置：写入固定入口（端口 + client key + 虚拟模型），指向常驻代理。
    func activateCLIConfig(_ config: GlobalProxyConfig) throws
    /// 还原 CLI 配置：清除受管理项 / 从备份还原。
    func restoreCLIConfig() throws
    /// 显式丢弃外部修改后的恢复路径。默认与普通恢复相同，OpenCode 使用
    /// 自己的 durable takeover session 做 force restore。
    func restoreCLIConfigDiscardingExternalChanges() throws

    /// 本轨「每节点激活」当前激活 id（启用全局前先停掉它，干净交接）。
    func currentPerNodeActiveId() -> String?
    func deactivatePerNode(_ id: String) async
    /// Gateway 接管失败时恢复刚才停用的每节点路由。
    func activatePerNode(_ id: String) async
}

extension GlobalProxyTrackAdapter {
    func restoreCLIConfigDiscardingExternalChanges() throws {
        try restoreCLIConfig()
    }
}

// MARK: - Codex Adapter

@MainActor
struct CodexGlobalProxyAdapter: GlobalProxyTrackAdapter {
    let track: GlobalProxyTrack = .codex
    var runtime: GlobalProxyRuntime { .codex }

    private func node(_ id: String) -> ProxyConfiguration? {
        ProxyViewModel.shared.configurations.first { $0.id == id && $0.nodeType == .codexProxy }
    }

    func availableNodes(config: GlobalProxyConfig) -> [GlobalProxyNodeRef] {
        ProxyViewModel.shared.configurations
            .filter { $0.nodeType == .codexProxy }
            .map { GlobalProxyNodeRef(id: $0.id, name: $0.name) }
    }

    func startEnv(config: GlobalProxyConfig, nodeId: String) -> [String: String]? {
        guard let node = node(nodeId) else { return nil }
        var env: [String: String] = [
            "PROXY_TARGET": "codex",
            // Codex wire_api 恒为 responses：强制 Responses 忠实透传，避免有损转换。
            "OPENAI_API_MODE": "responses",
            "CODEX_CLIENT_KEY": config.effectiveClientKey,
            "OPENAI_API_KEY": node.upstreamAPIKey,
            "OPENAI_BASE_URL": node.normalizedUpstreamBaseURL,
        ]
        if !node.codexModel.isEmpty { env["CODEX_UPSTREAM_MODEL"] = node.codexModel }
        if node.maxOutputTokens > 0 { env["MAX_OUTPUT_TOKENS"] = "\(node.maxOutputTokens)" }
        return env
    }

    func switchPayload(config: GlobalProxyConfig, nodeId: String) -> [String: Any]? {
        guard let node = node(nodeId) else { return nil }
        return [
            "nodeId": node.id,
            "baseURL": node.normalizedUpstreamBaseURL,
            "apiKey": node.upstreamAPIKey,
            "model": node.codexModel,
            "maxOutputTokens": node.maxOutputTokens,
        ]
    }

    func adminPath(config: GlobalProxyConfig) -> String { "/__aiusage/admin/codex-upstream" }

    func activateCLIConfig(_ config: GlobalProxyConfig) throws {
        try CodexConfigManager.shared.activate(
            baseURL: config.codexBaseURL,
            bearerToken: config.effectiveClientKey,
            model: config.virtualModel
        )
    }

    func restoreCLIConfig() throws {
        try CodexConfigManager.shared.restore()
    }

    func currentPerNodeActiveId() -> String? {
        ProxyViewModel.shared.activatedId(isCodex: true)
    }

    func deactivatePerNode(_ id: String) async {
        await ProxyViewModel.shared.deactivateConfiguration(id)
    }

    func activatePerNode(_ id: String) async {
        await ProxyViewModel.shared.activateConfiguration(id)
    }
}

// MARK: - Claude Adapter

@MainActor
struct ClaudeGlobalProxyAdapter: GlobalProxyTrackAdapter {
    let track: GlobalProxyTrack
    var runtime: GlobalProxyRuntime { .instance(for: track) }

    init(track: GlobalProxyTrack = .claude) {
        precondition([.claude, .desktop, .science].contains(track))
        self.track = track
    }

    private func node(_ id: String) -> ProxyConfiguration? {
        ProxyViewModel.shared.configurations.first { $0.id == id && ProxyNodeFamily.claude.contains($0.nodeType) }
    }

    private func productCatalogProjection(
        config: GlobalProxyConfig,
        node: ProxyConfiguration,
        codeModels: ClaudeAppResolvedModels,
        desktopModels: ClaudeAppResolvedModels
    ) -> (projection: ClaudeProductGatewayCatalogProjection, routeStyle: String, mapsStableRoutes: Bool)? {
        switch track {
        case .claude:
            let mode = config.effectiveClaudeCodeCatalogMode
            return (
                ClaudeDesktopProfileStore.gatewayProjection(
                    for: node,
                    mode: mode,
                    supports1M: node.supports1MModels,
                    routes: codeModels,
                    productRouteIDs: mode == .smartRoutes
                        ? [
                            ClaudeDesktopProfileStore.codeDefaultRouteID,
                            ClaudeDesktopProfileStore.codeOpusRouteID,
                            ClaudeDesktopProfileStore.codeSonnetRouteID,
                            ClaudeDesktopProfileStore.codeHaikuRouteID,
                        ]
                        : nil
                ),
                "code",
                mode == .smartRoutes
            )
        case .desktop:
            let mode = config.effectiveClaudeDesktopCatalogMode
            return (
                ClaudeDesktopProfileStore.gatewayProjection(
                    for: node,
                    mode: mode,
                    supports1M: node.supports1MModels,
                    routes: desktopModels
                ),
                "desktop",
                mode == .smartRoutes
            )
        default:
            return nil
        }
    }

    func availableNodes(config: GlobalProxyConfig) -> [GlobalProxyNodeRef] {
        ProxyViewModel.shared.configurations
            .filter { ProxyNodeFamily.claude.contains($0.nodeType) }
            .map { GlobalProxyNodeRef(id: $0.id, name: $0.name) }
    }

    func startEnv(config: GlobalProxyConfig, nodeId: String) -> [String: String]? {
        guard let node = node(nodeId) else { return nil }
        let codeModels = config.effectiveClaudeCodeModels(for: node)
        let desktopModels = config.effectiveClaudeDesktopModels(for: node)
        let routeModels = track == .desktop ? desktopModels : codeModels
        let useProductRoutes = track == .claude
            || (track == .desktop && config.effectiveClaudeDesktopCatalogMode == .smartRoutes)
        let productCatalog = productCatalogProjection(
            config: config,
            node: node,
            codeModels: codeModels,
            desktopModels: desktopModels
        )
        // Product Gateway owns aliases/catalog presentation. It always sends
        // an Anthropic-compatible request with an exact model to the selected
        // Node Runtime, where protocol conversion and aggregate usage live.
        var env: [String: String] = [
            "PROXY_MODE": "passthrough",
            "ANTHROPIC_API_KEY": config.effectiveClientKey,
            "ANTHROPIC_UPSTREAM_URL": node.displayURL,
            "ANTHROPIC_UPSTREAM_KEY": node.effectiveClientKey,
            "ENABLE_MODEL_ALIAS_MAPPING": "1",
            "BIG_MODEL": useProductRoutes ? routeModels.opus : node.modelMapping.bigModel.name,
            "MIDDLE_MODEL": useProductRoutes ? routeModels.sonnet : node.modelMapping.middleModel.name,
            "SMALL_MODEL": useProductRoutes ? routeModels.haiku : node.modelMapping.smallModel.name,
            "AIUSAGE_CLAUDE_MODEL_CATALOG": "1",
            "AIUSAGE_CLAUDE_EXACT_MODELS": "1",
        ]
        if let data = try? JSONEncoder().encode(node.runtimeModelCatalog),
           let json = String(data: data, encoding: .utf8) {
            env["AIUSAGE_CLAUDE_MODELS_JSON"] = json
        }
        env["AIUSAGE_CLAUDE_DEFAULT_MODEL"] = useProductRoutes
            ? routeModels.defaultModel
            : node.defaultModel
        if let productCatalog {
            if let data = try? JSONEncoder().encode(productCatalog.projection.availableModels),
               let json = String(data: data, encoding: .utf8) {
                env["AIUSAGE_CLAUDE_MODELS_JSON"] = json
            }
            if let defaultModel = productCatalog.projection.defaultModel {
                env["AIUSAGE_CLAUDE_DEFAULT_MODEL"] = defaultModel
            }
            if let data = try? JSONEncoder().encode(productCatalog.projection.supports1MModels),
               let json = String(data: data, encoding: .utf8) {
                env["AIUSAGE_CLAUDE_SUPPORTS_1M_JSON"] = json
            }
            env["AIUSAGE_CLAUDE_ROUTE_STYLE"] = productCatalog.routeStyle
            env["AIUSAGE_CLAUDE_DESKTOP_TIER_ROUTES"] = productCatalog.mapsStableRoutes ? "1" : "0"
        }
        return env
    }

    func switchPayload(config: GlobalProxyConfig, nodeId: String) -> [String: Any]? {
        guard let node = node(nodeId) else { return nil }
        let codeModels = config.effectiveClaudeCodeModels(for: node)
        let desktopModels = config.effectiveClaudeDesktopModels(for: node)
        let routeModels = track == .desktop ? desktopModels : codeModels
        let useProductRoutes = track == .claude
            || (track == .desktop && config.effectiveClaudeDesktopCatalogMode == .smartRoutes)
        let productCatalog = productCatalogProjection(
            config: config,
            node: node,
            codeModels: codeModels,
            desktopModels: desktopModels
        )
        let availableModels = productCatalog?.projection.availableModels ?? node.runtimeModelCatalog
        let defaultModel = productCatalog?.projection.defaultModel
            ?? (track == .claude ? codeModels.defaultModel : node.defaultModel)
        var payload: [String: Any] = [
            "nodeId": node.id,
            "mode": "passthrough",
            "baseURL": node.displayURL,
            "apiKey": node.effectiveClientKey,
            "apiMode": OpenAIUpstreamAPI.chatCompletions.rawValue,
            "bigModel": useProductRoutes ? routeModels.opus : node.modelMapping.bigModel.name,
            "middleModel": useProductRoutes ? routeModels.sonnet : node.modelMapping.middleModel.name,
            "smallModel": useProductRoutes ? routeModels.haiku : node.modelMapping.smallModel.name,
            "maxOutputTokens": node.maxOutputTokens,
            "enableModelAliasMapping": true,
            "availableModels": availableModels,
            "defaultModel": defaultModel,
        ]
        if let productCatalog {
            payload["catalogRouteStyle"] = productCatalog.routeStyle
            payload["mapDesktopTierRoutes"] = productCatalog.mapsStableRoutes
            payload["catalogSupports1M"] = productCatalog.projection.supports1MModels
        }
        return payload
    }

    func adminPath(config: GlobalProxyConfig) -> String { "/__aiusage/admin/claude-upstream" }

    func activateCLIConfig(_ config: GlobalProxyConfig) throws {
        guard track == .claude else { return }
        let activeNode = node(config.activeNodeId ?? "")
        let routes = activeNode.map { config.effectiveClaudeCodeModels(for: $0) }
        let smartRoutes = config.effectiveClaudeCodeCatalogMode == .smartRoutes
        try ClaudeSettingsManager.shared.writeEnv(.init(
            baseURL: config.localBaseURL,
            authToken: config.effectiveClientKey,
            // Smart mode never leaks a node-owned model id into Claude Code's
            // session identity. The Gateway remaps these durable routes live.
            defaultModel: smartRoutes ? ClaudeDesktopProfileStore.codeDefaultRouteID : routes?.defaultModel,
            opusModel: smartRoutes ? ClaudeDesktopProfileStore.codeOpusRouteID : (routes?.opus ?? config.claudeOpus),
            sonnetModel: smartRoutes ? ClaudeDesktopProfileStore.codeSonnetRouteID : (routes?.sonnet ?? config.claudeSonnet),
            haikuModel: smartRoutes ? ClaudeDesktopProfileStore.codeHaikuRouteID : (routes?.haiku ?? config.claudeHaiku),
            modelPresentation: smartRoutes ? .aiUsageRoutes : nil,
            // Full catalog needs discovery for real node ids; smart mode needs
            // it so the stable Default route is restored as a known model.
            enableGatewayModelDiscovery: true,
            nodeExtraCACerts: nil
        ))
    }

    func restoreCLIConfig() throws {
        guard track == .claude else { return }
        try ClaudeSettingsManager.shared.clearEnv()
    }

    func currentPerNodeActiveId() -> String? {
        track == .claude ? ProxyViewModel.shared.activatedId(isCodex: false) : nil
    }

    func deactivatePerNode(_ id: String) async {
        guard track == .claude else { return }
        await ProxyViewModel.shared.deactivateConfiguration(id)
    }

    func activatePerNode(_ id: String) async {
        guard track == .claude else { return }
        await ProxyViewModel.shared.activateConfiguration(id)
    }
}

// MARK: - OpenCode Adapter (3 interfaces)

@MainActor
struct OpenCodeGlobalProxyAdapter: GlobalProxyTrackAdapter {
    let track: GlobalProxyTrack = .opencode
    var runtime: GlobalProxyRuntime { .opencode }

    private func node(_ id: String) -> OpenCodeNode? {
        OpenCodeNodeStore.shared.nodes.first { $0.id == id }
    }

    /// 只列出与选定接口协议一致、且填齐激活字段的节点（保证 wire 格式兼容，切换只换上游）。
    func availableNodes(config: GlobalProxyConfig) -> [GlobalProxyNodeRef] {
        let interface = config.effectiveOpenCodeInterface
        return OpenCodeNodeStore.shared.nodes
            .filter { $0.protocolType == interface && $0.isComplete }
            .map { GlobalProxyNodeRef(id: $0.id, name: $0.displayName) }
    }

    func startEnv(config: GlobalProxyConfig, nodeId: String) -> [String: String]? {
        guard let node = node(nodeId) else { return nil }
        let model = node.effectiveDefaultModel ?? ""
        switch config.effectiveOpenCodeInterface {
        case .openAIResponses:
            // responses 接口复用 Codex 透传轨：上游模型由 CODEX_UPSTREAM_MODEL 覆盖。
            var env: [String: String] = [
                "PROXY_TARGET": "codex",
                "OPENAI_API_MODE": "responses",
                "CODEX_CLIENT_KEY": config.effectiveClientKey,
                "OPENAI_API_KEY": node.apiKey,
                "OPENAI_BASE_URL": node.baseURL,
            ]
            if !model.isEmpty { env["CODEX_UPSTREAM_MODEL"] = model }
            if node.maxOutputTokens > 0 { env["MAX_OUTPUT_TOKENS"] = "\(node.maxOutputTokens)" }
            return env
        case .anthropic:
            // anthropic 接口复用 Claude passthrough 轨：固定虚拟模型经 ANTHROPIC_FORCED_MODEL 改写为节点模型。
            var env: [String: String] = [
                "PROXY_MODE": "passthrough",
                "ANTHROPIC_API_KEY": config.effectiveClientKey,
                "ANTHROPIC_UPSTREAM_URL": node.baseURLWithoutV1Suffix,
                "ANTHROPIC_UPSTREAM_KEY": node.apiKey,
            ]
            if !model.isEmpty { env["ANTHROPIC_FORCED_MODEL"] = model }
            return env
        case .openAICompatible:
            // chat/completions 接口走 OpenCode 透传轨：OPENCODE_FORCED_MODEL 改写为节点模型。
            var env: [String: String] = [
                "PROXY_TARGET": "opencode",
                "OPENCODE_CLIENT_KEY": config.effectiveClientKey,
                "OPENAI_API_KEY": node.apiKey,
                "OPENAI_BASE_URL": node.baseURL,
            ]
            if !model.isEmpty { env["OPENCODE_FORCED_MODEL"] = model }
            return env
        }
    }

    func switchPayload(config: GlobalProxyConfig, nodeId: String) -> [String: Any]? {
        guard let node = node(nodeId) else { return nil }
        let model = node.effectiveDefaultModel ?? ""
        switch config.effectiveOpenCodeInterface {
        case .openAIResponses:
            return [
                "nodeId": node.id,
                "baseURL": node.baseURL,
                "apiKey": node.apiKey,
                "model": model,
                "maxOutputTokens": node.maxOutputTokens,
            ]
        case .anthropic:
            return [
                "nodeId": node.id,
                "mode": "passthrough",
                "baseURL": node.baseURLWithoutV1Suffix,
                "apiKey": node.apiKey,
                "apiMode": "chat_completions",
                "bigModel": model,
                "middleModel": model,
                "smallModel": model,
                "maxOutputTokens": node.maxOutputTokens,
                "enableModelAliasMapping": false,
                "forcedModel": model,
            ]
        case .openAICompatible:
            return [
                "nodeId": node.id,
                "baseURL": node.baseURL,
                "apiKey": node.apiKey,
                "model": model,
            ]
        }
    }

    func adminPath(config: GlobalProxyConfig) -> String {
        switch config.effectiveOpenCodeInterface {
        case .openAIResponses: return "/__aiusage/admin/codex-upstream"
        case .anthropic: return "/__aiusage/admin/claude-upstream"
        case .openAICompatible: return "/__aiusage/admin/opencode-upstream"
        }
    }

    func activateCLIConfig(_ config: GlobalProxyConfig) throws {
        try OpenCodeConfigManager.shared.activateGlobal(
            interface: config.effectiveOpenCodeInterface,
            baseURL: config.codexBaseURL,
            clientKey: config.effectiveClientKey,
            virtualModel: config.virtualModel
        )
    }

    func restoreCLIConfig() throws {
        try OpenCodeConfigManager.shared.restore()
    }

    func restoreCLIConfigDiscardingExternalChanges() throws {
        try OpenCodeConfigManager.shared.restoreDiscardingExternalChanges()
    }

    func currentPerNodeActiveId() -> String? {
        OpenCodeNodeStore.shared.activeNodeId
    }

    func deactivatePerNode(_ id: String) async {
        try? OpenCodeNodeStore.shared.deactivate()
    }

    func activatePerNode(_ id: String) async {
        guard let node = node(id) else { return }
        try? await OpenCodeNodeStore.shared.activate(node)
    }
}
