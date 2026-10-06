# Shared by wine-arm64/build.sh, bundle.sh, export.sh, tests and the release scripts (sourced). Messages go to stderr.
die() { echo "wine-arm64: $*" >&2; exit 1; }

# Tools the build needs, collected so one run names every missing one (die_if_missing); never installed here.
missing=""
need_tool() {  # need_tool <command> <brew formula> [keg]
  # "keg": the formula is keg-only, so its bin goes first on PATH and only that one counts (macOS ships bison 2.3).
  if [ "${3:-}" = keg ]; then
    keg=$(brew --prefix "$2" 2> /dev/null) || keg=
    if [ -n "$keg" ] && [ -x "$keg/bin/$1" ]; then PATH="$keg/bin:$PATH"; return 0; fi
  elif command -v "$1" > /dev/null 2>&1; then
    return 0
  fi
  missing="$missing, $1 (brew install $2)"
}
die_if_missing() { [ -z "$missing" ] || die "missing tools: ${missing#, }"; }

# What a source tree is: pinned (no tree yet: fetch and patch it), applied (HEAD is the commit recorded in the
# applied file, nothing else changed: the patches are the truth), development (anything else, including a stash, a
# second branch or a second worktree: build it as it is) or, when a series file and the current series hash are given,
# reapply (an applied tree that was patched with another series: it holds no work of its own, so build.sh deletes it
# and starts over).
build_mode() {  # build_mode <src-dir> <applied-file> [<series-file> <series>]
  [ -d "$1" ] || { echo pinned; return 0; }
  if [ -n "$(git -C "$1" status --porcelain)" ] || [ "$(git -C "$1" rev-parse HEAD)" != "$(cat "$2" 2> /dev/null)" ] \
    || [ -n "$(git -C "$1" stash list)" ] || [ -n "$(git -C "$1" for-each-ref refs/heads | sed -n 2p)" ] \
    || [ -n "$(git -C "$1" worktree list | sed -n 2p)" ]; then
    echo development
  elif [ $# -ge 4 ] && [ "$(cat "$3" 2> /dev/null)" != "$4" ]; then
    echo reapply
  else
    echo applied
  fi
}

# SHA-256 over the files' contents in order, then the signing identity (a different identity is a different build).
stamp_of() {  # stamp_of <file>...
  for f in "$@"; do [ -f "$f" ] || die "no such build input: $f"; done
  { cat "$@"; printf '%s' "${MACNEUTRON_SIGN_IDENTITY:-}"; } | shasum -a 256 | cut -d ' ' -f 1
}

# What a tree has to be patched with: the pins and the patches, whatever the signing identity.
series_of() {  # series_of <file>...
  ( MACNEUTRON_SIGN_IDENTITY=; stamp_of "$@" )
}

# lsteamclient's series (ship-base spec §7): deps.pins' LSTEAMCLIENT_ lines alone (a tarball pin is no input of that
# tree) and its patches.
lsteamclient_series() {  # lsteamclient_series <deps.pins> <patch>...
  _lsc_pins=$1; shift
  for _lsc_f in "$_lsc_pins" "$@"; do [ -f "$_lsc_f" ] || die "no such build input: $_lsc_f"; done
  { LC_ALL=C /usr/bin/grep -E '^LSTEAMCLIENT_' "$_lsc_pins"; cat "$@"; } | shasum -a 256 | cut -d ' ' -f 1
}

# The series each tree is patched with, as build.sh patches it, and the tree's build_mode against it (build.sh,
# bundle.sh --release and release.sh agree through these). The caller sets ROOT; BUILD_DIR replaces build/.
tree_series() {  # tree_series <wine|fex|dxmt|lsteamclient>
  case $1 in
    wine|fex) series_of "$ROOT/wine-arm64/pins" "$ROOT/wine-arm64/patches/$1"/*.patch ;;
    dxmt) series_of "$ROOT/dxmt/pins" "$ROOT/wine-arm64/patches/dxmt"/*.patch ;;
    lsteamclient) lsteamclient_series "$ROOT/wine-arm64/deps.pins" "$ROOT/wine-arm64/patches/lsteamclient"/*.patch ;;
    *) die "no tree $1" ;;
  esac
}
tree_mode() {  # tree_mode <tree>
  _tm_s="${BUILD_DIR:-$ROOT/build}/wine-arm64-src"
  build_mode "$_tm_s/$1" "$_tm_s/$1.applied" "$_tm_s/$1.series" "$(tree_series "$1")"
}

# A bundle's licenses/SOURCE (ship-base spec §4, arm64 release spec §14): the inputs it is built from, each tree's
# series (dev unless the tree is applied), the submodules and tarballs. build.sh writes the development one, naming
# <mac>; bundle.sh --release writes the release bundle's own, naming HEAD.
write_source() {  # write_source <out> <mac>
  (
    . "$ROOT/wine-arm64/pins"; . "$ROOT/dxmt/pins"; . "$ROOT/wine-arm64/deps.pins"
    S="${BUILD_DIR:-$ROOT/build}/wine-arm64-src"
    series() { if [ "$(tree_mode "$1")" = applied ]; then tree_series "$1"; else echo dev; fi; }
    echo "MACNEUTRON_COMMIT=$2"
    echo "WINE_COMMIT=$WINE_COMMIT"
    echo "WINE_SERIES=$(series wine)"
    echo "FEX_COMMIT=$FEX_COMMIT"
    echo "FEX_SERIES=$(series fex)"
    # " <sha> <path> (<describe>)", the first character "+" or "-" when the checkout differs from FEX's record.
    git -C "$S/fex" submodule status | awk '{ c = $1; sub(/^[-+U]/, "", c); n = $2; sub(/.*\//, "", n) }
      n ~ /^(fmt|range-v3|rpmalloc|unordered_dense|xxhash|cpp-optparse)$/ { print "FEX_SUBMODULE_" n "=" c }'
    echo "DXMT_COMMIT=$DXMT_COMMIT"
    echo "DXMT_SERIES=$(series dxmt)"
    git -C "$S/dxmt" submodule status | awk '{ c = $1; sub(/^[-+U]/, "", c); n = $2; sub(/.*\//, "", n)
      print "DXMT_SUBMODULE_" n "=" c }'  # external/nvapi, include/native/directx
    echo "LLVM_TAG=$LLVM_TAG"
    echo "LLVM_MINGW_SHA256=$LLVM_MINGW_SHA256"
    echo "LSTEAMCLIENT_COMMIT=$LSTEAMCLIENT_COMMIT"
    echo "LSTEAMCLIENT_SERIES=$(series lsteamclient)"
    deps_pins  # <NAME>_URL, <NAME>_SHA256
  ) > "$1"
}

# The FreeType, gnutls, nettle and GMP tarballs' pins (<NAME>_URL, <NAME>_SHA256): build.sh's deps input and SOURCE's.
deps_pins() { LC_ALL=C /usr/bin/grep -E '^(FREETYPE|GNUTLS|NETTLE|GMP)_' "$ROOT/wine-arm64/deps.pins"; }

# A release ships no build path (arm64 release Ruling 20): the files under <dir> that contain, as bytes, the repository's
# path, the build folder's (BUILD_DIR can move it outside the repository) or the home folder's. The first ten, relative
# to <dir>. The caller sets ROOT.
build_paths() {  # build_paths <dir>; fails closed (no HOME, or grep can't read <dir>)
  [ -n "${HOME:-}" ] || die "HOME is not set"
  _bp_st=0
  _bp_out=$(LC_ALL=C /usr/bin/grep -rlaF -e "$ROOT" -e "${BUILD_DIR:-$ROOT/build}" -e "$HOME/" "$1") || _bp_st=$?
  [ "$_bp_st" -le 1 ] || die "grep failed ($_bp_st) on $1"
  [ -z "$_bp_out" ] || printf '%s\n' "$_bp_out" | head -n 10 | while IFS= read -r _bp; do echo "${_bp#"$1"/}"; done
}

# The App ID the entitled loader is signed for; a provisioning profile has to be for it (spec §7.2).
APP_ID=49QMZXLR8S.net.authspot.macneutron.wine

# A decoded provisioning profile (security cms -D) grants this App ID, the cross-architecture entitlement, and has not
# expired. Messages name what is wrong; the first problem found stops it.
check_profile_plist() {  # check_profile_plist <decoded-plist>
  pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2> /dev/null; }
  id=$(pb Entitlements:com.apple.application-identifier "$1") || id="(no application identifier)"
  [ "$id" = "$APP_ID" ] || die "profile is for $id, not $APP_ID"
  [ "$(pb Entitlements:com.apple.developer.cross-architecture-support "$1" || true)" = true ] \
    || die "profile lacks com.apple.developer.cross-architecture-support"
  # PlistBuddy prints the date in local time ("Tue Sep 27 22:29:58 EST 2044"): off by hours at worst, fine for expiry.
  # Always in English, so date reads it in English too: LC_ALL=C (under fr_CA the month and day names don't parse).
  exp=$(pb ExpirationDate "$1") || die "profile has no ExpirationDate"
  at=$(LC_ALL=C date -j -f '%a %b %d %T %Z %Y' "$exp" +%s 2> /dev/null) || die "can't read the profile's ExpirationDate: $exp"
  [ "$at" -gt "$(date +%s)" ] || die "profile expired on $exp"
}

# The signing variables are set and name something usable: build.sh checks this before fetching or building (a missing
# variable costs seconds, not a build), bundle.sh before assembling. There is no ad-hoc mode: an unentitled loader can't boot.
check_signing() {
  [ -n "${MACNEUTRON_SIGN_IDENTITY:-}" ] || die "set MACNEUTRON_SIGN_IDENTITY"
  [ -n "${MACNEUTRON_PROVISIONING_PROFILE:-}" ] || die "set MACNEUTRON_PROVISIONING_PROFILE"
  plist=$(mktemp)
  security cms -D -i "$MACNEUTRON_PROVISIONING_PROFILE" > "$plist" 2> /dev/null \
    || { rm -f "$plist"; die "$MACNEUTRON_PROVISIONING_PROFILE is not a provisioning profile"; }
  ( check_profile_plist "$plist" ) || { rm -f "$plist"; exit 1; }  # check_profile_plist already said what is wrong
  rm -f "$plist"
}

# The key of DXMT's shader translator (arm64 release Ruling 46): DXMT's translation cache (ShaderCacheVersion, DXMT
# patch 0003) and the launcher's replay stamp (DXMT/translator) follow it, not DXMT's git version, which every re-fetch
# changes (git am makes new commits) and an uncommitted edit doesn't. It hashes what changes translated output, as the
# working tree has it (patched, committed or not, untracked files too): airconv (src/airconv, its .metal helpers and
# meson.build files), the DXBC parser it builds with, the headers and the top-level meson files (compile flags), d3d11's
# compile arguments (src/d3d11/d3d11_shader.cpp: its cache entries key on the variant's fields, not on the argument
# chain built from them, unlike d3d12's) and the PE side of the airconv calls (src/winemetal/airconv_thunks.[ch]; the
# unix side's 64-bit thunks pass the pointers through, and winemetal_unix.c is mostly not the translator), the meson
# buildtype, LLVM (the pin and dxmt/llvm.sh's recipe), the compilers (Apple clang for airconv, metal for its
# helpers, through tools/xcrun-metal.sh). Relative paths only: the same tree anywhere has the same key. The caller sets
# ROOT and LLVM_TAG (dxmt/pins).
translator_key() {  # translator_key <dxmt-tree> <buildtype>
  _tk_l="src/airconv libs/DXBCParser include meson.build meson.options src/d3d11/d3d11_shader.cpp
    src/winemetal/airconv_thunks.c src/winemetal/airconv_thunks.h"
  for _tk_p in $_tk_l; do
    [ -e "$1/$_tk_p" ] || die "no $_tk_p in $1"
  done
  {
    echo "macneutron translator 1"
    ( cd "$1" && find $_tk_l -name .git -prune -o -type f \
      ! -name .DS_Store -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 )
    echo "buildtype $2"
    echo "llvm $LLVM_TAG"; cat "$ROOT/dxmt/llvm.sh" "$ROOT/wine-arm64/tools/xcrun-metal.sh"
    c++ --version | head -1
    xcrun -sdk macosx metal --version | head -1  # the rest names the toolchain's mount point
  } | shasum -a 256 | cut -d ' ' -f 1
}
