import Foundation
import CryptoKit

public enum TokenSaverReleaseTool: String, CaseIterable, Codable, Identifiable, Sendable {
    case rtk, caveman, ponytail
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .rtk: return "RTK"
        case .caveman: return "Caveman"
        case .ponytail: return "Ponytail"
        }
    }
    public var repository: String {
        switch self {
        case .rtk: return "rtk-ai/rtk"
        case .caveman: return "JuliusBrussee/caveman"
        case .ponytail: return "DietrichGebert/ponytail"
        }
    }
    public var skillPath: String? {
        switch self {
        case .caveman, .ponytail: return "skills/\(rawValue)/SKILL.md"
        default: return nil
        }
    }
    public var upstreamURL: URL { URL(string: "https://github.com/\(repository)")! }
}

public struct TokenSaverRelease: Codable, Equatable, Sendable {
    public let tool: TokenSaverReleaseTool
    public let version: String
    public let commit: String
    public let isRelease: Bool
    public var upstreamURL: URL { tool.upstreamURL }
    public init(tool: TokenSaverReleaseTool, version: String, commit: String, isRelease: Bool) {
        self.tool = tool
        self.version = version
        self.commit = commit
        self.isRelease = isRelease
    }
}

public struct TokenSaverCachedRelease: Codable, Equatable, Sendable {
    public let release: TokenSaverRelease
    public let releaseETag: String?
    public let commitETag: String?
    public let checkedAt: Date
    public init(release: TokenSaverRelease, releaseETag: String?, commitETag: String?, checkedAt: Date) {
        self.release = release
        self.releaseETag = releaseETag
        self.commitETag = commitETag
        self.checkedAt = checkedAt
    }
}

private final class TokenSaverReleaseCache: @unchecked Sendable {
    private let cacheURL: URL?
    private let lock = NSLock()
    private var entries: [TokenSaverReleaseTool: TokenSaverCachedRelease] = [:]

    init(cacheURL: URL?) {
        self.cacheURL = cacheURL?.standardizedFileURL
        if self.cacheURL != nil {
            self.entries = Self.loadFromDisk(cacheURL: self.cacheURL)
        }
    }

    func entry(for tool: TokenSaverReleaseTool) -> TokenSaverCachedRelease? {
        lock.lock()
        defer { lock.unlock() }
        if cacheURL != nil {
            entries = Self.loadFromDisk(cacheURL: cacheURL)
        }
        guard let item = entries[tool], Self.isValid(item, for: tool) else { return nil }
        return item
    }

    func save(_ item: TokenSaverCachedRelease) {
        guard Self.isValid(item, for: item.release.tool),
              cacheURL != nil || item.releaseETag != nil || item.commitETag != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        if cacheURL != nil {
            var current = Self.loadFromDisk(cacheURL: cacheURL)
            current[item.release.tool] = item
            entries = current
            Self.saveToDisk(current, cacheURL: cacheURL)
        } else {
            entries[item.release.tool] = item
        }
    }

    func remove(_ tool: TokenSaverReleaseTool) {
        lock.lock()
        defer { lock.unlock() }
        if cacheURL != nil {
            var current = Self.loadFromDisk(cacheURL: cacheURL)
            current.removeValue(forKey: tool)
            entries = current
            Self.saveToDisk(current, cacheURL: cacheURL)
        } else {
            entries.removeValue(forKey: tool)
        }
    }

    private static func isValid(_ item: TokenSaverCachedRelease, for tool: TokenSaverReleaseTool) -> Bool {
        item.release.tool == tool
            && TokenSaverReleaseClient.validVersion(item.release.version)
            && TokenSaverReleaseClient.validSHA(item.release.commit)
            && item.checkedAt.timeIntervalSince1970.isFinite
            && (item.releaseETag == nil || TokenSaverReleaseClient.validETag(item.releaseETag!))
            && (item.commitETag == nil || TokenSaverReleaseClient.validETag(item.commitETag!))
    }

    private static func validateCachePath(_ url: URL) -> Bool {
        guard url.isFileURL, url.path != "/" else { return false }
        let fm = FileManager.default
        var ancestor = url.deletingLastPathComponent()
        while ancestor.path != "/" {
            if let attrs = try? fm.attributesOfItem(atPath: ancestor.path),
               attrs[.type] as? FileAttributeType != .typeDirectory {
                let expected = ["/var": "private/var", "/tmp": "private/tmp"][ancestor.path]
                let dest = try? fm.destinationOfSymbolicLink(atPath: ancestor.path)
                guard attrs[.type] as? FileAttributeType == .typeSymbolicLink,
                      (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
                      let expected, dest == expected || dest == "/" + expected else {
                    return false
                }
            }
            ancestor.deleteLastPathComponent()
        }
        if let attrs = try? fm.attributesOfItem(atPath: url.path) {
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  let size = attrs[.size] as? NSNumber, size.intValue <= 128 * 1024 else {
                return false
            }
        }
        return true
    }

    private static func loadFromDisk(cacheURL: URL?) -> [TokenSaverReleaseTool: TokenSaverCachedRelease] {
        guard let cacheURL, validateCachePath(cacheURL),
              FileManager.default.fileExists(atPath: cacheURL.path),
              let data = try? Data(contentsOf: cacheURL), data.count <= 128 * 1024,
              let raw = try? JSONDecoder().decode([String: TokenSaverCachedRelease].self, from: data) else {
            return [:]
        }
        var valid: [TokenSaverReleaseTool: TokenSaverCachedRelease] = [:]
        for (key, value) in raw {
            guard let tool = TokenSaverReleaseTool(rawValue: key), isValid(value, for: tool) else { continue }
            valid[tool] = value
        }
        return valid
    }

    private static func saveToDisk(_ map: [TokenSaverReleaseTool: TokenSaverCachedRelease], cacheURL: URL?) {
        guard let cacheURL, validateCachePath(cacheURL) else { return }
        let fm = FileManager.default
        let dir = cacheURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard validateCachePath(cacheURL) else { return }
            let raw = Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) })
            let data = try JSONEncoder().encode(raw)
            guard data.count <= 128 * 1024 else { return }
            try data.write(to: cacheURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        } catch {
            return
        }
    }
}

public enum TokenSaverReleaseError: LocalizedError {
    case http(Int), rateLimited(String?), invalidMetadata, oversized, unsafeStorage, manualInstallation
    public var errorDescription: String? {
        switch self {
        case .http(let status): return "GitHub returned HTTP \(status). Check again later."
        case .rateLimited(let reset):
            if let seconds = reset.flatMap(TimeInterval.init), seconds.isFinite {
                return "GitHub API limit reached. Retry after \(Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .standard)). This is not your AI usage quota."
            }
            return "GitHub API limit reached. Wait before trying again. This is not your AI usage quota."
        case .invalidMetadata: return "GitHub metadata or skill integrity validation failed."
        case .oversized: return "GitHub response exceeds the safe size limit."
        case .unsafeStorage: return "Managed storage is invalid or contains a symbolic link."
        case .manualInstallation: return "External installation required; AIUsage does not install or execute unverified binaries."
        }
    }
}

private final class TokenSaverReleaseNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// Read-only GitHub API access. No shell, archive extraction, package manager, or provider calls.
public struct TokenSaverReleaseClient: Sendable {
    public typealias Transport = @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private let cache: TokenSaverReleaseCache
    private let freshnessTTL: TimeInterval
    private let now: @Sendable () -> Date

    public static var defaultCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIUsage/token-saver-release-cache.json", isDirectory: false)
    }

    public init(cacheURL: URL? = nil, freshnessTTL: TimeInterval? = nil,
                transport: @escaping Transport = { request, limit in
        try await TokenSaverReleaseClient.fetch(request, limit: limit)
    }) {
        self.init(cacheURL: cacheURL, freshnessTTL: freshnessTTL, now: { Date() }, transport: transport)
    }

    public init(cacheURL: URL? = nil, freshnessTTL: TimeInterval? = nil,
                now: @escaping @Sendable () -> Date,
                transport: @escaping Transport = { request, limit in
        try await TokenSaverReleaseClient.fetch(request, limit: limit)
    }) {
        self.cache = TokenSaverReleaseCache(cacheURL: cacheURL)
        self.freshnessTTL = freshnessTTL ?? (cacheURL != nil ? 60 : 0)
        self.now = now
        self.transport = transport
    }

    public func cached(for tool: TokenSaverReleaseTool) -> TokenSaverCachedRelease? {
        cache.entry(for: tool)
    }

    public func clearCached(for tool: TokenSaverReleaseTool) {
        cache.remove(tool)
    }

    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: TokenSaverReleaseNoRedirects(), delegateQueue: nil)
    }()

    public static func fetch(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await sharedSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw TokenSaverReleaseError.invalidMetadata }
        guard response.expectedContentLength <= limit else { throw TokenSaverReleaseError.oversized }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw TokenSaverReleaseError.oversized }
            data.append(byte)
        }
        return (data, http)
    }

    public func latest(for tool: TokenSaverReleaseTool) async throws -> TokenSaverRelease {
        struct Release: Decodable { let tag_name: String; let draft: Bool; let prerelease: Bool }
        let currentTime = now()
        let cached = cache.entry(for: tool)
        if let cached, freshnessTTL > 0,
           currentTime.timeIntervalSince(cached.checkedAt) >= 0,
           currentTime.timeIntervalSince(cached.checkedAt) < freshnessTTL {
            return cached.release
        }
        let releaseETag = (cached?.release.isRelease == true) ? cached?.releaseETag : nil
        let (data, response) = try await request(
            tool, path: ["releases", "latest"], allowNotFound: true, ifNoneMatch: releaseETag
        )
        if response.statusCode == 304 {
            guard let cached, cached.release.isRelease else { throw TokenSaverReleaseError.invalidMetadata }
            cache.save(TokenSaverCachedRelease(
                release: cached.release,
                releaseETag: Self.etag(from: response) ?? cached.releaseETag,
                commitETag: cached.commitETag,
                checkedAt: now()
            ))
            return cached.release
        }
        if response.statusCode == 404 {
            // ponytail: repositories without releases use an explicitly labelled commit, never a made-up version.
            struct Commit: Decodable { let sha: String }
            let fallbackETag = (cached?.release.isRelease == false) ? cached?.commitETag : nil
            let (commits, commitResponse) = try await request(
                tool, path: ["commits"], query: [.init(name: "per_page", value: "1")], ifNoneMatch: fallbackETag
            )
            if commitResponse.statusCode == 304 {
                guard let cached, !cached.release.isRelease else { throw TokenSaverReleaseError.invalidMetadata }
                cache.save(TokenSaverCachedRelease(
                    release: cached.release,
                    releaseETag: nil,
                    commitETag: Self.etag(from: commitResponse) ?? cached.commitETag,
                    checkedAt: now()
                ))
                return cached.release
            }
            guard let commit = try JSONDecoder().decode([Commit].self, from: commits).first,
                  Self.validSHA(commit.sha) else { throw TokenSaverReleaseError.invalidMetadata }
            let result = TokenSaverRelease(tool: tool, version: "commit \(commit.sha.prefix(12))", commit: commit.sha, isRelease: false)
            cache.save(TokenSaverCachedRelease(
                release: result,
                releaseETag: nil,
                commitETag: Self.etag(from: commitResponse),
                checkedAt: now()
            ))
            return result
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease, Self.validVersion(release.tag_name) else {
            throw TokenSaverReleaseError.invalidMetadata
        }
        let matchingTag = (cached?.release.isRelease == true && cached?.release.version == release.tag_name) ? cached : nil
        struct Commit: Decodable { let sha: String }
        let (commitData, commitResponse) = try await request(
            tool, path: ["commits", release.tag_name], ifNoneMatch: matchingTag?.commitETag
        )
        if commitResponse.statusCode == 304 {
            guard let matchingTag else { throw TokenSaverReleaseError.invalidMetadata }
            cache.save(TokenSaverCachedRelease(
                release: matchingTag.release,
                releaseETag: Self.etag(from: response) ?? matchingTag.releaseETag,
                commitETag: Self.etag(from: commitResponse) ?? matchingTag.commitETag,
                checkedAt: now()
            ))
            return matchingTag.release
        }
        let commit = try JSONDecoder().decode(Commit.self, from: commitData)
        guard Self.validSHA(commit.sha) else { throw TokenSaverReleaseError.invalidMetadata }
        let result = TokenSaverRelease(tool: tool, version: release.tag_name, commit: commit.sha, isRelease: true)
        cache.save(TokenSaverCachedRelease(
            release: result,
            releaseETag: Self.etag(from: response),
            commitETag: Self.etag(from: commitResponse),
            checkedAt: now()
        ))
        return result
    }

    public func skill(for release: TokenSaverRelease) async throws -> Data {
        guard let path = release.tool.skillPath, Self.validSHA(release.commit) else {
            throw TokenSaverReleaseError.manualInstallation
        }
        struct Content: Decodable {
            let type: String; let path: String; let encoding: String
            let size: Int; let sha: String; let content: String
        }
        let (data, _) = try await request(release.tool, path: ["contents"] + path.components(separatedBy: "/"),
                                          query: [.init(name: "ref", value: release.commit)])
        let content = try JSONDecoder().decode(Content.self, from: data)
        guard content.type == "file", content.path == path, content.encoding == "base64",
              content.size > 0, content.size <= 128 * 1024,
              let bytes = Data(base64Encoded: content.content.filter { !$0.isWhitespace }),
              bytes.count == content.size,
              let markdown = String(data: bytes, encoding: .utf8), markdown.contains("name:"),
              !markdown.contains("\0") else { throw TokenSaverReleaseError.invalidMetadata }
        var blob = Data("blob \(bytes.count)\0".utf8)
        blob.append(bytes)
        let sha = Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
        guard sha == content.sha else { throw TokenSaverReleaseError.invalidMetadata }
        return bytes
    }

    static func validSHA(_ value: String) -> Bool {
        value.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func validVersion(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 200
            && !value.contains(where: { $0.isNewline || ($0.isASCII && ($0.asciiValue ?? 0) < 32) })
    }

    static func validETag(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256
            && !value.contains(where: { $0.isNewline || ($0.isASCII && ($0.asciiValue ?? 0) < 32) })
    }

    private static func etag(from response: HTTPURLResponse) -> String? {
        guard let raw = response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespacesAndNewlines),
              validETag(raw) else { return nil }
        return raw
    }

    private static func rateLimitResetHeader(from response: HTTPURLResponse) -> String? {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
           let seconds = TimeInterval(retryAfter), seconds > 0, seconds.isFinite {
            return String(Date().addingTimeInterval(seconds).timeIntervalSince1970)
        }
        if let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")?.trimmingCharacters(in: .whitespacesAndNewlines),
           let rem = Int(remaining), rem > 0 {
            return nil
        }
        return response.value(forHTTPHeaderField: "X-RateLimit-Reset")
    }

    private func request(_ tool: TokenSaverReleaseTool, path: [String], query: [URLQueryItem] = [],
                         allowNotFound: Bool = false, ifNoneMatch: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let components = ["repos"] + tool.repository.components(separatedBy: "/") + path
        var url = URLComponents(string: "https://api.github.com")!
        url.percentEncodedPath = "/" + components.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        if !query.isEmpty { url.queryItems = query }
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AIUsage-TokenSaver-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let validConditional = ifNoneMatch.flatMap { Self.validETag($0) ? $0 : nil }
        if let validConditional {
            request.setValue(validConditional, forHTTPHeaderField: "If-None-Match")
        }
        let limit = 512 * 1024
        let (data, response) = try await transport(request, limit)
        guard response.url == request.url else { throw TokenSaverReleaseError.invalidMetadata }
        guard data.count <= limit else { throw TokenSaverReleaseError.oversized }
        if response.statusCode == 403 || response.statusCode == 429 {
            throw TokenSaverReleaseError.rateLimited(Self.rateLimitResetHeader(from: response))
        }
        guard response.statusCode == 200
            || (allowNotFound && response.statusCode == 404)
            || (validConditional != nil && response.statusCode == 304) else {
            throw TokenSaverReleaseError.http(response.statusCode)
        }
        return (data, response)
    }
}
