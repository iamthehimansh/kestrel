# Kestrel — open-source Android gaming emulator for Apple Silicon Macs

An Android gaming environment for Apple Silicon Macs, with keyboard/mouse controls and a native Metal player. Kestrel manages Google's Android Emulator and adds instance management, editable keymaps and documented research. Kestrel itself requires no account; games and Google Play may require their own accounts.

> **Preview release.** Kestrel works and is actively used for games such as BGMI, but it is young. The app is ad-hoc signed (not notarized), the Android SDK is downloaded on first run rather than bundled, and game compatibility varies. Read [Compatibility](docs/guide/compatibility.md) before you rely on it.

![Platform](https://img.shields.io/badge/platform-macOS%20Apple%20Silicon-black) ![Swift](https://img.shields.io/badge/Swift-6.2-orange) ![License](https://img.shields.io/badge/license-MIT-blue) ![Status](https://img.shields.io/badge/status-preview-yellow)

![BGMI gameplay in Kestrel's native macOS player with keyboard hints and the right-hand control sidebar](docs/assets/bgmi-gameplay.png)

*Maintainer-provided gameplay screenshot. The bottom identifier strip was cropped for privacy; this demonstrates this session rendering, not universal game compatibility.*

## Download

Get the latest `Kestrel-<version>.dmg` from [Releases](https://github.com/iamthehimansh/kestrel/releases), open it and drag **Kestrel** to Applications. The first time, macOS will say it cannot verify the developer: open **System Settings → Privacy & Security** and click **Open Anyway**. Full walkthrough: [Getting started](docs/guide/getting-started.md).

## Features

- **Native player window** — Android frames are streamed over an authenticated local gRPC connection and drawn with Metal, with a sidebar for Back, Home, Recents, volume, rotate, screenshot and keyboard.
- **Keymapping for games** — WASD joystick, mouse-look aiming, taps, swipes, skills, macros and gamepad buttons, with presets for BGMI/PUBG Mobile, Free Fire, Call of Duty: Mobile, Genshin Impact, MLBB, Clash of Clans, Asphalt and Subway Surfers.
- **Live keymap editor** — drag controls over the running game, press a key to rebind, `[` `]` to resize a joystick ring and `Shift+[` `Shift+]` to change how far it actually pushes. Turn mapping on/off and set hint visibility (0–100%) from the sidebar.
- **Typing** — when an Android text field is focused, your Mac keyboard types into it and game keys step aside (ASCII for now).
- **Microphone** — optional per-instance switch to pass your Mac microphone to Android for voice chat.
- **Multiple instances** — create, clone, snapshot and restore; choose CPU, RAM, resolution, DPI, renderer, Vulkan and device profile.
- **Google Play** — instances use Google's official Play Store system image; sign in with your own account like on a phone. APKs install by drag and drop.
- **Command line** — everything is scriptable through the `kestrel` CLI.

## Requirements

| | |
|---|---|
| Mac | Apple Silicon (arm64). Intel Macs are not supported. |
| macOS | 15 or later for the native player (the core tools build for macOS 13+). |
| Disk | Several GB for the Android SDK and system image, plus space for each instance. |
| Permissions | Accessibility (for keymapping), Microphone (only if you turn it on). |

## Quick start

1. Install from the DMG and open Kestrel.
2. Let it download the Android SDK and Google Play system image (it accepts the SDK licences on your behalf; you can review them in Android Studio's SDK manager).
3. Create an instance, start it, and sign in to Google Play inside Android.
4. Install a game, pick its keymap in **Controls**, and press **Play**.

**BGMI:** use **Character control option 3** (fixed movement + fixed fire), import HUD code **`1-7685-6236-0319-5283-780`**, and select Kestrel's `bgmi` preset. See the [matching-layout guide](docs/guide/bgmi-layout.md) for setup and limitations.

Command-line equivalent:

```sh
kestrel setup
kestrel create --name Main --preset high
kestrel start 0 --wait
kestrel playstore 0 com.pubg.imobile
kestrel play 0 --keymap bgmi
```

## Documentation

| Guide | What it covers |
|---|---|
| [Getting started](docs/guide/getting-started.md) | Install, first launch, SDK download, first instance, data location |
| [User guide](docs/guide/user-guide.md) | Player window, sidebar, keymapping, editor, typing, microphone, snapshots, settings, CLI |
| [Compatibility](docs/guide/compatibility.md) | What is tested, what is user-reported, known limits |
| [Architecture](docs/guide/architecture.md) | How the emulator, gRPC streaming, Metal player, touch injection and keymap engine fit together |
| [Building](docs/guide/building.md) | Build, test, package and release from source |
| [Research](docs/research/README.md) | Every experiment, including the failed ones, and case studies (BGMI graphics, audio, detection surface) |

## Build from source

```sh
brew install protobuf
git clone https://github.com/iamthehimansh/kestrel.git && cd kestrel
PROTOC_PATH=/opt/homebrew/bin/protoc swift test --jobs 1
export KESTREL_VERSION=0.1.8 PROTOC_PATH=/opt/homebrew/bin/protoc
bash scripts/build-app.sh                       # build/Kestrel.app
SKIP_APP_BUILD=1 bash scripts/build-dmg.sh        # build/Kestrel-0.1.8.dmg
bash scripts/verify-release.sh
```

Needs Xcode with Swift 6.2. Details and troubleshooting: [Building](docs/guide/building.md).

## How it was built

Kestrel was created and vibe-coded with [Cana.build](https://cana.build) using its **REA mod**, which is based on the open-source [REA](https://github.com/morluto/rea) reverse-engineering toolkit. REA was used to study how existing Mac Android emulators are put together — graphics transport, input, settings and performance — so that Kestrel could re-implement the useful ideas as original code on top of Google's open-source emulator. No proprietary binaries, decompiled source or restricted Android images are included in this repository; the [research notes](docs/research/README.md) publish findings, measurements and reproducible methods instead.

Every change was driven by an experiment with a recorded hypothesis, method and result, and the [experiment ledger](docs/research/experiment-ledger.md) keeps the rejected approaches alongside the ones that shipped.

## Contributing

Contributions are welcome — new game keymaps, bug reports with logs, docs, tests and performance measurements are all useful. Start with [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). Security issues: see [SECURITY.md](SECURITY.md).

## Limitations

- Not notarized; macOS shows a warning on first open.
- Android SDK and system image are downloaded, not bundled.
- Typing supports ASCII only.
- Some games block emulators. Kestrel does not modify games or bypass anti-cheat.
- Performance and compatibility vary by game; no parity with commercial emulators is claimed.

## Credits

- Google's [Android Emulator](https://developer.android.com/studio/run/emulator) and Android SDK — the external runtime Kestrel drives. Components have their own licenses and SDK download terms; not every SDK/image component is Apache-2.0 licensed.
- [grpc-swift](https://github.com/grpc/grpc-swift), [swift-protobuf](https://github.com/apple/swift-protobuf) and the other dependencies listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- [Cana.build](https://cana.build) and the [REA](https://github.com/morluto/rea) project, used to research and build Kestrel. Mentioning them does not imply their endorsement.

Kestrel is not affiliated with Google, Krafton, Tencent, NetEase or any game publisher or emulator vendor. Game names are trademarks of their owners.

## License

MIT for Kestrel's original code — see [LICENSE](LICENSE). Third-party components keep their own licences; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
