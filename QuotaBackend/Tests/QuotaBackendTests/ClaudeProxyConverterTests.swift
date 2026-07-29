import XCTest
@testable import QuotaBackend

final class ClaudeProxyConverterTests: XCTestCase {

    func testDesktopAndCodeUseIndependentClientKeys() {
        let config = ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "https://example.com",
            upstreamAPIKey: "upstream",
            expectedClientKey: "code-key",
            expectedDesktopClientKey: "desktop-key"
        )

        XCTAssertEqual(
            config.authenticatedSurface(headers: ["authorization": "Bearer code-key"]),
            .code
        )
        XCTAssertEqual(
            config.authenticatedSurface(headers: [
                "x-api-key": "stale-key",
                "authorization": "bearer code-key",
            ]),
            .code,
            "a stale secondary header must not mask a valid credential"
        )
        XCTAssertEqual(
            config.authenticatedSurface(headers: ["x-api-key": "desktop-key"]),
            .desktop
        )
        XCTAssertEqual(
            config.authenticatedSurface(
                headers: ["authorization": "Bearer desktop-key"],
                hintedSurface: .desktop
            ),
            .desktop
        )
        XCTAssertNil(
            config.authenticatedSurface(
                headers: ["authorization": "Bearer code-key"],
                hintedSurface: .desktop
            )
        )
    }

    // MARK: - Configuration Tests

    func testModelNormalization() {
        XCTAssertEqual(ClaudeProxyConfiguration.normalizeModelName("claude-sonnet-4.5"), "sonnet")
        XCTAssertEqual(ClaudeProxyConfiguration.normalizeModelName("claude-3-5-haiku-20241022"), "haiku")
        XCTAssertEqual(ClaudeProxyConfiguration.normalizeModelName("claude-opus-4"), "opus")
        XCTAssertEqual(ClaudeProxyConfiguration.normalizeModelName("claude-3-opus-20240229"), "opus")
        XCTAssertEqual(ClaudeProxyConfiguration.normalizeModelName("sonnet"), "sonnet")
        XCTAssertEqual(ClaudeProxyConfiguration.normalizeModelName("haiku"), "haiku")
        XCTAssertEqual(ClaudeProxyConfiguration.normalizeModelName("opus"), "opus")
        XCTAssertEqual(ClaudeProxyConfiguration.normalizeModelName("unknown-model"), "unknown-model")
    }

    func testModelMapping() {
        let config = ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "https://api.openai.com",
            upstreamAPIKey: "test-key",
            bigModel: "gpt-4o",
            middleModel: "gpt-4o",
            smallModel: "gpt-4o-mini"
        )

        XCTAssertEqual(config.mapToUpstreamModel("claude-sonnet-4.5"), "gpt-4o")
        XCTAssertEqual(config.mapToUpstreamModel("claude-3-5-haiku-20241022"), "gpt-4o-mini")
        XCTAssertEqual(config.mapToUpstreamModel("claude-opus-4"), "gpt-4o")
        XCTAssertEqual(config.mapToUpstreamModel("claude-opus-4-8"), "gpt-4o")
        XCTAssertEqual(config.mapToUpstreamModel("sonnet"), "gpt-4o")
        XCTAssertEqual(config.mapToUpstreamModel("haiku"), "gpt-4o-mini")
        XCTAssertEqual(config.mapToUpstreamModel("opus"), "gpt-4o")
        XCTAssertEqual(config.mapToUpstreamModel("unknown"), "unknown")
    }

    func testProductGatewayMapsAliasOnceAndNodeRuntimePreservesExactModel() {
        let exactModel = "provider/opus-production"
        let productGateway = ClaudeProxyConfiguration(
            enabled: true,
            mode: .anthropicPassthrough,
            upstreamBaseURL: "http://127.0.0.1:18081",
            upstreamAPIKey: "node-key",
            bigModel: exactModel,
            middleModel: "provider/sonnet-production",
            smallModel: "provider/haiku-production",
            enableModelAliasMapping: true,
            availableModels: [
                exactModel,
                "provider/sonnet-production",
                "provider/haiku-production",
            ],
            preferExactCatalogModels: true
        )
        let nodeRuntime = ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "https://api.example.com",
            upstreamAPIKey: "upstream-key",
            bigModel: "must-not-remap",
            middleModel: "must-not-remap",
            smallModel: "must-not-remap",
            enableModelAliasMapping: false,
            availableModels: [exactModel],
            preferExactCatalogModels: true
        )

        let productOutput = productGateway.mapToUpstreamModel("claude-opus-4-6")
        XCTAssertEqual(productOutput, exactModel)
        XCTAssertEqual(nodeRuntime.mapToUpstreamModel(productOutput), exactModel)
    }

    func testScienceCatalogAliasesResolveToExactActiveNodeModels() throws {
        let config = ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "https://api.openai.com",
            upstreamAPIKey: "test-key",
            bigModel: "legacy-big",
            middleModel: "legacy-middle",
            smallModel: "legacy-small",
            availableModels: [
                " glm-5.2 ",
                "claude-sonnet-4-5",
                "glm-5.2",
                "bad\nmodel",
            ],
            defaultModel: "glm-5.2",
            exposeScienceModelCatalog: true,
            preferExactCatalogModels: true
        )

        XCTAssertEqual(config.availableModels, ["glm-5.2", "claude-sonnet-4-5"])
        XCTAssertTrue(config.exposeScienceModelCatalog)
        XCTAssertEqual(
            config.scienceCatalogModels.map(\.upstreamModel),
            ["glm-5.2", "claude-sonnet-4-5"]
        )
        let defaultID = try XCTUnwrap(config.scienceDefaultModelID)
        XCTAssertEqual(config.scienceCatalogModels.first?.id, defaultID)
        XCTAssertEqual(config.scienceCatalogModels.first?.displayName, "glm-5.2")

        let nativeClaudeAlias = try XCTUnwrap(
            config.scienceCatalogModels.first { $0.upstreamModel == "claude-sonnet-4-5" }?.id
        )
        XCTAssertNotEqual(nativeClaudeAlias, defaultID)
        XCTAssertEqual(config.mapToUpstreamModel(nativeClaudeAlias), "claude-sonnet-4-5")
        XCTAssertEqual(config.mapToUpstreamModel(defaultID), "glm-5.2")
        XCTAssertEqual(config.mapToUpstreamModel("claude-sonnet-4-5"), "claude-sonnet-4-5")
    }

    func testPersistentDefaultSelectionMapsToCurrentDefaultWithoutAddingLegacyRows() {
        let config = ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "https://api.openai.com",
            upstreamAPIKey: "test-key",
            bigModel: "legacy-big",
            middleModel: "legacy-middle",
            smallModel: "legacy-small",
            availableModels: ["new-default"],
            defaultModel: "new-default",
            exposeScienceModelCatalog: true,
            preferExactCatalogModels: true
        )

        XCTAssertEqual(config.scienceCatalogModels.map(\.upstreamModel), ["new-default"])
        XCTAssertEqual(config.scienceCatalogModels.map(\.id), ["claude-opus-4-8"])
        XCTAssertEqual(config.mapToUpstreamModel("claude-aiusage-v1-old-node-deadbeef"), "new-default")
        XCTAssertEqual(config.mapToUpstreamModel("claude-opus-4-8"), "new-default")
        XCTAssertEqual(config.mapToUpstreamModel("claude-sonnet-5"), "legacy-middle")
        XCTAssertEqual(config.mapToUpstreamModel("claude-haiku-4-5"), "legacy-small")
    }

    func testSciencePresentationNameAvoidsInternalMaskWithoutChangingRawRoutingID() {
        let kebab = "codex-auto-review"
        let guarded = ScienceModelProtocolAdapter.presentationName(for: kebab)
        XCTAssertEqual(guarded, ScienceModelProtocolAdapter.presentationGuard + kebab)
        XCTAssertEqual(
            String(guarded.dropFirst(ScienceModelProtocolAdapter.presentationGuard.count)),
            kebab
        )
        XCTAssertTrue(ScienceModelProtocolAdapter.presentationNameNeedsGuard("Claude gemini-pro-agent"))
        XCTAssertTrue(ScienceModelProtocolAdapter.presentationNameNeedsGuard("Claude   gemini-pro-agent"))
        XCTAssertTrue(ScienceModelProtocolAdapter.presentationNameNeedsGuard("🧪-model"))
        XCTAssertFalse(ScienceModelProtocolAdapter.presentationNameNeedsGuard("gemini-3.1-flash"))
        XCTAssertFalse(ScienceModelProtocolAdapter.presentationNameNeedsGuard("ZhipuAI/GLM-5.2"))
        XCTAssertEqual(
            ScienceModelProtocolAdapter.presentationName(for: "gpt-5.4"),
            "gpt-5.4"
        )

        let config = ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "https://api.openai.com",
            upstreamAPIKey: "test-key",
            availableModels: [kebab],
            defaultModel: kebab,
            exposeScienceModelCatalog: true,
            preferExactCatalogModels: true
        )
        XCTAssertEqual(config.availableModels, [kebab])
        XCTAssertEqual(config.mapToUpstreamModel(config.scienceDefaultModelID ?? ""), kebab)
        XCTAssertFalse(config.availableModels[0].contains(ScienceModelProtocolAdapter.presentationGuard))
    }

    func testScienceAliasIsDeterministicAndCaseSensitive() {
        XCTAssertEqual(
            ScienceModelProtocolAdapter.generatedSelectionID(for: "ZhipuAI/GLM-5.2"),
            ScienceModelProtocolAdapter.generatedSelectionID(for: "ZhipuAI/GLM-5.2")
        )
        XCTAssertNotEqual(
            ScienceModelProtocolAdapter.generatedSelectionID(for: "glm-5.2"),
            ScienceModelProtocolAdapter.generatedSelectionID(for: "GLM-5.2")
        )
    }

    func testDesktopCatalogUsesSafeRoutesDisplayNamesAndPerModel1M() throws {
        XCTAssertFalse(ScienceModelProtocolAdapter.isDesktopSafeModelID(
            "claude-sonnet-aiusage-v1-codex-auto-review-d9cd0070df74"
        ))
        let upstreams = [
            "gpt-5.4",
            "anthropic/claude-opus-4-8",
            "provider/speed-haiku",
            "codex-auto-review",
        ]
        let config = ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "https://api.example.com",
            upstreamAPIKey: "test-key",
            availableModels: upstreams,
            defaultModel: "gpt-5.4",
            exposeScienceModelCatalog: true,
            preferExactCatalogModels: true,
            catalogRouteStyle: .desktop,
            catalogSupports1M: ["gpt-5.4"]
        )

        XCTAssertEqual(config.scienceCatalogModels.map(\.displayName), upstreams)
        XCTAssertTrue(config.scienceCatalogModels.allSatisfy {
            ScienceModelProtocolAdapter.isDesktopSafeModelID($0.id)
        })
        XCTAssertTrue(config.scienceCatalogModels[0].id.hasPrefix("claude-sonnet-4-6-aiusage-v1-"))
        XCTAssertEqual(config.scienceCatalogModels[1].id, "anthropic/claude-opus-4-8")
        XCTAssertTrue(config.scienceCatalogModels[2].id.hasPrefix("claude-haiku-4-6-aiusage-v1-"))
        XCTAssertTrue(config.scienceCatalogModels[3].id.hasPrefix("claude-sonnet-4-6-aiusage-v1-"))
        XCTAssertFalse(config.scienceCatalogModels[3].id.contains("codex"))
        XCTAssertTrue(config.scienceCatalogModels[0].supports1M)
        XCTAssertFalse(config.scienceCatalogModels[1].supports1M)

        let generatedRoute = try XCTUnwrap(config.scienceCatalogModels.first?.id)
        XCTAssertEqual(config.mapToUpstreamModel(generatedRoute), "gpt-5.4")
    }

    func testDesktopStableTierRoutesMapThroughCurrentGatewayNode() {
        let routes = [
            ScienceModelProtocolAdapter.defaultRouteID,
            ScienceModelProtocolAdapter.opusRouteID,
            ScienceModelProtocolAdapter.sonnetRouteID,
            ScienceModelProtocolAdapter.haikuRouteID,
        ]
        let config = ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "https://api.example.com",
            upstreamAPIKey: "test-key",
            bigModel: "node-a-large",
            middleModel: "node-a-balanced",
            smallModel: "node-a-fast",
            availableModels: routes,
            defaultModel: "node-a-default",
            exposeScienceModelCatalog: true,
            preferExactCatalogModels: true,
            catalogRouteStyle: .desktop,
            mapDesktopTierRoutes: true
        )

        XCTAssertEqual(
            config.scienceCatalogModels.map(\.id),
            routes,
            "stable Desktop route identities must survive catalog projection"
        )
        XCTAssertEqual(
            config.scienceCatalogModels.map(\.displayName),
            ["AIUsage", "AIUsage Opus", "AIUsage Sonnet", "AIUsage Haiku"]
        )
        XCTAssertEqual(config.mapToUpstreamModel(routes[0]), "node-a-default")
        XCTAssertEqual(config.mapToUpstreamModel(routes[1]), "node-a-large")
        XCTAssertEqual(config.mapToUpstreamModel(routes[2]), "node-a-balanced")
        XCTAssertEqual(config.mapToUpstreamModel(routes[3]), "node-a-fast")
    }

    func testCodeSmartRoutesRemainStableWhileGatewayMappingChanges() {
        XCTAssertEqual(ScienceModelProtocolAdapter.defaultRouteID, "claude-aiusage")
        let routes = [
            ScienceModelProtocolAdapter.defaultRouteID,
            ScienceModelProtocolAdapter.opusRouteID,
            ScienceModelProtocolAdapter.sonnetRouteID,
            ScienceModelProtocolAdapter.haikuRouteID,
        ]
        let firstNode = ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "https://first.example.com",
            upstreamAPIKey: "first-key",
            bigModel: "GLM-5.2",
            middleModel: "provider/sonnet-a",
            smallModel: "provider/haiku-a",
            availableModels: routes,
            defaultModel: "provider/default-a",
            exposeScienceModelCatalog: true,
            preferExactCatalogModels: true,
            catalogRouteStyle: .code,
            mapDesktopTierRoutes: true
        )
        let secondNode = ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "https://second.example.com",
            upstreamAPIKey: "second-key",
            bigModel: "provider/opus-b",
            middleModel: "provider/sonnet-b",
            smallModel: "provider/haiku-b",
            availableModels: routes,
            defaultModel: "provider/default-b",
            exposeScienceModelCatalog: true,
            preferExactCatalogModels: true,
            catalogRouteStyle: .code,
            mapDesktopTierRoutes: true
        )

        XCTAssertEqual(firstNode.scienceCatalogModels.map(\.id), routes)
        XCTAssertEqual(secondNode.scienceCatalogModels.map(\.id), routes)
        XCTAssertEqual(firstNode.mapToUpstreamModel(routes[0]), "provider/default-a")
        XCTAssertEqual(secondNode.mapToUpstreamModel(routes[0]), "provider/default-b")
        XCTAssertEqual(firstNode.mapToUpstreamModel(routes[1]), "GLM-5.2")
        XCTAssertEqual(secondNode.mapToUpstreamModel(routes[1]), "provider/opus-b")
        XCTAssertEqual(
            firstNode.scienceCatalogModels.map(\.displayName),
            ["AIUsage", "AIUsage Opus", "AIUsage Sonnet", "AIUsage Haiku"]
        )
    }

    func testDesktopFullCatalogPublishesOnlyExactNodeModels() {
        let realModels = ["GLM-5.2", "provider/custom-opus"]
        let config = ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "https://api.example.com",
            upstreamAPIKey: "test-key",
            bigModel: "app-opus-override",
            middleModel: "app-sonnet-override",
            smallModel: "app-haiku-override",
            availableModels: realModels,
            defaultModel: realModels[0],
            exposeScienceModelCatalog: true,
            preferExactCatalogModels: true,
            catalogRouteStyle: .desktop,
            mapDesktopTierRoutes: false
        )

        XCTAssertEqual(config.scienceCatalogModels.map(\.upstreamModel), realModels)
        XCTAssertEqual(config.mapToUpstreamModel(realModels[0]), realModels[0])
        XCTAssertEqual(config.mapToUpstreamModel(realModels[1]), realModels[1])
    }

    func testCodeFullCatalogPublishesAndRoutesExactModelIDs() {
        let models = ["GLM-5.2", "provider/custom-opus", "claude-sonnet-private"]
        let config = ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "https://api.example.com",
            upstreamAPIKey: "test-key",
            bigModel: "must-not-remap",
            middleModel: "must-not-remap",
            smallModel: "must-not-remap",
            availableModels: models,
            defaultModel: models[0],
            exposeScienceModelCatalog: true,
            preferExactCatalogModels: true,
            catalogRouteStyle: .code,
            mapDesktopTierRoutes: false
        )

        XCTAssertEqual(config.scienceCatalogModels.map(\.id), models)
        XCTAssertEqual(config.scienceCatalogModels.map(\.displayName), models)
        for model in models {
            XCTAssertEqual(config.mapToUpstreamModel(model), model)
        }
    }

    func testDesktopFullCatalogDoesNotGuessStableTierRouteFromRealModelName() {
        let realModel = ScienceModelProtocolAdapter.opusRouteID
        let config = ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "https://api.example.com",
            upstreamAPIKey: "test-key",
            bigModel: "different-tier-target",
            availableModels: [realModel],
            defaultModel: realModel,
            exposeScienceModelCatalog: true,
            preferExactCatalogModels: true,
            catalogRouteStyle: .desktop,
            mapDesktopTierRoutes: false
        )

        XCTAssertEqual(config.mapToUpstreamModel(realModel), realModel)
    }

    func testRawCatalogIDThatLooksGeneratedStillRoutesExactly() {
        let raw = "claude-aiusage-v1-upstream-owned-model"
        let config = ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "https://api.openai.com",
            upstreamAPIKey: "test-key",
            availableModels: ["current-default", raw],
            defaultModel: "current-default",
            exposeScienceModelCatalog: true,
            preferExactCatalogModels: true
        )

        XCTAssertEqual(config.mapToUpstreamModel(raw), raw)
    }

    func testScienceDefaultBridgeDoesNotCollideWithRealNonDefaultOpusID() throws {
        let config = ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "https://api.openai.com",
            upstreamAPIKey: "test-key",
            availableModels: ["current-default", "claude-opus-4-8"],
            defaultModel: "current-default",
            exposeScienceModelCatalog: true,
            preferExactCatalogModels: true
        )

        let realOpus = try XCTUnwrap(
            config.scienceCatalogModels.first { $0.upstreamModel == "claude-opus-4-8" }
        )
        let defaultID = try XCTUnwrap(config.scienceDefaultModelID)
        XCTAssertEqual(config.scienceCatalogModels.count, 2)
        XCTAssertEqual(Set(config.scienceCatalogModels.map(\.id)).count, 2)
        XCTAssertEqual(
            config.scienceCatalogModels.map(\.upstreamModel),
            ["current-default", "claude-opus-4-8"]
        )
        XCTAssertNotEqual(realOpus.id, defaultID)
        XCTAssertEqual(config.mapToUpstreamModel(realOpus.id), "claude-opus-4-8")
        XCTAssertEqual(config.mapToUpstreamModel(defaultID), "current-default")
    }

    func testConfigurationValidation() {
        var config = ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "https://api.openai.com",
            upstreamAPIKey: "test-key"
        )

        XCTAssertNoThrow(try config.validate())

        // Test invalid port
        config = ClaudeProxyConfiguration(
            enabled: true,
            bindPort: 0,
            upstreamBaseURL: "https://api.openai.com",
            upstreamAPIKey: "test-key"
        )
        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidPort)
        }

        // Test empty API key
        config = ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "https://api.openai.com",
            upstreamAPIKey: ""
        )
        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error as? ConfigurationError, .missingAPIKey)
        }
    }

    func testNormalizeOpenAIBaseURL() {
        XCTAssertEqual(
            ClaudeProxyConfiguration.normalizeOpenAIBaseURL("https://api.openai.com/v1"),
            "https://api.openai.com"
        )
        XCTAssertEqual(
            ClaudeProxyConfiguration.normalizeOpenAIBaseURL("https://api.openai.com/v1/chat/completions"),
            "https://api.openai.com"
        )
        XCTAssertEqual(
            ClaudeProxyConfiguration.normalizeOpenAIBaseURL("https://example.com/openai/v1/responses"),
            "https://example.com/openai"
        )
        XCTAssertEqual(
            ClaudeProxyConfiguration.normalizeOpenAIBaseURL("https://example.com/proxy-root"),
            "https://example.com/proxy-root"
        )
    }

    // MARK: - Claude to OpenAI Conversion Tests

    func testConvertSimpleTextMessage() throws {
        let converter = ClaudeToOpenAIConverter()

        let claudeRequest = ClaudeMessageRequest(
            model: "claude-sonnet-4.5",
            messages: [
                ClaudeMessage(role: "user", content: .text("Hello, world!"))
            ],
            maxTokens: 1024
        )

        let openAIRequest = try converter.convert(request: claudeRequest, upstreamModel: "gpt-4o")

        XCTAssertEqual(openAIRequest.model, "gpt-4o")
        XCTAssertEqual(openAIRequest.messages.count, 1)
        XCTAssertEqual(openAIRequest.messages[0].role, "user")

        if case .text(let content) = openAIRequest.messages[0].content {
            XCTAssertEqual(content, "Hello, world!")
        } else {
            XCTFail("Expected text content")
        }
    }

    func testConvertSystemMessage() throws {
        let converter = ClaudeToOpenAIConverter()

        let claudeRequest = ClaudeMessageRequest(
            model: "claude-sonnet-4.5",
            messages: [
                ClaudeMessage(role: "user", content: .text("Hello"))
            ],
            system: "You are a helpful assistant.",
            maxTokens: 1024
        )

        let openAIRequest = try converter.convert(request: claudeRequest, upstreamModel: "gpt-4o")

        XCTAssertEqual(openAIRequest.messages.count, 2)
        XCTAssertEqual(openAIRequest.messages[0].role, "system")

        if case .text(let content) = openAIRequest.messages[0].content {
            XCTAssertEqual(content, "You are a helpful assistant.")
        } else {
            XCTFail("Expected text content")
        }
    }

    func testDecodeStructuredSystemBlocksPreservesJoinedTextAndRawBlocks() throws {
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "model": "claude-sonnet-4.5",
                "messages": [
                    [
                        "role": "user",
                        "content": "Hello"
                    ]
                ],
                "system": [
                    [
                        "type": "text",
                        "text": "You are a helpful assistant.",
                        "cache_control": [
                            "type": "ephemeral"
                        ]
                    ],
                    [
                        "type": "text",
                        "text": "Prefer concise answers."
                    ]
                ],
                "max_tokens": 1024
            ]
        )

        let request = try JSONDecoder().decode(ClaudeMessageRequest.self, from: payload)
        XCTAssertEqual(request.system, "You are a helpful assistant.\nPrefer concise answers.")
        XCTAssertEqual(request.systemBlocks?.count, 2)
        XCTAssertEqual(request.systemBlocks?.first?.text, "You are a helpful assistant.")
        XCTAssertEqual(request.systemBlocks?.first?.cacheControl?["type"]?.value as? String, "ephemeral")
    }

    func testEncodeStructuredSystemBlocksPreservesArrayShape() throws {
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "model": "claude-sonnet-4.5",
                "messages": [
                    [
                        "role": "user",
                        "content": "Hello"
                    ]
                ],
                "system": [
                    [
                        "type": "text",
                        "text": "You are a helpful assistant.",
                        "cache_control": [
                            "type": "ephemeral"
                        ]
                    ],
                    [
                        "type": "text",
                        "text": "Prefer concise answers."
                    ]
                ],
                "max_tokens": 1024
            ]
        )

        let request = try JSONDecoder().decode(ClaudeMessageRequest.self, from: payload)
        let encoded = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let system = try XCTUnwrap(json["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 2)
        XCTAssertEqual(system[0]["text"] as? String, "You are a helpful assistant.")
        let cacheControl = try XCTUnwrap(system[0]["cache_control"] as? [String: Any])
        XCTAssertEqual(cacheControl["type"] as? String, "ephemeral")
    }

    func testEncodeStructuredTokenCountSystemBlocksPreservesArrayShape() throws {
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "model": "claude-sonnet-4.5",
                "messages": [
                    [
                        "role": "user",
                        "content": "Hello"
                    ]
                ],
                "system": [
                    [
                        "type": "text",
                        "text": "You are a helpful assistant."
                    ],
                    [
                        "type": "text",
                        "text": "Prefer concise answers.",
                        "cache_control": [
                            "type": "ephemeral"
                        ]
                    ]
                ]
            ]
        )

        let request = try JSONDecoder().decode(ClaudeTokenCountRequest.self, from: payload)
        let encoded = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let system = try XCTUnwrap(json["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 2)
        XCTAssertEqual(system[1]["text"] as? String, "Prefer concise answers.")
        let cacheControl = try XCTUnwrap(system[1]["cache_control"] as? [String: Any])
        XCTAssertEqual(cacheControl["type"] as? String, "ephemeral")
    }

    func testConvertImageMessage() throws {
        let converter = ClaudeToOpenAIConverter()

        let imageSource = ClaudeImageSource(
            type: "base64",
            mediaType: "image/png",
            data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        )

        let claudeRequest = ClaudeMessageRequest(
            model: "claude-sonnet-4.5",
            messages: [
                ClaudeMessage(role: "user", content: .blocks([
                    .text(ClaudeTextBlock(text: "What's in this image?")),
                    .image(ClaudeImageBlock(source: imageSource))
                ]))
            ],
            maxTokens: 1024
        )

        let openAIRequest = try converter.convert(request: claudeRequest, upstreamModel: "gpt-4o")

        XCTAssertEqual(openAIRequest.messages.count, 1)

        if case .parts(let parts) = openAIRequest.messages[0].content {
            XCTAssertEqual(parts.count, 2)

            if case .text(let textPart) = parts[0] {
                XCTAssertEqual(textPart.text, "What's in this image?")
            } else {
                XCTFail("Expected text part")
            }

            if case .imageUrl(let imagePart) = parts[1] {
                XCTAssertTrue(imagePart.imageUrl.url.hasPrefix("data:image/png;base64,"))
            } else {
                XCTFail("Expected image part")
            }
        } else {
            XCTFail("Expected parts content")
        }
    }

    func testConvertClaudeDocumentFileIdToOpenAIInputFilePart() throws {
        let converter = ClaudeToOpenAIConverter()
        let claudeRequest = ClaudeMessageRequest(
            model: "claude-sonnet-4.5",
            messages: [
                ClaudeMessage(role: "user", content: .blocks([
                    .text(ClaudeTextBlock(text: "Summarize this document")),
                    .document(ClaudeDocumentBlock(
                        source: [
                            "type": AnyCodable("file"),
                            "file_id": AnyCodable("file_123")
                        ],
                        title: "report.pdf"
                    ))
                ]))
            ],
            maxTokens: 1024
        )

        let openAIRequest = try converter.convert(request: claudeRequest, upstreamModel: "gpt-4o")
        guard case .parts(let parts) = openAIRequest.messages[0].content else {
            return XCTFail("Expected multipart content")
        }

        XCTAssertEqual(parts.count, 2)
        guard case .inputFile(let filePart) = parts[1] else {
            return XCTFail("Expected input_file part")
        }
        XCTAssertEqual(filePart.fileId, "file_123")
        XCTAssertEqual(filePart.filename, "report.pdf")
    }

    func testConvertClaudeDocumentURLSourceFallsBackToExplicitText() throws {
        let converter = ClaudeToOpenAIConverter()
        let claudeRequest = ClaudeMessageRequest(
            model: "claude-sonnet-4.5",
            messages: [
                ClaudeMessage(role: "user", content: .blocks([
                    .document(ClaudeDocumentBlock(
                        source: [
                            "type": AnyCodable("url"),
                            "url": AnyCodable("https://example.com/spec.pdf")
                        ],
                        title: "spec.pdf",
                        context: "Reference this spec"
                    ))
                ]))
            ],
            maxTokens: 1024
        )

        let openAIRequest = try converter.convert(request: claudeRequest, upstreamModel: "gpt-4o")
        guard case .text(let text) = openAIRequest.messages[0].content else {
            return XCTFail("Expected degraded document to become text content")
        }

        XCTAssertTrue(text.contains("Claude document degraded"))
        XCTAssertTrue(text.contains("source.type=url"))
        XCTAssertTrue(text.contains("title=spec.pdf"))
        XCTAssertTrue(text.contains("context=Reference this spec"))
        XCTAssertTrue(text.contains("detail=https://example.com/spec.pdf"))
    }

    func testConvertClaudeInlineTextDocumentPreservesTextBody() throws {
        let converter = ClaudeToOpenAIConverter()
        let claudeRequest = ClaudeMessageRequest(
            model: "claude-sonnet-4.5",
            messages: [
                ClaudeMessage(role: "user", content: .blocks([
                    .document(ClaudeDocumentBlock(
                        source: [
                            "type": AnyCodable("text"),
                            "text": AnyCodable("Section 1: Requirements")
                        ],
                        title: "requirements.txt",
                        context: "Use this as primary reference"
                    ))
                ]))
            ],
            maxTokens: 1024
        )

        let openAIRequest = try converter.convert(request: claudeRequest, upstreamModel: "gpt-4o")
        guard case .text(let text) = openAIRequest.messages[0].content else {
            return XCTFail("Expected inline document to become text content")
        }

        XCTAssertTrue(text.contains("Document title: requirements.txt"))
        XCTAssertTrue(text.contains("Document context: Use this as primary reference"))
        XCTAssertTrue(text.contains("Document content:"))
        XCTAssertTrue(text.contains("Section 1: Requirements"))
    }

    func testConvertToolResultDocumentFallbackPreservesDegradedText() throws {
        let converter = ClaudeToOpenAIConverter()
        let claudeRequest = ClaudeMessageRequest(
            model: "claude-sonnet-4.5",
            messages: [
                ClaudeMessage(role: "user", content: .blocks([
                    .toolResult(ClaudeToolResultBlock(
                        toolUseId: "toolu_spec",
                        contentBlocks: [
                            .document(ClaudeDocumentBlock(
                                source: [
                                    "type": AnyCodable("url"),
                                    "url": AnyCodable("https://example.com/spec.pdf")
                                ],
                                title: "spec.pdf"
                            ))
                        ]
                    ))
                ]))
            ],
            maxTokens: 1024
        )

        let openAIRequest = try converter.convert(request: claudeRequest, upstreamModel: "gpt-4o")
        XCTAssertEqual(openAIRequest.messages.count, 1)
        XCTAssertEqual(openAIRequest.messages[0].role, "tool")

        guard case .text(let text) = openAIRequest.messages[0].content else {
            return XCTFail("Expected degraded tool result document to become text content")
        }

        XCTAssertTrue(text.contains("Claude document degraded"))
        XCTAssertTrue(text.contains("source.type=url"))
    }

    func testEncodeOpenAIInputFilePartAsChatCompletionsFileShape() throws {
        let request = OpenAIChatCompletionRequest(
            model: "gpt-4o-mini",
            messages: [
                OpenAIChatMessage(
                    role: "user",
                    content: .parts([
                        .text(OpenAITextPart(text: "See attached")),
                        .inputFile(OpenAIFilePart(fileId: "file_123", filename: "report.pdf"))
                    ])
                )
            ]
        )

        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])

        XCTAssertEqual(content[1]["type"] as? String, "file")

        let file = try XCTUnwrap(content[1]["file"] as? [String: Any])
        XCTAssertEqual(file["file_id"] as? String, "file_123")
        XCTAssertEqual(file["filename"] as? String, "report.pdf")
    }

    func testDecodeChatCompletionsFileShapeAsOpenAIInputFilePart() throws {
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "role": "user",
                "content": [
                    [
                        "type": "text",
                        "text": "See attached"
                    ],
                    [
                        "type": "file",
                        "file": [
                            "file_id": "file_123",
                            "filename": "report.pdf"
                        ]
                    ]
                ]
            ]
        )

        let message = try JSONDecoder().decode(OpenAIChatMessage.self, from: payload)
        guard case .parts(let parts) = message.content else {
            return XCTFail("Expected multipart content")
        }
        guard case .inputFile(let filePart) = parts[1] else {
            return XCTFail("Expected file content to decode as inputFile")
        }

        XCTAssertEqual(filePart.fileId, "file_123")
        XCTAssertEqual(filePart.filename, "report.pdf")
    }

    func testConvertToolDefinition() throws {
        let converter = ClaudeToOpenAIConverter()

        let tool = ClaudeTool(
            name: "get_weather",
            description: "Get the weather for a location",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "location": ["type": "string"]
                ]),
                "required": AnyCodable(["location"])
            ]
        )

        let claudeRequest = ClaudeMessageRequest(
            model: "claude-sonnet-4.5",
            messages: [
                ClaudeMessage(role: "user", content: .text("What's the weather?"))
            ],
            maxTokens: 1024,
            tools: [tool]
        )

        let openAIRequest = try converter.convert(request: claudeRequest, upstreamModel: "gpt-4o")

        XCTAssertNotNil(openAIRequest.tools)
        XCTAssertEqual(openAIRequest.tools?.count, 1)
        XCTAssertEqual(openAIRequest.tools?[0].function.name, "get_weather")
        XCTAssertEqual(openAIRequest.tools?[0].function.description, "Get the weather for a location")
    }

    func testClaudeToolDecodesEagerInputStreaming() throws {
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "name": "stream_tool",
                "description": "Stream tool inputs eagerly",
                "input_schema": [
                    "type": "object"
                ],
                "eager_input_streaming": true
            ]
        )

        let decoded = try JSONDecoder().decode(ClaudeTool.self, from: payload)
        XCTAssertEqual(decoded.name, "stream_tool")
        XCTAssertEqual(decoded.eagerInputStreaming, true)
    }

    func testClaudeToolEncodesEagerInputStreaming() throws {
        let tool = ClaudeTool(
            name: "stream_tool",
            description: "Stream tool inputs eagerly",
            inputSchema: [
                "type": AnyCodable("object")
            ],
            eagerInputStreaming: true
        )

        let data = try JSONEncoder().encode(tool)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["eager_input_streaming"] as? Bool, true)
    }

    func testConvertNamedToolChoiceEncodesStructuredChatCompletionsPayload() throws {
        let request = OpenAIChatCompletionRequest(
            model: "gpt-4o",
            messages: [
                OpenAIChatMessage(role: "user", content: .text("What's the weather?"))
            ],
            toolChoice: .function("get_weather")
        )

        let encoded = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let toolChoice = try XCTUnwrap(json["tool_choice"] as? [String: Any])
        XCTAssertEqual(toolChoice["type"] as? String, "function")

        let function = try XCTUnwrap(toolChoice["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "get_weather")
    }

    func testDisableParallelToolUseMapsToParallelToolCalls() throws {
        let converter = ClaudeToOpenAIConverter()
        let claudeRequest = ClaudeMessageRequest(
            model: "claude-sonnet-4.5",
            messages: [
                ClaudeMessage(role: "user", content: .text("What's the weather?"))
            ],
            maxTokens: 1024,
            tools: [
                ClaudeTool(
                    name: "get_weather",
                    description: "Get the weather",
                    inputSchema: [
                        "type": AnyCodable("object")
                    ]
                )
            ],
            toolChoice: ClaudeToolChoice(type: "any", disableParallelToolUse: true)
        )

        let openAIRequest = try converter.convert(request: claudeRequest, upstreamModel: "gpt-4o")
        XCTAssertEqual(openAIRequest.parallelToolCalls, false)

        let encoded = try JSONEncoder().encode(openAIRequest)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["parallel_tool_calls"] as? Bool, false)
    }

    func testDecodeNamedToolChoiceFromStructuredChatCompletionsPayload() throws {
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "model": "gpt-4o",
                "messages": [
                    [
                        "role": "user",
                        "content": "What's the weather?"
                    ]
                ],
                "tool_choice": [
                    "type": "function",
                    "function": [
                        "name": "get_weather"
                    ]
                ]
            ]
        )

        let decoded = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: payload)
        guard let toolChoice = decoded.toolChoice else {
            return XCTFail("Expected tool choice")
        }

        switch toolChoice {
        case .function(let name):
            XCTAssertEqual(name, "get_weather")
        default:
            XCTFail("Expected named function tool choice")
        }
    }

    func testConvertMultipleToolResultsPreservesEachToolMessage() throws {
        let converter = ClaudeToOpenAIConverter()

        let assistantToolUse = ClaudeMessage(
            role: "assistant",
            content: .blocks([
                .toolUse(ClaudeToolUseBlock(
                    id: "toolu_weather",
                    name: "get_weather",
                    input: ["location": AnyCodable("Shanghai")]
                )),
                .toolUse(ClaudeToolUseBlock(
                    id: "toolu_time",
                    name: "get_time",
                    input: ["timezone": AnyCodable("Asia/Shanghai")]
                ))
            ])
        )

        let userToolResults = ClaudeMessage(
            role: "user",
            content: .blocks([
                .toolResult(ClaudeToolResultBlock(toolUseId: "toolu_weather", content: "Sunny")),
                .toolResult(ClaudeToolResultBlock(toolUseId: "toolu_time", content: "12:00"))
            ])
        )

        let openAIRequest = try converter.convert(
            request: ClaudeMessageRequest(
                model: "claude-sonnet-4.5",
                messages: [assistantToolUse, userToolResults],
                maxTokens: 1024
            ),
            upstreamModel: "gpt-4o"
        )

        XCTAssertEqual(openAIRequest.messages.count, 3)
        XCTAssertEqual(openAIRequest.messages[0].role, "assistant")
        XCTAssertEqual(openAIRequest.messages[0].toolCalls?.count, 2)
        XCTAssertEqual(openAIRequest.messages[1].role, "tool")
        XCTAssertEqual(openAIRequest.messages[1].toolCallId, "toolu_weather")
        XCTAssertEqual(openAIRequest.messages[2].role, "tool")
        XCTAssertEqual(openAIRequest.messages[2].toolCallId, "toolu_time")

        if case .text(let content) = openAIRequest.messages[1].content {
            XCTAssertEqual(content, "Sunny")
        } else {
            XCTFail("Expected text tool result content")
        }

        if case .text(let content) = openAIRequest.messages[2].content {
            XCTAssertEqual(content, "12:00")
        } else {
            XCTFail("Expected text tool result content")
        }
    }

    func testConvertStructuredToolResultBlocksPreservesImageParts() throws {
        let converter = ClaudeToOpenAIConverter()

        let screenshot = ClaudeImageBlock(source: ClaudeImageSource(
            type: "base64",
            mediaType: "image/png",
            data: "AAAA"
        ))

        let openAIRequest = try converter.convert(
            request: ClaudeMessageRequest(
                model: "claude-sonnet-4.5",
                messages: [
                    ClaudeMessage(
                        role: "user",
                        content: .blocks([
                            .toolResult(ClaudeToolResultBlock(
                                toolUseId: "toolu_computer",
                                contentBlocks: [
                                    .text(ClaudeTextBlock(text: "Screenshot captured")),
                                    .image(screenshot)
                                ]
                            ))
                        ])
                    )
                ],
                maxTokens: 1024
            ),
            upstreamModel: "gpt-4o"
        )

        XCTAssertEqual(openAIRequest.messages.count, 1)
        XCTAssertEqual(openAIRequest.messages[0].role, "tool")
        XCTAssertEqual(openAIRequest.messages[0].toolCallId, "toolu_computer")

        guard case .parts(let parts) = openAIRequest.messages[0].content else {
            return XCTFail("Expected structured tool result content")
        }
        XCTAssertEqual(parts.count, 2)
        guard case .text(let textPart) = parts[0] else {
            return XCTFail("Expected text part in tool result")
        }
        XCTAssertEqual(textPart.text, "Screenshot captured")
        guard case .imageUrl(let imagePart) = parts[1] else {
            return XCTFail("Expected image part in tool result")
        }
        XCTAssertTrue(imagePart.imageUrl.url.hasPrefix("data:image/png;base64,"))
    }

    func testConvertMixedUserTextAndToolResultsPreservesOrder() throws {
        let converter = ClaudeToOpenAIConverter()

        let openAIRequest = try converter.convert(
            request: ClaudeMessageRequest(
                model: "claude-sonnet-4.5",
                messages: [
                    ClaudeMessage(
                        role: "user",
                        content: .blocks([
                            .text(ClaudeTextBlock(text: "Before tool")),
                            .toolResult(ClaudeToolResultBlock(toolUseId: "toolu_weather", content: "Sunny")),
                            .text(ClaudeTextBlock(text: "After tool"))
                        ])
                    )
                ],
                maxTokens: 1024
            ),
            upstreamModel: "gpt-4o"
        )

        XCTAssertEqual(openAIRequest.messages.count, 3)
        XCTAssertEqual(openAIRequest.messages[0].role, "user")
        XCTAssertEqual(openAIRequest.messages[1].role, "tool")
        XCTAssertEqual(openAIRequest.messages[2].role, "user")

        if case .text(let content) = openAIRequest.messages[0].content {
            XCTAssertEqual(content, "Before tool")
        } else {
            XCTFail("Expected text content before tool result")
        }

        if case .text(let content) = openAIRequest.messages[2].content {
            XCTAssertEqual(content, "After tool")
        } else {
            XCTFail("Expected text content after tool result")
        }
    }

    // MARK: - OpenAI to Claude Conversion Tests

    func testConvertOpenAIResponse() throws {
        let converter = OpenAIToClaudeConverter()

        let openAIResponse = OpenAIChatCompletionResponse(
            id: "chatcmpl-123",
            created: Int(Date().timeIntervalSince1970),
            model: "gpt-4o",
            choices: [
                OpenAIChoice(
                    index: 0,
                    message: OpenAIChatMessage(
                        role: "assistant",
                        content: .text("Hello! How can I help you today?")
                    ),
                    finishReason: "stop"
                )
            ],
            usage: OpenAIUsage(
                promptTokens: 10,
                completionTokens: 20,
                totalTokens: 30
            )
        )

        let claudeResponse = try converter.convert(
            response: openAIResponse,
            originalModel: "claude-sonnet-4.5"
        )

        XCTAssertEqual(claudeResponse.id, "chatcmpl-123")
        XCTAssertEqual(claudeResponse.role, "assistant")
        XCTAssertEqual(claudeResponse.model, "claude-sonnet-4.5")
        XCTAssertEqual(claudeResponse.stopReason, "end_turn")
        XCTAssertEqual(claudeResponse.usage.inputTokens, 10)
        XCTAssertEqual(claudeResponse.usage.outputTokens, 20)
        XCTAssertEqual(claudeResponse.content.count, 1)

        if case .text(let textBlock) = claudeResponse.content[0] {
            XCTAssertEqual(textBlock.text, "Hello! How can I help you today?")
        } else {
            XCTFail("Expected text block")
        }
    }

    func testConvertOpenAIInputFilePartBackToClaudeDocumentBlock() throws {
        let converter = OpenAIToClaudeConverter()

        let openAIResponse = OpenAIChatCompletionResponse(
            id: "chatcmpl-file-123",
            created: Int(Date().timeIntervalSince1970),
            model: "gpt-4o",
            choices: [
                OpenAIChoice(
                    index: 0,
                    message: OpenAIChatMessage(
                        role: "assistant",
                        content: .parts([
                            .text(OpenAITextPart(text: "Please inspect this file.")),
                            .inputFile(OpenAIFilePart(fileId: "file_123", filename: "report.pdf"))
                        ])
                    ),
                    finishReason: "stop"
                )
            ],
            usage: OpenAIUsage(
                promptTokens: 10,
                completionTokens: 20,
                totalTokens: 30
            )
        )

        let claudeResponse = try converter.convert(
            response: openAIResponse,
            originalModel: "claude-sonnet-4.5"
        )

        XCTAssertEqual(claudeResponse.content.count, 2)
        guard case .document(let block) = claudeResponse.content[1] else {
            return XCTFail("Expected document block")
        }
        XCTAssertEqual(block.title, "report.pdf")
        XCTAssertEqual(block.source["type"]?.value as? String, "file")
        XCTAssertEqual(block.source["file_id"]?.value as? String, "file_123")
    }

    func testConvertFinishReasons() {
        let converter = OpenAIToClaudeConverter()

        // Use reflection to test private method (for demonstration)
        // In real tests, you'd test through public API
        XCTAssertEqual(
            converter.convertFinishReason("stop"),
            "end_turn"
        )
        XCTAssertEqual(
            converter.convertFinishReason("length"),
            "max_tokens"
        )
        XCTAssertEqual(
            converter.convertFinishReason("tool_calls"),
            "tool_use"
        )
        XCTAssertEqual(
            converter.convertFinishReason("pause_turn"),
            "pause_turn"
        )
        XCTAssertEqual(
            converter.convertFinishReason("content_filter"),
            "refusal"
        )
        XCTAssertEqual(
            converter.convertFinishReason("refusal"),
            "refusal"
        )
    }

    func testClaudeContentBlockStartEventSupportsTextBlocks() throws {
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "type": "content_block_start",
                "index": 0,
                "content_block": [
                    "type": "text",
                    "text": ""
                ]
            ]
        )

        let event = try JSONDecoder().decode(ClaudeContentBlockStartEvent.self, from: payload)
        XCTAssertEqual(event.index, 0)

        guard case .text(let block) = event.contentBlock else {
            return XCTFail("Expected text content block")
        }
        XCTAssertEqual(block.text, "")
    }

    func testClaudeContentBlockDeltaEventDecodesThinkingAndSignatureDeltas() throws {
        let thinkingPayload = try JSONSerialization.data(
            withJSONObject: [
                "type": "content_block_delta",
                "index": 1,
                "delta": [
                    "type": "thinking_delta",
                    "thinking": "Let me reason about this."
                ]
            ]
        )

        let thinkingEvent = try JSONDecoder().decode(ClaudeContentBlockDeltaEvent.self, from: thinkingPayload)
        switch thinkingEvent.delta {
        case .thinking(let delta):
            XCTAssertEqual(delta.thinking, "Let me reason about this.")
        default:
            XCTFail("Expected thinking delta")
        }

        let signaturePayload = try JSONSerialization.data(
            withJSONObject: [
                "type": "content_block_delta",
                "index": 1,
                "delta": [
                    "type": "signature_delta",
                    "signature": "sig_123"
                ]
            ]
        )

        let signatureEvent = try JSONDecoder().decode(ClaudeContentBlockDeltaEvent.self, from: signaturePayload)
        switch signatureEvent.delta {
        case .signature(let delta):
            XCTAssertEqual(delta.signature, "sig_123")
        default:
            XCTFail("Expected signature delta")
        }
    }

    func testClaudeContentBlockStopEventPreservesIndex() throws {
        let event = ClaudeContentBlockStopEvent(index: 3)
        let encoded = try JSONEncoder().encode(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "content_block_stop")
        XCTAssertEqual(json["index"] as? Int, 3)
    }

    func testClaudeToolChoiceDecodesDisableParallelToolUseAndNone() throws {
        let autoPayload = try JSONSerialization.data(
            withJSONObject: [
                "model": "claude-sonnet-4.5",
                "messages": [
                    [
                        "role": "user",
                        "content": "Call a tool"
                    ]
                ],
                "tool_choice": [
                    "type": "auto",
                    "disable_parallel_tool_use": true
                ],
                "max_tokens": 1024
            ]
        )

        let autoRequest = try JSONDecoder().decode(ClaudeMessageRequest.self, from: autoPayload)
        XCTAssertEqual(autoRequest.toolChoice?.type, "auto")
        XCTAssertEqual(autoRequest.toolChoice?.disableParallelToolUse, true)

        let noneChoice = ClaudeToolChoice(type: "none")
        let openAIToolChoice = try ClaudeToOpenAIConverter()
            .convert(
                request: ClaudeMessageRequest(
                    model: "claude-sonnet-4.5",
                    messages: [ClaudeMessage(role: "user", content: .text("Hi"))],
                    maxTokens: 128,
                    toolChoice: noneChoice
                ),
                upstreamModel: "gpt-4o"
            )
            .toolChoice

        guard let openAIToolChoice else {
            return XCTFail("Expected tool choice")
        }
        switch openAIToolChoice {
        case .none:
            break
        default:
            XCTFail("Expected .none tool choice")
        }
    }

    // MARK: - Token Estimation Tests

    func testTokenEstimation() {
        let text = "Hello, world! This is a test message."
        let estimatedTokens = text.count / 4

        XCTAssertGreaterThan(estimatedTokens, 0)
        XCTAssertLessThan(estimatedTokens, text.count)
    }
}
