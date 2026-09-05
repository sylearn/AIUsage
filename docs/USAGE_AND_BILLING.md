# 用量与计费统计说明

本文说明 AIUsage 里 Claude Code 与 Codex 两类本地用量统计的真实数据源、token 口径、计费口径、归档规则和已知限制。

## 总原则

- 代理请求发生时就冻结成本：App 根据当时节点里的模型价格计算 `estimatedCostUSD`，之后统计层只汇总，不按新价格回溯改历史。
- token breakdown 保持分字段：`input`、`output`、`cacheRead`、`cacheCreate` 不互相合并。计费时 `input` 必须是 non-cached input，缓存读取只走 `cacheRead` 价格。
- 短期明细和永久统计分离：`proxy-logs` 是可裁剪的请求明细，`usage-archive` 是统计页和热力图的事实源。
- 清空日志只清明细，不清永久归档。删除节点前也会先把当前内存日志折叠入永久归档，避免历史统计丢失。

## Claude Code

Claude Code 用量统计只读取 AIUsage 代理用量归档：

```text
~/.config/aiusage/usage-archive/proxy-usage-claude-v1.json
```

Claude Provider 不再扫描 Claude Code JSONL。本项目只统计经过 AIUsage Claude 代理的请求，包括 OpenAI Proxy 模式和 Anthropic Passthrough 模式。

字段含义：

- `inputTokens`: 普通输入 token。
- `outputTokens`: 输出 token。
- `cacheReadTokens`: 缓存读取 token。
- `cacheCreateTokens`: 缓存写入 token。
- `costUSD`: 请求发生时按节点定价冻结后的美元成本。
- `pricingResolvedRequests`: 该模型当天有多少请求在发生时找到了定价；用于区分“未配置价格”和“价格刻意配置为 0”。

Claude/Anthropic 的 usage 语义里 `input_tokens`、`cache_read_input_tokens`、`cache_creation_input_tokens` 是独立字段，不是 OpenAI Responses 那种 `cached_tokens` 嵌在 `input_tokens` 里的子集。因此 Claude 这里不存在“缓存读取被并入输入再计费一次”的 double count 问题。

## Codex

Codex 统计是双轨合并。

### 代理轨 Proxy

数据源：

```text
~/.config/aiusage/usage-archive/proxy-usage-codex-v1.json
```

这条轨道只来自 AIUsage Codex 代理请求。成本在请求发生时按节点定价冻结，模型名在统计层加 ` (Proxy)` 后缀。归档同时保存每个请求的 Codex `session-id` / `thread-id`、日期、请求模型与 token 明细，供 JSONL 扫描精确去重。

OpenAI Responses 的 `input_tokens_details.cached_tokens` 是 `input_tokens` 的子集。AIUsage 代理在写日志前会规范化：

```text
inputTokens = max(input_tokens - cached_tokens, 0)
cacheReadTokens = min(cached_tokens, input_tokens)
```

所以代理成本不会把 cached input 同时按 input 和 cache read 两种价格计费。

### 非代理轨 Non-Proxy

数据源：

```text
~/.codex/sessions/**/*.jsonl
~/.codex/archived_sessions/**/*.jsonl
~/.config/aiusage/usage-archive/codex-non-proxy-usage-v1.json
```

账号和 AIUsage API 都使用内置 `openai` provider，所以同一会话可以混合两种来源。非代理轨按「JSONL token 总量 − 同会话/日期/模型的代理归档覆盖」计算；剩余部分包括 Codex 订阅账号和第三方直连，只统计 token、成本恒为 0，模型名加 ` (Non-Proxy)` 后缀。今天的数据会随 JSONL 重算；今天之前的数据会冻结进 `codex-non-proxy-usage-v1.json`，删除本地 JSONL 后历史 token 不丢。

AIUsage 启动时会把自己旧版本写入的 `model_provider = aiusage-proxy` 会话元数据原位迁移为 `openai`。迁移 journal 保留时间截点，截点前已由代理归档负责的 JSONL 行仍会被排除；其它第三方 provider 不会被改写。

旧路径 `codex-subscription-usage-v1.json` 会读取并迁移到新非代理归档。旧模型后缀 ` (Sub)` 会迁移为 ` (Non-Proxy)`，旧 ` (API)` 行会丢弃，避免把代理历史误放进非代理轨。

## OpenCode

OpenCode 是双源合并，两源互斥、不双计：

### 直连 / 路线 B（opencode.db）

数据源：

```text
~/.local/share/opencode/opencode.db
```

OpenCode 自 v1.2 起把每条 assistant 消息连同 token 明细与按 [models.dev](https://models.dev) 定价预计算的 `cost` 写入本地 SQLite。直连节点与「路线 B 每节点透传代理」的请求都落在这里，按消息 `providerID` 归因到节点（受管键恒为 `aiusage-<slug>`）。成本直接采用 db 的冻结 `cost`，与统计页同口径。

路线 B 的代理日志**仅作观测**（成功/失败计数与失败明细），不参与计费——计费以 db 为准，避免代理旁路与 db 账本双计。

### 全局统一代理（代理日志归档）

数据源：

```text
~/.config/aiusage/usage-archive/proxy-usage-opencode-v1.json   # 热力图 / 用量统计（按天 × 真实上游模型聚合）
~/.config/aiusage/opencode-global-usage.json                   # 节点卡片用（按节点永久累计）
```

全局统一代理是常驻固定端口、随激活节点热切换的单进程，对 CLI 暴露固定虚拟模型名（见 OPENCODE_INTEGRATION_DESIGN.md §12）。它接管 `opencode.json` 时注入裸 `aiusage` 受管 provider，因此这部分流量在 db 里记在 `providerID = "aiusage"` 名下——该 provider 被 `OpenCodeCostProvider` 与 `OpenCodeNodeStatsFetcher` **双双排除**，改由代理日志计费，杜绝双计。

口径与 Codex/Claude 代理轨一致：

- 成本在请求发生时按**激活节点**定价冻结（`PROXY_LOG → ProxyRequestLog.estimatedCostUSD`），改价不回溯历史。
- token 分字段 `input/output/cacheRead/cacheCreate`，`input` 为非缓存输入。
- 归因到日志携带的真实 `node_id` + 真实上游模型；**归档模型键与 db 完全一致**（`aiusage-<slug>/<model>`），故同节点同模型经「全局代理」与「直连/路线 B」两条路径在热力图/用量统计**合并为一行**，不再拆分。
- 节点卡片（请求数/费用/统计网格/最近请求）= db 直连归因 **+** 全局代理永久累计两源相加，故大部分时间走全局代理时，每个节点的用量与费用依然持续更新。

### 模型名展示口径

OpenCode 受管节点的模型键带内部归因前缀 `aiusage-<slug>/<model>`（`aiusage-` 是注入 `opencode.json` 的归因标记，数据键保留以做节点归因 + 跨路径合并）。**展示层统一剥掉 `aiusage-` 前缀**（`StatsDataAdapter.displayModelLabel`），热力图 tooltip / 模型分布 / 模型详情显示为 `<slug>/<model>`。非受管的第三方 provider（如用户自配的 `deepseek/...`）不带前缀，原样展示。

### 已知限制（OpenCode 专属）

- 全局代理归档自功能启用起累积，启用前无历史可回填（同 Claude/Codex 代理轨）。
- 同节点同模型已按 `aiusage-<slug>/<model>` 合并；不同节点（不同 slug）的同名模型仍按节点分行，保留归因。
- 未计价节点（节点编辑器未填单价）的全局代理请求成本记 0，提示用户补单价后新请求才有金额。

## UI 口径

统计页和热力图使用 `UsageTrack`：

- `Combined`: 合计。Codex token = Proxy + Non-Proxy，成本 = Proxy 成本。
- `Proxy`: 只看代理轨，展示费用和 token。
- `Non-Proxy`: 只看非代理轨，只展示 token，费用相关 UI 隐藏。

模型 breakdown、timeline、热力图 tooltip 都保留 input/output/cacheRead/cacheCreate。单轨展示时会剥离 ` (Proxy)` / ` (Non-Proxy)` 后缀，只在需要区分来源时保留轨道标签。

## 未定价提示

未定价提示只看今天，避免历史 0 成本模型永久干扰。

- 若代理请求发生时没有找到模型定价，且今天仍有 token，用量卡片会提示未定价模型。
- 若用户主动把模型价格配置为 0，新日志会记录 `pricingResolvedRequests`，不会再被误报为未定价。
- 旧归档没有 `pricingResolvedRequests` 字段时，只能按旧规则兼容：`costUSD == 0 && token > 0` 会被视为可能未定价。

## 已知限制

- AIUsage 是本地用量账本，不是官方账单。官方平台可能有折扣、阶梯价、免费额度、税费或舍入规则，本项目不会替代官方账单。
- 代理成本冻结后不会因改价自动重算历史。补充缺失定价只会回填仍在本地保留期内、且请求发生时未解析定价的明细。
- 代理永久归档自功能启用后累积。已被裁剪且从未折叠入归档的更早明细无法恢复。
- 非代理 Codex 没有账号级计费信息，本项目只做 token 统计，不估算订阅或第三方直连成本。
