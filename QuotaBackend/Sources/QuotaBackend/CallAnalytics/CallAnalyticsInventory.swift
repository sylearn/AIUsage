import Foundation

// MARK: - Call Analytics Inventory
// 探测「本地已安装」的 skill 与「已配置」的 MCP server，并按来源（Claude/Codex/OpenCode）归属，
// 用于按应用做零调用检测（某应用装了但从未调用）。尽力而为：某来源缺失/解析失败则跳过，不阻塞主统计。
// 仅覆盖三家 CLI；Cursor 自身用量不在这些日志里，故不扫 ~/.cursor（否则其技能/MCP 永远显示为僵尸，误导）。
// 注：各 CLI 的 MCP 命名/配置格式不一致（Codex 为 TOML），MCP 零调用判定为弱信号；skill 判定更可靠。

struct CallAnalyticsInventory {
    let homeDirectory: String
    var environment: [String: String] = ProcessInfo.processInfo.environment

    /// 「可清理」技能目录：仅用户自建 / 自行安装、能单独删除的技能目录，按来源归属。
    /// 内置（.cursor/skills-cursor）与插件缓存（plugins/cache）里的技能由工具 / 插件托管，
    /// 用户无法单独清理（只能卸载整个插件），故不计入零调用清单——
    /// 它们的调用仍由各事件源正常统计，不影响排行与「已用」判定。
    /// 目录名即 skill 名（与日志中 input.skill / state.input.name / SKILL.md 路径对应）。
    private var skillRoots: [(source: CallSourceKind, path: String)] {
        [
            (.claude, "\(homeDirectory)/.claude/skills"),
            (.codex, "\(homeDirectory)/.codex/skills"),
            (.opencode, "\(homeDirectory)/.config/opencode/skills")
        ]
    }

    /// MCP 配置文件，按来源归属。Claude 用 JSON（含项目级 projects.*.mcpServers），
    /// Codex 用 TOML（[mcp_servers.NAME]）。OpenCode 由统一 resolver 单独处理，
    /// 按 OpenCode 的全局/附加层合并后扫描。
    private var mcpConfigFiles: [(source: CallSourceKind, path: String, format: MCPConfigFormat)] {
        [
            (.claude, "\(homeDirectory)/.claude.json", .json),
            (.codex, "\(homeDirectory)/.codex/config.toml", .codexTOML)
        ]
    }

    private enum MCPConfigFormat {
        case json
        case codexTOML
    }

    private static let skillMarker = "SKILL.md"
    private static let skipDirectoryNames: Set<String> = ["node_modules", ".git", "Pods", "dist", "build"]

    func installedSkills() -> [InstalledItem] {
        var items = Set<InstalledItem>()
        for root in skillRoots {
            var names = Set<String>()
            collectSkillNames(root: root.path, into: &names)
            for name in names { items.insert(InstalledItem(source: root.source, name: name)) }
        }
        return items.sorted { ($0.name, $0.source.rawValue) < ($1.name, $1.source.rawValue) }
    }

    func installedMCPServers() -> [InstalledItem] {
        var items = Set<InstalledItem>()
        for config in mcpConfigFiles {
            var names = Set<String>()
            switch config.format {
            case .json: collectJSONMCPNames(path: config.path, into: &names)
            case .codexTOML: collectCodexTOMLMCPNames(path: config.path, into: &names)
            }
            for name in names { items.insert(InstalledItem(source: config.source, name: name)) }
        }

        let resolver = OpenCodeConfigResolver(homeDirectory: homeDirectory, environment: environment)
        var openCodeNames = Set<String>()
        if let object = resolver.readEffectiveObject() {
            addServerKeys(from: object, into: &openCodeNames)
        }
        for name in openCodeNames {
            items.insert(InstalledItem(source: .opencode, name: name))
        }
        return items.sorted { ($0.name, $0.source.rawValue) < ($1.name, $1.source.rawValue) }
    }

    // MARK: - Skills

    private func collectSkillNames(root: String, into names: inout Set<String>) {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root),
              let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return }

        for case let item as URL in enumerator {
            let component = item.lastPathComponent
            if Self.skipDirectoryNames.contains(component) {
                enumerator.skipDescendants()
                continue
            }
            guard component == Self.skillMarker else { continue }
            let skillDir = item.deletingLastPathComponent().lastPathComponent
            if !skillDir.isEmpty { names.insert(skillDir) }
        }
    }

    // MARK: - MCP servers (JSON: Claude / OpenCode)

    private func collectJSONMCPNames(path: String, into names: inout Set<String>) {
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        addServerKeys(from: object, into: &names)

        // Claude 的项目级配置：projects.<path>.mcpServers。
        if let projects = object["projects"] as? [String: Any] {
            for case let projectConfig as [String: Any] in projects.values {
                addServerKeys(from: projectConfig, into: &names)
            }
        }
    }

    private func addServerKeys(from object: [String: Any], into names: inout Set<String>) {
        for key in ["mcpServers", "mcp"] {
            if let servers = object[key] as? [String: Any] {
                for name in servers.keys {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { names.insert(trimmed) }
                }
            }
        }
    }

    // MARK: - MCP servers (TOML: Codex)

    /// 解析 Codex 的 ~/.codex/config.toml，取 [mcp_servers.NAME...] 表头里的首段 NAME。
    /// 形如 [mcp_servers.exa.env] / [mcp_servers.codebase-memory-mcp.tools.x] 仅记 server 名（exa / codebase-memory-mcp）。
    private func collectCodexTOMLMCPNames(path: String, into names: inout Set<String>) {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return }
        let prefix = "mcp_servers."
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // 仅表头 [..]，排除注释行（#…）与数组表 [[..]]。
            guard line.hasPrefix("["), !line.hasPrefix("[[") else { continue }
            // 取首个 ] 之前的内容，容忍表头后的行尾注释（如 `[mcp_servers.foo] # x`）。
            guard let close = line.firstIndex(of: "]") else { continue }
            let inner = line[line.index(after: line.startIndex)..<close]
            guard inner.hasPrefix(prefix) else { continue }
            if let name = Self.firstTOMLKeySegment(inner.dropFirst(prefix.count)),
               !name.isEmpty {
                names.insert(name)
            }
        }
    }

    /// 取 TOML 点分键的首段，支持引号包裹（如 "some.name"）。
    private static func firstTOMLKeySegment(_ raw: Substring) -> String? {
        var chars = raw
        if let quote = chars.first, quote == "\"" || quote == "'" {
            chars = chars.dropFirst()
            guard let end = chars.firstIndex(of: quote) else { return nil }
            return String(chars[chars.startIndex..<end])
        }
        if let dot = chars.firstIndex(of: ".") {
            return String(chars[chars.startIndex..<dot]).trimmingCharacters(in: .whitespaces)
        }
        return String(chars).trimmingCharacters(in: .whitespaces)
    }
}
