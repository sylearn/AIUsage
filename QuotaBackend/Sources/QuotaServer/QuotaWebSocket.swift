import CryptoKit
import Foundation
import Network

// MARK: - RFC 6455 WebSocket support used by the local Codex endpoint

enum QuotaWebSocket {
    static let maxFramePayloadBytes = 8 * 1_024 * 1_024
    static let maxMessagePayloadBytes = 16 * 1_024 * 1_024

    private static let handshakeMagic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func isUpgradeRequest(_ headers: [String: String]) -> Bool {
        headerContainsToken(headers["upgrade"], token: "websocket")
    }

    static func validateUpgradeRequest(method: String, headers: [String: String]) -> String? {
        guard method.uppercased() == "GET" else {
            return "WebSocket upgrade requires GET"
        }
        guard headerContainsToken(headers["upgrade"], token: "websocket"),
              headerContainsToken(headers["connection"], token: "upgrade") else {
            return "Invalid WebSocket upgrade headers"
        }
        guard headers["sec-websocket-version"] == "13" else {
            return "Unsupported WebSocket version"
        }
        guard let key = headers["sec-websocket-key"],
              let decoded = Data(base64Encoded: key), decoded.count == 16 else {
            return "Invalid Sec-WebSocket-Key"
        }
        return nil
    }

    static func acceptKey(for secWebSocketKey: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((secWebSocketKey + handshakeMagic).utf8))
        return Data(digest).base64EncodedString()
    }

    static func handshakeResponse(acceptKey: String, extraHeaders: [String: String] = [:]) -> Data {
        var lines = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(acceptKey)",
        ]
        for (key, value) in extraHeaders where !key.contains("\r") && !key.contains("\n")
            && !value.contains("\r") && !value.contains("\n") {
            lines.append("\(key): \(value)")
        }
        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private static func headerContainsToken(_ value: String?, token: String) -> Bool {
        value?.split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(token) == .orderedSame
        } ?? false
    }

    struct Frame: Equatable {
        let isFinal: Bool
        let opcode: UInt8
        let payload: Data
    }

    enum FrameError: Error, Equatable {
        case protocolViolation
        case frameTooLarge
    }

    struct FrameParser {
        private(set) var buffer = Data()

        var hasBufferedData: Bool { !buffer.isEmpty }

        mutating func append(_ data: Data) {
            buffer.append(data)
        }

        mutating func nextFrame() throws -> Frame? {
            guard buffer.count >= 2 else { return nil }
            let start = buffer.startIndex
            func byte(at offset: Int) -> UInt8 {
                buffer[buffer.index(start, offsetBy: offset)]
            }
            let first = byte(at: 0)
            let second = byte(at: 1)
            let isFinal = (first & 0x80) != 0
            let rsv = first & 0x70
            let opcode = first & 0x0F
            let isMasked = (second & 0x80) != 0

            guard rsv == 0, [0x0, 0x1, 0x2, 0x8, 0x9, 0xA].contains(opcode), isMasked else {
                throw FrameError.protocolViolation
            }

            let isControl = opcode >= 0x8
            var cursor = 2
            var payloadLength = UInt64(second & 0x7F)
            if payloadLength == 126 {
                guard buffer.count >= cursor + 2 else { return nil }
                payloadLength = UInt64(byte(at: cursor)) << 8 | UInt64(byte(at: cursor + 1))
                guard payloadLength >= 126 else { throw FrameError.protocolViolation }
                cursor += 2
            } else if payloadLength == 127 {
                guard buffer.count >= cursor + 8 else { return nil }
                guard (byte(at: cursor) & 0x80) == 0 else { throw FrameError.protocolViolation }
                payloadLength = 0
                for offset in 0..<8 {
                    payloadLength = (payloadLength << 8) | UInt64(byte(at: cursor + offset))
                }
                guard payloadLength >= 65_536 else { throw FrameError.protocolViolation }
                cursor += 8
            }

            guard payloadLength <= UInt64(maxFramePayloadBytes) else {
                throw FrameError.frameTooLarge
            }
            guard !isControl || (isFinal && payloadLength <= 125) else {
                throw FrameError.protocolViolation
            }

            let payloadCount = Int(payloadLength)
            let totalLength = cursor + 4 + payloadCount
            guard buffer.count >= totalLength else { return nil }

            let maskStart = buffer.index(start, offsetBy: cursor)
            let maskEnd = buffer.index(maskStart, offsetBy: 4)
            let mask = Array(buffer[maskStart..<maskEnd])
            cursor += 4
            let payloadStart = buffer.index(start, offsetBy: cursor)
            let payloadEnd = buffer.index(payloadStart, offsetBy: payloadCount)
            let encoded = buffer[payloadStart..<payloadEnd]
            var payload = Data(capacity: payloadCount)
            for (index, byte) in encoded.enumerated() {
                payload.append(byte ^ mask[index % 4])
            }
            let frameEnd = buffer.index(start, offsetBy: totalLength)
            buffer.removeSubrange(start..<frameEnd)
            return Frame(isFinal: isFinal, opcode: opcode, payload: payload)
        }
    }
}

actor QuotaWebSocketConnection {
    private let connection: NWConnection
    private var parser = QuotaWebSocket.FrameParser()
    private var fragmentedOpcode: UInt8?
    private var fragmentedPayload = Data()
    private var closeSent = false

    init(connection: NWConnection, initialBuffer: Data = Data()) {
        self.connection = connection
        parser.append(initialBuffer)
    }

    func sendHandshake(acceptKey: String, extraHeaders: [String: String] = [:]) async {
        await sendRaw(QuotaWebSocket.handshakeResponse(acceptKey: acceptKey, extraHeaders: extraHeaders))
    }

    func sendText(_ text: String) async {
        await sendFrame(opcode: 0x1, payload: Data(text.utf8))
    }

    func readTextMessage() async -> String? {
        do {
            while let frame = try await readFrame() {
                switch frame.opcode {
                case 0x0:
                    guard fragmentedOpcode != nil else { throw QuotaWebSocket.FrameError.protocolViolation }
                    try appendFragment(frame.payload)
                    if frame.isFinal {
                        guard fragmentedOpcode == 0x1 else {
                            throw WebSocketMessageError.unsupportedData
                        }
                        guard let text = String(data: fragmentedPayload, encoding: .utf8) else {
                            throw WebSocketMessageError.invalidText
                        }
                        fragmentedOpcode = nil
                        fragmentedPayload.removeAll(keepingCapacity: false)
                        return text
                    }
                case 0x1, 0x2:
                    guard fragmentedOpcode == nil else { throw QuotaWebSocket.FrameError.protocolViolation }
                    if frame.isFinal {
                        guard frame.opcode == 0x1 else { throw WebSocketMessageError.unsupportedData }
                        guard let text = String(data: frame.payload, encoding: .utf8) else {
                            throw WebSocketMessageError.invalidText
                        }
                        return text
                    }
                    fragmentedOpcode = frame.opcode
                    try appendFragment(frame.payload)
                case 0x8:
                    try validateClosePayload(frame.payload)
                    await sendClose(payload: frame.payload)
                    return nil
                case 0x9:
                    await sendFrame(opcode: 0xA, payload: frame.payload)
                case 0xA:
                    break
                default:
                    throw QuotaWebSocket.FrameError.protocolViolation
                }
            }
            return nil
        } catch QuotaWebSocket.FrameError.frameTooLarge, WebSocketMessageError.messageTooLarge {
            await sendClose(code: 1009)
            return nil
        } catch WebSocketMessageError.unsupportedData {
            await sendClose(code: 1003)
            return nil
        } catch WebSocketMessageError.invalidText {
            await sendClose(code: 1007)
            return nil
        } catch {
            await sendClose(code: 1002)
            return nil
        }
    }

    func close() {
        connection.cancel()
    }

    private enum WebSocketMessageError: Error {
        case invalidText
        case messageTooLarge
        case unsupportedData
    }

    private func appendFragment(_ payload: Data) throws {
        guard payload.count <= QuotaWebSocket.maxMessagePayloadBytes - fragmentedPayload.count else {
            throw WebSocketMessageError.messageTooLarge
        }
        fragmentedPayload.append(payload)
    }

    private func readFrame() async throws -> QuotaWebSocket.Frame? {
        while true {
            if let frame = try parser.nextFrame() { return frame }
            guard let chunk = await receiveChunk() else {
                if parser.hasBufferedData { throw QuotaWebSocket.FrameError.protocolViolation }
                return nil
            }
            parser.append(chunk)
        }
    }

    private func validateClosePayload(_ payload: Data) throws {
        guard payload.count != 1 else { throw QuotaWebSocket.FrameError.protocolViolation }
        guard payload.count >= 2 else { return }
        let code = UInt16(payload[payload.startIndex]) << 8
            | UInt16(payload[payload.index(after: payload.startIndex)])
        let validCode = (code >= 1000 && code <= 1014 && ![1004, 1005, 1006].contains(code))
            || (code >= 3000 && code <= 4999)
        guard validCode else { throw QuotaWebSocket.FrameError.protocolViolation }
        let reason = payload.dropFirst(2)
        guard String(data: reason, encoding: .utf8) != nil else { throw WebSocketMessageError.invalidText }
    }

    private func sendClose(code: UInt16) async {
        var payload = Data()
        payload.append(UInt8((code >> 8) & 0xFF))
        payload.append(UInt8(code & 0xFF))
        await sendClose(payload: payload)
    }

    private func sendClose(payload: Data) async {
        guard !closeSent else { return }
        closeSent = true
        await sendFrame(opcode: 0x8, payload: payload)
    }

    private func sendFrame(opcode: UInt8, payload: Data) async {
        var frame = Data()
        frame.append(0x80 | opcode)
        appendPayloadLength(payload.count, to: &frame)
        frame.append(payload)
        await sendRaw(frame)
    }

    private func appendPayloadLength(_ length: Int, to frame: inout Data) {
        if length < 126 {
            frame.append(UInt8(length))
        } else if length < 65_536 {
            frame.append(126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127)
            let value = UInt64(length)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((value >> shift) & 0xFF))
            }
        }
    }

    private func receiveChunk() async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                guard error == nil, !isComplete || data?.isEmpty == false,
                      let data, !data.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    private func sendRaw(_ data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}
