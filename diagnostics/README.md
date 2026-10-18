# Kestrel runtime diagnostics

An original, bounded Android workload for collecting comparable evidence. It contains no competitor code and does not modify or hook games.

## Build

`python3 -u diagnostics/build.py`

Requires the installed Android SDK platform 36, build-tools 35.0.0 and a JDK. The output is `.build/diagnostics/kestrel-diagnostics.apk`. A disposable local test certificate is generated for each build; it is not a release signing identity. Rebuilding requires removing an older install of this diagnostic app first. No other apps should be uninstalled.

## Measurements and limits

- GLES vendor, renderer, version, extension declarations and maximum texture size from a 1x1 ES2 pbuffer. These are reported capabilities, not conformance tests. The pbuffer is NOT a graphics throughput benchmark.
- A fixed workload of 128 animated Canvas circles. Callback intervals after a two-second warmup show UI scheduling cadence, not actual presented game FPS or GPU throughput.
- Touch event age uses the guest monotonic uptime clock and measures Android event-to-handler delivery age. It is NOT host-input-to-photon latency.
- A run saves its report only after completion or interruption. Interrupted/empty results are failures, never comparable to completed runs.

## Comparison protocol

1. Record emulator and image versions, hardware acceleration, renderer/transport, CPU/RAM, display dimensions/density/refresh, host memory pressure and foreground/background state. Hash the APK; use the exact same APK for both emulators.
2. Preserve user profiles. Use an isolated Kestrel profile and a separate MuMu test instance when possible. Never change user settings silently. Never run two VMs or a heavy decompiler concurrently during measurement.
3. Separate first boot, steady-state cold launch and snapshot resume. A rejected snapshot is a cold start, whatever the launcher calls it. Verify logs and hardware configuration, not just boot_completed.
4. Allow the same bounded stabilization interval. Capture background CPU, processes and renderer properties. Android 12 versus Android 16 is a confound: report it rather than attributing every difference to the VM engine.
5. Run at least three repetitions per condition, alternate condition order where feasible, and report every sample and worst-of-N. Do not select only a best run. This workload alone cannot establish normal-mode game parity.
6. Change one variable per experiment. First candidates supported by static analysis: pipe versus ASG transport, virtual display refresh plumbing, and explicit UI controls that currently do nothing. Do not enable Fast Math or change image internals during a baseline comparison.
7. Retain reports, screenshots, gfxinfo, logcat errors and timing logs. Inspect the rendered screenshot. A throughput gain with rendering errors, instability or increased input latency is not a successful optimization.
8. Game tests need the same version, scene and settings; record frame-time distributions and interaction correctness. Account-dependent testing is separate from this account-free diagnostic workload.

## Investigation boundary

Normal-mode parity with MuMu has not been demonstrated. Optional tuning is a later phase. The current Kestrel app stores FPS settings without applying a display-rate setting or drawing an FPS counter. Startup and snapshot success are not proof of graphical or gameplay responsiveness.
