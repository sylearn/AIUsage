import Foundation
import QuotaBackend

// MARK: - Agent Visibility
// 把「侧边栏隐藏某个 agent 入口」同步到所有聚合统计界面（用量统计 / 调用分析 / 仪表盘 / 菜单栏）。
// 唯一桥接点：AppSection（侧边栏隐藏键）↔ 数据源标识（CallSourceKind / 本地 cost provider id /
// 官方配额 provider id）。隐藏状态来源: AppSettings.hiddenSidebarSections。
// 隐藏只影响展示，不删除菜单栏固定偏好；重新显示后原选择仍在。

/// 三个 CLI agent（数据源）的统一标识，避免各界面各写一份 Claude/Codex/OpenCode 平行表示。
enum AgentKind: String, CaseIterable {
    case claude
    case codex
    case opencode

    /// 对应的侧边栏导航 section——隐藏状态以其 rawValue 为键存于 hiddenSidebarSections。
    var section: AppSection {
        switch self {
        case .claude:   return .proxyManagement
        case .codex:    return .codexProxyManagement
        case .opencode: return .opencodeManagement
        }
    }

    /// 本地 cost provider 的 baseProviderId（仪表盘 / 用量统计 / 菜单栏费用行按此过滤）。
    var costProviderId: String {
        switch self {
        case .claude:   return "claude"
        case .codex:    return "codex-cost"
        case .opencode: return "opencode"
        }
    }

    /// 调用分析的后端来源标识。
    var callSourceKind: CallSourceKind {
        switch self {
        case .claude:   return .claude
        case .codex:    return .codex
        case .opencode: return .opencode
        }
    }
}

/// 依据「侧边栏隐藏集合」推导各界面应过滤掉的 agent / 数据源。
enum AgentVisibility {
    /// 该 agent 是否被用户在侧边栏隐藏。
    static func isHidden(_ agent: AgentKind, hidden: Set<String>) -> Bool {
        hidden.contains(agent.section.rawValue)
    }

    static func isVisible(_ agent: AgentKind, hidden: Set<String>) -> Bool {
        !isHidden(agent, hidden: hidden)
    }

    /// 未被隐藏的 agent（保持 claude → codex → opencode 顺序）。
    static func visibleAgents(hidden: Set<String>) -> [AgentKind] {
        AgentKind.allCases.filter { isVisible($0, hidden: hidden) }
    }

    /// 被隐藏 agent 对应的本地 cost provider id 集合。
    static func hiddenCostProviderIds(hidden: Set<String>) -> Set<String> {
        Set(AgentKind.allCases.filter { isHidden($0, hidden: hidden) }.map(\.costProviderId))
    }

    /// 被隐藏 agent 对应的调用分析来源集合。
    static func hiddenCallSources(hidden: Set<String>) -> Set<CallSourceKind> {
        Set(AgentKind.allCases.filter { isHidden($0, hidden: hidden) }.map(\.callSourceKind))
    }

    /// Catalog / live provider id → owning agent. Cursor 等订阅源没有对应侧边栏 agent。
    static func agent(forProviderId id: String) -> AgentKind? {
        switch id {
        case "claude": return .claude
        case "codex", "codex-cost": return .codex
        case "opencode": return .opencode
        default: return nil
        }
    }

    static func isProviderHidden(_ providerId: String, hidden: Set<String>) -> Bool {
        guard let agent = agent(forProviderId: providerId) else { return false }
        return isHidden(agent, hidden: hidden)
    }

    /// Claude / Codex / OpenCode 本地账本在目录里的 id。未刷新时 live category
    /// 可能是 nil，不能靠 `category != local-cost` 把它们当成配额账号。
    static func isLocalCostCatalogId(_ providerId: String) -> Bool {
        switch providerId {
        case "claude", "codex-cost", "opencode": return true
        default: return false
        }
    }

    static func isQuotaAccount(providerId: String, category: String?) -> Bool {
        if isLocalCostCatalogId(providerId) { return false }
        return category != ProviderCategory.localCost
    }

    static func isCostAccount(providerId: String, category: String?) -> Bool {
        if isLocalCostCatalogId(providerId) { return true }
        return category == ProviderCategory.localCost
    }
}
