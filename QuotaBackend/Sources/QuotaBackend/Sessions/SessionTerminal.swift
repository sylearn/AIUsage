import Foundation

// MARK: - Session Center · Terminals
// 「继续对话」支持的 macOS 终端，以及把一次性 `.command` 脚本交给各终端的方式。
// 每个终端的行为都实测过或读源码确认过（2026-11），见 docs/SESSION_CENTER_DESIGN.md §4.3。
//
// - openScript：用该终端打开脚本，在已运行的实例里开新窗口。iTerm2 首次、Ghostty 每次会先请用户确认。
// - newInstance：新开一个进程，通过启动参数运行脚本。
//   WezTerm / Kaku 用 `start`：没在运行时由新进程开第一个窗口，已在运行时转交给原实例后退出
//   （打开脚本在冷启动时会被它丢掉，实测）。kitty、Alacritty 是独立实例，窗口关掉后退出。
//   Ghostty 不走这条路：新实例会恢复用户保存的窗口，退出时还会覆盖保存的布局。
//   脚本路径包在 `/bin/sh -c` 的字符串里，不单独作为参数：macOS 会把启动参数里现成的文件路径当成「打开文件」请求。

public enum SessionTerminal: String, CaseIterable, Identifiable, Sendable {
    // 顺序即默认优先级：没有选过时取第一个已安装的；系统终端兜底。
    case ghostty
    case iterm2
    case warp
    case wezterm
    case kaku
    case kitty
    case alacritty
    case terminal

    public enum LaunchMethod: Equatable, Sendable {
        case openScript
        case newInstance(arguments: [String])
    }

    public var id: String { rawValue }

    public var bundleIdentifier: String {
        switch self {
        case .ghostty: return "com.mitchellh.ghostty"
        case .iterm2: return "com.googlecode.iterm2"
        case .warp: return "dev.warp.Warp-Stable"
        case .wezterm: return "com.github.wez.wezterm"
        case .kaku: return "fun.tw93.kaku"
        case .kitty: return "net.kovidgoyal.kitty"
        case .alacritty: return "org.alacritty"
        case .terminal: return "com.apple.Terminal"
        }
    }

    public func launchMethod(scriptPath: String) -> LaunchMethod {
        switch self {
        case .kitty:
            // kitty 默认关掉最后一个窗口后仍驻留，这里让这个实例跟着窗口退出。
            return .newInstance(arguments: ["-o", "macos_quit_when_last_window_closed=yes"] + Self.runScript(scriptPath))
        case .alacritty:
            return .newInstance(arguments: ["-e"] + Self.runScript(scriptPath))
        case .wezterm, .kaku:
            return .newInstance(arguments: ["start", "--"] + Self.runScript(scriptPath))
        case .ghostty, .iterm2, .warp, .terminal:
            return .openScript
        }
    }

    static func runScript(_ path: String) -> [String] {
        ["/bin/sh", "-c", "exec " + SessionResumePlan.quote(path)]
    }
}
