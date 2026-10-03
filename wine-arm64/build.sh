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
APPLIED="$SRC/wine.applied"  # HEAD after the patches went on; outside the tree, so it never counts as a change
PATCHES="$ROOT/wine-arm64/patches/wine"

# 1. Tools. bison and flex are keg-only (macOS ships bison 2.3, too old), so Homebrew's go first on PATH.
for t in bison flex; do
  p=$(brew --prefix "$t" 2> /dev/null) || p=
  [ -n "$p" ] && [ -x "$p/bin/$t" ] || die "missing tool: $t (brew install $t)"
  PATH="$p/bin:$PATH"
done
need_tool autoconf autoconf; need_tool cmake cmake; need_tool ninja ninja
# llvm-mingw's arm64ec- and aarch64-w64-mingw32 wrappers, for the Windows side of Wine.
PATH="$(sh "$ROOT/dxmt/toolchain.sh"):$PATH"
export PATH
export MACOSX_DEPLOYMENT_TARGET=27.0

# 2. Fetch and patch, once. A tree that exists is never touched: the patches are applied or the tree is yours.
mode=$(build_mode "$W" "$APPLIED")
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
    git -C "$W.tmp" rev-parse HEAD > "$APPLIED"  # before the move: a stop in between leaves no tree, so it's redone
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
