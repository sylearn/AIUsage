import Foundation
import XCTest
@testable import QuotaBackend

final class CodexAccountIsolationTests: XCTestCase {
    private func jwt(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return "e30.\(data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")).test"
    }

    private func auth(workspace: String = "business-1", user: String = "member-a", token: String = "old-access") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tokens": ["account_id": workspace, "access_token": token, "refresh_token": "refresh-\(user)",
                       "id_token": jwt(["email": "\(user)@example.invalid", "https://api.openai.com/auth": [
                        "chatgpt_account_id": workspace, "chatgpt_user_id": user, "chatgpt_plan_type": "business"
                       ]])],
            "last_refresh": "2020-01-01T00:00:00Z"
        ])
    }

    func testNativeAndFlatAuthKeepWorkspaceAndUserSeparate() throws {
        let native = try JSONSerialization.jsonObject(with: auth()) as! [String: Any]
        let flat = native["tokens"] as! [String: Any]
        XCTAssertEqual(CodexAccountIdentity(authJSON: native), CodexAccountIdentity(authJSON: flat))
        XCTAssertEqual(CodexAccountIdentity(authJSON: native).nativeKey, "codex:account:business-1:user:member-a")
        let identity = CodexAccountIdentity(authJSON: native)
        XCTAssertFalse(identity.matches(CodexAccountIdentity(accountId: "business-1", userId: "member-b")))
        XCTAssertFalse(identity.matches(CodexAccountIdentity(accountId: "business-2", userId: "member-a")))
    }

    func testNativeUserInAccessTokenTakesPriorityOverIDTokenSubject() throws {
        let identity = CodexAccountIdentity(authJSON: ["tokens": [
            "account_id": "business-1",
            "id_token": try jwt(["sub": "auth0-legacy"]),
            "access_token": try jwt(["https://api.openai.com/auth": ["chatgpt_user_id": "member-a"]])
        ]])
        XCTAssertEqual(identity.userId, "member-a")
    }

    func testFallbackNeverTreatsNamesAsEmailOrOverridesKnownUserConflict() {
        let name = CodexAccountIdentity(accountId: "business-1", userId: nil, email: "Same Business")
        XCTAssertNil(name.key)
        XCTAssertFalse(name.matches(name))
        let a = CodexAccountIdentity(accountId: "business-1", userId: "a", email: "same@example.invalid")
        let b = CodexAccountIdentity(accountId: "business-1", userId: "b", email: "same@example.invalid")
        XCTAssertFalse(a.matches(b))
        XCTAssertTrue(a.conflicts(with: b))
        XCTAssertTrue(a.matches(CodexAccountIdentity(accountId: "business-1", userId: "a", email: "renamed@example.invalid")))
        XCTAssertNotEqual(name.key(fallback: "path:shared"), CodexAccountIdentity(accountId: "business-2", userId: nil).key(fallback: "path:shared"))
    }

    func testLegacyMetadataUpgradesOnlyWithJWTIdentityEvidence() throws {
        let provider = CodexProvider()
        let idToken = try jwt(["sub": "auth0-a", "https://api.openai.com/auth": [
            "chatgpt_account_id": "business-1", "chatgpt_user_id": "member-a"
        ]])
        let creds = CodexProvider.Credentials(authFile: "fixture", accessToken: "fixture", refreshToken: nil,
            idToken: idToken, accountId: "business-1", accountEmail: "a@example.invalid", jwtPlanType: "business",
            jwtUserId: "member-a", needsRefresh: false, isApiKeyMode: false)
        XCTAssertFalse(provider.credentialIdentityIsCompatible(
            CodexAccountIdentity(accountId: "member-a", userId: "auth0-a"), with: creds))
        XCTAssertTrue(provider.credentialIdentityIsCompatible(
            CodexAccountIdentity(accountId: "business-1", userId: "auth0-a"), with: creds))
        XCTAssertFalse(provider.credentialIdentityIsCompatible(
            CodexAccountIdentity(accountId: "business-2", userId: "auth0-a", email: "a@example.invalid"), with: creds))
        XCTAssertFalse(provider.credentialIdentityIsCompatible(
            CodexAccountIdentity(accountId: "business-1", userId: "member-b", email: "a@example.invalid"), with: creds))
    }

    func testQuotaResponseCannotReplaceWorkspaceIDWithUserLevelID() {
        let usage = CodexProvider().parseResponse(
            ["account_id": "user-legacy", "plan_type": "business"], accountId: "business-1",
            source: SourceInfo(mode: "test", type: "fixture"), fallbackEmail: "a@example.invalid", jwtUserId: "member-a"
        )
        XCTAssertEqual(usage.usageAccountId, "business-1")
        let summary = UsageNormalizer.normalize(provider: CodexProvider(), usage: usage)
        XCTAssertEqual(summary.workspaceUserId, "member-a")
    }

    func testRefreshWritesOwnCopyButNotSwitchedSharedSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-isolation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let own = directory.appendingPathComponent("own.json")
        let source = directory.appendingPathComponent("shared.json")
        try auth().write(to: own)
        let otherMember = try auth(user: "member-b")
        try otherMember.write(to: source)
        let provider = CodexProvider(homeDirectory: directory.path)
        let original = try provider.loadCredentials(from: own.path)
        let refreshed = CodexProvider.Credentials(
            authFile: own.path, accessToken: "new-access", refreshToken: "new-refresh", idToken: original.idToken,
            accountId: original.accountId, accountEmail: original.accountEmail, jwtPlanType: original.jwtPlanType,
            jwtUserId: original.jwtUserId, needsRefresh: false, isApiKeyMode: false
        )
        provider.persistRefreshedCredentials(refreshed, replacing: original, to: own.path)
        provider.persistRefreshedCredentials(refreshed, replacing: original, to: source.path)
        XCTAssertEqual(try provider.loadCredentials(from: own.path).accessToken, "new-access")
        XCTAssertEqual(try Data(contentsOf: source), otherMember)
        let otherWorkspace = try auth(workspace: "business-2")
        try otherWorkspace.write(to: source)
        provider.persistRefreshedCredentials(refreshed, replacing: original, to: source.path)
        XCTAssertEqual(try Data(contentsOf: source), otherWorkspace)
        // 同成员同空间的另一个副本仍能同步轮换后的 token。
        try auth().write(to: source)
        provider.persistRefreshedCredentials(refreshed, replacing: original, to: source.path)
        XCTAssertEqual(try provider.loadCredentials(from: source.path).accessToken, "new-access")
    }

    func testSwitchedCredentialFailsBeforeNetworkOrRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-switched-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("auth.json")
        try auth().write(to: path)
        let provider = CodexProvider(homeDirectory: directory.path)
        let original = try provider.loadCredentials(from: path.path)
        let switched = try auth(user: "member-b")
        try switched.write(to: path)
        do {
            _ = try await provider.performSerializedRefresh(original, fallbackRefreshToken: "dummy", persistTo: [path.path])
            XCTFail("Changed file must be rejected before contacting OAuth")
        } catch let error as ProviderError { XCTAssertEqual(error.code, "account_mismatch") }
        let credential = AccountCredential(providerId: "codex", authMethod: .authFile, credential: path.path,
                                           metadata: ["accountId": "business-1", "workspaceUserId": "member-a"])
        do {
            _ = try await provider.fetchUsage(with: credential)
            XCTFail("Changed credential must be rejected before usage request")
        } catch let error as ProviderError { XCTAssertEqual(error.code, "account_mismatch") }
        XCTAssertEqual(try Data(contentsOf: path), switched)
    }

    private func result(_ id: String, workspace: String = "business-1", user: String, failed: Bool = false) -> ProviderResult {
        var usage = ProviderUsage(provider: "codex", label: "Codex")
        usage.usageAccountId = workspace
        usage.accountEmail = "\(user)@example.invalid"
        usage.extra["userId"] = AnyCodable(user)
        var summary = UsageNormalizer.normalize(provider: CodexProvider(), usage: usage)
        summary.id = id
        summary.sourceFilePath = "/tmp/shared/auth.json"
        if failed { summary.status = "error" }
        return ProviderResult(id: id, providerId: "codex", accountId: workspace, ok: !failed,
                              usage: failed ? nil : usage, summary: summary, error: failed ? "unauthorized" : nil)
    }

    func testEngineKeepsOtherMembersAndFailuresEvenWithSharedPaths() async {
        let engine = ProviderEngine()
        let a = result("codex:cred:a", user: "a", failed: true)
        let b = result("codex:cred:b", user: "b")
        let auto = result("codex:auto:workspace", user: "b")
        let collision = await engine.codexResultsShareIdentity(a, auto)
        XCTAssertFalse(collision)
        let differentWorkspace = result("codex:auto:other", workspace: "business-2", user: "a")
        let workspaceCollision = await engine.codexResultsShareIdentity(a, differentWorkspace)
        XCTAssertFalse(workspaceCollision)
        let merged = await engine.mergeResults(automatic: [auto], credentialBacked: [a, b], provider: CodexProvider())
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains { $0.id == a.id && !$0.ok })
        let recovered = await engine.mergeResults(automatic: [result("codex:auto:a", user: "a")], credentialBacked: [a], provider: CodexProvider())
        XCTAssertEqual(recovered.count, 1)
        XCTAssertTrue(recovered[0].ok)
    }
}
