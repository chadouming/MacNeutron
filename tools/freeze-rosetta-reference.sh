#!/bin/bash
# Freeze a clone of the installed Rosetta-era tool as the comparison reference.
# Read-only on the source. Checks find it via MACNEUTRON_REFERENCE (default: rosetta-tool below).
set -euo pipefail
SRC="${MACNEUTRON_TOOL:-$HOME/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron}"
DIR="$HOME/Library/Application Support/MacNeutron Reference"
REF="$DIR/rosetta-tool"

for f in gptk.json runtime-version Libraries/Wine/bin/wineserver; do
  [ -e "$SRC/$f" ] || { echo "refusing: $SRC/$f is missing" >&2; exit 1; }
done
[ ! -e "$REF" ] || { echo "refusing: $REF already exists" >&2; exit 1; }

mkdir -p "$DIR"
rm -rf "$REF.partial"
cp -c -R "$SRC" "$REF.partial"
mv "$REF.partial" "$REF"
{
  echo "runtime=$(cat "$REF/runtime-version")"
  echo "gptk=$(/usr/bin/sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$REF/gptk.json")"
  echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$DIR/FROZEN"
echo "froze $REF"
