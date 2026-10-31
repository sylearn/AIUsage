# Token Saver: setup and updates

Token Saver is opt-in and applies to coding agents only. It does not rewrite provider API traffic, change gateway routing, install command hooks or enable tools automatically.

## Choose what you need

| Tool | Purpose | Installation / activation |
| --- | --- | --- |
| RTK | Compress supported command output before your coding agent reads it | Install RTK on the agent's PATH, then enable **Compress tool output (RTK)** in Token Saver |
| Caveman | Shorter coding explanations through instruction rules | Enable in Token Saver; choose Lite, Full or Ultra. Built-in rules work without downloading |
| Ponytail | Favor reuse, standard libraries and minimal verified code | Enable in Token Saver. Built-in rules work without downloading |

## What a normal user actually gets

Enabling a switch means managed **instructions are saved**, not that output compression was observed. AIUsage does not intercept terminal commands or provider traffic, and cannot guarantee an agent follows an instruction or that total tokens decrease.

| Agent / tool | Setup provided | Remaining requirement |
| --- | --- | --- |
| Antigravity, Claude Code, Codex, OpenCode, Hermes (`~/.hermes/SOUL.md`) | Managed coding rules at their configured instruction paths | Start a new session and confirm the agent loads and follows them |
| RTK | Explicit wrapper and coding instructions; installation help | Install RTK externally, make it available on the agent's PATH, and actually invoke supported RTK commands |
| Caveman / Ponytail | Built-in concise-output / minimal-code instructions; optional pinned upstream references | No executable plugin is installed; behavior still depends on the agent following the rules |
| Custom Hermes profiles (`~/.hermes/profiles/*`) | Strictly isolated | Never modified by global Token Saver switches |

The built-in rules for Antigravity, Claude Code, Codex, OpenCode and Hermes (`~/.hermes/SOUL.md`) instruct agents to prefer wrapped `rg -n -- 'pattern' path` over `grep`/`rg` when semantics match, while keeping raw `cat`/`sed` for exact editing context, line ranges, redirects and heredocs. Hermes (`~/.hermes/SOUL.md`) additionally includes read-only preview guidance (`read --level minimal --max-lines 80` only when not editing, skipping preview before edits to avoid double-read round trips) and requests one wrapper `--version` check. These are instructions, not an enforcement hook.

Users on a supported harness do not need custom prompt editing for the built-in setup. Distinguish **rules saved → rules loaded → RTK invoked → equal-quality token savings measured**; none implies the next automatically.

## Understand the buttons

### Gateway Settings → Token Saver

1. **Enable coding tools first:** Turn on **Compress tool output (RTK)**, **Compress LLM output (Caveman)**, and/or **Lazy senior dev (Ponytail)** at the top of the card. Caveman and Ponytail work immediately using built-in compact rules without downloading reference files.
2. Select the coding harness under **Setup & verification (after enabling tools above)** (`Codex`, `Claude Code`, `Antigravity`, `OpenCode`, or `Hermes (~/.hermes/SOUL.md)`). AIUsage shows its managed instruction path. Custom Hermes profiles in `~/.hermes/profiles/*` stay isolated and are never modified.
3. Select **Check setup (offline)**. It reads the installed Homebrew RTK version only (`brew list --versions rtk`), never GitHub, install or upgrade. This does **not** verify the agent's PATH. If RTK is not installed in Homebrew, an inline **Copy: brew install rtk** button appears right in the Token Saver pane. If the RTK switch is off, the UI explicitly states the switch is off rather than reporting a missing/corrupted wrapper.
4. Read **Managed rules**: `current` means the expected owned block matches the file; `missing`, `stale`, `off` and `unreadable` are separate states with explicit next-step guidance. This does **not** prove a new agent session loaded it. Click **Reapply compact rules**, then check again.
5. **Default RTK history** is a supplemental Mac-wide aggregate row count from a bounded, private temporary copy of the default macOS `rtk/history.db`. SQLite never opens the original, so it cannot create its WAL/SHM files. Existing WAL/SHM/journal activity, changing source metadata, missing/custom/corrupt/unsupported/symlinked history is **unavailable / not verified**, not zero. The private copy is integrity-checked, queried as immutable and removed afterward. A count is Mac-wide historical evidence, not attribution to the selected harness/session, recent activity, successful commands or measured savings. No command argument, output or token-estimate columns are queried or displayed.
6. **Copy optional agent diagnostic** is enabled when the managed rules are `current` (and when RTK is enabled, its managed wrapper is also ready). Caveman-only and Ponytail-only configurations do not require RTK or its wrapper to copy this prompt. The copied message is an optional **self-report / terminal diagnostic**, explicitly **not proof of automatic prompt loading**: it asks the agent to state what coding-only output or code-simplicity instructions and active mode are in its current system instructions without reading the rule file on disk, and appends `<wrapper> --version` only when RTK is enabled to check terminal PATH resolution without adding a fake record to `rtk/history.db`.

Checks are explicit snapshots, not a background monitor. Changing the harness or applying/syncing settings clears the snapshot; repeat the check after external changes. The checker never repairs files, creates Hermes profiles, changes routing or makes model requests. UI uses an isolated native fixture with synthetic Homebrew/history data for testing; screenshot values are not production measurements.

1. Open **CPA Gateway → Settings → Updates → Token Saver updates**.
2. **Check versions** looks up GitHub metadata. For RTK it also reads `brew list --versions rtk`; it does not install, download rules or enable anything.
3. **Download rules / Update staged rules** downloads the checked Caveman/Ponytail `SKILL.md` pinned to its immutable commit. Confirmation is required. Git blob integrity is checked, not publisher authenticity. No downloaded scripts are executed.
4. Downloaded rules remain saved only for disabled tools. For tools already enabled, saving rules reapplies them to managed instruction files. Download and activation are intentionally different states.
5. **Open Token Saver to enable tools** takes you to the switches. Start a **new coding session** after enabling or updating rules so the agent reloads its instructions. Saving rules alone does not prove an agent is using them or producing savings.

![Version checks with RTK missing and rule downloads available](images/token-saver/updates-ready.png)

*Screenshots show the actual SwiftUI section in an isolated offline fixture. All `v1.2.3` versions are synthetic, not upstream release claims.*

## Install RTK safely

Open **How to install…** for these steps in the app:

1. If needed, install [Homebrew](https://brew.sh), then restart AIUsage so it can discover the trusted Homebrew location.
2. Review and run the [upstream-supported command](https://github.com/rtk-ai/rtk#installation) yourself in Terminal:

   ```sh
   brew install rtk
   ```

3. Verify `rtk --version` in **your coding agent's terminal**. The agent must be able to find RTK on its own PATH.
4. Return to Updates and select **Check versions** to inspect the Homebrew installation. Then enable RTK in Runtime and start a new coding session.

**Update RTK** is available only after a successful version lookup and detected Homebrew `rtk` installation. After confirmation it runs `brew upgrade rtk`; Homebrew may update required dependencies. Its version can lag behind GitHub. AIUsage does not install Homebrew, run a downloaded installer, modify PATH or install RTK hooks. Other installation methods remain externally managed; see [RTK docs](https://github.com/rtk-ai/rtk).

![RTK installation guide](images/token-saver/rtk-setup.png)

## Why is a button unavailable?

| State | What to do |
| --- | --- |
| Not checked / failed check | Select **Check versions** after resolving the displayed error |
| Operation in progress | Wait for the operation to finish; controls prevent duplicates |
| GitHub API limit | Wait until the **local retry time** in the amber banner; then explicitly check again |
| RTK not installed in Homebrew | Open **How to install…**, install externally, then check again |
| Homebrew unavailable | Install Homebrew and restart AIUsage, or manage RTK externally |
| Latest checked rules already saved | No download needed; enable the tool in Runtime and start a new coding session |

GitHub checks use the anonymous API quota shared by originating IP, **not AI/model usage quota**. [GitHub rate-limit documentation](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api).

During cooldown, all three Check controls and rule downloads pause together. Install help and navigation remain available. No automatic retries are scheduled. If GitHub does not supply a usable reset time, AIUsage waits 60 seconds before another explicit attempt. Already-eligible Homebrew upgrades do not use the GitHub API and remain separate.

![Shared GitHub cooldown with readable local retry time](images/token-saver/cooldown.png)

## Result lifetime

Check results and cooldown are retained while moving between Settings categories, including destroying and recreating the Updates section. They belong to the current Settings view lifetime, not a disk cache: closing/recreating Settings or restarting AIUsage requires a fresh check. Saved rules persist separately in managed storage.

## Reviewer verification

```sh
bash scripts/run_token_saver_settings_regression.sh
bash scripts/run_token_saver_release_regression.sh
bash scripts/run_token_saver_ui_fixture.sh --run
```

The fixture compiles the exact production CPA updater property alongside the Token Saver section, so parent-scope compile regressions are caught too. It uses a private home, mocked GitHub responses and a stub Homebrew runner. It cannot update the real Homebrew installation or CPA accounts. For the missing-RTK and cooldown scenarios, launch with `TOKEN_SAVER_FIXTURE_RTK_MISSING=1` and `TOKEN_SAVER_FIXTURE_RATE_LIMIT=1` respectively. Release regression covers cooldown expiry using an injected clock, without sleeping or network access.

Full app build/XCTest still runs through GitHub Actions on a host with Xcode; the standalone native fixture is not a full application or live-provider E2E certification.
