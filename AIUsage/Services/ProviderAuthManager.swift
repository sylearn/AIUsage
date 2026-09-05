import AppKit
import Foundation
import QuotaBackend

enum ProviderAuthManager {
    static func plan(for providerId: String) -> ProviderAuthPlan {
        switch providerId {
        case "cursor":
            return ProviderAuthPlan(
                titleEn: "Connect a Cursor account",
                titleZh: "连接 Cursor 账号",
                summaryEn: "Sign in inside the embedded browser and AIUsage will start monitoring that Cursor account immediately.",
                summaryZh: "直接在内置浏览器里登录，AIUsage 会立刻开始监控这个 Cursor 账号。",
                launchActions: [],
                supportsEmbeddedWebLogin: true
            )
        case "codex":
            return ProviderAuthPlan(
                titleEn: "Connect a Codex account",
                titleZh: "连接 Codex 账号",
                summaryEn: "AIUsage can start an isolated ChatGPT sign-in just for this Codex account, show the official OpenAI page inside the app, and save the finished login as a separate monitored account automatically.",
                summaryZh: "AIUsage 会为这个 Codex 账号启动一条隔离的 ChatGPT 登录流程，在应用内展示 OpenAI 官方登录页，并在完成后自动保存成独立的监控账号。",
                launchActions: [
                    ProviderAuthLaunchAction(
                        id: "codex-login",
                        titleEn: "Continue with ChatGPT",
                        titleZh: "使用 ChatGPT 继续",
                        subtitleEn: "AIUsage opens the official OpenAI sign-in page in a secure window and connects the account automatically after login.",
                        subtitleZh: "AIUsage 会在安全窗口中打开 OpenAI 官方登录页，并在登录完成后自动接入这个账号。",
                        kind: .runTerminal(command: "codex login")
                    ),
                    ProviderAuthLaunchAction(
                        id: "codex-docs",
                        titleEn: "Open Official Login Guide",
                        titleZh: "打开官方登录说明",
                        subtitleEn: "Read the Codex CLI quickstart if you want the official ChatGPT login notes.",
                        subtitleZh: "如果想看 OpenAI 官方的 ChatGPT 登录说明，可以打开 Codex CLI quickstart。",
                        kind: .openURL(URL(string: "https://github.com/openai/codex#using-codex-with-your-chatgpt-plan")!)
                    )
                ],
                supportsEmbeddedWebLogin: false
            )
        case "copilot":
            return ProviderAuthPlan(
                titleEn: "Connect a GitHub Copilot account",
                titleZh: "连接 GitHub Copilot 账号",
                summaryEn: "Sign in with your GitHub account. AIUsage opens the official GitHub authorization page in your browser and connects the account automatically after you approve.",
                summaryZh: "使用 GitHub 账号登录。AIUsage 会在浏览器中打开 GitHub 官方授权页，你确认后即自动接入。",
                launchActions: [
                    ProviderAuthLaunchAction(
                        id: "copilot-gh-login",
                        titleEn: "Sign in with GitHub",
                        titleZh: "使用 GitHub 登录",
                        subtitleEn: "Opens the GitHub sign-in page in your browser. No gh CLI required.",
                        subtitleZh: "在浏览器中打开 GitHub 登录页，无需安装 gh 命令行工具。",
                        kind: .runTerminal(command: "copilot")
                    )
                ],
                supportsEmbeddedWebLogin: false
            )
        case "antigravity":
            return ProviderAuthPlan(
                titleEn: "Connect an Antigravity account",
                titleZh: "连接 Antigravity 账号",
                summaryEn: "Sign in with your Google account. AIUsage will also detect any existing Antigravity IDE session below.",
                summaryZh: "使用 Google 账号登录。AIUsage 也会在下方检测已有的 Antigravity IDE 会话。",
                launchActions: [
                    ProviderAuthLaunchAction(
                        id: "antigravity-login",
                        titleEn: "Sign in with Google",
                        titleZh: "使用 Google 登录",
                        subtitleEn: "Opens Google sign-in in your browser. No Antigravity installation required.",
                        subtitleZh: "在浏览器中打开 Google 登录页，无需安装 Antigravity 应用。",
                        kind: .runTerminal(command: "antigravity")
                    ),
                    ProviderAuthLaunchAction(
                        id: "antigravity-app",
                        titleEn: "Open Antigravity",
                        titleZh: "打开 Antigravity",
                        subtitleEn: "Launch the Antigravity app to sign in with another account.",
                        subtitleZh: "打开 Antigravity 应用，用另一个账号完成登录。",
                        kind: .openApp(bundleIdentifier: "com.google.antigravity")
                    )
                ],
                supportsEmbeddedWebLogin: false
            )
        case "kiro":
            return ProviderAuthPlan(
                titleEn: "Connect a Kiro account",
                titleZh: "连接 Kiro 账号",
                summaryEn: "Sign in with your Google, GitHub, Builder ID, or organization account. AIUsage opens the Kiro sign-in page in your browser and connects automatically after you approve.",
                summaryZh: "使用 Google、GitHub、Builder ID 或组织账号登录。AIUsage 会在浏览器中打开 Kiro 登录页，你确认后即自动接入。",
                launchActions: [
                    ProviderAuthLaunchAction(
                        id: "kiro-login",
                        titleEn: "Sign in with Kiro",
                        titleZh: "使用 Kiro 登录",
                        subtitleEn: "Opens the Kiro sign-in page in your browser. Supports Google, GitHub, Builder ID, and organization login.",
                        subtitleZh: "在浏览器中打开 Kiro 登录页，支持 Google、GitHub、Builder ID 和组织登录。",
                        kind: .runTerminal(command: "kiro")
                    ),
                    ProviderAuthLaunchAction(
                        id: "kiro-app",
                        titleEn: "Open Kiro App",
                        titleZh: "打开 Kiro 应用",
                        subtitleEn: "Launch the Kiro desktop app if you prefer signing in there.",
                        subtitleZh: "如果你更习惯在 Kiro 应用里登录，可以打开它。",
                        kind: .openApp(bundleIdentifier: "dev.kiro.desktop")
                    )
                ],
                supportsEmbeddedWebLogin: false
            )
        case "kimi":
            return ProviderAuthPlan(
                titleEn: "Connect a Kimi Code account",
                titleZh: "连接 Kimi Code 账号",
                summaryEn: "Paste a Kimi Code API key (sk-…) created in the Kimi Code Console. AIUsage tracks the same weekly and rolling rate-limit windows the `/usage` command shows. Local ~/.kimi keys are detected automatically.",
                summaryZh: "粘贴在 Kimi Code 控制台创建的 API Key（sk-…）。AIUsage 会监控与 `/usage` 命令一致的本周用量和滚动频控窗口。若本机 ~/.kimi 已有 Key 会自动检测。",
                launchActions: [],
                supportsEmbeddedWebLogin: false
            )
        case "minimax":
            return ProviderAuthPlan(
                titleEn: "Connect a MiniMax Token Plan account",
                titleZh: "连接 MiniMax Token Plan 账号",
                summaryEn: "Paste your Subscription Key (sk-cp-…) from platform.minimaxi.com → Subscription. AIUsage reads the official `/token_plan/remains` endpoint and tracks both the 5-hour rolling and weekly windows. The pay-as-you-go sk-… keys do not work here.",
                summaryZh: "在下方粘贴订阅 Key（sk-cp-…）。在「平台 → 订阅管理 / Token Plan」可以查看。AIUsage 调用官方 `/token_plan/remains`，同时追踪 5 小时滚动窗口和周窗口。注意按量付费的 sk-… Key 在这里不可用。",
                launchActions: [],
                supportsEmbeddedWebLogin: false
            )
        case "gemini":
            return ProviderAuthPlan(
                titleEn: "Connect a Gemini CLI account",
                titleZh: "连接 Gemini CLI 账号",
                summaryEn: "AIUsage opens Gemini's official Google sign-in in your browser, receives the OAuth callback itself, and saves that account as a monitored Gemini CLI login automatically.",
                summaryZh: "AIUsage 会直接在浏览器中打开 Gemini 官方 Google 登录页，自己接收 OAuth 回调，并把这个账号自动保存成可监控的 Gemini CLI 登录。",
                launchActions: [
                    ProviderAuthLaunchAction(
                        id: "gemini-login",
                        titleEn: "Continue with Google",
                        titleZh: "使用 Google 继续",
                        subtitleEn: "AIUsage opens the official Google sign-in in your browser and connects the Gemini CLI account automatically after authorization.",
                        subtitleZh: "AIUsage 会在浏览器中打开 Google 官方登录页，并在授权完成后自动接入这个 Gemini CLI 账号。",
                        kind: .runTerminal(command: "gemini")
                    ),
                    ProviderAuthLaunchAction(
                        id: "gemini-docs",
                        titleEn: "Open Official Auth Guide",
                        titleZh: "打开官方认证说明",
                        subtitleEn: "Check Gemini CLI's official authentication guide if you need project or account guidance.",
                        subtitleZh: "如果需要确认项目或账号要求，可以查看 Gemini CLI 官方认证说明。",
                        kind: .openURL(URL(string: "https://geminicli.com/docs/get-started/authentication/")!)
                    )
                ],
                supportsEmbeddedWebLogin: false
            )
        case "droid":
            return ProviderAuthPlan(
                titleEn: "Connect a Droid account",
                titleZh: "连接 Droid 账号",
                summaryEn: "Paste a Factory API key (fk-…) below. It is the most stable way to read your usage and avoids the browser-login and refresh-token issues. Get one in the Factory dashboard under Settings → API Keys.",
                summaryZh: "在下方粘贴 Factory API Key（fk-…）。这是最稳定的方式，可读取用量并避开浏览器登录与刷新令牌的问题。在 Factory 后台「Settings → API Keys」生成即可。",
                launchActions: [],
                supportsEmbeddedWebLogin: false
            )
        case "warp":
            return ProviderAuthPlan(
                titleEn: "Connect a Warp account",
                titleZh: "连接 Warp 账号",
                summaryEn: "Warp usage is read automatically from the local app cache. Just sign in inside the Warp terminal and AIUsage will detect it.",
                summaryZh: "Warp 用量数据从本地应用缓存自动读取。只需在 Warp 终端中登录，AIUsage 即可自动检测。",
                launchActions: [
                    ProviderAuthLaunchAction(
                        id: "warp-open",
                        titleEn: "Open Warp",
                        titleZh: "打开 Warp",
                        subtitleEn: "Launch the Warp terminal. Sign in there if you haven't already.",
                        subtitleZh: "启动 Warp 终端。如果还未登录，请先在 Warp 中登录。",
                        kind: .openApp(bundleIdentifier: "dev.warp.Warp-Stable")
                    ),
                    ProviderAuthLaunchAction(
                        id: "warp-check",
                        titleEn: "Check Connection",
                        titleZh: "检查连接",
                        subtitleEn: "Verify that Warp data is available from the local app cache.",
                        subtitleZh: "验证是否能从本地应用缓存中读取 Warp 数据。",
                        kind: .runTerminal(command: "warp-check")
                    ),
                    ProviderAuthLaunchAction(
                        id: "warp-site",
                        titleEn: "Get Warp",
                        titleZh: "获取 Warp",
                        subtitleEn: "Download Warp from the official website.",
                        subtitleZh: "从官方网站下载 Warp。",
                        kind: .openURL(URL(string: "https://www.warp.dev")!)
                    )
                ],
                supportsEmbeddedWebLogin: false
            )
        default:
            return ProviderAuthPlan(
                titleEn: "Connect account",
                titleZh: "连接账号",
                summaryEn: "Finish the provider's normal sign-in flow first, then AIUsage can connect and monitor that account.",
                summaryZh: "先完成服务商自己的正常登录流程，之后 AIUsage 才能连接并监控这个账号。",
                launchActions: [],
                supportsEmbeddedWebLogin: false
            )
        }
    }

    static func makeCodexCandidate(authFileURL: URL) -> ProviderAuthCandidate {
        let path = authFileURL.path
        let json = loadJSONObject(at: path)
        let tokens = json?["tokens"] as? [String: Any]
        let email = jwtEmail(from: stringValue(tokens?["id_token"]))
            ?? jwtEmail(from: stringValue(json?["id_token"]))
            ?? stringValue(json?["email"])
        let fingerprint: String?
        if let json {
            fingerprint = codexSessionFingerprint(from: json)
        } else {
            fingerprint = nil
        }

        return ProviderAuthCandidate(
            id: "codex-oauth:\(path)",
            providerId: "codex",
            sourceIdentifier: "codex-oauth:\(path)",
            sessionFingerprint: fingerprint,
            title: email ?? "Codex ChatGPT Login",
            subtitle: "Fresh login",
            detail: authFileURL.lastPathComponent,
            modifiedAt: Date(),
            authMethod: .authFile,
            credentialValue: path,
            sourcePath: path,
            shouldCopyFile: true,
            identityScope: .sharedSource
        )
    }

    static func makeAntigravityCandidate(authFileURL: URL) -> ProviderAuthCandidate {
        let path = authFileURL.path
        let json = loadJSONObject(at: path)
        let email = stringValue(json?["email"])
            ?? jwtEmail(from: stringValue(json?["id_token"]))
            ?? jwtEmail(from: stringValue(json?["access_token"]))
        let fingerprint: String?
        if let json {
            fingerprint = sessionFingerprint(from: json)
        } else {
            fingerprint = nil
        }

        return ProviderAuthCandidate(
            id: "antigravity-oauth:\(path)",
            providerId: "antigravity",
            sourceIdentifier: "antigravity-oauth:\(path)",
            sessionFingerprint: fingerprint,
            title: email ?? "Antigravity Login",
            subtitle: "From CPA",
            detail: authFileURL.lastPathComponent,
            modifiedAt: Date(),
            authMethod: .authFile,
            credentialValue: path,
            sourcePath: path,
            shouldCopyFile: true,
            identityScope: .sharedSource
        )
    }

    static func makeGeminiCandidate(authFileURL: URL) -> ProviderAuthCandidate {
        let path = authFileURL.path
        let data = try? Data(contentsOf: authFileURL, options: .mappedIfSafe)
        let email = data.flatMap { CLIProxyGeminiCredentialBridge.accountEmail(from: $0) }
        let json = loadJSONObject(at: path)
        let fingerprint = json.flatMap {
            sessionFingerprint(from: $0, preferredKeys: ["email"])
        } ?? email.flatMap { normalizedHandle($0) }

        return ProviderAuthCandidate(
            id: "gemini-oauth:\(path)",
            providerId: "gemini",
            sourceIdentifier: "gemini-oauth:\(path)",
            sessionFingerprint: fingerprint,
            title: email ?? "Gemini CLI Login",
            subtitle: "From CPA",
            detail: authFileURL.lastPathComponent,
            modifiedAt: (try? authFileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate,
            authMethod: .authFile,
            credentialValue: path,
            sourcePath: path,
            shouldCopyFile: true,
            identityScope: .sharedSource
        )
    }

    static func discoverCandidates(for providerId: String) -> [ProviderAuthCandidate] {
        let rawCandidates: [ProviderAuthCandidate]

        switch providerId {
        case "codex":
            rawCandidates = codexCandidates()
        case "cursor":
            rawCandidates = cursorCandidates()
        case "copilot":
            rawCandidates = copilotCandidates()
        case "antigravity":
            rawCandidates = antigravityCandidates()
        case "kimi":
            rawCandidates = kimiCandidates()
        case "kiro":
            rawCandidates = kiroCandidates()
        case "gemini":
            rawCandidates = geminiCandidates()
        case "droid":
            rawCandidates = droidCandidates()
        default:
            // minimax 当前仅手动粘贴 sk-cp-… key，没有本地配置可扫描，走 default。
            rawCandidates = []
        }

        return rawCandidates.sorted {
            if $0.modifiedAt != $1.modifiedAt {
                return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    static func unmanagedCandidates(for providerId: String) -> [ProviderAuthCandidate] {
        let monitored = monitoredSessions(for: providerId)
        return discoverCandidates(for: providerId).filter { !isCandidateManaged($0, monitored: monitored) }
    }

    static func preferredQuickConnectCandidate(for providerId: String) -> ProviderAuthCandidate? {
        let monitored = monitoredSessions(for: providerId)
        let prioritized: [ProviderAuthCandidate]

        switch providerId {
        case "droid":
            prioritized = droidCandidates()
        default:
            prioritized = discoverCandidates(for: providerId)
        }

        return prioritized.first { !isCandidateManaged($0, monitored: monitored) }
    }

    static func monitoredSessions(for providerId: String) -> ProviderMonitoredSessionIndex {
        let credentials = AccountCredentialStore.shared.loadCredentials(for: providerId)
        return ProviderMonitoredSessionIndex(
            sourceIdentifiers: Set(credentials.compactMap { credential in
                guard sourceIdentifierIsStableIdentity(for: credential) else { return nil }
                return credential.metadata["sourceIdentifier"]
                    ?? credential.metadata["sourcePath"]
                    ?? authFileSourceIdentifier(for: credential.credential, authMethod: credential.authMethod)
            }),
            sessionFingerprints: Set(credentials.compactMap { credential in
                if providerId == "codex" {
                    return CodexAccountIdentity(credential: credential).key
                        ?? credential.metadata["sessionFingerprint"].flatMap { $0.hasPrefix("codex:") ? $0 : nil }
                }
                return normalizedHandle(credential.metadata["sessionFingerprint"])
            }),
            accountHandles: Set(credentials.compactMap { credential in
                normalizedHandle(
                    credential.metadata["accountHandle"]
                        ?? credential.metadata["accountEmail"]
                        ?? credential.accountLabel
                )
            })
        )
    }

    static func launch(_ action: ProviderAuthLaunchAction) throws {
        switch action.kind {
        case .openApp(let bundleIdentifier):
            try runOpen(arguments: ["-b", bundleIdentifier])
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .revealPath(let path):
            let expanded = expand(path)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
        case .runTerminal(let command):
            try launchTerminal(command: command)
        }
    }

    static func authenticateCandidate(_ candidate: ProviderAuthCandidate) async throws -> (AccountCredential, ProviderUsage) {
        var copiedPath: String?
        do {
            let credentialValue: String
            if candidate.authMethod == .authFile, candidate.shouldCopyFile, let sourcePath = candidate.sourcePath {
                copiedPath = try copyImportedAuthFile(
                    providerId: candidate.providerId,
                    sourcePath: sourcePath,
                    suggestedName: candidate.title
                )
                credentialValue = copiedPath ?? sourcePath
            } else {
                credentialValue = candidate.credentialValue
            }

            let storedSourcePath = candidate.sourcePath ?? ""

            let credential = AccountCredential(
                providerId: candidate.providerId,
                accountLabel: candidate.title.nilIfBlank,
                authMethod: candidate.authMethod,
                credential: credentialValue,
                metadata: [
                    "sourceIdentifier": candidate.sourceIdentifier,
                    "sourcePath": storedSourcePath,
                    "importedAt": SharedFormatters.iso8601String(from: Date()),
                    "sessionFingerprint": candidate.sessionFingerprint ?? "",
                    "identityScope": candidate.identityScope.rawValue
                ]
            )

            let usage = try await validate(credential: credential)
            return (credential, usage)
        } catch {
            if let copiedPath {
                try? FileManager.default.removeItem(atPath: copiedPath)
            }
            throw error
        }
    }

    static func authenticateManualCredential(
        providerId: String,
        authMethod: AuthMethod,
        value: String,
        suggestedLabel: String? = nil,
        apiRegion: ProviderAPIRegion = .auto
    ) async throws -> (AccountCredential, ProviderUsage) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderError("missing_credential", "Credential value is empty.")
        }

        var metadata: [String: String] = [
            "sourceIdentifier": "manual:\(authMethod.rawValue):\(UUID().uuidString)",
            "importedAt": SharedFormatters.iso8601String(from: Date()),
            "identityScope": ProviderAuthCandidate.IdentityScope.sharedSource.rawValue
        ]
        if apiRegion != .auto {
            metadata[ProviderAPIRegion.metadataKey] = apiRegion.rawValue
        }

        var credential = AccountCredential(
            providerId: providerId,
            accountLabel: suggestedLabel?.nilIfBlank,
            authMethod: authMethod,
            credential: trimmed,
            metadata: metadata
        )
        let usage = try await validate(credential: credential)
        // 自动探测成功后把实际命中区域写回，后续刷新直打对应端点。
        if let resolved = (usage.extra[ProviderAPIRegion.metadataKey]?.value as? String)?.nilIfBlank {
            credential.metadata[ProviderAPIRegion.metadataKey] = resolved
        }
        return (credential, usage)
    }

    // MARK: - Validation

    private static func validate(credential: AccountCredential) async throws -> ProviderUsage {
        guard let provider = ProviderRegistry.provider(for: credential.providerId) as? any CredentialAcceptingProvider else {
            throw ProviderError("unsupported_provider", "\(credential.providerId) does not accept imported credentials.")
        }
        return try await provider.fetchUsage(with: credential)
    }

    // MARK: - Import Persistence

    private static func copyImportedAuthFile(
        providerId: String,
        sourcePath: String,
        suggestedName: String
    ) throws -> String {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let directory = try managedImportDirectory(for: providerId)
        let stem = sanitizedFilenameStem(suggestedName)
        let filename = "\(stem)-\(DateFormat.string(from: Date(), format: "yyyyMMdd-HHmmss")).json"
        let destinationURL = directory.appendingPathComponent(filename)

        let data: Data
        let normalizedProviderID = CLIProxyCredentialAdapter.normalizedProviderID(providerId)
        if providerId == "droid",
           let normalizedData = DroidProvider.managedSessionData(from: sourcePath) {
            data = normalizedData
        } else if normalizedProviderID == "gemini" {
            data = try CLIProxyGeminiCredentialBridge.makeNativePayload(
                from: Data(contentsOf: sourceURL, options: .mappedIfSafe)
            )
        } else {
            data = try Data(contentsOf: sourceURL)
        }
        try data.write(to: destinationURL, options: .atomic)
        return destinationURL.path
    }

    private static func managedImportDirectory(for providerId: String) throws -> URL {
        let directory = try ProviderManagedImportStore.managedImportsRootDirectory()
            .appendingPathComponent(providerId, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Launch Helpers

    private static func runOpen(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProviderError("launch_failed", "Could not launch the requested sign-in flow.")
        }
    }

    private static func launchTerminal(command: String) throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let scriptURL = tempDirectory.appendingPathComponent("aiusage-auth-\(UUID().uuidString).command")
        let script = """
        #!/bin/zsh
        \(command)
        printf "\\n\\nPress any key to close..."
        read -k 1
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        try runOpen(arguments: ["-a", "Terminal", scriptURL.path])
    }
}
