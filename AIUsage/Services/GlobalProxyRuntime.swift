import Foundation
import Combine
import os.log
import Darwin
import QuotaBackend

// MARK: - Global Proxy Runtime
// 管理某条轨「全局统一代理」的常驻 QuotaServer 进程。与每节点独立进程不同：本进程在固定端口长期存活，
// 切换激活节点时通过受 token 保护的本地 admin 端点热替换上游，进程不重启、端口不变。
// 日志经 stdout PROXY_LOG（已带 node_id）回流到 ProxyViewModel 按节点归因。
//
// 轨道无关：进程启动 env（PROXY_TARGET/上游/client key…）与热切换 payload 由各轨适配器构造，
// 本类只负责进程生命周期、健康检查、admin POST 与端口仲裁。三条轨各有独立实例。

private let globalProxyRuntimeLog = Logger(subsystem: "com.aiusage.desktop", category: "GlobalProxyRuntime")

enum GlobalProxyRuntimeError: LocalizedError {
    case quotaServerNotFound
    case startFailed(String)
    case portInUse(Int)
    case portInUseByNode(Int, String, String)
    case adminUnreachable(String)
    case adminRejected(Int)
    case notRunning

    var errorDescription: String? {
        switch self {
        case .quotaServerNotFound:
            return AppSettings.shared.t("QuotaServer executable not found.", "未找到 QuotaServer 可执行文件。")
        case .startFailed(let reason):
            return AppSettings.shared.t("Failed to start the global proxy: \(reason)", "启动全局代理失败：\(reason)")
        case .portInUse(let port):
            return AppSettings.shared.t(
                "Port \(port) is already in use by another process. Stop that process or choose another global proxy port.",
                "端口 \(port) 已被其它进程占用。请关闭占用进程，或修改全局代理端口。"
            )
        case .portInUseByNode(let port, let track, let name):
            return AppSettings.shared.t(
                "Port \(port) is already in use by node \"\(name)\" under the \(track) proxy. Change the global proxy port, or stop that node first.",
                "端口 \(port) 已被「\(track) 代理」下的节点「\(name)」占用。请修改全局代理端口，或先停用那个节点。"
            )
        case .adminUnreachable(let reason):
            return AppSettings.shared.t("Global proxy admin endpoint is unreachable: \(reason)", "全局代理 admin 端点不可达：\(reason)")
        case .adminRejected(let status):
            return AppSettings.shared.t("Global proxy rejected the upstream switch (HTTP \(status)).", "全局代理拒绝了上游切换（HTTP \(status)）。")
        case .notRunning:
            return AppSettings.shared.t("Global proxy is not running.", "全局代理未在运行。")
        }
    }
}

@MainActor
final class GlobalProxyRuntime: ObservableObject {
    // 每条轨一个常驻实例（互不影响，可同时启用）。
    static let codex = GlobalProxyRuntime(track: .codex, adminPath: "/__aiusage/admin/codex-upstream")
    static let claude = GlobalProxyRuntime(track: .claude, adminPath: "/__aiusage/admin/claude-upstream")
    static let desktop = GlobalProxyRuntime(track: .desktop, adminPath: "/__aiusage/admin/claude-upstream")
    static let opencode = GlobalProxyRuntime(track: .opencode, adminPath: "/__aiusage/admin/opencode-upstream")
    // Science 复用 Claude 轨的 Anthropic→OpenAI 转换代理（同 admin 路由，独立进程/端口）。
    static let science = GlobalProxyRuntime(track: .science, adminPath: "/__aiusage/admin/claude-upstream")
    static var all: [GlobalProxyRuntime] { [codex, claude, desktop, opencode, science] }

    static func instance(for track: GlobalProxyTrack) -> GlobalProxyRuntime {
        switch track {
        case .codex: return codex
        case .claude: return claude
        case .desktop: return desktop
        case .opencode: return opencode
        case .science: return science
        }
    }

    let track: GlobalProxyTrack
    let adminPath: String

    /// 跨轨端口仲裁中的所有者 id（固定标识，排除自身用）。
    var ownerId: String { "__aiusage_global_\(track.rawValue)__" }
    var trackLabel: String {
        switch track {
        case .codex: return AppSettings.shared.t("Codex global proxy", "Codex 全局代理")
        case .claude: return AppSettings.shared.t("Code Gateway", "Code 网关")
        case .desktop: return AppSettings.shared.t("Claude Desktop gateway", "Claude Desktop 网关")
        case .opencode: return AppSettings.shared.t("OpenCode global proxy", "OpenCode 全局代理")
        case .science: return AppSettings.shared.t("Claude Science proxy", "Claude Science 代理")
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var activeNodeId: String?
    @Published private(set) var activeNodeName: String?
    /// Event-driven count of authenticated Desktop traffic observed by the
    /// owned QuotaServer process. This avoids a permanent one-request-per-
    /// second admin polling loop in the host app.
    @Published private(set) var claudeDesktopObservedTrafficCount: UInt64 = 0

    private var process: Process?
    private var adminKey: String?
    private var listenPort = GlobalProxyConfig.defaultCodexPort
    private var httpsListenPort: Int?
    private var startGeneration: UInt64 = 0

    private static let startupTimeout: TimeInterval = 6
    private static let probeIntervalNanos: UInt64 = 250_000_000

    private init(track: GlobalProxyTrack, adminPath: String) {
        self.track = track
        self.adminPath = adminPath
    }

    var isProcessRunning: Bool { process?.isRunning == true }
    var isClaudeDesktopListenerRunning: Bool {
        track == .desktop && isProcessRunning && httpsListenPort != nil
    }

    /// 跨轨仲裁聚合用：本轨全局代理运行时占用的端口所有者（仅在确实运行时上报）。
    func runningPortOwners() -> [ProxyPortArbiter.Owner] {
        guard isProcessRunning else { return [] }
        let ports = [listenPort] + (httpsListenPort.map { [$0] } ?? [])
        return [ProxyPortArbiter.Owner(id: ownerId, ports: ports, track: trackLabel, label: activeNodeName ?? "")]
    }

    // MARK: - Lifecycle

    /// 启动常驻全局代理进程。`env` 由各轨适配器构造（上游 / client key / PROXY_TARGET 等）；
    /// 本类注入 admin key 与初始 node_id。端口冲突走跨轨仲裁 fail-loud；启动后等待 /health 就绪。
    func start(
        port: Int,
        bindHost: String,
        env baseEnv: [String: String],
        nodeId: String,
        nodeName: String,
        httpsPort: Int? = nil,
        tlsIdentityPath: String? = nil
    ) async throws {
        startGeneration &+= 1
        let generation = startGeneration
        if isProcessRunning { await stopAndWaitForExit() }
        guard generation == startGeneration else { throw CancellationError() }
        claudeDesktopObservedTrafficCount = 0

        let requestedPorts = [port] + (httpsPort.map { [$0] } ?? [])
        if Set(requestedPorts).count != requestedPorts.count {
            throw GlobalProxyRuntimeError.portInUse(port)
        }
        if let conflict = ProxyPortArbiter.conflict(forPorts: requestedPorts, excluding: ownerId) {
            throw GlobalProxyRuntimeError.portInUseByNode(conflict.port, conflict.track, conflict.label)
        }

        // 仲裁只知道当前 App 管理的实例；外部进程或上次崩溃遗留 helper 还需要系统级复核。
        for requestedPort in requestedPorts {
            do {
                try await ProxyProcessInspector.shared.killStaleProcesses(
                    port: requestedPort,
                    currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier
                )
            } catch {
                globalProxyRuntimeLog.error("Failed to inspect stale QuotaServer processes on port \(requestedPort, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            if await ProxyProcessInspector.shared.isPortOccupied(requestedPort) {
                throw GlobalProxyRuntimeError.portInUse(requestedPort)
            }
        }
        guard generation == startGeneration else { throw CancellationError() }

        let admin = UUID().uuidString
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in baseEnv { environment[key] = value }
        if let httpsPort, let tlsIdentityPath {
            environment["ENABLE_HTTPS"] = "1"
            environment["HTTPS_PORT"] = "\(httpsPort)"
            environment["TLS_IDENTITY_PATH"] = tlsIdentityPath
        } else {
            environment.removeValue(forKey: "ENABLE_HTTPS")
            environment.removeValue(forKey: "HTTPS_PORT")
            environment.removeValue(forKey: "TLS_IDENTITY_PATH")
        }
        environment["GLOBAL_PROXY_ADMIN_KEY"] = admin
        environment["GLOBAL_PROXY_NODE_ID"] = nodeId

        let capturedTrack = track
        guard let healthURL = URL(string: "http://127.0.0.1:\(port)/health") else {
            throw GlobalProxyRuntimeError.startFailed("invalid health URL")
        }

        let launchResult: QuotaServerLaunchResult
        do {
            launchResult = try await QuotaServerLauncher.launch(
                arguments: ["--host", bindHost, "--port", "\(port)"],
                environment: environment,
                healthURL: healthURL,
                startupTimeout: Self.startupTimeout,
                probeIntervalNanos: Self.probeIntervalNanos
            ) { line in
                guard let jsonStart = line.firstIndex(of: Character("{")) else { return }
                let jsonStr = String(line[jsonStart...])
                if line.hasPrefix("PROXY_STATUS:"),
                   let data = jsonStr.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object["client_surface"] as? String == ClaudeClientSurface.desktop.rawValue {
                    Task { @MainActor in
                        let runtime = GlobalProxyRuntime.instance(for: capturedTrack)
                        runtime.claudeDesktopObservedTrafficCount &+= 1
                    }
                    return
                }
                guard line.hasPrefix("PROXY_LOG:") else { return }
                Task { @MainActor in
                    // OpenCode 轨：归因到 OpenCodeProxyRuntime（节点卡片/统计/热力图同源、按节点定价算成本）。
                    // Claude product gateways forward into a Node Runtime,
                    // which owns aggregate usage. Ignoring their transport log
                    // prevents every request from being counted twice.
                    if capturedTrack == .opencode {
                        OpenCodeProxyRuntime.shared.ingestGlobalProxyLog(jsonStr)
                    } else if capturedTrack == .codex {
                        let runtime = GlobalProxyRuntime.instance(for: capturedTrack)
                        ProxyViewModel.shared.parseProxyLog(jsonStr, configId: runtime.activeNodeId ?? "")
                    }
                }
            }
        } catch QuotaServerStartupError.executableNotFound {
            throw GlobalProxyRuntimeError.quotaServerNotFound
        } catch QuotaServerStartupError.portInUse(let occupiedPort, _) {
            throw GlobalProxyRuntimeError.portInUse(occupiedPort)
        } catch {
            throw GlobalProxyRuntimeError.startFailed(error.localizedDescription)
        }
        let proc = launchResult.process
        guard generation == startGeneration else {
            await QuotaServerLauncher.terminateOwnedProcess(proc)
            throw CancellationError()
        }

        proc.terminationHandler = { [capturedTrack] p in
            Logger(subsystem: "com.aiusage.desktop", category: "GlobalProxyRuntime")
                .notice("Global proxy (\(capturedTrack.rawValue, privacy: .public)) exited code=\(p.terminationStatus, privacy: .public)")
            Task { @MainActor in
                let runtime = GlobalProxyRuntime.instance(for: capturedTrack)
                if runtime.process === p {
                    runtime.process = nil
                    runtime.isRunning = false
                }
            }
        }

        self.process = proc
        self.adminKey = admin
        self.listenPort = port
        self.httpsListenPort = httpsPort
        self.activeNodeId = nodeId
        self.activeNodeName = nodeName

        self.isRunning = true
        globalProxyRuntimeLog.info("Global proxy (\(self.track.rawValue, privacy: .public)) started on \(bindHost, privacy: .public):\(port, privacy: .public) pid=\(proc.processIdentifier, privacy: .public) node=\(nodeId, privacy: .public)")
    }

    func stop() {
        startGeneration &+= 1
        stopCurrentProcess()
    }

    private func stopCurrentProcess() {
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        adminKey = nil
        httpsListenPort = nil
        isRunning = false
        globalProxyRuntimeLog.info("Global proxy (\(self.track.rawValue, privacy: .public)) stopped")
    }

    /// `Process.terminate()` 只发信号，不保证监听端口已释放。重启前显式等待，
    /// 超时后仅强制结束自己持有的子进程，消除 stop→start 竞态。
    private func stopAndWaitForExit() async {
        guard let ownedProcess = process else {
            stopCurrentProcess()
            return
        }
        stopCurrentProcess()

        let deadline = Date().addingTimeInterval(1.5)
        while ownedProcess.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if ownedProcess.isRunning {
            globalProxyRuntimeLog.notice("Force-stopping QuotaServer pid=\(ownedProcess.processIdentifier, privacy: .public) after termination timeout")
            kill(ownedProcess.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(0.5)
            while ownedProcess.isRunning, Date() < killDeadline {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
    }

    // MARK: - Hot Switch

    /// 热切换激活节点：POST admin 端点替换上游，进程不重启。`payload`/`adminPath` 由各轨适配器构造
    /// （OpenCode 按接口复用 codex/claude/opencode 三个 admin 路由，故 adminPath 由调用方下发；
    /// 缺省回退到本实例固定路径，兼容 Codex/Claude 单一路由）。
    func switchUpstream(payload: [String: Any], adminPath overridePath: String? = nil, nodeId: String, nodeName: String) async throws {
        try Task.checkCancellation()
        guard isProcessRunning, let adminKey else {
            throw GlobalProxyRuntimeError.notRunning
        }
        let effectivePath = overridePath ?? adminPath
        guard let url = URL(string: "http://127.0.0.1:\(listenPort)\(effectivePath)") else {
            throw GlobalProxyRuntimeError.adminUnreachable("invalid url")
        }

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            // URLSession 将任务取消桥接成 URLError.cancelled；保留取消语义，不能报网络故障。
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            throw GlobalProxyRuntimeError.adminUnreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GlobalProxyRuntimeError.adminUnreachable("no http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GlobalProxyRuntimeError.adminRejected(http.statusCode)
        }

        self.activeNodeId = nodeId
        self.activeNodeName = nodeName
        globalProxyRuntimeLog.info("Global proxy (\(self.track.rawValue, privacy: .public)) hot-switched to node \(nodeId, privacy: .public)")
    }

    func claudeDesktopTrafficCount() async throws -> UInt64 {
        guard isProcessRunning, let adminKey else {
            throw GlobalProxyRuntimeError.notRunning
        }
        guard let url = URL(string: "http://127.0.0.1:\(listenPort)/__aiusage/admin/claude-status") else {
            throw GlobalProxyRuntimeError.adminUnreachable("invalid url")
        }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GlobalProxyRuntimeError.adminRejected((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let traffic = object?["traffic"] as? [String: Any]
        return (traffic?[ClaudeClientSurface.desktop.rawValue] as? NSNumber)?.uint64Value ?? 0
    }

}
