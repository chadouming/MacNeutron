#!/bin/bash
# R0b: can Steam launch a thin arm64 tool? Usage: r0b.sh setup | results | remove
# Test seam: R0B_STEAM_ROOT replaces ~/Library/Application Support/Steam (and skips the Steam-running check).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=${R0B_STEAM_ROOT:-$HOME/Library/Application Support/Steam}
macos="$root/Steam.AppBundle/Steam/Contents/MacOS"
out="$(cd "$here/.." && pwd)/build/r0b"
tools="$macos/compatibilitytools.d"

steam_running() { [ -z "${R0B_STEAM_ROOT:-}" ] && pgrep -x steam_osx >/dev/null; }

make_tool() { # name display from probe-name verb
    local d="$out/$1"
    mkdir -p "$d/bin"
    cat > "$d/compatibilitytool.vdf" <<VDF
"compatibilitytools"
{
  "compat_tools"
  {
    "$1"
    {
      "install_path" "."
      "display_name" "$2"
      "from_oslist"  "$3"
      "to_oslist"    "linux"
    }
  }
}
VDF
    printf '"manifest"\n{\n  "version" "2"\n  "commandline" "/bin/%s %s %%verb%%"\n}\n' "$4" "$5" > "$d/toolmanifest.vdf"
    cp "$out/probe" "$d/bin/$4"
}

case "${1:-}" in
setup)
    LC_ALL=C /usr/bin/grep -qx '@sSteamCmdForcePlatformType linux' "$macos/steam_dev.cfg" 2>/dev/null \
        || { echo "refusing: Steam is not in Linux mode (steam_dev.cfg lacks '@sSteamCmdForcePlatformType linux')" >&2; exit 1; }
    steam_running && { echo "refusing: Steam is running, quit it first" >&2; exit 1; }
    rm -rf "$out"; mkdir -p "$out"
    clang -arch arm64 -mmacosx-version-min=27.0 -o "$out/probe" "$here/r0b-probe.c"
    [ "$(lipo -archs "$out/probe")" = arm64 ] || { echo "probe is not thin arm64" >&2; exit 1; }
    make_tool r0b-probe "R0b probe" windows r0b-probe launch
    make_tool r0b-probe-native "R0b probe native" macos r0b-probe-native passthrough
    rm "$out/probe"
    mkdir -p "$tools"
    for t in r0b-probe r0b-probe-native; do ln -sfn "$out/$t" "$tools/$t"; done
    echo "set up r0b-probe and r0b-probe-native; start Steam and pick them in Properties > Compatibility"
    ;;
results)
    for t in r0b-probe r0b-probe-native; do
        echo "== $t"; cat "$out/$t/bin/r0b.log" 2>/dev/null || echo "(no r0b.log)"
    done
    ;;
remove)
    steam_running && { echo "refusing: Steam is running, quit it first" >&2; exit 1; }
    if LC_ALL=C /usr/bin/grep -q '"r0b-probe' "$root/config/config.vdf" 2>/dev/null; then
        echo "kept everything: Steam's config.vdf still names r0b-probe. Set those games back to their previous tool (Steam running), quit Steam, rerun remove." >&2
        exit 1
    fi
    rm -f "$tools/r0b-probe" "$tools/r0b-probe-native"
    rm -rf "$out"
    echo removed
    ;;
*) echo "usage: r0b.sh setup|results|remove" >&2; exit 2 ;;
esac
