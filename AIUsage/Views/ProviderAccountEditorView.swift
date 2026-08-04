import SwiftUI
import QuotaBackend

struct ProviderAccountEditorView: View {
    let providerId: String

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @StateObject var codexLogin = CodexLoginCoordinator()
    @StateObject var geminiLogin = GeminiLoginCoordinator()
    @StateObject var antigravityLogin = AntigravityLoginCoordinator()
    @StateObject var copilotLogin = CopilotLoginCoordinator()
    @StateObject var kiroLogin = KiroLoginCoordinator()
    @State var isWorking = false
    @State var statusMessage: String?
    @State var errorMessage: String?
    @State var kimiAPIKey: String = ""
    @State var droidAPIKey: String = ""
    @State var miniMaxAPIKey: String = ""
    @State var kimiAPIRegion: ProviderAPIRegion = .auto
    @State var miniMaxAPIRegion: ProviderAPIRegion = .auto
    @State var showWebLogin = false
    @State var showCodexBrowser = false
    @State var candidates: [ProviderAuthCandidate] = []
    @State var monitoredSources: Set<String> = []
    @State var monitoredFingerprints: Set<String> = []
    @State var monitoredHandles: Set<String> = []
    @State var sessionMonitorTask: Task<Void, Never>?
    @State var showBatchImport = false
    var providerTitle: String {
        appState.providerCatalogItem(for: providerId)?.title(for: appState.language) ?? providerId
    }

    var authPlan: ProviderAuthPlan {
        ProviderAuthManager.plan(for: providerId)
    }

    var primaryLaunchAction: ProviderAuthLaunchAction? {
        authPlan.launchActions.first {
            !$0.id.localizedCaseInsensitiveContains("docs")
        } ?? authPlan.launchActions.first
    }

    var showsCodexBrowser: Bool {
        providerId == "codex" && (showCodexBrowser || codexLogin.phase != .idle)
    }

    var showsGeminiLogin: Bool {
        providerId == "gemini" && geminiLogin.phase != .idle
    }

    var showsAntigravityLogin: Bool {
        providerId == "antigravity" && antigravityLogin.phase != .idle
    }

    var showsCopilotLogin: Bool {
        providerId == "copilot" && copilotLogin.phase != .idle
    }

    var showsKiroLogin: Bool {
        providerId == "kiro" && kiroLogin.phase != .idle
    }

    var supportsBatchImport: Bool {
        BatchAuthFileScanner.authFileProviderIds.contains(providerId)
    }

    var editorWidth: CGFloat {
        520
    }

    var editorHeight: CGFloat {
        if showsCopilotLogin || showsKiroLogin { return 440 }
        if showsGeminiLogin || showsAntigravityLogin || showsCodexBrowser { return 360 }

        let visibleCandidateCount = candidates.count
        let detectedSessionExtra = CGFloat(min(visibleCandidateCount, 3)) * 86
        if providerId == "kimi" {
            return min(660, 440 + detectedSessionExtra)
        }
        if providerId == "droid" {
            return min(660, 440 + detectedSessionExtra)
        }
        if providerId == "minimax" {
            return min(660, 460 + detectedSessionExtra)
        }
        let batchImportExtra: CGFloat = supportsBatchImport ? 44 : 0
        let baseHeight: CGFloat = (visibleCandidateCount == 0 ? 300 : 360) + batchImportExtra
        return min(600, baseHeight + detectedSessionExtra)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    ProviderIconView(providerId, size: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Connect \(providerTitle) Account", "连接 \(providerTitle) 账号"))
                            .font(.title3)
                            .bold()

                        Text(appState.language == "zh" ? authPlan.summaryZh : authPlan.summaryEn)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Main login button
                loginButton

                if providerId == "kimi" {
                    kimiKeyEntrySection
                }

                if providerId == "droid" {
                    droidKeyEntrySection
                }

                if providerId == "minimax" {
                    miniMaxKeyEntrySection
                }

                if !candidates.isEmpty {
                    detectedCandidatesSection
                }

                if supportsBatchImport {
                    batchImportButton
                }

                // Codex embedded browser (only when active)
                if showsCodexBrowser {
                    codexBrowserSection
                }

                if showsGeminiLogin {
                    geminiLoginSection
                }

                if showsAntigravityLogin {
                    antigravityLoginSection
                }

                if showsCopilotLogin {
                    copilotLoginSection
                }

                if showsKiroLogin {
                    kiroLoginSection
                }

                // Status feedback (single line)
                statusFeedback

                // Footer
                HStack {
                    Label(L("Stored in Keychain", "存入钥匙串"), systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(L("Cancel", "取消")) {
                        dismiss()
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(24)
        }
        .frame(
            width: editorWidth,
            height: editorHeight
        )
        .appPageChrome(colorScheme)
        .onAppear { refreshCandidates() }
        .onDisappear {
            sessionMonitorTask?.cancel()
            codexLogin.cancel()
            geminiLogin.cancel()
            antigravityLogin.cancel()
            copilotLogin.cancel()
            kiroLogin.cancel()
        }
        .onReceive(codexLogin.$phase) { phase in
            guard providerId == "codex" else { return }
            if case .succeeded = phase {
                Task { await handleCodexLoginSuccess() }
            } else if case .failed(let message) = phase {
                showCodexBrowser = true
                errorMessage = message
            }
        }
        .onReceive(geminiLogin.$phase) { phase in
            guard providerId == "gemini" else { return }
            if case .succeeded = phase {
                Task { await handleGeminiLoginSuccess() }
            } else if case .failed(let message) = phase {
                errorMessage = message
            }
        }
        .onReceive(antigravityLogin.$phase) { phase in
            guard providerId == "antigravity" else { return }
            if case .succeeded = phase {
                Task { await handleAntigravityLoginSuccess() }
            } else if case .failed(let message) = phase {
                errorMessage = message
            }
        }
        .onReceive(copilotLogin.$phase) { phase in
            guard providerId == "copilot" else { return }
            if case .succeeded = phase {
                Task { await handleCopilotLoginSuccess() }
            } else if case .failed(let message) = phase {
                errorMessage = message
            }
        }
        .onReceive(kiroLogin.$phase) { phase in
            guard providerId == "kiro" else { return }
            if case .succeeded = phase {
                Task { await handleKiroLoginSuccess() }
            } else if case .failed(let message) = phase {
                errorMessage = message
            }
        }
        .sheet(isPresented: $showWebLogin) {
            if let loginURL = ProviderLoginURLs.loginURL(for: providerId) {
                WebLoginView(
                    providerId: providerId,
                    loginURL: loginURL,
                    cookieDomains: ProviderLoginURLs.cookieDomains(for: providerId),
                    cookieNames: ProviderLoginURLs.cookieNames(for: providerId),
                    onComplete: { cookie in
                        Task { await importEmbeddedWebSession(cookie: cookie) }
                    }
                )
                .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showBatchImport) {
            BatchImportView(providerId: providerId)
                .environmentObject(appState)
                .environmentObject(refreshCoordinator)
        }
    }
}
