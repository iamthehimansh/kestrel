# Contributing to Kestrel

Thank you for your interest in Kestrel. It is a small, young project, and contributions of every size are welcome: a corrected sentence in the docs, a keymap for a game you play, a bug report with good logs, a new unit test, or a performance measurement. You do not need to be a Swift or Android expert to help.

This guide explains how to set up a development environment, how to build and test, how to contribute keymaps, and what we expect from a pull request. If anything here is unclear or out of date, opening an issue about it is itself a useful contribution.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md). Security problems should not be reported in public issues; see [SECURITY.md](SECURITY.md).

## Contents

- [Ways to contribute](#ways-to-contribute)
- [Development setup](#development-setup)
- [Build and test](#build-and-test)
- [Project layout](#project-layout)
- [Contributing keymaps](#contributing-keymaps)
- [Evidence standards](#evidence-standards)
- [What not to submit](#what-not-to-submit)
- [Branches and commits](#branches-and-commits)
- [Pull requests](#pull-requests)
- [Good first issues](#good-first-issues)
- [Further reading](#further-reading)

## Ways to contribute

- **Report a bug** with the bug report form. Include your macOS version, Mac model, Kestrel version and the relevant logs.
- **Report game compatibility** with the game compatibility form, whether a game works, partly works or does not work.
- **Suggest a feature** with the feature request form. Describe the problem first, then the solution you have in mind.
- **Improve the docs** in `docs/guide/` or fix the README.
- **Add or improve a keymap** in `keymaps/`.
- **Write tests** for code that is not yet covered.
- **Fix a bug or implement a feature.** For anything larger than a small fix, please open an issue first so we can agree on the approach before you spend time on it.

## Development setup

Kestrel targets Apple Silicon Macs only.

| Requirement | Notes |
|---|---|
| Mac | Apple Silicon (arm64). Intel Macs are not supported. |
| macOS | 15 or later to run the native player. The core libraries build for macOS 13 and later. |
| Xcode | A version that ships Swift 6.2 (the package uses `swift-tools-version:6.2`). Check with `swift --version`. |
| protobuf | `brew install protobuf`. The native stream target generates gRPC code at build time and needs `protoc`. On Apple Silicon Homebrew installs it at `/opt/homebrew/bin/protoc`. |
| Python 3 | Used by the packaging scripts and their unit tests. The system `python3` is enough. |
| Android SDK | Not needed to build or run the unit tests. To run instances, let the app download it on first launch, or run `kestrel setup`. An existing Android Studio SDK in `~/Library/Android/sdk` is reused. |

Clone the repository and fetch the Swift package dependencies:

```sh
brew install protobuf
git clone https://github.com/iamthehimansh/kestrel.git
cd kestrel
PROTOC_PATH=/opt/homebrew/bin/protoc swift build
```

The first build downloads the pinned dependencies listed in `Package.resolved` (grpc-swift, grpc-swift-nio-transport, grpc-swift-protobuf and swift-protobuf) and can take several minutes.

### Keep your own data safe

Kestrel stores instances, AVDs and logs in `~/Library/Application Support/Kestrel`. While developing, point it at a separate directory so experiments cannot damage the instances you actually play on:

```sh
export KESTREL_HOME="$HOME/kestrel-dev-home"
```

Each instance writes its emulator output to `instances/<index>/emulator.log` under that directory. That file is usually the first thing to attach to a bug report.

## Build and test

Run these from the repository root.

```sh
# Swift unit tests (all four test targets)
PROTOC_PATH=/opt/homebrew/bin/protoc swift test --jobs 1

# Python unit tests for the packaging scripts
python3 -m unittest discover -s scripts -p 'test_*.py'

# Build build/Kestrel.app (ad-hoc signed, runs on this Mac)
KESTREL_VERSION=x.y.z PROTOC_PATH=/opt/homebrew/bin/protoc bash scripts/build-app.sh

# Build build/Kestrel-x.y.z.dmg (builds the app first unless SKIP_APP_BUILD=1)
KESTREL_VERSION=x.y.z PROTOC_PATH=/opt/homebrew/bin/protoc bash scripts/build-dmg.sh
```

Notes:

- `--jobs 1` runs one build job at a time, which keeps memory use down. It is the command used for the project's own test runs.
- `KESTREL_VERSION` must be a plain `major.minor.patch` version such as `0.1.8`; the scripts reject anything else. It defaults to `0.1.0`.
- `build-app.sh` uses `PROTOC_PATH` if set, otherwise whatever `protoc` is on your `PATH`.
- The app is ad-hoc signed, so its signature changes on every rebuild. macOS ties the Accessibility permission to the signature, so after a rebuild you may need to switch Kestrel off and on again in System Settings > Privacy & Security > Accessibility.
- The app bundle and DMG do not include the Android SDK or a system image, and they are not notarized.
- The CLI can be run straight from the build: `PROTOC_PATH=/opt/homebrew/bin/protoc swift run kestrel --help`. The `swift run kestrel ...` commands below assume `PROTOC_PATH` is exported in your shell.

### Runtime and diagnostic tools

The unit tests do not start an Android VM. Behaviour of the native player, streaming, touch injection and typing can only be checked against a running instance on your Mac. The `diagnostics/` directory contains probe executables (for example `NativePlayerProbe` and `NativeStreamProbe`) and an original, account-free Android workload for collecting comparable measurements. Read `diagnostics/README.md` before using them: it explains what each measurement does and does not show, and the comparison protocol to follow.

Do not run two VMs, or a VM and another heavy process, at the same time while measuring performance.

## Project layout

| Path | What it contains |
|---|---|
| `Sources/KestrelCore` | Instances, settings, SDK management, emulator launching |
| `Sources/KestrelKeymap` | Keymap model, validation, editing and the input engine |
| `Sources/KestrelStream` | Authenticated loopback gRPC client for the emulator |
| `Sources/KestrelPlay` | Native Metal player window, sidebar and keymap overlay |
| `Sources/KestrelApp` | The SwiftUI app |
| `Sources/kestrel` | The `kestrel` command-line tool |
| `Tests/` | Unit tests for Core, Keymap, Play and Stream |
| `keymaps/` | Bundled keymap presets (JSON) |
| `touchd/` | Small Android-side touch helper written in C |
| `scripts/` | App, DMG and packaging scripts, plus their Python tests |
| `diagnostics/` | Probes and the runtime diagnostic workload |
| `docs/guide/` | User and developer guides |
| `docs/research/` | Experiment notes and case studies |

## Contributing keymaps

Keymaps are the easiest way to make Kestrel more useful, and you do not need to write any Swift to add one.

1. **Start from an existing file.** Copy the closest preset in `keymaps/` (for example `codm.json` for a shooter or `mlbb.json` for a MOBA) to `keymaps/<game>.json`. Use a short lowercase name with hyphens.
2. **Fill in the metadata.** Set `name`, the Android `package` name of the game (for example `com.pubg.imobile`), a one-line `description`, and the `aspect` you designed it for.
3. **Place the controls.** Coordinates are normalized: `[0, 0]` is the top-left corner of the Android screen and `[1, 1]` is the bottom-right. Every point must be between 0 and 1. Joystick and look `radius` values are also fractions of the screen and must be greater than 0 and at most 0.5. Supported control types are `tap`, `turbo`, `joystick`, `look`, `skill`, `swipe`, `combo`, `scroll`, `pinch` and `macro`. Only one `look` control is allowed.
4. **Measure against a real HUD screenshot.** Take a screenshot of the game at the resolution you play at (the sidebar has a screenshot button), open it in any image viewer that shows pixel positions, and divide each button's centre by the image width and height. Guessing positions from memory usually produces controls that miss by a few percent.
5. **Validate the file.**

   ```sh
   swift run kestrel keymap check keymaps/<game>.json
   ```

   It prints `<game>.json: OK (<n> controls)` on success, or one line per problem and a non-zero exit status. It catches out-of-range coordinates, unknown key names, invalid radii and timings, and unparsable macros. Reusing a key on several controls is allowed; one press then fires all of them.
6. **Try it in the game** with the live editor: open the player, enable mapping from the sidebar, raise hint opacity so you can see the controls over the HUD, and drag anything that is misplaced. You can also run `swift run kestrel keymap edit <game> <instance>` to edit over a live screenshot. Edits are saved to your user keymap folder (`$KESTREL_HOME/keymaps`, a file with the same name overrides the bundled preset) and bundled presets are never modified, so copy the adjusted file back into `keymaps/` for your pull request and run `keymap check` on it again.

In the pull request, state the game version, the Android resolution and DPI you tested at, and attach a screenshot of the hints over the game HUD. If you could only validate the file and not play with it, say so; that is still a useful contribution, but it must be described accurately.

## Evidence standards

Kestrel's documentation keeps a strict line between what has been built and what has been shown to work. Please follow the same rule in issues, pull requests and docs.

Describe each change at one of three levels, and do not blur them:

- **Implemented**: the code exists and builds.
- **Unit-tested**: there are automated tests that pass and that would fail without the change.
- **Runtime-verified**: you ran it on a real Mac against a running Android instance and observed the result.

Guidelines:

- Say which level each claim in your PR reaches. "Implemented and unit-tested; not yet runtime-verified" is a perfectly good description.
- For runtime claims, include evidence: the relevant part of `emulator.log` or the console output, a screenshot or a short screen recording, and the exact commands you ran.
- Record the environment: macOS version, Mac model, Kestrel version or commit, Android image, and the instance's CPU, RAM, resolution and renderer.
- For performance claims, follow the comparison protocol in `diagnostics/README.md`: several repetitions per condition, every sample reported, one variable changed at a time.
- **Never claim game compatibility you have not tested.** A game is "working" only if you played it with Kestrel and say which version and which features you checked. Do not copy compatibility claims from other emulators or from memory.
- Negative results are welcome. An experiment that did not work, written up clearly, saves the next person time. See `docs/research/` for examples.

## What not to submit

To keep Kestrel legally clean and safe to use, pull requests must not contain:

- Proprietary binaries, libraries or assets from other emulators, games or vendors.
- Decompiled or disassembled code, or code translated line by line from it. Research may describe how something works; Kestrel's code must be an original implementation.
- Android system images, Google Play components, or other files whose licences do not allow redistribution.
- User VM data: AVDs, snapshots, disk images, `KESTREL_HOME` contents, or anything containing account data.
- Secrets: API keys, tokens, signing certificates, passwords, or gRPC tokens copied from a running instance. Check screenshots and logs before attaching them.
- Game modifications, cheats, or anything that bypasses, disables or evades anti-cheat, emulator detection or Play Integrity. Kestrel does not modify games and will not accept such changes.

If you are not sure whether something is acceptable, ask in an issue before opening the pull request.

## Branches and commits

- Fork the repository and create a topic branch from `main`, for example `feat/keymap-pubg-new-state`, `fix/typing-focus-handoff` or `docs/building-troubleshooting`.
- Keep each pull request focused on one change. Separate refactoring from behaviour changes where you can.
- Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) for commit messages:

  ```text
  <type>(<optional scope>): <short summary in the imperative>
  ```

  Common types: `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `build`, `ci`, `chore`. Useful scopes: `app`, `cli`, `core`, `keymap`, `play`, `stream`, `touchd`, `scripts`, `keymaps`.

  Examples:

  ```text
  feat(keymap): add pinch control for map zoom
  fix(play): return focus to the game after a text field closes
  docs(guide): explain the Accessibility reset after rebuilding
  test(core): cover settings migration for hint opacity
  ```

- Mark breaking changes with `!` after the type, or a `BREAKING CHANGE:` footer, and explain the migration.

## Pull requests

Before opening a pull request, check that:

- [ ] `PROTOC_PATH=/opt/homebrew/bin/protoc swift test --jobs 1` passes.
- [ ] `python3 -m unittest discover -s scripts -p 'test_*.py'` passes if you touched `scripts/`.
- [ ] `swift run kestrel keymap check <file>` passes for every keymap you added or changed.
- [ ] New behaviour has unit tests where it can be tested without a VM.
- [ ] The description states what is implemented, what is unit-tested and what is runtime-verified, with logs or screenshots for runtime claims.
- [ ] User-facing changes are reflected in `docs/guide/` and noted under `Unreleased` in `CHANGELOG.md`.
- [ ] Nothing from [What not to submit](#what-not-to-submit) is included.
- [ ] Commits follow Conventional Commits.

The pull request template repeats this checklist. CI builds the package and runs the Swift and Python unit tests on macOS. It cannot start an Android VM, so runtime behaviour still has to be checked locally and described in the pull request.

A maintainer will review your pull request as time allows. Review comments are about the change, not about you; if you disagree with one, say so and explain why. If a pull request goes quiet for a while, a polite reminder is fine.

## Good first issues

Look for issues labelled `good first issue`. If none suit you, these areas are always useful:

- **Keymaps for more games**, or improvements to the existing presets for different resolutions and HUD layouts.
- **Documentation**: clearer setup steps, troubleshooting entries for errors you hit, and screenshots of the player and editor.
- **Tests**: more unit tests for keymap validation, the input engine, settings migration and the packaging scripts.
- **Unicode typing**: typing currently supports ASCII only. Investigating and implementing text input beyond ASCII (accented letters, other scripts) is a well-contained project.
- **Performance measurements**: careful, repeatable measurements on different Mac models using the protocol in `diagnostics/README.md`.

## Further reading

- `docs/guide/` contains the user and developer guides: setup, everyday use, building from source and how the pieces fit together.
- `docs/research/` contains experiment notes and case studies, including approaches that were tried and rejected and why.
- `diagnostics/README.md` describes the runtime diagnostic workload and the measurement protocol.
- `THIRD_PARTY_NOTICES.md` lists third-party components and their licences.

Kestrel is released under the [MIT License](LICENSE). By contributing, you agree that your contributions are licensed under the same terms.
