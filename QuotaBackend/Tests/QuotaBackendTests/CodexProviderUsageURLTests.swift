import Foundation
import XCTest
@testable import QuotaBackend

final class CodexProviderUsageURLTests: XCTestCase {
    private static let expectedUsageURL = "https://chatgpt.com/backend-api/wham/usage"

    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-codex-usage-url-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
    }

    func testUsageURLWithoutConfigToml() throws {
        try assertUsageURLEqualsExpected()
    }

    func testUsageURLIgnoresDefaultProviderConfig() throws {
        try writeConfig("""
        model = "gpt-5.4"
        model_provider = "openai"
        """)
        try assertUsageURLEqualsExpected()
    }

    func testUsageURLIgnoresHeadroomProvider() throws {
        try writeConfig("""
        model_provider = "headroom"

        [model_providers.headroom]
        name = "Headroom init proxy"
        base_url = "http://127.0.0.1:8787/v1"
        requires_openai_auth = true
        """)
        try assertUsageURLEqualsExpected()
    }

    func testUsageURLIgnoresAIUsageProxyProvider() throws {
        try writeConfig("""
        model_provider = "\(CodexProvider.proxyProviderId)"

        [model_providers.\(CodexProvider.proxyProviderId)]
        base_url = "http://127.0.0.1:4319/v1"
        wire_api = "responses"
        """)
        try assertUsageURLEqualsExpected()
    }

    func testUsageURLIgnoresOtherCustomProvider() throws {
        try writeConfig("""
        model_provider = "remote-openai"

        [model_providers.remote-openai]
        base_url = "https://proxy.example.com/v1"

        [model_providers.local-ollama]
        base_url = "http://127.0.0.1:11434/v1"
        """)
        try assertUsageURLEqualsExpected()
    }

    func testUsageURLIgnoresTopLevelBaseURLKeys() throws {
        try writeConfig("""
        apiBaseUrl = "http://127.0.0.1:9999"
        api_base_url = "http://127.0.0.1:8888"
        base_url = "http://127.0.0.1:7777/v1"
        model_provider = "headroom"

        [model_providers.headroom]
        base_url = "http://127.0.0.1:8787/v1"
        """)
        try assertUsageURLEqualsExpected()
    }

    private func writeConfig(_ toml: String) throws {
        let codexDirectory = tempHome.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let configURL = codexDirectory.appendingPathComponent("config.toml")
        try toml.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func assertUsageURLEqualsExpected(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let url = try CodexProvider.resolveUsageEndpointURL(homeDirectory: tempHome.path)
        XCTAssertEqual(url.absoluteString, Self.expectedUsageURL, file: file, line: line)
    }
}
