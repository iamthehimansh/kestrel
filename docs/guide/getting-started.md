# Getting started

Kestrel is an Apple Silicon Android emulator manager and native gaming player. It uses an Android Emulator installation on your Mac; the preview DMG does **not** contain Android or the SDK.

## Requirements

| Component | Requirement |
|---|---|
| CPU | Apple Silicon, arm64 |
| macOS | 15+ for the native player; the package/app deployment floor is 13 |
| Disk | Several GB for SDK/image downloads, plus guest data and snapshots |
| Memory | Leave room for macOS and the guest; Google Play profiles use at least 3 GiB |
| SDK | Android Emulator, platform-tools and the configured arm64 Google Play system image |
| Build tools | Xcode with Swift 6.2 and protobuf, only when building from source |

On macOS 13/14, Kestrel uses the Android Emulator's own window instead of the native streaming player. This fallback does not establish full feature parity with the macOS 15+ path.

## Install the preview

1. Download the DMG and checksums from [GitHub Releases](https://github.com/iamthehimansh/kestrel/releases).
2. Verify the checksum if desired, open the DMG, and drag **Kestrel** to **Applications**.
3. Open Kestrel. Preview builds are ad-hoc signed, not Developer ID signed or notarized. If macOS blocks launch, use its per-app **System Settings → Privacy & Security → Open Anyway** flow only after checking the source of the download. Wording varies by macOS release.
4. Do not globally disable Gatekeeper. If there is no per-app approval option, collect the exact message and consult [troubleshooting](../support/troubleshooting.md).

Updating the app does not intentionally replace your stored profiles or custom keymaps. Stop instances and keep a data backup before updating.

## Install or reuse Android components

The welcome screen provides **Download and Set Up** and **Check Again**. An existing SDK is reused. The command-line equivalents are:

```sh
kestrel setup --check
kestrel setup
```

The current setup requests:

- `emulator`
- `platform-tools`
- `system-images;android-36;google_apis_playstore;arm64-v8a`
- Optionally `ndk;27.1.12297006` with `--with-ndk`, for building the touch helper.

SDK discovery checks `ANDROID_SDK_ROOT`, then `ANDROID_HOME`, then `~/Library/Android/sdk`. Shell environment variables may not be inherited by an app opened from Finder.

Setup searches for `sdkmanager` in SDK command-line tools, Homebrew locations and `PATH`. If missing, it can install Temurin and Android command-line tools with Homebrew. If Homebrew itself is absent, setup asks for it rather than silently installing a package manager.

**License behavior:** setup invokes `sdkmanager --licenses` and feeds affirmative answers. This accepts the Android SDK licenses on your behalf. If you want to review/accept them manually, provision the packages yourself with Android Studio or `sdkmanager`, then use **Check Again**. Kestrel's MIT license does not replace Google's terms for SDK tools or Play images. See [third-party notices](../../THIRD_PARTY_NOTICES.md).

Source of truth: [Setup.swift](../../Sources/KestrelCore/Setup.swift).

## Create and start an instance

Choose **New Instance** or Command-N, give it a name, select a performance preset and screen size, and create it. The suggested CPU/RAM values depend on the host. They are resource choices, not measured game-performance guarantees.

Start the instance and wait for Android to finish booting. Initial boot may take longer than snapshot resume. Do not repeatedly press Start or kill the process while Android is initializing. A **Cold Boot** option is available when a saved state is unsuitable.

In **Apps**, use **Google Play** to open the Play Store, or enter a package name and choose **Open Page**. You sign in directly inside Android with your own Google account; Kestrel has no separate account. You can also use **Install APK…** or drop APK files into the app while the instance is running. Obtain apps from sources you trust.

## Set up controls

Select a preset in **Controls**, open the player and use the right-rail keymapping control. Grant Accessibility only when you want keyboard/mouse mapping. Native direct pointer input and game mappings are different paths; see the [user guide](user-guide.md).

For BGMI, first use the [matching HUD guide](bgmi-layout.md): **Character option 3**, fixed movement/fixed fire, and the supplied layout share code. A bundled keymap is not proof that its touch coordinates match every HUD or game version.

## Microphone and voice chat

In instance settings, enable **Sound** and then **Microphone (voice chat)** if needed. Microphone passthrough defaults off and takes effect at the next instance start. Android's app permission and the game's own voice-chat settings also matter. macOS may require permission for the process responsible for capture; do not assume every prompt is attributed to the Kestrel manager.

The launch flag and settings behavior are tested; actual microphone capture/game voice chat was not verified for the first public preview. Do not enable it merely to troubleshoot playback sound.

## Data and backup

Default data root:

```text
~/Library/Application Support/Kestrel/
  instances/<index>/     settings, logs and recordings
  avd/kestrel-<index>.avd/  Android disks and snapshots
  keymaps/               personal mappings overriding bundled presets
```

The CLI supports `KESTREL_HOME` for isolated data roots. **Show Data in Finder** opens the instance location.

To back up, stop all instances, quit Kestrel, and copy the entire data root to a separate location. The app bundle alone is not a game-data backup. **Duplicate/clone copies settings, not installed apps or userdata.** Deleting an instance removes its Android data, apps and snapshots; it is not an undoable action.

Next: [User guide](user-guide.md) · [Compatibility](compatibility.md) · [Building](building.md) · [FAQ](faq.md).
