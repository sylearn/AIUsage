import XCTest
@testable import QuotaBackend

final class OpenCodeConfigResolverTests: XCTestCase {
    func testDefaultsToJSONCManagementLayerWhenNoDedicatedGlobalFileExists() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        let resolution = OpenCodeConfigResolver(homeDirectory: home, environment: [:]).resolve()

        XCTAssertEqual(resolution.managementTarget.fileName, "opencode.jsonc")
        XCTAssertEqual(resolution.managementTarget.format, .jsonc)
        XCTAssertFalse(resolution.managementTarget.exists)
        XCTAssertEqual(resolution.globalLayers.map { $0.fileName }, ["config.json", "opencode.json", "opencode.jsonc"])
        XCTAssertTrue(resolution.lowerPriorityGlobalLayers.isEmpty)
    }

    func testJSONAndJSONCLayersAreMergedInsteadOfIgnored() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let directory = try makeConfigDirectory(home: home)
        try write("{\"mcp\":{\"from-json\":{}},\"theme\":\"dark\",\"shared\":{\"json\":true}}", to: directory, name: "opencode.json")
        try write("{// kept\n\"mcp\":{\"from-jsonc\":{}},\"shared\":{\"jsonc\":true},\n}", to: directory, name: "opencode.jsonc")

        let resolver = OpenCodeConfigResolver(homeDirectory: home, environment: [:])
        let resolution = resolver.resolve()
        let effective = try XCTUnwrap(resolver.readEffectiveObject())

        XCTAssertEqual(resolution.managementTarget.fileName, "opencode.jsonc")
        XCTAssertEqual(resolution.lowerPriorityGlobalLayers.map { $0.fileName }, ["opencode.json"])
        XCTAssertEqual(effective["theme"] as? String, "dark")
        XCTAssertEqual(Set((effective["mcp"] as? [String: Any] ?? [:]).keys), ["from-json", "from-jsonc"])
        let shared = try XCTUnwrap(effective["shared"] as? [String: Any])
        XCTAssertEqual(shared["json"] as? Bool, true)
        XCTAssertEqual(shared["jsonc"] as? Bool, true)
    }

    func testConfigJSONIsLowerPriorityAndNeverManagementTarget() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let directory = try makeConfigDirectory(home: home)
        try write("{\"mcp\":{\"legacy\":{}},\"theme\":\"dark\"}", to: directory, name: "config.json")

        let resolver = OpenCodeConfigResolver(homeDirectory: home, environment: [:])
        let resolution = resolver.resolve()
        let effective = try XCTUnwrap(resolver.readEffectiveObject())

        XCTAssertEqual(resolution.managementTarget.fileName, "opencode.jsonc")
        XCTAssertEqual(resolution.lowerPriorityGlobalLayers.map { $0.fileName }, ["config.json"])
        XCTAssertEqual(Set((effective["mcp"] as? [String: Any] ?? [:]).keys), ["legacy"])
    }

    func testXDGAndCustomLayersAreReportedSeparately() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let xdg = (home as NSString).appendingPathComponent("xdg")
        let custom = (home as NSString).appendingPathComponent("custom.json")
        let customDirectory = (home as NSString).appendingPathComponent("project-config")
        try FileManager.default.createDirectory(atPath: customDirectory, withIntermediateDirectories: true)
        try write("{\"mcp\":{\"project\":{}}}", to: customDirectory, name: "opencode.jsonc")

        let resolver = OpenCodeConfigResolver(
            homeDirectory: home,
            environment: [
                "XDG_CONFIG_HOME": xdg,
                "OPENCODE_CONFIG": custom,
                "OPENCODE_CONFIG_DIR": customDirectory,
            ]
        )
        let resolution = resolver.resolve()

        XCTAssertEqual(resolution.configDirectory, (xdg as NSString).appendingPathComponent("opencode"))
        XCTAssertEqual(resolution.customConfigPath, custom)
        XCTAssertEqual(resolution.customConfigDirectory, customDirectory)
        XCTAssertEqual(resolution.customDirectoryLayers.map { $0.fileName }, ["opencode.json", "opencode.jsonc"])
        XCTAssertEqual(resolution.managementTarget.fileName, "opencode.jsonc")
    }

    func testCustomConfigIsMergedAfterGlobalLayers() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let directory = try makeConfigDirectory(home: home)
        let custom = (home as NSString).appendingPathComponent("custom.json")
        try write("{\"theme\":\"dark\",\"mcp\":{\"global\":{}}}", to: directory, name: "opencode.json")
        try Data("{\"theme\":\"custom\",\"mcp\":{\"custom\":{}}}".utf8)
            .write(to: URL(fileURLWithPath: custom))

        let resolver = OpenCodeConfigResolver(
            homeDirectory: home,
            environment: ["OPENCODE_CONFIG": custom]
        )
        let effective = try XCTUnwrap(resolver.readEffectiveObject())
        XCTAssertEqual(effective["theme"] as? String, "custom")
        XCTAssertEqual(Set((effective["mcp"] as? [String: Any] ?? [:]).keys), ["global", "custom"])
    }

    func testInlineConfigContentIsMergedLastWithoutExposingItsText() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let directory = try makeConfigDirectory(home: home)
        try write("{\"theme\":\"global\",\"mcp\":{\"global\":{}}}", to: directory, name: "opencode.jsonc")

        let resolver = OpenCodeConfigResolver(
            homeDirectory: home,
            environment: [
                "OPENCODE_CONFIG_CONTENT": "{// inline\n\"theme\":\"inline\",\"mcp\":{\"inline\":{}},}"
            ]
        )
        let resolution = resolver.resolve()
        let effective = try XCTUnwrap(resolver.readEffectiveObject())

        XCTAssertEqual(resolution.inlineConfigParseStatus, .valid)
        XCTAssertEqual(effective["theme"] as? String, "inline")
        XCTAssertEqual(Set((effective["mcp"] as? [String: Any] ?? [:]).keys), ["global", "inline"])

        let invalidResolver = OpenCodeConfigResolver(
            homeDirectory: home,
            environment: ["OPENCODE_CONFIG_CONTENT": "{invalid"]
        )
        XCTAssertEqual(invalidResolver.resolve().inlineConfigParseStatus, .invalid)
        XCTAssertNil(invalidResolver.readEffectiveObject())
    }

    func testInventoryReadsMergedOpenCodeLayersAndSupportsComments() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let directory = try makeConfigDirectory(home: home)
        try write("{\"mcp\":{\"json-server\":{}}}", to: directory, name: "opencode.json")
        try write("{// comment\n\"mcp\":{\"jsonc-server\":{},},\n}", to: directory, name: "opencode.jsonc")

        let items = CallAnalyticsInventory(homeDirectory: home, environment: [:]).installedMCPServers()
        let openCodeNames = Set(items.filter { $0.source == .opencode }.map(\.name))

        XCTAssertEqual(openCodeNames, ["json-server", "jsonc-server"])
    }

    private func makeTemporaryHome() throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("aiusage-opencode-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func makeConfigDirectory(home: String) throws -> String {
        let directory = (home as NSString).appendingPathComponent(".config/opencode")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ text: String, to directory: String, name: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: (directory as NSString).appendingPathComponent(name)))
    }
}
