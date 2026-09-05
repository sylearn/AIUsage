import Foundation

actor CodexCostFileScanCache {
    // v7: aggregate 纳入按会话代理覆盖去重，旧缓存必须重解析。
    static let artifactVersion = 7
    var entriesByFile: [String: CodexParsedFile] = [:]
    var hasLoadedDiskCache = false

    func entries(matching fingerprintsByFile: [String: CodexFileFingerprint]) -> [String: CodexParsedFile] {
        loadDiskCacheIfNeeded()

        var matching: [String: CodexParsedFile] = [:]
        for (file, fingerprint) in fingerprintsByFile {
            guard let entry = entriesByFile[file],
                  entry.fingerprint == fingerprint else {
                continue
            }
            matching[file] = entry
        }
        return matching
    }

    /// 路由签名可能刚变化，但文件本身未变；此时仍可复用 session_meta，避免每次统计刷新
    /// 都重新解析所有 rollout 的首行。完整 aggregate 是否可复用仍由 `entries(matching:)` 判定。
    func metadata(matchingFileState fingerprintsByFile: [String: CodexFileFingerprint]) -> [String: SessionMetadata] {
        loadDiskCacheIfNeeded()

        var matching: [String: SessionMetadata] = [:]
        for (file, fingerprint) in fingerprintsByFile {
            guard let entry = entriesByFile[file],
                  entry.fingerprint.path == fingerprint.path,
                  entry.fingerprint.size == fingerprint.size,
                  entry.fingerprint.modifiedAt == fingerprint.modifiedAt,
                  let metadata = entry.metadata else {
                continue
            }
            matching[file] = metadata
        }
        return matching
    }

    func store(_ updates: [String: CodexParsedFile], keeping validFiles: Set<String>) {
        loadDiskCacheIfNeeded()

        entriesByFile = entriesByFile.filter { validFiles.contains($0.key) }
        for (file, entry) in updates {
            entriesByFile[file] = entry
        }
        saveDiskCache()
    }

    func loadDiskCacheIfNeeded() {
        guard !hasLoadedDiskCache else { return }
        hasLoadedDiskCache = true

        let url = Self.cacheFileURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CodexCostPersistentCache.self, from: data),
              decoded.version == Self.artifactVersion else {
            entriesByFile = [:]
            return
        }
        entriesByFile = decoded.files
    }

    func saveDiskCache() {
        let url = Self.cacheFileURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let cache = CodexCostPersistentCache(version: Self.artifactVersion, files: entriesByFile)
            let encoder = JSONEncoder()
            let data = try encoder.encode(cache)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort cache: stale or missing cache should never break token stats.
        }
    }

    static func cacheFileURL() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("AIUsage", isDirectory: true)
            .appendingPathComponent("codex-cost-file-cache-v\(artifactVersion).json")
    }
}
