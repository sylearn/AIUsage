import Foundation

/// Shared HTTP plumbing for quota lookups.
///
/// Quota endpoints are usually a single fixed URL (for example
/// `https://chatgpt.com/backend-api/wham/usage`) where the account identity
/// travels in request headers only. `URLCache` keys entries by URL + HTTP
/// method and ignores headers, so `URLSession.shared` happily serves account A's
/// cached response to account B — or replays a stale payload after a manual
/// refresh. Every quota GET therefore goes through this cache-free session.
enum QuotaHTTP {
    /// Ephemeral session with caching disabled at the configuration level.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Builds a request that opts out of caching on both the client and any
    /// intermediate proxy.
    static func request(url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
