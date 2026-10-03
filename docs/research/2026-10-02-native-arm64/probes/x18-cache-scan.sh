#!/bin/zsh
# Scans every image in the dyld shared cache for instructions that touch x18 (native arm64 design §5.3; rerun on each
# macOS beta). Usage: x18-cache-scan.sh <out-dir>. Writes <out-dir>/hits.txt as "image | function | instruction".
# The 2026-10-02 run found no code that depends on x18's value; ../x18-boundaries.md says how its matches (lookup tables
# decoded as instructions, libunwind save/restore, firmware modules) were classified. About 2.5 minutes on an M5 Pro (2026-10-03: 4,088 images, 1,021 matches).
set -eu
out=$1; rm -rf "$out/parts"; mkdir -p "$out/parts"
dyld_info -all_dyld_cache -uuid 2>/dev/null | sed -nE 's/^(\/.*) \[arm64e\]:$/\1/p' > "$out/images.txt"
# One dyld_info per 40 images, one job per core; each job keeps its own image/function context in its own file.
tr '\n' '\0' < "$out/images.txt" | xargs -0 -n 40 -P "$(sysctl -n hw.ncpu)" sh -c '
  dyld_info -arch arm64e -disassemble "$@" 2>/dev/null \
    | LC_ALL=C grep -E "^/.*\[arm64e\]:$|^[^ 0].*:$|[^0-9a-zA-Z_][xw]18([^0-9]|$)" \
    | awk "/^\/.*\[arm64e\]:$/{img=\$1; next} /^[^ 0].*:$/{fn=\$1; next} {print img\" | \"fn\" | \"\$0}" \
    > "$(mktemp "$0/parts/p.XXXXXX")"' "$out"
cat "$out"/parts/* > "$out/hits.txt"
echo "$(wc -l < "$out/images.txt" | tr -d ' ') images, $(wc -l < "$out/hits.txt" | tr -d ' ') hits" >&2
