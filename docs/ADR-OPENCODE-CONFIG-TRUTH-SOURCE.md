# ADR: OpenCode 配置采用统一真相源与持久化接管会话

- 状态：Accepted
- 日期：2026-09-02
- 关联：Issue #68

## 背景

OpenCode 会依次合并全局 `config.json`、`opencode.json`、`opencode.jsonc`，随后还可能叠加 `OPENCODE_CONFIG`、项目配置、`OPENCODE_CONFIG_DIR` 和 `OPENCODE_CONFIG_CONTENT`。过去 UI、配置写入和统计分别猜测某一份文件，既把“分层合并”误解成“二选一”，也可能让显示层、管理目标和恢复目标不一致。运行中新增或删除配置文件还会使动态选路把备份恢复到错误位置。

## 决策

1. `OpenCodeConfigResolver` 是全项目唯一的配置发现规则，输出按真实顺序排列的可见配置层、AIUsage 管理目标和后续覆盖提示。
2. 首次接管创建 `OpenCodeTakeoverSession`，持久化固定目标、原文快照、哈希和权限；接管结束前不重新选择目标。
3. JSONC 统一由 `JSONCEditor` 解析和局部补丁，保留注释与排版，并在写入前后校验语义一致。
4. 配置文件与 `auth.json` 作为同一操作事务写入或回滚。
5. 文件哈希变化、目标缺失、管理目标变化或后续层覆盖进入显式 recovery state。普通激活/停用 fail-closed；只有用户选择“保留修改”或“恢复快照”后才继续。
6. UI、节点 Store、统计扫描和内嵌编辑器都消费同一 resolution/state，不再硬编码 `opencode.json`。

## 结果

- Issue #68 不再是文案特判，而是统一路径解析的自然结果。
- 外部工具与 AIUsage 同时编辑配置时不会静默覆盖用户内容。
- App 崩溃或重启后仍能从 durable session 精确恢复原文件。
- 后续 OpenCode 增加新的配置入口时，只需扩展 resolver、诊断提示与对应测试。

## 不采用的方案

- 只把页面文案替换成 `opencode.jsonc`：仍会在 XDG、自定义配置和恢复路径上继续出现同类问题。
- 每次读写前重新探测扩展名：运行中优先级变化会让接管和恢复指向不同文件。
- 接管期间整份 JSONC 重写：会丢失注释与用户排版，用户体验不可接受。
