#!/usr/bin/env bash
# Exercise the exact production DMG-create command; no app build or installation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PYCODE'
from pathlib import Path
import hashlib, os, plistlib, shutil, subprocess, sys, tempfile
root = Path(sys.argv[1])
script = (root/'scripts/package-release.sh').read_text()
command = script.split('\nhdiutil create \\\n', 1)[1].split('\nMOUNT_DIR=', 1)[0]
command = 'hdiutil create \\\n' + command
work = Path(tempfile.mkdtemp(prefix='aiusage-dmg-regression-'))
mount = work/'mount'
mounted = False

def run(*args):
    return subprocess.run(args, check=True, capture_output=True)

try:
    source = work/'source'
    resources = source/'AIUsage.app/Contents/Resources'
    resources.mkdir(parents=True)
    payload = resources/'payload.bin'
    payload.write_bytes(bytes(range(256)) * 65536)
    for i in range(32):
        (resources/f'rule-{i}.md').write_text('Fixture rule.\n' * 40)
    (resources/'current').symlink_to('payload.bin')
    (source/'Applications').symlink_to('/Applications')
    image = work/'rw.dmg'
    env = dict(os.environ, APP_NAME='AIUsage-DMG-Regression',
               DMG_STAGING_DIR=str(source), DMG_RW_PATH=str(image))
    subprocess.run(['bash', '-euc', command], env=env, check=True)
    info = plistlib.loads(run('hdiutil', 'imageinfo', '-plist', str(image)).stdout)
    assert any(p.get('partition-hint') == 'Apple_HFS' for p in info['partitions']['partitions']), info
    print('PASS production create command uses HFS+ and native size estimation')
    compressed = work/'release.dmg'
    run('hdiutil', 'convert', str(image), '-format', 'UDZO', '-o', str(compressed))
    run('hdiutil', 'verify', str(compressed))
    print('PASS UDZO conversion and disk image checksum verification')
    mount.mkdir()
    run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(compressed))
    mounted = True
    expected = hashlib.sha256(payload.read_bytes()).digest()
    assert hashlib.sha256((mount/'AIUsage.app/Contents/Resources/payload.bin').read_bytes()).digest() == expected
    assert len(list((mount/'AIUsage.app/Contents/Resources').glob('rule-*.md'))) == 32
    assert os.readlink(mount/'Applications') == '/Applications'
    assert os.readlink(mount/'AIUsage.app/Contents/Resources/current') == 'payload.bin'
    print('PASS mounted contents, payload hash, resources and symlinks')
finally:
    if mounted:
        run('hdiutil', 'detach', str(mount))
    shutil.rmtree(work)
print('DMG packaging regression: 3 checks passed')
PYCODE
