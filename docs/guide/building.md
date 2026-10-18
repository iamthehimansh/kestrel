# Building and testing

## Toolchain

Use an Apple Silicon Mac and Xcode with **Swift 6.2**. The Swift package targets macOS 13+, while native-player integration requires macOS 15+. Install protobuf so the gRPC build plugins can locate `protoc`:

```sh
brew install protobuf
git clone https://github.com/iamthehimansh/kestrel.git
cd kestrel
export PROTOC_PATH=/opt/homebrew/bin/protoc
swift --version
"$PROTOC_PATH" --version
swift build --jobs 1
swift test --jobs 1
```

`Package.swift` defines products and dependencies; `Package.resolved` records the resolved versions. Do not update pins accidentally while fixing unrelated code. The command-line app is available through `swift run kestrel`; the installed app also contains `Contents/Resources/bin/kestrel` but does not automatically put it on your shell's PATH.

## Android components and touch helper

`kestrel setup` installs the SDK components described in [Getting started](getting-started.md), including automatic SDK-license acceptance. Building the original Android touch helper requires an NDK:

```sh
swift run kestrel setup --with-ndk
bash touchd/build.sh
```

The normal setup's NDK identifier is `ndk;27.1.12297006`. Inspect [touchd/build.sh](../../touchd/build.sh) when using a different SDK layout. Do not treat a pre-existing `.build/touchd` artifact as proof that a clean checkout has the required compiler.

## Build an app and DMG

Export the version so both scripts receive the same value:

```sh
export KESTREL_VERSION=0.1.8
export PROTOC_PATH=/opt/homebrew/bin/protoc
bash scripts/build-app.sh
SKIP_APP_BUILD=1 bash scripts/build-dmg.sh
bash scripts/verify-release.sh
```

Outputs are `build/Kestrel.app` and `build/Kestrel-0.1.8.dmg`. These scripts do not install the app into Applications. Previous build outputs are preserved with timestamped names when replaced.

The app contains its executable, CLI, touch helper, bundled keymaps, icon, original-code license, project notices, resolved dependency licenses/notices and Swift runtime resource bundles. It does **not** contain Android SDK tools, Google Play images, games or user data. Local scripts use ad-hoc signing; that is not notarization or Developer ID trust.

`SKIP_APP_BUILD=1` is only appropriate when the existing app was built from the intended source and version. The release verifier checks version, signature, architecture, bundled resources and keymap equality. Read the [maintainer release procedure](../maintainers/releasing.md) before publishing.

## Test layers

| Layer | Command / source | What it establishes |
|---|---|---|
| Swift unit/integration fixtures | `swift test --jobs 1` | Covered parser, lifecycle, frame, input and UI behavior under fixtures |
| Packaging scripts | `python3 -m unittest discover -s scripts -p 'test_*.py' -v` | Failure handling and packaging/history-checker contracts |
| Documentation | `python3 scripts/check-public-docs.py` | Required files/headings and supported relative links |
| Outgoing history | `python3 scripts/check-public-history.py main` | Defined checks over every reachable commit/path/blob; not a universal secret audit |
| App-only DMG | `bash scripts/verify-release.sh` | Mounted artifact structure, signature and checksum |
| Native UI probes | `diagnostics/NativeSessionWindowProbe` | Real window/control interactions for selected scenarios |
| Owned Android probes | `diagnostics/PlayerSessionProbe`, stream/GLES/Vulkan tools | Explicit runtime workloads and their measured outcomes |
| User gameplay | Compatibility report | Specific game/version/session experience, not universal support |

Tests using AppKit/Metal need a graphical macOS environment. The opt-in fullscreen test changes desktop Spaces and requires the fixture to acquire focus:

```sh
KESTREL_FULLSCREEN_TESTS=1 swift test --filter HintOverlayTests --jobs 1
```

Keep that interactive check separate from an unattended suite if another application owns focus. A failed focus precondition is not a passing fullscreen result. Do not hide it by removing the assertion.

The native sidebar probe can be built with `swift build --product NativeSessionWindowProbe --jobs 1`. Build output paths depend on Swift/Xcode's build system; find the actual executable before invoking `--sidebar-check OUTPUT_DIRECTORY` or another probe mode. Read the program's arguments and [diagnostics README](../../diagnostics/README.md) first.

## Runtime isolation

Never run diagnostic launchers against another person's active profile. Use a separate `KESTREL_HOME`, explicit free console/ADB/gRPC ports and adequate memory headroom. Verify process ownership and opened disk paths before mutation. Keep a backup and restore changed guest settings; asynchronous writes may require verification after reboot.

Do not infer game performance from a Canvas callback probe, microphone behavior from a launch flag, or end-to-end typing from a successful RPC. Preserve these distinctions in pull requests.

## Common build failures

- **Missing protoc:** check `PROTOC_PATH` and the installed protobuf binary.
- **Wrong Swift version:** inspect `swift --version` and selected Xcode; a deployment target is not the Swift tools version.
- **Missing NDK/touchd:** install the declared NDK and build the helper; do not download an unknown prebuilt executable.
- **SDK discovery fails:** check `ANDROID_SDK_ROOT`/`ANDROID_HOME`, or the default SDK path; Finder and terminal environments differ.
- **Permission-related native tests:** establish the expected local UI/Accessibility context, or report the test as not run.
- **Snapshot or VM failure:** inspect the instance's emulator log; do not delete userdata as a build workaround.

See [troubleshooting](../support/troubleshooting.md) and [Contributing](../../CONTRIBUTING.md).
