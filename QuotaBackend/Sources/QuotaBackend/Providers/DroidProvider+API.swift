import Foundation

// MARK: - Droid Provider — API

extension DroidProvider {
    func fetchSnapshot(
        auth: DroidAuth,
        persistencePath: String?
    ) async throws -> ([String: Any], [String: Any], DroidAuth) {
        var lastError: Error = ProviderError("not_logged_in", "Could not connect to the Droid API.")

        for candidateAuth in authVariants(for: auth) {
            for baseURL in Self.baseURLs {
                do {
                    return try await fetchSnapshot(baseURL: baseURL, auth: candidateAuth)
                } catch {
                    lastError = error
                }
            }
        }

        if let providerError = lastError as? ProviderError,
           providerError.code == "invalid_credentials",
           let refreshedAuth = try? await refreshAuth(auth, persistencePath: persistencePath) {
            for candidateAuth in authVariants(for: refreshedAuth) {
                for baseURL in Self.baseURLs {
                    do {
                        return try await fetchSnapshot(baseURL: baseURL, auth: candidateAuth)
                    } catch {
                        lastError = error
                    }
                }
            }
        }

        throw lastError
    }

    private func fetchSnapshot(
        baseURL: String,
        auth: DroidAuth
    ) async throws -> ([String: Any], [String: Any], DroidAuth) {
        let authInfo = try await requestAuthInfo(baseURL: baseURL, auth: auth)
        let usageInfo: [String: Any]
        do {
            let billingLimits = try await requestBillingLimits(baseURL: baseURL, auth: auth)
            if billingLimits["usesTokenRateLimitsBilling"] as? Bool == true {
                usageInfo = ["billingLimits": billingLimits]
            } else {
                usageInfo = try await requestUsageInfo(baseURL: baseURL, auth: auth)
            }
        } catch let error as ProviderError where error.code == "invalid_credentials" {
            throw error
        } catch {
            usageInfo = try await requestUsageInfo(baseURL: baseURL, auth: auth)
        }
        return (authInfo, usageInfo, auth)
    }

    func authVariants(for auth: DroidAuth) -> [DroidAuth] {
        guard let cookieHeader = auth.cookieHeader.nilIfBlank else { return [auth] }

        var variants: [DroidAuth] = [auth]
        if auth.bearerToken != nil {
            variants.append(rebuildAuth(auth, withCookieHeader: cookieHeader, includeAuthorization: false))
        }

        let withoutStale = Self.filteredCookieHeader(cookieHeader, removing: Self.staleTokenCookieNames)
        if withoutStale != cookieHeader, !withoutStale.isEmpty {
            variants.append(rebuildAuth(auth, withCookieHeader: withoutStale, includeAuthorization: true))
            variants.append(rebuildAuth(auth, withCookieHeader: withoutStale, includeAuthorization: false))
        }

        let authOnly = Self.filteredCookieHeader(
            cookieHeader,
            keeping: Self.authSessionCookieNames.union(["session", "wos-session"])
        )
        if !authOnly.isEmpty,
           authOnly != cookieHeader,
           !variants.contains(where: { $0.cookieHeader == authOnly && $0.bearerToken == nil }) {
            variants.append(rebuildAuth(auth, withCookieHeader: authOnly, includeAuthorization: true))
            variants.append(rebuildAuth(auth, withCookieHeader: authOnly, includeAuthorization: false))
        }

        var seen = Set<String>()
        return variants.filter { variant in
            let key = "\(variant.cookieHeader ?? "")|auth:\(variant.bearerToken ?? "")"
            return seen.insert(key).inserted
        }
    }

    func rebuildAuth(_ auth: DroidAuth, withCookieHeader cookieHeader: String, includeAuthorization: Bool) -> DroidAuth {
        let normalizedCookie = Self.normalizeCookieHeader(cookieHeader)
        let token = includeAuthorization ? Self.bearerToken(fromCookieHeader: normalizedCookie) : nil
        let claims = parseJWTClaims(token ?? "")
        return DroidAuth(
            cookieHeader: normalizedCookie,
            bearerToken: token,
            refreshToken: auth.refreshToken,
            organizationId: auth.organizationId ?? claims["org_id"] as? String,
            userId: auth.userId ?? claims["sub"] as? String,
            source: auth.source
        )
    }

    func requestAuthInfo(baseURL: String, auth: DroidAuth) async throws -> [String: Any] {
        guard let url = URL(string: "\(baseURL)/api/app/auth/me") else {
            throw ProviderError("invalid_url", "Droid auth URL is invalid.")
        }
        return try await requestDroidJSON(url: url, method: "GET", body: nil, auth: auth)
    }

    func requestBillingLimits(baseURL: String, auth: DroidAuth) async throws -> [String: Any] {
        guard let url = URL(string: "\(baseURL)/api/billing/limits") else {
            throw ProviderError("invalid_url", "Droid billing limits URL is invalid.")
        }
        return try await requestDroidJSON(url: url, method: "GET", body: nil, auth: auth)
    }

    func requestUsageInfo(baseURL: String, auth: DroidAuth) async throws -> [String: Any] {
        guard var components = URLComponents(string: "\(baseURL)/api/organization/subscription/usage") else {
            throw ProviderError("invalid_url", "Droid usage URL is invalid.")
        }
        var queryItems: [URLQueryItem] = [URLQueryItem(name: "useCache", value: "true")]
        if let userId = auth.userId { queryItems.append(URLQueryItem(name: "userId", value: userId)) }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw ProviderError("invalid_url", "Droid usage URL is invalid.")
        }
        return try await requestDroidJSON(url: url, method: "GET", body: nil, auth: auth)
    }

    func requestDroidJSON(
        url: URL,
        method: String,
        body: [String: Any]?,
        auth: DroidAuth
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://app.factory.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://app.factory.ai/", forHTTPHeaderField: "Referer")
        request.setValue("web-app", forHTTPHeaderField: "x-factory-client")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let cookieHeader = auth.cookieHeader.nilIfBlank {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let token = auth.bearerToken.nilIfBlank {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ProviderError("invalid_credentials", "Droid login state is invalid or expired.")
            }
            if !(200...299).contains(http.statusCode) {
                let body = String(data: data.prefix(512), encoding: .utf8) ?? ""
                throw ProviderError("api_error", "Droid API returned HTTP \(http.statusCode): \(body)")
            }
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError("parse_failed", "Droid API returned invalid JSON.")
        }
        return json
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        switch self {
        case .some(let value):
            return value.nilIfBlank
        case .none:
            return nil
        }
    }
}
