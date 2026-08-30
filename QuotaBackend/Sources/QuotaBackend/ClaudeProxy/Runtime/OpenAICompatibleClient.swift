import Foundation
import os.log

private let upstreamLog = Logger(subsystem: "com.aiusage.quotaserver", category: "Upstream")

// MARK: - OpenAI-Compatible HTTP Client

public actor OpenAICompatibleClient {
    private static let jsonDecoder = JSONDecoder()
    // 不启用 sortedKeys：上游请求体（长会话 messages/input）可达数 MB，
    // 全键排序只增加 CPU 与分配成本，对上游语义无影响。
    private static let jsonEncoder = JSONEncoder()

    private let configuration: ClaudeProxyConfiguration
    private let session: URLSession

    public init(configuration: ClaudeProxyConfiguration) {
        self.configuration = configuration
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = configuration.requestTimeout
        sessionConfig.timeoutIntervalForResource = configuration.requestTimeout * 2
        self.session = URLSession(configuration: sessionConfig)
    }

    // MARK: - Non-Streaming Request

    public func sendChatCompletion(
        request: OpenAIChatCompletionRequest
    ) async throws -> OpenAIChatCompletionResponse {
        guard configuration.openAIUpstreamAPI == .chatCompletions else {
            throw UpstreamError.invalidResponse(
                "sendChatCompletion requires .chatCompletions upstream; use sendResponses for .responses"
            )
        }
        return try await sendChatCompletionViaChatCompletions(
            request: request,
            allowRetryWithoutMaxTokens: true
        )
    }

    public func sendResponses(
        request: OpenAIResponsesRequest
    ) async throws -> OpenAIResponsesResponse {
        try await sendResponsesRequest(
            request: request,
            allowRetryWithoutMaxTokens: true
        )
    }

    // MARK: - Streaming Request

    public func streamCompletion(
        request: OpenAIChatCompletionRequest,
        onEvent: @escaping (OpenAIUpstreamStreamEvent) async throws -> Void
    ) async throws {
        guard configuration.openAIUpstreamAPI == .chatCompletions else {
            throw UpstreamError.invalidResponse(
                "streamCompletion requires .chatCompletions upstream; use streamResponses for .responses"
            )
        }
        try await streamViaChatCompletions(
            request: request,
            allowRetryWithoutMaxTokens: true,
            onEvent: onEvent
        )
    }

    public func streamResponses(
        request: OpenAIResponsesRequest,
        onEvent: @escaping (OpenAIUpstreamStreamEvent) async throws -> Void
    ) async throws {
        try await streamResponsesRequest(
            request: request,
            allowRetryWithoutMaxTokens: true,
            onEvent: onEvent
        )
    }

    public func listFiles(limit: Int?, after: String?) async throws -> OpenAIFileListResponse {
        var queryItems: [URLQueryItem] = []
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let after, !after.isEmpty {
            queryItems.append(URLQueryItem(name: "after", value: after))
        }

        let request = try makeUpstreamRequest(path: "/files", method: "GET", queryItems: queryItems)
        let (data, response) = try await session.data(for: request)
        return try decodeUpstreamJSONResponse(OpenAIFileListResponse.self, from: data, response: response)
    }

    public func retrieveFile(fileID: String) async throws -> OpenAIFileObject {
        let request = try makeUpstreamRequest(path: "/files/\(fileID)", method: "GET")
        let (data, response) = try await session.data(for: request)
        return try decodeUpstreamJSONResponse(OpenAIFileObject.self, from: data, response: response)
    }

    public func deleteFile(fileID: String) async throws -> OpenAIDeletedFileResponse {
        let request = try makeUpstreamRequest(path: "/files/\(fileID)", method: "DELETE")
        let (data, response) = try await session.data(for: request)
        return try decodeUpstreamJSONResponse(OpenAIDeletedFileResponse.self, from: data, response: response)
    }

    public func uploadFile(
        filename: String,
        mimeType: String?,
        data: Data,
        purpose: String = "user_data"
    ) async throws -> OpenAIFileObject {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = try makeUpstreamRequest(
            path: "/files",
            method: "POST",
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
        request.httpBody = buildMultipartFileUploadBody(
            filename: filename,
            mimeType: mimeType,
            fileData: data,
            purpose: purpose,
            boundary: boundary
        )
        let (responseData, response) = try await session.data(for: request)
        return try decodeUpstreamJSONResponse(OpenAIFileObject.self, from: responseData, response: response)
    }

    public func retrieveFileContent(fileID: String) async throws -> OpenAIFileContentResponse {
        let request = try makeUpstreamRequest(path: "/files/\(fileID)/content", method: "GET")
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpstreamError.invalidResponse("Not an HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            upstreamLog.warning("Upstream \(httpResponse.statusCode): \(String(errorBody.prefix(500)), privacy: .private)")
            throw UpstreamError.httpError(
                statusCode: httpResponse.statusCode,
                message: errorBody,
                requestID: upstreamRequestID(from: httpResponse)
            )
        }

        return OpenAIFileContentResponse(
            data: data,
            contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
            contentDisposition: httpResponse.value(forHTTPHeaderField: "Content-Disposition")
        )
    }

    // MARK: - Chat Completions

    private func sendChatCompletionViaChatCompletions(
        request: OpenAIChatCompletionRequest,
        allowRetryWithoutMaxTokens: Bool
    ) async throws -> OpenAIChatCompletionResponse {
        let nonStreamRequest = OpenAIChatCompletionRequest(
            model: request.model,
            messages: request.messages,
            temperature: request.temperature,
            topP: request.topP,
            maxTokens: request.maxTokens,
            stop: request.stop,
            stream: false,
            tools: request.tools,
            toolChoice: request.toolChoice,
            parallelToolCalls: request.parallelToolCalls
        )

        let urlRequest = try makeJSONRequest(path: "/chat/completions", body: nonStreamRequest)
        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpstreamError.invalidResponse("Not an HTTP response")
        }

        if httpResponse.statusCode == 200 {
            if let result = try? Self.jsonDecoder.decode(OpenAIChatCompletionResponse.self, from: data) {
                return result
            }
            if let body = String(data: data, encoding: .utf8), body.contains("data: ") {
                return try assembleChatCompletionFromSSE(body: body)
            }
            let body = String(data: data, encoding: .utf8) ?? "Unable to read response"
            throw UpstreamError.decodingFailed("Failed to decode upstream response. Body: \(body)")
        }

        let errorBody = String(data: data, encoding: .utf8) ?? ""
        upstreamLog.warning("Upstream \(httpResponse.statusCode): \(String(errorBody.prefix(500)), privacy: .private)")

        if allowRetryWithoutMaxTokens, nonStreamRequest.maxTokens != nil, shouldRetryWithoutMaxTokens(errorBody) {
            upstreamLog.info("Retrying chat/completions without max_tokens")
            let retryRequest = OpenAIChatCompletionRequest(
                model: request.model,
                messages: request.messages,
                temperature: request.temperature,
                topP: request.topP,
                maxTokens: nil,
                stop: request.stop,
                stream: false,
                tools: request.tools,
                toolChoice: request.toolChoice,
                parallelToolCalls: request.parallelToolCalls
            )
            return try await sendChatCompletionViaChatCompletions(
                request: retryRequest,
                allowRetryWithoutMaxTokens: false
            )
        }

        throw UpstreamError.httpError(
            statusCode: httpResponse.statusCode,
            message: errorBody,
            requestID: upstreamRequestID(from: httpResponse)
        )
    }

    private func streamViaChatCompletions(
        request: OpenAIChatCompletionRequest,
        allowRetryWithoutMaxTokens: Bool,
        onEvent: @escaping (OpenAIUpstreamStreamEvent) async throws -> Void
    ) async throws {
        let streamRequest = OpenAIChatCompletionRequest(
            model: request.model,
            messages: request.messages,
            temperature: request.temperature,
            topP: request.topP,
            maxTokens: request.maxTokens,
            stop: request.stop,
            stream: true,
            streamOptions: .init(includeUsage: true),
            tools: request.tools,
            toolChoice: request.toolChoice,
            parallelToolCalls: request.parallelToolCalls
        )

        let urlRequest = try makeJSONRequest(path: "/chat/completions", body: streamRequest)
        let (bytes, response) = try await session.bytes(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpstreamError.invalidResponse("Not an HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = try await readUTF8TextPrefix(from: bytes, maxBytes: 4096)
            upstreamLog.warning("Upstream streaming \(httpResponse.statusCode): \(String(errorBody.prefix(500)), privacy: .private)")

            if allowRetryWithoutMaxTokens, streamRequest.maxTokens != nil, shouldRetryWithoutMaxTokens(errorBody) {
                upstreamLog.info("Retrying streaming chat/completions without max_tokens")
                let retryRequest = OpenAIChatCompletionRequest(
                    model: request.model,
                    messages: request.messages,
                    temperature: request.temperature,
                    topP: request.topP,
                    maxTokens: nil,
                    stop: request.stop,
                    stream: true,
                    streamOptions: .init(includeUsage: true),
                    tools: request.tools,
                    toolChoice: request.toolChoice,
                    parallelToolCalls: request.parallelToolCalls
                )
                try await streamViaChatCompletions(
                    request: retryRequest,
                    allowRetryWithoutMaxTokens: false,
                    onEvent: onEvent
                )
                return
            }

            throw UpstreamError.httpError(
                statusCode: httpResponse.statusCode,
                message: errorBody.isEmpty ? "Upstream returned status \(httpResponse.statusCode)" : errorBody,
                requestID: upstreamRequestID(from: httpResponse)
            )
        }

        let decoder = Self.jsonDecoder
        var startedToolIndices = Set<Int>()
        var finishReason: String?
        var capturedUsage: OpenAIUsage?

        try await consumeSSEPayloads(from: bytes) { payload in
            if payload == "[DONE]" { return }

            guard let data = payload.data(using: .utf8),
                  let chunk = try? decoder.decode(OpenAIStreamChunk.self, from: data) else {
                return
            }

            if let usage = chunk.usage {
                capturedUsage = usage
            }
            // Moonshot/Kimi 把 usage 嵌在 choice 里（非 OpenAI 标准位置），这里兜底捞起来，
            // 否则代理日志里 Kimi 上游的 input/output/cache token 全是 0。
            // 顶层 chunk.usage 优先（OpenAI 标准、字段更完整含 prompt_tokens_details），
            // 仅在顶层缺失时才用 choice.usage 兜底（Kimi/Moonshot 路径）。
            if capturedUsage == nil,
               let choiceUsage = chunk.choices.first(where: { $0.usage != nil })?.usage {
                capturedUsage = choiceUsage
            }

            guard let choice = chunk.choices.first else { return }

            if let reasoning = choice.delta.reasoningContent, !reasoning.isEmpty {
                try await onEvent(.reasoningSummaryDelta(reasoning))
            }

            if let content = choice.delta.content, !content.isEmpty {
                try await onEvent(.textDelta(content))
            }

            if let toolCalls = choice.delta.toolCalls {
                for toolCall in toolCalls {
                    if let id = toolCall.id,
                       let name = toolCall.function?.name,
                       !startedToolIndices.contains(toolCall.index) {
                        startedToolIndices.insert(toolCall.index)
                        try await onEvent(.toolCallStarted(index: toolCall.index, id: id, name: name))
                    }

                    if let arguments = toolCall.function?.arguments, !arguments.isEmpty {
                        try await onEvent(.toolCallArgumentsDelta(index: toolCall.index, argumentsDelta: arguments))
                    }
                }
            }

            if let chunkFinishReason = choice.finishReason {
                finishReason = chunkFinishReason
            }
        }

        try await onEvent(.completed(finishReason: finishReason, usage: capturedUsage))
    }

    // MARK: - Responses API

    private func sendResponsesRequest(
        request: OpenAIResponsesRequest,
        allowRetryWithoutMaxTokens: Bool
    ) async throws -> OpenAIResponsesResponse {
        let urlRequest = try makeJSONRequest(path: "/responses", body: request)
        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpstreamError.invalidResponse("Not an HTTP response")
        }

        if httpResponse.statusCode == 200 {
            return try decodeResponsesResponse(data)
        }

        let errorBody = String(data: data, encoding: .utf8) ?? ""
        upstreamLog.warning("Upstream \(httpResponse.statusCode): \(String(errorBody.prefix(500)), privacy: .private)")

        if allowRetryWithoutMaxTokens, request.maxOutputTokens != nil, shouldRetryWithoutMaxTokens(errorBody) {
            upstreamLog.info("Retrying responses without max_output_tokens")
            let retryRequest = OpenAIResponsesRequest(
                model: request.model,
                input: request.input,
                temperature: request.temperature,
                topP: request.topP,
                maxOutputTokens: nil,
                stream: request.stream,
                store: request.store,
                tools: request.tools,
                toolChoice: request.toolChoice,
                parallelToolCalls: request.parallelToolCalls
            )
            return try await sendResponsesRequest(
                request: retryRequest,
                allowRetryWithoutMaxTokens: false
            )
        }

        throw UpstreamError.httpError(
            statusCode: httpResponse.statusCode,
            message: errorBody,
            requestID: upstreamRequestID(from: httpResponse)
        )
    }

    private func streamResponsesRequest(
        request: OpenAIResponsesRequest,
        allowRetryWithoutMaxTokens: Bool,
        onEvent: @escaping (OpenAIUpstreamStreamEvent) async throws -> Void
    ) async throws {
        let urlRequest = try makeJSONRequest(path: "/responses", body: request)
        let (bytes, response) = try await session.bytes(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpstreamError.invalidResponse("Not an HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = try await readUTF8TextPrefix(from: bytes, maxBytes: 4096)
            upstreamLog.warning("Upstream streaming \(httpResponse.statusCode): \(String(errorBody.prefix(500)), privacy: .private)")

            if allowRetryWithoutMaxTokens, request.maxOutputTokens != nil, shouldRetryWithoutMaxTokens(errorBody) {
                upstreamLog.info("Retrying streaming responses without max_output_tokens")
                let retryRequest = OpenAIResponsesRequest(
                    model: request.model,
                    input: request.input,
                    temperature: request.temperature,
                    topP: request.topP,
                    maxOutputTokens: nil,
                    stream: request.stream,
                    store: request.store,
                    tools: request.tools,
                    toolChoice: request.toolChoice,
                    parallelToolCalls: request.parallelToolCalls
                )
                try await streamResponsesRequest(
                    request: retryRequest,
                    allowRetryWithoutMaxTokens: false,
                    onEvent: onEvent
                )
                return
            }

            throw UpstreamError.httpError(
                statusCode: httpResponse.statusCode,
                message: errorBody.isEmpty ? "Upstream returned status \(httpResponse.statusCode)" : errorBody,
                requestID: upstreamRequestID(from: httpResponse)
            )
        }

        let decoder = Self.jsonDecoder
        var startedToolIndices = Set<Int>()
        var accumulatedArgumentsByIndex: [Int: String] = [:]
        var toolOrdinalsByOutputIndex: [Int: Int] = [:]
        var nextToolOrdinal = 0
        var emittedReasoningText = ""
        var emittedCompletion = false

        try await consumeSSEPayloads(from: bytes) { payload in
            if payload == "[DONE]" { return }
            guard let data = payload.data(using: .utf8),
                  let envelope = try? decoder.decode(OpenAIResponsesStreamEnvelope.self, from: data) else {
                return
            }

            switch envelope.type {
            case "response.output_item.added":
                guard let event = try? decoder.decode(OpenAIResponsesOutputItemAddedEvent.self, from: data) else {
                    return
                }
                let upstreamEvents = self.makeResponsesToolEvents(
                    from: event.item,
                    outputIndex: event.outputIndex,
                    toolOrdinalsByOutputIndex: &toolOrdinalsByOutputIndex,
                    nextToolOrdinal: &nextToolOrdinal,
                    startedToolIndices: &startedToolIndices,
                    accumulatedArgumentsByIndex: &accumulatedArgumentsByIndex,
                    emittedReasoningText: &emittedReasoningText
                )
                for upstreamEvent in upstreamEvents {
                    try await onEvent(upstreamEvent)
                }

            case "response.output_item.done":
                guard let event = try? decoder.decode(OpenAIResponsesOutputItemDoneEvent.self, from: data) else {
                    return
                }
                let upstreamEvents = self.makeResponsesToolEvents(
                    from: event.item,
                    outputIndex: event.outputIndex,
                    toolOrdinalsByOutputIndex: &toolOrdinalsByOutputIndex,
                    nextToolOrdinal: &nextToolOrdinal,
                    startedToolIndices: &startedToolIndices,
                    accumulatedArgumentsByIndex: &accumulatedArgumentsByIndex,
                    emittedReasoningText: &emittedReasoningText
                )
                for upstreamEvent in upstreamEvents {
                    try await onEvent(upstreamEvent)
                }

            case "response.output_text.delta":
                guard let event = try? decoder.decode(OpenAIResponsesOutputTextDeltaEvent.self, from: data),
                      !event.delta.isEmpty else {
                    return
                }
                try await onEvent(.textDelta(event.delta))

            case "response.reasoning_summary_text.delta":
                guard let event = try? decoder.decode(OpenAIResponsesReasoningSummaryTextDeltaEvent.self, from: data),
                      !event.delta.isEmpty else {
                    return
                }
                emittedReasoningText += event.delta
                try await onEvent(.reasoningSummaryDelta(event.delta))

            case "response.function_call_arguments.delta":
                guard let event = try? decoder.decode(OpenAIResponsesFunctionCallArgumentsDeltaEvent.self, from: data),
                      !event.delta.isEmpty else {
                    return
                }
                let toolIndex = self.toolOrdinal(
                    for: event.outputIndex,
                    toolOrdinalsByOutputIndex: &toolOrdinalsByOutputIndex,
                    nextToolOrdinal: &nextToolOrdinal
                )
                accumulatedArgumentsByIndex[toolIndex, default: ""] += event.delta
                try await onEvent(.toolCallArgumentsDelta(index: toolIndex, argumentsDelta: event.delta))

            case "response.function_call_arguments.done":
                guard let event = try? decoder.decode(OpenAIResponsesFunctionCallArgumentsDoneEvent.self, from: data) else {
                    return
                }

                if let item = event.item {
                    let toolIndex = self.toolOrdinal(
                        for: event.outputIndex,
                        toolOrdinalsByOutputIndex: &toolOrdinalsByOutputIndex,
                        nextToolOrdinal: &nextToolOrdinal
                    )
                    if !startedToolIndices.contains(toolIndex) {
                        startedToolIndices.insert(toolIndex)
                        try await onEvent(
                            .toolCallStarted(index: toolIndex, id: item.callId, name: item.name)
                        )
                    }

                    if accumulatedArgumentsByIndex[toolIndex, default: ""].isEmpty, !item.arguments.isEmpty {
                        accumulatedArgumentsByIndex[toolIndex] = item.arguments
                        try await onEvent(
                            .toolCallArgumentsDelta(index: toolIndex, argumentsDelta: item.arguments)
                        )
                    }
                } else if let arguments = event.arguments,
                          let toolIndex = toolOrdinalsByOutputIndex[event.outputIndex],
                          accumulatedArgumentsByIndex[toolIndex, default: ""].isEmpty,
                          !arguments.isEmpty {
                    accumulatedArgumentsByIndex[toolIndex] = arguments
                    try await onEvent(
                        .toolCallArgumentsDelta(index: toolIndex, argumentsDelta: arguments)
                    )
                }

            case "response.completed":
                guard let event = try? decoder.decode(OpenAIResponsesCompletedEvent.self, from: data) else {
                    return
                }
                emittedCompletion = true
                try await onEvent(
                    .completed(
                        finishReason: self.determineResponsesFinishReason(from: event.response),
                        usage: self.mapResponsesUsage(event.response.usage)
                    )
                )

            default:
                return
            }
        }

        if !emittedCompletion {
            try await onEvent(.completed(finishReason: nil, usage: nil))
        }
    }

    // MARK: - Request Builders

    private func makeJSONRequest<T: Encodable>(path: String, body: T) throws -> URLRequest {
        var request = try makeUpstreamRequest(
            path: path,
            method: "POST",
            contentType: "application/json"
        )
        request.httpBody = try Self.jsonEncoder.encode(body)
        return request
    }

    private func makeUpstreamRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        contentType: String? = nil
    ) throws -> URLRequest {
        let url = try buildURL(path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        // 空密钥不发 Authorization 头（本地上游如 Ollama 无需鉴权；Claude/Codex 配置已校验非空，不受影响）。
        if !configuration.upstreamAPIKey.isEmpty {
            request.setValue("Bearer \(configuration.upstreamAPIKey)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in configuration.customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        upstreamLog.debug("Upstream: \(url.absoluteString, privacy: .private)")
        return request
    }

    private func decodeUpstreamJSONResponse<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        response: URLResponse
    ) throws -> T {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpstreamError.invalidResponse("Not an HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            upstreamLog.warning("Upstream \(httpResponse.statusCode): \(String(errorBody.prefix(500)), privacy: .private)")
            throw UpstreamError.httpError(
                statusCode: httpResponse.statusCode,
                message: errorBody,
                requestID: upstreamRequestID(from: httpResponse)
            )
        }

        do {
            return try Self.jsonDecoder.decode(type, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "Unable to read response"
            throw UpstreamError.decodingFailed("Failed to decode upstream response. Body: \(body)")
        }
    }

    private func decodeResponsesResponse(_ data: Data) throws -> OpenAIResponsesResponse {
        guard let decoded = try? Self.jsonDecoder.decode(OpenAIResponsesResponse.self, from: data) else {
            let body = String(data: data, encoding: .utf8) ?? "Unable to read response"
            throw UpstreamError.decodingFailed("Failed to decode upstream Responses response. Body: \(body)")
        }
        return decoded
    }

    private func upstreamRequestID(from response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: "request-id")
            ?? response.value(forHTTPHeaderField: "x-request-id")
    }

    private func buildMultipartFileUploadBody(
        filename: String,
        mimeType: String?,
        fileData: Data,
        purpose: String,
        boundary: String
    ) -> Data {
        var body = Data()
        let normalizedMimeType = mimeType?.isEmpty == false ? mimeType! : "application/octet-stream"
        let escapedFilename = filename
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        appendMultipartString("--\(boundary)\r\n", to: &body)
        appendMultipartString("Content-Disposition: form-data; name=\"purpose\"\r\n\r\n", to: &body)
        appendMultipartString("\(purpose)\r\n", to: &body)

        appendMultipartString("--\(boundary)\r\n", to: &body)
        appendMultipartString("Content-Disposition: form-data; name=\"file\"; filename=\"\(escapedFilename)\"\r\n", to: &body)
        appendMultipartString("Content-Type: \(normalizedMimeType)\r\n\r\n", to: &body)
        body.append(fileData)
        appendMultipartString("\r\n--\(boundary)--\r\n", to: &body)

        return body
    }

    private func appendMultipartString(_ string: String, to body: inout Data) {
        body.append(Data(string.utf8))
    }

    private func makeResponsesToolEvents(
        from item: OpenAIResponsesOutputItem,
        outputIndex: Int,
        toolOrdinalsByOutputIndex: inout [Int: Int],
        nextToolOrdinal: inout Int,
        startedToolIndices: inout Set<Int>,
        accumulatedArgumentsByIndex: inout [Int: String],
        emittedReasoningText: inout String
    ) -> [OpenAIUpstreamStreamEvent] {
        var events: [OpenAIUpstreamStreamEvent] = []

        switch item {
        case .functionCall(let functionCall):
            let toolIndex = toolOrdinal(
                for: outputIndex,
                toolOrdinalsByOutputIndex: &toolOrdinalsByOutputIndex,
                nextToolOrdinal: &nextToolOrdinal
            )

            if !startedToolIndices.contains(toolIndex) {
                startedToolIndices.insert(toolIndex)
                events.append(
                    .toolCallStarted(index: toolIndex, id: functionCall.callId, name: functionCall.name)
                )
            }

            if !functionCall.arguments.isEmpty,
               accumulatedArgumentsByIndex[toolIndex, default: ""].isEmpty {
                accumulatedArgumentsByIndex[toolIndex] = functionCall.arguments
                events.append(
                    .toolCallArgumentsDelta(index: toolIndex, argumentsDelta: functionCall.arguments)
                )
            }

        case .reasoning(let reasoning):
            let fullText = normalizedReasoningSummaryText(from: reasoning)
            let unseenText = unseenReasoningText(fullText: fullText, emittedSoFar: emittedReasoningText)
            if !unseenText.isEmpty {
                emittedReasoningText += unseenText
                events.append(.reasoningSummaryDelta(unseenText))
            }

        default:
            break
        }

        return events
    }

    private func toolOrdinal(
        for outputIndex: Int,
        toolOrdinalsByOutputIndex: inout [Int: Int],
        nextToolOrdinal: inout Int
    ) -> Int {
        if let existing = toolOrdinalsByOutputIndex[outputIndex] {
            return existing
        }

        let newOrdinal = nextToolOrdinal
        nextToolOrdinal += 1
        toolOrdinalsByOutputIndex[outputIndex] = newOrdinal
        return newOrdinal
    }

    private func normalizedReasoningSummaryText(from reasoning: OpenAIResponsesReasoningItem) -> String {
        let summaryText = reasoning.summary
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if !summaryText.isEmpty {
            return summaryText
        }

        return reasoning.content?
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: "\n") ?? ""
    }

    private func unseenReasoningText(fullText: String, emittedSoFar: String) -> String {
        guard !fullText.isEmpty else { return "" }
        guard !emittedSoFar.isEmpty else { return fullText }

        if fullText.hasPrefix(emittedSoFar) {
            return String(fullText.dropFirst(emittedSoFar.count))
        }

        // Upstream replaced the summary text entirely; only emit the new portion
        // to avoid duplicate content in the thinking block.
        if emittedSoFar.hasPrefix(fullText) {
            return ""
        }

        return fullText
    }

    // MARK: - Response Adapters

    private func determineResponsesFinishReason(from response: OpenAIResponsesResponse) -> String? {
        if responseRequiresPauseTurn(response) {
            return "pause_turn"
        }

        switch response.status {
        case "incomplete":
            return "length"
        case "failed":
            return nil
        default:
            break
        }

        if response.output.contains(where: {
            if case .functionCall = $0 { return true }
            return false
        }) {
            return "tool_calls"
        }

        return "stop"
    }

    private func responseRequiresPauseTurn(_ response: OpenAIResponsesResponse) -> Bool {
        guard let status = response.status?.lowercased(),
              status == "incomplete" || status == "in_progress" else {
            return false
        }

        return response.output.contains(where: hostedToolItemIsPending)
    }

    private func hostedToolItemIsPending(_ item: OpenAIResponsesOutputItem) -> Bool {
        switch item {
        case .fileSearchCall(let call):
            return hostedToolStatusRequiresPauseTurn(call.status)
        case .webSearchCall(let call):
            return hostedToolStatusRequiresPauseTurn(call.status)
        case .computerCall(let call):
            return hostedToolStatusRequiresPauseTurn(call.status)
        case .imageGenerationCall(let call):
            return hostedToolStatusRequiresPauseTurn(call.status)
        case .codeInterpreterCall(let call):
            return hostedToolStatusRequiresPauseTurn(call.status)
        case .toolSearchCall(let call):
            return hostedToolStatusRequiresPauseTurn(call.status)
        case .localShellCall(let call):
            return hostedToolStatusRequiresPauseTurn(call.status)
        case .shellCall(let call):
            return hostedToolStatusRequiresPauseTurn(call.status)
        case .applyPatchCall(let call):
            return hostedToolStatusRequiresPauseTurn(call.status)
        case .mcpCall(let call):
            return hostedToolStatusRequiresPauseTurn(call.status)
        default:
            return false
        }
    }

    private func hostedToolStatusRequiresPauseTurn(_ status: String?) -> Bool {
        guard let normalized = status?.lowercased() else {
            return true
        }

        switch normalized {
        case "completed", "failed", "cancelled", "canceled":
            return false
        default:
            return true
        }
    }

    private func mapResponsesUsage(_ usage: OpenAIResponsesUsage?) -> OpenAIUsage? {
        guard let usage else { return nil }
        return OpenAIUsage(
            promptTokens: usage.inputTokens,
            completionTokens: usage.outputTokens,
            totalTokens: usage.totalTokens,
            promptTokensDetails: usage.inputTokensDetails?.cachedTokens.map {
                OpenAIUsage.PromptTokensDetails(cachedTokens: $0)
            }
        )
    }

    // MARK: - SSE Helpers

    private func assembleChatCompletionFromSSE(body: String) throws -> OpenAIChatCompletionResponse {
        let decoder = Self.jsonDecoder
        var assembledContent = ""
        var assembledReasoning = ""
        var finishReason: String?
        var responseId = ""
        var model = ""
        var created = 0
        var toolCalls: [OpenAIToolCall] = []
        var pendingToolCalls: [Int: (id: String, name: String, args: String)] = [:]
        var capturedUsage: OpenAIUsage?

        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // W3C SSE 规范里 `data:` 后面的空格是可选的。原先硬要求 `data: `
            // 会把 Kimi Coding 这种无空格写法（`data:{...}`）全部漏掉，
            // 改成 `data:` 前缀 + dropFirst(5) + trim 兼容两种格式。
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }

            guard let chunkData = payload.data(using: .utf8),
                  let chunk = try? decoder.decode(OpenAIStreamChunk.self, from: chunkData) else { continue }

            // Capture usage from either OpenAI-standard top-level or Kimi/Moonshot-style choice-embedded.
            if let usage = chunk.usage {
                capturedUsage = usage
            } else if capturedUsage == nil,
                      let choiceUsage = chunk.choices.first(where: { $0.usage != nil })?.usage {
                capturedUsage = choiceUsage
            }

            guard let choice = chunk.choices.first else { continue }

            if responseId.isEmpty { responseId = chunk.id }
            if model.isEmpty { model = chunk.model }
            if created == 0 { created = chunk.created }

            if let reasoning = choice.delta.reasoningContent {
                assembledReasoning += reasoning
            }

            if let content = choice.delta.content {
                assembledContent += content
            }

            if let deltaTools = choice.delta.toolCalls {
                for tc in deltaTools {
                    var entry = pendingToolCalls[tc.index] ?? (id: "", name: "", args: "")
                    if let id = tc.id { entry.id = id }
                    if let name = tc.function?.name { entry.name = name }
                    if let args = tc.function?.arguments { entry.args += args }
                    pendingToolCalls[tc.index] = entry
                }
            }

            if let chunkFinishReason = choice.finishReason {
                finishReason = chunkFinishReason
            }
        }

        for (_, entry) in pendingToolCalls.sorted(by: { $0.key < $1.key }) {
            toolCalls.append(OpenAIToolCall(
                id: entry.id,
                function: OpenAIFunctionCall(name: entry.name, arguments: entry.args)
            ))
        }

        let estimatedTokens = max(1, assembledContent.count / 4)
        // 真实 usage 优先：上游真的发了 usage（顶层或嵌在 choice 里）就用它，
        // 否则才退回到字符数估算，避免把真实数据覆盖成估算值。
        let finalUsage = capturedUsage ?? OpenAIUsage(
            promptTokens: 0,
            completionTokens: estimatedTokens,
            totalTokens: estimatedTokens
        )

        return OpenAIChatCompletionResponse(
            id: responseId,
            object: "chat.completion",
            created: created,
            model: model,
            choices: [
                OpenAIChoice(
                    index: 0,
                    message: OpenAIChatMessage(
                        role: "assistant",
                        content: assembledContent.isEmpty ? nil : .text(assembledContent),
                        toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                        reasoningContent: assembledReasoning.isEmpty ? nil : assembledReasoning
                    ),
                    finishReason: finishReason
                )
            ],
            usage: finalUsage
        )
    }

    private func consumeSSEPayloads(
        from bytes: URLSession.AsyncBytes,
        onPayload: @escaping (String) async throws -> Void
    ) async throws {
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            try await onPayload(payload)
        }
    }

    // MARK: - Helpers

    private func buildURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        let normalizedBaseURL = ClaudeProxyConfiguration.normalizeOpenAIBaseURL(configuration.upstreamBaseURL)
        guard var components = URLComponents(string: normalizedBaseURL) else {
            throw UpstreamError.invalidURL(normalizedBaseURL)
        }

        let existingPath = components.path.split(separator: "/").map(String.init)
        let endpointPath = path.split(separator: "/").map(String.init)
        let fullPath = (existingPath + ["v1"] + endpointPath).joined(separator: "/")
        components.path = "/" + fullPath
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw UpstreamError.invalidURL(normalizedBaseURL + path)
        }
        return url
    }

    private func shouldRetryWithoutMaxTokens(_ errorBody: String) -> Bool {
        guard let data = errorBody.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let message: String
        if let errorObj = json["error"] as? [String: Any],
           let msg = errorObj["message"] as? String {
            message = msg.lowercased()
        } else if let msg = json["message"] as? String {
            message = msg.lowercased()
        } else {
            return false
        }
        return message.contains("max_tokens")
            || message.contains("max_output_tokens")
            || message.contains("model output limit")
    }

    private func readUTF8TextPrefix(
        from bytes: URLSession.AsyncBytes,
        maxBytes: Int
    ) async throws -> String {
        var data = Data()
        data.reserveCapacity(maxBytes)

        for try await byte in bytes {
            data.append(byte)
            if data.count >= maxBytes {
                break
            }
        }

        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Raw Responses Passthrough
    // 忠实透传：直接转发原始 Responses 请求体（不经过 Canonical 改写），最大化兼容 Codex 原生语义。
    // 仅在出站时附加上游鉴权头（由 makeUpstreamRequest 注入），并允许转发入站客户端的关键头。

    /// 上游瞬时故障（网关 5xx）可重试——很多第三方中转/Cloudflare 会偶发 500/502/503/504。
    static let rawPassthroughMaxAttempts = 3
    static func isRetryableUpstreamStatus(_ code: Int) -> Bool {
        code == 500 || code == 502 || code == 503 || code == 504
    }
    /// 第 attempt 次（从 1 起）失败后的退避时长。
    private static func retryBackoffNanos(_ attempt: Int) -> UInt64 {
        // 0.4s, 0.9s ...
        let ms = 400 + (attempt - 1) * 500
        return UInt64(ms) * 1_000_000
    }

    /// 非流式原样转发到指定上游端点（如 "/responses"、"/chat/completions"），
    /// 返回上游原始状态码 + 响应体。瞬时 5xx 自动重试。
    func sendRaw(
        path: String,
        bodyJSON: Data,
        extraHeaders: [String: String]
    ) async throws -> RawResponsesResult {
        let maxAttempts = Self.rawPassthroughMaxAttempts
        for attempt in 1...maxAttempts {
            var request = try makeUpstreamRequest(path: path, method: "POST", contentType: "application/json")
            for (key, value) in extraHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
            request.httpBody = bodyJSON
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw UpstreamError.invalidResponse("Not an HTTP response")
            }
            if attempt < maxAttempts, Self.isRetryableUpstreamStatus(httpResponse.statusCode) {
                upstreamLog.warning("Upstream raw \(httpResponse.statusCode) (attempt \(attempt)/\(maxAttempts)); retrying")
                try? await Task.sleep(nanoseconds: Self.retryBackoffNanos(attempt))
                continue
            }
            return RawResponsesResult(
                statusCode: httpResponse.statusCode,
                data: data,
                requestID: upstreamRequestID(from: httpResponse)
            )
        }
        throw UpstreamError.invalidResponse("retry loop exhausted")
    }

    /// GET 原样转发上游模型列表（/v1/models）。瞬时 5xx 自动重试，返回上游原始状态码 + 响应体。
    func fetchRawModels(extraHeaders: [String: String]) async throws -> RawResponsesResult {
        let maxAttempts = Self.rawPassthroughMaxAttempts
        for attempt in 1...maxAttempts {
            var request = try makeUpstreamRequest(path: "/models", method: "GET")
            for (key, value) in extraHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw UpstreamError.invalidResponse("Not an HTTP response")
            }
            if attempt < maxAttempts, Self.isRetryableUpstreamStatus(httpResponse.statusCode) {
                upstreamLog.warning("Upstream models \(httpResponse.statusCode) (attempt \(attempt)/\(maxAttempts)); retrying")
                try? await Task.sleep(nanoseconds: Self.retryBackoffNanos(attempt))
                continue
            }
            return RawResponsesResult(
                statusCode: httpResponse.statusCode,
                data: data,
                requestID: upstreamRequestID(from: httpResponse)
            )
        }
        throw UpstreamError.invalidResponse("retry loop exhausted")
    }

    /// 建立上游流式连接，瞬时 5xx 自动重试，直到拿到 200 或耗尽重试/不可重试状态。
    private func connectStreamWithRetry(
        path: String,
        bodyJSON: Data,
        extraHeaders: [String: String],
        maxAttempts: Int
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        for attempt in 1...maxAttempts {
            var request = try makeUpstreamRequest(path: path, method: "POST", contentType: "application/json")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            for (key, value) in extraHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
            request.httpBody = bodyJSON

            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw UpstreamError.invalidResponse("Not an HTTP response")
            }
            if httpResponse.statusCode == 200
                || attempt == maxAttempts
                || !Self.isRetryableUpstreamStatus(httpResponse.statusCode) {
                return (bytes, httpResponse)
            }
            // 可重试的瞬时 5xx：丢弃少量响应体释放连接，退避后重试。
            _ = try? await readUTF8TextPrefix(from: bytes, maxBytes: 1024)
            upstreamLog.warning("Upstream raw streaming \(httpResponse.statusCode) (attempt \(attempt)/\(maxAttempts)); retrying")
            try? await Task.sleep(nanoseconds: Self.retryBackoffNanos(attempt))
        }
        throw UpstreamError.invalidResponse("stream retry loop exhausted")
    }

    /// 流式原样转发：按 SSE 帧（空行分隔）逐帧回调 (event, data)，data 为原始 JSON 文本。
    /// 上游非 200 时抛出 UpstreamError.httpError（携带响应体片段）。
    func streamRawResponses(
        bodyJSON: Data,
        extraHeaders: [String: String],
        onFrame: @escaping (_ event: String?, _ data: String) async throws -> Void
    ) async throws {
        // 在开始转发任何 SSE 帧之前完成状态码判定，因此瞬时 5xx 可安全重试
        // （客户端此时只收到了 200 响应头，仍在等待 SSE，延迟一点的成功流是无害的）。
        let maxAttempts = Self.rawPassthroughMaxAttempts
        let (bytes, httpResponse) = try await connectStreamWithRetry(
            path: "/responses",
            bodyJSON: bodyJSON,
            extraHeaders: extraHeaders,
            maxAttempts: maxAttempts
        )
        guard httpResponse.statusCode == 200 else {
            let errorBody = try await readUTF8TextPrefix(from: bytes, maxBytes: 4096)
            upstreamLog.warning("Upstream raw streaming \(httpResponse.statusCode): \(String(errorBody.prefix(500)), privacy: .private)")
            throw UpstreamError.httpError(
                statusCode: httpResponse.statusCode,
                message: errorBody.isEmpty ? "Upstream returned status \(httpResponse.statusCode)" : errorBody,
                requestID: upstreamRequestID(from: httpResponse)
            )
        }

        // 注意：Foundation 的 `AsyncBytes.lines` 会吞掉 SSE 帧之间的空行，
        // 因此不能只靠 `line.isEmpty` 切帧——否则上游多帧会被拼成一帧。
        // OpenAI Responses 每帧都以 `event:` 开头，故新 `event:` 行也作为切帧信号。
        var currentEvent: String?
        var dataLines: [String] = []
        func flushFrame() async throws {
            guard !dataLines.isEmpty else { return }
            try await onFrame(currentEvent, dataLines.joined(separator: "\n"))
            currentEvent = nil
            dataLines = []
        }
        for try await line in bytes.lines {
            if line.isEmpty {
                try await flushFrame()
                continue
            }
            if line.hasPrefix("event:") {
                // 新的 event 行 = 新帧开始：先把上一帧（若有）刷出去。
                try await flushFrame()
                currentEvent = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let data = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                if data == "[DONE]" {
                    try await flushFrame()
                    try await onFrame(nil, data)
                } else {
                    dataLines.append(data)
                }
            }
            // 其它行（注释/心跳 ':' 等）忽略。
        }
        // 末帧兜底（部分上游结尾不带空行）。
        try await flushFrame()
    }

    /// chat/completions 流式原样转发：每个 `data:` 行即一帧（含末尾的 `[DONE]`），逐帧回调原始文本。
    /// chat.completions SSE 没有 `event:` 行，且 `AsyncBytes.lines` 会吞掉帧间空行，
    /// 因此必须按 data 行切帧，避免多个 chunk 被拼成一帧导致客户端解析失败。
    func streamRawChatCompletions(
        bodyJSON: Data,
        extraHeaders: [String: String],
        onData: @escaping (_ data: String) async throws -> Void
    ) async throws {
        let (bytes, httpResponse) = try await connectStreamWithRetry(
            path: "/chat/completions",
            bodyJSON: bodyJSON,
            extraHeaders: extraHeaders,
            maxAttempts: Self.rawPassthroughMaxAttempts
        )
        guard httpResponse.statusCode == 200 else {
            let errorBody = try await readUTF8TextPrefix(from: bytes, maxBytes: 4096)
            upstreamLog.warning("Upstream raw chat streaming \(httpResponse.statusCode): \(String(errorBody.prefix(500)), privacy: .private)")
            throw UpstreamError.httpError(
                statusCode: httpResponse.statusCode,
                message: errorBody.isEmpty ? "Upstream returned status \(httpResponse.statusCode)" : errorBody,
                requestID: upstreamRequestID(from: httpResponse)
            )
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            try await onData(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
        }
    }
}

/// 原始响应透传结果。
public struct RawResponsesResult: Sendable {
    public let statusCode: Int
    public let data: Data
    public let requestID: String?

    public init(statusCode: Int, data: Data, requestID: String?) {
        self.statusCode = statusCode
        self.data = data
        self.requestID = requestID
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Array {
    var nilIfEmpty: [Element]? {
        isEmpty ? nil : self
    }
}

// MARK: - Upstream Errors

public enum UpstreamError: Error, LocalizedError {
    case invalidURL(String)
    case invalidResponse(String)
    case httpError(statusCode: Int, message: String, requestID: String? = nil)
    case decodingFailed(String)
    case streamingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid upstream URL: \(url)"
        case .invalidResponse(let msg):
            return "Invalid response: \(msg)"
        case .httpError(let code, let msg, let requestID):
            if let requestID, !requestID.isEmpty {
                return "Upstream HTTP \(code): \(msg) (request_id: \(requestID))"
            }
            return "Upstream HTTP \(code): \(msg)"
        case .decodingFailed(let msg):
            return "Decoding failed: \(msg)"
        case .streamingFailed(let msg):
            return "Streaming failed: \(msg)"
        }
    }
}
