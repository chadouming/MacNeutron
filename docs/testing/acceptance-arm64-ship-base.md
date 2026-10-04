# Native arm64 ship-base Wine acceptance test (sub-project 3)

Spec: `docs/superpowers/specs/2026-10-04-macneutron-ship-base-wine-design.md` §1, §10 and §12. Manual, on the
maintainer's Mac, with:
- the Developer ID identity and the provisioning profile for `net.authspot.macneutron.wine` (`wine-arm64/README.md`);
- MacNeutron's runtime-v4.7.3 installed, with its tarball cached in `~/Library/Caches/MacNeutron/` (G4's baseline and
  the D3DMetal reference), and GPTK imported (the D3DMetal reference of `dxmt/check.sh`);
- **Steam running and logged in**, and **SMITE 2** installed in Steam's default library: `steam-bridge` loads its
  `steam_api64.dll` in place and reaches Steam through the bundle's bridge, and `dxmt-x64` reads its
  `amd_fidelityfx_dx12.dll`. Without them those steps fail naming what is missing;
- Screen Recording granted to the app that runs the check (System Settings › Privacy & Security › Screen Recording),
  for `winshot` in `dxmt-present`, and no app in native full screen on the main display (Wine's windows then open on a
  hidden Space and `winshot` finds none). Windows appear on the display during the check;
- the four tarballs of `wine-arm64/deps.pins` in `build/wine-arm64-src/` (else the build fetches them from the pinned
  URLs), and network access for lsteamclient's sparse fetch from GitHub.

Record results at the bottom.

## Steps

1. **Clean build (S1, S2 and S7's bundle asserts):** with `MACNEUTRON_SIGN_IDENTITY` and
   `MACNEUTRON_PROVISIONING_PROFILE` set,
   ```
   rm -rf build/wine-arm64-src/wine-build build/wine-arm64-src/deps build/wine-arm64-src/deps-src \
     build/wine-arm64-src/lsteamclient build/wine-arm64
   time make wine-arm64
   codesign --verify --strict --deep build/wine-arm64/wine.app
   ```
   This rebuilds what the sub-project adds: the deps, lsteamclient's tree, Wine's build (its configure changed) and the
   bundle. Wine's, FEX's and DXMT's trees and the arm64 LLVM stay (sub-projects 1 and 2 rebuilt them from scratch);
   the tarballs are checked against their pins again, not downloaded.
2. **Checks (S1-S7, M1):** `make wine-arm64-check 2>&1 | tee build/wine-arm64-ship-base-acceptance.log` (outside
   `build/wine-arm64 check/`, which every run deletes). Then
   `LC_ALL=C /usr/bin/grep -cE '7656119[0-9]{10}' build/wine-arm64-ship-base-acceptance.log` must print 0: the log
   holds no SteamID.
3. **The Rosetta stack (S6):** `make test`, `sh dxmt/tests/build_test.sh`, `make bridge-check`, `make dxmt-check`.
4. **M2** is an A/B measured once during development, not in this run: `arm64-x18path.exe time` with the bundle's
   `wine` in the check's prefix (`WINEMSYNC=1`), three runs on a bundle with the old patch 0004 and three on the new.

## Pass criteria (spec §10)

| Gate | Pass |
|---|---|
| **S1 Licences** | `licences_test.sh` passes on the staged bundle and proves itself red; `bundle.sh`'s licence and signing asserts pass |
| **S2 Text and TLS** | `fonts-tls` passes; `bundle.sh`'s library asserts (install names, dependency paths, x18 scan with the allowlist, symbols, no build paths) pass |
| **S3 msync** | `msync` passes in both modes |
| **S4 No flips** | `wxflip-x64` shows 0 flips and `PASS x64-smc` |
| **S5 Strict x18** | `x18` passes (T1-T4 and the static check); the once-per-thread hunk is gone |
| **S6 No regressions** | Every sub-project 1 and 2 step passes under `WINEMSYNC=1`, including both DXMT lanes and `dxmt-present`; `make bridge-check` (the Rosetta bridge) passes; `make test`, `sh dxmt/tests/build_test.sh` and `make dxmt-check` pass; `PASS orphans` |
| **S7 Steam bridge** | `steam-bridge` passes; `bundle.sh`'s lsteamclient asserts pass |
| **M1 msync** (measured) | `x64-sync`'s timing rows in both modes: uncontended wait and signal, a cross-process wake, create/close |
| **M2 x18** (measured) | The round-trip A/B of §9 |

## Results

| Date | Mac | macOS | Wine | FEX | DXMT | Deps | lsteamclient | Patches |
|---|---|---|---|---|---|---|---|---|
| 2026-10-04 | Mac17,8 (Apple M5 Pro, 48 GB) | 27.0.1 (26A434) | wine-11.19, `455e3509b98a6919fd4ad1def4803e08c41c03b2` | `4ed80fd07176dce976a7351f559d59a47b68cbae` | fork `1fba8d25b5e29ab49012d633676a6b0d4b3b96c5`, LLVM 15.0.7 | FreeType 2.14.3, gnutls 3.8.13, nettle 4.0, GMP 6.3.0 | Proton `db9e6ffbf24a95b104fb699dd62532c70a2f9a51` | 17 Wine, 5 FEX, 1 DXMT, 3 lsteamclient |

Repository at `29d9d4e` (the build inputs are the pins and patches in it; the bundle's `licenses/SOURCE` says
`MACNEUTRON_COMMIT=29d9d4e909c89d8516aeee5ba2f6859b2c84a193`, without `+dirty`). **S1-S7 pass and M1-M2 are
measured**, so spec §1's done-when holds. The full check's first run failed one line of `dxmt-arm64ec`, in the D3DMetal
reference on the Rosetta stack, not in this sub-project's code (§3); the second run passed every step in
**15 min 27 s** (927 s, `make wine-arm64-check` from start to end; its prerequisites took seconds, as they were built).

### 1. Clean build

Step 1's `make wine-arm64` took **6 min 19 s** (`time`: real 379.23). Stage times, from the build's output with a
timestamp on each line:

| Stage | Time |
|---|---|
| lsteamclient's sparse fetch (`fetching lsteamclient db9e6ff…`) | 10 s |
| The deps: gmp 40 s, nettle 12 s, gnutls 1 min 51 s, FreeType 8 s | **2 min 51 s** |
| Wine's configure (against the deps, `CXX=/usr/bin/clang++`) | 24 s |
| Wine's build (ARM64EC and arm64, lsteamclient included) | 2 min 26 s |
| FEX and DXMT (up to date: their trees and builds stayed) | 3 s |
| Bundle, sign, and `bundle.sh`'s asserts | 25 s |

The four tarballs were already in `build/wine-arm64-src/`: no download, and `fetch` checked each against its pin. The
run printed no `development build` line: every tree was applied, and `SOURCE` names each series
(`WINE_SERIES=7550b397…`, `FEX_SERIES=1398dcb9…`, `DXMT_SERIES=63a4969e…`, `LSTEAMCLIENT_SERIES=3e73ad3a…`, none
`dev`). It ended with `wine-arm64: built …/build/wine-arm64/wine.app`, so every `bundle.sh` assert held (S1's licence
test and signing asserts, S2's library asserts, S7's lsteamclient asserts; the lists are in spec §4, §5 and §7).
`codesign --verify --strict --deep build/wine-arm64/wine.app`: exit 0.

### 2. The bundle

New and changed files under `wine.app/Contents/Resources/` (spec §3):

```
lib/wine/aarch64-unix/libfreetype.6.dylib   714 KB   arm64, minos 27.0, id @rpath/libfreetype.6.dylib;
                                                     links /usr/lib/libz.1.dylib, libbz2.1.0.dylib, libSystem
lib/wine/aarch64-unix/libgnutls.30.dylib    3.1 MB   arm64, minos 27.0, id @rpath/libgnutls.30.dylib (nettle, hogweed
                                                     and gmp inside); links Security, CoreFoundation, libSystem
lib/wine/aarch64-unix/lsteamclient.so       4.4 MB   arm64, minos 27.0; links @rpath/ntdll.so, /usr/lib/libc++.1.dylib,
                                                     libSystem; loads Mac Steam's steamclient.dylib at run time
lib/wine/aarch64-windows/lsteamclient.dll   57 MB    ARM64X (CHPE metadata), Wine builtin; not stripped
lib/wine/aarch64-unix/ntdll.so              695 KB   msync (0015), strict x18 (0004, 0017)
bin/wineserver                              865 KB   msync (0015)
licenses/                                            the tree below
```

The bundle has 40 Mach-O files. Outside it, `make bridge` built `build/bridge/arm64/steam.exe` and
`build/bridge/arm64/tests/helper.exe` (aarch64), which the launcher will place into prefixes (sub-project 5).

The licence tree, `Contents/Resources/licenses/` (33 files; DXMT's 3 stay in `Resources/DXMT/`, which `README` points
to):

```
README  NOTICES.md  SOURCE
wine/          LICENSE  COPYING.LIB  AUTHORS  NOTICES.md  gsm-COPYRIGHT  faudio-LICENSE
fex/           LICENSE  fmt-LICENSE  range-v3-LICENSE.txt  rpmalloc-LICENSE  unordered_dense-LICENSE  xxhash-LICENSE
               cpp-optparse-LICENSE  tiny-json-LICENSE  cephes-LICENSE
llvm/          LICENSE.TXT  COPYRIGHT.regex
llvm-mingw/    LICENSE.TXT  COPYING.MinGW-w64-runtime.txt
freetype/      LICENSE.TXT  FTL.TXT
gnutls/        COPYING.LESSERv2  COPYING.LESSERv3  COPYINGv3
nettle/        COPYING.LESSERv3  COPYINGv3
gmp/           COPYING.LESSERv3  COPYINGv3
lsteamclient/  LICENSE  NOTE
```

`SOURCE` holds the 15 keys of Task 1 (the repository commit, Wine's, FEX's and its 6 submodules', DXMT's, LLVM's tag,
llvm-mingw's SHA-256, and each series), `LSTEAMCLIENT_COMMIT` and `LSTEAMCLIENT_SERIES`, and the four tarballs' URL
and SHA-256.

### 3. `make wine-arm64-check` (S1-S7, M1)

**Run 1** (`build/wine-arm64-ship-base-acceptance-run1.log`) passed every step up to `dxmt-present`, then failed one
check of `dxmt-arm64ec`, and stopped there (`dxmt-x64` and `g4-bench` didn't run; `PASS orphans`):

```
FAIL dxmt-arm64ec: 1 FAIL lines; first: FAIL and on D3DMetal (but for its occlusion count after a merged pass, and
its zero timestamps): got [hazard rt-read 257 …
```

The line compares the D3DMetal reference, `d3d12_hazards.exe` run by `macneutron launch` on the installed
runtime-v4.7.3 under Rosetta with Apple's D3DMetal, with the expected rows. D3DMetal's run printed 36 of the 46
`hazard` rows and ended after `hazard fence-order 1 0` (expected `1 1`). It didn't hang: the step took 165 s (177 s
in run 2), so the run's 120 s watchdog can't have fired. Our DXMT on the arm64 runtime printed all 46 rows as
expected, in strict order and with overlap, and the lane's other 161 checks passed. Nothing this sub-project changed
runs in that reference. Sub-project 2's acceptance (`acceptance-arm64-dxmt.md`, §Results) saw one D3DMetal reference
line of this class fail once (`fence-transitive`) and pass on re-run, and Task 6's full `check.sh` passed this step on
the build before patch 0017, so the check was run again, unchanged. Run 1's other steps passed as in run 2 (its
`msync` rows are in §4; `steam-bridge` gave `steamid ok`, a 234-byte ticket and `fault: caught` there too).

**Run 2** (`build/wine-arm64-ship-base-acceptance.log`, the brief's command) printed, in order:

```
PASS mode_test
PASS profile_test
PASS licences_test
PASS licences_test self-test
PASS macos
PASS signature
PASS boot
PASS pages
PASS unentitled
PASS arm64
PASS isec
PASS g3-cpu
feature LSE=1
feature LRCPC=1
feature LRCPC2=1
feature AFP=1
PASS fex
PASS g1-hello
PASS g1-seh
PASS g1-threads
PASS g1-kuser
PASS g1-smc
PASS g1-tsc
info CPUID 0x15: eax 1 ebx 1 ecx 1000000000
info QueryPerformanceFrequency 10000000 Hz; RDTSC ran at 1000000558 Hz over 204.5 ms
info CPUID says 1000000000 Hz; measured / CPUID = 1.0000
PASS g1-unaligned
PASS g2-litmus
info TSO on: 8 s
info TSO off: litmus MP forbidden=6644 runs=10000000
info TSO off: litmus LB forbidden=0 runs=10000000
info TSO off: litmus 2+2W forbidden=0 runs=10000000
info TSO off: litmus IRIW forbidden=4677 runs=10000000
info TSO off: 6 s
PASS viewec
PASS wxflip
info 19 trace lines
PASS wxflip-x64
info wxflip-x64: 0 flips
PASS msync
info msync 1 pulse-event 4 of 4 waiters woke, the event is unset
info msync 1 uncontended-wait 143
info msync 1 uncontended-signal 100
info msync 1 cross-process-wake 4554
info msync 1 create-close 28346
info msync 0 pulse-event 4 of 4 waiters woke, the event is unset
info msync 0 uncontended-wait 8453
info msync 0 uncontended-signal 7270
info msync 0 cross-process-wake 9545
info msync 0 create-close 34055
PASS x18
info x18v: 36405700000 checks, 0 zero, 0 bad at start
info stress: 382166310 calls, 74400 suspends
info x18: ntdll.so names x18 9 times, in ___wine_syscall_dispatcher ___wine_unix_call_dispatcher _call_user_mode_callback
PASS g5-jit
info x64-bench: 0 flips after the marker
PASS fonts-tls
PASS steam-bridge
info steam-bridge: probe exit 0
info steam-bridge: steamid ok, ticket 234 bytes
info steam x18: 552 hits
PASS dxmt
PASS dxmt-present
info arm64ec present_loop: pixels 962560 green 71 white 24
info arm64ec d3d12_clear: pixels 962560 green 95 white 0
info x64 present_loop: pixels 962560 green 71 white 24
info x64 d3d12_clear: pixels 962560 green 95 white 0
info arm64ec present_loop cycles=20: cycles 20 ok
PASS dxmt-arm64ec
info arm64 mode: …/build/wine-arm64 check/Application Support/wine.app
info D3D11 frame time: arm64 4.713 ms, rosetta 3.967 ms
info pipeline creation: timing 9.2 ms cold, timing 3.2 ms warm
info dxmt-arm64ec: 177 s
PASS dxmt-x64
info arm64 mode: …/build/wine-arm64 check/Application Support/wine.app
info D3D11 frame time: arm64 5.043 ms, rosetta 4.038 ms
info pipeline creation: timing 9.2 ms cold, timing 1.3 ms warm
info dxmt-x64: 175 s
PASS g4-bench
…
geomean single-threaded=0.930 multithreaded=0.913 calls=1.130
worst: mem_seq_read=2.143 mem_seq_write=2.011 call_std_function=1.361 branch_predictable=1.313 fma256_ps=1.204
ratio > 1 means FEX is slower
PASS orphans
```

35 `PASS` lines, 0 `FAIL`. `LC_ALL=C /usr/bin/grep -cE '7656119[0-9]{10}'` prints 0 on both runs' logs, and on the
step's own `steam-bridge.log`. Step times (from the step logs): everything up to `steam-bridge` 1 min 48 s, the five new
steps among them (`wxflip-x64` about 1 s, `msync` 10 s, `x18` 7 s, `fonts-tls` 1 s, `steam-bridge` 15 s);
`dxmt-present` 1 min 19 s; `dxmt-arm64ec` 177 s; `dxmt-x64` 175 s; `g4-bench` 6 min 22 s.

- **S1 Licences: PASS.** `PASS licences_test` on the staged bundle and `PASS licences_test self-test` (red on a copy
  without `licenses/fex/xxhash-LICENSE` and on an extra `External/vixl`); inside `bundle.sh`, the licence test on
  `wine.app.tmp`, a secure timestamp on every Mach-O and no `get-task-allow` (the build staged).
- **S2 Text and TLS: PASS.** `fonts-tls.log`: `font 19 36x19 dbu 8,16`, `dwrite families 198`,
  `schannel: 0x00000000`, `pfx certs 1`, `PASS arm64-fonts-tls`, and no `cannot find the FreeType` or
  `failed to load libgnutls` in its stderr. `bundle.sh`'s library asserts held: install names, dependency paths and
  rpaths, the x18 scan equal to `x18-allow.txt` (gnutls's `gcm_ghash_v8_4x` 1, `_sha256_block_data_order` 3,
  `_sha512_block_data_order` 3), the 46 FreeType and 70 gnutls symbols, no build path.
- **S3 msync: PASS.** All 14 gated rows `ok` in each mode (28 `ok` lines). The server's log in mode 1 is
  `msync: bootstrapped mach port on wine-…-msync.` and `msync: up and running.`, in mode 0 empty; both mismatch
  directions exit 1 with their own `ERR` line (`Server is running with WINEMSYNC but this process is not, …` and
  `Failed bootstrap_look_up for wine-…-msync`). Every other step ran with `WINEMSYNC=1`. M1 is in §4.
- **S4 No flips: PASS.** `x64-smc`: `RWX page: before the rewrite 1, after 2`, `.text (protection 0x20): before the
  rewrite 1, after 2`, `PASS x64-smc`, **0** `trace:wxflip` lines; `wxflip`'s positive control traced 19. So x64 JITs
  under FEX never flip W^X, and the `MAP_JIT` work stays dropped (spec §8).
- **S5 Strict x18: PASS.** T1 `x18v: 16 threads, 0 mismatches` (36.4 × 10^9 checks, 0 zero, 0 bad); T2 every path
  `ok` in both lanes (seh-av, debugbreak, sigill, suspend, callback, ntreadfile, apc, threads, raw-syscall),
  `x18path: 0 mismatches`; T3 `WINE_X18_SELFTEST=double_on: exit 133` with no `err:seh` line; T4 382 × 10^6 calls and
  74,400 suspends, `ok stress`, 0 mismatches; no `x18: PE stack running OFF` in any log. The static check: `ntdll.so`
  names x18 only in `__wine_syscall_dispatcher`, `__wine_unix_call_dispatcher` and `call_user_mode_callback` (9
  times); `__wine_syscall_dispatcher_return` no longer reads it. `init_syscall_frame` no longer toggles the mode (the
  once-per-thread hunk is gone from `signal_arm64.c`).
- **S6 No regressions: PASS.** Every sub-project 1 and 2 step passed under `WINEMSYNC=1`: G1-G3 and G5, G2's control
  (`FEX_TSOENABLED=0`: MP 6,644 and IRIW 4,677 forbidden outcomes, so the litmus test still detects violations),
  `dxmt-present` with `winshot`'s shares equal to the Rosetta reference's in both lanes (`present_loop` green 71 white
  24, `d3d12_clear` green 95 white 0) and `cycles 20 ok`, both DXMT lanes with **162 `ok   ` checks** and 0 `FAIL`
  each (the FSR 3 check included), and G4 (geometric means 0.930, 0.913 and 1.130, FEX ÷ Rosetta; worst rows
  `mem_seq_read` 2.143 and `mem_seq_write` 2.011, as in sub-projects 1 and 2). `PASS orphans` last, after both runs.
  The Rosetta stack is in §7.
- **S7 Steam bridge: PASS.** `bridge/check.sh` in arm64 mode: its 8 `ok` lines with the aarch64 `steam.exe` (exit
  codes, arguments, the registry, child launchers; the work folder `steam-bridge ü` has a space and a non-ASCII
  letter). Then the probe, x64 under FEX with SMITE 2's `steam_api64.dll` and the bundle's `lsteamclient.dll` as
  `steamclient64.dll`: `PASS probe redaction`, `init: ok`, `steamid ok`, `persona ok`,
  `auth ticket: handle …, 234 bytes`, `auth ticket: callback, result 1`, `fault: caught` (an access violation after
  `SteamAPI_Init` still reaches SEH), exit 0. Reported, not gated: 552 x18 hits in the arm64 slice of Steam's
  `steamclient.dylib`, the count spec §2 read as constant tables after `ret`. `bundle.sh`'s lsteamclient asserts
  held (ARM64X metadata and the builtin marker, `lsteamclient.so` arm64 and exporting `__wine_unix_call_funcs`, its
  `Nt*` and `__wine_*` imports all exported by `ntdll.so`, `licenses/lsteamclient/`, and
  `disable-library-validation` on the loader).

The DXMT lanes' frame-time lines (4.7 / 4.0 ms ARM64EC lane, 5.0 / 4.0 ms x64 lane, arm64 / Rosetta) are not
display-paced this time; they are sub-project 2's D6 measure, not a gate here.

### 4. M1 msync (measured)

`x64-sync`'s timing rows, medians of batches in nanoseconds (cross-process wake is half a round trip, create/close one
create/use/close cycle), `WINEMSYNC=1` / `WINEMSYNC=0`:

| Run | Uncontended wait | Uncontended signal | Cross-process wake | Create/close |
|---|---|---|---|---|
| Task 4 (msync patch, before strict x18), `check.sh msync dxmt dxmt-present` | 66 / 8,049 | 46 / 6,684 | 3,990 / 9,650 | 29,140 / 31,758 |
| This acceptance, run 1 | 122 / 8,511 | 87 / 7,300 | 4,381 / 9,561 | 28,257 / 34,072 |
| This acceptance, run 2 | 143 / 8,453 | 100 / 7,270 | 4,554 / 9,545 | 28,346 / 34,055 |
| This bundle, `check.sh msync` alone, twice | 102 / 8,303; 141 / 8,637 | 77 / 7,880; 101 / 7,393 | 4,411 / 10,485; 4,586 / 9,992 | 28,641 / 34,181; 28,719 / 34,133 |

With msync the uncontended operations stay in the process and cost about 60 times less than a wineserver round trip;
a cross-process wake costs about half as much, and create/close about a sixth less. `pulse-event` (reported, not gated)
woke 4 of 4 waiters in every run here (3 of 4 once in Task 4, msync's known gap).

The in-process rows moved since Task 4: uncontended wait 102-143 ns here against 64-67 ns in Task 4's five runs, and
signal 77-101 against 45 and 46; the mode 0 rows and create/close are where they were. Between Task 4's bundle and this
one, patches 0004 (rewritten), 0016 and 0017 landed. Strict x18 adds two toggles to each syscall, which M2 measures
at 1.6 ns per round trip in the aarch64 lane, too little to explain 40-80 ns; the cause was not established (M1 is
measured, not gated).

### 5. M2 x18 (measured)

`arm64-x18path.exe time` (median ns per call over 100 batches of 10^4 calls, after a warm-up batch), with the bundle's
`wine` in the check's prefix, `WINEMSYNC=1`, three runs per build:

| Build | Syscall round trip (`NtQuerySystemTime`) | Unix call round trip (no-op) |
|---|---|---|
| A: patch 0004 as before (the mode on once per thread), Task 6 | 18.7 / 18.7 / 18.7 | 15.0 / 15.0 / 15.0 |
| B: strict x18 (0004 rewritten), Task 6 | 20.3 / 20.3 / 20.4 | 15.7 / 15.6 / 15.7 |
| B with the trap check without `dladdr` (0017), Task 6b | 22.0 (cold wineserver) / 20.3 / 20.3 | 17.2 (cold) / 15.7 / 15.7 |

Strict toggling costs **+1.6 ns per syscall round trip and +0.7 ns per unix call**, within spec §9's expected ≤ 4 ns.

### 6. The red runs (before each change)

- **Licences (Task 1)**, `licences_test.sh` on the bundle built from `main` before the sub-project: **46 `MISSING`**
  lines (the 22 copied files, the 9 `NOTICES.md` holders and the 15 `SOURCE` keys), then `FAIL licences_test`.
- **FreeType and gnutls (Task 2)**, `check.sh fonts-tls` on the bundle without the libraries:
  `font 0 0x0 dbu 0,0`, `dwrite families 0`, `schannel: 0x80090305`, `pfx: PFXImportCertStore: error 0x00000000`,
  `pfx certs 0`, `FAIL arm64-fonts-tls`; stderr had `Wine cannot find the FreeType font library` and
  `Failed to load libgnutls, secure connections will not be available.`
- **msync (Task 4)**, `check.sh msync` on the bundle before patch 0015:
  `FAIL msync: WINEMSYNC=1: 'msync: up and running.' 0 times in build/wine-arm64 check/msync-server-1.log`. All 14
  rows were `ok` against the plain wineserver, so the test itself was sound (wait 8,418, signal 7,191, wake 10,090,
  create/close 33,228 ns).
- **Strict x18 (Task 6)**, `check.sh x18` on the bundle with the old 0004: T1, T2 and T4 passed, then
  `T3: WINE_X18_SELFTEST=double_on: exit 0` and `FAIL x18: T3 exited 0, not 133 (SIGTRAP)`: a double enable became a
  Windows exception instead of killing the process. Task 6b's red: `nm -u signal_arm64.o` imported `_dladdr` (1, then
  0 with patch 0017).
- Also seen red: `licences_test.sh` on a copy without `licenses/lsteamclient/NOTE` (`MISSING lsteamclient/NOTE`);
  `steam-bridge` with `STEAM_COMPAT_CLIENT_INSTALL_PATH` set to an empty folder fails in 7.4 s with
  `Steam's steamclient.dylib not found at …`; `bundle.sh` stops on an x18 count that differs from `x18-allow.txt`
  and on an absolute rpath; `bridge/probe.sh --redact-self-test` fails on the old redaction in a UTF-8 locale.

### 7. The Rosetta stack unchanged (S6)

- `make test`: `Test run with 197 tests in 0 suites passed after 29.458 seconds.` (31 s).
- `sh dxmt/tests/build_test.sh`: 13 `ok`, 0 `FAIL` (the moved `fetch`'s checksum refusal included).
- `make bridge-check`: `PASS probe redaction`, then its 8 `ok` lines, 0 `FAIL` (7 s).
- `make dxmt-check`: `dxmt-check: all passed` in 6 min 14 s, 214 `ok` lines, 0 `FAIL`; its D3DMetal hazard
  comparison, run 1's failing line, passed on the Rosetta stack here.

The logs: `build/wine-arm64-ship-base-build.log` (Step 1, with timestamps), the two check logs above, and
`build/wine-arm64-ship-base-{make-test,build-test,bridge-check,dxmt-check}.log`.

### Found on the way

- **x64 JITs don't flip** (S4): FEX reads guest code as data and patch 0006 keeps guest RWX memory without the EC_CODE
  flag as host RW, so `MAP_JIT` isn't needed for them. Native ARM64 JITs keep patch 0006's flip (spec §8).
- **`lsteamclient.dll` is 57 MB**: Wine doesn't strip its builtin PE files. Noted for sub-project 5's packaging.
- **The Steam probe starts the Steam API as AppID 480** (Valve's Spacewar test app; `bridge/probe.sh` sets
  `SteamAppId=480`, as for the Rosetta bridge's probe), on the maintainer's logged-in Steam. It ran twice for this
  acceptance (once in each check run), with no game running.
- **`dxmt-present` needs no app in native full screen** on the main display: in Task 4 it failed with
  `winshot: no on-screen window titled present_loop` while a game was full screen (Wine's windows opened on the
  display's hidden desktop Space), with msync on or off, and passed once the game was closed. Nothing was full screen
  during this acceptance.
- **msync's server and clients must agree**: a client in the other mode exits with an `ERR` line hidden by
  `WINEDEBUG=-all`; `check.sh` therefore exports `WINEMSYNC=1` for every run, and the launcher will set it for games
  (sub-project 5).

### Pins and patches

`wine-arm64/deps.pins` (new; in the build stamp, not in any patch series):

| Source | Pin | SHA-256 / commit |
|---|---|---|
| FreeType 2.14.3 | `https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.xz` | `36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f` |
| gnutls 3.8.13 | `https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz` | `ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e` |
| nettle 4.0 | `https://ftp.gnu.org/gnu/nettle/nettle-4.0.tar.gz` | `3addbc00da01846b232fb3bc453538ea5468da43033f21bb345cb1e9073f5094` |
| GMP 6.3.0 | `https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz` | `a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898` |
| lsteamclient | `https://github.com/ValveSoftware/Proton.git`, `lsteamclient/` only | `db9e6ffbf24a95b104fb699dd62532c70a2f9a51` |

`wine-arm64/pins` (Wine 11.19 `455e3509…`, FEX `4ed80fd0…`) and `dxmt/pins` (DXMT `1fba8d25…`, LLVM 15.0.7,
llvm-mingw 20260908) are unchanged.

Patches added or changed by this sub-project:

- Wine **0004** `ntdll: Toggle the custom x18 ABI at every PE/unix boundary on macOS arm64.` (rewritten in place:
  strict toggling, the signal-handler wrapper, the trap pass-through, the invariant and the test hook; 163+, 35-).
- Wine **0015** `server: Add msync, CrossOver's in-process synchronization for macOS.` (15 files, 2,471+; Zebediah
  Figura and Marc-Aurel Zent's msync from CrossOver 26.3 on `cx/wine1117` with millia ampora's 8 commits; plus the
  one-time `shm_addrs` allocation, the wait-all fix in `linux_wait_objs`, and protocol 962 → 963).
- Wine **0016** `configure: Build dlls/lsteamclient, the Steam bridge.` (3 lines; the tree's `lsteamclient/` is linked
  in as `dlls/lsteamclient` and never enters a Wine patch).
- Wine **0017** `ntdll: Recognise the x18 toggle's trap by its address, not dladdr().` (a follow-up to 0004, added as
  its own patch because the in-place history rewrite was refused by the session's permission rules).
- lsteamclient **0001-0003**, `dappermint/winecx`'s three Mac fixes by millia ampora (`8d188ec0db` NOMINMAX and an X11
  keysym guard, `dada36ebab` `-lc++`, `6cfbd169a5` the two Proton-only client exports made optional), authors kept.

Wine 0001-0003 and 0005-0014, FEX 0001-0005 and DXMT 0001 are unchanged.
