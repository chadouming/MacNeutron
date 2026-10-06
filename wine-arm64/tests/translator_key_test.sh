#!/bin/sh
# lib.sh's translator_key (arm64 release Ruling 46), which keys DXMT's shader-translation cache and the launcher's
# replay stamp, on scratch DXMT-shaped trees fetched and patched as build.sh does. No network, no build.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/wine-arm64/lib.sh"
. "$ROOT/dxmt/pins"  # LLVM_TAG
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
expect() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2], want [$3]"; fail=1; fi; }
g() { _g_dir=$1; shift; git -C "$_g_dir" -c user.name=t -c user.email=t@t "$@"; }

# The pin: the translator (src/airconv, the DXBC parser, the headers, the top-level build files, d3d11's compile
# arguments, the airconv thunks) and the rest of DXMT.
O="$T/origin"
mkdir -p "$O/src/airconv/dxil" "$O/src/d3d12" "$O/src/d3d11" "$O/src/winemetal/unix" "$O/libs/DXBCParser" "$O/include"
echo 'int convert();' > "$O/src/airconv/dxbc_converter.cpp"
echo 'int lower();' > "$O/src/airconv/dxil/dxil_lower.cpp"
echo 'int parse();' > "$O/libs/DXBCParser/DXBCUtils.cpp"
echo '#pragma once' > "$O/include/adt.hpp"
echo "project('dxmt')" > "$O/meson.build"
echo "option('x', type : 'string')" > "$O/meson.options"
echo 'int variant();' > "$O/src/d3d11/d3d11_shader.cpp"
echo 'int thunk();' > "$O/src/winemetal/airconv_thunks.c"
echo '#pragma once' > "$O/src/winemetal/airconv_thunks.h"
echo 'int queue();' > "$O/src/d3d12/d3d12_command_queue.cpp"
echo 'int present();' > "$O/src/winemetal/unix/winemetal_unix.c"
echo 'int context();' > "$O/src/d3d11/d3d11_context.cpp"
git init -q "$O"; g "$O" add -A; g "$O" commit -qm pin
# The series: one patch in the translator, one outside it.
git clone -q "$O" "$T/work"
echo 'int convert(int);' > "$T/work/src/airconv/dxbc_converter.cpp"; g "$T/work" commit -qam 'airconv: one'
echo 'int queue(int);' > "$T/work/src/d3d12/d3d12_command_queue.cpp"; g "$T/work" commit -qam 'd3d12: two'
g "$T/work" format-patch -q --zero-commit -N -o "$T/patches" HEAD~2..HEAD

# fetch <tree> <time>: the pin plus the series by git am, as build.sh's patch_tree does, committed at <time>.
fetch() {
  git clone -q "$O" "$1"
  GIT_COMMITTER_DATE="$2" g "$1" am -q "$T/patches"/*.patch
}
fetch "$T/a" 2026-10-01T00:00:00Z
fetch "$T/b" 2026-10-02T00:00:00Z
expect "a re-fetch makes other commits" \
  "$([ "$(git -C "$T/a" rev-parse HEAD)" != "$(git -C "$T/b" rev-parse HEAD)" ] && echo yes)" yes
k=$(translator_key "$T/a" release)
expect "the key is a SHA-256" "$(echo "$k" | LC_ALL=C /usr/bin/grep -cE '^[0-9a-f]{64}$')" 1
# 1. Two fetches of one series: one key.
expect "two fetches of an unchanged series have one key" "$(translator_key "$T/b" release)" "$k"
cp -R "$T/a" "$T/moved"
expect "wherever the tree is" "$(translator_key "$T/moved" release)" "$k"

# 2. What translates changes it, committed or not.
changes() {  # changes <what> <tree> <buildtype>: the key differs from $k
  expect "$1 changes the key" "$([ "$(translator_key "$2" "$3")" != "$k" ] && echo yes)" yes
}
printf ' ' >> "$T/a/src/airconv/dxbc_converter.cpp"
changes "an uncommitted byte in src/airconv" "$T/a" release
g "$T/a" checkout -q -- src/airconv/dxbc_converter.cpp
expect "and putting it back restores it" "$(translator_key "$T/a" release)" "$k"
echo x > "$T/a/src/airconv/dxil/new.hpp"
changes "an untracked file in src/airconv" "$T/a" release
rm "$T/a/src/airconv/dxil/new.hpp"
rm "$T/a/src/airconv/dxil/dxil_lower.cpp"
changes "a deleted file in src/airconv" "$T/a" release
g "$T/a" checkout -q -- src/airconv/dxil/dxil_lower.cpp
for f in libs/DXBCParser/DXBCUtils.cpp include/adt.hpp meson.build meson.options src/d3d11/d3d11_shader.cpp \
  src/winemetal/airconv_thunks.c src/winemetal/airconv_thunks.h; do
  cp "$T/a/$f" "$T/saved"; printf ' ' >> "$T/a/$f"
  changes "a byte in $f" "$T/a" release
  cp "$T/saved" "$T/a/$f"
done
changes "another buildtype" "$T/a" debug
expect "another LLVM pin changes the key" "$([ "$(LLVM_TAG=llvmorg-0 translator_key "$T/a" release)" != "$k" ] && echo yes)" yes
expect "the tree is as fetched again" "$(translator_key "$T/a" release)" "$k"

# 3. The rest of DXMT doesn't, committed or not.
printf ' ' >> "$T/a/src/d3d12/d3d12_command_queue.cpp"
expect "an uncommitted byte in src/d3d12 keeps the key" "$(translator_key "$T/a" release)" "$k"
for f in src/d3d11/d3d11_context.cpp src/winemetal/unix/winemetal_unix.c; do
  printf ' ' >> "$T/a/$f"
  expect "an uncommitted byte in $f keeps the key" "$(translator_key "$T/a" release)" "$k"
done
g "$T/a" commit -qam 'd3d12: three'
echo 'int fence();' > "$T/a/src/d3d12/d3d12_fence.cpp"
expect "a commit and a new file outside the translator keep it" "$(translator_key "$T/a" release)" "$k"

[ $fail = 0 ] && echo "translator_key_test: all passed"
exit $fail
