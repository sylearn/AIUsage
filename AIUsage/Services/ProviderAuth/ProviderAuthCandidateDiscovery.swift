import Foundation
import QuotaBackend
import SQLite3

extension ProviderAuthManager {
    // MARK: - Candidate Discovery

    internal static func codexCandidates() -> [ProviderAuthCandidate] {
        var candidates: [ProviderAuthCandidate] = []

        let defaultURL = URL(fileURLWithPath: expand("~/.codex/auth.json"))
        if FileManager.default.fileExists(atPath: defaultURL.path),
           let json = loadJSONObject(at: defaultURL.path) {
            let email = jwtEmail(from: stringValue((json["tokens"] as? [String: Any])?["id_token"]))
                ?? stringValue(json["email"])
            candidates.append(
                ProviderAuthCandidate(
                    id: "codex:\(canonicalPath(defaultURL.path))",
                    providerId: "codex",
                    sourceIdentifier: "file:\(canonicalPath(defaultURL.path))",
                    sessionFingerprint: codexSessionFingerprint(from: json),
                    title: email ?? "Current ChatGPT login",
                    subtitle: "Current ChatGPT login",
                    detail: compactDetail(parts: [displayPath(defaultURL.path), formattedDate(modificationDate(for: defaultURL))]),
                    modifiedAt: modificationDate(for: defaultURL),
                    authMethod: .authFile,
                    credentialValue: defaultURL.path,
                    sourcePath: defaultURL.path,
                    shouldCopyFile: true,
                    identityScope: .sharedSource
                )
            )
        }

        return deduplicated(candidates)
    }

    internal static func copilotCandidates() -> [ProviderAuthCandidate] {
        var candidates: [ProviderAuthCandidate] = []

        if let session = currentGitHubCLISession() {
            candidates.append(
                ProviderAuthCandidate(
                    id: "copilot:\(session.sourceIdentifier)",
                    providerId: "copilot",
                    sourceIdentifier: session.sourceIdentifier,
                    sessionFingerprint: session.sessionFingerprint,
                    title: session.label,
                    subtitle: "GitHub CLI",
                    detail: session.detail,
                    modifiedAt: nil,
                    authMethod: .token,
                    credentialValue: session.token,
                    sourcePath: nil,
                    shouldCopyFile: false,
                    identityScope: .accountScoped
                )
            )
        }

        return deduplicated(candidates)
    }

    internal static func antigravityCandidates() -> [ProviderAuthCandidate] {
        guard let authStatus = readAntigravityAuthStatus() else { return [] }
        guard let apiKey = authStatus["apiKey"] as? String, !apiKey.isEmpty else { return [] }

        let email = authStatus["email"] as? String
        let name = authStatus["name"] as? String
        let title = email ?? name ?? "Antigravity IDE session"
        let sourceId = "antigravity-ide:\(email?.lowercased() ?? "default")"

        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let sessionDir = fileManager.temporaryDirectory
            .appendingPathComponent("aiusage-antigravity-import-\(sourceId.hashValue)", isDirectory: true)
        try? fileManager.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let authFileURL = sessionDir.appendingPathComponent("antigravity_ide_creds.json")

        var authJSON: [String: Any] = [
            "access_token": apiKey,
            "token_type": "Bearer",
            "expired": "2000-01-01T00:00:00Z"
        ]
        if let email { authJSON["email"] = email }
        if let refreshToken = extractAntigravityRefreshToken() {
            authJSON["refresh_token"] = refreshToken
        }

        guard let data = try? JSONSerialization.data(withJSONObject: authJSON, options: [.prettyPrinted, .sortedKeys]),
              let _ = try? data.write(to: authFileURL, options: .atomic) else {
            return []
        }

        let dbPath = "\(home)/Library/Application Support/Antigravity/User/globalStorage/state.vscdb"
        let dbURL = URL(fileURLWithPath: dbPath)
        let modifiedAt = modificationDate(for: dbURL)

        return [
            ProviderAuthCandidate(
                id: "antigravity:\(sourceId)",
                providerId: "antigravity",
                sourceIdentifier: sourceId,
                sessionFingerprint: normalizedHandle(email),
                title: title,
                subtitle: "Antigravity IDE",
                detail: compactDetail(parts: [email, formattedDate(modifiedAt)].compactMap { $0 }),
                modifiedAt: modifiedAt,
                authMethod: .authFile,
                credentialValue: authFileURL.path,
                sourcePath: authFileURL.path,
                shouldCopyFile: true,
                identityScope: .sharedSource
            )
        ]
    }

    private static let antigravityDBPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Antigravity/User/globalStorage/state.vscdb"
    }()

    private static func readAntigravityAuthStatus() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: antigravityDBPath) else { return nil }
        guard let db = openSQLiteDB(at: antigravityDBPath) else { return nil }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let query = "SELECT value FROM ItemTable WHERE key = 'antigravityAuthStatus'"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cString = sqlite3_column_text(stmt, 0) else { return nil }

        let jsonString = String(cString: cString)
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func extractAntigravityRefreshToken() -> String? {
        guard FileManager.default.fileExists(atPath: antigravityDBPath) else { return nil }
        guard let db = openSQLiteDB(at: antigravityDBPath) else { return nil }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let query = "SELECT value FROM ItemTable WHERE key = 'antigravityUnifiedStateSync.oauthToken'"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cString = sqlite3_column_text(stmt, 0) else { return nil }

        let b64String = String(cString: cString)
        guard let outerDecoded = Data(base64Encoded: b64String) else { return nil }

        // Protobuf binary: use .isoLatin1 to losslessly map every byte to a character
        guard let outerText = String(data: outerDecoded, encoding: .isoLatin1) else { return nil }

        guard let refreshTokenPattern = try? NSRegularExpression(pattern: #"1//[A-Za-z0-9_-]+"#) else { return nil }

        if let match = refreshTokenPattern.firstMatch(in: outerText, range: NSRange(outerText.startIndex..., in: outerText)),
           let range = Range(match.range, in: outerText) {
            return String(outerText[range])
        }

        // Protobuf nests tokens inside inner Base64 segments; decode and search each
        guard let innerB64Pattern = try? NSRegularExpression(pattern: #"[A-Za-z0-9+/_-]{40,}"#) else { return nil }
        let innerMatches = innerB64Pattern.matches(in: outerText, range: NSRange(outerText.startIndex..., in: outerText))
        for innerMatch in innerMatches {
            guard let matchRange = Range(innerMatch.range, in: outerText) else { continue }
            let segment = String(outerText[matchRange])
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let padded = segment + String(repeating: "=", count: (4 - segment.count % 4) % 4)
            guard let innerData = Data(base64Encoded: padded),
                  let innerText = String(data: innerData, encoding: .isoLatin1) else {
                continue
            }
            if let match = refreshTokenPattern.firstMatch(in: innerText, range: NSRange(innerText.startIndex..., in: innerText)),
               let range = Range(match.range, in: innerText) {
                return String(innerText[range])
            }
        }
        return nil
    }

    private static func openSQLiteDB(at path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_exec(db, "PRAGMA journal_mode=wal;", nil, nil, nil)
        return db
    }

    private static let kiroFingerprintKeys = ["email", "userId", "accountEmail", "profile_arn", "profileArn"]

    internal static func kiroCandidates() -> [ProviderAuthCandidate] {
        var candidates: [ProviderAuthCandidate] = []

        let ideURL = URL(fileURLWithPath: expand("~/.aws/sso/cache/kiro-auth-token.json"))
        if FileManager.default.fileExists(atPath: ideURL.path),
           let json = loadJSONObject(at: ideURL.path) {
            let provider = stringValue(json["provider"]) ?? "IDE"
            candidates.append(
                ProviderAuthCandidate(
                    id: "kiro:\(canonicalPath(ideURL.path))",
                    providerId: "kiro",
                    sourceIdentifier: "file:\(canonicalPath(ideURL.path))",
                    sessionFingerprint: sessionFingerprint(from: json, preferredKeys: kiroFingerprintKeys),
                    title: "Kiro (\(provider))",
                    subtitle: "IDE session cache",
                    detail: compactDetail(parts: [displayPath(ideURL.path), formattedDate(modificationDate(for: ideURL))]),
                    modifiedAt: modificationDate(for: ideURL),
                    authMethod: .authFile,
                    credentialValue: ideURL.path,
                    sourcePath: ideURL.path,
                    shouldCopyFile: true,
                    identityScope: .sharedSource
                )
            )
        }

        return deduplicated(candidates)
    }

    internal static func kimiCandidates() -> [ProviderAuthCandidate] {
        let configURL = URL(fileURLWithPath: expand("~/.kimi/config.toml"))
        let modifiedAt = modificationDate(for: configURL)
        let candidates = KimiProvider.discoverLocalCredentials().map { local -> ProviderAuthCandidate in
            let fingerprint = tokenFingerprint(local.apiKey)
            let title = local.providerSection.map { "Kimi Code · \($0)" } ?? "Kimi Code"
            return ProviderAuthCandidate(
                id: "kimi:\(fingerprint)",
                providerId: "kimi",
                sourceIdentifier: "kimi-config:\(fingerprint)",
                sessionFingerprint: fingerprint,
                title: title,
                subtitle: "~/.kimi/config.toml",
                detail: compactDetail(parts: [maskedSecret(local.apiKey), formattedDate(modifiedAt)]),
                modifiedAt: modifiedAt,
                authMethod: .apiKey,
                credentialValue: local.apiKey,
                sourcePath: nil,
                shouldCopyFile: false,
                identityScope: .accountScoped
            )
        }
        return deduplicated(candidates)
    }

    private static func maskedSecret(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 10 else { return "••••" }
        return "\(trimmed.prefix(6))…\(trimmed.suffix(4))"
    }

    internal static func geminiCandidates() -> [ProviderAuthCandidate] {
        let oauthURL = URL(fileURLWithPath: expand("~/.gemini/oauth_creds.json"))
        guard FileManager.default.fileExists(atPath: oauthURL.path),
              let json = loadJSONObject(at: oauthURL.path) else {
            return []
        }

        let email = stringValue(json["email"])
            ?? jwtEmail(from: stringValue(json["id_token"]))
            ?? "Current Gemini CLI session"
        return [
            ProviderAuthCandidate(
                id: "gemini:\(canonicalPath(oauthURL.path))",
                providerId: "gemini",
                sourceIdentifier: "file:\(canonicalPath(oauthURL.path))",
                sessionFingerprint: sessionFingerprint(from: json, preferredKeys: ["email"]),
                title: email,
                subtitle: "Current Gemini CLI login",
                detail: compactDetail(parts: [displayPath(oauthURL.path), formattedDate(modificationDate(for: oauthURL))]),
                modifiedAt: modificationDate(for: oauthURL),
                authMethod: .authFile,
                credentialValue: oauthURL.path,
                sourcePath: oauthURL.path,
                shouldCopyFile: true,
                identityScope: .sharedSource
            )
        ]
    }

    /// Droid 仅保留官方 API Key（fk-…）方式：浏览器 Cookie / auth.v2.file 刷新令牌那套
    /// 既脆弱（频繁「不可用」）、浏览器登录又常失效（Login state invalid/expired），所以这里
    /// 只发现 FACTORY_API_KEY 候选，连接面板也只暴露粘贴 Key 一条路径——最稳、最安全。
    /// 注意：后端仍保留 authFile/cookie 的处理，以兼容历史已存凭证，只是不再主动发现。
    internal static func droidCandidates() -> [ProviderAuthCandidate] {
        deduplicated(factoryAPIKeyCandidates())
    }

    /// 发现官方 FACTORY_API_KEY（fk-…）。CLI 文档建议把它写进 shell profile（~/.zshrc 等）或
    /// 作为环境变量，因此这里扫描环境变量与常见 profile 文件，作为 .apiKey 候选呈现。
    /// 注意：GUI 应用通常不继承交互式 shell 的环境变量，所以多数情况下要靠 profile 扫描或手动粘贴。
    internal static func factoryAPIKeyCandidates() -> [ProviderAuthCandidate] {
        var found: [(key: String, source: String)] = []

        if let envKey = ProcessInfo.processInfo.environment["FACTORY_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !envKey.isEmpty {
            found.append((envKey, "FACTORY_API_KEY (env)"))
        }

        let profiles = ["~/.zshrc", "~/.zprofile", "~/.bashrc", "~/.bash_profile", "~/.profile"]
        for rawPath in profiles {
            let path = expand(rawPath)
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for key in factoryAPIKeys(inShellProfile: contents) {
                found.append((key, displayPath(path)))
            }
        }

        var seen = Set<String>()
        return found.compactMap { entry -> ProviderAuthCandidate? in
            let fingerprint = tokenFingerprint(entry.key)
            guard seen.insert(fingerprint).inserted else { return nil }
            return ProviderAuthCandidate(
                id: "droid:apikey:\(fingerprint)",
                providerId: "droid",
                sourceIdentifier: "factory-api-key:\(fingerprint)",
                sessionFingerprint: fingerprint,
                title: "Factory API Key",
                subtitle: entry.source,
                detail: compactDetail(parts: [maskedSecret(entry.key), entry.source]),
                modifiedAt: nil,
                authMethod: .apiKey,
                credentialValue: entry.key,
                sourcePath: nil,
                shouldCopyFile: false,
                identityScope: .accountScoped
            )
        }
    }

    private static let factoryAPIKeyRegex = try? NSRegularExpression(
        pattern: #"FACTORY_API_KEY\s*=\s*["']?(fk-[A-Za-z0-9._-]+)["']?"#
    )

    /// 从 shell profile 文本里抽取 `FACTORY_API_KEY=fk-…` 形式的赋值（兼容 export 与引号）。
    private static func factoryAPIKeys(inShellProfile contents: String) -> [String] {
        guard let regex = factoryAPIKeyRegex else { return [] }
        let range = NSRange(contents.startIndex..., in: contents)
        return regex.matches(in: contents, range: range).compactMap { match in
            guard match.numberOfRanges >= 2,
                  let valueRange = Range(match.range(at: 1), in: contents) else { return nil }
            return String(contents[valueRange])
        }
    }

    internal static func cursorCandidates() -> [ProviderAuthCandidate] {
        deduplicated(
            CursorProvider.discoverBrowserSessions().map { session in
                let profileLabel = "\(session.browserName) \(session.profileName)"
                let sourceIdentifier = "browser-profile:cursor:\(session.browserName.lowercased()):\(session.profileName.lowercased())"
                return ProviderAuthCandidate(
                    id: "cursor:\(sourceIdentifier)",
                    providerId: "cursor",
                    sourceIdentifier: sourceIdentifier,
                    sessionFingerprint: tokenFingerprint(session.cookieHeader),
                    title: session.accountHint ?? profileLabel,
                    subtitle: "Browser session",
                    detail: compactDetail(parts: [profileLabel, "cursor.com"]),
                    modifiedAt: nil,
                    authMethod: .cookie,
                    credentialValue: session.cookieHeader,
                    sourcePath: nil,
                    shouldCopyFile: false,
                    identityScope: .sharedSource
                )
            }
        )
    }
}
