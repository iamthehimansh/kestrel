#!/bin/bash
# Builds build/Kestrel.app: the app, the kestrel CLI, touchd, the bundled keymaps and the
# icon, ad-hoc signed so it runs on this Mac.
#
# macOS ties the Accessibility permission to the app's signature. An ad-hoc signed app gets
# a new signature on every rebuild, so after rebuilding you may need to switch Kestrel off
# and on again in System Settings → Privacy & Security → Accessibility.
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/lib/progress.sh
VERSION="${KESTREL_VERSION:-0.1.0}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid release version" >&2; exit 1; }
export PROTOC_PATH="${PROTOC_PATH:-$(command -v protoc || :)}"
[ -x "$PROTOC_PATH" ] || { echo "protoc is required for the native stream build" >&2; exit 1; }
mkdir -p build
WORK="$(mktemp -d "$PWD/build/package.XXXXXX")"
APP="$WORK/Kestrel.app"
trap 'rm -rf "$WORK"' EXIT

run_step "[1/7] Build release app" swift build -c release --product KestrelApp --jobs 2
run_step "[2/7] Build release CLI" swift build -c release --product kestrel --jobs 2
BIN="$(swift build -c release --show-bin-path)"

build_touch() {
  if [ -x .build/touchd/touchd ] && [ .build/touchd/touchd -nt touchd/touchd.c ]; then
    echo ".build/touchd/touchd is up to date"
  else
    sh touchd/build.sh
  fi
}
run_step "[3/7] Build Android touch helper" build_touch

assemble() {
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
  cp "$BIN/KestrelApp" "$APP/Contents/MacOS/Kestrel"
  cp "$BIN/kestrel" "$APP/Contents/Resources/bin/kestrel"
  cp .build/touchd/touchd "$APP/Contents/Resources/touchd"
  cp -R keymaps "$APP/Contents/Resources/keymaps"
  cp LICENSE "$APP/Contents/Resources/LICENSE"
  python3 -u scripts/package-dependencies.py --binaries "$BIN" --resources "$APP/Contents/Resources"
}
run_step "[4/7] Assemble app resources and notices" assemble

make_icon() {
  local ICONSET="$WORK/Kestrel.iconset" s d
  mkdir -p "$ICONSET"
  swift scripts/make-icon.swift "$WORK/icon-1024.png"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$WORK/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png"
    d=$((s * 2))
    sips -z "$d" "$d" "$WORK/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png"
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Kestrel.icns"
}
run_step "[5/7] Generate icon" make_icon

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Kestrel</string>
  <key>CFBundleDisplayName</key><string>Kestrel</string>
  <key>CFBundleIdentifier</key><string>org.kestrel.app</string>
  <key>CFBundleExecutable</key><string>Kestrel</string>
  <key>CFBundleIconFile</key><string>Kestrel</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License. Kestrel contributors.</string>
</dict>
</plist>
PLIST
sign_app() {
  plutil -lint "$APP/Contents/Info.plist"
  codesign --force -s - "$APP/Contents/Resources/bin/kestrel"
  codesign --force --deep -s - "$APP"
  codesign --verify --deep --strict "$APP"
}
run_step "[6/7] Validate and ad-hoc sign staged app" sign_app

publish_app() {
  local backup="build/Kestrel.previous.$(date +%Y%m%d-%H%M%S).$$.app"
  if [ -e build/Kestrel.app ]; then
    mv build/Kestrel.app "$backup"
    echo "Previous app preserved at $backup"
  fi
  if ! mv "$APP" build/Kestrel.app; then
    if [ -e "$backup" ]; then mv "$backup" build/Kestrel.app; fi
    return 1
  fi
  codesign --verify --deep --strict build/Kestrel.app
}
run_step "[7/7] Publish verified local app" publish_app
printf '[%s] SUMMARY: build/Kestrel.app built and signed; Android SDK/image not bundled; not notarized.\n' "$(date +%H:%M:%S)"
