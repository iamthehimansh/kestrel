#!/bin/bash
# Builds build/Kestrel-<version>.dmg: a disk image with Kestrel.app and an Applications
# shortcut, so installing is a drag. Builds the app first unless SKIP_APP_BUILD=1.
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/lib/progress.sh
VERSION="${KESTREL_VERSION:-0.1.0}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid release version" >&2; exit 1; }
APP="build/Kestrel.app"
DMG="build/Kestrel-${VERSION}.dmg"

if [ "${SKIP_APP_BUILD:-0}" != "1" ]; then
  bash scripts/build-app.sh
fi
run_step "[1/4] Verify app signature" codesign --verify --deep --strict "$APP"
WORK="$(mktemp -d "$PWD/build/dmg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/Kestrel"
mkdir -p "$STAGE"
run_step "[2/4] Stage app" cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
run_step "[3/4] Create compressed app-only image" hdiutil create -volname "Kestrel" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$WORK/Kestrel.dmg"
run_step "[4/4] Verify disk image" hdiutil verify "$WORK/Kestrel.dmg"
if [ -e "$DMG" ]; then
  BACKUP="${DMG%.dmg}.previous.$(date +%Y%m%d-%H%M%S).$$.dmg"
  mv "$DMG" "$BACKUP"
  echo "Previous disk image preserved at $BACKUP"
fi
mv "$WORK/Kestrel.dmg" "$DMG"
printf '[%s] SUMMARY: %s verified; app-only, Android runtime/image not included; not installed.\n' "$(date +%H:%M:%S)" "$DMG"
