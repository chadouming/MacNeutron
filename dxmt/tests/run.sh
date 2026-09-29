#!/bin/sh
# Dev loop for the fork's D3D12 tests (check.sh runs them for real): rebuilds the fork incrementally, installs it
# into check.sh's "ours" runtime clone, and runs build/dxmt-tests/<test>.exe on our DXMT, then on D3DMetal.
#   sh dxmt/tests/run.sh <test> [args...]   (pass shader paths as Z:<absolute Mac path>)
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; SRC="$ROOT/build/dxmt-src"; WORK="${TMPDIR:-/tmp}/macneutron dxmt"
[ -x "$WORK/ours/bin/macneutron" ] || { echo "run.sh: run make dxmt-check once first (it creates $WORK/ours)"; exit 1; }
( PATH="$SRC/llvm-mingw/bin:$PATH"; ninja -C "$SRC/win64" > "$WORK/run-ninja.log" 2>&1 \
    && meson install -C "$SRC/win64" > "$WORK/run-install.log" 2>&1 ) \
  || { grep -E "error|Error" "$WORK/run-ninja.log" "$WORK/run-install.log" | head -20; exit 1; }
cp "$SRC"/win64-install/system32/*.dll "$SRC"/win64-install/x86_64-windows/*.dll "$ROOT/build/dxmt/x86_64-windows/"
cp "$SRC"/win64-install/x86_64-unix/* "$ROOT/build/dxmt/x86_64-unix/"
"$ROOT/.build/release/macneutron" install-dxmt --tool-dir "$WORK/ours" "$ROOT/build/dxmt" > /dev/null
make -C "$ROOT" -s dxmt-tests > /dev/null
test=$1; shift
for backend in dxmt d3dmetal; do
  env STEAM_COMPAT_DATA_PATH="$WORK/compat/ours" SteamAppId=0 MACNEUTRON_GRAPHICS=$backend \
      MACNEUTRON_NO_STEAM_BRIDGE=1 MACNEUTRON_NO_METALFX=1 ${RUN_ENV:-} \
      perl -e 'alarm 120; exec @ARGV' "$WORK/ours/bin/macneutron" launch waitforexitandrun \
      "$ROOT/build/dxmt-tests/$test.exe" "$@" 2>&1 | tr -d '\r' \
    | grep -E '^[a-z][a-z0-9-]* ' | grep -vE '^(msync|err|warn|fixme):' | sed "s/^/$backend: /" || true
done
