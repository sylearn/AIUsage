# AIUsage Architecture

## Overview

AIUsage is a macOS-native SwiftUI application that monitors AI subscription quotas across multiple providers, runs four native proxy tracks, and can manage the official CLIProxyAPI binary as a separately updatable CPA Gateway sidecar. The codebase consists of two main modules: the **AIUsage app** (SwiftUI frontend + state management, proxy and CPA lifecycle) and the **QuotaBackend** SwiftPM package (provider engines, normalizers, proxy runtime).

## Directory Structure

```
AIUsage/
├── AIUsageApp.swift              # @main, scene setup, EnvironmentObject wiring
├── Models/
│   ├── AppState.swift            # Thin facade: UI navigation + coordinator references
│   ├── AppSettings.swift         # UserDefaults-backed preferences (ObservableObject)
│   ├── AccountStore.swift        # Account registry & credential management
│   ├── CLIProxyGatewayModels.swift # CPA settings/auth, native account identity, safe dedup plans, model/route identity
│   ├── ProviderModels.swift      # App-side ProviderData, alerts, etc.
│   ├── ProxyConfiguration.swift  # Proxy node config model (legacy, kept for compat) + NodeType / ProxyNodeFamily
│   └── NodeProfile.swift         # File-based node profile (_metadata + full settings.json)
├── Services/
│   ├── APIService.swift          # HTTP client for remote QuotaServer
│   ├── SecureAccountVault.swift  # Account registry; folded into AccountCredentialStore's single keychain item (one-time migration)
│   ├── SystemProxyDetector.swift # Detects macOS system proxy (Codex no_proxy fix)
│   ├── CodexNoProxyFixer.swift   # Writes/removes managed no_proxy block in ~/.codex/.env
│   ├── CLIProxyBinaryStore.swift # Versioned official CPA install, validation, activation and rollback
│   ├── CLIProxyConfigStore.swift # Surgical config merge that preserves CPA/user-owned fields
│   ├── CLIProxyManagementClient.swift # Typed loopback Management API and public model transport
│   ├── CLIProxyRuntimeController.swift # Sidecar lifecycle, health, LAN addresses and batched logs
│   ├── CLIProxyReleaseClient.swift # Official release discovery and asset selection
│   ├── ProviderAuthManager.swift # Auth flow orchestration (slim router)
│   └── ProviderAuth/
│       ├── ProviderAuthTypes.swift
│       ├── ProviderManagedImportStore.swift
│       ├── CLIExecutableResolver.swift
│       ├── LoginPhase.swift              # Shared login phase enum for all login coordinators
│       ├── CodexLoginCoordinator.swift   # Browser login (CLI subprocess + auto-open system browser)
│       ├── GeminiLoginCoordinator.swift  # Browser login (loopback OAuth)
│       ├── AntigravityLoginCoordinator.swift # Browser login (loopback OAuth)
│       ├── CopilotLoginCoordinator.swift # GitHub device flow
│       ├── KiroLoginCoordinator.swift    # AWS SSO device flow
│       ├── ProviderAuthCandidateDiscovery.swift
│       └── ProviderAuthParsing.swift
├── ViewModels/
│   ├── ProviderRefreshCoordinator.swift  # Refresh engine, timers, data pipeline
│   ├── ProviderActivationManager.swift   # CLI active account detection
│   ├── ProxyViewModel.swift              # Proxy node lifecycle (dual track: Claude + Codex) & process management
│   ├── CodexConfigManager.swift          # ~/.codex/config.toml surgical merge + backup/restore
│   ├── NodeProfileStore.swift            # File-based profile CRUD (~/.config/aiusage/profiles/)
│   ├── CLIProxyGatewayManager.swift       # CPA install/update, accounts, model catalog and proxy distribution
│   └── ClaudeSettingsManager.swift       # ~/.claude/settings.json full write + backup/restore
└── Views/
    ├── ContentView.swift           # NavigationSplitView shell; routes AppSection → detail view
    ├── SidebarNavigation.swift     # Single source of truth for sidebar nav items (drives ContentView list + Settings visibility toggles)
    ├── DashboardView.swift         # Main dashboard
    ├── ProviderCard.swift          # Rich quota card UI
    ├── ProvidersView.swift         # Subscriptions (.accounts) + API Providers (.apiProviders) — split of legacy "Providers"
    ├── SubscriptionGatewayView.swift # CPA shell and overview/accounts/connections/settings navigation
    ├── SubscriptionGatewayOverviewView.swift # Runtime summary and deduplicated live model catalog
    ├── SubscriptionGatewayAccountsView.swift # OAuth/import/sync account pool workflows
    ├── SubscriptionGatewayConnectionsView.swift # Managed app targets and local API setup details
    ├── SubscriptionGatewaySettingsView.swift # Network, routing, plugins, versions and diagnostics
    ├── CallAnalyticsView.swift     # "Call Analytics" entry (proxy request inspection)
    ├── StatsHubView.swift          # "Usage Stats" entry (thin wrapper over ProxyStatsView)
    ├── ProxyManagementView.swift   # Proxy node list (family-filtered: .claude / .codex) + gesture drag-to-reorder
    ├── CodexProxyManagementView.swift # Codex proxy menu (wraps ProxyManagementView(family: .codex))
    ├── OpenCodeManagementView.swift # OpenCode proxy menu (node list + resolved config takeover; JSONC-preserving editor)
    ├── CodexProxyEditorView.swift  # Codex node editor (single model)
    ├── SystemProxyWarningBanner.swift # System-proxy notice in Codex menu
    ├── ProxyStatsView.swift        # Proxy usage statistics (family-aware)
    ├── SettingsView.swift          # Preferences UI (sidebar navigation, 7 categories)
    ├── JSONRawEditorView.swift     # Raw JSON editor for node profiles
    ├── SettingsVisualEditorView.swift # Visual settings.json editor
    ├── ProfileExportView.swift     # Batch profile export UI
    ├── ProviderAccountEditorView.swift # "Connect account" sheet (per provider)
    ├── ProviderLoginStatusCard.swift   # Unified login card shared by all 5 login flows
    └── ...

QuotaBackend/Sources/
├── QuotaBackend/
│   ├── ProviderProtocol.swift    # Core protocols & types
│   ├── Engine/
│   │   ├── ProviderEngine.swift          # Concurrent provider orchestration
│   │   ├── ProviderRegistry.swift        # Static provider list
│   │   ├── AccountCredentialStore.swift  # Keychain credential storage
│   │   └── BrowserDiscovery.swift        # Browser profile helpers
│   ├── Providers/
│   │   ├── ClaudeProvider.swift         # Claude proxy usage archive reader
│   │   ├── CodexProvider.swift          # OpenAI Codex API (multi-workspace)
│   │   ├── CodexCostProvider.swift      # Codex proxy archive + non-proxy JSONL token ledger
│   │   ├── CopilotProvider.swift        # GitHub Copilot
│   │   ├── CursorProvider.swift         # Cursor IDE
│   │   ├── GeminiProvider.swift         # Google Gemini CLI
│   │   ├── DroidProvider.swift          # Droid (+API, +Auth, +Helpers, +Parsing)
│   │   ├── KimiProvider.swift           # Kimi Code subscription (/usages: weekly + rate-limit windows)
│   │   ├── KiroProvider.swift           # Kiro (+Auth, +Parsing)
│   │   ├── MiniMaxProvider.swift        # MiniMax Token Plan (/token_plan/remains: 5h + weekly)
│   │   ├── WarpProvider.swift           # Warp
│   │   └── AntigravityProvider.swift    # Antigravity (multi-workspace)
│   ├── Normalizer/
│   │   ├── UsageNormalizer.swift        # Raw → ProviderSummary + DashboardOverview
│   │   ├── UsageNormalizer+<Provider>.swift  # Per-provider normalizers (11 files)
│   │   └── ProviderSummary.swift        # Normalized summary structs
│   ├── ClaudeProxy/
│   │   ├── Canonical/             # Unified middle layer (production pipeline)
│   │   ├── Runtime/               # Proxy service, upstream client (+ CodexProxyConfiguration/Service)
│   │   ├── Conversion/            # Legacy converters (reference impl)
│   │   ├── Models/                # API model definitions
│   │   └── Utilities/             # SSE encoder
│   └── Utilities/
│       └── DateFormatting.swift   # Shared formatters (SharedFormatters, DateFormat)
└── QuotaServer/
    ├── main.swift                          # CLI entry point (PROXY_TARGET=codex selects Codex proxy)
    ├── QuotaHTTPServer.swift               # NWListener HTTP server + StreamingResponse
    ├── QuotaHTTPServer+ClaudeProxy.swift   # Claude API routing & streaming bridge
    ├── QuotaHTTPServer+CodexProxy.swift    # Codex /v1/responses + /v1/models faithful passthrough
    └── QuotaHTTPServer+Passthrough.swift   # Anthropic passthrough proxy
```

## Singleton Architecture

```mermaid
graph TD
    AppState["AppState (facade)"] --> AppSettings
    AppState --> AccountStore
    AppState --> RefreshCoordinator["ProviderRefreshCoordinator"]
    AppState --> ActivationManager["ProviderActivationManager"]
    GatewayManager["CLIProxyGatewayManager"] --> GatewayRuntime["CLIProxyRuntimeController"]
    GatewayManager --> AccountStore

    RefreshCoordinator --> AccountStore
    RefreshCoordinator --> AppSettings
    RefreshCoordinator --> Engine["ProviderEngine"]
    ActivationManager --> AccountStore
    ActivationManager --> AppSettings
```

| Singleton | Responsibility |
|-----------|---------------|
| **AppState** | UI navigation state, selected providers, read-through forwarding, `objectWillChange` aggregation |
| **AppSettings** | UserDefaults-backed preferences: theme, language, refresh intervals, backend mode |
| **AccountStore** | Account registry, credential lifecycle, normalization/dedup, Keychain persistence |
| **ProviderRefreshCoordinator** | Refresh timers, `ProviderEngine` orchestration, local/remote fetch, data merging |
| **ProviderActivationManager** | CLI active account detection (Codex/Gemini), auth file I/O |
| **CLIProxyGatewayManager** | CPA release lifecycle, account-pool operations, manifest/native-identity reconciliation, canonical model catalog, provider plugin management and distribution into existing proxy tracks |
| **CLIProxyRuntimeController** | CPA process/config/secret lifecycle, loopback health checks, optional LAN addresses and throttled diagnostic logs |

The core provider singletons forward `objectWillChange` to `AppState`. CPA views observe `CLIProxyGatewayManager.shared` and `CLIProxyRuntimeController.shared` directly so frequent runtime/model updates do not invalidate the entire app shell.

## Data Flow: Provider Refresh

```mermaid
sequenceDiagram
    participant UI as View
    participant AS as AppState
    participant RC as RefreshCoordinator
    participant ENG as ProviderEngine
    participant P as Provider
    participant N as UsageNormalizer

    UI->>AS: refreshAllProviders()
    AS->>RC: refreshAllProviders()
    RC->>RC: set isRefreshingAllProviders
    RC->>ENG: fetchAll(ids:)
    ENG->>P: fetch(credential:)
    P-->>ENG: ProviderUsage
    ENG->>N: normalize(usages:)
    N-->>ENG: [ProviderSummary] + DashboardOverview
    ENG-->>RC: results
    RC->>RC: merge providers, reconcile AccountStore
    RC-->>AS: objectWillChange
    AS-->>UI: SwiftUI re-render
```

## Main Navigation & Sidebar (v0.11+)

The main window is a `NavigationSplitView` (`ContentView`) whose sidebar is driven by a single
source of truth — `SidebarNavigation` (`Views/SidebarNavigation.swift`). That same model also feeds
the **Settings → General** sidebar-visibility toggles, so item titles/icons/order never drift between
the two places.

**`AppSection`** (`Models/AppSettings.swift`) is the selected-section enum. The legacy single
`providers` entry was split into two sections in v0.11; its old rawValue (`"providers"`) is retained
**only** for migrating persisted state (hidden flags etc.) and is no longer a valid section.

| Section (`AppSection`) | Sidebar title (EN / 中文) | Detail view | Pinned? |
|------------------------|---------------------------|-------------|---------|
| `.dashboard`            | Dashboard / 仪表盘          | `DashboardView` | ✅ always |
| `.providerAccounts`     | Subscriptions / 订阅账号     | `ProvidersView(category: .accounts)` | hideable |
| `.subscriptionGateway`  | CPA Gateway / CPA 网关       | `SubscriptionGatewayView` | hideable |
| `.apiProviders`         | API Providers / API 提供商   | `ProvidersView(category: .apiProviders)` | hideable |
| `.codexProxyManagement` | Codex Proxy / Codex 代理     | `CodexProxyManagementView` | hideable |
| `.opencodeManagement`   | OpenCode Proxy / OpenCode 代理 | `OpenCodeManagementView` | hideable |
| `.proxyManagement`      | Claude Code Proxy / Claude Code 代理 | `ProxyManagementView` | hideable |
| `.costTracking`         | Usage Stats / 用量统计       | `StatsHubView` | hideable |
| `.callAnalytics`        | Call Analytics / 调用分析    | `CallAnalyticsView` | hideable |
| `.inbox`                | Inbox / 消息                | `InboxView` (unread badge) | hideable |
| `.settings`             | Settings / 设置             | `SettingsView` | ✅ always |

- **Grouping**: `SidebarNavigation.primary` (dashboard → call analytics) renders above a divider;
  `SidebarNavigation.secondary` (inbox + settings) below it.
- **Three independent proxy entries**: Claude Code / Codex / OpenCode each get their own sidebar item
  (brand icon), matching the three independent proxy tracks (see Proxy Subsystem).
- **User-hideable visibility**: every item except Dashboard and Settings (`isHideable == false`) can be
  hidden via right-click → Hide or Settings → General. Hidden sections live in
  `AppSettings.hiddenSidebarSections` (UserDefaults). Hiding the current section falls back to Dashboard.
- The macOS **menu-bar** surface (`MenuBarView`, status item) is a separate entry point that reuses the
  same `AppState` data and can deep-link back into these sections via `AppState.presentMainWindow(section:)`.

## CPA Gateway Subsystem (v0.14+)

Detailed lifecycle, security, account synchronization, model identity and UI decisions live in [CLIPROXYAPI_INTEGRATION_DESIGN.md](CLIPROXYAPI_INTEGRATION_DESIGN.md).

CPA is a managed upstream gateway, not a replacement for the Codex, Claude Code, OpenCode or Claude Science proxy tracks. AIUsage installs signed/ad-hoc-validated official release assets into versioned directories, keeps the active version behind a `current` symlink, writes only owned config paths, and can promote or roll back CPA without an AIUsage update.

The live model catalog intentionally separates three concepts:

- **logical model** — the canonical row shown once in Overview;
- **vendor brand** — resolved from model metadata/identity, never from the API format used to reach it;
- **route ID** — the exact OpenAI, Anthropic or Gemini identifier shown in the model detail sheet.

Known CPA compatibility aliases are collapsed into one logical entry while every protocol-specific route ID remains available. Account candidate discovery, compatibility checks and credential-file conversion run outside SwiftUI rendering; published snapshots are indexed in memory. CPA stdout/stderr is redacted off the main actor and published in 200 ms batches, removing the two high-frequency render invalidation paths that previously delayed top-level tab selection. Explicit full account reconciliation remains an asynchronous management operation rather than a render-time task.

CPA account reconciliation uses provider-native identity instead of display email or imported-file path. Codex identity is the normalized ChatGPT account/workspace ID plus a user discriminator (`chatgpt_user_id`, explicit `user_id`, then JWT `sub`); plan and email remain display metadata, so a plan upgrade does not create another identity while two workspaces for one email stay separate. Antigravity identity is project ID plus normalized email, preserving multiple projects for one Google account. Keys are provider-prefixed SHA-256 digests of those non-secret claims and never include tokens or the AIUsage credential ID. Incomplete or contradictory claims are weak identities and are never automatically merged. The Accounts UI exposes plan/workspace or project summaries so visually identical emails remain understandable.

`account-sync-manifest.json` keeps the existing schema version compatible by decoding its new optional native-identity key with `decodeIfPresent`. A missing manifest starts empty; an existing manifest that is malformed, unsupported, or internally invalid marks reconciliation unhealthy and blocks sync writes, record migration, and destructive cleanup. Legacy provider/credential/file-name linkage remains a compatibility fallback only.

Historical `aiusage-*.json` convergence is deliberately fail-closed. A pure plan accepts only strong native identity plus strong AIUsage ownership, then requires every copy to have the same destructive safety fingerprint: a SHA-256 refresh-token lineage and the same persistent CPA settings (`disabled`, `note`, `priority`, `websockets`, and other non-volatile fields). Access/id tokens, expiry/timestamp fields, request counters, and the AIUsage marker are excluded. Different or missing fingerprints produce a visible retained-conflict count and no deletion. Before execution, canonical and duplicate payloads are downloaded and checked again; rollback payloads live only in memory for that operation and are released afterward. AIUsage intentionally creates no second on-disk OAuth backup directory.

LAN mode binds the CPA data listener to all interfaces only after explicit opt-in. `remote-management.allow-remote` remains disabled, the management key is separate and never shown, and AIUsage itself always calls management and health endpoints through loopback.

## Proxy Subsystem

详细架构文档见 [PROXY_ARCHITECTURE.md](PROXY_ARCHITECTURE.md)。
Claude Code / Codex 的用量统计、计费、缓存和归档口径见 [USAGE_AND_BILLING.md](USAGE_AND_BILLING.md)。

三条相互独立、可同时激活的代理面（各有独立的侧边栏入口与激活状态）：

- **Claude Code 轨道**（`.anthropicDirect` / `.openaiProxy`）：写 `~/.claude/settings.json`。由 `ProxyViewModel` 用 `activatedConfigId` 跟踪。
- **Codex 轨道**（`.codexProxy`）：写 `~/.codex/config.toml`（`CodexConfigManager` 外科式合并），详见 PROXY_ARCHITECTURE.md「Codex 代理」章。由 `ProxyViewModel` 用 `activatedCodexConfigId` 跟踪。Claude/Codex 互斥仅限同家族 `ProxyNodeFamily`。
- **OpenCode 轨道**：由 `OpenCodeNodeStore` + `OpenCodeConfigManager` 独立管理（不经 `ProxyViewModel`），通过 `OpenCodeConfigResolver` 按 OpenCode 的真实顺序合并全局 `config.json → opencode.json → opencode.jsonc`，并报告 `OPENCODE_CONFIG`、`OPENCODE_CONFIG_DIR`、`OPENCODE_CONFIG_CONTENT` 等后续层；接管期间使用 durable session 固定管理目标，`JSONCEditor` 做局部文本更新并保留用户注释。

**Process lifecycle** (managed by `ProxyViewModel` + `ProxyRuntimeService`):

1. User activates a proxy node in the UI
2. `ProxyViewModel` executes transactional activation:
   - Loads full settings from `NodeProfileStore` profile (v0.5.0+) or legacy `ProxyConfiguration`
   - **Claude track**: writes complete `~/.claude/settings.json` via `ClaudeSettingsManager.writeFullSettings()` (auto-backup to `settings.backup.json`)
   - **Codex track**: spawns `QuotaServer(PROXY_TARGET=codex)`, then injects managed block into `~/.codex/config.toml` (backup-as-source-of-truth); if a system proxy is detected, writes `no_proxy` into `~/.codex/.env`
   - Spawns `QuotaServer` process (via `ProxyRuntimeService`)
   - Persists `activatedConfigId` / `activatedCodexConfigId` only after all steps succeed
3. Pipes stdout/stderr, parses `PROXY_LOG:` JSON lines for stats. Stats ingestion is main-thread-light:
   cache invalidation + `objectWillChange` are throttled to 0.5s, and all persistence (log shards,
   statistics, usage archive) is encoded and written on a background serial queue (`ProxyPersistence.queue`)
4. On deactivation: kills process, restores `settings.json` / `config.toml` (+ `.env`) from backup, rolls back state

**Proxy modes**:
- **OpenAI Convert** (Claude track): Claude API → Canonical Middle Layer → OpenAI `chat/completions` or `responses` → upstream
- **Anthropic Passthrough** (Claude track): Transparent forwarding with token usage logging
- **Codex Faithful Passthrough**: OpenAI Responses inbound forwarded verbatim to an OpenAI-compatible upstream (no Canonical rewrite; only model + auth adjusted)

**Conversion pipeline**: Claude-track protocol conversion goes through a Canonical Middle Layer (see [CANONICAL_MIDDLE_LAYER_DESIGN.md](CANONICAL_MIDDLE_LAYER_DESIGN.md)). The Codex track is passthrough-only in Phase B.

## Storage Locations

| Location | Content |
|----------|---------|
| **UserDefaults** | App preferences, selected providers, hidden sidebar sections, stats |
| **Keychain** (single item, owned by `AccountCredentialStore`) | Provider credentials (cookies, tokens, API keys) **plus** the account registry metadata (emails, notes, IDs) folded in as an auxiliary blob. Consolidated into one item in v0.12.1 so the app shows at most one "Always Allow" prompt; `SecureAccountVault` migrates its old standalone item once on first access. |
| `~/.config/aiusage/profiles/*.json` | Node profile files (`_metadata` + full `settings.json` content) |
| `~/.claude/settings.json` | Claude Code configuration (full replacement on activation) |
| `~/.claude/settings.backup.json` | Backup of `settings.json` before activation |
| `~/.config/aiusage/proxy-logs/proxy-logs-YYYY-MM-DD.json` | Short-retention proxy request log shards |
| `~/.config/aiusage/usage-archive/proxy-usage-claude-v1.json` | Claude proxy daily usage archive; token/cost fields are frozen when requests are logged |
| `~/.config/aiusage/usage-archive/proxy-usage-codex-v1.json` | Codex proxy daily usage archive; same frozen-cost semantics |
| `~/.codex/config.toml` | Codex configuration; managed `model_provider=aiusage-proxy` block injected on activation (chmod 0600) |
| `~/.codex/config.toml.aiusage.bak` | Backup of `config.toml` before injection (backup-as-source-of-truth; removed on restore) |
| `$XDG_CONFIG_HOME/opencode/config.json`、`opencode.json`、`opencode.jsonc`（默认 `~/.config/opencode/`） | OpenCode 全局配置层；三者按顺序深合并。AIUsage 只管理最高优先级的专用 `opencode.json[c]` 层，`config.json` 只读；编辑器保持 JSONC 注释与排版 |
| `~/.config/aiusage/opencode-takeover.json` + `opencode-takeover-backup/` | Durable takeover session：固定目标路径、原文快照、哈希、权限和恢复状态；外部修改时 fail-closed，用户明确选择后才接受或丢弃 |
| `~/.codex/.env` | Managed `no_proxy` block (loopback only) written when a system proxy is detected; removed on deactivation |
| `~/Library/Application Support/AIUsage/CLIProxyAPI/` | CPA versioned binaries, `current` symlink, preserved `config.yaml`, auth directory, stable plugin data, settings and account-sync manifest. Duplicate-auth rollback payloads are memory-only; no second token-bearing backup directory is created. |
| `~/Library/Application Support/AIUsage/CLIProxyAPI/account-sync-manifest.json` | Mode, file linkage, optional provider-prefixed native-identity digest, timestamps and one-way content fingerprints; never credential JSON or token material. Existing v1 records without native identity remain readable. |
| **Keychain** (`CLIProxySecretStore`) | Separate CPA client and management keys; management key is never displayed or reused as a client credential |
| `~/.codex/sessions/**/*.jsonl`, `~/.codex/archived_sessions/**/*.jsonl` | Codex non-proxy session logs (read-only token source for CodexCostProvider; overridable via `$CODEX_HOME`) |
| `~/Library/Caches/AIUsage/codex-cost-file-cache-v*.json` | CodexCostFileScanCache — per-file scan results, keyed on size + mtime so reopened sessions skip re-parsing |
| `~/.config/aiusage/usage-archive/codex-non-proxy-usage-v*.json` | CodexNonProxyUsageArchiveStore — frozen per-day non-proxy token totals; today is recomputed, previous days are immutable |
| `~/.config/aiusage/usage-archive/codex-subscription-usage-v*.json` | Legacy Codex non-proxy archive path; read once and migrated to `codex-non-proxy-usage-v*.json` |

## Supported Providers

| ID | Provider | Channel | Auth Method |
|----|----------|---------|-------------|
| codex | Codex (OpenAI) | CLI | `codex login` flow (system browser) |
| copilot | GitHub Copilot | IDE | GitHub device flow |
| cursor | Cursor | IDE | Browser session |
| antigravity | Antigravity | IDE | Google OAuth (loopback) |
| kiro | Kiro | IDE | AWS SSO device flow |
| warp | Warp | IDE | Auth file |
| gemini | Gemini CLI | CLI | Google OAuth |
| kimi | Kimi Code | CLI | API key (`sk-…`, manual paste or `~/.kimi/config.toml`) |
| minimax | MiniMax Token Plan | CLI | Subscription key (`sk-cp-…`, manual paste) |
| droid | Droid | CLI | Browser session / API |
| claude | Claude Code | Local | AIUsage Claude proxy usage archive |
| codex-cost | Codex | Local | Codex proxy archive + token-only non-proxy session logs |

## Account Login Flow (v0.7.1+)

Five providers use an interactive sign-in flow driven by a dedicated `*LoginCoordinator`
(Codex / Gemini / Antigravity browser-loopback, Copilot / Kiro device-code). They share:

- **`LoginPhase`** (Service layer, `ProviderAuth/LoginPhase.swift`): the single phase enum
  (`idle / launching / waitingForBrowser / waitingForCompletion / succeeded / failed`) every
  coordinator publishes. Coordinators never auto-open an embedded WebView — they open the
  **system browser** via `NSWorkspace`, matching native macOS sign-in behavior.
- **`ProviderLoginStatusCard`** (View layer): one card UI reused by all five sections. The
  view maps `LoginPhase` + the editor's `errorMessage`/`isWorking` into a single
  `ProviderLoginVisualState` where **error always wins over success** and the account-import
  step shows a distinct `connecting` state. This removes the previous bug where a green
  "completed" badge and a red error could appear at once.

`coordinator.phase == .succeeded` only means the browser/device step finished; the account is
actually connected by the subsequent `importCandidate` step in `ProviderAccountEditorView+Actions`.

## Auto-Update UX (v0.7.2+)

`SparkleController` (`AIUsageApp.swift`) wraps Sparkle with a launch-time silent probe
(`checkForUpdateInformation()`) and Sparkle 2 **gentle reminders** (`SPUStandardUserDriverDelegate`).
Scheduled/background update discovery never steals focus with a modal; instead it publishes
`availableUpdateVersion`. The sidebar footer (`SidebarFooterView` in `ContentView.swift`) always shows
the current `vX.Y.Z` in the bottom-left and reveals an animated "Update available" pill when a new
version is found. Clicking it runs the standard Sparkle flow (release notes → install → auto relaunch).

## CI/CD

Single GitHub Actions workflow (`.github/workflows/release.yml`):
- **Trigger**: push tag `v*.*.*` or manual dispatch
- **Regression gates**: QuotaBackend tests, Claude proxy regression, Claude Science auth regression, and the deterministic offline CPA updater/runtime regression
- **Steps**: checkout → validate version consistency (Info.plist + project.pbxproj + tag) → SPM resolve → regression gates → build universal release → sign with Sparkle → upload DMG/ZIP → publish GitHub Release → update appcast.xml

**Version must match in three places**: `Info.plist` (CFBundleShortVersionString + CFBundleVersion), `project.pbxproj` (MARKETING_VERSION), and Git tag.

## Settings UI Architecture (v0.5.1+)

The `SettingsView` uses a **sidebar navigation + content area** two-column layout with 7 categories:

| Category | Content |
|----------|---------|
| **General** | Language, theme, display currency, launch at login, hide dock icon, minimize to tray on close (#39), keep running in background, sidebar item visibility toggles |
| **Data & Refresh** | Backend mode (local/remote), remote server config, provider/CC auto-refresh intervals |
| **Menu Bar** | Quota account pinning, cost source pinning + per-source config |
| **Card Appearance** | Quota card style (bar/ring/segments), progress meaning (remaining/used), preview |
| **Proxy** | Auto-start proxy on launch, proxy log retention |
| **Notifications** | Enable notifications, low quota alert threshold, Claude Code daily cost alert |
| **About** | Version, automatic updates, check for updates, GitHub link |

Menu bar display is hardcoded to `iconAndMetric` mode with `both` (quota% + cost) metric type. The settings sidebar navigation state is managed by a `SettingsCategory` enum.
