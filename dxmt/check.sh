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
  # A fresh translation cache folder per run unless CACHE names a shared one: a dirty build shares its
  # `git describe`, so no run may read entries an earlier build left.
  env STEAM_COMPAT_DATA_PATH="$WORK/compat/$tool" SteamAppId=0 MACNEUTRON_GRAPHICS="$backend" \
      MACNEUTRON_NO_STEAM_BRIDGE=1 MACNEUTRON_NO_METALFX=1 DXMT_SHADER_CACHE_PATH="${CACHE:-$WORK/cache/$name}" \
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
# 1b. The translation cache's table is named by the build (shader pre-caching spec §3.1): no table of
#     AIRCONV_VERSION alone (26), and a table another build left is dropped when the cache opens.
CACHE="$WORK/cache/version"
run ours version1 dxmt "$LOOP" 320 240 0 0 10 0
db=$(ls "$CACHE"/shaders_*.db 2> /dev/null | head -1)
expect "D3D11 opens the translation cache" "$([ -n "$db" ] && echo yes || echo no)" yes
expect "its table is named by the build, not AIRCONV_VERSION alone" \
  "$(sqlite3 "$db" "SELECT count(*) FROM sqlite_master WHERE name = 'cache_26'" 2> /dev/null)" 0
sqlite3 "$db" "CREATE TABLE cache_1 (key BLOB PRIMARY KEY, value BLOB NOT NULL);"
run ours version2 dxmt "$LOOP" 320 240 0 0 10 0
expect "another build's table is dropped when the cache opens" \
  "$(sqlite3 "$db" "SELECT count(*) FROM sqlite_master WHERE name = 'cache_1'" 2> /dev/null)" 0
unset CACHE

# 2. A D3D12 program presents through our d3d12.dll (D3DMetal would report shader model 6.x).
run ours clear dxmt "$TESTS/d3d12_clear.exe" 300
expect "d3d12_clear presents every frame" "$(grep -c 'presented 300/300 frames' "$WORK/clear.txt" || true)" 1
# DXMT_DUMP_FRAMES=<n>: a pass dump takes n consecutive frames (a one-frame glitch is hard to catch with one F9).
rm -rf "$WORK/clear-dump"; export DXMT_DXIL_DUMP="$WORK/clear-dump" DXMT_DUMP_FRAME=5 DXMT_DUMP_FRAMES=3
run ours clear-dump dxmt "$TESTS/d3d12_clear.exe" 20
unset DXMT_DXIL_DUMP DXMT_DUMP_FRAME DXMT_DUMP_FRAMES
expect "DXMT_DUMP_FRAMES=3 dumps three frames in a row" \
  "$(grep '^# frame ' "$WORK/clear-dump/passes.txt" 2> /dev/null | tr '\n' ';')" "# frame 0 presented;# frame 1 presented;# frame 2 presented;"
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
# DXMT_D3D12_SM6=1 reports the same without capture mode (shader pre-caching spec §3.1): Unreal 5 games play with it.
export DXMT_D3D12_SM6=1
run ours clear-sm6 dxmt "$TESTS/d3d12_clear.exe" 10
unset DXMT_D3D12_SM6
expect "DXMT_D3D12_SM6 reports shader model 6.6 and binding tier 3" \
  "$(grep -cE '^(shader model 0x66 |resource binding tier 3$)' "$WORK/clear-sm6.txt" || true)" 2
expect "DXMT_D3D12_SM6 reports feature level 12_1, wave ops and 64-bit atomics" \
  "$(grep -c '^feature level 0xc100, wave ops 1, atomic64 1$' "$WORK/clear-sm6.txt" || true)" 1
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
for g in buffers math transcendental textures groupshared wave half packed atomics quad specials; do
  expect "DXIL $g matches D3DMetal" "$(python3 "$ROOT/dxmt/tests/compare.py" "$WORK/exec-ours.txt" "$WORK/exec-ref.txt" $g)" match
done
run ours exec-threads dxmt "$TESTS/d3d12_dxil_exec.exe" "Z:$X" threads
expect "DXIL pipelines compile on 8 threads at once" "$(grep -o 'threads ok 8/8' "$WORK/exec-threads.txt" || true)" "threads ok 8/8"
same_pixels() {  # same_pixels <ours> <ref> [prefix]: yes when both drew ("<prefix> ok") and 12 pixels are within 1/255
  python3 - "$1" "$2" "${3:-}" <<'PY'
import sys
def px(p, prefix):
    for l in open(p):
        s = l.split()
        if s[1:2] == ["ok"] and (not prefix or s[0] == prefix): return [int(x, 16) for x in s[3:15]]
a, b = px(sys.argv[1], sys.argv[3]), px(sys.argv[2], sys.argv[3])
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
expect "depth and stencil match D3DMetal (12 pixels within 1/255)" "$(same_pixels "$WORK/depth-ours.txt" "$WORK/depth-ref.txt" depth)" yes
expect "read-only depth and stencil views match D3DMetal (12 pixels within 1/255)" \
  "$(same_pixels "$WORK/depth-ours.txt" "$WORK/depth-ref.txt" depth2)" yes
# The pass dump (capture mode, DXMT_DUMP_FRAME): frame 0 of a test that never presents, saved as its queue goes.
rm -rf "$WORK/passes"; export DXMT_DXIL_DUMP="$WORK/passes" DXMT_DUMP_FRAME=0
run ours depth-dump dxmt "$TESTS/d3d12_depth.exe" "Z:$S/depth.vs.dxil" "Z:$S/depth.ps.dxil" "Z:$S/depth.psdepth.dxil"
unset DXMT_DXIL_DUMP DXMT_DUMP_FRAME
expect "the pass dump saves the depth test's 6 render passes (11 attachments)" \
  "$(grep -c ' render ' "$WORK/passes/passes.txt" 2> /dev/null || true) $(ls "$WORK/passes" 2> /dev/null | grep -c '\.raw$')" "6 11"
# Pixel history (DXMT_DUMP_PIXEL=x,y): each draw of the dumped frame redrawn alone from its pass's starting state, and
# the draws that change the pixel listed with their pipeline in pixels.txt. At (32,32): pass-3 (the depth test's
# first, its target's and its depth's clears folded into it, M4) draws the near red quad and the far green quad, each
# alone passing its depth test; pass-4's yellow quad (depth EQUAL 0.25) is rejected by the 0.75 the near quad left,
# so pass-4 lists nothing.
rm -rf "$WORK/pixel"; export DXMT_DXIL_DUMP="$WORK/pixel" DXMT_DUMP_FRAME=0 DXMT_DUMP_PIXEL=32,32
run ours depth-pixel dxmt "$TESTS/d3d12_depth.exe" "Z:$S/depth.vs.dxil" "Z:$S/depth.ps.dxil" "Z:$S/depth.psdepth.dxil"
unset DXMT_DXIL_DUMP DXMT_DUMP_FRAME DXMT_DUMP_PIXEL
expect "pixel history: each quad's draw alone, named by its shaders and blending" \
  "$(grep -cE '^pass-3 draw-(0|1) gfx vs=[0-9a-f]{16} ps=[0-9a-f]{16} .* blend0=off mask0=15 c0 000000ff->(ff0000ff|00ff00ff) at 32,32$' "$WORK/pixel/pixels.txt" 2> /dev/null || true)" 2
expect "a draw the pass's starting depth rejects isn't listed" "$(grep -c '^pass-4 ' "$WORK/pixel/pixels.txt" 2> /dev/null || true)" 0
expect "pixel history leaves the frame's own passes as they were" \
  "$(cmp -s "$WORK/pixel/pass-3-c0-64x64-70.raw" "$WORK/passes/pass-3-c0-64x64-70.raw" && echo same || echo differ)" same
# In sequence (",seq"), each draw goes on top of the pass's earlier draws: the far quad, behind the near one, no longer
# changes (32,32), but it does change (48,8), which only it covers. Pixels join with '+'; passes 3-4 only are redrawn.
# draws.txt lists every draw redrawn; pixels.txt also says what each pass redrew.
rm -rf "$WORK/pixelseq"; export DXMT_DXIL_DUMP="$WORK/pixelseq" DXMT_DUMP_FRAME=0 DXMT_DUMP_PIXEL=32,32+48,8,3,4,seq
run ours depth-pixelseq dxmt "$TESTS/d3d12_depth.exe" "Z:$S/depth.vs.dxil" "Z:$S/depth.ps.dxil" "Z:$S/depth.psdepth.dxil"
unset DXMT_DXIL_DUMP DXMT_DUMP_FRAME DXMT_DUMP_PIXEL
expect "in sequence, only the near quad changes (32,32) in pass-3" \
  "$(grep -c '^pass-3 draw-.* at 32,32$' "$WORK/pixelseq/pixels.txt" 2> /dev/null || true):$(grep -c '^pass-3 draw-0 .* c0 000000ff->ff0000ff at 32,32$' "$WORK/pixelseq/pixels.txt" 2> /dev/null || true)" "1:1"
expect "and the far quad changes (48,8), a second watched pixel" \
  "$(grep -c '^pass-3 draw-1 .* c0 000000ff->00ff00ff at 48,8$' "$WORK/pixelseq/pixels.txt" 2> /dev/null || true)" 1
expect "only passes 3-4 are redrawn" "$(grep -c '^# pass-' "$WORK/pixelseq/pixels.txt" 2> /dev/null || true)" 2
# A pixel list longer than 260 characters (Windows' MAX_PATH) still arrives whole.
long="32,32"; for y in 900 1000 1100 1200 1300; do for x in 100 300 500 700 900 1100 1300 1500 1700 1900; do long="$long+$x,$y"; done; done
rm -rf "$WORK/pixellong"; export DXMT_DXIL_DUMP="$WORK/pixellong" DXMT_DUMP_FRAME=0 DXMT_DUMP_PIXEL="$long,3,3"
run ours depth-pixellong dxmt "$TESTS/d3d12_depth.exe" "Z:$S/depth.vs.dxil" "Z:$S/depth.ps.dxil" "Z:$S/depth.psdepth.dxil"
unset DXMT_DXIL_DUMP DXMT_DUMP_FRAME DXMT_DUMP_PIXEL
expect "a pixel list over 260 characters works" \
  "${#long}:$(grep -c '^pass-3 draw-0 .* at 32,32$' "$WORK/pixellong/pixels.txt" 2> /dev/null || true)" "${#long}:1"
expect "draws.txt lists both of pass-3's draws" "$(grep -c '^pass-3 draw-[01] gfx ' "$WORK/pixelseq/draws.txt" 2> /dev/null || true)" 2
expect "pixels.txt says what pass-3 redrew" "$(grep -c '^# pass-3: 2 draws redrawn in sequence$' "$WORK/pixelseq/pixels.txt" 2> /dev/null || true)" 1
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
for s in markers cachedblob nulldsv list1 heap1 residency multifence feature library; do expect "d3d12_api $s answers as D3DMetal" "$(same_lines $s)" yes; done
# Batch 2: copies between formats D3D12 lets reinterpret.
run ours copy-ours dxmt "$TESTS/d3d12_copy.exe"
run ours copy-ref d3dmetal "$TESTS/d3d12_copy.exe"
expect "reinterpreting copies match D3DMetal byte for byte" \
  "$(grep '^copy ' "$WORK/copy-ours.txt" | tr '\n' ' ')" "$(grep '^copy ' "$WORK/copy-ref.txt" | tr '\n' ' ')"
expect "d3d12_copy ran its eleven cases" "$(grep -c '^copy .* ok ' "$WORK/copy-ours.txt" || true)" 11
# Batch 2: null descriptors of every type.
run ours null-ours dxmt "$TESTS/d3d12_null.exe" "Z:$S/null.cs.dxil"
run ours null-ref d3dmetal "$TESTS/d3d12_null.exe" "Z:$S/null.cs.dxil"
expect "null descriptors read and report as on D3DMetal" \
  "$(grep '^null ' "$WORK/null-ours.txt" | tr '\n' ' ')" "$(grep '^null ' "$WORK/null-ref.txt" | tr '\n' ' ')"
expect "d3d12_null ran its 18 slots" "$(grep -c '^null ' "$WORK/null-ours.txt" || true)" 18
# Paths Unreal's particles and translucency lighting use, each against D3DMetal: layered rendering into a 3D texture
# from the vertex shader, a 3D texture written by compute then sampled and loaded, and resources a vertex shader reads.
run ours layered-ours dxmt "$TESTS/d3d12_layered.exe" "Z:$S/layered.vs.dxil" "Z:$S/layered.ps.dxil"
run ours layered-ref d3dmetal "$TESTS/d3d12_layered.exe" "Z:$S/layered.vs.dxil" "Z:$S/layered.ps.dxil"
expect "layered rendering into a 3D texture matches D3DMetal (within 1/255)" "$(python3 - "$WORK/layered-ours.txt" "$WORK/layered-ref.txt" <<'PY'
import sys
def texels(p):
    for l in open(p):
        s = l.split()
        if s[:2] == ["layered", "ok"]: return [int(x, 16) for x in s[2:]]
a, b = texels(sys.argv[1]), texels(sys.argv[2])
print("yes" if a and b and len(a) == len(b) == 4 and all(abs(((x >> k) & 255) - ((y >> k) & 255)) <= 1 for x, y in zip(a, b) for k in (0, 8, 16, 24)) else f"no {a} {b}")
PY
)" yes
run ours volume-ours dxmt "$TESTS/d3d12_volume.exe" "Z:$S/volume.fill.dxil" "Z:$S/volume.sample.dxil"
run ours volume-ref d3dmetal "$TESTS/d3d12_volume.exe" "Z:$S/volume.fill.dxil" "Z:$S/volume.sample.dxil"
expect "a 3D texture written by compute, then sampled and loaded, matches D3DMetal" \
  "$(grep '^volume ' "$WORK/volume-ours.txt" | tr '\n' ' ')" "$(grep '^volume ' "$WORK/volume-ref.txt" | tr '\n' ' ')"
run ours vsread-ours dxmt "$TESTS/d3d12_vsread.exe" "Z:$S/vsread.vs.dxil" "Z:$S/vsread.ps.dxil"
run ours vsread-ref d3dmetal "$TESTS/d3d12_vsread.exe" "Z:$S/vsread.vs.dxil" "Z:$S/vsread.ps.dxil"
expect "a vertex shader reads typed, structured, 3D and cube resources as on D3DMetal" \
  "$(grep '^vsread ' "$WORK/vsread-ours.txt" || echo none)" "$(grep '^vsread ' "$WORK/vsread-ref.txt" || echo 'D3DMetal printed nothing')"
# Unreal draws grass and GPU particles with ExecuteIndirect: 1024 of them in one render pass, 8 frames, none lost.
indirect() { run ours "$1" "$2" "$TESTS/d3d12_indirect.exe" "Z:$S/indirect.vs.dxil" "Z:$S/indirect.ps.dxil" \
  "Z:$S/indirect.cs.dxil" "Z:$S/indirect.vsid.dxil" "Z:$S/indirect.psid.dxil"; }
indirect indirect-ours dxmt
indirect indirect-ref d3dmetal
expect "1024 indirect draws in one pass paint every cell" "$(grep '^indirect ok' "$WORK/indirect-ours.txt" || echo none)" "indirect ok 8 0"
expect "and on D3DMetal" "$(grep '^indirect ok' "$WORK/indirect-ref.txt" || echo 'D3DMetal printed nothing')" "indirect ok 8 0"
expect "1024 indirect dispatches in one pass run every thread" "$(grep '^indirect dispatch' "$WORK/indirect-ours.txt" || echo none)" "indirect dispatch 81920 81920"
expect "and on D3DMetal" "$(grep '^indirect dispatch' "$WORK/indirect-ref.txt" || echo 'D3DMetal printed nothing')" "indirect dispatch 81920 81920"
# E10: draw signatures that set nothing but the draw: vertices fetched from StartVertexLocation (or index plus
# BaseVertexLocation), instances from StartInstanceLocation, ByteStride and the argument and index buffer offsets kept,
# an instance count of 0 drawing nothing, a count buffer capping the call, and an index buffer placed where a released
# buffer was.
native=$(printf 'indirect %s\n' "native-draw 2,0:107 3,0:100 4,0:100 2,1:108" "counted 2,0:107 2,1:108" \
  "native-indexed 0,0:100 4,0:107 5,0:107 7,0:102 4,1:108 5,1:108" \
  "aliased-indexed 0,0:100 4,0:107 5,0:107 7,0:102 4,1:108 5,1:108")
expect "indirect draws read from the argument buffer draw what D3D12 says" \
  "$(grep -E '^indirect (native|counted|aliased)' "$WORK/indirect-ours.txt" || echo none)" "$native"
expect "and on D3DMetal" "$(grep -E '^indirect (native|counted|aliased)' "$WORK/indirect-ref.txt" || echo 'D3DMetal printed nothing')" "$native"
export DXMT_D3D12_INDIRECT=icb
indirect indirect-icb dxmt
unset DXMT_D3D12_INDIRECT
expect "and with DXMT_D3D12_INDIRECT=icb" "$(grep -E '^indirect (ok|native|counted|aliased)' "$WORK/indirect-icb.txt" || echo none)" \
  "$(printf 'indirect ok 8 0\n%s' "$native")"
# DXMT_STATS: every D3D12 call counted and timed per thread, encoder boundaries with and without a barrier, written to
# <capture folder>/stats.txt (at exit when nothing presents).
rm -rf "$WORK/stats"; export DXMT_DXIL_DUMP="$WORK/stats" DXMT_STATS=1
indirect indirect-stats dxmt
unset DXMT_DXIL_DUMP DXMT_STATS
expect "DXMT_STATS counts every ExecuteIndirect" "$(grep -c '^  list.ExecuteIndirect calls 16388 ' "$WORK/stats/stats.txt" 2> /dev/null || true)" 1
expect "and every encoder boundary, barrier or not" \
  "$(grep -cE '^  encoder boundaries [1-9][0-9]*, [0-9]+ with no barrier$' "$WORK/stats/stats.txt" 2> /dev/null || true)" 1
# E10: the 8192 single draws and the three uncounted calls draw from the argument buffer, with no indirect command buffer
# nor resolver pass; the dispatches' (1024 a frame) and the counted call's are reused once their allocator is reset.
# With DXMT_D3D12_INDIRECT=icb, every draw call's render pass resolves its commands in one compute pass before it.
expect "uncounted indirect draws read the argument buffer, with no indirect command buffer" \
  "$(grep -oE '(ExecuteIndirect native|indirect command buffers created|indirect resolve passes) [0-9]+' "$WORK/stats/stats.txt" 2> /dev/null | sort | tr '\n' ';')" \
  "ExecuteIndirect native 8195;indirect command buffers created 1025;indirect resolve passes 1;"
rm -rf "$WORK/stats-icb"; export DXMT_DXIL_DUMP="$WORK/stats-icb" DXMT_STATS=1 DXMT_D3D12_INDIRECT=icb
indirect indirect-stats-icb dxmt
unset DXMT_DXIL_DUMP DXMT_STATS DXMT_D3D12_INDIRECT
expect "and with DXMT_D3D12_INDIRECT=icb, one resolver pass per render pass" \
  "$(grep -oE '(ExecuteIndirect native|indirect resolve passes) [0-9]+' "$WORK/stats-icb/stats.txt" 2> /dev/null | tr '\n' ';')" \
  "indirect resolve passes 12;"
# GPU timestamps by D3D12's rules (D3DMetal has none), and a timestamp between draws never splits their pass.
rm -rf "$WORK/ts"; export DXMT_DXIL_DUMP="$WORK/ts" DXMT_DUMP_FRAME=0
run ours ts-ours dxmt "$TESTS/d3d12_timestamp.exe" "Z:$S/depth.vs.dxil" "Z:$S/depth.ps.dxil"
unset DXMT_DXIL_DUMP DXMT_DUMP_FRAME
expect "timestamps: frequency, increasing, advancing, calibrated, across lists and counter buffers" \
  "$(grep '^timestamp rules' "$WORK/ts-ours.txt" || true)" "timestamp rules 1 1 1 1 1 1"
expect "a timestamp between draws keeps them one render pass" "$(grep -c ' render ' "$WORK/ts/passes.txt" 2> /dev/null || true)" 1
expect "a timestamp resolve into a default heap never shows a previous submission's value" \
  "$(grep '^timestamp default-heap' "$WORK/ts-ours.txt" || true)" "timestamp default-heap 1"
# A timestamp resolved on the CPU (into a readback heap) needs no blit encoder: the test's 5 resolves made 10 before.
# Since GPU efficiency E4, 3 lone timestamps also ride on the next encoder (and 3 get blits of their own, counted
# apart), so 2 blit passes are left of 8.
rm -rf "$WORK/ts-stats"; export DXMT_DXIL_DUMP="$WORK/ts-stats" DXMT_STATS=1
run ours ts-stats dxmt "$TESTS/d3d12_timestamp.exe" "Z:$S/depth.vs.dxil" "Z:$S/depth.ps.dxil"
unset DXMT_DXIL_DUMP DXMT_STATS
expect "timestamps resolved on the CPU open no blit encoder" "$(grep -c '^  blit passes 2$' "$WORK/ts-stats/stats.txt" 2> /dev/null || true)" 1
run ours ts-leak dxmt "$TESTS/d3d12_timestamp.exe" "Z:$S/depth.vs.dxil" "Z:$S/depth.ps.dxil" leak
expect "1500 timestamp resolves grow memory by under 16 MB" "$(grep -o 'ok [01]$' "$WORK/ts-leak.txt" || true)" "ok 1"
expect "our DXMT claims no raytracing, mesh shaders, VRS or sampler feedback" \
  "$(grep '^caps ' "$WORK/api-ours.txt" || true)" "caps rt=0 mesh=0 vrs=0 sfb=0"

# 7. The D3D12 translation cache (shader pre-caching spec §5.1). Runs 1-5 share one folder; the counter line is ours
#    only. Each mode changes one thing a reused translated function would get wrong, so that function must miss.
cachetest() { run ours "$1" dxmt "$TESTS/d3d12_cache.exe" "Z:$S/cache.vs.dxil" "Z:$S/cache.ps.dxil" "Z:$S/cache.cs.dxil" "$2"; }
counters() { grep -o 'd3d12 shader cache: .*' "$WORK/$1.txt" | tail -1; }
drawn() { grep '^cache ' "$WORK/$1.txt" || echo "no cache line in $1"; }
for m in a rt layout root; do
  run ours "cache-ref-$m" d3dmetal "$TESTS/d3d12_cache.exe" "Z:$S/cache.vs.dxil" "Z:$S/cache.ps.dxil" "Z:$S/cache.cs.dxil" $m
done
CACHE="$WORK/cache/shared"
cachetest cache1 a
expect "cache run 1 (cold) draws as D3DMetal" "$(drawn cache1)" "$(drawn cache-ref-a)"
expect "cache run 1 misses every lookup" "$(counters cache1)" \
  "d3d12 shader cache: functions 0 hit 3 missed, reflections 0 hit 3 missed"
cachetest cache2 a
expect "cache run 2 (warm) draws as D3DMetal" "$(drawn cache2)" "$(drawn cache-ref-a)"
expect "cache run 2 only hits" "$(counters cache2)" "d3d12 shader cache: functions 3 hit 0 missed, reflections 3 hit 0 missed"
echo "info pipeline creation: $(grep '^timing' "$WORK/cache1.txt") ms cold, $(grep '^timing' "$WORK/cache2.txt") ms warm"
cachetest cache3rt rt
expect "another render target format draws as D3DMetal" "$(drawn cache3rt)" "$(drawn cache-ref-rt)"
expect "and misses the pixel shader only" "$(counters cache3rt)" \
  "d3d12 shader cache: functions 2 hit 1 missed, reflections 3 hit 0 missed"
cachetest cache3layout layout
expect "another input layout draws as D3DMetal" "$(drawn cache3layout)" "$(drawn cache-ref-layout)"
expect "and misses the vertex shader only" "$(counters cache3layout)" \
  "d3d12 shader cache: functions 2 hit 1 missed, reflections 3 hit 0 missed"
cachetest cache3root root
expect "another root signature draws as D3DMetal" "$(drawn cache3root)" "$(drawn cache-ref-root)"
expect "and misses both graphics shaders" "$(counters cache3root)" \
  "d3d12 shader cache: functions 1 hit 2 missed, reflections 3 hit 0 missed"
db="$CACHE/shaders_310.db"
sqlite3 "$db" "UPDATE \"$(sqlite3 "$db" "SELECT name FROM sqlite_master WHERE name GLOB 'cache_*'")\" SET value = x'00';"
cachetest cache4 a
expect "corrupt entries: still draws as D3DMetal" "$(drawn cache4)" "$(drawn cache-ref-a)"
expect "corrupt entries are misses" "$(counters cache4)" \
  "d3d12 shader cache: functions 0 hit 3 missed, reflections 0 hit 3 missed"
expect "a rejected cached function is logged once" \
  "$(grep -c 'd3d12 shader cache: rejected a cached function, recompiling' "$WORK/cache4.txt" || true)" 1
sqlite3 "$db" "CREATE TABLE cache_1 (key BLOB PRIMARY KEY, value BLOB NOT NULL);"
cachetest cache5 a
expect "D3D12 drops another build's table too" "$(sqlite3 "$db" "SELECT count(*) FROM sqlite_master WHERE name = 'cache_1'")" 0
expect "and still draws as D3DMetal" "$(drawn cache5)" "$(drawn cache-ref-a)"
# A probed run (DXMT_PROBE rewrites a pixel shader's output for frame debugging) neither reads nor stores translated
# functions: stored, they would draw a later normal run in the probe's colours.
CACHE="$WORK/cache/probe"
export DXMT_PROBE=0000000000000000:-,-,-
cachetest probe1 a
unset DXMT_PROBE
cachetest probe2 a
expect "a probed run stores no translated function" "$(counters probe2)" \
  "d3d12 shader cache: functions 0 hit 3 missed, reflections 3 hit 0 missed"
CACHE="$WORK/cache/gs"
run ours trigs-cold dxmt "$TESTS/d3d12_triangle.exe" "Z:$S/triangle2.vs.dxil" "Z:$S/triangle2.ps.dxil" "Z:$S/triangle2.gs.dxil"
run ours trigs-warm dxmt "$TESTS/d3d12_triangle.exe" "Z:$S/triangle2.vs.dxil" "Z:$S/triangle2.ps.dxil" "Z:$S/triangle2.gs.dxil"
expect "a warm geometry-shader pipeline only hits" \
  "$(counters trigs-warm | grep -cE 'functions [1-9][0-9]* hit 0 missed, reflections [1-9][0-9]* hit 0 missed$' || true)" 1
expect "and draws as D3DMetal" "$(same_pixels "$WORK/trigs-warm.txt" "$WORK/trigs-ref.txt")" yes
unset CACHE
# 8. Recording (spec §3.5, §5.2 runs 6-7): each pipeline once, a torn tail cut and re-recorded, a foreign file
#    started over, and an unwritable folder that changes nothing drawn.
REC="$WORK/rec"; f="$REC/d3d12_cache.exe.pipelines"
export DXMT_PIPELINE_RECORD="$REC"
CACHE="$WORK/cache/rec"
cachetest rec6 a
expect "run 6: the pipelines are recorded" "$(head -c 8 "$f" 2> /dev/null)" DXMTPRC1
full=$(wc -c < "$f" | tr -d ' ')
cachetest rec7 a
expect "run 7: a second run records nothing new" "$(wc -c < "$f" | tr -d ' ')" "$full"
python3 -c "import os, sys; os.truncate(sys.argv[1], os.path.getsize(sys.argv[1]) - 10)" "$f"
cachetest rec-torn a
expect "a torn tail is cut and its pipeline recorded again" "$(wc -c < "$f" | tr -d ' ')" "$full"
expect "recording changes nothing drawn" "$(drawn rec-torn)" "$(drawn cache-ref-a)"
printf 'not a recording' > "$f"
cachetest rec-foreign a
expect "a foreign file is started over" "$(head -c 8 "$f"):$(wc -c < "$f" | tr -d ' ')" "DXMTPRC1:$full"
export DXMT_PIPELINE_RECORD="/nonexistent/macneutron rec"
cachetest rec-unwritable a
expect "an unwritable recording folder changes nothing drawn" "$(drawn rec-unwritable)" "$(drawn cache-ref-a)"
expect "and says once that recording is off" "$(grep -c 'd3d12 pipeline recording off' "$WORK/rec-unwritable.txt" || true)" 1
unset DXMT_PIPELINE_RECORD CACHE
# 9. Replay (spec §3.6, §5.2 runs 8-12): dxmt-replay.exe rebuilds a recording into that game's caches.
RP="$WORK/ours/Libraries/DXMT/x64/dxmt-replay.exe"
replay() { run ours "$1" dxmt "$RP" "Z:$2"; grep '^replay: ' "$WORK/$1.txt" | tail -1 | sed 's/, [0-9]* ms$//'; }
UC="$(getconf DARWIN_USER_CACHE_DIR)dxmt"; rm -rf "$UC/d3d12_cache.exe" "$UC/dxmt-replay.exe"
CACHE="$WORK/cache/replay"
expect "run 8: the replay rebuilds every recorded pipeline" "$(replay rep8 "$f")" \
  "replay: 2 pipelines (1 graphics, 1 compute), 2 created, 0 failed, 0 bad records"
expect "into the game's Metal cache, not the replayer's" \
  "$([ -d "$UC/d3d12_cache.exe/com.apple.metal" ] && echo game):$([ -d "$UC/dxmt-replay.exe" ] && echo replayer)" "game:"
cachetest rep9 a
expect "run 9: after a replay the game only hits" "$(counters rep9)" \
  "d3d12 shader cache: functions 3 hit 0 missed, reflections 3 hit 0 missed"
expect "and draws as D3DMetal" "$(drawn rep9)" "$(drawn cache-ref-a)"
cp "$f" "$WORK/torn.pipelines"
python3 -c "import os, sys; os.truncate(sys.argv[1], os.path.getsize(sys.argv[1]) - 10)" "$WORK/torn.pipelines"
CACHE="$WORK/cache/replay-torn"
expect "run 10: a torn record is skipped and counted" "$(replay rep10 "$WORK/torn.pipelines")" \
  "replay: 1 pipelines (1 graphics, 0 compute), 1 created, 0 failed, 1 bad records"
export DXMT_PIPELINE_RECORD="$WORK/rec-gs"
CACHE="$WORK/cache/gs-rec"
run ours gs-rec dxmt "$TESTS/d3d12_triangle.exe" "Z:$S/triangle2.vs.dxil" "Z:$S/triangle2.ps.dxil" "Z:$S/triangle2.gs.dxil"
export DXMT_PIPELINE_RECORD="$WORK/rec-threads"
run ours threads-rec dxmt "$TESTS/d3d12_dxil_exec.exe" "Z:$X" threads
unset DXMT_PIPELINE_RECORD
CACHE="$WORK/cache/gs-replay"
expect "run 12: a geometry-shader pipeline replays" \
  "$(replay gs-replay "$WORK/rec-gs/d3d12_triangle.exe.pipelines" | grep -cE '^replay: [1-9][0-9]* pipelines .*, 0 failed, 0 bad records$' || true)" 1
run ours gs-after dxmt "$TESTS/d3d12_triangle.exe" "Z:$S/triangle2.vs.dxil" "Z:$S/triangle2.ps.dxil" "Z:$S/triangle2.gs.dxil"
expect "and then only hits" \
  "$(counters gs-after | grep -cE 'functions [1-9][0-9]* hit 0 missed, reflections [1-9][0-9]* hit 0 missed$' || true)" 1
expect "and draws as D3DMetal" "$(same_pixels "$WORK/gs-after.txt" "$WORK/trigs-ref.txt")" yes
CACHE="$WORK/cache/threads"
expect "pipelines created on 8 threads at once replay whole" \
  "$(replay threads-replay "$WORK/rec-threads/d3d12_dxil_exec.exe.pipelines" | grep -cE '^replay: [1-9][0-9]* pipelines .*, 0 failed, 0 bad records$' || true)" 1
# A recorded pipeline this DXMT can't build (a junk shader), and a file that isn't a recording.
python3 - "$WORK/junk.pipelines" <<'PY'
import hashlib, struct, sys
def fnv(b):
    h = 0xcbf29ce484222325
    for x in b: h = ((h ^ x) * 0x100000001b3) & 0xffffffffffffffff
    return h
def record(kind, payload, id):
    return struct.pack("<IIQ", kind, len(payload), fnv(payload)) + id + payload
junk = b"DXBC" + bytes(60)
compute = bytes(20) + hashlib.sha1(junk).digest() + struct.pack("<II", 0, 0)  # no root signature, the junk CS
open(sys.argv[1], "wb").write(b"DXMTPRC1" + record(1, junk, hashlib.sha1(junk).digest())
                              + record(3, compute, hashlib.sha1(compute).digest()))
PY
CACHE="$WORK/cache/junk"
expect "a recorded pipeline that no longer builds is counted, not fatal" "$(replay junk "$WORK/junk.pipelines")" \
  "replay: 1 pipelines (0 graphics, 1 compute), 0 created, 1 failed, 0 bad records"
printf 'nope' > "$WORK/foreign.pipelines"
expect "a file that isn't a recording is refused" "$(replay foreign "$WORK/foreign.pipelines")" "replay: not a recording"
unset CACHE
# 10. The launcher (spec §3.7): recordings land in the compat folder and the first session stamps the builds; with
#     another build in the stamp, the next launch replays every recording before the game, which then only hits.
#     (d3d12_cache's recording there holds every mode section 7 ran: a, rt, layout and root.)
P="$WORK/compat/ours/dxmt-pipelines"
expect "the launcher records into the game's compat folder" "$([ -s "$P/d3d12_cache.exe.pipelines" ] && echo yes || echo no)" yes
expect "and stamps the builds after the first session" "$(cut -d ' ' -f 1 "$P/replayed" 2> /dev/null)" "$(cat "$WORK/ours/dxmt-version")"
echo "old build" > "$P/replayed"
LLOG="$HOME/Library/Logs/MacNeutron/launcher.log"; before=$(cat "$LLOG" 2> /dev/null | wc -l)
CACHE="$WORK/cache/e2e"
cachetest e2e a
unset CACHE
expect "a changed build replays d3d12_cache's recording before the game" \
  "$(tail -n +$((before + 1)) "$LLOG" | grep -cE 'precache: d3d12_cache\.exe\.pipelines exit=0 replay: [1-9][0-9]* pipelines .*, 0 failed, 0 bad records' || true)" 1
expect "then the game only hits" "$(counters e2e)" "d3d12 shader cache: functions 3 hit 0 missed, reflections 3 hit 0 missed"
expect "and draws as D3DMetal" "$(drawn e2e)" "$(drawn cache-ref-a)"
expect "and the stamp holds the current builds" "$(cut -d ' ' -f 1 "$P/replayed")" "$(cat "$WORK/ours/dxmt-version")"
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
expect "dxil-translate accepts every behaviour shader but heap" "$(tail -1 "$WORK/translate.txt" | cut -d ' ' -f 2)" "11/12"
"$DXMT/dxil-translate" "$S" > "$WORK/translate-shaders.txt" 2>&1 || true
expect "dxil-translate accepts the test shaders" "$(tail -1 "$WORK/translate-shaders.txt" | cut -d ' ' -f 2)" "31/31"
# DXIL keeps NaN and infinity: no translated shader assumes them away or keeps a fast compare. Vertex and geometry
# shaders also stay unfused and unreassociated, as airconv's DXBC path: a depth prepass and a base pass then compute
# the same positions, and their depth EQUAL test holds (grass flickered in SMITE 2 without it).
"$DXMT/dxil-translate" "$S" --flags > "$WORK/translate-flags.txt" 2>&1 || true
expect "no translated shader assumes NaN or infinity away" \
  "$(grep -c '^ok ' "$WORK/translate-flags.txt" || true):$(grep '^ok ' "$WORK/translate-flags.txt" | grep -c ' nnan=0 ninf=0 cmp=0 ' || true)" "31:31"
expect "vertex and geometry shaders keep their math unfused" \
  "$(grep -E '^ok [^ ]+ (vs|gs) ' "$WORK/translate-flags.txt" | grep -c ' reassoc=0 contract=0 arcp=0$' || true)" 10

# 8. Encoder ordering (GPU overlap spec §5): each mode's first pass is heavy, so work after it that doesn't wait for it
#    reads or overwrites its results early. Our DXMT in strict order (the default), with overlap (DXMT_D3D12_OVERLAP=1),
#    and in strict order while dumping passes and pixel history (the queue's own encoders), and D3DMetal print the
#    same lines.
hazards() { grep '^hazard ' "$WORK/$1.txt" || echo "no hazard lines in $1"; }
want=$(printf 'hazard %s\n' "rt-read 257" "same-target 7 5" "uav 1048576" "copy-read 6" "indirect 9" "aliasing 2" \
  "occlusion 268435456" "independent 256 256" "precise 257" "mid-pass 77" "twice 514" "many 1200 1200" "clear-rects 3 256" \
  "signal 0" "wrap 4194304" "onewait 256 5 6" "newest 3 2" "nodraw 257" "queues 257 257" "unsplit 257" "unsplit-barrier 257" \
  "unsplit-samebuffer 257" "unsplit-midbarrier 258" "unsplit-query 258 268435456 1048576" "unsplit-twice 2" "deferred 1" "zeroed 0 0" "fold 6 2 9 5" "fold-order 6 7" \
  "fence-reset 1" "fence-cpu-late 1" "fence-transitive 0 0" "fence-custom 1" "fence-lower 0 1" "fence-wait-first 257" "fence-order 1 1" "two-heaps 1 1" "ts-start 1" "after-own-blit 7" \
  "fold-lists 6 2" "fold-lists-barrier 6 2" "fold-m4 11 7" "fold-twice 10 14" "fold-copy 2 6 2" "indirect-war 265" \
  "merge-indirect 10")
run ours hazards dxmt "$TESTS/d3d12_hazards.exe" "Z:$S"
export DXMT_D3D12_OVERLAP=1
run ours hazards-overlap dxmt "$TESTS/d3d12_hazards.exe" "Z:$S"
unset DXMT_D3D12_OVERLAP
run ours hazards-ref d3dmetal "$TESTS/d3d12_hazards.exe" "Z:$S"
expect "work after a heavy pass waits for it (strict order, the default)" "$(hazards hazards)" "$want"
expect "and with overlap (DXMT_D3D12_OVERLAP=1)" "$(hazards hazards-overlap)" "$want"
# D3DMetal counts the second list's draw before its own query into the first list's ended query 0 (269484032);
# D3D12 ends query 0 at its EndQuery, as our DXMT does (268435456).
# D3DMetal resolves timestamps as zero, so two-heaps reads 0 0 there.
expect "and on D3DMetal (but for its occlusion count after a merged pass, and its zero timestamps)" "$(hazards hazards-ref)" \
  "$(echo "$want" | sed -e 's/^hazard unsplit-query 258 268435456 1048576$/hazard unsplit-query 258 269484032 1048576/' \
    -e 's/^hazard two-heaps 1 1$/hazard two-heaps 0 0/' -e 's/^hazard ts-start 1$/hazard ts-start 0/')"
rm -rf "$WORK/hz-dump"; export DXMT_DXIL_DUMP="$WORK/hz-dump" DXMT_DUMP_FRAME=0 DXMT_DUMP_PIXEL=512,512,0,40
run ours hazards-dump dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" rt-read indirect precise
unset DXMT_DXIL_DUMP DXMT_DUMP_FRAME DXMT_DUMP_PIXEL
expect "and while dumping passes and pixel history" "$(hazards hazards-dump)" \
  "$(printf 'hazard %s\n' "rt-read 257" "indirect 9" "precise 257")"
# Overlap happens when asked for (GPU overlap spec §3.8): with DXMT_D3D12_OVERLAP=1, passes into different targets
# with no barrier between them leave their boundaries free to overlap; by default (strict order) none is, and every
# encoder joins.
rm -rf "$WORK/ov-stats" "$WORK/ov-default"; export DXMT_DXIL_DUMP="$WORK/ov-stats" DXMT_STATS=1 DXMT_D3D12_OVERLAP=1
run ours ov-stats dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" independent
unset DXMT_D3D12_OVERLAP; export DXMT_DXIL_DUMP="$WORK/ov-default"
run ours ov-default dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" independent
unset DXMT_DXIL_DUMP DXMT_STATS
expect "independent passes are free to overlap with DXMT_D3D12_OVERLAP=1" \
  "$(grep -cE '^  encoder boundaries free to overlap [1-9]' "$WORK/ov-stats/stats.txt" 2> /dev/null || true)" 1
expect "and never by default (strict order)" \
  "$(grep -c '^  encoder boundaries free to overlap' "$WORK/ov-default/stats.txt" 2> /dev/null || true):$(grep -c '^  encoder full joins' "$WORK/ov-default/stats.txt" 2> /dev/null || true)" "0:1"
# M2 (GPU overlap spec §3.1): a barrier ending one render target's writes makes later work wait on that target's
# writer alone. d3d12_hazards precise: the sampling pass waits on T0's pass (not T1's), the read on T0's and T2's.
rm -rf "$WORK/precise-stats"; export DXMT_DXIL_DUMP="$WORK/precise-stats" DXMT_STATS=1 DXMT_D3D12_OVERLAP=1
run ours precise-stats dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" precise
unset DXMT_DXIL_DUMP DXMT_STATS DXMT_D3D12_OVERLAP
expect "a transition waits on the transitioned resource's writers alone" \
  "$(grep -oE '(encoders with a dependency list|encoder dependency waits) [0-9]+' "$WORK/precise-stats/stats.txt" 2> /dev/null | tr '\n' ';')" \
  "encoder dependency waits 3;encoders with a dependency list 2;"
# A (GPU overlap spec §3.9): encoders after a join wait on its early fence alone, and on the newest writer of what
# they write. d3d12_hazards onewait and newest, each alone.
for m in onewait newest; do
  rm -rf "$WORK/$m-stats"; export DXMT_DXIL_DUMP="$WORK/$m-stats" DXMT_STATS=1 DXMT_D3D12_OVERLAP=1
  run ours "$m-stats" dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" $m
  unset DXMT_DXIL_DUMP DXMT_STATS DXMT_D3D12_OVERLAP
done
expect "encoders after a join wait on one fence" \
  "$(grep -oE 'encoder fence waits [0-9]+' "$WORK/onewait-stats/stats.txt" 2> /dev/null)" "encoder fence waits 10"
rm -rf "$WORK/onewait-default"; export DXMT_DXIL_DUMP="$WORK/onewait-default" DXMT_STATS=1
run ours onewait-default dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" onewait
unset DXMT_DXIL_DUMP DXMT_STATS
expect "early fences only with overlap" \
  "$(grep -c 'encoder early fences' "$WORK/onewait-default/stats.txt" 2> /dev/null || true):$(grep -c 'encoder early fences' "$WORK/onewait-stats/stats.txt" 2> /dev/null || true)" "0:1"
expect "and on the newest writer alone" \
  "$(grep -oE 'encoder dependency waits [0-9]+' "$WORK/newest-stats/stats.txt" 2> /dev/null)" "encoder dependency waits 3"
# B (GPU overlap spec §3.10): Wait, ExecuteCommandLists and Signal go into one Metal command buffer. d3d12_hazards
# queues alone: three such sequences over two queues.
rm -rf "$WORK/queues-stats"; export DXMT_DXIL_DUMP="$WORK/queues-stats" DXMT_STATS=1
run ours queues-stats dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" queues
unset DXMT_DXIL_DUMP DXMT_STATS
expect "a Wait rides in its ExecuteCommandLists' command buffer, which commits at once" \
  "$(grep -oE 'command buffers committed [0-9]+' "$WORK/queues-stats/stats.txt" 2> /dev/null)" "command buffers committed 6"
# M5 (GPU overlap spec §3.11): a queue waiting on another queue's fence waits on its MTLEvent (released in under 1 us,
# against 130-150 us for the shared event): both of d3d12_hazards queues' waits, neither met when encoded.
expect "a queue waits on another queue's fence through its GPU event" \
  "$(grep -oE '(queue waits on the GPU event|queue waits already met) [0-9]+' "$WORK/queues-stats/stats.txt" 2> /dev/null | tr '\n' ';')" \
  "queue waits on the GPU event 2;"
# A signal waits for timestamps resolved on the CPU only while some are pending (d3d12_hazards deferred alone).
rm -rf "$WORK/deferred-stats"; export DXMT_DXIL_DUMP="$WORK/deferred-stats" DXMT_STATS=1
run ours deferred-stats dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" deferred
unset DXMT_DXIL_DUMP DXMT_STATS
expect "a signal behind no pending timestamps stays on the GPU" \
  "$(grep -oE 'fence signals deferred to the CPU [0-9]+' "$WORK/deferred-stats/stats.txt" 2> /dev/null)" "fence signals deferred to the CPU 1"
# M3 (GPU overlap spec §3.5): two lists' passes into one target with only a timestamp between them are one Metal render
# pass; not across a barrier (between or inside the passes), nor when the timestamp's counter buffer is already
# sampled at that pass's end, nor out of a pass counting into an occlusion query, nor a list into itself.
rm -rf "$WORK/m3-stats"; export DXMT_DXIL_DUMP="$WORK/m3-stats" DXMT_STATS=1
run ours m3-stats dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" unsplit unsplit-barrier unsplit-samebuffer unsplit-midbarrier \
  unsplit-query unsplit-twice
unset DXMT_DXIL_DUMP DXMT_STATS
expect "render passes into one target across lists are one Metal render pass" \
  "$(grep -oE '(render passes merged|timestamp blits folded) [0-9]+' "$WORK/m3-stats/stats.txt" 2> /dev/null | tr '\n' ';')" \
  "render passes merged 1;timestamp blits folded 1;"
rm -rf "$WORK/m3-off-stats"; export DXMT_DXIL_DUMP="$WORK/m3-off-stats" DXMT_STATS=1 DXMT_D3D12_MERGE=0
run ours m3-off-stats dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" unsplit
unset DXMT_DXIL_DUMP DXMT_STATS DXMT_D3D12_MERGE
expect "and none with DXMT_D3D12_MERGE=0" \
  "$(grep -c 'render passes merged' "$WORK/m3-off-stats/stats.txt" 2> /dev/null || true):$(grep '^hazard ' "$WORK/m3-off-stats.txt")" "0:hazard unsplit 257"

# M4 (GPU overlap spec §3.6): a clear then a pass into the cleared target, no barrier between: one Metal render pass
# with the clear as its load action. Not across a barrier, nor with DXMT_D3D12_MERGE=0.
rm -rf "$WORK/m4-stats"; export DXMT_DXIL_DUMP="$WORK/m4-stats" DXMT_STATS=1
run ours m4-stats dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" fold
unset DXMT_DXIL_DUMP DXMT_STATS
# T1's clear, behind a barrier on T2, folds at execution since GPU efficiency E7 (counted apart): no clear pass is left.
expect "a clear before a pass into its target is the pass's load action" \
  "$(grep -oE '(clears folded|clear passes) [0-9]+' "$WORK/m4-stats/stats.txt" 2> /dev/null | sort | tr '\n' ';')" \
  "clears folded 1;"
rm -rf "$WORK/m4-off-stats"; export DXMT_DXIL_DUMP="$WORK/m4-off-stats" DXMT_STATS=1 DXMT_D3D12_MERGE=0
run ours m4-off-stats dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" fold
unset DXMT_DXIL_DUMP DXMT_STATS DXMT_D3D12_MERGE
expect "and none with DXMT_D3D12_MERGE=0" \
  "$(grep -oE '(clears folded|clear passes) [0-9]+' "$WORK/m4-off-stats/stats.txt" 2> /dev/null | sort | tr '\n' ';'):$(grep '^hazard ' "$WORK/m4-off-stats.txt")" \
  "clear passes 2;:hazard fold 6 2 9 5"

# 9. GPU efficiency (spec 2026-10-02). E1: D3D12 textures that aren't UAVs get Apple lossless compression (which
#    PixelFormatView usage alone would turn off): a clear-only pass of a 3840x2160 RGBA16F target is at least 3x
#    cheaper than with DXMT_D3D12_COMPRESSION=0, and writes through other views of one layout, copies and placed
#    textures read back as on D3DMetal.
run ours compress dxmt "$TESTS/d3d12_compress.exe"
export DXMT_D3D12_COMPRESSION=0
run ours compress-off dxmt "$TESTS/d3d12_compress.exe"
unset DXMT_D3D12_COMPRESSION
run ours compress-ref d3dmetal "$TESTS/d3d12_compress.exe"
clear_on=$(awk '/^compress clear /{print $3}' "$WORK/compress.txt"); clear_off=$(awk '/^compress clear /{print $3}' "$WORK/compress-off.txt")
expect "compressed targets clear at least 3x cheaper ($clear_on against $clear_off us)" \
  "$(awk -v on="$clear_on" -v off="$clear_off" 'BEGIN { print (on > 0 && off >= 3 * on) ? "yes" : "no" }')" yes
expect "and read back as on D3DMetal through other views, copies and heap placement" \
  "$(grep -E '^compress (views|placed) ' "$WORK/compress.txt")" "$(grep -E '^compress (views|placed) ' "$WORK/compress-ref.txt")"

# E4: a lone timestamp (a list's first, or a list of timestamps alone) is taken at the start of the next encoder the
# queue encodes, not by a blit of its own. d3d12_hazards ts-start alone: t0 and t4 ride on the passes after them;
# t2 and t3, which come before t4, keep blits of their own ahead of it.
rm -rf "$WORK/e4-stats"; export DXMT_DXIL_DUMP="$WORK/e4-stats" DXMT_STATS=1
run ours e4-stats dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" ts-start
unset DXMT_DXIL_DUMP DXMT_STATS
expect "a lone timestamp is taken at the next encoder's start" \
  "$(grep -oE "timestamps at the next encoder's start [0-9]+" "$WORK/e4-stats/stats.txt" 2> /dev/null):$(grep '^hazard ' "$WORK/e4-stats.txt")" \
  "timestamps at the next encoder's start 2:hazard ts-start 1"

# E5: a raw or structured buffer load is bounds-checked once for all its components, those the shader reads
# (shaders/bounds.hlsl: a 16-dword view from dword 4 and a 4-element view, over buffers holding 1..32). In bounds (the
# view's last dwords too), out of bounds and at an offset whose end wraps 32 bits read as on D3DMetal; a load
# straddling the view's end reads zeros, where D3DMetal reads past the view (19 20 21 22, 20 21).
run ours bounds dxmt "$TESTS/d3d12_bounds.exe" "Z:$S/bounds.cs.dxil"
run ours bounds-ref d3dmetal "$TESTS/d3d12_bounds.exe" "Z:$S/bounds.cs.dxil"
expect "buffer loads read zeros outside their views, in one check per load" \
  "$(grep '^bounds ' "$WORK/bounds.txt")" "bounds 5 6 7 8 0 0 0 0 0 0 0 0 0 0 0 0 13 14 15 16 0 0 0 0 20 19 20 0 0 0 0 0"
expect "and as on D3DMetal but where a load straddles the view's end" \
  "$(grep '^bounds ' "$WORK/bounds-ref.txt")" "bounds 5 6 7 8 19 20 21 22 0 0 0 0 20 21 0 0 13 14 15 16 0 0 0 0 20 19 20 0 0 0 0 0"

# E7: a clear-only pass folds into the first pass binding its view later in the same call, across lists, timestamps
# and barriers on other textures (fold-lists); not across a barrier naming its texture (fold-lists-barrier) or a copy
# of it (fold-copy). d3d12_hazards, each mode alone.
for m in fold-lists fold-lists-barrier fold-copy; do
  rm -rf "$WORK/e7-$m"; export DXMT_DXIL_DUMP="$WORK/e7-$m" DXMT_STATS=1
  run ours "e7-$m" dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" $m
  unset DXMT_DXIL_DUMP DXMT_STATS
done
e7() { grep -oE '(clears folded at execute|clear folds refused \([a-z ]+\)) [0-9]+' "$WORK/e7-$1/stats.txt" 2> /dev/null | tr '\n' ';'; }
expect "a clear folds into its pass across lists" "$(e7 fold-lists)" "clears folded at execute 1;"
expect "but not across a barrier naming its texture" "$(e7 fold-lists-barrier)" "clear folds refused (barrier) 1;"
expect "nor across a copy of it" "$(e7 fold-copy)" "clear folds refused (barrier) 1;"

# E10: two lists' passes into one target, each an indirect draw read from the argument buffer, are one Metal render
# pass (no resolver pass before the second); with DXMT_D3D12_INDIRECT=icb, two.
for m in native icb; do
  rm -rf "$WORK/e10-$m"; export DXMT_DXIL_DUMP="$WORK/e10-$m" DXMT_STATS=1 DXMT_D3D12_INDIRECT=$m
  run ours "e10-$m" dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" merge-indirect
  unset DXMT_DXIL_DUMP DXMT_STATS DXMT_D3D12_INDIRECT
done
e10() { echo "$(grep -oE 'render passes merged [0-9]+' "$WORK/e10-$1/stats.txt" 2> /dev/null):$(grep '^hazard ' "$WORK/e10-$1.txt")"; }
expect "indirect draws from the argument buffer merge across lists" "$(e10 native)" "render passes merged 1:hazard merge-indirect 10"
expect "and with DXMT_D3D12_INDIRECT=icb, don't" "$(e10 icb)" ":hazard merge-indirect 10"

[ $fail = 0 ] && echo "dxmt-check: all passed"
exit $fail
