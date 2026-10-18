# Experiment ledger

This records the development experiments of October 2026. Figures below are transcribed from retained private assessment/report files; public runners and tests are linked for reproduction. They are limited observations on one Apple Silicon development machine, not a benchmark certification. Historical run names identify experiments, not public downloadable datasets.

## Performance and guest investigation

| Experiment | Hypothesis and method | Observation | Decision / limitation |
|---|---|---|---|
| Host/guest inventory | Compare actual guest versions and interfaces before tuning | MuMu guest Android 12/API 32 versus Kestrel Android 16/API 36 | Major confound; do not treat images as matched |
| Interrupted `runtime-pipe-02` | Measure launch/input on Canvas fixture | System UI ANR; service registration waited about 22,501 ms; test tap reached the dialog | Reject samples; add foreground/focus validation |
| Cold versus resume baseline | Same diagnostic app, three launches per condition | Cold-state app launches 0.72/0.76/0.42 s; resumed-state 0.22/0.20/0.20 s; callbacks about 16.67 ms | These are app launch numbers, not VM boot times or game latency |
| Pipe versus ASG | Two independent boots per transport; three samples per boot; A-B-B-A | Worst p95 19 ms for all four accepted runs; p99 20–21 ms; worst launches 0.2925/0.2314/0.2529/0.2604 s | No meaningful frame-time improvement established; retain existing default. A fifth run refused preflight supplies no measurement |
| Commercial-emulator baseline | Run original Canvas probe | Launches 0.37/0.24/0.24 s; p95 18–19 ms; drawable 1280×684 | Did not reproduce a broad gameplay speed gap; workload/image/drawable confounds remain |
| GLES workload | Original draw workload with synchronized measurement | Kestrel median draw cost about 1.31 ms, worst p95 1.64/1.49 ms; MuMu medians about 4.4–4.75 ms, worst p95 5.00/5.13 ms; frame-start p95 roughly 17.2–18.2 ms on both | Lower synchronized draw time is not a general speed ratio; frame pacing still near 60 Hz |
| Initial 120 Hz test | Increase virtual display refresh | Display declared 120 Hz while app remained at 60 Hz | Reject as proof of 120 FPS |
| Explicit min+peak 120 | Set both Android refresh preferences for the fixture | Callback interval about 8.333 ms | Diagnostic-only success; do not silently force global minimum |
| Peak-only contaminated run | Test just peak preference | Earlier minimum persisted, confounding result | Withdraw run |
| Restoration audit | Restore preferences and reboot | Asynchronous settings persistence required settle/sync and cold verification | Cleanup became part of experiment validity |
| Clean peak-only repeat | Peak at 120 with clean minimum | App still about 60 Hz | Peak alone not sufficient under that app policy |
| Product refresh wiring | Write `fpsLimit` to `hw.lcd.vsync`; inspect emulator/guest | Requested 120 reached virtual display peak while Android min/peak preferences stayed unset | Ship as virtual display refresh, not a guaranteed FPS unlock |
| Vulkan snapshots | Original Vulkan fills, save/load, then host restart | Default rejected `UNSUPPORTED_VK_APP`; opt-in save 3.17 s/load 2.26 s retained test data; after host restart load about 1,552 ms/readiness 6.19 s | Unexplained resource/ColorBuffer warnings; experimental option remains off by default |
| Guest optimizer inspection | Examine `nemu_sys_opt` before copying tuning ideas | Page-cache/compaction and process scheduling policies observed statically | Not adopted without a relevant controlled Kestrel result |

Public methods: [run.py](../../diagnostics/run.py), [transport.py](../../diagnostics/transport.py), [compare.py](../../diagnostics/compare.py), [run_gles.py](../../diagnostics/run_gles.py), [refresh.py](../../diagnostics/refresh.py), [audit_refresh_restore.py](../../diagnostics/audit_refresh_restore.py), [run_vulkan_snapshot.py](../../diagnostics/run_vulkan_snapshot.py).

## Storage and startup correctness

A profile requested 4 GiB while the emulator-created QCOW2 userdata declared 6 GiB. Regenerating config as 4G made snapshot validation reject the next boot: the baseline second start took 16.86 s and was not a successful warm resume.

The fix reads bounded disk headers/logical sizes and generates the maximum of requested and existing capacity. It does not rewrite disks or change the user's requested value. A regression failed before the fix; source and runtime checks then passed. A fresh corrected profile loaded its snapshot in 1,745 ms and reached readiness in 6.44 s. Three later resumes were 6.359685/6.356108/6.368733 s, worst 6.37 s, with snapshot-load and boot-complete assertions. The initial 27.32 s cold boot included setup and is not a valid speedup denominator.

This addresses one capacity mismatch, not Vulkan snapshots, every settings invalidation or the System UI ANR. See [DiskCapacity.swift](../../Sources/KestrelCore/DiskCapacity.swift) and [product_boot.py](../../diagnostics/product_boot.py).

Two observed shutdown cycles exited successfully in 8.27 and 7.46 s; snapshot saves reported 6,654 and 6,033 ms. Snapshot work explains part of a slow-looking graceful exit. A running process is not automatically a hang, and force-killing it can destroy useful state. Method: [observe_shutdown.py](../../diagnostics/observe_shutdown.py).

## Native streaming and input

| Area | Experiment/result | Shipped response and limit |
|---|---|---|
| Authenticated gRPC | Missing, expired and wrong-audience credentials were rejected in tests/probes | Loopback endpoint ownership, per-session signing and explicit method allowlist |
| Inline versus shared frame memory | Inline roughly 56–60 frames/s, 198–212 MiB/s, 0.105–0.113 of one core, frame age 3.4–3.7 ms; shared memory roughly 57–60 frames/s, 0.037–0.053 core, age 2.2–3.0 ms | No demonstrated producer fence for raw shared memory; copied complete frames and one pending slot preferred. Frame age is not photon latency |
| Stream renewal | Long-lived authenticated connection exposed renewal/lifecycle edge cases | Renewal/reconnect generation tests and owned cleanup; no assumption that a short stream validates longevity |
| Touch path | Original uinput helper, direct pointer and mapped input exercised with bounded probes | Shared slot ownership, held-touch release and cancellation. Timing/concurrency correctness requires more than a screenshot |
| Native layout | User found rail controls overlapping on resize | Scrollable narrow rail plus zero custom-button alignment insets; real minimum/tall-window tests |
| Fullscreen hints | User reported disappearance | Native child-window/Space attachment; isolated real fullscreen entry/exit test passed. Combined test also failed initial focus setup, retained as a distinct failed run |
| Popover input | Enabling mapping caused slider/checkbox clicks to hit Android | Explicit input suspension, held-touch reset and suspension of mappings created inside the open popover |
| Popover verification | Directly queued/CGEvent drags initially failed; instrumentation showed window ID zero | Timed NSEvents targeting the actual popover moved 50% to 22%; untick and close/resume passed. Synthetic input construction was corrected rather than declaring a false success |
| Text transport | Bulk input initially dropped; sequential ASCII and editing keys tested | Bounded ordered single-character requests; later exact expected phrase and Backspace reached diagnostic field |
| Focus-loss test | Timeout after Home originally returned nil, falsely satisfying “no editor” | Probe corrected to throw on errors; later successful negative observation passed. Intermittent observer timeouts remain a limitation |
| Host capture diagnostic | Three short commands per 500 ms budget, repeated 20 times from detached work | 60 child commands passed; does not rule out intermittent host or guest stalls |
| Joystick tuning | User requested actual travel independent of visible radius | Optional `travel` multiplier, bounds validation, editor shortcut/inspector and engine-displacement regression |
| Microphone | Emulator help identified `-allow-host-audio`; normal input otherwise supplies silence | Separate opt-in setting, Sound dependency and bundle permission text; no actual voice-chat runtime proof |

Methods: [probe_stream.py](../../diagnostics/probe_stream.py), [shared_frame.py](../../diagnostics/shared_frame.py), [PlayerSessionProbe](../../diagnostics/PlayerSessionProbe/PlayerSessionProbe.swift), [NativeSessionWindowProbe](../../diagnostics/NativeSessionWindowProbe/NativeSessionWindowProbe.swift), [touch helper](../../touchd/touchd.c).

## Graphics, audio and detection

The [BGMI case study](bgmi-case-study.md) distinguishes the null-context async-swap crash, zero-flags context rejection, unsuccessful partial workaround and successful guest ANGLE selection. The [audio case study](audio-case-study.md) records nonzero mixed signal, normal routing and later user-reported recovery without a proven root cause. [Detection research](detection-surface.md) records configuration changes that left 15/15 indicators present and an image repack that failed to boot.

## Recovery and publication

An accidental reset discarded uncommitted player work during integration. Recovery used archived pre-edit snapshots plus later successful edits, compared against the merged commits rather than blanket Undo. A green build initially missed missing runtime wiring: native keymapping/replay/shutdown links, settings merging, disk-capacity preservation and refresh generation were recovered separately. Tests and build were rerun after each batch, then a local recovery checkpoint was committed.

Public preparation includes an original Git bundle and source backup, separate publication clone, whole outgoing-history identity/data checks, sanitized findings instead of raw logs, and app-only DMG checks. Old experimental notes can be incomplete or overconfident; these current summaries supersede their unsupported conclusions. No claim of commercial-emulator parity or universal game acceptance follows from this ledger.
