#!/bin/sh
# Our DXMT build under real Wine, no Steam (DXMT fork spec §6). Needs `make build dxmt presenter dxmt-tests`, an
# installed runtime with GPTK imported, and that runtime's tarball in ~/Library/Caches/MacNeutron. MACNEUTRON_TOOL
# overrides the tool folder, which is never modified: the checks run on two APFS clones of it (instant, no space).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DXMT="$ROOT/build/dxmt"
TESTS="$ROOT/build/dxmt-tests"
S="$ROOT/dxmt/tests/shaders"
LOOP="$ROOT/build/presenter/present_loop.exe"
TOOL="${MACNEUTRON_TOOL:-$HOME/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron}"
WORK="${TMPDIR:-/tmp}/macneutron dxmt"
fail=0
expect() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2], want [$3]"; fail=1; fi; }
die() { echo "dxmt-check: $*" >&2; exit 1; }

[ -f "$TOOL/gptk.json" ] || die "import GPTK first (check 4 runs D3DMetal)"
TARBALL="$HOME/Library/Caches/MacNeutron/$(cat "$TOOL/runtime-version").tar.gz"
[ -f "$TARBALL" ] || die "the runtime tarball isn't cached at $TARBALL (reinstall the runtime once)"

# "stock": the runtime's own DXMT 0.80, restored from its tarball. "ours": build/dxmt installed over it.
# Both run the launcher just built, so only DXMT differs.
rm -rf "$WORK"; mkdir -p "$WORK/compat"
cp -cR "$TOOL" "$WORK/stock"
rm -rf "$WORK/stock/Libraries/DXMT" "$WORK/stock/dxmt-version"
tar -xzf "$TARBALL" -C "$WORK/stock" Libraries/DXMT Libraries/Wine/lib/wine/x86_64-unix/winemetal.so \
  Libraries/Wine/lib/wine/x86_64-windows/winemetal.dll Libraries/Wine/lib/wine/i386-windows/winemetal.dll
cp "$ROOT/.build/release/macneutron" "$WORK/stock/bin/macneutron"
cp -cR "$WORK/stock" "$WORK/ours"
"$ROOT/.build/release/macneutron" install-dxmt --tool-dir "$WORK/ours" "$DXMT" > /dev/null

# run <stock|ours> <name> <backend> <exe> [args...]  →  output in $WORK/<name>.txt
run() {
  tool=$1 name=$2 backend=$3; shift 3
  env STEAM_COMPAT_DATA_PATH="$WORK/compat/$tool" SteamAppId=0 MACNEUTRON_GRAPHICS="$backend" \
      MACNEUTRON_NO_STEAM_BRIDGE=1 MACNEUTRON_NO_METALFX=1 \
      "$WORK/$tool/bin/macneutron" launch waitforexitandrun "$@" > "$WORK/$name.out" 2>&1 &
  pid=$!
  ( sleep 120; kill "$pid" 2> /dev/null ) & dog=$!
  wait "$pid" || true
  kill "$dog" 2> /dev/null || true
  tr -d '\r' < "$WORK/$name.out" > "$WORK/$name.txt"
}
for tool in stock ours; do  # the prefixes, created outside the 120 s watchdog
  env STEAM_COMPAT_DATA_PATH="$WORK/compat/$tool" SteamAppId=0 \
      "$WORK/$tool/bin/macneutron" launch getcompatpath "$WORK" > /dev/null 2>&1 || die "creating the $tool prefix failed"
done

# 1. D3D11 on our DXMT is as fast as on DXMT 0.80: best of three runs each, within 10%. Both builds swing between
#    two speeds from run to run (about 4.7 and 5.7 ms here), so fewer runs can compare a fast run with a slow one.
for i in 1 2 3; do
  run stock "stock$i" dxmt "$LOOP" 1280 720 0 0 600 0
  run ours "ours$i" dxmt "$LOOP" 1280 720 0 0 600 0
done
best() { cat "$WORK/${1}1.txt" "$WORK/${1}2.txt" "$WORK/${1}3.txt" | grep -o 'avg frame [0-9.]*' | awk '{print $3}' | sort -n | head -1; }
expect "D3D11 frame time within 10% of DXMT 0.80" \
  "$(awk -v a="$(best ours)" -v b="$(best stock)" 'BEGIN { print (a != "" && b != "" && a <= b * 1.10) ? "yes" : "no (" a " vs " b " ms)" }')" "yes"
expect "the D3D11 game ran our d3d11.dll" \
  "$(cmp -s "$DXMT/x86_64-windows/d3d11.dll" "$WORK/compat/ours/pfx/drive_c/windows/system32/d3d11.dll" && echo yes || echo no)" "yes"

# 2. A D3D12 program presents through our d3d12.dll (D3DMetal would report shader model 6.x).
run ours clear dxmt "$TESTS/d3d12_clear.exe" 300
expect "d3d12_clear presents every frame" "$(grep -c 'presented 300/300 frames' "$WORK/clear.txt" || true)" 1
expect "the D3D12 device is our DXMT (shader model 5.1)" "$(grep -c '^shader model 0x51 ' "$WORK/clear.txt" || true)" 1
expect "it reports its real limits" "$(grep -c '^feature level 0xb100, wave ops 0, atomic64 0$' "$WORK/clear.txt" || true)" 1

# 3. DXIL pipelines return E_NOTIMPL, and DXMT_DXIL_DUMP captures each shader once, byte for byte.
#    $WORK has a space in it, like the Application Support paths users will pass; the folder doesn't exist yet.
dxil() { run ours "$1" dxmt "$TESTS/d3d12_dxil.exe" "Z:$S/triangle.vs.dxil" "Z:$S/triangle.ps.dxil" "Z:$S/compute.cs.dxil"; }
D="$WORK/dxil"
export DXMT_DXIL_DUMP="$D"
dxil dxil
expect "DXIL pipelines return E_NOTIMPL" "$(grep -c 'hr=0x80004001' "$WORK/dxil.txt" || true)" 2
expect "the capture folder is created" "$([ -d "$D" ] && echo yes || echo no)" yes
expect "three shaders captured" "$(ls "$D" | wc -l | tr -d ' ')" 3
expect "each capture is the shader, byte for byte" "$(for s in triangle.vs:vs triangle.ps:ps compute.cs:cs; do
    f=$(ls "$D/${s#*:}"-*.dxil 2> /dev/null | head -1)
    [ -n "$f" ] && cmp -s "$S/${s%%:*}.dxil" "$f" && printf y || printf n
  done)" yyy
expect "capture names are <stage>-<16 hex>.dxil" "$(ls "$D" | grep -cE '^(vs|ps|cs)-[0-9a-f]{16}\.dxil$')" 3
vs=$(ls "$D"/vs-*.dxil 2> /dev/null | head -1)
[ -z "$vs" ] || echo keep > "$vs"
dxil dxil-again
expect "an existing capture is left alone" "$(cat "$vs" 2> /dev/null)" keep
# Capture mode reports what Unreal Engine's SM6 check needs, so SM6-only games get as far as creating pipelines.
run ours clear-capture dxmt "$TESTS/d3d12_clear.exe" 10
expect "capture mode reports shader model 6.6 and binding tier 3" \
  "$(grep -cE '^(shader model 0x66 |resource binding tier 3$)' "$WORK/clear-capture.txt" || true)" 2
expect "capture mode reports feature level 12_1, wave ops and 64-bit atomics" \
  "$(grep -c '^feature level 0xc100, wave ops 1, atomic64 1$' "$WORK/clear-capture.txt" || true)" 1
export DXMT_DXIL_DUMP="$WORK/dxil é"
dxil dxil-unicode
expect "a capture folder named outside ASCII works" "$(ls "$WORK/dxil é" 2> /dev/null | grep -c '\.dxil$')" 3
expect "no capture is left half-written" "$(ls "$D" "$WORK/dxil é" 2> /dev/null | grep -c '\.tmp$')" 0
export DXMT_DXIL_DUMP="/nonexistent/macneutron dxil"
dxil dxil-unwritable
expect "an unwritable capture folder changes nothing for the game" "$(grep -c 'hr=0x80004001' "$WORK/dxil-unwritable.txt" || true)" 2
unset DXMT_DXIL_DUMP

# 3b. DXIL behaviour groups: our DXMT against D3DMetal on the same GPU.
X="$ROOT/dxmt/tests/dxil"
run ours exec-ours dxmt "$TESTS/d3d12_dxil_exec.exe" "Z:$X"
run ours exec-ref d3dmetal "$TESTS/d3d12_dxil_exec.exe" "Z:$X"
for g in buffers math transcendental textures groupshared wave half packed; do
  expect "DXIL $g matches D3DMetal" "$(python3 "$ROOT/dxmt/tests/compare.py" "$WORK/exec-ours.txt" "$WORK/exec-ref.txt" $g)" match
done
run ours exec-threads dxmt "$TESTS/d3d12_dxil_exec.exe" "Z:$X" threads
expect "DXIL pipelines compile on 8 threads at once" "$(grep -o 'threads ok 8/8' "$WORK/exec-threads.txt" || true)" "threads ok 8/8"

# 4. D3DMetal still works.
run ours d3dmetal d3dmetal "$LOOP" 1280 720 0 0 200 0
expect "present_loop completes on D3DMetal" "$(grep -c 'avg frame' "$WORK/d3dmetal.txt" || true)" 1

# 5. The DXIL probe: results recorded, not graded; one line per shader, and a non-container is refused.
"$DXMT/dxil-probe" "$S"/*.dxil > "$WORK/probe.txt" || true
cat "$WORK/probe.txt"
expect "the probe reports every shader" "$(grep -cE '^(ok|fail) ' "$WORK/probe.txt")" 3
expect "the probe refuses a non-container" "$("$DXMT/dxil-probe" "$DXMT/version" | cut -d ' ' -f 1)" fail
# Malformed containers: a part count of 2^32-1, and bitcode that lies past the end of its DXIL part.
python3 - "$WORK" <<'PY'
import struct, sys
w = sys.argv[1]
open(w + "/many-parts.dxil", "wb").write(b"DXBC" + bytes(16) + struct.pack("<III", 1, 32, 0xFFFFFFFF))
part = b"DXIL" + struct.pack("<I", 24) + struct.pack("<II", 0x60060, 6) + b"DXIL" + struct.pack("<III", 0x106, 16, 64)
open(w + "/past-part.dxil", "wb").write(b"DXBC" + bytes(16) + struct.pack("<IIII", 1, 36 + len(part) + 64, 1, 36) + part + bytes(64))
PY
"$DXMT/dxil-probe" "$WORK/many-parts.dxil" > "$WORK/many-parts.txt" & probe=$!
sleep 1
if kill -0 "$probe" 2> /dev/null; then kill "$probe"; quick=no; else quick=yes; fi
reason() { sed 's/^[a-z]* .*\.dxil //'; }  # the probe's message after "<ok|fail> <file>"; $WORK has a space
expect "the probe answers a huge part count at once" "$quick:$(reason < "$WORK/many-parts.txt")" "yes:no DXIL part (a DXBC shader)"
expect "the probe keeps bitcode inside its part" "$("$DXMT/dxil-probe" "$WORK/past-part.dxil" | reason)" \
  "bitcode lies outside the DXIL part"

[ $fail = 0 ] && echo "dxmt-check: all passed"
exit $fail
