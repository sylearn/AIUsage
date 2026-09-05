import CryptoKit
import Foundation
import QuotaBackend

struct GitHubCLISession {
    let label: String
    let token: String
    let detail: String
    let sourceIdentifier: String
    let sessionFingerprint: String
}

extension ProviderAuthManager {
    // MARK: - Parsing Helpers

    static func currentGitHubCLISession() -> GitHubCLISession? {
        let token = runCommand(path: "/opt/homebrew/bin/gh", arguments: ["auth", "token"])
            ?? runCommand(path: "/usr/local/bin/gh", arguments: ["auth", "token"])
            ?? runCommand(path: "/usr/bin/gh", arguments: ["auth", "token"])
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return nil
        }

        let hostsPath = expand("~/.config/gh/hosts.yml")
        let hostsContent = try? String(contentsOfFile: hostsPath, encoding: .utf8)
        let username = hostsContent?
            .components(separatedBy: .newlines)
            .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("user:") })?
            .components(separatedBy: ":")
            .dropFirst()
            .joined(separator: ":")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let label = username?.nilIfBlank ?? "Current GitHub CLI session"
        return GitHubCLISession(
            label: label,
            token: token,
            detail: displayPath(hostsPath),
            sourceIdentifier: "gh-cli:\(label.lowercased())",
            sessionFingerprint: tokenFingerprint(token)
        )
    }

    static func loadJSONObject(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func jwtEmail(from token: String?) -> String? {
        jwtClaim("email", from: token)
    }

    static func jwtClaim(_ claim: String, from token: String?) -> String? {
        guard let token, token.contains(".") else { return nil }
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1])
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        payload = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let value = stringValue(json[claim]) {
            return value
        }
        if let profile = json["https://api.openai.com/profile"] as? [String: Any] {
            return stringValue(profile[claim])
        }
        return nil
    }

    static func sessionFingerprint(from json: [String: Any], preferredKeys: [String] = []) -> String? {
        for key in preferredKeys {
            if let value = stringValue(json[key]) {
                return normalizedHandle(value)
            }
        }

        let tokens = json["tokens"] as? [String: Any]

        // Also check preferred keys inside nested "tokens" dict (e.g. Codex auth.json
        // stores account_id under tokens, not at root level).
        if let tokens {
            for key in preferredKeys {
                if let value = stringValue(tokens[key]) {
                    return normalizedHandle(value)
                }
            }
        }

        // Provider-native Codex identity is workspace + user. Keep the same user
        // claim precedence as CodexProvider and the CPA identity parser; email is
        // only a final display-oriented fallback.
        let idTokenForJWT = stringValue(json["id_token"]) ?? stringValue(tokens?["id_token"])
        if let accountId = jwtAuthClaim("chatgpt_account_id", from: idTokenForJWT) {
            let userIdentity = jwtAuthClaim("chatgpt_user_id", from: idTokenForJWT)
                ?? jwtAuthClaim("user_id", from: idTokenForJWT)
                ?? jwtClaim("user_id", from: idTokenForJWT)
                ?? jwtClaim("sub", from: idTokenForJWT)
                ?? jwtEmail(from: idTokenForJWT)
            if let userIdentity {
                return normalizedHandle("\(accountId):\(userIdentity)")
            }
            return normalizedHandle(accountId)
        }

        if let email = jwtEmail(from: stringValue(json["id_token"])) {
            return normalizedHandle(email)
        }

        if let subject = jwtClaim("sub", from: stringValue(json["id_token"])) {
            return normalizedHandle(subject)
        }

        if let tokens {
            if let email = jwtEmail(from: stringValue(tokens["id_token"])) {
                return normalizedHandle(email)
            }

            if let subject = jwtClaim("sub", from: stringValue(tokens["id_token"])) {
                return normalizedHandle(subject)
            }

            for key in ["refresh_token", "access_token", "id_token"] {
                if let token = stringValue(tokens[key]) {
                    return tokenFingerprint(token)
                }
            }
        }

        for key in ["account_id", "email", "username", "login", "userId", "accountEmail", "refresh_token", "access_token", "id_token"] {
            if let value = stringValue(json[key]) {
                return key.contains("token") ? tokenFingerprint(value) : normalizedHandle(value)
            }
        }

        return nil
    }

    /// Extract a claim from the JWT's `https://api.openai.com/auth` namespace.
    static func jwtAuthClaim(_ claim: String, from token: String?) -> String? {
        guard let token, token.contains(".") else { return nil }
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1])
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        payload = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let auth = json["https://api.openai.com/auth"] as? [String: Any] {
            return stringValue(auth[claim])
        }
        return nil
    }

    static func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func readableFilename(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    static func formattedDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        let locale = Locale.current
        let format = DateFormatter.dateFormat(fromTemplate: "yMMdjm", options: 0, locale: locale) ?? "MMM d, yyyy, h:mm a"
        return DateFormat.formatter(format, timeZone: .current, locale: locale).string(from: date)
    }

    static func compactDetail(parts: [String?]) -> String {
        parts.compactMap { $0?.nilIfBlank }.joined(separator: " · ")
    }

    static func normalizedHandle(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    static func displayPath(_ path: String) -> String {
        path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    static func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func authFileSourceIdentifier(for value: String, authMethod: AuthMethod) -> String? {
        guard authMethod == .authFile else { return nil }
        return "file:\(canonicalPath(value))"
    }

    static func sourceIdentifierIsStableIdentity(for credential: AccountCredential) -> Bool {
        credential.metadata["identityScope"] == ProviderAuthCandidate.IdentityScope.accountScoped.rawValue
    }

    private static func sourceIdentifierIsStableIdentity(for candidate: ProviderAuthCandidate) -> Bool {
        candidate.identityScope == .accountScoped
    }

    static func sanitizedFilenameStem(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let joined = String(scalars)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return joined.nilIfBlank ?? "account"
    }

    static func tokenFingerprint(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func codexSessionFingerprint(from json: [String: Any]) -> String? {
        if let key = CodexAccountIdentity(authJSON: json).key { return key }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return nil }
        return "codex:raw:\(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())"
    }

    static func deduplicated(_ candidates: [ProviderAuthCandidate]) -> [ProviderAuthCandidate] {
        var seen = Set<String>()
        return candidates.filter { candidate in
            let key = candidate.sessionFingerprint.map { "fp:\($0)" } ?? "source:\(candidate.sourceIdentifier)"
            return seen.insert(key).inserted
        }
    }

    static func isCandidateManaged(_ candidate: ProviderAuthCandidate, monitored: ProviderMonitoredSessionIndex) -> Bool {
        if candidate.providerId == "codex" {
            // 公共 auth 路径、旧式 workspace-only 指纹和邮箱都不能抑制另一个订阅。
            guard let fingerprint = candidate.sessionFingerprint, fingerprint.hasPrefix("codex:") else { return false }
            return monitored.sessionFingerprints.contains(fingerprint)
        }
        if sourceIdentifierIsStableIdentity(for: candidate),
           monitored.sourceIdentifiers.contains(candidate.sourceIdentifier) {
            return true
        }

        if let fingerprint = candidate.sessionFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           monitored.sessionFingerprints.contains(fingerprint) {
            return true
        }

        let normalizedTitle = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return monitored.accountHandles.contains(normalizedTitle)
    }

    static func runCommand(path: String, arguments: [String]) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}
