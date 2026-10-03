#!/bin/sh
# Builds MacNeutron's arm64 Wine (11.19 + wine-arm64/patches/wine) into build/wine-arm64-src/wine-build and FEX
# (+ wine-arm64/patches/fex) into fex-ec and fex-unixlib, then stages the signed build/wine-arm64/wine.app (native arm64
# spec §5.4, §6.3). Never installs tools. Needs MACNEUTRON_SIGN_IDENTITY and MACNEUTRON_PROVISIONING_PROFILE.
# BUILD_DIR replaces build/ (tests).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/wine-arm64/pins"
. "$ROOT/wine-arm64/lib.sh"
B="${BUILD_DIR:-$ROOT/build}"
SRC="$B/wine-arm64-src"
OUT="$B/wine-arm64"
W="$SRC/wine"
F="$SRC/fex"
# What each tree was patched to, kept outside it so they never count as changes: <repo>.applied, HEAD after the
# patches went on, and <repo>.series, the hash of the series (pins and patches) that went on. A tree at that HEAD with
# another series is started over.
PATCHES="$ROOT/wine-arm64/patches/wine"
FEX_PATCHES="$ROOT/wine-arm64/patches/fex"

# 1. Tools, all named at once. bison and flex are keg-only: Homebrew's go first on PATH. The build doesn't run autoconf;
#    the development loop does, for a patch that changes configure.ac (README).
need_tool autoconf autoconf; need_tool bison bison keg; need_tool flex flex keg; need_tool cmake cmake
need_tool ninja ninja
die_if_missing
check_signing  # before anything is fetched or built
# llvm-mingw's arm64ec- and aarch64-w64-mingw32 wrappers, for the Windows side of Wine.
PATH="$(sh "$ROOT/dxmt/toolchain.sh"):$PATH"
export PATH
export MACOSX_DEPLOYMENT_TARGET=27.0

# 2. Fetch and patch, once per series. A tree with work in it is never touched; a clean one follows the patches.
# patch_tree <tmp-tree> <repo> <patch-dir> <series> <base>: git am the series on branch macneutron, record it, and
# move the tree into place. Recorded before the move: a stop in between leaves no tree, so it's redone.
patch_tree() {
  for p in "$3"/*.patch; do
    git -C "$1" am -q "$p" || { git -C "$1" am --abort; die "patch $(basename "$p") does not apply to $5"; }
  done
  git -C "$1" rev-parse HEAD > "$SRC/$2.applied"
  echo "$4" > "$SRC/$2.series"
  mv "$1" "$SRC/$2"
}
fetch_wine() {
  echo "wine-arm64: fetching Wine $WINE_TAG" >&2
  rm -rf "$W.tmp" "$SRC/wine-build"  # a new tree gets a new build folder
  git clone -q -c advice.detachedHead=false --depth 1 --branch "$WINE_TAG" "$WINE_REPO" "$W.tmp" \
    || die "can't clone $WINE_REPO at $WINE_TAG"
  [ "$(git -C "$W.tmp" rev-parse HEAD)" = "$WINE_COMMIT" ] || die "$WINE_TAG is not $WINE_COMMIT in $WINE_REPO"
  git -C "$W.tmp" checkout -q -b macneutron
  patch_tree "$W.tmp" wine "$PATCHES" "$wine_series" "$WINE_COMMIT"
}
# FEX's main has moved past the pin, so a shallow clone can't reach it: fetch the one commit.
fetch_fex() {
  echo "wine-arm64: fetching FEX $FEX_COMMIT" >&2
  rm -rf "$F.tmp" "$SRC/fex-ec" "$SRC/fex-unixlib"
  git init -q "$F.tmp"
  git -C "$F.tmp" remote add origin "$FEX_REPO"
  git -C "$F.tmp" fetch -q --depth 1 origin "$FEX_COMMIT" || die "can't fetch $FEX_COMMIT from $FEX_REPO"
  git -C "$F.tmp" checkout -q -b macneutron FETCH_HEAD
  git -C "$F.tmp" submodule update -q --init --recursive --depth 1 || die "can't fetch FEX's submodules"
  patch_tree "$F.tmp" fex "$FEX_PATCHES" "$fex_series" "$FEX_COMMIT"
}
wine_series=$(series_of "$ROOT/wine-arm64/pins" "$PATCHES"/*.patch)
fex_series=$(series_of "$ROOT/wine-arm64/pins" "$FEX_PATCHES"/*.patch)
# Every build input, once: the up-to-date check and the stamp written at the end must agree.
stamp=$(stamp_of "$ROOT/wine-arm64/pins" "$PATCHES"/*.patch "$FEX_PATCHES"/*.patch "$ROOT/wine-arm64/build.sh" \
  "$ROOT/wine-arm64/lib.sh" "$ROOT/wine-arm64/bundle.sh" "$ROOT/wine-arm64/wine.entitlements" \
  "$ROOT/wine-arm64/Info.plist")
mkdir -p "$SRC"
wine_mode=$(build_mode "$W" "$SRC/wine.applied" "$SRC/wine.series" "$wine_series")
fex_mode=$(build_mode "$F" "$SRC/fex.applied" "$SRC/fex.series" "$fex_series")
# prepare <repo> <mode>: a tree that isn't there yet, or was patched with another series, is fetched and patched.
prepare() {
  case "$2" in
    reapply) echo "wine-arm64: $1's patch series changed, re-applying" >&2; rm -rf "${SRC:?}/$1" ;;
    pinned) ;;
    *) return 0 ;;
  esac
  rm -f "$OUT/version"
  "fetch_$1"
}
prepare wine "$wine_mode"
prepare fex "$fex_mode"
# The build is a development build if either tree is.
if [ "$wine_mode" = development ] || [ "$fex_mode" = development ]; then
  echo "wine-arm64: development build" >&2
  rm -f "$OUT/version"  # what gets built is not what the stamp describes; the next applied build redoes it
  dev=1
else
  dev=
  if [ "$(cat "$OUT/version" 2> /dev/null)" = "$stamp" ] && [ -d "$OUT/wine.app" ]; then
    echo "wine-arm64: up to date" >&2
    exit 0
  fi
fi

# 3. Configure, once per build folder: out of tree, with the configure the patches carry (no autoreconf, spec §5.4: it
#    would rewrite configure with whatever autoconf is installed, and the tree would no longer be the applied one).
if [ ! -f "$SRC/wine-build/Makefile" ]; then
  echo "wine-arm64: configuring (log: $SRC/configure.log)" >&2
  mkdir -p "$SRC/wine-build"
  ( cd "$SRC/wine-build" && "$W/configure" --enable-archs=arm64ec,aarch64 --with-mingw=llvm-mingw --disable-tests \
      --without-x --without-wayland --without-oss --without-alsa --without-pulse --without-sane --without-usb \
      --without-v4l2 --without-pcap --without-capi --without-opencl --without-cups CC=/usr/bin/clang ) \
    > "$SRC/configure.log" 2>&1 || die "configure failed; see $SRC/configure.log"
fi

# 4. Make.
echo "wine-arm64: building (log: $SRC/make.log)" >&2
make -C "$SRC/wine-build" -j"$(sysctl -n hw.ncpu)" > "$SRC/make.log" 2>&1 || die "make failed; see $SRC/make.log"

# 5. FEX: the ARM64EC DLL with llvm-mingw's toolchain file (absolute path; TUNE_CPU=none, since the default reads
#    /proc/cpuinfo), the unixlib with Apple clang. Each build folder is configured once.
echo "wine-arm64: building FEX (log: $SRC/fex.log)" >&2
: > "$SRC/fex.log"
if [ ! -f "$SRC/fex-ec/build.ninja" ]; then
  cmake -S "$F" -B "$SRC/fex-ec" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$F/Data/CMake/toolchain_mingw.cmake" \
    -DMINGW_TRIPLE=arm64ec-w64-mingw32 -DCMAKE_BUILD_TYPE=Release -DTUNE_CPU=none -DENABLE_LTO=False \
    -DBUILD_TESTING=False -DBUILD_FEXCONFIG=False -DENABLE_JEMALLOC_GLIBC_ALLOC=False -DENABLE_CCACHE=False \
    >> "$SRC/fex.log" 2>&1 || { rm -rf "$SRC/fex-ec"; die "configuring FEX failed; see $SRC/fex.log"; }
fi
ninja -C "$SRC/fex-ec" arm64ecfex >> "$SRC/fex.log" 2>&1 || die "building libarm64ecfex.dll failed; see $SRC/fex.log"
if [ ! -f "$SRC/fex-unixlib/build.ninja" ]; then
  cmake -S "$F/Source/Windows/UnixLib" -B "$SRC/fex-unixlib" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_COMPILER=/usr/bin/clang++ -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 >> "$SRC/fex.log" 2>&1 \
    || { rm -rf "$SRC/fex-unixlib"; die "configuring FEX's unixlib failed; see $SRC/fex.log"; }
fi
ninja -C "$SRC/fex-unixlib" >> "$SRC/fex.log" 2>&1 || die "building FEX's unixlib failed; see $SRC/fex.log"
# Wine loads it only as a builtin (it ignores other DLLs in its own directories). Spec §6.3: it imports ntdll.dll alone
# and has no TLS directory (libc++ is linked statically).
dll="$SRC/fex-ec/Bin/libarm64ecfex.dll"
imports=$(llvm-objdump -p "$dll" | sed -n 's/^ *DLL Name: //p' | tr '\n' ' ')
[ "$imports" = "ntdll.dll " ] || die "libarm64ecfex.dll imports ${imports:-nothing}, not ntdll.dll alone"
if llvm-readobj --coff-tls-directory "$dll" | grep -q StartAddressOfRawData; then
  die "libarm64ecfex.dll has a TLS directory"
fi
[ "$(grep -c 'Wine builtin DLL' "$dll")" = 1 ] || die "libarm64ecfex.dll lacks Wine's builtin marker"

# 6. Bundle and sign (make install into wine.app, the loader's entitlements, every check on the result).
echo "wine-arm64: bundling (log: $OUT/install.log)" >&2
sh "$ROOT/wine-arm64/bundle.sh"

# 7. Stamp, last: only a finished build of the applied patches gets one.
if [ -z "$dev" ]; then
  echo "$stamp" > "$OUT/version"
fi
echo "wine-arm64: built $OUT/wine.app" >&2
