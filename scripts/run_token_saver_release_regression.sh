#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 - "$ROOT" "$TMP" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
tests = (root/'QuotaBackend/Tests/QuotaBackendTests/TokenSaverReleaseTests.swift').read_text()
(out/'Tests.swift').write_text(tests.replace('import XCTest', 'import Foundation').replace('@testable import QuotaBackend', ''))
manager = (root/'AIUsage/Services/TokenSaverReleaseManager.swift').read_text().replace('import QuotaBackend\n', '')
(out/'Manager.swift').write_text(manager)
PY
swiftc -swift-version 5 \
    "$ROOT"/QuotaBackend/Sources/QuotaBackend/Utilities/TokenSaverRelease*.swift \
    "$ROOT/QuotaBackend/Sources/QuotaBackend/Utilities/TokenSaverSettings.swift" \
    "$TMP/Tests.swift" "$TMP/Manager.swift" \
    "$ROOT/scripts/TokenSaverReleaseRegression.swift" -o "$TMP/release-regression"
"$TMP/release-regression"
