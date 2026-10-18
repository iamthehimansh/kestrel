#!/bin/zsh
# Lock-guarded image patch: carve EROFS -> extract -> patch build.prop ->
# repack -> assemble patched system.img -> point AVD at it. The lock stops the
# duplicate parallel job from racing on the same directories (which is what
# broke the previous two runs).
set -e
BASE="$HOME/Library/Android/sdk/system-images/android-36/google_apis_playstore/arm64-v8a"
WORK=/tmp/kestrel-research/imgpatch
LOCK=/tmp/kestrel-research/imgpatch.lock
FSCK=/opt/homebrew/opt/erofs-utils/bin/fsck.erofs
MKFS=/opt/homebrew/opt/erofs-utils/bin/mkfs.erofs
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "LOCK_HELD: another instance is running; duplicate exits now"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
ts() { date '+%H:%M:%S'; }
rm -rf "$WORK/extract" "$WORK/syspart.new"
mkdir -p "$WORK/extract"

echo "[$(ts)] [1/6] Carve EROFS partition (reuse existing carve if size matches)"
if [ ! -s "$WORK/syspart.erofs" ] || [ "$(stat -f %z "$WORK/syspart.erofs")" != "2305818624" ]; then
  dd if="$BASE/system.img" of="$WORK/syspart.erofs" bs=1m skip=3 2>/dev/null
fi
ls -la "$WORK/syspart.erofs"

echo "[$(ts)] [2/6] Full extraction (single instance, fresh dir)"
"$FSCK" --extract="$WORK/extract" --overwrite "$WORK/syspart.erofs" 2>&1 | grep -E '^<E>|FATAL|fail' | head -5
echo "extract rc captured; listing root:"
ls "$WORK/extract" | head -12
BP=""
for cand in build.prop system/build.prop; do
  [ -f "$WORK/extract/$cand" ] && { BP="$WORK/extract/$cand"; break; }
done
if [ -z "$BP" ]; then
  echo "build.prop not at expected paths; searching:"
  find "$WORK/extract" -maxdepth 2 -name '*.prop' | head -10
  exit 1
fi
echo "build.prop at: $BP ($(wc -l < "$BP") lines)"
grep -E '^ro.product.model=|^ro.product.brand=|^ro.hardware=|^ro.build.characteristics=|^ro.build.fingerprint=' "$BP" | head -6

echo "[$(ts)] [3/6] Patch build.prop"
python3 - "$BP" <<'EOF'
import sys
bp = sys.argv[1]
src = open(bp).read().splitlines()
DROP = {'ro.product.model','ro.product.brand','ro.product.name','ro.product.device',
        'ro.product.manufacturer','ro.product.board','ro.product.hardware','ro.hardware',
        'ro.build.characteristics','ro.build.fingerprint','ro.build.flavor',
        'ro.build.description','ro.build.tags','ro.system.build.fingerprint','ro.bootloader'}
out = [l for l in src if l.split('=',1)[0] not in DROP]
FP = 'samsung/e3qxxx/e3q:16/BP2A.250605.031/S928BXXU4BYE3:user/release-keys'
out += [
 'ro.product.model=SM-S928B','ro.product.brand=samsung','ro.product.name=e3qxxx',
 'ro.product.device=e3q','ro.product.manufacturer=samsung','ro.product.board=qcom',
 'ro.product.hardware=qcom','ro.hardware=qcom','ro.build.characteristics=default',
 f'ro.build.fingerprint={FP}','ro.build.flavor=e3qxxx-user',
 'ro.build.description=e3qxxx-user 16 BP2A.250605.031 S928BXXU4BYE3 release-keys',
 'ro.build.tags=release-keys',f'ro.system.build.fingerprint={FP}',
 'ro.bootloader=R3C4-08.03.01.5',
]
open(bp,'w').write('\n'.join(out)+'\n')
print('build.prop rewritten:', len(out), 'lines')
EOF

echo "[$(ts)] [4/6] Repack EROFS"
"$MKFS" -z lz4hc,1 -T 0 -b 4096 "$WORK/syspart.new" "$WORK/extract" 2>&1 | tail -2
ls -la "$WORK/syspart.new"

echo "[$(ts)] [5/6] Assemble patched system.img (APFS CoW clone + overwrite partition)"
rm -f "$WORK/system.img"
cp -c "$BASE/system.img" "$WORK/system.img" 2>/dev/null || cp "$BASE/system.img" "$WORK/system.img"
dd if="$WORK/syspart.new" of="$WORK/system.img" bs=1m seek=3 conv=notrunc 2>/dev/null
echo "assembled: $(stat -f %z "$WORK/system.img") bytes"

echo "[$(ts)] [6/6] Point AVD at patched image dir"
TESTDIR="$WORK/sysdir"
rm -rf "$TESTDIR"; mkdir -p "$TESTDIR"
for f in "$BASE"/*; do
  n=$(basename "$f")
  if [ "$n" = "system.img" ]; then
    cp -c "$WORK/system.img" "$TESTDIR/system.img" 2>/dev/null || cp "$WORK/system.img" "$TESTDIR/system.img"
  else
    ln -sf "$f" "$TESTDIR/$n"
  fi
done
CFG="$HOME/Library/Application Support/Kestrel/avd/kestrel-0.avd/config.ini"
[ -f "$WORK/config.ini.bak" ] || cp "$CFG" "$WORK/config.ini.bak"
grep -v '^image.sysdir.1=' "$CFG" > "$CFG.n" && mv "$CFG.n" "$CFG"
echo "image.sysdir.1=$TESTDIR/" >> "$CFG"
grep -E '^image.sysdir' "$CFG"
echo "PATCH_IMAGE_READY"
