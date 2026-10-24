import SwiftUI
import QuotaBackend

extension ProviderAccountEditorView {

    // MARK: - Ready

    var readyContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let notice = authPlan.notice {
                ConnectMessageCard(icon: "exclamationmark.triangle.fill", tint: .orange, title: notice.title, detail: notice.detail)
            }

            if !detected.isEmpty {
                VStack(spacing: 10) {
                    ForEach(detected) { session in
                        detectedCard(session)
                    }
                }
            }

            if connectableSessions.isEmpty || (authPlan.method == .apiKey && showKeyEntry) {
                signInArea
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label(L("Credentials stay in this Mac's Keychain.", "凭证只保存在本机钥匙串。"), systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func detectedCard(_ session: DetectedSession) -> some View {
        let candidate = session.candidate
        let failed = failedCandidateIds.contains(session.id)
        // 多个可连接会话（或正在手动输入 Key）时每张卡片自带按钮；只有一个时由页脚主按钮连接。
        let showsInlineButton = !session.isConnected
            && (failed || connectableSessions.count > 1 || (authPlan.method == .apiKey && showKeyEntry))
        return ConnectAccountCard(
            title: candidate.title,
            plan: candidate.plan,
            caption: session.isConnected ? L("Already syncing", "已在同步") : detectedCaption(candidate),
            tint: accent,
            checked: session.isConnected
        ) {
            if showsInlineButton {
                Button(failed ? L("Retry", "重试") : L("Connect", "连接")) {
                    Task { await connect(candidate) }
                }
                .controlSize(.small)
            }
        }
    }

    private func detectedCaption(_ candidate: ProviderAuthCandidate) -> String {
        let source = candidate.subtitle?.nilIfBlank ?? candidate.detail
        // Key 类凭证附上脱敏后的 Key，便于区分多个来源。
        guard candidate.authMethod == .apiKey, !candidate.detail.isEmpty else { return source }
        return "\(source) · \(candidate.detail)"
    }

    /// 没有可连接的本机会话时：Key 输入框，或说明这个服务商怎么登录。
    @ViewBuilder
    private var signInArea: some View {
        switch authPlan.method {
        case .apiKey:
            apiKeyEntryForm
        case .codexCLI where codexExecutable == nil:
            ConnectMessageCard(
                icon: "shippingbox",
                tint: .orange,
                title: L("Codex isn't installed", "未找到 Codex"),
                detail: L("AIUsage signs in through the official Codex CLI. Install the Codex CLI or the ChatGPT desktop app, then check again.",
                          "AIUsage 通过官方 Codex CLI 完成 ChatGPT 登录。安装 Codex CLI 或 ChatGPT 桌面版后点「重新检测」。")
            )
        default:
            // 本机会话都已在同步时不再重复说明，页脚直接提供新登录入口。
            if detected.isEmpty {
                ConnectMessageCard(
                    icon: "person.crop.circle.badge.questionmark",
                    tint: .secondary,
                    title: authPlan.signedOutTitle,
                    detail: signedOutDetail
                )
            }
        }
    }

    private var signedOutDetail: String {
        switch authPlan.method {
        case .kiro where !appInstalled:
            return L("Authorize an AWS Builder ID in the browser. For Google or GitHub accounts, install Kiro and sign in there first.",
                     "在浏览器中授权 AWS Builder ID。Google / GitHub 账号请先安装 Kiro 并在应用中登录。")
        default:
            return authPlan.signedOutDetail
        }
    }

    // MARK: - API Key Entry

    private struct APIKeyForm {
        let title: String
        let placeholder: String
        let hint: String
        let consoleTitle: String
        let supportsRegion: Bool
        let consoleURL: (ProviderAPIRegion) -> String
    }

    private var apiKeyForm: APIKeyForm? {
        switch providerId {
        case "kimi":
            return APIKeyForm(
                title: "Kimi Code API Key",
                placeholder: "sk-…",
                hint: L("Create an API key in the matching Kimi console and paste it here. China and International keys are not interchangeable.",
                        "在对应区域的 Kimi 控制台创建 API Key 后粘贴到这里。国内与海外 Key 不能混用。"),
                consoleTitle: L("Get API Key", "获取 API Key"),
                supportsRegion: true,
                consoleURL: { region in
                    region == .international ? "https://www.kimi.ai/code/console" : "https://www.kimi.com/code/console"
                }
            )
        case "minimax":
            return APIKeyForm(
                title: L("MiniMax Subscription Key", "MiniMax 订阅 Key"),
                placeholder: "sk-cp-…",
                hint: L("Use a Token Plan key starting with sk-cp-… from the matching MiniMax platform. Pay-as-you-go sk-… keys and cross-region keys won’t work here.",
                        "请使用对应区域平台上的 Token Plan 订阅 Key（sk-cp-…）。按量付费 sk-… 以及跨区 Key 在这里不可用。"),
                consoleTitle: L("Get Subscription Key", "获取订阅 Key"),
                supportsRegion: true,
                consoleURL: { region in
                    region == .international
                        ? "https://platform.minimax.io/user-center/basic-information/interface-key"
                        : "https://platform.minimaxi.com/user-center/basic-information/interface-key"
                }
            )
        case "warp":
            return APIKeyForm(
                title: "Warp API Key",
                placeholder: "wk-…",
                hint: L("In Warp, open Settings → Cloud platform → API keys, create a Personal key and paste it above.",
                        "在 Warp 中打开 Settings → Cloud platform → API keys，新建一个 Personal Key 并粘贴到上方。"),
                consoleTitle: L("How to get a key", "如何获取 Key"),
                supportsRegion: false,
                consoleURL: { _ in "https://docs.warp.dev/reference/cli/api-keys/" }
            )
        case "droid":
            return APIKeyForm(
                title: "Factory API Key",
                placeholder: "fk-…",
                hint: L("In Factory, open Settings → API Keys, create a key starting with fk-… and paste it above.",
                        "在 Factory 后台打开 Settings → API Keys，新建一个 fk- 开头的 Key 并粘贴到上方。"),
                consoleTitle: L("Get API Key", "获取 API Key"),
                supportsRegion: false,
                consoleURL: { _ in "https://app.factory.ai/settings/api-keys" }
            )
        default:
            return nil
        }
    }

    @ViewBuilder
    private var apiKeyEntryForm: some View {
        if let form = apiKeyForm {
            VStack(alignment: .leading, spacing: 10) {
                Text(form.title).font(.subheadline.weight(.semibold))

                if form.supportsRegion {
                    apiRegionPicker(selection: $apiRegion)
                }

                SecureField(form.placeholder, text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                Text(form.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    if let url = URL(string: form.consoleURL(apiRegion)) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(form.consoleTitle, systemImage: "safari")
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private func apiRegionPicker(selection: Binding<ProviderAPIRegion>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: selection) {
                Text(L("Auto", "自动")).tag(ProviderAPIRegion.auto)
                Text(L("China", "国内")).tag(ProviderAPIRegion.china)
                Text(L("International", "海外")).tag(ProviderAPIRegion.international)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(apiRegionHint(selection.wrappedValue))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func apiRegionHint(_ region: ProviderAPIRegion) -> String {
        switch region {
        case .auto:
            return L("Tries China first, then International.", "先试国内端点，失败再试海外。")
        case .china:
            return L("Only the China API. Use the China console for the key.", "只请求国内 API，请到国内控制台取 Key。")
        case .international:
            return L("Only the International API. Use the International console for the key.", "只请求海外 API，请到海外控制台取 Key。")
        }
    }

    // MARK: - Connected

    func connectedContent(_ account: ConnectedAccount) -> some View {
        let data = connectedProviderData(account)
        let windows = Array((data?.windows ?? []).filter { $0.remainingPercent != nil }.prefix(providerId == "antigravity" ? 5 : 3))
        return VStack(alignment: .leading, spacing: 14) {
            ConnectAccountCard(
                title: account.title,
                plan: data?.membershipLabel?.nilIfBlank ?? account.plan,
                caption: windows.isEmpty ? L("Connected", "已连接") : L("Synced", "已同步"),
                tint: accent,
                checked: true
            )
            if windows.isEmpty {
                Text(L("Quota appears on the dashboard after the next refresh.", "额度会在下次刷新后显示在仪表盘中。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                        ConnectQuotaRow(label: window.label, remaining: window.remainingPercent ?? 0, labelWidth: 110)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppSurface.card(colorScheme)))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    /// 连接后的实时数据：账号写入时已插入首批额度，后台刷新完成后这里随之更新。
    private func connectedProviderData(_ account: ConnectedAccount) -> ProviderData? {
        if let resultId = account.resultId {
            return refreshCoordinator.providers.first { $0.id == resultId }
        }
        return refreshCoordinator.providers.first { $0.baseProviderId == providerId && !$0.needsCredentialConnection }
    }

    // MARK: - Browser / Device Sign-In

    var activeLoginPhase: LoginPhase {
        switch providerId {
        case "codex": codexLogin.phase
        case "gemini": geminiLogin.phase
        case "antigravity": antigravityLogin.phase
        case "copilot": copilotLogin.phase
        case "kiro": kiroLogin.phase
        default: .idle
        }
    }

    @ViewBuilder
    var activeLoginCard: some View {
        switch providerId {
        case "codex": codexLoginSection
        case "gemini": geminiLoginSection
        case "antigravity": antigravityLoginSection
        case "copilot": copilotLoginSection
        case "kiro": kiroLoginSection
        default: EmptyView()
        }
    }

    private func loginVisualState(_ phase: LoginPhase) -> ProviderLoginVisualState {
        switch phase {
        case .idle, .launching: return .launching
        case .waitingForBrowser: return .awaitingBrowser
        case .waitingForCompletion: return .awaitingCompletion
        case .succeeded: return .succeeded
        case .failed(let message): return .failed(message)
        }
    }

    private var connectingLabel: String {
        L("Connecting account…", "正在接入账号…")
    }

    private var codexLoginSection: some View {
        ProviderLoginStatusCard(
            state: loginVisualState(codexLogin.phase),
            title: L("Sign in with ChatGPT", "使用 ChatGPT 登录"),
            description: L(
                "AIUsage opened the official ChatGPT sign-in page in your browser. Approve it there and the account connects automatically — your existing Codex login isn't touched.",
                "已在浏览器打开 ChatGPT 官方登录页，授权后自动接入；不会改动你现有的 Codex 登录。"
            ),
            inProgressLabel: codexPhaseLabel,
            connectingLabel: connectingLabel,
            succeededLabel: L("Signed in", "登录成功"),
            copyLink: codexLogin.authURL == nil ? nil : ProviderLoginAction(title: L("Copy Link", "复制链接")) {
                guard let authURL = codexLogin.authURL else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(authURL.absoluteString, forType: .string)
            },
            reopen: codexLogin.authURL == nil ? nil : ProviderLoginAction(title: L("Open Browser Again", "重新打开浏览器")) {
                codexLogin.reopenInBrowser()
            },
            cardMinHeight: 0
        )
    }

    private var codexPhaseLabel: String {
        switch codexLogin.phase {
        case .launching: return L("Starting Codex…", "正在启动 Codex…")
        case .waitingForBrowser: return L("Waiting for approval in your browser", "等待在浏览器中授权")
        case .waitingForCompletion: return L("Confirming sign-in…", "正在确认登录…")
        default: return ""
        }
    }

    private var geminiLoginSection: some View {
        googleLoginSection(
            phase: geminiLogin.phase,
            description: L("AIUsage opened Gemini's official Google sign-in in your browser. Approve it there and the account connects automatically.",
                           "已在浏览器打开 Gemini 官方 Google 登录页，授权后自动接入。"),
            accountEmail: geminiLogin.accountEmail,
            hasAuthURL: geminiLogin.authURL != nil,
            reopen: { geminiLogin.reopenInBrowser() }
        )
    }

    private var antigravityLoginSection: some View {
        googleLoginSection(
            phase: antigravityLogin.phase,
            description: L("AIUsage opened Antigravity's official Google sign-in in your browser. Approve it there and the account connects automatically.",
                           "已在浏览器打开 Antigravity 官方 Google 登录页，授权后自动接入。"),
            accountEmail: antigravityLogin.accountEmail,
            hasAuthURL: antigravityLogin.authURL != nil,
            reopen: { antigravityLogin.reopenInBrowser() }
        )
    }

    private func googleLoginSection(
        phase: LoginPhase,
        description: String,
        accountEmail: String?,
        hasAuthURL: Bool,
        reopen: @escaping () -> Void
    ) -> some View {
        ProviderLoginStatusCard(
            state: loginVisualState(phase),
            title: L("Sign in with Google", "使用 Google 登录"),
            description: description,
            accountBadge: accountEmail,
            inProgressLabel: googlePhaseLabel(phase),
            connectingLabel: connectingLabel,
            succeededLabel: L("Google sign-in completed", "Google 登录已完成"),
            reopen: hasAuthURL ? ProviderLoginAction(title: L("Open Browser Again", "重新打开浏览器"), perform: reopen) : nil,
            cardMinHeight: 0
        )
    }

    private func googlePhaseLabel(_ phase: LoginPhase) -> String {
        switch phase {
        case .launching: return L("Preparing Google sign-in…", "正在准备 Google 登录…")
        case .waitingForBrowser: return L("Waiting for approval in your browser", "等待在浏览器中授权")
        case .waitingForCompletion: return L("Confirming sign-in…", "正在确认登录…")
        default: return ""
        }
    }

    private var copilotLoginSection: some View {
        ProviderLoginStatusCard(
            state: loginVisualState(copilotLogin.phase),
            title: L("Sign in with GitHub", "使用 GitHub 登录"),
            description: L("AIUsage opened the GitHub authorization page in your browser. Approve the request and the account connects automatically.",
                           "已在浏览器打开 GitHub 授权页，确认后自动接入。"),
            deviceCode: copilotLogin.userCode,
            deviceCodePrompt: copilotLogin.codeCopied
                ? L("Code copied — paste it on the GitHub page:", "验证码已复制，在 GitHub 页面粘贴即可：")
                : L("Enter this code on the GitHub page:", "在 GitHub 页面输入此验证码："),
            accountBadge: copilotLogin.accountLogin.map { "@\($0)" },
            inProgressLabel: devicePhaseLabel(copilotLogin.phase, waiting: L("Waiting for approval on GitHub", "等待在 GitHub 上授权")),
            connectingLabel: connectingLabel,
            succeededLabel: L("GitHub sign-in completed", "GitHub 登录已完成"),
            reopen: copilotLogin.verificationURL == nil ? nil : ProviderLoginAction(title: L("Open GitHub Again", "重新打开 GitHub")) {
                copilotLogin.reopenInBrowser()
            },
            cardMinHeight: 0
        )
    }

    private var kiroLoginSection: some View {
        ProviderLoginStatusCard(
            state: loginVisualState(kiroLogin.phase),
            title: L("Sign in with AWS Builder ID", "使用 AWS Builder ID 登录"),
            description: L("AIUsage opened the AWS Builder ID page in your browser. Confirm there and the account connects automatically.",
                           "已在浏览器打开 AWS Builder ID 授权页，确认后自动接入。"),
            deviceCode: kiroLogin.userCode,
            deviceCodePrompt: kiroLogin.codeIsPrefilled
                ? L("Check that the page shows this code, then confirm:", "核对页面上的验证码与此一致后确认：")
                : L("Enter this code on the sign-in page:", "在登录页面输入此验证码："),
            accountBadge: kiroLogin.accountEmail,
            inProgressLabel: devicePhaseLabel(kiroLogin.phase, waiting: L("Waiting for approval in your browser", "等待在浏览器中授权")),
            connectingLabel: connectingLabel,
            succeededLabel: L("Kiro sign-in completed", "Kiro 登录已完成"),
            reopen: kiroLogin.verificationURL == nil ? nil : ProviderLoginAction(title: L("Open Browser Again", "重新打开浏览器")) {
                kiroLogin.reopenInBrowser()
            },
            cardMinHeight: 0
        )
    }

    private func devicePhaseLabel(_ phase: LoginPhase, waiting: String) -> String {
        switch phase {
        case .launching: return L("Preparing sign-in…", "正在准备登录…")
        case .waitingForBrowser: return waiting
        case .waitingForCompletion: return L("Verifying account…", "正在验证账号…")
        default: return ""
        }
    }
}
