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

# 3. DXIL pipelines are created (an out-of-scope op fails only its own pipeline, named in the log), and DXMT_DXIL_DUMP
#    captures each shader once, byte for byte. $WORK has a space in it, like the Application Support paths users pass.
H="$ROOT/dxmt/tests/dxil/heap.dxil"
dxil() { run ours "$1" dxmt "$TESTS/d3d12_dxil.exe" "Z:$S/triangle.vs.dxil" "Z:$S/triangle.ps.dxil" "Z:$S/compute.cs.dxil" "Z:$H"; }
D="$WORK/dxil"
export DXMT_DXIL_DUMP="$D"
dxil dxil
expect "DXIL pipelines are created" "$(grep -cE '^(graphics|compute) hr=0x00000000$' "$WORK/dxil.txt" || true)" 2
expect "an out-of-scope DXIL op fails only its pipeline" "$(grep -c '^heap hr=0x80004001$' "$WORK/dxil.txt" || true)" 1
run ours dxil-ref d3dmetal "$TESTS/d3d12_dxil.exe" "Z:$S/triangle.vs.dxil" "Z:$S/triangle.ps.dxil" "Z:$S/compute.cs.dxil" "Z:$H"
expect "newer device interfaces (5-8) answer as on D3DMetal" "$(grep '^device' "$WORK/dxil.txt" | tr -d '\r' | tr '\n' ' ')" \
  "$(grep '^device' "$WORK/dxil-ref.txt" | tr -d '\r' | tr '\n' ' ')"
expect "a graphics pipeline with sample count 0 fares as on D3DMetal" "$(grep '^graphics-samples0' "$WORK/dxil.txt" | tr -d '\r')" \
  "$(grep '^graphics-samples0' "$WORK/dxil-ref.txt" | tr -d '\r')"
expect "the capture folder is created" "$([ -d "$D" ] && echo yes || echo no)" yes
expect "four shaders captured" "$(ls "$D" | grep -c '\.dxil$')" 4
# Capture mode also saves the root signature and a line per pipeline naming its shaders and root signature by hash.
rs=$(ls "$D" | sed -n 's/^rs-\([0-9a-f]\{16\}\)\.bin$/\1/p')
expect "the root signature is captured" "$(echo "$rs" | grep -c .)" 1
expect "pipelines.txt names each pipeline's shaders and root signature" \
  "$(grep -cE "^(gfx vs=[0-9a-f]{16} ps=[0-9a-f]{16}|cs cs=[0-9a-f]{16}) rs=$rs( |$)" "$D/pipelines.txt" 2> /dev/null || true)" 4
expect "each capture is its shader, byte for byte" "$(for src in "$S/triangle.vs.dxil" "$S/triangle.ps.dxil" "$S/compute.cs.dxil" "$H"; do
    found=n; for f in "$D"/*.dxil; do cmp -s "$src" "$f" && found=y; done; printf %s $found
  done)" yyyy
expect "capture names are <stage>-<16 hex>.dxil" "$(ls "$D" | grep -cE '^(vs|ps|cs)-[0-9a-f]{16}\.dxil$')" 4
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
expect "a capture folder named outside ASCII works" "$(ls "$WORK/dxil é" 2> /dev/null | grep -c '\.dxil$')" 4
expect "no capture is left half-written" "$(ls "$D" "$WORK/dxil é" 2> /dev/null | grep -c '\.tmp$')" 0
export DXMT_DXIL_DUMP="/nonexistent/macneutron dxil"
dxil dxil-unwritable
expect "an unwritable capture folder changes nothing for the game" "$(grep -c '^compute hr=0x00000000$' "$WORK/dxil-unwritable.txt" || true)" 1
unset DXMT_DXIL_DUMP
# The unsupported op is named in the game log (MACNEUTRON_LOG=1 sends the output there).
LOG="$HOME/Library/Logs/MacNeutron/steam-0.log"; before=$(cat "$LOG" 2> /dev/null | wc -l)
export MACNEUTRON_LOG=1; dxil dxil-logged; unset MACNEUTRON_LOG
expect "the unsupported op is named in the log" "$(tail -n +$((before + 1)) "$LOG" | grep -c 'Failed to compile cs shader: DXIL: dx.op.createHandleFromHeap')" 1

# 3b. DXIL behaviour groups: our DXMT against D3DMetal on the same GPU.
X="$ROOT/dxmt/tests/dxil"
run ours exec-ours dxmt "$TESTS/d3d12_dxil_exec.exe" "Z:$X"
run ours exec-ref d3dmetal "$TESTS/d3d12_dxil_exec.exe" "Z:$X"
for g in buffers math transcendental textures groupshared wave half packed atomics quad; do
  expect "DXIL $g matches D3DMetal" "$(python3 "$ROOT/dxmt/tests/compare.py" "$WORK/exec-ours.txt" "$WORK/exec-ref.txt" $g)" match
done
run ours exec-threads dxmt "$TESTS/d3d12_dxil_exec.exe" "Z:$X" threads
expect "DXIL pipelines compile on 8 threads at once" "$(grep -o 'threads ok 8/8' "$WORK/exec-threads.txt" || true)" "threads ok 8/8"
same_pixels() {  # same_pixels <ours> <ref>: yes when both drew ("<test> ok") and the 12 sampled pixels are within 1/255
  python3 - "$1" "$2" <<'PY'
import sys
def px(p):
    for l in open(p):
        s = l.split()
        if s[1:2] == ["ok"]: return [int(x, 16) for x in s[3:15]]
a, b = px(sys.argv[1]), px(sys.argv[2])
print("yes" if a and b and len(a) == len(b) == 12 and all(abs(((x >> k) & 255) - ((y >> k) & 255)) <= 1 for x, y in zip(a, b) for k in (0, 8, 16, 24)) else f"no {a} {b}")
PY
}
run ours tri-ours dxmt "$TESTS/d3d12_triangle.exe" "Z:$S/triangle2.vs.dxil" "Z:$S/triangle2.ps.dxil"
run ours tri-ref d3dmetal "$TESTS/d3d12_triangle.exe" "Z:$S/triangle2.vs.dxil" "Z:$S/triangle2.ps.dxil"
expect "DXIL triangle matches D3DMetal (12 pixels within 1/255)" "$(same_pixels "$WORK/tri-ours.txt" "$WORK/tri-ref.txt")" yes
run ours trigs-ours dxmt "$TESTS/d3d12_triangle.exe" "Z:$S/triangle2.vs.dxil" "Z:$S/triangle2.ps.dxil" "Z:$S/triangle2.gs.dxil"
run ours trigs-ref d3dmetal "$TESTS/d3d12_triangle.exe" "Z:$S/triangle2.vs.dxil" "Z:$S/triangle2.ps.dxil" "Z:$S/triangle2.gs.dxil"
expect "DXIL geometry shader triangle matches D3DMetal (12 pixels within 1/255)" \
  "$(same_pixels "$WORK/trigs-ours.txt" "$WORK/trigs-ref.txt")" yes
# Depth and stencil as Unreal uses them; occlusion queries, which Unreal culls meshes by (SMITE 2's lobby).
run ours depth-ours dxmt "$TESTS/d3d12_depth.exe" "Z:$S/depth.vs.dxil" "Z:$S/depth.ps.dxil" "Z:$S/depth.psdepth.dxil"
run ours depth-ref d3dmetal "$TESTS/d3d12_depth.exe" "Z:$S/depth.vs.dxil" "Z:$S/depth.ps.dxil" "Z:$S/depth.psdepth.dxil"
expect "depth and stencil match D3DMetal (12 pixels within 1/255)" "$(same_pixels "$WORK/depth-ours.txt" "$WORK/depth-ref.txt")" yes
# The pass dump (capture mode, DXMT_DUMP_FRAME): frame 0 of a test that never presents, saved as its queue goes.
rm -rf "$WORK/passes"; export DXMT_DXIL_DUMP="$WORK/passes" DXMT_DUMP_FRAME=0
run ours depth-dump dxmt "$TESTS/d3d12_depth.exe" "Z:$S/depth.vs.dxil" "Z:$S/depth.ps.dxil" "Z:$S/depth.psdepth.dxil"
unset DXMT_DXIL_DUMP DXMT_DUMP_FRAME
expect "the pass dump saves the depth test's 3 render passes (5 attachments)" \
  "$(grep -c ' render ' "$WORK/passes/passes.txt" 2> /dev/null || true) $(ls "$WORK/passes" 2> /dev/null | grep -c '\.raw$')" "3 5"
run ours query-ours dxmt "$TESTS/d3d12_query.exe" "Z:$S/depth.vs.dxil" "Z:$S/depth.ps.dxil"
run ours query-ref d3dmetal "$TESTS/d3d12_query.exe" "Z:$S/depth.vs.dxil" "Z:$S/depth.ps.dxil"
expect "occlusion queries match D3DMetal" "$(grep '^query' "$WORK/query-ours.txt" || true)" "$(grep '^query' "$WORK/query-ref.txt" || echo 'D3DMetal ran no query')"
# Batch 1 of the D3D12 stubs spec: calls that aborted, hung or failed where D3DMetal succeeds (d3d12_api).
run ours api-ours dxmt "$TESTS/d3d12_api.exe" "Z:$S/depth.vs.dxil" "Z:$S/depth.ps.dxil"
run ours api-ref d3dmetal "$TESTS/d3d12_api.exe" "Z:$S/depth.vs.dxil" "Z:$S/depth.ps.dxil"
same_lines() {  # same_lines <prefix>: d3d12_api's lines starting with <prefix> are the same on both, and present
  a=$(grep "^$1 " "$WORK/api-ours.txt" || true); b=$(grep "^$1 " "$WORK/api-ref.txt" || true)
  [ -n "$a" ] && [ "$a" = "$b" ] && echo yes || echo "no: ours [$a] D3DMetal [$b]"
}
for s in markers cachedblob nulldsv; do expect "d3d12_api $s answers as D3DMetal" "$(same_lines $s)" yes; done

# AMD's FSR 3 swapchain proxy, which SMITE 2 (and other Unreal games with the FSR 3 plugin) create their swapchain
# through: read from the game's install when it's there, never copied.
FFX="$HOME/Library/Application Support/Steam/steamapps/common/SMITE 2/Windows/Hemingway/Binaries/Win64/amd_fidelityfx_dx12.dll"
if [ -f "$FFX" ]; then
  run ours ffx-ours dxmt "$TESTS/d3d12_ffx_swapchain.exe" "Z:$FFX" 60
  expect "the FSR 3 swapchain proxy presents on our DXMT" "$(grep -o 'presented 60/60' "$WORK/ffx-ours.txt" || grep -o 'ffxCreateContext rc=[0-9]*' "$WORK/ffx-ours.txt" || true)" "presented 60/60"
else
  echo "skip the FSR 3 swapchain proxy (SMITE 2 isn't installed)"
fi

# 4. D3DMetal still works.
run ours d3dmetal d3dmetal "$LOOP" 1280 720 0 0 200 0
expect "present_loop completes on D3DMetal" "$(grep -c 'avg frame' "$WORK/d3dmetal.txt" || true)" 1

# 5. The DXIL probe: results recorded, not graded; one line per shader, and a non-container is refused.
"$DXMT/dxil-probe" "$S"/*.dxil > "$WORK/probe.txt" || true
cat "$WORK/probe.txt"
expect "the probe reports every shader" "$(grep -cE '^(ok|fail) ' "$WORK/probe.txt")" "$(ls "$S"/*.dxil | wc -l | tr -d ' ')"
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

# 6. dxil-translate: every test shader reaches a Metal pipeline offline (heap.dxil is out of scope on purpose).
"$DXMT/dxil-translate" "$ROOT/dxmt/tests/dxil" > "$WORK/translate.txt" 2>&1 || true
expect "dxil-translate accepts every behaviour shader but heap" "$(tail -1 "$WORK/translate.txt" | cut -d ' ' -f 2)" "10/11"
"$DXMT/dxil-translate" "$S" > "$WORK/translate-shaders.txt" 2>&1 || true
expect "dxil-translate accepts the test shaders" "$(tail -1 "$WORK/translate-shaders.txt" | cut -d ' ' -f 2)" "9/9"

[ $fail = 0 ] && echo "dxmt-check: all passed"
exit $fail
