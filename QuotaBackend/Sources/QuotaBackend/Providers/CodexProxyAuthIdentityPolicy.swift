import Foundation

/// Codex `auth.json` 的最小身份分类。集中在可测试的后端层，避免激活、节点切换和恢复
/// 各自猜测 API key 是否属于 AIUsage 代理。
public enum CodexProxyAuthIdentity: Equatable, Sendable {
    case chatGPT
    case apiKey(String?)
    case other
}

public enum CodexProxyAuthIdentityPolicy {
    public static func classify(_ data: Data) -> CodexProxyAuthIdentity {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .other
        }

        if (object["auth_mode"] as? String)?.lowercased() == "chatgpt" {
            return .chatGPT
        }
        if let tokens = object["tokens"] as? [String: Any] {
            let refresh = (tokens["refresh_token"] as? String) ?? ""
            let access = (tokens["access_token"] as? String) ?? ""
            if !refresh.isEmpty || !access.isEmpty { return .chatGPT }
        }

        if (object["auth_mode"] as? String)?.lowercased() == "apikey" {
            let raw = (object["OPENAI_API_KEY"] as? String) ?? ""
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return .apiKey(key.isEmpty ? nil : key)
        }
        return .other
    }

    /// 是否应把当前 live identity 当作用户身份写入 `.aiusage.bak`。
    /// - 当前/上一把已知代理 key 与旧版空桩不备份；
    /// - ChatGPT、用户自己的 API key 和未知但可读的数据都保留；
    /// - 仅在旧版崩溃留下“有托管状态但没有 `.env` key”的歧义窗口中保守沿用原备份。
    public static func shouldStashCurrentAuth(
        _ data: Data,
        targetProxyAPIKey: String,
        knownManagedAPIKeys: Set<String>,
        managedStateExists: Bool
    ) -> Bool {
        switch classify(data) {
        case .chatGPT, .other:
            return true
        case .apiKey(nil):
            return false
        case .apiKey(let key?):
            if key == targetProxyAPIKey || knownManagedAPIKeys.contains(key) { return false }
            if managedStateExists, knownManagedAPIKeys.isEmpty { return false }
            return true
        }
    }
}
