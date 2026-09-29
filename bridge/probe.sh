#!/bin/sh
# Developer end-to-end check of the Steam bridge (bridge spec §4.3). Needs Steam running and logged in,
# an installed runtime, and `make bridge`. Prints your SteamID and persona name: don't paste them anywhere public.
#   bridge/probe.sh <path to a game's steam_api64.dll>
# ACCOUNT=<id> sets MACNEUTRON_STEAM_ACCOUNT; APPID=<id> replaces 480; WINEDEBUG=+steamclient shows the bridge's log.
set -eu
[ $# -eq 1 ] || { echo "usage: bridge/probe.sh <steam_api64.dll>" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/build/bridge"
DLL="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
TOOL="${MACNEUTRON_TOOL:-$HOME/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron}"
WINE="$TOOL/Libraries/Wine/bin/wine"
LIB="$TOOL/Libraries/Wine/lib/wine"
WORK="${TMPDIR:-/tmp}/macneutron probe"
export WINEPREFIX="$WORK/pfx" WINEDEBUG="${WINEDEBUG:--all}" WINEMSYNC=1
export SteamAppId="${APPID:-480}" SteamGameId="${APPID:-480}"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS"
if [ -n "${ACCOUNT:-}" ]; then export MACNEUTRON_STEAM_ACCOUNT="$ACCOUNT"; else unset MACNEUTRON_STEAM_ACCOUNT || true; fi

mkdir -p "$WORK"   # Wine creates only the prefix folder itself
[ -d "$WINEPREFIX" ] || "$WINE" wineboot -u >/dev/null 2>&1
STEAM="$WINEPREFIX/drive_c/Program Files (x86)/Steam"
mkdir -p "$STEAM"
cp "$B/steam.exe" "$STEAM/steam.exe"
cp "$LIB/x86_64-windows/lsteamclient.dll" "$STEAM/steamclient64.dll"
[ ! -f "$LIB/i386-windows/lsteamclient.dll" ] || cp "$LIB/i386-windows/lsteamclient.dll" "$STEAM/steamclient.dll"
winpath() { printf 'Z:%s' "$1" | tr / '\\'; }
exec "$WINE" 'C:\Program Files (x86)\Steam\steam.exe' "$(winpath "$B/steamprobe.exe")" "$(winpath "$DLL")"
