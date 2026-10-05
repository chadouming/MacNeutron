# Shared by dxmt/toolchain.sh and dxmt/tests/shaders/compile.sh (sourced). Messages go to stderr.
die() { echo "dxmt: $*" >&2; exit 1; }
. "$ROOT/dxmt/fetch.sh"
