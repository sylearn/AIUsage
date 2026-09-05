import Foundation
import XCTest
@testable import QuotaBackend

final class CodexSessionProviderMigratorTests: XCTestCase {
    func testMigratesOnlyAIUsageProviderInPlaceAndRecordsCutoff() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-session-provider-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let sessionURL = home
            .appendingPathComponent(".codex/sessions/2026/09/05", isDirectory: true)
            .appendingPathComponent("active.jsonl")
        let archivedURL = home
            .appendingPathComponent(".codex/archived_sessions", isDirectory: true)
            .appendingPathComponent("archived.jsonl")
        let foreignURL = home
            .appendingPathComponent(".codex/sessions/2026/09/05", isDirectory: true)
            .appendingPathComponent("foreign.jsonl")
        let nativeURL = home
            .appendingPathComponent(".codex/sessions/2026/09/05", isDirectory: true)
            .appendingPathComponent("native.jsonl")

        try writeRollout(sessionID: "active-session", provider: "aiusage-proxy", to: sessionURL)
        try writeRollout(sessionID: "archived-session", provider: "aiusage-proxy", to: archivedURL)
        try writeRollout(sessionID: "foreign-session", provider: "cliproxyapi", to: foreignURL)
        try writeRollout(sessionID: "native-session", provider: "openai", to: nativeURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionURL.path)

        let original = try Data(contentsOf: sessionURL)
        let originalSuffix = try suffixAfterFirstLine(original)
        let originalSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: sessionURL.path)[.size] as? NSNumber
        ).uint64Value

        let report = try CodexSessionProviderMigrator.migrate(homeDirectory: home.path)

        XCTAssertEqual(report.migratedFiles, 2)
        XCTAssertEqual(try provider(in: sessionURL), "openai")
        XCTAssertEqual(try provider(in: archivedURL), "openai")
        XCTAssertEqual(try provider(in: foreignURL), "cliproxyapi")
        XCTAssertEqual(try provider(in: nativeURL), "openai")
        XCTAssertEqual(try suffixAfterFirstLine(Data(contentsOf: sessionURL)), originalSuffix)
        let migratedSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: sessionURL.path)[.size] as? NSNumber
        ).uint64Value
        XCTAssertEqual(migratedSize, originalSize)
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: sessionURL.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(permissions & 0o777, 0o600)

        let archiveURL = CodexSessionProviderMigrator.archiveURL(homeDirectory: home.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        let archivePermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: archiveURL.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(archivePermissions & 0o777, 0o600)
        let cutoffs = CodexSessionProviderMigrator.legacyProxyCutoffs(homeDirectory: home.path)
        XCTAssertNotNil(cutoffs["active-session"])
        XCTAssertNotNil(cutoffs["archived-session"])
        XCTAssertNil(cutoffs["foreign-session"])

        let second = try CodexSessionProviderMigrator.migrate(homeDirectory: home.path)
        XCTAssertEqual(second.migratedFiles, 0)
    }

    private func writeRollout(sessionID: String, provider: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let metadata: [String: Any] = [
            "timestamp": "2026-09-05T00:00:00.000Z",
            "type": "session_meta",
            "payload": [
                "id": sessionID,
                "model_provider": provider,
            ],
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        var data = metadataData
        data.append(0x0A)
        data.append(Data("{\"type\":\"response_item\",\"payload\":{\"text\":\"keep exactly\"}}\n".utf8))
        try data.write(to: url, options: .atomic)
    }

    private func provider(in url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let newline = try XCTUnwrap(data.firstIndex(of: 0x0A))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any]
        )
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        return try XCTUnwrap(payload["model_provider"] as? String)
    }

    private func suffixAfterFirstLine(_ data: Data) throws -> Data {
        let newline = try XCTUnwrap(data.firstIndex(of: 0x0A))
        return data[data.index(after: newline)...]
    }
}
