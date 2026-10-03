#!/bin/sh
# dxmt/build.sh's refusals, without network or a real build (DXMT fork spec §7).
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="${TMPDIR:-/tmp}/macneutron dxmt-build-test"
rm -rf "$T"; mkdir -p "$T/bin"
fail=0
expect() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2], want [$3]"; fail=1; fi; }
. "$ROOT/dxmt/pins"

# A missing tool is named with its Homebrew formula: a PATH with every tool but meson.
for t in cmake ninja; do ln -s "$(command -v $t)" "$T/bin/$t"; done
out=$(PATH="$T/bin:/usr/bin:/bin" BUILD_DIR="$T/b1" sh "$ROOT/dxmt/build.sh" 2>&1) && st=0 || st=$?
expect "a missing tool stops the build" "$st" 1
expect "and is named with its formula" "$(echo "$out" | grep -c 'meson (brew install meson)')" 1

# A download that doesn't match its pin stops before anything is built or staged.
mkdir -p "$T/b2/dxmt-src"; echo "not wine" > "$T/b2/dxmt-src/wine.tar.gz"
out=$(BUILD_DIR="$T/b2" sh "$ROOT/dxmt/build.sh" 2>&1) && st=0 || st=$?
expect "a bad checksum stops the build" "$st" 1
expect "and says so" "$(echo "$out" | grep -c 'checksum mismatch for wine.tar.gz')" 1
expect "and stages nothing" "$([ -e "$T/b2/dxmt" ] && echo staged || echo none)" none
expect "and moves the bad file aside, so the next run downloads it again" \
  "$([ -e "$T/b2/dxmt-src/wine.tar.gz" ] && echo kept || echo moved):$([ -f "$T/b2/dxmt-src/wine.tar.gz.bad" ] && echo bad)" "moved:bad"

# Xcode's Metal Toolchain is a separate download; without it DXMT's Metal shaders can't compile.
mkdir -p "$T/bin2"
for t in cmake ninja meson; do ln -s "$(command -v $t)" "$T/bin2/$t"; done
printf '#!/bin/sh\nexit 1\n' > "$T/bin2/xcrun"; chmod +x "$T/bin2/xcrun"
mkdir -p "$T/b4/dxmt-src"; echo "not wine" > "$T/b4/dxmt-src/wine.tar.gz"  # a regression stops here, not at a download
out=$(PATH="$T/bin2:/usr/bin:/bin" BUILD_DIR="$T/b4" sh "$ROOT/dxmt/build.sh" 2>&1) && st=0 || st=$?
expect "a missing Metal Toolchain is named" \
  "$st:$(echo "$out" | grep -c 'Metal Toolchain (xcodebuild -downloadComponent MetalToolchain)')" "1:1"

# make app ships only a fork commit that's published on the fork's macneutron branch (LGPL).
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone" 2> /dev/null
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q --allow-empty -m pushed
git -C "$T/clone" push -q origin HEAD:macneutron
pushed=$(git -C "$T/clone" rev-parse HEAD)
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q --allow-empty -m local
sh "$ROOT/dxmt/published.sh" "$T/clone" "$pushed" > /dev/null 2>&1 && st=0 || st=$?
expect "a pushed fork commit may ship" "$st" 0
out=$(sh "$ROOT/dxmt/published.sh" "$T/clone" "$(git -C "$T/clone" rev-parse HEAD)" 2>&1) && st=0 || st=$?
expect "an unpushed fork commit may not" "$st:$(echo "$out" | grep -c 'push it before shipping')" "1:1"

# A build already at the pinned commit is left alone, even without the tools.
mkdir -p "$T/b3/dxmt"; echo "$DXMT_COMMIT" > "$T/b3/dxmt/version"; for f in dxil-probe dxil-translate; do printf '#!/bin/sh\n' > "$T/b3/dxmt/$f"; chmod +x "$T/b3/dxmt/$f"; done
out=$(PATH="/usr/bin:/bin" BUILD_DIR="$T/b3" sh "$ROOT/dxmt/build.sh" 2>&1) && st=0 || st=$?
expect "an up-to-date build is kept" "$st:$(echo "$out" | grep -c 'is up to date')" "0:1"

# The Windows compiler is Clang from the pinned llvm-mingw, not Homebrew's GCC.
bin=$(sh "$ROOT/dxmt/toolchain.sh")
expect "the Windows compiler is Clang" "$("$bin/x86_64-w64-mingw32-gcc" --version | head -1 | grep -c clang)" 1
expect "make uses it" "$(make -s -C "$ROOT" -n bridge | grep -c "$bin/x86_64-w64-mingw32-clang")" 3

# dxmt/llvm.sh reuses a finished LLVM install: with .complete present, nothing is cloned or built (stub cmake/git fail).
mkdir -p "$T/llvm/install" "$T/bin3"; touch "$T/llvm/install/.complete"
printf '#!/bin/sh\necho called >> "%s/called"; exit 1\n' "$T" > "$T/bin3/cmake"; cp "$T/bin3/cmake" "$T/bin3/git"
chmod +x "$T/bin3/cmake" "$T/bin3/git"
out=$(PATH="$T/bin3:/usr/bin:/bin" sh -c '. "$1/dxmt/pins"; die() { echo "$*"; exit 1; }; . "$1/dxmt/llvm.sh"
  build_llvm arm64 "$2/llvm/install" "$2/llvm/project" && echo reused' sh "$ROOT" "$T" 2>&1) || true
expect "a finished LLVM install is reused" "$out:$([ -f "$T/called" ] && echo called)" "reused:"

exit $fail
