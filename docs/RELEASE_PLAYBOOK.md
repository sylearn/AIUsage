# Release Playbook

## 目标

对这个仓库来说，“发布完成”必须同时满足：

- `main` 已推送到 GitHub
- `v<version>` tag 已推送
- GitHub Actions `Release Build` 成功
- GitHub Releases 页面已有 `dmg` 和 `zip`
- `appcast.xml` 已由工作流更新并回写到 `main`
- Release Notes 已补成用户可读版本
- 产物用稳定自签名证书签名（CI 已强制校验，详见「代码签名」一节）
- 产物是 **Universal Binary（arm64 + x86_64）**，同时支持 Apple Silicon 和 Intel（v0.13.1 起，`package-release.sh` 已强制 lipo 校验）
- 本地已重新同步远端 `main`

只要缺一项，都不算真正发版完成。

## 严禁（发版时绝对不要做）

1. **禁止**在 `README.md` / `README.zh-CN.md` 写任何版本更新说明、changelog、`New in` / `Improved in` / `v0.x.x 改进` 之类的段落。README 只描述产品能力，不写发版历史。
2. **禁止**新建总结性 Markdown 文档（发版笔记、变更汇总、临时 changelog 文件）塞进仓库。
3. **禁止**本地打包产物当正式发版：`dist/`、本地 `package-release.sh` 只用于预检；正式产物以 GitHub Actions `Release Build` 为准。
4. **禁止**跳过 CI 盯梢：push tag 后必须 `gh run watch`，确认成功、Release 有 dmg/zip、再拉回 `appcast.xml`。
5. **禁止**把用户可见更新内容写到别处：只通过 `gh release edit` 写 GitHub Release Notes。
6. **禁止**为发版改无关文件、顺手「整理」文档或加测试脚本。

## 发版前

先确认版本号已同步更新：

- `AIUsage/Info.plist`
- `AIUsage.xcodeproj/project.pbxproj`

建议先看工作区：

```bash
git status -sb
```

## 本地预检

每次发版前至少跑下面这些检查：

```bash
cd QuotaBackend && swift test
cd ..
./scripts/run_claude_proxy_regression.sh
./scripts/run_science_auth_proxy_regression.sh
./scripts/run_cliproxy_updater_regression.sh
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Release build CODE_SIGNING_ALLOWED=NO
./scripts/package-release.sh <version>
```

含义很简单：

- `swift test` 检查后端与包测试
- `run_claude_proxy_regression.sh` 检查 Claude 代理主链路
- `run_science_auth_proxy_regression.sh` 检查 Claude Science 的 HTTP、nonce、cookie 兼容与脱敏诊断
- `run_cliproxy_updater_regression.sh` 离线检查 CPA 资产选择、摘要校验、受限解压、配置保持、版本提升与回滚
- `xcodebuild ... Release` 提前暴露 Release-only 编译问题
- `package-release.sh` 提前暴露本地打包问题

CPA 网关相关的大版本或供应链改动还必须在本地增加官方完整资产回归；正式 CI 只跑确定性的离线用例，避免依赖会漂移的上游 latest release：

```bash
./scripts/run_cliproxy_updater_regression.sh --live
```

## 标准发版

### 1. 提交并推送

```bash
git add <changed-files>
git commit -m "Release <version>"
git push origin main
git tag -a v<version> -m "Release <version>"
git push origin v<version>
```

### 2. 盯工作流

```bash
gh run list --workflow "Release Build" --limit 3
gh run watch <run_id> --interval 10 --exit-status
```

如果失败，先直接看日志：

```bash
gh run view <run_id> --log-failed
```

### 3. 核对 Release

```bash
gh release view v<version> --json tagName,name,body,url,assets
```

必须确认：

- 有 `AIUsage-<version>-macOS.dmg`
- 有 `AIUsage-<version>-macOS.zip`
- Release 不是 draft
- 正文不是默认空模板

### 4. 拉回远端回写

```bash
git fetch origin
git pull --ff-only origin main
git status -sb
```

重点是把工作流自动更新的 `appcast.xml` 拉回本地。

## Release Notes

工作流只会自动生成默认 changelog 链接，所以每次都要手动补正文：

```bash
gh release edit v<version> --notes-file <notes-file>
```

推荐结构：

```md
## <version> 更新内容

### 体验修复
- ...

### 稳定性与维护
- ...

**Full Changelog**: https://github.com/sylearn/AIUsage/compare/v<prev>...v<version>
```

## 失败后的正确做法

如果 `Release Build` 失败，不要直接跳新版本号。

正确流程：

1. 在 `main` 修当前版本问题
2. 重新跑本地预检
3. 提交修复
4. 强制移动同一个 tag
5. 重新推送 `main` 和 tag

命令：

```bash
git add <changed-files>
git commit -m "<fix message>"
git push origin main
git tag -fa v<version> -m "Release <version>"
git push origin v<version> --force
```

## 代码签名（稳定自签名证书）

发布产物用**一张固定不变的自签名证书**签名（不是 ad-hoc）。原因：ad-hoc 签名指纹每次构建都变，macOS 钥匙串把指纹记在每个条目的 ACL 里，更新后旧的「始终允许」全部失效，用户每次更新都要重新授权（issue #35）。每次用同一张证书签，App 的 designated requirement 恒定（`certificate leaf = H"..."`），「始终允许」就能跨版本保留。

工作机制（已写进发布管线，自动生效，无需手动操作）：

- `release.yml` 的 `Import code signing certificate` 步骤：从 secret 解出 `.p12` → 临时钥匙串导入 → 取 identity → 写入 `MACOS_SIGNING_IDENTITY` / `MACOS_SIGNING_KEYCHAIN`。
- `package-release.sh`：检测到 `MACOS_SIGNING_IDENTITY` 就用该证书签名，并**强制校验**产物是 cert-pinned（不是则 `exit 1`，绝不静默回退 ad-hoc）。secret 缺失时才回退 ad-hoc（方便 fork 构建）。

依赖的仓库 secret（缺一不可，否则回退 ad-hoc）：

- `MACOS_CERT_P12_BASE64`：证书 `.p12` 的 base64
- `MACOS_CERT_PASSWORD`：`.p12` 密码

证书首次生成（**只做一次，之后永远复用同一张**）：

```bash
./scripts/generate-signing-cert.sh
# 产物在 dist/（已 gitignore）：aiusage-signing.p12 + .p12.base64
# 把打印的密码和 .p12.base64 内容分别填进上面两个 secret
```

> ⚠️ 不要重新生成证书。换证书 = 换指纹 = 所有用户被多问一次「始终允许」。务必把 `dist/aiusage-signing.p12` 和密码离线备份好，长期复用。

## 关键坑点

### 1. 只看本地 Debug 没用

- CI 上的 Release 构建更严格
- 一定要跑本地 Release 构建
- CI 失败时先看日志，不要靠猜

### 2. 不只是主 App，会一起构建 QuotaServer helper

- 主 App 能编译，不代表 Release workflow 一定能过
- Claude 代理相关回归必须每次发版前都跑
- helper 必须位于标准 nested-code 路径 `AIUsage.app/Contents/Helpers/QuotaServer`；旧的 `Contents/Resources/Helpers/QuotaServer` 只作为历史迁移路径，发布包不得保留
- helper 必须在外层 App 之前使用同一 identity 单独签名，并通过 `codesign --verify --strict`；`--deep` 只用于最终递归验证，不用于递归签名
- **P0 · Sparkle 自动更新**：自签名且无 Apple Team ID 时，`Sparkle.framework` 内的 `Autoupdate` / `Updater.app` / `Installer.xpc` / `Downloader.xpc` **必须与外层 App 使用同一张稳定证书（同一 certificate leaf）**。只签外层 framework、或把这些工具留成 SPM 自带的 ad-hoc，会导致已安装版本更新时报 `An error occurred while running the updater`（0.14.3 回归）。打包脚本与 CI 会硬失败校验 Autoupdate leaf == App leaf。不要为了「对齐 Sparkle 官方 ad-hoc 偏好」而破坏这条自洽布局。
- 外层 App 的 designated requirement 必须继续钉住稳定证书 leaf，否则钥匙串「始终允许」会在每次更新后失效（issue #35）

### 3. `appcast.xml` 的最终版本在远端

- 发版成功后，工作流会自动回写 `appcast.xml`
- 所以最后一定要 `git pull --ff-only origin main`

### 4. Release Notes 不会自动写好

- 默认只有 `Full Changelog`
- 必须手动补用户可读说明

### 5. `codesign` 容易被扩展属性绊倒

典型报错：

```text
resource fork, Finder information, or similar detritus not allowed
```

常见来源：

- `com.apple.FinderInfo`
- `com.apple.fileprovider.fpfs#P`

经验结论：

- 不要删掉 `scripts/package-release.sh` 里的 detritus 清理逻辑
- 不要在桌面仓库目录里的 staging `.app` 上直接做签名
- 先复制到 `/tmp` 临时目录签名和做 DMG staging，再把最终产物写回 `dist/`

### 6. 签名证书必须长期复用同一张

- 发布用稳定自签名证书（见「代码签名」一节），不是 ad-hoc
- **绝不重新生成证书**：换证书 = 用户被多问一次「始终允许」
- 证书或 secret 丢了：先找回备份，找不到再重生成（并预期老用户多授权一次）
- CI 若误回退 ad-hoc，`package-release.sh` 会 `exit 1`，不会静默发车

### 7. CI 的 Xcode 必须匹配项目的 Swift 6.2 工具链

项目 `project.pbxproj` 启用了 **Swift 6.2 专属设置/写法**，源码也按此编写：

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`（未显式标注的类型/方法隐式变 `@MainActor`）
- `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- 源码里用到 `@concurrent`（把 `nonisolated async` 强制切到全局并发执行器）

这些**只有 Xcode 26（Swift 6.2）认**。旧 runner（`macos-15` 默认 Xcode 16.4 / Swift 6.0）会：

- **静默忽略** `SWIFT_DEFAULT_ACTOR_ISOLATION` → 未标注方法退化成 `nonisolated`，一访问 `@MainActor` 成员就报 `main actor-isolated ... from a nonisolated context`
- **不认识** `@concurrent` → 直接编译失败

症状最坑：本地 Xcode 26 编译/运行都正常，CI 却 `Build macOS release artifacts` 报 `exit code 65`（issue #28 发版时踩过）。

规则：

- `release.yml` 用 `runs-on: macos-26`（默认 Xcode 26.5，和本地开发同一套 17F42）。**不要**改回 `macos-15`/旧 Xcode。
- 这跟最低系统无关：`MACOSX_DEPLOYMENT_TARGET = 14.0` 不变，老用户（macOS 14+）照常能装能跑。用哪个 SDK 编译 ≠ 最低运行系统。
- 想在本地复现旧工具链的隔离行为、一次性抓出所有「隐式 MainActor」依赖：

```bash
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Release \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  SWIFT_DEFAULT_ACTOR_ISOLATION=nonisolated build
```

- 反过来：要用新的 Swift 6.x 写法（`@concurrent` 等）前，先确认 CI 工具链跟得上，否则会出现「本地过、CI 挂」。

### 8. 发布产物必须是 Universal Binary（v0.13.1 起）

从 v0.13.1 开始，所有发布版本都同时支持 Apple Silicon 和 Intel。三条规则不能破坏：

- `package-release.sh` 里 `xcodebuild` 的 destination 必须是 **`generic/platform=macOS`**。改回具体的 `platform=macOS` 会在 arm64 runner 上静默产出 arm64-only 包。
- pbxproj 的「Build QuotaServer Helper」脚本按 Xcode 传入的 `ARCHS` 追加 `swift build --arch` 参数；Release（generic destination）产出双架构 helper，Debug 仍只编本机架构。注意 `--arch` 会把 SwiftPM 输出目录改到 `.build/apple/Products/<Config>/`，脚本用 `--show-bin-path` 动态解析，不要改回硬编码路径。
- `package-release.sh` 的 `verify_universal` 用 `lipo -archs` 校验主程序和 QuotaServer 都包含 arm64 + x86_64，缺一个切片直接 `exit 1`。不要删这段校验。
- `package-release.sh` 在 staging 完成后按 inside-out 顺序：先用宿主 identity 签 Sparkle 的 Autoupdate / Updater / XPCServices，再签被本地化修改的 Sparkle.framework，再签 `Contents/Helpers/QuotaServer`，最后签外层 App；helper、App、Autoupdate 共用 `MACOS_SIGNING_IDENTITY`，三者的 certificate leaf 一致是硬失败条件（P0 自动更新）。
- release workflow 会重新解压最终 ZIP，断言新 helper 路径存在、旧 resource 路径不存在，并对 helper 单独执行 `codesign --verify --strict --verbose=2`；同时断言 Autoupdate 与外层 App 的 certificate leaf 相同。

如需在 Apple Silicon 上验证 x86_64 切片：`arch -x86_64 <binary>`（Rosetta）。

常见疑问：

- **「未来不支持 / Rosetta」弹窗**：只有实际经 Rosetta 翻译执行的进程才会触发（macOS 26.4 起）。Universal 包在 M 芯片上原生运行 arm64 切片，不会触发；用 `arch -x86_64` 做冒烟测试时出现的弹窗属于测试行为。
- **不拆成 arm64 / x86_64 两个包**：Sparkle 同一版本只能挂一个 enclosure，拆包要双 feed、双签名、双 appcast，还要先发过渡版本分流，收益只是包体减半。所有用户走同一条 appcast，系统自动执行本机架构的切片。
- **Debug 构建的 codesign detritus 报错**：DerivedData 放在 iCloud 同步目录（如 `Desktop`）下时，`com.apple.fileprovider.fpfs#P` 扩展属性会让 codesign 失败；改用 `~/Library/Developer/` 下的 DerivedData。发布脚本的 `strip_bundle_detritus` 已处理，不受影响。

## 最短手顺

```bash
git status -sb
cd QuotaBackend && swift test
cd ..
./scripts/run_claude_proxy_regression.sh
./scripts/run_science_auth_proxy_regression.sh
./scripts/run_cliproxy_updater_regression.sh
# CPA 网关大版本或供应链改动再执行：
./scripts/run_cliproxy_updater_regression.sh --live
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Release build CODE_SIGNING_ALLOWED=NO
./scripts/package-release.sh <version>
git add <changed-files>
git commit -m "Release <version>"
git push origin main
git tag -a v<version> -m "Release <version>"
git push origin v<version>
gh run list --workflow "Release Build" --limit 3
gh run watch <run_id> --interval 10 --exit-status
gh release view v<version> --json tagName,name,body,url,assets
git fetch origin
git pull --ff-only origin main
git status -sb
```
