#!/bin/sh
# licences_check.sh [wine.app]: the shape of a future wine-arm64/tests/licences_test.sh (or bundle.sh step 3).
# Fails, naming each gap, unless every notice the shipped binaries need is in the bundle. Read-only.
# ponytail: a flat path list, no manifest format; add one when a second bundle needs the same list.
set -u
ROOT=/Users/chad/Documents/MacProton
APP=${1:-$ROOT/build/wine-arm64/wine.app}
R="$APP/Contents/Resources"
L="$R/licenses"
SRC=$ROOT/build/wine-arm64-src
bad=0
miss() { echo "MISSING $*"; bad=1; }

# 1. Files copied verbatim from the source trees (bundle.sh's cp list).
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

# 2. Notices that live only in source headers: one committed NOTICES.md must name each holder.
for h in "Regents of the University of California" "VIXL authors" "Rich Felker" "Arm Limited" "Will Faust" \
         "Microsoft Corporation" "Alexander Bessonov" "Unicode, Inc." "Henry Spencer"
do grep -q "$h" "$L/NOTICES.md" 2> /dev/null || miss "NOTICES.md entry for $h"; done

# 3. Drift: every FEX external the build compiled has a licence above (vixl, zydis, tracy... must stay out).
for d in "$SRC"/fex-ec/External/*/; do
  case $(basename "$d") in SoftFloat-3e|cephes|fmt|range-v3|rpmalloc|tiny-json|unordered_dense|xxhash) ;;
    *) miss "a licence decision for FEX External/$(basename "$d")" ;; esac
done

# 4. Sub-project 3 additions, once they are in the bundle (a dylib present without its licence is a failure).
has() { ls "$R"/lib/wine/aarch64-unix/"$1" > /dev/null 2>&1; }
has 'libfreetype*' && { for f in LICENSE.TXT FTL.TXT; do [ -s "$L/freetype/$f" ] || miss "freetype/$f"; done; }
has 'libgnutls*' && { [ -s "$L/gnutls/COPYING.LESSERv2" ] || miss gnutls/COPYING.LESSERv2; }
has 'libnettle*' && { for f in COPYING.LESSERv3 COPYINGv3; do [ -s "$L/nettle/$f" ] || miss "nettle/$f"; done; }
has 'libgmp*' && { for f in COPYING.LESSERv3 COPYINGv3; do [ -s "$L/gmp/$f" ] || miss "gmp/$f"; done; }
has 'lsteamclient.so' && { [ -s "$L/lsteamclient/LICENSE" ] || miss lsteamclient/LICENSE; }
has 'libfreetype*' && { grep -q "The FreeType Project" "$L/README" 2> /dev/null || miss "FreeType credit line in README"; }

# 5. Source correspondence: SOURCE names the exact inputs.
for k in WINE_COMMIT FEX_COMMIT DXMT_COMMIT MACNEUTRON_COMMIT LLVM_TAG LLVM_MINGW_SHA256; do
  grep -q "^$k=" "$L/SOURCE" 2> /dev/null || miss "SOURCE line $k="
done

[ $bad = 0 ] && echo "PASS licences_check: $APP" || { echo "FAIL licences_check: $APP"; exit 1; }
