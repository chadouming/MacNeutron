#!/bin/sh
# MacNeutron's release (arm64 release spec §6.3, §14), into build/release/<X.Y.Z>/: refuses development inputs, naming
# each; stages a stripped wine.app (bundle.sh --release) and runs R3 on it; notarizes and staples it (L6's notarized
# row on an installed copy); builds MacNeutron.app around it, checks its licences (R4), notarizes it (R2) and zips it;
# builds the source archive and checks it against the bundle's SOURCE (R5); writes SHA256SUMS and SIZES.txt and prints
# the tag and gh release commands. It never tags, pushes or uploads.
#   make release VERSION=X.Y.Z    make builds the CLI, steam.exe and wine.app first
#   release.sh X.Y.Z
#   release.sh --rehearse X.Y.Z   the same into build/release/rehearse-X.Y.Z/ (with a REHEARSAL file), without the
#                                 clean-tree and origin/main refusals and without notarization: nothing goes to Apple,
#                                 and no tag commands are printed
#   release.sh --self-test        each refusal on prepared bad inputs (gate R1)
# Needs MACNEUTRON_SIGN_IDENTITY and MACNEUTRON_PROVISIONING_PROFILE, the network (origin, the DXMT fork, Apple's
# timestamps) and, for a release, MACNEUTRON_NOTARY_PROFILE (default macneutron). R3 needs Steam running and logged in
# and a game's steam_api64.dll: MACNEUTRON_STEAM_API, by default SMITE 2's.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/wine-arm64/lib.sh"
. "$ROOT/release/lib.sh"  # after wine-arm64/lib.sh: its die says release:

# The refusals (§6.3 step 1). Each takes its inputs as arguments, says what is wrong on stderr and returns 1.
check_version() {  # check_version <repo> <version>: MAJOR.MINOR.PATCH, not yet a tag
  case $2 in
    *[!0-9.]* | .* | *. | *..*) f=1 ;;
    *) if [ "$(printf %s "$2" | tr -cd .)" = .. ]; then f=; else f=1; fi ;;
  esac
  [ -z "$f" ] || { echo "release: VERSION $2 is not MAJOR.MINOR.PATCH" >&2; return 1; }
  if git -C "$1" rev-parse -q --verify "refs/tags/v$2" > /dev/null; then
    echo "release: v$2 is already a tag" >&2
    return 1
  fi
}
check_readmes() {  # check_readmes <repo>: neither README keeps a Rosetta-era line (spec §7.3)
  r=0
  for f in README.md wine-arm64/README.md; do
    [ -f "$1/$f" ] || { echo "release: no $f" >&2; r=1; continue; }
    for s in "Rosetta 2" import-gptk "doesn't redistribute"; do
      if LC_ALL=C /usr/bin/grep -qF "$s" "$1/$f"; then echo "release: $f contains '$s'" >&2; r=1; fi
    done
  done
  return $r
}
check_clean() {  # check_clean <repo>
  s=$(git -C "$1" status --porcelain --untracked-files=normal)
  [ -n "$s" ] || return 0
  echo "release: the repository has uncommitted changes" >&2
  printf '%s\n' "$s" | head -n 10 >&2
  return 1
}
check_published() {  # check_published <repo>: HEAD is in origin/main, fetched now
  git -C "$1" fetch -q origin || { echo "release: can't fetch origin" >&2; return 1; }
  h=$(git -C "$1" rev-parse HEAD)
  git -C "$1" merge-base --is-ancestor "$h" origin/main 2> /dev/null \
    || { echo "release: HEAD $h is not in origin/main" >&2; return 1; }
}
check_trees() {  # check_trees: the four trees in build/wine-arm64-src are applied (the patches are the truth)
  r=0
  for t in wine fex dxmt lsteamclient; do
    m=$(tree_mode "$t")
    [ "$m" = applied ] || { echo "release: wine-arm64-src/$t is $m, not applied" >&2; r=1; }
  done
  return $r
}
check_dxmt() {  # check_dxmt <fork clone> <commit>: published on the fork's macneutron branch (LGPL)
  sh "$ROOT/dxmt/published.sh" "$1" "$2" \
    || { echo "release: DXMT_COMMIT $2 is not on the fork's macneutron branch" >&2; return 1; }
}
check_source() {  # check_source <SOURCE> <head>: the release bundle's SOURCE names applied trees and HEAD (§6.3 step 2)
  [ -f "$1" ] || { echo "release: no SOURCE at $1" >&2; return 1; }
  r=0
  for k in $(sed -n 's/^\([A-Z_]*_SERIES\)=dev$/\1/p' "$1"); do echo "release: SOURCE has $k=dev" >&2; r=1; done
  c=$(sed -n 's/^MACNEUTRON_COMMIT=//p' "$1")
  case $c in
    *+dirty) echo "release: SOURCE MACNEUTRON_COMMIT is +dirty" >&2; r=1 ;;
    "$2") ;;
    *) echo "release: SOURCE MACNEUTRON_COMMIT $c is not HEAD $2" >&2; r=1 ;;
  esac
  return $r
}
check_up_to_date() {  # make wine-arm64 has nothing to do: the bundle staged from these trees is current
  out=$(sh "$ROOT/wine-arm64/build.sh" 2>&1) && st=0 || st=$?
  if [ "$st" = 0 ] && printf '%s\n' "$out" | LC_ALL=C /usr/bin/grep -qx 'wine-arm64: up to date'; then return 0; fi
  printf '%s\n' "$out" | tail -n 5 >&2
  echo "release: make wine-arm64 didn't say 'wine-arm64: up to date' (exit $st): it built or failed" >&2
  return 1
}

# --self-test (gate R1): each refusal on its own input in a temporary clone; never build.sh, the real trees or GitHub.
self_test() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/release-self-test.XXXXXX")
  trap 'rm -rf "$T"' EXIT
  fail=0
  ok() { echo "ok   $1"; }
  bad() { echo "FAIL $1: $2"; fail=1; }
  refused() {  # refused <case> <message> <check> <args...>: the check fails, saying <message> on a line of its own
    c=$1 m=$2; shift 2
    if out=$( ("$@") 2>&1 ); then bad "$c" "not refused"; return 0; fi
    if printf '%s\n' "$out" | LC_ALL=C /usr/bin/grep -qxF "$m"; then ok "$c"; else bad "$c" "got [$out], want [$m]"; fi
  }
  passes() {  # passes <case> <check> <args...>: the check passes, silently
    c=$1; shift
    if out=$( ("$@") 2>&1 ) && [ -z "$out" ]; then ok "$c"; else bad "$c" "refused: [$out]"; fi
  }
  # The repository and its origin, both local: a clone, and a bare clone as its origin.
  git clone -q "$ROOT" "$T/repo"
  git clone -q --bare "$ROOT" "$T/origin.git"
  git -C "$T/repo" remote set-url origin "$T/origin.git"
  commit() { git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$2"; }

  # VERSION: refused first, exit 2, nothing else said.
  refused "a version that isn't MAJOR.MINOR.PATCH" "release: VERSION 0.0.1-rc is not MAJOR.MINOR.PATCH" \
    check_version "$T/repo" 0.0.1-rc
  git -C "$T/repo" tag v0.0.0
  refused "a version that is already a tag" "release: v0.0.0 is already a tag" check_version "$T/repo" 0.0.0
  passes "a new version" check_version "$T/repo" 0.0.1
  out=$(sh "$ROOT/release/release.sh" 0.0.1-rc 2>&1) && st=0 || st=$?
  if [ "$st:$out" = "2:release: VERSION 0.0.1-rc is not MAJOR.MINOR.PATCH" ]; then ok "a bad version exits 2 alone"
  else bad "a bad version exits 2 alone" "exit $st: [$out]"; fi

  # README strings left from the Rosetta era.
  passes "READMEs without the Rosetta-era strings" check_readmes "$T/repo"
  for s in "Rosetta 2" import-gptk "doesn't redistribute"; do
    echo "$s" >> "$T/repo/README.md"
    refused "a README naming '$s'" "release: README.md contains '$s'" check_readmes "$T/repo"
    git -C "$T/repo" checkout -q README.md
  done
  echo "doesn't redistribute" >> "$T/repo/wine-arm64/README.md"
  refused "wine-arm64's README naming 'doesn't redistribute'" \
    "release: wine-arm64/README.md contains 'doesn't redistribute'" check_readmes "$T/repo"
  git -C "$T/repo" checkout -q wine-arm64/README.md

  # A clean tree, and a HEAD that origin/main contains.
  passes "a clean tree" check_clean "$T/repo"
  echo stray > "$T/repo/stray"
  refused "a dirty tree" "release: the repository has uncommitted changes" check_clean "$T/repo"
  rm "$T/repo/stray"
  commit "$T/repo" unpublished
  refused "a HEAD not in origin/main" "release: HEAD $(git -C "$T/repo" rev-parse HEAD) is not in origin/main" \
    check_published "$T/repo"
  git -C "$T/repo" push -q -f origin HEAD:main
  passes "a HEAD in origin/main" check_published "$T/repo"

  # The trees: none built here, so each is named.
  no_build() { BUILD_DIR="$T/no-build"; check_trees; }  # run in refused's subshell
  refused "a tree that isn't applied" "release: wine-arm64-src/wine is pinned, not applied" no_build

  # The bundle's SOURCE.
  h=$(git -C "$T/repo" rev-parse HEAD) h1=$(git -C "$T/repo" rev-parse HEAD~1)
  printf 'MACNEUTRON_COMMIT=%s\nWINE_COMMIT=0\nWINE_SERIES=ab12\nFEX_SERIES=cd34\nFEX_SUBMODULE_range-v3=0\n' "$h" \
    > "$T/SOURCE"
  passes "a release SOURCE" check_source "$T/SOURCE" "$h"
  sed 's/^WINE_SERIES=.*/WINE_SERIES=dev/' "$T/SOURCE" > "$T/SOURCE.dev"
  refused "a dev series" "release: SOURCE has WINE_SERIES=dev" check_source "$T/SOURCE.dev" "$h"
  sed "s/^MACNEUTRON_COMMIT=.*/MACNEUTRON_COMMIT=$h+dirty/" "$T/SOURCE" > "$T/SOURCE.dirty"
  refused "a +dirty SOURCE" "release: SOURCE MACNEUTRON_COMMIT is +dirty" check_source "$T/SOURCE.dirty" "$h"
  sed "s/^MACNEUTRON_COMMIT=.*/MACNEUTRON_COMMIT=$h1/" "$T/SOURCE" > "$T/SOURCE.old"
  refused "a SOURCE from another commit" "release: SOURCE MACNEUTRON_COMMIT $h1 is not HEAD $h" \
    check_source "$T/SOURCE.old" "$h"

  # DXMT_COMMIT on the fork's macneutron branch (LGPL), with a local bare repository as the fork.
  git init -q --bare "$T/fork.git"
  git clone -q "$T/fork.git" "$T/dxmt" 2> /dev/null
  commit "$T/dxmt" pushed
  git -C "$T/dxmt" push -q origin HEAD:macneutron
  pushed=$(git -C "$T/dxmt" rev-parse HEAD)
  commit "$T/dxmt" local
  passes "a published DXMT commit" check_dxmt "$T/dxmt" "$pushed"
  refused "an unpublished DXMT commit" \
    "release: DXMT_COMMIT $(git -C "$T/dxmt" rev-parse HEAD) is not on the fork's macneutron branch" \
    check_dxmt "$T/dxmt" "$(git -C "$T/dxmt" rev-parse HEAD)"

  if [ $fail = 0 ]; then echo "PASS release self-test"; else echo "FAIL release self-test"; fi
  return $fail
}

# R3 (spec §9) on the release wine.app: smoke.sh's L5/L6 rows, then through a tool folder assembled from it the Steam
# bridge probe (redacted) and a DXMT draw. Its Wine is stopped on the way out, whatever happens.
stop_r3() {
  [ -d "$R3TOOL/wine.app" ] || return 0
  for p in "$R3C"/*/pfx; do
    [ ! -d "$p" ] || WINEPREFIX="$p" WINEMSYNC=1 "$R3TOOL/wine.app/Contents/Resources/bin/wineserver" -k 2> /dev/null \
      || true
  done
  pids=$(for f in "$R3TOOL/wine.app/Contents/MacOS/wine" "$R3TOOL/wine.app/Contents/Resources/bin/wineserver"; do
    lsof -t "$f" 2> /dev/null || true; done | sort -u)
  # shellcheck disable=SC2086  # pids is a list
  [ -z "$pids" ] || kill $pids 2> /dev/null || true
}
r3() {
  W="$OUT/r3" R3TOOL="$OUT/r3 tool" R3C="$OUT/r3 compat"
  mkdir -p "$W" "$R3C"
  trap stop_r3 EXIT
  MACNEUTRON_ARM64_APP="$OUT/wine.app" sh "$ROOT/Tests/Smoke/smoke.sh" > "$W/smoke.txt" 2>&1 && st=0 || st=$?
  cat "$W/smoke.txt"
  [ "$(head -n 1 "$W/smoke.txt")" = "info wine.app: $OUT/wine.app ($V)" ] || die "R3: smoke.sh didn't run on this bundle"
  if [ "$st" != 0 ] || LC_ALL=C /usr/bin/grep -q '^FAIL' "$W/smoke.txt"; then die "R3: smoke.sh failed (exit $st)"; fi
  echo "PASS R3 smoke"

  "$CLI" install --tool-dir "$R3TOOL" --wine-app "$OUT/wine.app" --steam-exe "$STEAM_EXE" > /dev/null \
    || die "R3: can't assemble $R3TOOL"
  pgrep -x steam_osx > /dev/null || die "R3: Steam isn't running: start it and log in"
  api="${MACNEUTRON_STEAM_API:-$HOME/Library/Application Support/Steam/steamapps/common/SMITE 2/Windows/Engine}"
  [ -n "${MACNEUTRON_STEAM_API:-}" ] || api="$api/Binaries/ThirdParty/Steamworks/Steamv157/Win64/steam_api64.dll"
  [ -f "$api" ] || die "R3: no steam_api64.dll at $api (set MACNEUTRON_STEAM_API)"
  # Redacted: no SteamID, account ID or persona name reaches the output or the record.
  out=$(PROBE_REDACT=1 STEAM_COMPAT_DATA_PATH="$R3C/probe" MACNEUTRON_TOOL_DIR="$R3TOOL" \
    sh "$ROOT/bridge/probe.sh" "$api" 2>&1) && st=0 || st=$?
  printf '%s\n' "$out" | tee "$W/probe.txt"
  has() { printf '%s\n' "$out" | LC_ALL=C /usr/bin/grep -qx "$1"; }
  n=$(printf '%s\n' "$out" | sed -n 's/^auth ticket: handle [0-9]*, \([0-9]*\) bytes$/\1/p' | head -n 1)
  has 'init: ok' && has 'steamid ok' && [ "${n:-0}" -gt 0 ] \
    || die "R3: the bridge probe through the launcher failed (exit $st; is Steam logged in?)"
  echo "PASS R3 probe: init ok, steamid ok, ticket $n bytes"

  "$(sh "$ROOT/dxmt/toolchain.sh")/x86_64-w64-mingw32-clang" -O2 -static -s -o "$W/present_loop.exe" \
    "$ROOT/presenter/tests/present_loop.c" -ld3d11 -ldxgi -luser32 -lgdi32 -ldxguid -luuid \
    || die "R3: can't build present_loop.exe"
  set -- env STEAM_COMPAT_DATA_PATH="$R3C/draw" SteamAppId=0 MACNEUTRON_GRAPHICS=dxmt MACNEUTRON_NO_STEAM_BRIDGE=1 \
    "$R3TOOL/bin/macneutron" launch
  "$@" getcompatpath "$W" > /dev/null 2>&1 || die "R3: the launcher didn't prepare $R3C/draw/pfx"  # untimed
  "$@" waitforexitandrun "$W/present_loop.exe" 1280 720 0 0 120 0 > "$W/draw.out" 2>&1 &
  pid=$!  # the launcher itself (env execs it), so the watchdog stops it
  # A watchdog that ends by itself within a second of the launcher, so nothing is left to kill.
  ( i=0; while [ $i -lt 120 ] && kill -0 "$pid" 2> /dev/null; do sleep 1; i=$((i + 1)); done
    kill "$pid" 2> /dev/null || true ) & dog=$!
  wait "$pid" || true
  wait "$dog" || true
  line=$(tr -d '\r' < "$W/draw.out" | LC_ALL=C /usr/bin/grep -m 1 'avg frame' || true)
  [ -n "$line" ] || die "R3: present_loop.exe on DXMT printed no 'avg frame' line; see $W/draw.out"
  echo "PASS R3 draw: $line"
  stop_r3
  trap - EXIT
}

# MacNeutron.app (§6.3 step 3, §7.1): the Swift binaries (thin arm64), wine.app copied whole with ditto (its signature,
# profile, entitlements and ticket stay), steam.exe and the licences; signed inside-out, never --deep, never re-signing
# wine.app, no entitlements. Then its licences (R4).
build_app() {
  A="$OUT/MacNeutron.app"
  rm -rf "$A"
  mkdir -p "$A/Contents/MacOS" "$A/Contents/Helpers" "$A/Contents/Resources/licenses"
  cp "$ROOT/App/Info.plist" "$A/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" -c "Set :CFBundleVersion $V" \
    "$A/Contents/Info.plist" || die "can't set the version in $A/Contents/Info.plist"
  m=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$A/Contents/Info.plist" 2> /dev/null || true)
  [ "$m" = 27.0 ] || die "App/Info.plist's LSMinimumSystemVersion is '${m:-missing}', not 27.0"
  cp "$ROOT/.build/release/MacNeutronApp" "$A/Contents/MacOS/MacNeutron"
  cp "$CLI" "$A/Contents/Helpers/macneutron"
  for f in MacOS/MacNeutron Helpers/macneutron; do
    a=$(lipo -archs "$A/Contents/$f")
    [ "$a" = arm64 ] || die "Contents/$f is '$a', not arm64"
    # No debug map: its OSO/SO entries name the build folder (signed below; the warning is that signature's loss).
    strip -S "$A/Contents/$f" 2> /dev/null || die "can't strip Contents/$f"
    n=$(nm -ap "$A/Contents/$f" | LC_ALL=C /usr/bin/grep -c ' OSO ' || true)
    [ "$n" = 0 ] || die "Contents/$f still has $n OSO entries after strip -S"
    ! LC_ALL=C /usr/bin/grep -aq /Users/ "$A/Contents/$f" || die "Contents/$f still names a path under /Users/"
  done
  ditto "$OUT/wine.app" "$A/Contents/Helpers/wine.app"
  cp "$STEAM_EXE" "$A/Contents/Resources/steam.exe"
  AL="$A/Contents/Resources/licenses"
  cp "$ROOT/LICENSE" "$AL/LICENSE"
  for f in LICENSE.TXT COPYING.MinGW-w64-runtime.txt; do
    cp "$OUT/wine.app/Contents/Resources/licenses/llvm-mingw/$f" "$AL/"
  done
  cat > "$AL/README" << 'EOF'
MacNeutron is under the MIT licence (LICENSE, beside this file).

steam.exe (Contents/Resources/steam.exe), MacNeutron's own Windows-side Steam stub, is built with llvm-mingw and links
its mingw-w64 runtime: llvm-mingw's licence is LICENSE.TXT and the runtime's notices COPYING.MinGW-w64-runtime.txt,
beside this file.

The runtime, Contents/Helpers/wine.app (Wine, FEX, DXMT, FreeType, gnutls, nettle, GMP, LLVM, lsteamclient and
MacNeutron's MetalFX presenter), carries every component's licence and the exact sources it is built from in
Contents/Helpers/wine.app/Contents/Resources/licenses/ (README there first; SOURCE names each commit).
EOF
  out=$(build_paths "$A")  # no build path ships (Ruling 20)
  [ -z "$out" ] || die "files naming the repository, build or home folder (the first ten): $(echo "$out" | tr '\n' ' ')"
  sign() { codesign -f -s "$MACNEUTRON_SIGN_IDENTITY" --options runtime --timestamp "$1" > /dev/null 2>&1 \
    || die "signing $1 failed"; }
  sign "$A/Contents/Helpers/macneutron"
  sign "$A"
  out=$(codesign --verify --strict --deep "$A" 2>&1) || die "codesign --verify --strict --deep $A: $out"
  cd1=$(codesign -dvvv "$OUT/wine.app" 2>&1 | sed -n 's/^CDHash=//p')
  cd2=$(codesign -dvvv "$A/Contents/Helpers/wine.app" 2>&1 | sed -n 's/^CDHash=//p')
  [ -n "$cd1" ] && [ "$cd1" = "$cd2" ] || die "the app's wine.app isn't the release wine.app ($cd2, not $cd1)"
  out=$(sh "$ROOT/wine-arm64/tests/licences_test.sh" --app "$A") || die "R4: $out"
  printf '%s\n' "$out"
  echo "PASS R4"
}

# The entry points: --self-test, or a version (released or rehearsed).
case "${1:-}" in
  --self-test) self_test; exit ;;
  --rehearse) mode=rehearse V=${2:-} ;;
  -*) V= ;;
  *) mode=release V=$1 ;;
esac
[ -n "$V" ] || { echo "release: usage: make release VERSION=X.Y.Z (or release.sh --rehearse X.Y.Z | --self-test)" >&2
  exit 2; }
check_version "$ROOT" "$V" || exit 2

# 1. Refusals: every failing one is named before stopping. Then make wine-arm64 must have nothing left to do.
failed=0
check_readmes "$ROOT" || failed=1
if [ $mode = release ]; then
  check_clean "$ROOT" || failed=1
  check_published "$ROOT" || failed=1
fi
check_trees || failed=1
check_dxmt "$ROOT/build/wine-arm64-src/dxmt" "$(. "$ROOT/dxmt/pins"; echo "$DXMT_COMMIT")" || failed=1
[ $failed = 0 ] || exit 1
check_up_to_date || exit 1
HEAD=$(git -C "$ROOT" rev-parse HEAD)
CLI="$ROOT/.build/release/macneutron" STEAM_EXE="$ROOT/build/bridge/arm64/steam.exe"
for f in "$CLI" "$ROOT/.build/release/MacNeutronApp" "$STEAM_EXE" "$ROOT/build/bridge/steamprobe.exe"; do
  [ -f "$f" ] || die "no $f: run make build bridge"
done
if [ $mode = release ]; then OUT="$ROOT/build/release/$V"; else OUT="$ROOT/build/release/rehearse-$V"; fi
rm -rf "$OUT"
mkdir -p "$OUT"
[ $mode = release ] || echo "Rehearsal of MacNeutron $V at $HEAD: not notarized, not for release." > "$OUT/REHEARSAL"

# 2. The release wine.app, its SOURCE, R3; then its notarization and L6's notarized row.
echo "release: bundling wine.app $V into $OUT" >&2
sh "$ROOT/wine-arm64/bundle.sh" --release --version "$V" --out "$OUT" || die "bundle.sh --release failed"
check_source "$OUT/wine.app/Contents/Resources/licenses/SOURCE" "$HEAD" || exit 1
r3
if [ $mode = release ]; then
  notarize_and_staple "$OUT/wine.app" "$OUT/notary-wine"
  "$CLI" install --tool-dir "$OUT/l6 tool" --wine-app "$OUT/wine.app" --steam-exe "$STEAM_EXE" > /dev/null \
    || die "L6: can't install the notarized wine.app"
  xcrun stapler validate "$OUT/l6 tool/wine.app" > /dev/null 2>&1 \
    || die "L6: stapler validate fails on the installed copy"
  accepted "$OUT/l6 tool/wine.app" || die "L6: Gatekeeper rejects the installed copy: $(spctl -a -vvv -t exec \
    "$OUT/l6 tool/wine.app" 2>&1 | head -n 2 | tr '\n' ' ')"
  echo "PASS L6 notarized copy installs and stays accepted"
fi

# 3-4. MacNeutron.app (R4), its notarization (R2) and its zip.
build_app
if [ $mode = release ]; then
  notarize_and_staple "$A" "$OUT/notary-app"
  accepted "$A" || die "R2: Gatekeeper rejects $A: $(spctl -a -vvv -t exec "$A" 2>&1 | head -n 2 | tr '\n' ' ')"
  echo "PASS R2 MacNeutron.app accepted"
fi
ZIP="MacNeutron-$V.zip"
ditto -c -k --keepParent "$A" "$OUT/$ZIP"

# 5. The source archive (R5).
TGZ="MacNeutron-$V-source.tar.gz"
sh "$ROOT/release/source-archive.sh" "$V" "$OUT" || die "source-archive.sh failed"
out=$(sh "$ROOT/release/verify-sources.sh" "$OUT/$TGZ" "$OUT/wine.app/Contents/Resources/licenses/SOURCE") && st=0 \
  || st=$?
printf '%s\n' "$out"
[ "$st" = 0 ] && [ "$(printf '%s\n' "$out" | tail -n 1)" = "PASS sources" ] || die "R5: the source archive fails"

# 6. Checksums and sizes; the commands that publish it, for the maintainer.
( cd "$OUT" && shasum -a 256 "$ZIP" "$TGZ" > SHA256SUMS )
for f in "$ZIP" "$TGZ"; do echo "$f: $(stat -f %z "$OUT/$f") bytes"; done >> "$OUT/SIZES.txt"
cat "$OUT/SIZES.txt" "$OUT/SHA256SUMS"
if [ $mode = release ]; then
  c=$(awk '$1 == "MacNeutron" { print $3 }' "$OUT/SOURCES.txt")
  echo "release: MacNeutron $V is ready in $OUT. To publish it:"
  echo "  git tag v$V $c"
  echo "  gh release create v$V --target $c --title 'MacNeutron $V' $OUT/$ZIP $OUT/$TGZ $OUT/SHA256SUMS"
else
  echo "release: rehearsal of $V done in $OUT (not notarized: nothing to publish)"
fi
