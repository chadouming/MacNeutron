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
# NEEDS_FEX: the x64 steps, which run after `fex` registers FEX in that prefix (else Wine's stub xtajit64 runs them).
G1="g1-hello g1-seh g1-threads g1-kuser g1-smc g1-tsc"
STEPS="macos signature boot pages unentitled arm64 isec g3-cpu fex $G1 g2-litmus viewec wxflip"
NEEDS_PREFIX="pages arm64 isec g3-cpu fex $G1 g2-litmus viewec wxflip"
NEEDS_FEX="$G1 g2-litmus"

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

# FEX as the prefix's x64 emulator (native arm64 spec §6.3): the default value of HKLM\Software\Microsoft\Wow64\amd64.
fex_cmd() {
  wine_run reg add 'HKLM\Software\Microsoft\Wow64\amd64' /ve /d libarm64ecfex.dll /f || return 1
  out=$(wine_run reg query 'HKLM\Software\Microsoft\Wow64\amd64' /ve | tr -d '\r') || return 1
  printf '%s\n' "$out"  # not echo: it would read the key's \a as a bell
  printf '%s\n' "$out" | grep -q 'REG_SZ *libarm64ecfex\.dll$' \
    || { echo "the amd64 emulator is not libarm64ecfex.dll"; return 1; }
}

# Gate G1's hello: x64 code under FEX, with the exception and DLL-load traces in the step's log.
g1_hello_cmd() {
  export WINEDEBUG=+seh,+loaddll
  exe_cmd x64-hello
}

# The rest of gate G1 (spec §8), each test under FEX. Structured exceptions and a C++ throw are one step.
g1_seh_cmd() { exe_cmd x64-seh && exe_cmd x64-seh-cpp; }

# Gate G2 (spec §8): x64 memory ordering under FEX's software TSO. The default run, with FEX's defaults (every FEX_*
# variable the caller set is dropped), forbids every pattern. The control run, TSO off, has to show MP reordering, or
# the test can't see reordering at all; its other patterns are only reported.
g2_litmus_cmd() {
  n=10000000
  unfex=$(env | sed -n 's/^\(FEX_[A-Za-z0-9_]*\)=.*/-u \1/p')
  t0=$(date +%s)
  # shellcheck disable=SC2086  # unfex is a list of options
  out=$(env $unfex WINEPREFIX="$PFX" "$TOOL/Contents/MacOS/wine" "$TESTS/x64-litmus.exe" $n | tr -d '\r') || true
  echo "$out"
  echo "info TSO on: $(($(date +%s) - t0)) s"
  for p in MP LB 2+2W IRIW; do
    f=$(echo "$out" | sed -n "s/^litmus $p forbidden=\([0-9]*\) runs=$n\$/\1/p")
    [ -n "$f" ] || { echo "FAIL g2-litmus: no $p result for $n runs"; return 1; }
    [ "$f" = 0 ] || { echo "FAIL g2-litmus: $p forbidden=$f"; return 1; }
  done
  t0=$(date +%s)
  out=$(FEX_TSOENABLED=0 wine_run "$TESTS/x64-litmus.exe" $n | tr -d '\r') || true
  echo "$out" | sed 's/^litmus /info TSO off: litmus /'
  echo "info TSO off: $(($(date +%s) - t0)) s"
  f=$(echo "$out" | sed -n "s/^litmus MP forbidden=\([0-9]*\) runs=$n\$/\1/p")
  [ -n "$f" ] || { echo "FAIL g2-litmus: control: no MP result for $n runs"; return 1; }
  [ "$f" -ge 1 ] || { echo "FAIL g2-litmus: control saw no MP violation"; return 1; }
}

# Patch 12's W^X flip trace (spec §5.2): an RWX page, rewritten and run 10 times, flips at least 10 times, in both
# directions, and every trace line has the one format.
wxflip_cmd() {
  out=$(WINEDEBUG=+wxflip wine_run "$TESTS/arm64-wxflip.exe" 2>&1 | tr -d '\r') || true
  echo "$out" | grep -v 'trace:wxflip' || true
  n=$(echo "$out" | grep -c 'trace:wxflip' || true)
  [ "$n" -gt 0 ] || { echo "FAIL wxflip: 0 trace lines"; return 1; }
  bad=$(echo "$out" | grep 'trace:wxflip' | grep -Ev 'trace:wxflip:virtual_handle_fault 0x[0-9a-f]+ -> r[wx]$' || true)
  [ -z "$bad" ] || { echo "FAIL wxflip: odd trace line: $(echo "$bad" | head -n 1)"; return 1; }
  for to in rx rw; do
    echo "$out" | grep -q "trace:wxflip:virtual_handle_fault 0x[0-9a-f]* -> $to\$" || { echo "FAIL wxflip: no flip to $to"; return 1; }
  done
  echo "$out" | grep -qx 'PASS arm64-wxflip' || { echo "FAIL wxflip: the program did not pass"; return 1; }
  echo "info $n trace lines"
  [ "$n" -ge 10 ] || { echo "FAIL wxflip: $n trace lines, wanted at least 10"; return 1; }
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
    fex) step fex 60 fex_cmd ;;
    g1-hello) step g1-hello 60 g1_hello_cmd ;;
    g1-seh) step g1-seh 60 g1_seh_cmd ;;
    g1-threads) step g1-threads 60 exe_cmd x64-threads ;;
    g1-kuser) step g1-kuser 60 exe_cmd x64-kuser ;;
    g1-smc) step g1-smc 60 exe_cmd x64-smc ;;
    g1-tsc) step g1-tsc 60 exe_cmd x64-tsc; grep '^info ' "$WORK/g1-tsc.log" ;;
    g2-litmus) step g2-litmus 1800 g2_litmus_cmd; grep '^info ' "$WORK/g2-litmus.log" ;;
    viewec) step viewec 60 exe_cmd arm64ec-viewec ;;
    wxflip) step wxflip 60 wxflip_cmd; grep '^info ' "$WORK/wxflip.log" ;;
    *) die "no runner for $1" ;;
  esac
}

want="${*:-$STEPS}"
for s in $want; do
  case " $STEPS " in *" $s "*) ;; *) die "no step named $s (steps: $STEPS)" ;; esac
done
for s in $want; do
  case " $NEEDS_FEX " in *" $s "*) want="fex $want" ;; esac
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
