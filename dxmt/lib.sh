# Shared by dxmt/build.sh and dxmt/toolchain.sh (sourced). Messages go to stderr.
die() { echo "dxmt: $*" >&2; exit 1; }
fetch() {  # fetch <url> <file> <sha256>
  if [ ! -f "$2" ]; then
    echo "dxmt: downloading $1" >&2
    curl -fL --retry 3 -o "$2.part" "$1" >&2 || die "download failed: $1"
    mv "$2.part" "$2"
  fi
  sum=$(shasum -a 256 "$2" | cut -d ' ' -f 1)
  if [ "$sum" != "$3" ]; then
    mv "$2" "$2.bad"  # so the next run downloads it again
    die "checksum mismatch for $(basename "$2"): expected $3, got $sum (moved to $(basename "$2").bad)"
  fi
}
