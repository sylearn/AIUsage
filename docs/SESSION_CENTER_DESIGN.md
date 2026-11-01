# 会话中心 · 设计与实现

> 状态：v1 实现中（分支 `feat/session-center`）
> 范围：Claude Code、Codex、OpenCode 三个 CLI 的本地会话浏览、阅读与一键继续
> 交互稿：<https://claude.ai/artifact/XntbutQ6BzjyN6Cm87FtUf>（主窗口 + 菜单栏两个画板）

## 1. 要解决的问题

三个编程 CLI 都把对话存在本机，但各自只提供命令行里的会话选择器：看不到完整内容，跨工具也没法一起找。会话中心把三家的历史会话放进同一个界面：

- 按标题、目录、分支、会话 ID 和提问内容搜索，按工具筛选，按时间或项目分组；
- 读一段会话时，工具调用折叠成一行摘要（几步、读改了几个文件、失败几次），失败步骤高亮；
- 一键在终端里继续对话，或者复制恢复命令；
- 菜单栏里直接列出最近会话，不打开主窗口也能继续。

**非目标（v1）**：不删除、不改写任何会话文件；不做全量正文索引；不支持 Hermes、Gemini CLI 等其他工具；不实时跟随正在进行的会话。

## 2. 数据来源（基于 2026-11-01 本机实测）

| | Claude Code 2.1.x | Codex CLI 0.135 | OpenCode |
|---|---|---|---|
| 根目录 | `$CLAUDE_CONFIG_DIR` 或 `~/.claude` | `$CODEX_HOME` 或 `~/.codex` | `$XDG_DATA_HOME/opencode`、`~/.local/share/opencode`、`~/Library/Application Support/opencode` |
| 会话列表 | `projects/<编码后的目录>/<uuid>.jsonl`（只认第二层） | `state_<N>.sqlite` 的 `threads` 表 | 旧版：`storage/session/<project>/<id>.json`；新版：`opencode.db` |
| 标题 | 最后一条 `custom-title` > 最后一条 `ai-title` > 旧版 `summary` > 第一句提问 | `name`（用户改名）> `title` > `first_user_message` | `title` |
| 正文 | 同一个 JSONL | `thread_history_<N>.sqlite` 的 `thread_items` | 旧版：`storage/message`、`storage/part`；新版：`message`/`part` 或 `session_message`/`session_part` 表 |
| 继续命令 | `cd <cwd> && claude --resume <uuid>` | `cd <cwd> && codex resume <uuid>` | `cd <dir> && opencode --session <ses_id>` |

实测细节与由此定下的规则：

- **Claude Code**：一个会话文件里有十几种记录类型（`user`、`assistant`、`ai-title`、`last-prompt`、`pr-link`、`api-request` 等）。`ai-title` 会随对话多次更新，取最后一条。用户消息分四种：普通提问（字符串或 `text` 块）、斜杠命令（`<command-name>` 包裹）、系统注入（`isMeta: true`）、工具结果（`tool_result` 块）。只有前两种算作一轮提问；`<system-reminder>` 片段从正文里去掉。`isSidechain: true` 的记录属于子代理，不进入主时间线。项目目录下的 `memory/`、`<uuid>/tool-results/` 等子目录不是会话。Claude Code 默认只保留 30 天会话（`settings.json` 的 `cleanupPeriodDays` 可调），会话中心只能显示磁盘上还在的记录。
- **Codex**：本机 175 条会话里，169 条的会话文件已被 Codex 压缩成 `.jsonl.zst`，而 `threads.rollout_path` 仍写着 `.jsonl`。判断能否继续时两种后缀都要认。正文不解析会话文件：`thread_history_1.sqlite` 已经把 153 条会话展开成结构化条目（`userMessage`、`agentMessage`、`commandExecution` 带 `exitCode`、`fileChange` 带路径、`mcpToolCall`、`webSearch` 等），状态只有 `completed` / `failed`。剩下 22 条只有压缩包，界面提示「无法预览，仍可继续」。`source` 里带 `subagent` 的线程（如 guardian 审查）不列出；已归档（`archived = 1`）的 v1 不列出。数据库文件名带版本号，按数字取最大的 `state_*.sqlite` / `thread_history_*.sqlite`，列用 `PRAGMA table_info` 探测，缺列只影响对应字段。
- **OpenCode**：本机是旧版 JSON 存储（7 个会话）。新版 `opencode.db` 有两代表结构：已发布的 `session`/`message`/`part`，以及开发分支里的 `session_v2`/`session_message`/`session_part`。两代都按列探测读取，`parent_id` 非空的子会话不列出。JSON 与数据库同时存在时（升级迁移后的残留），同一个会话 ID 以数据库为准。本机没有数据库样本，数据库路径只用按源码表结构构造的测试库验证过。

## 3. 架构

```
QuotaBackend/Sources/QuotaBackend/Sessions/      纯数据层，无 UI 依赖，可单测
  SessionModels.swift          SessionTool / SessionSummary / SessionTranscript / ToolStep
  SessionCatalog.swift         汇总三个来源，增量缓存，排序，搜索
  ClaudeSessionSource.swift    JSONL 扫描与解析
  CodexSessionSource.swift     state / thread_history 两个 SQLite
  OpenCodeSessionSource.swift  JSON 存储与 opencode.db
  SessionSQLite.swift          只读 SQLite 小工具（按列名取值、列探测）
  SessionResumePlan.swift      继续命令与启动脚本（ID 校验、shell 转义）
  SessionMarkdownExporter.swift 导出 Markdown

AIUsage/
  ViewModels/SessionCenterStore.swift     @MainActor 状态：列表、筛选、选中、正文加载、继续
  Services/TerminalLauncher.swift          终端探测与启动
  Views/SessionCenterView*.swift           主窗口：列表 / 阅读视图 / 大纲
  Views/MenuBarRecentSessions.swift        菜单栏「最近会话」
```

数据流：视图出现或手动刷新 → `SessionCenterStore.refresh()` → 后台线程 `SessionCatalog.scan()`（三个来源并行）→ 主线程发布 `[SessionSummary]`。选中某个会话 → 后台加载 `SessionTranscript`（按会话缓存最近 8 份）→ 阅读视图渲染。

### 3.1 增量扫描

- Claude：只对 `(路径, 修改时间, 大小)` 变化的文件重新解析，其余复用上次结果。列表解析是流式逐行读，不把整份文件读进内存；单行超过 4 MB 的记录（大块工具输出）直接跳过。
- Codex / OpenCode 数据库：数据库文件和 `-wal` 文件的修改时间都没变就复用上次结果。以只读模式打开，不复制快照，不加锁。
- 缓存只在内存里，不落盘：会话正文不会被复制到 AIUsage 自己的目录。

### 3.2 搜索

每个会话在扫描时生成一段搜索文本：标题、目录、分支、会话 ID，再加上全部提问（总长截断到 8 KB）。搜索不区分大小写，多个关键词之间是「且」。助手回复不进搜索文本，避免内存随会话量线性膨胀（见第 8 节后续方向）。

### 3.3 正文归一化

三家的记录统一成四种条目：

| 条目 | 来源 |
|---|---|
| 提问 | Claude 普通提问 / 斜杠命令；Codex `userMessage`；OpenCode user 消息的 text 部分 |
| 回复 | Claude `text` 块；Codex `agentMessage`；OpenCode assistant 消息的 text 部分 |
| 步骤组 | 两次文字之间的连续工具调用合成一组 |
| 提示 | 上下文压缩、用户中断等 |

思考过程（Claude `thinking`、Codex `reasoning`）v1 不显示。每个步骤记录名称、一行说明（文件路径、命令、搜索词或 MCP 工具名）、成功或失败，以及失败原因的第一行。失败判定：Claude `tool_result.is_error`；Codex `status == failed` 或 `exitCode != 0`；OpenCode `state.status == error`。读改文件的统计按工具名归类（Read / Edit / Write / apply_patch / fileChange 等）。

单条文字超过 20 000 字时截断并注明；一份会话最多渲染最近 3 000 个条目，更早的部分提示「已省略」。

## 4. 继续对话

### 4.1 命令构造

会话 ID 先按工具校验格式（Claude、Codex 为 UUID，OpenCode 为 `ses_` 加字母数字），不合格就拒绝，杜绝命令注入。目录和 ID 都用单引号转义后写进脚本。Claude 必须在原项目目录下恢复（会话按目录存放），目录不存在时直接提示，不启动终端。

### 4.2 启动脚本

在 `~/Library/Caches/AIUsage/resume/` 生成一次性的 `.command` 脚本（目录 0700，文件 0700）：

```sh
#!/bin/zsh -il
rm -f -- "$0"
cd -- '/path/to/project' || exit 1
claude --resume '4f2a91c3-…'
exec "${SHELL:-/bin/zsh}" -l
```

- 用交互式登录 shell 运行，和用户自己打开终端时的 PATH、环境变量一致；用户 shell 是 bash 时用 `#!/bin/bash -il`，其他 shell 退回 zsh。
- 脚本启动后先删除自己；App 启动时再清理一天前残留的脚本。
- CLI 退出后留在项目目录的 shell 里，窗口不会一闪而过。

### 4.3 终端

| 终端 | 启动方式 | 说明 |
|---|---|---|
| Ghostty | `NSWorkspace.openApplication`，新实例，参数 `-e <脚本>` | 等价于官方推荐的 `open -na Ghostty.app --args -e …`；macOS 上 Ghostty 不支持直接从命令行启动 |
| 终端（Terminal.app） | `NSWorkspace.open(脚本, withApplicationAt:)` | 系统原生支持 `.command` |
| Warp | 实测后确定，见第 7 节 | |

全程不用 AppleScript：App 开着 Hardened Runtime，发送 Apple Events 需要额外的 entitlement 和自动化授权弹窗。默认终端按 Ghostty → Warp → 终端 的顺序取第一个已安装的，用户在「继续」按钮的下拉菜单里改，选择会记住。启动失败时自动把命令复制到剪贴板并提示。

## 5. 界面

- **入口**：侧边栏「仪表盘」下方的「会话」，可在设置里隐藏（与其他入口一致）。
- **列表**：搜索框（⌘F）、工具筛选（全部 / Claude Code / Codex / OpenCode，带数量）、分组（按时间：置顶、今天、昨天、本周、更早；按项目）。行内显示品牌图标、两行标题、项目名与分支、时间 · 轮数 · token。悬停出现「继续」按钮；右键菜单有继续、复制命令、复制会话 ID、在 Finder 中显示。↑↓ 选择，↩ 继续。
- **阅读视图**：顶部是工具、会话 ID、标题和元信息标签（目录、分支、模型、轮数与 token、更新时间），右上角是复制命令、在 Finder 中显示、导出 Markdown 和「在 Ghostty 中继续」（带终端选择）。正文提问靠右、回复靠左，步骤组默认折叠，有失败的组默认展开并用橙色标出。
- **大纲**：窗口足够宽时显示在右侧，列出每一轮提问，点击跳转；底部是轮数、工具调用、改动文件、失败次数四个统计。
- **菜单栏**：额度区下方的「最近会话」，最多 4 条，可折叠（状态记住），点行打开会话中心并选中，点右侧按钮直接继续。
- 浅色、深色两种外观都使用 `AppSurfaceTokens` 里的色阶；品牌色只用在图标上。

## 6. 隐私与安全

- 只读：不写、不删、不移动三家的任何文件；SQLite 以 `SQLITE_OPEN_READONLY` 打开。
- 不联网，不上传，正文不落盘（除非用户主动导出 Markdown）。
- 唯一的写入是一次性启动脚本，权限 0700，执行后自删。

## 7. 测试

- `QuotaBackend/Tests/QuotaBackendTests/SessionCatalogTests.swift`：用脱敏样本覆盖三家的列表与正文解析——Claude 标题优先级、meta/命令/工具结果区分、子代理过滤、失败步骤；Codex 列探测、子代理与归档过滤、`.zst` 识别、条目映射；OpenCode JSON 存储与两代数据库表结构、子会话过滤、去重。
- 继续命令：ID 校验、单引号转义（含 `'` 的路径）、各工具参数。
- Markdown 导出：结构与转义。
- 真机验证：本机三家真实数据的扫描耗时与数量；Ghostty、终端、Warp 三种启动各实测一次；浅色、深色截图核对。

## 8. 后续优化与拓展

按价值排序：

1. **正文全文搜索**：用 SQLite FTS5 在 `~/Library/Caches/AIUsage` 建可删除的索引，覆盖助手回复与工具输出；需要设置开关并说明会在本地保存一份正文索引。
2. **实时更新**：用 FSEvents 监听三个根目录，替代「出现时刷新 + 手动刷新」；正在进行的会话在列表里显示「进行中」。
3. **更多工具**：Gemini CLI（`~/.gemini/tmp/*/chats`）、Hermes、Cursor Agent；来源协议已按「列表 + 正文 + 继续命令」三件事抽象，新增一家只需一个 Source 文件。
4. **更多终端**：iTerm2（需要 Apple Events entitlement 与自动化授权）、Kitty、WezTerm（都有 CLI，可用 `open -na … --args`）；终端新标签页而非新窗口。
5. **分支续写**：Claude `--fork-session`、OpenCode `--fork`，在原会话基础上开新会话，不污染原记录。
6. **会话管理**：归档会话的显示开关；移到废纸篓（只对 Claude/OpenCode 的文件型存储，带撤销）；置顶与重命名（写 AIUsage 自己的元数据，不改原文件）。
7. **统计联动**：在阅读视图显示本会话的 token 与费用（复用用量统计的计价表），从用量统计页跳到对应会话。
8. **思考过程与图片**：可选显示 thinking/reasoning 摘要，内联显示截图类附件。
9. **Codex 压缩会话预览**：引入 zstd 解码（体积约 300 KB）后，可预览只有 `.jsonl.zst` 的 22 条会话。
10. **全局快捷键**：⌥⌘S 唤出最近会话浮窗。
