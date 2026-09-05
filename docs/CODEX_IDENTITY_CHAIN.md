# Codex 多账号身份链

## 身份定义

一个订阅账号是“某个用户在某个工作区中的订阅”，不是整个 Business 空间。

统一的值对象为 QuotaBackend 中的 `CodexAccountIdentity`：

- 完整原生身份：`codex:account:<chatgpt_account_id>:user:<chatgpt_user_id>`。
- 缺少用户 ID 的历史列表数据：工作区 ID + 有效邮箱可辅助关联。
- 仍不完整：绑定的 credentialId、实际 auth 文件路径或记录 UUID；回退 key 保留已知身份字段。
- 空间名称、显示名称和套餐只用于展示，不进入身份。
- 工作区或用户 ID 明确冲突时，路径、邮箱、Token 相同都不能覆盖冲突。
- Keychain 跨文件凭据去重仍要求完整的工作区 + 用户；不完整凭据只在同文件且已知字段不冲突时合并。

## 数据传递

```
auth.json / JWT
  → CodexProvider（工作区 ID、用户 ID）
  → ProviderUsage.extra["userId"]
  → ProviderSummary.workspaceUserId
  → ProviderData.workspaceUserId
  → StoredProviderAccount.workspaceUserId
```

成功、凭据失败及自动扫描失败结果都保留可用的用户 ID。
请求携带的工作区 ID 优先于响应中的旧式 account_id，避免用户级 ID 替换工作区 ID。
新的字段均为可选；旧 JSON 仍可读取。已绑定记录从对应凭据补齐身份，再协调刷新结果。
旧版使用 JWT sub 的用户字段，仅在工作区一致且同一个 JWT 能证明旧 subject 时升级。
无法确认的原生工作区冲突会报告 account_mismatch，需重新连接，不猜测合并。

## 各入口使用同一身份规则

| 位置 | 规则 |
|---|---|
| 登录与凭据去重 | AccountCredentialStore 使用 CodexAccountIdentity 的原生身份与冲突判断 |
| 自动发现 | 使用 Codex 原生指纹；不按邮箱或公共 sourceIdentifier 跳过账号 |
| CPA 添加与 AuthImports 补回 | AccountIdentityPolicy.codexSubscriptionAlreadyContains，按工作区 + 用户核对 |
| 保存订阅记录 | 原生身份相同才复用；不再只按工作区 ID 覆盖邮箱、凭据 |
| 刷新协调 | 同时核对工作区和用户；完整身份优先，多个含糊候选不猜测归属，兜底分支使用相同规则 |
| 界面分组 | liveIdentityKey + 相同的归属规则；同空间不同成员各自一张卡片 |
| 单卡刷新与刷新时间 | 使用相同身份，禁止按空间 ID 或邮箱串到另一张卡片 |
| 隐藏与删除 | 只匹配当前身份；删除记录保存 workspaceUserId |
| 激活检测 | 核对磁盘内容中的原生身份，不按邮箱或共享路径判断 |

Antigravity 等其他 Provider 保持原有身份策略。

## 路径与 Token 隔离

Codex 凭据记录和订阅记录绑定的是各自实际的托管 auth 副本。
`metadata["sourcePath"]` 仅记录来源；它可能是反复切换账号的 `~/.codex/auth.json`，不能作为不同导入账号共享的身份锚点。

自动扫描与托管副本在完整原生身份相同时合并，不依赖公共路径。
一个成员失败时保留其独立错误状态，不因为同空间另一成员正常而从列表删除。

刷新与恢复：

1. OAuth 刷新按工作区 + 用户串行化。
2. 读取锁内文件时核对身份，避免请求等待期间账号已被切换。
3. 每个写回目标单独校验身份；使用已校验的数据快照构造输出，并在写入前确认文件未变化。
4. 相同 Token 只能在已知身份不冲突时辅助判断。
5. 来源文件改成其他成员或空间后，不会被旧副本的刷新覆盖。
6. 更新 lastUsed 只更新仍存在的当前凭据，不复活已删除记录或覆盖重新登录的新凭据。
7. 删除前发出的旧请求返回后，失效的 credentialId 不能复活删除记录。

## 回归验证

```bash
# 运行真实 App 账号模型与保存/协调/隐藏/删除代码，仅用内存替代 Keychain 和文件操作边界
bash scripts/run_account_identity_regression.sh

# 后端原生身份、JWT 解析、结果合并、错误保留、Token 写回与原有测试
swift test --package-path QuotaBackend

# 主应用构建
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Debug \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
```

隔离回归覆盖同 Business 多成员、同邮箱多空间、个人 + Business、同名空间、
共享路径冲突、重复登录/套餐变化、CPA 添加与删除记录、单卡刷新、
失败状态、隐藏/恢复、删除/重新添加、旧结果回流及历史 JSON 升级。
后端测试仅使用虚拟 JWT 和临时文件；不会调用真实 OpenAI 账号或更改用户凭据。
