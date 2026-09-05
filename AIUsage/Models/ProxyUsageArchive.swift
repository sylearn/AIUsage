import Foundation
import os.log

// MARK: - Proxy Usage Archive
// 代理日志的「永久每日用量归档」：按 家族 → 日 → 上游模型聚合，并在模型桶内保留
// client surface（Code / Desktop / Science）维度。总量字段保持原结构，旧读取器可直接忽略新增维度。
// 成本逐条冻结——直接累加 ProxyRequestLog.estimatedCostUSD（该值在请求发生时已用当时节点定价算好），
// 因此同一模型在不同节点不同价不会冲突，改价也不影响已入档的历史。
//
// 设计要点：
// - 原始代理日志（~/.config/aiusage/proxy-logs/）可按保留期裁剪以省空间，
//   但本归档的每日聚合永不丢失，是热力图 / 用量统计的真相源。
// - 折叠语义为「整日替换」：保留期窗口内的日期每个持久化周期都用 recentLogs 重算覆盖（幂等，
//   因为冻结成本是确定性求和），窗口外的旧日期保持上次冻结值不动——杜绝刷新时线性膨胀。
//
// 数据来源: ProxyViewModel.recentLogs（经 ProxyViewModel+UsageArchive 折叠写入）
// 持久化:   ~/.config/aiusage/usage-archive/proxy-usage-<family>-v<version>.json

private let proxyUsageArchiveLog = Logger(subsystem: "com.aiusage.desktop", category: "ProxyUsageArchive")

enum ProxyUsageFamily: String, CaseIterable, Sendable {
    case claude
    case codex
    /// OpenCode 全局统一代理轨：用量/成本来自代理日志（按激活节点定价冻结），
    /// 与 opencode.db 互斥（db 侧已排除全局 provider，避免双计）。
    case opencode
}

/// 一个产品面的冻结用量。它是模型总桶的可选细分，不参与旧版总量读取，
/// 因而可以在不迁移现有 v1 归档的前提下逐步补齐来源维度。
struct ProxyUsageSurfaceAgg: Codable, Sendable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreateTokens: Int = 0
    var costUSD: Double = 0
    var requests: Int = 0

    mutating func add(_ log: ProxyRequestLog) {
        inputTokens += log.tokensInput
        outputTokens += log.tokensOutput
        cacheReadTokens += log.tokensCacheRead
        cacheCreateTokens += log.tokensCacheCreation
        costUSD += log.estimatedCostUSD
        requests += 1
    }
}

/// Codex JSONL 去重所需的最小路由凭据。只保存 token，不参与代理总量求和。
struct ProxyUsageSessionTokenAgg: Codable, Sendable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreateTokens: Int = 0

    mutating func add(_ log: ProxyRequestLog) {
        inputTokens += log.tokensInput
        outputTokens += log.tokensOutput
        cacheReadTokens += log.tokensCacheRead
        cacheCreateTokens += log.tokensCacheCreation
    }
}

struct ProxyUsageModelAgg: Codable, Sendable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreateTokens: Int = 0
    var costUSD: Double = 0
    var requests: Int = 0
    var pricingResolvedRequests: Int = 0
    var surfaces: [String: ProxyUsageSurfaceAgg] = [:]
    /// session/conversation id → Codex 请求模型 → token。用于同一会话混合账号与代理时去重。
    var sessions: [String: [String: ProxyUsageSessionTokenAgg]] = [:]

    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreateTokens }

    init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreateTokens: Int = 0,
        costUSD: Double = 0,
        requests: Int = 0,
        pricingResolvedRequests: Int = 0,
        surfaces: [String: ProxyUsageSurfaceAgg] = [:],
        sessions: [String: [String: ProxyUsageSessionTokenAgg]] = [:]
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreateTokens = cacheCreateTokens
        self.costUSD = costUSD
        self.requests = requests
        self.pricingResolvedRequests = pricingResolvedRequests
        self.surfaces = surfaces
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens
        case outputTokens
        case cacheReadTokens
        case cacheCreateTokens
        case costUSD
        case requests
        case pricingResolvedRequests
        case surfaces
        case sessions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        cacheCreateTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreateTokens) ?? 0
        costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        requests = try c.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        pricingResolvedRequests = try c.decodeIfPresent(Int.self, forKey: .pricingResolvedRequests)
            ?? (costUSD > 0 ? requests : 0)
        surfaces = try c.decodeIfPresent([String: ProxyUsageSurfaceAgg].self, forKey: .surfaces) ?? [:]
        sessions = try c.decodeIfPresent(
            [String: [String: ProxyUsageSessionTokenAgg]].self,
            forKey: .sessions
        ) ?? [:]
    }

    mutating func add(_ log: ProxyRequestLog) {
        inputTokens += log.tokensInput
        outputTokens += log.tokensOutput
        cacheReadTokens += log.tokensCacheRead
        cacheCreateTokens += log.tokensCacheCreation
        costUSD += log.estimatedCostUSD
        requests += 1
        if log.pricingResolved {
            pricingResolvedRequests += 1
        }
        let surface = log.clientSurface?.nilIfBlank ?? "unknown"
        var surfaceAgg = surfaces[surface] ?? ProxyUsageSurfaceAgg()
        surfaceAgg.add(log)
        surfaces[surface] = surfaceAgg

        let requestedModel = log.claudeModel.nilIfBlank ?? log.upstreamModel
        let identifiers = Set([log.sessionId, log.conversationId].compactMap { $0?.nilIfBlank })
        for identifier in identifiers {
            var models = sessions[identifier] ?? [:]
            var usage = models[requestedModel] ?? ProxyUsageSessionTokenAgg()
            usage.add(log)
            models[requestedModel] = usage
            sessions[identifier] = models
        }
    }
}

struct ProxyUsageDay: Codable, Sendable {
    var models: [String: ProxyUsageModelAgg] = [:]

    var isEmpty: Bool { models.isEmpty }
}

struct ProxyUsageArchive: Codable, Sendable {
    var version: Int
    var updatedAt: String
    var days: [String: ProxyUsageDay]
}

// MARK: - Store

@MainActor
final class ProxyUsageArchiveStore {
    static let shared = ProxyUsageArchiveStore()

    static let artifactVersion = 1

    private var archives: [ProxyUsageFamily: ProxyUsageArchive] = [:]
    private var loaded: Set<ProxyUsageFamily> = []

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: Read

    /// 某家族的每日聚合（永久），供 Claude / Codex 代理轨构建 costSummary。
    func days(_ family: ProxyUsageFamily) -> [String: ProxyUsageDay] {
        loadIfNeeded(family).days
    }

    // MARK: Write

    /// 用重算后的每日桶「整日替换」归档中对应日期并持久化。
    /// 仅替换传入的（非空）日期；未传入的旧日期保持冻结值不动。
    func replaceDays(_ family: ProxyUsageFamily, days: [String: ProxyUsageDay]) {
        var archive = loadIfNeeded(family)
        var changed = false
        for (day, bucket) in days where !bucket.isEmpty {
            archive.days[day] = bucket
            changed = true
        }
        guard changed else { return }
        archive.updatedAt = Self.iso8601.string(from: Date())
        archives[family] = archive
        save(family, archive: archive)
    }

    /// 增量累加单条日志到「某日 × 上游模型」桶并持久化（用于无法整日重算的来源，如 OpenCode
    /// 全局代理——其原始日志环形封顶，故按发生即累加，跨重启不重复折叠，与 replaceDays 互斥使用）。
    func accumulate(_ family: ProxyUsageFamily, dayKey: String, model: String, log: ProxyRequestLog) {
        var archive = loadIfNeeded(family)
        var day = archive.days[dayKey] ?? ProxyUsageDay()
        var agg = day.models[model] ?? ProxyUsageModelAgg()
        agg.add(log)
        day.models[model] = agg
        archive.days[dayKey] = day
        archive.updatedAt = Self.iso8601.string(from: Date())
        archives[family] = archive
        save(family, archive: archive)
    }

    // MARK: Disk

    private func loadIfNeeded(_ family: ProxyUsageFamily) -> ProxyUsageArchive {
        if let archive = archives[family], loaded.contains(family) { return archive }
        loaded.insert(family)

        let url = Self.fileURL(family)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ProxyUsageArchive.self, from: data),
              decoded.version == Self.artifactVersion else {
            let fresh = ProxyUsageArchive(version: Self.artifactVersion, updatedAt: "", days: [:])
            archives[family] = fresh
            return fresh
        }
        archives[family] = decoded
        return decoded
    }

    /// 归档为 Sendable 值类型，编码与写盘移交持久化串行队列：
    /// 主线程只更新内存态，磁盘 IO 不再阻塞 UI；串行队列保证写入顺序。
    private func save(_ family: ProxyUsageFamily, archive: ProxyUsageArchive) {
        let url = Self.fileURL(family)
        ProxyPersistence.queue.async {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try ProxyPersistence.encoder.encode(archive)
                try data.write(to: url, options: .atomic)
            } catch {
                proxyUsageArchiveLog.warning("Failed to save proxy usage archive (\(family.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// 永久归档存放在 ~/.config/aiusage（而非 Caches，避免被系统在磁盘紧张时清理）。
    private static func fileURL(_ family: ProxyUsageFamily) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = (home as NSString).appendingPathComponent(".config/aiusage/usage-archive")
        return URL(fileURLWithPath: dir, isDirectory: true)
            .appendingPathComponent("proxy-usage-\(family.rawValue)-v\(artifactVersion).json")
    }
}
