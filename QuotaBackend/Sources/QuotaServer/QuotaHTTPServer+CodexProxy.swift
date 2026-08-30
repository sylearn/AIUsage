import Foundation
import Network
import os.log
import QuotaBackend

// MARK: - Codex Proxy HTTP Handlers
// 服务 OpenAI Responses 入站端点 `/v1/responses`（流式与非流式），转发到 OpenAI 兼容上游。
// 与 Claude 的 `/v1/messages` 处理逻辑保持一致的结构与日志格式。

extension QuotaHTTPServer {
    func codexErrorResponse(
        message: String,
        type: String,
        status: Int,
        headers: [String: String]
    ) -> HTTPResponse {
        let errorJSON = "{\"error\":{\"type\":\(escapeJSON(type)),\"message\":\(escapeJSON(message))}}"
        var responseHeaders = headers
        responseHeaders["Content-Type"] = "application/json"
        responseHeaders["Content-Length"] = "\(errorJSON.utf8.count)"
        return HTTPResponse(status: status, headers: responseHeaders, body: errorJSON)
    }

    // MARK: - Non-Streaming

    func handleCodexResponsesEndpoint(request: HTTPRequest, headers: [String: String]) async -> HTTPResponse {
        guard let proxy = codexProxyService else {
            return codexErrorResponse(
                message: "Codex proxy is not enabled",
                type: "api_error",
                status: 503,
                headers: headers
            )
        }

        guard await proxy.authenticate(headers: request.headers) else {
            return codexErrorResponse(
                message: "Invalid API key",
                type: "authentication_error",
                status: 401,
                headers: headers
            )
        }

        // Codex 恒走忠实透传（代理对 Codex 透明 = 直连）。
        return await handleCodexResponsesPassthrough(proxy: proxy, request: request, headers: headers)
    }

    // MARK: - Models (passthrough)

    /// `GET /v1/models`：Codex 启动时刷新可用模型列表。忠实透传上游结果，避免 404 报错。
    func handleCodexModelsEndpoint(request: HTTPRequest, headers: [String: String]) async -> HTTPResponse {
        guard let proxy = codexProxyService else {
            return codexErrorResponse(
                message: "Codex proxy is not enabled",
                type: "api_error",
                status: 503,
                headers: headers
            )
        }

        guard await proxy.authenticate(headers: request.headers) else {
            return codexErrorResponse(
                message: "Invalid API key",
                type: "authentication_error",
                status: 401,
                headers: headers
            )
        }

        do {
            let result = try await proxy.passthroughModels(inboundHeaders: request.headers)
            var responseHeaders = headers
            responseHeaders["Content-Type"] = "application/json"
            responseHeaders["Content-Length"] = "\(result.data.count)"
            if let requestID = result.requestID, !requestID.isEmpty {
                responseHeaders["request-id"] = requestID
            }
            return HTTPResponse(status: result.statusCode, headers: responseHeaders, bodyData: result.data)
        } catch {
            httpLog.error("  ✗ Codex models passthrough error: \(error.localizedDescription)")
            let errorResult = await proxy.buildErrorResult(error: error)
            return jsonResponse(
                encodable: errorResult.response,
                status: errorResult.statusCode,
                headers: headers
            )
        }
    }

    // MARK: - Streaming

    func handleCodexStreamingProxy(_ connection: NWConnection, request: HTTPRequest) async {
        guard let proxy = codexProxyService else {
            let response = codexErrorResponse(
                message: "Codex proxy is not enabled",
                type: "api_error",
                status: 503,
                headers: [:]
            )
            await sendResponse(connection, response: response)
            connection.cancel()
            return
        }

        guard await proxy.authenticate(headers: request.headers) else {
            let response = codexErrorResponse(
                message: "Invalid API key",
                type: "authentication_error",
                status: 401,
                headers: [:]
            )
            await sendResponse(connection, response: response)
            connection.cancel()
            return
        }

        // Codex 恒走忠实透传 SSE（逐帧原样回传）。
        await handleCodexStreamingPassthrough(proxy: proxy, connection: connection, request: request)
    }

    // MARK: - Passthrough Handlers

    /// 非流式忠实透传：原样转发请求体，回传上游原始状态码 + 响应体。
    private func handleCodexResponsesPassthrough(
        proxy: CodexProxyService,
        request: HTTPRequest,
        headers: [String: String]
    ) async -> HTTPResponse {
        let requestModel = Self.peekModel(from: request.body)
        let startTime = Date()
        do {
            let result = try await proxy.passthroughResponses(rawBody: request.body, inboundHeaders: request.headers)
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            let upstreamModel = await proxy.mapModel(requestModel)

            if (200..<300).contains(result.statusCode) {
                emitRequestLog(
                    claudeModel: requestModel,
                    upstreamModel: upstreamModel,
                    success: true,
                    responseTimeMs: elapsed,
                    inputTokens: result.usage?.inputTokens ?? 0,
                    outputTokens: result.usage?.outputTokens ?? 0,
                    cacheCreationTokens: 0,
                    cacheReadTokens: result.usage?.cachedTokens ?? 0,
                    nodeId: activeNodeId
                )
            } else {
                let bodyText = String(data: result.data, encoding: .utf8) ?? ""
                emitRequestLog(
                    claudeModel: requestModel,
                    upstreamModel: upstreamModel,
                    success: false,
                    responseTimeMs: elapsed,
                    errorMessage: String(bodyText.prefix(500)),
                    errorType: "upstream_error",
                    statusCode: result.statusCode,
                    nodeId: activeNodeId
                )
            }

            var responseHeaders = headers
            responseHeaders["Content-Type"] = "application/json"
            responseHeaders["Content-Length"] = "\(result.data.count)"
            if let requestID = result.requestID, !requestID.isEmpty {
                responseHeaders["request-id"] = requestID
            }
            return HTTPResponse(status: result.statusCode, headers: responseHeaders, bodyData: result.data)
        } catch {
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            let upstreamModel = await proxy.mapModel(requestModel)
            let errorResult = await proxy.buildErrorResult(error: error)
            emitRequestLog(
                claudeModel: requestModel,
                upstreamModel: upstreamModel,
                success: false,
                responseTimeMs: elapsed,
                errorMessage: errorResult.response.error.message,
                errorType: errorResult.response.error.type,
                statusCode: errorResult.statusCode,
                nodeId: activeNodeId
            )
            httpLog.error("  ✗ Codex passthrough error: \(error.localizedDescription)")
            var responseHeaders = headers
            if let requestID = errorResult.response.requestID, !requestID.isEmpty {
                responseHeaders["request-id"] = requestID
            }
            return jsonResponse(
                encodable: errorResult.response,
                status: errorResult.statusCode,
                headers: responseHeaders
            )
        }
    }

    /// 流式忠实透传：把上游 SSE 帧原样回传给 Codex，旁路解析 usage 做统计。
    private func handleCodexStreamingPassthrough(
        proxy: CodexProxyService,
        connection: NWConnection,
        request: HTTPRequest
    ) async {
        let requestModel = Self.peekModel(from: request.body)
        let streamStartTime = Date()
        var firstTokenAt: Date?
        let streamer = StreamingResponse(connection: connection)
        await streamer.sendHeaders(status: 200, headers: [
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "Access-Control-Allow-Origin": "*"
        ])

        let usageRef = CodexPassthroughUsageRef()
        do {
            try await proxy.passthroughStreamingResponses(
                rawBody: request.body,
                inboundHeaders: request.headers
            ) { event, data in
                // 首个上游帧到达即为首字时间（TTFT）。
                if firstTokenAt == nil { firstTokenAt = Date() }
                // usage 仅出现在 response.completed 帧；用廉价子串判定避免对每个 delta 帧做 JSON 解析。
                if data.contains("\"usage\""), let usage = CodexProxyService.parseUsage(fromStreamFrame: data) {
                    await usageRef.set(usage)
                }
                await streamer.sendSSEEvent(event: event, data: data)
            }

            let elapsed = Date().timeIntervalSince(streamStartTime) * 1000
            let firstTokenMs = firstTokenAt.map { $0.timeIntervalSince(streamStartTime) * 1000 }
            let upstreamModel = await proxy.mapModel(requestModel)
            let usage = await usageRef.get()
            emitRequestLog(
                claudeModel: requestModel,
                upstreamModel: upstreamModel,
                success: true,
                responseTimeMs: elapsed,
                firstTokenMs: firstTokenMs,
                inputTokens: usage?.inputTokens ?? 0,
                outputTokens: usage?.outputTokens ?? 0,
                cacheCreationTokens: 0,
                cacheReadTokens: usage?.cachedTokens ?? 0,
                nodeId: activeNodeId
            )
        } catch {
            httpLog.error("  ✗ Codex streaming passthrough error: \(error.localizedDescription)")
            let errorResult = await proxy.buildErrorResult(error: error)
            let errMsg = """
            {"type":"response.failed","response":{"error":{"type":\(escapeJSON(errorResult.response.error.type)),"message":\(escapeJSON(errorResult.response.error.message))}}}
            """
            await streamer.sendSSEEvent(event: "response.failed", data: errMsg)

            let elapsed = Date().timeIntervalSince(streamStartTime) * 1000
            let firstTokenMs = firstTokenAt.map { $0.timeIntervalSince(streamStartTime) * 1000 }
            let upstreamModel = await proxy.mapModel(requestModel)
            emitRequestLog(
                claudeModel: requestModel,
                upstreamModel: upstreamModel,
                success: false,
                responseTimeMs: elapsed,
                firstTokenMs: firstTokenMs,
                errorMessage: errorResult.response.error.message,
                errorType: errorResult.response.error.type,
                statusCode: errorResult.statusCode,
                nodeId: activeNodeId
            )
        }

        await streamer.finish()
    }

    /// 仅探测顶层 `model` 字段的轻量解码目标（避免对大 body 做 JSONSerialization 全量建图）。
    private struct ModelProbe: Decodable {
        let model: String?
    }

    /// 从原始请求体中安全读取 model（仅用于日志/映射展示）。
    static func peekModel(from body: Data) -> String {
        guard let model = (try? requestDecoder.decode(ModelProbe.self, from: body))?.model,
              !model.isEmpty else {
            return "unknown"
        }
        return model
    }
}

/// 流式透传期间累计 usage 的线程安全容器。
private actor CodexPassthroughUsageRef {
    private var usage: CodexProxyService.PassthroughUsage?

    func set(_ value: CodexProxyService.PassthroughUsage) {
        usage = value
    }

    func get() -> CodexProxyService.PassthroughUsage? {
        usage
    }
}
