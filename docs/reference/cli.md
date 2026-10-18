# Kestrel CLI reference

`kestrel` manages local Android emulator instances, applications, snapshots, and keyboard/mouse/gamepad mappings on macOS. This reference describes the checked-in command dispatcher and supporting implementations, not a transcript of commands run against a device.

## Invocation and conventions

```text
kestrel <command> [arguments] [options]
```

The app bundle contains the CLI at `Kestrel.app/Contents/Resources/bin/kestrel`. If the app is installed in `/Applications`, invoke it directly as:

```sh
/Applications/Kestrel.app/Contents/Resources/bin/kestrel --help
```

Examples below use `kestrel` as shorthand for that executable or a copy already on your `PATH`. The bundle layout does not by itself make the command available on `PATH`.

- `<i>` is an instance index, normally a nonnegative integer. Creation allocates the lowest unused index, from 0 through 51.
- `FILE`, `NAME`, and other uppercase words denote arguments, not literal values. Brackets denote optional arguments; do not type the brackets.
- Quote names containing spaces and JSON patches as shown in the examples.
- With no arguments, or with `help`, `-h`, or `--help` as the **first argument**, the CLI prints its command summary and exits successfully.
- There is no per-command help dispatcher. **Do not use `kestrel create --help` to ask for help:** it can create an instance, because `--help` is treated as an unused flag.
- Valued options use separate tokens: `--name "Game device"`, not `--name=Game`. A missing value is an error. Repeating a valued option keeps its last value.
- The small custom parser does not reject unknown `--flags`, and does not implement a `--` end-of-options marker. Only the options documented below have defined effects. A misspelled flag can therefore be silently ignored.

Sources: [command dispatcher and argument parser](../../Sources/kestrel/main.swift), [bundle layout](../../scripts/build-app.sh), [instance allocation](../../Sources/KestrelCore/Instance.swift).

## Environment and local storage

| Variable | Behavior |
| --- | --- |
| `KESTREL_HOME` | Kestrel data root. Defaults to `~/Library/Application Support/Kestrel`. Does **not** relocate the Android SDK. |
| `ANDROID_SDK_ROOT` | First runtime SDK candidate; first choice of SDK destination for `setup`. |
| `ANDROID_HOME` | Second runtime SDK candidate; setup destination when `ANDROID_SDK_ROOT` is unset. |
| `KESTREL_TOUCHD` | First candidate path for the guest touch helper used by `tap`, normal `play`, and normal `replay`. If not found there, helper discovery continues through bundled/build locations. |
| `KESTREL_SIM_WIDTH` | Integer screen width for `keymap simulate`; defaults to `1920` when absent or not an integer. |
| `KESTREL_SIM_HEIGHT` | Integer screen height for `keymap simulate`; defaults to `1080` when absent or not an integer. |

Runtime SDK discovery tries `ANDROID_SDK_ROOT`, `ANDROID_HOME`, `~/Library/Android/sdk`, then `/opt/homebrew/share/android-commandlinetools`, accepting the first candidate containing an executable `emulator/emulator`. This check does not establish that every SDK component is installed. `setup` instead chooses its destination from `ANDROID_SDK_ROOT`, then `ANDROID_HOME`, then `~/Library/Android/sdk`; it does not use the runtime Homebrew fallback as its default destination.

Most commands, including instance listing/configuration and `images`, require SDK discovery. Root help, `presets`, and keymap operations without an instance screenshot do not require a runtime SDK. `setup` can run before an emulator is installed. `keymap edit MAP 0` performs SDK discovery to obtain its optional screenshot.

Within the data root:

| Path | Contents |
| --- | --- |
| `instances/<i>/settings.json` | Persisted instance settings. |
| `instances/<i>/emulator.pid` | Recorded emulator PID used for running/stopped detection. |
| `instances/<i>/emulator.log` | Emulator stdout/stderr from launch. |
| `avd/kestrel-<i>.avd/` | Instance AVD, including guest data and snapshots. |
| `avd/kestrel-<i>.avd/config.ini` | Generated emulator configuration. |
| `avd/kestrel-<i>.ini` | AVD pointer file. |
| `keymaps/` | User keymap JSON files. |

A launched emulator receives Kestrel's `ANDROID_AVD_HOME`, the selected `ANDROID_SDK_ROOT`, and `ANDROID_EMU_VK_ICD=moltenvk`, overriding inherited values for those variables. Instance `i` uses console port `5580 + 2*i`, ADB port `5581 + 2*i`, and serial `emulator-<console-port>`. Running-state displays check the recorded PID; they are not Android boot-readiness checks.

```sh
KESTREL_HOME="$HOME/Kestrel-lab" kestrel list
ANDROID_SDK_ROOT="$HOME/Library/Android/sdk" kestrel setup --check
```

Sources: [paths and ports](../../Sources/KestrelCore/Instance.swift), [SDK discovery](../../Sources/KestrelCore/AndroidSDK.swift), [setup destination](../../Sources/KestrelCore/Setup.swift), [launch environment](../../Sources/KestrelCore/Launcher.swift), [helper discovery](../../Sources/KestrelPlay/TouchSink.swift), [simulation environment](../../Sources/kestrel/main.swift).

## Setup and discovery

### `setup`

```text
kestrel setup [--with-ndk]
kestrel setup --check
```

**Changes the host and can download several GB. Running installation authorizes automatic acceptance of Android SDK licenses.** There is no separate license-acceptance flag or interactive confirmation in Kestrel's implementation.

| Option | Effect |
| --- | --- |
| `--check` | Print selected SDK path and component status without installing. Exit 1 if a required component is missing, otherwise 0. This branch takes precedence over installation, including `--with-ndk`. |
| `--with-ndk` | Also install the optional NDK when missing. Without this flag, install only missing required components. |

| SDK package | Required | Purpose |
| --- | --- | --- |
| `emulator` | Yes | Android emulator. |
| `platform-tools` | Yes | ADB. |
| `system-images;android-36;google_apis_playstore;arm64-v8a` | Yes | Default Android 16 Google Play ARM64 image. |
| `ndk;27.1.12297006` | No | Building `touchd` from source. |

If all selected components are present, setup reports that everything is installed and returns without downloading. Otherwise it locates `sdkmanager` in the selected SDK, Homebrew locations, or `PATH`. If unavailable, it uses `/opt/homebrew/bin/brew` to install the `temurin` and `android-commandlinetools` casks; missing Homebrew is an error. Setup creates the SDK directory, supplies repeated `y` responses to `sdkmanager --licenses`, installs missing packages, and checks that the expected components now exist. The license subprocess's nonzero status is not checked separately; installation status and post-install presence are checked.

```sh
kestrel setup --check
# Installation below accepts SDK licenses and may install host tools:
kestrel setup
kestrel setup --with-ndk
```

Source: [setup implementation](../../Sources/KestrelCore/Setup.swift), [setup command](../../Sources/kestrel/main.swift).

### `images`

```sh
kestrel images
```

Print installed system-image IDs in sorted order. A discovered image must contain `system.img`. With no images, print an installation hint. This command does not download an image and does require a discoverable SDK.

Sources: [SDK image discovery](../../Sources/KestrelCore/AndroidSDK.swift), [command output](../../Sources/kestrel/main.swift).

### `presets`

```sh
kestrel presets
```

Print resolution presets, host-specific CPU/RAM recommendations for low/medium/high, and device brand/model pairs. It does not change settings or require an SDK.

| Resolution ID | Width × height | DPI |
| --- | --- | --- |
| `tablet-960x540` | 960 × 540 | 160 |
| `tablet-1280x720` | 1280 × 720 | 240 |
| `tablet-1600x900` | 1600 × 900 | 240 |
| `tablet-1920x1080` | 1920 × 1080 | 280 |
| `tablet-2560x1440` | 2560 × 1440 | 400 |
| `tablet-3840x2160` | 3840 × 2160 | 560 |
| `phone-720x1280` | 720 × 1280 | 320 |
| `phone-1080x1920` | 1080 × 1920 | 420 |
| `phone-1080x2400` | 1080 × 2400 | 420 |
| `phone-1440x3200` | 1440 × 3200 | 560 |

Performance starts from these CPU/RAM requests:

| Preset | vCPU request | RAM request (MB) |
| --- | --- | --- |
| `low` | 2 | 2048 |
| `medium` | 4 | 4096 on hosts with at least 16384 MB; otherwise 3072 |
| `high` | 6 on hosts with at least 10 cores; otherwise 4 | 12288 on hosts with at least 32768 MB; 6144 at 16384 MB; otherwise 4096 |
| `custom` | 4 | 4096 |

The algorithm caps CPU at `max(1, hostCores - 2)` and RAM at `max(1024, hostMemoryMB - 4096)`. **Creation then applies a 3072 MB minimum for Play images**, so a newly created low-preset Play instance is not necessarily assigned the RAM shown by `presets`.

The printed brand/model catalog contains `pixel9pro`, `galaxys24ultra`, `rog8`, `oneplus12`, and `xiaomi14`. These are not all valid `deviceIdentityPreset` values: that setting accepts only `galaxys24ultra`, `oneplus12`, and `xiaomi14`. A stored identity is configuration, not a guarantee of app compatibility or guest-observed identity.

Sources: [preset tables and algorithm](../../Sources/KestrelCore/Presets.swift), [Play memory floor](../../Sources/KestrelCore/Instance.swift), [identity profiles](../../Sources/KestrelCore/DeviceIdentity.swift), [CLI output](../../Sources/kestrel/main.swift).

## Instance management

### `list` and `info`

```text
kestrel list
kestrel info <i>
```

`list` prints instance index, name, PID-derived state, resolution, CPU count, and ADB address, or a no-instances hint. `info` prints the selected instance's state/PID, serial and ports, AVD location, and pretty-printed settings JSON. Neither command starts an instance.

```sh
kestrel list
kestrel info 0
```

### `create`

```text
kestrel create [--name N] [--preset low|medium|high] [--resolution ID]
```

Create settings and AVD configuration, but do not start an emulator. Defaults are name `Instance <index>`, preset `medium`, and resolution `1920×1080` at 280 DPI. CPU/RAM are derived from host resources as described under `presets`. The default image is `system-images;android-36;google_apis_playstore;arm64-v8a`.

An unknown resolution or preset fails. A missing system image produces a warning but does not prevent creation; it will prevent a subsequent launch. At most 52 instance indexes are allocated.

Implementation detail: the help/error text advertises low/medium/high, but the enum parser also accepts `--preset custom`, using the custom CPU/RAM request in the table above. It does not expose separate CPU/RAM creation flags; use `config --set` for explicit values.

```sh
kestrel create --name "Game device" --preset high --resolution tablet-1920x1080
```

### `clone`

```text
kestrel clone <i>
```

Create a new instance from the source's settings and append ` (copy)` to its name. **This copies configuration only, not installed applications, guest data, or snapshots.** It is not a backup command and does not start the clone.

```sh
kestrel clone 0
```

### `rename`

```text
kestrel rename <i> <name>
```

Join remaining name words, trim surrounding whitespace, reject an empty name, and save the settings/AVD configuration.

```sh
kestrel rename 0 "Primary game device"
```

### `delete` — destructive

```text
kestrel delete <i>
```

**Removes the instance's settings and AVD, including local guest data and snapshots, without a confirmation prompt.** The CLI refuses a running instance; stop it first. There is no `--force`, undo, or dry-run option. AVD directory/pointer removal is best effort; instance-directory removal errors propagate, so deletion is not transactional.

```sh
# Permanently delete the stopped instance numbered 3:
kestrel delete 3
```

Sources for instance management: [CLI commands](../../Sources/kestrel/main.swift), [instance store](../../Sources/KestrelCore/Instance.swift).

## Settings

```text
kestrel config <i>
kestrel config <i> --set '{json}'
```

Without `--set`, print sorted, pretty settings JSON. With it, shallow-merge a JSON object into current settings, reject unknown keys, decode and validate the result, and persist it. Saving also regenerates AVD configuration. Changes are not live-applied to a running emulator; the CLI tells you to restart it.

Optional fields may be omitted in printed JSON and may be cleared with JSON `null`. Other fields require their stated types. Setting `performance` alone does **not** recalculate `cpuCount` or `memoryMB`.

| JSON key | Type / validation | New-instance default |
| --- | --- | --- |
| `name` | String; not whitespace-only | `Instance <index>` unless `--name` supplied |
| `cpuCount` | Integer, 1–16 | Host-derived preset |
| `memoryMB` | Integer, 1024–32768 | Host-derived preset, then Play minimum 3072 |
| `width` | Integer, 320–7680 | 1920 |
| `height` | Integer, 320–7680 | 1080 |
| `dpi` | Integer, 120–640 | 280 |
| `gpuMode` | `"host"` or `"swiftshader_indirect"` | `"host"` |
| `vulkan` | Boolean | `true` |
| `disableAsyncSwap` | Boolean or null | Unset; only `true` disables GLAsyncSwap |
| `fpsLimit` | Integer: 30, 60, 90, 120, 144, 165, 240 | 60 |
| `showFPS` | Boolean | `false` |
| `performance` | `"low"`, `"medium"`, `"high"`, `"custom"` | `"medium"` unless another preset supplied |
| `deviceBrand` | String or null | Unset |
| `deviceModel` | String or null | Unset |
| `deviceIdentityPreset` | String or null; `galaxys24ultra`, `oneplus12`, `xiaomi14` | Unset |
| `dataPartitionGB` | Integer, 2–512 | 16 |
| `systemImage` | String with four semicolon-separated components | `system-images;android-36;google_apis_playstore;arm64-v8a` |
| `keymap` | String reference or null | Unset |
| `mouseSensitivity` | Number, 0.1–10 | 1.0 |
| `audio` | Boolean | `true` |
| `microphone` | Boolean or null | Unset; host-audio launch opt-in requires `true` |
| `window` | Boolean | `true` |

`--resolution` on creation replaces width, height, and DPI together. Configuring `systemImage` does not download it. A saved keymap reference is resolved and validated when starting `play` or `replay`, not by settings validation. With a recognized `deviceIdentityPreset`, launch uses that profile's properties instead of the separate brand/model overrides. `audio: false` disables audio regardless of the microphone setting. `window: false` requests a windowless emulator; it does not remove SDK or device requirements.

```sh
kestrel config 0
kestrel config 0 --set '{"cpuCount":6,"memoryMB":6144,"performance":"custom"}'
kestrel config 0 --set '{"keymap":"bgmi","mouseSensitivity":1.2}'
kestrel config 0 --set '{"keymap":null,"microphone":false}'
```

These are accepted configuration values, not promises that every emulator/image honors every property or that changing disk size resizes existing guest data.

Sources: [settings schema/defaults/validation/merge](../../Sources/KestrelCore/Settings.swift), [persistence and AVD generation](../../Sources/KestrelCore/Instance.swift), [launch settings](../../Sources/KestrelCore/Launcher.swift), [config command](../../Sources/kestrel/main.swift).

## Starting and stopping

### `start`

```text
kestrel start <i> [--cold] [--snapshot NAME] [--wait]
```

| Option | Default / behavior |
| --- | --- |
| `--cold` | Off. Skip loading the automatic quick-boot snapshot; does not wipe guest data. |
| `--snapshot NAME` | Unset. Load an existing named snapshot, force its loading, and disable automatic snapshot saving for that launch. Takes precedence over `--cold`. |
| `--wait` | Off. After starting, wait up to 300 seconds for `sys.boot_completed` to become `1`, polling every two seconds. |

Without cold/snapshot options, Kestrel leaves normal emulator quick-boot behavior enabled. Start requires an installed selected image and, if requested, an existing named snapshot. It saves/regenerates instance configuration, launches the emulator, directs output to the instance log, and records its PID. It prints the PID and log path before any `--wait` boot check.

If a recorded emulator PID is already alive, `start` returns that PID rather than relaunching. In that case `--cold` or `--snapshot` does not alter the existing session. `--wait` still performs its boot check. Without `--wait`, successful process creation is not proof that Android finished booting. A timeout/process-exit error is not an automatic cleanup or rollback operation.

```sh
kestrel start 0 --wait
kestrel start 0 --cold --wait
kestrel start 0 --snapshot before-update --wait
```

### `stop`

```text
kestrel stop <i>
```

Request shutdown with `adb emu kill`. If the recorded process remains, wait about five seconds, send SIGTERM and wait another five seconds, then SIGKILL and wait about two seconds. If it survives, report an error; otherwise remove the PID file. The instance and its guest data remain for future starts, but forced termination is not a guarantee of a cleanly saved guest session.

```sh
kestrel stop 0
```

Sources: [lifecycle commands](../../Sources/kestrel/main.swift), [launch arguments, PID handling, shutdown and boot wait](../../Sources/KestrelCore/Launcher.swift).

## Snapshots

```text
kestrel snapshot list <i>
kestrel snapshot save <i> NAME
kestrel snapshot load <i> NAME
kestrel snapshot delete <i> NAME
```

There are no snapshot flags. Use an explicit subcommand followed by the instance index.

| Subcommand | Requirements and effects |
| --- | --- |
| `list` | Reads snapshot directories from disk, so it works with a stopped instance. Prints name, modification date, and size, newest first, or a no-snapshots hint. Excludes the automatic `default_boot` snapshot and empty entries. |
| `save` | Requires a running instance. Requests an emulator snapshot save, detects console `KO` responses as errors, and verifies that the snapshot appeared on disk. No confirmation or separate overwrite flag is supplied when reusing a name. |
| `load` | **Replaces the current guest session with saved state.** Requires an existing snapshot and a running instance; it does not auto-start. To start from a snapshot instead, use `start --snapshot NAME`. |
| `delete` | **Permanently removes the named snapshot without confirmation.** Works stopped or running; if running, attempts console deletion before removing the directory. |

Names used for save/delete must contain 1–64 characters, start with an alphanumeric character, and otherwise contain only alphanumerics, `.`, `_`, or `-`. `default_boot` is reserved. A nonexistent load/delete target fails. Listing sizes counts immediate files, not a recursive accounting of all storage.

```sh
kestrel snapshot save 0 before-update
kestrel snapshot list 0
# Restores saved guest state, replacing the current session:
kestrel snapshot load 0 before-update
# Permanently removes the saved snapshot:
kestrel snapshot delete 0 before-update
```

Sources: [snapshot implementation](../../Sources/KestrelCore/Snapshots.swift), [snapshot dispatcher](../../Sources/kestrel/main.swift).

## Applications, shell, and ADB

These commands address an existing instance through its serial. They do not automatically boot it; device operations require a reachable emulator. Except raw `adb`, they convert nonzero ADB helper status into a Kestrel error.

| Command | Behavior / side effects |
| --- | --- |
| `install <i> <file.apk>` | Run `adb install -r -g`: install or replace the APK and grant runtime permissions. Print ADB stdout. **Can replace an installed application.** |
| `uninstall <i> <package>` | Run ADB uninstall and print stdout. **Removes the application; no keep-data flag is passed.** |
| `playstore <i> [package]` | Require a configured image whose tag contains `playstore`. With no package, launch Google Play Store. With a package, open its `market://details?id=…` page in `com.android.vending`; this is not an automatic app install. |
| `open <i> <package>` | Launch via Android `monkey` using the launcher category; print `Launched PACKAGE`. |
| `close <i> <package>` | Run `am force-stop`; print `Stopped PACKAGE`. **Can interrupt unsaved app activity.** |
| `apps <i>` | List third-party package IDs (`pm list packages -3`), sorted, one per line; not all system packages. |
| `shell <i> <command...>` | Join positional command tokens with spaces and execute that single Android shell string. Print stdout without adding a newline. An empty command fails. **Effects depend on the shell command.** |
| `screenshot <i> <out.png>` | Capture PNG bytes with `exec-out screencap -p`, validate the PNG signature, write to the supplied host path, and print that path. **May overwrite an existing file.** Capture is bounded by 10 seconds and 64 MiB. |
| `adb <i> <args...>` | Invoke the selected SDK's ADB with `-s SERIAL`, forwarding the remaining arguments unchanged; forward stdout, stderr, and ADB's exit status. **Effects depend on the ADB arguments.** |

Raw `adb` bypasses the ordinary option parser; use it when exact argument forwarding matters. Its first argument must parse as an integer and identify an instance. Unlike most commands it does not separately reject negative indexes in the argument parser, and does not require any remaining ADB arguments.

For `shell`, a standalone token starting with `--` is consumed by Kestrel's parser, not forwarded. Quote the entire guest command so such flags remain inside a single command token, or use `adb <i> shell ...` for raw forwarding. Shell metacharacters inside that string are interpreted by the guest shell.

```sh
kestrel install 0 ./game.apk
kestrel apps 0
kestrel playstore 0 com.example.game
kestrel open 0 com.example.game
kestrel close 0 com.example.game
kestrel shell 0 'getprop sys.boot_completed'
kestrel screenshot 0 ./screen.png
kestrel adb 0 shell pm list packages -3
# Removes the installed application:
kestrel uninstall 0 com.example.game
```

Sources: [application/ADB commands](../../Sources/kestrel/main.swift), [ADB helper and screenshot capture](../../Sources/KestrelCore/ADB.swift).

## Interactive input, recording, and replay

### `play`

```text
kestrel play <i> [--keymap FILE|NAME] [--record FILE] [--dry-run]
```

Capture host keyboard, mouse, and gamepad input for the focused emulator window and translate it into guest touches. The keymap is `--keymap` if supplied, otherwise the instance's `keymap` setting. Missing, unreadable, or invalid keymaps fail before playing.

| Option | Default / behavior |
| --- | --- |
| `--keymap FILE\|NAME` | Unset; use saved instance reference. Library package references also resolve. |
| `--record FILE` | Off. Accumulate input events and write a recording to this host path on Ctrl-C. May replace an existing file. |
| `--dry-run` | Off. Print touch operations instead of opening device delivery. Still loads the instance/SDK and runs an interactive macOS input session; it is not a general no-side-effects flag. |

Normal play requires a running instance and macOS Accessibility access. If missing, the CLI requests permission and reports instructions to enable the terminal app under System Settings → Privacy & Security → Accessibility. Dry-run skips this explicit permission/running-instance guard, but still attempts interactive input capture; that does not guarantee input will be captured without permissions.

The status line reports the keymap's mouse-look and free-cursor bindings. F12 toggles hints; Ctrl-C stops input and releases touches. With `--record`, recording is saved during the Ctrl-C handler, not continuously. A recording-write error is printed to stderr, but that handler still exits 0; check the save result rather than relying only on the exit code.

```sh
kestrel play 0 --keymap bgmi
kestrel play 0 --keymap bgmi --record ./session.rec
kestrel play 0 --keymap bgmi --dry-run
```

### `replay`

```text
kestrel replay <i> <FILE> [--keymap FILE|NAME] [--dry-run]
```

Read a recording and replay its events with the selected or saved keymap at recorded timing. The CLI waits one extra second for trailing gestures, then resets/releases touches. There is no speed, looping, or recording-output option.

`--dry-run` prints generated touch operations instead of using the device, but still requires an existing instance and runtime SDK discovery. Normal replay initializes device delivery; unlike `play`, the command does not explicitly check the recorded running PID or request Accessibility access. Device setup can fail if the emulator is unavailable. Later asynchronous delivery errors are printed to stderr and are not necessarily reflected in the process exit status.

```sh
kestrel replay 0 ./session.rec --keymap bgmi --dry-run
# Sends recorded input to the guest:
kestrel replay 0 ./session.rec --keymap bgmi
```

#### Recording format

Recordings are UTF-8 text, with milliseconds followed by an event token:

```text
# Kestrel input recording v1
0.0 keydown:W
100.0 keyup:W
```

Serialization writes timestamps with one decimal place. Blank lines and lines beginning with `#` are ignored on parsing. Timestamps must start at zero or later and be nondecreasing. Malformed lines or backwards time fail with a line-specific parse error. Supported tokens are:

- `keydown:KEY`, `keyup:KEY`
- `mouse:dx,dy`, `cursor:x,y`
- `pointerdown:x,y`, `pointermove:x,y`, `pointerup`
- `wheel:n`, `stick:left,x,y` (stick name is part of the token)
- `look:on`, `look:off`, `reset`

Use finite, reasonable timestamps. The CLI uses the older non-throwing replay overload; the stricter finite/24-hour checks in the cancellable replay API are **not** a CLI validation guarantee. Recordings contain input events, not guest state, the keymap, or a video. Successful parsing/delivery does not guarantee identical game results on replay.

### `tap`

```text
kestrel tap <i> <x> <y>
```

Send one touch at normalized coordinates in `[0,1]`. Convert to pixels by rounding `x*(width-1)` and `y*(height-1)` using instance settings; send down, wait 50 ms, send up, and close delivery. Print resulting pixel coordinates and helper readiness information. Invalid/missing coordinates fail. There is no dry-run flag for `tap`.

```sh
kestrel tap 0 0.5 0.5
```

### Device-delivery side effects

Normal `play`, normal `replay`, and `tap` locate a local `touchd` binary, push it to `/data/local/tmp/sec_touchd` in the **guest**, mark it executable, and start it through a persistent ADB shell. Touch operations are streamed to its stdin. Missing helper, push/chmod failures, process startup, or handshake failures can prevent delivery. These operations modify the guest helper file; they do not merely read input. Dry-run play/replay uses a print sink instead and avoids those helper-installation steps.

Sources: [CLI play/replay/tap](../../Sources/kestrel/main.swift), [interactive session and recording shutdown](../../Sources/KestrelPlay/PlaySession.swift), [replay timing and error handling](../../Sources/KestrelPlay/Driver.swift), [recording format/parser](../../Sources/KestrelKeymap/Recording.swift), [device sink](../../Sources/KestrelPlay/TouchSink.swift).

## Keymaps

Keymap references accept an existing file path, a library ID with or without `.json`, or a matching package name. User keymaps in the data root take precedence over bundled maps with the same ID. Bundled discovery searches executable-relative resource/share/build locations and the current directory's `keymaps` directory. Explicit file paths are resolved before library IDs/packages.

### `keymap list`, `show`, and `check`

```text
kestrel keymap
kestrel keymap list
kestrel keymap show FILE|NAME
kestrel keymap check FILE|NAME
```

The group defaults to `list`. List available maps; `show` prints a selected map as formatted JSON. `check` runs validation, printing success or problems and exiting 1 for validation failures. Checks include normalized coordinates, known/nonconflicting keys (with permitted look-control sharing), at most one look control, and control-specific radius/travel/interval/script requirements. Listing or showing is not equivalent to validation.

```sh
kestrel keymap list
kestrel keymap show bgmi
kestrel keymap check bgmi
```

### `keymap new`

```text
kestrel keymap new <name> [package]
```

Create `<data-root>/keymaps/<name>.json` and print its path. Name must start with a lowercase letter or digit and contain only lowercase letters, digits, and dashes. Existing destination files are rejected rather than overwritten. The optional package associates the map with an Android application. The initial map contains a WASD/left-stick joystick centered at `[0.15,0.72]` with radius `0.065`.

```sh
kestrel keymap new my-game com.example.game
```

### `keymap edit`

```text
kestrel keymap edit <FILE|NAME> [i]
```

Open the visual macOS editor. Cmd-S saves to the destination printed on startup. A user map is saved in place; a bundled or other external map is directed to the user keymap directory using its filename, leaving the source outside that directory unchanged. Saving can replace the user destination.

With an integer instance argument, attempt a screenshot as an editing background and use its aspect ratio. Capture errors fall back to a blank canvas, but missing SDK discovery fails before that fallback. Without an instance, use a blank canvas and the map's aspect ratio. A nonnumeric optional instance token is currently ignored. Screenshot capture also writes a temporary host image.

```sh
kestrel keymap edit my-game
kestrel keymap edit bgmi 0
```

### `keymap simulate`

```text
kestrel keymap simulate <FILE|NAME> <event...>
```

Run the keymap engine locally and print touch operations; no emulator or device sink is used. The map must decode, but this command does **not** run keymap validation first. Use `keymap check` separately. Simulation uses 1920×1080 unless overridden by `KESTREL_SIM_WIDTH` and `KESTREL_SIM_HEIGHT`.

| Event argument | Meaning |
| --- | --- |
| `keydown:W`, `keyup:W` | Press/release a named input. |
| `mouse:dx,dy` | Relative mouse movement. |
| `cursor:x,y` | Cursor position. |
| `wheel:n` | Scroll-wheel input. |
| `stick:left,x,y` | Named stick input. |
| `look:on`, `look:off` | Set mouse-look state. Only exact `on` enables it; the simulator parser treats other values as off. |
| `wait:ms` | Advance simulated time, ticking every 8 ms. |

Each non-wait event advances the simulation clock by 1 ms. The simulator has its own parser: recording-only tokens such as `pointerdown`, `pointerup`, and `reset` are not accepted here. Unknown event kinds or missing numeric components fail. Use finite, nonnegative wait durations.

```sh
kestrel keymap simulate bgmi keydown:W wait:100 keyup:W
KESTREL_SIM_WIDTH=1280 KESTREL_SIM_HEIGHT=720 kestrel keymap simulate bgmi keydown:W wait:100 keyup:W
```

Sources: [keymap commands and simulator parser](../../Sources/kestrel/main.swift), [library resolution](../../Sources/KestrelKeymap/KeymapLibrary.swift), [keymap schema and validation](../../Sources/KestrelKeymap/Keymap.swift).

## Errors, exit status, and automation limits

| Situation | Observable behavior in source |
| --- | --- |
| Root help | Print help; exit 0. |
| Ordinary command completes | Normal completion is success; command-specific output is generally human-oriented. |
| Missing argument, bad index/value, unknown command/subcommand, thrown operation error | Print `kestrel: <message>` to stderr; exit 1. Core errors may add `invalid:`, `not found:`, or `environment:`. |
| `setup --check` missing required component | Print missing-component status and installation hint; exit 1. Missing optional NDK alone does not fail the check. |
| `keymap check` validation failure | Print validation problems; exit 1. |
| Raw `adb` | Forward ADB stdout/stderr and exit with ADB's status. Failure to invoke the command still uses Kestrel's ordinary error handling. |
| Interactive Ctrl-C | Stop input, attempt recording save if requested, and exit 0, even if saving reports an error. |
| Later play/replay sink error | Report on stderr; not guaranteed to yield nonzero exit status. |

There is no documented global JSON-output, quiet, force, or version flag. `config` and the settings portion of `info` print JSON; most other commands print status text. Do not infer that an unrecognized option was honored merely because the process exited successfully.

Destructive or overwriting operations to review before automation include `delete`, `snapshot load`, `snapshot delete`, repeated snapshot saves, `uninstall`, replacement APK installation, `config --set`, screenshot/recording output, and editor saves. `shell`, raw `adb`, and replay can perform additional destructive guest actions according to their input. No general confirmation or rollback layer surrounds these operations.

This reference was checked against source without running the CLI, tests, builds, ADB, emulator sessions, downloads, or network requests. Runtime behavior dependent on the installed emulator/image, permissions, host tools, or target application remains environment-dependent.

Sources: [dispatch, error wrapper and exit paths](../../Sources/kestrel/main.swift), [core error descriptions](../../Sources/KestrelCore/Settings.swift), [interactive exit handler](../../Sources/KestrelPlay/PlaySession.swift), [asynchronous delivery](../../Sources/KestrelPlay/Driver.swift).
