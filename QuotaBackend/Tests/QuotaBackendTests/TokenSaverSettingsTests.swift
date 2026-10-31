import XCTest
import SQLite3
@testable import QuotaBackend

final class TokenSaverSettingsTests: XCTestCase {
    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testDefaultsAndScopeCannotBeDisabled() throws {
        let home = try temporaryHome()
        XCTAssertEqual(try TokenSaverSettingsStore.load(home: home), TokenSaverSettings())
        let value = try JSONDecoder().decode(TokenSaverSettings.self, from: Data("{\"codingOnlyScope\":false}".utf8))
        XCTAssertTrue(value.codingOnlyScope)
        XCTAssertFalse(value.cavemanEnabled)
    }
    func testRoundTripAndExactRuleRestoration() throws {
        let home = try temporaryHome()
        let original = Data("# User instructions\nKeep this exact.\n\n".utf8)
        let codex = TokenSaverAgentRules.rulePaths(home: home)[2]
        try TokenSaverSettingsStore.replace(codex, data: original)
        var value = TokenSaverSettings()
        value.rtkEnabled = true
        value.cavemanMode = .ultra
        try TokenSaverSettingsStore.save(value, home: home)
        XCTAssertEqual(try TokenSaverSettingsStore.load(home: home), value)
        for url in TokenSaverAgentRules.rulePaths(home: home) {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.contains("run_command"))
            XCTAssertTrue(text.contains("creative writing"))
            XCTAssertTrue(text.contains("customer-care"))
        }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: TokenSaverSettingsStore.settingsURL(home: home).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        value.rtkEnabled = false
        try TokenSaverSettingsStore.save(value, home: home)
        XCTAssertEqual(try Data(contentsOf: codex), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: TokenSaverAgentRules.rulePaths(home: home)[0].path))
    }
    func testForeignManagedBlockAndCorruptionFailWithoutChanges() throws {
        let home = try temporaryHome()
        let codex = TokenSaverAgentRules.rulePaths(home: home)[2]
        let original = Data("<!-- AIUsage Token Saver BEGIN -->\nUser-owned edited block".utf8)
        try TokenSaverSettingsStore.replace(codex, data: original)
        var value = TokenSaverSettings(); value.rtkEnabled = true
        XCTAssertThrowsError(try TokenSaverSettingsStore.save(value, home: home))
        XCTAssertEqual(try Data(contentsOf: codex), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: TokenSaverAgentRules.rulePaths(home: home)[0].path))
        let settings = TokenSaverSettingsStore.settingsURL(home: home)
        try TokenSaverSettingsStore.replace(settings, data: Data("invalid".utf8))
        XCTAssertThrowsError(try TokenSaverSettingsStore.load(home: home))
        XCTAssertThrowsError(try TokenSaverSettingsStore.save(value, home: home))
        XCTAssertEqual(try Data(contentsOf: settings), Data("invalid".utf8))
    }
    func testEditedOwnedRulesAreNotOverwritten() throws {
        let home = try temporaryHome()
        var value = TokenSaverSettings(); value.rtkEnabled = true
        try TokenSaverSettingsStore.save(value, home: home)
        let url = TokenSaverAgentRules.rulePaths(home: home)[1]
        let edited = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "stdlib", with: "stdlib2") + "custom"
        // Change content inside ownership block rather than unrelated trailing text.
        let changed = edited.replacingOccurrences(of: "run_command", with: "custom_command")
        try Data(changed.utf8).write(to: url)
        value.rtkEnabled = false
        XCTAssertThrowsError(try TokenSaverSettingsStore.save(value, home: home))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), changed)
        XCTAssertTrue(try TokenSaverSettingsStore.load(home: home).rtkEnabled)
    }
    func testCavemanModesAndPonytailApplyWithoutRTK() throws {
        let home = try temporaryHome()
        var value = TokenSaverSettings()
        value.cavemanEnabled = true
        value.ponytailEnabled = true
        for mode in TokenSaverSettings.CavemanMode.allCases {
            value.cavemanMode = mode
            try TokenSaverSettingsStore.save(value, home: home)
            for path in TokenSaverAgentRules.rulePaths(home: home) {
                let rule = try String(contentsOf: path, encoding: .utf8)
                XCTAssertTrue(rule.contains("Caveman active mode: " + mode.rawValue))
                XCTAssertTrue(rule.contains("Ponytail"))
                XCTAssertTrue(rule.contains("customer-care"))
                XCTAssertFalse(rule.contains("rtk git"))
            }
        }
        try TokenSaverSettingsStore.save(.init(), home: home)
        for path in TokenSaverAgentRules.rulePaths(home: home) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        }
    }
    func testManagedWrapperIsExecutableAndRestored() throws {
        let home = try temporaryHome()
        var value = TokenSaverSettings(); value.rtkEnabled = true
        try TokenSaverSettingsStore.save(value, home: home)
        let wrapper = TokenSaverSettingsStore.settingsURL(home: home).deletingLastPathComponent().appendingPathComponent("bin/token-saver-rtk")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: wrapper.path))
        let process = Process()
        process.executableURL = wrapper
        process.arguments = ["/usr/bin/printf", "%s", "original tool output"]
        // No RTK on PATH: original command runs once, without any rewrites.
        process.environment = ["PATH": "/usr/bin:/bin"]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(data: output, encoding: .utf8), "original tool output")
        value.rtkEnabled = false
        try TokenSaverSettingsStore.save(value, home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wrapper.path))
    }
    func testSymlinkedParentRejected() throws {
        let home = try temporaryHome(), other = try temporaryHome()
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".codex"), withDestinationURL: other)
        var value = TokenSaverSettings(); value.rtkEnabled = true
        XCTAssertThrowsError(try TokenSaverSettingsStore.save(value, home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("AGENTS.md").path))
    }
    func testCompactPolicyBoundsUpstreamTextAndPreservesProvenance() throws {
        let home = try temporaryHome()
        let store = TokenSaverReleaseStore(root: home.appendingPathComponent("Library/Application Support/AIUsage/Rules"))
        let commit = String(repeating: "a", count: 40)
        let prose = Data(("name: fixture\n" + String(repeating: "VERBOSE_UPSTREAM_DO_NOT_INLINE\n", count: 1800)).utf8)
        for tool in [TokenSaverReleaseTool.caveman, .ponytail] {
            try store.stage(.init(tool: tool, version: "v1", commit: commit, isRelease: true), markdown: prose)
        }
        var value = TokenSaverSettings(); value.rtkEnabled = true; value.cavemanEnabled = true; value.ponytailEnabled = true
        for mode in TokenSaverSettings.CavemanMode.allCases {
            value.cavemanMode = mode
            try TokenSaverSettingsStore.save(value, home: home)
            let block = try String(contentsOf: TokenSaverAgentRules.rulePaths(home: home)[2], encoding: .utf8)
            XCTAssertTrue(block.utf8.count < 2400)
            XCTAssertFalse(block.contains("VERBOSE_UPSTREAM_DO_NOT_INLINE"))
            XCTAssertFalse(block.contains(commit))
            XCTAssertFalse(block.contains("reference commit:"))
            XCTAssertTrue(block.contains("signed history"))
            XCTAssertTrue(block.contains("accessibility"))
            XCTAssertTrue(block.contains("diagnostics"))
            XCTAssertTrue(block.contains("all other non-coding"))
        }
        XCTAssertEqual(try store.staged(.ponytail)?.markdown, prose)
    }
    func testLegacyOwnedLedgerMigratesAndRestoresUserInstructions() throws {
        let home = try temporaryHome(), codex = TokenSaverAgentRules.rulePaths(home: home)[2]
        let ledger = TokenSaverSettingsStore.settingsURL(home: home).deletingLastPathComponent().appendingPathComponent("token-saver-managed-block.txt")
        let legacy = "<!-- AIUsage Token Saver BEGIN -->\n" + String(repeating: "old full upstream prose\n", count: 500) + "<!-- AIUsage Token Saver END -->"
        try TokenSaverSettingsStore.replace(ledger, data: Data(legacy.utf8))
        try TokenSaverSettingsStore.replace(codex, data: Data(("# Keep user instructions\n" + legacy).utf8))
        var value = TokenSaverSettings(); value.ponytailEnabled = true
        try TokenSaverSettingsStore.save(value, home: home)
        XCTAssertFalse(try String(contentsOf: codex, encoding: .utf8).contains("old full upstream prose"))
        try TokenSaverSettingsStore.save(.init(), home: home)
        XCTAssertEqual(try String(contentsOf: codex, encoding: .utf8), "# Keep user instructions")
    }
    func testHermesExportIsExplicitAndDoesNotTouchOtherProfiles() throws {
        let home = try temporaryHome()
        let root = home.appendingPathComponent(".hermes/profiles/token-saver-test")
        let config = root.appendingPathComponent("config.yaml")
        let bot = home.appendingPathComponent(".hermes/profiles/bot-huy/workspace/HERMES.md")
        let botHuySoul = home.appendingPathComponent(".hermes/profiles/bot-huy/SOUL.md")
        let botVoxSoul = home.appendingPathComponent(".hermes/profiles/bot-vox/SOUL.md")
        let botScriptDoctorSoul = home.appendingPathComponent(".hermes/profiles/bot-script-doctor/SOUL.md")
        let globalSoul = TokenSaverAgentRules.hermesGlobalRuleURL(home: home)
        let global = home.appendingPathComponent("HERMES.md")
        try TokenSaverSettingsStore.replace(bot, data: Data("Keep bot exact".utf8))
        try TokenSaverSettingsStore.replace(botHuySoul, data: Data("Keep bot-huy SOUL exact".utf8))
        try TokenSaverSettingsStore.replace(botVoxSoul, data: Data("Keep bot-vox SOUL exact".utf8))
        try TokenSaverSettingsStore.replace(botScriptDoctorSoul, data: Data("Keep bot-script-doctor SOUL exact".utf8))
        try TokenSaverSettingsStore.replace(globalSoul, data: Data("# Global Hermes SOUL\nKeep header exact.".utf8))
        try TokenSaverSettingsStore.replace(global, data: Data("Keep global exact".utf8))
        var value = TokenSaverSettings(); value.rtkEnabled = true; value.cavemanEnabled = true
        try TokenSaverSettingsStore.save(value, home: home)
        let syncedGlobalSoul = try String(contentsOf: globalSoul, encoding: .utf8)
        XCTAssertTrue(syncedGlobalSoul.hasPrefix("# Global Hermes SOUL\nKeep header exact.\n"))
        XCTAssertTrue(syncedGlobalSoul.contains("Hermes terminal mappings"))
        XCTAssertEqual(try String(contentsOf: botHuySoul, encoding: .utf8), "Keep bot-huy SOUL exact")
        XCTAssertEqual(try String(contentsOf: botVoxSoul, encoding: .utf8), "Keep bot-vox SOUL exact")
        XCTAssertEqual(try String(contentsOf: botScriptDoctorSoul, encoding: .utf8), "Keep bot-script-doctor SOUL exact")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertThrowsError(try TokenSaverSettingsStore.exportHermesTestProfile(home: home))
        try TokenSaverSettingsStore.replace(config, data: Data("terminal: fixture-only\n".utf8))
        let target = try TokenSaverSettingsStore.exportHermesTestProfile(home: home)
        XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).contains("RTK:"))
        XCTAssertEqual(try String(contentsOf: bot, encoding: .utf8), "Keep bot exact")
        XCTAssertEqual(try String(contentsOf: global, encoding: .utf8), "Keep global exact")
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "terminal: fixture-only\n")
        value.cavemanMode = .ultra
        try TokenSaverSettingsStore.save(value, home: home)
        XCTAssertTrue(try String(contentsOf: globalSoul, encoding: .utf8).contains("Caveman active mode: ultra"))
        try TokenSaverSettingsStore.exportHermesTestProfile(home: home)
        XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).contains("Caveman active mode: ultra"))
        try TokenSaverSettingsStore.save(.init(), home: home)
        XCTAssertEqual(try String(contentsOf: globalSoul, encoding: .utf8), "# Global Hermes SOUL\nKeep header exact.")
        XCTAssertEqual(try String(contentsOf: botHuySoul, encoding: .utf8), "Keep bot-huy SOUL exact")
        XCTAssertEqual(try String(contentsOf: botVoxSoul, encoding: .utf8), "Keep bot-vox SOUL exact")
        XCTAssertEqual(try String(contentsOf: botScriptDoctorSoul, encoding: .utf8), "Keep bot-script-doctor SOUL exact")
        try TokenSaverSettingsStore.exportHermesTestProfile(home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testHermesExportAdoptsExactManualSnapshotButRejectsEditsAndLinks() throws {
        let home = try temporaryHome(), other = try temporaryHome()
        let root = home.appendingPathComponent(".hermes/profiles/token-saver-test")
        try TokenSaverSettingsStore.replace(root.appendingPathComponent("config.yaml"), data: Data("fixture".utf8))
        var value = TokenSaverSettings(); value.ponytailEnabled = true
        try TokenSaverSettingsStore.save(value, home: home)
        let target = root.appendingPathComponent("workspace/HERMES.md")
        let ledger = TokenSaverSettingsStore.settingsURL(home: home).deletingLastPathComponent().appendingPathComponent("token-saver-managed-block.txt")
        try TokenSaverSettingsStore.replace(target, data: Data(contentsOf: ledger) + Data("\n".utf8))
        try TokenSaverSettingsStore.exportHermesTestProfile(home: home)
        let edited = try Data(contentsOf: target) + Data("user changes".utf8)
        try TokenSaverSettingsStore.replace(target, data: edited)
        XCTAssertThrowsError(try TokenSaverSettingsStore.exportHermesTestProfile(home: home))
        XCTAssertEqual(try Data(contentsOf: target), edited)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other.appendingPathComponent("HERMES.md"))
        XCTAssertThrowsError(try TokenSaverSettingsStore.exportHermesTestProfile(home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("HERMES.md").path))
    }
    func testHermesExportRequiresManagedExecutableWrapper() throws {
        let home = try temporaryHome()
        let root = home.appendingPathComponent(".hermes/profiles/token-saver-test")
        try TokenSaverSettingsStore.replace(root.appendingPathComponent("config.yaml"), data: Data("fixture".utf8))
        var value = TokenSaverSettings(); value.rtkEnabled = true
        try TokenSaverSettingsStore.save(value, home: home)
        let wrapper = home.appendingPathComponent("Library/Application Support/AIUsage/bin/token-saver-rtk")
        try FileManager.default.removeItem(at: wrapper)
        XCTAssertThrowsError(try TokenSaverSettingsStore.exportHermesTestProfile(home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("workspace/HERMES.md").path))
    }
    func testHermesSearchReadMappingsMigrateOnlyOwnedTestProfile() throws {
        let home = try temporaryHome()
        let profile = home.appendingPathComponent(".hermes/profiles/token-saver-test")
        try TokenSaverSettingsStore.replace(profile.appendingPathComponent("config.yaml"), data: Data("fixture".utf8))
        var value = TokenSaverSettings(); value.rtkEnabled = true; value.cavemanEnabled = true; value.ponytailEnabled = true
        try TokenSaverSettingsStore.save(value, home: home)
        let base = try TokenSaverAgentRules.block(value, home: home)
        let target = profile.appendingPathComponent("workspace/HERMES.md")
        let owned = profile.appendingPathComponent(".aiusage-token-saver-owned.txt")
        // Migrate an exact legacy export, without changing generic/global rules.
        try TokenSaverSettingsStore.replace(target, data: Data((base + "\n").utf8))
        try TokenSaverSettingsStore.replace(owned, data: Data((base + "\n").utf8))
        try TokenSaverSettingsStore.exportHermesTestProfile(home: home)
        let text = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(text.contains("rg -n -- 'pattern' path"))
        XCTAssertTrue(text.contains("read --level minimal --max-lines 80 path"))
        XCTAssertTrue(text.contains("skip before editing"))
        XCTAssertTrue(text.contains("Exact bytes, editing context or sed line ranges: keep raw cat/sed"))
        XCTAssertTrue(text.contains("Never replace cat redirects/heredocs/file writes"))
        XCTAssertTrue(text.contains("terminal(command=...)"))
        XCTAssertTrue(text.contains("coding tasks only"))
        XCTAssertTrue(text.utf8.count < 3400)
        XCTAssertEqual(text.components(separatedBy: TokenSaverAgentRules.begin).count, 2)
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: owned))
        for path in TokenSaverAgentRules.rulePaths(home: home) {
            let generic = try String(contentsOf: path, encoding: .utf8)
            XCTAssertFalse(generic.contains("Hermes terminal mappings"))
            XCTAssertTrue(generic.contains("prefer rg -n -- 'pattern' path over grep/rg when semantics match"))
        }
        try TokenSaverSettingsStore.exportHermesTestProfile(home: home)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), text)
    }
    func testHermesMappingsRequireRTKAndQuoteHomePaths() throws {
        let home = try temporaryHome().appendingPathComponent("space and 'quote")
        var value = TokenSaverSettings(); value.cavemanEnabled = true
        XCTAssertEqual(try TokenSaverAgentRules.hermesBlock(value, home: home), try TokenSaverAgentRules.block(value, home: home))
        value.rtkEnabled = true
        let text = try TokenSaverAgentRules.hermesBlock(value, home: home)
        XCTAssertTrue(text.contains("'\"'\"'quote/Library/Application Support/AIUsage/bin/token-saver-rtk' read"))
        XCTAssertTrue(text.contains("--version once per session"))
        XCTAssertTrue(text.contains("does not prove RTK ran or saved tokens"))
        XCTAssertEqual(try TokenSaverAgentRules.hermesBlock(.init(), home: home), "")
    }
    func testOnboardingDistinguishesSavedMissingStaleOffAndUnsupported() throws {
        let home = try temporaryHome()
        var settings = TokenSaverSettings(); settings.rtkEnabled = true
        let offSnapshot = TokenSaverOnboarding.inspect(home: home, harness: .codex)
        XCTAssertEqual(offSnapshot.rules, .off)
        XCTAssertEqual(offSnapshot.agentCommands, nil)
        try TokenSaverSettingsStore.save(settings, home: home)
        for harness in [TokenSaverOnboarding.Harness.codex, .claude, .antigravity, .openCode, .hermes] {
            let snapshot = TokenSaverOnboarding.inspect(home: home, harness: harness)
            XCTAssertEqual(snapshot.rules, .current)
            XCTAssertTrue(snapshot.wrapperReady)
            XCTAssertEqual(snapshot.historyRecords, nil)
            XCTAssertTrue(snapshot.agentCommands?.contains("without reading") == true)
            XCTAssertTrue(snapshot.agentCommands?.contains("not proof of automatic prompt loading") == true)
            XCTAssertTrue(snapshot.agentCommands?.contains("--version") == true)
            XCTAssertFalse(snapshot.agentCommands?.contains("rg -n") == true)
            XCTAssertFalse(snapshot.agentCommands?.contains("AIUsage Token Saver") == true)
        }
        // Caveman-only and Ponytail-only configurations must allow the rule-awareness diagnostic without requiring RTK/wrapper.
        var cavemanOnly = TokenSaverSettings(); cavemanOnly.cavemanEnabled = true
        var ponytailOnly = TokenSaverSettings(); ponytailOnly.ponytailEnabled = true
        for nonRTK in [cavemanOnly, ponytailOnly] {
            try TokenSaverSettingsStore.save(nonRTK, home: home)
            let nonRTKSnapshot = TokenSaverOnboarding.inspect(home: home, harness: .codex)
            XCTAssertEqual(nonRTKSnapshot.rules, .current)
            XCTAssertFalse(nonRTKSnapshot.wrapperReady)
            XCTAssertTrue(nonRTKSnapshot.agentCommands?.contains("without reading") == true)
            XCTAssertFalse(nonRTKSnapshot.agentCommands?.contains("--version") == true)
            XCTAssertFalse(nonRTKSnapshot.agentCommands?.contains("token-saver-rtk") == true)
        }
        try TokenSaverSettingsStore.save(settings, home: home)
        XCTAssertEqual(TokenSaverOnboarding.Harness.allCases, [.codex, .claude, .antigravity, .openCode, .hermes])
        let codex = TokenSaverOnboarding.Harness.codex.rulesURL(home: home)!
        let edited = Data("unrelated instructions".utf8)
        try TokenSaverSettingsStore.replace(codex, data: edited)
        let stale = TokenSaverOnboarding.inspect(home: home, harness: .codex)
        XCTAssertEqual(stale.rules, .stale)
        XCTAssertEqual(stale.agentCommands, nil)
        XCTAssertEqual(try Data(contentsOf: codex), edited)
        try TokenSaverSettingsStore.replace(TokenSaverSettingsStore.settingsURL(home: home), data: Data("bad json".utf8))
        XCTAssertEqual(TokenSaverOnboarding.inspect(home: home, harness: .codex).rules, .unreadable)
    }
    func testOnboardingHistoryIsReadOnlyAggregateAndUnknownStaysUnknown() throws {
        let home = try temporaryHome()
        let url = home.appendingPathComponent("Library/Application Support/rtk/history.db")
        XCTAssertEqual(TokenSaverOnboarding.inspect(home: home, harness: .codex).historyRecords, nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE commands(id INTEGER);", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertEqual(TokenSaverOnboarding.inspect(home: home, harness: .codex).historyRecords, 0)
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO commands VALUES(1),(2);", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: url)
        XCTAssertEqual(TokenSaverOnboarding.inspect(home: home, harness: .hermes).historyRecords, 2)
        XCTAssertEqual(try Data(contentsOf: url), before)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: home.appendingPathComponent("elsewhere.db"))
        XCTAssertEqual(TokenSaverOnboarding.inspect(home: home, harness: .codex).historyRecords, nil)
    }
    func testOnboardingWALAndSHMSidecarsAreNeverCreatedOrModified() throws {
        let home = try temporaryHome().appendingPathComponent("space # and ? 'quote")
        let url = home.appendingPathComponent("Library/Application Support/rtk/history.db")
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE commands(id INTEGER); INSERT INTO commands VALUES(1),(2);", nil, nil, nil), SQLITE_OK)
        var persist: Int32 = 1
        XCTAssertEqual(sqlite3_file_control(db, nil, SQLITE_FCNTL_PERSIST_WAL, &persist), SQLITE_OK)
        sqlite3_close(db)
        let wal = URL(fileURLWithPath: url.path + "-wal"), shm = URL(fileURLWithPath: url.path + "-shm")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wal.path))
        if FileManager.default.fileExists(atPath: shm.path) { try FileManager.default.removeItem(at: shm) }
        let beforeDB = try Data(contentsOf: url), beforeWAL = try Data(contentsOf: wal)
        let beforeEntries = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(TokenSaverOnboarding.inspect(home: home, harness: .codex).historyRecords, nil)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), beforeEntries)
        XCTAssertEqual(try Data(contentsOf: url), beforeDB)
        XCTAssertEqual(try Data(contentsOf: wal), beforeWAL)
        // A closed/checkpointed WAL-mode main DB, without sidecars, is copied privately.
        try FileManager.default.removeItem(at: wal)
        XCTAssertEqual(TokenSaverOnboarding.inspect(home: home, harness: .codex).historyRecords, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shm.path))
        XCTAssertEqual(try Data(contentsOf: url), beforeDB)
    }
    func testOnboardingRejectsChangedWrapperAndMalformedHistory() throws {
        let home = try temporaryHome()
        var settings = TokenSaverSettings(); settings.rtkEnabled = true
        try TokenSaverSettingsStore.save(settings, home: home)
        let wrapper = home.appendingPathComponent("Library/Application Support/AIUsage/bin/token-saver-rtk")
        try TokenSaverSettingsStore.replace(wrapper, data: Data("#!/bin/sh\nexit 0".utf8))
        let db = home.appendingPathComponent("Library/Application Support/rtk/history.db")
        try TokenSaverSettingsStore.replace(db, data: Data("not sqlite".utf8))
        let snapshot = TokenSaverOnboarding.inspect(home: home, harness: .codex)
        XCTAssertFalse(snapshot.wrapperReady)
        XCTAssertEqual(snapshot.historyRecords, nil)
        XCTAssertEqual(snapshot.rules, .current)
        XCTAssertEqual(snapshot.agentCommands, nil)
    }
    func testHermesExportRejectsCorruptMatchingOwnershipLedger() throws {
        let home = try temporaryHome()
        let root = home.appendingPathComponent(".hermes/profiles/token-saver-test")
        try TokenSaverSettingsStore.replace(root.appendingPathComponent("config.yaml"), data: Data("fixture".utf8))
        let target = root.appendingPathComponent("workspace/HERMES.md")
        let state = root.appendingPathComponent(".aiusage-token-saver-owned.txt")
        for corrupt in [Data("user instructions without ownership markers".utf8), Data([0xff, 0xfe])] {
            try TokenSaverSettingsStore.replace(target, data: corrupt)
            try TokenSaverSettingsStore.replace(state, data: corrupt)
            XCTAssertThrowsError(try TokenSaverSettingsStore.exportHermesTestProfile(home: home))
            XCTAssertEqual(try Data(contentsOf: target), corrupt)
        }
    }
    func testEnabledToolCountAndNotificationContract() throws {
        let home = try temporaryHome()
        let otherHome = try temporaryHome()
        var s = TokenSaverSettings()
        XCTAssertEqual(s.enabledToolCount, 0)
        s.rtkEnabled = true
        XCTAssertEqual(s.enabledToolCount, 1)
        s.cavemanEnabled = true
        XCTAssertEqual(s.enabledToolCount, 2)
        s.ponytailEnabled = true
        XCTAssertEqual(s.enabledToolCount, 3)

        var receivedHomes: [String] = []
        var receivedOrigins: [String?] = []
        let token = NotificationCenter.default.addObserver(
            forName: .tokenSaverSettingsDidChange,
            object: nil,
            queue: nil
        ) { note in
            if let h = note.userInfo?["home"] as? String {
                receivedHomes.append(h)
                receivedOrigins.append(note.userInfo?["origin"] as? String)
            }
        }
        addTeardownBlock { NotificationCenter.default.removeObserver(token) }

        let originA = UUID()
        let updated1 = try TokenSaverSettingsStore.update(home: home, origin: originA) { $0.rtkEnabled = true }
        XCTAssertTrue(updated1.rtkEnabled)
        XCTAssertFalse(updated1.ponytailEnabled)
        XCTAssertEqual(receivedHomes, [TokenSaverSettingsStore.canonicalHomePath(home)])
        XCTAssertEqual(receivedOrigins, [originA.uuidString])

        let originB = UUID()
        let updated2 = try TokenSaverSettingsStore.update(home: home, origin: originB) { $0.ponytailEnabled = true }
        XCTAssertTrue(updated2.rtkEnabled)
        XCTAssertTrue(updated2.ponytailEnabled)
        XCTAssertEqual(receivedHomes.count, 2)
        XCTAssertEqual(receivedOrigins.last ?? nil, originB.uuidString)

        // Failed save must emit zero notifications and keep otherHome untouched.
        let settingsFile = TokenSaverSettingsStore.settingsURL(home: otherHome)
        try TokenSaverSettingsStore.replace(settingsFile, data: Data("corrupt".utf8))
        let countBeforeFailure = receivedHomes.count
        XCTAssertThrowsError(try TokenSaverSettingsStore.save(s, home: otherHome))
        XCTAssertThrowsError(try TokenSaverSettingsStore.update(home: otherHome) { $0.rtkEnabled = true })
        XCTAssertEqual(receivedHomes.count, countBeforeFailure)

        // Rules-only inspection reuses cached history count when includeHistory is false.
        let snapCached = TokenSaverOnboarding.inspect(
            home: home,
            harness: .codex,
            includeHistory: false,
            cachedHistoryRecords: 42
        )
        XCTAssertEqual(snapCached.rules, .current)
        XCTAssertEqual(snapCached.historyRecords, 42)
    }
    func testAntigravityGlobalConfigRulePathAndLegacyCleanup() throws {
        let home = try temporaryHome()
        let agyConfigURL = home.appendingPathComponent(".gemini/config/AGENTS.md")
        let legacyURL = home.appendingPathComponent(".gemini/antigravity/rules/aiusage-token-saver.md")
        XCTAssertEqual(TokenSaverOnboarding.Harness.antigravity.rulesURL(home: home), agyConfigURL)

        let existingHeader = Data("# Antigravity Global Guidelines\nKeep this matrix intact.\n".utf8)
        try TokenSaverSettingsStore.replace(agyConfigURL, data: existingHeader)

        var active = TokenSaverSettings()
        active.rtkEnabled = true
        active.cavemanEnabled = true
        active.cavemanMode = .lite
        active.ponytailEnabled = true
        try TokenSaverSettingsStore.save(active, home: home)

        let savedText = try String(contentsOf: agyConfigURL, encoding: .utf8)
        XCTAssertTrue(savedText.hasPrefix("# Antigravity Global Guidelines\nKeep this matrix intact.\n"))
        XCTAssertTrue(savedText.contains("Caveman active mode: lite."))
        XCTAssertEqual(TokenSaverOnboarding.inspect(home: home, harness: .antigravity).rules, .current)

        // Simulate upgrade from legacy .gemini/antigravity/rules/aiusage-token-saver.md with reapply (oldBlock == newBlock):
        try TokenSaverSettingsStore.replace(agyConfigURL, data: existingHeader)
        let block = try TokenSaverAgentRules.block(active, home: home)
        try TokenSaverSettingsStore.replace(legacyURL, data: Data(("\n" + block).utf8))
        XCTAssertEqual(TokenSaverOnboarding.inspect(home: home, harness: .antigravity).rules, .stale)

        _ = try TokenSaverSettingsStore.update(home: home) { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertEqual(TokenSaverOnboarding.inspect(home: home, harness: .antigravity).rules, .current)

        // Turning all tools off restores ~/.gemini/config/AGENTS.md byte-for-byte.
        try TokenSaverSettingsStore.save(TokenSaverSettings(), home: home)
        XCTAssertEqual(try Data(contentsOf: agyConfigURL), existingHeader)
    }
}
