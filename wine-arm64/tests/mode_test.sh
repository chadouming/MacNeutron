#!/bin/sh
# lib.sh's build_mode and stamp_of, against a scratch repo (native arm64 plan, Task 1). No network.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/wine-arm64/lib.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
g() { git -C "$T/r" -c user.name=t -c user.email=t@t "$@"; }

git init -q "$T/r"; echo a > "$T/r/f"; g add f; g commit -qm init
[ "$(build_mode "$T/missing" "$T/a")" = pinned ]
git -C "$T/r" rev-parse HEAD > "$T/a"; [ "$(build_mode "$T/r" "$T/a")" = applied ]
echo x >> "$T/r/f";                    [ "$(build_mode "$T/r" "$T/a")" = development ]  # dirty
g commit -qam e;                       [ "$(build_mode "$T/r" "$T/a")" = development ]  # ahead of .applied
rm "$T/a";                             [ "$(build_mode "$T/r" "$T/a")" = development ]  # no .applied at all
[ "$(stamp_of "$T/r/f")" != "$(MACNEUTRON_SIGN_IDENTITY=other stamp_of "$T/r/f")" ]
echo PASS mode_test
