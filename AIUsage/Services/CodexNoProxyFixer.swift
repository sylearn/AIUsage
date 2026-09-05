import Foundation
import AppKit
import os.log

// MARK: - Codex No-Proxy Fixer
// 激活 Codex 代理时写入 ~/.codex/.env 托管块：
//   - OPENAI_BASE_URL / OPENAI_API_KEY 钉到本地代理（节点身份），避免 ChatGPT 桌面端
//     无视自定义 provider 后空请求打到 api.openai.com（401 Missing bearer）。
//   - no_proxy / NO_PROXY 让 reqwest 跳过对 127.0.0.1 / localhost 的系统代理（否则 502）。
//
// 为什么写 ~/.codex/.env 而不是 shell 配置:
//   - codex 启动时会加载 ~/.codex/.env 并应用其中的环境变量（已实测生效）。
//   - 只影响 codex，不污染用户全局 shell 环境，也和 ~/.codex/config.toml 在同一目录。
//   - OPENAI_BASE_URL 必须是本地代理，不能写成节点上游，否则会绕过 QuotaServer。
//
// 幂等: 用 sentinel 块包裹，激活时写入 / 替换，停用时整块移除（若文件因此变空则删除）。

private let noProxyFixLog = Logger(subsystem: "com.aiusage.desktop", category: "CodexNoProxy")

enum CodexNoProxyFixer {

    /// 需要跳过代理的主机（仅本地回环）。
    static let bypassHosts = "127.0.0.1,localhost,::1"

    private static let blockBegin = "# >>> AIUSAGE no_proxy (managed, do not edit) >>>"
    private static let blockEnd = "# <<< AIUSAGE no_proxy <<<"

    /// 供 UI 展示 / 手动粘贴的等效环境变量。
    static var exportCommand: String {
        "no_proxy=\"\(bypassHosts)\"\nNO_PROXY=\"\(bypassHosts)\""
    }

    /// UI 展示用路径。
    static let displayEnvPath = "~/.codex/.env"

    // MARK: - Path

    /// 目标文件 ~/.codex/.env（与 CodexConfigManager 一致，使用当前用户主目录）。
    static var envFilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".codex/.env")
    }

    /// 上一次成功写入托管块的 client key。用于区分“旧节点代理桩”和用户自己的 API 身份；
    /// 读取失败返回 nil，真正写入前的文件快照仍会负责 fail-loud。
    static func managedAPIKeyIfPresent() -> String? {
        guard let existing = try? readIfExists(envFilePath) else { return nil }
        return identityFromManagedBlock(existing).apiKey
    }

    // MARK: - Apply / Remove

    /// 幂等写入受管理块。未传入 OPENAI_* 时保留块内已有值，避免系统代理路径把节点身份冲掉。
    static func apply(openAIBaseURL: String? = nil, openAIAPIKey: String? = nil) throws {
        let path = envFilePath
        let existing = try readIfExists(path) ?? ""
        let preserved = identityFromManagedBlock(existing)
        let url = firstNonEmpty(openAIBaseURL, preserved.baseURL)
        let key = firstNonEmpty(openAIAPIKey, preserved.apiKey)
        try writeManagedEnv(to: path, existing: existing, openAIBaseURL: url, openAIAPIKey: key)
        noProxyFixLog.info("managed .env block written to ~/.codex/.env")
    }

    /// 给独立 CODEX_HOME 写一份只含托管块的 .env（不读、不合并用户 ~/.codex/.env）。
    static func writeIsolatedEnv(to path: String, openAIBaseURL: String?, openAIAPIKey: String?) throws {
        try writeManagedEnv(to: path, existing: "", openAIBaseURL: openAIBaseURL, openAIAPIKey: openAIAPIKey)
    }

    /// 移除受管理块；若文件因此变空则删除整文件（不影响用户自定义内容）。
    static func remove() throws {
        let path = envFilePath
        guard let existing = try readIfExists(path), existing.contains(blockBegin) else {
            return
        }
        let stripped = stripManagedBlock(from: existing)
        if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                noProxyFixLog.error("Failed to remove ~/.codex/.env: \(String(describing: error), privacy: .public)")
                throw NoProxyFixError.failedToRemove
            }
            noProxyFixLog.info("~/.codex/.env removed (was managed-only)")
        } else {
            try write(stripped + "\n", to: path)
            noProxyFixLog.info("managed .env block stripped from ~/.codex/.env")
        }
    }

    // MARK: - Clipboard

    static func copyCommandToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportCommand, forType: .string)
    }

    // MARK: - Internal Helpers

    private static func writeManagedEnv(
        to path: String,
        existing: String,
        openAIBaseURL: String?,
        openAIAPIKey: String?
    ) throws {
        let stripped = stripManagedBlock(from: existing)
        let block = managedBlock(openAIBaseURL: openAIBaseURL, openAIAPIKey: openAIAPIKey)
        let merged = stripped.isEmpty ? block + "\n" : stripped + "\n\n" + block + "\n"
        try write(merged, to: path)
    }

    private static func managedBlock(openAIBaseURL: String?, openAIAPIKey: String?) -> String {
        var lines = [blockBegin]
        if let url = firstNonEmpty(openAIBaseURL, nil) {
            lines.append("OPENAI_BASE_URL=\(envQuoted(url))")
        }
        if let key = firstNonEmpty(openAIAPIKey, nil) {
            lines.append("OPENAI_API_KEY=\(envQuoted(key))")
        }
        lines.append("no_proxy=\"\(bypassHosts)\"")
        lines.append("NO_PROXY=\"\(bypassHosts)\"")
        lines.append(blockEnd)
        return lines.joined(separator: "\n")
    }

    private static func identityFromManagedBlock(_ content: String) -> (baseURL: String?, apiKey: String?) {
        var inBlock = false
        var baseURL: String?
        var apiKey: String?
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == blockBegin { inBlock = true; continue }
            if trimmed == blockEnd { break }
            guard inBlock else { continue }
            if let value = envAssignment(trimmed, key: "OPENAI_BASE_URL") { baseURL = value }
            if let value = envAssignment(trimmed, key: "OPENAI_API_KEY") { apiKey = value }
        }
        return (baseURL, apiKey)
    }

    private static func envAssignment(_ line: String, key: String) -> String? {
        guard line.hasPrefix(key) else { return nil }
        let rest = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("=") else { return nil }
        var raw = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
            raw = String(raw.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return raw.isEmpty ? nil : raw
    }

    private static func envQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func firstNonEmpty(_ primary: String?, _ fallback: String?) -> String? {
        let trimmed = primary?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        let other = fallback?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let other, !other.isEmpty { return other }
        return nil
    }

    private static func readIfExists(_ path: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            noProxyFixLog.error("Failed to read ~/.codex/.env: \(String(describing: error), privacy: .public)")
            throw NoProxyFixError.failedToRead
        }
    }

    private static func write(_ content: String, to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        guard let data = content.data(using: .utf8) else {
            throw NoProxyFixError.failedToWrite
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            noProxyFixLog.error("Failed to write ~/.codex/.env: \(String(describing: error), privacy: .public)")
            throw NoProxyFixError.failedToWrite
        }
    }

    /// 去掉已存在的受管理块（含起止 sentinel 行），并清理首尾多余空行。
    private static func stripManagedBlock(from content: String) -> String {
        var out: [String] = []
        var skipping = false
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == blockBegin { skipping = true; continue }
            if trimmed == blockEnd { skipping = false; continue }
            if skipping { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
    }
}

enum NoProxyFixError: LocalizedError {
    case failedToRead
    case failedToWrite
    case failedToRemove

    var errorDescription: String? {
        switch self {
        case .failedToRead:
            return AppSettings.shared.t(
                "Failed to read ~/.codex/.env.",
                "读取 ~/.codex/.env 失败。"
            )
        case .failedToWrite:
            return AppSettings.shared.t(
                "Failed to write ~/.codex/.env.",
                "写入 ~/.codex/.env 失败。"
            )
        case .failedToRemove:
            return AppSettings.shared.t(
                "Failed to remove the managed block from ~/.codex/.env.",
                "移除 ~/.codex/.env 托管块失败。"
            )
        }
    }
}
