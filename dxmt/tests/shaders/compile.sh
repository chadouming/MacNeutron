#!/bin/sh
# Compiles the test shaders to DXIL with Microsoft's dxc.exe under the installed runtime's Wine (DXMT fork spec §6).
# Needs `make dxmt`, which fetches DXC. The .dxil files are committed; rerun this after editing a shader.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
TOOL="${MACNEUTRON_TOOL:-$HOME/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron}"
DXC="$ROOT/build/dxmt-src/dxc/bin/x64/dxc.exe"
export WINEPREFIX="${TMPDIR:-/tmp}/macneutron dxc" WINEDEBUG=-all
cd "$HERE"  # relative paths: dxc.exe would read a leading / as an option
dxc() { "$TOOL/Libraries/Wine/bin/wine" "$DXC" "$@"; }
dxc -T vs_6_0 -E vsmain -Fo triangle.vs.dxil triangle.hlsl
dxc -T ps_6_0 -E psmain -Fo triangle.ps.dxil triangle.hlsl
dxc -T cs_6_0 -E csmain -Fo compute.cs.dxil compute.hlsl
dxc -T vs_6_6 -E vsmain -Fo triangle2.vs.dxil triangle2.hlsl
dxc -T ps_6_6 -E psmain -Fo triangle2.ps.dxil triangle2.hlsl
dxc -T gs_6_6 -E gsmain -Fo triangle2.gs.dxil triangle2.hlsl
dxc -T vs_6_6 -E vsmain -Fo depth.vs.dxil depth.hlsl
dxc -T ps_6_6 -E psmain -Fo depth.ps.dxil depth.hlsl
dxc -T ps_6_6 -E psdepth -Fo depth.psdepth.dxil depth.hlsl
dxc -T cs_6_0 -E main -Fo null.cs.dxil null.hlsl
dxc -T vs_6_6 -E vsmain -Fo cache.vs.dxil cache.hlsl
dxc -T ps_6_6 -E psmain -Fo cache.ps.dxil cache.hlsl
dxc -T cs_6_6 -E csmain -Fo cache.cs.dxil cache.hlsl
dxc -T vs_6_6 -E vsmain -Fo layered.vs.dxil layered.hlsl
dxc -T ps_6_6 -E psmain -Fo layered.ps.dxil layered.hlsl
dxc -T cs_6_6 -E fill -Fo volume.fill.dxil volume.hlsl
dxc -T cs_6_6 -E sample -Fo volume.sample.dxil volume.hlsl
dxc -T vs_6_6 -E vsmain -Fo vsread.vs.dxil vsread.hlsl
dxc -T ps_6_6 -E psmain -Fo vsread.ps.dxil vsread.hlsl
dxc -T vs_6_6 -E vsmain -Fo indirect.vs.dxil indirect.hlsl
dxc -T ps_6_6 -E psmain -Fo indirect.ps.dxil indirect.hlsl
dxc -T cs_6_6 -E csmain -Fo indirect.cs.dxil indirect.hlsl
dxc -T vs_6_6 -E vsfull -Fo hazards.vsfull.dxil hazards.hlsl
dxc -T ps_6_6 -E psvalue -Fo hazards.psvalue.dxil hazards.hlsl
dxc -T ps_6_6 -E pssample -Fo hazards.pssample.dxil hazards.hlsl
dxc -T cs_6_6 -E csfill -Fo hazards.csfill.dxil hazards.hlsl
dxc -T cs_6_6 -E cscount -Fo hazards.cscount.dxil hazards.hlsl
dxc -T cs_6_6 -E csargs -Fo hazards.csargs.dxil hazards.hlsl
ls -l ./*.dxil
# DXIL translator behaviour groups (dxmt/tests/dxil; see common.hlsli). 16-bit types where the group needs them.
cd "$HERE/../dxil"
for g in buffers math transcendental textures groupshared wave atomics quad heap specials; do dxc -T cs_6_6 -E main -Fo "$g.dxil" "$g.hlsl"; done
for g in half packed; do dxc -T cs_6_6 -E main -enable-16bit-types -Fo "$g.dxil" "$g.hlsl"; done
ls -l ./*.dxil
