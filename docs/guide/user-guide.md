# User guide

Start with [Getting started](getting-started.md). Commands and JSON are documented separately in the [CLI reference](../reference/cli.md) and [keymap reference](../reference/keymap-format.md).

## Instance manager

Use New Instance to create a profile. The sidebar supports Start All and Stop All; each instance has Start, Cold Boot, Stop, Rename, Duplicate, Show Data in Finder and Delete actions. Apps, Controls, Snapshots and Settings are separate tabs.

**Duplicate copies settings only.** It is not a clone of the installed Android apps or disk. Delete removes the instance's apps, data and snapshots. Stop and back up before destructive operations.

The instance index is used by CLI commands and by the console/ADB port allocation; do not assume the first currently visible row is index zero.

## Native player and sidebar

On macOS 15+, Kestrel owns the emulator lifecycle and displays streamed frames in a Metal window. The narrow right rail provides Android navigation, volume, screenshot, rotation, keyboard and mapping controls. On shorter windows, scroll the rail to reach every button. Resizing the host window does not stretch Android's aspect ratio or change the guest's configured resolution.

| Control | Behavior |
|---|---|
| Back / Home / Recents | Sends the corresponding Android navigation action |
| Volume | Sends Android volume keys, not Mac system-volume commands |
| Screenshot | Saves a PNG from the current guest frame |
| Rotate | Requests guest rotation and waits for observed orientation |
| Keyboard | Requests Android's keyboard-related action; it is not a guarantee every game exposes an editable field |
| Keymapping switches icon | Opens Enable keymapping and Hint visibility controls |
| Fullscreen | Expands the native player into a macOS fullscreen Space |

A command can be unavailable while disconnected, rotating, or editing. A successful click is not evidence that Android completed the action; the player tracks readiness where supported.

## Mapping on/off and hint visibility

Open the switches icon in the right rail. **Enable keymapping** controls whether game keys generate touches. **Hint visibility** independently adjusts the drawn hints from 0% to 100%; 0% does not turn mapping off.

While this popover is open, gameplay input is suspended and held touches are released. This includes a mapping session newly enabled inside the popover. Closing it releases the input block. These boundaries prevent a slider drag or checkbox click from becoming a game action.

Hints are click-through child windows attached to the native player so they follow its fullscreen Space. Legacy external-window hints use a different floating-window path. Hints are not the Android frame and changing their opacity does not dim the game.

## Choose and edit a keymap

Choose a bundled preset or a personal mapping in Controls. Presets express intended button positions, not automatic game/HUD detection. For BGMI, follow the [matching HUD setup](bgmi-layout.md) before testing.

Open the live editor over the running guest. Gameplay input is paused while editing. Changes are staged until Save:

| Gesture/key | Result |
|---|---|
| Drag a control | Move its normalized position |
| Double-click empty space | Add a tap on an available key |
| Select a control, press a key | Rebind supported single-key controls |
| Delete / Backspace | Remove selected control |
| `[` / `]` | Shrink/enlarge a radius-based control |
| `Shift+[` / `Shift+]` | Decrease/increase joystick push distance |
| Save / Command-S | Validate and save staged changes |
| Cancel | Discard staged changes |

The manager's inspector exposes more fields, including joystick Push distance. Personal edits are saved under the Kestrel data root's `keymaps/`; they override bundled files with the same identifier. App updates deliberately preserve them.

### Ring radius versus push distance

The joystick radius is measured as a fraction of guest **width**. `travel` is a separate multiplier, default 1, from 0.25 through 4. A configured green secondary ring in the editor visualizes the effective travel; it can extend outside the base ring when travel exceeds 1.

Actual movement displacement combines radius, travel, directional input and walk/sprint scale. `Shift` is the BGMI preset's sprint modifier; `Ctrl` is its walk modifier. Increasing these values does not force the game to sprint: fixed/floating joystick mode, sprint sensitivity and the game's HUD still determine what the gesture means.

### Mouse look and temporary cursor release

The preset's look-toggle key is normally Grave/backtick. Alt temporarily frees the cursor. Left/right mouse actions can be restricted to look mode; if the pointer is free, a click may be a direct pointer action rather than a mapped fire button. Review the preset instead of assuming all clicks mean fire.

### Macros and gamepads

Control types include taps, turbo, joystick, look, skill, swipe, combo, scroll, pinch and macro. Macros are finite scripts of touches and waits; they do not recognize on-screen context. For example, the BGMI `F` macro taps multiple action coordinates, and another visible control at those coordinates may react.

Gamepad support depends on macOS's controller recognition and the preset's bindings. The [format reference](../reference/keymap-format.md) records model/runtime differences and limits. Follow each game's rules when using automation or mappings.

## Text typing

The native player observes Android's focused window and input method before authorizing text. When a fresh editor observation permits it, text goes through authenticated gRPC key events rather than game mappings. Held game input is released first.

Current support is printable ASCII and editing/navigation keys such as Backspace, Delete, Enter, Tab, arrows, Home and End. Unicode, Hindi, emoji and full IME composition are not implemented. Bulk ASCII is sent as ordered individual keys.

Focus evidence expires quickly. Losing Mac focus, changing Android fields, opening an editor/popover or a failed observation invalidates queued input. Intermittent focus-query timeouts were observed: input can stop rather than risk typing into the wrong app. Do not work around this by removing the guards. A successful isolated text/Backspace/Home probe is not complete game-chat compatibility proof.

## Sound and microphone

Playback is provided by the emulator's host audio backend, not by an additional Kestrel gRPC audio player. Sound controls output availability. Microphone is a separate opt-in setting available when Sound is on, implemented with the emulator's `-allow-host-audio` option.

Restart the instance after changing microphone passthrough. macOS capture authorization, Android's microphone permission and in-game voice settings can all be necessary. The preview has launch-flag/unit/build verification, not verified voice-chat capture. Neither input audio nor game chat is automatically recorded by Kestrel's research tools.

Earlier gameplay silence was investigated and later reported resolved after a restart, without a proven root cause. See the [audio case study](../research/audio-case-study.md) instead of treating a speculative setting as a universal fix.

## Settings and snapshots

CPU, RAM and resolution affect resource consumption; allocate within host limits. DPI controls Android's density. Virtual display refresh is not an FPS unlock. GPU mode, Vulkan and experimental snapshot options can change compatibility and invalidate saved states. EGL crash compatibility disables asynchronous swaps; it is not the complete BGMI black-screen workaround. Device identity settings may not be honored by stock system images and do not establish game acceptance.

Snapshots use the emulator's storage under the AVD. They are not independent backups. The reserved `default_boot` quick-boot state is distinct from named snapshots. Named snapshot identifiers use 1–64 letters/digits/dots/dashes/underscores and start with a letter or digit. Changes to hardware/graphics settings can invalidate them. Vulkan-active snapshots remain an experimental area.

## Recording and replay

Kestrel records mapping/input events, not a gameplay video or a microphone recording. Replays reproduce those events against the current screen and can perform unintended actions if the game state differs. Start only in a safe, known context and use the stop/cancel control. Replays must release held inputs and stop on session shutdown.

## Troubleshooting and safe testing

Test a new map in training ground. Do not use layout-editor screenshots as proof movement works: touches there edit buttons. For diagnosis, note the game version, guest resolution, selected preset and exact symptom. Redact account/session IDs and keys before sharing captures.

See [troubleshooting](../support/troubleshooting.md), [compatibility](compatibility.md), and [contributing](../../CONTRIBUTING.md).
