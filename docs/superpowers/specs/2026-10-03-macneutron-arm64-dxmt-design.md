# MacNeutron — Native arm64 stack, sub-project 2: DXMT for arm64

- **Date:** 2026-10-03
- **Status:** Written for autonomous execution. The maintainer asked to carry this sub-project through design, plan and implementation without approval stops ("keep going until it's working"); every decision taken on their behalf is in the decisions table and the execution ledger.
- **Builds on:**
  - `2026-10-02-macneutron-native-arm64-design.md` (sub-project 1: the entitled, 4K-page `wine.app`, FEX, `wine-arm64/`)
  - `2026-09-28-macneutron-dxmt-fork-design.md` (our DXMT fork, `dxmt/` build)
- **Evidence:** the exploration brief of 2026-10-03, kept in `docs/research/2026-10-03-arm64-dxmt/` with the draft Wine patch and the probes.
- **Scope:**
  - **In:**
    - DXMT built for ARM64X (PE side) with an aarch64 `winemetal.so` and an arm64 LLVM 15, from the fork pin plus committed patch files;
    - Wine patch 13: the `macdrv_functions` table DXMT looks up, and the present report that keeps the client view visible;
    - DXMT inside the signed `wine.app`;
    - arm64 builds of the DXIL host tools;
    - ARM64EC builds of the D3D test programs, and new `check.sh` steps for both lanes (ARM64EC, and x64 under FEX).
  - **Out:**
    - the MetalFX presenter, the launcher's second runtime, shader pre-caching from the launcher (sub-project 5);
    - SMITE 2 and frame-time parity (sub-project 6);
    - 32-bit and D3D9 (sub-projects 7, 8);
    - licence files for Wine and FEX inside the bundle, notarization (sub-projects 3, 5);
    - pushing anything to `chadouming/dxmt` or elsewhere.

## 1. Goal

Direct3D 10/11/12 programs running in the arm64 runtime draw through our DXMT fork, built natively for arm64, with no Rosetta anywhere. Both kinds of Windows program work: ARM64EC builds (native speed, no FEX) and x64 builds (under FEX).

**Sub-project 2 is done when** §8's gates D1–D5 pass on the maintainer's Mac, D6 is measured, and the result is recorded in `docs/testing/acceptance-arm64-dxmt.md`:
- `make wine-arm64` builds DXMT for arm64 into `wine.app`, and the bundle still passes `codesign --verify --strict --deep`;
- D3D11 and D3D12 programs present on screen from the arm64 runtime, in both lanes;
- the D3D12 read-back checks match fixed values, or our DXMT under Rosetta at the same pin;
- the Rosetta stack is unchanged.

### Decisions

| Decision | Choice |
|---|---|
| How DXMT changes are carried | **Patch files on top of the shared fork pin** (`dxmt/pins` `DXMT_COMMIT`), in `wine-arm64/patches/dxmt/`, applied with `git am` in the arm64 build's own DXMT clone. Same model as Wine and FEX. No pin bump, so the Rosetta stack doesn't rebuild or re-check; no push to `chadouming/dxmt`. Folding the patches into the fork is a maintainer step for later. |
| PE flavour | ARM64X, from DXMT's own `build-arm64ec.txt` (`-marm64x`, already in our pin). One DLL serves ARM64EC and x64 callers. |
| LLVM | LLVM 15.0.7 (`dxmt/pins` `LLVM_TAG`) built for arm64, in its own install folder, from the shared `build/dxmt-src/llvm-project` source. |
| Wine tree DXMT links against | Sub-project 1's build tree, `build/wine-arm64-src/wine-build` (`-Dwine_build_path`). Wine 8.16 isn't needed. |
| Window binding | Wine patch 13 ports the CodeWeavers `d3dmetal.c` table (as dappermint's `arm64-1117` enabled it on aarch64) plus the `WineMetalLayer` present report. Fallbacks, in order, if nothing draws: call `client_surface_present` from DXMT's side; cyyever's direct view without client surfaces. |
| Where DXMT lives | Inside `wine.app`, signed with it: `winemetal.so` must sit next to `winemac.so` (its rpath is `@loader_path`), and nothing can be added to a signed bundle later. |
| Reference for pixel/timing checks that today compare against D3DMetal | Our DXMT under Rosetta at the same pin, run live on a clone of the installed tool folder with `build/dxmt` installed into it. |
| Check target | One target: the DXMT steps join `make wine-arm64-check`, which grows from ~7.5 to ~20 minutes. Step names keep partial runs cheap. |
| Time box | Three weeks from the start of implementation, as for sub-project 1. The integration gate (§8, D3) is the risk; its fallbacks are named above. |

## 2. Evidence (verified 2026-10-03 on the M5 Pro, macOS 27.0.1, unless marked)

- **DXMT builds for ARM64X today**, apart from one file: `src/d3d12/d3d12_stats.cpp` includes `<x86intrin.h>` and calls `__rdtsc` (our fork commit `d245c13`). With an ARM64 counter in its place, 108 of 108 PE objects compile; a full setup + compile + install takes 26 s. Upstream's arm64ec CI never enables D3D12, which is why nobody hit it.
- **arm64 LLVM 15 builds in 153 s** with `dxmt/build.sh`'s flags plus `-DCMAKE_OSX_ARCHITECTURES=arm64 -DLLVM_HOST_TRIPLE=arm64-apple-darwin` (125 MB, 76 static libraries). The "30–60 minutes" comment in `dxmt/build.sh` is out of date.
- **`winemetal.so` links** for arm64 (22 MB stripped, `minos 27.0`). The only Wine symbol it imports is `NtSetEvent`; `winemac.so` and `ntdll.so` are loaded through `@rpath` = `@loader_path/`, `@loader_path/../../`. Loaded from outside the bundle it fails unless `winemac.so` is already loaded.
- **Wine 11.19's winemac has no `macdrv_functions`** (it exists only in CodeWeavers' tree) and builds with `-fvisibility=hidden`. DXMT's lookup (`winemetal_unix.c:1713-1757`) then finds no view, and the swap chain calls `abort()` (`src/d3d11/d3d11_swapchain.cpp:137-140`).
- **DXMT reads a 10-slot table** (`struct macdrv_functions_t`) and calls 5 of its slots: `get_win_data`, `release_win_data`, `macdrv_view_create_metal_view`, `macdrv_view_get_metal_layer`, `macdrv_view_release_metal_view`. It reads `client_cocoa_view` at offset 24 of what `get_win_data` returns, with no NULL check; Wine 11.19's own struct has `client_view` at offset 16.
- **Without a present report the window stays blank:** win32u never refreshes an unregistered client surface (`win32u/window.c:397-414`), and the first GDI flush hides the view (`surface.c:123-131`) (inferred from the source; CrossOver needed the same report).
- **The draft Wine patch 13** (5 files, +135/−1) applies to sub-project 1's tree, builds, and exports `_macdrv_functions`; a `dlsym` probe fails on the stock library and passes on the patched one. **It has never been run with DXMT.**
- **All 20 D3D test programs** in `dxmt/tests` plus `present_loop` build as ARM64EC with no source changes. An ARM64EC D3D12 program reached device creation in 1.9–2.4 s; the same x64 program under FEX in 2.2–2.7 s. Wine's built-in `d3d12.dll` fails (`0x80004005`, built without Vulkan), so there is no Wine reference.

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
- **Clone:** its own clone, `build/wine-arm64-src/dxmt`, at `dxmt/pins` `DXMT_COMMIT` (from `DXMT_REPO`), branch `macneutron`, then `git am wine-arm64/patches/dxmt/*.patch`. Same modes, `.applied`/`.series` files and development loop as Wine and FEX; `export.sh` exports it too. The shared `build/dxmt-src/dxmt` clone is never touched, so `make dxmt` and `make wine-arm64` can't race on it.
- **LLVM:** LLVM 15 for arm64 from `build/dxmt-src/llvm-project` (fetched by `dxmt/build.sh`'s logic if missing) into `build/wine-arm64-src/llvm-arm64`, with `dxmt/build.sh`'s flags plus `-DCMAKE_OSX_ARCHITECTURES=arm64 -DLLVM_HOST_TRIPLE=arm64-apple-darwin`. Built once; reused while `LLVM_TAG` is unchanged.
- **Shared code:** the clone and LLVM logic move into `dxmt/lib.sh` functions that take an architecture, used by both `dxmt/build.sh` and `wine-arm64/build.sh`; `dxmt/build.sh`'s behaviour is unchanged.
- **Meson:**
  ```
  meson setup <build> <dxmt> --cross-file build-arm64ec.txt --buildtype release --strip --prefix <install>
    -Dwine_builtin_dll=false -Denable_d3d12=true -Dnative_llvm_path=<llvm-arm64> -Dwine_build_path=<wine-build>
  ```
  with the llvm-mingw `bin` first on `PATH`, and `MACOSX_DEPLOYMENT_TARGET=27.0`.
- **Tools:** `meson` joins the required tools, plus the Metal Toolchain check from `dxmt/build.sh`.
- **Stamp:** covers `dxmt/pins`, `wine-arm64/patches/dxmt/*`, and the new build code.
- **Host tools:** arm64 `dxil-probe` and `dxil-translate`, built as `dxmt/build.sh` builds the x86_64 ones but against the arm64 LLVM and the arm64 build's `libairconv.a`, into `build/wine-arm64/` (outside the bundle).

**DXMT patches** (`wine-arm64/patches/dxmt/`):

| # | Patch | Why |
|---|---|---|
| 1 | `d3d12_stats.cpp` reads an ARM64 counter (`cntvct_el0`) on non-x86 builds, keeping `__rdtsc` under `DXMT_ARCH_X86`; its calibration against QueryPerformanceCounter already adapts to any rate. Also include `<cstdint>` at the top of `util_bit.hpp`, which `#error`s when nothing included it first | The only compile error on arm64 |

Further patches come only from failures seen during bring-up, each with the failure in its message.

## 5. Wine patch 13: window binding

One Wine commit in sub-project 1's development tree, exported as the next Wine patch. Its message names its sources: CodeWeavers' `dlls/winemac.drv/d3dmetal.c` (Brendan Shanks, LGPL-2.1+, as published in `athei/wine` branch `cx-26-patched`), and `dappermint/winecx` `713015fa9f`, `13e6a88a02`, `565f6386b7` (LGPL).

- **`window.c`:** a `DECLSPEC_EXPORT` 10-slot `macdrv_functions` table in DXMT's slot order (§2), and a stand-in struct whose `client_cocoa_view` is at offset 24 (`C_ASSERT`). `get_win_data` creates a client surface for the window, records it on the window's data, and returns with the window lock held; `release_win_data` unlocks. A window from another process gets a NULL view, so DXMT stops at its own message, not a NULL dereference. Surfaces are freed when the window is destroyed, after the lock is released.
- **`cocoa_window.m`:** the Metal layer posts `CLIENT_SURFACE_PRESENTED` from `nextDrawable`, for DXMT's views only.
- **`event.c`, `macdrv.h`, `macdrv_cocoa.h`:** the event handler calls `client_surface_present`.

The draft in the research folder is the starting point. Known limits it shares with CrossOver: a `nextDrawable` during window close can queue a pointer to a freed surface; every frame posts an event; the lock is held across main-thread round trips; child-window swap chains need dappermint's `f77c272bbe` (deferred until a game needs it).

## 6. The bundle

`bundle.sh` copies DXMT in before signing, so `macho()` signs `winemetal.so` with everything else:

| Path under `wine.app/Contents/Resources/` | Contents | Wine builtin marker |
|---|---|---|
| `lib/wine/aarch64-windows/winemetal.dll` | ARM64X | present (asserted) |
| `lib/wine/aarch64-unix/winemetal.so` | arm64, `minos 27.0` | — |
| `DXMT/aarch64-windows/` | `d3d11.dll`, `d3d10core.dll`, `dxgi.dll`, `d3d12.dll`, `dxmt-replay.exe` (ARM64X) | absent (asserted) |
| `DXMT/` | `COPYING.LIB`, `LICENSE`, `LICENSE.OLD` from the clone; `version` = the DXMT commit the build used plus the patch series hash | — |

New `bundle.sh` assertions: the markers as above; `DXMT/version` names `DXMT_COMMIT`; `codesign --verify --strict --deep` (already there).

**In a prefix** (done by `check.sh` here; by the launcher in sub-project 5): copy `DXMT/aarch64-windows/*` into `drive_c/windows/system32/`, and use the overrides `dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b` (`GraphicsBackend.swift:35`'s DXMT value). No syswow64 part until sub-project 8.

## 7. Tests and checks

**Test programs.**
- **ARM64EC lane:** a Makefile rule builds `dxmt/tests/d3d12_*.cpp` and `presenter/tests/present_loop.c` with `arm64ec-w64-mingw32-clang++`/`-clang` (same flags and libraries as the x64 rules) into `build/dxmt-tests-arm64ec/`, keeping the basenames (`dxmt/check.sh`'s expected strings contain them).
- **x64 lane:** the existing x64 programs in `build/dxmt-tests/` and `build/presenter/present_loop.exe`, run under FEX.

**A `dxmt_run` helper** in `wine-arm64/check.sh`, next to `wine_run`, sets the DXMT overrides and a per-lane `DXMT_SHADER_CACHE_PATH`. The ARM64EC and Rosetta reference runs never overlap (both key caches by exe name).

**Reference runs.** Checks that `dxmt/check.sh` compares against D3DMetal compare instead against the same program on our DXMT under Rosetta at the same pin: a clone of the installed tool folder (as G4 does) with `build/dxmt` installed into it through `macneutron install-dxmt --tool-dir`, guarded so its `dxmt-version` equals `DXMT_COMMIT`. Pixel comparisons keep `dxmt/check.sh`'s tolerance (1/255 per channel). Fixed-value checks reuse `dxmt/check.sh`'s expected strings unchanged.

**New steps** (in this order, after `g5-jit` and before `g4-bench`):

| Step | Content |
|---|---|
| `dxil-tools` | arm64 `dxil-probe`/`dxil-translate` on the test shaders: the same fixed results as `dxmt/check.sh` |
| `dxmt` | Copy the front ends into the prefix; marker and version checks |
| `dxmt-d3d12` | ARM64EC lane: `dxmt/check.sh`'s D3D12 read-back checks (cache/record/replay, hazards and stats, DXIL pipelines and capture, exec/tri/GS/depth/query/api/copy/null/layered/volume/vsread/indirect/stats/timestamps/bounds/queues), against fixed values or the Rosetta reference; Metal API validation (`MTL_DEBUG_LAYER=1`) reports 0 errors |
| `dxmt-present` | ARM64EC lane: `present_loop` (D3D11) presents all frames; `d3d12_clear` presents 300/300; 20 consecutive window open/close cycles without a crash |
| `dxmt-x64` | x64 lane under FEX: one launch per program with its main expected lines, plus the FFX swap chain test |
| `dxmt-frametime` | Measured, not gated: `present_loop` frame time in both lanes and on Rosetta's DXMT, same window size and frame count |

Each step runs all its checks before failing, so one run shows every failure in that step.

## 8. Gates

| Gate | Pass |
|---|---|
| **D1 Build** | `make wine-arm64` from a clean `build/` builds DXMT arm64 into §6's layout; `bundle.sh`'s assertions and `codesign --verify --strict --deep` pass |
| **D2 D3D12 correctness** | `dxmt-d3d12` passes |
| **D3 Present** | `dxmt-present` passes (this is the integration gate: Wine patch 13 + DXMT on screen) |
| **D4 x64 programs** | `dxmt-x64` passes |
| **D5 No regressions** | All sub-project 1 steps still pass; `make test` and `make dxmt-check` pass; no process of either runtime is left after `check.sh`, pass or fail |
| **D6 Frame time** (measured) | `dxmt-frametime`'s numbers recorded |

**Order:** D1 → D2 (no window needed) → D3 → D4 → D5 → D6. **If D3 fails** after Wine patch 13 is in, try §1's fallbacks in order before anything else.

## 9. Errors

| Condition | Behaviour |
|---|---|
| A DXMT patch fails to apply to the pin | The build stops and names the patch |
| `meson`, the Metal Toolchain or another tool missing | The build stops and names it with its Homebrew formula or install command |
| A built `winemetal.dll` lacks the builtin marker, or a front end has it | `bundle.sh` stops; nothing is staged |
| The Rosetta reference tool folder isn't at the DXMT pin after install | The reference step fails, naming both commits |
| `macdrv_functions` lookup fails at runtime | DXMT's own message, then the program exits (no NULL dereference) |

## 10. Acceptance

Recorded in `docs/testing/acceptance-arm64-dxmt.md`: clean build, every check step with its numbers, D6's frame times, `make test` and `make dxmt-check` results, the orphan line, and the DXMT commit and patch list.

## 11. Risks

- **Nothing has presented yet:** the draft Wine patch and the arm64 DXMT have never run together (D3). Fallbacks in §1.
- **Weak memory:** DXMT's queue and threading code now runs natively on Arm's weaker memory model instead of under Rosetta's TSO. Lane-B style hazard checks may expose real races.
- **Window-close races** shared with CrossOver's design (§5).
- **Metal validation under the hardened runtime** needs one confirming run.
- **Reference drift:** the Rosetta reference assumes identical shader translation across hosts; LLVM built with no targets should make airconv's output host-independent (inferred). The 1/255 tolerance absorbs rounding.
- **Two DXMT trees:** the Rosetta stack builds the pin as is; the arm64 stack builds the pin plus patches. They diverge until the patches are folded into the fork.
