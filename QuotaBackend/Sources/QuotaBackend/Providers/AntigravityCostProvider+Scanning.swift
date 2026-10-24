import Foundation
import os.log

private let antigravityScanLog = Logger(subsystem: "com.aiusage.quotabackend", category: "AntigravityScanning")

// MARK: - Antigravity Cost Provider: File Scanning & Proxy Archive
// 负责扫描 ~/.gemini/antigravity/brain/*/transcript.jsonl 提取非代理 token，
// 以及读取 ~/.config/aiusage/usage-archive/proxy-usage-antigravity-v1.json 提取代理轨用量。

extension AntigravityCostProvider {

    private struct ProxyUsageModelAggDTO: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheCreateTokens: Int
        let costUSD: Double
        let requests: Int
        let pricingResolvedRequests: Int?
    }

    private struct ProxyUsageDayDTO: Decodable {
        let models: [String: ProxyUsageModelAggDTO]
    }

    private struct ProxyUsageArchiveDTO: Decodable {
        let version: Int
        let updatedAt: String
        let days: [String: ProxyUsageDayDTO]
    }

    func resolveBrainDirectory() -> String? {
        let path = (homeDirectory as NSString).appendingPathComponent(".gemini/antigravity/brain")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return path
    }

    func collectTranscriptFiles(brainDirectory: String, scanWindowCutoff: Date?) -> [String] {
        let fm = FileManager.default
        guard let conversations = try? fm.contentsOfDirectory(atPath: brainDirectory) else {
            return []
        }

        var files: [String] = []
        for convId in conversations {
            let logDir = (brainDirectory as NSString)
                .appendingPathComponent(convId)
                .appending("/.system_generated/logs")
            
            let transcriptPath = (logDir as NSString).appendingPathComponent("transcript.jsonl")
            var targetPath: String?
            if fm.fileExists(atPath: transcriptPath) {
                targetPath = transcriptPath
            } else {
                let fullPath = (logDir as NSString).appendingPathComponent("transcript_full.jsonl")
                if fm.fileExists(atPath: fullPath) {
                    targetPath = fullPath
                }
            }

            guard let foundPath = targetPath else { continue }

            if let scanWindowCutoff {
                if let attrs = try? fm.attributesOfItem(atPath: foundPath),
                   let mtime = attrs[.modificationDate] as? Date {
                    if mtime < scanWindowCutoff {
                        continue
                    }
                }
            }

            files.append(foundPath)
        }

        return files
    }

    func scanFiles(_ files: [String]) -> [String: CodexAggregateBucket] {
        let byFile = scanFilesByPath(files)
        var out: [String: CodexAggregateBucket] = [:]
        for fileBuckets in byFile.values {
            for (dKey, bucket) in fileBuckets {
                out[dKey, default: .empty].merge(bucket)
            }
        }
        return out
    }

    static func canonicalTranscriptKey(_ filePath: String) -> String {
        if filePath.hasSuffix("/transcript_full.jsonl") {
            return String(filePath.dropLast("/transcript_full.jsonl".count)) + "/transcript.jsonl"
        }
        if filePath == "transcript_full.jsonl" {
            return "transcript.jsonl"
        }
        return filePath
    }

    func scanFilesByPath(_ files: [String]) -> [String: [String: CodexAggregateBucket]] {
        var out: [String: [String: CodexAggregateBucket]] = [:]

        for filePath in files {
            let key = Self.canonicalTranscriptKey(filePath)
            #if canImport(Darwin)
            autoreleasepool {
                let fileBuckets = processFile(filePath)
                if !fileBuckets.isEmpty {
                    out[key] = fileBuckets
                }
            }
            #else
            let fileBuckets = processFile(filePath)
            if !fileBuckets.isEmpty {
                out[key] = fileBuckets
            }
            #endif
        }

        return out
    }

    private func processFile(_ filePath: String) -> [String: CodexAggregateBucket] {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return [:]
        }

        var currentModelKey = "gemini-3.8-flash" + Self.nonProxySourceSuffix
        var fileOut: [String: CodexAggregateBucket] = [:]

        content.enumerateLines { line, _ in
            if line.contains("\"USER_INPUT\""),
               line.contains("<USER_SETTINGS_CHANGE>"),
               line.contains("Model Selection"),
               let updatedModel = Self.extractSelectedModel(from: line) {
                currentModelKey = updatedModel + Self.nonProxySourceSuffix
            }

            guard line.contains("\"PLANNER_RESPONSE\"") && line.contains("\"input_tokens\"") else {
                return
            }

            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "PLANNER_RESPONSE" else {
                return
            }

            guard let createdAtStr = json["created_at"] as? String,
                  let createdAt = SharedFormatters.parseISO8601(createdAtStr) else {
                return
            }

            let inTokens = json["input_tokens"] as? Int ?? 0
            let outTokens = json["output_tokens"] as? Int ?? 0
            let cacheRead = json["cache_read_tokens"] as? Int ?? 0
            let total = inTokens + outTokens + cacheRead

            guard total > 0 else { return }

            let dKey = self.dayKey(createdAt)
            var bucket = fileOut[dKey] ?? .empty
            var m = bucket.models[currentModelKey] ?? CodexModelAggregate(model: currentModelKey)
            m.inputTokens += inTokens
            m.outputTokens += outTokens
            m.cacheReadTokens += cacheRead
            m.totalTokens += total
            m.estimatedCostUsd = 0

            bucket.models[currentModelKey] = m
            bucket.totalTokens += total
            bucket.usageRows += 1
            fileOut[dKey] = bucket
        }

        return fileOut
    }

    static func extractSelectedModel(from line: String) -> String? {
        guard line.contains("<USER_SETTINGS_CHANGE>"),
              let markerRange = line.range(of: "Model Selection") else { return nil }
        let tail = line[markerRange.upperBound...]
        guard let toRange = tail.range(of: " to ") else { return nil }
        let afterTo = tail[toRange.upperBound...]
        let rawModel: Substring
        if let dotRange = afterTo.range(of: ". No need") {
            rawModel = afterTo[..<dotRange.lowerBound]
        } else if let escapedNewline = afterTo.range(of: "\\n") {
            rawModel = afterTo[..<escapedNewline.lowerBound]
        } else if let newline = afterTo.range(of: "\n") {
            rawModel = afterTo[..<newline.lowerBound]
        } else if let closeTag = afterTo.range(of: "</USER_SETTINGS_CHANGE>") {
            rawModel = afterTo[..<closeTag.lowerBound]
        } else {
            rawModel = afterTo
        }
        let trimmed = String(rawModel).trimmingCharacters(in: CharacterSet(charactersIn: ". \t\r\n"))
        return normalizeSelectedModelName(trimmed)
    }

    static func normalizeSelectedModelName(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty, cleaned != "none" else { return nil }
        if cleaned.contains("gemini 4 argon") || cleaned.contains("gemini-4-argon") {
            return "gemini-4-argon"
        }
        if cleaned.contains("gemini 3.8 flash") || cleaned.contains("gemini-3.8-flash") {
            return "gemini-3.8-flash"
        }
        if cleaned.contains("gemini 3.1 pro") || cleaned.contains("gemini-3.1-pro") {
            return "gemini-3.1-pro"
        }
        if cleaned.contains("gemini 3 pro") || cleaned.contains("gemini-3-pro") {
            return "gemini-3-pro"
        }
        if cleaned.contains("gemini 2.5 pro") || cleaned.contains("gemini-2.5-pro") {
            return "gemini-2.5-pro"
        }
        if cleaned.contains("gemini 2.5 flash") || cleaned.contains("gemini-2.5-flash") {
            return "gemini-2.5-flash"
        }
        if cleaned.contains("claude opus 4.6") || cleaned.contains("claude-opus-4-6") || cleaned.contains("claude-opus-4.6") {
            return "claude-opus-4.6"
        }
        if cleaned.contains("claude sonnet 4.6") || cleaned.contains("claude-sonnet-4-6") || cleaned.contains("claude-sonnet-4.6") {
            return "claude-sonnet-4.6"
        }
        if cleaned.contains("claude 3.7 sonnet") || cleaned.contains("claude-3-7-sonnet") || cleaned.contains("claude-3.7-sonnet") {
            return "claude-3.7-sonnet"
        }
        if cleaned.contains("gpt-oss") {
            return "gpt-oss-120b"
        }
        // Fallback for any newly introduced model in <USER_SETTINGS_CHANGE>:
        // strip trailing parenthetical mode tags like "(high)" or "(thinking)" and slugify,
        // so new models never inherit the previous model's token attribution.
        let withoutParen: String
        if let parenIndex = cleaned.firstIndex(of: "(") {
            withoutParen = String(cleaned[..<parenIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            withoutParen = cleaned
        }
        let slug = withoutParen
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return slug.isEmpty ? "unknown-model" : slug
    }

    // MARK: - Proxy Archive

    func proxyUsageArchivePath() -> String {
        (homeDirectory as NSString)
            .appendingPathComponent(".config/aiusage/usage-archive/proxy-usage-antigravity-v1.json")
    }

    func loadProxyArchive() -> [String: CodexAggregateBucket] {
        let path = proxyUsageArchivePath()
        guard let data = FileManager.default.contents(atPath: path),
              let dto = try? JSONDecoder().decode(ProxyUsageArchiveDTO.self, from: data) else {
            return [:]
        }

        var out: [String: CodexAggregateBucket] = [:]
        for (day, dayDTO) in dto.days {
            var bucket = CodexAggregateBucket.empty
            for (rawModel, modelDTO) in dayDTO.models {
                let modelKey = rawModel.hasSuffix(Self.proxySourceSuffix) ? rawModel : (rawModel + Self.proxySourceSuffix)
                var m = CodexModelAggregate(model: modelKey)
                m.inputTokens = modelDTO.inputTokens
                m.outputTokens = modelDTO.outputTokens
                m.cacheReadTokens = modelDTO.cacheReadTokens
                m.cacheCreateTokens = modelDTO.cacheCreateTokens
                m.totalTokens = modelDTO.inputTokens + modelDTO.outputTokens + modelDTO.cacheReadTokens + modelDTO.cacheCreateTokens
                m.estimatedCostUsd = modelDTO.costUSD

                bucket.models[modelKey] = m
                bucket.totalTokens += m.totalTokens
                bucket.estimatedCostUsd += m.estimatedCostUsd
                bucket.usageRows += modelDTO.requests
            }
            if !bucket.models.isEmpty {
                out[day] = bucket
            }
        }
        return out
    }
}
