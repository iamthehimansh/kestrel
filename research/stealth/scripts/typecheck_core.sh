#!/bin/zsh
# Typecheck every KestrelCore Swift source EXCEPT EmulatorPlayerSession.swift,
# which is pre-existing uncommitted WIP that fails to compile before any of the
# stealth changes (it calls Launcher.startOwned, which does not exist yet).
# Exit 0 iff the rest of the module typechecks cleanly.
set -e
cd "$(git rev-parse --show-toplevel)"
SDK=$(xcrun --show-sdk-path)
ls Sources/KestrelCore/*.swift | grep -v EmulatorPlayerSession.swift \
  | xargs swiftc -typecheck -sdk "$SDK" -target arm64-apple-macos13.0
echo "TYPECHECK_OK: all KestrelCore sources except pre-broken EmulatorPlayerSession.swift"
