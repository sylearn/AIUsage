#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-token-controller.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
swift build --package-path "$ROOT/QuotaBackend" --target QuotaBackend >/dev/null
BIN="$(swift build --package-path "$ROOT/QuotaBackend" --show-bin-path)"
python3 - "$ROOT" "$TEMP" <<'PY'
from pathlib import Path
import sys
root, temp = map(Path, sys.argv[1:])
source = (root/'AIUsage/Views/SubscriptionGatewaySettingsRuntimePane.swift').read_text()
controller = source.split('/// Agent-side instructions only. No request middleware or CPA runtime changes.\n', 1)[1]
(temp/'Controller.swift').write_text('import Foundation\nimport Combine\nimport QuotaBackend\n'+controller)
PY
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' "$BIN/description.json" > "$TEMP/objects.txt"
swiftc -parse-as-library -swift-version 5 -I "$BIN/Modules" -Xlinker -filelist -Xlinker "$TEMP/objects.txt" -lsqlite3 "$TEMP/Controller.swift" "$ROOT/scripts/TokenSaverControllerRegression.swift" -o "$TEMP/regression"
"$TEMP/regression"
