#!/bin/sh
# Writes the commits on `macneutron` in the Wine, FEX and DXMT trees back to wine-arm64/patches/wine, fex and dxmt
# (native arm64 spec §5.2, §6.1; arm64 DXMT spec §4), and records each tree as the applied one, so it builds as
# `applied` again. Run it after committing in build/wine-arm64-src/wine, fex or dxmt.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/wine-arm64/pins"
. "$ROOT/dxmt/pins"
. "$ROOT/wine-arm64/lib.sh"
SRC="${BUILD_DIR:-$ROOT/build}/wine-arm64-src"
# Every tree is checked before any is exported.
for repo in wine fex dxmt; do
  T="$SRC/$repo"
  [ -d "$T/.git" ] || die "no $repo tree at $T: run make wine-arm64 first"
  [ "$(git -C "$T" symbolic-ref -q --short HEAD)" = macneutron ] || die "$T is not on the macneutron branch"
  [ -z "$(git -C "$T" status --porcelain)" ] || die "uncommitted changes in $T: commit them first"
done
export_tree() {  # export_tree <repo> <pinned commit> <pins file>
  P="$ROOT/wine-arm64/patches/$1"
  # Into a scratch folder first (absolute, as format-patch -o wants): a failed export must not leave the series empty.
  rm -rf "$SRC/export.tmp"
  git -C "$SRC/$1" format-patch -q --zero-commit -N -o "$SRC/export.tmp" "$2..macneutron" \
    || die "format-patch of $1 failed"
  mkdir -p "$P"
  rm -f "$P"/*.patch
  mv "$SRC"/export.tmp/*.patch "$P/"
  rmdir "$SRC/export.tmp"
  git -C "$SRC/$1" rev-parse HEAD > "$SRC/$1.applied"
  series_of "$3" "$P"/*.patch > "$SRC/$1.series"
  echo "wine-arm64: exported $(ls "$P"/*.patch | wc -l | tr -d ' ') $1 patches" >&2
}
export_tree wine "$WINE_COMMIT" "$ROOT/wine-arm64/pins"
export_tree fex "$FEX_COMMIT" "$ROOT/wine-arm64/pins"
export_tree dxmt "$DXMT_COMMIT" "$ROOT/dxmt/pins"
