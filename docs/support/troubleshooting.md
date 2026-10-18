# Troubleshooting Kestrel

Use the section matching the symptom. Start with observation, change one setting at a time, and keep a way back. These checks do not imply that every issue is fixed or that every game is compatible.

## Before changing anything

- Record the Kestrel version, macOS version, Mac model/RAM, instance, Android image, renderer, guest resolution, and the exact error. Distinguish first boot, cold boot, and snapshot resume.
- Save work in Android before stopping or restarting an instance. A restart can lose unsaved app state.
- Preserve the current emulator log **before retrying a launch**: the launcher opens a fresh log for the new process. See [logs and reporting](#logs-and-reporting).
- Back up stopped instances before changing graphics settings, restoring snapshots, replacing data, or attempting recovery. Do not delete a VM or reinstall a game as a first diagnostic step.
- Do not disable Gatekeeper globally, weaken input/focus/timeout guards, expose emulator control ports, or share authentication keys to make a test pass.

## Installation: macOS refuses to open the app

**Symptom:** macOS reports an unidentified developer, cannot verify the developer, or says the app is damaged.

**Checks**

1. Confirm the download or locally built bundle is from a source you trust. Keep the exact macOS message: an unverified developer warning is not the same as a corrupt bundle or a malware alert.
2. For an ad-hoc-signed build, do not interpret the signature as Developer ID notarization or proof of publisher identity. A locally signed app can still trigger Gatekeeper.
3. Check that the app bundle was copied intact. Editing files inside a signed bundle can invalidate its signature.

**Safe recovery**

- For a trusted app that macOS merely blocks as unverified, use macOS's per-app approval in **System Settings → Privacy & Security → Open Anyway**, if offered, and review the confirmation. Do not use a global Gatekeeper disable or blanket quarantine removal.
- For a damaged, modified, revoked, or malware-flagged bundle, stop and obtain a fresh trusted copy or ask the maintainer to check packaging. Do not bypass the warning by blindly re-signing it.
- Replacing the application is different from deleting instance data. Preserve the Kestrel data directory described under [backups](#recovery-and-backups).

## Setup: SDK missing, wrong path, or license failure

**Symptom:** setup repeats, the emulator or `adb` is missing, or startup says the system image is not installed.

**Checks**

1. Check which SDK root the app is using. Setup prefers `ANDROID_SDK_ROOT`, then `ANDROID_HOME`, otherwise `~/Library/Android/sdk`. A Finder-launched app need not inherit your terminal's environment.
2. The required components are the Android emulator, platform-tools (`adb`), and the default Android 16 Google Play ARM64 image: `system-images;android-36;google_apis_playstore;arm64-v8a`. An instance configured with a different image needs that exact image installed too.
3. Read the setup error for missing Java, command-line tools, permissions, download failure, or licensing. Setup looks for `sdkmanager` under the SDK's command-line tools, Homebrew, and `PATH`.
4. The optional NDK is for building `touchd` from source; it is not a substitute for the required emulator/image packages.

**Safe recovery**

- Correct the intended SDK location and use **Check Again**. Do not copy unrelated SDK directories over each other or delete existing AVDs.
- Use **Download and Set Up** only when you intend to install the missing SDK components. The setup implementation accepts Android SDK licenses on your behalf and can install command-line tools/Java through Homebrew; review the applicable terms before proceeding.
- If license or installation errors persist, retain the error and resolve the SDK manager/Java/path problem rather than suppressing checks or repeatedly starting a partially installed instance.

Sources: [SDK setup and license handling](../../Sources/KestrelCore/Setup.swift), [setup UI](../../Sources/KestrelApp/Sheets.swift), [image validation at launch](../../Sources/KestrelCore/Launcher.swift).

## Startup: acceleration, RAM pressure, or disk exhaustion

**Symptom:** emulator exits immediately, Android becomes unresponsive, or launch reports acceleration/storage errors.

**Checks**

1. Read the launch log for the first failure, not just the final exit message. Kestrel requests hardware acceleration with `-accel on`; there is no explicit host Hypervisor.framework preflight in the inspected launcher.
2. Check macOS Activity Monitor for memory pressure and competing VMs/heavy workloads. Presets aim to reserve two CPU cores and 4 GB of RAM for macOS, but that is not a guarantee against pressure.
3. Check free space on the volumes holding both the SDK and Kestrel data. A configured guest data-partition size is not proof that the host has sufficient free space.
4. New Google Play instances have a 3072 MB memory floor because an Android 16 Play instance with 2 GB showed a system-not-responding dialog. Reducing RAM below a useful guest budget is not a safe universal fix.

**Safe recovery**

- Close unrelated heavy workloads, stop other VMs gracefully, and retry one instance. If the log reports hardware-acceleration failure, resolve the supported host/runtime configuration instead of assuming a software-rendering switch fixes virtualization.
- Adjust CPU/RAM using instance settings, then restart. Stay within validated settings and leave room for macOS.
- Free host space using files you know are disposable, not unknown guest disk/snapshot files. Back up first if instance storage is involved.
- Do not shrink or truncate a guest disk to match a smaller setting: Kestrel preserves existing userdata capacity rather than reducing it.

Sources: [launch arguments](../../Sources/KestrelCore/Launcher.swift), [host-aware presets](../../Sources/KestrelCore/Presets.swift), [settings validation](../../Sources/KestrelCore/Settings.swift), [Play-image memory floor](../../Sources/KestrelCore/Setup.swift), [disk-capacity handling](../../Sources/KestrelCore/DiskCapacity.swift).

## Startup: stuck boot or snapshot will not resume

**Symptom:** launch never becomes ready, a named snapshot is missing, or resume behaves like a fresh boot.

**Checks**

1. Separate normal **Start** (quick-boot resume), an explicit cold boot, and loading a named snapshot. Do not describe a rejected snapshot as a successful resume.
2. Check the image is installed and the selected snapshot exists. A missing named snapshot fails before launch; the launcher does not silently fall back to a cold boot for that error.
3. Check the preserved log for snapshot rejection, emulator exit, guest boot delay, or storage problems. Android's `boot_completed` alone does not establish that graphics or gameplay are responsive.

**Safe recovery**

- Save work and stop the instance normally. After preserving the log and backing up, try an explicit cold boot to bypass quick-boot loading without wiping Android userdata.
- If a named snapshot is unavailable, choose an existing snapshot deliberately or use a normal/cold start. Do not fabricate snapshot folders or force-load an unrelated instance's state.
- Restoring a snapshot can return guest state to an earlier point. Keep a stopped-instance backup before trying it; a snapshot is not an independent backup of the VM.
- If cold boot also fails, investigate the first launch error instead of deleting the instance or extending readiness timeouts indefinitely.

Sources: [startup modes and errors](../../Sources/KestrelCore/Launcher.swift), [snapshot validation](../../Sources/KestrelCore/Snapshots.swift), [diagnostic comparison limits](../../diagnostics/README.md).

## Black frame: Android versus a specific game

**Symptom:** the player is black, or Android is visible but BGMI renders a black game scene.

**Checks**

1. Determine whether Android's launcher/settings render, whether the player displays any fresh frames, and whether the failure begins only inside the game. A boot-success message is not a rendered-frame test.
2. Record the renderer, image/emulator versions, guest resolution, game version and scene. Do not attribute a game-only black frame to the video transport without evidence.
3. For BGMI, consult the [BGMI graphics case study](../research/bgmi-case-study.md), including the **guest ANGLE workaround** and its evidence limits. Guest ANGLE selection is a different layer from changing the emulator's host renderer.

**Safe recovery**

- If all frames stop, follow [streaming checks](#video-freezes-or-the-frame-stream-disconnects) first.
- For the BGMI-specific workaround, preserve the original configuration and follow the scoped case-study procedure only if your symptom/environment matches. Do not apply it globally to all games or improvise game-file modifications.
- Change one variable at a time and inspect the actual rendered result. Revert an ineffective change. Neither boot completion nor a synthetic graphics report proves BGMI gameplay works.

Sources: [BGMI case study](../research/bgmi-case-study.md), [diagnostics methodology and limitations](../../diagnostics/README.md), [native frame session](../../Sources/KestrelPlay/NativePlayerSessionController.swift).

## Video freezes or the frame stream disconnects

**Symptom:** a previously updating image freezes, or video stops with a timeout/stream-ended error.

**Checks**

1. Record whether Android and the emulator process are still running, the visible error, and how long the stream ran before failing.
2. The native player renews an expected bounded streaming RPC timeout only after it has run for at least 29 seconds. An earlier timeout is rethrown; a stream ending before that threshold is unexpected.
3. Distinguish this renewal behavior from a crash or repeated early failures. A periodic RPC deadline is not by itself a reason to change VM settings.

**Safe recovery**

- Allow the existing renewal logic to handle the expected deadline. For a persistent freeze, preserve the error/log and end/reopen the player through normal controls; save guest work first if this requires restarting the instance.
- Do not remove deadlines, treat every disconnection as successful renewal, or expose the local control endpoint to work around a failure. Report repeatable early failures with timing information.

Source: [native player renewal and failure handling](../../Sources/KestrelPlay/NativePlayerSessionController.swift).

## Keymapping: keys or mouse do nothing

**Symptom:** a loaded keymap does not move the character, the mouse does not look around, or a click is not delivered to the game.

**Checks**

1. Enable Kestrel under **System Settings → Privacy & Security → Accessibility** when prompted. Keymapping reports an error rather than starting without this permission.
2. Ensure Kestrel is active, the player is the key window, and the game view has focus. Close sheets and the mapping popover; a hidden/minimized view or another responder is not gameplay focus.
3. Check the selected keymap and its look-mode/free-cursor bindings. Look mode directs mouse motion to camera control; normal pointer touches are suppressed while effective look mode is active.
4. Compare the mapped touch locations with the current in-game HUD and guest resolution. For BGMI, use the [bundled layout guidance](../guide/bgmi-layout.md); a valid keymap is not proof the HUD matches.

**Safe recovery**

- Grant the required permission, return to the player, and retry mapping. If macOS requires reopening the app, save work first.
- Use the configured look toggle or free-cursor binding rather than guessing a universal shortcut. Return to free-cursor mode to use normal pointer clicks.
- Close configuration UI, click the game view to restore focus, then test one harmless action. Never bypass the active-focus checks or capture global input indiscriminately.

Sources: [Accessibility requirement](../../Sources/KestrelPlay/KeymapSession.swift), [focus gate](../../Sources/KestrelPlay/NativePlayerSessionController.swift), [look and pointer behavior](../../Sources/KestrelKeymap/Engine.swift).

## Mapping popover: controls work, but game clicks stop

**Symptom:** opening mapping controls releases the cursor or stops gameplay input.

**Checks:** This is intentional separation, not necessarily lost input. Opening the mapping popover blocks gameplay, suspends the session, resets input, and unlocks the cursor. UI clicks must not also become game touches.

**Safe recovery:** Finish changing the control, close the popover, and restore focus to the game view. If a slider/button click reaches the game while the popover is open, report that as an input-isolation bug. Do not disable the block as a workaround.

Sources: [popover lifecycle](../../Sources/KestrelPlay/PlayerWindowController.swift), [input suspension/reset](../../Sources/KestrelPlay/PlaySession.swift).

## Mapping hints: invisible or missing in fullscreen

**Symptom:** mappings work but their on-screen labels are missing or too faint.

**Checks:** Check that hints are enabled and their opacity is above zero. The opacity control is clamped to 0–1; zero intentionally hides the hints. Native hints are attached to the player's Space as fullscreen auxiliary windows, not global always-on-top windows.

**Safe recovery:** Increase opacity, restore player focus, and compare windowed versus fullscreen behavior. If labels appear only in one mode, report the display/Space arrangement and a redacted screenshot. Do not grant unrelated permissions or make overlays capture clicks to fix visibility.

Sources: [hint opacity](../../Sources/KestrelPlay/PlayerWindowController.swift), [fullscreen overlay placement](../../Sources/KestrelPlay/PlaySession.swift), [player hints](../../Sources/KestrelPlay/PlayerKeymapOverlay.swift).

## Joystick: short movement, wrong direction, or sprint fails

**Symptom:** movement activates the wrong location, only walks, or never reaches the game's sprint threshold.

**Checks**

1. Match the joystick center and radius to the visible in-game joystick/HUD. Check the selected scheme and guest resolution before changing movement scales.
2. Joystick travel multiplies the radius. Walk and sprint modifiers then affect displacement; sprint defaults to a 1.6 multiplier when no explicit scale is supplied.
3. Check whether the walk key is also held. Both walk and sprint scales can apply, so an overlapping modifier can reduce the expected travel.

**Safe recovery:** Save a copy of the keymap, adjust travel/radius or bindings one at a time, and test in a safe practice scene. Increased touch travel is not a guaranteed sprint command: the game's HUD and movement rules still determine the result. Revert changes that overshoot or hit another control.

Sources: [joystick displacement](../../Sources/KestrelKeymap/Engine.swift), [mapping model](../../Sources/KestrelKeymap/Keymap.swift), [BGMI HUD guidance](../guide/bgmi-layout.md).

## Typing: rejected text, partial entry, or timeout

**Symptom:** text is rejected, stops partway through, or fails after switching focus.

**Checks**

1. The native text request supports printable ASCII only: U+0020–U+007E, at most 256 UTF-8 bytes per request. Empty text, unsupported characters, and larger requests are rejected. Emoji and non-ASCII scripts are not supported by this path.
2. Focus evidence is short-lived (0.5 seconds by default), and submission requires a current permit. Delayed observations, focus changes, and cancellation can invalidate it intentionally.
3. Individual key RPCs have a two-second deadline and do not wait for readiness. Characters are sent as ordered keypresses, not shell input. Cancellation can stop subsequent characters but cannot undo a character already sent.
4. Bounded command helpers also reject invalid timeouts and terminate timed-out children. A timeout is a failure signal, not permission to queue input indefinitely.

**Safe recovery**

- Focus the intended Android text field, inspect what actually arrived, and retry a short harmless ASCII sample. Do not repeatedly resend an entire message when some characters may already be present.
- Use the guest's normal input method for characters outside this native path, if available. Avoid testing with passwords, authentication codes, or private messages.
- Keep focus, cancellation, character/size, and timeout guards intact. Do not loosen them or replace the path with shell-text injection to make a test pass. Report the error and a non-sensitive example instead.

Sources: [text bounds and RPC policy](../../Sources/KestrelStream/EmulatorKeyboardRequest.swift), [ordered dispatch and cancellation](../../Sources/KestrelStream/EmulatorFrameClient.swift), [focus permits](../../Sources/KestrelPlay/PlayerKeyboardFocusCoordinator.swift), [bounded process execution](../../Sources/KestrelCore/PlayerKeyCommand.swift).

## Sound: no playback or wrong output device

**Symptom:** game/Android sound is silent even though video works.

**Checks**

1. Confirm **Sound** is enabled in instance settings. Disabled sound adds `-no-audio` to launch arguments; changing the setting requires an instance restart to affect the running emulator.
2. Check ordinary routing: the game's own audio settings, Android media volume/mute, macOS output volume/mute, and the selected speakers/headphones/Bluetooth device.
3. Separate playback from microphone capture. A working speaker path does not establish that voice chat can record.

**Safe recovery:** Correct the ordinary guest/host routing, save work, and restart the instance after a setting change. A user reported sound working after a restart, but the audio root cause remains **unproven**. This is not evidence of a universal audio fix, nor proof that one particular routing change caused recovery.

Sources: [audio launch flags](../../Sources/KestrelCore/Launcher.swift), [Sound setting](../../Sources/KestrelApp/InstanceDetail.swift), [restart notice](../../Sources/KestrelApp/AppModel.swift).

## Microphone / voice chat (0.1.8): others cannot hear you

**Symptom:** playback works, but a recording app or voice chat receives silence.

**Checks**

1. In the 0.1.8 microphone feature, host microphone forwarding is **opt-in**, not enabled merely by turning on sound. Enable **Sound**, then **Microphone (voice chat)** in instance settings. The microphone toggle is disabled when Sound is off.
2. The launcher emits `-allow-host-audio` only when sound is enabled and `microphone == true`. With forwarding off, the settings contract describes recording input as silence.
3. Check **System Settings → Privacy & Security → Microphone** for the host process macOS asks you to authorize. Do not grant access to unrelated software. Also check the selected host input device and its input level.
4. Inside Android, grant microphone permission to the intended app when requested (or review its app permissions), and check the game's voice-channel/mute settings. Kestrel's host forwarding toggle does not grant Android app permissions.

**Safe recovery:** Save work, change only the required permissions/settings, and restart the instance after changing microphone forwarding. Test deliberately with a trusted recording app or willing voice-chat participant, then disable forwarding if no longer needed. Microphone access is a privacy-sensitive opt-in.

**Evidence limit:** The feature has reported unit-test/build verification, not proof of actual end-to-end voice capture or a successful in-game voice call. This documentation pass did not run those checks or record audio. Do not report voice chat as verified solely because the toggle appears or the launch flag is present.

Sources: [microphone default and dependency](../../Sources/KestrelCore/Settings.swift), [launch argument gate](../../Sources/KestrelCore/Launcher.swift), [UI and restart guidance](../../Sources/KestrelApp/InstanceDetail.swift).

## Recovery and backups

**Symptom:** you need to preserve an instance before a risky change, or recover from a failed experiment.

**Checks:** Kestrel data defaults to `~/Library/Application Support/Kestrel`, or the configured `KESTREL_HOME`. Its layout includes:

| Relative path | Purpose |
| --- | --- |
| `instances/<index>/settings.json` | Instance settings |
| `instances/<index>/emulator.log` | Emulator launch output |
| `avd/kestrel-<index>.avd/` | Guest disks and instance snapshot data |
| `avd/kestrel-<index>.ini` | AVD descriptor |
| `keymaps/` | Saved keymaps |

**Safe recovery**

1. Save guest work, stop the instance normally, and ensure it is stopped before copying its files. Do not take a casual file-copy backup of disks while the VM is writing to them.
2. Copy the complete Kestrel data root to a private backup location with sufficient space. Record the original root location, app/emulator/image versions, and date. A full root copy helps preserve the relationship between settings, keymaps, AVD descriptors, disks, and snapshots; protect it as personal data.
3. Keep the original and backup until recovery is validated. Do not blindly merge individual disk/snapshot files or overwrite a running instance. Relocating a backup may require path review; a file copy alone is not proof of a bootable restore.
4. Prefer reverting the last documented setting or trying a cold boot over wiping userdata. If replacing data becomes necessary, stop Kestrel first and obtain a recovery plan for the exact backup/version rather than guessing.
5. Kestrel uses its own AVD home. Do not delete `~/.android/avd` or another emulator's profiles while repairing Kestrel.

There is no backup/export workflow established by the inspected source; these are conservative file-preservation precautions, not a claim of a tested restore feature. Snapshots inside an AVD can be lost with that AVD and are not a separate backup.

Sources: [storage layout](../../Sources/KestrelCore/Instance.swift), [snapshot storage](../../Sources/KestrelCore/Snapshots.swift), [stop and log lifecycle](../../Sources/KestrelCore/Launcher.swift).

## Logs and reporting

**Symptom:** the safe checks above do not resolve the issue, or a failure needs maintainer investigation.

**Checks and safe reporting**

- Preserve `instances/<index>/emulator.log` under the effective Kestrel data root before another launch. The launcher directs emulator stdout/stderr there and recreates the file for a new launch.
- Provide the exact visible error, version/environment details, the smallest reproduction, and whether the failure occurs on cold boot, quick boot, or a named snapshot. Include recent settings changes and whether they were applied by a restart.
- For input issues, include a harmless example and whether the player was active, the mapping popover open, look mode enabled, or a text field focused. For rendering, include a redacted screenshot and whether Android outside the game renders.
- Share only the minimal relevant log excerpt. **Redact authentication keys/tokens, authorization headers, emulator control credentials, account identifiers, email addresses, personal paths, private messages, and other personal data.** Do not upload raw credential files, a whole VM backup, or private game/account content.
- Logs and screenshots can reveal personal information even when they look technical. Review them before sharing; keep timestamps and error wording where safe.
- If measurements are needed, follow the [diagnostics protocol](../../diagnostics/README.md) with isolated profiles and explicit consent. Its GLES capability report is not a conformance test; Canvas scheduling cadence is not presented game FPS; guest event age is not host-input-to-photon latency. Do not turn a diagnostic result into an unsupported compatibility/performance claim.

## Verification scope of this guide

The implementation links support the described checks and safeguards. This guide was prepared by reading source and existing documentation only: no commands, tests, builds, network operations, game/VM changes, microphone capture, or runtime reproduction were performed for it. Installation approval behavior depends on macOS and the particular distribution. The sound restart report and microphone unit/build status are reported evidence, not newly reproduced outcomes. Use the linked BGMI case study for that workaround's scope and current limitations.
