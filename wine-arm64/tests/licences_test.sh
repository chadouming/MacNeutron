#!/bin/sh
# licences_test.sh [--self-test] <wine.app>: every notice the shipped binaries need is in the bundle (ship-base spec §4).
# Prints MISSING <what> per gap, then PASS or FAIL. Read-only. BUILD_DIR replaces build/ (FEX's External list).
# --self-test proves it red on copies in $TMPDIR: one licence file deleted, one extra FEX external.
# ponytail: a flat path list, no manifest format; add one when a second bundle needs the same list.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
g() { LC_ALL=C /usr/bin/grep "$@"; }

check() {  # check <wine.app> <build dir>
  R="$1/Contents/Resources"
  L="$R/licenses"
  bad=0
  miss() { echo "MISSING $*"; bad=1; }
  key() { g -q "^$1=" "$L/SOURCE" 2> /dev/null || miss "SOURCE line $1="; }
  has() { ls "$R"/lib/wine/aarch64-unix/$1 > /dev/null 2>&1; }  # unquoted: $1 is a glob

  # 1. Files copied verbatim from the source trees (bundle.sh's put list).
  for f in \
    DXMT/COPYING.LIB DXMT/LICENSE DXMT/LICENSE.OLD \
    licenses/README licenses/SOURCE licenses/NOTICES.md \
    licenses/wine/LICENSE licenses/wine/COPYING.LIB licenses/wine/AUTHORS licenses/wine/NOTICES.md \
    licenses/wine/gsm-COPYRIGHT licenses/wine/faudio-LICENSE \
    licenses/fex/LICENSE \
    licenses/fex/fmt-LICENSE licenses/fex/xxhash-LICENSE licenses/fex/tiny-json-LICENSE \
    licenses/fex/cpp-optparse-LICENSE licenses/fex/unordered_dense-LICENSE licenses/fex/rpmalloc-LICENSE \
    licenses/fex/range-v3-LICENSE.txt licenses/fex/cephes-LICENSE \
    licenses/llvm/LICENSE.TXT licenses/llvm/COPYRIGHT.regex \
    licenses/llvm-mingw/LICENSE.TXT licenses/llvm-mingw/COPYING.MinGW-w64-runtime.txt
  do [ -s "$R/$f" ] || miss "$f"; done

  # 2. Notices that live only in source headers: the committed NOTICES.md names each holder.
  for h in "Regents of the University of California" "VIXL authors" "Rich Felker" "Arm Limited" "Will Faust" \
           "Microsoft Corporation" "Alexander Bessonov" "Unicode, Inc." "Henry Spencer" "Zebediah Figura" \
           "Marc-Aurel Zent"
  do g -qF "$h" "$L/NOTICES.md" 2> /dev/null || miss "NOTICES.md entry for $h"; done

  # 3. Drift: every FEX external the build compiled has a licence above (vixl, zydis, tracy... must stay out).
  for d in "$2"/wine-arm64-src/fex-ec/External/*/; do
    [ -d "$d" ] || { miss "FEX's External folder in $2/wine-arm64-src/fex-ec"; continue; }
    case $(basename "$d") in SoftFloat-3e|cephes|fmt|range-v3|rpmalloc|tiny-json|unordered_dense|xxhash) ;;
      *) miss "a licence decision for FEX External/$(basename "$d")" ;; esac
  done

  # 4. Sub-project 3's libraries, once they are in the bundle (a library present without its licence is a failure).
  #    nettle and gmp are folded into libgnutls: their texts come with it.
  if has 'libfreetype*'; then
    for f in LICENSE.TXT FTL.TXT; do [ -s "$L/freetype/$f" ] || miss "freetype/$f"; done
    g -qF "The FreeType Project" "$L/README" 2> /dev/null || miss "FreeType credit line in README"
  fi
  if has 'libgnutls*'; then
    for f in gnutls/COPYING.LESSERv2 gnutls/COPYING.LESSERv3 gnutls/COPYINGv3 nettle/COPYING.LESSERv3 nettle/COPYINGv3 \
             gmp/COPYING.LESSERv3 gmp/COPYINGv3
    do [ -s "$L/$f" ] || miss "$f"; done
  fi
  if has 'libfreetype*' || has 'libgnutls*'; then
    for n in FREETYPE GNUTLS NETTLE GMP; do key "${n}_URL"; key "${n}_SHA256"; done
  fi
  if has lsteamclient.so; then
    [ -s "$L/lsteamclient/LICENSE" ] || miss lsteamclient/LICENSE
    key LSTEAMCLIENT_COMMIT; key LSTEAMCLIENT_SERIES
  fi

  # 5. Source correspondence: SOURCE names the exact inputs.
  for k in MACNEUTRON_COMMIT WINE_COMMIT WINE_SERIES FEX_COMMIT FEX_SERIES FEX_SUBMODULE_fmt FEX_SUBMODULE_range-v3 \
           FEX_SUBMODULE_rpmalloc FEX_SUBMODULE_unordered_dense FEX_SUBMODULE_xxhash FEX_SUBMODULE_cpp-optparse \
           DXMT_COMMIT DXMT_SERIES LLVM_TAG LLVM_MINGW_SHA256
  do key "$k"; done

  if [ $bad = 0 ]; then echo "PASS licences_test"; else echo "FAIL licences_test"; return 1; fi
}

B="${BUILD_DIR:-$ROOT/build}"
if [ "${1:-}" != --self-test ]; then
  check "${1:?usage: licences_test.sh [--self-test] <wine.app>}" "$B"
  exit
fi

APP="${2:?usage: licences_test.sh --self-test <wine.app>}"
T="$(mktemp -d "${TMPDIR:-/tmp}/licences_test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL licences_test self-test: $*"; exit 1; }
# red <what> <MISSING line>: the copies fail, naming the gap.
red() {
  out=$(check "$T/wine.app" "$T/b") && fail "$1 still passes"
  case "$out" in *"MISSING $2"*) ;; *) fail "$1 does not say MISSING $2: $out" ;; esac
}
cp -cR "$APP" "$T/wine.app" || fail "can't copy $APP"
mkdir -p "$T/b/wine-arm64-src/fex-ec"
cp -cR "$B/wine-arm64-src/fex-ec/External" "$T/b/wine-arm64-src/fex-ec/" || fail "can't copy FEX's External folder"
out=$(check "$T/wine.app" "$T/b") || fail "the unchanged copies fail: $out"
rm "$T/wine.app/Contents/Resources/licenses/fex/xxhash-LICENSE"
red "a copy without fex/xxhash-LICENSE" licenses/fex/xxhash-LICENSE
cp -c "$APP/Contents/Resources/licenses/fex/xxhash-LICENSE" "$T/wine.app/Contents/Resources/licenses/fex/"
mkdir "$T/b/wine-arm64-src/fex-ec/External/vixl"
red "an extra External/vixl" "a licence decision for FEX External/vixl"
echo "PASS licences_test self-test"
