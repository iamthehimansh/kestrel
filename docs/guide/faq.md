# Frequently asked questions

## Is Kestrel an independent emulator engine?

It is an original manager, native player, input system and diagnostics suite built around Google's Android Emulator. The virtualization engine and Android image are external components. See [architecture](architecture.md).

## Does the DMG contain Android or my games?

No. First-run setup installs/reuses SDK components and a system image. Your apps and account live in separate guest data. See [setup and license behavior](getting-started.md).

## Why does macOS warn about the app?

The preview is ad-hoc signed and not notarized. Verify its origin and use macOS's per-app approval flow if available; do not disable Gatekeeper globally. See [troubleshooting](../support/troubleshooting.md).

## Why does a key hit the wrong button?

The keymap is a list of coordinates, not screen recognition. Your game HUD must match. BGMI users should use [Character option 3 and the shared layout](bgmi-layout.md). Test in training ground.

## Why does increasing WASD size not guarantee sprint?

The game decides how to interpret movement. Kestrel's actual joystick displacement combines ring radius, push distance and walk/sprint multipliers. Fixed movement mode and correct centre matter. Use the live editor or Controls inspector; do not assume a bigger drawn ring overrides game rules.

## Does hiding hints disable controls?

No. Hint visibility and Enable keymapping are separate. A 0% hint remains active if mappings are enabled. Open popovers temporarily block gameplay input so their controls remain usable.

## Can I type Hindi, emoji or any Unicode text?

Not yet. Native typing currently supports ASCII and selected editing keys. Focus observation failures reject input rather than send it to the wrong target. See [typing limitations](user-guide.md).

## Can I use voice chat?

The microphone switch opts into emulator host-microphone passthrough on the next instance start. Sound must be on, and macOS/Android/game permissions may be required. Actual voice-chat capture is not verified for the first preview.

## Does Duplicate copy all my games?

No: it duplicates settings only. Stop the instance and back up the entire Kestrel data root separately if you need to preserve apps and userdata.

## Does Kestrel hide that it is an emulator?

No such guarantee exists. Recorded identity/config changes left important detection indicators unchanged, and attestation was not tested. See [detection research](../research/detection-surface.md).

## Where are my settings and logs?

Under `~/Library/Application Support/Kestrel` by default. The CLI supports an isolated `KESTREL_HOME`. Do not share raw logs without removing keys and personal data.

## How can I contribute?

Start with [CONTRIBUTING.md](../../CONTRIBUTING.md). Useful work includes reproducible bug reports, carefully tested keymaps, docs, parser tests, input accessibility and performance measurements. Keep claims proportional to the evidence.
