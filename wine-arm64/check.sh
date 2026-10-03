#!/bin/sh
# The arm64 Wine runtime on the maintainer's Mac (native arm64 spec §7.3): `make wine-arm64-check`.
# Usage: check.sh [step...]   no step = all, in STEPS' order. Needs `make wine-arm64 wine-arm64-tests`.
# Every run starts fresh: a new clone of the staged bundle, a new prefix. The clone sits at a path with a space, as
# Sub-project 5 will install it. A step that needs a prefix gets one from `boot`, which runs first if it isn't named.
# Nothing of the runtime is left after the script exits, whatever the reason: the last line is PASS or FAIL orphans.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/wine-arm64/lib.sh"
B="${BUILD_DIR:-$ROOT/build}"
STAGED="$B/wine-arm64/wine.app"
TESTS="$B/wine-arm64-tests"
WORK="$B/wine-arm64 check"
TOOL="$WORK/Application Support/wine.app"
PFX="$WORK/prefix arm64"
# The `unentitled` step's loader: a clone of $TOOL re-signed without the entitlement, with a prefix of its own.
UNENT="$WORK/unentitled.app"
UPFX="$WORK/prefix unentitled"

# Steps, in order; each task appends its own. NEEDS_PREFIX: the steps that run in the prefix `boot` creates.
STEPS="macos signature boot pages unentitled arm64 isec g3-cpu"
NEEDS_PREFIX="pages arm64 isec g3-cpu"

# The processes running the runtime's executables. Wine rewrites argv, so `pkill -f <path>` finds nothing; the kernel
# knows the executable.
runtime_pids() {
  for f in "$TOOL/Contents/MacOS/wine" "$TOOL/Contents/Resources/bin/wineserver" \
    "$UNENT/Contents/MacOS/wine" "$UNENT/Contents/Resources/bin/wineserver"; do
    [ -e "$f" ] || continue
    lsof -t "$f" 2> /dev/null || true
  done | sort -u | tr '\n' ' '
}

# Stops the runtime: its servers first (the clone's too), then whatever still runs one of the binaries.
cleanup() {
  for pair in "$TOOL|$PFX" "$UNENT|$UPFX"; do
    if [ -d "${pair#*|}" ] && [ -x "${pair%%|*}/Contents/Resources/bin/wineserver" ]; then
      WINEPREFIX="${pair#*|}" "${pair%%|*}/Contents/Resources/bin/wineserver" -k > /dev/null 2>&1 || true
    fi
  done
  pids=$(runtime_pids)
  # shellcheck disable=SC2086  # pids is a list
  [ -z "$pids" ] || kill -9 $pids 2> /dev/null || true
}

# Prints PASS orphans, or FAIL orphans: <pids> (the processes get a few seconds to die).
orphans() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pids=$(runtime_pids)
    [ -n "$pids" ] || { echo "PASS orphans"; return 0; }
    sleep 0.5
  done
  echo "FAIL orphans: $pids"
  return 1
}

# On any exit: stop the runtime, then say whether anything is left. A leftover turns a pass into a failure.
finish() {
  rc=$?
  trap - EXIT INT TERM
  cleanup
  orphans || rc=1
  exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# step <name> <cap-seconds> <command...>: runs the command (output in $WORK/<name>.log) for at most the cap.
# Prints PASS <name>, or FAIL <name>: <last output line> and exits 1.
step() {
  name=$1 cap=$2; shift 2
  log="$WORK/$name.log"
  ( trap - EXIT INT TERM; "$@" ) > "$log" 2>&1 &
  pid=$!
  waited=0
  while kill -0 "$pid" 2> /dev/null && [ "$waited" -lt $((cap * 4)) ]; do sleep 0.25; waited=$((waited + 1)); done
  why=
  if kill -0 "$pid" 2> /dev/null; then
    kill "$pid" 2> /dev/null || true
    why="timed out after ${cap} s"
    rc=1
  else
    wait "$pid" && rc=0 || rc=$?
  fi
  if [ "$rc" = 0 ]; then echo "PASS $name"; return 0; fi
  last=$(tr -d '\r' < "$log" | grep . | tail -n 1 || true)
  last=${last#"FAIL $name: "}  # a command that already names the step
  echo "FAIL $name: ${why:+$why; }${last:-exit $rc}"
  exit 1
}

wine_run() { WINEPREFIX="$PFX" "$TOOL/Contents/MacOS/wine" "$@"; }

macos_cmd() {
  v=$(sw_vers -productVersion)
  [ "${v%%.*}" -ge 27 ] || { echo "macOS $v is below 27"; return 1; }
}

signature_cmd() {
  [ -d "$TOOL" ] || { echo "no bundle at ${STAGED#"$ROOT"/}"; return 1; }
  codesign --verify --strict --deep "$TOOL" || return 1
  codesign -d --entitlements - "$TOOL/Contents/MacOS/wine" 2>&1 | grep -q cross-architecture-support \
    || { echo "the loader lacks com.apple.developer.cross-architecture-support"; return 1; }
  got=$(realpath "$TOOL/Contents/Resources/lib/wine/aarch64-unix/wine")
  want="$(realpath "$TOOL")/Contents/MacOS/wine"
  [ "$got" = "$want" ] || { echo "aarch64-unix/wine is $got, not $want"; return 1; }
}

boot_cmd() { WINEDLLOVERRIDES="mscoree,mshtml=" wine_run wineboot -i; }

# Runs wine with +virtual (a new Windows process traces its host page size once); the run has to trace at least one
# `host page size:` line, and every one says 4k. A 16K process only gets to say so if nothing re-execs it.
pages_run() {  # pages_run <name> <wine args...>
  name=$1; shift
  trace="$WORK/pages-$name.trace"
  WINEDEBUG=+virtual WINEDLLOVERRIDES="mscoree,mshtml=" wine_run "$@" > "$trace" 2>&1 || { echo "$name: exit $?"; return 1; }
  lines=$(grep 'host page size:' "$trace" | tr -d '\r' || true)
  [ -n "$lines" ] || { echo "$name: no host page size line in ${trace#"$ROOT"/}"; return 1; }
  bad=$(echo "$lines" | grep -v 'host page size: 4k$' || true)
  [ -z "$bad" ] || { echo "$name: $(echo "$bad" | head -n 1)"; return 1; }
  echo "$name: $(echo "$lines" | wc -l | tr -d ' ') processes, all 4k"
}

pages_cmd() {
  pages_run wineboot wineboot -u && pages_run arm64-hello "$TESTS/arm64-hello.exe"
}

# The entitlement is checked before the exec: without it the kernel kills the 4K exec with no message at all.
unentitled_cmd() {
  cp -cR "$TOOL" "$UNENT"
  codesign -f -s - "$UNENT/Contents/MacOS/wine"  # ad hoc, no entitlements
  rc=0
  err=$(WINEPREFIX="$UPFX" WINEDLLOVERRIDES="mscoree,mshtml=" "$UNENT/Contents/MacOS/wine" wineboot 2>&1 > /dev/null) || rc=$?
  echo "$err"
  [ "$rc" != 0 ] || { echo "wineboot ran from a loader without the entitlement"; return 1; }
  echo "$err" | grep -q "lacks the com.apple.developer.cross-architecture-support entitlement" \
    || { echo "exit $rc, without saying the entitlement is missing"; return 1; }
}

# exe_cmd <test>: runs $TESTS/<test>.exe, which passes when it prints PASS <test>.
exe_cmd() {
  out=$(wine_run "$TESTS/$1.exe" | tr -d '\r') || true  # CRLF line ends: text mode on a pipe
  echo "$out"
  echo "$out" | grep -qx "PASS $1"
}

# Gate G3: the CPU ID registers FEX reads (patch 10). `reg query` prints nothing for REG_QWORD; `reg export` does.
g3_cpu_cmd() {
  wine_run reg export 'HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0' "Z:$WORK/cpu.reg" /y || return 1
  python3 "$ROOT/wine-arm64/tools/cpuregs.py" "$WORK/cpu.reg"
}

run_step() {
  case $1 in
    macos) step macos 10 macos_cmd ;;
    signature) step signature 60 signature_cmd ;;
    boot) step boot 180 boot_cmd ;;
    pages) step pages 120 pages_cmd ;;
    unentitled) step unentitled 30 unentitled_cmd ;;
    arm64) step arm64 60 exe_cmd arm64-hello ;;
    isec) step isec 60 exe_cmd arm64ec-isec ;;
    g3-cpu) step g3-cpu 60 g3_cpu_cmd; grep '^feature ' "$WORK/g3-cpu.log" ;;
    *) die "no runner for $1" ;;
  esac
}

want="${*:-$STEPS}"
for s in $want; do
  case " $STEPS " in *" $s "*) ;; *) die "no step named $s (steps: $STEPS)" ;; esac
done
for s in $want; do
  case " $NEEDS_PREFIX " in *" $s "*) want="boot $want" ;; esac
done

cleanup
rm -rf "$WORK"
mkdir -p "$WORK/Application Support"
# No staged bundle: the signature step says so.
if [ -d "$STAGED" ]; then cp -cR "$STAGED" "$TOOL"; fi
for s in $STEPS; do
  case " $want " in *" $s "*) run_step "$s" ;; esac
done
