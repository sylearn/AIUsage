import Foundation
import CryptoKit
import Darwin
#if canImport(QuotaBackend)
import QuotaBackend
#endif

// MARK: - Claude Desktop official 3P profile transaction

struct ClaudeDesktopCatalogEntry: Equatable, Identifiable {
    let id: String
    let upstreamModel: String
    let displayName: String
    let supports1M: Bool
}

/// The exact model values passed into a Claude product Gateway. Smart mode
/// exposes stable app routes; full mode exposes only real node model IDs.
struct ClaudeProductGatewayCatalogProjection {
    let availableModels: [String]
    let defaultModel: String?
    let supports1MModels: [String]
}

struct ClaudeDesktopInstallation: Equatable {
    let appURL: URL?
    let version: String?

    var isInstalled: Bool { appURL != nil }

    static func inspect(workspace: FileManager = .default) -> ClaudeDesktopInstallation {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Claude.app"),
            workspace.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Claude.app"),
        ]
        guard let url = candidates.first(where: { workspace.fileExists(atPath: $0.path) }) else {
            return ClaudeDesktopInstallation(appURL: nil, version: nil)
        }
        let bundle = Bundle(url: url)
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return ClaudeDesktopInstallation(appURL: url, version: version)
    }
}

enum ClaudeDesktopProfileError: LocalizedError {
    case desktopNotInstalled
    case invalidJSONObject(String)
    case profileOwnedByAnotherTool
    case profileChangedExternally(String)
    case noRestoreJournal
    case lockUnavailable
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .desktopNotInstalled:
            return AppSettings.shared.t(
                "Claude Desktop is not installed in Applications.",
                "未在「应用程序」中找到 Claude Desktop。"
            )
        case .invalidJSONObject(let name):
            return AppSettings.shared.t(
                "Claude Desktop configuration \(name) is not a JSON object. Nothing was changed.",
                "Claude Desktop 配置 \(name) 不是 JSON 对象，未做任何修改。"
            )
        case .profileOwnedByAnotherTool:
            return AppSettings.shared.t(
                "Claude Desktop is now using a profile selected by another tool. AIUsage did not overwrite it.",
                "Claude Desktop 已被其它工具切换到另一份配置，AIUsage 没有覆盖它。"
            )
        case .profileChangedExternally(let name):
            return AppSettings.shared.t(
                "Claude Desktop configuration \(name) changed outside AIUsage. It was left untouched.",
                "Claude Desktop 配置 \(name) 已被外部修改，AIUsage 未覆盖它。"
            )
        case .noRestoreJournal:
            return AppSettings.shared.t("No AIUsage Desktop connection is recorded.", "没有可恢复的 AIUsage Desktop 连接记录。")
        case .lockUnavailable:
            return AppSettings.shared.t("Claude Desktop configuration is busy. Try again in a moment.", "Claude Desktop 配置正忙，请稍后重试。")
        case .verificationFailed(let reason):
            return AppSettings.shared.t(
                "Claude Desktop configuration verification failed: \(reason)",
                "Claude Desktop 配置校验失败：\(reason)"
            )
        }
    }

    var isExternalConflict: Bool {
        switch self {
        case .profileOwnedByAnotherTool, .profileChangedExternally:
            return true
        default:
            return false
        }
    }
}

final class ClaudeDesktopProfileStore {
    static let shared = ClaudeDesktopProfileStore()
    private static let journalVersion = 2

    /// Stable forever after release.  A stable identity avoids duplicate
    /// entries when users alternate between AIUsage and another profile tool.
    static let profileID = "a1a5a9e0-7c1d-4e5f-9a0b-c1d2e3f4a5b6"
    static let profileName = "AIUsage Gateway"
    // Desktop infers Effort / Thinking from family SKUs. These IDs must stay
    // `claude-opus-*` / `claude-sonnet-*` / `claude-haiku-*` / `claude-fable-*`;
    // compact `claude-aiusage*` names appear in the menu but never unlock those
    // controls. `claude-sonnet-4-6` remains a Sonnet alias in the gateway.
    static let defaultRouteID = "claude-fable-5"
    static let opusRouteID = "claude-opus-5"
    static let sonnetRouteID = "claude-sonnet-5"
    static let haikuRouteID = "claude-haiku-4-5"
    // Claude Code pretty-prints known family SKUs in the status bar
    // (`claude-opus-5` → "Opus 5"). Compact IDs stay off that table so the
    // `/v1/models` display_name and `*_MODEL_NAME` aliases remain "AIUsage *".
    static let codeDefaultRouteID = "claude-aiusage"
    static let codeOpusRouteID = "claude-aiusage-opus"
    static let codeSonnetRouteID = "claude-aiusage-sonnet"
    static let codeHaikuRouteID = "claude-aiusage-haiku"

    struct Paths {
        let normalConfig: URL
        let threePConfig: URL
        let meta: URL
        let profile: URL
        let journal: URL
        let lock: URL

        init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
            let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
            let normalRoot = appSupport.appendingPathComponent("Claude", isDirectory: true)
            let threePRoot = appSupport.appendingPathComponent("Claude-3p", isDirectory: true)
            let library = threePRoot.appendingPathComponent("configLibrary", isDirectory: true)
            let stateRoot = home.appendingPathComponent(".config/aiusage/claude-desktop", isDirectory: true)
            normalConfig = normalRoot.appendingPathComponent("claude_desktop_config.json")
            threePConfig = threePRoot.appendingPathComponent("claude_desktop_config.json")
            meta = library.appendingPathComponent("_meta.json")
            profile = library.appendingPathComponent("\(ClaudeDesktopProfileStore.profileID).json")
            journal = stateRoot.appendingPathComponent("restore-state.json")
            lock = stateRoot.appendingPathComponent("profile.lock")
        }

        var protectedFiles: [URL] { [normalConfig, threePConfig, meta, profile] }
    }

    enum Phase: String, Codable {
        case applying
        case active
        case externalConflict
    }

    struct FileSnapshot: Codable {
        let path: String
        let existed: Bool
        let data: Data?
        let permissions: UInt16?
        let sha256: String?
    }

    struct Journal: Codable {
        let version: Int
        var phase: Phase
        let createdAt: Date
        let snapshots: [FileSnapshot]
        var managedHashes: [String: String]
    }

    struct Status: Equatable {
        let isApplied: Bool
        let isOwnedByAIUsage: Bool
        let hasJournal: Bool
        let appliedProfileName: String?
    }

    private let fileManager: FileManager
    let paths: Paths

    init(fileManager: FileManager = .default, paths: Paths = Paths()) {
        self.fileManager = fileManager
        self.paths = paths
    }

    #if canImport(QuotaBackend)
    static func catalog(
        for node: ProxyConfiguration,
        mode: ClaudeDesktopCatalogMode = .fullNodeCatalog,
        supports1M: Set<String> = [],
        routes: ClaudeAppResolvedModels? = nil
    ) -> [ClaudeDesktopCatalogEntry] {
        let resolved = resolvedRoutes(for: node, routes: routes)
        let routeEntries = productRouteEntries(resolved: resolved, supports1M: supports1M)
        switch mode {
        case .smartRoutes:
            return routeEntries

        case .fullNodeCatalog:
            return realCatalog(for: node, supports1M: supports1M)
        }
    }

    static func realCatalog(
        for node: ProxyConfiguration,
        supports1M: Set<String> = []
    ) -> [ClaudeDesktopCatalogEntry] {
        let protocolCatalog = ScienceModelProtocolAdapter(
            upstreamModels: upstreamModels(for: node),
            requestedDefault: node.defaultModel,
            routeStyle: .desktop,
            supports1MUpstreamModels: supports1M
        )
        return protocolCatalog.models.map {
            ClaudeDesktopCatalogEntry(
                id: $0.id,
                upstreamModel: $0.upstreamModel,
                displayName: $0.displayName,
                supports1M: $0.supports1M
            )
        }
    }

    static func gatewayProjection(
        for node: ProxyConfiguration,
        mode: ClaudeDesktopCatalogMode,
        supports1M: Set<String> = [],
        routes: ClaudeAppResolvedModels? = nil,
        productRouteIDs: [String]? = nil
    ) -> ClaudeProductGatewayCatalogProjection {
        let resolved = resolvedRoutes(for: node, routes: routes)
        let routeEntries = productRouteEntries(
            resolved: resolved,
            supports1M: supports1M,
            ids: productRouteIDs
        )
        switch mode {
        case .smartRoutes:
            return ClaudeProductGatewayCatalogProjection(
                availableModels: routeEntries.map(\.id),
                defaultModel: resolved.defaultModel,
                supports1MModels: routeEntries.filter(\.supports1M).map(\.id)
            )
        case .fullNodeCatalog:
            let realModels = upstreamModels(for: node)
            return ClaudeProductGatewayCatalogProjection(
                availableModels: realModels,
                defaultModel: realModels.contains(resolved.defaultModel)
                    ? resolved.defaultModel
                    : realModels.first,
                supports1MModels: realModels.filter(supports1M.contains)
            )
        }
    }

    private static func resolvedRoutes(
        for node: ProxyConfiguration,
        routes: ClaudeAppResolvedModels?
    ) -> ClaudeAppResolvedModels {
        routes ?? ClaudeAppResolvedModels(
            defaultModel: node.defaultModel,
            opus: node.modelMapping.bigModel.name,
            sonnet: node.modelMapping.middleModel.name,
            haiku: node.modelMapping.smallModel.name
        )
    }

    private static func upstreamModels(for node: ProxyConfiguration) -> [String] {
        let configured = node.modelCatalog.models
        let candidates = configured.isEmpty
            ? [
                node.defaultModel,
                node.modelMapping.bigModel.name,
                node.modelMapping.middleModel.name,
                node.modelMapping.smallModel.name,
            ]
            : configured
        var seen = Set<String>()
        return candidates.compactMap {
            let model = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, seen.insert(model).inserted else { return nil }
            return model
        }
    }

    private static func productRouteEntries(
        resolved: ClaudeAppResolvedModels,
        supports1M: Set<String>,
        ids: [String]? = nil
    ) -> [ClaudeDesktopCatalogEntry] {
        let ids = ids ?? [
            defaultRouteID,
            opusRouteID,
            sonnetRouteID,
            haikuRouteID,
        ]
        let definitions = zip(
            ids,
            [
                (resolved.defaultModel, "AIUsage"),
                (resolved.opus, "AIUsage Opus"),
                (resolved.sonnet, "AIUsage Sonnet"),
                (resolved.haiku, "AIUsage Haiku"),
            ]
        )
        return definitions.compactMap { id, definition in
            let upstream = definition.0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !upstream.isEmpty else { return nil }
            return ClaudeDesktopCatalogEntry(
                id: id,
                upstreamModel: upstream,
                displayName: definition.1,
                supports1M: supports1M.contains(upstream)
            )
        }
    }
    #endif

    func appliedModelIDs() -> [String] {
        let profile = (try? readJSONObject(paths.profile, missingAsEmpty: true)) ?? [:]
        let models = profile["inferenceModels"] as? [[String: Any]] ?? []
        return models.compactMap { name in
            guard let value = (name["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
    }

    func status() -> Status {
        let metaObject = (try? readJSONObject(paths.meta, missingAsEmpty: true)) ?? [:]
        let appliedID = metaObject["appliedId"] as? String
        let entries = metaObject["entries"] as? [[String: Any]] ?? []
        let appliedName = entries.first(where: { $0["id"] as? String == appliedID })?["name"] as? String
        let isOwn = appliedID == Self.profileID
        return Status(
            isApplied: appliedID != nil,
            isOwnedByAIUsage: isOwn,
            hasJournal: fileManager.fileExists(atPath: paths.journal.path),
            appliedProfileName: appliedName
        )
    }

    /// Recover only an interrupted apply.  An active journal is the exact
    /// snapshot needed for a future user-requested disconnect and must stay.
    func recoverInterruptedApplyIfNeeded() throws {
        try withLock {
            guard var journal = try loadJournal() else { return }
            guard journal.phase == .applying else { return }
            try restore(journal.snapshots)
            try removeJournal()
            journal.managedHashes.removeAll()
        }
    }

    func connect(
        baseURL: String,
        clientKey: String,
        catalog: [ClaudeDesktopCatalogEntry]
    ) throws {
        try withLock {
            var takeoverSnapshots: [FileSnapshot]?
            if let journal = try loadJournal() {
                switch journal.phase {
                case .applying:
                    try restore(journal.snapshots)
                    try removeJournal()
                case .active, .externalConflict:
                    if status().isOwnedByAIUsage {
                        // `connect` is an explicit user request. Repair only
                        // AIUsage-owned fields and adopt unrelated preference
                        // changes made by Claude Desktop itself.
                        try refreshLocked(
                            baseURL: baseURL,
                            clientKey: clientKey,
                            catalog: catalog,
                            journal: journal
                        )
                        return
                    }

                    // The user explicitly clicked Connect after another
                    // profile became active. Rebase the restore point onto the
                    // current Desktop selection, while retaining the original
                    // snapshot for AIUsage's dedicated profile file. A later
                    // disconnect therefore restores the profile that was
                    // active immediately before this takeover.
                    takeoverSnapshots = try rebasedSnapshots(from: journal)
                    try removeJournal()
                }
            }

            let snapshots: [FileSnapshot]
            if let takeoverSnapshots {
                snapshots = takeoverSnapshots
            } else {
                snapshots = try paths.protectedFiles.map(snapshot)
            }
            var journal = Journal(
                version: Self.journalVersion,
                phase: .applying,
                createdAt: Date(),
                snapshots: snapshots,
                managedHashes: [:]
            )
            try writeJournal(journal)

            do {
                try applyManagedConfiguration(baseURL: baseURL, clientKey: clientKey, catalog: catalog)

                journal.phase = .active
                journal.managedHashes = try managedHashes()
                try writeJournal(journal)
            } catch {
                try? restore(snapshots)
                try? removeJournal()
                throw error
            }
        }
    }

    func refresh(
        baseURL: String,
        clientKey: String,
        catalog: [ClaudeDesktopCatalogEntry]
    ) throws {
        try withLock {
            guard let journal = try loadJournal(), journal.phase == .active else {
                throw ClaudeDesktopProfileError.noRestoreJournal
            }
            guard status().isOwnedByAIUsage else {
                throw ClaudeDesktopProfileError.profileOwnedByAnotherTool
            }
            try refreshLocked(baseURL: baseURL, clientKey: clientKey, catalog: catalog, journal: journal)
        }
    }

    /// Restores AIUsage-owned fields while preserving unrelated preferences
    /// written by Claude Desktop during the connection. If another profile is
    /// active, fail closed and leave that selection untouched.
    @discardableResult
    func disconnect() throws -> Bool {
        try withLock {
            guard let journal = try loadJournal() else {
                throw ClaudeDesktopProfileError.noRestoreJournal
            }
            guard status().isOwnedByAIUsage else {
                var journal = journal
                journal.phase = .externalConflict
                try writeJournal(journal)
                throw ClaudeDesktopProfileError.profileOwnedByAnotherTool
            }

            let rollback = try paths.protectedFiles.map(snapshot)
            do {
                try restoreManagedState(from: journal)
                try removeJournal()
                return true
            } catch {
                try? restore(rollback)
                throw error
            }
        }
    }

    // MARK: - Merge / verification

    private func refreshLocked(
        baseURL: String,
        clientKey: String,
        catalog: [ClaudeDesktopCatalogEntry],
        journal original: Journal
    ) throws {
        var journal = original
        try applyManagedConfiguration(baseURL: baseURL, clientKey: clientKey, catalog: catalog)
        journal.phase = .active
        // Keep the first managed hashes as per-file change detectors. A later
        // refresh may change AIUsage-owned fields, and Desktop may change
        // unrelated preferences; either case makes that one file use the
        // field-level restore path without sacrificing exact restoration for
        // the other untouched files.
        try writeJournal(journal)
    }

    private func applyManagedConfiguration(
        baseURL: String,
        clientKey: String,
        catalog: [ClaudeDesktopCatalogEntry]
    ) throws {
        var normal = try readJSONObject(paths.normalConfig, missingAsEmpty: true)
        var threeP = try readJSONObject(paths.threePConfig, missingAsEmpty: true)
        var meta = try readJSONObject(paths.meta, missingAsEmpty: true)
        var profile = try readJSONObject(paths.profile, missingAsEmpty: true)

        normal["deploymentMode"] = "3p"
        threeP["deploymentMode"] = "3p"
        mergeMeta(&meta)
        mergeProfile(&profile, baseURL: baseURL, clientKey: clientKey, catalog: catalog)

        try writeJSONObject(normal, to: paths.normalConfig)
        try writeJSONObject(threeP, to: paths.threePConfig)
        try writeJSONObject(meta, to: paths.meta)
        try writeJSONObject(profile, to: paths.profile)
        try verify(baseURL: baseURL, clientKey: clientKey, expectedModelCount: catalog.count)
    }

    private func mergeMeta(_ object: inout [String: Any]) {
        let rawEntries = object["entries"] as? [Any] ?? []
        var entries: [[String: Any]] = rawEntries.compactMap { $0 as? [String: Any] }
        var firstOwnIndex: Int?
        entries = entries.enumerated().compactMap { index, entry in
            guard entry["id"] as? String == Self.profileID else { return entry }
            if firstOwnIndex == nil {
                firstOwnIndex = index
                var updated = entry
                updated["name"] = Self.profileName
                return updated
            }
            return nil
        }
        if !entries.contains(where: { $0["id"] as? String == Self.profileID }) {
            entries.append(["id": Self.profileID, "name": Self.profileName])
        }
        object["entries"] = entries
        object["appliedId"] = Self.profileID
    }

    private func mergeProfile(
        _ object: inout [String: Any],
        baseURL: String,
        clientKey: String,
        catalog: [ClaudeDesktopCatalogEntry]
    ) {
        object["inferenceProvider"] = "gateway"
        object["inferenceGatewayBaseUrl"] = baseURL
        object["inferenceGatewayApiKey"] = clientKey
        object["disableDeploymentModeChooser"] = true
        // Smart-route IDs are family SKUs so Desktop can attach Effort / Thinking.
        // Full-catalog mode may append generated role-shaped IDs for node models.
        object.removeValue(forKey: "inferenceGatewayAuthScheme")
        object["inferenceModels"] = catalog.map { entry -> [String: Any] in
            var model: [String: Any] = [
                "name": entry.id,
                "labelOverride": entry.displayName,
            ]
            if entry.supports1M { model["supports1m"] = true }
            return model
        }
    }

    private func verify(baseURL: String, clientKey: String, expectedModelCount: Int) throws {
        let normal = try readJSONObject(paths.normalConfig, missingAsEmpty: false)
        let threeP = try readJSONObject(paths.threePConfig, missingAsEmpty: false)
        let meta = try readJSONObject(paths.meta, missingAsEmpty: false)
        let profile = try readJSONObject(paths.profile, missingAsEmpty: false)
        guard normal["deploymentMode"] as? String == "3p",
              threeP["deploymentMode"] as? String == "3p",
              meta["appliedId"] as? String == Self.profileID,
              profile["inferenceGatewayBaseUrl"] as? String == baseURL,
              profile["inferenceGatewayApiKey"] as? String == clientKey,
              (profile["inferenceModels"] as? [[String: Any]])?.count == expectedModelCount else {
            throw ClaudeDesktopProfileError.verificationFailed("round-trip mismatch")
        }
    }

    // MARK: - Byte snapshots / durable journal

    private func snapshot(_ url: URL) throws -> FileSnapshot {
        guard fileManager.fileExists(atPath: url.path) else {
            return FileSnapshot(path: url.path, existed: false, data: nil, permissions: nil, sha256: nil)
        }
        let data = try Data(contentsOf: url)
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        return FileSnapshot(
            path: url.path,
            existed: true,
            data: data,
            permissions: permissions,
            sha256: Self.sha256(data)
        )
    }

    private func restore(_ snapshots: [FileSnapshot]) throws {
        for item in snapshots {
            let url = URL(fileURLWithPath: item.path)
            if item.existed, let data = item.data {
                try atomicWrite(data, to: url, permissions: item.permissions ?? 0o600)
                guard Self.sha256(try Data(contentsOf: url)) == item.sha256 else {
                    throw ClaudeDesktopProfileError.verificationFailed(url.lastPathComponent)
                }
            } else if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    /// Rebase a stale journal when the user explicitly asks AIUsage to take
    /// over again. Shared files use their current bytes so disconnect restores
    /// the latest Desktop/profile-tool state. The dedicated AIUsage profile
    /// keeps its original pre-AIUsage snapshot so we still remove/restore our
    /// own file correctly.
    private func rebasedSnapshots(from journal: Journal) throws -> [FileSnapshot] {
        let original = Dictionary(uniqueKeysWithValues: journal.snapshots.map { ($0.path, $0) })
        return try paths.protectedFiles.map { url in
            if url == paths.profile, let prior = original[url.path] {
                return prior
            }
            return try snapshot(url)
        }
    }

    /// Restore each protected file independently. Untouched files return to
    /// their exact bytes; changed files restore only AIUsage-owned fields so
    /// Desktop preferences and unknown extension fields survive.
    private func restoreManagedState(from journal: Journal) throws {
        let byPath = Dictionary(uniqueKeysWithValues: journal.snapshots.map { ($0.path, $0) })
        if try matchesManagedHash(paths.normalConfig, journal: journal) {
            try restoreSnapshot(byPath[paths.normalConfig.path])
        } else {
            try restoreDeploymentMode(at: paths.normalConfig, snapshot: byPath[paths.normalConfig.path])
        }
        if try matchesManagedHash(paths.threePConfig, journal: journal) {
            try restoreSnapshot(byPath[paths.threePConfig.path])
        } else {
            try restoreDeploymentMode(at: paths.threePConfig, snapshot: byPath[paths.threePConfig.path])
        }
        if try matchesManagedHash(paths.meta, journal: journal) {
            try restoreSnapshot(byPath[paths.meta.path])
        } else {
            try restoreMeta(snapshot: byPath[paths.meta.path])
        }
        if try matchesManagedHash(paths.profile, journal: journal) {
            try restoreSnapshot(byPath[paths.profile.path])
        } else {
            try restoreProfile(snapshot: byPath[paths.profile.path])
        }
    }

    private func matchesManagedHash(_ url: URL, journal: Journal) throws -> Bool {
        guard let expected = journal.managedHashes[url.path],
              fileManager.fileExists(atPath: url.path) else { return false }
        return Self.sha256(try Data(contentsOf: url)) == expected
    }

    private func restoreSnapshot(_ snapshot: FileSnapshot?) throws {
        guard let snapshot else {
            throw ClaudeDesktopProfileError.verificationFailed("missing restore snapshot")
        }
        try restore([snapshot])
    }

    private func restoreDeploymentMode(at url: URL, snapshot: FileSnapshot?) throws {
        var current = try readJSONObject(url, missingAsEmpty: true)
        let original = try snapshotJSONObject(snapshot)
        restoreKey("deploymentMode", from: original, into: &current)
        try writeOrRemove(current, to: url, snapshot: snapshot)
    }

    private func restoreMeta(snapshot: FileSnapshot?) throws {
        var current = try readJSONObject(paths.meta, missingAsEmpty: true)
        let original = try snapshotJSONObject(snapshot)
        restoreKey("appliedId", from: original, into: &current)

        var currentEntries = (current["entries"] as? [Any] ?? [])
            .compactMap { $0 as? [String: Any] }
            .filter { $0["id"] as? String != Self.profileID }
        let originalOwnEntry = (original["entries"] as? [Any] ?? [])
            .compactMap { $0 as? [String: Any] }
            .first { $0["id"] as? String == Self.profileID }
        if let originalOwnEntry { currentEntries.append(originalOwnEntry) }
        if currentEntries.isEmpty, original["entries"] == nil {
            current.removeValue(forKey: "entries")
        } else {
            current["entries"] = currentEntries
        }
        try writeOrRemove(current, to: paths.meta, snapshot: snapshot)
    }

    private func restoreProfile(snapshot: FileSnapshot?) throws {
        var current = try readJSONObject(paths.profile, missingAsEmpty: true)
        let original = try snapshotJSONObject(snapshot)
        for key in [
            "inferenceProvider",
            "inferenceGatewayBaseUrl",
            "inferenceGatewayApiKey",
            "inferenceGatewayAuthScheme",
            "disableDeploymentModeChooser",
            "inferenceModels",
        ] {
            restoreKey(key, from: original, into: &current)
        }
        try writeOrRemove(current, to: paths.profile, snapshot: snapshot)
    }

    private func snapshotJSONObject(_ snapshot: FileSnapshot?) throws -> [String: Any] {
        guard let snapshot, snapshot.existed, let data = snapshot.data else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeDesktopProfileError.invalidJSONObject(URL(fileURLWithPath: snapshot.path).lastPathComponent)
        }
        return object
    }

    private func restoreKey(_ key: String, from original: [String: Any], into current: inout [String: Any]) {
        if original.keys.contains(key) {
            current[key] = original[key]
        } else {
            current.removeValue(forKey: key)
        }
    }

    private func writeOrRemove(_ object: [String: Any], to url: URL, snapshot: FileSnapshot?) throws {
        if snapshot?.existed != true, object.isEmpty {
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            return
        }
        try writeJSONObject(object, to: url, permissions: snapshot?.permissions ?? 0o600)
    }

    private func managedHashes() throws -> [String: String] {
        var result: [String: String] = [:]
        for url in paths.protectedFiles where fileManager.fileExists(atPath: url.path) {
            result[url.path] = Self.sha256(try Data(contentsOf: url))
        }
        return result
    }

    private func loadJournal() throws -> Journal? {
        guard fileManager.fileExists(atPath: paths.journal.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Journal.self, from: Data(contentsOf: paths.journal))
    }

    private func writeJournal(_ journal: Journal) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try atomicWrite(try encoder.encode(journal), to: paths.journal, permissions: 0o600)
    }

    private func removeJournal() throws {
        if fileManager.fileExists(atPath: paths.journal.path) {
            try fileManager.removeItem(at: paths.journal)
        }
    }

    private func readJSONObject(_ url: URL, missingAsEmpty: Bool) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else {
            if missingAsEmpty { return [:] }
            throw ClaudeDesktopProfileError.verificationFailed("missing \(url.lastPathComponent)")
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dictionary = object as? [String: Any] else {
            throw ClaudeDesktopProfileError.invalidJSONObject(url.lastPathComponent)
        }
        return dictionary
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL, permissions: UInt16 = 0o600) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try atomicWrite(data + Data("\n".utf8), to: url, permissions: permissions)
    }

    private func atomicWrite(_ data: Data, to url: URL, permissions: UInt16) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        try fileManager.createDirectory(at: paths.lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(paths.lock.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ClaudeDesktopProfileError.lockUnavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ClaudeDesktopProfileError.lockUnavailable }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
