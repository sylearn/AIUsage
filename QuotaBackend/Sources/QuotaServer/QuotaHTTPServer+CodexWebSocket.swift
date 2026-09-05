import Foundation
import Network
import QuotaBackend

// MARK: - Codex Responses WebSocket

extension QuotaHTTPServer {
    func handleCodexWebSocketProxy(connection: NWConnection, request: HTTPRequest) async {
        guard let initialProxy = codexProxyService else {
            await rejectCodexWebSocket(connection, message: "Codex proxy is not enabled", status: 503)
            return
        }
        guard await initialProxy.authenticate(headers: request.headers) else {
            await rejectCodexWebSocket(connection, message: "Invalid API key", status: 401)
            return
        }
        if let validationError = QuotaWebSocket.validateUpgradeRequest(
            method: request.method,
            headers: request.headers
        ) {
            var headers = Self.corsHeaders
            headers["Sec-WebSocket-Version"] = "13"
            let response = codexErrorResponse(
                message: validationError,
                type: "invalid_request_error",
                status: 400,
                headers: headers
            )
            await sendResponse(connection, response: response)
            connection.cancel()
            return
        }

        let secKey = request.headers["sec-websocket-key"]!
        let ws = QuotaWebSocketConnection(connection: connection, initialBuffer: request.body)
        await ws.sendHandshake(
            acceptKey: QuotaWebSocket.acceptKey(for: secKey),
            extraHeaders: Self.corsHeaders
        )

        let scheduler = CodexWebSocketScheduler()
        let context = CodexWebSocketContextStore()
        while let message = await ws.readTextMessage() {
            let decoded: ([String: Any], String?)
            do {
                decoded = try Self.decodeCodexWebSocketEvent(message)
            } catch let error as CodexWebSocketRequestError {
                await sendCodexWebSocketError(ws: ws, streamID: nil, error: error)
                continue
            } catch {
                await sendCodexWebSocketError(
                    ws: ws,
                    streamID: nil,
                    error: .invalidRequest("Invalid WebSocket event")
                )
                continue
            }

            let (event, streamID) = decoded
            let enqueueResult = await scheduler.enqueue(streamID: streamID) { [weak self] in
                guard let self else { return }
                guard let proxy = self.codexProxyService else {
                    await self.sendCodexWebSocketError(
                        ws: ws,
                        streamID: streamID,
                        error: CodexWebSocketRequestError(
                            status: 503,
                            type: "api_error",
                            code: "proxy_unavailable",
                            message: "Codex proxy is not enabled"
                        )
                    )
                    return
                }
                await self.handleCodexWebSocketMessage(
                    proxy: proxy,
                    ws: ws,
                    context: context,
                    event: event,
                    streamID: streamID,
                    inboundHeaders: request.headers
                )
            }
            switch enqueueResult {
            case .accepted:
                break
            case .streamLimitReached:
                await sendCodexWebSocketError(
                    ws: ws,
                    streamID: streamID,
                    error: CodexWebSocketRequestError(
                        code: "websocket_stream_limit_reached",
                        message: "This WebSocket connection has reached its maximum number of distinct stream IDs.",
                        param: "stream_id"
                    )
                )
            case .queueLimitReached:
                await sendCodexWebSocketError(
                    ws: ws,
                    streamID: streamID,
                    error: CodexWebSocketRequestError(
                        code: "websocket_queue_limit_reached",
                        message: "This WebSocket connection has too many queued response.create events."
                    )
                )
            }
        }
        await scheduler.cancelAll()
        await ws.close()
    }

    private func rejectCodexWebSocket(_ connection: NWConnection, message: String, status: Int) async {
        let response = codexErrorResponse(
            message: message,
            type: status == 401 ? "authentication_error" : "api_error",
            status: status,
            headers: Self.corsHeaders
        )
        await sendResponse(connection, response: response)
        connection.cancel()
    }

    private func handleCodexWebSocketMessage(
        proxy: CodexProxyService,
        ws: QuotaWebSocketConnection,
        context: CodexWebSocketContextStore,
        event: [String: Any],
        streamID: String?,
        inboundHeaders: [String: String]
    ) async {
        let prepared: CodexWebSocketPreparedRequest
        do {
            prepared = try await context.prepare(
                event: event,
                routeOwner: proxy
            )
        } catch let error as CodexWebSocketRequestError {
            await sendCodexWebSocketError(ws: ws, streamID: streamID, error: error)
            return
        } catch {
            await sendCodexWebSocketError(
                ws: ws,
                streamID: streamID,
                error: .invalidRequest("Malformed response.create event")
            )
            return
        }

        if let warmupResponse = prepared.warmupResponse {
            await sendCodexWebSocketEvent(
                ws: ws,
                type: "response.created",
                response: warmupResponse.inProgress,
                sequenceNumber: 0,
                streamID: streamID
            )
            await sendCodexWebSocketEvent(
                ws: ws,
                type: "response.completed",
                response: warmupResponse.completed,
                sequenceNumber: 1,
                streamID: streamID
            )
            return
        }

        guard let body = prepared.httpBody else {
            await sendCodexWebSocketError(
                ws: ws,
                streamID: streamID,
                error: .invalidRequest("Malformed response.create event")
            )
            return
        }

        let requestModel = Self.peekModel(from: body)
        let requestIdentity = Self.codexRequestIdentity(from: inboundHeaders)
        let streamStartTime = Date()
        var firstTokenAt: Date?
        let usageRef = CodexWebSocketUsageRef()

        do {
            try await proxy.passthroughStreamingResponses(
                rawBody: body,
                inboundHeaders: inboundHeaders
            ) { _, frameData in
                try Task.checkCancellation()
                if frameData == "[DONE]" { return }
                if firstTokenAt == nil { firstTokenAt = Date() }
                if frameData.contains("\"usage\""),
                   let usage = CodexProxyService.parseUsage(fromStreamFrame: frameData) {
                    await usageRef.set(usage)
                }
                let outgoing = try Self.attachStreamID(streamID, to: frameData)
                if let response = outgoing.response, outgoing.type == "response.completed" {
                    await context.recordCompleted(response: response, for: prepared)
                }
                await ws.sendText(outgoing.text)
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
                nodeId: activeNodeId,
                sessionId: requestIdentity.sessionID,
                conversationId: requestIdentity.conversationID
            )
        } catch is CancellationError {
            return
        } catch {
            httpLog.error("  ✗ Codex WebSocket passthrough error: \(error.localizedDescription, privacy: .public)")
            let errorResult = await proxy.buildErrorResult(error: error)
            await sendCodexWebSocketError(
                ws: ws,
                streamID: streamID,
                error: CodexWebSocketRequestError(
                    status: errorResult.statusCode,
                    type: errorResult.response.error.type,
                    code: errorResult.response.error.code,
                    message: errorResult.response.error.message
                )
            )

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
                nodeId: activeNodeId,
                sessionId: requestIdentity.sessionID,
                conversationId: requestIdentity.conversationID,
                upstreamRequestId: errorResult.response.requestID
            )
        }
    }

    private static func decodeCodexWebSocketEvent(_ message: String) throws -> ([String: Any], String?) {
        guard let data = message.data(using: .utf8),
              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexWebSocketRequestError.invalidRequest("Invalid JSON frame")
        }
        guard event["type"] as? String == "response.create" else {
            throw CodexWebSocketRequestError(
                code: "invalid_event_type",
                message: "Only response.create events are supported.",
                param: "type"
            )
        }
        let streamID: String?
        if let rawStreamID = event["stream_id"] {
            guard let value = rawStreamID as? String, Self.isValidCodexStreamID(value) else {
                throw CodexWebSocketRequestError(
                    code: "invalid_stream_id",
                    message: "The 'stream_id' field must be 1-256 characters and contain only letters, numbers, underscores, hyphens, and periods.",
                    param: "stream_id"
                )
            }
            streamID = value
        } else {
            streamID = nil
        }
        return (event, streamID)
    }

    private static func isValidCodexStreamID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || $0 == 95 || $0 == 45 || $0 == 46
        }
    }

    private static func attachStreamID(
        _ streamID: String?,
        to frameData: String
    ) throws -> (text: String, type: String?, response: [String: Any]?) {
        guard let data = frameData.data(using: .utf8),
              var event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpstreamError.invalidResponse("Upstream emitted an invalid Responses event")
        }
        if let streamID {
            event["stream_id"] = streamID
        } else {
            event.removeValue(forKey: "stream_id")
        }
        let encoded = try JSONSerialization.data(withJSONObject: event)
        guard let text = String(data: encoded, encoding: .utf8) else {
            throw UpstreamError.invalidResponse("Upstream emitted a non-UTF-8 Responses event")
        }
        return (text, event["type"] as? String, event["response"] as? [String: Any])
    }

    private func sendCodexWebSocketEvent(
        ws: QuotaWebSocketConnection,
        type: String,
        response: [String: Any],
        sequenceNumber: Int,
        streamID: String?
    ) async {
        var event: [String: Any] = [
            "type": type,
            "sequence_number": sequenceNumber,
            "response": response,
        ]
        if let streamID { event["stream_id"] = streamID }
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        await ws.sendText(text)
    }

    private func sendCodexWebSocketError(
        ws: QuotaWebSocketConnection,
        streamID: String?,
        error: CodexWebSocketRequestError
    ) async {
        var detail: [String: Any] = [
            "type": error.type,
            "message": error.message,
        ]
        if let code = error.code { detail["code"] = code } else { detail["code"] = NSNull() }
        if let param = error.param { detail["param"] = param } else { detail["param"] = NSNull() }
        var body: [String: Any] = [
            "type": "error",
            "status": error.status,
            "error": detail,
        ]
        if let streamID { body["stream_id"] = streamID }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let text = String(data: data, encoding: .utf8) else { return }
        await ws.sendText(text)
    }
}

struct CodexWebSocketRequestError: Error {
    let status: Int
    let type: String
    let code: String?
    let message: String
    let param: String?

    init(
        status: Int = 400,
        type: String = "invalid_request_error",
        code: String? = nil,
        message: String,
        param: String? = nil
    ) {
        self.status = status
        self.type = type
        self.code = code
        self.message = message
        self.param = param
    }

    static func invalidRequest(_ message: String) -> Self {
        Self(message: message)
    }
}

struct CodexWebSocketPreparedRequest: @unchecked Sendable {
    struct WarmupResponse: @unchecked Sendable {
        let inProgress: [String: Any]
        let completed: [String: Any]
    }

    let httpBody: Data?
    let warmupResponse: WarmupResponse?
    let priorItems: [Any]
    let externalParentID: String?
    let inputItems: [Any]
    let warmupDefaults: [String: Any]?
    let routeIdentity: ObjectIdentifier?
}

actor CodexWebSocketContextStore {
    private struct Entry {
        let id: String
        let externalParentID: String?
        let contextItems: [Any]
        let warmupDefaults: [String: Any]?
        let routeIdentity: ObjectIdentifier?
        let estimatedBytes: Int
    }

    private static let syntheticPrefix = "resp_aiusage_"
    private static let maximumEntries = 128
    private static let maximumCacheBytes = 64 * 1_024 * 1_024

    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []
    private var cachedBytes = 0
    func prepare(
        event: [String: Any],
        routeOwner owner: AnyObject? = nil
    ) throws -> CodexWebSocketPreparedRequest {
        let routeIdentity = owner.map(ObjectIdentifier.init)

        var body = event
        body.removeValue(forKey: "type")
        body.removeValue(forKey: "stream_id")
        // HTTP-shaped clients (e.g. Codex CLI) may still send transport-specific fields.
        // WebSocket mode treats streaming as implicit; strip rather than fail the turn.
        body.removeValue(forKey: "stream")
        body.removeValue(forKey: "background")
        body.removeValue(forKey: "stream_options")
        let generate: Bool
        if let value = body.removeValue(forKey: "generate") {
            guard let boolValue = value as? Bool else {
                throw CodexWebSocketRequestError(
                    code: "invalid_type",
                    message: "'generate' must be a boolean.",
                    param: "generate"
                )
            }
            generate = boolValue
        } else {
            generate = true
        }
        let previousID: String?
        if let value = body["previous_response_id"], !(value is NSNull) {
            guard let stringValue = value as? String, !stringValue.isEmpty else {
                throw CodexWebSocketRequestError(
                    code: "invalid_type",
                    message: "'previous_response_id' must be a non-empty string or null.",
                    param: "previous_response_id"
                )
            }
            previousID = stringValue
        } else {
            previousID = nil
        }
        let inputItems = try Self.normalizedInputItems(body["input"])

        var priorItems: [Any] = []
        var externalParentID = previousID
        var inheritedDefaults: [String: Any]?
        if let previousID, let entry = entries[previousID] {
            priorItems = entry.contextItems
            // 上游 response id 只在创建它的节点内有效。切换节点后保留本地完整上下文，
            // 但去掉旧节点的 parent id，让新节点从展开后的 input 无缝继续。
            externalParentID = entry.routeIdentity == routeIdentity ? entry.externalParentID : nil
            inheritedDefaults = entry.warmupDefaults

            if let defaults = inheritedDefaults {
                var merged = defaults
                for (key, value) in body { merged[key] = value }
                body = merged
            }
            body["input"] = priorItems + inputItems
            if let externalParentID {
                body["previous_response_id"] = externalParentID
            } else {
                body.removeValue(forKey: "previous_response_id")
            }
        } else if let previousID, previousID.hasPrefix(Self.syntheticPrefix) {
            throw Self.previousResponseNotFound(previousID)
        }

        if !generate {
            var defaults = body
            defaults.removeValue(forKey: "input")
            defaults.removeValue(forKey: "previous_response_id")
            defaults.removeValue(forKey: "stream")

            let responseID = Self.syntheticPrefix + UUID().uuidString.lowercased()
            let contextItems = priorItems + inputItems
            let entry = Entry(
                id: responseID,
                externalParentID: externalParentID,
                contextItems: contextItems,
                warmupDefaults: defaults,
                routeIdentity: routeIdentity,
                estimatedBytes: Self.estimatedSize(contextItems) + Self.estimatedSize(defaults)
            )
            guard insert(entry) else {
                throw CodexWebSocketRequestError(
                    code: "context_length_exceeded",
                    message: "The warmup state exceeds the WebSocket connection cache limit."
                )
            }
            let response = Self.makeWarmupResponse(
                id: responseID,
                body: body,
                previousResponseID: previousID,
                status: "in_progress"
            )
            var completed = response
            completed["status"] = "completed"
            return CodexWebSocketPreparedRequest(
                httpBody: nil,
                warmupResponse: .init(inProgress: response, completed: completed),
                priorItems: priorItems,
                externalParentID: externalParentID,
                inputItems: inputItems,
                warmupDefaults: defaults,
                routeIdentity: routeIdentity
            )
        }

        var carriedDefaults: [String: Any]?
        if inheritedDefaults != nil {
            var defaults = body
            defaults.removeValue(forKey: "input")
            defaults.removeValue(forKey: "previous_response_id")
            defaults.removeValue(forKey: "stream")
            carriedDefaults = defaults
        }
        body["stream"] = true
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw CodexWebSocketRequestError.invalidRequest("Malformed response.create event")
        }
        guard data.count <= QuotaWebSocket.maxMessagePayloadBytes * 4 else {
            throw CodexWebSocketRequestError(
                code: "context_length_exceeded",
                message: "The expanded WebSocket conversation is too large."
            )
        }
        return CodexWebSocketPreparedRequest(
            httpBody: data,
            warmupResponse: nil,
            priorItems: priorItems,
            externalParentID: externalParentID,
            inputItems: inputItems,
            warmupDefaults: carriedDefaults,
            routeIdentity: routeIdentity
        )
    }

    func recordCompleted(response: [String: Any], for request: CodexWebSocketPreparedRequest) {
        guard let responseID = response["id"] as? String, !responseID.isEmpty else { return }
        let outputItems = response["output"] as? [Any] ?? []
        let contextItems = request.priorItems + request.inputItems + outputItems
        let entry = Entry(
            id: responseID,
            externalParentID: request.externalParentID,
            contextItems: contextItems,
            warmupDefaults: request.warmupDefaults,
            routeIdentity: request.routeIdentity,
            estimatedBytes: Self.estimatedSize(contextItems)
                + (request.warmupDefaults.map { Self.estimatedSize($0) } ?? 0)
        )
        _ = insert(entry)
    }

    private func insert(_ entry: Entry) -> Bool {
        guard entry.estimatedBytes <= Self.maximumCacheBytes else { return false }
        if let old = entries.removeValue(forKey: entry.id) {
            cachedBytes -= old.estimatedBytes
            insertionOrder.removeAll { $0 == entry.id }
        }
        while entries.count >= Self.maximumEntries
            || cachedBytes + entry.estimatedBytes > Self.maximumCacheBytes {
            guard let oldest = insertionOrder.first else { break }
            insertionOrder.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                cachedBytes -= removed.estimatedBytes
            }
        }
        entries[entry.id] = entry
        insertionOrder.append(entry.id)
        cachedBytes += entry.estimatedBytes
        return true
    }

    private static func normalizedInputItems(_ input: Any?) throws -> [Any] {
        if input == nil || input is NSNull { return [] }
        if let items = input as? [Any] { return items }
        if let text = input as? String {
            return [[
                "type": "message",
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": text,
                ]],
            ]]
        }
        throw CodexWebSocketRequestError(
            code: "invalid_type",
            message: "'input' must be a string or an array of input items.",
            param: "input"
        )
    }

    private static func estimatedSize(_ value: Any) -> Int {
        (try? JSONSerialization.data(withJSONObject: value).count) ?? Self.maximumCacheBytes + 1
    }

    private static func previousResponseNotFound(_ id: String) -> CodexWebSocketRequestError {
        CodexWebSocketRequestError(
            code: "previous_response_not_found",
            message: "Previous response with id '\(id)' was not found in this WebSocket connection.",
            param: "previous_response_id"
        )
    }

    private static func makeWarmupResponse(
        id: String,
        body: [String: Any],
        previousResponseID: String?,
        status: String
    ) -> [String: Any] {
        [
            "id": id,
            "object": "response",
            "created_at": Int(Date().timeIntervalSince1970),
            "status": status,
            "background": false,
            "error": NSNull(),
            "incomplete_details": NSNull(),
            "instructions": body["instructions"] ?? NSNull(),
            "max_output_tokens": body["max_output_tokens"] ?? NSNull(),
            "model": body["model"] ?? "",
            "output": [],
            "parallel_tool_calls": body["parallel_tool_calls"] ?? true,
            "previous_response_id": previousResponseID ?? NSNull(),
            "reasoning": body["reasoning"] ?? [:],
            "service_tier": body["service_tier"] ?? "auto",
            "store": body["store"] ?? true,
            "temperature": body["temperature"] ?? 1.0,
            "text": body["text"] ?? ["format": ["type": "text"]],
            "tool_choice": body["tool_choice"] ?? "auto",
            "tools": body["tools"] ?? [],
            "top_logprobs": body["top_logprobs"] ?? 0,
            "top_p": body["top_p"] ?? 1.0,
            "truncation": body["truncation"] ?? "disabled",
            "usage": NSNull(),
        ]
    }
}

private actor CodexWebSocketScheduler {
    enum EnqueueResult {
        case accepted
        case streamLimitReached
        case queueLimitReached
    }

    private struct Pending {
        let id: UUID
        let operation: () async -> Void
    }

    private static let defaultLane = "\0"
    private static let maximumNamedStreams = 32
    private static let maximumActiveResponses = 16
    private static let maximumQueuedResponses = 256

    private var namedStreams = Set<String>()
    private var laneOrder: [String] = []
    private var queues: [String: [Pending]] = [:]
    private var activeLanes = Set<String>()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func enqueue(streamID: String?, operation: @escaping () async -> Void) -> EnqueueResult {
        let queuedCount = queues.values.reduce(0) { $0 + $1.count }
        guard queuedCount < Self.maximumQueuedResponses else { return .queueLimitReached }
        if let streamID, namedStreams.insert(streamID).inserted,
           namedStreams.count > Self.maximumNamedStreams {
            namedStreams.remove(streamID)
            return .streamLimitReached
        }

        let lane = streamID ?? Self.defaultLane
        if queues[lane] == nil {
            queues[lane] = []
            laneOrder.append(lane)
        }
        queues[lane]?.append(Pending(id: UUID(), operation: operation))
        startAvailable()
        return .accepted
    }

    func cancelAll() {
        let running = Array(tasks.values)
        tasks.removeAll()
        queues.removeAll()
        laneOrder.removeAll()
        activeLanes.removeAll()
        running.forEach { $0.cancel() }
    }

    private func startAvailable() {
        while activeLanes.count < Self.maximumActiveResponses,
              let lane = laneOrder.first(where: {
                  !activeLanes.contains($0) && !(queues[$0]?.isEmpty ?? true)
              }),
              var queue = queues[lane], !queue.isEmpty {
            let pending = queue.removeFirst()
            queues[lane] = queue
            activeLanes.insert(lane)
            let task = Task {
                await pending.operation()
                self.finished(id: pending.id, lane: lane)
            }
            tasks[pending.id] = task
        }
    }

    private func finished(id: UUID, lane: String) {
        tasks.removeValue(forKey: id)
        activeLanes.remove(lane)
        startAvailable()
    }
}

private actor CodexWebSocketUsageRef {
    private var usage: CodexProxyService.PassthroughUsage?

    func set(_ value: CodexProxyService.PassthroughUsage) {
        usage = value
    }

    func get() -> CodexProxyService.PassthroughUsage? {
        usage
    }
}
