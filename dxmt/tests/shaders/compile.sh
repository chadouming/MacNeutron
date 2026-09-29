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
ls -l ./*.dxil
