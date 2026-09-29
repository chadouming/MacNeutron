#!/bin/sh
# Runs steam.exe under the installed MacNeutron runtime: real Wine, no Steam needed (bridge spec §9).
# Needs `make bridge` and an installed runtime; MACNEUTRON_TOOL overrides the default tool folder.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/build/bridge"
TOOL="${MACNEUTRON_TOOL:-$HOME/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron}"
WINE="$TOOL/Libraries/Wine/bin/wine"
WORK="${TMPDIR:-/tmp}/macneutron bridge ü"   # a space and a non-ASCII letter on purpose
export WINEPREFIX="$WORK/pfx" WINEDEBUG=-all WINEMSYNC=1

[ -x "$WINE" ] || { echo "check: no runtime at $TOOL" >&2; exit 1; }
mkdir -p "$WORK"   # Wine creates only the prefix folder itself
[ -d "$WINEPREFIX" ] || "$WINE" wineboot -u >/dev/null 2>&1
STEAM="$WINEPREFIX/drive_c/Program Files (x86)/Steam"
mkdir -p "$STEAM" "$WORK/game dir"
cp "$B/steam.exe" "$STEAM/steam.exe"
cp "$B/tests/helper.exe" "$WORK/game dir/hélper.exe"
winpath() { printf 'Z:%s' "$1" | tr / '\\'; }
HELPER="$(winpath "$WORK/game dir/hélper.exe")"
STEAMEXE='C:\Program Files (x86)\Steam\steam.exe'

steam() { "$WINE" "$STEAMEXE" "$HELPER" "$@" 2>/dev/null | tr -d '\r'; }
fail=0
expect() { # name got want
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2], want [$3]"; fail=1; fi
}

set +e; "$WINE" "$STEAMEXE" "$HELPER" exit 7 >/dev/null 2>&1; got=$?; set -e
expect "exit code passes through" "$got" 7
expect "arguments arrive unchanged" "$(steam args 'a b' '--name="Player One"' '')" '[a b][--name="Player One"][]'
expect "registry names a live Steam" "$(MACNEUTRON_STEAM_ACCOUNT=12345 steam steam)" \
  'alive=1 user=12345 client64=C:\Program Files (x86)\Steam\steamclient64.dll'
rm -f "$WORK/late.txt"
steam spawn "$(winpath "$WORK/late.txt")" >/dev/null
expect "launcher-style child still sees Steam" "$(tr -d '\r' < "$WORK/late.txt" 2>/dev/null || true)" "alive=1"
expect "pid cleared afterwards" "$("$WINE" "$HELPER" pid 2>/dev/null | tr -d '\r')" 0
set +e; "$WINE" "$STEAMEXE" 'C:\missing.exe' >/dev/null 2>&1; got=$?; set -e
expect "missing program exits 1" "$got" 1
expect "launchers may start children outside the job" "$(steam breakaway)" "breakaway ok"

# A second steam.exe in the prefix (a failed one, then a short one) must not end the first one's Steam.
rm -f "$WORK/late.txt"
steam spawn "$(winpath "$WORK/late.txt")" >/dev/null &
sleep 0.5
"$WINE" "$STEAMEXE" 'C:\missing.exe' >/dev/null 2>&1 || true
steam exit 0 >/dev/null
wait
expect "a second steam.exe leaves the first one's Steam running" "$(tr -d '\r' < "$WORK/late.txt" 2>/dev/null || true)" "alive=1"

exit $fail
