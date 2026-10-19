# Keymap JSON reference

This reference describes Kestrel's current JSON model, validator, macro parser, touch engine, and editor. It is intended for people editing a keymap or diagnosing why a binding behaves differently from its label.

A keymap describes **where to send touches**, not how to identify game actions. Successful JSON decoding or validation does not prove that a touch hits the intended button, that an imported HUD matches, or that a game accepts the gesture. The examples below are checked against the source definitions; they have not been executed in a game.

For the bundled BGMI preset, use the [BGMI HUD and layout guide](../guide/bgmi-layout.md). That guide owns the matching share code and movement-settings table. Its **Character control option 3** means fixed movement and fixed fire buttons, not third-person camera mode.

## File structure and decoding

A file contains one JSON object. Field names, control types, mode strings, and key names are case-sensitive. JSON itself does not support comments; `#` comments are supported only inside a macro's `script` string.

| Top-level field | JSON type | Required / default | Meaning and validation |
|---|---|---|---|
| `name` | string | Required | Display name; not the library ID. No nonempty-name check in `validate()`. |
| `controls` | array of control objects | Required | May be empty. Each element requires `type`. |
| `package` | string | Optional; absent | Android package association used for package lookup; no package-name syntax validation. |
| `description` | string | Optional; absent | Human-readable description. |
| `aspect` | number | Optional; `16 / 9` | Designed-for width/height ratio. No numeric range check. Runtime circular geometry uses the actual engine screen dimensions; editor surfaces use the aspect passed to them. |
| `lookToggleKey` | string | Optional; `"Grave"` | Toggles mouse-look when a `look` control exists. |
| `freeCursorKey` | string | Optional; `"Alt"` | Temporarily disables effective mouse-look while held. |
| `startInLook` | boolean | Optional; `false` | Initial mouse-look state, also applied when replacing the engine's keymap. |
| `mouseSensitivity` | number | Optional; `1` | Global multiplier on look sensitivity; no range check. |

Missing optional fields (or JSON `null`) use the fallback described here. A required numeric field has **no decode default**, even if the visual editor supplies an initial value when adding that control. Unknown extra fields are not a way to extend behavior: Codable ignores fields it does not decode, and re-encoding drops them. There is no required version field.

`Keymap.load` / `decode` decode the JSON; they do **not** call `validate()`. Library saving validates separately. The distinction matters when opening a hand-edited file.

### Coordinates, distances, and rounding

A point is normally `[x, y]`. The decoder also accepts `{"x": x, "y": y}`. Use two-element arrays; the decoder reads the first two elements without an explicit trailing-element check.

- `(0, 0)` is the top-left of the **guest display**, and `(1, 1)` is the bottom-right.
- X is a fraction of guest width; Y is a fraction of guest height. Both coordinates must be in inclusive `0...1` for validator-checked points and macro points.
- Joystick, look, and skill `radius` values are fractions of **screen width**, not percentages of height or diameter. A width-radius `r` corresponds to a normalized Y offset of `r × (width / height)` for a round gesture.
- Pinch `spread` is a horizontal half-separation in normalized X units. Scroll `distance` is a normalized Y displacement; it is not a width-based radius.
- Runtime touch positions are clamped to the screen. Pixel conversion is `round(x × (width - 1))`, `round(y × (height - 1))`.
- Saving encodes points as arrays rounded to four decimal places. Other numeric fields are not all rounded this way.

Normalized coordinates adapt to resolution changes, not to arbitrary HUD rearrangements or aspect-ratio changes.

## Keys, modes, and dispatch

### Canonical key names

Use the exact names from `KeyNames`, not overlay abbreviations such as `LMB`, `Esc`, or `Wh↑`:

| Group | Accepted names |
|---|---|
| Letters and numbers | `A`–`Z`, `0`–`9` (US-layout physical-key labels) |
| Common keys | `Space`, `Enter`, `Tab`, `Escape`, `Backspace`, `Delete`, `CapsLock` |
| Modifiers | `Shift`, `RightShift`, `Ctrl`, `RightCtrl`, `Alt`, `RightAlt`, `Cmd`, `RightCmd`, `Fn` |
| Navigation | `Up`, `Down`, `Left`, `Right`, `Home`, `End`, `PageUp`, `PageDown` |
| Punctuation | `Grave`, `Minus`, `Equal`, `LeftBracket`, `RightBracket`, `Backslash`, `Semicolon`, `Quote`, `Comma`, `Period`, `Slash` |
| Keypad | `Num0`–`Num9`, `NumPlus`, `NumMinus`, `NumMultiply`, `NumDivide`, `NumEnter`, `NumDecimal` |
| Function keys | `F1`–`F12` |
| Mouse | `MouseLeft`, `MouseRight`, `MouseMiddle`, `Mouse4`, `Mouse5`, `WheelUp`, `WheelDown` |
| Gamepad | `Pad.A`, `Pad.B`, `Pad.X`, `Pad.Y`, `Pad.L1`, `Pad.R1`, `Pad.L2`, `Pad.R2`, `Pad.L3`, `Pad.R3`, `Pad.Up`, `Pad.Down`, `Pad.Left`, `Pad.Right`, `Pad.Menu`, `Pad.Options`, `Pad.Home` |

There is no general chord syntax such as `"Ctrl+R"`. Walk, sprint, scope, and cancellation modifiers are separate fields. Left and right modifier names are distinct; `Alt` does not automatically mean `RightAlt`.

The macOS play-session adapter reserves **F12 for hint visibility**, even though `F12` is a known schema key. Command-modified ordinary key events are passed to macOS for shortcuts. A known key name therefore does not guarantee that every host adapter delivers it to a control.

### Control modes

The eight non-joystick/non-look types accept optional `mode`:

| `mode` | Active when |
|---|---|
| `always` (default) | In both cursor and look modes. |
| `look` | `lookMode` is on and the free-cursor key is not held. |
| `cursor` | Effective look is off, including while the free-cursor key is held. |

`joystick` and `look` have no decoded `mode` field and resolve to `always`. Mouse motion still drives a look control only during effective look; see gamepad exceptions below.

The engine checks the look-toggle key first, then the free-cursor key, before ordinary key dispatch. A look-toggle event is consumed when a look control exists. The free-cursor key is consumed while look mode is on; releasing it restores effective look. If both globals use the same key, the toggle branch wins. Avoid assigning ordinary actions to these keys: the validator does not reserve them.

**Shift versus Alt:** Shift is not intrinsically a sprint key; it sprints only when configured as `sprintKey`. Alt's default global free-cursor role takes precedence over ordinary control dispatch while look mode is on. It does not disable an `always` joystick or override Shift's configured multiplier. If Alt is also used as a walk/sprint key, its consumed event does not directly refresh the joystick, although its held state can affect a later refresh. Prefer a separate modifier, as the BGMI preset does with Ctrl for walking.

### One key can drive several controls

Since 0.1.9 the validator does not reject a key that is already bound to another control, in any mode. This is intentional: binding the same key to two or three `tap` controls makes one press touch all of those positions at once.

On a normal key-down the engine invokes **every active matching control**, not just the first, so an `always` binding and a `look` binding on the same key can both fire. Ordinary repeated OS key-downs are ignored while held. Key-up is processed for matching controls regardless of their current mode. Each simultaneous control uses its own touch slot, so a shared key counts toward the ten-slot limit once per control. Sharing a key with a joystick, look, or modifier can produce surprising combinations; test shared bindings in a safe area first.

## The ten control types

All objects require `type`. The canonical values are `tap`, `turbo`, `joystick`, `look`, `skill`, `swipe`, `combo`, `scroll`, `pinch`, and `macro`. The decoder also accepts `fire` as `tap` and `aim` as `look`; saving emits the canonical name.

`label` is an optional display string on tap, turbo, skill, swipe, combo, and macro only. It does not select a game action. `mode` defaults to `always` wherever supported. Required fields below have no implicit JSON defaults.

### `tap`

| Field | Required / default | Meaning |
|---|---|---|
| `key` | Required string | Trigger key. |
| `at` | Required point | Touch position. |
| `mode`, `label` | Optional | Common fields above. |

Despite its name, a tap control sends **touch-down on key-down and touch-up on key-up**. It can hold a fire button; it is not a fixed-duration macro tap.

### `turbo`

| Field | Required / default | Meaning / validated range |
|---|---|---|
| `key`, `at` | Required string, point | Trigger and position. |
| `intervalMs` | Required number | Start-to-start tap interval, **at least 20 ms**; no upper bound checked. |
| `mode`, `label` | Optional | Common fields. |

Starts immediately and repeats while held. Each touch lasts `min(40, intervalMs / 2)` milliseconds. Key-up cancels repetition and lifts the touch.

### `joystick`

| Field | Required / default | Meaning / validated range |
|---|---|---|
| `center` | Required point | Initial touch-down position. |
| `radius` | Required number | Ring radius as a fraction of width; **greater than 0 and at most 0.5**. |
| `up`, `down`, `left`, `right` | Optional key strings; absent | Direction bindings. No implicit WASD bindings on decode. |
| `stick` | Optional string; absent | Use `"left"` for the engine's analog movement input. |
| `travel` | Optional number; `1` | Actual push-distance multiplier, inclusive **`0.25...4`**. |
| `walkKey` | Optional key string; absent | Applies `walkScale` while held. |
| `walkScale` | Optional number; `0.5` | Walk multiplier; no numeric range validation. |
| `sprintKey` | Optional key string; absent | Applies `sprintScale` while held. |
| `sprintScale` | Optional number; `1.6` | Sprint multiplier; no numeric range validation. |

Validation requires at least one direction key or a non-null `stick`. It does not validate the stick name. Although the model comment mentions left/right, the movement implementation reads the analog stick only when `stick == "left"`; do not use `"right"` for movement.

For a nonzero direction `(dx, dy)`, let `mag = sqrt(dx² + dy²)`. The engine uses:

```text
scale = 1 for keyboard direction; otherwise min(analog magnitude, 1)
scale *= walkScale   if walkKey is held   (fallback 0.5)
scale *= sprintScale if sprintKey is held (fallback 1.6)
r = radius × (travel or 1) × scale
x = center.x + (dx / mag) × r
y = center.y + (dy / mag) × r × (screenWidth / screenHeight)
```

The target is clamped to the screen. Diagonal keys are normalized, so they do not inherently move farther. Nonzero keyboard direction takes precedence over analog input; if the summed keyboard direction is zero, left-stick input can take over. Analog movement must exceed magnitude `0.15` after the per-axis dead zone.

**Travel changes the emitted touch displacement, not the base ring radius.** The editor may draw an additional green travel ring, but the `radius` value remains unchanged. Walking and sprinting multiply together if both keys are held; neither takes precedence. With omitted scale fields their combined factor is `0.5 × 1.6 = 0.8`. These factors do not guarantee walking or sprinting in a particular game.

### `look`

| Field | Required / default | Meaning / validated range |
|---|---|---|
| `center` | Required point | Touch anchor / recenter position. |
| `radius` | Required number | Recenter threshold in width units; **greater than 0 and at most 0.5**. |
| `sensitivity` | Required number | Base look multiplier; **greater than 0**, no upper bound checked. |
| `stick` | Optional string; absent | Use `"right"` for controller look. |
| `stickSpeed` | Optional number; `900` | Full-deflection virtual mouse movement per second, before sensitivity multipliers; no range check. |
| `scopeKey` | Optional key string; absent | Held sensitivity modifier, not an automatic ADS touch. |
| `scopeSensitivity` | Optional number; `0.5` | Scope multiplier; no range check. |

Only one look control is permitted by validation. Mouse look drags from `center`, lifting and re-pressing when accumulated movement exceeds the width-based radius. At total sensitivity 1, one host movement point corresponds to one guest pixel before normalization.

```text
effective sensitivity = control.sensitivity
                      × engine/session sensitivity
                      × (mouseSensitivity or 1)
                      × (scopeSensitivity or 0.5, only while scopeKey is held)
```

The engine/session sensitivity defaults to 1 when constructing the engine; it is not another field of this JSON object. A separate tap control is needed to touch an ADS button.

### `skill`

| Field | Required / default | Meaning |
|---|---|---|
| `key`, `at` | Required string, point | Trigger and skill-button position. |
| `radius` | Required number | Width-based aim reach. `0` means plain hold; positive values enable aiming. No radius range check in `validate()`. |
| `quickCast` | Optional boolean; `false` | Schedules touch release 30 ms after pressing instead of waiting for key-up. |
| `cancelKey`, `cancelAt` | Optional key string and point; absent | Both are needed: on skill-key release while `cancelKey` is held, move to `cancelAt` before lifting. |
| `mode`, `label` | Optional | Common fields. |

Aimed skills use the direction from screen center to the cursor, applied around `at`, not a direction from the skill button itself. Reach scales with cursor distance up to `radius`. The engine ignores aiming within distance `0.01` of screen center and reaches full radius at distance `0.35` in width-based units.

`cancelKey` is not part of this control's dispatch-key list, so it is not checked as a known key or captured solely because it appears here. For keyboard cancellation in the play-session adapter, the key must reach the engine through another mapped/global role for the held-key test to work; the gamepad adapter posts supported button events directly. Quick-cast's automatic release does not perform the key-up cancellation drag.

### `swipe`

| Field | Required / default | Meaning / validated range |
|---|---|---|
| `key` | Required string | Starts the gesture. |
| `from`, `to` | Required points | Start and end. |
| `durationMs` | Required number | **At least 10 ms**; no upper bound checked. |
| `mode`, `label` | Optional | Common fields. |

Presses at `from`, interpolates toward `to`, then releases. Releasing the trigger early does not abort this timed gesture. Interpolation uses at least two moves, otherwise approximately one move per 16 ms.

### `combo`

| Field | Required / default | Meaning / validated range |
|---|---|---|
| `key` | Required string | Starts the sequence. |
| `points` | Required point array | **At least one** point. |
| `intervalMs` | Required number | Start-to-start spacing, **at least 20 ms**. |
| `mode`, `label` | Optional | Common fields. |

Each point receives a 40 ms touch, starting at `index × intervalMs`. Touches overlap when the interval is below 40 ms. Trigger release does not stop the sequence.

### `scroll`

| Field | Required / default | Meaning |
|---|---|---|
| `at` | Required point | Swipe start. |
| `distance` | Required number | Signed normalized Y displacement; no range check. |
| `durationMs` | Optional number; `120` | Swipe duration; no validator range check. |
| `upKey`, `downKey` | Optional strings; `"WheelUp"`, `"WheelDown"` | Triggers. |
| `mode` | Optional; `always` | Activation mode. |

For positive `distance`, the up trigger moves toward `at.y + distance` (down the screen), and the down trigger toward `at.y - distance`; endpoints are clamped. A wheel event dispatches by its sign, not one gesture per unit of its magnitude. Prefer positive, finite gesture durations even though this type lacks duration validation.

### `pinch`

| Field | Required / default | Meaning |
|---|---|---|
| `inKey`, `outKey` | Required key strings | Zoom-in / zoom-out triggers; no default keys on decode. |
| `center` | Required point | Midpoint between the two fingers. |
| `spread` | Required number | Far horizontal distance from center to **each** finger; no range check. |
| `durationMs` | Optional number; `200` | Gesture duration; no validator range check. |
| `mode` | Optional; `always` | Activation mode. |

The in trigger moves two fingers outward from `±0.15 × spread` to `±spread`; the out trigger reverses this. Coordinates are clamped. Full far separation is `2 × spread`. Trigger release does not abort the gesture. Use positive, finite spread and duration values.

### `macro`

| Field | Required / default | Meaning |
|---|---|---|
| `key` | Required string | Starts the script. |
| `script` | Required string | Newline-separated language below; escape line breaks as `\n` in JSON. |
| `loop` | Optional boolean; `false` | Repeat while the trigger remains held and the control stays active. |
| `mode`, `label` | Optional | Common fields. |

A macro has no movable screen anchor. Its coordinates live inside the script, and the canvas does not hit-test it; select it through the control list/inspector where available.

## Macro language

One command occupies each line. Commands are case-insensitive; finger identifiers retain their spelling. Spaces, tabs, and commas separate tokens. Text after the first `#` is a comment, and empty lines are ignored. There is no conditional, image-recognition, or game-state instruction.

| Syntax | Effect and timing |
|---|---|
| `tap x y` | Press a temporary finger, advance **40 ms**, release it. |
| `press finger x y` / `down finger x y` | Put a named finger down; no time advance. Re-pressing the same down finger releases it first. |
| `move finger x y` | Move the named finger; if it is not down, press it at that point instead. No time advance. |
| `release finger` / `up finger` | Lift a named finger if down; no time advance. |
| `swipe x1 y1 x2 y2 durationMs` | Interpolated swipe; advances time by duration, which must be **at least 1 ms** (different from a swipe control's 10 ms minimum). |
| `wait durationMs` / `sleep durationMs` | Advance time by a value **at least 0**. |
| `repeat count` … `end` | Repeat the enclosed block; integer count **1...1000**, inclusive. Nested blocks are supported. |

All points must be in `0...1`. A finger name must be a nonnumeric token; `A` and `B` are suitable. Commands other than `end` enforce exact argument counts; the current parser does not check trailing tokens on `end`, but use a bare `end`. Missing or unmatched `end` is an error. Any named fingers still down at script completion are lifted automatically.

A readable script example (store its lines in the JSON `script` string):

```text
# Hold one finger while tapping twice with temporary fingers.
press A 0.2 0.8
repeat 2
  tap 0.8 0.8
  wait 60
end
move A 0.3 0.8
wait 100
release A
```

### Limits and cancellation

- Each `repeat` has a finite 1–1000 count. Compilation permits at most **20,000 emitted touch steps**, including final releases, per run. A swipe expands to a press, `max(2, Int(durationMs / 16))` moves, and a release.
- The engine has **10 concurrent touch slots**, shared by all controls, macros, mouse-look, and direct pointer touches. A new finger cannot start when all slots are occupied.
- `validate()` only **parses** macro text; it does not compile it. A syntactically valid macro may exceed the step limit. The engine attempts parse and compilation on trigger and does not run the macro if either throws.
- There is **no explicit nesting-depth limit, total-duration cap, or general finite-number check for macro durations**. The step cap is not a CPU/time budget for nested empty/wait-only repeats. Use modest, finite durations and shallow repeats; do not treat accepted text as a resource-safety guarantee.
- A non-looping macro continues after key-up. A looping macro stops on key-up, invalidates its pending steps, and lifts its named/temporary fingers.
- Successful restart of the same macro cancels its previous scheduled run and lifts its owned fingers before scheduling anew. Ordinary OS key repeat does not retrigger it.
- Loop iterations restart after `max(compiled duration, 16)` ms, only while held and active. There is no fixed total iteration limit for `loop: true`.
- Changing modes cancels a macro that becomes inactive; an `always` macro does not become inactive simply because look mode changes. Engine reset cancels all timers, releases touches, and clears held keys/sticks. Replacing the keymap resets first. The play session also resets input on focus loss or input suspension.

### BGMI's contextual `F` macro is not contextual detection

In the [published BGMI JSON](../../keymaps/bgmi.json), `F` is labeled “Drive / Open door / Pick up / Exit vehicle”. Its script taps **all four positions, in order**:

```text
tap 0.676 0.423
wait 40
tap 0.677 0.686
wait 40
tap 0.593 0.726
wait 40
tap 0.874 0.448
```

Each tap itself lasts 40 ms; the three additional waits make this a 280 ms sequence. There is no screen inspection or selection of whichever action is currently available. Any other active button under any of those coordinates can be triggered. The same fixed-coordinate caveat applies to the preset's Backspace and Mouse4 macros. Consult the [BGMI guide](../guide/bgmi-layout.md#contextual-key-limitations) before testing or adapting them.

## Gamepad behavior

Gamepad buttons use the same key dispatch as keyboard buttons. L1/R1 are shoulders, L2/R2 triggers, and L3/R3 thumbstick clicks. Buttons must be exposed by the host controller's extended-gamepad profile; availability varies by device.

Movement uses `joystick.stick: "left"`; aim uses `look.stick: "right"`. Stick Y is converted so up is negative guest Y. Each axis has a `0.12` dead zone; joystick movement also has the `0.15` magnitude threshold described above.

The engine reads **right-stick** state for look. A non-null look `stick` permits that motion even in cursor mode; the runtime does not actually compare its string to `"right"`. In effective look, right-stick motion can also drive aim when the field is absent. These are current implementation details, not arbitrary stick routing. The validator accepts stick strings without checking them, so use the supported conventional values.

Right-stick motion is integrated on ticks with `dt` capped at 100 ms, using `stickSpeed` and the same sensitivity/scope multipliers as mouse look. Freeing the mouse cursor does not necessarily suppress configured controller aim.

## Complete JSON example

This self-contained example includes all ten canonical types without unintended duplicate dispatch keys. Coordinates are illustrative, not a playable HUD preset. Required fields, key names, modes, and ranges match the source; actual runtime/game behavior still needs testing.

```json
{
  "name": "Control reference example",
  "aspect": 1.7777777778,
  "lookToggleKey": "Grave",
  "freeCursorKey": "Alt",
  "startInLook": false,
  "mouseSensitivity": 1,
  "controls": [
    {"type": "tap", "key": "MouseLeft", "at": [0.85, 0.75], "mode": "look", "label": "Fire position"},
    {"type": "turbo", "key": "T", "at": [0.8, 0.6], "intervalMs": 100},
    {"type": "joystick", "center": [0.2, 0.7], "radius": 0.06, "travel": 1.5, "up": "W", "down": "S", "left": "A", "right": "D", "stick": "left", "walkKey": "Ctrl", "walkScale": 0.5, "sprintKey": "Shift", "sprintScale": 1.6},
    {"type": "look", "center": [0.6, 0.4], "radius": 0.14, "sensitivity": 1, "stick": "right", "stickSpeed": 900, "scopeKey": "MouseRight", "scopeSensitivity": 0.5},
    {"type": "skill", "key": "Q", "at": [0.8, 0.8], "radius": 0.07, "quickCast": false},
    {"type": "swipe", "key": "N", "from": [0.7, 0.3], "to": [0.8, 0.3], "durationMs": 120},
    {"type": "combo", "key": "C", "points": [[0.7, 0.8], [0.8, 0.8]], "intervalMs": 100},
    {"type": "scroll", "at": [0.5, 0.5], "distance": 0.15, "mode": "cursor"},
    {"type": "pinch", "inKey": "Equal", "outKey": "Minus", "center": [0.5, 0.5], "spread": 0.18},
    {"type": "macro", "key": "F", "script": "tap 0.6 0.4\nwait 40\ntap 0.7 0.5", "loop": false}
  ]
}
```

The sample's `scopeKey` only changes sensitivity. Add a separately positioned ADS tap if the game requires one; sharing `MouseRight` with that tap is intentional and permitted by the look-key exception.

## Validation boundaries

`validate()` checks point bounds, known dispatch keys (repeated keys are allowed), one-look-only, joystick/look radii, joystick travel and presence of movement input, positive look sensitivity, turbo/combo interval minima, swipe duration minimum, a nonempty combo, and macro **parsing**.

It does **not** comprehensively validate every field. In particular, it does not check top-level aspect/sensitivity/global-key names, stick names, movement/scope multipliers, stick speed, skill radius/cancel-key names, scroll distance/duration, pinch spread/duration, macro compiled length, or touch-slot demand. Negative or extreme values in unchecked fields can produce unintended behavior or unsafe runtime conversions. Prefer finite positive scales and gesture durations; do not use validation success as permission to supply arbitrary numbers.

## Loading, saving, and personal overrides

- The library ID is the filename without `.json`, not `name` or `package`. Saved IDs must match `[a-z0-9][a-z0-9-]*` and contain at most 64 characters.
- Normal library lookup scans the configured **user keymap folder first**, then bundled directories in their configured order. The first decodable file for an ID wins. Unreadable/undecodable files are skipped during enumeration; semantic validation is not performed there.
- A user file with the same ID as a bundled preset overrides it. Updating the application does not replace that personal copy. Saving a preset writes the user's copy, never the bundled file.
- Resolution accepts an existing explicit file reference containing `/` or ending in `.json`; that direct file takes precedence. Otherwise it looks for an ID (optionally stripping `.json`), then a matching Android package.
- Package lookup returns the first matching library entry. Package association alone is not a guarantee that a current foreground app will switch an already-running mapping session.
- Library save validates, creates the user directory if needed, and writes atomically. Output is pretty-printed with sorted keys; points are normalized to the array representation and rounded as described above.
- **Revert** discards unsaved editor changes by reloading the currently resolved ID. It does not remove a saved personal override. **Delete My Copy** removes that user file and exposes the bundled preset again if one exists.
- **Duplicate** and the app's **Import** action allocate a free ID and select the new saved copy. Import does not blindly overwrite the source filename's existing ID. Export writes the current editor model; the export path itself does not call `validate()`.
- Starting mapping from the app can use the unsaved editor model when the selected instance and keymap ID match. This does not make those edits persistent. The native player overlay stages its own edits: **Save** validates and invokes its save callback, while **Cancel** dismisses them.

To adopt the currently published BGMI layout when an older personal override exists, follow the [BGMI guide's existing-user note](../guide/bgmi-layout.md#3-select-kestrels-bgmi-preset) rather than assuming an app update replaced it.

## Visual editor shortcuts and defaults

The canvas must have keyboard focus. These are editor operations, not gameplay key bindings:

| Input | Result |
|---|---|
| Click a control | Select it. Macros are not canvas hit targets. |
| Drag selected control | Move its anchor. Swipe/combo points move together; the edit is clamped to keep points on screen. Skill `cancelAt` stays fixed. |
| Double-click empty space | Add a tap with an unused letter, digit, or function key. |
| Ordinary known key | Rebind a selected single-key control. Modifier presses can also rebind it. The key may already be used elsewhere. |
| Right / middle / side mouse button | Rebind the selected single-key control to `MouseRight`, `MouseMiddle`, `Mouse4` or `Mouse5`. Left click stays reserved for selecting and dragging. |
| Scroll wheel | Rebind the selected single-key control to `WheelUp` or `WheelDown` (one rebind per scroll gesture). |
| `[` / `]` | Divide/multiply radius by `1.1` for joystick, look, or positive-radius skill; editor radius clamp is `0.01...0.5`. |
| `Shift+[` / `Shift+]` | Divide/multiply joystick **travel** by `1.1`, without changing base radius; clamp `0.25...4`, round to two decimals, omit the field near 1. |
| Backspace / Delete | Remove the selected control. |
| Escape | Deselect; it is not the overlay's Cancel button. |
| Command-S | Invoke Save. |

The bracket handler checks **Shift first**. Alt/Option does not select travel editing: Alt+bracket without Shift follows radius editing, and Shift+Alt+bracket follows travel editing. Pressing a modifier while a single-key control is selected can itself rebind that control. Use the inspector/JSON for bindings whose keys are reserved by editor shortcuts.

Joystick, look, scroll, and pinch are multi-key controls and are not rebound by the canvas's single-key operation. Use their inspector fields or JSON. The canvas does not implement an undo/redo or duplicate-control shortcut; the app offers **Revert** for unsaved changes and **Duplicate** for the whole keymap.

New-control **editor presets are not JSON decode defaults**: turbo interval 100 ms; joystick radius `0.065` with left stick and available WASD or arrow keys; look radius `0.14`, sensitivity 1, right stick and speed 1000; skill radius `0.07`; swipe duration 120 ms; combo interval 100 ms; scroll distance `0.15` and duration 120 ms; pinch spread `0.18` and duration 180 ms. In particular, an omitted look `stickSpeed` runs at **900**, and omitted pinch duration runs at **200 ms**, not those editor insertion values.

## Source of truth

This reference follows these implementations:

- [Keymap model, point encoding, control decoding and validation](../../Sources/KestrelKeymap/Keymap.swift)
- [Touch engine, modes, timing, movement and gamepad interpretation](../../Sources/KestrelKeymap/Engine.swift)
- [Macro parser and compiler](../../Sources/KestrelKeymap/MacroScript.swift)
- [Canonical key names](../../Sources/KestrelKeymap/KeyNames.swift)
- [Editing operations and inserted-control presets](../../Sources/KestrelKeymap/KeymapEditing.swift)
- [Library lookup, override and save rules](../../Sources/KestrelKeymap/KeymapLibrary.swift)
- [Canvas shortcuts](../../Sources/KestrelPlay/KeymapCanvas.swift), [live editor save/cancel](../../Sources/KestrelPlay/PlayerKeymapOverlay.swift), and [host input adapter](../../Sources/KestrelPlay/PlaySession.swift)
- [App keymap persistence and selection](../../Sources/KestrelApp/AppModel+Play.swift)

Game-specific action names remain intended mappings, not schema-proven behavior. Test changed coordinates and gestures against the matching HUD in a safe practice environment before relying on them.
