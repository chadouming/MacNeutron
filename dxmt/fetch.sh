# fetch <url> <file> <sha256>: downloads the file once, then checks it against the pin; a mismatch is moved aside (so
# the next run downloads it again) and stops the caller with its own die. Sourced by dxmt/lib.sh and
# wine-arm64/build.sh; messages start with ${FETCH_TAG:-dxmt}.
fetch() {
  if [ ! -f "$2" ]; then
    echo "${FETCH_TAG:-dxmt}: downloading $1" >&2
    curl -fL --retry 3 -o "$2.part" "$1" >&2 || die "download failed: $1"
    mv "$2.part" "$2"
  fi
  sum=$(shasum -a 256 "$2" | cut -d ' ' -f 1)
  if [ "$sum" != "$3" ]; then
    mv "$2" "$2.bad"  # so the next run downloads it again
    die "checksum mismatch for $(basename "$2"): expected $3, got $sum (moved to $(basename "$2").bad)"
  fi
}
