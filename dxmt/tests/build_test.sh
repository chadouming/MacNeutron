#!/bin/sh
# The DXMT tooling that outlived dxmt/build.sh, without network or a real build: dxmt/published.sh (the release's
# LGPL check), the pinned Clang and dxmt/llvm.sh's reuse of a finished LLVM.
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

# dxmt/llvm.sh reuses a finished LLVM install: with .complete present, nothing is cloned or built (stub cmake/git fail).
mkdir -p "$T/llvm/install" "$T/bin3"; touch "$T/llvm/install/.complete"
printf '#!/bin/sh\necho called >> "%s/called"; exit 1\n' "$T" > "$T/bin3/cmake"; cp "$T/bin3/cmake" "$T/bin3/git"
chmod +x "$T/bin3/cmake" "$T/bin3/git"
out=$(PATH="$T/bin3:/usr/bin:/bin" sh -c '. "$1/dxmt/pins"; die() { echo "$*"; exit 1; }; . "$1/dxmt/llvm.sh"
  build_llvm arm64 "$2/llvm/install" "$2/llvm/project" && echo reused' sh "$ROOT" "$T" 2>&1) || true
expect "a finished LLVM install is reused" "$out:$([ -f "$T/called" ] && echo called)" "reused:"

exit $fail
