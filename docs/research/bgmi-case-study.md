# BGMI graphics: separating a crash from a black screen

## Scope

The investigation used BGMI (`com.pubg.imobile`) on an arm64 Android 16 Google Play image with Android Emulator 37.1.11. A measured guest `libEGL_emulation.so` had build ID `49e83397e4f4b857e7de7c88630b8685`. Later SDK/image versions may behave differently. Game data was preserved and experiments used an isolated clone before the successful setting was applied to the maintainer's instance.

## 1. Reproduce the crash independently

BGMI's crash involved `createNativeSync`, reached from the emulated EGL surface swap path, with a null-context-related fault at address `0xb0`. Rather than patch the game, an original [EGL diagnostic activity](../../diagnostics/src/org/kestrel/diagnostics/EGLSwapActivity.java) exercised a swap after releasing the current context. It reproduced the native failure on the same driver.

Disabling the emulator's GLAsyncSwap feature prevented that diagnostic crash. Kestrel exposes this as the optional **EGL crash compatibility** setting. In BGMI, however, the app then remained alive with a black screen. “Does not crash” was insufficient evidence of working rendering.

## 2. Find the earlier context failure

Startup logs showed `eglCreateContext(1749)` returning `EGL_BAD_ATTRIBUTE` before later synchronization failures. An original zero-context-flags test established that `EGL_CONTEXT_FLAGS_KHR=0` was rejected. The inspected source predicate required at least one known flag bit rather than allowing no flags.

A small [proposed source patch](../../diagnostics/gfxstream-egl-zero-flags.patch) and [standalone validation regression](../../diagnostics/egl_context_flags_regression.cpp) preserve this finding. The source examined was pinned to gfxstream revision `d047a57228332d995d36600792fa9ccc26cf8ae6`. A host-side predicate test and a patch that applies are **not** an Android driver replacement: that library depends on Android platform components beyond the standalone NDK. No corrected replacement EGL library was built and shipped as this game's fix.

## 3. Test a supported guest driver alternative

A package-name search found no separately installed ANGLE package. The initial inference that ANGLE was unavailable was too strong: the image could still include a built-in implementation.

The next isolated experiment selected ANGLE **for BGMI only**, keeping the previously selected GLAsyncSwap-off condition constant. Android's per-app settings use two parallel comma-separated lists:

- `angle_gl_driver_selection_pkgs`
- `angle_gl_driver_selection_values`

The BGMI entry was paired with `angle`. Startup logs then reported built-in ANGLE 2.1 using a Vulkan renderer on Apple M2 Pro, despite the lack of a separate package. The game displayed its resource-download artwork instead of a black frame. The same BGMI-only selection was applied to the positively identified user instance and its screenshot also rendered. Subsequent gameplay was user-reported and shown in a maintainer screenshot.

## Reproduce cautiously

This is a manual, game-specific workaround, **not an automatic feature of selecting Kestrel's BGMI keymap**. First identify the intended emulator serial and profile; do not run unqualified ADB commands against an arbitrary connected device. Save the original values and their absence/presence, and inspect `angle_gl_driver_all_angle` without globally enabling it.

If both per-app lists are absent/empty, the experiment used:

```sh
adb -s YOUR_SERIAL shell settings put global angle_gl_driver_selection_pkgs com.pubg.imobile
adb -s YOUR_SERIAL shell settings put global angle_gl_driver_selection_values angle
```

**Do not overwrite existing lists with these two commands.** If other apps have entries, preserve their positional pairing and change/add only BGMI's entry. Stop if list lengths disagree. Restart only BGMI when it is safe to lose its current session. Check process-associated graphics logs to prove the selected driver actually loaded; writing settings successfully does not prove driver selection.

To revert, restore the exact prior strings, or delete a key only if it was originally absent. Do not replace the game's APK, edit anti-cheat code, change system identity or disable integrity checks for this experiment. Enabling guest per-app ANGLE is distinct from changing the emulator's **host** GPU mode.

## Outcome and limits

- Independent diagnostics reproduced driver failures without game modifications.
- GLAsyncSwap-off alone removed a crash but did not produce the game screen.
- Per-app built-in ANGLE, under the recorded conditions, produced visible game rendering.
- A resource-download screenshot is not gameplay verification; later user gameplay reports are a separate evidence level.
- The driver source patch is not the runtime workaround and is not installed by Kestrel.
- No promise is made for every BGMI release, PUBG regional variant, shader workload, network feature or publisher policy.

![Maintainer gameplay in Kestrel after the graphics workaround](../assets/bgmi-gameplay.png)

*Maintainer-supplied gameplay screenshot; bottom identifiers removed. For the matching HUD and keyboard preset, see [BGMI layout](../guide/bgmi-layout.md).*
