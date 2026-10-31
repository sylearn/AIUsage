import Foundation
@testable import QuotaBackend

@main
struct CodexResetCardsRegression {
    static var assertions = 0
    static var failures = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { failures += 1; print("FAIL: \(message)") }
    }
    static func credential(_ id: String, user: String) -> AccountCredential {
        AccountCredential(id: id, providerId: "codex", authMethod: .authFile, credential: "/fixture/\(id)",
                          metadata: ["accountId": "workspace", "workspaceUserId": user])
    }
    static func result(_ credential: AccountCredential, count: Int) -> ProviderResult {
        var usage = ProviderUsage(provider: "codex", label: "Codex")
        usage.usageAccountId = "workspace"
        usage.extra["userId"] = AnyCodable(credential.metadata["workspaceUserId"]!)
        usage.codexResetCreditsAvailableCount = count
        var summary = UsageNormalizer.normalize(provider: CodexProvider(), usage: usage)
        summary.id = "codex:cred:\(credential.id)"
        summary.sourceFilePath = credential.credential
        return ProviderResult(id: summary.id, providerId: "codex", ok: true, usage: usage, summary: summary)
    }

    @MainActor static func main() async throws {
        fixtureLanguage = "zh"
        check(CodexCreditsText.full(nil) == "未提供", "Missing credit data is explicit")
        check(CodexCreditsText.full("Available") == "可用 · 数额未提供", "Availability is not a numeric balance")
        check(CodexCreditsText.full("可用") == "可用 · 数额未提供", "Legacy localized snapshots use the same wording")
        check(CodexCreditsText.full("No available credits") == "无可用积分", "Explicit no-credit flag is separate from an unknown amount")
        check(CodexCreditsText.full("0 积分") == "0 积分", "Explicit zero stays zero")
        check(CodexCreditsText.compact("42.25 积分") == "42.25", "Compact summary preserves the numeric amount")
        fixtureLanguage = "en"
        check(CodexCreditsText.full(nil) == "Not provided", "English missing data is explicit")
        check(CodexCreditsText.full("Available") == "Available · amount not provided", "English unknown amount is explicit")
        let a = credential("A", user: "a"), b = credential("B", user: "b")
        AccountCredentialStore.shared.credentials = [a, b]
        let coordinator = ProviderRefreshCoordinator()
        let oldA = result(a, count: 4), oldB = result(b, count: 7)
        let oldProviders = coordinator.localizedProviderResults(from: [oldA, oldB], language: "zh").map(\.provider)
        coordinator.providers = oldProviders
        check(oldProviders[0].codexResetCreditsAvailableCount == 4, "Both conversion paths preserve count")
        let oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldProviders[0])) as! [String: Any]
        var legacyJSON = oldJSON
        legacyJSON.removeValue(forKey: "codexResetCreditsAvailableCount")
        let legacy = try JSONDecoder().decode(ProviderData.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        check(legacy.codexResetCreditsAvailableCount == nil, "Old frontend JSON decodes")
        for (label, value) in [("Credits", "42.25 credits"), ("积分", "42.25 积分"), ("Credits", "0 credits"), ("Credits", "Unlimited")] {
            var creditJSON = oldJSON
            creditJSON["metrics"] = [["label": label, "value": value]]
            let provider = try JSONDecoder().decode(ProviderData.self, from: JSONSerialization.data(withJSONObject: creditJSON))
            check(provider.codexCreditsDisplayValue == value, "Codex card preserves \(label): \(value)")
            creditJSON["providerId"] = "claude-subscription"
            let other = try JSONDecoder().decode(ProviderData.self, from: JSONSerialization.data(withJSONObject: creditJSON))
            check(other.codexCreditsDisplayValue == nil, "Credits never leak into another provider's card")
        }
        check(legacy.codexCreditsDisplayValue == nil, "Missing credits stay unknown rather than zero")

        var continuation: CheckedContinuation<ProviderResult?, Never>?
        coordinator.engine.fetch = { _ in await withCheckedContinuation { continuation = $0 } }
        let olderAccount = Task { await coordinator.fetchAccountByCredential(credentialId: "A", providerId: "codex") }
        while continuation == nil { await Task.yield() }
        let oldBulkGeneration = coordinator.codexResetRefreshFence.token
        coordinator.refreshingAccountIDs.insert("codex:A")
        coordinator.engine.fetch = { id in result(id == "A" ? a : b, count: 3) }
        let identity = CodexAccountIdentity(credential: a)
        let refreshed = await coordinator.refreshCodexAccountAfterReset(credentialId: "A", identity: identity)
        check(refreshed, "Post-consume refresh actually runs despite prior in-flight request")
        continuation?.resume(returning: oldA)
        _ = await olderAccount.value
        check(coordinator.providers.first { $0.id == oldA.id }?.codexResetCreditsAvailableCount == 3, "Old single response rejected")
        let protected = coordinator.preserveCodexResetUpdates(oldProviders, since: oldBulkGeneration)
        check(protected.first { $0.id == oldA.id }?.codexResetCreditsAvailableCount == 3, "Old bulk response rejected")
        check(protected.first { $0.id == oldB.id }?.codexResetCreditsAvailableCount == 7, "B bulk response retained")
        check(coordinator.engine.requested == ["A", "A"], "No B refresh or provider fallback")
        AppSettings.shared.backendMode = "remote"
        let remote = await coordinator.refreshCodexAccountAfterReset(credentialId: "A", identity: identity)
        check(!remote && coordinator.engine.requested.count == 2, "Remote mode cannot refresh local credentials")
        AppSettings.shared.backendMode = "local"

        try await testUICoordinator()
        try await testLoadConsumeOrdering()
        await testRegistryProtection()
        try await testRetryRefreshOrdering()
        if failures > 0 { print("FAILED: \(failures) / \(assertions) assertions"); exit(1) }
        print("PASS: \(assertions) Codex reset-card coordinator/conversion/concurrency assertions")
    }

    @MainActor static func testRegistryProtection() async {
        let a = credential("A", user: "a"), b = credential("B", user: "b")
        AccountCredentialStore.shared.credentials = [a, b]
        let freshA = result(a, count: 3), freshB = result(b, count: 7)
        var staleA = result(a, count: 4)
        staleA.summary!.id = "codex:auto:old-A"
        staleA.summary!.sourceFilePath = "/fixture/old-A/auth.json"
        var incomingB = result(b, count: 6)
        incomingB.summary!.sourceFilePath = "/fixture/new-B/auth.json"
        let paths = ["targeted", "provider-multi", "provider-single", "dashboard", "provider-remote", "dashboard-remote"]
        for path in paths {
            for timing in ["response", "worker", "worker-no-revision"] {
                let suspendWorker = timing != "response"
                let label = "\(path)/\(timing)"
                AppSettings.shared.backendMode = "local"
                let coordinator = ProviderRefreshCoordinator()
                coordinator.accountStore.accountRegistry = []
                coordinator.providers = coordinator.localizedProviderResults(from: [freshA, freshB], language: "zh").map(\.provider)
                await coordinator.accountStore.reconcileAccountRegistry(with: coordinator.providers)
                let gate = FixtureRegistryGate.shared
                gate.batches = []
                gate.sourceToHold = suspendWorker ? staleA.summary!.sourceFilePath : nil
                var responseGate: CheckedContinuation<Void, Never>?
                let waitForResponse: () async -> Void = {
                    if !suspendWorker { await withCheckedContinuation { responseGate = $0 } }
                }
                let incoming = path == "targeted" || path == "provider-single" ? [staleA] : [staleA, incomingB]
                let overviewJSON = #"{"generatedAt":"fixture","activeProviders":2,"attentionProviders":0,"criticalProviders":0,"resetSoonProviders":0,"localCostMonthUsd":0,"localWeekTokens":0,"stats":[],"alerts":[]}"#
                let snapshotJSON = "{\"generatedAt\":\"fixture\",\"overview\":\(overviewJSON),\"providers\":\(String(data: try! JSONEncoder().encode(incoming), encoding: .utf8)!)}"
                let snapshot = try! JSONDecoder().decode(DashboardSnapshot.self, from: Data(snapshotJSON.utf8))
                let remote = try! JSONDecoder().decode(DashboardResponse.self, from: Data(snapshotJSON.utf8))
                coordinator.engine.fetch = { _ in await waitForResponse(); return staleA }
                coordinator.engine.multi = { await waitForResponse(); return path == "provider-single" ? nil : incoming }
                // 单结果分支只挂起一次：multi 返回 nil，不消费 response gate。
                if path == "provider-single" { coordinator.engine.multi = { nil } }
                coordinator.engine.single = { await waitForResponse(); return staleA }
                coordinator.engine.all = { await waitForResponse(); return snapshot }
                APIService.shared.results = { await waitForResponse(); return remote.providers }
                APIService.shared.dashboard = { await waitForResponse(); return remote }
                let old = Task {
                    switch path {
                    case "targeted": return await coordinator.fetchAccountByCredential(credentialId: "A", providerId: "codex")
                    case "provider-multi", "provider-single": return await coordinator.fetchSingleProviderLocal("codex")
                    case "provider-remote": return await coordinator.fetchSingleProviderRemote("codex")
                    case "dashboard-remote": return await coordinator.fetchDashboardRemote(showMessageOnFailure: false)
                    default: return await coordinator.fetchDashboardLocal()
                    }
                }
                while suspendWorker ? gate.continuation == nil : responseGate == nil { await Task.yield() }
                coordinator.engine.fetch = { _ in freshA }
                if timing == "worker-no-revision" {
                    let revision = coordinator.accountStore.accountRegistryRevision
                    coordinator.codexResetRefreshFence.invalidate(CodexAccountIdentity(credential: a).nativeKey!)
                    check(coordinator.accountStore.accountRegistryRevision == revision, "\(label): only fence changed while worker suspended")
                } else {
                    let refreshed = await coordinator.refreshCodexAccountAfterReset(credentialId: "A", identity: CodexAccountIdentity(credential: a))
                    check(refreshed, "\(label): reset usage accepted")
                }
                let expected = coordinator.accountStore.accountRegistry.first { $0.workspaceUserId == "a" }!
                var staleWrites = 0
                let observation = coordinator.accountStore.$accountRegistry.sink { registry in
                    if registry.contains(where: { $0.workspaceUserId == "a" && ($0.providerResultId != expected.providerResultId || $0.sourceFilePath != expected.sourceFilePath) }) { staleWrites += 1 }
                }
                let batchCountBeforeOldResponse = gate.batches.count
                if suspendWorker { gate.release() } else { responseGate?.resume() }
                _ = await old.value
                let actual = coordinator.accountStore.accountRegistry.first { $0.workspaceUserId == "a" }!
                check(actual.providerResultId == expected.providerResultId && actual.sourceFilePath == expected.sourceFilePath
                      && actual.credentialId == expected.credentialId && actual.accountId == expected.accountId,
                      "\(label): stale A cannot overwrite real registry source/identity")
                check(staleWrites == 0, "\(label): no stale registry publication before final state")
                if !suspendWorker {
                    check(!gate.batches.dropFirst(batchCountBeforeOldResponse).flatMap { $0 }.contains { $0.sourceFilePath == staleA.summary!.sourceFilePath },
                          "\(label): stale A filtered before registry worker")
                }
                check(coordinator.providers.first { $0.workspaceUserId == "a" }?.sourceFilePath == a.credential,
                      "\(label): UI retains reset A")
                if incoming.count == 2 {
                    check(coordinator.accountStore.accountRegistry.first { $0.workspaceUserId == "b" }?.sourceFilePath == incomingB.summary!.sourceFilePath,
                          "\(label): B registry update remains accepted")
                    check(coordinator.providers.first { $0.workspaceUserId == "b" }?.codexResetCreditsAvailableCount == 6,
                          "\(label): B usage remains accepted")
                }
                observation.cancel()
            }
        }
        print("Registry regression: 6 production apply paths × response/worker/worker-without-registry-revision suspension; real AccountStore and worker")
    }

    @MainActor static func testRetryRefreshOrdering() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory); StubURLProtocol.uninstall() }
        var credentials: [String: AccountCredential] = [:]
        for id in ["A", "B"] {
            let claims = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": ["chatgpt_account_id": "workspace", "chatgpt_user_id": id]])
                .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let authURL = directory.appendingPathComponent("\(id).json")
            try JSONSerialization.data(withJSONObject: ["last_refresh": SharedFormatters.iso8601String(from: Date()),
                "tokens": ["account_id": "workspace", "access_token": "fixture", "id_token": "e30.\(claims).test"]]).write(to: authURL)
            credentials[id] = AccountCredential(id: id, providerId: "codex", authMethod: .authFile, credential: authURL.path,
                metadata: ["accountId": "workspace", "workspaceUserId": id])
        }
        let a = credentials["A"]!, b = credentials["B"]!
        let targetA = CodexResetCreditsCoordinator.Target(identity: CodexAccountIdentity(credential: a), credentialID: "A", label: "A", isLocal: true)
        let targetB = CodexResetCreditsCoordinator.Target(identity: CodexAccountIdentity(credential: b), credentialID: "B", label: "B", isLocal: true)
        let model = CodexResetCreditsCoordinator(operations: .init(journalURL: directory.appendingPathComponent("pending.json")),
            loadCredential: { credentials[$0] }, isLocal: { true })
        StubURLProtocol.install(hosts: ["chatgpt.com"])
        let endpoint = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
        StubURLProtocol.respond(endpoint, body: CoordinatorGateProtocol.available)
        await model.load(targetA)
        let card = model.state(for: targetA).list!.credits[0]
        StubURLProtocol.respond(endpoint + "/consume", body: #"{"code":"reset"}"#)
        var gate: CheckedContinuation<Bool, Never>?
        var usageCalls = 0, confirmCalls = 0, bCalls = 0
        let first = Task {
            await model.retryRefresh(targetA) {
                usageCalls += 1
                return await withCheckedContinuation { gate = $0 }
            }
        }
        while gate == nil { await Task.yield() }
        await model.retryRefresh(targetA) { usageCalls += 1; return true }
        check(usageCalls == 1, "Refreshing A: second click sends zero extra usage calls")
        let requestsBeforeLoad = StubURLProtocol.requests.count
        await model.load(targetA)
        check(StubURLProtocol.requests.count == requestsBeforeLoad, "Refreshing A: load rejected before detail GET")
        await model.confirm(card, for: targetA) { confirmCalls += 1; return true }
        check(!StubURLProtocol.requests.contains { $0.method == "POST" } && confirmCalls == 0,
              "Refreshing A: confirm sends zero POST and zero usage calls")
        StubURLProtocol.respond(endpoint, body: #"{"available_count":0,"credits":[]}"#)
        await model.retryRefresh(targetB) { bCalls += 1; return true }
        check(bCalls == 1 && model.state(for: targetB).list?.availableCount == 0,
              "Refreshing A: B remains independent and reloads its list")
        let requestsBeforeRelease = StubURLProtocol.requests.count
        gate?.resume(returning: true)
        await first.value
        check(StubURLProtocol.requests.count == requestsBeforeRelease + 1 && model.state(for: targetA).list?.availableCount == 0
              && model.state(for: targetA).list?.credits.isEmpty == true && !model.state(for: targetA).refreshFailed,
              "Manual usage refresh still reloads fresh detail list")
        await model.retryRefresh(targetA) { usageCalls += 1; return true }
        check(usageCalls == 2, "Refreshing flag clears after completion and accepts next refresh")
        await model.retryRefresh(targetA) { false }
        await model.retryRefresh(targetA) { usageCalls += 1; return true }
        check(usageCalls == 3 && !model.state(for: targetA).refreshFailed, "Refreshing flag also clears after failure")
        print("Retry regression: held A usage refresh deduplicates, blocks load/confirm, accepts B, reloads detail")
    }

    @MainActor static func testUICoordinator() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory); StubURLProtocol.uninstall() }
        let claims = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": ["chatgpt_account_id": "workspace", "chatgpt_user_id": "a"]])
            .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let authURL = directory.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: ["last_refresh": SharedFormatters.iso8601String(from: Date()),
            "tokens": ["account_id": "workspace", "access_token": "fixture", "id_token": "e30.\(claims).test"]]).write(to: authURL)
        let credential = AccountCredential(id: "A", providerId: "codex", authMethod: .authFile, credential: authURL.path,
                                           metadata: ["accountId": "workspace", "workspaceUserId": "a"])
        let identity = CodexAccountIdentity(credential: credential)
        let target = CodexResetCreditsCoordinator.Target(identity: identity, credentialID: "A", label: "Fixture A", isLocal: true)
        var local = true
        let second = Date(timeIntervalSince1970: 2_000_000_000)
        var listFetchedAt = second.addingTimeInterval(0.2)
        var model = CodexResetCreditsCoordinator(operations: .init(journalURL: directory.appendingPathComponent("pending.json")),
                                                loadCredential: { _ in credential }, isLocal: { local }, now: { listFetchedAt })
        StubURLProtocol.install(hosts: ["chatgpt.com"])
        let endpoint = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
        let list = #"{"available_count":8,"credits":[{"id":"chosen","reset_type":"codex_rate_limits","status":"available","expires_at":null}]}"#
        StubURLProtocol.respond(endpoint, body: list)
        await model.load(target)
        let card = model.state(for: target).list!.credits[0]
        check(model.state(for: target).list?.availableCount == 8, "UI uses server total")
        let remoteTarget = CodexResetCreditsCoordinator.Target(identity: identity, credentialID: nil, label: "Fixture A", isLocal: false)
        check(model.state(for: remoteTarget).list == nil, "Remote view must not reuse local operation state")
        check(model.availableCount(for: target, summaryCount: 2, summaryFetchedAt: "2099-01-01T00:00:00Z") == 2,
              "New usage summary takes precedence over cached detail total")
        check(!StubURLProtocol.requests.contains { $0.method == "POST" }, "Open/select/cancel has zero POST")
        StubURLProtocol.respond(endpoint, status: 500, body: "{}")
        await model.load(target)
        check(model.state(for: target).listFailed && model.state(for: target).list?.availableCount == 8, "List failure keeps known data")
        StubURLProtocol.respond(endpoint, body: list)
        StubURLProtocol.respond(endpoint + "/consume", body: #"{"code":"reset"}"#)
        var refreshes = 0
        await model.confirm(card, for: target) { refreshes += 1; return false }
        check(model.state(for: target).outcome?.code == .reset && model.state(for: target).refreshFailed, "Consume success separate from refresh failure")
        check(refreshes == 1, "One target refresh")
        await model.retryRefresh(target) { refreshes += 1; return true }
        check(!model.state(for: target).refreshFailed && refreshes == 2, "Manual target retry retained")

        // 后续场景使用独立会话；同一已兑换 ID 不能再次提交。
        model = CodexResetCreditsCoordinator(operations: .init(journalURL: directory.appendingPathComponent("same-second.json")),
                                            loadCredential: { _ in credential }, isLocal: { local }, now: { listFetchedAt })
        await model.load(target)
        // 列表在 .2 秒返回，目标 usage 在同一秒的 .6 秒更新，但其序列化时间丢失小数。
        let usageFetchedAt = SharedFormatters.iso8601String(from: second.addingTimeInterval(0.6))
        check(SharedFormatters.parseISO8601(usageFetchedAt) == second && model.state(for: target).listFetchedAt == second.addingTimeInterval(0.2),
              "Regression uses second-precision usage and controlled subsecond list time")
        StubURLProtocol.respond(endpoint, body: list)
        await model.confirm(card, for: target) {
            StubURLProtocol.respond(endpoint, status: 500, body: "{}")
            return true
        }
        check(model.state(for: target).outcome?.code == .reset && !model.state(for: target).refreshFailed && model.state(for: target).listFailed,
              "Confirm succeeds and target usage refresh succeeds before detail reload fails")
        check(model.availableCount(for: target, summaryCount: 7, summaryFetchedAt: usageFetchedAt) == 7,
              "Successful confirm usage refresh supersedes same-second cached count after detail failure")
        check(model.state(for: target).list?.credits == [card] && model.state(for: target).list?.availableCount == 8 && model.state(for: target).listFailed,
              "Confirm detail failure retains old rows and old-data warning")

        listFetchedAt = second.addingTimeInterval(0.8)
        StubURLProtocol.respond(endpoint, body: list.replacingOccurrences(of: "\"available_count\":8", with: "\"available_count\":6"))
        await model.load(target)
        check(model.availableCount(for: target, summaryCount: 7, summaryFetchedAt: usageFetchedAt) == 6 && !model.state(for: target).listFailed,
              "Later list restores count authority over older usage in the same second")

        StubURLProtocol.respond(endpoint, status: 500, body: "{}")
        await model.retryRefresh(target) { true }
        check(model.availableCount(for: target, summaryCount: 5, summaryFetchedAt: usageFetchedAt) == 5,
              "Successful retry usage refresh supersedes same-second cached count after detail failure")
        check(model.state(for: target).list?.credits == [card] && model.state(for: target).list?.availableCount == 6 && model.state(for: target).listFailed,
              "Retry detail failure retains old rows and old-data warning")
        listFetchedAt = second.addingTimeInterval(0.9)
        StubURLProtocol.respond(endpoint, body: list.replacingOccurrences(of: "\"available_count\":8", with: "\"available_count\":4"))
        await model.load(target)
        check(model.availableCount(for: target, summaryCount: 5, summaryFetchedAt: usageFetchedAt) == 4 && !model.state(for: target).listFailed,
              "Successful list reload also restores authority after retry")
        // 已确认消费必须立即废弃旧计数并禁用原卡，回读失败也不能重新启用。
        for code in ["reset", "already_redeemed"] {
            let recovery = CodexResetCreditsCoordinator(operations: .init(journalURL: directory.appendingPathComponent("recovery-\(code).json")),
                loadCredential: { _ in credential }, isLocal: { local }, now: { listFetchedAt })
            StubURLProtocol.respond(endpoint, body: list)
            await recovery.load(target)
            StubURLProtocol.respond(endpoint + "/consume", body: "{\"code\":\"\(code)\"}")
            await recovery.confirm(card, for: target) {
                StubURLProtocol.respond(endpoint, status: 500, body: "{}")
                return false
            }
            check(recovery.state(for: target).outcome?.code.rawValue == code && recovery.state(for: target).listFailed,
                  "\(code): definite outcome survives both failed follow-up reads")
            check(recovery.availableCount(for: target, summaryCount: 8, summaryFetchedAt: usageFetchedAt) == nil,
                  "\(code): old summary and detail counts become unknown")
            check(!recovery.canConsume(card, for: target), "\(code): used card is disabled immediately")
            let posts = StubURLProtocol.requests.filter { $0.method == "POST" }.count
            await recovery.confirm(card, for: target) { true }
            check(StubURLProtocol.requests.filter { $0.method == "POST" }.count == posts,
                  "\(code): stale UI confirmation cannot resubmit a redeemed card")
            StubURLProtocol.respond(endpoint, body: #"{"available_count":7,"credits":[]}"#)
            await recovery.retryRefresh(target) { true }
            check(recovery.availableCount(for: target, summaryCount: 8, summaryFetchedAt: usageFetchedAt) == 7
                  && !recovery.state(for: target).refreshFailed && !recovery.state(for: target).listFailed,
                  "\(code): successful recovery restores the authoritative total")
        }
        let recovery = CodexResetCreditsCoordinator(operations: .init(journalURL: directory.appendingPathComponent("errors.json")),
            loadCredential: { _ in credential }, isLocal: { local }, now: { listFetchedAt })
        StubURLProtocol.respond(endpoint, body: #"{"available_count":0,"credits":[]}"#)
        await recovery.confirm(card, for: target) { true }
        check(recovery.state(for: target).errorCode == "reset_card_unavailable", "Unavailable card reports validation failure")
        await recovery.load(target)
        check(recovery.state(for: target).errorCode == nil, "Fresh details clear recovered validation errors")
        StubURLProtocol.respond(endpoint, body: list)
        StubURLProtocol.respond(endpoint + "/consume", status: 500, body: "{}")
        await recovery.confirm(card, for: target) { true }
        check(recovery.state(for: target).errorCode == "reset_ambiguous"
              && recovery.availableCount(for: target, summaryCount: 8, summaryFetchedAt: usageFetchedAt) == nil,
              "Unknown submission invalidates the old total without claiming success")
        StubURLProtocol.respond(endpoint, body: #"{"available_count":0,"credits":[]}"#)
        await recovery.retryRefresh(target) { true }
        check(recovery.state(for: target).errorCode == "reset_ambiguous" && recovery.state(for: target).refreshedAfterError
              && !recovery.state(for: target).refreshFailed,
              "Successful recovery distinguishes fresh account data from an unconfirmed submission")
        check(recovery.availableCount(for: target, summaryCount: 8, summaryFetchedAt: usageFetchedAt) == 0,
              "Unknown submission recovery displays the new zero total")
        let requestsAfterRecovery = StubURLProtocol.requests.count
        await recovery.confirm(card, for: .init(identity: identity, credentialID: nil, label: "Remote", isLocal: false)) { true }
        check(StubURLProtocol.requests.count == requestsAfterRecovery, "Recovered state never enables remote submission")
        // 快捷入口必须读取最新列表，按到期时间选择有效卡；仅准备，不发送 POST。
        let shortcut = CodexResetCreditsCoordinator(operations: .init(journalURL: directory.appendingPathComponent("shortcut.json")),
            loadCredential: { _ in credential }, isLocal: { local }, now: { listFetchedAt })
        let soon = SharedFormatters.iso8601String(from: listFetchedAt.addingTimeInterval(86_400))
        let later = SharedFormatters.iso8601String(from: listFetchedAt.addingTimeInterval(10 * 86_400))
        let payload = "{\"available_count\":4,\"credits\":[" + [
            "{\"id\":\"unlimited\",\"reset_type\":\"codex_rate_limits\",\"status\":\"available\",\"expires_at\":null}",
            "{\"id\":\"later\",\"reset_type\":\"codex_rate_limits\",\"status\":\"available\",\"expires_at\":\"\(later)\"}",
            "{\"id\":\"expired\",\"reset_type\":\"codex_rate_limits\",\"status\":\"available\",\"expires_at\":\"2000-01-01T00:00:00Z\"}",
            "{\"id\":\"soon\",\"reset_type\":\"codex_rate_limits\",\"status\":\"available\",\"expires_at\":\"\(soon)\"}",
            "{\"id\":\"unknown\",\"reset_type\":\"future_type\",\"status\":\"available\",\"expires_at\":null}"
        ].joined(separator: ",") + "]}"
        StubURLProtocol.respond(endpoint, body: payload)
        let postsBeforeShortcut = StubURLProtocol.requests.filter { $0.method == "POST" }.count
        let chosen = await shortcut.prepareEarliestCredit(for: target)
        check(chosen?.id == "soon", "Shortcut selects earliest-expiring valid card, skipping expired and unknown types")
        check(StubURLProtocol.requests.filter { $0.method == "POST" }.count == postsBeforeShortcut,
              "Preparing or cancelling shortcut confirmation never posts")
        StubURLProtocol.respond(endpoint, status: 500, body: "{}")
        let staleChoice = await shortcut.prepareEarliestCredit(for: target)
        check(staleChoice == nil, "Failed shortcut read never selects from cached cards")
        StubURLProtocol.respond(endpoint, body: payload)
        StubURLProtocol.respond(endpoint + "/consume", body: #"{"code":"reset"}"#)
        if let chosen { await shortcut.confirm(chosen, for: target) { true } }
        let nextChoice = await shortcut.prepareEarliestCredit(for: target)
        check(nextChoice?.id == "later", "Shortcut skips a redeemed ID even if the service still returns its old available row")
        StubURLProtocol.respond(endpoint, body: #"{"available_count":0,"credits":[]}"#)
        let emptyChoice = await shortcut.prepareEarliestCredit(for: target)
        check(emptyChoice == nil, "Empty fresh list does not submit")
        let beforeRemoteShortcut = StubURLProtocol.requests.count
        let remoteChoice = await shortcut.prepareEarliestCredit(for: remoteTarget)
        check(remoteChoice == nil && StubURLProtocol.requests.count == beforeRemoteShortcut,
              "Remote shortcut does not read local credentials or submit")
        local = false
        let before = StubURLProtocol.requests.count
        await model.load(target)
        await model.confirm(card, for: target) { refreshes += 1; return true }
        check(StubURLProtocol.requests.count == before && refreshes == 2, "Remote switch blocks local actions")
    }
    @MainActor static func testLoadConsumeOrdering() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory); CoordinatorGateProtocol.clear(); QuotaHTTP.sessionOverride = nil }
        let claims = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": ["chatgpt_account_id": "workspace", "chatgpt_user_id": "a"]])
            .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let authURL = directory.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: ["last_refresh": SharedFormatters.iso8601String(from: Date()),
            "tokens": ["account_id": "workspace", "access_token": "fixture", "id_token": "e30.\(claims).test"]]).write(to: authURL)
        let credential = AccountCredential(id: "A", providerId: "codex", authMethod: .authFile, credential: authURL.path,
                                           metadata: ["accountId": "workspace", "workspaceUserId": "a"])
        let identity = CodexAccountIdentity(credential: credential)
        let target = CodexResetCreditsCoordinator.Target(identity: identity, credentialID: "A", label: "Fixture A", isLocal: true)
        let model = CodexResetCreditsCoordinator(operations: .init(journalURL: directory.appendingPathComponent("pending.json")),
                                                loadCredential: { _ in credential }, isLocal: { true })
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CoordinatorGateProtocol.self]
        let session = URLSession(configuration: config)
        QuotaHTTP.sessionOverride = session
        defer { session.invalidateAndCancel() }
        let card = try JSONDecoder().decode(CodexResetCredits.self, from: Data(CoordinatorGateProtocol.available.utf8)).credits[0]
        let load = Task { await model.load(target) }
        while !CoordinatorGateProtocol.isHeld { await Task.yield() }
        var confirmationFinished = false
        let confirmation = Task {
            await model.confirm(card, for: target) { true }
            confirmationFinished = true
        }
        while !confirmationFinished && CoordinatorGateProtocol.postCount == 0 { await Task.yield() }
        let postsWhileLoading = CoordinatorGateProtocol.postCount
        CoordinatorGateProtocol.release()
        await load.value
        await confirmation.value
        check(postsWhileLoading == 0, "Confirm at coordinator boundary must reject in-flight detail read")
        let presenter = CodexQuickResetPresenter()
        await presenter.prepareReset(for: target, coordinator: model)
        check(presenter.selectedCard?.id == "chosen" && presenter.confirmedTarget?.credentialID == target.credentialID && presenter.showingAlert,
              "Quick reset presenter prepares earliest card and captures confirmed target")
        presenter.cancelSelection()
        check(presenter.selectedCard == nil && presenter.confirmedTarget == nil && CoordinatorGateProtocol.postCount == 0,
              "Canceling quick reset clears selection without submitting POST")
        await presenter.prepareReset(for: target, coordinator: model)
        let decoyTarget = CodexResetCreditsCoordinator.Target(identity: .init(accountId: "other", userId: "z"), credentialID: "Z", label: "Decoy", isLocal: true)
        await presenter.confirmSelected(fallbackTarget: decoyTarget, coordinator: model) { true }
        check(model.state(for: target).list?.availableCount == 0, "Post-consume detail total must be fresh")
        check(model.state(for: target).list?.credits.isEmpty == true, "Consumed card cannot reappear from old detail GET")
        check(CoordinatorGateProtocol.postCount == 1, "Only the explicit confirm after loading sends POST")
    }

}


private final class CoordinatorGateProtocol: URLProtocol {
    static let available = #"{"available_count":1,"credits":[{"id":"chosen","reset_type":"codex_rate_limits","status":"available","expires_at":null}]}"#
    private static let lock = NSLock()
    private static var held: CoordinatorGateProtocol?
    private static var hasHeld = false
    private static var posts = 0
    static var isHeld: Bool { lock.withLock { held != nil } }
    static var postCount: Int { lock.withLock { posts } }
    static func clear() { lock.withLock { held = nil; hasHeld = false; posts = 0 } }
    static func release() {
        let request = lock.withLock { () -> CoordinatorGateProtocol? in defer { held = nil }; return held }
        request?.reply(available)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = Self.lock.withLock { () -> String? in
            if request.httpMethod == "POST" { Self.posts += 1; return #"{"code":"reset"}"# }
            if !Self.hasHeld { Self.hasHeld = true; Self.held = self; return nil }
            return Self.posts == 0 ? Self.available : #"{"available_count":0,"credits":[]}"#
        }
        if let body { reply(body) }
    }
    private func reply(_ body: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
