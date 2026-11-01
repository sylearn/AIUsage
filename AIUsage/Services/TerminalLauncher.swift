import AppKit
import QuotaBackend

// MARK: - Terminal Launcher
// 会话中心「继续对话」：把一次性 .command 脚本交给用户选的终端打开。
// 三种终端走同一条路：NSWorkspace 用指定应用打开脚本。不用 AppleScript（Hardened Runtime 下需要额外授权）。
// 实测（2026-11）：终端、Warp 直接执行；Ghostty 出于安全策略会先弹「Allow Ghostty to execute …?」确认一次。
// 设计文档：docs/SESSION_CENTER_DESIGN.md §4

enum SessionTerminal: String, CaseIterable, Identifiable {
    case ghostty
    case warp
    case terminal

    var id: String { rawValue }

    var bundleIdentifier: String {
        switch self {
        case .ghostty: return "com.mitchellh.ghostty"
        case .warp: return "dev.warp.Warp-Stable"
        case .terminal: return "com.apple.Terminal"
        }
    }

    var displayName: String {
        switch self {
        case .ghostty: return "Ghostty"
        case .warp: return "Warp"
        case .terminal: return L("Terminal", "终端", key: "sessions.terminal.apple")
        }
    }

    /// 启动前需要用户在终端里确认一次的说明；nil 表示直接执行。
    var confirmationNote: String? {
        self == .ghostty
            ? L("Ghostty asks once before running", "Ghostty 会先请你确认一次", key: "sessions.terminal.ghostty_confirm")
            : nil
    }

    var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    var isInstalled: Bool { applicationURL != nil }

    /// 默认终端：按 Ghostty → Warp → 终端 取第一个已安装的。
    static var preferredDefault: SessionTerminal {
        allCases.first(where: \.isInstalled) ?? .terminal
    }
}

enum TerminalLauncherError: LocalizedError {
    case terminalNotInstalled
    case scriptWriteFailed
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .terminalNotInstalled:
            return L("This terminal is not installed.", "没有找到这个终端。", key: "sessions.error.terminal_missing")
        case .scriptWriteFailed:
            return L("Could not prepare the launch script.", "无法生成启动脚本。", key: "sessions.error.script")
        case .openFailed(let reason):
            return reason
        }
    }
}

enum TerminalLauncher {
    /// ~/Library/Caches/AIUsage/resume；目录 0700，脚本 0700，脚本启动后自删。
    nonisolated static var scriptDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIUsage/resume", isDirectory: true)
    }

    static func launch(_ plan: SessionResumePlan, in terminal: SessionTerminal) async throws {
        guard let appURL = terminal.applicationURL else { throw TerminalLauncherError.terminalNotInstalled }
        let script = try writeScript(plan.script())
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open([script], withApplicationAt: appURL, configuration: configuration)
        } catch {
            try? FileManager.default.removeItem(at: script)
            throw TerminalLauncherError.openFailed(error.localizedDescription)
        }
    }

    private static func writeScript(_ content: String) throws -> URL {
        let fileManager = FileManager.default
        let directory = scriptDirectory
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("resume-\(UUID().uuidString).command")
            guard fileManager.createFile(atPath: url.path, contents: Data(content.utf8), attributes: [.posixPermissions: 0o700]) else {
                throw TerminalLauncherError.scriptWriteFailed
            }
            return url
        } catch {
            throw TerminalLauncherError.scriptWriteFailed
        }
    }

    /// 清理一天前残留的脚本（正常情况下脚本启动后已自删）。
    nonisolated static func removeStaleScripts(olderThan age: TimeInterval = 86_400) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: scriptDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for file in files where file.pathExtension == "command" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fileManager.removeItem(at: file) }
        }
    }
}
