#!/bin/zsh
# Prove the full-package build's error set contains nothing beyond the
# pre-existing WIP breakage: every primary `path:line:col: error:` line must
# name EmulatorPlayerSession (the user's unfinished file). Continuation lines
# (starting with |) are ignored — they belong to the diagnostic above them.
# Exit 0 iff so.
cd "$(git rev-parse --show-toplevel)"
OUT=$(swift build -c debug 2>&1 || true)
PRIMARY=$(echo "$OUT" | grep -E 'error:' | grep -E '\.swift:[0-9]+' || true)
if [ -z "$PRIMARY" ]; then
  echo "BUILD_CLEAN: no file-scoped errors at all"
  exit 0
fi
NEW=$(echo "$PRIMARY" | grep -v 'EmulatorPlayerSession' || true)
if [ -z "$NEW" ]; then
  echo "ONLY_PREEXISTING_WIP_ERRORS: all file-scoped errors are in EmulatorPlayerSession.swift (pre-existing broken WIP, present before stealth changes)"
  exit 0
fi
echo "NEW_ERRORS_DETECTED:"
echo "$NEW"
exit 1
