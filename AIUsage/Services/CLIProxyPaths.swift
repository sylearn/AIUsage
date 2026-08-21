import Foundation

nonisolated struct CLIProxyPaths: Sendable {
    let root: URL

    init(root: URL? = nil, fileManager: FileManager = .default) throws {
        if let root {
            self.root = root.standardizedFileURL
            return
        }
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CLIProxyGatewayError.fileSystem("Application Support directory is unavailable.")
        }
        self.root = applicationSupport
            .appendingPathComponent("AIUsage", isDirectory: true)
            .appendingPathComponent("CLIProxyAPI", isDirectory: true)
    }

    var versionsDirectory: URL { root.appendingPathComponent("versions", isDirectory: true) }
    var currentSymlink: URL { root.appendingPathComponent("current", isDirectory: false) }
    var authDirectory: URL { root.appendingPathComponent("auth", isDirectory: true) }
    var pluginsDirectory: URL { root.appendingPathComponent("plugins", isDirectory: true) }
    var logsDirectory: URL { root.appendingPathComponent("logs", isDirectory: true) }
    var configURL: URL { root.appendingPathComponent("config.yaml", isDirectory: false) }
    var stateURL: URL { root.appendingPathComponent("state.json", isDirectory: false) }
    var syncManifestURL: URL { root.appendingPathComponent("account-sync-manifest.json", isDirectory: false) }
    /// Cached GitHub `releases/latest` payload + ETag, so opening the CPA page
    /// does not burn the unauthenticated 60 req/hour budget.
    var githubReleaseCacheURL: URL { root.appendingPathComponent("github-latest-release.json", isDirectory: false) }
    var binaryName: String { "CLIProxyAPI" }

    func versionDirectory(_ version: String) throws -> URL {
        guard CLIProxyVersion.isSafePathComponent(version) else {
            throw CLIProxyGatewayError.invalidRelease("unsafe version path component")
        }
        return versionsDirectory.appendingPathComponent("v\(CLIProxyVersion.normalized(version))", isDirectory: true)
    }

    func binaryURL(version: String) throws -> URL {
        try versionDirectory(version).appendingPathComponent(binaryName, isDirectory: false)
    }

    func prepare(fileManager: FileManager = .default) throws {
        for directory in [root, versionsDirectory, authDirectory, pluginsDirectory, logsDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    /// Resolves the plugin directory without silently abandoning plugins from an
    /// older CPA working directory. Explicit absolute paths remain user-owned.
    /// Relative paths are copied into the stable AIUsage directory only after a
    /// complete conflict preflight; the source is intentionally left untouched.
    func runtimePluginsDirectory(
        configuredPath: String?,
        fileManager: FileManager = .default
    ) throws -> URL {
        // Before AIUsage owned a stable plugins.dir, CPA resolved its default
        // "plugins" path against the active binary directory.
        let value = (configuredPath ?? "plugins")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw CLIProxyGatewayError.configuration(
                "CPA plugins.dir is empty; the existing config was left unchanged"
            )
        }

        if NSString(string: value).isAbsolutePath {
            return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        }

        let components = NSString(string: value).pathComponents
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." && $0 != "~" }),
              !value.contains("\0") else {
            throw CLIProxyGatewayError.configuration(
                "CPA plugins.dir uses an unsafe relative path; the existing config was left unchanged"
            )
        }
        let runtimeDirectories = try installedRuntimeDirectories(fileManager: fileManager)
        var oldSources: [URL] = []
        var currentSources: [URL] = []
        for runtimeDirectory in runtimeDirectories.directories {
            let unresolvedSource = runtimeDirectory
                .appendingPathComponent(value, isDirectory: true)
                .standardizedFileURL
            let expectedPrefix = runtimeDirectory.path.hasSuffix("/")
                ? runtimeDirectory.path
                : runtimeDirectory.path + "/"
            guard unresolvedSource.path.hasPrefix(expectedPrefix) else {
                throw CLIProxyGatewayError.configuration(
                    "CPA plugins.dir escapes a runtime directory; the existing config was left unchanged"
                )
            }
            guard let sourceType = try itemType(at: unresolvedSource, fileManager: fileManager) else {
                continue
            }
            guard sourceType == .typeDirectory || sourceType == .typeSymbolicLink else {
                throw CLIProxyGatewayError.configuration(
                    "CPA plugins.dir does not point to a directory; the existing config was left unchanged"
                )
            }
            let source = unresolvedSource.resolvingSymlinksInPath().standardizedFileURL
            guard try itemType(at: source, fileManager: fileManager) == .typeDirectory else {
                throw CLIProxyGatewayError.configuration(
                    "CPA plugins.dir resolves to an unavailable directory; the existing config was left unchanged"
                )
            }
            guard !(try fileManager.contentsOfDirectory(atPath: source.path)).isEmpty else { continue }
            if runtimeDirectories.current == runtimeDirectory {
                if !currentSources.contains(source) { currentSources.append(source) }
            } else if !oldSources.contains(source) {
                oldSources.append(source)
            }
        }

        let discoveredSources = (oldSources + currentSources).reduce(into: [URL]()) { result, source in
            if !result.contains(source) { result.append(source) }
        }
        guard discoveredSources.count <= 1 else {
            throw CLIProxyGatewayError.configuration(
                "CPA found plugins in multiple version directories; choose or merge them manually before retrying"
            )
        }
        guard let source = discoveredSources.first else { return pluginsDirectory }
        guard source != pluginsDirectory.standardizedFileURL else { return pluginsDirectory }

        try migratePluginContents(
            from: source,
            to: pluginsDirectory,
            fileManager: fileManager
        )
        return pluginsDirectory
    }

    private func installedRuntimeDirectories(
        fileManager: FileManager
    ) throws -> (directories: [URL], current: URL?) {
        let current: URL?
        if try itemType(at: currentSymlink, fileManager: fileManager) != nil {
            current = currentSymlink.resolvingSymlinksInPath().standardizedFileURL
        } else {
            current = nil
        }

        let installed = try fileManager.contentsOfDirectory(
            at: versionsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ).filter {
            (try? itemType(at: $0, fileManager: fileManager)) == .typeDirectory
        }.map(\.standardizedFileURL)
        .sorted {
            CLIProxyVersion.compare($0.lastPathComponent, $1.lastPathComponent) == .orderedDescending
        }

        var directories = installed.filter { $0 != current }
        if let current, !directories.contains(current) { directories.append(current) }
        return (directories, current)
    }

    private func migratePluginContents(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        var entries: [PluginMigrationEntry] = []
        try collectPluginEntries(
            source: source,
            destination: destination,
            fileManager: fileManager,
            entries: &entries
        )

        // Preflight every destination before copying anything. Existing identical
        // files are accepted; any type/content conflict aborts the migration.
        for entry in entries {
            guard let existingType = try itemType(at: entry.destination, fileManager: fileManager) else {
                continue
            }
            switch (entry.type, existingType) {
            case (.typeDirectory, .typeDirectory):
                continue
            case (.typeRegular, .typeRegular):
                guard fileManager.contentsEqual(
                    atPath: entry.source.path,
                    andPath: entry.destination.path
                ) else {
                    throw pluginMigrationConflict(entry.destination)
                }
            default:
                throw pluginMigrationConflict(entry.destination)
            }
        }

        let directories = entries
            .filter { $0.type == .typeDirectory }
            .sorted { $0.destination.pathComponents.count < $1.destination.pathComponents.count }
        for entry in directories where try itemType(at: entry.destination, fileManager: fileManager) == nil {
            try fileManager.createDirectory(
                at: entry.destination,
                withIntermediateDirectories: false
            )
        }
        for entry in entries where entry.type == .typeRegular {
            if try itemType(at: entry.destination, fileManager: fileManager) == nil {
                try fileManager.copyItem(at: entry.source, to: entry.destination)
            }
        }
    }

    private func collectPluginEntries(
        source: URL,
        destination: URL,
        fileManager: FileManager,
        entries: inout [PluginMigrationEntry]
    ) throws {
        let children = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        for child in children {
            guard let type = try itemType(at: child, fileManager: fileManager) else { continue }
            let target = destination.appendingPathComponent(
                child.lastPathComponent,
                isDirectory: type == .typeDirectory
            )
            guard type == .typeDirectory || type == .typeRegular else {
                throw CLIProxyGatewayError.configuration(
                    "CPA legacy plugin directory contains a symbolic link or special file at '\(child.lastPathComponent)'; the existing config was left unchanged"
                )
            }
            entries.append(PluginMigrationEntry(source: child, destination: target, type: type))
            if type == .typeDirectory {
                try collectPluginEntries(
                    source: child,
                    destination: target,
                    fileManager: fileManager,
                    entries: &entries
                )
            }
        }
    }

    private func itemType(at url: URL, fileManager: FileManager) throws -> FileAttributeType? {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            return attributes[.type] as? FileAttributeType
        } catch {
            let cocoaError = error as NSError
            if cocoaError.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cocoaError.code) {
                return nil
            }
            throw CLIProxyGatewayError.configuration(
                "CPA plugin directory could not be inspected safely: \(error.localizedDescription)"
            )
        }
    }

    private func pluginMigrationConflict(_ destination: URL) -> CLIProxyGatewayError {
        CLIProxyGatewayError.configuration(
            "CPA plugin migration found conflicting content at '\(destination.path)'; no existing plugin files were changed"
        )
    }
}

nonisolated private struct PluginMigrationEntry {
    let source: URL
    let destination: URL
    let type: FileAttributeType
}
