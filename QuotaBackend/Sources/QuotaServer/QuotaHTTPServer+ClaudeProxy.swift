import Foundation
import Network
import os.log
import QuotaBackend

extension QuotaHTTPServer {
    private static let filesAPIBeta = "files-api-2025-04-14"

    struct ParsedMultipartFileUpload {
        let filename: String
        let mimeType: String?
        let data: Data
    }

    func proxyErrorHTTPResponse(
        proxy: ClaudeProxyService,
        error: Error,
        headers: [String: String]
    ) async -> HTTPResponse {
        let errorResult = await proxy.buildErrorResult(error: error)
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

    // MARK: - Claude Proxy Handlers

    /// Local Anthropic Models API backed by the active AIUsage node catalog.
    /// It deliberately never reaches the upstream or returns credentials.
    func handleScienceModelsEndpoint(
        request: HTTPRequest,
        queryItems: [String: String],
        headers: [String: String]
    ) -> HTTPResponse {
        guard let config = proxyConfig, config.exposeScienceModelCatalog else {
            return jsonResponse(["error": "Not found"], status: 404, headers: headers)
        }

        guard authenticatedClaudeSurface(for: request) != nil else {
            return claudeErrorResponse(
                type: "authentication_error",
                message: "Invalid API key",
                status: 401,
                headers: headers
            )
        }

        let allModels = config.scienceCatalogModels
        var lowerBound = allModels.startIndex
        var upperBound = allModels.endIndex
        if let afterID = queryItems["after_id"],
           let index = allModels.firstIndex(where: { $0.id == afterID }) {
            lowerBound = allModels.index(after: index)
        }
        if let beforeID = queryItems["before_id"],
           let index = allModels.firstIndex(where: { $0.id == beforeID }) {
            upperBound = index
        }
        if lowerBound > upperBound { lowerBound = upperBound }
        let candidates = allModels[lowerBound..<upperBound]
        let requestedLimit = queryItems["limit"].flatMap(Int.init) ?? 1_000
        let limit = max(1, min(1_000, requestedLimit))
        let models = Array(candidates.prefix(limit))
        let data: [[String: Any]] = models.map { model in
            var row: [String: Any] = [
                "id": model.id,
                "type": "model",
                "display_name": model.displayName,
                "created_at": "1970-01-01T00:00:00Z",
            ]
            if model.supports1M { row["supports1m"] = true }
            return row
        }
        var payload: [String: Any] = [
            "data": data,
            "has_more": candidates.count > models.count,
        ]
        if let first = models.first?.id { payload["first_id"] = first }
        if let last = models.last?.id { payload["last_id"] = last }
        return jsonResponse(payload, headers: headers)
    }

    func handleEventLoggingEndpoint(request: HTTPRequest, headers: [String: String]) async -> HTTPResponse {
        httpLog.debug("→ POST /api/event_logging/batch (\(request.body.count) bytes)")

        // Telemetry 端点快速返回：不再全量解码 body（解码结果除 debug 日志外从未被使用），
        // 避免 Claude Code 的高频遥测批次与代理热路径争抢 CPU。端点永远回成功。
        let response = EventLoggingBatchResponse(
            success: true,
            batchId: UUID().uuidString,
            processedCount: 0,
            message: "Batch received"
        )

        return jsonResponse(encodable: response, headers: headers)
    }

    /// `claudeRequest` 可传入 `handleConnection` 已解码的请求体，避免大 body 重复解析；
    /// 为 nil 时（经通用路由进入）在认证后再解码一次。
    func handleMessagesEndpoint(
        request: HTTPRequest,
        claudeRequest decodedRequest: ClaudeMessageRequest? = nil,
        headers: [String: String]
    ) async -> HTTPResponse {
        guard let proxy = proxyService else {
            return claudeErrorResponse(
                type: "api_error",
                message: "Claude proxy is not enabled",
                status: 503,
                headers: headers
            )
        }

        // Authenticate
        guard authenticatedClaudeSurface(for: request) != nil else {
            return claudeErrorResponse(
                type: "authentication_error",
                message: "Invalid API key",
                status: 401,
                headers: headers
            )
        }

        // Parse request (reuse the pre-decoded body when available)
        let claudeRequest: ClaudeMessageRequest
        if let decodedRequest {
            claudeRequest = decodedRequest
        } else {
            do {
                claudeRequest = try Self.requestDecoder.decode(ClaudeMessageRequest.self, from: request.body)
            } catch {
                httpLog.error(
                    "Failed to parse Claude request body (\(request.body.count) bytes): \(Self.describeDecodingFailure(error), privacy: .public)"
                )
                return claudeErrorResponse(
                    type: "invalid_request_error",
                    message: "Failed to parse request body",
                    status: 400,
                    headers: headers
                )
            }
        }

        httpLog.debug("→ POST /v1/messages (model: \(claudeRequest.model), stream: \(claudeRequest.stream ?? false))")

        let startTime = Date()
        do {
            let response = try await proxy.handleMessages(request: claudeRequest)
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            let upstreamModel = await proxy.mapModel(claudeRequest.model)
            emitRequestLog(
                claudeModel: claudeRequest.model,
                upstreamModel: upstreamModel,
                success: true,
                responseTimeMs: elapsed,
                inputTokens: response.usage.inputTokens,
                outputTokens: response.usage.outputTokens,
                cacheCreationTokens: response.usage.cacheCreationInputTokens ?? 0,
                cacheReadTokens: response.usage.cacheReadInputTokens ?? 0,
                nodeId: activeNodeId,
                clientSurface: resolvedClaudeSurface(for: request)
            )
            return jsonResponse(encodable: response, headers: headers)
        } catch {
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            let upstreamModel = await proxy.mapModel(claudeRequest.model)
            let errorResult = await proxy.buildErrorResult(error: error)
            emitRequestLog(
                claudeModel: claudeRequest.model,
                upstreamModel: upstreamModel,
                success: false,
                responseTimeMs: elapsed,
                errorMessage: errorResult.response.error.message,
                errorType: errorResult.response.error.type,
                statusCode: errorResult.statusCode,
                nodeId: activeNodeId,
                clientSurface: resolvedClaudeSurface(for: request)
            )
            httpLog.error("  ✗ Proxy error: \(error.localizedDescription)")
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

    func handleCountTokensEndpoint(request: HTTPRequest, headers: [String: String]) async -> HTTPResponse {
        guard authenticatedClaudeSurface(for: request) != nil else {
            return claudeErrorResponse(
                type: "authentication_error",
                message: "Invalid API key",
                status: 401,
                headers: headers
            )
        }

        guard let tokenRequest = try? Self.requestDecoder.decode(ClaudeTokenCountRequest.self, from: request.body) else {
            return claudeErrorResponse(
                type: "invalid_request_error",
                message: "Failed to parse token count request body",
                status: 400,
                headers: headers
            )
        }

        httpLog.debug("→ POST /v1/messages/count_tokens (model: \(tokenRequest.model))")

        if let proxy = proxyService {
            do {
                let response = try await proxy.handleCountTokens(request: tokenRequest)
                return jsonResponse(encodable: response, headers: headers)
            } catch {
                return await proxyErrorHTTPResponse(proxy: proxy, error: error, headers: headers)
            }
        }

        // Passthrough mode fallback: local heuristic estimate (upstream does not support count_tokens)
        let estimated = estimateTokenCount(request: tokenRequest)
        return jsonResponse(encodable: ClaudeTokenCountResponse(inputTokens: estimated), headers: headers)
    }

    /// Local heuristic token estimate for passthrough mode where upstream
    /// does not support `/v1/messages/count_tokens`.
    /// Uses character-count / 4 approximation; not tokenizer-exact.
    /// Algorithm mirrors `ClaudeProxyService.handleCountTokens`.
    private func estimateTokenCount(request: ClaudeTokenCountRequest) -> Int {
        var totalChars = 0

        if let system = request.system {
            totalChars += system.count
        }
        if let systemBlocks = request.systemBlocks {
            for block in systemBlocks {
                totalChars += block.text?.count ?? 0
                totalChars += block.cacheControl == nil ? 0 : 20
            }
        }

        for message in request.messages {
            switch message.content {
            case .text(let text):
                totalChars += text.count
            case .blocks(let blocks):
                for block in blocks {
                    switch block {
                    case .text(let textBlock):
                        totalChars += textBlock.text.count
                    case .toolUse(let toolUse):
                        totalChars += toolUse.name.count
                        totalChars += 50
                    case .toolResult(let result):
                        totalChars += result.content?.count ?? 0
                        if let contentBlocks = result.contentBlocks {
                            for contentBlock in contentBlocks {
                                switch contentBlock {
                                case .image:
                                    totalChars += 4000
                                case .document:
                                    totalChars += 8000
                                case .thinking(let thinking):
                                    totalChars += thinking.thinking.count
                                case .redactedThinking:
                                    totalChars += 2000
                                case .text, .toolUse, .toolResult, .unknown:
                                    break
                                }
                            }
                        }
                    case .image:
                        totalChars += 4000
                    case .document:
                        totalChars += 8000
                    case .thinking(let thinking):
                        totalChars += thinking.thinking.count
                    case .redactedThinking:
                        totalChars += 2000
                    case .unknown:
                        totalChars += 100
                    }
                }
            }
        }

        if let tools = request.tools {
            for tool in tools {
                totalChars += tool.name.count
                totalChars += tool.description?.count ?? 0
                totalChars += 100
            }
        }

        return max(1, totalChars / 4)
    }

    func handleListFilesEndpoint(
        request: HTTPRequest,
        queryItems: [String: String],
        headers: [String: String]
    ) async -> HTTPResponse {
        guard let proxy = proxyService else {
            return claudeErrorResponse(
                type: "api_error",
                message: "Claude proxy is not enabled",
                status: 503,
                headers: headers
            )
        }

        guard authenticatedClaudeSurface(for: request) != nil else {
            return claudeErrorResponse(
                type: "authentication_error",
                message: "Invalid API key",
                status: 401,
                headers: headers
            )
        }

        if let validationError = validateFilesAPIHeaders(requestHeaders: request.headers, responseHeaders: headers) {
            return validationError
        }

        if queryItems["before_id"] != nil {
            return claudeErrorResponse(
                type: "invalid_request_error",
                message: "`before_id` is not supported by this OpenAI bridge. Use `after_id` for forward pagination.",
                status: 400,
                headers: headers
            )
        }

        let limit: Int?
        if let rawLimit = queryItems["limit"], !rawLimit.isEmpty {
            guard let parsedLimit = Int(rawLimit) else {
                return claudeErrorResponse(
                    type: "invalid_request_error",
                    message: "`limit` must be an integer.",
                    status: 400,
                    headers: headers
                )
            }
            limit = parsedLimit
        } else {
            limit = nil
        }

        do {
            let response = try await proxy.listFiles(limit: limit, afterID: queryItems["after_id"])
            return jsonResponse(encodable: response, headers: headers)
        } catch {
            return await proxyErrorHTTPResponse(proxy: proxy, error: error, headers: headers)
        }
    }

    func handleCreateFileEndpoint(request: HTTPRequest, headers: [String: String]) async -> HTTPResponse {
        guard let proxy = proxyService else {
            return claudeErrorResponse(
                type: "api_error",
                message: "Claude proxy is not enabled",
                status: 503,
                headers: headers
            )
        }

        guard authenticatedClaudeSurface(for: request) != nil else {
            return claudeErrorResponse(
                type: "authentication_error",
                message: "Invalid API key",
                status: 401,
                headers: headers
            )
        }

        if let validationError = validateFilesAPIHeaders(requestHeaders: request.headers, responseHeaders: headers) {
            return validationError
        }

        guard let upload = parseClaudeFilesMultipartUpload(
            body: request.body,
            contentTypeHeader: request.headers["content-type"]
        ) else {
            return claudeErrorResponse(
                type: "invalid_request_error",
                message: "Claude Files upload expects multipart/form-data with a single `file` part.",
                status: 400,
                headers: headers
            )
        }

        do {
            let response = try await proxy.createFile(
                filename: upload.filename,
                mimeType: upload.mimeType,
                data: upload.data
            )
            return jsonResponse(encodable: response, headers: headers)
        } catch {
            return await proxyErrorHTTPResponse(proxy: proxy, error: error, headers: headers)
        }
    }

    func handleFileSubresourceEndpoint(
        request: HTTPRequest,
        path: String,
        headers: [String: String]
    ) async -> HTTPResponse {
        guard let proxy = proxyService else {
            return claudeErrorResponse(
                type: "api_error",
                message: "Claude proxy is not enabled",
                status: 503,
                headers: headers
            )
        }

        guard authenticatedClaudeSurface(for: request) != nil else {
            return claudeErrorResponse(
                type: "authentication_error",
                message: "Invalid API key",
                status: 401,
                headers: headers
            )
        }

        if let validationError = validateFilesAPIHeaders(requestHeaders: request.headers, responseHeaders: headers) {
            return validationError
        }

        let filePath = String(path.dropFirst("/v1/files/".count))
        if filePath.hasSuffix("/content") {
            let fileID = String(filePath.dropLast("/content".count))
            do {
                let response = try await proxy.retrieveFileContent(fileID: fileID)
                var responseHeaders = headers
                responseHeaders["Content-Type"] = response.contentType ?? "application/octet-stream"
                responseHeaders["Content-Length"] = "\(response.data.count)"
                if let contentDisposition = response.contentDisposition {
                    responseHeaders["Content-Disposition"] = contentDisposition
                }
                return HTTPResponse(status: 200, headers: responseHeaders, bodyData: response.data)
            } catch {
                return await proxyErrorHTTPResponse(proxy: proxy, error: error, headers: headers)
            }
        }

        do {
            let response = try await proxy.retrieveFile(fileID: filePath)
            return jsonResponse(encodable: response, headers: headers)
        } catch {
            return await proxyErrorHTTPResponse(proxy: proxy, error: error, headers: headers)
        }
    }

    func handleDeleteFileEndpoint(
        request: HTTPRequest,
        path: String,
        headers: [String: String]
    ) async -> HTTPResponse {
        guard let proxy = proxyService else {
            return claudeErrorResponse(
                type: "api_error",
                message: "Claude proxy is not enabled",
                status: 503,
                headers: headers
            )
        }

        guard authenticatedClaudeSurface(for: request) != nil else {
            return claudeErrorResponse(
                type: "authentication_error",
                message: "Invalid API key",
                status: 401,
                headers: headers
            )
        }

        if let validationError = validateFilesAPIHeaders(requestHeaders: request.headers, responseHeaders: headers) {
            return validationError
        }

        let fileID = String(path.dropFirst("/v1/files/".count))

        do {
            let response = try await proxy.deleteFile(fileID: fileID)
            return jsonResponse(encodable: response, headers: headers)
        } catch {
            return await proxyErrorHTTPResponse(proxy: proxy, error: error, headers: headers)
        }
    }

    func validateFilesAPIHeaders(
        requestHeaders: [String: String],
        responseHeaders: [String: String]
    ) -> HTTPResponse? {
        let betas = parseAnthropicBetas(from: requestHeaders["anthropic-beta"])
        guard betas.contains(Self.filesAPIBeta) else {
            return claudeErrorResponse(
                type: "invalid_request_error",
                message: "Files API requires anthropic-beta: \(Self.filesAPIBeta)",
                status: 400,
                headers: responseHeaders
            )
        }
        return nil
    }

    func parseAnthropicBetas(from rawValue: String?) -> Set<String> {
        guard let rawValue, !rawValue.isEmpty else { return [] }
        return Set(
            rawValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    func parseClaudeFilesMultipartUpload(
        body: Data,
        contentTypeHeader: String?
    ) -> ParsedMultipartFileUpload? {
        guard let boundary = extractMultipartBoundary(from: contentTypeHeader) else {
            return nil
        }

        let openingBoundary = Data("--\(boundary)\r\n".utf8)
        guard body.starts(with: openingBoundary) else {
            return nil
        }

        let headerStart = openingBoundary.count
        let headerSeparator = Data([13, 10, 13, 10])
        guard let headerRange = body.range(of: headerSeparator, in: headerStart..<body.count) else {
            return nil
        }

        let headerData = Data(body[headerStart..<headerRange.lowerBound])
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        var partHeaders: [String: String] = [:]
        for line in headerText.components(separatedBy: "\r\n") {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            partHeaders[key] = value
        }

        guard let disposition = partHeaders["content-disposition"] else {
            return nil
        }
        let parameters = parseContentDispositionParameters(disposition)
        guard parameters["name"] == "file" else {
            return nil
        }

        let filename = parameters["filename"] ?? "upload.bin"
        let contentStart = headerRange.upperBound
        let closingBoundary = Data("\r\n--\(boundary)".utf8)
        guard let closingRange = body.range(of: closingBoundary, in: contentStart..<body.count) else {
            return nil
        }

        return ParsedMultipartFileUpload(
            filename: filename,
            mimeType: partHeaders["content-type"],
            data: Data(body[contentStart..<closingRange.lowerBound])
        )
    }

    func extractMultipartBoundary(from contentTypeHeader: String?) -> String? {
        guard let contentTypeHeader else { return nil }
        for segment in contentTypeHeader.split(separator: ";") {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("boundary=") else { continue }
            let rawBoundary = trimmed.dropFirst("boundary=".count)
            return rawBoundary.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    func parseContentDispositionParameters(_ headerValue: String) -> [String: String] {
        var parameters: [String: String] = [:]
        for component in headerValue.split(separator: ";").dropFirst() {
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            parameters[parts[0].lowercased()] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return parameters
    }

    /// `claudeRequest` 由 `handleConnection` 单次解码后传入，本方法不再重复解析请求体。
    func handleStreamingProxy(
        _ connection: NWConnection,
        request: HTTPRequest,
        claudeRequest: ClaudeMessageRequest
    ) async {
        guard let proxy = proxyService else {
            let response = claudeErrorResponse(
                type: "api_error",
                message: "Claude proxy is not enabled",
                status: 503,
                headers: [:]
            )
            await sendResponse(connection, response: response)
            connection.cancel()
            return
        }

        // Authenticate
        guard authenticatedClaudeSurface(for: request) != nil else {
            let response = claudeErrorResponse(
                type: "authentication_error",
                message: "Invalid API key",
                status: 401,
                headers: [:]
            )
            await sendResponse(connection, response: response)
            connection.cancel()
            return
        }

        httpLog.debug("→ POST /v1/messages (streaming, model: \(claudeRequest.model))")

        let streamStartTime = Date()
        var firstTokenAt: Date?
        let streamer = StreamingResponse(connection: connection)

        // Send SSE headers
        await streamer.sendHeaders(status: 200, headers: [
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "Access-Control-Allow-Origin": "*"
        ])

        do {
            let upstreamModel = await proxy.mapModel(claudeRequest.model)

            let encoder = Self.responseEncoder
            let messageID = "msg_\(UUID().uuidString.prefix(24))"
            var outputTokens = 0
            var reportedOutputTokens: Int?
            var reportedInputTokens: Int?
            var reportedCacheCreation: Int?
            var reportedCacheRead: Int?
            var hasAnyContentBlock = false
            var canonicalMapper = CanonicalOpenAIUpstreamStreamMapper()
            let canonicalBuilder = CanonicalClaudeStreamBuilder()

            func sendClaudeEvent(_ event: ClaudeStreamEvent) async throws {
                let eventName: String
                let json: String

                func encodeEventJSON<T: Encodable>(_ payload: T) throws -> String {
                    let data = try encoder.encode(payload)
                    guard let json = String(data: data, encoding: .utf8) else {
                        throw NSError(
                            domain: "QuotaHTTPServer",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to encode Claude SSE payload"]
                        )
                    }
                    return json
                }

                switch event {
                case .messageStart(let payload):
                    eventName = "message_start"
                    json = try encodeEventJSON(payload)

                case .contentBlockStart(let payload):
                    hasAnyContentBlock = true
                    eventName = "content_block_start"
                    json = try encodeEventJSON(payload)

                case .contentBlockDelta(let payload):
                    hasAnyContentBlock = true
                    eventName = "content_block_delta"
                    json = try encodeEventJSON(payload)

                case .contentBlockStop(let payload):
                    hasAnyContentBlock = true
                    eventName = "content_block_stop"
                    json = try encodeEventJSON(payload)

                case .messageDelta(let payload):
                    eventName = "message_delta"
                    json = try encodeEventJSON(payload)

                case .messageStop:
                    eventName = "message_stop"
                    json = "{\"type\":\"message_stop\"}"

                case .ping:
                    eventName = "ping"
                    json = "{\"type\":\"ping\"}"
                }
                await streamer.sendSSEEvent(event: eventName, data: json)
            }

            func sendEmptyTextLifecycleIfNeeded() async throws {
                guard !hasAnyContentBlock else { return }
                try await sendClaudeEvent(.contentBlockStart(ClaudeContentBlockStartEvent(
                    index: 0,
                    contentBlock: .text(ClaudeTextBlock(text: ""))
                )))
                try await sendClaudeEvent(.contentBlockStop(ClaudeContentBlockStopEvent(index: 0)))
            }

            try await proxy.sendStreamingClaudeRequest(claudeRequest) { upstreamEvent in
                // 首个上游分片到达即为首字时间（TTFT）。
                if firstTokenAt == nil { firstTokenAt = Date() }
                let canonicalEvents = canonicalMapper.map(upstreamEvent).map { event -> CanonicalStreamEvent in
                    guard case .messageStarted(let start) = event else { return event }
                    return .messageStarted(CanonicalStreamMessageStarted(
                        role: start.role,
                        messageID: messageID,
                        model: claudeRequest.model,
                        rawExtensions: start.rawExtensions
                    ))
                }

                for canonicalEvent in canonicalEvents {
                    if case .contentPartDelta(let delta) = canonicalEvent,
                       let textDelta = delta.textDelta,
                       !textDelta.isEmpty {
                        outputTokens += max(1, textDelta.count / 4)
                    }

                    if case .messageDelta(let delta) = canonicalEvent, let usage = delta.usage {
                        reportedInputTokens = usage.inputTokens ?? reportedInputTokens
                        reportedCacheCreation = usage.cacheCreationInputTokens ?? reportedCacheCreation
                        reportedCacheRead = usage.cacheReadInputTokens ?? reportedCacheRead
                    }

                    let claudeEvents = canonicalBuilder.build(event: canonicalEvent)
                    for claudeEvent in claudeEvents {
                        if case .messageDelta(let payload) = claudeEvent {
                            try await sendEmptyTextLifecycleIfNeeded()
                            reportedOutputTokens = payload.usage.outputTokens
                        }
                        try await sendClaudeEvent(claudeEvent)
                    }
                }
            }

            let elapsed = Date().timeIntervalSince(streamStartTime) * 1000
            let firstTokenMs = firstTokenAt.map { $0.timeIntervalSince(streamStartTime) * 1000 }
            let finalOutputTokens = max(1, reportedOutputTokens ?? outputTokens)
            emitRequestLog(
                claudeModel: claudeRequest.model,
                upstreamModel: upstreamModel,
                success: true,
                responseTimeMs: elapsed,
                firstTokenMs: firstTokenMs,
                inputTokens: reportedInputTokens ?? 0,
                outputTokens: finalOutputTokens,
                cacheCreationTokens: reportedCacheCreation ?? 0,
                cacheReadTokens: reportedCacheRead ?? 0,
                nodeId: activeNodeId,
                clientSurface: resolvedClaudeSurface(for: request)
            )

        } catch {
            httpLog.error("  ✗ Streaming proxy error: \(error.localizedDescription)")
            let errorResult = await proxy.buildErrorResult(error: error)
            let errMsg = """
            {"type":"error","error":{"type":\(escapeJSON(errorResult.response.error.type)),"message":\(escapeJSON(errorResult.response.error.message))}\(errorResult.response.requestID.map { ",\"request_id\":\(escapeJSON($0))" } ?? "")}
            """
            await streamer.sendSSEEvent(event: "error", data: errMsg)

            let elapsed = Date().timeIntervalSince(streamStartTime) * 1000
            let firstTokenMs = firstTokenAt.map { $0.timeIntervalSince(streamStartTime) * 1000 }
            let errUpstreamModel = await proxy.mapModel(claudeRequest.model)
            emitRequestLog(
                claudeModel: claudeRequest.model,
                upstreamModel: errUpstreamModel,
                success: false,
                responseTimeMs: elapsed,
                firstTokenMs: firstTokenMs,
                errorMessage: errorResult.response.error.message,
                errorType: errorResult.response.error.type,
                statusCode: errorResult.statusCode,
                nodeId: activeNodeId,
                clientSurface: resolvedClaudeSurface(for: request)
            )
        }

        await streamer.finish()
    }

    func emitRequestLog(
        claudeModel: String,
        upstreamModel: String,
        success: Bool,
        responseTimeMs: Double,
        firstTokenMs: Double? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        errorMessage: String? = nil,
        errorType: String? = nil,
        statusCode: Int? = nil,
        nodeId: String? = nil,
        sessionId: String? = nil,
        conversationId: String? = nil,
        upstreamRequestId: String? = nil,
        clientSurface: ClaudeClientSurface = .unknown
    ) {
        var parts = [
            "\"type\":\"proxy_request_log\"",
            "\"claude_model\":\(escapeJSON(claudeModel))",
            "\"upstream_model\":\(escapeJSON(upstreamModel))",
            "\"success\":\(success)",
            "\"response_time_ms\":\(Int(responseTimeMs))",
            "\"input_tokens\":\(inputTokens)",
            "\"output_tokens\":\(outputTokens)",
            "\"cache_creation_tokens\":\(cacheCreationTokens)",
            "\"cache_read_tokens\":\(cacheReadTokens)",
            "\"cache_tokens\":\(cacheCreationTokens + cacheReadTokens)"
        ]
        if let firstTokenMs {
            parts.append("\"first_token_ms\":\(Int(firstTokenMs))")
        }
        if let err = errorMessage {
            parts.append("\"error\":\(escapeJSON(err))")
        }
        if let errType = errorType {
            parts.append("\"error_type\":\(escapeJSON(errType))")
        }
        if let code = statusCode {
            parts.append("\"status_code\":\(code)")
        }
        // 全局统一代理：一个进程随激活节点轮转服务多个节点，按 node_id 把日志归因到当前节点
        // （宿主 App 解析时优先用 node_id 而非进程 configId）。
        if let nodeId, !nodeId.isEmpty {
            parts.append("\"node_id\":\(escapeJSON(nodeId))")
        }
        if let sessionId, !sessionId.isEmpty {
            parts.append("\"session_id\":\(escapeJSON(sessionId))")
        }
        if let conversationId, !conversationId.isEmpty {
            parts.append("\"conversation_id\":\(escapeJSON(conversationId))")
        }
        if let upstreamRequestId, !upstreamRequestId.isEmpty {
            parts.append("\"upstream_request_id\":\(escapeJSON(upstreamRequestId))")
        }
        parts.append("\"client_surface\":\(escapeJSON(clientSurface.rawValue))")
        // stdout is parsed by the macOS host app for structured log ingestion
        print("PROXY_LOG:{\(parts.joined(separator: ","))}")
    }
}
