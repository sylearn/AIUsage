import SwiftUI
import QuotaBackend

extension ProviderAccountEditorView {

    // MARK: - Login Button

    @ViewBuilder
    var loginButton: some View {
        if authPlan.supportsEmbeddedWebLogin && ProviderLoginURLs.webLoginProviders.contains(providerId) {
            Button {
                errorMessage = nil
                statusMessage = nil
                showWebLogin = true
            } label: {
                Label(
                    providerId == "droid" ? L("Connect Account", "连接账号") : L("Sign In", "登录"),
                    systemImage: "globe"
                )
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isWorking)
        } else if let action = primaryLaunchAction {
            Button {
                performLaunch(action)
            } label: {
                Label(action.title(for: appState.language), systemImage: iconName(for: action))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isWorking)
        }
    }

    var detectedCandidatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Detected Sessions", "已检测到的会话"))
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Button {
                    refreshCandidates()
                } label: {
                    Label(L("Refresh", "刷新"), systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isWorking)
            }

            Text(L(
                "AIUsage found local login state for this provider. Connect one of the sessions below directly.",
                "AIUsage 检测到了这个服务商的本地登录状态。你可以直接连接下面的会话。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                ForEach(candidates) { candidate in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)

                            if let subtitle = candidate.subtitle?.nilIfBlank {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Text(candidate.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 12)

                        Button(L("Connect", "连接")) {
                            Task { await importCandidate(candidate) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isWorking)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(AppSurface.card(colorScheme))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }
            }
        }
    }

    // MARK: - Kimi Code API Key Entry

    var kimiKeyEntrySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Kimi Code API Key", "Kimi Code API Key"))
                .font(.subheadline.weight(.semibold))

            apiRegionPicker(selection: $kimiAPIRegion)

            SecureField("sk-…", text: $kimiAPIKey)
                .textFieldStyle(.roundedBorder)
                .disabled(isWorking)
                .onSubmit { connectKimiAPIKey() }

            Text(L(
                "Create an API key in the matching Kimi console and paste it here. China and International keys are not interchangeable. The key is stored in Keychain.",
                "在对应区域的 Kimi 控制台创建 API Key 后粘贴到这里。国内与海外 Key 不能混用。Key 会存入钥匙串。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    connectKimiAPIKey()
                } label: {
                    Label(L("Connect", "连接"), systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isWorking || kimiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    if let url = URL(string: kimiConsoleURL(for: kimiAPIRegion)) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(L("Get API Key", "获取 API Key"), systemImage: "safari")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isWorking)
            }
        }
    }

    // MARK: - MiniMax Token Plan API Key Entry

    var miniMaxKeyEntrySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("MiniMax Subscription Key", "MiniMax 订阅 Key"))
                .font(.subheadline.weight(.semibold))

            apiRegionPicker(selection: $miniMaxAPIRegion)

            SecureField("sk-cp-…", text: $miniMaxAPIKey)
                .textFieldStyle(.roundedBorder)
                .disabled(isWorking)
                .onSubmit { connectMiniMaxAPIKey() }

            Text(L(
                "Use a Token Plan key starting with sk-cp-… from the matching MiniMax platform. Pay-as-you-go sk-… keys and cross-region keys won’t work here. The key is stored in Keychain.",
                "请使用对应区域平台上的 Token Plan 订阅 Key（sk-cp-…）。按量付费 sk-… 以及跨区 Key 在这里不可用。Key 会存入钥匙串。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    connectMiniMaxAPIKey()
                } label: {
                    Label(L("Connect", "连接"), systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isWorking || miniMaxAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    if let url = URL(string: miniMaxConsoleURL(for: miniMaxAPIRegion)) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(L("Get Subscription Key", "获取订阅 Key"), systemImage: "safari")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isWorking)
            }
        }
    }

    // MARK: - API Region

    private func apiRegionPicker(selection: Binding<ProviderAPIRegion>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Region", "区域"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("", selection: selection) {
                Text(L("Auto", "自动")).tag(ProviderAPIRegion.auto)
                Text(L("China", "国内")).tag(ProviderAPIRegion.china)
                Text(L("International", "海外")).tag(ProviderAPIRegion.international)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isWorking)
            Text(apiRegionHint(selection.wrappedValue))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func apiRegionHint(_ region: ProviderAPIRegion) -> String {
        switch region {
        case .auto:
            return L(
                "Tries China first, then International.",
                "先试国内端点，失败再试海外。"
            )
        case .china:
            return L(
                "Only the China API. Use the China console for the key.",
                "只请求国内 API，请到国内控制台取 Key。"
            )
        case .international:
            return L(
                "Only the International API. Use the International console for the key.",
                "只请求海外 API，请到海外控制台取 Key。"
            )
        }
    }

    private func kimiConsoleURL(for region: ProviderAPIRegion) -> String {
        switch region {
        case .international:
            return "https://platform.moonshot.ai/"
        case .china, .auto:
            return "https://www.kimi.com/code/console"
        }
    }

    private func miniMaxConsoleURL(for region: ProviderAPIRegion) -> String {
        switch region {
        case .international:
            return "https://platform.minimax.io/user-center/basic-information/interface-key"
        case .china, .auto:
            return "https://platform.minimaxi.com/user-center/basic-information/interface-key"
        }
    }

    // MARK: - Droid API Key Entry

    var droidKeyEntrySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Factory API Key", "Factory API Key"))
                .font(.subheadline.weight(.semibold))

            SecureField("fk-…", text: $droidAPIKey)
                .textFieldStyle(.roundedBorder)
                .disabled(isWorking)
                .onSubmit { connectDroidAPIKey() }

            Text(L(
                "How to get a key: click “Get API Key” → sign in to Factory → Settings → API Keys → create a key starting with fk-… → paste it above. This is the most stable way and avoids browser-cookie / refresh-token issues. The key is stored in Keychain.",
                "如何获取：点击「获取 API Key」→ 登录 Factory → Settings → API Keys → 新建一个 fk- 开头的 Key → 粘贴到上方。这是最稳定的方式，可避开浏览器 Cookie / 刷新令牌的脆弱问题。Key 会存入钥匙串。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    connectDroidAPIKey()
                } label: {
                    Label(L("Connect", "连接"), systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isWorking || droidAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    if let url = URL(string: "https://app.factory.ai/settings/api-keys") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(L("Get API Key", "获取 API Key"), systemImage: "safari")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isWorking)
            }
        }
    }

    // MARK: - Batch Import

    var batchImportButton: some View {
        Button {
            showBatchImport = true
        } label: {
            Label(
                L("Batch Import from Folder", "从文件夹批量导入"),
                systemImage: "square.and.arrow.down.on.square"
            )
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(isWorking)
    }

    // MARK: - Shared Login Presentation

    /// 把任意协调器的 phase 映射成卡片的单一展示状态。
    /// 错误优先：导入账号失败（errorMessage）或浏览器步骤失败都直接显示红色错误，
    /// 不会再出现「绿色完成 + 红色报错」同现。导入账号进行中显示「接入中」。
    func loginVisualState(_ phase: LoginPhase) -> ProviderLoginVisualState {
        if let errorMessage, !errorMessage.isEmpty {
            return .failed(errorMessage)
        }
        if isWorking {
            return .connecting
        }
        switch phase {
        case .idle, .launching:
            return .launching
        case .waitingForBrowser:
            return .awaitingBrowser
        case .waitingForCompletion:
            return .awaitingCompletion
        case .succeeded:
            return .succeeded
        case .failed(let message):
            return .failed(message)
        }
    }

    var connectingLabel: String {
        L("Connecting account…", "正在接入账号…")
    }

    var hasActiveLoginCard: Bool {
        showsCodexBrowser || showsGeminiLogin || showsAntigravityLogin
            || showsCopilotLogin || showsKiroLogin
    }

    var codexBrowserSection: some View {
        ProviderLoginStatusCard(
            state: loginVisualState(codexLogin.phase),
            title: L("Secure ChatGPT Sign-In", "安全的 ChatGPT 登录"),
            description: L(
                "AIUsage has opened the official ChatGPT sign-in page in your browser. Finish the browser step, then return here and the account will connect automatically.",
                "AIUsage 已在浏览器中打开 ChatGPT 官方登录页。你只要在浏览器里完成授权，再回到这里，账号就会自动接入。"
            ),
            inProgressLabel: codexPhaseLabel,
            connectingLabel: connectingLabel,
            succeededLabel: L("Login completed", "登录完成"),
            copyLink: codexLogin.authURL == nil ? nil : ProviderLoginAction(
                title: L("Copy Link", "复制链接"),
                perform: {
                    guard let authURL = codexLogin.authURL else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(authURL.absoluteString, forType: .string)
                    statusMessage = L("Link copied.", "链接已复制。")
                }
            ),
            reopen: codexLogin.authURL == nil ? nil : ProviderLoginAction(
                title: L("Open Browser Again", "重新打开浏览器"),
                perform: { codexLogin.reopenInBrowser() }
            ),
            onCancel: {
                showCodexBrowser = false
                errorMessage = nil
                statusMessage = nil
                codexLogin.cancel()
            }
        )
    }

    var codexPhaseLabel: String {
        switch codexLogin.phase {
        case .launching:
            return L("Starting...", "启动中...")
        case .waitingForBrowser:
            return L("Complete sign-in in your browser", "请在浏览器中完成登录")
        case .waitingForCompletion:
            return L("Waiting for authentication...", "等待认证完成...")
        default:
            return ""
        }
    }

    // MARK: - Status

    @ViewBuilder
    var statusFeedback: some View {
        if hasActiveLoginCard {
            // 登录卡片已自带状态/错误展示，避免底部重复一条 spinner 或红字。
            EmptyView()
        } else if isWorking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Connecting...", "连接中..."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let errorMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        } else if let statusMessage {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    var geminiLoginSection: some View {
        ProviderLoginStatusCard(
            state: loginVisualState(geminiLogin.phase),
            title: L("Secure Google Sign-In", "安全的 Google 登录"),
            description: L(
                "AIUsage has opened Gemini's official Google sign-in page in your browser. Finish the browser step, then return here and the account will connect automatically.",
                "AIUsage 已经在浏览器中打开 Gemini 官方 Google 登录页。你只要在浏览器里完成授权，再回到这里，账号就会自动接入。"
            ),
            accountBadge: geminiLogin.accountEmail,
            inProgressLabel: geminiPhaseLabel,
            connectingLabel: connectingLabel,
            succeededLabel: L("Google sign-in completed", "Google 登录已完成"),
            reopen: geminiLogin.authURL == nil ? nil : ProviderLoginAction(
                title: L("Open Browser Again", "重新打开浏览器"),
                perform: { geminiLogin.reopenInBrowser() }
            ),
            onCancel: {
                errorMessage = nil
                statusMessage = nil
                geminiLogin.cancel()
            }
        )
    }

    // MARK: - Antigravity Login

    var antigravityLoginSection: some View {
        ProviderLoginStatusCard(
            state: loginVisualState(antigravityLogin.phase),
            title: L("Secure Google Sign-In", "安全的 Google 登录"),
            description: L(
                "AIUsage has opened Antigravity's official Google sign-in page in your browser. Finish the browser step, then return here and the account will connect automatically.",
                "AIUsage 已经在浏览器中打开 Antigravity 官方 Google 登录页。你只要在浏览器里完成授权，再回到这里，账号就会自动接入。"
            ),
            accountBadge: antigravityLogin.accountEmail,
            inProgressLabel: antigravityPhaseLabel,
            connectingLabel: connectingLabel,
            succeededLabel: L("Google sign-in completed", "Google 登录已完成"),
            reopen: antigravityLogin.authURL == nil ? nil : ProviderLoginAction(
                title: L("Open Browser Again", "重新打开浏览器"),
                perform: { antigravityLogin.reopenInBrowser() }
            ),
            onCancel: {
                errorMessage = nil
                statusMessage = nil
                antigravityLogin.cancel()
            }
        )
    }

    // MARK: - Kiro Login

    var kiroLoginSection: some View {
        ProviderLoginStatusCard(
            state: loginVisualState(kiroLogin.phase),
            title: L("Kiro AWS SSO Login", "Kiro AWS SSO 登录"),
            description: L(
                "AIUsage will open the Kiro sign-in page in your browser. Supports Google, GitHub, Builder ID, and organization login.",
                "AIUsage 会在浏览器中打开 Kiro 登录页，支持 Google、GitHub、Builder ID 和组织登录。"
            ),
            deviceCode: kiroLogin.userCode,
            deviceCodePrompt: L("Enter this code on the Kiro sign-in page:", "在 Kiro 登录页面输入此验证码："),
            accountBadge: kiroLogin.accountEmail,
            inProgressLabel: kiroPhaseLabel,
            connectingLabel: connectingLabel,
            succeededLabel: L("Kiro sign-in completed", "Kiro 登录已完成"),
            reopen: kiroLogin.verificationURL == nil ? nil : ProviderLoginAction(
                title: L("Open Kiro Again", "重新打开 Kiro"),
                perform: { kiroLogin.reopenInBrowser() }
            ),
            onCancel: {
                errorMessage = nil
                statusMessage = nil
                kiroLogin.cancel()
            },
            cardMinHeight: 128
        )
    }

    var kiroPhaseLabel: String {
        switch kiroLogin.phase {
        case .launching:
            return L("Preparing Kiro sign-in…", "正在准备 Kiro 登录…")
        case .waitingForBrowser:
            return L("Enter the code on the sign-in page", "在登录页上输入验证码")
        case .waitingForCompletion:
            return L("Verifying account…", "正在验证账号…")
        default:
            return ""
        }
    }

    // MARK: - Copilot Login

    var copilotLoginSection: some View {
        ProviderLoginStatusCard(
            state: loginVisualState(copilotLogin.phase),
            title: L("GitHub Device Flow", "GitHub 设备流登录"),
            description: L(
                "AIUsage will open the GitHub authorization page in your browser. Approve the request and the account will connect automatically.",
                "AIUsage 会在浏览器中打开 GitHub 授权页。你确认授权后，账号会自动接入。"
            ),
            deviceCode: copilotLogin.userCode,
            deviceCodePrompt: L("Enter this code on the GitHub page:", "在 GitHub 页面输入此验证码："),
            accountBadge: copilotLogin.accountLogin.map { "@\($0)" },
            inProgressLabel: copilotPhaseLabel,
            connectingLabel: connectingLabel,
            succeededLabel: L("GitHub sign-in completed", "GitHub 登录已完成"),
            reopen: copilotLogin.verificationURL == nil ? nil : ProviderLoginAction(
                title: L("Open GitHub Again", "重新打开 GitHub"),
                perform: { copilotLogin.reopenInBrowser() }
            ),
            onCancel: {
                errorMessage = nil
                statusMessage = nil
                copilotLogin.cancel()
            },
            cardMinHeight: 128
        )
    }

    var copilotPhaseLabel: String {
        switch copilotLogin.phase {
        case .launching:
            return L("Preparing GitHub sign-in…", "正在准备 GitHub 登录…")
        case .waitingForBrowser:
            return L("Enter the code on GitHub", "在 GitHub 上输入验证码")
        case .waitingForCompletion:
            return L("Verifying account…", "正在验证账号…")
        default:
            return ""
        }
    }

    var antigravityPhaseLabel: String {
        switch antigravityLogin.phase {
        case .launching:
            return L("Preparing Google sign-in…", "正在准备 Google 登录…")
        case .waitingForBrowser:
            return L("Finish the browser sign-in", "请完成浏览器登录")
        case .waitingForCompletion:
            return L("Waiting for Google callback…", "正在等待 Google 回调…")
        default:
            return ""
        }
    }

    var geminiPhaseLabel: String {
        switch geminiLogin.phase {
        case .launching:
            return L("Preparing Google sign-in…", "正在准备 Google 登录…")
        case .waitingForBrowser:
            return L("Finish the browser sign-in", "请完成浏览器登录")
        case .waitingForCompletion:
            return L("Waiting for Google callback…", "正在等待 Google 回调…")
        default:
            return ""
        }
    }
}
