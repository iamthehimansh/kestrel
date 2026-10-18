#!/bin/bash
# Verify an existing app-only preview DMG without launching the app or Android.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/progress.sh
VERSION="${KESTREL_VERSION:-0.1.8}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid version' >&2; exit 1; }
DMG="${1:-build/Kestrel-${VERSION}.dmg}"
WORK="$(mktemp -d "$PWD/build/verify-release.XXXXXX")"
MOUNT="$WORK/mount"
mkdir "$MOUNT"
ATTACHED=0
cleanup() {
  local result=$?
  trap - EXIT
  if [ "$ATTACHED" = 1 ]; then
    if ! hdiutil detach "$MOUNT"; then
      echo "Unmount failed; preserving $WORK" >&2
      exit 1
    fi
  fi
  rm -rf "$WORK"
  exit "$result"
}
trap cleanup EXIT
run_step '[1/5] Verify disk image integrity' hdiutil verify "$DMG"
run_step '[2/5] Mount read-only without opening Finder' hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$DMG"
ATTACHED=1
run_step '[3/5] Verify app signature' codesign --verify --deep --strict "$MOUNT/Kestrel.app"
VERIFY_CODE="$(cat <<'PY'
import plistlib, subprocess, sys
from pathlib import Path
mount = Path(sys.argv[1]); version = sys.argv[2]; app = mount / 'Kestrel.app'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleShortVersionString'] == version and info['CFBundleVersion'] == version, info
assert info['CFBundleIdentifier'] == 'org.kestrel.app'
allowed = {'Kestrel.app', 'Applications', '.DS_Store', '.HFS+ Private Directory Data\r', '.fseventsd', '.Trashes', '.Spotlight-V100'}
assert {p.name for p in mount.iterdir()} <= allowed, 'Unexpected files in release volume'
assert info.get('NSMicrophoneUsageDescription')
assert (mount / 'Applications').is_symlink()
assert (mount / 'Applications').readlink() == Path('/Applications')
for relative in ['Contents/MacOS/Kestrel', 'Contents/Resources/bin/kestrel']:
    path = app / relative
    arches = subprocess.check_output(['lipo', '-archs', str(path)], text=True).split()
    assert arches == ['arm64'], (relative, arches)
    print(relative, 'arm64 verified', flush=True)
resources = app / 'Contents/Resources'
assert (resources / 'LICENSE').read_bytes() == Path('LICENSE').read_bytes()
assert (resources / 'THIRD_PARTY_NOTICES.md').read_bytes() == Path('THIRD_PARTY_NOTICES.md').read_bytes()
assert (resources / 'licenses/Apache-2.0.txt').read_bytes() == Path('licenses/Apache-2.0.txt').read_bytes()
assert (resources / 'ThirdPartyNotices').is_dir()
assert any((resources / 'ThirdPartyNotices').rglob('*LICENSE*'))
assert any(resources.rglob('*.bundle')), 'Swift resource bundles missing'
import hashlib
for preset in Path('keymaps').glob('*.json'):
    packaged = resources / 'keymaps' / preset.name
    assert packaged.is_file(), f'Missing bundled preset: {preset.name}'
    assert hashlib.sha256(packaged.read_bytes()).digest() == hashlib.sha256(preset.read_bytes()).digest(), f'Stale bundled preset: {preset.name}'
for path in app.rglob('*'):
    assert path.suffix.lower() not in {'.img', '.qcow2', '.apk', '.jks', '.pem', '.key'}, path
    assert path.name not in {'adbkey', 'adbkey.pub', '.env', '.cocreate'}, path
print('Version, permission description, notices and no bundled VM/private files verified', flush=True)
PY
)"
run_step '[4/5] Verify version, architecture, notices and bundle contents' python3 -c "$VERIFY_CODE" "$MOUNT" "$VERSION"
run_step '[5/5] Compute distributable checksum' shasum -a 256 "$DMG"
hdiutil detach "$MOUNT"
ATTACHED=0
printf '[%s] SUMMARY: %s verified; ad-hoc signed, not notarized; no app launched.\n' "$(date +%H:%M:%S)" "$DMG"
