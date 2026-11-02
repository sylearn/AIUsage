# 会话中心 · 设计与实现

> 状态：v1 已实现（`feat/session-center`）；v1.1 加入全文搜索与实时更新（`feat/session-search-live`）
> 范围：Claude Code、Codex、OpenCode 三个 CLI 的本地会话浏览、阅读与一键继续
> 交互稿：<https://claude.ai/artifact/XntbutQ6BzjyN6Cm87FtUf>（主窗口 + 菜单栏两个画板）

## 1. 要解决的问题

三个编程 CLI 都把对话存在本机，但各自只提供命令行里的会话选择器：看不到完整内容，跨工具也没法一起找。会话中心把三家的历史会话放进同一个界面：

- 按标题、目录、分支、会话 ID 和提问内容搜索，按工具筛选，按时间或项目分组；开启全文搜索后也能搜回复和工具调用；
- 页面开着时跟着原工具的文件实时更新，正在进行的会话标出「进行中」；
- 读一段会话时，工具调用折叠成一行摘要（几步、读改了几个文件、失败几次），失败步骤高亮；
- 一键在终端里继续对话，或者复制恢复命令；
- 菜单栏里直接列出最近会话，不打开主窗口也能继续。

**非目标**：不删除、不改写任何会话文件；不支持 Hermes、Gemini CLI 等其他工具；不把工具的原始输出（文件内容、命令输出）放进搜索。

## 2. 数据来源（基于 2026-11-01 本机实测）

| | Claude Code 2.1.x | Codex CLI 0.135 | OpenCode |
|---|---|---|---|
| 根目录 | `$CLAUDE_CONFIG_DIR` 或 `~/.claude` | `$CODEX_HOME` 或 `~/.codex` | `$XDG_DATA_HOME/opencode`、`~/.local/share/opencode`、`~/Library/Application Support/opencode` |
| 会话列表 | `projects/<编码后的目录>/<uuid>.jsonl`（只认第二层） | `state_<N>.sqlite` 的 `threads` 表 | 旧版：`storage/session/<project>/<id>.json`；新版：`opencode.db` |
| 标题 | 最后一条 `custom-title` > 最后一条 `ai-title` > 旧版 `summary` > 第一句提问 | `name`（用户改名）> `title` > `first_user_message` | `title` |
| 正文 | 同一个 JSONL | `thread_history_<N>.sqlite` 的 `thread_items` | 旧版：`storage/message`、`storage/part`；新版：`message`/`part` 或 `session_message`/`session_part` 表 |
| 继续命令 | `cd <cwd> && claude --resume <uuid>` | `cd <cwd> && codex resume <uuid>` | `cd <dir> && opencode --session <ses_id>` |
| 进行中 | `sessions/<pid>.json` 进程登记（2026-11-02 实测 2.1.316） | `thread_history` 的 `thread_turns.status` | 数据库 `message.data.time.completed` |

实测细节与由此定下的规则：

- **Claude Code**：一个会话文件里有十几种记录类型（`user`、`assistant`、`ai-title`、`last-prompt`、`pr-link`、`api-request` 等）。`ai-title` 会随对话多次更新，取最后一条。用户消息分四种：普通提问（字符串或 `text` 块）、斜杠命令（`<command-name>` 包裹）、系统注入（`isMeta: true`）、工具结果（`tool_result` 块）。只有前两种算作一轮提问；`<system-reminder>` 片段从正文里去掉，`<task-notification>`（后台任务完成时自动注入）、`<local-command-stdout>` 等输出不算提问。会话目录取文件里第一条 `cwd`：会话按开始时的目录存放，`--resume` 必须回到那里，中途 `cd` 不影响。`isSidechain: true` 的记录属于子代理，不进入主时间线。项目目录下的 `memory/`、`<uuid>/tool-results/` 等子目录不是会话。Claude Code 默认只保留 30 天会话（`settings.json` 的 `cleanupPeriodDays` 可调），会话中心只能显示磁盘上还在的记录。
- **Codex**：本机 175 条会话里，169 条的会话文件已被 Codex 压缩成 `.jsonl.zst`，而 `threads.rollout_path` 仍写着 `.jsonl`。判断能否继续时两种后缀都要认。正文不解析会话文件：`thread_history_1.sqlite` 已经把 153 条会话展开成结构化条目（`userMessage`、`agentMessage`、`commandExecution` 带 `exitCode`、`fileChange` 带路径、`mcpToolCall`、`webSearch` 等），状态只有 `completed` / `failed`。剩下 22 条只有压缩包，界面提示「无法预览，仍可继续」。`source` 里带 `subagent` 的线程（如 guardian 审查）不列出；已归档（`archived = 1`）的 v1 不列出。数据库文件名带版本号，按数字取最大的 `state_*.sqlite` / `thread_history_*.sqlite`，列用 `PRAGMA table_info` 探测，缺列只影响对应字段。`has_user_event` 列实测恒为 0，不能用来判断空线程，改为「没有第一句提问、历史库里也没有提问」才跳过。
- **OpenCode**：本机是旧版 JSON 存储（7 个会话）。新版 `opencode.db` 有两代表结构：已发布的 `session`/`message`/`part`，以及开发分支里的 `session_v2`/`session_message`/`session_part`。两代都按列探测读取，`parent_id` 非空的子会话不列出。JSON 与数据库同时存在时（升级迁移后的残留），同一个会话 ID 以数据库为准。本机没有数据库样本，数据库路径只用按源码表结构构造的测试库验证过。

## 3. 架构

```
QuotaBackend/Sources/QuotaBackend/Sessions/      纯数据层，无 UI 依赖，可单测
  SessionModels.swift          SessionTool / SessionSummary / SessionActivity / SessionTranscript / ToolStep
  SessionCatalog.swift         汇总三个来源，增量缓存，排序
  ClaudeSessionSource.swift    JSONL 扫描与解析（追加部分增量读取）
  ClaudeSessionRegistry.swift  Claude Code 进程登记 → 进行中
  SessionLineReader.swift      从指定偏移逐行读 JSONL，返回下次接着读的位置
  SessionSearchIndex.swift     全文索引（SQLite FTS5，可选）
  SessionSourceMonitor.swift   FSEvents 监听三家的数据目录
  CodexSessionSource.swift     state / thread_history 两个 SQLite
  OpenCodeSessionSource.swift  JSON 存储与 opencode.db
  SessionSQLite.swift          SQLite 小工具（原工具的库只读打开；可写连接只给全文索引）
  SessionResumePlan.swift      继续命令与启动脚本（ID 校验、shell 转义）
  SessionTerminal.swift        支持的终端与各自的启动方式
  SessionMarkdownExporter.swift 导出 Markdown

AIUsage/
  ViewModels/SessionCenterStore.swift     @MainActor 状态：列表、筛选、选中、正文加载、继续
  Services/TerminalLauncher.swift          终端显示名、安装检测与启动
  Views/SessionCenterView*.swift           主窗口：列表 / 阅读视图 / 大纲
  Views/MenuBarRecentSessions.swift        菜单栏「最近会话」
```

数据流：视图出现、文件变化或手动刷新 → `SessionCenterStore.refresh()` → 后台线程 `SessionCatalog.scan()`（三个来源并行）→ 主线程发布 `[SessionSummary]`（没变化不发布）。选中某个会话 → 后台加载 `SessionTranscript`（按会话缓存最近 8 份）→ 阅读视图渲染。开了全文搜索时，每次扫描后增量更新索引，搜索在后台跑。

### 3.1 增量扫描

- Claude：只对 `(路径, inode, 修改时间, 大小)` 变化的文件重新解析，其余复用上次结果。列表解析是流式逐行读，不把整份文件读进内存；单行超过 4 MB 的记录（大块工具输出）直接跳过。
- Claude 会话文件只会追加，所以变化的文件也不整份重读：记下上次读到的字节位置和累计状态（标题、提问数、usage 等），从那里接着读新增的行。inode 变了、文件变小，或停下的位置前一个字节不是换行或 `}`，才从头读。文件末尾没有换行的半行可能正写到一半，只有能解析成 JSON 才算读过，否则下次从行首重读。阅读视图对最近打开的 4 份会话也这样做（`TranscriptBuilder` 是值类型，整个留在内存里）。实测：14.7 MB 的会话整份解析约 0.25 秒，追加几行后只需毫秒级；会话进行中每隔一两秒变一次，整份重读会长期占用 10% 以上的 CPU。
- Codex 整库重读实测 30–60 ms（150 个线程），实时更新时直接重读，没有做增量。
- Codex / OpenCode 数据库：数据库文件和 `-wal` 文件的修改时间都没变就复用上次结果。以只读模式打开，不复制快照，不加锁。
- WAL 库的坑：Codex 退出时会删掉 `-wal` / `-shm`，库仍是 WAL 模式，而只读连接无权重建 `-shm`，直接打开会失败（实测：Codex 不在运行时列表为空）。`SessionSQLite` 先按 `mode=ro` 打开，读不了再退回 `immutable=1`；没有 `-wal` 就没有未落盘的内容，不会少读数据。有回归测试覆盖。
- 缓存只在内存里，不落盘：会话正文不会被复制到 AIUsage 自己的目录。

### 3.2 搜索

**列表信息搜索**（默认）：每个会话在扫描时生成一段搜索文本：标题、目录、分支、会话 ID，再加上全部提问（总长截断到 8 KB）。搜索不区分大小写，多个关键词之间是「且」。

**全文搜索**（`SessionSearchIndex`，用户确认后开启）：

- 位置：`~/Library/Caches/AIUsage/Sessions/search-index.sqlite`，目录 0700、文件 0600（先以 0600 建空文件，SQLite 的 -wal / -shm 沿用它的权限）。开启前弹窗说明会在本机建一份正文索引；关闭时整个删除；没开过也会在启动时删一次，清掉上次没删干净的残留。它只是缓存，被系统清理后会重建。
- 内容：阅读视图显示的东西，即提问、回复、工具步骤（名称、命令或路径、失败原因），每条正文一行，记下它在正文里的序号（`TranscriptItem.id`）。工具的原始输出不进索引：整份文件、命令输出会让索引膨胀数倍，常见词几乎命中每个会话，而且命中了也没法在阅读视图里指给用户看。
- 表结构：`items`（会话、序号、类型、文字）加 external content 的 FTS5 表 `items_fts`，用触发器同步；`sessions` 表记每个会话的版本（更新时间 + 提问数 + 是否有正文）。`PRAGMA user_version` 记表结构版本，对不上就删掉重建。
- 分词：trigram，中文没有空格也能按子串搜。不足 3 个字的词（「登录」「缓存」）trigram 索引用不上，退回 `LIKE` 逐行比对（转义 `%`、`_`）；实测几十 MB 正文也只要几毫秒。
- 更新：每次扫描后在后台按版本比对，只重建变了的会话；正在运行（`working`）的会话先不动，等它停下再索引，免得边写边重建；已不在列表里的会话删掉。每个会话一个事务；关闭全文搜索时在两个会话之间停下。
- 查询：每个词要么在列表信息里，要么在正文里（「app 缓存」可以一个词命中目录、一个词命中回复）。正文命中时返回最早命中的那一条，生成摘录：从命中词前 24 个字开始，退到最近的空格或中文标点之后（不认 `.` 和 `:`，免得拆开路径），压成一行并去掉 Markdown 的 `**` 和反引号。命中词已经在列表行上看得到（标题、项目、分支）时不给摘录。
- 界面：结果行下面显示摘录并高亮搜索词；点开后阅读视图滚到命中的那一条，按命中词在这条文字里的相对位置对齐视口（长回复末尾的命中也在屏幕上），步骤组里有命中时自动展开。已选中的会话换了搜索词或再点一次，也会重新滚过去。
- 实测（2026-11-02，163 个会话）：首次建索引 1.2 秒，索引 3.8 MB；没有变化时比对 0.2 ms；单次搜索 1–11 ms。「缓存」从只搜列表信息的 1 个结果变成 9 个。

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

### 3.4 实时更新

- `SessionSourceMonitor` 用 FSEvents（文件级事件，合并 1 秒内的变化）监听三家的数据目录，只认会话记录：Claude 的 `projects/<目录>/<id>.jsonl` 与 `sessions/*.json`，Codex 的 `state_*` / `thread_history_*`，OpenCode 的 `storage/session|message|part` 与 `opencode.db`。Codex 的日志库每秒都在写，Claude 的调试日志、`-shm` 共享内存文件（读库时也会变）一律过滤。
- 只在会话页或菜单栏「最近会话」可见时监听（`beginObserving` / `endObserving` 计数），都不可见就停掉，不在后台空转。有变化时距上次扫描不足 1.5 秒就等一等，期间的变化合并成一次扫描；扫描进行中又有变化，扫完再补一次。
- 根目录用 `realpath` 解开符号链接再比对：FSEvents 报告的是真实路径（`/private/var/…`），而 `URL.resolvingSymlinksInPath` 会特意去掉 `/private`，用它会让事件全部对不上（测试里踩到过）。目录不存在就不监听，每次扫描时顺手重新检查，工具装好后能自动接上。
- 页面可见时仍保留 30 秒一次的定时扫描兜底：进程崩溃、「进行中」过期不一定伴随文件变化。
- 阅读视图：同一个会话有新内容时，旧正文留到新的读完再换，不闪加载中，滚动位置也不跳；视图停在末尾时跟着新内容滚动。读失败（文件正写到一半）就保留旧正文，下次变化再读。实时扫描不显示进度圈，只有手动「重新扫描」显示。
- 实测（假 HOME 端到端）：追加一轮对话后 1.5 秒列表和阅读视图都更新；登记 / 移除进程后 1.5 秒「进行中」出现 / 消失；停止观察后不再扫描。

### 3.5 进行中

| | 判断依据 | 状态 |
|---|---|---|
| Claude Code | `<root>/sessions/<pid>.json` 登记了 `sessionId`、`status`、`procStart`。PID 还活着（`kill(pid, 0)`），且进程启动时间（`sysctl KERN_PROC_PID`）与 `procStart` 相差不超过 2 秒，防止 PID 被复用；这和 Claude Code 自己判断会话被谁占用的规则一致。`procStart` 实测是 UTC 的 ctime 格式（`Mon Nov  2 01:12:05 2026`），也接受本地时区。转入后台的会话（`parkedJobId`）不算 | `idle` 为「等待输入」，其余（`busy` 等）为「进行中」 |
| Codex | `thread_turns` 里线程最新一轮是 `inProgress`，且最后一次动静（轮次开始或最近一条条目）在 30 分钟内。实测本机有 4 条崩溃残留的 `inProgress` 轮次（最早是 6 月），时间窗口把它们排除 | 进行中 |
| OpenCode | 只看 v1 数据库：最后一条消息是没有 `time.completed` 的助手消息，且在 30 分钟内。旧版 JSON 存储原地改写消息文件、目录修改时间不变，扫描缓存看不到消息完成，会误报，不判断；v2 的完成标记还没有样本 | 进行中 |

「进行中」每次扫描现算，不进缓存：数据库没变，时间窗口也会按时过期。对进行中的会话点「继续」会先弹窗确认：再开一个进程，两边会同时写同一份记录。

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

支持 8 个终端，菜单里只列出已安装的。清单和启动方式定义在 `QuotaBackend/Sessions/SessionTerminal.swift`（可单测），App 侧只负责显示名、安装检测（废纸篓里的不算）和调用 `NSWorkspace`。两种启动方式：

- **打开脚本**：`NSWorkspace.open([脚本], withApplicationAt: 终端)`，在用户已运行的实例里开新窗口，沿用用户的配置。
- **新开进程**：`NSWorkspace.openApplication(at:)` 加 `createsNewApplicationInstance` 和启动参数，等价于 `open -na 终端 --args …`。WezTerm / Kaku 用 `start`：没在运行时由新进程开第一个窗口，已在运行时把命令转交给原实例后退出；kitty、Alacritty 是独立实例，窗口关掉后退出。只用于没有窗口恢复的终端。脚本路径包在 `/bin/sh -c "exec '…'"` 的字符串里，不单独作为参数：macOS 会把启动参数里现成的文件路径当成「打开文件」请求，Ghostty 1.3.1 就因此弹确认并卡住新实例。

| 终端 | 方式 | 执行前是否确认 | 依据（2026-11） |
|---|---|---|---|
| Ghostty 1.3.1 | 打开脚本 | 每次弹「Allow Ghostty to execute …?」 | 实测。Ghostty 对打开的文件一律确认（防止沙盒应用借道执行） |
| iTerm2 3.7.4 | 打开脚本 | 弹「OK to run …?」，可选不再询问 | 实测（冷启动，点 OK 后执行）；源码 `iTermApplicationDelegate application:openFile:` |
| Warp | 打开脚本 | 否 | 实测 |
| WezTerm 20240203 | 新开进程：`start -- /bin/sh -c …` | 否 | 实测冷启动、已运行两种情况。打开脚本在冷启动时会被丢掉（只开一个空 shell），已运行时才正常，所以不用 |
| Kaku 0.22.0 | 同 WezTerm | 否 | 未实测：WezTerm 分支，入口相同；首次打开会跑自己的设置向导，可能改 `~/.zshrc` |
| kitty 0.49.2 | 新开实例：`-o macos_quit_when_last_window_closed=yes /bin/sh -c …` | 否 | 实测，脚本结束后实例自动退出。打开脚本默认 `confirm-always`，每次都要确认，所以改走参数；kitty 自己关掉了「参数当文件打开」，指定程序时也不加载 `startup_session` |
| Alacritty 0.17.0 | 新开实例：`-e /bin/sh -c …` | 否 | 未实测：官方包只有临时签名、没有公证，Homebrew 已于 2026-09 停用；不能打开脚本，关掉最后一个窗口即退出 |
| 终端（Terminal.app） | 打开脚本 | 否 | 实测 |

Ghostty 不走新开实例，虽然那样可以免确认（实测 `-e` 能直接执行）：新实例会把用户保存的窗口再恢复一份，退出时还会覆盖保存的布局；加 `--window-save-state=never` 能避开恢复，但 Ghostty 会把它写进所有实例共用的 `NSQuitAlwaysKeepsWindows` 偏好，改掉主实例的窗口恢复行为。iTerm2 的 `iterm2:///command` 入口同样要确认，也不用。

全程不用 AppleScript：App 开着 Hardened Runtime，发送 Apple Events 需要额外的 entitlement 和自动化授权弹窗（见第 8 节）。默认终端按上表顺序取第一个已安装的（系统终端兜底），用户在「继续」按钮旁的下拉菜单里改，选择会记住；记住的终端被卸载后自动换回默认。启动失败时自动把命令复制到剪贴板并提示。没有列出的终端可以用「复制命令」。

## 5. 界面

- **入口**：侧边栏「仪表盘」下方的「会话」，可在设置里隐藏（与其他入口一致）。
- **列表**：搜索框（⌘F，Esc 清空；搜索时下方说明搜了哪些内容，没开全文搜索时给「也搜回复」入口，首次建索引时显示进度）、工具筛选（全部 / Claude / Codex / OpenCode，悬停显示数量）、分组（按时间：置顶、今天、昨天、本周、更早；按项目）。行内显示品牌图标、两行标题、项目名与分支、进行中标记 · 时间 · 轮数，全文搜索命中时再加一行摘录。标题栏右侧的「…」菜单里是重新扫描和全文搜索开关（开启后显示索引占用）。选中与悬停用 `AppSurface` 色阶自绘（系统 List 的失焦选中色在浅色下是黑底，和本应用风格不符），组标题吸顶。悬停出现「继续」按钮；右键菜单有继续、复制命令、复制会话 ID、在 Finder 中显示、导出 Markdown。↑↓ 选择并自动滚到可见，↩ 继续。
- **阅读视图**：顶部是工具、会话 ID、进行中标记、标题和元信息标签（目录、分支、模型、轮数、token、更新时间），右上角依次是复制命令、更多（Finder、导出等）、「在 <终端> 中继续」主按钮（⌘↩）和终端选择（只列已安装的）。token 是工具记录的累计数，含缓存读取，所以只放在这里并加说明，不进列表。正文提问靠右、回复靠左；回复里的代码块用等宽底色块显示，`-` 列表换成「•」，标题行加粗，其余按行内 Markdown 渲染。步骤组默认折叠，有失败的组默认展开并用橙色标出。
- **大纲**：窗口足够宽时显示在右侧，列出每一轮提问，点击跳转；底部是轮数、工具调用、改动文件、失败次数四个统计。
- **菜单栏**：额度区下方的「最近会话」，最多 4 条，可折叠（状态记住），点行打开会话中心并选中，点右侧按钮直接继续。面板打开期间实时更新，进行中的会话有标记。
- 浅色、深色两种外观都使用 `AppSurfaceTokens` 里的色阶；品牌色只用在图标上。

## 6. 隐私与安全

- 只读：不写、不删、不移动三家的任何文件；SQLite 以 `SQLITE_OPEN_READONLY` 打开。
- 不联网，不上传。正文只在两种情况下落盘：用户主动导出 Markdown；用户确认开启全文搜索后的索引（缓存目录，0600，关闭即删除）。
- 其余写入只有一次性启动脚本，权限 0700，执行后自删。

## 7. 测试

- `QuotaBackend/Tests/QuotaBackendTests/SessionCatalogTests.swift`（12 项），样本在 `Fixtures/sessions/`：
  - Claude：标题优先级、只数真实提问（排除 meta、工具结果、命令输出、任务通知、子代理）、开始目录、usage 去重、正文分组与失败回填、增量缓存；
  - Codex：只读最新版本的库、归档 / guardian / 空线程过滤、`.zst` 记录、历史库条目映射与失败识别；
  - OpenCode：JSON 存储、v1 库（与 JSON 去重、子会话与归档过滤）、v2 库内联内容；
  - WAL 库在伴随文件被删后仍可读（去掉修复时该测试失败，已验证）；
  - 继续命令：ID 校验、单引号转义（含 `'` 的路径）、各工具参数；Markdown 导出。
- 真机数据（2026-11-01）：Claude 5、Codex 150、OpenCode 7 个会话；首次扫描约 370 ms，之后增量约 2 ms；最长的 Claude 会话正文加载约 100 ms。
- 界面：用离屏渲染（与 `run_codex_reset_cards_regression.sh --render` 同法）以真实数据出浅色、深色、窄窗口和菜单栏截图逐项核对。
- `QuotaBackend/Tests/QuotaBackendTests/SessionLiveSearchTests.swift`（14 项）：
  - 增量读取：半行不算读过、补完后只读一次；追加记录后增量结果与整份重读完全一致（列表与正文）；原地截短重写、换 inode 时从头读；
  - 进行中：Claude 登记文件（busy / idle、PID 复用、进程已退出、parkedJobId）；Codex 最新一轮 inProgress 且在窗口内、崩溃残留、旧轮次、窗口过期；OpenCode v1 未完成的助手消息；
  - 全文索引：命中回复与步骤并给出可跳转的序号、列表信息与正文混合的多词查询、不足 3 字的中文、`%` `_` 引号、增量更新、跳过运行中的会话、删掉消失的会话、表结构版本重建、文件权限、删除后不会被后台更新重新建出；摘录窗口；
  - 文件监听：路径过滤（含 `/private/var` 与 `/var`）、真实 FSEvents 收到追加事件。
- 实时更新端到端：离屏程序在假 HOME 里驱动真实的 `SessionCenterStore`，结果见 §3.4。
- 终端（2026-11-02）：用与 App 相同的 NSWorkspace 调用逐个拉起，工作目录带空格和单引号，确认进入了正确目录、`claude` 在 PATH 里、脚本执行后自删。终端、Warp、WezTerm、kitty 直接执行，Ghostty、iTerm2 确认后执行；Kaku、Alacritty 未实测（原因见 §4.3）。启动参数单测覆盖：路径含空格和单引号时 `/bin/sh` 执行的正是这个脚本，脚本路径不会单独出现在参数里（去掉转义时该测试失败，已验证）。

## 8. 后续优化与拓展

按价值排序（v1 的「正文全文搜索」「实时更新」已在 v1.1 完成，见 §3.2、§3.4）：

1. **更多工具**：Gemini CLI（`~/.gemini/tmp/*/chats`）、Hermes、Cursor Agent；来源协议已按「列表 + 正文 + 继续命令」三件事抽象，新增一家只需一个 Source 文件。
2. **终端免确认与新标签页**：Ghostty 1.3 起和 iTerm2 都提供 AppleScript，可以在已运行实例里开新标签页并直接执行，免掉确认框；代价是 Apple Events entitlement、`NSAppleEventsUsageDescription` 和每个终端一次的自动化授权，用户拒绝时退回打开脚本。Otty 等更多终端、自定义终端命令也放在这一项。进行中的 Claude 会话还可以直接切到它所在的终端窗口，而不是再开一个。
3. **分支续写**：Claude `--fork-session`、OpenCode `--fork`，在原会话基础上开新会话，不污染原记录。
4. **会话管理**：归档会话的显示开关；移到废纸篓（只对 Claude/OpenCode 的文件型存储，带撤销）；置顶与重命名（写 AIUsage 自己的元数据，不改原文件）。
5. **统计联动**：在阅读视图显示本会话的 token 与费用（复用用量统计的计价表），从用量统计页跳到对应会话。
6. **会话内搜索**：阅读视图里查找并在命中之间跳转（全文搜索已经能高亮并跳到第一处）。
7. **思考过程与图片**：可选显示 thinking/reasoning 摘要，内联显示截图类附件。
8. **Codex 压缩会话预览**：引入 zstd 解码（体积约 300 KB）后，可预览只有 `.jsonl.zst` 的 22 条会话，也能进全文索引。
9. **全局快捷键**：⌥⌘S 唤出最近会话浮窗。
10. **OpenCode 进行中**：拿到 v2 库样本后补上完成标记；JSON 存储需要按消息文件指纹缓存才能判断。
