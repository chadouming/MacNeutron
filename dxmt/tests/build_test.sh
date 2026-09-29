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
for t in cmake ninja x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc; do ln -s "$(command -v $t)" "$T/bin/$t"; done
out=$(PATH="$T/bin:/usr/bin:/bin" BUILD_DIR="$T/b1" sh "$ROOT/dxmt/build.sh" 2>&1) && st=0 || st=$?
expect "a missing tool stops the build" "$st" 1
expect "and is named with its formula" "$(echo "$out" | grep -c 'meson (brew install meson)')" 1

# A download that doesn't match its pin stops before anything is built or staged.
mkdir -p "$T/b2/dxmt-src"; echo "not wine" > "$T/b2/dxmt-src/wine.tar.gz"
out=$(BUILD_DIR="$T/b2" sh "$ROOT/dxmt/build.sh" 2>&1) && st=0 || st=$?
expect "a bad checksum stops the build" "$st" 1
expect "and says so" "$(echo "$out" | grep -c 'checksum mismatch for wine.tar.gz')" 1
expect "and stages nothing" "$([ -e "$T/b2/dxmt" ] && echo staged || echo none)" none

# A build already at the pinned commit is left alone, even without the tools.
mkdir -p "$T/b3/dxmt"; echo "$DXMT_COMMIT" > "$T/b3/dxmt/version"; printf '#!/bin/sh\n' > "$T/b3/dxmt/dxil-probe"
chmod +x "$T/b3/dxmt/dxil-probe"
out=$(PATH="/usr/bin:/bin" BUILD_DIR="$T/b3" sh "$ROOT/dxmt/build.sh" 2>&1) && st=0 || st=$?
expect "an up-to-date build is kept" "$st:$(echo "$out" | grep -c 'is up to date')" "0:1"

exit $fail
