#!/bin/sh
# The DXMT tooling that outlived dxmt/build.sh, without network or a real build: dxmt/published.sh (the release's
# LGPL check), the pinned Clang and the reuse of a finished LLVM and llvm-mingw only when they match the pins.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="${TMPDIR:-/tmp}/macneutron dxmt-build-test"
rm -rf "$T"; mkdir -p "$T"
fail=0
expect() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2], want [$3]"; fail=1; fi; }

# A release ships only a fork commit that's published on the fork's macneutron branch (LGPL).
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone" 2> /dev/null
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q --allow-empty -m pushed
git -C "$T/clone" push -q origin HEAD:macneutron
pushed=$(git -C "$T/clone" rev-parse HEAD)
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q --allow-empty -m local
sh "$ROOT/dxmt/published.sh" "$T/clone" "$pushed" > /dev/null 2>&1 && st=0 || st=$?
expect "a pushed fork commit may ship" "$st" 0
out=$(sh "$ROOT/dxmt/published.sh" "$T/clone" "$(git -C "$T/clone" rev-parse HEAD)" 2>&1) && st=0 || st=$?
expect "an unpushed fork commit may not" "$st:$(echo "$out" | LC_ALL=C /usr/bin/grep -c 'push it before shipping')" "1:1"

# The Windows compiler is Clang from the pinned llvm-mingw, not Homebrew's GCC. In make bridge only steamprobe.exe
# is x64 (it runs under FEX); steam.exe and its helper are arm64.
bin=$(sh "$ROOT/dxmt/toolchain.sh")
expect "the Windows compiler is Clang" "$("$bin/x86_64-w64-mingw32-gcc" --version | head -1 | LC_ALL=C /usr/bin/grep -c clang)" 1
expect "make uses it" "$(make -s -C "$ROOT" -n bridge | LC_ALL=C /usr/bin/grep -c "$bin/x86_64-w64-mingw32-clang")" 1

# dxmt/llvm.sh reuses a finished LLVM install built from the pinned LLVM_TAG (its .complete names it): nothing is
# cloned or built (stub cmake/git fail, curl too). One from before the tag was recorded (an empty .complete) is
# adopted; one built from another tag is built again.
. "$ROOT/dxmt/pins"
mkdir -p "$T/llvm/install" "$T/bin3"; touch "$T/llvm/install/.complete"
printf '#!/bin/sh\necho called >> "%s/called"; exit 1\n' "$T" > "$T/bin3/cmake"
for t in git curl; do cp "$T/bin3/cmake" "$T/bin3/$t"; done
chmod +x "$T/bin3/cmake" "$T/bin3/git" "$T/bin3/curl"
llvm() { PATH="$T/bin3:/usr/bin:/bin" sh -c '. "$1/dxmt/pins"; die() { echo "$*"; exit 1; }; . "$1/dxmt/llvm.sh"
  build_llvm arm64 "$2/llvm/install" "$2/llvm/project" 2> /dev/null && echo reused' sh "$ROOT" "$T" || true; }
expect "an LLVM install from before the tag was recorded is adopted" "$(llvm):$(cat "$T/llvm/install/.complete")" \
  "reused:$LLVM_TAG"
expect "a finished LLVM install of the pinned tag is reused" "$(llvm):$([ -f "$T/called" ] && echo called)" "reused:"
echo llvmorg-0.0.0 > "$T/llvm/install/.complete"
expect "an LLVM install of another tag is built again" "$(llvm):$([ -f "$T/called" ] && echo called)" \
  "can't clone llvm-project $LLVM_TAG:called"
rm -f "$T/called"

# dxmt/toolchain.sh likewise: llvm-mingw from before its pin was recorded (no .pin) is adopted; another pin's is
# fetched again (the stub curl fails, so the run stops there).
M="$T/b/dxmt-src/llvm-mingw"
mkdir -p "$M/bin"; printf '#!/bin/sh\n' > "$M/bin/x86_64-w64-mingw32-clang"; chmod +x "$M/bin/x86_64-w64-mingw32-clang"
mingw() { BUILD_DIR="$T/b" PATH="$T/bin3:/usr/bin:/bin" sh "$ROOT/dxmt/toolchain.sh" 2> /dev/null || true; }
expect "llvm-mingw from before its pin was recorded is adopted" "$(mingw):$(cat "$M/.pin")" "$M/bin:$LLVM_MINGW_SHA256"
expect "llvm-mingw of the pin is reused" "$(mingw):$([ -f "$T/called" ] && echo called)" "$M/bin:"
echo 0000 > "$M/.pin"
expect "llvm-mingw of another pin is fetched again" "$(mingw):$([ -f "$T/called" ] && echo called)" ":called"

exit $fail
