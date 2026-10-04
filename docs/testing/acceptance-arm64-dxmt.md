# Native arm64 DXMT acceptance test (sub-project 2)

Spec: `docs/superpowers/specs/2026-10-03-macneutron-arm64-dxmt-design.md` §1, §8 and §10. Manual, on the
maintainer's Mac, with:
- the Developer ID identity and the provisioning profile for `net.authspot.macneutron.wine` (`wine-arm64/README.md`);
- MacNeutron's runtime-v4.7.3 installed, with its tarball cached in `~/Library/Caches/MacNeutron/` (G4's baseline and
  the D3DMetal reference);
- GPTK imported (the D3DMetal reference of `dxmt/check.sh`, in both arm64 lanes and in `make dxmt-check`);
- Screen Recording granted to the app that runs the check (System Settings › Privacy & Security › Screen Recording),
  for `winshot` in `dxmt-present`. Windows appear on the display during the check.

Record results at the bottom.

## Steps

1. **Clean build (D1):** with `MACNEUTRON_SIGN_IDENTITY` and `MACNEUTRON_PROVISIONING_PROFILE` set,
   ```
   rm -rf build/wine-arm64-src/dxmt build/wine-arm64-src/dxmt-build build/wine-arm64-src/dxmt-install \
     build/wine-arm64-src/llvm-arm64 build/wine-arm64-src/llvm-arm64-build build/wine-arm64-src/llvm-arm64.log build/wine-arm64
   time make wine-arm64
   codesign --verify --strict --deep build/wine-arm64/wine.app
   ```
   Wine's and FEX's trees stay (sub-project 1's acceptance rebuilt them from scratch); DXMT, the arm64 LLVM and the
   bundle are rebuilt.
2. **Checks (D2, D3, D4, D5's first part):** `make wine-arm64-check 2>&1 | tee build/wine-arm64-dxmt-acceptance.log`
   (outside `build/wine-arm64 check/`, which every run deletes). It also builds `dxmt dxmt-tests presenter
   dxmt-tests-arm64ec`. Copy `build/wine-arm64 check/dxmt-arm64ec.log` and `dxmt-x64.log` out before the next run.
3. **Frame times (D6):** `sh wine-arm64/check.sh dxmt-arm64ec`, then `sh wine-arm64/check.sh dxmt-x64`, for a second
   measurement per lane.
4. **The Rosetta stack (D5):** `make test`; `make dxmt-check`, its `ok` lines compared with the last Rosetta run's
   (measured numbers inside a line normalised); then `rm build/dxmt/version && make dxmt`.

## Pass criteria (spec §8)

| Gate | Pass |
|---|---|
| **D1 Build** | Step 1 builds DXMT for arm64 into spec §6's layout; `bundle.sh`'s assertions and `codesign --verify --strict --deep` pass |
| **D2 On screen** | `dxmt-present` passes: D3D11 and D3D12 windows on screen in both lanes, read by `winshot` against thresholds measured on the Rosetta stack, and 20 window cycles |
| **D3 ARM64EC correctness** | `dxmt-arm64ec` passes |
| **D4 x64 programs** | `dxmt-x64` passes, FSR 3 check included |
| **D5 No regressions** | Every sub-project 1 step still passes; `make test` and `make dxmt-check` pass; after `rm build/dxmt/version`, `make dxmt` rebuilds through `dxmt/llvm.sh`; the check ends with `PASS orphans` |
| **D6 Frame time** (measured) | Section 1's `info` lines from D3 and D4 recorded: `present_loop` frame time in both arm64 lanes and on our DXMT under Rosetta |

## Results

| Date | Mac | macOS | Wine | FEX | DXMT | Patches |
|---|---|---|---|---|---|---|
| 2026-10-03 | Mac17,8 (Apple M5 Pro, 48 GB) | 27.0.1 (26A434) | wine-11.19, `455e3509b98a6919fd4ad1def4803e08c41c03b2` | `4ed80fd07176dce976a7351f559d59a47b68cbae` (2026-08-26) | fork `1fba8d25b5e29ab49012d633676a6b0d4b3b96c5` (`dxmt/pins`), LLVM 15.0.7 | 14 Wine (`patches/wine`), 5 FEX (`patches/fex`), 1 DXMT (`patches/dxmt`) |

Repository at `f1389ca` (the build inputs are the pins and patches in it). **D1-D5 pass and D6 is measured**, so
spec §1's done-when holds. The full check took **14 min 51 s** (891 s, `make wine-arm64-check` from start to end;
its prerequisites took seconds, as they were built).

### 1. Clean build (D1)

Step 1's `make wine-arm64` took **2 min 52 s** (`time`: 2:51.64). It fetched DXMT at the pin, applied the DXMT patch,
re-ran Wine's and FEX's builds, which were up to date (5 s together), and built the arm64 LLVM 15.0.7 (128 s), DXMT
for ARM64X (27 s) and the arm64 `dxil-probe` and `dxil-translate` (2 s), then bundled (3 s) and signed (5 s); stage
times are from the logs' timestamps.
It ended with `wine-arm64: built …/build/wine-arm64/wine.app`, so `bundle.sh`'s assertions held (builtin markers,
`winemetal.so` present, `DXMT/version` matching the tree).
`codesign --verify --strict --deep build/wine-arm64/wine.app`: exit 0.

Layout under `wine.app/Contents/Resources/` (spec §6):

```
DXMT/                          COPYING.LIB  LICENSE  LICENSE.OLD  aarch64-windows/  version
DXMT/aarch64-windows/          d3d10core.dll (1.9 MB)  d3d11.dll (8.1 MB)  d3d12.dll (4.7 MB)  dxgi.dll (2.4 MB)
                               dxmt-replay.exe (2.0 MB)
lib/wine/aarch64-windows/      winemetal.dll (124 KB)
lib/wine/aarch64-unix/         winemetal.so (22 MB, Mach-O arm64, minos 27.0)
```

`DXMT/version`: `1fba8d25b5e29ab49012d633676a6b0d4b3b96c5+63a4969e01ba` (the pin, then the first 12 characters of the
series hash: an applied build).

### 2. Bring-up (development, before the gates)

- **DXMT loaded first time in both lanes**, with no DXMT patch beyond 0001. `d3d12_null` with `WINEDEBUG=+loaddll`:
  `DXGI.DLL` and `d3d12.dll` loaded native from system32 and `winemetal.dll` builtin; exit 0; its 18 `null` lines are
  identical, line for line, to D3DMetal's reference run. ARM64EC: 1.5 s on the first DXMT launch after the bundle
  clone, 0.50 s after that. x64 under FEX (`libarm64ecfex.dll` loaded): 0.57 s first, 0.50-0.51 s after, the same
  18 lines. So x64 code reached DXMT's ARM64EC code through FEX, COM vtable calls included.
- **Before Wine patch 13**, `present_loop` stopped at DXMT's own message, `Failed to create metal view, it seems like
  your Wine has no exported symbols needed by DXMT.` (exit 3). With patch 13 DXMT presented (`frames 3000`), but every
  window was off screen until Wine patch 14 (below). Spec §1's fallbacks were not needed.

### 3. `make wine-arm64-check` (D2, D3, D4, D5)

Printed, in order (`build/wine-arm64-dxmt-acceptance.log`; G4's table follows `PASS g4-bench` and is summarised below):

```
PASS mode_test
PASS profile_test
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
info QueryPerformanceFrequency 10000000 Hz; RDTSC ran at 1000000059 Hz over 204.6 ms
info CPUID says 1000000000 Hz; measured / CPUID = 1.0000
PASS g1-unaligned
PASS g2-litmus
info TSO on: 8 s
info TSO off: litmus MP forbidden=8594 runs=10000000
info TSO off: litmus LB forbidden=0 runs=10000000
info TSO off: litmus 2+2W forbidden=1 runs=10000000
info TSO off: litmus IRIW forbidden=996 runs=10000000
info TSO off: 6 s
PASS viewec
PASS wxflip
info 19 trace lines
PASS g5-jit
info x64-bench: 0 flips after the marker
PASS dxmt
PASS dxmt-present
info arm64ec present_loop: pixels 962560 green 71 white 24
info arm64ec d3d12_clear: pixels 962560 green 95 white 0
info x64 present_loop: pixels 962560 green 71 white 24
info x64 d3d12_clear: pixels 962560 green 95 white 0
info arm64ec present_loop cycles=20: cycles 20 ok
PASS dxmt-arm64ec
info arm64 mode: …/build/wine-arm64 check/Application Support/wine.app
info D3D11 frame time: arm64 8.320 ms, rosetta 8.330 ms
info pipeline creation: timing 7.7 ms cold, timing 3.0 ms warm
info dxmt-arm64ec: 168 s
PASS dxmt-x64
info arm64 mode: …/build/wine-arm64 check/Application Support/wine.app
info D3D11 frame time: arm64 8.321 ms, rosetta 8.329 ms
info pipeline creation: timing 12.3 ms cold, timing 3.0 ms warm
info dxmt-x64: 166 s
PASS g4-bench
…
PASS orphans
```

Step times (from the step logs): everything up to `g5-jit` 1 min 3 s; `dxmt` 4 s; `dxmt-present` 1 min 54 s;
`dxmt-arm64ec` 168 s; `dxmt-x64` 166 s; `g4-bench` 6 min 5 s.

- **`dxmt`:** the front ends in system32 are the bundle's and carry no builtin marker, `winemetal.dll` carries it, and
  `DXMT/version` names the pin.
- **D2 On screen: PASS.** `winshot`'s shares (percent of the window's 1280x752 pixels: green 60-95, and all channels
  above 200) are the Rosetta reference's exactly, in both lanes:

  | Program | Rosetta reference (our DXMT, installed runtime) | ARM64EC | x64 under FEX | Minimum in `dxmt-present` |
  |---|---|---|---|---|
  | `present_loop 1280 720 1280 720 3000 0` (D3D11) | green 71, white 24 | green 71, white 24 | green 71, white 24 | green 56, white 12 |
  | `d3d12_clear 3000` (D3D12) | green 95, white 0 | green 95, white 0 | green 95, white 0 | green 80 |

  Both programs printed their completion lines (`frames 3000,`, `presented 3000/3000 frames`). The 20 window cycles
  (ARM64EC, `present_loop 640 360 640 360 60 0 cycles=20`, both teardown orders) printed `cycles 20 ok` and exited 0.
  The reference was measured in dark mode on the 1x main display.
- **D3 ARM64EC correctness: PASS. D4 x64 programs: PASS.** Each lane's log
  (`build/wine-arm64-dxmt-acceptance-arm64ec.log`, `-x64.log`) ends `dxmt-check: all passed` with **162 `ok   `
  checks**, 0 `FAIL`, 0 skipped, plus the probe's 31 `ok <shader>` lines (193 `^ok` lines). 162 is `dxmt/check.sh`'s
  170 checks less the 8 that arm64 mode skips or doesn't grade: the `MACNEUTRON_LOG` check and section 10's six
  (launcher features, sub-project 5), and section 1's frame-time grade (an `info` line instead, D6). Both lanes give the
  same set of `ok` lines, measured numbers aside, and every comparison with D3DMetal (on the installed runtime, under
  Rosetta) holds as exactly as on the Rosetta stack. Both lanes print
  `ok   the FSR 3 swapchain proxy presents on our DXMT`, which `dxmt-x64` requires.
- **Sub-project 1's steps** all pass again: G1 (`g1-*`), G2's default run (`litmus MP/LB/2+2W/IRIW forbidden=0`, 8 s;
  the `FEX_TSOENABLED=0` control saw MP 8,594 and IRIW 996, so the test still detects violations), G3's four features,
  G5 (0 flips after FEX's initialization; the positive control traces 19 lines), and the G4 report: geometric means
  single-threaded 0.915, multithreaded 0.909, call-heavy 1.178 (FEX ÷ Rosetta; worst rows `mem_seq_read` 2.103 and
  `mem_seq_write` 1.996, as in sub-project 1). The layout-sensitive rows moved as sub-project 1's acceptance warned:
  `branch_random` 1.332 (0.966 there) and `indirect_calls` 0.374 (0.857 there; Rosetta's time doubled).
- **Orphans:** the last line is `PASS orphans`, here and after both runs in §4. A `pgrep` for `wine`, `wineserver` and
  `macneutron` after the last run found nothing.

### 4. D6 Frame time (measured)

Section 1 of `dxmt/check.sh`: `present_loop 1280 720 0 0 600 0` (Present's sync interval 0), best of three runs, our
DXMT on the arm64 runtime against our DXMT under Rosetta, in milliseconds per frame:

| Run | ARM64EC lane: arm64 / Rosetta | x64 lane: arm64 (FEX) / Rosetta |
|---|---|---|
| Task 7, first run | 7.425 / 4.877 | 8.322 / 8.306 |
| Task 7, re-run | 8.321 / 8.330 | — |
| This acceptance, `make wine-arm64-check` | 8.320 / 8.330 | 8.321 / 8.329 |
| This acceptance, `check.sh dxmt-arm64ec`, `check.sh dxmt-x64` | 8.319 / 8.329 | 8.321 / 8.327 |

**These numbers look display-paced, not CPU-bound:** apart from Task 7's first ARM64EC run, every value is 8.31-8.33 ms,
that is 120 frames per second, on both stacks and in both lanes, although the program asks for no vsync. The Rosetta
stack's own `make dxmt-check` in §5 also read 8.29-8.34 ms for both our DXMT and DXMT 0.80 (its check's comment records
4.7 and 5.7 ms in an earlier setup). The window sat on the 1x main display, which reports 144 Hz (the built-in panel is
120 Hz, and a third display 75 Hz); what holds presentation at 120 Hz was not established. So D6 says that both lanes
keep up with that rate as the Rosetta stack does; it is not a comparison of the stacks' CPU cost. Frame-time parity is
sub-project 6's (SMITE 2).

### 5. The Rosetta stack unchanged (D5)

- `make test`: `Test run with 197 tests in 0 suites passed after 32.389 seconds.`
- `make dxmt-check`: `dxmt-check: all passed` in 5 min 43 s, 214 `ok` lines (170 checks, 31 probe lines and 13
  `build_test.sh` lines), 0 `FAIL`. Against the Rosetta run recorded before Task 7 (sorted `ok` lines), one line differs
  only in its measured numbers: `compressed targets clear at least 3x cheaper (47.9 against 217.3 us)` against
  `(49.2 against 217.6 us)`. With digits normalised the two sets are identical.
- `rm build/dxmt/version && make dxmt`: `dxmt: building DXMT 1fba8d25…` then `dxmt: built …/build/dxmt (1fba8d25…)`
  in 33 s, with no LLVM build line (the x86_64 LLVM is reused through `dxmt/llvm.sh`); `dxil-probe` and
  `dxil-translate` were rebuilt (new timestamps).
- Host differences: none recorded. Every exact comparison with D3DMetal held in both arm64 lanes, so no
  `-ffp-contract=off` patch was needed (spec §11), and the hazard checks pass on Arm's weaker memory model.

### Found during bring-up

- **Windows off screen (Wine patch 14).** The bundle has no FreeType, so no font can be measured. `get_text_metr_size()`
  in win32u then left the caller's `TEXTMETRICW` unset, and `normalize_nonclientmetrics()` read caption and menu
  heights from stack garbage: every top-level window (explorer's, notepad, `present_loop`) came out about 32875x32778,
  and Cocoa clamped them off screen, where `screencapture` couldn't image them. Patch 14 reports a height of -1 and
  no external leading in that case, as when the font can't be selected.
- **The runtime still has no FreeType.** Every process prints Wine's FreeType warning and GDI text is missing until
  sub-project 3 bundles FreeType. Direct3D is unaffected: every check above passed with it.

### Patches added by this sub-project

- DXMT 0001 `d3d12: Read the ARM64 counter on arm64 builds.`: `d3d12_stats.cpp` reads `cntvct_el0` on ARM64 instead of
  `__rdtsc`, the only file that didn't compile for ARM64X.
- Wine 0013 `winemac.drv: Export macdrv_functions so DXMT can present.`: the 10-slot table DXMT looks up, a client
  surface per window, and the Metal layer's present report (from CodeWeavers' `d3dmetal.c` and `d3dmetal_objc.m`, via
  dappermint's port).
- Wine 0014 `win32u: Don't read unset text metrics when no font can be measured.`: the off-screen windows above.
