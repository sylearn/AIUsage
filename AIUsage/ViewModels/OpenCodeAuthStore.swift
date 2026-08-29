import Foundation
import os.log

// MARK: - OpenCode Auth Store
// 管理 ~/.local/share/opencode/auth.json：OpenCode 官方的凭据存放位置（`opencode auth login`
// 写的就是它），格式为 providerID → { "type": "api", "key": "<密钥>" }。OpenCode 启动时按
// provider id 取凭据并注入 SDK，配置文件因此不需要出现明文 key（issue #65）。
//
// 只接管 `aiusage*` 键（OpenCodeConfigManager.isManagedProviderKey）；用户自己 auth login
// 存的其他 provider 凭据原样保留。

private let openCodeAuthLog = Logger(subsystem: "com.aiusage.desktop", category: "OpenCodeAuth")

final class OpenCodeAuthStore {
    static let shared = OpenCodeAuthStore()

    private let fileManager = FileManager.default

    // MARK: - Paths

    /// OpenCode 的数据目录（`Global.Path.data`）：$XDG_DATA_HOME/opencode，默认 ~/.local/share/opencode。
    var directory: String {
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]?.nilIfBlank {
            return (xdg as NSString).appendingPathComponent("opencode")
        }
        let home = fileManager.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".local/share/opencode")
    }

    var path: String {
        (directory as NSString).appendingPathComponent("auth.json")
    }

    // MARK: - Read

    /// 现有凭据。文件缺失、损坏或不是 JSON 对象都按空处理：auth.json 不是本应用的真相源，
    /// 不能因为读不动它就阻断节点激活。
    func load() -> [String: Any] {
        guard let data = fileManager.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        return root
    }

    /// 受管 provider 当前记录的 API Key。
    func managedAPIKey(forProviderId providerId: String) -> String? {
        guard let entry = load()[providerId] as? [String: Any],
              entry["type"] as? String == "api" else { return nil }
        return (entry["key"] as? String)?.nilIfBlank
    }

    // MARK: - Write

    /// 让受管凭据恰好等于 `credentials`（providerId → API Key）：写入给定项，删除其余 `aiusage*` 项，
    /// 非受管项保留。返回是否写入成功——失败时调用方需回退到把 key 内联进配置，否则 opencode 无凭据可用。
    ///
    /// 传空字典即「清掉全部受管凭据」，用于停用/切到代理模式（代理模式配置里放的是 client key，
    /// 残留的直连密钥会覆盖它）。
    @discardableResult
    func syncManagedCredentials(_ credentials: [String: String]) -> Bool {
        var root = load()
        let managedKeys = root.keys.filter(OpenCodeConfigManager.isManagedProviderKey)
        for key in managedKeys {
            root.removeValue(forKey: key)
        }
        for (providerId, apiKey) in credentials where !apiKey.isEmpty {
            root[providerId] = ["type": "api", "key": apiKey]
        }

        // 无受管凭据可写、且文件本就不存在时不要凭空造一个空 auth.json。
        if root.isEmpty, !fileManager.fileExists(atPath: path) {
            return true
        }
        return write(root)
    }

    /// 清掉全部受管凭据（停用节点时调用）。
    @discardableResult
    func removeManagedCredentials() -> Bool {
        syncManagedCredentials([:])
    }

    private func write(_ root: [String: Any]) -> Bool {
        do {
            try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            // OpenCode 自己也把 auth.json 建成 0600；原子写换掉的是 inode，每次都要重设。
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch {
            openCodeAuthLog.error("Failed to write auth.json: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
