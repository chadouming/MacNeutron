#!/bin/sh
# The arm64 Wine runtime on the maintainer's Mac (native arm64 spec §7.3): `make wine-arm64-check`.
# Usage: check.sh [step...]   no step = all, in STEPS' order. Needs `make build wine-arm64 wine-arm64-tests`; g4-bench
# also needs MacNeutron's runtime-v4.7.3 installed (MACNEUTRON_TOOL names another tool folder).
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
# Gate G4's baseline: a clone of the installed MacNeutron tool folder (x86_64 Wine under Rosetta), never the folder
# itself, run by the launcher just built. RPFX is its STEAM_COMPAT_DATA_PATH; Wine's prefix is RPFX/pfx.
RSRC="${MACNEUTRON_TOOL:-$HOME/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron}"
RTOOL="$WORK/rosetta tool"
RPFX="$WORK/prefix rosetta"
RWINE="$RTOOL/Libraries/Wine/bin"

# Steps, in order; each task appends its own. NEEDS_PREFIX: the steps that run in the prefix `boot` creates.
# NEEDS_FEX: the x64 steps, which run after `fex` registers FEX in that prefix (else Wine's stub xtajit64 runs them).
G1="g1-hello g1-seh g1-threads g1-kuser g1-smc g1-tsc g1-unaligned"
STEPS="macos signature boot pages unentitled arm64 isec g3-cpu fex $G1 g2-litmus viewec wxflip g5-jit g4-bench"
NEEDS_PREFIX="pages arm64 isec g3-cpu fex $G1 g2-litmus viewec wxflip g5-jit g4-bench"
NEEDS_FEX="$G1 g2-litmus g5-jit g4-bench"

# The processes running the runtime's executables. Wine rewrites argv, so `pkill -f <path>` finds nothing; the kernel
# knows the executable.
runtime_pids() {
  for f in "$TOOL/Contents/MacOS/wine" "$TOOL/Contents/Resources/bin/wineserver" \
    "$UNENT/Contents/MacOS/wine" "$UNENT/Contents/Resources/bin/wineserver" \
    "$RTOOL/bin/macneutron" "$RTOOL/Libraries/Wine/lib/wine/x86_64-unix/wine" "$RWINE/wineserver"; do
    [ -e "$f" ] || continue
    lsof -t "$f" 2> /dev/null || true
  done | sort -u | tr '\n' ' '
}

# Stops the runtimes: their servers first (the clones' too), then whatever still runs one of the binaries.
cleanup() {
  for pair in "$TOOL/Contents/Resources/bin/wineserver|$PFX" "$UNENT/Contents/Resources/bin/wineserver|$UPFX" \
    "$RWINE/wineserver|$RPFX/pfx"; do
    if [ -d "${pair#*|}" ] && [ -x "${pair%%|*}" ]; then
      WINEPREFIX="${pair#*|}" "${pair%%|*}" -k > /dev/null 2>&1 || true
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

# `env -u` options for every FEX_* variable the caller set: runs that measure FEX run it with its defaults.
unfex() { env | sed -n 's/^\(FEX_[A-Za-z0-9_]*\)=.*/-u \1/p'; }

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
  t0=$(date +%s)
  # shellcheck disable=SC2046  # unfex prints a list of options
  out=$(env $(unfex) WINEPREFIX="$PFX" "$TOOL/Contents/MacOS/wine" "$TESTS/x64-litmus.exe" $n | tr -d '\r') || true
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

# x64-bench's rows (gates G5 and G4). bench_rows <file>: fails, saying so, unless the run printed every one.
BENCH_ROWS=36
bench_rows() {
  n=$(grep -c '^row ' "$1" || true)
  [ "$n" = "$BENCH_ROWS" ] || { echo "${1#"$WORK"/} has $n of $BENCH_ROWS rows; it ends: $(tail -n 1 "$1")"; return 1; }
}

# Gate G5 (spec §8): FEX's code memory never flips W^X (patch 12's trace) once a program runs, over one full x64-bench
# run. It calls OutputDebugStringA("jit: start") (kernel32 WARNs it on debugstr) before its rows; the flips counted
# are those after it, and the run has to print every row. A log with no marker fails: its count would mean nothing.
g5_jit_cmd() {
  log="$WORK/g5-x64-bench.log" out="$WORK/g5-x64-bench.txt"
  WINEDEBUG=+wxflip,warn+debugstr,warn+seh wine_run "$TESTS/x64-bench.exe" 2> "$log" | tr -d '\r' > "$out" || true
  cat "$out"
  grep -q 'jit: start' "$log" || { echo "FAIL g5-jit: no marker in ${log#"$ROOT"/}"; return 1; }
  bench_rows "$out" || return 1
  n=$(sed -n '/jit: start/,$p' "$log" | grep -c 'trace:wxflip' || true)
  echo "info x64-bench: $n flips after the marker"
  [ "$n" = 0 ] || { echo "FAIL g5-jit: $n flips"; return 1; }
}

# Gate G4 (spec §8), measured, not gated: x64-bench, five processes per side, the sides alternating so drift falls on
# both alike. FEX: this stack, with FEX's defaults. Rosetta: the launcher just built, in a clone of the installed tool
# folder (the pinned runtime-v4.7.3), with dxmt/check.sh's environment; the launcher adds ROSETTA_ADVERTISE_AVX=1 and
# WINEMSYNC=1. Both sides run with WINEDEBUG=-all, the launcher's default. Passes when every run printed every row;
# bench_report.py's table (FEX time / Rosetta time per row) says how fast. Output in $WORK/bench.
rosetta() {  # rosetta <launch verb> <args...>
  env STEAM_COMPAT_DATA_PATH="$RPFX" SteamAppId=0 MACNEUTRON_NO_STEAM_BRIDGE=1 MACNEUTRON_NO_METALFX=1 \
    "$RTOOL/bin/macneutron" launch "$@"
}
g4_bench_cmd() {
  cp -cR "$RSRC" "$RTOOL" || return 1
  v=$(cat "$RTOOL/runtime-version" 2> /dev/null || true)
  [ "$v" = runtime-v4.7.3 ] || { echo "the tool folder at $RSRC holds ${v:-no runtime}, not runtime-v4.7.3"; return 1; }
  cp "$ROOT/.build/release/macneutron" "$RTOOL/bin/macneutron" || return 1
  rosetta getcompatpath "$WORK" > /dev/null || { echo "creating the Rosetta prefix failed"; return 1; }
  b="$WORK/bench"
  mkdir -p "$b/fex" "$b/rosetta"
  for i in 1 2 3 4 5; do
    t0=$(date +%s)
    # shellcheck disable=SC2046  # unfex prints a list of options
    env $(unfex) WINEDEBUG=-all WINEPREFIX="$PFX" "$TOOL/Contents/MacOS/wine" "$TESTS/x64-bench.exe" \
      2> "$b/fex/run$i.err" | tr -d '\r' > "$b/fex/run$i.txt" || true
    t1=$(date +%s)
    WINEDEBUG=-all rosetta waitforexitandrun "$TESTS/x64-bench.exe" 2> "$b/rosetta/run$i.err" | tr -d '\r' \
      > "$b/rosetta/run$i.txt" || true
    echo "info run $i: fex $((t1 - t0)) s, rosetta $(($(date +%s) - t1)) s"
  done
  for f in "$b"/fex/run*.txt "$b"/rosetta/run*.txt; do bench_rows "$f" || return 1; done
  echo "info fex: $(grep '^cpuid ' "$b/fex/run1.txt")"
  echo "info rosetta: $(grep '^cpuid ' "$b/rosetta/run1.txt")"
  python3 "$ROOT/wine-arm64/tools/bench_report.py" "$b/fex" "$b/rosetta" > "$b/report.txt" || return 1
  cat "$b/report.txt"
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
    g1-unaligned) step g1-unaligned 60 exe_cmd x64-unaligned ;;
    g5-jit) step g5-jit 600 g5_jit_cmd; grep '^info ' "$WORK/g5-jit.log" ;;
    g4-bench) step g4-bench 3600 g4_bench_cmd; grep '^info ' "$WORK/g4-bench.log"; cat "$WORK/bench/report.txt" ;;
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
