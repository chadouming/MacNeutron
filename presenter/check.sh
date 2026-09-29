#!/bin/sh
# Runs the MetalFX presenter under the installed runtime on D3DMetal: real Wine, no Steam (upscaler spec §6).
# Needs `make presenter` and an installed runtime with GPTK imported; MACNEUTRON_TOOL overrides the tool folder.
# DYLD_INSERT_LIBRARIES goes straight to the launcher through env's arguments: macOS strips DYLD_* variables when
# a protected binary (sh, perl, ...) sits in between.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/build/presenter"
LIB="$B/libmacneutron-present.dylib"
TOOL="${MACNEUTRON_TOOL:-$HOME/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron}"
WORK="${TMPDIR:-/tmp}/macneutron presenter"
mkdir -p "$WORK/compat"
fail=0
expect() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2], want [$3]"; fail=1; fi; }

# run_loop <name> <inject 0|1> <scale> <present_loop args...>  →  output in $WORK/<name>.txt
run_loop() {
  name=$1 inject=$2 scale=$3; shift 3
  lib=""; [ "$inject" = 1 ] && lib="$LIB"
  env STEAM_COMPAT_DATA_PATH="$WORK/compat/0" SteamAppId=0 MACNEUTRON_GRAPHICS=d3dmetal \
      MACNEUTRON_NO_STEAM_BRIDGE=1 MACNEUTRON_NO_METALFX=1 DYLD_INSERT_LIBRARIES="$lib" \
      MACNEUTRON_PRESENT_SCALE="$scale" MACNEUTRON_PRESENT_DUMP="$WORK/frame.ppm" \
      "$TOOL/bin/macneutron" launch waitforexitandrun "$B/present_loop.exe" "$@" > "$WORK/$name.out" 2>&1 &
  pid=$!
  ( sleep 120; kill "$pid" 2>/dev/null ) & dog=$!
  wait "$pid" || true
  kill "$dog" 2>/dev/null || true
  tr -d '\r' < "$WORK/$name.out" > "$WORK/$name.txt"
}
frame_ms() { grep -o 'avg frame [0-9.]*' "$WORK/$1.txt" | awk '{print $3}'; }

# The prefix, created without the library (check 4 covers creating one with it).
[ -d "$WORK/compat/0/pfx" ] || env STEAM_COMPAT_DATA_PATH="$WORK/compat/0" SteamAppId=0 \
    "$TOOL/bin/macneutron" launch getcompatpath "$WORK" > /dev/null 2>&1

run_loop pass 1 1 1280 720 0 0 200 0
expect "full-size game passes through" "$(grep -c 'macneutron-present: MetalFX' "$WORK/pass.txt" || true)" 0

rm -f "$WORK/frame.ppm"
run_loop up 1 1 1280 720 640 360 300 0
expect "small swap chain is upscaled" "$(grep -c 'macneutron-present: MetalFX 640x360 -> 1280x720' "$WORK/up.txt" || true)" 1
expect "upscaled frame shows the whole checkerboard" \
  "$( [ -f "$WORK/frame.ppm" ] && python3 "$ROOT/presenter/tests/pixels.py" "$WORK/frame.ppm" || echo none)" "WNWNWNWN"

run_loop retina 1 2 1280 720 0 0 200 0
expect "Retina density is upscaled" "$(grep -c 'macneutron-present: MetalFX 1280x720 -> 2560x1440' "$WORK/retina.txt" || true)" 1

rm -rf "$WORK/compat/fresh"
env STEAM_COMPAT_DATA_PATH="$WORK/compat/fresh" SteamAppId=0 DYLD_INSERT_LIBRARIES="$LIB" \
    "$TOOL/bin/macneutron" launch getcompatpath "$WORK" > /dev/null 2>&1 && st=0 || st=$?
expect "prefix setup works with the library loaded" \
  "$st:$( [ -d "$WORK/compat/fresh/pfx/drive_c" ] && echo yes || echo no)" "0:yes"

run_loop resize 1 1 1280 720 640 360 300 0 resize=150:960x540
expect "overlay follows a window resize" "$(grep -c 'macneutron-present: MetalFX 640x360 -> 960x540' "$WORK/resize.txt" || true)" 1

run_loop grow 1 1 1280 720 640 360 300 0 grow=150
expect "overlay goes away at full size" "$(grep -c 'macneutron-present: pass-through (full size)' "$WORK/grow.txt" || true)" 1

run_loop hdr 1 1 1280 720 640 360 200 0 fp16
expect "HDR layers are left alone" \
  "$(grep -c 'left alone (HDR/extended-range layer)' "$WORK/hdr.txt" || true):$(grep -c 'macneutron-present: MetalFX' "$WORK/hdr.txt" || true)" "1:0"

run_loop base 0 1 1280 720 640 360 600 0
run_loop pace 1 1 1280 720 640 360 600 0
expect "pacing within 1 ms of no library" \
  "$(awk -v a="$(frame_ms pace)" -v b="$(frame_ms base)" 'BEGIN { print (a != "" && b != "" && a <= b + 1.0) ? "yes" : "no (" a " vs " b " ms)" }')" "yes"

exit $fail
