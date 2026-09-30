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
ls -l ./*.dxil
# DXIL translator behaviour groups (dxmt/tests/dxil; see common.hlsli). 16-bit types where the group needs them.
cd "$HERE/../dxil"
for g in buffers math transcendental textures groupshared wave atomics quad heap specials; do dxc -T cs_6_6 -E main -Fo "$g.dxil" "$g.hlsl"; done
for g in half packed; do dxc -T cs_6_6 -E main -enable-16bit-types -Fo "$g.dxil" "$g.hlsl"; done
ls -l ./*.dxil
