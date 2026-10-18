#!/bin/zsh
# Run the in-guest EmuDetectProbe and pull its JSON report; then host-side sweep.
set -e
SDK="$HOME/Library/Android/sdk"
ADB="$SDK/platform-tools/adb"
RES=/tmp/kestrel-research/results
exec > >(tee "$RES/probe_run_log.txt") 2>&1
ts() { date '+%H:%M:%S'; }

echo "[$(ts)] [1/6] Device check"
"$ADB" devices | grep -E 'emulator-[0-9]+\s+device$' || { echo "no booted emulator"; exit 1; }
DEV=$("$ADB" devices | awk '/emulator-[0-9]+[[:space:]]+device$/{print $1; exit}')
echo "using device $DEV"

echo "[$(ts)] [2/6] Launching probe activity"
"$ADB" -s "$DEV" logcat -c || true
"$ADB" -s "$DEV" shell am start -n org.kestrel.emudetect/.ProbeActivity
sleep 8

echo "[$(ts)] [3/6] Pulling report.json (probe is debuggable -> run-as)"
"$ADB" -s "$DEV" shell run-as org.kestrel.emudetect cat files/report.json > "$RES/probe_report.json" 2>/dev/null || true
if [ ! -s "$RES/probe_report.json" ]; then
  echo "run-as failed; reconstructing from logcat chunks"
  "$ADB" -s "$DEV" logcat -d -s EmuDetect:I | sed -n 's/^.*JSONCHUNK //p' > "$RES/probe_report.json"
fi
python3 -c "import json;d=json.load(open('$RES/probe_report.json'));print('report parsed OK, keys:',sorted(d.keys()))"

echo "[$(ts)] [4/6] Host sweep: system properties"
"$ADB" -s "$DEV" shell getprop > "$RES/getprop_full.txt"
wc -l "$RES/getprop_full.txt"

echo "[$(ts)] [5/6] Host sweep: artifacts, input, network, battery, packages"
{
  echo "=== artifact files ==="
  for f in /dev/qemu_pipe /dev/goldfish_pipe /dev/socket/qemud /dev/qemu_trace \
           /system/lib/libc_malloc_debug_qemu.so /system/lib64/libc_malloc_debug_qemu.so \
           /system/bin/qemu-props /init.goldfish.rc /init.qemu.rc \
           /sys/module/goldfish_audio /sys/module/goldfish_battery \
           /proc/qemu_trace /system/lib64/hw/gralloc.ranchu.so /system/lib64/hw/vulkan.ranchu.so; do
    if "$ADB" -s "$DEV" shell "test -e $f" 2>/dev/null; then echo "EXISTS  $f"; else echo "absent  $f"; fi
  done
  echo "=== /proc/bus/input/devices ==="
  "$ADB" -s "$DEV" shell cat /proc/bus/input/devices 2>/dev/null || echo "(unreadable or absent)"
  echo "=== /proc/cpuinfo (head) ==="
  "$ADB" -s "$DEV" shell head -40 /proc/cpuinfo 2>/dev/null || echo "(unreadable)"
  echo "=== network interfaces ==="
  { "$ADB" -s "$DEV" shell ip -o addr 2>/dev/null || "$ADB" -s "$DEV" shell ifconfig -a 2>/dev/null; } || echo "(none)"
  echo "=== battery stats ==="
  "$ADB" -s "$DEV" shell dumpsys battery 2>/dev/null || echo "(unavailable)"
  echo "=== sensors ==="
  "$ADB" -s "$DEV" shell dumpsys sensorservice 2>/dev/null | head -60 || echo "(unavailable)"
  echo "=== package: emulator suspects ==="
  "$ADB" -s "$DEV" shell pm list packages | grep -iE 'emulator|goldfish|qemu|nemu' || echo "(none)"
  echo "=== ro. props quick view ==="
  for p in ro.kernel.qemu ro.hardware ro.build.flavor ro.build.type ro.build.tags ro.product.model ro.product.brand ro.product.manufacturer ro.build.fingerprint ro.bootloader; do
    echo "$p=$("$ADB" -s "$DEV" shell getprop $p | tr -d '\r')"
  done
} > "$RES/host_sweep.txt" 2>&1
echo "sweep written: $(wc -l < "$RES/host_sweep.txt") lines"

echo "[$(ts)] [6/6] Done"
echo "PROBE_RUN_COMPLETE"
