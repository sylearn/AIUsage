import Foundation
import Network
import XCTest
@testable import QuotaBackend
@testable import QuotaServerCore

final class CodexWebSocketTests: XCTestCase {
    func testUpgradeValidationRequiresRFC6455Headers() {
        let valid = [
            "upgrade": "websocket",
            "connection": "keep-alive, Upgrade",
            "sec-websocket-version": "13",
            "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==",
        ]
        XCTAssertNil(QuotaWebSocket.validateUpgradeRequest(method: "GET", headers: valid))

        var invalid = valid
        invalid["connection"] = "keep-alive"
        XCTAssertNotNil(QuotaWebSocket.validateUpgradeRequest(method: "GET", headers: invalid))
        invalid = valid
        invalid["sec-websocket-version"] = "12"
        XCTAssertNotNil(QuotaWebSocket.validateUpgradeRequest(method: "GET", headers: invalid))
        invalid = valid
        invalid["sec-websocket-key"] = "not-a-websocket-key"
        XCTAssertNotNil(QuotaWebSocket.validateUpgradeRequest(method: "GET", headers: invalid))
    }

    func testFrameParserAcceptsMaskedFramesIncrementally() throws {
        let payload = Data(String(repeating: "x", count: 130).utf8)
        let frame = makeClientFrame(opcode: 0x1, payload: payload)
        var parser = QuotaWebSocket.FrameParser()
        parser.append(frame.prefix(5))
        XCTAssertNil(try parser.nextFrame())
        parser.append(frame.dropFirst(5))

        let parsed = try XCTUnwrap(parser.nextFrame())
        XCTAssertTrue(parsed.isFinal)
        XCTAssertEqual(parsed.opcode, 0x1)
        XCTAssertEqual(parsed.payload, payload)
        XCTAssertFalse(parser.hasBufferedData)
    }

    func testFrameParserRejectsUnmaskedRSVAndInvalidControlFrames() {
        var parser = QuotaWebSocket.FrameParser()
        parser.append(makeClientFrame(opcode: 0x1, payload: Data("x".utf8), masked: false))
        XCTAssertThrowsError(try parser.nextFrame()) {
            XCTAssertEqual($0 as? QuotaWebSocket.FrameError, .protocolViolation)
        }

        parser = QuotaWebSocket.FrameParser()
        parser.append(makeClientFrame(opcode: 0x1, payload: Data("x".utf8), rsv: 0x40))
        XCTAssertThrowsError(try parser.nextFrame()) {
            XCTAssertEqual($0 as? QuotaWebSocket.FrameError, .protocolViolation)
        }

        parser = QuotaWebSocket.FrameParser()
        parser.append(makeClientFrame(opcode: 0x9, payload: Data("x".utf8), isFinal: false))
        XCTAssertThrowsError(try parser.nextFrame()) {
            XCTAssertEqual($0 as? QuotaWebSocket.FrameError, .protocolViolation)
        }
    }

    func testFrameParserRejectsOversizedPayloadBeforeAllocation() {
        let length = UInt64(QuotaWebSocket.maxFramePayloadBytes + 1)
        var frame = Data([0x81, 0xFF])
        for shift in stride(from: 56, through: 0, by: -8) {
            frame.append(UInt8((length >> shift) & 0xFF))
        }
        var parser = QuotaWebSocket.FrameParser()
        parser.append(frame)
        XCTAssertThrowsError(try parser.nextFrame()) {
            XCTAssertEqual($0 as? QuotaWebSocket.FrameError, .frameTooLarge)
        }
    }

    func testGenerateFalseCreatesWarmupWithoutHTTPAndContinuesLocally() async throws {
        let store = CodexWebSocketContextStore()
        let warmup = try await store.prepare(event: [
            "type": "response.create",
            "stream_id": "main",
            "generate": false,
            "model": "gpt-test",
            "instructions": "Use the tool.",
            "tools": [["type": "function", "name": "lookup"]],
            "store": false,
            "input": [["type": "message", "role": "user", "content": []]],
        ])

        XCTAssertNil(warmup.httpBody)
        let responseID = try XCTUnwrap(warmup.warmupResponse?.completed["id"] as? String)
        XCTAssertTrue(responseID.hasPrefix("resp_aiusage_"))

        let continued = try await store.prepare(event: [
            "type": "response.create",
            "stream_id": "main",
            "previous_response_id": responseID,
            "model": "gpt-test",
            "input": [["type": "function_call_output", "call_id": "call_1", "output": "ok"]],
        ])
        let body = try jsonObject(try XCTUnwrap(continued.httpBody))
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNil(body["previous_response_id"])
        XCTAssertEqual(body["instructions"] as? String, "Use the tool.")
        XCTAssertEqual((body["tools"] as? [Any])?.count, 1)
        XCTAssertEqual((body["input"] as? [Any])?.count, 2)
    }

    func testCompletedResponseBuildsLocalContinuationContext() async throws {
        let store = CodexWebSocketContextStore()
        let first = try await store.prepare(event: [
            "type": "response.create",
            "model": "gpt-test",
            "store": false,
            "input": [["type": "message", "role": "user", "content": []]],
        ])
        await store.recordCompleted(response: [
            "id": "resp_local",
            "output": [["type": "message", "role": "assistant", "content": []]],
        ], for: first)

        let second = try await store.prepare(event: [
            "type": "response.create",
            "model": "gpt-test",
            "store": false,
            "previous_response_id": "resp_local",
            "input": [["type": "function_call_output", "call_id": "call_1", "output": "ok"]],
        ])
        let body = try jsonObject(try XCTUnwrap(second.httpBody))
        XCTAssertNil(body["previous_response_id"])
        XCTAssertEqual((body["input"] as? [Any])?.count, 3)
    }

    func testLocalContinuationPreservesExternalRootResponseID() async throws {
        let store = CodexWebSocketContextStore()
        let first = try await store.prepare(event: [
            "type": "response.create",
            "model": "gpt-test",
            "previous_response_id": "resp_external",
            "input": [["type": "message", "role": "user", "content": []]],
        ])
        await store.recordCompleted(response: [
            "id": "resp_local",
            "output": [["type": "message", "role": "assistant", "content": []]],
        ], for: first)

        let second = try await store.prepare(event: [
            "type": "response.create",
            "model": "gpt-test",
            "previous_response_id": "resp_local",
            "input": [["type": "message", "role": "user", "content": []]],
        ])
        let body = try jsonObject(try XCTUnwrap(second.httpBody))
        XCTAssertEqual(body["previous_response_id"] as? String, "resp_external")
        XCTAssertEqual((body["input"] as? [Any])?.count, 3)
    }

    func testWebSocketTransportFieldsAreStripped() async throws {
        let store = CodexWebSocketContextStore()
        let prepared = try await store.prepare(event: [
            "type": "response.create",
            "model": "gpt-test",
            "input": "ping",
            "stream": true,
            "background": false,
            "stream_options": ["include_usage": true],
        ])
        let body = try jsonObject(try XCTUnwrap(prepared.httpBody))
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNil(body["background"])
        XCTAssertNil(body["stream_options"])
    }

    func testWebSocketOnlyFieldsAndTypesAreValidated() async {
        let store = CodexWebSocketContextStore()
        await XCTAssertThrowsErrorAsync {
            _ = try await store.prepare(event: [
                "type": "response.create",
                "model": "gpt-test",
                "generate": "false",
            ])
        }
    }

    func testWarmupDefaultsPersistAcrossGeneratedResponses() async throws {
        let store = CodexWebSocketContextStore()
        let warmup = try await store.prepare(event: [
            "type": "response.create",
            "generate": false,
            "model": "gpt-test",
            "instructions": "Keep using the configured tool.",
            "tools": [["type": "function", "name": "lookup"]],
        ])
        let warmupID = try XCTUnwrap(warmup.warmupResponse?.completed["id"] as? String)

        let first = try await store.prepare(event: [
            "type": "response.create",
            "previous_response_id": warmupID,
            "input": "first",
        ])
        await store.recordCompleted(
            response: ["id": "resp_generated_1", "output": []],
            for: first
        )

        let second = try await store.prepare(event: [
            "type": "response.create",
            "previous_response_id": "resp_generated_1",
            "input": "second",
        ])
        let body = try jsonObject(try XCTUnwrap(second.httpBody))
        XCTAssertEqual(body["instructions"] as? String, "Keep using the configured tool.")
        XCTAssertEqual((body["tools"] as? [Any])?.count, 1)
    }

    func testLatestContextSurvivesAncestorEviction() async throws {
        let store = CodexWebSocketContextStore()
        var previousID: String?

        for index in 0..<130 {
            var event: [String: Any] = [
                "type": "response.create",
                "model": "gpt-test",
                "input": "turn-\(index)",
            ]
            if let previousID { event["previous_response_id"] = previousID }
            let prepared = try await store.prepare(event: event)
            let responseID = "resp_local_\(index)"
            await store.recordCompleted(
                response: ["id": responseID, "output": []],
                for: prepared
            )
            previousID = responseID
        }

        let continued = try await store.prepare(event: [
            "type": "response.create",
            "model": "gpt-test",
            "previous_response_id": try XCTUnwrap(previousID),
            "input": "final",
        ])
        let body = try jsonObject(try XCTUnwrap(continued.httpBody))
        XCTAssertEqual((body["input"] as? [Any])?.count, 131)
    }

    func testLiveWebSocketHandlesPingConcurrentStreamsAndHotSwitch() async throws {
        let firstUpstreamPort = try findFreePort()
        let firstUpstream = MockHTTPServer(port: firstUpstreamPort) { request in
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: request.body) as? [String: Any]
            )
            let input = body["input"] as? String ?? "unknown"
            if input == "slow" {
                try await Task.sleep(nanoseconds: 700_000_000)
                return MockHTTPResponse(
                    headers: ["Content-Type": "text/event-stream"],
                    body: Self.responsesEvent(type: "response.created", id: "resp-slow", status: "in_progress")
                        + Self.responsesEvent(type: "response.completed", id: "resp-slow", status: "completed")
                        + "data: [DONE]\n\n"
                )
            }
            return MockHTTPResponse(
                headers: ["Content-Type": "text/event-stream"],
                body: Self.responsesEvent(type: "response.completed", id: "resp-fast", status: "completed")
                    + "data: [DONE]\n\n"
            )
        }
        try await firstUpstream.start()
        defer { firstUpstream.stop() }

        let secondUpstreamPort = try findFreePort()
        let secondUpstream = MockHTTPServer(port: secondUpstreamPort) { _ in
            MockHTTPResponse(
                headers: ["Content-Type": "text/event-stream"],
                body: Self.responsesEvent(type: "response.completed", id: "resp-switched", status: "completed")
                    + "data: [DONE]\n\n"
            )
        }
        try await secondUpstream.start()
        defer { secondUpstream.stop() }

        let proxyPort = try findFreePort()
        let config = CodexProxyConfiguration(
            enabled: true,
            bindPort: proxyPort,
            upstreamBaseURL: "http://127.0.0.1:\(firstUpstreamPort)/v1",
            openAIUpstreamAPI: .responses,
            upstreamAPIKey: "upstream-key",
            expectedClientKey: "client-key"
        )
        let server = QuotaHTTPServer(
            host: "127.0.0.1",
            port: proxyPort,
            codexConfig: config
        )
        try await server.start()
        defer { server.stop() }

        let socket = RawWebSocketTestClient(port: proxyPort, clientKey: "client-key")
        try await socket.connect()
        defer { socket.close() }

        try await sendCreate(socket, streamID: "slow", input: "slow")
        let pingStarted = ContinuousClock.now
        try await socket.sendPing()
        try await sendCreate(socket, streamID: "fast", input: "fast")
        try await socket.waitForPong()
        XCTAssertLessThan(ContinuousClock.now - pingStarted, .milliseconds(500))

        var completedStreams: [String] = []
        var sawSlowCreated = false
        while completedStreams.count < 2 {
            let event = try await receiveEvent(socket)
            if event["type"] as? String == "response.created",
               event["stream_id"] as? String == "slow" {
                sawSlowCreated = true
            }
            if event["type"] as? String == "response.completed",
               let streamID = event["stream_id"] as? String {
                completedStreams.append(streamID)
            }
        }
        XCTAssertTrue(sawSlowCreated)
        XCTAssertEqual(completedStreams, ["fast", "slow"])

        XCTAssertTrue(server.applyCodexUpstream(.init(
            nodeId: "switched-node",
            baseURL: "http://127.0.0.1:\(secondUpstreamPort)/v1",
            apiKey: "new-upstream-key",
            model: nil,
            maxOutputTokens: nil
        )))
        try await sendCreate(socket, streamID: "switched", input: "after-switch")

        var switchedResponseID: String?
        while switchedResponseID == nil {
            let event = try await receiveEvent(socket)
            if event["type"] as? String == "response.completed",
               event["stream_id"] as? String == "switched" {
                switchedResponseID = (event["response"] as? [String: Any])?["id"] as? String
            }
        }
        XCTAssertEqual(switchedResponseID, "resp-switched")
        let switchedRequests = await secondUpstream.recordedRequests()
        XCTAssertEqual(switchedRequests.count, 1)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func sendCreate(
        _ socket: RawWebSocketTestClient,
        streamID: String,
        input: String
    ) async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "response.create",
            "stream_id": streamID,
            "model": "gpt-test",
            "input": input,
        ])
        try await socket.sendText(String(decoding: data, as: UTF8.self))
    }

    private func receiveEvent(_ socket: RawWebSocketTestClient) async throws -> [String: Any] {
        let data = Data(try await socket.receiveText().utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func responsesEvent(type: String, id: String, status: String) -> String {
        let payload = "{\"type\":\"\(type)\",\"response\":{\"id\":\"\(id)\",\"object\":\"response\",\"status\":\"\(status)\",\"model\":\"gpt-test\",\"output\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}}"
        return "event: \(type)\ndata: \(payload)\n\n"
    }

    private func makeClientFrame(
        opcode: UInt8,
        payload: Data,
        isFinal: Bool = true,
        masked: Bool = true,
        rsv: UInt8 = 0
    ) -> Data {
        var frame = Data([(isFinal ? 0x80 : 0) | rsv | opcode])
        let maskBit: UInt8 = masked ? 0x80 : 0
        if payload.count < 126 {
            frame.append(maskBit | UInt8(payload.count))
        } else if payload.count < 65_536 {
            frame.append(maskBit | 126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(maskBit | 127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> shift) & 0xFF))
            }
        }
        let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        if masked { frame.append(contentsOf: mask) }
        for (index, byte) in payload.enumerated() {
            frame.append(masked ? byte ^ mask[index % 4] : byte)
        }
        return frame
    }
}

private final class RawWebSocketTestClient: @unchecked Sendable {
    private struct Frame {
        let opcode: UInt8
        let payload: Data
    }

    private let connection: NWConnection
    private let port: Int
    private let clientKey: String
    private var buffer = Data()
    private var pendingText: [String] = []

    init(port: Int, clientKey: String) {
        self.port = port
        self.clientKey = clientKey
        self.connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: UInt16(port))!,
            using: .tcp
        )
    }

    func connect() async throws {
        connection.start(queue: .global())
        let request = [
            "GET /v1/responses HTTP/1.1",
            "Host: 127.0.0.1:\(port)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
            "Sec-WebSocket-Version: 13",
            "Authorization: Bearer \(clientKey)",
            "",
            "",
        ].joined(separator: "\r\n")
        try await sendRaw(Data(request.utf8))

        let separator = Data([13, 10, 13, 10])
        while buffer.range(of: separator) == nil {
            buffer.append(try await receiveChunk())
        }
        let range = try XCTUnwrap(buffer.range(of: separator))
        let headers = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
        guard headers.hasPrefix("HTTP/1.1 101 ") else {
            throw NSError(
                domain: "RawWebSocketTestClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: headers]
            )
        }
        buffer = Data(buffer[range.upperBound...])
    }

    func close() {
        connection.cancel()
    }

    func sendText(_ text: String) async throws {
        try await sendFrame(opcode: 0x1, payload: Data(text.utf8))
    }

    func sendPing() async throws {
        try await sendFrame(opcode: 0x9, payload: Data("probe".utf8))
    }

    func waitForPong() async throws {
        while true {
            let frame = try await readFrame()
            switch frame.opcode {
            case 0xA:
                guard frame.payload == Data("probe".utf8) else { continue }
                return
            case 0x1:
                guard let text = String(data: frame.payload, encoding: .utf8) else {
                    throw NSError(domain: "RawWebSocketTestClient", code: 2)
                }
                pendingText.append(text)
            case 0x8:
                throw NSError(domain: "RawWebSocketTestClient", code: 3)
            default:
                continue
            }
        }
    }

    func receiveText() async throws -> String {
        if !pendingText.isEmpty { return pendingText.removeFirst() }
        while true {
            let frame = try await readFrame()
            switch frame.opcode {
            case 0x1:
                guard let text = String(data: frame.payload, encoding: .utf8) else {
                    throw NSError(domain: "RawWebSocketTestClient", code: 4)
                }
                return text
            case 0x9:
                try await sendFrame(opcode: 0xA, payload: frame.payload)
            case 0x8:
                throw NSError(domain: "RawWebSocketTestClient", code: 5)
            default:
                continue
            }
        }
    }

    private func sendFrame(opcode: UInt8, payload: Data) async throws {
        var frame = Data([0x80 | opcode])
        let maskBit: UInt8 = 0x80
        if payload.count < 126 {
            frame.append(maskBit | UInt8(payload.count))
        } else if payload.count < 65_536 {
            frame.append(maskBit | 126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(maskBit | 127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> shift) & 0xFF))
            }
        }
        let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        frame.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() {
            frame.append(byte ^ mask[index % 4])
        }
        try await sendRaw(frame)
    }

    private func readFrame() async throws -> Frame {
        while true {
            if let frame = try parseFrame() { return frame }
            buffer.append(try await receiveChunk())
        }
    }

    private func parseFrame() throws -> Frame? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }
        let opcode = bytes[0] & 0x0F
        guard (bytes[1] & 0x80) == 0 else {
            throw NSError(domain: "RawWebSocketTestClient", code: 6)
        }
        var cursor = 2
        var length = Int(bytes[1] & 0x7F)
        if length == 126 {
            guard bytes.count >= cursor + 2 else { return nil }
            length = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
            cursor += 2
        } else if length == 127 {
            guard bytes.count >= cursor + 8 else { return nil }
            var extended: UInt64 = 0
            for offset in 0..<8 {
                extended = (extended << 8) | UInt64(bytes[cursor + offset])
            }
            guard extended <= UInt64(Int.max) else {
                throw NSError(domain: "RawWebSocketTestClient", code: 7)
            }
            length = Int(extended)
            cursor += 8
        }
        guard bytes.count >= cursor + length else { return nil }
        let payload = Data(bytes[cursor..<(cursor + length)])
        buffer = Data(bytes.dropFirst(cursor + length))
        return Frame(opcode: opcode, payload: payload)
    }

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: NSError(domain: "RawWebSocketTestClient", code: 8))
                }
            }
        }
    }

    private func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
