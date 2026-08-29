import Foundation
import XCTest
@testable import QuotaBackend
@testable import QuotaServerCore

final class QuotaHTTPServerProxyIntegrationTests: XCTestCase {

    func testHealthEndpointReportsReady() async throws {
        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            startupToken: "test-instance-token"
        )
        try await server.start()
        defer { server.stop() }

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(proxyPort)/health")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertFalse((json["generatedAt"] as? String ?? "").isEmpty)
        XCTAssertEqual(json["instanceToken"] as? String, "test-instance-token")
    }

    func testScienceModelsEndpointUsesActiveCatalogAndRequiresClientKey() async throws {
        let proxyPort = try findFreePort()
        let config = ClaudeProxyConfiguration(
            enabled: true,
            bindPort: proxyPort,
            mode: .openaiConvert,
            upstreamBaseURL: "http://127.0.0.1:9",
            upstreamAPIKey: "upstream-key",
            expectedClientKey: "client-key",
            availableModels: ["glm-5.2", "ZhipuAI/GLM-5.2"],
            defaultModel: "glm-5.2",
            exposeScienceModelCatalog: true,
            preferExactCatalogModels: true
        )
        let server = QuotaHTTPServer(host: "127.0.0.1", port: proxyPort, proxyConfig: config)
        try await server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(proxyPort)/v1/models?limit=1000")!
        let (_, unauthorizedResponse) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((unauthorizedResponse as? HTTPURLResponse)?.statusCode, 401)

        var request = URLRequest(url: url)
        request.setValue("Bearer client-key", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(json["data"] as? [[String: Any]])
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0]["id"] as? String, config.scienceDefaultModelID)
        XCTAssertEqual(models[0]["display_name"] as? String, "glm-5.2")
        XCTAssertEqual(models[1]["display_name"] as? String, "ZhipuAI/GLM-5.2")
        XCTAssertEqual(models[0]["type"] as? String, "model")
        XCTAssertEqual(json["has_more"] as? Bool, false)
        XCTAssertEqual(json["first_id"] as? String, models[0]["id"] as? String)
        XCTAssertEqual(json["last_id"] as? String, models[1]["id"] as? String)

        var pagedRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/models?limit=1")!)
        pagedRequest.setValue("client-key", forHTTPHeaderField: "x-api-key")
        let (pagedData, pagedResponse) = try await URLSession.shared.data(for: pagedRequest)
        XCTAssertEqual((pagedResponse as? HTTPURLResponse)?.statusCode, 200)
        let pagedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: pagedData) as? [String: Any])
        XCTAssertEqual((pagedJSON["data"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(pagedJSON["has_more"] as? Bool, true)
    }

    func testDesktopModelsEndpointAcceptsOnlyDesktopKeyOnDedicatedPrefix() async throws {
        let proxyPort = try findFreePort()
        let config = ClaudeProxyConfiguration(
            enabled: true,
            bindPort: proxyPort,
            mode: .openaiConvert,
            upstreamBaseURL: "http://127.0.0.1:9",
            upstreamAPIKey: "upstream-key",
            expectedClientKey: "code-key",
            expectedDesktopClientKey: "desktop-key",
            availableModels: ["third-party-large", "third-party-fast"],
            defaultModel: "third-party-large",
            exposeScienceModelCatalog: true,
            preferExactCatalogModels: true,
            catalogRouteStyle: .desktop,
            catalogSupports1M: ["third-party-large"]
        )
        let server = QuotaHTTPServer(host: "127.0.0.1", port: proxyPort, proxyConfig: config)
        try await server.start()
        defer { server.stop() }

        let prefixedURL = URL(string: "http://127.0.0.1:\(proxyPort)/claude-desktop/v1/models?limit=1000")!
        var codeRequest = URLRequest(url: prefixedURL)
        codeRequest.setValue("Bearer code-key", forHTTPHeaderField: "Authorization")
        let (_, codeResponse) = try await URLSession.shared.data(for: codeRequest)
        XCTAssertEqual((codeResponse as? HTTPURLResponse)?.statusCode, 401)

        var desktopRequest = URLRequest(url: prefixedURL)
        desktopRequest.setValue("Bearer desktop-key", forHTTPHeaderField: "Authorization")
        let (desktopData, desktopResponse) = try await URLSession.shared.data(for: desktopRequest)
        XCTAssertEqual((desktopResponse as? HTTPURLResponse)?.statusCode, 200)
        let desktopJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: desktopData) as? [String: Any])
        let desktopModels = try XCTUnwrap(desktopJSON["data"] as? [[String: Any]])
        XCTAssertEqual(desktopModels.count, 2)
        XCTAssertEqual(desktopModels[0]["display_name"] as? String, "third-party-large")
        XCTAssertEqual(desktopModels[0]["supports1m"] as? Bool, true)
        XCTAssertTrue(
            ScienceModelProtocolAdapter.isDesktopSafeModelID(desktopModels[0]["id"] as? String ?? "")
        )

        // Current Desktop builds may also call the root route. The matching
        // Desktop credential still classifies the request without a client header.
        var rootRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/models")!)
        rootRequest.setValue("desktop-key", forHTTPHeaderField: "x-api-key")
        let (_, rootResponse) = try await URLSession.shared.data(for: rootRequest)
        XCTAssertEqual((rootResponse as? HTTPURLResponse)?.statusCode, 200)
    }

    func testScienceCatalogHotSwitchReplacesAliasesAndContainsStaleSelection() throws {
        let initial = ClaudeProxyConfiguration(
            enabled: true,
            mode: .openaiConvert,
            upstreamBaseURL: "http://127.0.0.1:9",
            upstreamAPIKey: "old-key",
            availableModels: ["old-default", "old-extra"],
            defaultModel: "old-default",
            exposeScienceModelCatalog: true,
            preferExactCatalogModels: true
        )
        let staleAlias = try XCTUnwrap(
            initial.scienceCatalogModels.first { $0.upstreamModel == "old-extra" }?.id
        )
        let server = QuotaHTTPServer(host: "127.0.0.1", port: 4318, proxyConfig: initial)

        let update = QuotaHTTPServer.ClaudeUpstreamUpdate(
            nodeId: "new-node",
            mode: "convert",
            baseURL: "http://127.0.0.1:10",
            apiKey: "new-key",
            apiMode: "chat_completions",
            bigModel: "new-default",
            middleModel: "new-default",
            smallModel: "new-default",
            maxOutputTokens: nil,
            enableModelAliasMapping: false,
            availableModels: ["new-default", "new-extra"],
            defaultModel: "new-default",
            catalogRouteStyle: nil,
            mapDesktopTierRoutes: nil,
            catalogSupports1M: nil,
            forcedModel: nil
        )

        XCTAssertTrue(server.applyClaudeUpstream(update))
        let switched = try XCTUnwrap(server.proxyConfig)
        XCTAssertEqual(switched.availableModels, ["new-default", "new-extra"])
        XCTAssertTrue(switched.exposeScienceModelCatalog)
        XCTAssertTrue(switched.preferExactCatalogModels)
        XCTAssertEqual(switched.mapToUpstreamModel(staleAlias), "new-default")
        XCTAssertEqual(
            switched.mapToUpstreamModel(switched.scienceDefaultModelID ?? ""),
            "new-default"
        )
        let currentAlias = try XCTUnwrap(
            switched.scienceCatalogModels.first { $0.upstreamModel == "new-extra" }?.id
        )
        XCTAssertEqual(switched.mapToUpstreamModel(currentAlias), "new-extra")
    }

    func testMessagesEndpointRejectsInvalidClientKey() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            try MockHTTPResponse.json(
                object: [
                    "id": "chatcmpl-test",
                    "object": "chat.completion",
                    "created": 1,
                    "model": "gpt-4o-mini",
                    "choices": [
                        [
                            "index": 0,
                            "message": ["role": "assistant", "content": "should not be reached"],
                            "finish_reason": "stop",
                        ],
                    ],
                    "usage": [
                        "prompt_tokens": 1,
                        "completion_tokens": 1,
                        "total_tokens": 2,
                    ],
                ]
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort)
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "wrong-key"
        )
        request.httpBody = try makeClaudeMessagesBody(stream: false)

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)

        let decoded = try JSONDecoder().decode(ClaudeErrorResponse.self, from: data)
        XCTAssertEqual(decoded.error.type, "authentication_error")
        XCTAssertEqual(decoded.error.message, "Invalid API key")
        let recordedRequests = await upstream.recordedRequests()
        XCTAssertTrue(recordedRequests.isEmpty)
    }

    func testCountTokensEndpointReturnsHeuristicEstimate() async throws {
        let upstreamPort = try findFreePort()
        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort)
        )
        try await server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/messages/count_tokens")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("client-key", forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": "claude-3-5-sonnet-20241022",
                "system": "You are a helpful assistant.",
                "messages": [
                    ["role": "user", "content": "Please count these tokens."],
                ],
            ]
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let tokenCount = try JSONDecoder().decode(ClaudeTokenCountResponse.self, from: data)
        XCTAssertGreaterThan(tokenCount.inputTokens, 0)
    }

    func testOpenAIConvertProxyNonStreamingRoundTrip() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            try MockHTTPResponse.json(
                object: [
                    "id": "chatcmpl-nonstream",
                    "object": "chat.completion",
                    "created": 1_710_000_000,
                    "model": "gpt-4o-mini",
                    "choices": [
                        [
                            "index": 0,
                            "message": [
                                "role": "assistant",
                                "content": "Hello from upstream",
                            ],
                            "finish_reason": "stop",
                        ],
                    ],
                    "usage": [
                        "prompt_tokens": 12,
                        "completion_tokens": 5,
                        "total_tokens": 17,
                    ],
                ]
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort)
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try makeClaudeMessagesBody(stream: false)

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let decoded = try JSONDecoder().decode(ClaudeMessageResponse.self, from: data)
        XCTAssertEqual(decoded.role, "assistant")
        XCTAssertEqual(firstTextBlock(in: decoded.content), "Hello from upstream")
        XCTAssertEqual(decoded.stopReason, "end_turn")
        XCTAssertEqual(decoded.usage.outputTokens, 5)

        let requests = await upstream.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let upstreamRequest = try XCTUnwrap(requests.first)
        XCTAssertEqual(upstreamRequest.method, "POST")
        XCTAssertEqual(upstreamRequest.path, "/v1/chat/completions")
        XCTAssertEqual(upstreamRequest.headers["authorization"], "Bearer upstream-key")

        let upstreamBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: upstreamRequest.body) as? [String: Any]
        )
        XCTAssertEqual(upstreamBody["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(upstreamBody["stream"] as? Bool, false)
    }

    func testOpenAIConvertProxyNonStreamingForwardsRichMediaInputsInChatCompletionsMode() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            try MockHTTPResponse.json(
                object: [
                    "id": "chatcmpl-media",
                    "object": "chat.completion",
                    "created": 1_710_000_005,
                    "model": "gpt-4o-mini",
                    "choices": [
                        [
                            "index": 0,
                            "message": [
                                "role": "assistant",
                                "content": "Media received",
                            ],
                            "finish_reason": "stop",
                        ],
                    ],
                    "usage": [
                        "prompt_tokens": 18,
                        "completion_tokens": 3,
                        "total_tokens": 21,
                    ],
                ]
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort)
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": "claude-3-5-sonnet-20241022",
                "messages": [
                    [
                        "role": "user",
                        "content": [
                            [
                                "type": "text",
                                "text": "Review these attachments"
                            ],
                            [
                                "type": "image",
                                "source": [
                                    "type": "base64",
                                    "media_type": "image/png",
                                    "data": "AAAA"
                                ]
                            ],
                            [
                                "type": "document",
                                "source": [
                                    "type": "file",
                                    "file_id": "file_123"
                                ],
                                "title": "report.pdf"
                            ]
                        ]
                    ]
                ],
                "max_tokens": 64,
                "stream": false
            ]
        )

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let requests = await upstream.recordedRequests()
        let upstreamRequest = try XCTUnwrap(requests.first)
        XCTAssertEqual(upstreamRequest.path, "/v1/chat/completions")

        let upstreamBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: upstreamRequest.body) as? [String: Any]
        )
        let messages = try XCTUnwrap(upstreamBody["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])

        XCTAssertEqual(content.count, 3)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "Review these attachments")
        XCTAssertEqual(content[1]["type"] as? String, "image_url")
        let image = try XCTUnwrap(content[1]["image_url"] as? [String: Any])
        XCTAssertEqual(image["url"] as? String, "data:image/png;base64,AAAA")
        XCTAssertEqual(content[2]["type"] as? String, "file")
        let file = try XCTUnwrap(content[2]["file"] as? [String: Any])
        XCTAssertEqual(file["file_id"] as? String, "file_123")
        XCTAssertEqual(file["filename"] as? String, "report.pdf")
    }

    func testOpenAIConvertProxyForwardsStructuredToolChoiceAndMultipleToolResults() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            try MockHTTPResponse.json(
                object: [
                    "id": "chatcmpl-tools",
                    "object": "chat.completion",
                    "created": 1_710_000_010,
                    "model": "gpt-4o-mini",
                    "choices": [
                        [
                            "index": 0,
                            "message": [
                                "role": "assistant",
                                "content": "Tool results received",
                            ],
                            "finish_reason": "stop",
                        ],
                    ],
                    "usage": [
                        "prompt_tokens": 20,
                        "completion_tokens": 4,
                        "total_tokens": 24,
                    ],
                ]
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort)
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": "claude-3-5-sonnet-20241022",
                "messages": [
                    [
                        "role": "assistant",
                        "content": [
                            [
                                "type": "tool_use",
                                "id": "toolu_weather",
                                "name": "get_weather",
                                "input": [
                                    "location": "Shanghai",
                                ],
                            ],
                            [
                                "type": "tool_use",
                                "id": "toolu_time",
                                "name": "get_time",
                                "input": [
                                    "timezone": "Asia/Shanghai",
                                ],
                            ],
                        ],
                    ],
                    [
                        "role": "user",
                        "content": [
                            [
                                "type": "tool_result",
                                "tool_use_id": "toolu_weather",
                                "content": "Sunny",
                            ],
                            [
                                "type": "tool_result",
                                "tool_use_id": "toolu_time",
                                "content": "12:00",
                            ],
                        ],
                    ],
                ],
                "tools": [
                    [
                        "name": "get_weather",
                        "description": "Get the weather",
                        "input_schema": [
                            "type": "object",
                            "properties": [
                                "location": [
                                    "type": "string",
                                ],
                            ],
                            "required": ["location"],
                        ],
                    ],
                    [
                        "name": "get_time",
                        "description": "Get the time",
                        "input_schema": [
                            "type": "object",
                            "properties": [
                                "timezone": [
                                    "type": "string",
                                ],
                            ],
                            "required": ["timezone"],
                        ],
                    ],
                ],
                "tool_choice": [
                    "type": "tool",
                    "name": "get_weather",
                ],
                "max_tokens": 64,
                "stream": false,
            ]
        )

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let requests = await upstream.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let upstreamRequest = try XCTUnwrap(requests.first)
        let upstreamBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: upstreamRequest.body) as? [String: Any]
        )

        let messages = try XCTUnwrap(upstreamBody["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0]["role"] as? String, "assistant")
        XCTAssertEqual(messages[1]["role"] as? String, "tool")
        XCTAssertEqual(messages[1]["tool_call_id"] as? String, "toolu_weather")
        XCTAssertEqual(messages[2]["role"] as? String, "tool")
        XCTAssertEqual(messages[2]["tool_call_id"] as? String, "toolu_time")

        let toolChoice = try XCTUnwrap(upstreamBody["tool_choice"] as? [String: Any])
        XCTAssertEqual(toolChoice["type"] as? String, "function")
        let function = try XCTUnwrap(toolChoice["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "get_weather")
    }

    func testOpenAIConvertProxyMapsUpstreamHTTP400ToClaudeInvalidRequestError() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            try MockHTTPResponse.json(
                status: 400,
                object: [
                    "error": [
                        "message": "Model mismatch",
                        "type": "invalid_request_error"
                    ]
                ],
                headers: [
                    "x-request-id": "req_chat_400"
                ]
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort)
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try makeClaudeMessagesBody(stream: false)

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "request-id"), "req_chat_400")

        let decoded = try JSONDecoder().decode(ClaudeErrorResponse.self, from: data)
        XCTAssertEqual(decoded.error.type, "invalid_request_error")
        XCTAssertEqual(decoded.error.message, "Model mismatch")
        XCTAssertEqual(decoded.requestID, "req_chat_400")
    }

    func testOpenAIResponsesProxyNonStreamingRoundTrip() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            try MockHTTPResponse.json(
                object: [
                    "id": "resp-nonstream",
                    "object": "response",
                    "created_at": 1_710_000_100,
                    "model": "gpt-4o-mini",
                    "status": "completed",
                    "output": [
                        [
                            "id": "msg-responses-1",
                            "type": "message",
                            "role": "assistant",
                            "status": "completed",
                            "content": [
                                [
                                    "type": "output_text",
                                    "text": "Hello from responses",
                                ],
                            ],
                        ],
                    ],
                    "usage": [
                        "input_tokens": 12,
                        "output_tokens": 6,
                        "total_tokens": 18,
                    ],
                ]
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(
                upstreamPort: upstreamPort,
                api: .responses,
                upstreamBaseURL: "http://127.0.0.1:\(upstreamPort)/v1"
            )
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try makeClaudeMessagesBody(stream: false)

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let decoded = try JSONDecoder().decode(ClaudeMessageResponse.self, from: data)
        XCTAssertEqual(decoded.role, "assistant")
        XCTAssertEqual(firstTextBlock(in: decoded.content), "Hello from responses")
        XCTAssertEqual(decoded.stopReason, "end_turn")
        XCTAssertEqual(decoded.usage.outputTokens, 6)

        let requests = await upstream.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let upstreamRequest = try XCTUnwrap(requests.first)
        XCTAssertEqual(upstreamRequest.path, "/v1/responses")

        let upstreamBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: upstreamRequest.body) as? [String: Any]
        )
        XCTAssertNil(upstreamBody["messages"])
        XCTAssertNotNil(upstreamBody["input"])
        XCTAssertEqual(upstreamBody["stream"] as? Bool, false)
        XCTAssertEqual(upstreamBody["store"] as? Bool, false)
        XCTAssertEqual(upstreamBody["max_output_tokens"] as? Int, 64)
    }

    func testOpenAIResponsesProxyNonStreamingForwardsRichMediaInputsInResponsesMode() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            try MockHTTPResponse.json(
                object: [
                    "id": "resp-media",
                    "object": "response",
                    "created_at": 1_710_000_150,
                    "model": "gpt-4o-mini",
                    "status": "completed",
                    "output": [
                        [
                            "id": "msg-responses-media",
                            "type": "message",
                            "role": "assistant",
                            "status": "completed",
                            "content": [
                                [
                                    "type": "output_text",
                                    "text": "Media received",
                                ],
                            ],
                        ],
                    ],
                    "usage": [
                        "input_tokens": 22,
                        "output_tokens": 4,
                        "total_tokens": 26,
                    ],
                ]
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(
                upstreamPort: upstreamPort,
                api: .responses,
                upstreamBaseURL: "http://127.0.0.1:\(upstreamPort)/v1"
            )
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": "claude-3-5-sonnet-20241022",
                "messages": [
                    [
                        "role": "user",
                        "content": [
                            [
                                "type": "text",
                                "text": "Summarize these inputs"
                            ],
                            [
                                "type": "image",
                                "source": [
                                    "type": "base64",
                                    "media_type": "image/png",
                                    "data": "BBBB"
                                ]
                            ],
                            [
                                "type": "document",
                                "source": [
                                    "type": "file",
                                    "file_id": "file_456"
                                ],
                                "title": "analysis.pdf"
                            ]
                        ]
                    ]
                ],
                "max_tokens": 64,
                "stream": false
            ]
        )

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let requests = await upstream.recordedRequests()
        let upstreamRequest = try XCTUnwrap(requests.first)
        XCTAssertEqual(upstreamRequest.path, "/v1/responses")

        let upstreamBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: upstreamRequest.body) as? [String: Any]
        )
        let input = try XCTUnwrap(upstreamBody["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])

        XCTAssertEqual(content.count, 3)
        XCTAssertEqual(content[0]["type"] as? String, "input_text")
        XCTAssertEqual(content[0]["text"] as? String, "Summarize these inputs")
        XCTAssertEqual(content[1]["type"] as? String, "input_image")
        XCTAssertEqual(content[1]["image_url"] as? String, "data:image/png;base64,BBBB")
        XCTAssertEqual(content[2]["type"] as? String, "input_file")
        XCTAssertEqual(content[2]["file_id"] as? String, "file_456")
        XCTAssertEqual(content[2]["filename"] as? String, "analysis.pdf")
    }

    func testOpenAIResponsesProxyMapsUpstreamHTTP429ToClaudeRateLimitError() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            try MockHTTPResponse.json(
                status: 429,
                object: [
                    "error": [
                        "message": "Too many requests",
                        "type": "rate_limit_error"
                    ]
                ],
                headers: [
                    "x-request-id": "req_resp_429"
                ]
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(
                upstreamPort: upstreamPort,
                api: .responses,
                upstreamBaseURL: "http://127.0.0.1:\(upstreamPort)/v1"
            )
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try makeClaudeMessagesBody(stream: false)

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 429)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "request-id"), "req_resp_429")

        let decoded = try JSONDecoder().decode(ClaudeErrorResponse.self, from: data)
        XCTAssertEqual(decoded.error.type, "rate_limit_error")
        XCTAssertEqual(decoded.error.message, "Too many requests")
        XCTAssertEqual(decoded.requestID, "req_resp_429")
    }

    func testOpenAIResponsesProxyPreservesClaudeCodeStyleToolLoopHistory() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            try MockHTTPResponse.json(
                object: [
                    "id": "resp-history",
                    "object": "response",
                    "created_at": 1_710_000_180,
                    "model": "gpt-4o-mini",
                    "status": "completed",
                    "output": [
                        [
                            "id": "msg-history-1",
                            "type": "message",
                            "role": "assistant",
                            "status": "completed",
                            "phase": "final_answer",
                            "content": [
                                [
                                    "type": "output_text",
                                    "text": "Repo inspected",
                                ],
                            ],
                        ],
                    ],
                    "usage": [
                        "input_tokens": 34,
                        "output_tokens": 5,
                        "total_tokens": 39,
                    ],
                ]
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(
                upstreamPort: upstreamPort,
                api: .responses,
                upstreamBaseURL: "http://127.0.0.1:\(upstreamPort)/v1"
            )
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": "claude-sonnet-4.5",
                "messages": [
                    [
                        "role": "user",
                        "content": "Inspect the repository."
                    ],
                    [
                        "role": "assistant",
                        "content": [
                            [
                                "type": "text",
                                "text": "I'll inspect the tree first."
                            ],
                            [
                                "type": "tool_use",
                                "id": "toolu_repo",
                                "name": "inspect_repo",
                                "input": [
                                    "path": "/workspace"
                                ]
                            ]
                        ]
                    ],
                    [
                        "role": "user",
                        "content": [
                            [
                                "type": "tool_result",
                                "tool_use_id": "toolu_repo",
                                "content": [
                                    [
                                        "type": "text",
                                        "text": "Found 3 files"
                                    ],
                                    [
                                        "type": "image",
                                        "source": [
                                            "type": "base64",
                                            "media_type": "image/png",
                                            "data": "CCCC"
                                        ]
                                    ],
                                    [
                                        "type": "document",
                                        "source": [
                                            "type": "file",
                                            "file_id": "file_789"
                                        ],
                                        "title": "tree.txt"
                                    ]
                                ]
                            ]
                        ]
                    ]
                ],
                "max_tokens": 64,
                "stream": false
            ]
        )

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let requests = await upstream.recordedRequests()
        let upstreamRequest = try XCTUnwrap(requests.first)
        XCTAssertEqual(upstreamRequest.path, "/v1/responses")

        let upstreamBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: upstreamRequest.body) as? [String: Any]
        )
        let input = try XCTUnwrap(upstreamBody["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 4)

        XCTAssertEqual(input[0]["role"] as? String, "user")

        XCTAssertEqual(input[1]["role"] as? String, "assistant")
        XCTAssertEqual(input[1]["phase"] as? String, "commentary")
        let assistantContent = try XCTUnwrap(input[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistantContent.count, 1)
        XCTAssertEqual(assistantContent[0]["type"] as? String, "output_text")
        XCTAssertEqual(assistantContent[0]["text"] as? String, "I'll inspect the tree first.")

        XCTAssertEqual(input[2]["type"] as? String, "function_call")
        XCTAssertEqual(input[2]["call_id"] as? String, "toolu_repo")
        XCTAssertEqual(input[2]["name"] as? String, "inspect_repo")

        XCTAssertEqual(input[3]["type"] as? String, "function_call_output")
        XCTAssertEqual(input[3]["call_id"] as? String, "toolu_repo")
        let toolOutput = try XCTUnwrap(input[3]["output"] as? [[String: Any]])
        XCTAssertEqual(toolOutput.count, 3)
        XCTAssertEqual(toolOutput[0]["type"] as? String, "input_text")
        XCTAssertEqual(toolOutput[0]["text"] as? String, "Found 3 files")
        XCTAssertEqual(toolOutput[1]["type"] as? String, "input_image")
        XCTAssertEqual(toolOutput[1]["image_url"] as? String, "data:image/png;base64,CCCC")
        XCTAssertEqual(toolOutput[2]["type"] as? String, "input_file")
        XCTAssertEqual(toolOutput[2]["file_id"] as? String, "file_789")
        XCTAssertEqual(toolOutput[2]["filename"] as? String, "tree.txt")
    }

    func testOpenAIResponsesProxyPreservesLongMultiTurnToolLoopHistoryAndUsage() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            try MockHTTPResponse.json(
                object: [
                    "id": "resp-history-long",
                    "object": "response",
                    "created_at": 1_710_000_181,
                    "model": "gpt-4o-mini",
                    "status": "completed",
                    "output": [
                        [
                            "id": "msg-history-long-1",
                            "type": "message",
                            "role": "assistant",
                            "status": "completed",
                            "phase": "final_answer",
                            "content": [
                                [
                                    "type": "output_text",
                                    "text": "Both inspections are complete.",
                                ],
                            ],
                        ],
                    ],
                    "usage": [
                        "input_tokens": 55,
                        "output_tokens": 8,
                        "total_tokens": 63,
                    ],
                ]
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(
                upstreamPort: upstreamPort,
                api: .responses,
                upstreamBaseURL: "http://127.0.0.1:\(upstreamPort)/v1"
            )
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": "claude-sonnet-4.5",
                "messages": [
                    [
                        "role": "user",
                        "content": "Inspect the frontend files."
                    ],
                    [
                        "role": "assistant",
                        "content": [
                            [
                                "type": "text",
                                "text": "I'll inspect the frontend first."
                            ],
                            [
                                "type": "tool_use",
                                "id": "toolu_frontend",
                                "name": "inspect_repo",
                                "input": [
                                    "path": "/workspace/frontend"
                                ]
                            ]
                        ]
                    ],
                    [
                        "role": "user",
                        "content": [
                            [
                                "type": "tool_result",
                                "tool_use_id": "toolu_frontend",
                                "content": [
                                    [
                                        "type": "text",
                                        "text": "Found 12 frontend files"
                                    ],
                                    [
                                        "type": "image",
                                        "source": [
                                            "type": "base64",
                                            "media_type": "image/png",
                                            "data": "DDDD"
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ],
                    [
                        "role": "user",
                        "content": "Now inspect the backend files too."
                    ],
                    [
                        "role": "assistant",
                        "content": [
                            [
                                "type": "text",
                                "text": "I'll inspect the backend next."
                            ],
                            [
                                "type": "tool_use",
                                "id": "toolu_backend",
                                "name": "inspect_repo",
                                "input": [
                                    "path": "/workspace/backend"
                                ]
                            ]
                        ]
                    ],
                    [
                        "role": "user",
                        "content": [
                            [
                                "type": "tool_result",
                                "tool_use_id": "toolu_backend",
                                "content": [
                                    [
                                        "type": "text",
                                        "text": "Found 8 backend files"
                                    ],
                                    [
                                        "type": "document",
                                        "source": [
                                            "type": "file",
                                            "file_id": "file_backend_1"
                                        ],
                                        "title": "backend-tree.txt"
                                    ]
                                ]
                            ]
                        ]
                    ],
                    [
                        "role": "user",
                        "content": "Summarize both inspections."
                    ]
                ],
                "max_tokens": 96,
                "stream": false
            ]
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let decoded = try JSONDecoder().decode(ClaudeMessageResponse.self, from: data)
        XCTAssertEqual(decoded.stopReason, "end_turn")
        XCTAssertEqual(decoded.usage.inputTokens, 55)
        XCTAssertEqual(decoded.usage.outputTokens, 8)
        XCTAssertEqual(firstTextBlock(in: decoded.content), "Both inspections are complete.")

        let requests = await upstream.recordedRequests()
        let upstreamRequest = try XCTUnwrap(requests.first)
        XCTAssertEqual(upstreamRequest.path, "/v1/responses")

        let upstreamBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: upstreamRequest.body) as? [String: Any]
        )
        let input = try XCTUnwrap(upstreamBody["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 9)

        XCTAssertEqual(input[0]["role"] as? String, "user")
        XCTAssertEqual(input[1]["role"] as? String, "assistant")
        XCTAssertEqual(input[1]["phase"] as? String, "commentary")
        XCTAssertEqual(input[2]["type"] as? String, "function_call")
        XCTAssertEqual(input[2]["call_id"] as? String, "toolu_frontend")
        XCTAssertEqual(input[3]["type"] as? String, "function_call_output")
        let firstToolOutput = try XCTUnwrap(input[3]["output"] as? [[String: Any]])
        XCTAssertEqual(firstToolOutput[0]["type"] as? String, "input_text")
        XCTAssertEqual(firstToolOutput[1]["type"] as? String, "input_image")
        XCTAssertEqual(firstToolOutput[1]["image_url"] as? String, "data:image/png;base64,DDDD")

        XCTAssertEqual(input[4]["role"] as? String, "user")
        XCTAssertEqual(input[5]["role"] as? String, "assistant")
        XCTAssertEqual(input[5]["phase"] as? String, "commentary")
        XCTAssertEqual(input[6]["type"] as? String, "function_call")
        XCTAssertEqual(input[6]["call_id"] as? String, "toolu_backend")
        XCTAssertEqual(input[7]["type"] as? String, "function_call_output")
        let secondToolOutput = try XCTUnwrap(input[7]["output"] as? [[String: Any]])
        XCTAssertEqual(secondToolOutput[0]["type"] as? String, "input_text")
        XCTAssertEqual(secondToolOutput[0]["text"] as? String, "Found 8 backend files")
        XCTAssertEqual(secondToolOutput[1]["type"] as? String, "input_file")
        XCTAssertEqual(secondToolOutput[1]["file_id"] as? String, "file_backend_1")
        XCTAssertEqual(secondToolOutput[1]["filename"] as? String, "backend-tree.txt")

        XCTAssertEqual(input[8]["role"] as? String, "user")
        let finalUserContent = try XCTUnwrap(input[8]["content"] as? [[String: Any]])
        XCTAssertEqual(finalUserContent[0]["text"] as? String, "Summarize both inspections.")
    }

    func testOpenAIResponsesProxyNonStreamingMapsHostedToolIncompleteToPauseTurnAndPreservesUsage() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            try MockHTTPResponse.json(
                object: [
                    "id": "resp-pause-turn-nonstream",
                    "object": "response",
                    "created_at": 1_710_000_190,
                    "model": "gpt-4o-mini",
                    "status": "incomplete",
                    "output": [
                        [
                            "id": "ws_pending",
                            "type": "web_search_call",
                            "status": "in_progress",
                            "action": [
                                "type": "search",
                                "query": "latest proxy docs"
                            ]
                        ]
                    ],
                    "usage": [
                        "input_tokens": 21,
                        "output_tokens": 2,
                        "total_tokens": 23,
                    ],
                ]
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(
                upstreamPort: upstreamPort,
                api: .responses,
                upstreamBaseURL: "http://127.0.0.1:\(upstreamPort)/v1"
            )
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try makeClaudeMessagesBody(stream: false)

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let decoded = try JSONDecoder().decode(ClaudeMessageResponse.self, from: data)
        XCTAssertEqual(decoded.stopReason, "pause_turn")
        XCTAssertEqual(decoded.usage.inputTokens, 21)
        XCTAssertEqual(decoded.usage.outputTokens, 2)
        XCTAssertEqual(firstTextBlock(in: decoded.content), "")
    }

    func testOpenAIResponsesProxyMapsDisableParallelToolUseToParallelToolCalls() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            try MockHTTPResponse.json(
                object: [
                    "id": "resp-parallel-tools",
                    "object": "response",
                    "created_at": 1_710_000_300,
                    "model": "gpt-4o-mini",
                    "status": "completed",
                    "output": [
                        [
                            "id": "msg-parallel-tools-1",
                            "type": "message",
                            "role": "assistant",
                            "status": "completed",
                            "content": [
                                [
                                    "type": "output_text",
                                    "text": "Handled one tool at a time.",
                                ],
                            ],
                        ],
                    ],
                    "usage": [
                        "input_tokens": 14,
                        "output_tokens": 7,
                        "total_tokens": 21,
                    ],
                ]
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(
                upstreamPort: upstreamPort,
                api: .responses,
                upstreamBaseURL: "http://127.0.0.1:\(upstreamPort)/v1"
            )
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": "claude-sonnet-4.5",
                "messages": [
                    [
                        "role": "user",
                        "content": "What's the weather?"
                    ]
                ],
                "tools": [
                    [
                        "name": "get_weather",
                        "description": "Get the weather",
                        "input_schema": [
                            "type": "object",
                            "properties": [
                                "location": [
                                    "type": "string"
                                ]
                            ],
                            "required": ["location"]
                        ]
                    ]
                ],
                "tool_choice": [
                    "type": "any",
                    "disable_parallel_tool_use": true
                ],
                "max_tokens": 64,
                "stream": false
            ]
        )

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let requests = await upstream.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let upstreamRequest = try XCTUnwrap(requests.first)
        XCTAssertEqual(upstreamRequest.path, "/v1/responses")

        let upstreamBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: upstreamRequest.body) as? [String: Any]
        )
        XCTAssertEqual(upstreamBody["parallel_tool_calls"] as? Bool, false)
    }

    func testOpenAIConvertProxyStreamingRoundTrip() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            MockHTTPResponse(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [
                    "data: {\"id\":\"chatcmpl-stream\",\"object\":\"chat.completion.chunk\",\"created\":1710000001,\"model\":\"gpt-4o-mini\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Hello\"},\"finish_reason\":null}]}\n\n",
                    "data: {\"id\":\"chatcmpl-stream\",\"object\":\"chat.completion.chunk\",\"created\":1710000001,\"model\":\"gpt-4o-mini\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\" world\"},\"finish_reason\":\"stop\"}]}\n\n",
                    "data: [DONE]\n\n",
                ],
                chunkDelayNanoseconds: 20_000_000
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort)
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try makeClaudeMessagesBody(stream: true)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")

        var lines: [String] = []
        for try await line in bytes.lines {
            lines.append(line)
        }

        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("event: message_start"))
        XCTAssertTrue(joined.contains("event: content_block_delta"))
        XCTAssertTrue(joined.contains("\"text\":\"Hello\""))
        XCTAssertTrue(joined.contains("\"text\":\" world\""))
        XCTAssertTrue(joined.contains("event: message_stop"))

        let messageStartJSON = try XCTUnwrap(ssePayloads(named: "message_start", from: lines).first)
        let messageStartPayload = Data(messageStartJSON.utf8)
        let messageStartEvent = try JSONDecoder().decode(ClaudeMessageStartEvent.self, from: messageStartPayload)
        XCTAssertTrue(messageStartEvent.message.content.isEmpty)
        XCTAssertNil(messageStartEvent.message.stopReason)
        XCTAssertNil(messageStartEvent.message.stopSequence)
        XCTAssertEqual(messageStartEvent.message.usage.inputTokens, 0)
        XCTAssertEqual(messageStartEvent.message.usage.outputTokens, 0)

        let requests = await upstream.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let upstreamBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(requests.first).body) as? [String: Any]
        )
        XCTAssertEqual(upstreamBody["stream"] as? Bool, true)
        XCTAssertEqual(upstreamBody["model"] as? String, "gpt-4o-mini")
    }

    func testOpenAIResponsesProxyStreamingRoundTrip() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            MockHTTPResponse(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [
                    "event: response.output_text.delta\n",
                    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_resp_stream\",\"output_index\":0,\"content_index\":0,\"delta\":\"Hello\"}\n\n",
                    "event: response.output_text.delta\n",
                    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_resp_stream\",\"output_index\":0,\"content_index\":0,\"delta\":\" responses\"}\n\n",
                    "event: response.completed\n",
                    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp-stream\",\"object\":\"response\",\"created_at\":1710000200,\"model\":\"gpt-4o-mini\",\"status\":\"completed\",\"output\":[{\"id\":\"msg_resp_stream\",\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello responses\"}]}],\"usage\":{\"input_tokens\":11,\"output_tokens\":7,\"total_tokens\":18}}}\n\n",
                ],
                chunkDelayNanoseconds: 20_000_000
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort, api: .responses)
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try makeClaudeMessagesBody(stream: true)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")

        var lines: [String] = []
        for try await line in bytes.lines {
            lines.append(line)
        }

        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("event: message_start"))
        XCTAssertTrue(joined.contains("event: content_block_delta"))
        XCTAssertTrue(joined.contains("\"text\":\"Hello\""))
        XCTAssertTrue(joined.contains("\"text\":\" responses\""))
        XCTAssertTrue(joined.contains("event: message_stop"))

        let messageStartJSON = try XCTUnwrap(ssePayloads(named: "message_start", from: lines).first)
        let messageStartPayload = Data(messageStartJSON.utf8)
        let messageStartEvent = try JSONDecoder().decode(ClaudeMessageStartEvent.self, from: messageStartPayload)
        XCTAssertTrue(messageStartEvent.message.content.isEmpty)
        XCTAssertNil(messageStartEvent.message.stopReason)
        XCTAssertNil(messageStartEvent.message.stopSequence)
        XCTAssertEqual(messageStartEvent.message.usage.inputTokens, 0)
        XCTAssertEqual(messageStartEvent.message.usage.outputTokens, 0)

        let requests = await upstream.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let upstreamRequest = try XCTUnwrap(requests.first)
        XCTAssertEqual(upstreamRequest.path, "/v1/responses")

        let upstreamBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: upstreamRequest.body) as? [String: Any]
        )
        XCTAssertNil(upstreamBody["messages"])
        XCTAssertNotNil(upstreamBody["input"])
        XCTAssertEqual(upstreamBody["stream"] as? Bool, true)
        XCTAssertEqual(upstreamBody["store"] as? Bool, false)
    }

    func testOpenAIResponsesProxyStreamingEmitsThinkingDeltaBeforeText() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            MockHTTPResponse(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [
                    "event: response.reasoning_summary_text.delta\n",
                    "data: {\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_stream\",\"output_index\":0,\"summary_index\":0,\"delta\":\"Need to verify the answer first.\"}\n\n",
                    "event: response.output_text.delta\n",
                    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_resp_stream\",\"output_index\":1,\"content_index\":0,\"delta\":\"Final\"}\n\n",
                    "event: response.output_text.delta\n",
                    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_resp_stream\",\"output_index\":1,\"content_index\":0,\"delta\":\" answer\"}\n\n",
                    "event: response.completed\n",
                    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp-stream-thinking\",\"object\":\"response\",\"created_at\":1710000200,\"model\":\"gpt-4o-mini\",\"status\":\"completed\",\"output\":[{\"id\":\"rs_stream\",\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"Need to verify the answer first.\"}],\"status\":\"completed\"},{\"id\":\"msg_resp_stream\",\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"Final answer\"}]}],\"usage\":{\"input_tokens\":11,\"output_tokens\":9,\"total_tokens\":20}}}\n\n"
                ],
                chunkDelayNanoseconds: 20_000_000
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort, api: .responses)
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try makeClaudeMessagesBody(stream: true)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")

        var lines: [String] = []
        for try await line in bytes.lines {
            lines.append(line)
        }

        let startPayloads = ssePayloads(named: "content_block_start", from: lines)
        let deltaPayloads = ssePayloads(named: "content_block_delta", from: lines)
        let stopPayloads = ssePayloads(named: "message_stop", from: lines)

        let thinkingStart = try XCTUnwrap(startPayloads.compactMap {
            try? JSONDecoder().decode(ClaudeContentBlockStartEvent.self, from: Data($0.utf8))
        }.first(where: { event in
            if case .thinking = event.contentBlock { return true }
            return false
        }))
        if case .thinking(let block) = thinkingStart.contentBlock {
            XCTAssertEqual(block.thinking, "")
        } else {
            XCTFail("Expected thinking block")
        }

        let textStart = try XCTUnwrap(startPayloads.compactMap {
            try? JSONDecoder().decode(ClaudeContentBlockStartEvent.self, from: Data($0.utf8))
        }.first(where: { event in
            if case .text = event.contentBlock { return true }
            return false
        }))
        if case .text(let block) = textStart.contentBlock {
            XCTAssertEqual(block.text, "")
        } else {
            XCTFail("Expected text block")
        }

        let deltaEvents = deltaPayloads.compactMap {
            try? JSONDecoder().decode(ClaudeContentBlockDeltaEvent.self, from: Data($0.utf8))
        }
        let thinkingDelta = try XCTUnwrap(deltaEvents.first(where: {
            if case .thinking = $0.delta { return true }
            return false
        }))
        if case .thinking(let delta) = thinkingDelta.delta {
            XCTAssertEqual(delta.thinking, "Need to verify the answer first.")
        }

        let textDeltas = deltaEvents.filter {
            if case .text = $0.delta { return true }
            return false
        }
        XCTAssertEqual(textDeltas.count, 2)
        if case .text(let delta) = textDeltas[0].delta {
            XCTAssertEqual(textDeltas[0].index, 1)
            XCTAssertEqual(delta.text, "Final")
        }
        if case .text(let delta) = textDeltas[1].delta {
            XCTAssertEqual(textDeltas[1].index, 1)
            XCTAssertEqual(delta.text, " answer")
        }
        XCTAssertFalse(stopPayloads.isEmpty)
    }

    func testOpenAIResponsesProxyStreamingMapsHostedToolIncompleteToPauseTurn() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            MockHTTPResponse(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [
                    "event: response.completed\n",
                    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp-pause-turn\",\"object\":\"response\",\"created_at\":1710000250,\"model\":\"gpt-4o-mini\",\"status\":\"incomplete\",\"output\":[{\"id\":\"ws_pending\",\"type\":\"web_search_call\",\"status\":\"in_progress\",\"action\":{\"type\":\"search\",\"query\":\"latest weather shanghai\"}}],\"usage\":{\"input_tokens\":11,\"output_tokens\":1,\"total_tokens\":12}}}\n\n",
                ],
                chunkDelayNanoseconds: 20_000_000
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort, api: .responses)
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try makeClaudeMessagesBody(stream: true)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        var lines: [String] = []
        for try await line in bytes.lines {
            lines.append(line)
        }

        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("\"stop_reason\":\"pause_turn\""))
        XCTAssertTrue(joined.contains("event: message_stop"))
    }

    func testOpenAIResponsesProxyBuffersToolArgumentDeltasUntilRealToolMetadataArrives() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            MockHTTPResponse(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [
                    "event: response.reasoning_summary_text.delta\n",
                    "data: {\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_stream\",\"output_index\":0,\"summary_index\":0,\"delta\":\"Need to consult the tool.\"}\n\n",
                    "event: response.function_call_arguments.delta\n",
                    "data: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_123\",\"output_index\":1,\"delta\":\"{\\\"location\\\":\\\"Shanghai\\\"}\"}\n\n",
                    "event: response.function_call_arguments.done\n",
                    "data: {\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc_123\",\"output_index\":1,\"arguments\":\"{\\\"location\\\":\\\"Shanghai\\\"}\",\"item\":{\"type\":\"function_call\",\"call_id\":\"call_789\",\"name\":\"get_weather\",\"arguments\":\"{\\\"location\\\":\\\"Shanghai\\\"}\",\"status\":\"completed\"}}\n\n",
                    "event: response.completed\n",
                    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp-stream-tool-buffer\",\"object\":\"response\",\"created_at\":1710000300,\"model\":\"gpt-4o-mini\",\"status\":\"completed\",\"output\":[{\"id\":\"rs_stream\",\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"Need to consult the tool.\"}],\"status\":\"completed\"},{\"type\":\"function_call\",\"call_id\":\"call_789\",\"name\":\"get_weather\",\"arguments\":\"{\\\"location\\\":\\\"Shanghai\\\"}\",\"status\":\"completed\"}],\"usage\":{\"input_tokens\":11,\"output_tokens\":5,\"total_tokens\":16}}}\n\n"
                ],
                chunkDelayNanoseconds: 20_000_000
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort, api: .responses)
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try makeClaudeMessagesBody(stream: true)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        var lines: [String] = []
        for try await line in bytes.lines {
            lines.append(line)
        }

        let startPayloads = ssePayloads(named: "content_block_start", from: lines)
        let deltaPayloads = ssePayloads(named: "content_block_delta", from: lines)

        let toolStart = try XCTUnwrap(startPayloads.compactMap {
            try? JSONDecoder().decode(ClaudeContentBlockStartEvent.self, from: Data($0.utf8))
        }.first(where: { event in
            if case .toolUse = event.contentBlock { return true }
            return false
        }))
        if case .toolUse(let block) = toolStart.contentBlock {
            XCTAssertEqual(block.id, "call_789")
            XCTAssertEqual(block.name, "get_weather")
        } else {
            XCTFail("Expected tool_use block")
        }

        let inputJSONDelta = try XCTUnwrap(deltaPayloads.compactMap {
            try? JSONDecoder().decode(ClaudeContentBlockDeltaEvent.self, from: Data($0.utf8))
        }.first(where: { event in
            if case .inputJson = event.delta { return true }
            return false
        }))
        if case .inputJson(let delta) = inputJSONDelta.delta {
            XCTAssertEqual(delta.partialJson, #"{"location":"Shanghai"}"#)
        }
    }

    func testOpenAIResponsesProxyFineGrainedToolStreamingAllowsPartialJSONAndMaxTokensStopReason() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { request in
            let upstreamBody = try XCTUnwrap(
                JSONSerialization.jsonObject(with: request.body) as? [String: Any]
            )
            XCTAssertEqual(upstreamBody["stream"] as? Bool, true)

            return MockHTTPResponse(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [
                    "event: response.output_item.added\n",
                    "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_partial\",\"name\":\"make_file\",\"arguments\":\"\",\"status\":\"in_progress\"}}\n\n",
                    "event: response.function_call_arguments.delta\n",
                    "data: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_partial\",\"output_index\":0,\"delta\":\"{\\\"filename\\\":\\\"poem.txt\\\",\\\"lines_of_text\\\":[\\\"Roses are red\\\"\"}\n\n",
                    "event: response.completed\n",
                    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_stream_partial_tool\",\"object\":\"response\",\"created_at\":1710000600,\"model\":\"gpt-4o-mini\",\"status\":\"incomplete\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"call_partial\",\"name\":\"make_file\",\"arguments\":\"{\\\"filename\\\":\\\"poem.txt\\\",\\\"lines_of_text\\\":[\\\"Roses are red\\\"\",\"status\":\"in_progress\"}],\"usage\":{\"input_tokens\":11,\"output_tokens\":5,\"total_tokens\":16}}}\n\n"
                ],
                chunkDelayNanoseconds: 20_000_000
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort, api: .responses)
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": "claude-sonnet-4.5",
                "messages": [
                    [
                        "role": "user",
                        "content": "Write a long poem and create a file."
                    ]
                ],
                "tools": [
                    [
                        "name": "make_file",
                        "description": "Write text to a file",
                        "eager_input_streaming": true,
                        "input_schema": [
                            "type": "object",
                            "properties": [
                                "filename": ["type": "string"],
                                "lines_of_text": [
                                    "type": "array",
                                    "items": ["type": "string"]
                                ]
                            ],
                            "required": ["filename", "lines_of_text"]
                        ]
                    ]
                ],
                "max_tokens": 32,
                "stream": true
            ]
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        var lines: [String] = []
        for try await line in bytes.lines {
            lines.append(line)
        }

        let startPayloads = ssePayloads(named: "content_block_start", from: lines)
        let deltaPayloads = ssePayloads(named: "content_block_delta", from: lines)
        let messageDeltaPayload = try XCTUnwrap(ssePayloads(named: "message_delta", from: lines).last)

        let toolStart = try XCTUnwrap(startPayloads.compactMap {
            try? JSONDecoder().decode(ClaudeContentBlockStartEvent.self, from: Data($0.utf8))
        }.first(where: { event in
            if case .toolUse = event.contentBlock { return true }
            return false
        }))
        if case .toolUse(let block) = toolStart.contentBlock {
            XCTAssertEqual(block.id, "call_partial")
            XCTAssertEqual(block.name, "make_file")
        }

        let inputJSONDelta = try XCTUnwrap(deltaPayloads.compactMap {
            try? JSONDecoder().decode(ClaudeContentBlockDeltaEvent.self, from: Data($0.utf8))
        }.first(where: { event in
            if case .inputJson = event.delta { return true }
            return false
        }))
        if case .inputJson(let delta) = inputJSONDelta.delta {
            XCTAssertEqual(delta.partialJson, #"{"filename":"poem.txt","lines_of_text":["Roses are red""#)
        }

        let messageDelta = try JSONDecoder().decode(ClaudeMessageDeltaEvent.self, from: Data(messageDeltaPayload.utf8))
        XCTAssertEqual(messageDelta.delta.stopReason, "max_tokens")
    }

    func testOpenAIResponsesProxyStreamingMapsUpstreamHTTP429ToClaudeRateLimitErrorEvent() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            try MockHTTPResponse.json(
                status: 429,
                object: [
                    "error": [
                        "message": "Too many requests",
                        "type": "rate_limit_error"
                    ]
                ],
                headers: [
                    "x-request-id": "req_stream_429"
                ]
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(
                upstreamPort: upstreamPort,
                api: .responses,
                upstreamBaseURL: "http://127.0.0.1:\(upstreamPort)/v1"
            )
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try makeClaudeMessagesBody(stream: true)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")

        var lines: [String] = []
        for try await line in bytes.lines {
            lines.append(line)
        }

        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("event: error"))
        XCTAssertTrue(joined.contains("\"type\":\"rate_limit_error\""))
        XCTAssertTrue(joined.contains("\"message\":\"Too many requests\""))
        XCTAssertTrue(joined.contains("\"request_id\":\"req_stream_429\""))
    }

    func testOpenAIConvertProxyStreamingPreservesUTF8Content() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            MockHTTPResponse(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [
                    "data: {\"id\":\"chatcmpl-stream-zh\",\"object\":\"chat.completion.chunk\",\"created\":1710000001,\"model\":\"gpt-4o-mini\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"你好\"},\"finish_reason\":null}]}\n\n",
                    "data: {\"id\":\"chatcmpl-stream-zh\",\"object\":\"chat.completion.chunk\",\"created\":1710000001,\"model\":\"gpt-4o-mini\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"，我可以帮你什么？\"},\"finish_reason\":\"stop\"}]}\n\n",
                    "data: [DONE]\n\n",
                ],
                chunkDelayNanoseconds: 20_000_000
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort)
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try makeClaudeMessagesBody(stream: true)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        var lines: [String] = []
        for try await line in bytes.lines {
            lines.append(line)
        }

        let textDeltas = ssePayloads(named: "content_block_delta", from: lines).compactMap { payload -> String? in
            guard
                let event = try? JSONDecoder().decode(ClaudeContentBlockDeltaEvent.self, from: Data(payload.utf8)),
                case .text(let delta) = event.delta
            else {
                return nil
            }
            return delta.text
        }

        XCTAssertEqual(textDeltas.joined(), "你好，我可以帮你什么？")
        XCTAssertFalse(textDeltas.joined().contains("ä½ å¥½"))
    }

    func testFilesListEndpointRequiresFilesBetaHeader() async throws {
        let upstreamPort = try findFreePort()
        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort)
        )
        try await server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/files")!)
        request.httpMethod = "GET"
        request.setValue("client-key", forHTTPHeaderField: "x-api-key")

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)

        let decoded = try JSONDecoder().decode(ClaudeErrorResponse.self, from: data)
        XCTAssertEqual(decoded.error.type, "invalid_request_error")
        XCTAssertTrue(decoded.error.message.contains("files-api-2025-04-14"))
    }

    func testFilesListAndMetadataEndpointsBridgeOpenAIFileMetadata() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { request in
            switch (request.method, request.path) {
            case ("GET", "/v1/files?limit=1&after=file_prev"):
                return try MockHTTPResponse.json(
                    object: [
                        "object": "list",
                        "data": [
                            [
                                "id": "file_123",
                                "object": "file",
                                "bytes": 42,
                                "created_at": 1_710_000_400,
                                "filename": "notes.md",
                                "purpose": "assistants",
                                "mime_type": "text/markdown",
                                "status": "processed",
                            ],
                        ],
                        "has_more": false,
                    ]
                )
            case ("GET", "/v1/files/file_123"):
                return try MockHTTPResponse.json(
                    object: [
                        "id": "file_123",
                        "object": "file",
                        "bytes": 42,
                        "created_at": 1_710_000_400,
                        "filename": "notes.md",
                        "purpose": "assistants",
                        "status": "processed",
                    ]
                )
            default:
                XCTFail("Unexpected upstream request: \(request.method) \(request.path)")
                return try MockHTTPResponse.json(status: 404, object: ["error": "not found"])
            }
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort)
        )
        try await server.start()
        defer { server.stop() }

        var listRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/files?limit=1&after_id=file_prev")!)
        listRequest.httpMethod = "GET"
        listRequest.setValue("client-key", forHTTPHeaderField: "x-api-key")
        listRequest.setValue("files-api-2025-04-14", forHTTPHeaderField: "anthropic-beta")

        let (listData, listResponse) = try await URLSession.shared.data(for: listRequest)
        XCTAssertEqual((listResponse as? HTTPURLResponse)?.statusCode, 200)

        let listDecoded = try JSONDecoder().decode(ClaudeFilesListResponse.self, from: listData)
        XCTAssertEqual(listDecoded.data.count, 1)
        XCTAssertEqual(listDecoded.firstId, "file_123")
        XCTAssertEqual(listDecoded.lastId, "file_123")
        XCTAssertEqual(listDecoded.data.first?.mimeType, "text/markdown")
        XCTAssertEqual(listDecoded.data.first?.sizeBytes, 42)

        var metadataRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/files/file_123")!)
        metadataRequest.httpMethod = "GET"
        metadataRequest.setValue("client-key", forHTTPHeaderField: "x-api-key")
        metadataRequest.setValue("files-api-2025-04-14", forHTTPHeaderField: "anthropic-beta")

        let (metadataData, metadataResponse) = try await URLSession.shared.data(for: metadataRequest)
        XCTAssertEqual((metadataResponse as? HTTPURLResponse)?.statusCode, 200)

        let metadataDecoded = try JSONDecoder().decode(ClaudeFileObject.self, from: metadataData)
        XCTAssertEqual(metadataDecoded.id, "file_123")
        XCTAssertEqual(metadataDecoded.filename, "notes.md")
        XCTAssertEqual(metadataDecoded.mimeType, "text/markdown")
        XCTAssertEqual(metadataDecoded.downloadable, true)

        let requests = await upstream.recordedRequests()
        XCTAssertEqual(requests.map(\.path), ["/v1/files?limit=1&after=file_prev", "/v1/files/file_123"])
    }

    func testFilesCreateEndpointBridgesAnthropicMultipartUploadToOpenAI() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { request in
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/v1/files")
            XCTAssertTrue(request.headers["content-type"]?.contains("multipart/form-data") ?? false)

            let body = request.bodyString
            XCTAssertTrue(body.contains("name=\"purpose\""))
            XCTAssertTrue(body.contains("user_data"))
            XCTAssertTrue(body.contains("name=\"file\"; filename=\"report.txt\""))
            XCTAssertTrue(body.contains("Content-Type: text/plain"))
            XCTAssertTrue(body.contains("hello from anthropic files"))

            return try MockHTTPResponse.json(
                object: [
                    "id": "file_uploaded",
                    "object": "file",
                    "bytes": 26,
                    "created_at": 1_710_000_500,
                    "filename": "report.txt",
                    "purpose": "user_data",
                    "mime_type": "text/plain",
                    "status": "processed",
                ]
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort)
        )
        try await server.start()
        defer { server.stop() }

        let uploadBody = makeAnthropicFilesUploadBody(
            boundary: "Boundary-Test-Upload",
            filename: "report.txt",
            mimeType: "text/plain",
            data: Data("hello from anthropic files".utf8)
        )

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/files")!)
        request.httpMethod = "POST"
        request.setValue("client-key", forHTTPHeaderField: "x-api-key")
        request.setValue("files-api-2025-04-14", forHTTPHeaderField: "anthropic-beta")
        request.setValue("multipart/form-data; boundary=Boundary-Test-Upload", forHTTPHeaderField: "Content-Type")
        request.httpBody = uploadBody

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let decoded = try JSONDecoder().decode(ClaudeFileObject.self, from: data)
        XCTAssertEqual(decoded.id, "file_uploaded")
        XCTAssertEqual(decoded.filename, "report.txt")
        XCTAssertEqual(decoded.mimeType, "text/plain")
        XCTAssertEqual(decoded.downloadable, true)
    }

    func testFilesDeleteEndpointBridgesOpenAIDelete() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { request in
            XCTAssertEqual(request.method, "DELETE")
            XCTAssertEqual(request.path, "/v1/files/file_123")
            return try MockHTTPResponse.json(
                object: [
                    "id": "file_123",
                    "object": "file",
                    "deleted": true,
                ]
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort)
        )
        try await server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/files/file_123")!)
        request.httpMethod = "DELETE"
        request.setValue("client-key", forHTTPHeaderField: "x-api-key")
        request.setValue("files-api-2025-04-14", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let decoded = try JSONDecoder().decode(ClaudeDeletedFileResponse.self, from: data)
        XCTAssertEqual(decoded.id, "file_123")
        XCTAssertTrue(decoded.deleted)
    }

    func testFilesContentEndpointBridgesBinaryContentFromOpenAI() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { request in
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.path, "/v1/files/file_123/content")
            return MockHTTPResponse(
                status: 200,
                headers: [
                    "Content-Type": "application/octet-stream",
                    "Content-Disposition": "attachment; filename=\"download.bin\"",
                ],
                bodyData: Data([0x00, 0x01, 0x02, 0xFF, 0x7A])
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: makeOpenAIProxyConfiguration(upstreamPort: upstreamPort)
        )
        try await server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/files/file_123/content")!)
        request.httpMethod = "GET"
        request.setValue("client-key", forHTTPHeaderField: "x-api-key")
        request.setValue("files-api-2025-04-14", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Disposition"), "attachment; filename=\"download.bin\"")
        XCTAssertEqual(data, Data([0x00, 0x01, 0x02, 0xFF, 0x7A]))
    }

    func testAnthropicPassthroughNonStreamingForwarding() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            try MockHTTPResponse.json(
                object: [
                    "id": "msg_passthrough",
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        [
                            "type": "text",
                            "text": "passthrough ok",
                        ],
                    ],
                    "model": "claude-3-5-sonnet-20241022",
                    "stop_reason": "end_turn",
                    "stop_sequence": NSNull(),
                    "usage": [
                        "input_tokens": 8,
                        "output_tokens": 4,
                    ],
                ]
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: ClaudeProxyConfiguration(
                enabled: true,
                bindPort: proxyPort,
                mode: .anthropicPassthrough,
                upstreamBaseURL: "http://127.0.0.1:\(upstreamPort)",
                upstreamAPIKey: "upstream-anthropic-key",
                expectedClientKey: "client-key"
            )
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try makeClaudeMessagesBody(stream: false)

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let decoded = try JSONDecoder().decode(ClaudeMessageResponse.self, from: data)
        XCTAssertEqual(firstTextBlock(in: decoded.content), "passthrough ok")

        let requests = await upstream.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let upstreamRequest = try XCTUnwrap(requests.first)
        XCTAssertEqual(upstreamRequest.path, "/v1/messages")
        XCTAssertEqual(upstreamRequest.headers["x-api-key"], "upstream-anthropic-key")
    }

    func testAnthropicPassthrough1MVariantSendsBetaAndBaseModel() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            try MockHTTPResponse.json(
                object: [
                    "id": "msg_1m",
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "text", "text": "ok"]],
                    "model": "claude-sonnet-4-5-20250929",
                    "stop_reason": "end_turn",
                    "stop_sequence": NSNull(),
                    "usage": ["input_tokens": 8, "output_tokens": 2],
                ]
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: ClaudeProxyConfiguration(
                enabled: true,
                bindPort: proxyPort,
                mode: .anthropicPassthrough,
                upstreamBaseURL: "http://127.0.0.1:\(upstreamPort)",
                upstreamAPIKey: "upstream-anthropic-key",
                expectedClientKey: "client-key"
            )
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(proxyPort: proxyPort, clientKey: "client-key")
        request.setValue("interleaved-thinking-2025-05-14", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": "claude-sonnet-4-5-20250929\(ClaudeContext1M.variantSuffix)",
                "messages": [["role": "user", "content": "Say hello"]],
                "max_tokens": 64,
                "stream": false,
            ]
        )

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let recorded = await upstream.recordedRequests()
        let upstreamRequest = try XCTUnwrap(recorded.first)
        let betas = Set(
            (upstreamRequest.headers["anthropic-beta"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        )
        XCTAssertTrue(betas.contains(ClaudeContext1M.beta))
        XCTAssertTrue(betas.contains("interleaved-thinking-2025-05-14"))

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: upstreamRequest.body) as? [String: Any]
        )
        // Anthropic rejects the bracketed id as an unknown model.
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-4-5-20250929")
    }

    func testAnthropicPassthroughStreamingPreservesMultiToolEventBoundaries() async throws {
        let upstreamPort = try findFreePort()
        let upstreamBody = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_passthrough_stream","type":"message","role":"assistant","content":[],"model":"claude-3-5-sonnet-20241022","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":20,"output_tokens":0}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_weather","name":"get_weather","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"city\\":\\"Shanghai\\"}"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_time","name":"get_time","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"timezone\\":\\"Asia/Shanghai\\"}"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":1}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":12}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            MockHTTPResponse(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: upstreamBody
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let proxyPort = try findFreePort()
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            proxyConfig: ClaudeProxyConfiguration(
                enabled: true,
                bindPort: proxyPort,
                mode: .anthropicPassthrough,
                upstreamBaseURL: "http://127.0.0.1:\(upstreamPort)",
                upstreamAPIKey: "upstream-anthropic-key",
                expectedClientKey: "client-key"
            )
        )
        try await server.start()
        defer { server.stop() }

        var request = makeClaudeMessagesRequest(
            proxyPort: proxyPort,
            clientKey: "client-key"
        )
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": "claude-3-5-sonnet-20241022",
                "messages": [
                    [
                        "role": "user",
                        "content": "Run two tools"
                    ]
                ],
                "stream": true,
                "max_tokens": 256
            ]
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")

        let responseBody = String(data: data, encoding: .utf8)
        XCTAssertEqual(responseBody, upstreamBody)
        XCTAssertTrue(try XCTUnwrap(responseBody).contains("\n\nevent: content_block_start\n"))
        XCTAssertTrue(try XCTUnwrap(responseBody).contains("\"stop_reason\":\"tool_use\""))
    }

    private func makeOpenAIProxyConfiguration(
        upstreamPort: Int,
        api: OpenAIUpstreamAPI = .chatCompletions,
        upstreamBaseURL: String? = nil
    ) -> ClaudeProxyConfiguration {
        ClaudeProxyConfiguration(
            enabled: true,
            bindPort: 4318,
            mode: .openaiConvert,
            upstreamBaseURL: upstreamBaseURL ?? "http://127.0.0.1:\(upstreamPort)",
            openAIUpstreamAPI: api,
            upstreamAPIKey: "upstream-key",
            expectedClientKey: "client-key",
            bigModel: "gpt-4.1",
            middleModel: "gpt-4o-mini",
            smallModel: "gpt-4.1-nano",
            maxOutputTokens: 512
        )
    }

    private func makeClaudeMessagesRequest(proxyPort: Int, clientKey: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(clientKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 10
        return request
    }

    private func makeClaudeMessagesBody(stream: Bool) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "model": "claude-3-5-sonnet-20241022",
                "messages": [
                    [
                        "role": "user",
                        "content": "Say hello",
                    ],
                ],
                "max_tokens": 64,
                "stream": stream,
            ]
        )
    }

    private func makeAnthropicFilesUploadBody(
        boundary: String,
        filename: String,
        mimeType: String,
        data: Data
    ) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private func firstTextBlock(in blocks: [ClaudeContentBlock]) -> String? {
        for block in blocks {
            if case .text(let textBlock) = block {
                return textBlock.text
            }
        }
        return nil
    }

    private func ssePayloads(named eventName: String, from lines: [String]) -> [String] {
        var currentEvent: String?
        var payloads: [String] = []

        for line in lines {
            if line.hasPrefix("event: ") {
                currentEvent = String(line.dropFirst("event: ".count))
            } else if line.hasPrefix("data: "), currentEvent == eventName {
                payloads.append(String(line.dropFirst("data: ".count)))
            } else if line.isEmpty {
                currentEvent = nil
            }
        }

        return payloads
    }
}
