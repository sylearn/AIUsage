import Foundation

// MARK: - Codex Proxy Service
// 入站: OpenAI Responses 请求 → Canonical → OpenAI 兼容上游 → Canonical → Responses 响应/SSE。
// 复用 ClaudeProxy 的 Canonical 中间层与 OpenAICompatibleClient，仅出站构建器为新增。

public struct CodexProxyErrorResult: Sendable {
    public let response: CodexErrorResponse
    public let statusCode: Int

    public init(response: CodexErrorResponse, statusCode: Int) {
        self.response = response
        self.statusCode = statusCode
    }
}

public struct CodexErrorResponse: Codable, Sendable {
    public struct Body: Codable, Sendable {
        public let message: String
        public let type: String
        public let code: String?

        public init(message: String, type: String, code: String? = nil) {
            self.message = message
            self.type = type
            self.code = code
        }
    }

    public let error: Body
    /// 不参与编解码（仅入站透传时附带）。未列入 CodingKeys，故需默认值以满足 Decodable 合成。
    public var requestID: String? = nil

    enum CodingKeys: String, CodingKey {
        case error
    }

    public init(error: Body, requestID: String? = nil) {
        self.error = error
        self.requestID = requestID
    }
}

public actor CodexProxyService {
    private let configuration: CodexProxyConfiguration
    private let upstreamClient: OpenAICompatibleClient

    public init(configuration: CodexProxyConfiguration) throws {
        try configuration.validate()
        self.configuration = configuration
        self.upstreamClient = OpenAICompatibleClient(
            configuration: configuration.makeUpstreamClientConfiguration()
        )
    }

    // MARK: - Authentication

    public func authenticate(headers: [String: String]) -> Bool {
        guard let expectedKey = configuration.expectedClientAPIKey else {
            return true
        }
        if let apiKey = headers["x-api-key"], apiKey == expectedKey {
            return true
        }
        if let auth = headers["authorization"] {
            let bearer = "Bearer "
            if auth.hasPrefix(bearer) {
                let token = String(auth.dropFirst(bearer.count))
                if token == expectedKey {
                    return true
                }
            }
        }
        return false
    }

    public func mapModel(_ requestModel: String) -> String {
        configuration.mapToUpstreamModel(requestModel)
    }

    // MARK: - Faithful Passthrough (Responses → Responses)
    // Codex 恒走 Responses 忠实透传：不经过 Canonical 改写，直接转发原始请求体，
    // 仅把 model 映射到上游模型、附加上游鉴权与入站关键头；旁路解析 usage 用于统计。
    // 这样代理对 Codex 完全透明（= 直连），最大化兼容原生 instructions/reasoning/工具语义。
    // 备注: chat-completions 上游 / Anthropic 上游接入 Codex 属 Phase 2，届时再引入 Canonical 转换层。

    public struct PassthroughUsage: Sendable {
        /// Non-cached input tokens. OpenAI Responses reports cached tokens as a
        /// subset of `input_tokens`, so normalize before the value reaches
        /// proxy logs or pricing.
        public let inputTokens: Int
        public let outputTokens: Int
        public let cachedTokens: Int
    }

    public struct PassthroughResult: Sendable {
        public let statusCode: Int
        public let data: Data
        public let requestID: String?
        public let usage: PassthroughUsage?
    }

    /// 非流式透传。
    public func passthroughResponses(
        rawBody: Data,
        inboundHeaders: [String: String]
    ) async throws -> PassthroughResult {
        let body = rewriteModel(in: rawBody)
        let result = try await upstreamClient.sendRaw(
            path: "/responses",
            bodyJSON: body,
            extraHeaders: Self.forwardableHeaders(from: inboundHeaders)
        )
        let usage = (200..<300).contains(result.statusCode)
            ? Self.parseUsage(fromResponseBody: result.data)
            : nil
        return PassthroughResult(
            statusCode: result.statusCode,
            data: result.data,
            requestID: result.requestID,
            usage: usage
        )
    }

    /// 模型列表透传：Codex 启动时会 GET /v1/models 刷新可用模型，原样转发上游结果。
    public func passthroughModels(inboundHeaders: [String: String]) async throws -> RawResponsesResult {
        try await upstreamClient.fetchRawModels(
            extraHeaders: Self.forwardableHeaders(from: inboundHeaders)
        )
    }

    /// 流式透传：逐帧把上游 SSE 原样回调给入站层。
    public func passthroughStreamingResponses(
        rawBody: Data,
        inboundHeaders: [String: String],
        onFrame: @escaping (_ event: String?, _ data: String) async throws -> Void
    ) async throws {
        let body = rewriteModel(in: rawBody)
        try await upstreamClient.streamRawResponses(
            bodyJSON: body,
            extraHeaders: Self.forwardableHeaders(from: inboundHeaders),
            onFrame: onFrame
        )
    }

    /// 仅当配置了与请求不同的上游模型时改写 model 字段；否则保持原始字节不变。
    private func rewriteModel(in rawBody: Data) -> Data {
        guard let object = (try? JSONSerialization.jsonObject(with: rawBody)) as? [String: Any],
              let requestModel = object["model"] as? String else {
            return rawBody
        }
        let mapped = configuration.mapToUpstreamModel(requestModel)
        guard mapped != requestModel else { return rawBody }
        var mutated = object
        mutated["model"] = mapped
        return (try? JSONSerialization.data(withJSONObject: mutated)) ?? rawBody
    }

    /// 转发 Codex 客户端的关键头（剔除会与上游连接/鉴权冲突的头，鉴权由 makeUpstreamRequest 注入）。
    private static let forwardableHeaderMap: [String: String] = [
        "openai-beta": "OpenAI-Beta",
        "originator": "originator",
        "session-id": "session-id",
        "thread-id": "thread-id",
        "conversation-id": "conversation-id",
        "session_id": "session_id",
        "conversation_id": "conversation_id",
        "x-client-request-id": "x-client-request-id",
        "x-codex-turn-metadata": "x-codex-turn-metadata",
        "x-codex-window-id": "x-codex-window-id",
        "x-codex-beta-features": "x-codex-beta-features",
        "version": "version",
        "user-agent": "User-Agent"
    ]

    static func forwardableHeaders(from inbound: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (lowerKey, canonical) in forwardableHeaderMap {
            if let value = inbound[lowerKey], !value.isEmpty {
                out[canonical] = value
            }
        }
        return out
    }

    /// 解析非流式响应体顶层 usage。
    static func parseUsage(fromResponseBody data: Data) -> PassthroughUsage? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let usage = object["usage"] as? [String: Any] else {
            return nil
        }
        return makeUsage(usage)
    }

    /// 从流式帧的 data 文本中解析 usage（response.completed 内含 response.usage）。
    public static func parseUsage(fromStreamFrame frameData: String) -> PassthroughUsage? {
        guard let data = frameData.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if let response = object["response"] as? [String: Any],
           let usage = response["usage"] as? [String: Any] {
            return makeUsage(usage)
        }
        if let usage = object["usage"] as? [String: Any] {
            return makeUsage(usage)
        }
        return nil
    }

    private static func makeUsage(_ usage: [String: Any]) -> PassthroughUsage {
        let rawInput = max(0, intValue(usage["input_tokens"]))
        let output = max(0, intValue(usage["output_tokens"]))
        var cached = 0
        if let details = usage["input_tokens_details"] as? [String: Any] {
            cached = min(rawInput, max(0, intValue(details["cached_tokens"])))
        }
        let input = rawInput - cached
        return PassthroughUsage(inputTokens: input, outputTokens: output, cachedTokens: cached)
    }

    private static func intValue(_ any: Any?) -> Int {
        if let n = any as? Int { return n }
        if let n = any as? Double { return Int(n) }
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }

    // MARK: - Error Handling

    public func buildErrorResult(error: Error) -> CodexProxyErrorResult {
        let errorType: String
        let errorMessage: String
        let statusCode: Int
        var requestID: String?

        switch error {
        case let configError as ConfigurationError:
            errorType = "invalid_request_error"
            errorMessage = configError.localizedDescription
            statusCode = 400

        case let conversionError as ConversionError:
            errorType = "invalid_request_error"
            errorMessage = conversionError.localizedDescription
            statusCode = 400

        case let upstreamError as UpstreamError:
            switch upstreamError {
            case .httpError(let upstreamStatusCode, let upstreamMessage, let upstreamRequestID):
                errorType = openAIErrorType(forHTTPStatus: upstreamStatusCode)
                errorMessage = upstreamErrorMessage(from: upstreamMessage, statusCode: upstreamStatusCode)
                statusCode = upstreamStatusCode
                requestID = upstreamRequestID
            case .invalidURL(let url):
                errorType = "api_error"
                errorMessage = "Invalid upstream URL: \(url)"
                statusCode = 500
            case .invalidResponse(let message):
                errorType = "api_error"
                errorMessage = "Invalid response: \(message)"
                statusCode = 500
            case .decodingFailed(let message):
                errorType = "api_error"
                errorMessage = "Decoding failed: \(message)"
                statusCode = 500
            case .streamingFailed(let message):
                errorType = "api_error"
                errorMessage = "Streaming failed: \(message)"
                statusCode = 500
            }

        default:
            errorType = "api_error"
            errorMessage = error.localizedDescription
            statusCode = 500
        }

        return CodexProxyErrorResult(
            response: CodexErrorResponse(
                error: CodexErrorResponse.Body(message: errorMessage, type: errorType),
                requestID: requestID
            ),
            statusCode: statusCode
        )
    }

    private func openAIErrorType(forHTTPStatus statusCode: Int) -> String {
        switch statusCode {
        case 400:
            return "invalid_request_error"
        case 401:
            return "authentication_error"
        case 403:
            return "permission_error"
        case 404:
            return "not_found_error"
        case 429:
            return "rate_limit_error"
        case 400..<500:
            return "invalid_request_error"
        default:
            return "api_error"
        }
    }

    private func upstreamErrorMessage(from rawMessage: String, statusCode: Int) -> String {
        if let data = rawMessage.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errorObject = object["error"] as? [String: Any],
               let message = errorObject["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
            if let message = object["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
        }
        let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return "Upstream request failed with HTTP \(statusCode)."
    }
}
