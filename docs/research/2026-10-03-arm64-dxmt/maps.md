### build
The ARM64X build works. With one source fix, the full DXMT D3D12-on build succeeds against our wine.app. That fix is replacing `__rdtsc` in `d3d12_stats.cpp`, which I made in a copy under sp2-explore. 107 of the 108 PE objects compile unchanged.

Scope: I went past "configure only" and ran a full build. Everything is under `/Users/chad/Documents/MacProton/build/arm64/sp2-explore/`:
- `probe/`: macro and `-marm64x` probes.
- `arm64x-x86llvm/`: configure against the x86_64 LLVM, plus the per-object PE compile.
- `arm64x/`: configure against the arm64 LLVM, plus the `winemetal.so` link.
- `llvm-arm64{,-build}/`: arm64 LLVM 15.
- `dxmt-copy/`: an rsync of the fork without `.git`, with only `d3d12_stats.cpp` edited.
- `full/`, `full-install/`: the full build and its install.
- `cfg-winebuild/`: configure against the wine-build tree.

Nothing tracked was edited, and nothing under `build/dxmt*`, `build/wine-arm64*` or the tool folder was touched.

**(1) Cross file and flags**
- **The cross file already exists (VERIFIED).** It is `build/dxmt-src/dxmt/build-arm64ec.txt`, from upstream commits 7ef5d9c and 3b78076 (Feifan He, both ancestors of our pin 1fba8d2). It sets `c/cpp/ar/strip/windres = arm64ec-w64-mingw32-*`, `c_args/cpp_args/c_link_args/cpp_link_args = ['-marm64x']`, and host `cpu_family='aarch64'`.
- **The command I ran (VERIFIED):** `PATH=build/dxmt-src/llvm-mingw/bin:$PATH meson setup <dir> build/dxmt-src/dxmt --cross-file build/dxmt-src/dxmt/build-arm64ec.txt --buildtype release --strip --prefix <dir>-install -Dwine_builtin_dll=false -Denable_d3d12=true -Dwine_install_path=/Users/chad/Documents/MacProton/build/wine-arm64/wine.app/Contents/Resources -Dnative_llvm_path=<arm64 LLVM prefix>`. Configure returned 0 and found winecrt0, ntdll, dbghelp and wine.app's `bin/winebuild`, with 15 targets. The toolchain is clang 23.1.1 (llvm-mingw 20260908).
- **The output is ARM64X despite the file name (VERIFIED).** `-marm64x` makes the driver run two compiles, one for aarch64 and one for arm64ec, and embed the second in a `.obj.arm64ec` section. All six outputs are ARM64X: `winemetal.dll`, `d3d11`, `d3d10core`, `dxgi`, `d3d12` and `dxmt-replay.exe`. Their raw machine field is 0xAA64, the same as Wine's own `aarch64-windows/d3d11.dll`.
- **Pure ARM64EC (INFERRED).** Dropping `-marm64x` would give EC-only DLLs that load only in EC processes.
- **Why `__rdtsc` went unnoticed (VERIFIED).** Upstream CI's arm64ec jobs never pass `-Denable_d3d12` (`.github/workflows/ci.yml`, `build-clang-*-arm64ec-windows-cross`). The `__rdtsc` came in with our commit d245c13.

**(2) `winemetal.so` and the Wine tree**
- **How it's built (VERIFIED).** It is the meson native target in `src/winemetal/unix/meson.build:23-36`, compiled with Apple clang `-arch arm64` (meson.build:191, 200-202).
- **What it links:**
  - airconv and DXBCParserNative, statically.
  - LLVM's static libraries.
  - `winemac.so` and `ntdll.so` from `lib/wine/aarch64-unix`, by path.
  - Its rpaths are `@loader_path/` and `@loader_path/../../`.
- **Result (VERIFIED):** an arm64 `.so` of 22 MB stripped, built for macOS 27.0 to match wine.app's `.so` files, with no link warnings. The native side built in 6.6 s.
- **No Wine headers are needed (VERIFIED).** `winemetal_unix.c` and `cache.c` include only DXMT's own headers and system headers. wine.app has no `include/`, and that doesn't matter.
- **The Wine tree supplies only these files (VERIFIED):**
  - `lib/wine/aarch64-windows/{libwinecrt0,libntdll,libdbghelp}.a`; the winecrt0 archive has both coff-arm64 and coff-arm64ec members.
  - `bin/winebuild`.
  - `aarch64-unix/{winemac,ntdll}.so`.
- **Both of our trees work, so 3Shain's Wine 8.16 isn't needed:**
  - wine.app Resources (`-Dwine_install_path`): full build, `winemetal.so` linked (VERIFIED).
  - `build/wine-arm64-src/wine-build` (`-Dwine_build_path`): configure plus the `winemetal.dll` link and its builtin post-processing (VERIFIED). `winemetal.so` was not linked against this tree, but its inputs `dlls/winemac.drv/winemac.so` and `dlls/ntdll/ntdll.so` exist. In that tree the `.a` files sit under `libs/winecrt0/`, `dlls/ntdll/` and `dlls/dbghelp/aarch64-windows/`; the `arm64ec-windows` folders have none.
- **`wine_build_path` takes precedence when both are given (INFERRED from source:** `src/winemetal/meson.build:12,24`, `unix/meson.build:6`). So `meson_build` in `dxmt/build.sh:96-101`, which hardcodes 3Shain's tree, can be reused by passing `-Dwine_build_path` through `"$@"`.
- **The winemac shim is not a build dependency (VERIFIED).** The only Wine symbol `winemetal.so` imports is `_NtSetEvent` from `ntdll.so`. `winemac.so` appears as a load command only because of `b_asneeded: false`. The shim is needed at runtime only.

**(3) LLVM 15 for arm64**
- **Recipe (VERIFIED):** `dxmt/build.sh:84-86` with `-DCMAKE_OSX_ARCHITECTURES=arm64 -DLLVM_HOST_TRIPLE=arm64-apple-darwin` and the other flags unchanged (assertions off, no targets, no tools, `CMAKE_POLICY_VERSION_MINIMUM=3.5`). The source is `build/dxmt-src/llvm-project`, built out of tree.
- **Time (VERIFIED):** 153 s in total, 135 s of ninja (1918 steps) on the M5 Pro, while the PE objects compiled at the same time.
- **Install (VERIFIED):** 125 MB, 76 static libraries, all arm64; the host triple is `arm64-apple-darwin`.
- **The x86_64 build took 252 s of ninja (VERIFIED,** from `build/dxmt-src/llvm-release-build/.ninja_log`). The "30-60 minutes" comment at `dxmt/build.sh:83` is out of date.
- **Where it's linked:** `src/airconv/darwin/meson.build:12-15,25-37`, using `llvm_deps` from `src/airconv/meson.build:33-47`, into `winemetal.so` via `src/winemetal/unix/meson.build:30`.
- **It needs its own install folder,** because the libraries are static and per-architecture. `build_probe` and `build_translate` hardcode `-arch x86_64` (`dxmt/build.sh:15,24`).
- **Upstream CI uses the same recipe** in its `setup-llvm-darwin-arm64` job, with assertions on.

**(4) x86-only constructs**

The arm64ec compile defines `__x86_64__`, `__amd64__` and `__arm64ec__`, but not `__aarch64__` (VERIFIED). `_M_ARM64EC` arrives only through the mingw header `_mingw_mac.h:94-95`.
- **Breaks the build (VERIFIED):** `src/d3d12/d3d12_stats.cpp:6` includes `<x86intrin.h>` unconditionally, and `__rdtsc` is called at `:71`, `:160`, `:185` and `:190`.
- **Latent (VERIFIED):** `src/util/util_bit.hpp:13-23` hits `#error "Unknown CPU Architecture"` if no standard header comes before it, because its own `<cstdint>` is at line 44. A probe that includes it first fails; with `<cstdint>` first it compiles. No real source file triggers this.
- **Safe because guarded (VERIFIED by the compile):**
  - In `util_bit.hpp`, all of these sit behind `DXMT_ARCH_X86`, so arm64 takes the fallback: `x86intrin` at :25-38, tzcnt/lzcnt at :80-144, SSE `bcmpeq` at :216-235, inline `tzcnt` asm at :489.
  - `d3d11_multithread.cpp:19-22` uses `_mm_pause` on x86 and `yield` on arm64.
  - `winemetal_unix.c:2566-2569` and `:2600-2603` do the same on the native side.
- **32-bit only, not reached:** `__i386__` blocks at `d3d11_buffer.cpp:101`, `d3d11_texture_dynamic.cpp:121`, `d3d12_descriptor_heap.cpp:132,533`, `dxmt_texture.cpp:93,197`, `dxgi.cpp:17`, `dxmt_occlusion_query.hpp:169,179`, `dxmt_staging.cpp:80` and `winemetal.h:127-184`.
- **Not a break (VERIFIED):** under arm64ec, `wineunixlib.h:32-50` picks the x86_64 `__wine_jmp_buf` layout. That matches Wine's own `include/wine/exception.h:102-107`, and DXMT never uses `__TRY`.
- **`DXMT_PAGE_SIZE=4096`** (meson.build:140; used in `dxmt_buffer.cpp:38-45`, `dxmt_context.cpp:58`, `dxmt_texture.cpp:198`, `dxmt_occlusion_query.hpp:170`) compiles fine. At runtime, the page alignment Metal needs for `newBufferWithBytesNoCopy` (`winemetal_unix.c:162`) should hold in the entitled 4K-page process, as it does under Rosetta today (INFERRED).

**(5) Wine's builtin marker**
- **Only `winemetal.dll` needs it.** Wine loads a DLL's `.so` only for modules on its builtin list:
  - `dlls/ntdll/unix/virtual.c:857-879`, `load_builtin_unixlib`.
  - `:3489`, where `add_builtin_module` runs only when the image is builtin.
  - `dlls/ntdll/loader.c:2271-2285`, the "Wine builtin DLL" test.
- **What the build produced (VERIFIED):** the post-processing step (`src/winemetal/meson.build:52-58`) marked `winemetal.dll` builtin, using wine.app's `winebuild`. With `-Dwine_builtin_dll=false` the front ends have no marker and install to `system32/`, which matches today's asserts at `dxmt/build.sh:119-121`.
- **Install layout (VERIFIED):** `aarch64-windows/winemetal.dll`, `aarch64-unix/winemetal.so`, and `system32/{d3d11,d3d10core,dxgi,d3d12}.dll` plus `dxmt-replay.exe`.
- **Placement (INFERRED):** `winemetal.so` is a Mach-O library. It has to go into wine.app before `wine-arm64/bundle.sh:46-57` signs and checks the bundle. The alternative is to keep it outside and load it via `WINEDLLPATH`, which works because the entitlements disable library validation.

**(6) Trial results**
- **Configure:** both configures returned 0 with no warnings or errors.
- **`d3d12_stats.cpp` through ninja (VERIFIED):** fails with the include present. The first errors come from the `x86intrin.h` include chain:
  - aarch64 compile: `ia32intrin.h:312: use of undeclared identifier '__builtin_ia32_readeflags_u32'`, then `immintrin.h:14: #error "This header is only meant to be used on x86 and x64 architecture"`.
  - arm64ec compile: `ia32intrin.h:282 '__builtin_ia32_readeflags_u64'`, `hresetintrin.h:42: invalid input constraint 'a' in asm`, and `uintrintrin.h`/`usermsrintrin.h` builtins.
  - With no error limit, that is 3102 errors (aarch64) and 3215 (arm64ec).
- **With line 6 removed:** exactly 4 errors per compile, `d3d12_stats.cpp:71:18`, `:160:18`, `:185:10` and `:190:16`: "use of undeclared identifier '__rdtsc'".
- **Everything else:** `ninja -k 0` over all 108 PE objects fails only `d3d12_stats.cpp.obj`.
- **With the fix in the copy:** full `meson setup`, `compile` and `install` take 25.6 s and return 0.
- **The fix, built but not run:** keep `__rdtsc` only when `defined(__x86_64__) && !defined(__arm64ec__)`. Otherwise read `__builtin_arm_rsr64("cntvct_el0")`, the generic timer, which user code can read on macOS. That puts 8 reads in `d3d12.dll`, 4 call sites times 2 halves. The `per_us` calculation at `:72-73` calibrates itself against QueryPerformanceCounter. For the real patch, guard with `util_bit.hpp`'s `DXMT_ARCH_X86`/`DXMT_ARCH_ARM64`, as `d3d11_multithread.cpp:19-22` does.

**Lead on the second blocker (outside this task):** 3Shain's Wine 8.16 `winemac.so` exports `_macdrv_functions`, `_get_win_data` and `_macdrv_view_create_metal_view`. Wine 11.19's exports only `___wine_unix_call_funcs` and `___wine_unix_call_wow64_funcs` (both VERIFIED). The shim is runtime-only.

Logs are in `/Users/chad/Documents/MacProton/build/arm64/sp2-explore/`:
- `configure-x86llvm.log`, `configure-arm64.log`, `cfg-winebuild.log`
- `d3d12_stats.log`, `pe-objs.log`, `native.log`
- `full.log`, `llvm-arm64.log`

### window
I've written the smallest Wine patch that should let DXMT present on 11.19, and checked that it builds and exports the table DXMT looks for. Whether DXMT actually draws on arm64 is still untested, because no arm64 DXMT build exists yet. The patch is `/Users/chad/Documents/MacProton/build/arm64/sp2-explore/window/0013-winemac.drv-Export-macdrv_functions-so-DXMT-can-present.patch` (135 lines added, 1 removed; `git apply --check` is clean on wine-arm64-src d368103).

## How DXMT attaches to a window (all VERIFIED)
- **Windows side:** `d3d11_swapchain.cpp:135` and `d3d12_swapchain.cpp:177` call `CreateMetalViewFromHWND` (`winemetal_thunks.c:715`, unix call 72, hwnd passed as a uint64). Release is `d3d11_swapchain.cpp:210` / `d3d12_swapchain.cpp:233` (unix call 73). `nextDrawable` is called from a Windows thread via a unix call (`dxmt_presenter.cpp:159`).
- **Unix side** (`winemetal_unix.c:1704-1757`):
  - It first tries `dlsym(RTLD_DEFAULT,"macdrv_functions")`, then four separate symbols (lines 1713-1722).
  - It then calls `get_win_data(hwnd)` and reads `->client_cocoa_view` at offset 24 with no NULL check (1727-1729).
  - It creates the metal view and gets its layer, then releases the window data.
- **Correction to the task's premise:** on stock 11.19 it isn't that "nothing presents". The lookup returns no view and DXMT calls `abort()` at `d3d11_swapchain.cpp:137-140`.

## What Wine 11.19 provides (VERIFIED)
- **Exports:** the built `winemac.so` (wine-build, trial-11.19 and wine.app) exports only `___wine_unix_call_funcs` and `___wine_unix_call_wow64_funcs`. The cause is `-fvisibility=hidden` (`configure.ac:1943`). 3Shain's 8.16 build exports `_macdrv_functions`, `_get_win_data` and the `macdrv_view_*` functions, which is why it works under Rosetta today.
- **The usual export mechanism works:** marking a symbol `DECLSPEC_EXPORT` gives it default visibility in a unix lib (`winnt.h:179-185`). Wine uses the same mechanism for its two exported symbols (`include/wine/unixlib.h:38-39`).
- **The window data struct changed** (`macdrv.h:230-245`): it is now `{hwnd, cocoa_window, client_view @16, rects @24 …}`, and `cocoa_view` is gone. Returning the real struct would make DXMT read `rects.window.left/top` as a view pointer, so a stand-in struct is required.
- **`client_view` is NULL until a client surface exists.** Only OpenGL and Vulkan create one. Asking for a metal view on a NULL view returns nothing (`cocoa_window.m:3616`, a message to nil).
- **The view must be re-shown on present.** At creation it starts visible (`window.c:1143-1157`, which presents immediately). After that:
  - Any GDI flush of the window hides it and forgets it (`surface.c:123-131`).
  - win32u never updates a surface it didn't register: `client_surface_create` doesn't add it to any list (`win32u/window.c:397-414`), the function that would register it is private (`win32u_private.h:335`), and `update_client_surfaces` only walks registered surfaces. Only `client_surface_present` (`win32u/window.c:430-444`) refreshes its size and position.
  - So a per-frame present report is required, both to undo the hide and to follow window resizes.
  - When the first GDI flush happens in a real game is INFERRED, backed by CrossOver arm64 commit 13e6a88a02: "the window stays empty with nothing in any log".
- **Lock and thread facts:** `win_data_mutex` is recursive (`window.c:2207`). Win data exists only for windows owned by this process (`window.c:521-549`), so a window from another process gets no data.

## CrossOver's approach (read from the local winecx clone `build/arm64/crossover/wine`, remote dappermint/winecx, with lazy fetch off, so no network)
- `d3dmetal.c` exports a 24-slot table (192 bytes, `:39-66`) for D3DMetal. Its `get_win_data` creates a client surface, stores it in a CFArray on the window data, and returns the old 120-byte struct (`:100-158`). The export is at `:401`; the present handler at `:429-434` calls `client_surface_present`.
- `WineMetalLayer` overrides `nextDrawable` (`d3dmetal_objc.m:43-71`) and posts `CLIENT_SURFACE_PRESENTED` to the window's thread. Supporting hooks: `cocoa_window.m:256,908,4117-4131`, `event.c:48,126,401`, `window.c:1459`.
- The arm64-1117 branch enables all of this on aarch64 specifically for DXMT: commits 713015fa9f and 13e6a88a02 (2026-08-26). 565f6386b7 (2026-09-17) fixed the call signature for 11.17. f77c272bbe also removes the GDI-flush hide, for swapchains on child windows.

## The patch (ported from CrossOver, cut down; no Makefile.in change)
**`window.c`** holds the exported table and a stand-in struct.

The table, in DXMT's slot order (VERIFIED from the binary's fixups):

| Slot | Contents |
|---|---|
| 0 | NULL |
| 1 | `dxmt_get_win_data` |
| 2 | `dxmt_release_win_data` |
| 3 | NULL |
| 4 | `macdrv_create_metal_device` |
| 5 | `macdrv_release_metal_device` |
| 6 | `macdrv_view_create_metal_view` |
| 7 | `macdrv_view_get_metal_layer` |
| 8 | `macdrv_view_release_metal_view` |
| 9 | NULL |

It is 80 bytes; DXMT calls only slots 1, 2, 6, 7 and 8.

The stand-in struct:
```c
struct dxmt_win_data { HWND hwnd; WineWindow *cocoa_window; WineContentView *cocoa_view /*NULL*/;
                       WineContentView *client_cocoa_view; struct macdrv_win_data *data; };
C_ASSERT(offsetof(struct dxmt_win_data, client_cocoa_view) == 24);
```

How it behaves:
- **`get_win_data`:** creates a client surface, then locks the window data. It stores the surface in `data->dxmt_surfaces` (a CFArray), marks the view, and returns the struct with the lock held. Release unlocks and frees it.
- **Window from another process:** it returns the struct with a NULL view, so DXMT hits its own abort message instead of the NULL dereference at 1729.
- **Window destroy:** `macdrv_DestroyWindow` releases the CFArray after unlocking. This differs from CrossOver, which releases while holding the lock and so takes the locks in the opposite order to Vulkan's present path.

**`cocoa_window.m`:** `WineMetalLayer` posts `CLIENT_SURFACE_PRESENTED` only for marked views, plus a `client_surface` field and a setter on `WineContentView`.

**`event.c` / `macdrv_cocoa.h` / `macdrv.h`:** the new event type is appended before `NUM_EVENT_TYPES`, delivered with posted messages, and handled by calling `client_surface_present`.

## Verification (VERIFIED)
- **Build:** all 23 winemac sources compiled from the patched copy with wine-build's exact flags and relinked (`build.sh`). The added code produces no new warnings.
- **Export:** `nm` and `dyld_info -exports` show `_macdrv_functions`.
- **`dlsym_test`:** it loads the library like ntdll and looks the table up like DXMT. It fails on the stock library and passes on the patched one, and confirms `get_win_data` stays hidden.

## Does DXMT's present path use x86_64-only Wine API? No (VERIFIED)
- **Lookups:** all five are by name, and the 11.19 functions keep the same arguments (`cocoa_window.m:3600-3645`, `window.c:187-210`).
- **The one break is the struct:** the field moved from offset 24 to 16, and the view is now created on demand.
- **Unused slots:** the `bool`/`BOOL` difference in `macdrv_get_cocoa_window`, the missing `macdrv_init_display_devices` and the hidden `OnMainThread` all sit in slots DXMT never calls.
- **Linked symbols:** `winemetal.so` binds only `_NtSetEvent` from ntdll.so (11.19 exports it).
- **Placement:** `winemetal.so` loads `winemac.so` and ntdll.so from its own directory, so it must sit in `Contents/Resources/lib/wine/aarch64-unix/`. The stock-path test failed with exactly "Library not loaded: @rpath/ntdll.so". Loading it is not blocked by signing, because the wine binary allows libraries signed by other teams.

## Known limits and deferred work (INFERRED; CrossOver has the same limits)
- **Possible crash on window close:** a `nextDrawable` landing between the event discard (`cocoa_window.m:3127`) and the CFArray release can queue a pointer to a freed surface. If that shows up, keep the array on the top-level window's data and check membership in the handler.
- **Per-frame cost:** every frame posts an event and runs a frame/superview update; these could be coalesced later.
- **Off-main-thread reads:** `nextDrawable` reads `view.superview` and `view.window` off the main thread.
- **Child-window swapchains:** need CrossOver's f77c272bbe (drop the GDI-flush hide); not included.
- **Holding the lock across two main-thread round trips:** same as Wine 8.16 and CrossOver. An optional hardening is to copy the fields, unlock, and make release just `free`.
- **Not D3DMetal-compatible:** the 10-slot table omits D3DMetal's 24 slots, which matters only if the x86_64 stack moves to Wine 11.19.

Files are in `/Users/chad/Documents/MacProton/build/arm64/sp2-explore/window/`:
- 0013-winemac.drv-Export-macdrv_functions-so-DXMT-can-present.patch
- build.sh
- dlsym_test.c
- winemac.so
- wine/

### tests
**SP2 test plan: running DXMT's tests on the arm64 stack**

I built all 20 test programs as ARM64EC and ran one under both lanes. That run showed three things (VERIFIED):
- The ARM64EC build runs without FEX and gets as far as `D3D12CreateDevice`.
- The x64 build needs FEX, and with FEX it gets just as far.
- Wine's own `d3d12.dll` fails here, so the arm64 stack has no built-in D3D12 to compare against.

Every arm64 check can therefore compare against either a fixed expected value or the Rosetta build of the same DXMT commit. I recommend ARM64EC builds as the main test, with x64 under FEX as a second lane.

**What I ran** (only under `build/arm64/sp2-explore/`; nothing tracked changed; wineserver stopped, no processes left):
- `tests/ec-*.exe`: the 19 `dxmt/tests/d3d12_*.cpp` plus `present_loop.c`, built with `arm64ec-w64-mingw32-clang++ -O2 -static -s -std=c++17 … -ld3d12 -ldxgi -luser32 -lpsapi`. All linked. Header machine is `0xA641` with CHPE metadata. Imports are only KERNEL32, the ucrt api-sets and d3d12. (VERIFIED)
- `wine.app`: an APFS clone of the staged bundle; `codesign --verify --strict --deep` passed. Plus a fresh prefix, `pfx`.

### (1) Which `dxmt/check.sh` checks matter for SP2, and their reference today

| Check (dxmt/check.sh) | Reference today | Matters for SP2 |
|---|---|---|
| §1 D3D11 `present_loop`, best of 3 within 10% (:77-85) | stock DXMT 0.80 | Blocked until the winemac `macdrv_functions` shim lands; then measure only |
| "the game ran our d3d11.dll", `cmp` of the prefix copy (:86-87) | fixed check | Yes: proves the setup |
| §9 E1 compression ≥3× (:92-99) | its own `DXMT_D3D12_COMPRESSION=0` run | Yes, unchanged |
| E1 views/placed lines (:100-101) | D3DMetal | Yes |
| §5 dxil-probe (:103-122), §6 dxil-translate 11/12, 31/31, flags (:680-692) | fixed values | Yes, and first: host tools on arm64 LLVM 15, no Wine needed |
| Lane A cache counters, corrupt/foreign tables, record/torn/unwritable, replay counts (:132-214) | fixed strings | Yes |
| Lane A "draws as D3DMetal" (`cache-ref-*`) | D3DMetal | Yes |
| Lane B `hazards` list (:226-232) and overlap/M2-M4/E4/E7/E10 stats | fixed values | Yes. DXMT's queue code becomes native weak-memory ARM64 code, so threading bugs Rosetta's TSO hid can show here (INFERRED) |
| Lane B `hazards-ref` with sed exceptions (:243-245) | D3DMetal | Cross-check only; drop |
| Metal validation (:251-255, :534-538) | 0 errors | Yes. INFERRED that `MTL_DEBUG_LAYER` works under the hardened runtime; check with one run |
| `d3d12_clear` presents 300/300, dump frames (:360-367) | fixed | Blocked on the shim (it creates a swap chain) |
| SM 5.1 / capture SM6.6 / `DXMT_D3D12_SM6` caps lines (:368-412) | fixed | Yes. They are printed by `d3d12_clear`, so blocked unless they appear before the swap chain |
| DXIL pipelines and capture byte-for-byte (:376-398, 413-420) | fixed / `cmp` | Yes |
| device 5-8, samples0 (:380-383) | D3DMetal | Yes |
| "op named in the log" via `MACNEUTRON_LOG` (:422-424) | launcher log | Launcher → SP5. Could grep the run's stderr instead |
| `dxil_exec` 11 groups via `compare.py`; threads 8/8 (:427-433) | D3DMetal; fixed | Yes |
| triangle / GS pixels, GS cache and replay (:434-463) | D3DMetal (`same_pixels`) | Yes |
| depth, pass dump, pixel history (:471-514) | D3DMetal; fixed | Yes |
| query, api `same_lines`, copy, null, layered, volume, vsread (:515-585) | D3DMetal | Yes |
| caps / 11 cases / 18 slots counts | fixed | Yes |
| indirect, E10, stats, timestamps, ts-leak, junk/foreign replay, bounds (:587-702) | fixed (D3DMetal also fixed) | Yes |
| D3D11 cache table via `present_loop` (:571-581) | fixed | Blocked on the shim |
| FFX swapchain (:670-676) | presented 60/60 | Needs x64 under FEX (the DLL is x64) and presenting |
| "D3DMetal still works" (:678) | — | Rosetta only; not applicable |
| queues / deferred stats (:713-728) | fixed | Yes |
| §10 launcher precache/stamp (:729-744) | launcher | SP5 |
| `presenter/check.sh` | D3DMetal plus `DYLD_INSERT_LIBRARIES` | SP5: the hardened runtime ignores `DYLD_*` |

Facts behind this table (VERIFIED):
- **Only the swap-chain path needs winemac.** DXMT looks up the macdrv symbols only in `_CreateMetalViewFromHWND` and its release (`winemetal_unix.c:1704-1755`, fork `1fba8d2`). Every read-back test above is free of the shim.
- **The last dxmt-check (today 14:39-14:45)** had 115 launches, 24 of them reference runs, and no FAIL lines.
- **Our DXMT already matches D3DMetal line for line** in compress, copy, depth, dxil, exec (all 11 groups, transcendental included), indirect, null, query, tri, trigs, volume and vsread.
- **The only differences are expected ones:**
  - api: only the `caps` line (ours `rt=0 mesh=0`, D3DMetal `rt=11 mesh=10`);
  - bounds: the documented straddle case;
  - hazards: the three sed exceptions;
  - layered: D3DMetal rounding, `ff80…` against `ff7f…`.

### (2) What each check compares against on the arm64 stack
- **Fixed-value checks** (most of the table): reuse the strings verbatim; no reference run needed.
- **D3DMetal comparisons:** use our own DXMT on the Rosetta stack, same fork commit.
  - The tests print deterministic hex.
  - LLVM is built with `-DLLVM_TARGETS_TO_BUILD=""` (`dxmt/build.sh:84-86`), so it only manipulates IR. Exact matches across host architectures are expected (INFERRED). Keep `same_pixels`' 1/255 anyway.
  - The Rosetta build itself is checked against D3DMetal by dxmt-check, so the chain holds.
- **Record the reference rather than run it live** (lazy option): dxmt-check already writes `*-ours.txt`, but in a work folder it wipes each run (`dxmt/check.sh:23`). Copy those files once per pin to `build/dxmt-ref/<commit>/`, with the GPU and macOS version noted. The arm64 check then refuses a snapshot whose commit differs.
  - Zero cost at check time.
  - These files become the golden references once Rosetta is gone (spec §1).
- **If run live instead,** do it through check.sh's `rosetta()` (:271-274), and first run `install-dxmt --tool-dir "$RTOOL" build/dxmt` (as `dxmt/check.sh:30` does) plus a check that `dxmt-version` equals the pin. Otherwise the reference is whatever DXMT the installed tool happens to hold.
  - Today it holds the pin `1fba8d2` (VERIFIED), but nothing guarantees that: `DXMTBuild.bundled` (`DXMTInstaller.swift:37-43`) finds nothing next to `.build/release/macneutron` (VERIFIED: no `DXMT/` there).
  - Cost: about 30 extra Rosetta launches per run.
- **D3D11 timing against DXMT 0.80:** no arm64 equivalent. Frame time against Rosetta's DXMT is measured, not gated, like G4. That comparison is SP6's job.
- **Built-in reference: none.** Wine's `d3d12.dll` returns `0x80004005` with "Wine was built without Vulkan support" (VERIFIED, `sp2-explore/ec-null.err`).

### (3) x64 builds under FEX vs ARM64EC builds
**What changes:**
- Triple: `x86_64-w64-mingw32-clang++` becomes `arm64ec-w64-mingw32-clang++`, the same llvm-mingw wrapper script (VERIFIED).
- Import libraries come from `aarch64-w64-mingw32/lib`; there is no separate arm64ec sysroot (VERIFIED). The libraries stay the same.
- `-fms-extensions` isn't needed: there is no `__try` in `dxmt/tests` (VERIFIED by grep).
- `-static` stays (C++ tests would otherwise import `libc++.dll`; spec §7.3).
- No source changes: no asm, `__rdtsc` or `__cpuid` in the tests (VERIFIED).

**Running them:**
- ARM64EC exes run before the `fex` step (ec run 1-2 reached `D3D12CreateDevice`; VERIFIED). check.sh already runs `isec` that way (:30-32).
- x64 exes before FEX print nothing ("x64 emulation not implemented"; VERIFIED), and work after `reg add` (VERIFIED).

**Pick ARM64EC as the main test** (it is what the roadmap row says):
- No dependency on FEX, so a failure is DXMT's port.
- Runs at native speed.

**Keep x64 under FEX as the integration lane:**
- It is what games do: x64 code calling into DXMT's ARM64EC code through entry thunks on every COM call, struct returns (`WIDL_EXPLICIT_AGGREGATE_RETURNS`, `d3d12_common.hpp:3`) and callbacks such as WndProc. ARM64EC exes skip those thunks.
- It runs the exact binaries the Rosetta reference ran.
- FFX requires it.

Linking only proves the ARM64EC build compiles; the ABI is proven by running. ARM64EC test exes need only an ARM64EC DXMT. A pure aarch64 exe would need ARM64X; which one SP2 builds is the build task's call.

**Build hookup:** one Makefile pattern rule like `build/dxmt-tests/%.exe` (Makefile:54-55), outputting to a separate folder such as `build/dxmt-tests-arm64ec/` with the same basenames. Keep the basenames because the expected strings contain them: `d3d12_cache.exe.pipelines` (:179), `$UC/d3d12_cache.exe` (:200), `precache: d3d12_cache\.exe` (:741). DXMT keeps Metal caches by executable name under `DARWIN_USER_CACHE_DIR`, so the arm64 and Rosetta runs must not run at the same time.

### (4) Fitting into `wine-arm64/check.sh`
- **Stage layout:** stage DXMT as `build/dxmt-arm64/{aarch64-windows,aarch64-unix}`, the same layout as `build/dxmt/x86_64-*`. That folder can be a `WINEDLLPATH` entry as is:
  - `loader.c:300-318` appends `WINEDLLPATH` after the bundle's own folder;
  - `loader.c:1264-1302` finds `<entry>/aarch64-windows/winemetal.dll` and sets its unix library to `<entry>/aarch64-unix/winemetal.so`;
  - `virtual.c:857-878` loads that library only for builtins, so the builtin-marker check stays (`dxmt/build.sh:119-121`). (VERIFIED)
- **Don't copy winemetal into the bundle clone** the way `DXMTInstaller.swift:72-80` does: anything added after signing breaks the `signature` step (:131).
  - `wine.entitlements` has `disable-library-validation` (VERIFIED), so an ad-hoc-signed `.so` outside the bundle should load (INFERRED).
- **Front-end DLLs:** `d3d11, d3d10core, dxgi, d3d12.dll` go to `$PFX/drive_c/windows/system32/`, as `prefixDLLs` does (`GraphicsBackend.swift:44-59`). On arm64 that folder serves x64 processes too: the ARM64EC test loaded `C:\windows\system32\d3d12.dll` (VERIFIED, `+loaddll`). There is no syswow64 or 32-bit part until SP8.
- **Overrides:** `WINEDLLOVERRIDES="dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b"` (`GraphicsBackend.swift:35`).
- **Step model:**
  - Add a `dxil-tools` step (no prefix).
  - Add a `dxmt` setup step: copy into system32, check the version against `dxmt/pins`, check the builtin marker.
  - Add one step per test program: ARM64EC steps, plus `x64-*` steps listed in `NEEDS_FEX`.
  - Add a `NEEDS_DXMT` list that puts `dxmt` in front, using the same loop as :333-339.
  - The steps run in subshells (:99), so `export` doesn't carry over between steps. Set `WINEDLLPATH`, the overrides and `DXMT_SHADER_CACHE_PATH` inside a `dxmt_run` helper next to `wine_run` (:119). The `MACNEUTRON_*` variables are dropped; they belong to the launcher.
- **Trade-off:** steps run serially and stop at the first failure (:96-117); dxmt/check.sh runs 5 lanes and reports everything. Run all of a step's checks before it returns 1, so one step still shows all its failures. Leave parallel lanes out until the time hurts.
- **Cleanup:** `runtime_pids` and `cleanup` already cover `$TOOL` and `$RTOOL`.

### (5) Runtime cost
**Measured on the arm64 stack (VERIFIED, this Mac):**

| Run | Time |
|---|---|
| Fresh prefix boot | 8 s |
| First D3D launch in a new prefix | 13 s, once |
| ARM64EC D3D12 test, stopping at device creation | 1.9-2.4 s per launch |
| x64 under FEX, same test | 2.2-2.7 s per launch |
| Trivial ARM64EC exe (`isec`) | 0.08 s |

Wine's graphics and desktop startup dominate; FEX adds about 0.3 s at this size.

**Today's Rosetta check:** dxmt-check took 5 min 44 s wall (5 min 53 s in `acceptance-arm64-wine.md:114`). The lanes took 141-186 s each in parallel, about 800 s of lane work. Serialized, that is about 15 min (INFERRED from file times).

**arm64 estimate (INFERRED):**
- About 90 DXMT launches with the reference runs dropped: roughly 10-13 min serial.
- Plus the x64 lane: about +2-3 s per program duplicated.
- Plus a live Rosetta reference: about +4-5 min. A recorded snapshot costs about 0.
- Added to `make wine-arm64-check`'s current 7 min 22 s, that is about 20 min serial.
- Use `sh wine-arm64/check.sh <steps>` while developing.

### bundle
**SP2 layout: where DXMT goes in wine.app and what the Swift side expects**

Short answer: everything of DXMT's goes inside wine.app and is signed together with Wine. Both winemetal files go next to Wine's own files. The front-end DLLs, licences and version file go in a new `Contents/Resources/DXMT/`. The Swift side copies the front ends from the bundle into each prefix and never writes into the bundle.

## (1) Today's split on the Rosetta stack (all VERIFIED)
- **Unix side.** `build.unix/x86_64-unix/*` (just `winemetal.so`) is copied to `Libraries/Wine/lib/wine/x86_64-unix/` (DXMTInstaller.swift:72-76).
- **winemetal.dll.** Each arch's copy goes to `Libraries/Wine/lib/wine/{x86_64-windows,i386-windows}/winemetal.dll` (DXMTInstaller.swift:79-80). It is the "builtin" one: it carries Wine's builtin marker, and dxmt/build.sh:119-122 asserts that.
- **Front ends.**
  - `Libraries/DXMT/x64/{d3d11,d3d10core,dxgi,d3d12}.dll` plus `dxmt-replay.exe`.
  - `Libraries/DXMT/x32/{d3d11,d3d10core,dxgi}.dll` (DXMTInstaller.swift:56-59, 81-82).
  - They must not carry the builtin marker (dxmt/build.sh:94-96, 123-128).
- **Version.** `dxmt-version` is written to the tool folder root, deleted first and written last (DXMTInstaller.swift:66-71, 85; ToolLayout.swift:50).
- **Copies into the prefix on every launch** (GraphicsBackend.swift:44-58, PrefixManager.swift:61-71):
  - `x64/<dll>` goes to `drive_c/windows/system32/<dll>`.
  - `x32/<dll>` goes to `drive_c/windows/syswow64/<dll>`.
  - `x64/d3d12.dll` goes to system32 only when it exists.
- **DLL overrides** (GraphicsBackend.swift:35-36):
  - With d3d12: `dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b`.
  - Without: `dxgi,d3d10core,d3d11=n,b;d3d9,d3d10,d3d12=b`.
  - User values win the merge (LaunchEnvironment.swift:10, 28-44).
- **Shader replay** runs `wine Libraries/DXMT/x64/dxmt-replay.exe Z:<rec>` (ShaderPrecache.swift:80).
- **Inside MacNeutron.app** (Makefile:79-85):
  - The Windows side, `version` and the licences go in `Contents/Resources/DXMT/`.
  - `x86_64-unix/` goes in `Contents/Frameworks/DXMT/` and is signed ad hoc.
  - `published.sh` runs first.
- **Updates.** A new DXMT is installed from the app bundle when its version differs, at every app start (AppModel.swift:76) and after a runtime install (RuntimeInstaller.swift:104).

## (2) Must DXMT be built into the bundle?
**Sealing (VERIFIED).** On an APFS clone of wine.app, adding a PE DLL or a text file anywhere under `Contents/Resources` after signing fails `codesign --verify --strict --deep` with "a sealed resource is missing or invalid". The user's machine has no Developer ID key, so the Swift side can never add files to wine.app.

**Wine itself would not notice (VERIFIED).** Patch 0007 only reads the entitlements (`SecStaticCodeCreateWithPath` plus `SecCodeCopySigningInformation`, patch lines 94-95) and never checks the seal. So a modified bundle would still run, but it would fail verification and notarization.

**Could winemetal live outside the bundle?**
- In principle, by signature, yes. Wine searches `WINEDLLPATH` after `dll_dir` (loader.c:300-318). A builtin's unix library is looked for in `<that path>/aarch64-unix/` (loader.c:1264-1281). wine.entitlements has `disable-library-validation`.
- That relies on `WINEDLLPATH` surviving the 4K-page re-exec, which I did not check (INFERRED).

**In practice, no.**
- `winemetal.so` loads `@rpath/winemac.so` and `@rpath/ntdll.so`, and its only rpaths are `@loader_path/` and `@loader_path/../../` (otool; unix/meson.build:6-21).
- I tested a copy of that setup in sp2-explore (VERIFIED on a toy library):
  - Loaded from another directory before winemac.so is loaded, it fails with "Library not loaded: @rpath/winemac.so".
  - It works only if winemac.so is already loaded, or if it sits in the same directory.
  - `dxmt-replay.exe`, or a device created before any window, would hit the failing case.
- `winemetal.so` is also linked against this exact Wine's `winemac.so` and `ntdll.so`, plus the planned `macdrv_functions` shim patch. Shipping them in one bundle is the only thing that keeps them matched.

**So:**
- The Mach-O half (`winemetal.so`) and `winemetal.dll` must be in the bundle, signed by bundle.sh.
- The front-end PE DLLs could live anywhere, since they are copied into the prefix. Keeping them in the bundle is simpler: one artifact, one version, and no install step.

**Build order forces this into build.sh (VERIFIED).**
- Everything `-Dwine_build_path` needs is already in `build/wine-arm64-src/wine-build`: `libs/winecrt0/aarch64-windows`, `dlls/ntdll/aarch64-windows/libntdll.a`, `dlls/dbghelp/aarch64-windows/libdbghelp.a`, `tools/winebuild/winebuild`, `dlls/winemac.drv/winemac.so`, `dlls/ntdll/ntdll.so`.
- So DXMT builds after build.sh step 4 (make) and before step 6 (bundle).
- DXMT's own `build-arm64ec.txt` uses `arm64ec-w64-mingw32-gcc` with `-marm64x`, and llvm-mingw has those wrappers.
- With `wine_builtin_dll=false`, meson installs the front ends to `system32/`, winemetal.dll to `aarch64-windows/` and winemetal.so to `aarch64-unix/` (meson.build:174-185).
- Whether `-marm64x` also needs Wine's `arm64ec-windows` import libraries (they exist) is INFERRED and needs a test build.

**Three checks the first SP2 build will hit:**
1. **Signing.** No new signing code is needed: bundle.sh's `macho()` signs every Mach-O it finds (bundle.sh:46, 50-54). The hook is a `cp` between bundle.sh:41 and :46.
2. **minos.** bundle.sh:61-64 requires minos 27.0 on every Mach-O. build.sh:30 exports `MACOSX_DEPLOYMENT_TARGET=27.0`; that meson's native link picks it up is INFERRED and needs checking.
3. **Up-to-date stamp.** `stamp_of` (build.sh:66-68) must also cover `dxmt/pins` and the DXMT build inputs. Otherwise a pin bump exits "up to date" (build.sh:91-94).

**arm64 LLVM.** The existing LLVM 15 is x86_64-only (`-DCMAKE_OSX_ARCHITECTURES=x86_64`, dxmt/build.sh:85). The arm64 airconv in winemetal.so needs its own LLVM build, about 30-60 minutes once, in a separate folder. I did not build it.

## (3) Smallest SP2 layout (codesign verify VERIFIED on a clone, ad hoc re-sign with entitlements kept)
```
wine.app/Contents/Resources/lib/wine/aarch64-windows/winemetal.dll   ARM64X, builtin marker (next to libarm64ecfex.dll)
wine.app/Contents/Resources/lib/wine/aarch64-unix/winemetal.so       next to winemac.so/ntdll.so; signed by macho()
wine.app/Contents/Resources/DXMT/aarch64-windows/{d3d11,d3d10core,dxgi,d3d12}.dll, dxmt-replay.exe   ARM64X, no marker
wine.app/Contents/Resources/DXMT/{version,COPYING.LIB,LICENSE,LICENSE.OLD}
```
- The test bundle had that layout and passed `codesign --verify --strict --deep` (Developer ID makes no difference to the seal).
- Wine's own aarch64-windows DLLs are ARM64X (d3d11.dll has CHPEMetadata, VERIFIED). That fits x64 games under FEX loading system32 DLLs (INFERRED for DXMT's native front ends).
- No 32-bit parts until SP8.

**check.sh step:**
- After `boot`, copy `$TOOL/Contents/Resources/DXMT/aarch64-windows/*.dll` into `$PFX/drive_c/windows/system32/`. The prefix is outside the bundle, so `signature` still passes.
- Use `WINEDLLOVERRIDES="dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b"` (GraphicsBackend.swift:35) and `MACNEUTRON_NO_METALFX`-equivalent conditions (no presenter).
- **Gaps to fill:**
  - **Pixel reference.** dxmt/check.sh compares pixels against D3DMetal, which is x86_64-only (spec §1). The reference available is the Rosetta tool clone check.sh already keeps (`RTOOL`/`RWINE`, check.sh:22-25).
  - **ARM64EC test builds.** The Makefile's arm64ec rules only match `wine-arm64/tests/arm64ec-*.c` (Makefile:110-111). `dxmt/tests/*.cpp` and `present_loop.c` only have x86_64 rules (Makefile:38, 54-55), and those x86_64 builds can also run under FEX.

## (4) What SP5 will need
- **`ToolLayout` per runtime.** Everything is hard-coded to the Rosetta layout today:
  - `wine` becomes `wine.app/Contents/MacOS/wine`, `wineserver` becomes `Contents/Resources/bin/wineserver`.
  - The DXMT folder becomes `Contents/Resources/DXMT`.
  - `dxmtVersion` is read from `DXMT/version` in the bundle, not from root `dxmt-version`.
  - `dxmtD3D12` and `dxmtReplay` move to `aarch64-windows/`.
- **`GraphicsBackend`.**
  - On arm64, copy to system32 only.
  - `select()` must force dxmt, since there is no D3DMetal or DXVK on arm64.
  - The override strings stay as they are.
- **`DXMTInstaller`.** `installBundled` runs at every app start (AppModel.swift:76) and after a runtime install (RuntimeInstaller.swift:104). It must never touch wine.app (the seal test is the proof). For arm64 there is nothing to install.
- **Presenter.** wine.entitlements has no `allow-dyld-environment-variables`, which is why `DYLD_INSERT_LIBRARIES` is ignored (VERIFIED). SP5 either adds that entitlement or loads the presenter from code, for example by `dlopen` from winemetal.so. The presenter is already built for both architectures (Makefile:35) but with no deployment target, so bundle.sh's minos check would reject it as it is.
- **Shader caches.**
  - Pipeline recordings live per compatdata (`<compatdata>/dxmt-pipelines`, stamped `"<dxmt-version> <macOS build>"`, ShaderPrecache.swift:13-16). Two runtimes with different DXMT commits would trigger a replay at every switch, so keep one DXMT pin for both, or key the stamp per runtime.
  - The translation cache is keyed by `git describe --always` (meson.build:143-147) under `DARWIN_USER_CACHE_DIR/dxmt/<exe>`, which both runtimes would share. Whether airconv's output is the same on both host architectures is INFERRED.
- **Notarization.** Any DXMT update means rebuilding, re-signing and re-notarizing wine.app. That is inherent to putting it in the bundle.

## (5) Licences
- I searched wine.app for licence files and found none (VERIFIED). That includes Wine's LGPL and FEX's MIT files: not SP2's job, but worth flagging for SP3/SP5.
- **For DXMT:**
  - Copy `COPYING.LIB`, `LICENSE`, `LICENSE.OLD` from the fork clone, plus `version` (the `DXMT_COMMIT`, as dxmt/build.sh:118 and :130 do), into `Contents/Resources/DXMT/` before signing. This mirrors Makefile:80-82.
  - Any shipping path must run `dxmt/published.sh <clone> <commit>` (Makefile:79) for the commit inside wine.app.

## Experiments
All under `/Users/chad/Documents/MacProton/build/arm64/sp2-explore/`:
- `seal/` — adding files after signing breaks verify.
- `rpath/` — the `@rpath/winemac.so` test, working and failing cases.
- `layout/` — the proposed layout, re-signed, passes verify.

Nothing tracked, nothing in `build/dxmt*` or `build/wine-arm64*`, and nothing in the installed tool folder was modified.

### upstream
Upstream DXMT already builds an ARM64X Windows side and an arm64 `winemetal.so`, and that output runs on CrossOver 27 Preview. The only missing piece for SP2 is the winemac export. Nothing was built, downloaded or modified. I created the empty `/Users/chad/Documents/MacProton/build/arm64/sp2-explore/`.

Local evidence comes from:
- `/Users/chad/Documents/MacProton/build/dxmt-src/dxmt`, where `origin/main` is the chadouming fork's main. It was fetched 2026-10-02 and is level with upstream `7c8dee1`.
- `/Users/chad/Documents/MacProton/build/wine-arm64-src/{wine,wine-build}`, which is Wine 11.19 (`455e350`, 2026-10-02) plus the SP1 patches.

## 1. Does upstream 3Shain/dxmt build ARM64EC/ARM64X?
**Yes, in CI since March 2026. No tagged release contains it.**

**Timeline (VERIFIED from the local git log):**
- `db4720e` (2026-02-17): "feat(util): detect arm64ec ABI".
- PR #127 "WIP: ARM64EC Support" (https://github.com/3Shain/dxmt/pull/127): open Feb 17 to Mar 9, closed 2026-03-23. 3Shain on why it couldn't work yet: "until Wine ARM64EC is supported on macOS".
- `7ef5d9c` (2026-03-09): "build: add arm64ec support". This added `build-arm64ec.txt`, made the install dirs `aarch64-windows` and `aarch64-unix` (`meson.build:174-185`), built the native side with `-arch arm64` (`:191`), and built airconv and winemetal unix for aarch64.
- `a3a6e8f` (2026-03-07): adds the `libs/winecrt0` path needed for Wine 11.4 and later.
- `25d4a26` (2026-03-12): first CI jobs using `build-arm64ec.txt`.
- `856d9f3` (2026-08-04), PR #202: the ARM64EC build is packaged into the combined tarball.
- `3b78076` (2026-08-26), merged 2026-09-17 as PR #209: `-marm64x` added to the c/cpp compile and link args, which gives ARM64X DLLs. PR #209 also brought `20af9fc` (hot-patchable DXGI, for overlays on ARM64EC) and `7c8dee1` (`stb_image` SIMD disabled for arm64).
- Earlier: PR #76 (merged 2025-07-15), a native macOS/arm64 dylib build. `89a1a60` (2025-07-10), arm64 spin.

**CI recipe** (`.github/workflows/ci.yml` on origin/main, VERIFIED):
- **LLVM:** 15.0.7 (`:21`). Job `setup-llvm-darwin-arm64` (`:245`) builds it with `-DCMAKE_OSX_ARCHITECTURES=arm64` (`:272`), `LLVM_HOST_TRIPLE=arm64-apple-darwin`, `TARGETS_TO_BUILD=""` and assertions on.
- **Wine to link against:** `WINE_ARM64EC_URL` = 3Shain/wine release `wine-11.2` (`:24-25`). The API shows it published 2026-02-17 at plain upstream Wine 11.2 (`87ba10b`, julliard's "Release 11.2."). Its release note: "Do not use, it doesn't work (yet) and only aims for linking of DXMT."
- **Build:** `meson setup --cross-file build-arm64ec.txt -Denable_nvapi=true -Denable_nvngx=true -Dnative_llvm_path=toolchains/llvm-darwin-arm64 -Dwine_install_path=toolchains/wine` (`:595`).
- **D3D12:** the arm64ec jobs never pass `-Denable_d3d12=true`; the x64 jobs do (`:417`, `:463`). Upstream D3D12 on arm64ec is untested.
- **Toolchain:** llvm-mingw 20260908, the same version `dxmt/pins:13` already pins.

**Releases:** the latest is v0.80, published 2026-04-23 with one asset, `dxmt-v0.80-builtin.tar.gz`. That is before the ARM64EC packaging, so ARM64 output exists only as main-branch CI artifacts. (VERIFIED, API: https://api.github.com/repos/3Shain/dxmt/releases)

**Upstream commits after our fetch** (https://github.com/3Shain/dxmt/commits/main, VERIFIED):
- `c5f854c` (2026-09-29): adds `-DCMAKE_CXX_FLAGS=-D_LIBCPP_KEEP_TRANSITIVE_INCLUDES_LLVM23` to all three LLVM builds.
- `e86484e`: adds `-DLLVM_INCLUDE_BENCHMARKS=Off`.
- `fb45156` (2026-10-01): fixes `device_` being used before it is initialised (crash in the ClearUAV pipeline).
- Our `dxmt/build.sh:84-88` has neither LLVM flag. INFERRED: an arm64 LLVM 15 build on the current SDK will need them.

**CodeWeavers connection:** Feifan He (3Shain) commits as feifan@codeweavers.com: 227 commits, the first on 2026-04-25. Marc-Aurel Zent has 17 commits as mzent@codeweavers.com, and Brendan Shanks has 2 (bshanks@codeweavers.com, e.g. `6eee76a`). VERIFIED from git log. INFERRED: upstream's arm64ec CI build is in effect CrossOver's DXMT build.

## 2. Issues/PRs about arm64 and Wine 11, and how upstream binds windows
- **The brief's framing is wrong.** Vanilla Wine never exported `macdrv_functions`. It is a CodeWeavers-only table (section 3).
  - What vanilla does: it builds unix libraries with `-fvisibility=hidden` (`wine/configure.ac:1943`). Our `winemac.so` exports only `___wine_unix_call_funcs` and `___wine_unix_call_wow64_funcs` (VERIFIED with `nm -gU` on `wine-build/dlls/winemac.drv/winemac.so`).
  - What else changed: the 11.x `struct macdrv_win_data` is now `{hwnd; WineWindow *cocoa_window; WineContentView *client_view; struct window_rects rects; ...}` (`wine/dlls/winemac.drv/macdrv.h:230-245`), with no `cocoa_view`.
  - Effect: DXMT's mirror struct (fork `winemetal_unix.c:1683`, upstream `:1664`) would read `client_cocoa_view` from the start of `rects`. A shim must return DXMT's layout, not the real struct.
- **Upstream binding today** (origin/main `winemetal_unix.c`):
  - It first does `dlsym(RTLD_DEFAULT,"macdrv_functions")` (`:1694`, `:1728`).
  - If that fails, it falls back to `dlsym` of `get_win_data`, `release_win_data`, `macdrv_view_create_metal_view` and `macdrv_view_get_metal_layer` (`:1700-1703`). The fallback was added in `8b6ecca` (2025-04-21).
  - DXMT reads only 9 table entries (`:1671-1681`) and uses 5. There is no Wine-11 layout handling upstream.
- **Issue #170** (https://github.com/3Shain/dxmt/issues/170), "Wine 11.x support: macdrv_win_data layout change + RTLD_GLOBAL break Metal view creation". Opened 2026-06-14 by cyyever, closed "completed" by 3Shain on 2026-06-15: "It's not really a DXMT bug, but #166 is the intended solution."
  - cyyever's Wine patch: https://github.com/cyyever/wine/commit/c5375ee66cb355bb949d60e952da3bf9323d7bc3, "winemac/ntdll: export macdrv_functions for DXMT". It changes `window.c` (+72), adding a default-visibility table, a DXMT-layout `get_win_data` shim, and on-demand `macdrv_create_view` plus `macdrv_set_view_superview`. It also changes `loader.c` to dlopen with `RTLD_GLOBAL`.
  - Both of those helpers exist in 11.19 (`macdrv_cocoa.h:494`, `:497`, VERIFIED), so the patch ports cleanly. Its license is LGPL (Wine).
  - The `RTLD_GLOBAL` change is INFERRED to be unnecessary on macOS. `man 3 dlopen` on this host says "If neither RTLD_GLOBAL nor RTLD_LOCAL is specified, the default is RTLD_GLOBAL", and Wine uses plain `RTLD_NOW` (`loader.c:861`, `:1412`). Confirm by testing after the patch.
- **PR #166** (https://github.com/3Shain/dxmt/pull/166), by marzent, opened 2026-06-03 and still open: "implement getting Metal layer from HWND via ExtEscape". It is paired with Wine MR !11058.
  - Interface: `MACDRV_ESCAPE_GET_SURFACE 6790` / `RELEASE_SURFACE 6791`, `struct macdrv_escape_surface {UINT64 surface; UINT64 layer;}`, called through `GetDC` + `ExtEscape` in `d3d11_swapchain.cpp`, with the old path as fallback.
  - Status: the MR page is blocked by GitLab's Anubis bot check, so its state is unknown. Wine 11.19 has no `ESCAPE_GET_SURFACE` or 6790 (VERIFIED by grep). Not usable today; worth tracking.
- **Other issues/PRs:**
  - #206 (closed 2026-08-24): presents to a non-newest swapchain are never composited.
  - #183/#184: per-HWND Metal view refcount (ANGLE white screen).
  - #201 (closed 2026-08-04): request for ARM64 NVAPI/NVNGX binaries.
  - All VERIFIED via issue search.

## 3. CrossOver's ARM64 DXMT
- **Blog:** https://www.codeweavers.com/blog/mjohnson/2026/7/31/crossover-preview-the-right-to-bear-arm64-on-mac returned 403 and the archive.org copy was unreachable, so I did not read it.
  - From search snippets only (INFERRED): the ARM64 builds include ARM64 DXMT and recommend the DXMT backend; FEX is a custom macOS port; the build is universal; ARM64 needs macOS 26.5 or later.
  - AppleInsider (https://appleinsider.com/articles/26/07/31/first-apple-silicon-native-crossover-build-in-testing-as-rosettas-end-nears, VERIFIED) quotes "No D3DMetal in this build", plus no launchers and no bottle conversion. CrossOver 27 is due early 2027.
- **Source:** https://www.codeweavers.com/crossover/source lists only `crossover-sources-26.3.0.tar.gz`. No 27 or arm64 sources are published (VERIFIED).
- **The shim CodeWeavers wrote:** CrossOver 26 Wine is mirrored at https://github.com/athei/wine, branch `cx-26-patched`, VERSION = "Wine version 11.0". The file is `dlls/winemac.drv/d3dmetal.c` (2023, Brendan Shanks/CodeWeavers, LGPL-2.1+). VERIFIED via raw view.
  - **Guard:** the whole file sits inside `#if defined(__x86_64__)` (line 24), so in CrossOver 26 it is x86_64-only.
  - **Table:** `DECLSPEC_EXPORT struct macdrv_functions_t macdrv_functions` has 24 entries, `C_ASSERT == 192`. Its first 9 match DXMT's order exactly. `DECLSPEC_EXPORT` means `visibility("default")` (`include/winnt.h:185`).
  - **`my_get_win_data`:** builds a client surface, then returns a calloc'd `d3dmetal_macdrv_win_data {hwnd; cocoa_window; cocoa_view; client_cocoa_view = client_surface->cocoa_view; ...}`. That prefix matches DXMT's struct.
  - **CrossOver-only dependencies:** `macdrv_client_surface_create`, `macdrv_set_view_d3dmetal_client_surface`, and the `data->d3dmetal_client_surfaces` CFArray field.
  - **Vanilla 11.19 equivalents:** `macdrv_CreateClientSurface(hwnd, pixel_format, raw)` (`window.c:1142`), `impl_from_client_surface` (`:1136`) and `client_surface_release` (`gdi_driver.h:282`), all VERIFIED.
- **Runtime proof:** https://github.com/ProbabilityEngineer/EDHM-UI-Mac/releases/tag/dxmt-arm64ec-7c8dee1 (2026-09-19) ships unmodified upstream `7c8dee1` ARM64X `d3d11`/`dxgi`/`winemetal`/`d3d10core.dll` plus an arm64 `winemetal.so`. It was "tested only with Elite Dangerous Odyssey + EDHM on CrossOver Preview 27.0.0.40921" (VERIFIED from the release text).
  - `7c8dee1` is our fork's merge base.
  - INFERRED: CrossOver 27's arm64 winemac exports `macdrv_functions` with the x86_64 guard removed. athei/mtld3d PR #994 also states CrossOver 27 arm64 has the `WineMetalLayer` hook and a `d3dmetal_client_surface` field.

## 4. Gcenx and other arm64 builds
- **Gcenx:** no arm64 Wine or DXMT found. https://github.com/Gcenx/macOS_Wine_builds/releases has only x86_64 wine-devel up to 11.18, and Gcenx/winecx returns 404. A negative result.
- **gauthierpiarrette/highball #5** (https://github.com/gauthierpiarrette/highball/issues/5, 2026-08-24): Gcenx 11.x lacks `macdrv_functions`, Sikarugir 10.0_6 has it, and their CrossOver-26.3-based Wine 11 exports it and runs DXMT.
- **alexwinskii/steam-on-m1-wine** (https://github.com/alexwinskii/steam-on-m1-wine/releases/tag/prebuilt-macos26-1, 2026-09-28): rebuilds x86_64 Wine 11.0 winemac with `-fvisibility=default` plus a roughly 150-line DXMT fork (`notpop/dxmt@debug/present-path-tracing`). This is the alternative to a shim table. MIT.
- **athei/mtld3d** (zlib, D3D9→Metal):
  - PR #994, merged 2026-10-03: calls win32u `client_surface_present` itself and turns the layer into a plain `CAMetalLayer` on the main thread, avoiding Wine's off-main-thread `nextDrawable` override.
  - It uses ARM64X builds on CrossOver 27 arm64.
  - https://github.com/athei/wine-build builds "ARM64X link libraries" (`arm64ec,aarch64`, link-only).
- **License warning:** willfaust/Madeira (iOS; Wine 11.4 ARM64EC + FEX + DXMT, `wineios-drv`, no winemac) and the willfaust/dxmt and DAthensT/dxmt forks (`build-aarch64-win.txt`, `build-arm64ec-win.txt`) carry GPL-3.0-or-later changes. Don't copy their code into the LGPL fork.

## Shortcuts and blockers for SP2
1. **Build: no new cross file is needed.** Upstream's `build-arm64ec.txt` (with `-marm64x`), `meson.build` aarch64 branches and the arm64 LLVM 15 CI recipe are already in our fork. The SP1 tree has `libs/winecrt0/aarch64-windows/libwinecrt0.a`, `dlls/ntdll/aarch64-windows/libntdll.a` and `dlls/dbghelp/aarch64-windows/libdbghelp.a`, which `-Dwine_build_path` needs (VERIFIED). Add `c5f854c` and `e86484e`'s LLVM flags.
2. **`__rdtsc`:** fork-only. It comes from `d245c13` (2026-09-30, `src/d3d12/d3d12_stats.cpp:71,160,185,190`); upstream has no such file.
3. **winemac shim:** port CodeWeavers' `d3dmetal.c` (first 9 entries are enough), or cyyever's `c5375ee66cb`. Both are LGPL and Wine-11-based. Drop the x86_64 guard and swap in the vanilla client-surface functions above. The `RTLD_GLOBAL` loader change is probably not needed.
4. **Open risk (INFERRED):** "nothing presents" can survive the export fix. In 11.x, client surfaces are attached and detached lazily (`window.c:1066-1110`). The shim must choose one of three approaches:
   - CodeWeavers: keep the surfaces on the window, plus the `WineMetalLayer` hook.
   - mtld3d #994: present the client surface yourself and reclass the layer to plain `CAMetalLayer`.
   - cyyever: a direct view that bypasses client surfaces.
5. **Upstream route later:** DXMT #166 plus Wine !11058 (ExtEscape 6790/6791) removes the need for a shim once both merge. Neither is in 11.19.