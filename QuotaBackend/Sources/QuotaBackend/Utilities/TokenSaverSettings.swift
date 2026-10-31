import Foundation

/// Opt-in only. A corrupt file must never enable compression or broaden scope.
public struct TokenSaverSettings: Codable, Equatable, Sendable {
    public enum CavemanMode: String, Codable, CaseIterable, Sendable { case lite, full, ultra }
    public var rtkEnabled = false
    public var cavemanEnabled = false
    public var cavemanMode: CavemanMode = .full
    public var ponytailEnabled = false
    public let codingOnlyScope = true
    public init() {}

    public var enabledToolCount: Int {
        (rtkEnabled ? 1 : 0) + (cavemanEnabled ? 1 : 0) + (ponytailEnabled ? 1 : 0)
    }

    enum CodingKeys: String, CodingKey {
        case rtkEnabled, cavemanEnabled, cavemanMode, ponytailEnabled, codingOnlyScope
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rtkEnabled = try c.decodeIfPresent(Bool.self, forKey: .rtkEnabled) ?? false
        cavemanEnabled = try c.decodeIfPresent(Bool.self, forKey: .cavemanEnabled) ?? false
        cavemanMode = try c.decodeIfPresent(CavemanMode.self, forKey: .cavemanMode) ?? .full
        ponytailEnabled = try c.decodeIfPresent(Bool.self, forKey: .ponytailEnabled) ?? false
        // Intentionally ignore a false codingOnlyScope in old/edited settings.
    }
}

public extension Notification.Name {
    static let tokenSaverSettingsDidChange = Notification.Name("AIUsage.tokenSaverSettingsDidChange")
}

public enum TokenSaverSettingsStore {
    private static let lock = NSRecursiveLock()
    public static func canonicalHomePath(_ home: URL) -> String {
        home.standardizedFileURL.resolvingSymlinksInPath().path
    }
    private static func notificationUserInfo(home: URL, origin: UUID?) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = ["home": canonicalHomePath(home)]
        if let origin { info["origin"] = origin.uuidString }
        return info
    }
    public static func settingsURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/AIUsage/token-saver-settings.json")
    }
    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> TokenSaverSettings {
        lock.lock(); defer { lock.unlock() }
        let url = settingsURL(home: home)
        guard let data = try contents(url) else { return .init() }
        return try JSONDecoder().decode(TokenSaverSettings.self, from: data)
    }
    public static func save(
        _ settings: TokenSaverSettings,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        origin: UUID? = nil
    ) throws {
        do {
            lock.lock(); defer { lock.unlock() }
            try saveLocked(settings, home: home)
        }
        NotificationCenter.default.post(
            name: .tokenSaverSettingsDidChange,
            object: nil,
            userInfo: notificationUserInfo(home: home, origin: origin)
        )
    }
    @discardableResult
    public static func update(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        origin: UUID? = nil,
        _ transform: (inout TokenSaverSettings) throws -> Void
    ) throws -> TokenSaverSettings {
        let updated: TokenSaverSettings
        do {
            lock.lock(); defer { lock.unlock() }
            var current = try load(home: home)
            try transform(&current)
            try saveLocked(current, home: home)
            updated = current
        }
        NotificationCenter.default.post(
            name: .tokenSaverSettingsDidChange,
            object: nil,
            userInfo: notificationUserInfo(home: home, origin: origin)
        )
        return updated
    }
    private static func saveLocked(_ settings: TokenSaverSettings, home: URL) throws {
        let previous = try load(home: home)
        let url = settingsURL(home: home)
        try rejectSymlinks(url)
        let blockURL = settingsURL(home: home).deletingLastPathComponent().appendingPathComponent("token-saver-managed-block.txt")
        let ledgerData = try contents(blockURL)
        guard ledgerData == nil || String(data: ledgerData!, encoding: .utf8) != nil else { throw Failure.changed }
        let oldBlock = ledgerData.flatMap { String(data: $0, encoding: .utf8) } ?? TokenSaverAgentRules.block(previous)
        let newBlock = try TokenSaverAgentRules.block(settings, home: home)
        var changes = try TokenSaverAgentRules.changes(from: oldBlock, to: newBlock, home: home)
        let hermesBlockURL = settingsURL(home: home).deletingLastPathComponent().appendingPathComponent("token-saver-hermes-managed-block.txt")
        let hermesLedgerData = try contents(hermesBlockURL)
        guard hermesLedgerData == nil || String(data: hermesLedgerData!, encoding: .utf8) != nil else { throw Failure.changed }
        let hermesGlobalURL = TokenSaverAgentRules.hermesGlobalRuleURL(home: home)
        let hermesGlobalBefore = try contents(hermesGlobalURL)
        let hermesGlobalHasMarkers = hermesGlobalBefore.flatMap { String(data: $0, encoding: .utf8) }.map {
            $0.contains(TokenSaverAgentRules.begin) || $0.contains(TokenSaverAgentRules.end)
        } ?? false
        let oldHermesBlock = hermesLedgerData.flatMap { String(data: $0, encoding: .utf8) }
            ?? (hermesGlobalHasMarkers ? ((try? TokenSaverAgentRules.hermesBlock(previous, home: home)) ?? "") : "")
        let newHermesBlock = try TokenSaverAgentRules.hermesBlock(settings, home: home)
        if let hermesChange = try TokenSaverAgentRules.singleChange(url: hermesGlobalURL, from: oldHermesBlock, to: newHermesBlock) {
            changes.append(hermesChange)
        }
        let wrapper = settingsURL(home: home).deletingLastPathComponent().appendingPathComponent("bin/token-saver-rtk")
        let wrapperBefore = try contents(wrapper)
        let wrapperAfter = settings.rtkEnabled ? Data(TokenSaverAgentRules.rtkWrapper.utf8) : nil
        if wrapperBefore != wrapperAfter {
            guard wrapperBefore == nil || wrapperBefore == Data(TokenSaverAgentRules.rtkWrapper.utf8) else { throw Failure.changed }
            changes.append((wrapper, wrapperBefore, wrapperAfter))
        }
        let oldLedger = try contents(blockURL)
        changes.append((blockURL, oldLedger, newBlock.isEmpty ? nil : Data(newBlock.utf8)))
        let oldHermesLedger = try contents(hermesBlockURL)
        let newHermesLedger = newHermesBlock.isEmpty ? nil : Data(newHermesBlock.utf8)
        if oldHermesLedger != newHermesLedger {
            changes.append((hermesBlockURL, oldHermesLedger, newHermesLedger))
        }
        let settingsBefore = try contents(url)
        var applied: [(URL, Data?, Data?)] = []
        do {
            for (target, before, after) in changes {
                guard try contents(target) == before else { throw Failure.changed }
                try replace(target, data: after)
                applied.append((target, before, after))
                if target == wrapper, after != nil {
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
                }
            }
            guard try contents(url) == settingsBefore else { throw Failure.changed }
            try replace(url, data: JSONEncoder().encode(settings))
        } catch {
            for (target, before, after) in applied.reversed() {
                if (try? contents(target)) == after { try? replace(target, data: before) }
            }
            throw error
        }
    }
    /// Explicit test-only export. Never discovers or edits a bot/global Hermes profile.
    @discardableResult
    public static func exportHermesTestProfile(home: URL) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let profile = home.appendingPathComponent(".hermes/profiles/token-saver-test")
        let config = profile.appendingPathComponent("config.yaml")
        guard try contents(config) != nil else { throw Failure.missingHermesProfile }
        let target = profile.appendingPathComponent("workspace/HERMES.md")
        let state = profile.appendingPathComponent(".aiusage-token-saver-owned.txt")
        let before = try contents(target), owned = try contents(state)
        let source = try contents(settingsURL(home: home).deletingLastPathComponent().appendingPathComponent("token-saver-managed-block.txt"))
        // Adopt only the exact prior manual export; never replace unrelated project instructions.
        if let before {
            guard let expected = owned ?? source,
                  let text = String(data: expected, encoding: .utf8),
                  text.hasPrefix(TokenSaverAgentRules.begin + "\n"),
                  text.trimmingCharacters(in: .newlines).hasSuffix(TokenSaverAgentRules.end),
                  text.components(separatedBy: TokenSaverAgentRules.begin).count == 2,
                  text.components(separatedBy: TokenSaverAgentRules.end).count == 2,
                  before == expected || before == expected + Data("\n".utf8) else { throw Failure.changed }
        } else if owned != nil { throw Failure.changed }
        let settings = try load(home: home)
        if settings.rtkEnabled {
            let wrapper = settingsURL(home: home).deletingLastPathComponent().appendingPathComponent("bin/token-saver-rtk")
            guard try contents(wrapper) == Data(TokenSaverAgentRules.rtkWrapper.utf8),
                  FileManager.default.isExecutableFile(atPath: wrapper.path) else { throw Failure.missingRTKWrapper }
        }
        let block = try TokenSaverAgentRules.hermesBlock(settings, home: home)
        let after = block.isEmpty ? nil : Data((block + "\n").utf8)
        var applied: [(URL, Data?, Data?)] = []
        do {
            for (url, old, new) in [(target, before, after), (state, owned, after)] {
                guard try contents(url) == old else { throw Failure.changed }
                try replace(url, data: new)
                applied.append((url, old, new))
            }
        } catch {
            for (url, old, new) in applied.reversed() {
                if (try? contents(url)) == new { try? replace(url, data: old) }
            }
            throw error
        }
        return target
    }
    static func contents(_ url: URL) throws -> Data? {
        try rejectSymlinks(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
    static func rejectSymlinks(_ url: URL) throws {
        var path = url.standardizedFileURL
        while path.path != "/" {
            // macOS system aliases are root-owned; URL canonicalization maps /private/var back to /var.
            if let expected = ["/var": "private/var", "/tmp": "private/tmp"][path.path] {
                let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: path.path)
                guard (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
                      target == expected || target == "/" + expected else { throw Failure.symlink }
                break
            }
            if (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw Failure.symlink }
            path.deleteLastPathComponent()
        }
    }
    static func replace(_ url: URL, data: Data?) throws {
        try rejectSymlinks(url)
        let fm = FileManager.default
        if let data {
            let permissions = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? 0o600
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        } else if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }
    enum Failure: LocalizedError {
        case changed, symlink, missingHermesProfile, missingRTKWrapper
        var errorDescription: String? {
            switch self {
            case .changed: "Token Saver rule was edited externally. Preserve it and resolve the AIUsage managed block before retrying."
            case .symlink: "Token Saver will not replace symlinked settings or rules."
            case .missingHermesProfile: "Create the dedicated Hermes token-saver-test profile first. No bot or default profile is modified."
            case .missingRTKWrapper: "Enable RTK in AIUsage first; the managed executable wrapper is required before exporting Hermes test rules."
            }
        }
    }
}

/// Adds only an owned block. Existing instructions are never replaced.
public enum TokenSaverAgentRules {
    public static let rtkWrapper = """
    #!/bin/zsh
    # AIUsage-owned explicit RTK wrapper. No aliases, PATH mutation or retry.
    set -eu
    if (( $# == 0 )); then exit 64; fi
    if command -v rtk >/dev/null 2>&1; then
        exec rtk "$@"
    fi
    exec "$@"
    """ + "\n"
    static let begin = "<!-- AIUsage Token Saver BEGIN -->"
    static let end = "<!-- AIUsage Token Saver END -->"
    public static func rulePaths(home: URL) -> [URL] {
        [".gemini/config/AGENTS.md", ".claude/rules/aiusage-token-saver.md",
         ".codex/AGENTS.md", ".config/opencode/AGENTS.md"].map { home.appendingPathComponent($0) }
    }
    static func legacyAntigravityRuleURL(home: URL) -> URL {
        home.appendingPathComponent(".gemini/antigravity/rules/aiusage-token-saver.md")
    }
    /// Global Hermes coding instructions (`~/.hermes/SOUL.md`). Custom profiles under `~/.hermes/profiles/*`
    /// have their own isolated `SOUL.md` and are never touched.
    public static func hermesGlobalRuleURL(home: URL) -> URL {
        home.appendingPathComponent(".hermes/SOUL.md")
    }
    public static func block(_ s: TokenSaverSettings) -> String {
        // Built-in policy remains usable before downloading any upstream skill.
        (try? block(s, home: nil)) ?? ""
    }
    static func block(_ s: TokenSaverSettings, home: URL?) throws -> String {
        guard s.rtkEnabled || s.cavemanEnabled || s.ponytailEnabled else { return "" }
        var sections = [begin, "# Token Saver — coding work only",
            "Apply only to implementing, testing, debugging or reviewing code. Exclude creative writing, scriptwriting, lyrics, customer-care chat and all other non-coding work; preserve their tone."]
        if s.rtkEnabled {
            if let home {
                let wrapper = settingsPathForWrapper(home)
                sections.append("RTK: use \(wrapper) for supported coding commands (git status/diff/log, ls, rg, pytest; prefer rg -n -- 'pattern' path over grep/rg when semantics match). Antigravity: run_command (zsh). Quote the wrapper path. Do not wrap unsupported commands; run them directly. If RTK is absent, run the original once. Preserve exit status/diagnostics; no aliases, PATH changes, interception or automatic replay.")
            } else {
                sections.append("RTK: use rtk git status/diff/log, rtk ls, rtk rg (prefer over grep when semantics match) or rtk pytest when installed and supported; otherwise run the original once. Antigravity: run_command (zsh). Keep exit status/diagnostics; no aliases, PATH changes or automatic replay.")
            }
        }
        for tool in [TokenSaverReleaseTool.caveman, .ponytail] {
            let enabled = tool == .caveman ? s.cavemanEnabled : s.ponytailEnabled
            guard enabled else { continue }
            if let home, let staged = try TokenSaverReleaseStore(root: home.appendingPathComponent("Library/Application Support/AIUsage/Rules")).staged(tool),
               let text = String(data: staged.markdown, encoding: .utf8) {
                guard !text.contains(begin), !text.contains(end) else { throw TokenSaverSettingsStore.Failure.changed }
                // Full upstream skills and reference commit SHAs stay in local receipts, never injected into prompts.
            }
            if tool == .caveman {
                let mode: String
                switch s.cavemanMode {
                case .lite: mode = "Concise natural sentences. Drop greetings and filler, retain essential explanations."
                case .full: mode = "Terse direct prose. Omit filler and repetition; keep required context and actionable facts."
                case .ultra: mode = "Minimum prose: compact bullets or fragments. Never sacrifice correctness, necessary caveats or instructions."
                }
                sections.append("Caveman active mode: \(s.cavemanMode.rawValue). \(mode) Keep the user's language and exact code, commands, paths, errors, security warnings and requested detail.")
            } else {
                sections.append("Ponytail: YAGNI; reuse project helpers, then stdlib/native features and existing dependencies. Trace callers/root cause; make the smallest correct change and run a check. No speculative abstractions or dependencies. Keep validation, security, accessibility and required behavior.")
            }
        }
        sections.append("Report actual tool/test results; do not invent token savings. No request/response or signed history rewriting. Scope reminder: all policies above are coding-only.")
        sections.append(end)
        return sections.joined(separator: "\n")
    }
    static func hermesBlock(_ settings: TokenSaverSettings, home: URL) throws -> String {
        let base = try block(settings, home: home)
        guard settings.rtkEnabled else { return base }
        let wrapper = settingsPathForWrapper(home)
        let mappings = """
        Hermes terminal mappings (coding tasks only): check wrapper --version once per session. Search: prefer \(wrapper) rg -n -- 'pattern' path over grep/rg with matching semantics. Read-only preview (skip before editing): \(wrapper) read --level minimal --max-lines 80 path. Exact bytes, editing context or sed line ranges: keep raw cat/sed; previews omit source. Never replace cat redirects/heredocs/file writes. Use terminal(command=...) with quoted wrapper paths. Keep bash/node/test scripts direct; no automatic retries. Rules loaded does not prove RTK ran or saved tokens.
        """
        return base.replacingOccurrences(of: end, with: mappings + "\n" + end)
    }
    static func settingsPathForWrapper(_ home: URL) -> String {
        // Shell single-quote escaping protects user home paths with spaces or quotes.
        let path = home.appendingPathComponent("Library/Application Support/AIUsage/bin/token-saver-rtk").path
        return "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
    static func singleChange(url: URL, from oldBlock: String, to newBlock: String) throws -> (URL, Data?, Data?)? {
        guard oldBlock != newBlock || !newBlock.isEmpty else { return nil }
        let before = try TokenSaverSettingsStore.contents(url)
        guard var text = before.flatMap({ String(data: $0, encoding: .utf8) }) ?? (before == nil ? "" : nil) else {
            throw TokenSaverSettingsStore.Failure.changed
        }
        if text.contains(begin) || text.contains(end) {
            let owned = "\n" + oldBlock
            guard !oldBlock.isEmpty, text.components(separatedBy: owned).count == 2,
                  text.components(separatedBy: begin).count == 2,
                  text.components(separatedBy: end).count == 2 else {
                throw TokenSaverSettingsStore.Failure.changed
            }
            text = text.replacingOccurrences(of: owned, with: newBlock.isEmpty ? "" : "\n" + newBlock)
        } else if !newBlock.isEmpty {
            text += "\n" + newBlock
        }
        let after = text.isEmpty ? nil : Data(text.utf8)
        return before == after ? nil : (url, before, after)
    }
    static func changes(from oldBlock: String, to newBlock: String, home: URL) throws -> [(URL, Data?, Data?)] {
        guard oldBlock != newBlock || !newBlock.isEmpty else { return [] }
        var result = try rulePaths(home: home).compactMap { url in
            try singleChange(url: url, from: oldBlock, to: newBlock)
        }
        if !oldBlock.isEmpty,
           let legacyCleanup = try singleChange(url: legacyAntigravityRuleURL(home: home), from: oldBlock, to: "") {
            result.append(legacyCleanup)
        }
        return result
    }
}
