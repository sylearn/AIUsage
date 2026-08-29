import Foundation
import Network
import os.log
import QuotaBackend

extension QuotaHTTPServer {
    // MARK: - Anthropic Passthrough Proxy

    func handlePassthroughProxy(_ connection: NWConnection, request: HTTPRequest) async {
        guard let config = proxyConfig else {
            let resp = HTTPResponse(status: 502, headers: [:], body: "{\"error\":\"Passthrough not configured\"}")
            await sendResponse(connection, response: resp)
            connection.cancel()
            return
        }

        guard config.authenticatedSurface(
            headers: request.headers,
            hintedSurface: request.clientSurface
        ) != nil else {
            let resp = claudeErrorResponse(type: "authentication_error", message: "Invalid API key", status: 401, headers: [:])
            await sendResponse(connection, response: resp)
            connection.cancel()
            return
        }

        let startTime = Date()
        let cleanPath = request.path.split(separator: "?").first.map(String.init) ?? request.path
        let queryPart = request.path.contains("?") ? "?" + request.path.split(separator: "?").dropFirst().joined(separator: "?") : ""
        let upstreamURL = config.upstreamBaseURL.hasSuffix("/")
            ? config.upstreamBaseURL + String(cleanPath.dropFirst()) + queryPart
            : config.upstreamBaseURL + cleanPath + queryPart

        httpLog.debug("→ PASSTHROUGH \(request.method) \(request.path, privacy: .public) → \(upstreamURL, privacy: .private)")

        guard let url = URL(string: upstreamURL) else {
            let resp = HTTPResponse(status: 502, headers: [:], body: "{\"error\":\"Invalid upstream URL\"}")
            await sendResponse(connection, response: resp)
            connection.cancel()
            return
        }

        var mutableBody = request.body
        let mutableHeaders = request.headers

        // Strict passthrough: forward cache_control, system-in-messages,
        // thinking blocks, and tool schemas unchanged. The only body rewrite
        // is a stable `model` alias / forced-model swap, which is not part of
        // the Anthropic prompt-cache prefix (tools → system → messages).
        var isStreaming = false
        var requestModel = "unknown"
        var upstreamModel = "unknown"
        if var json = try? JSONSerialization.jsonObject(with: mutableBody) as? [String: Any] {
            isStreaming = json["stream"] as? Bool ?? false
            requestModel = json["model"] as? String ?? "unknown"
            upstreamModel = requestModel
            var bodyModified = false

            // 全局统一代理（OpenCode anthropic 接口）：CLI 固定发虚拟模型名，按激活节点真实模型无条件改写，
            // 优先于三层别名映射。
            if let forced = config.forcedModel, forced != requestModel {
                upstreamModel = forced
                json["model"] = forced
                bodyModified = true
            } else if config.enableModelAliasMapping, requestModel != "unknown" {
                let mapped = config.mapToUpstreamModel(requestModel)
                if mapped != requestModel {
                    upstreamModel = mapped
                    json["model"] = mapped
                    bodyModified = true
                }
            } else if !config.availableModels.contains(requestModel) {
                // Even strict passthrough has to drop a `[1m]` suffix: Anthropic
                // gates 1M context on `anthropic-beta` (added below) and treats
                // the bracketed id as an unknown model. Catalogs that publish a
                // literal `…[1m]` name are matched above and left alone.
                let base = ClaudeContext1M.baseModel(requestModel)
                if base != requestModel {
                    upstreamModel = base
                    json["model"] = base
                    bodyModified = true
                }
            }

            if bodyModified, let rewritten = try? JSONSerialization.data(withJSONObject: json) {
                mutableBody = rewritten
            }
        }

        var upstreamReq = URLRequest(url: url)
        upstreamReq.httpMethod = request.method
        upstreamReq.httpBody = mutableBody

        let suppressedRequestHeaders: Set<String> = [
            "host", "content-length",
            "accept-encoding",
        ]

        for (key, value) in mutableHeaders {
            let lk = key.lowercased()
            if suppressedRequestHeaders.contains(lk) { continue }
            if lk == "authorization" && !config.upstreamAPIKey.isEmpty { continue }
            upstreamReq.setValue(value, forHTTPHeaderField: key)
        }
        if !config.upstreamAPIKey.isEmpty {
            upstreamReq.setValue(config.upstreamAPIKey, forHTTPHeaderField: "x-api-key")
        }
        if mutableHeaders["content-type"] == nil {
            upstreamReq.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        // A `[1m]` model selection is how the client asks for 1M context; upstream
        // only honours it as a beta. Merge so the client's own betas survive.
        if ClaudeContext1M.requestsVariant(requestModel) {
            upstreamReq.setValue(
                ClaudeContext1M.mergingBeta(into: mutableHeaders["anthropic-beta"]),
                forHTTPHeaderField: "anthropic-beta"
            )
        }

        if isStreaming {
            await handlePassthroughStreaming(
                connection,
                upstreamRequest: upstreamReq,
                requestModel: requestModel,
                upstreamModel: upstreamModel,
                clientSurface: resolvedClaudeSurface(for: request),
                startTime: startTime
            )
        } else {
            await handlePassthroughNonStreaming(
                connection,
                upstreamRequest: upstreamReq,
                requestModel: requestModel,
                upstreamModel: upstreamModel,
                clientSurface: resolvedClaudeSurface(for: request),
                startTime: startTime
            )
        }
    }

    private static let suppressedResponseHeaders: Set<String> = [
        "content-length", "transfer-encoding", "content-encoding",
    ]

    func handlePassthroughNonStreaming(
        _ connection: NWConnection,
        upstreamRequest: URLRequest,
        requestModel: String,
        upstreamModel: String,
        clientSurface: ClaudeClientSurface,
        startTime: Date
    ) async {
        do {
            let (data, response) = try await URLSession.shared.data(for: upstreamRequest)
            let httpResp = response as? HTTPURLResponse
            let statusCode = httpResp?.statusCode ?? 502

            var respHeaders: [String: String] = ["Content-Type": "application/json"]
            httpResp?.allHeaderFields.forEach { key, value in
                if let k = key as? String, let v = value as? String {
                    let lk = k.lowercased()
                    if !Self.suppressedResponseHeaders.contains(lk) {
                        respHeaders[k] = v
                    }
                }
            }
            respHeaders["Content-Length"] = "\(data.count)"

            let elapsed = Date().timeIntervalSince(startTime) * 1000
            let isSuccess = statusCode < 400
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            var usage = json?["usage"] as? [String: Any] ?? [:]

            if isSuccess {
                // 与流式路径一致的宽容化 + 兜底：上游漏发 usage 时用请求体字符数估算 input、
                // 用响应 content 字符数估算 output。input 兜底要先排除「全命中缓存
                // 导致 input_tokens 真值就是 0」的情况——有 cache 字段就别动 input。
                let normalizedInput = Self.coerceInt(usage["input_tokens"]) ?? 0
                let normalizedOutput = Self.coerceInt(usage["output_tokens"]) ?? 0
                let normalizedCacheRead = Self.coerceInt(usage["cache_read_input_tokens"]) ?? 0
                let normalizedCacheWrite = Self.coerceInt(usage["cache_creation_input_tokens"]) ?? 0

                if normalizedInput == 0, normalizedCacheRead == 0, normalizedCacheWrite == 0 {
                    usage["input_tokens"] = Self.estimateAnthropicInputTokens(fromRequestBody: upstreamRequest.httpBody)
                } else {
                    usage["input_tokens"] = normalizedInput
                }
                if normalizedOutput == 0 {
                    let chars = Self.estimateAnthropicOutputChars(fromResponseJSON: json)
                    usage["output_tokens"] = chars > 0 ? max(1, chars / 4) : 0
                } else {
                    usage["output_tokens"] = normalizedOutput
                }
                usage["cache_read_input_tokens"] = normalizedCacheRead
                usage["cache_creation_input_tokens"] = normalizedCacheWrite
            }

            var errorType: String?
            var errorMessage: String?
            if !isSuccess {
                if let errorObj = json?["error"] as? [String: Any] {
                    errorType = errorObj["type"] as? String
                    errorMessage = errorObj["message"] as? String
                }
                if errorType == nil {
                    errorType = passthroughErrorType(forHTTPStatus: statusCode)
                }
                if errorMessage == nil {
                    errorMessage = json?["message"] as? String ?? "HTTP \(statusCode)"
                }
            }

            emitPassthroughLog(
                model: requestModel,
                upstreamModel: upstreamModel,
                usage: usage,
                responseTimeMs: Int(elapsed),
                success: isSuccess,
                errorType: errorType,
                errorMessage: errorMessage,
                statusCode: !isSuccess ? statusCode : nil,
                clientSurface: clientSurface
            )

            let resp = HTTPResponse(status: statusCode, headers: respHeaders, bodyData: data)
            await sendResponse(connection, response: resp)
            connection.cancel()
        } catch {
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            emitPassthroughLog(
                model: requestModel,
                upstreamModel: upstreamModel,
                usage: [:],
                responseTimeMs: Int(elapsed),
                success: false,
                errorType: "network_error",
                errorMessage: error.localizedDescription,
                statusCode: nil,
                clientSurface: clientSurface
            )
            let escaped = escapeJSON("Upstream error: \(error.localizedDescription)")
            let resp = HTTPResponse(status: 502, headers: ["Content-Type": "application/json"], body: "{\"error\":\(escaped)}")
            await sendResponse(connection, response: resp)
            connection.cancel()
        }
    }

    private static let suppressedStreamingResponseHeaders: Set<String> = [
        "content-length", "transfer-encoding", "connection", "content-encoding",
    ]

    func handlePassthroughStreaming(
        _ connection: NWConnection,
        upstreamRequest: URLRequest,
        requestModel: String,
        upstreamModel: String,
        clientSurface: ClaudeClientSurface,
        startTime: Date
    ) async {
        let streamer = StreamingResponse(connection: connection)
        var firstTokenAt: Date?

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: upstreamRequest)
            let httpResp = response as? HTTPURLResponse
            let statusCode = httpResp?.statusCode ?? 502

            var respHeaders: [String: String] = [
                "Cache-Control": "no-cache",
                "Connection": "close",
            ]
            httpResp?.allHeaderFields.forEach { key, value in
                guard let k = key as? String, let v = value as? String else { return }
                let lk = k.lowercased()
                if !Self.suppressedStreamingResponseHeaders.contains(lk) {
                    respHeaders[k] = v
                }
            }
            if respHeaders["Content-Type"] == nil && respHeaders["content-type"] == nil {
                respHeaders["Content-Type"] = "text/event-stream"
            }
            await streamer.sendHeaders(status: statusCode, headers: respHeaders)

            var totalInputTokens = 0
            var totalOutputTokens = 0
            var cacheCreationTokens = 0
            var cacheReadTokens = 0
            // 兜底估算：当上游漏发 usage（Kimi Coding/Anthropic-compat 在中断或不带缓存的
            // 短回合里很常见）时，用「请求体字符数」估 input、用「累计 delta 字符数」估 output，
            // 避免明细行恒显 0/0。估算用 chars/4 的传统启发式，仅当上游真实数据缺失时才介入。
            var assistantDeltaChars = 0
            var lineBuffer = Data()

            func processUsageLine(_ line: String) {
                // W3C SSE 规范里 `data:` 后面的空格是可选的；Kimi Coding 的 Anthropic-compat
                // 端点固定发的就是 `data:{...}`（无空格），原先 hasPrefix("data: ") 直接全部丢弃，
                // 导致 passthrough 路径下 Kimi 的 usage 一次都抓不到，明细行恒显 0/0。
                // 现在统一通过定位第一个 `{` 来抠 JSON，兼容有空格 / 没空格两种格式。
                guard line.hasPrefix("data:"), let jsonStart = line.firstIndex(of: Character("{")) else {
                    return
                }
                // 廉价子串预过滤：只有可能携带 usage 或参与 output 兜底估算
                // （content_block_delta）的事件才值得做 JSON 解析；
                // ping / content_block_start / message_stop 等高频帧直接跳过。
                guard line.contains("\"usage\"") || line.contains("content_block_delta") else {
                    return
                }
                let jsonStr = String(line[jsonStart...])
                guard let eventData = try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8)) as? [String: Any] else {
                    return
                }

                // 累计输出 delta（content_block_delta.delta.{text|partial_json|thinking}），
                // 用作上游漏发 message_delta.usage 时的 output 兜底估算。
                if let type = eventData["type"] as? String, type == "content_block_delta",
                   let delta = eventData["delta"] as? [String: Any] {
                    if let text = delta["text"] as? String { assistantDeltaChars += text.count }
                    if let partial = delta["partial_json"] as? String { assistantDeltaChars += partial.count }
                    if let thinking = delta["thinking"] as? String { assistantDeltaChars += thinking.count }
                }

                let usage: [String: Any]
                if let u = eventData["usage"] as? [String: Any] {
                    usage = u
                } else if let message = eventData["message"] as? [String: Any],
                          let u = message["usage"] as? [String: Any] {
                    usage = u
                } else {
                    return
                }

                if let v = Self.coerceInt(usage["input_tokens"]), v > 0 { totalInputTokens = v }
                if let v = Self.coerceInt(usage["output_tokens"]), v > 0 { totalOutputTokens = v }
                if let v = Self.coerceInt(usage["cache_creation_input_tokens"]), v > 0 { cacheCreationTokens = v }
                if let v = Self.coerceInt(usage["cache_read_input_tokens"]), v > 0 { cacheReadTokens = v }
            }

            for try await byte in bytes {
                // 首个上游字节到达即为首字时间（TTFT）。
                if firstTokenAt == nil { firstTokenAt = Date() }
                lineBuffer.append(byte)

                if byte == 0x0A {
                    var trimmed = lineBuffer
                    if trimmed.last == 0x0A { trimmed.removeLast() }
                    if trimmed.last == 0x0D { trimmed.removeLast() }
                    let line = String(decoding: trimmed, as: UTF8.self)
                    processUsageLine(line)

                    await streamer.sendDataChunk(lineBuffer)
                    lineBuffer.removeAll(keepingCapacity: true)
                }
            }

            if !lineBuffer.isEmpty {
                let trailingLine = String(decoding: lineBuffer, as: UTF8.self)
                processUsageLine(trailingLine)
                await streamer.sendDataChunk(lineBuffer)
            }

            // 上游真没给就用估算补上，至少让明细行不再恒 0/0。
            // - input：只有在「连 cache 字段都没拿到」时才估算，否则可能是「全命中缓存
            //   导致 input_tokens 真值就是 0」（Anthropic 语义），不能被估算覆盖成几 K。
            // - output：上游没给且本地累计的 content delta 也为空时才填 0；
            //   只要有 delta 文本就用 chars/4 当下界。
            if totalInputTokens == 0, cacheReadTokens == 0, cacheCreationTokens == 0 {
                totalInputTokens = Self.estimateAnthropicInputTokens(fromRequestBody: upstreamRequest.httpBody)
            }
            if totalOutputTokens == 0, assistantDeltaChars > 0 {
                totalOutputTokens = max(1, assistantDeltaChars / 4)
            }

            let elapsed = Date().timeIntervalSince(startTime) * 1000
            let firstTokenMs = firstTokenAt.map { Int($0.timeIntervalSince(startTime) * 1000) }
            let isSuccess = statusCode < 400
            let usageDict: [String: Any] = [
                "input_tokens": totalInputTokens,
                "output_tokens": totalOutputTokens,
                "cache_creation_input_tokens": cacheCreationTokens,
                "cache_read_input_tokens": cacheReadTokens
            ]
            emitPassthroughLog(
                model: requestModel,
                upstreamModel: upstreamModel,
                usage: usageDict,
                responseTimeMs: Int(elapsed),
                firstTokenMs: firstTokenMs,
                success: isSuccess,
                errorType: !isSuccess ? passthroughErrorType(forHTTPStatus: statusCode) : nil,
                errorMessage: !isSuccess ? "HTTP \(statusCode)" : nil,
                statusCode: !isSuccess ? statusCode : nil,
                clientSurface: clientSurface
            )

            await streamer.finish()
        } catch {
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            let firstTokenMs = firstTokenAt.map { Int($0.timeIntervalSince(startTime) * 1000) }
            emitPassthroughLog(
                model: requestModel,
                upstreamModel: upstreamModel,
                usage: [:],
                responseTimeMs: Int(elapsed),
                firstTokenMs: firstTokenMs,
                success: false,
                errorType: "network_error",
                errorMessage: error.localizedDescription,
                statusCode: nil,
                clientSurface: clientSurface
            )
            let escaped = escapeJSON(error.localizedDescription)
            await streamer.sendChunk("event: error\ndata: {\"error\":\(escaped)}\n\n")
            await streamer.finish()
        }
    }

    func forwardPassthrough(request: HTTPRequest, path: String) async -> HTTPResponse {
        guard let config = proxyConfig else {
            return HTTPResponse(status: 502, headers: [:], body: "{\"error\":\"Not configured\"}")
        }

        let upstreamURL = config.upstreamBaseURL.hasSuffix("/")
            ? config.upstreamBaseURL + String(path.dropFirst())
            : config.upstreamBaseURL + path

        guard let url = URL(string: upstreamURL) else {
            return HTTPResponse(status: 502, headers: [:], body: "{\"error\":\"Invalid URL\"}")
        }

        var upstreamReq = URLRequest(url: url)
        upstreamReq.httpMethod = request.method
        upstreamReq.httpBody = request.body
        for (key, value) in request.headers {
            let lk = key.lowercased()
            if lk == "host" || lk == "content-length" { continue }
            if lk == "authorization" && !config.upstreamAPIKey.isEmpty { continue }
            upstreamReq.setValue(value, forHTTPHeaderField: key)
        }
        if !config.upstreamAPIKey.isEmpty {
            upstreamReq.setValue(config.upstreamAPIKey, forHTTPHeaderField: "x-api-key")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: upstreamReq)
            let httpResp = response as? HTTPURLResponse
            return HTTPResponse(
                status: httpResp?.statusCode ?? 502,
                headers: ["Content-Type": "application/json"],
                bodyData: data
            )
        } catch {
            let escaped = escapeJSON(error.localizedDescription)
            return HTTPResponse(status: 502, headers: ["Content-Type": "application/json"], body: "{\"error\":\(escaped)}")
        }
    }

    func emitPassthroughLog(
        model: String,
        upstreamModel: String? = nil,
        usage: [String: Any],
        responseTimeMs: Int,
        firstTokenMs: Int? = nil,
        success: Bool,
        errorType: String? = nil,
        errorMessage: String? = nil,
        statusCode: Int? = nil,
        clientSurface: ClaudeClientSurface = .unknown
    ) {
        let inputTokens = usage["input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0

        var log: [String: Any] = [
            "type": "proxy_request_log",
            "claude_model": model,
            "upstream_model": upstreamModel ?? model,
            "success": success,
            "response_time_ms": responseTimeMs,
            "input_tokens": inputTokens,
            "output_tokens": outputTokens,
            "cache_creation_tokens": cacheCreation,
            "cache_read_tokens": cacheRead,
            "cache_tokens": cacheCreation + cacheRead,
            "client_surface": clientSurface.rawValue,
        ]
        if let firstTokenMs { log["first_token_ms"] = firstTokenMs }
        if let errorType { log["error_type"] = errorType }
        if let errorMessage { log["error"] = errorMessage }
        if let statusCode { log["status_code"] = statusCode }
        // 全局统一代理：一个进程随激活节点轮转服务多个节点，按 node_id 把日志归因到当前节点。
        if let nodeId = activeNodeId, !nodeId.isEmpty { log["node_id"] = nodeId }

        if let data = try? JSONSerialization.data(withJSONObject: log),
           let jsonStr = String(data: data, encoding: .utf8) {
            // stdout is parsed by the macOS host app for structured log ingestion
            print("PROXY_LOG:\(jsonStr)")
        }
    }

    func passthroughErrorType(forHTTPStatus statusCode: Int) -> String {
        switch statusCode {
        case 400: return "invalid_request_error"
        case 401: return "authentication_error"
        case 402: return "billing_error"
        case 403: return "permission_error"
        case 404: return "not_found_error"
        case 413: return "request_too_large"
        case 429: return "rate_limit_error"
        case 504: return "timeout_error"
        case 529: return "overloaded_error"
        case 400..<500: return "invalid_request_error"
        default: return "api_error"
        }
    }

    // MARK: - Usage Coercion & Estimation Fallbacks

    /// 把 `Any?` 形态的 token 字段安全转回 Int。
    /// 不少「Anthropic 兼容」上游（包括 Kimi Coding 在内）会把 token 数写成
    /// 浮点或字符串，直接 `as? Int` 失败就丢字段；用一组兜底转换把这种 case 拉回来。
    static func coerceInt(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String, let i = Int(s) { return i }
        if let s = value as? String, let d = Double(s) { return Int(d) }
        return nil
    }

    /// 用请求体里的 `system + messages + tools` 字符数粗估 input tokens。
    /// 仅用于上游漏发 `usage.input_tokens` 的兜底，避免明细行显示 0/0。
    /// 字符数除以 4 是经典启发式，准度有限但是个有意义的下界。
    static func estimateAnthropicInputTokens(fromRequestBody body: Data?) -> Int {
        guard let body, !body.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return 0
        }
        var chars = 0
        if let system = json["system"] as? String {
            chars += system.count
        } else if let systemBlocks = json["system"] as? [[String: Any]] {
            for block in systemBlocks {
                if let t = block["text"] as? String { chars += t.count }
            }
        }
        if let messages = json["messages"] as? [[String: Any]] {
            for message in messages {
                chars += countAnthropicContentChars(message["content"])
            }
        }
        if let tools = json["tools"] as? [[String: Any]] {
            for tool in tools {
                if let name = tool["name"] as? String { chars += name.count }
                if let desc = tool["description"] as? String { chars += desc.count }
                // tool input schema 经常比较大，给个估算下限免得低估太狠
                chars += 100
            }
        }
        return chars > 0 ? max(1, chars / 4) : 0
    }

    /// 非流式响应里，把 assistant content 的字符数加起来做 output 估算。
    static func estimateAnthropicOutputChars(fromResponseJSON json: [String: Any]?) -> Int {
        guard let json,
              let content = json["content"] as? [[String: Any]] else { return 0 }
        var chars = 0
        for block in content {
            if let text = block["text"] as? String { chars += text.count }
            if let thinking = block["thinking"] as? String { chars += thinking.count }
            if let input = block["input"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: input) {
                chars += data.count
            }
        }
        return chars
    }

    private static func countAnthropicContentChars(_ content: Any?) -> Int {
        if let text = content as? String { return text.count }
        guard let blocks = content as? [[String: Any]] else { return 0 }
        var chars = 0
        for block in blocks {
            if let t = block["text"] as? String { chars += t.count }
            if let c = block["content"] as? String { chars += c.count }
            if let nested = block["content"] as? [[String: Any]] {
                for inner in nested {
                    if let t = inner["text"] as? String { chars += t.count }
                }
            }
            if let input = block["input"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: input) {
                chars += data.count
            }
        }
        return chars
    }
}
