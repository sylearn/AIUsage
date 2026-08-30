import SwiftUI
import Combine
import Foundation
import os.log
import QuotaBackend

// MARK: - Proxy ViewModel

internal let proxyPersistenceLog = Logger(subsystem: "com.aiusage.desktop", category: "ProxyPersistence")
internal let proxyRuntimeLog = Logger(subsystem: "com.aiusage.desktop", category: "ProxyRuntime")

// MARK: - Proxy Persistence Infrastructure
// 代理日志/统计/用量归档的后台持久化基础设施：所有 JSON 编码与磁盘写入统一经由
// 同一条串行队列执行，确保写入顺序（先入队先落盘）并把高成本编码移出主线程。
// 代理高频请求期间主线程只做内存快照，落盘不再阻塞 UI。
enum ProxyPersistence {
    static let queue = DispatchQueue(label: "com.aiusage.proxy-persistence", qos: .utility)
    static let encoder = JSONEncoder()

    /// DateFormatter 的 string(from:) 自 macOS 10.9 起线程安全，可跨队列共享。
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    static func dayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    /// 把日键解析为本地时区的 [当日起点, 次日起点) 区间。
    /// 与 `dayKey(for:)` 的分桶语义一致；跨日扫描时用 Date 区间比较替代
    /// 对每条日志做 DateFormatter 格式化（后者贵 1-2 个数量级）。
    static func dayInterval(for key: String) -> (start: Date, end: Date)? {
        guard let start = dayKeyFormatter.date(from: key) else { return nil }
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        return (start, end)
    }
}

enum ProxyRuntimeError: LocalizedError {
    case configurationNotFound
    case quotaServerNotFound
    case proxyStartFailed(String)
    case proxyPortInUse(Int)
    /// 端口已被本 App 另一条正在运行的代理（Claude/Codex/OpenCode 任一轨）占用：附 (端口, 代理家族, 占用节点名)。
    case proxyPortInUseByNode(Int, String, String)
    case activationStatePersistFailed
    case deactivationStatePersistFailed
    /// Claude Code 已接入 Code 网关时，禁止再直连激活节点。
    case managedByCodeGateway

    var errorDescription: String? {
        switch self {
        case .configurationNotFound:
            return AppSettings.shared.t("The selected node could not be found.", "找不到所选节点。")
        case .quotaServerNotFound:
            return AppSettings.shared.t(
                "QuotaServer helper not found. Rebuild or reinstall AIUsage, then try again.",
                "找不到 QuotaServer 辅助程序。请重新构建或重新安装 AIUsage 后再试。"
            )
        case .proxyStartFailed(let reason):
            return AppSettings.shared.t("Failed to start proxy: \(reason)", "启动代理失败：\(reason)")
        case .proxyPortInUse(let port):
            return AppSettings.shared.t(
                "Port \(port) is already in use by another process. Quit the program occupying it (or restart AIUsage to clear leftover proxies), then try again.",
                "端口 \(port) 已被其它进程占用。请关闭占用该端口的程序（或重启 AIUsage 清理残留代理）后重试。"
            )
        case .proxyPortInUseByNode(let port, let track, let name):
            return AppSettings.shared.t(
                "Port \(port) is already in use by node \"\(name)\" under the \(track) proxy. Change this node's port, or stop that node first.",
                "端口 \(port) 已被「\(track) 代理」下的节点「\(name)」占用。请修改本节点端口，或先停用那个节点。"
            )
        case .activationStatePersistFailed:
            return AppSettings.shared.t("The node started, but AIUsage could not persist the activated state.", "节点已启动，但 AIUsage 无法保存激活状态。")
        case .deactivationStatePersistFailed:
            return AppSettings.shared.t("The node stopped, but AIUsage could not persist the deactivated state.", "节点已停止，但 AIUsage 无法保存停用状态。")
        case .managedByCodeGateway:
            return AppSettings.shared.t(
                "Claude Code is attached to Code Gateway. Switch its route from the Code card, or disconnect Code before using a direct node.",
                "Claude Code 已接入 Code 网关。请在 Code 卡片中切换路由，或先断开 Code 再使用直连节点。"
            )
        }
    }
}

struct ProxyConnectivityTestState: Equatable, Codable {
    var isTesting: Bool = false
    var lastSucceeded: Bool?
    /// 完整明细（脱敏后），供失败 Popover 展示与复制。
    var message: String?
    /// 已知的 HTTP 状态码（成功/失败均可能有），用于徽章短摘要。
    var statusCode: Int?
    /// 成功时的往返耗时（毫秒）。
    var latencyMs: Int?
    /// 本次结果产生的时间，供 Popover 显示「多久之前」。
    var testedAt: Date?
}

/// Lifecycle ownership for one reusable Node Runtime. Product gateways carry
/// this control-plane identity; requests on the node data plane do not.
enum NodeRuntimeConsumer: String, Codable, CaseIterable, Hashable {
    case code
    case desktop
    case science
    case manual

    var label: String {
        switch self {
        case .code: return "Code"
        case .desktop: return "Desktop"
        case .science: return "Science"
        case .manual: return AppSettings.shared.t("Manual", "手动")
        }
    }
}

struct UnusedNodeRuntimePrompt: Identifiable, Equatable {
    let nodeID: String
    let nodeName: String
    var id: String { nodeID }
}

@MainActor
class ProxyViewModel: ObservableObject {
    static let shared = ProxyViewModel()

    @Published var configurations: [ProxyConfiguration] = []
    @Published var activatedConfigId: String?
    /// Codex 节点独立的激活轨道。Codex 写 ~/.codex/config.toml，与 Claude 节点（~/.claude/settings.json）
    /// 写不同文件，故二者可同时激活，分别用 `activatedConfigId` / `activatedCodexConfigId` 跟踪。
    @Published var activatedCodexConfigId: String?
    @Published var proxyOnlyRunningIds: Set<String> = []
    /// Control-plane leases for shared Node Runtime processes. A single node
    /// process can serve Code, Desktop and Science concurrently.
    @Published var nodeRuntimeConsumers: [String: Set<NodeRuntimeConsumer>] = [:]
    @Published var unusedNodeRuntimePrompt: UnusedNodeRuntimePrompt?
    /// Coalesces simultaneous Code/Desktop/Science requests for the same node
    /// into one process launch and one port bind.
    var nodeRuntimeStartTasks: [String: Task<Void, Error>] = [:]
    // `statistics` and `recentLogs` are intentionally NOT @Published: writes happen on every
    // proxied request (potentially many per second during streaming) and each publish would
    // force every observing view to rebuild body + re-aggregate on the main thread. Instead,
    // mutations feed `logsChangeSubject`, which throttles UI notifications to `logsPublishInterval`
    // via `objectWillChange.send()`. Persistence is debounced via `schedulePersistence()` to
    // avoid redundant full-JSON encodes on every request; critical exit points flush immediately.
    var statistics: [String: ProxyStatistics] = [:]
    var recentLogs: [String: [ProxyRequestLog]] = [:]
    @Published var operationErrorMessage: String?
    @Published var operationInProgressConfigIds: Set<String> = []
    @Published var connectivityTestStates: [String: ProxyConnectivityTestState] = [:]
    var proxyRuntimeRestartAttempts: [String: Int] = [:]
    /// 自动重启已耗尽、确认代理进程未在运行的激活节点（fail-loud：不再静默自动停用，
    /// 改为保留激活态 + 持久「本地代理未在运行」横幅 + 手动重启，与 OpenCode 三轨对齐）。
    @Published var proxyRuntimeDownConfigIds: Set<String> = []
    static let maxProxyRuntimeRestartAttempts = 3
    static let proxyRuntimeRestartBaseDelayNanos: UInt64 = 1_000_000_000
    static let proxyRuntimeRestartStabilityWindowNanos: UInt64 = 10_000_000_000

    struct LogCacheKey: Hashable {
        let nodeFilter: String?
        let modelFilter: String?
        var family: ProxyNodeFamily?
    }

    var _logCache: [LogCacheKey: [ProxyRequestLog]] = [:]

    // Cache dictionaries for derived aggregations. All are cleared together with `_logCache`
    // whenever the throttled log refresh fires.
    struct TimeSeriesKey: Hashable {
        let nodeFilter: String?
        let granularity: String
        var family: ProxyNodeFamily?
    }
    struct AggregateKey: Hashable {
        let nodeFilter: String?
        let modelFilter: String?
        let since: Date?
        var family: ProxyNodeFamily?
    }
    struct UpstreamModelsKey: Hashable {
        let nodeFilter: String?
        var family: ProxyNodeFamily?
    }
    var _timeSeriesCache: [TimeSeriesKey: Any] = [:]
    var _modelAggCache: [AggregateKey: Any] = [:]
    var _overallStatsCache: [AggregateKey: Any] = [:]
    var _dateRangeCache: [LogCacheKey: (earliest: Date?, latest: Date?, days: Int)] = [:]
    var _upstreamModelsCache: [UpstreamModelsKey: [String]] = [:]

    let logsChangeSubject = PassthroughSubject<Void, Never>()
    var logsChangeCancellable: AnyCancellable?
    /// Set by `scheduleLogsRefresh`, cleared by both the throttle sink and `flushLogsRefresh`.
    /// Prevents a stale throttle event from triggering a redundant `objectWillChange` after
    /// a synchronous flush already refreshed the UI.
    private var logsDirty = false
    /// Throttle window for coalescing log-driven UI refreshes. Individual log writes still hit
    /// storage immediately; only the SwiftUI invalidation is batched.
    static let logsPublishInterval: TimeInterval = 0.5

    var persistenceWorkItem: DispatchWorkItem?
    static let persistenceDebounceInterval: TimeInterval = 2.0
    var logsDirtyDays: Set<String> = []

    let runtimeService: ProxyRuntimeService

    var logRetentionDays: Int {
        let days = UserDefaults.standard.integer(forKey: DefaultsKey.proxyLogRetentionDays)
        return days > 0 ? days : 30
    }

    var logsFilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/proxy-logs.json")
    }

    var logsShardDirPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/proxy-logs")
    }

    func shardDayKey(_ date: Date) -> String {
        ProxyPersistence.dayKey(for: date)
    }

    init() {
        runtimeService = ProxyRuntimeService()
        runtimeService.delegate = self
        logsChangeCancellable = logsChangeSubject
            .throttle(for: .seconds(Self.logsPublishInterval), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                guard let self, self.logsDirty else { return }
                self.logsDirty = false
                // 缓存失效与 UI 通知同步节流：高频请求期间不再每条都清空全部聚合缓存，
                // 派生数据最多滞后 logsPublishInterval（与 UI 刷新节奏一致）。
                self.invalidateLogCaches()
                self.objectWillChange.send()
            }
        loadConfigurations()
        restoreConnectivityResults()
        loadStatistics()
        loadLogs()
        restoreActivatedNode()
        observeCodexAccountActivation()
    }

    /// 互斥：监听 Codex 订阅账号激活通知。账号写 ~/.codex/auth.json 前，先停用正在运行的
    /// Codex 代理并还原 config.toml，避免两条轨道同时改 ~/.codex 造成冲突与统计串台。
    private func observeCodexAccountActivation() {
        NotificationCenter.default.addObserver(
            forName: .codexSubscriptionAccountActivating,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                if GlobalProxyManager.codex.isEnabled {
                    await GlobalProxyManager.codex.disable()
                }
                guard let self, let id = self.activatedCodexConfigId else { return }
                await self.deactivateConfiguration(id)
            }
        }
    }

    /// Marks that logs/statistics have changed. Cache invalidation and the `objectWillChange`
    /// notification are both coalesced by the throttle in `init` (invalidating on every call
    /// would force a full re-aggregation per proxied request during streaming bursts);
    /// callers that need the UI to update synchronously (e.g. user-initiated delete/clear)
    /// should additionally call `flushLogsRefresh()`.
    func scheduleLogsRefresh() {
        logsDirty = true
        logsChangeSubject.send(())
    }

    /// Forces any pending throttled refresh to fire immediately. Used by user-initiated
    /// operations (add/delete node, clear logs) where we don't want up-to-0.5s staleness.
    func flushLogsRefresh() {
        logsDirty = false
        invalidateLogCaches()
        objectWillChange.send()
    }

    func invalidateLogCaches() {
        _logCache.removeAll()
        _timeSeriesCache.removeAll()
        _modelAggCache.removeAll()
        _overallStatsCache.removeAll()
        _dateRangeCache.removeAll()
        _upstreamModelsCache.removeAll()
    }

    // MARK: - Profile Store Bridge

    /// Reference to the file-based profile store (injected or shared singleton).
    var profileStore: NodeProfileStore { NodeProfileStore.shared }

    // MARK: - Configuration Management

    func loadConfigurations() {
        configurations = profileStore.profiles.map { $0.metadata.proxy.toProxyConfiguration(metadata: $0.metadata) }
        migrateLegacyDesktopSupports1M()
    }

    /// 把旧版存在 Desktop 轨配置里的 1M 声明搬到节点上，然后清空遗留字段。
    ///
    /// 用并集而非覆盖，且只在真正发生变化时落盘——重复执行无副作用，节点上已有的新声明
    /// 也不会被旧档回退。
    private func migrateLegacyDesktopSupports1M() {
        var legacy = GlobalProxyStore.load(track: .desktop)
        guard let byNode = legacy.claudeDesktopSupports1MByNode, !byNode.isEmpty else { return }

        for (nodeID, _) in byNode {
            let declared = legacy.legacyClaudeDesktopSupports1MModels(for: nodeID)
            guard !declared.isEmpty,
                  let index = configurations.firstIndex(where: { $0.id == nodeID }),
                  var profile = profileStore.profile(for: nodeID) else { continue }
            let merged = configurations[index].modelCatalog.supports1MModels.union(declared)
            guard merged != configurations[index].modelCatalog.supports1MModels else { continue }
            profile.metadata.proxy.modelCatalog.supports1MModels = merged
            guard profileStore.save(profile) else { continue }
            configurations[index].modelCatalog.supports1MModels = merged
        }

        // 刻意只读写磁盘、不碰 GlobalProxyManager.desktop：本方法可能在 ProxyViewModel
        // 初始化期间运行，此时去触发另一个单例的构造是自找的初始化顺序问题。代价是若该
        // 单例已加载并在之后 persist()，遗留字段会被写回一次——迁移是并集且幂等，下次启动
        // 再搬一遍即收敛。
        // 只有节点侧都写成功才清遗留字段，否则下次启动还能再搬一次。
        let unmigrated = byNode.keys.filter { nodeID in
            let declared = legacy.legacyClaudeDesktopSupports1MModels(for: nodeID)
            guard !declared.isEmpty else { return false }
            guard let node = configurations.first(where: { $0.id == nodeID }) else {
                // 节点已被删除，这份声明没有归属可搬，不该永久阻塞迁移。
                return false
            }
            return !declared.isSubset(of: node.modelCatalog.supports1MModels)
        }
        guard unmigrated.isEmpty else { return }
        legacy.claudeDesktopSupports1MByNode = nil
        _ = GlobalProxyStore.save(legacy, track: .desktop)
    }

    @discardableResult
    func saveConfigurations() -> Bool {
        return true
    }

    /// Persist a single profile to its JSON file via the store.
    @discardableResult
    func saveProfile(_ profile: NodeProfile) -> Bool {
        return profileStore.save(profile)
    }

    /// 声明/取消某个上游模型的 1M 上下文能力。
    ///
    /// 刻意不走 `updateConfiguration` / `updateProfile`：那两条路会先停掉再重建节点运行时，
    /// 而这里改的只是「对外声明的目录」，不影响进程该怎么跑。调用方负责在写成功后让相关
    /// 轨道热下发新目录（`GlobalProxyManager.applyNodeSupports1M`）。
    @discardableResult
    func setSupports1M(nodeID: String, modelID: String, enabled: Bool) -> Bool {
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty,
              let index = configurations.firstIndex(where: { $0.id == nodeID }) else { return false }

        var updated = configurations[index].modelCatalog.supports1MModels
        if enabled {
            updated.insert(model)
        } else {
            updated.remove(model)
        }
        guard updated != configurations[index].modelCatalog.supports1MModels else { return true }

        // 以盘上 profile 为基底改写，而不是从 ProxyConfiguration 反向重建：profile 里有
        // 不进 ProxyConfiguration 的字段，重建会把它们抹掉。
        guard var profile = profileStore.profile(for: nodeID) else { return false }
        let previous = configurations[index].modelCatalog.supports1MModels
        profile.metadata.proxy.modelCatalog.supports1MModels = updated
        configurations[index].modelCatalog.supports1MModels = updated
        guard profileStore.save(profile) else {
            configurations[index].modelCatalog.supports1MModels = previous
            return false
        }
        return true
    }

    func saveActivatedId() {
        if let id = activatedConfigId {
            UserDefaults.standard.set(id, forKey: DefaultsKey.proxyActivatedConfigId)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.proxyActivatedConfigId)
        }
        profileStore.activatedProfileId = activatedConfigId
        profileStore.saveActivatedId()
    }

    func saveActivatedCodexId() {
        if let id = activatedCodexConfigId {
            UserDefaults.standard.set(id, forKey: DefaultsKey.proxyActivatedCodexConfigId)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.proxyActivatedCodexConfigId)
        }
    }

    // MARK: - Activation Family Helpers

    /// 某节点是否处于激活态（任一轨道）。
    func isNodeActivated(_ id: String) -> Bool {
        activatedConfigId == id || activatedCodexConfigId == id
    }

    /// 横幅「重启代理」按钮：手动拉起被标记为 down 的激活节点的代理进程。
    /// settings.json/config.toml 在 fail-loud 下并未还原（仍指向本地端口），故只需重启进程即可恢复。
    /// 不传 ids 时重启全部 down 节点；传入则只重启指定家族的节点。
    func restartDownProxyRuntime(ids: Set<String>? = nil) async {
        let targets = ids ?? proxyRuntimeDownConfigIds
        for id in targets {
            guard isNodeActivated(id) || !nodeRuntimeConsumers[id, default: []].isEmpty,
                  let config = configurations.first(where: { $0.id == id }),
                  config.needsProxyProcess else {
                proxyRuntimeDownConfigIds.remove(id)
                continue
            }
            proxyRuntimeRestartAttempts.removeValue(forKey: id)
            do {
                try await runtimeService.startProxyOnly(for: config)
                proxyRuntimeDownConfigIds.remove(id)
                proxyRuntimeLog.info("Manually restarted proxy for node \(config.name, privacy: .public)")
            } catch {
                let redactedMessage = SensitiveDataRedactor.redactedMessage(for: error)
                operationErrorMessage = redactedMessage
                proxyRuntimeLog.error("Manual proxy restart failed for node \(config.name, privacy: .public): \(redactedMessage, privacy: .public)")
            }
        }
    }

    /// 取指定家族当前激活的节点 id（Codex 走独立轨道）。
    func activatedId(isCodex: Bool) -> String? {
        isCodex ? activatedCodexConfigId : activatedConfigId
    }

    private func nodeIsCodex(_ id: String) -> Bool {
        configurations.first(where: { $0.id == id })?.nodeType.isCodex ?? false
    }

    func moveConfiguration(fromId: String, toIndex: Int) {
        guard let fromIndex = configurations.firstIndex(where: { $0.id == fromId }) else { return }
        let clampedTarget = min(max(toIndex, 0), configurations.count)
        guard fromIndex != clampedTarget, fromIndex != clampedTarget - 1 else { return }
        let item = configurations.remove(at: fromIndex)
        let insertAt = clampedTarget > fromIndex ? clampedTarget - 1 : clampedTarget
        configurations.insert(item, at: insertAt)
        profileStore.move(fromId: fromId, toIndex: toIndex)
    }

    func addConfiguration(_ config: ProxyConfiguration) {
        let profile = NodeProfile.fromLegacyConfiguration(config)
        profileStore.save(profile)
        configurations.insert(config, at: 0)
        if config.nodeType == .openaiProxy || config.nodeType == .codexProxy {
            statistics[config.id] = .empty
            recentLogs[config.id] = []
        }
        saveStatistics()
        saveLogs()
        flushLogsRefresh()
    }

    func addProfile(_ profile: NodeProfile) {
        profileStore.save(profile)
        let config = profile.metadata.proxy.toProxyConfiguration(metadata: profile.metadata)
        configurations.insert(config, at: 0)
        if profile.metadata.nodeType == .openaiProxy || profile.metadata.nodeType == .codexProxy {
            statistics[profile.id] = .empty
            recentLogs[profile.id] = []
        }
        saveStatistics()
        saveLogs()
        flushLogsRefresh()
    }

    func updateProfile(_ profile: NodeProfile) async {
        let config = profile.metadata.proxy.toProxyConfiguration(metadata: profile.metadata)
        guard let index = configurations.firstIndex(where: { $0.id == profile.id }) else { return }
        let wasActivated = isNodeActivated(profile.id)
        let wasProxyOnly = proxyOnlyRunningIds.contains(profile.id)
        let wasRuntimeRunning = runtimeService.isProxyRunning(profile.id)
        let busyIds: Set<String> = [profile.id]
        setOperationInProgress(busyIds, isActive: true)
        defer { setOperationInProgress(busyIds, isActive: false) }
        if wasActivated {
            do {
                try await performDeactivationTransaction(profile.id)
            } catch {
                reportOperationError(error)
                return
            }
        } else if wasRuntimeRunning {
            runtimeService.stopProxyOnly(for: configurations[index])
            if wasProxyOnly { proxyOnlyRunningIds.remove(profile.id) }
        }
        configurations[index] = config
        // Persist only after the old runtime has stopped successfully. Otherwise
        // disk state could describe a node that the still-running process does not.
        profileStore.save(profile)
        // 配置已变更，旧的连通性测试结果不再代表当前节点，清除之。
        clearConnectivityResult(for: profile.id)
        // 节点定价可能在本次保存中被新增/修改，回填历史 $0 日志的费用。
        recalculateCosts(for: profile.id)
        if wasActivated {
            do {
                try await performActivationTransaction(profile.id)
            } catch {
                reportOperationError(error)
            }
        } else if wasRuntimeRunning {
            do {
                try await runtimeService.startProxyOnly(for: config)
                if wasProxyOnly { proxyOnlyRunningIds.insert(profile.id) }
            } catch {
                proxyRuntimeDownConfigIds.insert(profile.id)
                proxyRuntimeLog.error("Failed to restart Node Runtime after profile update for \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            if wasProxyOnly { saveProxyOnlyIds() }
        }
        await ensureLeasedNodeRuntimeAfterUpdate(config, wasRuntimeRunning: wasRuntimeRunning)
        await reapplyManagedRuntimesIfNeeded(for: profile.id)
    }

    func updateConfiguration(_ config: ProxyConfiguration) async {
        if let index = configurations.firstIndex(where: { $0.id == config.id }) {
            let wasActivated = isNodeActivated(config.id)
            let wasProxyOnly = proxyOnlyRunningIds.contains(config.id)
            let wasRuntimeRunning = runtimeService.isProxyRunning(config.id)
            let busyIds: Set<String> = [config.id]
            setOperationInProgress(busyIds, isActive: true)
            defer { setOperationInProgress(busyIds, isActive: false) }
            if wasActivated {
                do {
                    try await performDeactivationTransaction(config.id)
                } catch {
                    reportOperationError(error)
                    return
                }
            } else if wasRuntimeRunning {
                runtimeService.stopProxyOnly(for: configurations[index])
                if wasProxyOnly { proxyOnlyRunningIds.remove(config.id) }
            }
            configurations[index] = config
            // 配置已变更，旧的连通性测试结果不再代表当前节点，清除之。
            clearConnectivityResult(for: config.id)
            let profile = NodeProfile.fromLegacyConfiguration(config)
            profileStore.save(profile)
            // 节点定价可能在本次保存中被新增/修改，回填历史 $0 日志的费用。
            recalculateCosts(for: config.id)
            if wasActivated {
                do {
                    try await performActivationTransaction(config.id)
                } catch {
                    reportOperationError(error)
                }
            } else if wasRuntimeRunning {
                do {
                    try await runtimeService.startProxyOnly(for: config)
                    if wasProxyOnly { proxyOnlyRunningIds.insert(config.id) }
                } catch {
                    proxyRuntimeDownConfigIds.insert(config.id)
                    proxyRuntimeLog.error("Failed to restart Node Runtime after config update for \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
                }
                if wasProxyOnly { saveProxyOnlyIds() }
            }
            await ensureLeasedNodeRuntimeAfterUpdate(config, wasRuntimeRunning: wasRuntimeRunning)
            await reapplyManagedRuntimesIfNeeded(for: config.id)
        }
    }

    func deleteConfiguration(_ id: String) async {
        if let reason = managedRuntimeDeletionBlockReason(for: id) {
            operationErrorMessage = reason
            return
        }
        let busyIds: Set<String> = [id]
        setOperationInProgress(busyIds, isActive: true)
        defer { setOperationInProgress(busyIds, isActive: false) }

        if isNodeActivated(id) {
            do {
                try await performDeactivationTransaction(id)
            } catch {
                reportOperationError(error)
                return
            }
        }

        if proxyOnlyRunningIds.contains(id),
           let config = configurations.first(where: { $0.id == id }) {
            runtimeService.stopProxyOnly(for: config)
            proxyOnlyRunningIds.remove(id)
            saveProxyOnlyIds()
        }

        if let logs = recentLogs[id], !logs.isEmpty {
            let dayKeys = Set(logs.map { shardDayKey($0.timestamp) })
            foldDaysIntoUsageArchive(dayKeys)
            logsDirtyDays.formUnion(dayKeys)
        }

        configurations.removeAll { $0.id == id }
        statistics.removeValue(forKey: id)
        recentLogs.removeValue(forKey: id)
        clearConnectivityResult(for: id)
        profileStore.delete(id)
        saveStatistics()
        saveLogs()
        flushLogsRefresh()
    }

    /// A managed runtime owns a stable route that outlives the node editor. Do
    /// not orphan that route by deleting its active node; the user disconnects
    /// the named consumer first, which also gives each product a clean restore.
    func managedRuntimeDeletionBlockReason(for id: String) -> String? {
        var consumers: [String] = []

        let codex = GlobalProxyManager.codex
        if codex.isRuntimeEnabled, codex.activeNodeId == id { consumers.append("Codex") }

        let claude = GlobalProxyManager.claude
        if claude.activeNodeId == id {
            if claude.config.effectiveClaudeCodeEnabled { consumers.append("Code") }
        }

        let desktop = GlobalProxyManager.desktop
        if desktop.isEnabled, desktop.activeNodeId == id { consumers.append("Desktop") }

        let science = ScienceProxyManager.shared
        if science.isEnabled, science.activeNodeId == id { consumers.append("Science") }

        let openCode = GlobalProxyManager.opencode
        if openCode.isRuntimeEnabled, openCode.activeNodeId == id { consumers.append("OpenCode") }

        guard !consumers.isEmpty else { return nil }
        let names = AppSettings.shared.language == "zh"
            ? consumers.joined(separator: "、")
            : consumers.joined(separator: ", ")
        return AppSettings.shared.t(
            "Disconnect \(names) before deleting this node.",
            "请先断开 \(names)，再删除此节点。"
        )
    }

    /// Node edits must reach every live projection, not just the direct Code
    /// route. This keeps Desktop's picker, Science's model catalog, and global
    /// gateways aligned with the single shared node library.
    private func reapplyManagedRuntimesIfNeeded(for id: String) async {
        let managers = [
            GlobalProxyManager.codex,
            GlobalProxyManager.claude,
            GlobalProxyManager.desktop,
            GlobalProxyManager.opencode,
        ]
        for manager in managers where manager.isRuntimeEnabled && manager.activeNodeId == id {
            await manager.reapplyActiveUpstream()
            if let failure = manager.operationError { operationErrorMessage = failure }
        }

        let science = ScienceProxyManager.shared
        if science.isEnabled, science.activeNodeId == id {
            await science.reapplyActiveUpstream()
            if let failure = science.operationError { operationErrorMessage = failure }
        }
    }

    /// A node editor save may require replacing the process because its fixed
    /// endpoint or upstream credentials changed. Product leases survive that
    /// replacement and the runtime is restored before gateways are reapplied.
    private func ensureLeasedNodeRuntimeAfterUpdate(
        _ config: ProxyConfiguration,
        wasRuntimeRunning: Bool
    ) async {
        guard wasRuntimeRunning,
              !nodeRuntimeConsumers[config.id, default: []].isEmpty,
              !runtimeService.isProxyRunning(config.id) else { return }
        do {
            try await runtimeService.startProxyOnly(for: config)
            proxyRuntimeDownConfigIds.remove(config.id)
        } catch {
            proxyRuntimeDownConfigIds.insert(config.id)
            reportOperationError(error)
        }
    }

    // MARK: - Activate / Deactivate

    func envConfig(for config: ProxyConfiguration) -> ClaudeSettingsManager.EnvConfig {
        let m = config.modelMapping
        let dm = config.defaultModel.isEmpty ? nil : config.defaultModel
        let opus   = m.bigModel.name.isEmpty    ? nil : m.bigModel.name
        let sonnet = m.middleModel.name.isEmpty ? nil : m.middleModel.name
        let haiku  = m.smallModel.name.isEmpty  ? nil : m.smallModel.name

        let certPath: String? = config.enableHTTPS ? TLSCertificateManager.shared.certFilePath : nil

        switch config.nodeType {
        case .anthropicDirect:
            if config.usePassthroughProxy {
                let proxyURL: String
                if config.enableHTTPS {
                    proxyURL = "https://\(config.host):\(config.effectiveHTTPSPort)"
                } else {
                    proxyURL = "http://\(config.host):\(config.port)"
                }
                return .init(baseURL: proxyURL, authToken: config.anthropicAPIKey,
                             defaultModel: dm, opusModel: opus, sonnetModel: sonnet, haikuModel: haiku,
                             nodeExtraCACerts: certPath)
            }
            return .init(baseURL: config.anthropicBaseURL, authToken: config.anthropicAPIKey,
                         defaultModel: dm, opusModel: opus, sonnetModel: sonnet, haikuModel: haiku)
        case .openaiProxy, .codexProxy:
            // Codex 节点通过 activateCodexRuntime 走 config.toml，不会调用本方法；
            // 这里仅为满足 switch 穷尽性，返回与 openaiProxy 同形的配置，实际不会写入 settings.json。
            let proxyKey = config.expectedClientKey.isEmpty ? "proxy-key" : config.expectedClientKey
            let baseURL: String
            if config.enableHTTPS {
                baseURL = "https://\(config.host):\(config.effectiveHTTPSPort)"
            } else {
                baseURL = config.displayURL
            }
            return .init(baseURL: baseURL, authToken: proxyKey,
                         defaultModel: dm, opusModel: opus, sonnetModel: sonnet, haikuModel: haiku,
                         nodeExtraCACerts: certPath)
        }
    }

    func activateConfiguration(_ id: String) async {
        // 仅与同家族当前激活节点互斥（Codex 与 Claude 各自独立轨道）。
        let currentActive = activatedId(isCodex: nodeIsCodex(id))
        let busyIds = Set([id, currentActive].compactMap { $0 })
        guard !busyIds.contains(where: { operationInProgressConfigIds.contains($0) }) else { return }

        setOperationInProgress(busyIds, isActive: true)
        defer { setOperationInProgress(busyIds, isActive: false) }
        operationErrorMessage = nil

        do {
            try await performActivationTransaction(id)
        } catch {
            reportOperationError(error)
        }
    }

    func deactivateConfiguration(_ id: String) async {
        guard !operationInProgressConfigIds.contains(id) else { return }

        let busyIds: Set<String> = [id]
        setOperationInProgress(busyIds, isActive: true)
        defer { setOperationInProgress(busyIds, isActive: false) }
        operationErrorMessage = nil

        do {
            try await performDeactivationTransaction(id)
        } catch {
            reportOperationError(error)
        }
    }

    func toggleActivation(_ id: String) async {
        if isNodeActivated(id) {
            await deactivateConfiguration(id)
        } else {
            await activateConfiguration(id)
        }
    }

    func performActivationTransaction(_ id: String) async throws {
        guard let config = configurations.first(where: { $0.id == id }) else {
            throw ProxyRuntimeError.configurationNotFound
        }

        let isCodex = config.nodeType.isCodex

        // Codex 全局代理开着时，节点列表的「接入」就是热切换上游，不要抛 Claude 文案、也不要再写一份直连 config.toml。
        if isCodex, GlobalProxyManager.codex.isEnabled {
            try await switchCodexGlobalProxyRoute(to: id)
            return
        }
        // Claude Code 由 Code 网关接管时，禁止再直连写 settings.json。
        if !isCodex, GlobalProxyManager.claude.isEnabled {
            throw ProxyRuntimeError.managedByCodeGateway
        }

        if activatedId(isCodex: isCodex) == id {
            return
        }

        let wasProxyOnly = proxyOnlyRunningIds.contains(id)

        // 只停用同家族的前一个激活节点；另一家族节点保持激活。
        let previousActiveConfig = activatedId(isCodex: isCodex).flatMap { currentId in
            configurations.first(where: { $0.id == currentId })
        }

        if let previousActiveConfig {
            try await deactivateRuntime(for: previousActiveConfig)
        }

        do {
            try await activateRuntime(for: config)
            proxyOnlyRunningIds.remove(id)
            saveProxyOnlyIds()
            do {
                try persistActivationSelection(config.id, touchLastUsedAt: true, isCodex: isCodex)
            } catch {
                do {
                    try await deactivateRuntime(for: config)
                } catch {
                    proxyRuntimeLog.error("Failed to roll back runtime for newly activated node \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
                }
                if wasProxyOnly {
                    proxyOnlyRunningIds.insert(id)
                    saveProxyOnlyIds()
                }
                if let previousActiveConfig {
                    do {
                        try await activateRuntime(for: previousActiveConfig)
                    } catch {
                        proxyRuntimeLog.error("Failed to restore previous node \(previousActiveConfig.name, privacy: .public) after persistence failure: \(String(describing: error), privacy: .public)")
                    }
                }
                throw error
            }
        } catch {
            if wasProxyOnly {
                proxyOnlyRunningIds.insert(id)
                saveProxyOnlyIds()
            }
            if let previousActiveConfig {
                do {
                    try await activateRuntime(for: previousActiveConfig)
                } catch {
                    proxyRuntimeLog.error("Failed to restore previous node \(previousActiveConfig.name, privacy: .public) after activation failure: \(String(describing: error), privacy: .public)")
                }
            }
            throw error
        }

        // 互斥（代理→账号方向）：Codex 代理接管 config.toml 后，把订阅账号标记为未激活。
        if isCodex {
            ProviderActivationManager.shared.markCodexSubscriptionInactiveForProxy()
        }

        proxyRuntimeLog.info("Node activated: \(config.name, privacy: .public)")
        proxyRuntimeRestartAttempts.removeValue(forKey: config.id)
        proxyRuntimeDownConfigIds.remove(config.id)
    }

    func performDeactivationTransaction(_ id: String) async throws {
        guard let config = configurations.first(where: { $0.id == id }) else {
            return
        }
        let isCodex = config.nodeType.isCodex
        guard activatedId(isCodex: isCodex) == id else {
            return
        }

        try await deactivateRuntime(for: config)

        do {
            try persistActivationSelection(nil, touchLastUsedAt: false, isCodex: isCodex)
        } catch {
            do {
                try await activateRuntime(for: config)
            } catch {
                proxyRuntimeLog.error("Failed to restore node \(config.name, privacy: .public) after deactivation persistence failure: \(String(describing: error), privacy: .public)")
            }
            throw error
        }

        proxyRuntimeLog.info("Node deactivated: \(config.name, privacy: .public)")
        proxyRuntimeRestartAttempts.removeValue(forKey: config.id)
        proxyRuntimeDownConfigIds.remove(config.id)
    }

    func persistActivationSelection(_ activeId: String?, touchLastUsedAt: Bool, isCodex: Bool) throws {
        let now = touchLastUsedAt ? Date() : nil

        // 只更新本家族的激活轨道，保留另一家族的激活态。
        if isCodex {
            activatedCodexConfigId = activeId
        } else {
            activatedConfigId = activeId
        }

        // isEnabled 反映「任一轨道处于激活」，兼顾 Codex 与 Claude 同时激活。
        let activeSet = Set([activatedConfigId, activatedCodexConfigId].compactMap { $0 })
        for index in configurations.indices {
            let isActive = activeSet.contains(configurations[index].id)
            configurations[index].isEnabled = isActive
            if configurations[index].id == activeId, let now {
                configurations[index].lastUsedAt = now
            }
        }

        if let activeId, touchLastUsedAt, let now,
           var profile = profileStore.profile(for: activeId) {
            profile.metadata.lastUsedAt = now
            profileStore.save(profile)
        }

        if isCodex {
            saveActivatedCodexId()
        } else {
            saveActivatedId()
        }
    }

    /// 全局代理运行中：把 Codex 流量切到指定节点（不改端口、不重写 CLI 入口）。
    func switchCodexGlobalProxyRoute(to id: String) async throws {
        let gateway = GlobalProxyManager.codex
        if gateway.activeNodeId == id, gateway.isEnabled { return }
        let switched = await gateway.switchActiveNode(to: id)
        if let failure = gateway.operationError {
            throw ProxyRuntimeError.proxyStartFailed(failure)
        }
        guard switched, gateway.activeNodeId == id, gateway.isEnabled else {
            throw ProxyRuntimeError.proxyStartFailed(
                AppSettings.shared.t(
                    "The Codex Gateway is busy. Try switching the node again.",
                    "Codex Gateway 正忙，请重新切换节点。"
                )
            )
        }
    }

    func setOperationInProgress(_ ids: Set<String>, isActive: Bool) {
        if isActive {
            operationInProgressConfigIds.formUnion(ids)
        } else {
            operationInProgressConfigIds.subtract(ids)
        }
    }

    func isOperationInProgress(_ configId: String) -> Bool {
        operationInProgressConfigIds.contains(configId)
    }

    func reportOperationError(_ error: Error) {
        let redactedMessage = SensitiveDataRedactor.redactedMessage(for: error)
        operationErrorMessage = redactedMessage
        proxyRuntimeLog.error("Proxy operation failed: \(redactedMessage, privacy: .public)")
    }

    func logPersistenceError(_ action: String, error: Error) {
        proxyPersistenceLog.error("Failed to \(action, privacy: .public): \(String(describing: error), privacy: .public)")
    }
}
