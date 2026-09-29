#!/bin/sh
# Builds MacNeutron's DXMT fork, Direct3D 12 enabled, into build/dxmt (DXMT fork spec §5).
# Downloads each pinned input once into build/dxmt-src and never installs tools. BUILD_DIR replaces build/ (tests).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/dxmt/pins"
B="${BUILD_DIR:-$ROOT/build}"
SRC="$B/dxmt-src"
OUT="$B/dxmt"
LLVM="$SRC/llvm"
. "$ROOT/dxmt/lib.sh"

# The DXIL probe (spec §6), against the same LLVM. -fno-rtti matches LLVM's own build.
build_probe() {  # build_probe <folder>
  clang++ -arch x86_64 -std=c++17 -O1 -fno-rtti -I"$LLVM/include" "$ROOT/dxmt/tools/dxil-probe.cpp" -o "$1/dxil-probe" \
    -L"$LLVM/lib" -lLLVMBitReader -lLLVMCore -lLLVMRemarks -lLLVMBitstreamReader -lLLVMBinaryFormat -lLLVMSupport \
    -lLLVMDemangle -lz -lcurses > "$SRC/dxil-probe.log" 2>&1 || die "dxil-probe failed to build; see $SRC/dxil-probe.log"
}

if [ "$(cat "$OUT/version" 2> /dev/null)" = "$DXMT_COMMIT" ] && [ -x "$OUT/dxil-probe" ]; then
  [ "$OUT/dxil-probe" -nt "$ROOT/dxmt/tools/dxil-probe.cpp" ] || build_probe "$OUT"
  echo "dxmt: $OUT is up to date ($DXMT_COMMIT)"
  exit 0
fi

# 1. Tools.
missing=""
need() { command -v "$1" > /dev/null 2>&1 || missing="$missing, $1 (brew install $2)"; }
need cmake cmake; need ninja ninja; need meson meson
# DXMT compiles its own Metal shaders; Xcode ships the compiler as a separate component.
xcrun metal --version > /dev/null 2>&1 || missing="$missing, Metal Toolchain (xcodebuild -downloadComponent MetalToolchain)"
[ -z "$missing" ] || die "missing tools: ${missing#, }"

# 2. Fetch. Checksummed archives first, so a bad download stops before anything is built or staged.
mkdir -p "$SRC"
fetch "$WINE_URL" "$SRC/wine.tar.gz" "$WINE_SHA256"
fetch "$DXC_URL" "$SRC/dxc.zip" "$DXC_SHA256"
if [ ! -d "$SRC/wine" ]; then
  rm -rf "$SRC/wine.tmp"; mkdir -p "$SRC/wine.tmp"
  tar -xzf "$SRC/wine.tar.gz" -C "$SRC/wine.tmp" || die "can't unpack wine.tar.gz"
  mv "$SRC/wine.tmp" "$SRC/wine"
fi
if [ ! -d "$SRC/dxc" ]; then
  rm -rf "$SRC/dxc.tmp"
  # Exit 1 is a warning: DXC's zip uses backslash separators, which unzip converts.
  unzip -q "$SRC/dxc.zip" -d "$SRC/dxc.tmp" 2> /dev/null || [ $? -eq 1 ] || die "can't unpack dxc.zip"
  mv "$SRC/dxc.tmp" "$SRC/dxc"
fi

# The fork at the pinned commit. The clone is reused, so a commit made in it builds before it's pushed.
[ -d "$SRC/dxmt/.git" ] || git clone -q "$DXMT_REPO" "$SRC/dxmt" || die "can't clone $DXMT_REPO"
git -C "$SRC/dxmt" cat-file -e "$DXMT_COMMIT^{commit}" 2> /dev/null || git -C "$SRC/dxmt" fetch -q origin \
  || die "can't fetch $DXMT_REPO"
git -C "$SRC/dxmt" diff --quiet HEAD || die "uncommitted changes in $SRC/dxmt: commit them and pin that commit"
git -C "$SRC/dxmt" -c advice.detachedHead=false checkout -q --detach "$DXMT_COMMIT" \
  || die "commit $DXMT_COMMIT isn't in $DXMT_REPO"
git -C "$SRC/dxmt" submodule update -q --init --depth 1 || die "can't fetch DXMT's submodules"

# 3. LLVM 15: x86_64, static, with DXMT's CI flags. Built once.
if [ ! -f "$LLVM/.complete" ]; then
  [ -d "$SRC/llvm-project/llvm" ] || git clone -q --depth 1 --branch "$LLVM_TAG" \
    https://github.com/llvm/llvm-project.git "$SRC/llvm-project" || die "can't clone llvm-project $LLVM_TAG"
  echo "dxmt: building LLVM $LLVM_TAG (30-60 minutes, once); log: $SRC/llvm.log"
  { cmake -B "$SRC/llvm-build" -S "$SRC/llvm-project/llvm" -G Ninja \
      -DCMAKE_INSTALL_PREFIX="$LLVM" -DCMAKE_OSX_ARCHITECTURES=x86_64 -DLLVM_HOST_TRIPLE=x86_64-apple-darwin \
      -DLLVM_ENABLE_ASSERTIONS=On -DLLVM_ENABLE_ZSTD=Off -DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD="" \
      -DLLVM_BUILD_TOOLS=Off -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off -DCMAKE_POLICY_VERSION_MINIMUM=3.5 &&
    cmake --build "$SRC/llvm-build" && cmake --install "$SRC/llvm-build"; } > "$SRC/llvm.log" 2>&1 \
    || die "LLVM build failed; see $SRC/llvm.log"
  touch "$LLVM/.complete"  # written last: an interrupted install is redone
fi

# 4. DXMT: 64-bit with Direct3D 12, and 32-bit, which gets no D3D12 (spec §5).
# wine_builtin_dll=false keeps the front ends native, as in the runtime's DXMT 0.80: with Wine's builtin marker, a
# d3d11.dll copied into a prefix would make Wine load its own d3d11 instead.
meson_build() {  # meson_build <cross file> <name> <options...>
  cross=$1 name=$2; shift 2
  rm -rf "$SRC/$name" "$SRC/$name-install"
  ( PATH="$MINGW_BIN:$PATH"
    meson setup "$SRC/$name" "$SRC/dxmt" --cross-file "$SRC/dxmt/$cross" --buildtype release --strip \
      --prefix "$SRC/$name-install" -Dwine_builtin_dll=false -Dwine_install_path="$SRC/wine" "$@" &&
    meson compile -C "$SRC/$name" && meson install -C "$SRC/$name" ) > "$SRC/$name.log" 2>&1 \
    || die "DXMT $name build failed; see $SRC/$name.log"
}
# DXMT's cross files name x86_64/i686-w64-mingw32-gcc: put llvm-mingw's Clang wrappers first, for the meson builds only
# (native Mac code must keep Apple's clang).
MINGW_BIN=$(sh "$ROOT/dxmt/toolchain.sh")
echo "dxmt: building DXMT $DXMT_COMMIT"
meson_build build-win64.txt win64 -Denable_d3d12=true -Dnative_llvm_path="$LLVM"
meson_build build-win32.txt win32

# 5. Stage. build/dxmt is replaced only once everything is in place and checked.
I64="$SRC/win64-install" I32="$SRC/win32-install" T="$OUT.tmp"
rm -rf "$T"; mkdir -p "$T/x86_64-windows" "$T/i386-windows" "$T/x86_64-unix"
cp "$I64"/x86_64-windows/*.dll "$I64"/system32/*.dll "$T/x86_64-windows/"
cp "$I32"/i386-windows/*.dll "$I32"/syswow64/*.dll "$T/i386-windows/"
cp "$I64"/x86_64-unix/* "$T/x86_64-unix/"
cp "$SRC/dxmt/COPYING.LIB" "$SRC/dxmt/LICENSE" "$SRC/dxmt/LICENSE.OLD" "$T/"
builtin() { [ "$(dd if="$1" bs=1 skip=64 count=16 2> /dev/null)" = "Wine builtin DLL" ]; }
for f in x86_64-windows/winemetal.dll i386-windows/winemetal.dll; do
  builtin "$T/$f" || die "$f lacks Wine's builtin marker"
done
for f in x86_64-windows/d3d11.dll x86_64-windows/d3d10core.dll x86_64-windows/dxgi.dll x86_64-windows/d3d12.dll \
         i386-windows/d3d11.dll i386-windows/d3d10core.dll i386-windows/dxgi.dll; do
  [ -f "$T/$f" ] || die "the build has no $f"
  ! builtin "$T/$f" || die "$f carries Wine's builtin marker"
done
[ -f "$T/x86_64-unix/winemetal.so" ] || die "the build has no x86_64-unix/winemetal.so"
echo "$DXMT_COMMIT" > "$T/version"

# 6. The DXIL probe.
build_probe "$T"
rm -rf "$OUT"; mv "$T" "$OUT"
echo "dxmt: built $OUT ($DXMT_COMMIT)"
