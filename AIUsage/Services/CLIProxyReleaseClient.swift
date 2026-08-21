import Foundation

// MARK: - GitHub latest-release lookup
// Unauthenticated api.github.com allows about 60 requests per hour per IP.
// Opening the CPA page used to hit `/releases/latest` every time and surface HTTP 403.

nonisolated struct CLIProxyReleaseLookup: Sendable {
    let release: CLIProxyRelease
    let fetchedAt: Date
    let fromNetwork: Bool
    let rateLimitedUntil: Date?
}

private nonisolated struct CLIProxyGitHubReleaseCache: Codable, Sendable {
    var etag: String?
    var fetchedAt: Date
    var rateLimitedUntil: Date?
    var payload: Data
}

nonisolated final class CLIProxyReleaseClient: @unchecked Sendable {
    static let repository = "router-for-me/CLIProxyAPI"
    static let cacheTTL: TimeInterval = 30 * 60

    private let session: URLSession
    private let apiBaseURL: URL
    private let cacheURL: URL?
    private let fileManager: FileManager
    private let cacheLock = NSLock()

    init(
        session: URLSession = .shared,
        apiBaseURL: URL = URL(string: "https://api.github.com")!,
        cacheURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.session = session
        self.apiBaseURL = apiBaseURL
        self.cacheURL = cacheURL
        self.fileManager = fileManager
    }

    func cachedLookup(
        architecture: CLIProxyArchitecture = .current
    ) -> CLIProxyReleaseLookup? {
        guard let cache = loadCache(),
              let release = try? Self.decodeRelease(cache.payload, architecture: architecture) else {
            return nil
        }
        return CLIProxyReleaseLookup(
            release: release,
            fetchedAt: cache.fetchedAt,
            fromNetwork: false,
            rateLimitedUntil: cache.rateLimitedUntil
        )
    }

    /// Live / regression callers that only need the decoded release.
    func latestStableRelease(
        architecture: CLIProxyArchitecture = .current
    ) async throws -> CLIProxyRelease {
        try await lookupLatestRelease(forceRefresh: true, architecture: architecture).release
    }

    func lookupLatestRelease(
        forceRefresh: Bool = false,
        architecture: CLIProxyArchitecture = .current
    ) async throws -> CLIProxyReleaseLookup {
        let now = Date()
        let cache = loadCache()
        if let cache,
           let until = cache.rateLimitedUntil,
           now < until,
           let release = try? Self.decodeRelease(cache.payload, architecture: architecture) {
            return CLIProxyReleaseLookup(
                release: release,
                fetchedAt: cache.fetchedAt,
                fromNetwork: false,
                rateLimitedUntil: until
            )
        }
        if !forceRefresh,
           let cache,
           now.timeIntervalSince(cache.fetchedAt) < Self.cacheTTL,
           let release = try? Self.decodeRelease(cache.payload, architecture: architecture) {
            return CLIProxyReleaseLookup(
                release: release,
                fetchedAt: cache.fetchedAt,
                fromNetwork: false,
                rateLimitedUntil: cache.rateLimitedUntil
            )
        }

        do {
            return try await fetchLatestRelease(
                architecture: architecture,
                cache: cache,
                now: now
            )
        } catch {
            if forceRefresh { throw error }
            if let cache,
               let release = try? Self.decodeRelease(cache.payload, architecture: architecture) {
                return CLIProxyReleaseLookup(
                    release: release,
                    fetchedAt: cache.fetchedAt,
                    fromNetwork: false,
                    rateLimitedUntil: cache.rateLimitedUntil
                )
            }
            throw error
        }
    }

    static func decodeRelease(
        _ data: Data,
        architecture: CLIProxyArchitecture
    ) throws -> CLIProxyRelease {
        let githubRelease = try decoder.decode(CLIProxyGitHubRelease.self, from: data)
        guard let release = CLIProxyRelease(githubRelease: githubRelease, architecture: architecture) else {
            throw CLIProxyGatewayError.incompatibleAsset
        }
        return release
    }

    private func fetchLatestRelease(
        architecture: CLIProxyArchitecture,
        cache: CLIProxyGitHubReleaseCache?,
        now: Date
    ) async throws -> CLIProxyReleaseLookup {
        let endpoint = apiBaseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(Self.repository)
            .appendingPathComponent("releases")
            .appendingPathComponent("latest")
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AIUsage-CLIProxy-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let etag = cache?.etag?.trimmingCharacters(in: .whitespacesAndNewlines), !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CLIProxyGatewayError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CLIProxyGatewayError.network("missing HTTP response")
        }

        if http.statusCode == 304, let cache,
           let release = try? Self.decodeRelease(cache.payload, architecture: architecture) {
            let updated = CLIProxyGitHubReleaseCache(
                etag: http.value(forHTTPHeaderField: "Etag") ?? cache.etag,
                fetchedAt: now,
                rateLimitedUntil: nil,
                payload: cache.payload
            )
            saveCache(updated)
            return CLIProxyReleaseLookup(
                release: release,
                fetchedAt: now,
                fromNetwork: true,
                rateLimitedUntil: nil
            )
        }

        if http.statusCode == 403 || http.statusCode == 429 {
            let resetAt = Self.rateLimitReset(from: http)
            if var cache {
                cache.rateLimitedUntil = resetAt
                saveCache(cache)
                if let release = try? Self.decodeRelease(cache.payload, architecture: architecture) {
                    return CLIProxyReleaseLookup(
                        release: release,
                        fetchedAt: cache.fetchedAt,
                        fromNetwork: false,
                        rateLimitedUntil: resetAt
                    )
                }
            }
            throw CLIProxyGatewayError.githubRateLimited(resetAt: resetAt)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw CLIProxyGatewayError.invalidHTTPStatus(http.statusCode)
        }

        let release: CLIProxyRelease
        do {
            release = try Self.decodeRelease(data, architecture: architecture)
        } catch let error as CLIProxyGatewayError {
            throw error
        } catch {
            throw CLIProxyGatewayError.invalidRelease(error.localizedDescription)
        }
        saveCache(CLIProxyGitHubReleaseCache(
            etag: http.value(forHTTPHeaderField: "Etag"),
            fetchedAt: now,
            rateLimitedUntil: nil,
            payload: data
        ))
        return CLIProxyReleaseLookup(
            release: release,
            fetchedAt: now,
            fromNetwork: true,
            rateLimitedUntil: nil
        )
    }

    private static func rateLimitReset(from http: HTTPURLResponse) -> Date? {
        if let retryAfter = http.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
           let seconds = TimeInterval(retryAfter), seconds > 0 {
            return Date().addingTimeInterval(seconds)
        }
        if let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let epoch = TimeInterval(reset), epoch > 0 {
            return Date(timeIntervalSince1970: epoch)
        }
        return Date().addingTimeInterval(15 * 60)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let cacheDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    private static let cacheEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private func loadCache() -> CLIProxyGitHubReleaseCache? {
        guard let cacheURL else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? Self.cacheDecoder.decode(CLIProxyGitHubReleaseCache.self, from: data) else {
            return nil
        }
        return cache
    }

    private func saveCache(_ cache: CLIProxyGitHubReleaseCache) {
        guard let cacheURL else { return }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        do {
            try fileManager.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try Self.cacheEncoder.encode(cache)
            try data.write(to: cacheURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        } catch {
            return
        }
    }
}

nonisolated struct CLIProxyDownloadedAsset: Sendable {
    let fileURL: URL
    let cleanupDirectory: URL
}

nonisolated final class CLIProxyAssetDownloader: @unchecked Sendable {
    private let session: URLSession
    private let fileManager: FileManager

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    func download(_ release: CLIProxyRelease) async throws -> CLIProxyDownloadedAsset {
        var request = URLRequest(url: release.downloadURL, timeoutInterval: 300)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("AIUsage-CLIProxy-Updater", forHTTPHeaderField: "User-Agent")

        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: request)
        } catch {
            throw CLIProxyGatewayError.network(error.localizedDescription)
        }
        try Self.validate(response: response)

        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("AIUsage-CLIProxy-\(UUID().uuidString)", isDirectory: true)
        let destination = directory.appendingPathComponent(release.assetName, isDirectory: false)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try fileManager.moveItem(at: temporaryURL, to: destination)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw CLIProxyGatewayError.fileSystem(error.localizedDescription)
        }
        return CLIProxyDownloadedAsset(fileURL: destination, cleanupDirectory: directory)
    }

    fileprivate static func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CLIProxyGatewayError.network("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CLIProxyGatewayError.invalidHTTPStatus(http.statusCode)
        }
    }
}
