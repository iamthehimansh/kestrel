#!/bin/zsh
# Boot Kestrel instance 0's AVD with the SDK emulator and install the probe APK.
set -e
LOG=/tmp/kestrel-research/results/boot_log.txt
APK=/tmp/kestrel-research/out/kestrel-emudetect.apk
SDK="$HOME/Library/Android/sdk"
export ANDROID_HOME="$SDK"
export ANDROID_AVD_HOME="$HOME/Library/Application Support/Kestrel/avd"
ADB="$SDK/platform-tools/adb"
EMU="$SDK/emulator/emulator"
exec > >(tee "$LOG") 2>&1

ts() { date '+%H:%M:%S'; }
echo "[$(ts)] [1/3] Preflight"
"$ADB" start-server
if "$EMU" -list-avds | grep -q '^kestrel-0$'; then
  echo "[$(ts)] AVD kestrel-0 found"
else
  echo "[$(ts)] AVD kestrel-0 NOT found; available:"; "$EMU" -list-avds; exit 1
fi

# Reuse an already-running emulator-5554 if present.
if "$ADB" devices | grep -qE 'emulator-[0-9]+\s+device$'; then
  echo "[$(ts)] [2/3] Emulator already running; reusing"
else
  echo "[$(ts)] [2/3] Cold-booting kestrel-0 (window visible, gpu=host from config.ini)"
  nohup "$EMU" -avd kestrel-0 -no-snapshot-load -no-boot-anim > /tmp/kestrel-research/results/emulator_stdout.txt 2>&1 &
  echo "[$(ts)] emulator launched pid=$!; waiting for boot_completed (up to 5 min)"
  START=$(date +%s)
  while true; do
    BOOTED=$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
    if [ "$BOOTED" = "1" ]; then
      echo "[$(ts)] boot_completed=1 after $(( $(date +%s) - START ))s"
      break
    fi
    if [ $(( $(date +%s) - START )) -gt 300 ]; then
      echo "[$(ts)] TIMEOUT waiting for boot"; exit 1
    fi
    sleep 5
  done
fi

echo "[$(ts)] [3/3] Installing probe APK"
"$ADB" install -r "$APK"
echo "PROBE_INSTALLED"
