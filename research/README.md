# Research archive

Start with the current [research overview](../docs/research/README.md) and [experiment ledger](../docs/research/experiment-ledger.md).

This directory retains original diagnostic source and historical notes from the separate detection-surface investigation. The `stealth` directory name is historical, not a promise of invisibility or game acceptance. Some early hypotheses and plans were disproved by later tests. The current [detection-surface summary](../docs/research/detection-surface.md) explains the measured outcome: property/GL changes closed zero of fifteen tracked indicators, and a naive image repack did not boot.

## What is published

- Original diagnostic activity and manifest.
- Research scripts and recorded findings, with local machine paths sanitized.
- Negative results and unresolved hypotheses.
- Detailed architecture, graphics, input, audio and performance summaries under `docs/research/`.

## What is deliberately withheld

Raw `results/` dumps, credentials/device keys, private paths, game/account identifiers, proprietary binaries or decompiled source, restricted images and user VM disks. These were excluded from the outgoing history as well as the latest source tree. The private original backup is not a release asset.

Historical scripts are **not safe one-click setup tools**. Some start or stop emulators, modify test images or assume a local workspace. Review them completely, use an isolated profile and unique ports, and never run them against valuable game data or another person's session. The failed image experiment is retained for understanding a rejected approach, not as a recommended way to prepare a guest.

No hardware-backed attestation test or anti-cheat bypass is established. See [CONTRIBUTING.md](../CONTRIBUTING.md) for acceptable research contributions and evidence requirements.
