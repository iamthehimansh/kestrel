# Kestrel

An open-source Android gaming emulator for Apple Silicon Macs. No account, no login, no telemetry.

Kestrel is a clean-room project built only on open-source parts. It contains no code, binaries or Android images from any commercial emulator. `REPORT.md` is a separate research note on how commercial Mac Android emulators are put together; nothing in Kestrel is copied from them.

## What it is built on

| Layer | Kestrel |
|---|---|
| Virtual machine | Google's open-source Android Emulator (QEMU, accelerated by Apple's Hypervisor.framework) |
| Graphics | gfxstream → ANGLE → MoltenVK → Metal, shipped with the Android Emulator |
| Android | Official Android SDK system images (Android 16 arm64 with Play Store by default) |
| Instances, settings, presets | `kestrel` CLI and `KestrelCore` |
| Game controls | `KestrelKeymap` engine + on-device `touchd` injector + `kestrel play` |
| Account | None |

## Requirements

- An Apple Silicon Mac on macOS 13 or later
- Swift 5.10+ (Xcode or the command line tools)
- [Homebrew](https://brew.sh), if you don't already have the Android SDK. `kestrel setup` does the rest:

```sh
kestrel setup            # downloads the emulator, adb and the Android 16 Google Play image (several GB)
kestrel setup --check    # shows what is installed
kestrel setup --with-ndk # also installs the NDK, only needed to rebuild touchd
```

`kestrel setup` accepts the Android SDK licences for you. If you already have Android Studio's SDK in `~/Library/Android/sdk`, it is reused.

## Build

```sh
swift build -c release
./touchd/build.sh            # builds the on-device touch injector
```

## Quick start

```sh
kestrel create --name Main --preset high --resolution tablet-1920x1080
kestrel start 0 --wait
kestrel install 0 game.apk
kestrel open 0 com.pubg.imobile
kestrel play 0 --keymap bgmi
```

`kestrel play` needs the macOS Accessibility permission for your terminal app (System Settings → Privacy & Security → Accessibility). It only reads keys while the emulator window is in front.

## Google Play

New instances use Google's official **Google Play** system image, which already contains the Play Store and Google Play services. There is no Kestrel account; to install apps you sign in to your own Google account inside Android, exactly as on a phone:

```sh
kestrel start 0 --wait
kestrel playstore 0                       # opens the Play Store; sign in the first time
kestrel playstore 0 com.dts.freefireth    # opens one app's page
```

Google Play instances get at least 3 GB of RAM, because a 2 GB instance stalled right after boot in testing. APKs from outside the Play Store still install with `kestrel install 0 game.apk`.

## Game controls

Keymaps are JSON files in `keymaps/`. Coordinates are normalized (0 to 1), so one keymap works at any resolution. Bundled presets:

| File | Game |
|---|---|
| `bgmi.json` | BGMI / PUBG Mobile |
| `freefire.json` | Free Fire |
| `codm.json` | Call of Duty: Mobile |
| `genshin.json` | Genshin Impact |
| `mlbb.json` | Mobile Legends: Bang Bang |
| `clash-of-clans.json` | Clash of Clans (strategy) |
| `asphalt.json` | Asphalt (racing) |
| `subway-surfers.json` | Subway Surfers (runner) |

Button positions are estimates of each game's default layout. If your HUD differs, move them in the visual editor (below).

### Control types

| Type | What it does |
|---|---|
| `tap` / `fire` | Holds a touch while the key is held |
| `turbo` | Taps repeatedly while held (`intervalMs`) |
| `joystick` | WASD and/or a gamepad stick drag a virtual stick. Optional walk (slower) and sprint (past the edge) modifiers |
| `look` / `aim` | Mouse-look: relative mouse motion drags a finger and re-centres at the edge, so turning never runs out. Optional scope key with lower sensitivity and right-stick support |
| `skill` | MOBA skill: holds the button and drags it toward the cursor. Optional cancel key and quick cast |
| `swipe` | One swipe per key press |
| `combo` | Several taps in sequence |
| `scroll` | Mouse wheel turned into a swipe |
| `pinch` | Two-finger zoom in/out |
| `macro` | A script (see below), optionally looping while held |

Any control can be limited to aim mode (`"mode": "look"`) or cursor mode (`"mode": "cursor"`). That is how left click fires while aiming but still clicks menus when the cursor is free.

Defaults: `` ` `` toggles mouse-look (cursor locked and hidden), holding `Alt` frees the cursor temporarily, and `F12` hides the on-screen key hints. The first two can be changed with `lookToggleKey` and `freeCursorKey`.

Gamepads that macOS supports (Xbox, PlayStation, MFi) work through the `Pad.A` … `Pad.Home` keys and the `stick` fields.

### Visual editor

```sh
kestrel keymap edit bgmi 0        # opens over a live screenshot of instance 0
kestrel keymap new my-game com.example.game
```

Drag a control to move it, double-click empty space to add a tap, select a control and press a key to rebind it, `[` / `]` shrink or grow a joystick/aim/skill radius, `⌫` deletes, `⌘S` saves. Bundled presets are never overwritten: your edited copy is saved to `KESTREL_HOME/keymaps` and takes priority.

### Macro language

```
tap 0.5 0.5                 # quick tap
press A 0.2 0.8             # finger A down
move A 0.3 0.8              # move finger A
release A                   # lift finger A
swipe 0.1 0.5 0.6 0.5 200   # swipe over 200 ms
wait 50                     # pause
repeat 3                    # repeat a block
  tap 0.9 0.9
end
```

### Record and replay

```sh
kestrel play 0 --keymap bgmi --record run.txt   # Ctrl-C saves the recording
kestrel replay 0 run.txt --keymap bgmi          # plays it back with the same timing
```

Recordings are plain text, one `<ms> <event>` line per input, so they can be edited by hand.

### Testing a keymap without a device

```sh
kestrel keymap check bgmi
kestrel keymap simulate bgmi keydown:W wait:50 keyup:W look:on mouse:40,0
```

## How touch injection works

`touchd` is a small static arm64 program pushed to `/data/local/tmp`. On images that allow it, it writes Linux multitouch (protocol B) events to the emulator's own touchscreen. Google Play images are locked down and refuse that, so there it creates its own virtual touchscreen ("kestrel-touch") through `/dev/uinput` and removes it when it exits. `kestrel play` keeps one `adb shell` open to it and streams `down`/`move`/`up` lines, so each event costs a pipe write rather than an adb round trip. Up to 10 fingers are supported.

## Commands

```
kestrel setup
kestrel list | create | clone | delete | info | config | start | stop | presets | images
kestrel playstore | install | uninstall | open | close | apps | shell | screenshot | adb | tap
kestrel keymap list | new | edit | show | check | simulate
kestrel play | replay
```

Data lives in `~/Library/Application Support/Kestrel` (override with `KESTREL_HOME`). Instances use their own AVD folder, so existing Android Studio emulators are left alone.

## Limits

- **FPS cap:** `fpsLimit` is stored as a setting but not enforced yet. The Android Emulator has no per-instance frame cap. Whether a game offers 90/120 fps is decided by the game, often from the device model (the `deviceBrand` / `deviceModel` settings).
- **Anti-cheat:** some games refuse to run on emulators. That is the game's choice; this project does not try to bypass it.
- **Guest architecture:** only arm64 guest images are supported, because Apple Silicon cannot virtualise x86.

## License

MIT. See `LICENSE`.
