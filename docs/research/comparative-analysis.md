# Comparative architecture findings

This is a summary of artifact/interface research, not a reconstruction of a proprietary emulator. REA-assisted inspection of MuMuPlayer Pro informed questions; Kestrel's implementation uses original source and Google's emulator. The public repository contains findings and methods, not the inspected proprietary binaries or decompiled code.

## Findings and design responses

| Area | Research observation | Kestrel response |
|---|---|---|
| Graphics transport | A commercial guest/host interface used a shared-memory ring associated with `/dev/vaddress` | Compare stock pipe and ASG before changing defaults; the measured Canvas workload showed no meaningful frame-time benefit |
| Input | Both investigated approaches ultimately deliver Linux input events; host-to-guest transport differs | Build an original bounded touch helper and deterministic keymap engine, with explicit touch ownership and cancellation |
| Settings | Some names map to concrete guest/renderer behavior, including refresh scheduling and MoltenVK-related fast math | Verify each setting's effect; expose virtual display refresh honestly and do not use optional tuning to hide a weak baseline |
| Guest optimizer | Static inspection found page-cache management/compaction and process CPU policy | Do not copy a proprietary optimizer or apply unmeasured caps to Kestrel |
| Android image | Commercial guest Android 12/API 32 differs from stock API 36 used by Kestrel | Treat guest version/services as performance confounders, not a fixed universal runtime |
| Host frame presentation | Shared-memory exchange is possible but ownership/fencing matters | Use complete copied frames and a bounded mailbox until tear-free synchronization is demonstrated |

A sampled optimizer CPU setting of `15000 100000` was a finding about that target, not a recommended Kestrel policy. It was not adopted as an unexplained performance fix.

## Corrections retained

Early assumptions were corrected as evidence improved: the inspected image included Google Play services, and the purpose of `libvpxsf` was not established. A component name is not proof of its function. Similarly, “no separately installed ANGLE package” did not imply no built-in ANGLE in the stock image; that incorrect inference was corrected during the [BGMI investigation](bgmi-case-study.md).

The benchmark workloads did not substantiate a general user-observed commercial-emulator speed ratio. Some original GLES draw measurements favored Kestrel while frame cadence remained similar. Neither result establishes full-game parity; see the [ledger](experiment-ledger.md).

## Reproducible approach

1. Identify versions, architecture, hashes/build IDs and dependency boundaries before comparing behavior.
2. Inventory services/interfaces without assuming a proprietary binary's source is available or redistributable.
3. Form an implementation-independent hypothesis.
4. Build an original small diagnostic workload on the supported public platform.
5. Measure matching conditions, explicitly list unavoidable differences, and reject interrupted/confounded runs.
6. Implement original code only where evidence justifies it; retain rejected hypotheses.

Source examples: [MuMu observation runner](../../diagnostics/run_mumu.py), [service inspection](../../diagnostics/inspect_mumu_services.py), [GLES comparison](../../diagnostics/compare_gles.py), [transport comparison](../../diagnostics/transport.py). Review scripts and ownership assumptions before executing them; these are research tools, not permission to control an unrelated running instance.

## Distribution boundary

The MIT license covers Kestrel's original code, not game artwork, Android Google Play images, commercial binaries or dependency code with separate notices. Public methods and limited factual findings are not a substitute for a legal review. No affiliation or endorsement by the studied vendors is implied.
