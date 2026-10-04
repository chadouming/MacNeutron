#!/bin/sh
# Assembles and signs build/wine-arm64/wine.app from the built Wine tree (native arm64 spec §4, §7.2). The bundle is
# built as wine.app.tmp and moved to wine.app only after every assertion holds, so a failure stages nothing.
# Needs MACNEUTRON_SIGN_IDENTITY and MACNEUTRON_PROVISIONING_PROFILE. BUILD_DIR replaces build/ (tests).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/wine-arm64/lib.sh"
. "$ROOT/dxmt/pins"  # DXMT_COMMIT
B="${BUILD_DIR:-$ROOT/build}"
OUT="$B/wine-arm64"
BUILD="$B/wine-arm64-src/wine-build"
FEX_DLL="$B/wine-arm64-src/fex-ec/Bin/libarm64ecfex.dll"
FEX_SO="$B/wine-arm64-src/fex-unixlib/libarm64ecfex.so"
DXMT_IN="$B/wine-arm64-src/dxmt-install"
DXMT_TREE="$B/wine-arm64-src/dxmt"
APP="$OUT/wine.app.tmp"
R="$APP/Contents/Resources"
INSTALL="$OUT/install.tmp"
export MACOSX_DEPLOYMENT_TARGET=27.0

check_signing
[ -x "$BUILD/loader/wine" ] || die "no Wine build at $BUILD: run make wine-arm64"
[ -f "$FEX_DLL" ] && [ -f "$FEX_SO" ] || die "no FEX build in $B/wine-arm64-src: run make wine-arm64"
[ -d "$DXMT_IN" ] || die "no DXMT build at $DXMT_IN: run make wine-arm64"
mkdir -p "$OUT"
rm -rf "$APP" "$INSTALL"
trap 'rm -rf "$INSTALL"' EXIT

# 1. Layout. make install's tree (configure's default prefix, /usr/local) goes under Resources, where configure's
#    relative paths (bin to ../lib/wine and back) hold. The loader is the one entitled binary: make install's own
#    copies of it (bin/wine, which every program link in bin/ points at, and the unix library directory's) become
#    links to it, since Wine execs <ntdll.so's real directory>/wine for every Windows process.
mkdir -p "$APP/Contents/MacOS" "$R"
make -C "$BUILD" install DESTDIR="$INSTALL" > "$OUT/install.log" 2>&1 || die "make install failed; see $OUT/install.log"
for d in bin lib share; do
  mv "$INSTALL/usr/local/$d" "$R/$d" || die "make install left no $d (see $OUT/install.log)"
done
cp "$BUILD/loader/wine" "$APP/Contents/MacOS/wine"
rm -f "$R/bin/wine" "$R/lib/wine/aarch64-unix/wine"
ln -s ../../MacOS/wine "$R/bin/wine"
ln -s ../../../../MacOS/wine "$R/lib/wine/aarch64-unix/wine"
ln -s ../Resources/lib/wine/aarch64-unix/ntdll.so "$APP/Contents/MacOS/ntdll.so"
# FEX, the x64 emulator (spec §6.3): its ARM64EC DLL among Wine's builtins, its unixlib beside theirs.
cp "$FEX_DLL" "$R/lib/wine/aarch64-windows/"
cp "$FEX_SO" "$R/lib/wine/aarch64-unix/"
# DXMT (arm64 DXMT spec §6), before signing so macho() signs winemetal.so with the rest. winemetal.dll is a Wine builtin
# (DXMT's own build marks it) among Wine's. The front ends are native DLLs that go into a prefix's system32: they keep
# to DXMT/, with the licences and the version.
put() { [ -f "$1/$2" ] || die "no $1/$2"; cp "$1/$2" "$3"; }  # put <dir> <file> <dest>
mkdir -p "$R/DXMT/aarch64-windows"
put "$DXMT_IN" aarch64-windows/winemetal.dll "$R/lib/wine/aarch64-windows/"
put "$DXMT_IN" aarch64-unix/winemetal.so "$R/lib/wine/aarch64-unix/"
for f in d3d11.dll d3d10core.dll dxgi.dll d3d12.dll dxmt-replay.exe; do
  put "$DXMT_IN" "system32/$f" "$R/DXMT/aarch64-windows/"
done
for f in COPYING.LIB LICENSE LICENSE.OLD; do put "$DXMT_TREE" "$f" "$R/DXMT/"; done
put "$DXMT_IN" version "$R/DXMT/"
# Licences (ship-base spec §4): the components' own texts, the committed README and NOTICES.md, and build.sh's SOURCE.
# DXMT's stay in DXMT/.
L="$R/licenses"
S="$B/wine-arm64-src"
mkdir -p "$L/wine" "$L/fex" "$L/llvm" "$L/llvm-mingw"
for f in README NOTICES.md; do put "$ROOT/wine-arm64/licenses" "$f" "$L/"; done
put "$S" SOURCE "$L/"
for f in LICENSE COPYING.LIB AUTHORS NOTICES.md; do put "$S/wine" "$f" "$L/wine/"; done
put "$S/wine" libs/gsm/COPYRIGHT "$L/wine/gsm-COPYRIGHT"
put "$S/wine" libs/faudio/LICENSE "$L/wine/faudio-LICENSE"
put "$S/fex" LICENSE "$L/fex/"
for e in fmt xxhash tiny-json unordered_dense rpmalloc cephes; do
  put "$S/fex" "External/$e/LICENSE" "$L/fex/$e-LICENSE"
done
put "$S/fex" External/range-v3/LICENSE.txt "$L/fex/range-v3-LICENSE.txt"
put "$S/fex" Source/Common/cpp-optparse/LICENSE "$L/fex/cpp-optparse-LICENSE"
put "$B/dxmt-src/llvm-project/llvm" LICENSE.TXT "$L/llvm/"
put "$B/dxmt-src/llvm-project/llvm" lib/Support/COPYRIGHT.regex "$L/llvm/"
put "$B/dxmt-src/llvm-mingw" LICENSE.TXT "$L/llvm-mingw/"
put "$B/dxmt-src/llvm-mingw" aarch64-w64-mingw32/share/mingw32/COPYING.MinGW-w64-runtime.txt "$L/llvm-mingw/"
cp "$ROOT/wine-arm64/Info.plist" "$APP/Contents/Info.plist"
cp "$MACNEUTRON_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"

# The Mach-O files in the bundle, one per line (PE DLLs need no signature).
macho() { find "$APP" -type f -print0 | xargs -0 file | sed -n 's/: *Mach-O .*//p'; }
LOADER="$APP/Contents/MacOS/wine"

# 2. Sign: everything but the loader, then the bundle with the entitlements, which land on the loader alone.
macho | grep -vxF "$LOADER" | tr '\n' '\0' \
  | xargs -0 codesign -f -s "$MACNEUTRON_SIGN_IDENTITY" --options runtime > "$OUT/sign.log" 2>&1 \
  || die "signing the libraries failed; see $OUT/sign.log"
codesign -f -s "$MACNEUTRON_SIGN_IDENTITY" --options runtime --entitlements "$ROOT/wine-arm64/wine.entitlements" "$APP" \
  >> "$OUT/sign.log" 2>&1 || die "signing the bundle failed; see $OUT/sign.log"

# 3. Assert. Each failure names its check.
out=$(codesign --verify --strict --deep "$APP" 2>&1) || die "codesign --verify --strict --deep: $out"
codesign -d --entitlements - "$LOADER" 2>&1 | grep -q cross-architecture-support \
  || die "the loader lacks com.apple.developer.cross-architecture-support"
if codesign -d --entitlements - "$LOADER" 2>&1 | LC_ALL=C /usr/bin/grep -q get-task-allow; then
  die "the loader has get-task-allow"
fi
out=$(BUILD_DIR="$B" sh "$ROOT/wine-arm64/tests/licences_test.sh" "$APP") || die "$out"
macho > "$OUT/macho.list"
while IFS= read -r f; do
  minos=$(otool -l "$f" | awk '/LC_BUILD_VERSION/ { b = 1 } b && /minos/ { print $2; exit }')
  [ "$minos" = 27.0 ] || die "minos of ${f#"$APP"/} is ${minos:-missing}, not 27.0"
  codesign -dvv "$f" 2>&1 | LC_ALL=C /usr/bin/grep -q '^Timestamp=' || die "${f#"$APP"/} has no secure timestamp"
done < "$OUT/macho.list"
rm "$OUT/macho.list"
[ "$(realpath "$R/lib/wine/aarch64-unix/wine")" = "$(realpath "$APP")/Contents/MacOS/wine" ] \
  || die "lib/wine/aarch64-unix/wine does not resolve to Contents/MacOS/wine"
[ "$(realpath "$APP/Contents/MacOS/ntdll.so")" = "$(realpath "$R/lib/wine/aarch64-unix/ntdll.so")" ] \
  || die "Contents/MacOS/ntdll.so does not resolve to lib/wine/aarch64-unix/ntdll.so"
[ -e "$R/bin/wineserver" ] || die "no Resources/bin/wineserver"
[ -e "$R/share/wine/wine.inf" ] || die "no Resources/share/wine/wine.inf"
# DXMT: Wine's builtin marker as dxmt/build.sh checks it (bytes 64-79), the version token, the pin's place in the tree.
builtin() { [ "$(dd if="$1" bs=1 skip=64 count=16 2> /dev/null)" = "Wine builtin DLL" ]; }
builtin "$R/lib/wine/aarch64-windows/winemetal.dll" || die "winemetal.dll lacks Wine's builtin marker"
for f in d3d11.dll d3d10core.dll dxgi.dll d3d12.dll dxmt-replay.exe; do
  ! builtin "$R/DXMT/aarch64-windows/$f" || die "$f carries Wine's builtin marker"
done
ver=$(cat "$R/DXMT/version")
case $ver in "$DXMT_COMMIT"+?*) ;; *) die "DXMT/version is '$ver', not $DXMT_COMMIT+<series or dev>" ;; esac
git -C "$DXMT_TREE" merge-base --is-ancestor "$DXMT_COMMIT" HEAD \
  || die "$DXMT_COMMIT (dxmt/pins) is not an ancestor of HEAD in $DXMT_TREE"
others=$(macho | grep '/wine$' | grep -vxF "$LOADER" || true)
[ -z "$others" ] || die "another Mach-O named wine: $others"

# 4. Stage.
rm -rf "$OUT/wine.app"
mv "$APP" "$OUT/wine.app"
echo "wine-arm64: staged $OUT/wine.app" >&2
