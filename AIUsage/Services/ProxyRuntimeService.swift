import Foundation
import QuotaBackend
import os.log
import Darwin

/// 端口残留进程清理 + 孤儿 helper 回收。放在独立 actor 上执行，避免在主线程同步阻塞
/// （Claude/Codex/OpenCode 三轨共用，统一并发语义）。
///
/// 设计要点：
/// - 只清理当前 App 的 QuotaServer 子进程或 PPID==1 的孤儿，绝不误杀另一 App 实例或手工 helper。
/// - SIGTERM → 复核端口 → 仍占用则升级 SIGKILL → 再复核，避免「发了信号但端口没真正释放」。
/// - 端口被外部进程占用时不杀，交由上层给出清晰报错，而不是让新进程绑定失败后以 code 9 退出。
actor ProxyProcessInspector {
    static let shared = ProxyProcessInspector()

    /// 本 App helper 的可执行名（见 QuotaServerLocator：bundle Helpers/QuotaServer 或 .build/*/QuotaServer）。
    private static let helperExecutableName = "QuotaServer"

    /// proc_pidpath 路径缓冲区大小。等价于 sys/proc_info.h 的 PROC_PIDPATHINFO_MAXSIZE (4*MAXPATHLEN)，
    /// 但该宏引用 MAXPATHLEN 无法被 Swift 导入，这里直接用其常量值。
    private static let pidPathMaxSize = 4 * 1024

    private let log = Logger(subsystem: "com.aiusage.desktop", category: "ProxyRuntime")

    // MARK: - 端口回收（激活/启动前）

    /// 尽力释放端口：仅针对当前 App 的子 helper 或 PPID==1 的孤儿，SIGTERM→复核→SIGKILL→复核。
    /// 不动另一 AIUsage 实例、手工 QuotaServer 或其它外部进程（交由上层报端口占用）。
    /// 保留原方法名与 `throws` 签名，OpenCode 轨道无需改动。
    func killStaleProcesses(port: Int, currentProcessIdentifier: Int32) throws {
        let ownHelpers = pids(onPort: port)
            .filter { isReapableHelper(pid: $0, currentProcessIdentifier: currentProcessIdentifier) }
        guard !ownHelpers.isEmpty else { return }

        for pid in ownHelpers {
            log.info("Killing stale proxy helper on port \(port, privacy: .public): pid=\(pid, privacy: .public)")
            kill(pid, SIGTERM)
        }
        if waitUntilPortFree(port, excluding: currentProcessIdentifier) { return }

        // SIGTERM 后端口仍被本 App helper 占用 → 升级 SIGKILL，避免孤儿进程拖死激活。
        let survivors = pids(onPort: port)
            .filter { isReapableHelper(pid: $0, currentProcessIdentifier: currentProcessIdentifier) }
        for pid in survivors {
            log.notice("Force-killing unresponsive proxy helper on port \(port, privacy: .public): pid=\(pid, privacy: .public)")
            kill(pid, SIGKILL)
        }
        _ = waitUntilPortFree(port, excluding: currentProcessIdentifier)
    }

    /// 端口是否仍被占用。用本地连接探测（不依赖 lsof 能否正常 spawn），作为启动前的最终判定。
    /// 连接到 127.0.0.1:port 成功即表示有进程在监听。
    func isPortOccupied(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                connect(fd, sockAddr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }

    // MARK: - 孤儿回收（App 启动时）

    /// 回收本 App 上次会话残留的孤儿 QuotaServer helper（已被 launchd 收养，PPID==1）。
    /// 只杀孤儿，保留仍属其它在跑 AIUsage 实例（PPID 指向活进程）的 helper，兼容多实例。
    /// SIGTERM → 复核 → 仍存活升级 SIGKILL，确保孤儿真的释放端口（正常退出已不留孤儿，此处为崩溃/强退兜底）。
    func reapOrphanedHelpers() {
        let orphans = ownHelperPids().filter { parentPid(of: $0) == 1 }
        guard !orphans.isEmpty else { return }
        for pid in orphans {
            log.info("Reaping orphaned proxy helper pid=\(pid, privacy: .public)")
            kill(pid, SIGTERM)
        }
        // 复核（最多 ~1s）：仍存活的孤儿强杀，避免「发了 SIGTERM 但进程没退、端口仍被占」。
        for _ in 0..<10 {
            usleep(100_000) // 100ms
            if orphans.allSatisfy({ kill($0, 0) != 0 }) { return }
        }
        for pid in orphans where kill(pid, 0) == 0 {
            log.notice("Force-killing surviving orphaned helper pid=\(pid, privacy: .public)")
            kill(pid, SIGKILL)
        }
    }

    // MARK: - Internals

    /// 轮询复核端口是否已空闲（最多 ~1.5s）。
    private func waitUntilPortFree(_ port: Int, excluding currentPid: Int32, attempts: Int = 15) -> Bool {
        for _ in 0..<attempts {
            usleep(100_000) // 100ms
            if pids(onPort: port).allSatisfy({ $0 == currentPid }) { return true }
        }
        return false
    }

    /// 通过 lsof 取占用指定端口的 pid 列表。spawn 失败时返回空（上层再用连接探测兜底）。
    private func pids(onPort port: Int) -> [Int32] {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:\(port)"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        do {
            try lsof.run()
        } catch {
            log.error("lsof spawn failed while inspecting port \(port, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        lsof.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.components(separatedBy: .whitespacesAndNewlines).compactMap { Int32($0) }
    }

    /// pid 的可执行文件是否为本 App 的 QuotaServer helper。
    private func isOwnHelper(pid: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: Self.pidPathMaxSize)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let path = String(cString: buffer)
        return (path as NSString).lastPathComponent == Self.helperExecutableName
    }

    private func isReapableHelper(pid: Int32, currentProcessIdentifier: Int32) -> Bool {
        guard pid != currentProcessIdentifier, isOwnHelper(pid: pid) else { return false }
        let parent = parentPid(of: pid)
        return parent == currentProcessIdentifier || parent == 1
    }

    /// 枚举所有进程，筛出本 App 的 QuotaServer helper。
    private func ownHelperPids() -> [Int32] {
        let capacity = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard capacity > 0 else { return [] }
        let slotCount = Int(capacity) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: slotCount)
        let written = proc_listpids(
            UInt32(PROC_ALL_PIDS),
            0,
            &pids,
            Int32(slotCount * MemoryLayout<pid_t>.stride)
        )
        guard written > 0 else { return [] }
        let actual = Int(written) / MemoryLayout<pid_t>.stride
        return pids.prefix(actual).filter { $0 > 0 && isOwnHelper(pid: $0) }
    }

    /// pid 的父进程号（libproc，避免再 spawn 外部命令）。失败返回 -1。
    private func parentPid(of pid: Int32) -> Int32 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard result > 0 else { return -1 }
        return Int32(bitPattern: info.pbi_ppid)
    }
}

@MainActor
protocol ProxyRuntimeServiceDelegate: AnyObject {
    func proxyRuntimeService(_ service: ProxyRuntimeService, didReceiveProxyLog json: String, configId: String)
    func proxyRuntimeService(_ service: ProxyRuntimeService, processDidTerminateFor configId: String)
}

@MainActor
final class ProxyRuntimeService {
    private static let proxyStartupTimeout: TimeInterval = 5
    private static let proxyStartupProbeIntervalNanos: UInt64 = 100_000_000

    weak var delegate: ProxyRuntimeServiceDelegate?

    private let settingsManager: ClaudeSettingsManager
    private var runningProcesses: [String: Process] = [:]
    private var startGenerations: [String: UInt64] = [:]

    init(settingsManager: ClaudeSettingsManager? = nil) {
        self.settingsManager = settingsManager ?? ClaudeSettingsManager.shared
    }

    /// Activate using full settings.json replacement (new profile-based flow).
    func activateRuntime(
        for config: ProxyConfiguration,
        settings: [String: Any]
    ) async throws {
        if config.needsProxyProcess {
            try await startProxy(config)
        }

        do {
            try settingsManager.writeFullSettings(settings)
        } catch {
            if config.needsProxyProcess {
                stopProxy(config)
            }
            do {
                try settingsManager.restoreFromBackup()
            } catch {
                proxyRuntimeLog.error("Failed to restore settings while rolling back node \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            throw error
        }
    }

    /// Deactivate using backup restoration (new profile-based flow).
    func deactivateRuntime(
        for config: ProxyConfiguration,
        settings: [String: Any]
    ) async throws {
        if config.needsProxyProcess {
            stopProxy(config)
        }

        do {
            try settingsManager.restoreFromBackup()
        } catch {
            do {
                try await activateRuntime(for: config, settings: settings)
            } catch {
                proxyRuntimeLog.error("Failed to restore runtime for node \(config.name, privacy: .public) after deactivation rollback: \(String(describing: error), privacy: .public)")
            }
            throw error
        }
    }

    /// Legacy activation using partial env write (kept for backward compat).
    func activateRuntime(
        for config: ProxyConfiguration,
        envConfig: ClaudeSettingsManager.EnvConfig
    ) async throws {
        if config.needsProxyProcess {
            try await startProxy(config)
        }

        do {
            try settingsManager.writeEnv(envConfig)
        } catch {
            if config.needsProxyProcess {
                stopProxy(config)
            }
            do {
                try settingsManager.clearEnv()
            } catch {
                proxyRuntimeLog.error("Failed to clear Claude runtime env while rolling back node \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            throw error
        }
    }

    /// Legacy deactivation using env clear (kept for backward compat).
    func deactivateRuntime(
        for config: ProxyConfiguration,
        envConfig: ClaudeSettingsManager.EnvConfig
    ) async throws {
        if config.needsProxyProcess {
            stopProxy(config)
        }

        do {
            try settingsManager.clearEnv()
        } catch {
            do {
                try await activateRuntime(for: config, envConfig: envConfig)
            } catch {
                proxyRuntimeLog.error("Failed to restore runtime for node \(config.name, privacy: .public) after deactivation rollback: \(String(describing: error), privacy: .public)")
            }
            throw error
        }
    }

    func clearRuntime() throws {
        try settingsManager.restoreFromBackup()
    }

    // MARK: - Codex Runtime
    // Codex 节点与 Claude 节点写不同文件（~/.codex/config.toml vs ~/.claude/settings.json），
    // 因此可与 Claude 节点并存。代理成本由 App 端按节点重算，故不写共享的 proxy-pricing.json。

    private let codexConfigManager = CodexConfigManager.shared

    /// Codex 节点是否已注入受管理的 config.toml。
    func isCodexConfigManaged() -> Bool {
        codexConfigManager.isManaged
    }

    /// 激活 Codex 节点：启动本地 QuotaServer(PROXY_TARGET=codex)，再外科式注入 config.toml。
    /// - Parameters:
    ///   - globalTOML: 全局通用配置基底（启用时由 ViewModel 传入）。
    ///   - nodeTOML: 该节点的额外 TOML（覆盖全局同名顶层键 / 表）。
    func activateCodexRuntime(
        for config: ProxyConfiguration,
        globalTOML: String? = nil,
        nodeTOML: String? = nil
    ) async throws {
        try await startProxy(config)

        do {
            try codexConfigManager.activate(
                baseURL: codexProxyBaseURL(for: config),
                bearerToken: config.effectiveClientKey,
                model: config.codexModel,
                globalTOML: globalTOML,
                nodeTOML: nodeTOML
            )
        } catch {
            stopProxy(config)
            throw error
        }
    }

    /// 停用 Codex 节点：停止进程并从备份还原 config.toml。
    func deactivateCodexRuntime(for config: ProxyConfiguration) async throws {
        stopProxy(config)

        do {
            try codexConfigManager.restore()
        } catch {
            do {
                try await activateCodexRuntime(for: config)
            } catch {
                proxyRuntimeLog.error("Failed to re-activate Codex runtime for node \(config.name, privacy: .public) after deactivation rollback: \(String(describing: error), privacy: .public)")
            }
            throw error
        }
    }

    /// 还原 Codex config.toml（启动时清理残留激活态用）。
    func clearCodexRuntime() throws {
        try codexConfigManager.restore()
    }

    /// Codex 的 base_url 需包含 /v1，Codex 会在其后拼接 /responses。
    private func codexProxyBaseURL(for config: ProxyConfiguration) -> String {
        let scheme: String
        let portValue: Int
        if config.enableHTTPS {
            scheme = "https"
            portValue = config.effectiveHTTPSPort
        } else {
            scheme = "http"
            portValue = config.port
        }
        return "\(scheme)://\(config.host):\(portValue)/v1"
    }

    // MARK: - Proxy-Only Mode

    /// Start the proxy process without writing to settings.json.
    /// Used for "proxy only" mode where the node serves other tools via its port.
    func startProxyOnly(for config: ProxyConfiguration) async throws {
        try await startProxy(config)
    }

    /// Starts a proxy for a one-off connectivity test. Returns true when this call started it.
    func startProxyForConnectivityTest(for config: ProxyConfiguration) async throws -> Bool {
        if isProxyRunning(config.id) { return false }
        try await startProxy(config)
        return true
    }

    func stopProxyForConnectivityTest(for config: ProxyConfiguration, startedByTest: Bool) {
        guard startedByTest else { return }
        stopProxy(config)
    }

    /// Stop a proxy-only process without touching settings.json or backup.
    func stopProxyOnly(for config: ProxyConfiguration) {
        stopProxy(config)
    }

    func isProxyRunning(_ configId: String) -> Bool {
        guard let process = runningProcesses[configId] else { return false }
        if !process.isRunning {
            runningProcesses.removeValue(forKey: configId)
            return false
        }
        return true
    }

    func processDebugDescription(for configId: String) -> String? {
        guard let process = runningProcesses[configId] else { return nil }
        return "Proxy process isRunning=\(process.isRunning) pid=\(process.processIdentifier)"
    }

    private func startProxy(_ config: ProxyConfiguration) async throws {
        let runtimeLog = Logger(
            subsystem: "com.aiusage.desktop",
            category: "ProxyRuntime"
        )
        guard config.needsProxyProcess else { return }
        if runningProcesses[config.id]?.isRunning == true {
            runtimeLog.info("Proxy already running for node \(config.name, privacy: .public)")
            return
        }
        let generation = (startGenerations[config.id] ?? 0) &+ 1
        startGenerations[config.id] = generation

        // 跨轨端口仲裁：端口已被另一条正在运行的代理（Claude/Codex/OpenCode）占用时直接报错，
        // 必须在 killStaleProcesses 之前——否则会把对方这条活代理当作残留 helper 误杀。
        if let conflict = ProxyPortArbiter.conflict(forPorts: config.listeningPorts, excluding: config.id) {
            runtimeLog.error("Port \(conflict.port, privacy: .public) already used by \(conflict.track, privacy: .public) node \(conflict.label, privacy: .public) while starting \(config.name, privacy: .public)")
            throw ProxyRuntimeError.proxyPortInUseByNode(conflict.port, conflict.track, conflict.label)
        }

        do {
            try await ProxyProcessInspector.shared.killStaleProcesses(
                port: config.port,
                currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier
            )
        } catch {
            proxyRuntimeLog.error("Failed to inspect stale proxy process on port \(config.port, privacy: .public): \(String(describing: error), privacy: .public)")
        }

        // 清理后端口仍被占用（多为外部进程或无法回收的残留）→ 提前给出清晰报错，
        // 而不是放任新 helper 绑定失败后以 code 9 退出、对用户只显示无意义的退出码。
        if await ProxyProcessInspector.shared.isPortOccupied(config.port) {
            runtimeLog.error("Port \(config.port, privacy: .public) still in use after cleanup for node \(config.name, privacy: .public)")
            throw ProxyRuntimeError.proxyPortInUse(config.port)
        }

        var environment = ProcessInfo.processInfo.environment

        if config.nodeType == .codexProxy {
            // Codex 节点: QuotaServer 以 PROXY_TARGET=codex 启动 Responses 入站，转换到 OpenAI 兼容上游。
            environment["PROXY_TARGET"] = "codex"
            environment["OPENAI_API_KEY"] = config.upstreamAPIKey
            environment["OPENAI_BASE_URL"] = config.normalizedUpstreamBaseURL
            // Codex 的 wire_api 恒为 responses：强制 Responses 忠实透传，避免误用 Chat Completions 造成有损转换。
            environment["OPENAI_API_MODE"] = OpenAIUpstreamAPI.responses.rawValue
            let codexModel = config.codexModel
            if !codexModel.isEmpty {
                environment["CODEX_UPSTREAM_MODEL"] = codexModel
            }
            if config.maxOutputTokens > 0 {
                environment["MAX_OUTPUT_TOKENS"] = "\(config.maxOutputTokens)"
            }
            environment["CODEX_CLIENT_KEY"] = config.effectiveClientKey
        } else if config.nodeType == .anthropicDirect {
            environment["PROXY_MODE"] = "passthrough"
            environment["ANTHROPIC_UPSTREAM_URL"] = config.anthropicBaseURL
            environment["ANTHROPIC_UPSTREAM_KEY"] = config.anthropicAPIKey
            environment["ANTHROPIC_API_KEY"] = config.effectiveClientKey
            // Node runtimes receive exact model IDs from product gateways.
            // Alias resolution here would map a second time and violate the
            // Node / product boundary.
            environment["ENABLE_MODEL_ALIAS_MAPPING"] = "0"
            environment["BIG_MODEL"] = config.modelMapping.bigModel.name
            environment["MIDDLE_MODEL"] = config.modelMapping.middleModel.name
            environment["SMALL_MODEL"] = config.modelMapping.smallModel.name
        } else {
            environment["OPENAI_API_KEY"] = config.upstreamAPIKey
            environment["OPENAI_BASE_URL"] = config.normalizedUpstreamBaseURL
            environment["OPENAI_API_MODE"] = config.openAIUpstreamAPI.rawValue
            environment["BIG_MODEL"] = config.modelMapping.bigModel.name
            environment["MIDDLE_MODEL"] = config.modelMapping.middleModel.name
            environment["SMALL_MODEL"] = config.modelMapping.smallModel.name

            if config.maxOutputTokens > 0 {
                environment["MAX_OUTPUT_TOKENS"] = "\(config.maxOutputTokens)"
            }

            environment["ANTHROPIC_API_KEY"] = config.effectiveClientKey
        }

        if !config.nodeType.isCodex {
            if let data = try? JSONEncoder().encode(config.runtimeModelCatalog),
               let json = String(data: data, encoding: .utf8) {
                environment["AIUSAGE_CLAUDE_MODELS_JSON"] = json
            }
            environment["AIUSAGE_CLAUDE_DEFAULT_MODEL"] = config.defaultModel
            environment["AIUSAGE_CLAUDE_MODEL_CATALOG"] = "1"
            environment["AIUSAGE_CLAUDE_EXACT_MODELS"] = "1"
            environment["AIUSAGE_CLAUDE_ROUTE_STYLE"] = "code"
            environment["AIUSAGE_CLAUDE_DESKTOP_TIER_ROUTES"] = "0"
            let exposed1M = config.runtimeModelCatalog.filter { config.supports1MModels.contains($0) }
            if !exposed1M.isEmpty,
               let data = try? JSONEncoder().encode(exposed1M),
               let json = String(data: data, encoding: .utf8) {
                environment["AIUSAGE_CLAUDE_SUPPORTS_1M_JSON"] = json
            }
        }

        if config.enableHTTPS {
            do {
                try await TLSCertificateManager.shared.ensureCertificate()
                environment["ENABLE_HTTPS"] = "1"
                environment["TLS_IDENTITY_PATH"] = TLSCertificateManager.shared.identityFilePath
                environment["HTTPS_PORT"] = "\(config.effectiveHTTPSPort)"
            } catch {
                proxyRuntimeLog.error("TLS certificate setup failed: \(String(describing: error), privacy: .public)")
                throw ProxyRuntimeError.proxyStartFailed("TLS certificate setup failed: \(error.localizedDescription)")
            }
        }

        let configId = config.id
        let configName = config.name
        let healthHost = healthCheckHost(for: config.host)
        let healthHostComponent = healthHost.contains(":") && !healthHost.hasPrefix("[")
            ? "[\(healthHost)]"
            : healthHost
        guard let healthURL = URL(string: "http://\(healthHostComponent):\(config.port)/health") else {
            throw ProxyRuntimeError.proxyStartFailed("invalid health URL")
        }

        let launchResult: QuotaServerLaunchResult
        do {
            launchResult = try await QuotaServerLauncher.launch(
                arguments: ["--host", config.bindAddress, "--port", "\(config.port)"],
                environment: environment,
                healthURL: healthURL,
                startupTimeout: Self.proxyStartupTimeout,
                probeIntervalNanos: Self.proxyStartupProbeIntervalNanos
            ) { [weak self] line in
                runtimeLog.debug("Proxy runtime output for \(configName, privacy: .public): \(line, privacy: .private)")
                guard line.hasPrefix("PROXY_LOG:"),
                      let jsonStart = line.firstIndex(of: Character("{")) else { return }
                let jsonStr = String(line[jsonStart...])
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.delegate?.proxyRuntimeService(self, didReceiveProxyLog: jsonStr, configId: configId)
                }
            }
        } catch QuotaServerStartupError.executableNotFound {
            runtimeLog.error("QuotaServer executable not found while starting node \(config.name, privacy: .public)")
            throw ProxyRuntimeError.quotaServerNotFound
        } catch QuotaServerStartupError.portInUse(let occupiedPort, _) {
            throw ProxyRuntimeError.proxyPortInUse(occupiedPort)
        } catch {
            runtimeLog.error("Failed to start proxy for node \(config.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw ProxyRuntimeError.proxyStartFailed(error.localizedDescription)
        }

        let process = launchResult.process
        guard startGenerations[config.id] == generation else {
            await QuotaServerLauncher.terminateOwnedProcess(process)
            throw CancellationError()
        }
        runningProcesses[config.id] = process
        runtimeLog.info(
            "Proxy started for node \(config.name, privacy: .public) on \(config.displayURL, privacy: .public) pid=\(process.processIdentifier, privacy: .public)"
        )

        process.terminationHandler = { [weak self] proc in
            runtimeLog.notice(
                "Proxy process exited for node \(config.name, privacy: .public) code=\(proc.terminationStatus, privacy: .public)"
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.runningProcesses[config.id] === proc else { return }
                self.runningProcesses.removeValue(forKey: config.id)
                self.delegate?.proxyRuntimeService(self, processDidTerminateFor: config.id)
            }
        }
    }

    private func stopProxy(_ config: ProxyConfiguration) {
        startGenerations[config.id] = (startGenerations[config.id] ?? 0) &+ 1
        guard let process = runningProcesses[config.id] else { return }
        process.terminate()
        runningProcesses.removeValue(forKey: config.id)
        proxyRuntimeLog.info("Proxy stopped for node \(config.name, privacy: .public)")
    }

    private func healthCheckHost(for configuredHost: String) -> String {
        let trimmed = configuredHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "0.0.0.0" || trimmed == "::" {
            return "127.0.0.1"
        }
        return trimmed
    }
}
