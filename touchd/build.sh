#!/bin/sh
# Builds touchd for arm64 Android with the NDK. Output: .build/touchd/touchd
set -eu
cd "$(dirname "$0")/.."
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
CLANG=""
for v in $(ls -r "$SDK/ndk" 2>/dev/null); do
  for host in darwin-x86_64 darwin-arm64; do
    c="$SDK/ndk/$v/toolchains/llvm/prebuilt/$host/bin/aarch64-linux-android29-clang"
    if [ -x "$c" ]; then CLANG="$c"; break 2; fi
  done
done
if [ -z "$CLANG" ]; then
  echo "Android NDK not found. Install it with: sdkmanager 'ndk;27.1.12297006'" >&2
  exit 1
fi
mkdir -p .build/touchd
"$CLANG" -O2 -Wall -Wextra -Werror -static -s -o .build/touchd/touchd touchd/touchd.c
echo ".build/touchd/touchd"
