#!/bin/sh
# Assembles and signs build/wine-arm64/wine.app from the built Wine tree (native arm64 spec §4, §7.2). The bundle is
# built as wine.app.tmp and moved to wine.app only after every assertion holds, so a failure stages nothing.
# Needs MACNEUTRON_SIGN_IDENTITY and MACNEUTRON_PROVISIONING_PROFILE. BUILD_DIR replaces build/ (tests).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/wine-arm64/lib.sh"
B="${BUILD_DIR:-$ROOT/build}"
OUT="$B/wine-arm64"
BUILD="$B/wine-arm64-src/wine-build"
APP="$OUT/wine.app.tmp"
R="$APP/Contents/Resources"
INSTALL="$OUT/install.tmp"
export MACOSX_DEPLOYMENT_TARGET=27.0

check_signing
[ -x "$BUILD/loader/wine" ] || die "no Wine build at $BUILD: run make wine-arm64"
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
macho > "$OUT/macho.list"
while IFS= read -r f; do
  minos=$(otool -l "$f" | awk '/LC_BUILD_VERSION/ { b = 1 } b && /minos/ { print $2; exit }')
  [ "$minos" = 27.0 ] || die "minos of ${f#"$APP"/} is ${minos:-missing}, not 27.0"
done < "$OUT/macho.list"
rm "$OUT/macho.list"
[ "$(realpath "$R/lib/wine/aarch64-unix/wine")" = "$(realpath "$APP")/Contents/MacOS/wine" ] \
  || die "lib/wine/aarch64-unix/wine does not resolve to Contents/MacOS/wine"
[ "$(realpath "$APP/Contents/MacOS/ntdll.so")" = "$(realpath "$R/lib/wine/aarch64-unix/ntdll.so")" ] \
  || die "Contents/MacOS/ntdll.so does not resolve to lib/wine/aarch64-unix/ntdll.so"
[ -e "$R/bin/wineserver" ] || die "no Resources/bin/wineserver"
[ -e "$R/share/wine/wine.inf" ] || die "no Resources/share/wine/wine.inf"
others=$(macho | grep '/wine$' | grep -vxF "$LOADER" || true)
[ -z "$others" ] || die "another Mach-O named wine: $others"

# 4. Stage.
rm -rf "$OUT/wine.app"
mv "$APP" "$OUT/wine.app"
echo "wine-arm64: staged $OUT/wine.app" >&2
