import Foundation
import CommonCrypto

// MARK: - Cursor Provider
// 从 macOS Chromium 浏览器 Cookie 数据库读取会话 Cookie，调用 cursor.com API

public struct CursorProvider: ProviderFetcher, CredentialAcceptingProvider {
    public let id = "cursor"
    public let displayName = "Cursor"
    public let description = "Cursor AI usage quota"

    let timeoutSeconds: Double
    let homeDirectory: String

    static let usageSummaryURL = "https://cursor.com/api/usage-summary"
    static let authMeURL = "https://cursor.com/api/auth/me"
    static let usageURL = "https://cursor.com/api/usage"

    static let cookieDomains = ["cursor.com", "www.cursor.com", "cursor.sh", "authenticator.cursor.sh"]
    static let sessionCookieNames: Set<String> = [
        "WorkosCursorSessionToken", "__Secure-next-auth.session-token",
        "next-auth.session-token", "wos-session", "__Secure-wos-session",
        "authjs.session-token", "__Secure-authjs.session-token"
    ]

    static func browserProfiles(home: String) -> [(name: String, cookiesPath: String, keychainService: String)] {
        [
            ("Chrome",         "\(home)/Library/Application Support/Google/Chrome/Default/Cookies",                           "Chrome Safe Storage"),
            ("Chrome P1",      "\(home)/Library/Application Support/Google/Chrome/Profile 1/Cookies",                         "Chrome Safe Storage"),
            ("Edge",           "\(home)/Library/Application Support/Microsoft Edge/Default/Cookies",                           "Microsoft Edge Safe Storage"),
            ("Brave",          "\(home)/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies",              "Brave Safe Storage"),
            ("Cursor",         "\(home)/Library/Application Support/Cursor/Partitions/cursor-browser/Cookies",                 "Cursor Safe Storage"),
            ("Cursor-main",    "\(home)/Library/Application Support/Cursor/Cookies",                                           "Cursor Safe Storage"),
        ]
    }

    public var supportedAuthMethods: [AuthMethod] { [.cookie, .webSession, .auto] }

    public init(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
                timeoutSeconds: Double = 15) {
        self.homeDirectory = homeDirectory
        self.timeoutSeconds = timeoutSeconds
    }

    public func fetchUsage() async throws -> ProviderUsage {
        if let envCookie = ProcessInfo.processInfo.environment["CURSOR_COOKIE_HEADER"], !envCookie.isEmpty {
            return try await fetchWithCookie(envCookie, source: SourceInfo(mode: "manual", type: "env-var"))
        }

        var lastAutomaticError: Error?
        if let cookieHeader = try? importCookieFromBrowser() {
            let source = SourceInfo(mode: "auto", type: "browser-cookie")
            do {
                return try await fetchWithCookie(cookieHeader, source: source)
            } catch {
                // The local browser session may belong to a different or expired account.
                // Fall back to the saved per-account session before surfacing an error.
                lastAutomaticError = error
            }
        }

        let storedCreds = AccountCredentialStore.shared.loadCredentials(for: "cursor")
        for cred in storedCreds where cred.authMethod == .cookie || cred.authMethod == .webSession {
            if let usage = try? await fetchWithCookie(cred.credential, source: SourceInfo(mode: "stored", type: "keychain-credential")) {
                AccountCredentialStore.shared.updateLastUsed(cred)
                return usage
            }
        }

        if let lastAutomaticError {
            throw lastAutomaticError
        }
        throw ProviderError("not_logged_in", "No Cursor session cookie found. Log in to cursor.com in Chrome/Edge/Brave, or save a valid cookie.")
    }

    /// Fetch with externally provided credential (e.g. pasted cookie, WebView session)
    public func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage {
        guard supportedAuthMethods.contains(credential.authMethod) else {
            throw ProviderError("unsupported_auth_method", "Cursor does not support \(credential.authMethod) credentials.")
        }
        let source: SourceInfo
        switch credential.authMethod {
        case .cookie:
            source = SourceInfo(mode: "manual", type: "pasted-cookie")
        case .webSession:
            source = SourceInfo(mode: "stored", type: "webview-session")
        default:
            source = SourceInfo(mode: "manual", type: "imported-credential")
        }
        return try await fetchWithCookie(credential.credential, source: source)
    }

    private func fetchWithCookie(_ cookieHeader: String, source: SourceInfo) async throws -> ProviderUsage {
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

        // Fetch summary and user info in parallel
        async let summaryTask = fetchJSON(url: Self.usageSummaryURL, cookie: cookieHeader, userAgent: userAgent)
        async let userInfoTask = (try? await fetchJSON(url: Self.authMeURL, cookie: cookieHeader, userAgent: userAgent))

        let summary = try await summaryTask
        let userInfo = await userInfoTask

        // Fetch request usage if we have user ID
        var requestUsage: [String: Any]? = nil
        if let userId = userInfo?["sub"] as? String, !userId.isEmpty {
            let usageURLString = "\(Self.usageURL)?user=\(userId)"
            requestUsage = try? await fetchJSON(url: usageURLString, cookie: cookieHeader, userAgent: userAgent)
        }

        return parseResponse(summary: summary, userInfo: userInfo, requestUsage: requestUsage, source: source)
    }

    // MARK: - Cookie Import

    private func importCookieFromBrowser() throws -> String {
        try Self.importCookieFromBrowser(homeDirectory: homeDirectory)
    }

    public static func discoverBrowserSessions(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [BrowserDiscovery.DiscoveredSession] {
        var seen = Set<String>()
        return browserProfiles(home: homeDirectory).compactMap { profile in
            guard FileManager.default.fileExists(atPath: profile.cookiesPath),
                  let cookie = extractCookies(dbPath: profile.cookiesPath, keychainService: profile.keychainService) else {
                return nil
            }
            guard seen.insert(cookie).inserted else { return nil }
            return BrowserDiscovery.DiscoveredSession(
                browserName: profile.name,
                profileName: profile.name,
                cookieHeader: cookie,
                accountHint: nil
            )
        }
    }

    private static func importCookieFromBrowser(homeDirectory: String) throws -> String {
        if let session = discoverBrowserSessions(homeDirectory: homeDirectory).first {
            return session.cookieHeader
        }
        throw ProviderError("not_logged_in", "No Cursor session cookie found. Log in to cursor.com in Chrome/Edge/Brave, or set CURSOR_COOKIE_HEADER.")
    }

    private static func extractCookies(dbPath: String, keychainService: String) -> String? {
        let tempPath = NSTemporaryDirectory() + "cursor_\(ProcessInfo.processInfo.processIdentifier)_\(Int.random(in: 10000...99999)).db"
        defer {
            try? FileManager.default.removeItem(atPath: tempPath)
            try? FileManager.default.removeItem(atPath: tempPath + "-wal")
            try? FileManager.default.removeItem(atPath: tempPath + "-shm")
        }
        do { try FileManager.default.copyItem(atPath: dbPath, toPath: tempPath) } catch { return nil }
        try? FileManager.default.copyItem(atPath: dbPath + "-wal", toPath: tempPath + "-wal")
        try? FileManager.default.copyItem(atPath: dbPath + "-shm", toPath: tempPath + "-shm")

        // Read encrypted cookie blobs via sqlite3
        let domainSQL = Self.cookieDomains.map { "'\($0)'" }.joined(separator: ",")
        let nameSQL   = Self.sessionCookieNames.map { "'\($0)'" }.joined(separator: ",")
        let query = "SELECT name, encrypted_value FROM cookies WHERE host_key IN (\(domainSQL)) AND name IN (\(nameSQL)) LIMIT 10;"

        guard let rows = querySQLite(db: tempPath, sql: query) else { return nil }
        guard !rows.isEmpty else { return nil }

        // Get AES key from Keychain PBKDF2
        guard let aesKey = chromiumAESKey(keychainService: keychainService) else { return nil }

        var parts: [String] = []
        for row in rows {
            guard row.count >= 2 else { continue }
            let name = row[0]
            let encBlob = row[1]
            if let decrypted = CursorProvider.decryptChromiumCookie(blob: encBlob, key: aesKey) {
                parts.append("\(name)=\(decrypted)")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    // Query sqlite3 binary-safe using Process, returns rows as [[String]]
    private static func querySQLite(db: String, sql: String) -> [[String]]? {
        let domainSQL = Self.cookieDomains.map { "'\($0)'" }.joined(separator: ",")
        let nameSQL   = Self.sessionCookieNames.map { "'\($0)'" }.joined(separator: ",")
        let hexSQL = "SELECT name, hex(encrypted_value) FROM cookies WHERE host_key IN (\(domainSQL)) AND name IN (\(nameSQL)) LIMIT 10;"

        let hexTask = Process()
        hexTask.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        hexTask.arguments = [db, hexSQL]
        let hexPipe = Pipe()
        hexTask.standardOutput = hexPipe
        hexTask.standardError = Pipe()
        do { try hexTask.run(); hexTask.waitUntilExit() } catch { return nil }

        let output = String(data: hexPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let rows = output.components(separatedBy: "\n").filter { !$0.isEmpty }.map { $0.components(separatedBy: "|") }
        return rows.isEmpty ? nil : rows
    }

    // Derive AES-128 key: PBKDF2-SHA1(password, "saltysalt", 1003, 16)
    private static func chromiumAESKey(keychainService: String) -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run(); task.waitUntilExit() } catch { return nil }
        guard task.terminationStatus == 0 else { return nil }

        let password = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !password.isEmpty, let passData = password.data(using: .utf8) else { return nil }

        let salt = Data("saltysalt".utf8)
        var derivedKey = Data(count: 16)
        let status = derivedKey.withUnsafeMutableBytes { derivedKeyPtr in
            passData.withUnsafeBytes { passPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passPtr.baseAddress, passData.count,
                        saltPtr.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        derivedKeyPtr.baseAddress, 16
                    )
                }
            }
        }
        return status == kCCSuccess ? derivedKey : nil
    }

    // Decrypt Chromium v10/v11 AES-128-CBC cookie blob (hex string from sqlite hex())
    // Mirrors decryptChromiumCookieValue() in the original Node.js browserCookies.js
    static func decryptChromiumCookie(blob: String, key: Data) -> String? {
        guard blob.count >= 6 else { return nil }

        // Hex → Data
        var data = Data()
        var i = blob.startIndex
        while i < blob.endIndex {
            let j = blob.index(i, offsetBy: 2, limitedBy: blob.endIndex) ?? blob.endIndex
            if let byte = UInt8(blob[i..<j], radix: 16) { data.append(byte) }
            i = j
        }

        // Must start with v10 or v11
        guard data.count > 3 else { return nil }
        let prefix = String(bytes: data.prefix(3), encoding: .utf8) ?? ""
        guard prefix == "v10" || prefix == "v11" else { return nil }

        let payload = data.dropFirst(3)
        let iv = Data(repeating: 0x20, count: 16) // ' ' * 16

        guard let decrypted = aesCBCDecrypt(data: Data(payload), key: key, iv: iv) else { return nil }

        // Try full decrypted bytes first
        if let value = decodeCookieCandidate(decrypted) { return value }

        // Chromium v11: skip first 32 bytes (nonce prefix)
        if decrypted.count > 32, let value = decodeCookieCandidate(decrypted.dropFirst(32)) {
            return value
        }
        return nil
    }

    private static func aesCBCDecrypt(data: Data, key: Data, iv: Data) -> Data? {
        let outLen = data.count + kCCBlockSizeAES128
        var decrypted = Data(count: outLen)
        var decryptedLen = 0
        let status = decrypted.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            inPtr.baseAddress, data.count,
                            outPtr.baseAddress, outLen,
                            &decryptedLen
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, decryptedLen > 0 else { return nil }
        return decrypted.prefix(decryptedLen)
    }

    // Validates each byte is a valid cookie octet (mirrors isCookieOctet in JS)
    private static func decodeCookieCandidate(_ data: any DataProtocol) -> String? {
        let bytes = Array(data)
        guard !bytes.isEmpty else { return nil }
        for byte in bytes {
            let ok = byte == 0x21
                || (byte >= 0x23 && byte <= 0x2b)
                || (byte >= 0x2d && byte <= 0x3a)
                || (byte >= 0x3c && byte <= 0x5b)
                || (byte >= 0x5d && byte <= 0x7e)
            if !ok { return nil }
        }
        return String(bytes: bytes, encoding: .ascii)
    }

    // MARK: - API

    private func fetchJSON(url: String, cookie: String, userAgent: String) async throws -> [String: Any] {
        guard let requestURL = URL(string: url) else {
            throw ProviderError("invalid_url", "Cursor API URL is invalid.")
        }
        var request = QuotaHTTP.request(url: requestURL, timeout: timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await QuotaHTTP.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderError("invalid_credentials", "Cursor session cookie expired. Please log in again.")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError("parse_failed", "Cursor API returned invalid JSON.")
        }
        return json
    }

    // MARK: - Response Parsing (matches fetchCursorUsage.js parseCursorUsageResponse)

    private func parseResponse(summary: [String: Any], userInfo: [String: Any]?, requestUsage: [String: Any]?, source: SourceInfo) -> ProviderUsage {
        let billingEnd   = parseDate(summary["billingCycleEnd"] as? String)
        let resetDesc    = billingEnd.map { formatResetDescription($0) } ?? "Reset date unknown"

        let individual = summary["individualUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]

        let planUsedRaw = doubleValue(plan?["used"]) ?? 0
        let planLimitRaw = doubleValue(plan?["limit"]) ?? 0
        let autoPercent = clamp(doubleValue(plan?["autoPercentUsed"]))
        let apiPercent  = clamp(doubleValue(plan?["apiPercentUsed"]))
        let totalPercent = clamp(doubleValue(plan?["totalPercentUsed"]))

        let planPercentUsed: Double
        if let t = totalPercent { planPercentUsed = t }
        else if let a = autoPercent, let ap = apiPercent { planPercentUsed = (a + ap) / 2 }
        else if let a = autoPercent { planPercentUsed = a }
        else if let ap = apiPercent { planPercentUsed = ap }
        else if planLimitRaw > 0 { planPercentUsed = min(100, planUsedRaw / planLimitRaw * 100) }
        else { planPercentUsed = 0 }

        // Legacy request usage
        let gpt4 = requestUsage?["gpt-4"] as? [String: Any]
        let reqUsed = doubleValue(gpt4?["numRequestsTotal"] ?? gpt4?["numRequests"])
        let reqLimit = doubleValue(gpt4?["maxRequestUsage"])
        let isLegacy = reqLimit != nil && (reqLimit ?? 0) > 0

        let primaryPercent: Double
        if isLegacy, let ru = reqUsed, let rl = reqLimit, rl > 0 {
            primaryPercent = min(100, max(0, ru / rl * 100))
        } else {
            primaryPercent = planPercentUsed
        }

        let membershipType = summary["membershipType"] as? String
        let accountEmail = userInfo?["email"] as? String
        let trimmedSubject = (userInfo?["sub"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = accountEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let accountId = (trimmedSubject?.isEmpty == false ? trimmedSubject : nil)
            ?? (trimmedEmail?.isEmpty == false ? trimmedEmail : nil)

        var usage = ProviderUsage(provider: "cursor", label: "Cursor")
        usage.accountEmail = accountEmail
        usage.accountName  = userInfo?["name"] as? String
        usage.usageAccountId = accountId
        usage.accountPlan  = formatMembership(membershipType)

        usage.primary   = makePercentWindow(used: primaryPercent, billingEnd: billingEnd, resetDesc: resetDesc)
        usage.secondary = autoPercent.map { makePercentWindow(used: $0, billingEnd: billingEnd, resetDesc: resetDesc) }
        usage.tertiary  = apiPercent.map { makePercentWindow(used: $0, billingEnd: billingEnd, resetDesc: resetDesc) }

        // Extra fields
        let onDemand = individual?["onDemand"] as? [String: Any]
        usage.extra["membershipType"] = AnyCodable(membershipType ?? "")
        usage.extra["billingCycleEnd"] = AnyCodable(billingEnd.map { SharedFormatters.iso8601String(from: $0) } ?? "")
        usage.extra["billingCycleResetDescription"] = AnyCodable(resetDesc)
        usage.extra["includedPlan.usedUsd"]   = AnyCodable(centsToUsd(planUsedRaw))
        usage.extra["includedPlan.limitUsd"]  = AnyCodable(centsToUsd(planLimitRaw))
        usage.extra["onDemand.usedUsd"]       = AnyCodable(centsToUsd(doubleValue(onDemand?["used"]) ?? 0))

        usage.source = source
        return usage
    }

    private func makePercentWindow(used: Double, billingEnd: Date?, resetDesc: String) -> RawQuotaWindow {
        var w = RawQuotaWindow()
        w.usedPercent = used
        w.remainingPercent = max(0, 100 - used)
        w.resetAt = billingEnd.map { SharedFormatters.iso8601String(from: $0) }
        w.resetDescription = resetDesc
        return w
    }

    private func formatMembership(_ raw: String?) -> String? {
        guard let r = raw?.trimmingCharacters(in: .whitespaces), !r.isEmpty else { return nil }
        switch r.lowercased() {
        case "enterprise": return "Enterprise"
        case "pro": return "Pro"
        case "hobby": return "Hobby"
        case "team": return "Team"
        default: return r.capitalized
        }
    }

    private func formatResetDescription(_ date: Date) -> String {
        let day = DateFormat.string(from: date, format: "MMM d")
        let time = DateFormat.string(from: date, format: "h:mma")
        return "Resets \(day) at \(time)"
    }

    private func centsToUsd(_ cents: Double) -> Double { cents / 100 }

    private func doubleValue(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let n as Int: return Double(n)
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private func clamp(_ v: Double?) -> Double? {
        v.map { min(100, max(0, $0)) }
    }

    private func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return SharedFormatters.parseISO8601(s)
    }
}
