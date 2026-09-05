import XCTest
import Foundation
@testable import QuotaBackend

// Codex 两轨用量统计测试（与「代理归档 + JSONL 非代理轨」架构对齐）：
// - 非代理轨：JSONL 非代理行「仅统计 token、成本恒 0」，模型名带 " (Non-Proxy)" 标签；
//   token 用量今天之前冻结、今天重算（删本地日志后历史用量不丢）。
// - 代理轨：读 proxy-usage-codex 永久归档，成本逐条冻结，模型名带 " (Proxy)" 标签。
// - JSONL 里的代理行被丢弃（避免与代理归档双计）。
final class CodexCostProviderTests: XCTestCase {

    // MARK: - 非代理轨：仅统计 token、成本恒 0 + (Non-Proxy) 标签

    func testNonProxyTrackCountsTokensOnlyAndTagsNonProxy() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()

        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let ts1 = SharedFormatters.iso8601String(from: now.addingTimeInterval(-60))
        let ts2 = SharedFormatters.iso8601String(from: now)
        try writeJSONLines([
            ["type": "session_meta", "timestamp": ts1, "payload": ["id": "session-1"]],
            ["type": "turn_context", "timestamp": ts1, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(ts1, input: 100, cached: 40, output: 20),
            tokenCountLine(ts2, input: 160, cached: 50, output: 70)
        ], to: sessionDir.appendingPathComponent("session-1.jsonl"))

        let provider = makeProvider(home: tempRoot)
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        // net input = 160 - 50(cached) = 110, cacheRead 50, output 70 → total 230
        XCTAssertEqual(usage.extra["overall.totalTokens"]?.value as? Int, 230)
        XCTAssertEqual(usage.source?.type, "codex-proxy-non-proxy")
        XCTAssertEqual(summary.providerId, "codex-cost")
        XCTAssertEqual(summary.category, "local-cost")
        XCTAssertEqual(summary.costSummary?.overall?.tokens, 230)

        let model = try XCTUnwrap(summary.costSummary?.modelBreakdownOverall?.first)
        XCTAssertEqual(model.model, "gpt-5.4 (Non-Proxy)")
        XCTAssertEqual(model.inputTokens, 110)
        XCTAssertEqual(model.cacheReadTokens, 50)
        XCTAssertEqual(model.outputTokens, 70)
        let timelinePoint = try XCTUnwrap(summary.costSummary?.modelTimelines?.first?.daily.last)
        XCTAssertEqual(timelinePoint.inputTokens, 110)
        XCTAssertEqual(timelinePoint.cacheReadTokens, 50)
        XCTAssertEqual(timelinePoint.outputTokens, 70)

        // 非代理轨不监控价格：成本恒 0，且非代理模型不算「未定价」。
        XCTAssertEqual(summary.costSummary?.overall?.usd, 0)
        XCTAssertEqual(model.estimatedCostUsd, 0)
        XCTAssertEqual(extraInt(usage, "overall.nonProxy.totalTokens"), 230)
        XCTAssertEqual(extraInt(usage, "overall.proxy.totalTokens"), 0)
        XCTAssertNil(summary.unpricedModels)
    }

    func testNonProxyTrackHasZeroCostAndIsNeverUnpriced() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let ts = SharedFormatters.iso8601String(from: now)
        try writeJSONLines([
            ["type": "session_meta", "timestamp": ts, "payload": ["id": "session-sub"]],
            ["type": "turn_context", "timestamp": ts, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(ts, input: 100, cached: 0, output: 20)
        ], to: sessionDir.appendingPathComponent("session-sub.jsonl"))

        let provider = makeProvider(home: tempRoot)
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        // 非代理轨不监控价格 → 成本 0，且不应进入「未定价」集合。
        XCTAssertEqual(summary.costSummary?.overall?.usd, 0)
        XCTAssertNil(summary.unpricedModels)
        XCTAssertEqual(summary.costSummary?.modelBreakdownOverall?.first?.model, "gpt-5.4 (Non-Proxy)")
    }

    func testSubtractsInheritedTotalsForForkedCodexSessions() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let parentTs = SharedFormatters.iso8601String(from: now.addingTimeInterval(-120))
        let childTs = SharedFormatters.iso8601String(from: now.addingTimeInterval(-60))

        try writeJSONLines([
            ["type": "session_meta", "timestamp": parentTs, "payload": ["id": "parent-session"]],
            ["type": "turn_context", "timestamp": parentTs, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(parentTs, input: 100, cached: 40, output: 20)
        ], to: sessionDir.appendingPathComponent("parent.jsonl"))

        try writeJSONLines([
            ["type": "session_meta", "timestamp": childTs, "payload": [
                "id": "child-session",
                "forked_from_id": "parent-session",
                "timestamp": childTs
            ]],
            ["type": "turn_context", "timestamp": childTs, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(childTs, input: 130, cached: 50, output: 30)
        ], to: sessionDir.appendingPathComponent("child.jsonl"))

        let provider = makeProvider(home: tempRoot)
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        XCTAssertEqual(summary.costSummary?.overall?.tokens, 160)
        let breakdown = try XCTUnwrap(summary.costSummary?.modelBreakdownOverall?.first)
        XCTAssertEqual(breakdown.model, "gpt-5.4 (Non-Proxy)")
        XCTAssertEqual(breakdown.inputTokens, 80)
        XCTAssertEqual(breakdown.cacheReadTokens, 50)
        XCTAssertEqual(breakdown.outputTokens, 30)
    }

    func testIncludesAllModelsWhenMultipleRolloutsShareSessionId() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let sharedSessionId = "shared-task-session"
        let solTs = SharedFormatters.iso8601String(from: now.addingTimeInterval(-120))
        let lunaTs = SharedFormatters.iso8601String(from: now.addingTimeInterval(-60))

        // Lexicographically first file only contains Sol; a later rollout adds Luna.
        try writeJSONLines([
            ["type": "session_meta", "timestamp": solTs, "payload": ["id": sharedSessionId]],
            ["type": "turn_context", "timestamp": solTs, "payload": ["model": "gpt-5.6-sol"]],
            tokenCountLine(solTs, input: 100, cached: 20, output: 10)
        ], to: sessionDir.appendingPathComponent("aaa-sol-rollout.jsonl"))

        try writeJSONLines([
            ["type": "session_meta", "timestamp": lunaTs, "payload": ["id": sharedSessionId]],
            ["type": "turn_context", "timestamp": lunaTs, "payload": ["model": "gpt-5.6-luna"]],
            tokenCountLine(lunaTs, input: 50, cached: 10, output: 5)
        ], to: sessionDir.appendingPathComponent("zzz-luna-rollout.jsonl"))

        let provider = makeProvider(home: tempRoot)
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        XCTAssertEqual(summary.costSummary?.overall?.tokens, 165)
        let models = try XCTUnwrap(summary.costSummary?.modelBreakdownOverall?.map(\.model).sorted())
        XCTAssertEqual(models, ["gpt-5.6-luna (Non-Proxy)", "gpt-5.6-sol (Non-Proxy)"])

        let sol = try XCTUnwrap(summary.costSummary?.modelBreakdownOverall?.first { $0.model == "gpt-5.6-sol (Non-Proxy)" })
        XCTAssertEqual(sol.inputTokens, 80)
        XCTAssertEqual(sol.cacheReadTokens, 20)
        XCTAssertEqual(sol.outputTokens, 10)

        let luna = try XCTUnwrap(summary.costSummary?.modelBreakdownOverall?.first { $0.model == "gpt-5.6-luna (Non-Proxy)" })
        XCTAssertEqual(luna.inputTokens, 40)
        XCTAssertEqual(luna.cacheReadTokens, 10)
        XCTAssertEqual(luna.outputTokens, 5)
    }

    func testTokenCountModelOverridesPreviousTurnContext() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let ts = SharedFormatters.iso8601String(from: now)
        try writeJSONLines([
            ["type": "session_meta", "timestamp": ts, "payload": ["id": "session-model-override"]],
            ["type": "turn_context", "timestamp": ts, "payload": ["model": "gpt-5.4"]],
            [
                "type": "event_msg",
                "timestamp": ts,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "model": "gpt-5-mini",
                        "total_token_usage": ["input_tokens": 10, "cached_input_tokens": 0, "output_tokens": 5]
                    ]
                ]
            ]
        ], to: sessionDir.appendingPathComponent("session-model-override.jsonl"))

        let provider = makeProvider(home: tempRoot)
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        let models = try XCTUnwrap(summary.costSummary?.modelBreakdownOverall)
        XCTAssertEqual(models.map(\.model), ["gpt-5-mini (Non-Proxy)"])
    }

    func testParsesLastTokenUsageDeltas() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let ts = SharedFormatters.iso8601String(from: now)
        try writeJSONLines([
            ["type": "session_meta", "timestamp": ts, "payload": ["id": "session-last-token-usage"]],
            ["type": "turn_context", "timestamp": ts, "payload": ["model": "gpt-5.4"]],
            [
                "type": "event_msg",
                "timestamp": ts,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": ["input_tokens": 12, "cached_input_tokens": 4, "output_tokens": 7]
                    ]
                ]
            ]
        ], to: sessionDir.appendingPathComponent("session-last-token-usage.jsonl"))

        let provider = makeProvider(home: tempRoot)
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        XCTAssertEqual(summary.costSummary?.overall?.tokens, 19)
        let breakdown = try XCTUnwrap(summary.costSummary?.modelBreakdownOverall?.first)
        XCTAssertEqual(breakdown.inputTokens, 8)
        XCTAssertEqual(breakdown.cacheReadTokens, 4)
        XCTAssertEqual(breakdown.outputTokens, 7)
    }

    // MARK: - 代理 JSONL 行丢弃，避免双计

    func testProxyTaggedJSONLRowsAreExcludedFromNonProxyTrack() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let ts = SharedFormatters.iso8601String(from: now)
        // model_provider = aiusage-proxy → 该会话走代理归档，JSONL 行应被非代理轨丢弃。
        try writeJSONLines([
            ["type": "session_meta", "timestamp": ts, "payload": ["id": "proxy-session", "model_provider": "aiusage-proxy"]],
            ["type": "turn_context", "timestamp": ts, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(ts, input: 100, cached: 0, output: 20)
        ], to: sessionDir.appendingPathComponent("proxy-session.jsonl"))

        // 无代理归档文件 → 代理轨为空，非代理轨丢弃代理 JSONL 行后也为空 → 无任何用量。
        let provider = makeProvider(home: tempRoot)
        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected no_usage_data: proxy-tagged JSONL rows must not feed the non-proxy track")
        } catch let error as ProviderError {
            XCTAssertEqual(error.code, "no_usage_data")
        }
    }

    // MARK: - 第三方直连（非代理、无 rate_limits）计入 token

    func testThirdPartyDirectUsageCountsAsNonProxyWithoutRateLimits() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let ts = SharedFormatters.iso8601String(from: now)
        // 第三方直连 / 自定义 base_url：不依赖 rate_limits，只要不是 aiusage-proxy 就归入非代理 token 轨。
        try writeJSONLines([
            ["type": "session_meta", "timestamp": ts, "payload": ["id": "third-party", "model_provider": "openai"]],
            ["type": "turn_context", "timestamp": ts, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(ts, input: 100, cached: 0, output: 20)
        ], to: sessionDir.appendingPathComponent("third-party.jsonl"))

        let provider = makeProvider(home: tempRoot)
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        XCTAssertEqual(extraInt(usage, "overall.nonProxy.totalTokens"), 120)
        XCTAssertEqual(extraDouble(usage, "overall.nonProxy.estimatedCostUsd") ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(summary.costSummary?.overall?.tokens, 120)
        XCTAssertEqual(summary.costSummary?.overall?.usd, 0)
        XCTAssertEqual(summary.costSummary?.modelBreakdownOverall?.first?.model, "gpt-5.4 (Non-Proxy)")
    }

    func testSameOpenAIThreadCanMixAccountAndProxyWithoutDoubleCounting() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let day = utcDayKey(now)
        let timestamp = SharedFormatters.iso8601String(from: now)
        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try writeJSONLines([
            ["type": "session_meta", "timestamp": timestamp, "payload": [
                "id": "mixed-session", "model_provider": "openai",
            ]],
            ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(timestamp, input: 160, cached: 40, output: 50),
        ], to: sessionDir.appendingPathComponent("mixed-session.jsonl"))
        try writeProxyApiArchive(home: tempRoot, days: [
            day: ["gpt-5.4": [
                "inputTokens": 30, "outputTokens": 20,
                "cacheReadTokens": 10, "cacheCreateTokens": 0,
                "costUSD": 0.25, "requests": 1,
                "sessions": [
                    "mixed-session": [
                        "gpt-5.4": [
                            "inputTokens": 30, "outputTokens": 20,
                            "cacheReadTokens": 10, "cacheCreateTokens": 0,
                        ],
                    ],
                ],
            ]],
        ])

        let provider = makeProvider(home: tempRoot)
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        XCTAssertEqual(extraInt(usage, "overall.proxy.totalTokens"), 60)
        XCTAssertEqual(extraInt(usage, "overall.nonProxy.totalTokens"), 150)
        XCTAssertEqual(summary.costSummary?.overall?.tokens, 210)
        let models = try XCTUnwrap(summary.costSummary?.modelBreakdownOverall)
        let account = try XCTUnwrap(models.first { $0.model == "gpt-5.4 (Non-Proxy)" })
        XCTAssertEqual(account.inputTokens, 90)
        XCTAssertEqual(account.cacheReadTokens, 30)
        XCTAssertEqual(account.outputTokens, 30)
    }

    func testProxyCoverageChangeInvalidatesUnchangedJSONLCache() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let day = utcDayKey(now)
        let timestamp = SharedFormatters.iso8601String(from: now)
        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try writeJSONLines([
            ["type": "session_meta", "timestamp": timestamp, "payload": [
                "id": "cache-session", "model_provider": "openai",
            ]],
            ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(timestamp, input: 100, cached: 0, output: 20),
        ], to: sessionDir.appendingPathComponent("cache-session.jsonl"))

        let provider = makeProvider(home: tempRoot)
        let first = try await provider.fetchUsage()
        XCTAssertEqual(extraInt(first, "overall.nonProxy.totalTokens"), 120)

        try writeProxyApiArchive(home: tempRoot, days: [
            day: ["gpt-5.4": [
                "inputTokens": 30, "outputTokens": 20,
                "cacheReadTokens": 0, "cacheCreateTokens": 0,
                "costUSD": 0.1, "requests": 1,
                "sessions": [
                    "cache-session": [
                        "gpt-5.4": [
                            "inputTokens": 30, "outputTokens": 20,
                            "cacheReadTokens": 0, "cacheCreateTokens": 0,
                        ],
                    ],
                ],
            ]],
        ])

        let second = try await provider.fetchUsage()
        XCTAssertEqual(extraInt(second, "overall.proxy.totalTokens"), 50)
        XCTAssertEqual(extraInt(second, "overall.nonProxy.totalTokens"), 70)
        XCTAssertEqual(extraInt(second, "overall.totalTokens"), 120)
    }

    func testMigratedLegacyProxySessionKeepsHistoricalRowsOutOfNonProxyTrack() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date().addingTimeInterval(-60)
        let day = utcDayKey(now)
        let timestamp = SharedFormatters.iso8601String(from: now)
        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try writeJSONLines([
            ["type": "session_meta", "timestamp": timestamp, "payload": [
                "id": "legacy-proxy-session", "model_provider": "aiusage-proxy",
            ]],
            ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(timestamp, input: 100, cached: 10, output: 20),
        ], to: sessionDir.appendingPathComponent("legacy-proxy-session.jsonl"))
        try writeProxyApiArchive(home: tempRoot, days: [
            day: ["gpt-5.4": [
                "inputTokens": 90, "outputTokens": 20,
                "cacheReadTokens": 10, "cacheCreateTokens": 0,
                "costUSD": 0.2, "requests": 1,
            ]],
        ])

        XCTAssertEqual(
            try CodexSessionProviderMigrator.migrate(homeDirectory: tempRoot.path).migratedFiles,
            1
        )
        let provider = makeProvider(home: tempRoot)
        let usage = try await provider.fetchUsage()

        XCTAssertEqual(extraInt(usage, "overall.proxy.totalTokens"), 120)
        XCTAssertEqual(extraInt(usage, "overall.nonProxy.totalTokens"), 0)
        XCTAssertEqual(extraInt(usage, "overall.totalTokens"), 120)
    }

    func testMigratedThreadCanContinueWithProxyThenAccountWithoutHistoricalDoubleCount() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let beforeMigration = Date().addingTimeInterval(-1)
        let sessionDir = codexSessionDirectory(in: tempRoot, for: beforeMigration)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let rollout = sessionDir.appendingPathComponent("legacy-then-mixed.jsonl")
        try writeJSONLines([
            ["type": "session_meta", "timestamp": SharedFormatters.iso8601String(from: beforeMigration), "payload": [
                "id": "legacy-then-mixed", "model_provider": "aiusage-proxy",
            ]],
            ["type": "turn_context", "timestamp": SharedFormatters.iso8601String(from: beforeMigration), "payload": ["model": "gpt-5.4"]],
            tokenCountLine(
                SharedFormatters.iso8601String(from: beforeMigration),
                input: 100,
                cached: 10,
                output: 20
            ),
        ], to: rollout)

        XCTAssertEqual(
            try CodexSessionProviderMigrator.migrate(homeDirectory: tempRoot.path).migratedFiles,
            1
        )

        let proxyTurn = Date().addingTimeInterval(1)
        let accountTurn = Date().addingTimeInterval(2)
        try appendJSONLines([
            tokenCountLine(
                SharedFormatters.iso8601String(from: proxyTurn),
                input: 160,
                cached: 20,
                output: 30
            ),
            tokenCountLine(
                SharedFormatters.iso8601String(from: accountTurn),
                input: 210,
                cached: 20,
                output: 50
            ),
        ], to: rollout)

        var archiveDays: [String: [String: [String: Any]]] = [:]
        func addProxyCoverage(day: String, input: Int, cached: Int, output: Int) {
            var model = archiveDays[day]?["gpt-5.4"] ?? [
                "inputTokens": 0, "outputTokens": 0,
                "cacheReadTokens": 0, "cacheCreateTokens": 0,
                "costUSD": 0.0, "requests": 0,
                "sessions": [String: Any](),
            ]
            model["inputTokens"] = (model["inputTokens"] as? Int ?? 0) + input
            model["outputTokens"] = (model["outputTokens"] as? Int ?? 0) + output
            model["cacheReadTokens"] = (model["cacheReadTokens"] as? Int ?? 0) + cached
            model["requests"] = (model["requests"] as? Int ?? 0) + 1
            var sessions = model["sessions"] as? [String: Any] ?? [:]
            var models = sessions["legacy-then-mixed"] as? [String: Any] ?? [:]
            var usage = models["gpt-5.4"] as? [String: Any] ?? [
                "inputTokens": 0, "outputTokens": 0,
                "cacheReadTokens": 0, "cacheCreateTokens": 0,
            ]
            usage["inputTokens"] = (usage["inputTokens"] as? Int ?? 0) + input
            usage["outputTokens"] = (usage["outputTokens"] as? Int ?? 0) + output
            usage["cacheReadTokens"] = (usage["cacheReadTokens"] as? Int ?? 0) + cached
            models["gpt-5.4"] = usage
            sessions["legacy-then-mixed"] = models
            model["sessions"] = sessions
            archiveDays[day, default: [:]]["gpt-5.4"] = model
        }
        // 迁移前一轮与迁移后的首轮均走代理；最后一轮切回账号。
        addProxyCoverage(day: utcDayKey(beforeMigration), input: 90, cached: 10, output: 20)
        addProxyCoverage(day: utcDayKey(proxyTurn), input: 50, cached: 10, output: 10)
        try writeProxyApiArchive(home: tempRoot, days: archiveDays)

        let usage = try await makeProvider(home: tempRoot).fetchUsage()
        XCTAssertEqual(extraInt(usage, "overall.proxy.totalTokens"), 190)
        XCTAssertEqual(extraInt(usage, "overall.nonProxy.totalTokens"), 70)
        XCTAssertEqual(extraInt(usage, "overall.totalTokens"), 260)
    }

    // MARK: - 代理轨：读代理归档 + 与非代理轨合并

    func testProxyTrackFromArchiveMergesWithNonProxyTrack() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let todayKey = utcDayKey(now)

        // 代理轨：代理归档（成本冻结 0.5），模型 gpt-5.4，今天。
        try writeProxyApiArchive(home: tempRoot, days: [
            todayKey: ["gpt-5.4": [
                "inputTokens": 300, "outputTokens": 100,
                "cacheReadTokens": 20, "cacheCreateTokens": 10,
                "costUSD": 0.5, "requests": 2
            ]]
        ])

        // 非代理轨：JSONL 非代理行仅统计 token（不监控价格，成本恒 0）。
        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let ts = SharedFormatters.iso8601String(from: now)
        try writeJSONLines([
            ["type": "session_meta", "timestamp": ts, "payload": ["id": "sub-session"]],
            ["type": "turn_context", "timestamp": ts, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(ts, input: 1_000_000, cached: 0, output: 0)
        ], to: sessionDir.appendingPathComponent("sub-session.jsonl"))

        let provider = makeProvider(home: tempRoot)
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        XCTAssertEqual(extraInt(usage, "overall.proxy.totalTokens"), 430)
        XCTAssertEqual(extraDouble(usage, "overall.proxy.estimatedCostUsd") ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(extraInt(usage, "overall.nonProxy.totalTokens"), 1_000_000)
        XCTAssertEqual(extraDouble(usage, "overall.nonProxy.estimatedCostUsd") ?? -1, 0.0, accuracy: 1e-9)

        // 合计 token = 两轨之和；合计成本 = 仅代理（非代理不监控价格）。
        XCTAssertEqual(summary.costSummary?.overall?.tokens, 1_000_430)
        XCTAssertEqual(summary.costSummary?.overall?.usd ?? -1, 0.5, accuracy: 1e-9)

        let models = try XCTUnwrap(summary.costSummary?.modelBreakdownOverall)
        let proxy = try XCTUnwrap(models.first { $0.model == "gpt-5.4 (Proxy)" })
        XCTAssertEqual(proxy.totalTokens, 430)
        XCTAssertEqual(proxy.inputTokens, 300)
        XCTAssertEqual(proxy.outputTokens, 100)
        XCTAssertEqual(proxy.cacheReadTokens, 20)
        XCTAssertEqual(proxy.cacheCreateTokens, 10)
        XCTAssertEqual(proxy.estimatedCostUsd, 0.5, accuracy: 1e-9)
        let nonProxy = try XCTUnwrap(models.first { $0.model == "gpt-5.4 (Non-Proxy)" })
        XCTAssertEqual(nonProxy.totalTokens, 1_000_000)
        XCTAssertEqual(nonProxy.estimatedCostUsd, 0.0, accuracy: 1e-9)

        let proxyTimeline = try XCTUnwrap(summary.costSummary?.modelTimelines?.first { $0.model == "gpt-5.4 (Proxy)" })
        let proxyDay = try XCTUnwrap(proxyTimeline.daily.last)
        XCTAssertEqual(proxyDay.inputTokens, 300)
        XCTAssertEqual(proxyDay.outputTokens, 100)
        XCTAssertEqual(proxyDay.cacheReadTokens, 20)
        XCTAssertEqual(proxyDay.cacheCreateTokens, 10)
    }

    func testProxyTrackZeroCostModelMarkedUnpriced() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let todayKey = utcDayKey(now)
        try writeProxyApiArchive(home: tempRoot, days: [
            todayKey: ["gpt-5.4": [
                "inputTokens": 300, "outputTokens": 100,
                "cacheReadTokens": 0, "cacheCreateTokens": 0,
                "costUSD": 0.0, "requests": 1
            ]]
        ])

        let provider = makeProvider(home: tempRoot)
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        XCTAssertEqual(summary.costSummary?.overall?.tokens, 400)
        XCTAssertEqual(summary.costSummary?.overall?.usd, 0)
        XCTAssertEqual(summary.unpricedModels, ["gpt-5.4 (Proxy)"])
    }

    func testProxyTrackZeroCostWithResolvedPricingIsNotUnpriced() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let todayKey = utcDayKey(now)
        try writeProxyApiArchive(home: tempRoot, days: [
            todayKey: ["gpt-5.4": [
                "inputTokens": 300, "outputTokens": 100,
                "cacheReadTokens": 0, "cacheCreateTokens": 0,
                "costUSD": 0.0, "requests": 1,
                "pricingResolvedRequests": 1
            ]]
        ])

        let provider = makeProvider(home: tempRoot)
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        XCTAssertEqual(summary.costSummary?.overall?.tokens, 400)
        XCTAssertEqual(summary.costSummary?.overall?.usd, 0)
        XCTAssertNil(summary.unpricedModels)
    }

    // MARK: - 非代理轨冻结：今天之前冻结、今天重算（删本地日志后历史用量不丢）

    func testNonProxyPastDayTokensStayFrozenAfterLogDeletion() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)

        // 昨天 1,000,000 net；今天 2,000,000 net。
        let yDir = codexSessionDirectory(in: tempRoot, for: yesterday)
        try FileManager.default.createDirectory(at: yDir, withIntermediateDirectories: true)
        let yts = SharedFormatters.iso8601String(from: yesterday)
        let yesterdayFile = yDir.appendingPathComponent("yesterday.jsonl")
        try writeJSONLines([
            ["type": "session_meta", "timestamp": yts, "payload": ["id": "yesterday-session"]],
            ["type": "turn_context", "timestamp": yts, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(yts, input: 1_000_000, cached: 0, output: 0)
        ], to: yesterdayFile)

        let tDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: tDir, withIntermediateDirectories: true)
        let tts = SharedFormatters.iso8601String(from: now)
        try writeJSONLines([
            ["type": "session_meta", "timestamp": tts, "payload": ["id": "today-session"]],
            ["type": "turn_context", "timestamp": tts, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(tts, input: 2_000_000, cached: 0, output: 0)
        ], to: tDir.appendingPathComponent("today.jsonl"))

        // 首跑：昨天 1M、今天 2M、合计 3M（非代理 token；成本恒 0）。
        let provider = makeProvider(home: tempRoot)
        let first = try await provider.fetchUsage()
        let firstSummary = UsageNormalizer.normalize(provider: provider, usage: first)
        XCTAssertEqual(firstSummary.costSummary?.today?.tokens, 2_000_000)
        XCTAssertEqual(firstSummary.costSummary?.overall?.tokens, 3_000_000)
        XCTAssertEqual(firstSummary.costSummary?.overall?.usd, 0)

        // 删除昨天的本地日志后重跑：昨天已冻结进归档 → 历史用量不丢，合计仍含昨天 1M。
        try FileManager.default.removeItem(at: yesterdayFile)
        let second = try await provider.fetchUsage()
        let secondSummary = UsageNormalizer.normalize(provider: provider, usage: second)
        XCTAssertEqual(secondSummary.costSummary?.today?.tokens, 2_000_000)
        XCTAssertEqual(secondSummary.costSummary?.overall?.tokens, 3_000_000)
    }

    func testFullHistoryImportFreezesNonProxyArchivePerHome() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let oldDate = Date().addingTimeInterval(-60 * 86_400)
        let sessionDir = codexSessionDirectory(in: tempRoot, for: oldDate)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let ts = SharedFormatters.iso8601String(from: oldDate)
        try writeJSONLines([
            ["type": "session_meta", "timestamp": ts, "payload": ["id": "old-session"]],
            ["type": "turn_context", "timestamp": ts, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(ts, input: 42, cached: 0, output: 8)
        ], to: sessionDir.appendingPathComponent("old-session.jsonl"))

        let provider = makeProvider(home: tempRoot)
        let initiallyNeedsImport = await provider.needsFullHistoryImport()
        XCTAssertTrue(initiallyNeedsImport)

        // 另一个 home 的归档相互独立，互不消费全量请求。
        let otherHome = tempRoot.appendingPathComponent("other-home", isDirectory: true)
        let otherProvider = makeProvider(home: otherHome)
        let otherNeedsImport = await otherProvider.needsFullHistoryImport()
        XCTAssertTrue(otherNeedsImport)

        // 首跑触发全量导入：冻结 60 天前的非代理日（窗口外，必须靠全量扫描）。
        let usage = try await provider.fetchUsage()
        XCTAssertEqual(usage.extra["overall.totalTokens"]?.value as? Int, 50)

        let archiveURL = CodexNonProxyUsageArchiveStore.fileURL(homeDirectory: tempRoot.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))

        let stillNeedsImport = await provider.needsFullHistoryImport()
        XCTAssertFalse(stillNeedsImport)
    }

    func testLegacySubscriptionArchiveMigratesToNonProxyArchive() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let archivedDayKey = utcDayKey(now.addingTimeInterval(-86_400))
        let legacyURL = CodexNonProxyUsageArchiveStore.legacyFileURL(homeDirectory: tempRoot.path, version: 1)
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacyPayload: [String: Any] = [
            "version": 1,
            "updatedAt": SharedFormatters.iso8601String(from: now),
            "fullHistoryImportedAt": SharedFormatters.iso8601String(from: now),
            "days": [
                archivedDayKey: [
                    "usageRows": 2,
                    "totalTokens": 1049,
                    "estimatedCostUsd": 9.9,
                    "models": [
                        "gpt-5.4 (Sub)": [
                            "model": "gpt-5.4 (Sub)",
                            "totalTokens": 50,
                            "inputTokens": 42,
                            "outputTokens": 8,
                            "cacheReadTokens": 0,
                            "estimatedCostUsd": 9.9
                        ],
                        "gpt-5.4 (API)": [
                            "model": "gpt-5.4 (API)",
                            "totalTokens": 999,
                            "inputTokens": 999,
                            "outputTokens": 0,
                            "cacheReadTokens": 0,
                            "estimatedCostUsd": 1.0
                        ]
                    ]
                ]
            ]
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyPayload, options: [.sortedKeys])
        try legacyData.write(to: legacyURL, options: .atomic)

        let provider = makeProvider(home: tempRoot)
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        XCTAssertEqual(extraInt(usage, "overall.nonProxy.totalTokens"), 50)
        XCTAssertEqual(extraDouble(usage, "overall.nonProxy.estimatedCostUsd") ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(summary.costSummary?.overall?.usd ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(summary.costSummary?.modelBreakdownOverall?.first?.model, "gpt-5.4 (Non-Proxy)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: CodexNonProxyUsageArchiveStore.fileURL(homeDirectory: tempRoot.path).path))
    }

    func testNonProxyTodayArchiveClearsWhenTodayLogsDisappear() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let ts = SharedFormatters.iso8601String(from: now)
        let todayFile = sessionDir.appendingPathComponent("today.jsonl")
        try writeJSONLines([
            ["type": "session_meta", "timestamp": ts, "payload": ["id": "today-session"]],
            ["type": "turn_context", "timestamp": ts, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(ts, input: 100, cached: 0, output: 20)
        ], to: todayFile)

        let provider = makeProvider(home: tempRoot)
        let first = try await provider.fetchUsage()
        XCTAssertEqual(extraInt(first, "today.totalTokens"), 120)

        try FileManager.default.removeItem(at: todayFile)

        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected no_usage_data after today's non-proxy logs disappear")
        } catch let error as ProviderError {
            XCTAssertEqual(error.code, "no_usage_data")
        }
    }

    // MARK: - Helpers

    private func makeProvider(home: URL) -> CodexCostProvider {
        CodexCostProvider(
            homeDirectory: home.path,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            environment: [:]
        )
    }

    private func extraInt(_ usage: ProviderUsage, _ key: String) -> Int? {
        switch usage.extra[key]?.value {
        case let value as Int: return value
        case let value as Double: return Int(value)
        default: return nil
        }
    }

    private func extraDouble(_ usage: ProviderUsage, _ key: String) -> Double? {
        switch usage.extra[key]?.value {
        case let value as Double: return value
        case let value as Int: return Double(value)
        default: return nil
        }
    }

    /// Codex JSONL 的 token_count 事件：不带 rate_limits，验证非代理统计不依赖该字段。
    private func tokenCountLine(_ timestamp: String, input: Int, cached: Int, output: Int) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": cached,
                        "output_tokens": output
                    ]
                ]
            ]
        ]
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-codex-cost-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func codexSessionDirectory(in tempRoot: URL, for date: Date) -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return tempRoot
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", comps.year ?? 1970), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.day ?? 1), isDirectory: true)
    }

    private func utcDayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    private func writeJSONLines(_ objects: [[String: Any]], to url: URL) throws {
        let lines = try objects.map { object -> String in
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(data: data, encoding: .utf8)!
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func appendJSONLines(_ objects: [[String: Any]], to url: URL) throws {
        let lines = try objects.map { object -> String in
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(data: data, encoding: .utf8)!
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.joined(separator: "\n").appending("\n").utf8))
    }

    private func writeProxyApiArchive(home: URL, days: [String: [String: [String: Any]]]) throws {
        let dir = home.appendingPathComponent(".config/aiusage/usage-archive", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dayDTOs: [String: Any] = [:]
        for (day, models) in days {
            dayDTOs[day] = ["models": models]
        }
        let payload: [String: Any] = [
            "version": 1,
            "updatedAt": SharedFormatters.iso8601String(from: Date()),
            "days": dayDTOs
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: dir.appendingPathComponent("proxy-usage-codex-v1.json"), options: .atomic)
    }
}
