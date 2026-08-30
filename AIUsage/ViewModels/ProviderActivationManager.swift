import Foundation
import Combine
import QuotaBackend
import os.log

private let providerActivationLog = Logger(subsystem: "com.aiusage.desktop", category: "ProviderActivation")

extension Notification.Name {
    /// Codex 订阅账号即将激活（写 ~/.codex/auth.json）。Codex 代理监听此通知后自动停用，
    /// 还原 config.toml，避免 ~/.codex 下的 auth.json 与 config.toml 冲突、用量统计串台。
    static let codexSubscriptionAccountActivating = Notification.Name("com.aiusage.codexSubscriptionAccountActivating")
}

// MARK: - Provider Account Activation
// Manages CLI auth file switching for Codex and Gemini: detection from disk,
// activation from managed/proxy sources, format normalization, and UserDefaults persistence.

final class ProviderActivationManager: ObservableObject {
    static let shared = ProviderActivationManager()

    static let activatableProviders: Set<String> = ["codex", "gemini"]

    @Published var activeProviderAccountIds: [String: String] = {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.activeProviderAccountIds) else {
            if let legacyCodex = UserDefaults.standard.string(forKey: DefaultsKey.activeCodexAccountId) {
                return ["codex": legacyCodex]
            }
            return [:]
        }

        var ids: [String: String]
        do {
            ids = try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            providerActivationLog.error("Failed to decode persisted active provider ids: \(String(describing: error), privacy: .public)")
            if let legacyCodex = UserDefaults.standard.string(forKey: DefaultsKey.activeCodexAccountId) {
                return ["codex": legacyCodex]
            }
            return [:]
        }

        let staleKeys = ids.keys.filter { !activatableProviders.contains($0) }
        if !staleKeys.isEmpty {
            staleKeys.forEach { ids.removeValue(forKey: $0) }
            if let cleaned = try? JSONEncoder().encode(ids) {
                UserDefaults.standard.set(cleaned, forKey: DefaultsKey.activeProviderAccountIds)
            }
        }
        return ids
    }()

    @Published var activationResult: ActivationResult?
    @Published var codexActivationResult: CodexActivationResult?

    let accountStore = AccountStore.shared
    let settings = AppSettings.shared

    var activeCodexAccountId: String? {
        get { activeProviderAccountIds["codex"] }
        set {
            activeProviderAccountIds["codex"] = newValue
            persistActiveIds()
        }
    }

    enum CodexActivationResult: Equatable {
        case success(String)
        case failure(String)
    }

    enum ActivationResult: Equatable {
        case success(String)
        case failure(String)
    }

    private init() {}

    private func persistActiveIds() {
        do {
            let data = try JSONEncoder().encode(activeProviderAccountIds)
            UserDefaults.standard.set(data, forKey: DefaultsKey.activeProviderAccountIds)
        } catch {
            providerActivationLog.error("Failed to persist active provider ids: \(String(describing: error), privacy: .public)")
        }
    }

    func canActivateProvider(_ providerId: String) -> Bool {
        Self.activatableProviders.contains(providerId)
    }

    /// 互斥：Codex 代理接管 ~/.codex/config.toml 时调用，把当前 Codex 订阅账号标记为未激活，
    /// 保证账号轨道与代理轨道在 UI 与用量统计上互斥（不改动 auth.json 内容）。
    func markCodexSubscriptionInactiveForProxy() {
        guard activeProviderAccountIds["codex"] != nil else { return }
        activeProviderAccountIds["codex"] = nil
        persistActiveIds()
        providerActivationLog.info("Codex subscription account marked inactive due to proxy activation")
    }

    func activateAccount(entry: ProviderAccountEntry) throws {
        switch entry.providerId {
        case "codex":
            try activateCodexAccount(entry: entry)
        case "gemini":
            try activateGeminiAccount(entry: entry)
        default:
            break
        }
    }

    /// 用户主动停用某账号（清除该 provider 的「当前激活」标记，不改动 auth.json 内容）。
    /// 与节点开关「关」对齐：关掉后该 provider 无激活账号（账号轨道与代理轨道仍互斥）。
    func deactivateAccount(entry: ProviderAccountEntry) {
        guard isActiveAccount(entry) else { return }
        activeProviderAccountIds[entry.providerId] = nil
        persistActiveIds()
        providerActivationLog.info("Deactivated \(entry.providerId, privacy: .public) account by user toggle")
    }

    func isActiveAccount(_ entry: ProviderAccountEntry) -> Bool {
        guard let activeId = activeProviderAccountIds[entry.providerId]?.lowercased() else { return false }

        if AccountIdentityPolicy.isMultiWorkspace(entry.providerId) {
            let entryPath = entry.storedAccount?.sourceFilePath ?? entry.liveProvider?.sourceFilePath
            guard let entryPath else { return false }
            return AccountCredentialStore.normalizedAuthFilePath(entryPath) == activeId
        }

        let entryAccountId = (entry.storedAccount?.accountId ?? entry.liveProvider?.accountId)?.lowercased().nilIfBlank
        if let entryAccountId, entryAccountId == activeId {
            return true
        }

        let email = entry.accountEmail?.lowercased().nilIfBlank
        return email != nil && email == activeId
    }

    func isActiveCodexAccount(_ entry: ProviderAccountEntry) -> Bool {
        isActiveAccount(entry)
    }

    // MARK: Codex activation

    func activateCodexAccount(entry: ProviderAccountEntry) throws {
        let fm = FileManager.default
        let codexDir = NSString(string: "~/.codex").expandingTildeInPath
        let targetPath = "\(codexDir)/auth.json"

        let email = entry.accountEmail
            ?? entry.storedAccount?.email
            ?? entry.liveProvider?.accountLabel
        let accountId = entry.storedAccount?.accountId
            ?? entry.liveProvider?.accountId

        let resolved = resolveManagedSource(entry: entry)
        guard let resolved, fm.fileExists(atPath: resolved) else {
            let msg = settings.t("Auth file not found for this account.", "找不到该账号的认证文件")
            activationResult = .failure(msg)
            codexActivationResult = .failure(msg)
            throw ProviderError("source_not_found", msg)
        }

        let sourceData = try Data(contentsOf: URL(fileURLWithPath: resolved))
        let nativeData = try convertToCodexNativeFormat(sourceData)

        // 目标账号验证完成后再解除代理接管，避免坏文件让当前可用路由先被停掉。
        // 停进程走通知（异步），但文件必须在写账号之前同步归位，否则异步 restore 会覆盖新账号。
        NotificationCenter.default.post(name: .codexSubscriptionAccountActivating, object: nil)
        try CodexConfigManager.shared.restore()
        try writeAuthFileWithBackup(targetDir: codexDir, targetPath: targetPath, data: nativeData, fm: fm)

        let entryPath = entry.storedAccount?.sourceFilePath ?? entry.liveProvider?.sourceFilePath
        if let entryPath {
            activeProviderAccountIds["codex"] = AccountCredentialStore.normalizedAuthFilePath(entryPath)
        } else {
            activeProviderAccountIds["codex"] = accountId ?? email
        }
        persistActiveIds()

        let label = email ?? accountId ?? "Codex"
        let msg = settings.t("Switched to \(label)", "已切换到 \(label)")
        activationResult = .success(msg)
        codexActivationResult = .success(msg)
    }

    // MARK: Gemini activation

    func activateGeminiAccount(entry: ProviderAccountEntry) throws {
        let fm = FileManager.default
        let geminiDir = NSString(string: "~/.gemini").expandingTildeInPath
        let oauthCredsPath = "\(geminiDir)/oauth_creds.json"
        let googleAccountsPath = "\(geminiDir)/google_accounts.json"

        let email = entry.accountEmail
            ?? entry.storedAccount?.email
            ?? entry.liveProvider?.accountLabel

        let resolved = resolveManagedSource(entry: entry)

        guard let resolved, fm.fileExists(atPath: resolved) else {
            let msg = settings.t("Auth file not found for this account.", "找不到该账号的认证文件")
            activationResult = .failure(msg)
            throw ProviderError("source_not_found", msg)
        }

        let sourceData = try Data(contentsOf: URL(fileURLWithPath: resolved))
        let nativeData = try convertToGeminiNativeFormat(sourceData)

        try writeAuthFileWithBackup(targetDir: geminiDir, targetPath: oauthCredsPath, data: nativeData, fm: fm)

        if let email {
            try updateGeminiActiveAccount(googleAccountsPath: googleAccountsPath, email: email, fm: fm)
        }

        activeProviderAccountIds["gemini"] = email
        persistActiveIds()

        let label = email ?? "Account"
        let msg = settings.t("Switched to \(label)", "已切换到 \(label)")
        activationResult = .success(msg)
    }

    private func convertToGeminiNativeFormat(_ data: Data) throws -> Data {
        try CLIProxyGeminiCredentialBridge.makeNativePayload(from: data)
    }

    private func updateGeminiActiveAccount(googleAccountsPath: String, email: String, fm: FileManager) throws {
        var accounts: [String: Any]
        if let data = fm.contents(atPath: googleAccountsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            accounts = json
        } else {
            accounts = [:]
        }

        let previousActive = accounts["active"] as? String
        var oldList = (accounts["old"] as? [String]) ?? []

        if let previousActive, previousActive != email, !oldList.contains(previousActive) {
            oldList.append(previousActive)
        }
        oldList.removeAll { $0 == email }

        accounts["active"] = email
        accounts["old"] = oldList

        let data = try JSONSerialization.data(withJSONObject: accounts, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: googleAccountsPath), options: .atomic)
    }

    // MARK: Codex format conversion

    private func convertToCodexNativeFormat(_ data: Data) throws -> Data {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }

        if json["tokens"] is [String: Any], json["auth_mode"] != nil {
            return data
        }

        guard let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String else {
            return data
        }

        var native: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": accessToken,
                "refresh_token": refreshToken,
                "account_id": json["account_id"] ?? "",
                "id_token": json["id_token"] ?? ""
            ] as [String: Any],
            "last_refresh": json["last_refresh"] ?? SharedFormatters.iso8601String(from: Date())
        ]
        if let email = json["email"] as? String, !email.isEmpty {
            native["email"] = email
        }
        native["OPENAI_API_KEY"] = NSNull()

        return try JSONSerialization.data(withJSONObject: native, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: Shared helpers

    private func writeAuthFileWithBackup(targetDir: String, targetPath: String, data: Data, fm: FileManager) throws {
        if !fm.fileExists(atPath: targetDir) {
            try fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
        }

        let backupPath = "\(targetPath).bak"
        if fm.fileExists(atPath: targetPath) {
            try? fm.removeItem(atPath: backupPath)
            try fm.copyItem(atPath: targetPath, toPath: backupPath)
        }

        do {
            try data.write(to: URL(fileURLWithPath: targetPath), options: .atomic)
        } catch {
            if fm.fileExists(atPath: backupPath) {
                try? fm.removeItem(atPath: targetPath)
                try? fm.copyItem(atPath: backupPath, toPath: targetPath)
            }
            let redactedError = SensitiveDataRedactor.redactedMessage(for: error)
            let msg = settings.t("Switch failed: \(redactedError)", "切换失败：\(redactedError)")
            activationResult = .failure(msg)
            throw error
        }
    }

    private func resolveManagedSource(entry: ProviderAccountEntry) -> String? {
        let fm = FileManager.default

        let credentials = accountStore.matchingCredentials(for: entry)
        if let credential = credentials.first {
            let candidatePaths: [String?] = [
                credential.authMethod == .authFile ? credential.credential : nil,
                credential.metadata["sourcePath"]
            ]
            for p in candidatePaths.compactMap({ $0?.nilIfBlank }) {
                let expanded = NSString(string: p).expandingTildeInPath
                if fm.fileExists(atPath: expanded) { return expanded }
            }
        }

        return nil
    }

    // MARK: Detection

    private func applyDetectedActiveId(_ detectedId: String?, for providerId: String, reason: String) {
        let normalizedDetectedId = detectedId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let previousDetectedId = activeProviderAccountIds[providerId]

        if let normalizedDetectedId {
            guard normalizedDetectedId != previousDetectedId else { return }
            activeProviderAccountIds[providerId] = normalizedDetectedId
            persistActiveIds()
            return
        }

        guard previousDetectedId != nil else { return }
        activeProviderAccountIds.removeValue(forKey: providerId)
        persistActiveIds()
        providerActivationLog.info("Cleared active \(providerId, privacy: .public) account detection: \(reason, privacy: .public)")
    }

    private func jwtEmailFromToken(_ token: String?) -> String? {
        guard let token, token.contains(".") else { return nil }
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1])
        let remainder = payload.count % 4
        if remainder > 0 { payload += String(repeating: "=", count: 4 - remainder) }
        guard let decoded = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
              let email = claims["email"] as? String else {
            return nil
        }
        return email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    func detectActiveCodexAccount() {
        let authPath = NSString(string: "~/.codex/auth.json").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: authPath) else {
            applyDetectedActiveId(nil, for: "codex", reason: "auth file missing")
            return
        }

        let codexAccounts = accountStore.accountRegistry.filter { $0.providerId == "codex" }
        guard !codexAccounts.isEmpty else { return }

        // If there's already an active Codex ID that resolves to a known registered
        // account, keep it. This prevents the path-based heuristic below from
        // overwriting a user's explicit in-app account switch: activateCodexAccount
        // stores the *managed* entry path, but a naïve path match against
        // ~/.codex/auth.json would replace it with the CLI path and highlight the
        // wrong row.
        if let currentId = activeProviderAccountIds["codex"] {
            let stillValid = codexAccounts.contains { account in
                if let path = account.sourceFilePath {
                    return AccountCredentialStore.normalizedAuthFilePath(path) == currentId
                }
                let id = (account.accountId ?? account.email)?.lowercased()
                return id != nil && id == currentId
            }
            if stillValid { return }
        }

        // No valid active ID — detect from disk.
        // Prefer content-based matching (email from JWT / auth file).
        let normalizedPath = AccountCredentialStore.normalizedAuthFilePath(authPath)

        if let authJSON = Self.loadJSON(atPath: authPath) {
            if let email = extractEmailFromCodexAuth(authJSON) {
                let emailLower = email.lowercased()
                if let matched = codexAccounts.first(where: {
                    $0.email.lowercased() == emailLower
                        || $0.accountId?.lowercased() == emailLower
                }) {
                    let matchedPath = matched.sourceFilePath.flatMap {
                        AccountCredentialStore.normalizedAuthFilePath($0)
                    } ?? normalizedPath
                    applyDetectedActiveId(matchedPath, for: "codex", reason: "matched by auth file email")
                    return
                }
            }
        }

        // Fallback: path-based match
        if codexAccounts.first(where: {
            AccountIdentityPolicy.sourceFilePathsMatch($0.sourceFilePath, authPath)
        }) != nil {
            applyDetectedActiveId(normalizedPath, for: "codex", reason: "matched by sourceFilePath (fallback)")
            return
        }

        // Fallback: credential sourcePath match
        let credentials = AccountCredentialStore.shared.loadCredentials(for: "codex")
        if let credMatch = credentials.first(where: { cred in
            guard cred.authMethod == .authFile else { return false }
            let sourcePath = cred.metadata["sourcePath"]?.nilIfBlank ?? cred.credential
            return AccountCredentialStore.normalizedAuthFilePath(sourcePath) == normalizedPath
        }) {
            if let storedMatch = codexAccounts.first(where: { $0.credentialId == credMatch.id }) {
                let storedPath = storedMatch.sourceFilePath.flatMap {
                    AccountCredentialStore.normalizedAuthFilePath($0)
                } ?? normalizedPath
                applyDetectedActiveId(storedPath, for: "codex", reason: "matched managed credential")
                return
            }
        }
    }

    private func extractEmailFromCodexAuth(_ json: [String: Any]) -> String? {
        if let email = (json["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
            return email
        }
        if let tokens = json["tokens"] as? [String: Any] {
            if let email = jwtEmailFromToken(tokens["id_token"] as? String) { return email }
            if let email = jwtEmailFromToken(tokens["access_token"] as? String) { return email }
        }
        if let email = jwtEmailFromToken(json["id_token"] as? String) { return email }
        if let email = jwtEmailFromToken(json["access_token"] as? String) { return email }
        return nil
    }

    private static func loadJSON(atPath path: String) -> [String: Any]? {
        let expanded = NSString(string: path).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expanded) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func detectActiveGeminiAccount() {
        let googleAccountsPath = NSString(string: "~/.gemini/google_accounts.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: googleAccountsPath) else {
            applyDetectedActiveId(nil, for: "gemini", reason: "google_accounts.json missing")
            return
        }

        let json: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                applyDetectedActiveId(nil, for: "gemini", reason: "google_accounts.json root object is not a dictionary")
                return
            }
            json = object
        } catch {
            providerActivationLog.error("Failed to decode Gemini google_accounts.json: \(String(describing: error), privacy: .public)")
            applyDetectedActiveId(nil, for: "gemini", reason: "google_accounts.json contains invalid JSON")
            return
        }

        let active = (json["active"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        applyDetectedActiveId(active, for: "gemini", reason: "google_accounts.json has no active account")
    }

}
