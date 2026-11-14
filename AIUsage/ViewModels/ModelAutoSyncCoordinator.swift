import Combine
import Foundation
import SwiftUI
import os.log

// MARK: - Model Auto Sync
// 后台自动同步「上游模型 + models.dev 公开价格」，覆盖 API 提供商、Claude / Codex 节点与 OpenCode 节点。
//
// 规则（与编辑器里的一键获取一致，见 PublicPriceUpdate）：
// - 新模型：每个节点按上游地址记录「已见过的上游模型」基线。首次同步只记基线、不改用户挑过的列表
//   （Claude / Codex 目录本来就是全量合并，首次仍全量）；之后上游新出现的模型自动加入。
//   用户删掉的模型已在基线里，不会被加回来。上游下架的模型不自动删除。
// - 价格：只填空白价格、刷新来源为 models.dev 的价格；手动价格与明确免费永不覆盖。
//   链接到 API 提供商的节点优先用提供商自己的默认价，没有才用公开价。
// - 写入：Claude / Codex 只改目录不重启运行时；OpenCode 走正常 upsert 以重写 opencode.json。
// - 由提供商托管模型的链接节点不单独拉模型，由提供商同步后传播下去。
//
// 状态持久化: ~/.config/aiusage/model-sync-state.json（只存基线模型名与时间，不存密钥）。

private let modelSyncLog = Logger(subsystem: "com.aiusage.desktop", category: "ModelAutoSync")

@MainActor
final class ModelAutoSyncCoordinator: ObservableObject {
    static let shared = ModelAutoSyncCoordinator()

    enum Target: Hashable {
        case provider(String)
        case profile(String)
        case openCode(String)

        var stateKey: String {
            switch self {
            case .provider(let id): return "provider:\(id)"
            case .profile(let id): return "profile:\(id)"
            case .openCode(let id): return "opencode:\(id)"
            }
        }
    }

    struct Report {
        var addedModels: [String] = []
        var filledPrices = 0
        var refreshedPrices = 0
        /// 首次同步记录为基线的上游模型数（这些模型不会被自动加入）。
        var baselineRecorded = 0
        var fetchError: String?
        var pricingUnavailable = false
        /// 模型由所链接的 API 提供商托管（只同步了价格）。
        var managedByProvider = false

        var changed: Bool { !addedModels.isEmpty || filledPrices > 0 || refreshedPrices > 0 }

        mutating func absorb(_ other: Report) {
            addedModels += other.addedModels
            filledPrices += other.filledPrices
            refreshedPrices += other.refreshedPrices
            baselineRecorded += other.baselineRecorded
        }
    }

    @Published private(set) var isSyncingAll = false
    @Published private(set) var syncingTargets: Set<Target> = []
    @Published private(set) var lastRunAt: Date?
    @Published var flash: AppFlash?

    /// 两次全量后台同步的最小间隔。
    static let interval: TimeInterval = 6 * 60 * 60
    /// 启动后等待一会儿再检查，避开启动期的额度刷新与代理恢复。
    private static let launchDelay: UInt64 = 45 * 1_000_000_000
    /// 到期检查的节拍；用「上次运行时间」判断是否到期，休眠唤醒后也能及时补跑。
    private static let tick: UInt64 = 15 * 60 * 1_000_000_000

    private var loopTask: Task<Void, Never>?
    private var state: StateFile
    /// 单次运行内的上游列表缓存：同一上游（如提供商与独立节点指向同一地址）只请求一次。
    private var upstreamCache: [FetchSpec: Result<[String], Error>] = [:]

    private init() {
        state = Self.loadState()
        lastRunAt = state.lastRunAt
    }

    // MARK: - Scheduling

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.launchDelay)
            while !Task.isCancelled {
                guard let self else { return }
                if AppSettings.shared.modelAutoSyncEnabled, self.isDue {
                    await self.syncAll(interactive: false)
                }
                try? await Task.sleep(nanoseconds: Self.tick)
            }
        }
    }

    private var isDue: Bool {
        guard let lastRunAt else { return true }
        return Date().timeIntervalSince(lastRunAt) >= Self.interval
    }

    // MARK: - Entry Points

    /// 同步全部节点。interactive = 用户手动触发（结束后给出横幅）。
    func syncAll(interactive: Bool) async {
        guard !isSyncingAll else { return }
        isSyncingAll = true
        defer {
            isSyncingAll = false
            upstreamCache = [:]
        }

        let priceCatalog = try? await ModelsDevPricingService.catalog()
        let providers = APIProviderStore.shared.providers.map(\.id)
        let profiles = NodeProfileStore.shared.profiles.map(\.id)
        let openCodeNodes = OpenCodeNodeStore.shared.nodes.map(\.id)

        // 先并发预取所有需要的上游列表，再按顺序落盘（落盘涉及主线程状态，串行更安全）。
        let specs = providers.compactMap { fetchSpec(for: .provider($0)) }
            + profiles.compactMap { fetchSpec(for: .profile($0)) }
            + openCodeNodes.compactMap { fetchSpec(for: .openCode($0)) }
        await prefetch(Set(specs))

        var total = Report()
        var failures = 0
        // 顺序很重要：提供商先同步并传播到链接节点，节点再按自身目录补价格。
        for id in providers {
            let report = await syncProvider(id, priceCatalog: priceCatalog)
            total.absorb(report)
            if report.fetchError != nil { failures += 1 }
        }
        for id in profiles {
            let report = await syncProfile(id, priceCatalog: priceCatalog, interactive: false)
            total.absorb(report)
            if report.fetchError != nil { failures += 1 }
        }
        for id in openCodeNodes {
            let report = await syncOpenCode(id, priceCatalog: priceCatalog)
            total.absorb(report)
            if report.fetchError != nil { failures += 1 }
        }

        pruneState(validKeys: Set(
            providers.map { Target.provider($0).stateKey }
                + profiles.map { Target.profile($0).stateKey }
                + openCodeNodes.map { Target.openCode($0).stateKey }
        ))
        state.lastRunAt = Date()
        lastRunAt = state.lastRunAt
        saveState()

        modelSyncLog.info("Model sync finished: added=\(total.addedModels.count, privacy: .public) filled=\(total.filledPrices, privacy: .public) refreshed=\(total.refreshedPrices, privacy: .public) failures=\(failures, privacy: .public)")

        if interactive {
            var report = total
            report.pricingUnavailable = priceCatalog == nil
            show(summaryFlash(for: report, failures: failures, subject: nil))
        }
    }

    /// 右键「同步模型与价格」：立即同步单个节点，结束后给出横幅。
    func syncNow(_ target: Target) {
        guard !syncingTargets.contains(target), !isSyncingAll else { return }
        syncingTargets.insert(target)
        Task {
            defer {
                syncingTargets.remove(target)
                upstreamCache = [:]
            }
            let priceCatalog = try? await ModelsDevPricingService.catalog()
            var report: Report
            switch target {
            case .provider(let id):
                report = await syncProvider(id, priceCatalog: priceCatalog)
                // 提供商的 Claude / Codex 链接节点各自持有本地费用规则，顺带补价。
                for child in NodeProfileStore.shared.profiles where child.metadata.linkedProviderId == id {
                    report.absorb(await syncProfile(child.id, priceCatalog: priceCatalog, interactive: true))
                }
            case .profile(let id):
                report = await syncProfile(id, priceCatalog: priceCatalog, interactive: true)
            case .openCode(let id):
                report = await syncOpenCode(id, priceCatalog: priceCatalog)
            }
            report.pricingUnavailable = priceCatalog == nil
            saveState()
            show(summaryFlash(for: report, failures: report.fetchError == nil ? 0 : 1, subject: displayName(for: target)))
        }
    }

    func isSyncing(_ target: Target) -> Bool {
        isSyncingAll || syncingTargets.contains(target)
    }

    // MARK: - API Provider
    // 三个 sync 函数统一两段式：先 await 读取上游（不持有配置快照），再重新读取最新配置、
    // 计算并写回，读写之间不再 await。否则请求期间用户在编辑器保存、或另一轮同步写入的内容
    // 会被旧快照覆盖，而新模型已记进基线，就再也不会被加回来。

    private func syncProvider(
        _ id: String,
        priceCatalog: ModelsDevPricingService.Catalog?
    ) async -> Report {
        let target = Target.provider(id)
        // CPA 托管主配置的模型由 CPA 网关维护，fetchSpec 为 nil，这里只补价格。
        let fetched = await fetchUpstream(for: target)

        guard var provider = APIProviderStore.shared.provider(id: id) else { return Report() }
        let original = provider
        var report = Report()
        var pendingEntry: StateFile.Entry?

        switch currentUpstreamResult(fetched, for: target) {
        case .success(let spec, let upstream):
            let existing = Set(provider.models.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
            let decision = baselineDecision(
                for: target, spec: spec, upstream: upstream, existing: existing, mergeAllOnFirstSync: false
            )
            provider.models.append(contentsOf: decision.newModels.map {
                ProxyConfiguration.MappedModel(name: $0, pricing: .init())
            })
            report.addedModels = decision.newModels
            report.baselineRecorded = decision.isFirstSync ? upstream.count : 0
            pendingEntry = decision.entry
        case .failure(let message):
            report.fetchError = message
        case .skipped:
            break
        }

        if let priceCatalog {
            let prices = ModelsDevPricingService.pricingMap(
                models: provider.models.map(\.name),
                upstreamBaseURL: provider.baseURL,
                in: priceCatalog
            )
            let currency = PublicPriceUpdate.dominantCurrency(provider.models.map(\.pricing))
            for index in provider.models.indices {
                let model = provider.models[index]
                let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let updated = PublicPriceUpdate.updatedPricing(
                    forProviderModel: model.pricing,
                    candidate: prices[name],
                    targetCurrency: currency
                ) else { continue }
                if model.pricing.hasAnyRate || model.pricing.source?.kind == .modelsDev {
                    report.refreshedPrices += 1
                } else {
                    report.filledPrices += 1
                }
                provider.models[index].pricing = updated
            }
        } else {
            report.pricingUnavailable = true
        }

        if let pendingEntry { state.entries[target.stateKey] = pendingEntry }
        guard provider != original else { return report }

        APIProviderStore.shared.upsert(provider)
        await APIProviderDistributor.shared.propagateCatalog(
            from: provider,
            modelNamesChanged: !report.addedModels.isEmpty
        )
        return report
    }

    // MARK: - Claude / Codex Node

    /// - Parameter interactive: 用户右键手动同步。Claude / Codex 目录与编辑器「同步」按钮一致，
    ///   首次可以全量合并；后台首次只记基线，避免聚合网关的几百个模型悄悄灌进 Desktop 模型列表。
    private func syncProfile(
        _ id: String,
        priceCatalog: ModelsDevPricingService.Catalog?,
        interactive: Bool
    ) async -> Report {
        let target = Target.profile(id)
        let fetched = await fetchUpstream(for: target)

        guard let profile = NodeProfileStore.shared.profile(for: id) else { return Report() }
        let meta = profile.metadata
        let linkedProvider = linkedProvider(meta.linkedProviderId)
        var report = Report()
        report.managedByProvider = linkedProvider != nil
            && !(meta.overriddenKeys?.contains(APIProviderSharedKey.models) ?? false)

        var catalog = meta.proxy.modelCatalog
        let original = catalog
        var pendingEntry: StateFile.Entry?

        switch currentUpstreamResult(fetched, for: target) {
        case .success(let spec, let upstream):
            let decision = baselineDecision(
                for: target, spec: spec, upstream: upstream,
                existing: Set(catalog.models), mergeAllOnFirstSync: interactive
            )
            catalog.mergeModels(decision.newModels)
            report.addedModels = decision.newModels
            report.baselineRecorded = decision.isFirstSync && decision.newModels.isEmpty ? upstream.count : 0
            pendingEntry = decision.entry
        case .failure(let message):
            report.fetchError = message
        case .skipped:
            break
        }

        if let priceCatalog {
            let upstreamBaseURL = meta.nodeType == .anthropicDirect
                ? meta.proxy.anthropicBaseURL
                : meta.proxy.normalizedUpstreamBaseURL
            let publicPrices = ModelsDevPricingService.pricingMap(
                models: catalog.models,
                upstreamBaseURL: upstreamBaseURL,
                in: priceCatalog
            )
            let providerPrices = Self.providerPrices(linkedProvider)
            let before = catalog.pricingOverrides
            catalog.applyPublicPrices { providerPrices[$0] ?? publicPrices[$0] }
            for (model, pricing) in catalog.pricingOverrides where before[model] != pricing {
                if before[model] == nil { report.filledPrices += 1 } else { report.refreshedPrices += 1 }
            }
        } else {
            report.pricingUnavailable = true
        }

        if let pendingEntry { state.entries[target.stateKey] = pendingEntry }
        if catalog != original {
            ProxyViewModel.shared.applyModelCatalogUpdate(nodeID: id, catalog: catalog)
        }
        return report
    }

    // MARK: - OpenCode Node

    private func syncOpenCode(
        _ id: String,
        priceCatalog: ModelsDevPricingService.Catalog?
    ) async -> Report {
        let target = Target.openCode(id)
        let fetched = await fetchUpstream(for: target)

        guard var node = OpenCodeNodeStore.shared.nodes.first(where: { $0.id == id }) else { return Report() }
        var report = Report()
        // 模型与价格条目都随所链接的提供商传播，这里不重复处理。
        if linkedProvider(node.linkedProviderId) != nil,
           !(node.overriddenKeys?.contains(APIProviderSharedKey.models) ?? false) {
            report.managedByProvider = true
            return report
        }

        let original = node
        var pendingEntry: StateFile.Entry?

        switch currentUpstreamResult(fetched, for: target) {
        case .success(let spec, let upstream):
            let decision = baselineDecision(
                for: target, spec: spec, upstream: upstream,
                existing: Set(node.models), mergeAllOnFirstSync: false
            )
            node.modelEntries.append(contentsOf: decision.newModels.map { OpenCodeModelEntry(id: $0) })
            if node.defaultModel.isEmpty, let first = node.models.first {
                node.defaultModel = first
            }
            report.addedModels = decision.newModels
            report.baselineRecorded = decision.isFirstSync ? upstream.count : 0
            pendingEntry = decision.entry
        case .failure(let message):
            report.fetchError = message
        case .skipped:
            break
        }

        if let priceCatalog {
            let prices = ModelsDevPricingService.pricingMap(
                models: node.models,
                upstreamBaseURL: node.baseURL,
                in: priceCatalog
            )
            for index in node.modelEntries.indices {
                let entry = node.modelEntries[index]
                guard let updated = PublicPriceUpdate.updatedEntry(
                    entry,
                    nodeCurrency: node.pricingCurrency,
                    candidate: prices[entry.id.trimmingCharacters(in: .whitespacesAndNewlines)]
                ) else { continue }
                if entry.hasPricing || entry.pricingSource?.kind == .modelsDev {
                    report.refreshedPrices += 1
                } else {
                    report.filledPrices += 1
                }
                node.modelEntries[index] = updated
            }
            if report.filledPrices > 0, node.pricingCurrency == .none {
                node.pricingCurrency = .usd
            }
        } else {
            report.pricingUnavailable = true
        }

        if let pendingEntry { state.entries[target.stateKey] = pendingEntry }
        if node != original {
            OpenCodeNodeStore.shared.upsert(node)
        }
        return report
    }

    // MARK: - Upstream Fetch

    struct FetchSpec: Hashable {
        let baseURL: String
        let apiKey: String
        let style: ModelListEndpointStyle

        var upstreamIdentity: String { UpstreamModelListClient.upstreamIdentity(baseURL: baseURL) }
    }

    /// 某个同步目标需要读取的上游；nil 表示该目标不拉模型（托管 / 未填地址 / 缺 Key）。
    private func fetchSpec(for target: Target) -> FetchSpec? {
        func make(_ baseURL: String, _ apiKey: String, _ style: ModelListEndpointStyle, requiresKey: Bool) -> FetchSpec? {
            let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty, !(requiresKey && key.isEmpty) else { return nil }
            return FetchSpec(baseURL: base, apiKey: key, style: style)
        }

        switch target {
        case .provider(let id):
            guard id != CLIProxyGatewayManager.managedProviderID,
                  let provider = APIProviderStore.shared.provider(id: id) else { return nil }
            return make(provider.baseURL, provider.apiKey,
                        provider.format == .anthropic ? .anthropic : .openAICompatible,
                        requiresKey: false)
        case .profile(let id):
            guard let meta = NodeProfileStore.shared.profile(for: id)?.metadata else { return nil }
            if linkedProvider(meta.linkedProviderId) != nil,
               !(meta.overriddenKeys?.contains(APIProviderSharedKey.models) ?? false) {
                return nil
            }
            if meta.nodeType == .anthropicDirect {
                return make(meta.proxy.anthropicBaseURL, meta.proxy.anthropicAPIKey, .anthropic, requiresKey: true)
            }
            return make(meta.proxy.normalizedUpstreamBaseURL, meta.proxy.upstreamAPIKey, .openAICompatible, requiresKey: true)
        case .openCode(let id):
            guard let node = OpenCodeNodeStore.shared.nodes.first(where: { $0.id == id }) else { return nil }
            if linkedProvider(node.linkedProviderId) != nil,
               !(node.overriddenKeys?.contains(APIProviderSharedKey.models) ?? false) {
                return nil
            }
            return make(node.baseURL, node.apiKey,
                        node.protocolType == .anthropic ? .anthropic : .openAICompatible,
                        requiresKey: false)
        }
    }

    /// 同时在途的上游请求上限：节点很多时不把所有上游一起打满，也不占满 URLSession 连接。
    private static let maxConcurrentFetches = 6

    private func prefetch(_ specs: Set<FetchSpec>) async {
        let pending = Array(specs.filter { upstreamCache[$0] == nil })
        guard !pending.isEmpty else { return }
        let results = await withTaskGroup(of: (FetchSpec, Result<[String], Error>).self) { group in
            var iterator = pending.makeIterator()
            var started = 0
            while started < Self.maxConcurrentFetches, let spec = iterator.next() {
                group.addTask { await Self.fetchResult(spec) }
                started += 1
            }
            var collected: [(FetchSpec, Result<[String], Error>)] = []
            while let result = await group.next() {
                collected.append(result)
                if let spec = iterator.next() {
                    group.addTask { await Self.fetchResult(spec) }
                }
            }
            return collected
        }
        for (spec, result) in results { upstreamCache[spec] = result }
    }

    private static func fetchResult(_ spec: FetchSpec) async -> (FetchSpec, Result<[String], Error>) {
        do {
            let models = try await UpstreamModelListClient.fetchModelIDs(
                baseURL: spec.baseURL, apiKey: spec.apiKey, style: spec.style
            )
            return (spec, .success(models))
        } catch {
            return (spec, .failure(error))
        }
    }

    private struct FetchedUpstream {
        let spec: FetchSpec
        let result: Result<[String], Error>
    }

    private enum UpstreamOutcome {
        case success(FetchSpec, [String])
        case failure(String)
        /// 不需要拉模型，或请求期间上游地址 / Key 被修改（本轮结果作废，下一轮按新上游重来）。
        case skipped
    }

    private func fetchUpstream(for target: Target) async -> FetchedUpstream? {
        guard let spec = fetchSpec(for: target) else { return nil }
        return FetchedUpstream(spec: spec, result: await upstreamModels(spec))
    }

    /// 只有当上游配置在请求期间没变时，结果才用于当前配置。
    private func currentUpstreamResult(_ fetched: FetchedUpstream?, for target: Target) -> UpstreamOutcome {
        guard let fetched, fetchSpec(for: target) == fetched.spec else { return .skipped }
        switch fetched.result {
        case .success(let models): return .success(fetched.spec, models)
        case .failure(let error): return .failure(error.localizedDescription)
        }
    }

    private func upstreamModels(_ spec: FetchSpec) async -> Result<[String], Error> {
        if let cached = upstreamCache[spec] { return cached }
        await prefetch([spec])
        return upstreamCache[spec] ?? .failure(UpstreamModelListError.emptyList)
    }

    // MARK: - Baseline

    private struct BaselineDecision {
        let newModels: [String]
        let isFirstSync: Bool
        let entry: StateFile.Entry
    }

    /// 计算本次应加入的新模型。换了上游地址视为首次同步，避免把另一个上游的整份目录当成「新上架」。
    private func baselineDecision(
        for target: Target,
        spec: FetchSpec,
        upstream: [String],
        existing: Set<String>,
        mergeAllOnFirstSync: Bool
    ) -> BaselineDecision {
        let previous = state.entries[target.stateKey]
        let isFirstSync = previous == nil || previous?.upstreamIdentity != spec.upstreamIdentity
        let known = isFirstSync ? Set<String>() : Set(previous?.knownModels ?? [])
        let newModels = upstream.filter { model in
            guard !existing.contains(model) else { return false }
            return isFirstSync ? mergeAllOnFirstSync : !known.contains(model)
        }
        let entry = StateFile.Entry(
            upstreamIdentity: spec.upstreamIdentity,
            knownModels: known.union(upstream).sorted(),
            lastSyncedAt: Date()
        )
        return BaselineDecision(newModels: newModels, isFirstSync: isFirstSync, entry: entry)
    }

    // MARK: - Helpers

    private func linkedProvider(_ id: String?) -> APIProvider? {
        id.flatMap { APIProviderStore.shared.provider(id: $0) }
    }

    /// 提供商为各模型设置的默认价（有单价的才算）。
    private static func providerPrices(_ provider: APIProvider?) -> [String: ProxyConfiguration.ModelPricing] {
        guard let provider else { return [:] }
        var result: [String: ProxyConfiguration.ModelPricing] = [:]
        for model in provider.models where model.pricing.hasAnyRate {
            result[model.name.trimmingCharacters(in: .whitespacesAndNewlines)] = model.pricing
        }
        return result
    }

    private func displayName(for target: Target) -> String {
        switch target {
        case .provider(let id):
            return APIProviderStore.shared.provider(id: id)?.displayName ?? ""
        case .profile(let id):
            return NodeProfileStore.shared.profile(for: id)?.metadata.name ?? ""
        case .openCode(let id):
            return OpenCodeNodeStore.shared.nodes.first { $0.id == id }?.displayName ?? ""
        }
    }

    private func summaryFlash(for report: Report, failures: Int, subject: String?) -> AppFlash {
        let prefix = subject.map { L("“\($0)”: ", "「\($0)」：") } ?? ""
        var parts: [String] = []
        if !report.addedModels.isEmpty {
            parts.append(L("\(report.addedModels.count) new models", "新增 \(report.addedModels.count) 个模型"))
        }
        if report.filledPrices > 0 {
            parts.append(L("\(report.filledPrices) prices filled", "补齐 \(report.filledPrices) 个价格"))
        }
        if report.refreshedPrices > 0 {
            parts.append(L("\(report.refreshedPrices) prices updated", "更新 \(report.refreshedPrices) 个价格"))
        }

        if parts.isEmpty {
            if let error = report.fetchError, subject != nil {
                return .error(prefix + error)
            }
            if report.managedByProvider, subject != nil {
                return .info(prefix + L(
                    "Models follow the linked API provider; prices are up to date.",
                    "模型跟随所链接的 API 提供商，价格已是最新。"
                ))
            }
            if report.baselineRecorded > 0 {
                return .info(prefix + L(
                    "Recorded \(report.baselineRecorded) upstream models as the baseline; newly listed models will be added automatically.",
                    "已记录上游 \(report.baselineRecorded) 个模型作为基线，之后新上架的模型会自动加入。"
                ))
            }
            if report.pricingUnavailable {
                return .error(prefix + L("models.dev is unreachable; prices were not checked.", "无法连接 models.dev，未检查价格。"))
            }
            return .success(prefix + L("Models and prices are up to date.", "模型与价格已是最新。"))
        }

        var message = prefix + parts.joined(separator: L(", ", "，"))
        if failures > 0 {
            message += L(" (\(failures) upstreams unreachable)", "（\(failures) 个上游读取失败）")
        }
        return .success(message)
    }

    private func show(_ flash: AppFlash) {
        let binding = Binding<AppFlash?>(
            get: { [weak self] in self?.flash },
            set: { [weak self] in self?.flash = $0 }
        )
        AppFlashPresenter.present(flash, into: binding, durationNanoseconds: 3_600_000_000)
    }

    // MARK: - Persistence

    struct StateFile: Codable {
        struct Entry: Codable {
            var upstreamIdentity: String
            var knownModels: [String]
            var lastSyncedAt: Date?
        }

        var version = 1
        var lastRunAt: Date?
        var entries: [String: Entry] = [:]
    }

    static var statePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/model-sync-state.json")
    }

    private static func loadState() -> StateFile {
        guard let data = FileManager.default.contents(atPath: statePath) else { return StateFile() }
        do {
            return try JSONDecoder.profileDecoder.decode(StateFile.self, from: data)
        } catch {
            modelSyncLog.error("Failed to load model sync state: \(String(describing: error), privacy: .public)")
            return StateFile()
        }
    }

    private func saveState() {
        do {
            let dir = (Self.statePath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder.profileEncoder.encode(state)
            try data.write(to: URL(fileURLWithPath: Self.statePath), options: .atomic)
        } catch {
            modelSyncLog.error("Failed to save model sync state: \(String(describing: error), privacy: .public)")
        }
    }

    private func pruneState(validKeys: Set<String>) {
        state.entries = state.entries.filter { validKeys.contains($0.key) }
    }
}

// MARK: - Flash Overlay

/// 节点列表页显示同步结果横幅。只有这个修饰器订阅协调器，列表本身不会因同步状态变化而重绘。
private struct ModelSyncFlashOverlay: ViewModifier {
    @ObservedObject private var coordinator = ModelAutoSyncCoordinator.shared

    func body(content: Content) -> some View {
        content.appFlashOverlay(coordinator.flash)
    }
}

extension View {
    func modelSyncFlashOverlay() -> some View {
        modifier(ModelSyncFlashOverlay())
    }
}
