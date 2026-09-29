#!/bin/sh
# Real-Wine smoke test (spec section 7). Not run in CI: GitHub's macOS runners are unreliable for GPU work.
# Needs: network on the first run for the runtime (461 MB) and the pinned llvm-mingw (dxmt/toolchain.sh, 118 MB), then cached.
# Optional: MACNEUTRON_TARBALL=<Libraries.tar.gz> skips the download; GPTK=<mounted GPTK volume> adds d3dmetal.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/macneutron smoke"   # a space on purpose: Steam's paths have one
TOOL="$WORK/tool"
rm -rf "$WORK/compatdata"
mkdir -p "$WORK/bin"

"$(sh "$ROOT/dxmt/toolchain.sh")/x86_64-w64-mingw32-clang" -O2 -o "$WORK/bin/exitcode.exe" "$ROOT/Tests/Smoke/exitcode.c"
x86_64-w64-mingw32-gcc -O2 -o "$WORK/bin/d3d11probe.exe" "$ROOT/Tests/Smoke/d3d11probe.c" -ld3d11 -luser32

if [ -n "${MACNEUTRON_TARBALL:-}" ]; then
  "$ROOT/.build/release/macneutron" install-runtime --tool-dir "$TOOL" --tarball "$MACNEUTRON_TARBALL"
else
  "$ROOT/.build/release/macneutron" install-runtime --tool-dir "$TOOL"
fi
if [ -n "${GPTK:-}" ]; then
  "$TOOL/bin/macneutron" import-gptk --tool-dir "$TOOL" "$GPTK"
fi

fail=0
check() { # backend exe expected-exit [args...]
  backend=$1; exe=$2; want=$3; shift 3
  set +e
  STEAM_COMPAT_DATA_PATH="$WORK/compatdata/shared" SteamAppId=0 MACNEUTRON_GRAPHICS=$backend \
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
tail -n 6 "$HOME/Library/Logs/MacNeutron/launcher.log"
exit $fail
