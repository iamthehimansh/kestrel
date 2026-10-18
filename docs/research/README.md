# Research: how Kestrel was built

Kestrel was created and vibe-coded with [Cana.build](https://cana.build), using its REA mod based on the open-source [REA project](https://github.com/morluto/rea). This records the tools used, not an endorsement by their authors or any emulator/game vendor.

## From observation to original implementation

The work began by examining the installed artifacts, interfaces and behavior of MuMuPlayer Pro on Apple Silicon. REA provided artifact inspection, binary analysis and interface tracing. Findings about shared-memory graphics transport, Android services, settings and input helped formulate hypotheses. They did not provide a license to copy proprietary implementation.

Kestrel was then developed as original Swift host code around Google's Android Emulator: instance configuration and management, authenticated video transport, a Metal player, keyboard/mouse/gamepad mapping, an Android touch helper, and diagnostic workloads. The Android SDK and images remain external downloads. A custom guest image was considered rather than assumed necessary; an unsuccessful image-repack experiment was preserved as a negative result.

## Index

- [Experiment ledger](experiment-ledger.md): measurements, rejected hypotheses, fixes and remaining gaps.
- [Comparative architecture analysis](comparative-analysis.md): what commercial-emulator inspection established, and what it did not.
- [BGMI EGL and ANGLE case study](bgmi-case-study.md): independent reproductions and the successful per-app workaround.
- [Audio case study](audio-case-study.md): game/guest/host evidence and an unresolved root cause despite reported recovery.
- [Detection-surface measurements](detection-surface.md): what configuration changes actually affected.
- [Runtime architecture](../guide/architecture.md): the code that shipped.
- [Diagnostics inventory](../../diagnostics/README.md): runnable original workloads.

## Method

| Step | Rule |
|---|---|
| Hypothesis | State a falsifiable cause before changing settings |
| Ownership | Identify exact process, guest, profile, ports and disk; isolate experiments |
| Control | Change one variable, keep workloads/settings comparable, record confounders |
| Ordering | Use repeated independent boots and A-B-B-A comparisons where practical |
| Measurement | Save reports and screenshots; separate launch time, callback cadence, render cost and frame age |
| Rejection | Discard interrupted runs and incorrect restorations; retain why they were rejected |
| Decision | Adopt only the justified change; no difference means no default toggle added |
| Cleanup | Stop owned processes, revoke temporary keys and verify settings restoration |

“Implemented”, “unit-tested”, “runtime-verified” and “user-reported” are not interchangeable. The [compatibility table](../guide/compatibility.md) applies this vocabulary to the preview. Small diagnostic workloads on one Mac do not establish general speed ratios or all-game support.

## Public evidence and privacy

Public artifacts include original diagnostics, test code, a small source patch/regression for the graphics investigation, sanitized findings and the experiment summaries here. Examples:

- [Diagnostic Android activities](../../diagnostics/src/org/kestrel/diagnostics/)
- [GLES workload](../../diagnostics/src/org/kestrel/glesprobe/GLESActivity.java)
- [EGL validation regression](../../diagnostics/egl_context_flags_regression.cpp)
- [Proposed gfxstream correction](../../diagnostics/gfxstream-egl-zero-flags.patch)
- [Native session probe](../../diagnostics/PlayerSessionProbe/PlayerSessionProbe.swift)
- [Original touch helper](../../touchd/touchd.c)

Raw captures were kept privately because they can contain ADB public keys, account/session identifiers, machine paths and unrelated environment data. Proprietary binaries, decompiled source, restricted system images, game APKs and user VM disks are not published. This limits independent verification of historical numbers: readers can rerun the public probes, but cannot reconstruct every private capture byte-for-byte. A clean public repository is not a complete public raw dataset, and we do not present it as one.

No game modifications, anti-cheat bypass or attestation bypass are part of the supported product. Historical research plans can contain claims later disproved; use the current case studies and measured results rather than treating an old plan as a guarantee.
