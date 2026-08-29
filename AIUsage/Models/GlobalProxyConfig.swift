import Foundation
import os.log

// MARK: - Global Proxy Track
// 每个产品轨道各自拥有一条固定入口、一个 QuotaServer 进程和一份独立持久化配置。
enum GlobalProxyTrack: String, Codable, CaseIterable {
    case codex
    case claude
    /// Claude Desktop owns an independent product gateway and port. It shares
    /// Node Runtime endpoints with other products, never gateway state.
    case desktop
    case opencode
    /// Claude Science：免订阅启动 Science（隔离沙箱 + 本地虚拟登录），推理经独立产品网关走共享 Node Runtime。
    case science

    /// 持久化文件名（~/.config/aiusage 下）。
    var configFileName: String { "global-proxy-\(rawValue).json" }
}

/// Compatibility model for decoding the pre-0.16 shared Claude Gateway file.
/// New product tracks never use this set for runtime ownership.
enum ClaudeGatewayConsumer: String, Codable, CaseIterable, Hashable {
    case code
    case desktop
}

/// The model surface published to Claude Desktop. This is independent from
/// the legacy shared-Gateway attachment flag retained for migration.
enum ClaudeDesktopCatalogMode: String, Codable, CaseIterable, Identifiable {
    /// Fixed Opus/Sonnet/Haiku identities; node switches only remap tiers.
    case smartRoutes
    /// Every model in the selected node, with its real display name.
    case fullNodeCatalog

    var id: String { rawValue }
}

/// The four application-facing model entries shared by Code and Desktop.
/// Nodes remain the source of truth; each product may keep a sparse, per-node
/// projection without mutating that shared node configuration.
enum ClaudeAppModelRoute: String, Codable, CaseIterable, Identifiable {
    case defaultModel = "default"
    case opus
    case sonnet
    case haiku

    var id: String { rawValue }
    var title: String {
        switch self {
        case .defaultModel: return "Default"
        case .opus: return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku: return "Haiku"
        }
    }
}

struct ClaudeAppNodeModelOverride: Codable, Equatable {
    var defaultModel: String? = nil
    var opus: String? = nil
    var sonnet: String? = nil
    var haiku: String? = nil

    var isEmpty: Bool {
        defaultModel?.nilIfBlank == nil
            && opus?.nilIfBlank == nil
            && sonnet?.nilIfBlank == nil
            && haiku?.nilIfBlank == nil
    }

    func model(for route: ClaudeAppModelRoute) -> String? {
        switch route {
        case .defaultModel: return defaultModel?.nilIfBlank
        case .opus: return opus?.nilIfBlank
        case .sonnet: return sonnet?.nilIfBlank
        case .haiku: return haiku?.nilIfBlank
        }
    }

    mutating func setModel(_ model: String?, for route: ClaudeAppModelRoute) {
        switch route {
        case .defaultModel: defaultModel = model?.nilIfBlank
        case .opus: opus = model?.nilIfBlank
        case .sonnet: sonnet = model?.nilIfBlank
        case .haiku: haiku = model?.nilIfBlank
        }
    }
}

struct ClaudeAppResolvedModels: Equatable {
    let defaultModel: String
    let opus: String
    let sonnet: String
    let haiku: String

    func model(for route: ClaudeAppModelRoute) -> String {
        switch route {
        case .defaultModel: return defaultModel
        case .opus: return opus
        case .sonnet: return sonnet
        case .haiku: return haiku
        }
    }
}

// MARK: - Global Proxy Config
// 全局统一代理：给某条轨一个「固定入口」——固定端口 + 固定 client key + 固定虚拟模型名，
// CLI 一次性指向它即可。切换激活节点只在常驻代理进程内热替换上游（base_url/key/model），
// 进程不重启、端口不变、CLI 配置不重写，因此正在运行的 CLI 无感。
//
// 数据来源/写入目标: ~/.config/aiusage/global-proxy-<track>.json（含 client key，0600 权限）。
// 工作方式: isEnabled=true 时接管对应 CLI 配置（config.toml / settings.json / opencode.json）并拉起常驻代理。
//
// 模型字段语义：
//   - Codex / OpenCode：仅用 virtualModel（单一虚拟模型名）。
//   - Claude：三层模型 virtualModel(=opus) / sonnetModel / haikuModel；值需含 opus/sonnet/haiku
//     关键字，便于后端按层映射到激活节点的真实 big/middle/small 模型。

private let globalProxyLog = Logger(subsystem: "com.aiusage.desktop", category: "GlobalProxy")

/// Claude Science 沙箱工作区：每个工作区对应独立 data-dir；技术 email 由 id 派生，不暴露给用户。
struct ScienceWorkspace: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var name: String
}

struct GlobalProxyConfig: Codable, Equatable {
    /// 是否启用全局代理模式。Claude 轨中这是 `hasClaudeConsumers` 的兼容聚合镜像；
    /// 任何产品级判断都必须使用下面的 consumer 字段，不能再用这个总开关推断 Code 状态。
    var isEnabled: Bool
    /// 常驻监听端口（固定，CLI 永远指向它）。
    var port: Int
    /// 对客户端固定不变的 client key。
    var clientKey: String
    /// 主虚拟模型名（Codex/OpenCode 唯一模型；Claude 的 opus 层）。
    var virtualModel: String
    /// Claude sonnet 层虚拟模型名（仅 Claude 轨使用）。
    var sonnetModel: String?
    /// Claude haiku 层虚拟模型名（仅 Claude 轨使用）。
    var haikuModel: String?
    /// OpenCode 轨选定的接口协议（仅 OpenCode 轨使用）。决定 CLI 受管块的 npm 包、后端复用的透传轨道、
    /// 以及可参与切换的节点集合（只能切同接口节点，保证格式兼容）。旧档案缺省为 OpenAI 兼容。
    var openCodeInterface: OpenCodeProtocol?
    /// 当前激活的参与节点 id；nil 表示未选定。
    var activeNodeId: String?
    /// Code Gateway connection state. The optional field remains for decoding
    /// the pre-0.16 shared-Gateway file; missing values migrate from isEnabled.
    var claudeCodeEnabled: Bool? = nil
    /// Claude Desktop 官方 3P profile consumer；与 Code 配置/鉴权独立。
    var claudeDesktopEnabled: Bool? = nil
    /// 缺省保持 0.15 的完整节点目录行为，避免升级后静默隐藏模型。
    var claudeDesktopCatalogMode: ClaudeDesktopCatalogMode? = nil
    /// Code's public model surface. Reuses the same two durable wire values as
    /// Desktop: stable tier routes or the selected node's exact catalog.
    var claudeCodeCatalogMode: ClaudeDesktopCatalogMode? = nil
    /// Sparse Code-only model overrides keyed by node id. Missing tiers always
    /// follow the node's current defaults, so later node edits remain visible.
    var claudeCodeModelOverridesByNode: [String: ClaudeAppNodeModelOverride]? = nil
    /// Sparse Desktop-only overrides. They are used only by hot-switch routes;
    /// the full node catalog continues to expose exact node-owned identities.
    var claudeDesktopModelOverridesByNode: [String: ClaudeAppNodeModelOverride]? = nil
    /// Claude Desktop 专用 HTTPS listener，默认 14403。
    var claudeDesktopHTTPSPort: Int? = nil
    /// 只供本地 Desktop profile 使用的独立随机 key（配置文件本身为 0600）。
    var claudeDesktopClientKey: String? = nil
    /// 遗留：1M 能力曾是「Desktop 轨的偏好」，现已提升为节点的模型能力
    /// （`ProxyConfiguration.modelCatalog.supports1MModels`），Code 与 Desktop 共用一份。
    /// 保留此字段仅为读旧档并一次性搬迁；迁移完成后置空，不再写入。
    var claudeDesktopSupports1MByNode: [String: [String: Bool]]? = nil
    /// Science 沙箱监听端口（仅 Science 轨；即 `claude-science serve --port`）。缺省 14410（AIUsage 端口族）。
    var sciencePort: Int? = nil
    /// 遗留：旧版可编辑假邮箱。现由 `activeScienceWorkspaceId` 派生 `…@cslocal.invalid`，读档后会被覆盖。
    var sandboxEmail: String? = nil
    /// Science 沙箱工作区列表（仅 Science 轨）。缺省一个「默认」工作区。
    var scienceWorkspaces: [ScienceWorkspace]? = nil
    /// 当前激活的沙箱工作区 id。接管模式下忽略，固定走 adopt 目录。
    var activeScienceWorkspaceId: String? = nil
    /// 接管真实实例（仅 Science 轨）：内部 daemon 跑在独立 data-dir、由 8765 反向代理注入会话，
    /// 使双击桌面 app 也免登录。**不触碰真实 ~/.claude-science 凭证**，仅改写运行期 operon.lock（停用即删）。
    /// 缺省 false（安全默认，只做隔离沙箱）。
    var adoptRealInstance: Bool? = nil
    /// 是否允许局域网访问（监听 0.0.0.0 而非 127.0.0.1）。缺省 false（安全默认，仅本机可用）。
    var allowLAN: Bool? = nil

    // MARK: Defaults

    // 全局代理端口提到 1 万段（避开常用低端口、降低与其他本地服务冲突概率）。
    static let defaultCodexPort = 14399
    static let defaultClaudePort = 14400
    static let defaultClaudeDesktopGatewayPort = 14404
    static let defaultClaudeDesktopHTTPSPort = 14403
    static let defaultOpenCodePort = 14401
    // Science 轨端口全部落在 AIUsage 自有的 144xx 端口族（区别于其它同类工具，避免撞常用端口）：
    // 代理端口 14402、沙箱公开入口 14410、接管内部 daemon 14411、沙箱内部 daemon 14412；
    // 对外唯一例外是 8765（桌面 app 硬编码默认端口）。
    static let defaultSciencePort = 14402
    static let defaultScienceListenPort = 14410
    /// 默认沙箱的内部 daemon 端口。浏览器只访问 `defaultScienceListenPort`，
    /// `ScienceAuthProxy` 在二者之间反代并提供即时模型目录。
    static let defaultScienceSandboxInternalPort = 14412
    /// 默认沙箱工作区 id（稳定；旧 `science-sandbox/home` 迁移到此）。
    static let defaultScienceWorkspaceId = "default"
    /// 默认工作区显示名（英文存盘；UI 可本地化展示）。
    static let defaultScienceWorkspaceName = "Default"
    // 假账号邮箱缺省值（兼容旧配置；运行时由工作区 id 派生覆盖）。
    static let defaultSandboxEmail = "default@cslocal.invalid"

    /// 由工作区 id 派生不可路由假邮箱（RFC 2606 `.invalid`）。
    static func sandboxEmail(forWorkspaceId id: String) -> String {
        let raw = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = raw.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        let local = safe.isEmpty ? "workspace" : safe
        return "\(local)@cslocal.invalid"
    }

    static var defaultScienceWorkspace: ScienceWorkspace {
        ScienceWorkspace(id: defaultScienceWorkspaceId, name: defaultScienceWorkspaceName)
    }
    // 接管真实实例模式下 Science 对外固定端口（= 桌面 app 默认端口）：由本地反向代理（ScienceAuthProxy）占用，
    // 负责给每个请求注入 operon 会话 cookie，使双击桌面 app / 浏览器打开 8765 都免登录。
    static let realInstancePort = 8765
    // 接管模式下内部 Claude Science daemon 的监听端口（反代把 8765 的流量转发到这里）。
    static let realInstanceInternalPort = 14411
    // 虚拟模型名仅作 CLI 固定入口名，可任意取——会被代理改写为激活节点真实上游模型，故取通用短名。
    static let defaultVirtualModel = "gpt"
    // Claude 三层名需含 opus/sonnet/haiku 关键字（后端据此映射到节点 big/middle/small），裸关键字即可。
    static let defaultClaudeOpus = "opus"
    static let defaultClaudeSonnet = "sonnet"
    static let defaultClaudeHaiku = "haiku"
    static let defaultOpenCodeModel = "LLM"

    private static func freshClientKey() -> String {
        "aiusage-global-\(UUID().uuidString.prefix(8))"
    }

    static func freshDesktopClientKey() -> String {
        "aiusage-desktop-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    static func makeDefault(track: GlobalProxyTrack) -> GlobalProxyConfig {
        switch track {
        case .codex:
            return GlobalProxyConfig(
                isEnabled: false, port: defaultCodexPort, clientKey: freshClientKey(),
                virtualModel: defaultVirtualModel, sonnetModel: nil, haikuModel: nil,
                openCodeInterface: nil, activeNodeId: nil
            )
        case .claude:
            var config = GlobalProxyConfig(
                isEnabled: false, port: defaultClaudePort, clientKey: freshClientKey(),
                virtualModel: defaultClaudeOpus, sonnetModel: defaultClaudeSonnet,
                haikuModel: defaultClaudeHaiku, openCodeInterface: nil, activeNodeId: nil
            )
            config.claudeCodeEnabled = false
            config.claudeDesktopEnabled = false
            config.claudeDesktopHTTPSPort = defaultClaudeDesktopHTTPSPort
            config.claudeDesktopClientKey = freshDesktopClientKey()
            return config
        case .desktop:
            var config = GlobalProxyConfig(
                isEnabled: false, port: defaultClaudeDesktopGatewayPort,
                clientKey: freshClientKey(), virtualModel: defaultClaudeOpus,
                sonnetModel: defaultClaudeSonnet, haikuModel: defaultClaudeHaiku,
                openCodeInterface: nil, activeNodeId: nil
            )
            config.claudeDesktopCatalogMode = .fullNodeCatalog
            config.claudeDesktopHTTPSPort = defaultClaudeDesktopHTTPSPort
            config.claudeDesktopClientKey = freshDesktopClientKey()
            return config
        case .opencode:
            return GlobalProxyConfig(
                isEnabled: false, port: defaultOpenCodePort, clientKey: freshClientKey(),
                virtualModel: defaultOpenCodeModel, sonnetModel: nil, haikuModel: nil,
                openCodeInterface: .openAICompatible, activeNodeId: nil
            )
        case .science:
            var config = GlobalProxyConfig(
                isEnabled: false, port: defaultSciencePort, clientKey: freshClientKey(),
                virtualModel: defaultClaudeOpus, sonnetModel: defaultClaudeSonnet,
                haikuModel: defaultClaudeHaiku, openCodeInterface: nil, activeNodeId: nil,
                sciencePort: defaultScienceListenPort,
                sandboxEmail: sandboxEmail(forWorkspaceId: defaultScienceWorkspaceId),
                scienceWorkspaces: [defaultScienceWorkspace],
                activeScienceWorkspaceId: defaultScienceWorkspaceId
            )
            config.ensureScienceWorkspaceDefaults()
            return config
        }
    }

    /// 保证至少有一个工作区，并同步派生 `sandboxEmail`。读档后应调用。
    mutating func ensureScienceWorkspaceDefaults() {
        var list = scienceWorkspaces ?? []
        if list.isEmpty {
            list = [Self.defaultScienceWorkspace]
        }
        // 去重保序
        var seen = Set<String>()
        list = list.filter { seen.insert($0.id).inserted }
        scienceWorkspaces = list
        if activeScienceWorkspaceId == nil || !list.contains(where: { $0.id == activeScienceWorkspaceId }) {
            activeScienceWorkspaceId = list[0].id
        }
        sandboxEmail = Self.sandboxEmail(forWorkspaceId: activeScienceWorkspaceId ?? Self.defaultScienceWorkspaceId)
    }

    /// Normalize every persisted Claude Desktop invariant in one place.  This
    /// keeps the profile key stable across reads and prevents a damaged config
    /// from trying to bind a privileged port or reuse the Code listener.
    mutating func ensureClaudeDesktopDefaults() {
        if claudeCodeEnabled == nil {
            claudeCodeEnabled = isEnabled
        }
        claudeDesktopEnabled = claudeDesktopEnabled ?? false
        claudeDesktopCatalogMode = claudeDesktopCatalogMode ?? .fullNodeCatalog

        let requestedPort = claudeDesktopHTTPSPort ?? Self.defaultClaudeDesktopHTTPSPort
        let validPort = (1_024...65_535).contains(requestedPort)
            ? requestedPort
            : Self.defaultClaudeDesktopHTTPSPort
        if validPort == port {
            claudeDesktopHTTPSPort = port == 65_535 ? 65_534 : max(1_024, port + 1)
        } else {
            claudeDesktopHTTPSPort = validPort
        }

        if claudeDesktopClientKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            claudeDesktopClientKey = Self.freshDesktopClientKey()
        }
        isEnabled = hasClaudeConsumers
    }

    /// Normalize the independent Desktop product gateway. Unlike the legacy
    /// shared Claude config, `isEnabled` is the Desktop connection state and
    /// must not be derived from Code/Desktop consumer flags.
    mutating func ensureDesktopDefaults() {
        claudeDesktopCatalogMode = claudeDesktopCatalogMode ?? .fullNodeCatalog
        let requestedHTTPSPort = claudeDesktopHTTPSPort ?? Self.defaultClaudeDesktopHTTPSPort
        let validPort = (1_024...65_535).contains(requestedHTTPSPort)
            ? requestedHTTPSPort : Self.defaultClaudeDesktopHTTPSPort
        claudeDesktopHTTPSPort = validPort == port
            ? (port == 65_535 ? 65_534 : max(1_024, port + 1))
            : validPort
        if claudeDesktopClientKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            claudeDesktopClientKey = Self.freshDesktopClientKey()
        }
    }

    // MARK: Derived

    /// client key 兜底：空则用稳定占位，避免 admin/CLI 鉴权两端空值不一致。
    var effectiveClientKey: String {
        let trimmed = clientKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "aiusage-global-key" : trimmed
    }

    var effectiveClaudeCodeEnabled: Bool { claudeCodeEnabled ?? (isEnabled && claudeDesktopEnabled != true) }
    var effectiveClaudeDesktopEnabled: Bool { claudeDesktopEnabled ?? false }
    var effectiveClaudeDesktopCatalogMode: ClaudeDesktopCatalogMode {
        claudeDesktopCatalogMode ?? .fullNodeCatalog
    }
    var effectiveClaudeCodeCatalogMode: ClaudeDesktopCatalogMode {
        claudeCodeCatalogMode ?? .smartRoutes
    }
    func claudeCodeModelOverride(for nodeID: String) -> ClaudeAppNodeModelOverride? {
        guard let value = claudeCodeModelOverridesByNode?[nodeID], !value.isEmpty else { return nil }
        return value
    }
    func effectiveClaudeCodeModels(for node: ProxyConfiguration) -> ClaudeAppResolvedModels {
        let override = claudeCodeModelOverride(for: node.id)
        return ClaudeAppResolvedModels(
            defaultModel: override?.defaultModel?.nilIfBlank ?? node.defaultModel,
            opus: override?.opus?.nilIfBlank ?? node.modelMapping.bigModel.name,
            sonnet: override?.sonnet?.nilIfBlank ?? node.modelMapping.middleModel.name,
            haiku: override?.haiku?.nilIfBlank ?? node.modelMapping.smallModel.name
        )
    }
    func claudeDesktopModelOverride(for nodeID: String) -> ClaudeAppNodeModelOverride? {
        guard let value = claudeDesktopModelOverridesByNode?[nodeID], !value.isEmpty else { return nil }
        return value
    }
    func effectiveClaudeDesktopModels(for node: ProxyConfiguration) -> ClaudeAppResolvedModels {
        let override = claudeDesktopModelOverride(for: node.id)
        return ClaudeAppResolvedModels(
            defaultModel: override?.defaultModel?.nilIfBlank ?? node.defaultModel,
            opus: override?.opus?.nilIfBlank ?? node.modelMapping.bigModel.name,
            sonnet: override?.sonnet?.nilIfBlank ?? node.modelMapping.middleModel.name,
            haiku: override?.haiku?.nilIfBlank ?? node.modelMapping.smallModel.name
        )
    }
    var hasClaudeConsumers: Bool { effectiveClaudeCodeEnabled || effectiveClaudeDesktopEnabled }
    var claudeConsumers: Set<ClaudeGatewayConsumer> {
        var result = Set<ClaudeGatewayConsumer>()
        if effectiveClaudeCodeEnabled { result.insert(.code) }
        if effectiveClaudeDesktopEnabled { result.insert(.desktop) }
        return result
    }
    var effectiveClaudeDesktopHTTPSPort: Int {
        let requested = claudeDesktopHTTPSPort ?? Self.defaultClaudeDesktopHTTPSPort
        guard (1_024...65_535).contains(requested), requested != port else {
            return port == 65_535 ? 65_534 : max(1_024, port + 1)
        }
        return requested
    }
    var effectiveClaudeDesktopClientKey: String {
        let value = claudeDesktopClientKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Loaded/default Claude configs are normalized before use. Returning
        // an empty value here fails closed if an unnormalized in-memory config
        // is ever constructed; generating in a getter would create a new key
        // on every read and desynchronize the runtime from the profile.
        return value
    }
    var claudeDesktopBaseURL: String {
        "https://localhost:\(effectiveClaudeDesktopHTTPSPort)/claude-desktop"
    }
    /// 遗留读取口：1M 能力已迁到节点（`ProxyConfiguration.modelCatalog.supports1MModels`），
    /// 这里只服务于把旧 Desktop 配置里的声明搬到节点上（见 `migrateLegacySupports1MToNodes`）。
    func legacyClaudeDesktopSupports1MModels(for nodeID: String) -> Set<String> {
        Set((claudeDesktopSupports1MByNode?[nodeID] ?? [:]).compactMap { model, enabled in
            enabled ? model : nil
        })
    }

    /// 含 /v1 的本地地址（Codex 在其后拼 /responses）。
    var codexBaseURL: String { "http://127.0.0.1:\(port)/v1" }
    /// 不含 /v1 的本地地址（Claude Code 自行拼 /v1/messages）。
    var localBaseURL: String { "http://127.0.0.1:\(port)" }

    /// Claude 三层虚拟模型（缺省回退到默认值）。
    var claudeOpus: String { virtualModel.nilIfBlank ?? Self.defaultClaudeOpus }
    var claudeSonnet: String { (sonnetModel?.nilIfBlank) ?? Self.defaultClaudeSonnet }
    var claudeHaiku: String { (haikuModel?.nilIfBlank) ?? Self.defaultClaudeHaiku }

    /// OpenCode 选定接口（缺省回退到 OpenAI 兼容）。
    var effectiveOpenCodeInterface: OpenCodeProtocol { openCodeInterface ?? .openAICompatible }

    /// 不含 /v1 的本地地址（Anthropic 接口的 OpenCode 上游需要根地址 + /v1/messages）。
    var rootBaseURL: String { "http://127.0.0.1:\(port)" }

    /// Science 沙箱监听端口（缺省 14410；绝不占用真实实例保留端口 8765）。
    var effectiveSciencePort: Int {
        let p = sciencePort ?? Self.defaultScienceListenPort
        return p == 8765 ? Self.defaultScienceListenPort : p
    }
    /// 当前沙箱工作区列表（至少含默认项）。
    var effectiveScienceWorkspaces: [ScienceWorkspace] {
        let list = scienceWorkspaces ?? []
        return list.isEmpty ? [Self.defaultScienceWorkspace] : list
    }

    /// 当前激活沙箱工作区 id。
    var effectiveActiveScienceWorkspaceId: String {
        let id = activeScienceWorkspaceId ?? Self.defaultScienceWorkspaceId
        if effectiveScienceWorkspaces.contains(where: { $0.id == id }) { return id }
        return effectiveScienceWorkspaces[0].id
    }

    /// 当前激活沙箱工作区。
    var effectiveActiveScienceWorkspace: ScienceWorkspace {
        effectiveScienceWorkspaces.first(where: { $0.id == effectiveActiveScienceWorkspaceId })
            ?? Self.defaultScienceWorkspace
    }

    /// Science 沙箱假账号邮箱（由工作区 id 派生；`.invalid` 不可路由）。
    var effectiveSandboxEmail: String {
        Self.sandboxEmail(forWorkspaceId: effectiveActiveScienceWorkspaceId)
    }

    /// 是否接管真实实例（缺省 false）。
    var effectiveAdoptReal: Bool { adoptRealInstance ?? false }

    /// 是否允许局域网访问（缺省 false）。
    var effectiveAllowLAN: Bool { allowLAN ?? false }

    /// QuotaServer 绑定地址：开启局域网时监听 0.0.0.0，否则仅本机 127.0.0.1。
    var bindAddress: String { effectiveAllowLAN ? "0.0.0.0" : "127.0.0.1" }

    /// UI 展示用绑定主机名（与 bindAddress 一致）。
    var displayBindHost: String { bindAddress }

    /// 当前 Science 实际监听端口：接管真实实例走 8765，否则走沙箱端口。
    var effectiveScienceListenPort: Int {
        effectiveAdoptReal ? Self.realInstancePort : effectiveSciencePort
    }
}

// MARK: - Persistence

/// GlobalProxyConfig 的按轨文件持久化（与 OpenCodeNodeStore 等一致：~/.config/aiusage 下 0600 JSON）。
enum GlobalProxyStore {
    private static func configPath(track: GlobalProxyTrack) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/\(track.configFileName)")
    }

    static func load(track: GlobalProxyTrack) -> GlobalProxyConfig {
        let path = configPath(track: track)
        guard let data = FileManager.default.contents(atPath: path) else {
            if track == .desktop, let migrated = migrateLegacyDesktopIfNeeded() {
                return migrated
            }
            return .makeDefault(track: track)
        }
        do {
            var config = try JSONDecoder().decode(GlobalProxyConfig.self, from: data)
            if track == .science {
                config.ensureScienceWorkspaceDefaults()
            } else if track == .claude {
                let decoded = config
                config.ensureClaudeDesktopDefaults()
                if config.effectiveClaudeDesktopEnabled {
                    _ = persistDesktopMigration(from: config)
                    config.claudeDesktopEnabled = false
                    config.isEnabled = config.effectiveClaudeCodeEnabled
                }
                if config != decoded { _ = save(config, track: track) }
            } else if track == .desktop {
                let decoded = config
                config.ensureDesktopDefaults()
                if config != decoded { _ = save(config, track: track) }
            }
            return config
        } catch {
            globalProxyLog.error("Failed to decode global proxy config (\(track.rawValue, privacy: .public)), using default: \(String(describing: error), privacy: .public)")
            return .makeDefault(track: track)
        }
    }

    @discardableResult
    static func save(_ config: GlobalProxyConfig, track: GlobalProxyTrack) -> Bool {
        var toSave = config
        if track == .science {
            toSave.ensureScienceWorkspaceDefaults()
        } else if track == .claude {
            toSave.ensureClaudeDesktopDefaults()
        } else if track == .desktop {
            toSave.ensureDesktopDefaults()
        }
        let path = configPath(track: track)
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(toSave)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch {
            globalProxyLog.error("Failed to persist global proxy config (\(track.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// One-time 0.15 shared-Gateway migration. Desktop keeps the same public
    /// HTTPS port, key, model mode and selected node, but receives a new
    /// independent internal product port.
    private static func migrateLegacyDesktopIfNeeded() -> GlobalProxyConfig? {
        let legacyPath = configPath(track: .claude)
        guard let data = FileManager.default.contents(atPath: legacyPath),
              var legacy = try? JSONDecoder().decode(GlobalProxyConfig.self, from: data) else { return nil }
        legacy.ensureClaudeDesktopDefaults()
        guard legacy.effectiveClaudeDesktopEnabled else { return nil }
        let desktop = desktopConfig(from: legacy)
        guard save(desktop, track: .desktop) else { return nil }
        legacy.claudeDesktopEnabled = false
        legacy.isEnabled = legacy.effectiveClaudeCodeEnabled
        _ = save(legacy, track: .claude)
        return desktop
    }

    @discardableResult
    private static func persistDesktopMigration(from legacy: GlobalProxyConfig) -> Bool {
        let desktopPath = configPath(track: .desktop)
        if FileManager.default.fileExists(atPath: desktopPath) { return true }
        return save(desktopConfig(from: legacy), track: .desktop)
    }

    private static func desktopConfig(from legacy: GlobalProxyConfig) -> GlobalProxyConfig {
        var desktop = GlobalProxyConfig.makeDefault(track: .desktop)
        desktop.isEnabled = legacy.effectiveClaudeDesktopEnabled
        desktop.activeNodeId = legacy.activeNodeId
        desktop.clientKey = legacy.effectiveClaudeDesktopClientKey
        desktop.claudeDesktopClientKey = legacy.effectiveClaudeDesktopClientKey
        desktop.claudeDesktopHTTPSPort = legacy.effectiveClaudeDesktopHTTPSPort
        desktop.claudeDesktopCatalogMode = legacy.effectiveClaudeDesktopCatalogMode
        desktop.claudeDesktopSupports1MByNode = legacy.claudeDesktopSupports1MByNode
        desktop.ensureDesktopDefaults()
        return desktop
    }
}
