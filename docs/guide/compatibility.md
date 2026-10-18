# Compatibility and evidence

Kestrel is a preview, not a promise that every Android game works. A test pass, a rendered screenshot and a full match are different observations.

## Evidence vocabulary

- **Implemented:** behavior exists in source. It may still have untested paths.
- **Unit-tested:** automated fixtures cover specified behavior.
- **Runtime-verified:** a defined probe or interaction succeeded on a running system.
- **User-reported:** the maintainer/user observed behavior outside a controlled test.
- **Unknown:** no adequate evidence yet.

## Support matrix for the first public preview

| Area | Current evidence | Limits |
|---|---|---|
| Apple Silicon host | Built and installed on an Apple Silicon development Mac | Not a hardware-wide certification; Intel unsupported |
| Native player | macOS 15+ implementation, frame/render/window tests and runtime probes | Older macOS uses the emulator window; not equivalent coverage |
| Android guest | Official arm64 API 36 Google Play image used in recorded tests | SDK/image updates can alter results; no bundled runtime |
| Frame streaming | Authenticated screenshot, bounded stream and lifecycle probes | Render correctness/performance not established for every workload |
| Mouse/keymapping | Engine tests, touch probes, native sidebar drag/enable/disable checks | Requires suitable HUD coordinates and host permissions |
| Fullscreen hints | Isolated real fullscreen round trip and resize checks passed | Combined interactive tests can fail focus preconditions |
| Joystick push distance | Engine displacement and editor/model tests | Larger travel does not guarantee a game's sprint condition |
| ASCII typing | Expected phrase, Backspace and negative editor observation after Home passed on a diagnostic app | Intermittent focus-query timeouts; Unicode/IME unsupported; every game's chat not tested |
| Microphone | Opt-in flag, Sound dependency, persistence validation, build/permission description | Actual voice capture and game voice chat not verified |
| Audio playback | User reported working gameplay audio after an earlier silence investigation | Root cause/restart relationship not proven; no universal sound fix |
| Snapshot resume | Capacity-mismatch regression fixed and isolated resumes measured | Vulkan-active snapshots and changed hardware can still fail |
| Clone/duplicate | Copies settings into a new instance | Does not copy game data or installed apps |
| Device identity settings | Configuration/model code and measured research | Stock image ignored important overrides; no anti-cheat acceptance claim |
| DMG | Local integrity/mount/signature/resource checks | Ad-hoc signed, not notarized; no clean-Mac usability certification |

## Games and presets

Bundled presets include BGMI, COD Mobile, Free Fire, Genshin Impact, Mobile Legends, Clash of Clans, Asphalt and Subway Surfers. **These are starting keymaps, not a tested-games support list.** A valid JSON file can still point at the wrong HUD button.

BGMI (`com.pubg.imobile`) progressed from a reproduced EGL crash/black screen to rendered resource download with a per-app guest ANGLE selection. The maintainer supplied gameplay screenshots and reported playing. The original GLAsyncSwap-off condition was retained during the successful comparison; this was not an independent proof that every other setting is irrelevant. See the [graphics case study](../research/bgmi-case-study.md).

The published BGMI mapping uses the maintainer's current saved coordinates, Character control option 3 and a supplied HUD share code. Follow the [BGMI layout guide](bgmi-layout.md). Code validity/import behavior in another account, PUBG regional editions, every game mode and every contextual macro are not independently verified.

## Performance

No general performance parity or speed multiplier versus MuMu or other products is established. Existing comparisons used small diagnostic workloads on one host, with Android-version and drawable-size differences. UI callback cadence is not presented FPS, synchronized draw time is not frame latency, and a short app launch is not gameplay responsiveness. Read the [experiment ledger](../research/experiment-ledger.md).

## Game policy and integrity

Some publishers block emulators or restrict accounts/features. Kestrel does not promise acceptance or protection from account action. It does not modify a game's code or provide an anti-cheat/attestation bypass. The detection research measured the limits of property/configuration changes rather than proving invisibility. Follow publisher rules; do not use a valuable account to test unsupported behavior.

## Reporting a result

Use the game-compatibility issue form with the exact game/package version, guest image, emulator version, Mac/macOS, Kestrel version, renderer/ANGLE settings and HUD layout. Mark graphics, sound, input, voice and online behavior separately as working, failing or not tested. Redact account/session IDs and device credentials. One successful session is useful evidence, not a guarantee for all users.
