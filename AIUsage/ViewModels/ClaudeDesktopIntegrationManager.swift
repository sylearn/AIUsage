import Foundation
import Combine
import AppKit

enum ClaudeDesktopConnectionState: Equatable {
    case unavailable
    case disconnected
    case preparing(String)
    case ready
    case connected
    case conflict(String)
    case failed(String)
}

enum ClaudeDesktopAppError: LocalizedError {
    case launchFailed
    case terminateFailed

    var errorDescription: String? {
        switch self {
        case .launchFailed:
            return AppSettings.shared.t("Claude Desktop could not be opened.", "无法打开 Claude Desktop。")
        case .terminateFailed:
            return AppSettings.shared.t("Claude Desktop could not be fully closed.", "无法完整退出 Claude Desktop。")
        }
    }
}

@MainActor
enum ClaudeDesktopAppController {
    static let bundleIdentifier = "com.anthropic.claudefordesktop"

    static var isRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains(where: { !$0.isTerminated })
    }

    /// Fully quits Claude Desktop without reopening it. Closing the process is
    /// important after restoring a profile because Desktop keeps its selected
    /// 3P configuration in memory for the lifetime of the app.
    static func quitIfRunning() async throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        for app in running { app.terminate() }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let survivors = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
        for app in survivors { app.forceTerminate() }

        let forceDeadline = Date().addingTimeInterval(2)
        while Date() < forceDeadline,
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).allSatisfy(\.isTerminated) else {
            throw ClaudeDesktopAppError.terminateFailed
        }
    }

    static func restart(appURL: URL) async throws {
        try await quitIfRunning()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } catch {
            throw ClaudeDesktopAppError.launchFailed
        }
    }

    static func open(appURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } catch {
            throw ClaudeDesktopAppError.launchFailed
        }
    }
}

/// End-to-end coordinator for the user-visible one-click Desktop flow.  It
/// deliberately keeps "profile ready" separate from "real Desktop traffic
/// observed" so a local health check can never be shown as a successful app
/// connection.
@MainActor
final class ClaudeDesktopIntegrationManager: ObservableObject {
    static let shared = ClaudeDesktopIntegrationManager()

    @Published private(set) var state: ClaudeDesktopConnectionState
    @Published private(set) var installation: ClaudeDesktopInstallation
    @Published private(set) var configuredModels: [ClaudeDesktopCatalogEntry] = []
    @Published private(set) var activeNodeName: String?
    @Published private(set) var isBusy = false

    private let gateway = GlobalProxyManager.desktop
    private let runtime = GlobalProxyRuntime.desktop
    private let profileStore = ClaudeDesktopProfileStore.shared
    private var cancellables: Set<AnyCancellable> = []
    private var trafficObservationCancellable: AnyCancellable?

    private init() {
        let installation = ClaudeDesktopInstallation.inspect()
        self.installation = installation
        if !installation.isInstalled {
            state = .unavailable
        } else if ClaudeDesktopProfileStore.shared.status().isOwnedByAIUsage {
            state = .ready
        } else {
            state = .disconnected
        }

        NotificationCenter.default.publisher(for: .claudeGatewayActiveNodeDidChange)
            .sink { [weak self] notification in
                guard let nodeID = notification.object as? String else { return }
                Task { @MainActor in
                    await self?.refreshProfileForActiveNode(nodeID)
                }
            }
            .store(in: &cancellables)
    }

    var isConfigured: Bool {
        switch state {
        case .ready, .connected, .preparing: return true
        default: return false
        }
    }

    var isConnected: Bool { state == .connected }
    var versionLabel: String { installation.version ?? "—" }
    var endpointLabel: String { gateway.config.claudeDesktopBaseURL }

    func refreshInstallation() {
        installation = ClaudeDesktopInstallation.inspect()
        if !installation.isInstalled {
            state = .unavailable
        } else if state == .unavailable {
            state = profileStore.status().isOwnedByAIUsage ? .ready : .disconnected
        }
    }

    func connect(activeNodeId nodeID: String) async {
        guard !isBusy else { return }
        isBusy = true
        trafficObservationCancellable?.cancel()
        defer { isBusy = false }

        refreshInstallation()
        guard let appURL = installation.appURL else {
            state = .unavailable
            return
        }
        guard let node = ProxyViewModel.shared.configurations.first(where: {
            $0.id == nodeID && ProxyNodeFamily.claude.contains($0.nodeType)
        }) else {
            state = .failed(AppSettings.shared.t("Selected node not found.", "未找到所选节点。"))
            return
        }
        let catalog = ClaudeDesktopProfileStore.catalog(
            for: node,
            mode: gateway.config.effectiveClaudeDesktopCatalogMode,
            supports1M: gateway.config.claudeDesktopSupports1MModels(for: node.id),
            routes: gateway.config.effectiveClaudeDesktopModels(for: node)
        )
        guard !catalog.isEmpty else {
            state = .failed(AppSettings.shared.t(
                "This node has no usable models. Sync or add an available model first.",
                "该节点没有可用模型，请先同步或添加可用模型。"
            ))
            return
        }

        let clientKey = gateway.config.effectiveClaudeDesktopClientKey
        var runtimeAttached = false
        var profileApplied = false
        do {
            state = .preparing(AppSettings.shared.t(
                "Preparing secure localhost HTTPS…",
                "正在准备安全的本机 HTTPS…"
            ))
            try await TLSCertificateManager.shared.ensureCertificate()

            state = .preparing(AppSettings.shared.t("Starting the Desktop Gateway…", "正在启动 Desktop 网关…"))
            try await gateway.attachClaudeDesktop(
                activeNodeId: nodeID,
                httpsPort: gateway.config.effectiveClaudeDesktopHTTPSPort,
                clientKey: clientKey,
                tlsIdentityPath: TLSCertificateManager.shared.identityFilePath
            )
            runtimeAttached = true

            state = .preparing(AppSettings.shared.t("Applying the Claude Desktop profile…", "正在应用 Claude Desktop 配置…"))
            try profileStore.connect(
                baseURL: gateway.config.claudeDesktopBaseURL,
                clientKey: clientKey,
                catalog: catalog
            )
            profileApplied = true
            configuredModels = catalog
            activeNodeName = node.name
            state = .ready

            let baseline = runtime.claudeDesktopObservedTrafficCount
            state = .preparing(AppSettings.shared.t("Restarting Claude Desktop…", "正在重启 Claude Desktop…"))
            try await ClaudeDesktopAppController.restart(appURL: appURL)
            state = .ready
            beginTrafficObservation(after: baseline)
        } catch let error as ClaudeDesktopProfileError {
            if profileApplied { _ = try? profileStore.disconnect() }
            if runtimeAttached { try? await gateway.detachClaudeDesktop() }
            if error.isExternalConflict {
                state = .conflict(error.localizedDescription)
            } else {
                state = .failed(error.localizedDescription)
            }
        } catch {
            if profileApplied { _ = try? profileStore.disconnect() }
            if runtimeAttached { try? await gateway.detachClaudeDesktop() }
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect(quitDesktop: Bool = true) async {
        guard !isBusy else { return }
        isBusy = true
        trafficObservationCancellable?.cancel()
        defer { isBusy = false }

        state = .preparing(AppSettings.shared.t(
            "Restoring the previous Desktop configuration…",
            "正在恢复接入前的 Desktop 配置…"
        ))
        var restoreError: Error?
        do {
            _ = try profileStore.disconnect()
        } catch ClaudeDesktopProfileError.noRestoreJournal
            where !profileStore.status().isOwnedByAIUsage {
            // A prior partial cleanup may already have restored the profile.
            // Keep disconnect idempotent so a retry can still close the
            // listener and clear the persisted Desktop consumer.
        } catch {
            restoreError = error
        }
        do {
            try await gateway.detachClaudeDesktop()
        } catch {
            if restoreError == nil { restoreError = error }
        }

        if let restoreError {
            if let profileError = restoreError as? ClaudeDesktopProfileError,
               profileError.isExternalConflict {
                state = .conflict(profileError.localizedDescription)
            } else {
                state = .failed(restoreError.localizedDescription)
            }
            return
        }

        if quitDesktop {
            state = .preparing(AppSettings.shared.t(
                "Closing Claude Desktop without reopening it…",
                "正在退出 Claude Desktop，完成后不会重新打开…"
            ))
            do {
                try await ClaudeDesktopAppController.quitIfRunning()
            } catch {
                state = .failed(error.localizedDescription)
                return
            }
        }

        configuredModels = []
        activeNodeName = nil
        state = installation.isInstalled ? .disconnected : .unavailable
    }

    func openClaudeDesktop() async {
        guard let appURL = installation.appURL else {
            state = .unavailable
            return
        }
        do {
            try await ClaudeDesktopAppController.open(appURL: appURL)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func restoreOnLaunch() async {
        do {
            try profileStore.recoverInterruptedApplyIfNeeded()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        installation = ClaudeDesktopInstallation.inspect()
        guard installation.isInstalled else {
            state = .unavailable
            return
        }
        let profileStatus = profileStore.status()
        guard gateway.config.isEnabled else {
            state = profileStatus.isOwnedByAIUsage
                ? .conflict(AppSettings.shared.t(
                    "The AIUsage profile is still selected, but its gateway consumer is off.",
                    "AIUsage 配置仍被选中，但 Gateway 消费者未开启。"
                ))
                : .disconnected
            return
        }
        guard profileStatus.isOwnedByAIUsage else {
            state = .conflict(ClaudeDesktopProfileError.profileOwnedByAnotherTool.localizedDescription)
            return
        }
        guard gateway.isProxyRunning else {
            state = .failed(AppSettings.shared.t(
                "The Desktop profile is attached, but its local HTTPS port could not be restored.",
                "Desktop 配置仍处于接入状态，但本机 HTTPS 端口恢复失败。"
            ))
            return
        }
        if let node = ProxyViewModel.shared.configurations.first(where: { $0.id == gateway.activeNodeId }) {
            let catalog = ClaudeDesktopProfileStore.catalog(
                for: node,
                mode: gateway.config.effectiveClaudeDesktopCatalogMode,
                supports1M: gateway.config.claudeDesktopSupports1MModels(for: node.id),
                routes: gateway.config.effectiveClaudeDesktopModels(for: node)
            )
            let diskIDs = profileStore.appliedModelIDs()
            let catalogIDs = catalog.map(\.id)
            if diskIDs != catalogIDs, !catalog.isEmpty {
                do {
                    try profileStore.refresh(
                        baseURL: gateway.config.claudeDesktopBaseURL,
                        clientKey: gateway.config.effectiveClaudeDesktopClientKey,
                        catalog: catalog
                    )
                    if ClaudeDesktopAppController.isRunning, let appURL = installation.appURL {
                        try await ClaudeDesktopAppController.restart(appURL: appURL)
                    }
                } catch {
                    state = .failed(error.localizedDescription)
                    return
                }
            }
            configuredModels = catalog
            activeNodeName = node.name
        }
        state = .ready
        beginTrafficObservation(after: 0)
    }

    func refreshProfileForActiveNode(_ nodeID: String) async {
        guard gateway.config.isEnabled,
              let node = ProxyViewModel.shared.configurations.first(where: { $0.id == nodeID }) else { return }
        let catalog = ClaudeDesktopProfileStore.catalog(
            for: node,
            mode: gateway.config.effectiveClaudeDesktopCatalogMode,
            supports1M: gateway.config.claudeDesktopSupports1MModels(for: node.id),
            routes: gateway.config.effectiveClaudeDesktopModels(for: node)
        )
        guard !catalog.isEmpty else {
            state = .failed(AppSettings.shared.t(
                "The active node has no models for Claude Desktop.",
                "当前节点没有可供 Claude Desktop 使用的模型。"
            ))
            return
        }
        // Hot-switch mode keeps one stable four-route surface. Full-catalog
        // mode exposes node-owned models, so a node/catalog change may alter
        // the visible surface and require a Desktop reload.
        let visibleCatalogChanged = !configuredModels.isEmpty
            && profileSurface(of: configuredModels) != profileSurface(of: catalog)
        let shouldReloadDesktop = visibleCatalogChanged && ClaudeDesktopAppController.isRunning
        let trafficBaseline = runtime.claudeDesktopObservedTrafficCount
        do {
            try profileStore.refresh(
                baseURL: gateway.config.claudeDesktopBaseURL,
                clientKey: gateway.config.effectiveClaudeDesktopClientKey,
                catalog: catalog
            )
            configuredModels = catalog
            activeNodeName = node.name
            if shouldReloadDesktop, let appURL = installation.appURL {
                state = .preparing(AppSettings.shared.t(
                    "Reloading Claude Desktop for updated model capabilities…",
                    "模型能力已变化，正在重新加载 Claude Desktop…"
                ))
                try await ClaudeDesktopAppController.restart(appURL: appURL)
                state = .ready
                beginTrafficObservation(after: trafficBaseline)
            }
        } catch let error as ClaudeDesktopProfileError {
            if error.isExternalConflict {
                state = .conflict(error.localizedDescription)
            } else {
                state = .failed(error.localizedDescription)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func profileSurface(
        of catalog: [ClaudeDesktopCatalogEntry]
    ) -> [String] {
        catalog.map { "\($0.id)|\($0.displayName)|\($0.supports1M)" }
    }

    private func beginTrafficObservation(after baseline: UInt64) {
        trafficObservationCancellable?.cancel()
        trafficObservationCancellable = runtime.$claudeDesktopObservedTrafficCount
            .filter { $0 > baseline }
            .prefix(1)
            .sink { [weak self] _ in self?.state = .connected }
    }
}
