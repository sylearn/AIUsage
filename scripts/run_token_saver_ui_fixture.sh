#!/usr/bin/env bash
# Compile/render actual RuntimePane with isolated runtime stubs, never production AIUsage.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="${TOKEN_SAVER_FIXTURE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/aiusage-token-ui.XXXXXX")}"
mkdir -p "$FIXTURE"
FIXTURE="$(cd "$FIXTURE" && pwd -P)"
swift build --package-path "$ROOT/QuotaBackend" --target QuotaBackend >/dev/null
BIN="$(swift build --package-path "$ROOT/QuotaBackend" --show-bin-path)"
python3 - "$ROOT" "$FIXTURE" <<'PYCODE'
from pathlib import Path
import sys
root, fixture = map(Path, sys.argv[1:])
s = (root/'AIUsage/Views/SubscriptionGatewaySettingsView.swift').read_text()
categories = s.split('// MARK: - Settings View', 1)[0].replace('private enum GatewaySettingsCategory', 'enum GatewaySettingsCategory')
consume_fn = '    func consumeSettingsDestination()' + s.split('    private func consumeSettingsDestination()', 1)[1].split('\n    }\n', 1)[0] + '\n    }\n'
tail = s.split('// MARK: - Token Saver updates section', 1)[1]
comp = (root/'AIUsage/Views/SubscriptionGatewayComponents.swift').read_text().split('struct GatewayCard<Content: View>: View {', 1)[0]
mb = (root/'AIUsage/Views/MenuBarView.swift').read_text()
open_fn = '    func openTokenSaverSettings()' + mb.split('    private func openTokenSaverSettings()', 1)[1].split('\n    }\n', 1)[0] + '\n    }\n'
mb_section = mb.split('// MARK: - Token Saver Menu Bar Quick Controls', 1)[1].split('// MARK: - Overall Health Status', 1)[0]
routing_harness = f'''
enum AppSection {{ case subscriptionGateway }}
@MainActor final class ProductionMenuBarRouting {{
    var revealedSection: AppSection?
    private func openMainWindow(section: AppSection) {{ revealedSection = section }}
{open_fn}
}}
@MainActor final class ProductionGatewaySettingsRouting {{
    let navigation = CLIProxyGatewayNavigation.shared
    var selectedCategory: GatewaySettingsCategory = .runtime
{consume_fn}
}}
'''
(fixture/'Updates.swift').write_text(comp + '\n' + categories + '\n' + routing_harness + '\n' + tail)
(fixture/'MenuBarTokenSaver.swift').write_text('import SwiftUI\nimport Combine\nimport QuotaBackend\n' + mb_section)
# Compile the exact parent updater too: the Token Saver child alone cannot detect
# misplaced references in the sibling CPA updater. Stubs never launch CPA.
parent = s.split('    private var updatesSection: some View {', 1)[1].split('    @ViewBuilder\n    private var updateStatusPill', 1)[0]
(fixture/'ParentUpdates.swift').write_text('''import SwiftUI
import Combine

@MainActor
final class FixtureCPAUpdater: ObservableObject {
    struct Release { var version: String }
    struct Operation { var isBusy = false }
    @Published var latestRelease: Release?
    @Published var lastCheckedAt: Date?
    let currentVersion: String? = "8.0.47"
    let operation = Operation()
    let isInstalled = true
    var hasUpdate: Bool { latestRelease != nil }
    func checkForUpdates(force: Bool) async {
        latestRelease = Release(version: "8.0.99-fixture")
        lastCheckedAt = Date()
    }
    func installOrUpdateLatest() async { }
}

struct FixtureCPAUpdatesSection: View {
    @StateObject private var manager = FixtureCPAUpdater()
    var body: some View { updatesSection }
    private var updateStatusPill: some View { Text("Offline CPA fixture") }
    private var operationLabel: String { "Working…" }
    private var primaryUpdateActionTitle: String { "Update CPA (stub)" }
    private func sectionHeader<Content: View>(title: String, @ViewBuilder trailing: () -> Content) -> some View {
        HStack { Text(title).font(.title3); Spacer(); trailing().font(.caption) }
    }
    private func versionChip(title: String, value: String) -> some View { Text("\\(title): \\(value)") }
    private var updatesSection: some View {
''' + parent + '}\n')

PYCODE
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' "$BIN/description.json" > "$FIXTURE/objects.txt"
swiftc -parse-as-library -swift-version 5 -I "$BIN/Modules" -Xlinker -filelist -Xlinker "$FIXTURE/objects.txt" -lsqlite3 \
  "$ROOT/AIUsage/Views/SubscriptionGatewaySettingsRuntimePane.swift" "$ROOT/scripts/token_saver_ui_stubs.swift" "$FIXTURE/ParentUpdates.swift" "$FIXTURE/Updates.swift" "$FIXTURE/MenuBarTokenSaver.swift" "$ROOT/AIUsage/Services/TokenSaverReleaseManager.swift" -o "$FIXTURE/TokenSaverUIFixture"
mkdir -p "$FIXTURE/TokenSaverUIFixture.app/Contents/MacOS"
cp "$FIXTURE/TokenSaverUIFixture" "$FIXTURE/TokenSaverUIFixture.app/Contents/MacOS/TokenSaverUIFixture"
cat > "$FIXTURE/TokenSaverUIFixture.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.aiusage.token-saver-fixture</string><key>CFBundleName</key><string>TokenSaverUIFixture</string><key>CFBundleExecutable</key><string>TokenSaverUIFixture</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><false/></dict></plist>
PLIST
python3 - "$FIXTURE" <<'PYCODE'
from pathlib import Path
import hashlib,plistlib,sys
root=Path(sys.argv[1]);p=root/'TokenSaverUIFixture.app/Contents/Info.plist'
data=plistlib.loads(p.read_bytes())
data['CFBundleIdentifier']='local.aiusage.token-saver-fixture.'+hashlib.sha256(str(root).encode()).hexdigest()[:12]
p.write_bytes(plistlib.dumps(data))
PYCODE
if [[ "${TOKEN_SAVER_FIXTURE_WITH_LEGACY:-0}" == "1" ]]; then
  python3 - "$FIXTURE/home" <<'PYCODE'
from pathlib import Path
import json,sys
home=Path(sys.argv[1])
runtime=home/'Library/Application Support/AIUsage/CLIProxyAPI'
(runtime/'auth').mkdir(parents=True,exist_ok=True)
(runtime/'versions/v8.0.43').mkdir(parents=True,exist_ok=True)
(runtime/'current').symlink_to('versions/v8.0.43')
(runtime/'config.yaml').write_text('oauth-excluded-models: {}\n')
record={'type':'antigravity','access_token':'fixture-only-token','disabled':True,
 'excluded_models':['user-*','claude-old'],
 'aiusage_pool_breaker':{'original_excluded_models':['user-*'],'last_excluded_models':['user-*','claude-old'],'blocked_windows':{'claude-weekly':'claude'}}}
(runtime/'auth/legacy.json').write_text(json.dumps(record,sort_keys=True))
(runtime/'legacy-before.json').write_text(json.dumps(record,sort_keys=True))
PYCODE
fi
printf 'Fixture path: %s\n' "$FIXTURE"
if [[ "${1:-}" == "--run" ]]; then
  TOKEN_SAVER_FIXTURE_HOME="$FIXTURE" "$FIXTURE/TokenSaverUIFixture.app/Contents/MacOS/TokenSaverUIFixture"
else
  TOKEN_SAVER_FIXTURE_HOME="$FIXTURE/verify-home" "$FIXTURE/TokenSaverUIFixture.app/Contents/MacOS/TokenSaverUIFixture" --verify-ui
fi
