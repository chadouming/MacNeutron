#!/bin/zsh
# Scans every image in the dyld shared cache for instructions that touch x18 (native arm64 design §5.3; rerun on each
# macOS beta). Usage: x18-cache-scan.sh <out-dir>. Writes <out-dir>/hits.txt as "image | function | instruction".
# The 2026-10-02 run found no code that depends on x18's value; ../x18-boundaries.md says how its 1,021 matches
# (lookup tables decoded as instructions, libunwind save/restore, firmware modules) were classified.
set -eu
out=$1; mkdir -p "$out"
dyld_info -arch arm64e -disassemble -all_dyld_cache 2>/dev/null \
  | LC_ALL=C grep -E '^/.*\[arm64e\]:$|^[^ 0].*:$|[^0-9a-zA-Z_][xw]18([^0-9]|$)' \
  | awk '/^\/.*\[arm64e\]:$/{img=$1; n++; next} /^[^ 0].*:$/{fn=$1; next} {print img" | "fn" | "$0; c++}
         END{print n" images, "c+0" hits" > "/dev/stderr"}' > "$out/hits.txt"
