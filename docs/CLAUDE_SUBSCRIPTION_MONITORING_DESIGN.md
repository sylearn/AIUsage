# Claude 订阅监控：调研与设计

调研日期：2026-10-06（Asia/Shanghai）

AIUsage 基线：`7935fe0feac7bb8a30b4ba86f52e1e15f3f4cf90`
状态：订阅监控、Code 来源切换及本地用量/调用账本已实现；真实 Pro / Max 额度仍待用户正常会话验收。开发验证未读取订阅 Token / Cookie，未修改现有 Claude 登录、配置或代理。

## 1. 最终建议

在「订阅账号」新增独立的 **Claude 订阅**，内部 ID 为 `claude-subscription`。保留原有 `claude` 的 Gateway 费用账本，不改 ID、不迁移历史统计。

当前实现与后续补充：

1. **默认：官方 Claude Code statusLine JSON 回传。** 读取公开的 5 小时 / 7 天额度字段，不收集登录凭证，也不主动发送模型请求。
2. **补充：启动官方 Code 后手动输入 `/usage`，或打开网页用量页。** 当前不自动提交 slash command、不解析终端面板。PTY 可行性与真实字段覆盖验证后，才考虑手动采集；不做高频后台轮询。

同时在 **Claude → Code** 增加新会话来源选择：已有 API 代理 / 独立官方订阅配置。每张订阅卡支持“使用账号”和“启动 Code”。切换只作用于 AIUsage 启动的新进程，不复制凭证、不替换默认登录、不终止已有会话。

OAuth / 网页接口确实有开源实现，但当前官方凭证使用限制使它们不适合作为默认产品路径。记录技术合同，待 Anthropic 提供明确授权或公开支持后再考虑启用。

**首版验收目标是“可信的订阅监控”，不是“界面上填满所有字段”。** 核心额度、来源、新鲜度、多配置目录、连接引导、告警、暂停、备注、隐藏和删除都应完整；来源不提供的金额、套餐、模型额度明确留空。

## 2. 实施前的缺口

| 当前实现 | 已确认行为 | 对新增功能的影响 |
| --- | --- | --- |
| `QuotaBackend/.../Providers/ClaudeProvider.swift:11` | ID=`claude`；唯一来源是 Gateway 永久日归档 | 不是订阅额度，也不是当前 JSONL 扫描器 |
| `Normalizer/UsageNormalizer+Claude.swift` | `local-cost`，`windows=[]` | 不能直接补几个配额字段冒充订阅监控 |
| `AIUsage/Models/AppState.swift:27` | Codex 为 `.official`；Claude 为 `.costTracking` | Claude 不会进入订阅页的官方应用列表 |
| `AIUsage/Views/ProvidersView.swift:328` | 订阅页仅展示 `.official` 分组 | 新增独立目录项即可沿用页面结构 |
| `Providers/CodexProvider.swift` | 官方用量窗口、凭证导入、多账号、刷新和身份隔离 | 可复用产品能力与数据协议，不能照搬凭证策略 |
| `SubscriptionAccountListModels.swift` | 额度低仍算在线；采集错误才归为需处理 | 不要把“额度耗尽”误当“登录失效” |
| `CLIProxyGatewayManager+SubscriptionBridge.swift:120` | 可导入列表无 Claude | 本轮不顺手扩展 CPA 凭证导入 |

现有展示链路：

```text
ProviderRegistry → ProviderEngine → UsageNormalizer
                                   ↓
                     ProviderRefreshCoordinator
                                   ↓
AccountStore → ProviderAccountGroupSection → ProviderCard / ProviderDetailView
```

沿用这条链路，不建第二套订阅管理系统。`docs/NEXT_VERSION_TODO.md` 和旧 Provider 审查文档包含过时的 Claude JSONL 描述，本方案以当前源码为准。

## 3. 已核实的产品语义

- Claude 网页、Desktop、Claude Code 等产品的订阅使用共同影响账号额度；不是各自独立余额。[S1][S2]
- 额度百分比不等于 Token 百分比。上下文长度、模型和 effort 等会影响实际消耗，不能用代理 Token 反算剩余额度。[S2]
- Pro / Max 的 5 小时和周额度是首版核心；模型专属额度按来源实际返回展示，不假定每个套餐都有 Sonnet / Opus 窗口。[S3][S7]
- API Console 用量与个人订阅是不同系统。Admin API 的 Token / Cost Report 不能替代 Pro / Max 订阅仪表。[S1][S6]
- “额外用量 / usage credits”是订阅额度之外的支出。月支出上限、已消费金额、预付余额是三种不同指标，不能合并成一个“剩余额度”。[S5][S8]
- 本地 `$cost`、statusLine 的 `cost.total_cost_usd`、Gateway 的 `spend_limit` 都不能自动命名为“订阅账单”或“额外用量已花费”。[S3][S6]

### 官方约束怎样影响设计

当前官方文档限制第三方应用提供 Claude.ai 登录、收集/保存/中转 Claude 凭证或会话 Token；官方未修改的 Claude Code 自行完成用户登录是另一条路径。[S4]

因此设计中：

- 登录在官方 Claude Code 中完成，不创建 AIUsage 自有 Claude OAuth 页。
- 不复制 `Claude Code-credentials` Keychain 项，不读取浏览器 sessionKey，不复用官方 OAuth client ID。
- 不在监控操作中重置、登出、切换代理或静默切换真实账号。
- statusLine 与 `/usage` 输出集成是推荐工程方向；本轮不声称官方已认证 AIUsage 集成，也不承诺第三方使用资格。

## 4. 采集方式与接口合同

### 4.1 官方 statusLine：默认方案

官方扩展向用户配置的本地命令 stdin 传入 JSON；stdout 继续作为用户的状态栏文本。公开额度字段：[S3]

```json
{
  "version": "2.1.289",
  "session_id": "示例会话",
  "rate_limits": {
    "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
    "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 }
  }
}
```

以上为合同示例，不是真实账号响应。

| 字段 | 类型/单位 | AIUsage 映射 |
| --- | --- | --- |
| `five_hour.used_percentage` | 0–100 数值 | `primary.usedPercent`；剩余=`100-used` |
| `five_hour.resets_at` | Unix 秒 | UTC Date，显示转用户时区 |
| `seven_day.used_percentage` | 0–100 数值 | `secondary.usedPercent` |
| `seven_day.resets_at` | Unix 秒 | 独立周窗口重置时间 |
| `version` | 字符串 | 诊断兼容性，不作为账号身份 |
| `session_id` | 字符串 | 分会话缓存隔离，不是账号 ID |

已核实边界：[S3]

- 官方文档明确列出的个人订阅支持是 Pro / Max；Team / Enterprise 不能仅凭同样字段结构宣称支持。
- 在会话首次 API 响应后才有额度；不得为了取得数据主动发送模型请求。
- 两个窗口可分别缺失。重置时间已过时，官方会移除旧窗口；AIUsage 同样不能把旧值变成 100%。
- 自定义状态栏运行本身不消耗 API Token；这是本地执行，不代表每次执行都发起新的额度查询。
- 没有公开的模型专属额度、额外用量余额、套餐续费日期或可信账号 UUID 字段。
- 定时重跑 `statusLine` 只是重跑脚本，不能据此承诺跨设备额度实时更新。

### 4.2 官方 CLI `/usage`：手动补充

官方命令用于展示计划额度等信息；当前帮助未提供独立的 `claude usage --json` 命令。`--output-format json` 属于 print 模式，不能假定它能导出交互式 `/usage`。[S9]

当前菜单“启动 Code 后输入 /usage”只启动官方交互式 CLI 并提示用户输入，不将其输出解析为 AIUsage 用量。后续候选方案为独立临时工作目录 + 短生命周期 PTY，只解析可识别的额度面板。

要求：

- 只由用户触发，按配置目录串行，合并重复点击，取消/超时必须清理本次子进程。
- 不加载当前仓库的 CLAUDE.md、MCP、插件或启动 hooks。先验证当前版本的 `--safe-mode`、`--no-session-persistence` 等选项，不使用 `--bare`：其帮助明确排除订阅 OAuth。
- 不用普通模型问答“查询我的额度”，不承诺 `/usage` 启动完全零网络/零后台消耗。[S10]
- 20–30 秒作为待测试的总预算；现有 ProviderEngine 默认 15 秒，若接入该路径需给 Claude 手动探测独立超时，不能拉长所有 Provider。
- 解析 ANSI / 重绘后的最后一个完整面板；缺失标签不按第几个百分比猜测，避免把 context 的 0% 识别成订阅用量。
- 重置文案只有可确定时区/日期时才转 Date；否则保留原始说明，不猜下周一。
- 只有官方面板确实返回的模型窗口才展示；全部字段覆盖仍需真实账号验收。

本轮阅读的 CodexBar 源码证明 PTY 有可参考实现，不等于已证明 AIUsage 能在所有 CLI 版本和套餐上完成采集。[S7]

### 4.3 OAuth / Web：技术调研，暂不启用

CodexBar 已检查版本：`6a26b2e9b1b60471970deb6fe663f9e5f284e2ce`。这些是源码观察，不是 Anthropic 公开稳定 API 承诺，也未用真实订阅认证探测。[S7][S8]

| 路径 | 认证/返回 | 设计取舍 |
| --- | --- | --- |
| `GET api.anthropic.com/api/oauth/usage` | Bearer + `anthropic-beta: oauth-2025-04-20`；`five_hour` / `seven_day` / 模型窗口 / `extra_usage` | 非公开订阅接口；暂不调用 |
| `GET api.anthropic.com/api/oauth/profile` | account UUID、email、organization UUID | 候选身份来源；暂不调用 |
| `GET claude.ai/api/organizations` | sessionKey；组织列表 | 不默认挑第一个组织 |
| `GET claude.ai/api/organizations/{orgId}/usage` | sessionKey；用量窗口 | 非公开网页接口，可能遇到 Cloudflare |
| `GET claude.ai/api/account` | sessionKey；邮箱、组织、套餐线索 | 不根据邮箱猜组织 |
| `GET .../{orgId}/overage_spend_limit` | 月额外支出与上限 | 不和订阅额度混加 |
| `GET .../{orgId}/prepaid/credits` | 预付余额 | 不用“月上限-已花费”冒充此余额 |
| `GET api.anthropic.com/v1/organizations/usage_report/messages` / `cost_report` | 正式 Admin API 认证 | API 管理报表，不接个人订阅页 |

候选合同需要保留的差异：

- OAuth/Web 窗口是 `utilization` + `resets_at`（ISO 时间）；statusLine 是 `used_percentage` + Unix 秒。
- OAuth `user:profile` 权限影响用量访问；`claude setup-token` 官方说明仅用于模型请求，不作为“订阅查询专用 Token”。[S11][S7]
- 新的 `limits[]` 可携带动态 `weekly_scoped` / 模型信息；若以后获准接入，不能硬编码只有 Opus、Sonnet。
- 参考源码把 OAuth `used_credits` / `monthly_limit` 按分换算金额（除以 100）；这是观察到的合同，需获准后用真实响应再确认，不推广到所有金额字段。
- HTTP 401、缺权限的 403、Cloudflare HTML 403、429、5xx 必须区分。429 尊重 Retry-After；不能把所有错误提示成“登录过期”。
- 不复制参考项目的新实验查询参数、伪装 CLI 的 User-Agent 或更多促销额度功能。
- 借鉴 MIT 源码时保留许可证；优先复用概念和小范围解析，不引入整个监控框架。

## 5. 连接和多账号设计

### 能力覆盖，不混淆“可设计”与“已可采集”

| 能力 | 默认 statusLine | 手动 CLI（需实测） | 非公开 OAuth/Web（暂不启用） |
| --- | --- | --- | --- |
| 5h / 周额度及重置 | 官方文档确认 Pro / Max 字段 | 面板读取候选 | 开源源码确认字段 |
| 模型专属周额度 | 未公开提供 | 有标签才展示 | 兼容旧字段和动态模型窗口 |
| 邮箱 / 组织 / 套餐 | 未提供，另查官方身份输出 | 可缺失，不推断 | profile/account 线索 |
| 额外支出 / 预付余额 | 未提供 | 不保证完整金额 | 两类独立数据 |
| 网页用户无 Code 的后台监控 | 不覆盖 | 需安装并登录官方 Code | 技术可行性不等于准许接入 |
| 自动跨设备更新 | 不能保证 | 仅手动采集时更新 | 查询语义，仍非推送 |

因此“和 Codex 一样完善”应落实在连接、状态、额度展示和生命周期，而不是承诺所有来源都有同样的数据覆盖。

### 连接流程

```text
添加应用 → Claude 订阅 → 选择官方配置目录
                        ↓
             检查 CLI 版本和 auth status（不读 Token）
                        ↓
             确认安装状态栏回传，保留原状态栏
                        ↓
             等待正常使用中的首个额度样本
                        ↓
             显示两条额度 / 来源 / 最后回传时间
```

没有 CLI：提示安装官方 CLI，不自动安装。未登录：打开官方终端登录引导，不登出其他账号。只接受 `authMethod=claude.ai`、`apiProvider=firstParty` 且 `configDirectory` 与选择目录一致的登录状态；只有 inference token 不接受。旧 CLI 未返回目录时要求升级，不能以 `loggedIn=true` 判定已监控成功。

### 原状态栏与设置的保留

本机已只读确认 `~/.claude/settings.json` 存在 command 类型状态栏，未读取其命令内容。

复用应用已打包的 `QuotaServer --claude-statusline` 入口，无额外 helper target、Python / jq / Homebrew 运行依赖；入口在服务启动前分支，不监听端口、不输出服务日志：

1. 有状态栏时，将相同 stdin 传给原命令，原 stdout 保持不变；额度提取独立执行，失败不影响原输出。
2. 无状态栏时，提供简短 `5h ... · 7d ...` 原生输出；提示用户这是新启用的自定义状态栏。
3. 仅改所选配置目录的 `statusLine`。保存原对象的完整字段，不改 `env`、模型、effort、权限、hooks。
4. 连接前明确说明修改范围并要求勾选确认；禁止嵌套包裹重复安装。卸载只在当前 command 仍属于 AIUsage 时恢复原命令，用户后来修改的 padding 等键保持；command 被替换则不覆盖。
5. 原命令可能依赖 cwd、TTY、超时、padding；这些是必须做的小范围兼容验收，不保证“任意状态栏无损”。
6. ClaudeSettingsManager 的全量替换、节点切换、备份恢复可能丢失字段：检查每个写入入口，保持已安装回传或显示“回传配置被替换”；不擅自改变节点设置语义。

### 身份与配置目录

- 官方已文档化 `CLAUDE_CONFIG_DIR` 的多账号用法。[S11]
- 当前只存监控目录、显示名、来源类型、目录 SHA256 和登录代次；**目录引用不是凭证副本，也不是真实账号 UUID**。
- `claude auth status --json` 的身份字段可缺失。本机只返回登录类型等字段，无邮箱、组织或套餐；故本轮不能确认当前真实订阅身份/档位。
- 当前标题为“默认 Claude 配置 / 自定义名称”，不显示虚构邮箱或套餐。若后续公开来源提供可信账号/组织 UUID，再补充绑定。
- 多目录先按 canonical path 注册为配置监控条目，不在未验证前把它们计成独立真实账号。
- 从 AIUsage 发起重新登录时先更新 generation，让旧会话样本失效；每次用户明确连接/重连也更新绑定代次。用户在外部终端自行更换同目录登录，statusLine 没有身份字段，无法可靠自动识别，必须重新连接并确认配置名；不能声称已自动识别身份变更。
- `session_id` 分文件保存，避免多进程相互覆盖；同账号多会话只选最近有效样本，不相加。跨来源合并必须先确认身份一致。
- 提供明确的“使用此账号（新会话）”，查看条目不触发切换。选择时用官方 `auth status --json` 检查，不读取认证 JSON 文件或钥匙串。

### 新会话切换与代理优先级

1. 使用官方 `CLAUDE_CONFIG_DIR`，每个配置目录独立登录；不实现默认凭证文件/Keychain 的备份和替换。
2. 订阅进程使用 `/usr/bin/env -u ...` 清除 API 认证、第三方后端和代理模型别名；再用 `--settings` 内联 JSON 清空同名设置与 `apiKeyHelper`，仅作用于该进程。[S11][S12][S13]
3. 新订阅会话选用官方 `sonnet` 别名，避免携带代理虚拟模型；不持久修改用户 model 或 effort。系统 `HTTPS_PROXY` 等出网代理保留。
4. 已有 Code 会话、Gateway 进程、节点、Desktop、Science 不变；返回“API 代理 / 默认 CLI 配置”只是改 AIUsage 启动选择，不自动启动/停止代理。
5. 所选条目被删除时拒绝启动并要求重选，不静默回退到 API 代理。远程后端模式不开放本机连接和启动动作。

## 6. 数据模型与刷新规则

### 最小实现

- `ClaudeSubscriptionProvider` 实现既有 `ProviderFetcher` / `CredentialAcceptingProvider`；`.auto` 类型的记录只保存配置目录引用，metadata 标注 `sourceKind=claude-cli-profile`，不存 Token。现有协议和账号存储可承接，无需增加通用认证框架。
- 新的 `ClaudeSubscriptionSnapshot` 使用 typed 可选窗口与来源字段；helper 只写白名单字段。不能把原始 statusLine JSON、项目路径、对话或完整 PTY 输出写入永久归档。
- `primary`=5h，`secondary`=7d；可验证的模型专属窗口放 `extra.subscriptionWindows`，normalizer 输出到现有 `windows` 数组。
- `accountPlan` 仅来自可验证 CLI 身份输出，未知时不显示 Pro / Max 徽标。个人、组织预算等来源能力分别声明。
- 新快照 `fetchedAt` 使用来源采集时间，而不是“App 刚读了缓存”的时间。
- 可选支出若日后接入，独立用 `extra.subscriptionSpend`（金额、币种、上限、余额、来源）；不写进 `costSummary`，避免重复加到代理成本和仪表盘总费用。
- 监控引用可复用账号 vault；不新增 Keychain 凭证项，不改现有 vault 布局。

### 快照文件合同（内部实现）

```json
{
  "schemaVersion": 1,
  "profileID": "已注册目录的稳定标识",
  "generation": "本次配置绑定 UUID",
  "sessionID": "官方会话 UUID",
  "receivedAt": "最后接收的 Date",
  "observedAt": "该会话额度字段首次出现或变化的 Date",
  "fiveHour": { "usedPercent": 23.5, "resetAt": "窗口 Date" },
  "sevenDay": { "usedPercent": 41.2, "resetAt": "窗口 Date" }
}
```

上面为字段说明，Date 由 Swift Codable 序列化，不是外部 HTTP 协议。路径为 `~/.config/aiusage/claude-subscriptions/{目录SHA256}/profile.json` 和 `snapshot-{sessionUUID}.json`；profile 含原状态栏对象的受保护备份，snapshot 只含额度白名单。原子替换，目录/文件权限 0700/0600，每个配置最多保留 20 条会话快照。App 不运行时 helper 仍可落盘；App 既有扫描器读取，不新增网络服务器或监听系统。

### 新鲜度的语义

- statusLine 重跑时可能收到同一份缓存额度。`receivedAt`只是“最后回传”，同一会话字段不变时保持 `observedAt` 不变。官方测量时间没有来源证据，详情明确“未提供”。
- UI 用“Code 最近回传”而非“官方刚刚刷新”；定时重跑脚本不能刷新真实测量时间。
- 新会话首次响应前的空字段不覆盖另一条有效会话样本；已知窗口明确失效/重置后则不能无限保留为当前值。
- 5 分钟未见新额度证据可提示“最近快照”（产品建议值，非官方 SLA），保留时间和数值；超过窗口 resetAt 后不再作为当前可用额度或触发新阈值告警。
- 读取缓存的“刷新”命名“检查同步”。“启动 Code 后输入 /usage”供用户查看，不声称已重新采集。
- 网页/其他设备使用可能让最后快照落后；状态栏不是全账号实时推送。只用 Claude 网页且不使用 Code 的用户，首版只能打开官方用量页，不能冒充自动监控已覆盖。

### 告警

沿用现有剩余百分比阈值和全局通知设置，不再建一个阈值面板。主状态只使用可信的 5h / 7d 普适窗口；模型专属额度单独提醒，不能把某模型受限描述成整个账号不可用。到达 resetAt 只提示“等待新快照”，不自动宣布恢复。

## 7. 页面与交互

继续使用现有订阅页，不增加侧栏栏目。目录显示“Claude 订阅”；本地统计显示“Claude”，提供合计、代理、非代理筛选。图标复用现有 Claude 资源，支持浅色/深色。

```text
订阅账号                             搜索 / 批量 / 管理来源 / 添加应用
全部应用  Codex  Claude 订阅  ...       全部 / 在线 / 需处理 / 未连接

Claude 订阅             检查同步   暂停同步   批量管理   连接账号
官方订阅额度；与 Claude 网页和 Code 共享

┌ 工作配置 ──────────── 额度快照 ┐   ┌ 默认配置 ─────── 待接收数据 ┐
│ 5 小时剩余    ███████░░  76.5%   │   │ 正常使用 Code 后自动同步   │
│ 本周剩余      █████░░░░  58.8%   │   │ 不会为采集发起模型请求     │
│ Code 最近回传 16:42   查看详情    │   │ 配置已连接    查看连接说明 │
│ 使用此账号（新会话）    启动 Code │   │ 使用此账号（新会话）       │
└─────────────────────────────────┘   └───────────────────────────┘
```

示例名称、时间和额度均为设计数据；当前 statusLine 来源不显示档位或邮箱。

账号详情沿用现有详情入口，新增 Claude 专属来源说明：账号/组织或配置目录、套餐（已知时）、每条窗口的重置时间和来源、数据年龄、来源未提供的功能、原状态栏保留状态。

不新增全局大数字、不创建仿 Claude 官网的米色页面。沿用 `AppSurface` 雾蓝灰/系统深色、SF 字体、现有卡片 320pt 自适应网格。品牌暖色只用于图标；余额仍按现有绿/橙/红语义。

| 状态 | 文案与数据 | 动作 |
| --- | --- | --- |
| 未安装 CLI | 未检测到 Claude Code | 查看安装说明 |
| 尚未连接 | 连接官方 Claude 配置 | 连接账号 |
| 已配置，无样本 | 等待 Claude Code 用量回传；无假进度条 | 查看连接说明 |
| 身份不完整 | 默认配置 / 身份待确认；套餐不显示 | 在官方 Code 中确认登录 |
| 新近回传 | 5h / 7d 剩余 + 最后回传时间 | 检查同步 / 查看详情 |
| 只有一条窗口 | 只显示来源确实提供的窗口 | 查看来源说明 |
| 最近快照 | 保留样本时间；不标“刚刚” | 读取官方用量（验证后） |
| 已到重置时间 | 等待新快照；不用旧值宣布恢复 | 读取官方用量 |
| API / 代理会话 | 当前会话不是可验证订阅额度来源 | 查看来源，不修改代理 |
| CLI 输出变更 | 官方用量格式暂不支持 | 重试 / 打开官方用量页 |
| 暂停同步 | 已暂停；样本时间继续可见 | 恢复同步 |

额度耗尽不是连接错误。隐藏/删除只移除 AIUsage 监控；如需取消 helper，独立确认并做字段级恢复，不删除官方登录或整个配置目录。

## 8. 文件级实施范围

| 文件/模块 | 计划修改 |
| --- | --- |
| 新 `Providers/ClaudeSubscriptionProvider.swift` | 读取白名单快照、配置目录引用与来源能力 |
| 新 `Normalizer/UsageNormalizer+ClaudeSubscription.swift` | 5h/周额度、缺字段、新鲜度；未知模型额度留空 |
| `ClaudeSubscription/` + `QuotaServer/main.swift` | typed Snapshot、字段级安装/恢复、stdin → 最小原子快照；保留原 stdout；复用已打包 helper |
| `Engine/ProviderRegistry.swift` | 注册新 provider，不替换 ClaudeProvider |
| `Normalizer/UsageNormalizer.swift` | 新分支与主题，沿用现有窗口格式化 |
| `AIUsage/Models/AppState.swift` | `.official`目录项；新功能由用户选择，不自动读取/安装 |
| 新 `Services/ClaudeSubscriptionManager.swift` | 官方登录检查、配置选择、新会话启动；不调用 managed credential copy |
| 新 `ClaudeSubscriptionConnectionView` / `ClaudeSubscriptionRoutingSection` | 目录连接确认、Claude Code 来源选择与每账号操作 |
| `ProviderAccountEditorView` / `ProviderDetailView` | 来源适配的连接说明和详情；其余 Provider 不改行为 |
| `ProviderCard` / `ProviderDetailView` / `ProviderModels.swift` | 来源时间、等待/缓存态、连接状态；不把 `nil` 变成 100% 或无限 |
| `ProviderIconView.swift` / 正式打包配置 | 新 ID 映射现有图标；打包签名 helper、升级后路径稳定 |

保留 `claude` ID、代理费用口径、Science 虚拟授权、CPA 账号导入与 Codex 切换逻辑。`ClaudeProvider` 增补本地非代理 Token，详见第 11 节。远程后端模式只读后端主机上的配置与日志，不归入桌面本机账号。

## 9. 分阶段实施与验收

### A. 公开合同与隔离实验（已完成）

已验证公开字段解析、原状态栏串接/stdout/退出码、失效 generation、代理凭据排除；官方 CLI 2.1.289 在独立未登录目录中验证了 `--settings` 可以覆盖外部 API 凭据，不读取真实登录。

通过条件：能取得真实窗口且账号/配置归属清楚；CLI 的启动副作用可控；未改已有代理、模型、权限、hooks 与登录。仅 `claude auth status` 成功不算通过。

### B. 核心闭环（已实现，真实样本待验收）

完成添加应用 → 配置连接 → 自动回传 → 额度卡片/详情 → 告警 → 暂停/隐藏/删除/恢复。验证浅色、深色及 320pt 卡片布局；真实页面同官方 `/usage` 或网页同时间对照。

### C. 真实账号验收与可选补充（未完成）

两个真实不同账号/组织的配置目录验证隔离、同目录换账号、取消探测和升级后的 helper 路径。测试返回模型专属窗口时展示，不返回时留空。OAuth、Cookie、企业报表不作为此阶段隐含需求。

### 聚焦验收清单

- [x] 首次无额度、单窗口缺失、0%已用、100%已用、resetAt已过：隔离测试不制造假余额。
- [ ] Unix 秒 / ISO 时间 / 不确定 CLI 文案各自处理；日期按 Asia/Shanghai 对照。
- [ ] 与同身份官方页面核对 5h / 周额度及重置时间，注明观察时差。
- [x] 重读缓存不把时间改成“刚刚”；重复 statusLine 回传不冒充新的官方查询。
- [ ] 额度耗尽仍是连接正常；模型专属受限不误伤全账号。
- [ ] 两个目录、多并发会话、同目录重新登录不混账号、不累加百分比。
- [x] 原状态栏 stdin/stdout/退出码、对象扩展字段、其他 settings 键在隔离安装/卸载后保持；用户后改 command 不覆盖。
- [x] 节点切换的正式写入路径、全量设置与备份恢复在临时 HOME 中保留回传；断开的旧备份不重启 wrapper。
- [x] 开发验证不输出/复制订阅凭证，不改实际代理，不主动调用模型。
- [x] Codex 隔离、Claude Gateway 转换/透传、费用冻结、归档和账号身份回归通过；真实 Science 登录不在本轮操作范围。

不先做预测耗尽时间、复杂历史图、订阅续费/价格猜测、自动切号、企业管理平台或统一 OAuth 框架。

## 10. 本轮证据与尚未验证事项

已完成：源码与官方资料调研、交互原型、独立 provider、官方目录连接、statusLine 回传/恢复、原生订阅卡片/详情、Claude Code 新会话来源切换。本地用量与调用分析后续补充见第 11 节；不改代理费用定价、Codex 激活、CPA 或 Science 登录。

工程验证：`QuotaServer` 和 macOS App Debug 构建通过；19 项定向测试通过（7 项新订阅、2 项 Claude 费用、8 项 Codex 隔离、2 项注册表）；67 项账号身份断言通过（包含同名 Claude 目录隔离，系统存储替换为内存）；App 包内真实 helper 子进程保留原 stdin/stdout 和退出码，不启动监听服务；测试目录中官方 CLI 认证优先级验证通过。原生 UI 使用独立 Bundle ID 与临时 HOME，已检查来源卡、连接弹窗、确认开关、未登录错误；还使用明确标注“界面测试”的合成配置，检查浅色/深色双窗口、待接收、来源指标、完整详情与证据时间。合成数据不能证明真实订阅采集成功。

复现测试：先构建 `QuotaServer`，将 `AIUSAGE_TEST_CLAUDE_HELPER` 指向 App 包内或 SwiftPM 产品目录的 helper，再执行 `swift test --package-path QuotaBackend --scratch-path <临时目录> --filter 'ClaudeSubscriptionTests|ProviderRegistryTests|ClaudeProviderProxyArchiveTests|CodexAccountIsolationTests'`。本机 Swift 默认使用新 swiftbuild；现有账号回归脚本依赖旧 description.json，本次用 `--build-system native` 的独立临时目录编译同一套正式保存/协调/隐藏/删除源码，未改脚本或真实账号库。

原型已检查浅色/深色、1360px 双列与 780px 单列（无水平溢出）、连接/变更预览、应用筛选和额度紧张状态；脚本语法及浏览器错误检查通过。WCAG 2A/2AA 自动检查为 0 项违规，装饰符号对比度仍需人工判断。这些检查仅验证原型，不代表订阅采集或原生 App 已验收。

界面文案已同步精简：卡片只保留额度、重置、同步状态和操作；连接弹窗只保留目录、登录和状态栏授权。数据来源与跨设备同步说明放入详情，不在卡片重复。

未完成：真实 Pro / Max 首个额度样本与官方页面同时间核对、两个真实账号隔离、任意原状态栏 TTY/超时兼容、外部同目录换登录的可靠身份识别、PTY 面板采集、发布。所有 statusLine 安装测试都在临时目录，未安装到用户已有真实配置。当前不能将功能实现描述为真实订阅全链路已验收。

搜索工具：OpenCLI Gemini 首次查询因 Browser Bridge 未连接失败（1次）；按技能停止修复与重试。web 搜索两次返回工具级 404。后续使用官方站点直读和 GitHub 源码，不采用 AI 搜索摘要作证据。

## 11. 用量记录与调用分析（已实现）

### 数据口径

- **订阅额度**：仍由 `claude-subscription` 的官方 Code statusLine 快照提供，不用 Token 反算额度。
- **用量统计**：`claude` 合并 Gateway 代理归档与 Code JSONL 的非代理 Token。非代理包含订阅及其他直连，不根据模型名推断套餐或真实账号。
- **费用**：只计 Gateway 请求时冻结的费用。非代理不估价、不标为免费，不使用 Code 的本地 `$cost` 作为订阅账单。
- **调用分析**：统计 Code 工具、MCP、Skill 和子代理调用；不伪造直连 HTTP 日志、TTFT 或网络成功率，不宣称覆盖网页/Desktop 的直连请求。

### 采集、去重与历史

`ClaudeLogDirectoryResolver` 统一发现默认/环境配置目录及已连接订阅目录。Token、调用分析与技能/MCP 清单使用相同目录集合；canonical path 去重，支持嵌套 subagents 日志。连接新目录后自动补采历史，不要求修改 App 的环境变量，也不只扫当前选择的账号。

Token 按 `message.id` 归档，同一响应重复内容块和流式补齐按各 Token 分量取最大值，不逐行相加；原始时间用于按当前时区分日。Gateway 的转换/透传、流式/非流式路径记录客户端实际收到的 `response_message_id`，App 保存到代理归档，JSONL 中的同响应只计代理一次。模型别名或上游模型不同不影响去重。

代理日志在节点删除、清空及过期裁剪前冻结最小聚合与请求身份。日桶的 `models` 包含完整历史总量；`retainedModels` / `retainedRequestIds` 只用于后续重算和恢复日志去重，不在读取侧再次相加。费用、Token、响应 ID、surface/session 维度保留，重复刷新和恢复旧分片不重复加账；旧 v1 桶的可选冻结字段默认为空。

旧代理归档缺少响应标识和时区时，以事件在 UTC−12 至 UTC+14 的候选日期核对旧日键。可能重叠的 JSONL Token 保留为“来源待确认”，不计入合计；不按模型名或 Token 大小猜测。代理归档不可读时采集报错，不退化成把全部日志当作直连。

Token 账本 `claude-token-ledger-v1.json` 保存响应标识、时间、模型、输入/输出/缓存 Token；调用账本沿用 `claude-call-ledger-v1.json` 路径、schema 升至 2，保存工具事件 ID、会话身份、绝对时间、类别、名称、agent 与结果。缺少稳定会话 ID 时用文件路径哈希维持裁剪后的会话归属。两者不保存正文、工具参数、登录凭证或费率。原子写入，文件权限 0600；删除日志后保留已采集数据。未被采集就删除的日志无法补回。

Token 与调用共用有界流式字段读取器：正文、图片和无关工具参数直接跳过；每行统计投影上限 1 MB、单个统计字符串上限 16 KB，超限或异常行明确报部分采集，并保留重试机会。追加时核对 inode、尺寸及已读边界后只读增量；裁剪、替换或边界变化回到开头。游标只放内存，重启从源日志核对身份，不以已读位置替代永久记录。行级释放临时对象，不随大文件累计解析内存。

工具调用按 ID 跨文件去重；迟到结果和 agent 类型只更新同一事件；日期按当前时区计算。子代理不与沿用父 sessionId 的其他子代理合并。旧聚合没有事件 ID，迁移前历史与旧计数动态保守协调，迁移后新调用独立累加；保留的无身份残差显示“旧记录待确认”，不计算其成功率或耗时。迁移失败不清除旧记录。Codex、OpenCode 的归档策略保持原样。

### 页面与验收

用量统计的 Claude 页增加“合计 / 代理 / 非代理”；摘要、模型明细、趋势和热力图使用同一轨道。非代理页隐藏费用，合计页的费用标为“代理费用”；待确认历史单独提示，不混入合计。调用分析继续使用已有 Claude Code 来源，不增加页面。

隔离原生界面核对：合计 274K Token = 代理 34K + 非代理 240K；代理费用为 $1.25，非代理页没有费用卡或费用切换器，模型费用显示为“—”；调用分析显示 2 次测试调用（含 1 次 Skill）。这些均为合成数据，不是真实订阅账单或采集验收。正式应用及其代理进程未停止，测试使用独立 Bundle ID 与临时 HOME。

本轮 91 项定向测试通过，无失败或跳过；macOS Debug 构建通过。测试覆盖 Token 重复/流式补齐、缓存拆分、模型别名去重、旧归档待确认、删除后重启保留、新目录历史补采、调用残差迁移、重复 tool_use 与迟到结果、时区变更，以及既有订阅、Codex、OpenCode 和代理 HTTP 回归。真实 Pro / Max 额度对照及发布仍未完成。

2026-10-06 发布前优化：此前审查发现的六项缺陷已修复；新增 13 项边界测试后全量 348 项通过、账号身份 67 项断言通过。当时的 Release 构建与性能数据记录在已归档的 `docs/CLAUDE_RELEASE_AUDIT_2026-10-06.md`，可用 `git log -- docs/CLAUDE_RELEASE_AUDIT_2026-10-06.md` 找回。测试使用合成日志、隔离 HOME 和临时 Bundle ID，未切换真实账号或发布。

同日复审修复：防止 profile 元数据丢失后的 wrapper 递归，已有可读备份则恢复串接，否则保持设置不变；helper 拒绝执行递归回传原命令。删除与清理后的代理历史保留，并纳入永久回归。全量 351 项及 67 项身份断言通过；发布 CI 已配置对最终 ZIP 解压 helper 运行订阅测试，本地 12 项全部执行通过。未发布，真实额度与双账号验收仍待完成。

## 来源

以下资料均于本轮在线读取。官方资料约束产品语义；开源源码只证明对应实现和观察到的合同。

- **S1** [Use Claude Code with your Pro or Max plan](https://support.claude.com/en/articles/11145838-using-claude-code-with-your-pro-or-max-plan)
- **S2** [How do usage and length limits work?](https://support.claude.com/en/articles/11647753-understanding-usage-and-length-limits)
- **S3** [Claude Code statusLine：Available data / Rate limit usage / Update behavior](https://code.claude.com/docs/en/statusline)
- **S4** [Legal and compliance：Authentication and credential use](https://code.claude.com/docs/en/legal-and-compliance)
- **S5** [Manage usage credits for paid Claude plans](https://support.claude.com/en/articles/12429409-extra-usage-for-paid-claude-plans)
- **S6** [Usage and Cost Admin API](https://platform.claude.com/docs/en/build-with-claude/usage-cost-api)
- **S7** [CodexBar Claude 文档（固定提交）](https://github.com/steipete/CodexBar/blob/6a26b2e9b1b60471970deb6fe663f9e5f284e2ce/docs/claude.md)，[OAuthUsageFetcher](https://github.com/steipete/CodexBar/blob/6a26b2e9b1b60471970deb6fe663f9e5f284e2ce/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageFetcher.swift)，[ClaudeStatusProbe](https://github.com/steipete/CodexBar/blob/6a26b2e9b1b60471970deb6fe663f9e5f284e2ce/Sources/CodexBarCore/Providers/Claude/ClaudeStatusProbe.swift)
- **S8** [CodexBar WebAPIFetcher](https://github.com/steipete/CodexBar/blob/6a26b2e9b1b60471970deb6fe663f9e5f284e2ce/Sources/CodexBarCore/Providers/Claude/ClaudeWeb/ClaudeWebAPIFetcher.swift)，[ClaudeUsageFetcher 金额映射](https://github.com/steipete/CodexBar/blob/6a26b2e9b1b60471970deb6fe663f9e5f284e2ce/Sources/CodexBarCore/Providers/Claude/ClaudeUsageFetcher.swift)
- **S9** [Claude Code commands](https://code.claude.com/docs/en/commands)
- **S10** [Manage costs：Background token usage / Plan usage breakdown](https://code.claude.com/docs/en/costs)
- **S11** [Authentication：Multi-account / Long-lived token / Precedence](https://code.claude.com/docs/en/authentication)
- **S12** [CLI reference：settings / auth status](https://code.claude.com/docs/en/cli-reference)
- **S13** [Settings：scope / precedence](https://code.claude.com/docs/en/settings)

交互设计：[claude-subscription-monitor.html](design/claude-subscription-monitor.html)。该页面只模拟状态与交互，不执行登录、配置修改、CLI 命令或网络接口请求。

## 12. 连接体验重设计（2026-10-06）

起因：实测连接失败——「启动 Code」打开终端；终端登录成功后 AIUsage 无反应；连接页要求填写名称与目录。本节取代第 5、7 节中与之冲突的描述。

根因（均已在真实 CLI 2.1.289 上复现）：

- **显式设置 `CLAUDE_CONFIG_DIR` 会切换到另一份登录凭证，即使路径就是默认的 `~/.claude`。** 旧流程对默认目录也设置了该变量：已登录 Pro 的用户被判为「未登录」，终端里的 Code 要求重新登录，登录写进了另一份凭证，AIUsage 永远等不到数据。默认目录现在一律不设置（并清除继承值）。
- 默认目标是新目录 `~/.claude-aiusage/personal`：用户平时的 `claude` 不会使用它，额度只能经由 AIUsage 打开的终端产生。
- 登录为「打开终端后不再跟进」，没有完成检测。
- `auth status --json` 实际返回 `email`、`orgName`、`subscriptionType`，第 5 节「本机无邮箱/套餐」的结论已过时。

现行流程：

1. 打开连接页即检测默认 Claude Code：已登录 Pro / Max → 显示邮箱与套餐，一键「连接」（按钮即同意修改 statusLine，说明紧邻按钮）。无名称、目录、勾选框。
2. 未登录 → 「使用 Claude 登录」：后台 `script` 伪终端运行官方 `claude auth login`，经 `$BROWSER` 拿到可自动回调的授权链接，由 AIUsage 打开一次；CLI 退出或 `auth status` 确认后自动连接并回到 AIUsage。终端打印的是手动授权码链接，仅作 3 秒后的兜底，并自动展开授权码输入框。
3. 连接后实时监听快照目录：已有 Code 会话时 statusLine 立即重跑，额度约 1 秒内出现在连接页与卡片；否则提示「发送任意一条消息」。目录 settings 指向 API 代理时直接说明代理会话不产生订阅额度。
4. 「添加其他账号」：AIUsage 生成独立目录并在浏览器登录；与已连接账号重复时撤销这次登录。独立账号在卡片菜单「复制终端命令」使用，AIUsage 不打开终端。
5. 移除「Code 启动账号」及所有「启动 Code」入口；卡片与 Codex 一致：标题 + 邮箱 + 套餐徽标，操作收进「⋯」（Claude 用量页 / 重新连接 / 停止同步）。启动时用 `auth status` 刷新邮箱与套餐。

验证：QuotaBackend 353 项通过、0 跳过（含 App 包内 helper）；账号身份 67 项断言通过；真实 CLI 驱动正式 `ClaudeLoginCoordinator`（仅替换打开浏览器/激活窗口两处副作用）拿到 localhost 回调链接、只打开一次、取消后无残留进程与临时目录；默认目录在继承 `CLAUDE_CONFIG_DIR` 与代理变量时仍识别为 Pro。浏览器授权完成后的自动连接和真实额度回传需用户在 App 中验收。
