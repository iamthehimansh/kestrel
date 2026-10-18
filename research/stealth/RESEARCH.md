# Emulator detection surface — research notes

Compiled from: OWASP MASTG-KNOW-0031, ByteHide VM-detection docs, Conbersa
"Android Emulator Detection Techniques", the anti-anti-emulator playbook,
GitHub reveny/Android-Emulator-Detection, plus the Kestrel/MuMu reverse-
engineering in the main Kestrel repository (Sources/).

Goal: enumerate EVERY signal a game app can use to conclude "this is an
emulator", so the Kestrel project can close them and measure the result.

## A. System properties (readable via getprop / __system_property_get)
| Property | Emulator tell | Real phone |
|---|---|---|
| ro.kernel.qemu | =1 | absent/0 |
| ro.kernel.android.qemud | =1 | absent |
| ro.hardware | goldfish / ranchu / qemu | vendor hw name (qcom, exynos…) |
| ro.build.flavor | emulator… / sdk_gphone… | e.g. oneplus/… |
| ro.build.type | userdebug / eng | user |
| ro.build.tags | test-keys | release-keys |
| ro.build.host | build numbers with "android-build" | factory host |
| ro.build.characteristics | emulator | default/nosdcard |
| ro.product.device / name | generic / sdk / emu64 / goldfish | device codename |
| ro.product.model / brand / manufacturer | sdk_gphone / Google generic | real values |
| ro.product.manufacturer | Google | Samsung/Xiaomi/… |
| ro.build.fingerprint | generic/…/generic:… | full device fingerprint |
| ro.bootloader | unknown / qemu | real bootloader version |
| ro.boot.qemu / ro.boot.goldfish | present on emulator | absent |
| ro.radio.noril | =1 | absent |
| gsm.version.baseband | absent or dummy | modem version string |
| ro.debuggable | =1 on userdebug | 0 |
| ro.secure / ro.adb.secure | 0/0 on eng | 1/1 |
| init.svc.qemu-props | running | absent |
| qemu.hw.mainkeys / qemu.sf.lcd_density / qemu.* | present | absent |
| ro.qemu.initrc | present | absent |
| persist.qemu.* | present | absent |
| ro.kernel.android.checkjni | =1 on debug | absent |
| ro.build.characteristics=emulator | emulator | default |

## B. Filesystem artifacts (root/unrooted readable paths differ)
- /dev/qemu_pipe, /dev/goldfish_pipe, /dev/socket/qemud
- /dev/qemu_trace, /sys/kernel/debug/qemu_trace (root)
- /system/lib/libc_malloc_debug_qemu.so (+ lib64)
- /system/bin/qemu-props, init.goldfish.rc / init.qemu.rc
- /sys/module/goldfish_audio, goldfish_* kernel modules
- /system/lib/soundfx (goldfish), /sys/devices/system/qemu_trace
- /proc/qemu_trace
- /system/bin/microg-google-support or emulator-only packages
- /data/local/tmp writability is common but not conclusive

## C. Graphics stack
- GL_RENDERER: "Android Emulator OpenGL ES Translator (…)", "SwiftShader",
  "Android Emulator OpenGL ES Translator (MoltenVK…)" — vs real
  "Adreno (TM) xxx" / "Mali-Gxxx"
- GL_VENDOR: "Google Inc." / "Android Emulator" vs "Qualcomm"/"ARM"
- GL_VERSION strings containing "Emulator", "OpenGL ES 3.x (Translator …)"
- Vulkan: vkEnumeratePhysicalProperties deviceName — gfxstream exposes
  "Google SwiftShader" / goldfish translator names vs "Adreno (TM) 740"
- ANGLE renderer string via EGL (ANGLE on …)
- Extension sets that only exist in the translator

## D. Hardware / sensors
- SensorManager list: emulators expose 3–5 sensors vs 10–25 on real phones;
  missing barometer/magnetometer/light/proximity is suspicious
- Identical calibration across instances (no manufacturing variance)
- Battery: status always Charging, health good, level 100/50 fixed,
  temperature constant 25.0 (real phones: discharging usually, temp varies)
- No real telephony: gsm.sim.state ABSENT (vs READY), no IMEI, no baseband,
  no cell info (CellInfoList empty), no signal strength
- Camera: "emulated" back/front cameras on goldfish
- GPS: fixed/simulated location, NMEA from emulator

## E. Network
- 10.0.2.0/24 netdev (slirp), DNS 10.0.2.3, gateway 10.0.2.2 — classic tell
- MAC 02:00:00:00:00:00 (goldfish_ranchu default)
- No Wi-Fi MAC / no cellular interface (rmnet)

## F. Process / kernel
- /proc/cpuinfo: "Goldfish" hardware, ARM implementer 0x51? (QEMU virtual
  CPU features), "ranchu" in hardware line
- /proc/interrupts, /proc/timer_list readable on old emulators (restricted
  on real devices via hidepid/SELinux)
- dmesg readable showing goldfish kernel boot (restricted on real devices)
- Kernel version string contains "android-goldfish" / "qemu"
- Presence of adbd running as root on eng builds

## G. Behavioral / input
- Keymap injection: perfect coordinates (multiples of exact pixels),
  identical event timestamps, zero drift, impossible touch-to-response
  latency, simultaneous multi-touch with machine-identical timing
- uinput virtual devices visible in /proc/bus/input/devices ("kestrel-touch")
- ADB connection alive while game runs (games check for adbd/debuggable)

## H. Hardware attestation — THE HARD WALL
- Play Integrity API (replacing SafetyNet): verdicts MEETS_STRONG_INTEGRITY
  require a Google-backed hardware attestation (KeyMint/TEE/StrongBox).
  An AVF/QEMU guest has no genuine TEE, so the attestation key chain fails
  and the verdict will be MEETS_BASIC_INTEGRITY at best — often NONE.
- This CANNOT be fixed by spoofing props/files: the attestation happens
  server-side against Google's keys. Only a real device (or defensible
  server-side compromise, which we do not do) passes.
- Games increasingly gate online play on this (BGMI/PUBG Mobile check
  emulator at runtime + Play Integrity for payments).

## I. Kestrel's current exposure (from code exploration)
- Spoofs ONLY ro.product.brand + ro.product.model (Launcher.swift:37-38),
  opt-in via Settings phone-model presets (Pixel 9 Pro, S24U, ROG 8,
  OnePlus 12, Xiaomi 14 — Presets.swift:46-53)
- Everything else: stock Android Emulator (Google emulator binary, AVD
  config.ini hw.* keys, gfxstream renderer, "Default (emulator)" identity)
- touchd creates a uinput device named "kestrel-touch" on Play images
  (README.md:158) — a unique input-device name games can read from
  /proc/bus/input/devices without root? (needs testing — /proc/bus/input
  is usually world-readable on Android)

## J. What MuMu does (from REPORT.md)
- phone_prop_preset.json with brand/model presets injected as
  nemu.ro.product.* — i.e. they solve the same problem the same way:
  property presets, not deep attestation spoofing
- MuMu's "Miu Miu" (Mi Mo?) mode referenced in meeting: MuMu ships a
  "normal phone" mode that likely swaps more of the identity surface

## Test plan (this workdir)
1. EmuDetectProbe.apk — in-guest app that a game could ship: dumps Build.*,
   readable system properties, artifact files, GL/EGL/Vulkan strings,
   sensors, battery, telephony, /proc/cpuinfo, input devices -> JSON
2. collect_host.sh — adb-side sweep: full getprop, artifact ls, input list,
   network, battery stats
3. Score every vector LEAKS / CLEAN / UNKNOWN vs real-device baselines
