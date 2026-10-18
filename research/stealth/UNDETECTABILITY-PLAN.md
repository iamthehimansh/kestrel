# Making Kestrel undetectable by games — how it works, the method, and the path

Companion to `FINDINGS.md` (measured evidence) and `RESEARCH.md` (detection-surface
map). All claims here are grounded in what the probe actually measured on
Kestrel instance 0 on 2026-10-18.

## 1. How detection works (the mental model)

A game does not "detect an emulator" in one check. It runs a battery of cheap
probes and accumulates confidence:

1. **Static identity** — `Build.*` fields and system properties, readable in
   milliseconds with no permissions. One wrong string (`sdk_gphone64_arm64`,
   `ranchu`, `ro.kernel.qemu=1`) is enough for most commercial SDKs.
2. **Environment artifacts** — files, kernel modules, services, GPU strings,
   sensor names. Requires a little more effort but still trivial.
3. **Behavioral signals** — constant battery temperature, perfect touch
   timing, adb enabled, uinput devices. Correlated over sessions.
4. **Hardware attestation** — Play Integrity asks Google's servers whether the
   boot chain is genuinely signed by a phone manufacturer. This is not a
   local check and cannot be spoofed locally.

Kestrel today fails **every layer 1–2 check measured** (20 leaking vectors)
and passes a few (cpuinfo, telephony, user build). MuMu takes the same
architectural approach the plan below proposes: a phone-identity preset
injected as properties (`phone_prop_preset.json` → `nemu.ro.product.*`, see
`REPORT.md`), not attestation spoofing.

## 2. What to do — phased fix plan

### Phase 1 — Property layer (biggest win, days of work)
Make the guest present a complete, *internally consistent* phone identity.
Per-instance "stealth profile" = brand/model/device/product/board/fingerprint/
bootloader/security-patch set as coherent `-prop` overrides at launch
(exactly the extension of Kestrel's existing `deviceBrand`/`deviceModel`
machinery in `Launcher.swift:37-38`).

Must-change props (all measured leaking today):
- `ro.kernel.qemu` → absent/0; `ro.boot.qemu*` → absent (launcher must stop
  the emulator from injecting them — they come from the emulator's own boot
  config; Kestrel already owns the QEMU command line, so this is a launcher/
  guest-init change, e.g. override in `init` or filter before property
  import)
- `ro.hardware`, `ro.boot.hardware` → real codename (`taro`, `kalama`…)
- `ro.product.*` (all 12 partitions measured: product, vendor, odm,
  system_ext, system_dlkm, vendor_dlkm) → one coherent Samsung/OnePlus/Xiaomi
  identity; today they all say `sdk_gphone64_arm64`
- `ro.build.fingerprint` (and the 8 partition fingerprints measured) → a real
  released fingerprint matching the chosen model + Android version + patch
  level
- `ro.build.characteristics` → `default`/`nosdcard`; `ro.build.flavor` →
  device codename; `ro.bootloader` → real bootloader string
- Hide `init.svc.qemu-props` (service name is itself a tell)
- Strip `ro.boot.qemu.adb.pubkey` (leaks the host user's e-mail — privacy
  leak, not just detection)

Verification: re-run the EmuDetectProbe; `props.emu_signatures` must be empty
and `build.*` must match the chosen profile.

### Phase 2 — Graphics strings (days)
Measured: `GL_VENDOR=Google (Apple)`, `GL_RENDERER=Android Emulator OpenGL ES
Translator (Apple M2 Pro)`, `GL_VERSION=OpenGL ES 3.0 (4.1 Metal - 90.5)`.
These come from the gfxstream/ANGLE translator. Fix at the translator layer
(ANGLE's renderer string generation / gfxstream's vendor string) to report a
plausible real GPU for the spoofed profile, e.g. `Adreno (TM) 740` /
`Qualcomm Technologies Inc.` — including Vulkan `deviceName`, which the probe
did not cover and should be added to it.

### Phase 3 — Environment artifacts (days)
- `/sys/module/goldfish_battery` — measured EXISTS; rename/blacklist the
  module path or make /sys/module unlistable for unprivileged readers.
- Sensor names — measured all `Goldfish …` with AOSP vendor; rename to the
  spoofed OEM's sensor naming (`samsung accel` etc.) in the guest HAL config.
- Battery constants — measured full/100/5000 mV/25.0 °C; add variance
  (temperature drift, plausible discharge).
- `/data/local/tmp` writable + `adb_enabled=1` are weak signals; leave for
  last.

### Phase 4 — Input path (the Kestrel-specific tell, harder)
`touchd`'s uinput device is named `kestrel-touch` (README). Apps cannot read
`/proc/bus/input/devices` on API 36 (measured EACCES), so this is invisible
to games *today*, but anything with shell access can see it, and behavioral
analysis (perfect event timing, machine-identical coordinates) is a separate
harder fight. Rename the device to a plausible input device name anyway
(`sec_touchscreen` etc.) — cheap and removes a future tell.

### Phase 5 — Attestation wall (cannot be won; manage it)
Play Integrity MEETS_STRONG_INTEGRITY requires genuine phone TEE/KeyMint.
An AVF/QEMU guest cannot produce it, full stop. Options are only:
- **Accept**: games gating on strong integrity will still classify the
  device as non-genuine. Document it; target games that gate on local checks
  (which Phases 1–3 defeat).
- **Server-side reality**: many games' emulator separation is a local check +
  server matchmaking flag; beating the local check changes the client's
  report but not Google's verdict.

Do NOT attempt fake attestation (violates Google's terms and most games'
ToS in a way local spoofing does not; also technically infeasible against
hardware-backed attestation).

## 3. How to research further (the method that produced this)

1. **Enumerate the surface before touching anything** — OWASP MASTG-KNOW-0031,
   commercial SDK docs (ByteHide, Appsolid), open PoCs
   (reveny/Android-Emulator-Detection), plus the project's own MuMu RE
   (`REPORT.md`). Written up in `RESEARCH.md`.
2. **Build a probe that is exactly what a game would be** — a normal APK
   reading only public APIs (Build, getprop, EGL/GLES, SensorManager,
   BatteryManager, TelephonyManager, files). No root, no hooks. If the probe
   can see it, any game can. (`ProbeActivity.java`, built no-Gradle.)
3. **Sweep from the host too** — adb shell sees what apps cannot (getprop
   full dump, /proc, module list); this separates "game-visible" from
   "researcher-visible" leaks.
4. **Measure, don't assume** — several plausible tells did NOT appear
   (cpuinfo is clean, telephony looks plausible, no emulator packages), and
   one real leak was found that lists don't mention (`/sys/module/
   goldfish_battery`).
5. **Re-run after every fix** — the probe is the regression test. Wire it
   into the diagnostics suite (`diagnostics/` already has the same pattern).

## 4. Way to achieve the goal — decision summary

- Goal "games don't detect the emulator by local checks" is **achievable**;
  Phases 1–3 close the 20 measured leaks. Kestrel is architecturally well
  placed: it already controls the QEMU command line, the guest init, the
  renderer stack and the touch path — every layer needing a change is
  already Kestrel's own code.
- Goal "fully undetectable, including Play Integrity" is **not achievable on
  any emulator** (including MuMu — its "normal phone" mode closes local
  checks, not attestation). Be explicit about which goal is being pursued.
- Suggested order: Phase 1 (props) → re-probe → Phase 2 (GL strings) →
  re-probe → Phase 3 (artifacts/sensors) → re-probe → Phase 4 (input) →
  then test with a real game's emulator gate (e.g. BGMI's emulator
  matchmaking notice) as the end-to-end check.

Artifacts in this workdir: `RESEARCH.md`, `FINDINGS.md`, this file,
`ProbeActivity.java`, `build_probe.py`, `boot_and_install.sh`, `run_probe.sh`,
`out/kestrel-emudetect.apk` (signed, verify passed), `results/` (probe JSON,
full getprop, host sweep, build/boot/run logs).
