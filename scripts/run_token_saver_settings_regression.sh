#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-token-settings.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
swift build --package-path "$ROOT/QuotaBackend" --target QuotaBackend >/dev/null
BIN="$(swift build --package-path "$ROOT/QuotaBackend" --show-bin-path)"
python3 - "$ROOT" "$TEMP" <<'PY'
import pathlib, re, sys
root, tmp = map(pathlib.Path, sys.argv[1:])
source = (root / 'QuotaBackend/Tests/QuotaBackendTests/TokenSaverSettingsTests.swift').read_text().replace('import XCTest', 'import Foundation')
shim = '''
class XCTestCase {
    var cleanups: [() throws -> Void] = []
    func addTeardownBlock(_ body: @escaping () throws -> Void) { cleanups.append(body) }
    deinit { for cleanup in cleanups.reversed() { try? cleanup() } }
}
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool) rethrows { let result = try value(); precondition(result) }
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool) rethrows { let result = try value(); precondition(!result) }
func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T) rethrows { let left = try lhs(); let right = try rhs(); precondition(left == right) }
func XCTAssertThrowsError<T>(_ body: @autoclosure () throws -> T) { do { _ = try body(); fatalError("Expected failure") } catch {} }
'''
# XCTest autoclosure accepts throwing expressions; shim uses throwing functions,
# so move `try` outside each assertion call in the copied test only.
source = re.sub(r'(XCTAssert(?:True|False|Equal)\([^\n]*\btry\b[^\n]*)', r'try \1', source)
methods = re.findall(r'func (test\w+)\(\)', source)
main = '\n@main struct Main { static func main() throws {\n'
for method in methods:
    main += f'    try TokenSaverSettingsTests().{method}()\n'
main += f'    print("Token Saver settings: {len(methods)} checks passed")\n}} }}\n'
(tmp/'main.swift').write_text(source + shim + main)
PY
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' "$BIN/description.json" > "$TEMP/objects.txt"
swiftc -parse-as-library -swift-version 5 -I "$BIN/Modules" -Xlinker -filelist -Xlinker "$TEMP/objects.txt" -lsqlite3 "$TEMP/main.swift" -o "$TEMP/regression"
"$TEMP/regression"
