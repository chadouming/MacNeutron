#!/bin/sh
# Prints the bin folder of the pinned llvm-mingw (Clang) toolchain, fetching it into build/dxmt-src once.
# Every Windows-side binary is built with it: DXMT (dxmt/build.sh), steam.exe, the presenter and D3D12 test programs.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/dxmt/pins"
. "$ROOT/dxmt/lib.sh"
SRC="${BUILD_DIR:-$ROOT/build}/dxmt-src"
T="$SRC/llvm-mingw"
if [ ! -x "$T/bin/x86_64-w64-mingw32-clang" ]; then
  mkdir -p "$SRC"
  fetch "$LLVM_MINGW_URL" "$SRC/llvm-mingw.tar.xz" "$LLVM_MINGW_SHA256"
  rm -rf "$T.tmp"; mkdir -p "$T.tmp"
  tar -xJf "$SRC/llvm-mingw.tar.xz" -C "$T.tmp" --strip-components 1 || die "can't unpack llvm-mingw.tar.xz"
  mv "$T.tmp" "$T"
fi
echo "$T/bin"
