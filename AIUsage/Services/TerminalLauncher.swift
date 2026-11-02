import AppKit
import QuotaBackend

// MARK: - Terminal Launcher
// 会话中心「继续对话」：把一次性 .command 脚本交给用户选的终端。
// 支持哪些终端、各自怎么启动定义在 QuotaBackend 的 SessionTerminal（可单测）；这里只负责显示名、安装检测和调用 NSWorkspace。
// 不用 AppleScript（Hardened Runtime 下需要额外 entitlement 和自动化授权）。
// 设计文档：docs/SESSION_CENTER_DESIGN.md §4

extension SessionTerminal {
    var displayName: String {
        switch self {
        case .ghostty: return "Ghostty"
        case .iterm2: return "iTerm2"
        case .warp: return "Warp"
        case .wezterm: return "WezTerm"
        case .kaku: return "Kaku"
        case .kitty: return "kitty"
        case .alacritty: return "Alacritty"
        case .terminal: return L("Terminal", "终端", key: "sessions.terminal.apple")
        }
    }

    /// 终端在执行前会请用户确认时的说明；nil 表示直接执行。
    var confirmationNote: String? {
        switch self {
        case .ghostty:
            return L("Ghostty asks before running", "Ghostty 会先请你确认", key: "sessions.terminal.ghostty_confirm")
        case .iterm2:
            return L("iTerm2 asks before running; you can turn the prompt off there",
                     "iTerm2 会先请你确认，可在弹窗里选择不再询问", key: "sessions.terminal.iterm2_confirm")
        case .warp, .wezterm, .kaku, .kitty, .alacritty, .terminal:
            return nil
        }
    }

    /// 废纸篓里的应用不算已安装。
    var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .flatMap { $0.path.contains("/.Trash/") ? nil : $0 }
    }

    var isInstalled: Bool { applicationURL != nil }

    /// 已安装的终端，按默认优先级排列。
    static var installed: [SessionTerminal] { allCases.filter(\.isInstalled) }
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
            switch terminal.launchMethod(scriptPath: script.path) {
            case .openScript:
                _ = try await NSWorkspace.shared.open([script], withApplicationAt: appURL, configuration: configuration)
            case .newInstance(let arguments):
                configuration.createsNewApplicationInstance = true
                configuration.arguments = arguments
                _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            }
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
