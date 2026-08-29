# OpenCode 集成技术设计

> 对应 issue [#17](https://github.com/sylearn/AIUsage/issues/17)。
> 分支：`feature/opencode-provider`。
> 本文是实现的唯一事实源：数据口径、文件级改动清单、分阶段范围都以此为准。

## 1. 背景与结论

OpenCode 是终端 AI 编程工具（类似 Claude Code / Codex CLI）。issue #17 请求四项能力：代理、用量统计、菜单栏集成、多账户。

调研结论（实测 OpenCode 1.2.26 + 官方文档）：

- **用量统计无需代理**。OpenCode 自 v1.2.0 起把全部会话写入本地 SQLite（`~/.local/share/opencode/opencode.db`，WAL 模式，Drizzle 管理），每条 assistant 消息自带 token 明细与按 [models.dev](https://models.dev) 定价预计算的 `cost`。这比 Claude（必须走代理才有归档）和 Codex（非代理轨无成本）的数据条件更好。
- **翻译代理无存在必要**。OpenCode 原生支持任意 OpenAI 兼容上游（`opencode.json` 的 `provider` 块 + `baseURL`）。真正缺的是「节点管理 + 一键切换」，应做成配置切换器而非代理进程。
- **OpenCode Zen 无公开余额 API**（上游 issue #10448 开放中），配额型监控暂不可行。

因此分三阶段：

| 阶段 | 范围 | 状态 |
|------|------|------|
| Phase 1 | 用量统计 Provider + 仪表盘 / 菜单栏 / 统计页 / 设置集成 | 本文档主体 |
| Phase 2 | 多账户（auth.json 快照切换）+ 配置节点切换器（opencode.json 受管块） | 设计见 §7 |
| Phase 3（可选） | OpenAI 透传代理轨（请求级日志、与 Claude/Codex 同一节点池） | 设计要点见 §8 |

## 2. OpenCode 数据源事实

### 2.1 存储位置

| 路径 | 内容 |
|------|------|
| `~/.local/share/opencode/opencode.db`（+ `-wal` / `-shm`） | v1.2.0+ 唯一事实源。表：`project` / `session` / `message` / `part` / `account` 等 |
| `~/.local/share/opencode/storage/` | v1.2 之前的旧 JSON 存储；v1.2 启动时自动迁移进 db |
| `~/.local/share/opencode/auth.json` | 各 provider 凭据（Phase 2 用） |
| `~/.config/opencode/opencode.json`（或 `.jsonc`） | 全局配置（Phase 2 用） |

数据目录解析顺序（与 OpenCode 的 `Global.Path.data` 对齐）：

1. `$XDG_DATA_HOME/opencode`（若设置）
2. `~/.local/share/opencode`（CLI 默认，含 macOS）
3. `~/Library/Application Support/opencode`（桌面版 fallback）

**最低支持版本定为 v1.2.0**（SQLite 起点）。旧版 JSON 存储不做兼容——OpenCode 升级时自动迁移，无必要背包袱。找不到 `opencode.db` 即抛 `ProviderError("no_usage_data", …)`。

### 2.2 message 表 schema（实测 1.2.26）

```sql
CREATE TABLE `message` (
  `id` text PRIMARY KEY,            -- msg_xxx
  `session_id` text NOT NULL,
  `time_created` integer NOT NULL,  -- epoch 毫秒
  `time_updated` integer NOT NULL,
  `data` text NOT NULL              -- JSON
);
```

assistant 消息的 `data` JSON（仅列用到的字段）：

```json
{
  "role": "assistant",
  "providerID": "deepseek",
  "modelID": "deepseek-v4-pro",
  "cost": 0.0377087,
  "tokens": {
    "input": 15637, "output": 725, "reasoning": 479,
    "cache": { "read": 43520, "write": 0 }
  },
  "time": { "created": 1778062335799, "completed": 1778062360154 }
}
```

### 2.3 token / 成本口径

实测验证：`tokens.total = input + output + cache.read + cache.write`；`reasoning` 是 `output` 的子集，**不参与求和**。即 `input` 已是 non-cached input，与本项目「`input` 必须是非缓存输入」的计费口径天然一致（见 USAGE_AND_BILLING.md 总原则）。

映射：

| OpenCode 字段 | AIUsage 字段 |
|---|---|
| `tokens.input` | `inputTokens` |
| `tokens.output` | `outputTokens` |
| `tokens.cache.read` | `cacheReadTokens` |
| `tokens.cache.write` | `cacheCreateTokens` |
| `cost` | `estimatedCostUsd`（直接采用，发生时已按 models.dev 定价冻结） |

**未定价语义**：OAuth 订阅渠道（如 `github-copilot`、OAuth 登录的 `anthropic`）OpenCode 记 `cost: 0`，这是「订阅不计费」而非「未定价」。Phase 1 **不产生** unpriced 告警（`overall.unpricedModels` 恒空），避免订阅用户每天被误报。

**模型名口径**：使用 `providerID/modelID`（如 `deepseek/deepseek-v4-pro`、`anthropic/claude-opus-4-6`）。这保留了 OpenCode 特有的「内部供应商」维度，统计页模型分布天然可看出成本流向哪家。无轨道后缀（单轨，见 §4.4）。

**日界**：以 `time.created`（毫秒）按本地时区取 `yyyy-MM-dd`，与 Claude/Codex 口径一致。

## 3. Phase 1 总体数据流

```
opencode.db ──复制 db/-wal/-shm 到临时目录──► SQLite 只读查询（system libsqlite3）
  ──► OpenCodeRow（逐条 assistant 消息）──► 按日聚合 [String: CodexAggregateBucket]
  ──► OpenCodeUsageArchiveStore.freeze()（昨日前冻结、今天重算）
  ──► ProviderUsage.extra（today/week/month/overall + timeline + models）
  ──► UsageNormalizer.normalizeOpenCode() ──► ProviderSummary(costSummary, category: localCost)
  ──► Dashboard / MenuBar / ProxyStatsView / 设置费用来源（全部走既有 localCost 管线）
```

设计取舍：

- **SQLite 访问**：`import SQLite3`（系统库，无新依赖），不走 `Process + /usr/bin/sqlite3`（CursorProvider 旧路径），因为本 provider 每个刷新周期都要跑。先把 `opencode.db` / `-wal` / `-shm` 复制到 `NSTemporaryDirectory()` 再以 `SQLITE_OPEN_READONLY` 打开，规避 WAL 并发与锁问题（OpenCode 进程可能正在写）。查询后删除临时文件。
- **冻结归档**：镜像 `CodexNonProxyUsageArchiveStore` 语义——今天之前的日期首写即冻结、今天每次覆盖重算；`fullHistoryImportedAt == nil` 时首次 fetch 自动全量（`consumeFullHistoryImportRequest` 模式），之后只查 `time_created >= (今天 - 30 天)` 的窗口。用户清空 OpenCode 历史后统计不丢。
  - 归档路径：`~/.config/aiusage/usage-archive/opencode-usage-v1.json`
- **聚合结构复用**：`CodexAggregateBucket` / `CodexModelAggregate` / `CodexRow` / `CodexUsageArchive` 是通用聚合结构（QuotaBackend 模块内部类型），直接复用，不复制一套改名。已知技术债：命名带 Codex 前缀，待后续统一改名为 `Usage*`（不在本期做，避免无关 diff）。
- **timeline**：`hourly` 留空、按日呈现，与 Codex 一致（冻结归档无小时粒度；虽然 db 有毫秒戳，但跨「归档冻结 + 实时重算」两源的小时口径不一致，留作未来增强）。
- **会话数**：扫描窗口内 distinct `session_id` 计数，进 `overall.sessionCount`。
- **schema 漂移防御**：所有 JSON 字段缺失按 0 / nil 处理；`message` 表不存在或查询失败 → 抛 `ProviderError`，UI 呈现为「采集失败」卡片，不崩溃。

## 4. Phase 1 文件级改动清单

### 4.1 QuotaBackend 新增（6 个文件）

| 文件 | 职责 |
|------|------|
| `Providers/OpenCodeCostProvider.swift` | `id = "opencode"`，`displayName = "OpenCode"`；`fetchUsage()` 主流程（镜像 `CodexCostProvider.fetchUsage` 的聚合→extra 编码段，单轨无合并步骤）。顶部注释说明数据来源（规则 15） |
| `Providers/OpenCodeCostProvider+Discovery.swift` | 数据目录解析（§2.1 顺序，`environment` 注入便于测试）；db 临时快照复制/清理 |
| `Providers/OpenCodeCostProvider+Database.swift` | SQLite3 C API 只读封装：open/prepare/step/finalize；查询 `SELECT session_id, data FROM message WHERE time_created >= ?`；错误包装为 `ProviderError` |
| `Providers/OpenCodeCostProvider+Parsing.swift` | `data` JSON → `OpenCodeRow`（Codable 防御解析，过滤 `role != "assistant"`、`tokens` 全零行） |
| `Providers/OpenCodeCostProvider+Aggregation.swift` | dayKey / weekRange / scanWindow / aggregateDays / trailingDailyTimeline / encodeTimeline（镜像 `CodexCostProvider+Aggregation` + `+DateUtils`，遵循仓库既有 per-provider 扩展模式） |
| `Providers/OpenCodeUsageArchiveStore.swift` | actor，冻结归档（§3），无 legacy 迁移分支 |

每个文件控制在 400 行内（规则 3）。

### 4.2 QuotaBackend 修改（4 处）

| 文件 | 改动 |
|------|------|
| `Engine/ProviderRegistry.swift` | `all` 数组按字母序插入 `OpenCodeCostProvider()`（`minimax` 与 `warp` 之间） |
| `Normalizer/UsageNormalizer.swift` | ① `providerThemes` 加 `"opencode": ThemeInfo(accent: "teal", glow: "#2dd4bf")`；② `normalize` switch 加 `case "opencode"`；③ `channel(for:)` 加入 `local` 分支；④ `compactProviderLabel` 加 `"OpenCode"`；⑤ `formatSourceLabel` 加 `"opencode-session-db": "Local OpenCode sessions"` |
| `Normalizer/UsageNormalizer+OpenCode.swift`（新增） | `normalizeOpenCode(base:usage:)`：镜像 `normalizeCodexCost`，`category = ProviderCategory.localCost`，headline/metrics 文案改为 OpenCode 口径（「Local session ledger」），`unpricedModels` 恒 nil |
| `Tests/QuotaBackendTests/ProviderRegistryTests.swift` | 既有契约测试的 id 列表插入 `"opencode"`（不更新会编译失败级红测；仅改既有断言，不新增测试文件） |

### 4.3 App 层修改（10 处）

| 文件 | 改动 |
|------|------|
| `Models/AppState.swift` | ① `providerCatalogItems` 追加 `ProviderCatalogItem(id: "opencode", titleEn: "OpenCode", titleZh: "OpenCode", summaryEn: "Local token and cost ledger from OpenCode sessions", summaryZh: "基于 OpenCode 本地会话的 Token 与费用账本", channel: "local", kind: .costTracking)`；② `costTrackingSelectionMigrationKey` bump 到 `v3`（让存量用户自动启用 OpenCode，逻辑只增不减，与 v2 注释语义一致） |
| `ViewModels/ProviderRefreshCoordinator.swift` | `refreshLocalTokenStatsOnly()` 的 `active` 列表 `["claude", "codex-cost"]` → `["claude", "codex-cost", "opencode"]`（fan-out 隔离慢源） |
| `ViewModels/StatsDataAdapter.swift` | `SourceFamily` 加 `case opencode`，`matches` 按 `baseProviderId == "opencode"` |
| `Views/ProxyStatsView.swift` | ① 视图层 `SourceFamily` 加 `case opencode` + `adapterFamily` 映射（exhaustive switch）；② `opencodeLocalProviders` 计算属性；③ 家族切换器自动出现新段（CaseIterable 驱动，需确认分段标签文案处）；④ 轨道切换器保持仅 Codex（OpenCode 单轨）；⑤ 空态文案补「OpenCode」 |
| `Views/DashboardView.swift` | ① `isAwaitingLocalStats` 的硬编码 id 集合加 `"opencode"`；② 热力图从「claude/codex 两列特判」重构为数据驱动：`[HeatmapSpec]`（providers/label/asset/accent）过滤有数据项后按每行 2 列 chunk 布局；③ `opencodeLocalProviders` 计算属性 |
| `Views/MenuBarView+CostTracking.swift` | `FamilyCost`（基于 `ProxyNodeFamily` 二元）重构为 `CostSourceRow { providerId, label, iconAsset, tint, summary }`，`costFamilyProviders` 改为遍历 `["claude", "codex-cost", "opencode"]` 描述表生成；`familyCostRow` 改为吃 `CostSourceRow`——菜单栏每行的图标/名称/配色与各自工具一一对应 |
| `Views/CostTrackingCard.swift` | accent switch 加 `case "opencode": return .teal` |
| `Views/ProviderIconView.swift` | ① SF Symbol fallback 加 `case "opencode": return "terminal.fill"`；② accent 色 加 `case "opencode": return .teal`（无品牌 imageset 时走 fallback，asset 后续可补 `ProviderIcons/opencode.imageset`） |
| `Resources/Assets.xcassets/ProviderIcons/opencode.imageset` | 新增品牌图标（若无合适 SVG，先不加，靠 SF Symbol fallback；Contents.json + svg 各一文件） |
| 设置页 | **无需改动**：「费用来源」选择器与状态栏 pin 项由 `category == localCost` 通用驱动（`SettingsView+MenuBarPins.swift` / `StatusBarItemView.swift`），OpenCode 自动出现 |

### 4.4 明确不做（Phase 1）

- `UsageTrack` 不动：OpenCode 单轨（全部本地会话），无 ` (Proxy)`/` (Non-Proxy)` 后缀，无轨道切换器（同 Claude）。
- `ProxyUsageFamily` / `ProxyConfiguration` / `ProxyViewModel` 不动：无代理轨。
- `ProviderAuthManager` / `ProviderActivationManager` / `AccountStore` 不动：无多账户。
- 不新增测试文件；仅维护既有 `ProviderRegistryTests` 契约断言。

### 4.5 验收口径

1. 本机有 OpenCode 1.2+ 数据时：仪表盘出现 OpenCode 热力图与概览计入、统计页家族切换出现 OpenCode、菜单栏「费用 · 用量」出现 OpenCode 行（独立图标与青色调）、设置「费用来源」可 pin OpenCode。
2. 无 OpenCode 安装：provider 报 `no_usage_data`，卡片呈现采集失败态，其余功能不受影响。
3. OpenCode 正在运行时刷新：临时快照只读查询不报锁错误。
4. 删除 `~/.local/share/opencode` 后：历史统计仍可从冻结归档读出。

## 5. 关键实现细节备忘

- **SQLite 封装**（`+Database.swift`）：`sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)`；text 列用 `sqlite3_column_text` + `String(cString:)`；prepare 失败/step 错误统一 `ProviderError("db_error", …)`，路径经 `SensitiveDataRedactor.redactPaths(in:)` 脱敏后再进日志（规则 5）。
- **扫描窗口**：默认 30 天（`defaultScanDays` 同 Codex）；首次全量时不带 `WHERE time_created >=` 条件。窗口起点 = 本地时区今天零点 − 29 天，转 epoch 毫秒下推到 SQL，减少 JSON 解码量。
- **临时快照**：`opencode-snapshot-<uuid>.db`；复制顺序 db → wal → shm（wal/shm 容忍缺失）；`defer` 清理。
- **性能**：70 条消息 ≈ 毫秒级；十万行级别靠 30 天窗口 + 冻结归档兜底，不引入逐文件缓存（SQLite 自带索引优势，无需 `CodexCostFileScanCache` 类机制）。
- **os.Logger**：subsystem `com.aiusage.quotabackend`，category `OpenCodeCost`；禁止 print（规则 5）。

## 6. Phase 1 实施顺序

1. QuotaBackend：models 复用确认 → `+Database` → `+Parsing` → `+Discovery` → `+Aggregation` → `OpenCodeUsageArchiveStore` → 主文件 `fetchUsage`
2. Normalizer + Registry + 契约测试断言
3. App 层：catalog → 刷新 fan-out → StatsDataAdapter / ProxyStatsView → DashboardView 热力图重构 → MenuBar 重构 → 图标/配色
4. 人工验证（用户自行编译；本机有真实 OpenCode 数据可直接验收 §4.5）

## 7. Phase 2 设计（节点切换器，已实现）

> 已过寸止确认：做成**独立轻量模块**，不挂入 `NodeProfile` / `ProxyViewModel` 体系
> （该体系 Claude/Codex 二元假设深植，`isCodex` 全应用约 85 处，硬塞第三家族风险过高；
> 且 OpenCode 无代理进程，复用激活管线没有收益）。多账户（auth.json 快照）暂缓，见 §7.3。

### 7.1 模块构成（5 个新文件 + 2 处修改）

| 文件 | 职责 |
|------|------|
| `Models/OpenCodeNode.swift` | 节点模型：name / baseURL / apiKey / models / defaultModel / 可选 limit |
| `ViewModels/OpenCodeConfigManager.swift` | opencode.json 受管注入与还原（见 §7.2） |
| `ViewModels/OpenCodeNodeStore.swift` | 节点持久化（`~/.config/aiusage/opencode-nodes.json`，0600）+ 激活状态对账 |
| `Views/OpenCodeManagementView.swift` | 「OpenCode 代理」主视图：状态横幅 / 节点卡片 / 激活停用 |
| `Views/OpenCodeNodeEditorView.swift` | 节点编辑 sheet |
| `Models/AppSettings.swift` | `AppSection` 加 `opencodeManagement` |
| `Views/ContentView.swift` | 侧边栏「OpenCode 代理」入口（teal 品牌图标，与 Claude/Codex 代理并列） |

### 7.2 配置切换器：opencode.json 受管块

- `OpenCodeConfigManager`（镜像 `CodexConfigManager` 的 backup-as-source-of-truth）：
  - 注入受管键 `provider["aiusage-<节点 slug>"]`（`npm: "@ai-sdk/openai-compatible"` + baseURL/apiKey/models）+ 顶层 `model: "aiusage-<slug>/<模型>"`；备份 `opencode.json.aiusage.bak`；还原即整文件回滚，重复激活/切换节点幂等（剥离所有 `aiusage*` 前缀键）。
  - **路线 A（消息级节点归因，已实现）**：provider 键按节点区分（`OpenCodeNode.providerSlug`，首次保存生成且改名不变），opencode.db 的消息携带它作为 `providerID`，Phase 1 统计据此把用量/费用归因到具体节点，无需代理。
  - JSON 结构化读写（`JSONSerialization`，pretty + sortedKeys）；检测到 `opencode.jsonc`（无法保真注释）或解析失败时拒绝接管并在 UI 横幅提示。
  - 写入后恢复 0600 权限。
  - **密钥与配置分离（issue #65）**：直连模式的上游 API Key 不再内联进受管块，而是走 OpenCode 官方位置 `~/.local/share/opencode/auth.json`（`OpenCodeAuthStore`，0600），格式 `{"aiusage-<slug>": {"type": "api", "key": "…"}}`——键名必须与 `opencode.json` 里的 provider 键一致，OpenCode 启动时按 provider id 取凭据注入 SDK。`opencode.json` 只留 `baseURL`/`models`，因此该文件被同步/备份/分享时不含密钥。
    - 代理模式受管块仍内联 client key（代理鉴权用，非上游密钥）；激活代理模式时会清掉本节点残留的直连凭据，否则 auth.json 里的 key 会覆盖它。
    - 停用（`restore()`）连带清掉全部 `aiusage*` 凭据，密钥不在停用后留在盘上；用户自己 `opencode auth login` 存的其他 provider 项原样保留。
    - auth.json 写不动时回退为内联 `apiKey`——否则 OpenCode 拿不到凭据，激活即失效。
    - 「复制启动命令」导出的是自带凭据的独立配置（0600，`OPENCODE_CONFIG=`），固定内联 key，不依赖 auth.json 里有没有本节点的项。
  - 启动对账：用户手动改回 opencode.json 后自动清除激活标记（`OpenCodeNodeStore.reconcileWithConfigFile`）。

### 7.3 暂缓项

- **auth.json 多账户快照切换**（issue 第 4 点）：模式可镜像 Codex 订阅账号切换（快照存 Keychain、备份-写入-标记激活）；auth.json 是「每 provider 单凭据」字典，一份快照 = 一个账户组合，UI 应按「配置快照」表达。待后续单独立项。
- **菜单栏节点快切**：`MenuBarView+TrackSwitcher` 同为二元家族结构，待重构后再接入。

## 8. 路线 B：透传代理轨（请求级日志，已实现）

> 已过寸止确认。与 §7 同思路：**独立轻量轨道**，不扩 `ProxyUsageFamily` / `ProxyNodeFamily`
> 三元枚举，不接 `ProxyViewModel` / TrackSwitcher。核心约束：**请求日志仅观测，不参与计费**
> ——用量成本仍以 opencode.db（Phase 1 Provider）为准，避免代理旁路统计与 db 账本双重计账。

### 8.1 QuotaBackend（新增 3 文件 + 4 处修改）

| 文件 | 职责 |
|------|------|
| `ClaudeProxy/Runtime/OpenCodeProxyConfiguration.swift` | `PROXY_TARGET=opencode` 环境配置：上游 baseURL（允许空 Key，本地上游如 Ollama）、可选客户端鉴权 |
| `ClaudeProxy/Runtime/OpenCodeProxyService.swift` | chat/completions 忠实透传 actor：不改写请求体、旁路解析 usage（`prompt_tokens - cached_tokens` 口径）、错误结构复用 `CodexErrorResponse` |
| `QuotaServer/QuotaHTTPServer+OpenCodeProxy.swift` | 入站 `/v1/chat/completions`（流式/非流式）+ `/v1/models` 透传 + `PROXY_LOG` 发射 |
| `OpenAICompatibleClient.swift`（改） | 原始透传方法泛化端点路径（`sendRaw(path:)`）；新增 `streamRawChatCompletions`（chat SSE 无 `event:` 行，必须按 `data:` 行切帧）；空 Key 不发 Authorization 头 |
| `QuotaHTTPServer.swift` / `main.swift`（改） | 注册 openCodeProxyService、路由与互斥加载（codex > opencode > claude） |

### 8.2 App 层（新增 3 文件 + 5 处修改）

| 文件 | 职责 |
|------|------|
| `Services/QuotaServerLocator.swift` | 从 `ProxyRuntimeService` 抽出的 QuotaServer 可执行文件定位/按需构建（两轨共用） |
| `Services/OpenCodeProxyRuntime.swift` | 单子进程管理：启动/健康检查/崩溃自动重启（≤3 次）/PROXY_LOG → `ProxyRequestLog` 内存环形缓冲（200 条，成本恒 0） |
| `Views/OpenCodeRequestLogSection.swift` | 管理页底部实时请求日志区块（§10 重构中删除，改为节点内联「最近请求」） |
| `Models/OpenCodeNode.swift`（改） | `proxyEnabled` / `proxyPort`（默认 4321，旧档案兼容解码） |
| `ViewModels/OpenCodeConfigManager.swift`（改） | `activate(node:baseURLOverride:)`：代理模式 baseURL 指向 `127.0.0.1:<port>/v1`，apiKey 写占位符（真实 Key 留在代理进程环境） |
| `ViewModels/OpenCodeNodeStore.swift`（改） | 激活编排（先拉代理再写配置，失败回收）；App 重启后恢复代理进程（否则 opencode.json 指向死端口） |
| `Views/OpenCodeManagementView.swift` / `OpenCodeNodeEditorView.swift`（改） | 代理开关 + 端口、运行状态横幅、重启按钮、节点卡「代理」徽标 |

### 8.3 明确不做

- 不写 `proxy-usage-opencode-v1.json` 归档、不计代理轨成本（db 已是全量账本）。
- 不接菜单栏 TrackSwitcher / `StatsHubView` 双轨（`UsageTrack`）。
- 多节点同时起代理：单活跃节点模型下无需求。

## 9. 协议补齐（直连 npm 选择 + 代理轨道复用，已实现）

OpenCode 自定义 provider 的上游协议由受管块的 `npm` 字段决定，因此协议补齐
**直连模式只是换包名，代理模式只是换 QuotaServer 的选轨环境变量**——三条入站
路由（`/v1/chat/completions`、`/v1/responses`、`/v1/messages`）与 PROXY_LOG
发射在后端早已存在，无新增后端代码。

| `OpenCodeProtocol` | npm 包 | SDK 拼接路径 | 代理选轨环境变量 |
|---|---|---|---|
| `openai-compatible`（默认） | `@ai-sdk/openai-compatible` | `/chat/completions` | `PROXY_TARGET=opencode` |
| `anthropic` | `@ai-sdk/anthropic` | `/messages` | `PROXY_MODE=passthrough` + `ANTHROPIC_UPSTREAM_URL`（剥 `/v1` 后的根地址）/`ANTHROPIC_UPSTREAM_KEY` |
| `openai-responses` | `@ai-sdk/openai` | `/responses` | `PROXY_TARGET=codex` + `OPENAI_API_MODE=responses`（**强制要求 Key**，缺失则激活前拦截） |

要点：

- `OpenCodeNode.protocolType`（旧档案缺省 `openai-compatible`，`decodeIfPresent` 兼容）。
- 代理模式本地 baseURL 三协议共用 `http://127.0.0.1:<port>/v1`：SDK 各自拼接的路径恰好
  命中 QuotaServer 对应轨道的入站路由。
- 启动子进程前清除继承环境里的选轨/认证残留（`PROXY_TARGET/PROXY_MODE/ANTHROPIC_API_KEY` 等），
  避免误启别的轨道或被 passthrough 当作客户端校验 Key 拒掉请求。
- 编辑器：协议分段选择器 + 按协议适配的 Base URL 提示、模型获取（Anthropic 风格带
  `x-api-key` + `anthropic-version` 头）、连通性测试（Responses 用 `max_output_tokens: 16`，
  API 最小值）。节点卡片对非默认协议显示橙色协议徽标。

## 10. 管理页深度对齐 Claude 页（已实现）

整页采用与 Claude/Codex 管理页**同一套视觉语言与交互骨架**。数据源分工（已过寸止，方案 C·混合）：

- **用量/费用/最近请求** → opencode.db 节点归因（`OpenCodeNodeStatsFetcher`，
  LIKE 预过滤 `aiusage` 行 + JSON 防御解析，按 providerID 聚合 + 最近 200 条明细，
  含 data.time 推出的单条耗时）。直连/代理模式都有数据，费用与用量统计页同口径。
- **成功/失败计数与失败明细** → 代理日志（`OpenCodeProxyRuntime`，仅代理模式，直连显示 —）。
  代理日志落盘持久化（`~/.config/aiusage/opencode-proxy-logs.json`，500 条环形 +
  2s 防抖写入，成本恒 0 不变）。平均响应优先取 db 单条耗时（直连也有）。

页面骨架（自上而下）：告警横幅（仅异常态：JSONC 无法接管 / 代理进程故障或未运行；
常态不占版面，接管状态由卡片激活开关表达，与 CC 一致）→ 工具栏（`opencode.json`/
导入节点/导出节点/新建节点，CC 同款容器按钮组；`opencode.json` 按钮打开内嵌语法
高亮编辑器——参数化复用 `LocalSettingsEditorView`+`JSONRawEditorView`，非 Finder
reveal）→ 汇总条（节点数/已激活/总请求/成功率/总 Tokens/总费用）→ 节点列表。

节点卡片（CC `ConfigurationCardView` 同款，Equatable 跳渲染）：顶部协议徽章
（`OpenAI|Anthropic|Responses Direct/Proxy` 短名措辞，与 CC「OpenAI Proxy」对齐，
按协议配色）、拖拽把手、左侧统计 pills（请求数/费用）、名称/URL/连通性状态行
（成功 `200 · 885ms · 时间`；失败可点开 Popover 看完整报文+重试）、右侧动作区
（激活开关 `ProxyActivationToggleStyle` + 代理模式 antenna 切换 + **复制启动命令**
（导出与激活同口径的独立配置到 `~/.config/aiusage/opencode-configs/<slug>.json`，
命令 `OPENCODE_CONFIG="<path>" opencode`，不改全局配置，与 CC `claude --settings`/
Codex `CODEX_HOME` 同构）+ 连通性测试 + 编辑 + 删除）、右键菜单（含复制节点/
复制启动命令）。**单击内联展开**：卡片内配置明细（含定价行）+ 卡片下方
「统计信息」网格（总请求/成功/失败/平均响应/输入/输出/缓存读写/命中率/费用）+
「最近请求」列表（db 成功消息与代理失败日志按时间合并，限 10 条）——与 CC 完全同构。

编辑器对齐：顶部 Tab（节点设置 / JSON 预览）。JSON 预览为只读的「激活后 opencode.json
最终内容」（与现有配置合并，代理模式显示本地 baseURL + Key 占位符语义说明）。
不移植 CC 的可视化配置 Tab（那是 settings.json 的 env/权限/钩子，OpenCode 受管块已被
表单全覆盖）与 Opus/Sonnet/Haiku 槽位（Claude 专属）。

节点计费（CC 定价区同款）：每节点四项单价（输入/输出/缓存写入/缓存读取，USD/百万
token，含缓存 1.25×/0.1× 自动填充）。**不在本地算账**——单价写入受管块每个模型的
`cost` 字段（models.dev schema），OpenCode 据此把逐条消息的真实消费算进 opencode.db，
统计页/卡片 pill/用量统计自动呈现金额（自定义 provider 默认无价、cost 恒 0 的问题由此
解决，对既往消息不回溯）。代理端口字段常驻显示（未开代理时禁用），与 CC 一致。

品牌图标：`ProviderIcons/opencode.imageset`（lobehub 官方 opencode logomark SVG，
template 渲染自适应明暗），替换此前的 SF Symbol 兜底。

模块构成：

| 文件 | 职责 |
|------|------|
| `QuotaBackend/Providers/OpenCodeNodeStatsFetcher.swift`（新） | db 按 providerID 聚合 + 最近明细（复用快照/READONLY 机制） |
| `ViewModels/OpenCodeNodeStatsStore.swift`（新） | 统计快照主线程发布；出现节流 30s + 激活/停用后刷新 |
| `Services/OpenCodeConnectivityTester.swift`（新） | 协议感知的连通性探测（卡片与编辑器共用），产出 `ProxyConnectivityTestState` |
| `Views/OpenCodeNodeCard.swift`（重做） | CC 同款卡片（徽章/pills/开关/antenna/测试/编辑/删除/右键/内联明细/Equatable） |
| `Views/OpenCodeNodeStatsSection.swift`（重做） | 汇总条 + 选中节点内联「统计信息」/「最近请求」区块（CC 同款视觉） |
| `OpenCodeNodeStore`（改） | 节点导入/导出 + 复制节点（新 id/slug，代理端口避让） |
| `OpenCodeConfigManager`（改） | 受管块构建抽取（含模型 `cost` 定价块）+ `previewMergedConfig`（编辑器 JSON 预览，不落盘） |
| `OpenCodeManagementView`（重做） | CC 同款骨架与列表编排；连通性状态字典 |
| `Views/OpenCodeManagementView+Toolbar.swift`（新） | 状态横幅 + 工具栏（opencode.json/导入/导出/新建），拆出以控规模 |
| `Views/OpenCodeRequestLogSection.swift`（删除） | 页面级日志区被节点内联「最近请求」取代 |

### 10.1 通用配置 + 分层预览 + 统计自动刷新（第四轮反馈）

通用配置（CC 同款语义）：复用 `GlobalConfig`（深合并）与 `CommonConfigMode`
（跟随全局/始终合并/从不合并）两个既有类型，零新模型。片段持久化于
`~/.config/aiusage/opencode-global-config.json`，激活时合并顺序固定为
**用户原文 ← 通用配置 ← 受管块**（受管键始终最终生效；通用片段先剥离误带的
aiusage-* 受管键）。`OpenCodeNodeStore.commonSettings(for:)` 是激活/JSON 预览/
启动命令三处共用的单一口径；保存通用配置或编辑活动节点都会即时重激活。
节点级策略存 `OpenCodeNode.commonConfigMode`（可选，nil=跟随全局，旧档案兼容）。

分层最终预览：编辑器「JSON 预览」加合并策略分段选择器 + 行级来源标注
（复用 `JSONRawEditorView` 的 lineMarkers/C-N-O 三色高亮）：无标=用户原文、
C=通用配置、N=节点受管、O=通用覆盖原文。标注算法独立于 CC 版
（层语义不同：CC 是 通用/节点/覆盖，此处是 原文/通用/受管），见
`Views/OpenCodeConfigLayering.swift`。

统计自动刷新：此前仅「页面出现 + 30s 节流」，对话后必须离开再回来才更新。
现 `OpenCodeNodeStatsStore` 在管理页可见期间每 3s 轮询 db 变更指纹
（`OpenCodeNodeStatsFetcher.databaseFingerprint()`：opencode.db/-wal 的
mtime+size），指纹变化才整库快照扫描——无对话时零扫库开销，有新消息秒级反映。

| 文件 | 职责 |
|------|------|
| `Views/OpenCodeGlobalConfigSection.swift`（新） | 节点列表上方「通用配置」卡片（开关 + 语法高亮编辑 sheet） |
| `Views/OpenCodeConfigLayering.swift`（新） | 分层行标计算（原文/通用/受管/覆盖 → lineMarkers） |
| `OpenCodeNodeStore`（改） | globalConfig 加载/保存 + `commonSettings(for:)` 合并口径 + 变更即时重激活 |
| `OpenCodeConfigManager`（改） | `activate/previewMergedConfig/makeLaunchCommand` 接 commonSettings；`pristineConfig`/`managedLayer` 供分层标注 |
| `OpenCodeNodeStatsFetcher`（改） | `databaseFingerprint()` 轻量变更探测 |
| `OpenCodeNodeStatsStore`（改） | 可见期 3s 指纹轮询，变化才刷新 |

### 10.2 每模型独立定价 + 默认模型快切 + 三页一致性（第五轮反馈）

数据模型重构：`OpenCodeNode.models: [String]` + 节点级四项单价 →
`modelEntries: [OpenCodeModelEntry]`（模型 ID + 每模型四项单价）+
`pricingCurrency`（无/USD/CNY；CNY 录入写 cost 块时按 ≈7.3 折算成 USD——
opencode.db 的费用口径是 USD，折算策略与 Claude 节点一致）。
`models` 降级为计算属性（setter 保留同名条目定价），既有调用零改动；
旧档案解码迁移：legacy models + 节点级单价 → 各模型继承同一单价，
任一单价 > 0 视为 USD 计价。编码不再写 legacy 键。

编辑器模型区改为行式（替代「每行一个」文本框）：每行 = 默认模型单选钮 +
模型 ID（等宽字体，稳定 UUID 行号避免打字丢焦点）+ 四项单价（币种非「无」时显示）
+ 删除；顶部币种分段选择器（无/USD/CNY）+ 缓存自动填充（1.25×/0.1×，逐行应用）；
获取模型追加为新行。默认模型快切不必进编辑器：卡片展开区内联 Picker +
右键「默认模型」子菜单，保存即生效（激活中节点由 upsert 自动重写 opencode.json）。

三页一致性：
- 卡片配色对齐 CC/Codex 的「紫 = 代理」语义（第六轮已改为 §10.3 的「仅代理运行」口径）。
- 抽共享 `SecureKeyField`（带眼睛显隐的密钥输入框，源自 OpenCode 编辑器）：
  CC 编辑器两处（Anthropic Key / 上游 Key）与 Codex 编辑器上游 Key 接入。
- 编辑器窗口统一为 750（设置）/ 1100（JSON 预览）× 800，与 CC/Codex 同尺寸。

### 10.3 仅代理 + 菜单栏切换器 + cc-switch 同步（第六轮反馈）

**卡片状态语义改为与 CC/Codex 完全一致**：品牌色 = 激活，紫色 = 「仅代理」运行中；
「代理模式」本身只是节点类型（徽章表达 Proxy/Direct），不再给卡片染色——
此前激活的代理节点整卡紫色，与「仅代理」视觉无法区分。天线按钮从「切换代理模式」
改为「仅代理启停」（代理模式节点专属；激活期间置灰，代理随激活运行）；
模式切换移到右键菜单/编辑器。

**仅代理（proxy-only）**：`OpenCodeNodeStore.proxyOnlyNodeIds: Set<String>`
（随 StoreFile 持久化，重启自动恢复）。拉起本地透传进程暴露端口，但不接管
opencode.json，配合「复制启动命令」独立接入。`OpenCodeProxyRuntime` 重构为
**多进程模型**（与 Claude/Codex 的 ProxyRuntimeService 同语义）：每节点一个独立
子进程、各占一端口，可同时运行多个仅代理节点 + 一个激活节点；同端口启动报可读
错误（运行时先做实例间端口冲突检查，避免 killStaleProcesses 误杀自己的子进程）。
激活某节点时该节点退出仅代理集合（代理随激活运行，进程参数没变则原地复用）。

**横幅闪现修复**：`OpenCodeProxyRuntime.start` 幂等化——同节点且代理相关参数
（协议/上游/Key/端口）未变时复用现有进程。此前切换通用配置触发重新激活会让
代理闪断一拍，顶部「本地代理未在运行」横幅闪现。横幅改为列出所有「应运行而
未运行」节点的端口，重启按钮拉起全部停摆实例。

**菜单栏切换器**：控制台新增 OpenCode 轨道（Codex → OpenCode → Claude Code，
与侧边栏同序），节点列表勾选当前生效、点击激活/还原 opencode.json；
三轨道共用 `trackSwitcherLabel` 外观。

**cc-switch 同步**（`OpenCodeNodeStore+CCSwitchSync.swift`）：cc-switch v3.x 把
OpenCode 供应商存在 `~/.cc-switch/cc-switch.db` providers 表（app_type='opencode'），
`settings_config` 即 opencode.json 的 provider 片段 `{npm, options{baseURL,apiKey}, models{...}}`。
映射：npm 包名 → 协议类型（openai-compatible/anthropic/openai→responses）、
models 的 `cost` 块（USD/百万）→ 每模型定价、`limit` → 上下文/输出上限。
节点 id 由行 id + 盐派生确定性 UUID，重复同步 upsert 同一批节点（保留本地代理设置、
归因 slug、排序）。cc-switch 对 OpenCode 无通用配置（其源码显式不适用），故只同步供应商。

**数据库定位（CCSwitchLocator，三处同步共用）**：cc-switch 支持自定义配置目录，
覆盖路径存于 `~/Library/Application Support/com.ccswitch.desktop/app_paths.json`
的 `app_config_dir_override` 键（Tauri store）；未设置时默认 `~/.cc-switch`。
此前 Claude/Codex/OpenCode 三处同步都硬编码默认路径，用户迁移过配置目录后
会读到陈旧库——`NodeProfileStore` 与 OpenCode 同步现统一走 `CCSwitchLocator.databasePath()`。
解析优先级：设置页「数据与刷新 → cc-switch 配置目录」手动指定（权威，db 缺失时
如实报错不回退）> app_paths.json 自动探测（要求 db 存在）> 默认目录。
导入节点名称统一加「 (cc-switch)」后缀（与 Claude/Codex 导入同款来源标记）。

## 11. 风险与缓解

| 风险 | 缓解 |
|------|------|
| opencode.db schema 漂移（内部 API，Drizzle 迁移） | 只读 + 防御解析 + 失败降级为采集错误；社区工具（ccusage、oc-stats）同押此路径，漂移会被快速暴露 |
| OpenCode 进程写库时读取 | 临时快照 + READONLY；不持久持有连接 |
| `cost: 0` 双语义（订阅 vs 真未定价） | Phase 1 不报 unpriced；如实呈现 0 成本 + token 量 |
| 巨型 message 表 | 30 天窗口下推 SQL + 冻结归档；首次全量仅一次 |
| 桌面版数据目录不同 | Discovery 多路径探测（§2.1） |
| 内嵌 QuotaServer 过旧（曾导致代理 404「Not found」：build phase 声明 outputPaths 但无 inputPaths，Xcode 增量构建跳过 swift build+拷贝） | 「Build QuotaServer Helper」phase 改为 alwaysOutOfDate=1，每次构建都跑（swift build 自身增量，代价小） |

## 12. 全局统一代理与节点归因（已实现）

> 由 Codex/Claude「全局统一代理」扩展到 OpenCode。与 §8 路线 B（每节点独立进程、
> 日志仅观测、计费走 opencode.db）是**两套不同轨道**：全局代理是常驻单进程、随激活节点
> 热切换、**计费走代理日志**（db 侧排除全局 provider）。两者可并存，互不影响。

### 12.1 形态

- 一个常驻 `QuotaServer` 进程长期占用固定端口（默认 14401），对 CLI 暴露稳定入口：
  接口协议 + 端口 + client key + 固定虚拟模型名。`opencode.json` 一次性指向它（受管 `aiusage`
  provider 块 + 顶层 `model`）。
- 启用时先选接口协议（OpenAI 兼容 / Anthropic / OpenAI Responses），**只能在「同接口」节点间
  热切换**以保证 wire 格式兼容；切换激活节点走进程内热替换（admin POST），CLI 无感、端口不变。
- 启用期间接管 `opencode.json` 并禁用每节点单独激活（由本卡片统一切换激活节点）。
- 三轨默认值：端口 14399/14400/14401（Codex/Claude/OpenCode）；虚拟模型 `gpt` /
  `opus,sonnet,haiku` / `LLM`。虚拟模型名仅作 CLI 固定入口名，**可任意取**——会被代理改写为
  激活节点的真实上游模型（Claude 按 opus/sonnet/haiku → 节点 大/中/小 三层映射）。三轨全局区块
  均有 Tip 说明此改写语义。

### 12.2 模型改写

- CLI 端固定发虚拟模型名，后端按激活节点真实模型**无条件改写**请求体 `model`
  （`OpenCodeProxyConfiguration.forcedModel` / `ClaudeProxyConfiguration.forcedModel`）。
- 每节点代理模式（路线 B）`forcedModel = nil` → 不改写，忠实透传。

### 12.3 接口 → 后端轨道映射

`GlobalProxyRuntime.opencode` 是单一实例（`track == .opencode`），但按接口构造不同启动 env /
admin 路由（`OpenCodeGlobalProxyAdapter`），复用既有三条入站路由与 `PROXY_LOG` 发射：

| 接口 | 后端轨 | 入站路由 | admin 路由 |
|---|---|---|---|
| OpenAI 兼容 | `PROXY_TARGET=opencode` | `/v1/chat/completions` | `/__aiusage/admin/opencode-upstream` |
| Anthropic | `PROXY_MODE=passthrough` | `/v1/messages` | `/__aiusage/admin/claude-upstream` |
| OpenAI Responses | `PROXY_TARGET=codex` | `/v1/responses` | `/__aiusage/admin/codex-upstream` |

### 12.4 归因链路（计费走代理日志）

1. **打点**：后端在全部三个接口处理器都按 `activeNodeId` 在 `PROXY_LOG` 里打 `node_id`
   （`activeNodeId` 来自启动 env `GLOBAL_PROXY_NODE_ID`，每次 admin 热切换原子更新）。
2. **路由**：`GlobalProxyRuntime` 的 stdout 读取把 `.opencode` 轨日志交给
   `OpenCodeProxyRuntime.ingestGlobalProxyLog`（Codex/Claude 轨仍走 `ProxyViewModel.parseProxyLog`）。
3. **计费 + 落账**：`ingestGlobalProxyLog` 按 `node_id` 找节点、按节点定价就地算 `estimatedCostUSD`
   （`isGlobalProxy = true` 标记），然后三处写入：
   - `requestLogs`（节点卡片成功率 / 最近请求）；
   - `globalNodeStats[nodeId]` 永久累计 → `opencode-global-usage.json`（节点卡片用量/费用）；
   - `ProxyUsageArchiveStore.accumulate(.opencode, …)` 按天 × 真实上游模型增量归档 → 热力图。
     归档模型键写成 `aiusage-<slug>/<上游模型>`（与 db 直连/路线 B 完全一致），让同节点同模型跨两条路径合并为一行。
     （原始日志环形封顶会被裁剪，故按发生即增量累加、不可整日重算，跨重启不重复折叠。）
4. **后端热力图合并**：`OpenCodeCostProvider.fetchUsage` 把 db 冻结归档与代理归档按天合并
   （`OpenCodeCostProvider+ProxyArchive.swift`）。因模型键同口径（`aiusage-<slug>/<model>`），
   同节点同模型自动合并、**不加任何来源后缀**；展示层 `StatsDataAdapter.displayModelLabel` 统一剥掉 `aiusage-` 前缀。
   db 侧 `OpenCodeCostProvider+Parsing` 与 `OpenCodeNodeStatsFetcher` 均排除裸 `aiusage`，两源互斥不双计。

### 12.5 节点卡片展示（与 Codex/Claude 同体验）

- **列表卡片 pills（请求数/费用）/ 概览汇总 / 统计网格**：db 节点归因 + 全局永久累计两源相加。
- **最近请求**列表按来源区分，避免双列：db 成功行（直连/路线 B）+ 路线 B 代理失败行 +
  **全局代理日志成功与失败都显示**（db 不记全局流量，代理日志是其唯一来源，靠 `isGlobalProxy` 判别）。
- 删除节点时 `OpenCodeProxyRuntime.purgeNode` 清理该节点的 `globalNodeStats` 与 `requestLogs` 残留。

### 12.6 与路线 B 的计费差异（务必区分）

| 维度 | 路线 B（每节点透传代理） | 全局统一代理 |
|---|---|---|
| 进程 | 每节点一个，端口各异 | 单进程，固定端口，热切换 |
| 接管 opencode.json | 否（配合「复制启动命令」） | 是（注入裸 `aiusage` 块） |
| db providerID | `aiusage-<slug>`（计入 db） | `aiusage`（db 双双排除） |
| 计费来源 | opencode.db 冻结 cost | 代理日志按激活节点定价冻结 |
| 代理日志角色 | 仅观测（失败明细 + 成功率） | 节点用量/费用/成功失败的唯一来源 |

### 12.7 用量统计 & 热力图：两源合并与去重（核心，务必读）

OpenCode 用量只有两个真相源，二者是**互斥的事件集合**，相加即全量、不双计：

| 源 | 内容 | 模型键 | 谁负责 |
|---|---|---|---|
| **A. opencode.db** | OpenCode 本地会话消息（直连 / 路线 B 透传） | `aiusage-<slug>/<model>`（受管节点）或第三方 `provider/model` | `OpenCodeCostProvider+Parsing` |
| **B. 代理日志归档** | 全局统一代理转发流量（按激活节点定价冻结成本） | `aiusage-<slug>/<model>`（App 侧 `ingestGlobalProxyLog` 写出） | `OpenCodeProxyRuntime` → `proxy-usage-opencode-v1.json` |

**为什么需要 B**：全局代理在 opencode.json 注入的是**裸 `aiusage`** provider，OpenCode 只会把这条流量记成 `aiusage/<虚拟模型>`——它**不知道实际转发到了哪个节点/哪个真实模型**，无法做节点归因。代理日志在 `QuotaServer` 处用启动 env `GLOBAL_PROXY_NODE_ID`（admin 热切换原子更新）给每条 `PROXY_LOG` 打上真实 `node_id` + 真实上游模型，这才补上了 db 缺失的节点维度。

**如何去重（去掉「全局聚合」、换成「各节点真实用量」）**：

1. db 解析在 `OpenCodeCostProvider+Parsing` 与 `OpenCodeNodeStatsFetcher` 两处都**丢弃裸 `aiusage`** 那条全局聚合（`providerID == "aiusage"` → skip）。即用户说的「那条只知道全局、不知道节点的用量」被整条移除。
2. 同一笔全局流量改由源 B 以 `aiusage-<slug>/<真实模型>` 重新计入——节点维度由 `node_id` 还原，成本按该节点单价冻结。
3. 因为 A 与 B 的模型键**完全同口径**（都是 `aiusage-<slug>/<model>`），`mergeProxyDays` 按「日 × 模型键」相加时，**同节点同模型自动并入同一行**：
   - 某节点既走过直连/路线 B（落 A）又走过全局代理（落 B）→ 两段用量合并为该模型一行，不拆分、不重复。
   - 不同节点（不同 slug）的同名模型 → 仍按节点分行，保留归因。
4. 展示层 `StatsDataAdapter.displayModelLabel` 统一剥掉 `aiusage-` 前缀，热力图/分布显示为干净的 `<slug>/<model>`。

**热力图与节点卡片的喂数关系**：

- **热力图 / 用量统计页**：吃后端 `OpenCodeCostProvider.fetchUsage`（A 冻结归档 + B 代理归档按日合并）。
- **节点卡片 pills / 统计网格 / 最近请求**：吃 `OpenCodeNodeStatsFetcher`（A 的节点桶，排除裸 `aiusage`）**＋** `OpenCodeProxyRuntime.globalNodeStats`（B 的逐节点永久累计）相加。

**结论**：能准确按节点 × 模型显示用量；裸全局聚合已被移除并按 `node_id` 拆回各节点真实用量；A/B 互斥相加不双计。**唯一前提**是全局代理必须把 `node_id` 正确打进 `PROXY_LOG`（已在三个接口处理器统一打点）；若某条日志缺 `node_id`（理论上不应发生），该条会退化为裸上游模型名、归不到具体节点，但不会被重复计入。
