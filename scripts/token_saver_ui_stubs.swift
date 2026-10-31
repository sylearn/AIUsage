// Isolated SwiftUI fixture only; never launches CPA or uses real account stores.
import SwiftUI
import AppKit
import PDFKit
import Combine
import QuotaBackend
import CryptoKit

var fixtureForceChinese = false
func L(_ en: String, _ zh: String) -> String {
    (fixtureForceChinese || ProcessInfo.processInfo.environment["TOKEN_SAVER_FIXTURE_LANG"] == "zh") ? zh : en
}
struct CLIProxyGatewaySettings: Equatable {
    var autoStart = false, allowLANAccess = false, accountModelProbeEnabled = false, enablePlugins = false
    var port = 14420, accountModelProbeIntervalSeconds = 60, maxRetryCredentials = 0, requestRetry = 3, maxRetryInterval = 30
    var proxyURL = ""
    var routingStrategy = CLIProxyRoutingStrategy.roundRobin
    var normalized: Self { self }
    func requiresCPAProcessRestart(comparedTo: Self) -> Bool { self != comparedTo }
}
enum CLIProxyRoutingStrategy { case roundRobin, fillFirst }
struct FixtureRuntimeState { var isRunning = false; var isTransitioning = false }
@MainActor final class CLIProxyRuntimeController: ObservableObject {
    @Published var settings = CLIProxyGatewaySettings()
    var state = FixtureRuntimeState()
    func detectedLANBaseURLs(port: Int) -> [URL] { [] }
}
struct GatewayCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: () -> Content
    var body: some View { content().padding(padding).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12)) }
}
struct GatewayQuietBadge: View {
    let text: String
    var tint: Color = .secondary
    var body: some View { Text(text).foregroundStyle(tint) }
}
private func fixtureHome() -> URL {
    URL(fileURLWithPath: ProcessInfo.processInfo.environment["TOKEN_SAVER_FIXTURE_HOME"] ?? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("home").path)
}
private func fixtureRTK() -> TokenSaverReleaseRTK {
    TokenSaverReleaseRTK(brewURL: URL(fileURLWithPath:"/opt/homebrew/bin/brew")) { _, args in
        if args == ["list", "--versions", "rtk"], ProcessInfo.processInfo.environment["TOKEN_SAVER_FIXTURE_RTK_MISSING"] == "1" {
            return .init(status: 1, text: "")
        }
        return .init(status:0,text:args == ["list","--versions","rtk"] ? "rtk 1.0.0" : "fixture upgrade only")
    }
}
@MainActor private func fixtureReleaseManager() -> TokenSaverReleaseManager {
    let home = fixtureHome()
    let client = TokenSaverReleaseClient { request, _ in
        let path = request.url!.path
        if ProcessInfo.processInfo.environment["TOKEN_SAVER_FIXTURE_RATE_LIMIT"] == "1" {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                    headerFields: ["X-RateLimit-Reset": String(Int(Date().addingTimeInterval(120).timeIntervalSince1970))])!)
        }
        let body: [String: Any]
        if path.contains("/contents/") {
            let tool = path.contains("/ponytail/") ? "ponytail" : "caveman"
            let data = Data("---\nname: \(tool)\ndescription: Isolated UI fixture.\n---\nCoding-only fixture policy.\n".utf8)
            var blob = Data("blob \(data.count)\0".utf8); blob.append(data)
            body = ["type":"file", "path":"skills/\(tool)/SKILL.md", "encoding":"base64", "size":data.count,
                    "content":data.base64EncodedString(), "sha":Insecure.SHA1.hash(data:blob).map { String(format:"%02x",$0) }.joined()]
        } else if path.contains("/commits/") { body = ["sha":String(repeating:"a",count:40)] }
        else { body = ["tag_name":"v1.2.3", "draft":false, "prerelease":false] }
        return (try JSONSerialization.data(withJSONObject:body), HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
    let rtk = fixtureRTK()
    return TokenSaverReleaseManager(client:client,
        store:TokenSaverReleaseStore(root:home.appendingPathComponent("Library/Application Support/AIUsage/Rules")),
        rtk:rtk, reapplyRules:{ try TokenSaverSettingsStore.save(TokenSaverSettingsStore.load(home:home),home:home) })
}
@MainActor
private func inspectOffscreen<V: View>(_ root: V, width: CGFloat, maxWidth: CGFloat? = nil) -> (size: NSSize, strings: [String]) {
    let hosting = NSHostingView(rootView: root)
    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 1), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = hosting
    hosting.setFrameSize(NSSize(width: width, height: 1))
    hosting.layoutSubtreeIfNeeded()
    let fitting = hosting.fittingSize
    let size = NSSize(width: max(width, fitting.width), height: max(ceil(fitting.height), 40))
    window.setContentSize(size)
    hosting.frame = NSRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let rootScreenFrame = window.convertToScreen(hosting.convert(hosting.bounds, to: nil))

    var result: [String] = []
    var visited = Set<ObjectIdentifier>()

    func appendString(_ s: String?, screenFrame: NSRect? = nil) {
        guard let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return }
        result.append(trimmed)
        if let maxWidth, let screenFrame, screenFrame.width > 0 {
            let minX = screenFrame.minX - rootScreenFrame.minX
            let maxX = screenFrame.maxX - rootScreenFrame.minX
            precondition(minX >= -2.0 && maxX <= maxWidth + 2.0,
                         "Element '\(trimmed)' exceeds \(maxWidth)pt bounds: minX=\(minX), maxX=\(maxX)")
        }
    }

    func visitAX(_ anyObj: AnyObject) {
        let id = ObjectIdentifier(anyObj)
        guard visited.insert(id).inserted else { return }
        let frame = (anyObj as? NSAccessibilityProtocol)?.accessibilityFrame()
            ?? (anyObj as? NSAccessibilityElementProtocol)?.accessibilityFrame()
        if let ax = anyObj as? NSAccessibilityProtocol {
            appendString(ax.accessibilityLabel(), screenFrame: frame)
            appendString(ax.accessibilityTitle(), screenFrame: frame)
            appendString(ax.accessibilityValue() as? String, screenFrame: frame)
            appendString(ax.accessibilityHelp(), screenFrame: frame)
            for child in (ax.accessibilityChildren() ?? []) {
                visitAX(child as AnyObject)
            }
        }
        if let view = anyObj as? NSView {
            if let tf = view as? NSTextField { appendString(tf.stringValue) }
            if let btn = view as? NSButton { appendString(btn.title) }
            for sub in view.subviews { visitAX(sub) }
        }
    }

    _ = NSApplication.shared
    visitAX(hosting)
    let pdfData = hosting.dataWithPDF(inside: hosting.bounds)
    if let pdfDoc = PDFDocument(data: pdfData), let pdfText = pdfDoc.string {
        appendString(pdfText)
        if let maxWidth, let page = pdfDoc.page(at: 0) {
            let pageBounds = page.bounds(for: .mediaBox)
            precondition(pageBounds.width <= maxWidth + 1.0,
                         "Rendered PDF page width (\(pageBounds.width)) exceeds \(maxWidth)pt")
        }
    }
    window.contentView = nil
    return (fitting, result)
}

@MainActor
private func runHeadlessUIVerification() async throws {
    let fm = FileManager.default
    let tempRoot = fm.temporaryDirectory.appendingPathComponent("aiusage-ui-verify-" + UUID().uuidString)
    let homeA = tempRoot.appendingPathComponent("home-a")
    let homeB = tempRoot.appendingPathComponent("home-b")
    try fm.createDirectory(at: homeA, withIntermediateDirectories: true)
    try fm.createDirectory(at: homeB, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempRoot) }

    // 1. Verify REAL extracted MenuBarView.openTokenSaverSettings -> CLIProxyGatewayNavigation -> SubscriptionGatewaySettingsView.consumeSettingsDestination
    let menuRouter = ProductionMenuBarRouting()
    let settingsRouter = ProductionGatewaySettingsRouting()
    precondition(settingsRouter.selectedCategory == .runtime)
    menuRouter.openTokenSaverSettings()
    precondition(menuRouter.revealedSection == .subscriptionGateway, "Expected MenuBarView.openTokenSaverSettings to reveal .subscriptionGateway")
    precondition(CLIProxyGatewayNavigation.shared.selectedSection == .settings, "Expected navigation section .settings")
    precondition(CLIProxyGatewayNavigation.shared.settingsDestination == .tokenSaver, "Expected pending destination .tokenSaver")
    settingsRouter.consumeSettingsDestination()
    precondition(settingsRouter.selectedCategory == .tokenSaver, "Expected consumeSettingsDestination() to select .tokenSaver")
    precondition(CLIProxyGatewayNavigation.shared.settingsDestination == nil, "Expected destination to be cleared after consumption")

    // 2. Verify unconstrained & 420pt offscreen NSHostingView layout + rendered text/accessibility state in EN & ZH across all Caveman modes
    for useZH in [false, true] {
        fixtureForceChinese = useZH
        for mode in TokenSaverSettings.CavemanMode.allCases {
            _ = try TokenSaverSettingsStore.update(home: homeA) {
                $0.rtkEnabled = true
                $0.cavemanEnabled = true
                $0.cavemanMode = mode
                $0.ponytailEnabled = true
            }
            // Check unconstrained natural width fits inside 420pt without forcing .frame(width: 420)
            let naturalHost = NSHostingView(rootView: TokenSaverMenuBarSection(home: homeA, rtk: fixtureRTK(), onOpenSettings: { menuRouter.openTokenSaverSettings() }))
            naturalHost.layoutSubtreeIfNeeded()
            let naturalSize = naturalHost.fittingSize
            precondition(naturalSize.width <= 420.0 && naturalSize.height >= 40 && naturalSize.height <= 160,
                         "Unconstrained MenuBar section width exceeds 420pt (\(naturalSize)) for zh=\(useZH) mode=\(mode.rawValue)")

            // Also host inside a 420pt offscreen window and verify child bounds & rendered strings
            let (_, strings) = inspectOffscreen(
                TokenSaverMenuBarSection(home: homeA, rtk: fixtureRTK(), onOpenSettings: { menuRouter.openTokenSaverSettings() }).frame(width: 420),
                width: 420,
                maxWidth: 420
            )
            let joined = strings.joined(separator: " | ")
            let expectedTitle = useZH ? "Token 节省" : "Token Saver"
            let expectedBadge = useZH ? "已启用 3/3" : "Enabled 3/3"
            precondition(joined.contains(expectedTitle), "Missing title '\(expectedTitle)' in rendered MenuBar strings: \(joined)")
            precondition(joined.contains(expectedBadge), "Missing badge '\(expectedBadge)' in rendered MenuBar strings: \(joined)")
            precondition(joined.contains("RTK") && joined.contains("Caveman") && joined.contains("Ponytail"),
                         "Missing tool pills in rendered MenuBar strings: \(joined)")
        }

        // Verify TokenSaverUpdatesSection renders read-only Caveman/Ponytail built-in copy and no reference download buttons
        let (_, updateStringList) = inspectOffscreen(
            TokenSaverUpdatesSection(manager: fixtureReleaseManager(), onOpenRuntime: {}).frame(width: 680),
            width: 680
        )
        let updateStrings = updateStringList.joined(separator: " | ")
        let expectedBuiltIn = useZH ? "内置精简规则 · 在 Token 节省页启用" : "Built-in compact rules · Enable in Token Saver"
        let forbiddenSavedRef = useZH ? "已保存参考 · 非当前生效策略" : "Saved reference · not active policy"
        let forbiddenStagedCommit = useZH ? "已暂存提交：" : "Staged commit:"
        precondition(updateStrings.contains(expectedBuiltIn), "Missing built-in policy label in Updates: \(updateStrings)")
        precondition(!updateStrings.contains(forbiddenSavedRef) && !updateStrings.contains(forbiddenStagedCommit),
                     "Unexpected legacy staged reference UI in Updates: \(updateStrings)")
    }
    fixtureForceChinese = false

    // 3. Verify named NSPasteboard isolation, repeat-click timer cancellation across first deadline, and final expiry to false
    let testPasteboard = NSPasteboard.withUniqueName()
    defer { testPasteboard.releaseGlobally() }
    let pasteController = TokenSaverSettingsController(
        home: homeA,
        rtk: fixtureRTK(),
        copyFeedbackDurationNanoseconds: 140_000_000
    ) { text in
        testPasteboard.clearContents()
        return testPasteboard.setString(text, forType: .string)
    }
    await pasteController.checkOnboarding()
    precondition(pasteController.onboarding?.rules == .current)
    precondition(pasteController.copyDiagnostic() && pasteController.copiedDiagnostic)
    precondition(testPasteboard.string(forType: .string)?.contains("Optional diagnostic") == true)
    precondition(pasteController.copyBrewInstallCommand() && pasteController.copiedBrewCommand)
    precondition(testPasteboard.string(forType: .string) == "brew install rtk")
    try? await Task.sleep(nanoseconds: 80_000_000)
    // Repeat click at 80ms cancels the first 140ms timer and restarts a new 140ms window
    precondition(pasteController.copyDiagnostic() && pasteController.copiedDiagnostic)
    precondition(pasteController.copyBrewInstallCommand() && pasteController.copiedBrewCommand)
    try? await Task.sleep(nanoseconds: 85_000_000)
    // At 165ms (past the first 140ms deadline), both must still be true
    precondition(pasteController.copiedDiagnostic && pasteController.copiedBrewCommand,
                 "Expected repeat click to cancel first timer and keep copied state true across first deadline")
    try? await Task.sleep(nanoseconds: 100_000_000)
    // At 265ms (past the second timer deadline), both must reset to false
    precondition(!pasteController.copiedDiagnostic && !pasteController.copiedBrewCommand,
                 "Expected copied state to reset to false after replacement timer expires")

    // 4. Verify offscreen rendering of SubscriptionGatewaySettingsTokenSaverPane
    let (_, runtimeStringList) = inspectOffscreen(
        SubscriptionGatewaySettingsTokenSaverPane(home: homeA, rtk: fixtureRTK()).frame(width: 680),
        width: 680
    )
    let runtimeStrings = runtimeStringList.joined(separator: " | ")
    precondition(runtimeStrings.contains("Enabled 3/3"), "Expected Enabled 3/3 badge in TokenSaverRuntimeSection: \(runtimeStrings)")

    print("PASS TokenSaverUIFixture headless verification (unconstrained <=420pt EN/ZH layout, real production .tokenSaver routing, timer cancellation/expiry on isolated NSPasteboard, Runtime & read-only Updates views)")
}

struct TokenSaverUIFixtureApp: App {
    @StateObject var runtime = CLIProxyRuntimeController()
    @State var draft = CLIProxyGatewaySettings()
    @StateObject private var releases = fixtureReleaseManager()
    @State private var tab = 0
    var body: some Scene {
        WindowGroup("AIUsage Token Saver — isolated fixture") {
            TabView(selection: $tab) {
                SubscriptionGatewaySettingsRuntimePane(runtime:runtime,draftSettings:$draft,onApply:{},tokenSaverHome:fixtureHome(),tokenSaverRTK:fixtureRTK())
                    .tabItem { Text("Runtime") }.tag(0)
                SubscriptionGatewaySettingsTokenSaverPane(home:fixtureHome(),rtk:fixtureRTK())
                    .tabItem { Text("Token Saver") }.tag(1)
                ScrollView {
                    if tab == 2 {
                        VStack(alignment: .leading, spacing: 20) {
                            FixtureCPAUpdatesSection()
                            TokenSaverUpdatesSection(manager:releases, onOpenRuntime: { tab = 1 })
                        }.padding(20)
                    }
                }
                    .tabItem { Text("Updates (offline fixtures)") }.tag(2)
            }
            .padding(20).frame(minWidth:760,minHeight:920)
            .onAppear { NSApp.activate(ignoringOtherApps:true) }
        }
    }
}

@main
struct TokenSaverUIFixtureEntry {
    static func main() async throws {
        if CommandLine.arguments.contains("--verify-ui") {
            try await runHeadlessUIVerification()
            return
        }
        TokenSaverUIFixtureApp.main()
    }
}
