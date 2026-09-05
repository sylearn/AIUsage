import Foundation

extension CodexCostProvider {
    func parseFile(
        _ path: String,
        metadata: SessionMetadata?,
        routing: CodexProxyRoutingSnapshot,
        proxyCoverage: inout CodexProxyRoutingSnapshot.Days,
        inheritedTotals: (String, String) -> CodexTotals?
    ) -> CodexFileAggregate {
        var currentModel: String?
        var previousTotals: CodexTotals?
        let inherited = metadata.flatMap { meta -> CodexTotals? in
            guard let parentId = meta.forkedFromId else { return nil }
            return inheritedTotals(parentId, meta.forkTimestamp ?? "")
        }
        var remainingInherited = inherited
        var aggregate = CodexFileAggregate(sessionId: metadata?.sessionId)
        let provider = metadata?.modelProvider

        scanJSONLLines(
            path,
            matching: [
                Self.tokenCountNeedle,
                Self.turnContextNeedle,
                Self.sessionMetaNeedle
            ],
            maxLineBytes: 1024 * 1024,
            prefixBytes: 1024 * 1024
        ) { data in
            guard data.range(of: Self.tokenCountNeedle) != nil
                || data.range(of: Self.turnContextNeedle) != nil
                || data.range(of: Self.sessionMetaNeedle) != nil else {
                return
            }

            if data.range(of: Self.compactTurnContextTypeNeedle) != nil {
                currentModel = extractJSONStringField("model", from: data) ?? currentModel
                return
            }

            if data.range(of: Self.sessionMetaNeedle) != nil {
                return
            }

            guard let tsText = extractJSONStringField("timestamp", from: data),
                  let timestamp = parseTimestamp(tsText) else {
                return
            }

            if data.range(of: Self.turnContextNeedle) != nil {
                currentModel = extractJSONStringField("model", from: data) ?? currentModel
                return
            }

            guard data.range(of: Self.compactEventMsgTypeNeedle) != nil else { return }

            guard data.range(of: Self.tokenCountNeedle) != nil else { return }

            let modelFromInfo = firstNonEmpty(
                extractJSONStringField("model", from: data),
                extractJSONStringField("model_name", from: data)
            )
            let baseModel = normalizeModel(modelFromInfo ?? currentModel ?? "gpt-5")

            var delta = CodexTotals(input: 0, cached: 0, output: 0)

            if let rawTotals = tokenUsageTotals(named: "total_token_usage", in: data) {
                let currentTotals: CodexTotals
                if let inherited {
                    currentTotals = CodexTotals(
                        input: max(0, rawTotals.input - inherited.input),
                        cached: max(0, rawTotals.cached - inherited.cached),
                        output: max(0, rawTotals.output - inherited.output)
                    )
                } else {
                    currentTotals = rawTotals
                }
                let previous = previousTotals ?? CodexTotals(input: 0, cached: 0, output: 0)
                delta = CodexTotals(
                    input: max(0, currentTotals.input - previous.input),
                    cached: max(0, currentTotals.cached - previous.cached),
                    output: max(0, currentTotals.output - previous.output)
                )
                previousTotals = currentTotals
                remainingInherited = nil
            } else if let rawDelta = tokenUsageTotals(named: "last_token_usage", in: data) {
                delta = adjustedLastDelta(rawDelta, remainingInherited: &remainingInherited)
                let previous = previousTotals ?? CodexTotals(input: 0, cached: 0, output: 0)
                previousTotals = CodexTotals(
                    input: previous.input + delta.input,
                    cached: previous.cached + delta.cached,
                    output: previous.output + delta.output
                )
            } else {
                return
            }

            guard delta.input > 0 || delta.cached > 0 || delta.output > 0 else { return }
            let cached = min(delta.cached, delta.input)
            let nonCachedInput = max(0, delta.input - cached)
            let residual = consumeProxyCoverage(
                day: dayKey(timestamp),
                model: baseModel,
                inputTokens: nonCachedInput,
                cacheReadTokens: cached,
                cacheCreateTokens: 0,
                outputTokens: delta.output,
                from: &proxyCoverage
            )

            // 旧 aiusage-proxy 会话迁移前的全部行已经进入代理归档；迁移后才允许账号/API 混合。
            if routing.isLegacyProxyRow(sessionID: metadata?.sessionId, timestamp: timestamp) {
                return
            }
            guard let model = sourceTaggedModel(baseModel, provider: provider) else { return }
            let residualTotal = residual.input + residual.cached + residual.output
            guard residualTotal > 0 else { return }
            let row = CodexRow(
                dayKey: dayKey(timestamp),
                model: model,
                inputTokens: residual.input,
                cacheReadTokens: residual.cached,
                outputTokens: residual.output,
                totalTokens: residualTotal,
                estimatedCostUsd: 0
            )
            aggregate.record(row: row, hourKey: hourBucketKey(timestamp))
        }

        return aggregate
    }

    /// 从 JSONL 的总 token 中扣掉同一会话、同一天、同一请求模型实际经过 AIUsage 网关的部分。
    /// 剩余量才属于账号或其它非 AIUsage 路径；组件分别扣减，避免缓存 token 被重复归类。
    func consumeProxyCoverage(
        day: String,
        model: String,
        inputTokens: Int,
        cacheReadTokens: Int,
        cacheCreateTokens: Int,
        outputTokens: Int,
        from coverage: inout CodexProxyRoutingSnapshot.Days
    ) -> (input: Int, cached: Int, cacheCreate: Int, output: Int) {
        guard var models = coverage[day], var proxy = models[model] else {
            return (inputTokens, cacheReadTokens, cacheCreateTokens, outputTokens)
        }

        let usedInput = min(inputTokens, proxy.inputTokens)
        let usedCacheRead = min(cacheReadTokens, proxy.cacheReadTokens)
        let usedCacheCreate = min(cacheCreateTokens, proxy.cacheCreateTokens)
        let usedOutput = min(outputTokens, proxy.outputTokens)
        proxy.inputTokens -= usedInput
        proxy.cacheReadTokens -= usedCacheRead
        proxy.cacheCreateTokens -= usedCacheCreate
        proxy.outputTokens -= usedOutput
        models[model] = proxy
        coverage[day] = models

        return (
            inputTokens - usedInput,
            cacheReadTokens - usedCacheRead,
            cacheCreateTokens - usedCacheCreate,
            outputTokens - usedOutput
        )
    }

    func scanJSONLLines(
        _ path: String,
        matching needles: [Data] = [],
        maxLineBytes: Int,
        prefixBytes: Int,
        onLine: (Data) -> Void
    ) {
        let effectivePrefixBytes = max(1, min(prefixBytes, maxLineBytes))
        var lineBuffer = Data()
        lineBuffer.reserveCapacity(min(effectivePrefixBytes, 32 * 1024))

        func appendSegment(_ segment: Data.SubSequence) {
            guard !segment.isEmpty else { return }
            guard lineBuffer.count < effectivePrefixBytes else { return }
            let remaining = effectivePrefixBytes - lineBuffer.count
            if segment.count <= remaining {
                lineBuffer.append(contentsOf: segment)
            } else {
                lineBuffer.append(contentsOf: segment.prefix(remaining))
            }
        }

        func flushLine() {
            defer {
                lineBuffer.removeAll(keepingCapacity: true)
            }
            guard !lineBuffer.isEmpty,
                  lineMatches(lineBuffer, in: lineBuffer.startIndex..<lineBuffer.endIndex, needles: needles) else {
                return
            }
            let line = lineBuffer
            autoreleasepool {
                onLine(line)
            }
        }

        #if canImport(Darwin)
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }

        let chunkSize = 128 * 1024
        var readBuffer = [UInt8](repeating: 0, count: chunkSize)

        func appendPointer(_ pointer: UnsafePointer<UInt8>, count: Int) {
            guard count > 0, lineBuffer.count < effectivePrefixBytes else { return }
            let countToAppend = min(count, effectivePrefixBytes - lineBuffer.count)
            lineBuffer.append(pointer, count: countToAppend)
        }

        while true {
            let bytesRead = readBuffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return Darwin.read(fd, base, chunkSize)
            }
            if bytesRead <= 0 { break }

            readBuffer.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < bytesRead {
                    let remaining = bytesRead - offset
                    if let found = memchr(base.advanced(by: offset), 0x0A, remaining) {
                        let newline = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
                        appendPointer(base.advanced(by: offset), count: newline - offset)
                        flushLine()
                        offset = newline + 1
                    } else {
                        appendPointer(base.advanced(by: offset), count: remaining)
                        offset = bytesRead
                    }
                }
            }
        }
        flushLine()
        #else
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { handle.closeFile() }

        let newline = Data([0x0A])
        let chunkSize = 256 * 1024

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }

            var searchStart = chunk.startIndex
            while searchStart < chunk.endIndex,
                  let newlineRange = chunk.range(of: newline, options: [], in: searchStart..<chunk.endIndex) {
                appendSegment(chunk[searchStart..<newlineRange.lowerBound])
                flushLine()
                searchStart = newlineRange.upperBound
            }

            if searchStart < chunk.endIndex {
                appendSegment(chunk[searchStart..<chunk.endIndex])
            }
        }
        flushLine()
        #endif
    }

    func lineMatches(_ data: Data, in range: Range<Data.Index>, needles: [Data]) -> Bool {
        guard !needles.isEmpty else { return true }
        for needle in needles where data.range(of: needle, options: [], in: range) != nil {
            return true
        }
        return false
    }

    func adjustedLastDelta(_ rawDelta: CodexTotals, remainingInherited: inout CodexTotals?) -> CodexTotals {
        guard var remaining = remainingInherited else { return rawDelta }
        let adjusted = CodexTotals(
            input: max(0, rawDelta.input - remaining.input),
            cached: max(0, rawDelta.cached - remaining.cached),
            output: max(0, rawDelta.output - remaining.output)
        )
        remaining.input = max(0, remaining.input - rawDelta.input)
        remaining.cached = max(0, remaining.cached - rawDelta.cached)
        remaining.output = max(0, remaining.output - rawDelta.output)
        remainingInherited = (remaining.input == 0 && remaining.cached == 0 && remaining.output == 0) ? nil : remaining
        return adjusted
    }

    func extractJSONStringField(_ field: String, from data: Data) -> String? {
        let needle = Data("\"\(field)\"".utf8)
        var searchStart = data.startIndex

        while searchStart < data.endIndex,
              let keyRange = data.range(of: needle, options: [], in: searchStart..<data.endIndex) {
            var index = keyRange.upperBound
            skipJSONWhitespace(in: data, index: &index)
            guard index < data.endIndex, data[index] == 0x3A else {
                searchStart = keyRange.upperBound
                continue
            }

            index += 1
            skipJSONWhitespace(in: data, index: &index)
            guard index < data.endIndex, data[index] == 0x22 else {
                searchStart = keyRange.upperBound
                continue
            }

            index += 1
            var bytes: [UInt8] = []
            bytes.reserveCapacity(32)
            var escaped = false
            while index < data.endIndex {
                let byte = data[index]
                index += 1
                if escaped {
                    bytes.append(byte)
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    return String(bytes: bytes, encoding: .utf8)
                } else {
                    bytes.append(byte)
                }
            }
            return nil
        }

        return nil
    }

    func skipJSONWhitespace(in data: Data, index: inout Data.Index) {
        while index < data.endIndex {
            switch data[index] {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            default:
                return
            }
        }
    }

    func tokenUsageTotals(named field: String, in data: Data) -> CodexTotals? {
        guard let range = jsonObjectRange(named: field, in: data) else { return nil }
        let cached = jsonIntField("cached_input_tokens", in: data, range: range)
        let cacheRead = jsonIntField("cache_read_input_tokens", in: data, range: range)
        return CodexTotals(
            input: jsonIntField("input_tokens", in: data, range: range),
            cached: cached > 0 ? cached : cacheRead,
            output: jsonIntField("output_tokens", in: data, range: range)
        )
    }

    func jsonObjectRange(named field: String, in data: Data) -> Range<Data.Index>? {
        let needle = Data("\"\(field)\"".utf8)
        guard let keyRange = data.range(of: needle) else { return nil }
        var index = keyRange.upperBound
        skipJSONWhitespace(in: data, index: &index)
        guard index < data.endIndex, data[index] == 0x3A else { return nil }
        index += 1
        skipJSONWhitespace(in: data, index: &index)
        guard index < data.endIndex, data[index] == 0x7B else { return nil }

        let start = index
        var depth = 0
        var inString = false
        var escaped = false
        while index < data.endIndex {
            let byte = data[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
            } else if byte == 0x22 {
                inString = true
            } else if byte == 0x7B {
                depth += 1
            } else if byte == 0x7D {
                depth -= 1
                if depth == 0 {
                    return start..<data.index(after: index)
                }
            }
            index += 1
        }
        return nil
    }

    func jsonIntField(_ field: String, in data: Data, range: Range<Data.Index>) -> Int {
        let needle = Data("\"\(field)\"".utf8)
        guard let keyRange = data.range(of: needle, options: [], in: range) else { return 0 }
        var index = keyRange.upperBound
        skipJSONWhitespace(in: data, index: &index)
        guard index < range.upperBound, data[index] == 0x3A else { return 0 }
        index += 1
        skipJSONWhitespace(in: data, index: &index)

        if index < range.upperBound, data[index] == 0x22 {
            index += 1
        }

        var sign = 1
        if index < range.upperBound, data[index] == 0x2D {
            sign = -1
            index += 1
        }

        var value = 0
        var sawDigit = false
        while index < range.upperBound {
            let byte = data[index]
            guard byte >= 0x30, byte <= 0x39 else { break }
            sawDigit = true
            value = value * 10 + Int(byte - 0x30)
            index += 1
        }
        return sawDigit ? max(0, value * sign) : 0
    }

    // MARK: - Aggregation

    struct TimelineBucket {
        let bucket: String
        let label: String
        let estimatedCostUsd: Double
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheReadTokens: Int = 0
        var cacheCreateTokens: Int = 0
        let totalTokens: Int
    }
}
