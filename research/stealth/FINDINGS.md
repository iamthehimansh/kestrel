# Kestrel detection findings — measured on a live instance

Measured 2026-10-18 against Kestrel instance 0 (AVD `kestrel-0`, Android 16 /
API 36, `google_apis_playstore` arm64, `hw.gpu.mode=host`, 6 vCPU / 6 GB) using
the in-guest EmuDetectProbe APK plus a host-side adb sweep. Raw data:
`results/probe_report.json`, `results/getprop_full.txt`,
`results/host_sweep.txt`. Probe verdict code had one bug (treated
`emu_signatures` JSONArray as a JSONObject) after all data was collected, so
the classification below is computed by hand from the measured values.

Legend: **LEAK** = a game can read this today and conclude "emulator";
**CLEAN** = measured and looks like a real device; **UNKNOWN** = not measured.

## Scored vectors

| # | Vector | Measured value | Score |
|---|--------|----------------|-------|
| 1 | `Build.MODEL` / `PRODUCT` | `sdk_gphone64_arm64` | **LEAK** (instant) |
| 2 | `Build.DEVICE` | `emu64a` | **LEAK** |
| 3 | `Build.HARDWARE` | `ranchu` | **LEAK** (goldfish/ranchu = classic emulator string) |
| 4 | `Build.BOARD` | `goldfish_arm64` | **LEAK** |
| 5 | `Build.FINGERPRINT` (+ all 8 partition fingerprints) | `google/sdk_gphone64_arm64/emu64a:16/...` | **LEAK** |
| 6 | `Build.BOOTLOADER` | `unknown` | **LEAK** (weak) |
| 7 | `Build.HOST` | `5e4581c39a34` (hex container id) | **LEAK** (weak) |
| 8 | `ro.kernel.qemu` | `1` | **LEAK** (the single most famous check) |
| 9 | `ro.boot.qemu` + ~30 `ro.boot.qemu.*` / `vendor.qemu.*` props | present, incl. `avd_name=kestrel-0`, `fake_camera=both`, `vport.modem`, ADB pubkey with user e-mail | **LEAK** (severe — even the AVD name and host user e-mail are exposed) |
| 10 | `ro.hardware` / `ro.boot.hardware` | `ranchu` | **LEAK** |
| 11 | `ro.build.characteristics` | `emulator` | **LEAK** |
| 12 | `ro.build.flavor` | `sdk_gphone64_arm64-user` | **LEAK** |
| 13 | `init.svc.qemu-props` | `running` (service visible) | **LEAK** |
| 14 | `GL_VENDOR` | `Google (Apple)` | **LEAK** (translator signature) |
| 15 | `GL_RENDERER` | `Android Emulator OpenGL ES Translator (Apple M2 Pro)` | **LEAK** (names the emulator AND the host chip) |
| 16 | `GL_VERSION` | `OpenGL ES 3.0 (4.1 Metal - 90.5)` | **LEAK** (Metal version leaks the host) |
| 17 | File artifact `/sys/module/goldfish_battery` | **EXISTS** | **LEAK** |
| 18 | `/dev/uinput` | exists (used by touchd) | **LEAK** (weak; some real devices have it, most hide it) |
| 19 | `/data/local/tmp` writable | yes | LEAK (weak; adb-connected indicator) |
| 20 | Sensor names | 18 sensors, all named `Goldfish …`, vendor `The Android Open Source Project` | **LEAK** (count is phone-like but the names are unique to the emulator) |
| 21 | Battery | `full/100`, 5000 mV, exactly 25.0 °C, Li-ion | **LEAK** (weak — constant values; real phones rarely sit at exactly 25.0 °C at full) |
| 22 | Telephony | SIM `ready`, T-Mobile 310260, SMS capable | CLEAN-ish (the goldfish test SIM looks plausible; IMEI correctly denied) |
| 23 | `/proc/cpuinfo` | generic ARMv8, implementer 0x61 (ARM Ltd), no QEMU/Goldfish strings | **CLEAN** (measured — modern ranchu does not leak here) |
| 24 | Emulator packages (`com.google.android.apps.emulator.head_track` …) | none installed | **CLEAN** |
| 25 | `Build.TYPE`/`TAGS` | `user` / `release-keys` | **CLEAN** (Play Store image is a user build — good) |
| 26 | `adb_enabled` | `1` | **LEAK** (weak — many real phones have adb on, but it flags a dev device) |
| 27 | Input devices via app | `/proc/bus/input/devices` is EACCES from an app on API 36 | **UNKNOWN for apps / LEAK for adb** — the `kestrel-touch` uinput name is invisible to apps but visible to anything with shell/adb |
| 28 | Network MAC | app got `getNetworkInterfaces()==null` (needs fix); known emulator default `02:00:00:00:00:00` | **UNKNOWN** (re-test after probe fix) |
| 29 | Play Integrity / hardware attestation | not run (would need Google endpoint + keys) | **LEAK — hard wall** (AVF/QEMU guest has no genuine TEE; verdict cannot reach MEETS_STRONG_INTEGRITY) |

## Summary

- **29 vectors examined; 20 LEAK, 3 CLEAN, 2 UNKNOWN, plus the attestation wall.**
- Only 2 of the leaks are currently spoofed by Kestrel (`ro.product.brand` /
  `ro.product.model` — and in this run not even those: the launcher only
  applies `-prop` overrides for the user-selected preset, and this instance
  uses the default identity).
- The cheapest, highest-value fixes are #8–#16 (props + GL strings): they are
  the exact strings commercial SDKs (ByteHide, Appsolid, MASTG checks) grep
  for, and MuMu closes the same class of props with its
  `phone_prop_preset.json` injection (see REPORT.md).
- The unfixable one is #29: no software change makes an emulator pass
  MEETS_STRONG_INTEGRITY. Any game gating on Play Integrity (BGMI/PUBG do for
  payments; some gate matchmaking) will still classify the device as
  non-genuine regardless of every other fix.

## Re-measurement after the stealth changes (2026-10-18, same probe, same AVD)

Three mechanisms were implemented in code and then measured live; results
below are what the guest actually reported, not intent.

### A. Launcher `-prop` identity injection (DeviceIdentity.swift + Launcher.swift)
Booted kestrel-0 cold with the full Galaxy S24 Ultra `-prop` set (57 props,
generated directly from `DeviceIdentity.properties` so the test matches the
shipped code exactly). Guest spot-check after boot:

| prop | expected | measured |
|---|---|---|
| ro.product.model | SM-S928B | **sdk_gphone64_arm64** |
| ro.product.brand | samsung | **google** |
| ro.hardware | qcom | **ranchu** |
| ro.kernel.qemu | 0/absent | **1** |
| ro.build.fingerprint | samsung/… | **google/sdk_gphone64_arm64/emu64a:16/…** |
| ro.build.characteristics | default | **emulator** |

Leak count over the 15 tracked probe vectors: **15 → 15 (0 closed)**.

Cause: on Android 16 these `ro.*` values are imported from `build.prop`
inside the read-only system partition *before* the emulator's qemu-props
service runs; Android's property service refuses to overwrite an existing
`ro.*` key, so `-prop` can only ADD new keys, never change the built-in
identity. This matches why MuMu injects its own `nemu.ro.product.*`
namespace (REPORT.md) instead of overriding `ro.product.*`.

### B. `hw.glrenderer` / `hw.glvendor` config keys (AVDConfig.render)
Both keys were written into config.ini before boot. Measured GL strings
after boot: unchanged — `Google (Apple)` / `Android Emulator OpenGL ES
Translator (Apple M2 Pro)`. This emulator build does not honor those keys
on the gfxstream translator path; the strings originate host-side in the
ANGLE/gfxstream layer.

### C. Image-level build.prop patch (the commercial mechanism; feasibility test)
Carved the EROFS system partition out of system.img (fs starts at 3 MiB),
extracted with fsck.erofs, rewrote `system/build.prop` (Samsung identity,
emulator tells dropped, 132→143 lines), repacked with mkfs.erofs
(lz4hc, 4k), reassembled a patched system.img and pointed the AVD at it.
Extraction/patch/repack all succeeded, but **the guest never completed
boot** (adb stayed `device offline` >7 minutes). A from-scratch repack
loses boot-critical metadata — most plausibly SELinux xattr contexts
and/or AVB/verity structure (the stock image carries
`VerifiedBootParams.textproto` and verity blocks mkfs.erofs does not
regenerate). Conclusion: image-level patching IS the viable mechanism
(commercial emulators all ship purpose-built guest images), but it must be
a proper image build that preserves xattrs and handles verity — not a
naive runtime repack. The AVD was restored to the stock image and
verified healthy afterwards (boots in 15-20 s, original identity).

### Net honest status
- Code shipped on this branch: coherent identity profiles, prop emission,
  GL config keys, `sec_touchscreen` rename — architecture correct and
  typechecked, **measured insufficient alone** for props/GL on stock
  Google images (A + B).
- The working mechanism (C) needs a build-time image pipeline: preserve
  xattrs + handle verity/AVB. That is the concrete next step; the
  experiment scripts are preserved in the workdir (`patch_image2.sh`,
  `retest_identity.sh`, `compare_leaks.py`).
- Play Integrity remains unbeatable by any of these (see plan doc).
