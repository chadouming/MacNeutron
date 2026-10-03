#!/bin/sh
# Writes the commits on `macneutron` in the Wine and FEX trees back to wine-arm64/patches/wine and patches/fex (native
# arm64 spec §5.2, §6.1), and records each tree as the applied one, so it builds as `applied` again. Run it after
# committing in build/wine-arm64-src/wine or fex.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/wine-arm64/pins"
. "$ROOT/wine-arm64/lib.sh"
SRC="${BUILD_DIR:-$ROOT/build}/wine-arm64-src"
# Both trees are checked before either is exported.
for repo in wine fex; do
  T="$SRC/$repo"
  [ -d "$T/.git" ] || die "no $repo tree at $T: run make wine-arm64 first"
  [ "$(git -C "$T" symbolic-ref -q --short HEAD)" = macneutron ] || die "$T is not on the macneutron branch"
  [ -z "$(git -C "$T" status --porcelain)" ] || die "uncommitted changes in $T: commit them first"
done
export_tree() {  # export_tree <repo> <pinned commit>
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
  series_of "$ROOT/wine-arm64/pins" "$P"/*.patch > "$SRC/$1.series"
  echo "wine-arm64: exported $(ls "$P"/*.patch | wc -l | tr -d ' ') $1 patches" >&2
}
export_tree wine "$WINE_COMMIT"
export_tree fex "$FEX_COMMIT"
