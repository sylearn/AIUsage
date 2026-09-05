import Foundation
import QuotaBackend
import os.log

// MARK: - Connectivity Error

/// 连通性测试专用错误：把底层 URLError/HTTP 状态包装为语义明确、可本地化的类型，
/// 避免裸抛系统错误（详见架构规范「错误必须被包装为语义明确的类型」）。
enum ProxyConnectivityError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(code: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return AppSettings.shared.t("Invalid endpoint URL", "无效的端点 URL")
        case .invalidResponse:
            return AppSettings.shared.t("Invalid server response", "服务器响应无效")
        case let .httpStatus(code, body):
            return "HTTP \(code): \(body)"
        }
    }

    /// 已知的 HTTP 状态码（仅 `.httpStatus` 携带），供 UI 徽章展示短摘要。
    var statusCode: Int? {
        if case let .httpStatus(code, _) = self { return code }
        return nil
    }
}

/// 连通性探测的结构化结果：把「状态码 + 往返耗时 + 可读明细」从 View 层解析里解耦出来，
/// 由 ViewModel 直接产出结构化字段，UI 只负责渲染（徽章/Popover）。
struct ConnectivityProbeResult {
    let statusCode: Int
    let latencyMs: Int
    let message: String
}

extension ProxyViewModel {

    func restoreActivatedNode() {
        Task {
            // 启动时先回收上次会话残留的孤儿 QuotaServer（崩溃/强退后被 launchd 收养、仍占着端口），
            // 再恢复激活态，避免恢复/激活时因端口被自家孤儿占用而失败（旧版表现为 code 9）。
            await ProxyProcessInspector.shared.reapOrphanedHelpers()
            // 先恢复两轨全局代理（启用态下各自独占 config.toml / settings.json）；
            // 随后的每节点恢复会因对应轨全局启用而跳过。
            await GlobalProxyManager.codex.restoreOnLaunch()
            await GlobalProxyManager.claude.restoreOnLaunch()
            await GlobalProxyManager.desktop.restoreOnLaunch()
            await ClaudeDesktopIntegrationManager.shared.restoreOnLaunch()
            await GlobalProxyManager.opencode.restoreOnLaunch()
            await ScienceProxyManager.shared.restoreOnLaunch()
            await restoreActivatedNodeAsync()
            await restoreActivatedCodexNodeAsync()
            await restoreProxyOnlyNodes()
        }
    }

    /// 启动时恢复 Codex 代理激活态（独立于 Claude 轨道）。
    private func restoreActivatedCodexNodeAsync() async {
        // 全局代理启用时由它独占 config.toml；跳过每节点恢复，避免清理/还原误删全局受管块。
        if GlobalProxyManager.shared.config.isEnabled {
            return
        }
        let shouldAutoRestore = AppSettings.shared.proxyAutoRestoreOnLaunch
        let savedId = shouldAutoRestore
            ? UserDefaults.standard.string(forKey: DefaultsKey.proxyActivatedCodexConfigId)
            : nil

        guard let id = savedId,
              let config = configurations.first(where: { $0.id == id }),
              config.nodeType.isCodex else {
            activatedCodexConfigId = nil
            saveActivatedCodexId()
            // 清理任何残留的受管理 config.toml（仅当确实由我们注入时才会动作）。
            if runtimeService.isCodexConfigManaged() {
                do {
                    try runtimeService.clearCodexRuntime()
                } catch {
                    proxyRuntimeLog.error("Failed to clear Codex runtime while restoring empty activation state: \(String(describing: error), privacy: .public)")
                }
            }
            return
        }

        proxyRuntimeLog.info("Restoring Codex node \(config.name, privacy: .public)")
        do {
            try await activateRuntime(for: config)
            try persistActivationSelection(config.id, touchLastUsedAt: false, isCodex: true)
        } catch {
            proxyRuntimeLog.error("Failed to restore Codex node \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
            activatedCodexConfigId = nil
            saveActivatedCodexId()
            do {
                try runtimeService.clearCodexRuntime()
            } catch {
                proxyRuntimeLog.error("Failed to clear Codex runtime after restore failure: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func restoreActivatedNodeAsync() async {
        // Code now always owns one product Gateway. A legacy 0.15 per-node
        // activation is migrated below instead of restoring the old direct
        // settings.json route.
        if GlobalProxyManager.claude.isEnabled {
            return
        }
        let shouldAutoRestore = AppSettings.shared.proxyAutoRestoreOnLaunch

        activatedConfigId = shouldAutoRestore
            ? UserDefaults.standard.string(forKey: DefaultsKey.proxyActivatedConfigId)
            : nil

        if activatedConfigId == nil {
            var migrated = false
            for i in configurations.indices where configurations[i].isEnabled {
                configurations[i].isEnabled = false
                migrated = true
            }
            if migrated { saveConfigurations() }
        }

        guard let id = activatedConfigId else {
            do {
                try runtimeService.clearRuntime()
            } catch {
                proxyRuntimeLog.error("Failed to clear proxy runtime while restoring empty activation state: \(String(describing: error), privacy: .public)")
            }
            return
        }

        guard let config = configurations.first(where: { $0.id == id }) else {
            var migrated = false
            for i in configurations.indices where configurations[i].isEnabled {
                configurations[i].isEnabled = false
                migrated = true
            }
            activatedConfigId = nil
            if migrated { saveConfigurations() }
            saveActivatedId()
            do {
                try runtimeService.clearRuntime()
            } catch {
                proxyRuntimeLog.error("Failed to clear proxy runtime for missing restored node: \(String(describing: error), privacy: .public)")
            }
            return
        }

        proxyRuntimeLog.info("Migrating legacy Code route for \(config.name, privacy: .public) to the Code Gateway")
        do {
            try runtimeService.clearRuntime()
            try persistActivationSelection(nil, touchLastUsedAt: false, isCodex: false)
        } catch {
            proxyRuntimeLog.error("Failed to clear the legacy Code route for \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
            activatedConfigId = nil
            for index in configurations.indices {
                configurations[index].isEnabled = false
            }
            saveConfigurations()
            saveActivatedId()
            do {
                try runtimeService.clearRuntime()
            } catch {
                proxyRuntimeLog.error("Failed to clear proxy runtime after restore failure: \(String(describing: error), privacy: .public)")
            }
            return
        }
        await GlobalProxyManager.claude.enable(activeNodeId: config.id)
        if !GlobalProxyManager.claude.isEnabled {
            proxyRuntimeLog.error("Failed to migrate the legacy Code route for \(config.name, privacy: .public) to the Code Gateway")
        }
    }

    func activateRuntime(for config: ProxyConfiguration) async throws {
        if config.nodeType.isCodex {
            // 通用配置基底（启用时）+ 节点额外 TOML，交由 CodexConfigManager 按顶层键合并注入。
            let globalTOML = profileStore.codexGlobalConfig.hasContent
                ? profileStore.codexGlobalConfig.tomlText
                : nil
            let nodeTOML = profileStore.profile(for: config.id)?.metadata.proxy.extraTOML?.nilIfBlank
            try await runtimeService.activateCodexRuntime(
                for: config,
                globalTOML: globalTOML,
                nodeTOML: nodeTOML
            )
            return
        }

        if let profile = profileStore.profile(for: config.id) {
            let finalSettings: [String: Any]
            if profile.metadata.proxy.shouldMergeClaudeCommonConfig(globalEnabled: profileStore.globalConfig.enabled) {
                finalSettings = GlobalConfig.deepMerge(
                    base: profileStore.globalConfig.settings,
                    override: profile.settings
                )
            } else {
                finalSettings = profile.settings
            }

            var settingsToWrite = finalSettings
            if config.enableHTTPS {
                var env = settingsToWrite["env"] as? [String: Any] ?? [:]
                env["NODE_EXTRA_CA_CERTS"] = TLSCertificateManager.shared.certFilePath
                let httpsURL = "https://\(config.host):\(config.effectiveHTTPSPort)"
                env["ANTHROPIC_BASE_URL"] = httpsURL
                settingsToWrite["env"] = env
            }

            try await runtimeService.activateRuntime(
                for: config,
                settings: settingsToWrite
            )
        } else {
            try await runtimeService.activateRuntime(
                for: config,
                envConfig: envConfig(for: config)
            )
        }
    }

    func deactivateRuntime(for config: ProxyConfiguration) async throws {
        if config.nodeType.isCodex {
            try await runtimeService.deactivateCodexRuntime(for: config)
            return
        }

        if let profile = profileStore.profile(for: config.id) {
            try await runtimeService.deactivateRuntime(
                for: config,
                settings: profile.settings
            )
        } else {
            try await runtimeService.deactivateRuntime(
                for: config,
                envConfig: envConfig(for: config)
            )
        }
    }

    func isProxyRunning(_ configId: String) -> Bool {
        runtimeService.isProxyRunning(configId)
    }

    func testConnectivity(_ id: String) async {
        guard let config = configurations.first(where: { $0.id == id }) else { return }
        guard !connectivityTestStates[id, default: .init()].isTesting else { return }

        connectivityTestStates[id] = ProxyConnectivityTestState(isTesting: true, lastSucceeded: nil, message: nil)
        defer {
            var state = connectivityTestStates[id, default: .init()]
            state.isTesting = false
            connectivityTestStates[id] = state
            saveConnectivityResults()
        }

        let startedByTest: Bool
        do {
            if config.needsProxyProcess {
                startedByTest = try await runtimeService.startProxyForConnectivityTest(for: config)
            } else {
                startedByTest = false
            }
        } catch {
            connectivityTestStates[id] = ProxyConnectivityTestState(
                isTesting: false,
                lastSucceeded: false,
                message: sanitizedConnectivityMessage(error.localizedDescription),
                statusCode: (error as? ProxyConnectivityError)?.statusCode,
                latencyMs: nil,
                testedAt: Date()
            )
            return
        }

        defer {
            runtimeService.stopProxyForConnectivityTest(for: config, startedByTest: startedByTest)
        }

        do {
            let result = config.nodeType.isCodex
                ? try await performCodexConnectivityRequest(config)
                : try await performClaudeConnectivityRequest(config)
            connectivityTestStates[id] = ProxyConnectivityTestState(
                isTesting: false,
                lastSucceeded: true,
                message: result.message,
                statusCode: result.statusCode,
                latencyMs: result.latencyMs,
                testedAt: Date()
            )
        } catch {
            connectivityTestStates[id] = ProxyConnectivityTestState(
                isTesting: false,
                lastSucceeded: false,
                message: sanitizedConnectivityMessage(error.localizedDescription),
                statusCode: (error as? ProxyConnectivityError)?.statusCode,
                latencyMs: nil,
                testedAt: Date()
            )
        }
    }

    // MARK: - Connectivity Result Persistence

    // 高成本编解码器提取为静态常量，避免每次保存/读取重复创建。
    private static let connectivityResultsEncoder = JSONEncoder()
    private static let connectivityResultsDecoder = JSONDecoder()

    /// 把已完成的连通性结果（含脱敏 message）持久化到 UserDefaults，跨重启保留「上次测试时间 + 结果」。
    /// 仅存非进行中的条目；message 已经过 `sanitizedConnectivityMessage` 脱敏，无敏感信息。
    func saveConnectivityResults() {
        let finished = connectivityTestStates.filter { !$0.value.isTesting }
        guard let data = try? Self.connectivityResultsEncoder.encode(finished) else {
            return
        }
        UserDefaults.standard.set(data, forKey: DefaultsKey.proxyConnectivityResults)
    }

    /// 启动时还原连通性结果。强制 `isTesting=false`（重启后没有进行中的测试），并裁剪掉已不存在的节点。
    func restoreConnectivityResults() {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.proxyConnectivityResults),
              let decoded = try? Self.connectivityResultsDecoder.decode([String: ProxyConnectivityTestState].self, from: data) else {
            return
        }
        let knownIds = Set(configurations.map(\.id))
        var restored: [String: ProxyConnectivityTestState] = [:]
        for (id, var state) in decoded where knownIds.contains(id) {
            state.isTesting = false
            restored[id] = state
        }
        connectivityTestStates = restored
    }

    /// 节点被编辑/删除时清除其旧连通性结果（旧结果对新配置不再有效）。
    func clearConnectivityResult(for id: String) {
        if connectivityTestStates.removeValue(forKey: id) != nil {
            saveConnectivityResults()
        }
    }

    private func performClaudeConnectivityRequest(_ config: ProxyConfiguration) async throws -> ConnectivityProbeResult {
        let baseURL: String
        let apiKey: String
        if config.needsProxyProcess {
            baseURL = config.displayURL
            apiKey = config.effectiveClientKey
        } else {
            baseURL = config.anthropicBaseURL
            apiKey = config.anthropicAPIKey
        }

        guard let url = URL(string: claudeMessagesEndpoint(baseURL: baseURL)) else {
            throw ProxyConnectivityError.invalidURL
        }

        let model = [
            config.defaultModel,
            config.modelMapping.middleModel.name,
            config.modelMapping.bigModel.name,
        ].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "claude-sonnet-4-6"

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8,
            "stream": false,
            "messages": [
                ["role": "user", "content": "ping"]
            ],
        ]

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        guard let http = response as? HTTPURLResponse else {
            throw ProxyConnectivityError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ProxyConnectivityError.httpStatus(code: http.statusCode, body: sanitizedConnectivityMessage(text))
        }

        return ConnectivityProbeResult(
            statusCode: http.statusCode,
            latencyMs: elapsedMs,
            message: AppSettings.shared.t(
                "HTTP \(http.statusCode), \(elapsedMs) ms",
                "HTTP \(http.statusCode)，\(elapsedMs) ms"
            )
        )
    }

    private func claudeMessagesEndpoint(baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasSuffix("/v1") {
            return "\(trimmed)/messages"
        }
        if trimmed.hasSuffix("/v1/messages") {
            return trimmed
        }
        return "\(trimmed)/v1/messages"
    }

    /// Codex 节点连通性测试：走 OpenAI Responses 口径（`POST /v1/responses`）。
    /// 经本地 Codex 代理忠实透传到上游，可端到端验证「客户端 key → 代理 → 上游 key」整条链路。
    private func performCodexConnectivityRequest(_ config: ProxyConfiguration) async throws -> ConnectivityProbeResult {
        let baseURL: String
        let apiKey: String
        if config.needsProxyProcess {
            baseURL = config.displayURL
            apiKey = config.effectiveClientKey
        } else {
            baseURL = config.upstreamBaseURL
            apiKey = config.upstreamAPIKey
        }

        guard let url = URL(string: codexResponsesEndpoint(baseURL: baseURL)) else {
            throw ProxyConnectivityError.invalidURL
        }

        let model = [
            config.codexModel,
            config.defaultModel,
        ].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "gpt-5-codex"

        // Codex 连通性探测请求体。
        // 注意：new-api / one-api 类中转（如 anyrouter）会校验入站是否为「合法 Codex 请求」，
        // 仅当 `input` 为消息数组且携带 `include:["reasoning.encrypted_content"]`（真实 Codex CLI 的签名）
        // 才放行；否则一律 HTTP 400 `invalid_responses_request`。纯字符串 input 或缺 include 都会被拒。
        // 因此这里按真实 Codex 形态构造最小请求；max_output_tokens 下限为 16，用于压低探测成本。
        let body: [String: Any] = [
            "model": model,
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": "ping"]
                    ],
                ]
            ],
            "include": ["reasoning.encrypted_content"],
            "store": false,
            "stream": false,
            "max_output_tokens": 16,
        ]

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        guard let http = response as? HTTPURLResponse else {
            throw ProxyConnectivityError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ProxyConnectivityError.httpStatus(code: http.statusCode, body: sanitizedConnectivityMessage(text))
        }

        return ConnectivityProbeResult(
            statusCode: http.statusCode,
            latencyMs: elapsedMs,
            message: AppSettings.shared.t(
                "HTTP \(http.statusCode), \(elapsedMs) ms",
                "HTTP \(http.statusCode)，\(elapsedMs) ms"
            )
        )
    }

    private func codexResponsesEndpoint(baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasSuffix("/v1/responses") {
            return trimmed
        }
        if trimmed.hasSuffix("/v1") {
            return "\(trimmed)/responses"
        }
        return "\(trimmed)/v1/responses"
    }

    /// 预编译的脱敏规则（正则 + 替换模板）。提取为静态常量，避免每次测试反复编译正则。
    private static let connectivityRedactionRules: [(regex: NSRegularExpression, template: String)] = {
        let specs: [(pattern: String, template: String)] = [
            (#"(?i)sk-[A-Za-z0-9_\-]{8,}"#, "sk-••••"),
            (#"(?i)(Bearer\s+)[A-Za-z0-9._~+/=\-]{8,}"#, "$1••••"),
            (#"(?i)(ANTHROPIC_AUTH_TOKEN["':=\s]+)[^"',\s}]+"#, "$1••••"),
            (#"(?i)(x-api-key["':=\s]+)[^"',\s}]+"#, "$1••••"),
        ]
        return specs.compactMap { spec in
            (try? NSRegularExpression(pattern: spec.pattern)).map { ($0, spec.template) }
        }
    }()

    private func sanitizedConnectivityMessage(_ raw: String) -> String {
        var text = raw
        for rule in Self.connectivityRedactionRules {
            let range = NSRange(text.startIndex..., in: text)
            text = rule.regex.stringByReplacingMatches(in: text, range: range, withTemplate: rule.template)
        }
        return String(text.prefix(500))
    }
}

extension ProxyViewModel: ProxyRuntimeServiceDelegate {
    func proxyRuntimeService(_ service: ProxyRuntimeService, didReceiveProxyLog json: String, configId: String) {
        parseProxyLog(json, configId: configId)
    }

    func proxyRuntimeService(_ service: ProxyRuntimeService, processDidTerminateFor configId: String) {
        guard !operationInProgressConfigIds.contains(configId) else {
            return
        }
        let hasRuntimeLease = !nodeRuntimeConsumers[configId, default: []].isEmpty
        let shouldRemainRunning = isNodeActivated(configId) || hasRuntimeLease
        guard shouldRemainRunning,
              let config = configurations.first(where: { $0.id == configId }),
              config.needsProxyProcess else {
            if proxyOnlyRunningIds.remove(configId) != nil {
                nodeRuntimeConsumers[configId]?.remove(.manual)
                if nodeRuntimeConsumers[configId]?.isEmpty == true {
                    nodeRuntimeConsumers.removeValue(forKey: configId)
                }
                saveProxyOnlyIds()
            }
            return
        }

        scheduleProxyRuntimeRestart(for: config)
    }

    private func scheduleProxyRuntimeRestart(for config: ProxyConfiguration) {
        let attempt = proxyRuntimeRestartAttempts[config.id, default: 0] + 1
        guard attempt <= Self.maxProxyRuntimeRestartAttempts else {
            markProxyRuntimeDown(config)
            return
        }

        proxyRuntimeRestartAttempts[config.id] = attempt
        let delay = Self.proxyRuntimeRestartBaseDelayNanos * UInt64(attempt)
        proxyRuntimeLog.notice(
            "Proxy process for active node \(config.name, privacy: .public) exited unexpectedly; scheduling restart attempt \(attempt, privacy: .public)"
        )

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self else { return }
            guard self.isNodeActivated(config.id) || !self.nodeRuntimeConsumers[config.id, default: []].isEmpty,
                  !self.operationInProgressConfigIds.contains(config.id),
                  let latestConfig = self.configurations.first(where: { $0.id == config.id }),
                  latestConfig.needsProxyProcess else {
                return
            }

            do {
                try await self.runtimeService.startProxyOnly(for: latestConfig)
                self.proxyRuntimeDownConfigIds.remove(latestConfig.id)
                proxyRuntimeLog.info(
                    "Proxy process restarted for active node \(latestConfig.name, privacy: .public) on attempt \(attempt, privacy: .public)"
                )
                self.scheduleProxyRuntimeRestartReset(for: latestConfig.id, attempt: attempt)
            } catch {
                let redactedMessage = SensitiveDataRedactor.redactedMessage(for: error)
                proxyRuntimeLog.error(
                    "Failed to restart proxy process for active node \(latestConfig.name, privacy: .public) on attempt \(attempt, privacy: .public): \(redactedMessage, privacy: .public)"
                )
                self.scheduleProxyRuntimeRestart(for: latestConfig)
            }
        }
    }

    private func scheduleProxyRuntimeRestartReset(for configId: String, attempt: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.proxyRuntimeRestartStabilityWindowNanos)
            guard let self else { return }
            guard self.proxyRuntimeRestartAttempts[configId] == attempt,
                  self.isProxyRunning(configId) else {
                return
            }
            self.proxyRuntimeRestartAttempts.removeValue(forKey: configId)
        }
    }

    /// fail-loud：自动重启耗尽后不再静默停用，而是保留激活态、标记 down，由管理页持久横幅
    /// 提示「本地代理未在运行」并提供手动重启（与 OpenCode 三轨对齐）。
    /// 不还原 settings.json/config.toml——它们仍指向本地端口，手动重启进程即可恢复，无需重新激活。
    private func markProxyRuntimeDown(_ config: ProxyConfiguration) {
        guard isNodeActivated(config.id) || !nodeRuntimeConsumers[config.id, default: []].isEmpty else { return }
        proxyRuntimeRestartAttempts.removeValue(forKey: config.id)
        proxyRuntimeDownConfigIds.insert(config.id)
        proxyRuntimeLog.error(
            "Proxy process for active node \(config.name, privacy: .public) keeps exiting; surfaced as down (manual restart required)"
        )
    }
}

extension ProxyViewModel {
    func parseProxyLog(_ jsonStr: String, configId: String) {
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String, type == "proxy_request_log" else {
            return
        }

        let upstreamModel = json["upstream_model"] as? String ?? "unknown"
        let tokensInput = json["input_tokens"] as? Int ?? 0
        let tokensOutput = json["output_tokens"] as? Int ?? 0

        // Prefer split cache fields; fall back to legacy combined `cache_tokens` (attribute to cache-read).
        let splitRead = json["cache_read_tokens"] as? Int
        let splitCreate = json["cache_creation_tokens"] as? Int
        let legacyCache = json["cache_tokens"] as? Int
        let tokensCacheRead: Int
        let tokensCacheCreation: Int
        if splitRead != nil || splitCreate != nil {
            tokensCacheRead = splitRead ?? 0
            tokensCacheCreation = splitCreate ?? 0
        } else {
            tokensCacheRead = legacyCache ?? 0
            tokensCacheCreation = 0
        }

        // 全局统一代理（Codex/Claude 轨）：一个进程随激活节点轮转，日志里带 node_id；优先按 node_id
        // 归因到当前节点，这样定价/统计落到真实节点上（缺省回退到进程的 configId，兼容每节点独立进程的旧路径）。
        // OpenCode 轨的全局日志不经此函数——它在 OpenCodeProxyRuntime 里按 OpenCode 节点定价单独归因。
        let effectiveConfigId = (json["node_id"] as? String)?.nilIfBlank ?? configId
        let config = configurations.first { $0.id == effectiveConfigId }

        let requestPath = config?.nodeType.isCodex == true ? "/v1/responses" : "/v1/messages"
        let pricing = config?.pricingForModel(upstreamModel)
        let estimatedCost = pricing?.costForTokens(
            input: tokensInput,
            output: tokensOutput,
            cacheRead: tokensCacheRead,
            cacheCreate: tokensCacheCreation
        ) ?? 0

        let log = ProxyRequestLog(
            configId: effectiveConfigId,
            method: "POST",
            path: requestPath,
            claudeModel: json["claude_model"] as? String ?? "unknown",
            upstreamModel: upstreamModel,
            success: json["success"] as? Bool ?? false,
            responseTimeMs: Double(json["response_time_ms"] as? Int ?? 0),
            firstTokenMs: (json["first_token_ms"] as? Int).map(Double.init),
            tokensInput: tokensInput,
            tokensOutput: tokensOutput,
            tokensCacheRead: tokensCacheRead,
            tokensCacheCreation: tokensCacheCreation,
            estimatedCostUSD: estimatedCost,
            pricingResolved: pricing != nil,
            errorMessage: json["error"] as? String,
            errorType: json["error_type"] as? String,
            statusCode: json["status_code"] as? Int,
            sessionId: (json["session_id"] as? String)?.nilIfBlank,
            conversationId: (json["conversation_id"] as? String)?.nilIfBlank,
            upstreamRequestId: (json["upstream_request_id"] as? String)?.nilIfBlank,
            clientSurface: (json["client_surface"] as? String)?.nilIfBlank
        )

        // parseProxyLog 本身已运行在 MainActor（pipe 回调经 Task { @MainActor } 跳转而来），
        // 直接记录即可，无需再经 DispatchQueue.main 多跳一次。
        recordRequest(log)
    }
}
