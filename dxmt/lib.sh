# Shared by dxmt/build.sh and dxmt/toolchain.sh (sourced). Messages go to stderr.
die() { echo "dxmt: $*" >&2; exit 1; }
. "$ROOT/dxmt/fetch.sh"
