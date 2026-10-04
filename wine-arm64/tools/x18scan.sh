#!/bin/sh
# x18scan.sh [-arch <a>] <mach-o>: the instructions in a Mach-O's code that name x18 or w18 (ship-base spec §5, §9),
# one line per hit: <label> <instruction>, the label being the enclosing otool -tV label without its ':'. otool's
# comments are stripped first (they quote addresses and strings, not registers); the regex is
# docs/research/2026-10-02-native-arm64/probes/x18-cache-scan.sh's. Data in __text decodes as instructions too: reading
# the routine says which a hit is.
set -eu
arch=
if [ "${1:-}" = -arch ]; then arch="-arch ${2:?usage: x18scan.sh [-arch <a>] <mach-o>}"; shift 2; fi
f=${1:?usage: x18scan.sh [-arch <a>] <mach-o>}
# The disassembly, in a file (winemetal.so's is 165 MB). otool exits 0 on a file that is no object or lacks the arch,
# printing at most a header: without one instruction line the scan would pass on nothing.
dis=$(mktemp)
trap 'rm -f "$dis"' EXIT
# shellcheck disable=SC2086  # arch is empty or two words
otool $arch -tV "$f" > "$dis" || { echo "x18scan.sh: otool failed on $f" >&2; exit 1; }
awk '/^[0-9a-f]+\t/ { n = 1; exit } END { exit !n }' "$dis" \
  || { echo "x18scan.sh: otool read no instructions from $f${arch:+ ($arch)}: $(head -n 1 "$dis")" >&2; exit 1; }
# Line 1 is the file's name; an instruction line starts with its address, every other line that ends in ':' is a label.
sed 's/;.*//' "$dis" | LC_ALL=C /usr/bin/grep -E '^[^0-9]|[^0-9a-zA-Z_][xw]18([^0-9]|$)' \
  | awk 'NR == 1 { next }
    /^[0-9a-f]+\t/ { sub(/^[0-9a-f]+\t/, ""); gsub(/\t/, " "); sub(/ +$/, ""); print l " " $0; next }
    /:$/ { l = substr($0, 1, length($0) - 1) }'
