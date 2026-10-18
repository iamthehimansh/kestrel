## Summary

<!-- What does this change do, and why? Link the issue it addresses, e.g. "Fixes #123". -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Keymap (new or updated)
- [ ] Documentation
- [ ] Tests only
- [ ] Build, packaging or CI
- [ ] Refactor with no behaviour change

## Evidence

<!--
Keep these three levels separate. It is fine for a change to be implemented and
unit-tested but not yet runtime-verified; just say so.
-->

- **Implemented:** <!-- what code changed -->
- **Unit-tested:** <!-- which tests cover it, or "not covered" and why -->
- **Runtime-verified:** <!-- what you ran on a live instance and what you saw, or "not runtime-verified" -->

<!--
For runtime claims, attach logs (emulator.log or console output), screenshots or
a short recording, and the exact commands you ran.
-->

### Test environment

<!-- Needed for runtime-verified changes and keymaps. Delete if not applicable. -->

- Kestrel commit:
- macOS version:
- Mac model and memory:
- Instance settings (CPU, RAM, resolution, DPI, renderer, Android image):
- Game and version (if relevant):

## Checklist

- [ ] `PROTOC_PATH=/opt/homebrew/bin/protoc swift test --jobs 1` passes locally.
- [ ] `python3 -m unittest discover -s scripts -p 'test_*.py'` passes (if `scripts/` changed).
- [ ] `swift run kestrel keymap check <file>` passes for every keymap added or changed, and a screenshot of the hints over the game HUD is attached.
- [ ] New behaviour has unit tests where it can be tested without a VM.
- [ ] The Evidence section above states what is implemented, unit-tested and runtime-verified.
- [ ] No game compatibility is claimed beyond what I tested myself.
- [ ] User-facing changes are documented in `docs/guide/` and listed under `Unreleased` in `CHANGELOG.md`.
- [ ] Commit messages follow Conventional Commits (`feat:`, `fix:`, `docs:`, ...).
- [ ] This pull request contains no proprietary binaries, decompiled code, Android system images, user VM data, secrets, game modifications or anti-cheat bypasses.
- [ ] Logs and screenshots have been checked for tokens and personal information.

## Notes for reviewers

<!-- Anything you are unsure about, follow-up work, or areas that need a closer look. -->
