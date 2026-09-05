import Foundation
import XCTest
@testable import QuotaBackend

final class OpenAIResponsesTests: XCTestCase {

    func testResponsesInputMessageSupportsPhaseAndInputFileContent() throws {
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "model": "gpt-5",
                "input": [
                    [
                        "type": "message",
                        "role": "assistant",
                        "phase": "final_answer",
                        "content": [
                            [
                                "type": "input_text",
                                "text": "See attached report"
                            ],
                            [
                                "type": "input_file",
                                "file_id": "file_123",
                                "filename": "report.pdf"
                            ]
                        ]
                    ]
                ]
            ]
        )

        let decoded = try JSONDecoder().decode(OpenAIResponsesRequest.self, from: payload)
        XCTAssertEqual(decoded.input.count, 1)

        guard case .message(let message) = decoded.input[0] else {
            return XCTFail("Expected message input item")
        }

        XCTAssertEqual(message.role, "assistant")
        XCTAssertEqual(message.phase, .finalAnswer)
        XCTAssertEqual(message.content.count, 2)

        guard case .inputFile(let file) = message.content[1] else {
            return XCTFail("Expected input_file content")
        }

        XCTAssertEqual(file.fileId, "file_123")
        XCTAssertEqual(file.filename, "report.pdf")
    }

    func testResponsesFunctionCallOutputSupportsStructuredContentArray() throws {
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "type": "function_call_output",
                "call_id": "call_123",
                "output": [
                    [
                        "type": "input_text",
                        "text": "Chart generated"
                    ],
                    [
                        "type": "input_image",
                        "image_url": "data:image/png;base64,AAAA",
                        "detail": "high"
                    ],
                    [
                        "type": "input_file",
                        "file_url": "https://example.com/report.csv",
                        "filename": "report.csv"
                    ]
                ]
            ]
        )

        let decoded = try JSONDecoder().decode(OpenAIResponsesFunctionCallOutput.self, from: payload)
        switch decoded.output {
        case .content(let content):
            XCTAssertEqual(content.count, 3)

            guard case .inputImage(let image) = content[1] else {
                return XCTFail("Expected input_image content")
            }
            XCTAssertEqual(image.imageURL, "data:image/png;base64,AAAA")
            XCTAssertEqual(image.detail, "high")

            guard case .inputFile(let file) = content[2] else {
                return XCTFail("Expected input_file content")
            }
            XCTAssertEqual(file.fileURL, "https://example.com/report.csv")
            XCTAssertEqual(file.filename, "report.csv")
        case .text:
            XCTFail("Expected structured content array")
        }
    }

    func testResponsesOutputItemsDecodeReasoningAndCompaction() throws {
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "id": "resp_123",
                "object": "response",
                "created_at": 1_710_000_000,
                "model": "gpt-5",
                "status": "completed",
                "output": [
                    [
                        "id": "rs_123",
                        "type": "reasoning",
                        "summary": [
                            [
                                "type": "summary_text",
                                "text": "Need to consult the weather tool."
                            ]
                        ],
                        "content": [
                            [
                                "type": "reasoning_text",
                                "text": "The user asked for current weather."
                            ]
                        ],
                        "encrypted_content": "enc_reasoning",
                        "status": "completed"
                    ],
                    [
                        "type": "compaction",
                        "id": "cmp_123",
                        "encrypted_content": "enc_compaction"
                    ]
                ]
            ]
        )

        let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: payload)
        XCTAssertEqual(decoded.output.count, 2)

        guard case .reasoning(let reasoning) = decoded.output[0] else {
            return XCTFail("Expected reasoning item")
        }
        XCTAssertEqual(reasoning.summary.first?.text, "Need to consult the weather tool.")
        XCTAssertEqual(reasoning.content?.first?.text, "The user asked for current weather.")
        XCTAssertEqual(reasoning.encryptedContent, "enc_reasoning")

        guard case .compaction(let compaction) = decoded.output[1] else {
            return XCTFail("Expected compaction item")
        }
        XCTAssertEqual(compaction.id, "cmp_123")
        XCTAssertEqual(compaction.encryptedContent, "enc_compaction")
    }

    func testResponsesOutputItemsDecodeBuiltInToolVariants() throws {
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "id": "resp_tools_123",
                "object": "response",
                "created_at": 1_710_000_050,
                "model": "gpt-5",
                "status": "completed",
                "output": [
                    [
                        "id": "fs_123",
                        "type": "file_search_call",
                        "queries": ["quota usage"],
                        "status": "searching",
                        "results": [
                            [
                                "file_id": "file_123",
                                "filename": "usage.md",
                                "score": 0.91,
                                "text": "Current quota usage"
                            ]
                        ]
                    ],
                    [
                        "id": "computer_123",
                        "type": "computer_call",
                        "call_id": "computer_call_123",
                        "status": "completed",
                        "action": [
                            "type": "click",
                            "x": 10,
                            "y": 12,
                            "button": "left"
                        ],
                        "actions": [
                            [
                                "type": "click",
                                "x": 10,
                                "y": 12,
                                "button": "left"
                            ],
                            [
                                "type": "wait"
                            ]
                        ],
                        "pending_safety_checks": [
                            [
                                "id": "safe_1",
                                "message": "Confirm external navigation"
                            ]
                        ]
                    ],
                    [
                        "id": "computer_out_123",
                        "type": "computer_call_output",
                        "call_id": "computer_call_123",
                        "status": "completed",
                        "output": [
                            "type": "computer_screenshot",
                            "file_id": "file_screen_123",
                            "image_url": "https://example.com/screen.png"
                        ],
                        "acknowledged_safety_checks": [
                            [
                                "id": "safe_1"
                            ]
                        ]
                    ],
                    [
                        "id": "tool_search_call_123",
                        "type": "tool_search_call",
                        "call_id": "tool_search_call_123",
                        "arguments": [
                            "query": "web and file tools"
                        ],
                        "execution": "server",
                        "status": "completed"
                    ],
                    [
                        "id": "tool_search_out_123",
                        "type": "tool_search_output",
                        "call_id": "tool_search_call_123",
                        "execution": "server",
                        "status": "completed",
                        "tools": [
                            [
                                "type": "function",
                                "name": "search_docs",
                                "parameters": [
                                    "type": "object",
                                    "properties": [
                                        "query": [
                                            "type": "string"
                                        ]
                                    ]
                                ],
                                "strict": true
                            ],
                            [
                                "type": "file_search",
                                "vector_store_ids": ["vs_123"]
                            ],
                            [
                                "type": "web_search"
                            ]
                        ]
                    ],
                    [
                        "id": "shell_123",
                        "type": "shell_call",
                        "call_id": "shell_call_123",
                        "action": [
                            "commands": ["pwd", "ls"],
                            "max_output_length": 4096,
                            "timeout_ms": 1200
                        ],
                        "environment": [
                            "type": "container_reference",
                            "container_id": "ctr_123"
                        ],
                        "status": "completed"
                    ],
                    [
                        "id": "shell_out_123",
                        "type": "shell_call_output",
                        "call_id": "shell_call_123",
                        "max_output_length": 4096,
                        "output": [
                            [
                                "outcome": [
                                    "type": "exit",
                                    "exit_code": 0
                                ],
                                "stdout": "/workspace\n",
                                "stderr": ""
                            ]
                        ],
                        "status": "completed"
                    ],
                    [
                        "id": "mcp_list_123",
                        "type": "mcp_list_tools",
                        "server_label": "github",
                        "tools": [
                            [
                                "type": "function",
                                "name": "fetch_issue",
                                "parameters": [
                                    "type": "object"
                                ]
                            ]
                        ]
                    ],
                    [
                        "id": "approval_req_123",
                        "type": "mcp_approval_request",
                        "arguments": "{\"repo\":\"openai/openai\"}",
                        "name": "delete_branch",
                        "server_label": "github"
                    ],
                    [
                        "id": "approval_res_123",
                        "type": "mcp_approval_response",
                        "approval_request_id": "approval_req_123",
                        "approve": true
                    ],
                    [
                        "id": "custom_call_123",
                        "type": "custom_tool_call",
                        "call_id": "custom_call_123",
                        "input": "{\"path\":\"README.md\"}",
                        "name": "workspace.read",
                        "status": "completed"
                    ],
                    [
                        "id": "custom_out_123",
                        "type": "custom_tool_call_output",
                        "call_id": "custom_call_123",
                        "status": "completed",
                        "output": [
                            [
                                "type": "input_text",
                                "text": "README contents"
                            ]
                        ]
                    ]
                ]
            ]
        )

        let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: payload)
        XCTAssertEqual(decoded.output.count, 12)

        guard case .fileSearchCall(let fileSearch) = decoded.output[0] else {
            return XCTFail("Expected file_search_call")
        }
        XCTAssertEqual(fileSearch.queries, ["quota usage"])
        XCTAssertEqual(fileSearch.results?.first?.filename, "usage.md")

        guard case .computerCall(let computerCall) = decoded.output[1] else {
            return XCTFail("Expected computer_call")
        }
        XCTAssertEqual(computerCall.callId, "computer_call_123")
        XCTAssertEqual(computerCall.actions?.count, 2)
        XCTAssertEqual(computerCall.action?["type"]?.value as? String, "click")

        guard case .computerCallOutput(let computerOutput) = decoded.output[2] else {
            return XCTFail("Expected computer_call_output")
        }
        XCTAssertEqual(computerOutput.output.fileId, "file_screen_123")
        XCTAssertEqual(computerOutput.acknowledgedSafetyChecks?.count, 1)

        guard case .toolSearchOutput(let toolSearchOutput) = decoded.output[4] else {
            return XCTFail("Expected tool_search_output")
        }
        XCTAssertEqual(toolSearchOutput.tools.count, 3)
        guard case .function(let functionTool) = toolSearchOutput.tools[0] else {
            return XCTFail("Expected function tool in tool_search_output")
        }
        XCTAssertEqual(functionTool.name, "search_docs")
        guard case .fileSearch(let fileSearchTool) = toolSearchOutput.tools[1] else {
            return XCTFail("Expected file_search tool in tool_search_output")
        }
        XCTAssertEqual(fileSearchTool.type, "file_search")
        guard case .webSearch(let webSearchTool) = toolSearchOutput.tools[2] else {
            return XCTFail("Expected web_search tool in tool_search_output")
        }
        XCTAssertEqual(webSearchTool.type, "web_search")

        guard case .shellCall(let shellCall) = decoded.output[5] else {
            return XCTFail("Expected shell_call")
        }
        XCTAssertEqual(shellCall.action.commands, ["pwd", "ls"])
        XCTAssertEqual(shellCall.environment.containerId, "ctr_123")

        guard case .shellCallOutput(let shellOutput) = decoded.output[6] else {
            return XCTFail("Expected shell_call_output")
        }
        XCTAssertEqual(shellOutput.output.count, 1)
        guard case .exit(let exitOutcome) = shellOutput.output[0].outcome else {
            return XCTFail("Expected exit outcome")
        }
        XCTAssertEqual(exitOutcome.exitCode, 0)

        guard case .mcpListTools(let mcpList) = decoded.output[7] else {
            return XCTFail("Expected mcp_list_tools")
        }
        XCTAssertEqual(mcpList.serverLabel, "github")
        guard let firstMCPTool = mcpList.tools.first,
              case .function(let mcpFunctionTool) = firstMCPTool else {
            return XCTFail("Expected function tool in mcp_list_tools")
        }
        XCTAssertEqual(mcpFunctionTool.name, "fetch_issue")

        guard case .mcpApprovalRequest(let approvalRequest) = decoded.output[8] else {
            return XCTFail("Expected mcp_approval_request")
        }
        XCTAssertEqual(approvalRequest.serverLabel, "github")

        guard case .mcpApprovalResponse(let approvalResponse) = decoded.output[9] else {
            return XCTFail("Expected mcp_approval_response")
        }
        XCTAssertTrue(approvalResponse.approve)

        guard case .customToolCall(let customToolCall) = decoded.output[10] else {
            return XCTFail("Expected custom_tool_call")
        }
        XCTAssertEqual(customToolCall.name, "workspace.read")

        guard case .customToolCallOutput(let customToolOutput) = decoded.output[11] else {
            return XCTFail("Expected custom_tool_call_output")
        }
        switch customToolOutput.output {
        case .content(let content):
            XCTAssertEqual(content.count, 1)
        case .text:
            XCTFail("Expected structured custom tool output")
        }
    }

    func testResponsesInputItemsDecodeAdvancedToolOutputs() throws {
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "model": "gpt-5",
                "input": [
                    [
                        "type": "computer_call_output",
                        "id": "computer_out_123",
                        "call_id": "computer_call_123",
                        "status": "completed",
                        "output": [
                            "type": "computer_screenshot",
                            "image_url": "https://example.com/screen.png"
                        ]
                    ],
                    [
                        "type": "local_shell_call_output",
                        "id": "local_shell_out_123",
                        "output": "{\"stdout\":\"ok\"}",
                        "status": "completed"
                    ],
                    [
                        "type": "shell_call_output",
                        "id": "shell_out_123",
                        "call_id": "shell_call_123",
                        "max_output_length": 1024,
                        "output": [
                            [
                                "outcome": [
                                    "type": "timeout"
                                ],
                                "stderr": "timed out"
                            ]
                        ],
                        "status": "incomplete"
                    ],
                    [
                        "type": "apply_patch_call_output",
                        "id": "patch_out_123",
                        "call_id": "patch_call_123",
                        "status": "completed",
                        "output": "updated README"
                    ],
                    [
                        "type": "mcp_approval_response",
                        "id": "approval_res_123",
                        "approval_request_id": "approval_req_123",
                        "approve": false,
                        "reason": "Needs manual review"
                    ],
                    [
                        "type": "custom_tool_call_output",
                        "id": "custom_out_123",
                        "call_id": "custom_call_123",
                        "status": "completed",
                        "output": "README contents"
                    ]
                ]
            ]
        )

        let decoded = try JSONDecoder().decode(OpenAIResponsesRequest.self, from: payload)
        XCTAssertEqual(decoded.input.count, 6)

        guard case .computerCallOutput(let computerOutput) = decoded.input[0] else {
            return XCTFail("Expected computer_call_output input")
        }
        XCTAssertEqual(computerOutput.output.imageURL, "https://example.com/screen.png")

        guard case .localShellCallOutput(let localShellOutput) = decoded.input[1] else {
            return XCTFail("Expected local_shell_call_output input")
        }
        XCTAssertEqual(localShellOutput.output, "{\"stdout\":\"ok\"}")

        guard case .shellCallOutput(let shellOutput) = decoded.input[2] else {
            return XCTFail("Expected shell_call_output input")
        }
        XCTAssertEqual(shellOutput.maxOutputLength, 1024)
        guard case .timeout = shellOutput.output[0].outcome else {
            return XCTFail("Expected timeout shell outcome")
        }

        guard case .applyPatchCallOutput(let patchOutput) = decoded.input[3] else {
            return XCTFail("Expected apply_patch_call_output input")
        }
        XCTAssertEqual(patchOutput.output, "updated README")

        guard case .mcpApprovalResponse(let approvalResponse) = decoded.input[4] else {
            return XCTFail("Expected mcp_approval_response input")
        }
        XCTAssertFalse(approvalResponse.approve)
        XCTAssertEqual(approvalResponse.reason, "Needs manual review")

        guard case .customToolCallOutput(let customToolOutput) = decoded.input[5] else {
            return XCTFail("Expected custom_tool_call_output input")
        }
        switch customToolOutput.output {
        case .text(let text):
            XCTAssertEqual(text, "README contents")
        case .content:
            XCTFail("Expected plain text custom tool output")
        }
    }

    func testResponsesRequestToolsSupportBuiltInDefinitions() throws {
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "model": "gpt-5",
                "input": [],
                "tools": [
                    [
                        "type": "function",
                        "name": "get_weather",
                        "description": "Fetches weather",
                        "parameters": [
                            "type": "object"
                        ],
                        "strict": true
                    ],
                    [
                        "type": "file_search",
                        "vector_store_ids": ["vs_123"],
                        "max_num_results": 8
                    ],
                    [
                        "type": "computer_use_preview",
                        "display_height": 900,
                        "display_width": 1440,
                        "environment": "browser"
                    ],
                    [
                        "type": "web_search_2025_08_26",
                        "filters": [
                            "allowed_domains": ["example.com"]
                        ],
                        "search_context_size": "high",
                        "user_location": [
                            "type": "approximate",
                            "city": "Shanghai",
                            "country": "CN",
                            "timezone": "Asia/Shanghai"
                        ]
                    ],
                    [
                        "type": "mcp",
                        "server_label": "deepwiki",
                        "server_url": "https://mcp.example.com",
                        "allowed_tools": [
                            "read_only": true,
                            "tool_names": ["search", "open_page"]
                        ],
                        "require_approval": "never"
                    ],
                    [
                        "type": "code_interpreter",
                        "container": [
                            "type": "auto",
                            "file_ids": ["file_123"],
                            "memory_limit": "4g",
                            "network_policy": [
                                "type": "allowlist",
                                "allowed_domains": ["example.com"]
                            ]
                        ]
                    ],
                    [
                        "type": "image_generation",
                        "background": "transparent",
                        "output_format": "webp",
                        "quality": "high",
                        "size": "1024x1024"
                    ],
                    [
                        "type": "local_shell"
                    ],
                    [
                        "type": "shell",
                        "environment": [
                            "type": "local",
                            "skills": [
                                [
                                    "name": "checks",
                                    "description": "Run workspace checks",
                                    "path": "/skills/checks"
                                ]
                            ]
                        ]
                    ],
                    [
                        "type": "custom",
                        "name": "workspace.write",
                        "description": "Write file content",
                        "format": [
                            "type": "grammar",
                            "definition": "start: /.+/",
                            "syntax": "regex"
                        ]
                    ],
                    [
                        "type": "apply_patch"
                    ]
                ]
            ]
        )

        let decoded = try JSONDecoder().decode(OpenAIResponsesRequest.self, from: payload)
        let tools = try XCTUnwrap(decoded.tools)
        XCTAssertEqual(tools.count, 11)

        guard case .function(let functionTool) = tools[0] else {
            return XCTFail("Expected function tool")
        }
        XCTAssertEqual(functionTool.name, "get_weather")
        XCTAssertEqual(functionTool.strict, true)

        guard case .fileSearch(let fileSearchTool) = tools[1] else {
            return XCTFail("Expected file_search tool")
        }
        XCTAssertEqual(fileSearchTool.vectorStoreIds, ["vs_123"])
        XCTAssertEqual(fileSearchTool.maxNumResults, 8)

        guard case .computerUsePreview(let computerTool) = tools[2] else {
            return XCTFail("Expected computer_use_preview tool")
        }
        XCTAssertEqual(computerTool.environment, "browser")
        XCTAssertEqual(computerTool.displayWidth, 1440)

        guard case .webSearch(let webSearchTool) = tools[3] else {
            return XCTFail("Expected web_search tool")
        }
        XCTAssertEqual(webSearchTool.type, "web_search_2025_08_26")
        XCTAssertEqual(webSearchTool.filters?.allowedDomains, ["example.com"])
        XCTAssertEqual(webSearchTool.userLocation?.timezone, "Asia/Shanghai")

        guard case .mcp(let mcpTool) = tools[4] else {
            return XCTFail("Expected mcp tool")
        }
        XCTAssertEqual(mcpTool.serverLabel, "deepwiki")
        switch mcpTool.allowedTools {
        case .filter(let filter):
            XCTAssertEqual(filter.toolNames, ["search", "open_page"])
            XCTAssertEqual(filter.readOnly, true)
        case .toolNames:
            XCTFail("Expected MCP allowed_tools filter object")
        case .none:
            XCTFail("Expected MCP allowed_tools")
        }
        switch mcpTool.requireApproval {
        case .policy(let policy):
            XCTAssertEqual(policy, "never")
        case .filters:
            XCTFail("Expected string approval policy")
        case .none:
            XCTFail("Expected require_approval")
        }

        guard case .codeInterpreter(let codeInterpreterTool) = tools[5] else {
            return XCTFail("Expected code_interpreter tool")
        }
        switch codeInterpreterTool.container {
        case .auto(let container):
            XCTAssertEqual(container.fileIds, ["file_123"])
            XCTAssertEqual(container.memoryLimit, "4g")
            guard case .allowlist(let policy) = container.networkPolicy else {
                return XCTFail("Expected allowlist network policy")
            }
            XCTAssertEqual(policy.allowedDomains, ["example.com"])
        case .containerId:
            XCTFail("Expected auto container")
        }

        guard case .imageGeneration(let imageTool) = tools[6] else {
            return XCTFail("Expected image_generation tool")
        }
        XCTAssertEqual(imageTool.outputFormat, "webp")
        XCTAssertEqual(imageTool.quality, "high")

        guard case .localShell(let localShellTool) = tools[7] else {
            return XCTFail("Expected local_shell tool")
        }
        XCTAssertEqual(localShellTool.type, "local_shell")

        guard case .shell(let shellTool) = tools[8] else {
            return XCTFail("Expected shell tool")
        }
        switch shellTool.environment {
        case .local(let local):
            XCTAssertEqual(local.skills?.first?.name, "checks")
        case .containerReference, .containerAuto:
            XCTFail("Expected local shell environment")
        case .none:
            XCTFail("Expected shell environment")
        }

        guard case .custom(let customTool) = tools[9] else {
            return XCTFail("Expected custom tool")
        }
        XCTAssertEqual(customTool.name, "workspace.write")
        switch customTool.format {
        case .grammar(let grammar):
            XCTAssertEqual(grammar.syntax, "regex")
        case .text:
            XCTFail("Expected grammar custom tool format")
        case .none:
            XCTFail("Expected custom tool format")
        }

        guard case .applyPatch(let applyPatchTool) = tools[10] else {
            return XCTFail("Expected apply_patch tool")
        }
        XCTAssertEqual(applyPatchTool.type, "apply_patch")
    }

    func testResponsesToolChoiceSupportsAllowedToolsAndSpecificTargets() throws {
        struct ToolChoiceEnvelope: Codable {
            let toolChoice: OpenAIResponsesToolChoice

            enum CodingKeys: String, CodingKey {
                case toolChoice = "tool_choice"
            }
        }

        let allowedPayload = try JSONSerialization.data(
            withJSONObject: [
                "tool_choice": [
                    "type": "allowed_tools",
                    "mode": "required",
                    "tools": [
                        [
                            "type": "function",
                            "name": "get_weather"
                        ],
                        [
                            "type": "mcp",
                            "server_label": "deepwiki",
                            "server_url": "https://mcp.example.com"
                        ]
                    ]
                ]
            ]
        )

        let allowedChoice = try JSONDecoder().decode(ToolChoiceEnvelope.self, from: allowedPayload).toolChoice
        switch allowedChoice {
        case .allowedTools(let mode, let tools):
            XCTAssertEqual(mode, "required")
            XCTAssertEqual(tools.count, 2)
            guard case .function(let functionTool) = tools[0] else {
                return XCTFail("Expected function allowed tool")
            }
            XCTAssertEqual(functionTool.name, "get_weather")
            guard case .mcp(let mcpTool) = tools[1] else {
                return XCTFail("Expected mcp allowed tool")
            }
            XCTAssertEqual(mcpTool.serverLabel, "deepwiki")
        default:
            XCTFail("Expected allowed_tools tool choice")
        }

        let hostedPayload = try JSONSerialization.data(
            withJSONObject: [
                "tool_choice": [
                    "type": "file_search"
                ]
            ]
        )
        let hostedChoice = try JSONDecoder().decode(ToolChoiceEnvelope.self, from: hostedPayload).toolChoice
        guard case .hostedTool(let hostedType) = hostedChoice else {
            return XCTFail("Expected hosted tool choice")
        }
        XCTAssertEqual(hostedType, "file_search")

        let mcpPayload = try JSONSerialization.data(
            withJSONObject: [
                "tool_choice": [
                    "type": "mcp",
                    "server_label": "deepwiki",
                    "name": "search_docs"
                ]
            ]
        )
        let mcpChoice = try JSONDecoder().decode(ToolChoiceEnvelope.self, from: mcpPayload).toolChoice
        guard case .mcp(let serverLabel, let name) = mcpChoice else {
            return XCTFail("Expected mcp tool choice")
        }
        XCTAssertEqual(serverLabel, "deepwiki")
        XCTAssertEqual(name, "search_docs")

        let customPayload = try JSONSerialization.data(
            withJSONObject: [
                "tool_choice": [
                    "type": "custom",
                    "name": "workspace.write"
                ]
            ]
        )
        let customChoice = try JSONDecoder().decode(ToolChoiceEnvelope.self, from: customPayload).toolChoice
        guard case .custom(let customName) = customChoice else {
            return XCTFail("Expected custom tool choice")
        }
        XCTAssertEqual(customName, "workspace.write")

        let encoded = try JSONEncoder().encode(ToolChoiceEnvelope(
            toolChoice: .allowedTools(
                mode: "required",
                tools: [
                    .function(OpenAIResponsesFunctionTool(name: "get_weather", description: nil, parameters: nil)),
                    .mcp(OpenAIResponsesMCPTool(
                        type: "mcp",
                        serverLabel: "deepwiki",
                        allowedTools: nil,
                        authorization: nil,
                        connectorId: nil,
                        headers: nil,
                        requireApproval: nil,
                        serverDescription: nil,
                        serverURL: "https://mcp.example.com"
                    ))
                ]
            )
        ))
        let encodedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedChoice = try XCTUnwrap(encodedObject["tool_choice"] as? [String: Any])
        XCTAssertEqual(encodedChoice["type"] as? String, "allowed_tools")
        XCTAssertEqual(encodedChoice["mode"] as? String, "required")
        let encodedTools = try XCTUnwrap(encodedChoice["tools"] as? [[String: Any]])
        XCTAssertEqual(encodedTools.count, 2)
        XCTAssertEqual(encodedTools[0]["type"] as? String, "function")
        XCTAssertEqual(encodedTools[0]["name"] as? String, "get_weather")

        let shellEncoded = try JSONEncoder().encode(ToolChoiceEnvelope(toolChoice: .shell))
        let shellObject = try XCTUnwrap(JSONSerialization.jsonObject(with: shellEncoded) as? [String: Any])
        let shellChoice = try XCTUnwrap(shellObject["tool_choice"] as? [String: Any])
        XCTAssertEqual(shellChoice["type"] as? String, "shell")

        let applyPatchEncoded = try JSONEncoder().encode(ToolChoiceEnvelope(toolChoice: .applyPatch))
        let applyPatchObject = try XCTUnwrap(JSONSerialization.jsonObject(with: applyPatchEncoded) as? [String: Any])
        let applyPatchChoice = try XCTUnwrap(applyPatchObject["tool_choice"] as? [String: Any])
        XCTAssertEqual(applyPatchChoice["type"] as? String, "apply_patch")
    }

    /// Verify that sendChatCompletion rejects .responses upstream config
    func testResponsesClientRejectsChatCompletionWithResponsesUpstream() async throws {
        let client = OpenAICompatibleClient(configuration: ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "http://127.0.0.1:9999",
            openAIUpstreamAPI: .responses,
            upstreamAPIKey: "upstream-key"
        ))

        do {
            _ = try await client.sendChatCompletion(request: OpenAIChatCompletionRequest(
                model: "gpt-4o-mini",
                messages: [OpenAIChatMessage(role: "user", content: .text("hello"))]
            ))
            XCTFail("Expected invalidResponse error")
        } catch {
            XCTAssertTrue("\(error)".contains("sendChatCompletion requires .chatCompletions"))
        }
    }

    /// Verify that streamCompletion rejects .responses upstream config
    func testResponsesClientRejectsStreamCompletionWithResponsesUpstream() async throws {
        let client = OpenAICompatibleClient(configuration: ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "http://127.0.0.1:9999",
            openAIUpstreamAPI: .responses,
            upstreamAPIKey: "upstream-key"
        ))

        do {
            try await client.streamCompletion(
                request: OpenAIChatCompletionRequest(
                    model: "gpt-4o-mini",
                    messages: [OpenAIChatMessage(role: "user", content: .text("hello"))],
                    stream: true
                )
            ) { _ in }
            XCTFail("Expected invalidResponse error")
        } catch {
            XCTAssertTrue("\(error)".contains("streamCompletion requires .chatCompletions"))
        }
    }

    func testResponsesStreamingUsesOutputItemDoneForToolCalls() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            MockHTTPResponse(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [
                    "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_123\",\"name\":\"get_weather\",\"arguments\":\"{\\\"location\\\":\\\"Shanghai\\\"}\",\"status\":\"completed\"}}\n\n",
                    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_stream_tool\",\"object\":\"response\",\"created_at\":1710000200,\"model\":\"gpt-4o-mini\",\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"call_123\",\"name\":\"get_weather\",\"arguments\":\"{\\\"location\\\":\\\"Shanghai\\\"}\",\"status\":\"completed\"}],\"usage\":{\"input_tokens\":11,\"output_tokens\":3,\"total_tokens\":14}}}\n\n"
                ],
                chunkDelayNanoseconds: 20_000_000
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let client = OpenAICompatibleClient(configuration: ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "http://127.0.0.1:\(upstreamPort)",
            openAIUpstreamAPI: .responses,
            upstreamAPIKey: "upstream-key"
        ))

        var startedToolCalls: [(Int, String, String)] = []
        var argumentDeltas: [(Int, String)] = []
        var reasoningDeltas: [String] = []
        var finishReason: String?

        try await client.streamResponses(
            request: OpenAIResponsesRequest(
                model: "gpt-4o-mini",
                input: [.message(OpenAIResponsesInputMessage(role: "user", content: [.inputText(OpenAIResponsesInputText(text: "What's the weather?"))]))]
            )
        ) { event in
            switch event {
            case .reasoningSummaryDelta(let delta):
                reasoningDeltas.append(delta)
            case .toolCallStarted(let index, let id, let name):
                startedToolCalls.append((index, id, name))
            case .toolCallArgumentsDelta(let index, let argumentsDelta):
                argumentDeltas.append((index, argumentsDelta))
            case .completed(let reason, _):
                finishReason = reason
            case .textDelta(_):
                break
            }
        }

        XCTAssertTrue(reasoningDeltas.isEmpty)
        XCTAssertEqual(startedToolCalls.count, 1)
        XCTAssertEqual(startedToolCalls.first?.0, 0)
        XCTAssertEqual(startedToolCalls.first?.1, "call_123")
        XCTAssertEqual(startedToolCalls.first?.2, "get_weather")
        XCTAssertEqual(argumentDeltas.count, 1)
        XCTAssertEqual(argumentDeltas.first?.1, #"{"location":"Shanghai"}"#)
        XCTAssertEqual(finishReason, "tool_calls")
    }

    func testResponsesStreamingEmitsReasoningSummaryAndKeepsToolIndicesRelative() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            MockHTTPResponse(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [
                    "data: {\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_123\",\"output_index\":0,\"summary_index\":0,\"delta\":\"Need to consult the weather tool.\"}\n\n",
                    "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_456\",\"name\":\"get_weather\",\"arguments\":\"{\\\"location\\\":\\\"Shanghai\\\"}\",\"status\":\"completed\"}}\n\n",
                    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_stream_reasoning_tool\",\"object\":\"response\",\"created_at\":1710000200,\"model\":\"gpt-4o-mini\",\"status\":\"completed\",\"output\":[{\"id\":\"rs_123\",\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"Need to consult the weather tool.\"}],\"status\":\"completed\"},{\"type\":\"function_call\",\"call_id\":\"call_456\",\"name\":\"get_weather\",\"arguments\":\"{\\\"location\\\":\\\"Shanghai\\\"}\",\"status\":\"completed\"}],\"usage\":{\"input_tokens\":11,\"output_tokens\":5,\"total_tokens\":16}}}\n\n"
                ],
                chunkDelayNanoseconds: 20_000_000
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let client = OpenAICompatibleClient(configuration: ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "http://127.0.0.1:\(upstreamPort)",
            openAIUpstreamAPI: .responses,
            upstreamAPIKey: "upstream-key"
        ))

        var reasoningDeltas: [String] = []
        var startedToolCalls: [(Int, String, String)] = []
        var argumentDeltas: [(Int, String)] = []
        var finishReason: String?

        try await client.streamResponses(
            request: OpenAIResponsesRequest(
                model: "gpt-4o-mini",
                input: [.message(OpenAIResponsesInputMessage(role: "user", content: [.inputText(OpenAIResponsesInputText(text: "What's the weather?"))]))]
            )
        ) { event in
            switch event {
            case .reasoningSummaryDelta(let delta):
                reasoningDeltas.append(delta)
            case .toolCallStarted(let index, let id, let name):
                startedToolCalls.append((index, id, name))
            case .toolCallArgumentsDelta(let index, let argumentsDelta):
                argumentDeltas.append((index, argumentsDelta))
            case .completed(let reason, _):
                finishReason = reason
            case .textDelta(_):
                break
            }
        }

        XCTAssertEqual(reasoningDeltas, ["Need to consult the weather tool."])
        XCTAssertEqual(startedToolCalls.count, 1)
        XCTAssertEqual(startedToolCalls.first?.0, 0)
        XCTAssertEqual(startedToolCalls.first?.1, "call_456")
        XCTAssertEqual(startedToolCalls.first?.2, "get_weather")
        XCTAssertEqual(argumentDeltas.count, 1)
        XCTAssertEqual(argumentDeltas.first?.0, 0)
        XCTAssertEqual(argumentDeltas.first?.1, #"{"location":"Shanghai"}"#)
        XCTAssertEqual(finishReason, "tool_calls")
    }

    func testResponsesStreamingNormalizesFunctionArgumentDeltaIndicesAfterReasoning() async throws {
        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            MockHTTPResponse(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [
                    "data: {\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_123\",\"output_index\":0,\"summary_index\":0,\"delta\":\"Need to consult the weather tool.\"}\n\n",
                    "data: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_123\",\"output_index\":1,\"delta\":\"{\\\"location\\\":\\\"Shanghai\\\"}\"}\n\n",
                    "data: {\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc_123\",\"output_index\":1,\"arguments\":\"{\\\"location\\\":\\\"Shanghai\\\"}\",\"item\":{\"type\":\"function_call\",\"call_id\":\"call_789\",\"name\":\"get_weather\",\"arguments\":\"{\\\"location\\\":\\\"Shanghai\\\"}\",\"status\":\"completed\"}}\n\n",
                    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_stream_reasoning_tool_delta\",\"object\":\"response\",\"created_at\":1710000200,\"model\":\"gpt-4o-mini\",\"status\":\"completed\",\"output\":[{\"id\":\"rs_123\",\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"Need to consult the weather tool.\"}],\"status\":\"completed\"},{\"type\":\"function_call\",\"call_id\":\"call_789\",\"name\":\"get_weather\",\"arguments\":\"{\\\"location\\\":\\\"Shanghai\\\"}\",\"status\":\"completed\"}],\"usage\":{\"input_tokens\":11,\"output_tokens\":5,\"total_tokens\":16}}}\n\n"
                ],
                chunkDelayNanoseconds: 20_000_000
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let client = OpenAICompatibleClient(configuration: ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "http://127.0.0.1:\(upstreamPort)",
            openAIUpstreamAPI: .responses,
            upstreamAPIKey: "upstream-key"
        ))

        var reasoningDeltas: [String] = []
        var startedToolCalls: [(Int, String, String)] = []
        var argumentDeltas: [(Int, String)] = []
        var finishReason: String?

        try await client.streamResponses(
            request: OpenAIResponsesRequest(
                model: "gpt-4o-mini",
                input: [.message(OpenAIResponsesInputMessage(role: "user", content: [.inputText(OpenAIResponsesInputText(text: "What's the weather?"))]))]
            )
        ) { event in
            switch event {
            case .reasoningSummaryDelta(let delta):
                reasoningDeltas.append(delta)
            case .toolCallStarted(let index, let id, let name):
                startedToolCalls.append((index, id, name))
            case .toolCallArgumentsDelta(let index, let argumentsDelta):
                argumentDeltas.append((index, argumentsDelta))
            case .completed(let reason, _):
                finishReason = reason
            case .textDelta:
                break
            }
        }

        XCTAssertEqual(reasoningDeltas, ["Need to consult the weather tool."])
        XCTAssertEqual(argumentDeltas.count, 1)
        XCTAssertEqual(argumentDeltas.first?.0, 0)
        XCTAssertEqual(argumentDeltas.first?.1, #"{"location":"Shanghai"}"#)
        XCTAssertEqual(startedToolCalls.count, 1)
        XCTAssertEqual(startedToolCalls.first?.0, 0)
        XCTAssertEqual(startedToolCalls.first?.1, "call_789")
        XCTAssertEqual(startedToolCalls.first?.2, "get_weather")
        XCTAssertEqual(finishReason, "tool_calls")
    }

    func testCodexPassthroughUsageSubtractsCachedTokensFromInput() throws {
        let data = Data("""
        {
          "id": "resp_cached",
          "usage": {
            "input_tokens": 1000,
            "output_tokens": 120,
            "input_tokens_details": {
              "cached_tokens": 800
            }
          }
        }
        """.utf8)

        let usage = try XCTUnwrap(CodexProxyService.parseUsage(fromResponseBody: data))
        XCTAssertEqual(usage.inputTokens, 200)
        XCTAssertEqual(usage.cachedTokens, 800)
        XCTAssertEqual(usage.outputTokens, 120)
    }

    func testCodexPassthroughUsageClampsCachedTokensToInput() throws {
        let data = Data("""
        {
          "id": "resp_cached_overflow",
          "usage": {
            "input_tokens": 100,
            "output_tokens": 20,
            "input_tokens_details": {
              "cached_tokens": 140
            }
          }
        }
        """.utf8)

        let usage = try XCTUnwrap(CodexProxyService.parseUsage(fromResponseBody: data))
        XCTAssertEqual(usage.inputTokens, 0)
        XCTAssertEqual(usage.cachedTokens, 100)
        XCTAssertEqual(usage.outputTokens, 20)
    }

    func testCodexPassthroughStreamUsageSubtractsCachedTokensFromInput() throws {
        let frame = """
        {"type":"response.completed","response":{"usage":{"input_tokens":1000,"output_tokens":120,"input_tokens_details":{"cached_tokens":800}}}}
        """

        let usage = try XCTUnwrap(CodexProxyService.parseUsage(fromStreamFrame: frame))
        XCTAssertEqual(usage.inputTokens, 200)
        XCTAssertEqual(usage.cachedTokens, 800)
        XCTAssertEqual(usage.outputTokens, 120)
    }

    func testCodexPassthroughForwardsCurrentIdentityHeadersWithoutClientAuthorization() {
        let headers = CodexProxyService.forwardableHeaders(from: [
            "authorization": "Bearer local-client-key",
            "session-id": "session-current",
            "thread-id": "thread-current",
            "x-client-request-id": "request-current",
            "x-codex-turn-metadata": "{\"session_id\":\"session-current\"}",
            "originator": "Codex Desktop",
        ])

        XCTAssertNil(headers["Authorization"])
        XCTAssertEqual(headers["session-id"], "session-current")
        XCTAssertEqual(headers["thread-id"], "thread-current")
        XCTAssertEqual(headers["x-client-request-id"], "request-current")
        XCTAssertEqual(headers["x-codex-turn-metadata"], "{\"session_id\":\"session-current\"}")
        XCTAssertEqual(headers["originator"], "Codex Desktop")
    }
}
