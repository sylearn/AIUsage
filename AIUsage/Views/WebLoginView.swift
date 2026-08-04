import SwiftUI
import WebKit
import QuotaBackend

/// Embedded WebView for logging into provider websites.
/// Captures session cookies after successful login and stores them as credentials.
struct WebLoginView: View {
    let providerId: String
    let loginURL: URL
    let cookieDomains: [String]
    let cookieNames: Set<String>?
    let onComplete: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var appState: AppState
    @State private var isLoading = true
    @State private var currentURL: URL?
    @State private var capturedCookie: String?
    @State private var pageTitle: String = ""
    private var canConnectCapturedAccount: Bool {
        guard capturedCookie != nil else { return false }
        return ProviderLoginURLs.isReadyToUseCapturedAccount(for: providerId, currentURL: currentURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ProviderIconView(providerId, size: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Sign in to \(providerId.capitalized)", "登录 \(providerId.capitalized)"))
                        .font(.headline)
                    if !pageTitle.isEmpty {
                        Text(pageTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                if canConnectCapturedAccount {
                    Button(L("Use This Account", "使用此账号")) {
                        if let cookie = capturedCookie {
                            onComplete(cookie)
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Button(L("Cancel", "取消")) {
                    dismiss()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(AppSurface.toolbar(colorScheme))

            Divider()

            WebViewRepresentable(
                providerId: providerId,
                url: loginURL,
                cookieDomains: cookieDomains,
                cookieNames: cookieNames,
                isLoading: $isLoading,
                currentURL: $currentURL,
                pageTitle: $pageTitle,
                capturedCookie: $capturedCookie
            )
        }
        .frame(width: 900, height: 680)
    }
}

// MARK: - NSViewRepresentable WebKit Wrapper

private struct WebViewRepresentable: NSViewRepresentable {
    let providerId: String
    let url: URL
    let cookieDomains: [String]
    let cookieNames: Set<String>?
    @Binding var isLoading: Bool
    @Binding var currentURL: URL?
    @Binding var pageTitle: String
    @Binding var capturedCookie: String?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebViewRepresentable

        init(parent: WebViewRepresentable) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async { self.parent.isLoading = true }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.currentURL = webView.url
                self.parent.pageTitle = webView.title ?? ""
            }
            checkForSessionCookies(in: webView)
        }

        private func checkForSessionCookies(in webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let domainCookies = cookies.filter { cookie in
                    self.parent.cookieDomains.contains(where: { domain in
                        cookie.domain == domain || cookie.domain.hasSuffix(".\(domain)")
                    })
                }

                let relevantCookies: [HTTPCookie]
                if let names = self.parent.cookieNames, !names.isEmpty {
                    relevantCookies = domainCookies.filter { names.contains($0.name) }
                } else {
                    relevantCookies = domainCookies.filter { cookie in
                        let name = cookie.name.lowercased()
                        return name.contains("session") || name.contains("token") || name.contains("auth")
                    }
                }

                guard !relevantCookies.isEmpty else { return }

                let header = Self.buildCookieHeader(from: relevantCookies, providerId: self.parent.providerId)
                guard !header.isEmpty else { return }

                DispatchQueue.main.async {
                    self.parent.capturedCookie = header
                }
            }
        }

        private static func buildCookieHeader(from cookies: [HTTPCookie], providerId: String) -> String {
            let ordered = cookies.sorted { lhs, rhs in
                if lhs.name != rhs.name {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }

                let lhsPriority = ProviderLoginURLs.cookieDomainPriority(for: providerId, cookie: lhs)
                let rhsPriority = ProviderLoginURLs.cookieDomainPriority(for: providerId, cookie: rhs)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }

                let lhsExpires = lhs.expiresDate ?? .distantPast
                let rhsExpires = rhs.expiresDate ?? .distantPast
                if lhsExpires != rhsExpires {
                    return lhsExpires > rhsExpires
                }

                if lhs.domain.count != rhs.domain.count {
                    return lhs.domain.count > rhs.domain.count
                }

                if lhs.path.count != rhs.path.count {
                    return lhs.path.count > rhs.path.count
                }

                return lhs.value.count > rhs.value.count
            }

            var selectedByName: [String: HTTPCookie] = [:]
            for cookie in ordered where selectedByName[cookie.name] == nil {
                selectedByName[cookie.name] = cookie
            }

            return selectedByName
                .values
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
        }
    }
}

// MARK: - Provider Login URLs

enum ProviderLoginURLs {
    static func loginURL(for providerId: String) -> URL? {
        switch providerId {
        case "cursor":
            return URL(string: "https://cursor.com/login")
        case "droid":
            return URL(string: "https://app.factory.ai")
        default:
            return nil
        }
    }

    static func cookieDomains(for providerId: String) -> [String] {
        switch providerId {
        case "cursor":
            return ["cursor.com", "www.cursor.com", "cursor.sh"]
        case "droid":
            return ["factory.ai", ".factory.ai", "app.factory.ai", "auth.factory.ai", "api.factory.ai"]
        default:
            return []
        }
    }

    static func cookieNames(for providerId: String) -> Set<String>? {
        switch providerId {
        case "cursor":
            return ["WorkosCursorSessionToken", "__Secure-next-auth.session-token", "next-auth.session-token", "wos-session", "__Secure-wos-session"]
        case "droid":
            return [
                "wos-session",
                "__Secure-next-auth.session-token",
                "next-auth.session-token",
                "__Secure-authjs.session-token",
                "__Host-authjs.csrf-token",
                "authjs.session-token",
                "session",
                "access-token"
            ]
        default:
            return nil
        }
    }

    static func isReadyToUseCapturedAccount(for providerId: String, currentURL: URL?) -> Bool {
        guard let currentURL else { return true }

        let host = currentURL.host?.lowercased() ?? ""
        let absolute = currentURL.absoluteString.lowercased()

        switch providerId {
        case "cursor":
            if absolute.contains("/login") || absolute.contains("/signin") || absolute.contains("/auth") {
                return false
            }
            return true
        case "droid":
            guard host == "app.factory.ai" else { return false }
            if absolute.contains("/login") || absolute.contains("/signin") || absolute.contains("/sign-in") || absolute.contains("/auth/") {
                return false
            }
            return true
        default:
            return true
        }
    }

    static func cookieDomainPriority(for providerId: String, cookie: HTTPCookie) -> Int {
        let domain = cookie.domain.lowercased()

        switch providerId {
        case "droid":
            switch domain {
            case "app.factory.ai": return 0
            case ".factory.ai": return 1
            case "factory.ai": return 2
            case "api.factory.ai": return 3
            case "auth.factory.ai": return 4
            default:
                if domain.hasSuffix(".factory.ai") { return 5 }
                return 10
            }
        default:
            return 10
        }
    }

    static var webLoginProviders: Set<String> { ["cursor", "droid"] }
}
