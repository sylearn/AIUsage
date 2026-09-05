import Foundation
import QuotaBackend

@main
struct AccountIdentityRegression {
    static var assertions = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
        assertions += 1
        guard condition() else { fatalError("\(message) (line \(line))") }
    }

    static func credential(_ id: String, workspace: String = "business-1", user: String = "member-a", email: String = "a@example.invalid", path: String? = nil) -> AccountCredential {
        AccountCredential(id: id, providerId: "codex", accountLabel: email, authMethod: .authFile,
                          credential: path ?? "/tmp/identity-fixtures/\(id)/auth.json", metadata: [
                            "accountId": workspace, "workspaceUserId": user, "accountEmail": email,
                            "sourcePath": "/tmp/shared-codex/auth.json", "accountPlan": "business"
                          ])
    }

    static func live(_ credential: AccountCredential, failed: Bool = false) throws -> ProviderData {
        var usage = ProviderUsage(provider: "codex", label: "Codex")
        usage.usageAccountId = credential.metadata["accountId"]
        usage.accountEmail = credential.metadata["accountEmail"]
        usage.accountPlan = "Business"
        usage.extra["userId"] = AnyCodable(credential.metadata["workspaceUserId"] ?? "")
        var summary = UsageNormalizer.normalize(provider: CodexProvider(), usage: usage)
        summary.id = "codex:cred:\(credential.id)"
        summary.sourceFilePath = credential.credential
        if failed { summary.status = "error"; summary.errorCode = "refresh_token_expired" }
        return try JSONDecoder().decode(ProviderData.self, from: JSONEncoder().encode(summary))
    }

    static func entry(_ provider: ProviderData, store: AccountStore) -> ProviderAccountEntry {
        ProviderAccountEntry(id: provider.id, providerId: "codex", providerTitle: "Codex", providerSubtitle: nil,
                             liveProvider: provider, storedAccount: store.accountRegistry.first {
            AccountIdentityPolicy.matchesLive(stored: $0, provider: provider)
        })
    }

    @MainActor static func main() async throws {
        let store = AccountStore.shared
        let fingerprintA = ProviderAuthManager.codexSessionFingerprint(from: ["account_id": "business-1", "chatgpt_user_id": "a", "email": "same@example.invalid"])!
        let fingerprintB = ProviderAuthManager.codexSessionFingerprint(from: ["account_id": "business-1", "chatgpt_user_id": "b", "email": "same@example.invalid"])!
        let fingerprintC = ProviderAuthManager.codexSessionFingerprint(from: ["account_id": "business-2", "chatgpt_user_id": "a", "email": "same@example.invalid"])!
        check(Set([fingerprintA, fingerprintB, fingerprintC]).count == 3, "自动发现指纹区分用户及空间")
        let monitored = ProviderMonitoredSessionIndex(sourceIdentifiers: ["shared-path"], sessionFingerprints: [fingerprintA], accountHandles: ["same@example.invalid"])
        func candidate(_ fingerprint: String) -> ProviderAuthCandidate {
            ProviderAuthCandidate(id: "test", providerId: "codex", sourceIdentifier: "shared-path", sessionFingerprint: fingerprint,
                title: "same@example.invalid", subtitle: nil, detail: "", modifiedAt: nil, authMethod: .authFile,
                credentialValue: "/tmp/auth.json", sourcePath: "/tmp/auth.json", shouldCopyFile: true, identityScope: .sharedSource)
        }
        check(ProviderAuthManager.isCandidateManaged(candidate(fingerprintA), monitored: monitored), "自动发现跳过已监控的同一身份")
        check(!ProviderAuthManager.isCandidateManaged(candidate(fingerprintB), monitored: monitored), "相同邮箱和路径不能抑制新成员")
        check(!ProviderAuthManager.isCandidateManaged(candidate(fingerprintC), monitored: monitored), "相同邮箱和路径不能抑制新空间")
        check(!ProviderAuthManager.isCandidateManaged(candidate("business-1"), monitored: monitored), "旧版空间指纹不得视为完整身份")
        let a = credential("a")
        let b = credential("b", user: "member-b", email: "b@example.invalid")
        let c = credential("c", workspace: "business-2")
        let p = credential("personal", workspace: "personal-a")
        for value in [a, b, c, p] {
            try AccountCredentialStore.shared.saveCredential(value)
            check(store.saveAccount(providerId: "codex", email: value.accountLabel!, displayName: "同名空间",
                                    accountId: value.metadata["accountId"], credentialId: value.id,
                                    ensureProviderSelected: { _ in }), "保存成功")
        }
        check(store.accountRegistry.count == 4, "同空间成员/同邮箱多空间必须各自保存")
        check(Set(store.accountRegistry.compactMap(\.credentialId)).count == 4, "凭据不能被替换")
        let liveA = try live(a), liveB = try live(b), liveC = try live(c), liveP = try live(p)
        check(liveA.workspaceUserId == "member-a", "用户 ID 必须跨服务 JSON 传到 UI")
        check(Set([liveA, liveB, liveC, liveP].map(AccountIdentityPolicy.liveIdentityKey(for:))).count == 4, "UI 分组必须独立")
        check(!AccountIdentityPolicy.codexLiveAccountsMatch(liveA, liveB), "单卡刷新不可匹配其他成员")
        check(!AccountIdentityPolicy.codexLiveAccountsMatch(liveA, liveC), "单卡刷新不可按邮箱跨空间匹配")
        for order in [[liveA, liveB, liveC, liveP], [liveP, liveC, liveB, liveA]] {
            await store.reconcileAccountRegistry(with: order)
            check(store.accountRegistry.count == 4, "刷新顺序不可影响账号数量")
            for provider in order {
                check(store.accountRegistry.filter { AccountIdentityPolicy.matchesLive(stored: $0, provider: provider) }.count == 1, "每条 live 只匹配一条存储")
            }
        }
        let failedA = try live(a, failed: true)
        await store.reconcileAccountRegistry(with: [failedA, liveB, liveC, liveP])
        check(store.accountRegistry.count == 4, "某成员失败不丢失账号")
        check(store.matchingCredentials(for: entry(liveA, store: store)).map(\.id) == ["a"], "凭据查找只命中当前成员")
        check(store.matchingStoredAccountIndices(for: entry(liveA, store: store)).count == 1, "隐藏删除只能选中当前成员")

        store.hideAccount(entry(liveA, store: store), onPostRegistryChange: {})
        check(store.hiddenAccounts().count == 1, "只隐藏指定成员")
        check(!store.hasHiddenRegistryMatch(providerId: "codex", normalizedEmail: b.accountLabel,
                                            normalizedAccountId: "business-1", sourceFilePath: b.credential,
                                            workspaceUserId: "member-b"), "隐藏 A 不抑制 B")
        await store.reconcileAccountRegistry(with: [liveA, liveB, liveC, liveP])
        check(store.hiddenAccounts().count == 1, "自动刷新不可取消隐藏")
        let hidden = store.hiddenAccounts()[0]
        check(hidden.workspaceUserId == "member-a", "隐藏记录保留成员身份")
        store.restoreAccount(hidden.id, onRestored: { _ in })
        check(store.hiddenAccounts().isEmpty, "恢复指定成员")

        store.deleteAccount(entry(liveA, store: store), onPostRegistryDelete: {})
        check(AccountCredentialStore.shared.loadCredentials(for: "codex").map(\.id).sorted() == ["b", "c", "personal"], "删除 A 不可删除 B/C")
        check(store.accountRegistry.filter(\.isPermanentlyRemoved).count == 1, "仅 A 留下删除记录")
        check(store.accountRegistry.filter { !$0.isHidden }.count == 3, "其他三个账号继续监控")
        await store.reconcileAccountRegistry(with: [liveA, liveB, liveC, liveP])
        check(store.accountRegistry.filter { !$0.isHidden }.count == 3, "删除前发出的旧请求不能复活 A")
        try AccountCredentialStore.shared.saveCredential(a)
        check(store.saveAccount(providerId: "codex", email: a.accountLabel!, displayName: nil, accountId: "business-1",
                                credentialId: "a", ensureProviderSelected: { _ in }), "重新添加 A")
        check(store.accountRegistry.count == 4 && !store.accountRegistry.contains(where: \.isHidden), "重新添加只复活 A、不重复")

        let onlyA = store.accountRegistry.filter { $0.credentialId == "a" }
        let lookup = Dictionary(uniqueKeysWithValues: [a, b, c].map { ($0.id, $0) })
        check(AccountIdentityPolicy.codexSubscriptionAlreadyContains(identity: CodexAccountIdentity(credential: a), sourcePath: a.credential,
                registry: onlyA, credentialLookup: lookup, respectRemoval: false), "CPA 相同账号重复添加应跳过")
        check(!AccountIdentityPolicy.codexSubscriptionAlreadyContains(identity: CodexAccountIdentity(credential: b), sourcePath: a.credential,
                registry: onlyA, credentialLookup: lookup, respectRemoval: false), "CPA 同空间其他成员不能被已存在判定挡住")
        check(!AccountIdentityPolicy.codexSubscriptionAlreadyContains(identity: CodexAccountIdentity(credential: c), sourcePath: a.credential,
                registry: onlyA, credentialLookup: lookup, respectRemoval: false), "CPA 同邮箱其他空间不能被挡住")
        var removedA = onlyA[0]
        removedA.isHidden = true
        removedA.isPermanentlyRemoved = true
        check(AccountIdentityPolicy.codexSubscriptionAlreadyContains(identity: CodexAccountIdentity(credential: a), sourcePath: a.credential,
                registry: [removedA], credentialLookup: lookup, respectRemoval: true), "自动补回尊重 A 的删除记录")
        check(!AccountIdentityPolicy.codexSubscriptionAlreadyContains(identity: CodexAccountIdentity(credential: b), sourcePath: a.credential,
                registry: [removedA], credentialLookup: lookup, respectRemoval: true), "A 的删除记录不能阻挡 B 的补回")
        check(!AccountIdentityPolicy.codexSubscriptionAlreadyContains(identity: CodexAccountIdentity(credential: a), sourcePath: a.credential,
                registry: [removedA], credentialLookup: lookup, respectRemoval: false), "显式添加允许复活 A")

        let sharedA = credential("path-a", path: "/tmp/same/auth.json")
        let sharedB = credential("path-b", user: "member-b", email: "b@example.invalid", path: "/tmp/same/auth.json")
        let sharedC = credential("path-c", workspace: "business-2", path: "/tmp/same/auth.json")
        let sharedLiveA = try live(sharedA), sharedLiveB = try live(sharedB), sharedLiveC = try live(sharedC)
        check(!AccountIdentityPolicy.codexLiveAccountsMatch(sharedLiveA, sharedLiveB), "共享路径不能覆盖用户冲突")
        check(!AccountIdentityPolicy.codexLiveAccountsMatch(sharedLiveA, sharedLiveC), "共享路径不能覆盖工作区冲突")

        let encoded = try JSONEncoder().encode(store.accountRegistry)
        let restored = try JSONDecoder().decode([StoredProviderAccount].self, from: encoded)
        check(restored == store.accountRegistry, "持久化往返保留所有身份字段")
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [[String: Any]]
        for index in legacy.indices { legacy[index].removeValue(forKey: "workspaceUserId") }
        store.accountRegistry = try JSONDecoder().decode([StoredProviderAccount].self, from: JSONSerialization.data(withJSONObject: legacy))
        _ = store.normalizeAccountRegistryAgainstCredentials()
        check(store.accountRegistry.count == 4 && store.accountRegistry.allSatisfy { $0.workspaceUserId != nil }, "旧数据从对应凭据补全身份")
        await store.reconcileAccountRegistry(with: [liveA, liveB, liveC, liveP])
        check(store.accountRegistry.count == 4, "旧数据升级后不合并、不重复")

        var usage = ProviderUsage(provider: "codex", label: "Codex")
        usage.usageAccountId = "business-1"
        usage.accountEmail = "a@example.invalid"
        usage.accountPlan = "Pro"
        usage.extra["userId"] = AnyCodable("member-a")
        try store.registerAuthenticatedCredential(credential("a-new"), usage: usage, note: nil, providerDisplayTitle: "Codex",
            insertImmediateProviderData: { _, _, _, _ in }, ensureProviderSelected: { _ in })
        check(store.accountRegistry.count == 4, "重复登录/套餐变化不创建重复账号")
        check(AccountCredentialStore.shared.credentials.count == 4, "同身份重新登录复用原凭据")
        check(store.accountRegistry.contains { $0.credentialId == "b" && $0.email == "b@example.invalid" }, "A 重新登录不能修改 B")
        let legacyIndex = store.accountRegistry.firstIndex { $0.credentialId == "b" }!
        store.accountRegistry[legacyIndex].accountId = "member-b"
        store.accountRegistry[legacyIndex].workspaceUserId = "old-subject-b"
        await store.reconcileAccountRegistry(with: [liveB])
        check(store.accountRegistry.count == 4, "旧版错误字段更新不能产生重复卡片")
        check(store.accountRegistry[legacyIndex].accountId == "business-1"
              && store.accountRegistry[legacyIndex].workspaceUserId == "member-b", "用已验证凭据修复旧注册表身份")
        store.deleteAccounts([entry(liveB, store: store), entry(liveC, store: store)], onPostRegistryDelete: {})
        check(Set(store.accountRegistry.filter { !$0.isHidden }.compactMap(\.credentialId)) == ["a", "personal"], "批量删除仅移除选中的成员与空间")
        check(Set(AccountCredentialStore.shared.credentials.map(\.id)) == ["a", "personal"], "批量删除保留未选中凭据")

        // 相同邮箱的残缺历史数据不能通过兜底分支抢占另一个明确的成员。
        var oldA = onlyA[0]
        oldA.credentialId = nil
        oldA.workspaceUserId = nil
        let sameEmailB = StoredProviderAccount(id: "same-email-b", providerId: "codex", email: oldA.email,
            displayName: nil, note: nil, accountId: "business-1", providerResultId: "codex:saved-member-b",
            credentialId: nil, createdAt: oldA.createdAt, lastSeenAt: nil,
            sourceFilePath: "/tmp/legacy-b/auth.json", workspaceUserId: "member-b")
        var memberB = credential("ambiguous-b", user: "member-b")
        memberB.metadata["accountEmail"] = oldA.email
        let memberBLive = try live(memberB)
        check(AccountIdentityPolicy.bestStoredAccountIndex(in: [oldA, sameEmailB], for: memberBLive,
                excluding: [], allowUnseenCredentialFallback: false) == 1, "完整原生身份优先于旧邮箱关联，卡片顺序不影响归属")
        check(AccountIdentityPolicy.bestStoredAccountIndex(in: [oldA, sameEmailB], for: memberBLive,
                excluding: [sameEmailB.id], allowUnseenCredentialFallback: false) == nil, "已消费的精确身份不能退到其他历史记录")
        var incompleteJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(memberBLive)) as! [String: Any]
        incompleteJSON.removeValue(forKey: "workspaceUserId")
        incompleteJSON["id"] = "codex:legacy-ambiguous"
        incompleteJSON["sourceFilePath"] = "/tmp/ambiguous/auth.json"
        let incompleteLive = try JSONDecoder().decode(ProviderData.self, from: JSONSerialization.data(withJSONObject: incompleteJSON))
        let completeA = onlyA[0]
        store.accountRegistry = [completeA, sameEmailB]
        check(AccountIdentityPolicy.bestStoredAccountIndex(in: store.accountRegistry, for: incompleteLive,
                excluding: [], allowUnseenCredentialFallback: false) == nil, "残缺结果存在多个候选时不猜测归属")
        await store.reconcileAccountRegistry(with: [incompleteLive])
        check(store.accountRegistry[0] == completeA && store.accountRegistry[1] == sameEmailB, "协调兜底不能绕过歧义检查覆盖任何成员")
        print("PASS: \(assertions) account identity assertions (production save/reconcile/hide/delete, isolated storage)")
    }
}
