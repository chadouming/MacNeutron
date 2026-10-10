#!/bin/sh
# lib.sh's prefer_native_check (batch Task 7): today's bundle and Wine tree pass; a guarded builtin that prefers native,
# or a loadorder.c whose version_heuristics no longer sends Microsoft DLLs to LO_DEFAULT, fails it. No build.
# prefer_native_test.sh <wine.app>. BUILD_DIR replaces build/.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/wine-arm64/lib.sh"
A="$1/Contents/Resources/lib/wine/aarch64-windows"
W="${BUILD_DIR:-$ROOT/build}/wine-arm64-src/wine"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL prefer_native_test: $*"; exit 1; }
# expect_die <what it must say> <aarch64-windows dir> <Wine tree>
expect_die() {
  out=$( (prefer_native_check "$2" "$3") 2>&1 ) && fail "passed on $2 and $3, want: $1"
  case $out in *"$1"*) ;; *) fail "said [$out], want: $1" ;; esac
}

( prefer_native_check "$A" "$W" ) || fail "today's bundle and Wine tree"

# A guarded builtin that prefers native: mfplat.dll is one (DllCharacteristics 0x170).
mkdir "$T/a"
for n in $CRT_BUILTINS; do cp -c "$A/$n.dll" "$T/a/"; done
cp -c "$A/mfplat.dll" "$T/a/ucrtbase.dll"
expect_die "ucrtbase.dll prefers native" "$T/a" "$W"

# version_heuristics sending Microsoft DLLs elsewhere.
u=dlls/ntdll/unix
mkdir -p "$T/w/$u"
cp "$W/$u/unix_private.h" "$T/w/$u/"
sed "s/{'M','i','c','r','o','s','o','f','t',0}, LO_DEFAULT }/{'M','i','c','r','o','s','o','f','t',0}, LO_NATIVE_BUILTIN }/" \
  "$W/$u/loadorder.c" > "$T/w/$u/loadorder.c"
! cmp -s "$W/$u/loadorder.c" "$T/w/$u/loadorder.c" || fail "the Microsoft row moved"
expect_die "version_heuristics no longer sends" "$A" "$T/w"
echo PASS prefer_native_test
