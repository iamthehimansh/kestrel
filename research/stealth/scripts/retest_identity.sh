#!/bin/zsh
# Re-measure: boot kestrel-0 with the Galaxy S24 Ultra identity applied the
# exact way Kestrel's Launcher/AVDConfig now apply it, then re-run the probe.
set -e
cd "$(git rev-parse --show-toplevel)"
RES=/tmp/kestrel-research/results
SDK="$HOME/Library/Android/sdk"
export ANDROID_AVD_HOME="$HOME/Library/Application Support/Kestrel/avd"
ADB="$SDK/platform-tools/adb"
EMU="$SDK/emulator/emulator"
exec > >(tee "$RES/retest_log.txt") 2>&1
ts() { date '+%H:%M:%S'; }

echo "[$(ts)] [1/6] Generate -prop args from DeviceIdentity.swift (galaxys24ultra)"
cat > /tmp/kestrel-research/identity_args.swift <<'SWIFT'
import Foundation
// #sourcePath marker keeps this readable in crash logs.
guard let id = DeviceIdentity.profile("galaxys24ultra") else { fatalError("profile missing") }
var parts: [String] = []
for (k, v) in id.properties { parts.append("\(k)=\(v)") }
print(parts.joined(separator: "\n"))
SWIFT
cat Sources/KestrelCore/DeviceIdentity.swift /tmp/kestrel-research/identity_args.swift > /tmp/kestrel-research/identity_args_run.swift
swift /tmp/kestrel-research/identity_args_run.swift > /tmp/kestrel-research/identity_props.txt
echo "props generated: $(wc -l < /tmp/kestrel-research/identity_props.txt)"
head -3 /tmp/kestrel-research/identity_props.txt

echo "[$(ts)] [2/6] Apply hw.glrenderer/hw.glvendor to config.ini (as AVDConfig.render would)"
CFG="$ANDROID_AVD_HOME/kestrel-0.avd/config.ini"
grep -v -e '^hw.glrenderer=' -e '^hw.glvendor=' "$CFG" > "$CFG.tmp"
printf 'hw.glrenderer=Adreno (TM) 740\nhw.glvendor=Qualcomm Technologies Inc.\n' >> "$CFG.tmp"
mv "$CFG.tmp" "$CFG"
grep -E '^hw.gl(renderer|vendor)=' "$CFG"

echo "[$(ts)] [3/6] Stop any running emulator"
"$ADB" emu kill 2>/dev/null || true
sleep 3

echo "[$(ts)] [4/6] Boot kestrel-0 with identity props (cold boot)"
PROPARGS=()
while IFS= read -r line; do PROPARGS+=("-prop" "$line"); done < /tmp/kestrel-research/identity_props.txt
nohup "$EMU" -avd kestrel-0 -no-snapshot-load -no-boot-anim "${PROPARGS[@]}" > "$RES/emulator_stdout_after.txt" 2>&1 &
echo "emulator pid=$!"
START=$(date +%s)
while true; do
  BOOTED=$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
  [ "$BOOTED" = "1" ] && { echo "[$(ts)] boot_completed after $(( $(date +%s) - START ))s"; break; }
  [ $(( $(date +%s) - START )) -gt 300 ] && { echo "[$(ts)] TIMEOUT"; exit 1; }
  sleep 5
done

echo "[$(ts)] [5/6] Re-run probe"
zsh /tmp/kestrel-research/run_probe.sh
cp "$RES/probe_report.json" "$RES/probe_report_after.json"

echo "[$(ts)] [6/6] Spot-check key props in guest"
for p in ro.product.model ro.product.brand ro.hardware ro.kernel.qemu ro.build.fingerprint ro.build.characteristics; do
  echo "$p=$("$ADB" shell getprop $p | tr -d '\r')"
done
echo "RETEST_DONE"
