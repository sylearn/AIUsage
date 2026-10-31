# Token Saver — safe trio

The current handoff (2026-10-29) explicitly excludes Headroom. This integration contains **RTK, Caveman and Ponytail only**.

## Architecture

Agent-side, coding-scoped rules. **No request middleware, listener, Python dependency, response postprocessing, CPA restart or change to `proxy-url`.** Consequently no mutation of Claude thinking signatures, OAuth credentials or provider egress/TLS.

- Each tool is opt-in and off by default. Atomic settings at `~/Library/Application Support/AIUsage/token-saver-settings.json` (0600), protected by an in-process lock.
- Coding-only isolation is mandatory. Managed agent instructions explicitly exclude creative writing, scriptwriting, lyrics, customer-care chat and other non-coding tasks. These are instructions, not an infallible semantic classifier. No claims of guaranteed model compliance or measured savings.
- RTK rules support Antigravity `run_command` (zsh), Claude Code, Codex and OpenCode. RTK must be on the agent's PATH. A reversible, explicit zsh wrapper under AIUsage/bin supports Antigravity run_command and other agents without changing global PATH. No shell aliases or hidden interception; unsupported commands fall back to originals.
- Caveman Lite/Full/Ultra controls prose instructions only; exact code, paths, errors, security checks, the user's language and essential explanations remain intact.
- Ponytail chooses reuse/stdlib/native features and minimal verified code, not speculative abstractions.
- Rules are applied to dedicated Antigravity/Claude rules and managed blocks in Codex/OpenCode AGENTS. Existing user instructions are preserved. Start a new session to reload instructions.
- The always-on prompt is a compact built-in policy, not a concatenation of full upstream SKILL.md documents. Downloads remain integrity-checked reference artifacts; enabled tools include only their pinned commit as provenance. Updating a reference does not automatically adopt its prose or change the app-maintained compact policy. The update notice makes this distinction explicit.
- Upstream Markdown downloads are separate managed rule artifacts, never executed as code. RTK Check reads its Homebrew installed version; Update requires explicit confirmation and runs only `brew upgrade rtk` on an existing installation through a validated Homebrew path. No downloaded script, automatic install or update is executed.
- Reject symlinked targets and externally edited owned blocks. In-process serialization is not cross-process atomicity across several files.

## Verification boundaries

Run `swift test --package-path QuotaBackend`, `bash scripts/run_token_saver_settings_regression.sh` (CLT-only fallback), `bash scripts/run_token_saver_release_regression.sh`, and `bash scripts/run_pool_circuit_breaker_regression.sh`.

Full app build/tests use GitHub Actions (`build-personal.yml`) on `feat/token-saver-integration`, based on `personal-build` (`af7f4f8`). That workflow now runs Debug xcodebuild, the full QuotaBackend XCTest suite, Safe Trio/pool/updater regressions and universal Release packaging with provenance/hashes. Only read repository permission is needed; branch builds do not publish tags/releases or update main. No local Xcode installation is requested.

The original worktree retains its preexisting project/image deletions. The isolated feature worktree gets project/assets from its tracked personal-build base, without restoring or modifying the original checkout. Personal-build lacked the opt-in setting referenced by the handoff; the dependency port adds that switch support while preserving the personal-build ledger/provider/runtime behavior rather than merging the divergent upstream branch wholesale.

The release manager is registered as `AIUsage/Services/TokenSaverReleaseManager.swift` in this feature worktree’s Xcode project, matching the handoff. The original deleted project file is unchanged.


## Explicit Hermes test-profile export (2026-10-30 remediation)

Hermes is **not** silently added to `rulePaths`. No bot/default/global Hermes files are discovered or edited. After creating `token-saver-test` explicitly, run:

```sh
bash '/Users/apple/Downloads/Repo Github/AIUsage-token-saver/scripts/run_token_saver_hermes_profile.sh' --home /Users/apple
```

The source-built exporter writes only `~/.hermes/profiles/token-saver-test/workspace/HERMES.md` and a local ownership ledger. It reads current AIUsage settings, requires the exact executable managed RTK wrapper when RTK is enabled, rejects symlinked ancestors/files and externally edited content, and preserves profile config. It may adopt only the exact earlier manually copied AIUsage block. Re-export explicitly after changing toggles; this is not automatic synchronization. It neither creates/switches profiles nor changes inference connections. Disabling all features and exporting removes owned rules only.

The installed app is not rebuilt or replaced by this command. New compact rendering for the original four harnesses takes effect only after installing a build containing these source changes and applying settings; current real global settings/ledger/rules were intentionally not rewritten during remediation.

## Offline complete-cycle proof

```sh
python3 '/Users/apple/Downloads/Repo Github/AIUsage-token-saver/scripts/test_token_saver_hermes.py'
```

Uses installed Hermes's published runtime resolution and existing test-profile dependency runtime, never arbitrary `.venv` shims or a newly bootstrapped profile. Fake config, API key, model replies and usage; real temporary repository, terminal cwd binding, wrapper execution, code edit and unittest invocation. Both ON and OFF complete inspection, edit/test, then a natural final message in three mock model responses within the four-response budget. HTTP uses MockTransport and real socket connections are forbidden. No gateway or provider is contacted. This proves orchestration can finish, **not** that a real model follows RTK/Caveman/Ponytail or that net tokens decrease.

The earlier paid six-session receipt remains failed/incomplete and unchanged. No budget was reset, no seventh session or paid rerun was made. Instructions remain advisory; RTK may still be bypassed by a real model. Any future live A/B needs separate bounded authorization and a task designed to reach a natural final response inside its cap.


## AIUsage Runtime UI

The Runtime card now exposes **Reapply compact rules** and **Sync Hermes test profile**. Reapply saves the displayed settings through the existing guarded transaction; Sync calls the same explicit test-only exporter as the CLI. Changing toggles/mode replaces any prior sync-success notice with a reminder to sync separately. Missing profiles, edited files and corrupt settings produce visible errors; all-off sync reports removal of owned rules instead of a misleading export-success message.

The Updates card labels downloaded material as **Saved reference · not active policy** / **Download reference**. Confirmation and guidance explicitly say full upstream text is not injected. Built-in compact policies remain app-maintained.

Native UI proof uses the existing SwiftUI fixture, injected home, mock GitHub client and stub CPA/RTK executors. It was driven through actual macOS accessibility controls with cua_repl, with screenshots in the task's tool transcript and filesystem assertions under `artifacts/token-saver-native-ui-20261030`. This is native macOS end-to-end evidence, not a claimed browser DOM test or a full installed-app test. The available e2e skill targets web/iOS/Android; no new framework or artificial web UI was introduced for this native screen.

Run `bash scripts/run_token_saver_controller_regression.sh` for seven deterministic tests of the actual extracted controller, and `bash scripts/run_token_saver_ui_fixture.sh` to compile the actual Runtime/Updates views plus the real controller/backend against isolated runtime stubs. The personal-build workflow includes the new controller regression. No paid provider is involved.
