# Changelog

All notable changes to Kestrel are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While Kestrel is below 1.0, minor and patch releases may include breaking changes;
they will be called out here.

Entries say whether a change is unit-tested or has been checked on a running
instance where that matters. See [CONTRIBUTING.md](CONTRIBUTING.md#evidence-standards).

## [Unreleased]

Nothing yet.

## [0.1.8] - Preview

First public release. Kestrel is preview software: it works and is in daily use
by its author, but expect rough edges.

### Added

- Native Metal player window for Android instances, streaming frames from the
  emulator over an authenticated gRPC connection on a loopback address only.
  Each player session signs its tokens with its own key, tokens are limited to
  the methods the player needs, and the public key is removed when the session
  ends.
- Keymapping from keyboard, mouse and gamepad to touch, with a live editor in
  the player: drag controls over the game, double-click to add, press a key to
  rebind.
- Sidebar toggle to enable or disable mapping for the current game.
- Hint opacity slider from 0 to 100% for the on-screen control hints.
- Joystick push distance, set separately from the joystick ring size, in the
  control inspector and with Shift+[ and Shift+] in the editor.
- Typing into Android text fields from the Mac keyboard (ASCII only), with
  keyboard focus handed to the text field and back to the game controls.
- Optional microphone passthrough per instance (`microphone` setting, which
  launches the emulator with `-allow-host-audio`). Off by default.
- Bundled keymap presets, including an expanded BGMI/PUBG Mobile preset, and
  `kestrel keymap check` for validating keymap files.
- App bundle and DMG build scripts (`scripts/build-app.sh`,
  `scripts/build-dmg.sh`) with Python unit tests for the packaging steps.
- Documentation of a per-app ANGLE workaround for BGMI, which applies to the
  game only rather than changing the renderer for the whole instance.
- Contributor guide, code of conduct, security policy, issue forms, pull
  request template and a CI workflow that builds the package and runs the
  unit tests.

### Changed

- Popovers and panels opened from the player isolate their input, so typing or
  clicking in them no longer reaches the game as mapped key presses.
- The player sidebar scrolls when its contents do not fit the window.
- Control hints are shown in fullscreen as well as in windowed mode.

### Fixed

- Work lost in an accidental local reset during development was recovered and
  re-applied before this release. If you notice behaviour that regressed
  compared with earlier private builds, please open an issue.

### Known limitations

- The app is ad-hoc signed and not notarized. macOS asks you to allow it in
  System Settings > Privacy & Security the first time, and the Accessibility
  permission may need to be re-granted after an update.
- The Android SDK, emulator and system image are not bundled. They are
  downloaded on first launch (or with `kestrel setup`), or an existing Android
  Studio SDK is reused.
- Typing supports ASCII characters only.
- Audio problems have been observed in some sessions. Their root cause is not
  yet known.
- Native player runtime behaviour is checked manually on a local VM and is not
  covered by CI.
- Game compatibility varies by title and game version. Games that enforce Play
  Integrity or emulator detection may refuse to run; Kestrel does not attempt
  to bypass these checks.

[Unreleased]: https://github.com/iamthehimansh/kestrel/compare/v0.1.8...HEAD
[0.1.8]: https://github.com/iamthehimansh/kestrel/releases/tag/v0.1.8
