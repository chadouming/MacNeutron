# SP2 design-input brief: DXMT on the native arm64 stack

Sources: the build, window, tests, bundle and upstream reports, plus re-checks I ran today. Paths are relative to `/Users/chad/Documents/MacProton`. Unlabelled facts are VERIFIED; anything not checked is marked INFERRED.

## 0. Corrections and dropped claims

| Claim | Status |
|---|---|
| "Nothing presents" on stock 11.19 | **Wrong.** The lookup returns no view, and DXMT calls `abort()` at `src/d3d11/d3d11_swapchain.cpp:137-140` (re-read at fork `1fba8d2`). |
| Vanilla Wine once exported `macdrv_functions` | **Refuted.** The table exists only in CodeWeavers' Wine. Vanilla builds unix libraries with `-fvisibility=hidden` (`configure.ac:1943`). |
| DXMT reads 9 table entries | **Corrected.** `struct macdrv_functions_t` has 10 slots (80 bytes) and DXMT calls 5 of them (`winemetal_unix.c:1690-1701,1713-1757`). |
| "CrossOver's" arm64 enablement (`713015fa9f`, `13e6a88a02`, `565f6386b7`, `f77c272bbe`) | **Re-attributed.** All four are by dappermint ("millia ampora"), from the `dappermint/winecx` branch `arm64-1117` (`git log` author check). CodeWeavers' own `d3dmetal.c` (CX26) is x86_64-only. |
| Stage DXMT outside the bundle and load it via `WINEDLLPATH` (tests report; build report's alternative) | **Refuted.** `winemetal.so` loads `@rpath/{winemac,ntdll}.so` and its only rpaths are `@loader_path/` and `@loader_path/../../`. Loaded from outside the bundle it fails unless `winemac.so` is already loaded (rpath toy test in `sp2-explore/rpath/`). |
| arm64 LLVM 15 takes 30-60 min (bundle report) | **Refuted.** It took 153 s, of which 135 s was ninja (`sp2-explore/llvm-arm64.log`, rc=0). The comment at `dxmt/build.sh:83` is out of date. |
| Upstream LLVM flags `c5f854c` and `e86484e` are needed on the current SDK | **Refuted.** The build passed without them. Adding them is optional, only to match upstream. |
| `-marm64x` needs Wine's `arm64ec-windows` import libraries | **Refuted.** The full build linked against `aarch64-windows/*.a` alone; the winecrt0 archive carries both COFF members. |
| `winemetal.so` minos is unknown | **Settled.** `otool` shows minos 27.0 on `sp2-explore/full-install/aarch64-unix/winemetal.so`. |
| Whether `WINEDLLPATH` survives the 4K re-exec | **Dropped.** It no longer matters once the files sit inside the bundle. |

## 1. Build recipe

| Item | Recipe |
|---|---|
| Output type | **ARM64X** (decided). DXMT's existing `build-arm64ec.txt` already passes `-marm64x` (upstream `7ef5d9c` and `3b78076`, both in our pin). All 6 PE outputs have machine 0xAA64, like Wine's own `aarch64-windows` DLLs. Pure ARM64EC would gain nothing (INFERRED). |
| Meson | `meson setup <dir> <dxmt> --cross-file build-arm64ec.txt --buildtype release --strip --prefix <dir>-install -Dwine_builtin_dll=false -Denable_d3d12=true -Dnative_llvm_path=<arm64 LLVM> -Dwine_build_path=build/wine-arm64-src/wine-build`, with llvm-mingw first on PATH (clang 23.1.1, release 20260908, the same as `dxmt/pins`). Full setup, compile and install took 25.6 s. |
| Wine tree to link against | `wine-build` via `-Dwine_build_path`, because `wine.app` doesn't exist until `bundle.sh` runs. Configure and the `winemetal.dll` link (with the builtin step) were VERIFIED against this tree. The `winemetal.so` link was only done against `wine.app/Contents/Resources`, so it is the first thing to check (INFERRED to work: its inputs `dlls/winemac.drv/winemac.so` and `dlls/ntdll/ntdll.so` exist). Pass only `wine_build_path`; precedence when both are given is INFERRED (`src/winemetal/meson.build:12,24`). Wine 8.16 isn't needed. |
| What Wine supplies | `libwinecrt0.a`, `libntdll.a`, `libdbghelp.a`, `winebuild`, `winemac.so`, `ntdll.so`. No Wine headers. The only Wine symbol `winemetal.so` imports is `_NtSetEvent`, so the winemac shim is needed at runtime only. |
| arm64 LLVM 15 | `dxmt/build.sh:84-88` with `-DCMAKE_OSX_ARCHITECTURES=arm64 -DLLVM_HOST_TRIPLE=arm64-apple-darwin`, in its own install folder (static per-arch libraries). 125 MB, 76 static libraries. It shares `build/dxmt-src/llvm-project`. |
| `winemetal.so` | Meson native target, `-arch arm64`; 22 MB stripped, minos 27.0, no link warnings. |
| Source of DXMT | The shared clone `build/dxmt-src/dxmt` at the `DXMT_COMMIT` from `dxmt/pins`. `dxmt/build.sh:73-74` stops on uncommitted changes and detaches at the pin, so the `__rdtsc` fix has to be a **fork commit plus a pin bump**, not a local edit. The arm64 build should stop if HEAD isn't the pin. If `make dxmt` and `make wine-arm64` run at the same time they will race on that clone (INFERRED); alternatively use a `git worktree`. |
| Where in `wine-arm64/build.sh` | A new step between 5 (FEX, `:112-137`) and 6 (bundle, `:139-141`). Factor the clone/checkout (`dxmt/build.sh:69-76`) and the LLVM build (`:80-91`) into `dxmt/lib.sh` functions that take an arch, and call them from both scripts. |
| Build prerequisites | Add `meson` and the Metal Toolchain check (`dxmt/build.sh:50`) to `wine-arm64/lib.sh`'s `need_tool` list. |
| Up-to-date stamp | `stamp_of` (`build.sh:66-68`) must also cover `dxmt/pins` and the DXMT step's inputs. Otherwise a pin bump exits "up to date" (`:91-94`). |
| Host tools | `dxil-probe` and `dxil-translate` hardcode `-arch x86_64` and the x86 LLVM (`dxmt/build.sh:15,24`). They need an arm64 variant built against the arm64 LLVM and the arm64 build's `libairconv.a`. |

**Blocker: `__rdtsc`, the only compile error.**
- Where: `src/d3d12/d3d12_stats.cpp:6` includes `<x86intrin.h>` unconditionally, and `__rdtsc` is called at `:71,160,185,190`. It came in with our fork commit `d245c13`. Upstream's arm64ec CI never passes `-Denable_d3d12`, which is why nobody hit it.
- Fix: keep `__rdtsc` under `DXMT_ARCH_X86`; otherwise read `__builtin_arm_rsr64("cntvct_el0")`, using the same guard style as `d3d11_multithread.cpp:19-22`. The calibration at `:72-73` adjusts itself against QueryPerformanceCounter.
- Status: built in `sp2-explore/dxmt-copy`; with it, 108 of 108 PE objects compile. Not run.

**Latent issue (no source file triggers it today).** `src/util/util_bit.hpp:13-23` hits `#error` if nothing includes `<cstdint>` before it (its own include is at `:44`). Optional fix in the same commit.

**Side effect of the pin bump.** It forces `make dxmt` and `make dxmt-check` (about 6 min) on the Rosetta stack (`dxmt/build.sh:38`). On x86_64 the fix changes nothing, by the guard.

**Effort (INFERRED):** fork commit 0.5 day; `build.sh`/`bundle.sh`/`lib.sh` changes 1-2 days.

## 2. Wine patch 13: window binding

The patch is `build/arm64/sp2-explore/window/0013-winemac.drv-Export-macdrv_functions-so-DXMT-can-present.patch`:
- 5 files changed, 135 lines added, 1 removed.
- `git apply --check` is clean on `build/wine-arm64-src/wine` at `d368103`.
- It builds with `wine-build`'s flags; `nm` shows `_macdrv_functions` exported.
- `dlsym_test` fails on the stock library and passes on the patched one, with no `RTLD_GLOBAL` loader change.

**What DXMT needs**

`dlsym(RTLD_DEFAULT,"macdrv_functions")` must find a default-visibility (`DECLSPEC_EXPORT`) table of 10 slots in this order:

| Slot | Contents | Called by DXMT |
|---|---|---|
| 0 | NULL | no |
| 1 | `get_win_data` | yes |
| 2 | `release_win_data` | yes |
| 3 | NULL | no |
| 4 | `macdrv_create_metal_device` | no |
| 5 | `macdrv_release_metal_device` | no |
| 6 | `macdrv_view_create_metal_view` | yes |
| 7 | `macdrv_view_get_metal_layer` | yes |
| 8 | `macdrv_view_release_metal_view` | yes |
| 9 | NULL | no |

`get_win_data` must return Wine 8's struct head, because DXMT reads `client_cocoa_view` at offset 24 with no NULL check (`winemetal_unix.c:1727-1729`). Wine 11.19's real struct has `client_view` at offset 16 (`macdrv.h:230-245`), so the patch uses a stand-in:

```c
struct dxmt_win_data { HWND hwnd; WineWindow *cocoa_window; WineContentView *cocoa_view /*NULL*/;
                       WineContentView *client_cocoa_view; struct macdrv_win_data *data; };
C_ASSERT(offsetof(struct dxmt_win_data, client_cocoa_view) == 24);
```

**What each file does**
- `window.c`: holds the table and stand-in. `get_win_data` creates a client surface, keeps it in a `data->dxmt_surfaces` CFArray, and returns with the lock held; release unlocks and frees. A window from another process gets a NULL view, so DXMT stops at its own abort message instead of a NULL dereference. `macdrv_DestroyWindow` frees the array after unlocking, the opposite order to CrossOver's, so it matches Vulkan's lock order.
- `cocoa_window.m`: `WineMetalLayer`'s `nextDrawable` posts `CLIENT_SURFACE_PRESENTED`, for marked views only.
- `event.c`, `macdrv.h`, `macdrv_cocoa.h`: the handler calls `client_surface_present`.

**Why the present report is needed.** win32u never refreshes an unregistered client surface (`win32u/window.c:397-414,430-444`), and the first GDI flush hides the view (`surface.c:123-131`). Without the report the window stays blank and nothing is logged (INFERRED in a real game).

**Where it goes.** Through the development loop: commit in `build/wine-arm64-src/wine`, then `make wine-arm64-export` writes it to `wine-arm64/patches/wine/0013-*`.
- The commit message must name its sources, as the README's licence section requires: `athei/wine` branch `cx-26-patched` `dlls/winemac.drv/d3dmetal.c` (Brendan Shanks/CodeWeavers, LGPL-2.1+), and `dappermint/winecx` `713015fa9f`, `13e6a88a02`, `565f6386b7`.
- Today it cites only "CW HACK 22435". Its `4caa5c8` header comes from a throwaway tree.

**Precedents**

| Source | What it has |
|---|---|
| CodeWeavers `d3dmetal.c` (CX26, Wine 11.0) | 24-slot table (192 bytes) whose first 9 slots match DXMT's order; guarded `#if defined(__x86_64__)` |
| dappermint `arm64-1117` | The same code enabled on aarch64, plus the `WineMetalLayer` present report, ported to 11.17 |
| cyyever `c5375ee66cb` (Wine 11, LGPL) | 72-line `window.c` change: table plus a view created directly; its `RTLD_GLOBAL` change is INFERRED unnecessary (macOS `dlopen` defaults to global) |
| ProbabilityEngineer EDHM release `dxmt-arm64ec-7c8dee1` | Unmodified upstream ARM64X DXMT (`7c8dee1`, our merge base) running on CrossOver Preview 27.0.0.40921, so CX27 arm64 exports the table (INFERRED) |

**Top risk: nothing has presented yet (INFERRED).** The DXMT build and the patched `winemac.so` have never been run together. Fallbacks, in order:
1. mtld3d PR #994's approach: call `client_surface_present` ourselves and reclass the layer as a plain `CAMetalLayer`.
2. cyyever's direct view, which skips client surfaces.

**Known limits (INFERRED; CrossOver shares them)**
- A `nextDrawable` landing during window close can queue a pointer to a freed surface.
- Every frame posts an event and runs a frame update.
- The lock is held across main-thread round trips.
- Child-window swapchains need `f77c272bbe`. Deferred until a target game needs it.

**Long-term route.** DXMT PR #166 plus Wine MR !11058 (`ExtEscape` 6790/6791) would remove the shim. Neither is in 11.19.

**Effort (INFERRED):** 1-3 days, mostly runtime validation.

## 3. Bundle layout

The Swift side can never write into `wine.app`: adding a file after signing breaks `codesign --verify --strict --deep` (`sp2-explore/seal/`), and the user's machine has no Developer ID. So DXMT is built into the bundle by `bundle.sh`, in a `cp` block between `bundle.sh:41` and `:42`. `macho()` (`:46`, `:50-54`) then signs `winemetal.so` with no new signing code.

| Path in `wine.app/Contents/Resources/` | What | Builtin marker |
|---|---|---|
| `lib/wine/aarch64-windows/winemetal.dll` | ARM64X, next to `libarm64ecfex.dll` | required |
| `lib/wine/aarch64-unix/winemetal.so` | Mach-O, next to `winemac.so` and `ntdll.so` (rpath), signed by `macho()` | — |
| `DXMT/aarch64-windows/{d3d11,d3d10core,dxgi,d3d12}.dll`, `dxmt-replay.exe` | ARM64X front ends | must be absent |
| `DXMT/{COPYING.LIB,LICENSE,LICENSE.OLD,version}` | Licences from the fork clone; `version` = `DXMT_COMMIT` | — |

- A clone with this layout, re-signed, passes `codesign --verify --strict --deep` (`sp2-explore/layout/`).
- **New `bundle.sh` asserts:** `winemetal.dll` carries the builtin marker (the `dd` test at `dxmt/build.sh:119`); the 5 front-end files lack it; `winemetal.so` exists with minos 27.0 (already covered by `:60-64`); `DXMT/version` equals the pin.

**Prefix**
- Copy `DXMT/aarch64-windows/*.dll` into `drive_c/windows/system32/`. An ARM64EC process loaded `C:\windows\system32\d3d12.dll` (`+loaddll`).
- Overrides: `WINEDLLOVERRIDES="dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b"` (`GraphicsBackend.swift:35`).
- No syswow64 or 32-bit part until SP8.
- x64-under-FEX processes loading these ARM64X DLLs is INFERRED. The support is that G1's x64 tests already load Wine's own ARM64X DLLs. The x64 check lane is the proof.

**Licences and publishing**
- `wine.app` contains no licence files today, Wine's and FEX's included. Flag for SP3/SP5; outside SP2.
- Shipping requires `dxmt/published.sh` (`Makefile:79`) to pass for the pinned commit, which means the fork commit must be public.

**Consequences for SP5 (out of scope):**
- `ToolLayout` and `GraphicsBackend` need per-runtime paths and must force dxmt on arm64.
- `DXMTInstaller` must never touch `wine.app`.
- Every DXMT update means rebuilding, re-signing and re-notarizing `wine.app`.
- The presenter is not loaded: no `allow-dyld-environment-variables` entitlement.
- Shader-cache stamps should keep one DXMT pin for both runtimes, or be keyed per runtime.

## 4. Tests

**Program builds**
- Add one Makefile pattern rule building `dxmt/tests/*.cpp` and `present_loop.c` with `arm64ec-w64-mingw32-clang++ -O2 -static -s -std=c++17 … -ld3d12 -ldxgi -luser32 -lpsapi` into `build/dxmt-tests-arm64ec/`.
- Keep the basenames: the expected strings contain them (`dxmt/check.sh:179,200,741`).
- All 20 programs link (machine 0xA641 with CHPE metadata) and need no source changes.
- No new rule is needed for the x64 lane: it reuses the existing `build/dxmt-tests` x64 programs.

**Lanes**

| Lane | Runs | Proves |
|---|---|---|
| **ARM64EC** (primary) | Before the `fex` step; reached `D3D12CreateDevice` | DXMT's port alone, at native speed |
| **x64 under FEX** (integration) | In `NEEDS_FEX`; reached `D3D12CreateDevice` after `reg add`; prints nothing without FEX | Entry thunks on every COM call, struct returns (`d3d12_common.hpp:3`), callbacks; the exact binaries the Rosetta reference ran; FFX (an x64 DLL) |

**References**

| Check type | Reference on arm64 |
|---|---|
| Fixed-value checks (most of them) | Reuse `dxmt/check.sh`'s strings unchanged |
| Checks compared against D3DMetal today | **Default:** our DXMT on Rosetta at the same pin, through `check.sh`'s `rosetta()` (`:271-274`), after `install-dxmt --tool-dir "$RTOOL"` plus a guard that `dxmt-version` equals the pin (the installed tool happens to be at `1fba8d2` today, but nothing ensures that). Exact matches across hosts are INFERRED (LLVM built with no targets); keep `same_pixels`' 1/255 tolerance. Recorded snapshots under `build/dxmt-ref/<commit>/` become the path once Rosetta is gone. |
| Built into Wine | None: Wine's `d3d12.dll` fails with `0x80004005`, "built without Vulkan" (`sp2-explore/ec-null.err`) |
| D3D11 timing vs DXMT 0.80 | Not gated. Frame time against Rosetta's DXMT is measured, like G4; the comparison belongs to SP6 |

**What carries over from `dxmt/check.sh`**

| Carries over now (no winemac needed) | Waits for patch 13 (needs a swap chain) | Not in SP2 |
|---|---|---|
| E1 compression and views (`:92-101`)<br>dxil-probe and dxil-translate (`:103-122`, `:680-692`), on arm64 host tools first<br>Lane A cache, record, replay (`:132-214`)<br>Lane B hazards and stats (`:226-232`)<br>DXIL pipelines and capture (`:376-398`, `:413-420`)<br>exec / tri / GS / depth / query / api / copy / null / layered / volume / vsread / indirect / stats / timestamps / bounds / queues (`:427-728`)<br>Metal validation, 0 errors (`:251-255`, `:534-538`) | `present_loop` (`:77-87`)<br>`d3d12_clear` 300/300 and the caps lines it prints (`:360-412`)<br>D3D11 cache table (`:571-581`)<br>FFX swapchain, x64 under FEX only (`:670-676`) | `hazards-ref` (cross-check only)<br>"D3DMetal still works" (`:678`)<br>launcher precache (`:729-744`) and `MACNEUTRON_LOG`: SP5<br>`presenter/check.sh`: SP5 |

- **Weak memory (INFERRED):** Lane B can now expose threading bugs that Rosetta's TSO hid, because DXMT's queue code runs as native ARM64.
- **Metal validation (INFERRED):** `MTL_DEBUG_LAYER` working under the hardened runtime needs one confirming run.

**New steps in `wine-arm64/check.sh`**

| Step | Content |
|---|---|
| `dxil-tools` | arm64 dxil-probe and dxil-translate; fixed values; no prefix |
| `dxmt` | Copy the front ends into system32; builtin and non-builtin markers; `DXMT/version` equals the pin |
| `dxmt-d3d12` | ARM64EC read-back checks |
| `dxmt-present` | `present_loop`, `d3d12_clear` 300/300, and N clean window closes |
| `dxmt-x64` | In `NEEDS_FEX`: one launch per program with its main expected lines, plus FFX |

- A `NEEDS_DXMT` list puts `dxmt` in front, reusing the loop at `:333-339`.
- Add a `dxmt_run` helper next to `wine_run` (`:119`) that sets `WINEDLLOVERRIDES`, a per-lane `DXMT_SHADER_CACHE_PATH`, and the reference guard. Steps run in subshells (`:99`), so exports don't carry between steps.
- Each step runs all its checks before returning 1, so one run shows every failure in that step.
- The arm64 and Rosetta lanes must not run at the same time: both use DXMT caches keyed by exe name.

**Runtime cost**

Measured: prefix boot 8 s; first D3D launch 13 s (once); ARM64EC D3D12 test to device creation 1.9-2.4 s; x64 under FEX 2.2-2.7 s; `isec` 0.08 s.

Estimate (INFERRED):
- About 90 DXMT launches, 10-13 min serial.
- x64 lane about +1 min; live Rosetta reference +4-5 min.
- `make wine-arm64-check` goes from 7 min 22 s to about 20 min.

**Effort (INFERRED):** Makefile rule 0.5 day; `check.sh` steps 2-3 days.

## 5. Upstream shortcuts

- **Build side is mostly done upstream:** DXMT's cross file, its `aarch64` meson branches, and CI's arm64 LLVM recipe (`ci.yml` job `setup-llvm-darwin-arm64`, `:245-272`) are all in our pin. No new cross file is needed.
- **Window binding:** port the CodeWeavers and dappermint code (patch 13 has done this); cyyever's patch is the smaller alternative. All are LGPL and Wine-11-based.
- **Runtime proof:** the EDHM ARM64X release on CrossOver 27.
- **Not usable today:**
  - Upstream v0.80 has no ARM64 assets; ARM64 builds exist only as CI artifacts.
  - Upstream D3D12 on arm64ec is untested.
  - DXMT #166 and Wine !11058 are not merged.
  - Gcenx has no arm64 Wine or DXMT.
- **Licence warning:** the `willfaust/dxmt` and `DAthensT/dxmt` forks and Madeira's post-2026-08-28 changes are GPL-3. Do not copy them into the LGPL fork.
- **Upstream fix after our pin:** `fb45156` (`device_` used before it is initialised, ClearUAV crash). Optional cherry-pick.

## 6. Acceptance and tasks

**Done when**
1. `make wine-arm64` from a clean `build/` builds DXMT arm64 into `wine.app` in §3's layout, `bundle.sh`'s new asserts pass, and `codesign --verify --strict --deep` passes.
2. `make wine-arm64-check` passes the existing steps plus `dxil-tools`, `dxmt`, `dxmt-d3d12`, `dxmt-present` and `dxmt-x64`.
   - D3D11 `present_loop` and D3D12 `d3d12_clear` present on screen (300/300).
   - The ARM64EC read-back checks equal the fixed values or the Rosetta reference at the same pin.
   - Metal validation reports 0 errors.
   - The x64-under-FEX lane passes, FFX included.
3. The Rosetta stack is unchanged with the new pin: `make test` and `make dxmt-check` pass.
4. No process of either runtime is left after `check.sh` exits, pass or fail.
5. Measured, not gated: `present_loop` frame time on arm64 against Rosetta's DXMT, recorded in `docs/testing/acceptance-arm64-dxmt.md`.
6. The `DXMT/` licences and version are in the bundle, and patch 13's message names its sources.

**Tasks** (effort INFERRED)

| # | Task | Depends on | Effort |
|---|---|---|---|
| T1 | Fork commit for `__rdtsc` (plus the optional `util_bit.hpp` fix); bump `dxmt/pins`; `make dxmt && make dxmt-check` green; user pushes | — | 0.5 d |
| T2 | Patch 13 through the development loop and `export.sh`; provenance in the message | — | 0.5 d (the patch exists) |
| T3 | `dxmt/lib.sh` arch functions (clone, LLVM); `build.sh` DXMT step, prerequisites, stamp; `bundle.sh` copy and asserts; arm64 dxil tools | T1 (prototype on `dxmt-copy` meanwhile) | 1-2 d |
| T4 | Makefile ARM64EC rule for `dxmt/tests` into `build/dxmt-tests-arm64ec/` | — | 0.5 d |
| T5 | **Integration gate:** ARM64EC `present_loop` and `d3d12_clear` present on the T2+T3 bundle; window-close stress; fallbacks from §2 if blank | T2, T3, T4 | 1-3 d |
| T6 | `check.sh` steps, `dxmt_run`, Rosetta reference plus pin guard, x64 lane | T5 | 2-3 d |
| T7 | Acceptance doc, README (licences, layout), update spec row 2 | T6 | 0.5 d |

Total about 6-10 working days, assuming T5 doesn't need a fallback (INFERRED).

## 7. Questions only the user can answer

1. **DXMT pin:** one pin for both stacks (recommended: shader-cache stamps stay valid, but every SP2 fork commit re-runs dxmt-check), or a separate arm64 pin?
2. **Check time:** put about 13 more minutes into `make wine-arm64-check` (about 20 min total), or create a separate `make wine-arm64-dxmt-check` target?
3. **Time box:** how long for SP2? SP1 had three weeks.

**User action, not a question:** push the T1 fork commit to `chadouming/dxmt` branch `macneutron`, so `published.sh` passes for any shipped bundle.

All experiment artefacts are in `/Users/chad/Documents/MacProton/build/arm64/sp2-explore/`; the patch is in `window/`. Nothing tracked, nothing under `build/dxmt*` or `build/wine-arm64*`, and nothing in the installed tool folder was changed.