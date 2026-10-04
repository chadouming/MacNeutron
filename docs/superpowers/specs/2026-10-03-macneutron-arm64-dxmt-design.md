# MacNeutron — Native arm64 stack, sub-project 2: DXMT for arm64

- **Date:** 2026-10-03 (revised the same day after an adversarial review)
- **Status:** Implemented 2026-10-03; gates D1–D5 pass and D6 is measured: `docs/testing/acceptance-arm64-dxmt.md`. Written for autonomous execution: the maintainer asked to carry this sub-project through design, plan and implementation without approval stops ("keep going until it's working"); every decision taken on their behalf is in the decisions table and the execution ledger.
- **Builds on:**
  - `2026-10-02-macneutron-native-arm64-design.md` (sub-project 1: the entitled, 4K-page `wine.app`, FEX, `wine-arm64/`)
  - `2026-09-28-macneutron-dxmt-fork-design.md` (our DXMT fork, `dxmt/` build, `dxmt/check.sh`)
- **Evidence:** the exploration brief of 2026-10-03, kept in `docs/research/2026-10-03-arm64-dxmt/` with the draft Wine patch and the probes.
- **Scope:**
  - **In:**
    - DXMT built for ARM64X (PE side) with an aarch64 `winemetal.so` and an arm64 LLVM 15, from the fork pin plus committed patch files;
    - Wine patch 13: the `macdrv_functions` table DXMT looks up, and the present report that keeps the client view visible;
    - DXMT inside the signed `wine.app`;
    - arm64 builds of the DXIL host tools;
    - ARM64EC builds of the D3D test programs; `dxmt/check.sh` able to run our DXMT on the arm64 runtime; new `check.sh` steps for both lanes (ARM64EC, and x64 under FEX) and an on-screen check.
  - **Out:**
    - the MetalFX presenter, the launcher's second runtime, shader pre-caching from the launcher (sub-project 5);
    - SMITE 2 and frame-time parity (sub-project 6);
    - 32-bit and D3D9 (sub-projects 7, 8);
    - licence files for Wine and FEX inside the bundle, notarization (sub-projects 3, 5);
    - pushing anything to `chadouming/dxmt` or elsewhere.

## 1. Goal

Direct3D 10/11/12 programs running in the arm64 runtime draw through our DXMT fork, built natively for arm64, with no Rosetta in the runtime. Both kinds of Windows program work: ARM64EC builds (native code) and x64 builds (under FEX).

**Sub-project 2 is done when** §8's gates D1–D5 pass on the maintainer's Mac, D6 is measured, and the result is recorded in `docs/testing/acceptance-arm64-dxmt.md`:
- `make wine-arm64` builds DXMT for arm64 into `wine.app`, and the bundle still passes `codesign --verify --strict --deep`;
- D3D11 and D3D12 programs put pixels on screen from the arm64 runtime, in both lanes;
- every check `dxmt/check.sh` makes of our DXMT passes with our DXMT on the arm64 runtime, in both lanes, against the same fixed values and the same D3DMetal reference;
- the Rosetta stack is unchanged.

### Decisions

| Decision | Choice |
|---|---|
| How DXMT changes are carried | **Patch files on top of the shared fork pin** (`dxmt/pins` `DXMT_COMMIT`), in `wine-arm64/patches/dxmt/`, applied with `git am` in the arm64 build's own DXMT clone. Same model as Wine and FEX. No pin bump, so the Rosetta stack doesn't rebuild; no push to `chadouming/dxmt`. Folding the patches into the fork is a maintainer step for later. |
| PE flavour | ARM64X, from DXMT's own `build-arm64ec.txt` (`-marm64x`, already in our pin). One DLL serves ARM64EC and x64 callers (inferred: Wine's own ARM64X DLLs already serve the x64 programs of gate G1; DXMT's have never loaded here, §11). |
| LLVM | LLVM 15.0.7 (`dxmt/pins` `LLVM_TAG`) built for arm64, in its own install folder, from the shared `build/dxmt-src/llvm-project` source. |
| Wine tree DXMT links against | Sub-project 1's build tree, `build/wine-arm64-src/wine-build` (`-Dwine_build_path`). Wine 8.16 isn't needed. |
| Window binding | Wine patch 13 ports the CodeWeavers `d3dmetal.c` table (as dappermint's `arm64-1117` enabled it on aarch64) plus the `WineMetalLayer` present report. Fallbacks, in order, if nothing draws: (1) mtld3d PR #994's approach: patch 13's stand-in struct also carries the window's client surface (offset 40), a DXMT patch calls win32u's exported `client_surface_present` (found with `dlsym`) after each present, and the layer is a plain `CAMetalLayer`; (2) cyyever's direct view, without client surfaces. |
| Where DXMT lives | Inside `wine.app`, signed with it: `winemetal.so` must sit next to `winemac.so` (its rpath is `@loader_path`), and nothing can be added to a signed bundle later. |
| How the arm64 checks are written | **`dxmt/check.sh` itself, in an arm64 mode** (§7): its `run()` sends our DXMT's runs to the arm64 runtime and leaves D3DMetal's runs on the installed runtime. Every check, expected string and tolerance stays as it is, and there is one copy of them. |
| Reference for checks that compare against D3DMetal | D3DMetal on the installed runtime (under Rosetta), exactly as `dxmt/check.sh` runs it today. |
| Check target | The DXMT steps join `make wine-arm64-check`. `make dxmt-check` takes about 6 minutes on Rosetta; the two arm64 lanes roughly triple the check's ~7.5 minutes. The real time is recorded at D3. |
| Time box | Three weeks from the start of implementation, as for sub-project 1. The on-screen gate (§8, D2) is the risk; its fallbacks are named above. |

## 2. Evidence (verified 2026-10-03 on the M5 Pro, macOS 27.0.1, unless marked)

- **DXMT builds for ARM64X today**, apart from one file: `src/d3d12/d3d12_stats.cpp` includes `<x86intrin.h>` and calls `__rdtsc` (our fork commit `d245c13`). With an ARM64 counter in its place, 108 of 108 PE objects compile; a full setup + compile + install takes 26 s. Upstream's arm64ec CI never enables D3D12, which is why nobody hit it.
- **arm64 LLVM 15 builds in 153 s** with `dxmt/build.sh`'s flags plus `-DCMAKE_OSX_ARCHITECTURES=arm64 -DLLVM_HOST_TRIPLE=arm64-apple-darwin` (125 MB, 76 static libraries).
- **`winemetal.so` links** for arm64 (22 MB stripped, `minos 27.0`). The only Wine symbol it imports is `NtSetEvent`; `winemac.so` and `ntdll.so` are loaded through `@rpath` = `@loader_path/`, `@loader_path/../../`. Loaded from outside the bundle it fails unless `winemac.so` is already loaded.
- **Wine 11.19's winemac has no `macdrv_functions`** (it exists only in CodeWeavers' tree) and builds with `-fvisibility=hidden`. DXMT's lookup (`winemetal_unix.c:1713-1757`) then finds no view, and the swap chain calls `abort()` (`src/d3d11/d3d11_swapchain.cpp:137-140`, `src/d3d12/d3d12_swapchain.cpp:179-181`). Wine's `abort()` exits without flushing stdio, so a program's earlier `printf` lines are lost too.
- **DXMT reads a 10-slot table** (`struct macdrv_functions_t`) and calls 5 of its slots: `get_win_data`, `release_win_data`, `macdrv_view_create_metal_view`, `macdrv_view_get_metal_layer`, `macdrv_view_release_metal_view`. It reads `client_cocoa_view` at offset 24 of what `get_win_data` returns, with no NULL check; Wine 11.19's own struct has `client_view` at offset 16.
- **Without a present report the window stays blank:** win32u never refreshes an unregistered client surface (`win32u/window.c:397-414`), and the first GDI flush hides the view (`surface.c:123-131`) (inferred from the source; CrossOver needed the same report). Nothing is logged and `Present` still succeeds, so only the screen shows it.
- **The draft Wine patch 13** (5 files, +135/−1) applies to sub-project 1's tree, builds, and exports `_macdrv_functions`; a `dlsym` probe fails on the stock library and passes on the patched one. **It has never been run with DXMT.**
- **DXMT's DLLs have never loaded on this stack.** All 19 D3D12 test programs plus `present_loop` (20) build as ARM64EC with no source changes, and an ARM64EC D3D12 program reached device creation in 1.9–2.4 s (the same x64 program under FEX in 2.2–2.7 s), but those runs used Wine's built-in `d3d12.dll`, which then fails (`0x80004005`, built without Vulkan).
- **Screen capture works here:** `CGPreflightScreenCaptureAccess()` returns true for the process tree that runs the checks, and windows are listed by title.
- **Metal API validation works under the hardened runtime:** a probe signed `adhoc,runtime` with `MTL_DEBUG_LAYER=1` printed `Metal API Validation Enabled` and reported a deliberate error.

## 3. Architecture

```
 Game process (native arm64, 4K pages, wine.app/Contents/MacOS/wine)
 ┌───────────────────────────────────────────────────────────────────────┐
 │ ARM64EC game code ─┐                   x64 game code ── FEX ─┐         │
 │                    ▼                                         ▼         │
 │ DXMT front ends (ARM64X, prefix system32): d3d11, d3d10core, dxgi, d3d12 │
 │                    │                                                   │
 │ winemetal.dll (ARM64X, builtin, in the bundle) ── unix call ─┐          │
 │ winemetal.so (arm64, in the bundle, airconv + LLVM 15) ◄─────┘          │
 │      │ dlsym("macdrv_functions")                                       │
 │ winemac.so (Wine patch 13: table + present report) ── Metal / AppKit   │
 └───────────────────────────────────────────────────────────────────────┘
```

## 4. DXMT build

**Source.** `wine-arm64/build.sh` gets a DXMT step between FEX and bundling:
- **Clone:** `fetch_dxmt`, modelled on `fetch_fex`: `git init` of `build/wine-arm64-src/dxmt`, `fetch --depth 1` of `DXMT_COMMIT` from `DXMT_REPO`, `checkout -b macneutron FETCH_HEAD`, `submodule update --init --depth 1`, then `patch_tree` with `wine-arm64/patches/dxmt/*.patch`. One local branch, so `build_mode` gives pinned/applied/reapply/development exactly as for Wine and FEX; the development test covers all three trees. The shared `build/dxmt-src/dxmt` clone is never touched.
- **Series:** `dxmt_series = series_of dxmt/pins wine-arm64/patches/dxmt/*.patch`, computed the same way by `build.sh` and `export.sh` (whose `export_tree` takes the pins file as an argument), so a `DXMT_COMMIT` bump re-applies the tree.
- **LLVM:** a new sourced file, `dxmt/llvm.sh`, holds `build_llvm <arch> <install folder>`: the shared `build/dxmt-src/llvm-project` source (cloned into a `.tmp` folder and moved into place, so an interrupted clone is never taken for a source tree) and `dxmt/build.sh`'s flags with `-DCMAKE_OSX_ARCHITECTURES=<arch> -DLLVM_HOST_TRIPLE=<arch>-apple-darwin`. `dxmt/build.sh` calls it for x86_64 into `build/dxmt-src/llvm-release` (behaviour unchanged); `wine-arm64/build.sh` for arm64 into `build/wine-arm64-src/llvm-arm64`. Built once per install folder, as today; a change of `LLVM_TAG` needs the install folder removed, as today. It uses the caller's `die`; `dxmt/lib.sh` is not sourced by `wine-arm64/` (its `die` would relabel every message).
- **Meson:**
  ```
  meson setup <build> <dxmt> --cross-file build-arm64ec.txt --buildtype release --strip --prefix <install>
    -Dwine_builtin_dll=false -Denable_d3d12=true -Dnative_llvm_path=<llvm-arm64> -Dwine_build_path=<wine-build>
  ```
  with the llvm-mingw `bin` first on `PATH` (already so in `wine-arm64/build.sh`), and `MACOSX_DEPLOYMENT_TARGET=27.0`. `wine_builtin_dll=false` keeps the front ends native; DXMT's own build marks `winemetal.dll` builtin regardless (asserted, §6).
- **Tools:** `meson` joins the required tools, plus the Metal Toolchain check from `dxmt/build.sh`.
- **Stamp:** also covers `dxmt/pins`, `wine-arm64/patches/dxmt/*`, `dxmt/llvm.sh`, `dxmt/tools/dxil-probe.cpp` and `dxmt/tools/dxil-translate.mm`.
- **Host tools:** arm64 `dxil-probe` and `dxil-translate`, with `dxmt/build.sh`'s sources and flags but `-arch arm64`, the arm64 LLVM and the arm64 build's `libairconv.a` and `libDXBCParserNative.a`, built with `/usr/bin/clang++` (llvm-mingw's `clang++` is first on `PATH` and can't build Mac code), into `build/wine-arm64/` (outside the bundle).

**DXMT patches** (`wine-arm64/patches/dxmt/`):

| # | Patch | Why |
|---|---|---|
| 1 | `d3d12_stats.cpp` includes `util_bit.hpp` (after `d3d12_stats.hpp`, which brings `<cstdint>`) and reads the counter through one function: `__rdtsc` with `<x86intrin.h>` under `#if defined(DXMT_ARCH_X86)`, `cntvct_el0` under `#elif defined(DXMT_ARCH_ARM64)`, `#error` otherwise. Its calibration against QueryPerformanceCounter already adapts to any rate. The x86 build compiles as before. | The only compile error on arm64 (`DXMT_ARCH_*` is defined only in `util_bit.hpp`, which the file didn't include) |

Further patches come only from failures seen during bring-up, each with the failure in its message.

## 5. Wine patch 13: window binding

One Wine commit in sub-project 1's development tree, exported as the next Wine patch. Its message names its sources: CodeWeavers' `dlls/winemac.drv/d3dmetal.c` (Brendan Shanks, LGPL-2.1+) and `d3dmetal_objc.m` (`WineMetalLayer`), as published in `athei/wine` branch `cx-26-patched`, and `dappermint/winecx` `713015fa9f`, `13e6a88a02`, `565f6386b7` (LGPL).

- **`window.c`:** a `DECLSPEC_EXPORT` 10-slot `macdrv_functions` table in DXMT's slot order (§2), and a stand-in struct whose `client_cocoa_view` is at offset 24 (`C_ASSERT`). `get_win_data` creates a client surface for the window, records it on the window's data, and returns with the window lock held; `release_win_data` unlocks. A window from another process gets a NULL view, so DXMT stops at its own message, not a NULL dereference. Surfaces are freed when the window is destroyed, after the lock is released.
- **`cocoa_window.m`:** the Metal layer posts `CLIENT_SURFACE_PRESENTED` from `nextDrawable`, for DXMT's views only.
- **`event.c`, `macdrv.h`, `macdrv_cocoa.h`:** the event handler calls `client_surface_present` for a surface the window still lists.

The draft in the research folder is the starting point. Known limits it shares with CrossOver: a `nextDrawable` during window close can queue a pointer to a freed surface, now guarded: the handler presents only surfaces the window still lists (§7's window cycles exercise it); every frame posts an event; the lock is held across main-thread round trips; child-window swap chains need dappermint's `f77c272bbe` (deferred until a game needs it; the handler presents a toplevel window's surfaces only). Still open, also inherited: `nextDrawable` runs on DXMT's thread and reads the content view and its client surface without synchronisation, while the main thread frees that view when the window is destroyed (`macdrv_dispose_view`); closing it needs the view to hold its own reference, or a lock, between the two threads.

## 6. The bundle

`bundle.sh` copies DXMT in before signing, so `macho()` signs `winemetal.so` with everything else:

| Path under `wine.app/Contents/Resources/` | Contents | Wine builtin marker |
|---|---|---|
| `lib/wine/aarch64-windows/winemetal.dll` | ARM64X | present (asserted) |
| `lib/wine/aarch64-unix/winemetal.so` | arm64, `minos 27.0` (asserted present) | — |
| `DXMT/aarch64-windows/` | `d3d11.dll`, `d3d10core.dll`, `dxgi.dll`, `d3d12.dll`, `dxmt-replay.exe` (ARM64X) | absent (asserted) |
| `DXMT/` | `COPYING.LIB`, `LICENSE`, `LICENSE.OLD` from the clone; `version` | — |

**`DXMT/version`** is one token, as the Rosetta stack's consumers read it: `<DXMT_COMMIT>+<first 12 characters of the series hash>` for a pinned or applied build, `<DXMT_COMMIT>+dev` for a development build. `bundle.sh` asserts that the part before `+` is `DXMT_COMMIT` and that `DXMT_COMMIT` is an ancestor of the tree's `HEAD` (`git merge-base --is-ancestor`), so a stale tree can't pass.

**In a prefix** (done by `check.sh` here; by the launcher in sub-project 5): copy `DXMT/aarch64-windows/*` into `drive_c/windows/system32/`, and use the overrides `dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b` (`GraphicsBackend.swift:35`'s DXMT value). No syswow64 part until sub-project 8.

## 7. Tests and checks

**Test programs.**
- **ARM64EC lane:** a Makefile target, `dxmt-tests-arm64ec`, builds the 19 `dxmt/tests/d3d12_*.cpp` and `presenter/tests/present_loop.c` with `arm64ec-w64-mingw32-clang++`/`-clang` (the x64 rules' flags and libraries) into `build/dxmt-tests-arm64ec/`, keeping the basenames (`dxmt/check.sh`'s expected strings contain them).
- **x64 lane:** the existing `build/dxmt-tests/` and `build/presenter/present_loop.exe`, under FEX.
- **Window cycles:** `present_loop` gains `cycles=N` (default 1): N rounds in one process of window, device and swap chain, then the frames. Odd rounds release the device objects and then call `DestroyWindow`; even rounds call `DestroyWindow` while the swap chain still holds the view, then release (the order §5's race needs). Each round then pumps messages until the queue is empty; the program ends with `cycles N ok`. Nothing changes for existing callers.
- **Screen helper:** `wine-arm64/tools/winshot.c`, a native Mac program (`/usr/bin/clang`, CoreGraphics and ImageIO), built by `wine-arm64-tests`. `winshot <window title> <png>` stops with a message naming System Settings › Privacy & Security › Screen Recording when `CGPreflightScreenCaptureAccess()` is false. Otherwise it waits up to 30 s for an on-screen window with that title, waits 2 s more, captures it with `screencapture -x -o -l<id>`, draws the image into an sRGB bitmap (so the display's colour profile doesn't move the values), and prints `pixels <n> green <pct> white <pct>`: the share of pixels with green 60–95 (the test programs' background green is 0.3, 77 in sRGB) and with every channel above 200. Before any threshold gates D2, `winshot` is run on `present_loop` on the installed Rosetta runtime (a window known to present) and its shares are recorded; the thresholds in `dxmt-present` come from that measurement, with margin.

**`dxmt/check.sh` arm64 mode.** Set when `MACNEUTRON_ARM64_APP` names a `wine.app`; also read: `MACNEUTRON_ARM64_PREFIX` (a booted prefix with the front ends in system32, FEX registered and the crash dialog off), `MACNEUTRON_ARM64_TESTS` (the folder holding the 19 programs), `MACNEUTRON_ARM64_LOOP` (`present_loop.exe`), `MACNEUTRON_ARM64_TOOLS` (the arm64 `dxil-probe` and `dxil-translate`). `DXMT_CHECK_WORK` replaces the work folder in either mode (default unchanged). In arm64 mode:
- `run` sends our DXMT's runs (tool `ours`, backend `dxmt`) to the bundle's `wine` with `WINEPREFIX` = a clone of `MACNEUTRON_ARM64_PREFIX` per tool and lane (`cp -cR`, made at setup after `wineserver -w` on the template), the DXMT overrides, the same `DXMT_SHADER_CACHE_PATH` rule (fresh per run unless `CACHE` names one), the same 120 s watchdog and the same `2>&1` capture. Program paths under `$TESTS` map to `MACNEUTRON_ARM64_TESTS`, `$LOOP` to `MACNEUTRON_ARM64_LOOP`; `dxmt-replay.exe` is the bundle's.
- D3DMetal's runs (backend `d3dmetal`) stay on the installed runtime through the launcher, as now.
- Tool `x86` runs our DXMT under Rosetta (the `ours` clone). Section 1 compares `ours` (arm64) with `x86`, best of three each, and prints both as `info` lines, ungraded (gate D6); its "ran our d3d11.dll" check compares the bundle's front end with the prefix's.
- `dxil-probe` and `dxil-translate` come from `MACNEUTRON_ARM64_TOOLS`.
- Skipped, as launcher features (sub-project 5): `MACNEUTRON_LOG` naming the unsupported op (`:421-424`) and section 10 (`:729-744`).
- At exit, and on TERM or INT, the lanes are stopped and `wineserver -k` runs for each arm64 prefix (a trap: `check.sh`'s step stop reaches `dxmt/check.sh` but not its lanes).
- Everything else, including the expected strings and every D3DMetal comparison, runs unchanged. Rosetta mode (no `MACNEUTRON_ARM64_APP`) behaves exactly as before.

**One change for both modes:** `invalid` prints `off` when a run lacks the `Metal API Validation Enabled` line, so a run where validation never switched on can't count as 0 errors.

**New `wine-arm64/check.sh` steps** (in this order, after `g5-jit` and before `g4-bench`):

| Step | Content |
|---|---|
| `dxmt` | Copies the front ends into the prefix; turns the crash dialog off (`HKCU\Software\Wine\WineDbg` `ShowCrashDialog` = 0, so a crash ends instead of waiting for the watchdog); checks the markers and `DXMT/version` as `bundle.sh` does; waits for the prefix's server to exit so later clones get a saved registry |
| `dxmt-present` | On screen, both lanes: `present_loop 1280 720 1280 720 3000 0` and `d3d12_clear 3000`, each read by `winshot` against the measured thresholds, and each printing its completion line (`frames 3000`, `presented 3000/3000 frames`). ARM64EC lane only: `present_loop 640 360 640 360 60 0 cycles=20` prints `cycles 20 ok` and exits 0 |
| `dxmt-arm64ec` | `dxmt/check.sh` in arm64 mode with the ARM64EC programs: `dxmt-check: all passed` |
| `dxmt-x64` | `dxmt/check.sh` in arm64 mode with the x64 programs under FEX: `dxmt-check: all passed`, and its FSR 3 check ran (`ok   the FSR 3 swapchain proxy presents on our DXMT`, not the skip line), which needs SMITE 2 installed in Steam's default library (its `amd_fidelityfx_dx12.dll` is read there) |

- **Dependencies:** the three `dxmt-*` steps pull in `dxmt` (a new `NEEDS_DXMT` list) and join `NEEDS_FEX`; all four join `NEEDS_PREFIX` (`dxmt` itself needs no FEX). With FEX registered in every lane, as in a game's prefix, partial and full runs run the same way.
- **Clean-up:** `runtime_pids` also lists the Rosetta tool clones `dxmt/check.sh` makes, whose work folders live under `check.sh`'s own (`$WORK/dxmt-arm64ec`, `$WORK/dxmt-x64`), so the orphan line covers them.
- **Failure output:** a failing `dxmt-arm64ec`/`dxmt-x64` step's FAIL line gives the number of `FAIL` lines and the first one, or, when `dxmt-x64`'s FSR 3 line is missing, `dxmt/check.sh`'s skip line (SMITE 2 isn't installed). A failing step stops the run, as for sub-project 1's steps; `check.sh <step>` runs one alone.
- **One target:** `wine-arm64-check` gains the prerequisites `dxmt dxmt-tests presenter dxmt-tests-arm64ec` (`dxmt` builds the x86_64 LLVM if it's missing).

## 8. Gates

| Gate | Pass |
|---|---|
| **D1 Build** | `make wine-arm64`, with `build/wine-arm64-src/dxmt`, `build/wine-arm64-src/llvm-arm64` (and its `-build` folder and log) and `build/wine-arm64/` removed first, builds DXMT arm64 into §6's layout; `bundle.sh`'s assertions and `codesign --verify --strict --deep` pass |
| **D2 On screen** | `dxmt-present` passes (the integration gate: Wine patch 13 + DXMT, pixels on screen in both lanes, 20 window cycles) |
| **D3 ARM64EC correctness** | `dxmt-arm64ec` passes |
| **D4 x64 programs** | `dxmt-x64` passes, FSR 3 check included |
| **D5 No regressions** | All sub-project 1 steps still pass; `make test` and `make dxmt-check` pass; after `rm build/dxmt/version`, `make dxmt` rebuilds through `dxmt/llvm.sh`; no process of either runtime is left after `check.sh`, pass or fail |
| **D6 Frame time** (measured) | Section 1's `info` lines from D3 and D4 recorded: `present_loop` frame time in both arm64 lanes and on our DXMT under Rosetta |

**Bring-up order** (development, before the gates): an ARM64EC `d3d12_null` run against DXMT with `WINEDEBUG=+loaddll` (the front ends and `winemetal` load and the unix calls work), then the x64 build under FEX; then Wine patch 13 and `present_loop`; then the full lanes. **If D2 fails** after Wine patch 13 is in, try §1's fallbacks in order before anything else.

## 9. Errors

| Condition | Behaviour |
|---|---|
| A DXMT patch fails to apply to the pin | The build stops and names the patch |
| `meson`, the Metal Toolchain or another tool missing | The build stops and names it with its Homebrew formula or install command |
| A built `winemetal.dll` lacks the builtin marker, a front end has it, `winemetal.so` is missing, or `DXMT/version` doesn't match the tree | `bundle.sh` stops; nothing is staged |
| Screen Recording not granted to the app running the check | `dxmt-present` fails, naming the setting |
| GPTK not imported, or the installed runtime's tarball not cached | `dxmt/check.sh` stops with its existing messages (the D3DMetal reference needs both) |
| A test program hangs or crashes | Its 120 s watchdog ends it (the crash dialog is off), and the lane's later checks still run |
| `macdrv_functions` lookup fails at runtime | DXMT's own message, then the program exits (no NULL dereference) |

## 10. Acceptance

Recorded in `docs/testing/acceptance-arm64-dxmt.md`: clean build, the bring-up runs, `winshot`'s shares on the Rosetta reference window and on both lanes, every check step with its `ok` counts, D6's frame times, `make test` and `make dxmt-check` results, the orphan line, the check's run time, and the DXMT commit and patch list.

## 11. Risks

- **Nothing has presented yet:** the draft Wine patch and the arm64 DXMT have never run together (D2). Fallbacks in §1.
- **DXMT has never loaded here:** the ARM64X front ends, `winemetal.dll`'s unix calls, and x64 callers reaching DXMT's ARM64EC code through FEX (COM calls through vtables included) are untried; the bring-up order tests each in turn. If x64 calls fail where ARM64EC calls work, the fault is in the call path (FEX's or Wine's ARM64EC dispatch, or DXMT code without entry thunks), and is fixed there with a patch naming the failure.
- **Bit-identical results across hosts:** the D3DMetal comparisons are exact for most checks, and today they hold for x86_64 DXMT. arm64 DXMT may differ in the last bit: clang contracts floating-point multiply-adds into FMA on arm64 by default (x86_64 without `-mfma` can't), so host-side float math in airconv or `winemetal.so` can round differently, and different AIR can make Metal's compiler optimize differently. Expect it at D3 rather than read it as a DXMT bug; the first fix is `-ffp-contract=off` for the unix side (a DXMT patch naming the failing check), and a check is only ever loosened with its reason recorded.
- **Weak memory:** DXMT's queue and threading code now runs natively on Arm's weaker memory model instead of under Rosetta's TSO. The hazard checks (`dxmt/check.sh` lane B) may expose real races.
- **Window-close races** shared with CrossOver's design (§5); the freed-surface case is now guarded (the handler presents only surfaces the window still lists), and the window cycles exercise it.
- **Check time:** two full `dxmt/check.sh` lanes plus their D3DMetal reference runs; measured at D3.
- **Two DXMT trees:** the Rosetta stack builds the pin as is; the arm64 stack builds the pin plus patches. They diverge until the patches are folded into the fork.
