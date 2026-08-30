import Foundation
import Network
import os.log
import QuotaBackend

let httpLog = Logger(subsystem: "com.aiusage.quotaserver", category: "HTTP")

enum QuotaHTTPServerError: LocalizedError {
    case invalidPort(Int)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Invalid server port \(port). Use a value from 1 through 65535."
        }
    }
}

/// QuotaServer executable 与宿主 App 之间的启动错误契约。
/// 只输出单行、无环境变量的诊断，避免顶层 async throw 退化成 SIGTRAP crash report。
public enum QuotaServerStartupDiagnostics {
    public static func category(for error: Error) -> String {
        if let networkError = error as? NWError,
           case .posix(let code) = networkError,
           code == .EADDRINUSE {
            return "port_in_use"
        }
        return "startup_failure"
    }

    public static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
}

// MARK: - Lightweight HTTP Server
// Uses Network.framework (no external dependencies) to serve the same JSON API
// as the original Node.js backend.

public final class QuotaHTTPServer: @unchecked Sendable {
    // JSONDecoder/JSONEncoder 的 decode/encode 线程安全（配置不可变时），
    // 静态复用避免每请求/每事件重复创建高成本对象。
    static let requestDecoder = JSONDecoder()
    static let responseEncoder = JSONEncoder()

    static let corsHeaders = [
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, x-api-key, authorization, anthropic-version, anthropic-beta"
    ]

    /// 仅探测请求体顶层 `stream` 标志的轻量解码目标，
    /// 避免为路由判断对大 body 做 JSONSerialization 全量建图。
    struct StreamFlagProbe: Decodable {
        let stream: Bool?
    }

    /// 把 DecodingError 收成可日志的路径摘要（不含 body / token 原文）。
    static func describeDecodingFailure(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else {
            return error.localizedDescription
        }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "keyNotFound:\(key.stringValue) at \(path(context))"
        case .typeMismatch(let type, let context):
            return "typeMismatch:\(type) at \(path(context))"
        case .valueNotFound(let type, let context):
            return "valueNotFound:\(type) at \(path(context))"
        case .dataCorrupted(let context):
            return "dataCorrupted at \(path(context)): \(context.debugDescription)"
        @unknown default:
            return String(describing: decoding)
        }
    }

    let host: String
    let port: Int
    private let startupToken: String?
    let engine = ProviderEngine()
    var httpsConfig: HTTPSConfig?
    private let lifecycleQueue = DispatchQueue(label: "com.aiusage.quotaserver.lifecycle")

    // MARK: - OpenCode Proxy (hot-swappable upstream)
    // 与 Codex/Claude 同构：全局统一代理模式下 OpenCode 上游（base_url/key/forcedModel）由 admin 热替换。
    // service/config 跨连接并发读 + admin 线程写，统一用 openCodeStateLock 保护。
    private let openCodeStateLock = NSLock()
    private var _openCodeProxyService: OpenCodeProxyService?
    private var _openCodeConfig: OpenCodeProxyConfiguration?

    /// 当前 OpenCode 透传服务（启用时有值；全局模式下可被 admin 热替换）。
    var openCodeProxyService: OpenCodeProxyService? {
        get { openCodeStateLock.withLock { _openCodeProxyService } }
        set { openCodeStateLock.withLock { _openCodeProxyService = newValue } }
    }
    /// 当前 OpenCode 上游配置（全局模式下含 forcedModel，用于入站请求体 model 改写）。
    var openCodeConfig: OpenCodeProxyConfiguration? {
        get { openCodeStateLock.withLock { _openCodeConfig } }
        set { openCodeStateLock.withLock { _openCodeConfig = newValue } }
    }

    // MARK: - Claude Proxy (hot-swappable upstream)
    // 与 Codex 同构：全局统一代理模式下 Claude 上游（base_url/key/三模型映射/模式）由 admin 热替换。
    // service/config 跨连接并发读 + admin 线程写，统一用 claudeStateLock 保护。
    private let claudeStateLock = NSLock()
    private var _proxyService: ClaudeProxyService?
    private var _proxyConfig: ClaudeProxyConfiguration?

    /// 当前 Claude 代理服务（openaiConvert 模式有值；passthrough 模式为 nil，由 proxyConfig 驱动）。
    var proxyService: ClaudeProxyService? {
        get { claudeStateLock.withLock { _proxyService } }
        set { claudeStateLock.withLock { _proxyService = newValue } }
    }
    /// 当前 Claude 上游配置（全局模式下可被 admin 热替换；passthrough 模式据此透传）。
    var proxyConfig: ClaudeProxyConfiguration? {
        get { claudeStateLock.withLock { _proxyConfig } }
        set { claudeStateLock.withLock { _proxyConfig = newValue } }
    }

    // MARK: - Global Proxy (hot-swappable Codex upstream)
    // 全局统一代理模式下，本进程常驻在固定端口，由宿主 App 通过受 token 保护的本地 admin 端点
    // 原子热替换 Codex 上游（base_url/key/model），无需重启进程 / 无需重写 CLI 配置 / 端口不变。
    // codex 三态（service/config/activeNodeId）跨连接并发读 + admin 线程写，统一用 codexStateLock 保护。
    private let codexStateLock = NSLock()
    private var _codexProxyService: CodexProxyService?
    private var _codexConfig: CodexProxyConfiguration?
    private var _activeNodeId: String?

    private let claudeTrafficLock = NSLock()
    private var claudeTrafficCounts: [ClaudeClientSurface: UInt64] = [:]

    /// 当前 Codex 代理服务（全局模式下可被 admin 热替换）。
    var codexProxyService: CodexProxyService? {
        get { codexStateLock.withLock { _codexProxyService } }
        set { codexStateLock.withLock { _codexProxyService = newValue } }
    }
    /// 当前 Codex 上游配置（全局模式下可被 admin 热替换）。
    var codexConfig: CodexProxyConfiguration? {
        get { codexStateLock.withLock { _codexConfig } }
        set { codexStateLock.withLock { _codexConfig = newValue } }
    }
    /// 当前生效节点 id：全局模式下随热切换变化，用于给 PROXY_LOG 打上正确的节点归因。
    /// 每个 QuotaServer 进程只服务单一轨（codex/claude/opencode），故本字段跨轨复用、不会歧义。
    var activeNodeId: String? {
        get { codexStateLock.withLock { _activeNodeId } }
        set { codexStateLock.withLock { _activeNodeId = newValue } }
    }

    func recordClaudeTraffic(_ surface: ClaudeClientSurface) {
        guard surface != .unknown else { return }
        let isFirstForSurface = claudeTrafficLock.withLock {
            claudeTrafficCounts[surface, default: 0] &+= 1
            return claudeTrafficCounts[surface] == 1
        }
        // The host only needs an edge-trigger to light the connection state.
        // Emit once per process/surface instead of making the UI poll an admin
        // endpoint forever while no Desktop traffic exists.
        if surface == .desktop, isFirstForSurface {
            print("PROXY_STATUS:{\"client_surface\":\(escapeJSON(surface.rawValue))}")
        }
    }

    func claudeTrafficSnapshot() -> [String: UInt64] {
        claudeTrafficLock.withLock {
            Dictionary(uniqueKeysWithValues: claudeTrafficCounts.map { ($0.key.rawValue, $0.value) })
        }
    }

    /// 全局代理 admin 端点的 Bearer token（仅全局模式下由启动环境注入；为 nil 时 admin 端点关闭）。
    let globalProxyAdminKey: String?
    /// 全局模式下对客户端固定不变的 client key（热切换只换上游，绝不换 client key，保证 CLI 配置无需重写）。
    let fixedCodexClientKey: String?
    /// Claude 全局模式下对客户端固定不变的 client key（写入 settings.json 的 ANTHROPIC_AUTH_TOKEN）。
    let fixedClaudeClientKey: String?
    /// Desktop keeps its own local key so disconnecting/reconfiguring the app
    /// never changes Claude Code credentials.
    let fixedClaudeDesktopClientKey: String?
    /// OpenCode 全局模式下对客户端固定不变的 client key（写入 opencode.json 受管块的 apiKey 占位）。
    let fixedOpenCodeClientKey: String?

    /// 原子热替换 Codex 上游：用新上游构造 service，连同 config / activeNodeId 一次性换入（单次加锁），
    /// 保证并发请求要么看到旧三态、要么看到新三态，不会读到半新半旧的组合。client key 恒用固定值。
    /// 返回 false 表示新配置非法（如缺 key/URL），调用方保持旧上游不变。
    func applyCodexUpstream(_ update: CodexUpstreamUpdate) -> Bool {
        let newConfig = CodexProxyConfiguration(
            enabled: true,
            bindPort: port,
            mode: .openaiConvert,
            upstreamBaseURL: update.baseURL,
            openAIUpstreamAPI: .responses,
            upstreamAPIKey: update.apiKey,
            expectedClientKey: fixedCodexClientKey,
            upstreamModel: update.model,
            maxOutputTokens: update.maxOutputTokens
        )
        guard let newService = try? CodexProxyService(configuration: newConfig) else {
            return false
        }
        codexStateLock.withLock {
            _codexConfig = newConfig
            _codexProxyService = newService
            _activeNodeId = update.nodeId
        }
        return true
    }

    /// 原子热替换 Claude 上游：按模式（passthrough/convert）重建 config（+ convert 模式下重建 service），
    /// 一次性换入。client key 恒用固定值，CLI 的 settings.json 无需重写。返回 false 表示新配置非法。
    func applyClaudeUpstream(_ update: ClaudeUpstreamUpdate) -> Bool {
        let mode: ProxyMode = update.mode == "passthrough" ? .anthropicPassthrough : .openaiConvert
        guard !update.baseURL.isEmpty, !update.apiKey.isEmpty else { return false }
        let currentConfig = proxyConfig

        let newConfig = ClaudeProxyConfiguration(
            enabled: true,
            bindPort: port,
            mode: mode,
            upstreamBaseURL: update.baseURL,
            openAIUpstreamAPI: OpenAIUpstreamAPI.fromEnvironment(update.apiMode),
            upstreamAPIKey: update.apiKey,
            expectedClientKey: fixedClaudeClientKey,
            expectedDesktopClientKey: fixedClaudeDesktopClientKey,
            bigModel: update.bigModel.isEmpty ? "gpt-4o" : update.bigModel,
            middleModel: update.middleModel.isEmpty ? "gpt-4o-mini" : update.middleModel,
            smallModel: update.smallModel.isEmpty ? "gpt-3.5-turbo" : update.smallModel,
            maxOutputTokens: update.maxOutputTokens,
            enableModelAliasMapping: mode == .anthropicPassthrough && (update.enableModelAliasMapping ?? false),
            availableModels: update.availableModels ?? currentConfig?.availableModels ?? [],
            defaultModel: update.defaultModel ?? currentConfig?.defaultModel,
            exposeScienceModelCatalog: currentConfig?.exposeScienceModelCatalog ?? false,
            preferExactCatalogModels: currentConfig?.preferExactCatalogModels ?? false,
            catalogRouteStyle: update.catalogRouteStyle
                .flatMap(ScienceModelProtocolAdapter.RouteStyle.init(rawValue:))
                ?? currentConfig?.catalogRouteStyle
                ?? .science,
            mapDesktopTierRoutes: update.mapDesktopTierRoutes
                ?? currentConfig?.mapDesktopTierRoutes
                ?? false,
            catalogSupports1M: Set(update.catalogSupports1M ?? Array(currentConfig?.catalogSupports1M ?? [])),
            forcedModel: mode == .anthropicPassthrough ? update.forcedModel : nil
        )

        // convert 模式需要 service 做协议转换；passthrough 模式由 proxyConfig 直接透传（service 置空）。
        let newService: ClaudeProxyService?
        if mode == .openaiConvert {
            guard let svc = try? ClaudeProxyService(configuration: newConfig) else { return false }
            newService = svc
        } else {
            newService = nil
        }
        claudeStateLock.withLock {
            _proxyConfig = newConfig
            _proxyService = newService
        }
        activeNodeId = update.nodeId
        return true
    }

    /// 原子热替换 OpenCode（chat/completions 透传轨）上游：用新上游 + forcedModel 重建 service/config 一次性换入。
    /// client key 恒用固定值，opencode.json 无需重写。返回 false 表示新配置非法（缺 URL）。
    func applyOpenCodeUpstream(_ update: OpenCodeUpstreamUpdate) -> Bool {
        guard !update.baseURL.isEmpty else { return false }
        let newConfig = OpenCodeProxyConfiguration(
            enabled: true,
            bindPort: port,
            upstreamBaseURL: update.baseURL,
            upstreamAPIKey: update.apiKey,
            expectedClientKey: fixedOpenCodeClientKey,
            forcedModel: update.model
        )
        guard let newService = try? OpenCodeProxyService(configuration: newConfig) else {
            return false
        }
        openCodeStateLock.withLock {
            _openCodeConfig = newConfig
            _openCodeProxyService = newService
        }
        activeNodeId = update.nodeId
        return true
    }
    private var ipv4Listener: NWListener?
    private var ipv6Listener: NWListener?
    private var httpsListener: NWListener?
    private var stopContinuation: CheckedContinuation<Void, Never>?

    var isPassthrough: Bool { proxyConfig?.mode == .anthropicPassthrough }

    public init(
        host: String,
        port: Int,
        proxyConfig: ClaudeProxyConfiguration? = nil,
        codexConfig: CodexProxyConfiguration? = nil,
        openCodeConfig: OpenCodeProxyConfiguration? = nil,
        httpsConfig: HTTPSConfig? = nil,
        startupToken: String? = nil
    ) {
        self.host = host
        self.port = port
        self._proxyConfig = proxyConfig
        self._openCodeConfig = openCodeConfig
        self.httpsConfig = httpsConfig

        let env = ProcessInfo.processInfo.environment
        self.startupToken = startupToken
            ?? env["AIUSAGE_STARTUP_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
        self.globalProxyAdminKey = env["GLOBAL_PROXY_ADMIN_KEY"].flatMap { $0.isEmpty ? nil : $0 }
        self.fixedCodexClientKey = codexConfig?.expectedClientKey
        self.fixedClaudeClientKey = proxyConfig?.expectedClientKey
        self.fixedClaudeDesktopClientKey = proxyConfig?.expectedDesktopClientKey
        self.fixedOpenCodeClientKey = openCodeConfig?.expectedClientKey
        self._activeNodeId = env["GLOBAL_PROXY_NODE_ID"].flatMap { $0.isEmpty ? nil : $0 }
        self._codexConfig = codexConfig

        if let config = proxyConfig, config.enabled, config.mode == .openaiConvert {
            self._proxyService = try? ClaudeProxyService(configuration: config)
        }
        if let codexConfig, codexConfig.enabled, codexConfig.mode == .openaiConvert {
            self._codexProxyService = try? CodexProxyService(configuration: codexConfig)
        }
        if let openCodeConfig, openCodeConfig.enabled {
            self._openCodeProxyService = try? OpenCodeProxyService(configuration: openCodeConfig)
        }
    }

    deinit {
        stop()
    }

    public func start() async throws {
        let isRunning = lifecycleQueue.sync { ipv4Listener != nil }
        if isRunning {
            return
        }

        guard (1...65_535).contains(port),
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw QuotaHTTPServerError.invalidPort(port)
        }
        let nwHost = NWEndpoint.Host(host)

        let listener4 = try await startIPv4Listener(host: nwHost, port: nwPort)
        let (listener6, ipv6Active) = startIPv6Listener(port: nwPort)

        var tlsListener: NWListener?
        if let httpsConfig {
            do {
                tlsListener = try await startHTTPSListener(config: httpsConfig, host: nwHost)
            } catch {
                httpLog.error("HTTPS listener failed to start: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }

        lifecycleQueue.sync {
            ipv4Listener = listener4
            ipv6Listener = listener6
            httpsListener = tlsListener
        }

        logStartup(ipv6Active: ipv6Active, httpsPort: tlsListener != nil ? httpsConfig?.port : nil)
    }

    public func stop() {
        let state = lifecycleQueue.sync { () -> (NWListener?, NWListener?, NWListener?, CheckedContinuation<Void, Never>?) in
            let currentState = (ipv4Listener, ipv6Listener, httpsListener, stopContinuation)
            ipv4Listener = nil
            ipv6Listener = nil
            httpsListener = nil
            stopContinuation = nil
            return currentState
        }

        state.0?.cancel()
        state.1?.cancel()
        state.2?.cancel()
        state.3?.resume()
    }

    public func run() async throws {
        try await start()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let shouldResumeImmediately = lifecycleQueue.sync { () -> Bool in
                if ipv4Listener == nil {
                    return true
                }
                stopContinuation = cont
                return false
            }
            if shouldResumeImmediately {
                cont.resume()
            }
        }
    }

    private func startIPv4Listener(host: NWEndpoint.Host, port: NWEndpoint.Port) async throws -> NWListener {
        final class ListenerStartState: @unchecked Sendable {
            private let lock = NSLock()
            private var hasResolved = false

            func resolve(
                continuation: CheckedContinuation<Void, Error>,
                result: Result<Void, Error>
            ) {
                lock.lock()
                defer { lock.unlock() }
                guard !hasResolved else { return }
                hasResolved = true
                continuation.resume(with: result)
            }
        }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: host, port: port)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handleConnection(connection) }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let startState = ListenerStartState()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    startState.resolve(continuation: continuation, result: .success(()))
                case .failed(let error):
                    startState.resolve(continuation: continuation, result: .failure(error))
                    self?.handlePrimaryListenerExit(error: error)
                case .cancelled:
                    startState.resolve(continuation: continuation, result: .failure(CancellationError()))
                    self?.handlePrimaryListenerExit(error: nil)
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }

        return listener
    }

    private func startIPv6Listener(port: NWEndpoint.Port) -> (NWListener?, Bool) {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "::1", port: port)
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { await self.handleConnection(connection) }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    httpLog.debug("IPv6 listener unavailable: \(error.localizedDescription, privacy: .public)")
                }
            }
            listener.start(queue: .global())
            return (listener, true)
        } catch {
            return (nil, false)
        }
    }

    private func handlePrimaryListenerExit(error: Error?) {
        if let error {
            httpLog.error("Listener failed: \(error.localizedDescription, privacy: .public)")
        }

        let continuation = lifecycleQueue.sync { () -> CheckedContinuation<Void, Never>? in
            ipv4Listener = nil
            ipv6Listener = nil
            let waiter = stopContinuation
            stopContinuation = nil
            return waiter
        }
        continuation?.resume()
    }

    private func logStartup(ipv6Active: Bool, httpsPort: Int? = nil) {
        var proto = ipv6Active ? "(IPv4 + IPv6)" : "(IPv4)"
        if let httpsPort { proto += " + HTTPS:\(httpsPort)" }
        httpLog.info("QuotaServer listening on \(self.host):\(self.port) \(proto)")
        httpLog.info("Endpoints:")
        httpLog.info("  GET /api/dashboard")
        httpLog.info("  GET /api/provider/:id")
        httpLog.info("  GET /api/providers")
        httpLog.info("  GET /api/health")
        httpLog.info("  GET /health")
        if self.proxyService != nil {
            httpLog.info("  POST /v1/messages (Claude Proxy - OpenAI Convert)")
            httpLog.info("  POST /v1/messages/count_tokens (Claude Proxy)")
            httpLog.info("  GET /v1/files (Claude Proxy)")
            httpLog.info("  POST /v1/files (Claude Proxy)")
            httpLog.info("  GET /v1/files/:id (Claude Proxy)")
            httpLog.info("  DELETE /v1/files/:id (Claude Proxy)")
        }
        if self.isPassthrough {
            httpLog.info("  POST /v1/messages (Anthropic Passthrough)")
        }
        if self.codexProxyService != nil {
            httpLog.info("  POST /v1/responses (Codex Proxy - OpenAI Convert)")
            httpLog.info("  GET  /v1/responses (Codex Proxy - WebSocket upgrade)")
        }
    }

    // MARK: - Connection Handling

    func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .global())
        let requestData: Data
        switch await receiveData(connection) {
        case .none:
            connection.cancel()
            return
        case .tooLarge(let limit):
            let response = claudeErrorResponse(
                type: "request_too_large",
                message: "Request exceeds the \(limit / (1024 * 1024))MB proxy limit",
                status: 413,
                headers: Self.corsHeaders
            )
            await sendResponse(connection, response: response)
            connection.cancel()
            return
        case .complete(let data):
            requestData = data
        }

        let request = normalizeClaudeRoute(parseHTTPRequest(requestData))
        let cleanPath = request.path.split(separator: "?").first.map(String.init) ?? request.path

        // The dedicated Desktop prefix is also an authentication boundary.
        // Root routes remain compatible with current Desktop releases and are
        // classified by their matching credential inside the handlers.
        if request.clientSurface == .desktop,
           proxyConfig?.authenticatedSurface(
               headers: request.headers,
               hintedSurface: .desktop
           ) != .desktop {
            let response = claudeErrorResponse(
                type: "authentication_error",
                message: "Invalid API key",
                status: 401,
                headers: Self.corsHeaders
            )
            await sendResponse(connection, response: response)
            connection.cancel()
            return
        }
        if let surface = authenticatedClaudeSurface(for: request) {
            recordClaudeTraffic(surface)
        }

        if request.method == "POST",
           cleanPath == "/v1/messages" || cleanPath.hasPrefix("/v1/messages/") {
            if isPassthrough && cleanPath != "/v1/messages/count_tokens" {
                await handlePassthroughProxy(connection, request: request)
                return
            }
            if proxyService != nil, cleanPath == "/v1/messages" {
                // 单次解码：一次拿到 stream 标志与完整请求，流式/非流式 handler 直接复用，
                // 不再「JSONSerialization 全量建图读 stream + handler 再 JSONDecoder 解一遍」。
                do {
                    let claudeRequest = try Self.requestDecoder.decode(ClaudeMessageRequest.self, from: request.body)
                    if claudeRequest.stream == true {
                        await handleStreamingProxy(connection, request: request, claudeRequest: claudeRequest)
                    } else {
                        let response = await handleMessagesEndpoint(
                            request: request,
                            claudeRequest: claudeRequest,
                            headers: Self.corsHeaders
                        )
                        await sendResponse(connection, response: response)
                        connection.cancel()
                    }
                    return
                } catch {
                    httpLog.error(
                        "Failed to parse Claude /v1/messages body (\(request.body.count) bytes): \(Self.describeDecodingFailure(error), privacy: .public)"
                    )
                    // 解码失败：交由通用路由按非流式流程返回 400。
                }
            }
        }

        if request.method == "GET",
           cleanPath == "/v1/responses",
           codexProxyService != nil,
           QuotaWebSocket.isUpgradeRequest(request.headers) {
            await handleCodexWebSocketProxy(connection: connection, request: request)
            return
        }

        if request.method == "POST", cleanPath == "/v1/responses", codexProxyService != nil {
            let isStreaming = (try? Self.requestDecoder.decode(StreamFlagProbe.self, from: request.body))?.stream ?? false
            if isStreaming {
                await handleCodexStreamingProxy(connection, request: request)
                return
            }
        }

        if request.method == "POST", cleanPath == "/v1/chat/completions", openCodeProxyService != nil {
            let isStreaming = (try? Self.requestDecoder.decode(StreamFlagProbe.self, from: request.body))?.stream ?? false
            if isStreaming {
                await handleOpenCodeStreamingProxy(connection, request: request)
                return
            }
        }

        let response = await routeRequest(request)
        await sendResponse(connection, response: response)
        connection.cancel()
    }

    private func routeRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        let queryItems = parseQueryItems(request.path)
        let corsHeaders = Self.corsHeaders

        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204, headers: corsHeaders, body: "")
        }

        switch (request.method, path) {
        case ("GET", "/health"), ("GET", "/api/health"):
            let generatedAt = SharedFormatters.iso8601String(from: Date())
            var payload: [String: Any] = [
                "ok": true,
                "generatedAt": generatedAt,
            ]
            if let startupToken { payload["instanceToken"] = startupToken }
            return jsonResponse(payload, headers: corsHeaders)

        // MARK: - Claude Proxy Endpoints

        case ("POST", "/v1/messages"):
            return await handleMessagesEndpoint(request: request, headers: corsHeaders)

        case ("GET", "/v1/models") where proxyConfig?.exposeScienceModelCatalog == true:
            return handleScienceModelsEndpoint(
                request: request,
                queryItems: queryItems,
                headers: corsHeaders
            )

        // MARK: - Global Proxy Admin (hot-swap upstream)

        case ("POST", "/__aiusage/admin/codex-upstream"):
            return handleCodexUpstreamAdmin(request: request, headers: corsHeaders)

        case ("POST", "/__aiusage/admin/claude-upstream"):
            return handleClaudeUpstreamAdmin(request: request, headers: corsHeaders)

        case ("GET", "/__aiusage/admin/claude-status"):
            return handleClaudeStatusAdmin(request: request, headers: corsHeaders)

        case ("POST", "/__aiusage/admin/opencode-upstream"):
            return handleOpenCodeUpstreamAdmin(request: request, headers: corsHeaders)

        // MARK: - Codex Proxy Endpoint

        case ("POST", "/v1/responses"):
            return await handleCodexResponsesEndpoint(request: request, headers: corsHeaders)

        case ("GET", "/v1/models") where codexProxyService != nil:
            return await handleCodexModelsEndpoint(request: request, headers: corsHeaders)

        // MARK: - OpenCode Proxy Endpoint

        case ("POST", "/v1/chat/completions") where openCodeProxyService != nil:
            return await handleOpenCodeChatEndpoint(request: request, headers: corsHeaders)

        case ("GET", "/v1/models") where openCodeProxyService != nil:
            return await handleOpenCodeModelsEndpoint(request: request, headers: corsHeaders)

        case ("POST", "/v1/messages/count_tokens"):
            return await handleCountTokensEndpoint(request: request, headers: corsHeaders)

        case ("GET", "/v1/files"):
            return await handleListFilesEndpoint(request: request, queryItems: queryItems, headers: corsHeaders)

        case ("POST", "/v1/files"):
            return await handleCreateFileEndpoint(request: request, headers: corsHeaders)

        case ("GET", _) where path.hasPrefix("/v1/files/"):
            return await handleFileSubresourceEndpoint(request: request, path: path, headers: corsHeaders)

        case ("DELETE", _) where path.hasPrefix("/v1/files/"):
            return await handleDeleteFileEndpoint(request: request, path: path, headers: corsHeaders)

        case ("POST", "/api/event_logging/batch"):
            if isPassthrough {
                return await forwardPassthrough(request: request, path: "/api/event_logging/batch")
            }
            return await handleEventLoggingEndpoint(request: request, headers: corsHeaders)

        case ("GET", "/api/providers"):
            let providers = ProviderRegistry.allProviders().map { ["id": $0.id, "displayName": $0.displayName, "description": $0.description] }
            return jsonResponse(providers, headers: corsHeaders)

        case ("GET", "/api/dashboard"):
            httpLog.debug("→ GET /api/dashboard")
            let ids = queryItems["ids"]?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let snapshot = await engine.fetchAll(ids: ids)
            return jsonResponse(encodable: snapshot, headers: corsHeaders)

        case ("GET", _) where path.hasPrefix("/api/provider/"):
            let providerId = String(path.dropFirst("/api/provider/".count))
            httpLog.debug("→ GET /api/provider/\(providerId)")
            guard let result = await engine.fetchSingle(id: providerId) else {
                return jsonResponse(["error": "Provider '\(providerId)' not found"], status: 404, headers: corsHeaders)
            }
            return jsonResponse(encodable: result, headers: corsHeaders)

        default:
            return jsonResponse(["error": "Not found"], status: 404, headers: corsHeaders)
        }
    }

    // MARK: - Error Helpers

    func claudeErrorResponse(type: String, message: String, status: Int, headers: [String: String]) -> HTTPResponse {
        let errorJSON = "{\"type\":\"error\",\"error\":{\"type\":\(escapeJSON(type)),\"message\":\(escapeJSON(message))}}"
        var h = headers
        h["Content-Type"] = "application/json"
        h["Content-Length"] = "\(errorJSON.utf8.count)"
        return HTTPResponse(status: status, headers: h, body: errorJSON)
    }

    func escapeJSON(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let json = String(data: data, encoding: .utf8),
              json.count > 2 else {
            let escaped = string
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
            return "\"\(escaped)\""
        }
        // Strip outer [ and ] to get the quoted string
        let start = json.index(after: json.startIndex)
        let end = json.index(before: json.endIndex)
        return String(json[start..<end])
    }

    // MARK: - HTTP Helpers

    struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
        let clientSurface: ClaudeClientSurface

        init(
            method: String,
            path: String,
            headers: [String: String],
            body: Data,
            clientSurface: ClaudeClientSurface = .unknown
        ) {
            self.method = method
            self.path = path
            self.headers = headers
            self.body = body
            self.clientSurface = clientSurface
        }

        var bodyString: String {
            String(data: body, encoding: .utf8) ?? ""
        }
    }

    /// Claude Desktop has used both root base URLs and a tool-owned prefix in
    /// the ecosystem.  Normalize only the pathname and preserve the query
    /// byte-for-byte so endpoint behavior is identical in both forms.
    func normalizeClaudeRoute(_ request: HTTPRequest) -> HTTPRequest {
        let prefix = "/claude-desktop"
        let components = request.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let pathname = String(components.first ?? "")
        guard pathname == prefix || pathname.hasPrefix(prefix + "/") else { return request }

        let stripped = String(pathname.dropFirst(prefix.count))
        let canonicalPath = stripped.isEmpty ? "/" : stripped
        let query = components.count == 2 ? "?" + components[1] : ""
        return HTTPRequest(
            method: request.method,
            path: canonicalPath + query,
            headers: request.headers,
            body: request.body,
            clientSurface: .desktop
        )
    }

    func authenticatedClaudeSurface(for request: HTTPRequest) -> ClaudeClientSurface? {
        proxyConfig?.authenticatedSurface(
            headers: request.headers,
            hintedSurface: request.clientSurface
        )
    }

    func resolvedClaudeSurface(for request: HTTPRequest) -> ClaudeClientSurface {
        authenticatedClaudeSurface(for: request) ?? request.clientSurface
    }

    struct HTTPResponse {
        let status: Int
        let headers: [String: String]
        let body: Data

        init(status: Int, headers: [String: String], body: String) {
            self.status = status
            self.headers = headers
            self.body = Data(body.utf8)
        }

        init(status: Int, headers: [String: String], bodyData: Data) {
            self.status = status
            self.headers = headers
            self.body = bodyData
        }
    }

    // MARK: - Streaming Response

    actor StreamingResponse {
        let connection: NWConnection
        private var headersSent = false

        init(connection: NWConnection) {
            self.connection = connection
        }

        func sendHeaders(status: Int, headers: [String: String]) async {
            guard !headersSent else { return }
            headersSent = true

            let statusText = httpStatusText(status)
            var h = headers
            h["Transfer-Encoding"] = "chunked"

            var headerLines = "HTTP/1.1 \(status) \(statusText)\r\n"
            for (key, value) in h {
                headerLines += "\(key): \(value)\r\n"
            }
            headerLines += "\r\n"

            guard let data = headerLines.data(using: .utf8) else { return }
            await sendRaw(data)
        }

        func sendSSEEvent(event: String?, data: String) async {
            var message = ""
            if let event {
                message += "event: \(event)\n"
            }
            message += "data: \(data)\n\n"

            guard let eventData = message.data(using: .utf8) else { return }
            await sendChunkedFrame(eventData)
        }

        func sendChunk(_ text: String) async {
            guard let data = text.data(using: .utf8) else { return }
            await sendChunkedFrame(data)
        }

        func sendDataChunk(_ data: Data) async {
            guard !data.isEmpty else { return }
            await sendChunkedFrame(data)
        }

        func finish() async {
            let terminator = Data("0\r\n\r\n".utf8)
            await sendRaw(terminator)

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    continuation.resume()
                })
            }
            connection.cancel()
        }

        nonisolated func close() {
            connection.cancel()
        }

        private func sendChunkedFrame(_ body: Data) async {
            let sizeHex = String(body.count, radix: 16)
            var frame = Data("\(sizeHex)\r\n".utf8)
            frame.append(body)
            frame.append(Data("\r\n".utf8))
            await sendRaw(frame)
        }

        private func sendRaw(_ data: Data) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                connection.send(content: data, completion: .contentProcessed { _ in
                    continuation.resume()
                })
            }
        }

        private func httpStatusText(_ code: Int) -> String {
            [
                200: "OK",
                204: "No Content",
                400: "Bad Request",
                401: "Unauthorized",
                404: "Not Found",
                500: "Internal Server Error",
                501: "Not Implemented",
                503: "Service Unavailable",
            ][code] ?? "OK"
        }
    }

    func parseHTTPRequest(_ data: Data) -> HTTPRequest {
        let headerSeparator = Data([13, 10, 13, 10])
        let headerRange = data.range(of: headerSeparator)
        let headerData = headerRange.map { Data(data[..<($0.lowerBound)]) } ?? data
        let bodyData = headerRange.map { Data(data[$0.upperBound...]) } ?? Data()
        let text = String(data: headerData, encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: "\r\n")
        let firstLine = lines.first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        let method = parts.count > 0 ? parts[0] : "GET"
        let path = parts.count > 1 ? parts[1] : "/"

        // Parse headers
        var headers: [String: String] = [:]
        for (index, line) in lines.enumerated() {
            if line.isEmpty {
                break
            }
            if index > 0, let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: bodyData)
    }

    private func parseQueryItems(_ path: String) -> [String: String] {
        guard let questionMark = path.firstIndex(of: "?") else { return [:] }
        let query = String(path[path.index(after: questionMark)...])
        var result: [String: String] = [:]

        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first, !key.isEmpty else { continue }
            let value = parts.count > 1 ? parts[1].removingPercentEncoding ?? parts[1] : ""
            result[key] = value
        }

        return result
    }

    // JSON 响应统一紧凑输出（不 prettyPrinted）：代理热路径上的响应体不必为可读性
    // 膨胀约 30% 的体积与编码成本；调试时可用 jq 等工具格式化。
    func jsonResponse(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        let body: String
        if let data = try? JSONSerialization.data(withJSONObject: object),
           let str = String(data: data, encoding: .utf8) {
            body = str
        } else {
            body = "{}"
        }
        var h = headers
        h["Content-Type"] = "application/json"
        h["Content-Length"] = "\(body.utf8.count)"
        return HTTPResponse(status: status, headers: h, body: body)
    }

    func jsonResponse<T: Encodable>(encodable: T, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        let body: String
        if let data = try? Self.responseEncoder.encode(encodable), let str = String(data: data, encoding: .utf8) {
            body = str
        } else {
            body = "{}"
        }
        var h = headers
        h["Content-Type"] = "application/json"
        h["Content-Length"] = "\(body.utf8.count)"
        return HTTPResponse(status: status, headers: h, body: body)
    }

    enum ReceivedRequest {
        case complete(Data)
        case tooLarge(limit: Int)
    }

    /// A 1M-token context is already ~4MB of JSON before tool schemas and
    /// inline images, so the ceiling has to leave room above that.
    static let maxRequestSize = 64 * 1024 * 1024

    private func receiveData(_ connection: NWConnection) async -> ReceivedRequest? {
        let maxSize = Self.maxRequestSize
        let headerSeparator = Data([13, 10, 13, 10])
        var accumulated = Data()
        // Total request size once the headers declare a Content-Length. Reading
        // to that figure is what keeps a large body intact: stopping at the cap
        // instead would hand the router a truncated body, which surfaces only as
        // an unexplained JSON decode failure.
        var expectedTotal: Int?

        while true {
            if let expectedTotal, accumulated.count >= expectedTotal { break }
            if accumulated.count > maxSize { return .tooLarge(limit: maxSize) }
            guard let chunk = await receiveChunk(connection) else {
                break
            }
            accumulated.append(chunk)

            // Scanning stops once the header block is in hand, so a multi-megabyte
            // body is never re-scanned chunk after chunk.
            if expectedTotal == nil, let headerRange = accumulated.range(of: headerSeparator) {
                let headerText = String(data: accumulated[..<headerRange.lowerBound], encoding: .utf8) ?? ""
                guard let contentLength = extractContentLength(from: headerText) else {
                    // No Content-Length: the headers are the whole request.
                    break
                }
                let total = headerRange.upperBound + contentLength
                if total > maxSize { return .tooLarge(limit: maxSize) }
                expectedTotal = total
            }
        }

        return accumulated.isEmpty ? nil : .complete(accumulated)
    }

    private func receiveChunk(_ connection: NWConnection) async -> Data? {
        return await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                continuation.resume(returning: data)
            }
        }
    }

    private func extractContentLength(from text: String) -> Int? {
        let lines = text.components(separatedBy: "\r\n")
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }
        return nil
    }

    func sendResponse(_ connection: NWConnection, response: HTTPResponse) async {
        let statusText = httpStatusText(response.status)
        var headerLines = "HTTP/1.1 \(response.status) \(statusText)\r\n"
        for (key, value) in response.headers {
            headerLines += "\(key): \(value)\r\n"
        }
        headerLines += "\r\n"
        var full = Data(headerLines.utf8)
        full.append(response.body)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: full, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    private func httpStatusText(_ code: Int) -> String {
        [
            200: "OK",
            204: "No Content",
            400: "Bad Request",
            401: "Unauthorized",
            404: "Not Found",
            500: "Internal Server Error",
            501: "Not Implemented",
            503: "Service Unavailable",
        ][code] ?? "OK"
    }
}
