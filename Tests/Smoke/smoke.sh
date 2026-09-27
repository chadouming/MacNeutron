#!/bin/sh
# Real-Wine smoke test (spec section 7). Not run in CI: GitHub's macOS runners are unreliable for GPU work.
# Needs: `brew install mingw-w64`, and network on the first run (461 MB runtime download, then cached).
# Optional: MACPROTON_TARBALL=<Libraries.tar.gz> skips the download; GPTK=<mounted GPTK volume> adds d3dmetal.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/macproton smoke"   # a space on purpose: Steam's paths have one
TOOL="$WORK/tool"
rm -rf "$WORK/compatdata"
mkdir -p "$WORK/bin"

x86_64-w64-mingw32-gcc -O2 -o "$WORK/bin/exitcode.exe" "$ROOT/Tests/Smoke/exitcode.c"
x86_64-w64-mingw32-gcc -O2 -o "$WORK/bin/d3d11probe.exe" "$ROOT/Tests/Smoke/d3d11probe.c" -ld3d11 -luser32

if [ -n "${MACPROTON_TARBALL:-}" ]; then
  "$ROOT/.build/release/macproton" install-runtime --tool-dir "$TOOL" --tarball "$MACPROTON_TARBALL"
else
  "$ROOT/.build/release/macproton" install-runtime --tool-dir "$TOOL"
fi
if [ -n "${GPTK:-}" ]; then
  "$TOOL/bin/macproton" import-gptk --tool-dir "$TOOL" "$GPTK"
fi

fail=0
check() { # backend exe expected-exit [args...]
  backend=$1; exe=$2; want=$3; shift 3
  set +e
  STEAM_COMPAT_DATA_PATH="$WORK/compatdata/shared" SteamAppId=0 MACPROTON_GRAPHICS=$backend \
    "$TOOL/proton" waitforexitandrun "$WORK/bin/$exe" "$@"
  got=$?
  set -e
  if [ "$got" -eq "$want" ]; then echo "PASS $backend $exe"; else echo "FAIL $backend $exe: exit $got, want $want"; fail=1; fi
}

backends="dxmt dxvk"   # one shared prefix, in this order: switching backends is the case that broke
if [ -f "$TOOL/gptk.json" ]; then backends="d3dmetal $backends"; fi
for backend in $backends; do
  check "$backend" exitcode.exe 2 "a b" "c"
  check "$backend" d3d11probe.exe 0
done
tail -n 6 "$HOME/Library/Logs/MacProton/launcher.log"
exit $fail
