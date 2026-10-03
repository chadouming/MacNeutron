#!/bin/sh
# Builds MacNeutron's arm64 Wine (11.19 + wine-arm64/patches/wine) into build/wine-arm64-src/wine-build
# (native arm64 spec §5.4). Never installs tools. BUILD_DIR replaces build/ (tests).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/wine-arm64/pins"
. "$ROOT/wine-arm64/lib.sh"
B="${BUILD_DIR:-$ROOT/build}"
SRC="$B/wine-arm64-src"
OUT="$B/wine-arm64"
W="$SRC/wine"
# What the tree was patched to, kept outside it so they never count as changes: HEAD after the patches went on, and
# the hash of the series (pins and patches) that went on. A tree at that HEAD with another series is started over.
APPLIED="$SRC/wine.applied"
SERIES_FILE="$SRC/wine.series"
PATCHES="$ROOT/wine-arm64/patches/wine"

# 1. Tools, all named at once. bison and flex are keg-only: Homebrew's go first on PATH.
need_tool autoconf autoconf; need_tool bison bison keg; need_tool flex flex keg; need_tool cmake cmake
need_tool ninja ninja
die_if_missing
# llvm-mingw's arm64ec- and aarch64-w64-mingw32 wrappers, for the Windows side of Wine.
PATH="$(sh "$ROOT/dxmt/toolchain.sh"):$PATH"
export PATH
export MACOSX_DEPLOYMENT_TARGET=27.0

# 2. Fetch and patch, once per series. A tree with work in it is never touched; a clean one follows the patches.
series=$(series_of "$ROOT/wine-arm64/pins" "$PATCHES"/*.patch)
mode=$(build_mode "$W" "$APPLIED" "$SERIES_FILE" "$series")
if [ "$mode" = reapply ]; then
  echo "wine-arm64: patch series changed, re-applying" >&2
  rm -rf "$W"
  mode=pinned
fi
case "$mode" in
  pinned)
    echo "wine-arm64: fetching Wine $WINE_TAG" >&2
    rm -rf "$W.tmp" "$SRC/wine-build" "$OUT/version"  # a new tree gets a new build folder
    mkdir -p "$SRC"
    git clone -q -c advice.detachedHead=false --depth 1 --branch "$WINE_TAG" "$WINE_REPO" "$W.tmp" \
      || die "can't clone $WINE_REPO at $WINE_TAG"
    [ "$(git -C "$W.tmp" rev-parse HEAD)" = "$WINE_COMMIT" ] || die "$WINE_TAG is not $WINE_COMMIT in $WINE_REPO"
    git -C "$W.tmp" checkout -q -b macneutron
    for p in "$PATCHES"/*.patch; do
      git -C "$W.tmp" am -q "$p" || { git -C "$W.tmp" am --abort; die "patch $(basename "$p") does not apply to $WINE_COMMIT"; }
    done
    # Before the move: a stop in between leaves no tree, so it's redone.
    git -C "$W.tmp" rev-parse HEAD > "$APPLIED"
    echo "$series" > "$SERIES_FILE"
    mv "$W.tmp" "$W"
    ;;
  applied)
    stamp=$(stamp_of "$ROOT/wine-arm64/pins" "$PATCHES"/*.patch "$ROOT/wine-arm64/build.sh" "$ROOT/wine-arm64/lib.sh")
    if [ "$(cat "$OUT/version" 2> /dev/null)" = "$stamp" ]; then
      echo "wine-arm64: up to date" >&2
      exit 0
    fi
    ;;
  development)
    echo "wine-arm64: development build" >&2
    rm -f "$OUT/version"  # what gets built is not what the stamp describes; the next applied build redoes it
    ;;
esac

# 3. Configure, once per build folder: out of tree, with the checked-in configure regenerated first.
if [ ! -f "$SRC/wine-build/Makefile" ]; then
  echo "wine-arm64: configuring (log: $SRC/configure.log)" >&2
  mkdir -p "$SRC/wine-build"
  ( cd "$W" && autoreconf && rm -rf autom4te.cache configure~ ) > "$SRC/configure.log" 2>&1 \
    || die "autoreconf failed; see $SRC/configure.log"
  ( cd "$SRC/wine-build" && "$W/configure" --enable-archs=arm64ec,aarch64 --with-mingw=llvm-mingw --disable-tests \
      --without-x --without-wayland --without-oss --without-alsa --without-pulse --without-sane --without-usb \
      --without-v4l2 --without-pcap --without-capi --without-opencl --without-cups CC=/usr/bin/clang ) \
    >> "$SRC/configure.log" 2>&1 || die "configure failed; see $SRC/configure.log"
fi

# 4. Make.
echo "wine-arm64: building (log: $SRC/make.log)" >&2
make -C "$SRC/wine-build" -j"$(sysctl -n hw.ncpu)" > "$SRC/make.log" 2>&1 || die "make failed; see $SRC/make.log"

# 5. Stamp, last: only a finished build of the applied patches gets one.
if [ "$mode" != development ]; then
  mkdir -p "$OUT"
  stamp_of "$ROOT/wine-arm64/pins" "$PATCHES"/*.patch "$ROOT/wine-arm64/build.sh" "$ROOT/wine-arm64/lib.sh" > "$OUT/version"
fi
echo "wine-arm64: built $SRC/wine-build" >&2
