# Shared by wine-arm64/build.sh, export.sh and tests (sourced). Messages go to stderr.
die() { echo "wine-arm64: $*" >&2; exit 1; }

# Tools the build needs, collected so one run names every missing one (die_if_missing); never installed here.
missing=""
need_tool() {  # need_tool <command> <brew formula> [keg]
  # "keg": the formula is keg-only, so its bin goes first on PATH and only that one counts (macOS ships bison 2.3).
  if [ "${3:-}" = keg ]; then
    keg=$(brew --prefix "$2" 2> /dev/null) || keg=
    if [ -n "$keg" ] && [ -x "$keg/bin/$1" ]; then PATH="$keg/bin:$PATH"; return 0; fi
  elif command -v "$1" > /dev/null 2>&1; then
    return 0
  fi
  missing="$missing, $1 (brew install $2)"
}
die_if_missing() { [ -z "$missing" ] || die "missing tools: ${missing#, }"; }

# What a source tree is: pinned (no tree yet: fetch and patch it), applied (HEAD is the commit recorded in the
# applied file, nothing else changed: the patches are the truth), development (anything else: build it as it is) or,
# when a series file and the current series hash are given, reapply (an applied tree that was patched with another
# series: it holds no work of its own, so build.sh starts it over).
build_mode() {  # build_mode <src-dir> <applied-file> [<series-file> <series>]
  [ -d "$1" ] || { echo pinned; return 0; }
  if [ -n "$(git -C "$1" status --porcelain)" ] || [ "$(git -C "$1" rev-parse HEAD)" != "$(cat "$2" 2> /dev/null)" ]; then
    echo development
  elif [ $# -ge 4 ] && [ "$(cat "$3" 2> /dev/null)" != "$4" ]; then
    echo reapply
  else
    echo applied
  fi
}

# SHA-256 over the files' contents in order, then the signing identity (a different identity is a different build).
stamp_of() {  # stamp_of <file>...
  for f in "$@"; do [ -f "$f" ] || die "no such build input: $f"; done
  { cat "$@"; printf '%s' "${MACNEUTRON_SIGN_IDENTITY:-}"; } | shasum -a 256 | cut -d ' ' -f 1
}

# What a tree has to be patched with: the pins and the patches, whatever the signing identity.
series_of() {  # series_of <file>...
  ( MACNEUTRON_SIGN_IDENTITY=; stamp_of "$@" )
}
