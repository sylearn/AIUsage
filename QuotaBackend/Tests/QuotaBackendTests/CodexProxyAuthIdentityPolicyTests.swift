import Foundation
import XCTest
@testable import QuotaBackend

final class CodexProxyAuthIdentityPolicyTests: XCTestCase {
    func testClassifiesChatGPTTokensEvenWhenAuthModeIsStale() throws {
        let data = try json([
            "auth_mode": "apikey",
            "OPENAI_API_KEY": "stale-key",
            "tokens": ["access_token": "chatgpt-access"],
        ])
        XCTAssertEqual(CodexProxyAuthIdentityPolicy.classify(data), .chatGPT)
    }

    func testKeepsCurrentAndPreviousManagedProxyStubsOutOfAccountBackup() throws {
        let current = try apiKey("client-new")
        let previous = try apiKey("client-old")
        XCTAssertFalse(CodexProxyAuthIdentityPolicy.shouldStashCurrentAuth(
            current,
            targetProxyAPIKey: "client-new",
            knownManagedAPIKeys: ["client-old"],
            managedStateExists: true
        ))
        XCTAssertFalse(CodexProxyAuthIdentityPolicy.shouldStashCurrentAuth(
            previous,
            targetProxyAPIKey: "client-new",
            knownManagedAPIKeys: ["client-old"],
            managedStateExists: true
        ))
    }

    func testPreservesUsersNewAPIIdentityWhileProxyIsManaged() throws {
        XCTAssertTrue(CodexProxyAuthIdentityPolicy.shouldStashCurrentAuth(
            try apiKey("personal-api-key"),
            targetProxyAPIKey: "client-new",
            knownManagedAPIKeys: ["client-old", "client-new"],
            managedStateExists: true
        ))
    }

    func testPreservesChatGPTAndMalformedIdentityData() throws {
        let chatGPT = try json([
            "auth_mode": "chatgpt",
            "tokens": ["refresh_token": "chatgpt-refresh"],
        ])
        XCTAssertTrue(CodexProxyAuthIdentityPolicy.shouldStashCurrentAuth(
            chatGPT,
            targetProxyAPIKey: "client-key",
            knownManagedAPIKeys: ["client-key"],
            managedStateExists: true
        ))
        XCTAssertTrue(CodexProxyAuthIdentityPolicy.shouldStashCurrentAuth(
            Data("not-json".utf8),
            targetProxyAPIKey: "client-key",
            knownManagedAPIKeys: ["client-key"],
            managedStateExists: true
        ))
    }

    func testLegacyEmptyStubAndAmbiguousCrashStubDoNotOverwriteBackup() throws {
        XCTAssertFalse(CodexProxyAuthIdentityPolicy.shouldStashCurrentAuth(
            try apiKey(""),
            targetProxyAPIKey: "client-new",
            knownManagedAPIKeys: [],
            managedStateExists: true
        ))
        XCTAssertFalse(CodexProxyAuthIdentityPolicy.shouldStashCurrentAuth(
            try apiKey("unknown-old-client"),
            targetProxyAPIKey: "client-new",
            knownManagedAPIKeys: [],
            managedStateExists: true
        ))
    }

    private func apiKey(_ key: String) throws -> Data {
        try json(["auth_mode": "apikey", "OPENAI_API_KEY": key])
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
