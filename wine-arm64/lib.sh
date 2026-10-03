# Shared by wine-arm64/build.sh, export.sh and tests (sourced). Messages go to stderr.
die() { echo "wine-arm64: $*" >&2; exit 1; }

# A tool the build needs, named with its Homebrew formula; never installed here.
need_tool() {  # need_tool <command> <brew formula>
  command -v "$1" > /dev/null 2>&1 || die "missing tool: $1 (brew install $2)"
}

# What a source tree is: pinned (no tree yet: fetch and patch it), applied (HEAD is the commit recorded in the
# applied file, nothing else changed: the patches are the truth) or development (anything else: build it as it is).
build_mode() {  # build_mode <src-dir> <applied-file>
  [ -d "$1" ] || { echo pinned; return 0; }
  if [ -n "$(git -C "$1" status --porcelain)" ] || [ "$(git -C "$1" rev-parse HEAD)" != "$(cat "$2" 2> /dev/null)" ]; then
    echo development
  else
    echo applied
  fi
}

# SHA-256 over the files' contents in order, then the signing identity (a different identity is a different build).
stamp_of() {  # stamp_of <file>...
  for f in "$@"; do [ -f "$f" ] || die "no such build input: $f"; done
  { cat "$@"; printf '%s' "${MACNEUTRON_SIGN_IDENTITY:-}"; } | shasum -a 256 | cut -d ' ' -f 1
}
