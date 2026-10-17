#!/bin/bash
# Builds build/Kestrel.app: the app, the kestrel CLI, touchd, the bundled keymaps and the
# icon, ad-hoc signed so it runs on this Mac.
#
# macOS ties the Accessibility permission to the app's signature. An ad-hoc signed app gets
# a new signature on every rebuild, so after rebuilding you may need to switch Kestrel off
# and on again in System Settings → Privacy & Security → Accessibility.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${KESTREL_VERSION:-0.1.0}"
APP="build/Kestrel.app"

echo "==> Building (release)"
swift build -c release --product KestrelApp
swift build -c release --product kestrel
BIN="$(swift build -c release --show-bin-path)"

echo "==> touchd"
if [ -x .build/touchd/touchd ] && [ .build/touchd/touchd -nt touchd/touchd.c ]; then
  echo ".build/touchd/touchd is up to date"
else
  ./touchd/build.sh
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN/KestrelApp" "$APP/Contents/MacOS/Kestrel"
cp "$BIN/kestrel" "$APP/Contents/Resources/bin/kestrel"
cp .build/touchd/touchd "$APP/Contents/Resources/touchd"
cp -R keymaps "$APP/Contents/Resources/keymaps"
cp LICENSE "$APP/Contents/Resources/LICENSE"

echo "==> Icon"
WORK="$(mktemp -d)"
ICONSET="$WORK/Kestrel.iconset"
mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$WORK/icon-1024.png" >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$WORK/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Kestrel.icns"
rm -rf "$WORK"

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
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing (ad-hoc)"
codesign --force -s - "$APP/Contents/Resources/bin/kestrel"
codesign --force --deep -s - "$APP"
codesign --verify --strict "$APP"

echo "==> Done: $APP ($(du -sh "$APP" | cut -f1))"
