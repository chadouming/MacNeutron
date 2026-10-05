#!/bin/sh
# Runs the MetalFX presenter inside wine.app through the launcher on DXMT: real Wine, no Steam (upscaler spec §6,
# release spec §9 L4). Needs `make build wine-arm64 presenter`. The tool folder is assembled from
# build/wine-arm64/wine.app with `macneutron install`; the launcher sets MACNEUTRON_PRESENT=1 for the game, and DXMT's
# winemetal.so loads the presenter from beside itself. MACNEUTRON_NO_METALFX=1 turns that off (the runs without it).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/build/presenter"
WORK="${TMPDIR:-/tmp}/macneutron presenter"
TOOL="$WORK/tool"
mkdir -p "$WORK/compat"
"$ROOT/.build/release/macneutron" install --tool-dir "$TOOL" --wine-app "$ROOT/build/wine-arm64/wine.app" \
  || { echo "check: assembling the tool folder failed" >&2; exit 1; }
fail=0
expect() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2], want [$3]"; fail=1; fi; }

# run_loop <name> <inject 0|1> <scale> <present_loop args...>  →  output in $WORK/<name>.txt
run_loop() {
  name=$1 inject=$2 scale=$3; shift 3
  off=; [ "$inject" = 1 ] || off=1
  env STEAM_COMPAT_DATA_PATH="$WORK/compat/0" SteamAppId=0 MACNEUTRON_GRAPHICS=dxmt MACNEUTRON_NO_STEAM_BRIDGE=1 \
      ${off:+MACNEUTRON_NO_METALFX=1} MACNEUTRON_PRESENT_SCALE="$scale" MACNEUTRON_PRESENT_DUMP="$WORK/frame.ppm" \
      "$TOOL/bin/macneutron" launch waitforexitandrun "$B/present_loop.exe" "$@" > "$WORK/$name.out" 2>&1 &
  pid=$!
  ( sleep 120; kill "$pid" 2>/dev/null ) & dog=$!
  wait "$pid" || true
  kill "$dog" 2>/dev/null || true
  tr -d '\r' < "$WORK/$name.out" > "$WORK/$name.txt"
}
count() { LC_ALL=C /usr/bin/grep -c "$1" "$WORK/$2.txt" || true; }   # count <pattern> <run>
frame_ms() { LC_ALL=C /usr/bin/grep -o 'avg frame [0-9.]*' "$WORK/$1.txt" | awk '{print $3}'; }

# The prefix, prepared before the timed runs (a no-op when it is current).
env STEAM_COMPAT_DATA_PATH="$WORK/compat/0" SteamAppId=0 MACNEUTRON_GRAPHICS=dxmt \
    "$TOOL/bin/macneutron" launch getcompatpath "$WORK" > /dev/null 2>&1 \
  || { echo "check: the launcher didn't prepare $WORK/compat/0/pfx" >&2; exit 1; }

run_loop pass 1 1 1280 720 0 0 200 0
expect "full-size game passes through" "$(count 'macneutron-present: MetalFX' pass)" 0

rm -f "$WORK/frame.ppm"
run_loop up 1 1 1280 720 640 360 300 0
expect "small swap chain is upscaled" "$(count 'macneutron-present: MetalFX 640x360 -> 1280x720' up)" 1
expect "upscaled frame shows the whole checkerboard" \
  "$( [ -f "$WORK/frame.ppm" ] && python3 "$ROOT/presenter/tests/pixels.py" "$WORK/frame.ppm" || echo none)" "WNWNWNWN"

run_loop retina 1 2 1280 720 0 0 200 0
expect "Retina density is upscaled" "$(count 'macneutron-present: MetalFX 1280x720 -> 2560x1440' retina)" 1

run_loop resize 1 1 1280 720 640 360 300 0 resize=150:960x540
expect "overlay follows a window resize" "$(count 'macneutron-present: MetalFX 640x360 -> 960x540' resize)" 1

run_loop grow 1 1 1280 720 640 360 300 0 grow=150
expect "overlay goes away at full size" "$(count 'macneutron-present: pass-through (full size)' grow)" 1

run_loop hdr 1 1 1280 720 640 360 200 0 fp16
expect "HDR layers are left alone" \
  "$(count 'left alone (HDR/extended-range layer)' hdr):$(count 'macneutron-present: MetalFX' hdr)" "1:0"

run_loop vsync 1 1 1280 720 640 360 200 1
expect "vsync-on game is upscaled" "$(count 'macneutron-present: MetalFX 640x360 -> 1280x720' vsync)" 1

rm -f "$WORK/frame.ppm"
run_loop vswitch 1 1 1280 720 640 360 300 0 vsync_at=60:1
expect "switching vsync on keeps upscaling" \
  "$( [ -f "$WORK/frame.ppm" ] && python3 "$ROOT/presenter/tests/pixels.py" "$WORK/frame.ppm" || echo none)" "WNWNWNWN"

run_loop format 1 1 1280 720 640 360 300 0 format_at=100
expect "a pixel-format switch rebuilds the overlay" \
  "$(count 'macneutron-present: MetalFX 640x360 -> 1280x720' format):$(count 'avg frame' format)" "2:1"

run_loop base 0 1 1280 720 640 360 600 0
expect "MACNEUTRON_NO_METALFX=1 loads no presenter" "$(count 'macneutron-present' base)" 0
run_loop pace 1 1 1280 720 640 360 600 0
expect "pacing within 1 ms of no library" \
  "$(awk -v a="$(frame_ms pace)" -v b="$(frame_ms base)" 'BEGIN { print (a != "" && b != "" && a <= b + 1.0) ? "yes" : "no (" a " vs " b " ms)" }')" "yes"

exit $fail
