import Foundation
import SwiftUI
import QuotaBackend

// MARK: - API Provider Distributor
// 把「API 提供商」主配置分发到 Codex / Claude / OpenCode 本地代理，以及 CPA 的 OpenAI 兼容上游：
//   - 分发即生成各代理的「链接节点」（携带 linkedProviderId），按目标去重 upsert。
//   - CPA：写入 openai-compatibility，并用 APIProviderCPALinkStore 维护 providerId→name 映射。
//   - 主配置变更时，链接节点里未被 overriddenKeys 标记的共享字段跟随同步；代理专属字段本地独立。
//   - 取消分发某代理 = 删除该代理下的链接节点；解除链接 = 链接节点转为普通独立节点。
// Codex/Claude 节点经 ProxyViewModel（落 ~/.config/aiusage/profiles），OpenCode 经 OpenCodeNodeStore。

@MainActor
final class APIProviderDistributor {
    static let shared = APIProviderDistributor()

    private var proxyVM: ProxyViewModel { ProxyViewModel.shared }
    private var profileStore: NodeProfileStore { NodeProfileStore.shared }
    private var openCodeStore: OpenCodeNodeStore { OpenCodeNodeStore.shared }
    private var cpaLinks: APIProviderCPALinkStore { APIProviderCPALinkStore.shared }
    private var gateway: CLIProxyGatewayManager { CLIProxyGatewayManager.shared }

    // MARK: - Distribution State

    /// 该主配置当前已在哪些目标生成了链接。
    func currentTargets(for providerId: String) -> Set<ProxyTarget> {
        var result: Set<ProxyTarget> = []
        if codexChild(for: providerId) != nil { result.insert(.codex) }
        if claudeChild(for: providerId) != nil { result.insert(.claude) }
        if openCodeChild(for: providerId) != nil { result.insert(.openCode) }
        if cpaLinks.hasLink(for: providerId) { result.insert(.cpa) }
        return result
    }

    /// Used by the CPA credential repair path to detect a partially completed
    /// rotation. Missing targets are ignored; every linked local child must use
    /// the current runtime-owned client key.
    func linkedChildrenUseAPIKey(providerId: String, apiKey: String) -> Bool {
        if let child = codexChild(for: providerId),
           child.metadata.proxy.upstreamAPIKey != apiKey { return false }
        if let child = claudeChild(for: providerId) {
            let childKey = child.metadata.nodeType == .anthropicDirect
                ? child.metadata.proxy.anthropicAPIKey
                : child.metadata.proxy.upstreamAPIKey
            if childKey != apiKey { return false }
        }
        if let child = openCodeChild(for: providerId), child.apiKey != apiKey { return false }
        return true
    }

    // MARK: - Reconcile (distribute / undistribute)

    /// 把主配置的分发集合对齐到 `targets`：被选中且兼容的目标 upsert 链接节点（已存在则同步），
    /// 未选中（或不兼容）的目标若有链接节点则删除。
    /// 主配置内容变更后，把变更同步到所有已存在的链接；返回失败原因（成功为 nil）。
    @discardableResult
    func syncFromMaster(_ provider: APIProvider) async -> String? {
        gateway.lastError = nil
        for target in currentTargets(for: provider.id) {
            if target == .cpa, let reason = APIProviderCPALoopGuard.blockReason(for: provider) {
                gateway.lastError = reason
                await removeChild(for: provider.id, target: .cpa)
                continue
            }
            await upsertChild(provider, target: target)
        }
        return gateway.lastError
    }

    /// 对齐分发集合；返回失败原因（成功为 nil）。
    @discardableResult
    func setDistribution(_ provider: APIProvider, targets: Set<ProxyTarget>) async -> String? {
        gateway.lastError = nil
        for target in ProxyTarget.allCases {
            var want = targets.contains(target) && target.supports(provider.format)
            if want, target == .cpa, let reason = APIProviderCPALoopGuard.blockReason(for: provider) {
                gateway.lastError = reason
                want = false
            }
            if want {
                await upsertChild(provider, target: target)
            } else {
                await removeChild(for: provider.id, target: target)
            }
        }
        return gateway.lastError
    }

    /// 删除主配置：要么级联删除所有链接节点，要么解除链接（保留为独立节点）。
    func handleProviderDeletion(_ provider: APIProvider, deleteChildren: Bool) async {
        for target in ProxyTarget.allCases {
            if deleteChildren {
                await removeChild(for: provider.id, target: target)
            } else {
                unlinkChild(for: provider.id, target: target)
            }
        }
    }

    // MARK: - Per-target upsert

    private func upsertChild(_ provider: APIProvider, target: ProxyTarget) async {
        switch target {
        case .codex:
            let existing = codexChild(for: provider.id)
            let profile = makeProfile(provider, family: .codex, existing: existing)
            if existing != nil { await proxyVM.updateProfile(profile) } else { proxyVM.addProfile(profile) }
        case .claude:
            let existing = claudeChild(for: provider.id)
            let profile = makeProfile(provider, family: .claude, existing: existing)
            if existing != nil { await proxyVM.updateProfile(profile) } else { proxyVM.addProfile(profile) }
            // CPA→Claude 从 convert 切到 Anthropic 透传后，正在跑的 Science/Claude 全局代理
            // 需热推上游，否则仍停在旧 convert 进程配置上。
            if provider.id == CLIProxyGatewayManager.managedProviderID {
                await reapplyRunningClaudeTracks(for: profile.metadata.id)
            }
        case .openCode:
            let existing = openCodeChild(for: provider.id)
            let node = makeOpenCodeNode(provider, existing: existing)
            openCodeStore.upsert(node)
            if provider.id == CLIProxyGatewayManager.managedProviderID {
                await reapplyRunningOpenCodeTrack(for: node.id)
            }
        case .cpa:
            if let reason = APIProviderCPALoopGuard.blockReason(for: provider) {
                gateway.lastError = reason
                return
            }
            await upsertCPAChild(provider)
        }
    }

    private func upsertCPAChild(_ provider: APIProvider) async {
        let existingName = cpaLinks.cpaName(for: provider.id)
        do {
            let name = try await gateway.upsertOpenAICompatibleProvider(
                fromAPIProvider: provider,
                existingCPAName: existingName
            )
            cpaLinks.setLink(providerId: provider.id, cpaName: name)
        } catch {
            gateway.lastError = error.localizedDescription
        }
    }

    /// Science / Claude 全局代理若正用该节点，强制再推一次上游（允许同 nodeId 重入）。
    private func reapplyRunningClaudeTracks(for nodeId: String) async {
        let science = ScienceProxyManager.shared
        if science.isEnabled, science.isProxyRunning, science.activeNodeId == nodeId {
            await science.reapplyActiveUpstream()
        }
        let claude = GlobalProxyManager.claude
        if claude.isRuntimeEnabled, claude.isProxyRunning, claude.activeNodeId == nodeId {
            await claude.reapplyActiveUpstream()
        }
    }

    private func reapplyRunningOpenCodeTrack(for nodeId: String) async {
        let opencode = GlobalProxyManager.opencode
        if opencode.isEnabled, opencode.isProxyRunning, opencode.activeNodeId == nodeId {
            await opencode.reapplyActiveUpstream()
        }
    }

    private func removeChild(for providerId: String, target: ProxyTarget) async {
        switch target {
        case .codex:
            if let child = codexChild(for: providerId) { await proxyVM.deleteConfiguration(child.id) }
        case .claude:
            if let child = claudeChild(for: providerId) { await proxyVM.deleteConfiguration(child.id) }
        case .openCode:
            if let child = openCodeChild(for: providerId) {
                do {
                    try openCodeStore.delete(child)
                } catch {
                    gateway.lastError = error.localizedDescription
                }
            }
        case .cpa:
            if let name = cpaLinks.cpaName(for: providerId) {
                do {
                    try await gateway.deleteOpenAICompatibleProviderLinked(cpaName: name)
                } catch {
                    gateway.lastError = error.localizedDescription
                }
                cpaLinks.removeLink(providerId: providerId)
            }
        }
    }

    private func unlinkChild(for providerId: String, target: ProxyTarget) {
        switch target {
        case .codex:
            guard var child = codexChild(for: providerId) else { return }
            child.metadata.linkedProviderId = nil
            child.metadata.overriddenKeys = nil
            profileStore.save(child)
            proxyVM.loadConfigurations()
        case .claude:
            guard var child = claudeChild(for: providerId) else { return }
            child.metadata.linkedProviderId = nil
            child.metadata.overriddenKeys = nil
            profileStore.save(child)
            proxyVM.loadConfigurations()
        case .openCode:
            guard var child = openCodeChild(for: providerId) else { return }
            child.linkedProviderId = nil
            child.overriddenKeys = nil
            openCodeStore.upsert(child)
        case .cpa:
            // 解除链接：保留 CPA 上游条目，仅丢掉本地映射。
            cpaLinks.removeLink(providerId: providerId)
        }
    }

    // MARK: - Child lookup

    private func codexChild(for providerId: String) -> NodeProfile? {
        profileStore.profiles.first { $0.metadata.linkedProviderId == providerId && $0.metadata.nodeType.isCodex }
    }

    private func claudeChild(for providerId: String) -> NodeProfile? {
        profileStore.profiles.first { $0.metadata.linkedProviderId == providerId && !$0.metadata.nodeType.isCodex }
    }

    private func openCodeChild(for providerId: String) -> OpenCodeNode? {
        openCodeStore.nodes.first { $0.linkedProviderId == providerId }
    }

    // MARK: - Mapping: APIProvider → Codex/Claude NodeProfile

    private func makeProfile(_ provider: APIProvider, family: ProxyNodeFamily, existing: NodeProfile?) -> NodeProfile {
        let isCPAManagedProvider = provider.id == CLIProxyGatewayManager.managedProviderID
        var overridden = existing?.metadata.overriddenKeys ?? []
        if isCPAManagedProvider { overridden.remove(APIProviderSharedKey.apiKey) }
        func wins(_ key: String) -> Bool { !overridden.contains(key) }

        // CPA 一键网关主配置固定为 OpenAI Responses（Codex 必需）；Claude Code（含 Science）
        // 在接入页可选 Anthropic / Chat Completions / Responses，与节点编辑器三卡片一致。
        let isCPAManagedClaude = family == .claude
            && provider.id == CLIProxyGatewayManager.managedProviderID

        // 节点类型由格式推导（Codex 恒 codexProxy；Claude：Anthropic→透传直连，OpenAI→转换代理）。
        let managedClaude = CLIProxyGatewayManager.shared.managedClaudeProtocol
        let nodeType: NodeType
        if family.isCodex {
            nodeType = .codexProxy
        } else if isCPAManagedClaude {
            switch managedClaude {
            case .anthropicPassthrough: nodeType = .anthropicDirect
            case .openAIChatCompletions, .openAIResponses: nodeType = .openaiProxy
            }
        } else {
            nodeType = (provider.format == .anthropic) ? .anthropicDirect : .openaiProxy
        }

        var proxy = existing?.metadata.proxy ?? defaultProxy(for: nodeType)

        // 共享字段：API Key / baseURL（按节点类型落到不同字段）。
        // CPA's client key is runtime-owned and may rotate. A linked node must
        // never pin an old local key through an inherited override marker.
        if isCPAManagedProvider || wins(APIProviderSharedKey.apiKey) {
            switch nodeType {
            case .anthropicDirect: proxy.anthropicAPIKey = provider.apiKey
            case .openaiProxy, .codexProxy: proxy.upstreamAPIKey = provider.apiKey
            }
        }
        if wins(APIProviderSharedKey.baseURL) {
            switch nodeType {
            case .anthropicDirect:
                // CPA Anthropic 入口是 Origin（无 /v1）；Responses 主配置带 /v1，Claude 侧需剥离。
                proxy.anthropicBaseURL = isCPAManagedClaude
                    ? Self.stripTrailingV1Path(provider.baseURL)
                    : provider.baseURL
            case .openaiProxy, .codexProxy: proxy.upstreamBaseURL = provider.baseURL
            }
        }

        // 上游接口模式 / 透传开关由格式决定（跟随主配置）。
        switch nodeType {
        case .codexProxy:
            proxy.openAIUpstreamAPI = .responses
        case .openaiProxy:
            if isCPAManagedClaude, let api = managedClaude.openAIUpstreamAPI {
                proxy.openAIUpstreamAPI = api
            } else {
                proxy.openAIUpstreamAPI = provider.format.openAIUpstreamAPI ?? .chatCompletions
            }
            proxy.usePassthroughProxy = false
        case .anthropicDirect:
            proxy.usePassthroughProxy = true
        }

        // 模型目录（共享）。费用规则属于节点本地估算配置，不由提供商同步；
        // Claude 的大/中/小槽位也是本地映射（仅新节点播种、之后保留）；
        // Codex 单模型即 bigModel（codexModel 取自 bigModel.name），属共享字段，始终跟随主配置。
        if wins(APIProviderSharedKey.models) {
            let providerCatalog = ProxyConfiguration.ModelCatalog(mappedModels: provider.models)
            let providerNames = Set(providerCatalog.models)
            let retainedLocalPricing = proxy.modelCatalog.pricingOverrides.filter {
                providerNames.contains($0.key)
            }
            // 1M 声明与定价同口径保留：供应商已不再提供的模型，其能力标记也就没有意义了。
            let retainedLocal1M = proxy.modelCatalog.supports1MModels.filter(providerNames.contains)
            proxy.modelCatalog = .init(
                models: providerCatalog.models,
                pricingOverrides: retainedLocalPricing,
                supports1MModels: retainedLocal1M
            )
        }
        if wins(APIProviderSharedKey.defaultModel) {
            let dm = provider.effectiveDefaultModel
            proxy.defaultModel = dm
            if family.isCodex {
                // Codex 运行时改写用的是 codexModel(=bigModel.name)，proxy.defaultModel 对其无效，
                // 故 bigModel 必须始终随主配置同步——否则「立即同步」改不到 Codex 真实上游模型。
                proxy.modelMapping.bigModel.name = dm
                if existing == nil {
                    proxy.modelMapping.middleModel.name = ""
                    proxy.modelMapping.smallModel.name = ""
                }
            } else if existing == nil {
                // 通用上游：新节点三槽位先全部指向默认模型（用户可在节点编辑器按需细分，属本地配置）。
                proxy.modelMapping.bigModel.name = dm
                proxy.modelMapping.middleModel.name = dm
                proxy.modelMapping.smallModel.name = dm
            }
        }
        // 新节点端口避让，避免与现有代理端口直接撞车。
        if existing == nil {
            proxy.port = freePort(preferred: proxy.port)
        }

        var meta = existing?.metadata ?? NodeProfile.Metadata(nodeType: nodeType, proxy: proxy)
        meta.nodeType = nodeType
        meta.proxy = proxy
        meta.linkedProviderId = provider.id
        meta.overriddenKeys = overridden.isEmpty ? nil : overridden
        if wins(APIProviderSharedKey.name) {
            meta.name = provider.displayName
        }

        var profile = NodeProfile(metadata: meta, settings: existing?.settings ?? [:])
        profile.syncEnvFromProxy()
        return profile
    }

    /// 去掉末尾 `/v1`，得到 Anthropic 客户端期望的 Origin / REST API Root。
    static func stripTrailingV1Path(_ urlString: String) -> String {
        var value = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.lowercased().hasSuffix("/v1") {
            value = String(value.dropLast(3))
            while value.hasSuffix("/") { value.removeLast() }
        }
        return value
    }

    private func defaultProxy(for nodeType: NodeType) -> ProxySettings {
        switch nodeType {
        case .codexProxy: return .defaultCodex
        case .anthropicDirect: return .defaultAnthropic
        case .openaiProxy: return .defaultOpenAI
        }
    }

    // MARK: - Mapping: APIProvider → OpenCodeNode

    private func makeOpenCodeNode(_ provider: APIProvider, existing: OpenCodeNode?) -> OpenCodeNode {
        let isCPAManaged = provider.id == CLIProxyGatewayManager.managedProviderID
        var overridden = existing?.overriddenKeys ?? []
        if isCPAManaged { overridden.remove(APIProviderSharedKey.apiKey) }
        func wins(_ key: String) -> Bool { !overridden.contains(key) }

        let protocolType: OpenCodeProtocol = isCPAManaged
            ? CLIProxyGatewayManager.shared.managedOpenCodeProtocol
            : provider.format.openCodeProtocol

        var node = existing ?? OpenCodeNode()
        node.linkedProviderId = provider.id
        node.overriddenKeys = overridden.isEmpty ? nil : overridden
        // CPA 托管 OpenCode：协议由接入页选择；其它主配置仍跟随 format。
        node.protocolType = protocolType

        if wins(APIProviderSharedKey.name) { node.name = provider.displayName }
        if wins(APIProviderSharedKey.baseURL) {
            // Anthropic 入口是 Origin（无 /v1）；Chat/Responses 使用带 /v1 的 Base URL。
            node.baseURL = (isCPAManaged && protocolType == .anthropic)
                ? Self.stripTrailingV1Path(provider.baseURL)
                : provider.baseURL
        }
        if isCPAManaged || wins(APIProviderSharedKey.apiKey) { node.apiKey = provider.apiKey }
        if wins(APIProviderSharedKey.models) {
            let entries = Self.openCodeEntries(from: provider.models)
            node.modelEntries = entries
            node.pricingCurrency = entries.contains { $0.hasPricing } ? .usd : .none
        }
        if wins(APIProviderSharedKey.defaultModel) {
            node.defaultModel = provider.effectiveDefaultModel
        }

        // 共享生成参数 / 上限（仅 OpenCode 消费，跟随主配置）。
        node.contextLimit = provider.contextLimit
        node.outputLimit = provider.outputLimit
        node.temperature = provider.temperature
        node.topP = provider.topP
        node.maxOutputTokens = provider.maxOutputTokens
        node.frequencyPenalty = provider.frequencyPenalty
        node.presencePenalty = provider.presencePenalty

        return node
    }

    /// MappedModel（可能混合币种）→ OpenCodeModelEntry，统一折算为 USD（OpenCode cost 口径）。
    static func openCodeEntries(from models: [ProxyConfiguration.MappedModel]) -> [OpenCodeModelEntry] {
        models.map { m in
            OpenCodeModelEntry(
                id: m.name,
                priceInputPerMillion: m.pricing.inputPerMillionUSD,
                priceOutputPerMillion: m.pricing.outputPerMillionUSD,
                priceCacheReadPerMillion: m.pricing.cacheReadPerMillionUSD,
                priceCacheWritePerMillion: m.pricing.cacheCreatePerMillionUSD,
                pricingSource: m.pricing.source
            )
        }
    }

    // MARK: - Override stamping (called by child editors on save)
    // 子编辑器保存时调用：把链接节点的共享字段与主配置当前值逐项比对，不同即标记为本地覆盖
    // （写入 overriddenKeys），此后主配置同步不再覆盖这些字段。未链接节点清空标记。

    func stampOverrides(_ profile: NodeProfile) -> NodeProfile {
        var p = profile
        guard let masterId = p.metadata.linkedProviderId,
              let master = APIProviderStore.shared.provider(id: masterId) else {
            p.metadata.overriddenKeys = nil
            return p
        }
        var overridden = Set<String>()
        let proxy = p.metadata.proxy
        if p.metadata.name != master.displayName { overridden.insert(APIProviderSharedKey.name) }
        let childBaseURL: String
        let childKey: String
        switch p.metadata.nodeType {
        case .anthropicDirect: childBaseURL = proxy.anthropicBaseURL; childKey = proxy.anthropicAPIKey
        case .openaiProxy, .codexProxy: childBaseURL = proxy.upstreamBaseURL; childKey = proxy.upstreamAPIKey
        }
        if trimmed(childBaseURL) != trimmed(master.baseURL) { overridden.insert(APIProviderSharedKey.baseURL) }
        if masterId != CLIProxyGatewayManager.managedProviderID,
           childKey != master.apiKey { overridden.insert(APIProviderSharedKey.apiKey) }
        if proxy.modelCatalog.models != ProxyConfiguration.ModelCatalog(mappedModels: master.models).models {
            overridden.insert(APIProviderSharedKey.models)
        }
        if proxy.defaultModel != master.effectiveDefaultModel { overridden.insert(APIProviderSharedKey.defaultModel) }
        p.metadata.overriddenKeys = overridden.isEmpty ? nil : overridden
        return p
    }

    func stampOverrides(_ node: OpenCodeNode) -> OpenCodeNode {
        var n = node
        guard let masterId = n.linkedProviderId,
              let master = APIProviderStore.shared.provider(id: masterId) else {
            n.overriddenKeys = nil
            return n
        }
        var overridden = Set<String>()
        if n.name != master.displayName { overridden.insert(APIProviderSharedKey.name) }
        if trimmed(n.baseURL) != trimmed(master.baseURL) { overridden.insert(APIProviderSharedKey.baseURL) }
        if masterId != CLIProxyGatewayManager.managedProviderID,
           n.apiKey != master.apiKey { overridden.insert(APIProviderSharedKey.apiKey) }
        let masterFingerprints = Self.openCodeEntries(from: master.models).map(Self.fingerprint)
        if n.modelEntries.map(Self.fingerprint) != masterFingerprints { overridden.insert(APIProviderSharedKey.models) }
        if n.defaultModel != master.effectiveDefaultModel { overridden.insert(APIProviderSharedKey.defaultModel) }
        n.overriddenKeys = overridden.isEmpty ? nil : overridden
        return n
    }

    /// 模型条目价格指纹（忽略 modalities 等本地装饰，只比对 id + 四项单价）。
    private static func fingerprint(_ e: OpenCodeModelEntry) -> String {
        "\(e.id)|\(e.priceInputPerMillion)|\(e.priceOutputPerMillion)|\(e.priceCacheReadPerMillion)|\(e.priceCacheWritePerMillion)"
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 「重置为继承」：清掉该代理下链接节点的本地覆盖标记，并用主配置当前值整体重写。
    func resetToInherit(providerId: String, target: ProxyTarget) async {
        switch target {
        case .codex:
            guard var child = codexChild(for: providerId) else { return }
            child.metadata.overriddenKeys = nil
            profileStore.save(child)
        case .claude:
            guard var child = claudeChild(for: providerId) else { return }
            child.metadata.overriddenKeys = nil
            profileStore.save(child)
        case .openCode:
            guard var child = openCodeChild(for: providerId) else { return }
            child.overriddenKeys = nil
            openCodeStore.upsert(child)
        case .cpa:
            break
        }
        guard let master = APIProviderStore.shared.provider(id: providerId) else { return }
        await upsertChild(master, target: target)
    }

    // MARK: - Port deconfliction

    /// 为新链接节点挑一个不与现有代理端口（Claude/Codex profiles + OpenCode 节点）直接冲突的端口。
    private func freePort(preferred: Int) -> Int {
        var used = Set<Int>()
        for profile in profileStore.profiles {
            used.insert(profile.metadata.proxy.port)
            if profile.metadata.proxy.enableHTTPS == true {
                used.insert(profile.metadata.proxy.effectiveHTTPSPort)
            }
        }
        for node in openCodeStore.nodes where node.proxyEnabled {
            used.insert(node.proxyPort)
        }
        var port = max(1, min(preferred, 65_534))
        while used.contains(port) && port < 65_534 { port += 1 }
        return port
    }
}
