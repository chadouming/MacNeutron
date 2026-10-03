#!/bin/sh
# Writes the Wine tree's commits on `macneutron` back to wine-arm64/patches/wine (native arm64 spec §5.2), and records
# that tree as the applied one, so it builds as `applied` again. Run it after committing in build/wine-arm64-src/wine.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/wine-arm64/pins"
. "$ROOT/wine-arm64/lib.sh"
SRC="${BUILD_DIR:-$ROOT/build}/wine-arm64-src"
W="$SRC/wine"
[ -d "$W/.git" ] || die "no Wine tree at $W: run make wine-arm64 first"
[ "$(git -C "$W" symbolic-ref -q --short HEAD)" = macneutron ] || die "$W is not on the macneutron branch"
[ -z "$(git -C "$W" status --porcelain)" ] || die "uncommitted changes in $W: commit them first"
# Into a scratch folder first: a failed export must not leave the series empty.
rm -rf "$SRC/export.tmp"
git -C "$W" format-patch -q --zero-commit -N -o "$SRC/export.tmp" "$WINE_COMMIT..macneutron" || die "format-patch failed"
rm -f "$ROOT"/wine-arm64/patches/wine/*.patch
mv "$SRC"/export.tmp/*.patch "$ROOT/wine-arm64/patches/wine/"
rmdir "$SRC/export.tmp"
git -C "$W" rev-parse HEAD > "$SRC/wine.applied"
series_of "$ROOT/wine-arm64/pins" "$ROOT"/wine-arm64/patches/wine/*.patch > "$SRC/wine.series"
echo "wine-arm64: exported $(ls "$ROOT"/wine-arm64/patches/wine/*.patch | wc -l | tr -d ' ') patches" >&2
