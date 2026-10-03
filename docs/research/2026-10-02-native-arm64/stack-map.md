# MacNeutron arm64 migration: planning brief (2026-10-02)

**Tags.** **V** = verified in the repo or the installed runtime (by the maps or by me today). **Vw** = web source verified (skeptic pass or me), with URL and date. **I** = inferred. **U** = unverified, carried with that label. Claims tagged REFUTED were dropped and their corrections used.

**Path shorthand.** `Core/` = `Sources/MacNeutronCore/`. `UI/` = `Sources/MacNeutronApp/`. `fork:` = `build/dxmt-src/dxmt` at `1fba8d2`. `rt:` = the installed runtime at `~/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron`.

## TL;DR
- **"One pass" exists already.** The target is one native arm64 process: FEX ARM64EC translates x86, Wine runs as ARM64EC, and DXMT is ARM64X with an aarch64 `winemetal.so`. Each x86 block is translated once, and Win32 and D3D run as native code. Do not build a fused translator (§6).
- **The biggest gate is `com.apple.developer.cross-architecture-support`.**
  - It decides the Wine base, the 32-bit design, and possibly whether x64 code under FEX can run without it.
  - Ad-hoc signing with that entitlement is killed at launch (V on this Mac).
  - Whether Apple grants it to third parties is U.
- **DXMT is close.**
  - One compile blocker.
  - LLVM 15 needs an arm64 build.
  - It must link against an arm64 Wine.
  - It can be tested without FEX, using ARM64EC-built test programs, while the FEX crash is debugged in parallel.
- **D3D9.** Import dacevedo12/dxmt `v0.4-d3d9`. It does not depend on the CPU architecture, so it can ship on today's Rosetta stack first.
- **32-bit games stay on Rosetta** until the entitlement question is answered.
- **The spike left nothing on disk.** The age cleanup removed its scratchpad. Rebuild under `build/` instead, which is gitignored (`.gitignore:3`, V).

---

## 1. x86_64/Rosetta assumption table (merged, one row per site)

**Fate key.**
- **DIES**: goes away.
- **ARM64 TWIN**: needs an arm64/ARM64EC counterpart.
- **NEUTRAL**: works on both architectures as is.
- **"i386-gated"** means: ARM64 TWIN if 32-bit support is kept (§4), DIES otherwise.
- **msync rows** are NEUTRAL on a dappermint `winecx` `arm64-1117` base and DIES on a citi94 base. I checked both today: `server/msync.c` (27,004 B) exists on `arm64-1117` and on `wine1117`, and is missing (404) on citi94 `macos-arm64-port` (api.github.com, 2026-10-02, V).

| site | assumption | fate | note |
|---|---|---|---|
| Core/Preflight.swift:4,9-10 | `rosettaMissing` + softwareupdate message | DIES | |
| Core/Preflight.swift:20-27 | libRosettaRuntime path, `rosettaAvailable` | DIES | Check that the FEX files are present under `runtimeMissing` instead (I) |
| Core/Preflight.swift:30 | `check()` fails first on missing Rosetta | DIES | Keep it for the Rosetta runtime during the transition |
| Core/Preflight.swift:31-35 | wine/wineserver executable + runtime-version | NEUTRAL | No Mach-O arch check, so an x86_64 runtime passes preflight on a Mac without Rosetta. Add one |
| Core/SteamPlayMode.swift:18 | steam_dev.cfg platform `linux` | NEUTRAL | |
| Core/SteamPlayMode.swift:20-23,33 | `arch -arm64e -arm64 -x86_64` passthrough (Mac-native games only) | NEUTRAL | The `-x86_64` fallback dies with Rosetta |
| Core/SteamPlayMode.swift:44 | `rosettaAvailable` | DIES | |
| Core/SteamPlayMode.swift:93 | `enable` refuses without Rosetta | DIES | |
| Core/SteamLocation.swift:89,98 | `rosettaMissing`, "runtime needs it" | DIES | |
| Core/SteamLocation.swift:23,116 | Steam MacOS dir; `pgrep steam_osx` | NEUTRAL | steam_osx is x86_64+arm64 (V) |
| Core/GPTKImporter.swift:26-37,95-106 (whole file) | D3DMetal + `x86_64-windows/unix` overlay | DIES | D3DMetal is x86_64-only (settled) |
| Core/GPTKDiskImage.swift:1-89 | GPTK .dmg mount | DIES | |
| Core/DXMTInstaller.swift:15-17 | doc: `x86_64-windows`, `i386-windows`, `x86_64-unix` halves | ARM64 TWIN | |
| Core/DXMTInstaller.swift:24-27 | requires `x86_64-unix/winemetal.so` | ARM64 TWIN | → `aarch64-unix` (fork:meson.build:185, V) |
| Core/DXMTInstaller.swift:52 | "over the runtime's DXMT 0.80" | ARM64 TWIN | An arm64 runtime has no DXMT 0.80 (I), so the bundled DXMT becomes mandatory |
| Core/DXMTInstaller.swift:56-57 | `x86_64-windows` → `x64` front ends | ARM64 TWIN | Source is the ARM64X build (`aarch64-windows`, fork:meson.build:174-180). `x64` is a guest name and can stay |
| Core/DXMTInstaller.swift:58 | `i386-windows` → `x32` | ARM64 TWIN | i386-gated. The i386 PE is guest code and is unchanged |
| Core/DXMTInstaller.swift:72-76 | Mac half → `x86_64-unix` | ARM64 TWIN | |
| Core/DXMTInstaller.swift:79-80 | `winemetal.dll` → `x86_64-/i386-windows` | ARM64 TWIN | 64-bit: ARM64X. 32-bit: i386-gated |
| Core/ToolLayout.swift:20-24 | `Libraries/{Wine,DXMT,DXVK}`, `Wine/bin/{wine,wineserver}` | NEUTRAL | Only if the arm64 runtime uses the same shape. A single root blocks two runtimes side by side (§7 SP5) |
| Core/ToolLayout.swift:26 | `Libraries/DXVK` | DIES | DXVK-macOS 1.10.3 is x86_64/i386 on MoltenVK |
| Core/ToolLayout.swift:27-29,65-73 | `gptkStore/Manifest/Version/Imported` | DIES | |
| Core/ToolLayout.swift:35 | `x86_64-unix/lsteamclient.so` | ARM64 TWIN | steamclient.dylib has an arm64 slice (V) |
| Core/ToolLayout.swift:36 | `x86_64-windows/lsteamclient.dll` | ARM64 TWIN | ARM64EC/ARM64X |
| Core/ToolLayout.swift:37 | `i386-windows/lsteamclient.dll` | ARM64 TWIN | i386-gated; optional today (SteamBridge.swift:21) |
| Core/ToolLayout.swift:46-47 | presenter dylib | NEUTRAL | Universal (V) |
| Core/ToolLayout.swift:55-58 | `x64/d3d12.dll`, `x64/dxmt-replay.exe` | NEUTRAL | Guest-name path; the contents are twins |
| Core/RuntimeInstaller.swift:10-15 | `RuntimePin` winecx-gptk runtime-v4.7.3 | ARM64 TWIN | Needs a second pin |
| Core/RuntimeInstaller.swift:58-62 | `proton` = `#!/bin/sh` → macneutron | NEUTRAL | Risk (I): Steam spawns tools preferring x86_64 (SteamPlayMode.swift:21-22), so `/bin/sh` runs translated today. Behaviour without Rosetta is unknown; test on a Mac without Rosetta |
| Core/RuntimeInstaller.swift:73,95-96 | runtime brings DXMT 0.80; drops dxmt-version | ARM64 TWIN | The logic survives; the premise doesn't |
| Core/RuntimeInstaller.swift:91-94 | `badArchive` checks only that wine/wineserver exist | NEUTRAL | Also reject a wine with no arm64 slice |
| Core/RuntimeInstaller.swift:101-103 | re-applies GPTK | DIES | |
| Core/Launcher.swift:52-56 | `preflight.check` | DIES | Only the Rosetta part dies |
| Core/Launcher.swift:58-59 | `select(..., gptkImported:)` | DIES | The parameter goes |
| Core/Launcher.swift:117 | log `gptk=` | DIES | |
| Core/Launcher.swift:65,159-167 | presenter via `DYLD_INSERT_LIBRARIES` | NEUTRAL | Works because today's loader is unsigned (V). A hardened, entitled loader needs `allow-dyld-environment-variables` (I). Alternative: put the overlay in `winemetal.so` |
| Core/Launcher.swift:86,108,114,132 | `wineserver -w/-k`, `winepath` | NEUTRAL | |
| Core/Launcher.swift:138-139 | games start through x64 `steam.exe` | ARM64 TWIN | Build steam.exe for aarch64, otherwise every launch goes through FEX first |
| Core/Launcher.swift:170-184 | steamclient.dylib in Steam's bundle | NEUTRAL | |
| Core/LaunchEnvironment.swift:14-16 | `ROSETTA_ADVERTISE_AVX=1` | DIES | FEX has an AVX equivalent; its name is U |
| Core/LaunchEnvironment.swift:17-19 | `WINEMSYNC=1` | NEUTRAL | msync rule (see fate key) |
| Core/LaunchEnvironment.swift:10,20-22 | DLL overrides, `DXMT_PIPELINE_RECORD` | NEUTRAL | |
| Core/GraphicsBackend.swift:5 | `d3dmetal, dxmt, dxvk` | DIES | Only dxmt remains (plus a D3D9 front end, §3) |
| Core/GraphicsBackend.swift:9-26 | GPTK/DXVK fallbacks | DIES | |
| Core/GraphicsBackend.swift:34,46 | d3dmetal overrides | DIES | |
| Core/GraphicsBackend.swift:35-36 | dxmt keeps `d3d9,d3d10=b` | NEUTRAL | Gap: d3d9 goes to wined3d over GL (§3) |
| Core/GraphicsBackend.swift:38,48 | dxvk overrides/DLLs | DIES | |
| Core/GraphicsBackend.swift:52 | `x64` → system32 | NEUTRAL | Source must be the ARM64X twin |
| Core/GraphicsBackend.swift:53 | `x32` → syswow64 | ARM64 TWIN | i386-gated |
| Core/GraphicsBackend.swift:57-58 | d3d12 is 64-bit only | NEUTRAL | |
| Core/ShaderPrecache.swift:80-82 | `wine x64/dxmt-replay.exe` | ARM64 TWIN | An x64 build would compile pipelines under FEX |
| Core/ShaderPrecache.swift:13,100-107 | stamp = dxmt-version + osversion | NEUTRAL | |
| Core/SteamBridge.swift:7,15 | `Program Files (x86)\Steam\steam.exe` | NEUTRAL | Real Windows path |
| Core/SteamBridge.swift:18-24 | steamclient64.dll / steamclient.dll | ARM64 TWIN | The 32-bit half is i386-gated |
| Core/PrefixManager.swift:35-39,48 | runtime change → `wineboot -u` in place | NEUTRAL | Upgrading an x86_64-built prefix in place under aarch64 Wine is untested (I). Use separate prefixes |
| Core/GameSettings.swift:7,27-28 | `avx` → `MACNEUTRON_NO_AVX` | DIES | Codable ignores unknown keys, so no migration needed |
| Core/GameSettings.swift:8 | `msync` | NEUTRAL | msync rule |
| Core/CommandLineTool.swift:8,21-30 | `import-gptk` | DIES | |
| Core/CommandLineTool.swift:9,31-43 | `install-runtime` | NEUTRAL | Only the pin changes |
| UI/AppModel.swift:29,48,80,110,131,151-155 | `gptkVersion`, `importGPTK` | DIES | |
| UI/AppModel.swift:143 | "461 MB" | ARM64 TWIN | Size string |
| UI/SetupView.swift:18 | "461 MB" | ARM64 TWIN | |
| UI/SetupView.swift:22-31,62-64 | GPTK step, .dmg drop | DIES | |
| UI/GamesView.swift:41,43 | D3DMetal/DXVK picker entries | DIES | |
| UI/GamesView.swift:55 | AVX toggle | DIES | Or relabel it for FEX |
| UI/GamesView.swift:56 | msync toggle | NEUTRAL | msync rule |
| UI/MenuContent.swift:11 | D3DMetal version | DIES | |
| Package.swift:6-16; App/Info.plist:1-16 | host-arch build; no arch keys | NEUTRAL | Output is arm64 (V) |
| Makefile:5-7 | `MINGW` = `x86_64-w64-mingw32-clang` | ARM64 TWIN | The pinned toolchain has arm64ec/aarch64 wrappers (V) |
| Makefile:24 | steam.exe built x64 | ARM64 TWIN | aarch64; registry and job APIs only |
| Makefile:25-26 | steamprobe.exe, helper.exe x64 | NEUTRAL | Keep x64: they test FEX and an aarch64 parent starting an x64 child |
| Makefile:35 | presenter `-arch x86_64 -arch arm64` | NEUTRAL | Drop the x86_64 slice after cutover |
| Makefile:38,50-55 | present_loop.exe, d3d12_*.exe x64 | NEUTRAL | Keep x64 for the FEX path; add arm64ec builds to test DXMT without FEX |
| Makefile:46-47 | `dxmt` → dxmt/build.sh | ARM64 TWIN | |
| Makefile:62-64 + dxmt/check.sh:17 | dxmt-check needs GPTK (D3DMetal is the reference) | DIES | Capture reference images from the Rosetta-stack DXMT while it still exists |
| Makefile:81-84 | bundle copies `x86_64-windows`, `i386-windows`, `x86_64-unix`; codesigns `x86_64-unix/*` | ARM64 TWIN | |
| dxmt/build.sh:15,24 | dxil-probe/translate `-arch x86_64` | ARM64 TWIN | |
| dxmt/build.sh:78-91 | LLVM 15 `CMAKE_OSX_ARCHITECTURES=x86_64` | ARM64 TWIN | Upstream ci.yml:266-284 has the arm64 recipe (est. 30-60 min build) |
| dxmt/build.sh:96-110 | meson runs win64/win32 only | ARM64 TWIN | Add `build-arm64ec.txt` with `-Denable_d3d12=true` |
| dxmt/build.sh:113-129 | staging x86_64/i386 paths | ARM64 TWIN | |
| dxmt/pins:5-7 | 3Shain Wine 8.16 (x86_64) as link tree | ARM64 TWIN | Link against 3Shain wine-11.2 (link-only) or our arm64 Wine |
| dxmt/pins:13-14 | llvm-mingw 20260908 | NEUTRAL | Has the arm64ec/aarch64 sets (V) |
| dxmt/check.sh:25-27; dxmt/tests/run.sh:21-31 | x86_64 runtime paths; `dxmt\|d3dmetal` | ARM64 TWIN | Drop d3dmetal |
| fork:src/d3d12/d3d12_stats.cpp:6,71,160,185,190 | `x86intrin.h` + `__rdtsc`, unguarded (fork d245c13) | ARM64 TWIN | **The only compile blocker** (V). Use QueryPerformanceCounter |
| fork:meson.build:140 | `DXMT_PAGE_SIZE=4096` | ARM64 TWIN | 4K NoCopy works on macOS 27 (V); 16384 is the prudent value on arm64 |
| fork:meson.build:54-61,151-160 | i686 SSE flags, stdcall fixups | NEUTRAL | i386 PE is guest code |
| fork:util_bit.hpp:13-19,31,91,121,220-233,489 | arch detection, SSE/tzcnt, all guarded | NEUTRAL | Selects ARM64 under arm64ec (V) |
| fork:util_hotpatch.h:13 (16 uses) | `hybrid_patchable` on swapchain/factory | NEUTRAL | COM vtable methods are not covered (dxvk#5600) |
| fork:src/winemetal/unix/meson.build:10-11,16-38 | links `<cpu>-unix/{winemac,ntdll}.so` | ARM64 TWIN | |
| fork:winemetal_unix.c:1690-1722,1747-1750 | dlsym `macdrv_functions` or bare macdrv names | ARM64 TWIN | The arm64 `winemac.so` must export one of the two sets, otherwise there is silently no view |
| fork:winemetal_unix.c:2566-2569,2600-2603 | `_mm_pause` / `yield`, guarded | NEUTRAL | |
| fork:winemetal_unix.c:3280,3434 | 64-bit + wow64 call tables | NEUTRAL | The wow64 table is i386-gated. D3D9 slots go at 150 and up |
| fork:airconv_public.h:166 | `sysv_abi` (non-Windows branch) | NEUTRAL | 0 warnings with arm64 (V) |
| bridge/check.sh:8 | `Libraries/Wine/bin/wine` | NEUTRAL | |
| bridge/probe.sh:25-26 | copies `x86_64-windows`/`i386-windows` lsteamclient | ARM64 TWIN | |
| bridge/steam.c:136-154 | suspend + job + wait; loads no game code | NEUTRAL | Source is unchanged; Makefile:24 does the retarget |
| presenter/check.sh:20 | forces `d3dmetal` | DIES | The presenter has never been verified on DXMT (acceptance-upscaler.md:7) |
| Tests/Smoke/smoke.sh:12-13,20-21 | Homebrew `x86_64-w64-mingw32-gcc` (contradicts Makefile:4) | NEUTRAL | The x64 probes stay as guest code; switch to the pinned toolchain |
| Tests/Smoke/smoke.sh:35-36 | d3dmetal/dxvk backends | DIES | |
| rt:Libraries/Wine/lib (700 Mach-O), bin/wine, wineserver | all x86_64 | ARM64 TWIN | The whole runtime is replaced |
| rt:loader `WINE_RESERVE`/`WINE_TOP_DOWN` segments | x86_64-only low-8 GB reservation | DIES | arm64 gets a 4 GB hard pagezero unless entitled (§4) |
| rt:D3DMetal.framework, libd3dshared, libMoltenVK | x86_64 | DIES | |
| rt:`x86_64-windows/d3d10.dll` = GPTK stub (exports only `D3D10CreateDevice`, `D3D10CreateBlob`) | 64-bit D3D10 goes to D3DMetal even on dxmt | DIES | **A bug in today's stack** (I: games importing `D3D10CreateDeviceAndSwapChain` fail). Goes away with GPTK |
| README.md:4,8,17,40,44,55,57,74-75 | D3DMetal, Rosetta requirement, GPTK, AVX | DIES | |
| README.md:39 | 461 MB | ARM64 TWIN | |
| README.md:58 | `MACNEUTRON_NO_MSYNC` | NEUTRAL | msync rule |
| README.md:104-105 | lsteamclient "built by the runtime" | ARM64 TWIN | `arm64-1117` carries `dlls/lsteamclient` (275 entries; citi94: 404) (V, api.github.com 2026-10-02) |
| docs/.../2026-09-27-macproton-runtime-design.md:71 | tool name must not contain `arm64` | NEUTRAL | Constrains how a second compat tool is named |

**Tests to delete or rewrite (V):**
- Whole files:
  - GPTKImporterTests
  - GPTKDiskImageTests
- PreflightTests: `passesWithRosettaAndRuntime`, `reportsMissingRosettaFirst`
- LauncherTests: `missingRosettaNotifiesAndFails`, `everyLaunchIsLoggedWithVersions`, `gameSettingsApplyUnderneathLaunchOptions`, `defaultBackendIsDXMTEvenWithGPTKImported`
- SteamPlayModeTests: `enableRequiresRosetta`, `passthroughPrefersTheAppleSiliconBuild` (skipped forever without Rosetta)
- AppModelTests: `turningOnWithoutRosettaLeavesSteamRunning`
- LaunchEnvironmentTests: 4 tests
- GameSettingsTests: 2 tests
- GraphicsBackendTests: 13 tests
- CommandLineToolTests: `importGPTKRejectsANonGPTKFolder`
- DXMTInstallerTests: 5 tests, plus everything that uses `Support.makeDXMTBuild`
- PrefixManagerTests: 3 tests
- RuntimeInstallerTests: 3 tests plus `makeRuntimeTarball`
- PathsTests: 2 tests
- SteamBridgeTests: `bridgeNeedsSteamExeAndBothHalvesOfTheClient`
- Signature-only breaks (`rosettaAvailable`):
  - PreflightTests:17,23
  - LauncherTests:20,29
  - ShaderPrecacheTests:41
  - SteamPlayModeTests:12,237,249
- Shared helpers in Support.swift:
  - `makeToolLayout` (61-69)
  - `installFakeSteamBridge` (97-103)
  - `makeDXMTBuild` (110-124)

---

## 2. Spike 2026-09-27: what survives and how to resume

**What survives:**
- **Build products: none (V).** The 8.4 GB `scratchpad/arm64` is gone, along with `arm64spike/`, `lowmem/` and the logs. The likely cause is an age-based scratchpad cleanup (I).
- **What survives (V):**
  - The memory file `memory/arm64-wine-spike.md`.
  - Homebrew bison 3.8.2, flex 2.6.4_2, cmake 4.4.3, ninja, molten-vk 1.4.2.
  - The repo's llvm-mingw **20260908** (`build/dxmt-src/llvm-mingw`), which has the arm64ec and aarch64 wrappers.
- **Upstream is unchanged since the spike (Vw, gh api 2026-10-02):**
  - citi94 `macos-arm64-port` = `0cc8848b6075` (2026-07-03)
  - dappermint/FEX `main` = `4efc3abc8aca` (2026-08-26)
- **Session 1cf87734's files** (`layers/up` = 3Shain/dxmt fb45156, and others) also sit in a scratchpad. Expect them to be cleaned up too.

**Resume recipe** (V from the spike transcript). Build in `$WD=/Users/chad/Documents/MacProton/build/arm64` (gitignored, durable), not in a scratchpad.

```sh
T=<toolchain bin>   # try the repo's build/dxmt-src/llvm-mingw/bin (20260908) first (untested, I); fall back to 20260922
git clone --depth 1 -b macos-arm64-port https://github.com/citi94/wine-macos-arm64.git $WD/src/citi94
git clone --depth 1 --recurse-submodules --shallow-submodules https://github.com/dappermint/FEX.git $WD/src/FEX
export PATH="$T:$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LDFLAGS="-L$(brew --prefix molten-vk)/lib" CPPFLAGS="-I$(brew --prefix molten-vk)/include"
mkdir -p $WD/build-wine && cd $WD/build-wine
$WD/src/citi94/configure --enable-archs=arm64ec,aarch64 --disable-tests --without-x --without-wayland --without-oss \
  --without-alsa --without-pulse --without-sane --without-usb --without-v4l2 --without-pcap --without-capi \
  --without-opencl --without-cups CC=/usr/bin/clang      # must be /usr/bin/clang (bare clang -> exit 77); expect PE_ARCHS = arm64ec aarch64
make -j18                                               # ~2.5 min
```

1. **Server patch** (citi94 `server/registry.c`, `init_supported_machines`). Insert it after the `if (getenv("WINEHYBRIDX86"))` block, before `#else`. Then rebuild with `make -C $B -j8 server/wineserver`:
   ```c
   else if (getenv( "WINEARM64EC" )) supported_machines[count++] = IMAGE_FILE_MACHINE_AMD64;
   ```
2. **FEX `-lrt` patch.** In `Source/Windows/UnixLib/CMakeLists.txt`, wrap `target_link_libraries(... rt)` in `if(NOT APPLE)`. Make this a plain edit, not the BSD-`sed` from the spike.
3. **FEX unixlib.**
   ```sh
   cmake -S $F/Source/Windows/UnixLib -B $WD/build-fex-unixlib -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=/usr/bin/clang++
   ninja -C $WD/build-fex-unixlib
   ```
   This produces `libarm64ecfex.so` and `libwow64fex.so`.
4. **FEX ARM64EC.**
   ```sh
   cmake -S $F -B $WD/build-fex-ec -G Ninja -DCMAKE_TOOLCHAIN_FILE=$F/Data/CMake/toolchain_mingw.cmake -DMINGW_TRIPLE=arm64ec-w64-mingw32 \
     -DCMAKE_BUILD_TYPE=Release -DTUNE_CPU=none -DENABLE_LTO=False -DBUILD_TESTING=False -DBUILD_FEXCONFIG=False \
     -DENABLE_JEMALLOC_GLIBC_ALLOC=False -DENABLE_CCACHE=False
   ninja -C $WD/build-fex-ec arm64ecfex
   ```
   `TUNE_CPU=none` is mandatory, because the default tuning reads `/proc/cpuinfo`.
5. **x18 relink.** Repeat this after every `make`, because `make` relinks `loader/wine` (I):
   ```sh
   /usr/bin/clang -std=gnu23 -o loader/wine loader/main.o -Wl,-sectcreate,__TEXT,__info_plist,loader/wine_info.plist \
     -L/opt/homebrew/opt/molten-vk/lib -Wl,-platform_version,macos,12.0,12.0
   codesign -f -s - --entitlements jit.plist loader/wine
   ```
   `jit.plist` sets `allow-jit`, `allow-unsigned-executable-memory` and `disable-library-validation`.
6. **Prefix and FEX install.**
   ```sh
   wineboot -i
   # libarm64ecfex.dll -> system32 and $FX/aarch64-windows; .so -> $FX/aarch64-unix (codesign -s -)
   wine reg add 'HKLM\Software\Microsoft\Wow64\amd64' /ve /d libarm64ecfex.dll /f
   WINEDLLPATH=$FX WINEARM64EC=1 WINEDEBUG=err+all,+seh,+virtual wine hello_x86_64.exe
   ```
7. **Rebuild the test programs.** `hello.c` and `kuser.c` are lost; rebuild them from the spec at jsonl:1773/1785 with `$T/{x86_64,aarch64}-w64-mingw32-clang -O1 -D_WIN32_WINNT=0x0A00`. **Capture kuser's output this time**, because it was never captured.

**Crash diagnostics, in order.** None of these has been started.

1. **Log the raw fault classification first.** citi94 `virtual.c:4665-4672` turns any read fault on a readable page into a write fault under `#ifdef __APPLE__`, so the reported info[0]=1 (write) cannot be trusted (I).
2. **Dump `peb->EcCodeBitMap`** (set at citi94 `virtual.c:2865`) for the x64 image range. This shows whether native code jumped into x64 code.
3. **Check whether FEX's `ResetToConsistentState` runs** when its JIT code faults on macOS.
4. **New lead (I):**
   - The fault was raised on a host stack: addr 0x7ffeabef00d0, outside the Windows stack 0x105b10000-0x105c10000.
   - rip was garbage.
   - Then `RtlIsEcCode` read the bitmap through a garbage pointer.
   - Madeira fixes exactly these sites: `alloc_arm64ec_map` (EC bitmap sizing, `virtual_ios.c:15549`), `8f0243b303` "SEH survival" and `3228ed587b` ExitFunctionEC. Diff those against citi94 before writing anything new.

**Wine base.** The two candidates (V unless marked):

| | citi94 `macos-arm64-port` (Wine 11.10) | dappermint/winecx `arm64-1117` (CX 26.3 on Wine 11.17) |
|---|---|---|
| Runs unentitled | Yes: wineboot and ARM64 PE work (spike) | No. `236d597f89`: the loader "cannot host a windows process yet". `82b2ee5415`: "Without the entitlement the deallocate fails" (Vw) |
| arm64 patch surface | Large: KUSER at 0x17ffe0000, TEB in TSD, W^X flip | **8 commits, 14 files** on top of `wine1117` (`virtual.c` +67, winemac +~120) (Vw, compare API 2026-10-02) |
| lsteamclient / msync | Neither | Both |
| `macdrv_functions` for winemetal | Unknown | Likely: `713015fa9f` "build the d3dmetal hooks on arm64 as well" (I) |
| Role | Debug base for the FEX crash | Ship base, if the entitlement is granted |

---

## 3. Direct3D 9 and 10 in a native arm64 process (ranked)

| # | Option | 64-bit | 32-bit (WoW64) | Status |
|---|---|---|---|---|
| 1 | **Import dacevedo12/dxmt `v0.4-d3d9`** into the fork (LGPL-2.1+) | ARM64X through the existing `build-arm64ec.txt` (`-marm64x`) | Ships `thunk32_DXSO*` wow64 thunks, so the i386 PE side exists. The DXSO compile runs on the unix side, which is native even for 32-bit games (I, from the slot names). Gated by §4 | Vw: fe69cd39, +55,976 lines. "No game has been played on it end to end." Work: renumber its unix-call slots to 150 and up (they collide at 145-149) and rebase across 86 upstream commits (15 files overlap with our fork) |
| 2 | **wined3d** (comes with any arm64 Wine) over OpenGL through winemac | Works at no cost on day 1 (I) | All i386 PE code, wined3d included, runs emulated: Wine has no CHPE-x86 (Vs, `loader.c:2500-2512`) | The baseline and fallback. wined3d-vk at FL 9_3 needs only SM3 + `independentBlend` (Vs), but Wine 11 says the Vulkan renderer is "not yet at parity" (Vs). OpenGL is deprecated on macOS; its removal is not announced (I) |
| 3 | DXVK d3d9 (ARM64EC, as Proton builds it) on MoltenVK/KosmicKrisp | Blocked: DXVK master requires `geometryShader` (`dxvk_device_info.cpp:854`), and KosmicKrisp has none until Mesa MR !44786 lands (open, updated 2026-10-01) (Vs) | Same | Rejected in the fork spec (`2026-09-28-macneutron-dxmt-fork-design.md:26`) |
| 4 | D3D9On12 | No: it is a DDI driver, MSVC/WDK only (Vs) | No | Kill |
| — | D3DMetal | No D3D9, x86_64-only (Vs) | — | Dead |
| — | willfaust/dxmt shim (PR #2) | GPL-3. "Has never run on a device" | Self-reported on iPad | Reference only |

**D3D10:**
- It is handled by DXMT `d3d10core` plus Wine's builtin `d3d10`/`d3d10_1` (V: GraphicsBackend.swift:35-36; fork `src/d3d10/meson.build` builds only `d3d10core`).
- The arm64 stack also fixes today's bug where the GPTK `d3d10.dll` stub replaces Wine's (§1).
- **Do item 1 on the Rosetta stack first.** It needs no arm64 work and replaces wined3d/GL there too.

## 4. 32-bit games: plan and order

1. **Ship the arm64 stack as x64-only.** 32-bit games stay on the Rosetta runtime through macOS 27. Whether Rosetta's post-27 carve-out for "older, unmaintained games" covers them is unknown (settled).
2. **Get the entitlement answer (SP0).** The facts so far:
   - Since xnu-12377.101.15 (2026-04-17), `cross-architecture-support` relaxes the 4 GB hard pagezero to a soft one and allows 4K-page spawns (`mach_loader.c:1081-1086,2604-2636`, Vs).
   - The kernels on this Mac (macOS 27.0.1) contain the entitlement strings (V).
   - Ad-hoc signing with the entitlement is killed (rc 137), and 4K spawn fails with errno 88 (V).
   - Whether Apple grants it to third parties is U.
3. **If entitled:**
   - Use the standard new-WoW64 layout: add i386 to `--enable-archs`, and run upstream FEX `libwow64fex.dll` (+`.so`, already built by the spike's unixlib target) as the i386 emulator. This is the Proton 11 ARM64 default (Vs, `dlls/wow64/syscall.c:763`).
   - Re-enable the i386-gated rows in §1.
   - Madeira's code is not needed.
   - This probably also explains the CrossOver arm64 Preview's 26.5 floor (I).
4. **If refused:**
   - Re-implement Madeira's guest-base window: `[B, B+4 GB)`, FEX 32-bit `B + zext32(EA)`, and wow64 thunks that add or remove `B` (`docs/WOW64.md:25-50`, Vs).
   - winemetal's i386 pointer paths (`winemetal.h:128,162` `high_part`; NoCopy buffers on guest memory at `winemetal_unix.c:156-170`) then need `B` translation (I).
   - Madeira is GPL-3.0 with an exception. That code lands in our Wine and FEX forks, not in the LGPL DXMT fork; the combined runtime becomes GPL-3 (I).
     Superseded (2026-10-03): Madeira's FEX commits used here are MIT under its pre-2026-08-28 grant; see the spec.
   - Its PR #26 closed unmerged, and its device results are self-reported (Vs).
   - Effort is months (estimate).
5. **Order within 32-bit:** D3D9 first (the biggest share of 32-bit titles, I), then D3D11 i386 DXMT (already built today), then lsteamclient32. 32-bit D3D12 stays unimplemented (`d3d12_descriptor_heap.cpp:132,533`).
6. **x87-heavy titles** behave differently under FEX (dacevedo release notes, Vs). Budget a compatibility list for them.

## 5. State of the art since 2026-09-27

| Item | Date | Fact | Use for the crash |
|---|---|---|---|
| citi94, dappermint/FEX | 07-03 / 08-26 | Unchanged (Vw) | — |
| dappermint arm64 runtime recipe | committed 09-23 | Wine `arm64-1117` + **prebuilt** FEX copied from `whisky-arm64-5.1.1` + DXMT `arm64-1117`. Runs only on "CrossOver's entitled `wine.app`" (Vs) | Shows that entitled x64-under-FEX works. Does not prove the crash is the low 4 GB |
| winecx `arm64-1117` | 09-23 | 8 commits over `wine1117`, including a W^X flip (`eb6cb20f00`, CW hacks 24945/25719, "FEX spun on one address") (Vw) | Compare its W^X flip with citi94's |
| Madeira v0.1.0 / v0.1.1; willfaust FEX/wine/dxmt PRs | 09-28 to 10-02 | The only unentitled x64-under-FEX on XNU. FEX ARM64EC is +1273/−36 in `Module.cpp`, +322 in `Module.S`, +199 in `CallRetStack.h`. Wine side: EC bitmap sizing, KUSER fault emulation, image placement. iOS-specific parts: debugger-attached JIT, one dual-mapped pool, sigreturn zeroing x18 (Vs) | **Best lead**: port selectively (§2, lead 4) |
| FEX-2609 | 09-07/08 | Experimental on-disk JIT cache `FEX_DISKCACHE=1`. Whether it covers ARM64EC is I (Vs) | — |
| FEX-Emu upstream | — | "No plans for MacOS support" (#5046, 2025-11-13). `CONTRIBUTING.md:1` bans AI/LLM contributions. Upstream `c55fb3b5b8` (09-18) needs a macOS PID call before rebasing dappermint's commit (Vs) | We carry a FEX fork |
| Wine 11.18 / 11.19 | 09-18 / 10-02 | Bug 60331 fixed in 11.18 (native ARM64EC crash). jacek's ARM64EC MRs !11697 and !11860 merged (Vs) | Rebasing to ≥11.18 may help; relevance is I |
| Wine MR !11638 (trcrsired) | stalled since 08-14 | macOS arm64 PIE, KUSER at TPIDRRO_EL0−0x1000, builds for macOS 12 to keep x18. Status "conflict" (Vs) | Same old-SDK x18 trick as the spike |
| CodeWeavers | — | Sources only for 26.3.0. 26.4 and 27 return 404 (Vs) | Nothing to port |
| dxvk#5600 | 2026-04-24 (open) | SpecialK can't hook ARM64EC COM methods until they are `hybrid_patchable` (Vs) | Applies to DXMT's COM methods |

**Shortcut ranking:**
1. **Entitled A/B (user):** run our build behind CrossOver Preview's `wine.app`. This isolates whether the crash comes from the low 4 GB.
2. **Port Madeira's Wine fixes** and diff its FEX ARM64EC changes.
3. **Rebase onto Wine ≥11.18.**
4. **Use dappermint's ntdll commits**, but only on an entitled loader.

## 6. "One pass"

**Short answer: ARM64EC layering is already one pass**, in the sense of one process with one translation per piece of code. There is no fused translator to wait for.

How the three translations map to the stack:

| User's translation | Done by | When |
|---|---|---|
| x86 → arm64 | FEX ARM64EC JIT | Once per block, cached (on disk with FEX-2609) |
| Windows → macOS | Wine built ARM64EC/aarch64 | Ahead of time, native |
| DirectX → Metal | DXMT ARM64X + `winemetal.so` | Native; shaders compiled once and pre-cached by `dxmt-replay` |

What remains between the layers:
- Each call from x64 code into ARM64EC code costs about 100–200 cycles **per round trip**. That figure is Microsoft xtajit64 on Snapdragon (Vs, emulators.com 2024). FEX's cost is unmeasured in both directions.
- The PE-to-unix call into `winemetal` exists in every design (Vs), so it does not count against layering.

**What fusing would buy.** It would remove only that round trip:
- Upper bound: 15k draws × 3–8 crossings × 150 cycles ÷ 4 GHz ≈ 1.7–4.5 ms per frame. At one crossing per draw it is 0.56 ms.
- The inputs are a 2015 draw count and a 2024 xtajit64 figure.
- Zero gain on SMITE 2, which is GPU-bound (settled).
- TSO cost is unchanged either way.

**What fusing would cost:**
- A static or hybrid translator that understands Win32 and COM. Theseus shows that static discovery needs manual help with vtables and jump tables.
- It still needs a JIT for game JITs, DRM and self-modifying code.
- Person-years of work, and nobody ships one for PC games. Valve chose layering for Proton 11 ARM64 (Vs).
- Losing hook points is not unique to fusion: layered ARM64EC already lacks x64-shaped COM entry points (dxvk#5600).

**Action:** measure FEX crossings in both directions in SP6. Revisit only if a CPU-bound title shows the boundary dominating.

## 7. Sub-projects (ordered; efforts are estimates)

Throughout: **the Rosetta runtime keeps shipping, unchanged and default, until SP9.**

| SP | What | Depends on | Reused | New | Go / kill gate | Effort |
|---|---|---|---|---|---|---|
| **SP0** | Decision inputs (user): apply for the entitlement; install CrossOver arm64 Preview to run `codesign -d --entitlements -` on its `wine.app`, test whether it runs i386, and A/B our Wine behind it; inventory 32-bit and D3D9 titles | — | — | — | Output is a yes/no/date on the entitlement. Every branch below keys on it | User days; Apple's response time unknown |
| **SP1** | Resume the FEX spike in `build/arm64/` (§2) | — | Recipe, citi94, dappermint/FEX, x18 relink, server patch | Durable build script, diagnostics, Madeira-derived fixes | **Go:** x64 hello + kuser + SEH test run under FEX unentitled. **Kill/pivot:** time box exhausted, or the A/B shows it works entitled only → stop unentitled work and wait for SP0 | est. 2 wk time box |
| **SP2** | DXMT ARM64X + aarch64 `winemetal.so` (parallel to SP1: needs only native ARM64 PE, which already works) | Wine link tree | Fork code, upstream `build-arm64ec.txt`, ci.yml LLVM recipe | `d3d12_stats.cpp` fix, arm64 LLVM 15, build.sh arm64ec run with D3D12 on, 16K page size, winemac exports | **Go:** `present_loop` and `d3d12_*` tests **built arm64ec** render on native arm64 Wine without FEX. **Kill:** none expected; the main risk is winemac exports (fix in Wine) | est. 1–2 wk |
| **SP3** | Ship-base Wine | SP0, SP1 | `arm64-1117` (lsteamclient, msync, `macdrv_functions`) or citi94 | Entitled: none. Unentitled: port citi94's KUSER/TEB/W^X onto `arm64-1117`, or port lsteamclient (4 winecx commits from 2026-08-25), msync and the macdrv hooks onto citi94 | **Go:** wineboot + x64 `present_loop` under FEX → ARM64EC DXMT → Metal on the chosen base | est. 1 wk entitled / 3–5 wk unentitled |
| **SP4** | Steam path | SP3 | steam.c, probe.c, bridge/check.sh | aarch64 `steam.exe`; ARM64X lsteamclient + aarch64 `.so` from the base | **Go:** `bridge/check.sh` passes; x64 `steamprobe` gets SteamAPI_Init against Mac Steam | est. 1 wk |
| **SP5** | Launcher/runtime twin (Swift) | SP3 | Whole launcher | Second pin and root; per-game runtime choice; per-runtime prefixes; Preflight split; FEX env knobs; presenter injection (DYLD vs inside winemetal); test rewrite (§1). Second compat-tool name without `arm64` (runtime-design.md:71) | **Go:** Cats (x64 D3D11) launched from the Steam UI on arm64; all tests green; the Rosetta path is byte-identical in behaviour | est. 2 wk |
| **SP6** | D3D12 / SMITE 2 parity + measurement | SP4, SP5 | DXIL translator, replay | ARM64X `dxmt-replay`; `hybrid_patchable` on COM methods; `FEX_DISKCACHE`; crossing-cost probe; check.sh reference = Rosetta DXMT reference images | **Go:** SMITE 2 frame time ≈ the Rosetta stack (GPU-bound); one CPU-bound title measured; Steam overlay works. **Kill:** none; this produces the parity data | est. 2–4 wk |
| **SP7** | D3D9 front end import (can start **now**, on Rosetta) | — | dacevedo v0.4-d3d9 | Rebase, slots 150+, d3d9 override in GraphicsBackend, x86_64/i386/arm64ec builds | **Go:** D3D9 tests + one 64-bit D3D9 game end to end on Rosetta, then on arm64. **Kill:** conformance worse than wined3d → keep wined3d as default and DXMT D3D9 opt-in | est. 3–6 wk |
| **SP8** | 32-bit (§4) | SP0, SP3, SP7 | i386 DXMT build, wow64 call table | Entitled: i386 arch + `libwow64fex`. Unentitled: guest-base window | **Go:** one 32-bit D3D9 and one 32-bit D3D11 game end to end. **Kill:** neither branch converges by mid-2027 → 32-bit relies on Rosetta's carve-out or is unsupported on macOS 28 | est. 2–4 wk entitled / months unentitled |
| **SP9** | Cutover | SP6 (+SP8 for 32-bit) | — | Default runtime flips per game when a game passes the parity set; delete the DIES rows (GPTK, DXVK, AVX, Rosetta preflight) | Parity matrix agreed in §8 | est. 1 wk + soak |

**Dependency graph:**
```
SP0 ─┬─────────────► SP3 ─► SP4 ─► SP5 ─► SP6 ─► SP9
SP1 ─┘                ▲                    ▲
SP2 ──────────────────┘                    │
SP7 ───────────────────────────────────────┤
SP0 + SP3 + SP7 ─► SP8 ────────────────────┘
```

## 8. Open questions only you can answer
1. Will you apply to Apple for `com.apple.developer.cross-architecture-support`? That needs a paid Developer team, and probably a hardened, notarized loader (I). Are you willing to ship that way?
2. May the plan rely on your installing CrossOver's arm64 Preview, to inspect its entitlements, test i386, and A/B our Wine behind its `wine.app` (test-only use)?
3. Which Wine base should we prefer: CrossOver patches (`arm64-1117`: lsteamclient, msync) or citi94's unentitled port? This matters only if the entitlement is refused.
4. Is GPL-3 code (Madeira-derived FEX and Wine changes) acceptable in the shipped runtime? The DXMT fork stays LGPL-2.1+.
5. How many target games are 32-bit, and how many D3D9? Is "32-bit stays on Rosetta until macOS 28" acceptable?
6. Which games make up the parity set for cutover, and what threshold counts as parity?
7. Is a second Steam compat tool entry (two runtimes side by side) acceptable, or should one tool choose a runtime per game?
8. What minimum macOS should the arm64 stack require: 26.5 (CrossOver's floor) or 27?
9. Does D3D9 → Metal have to be done at cutover, or is wined3d over OpenGL an acceptable interim?
10. Should D3DMetal stay in the Rosetta stack until macOS 28, or be dropped earlier?
11. Do you accept carrying long-lived FEX and Wine forks? FEX bans AI contributions, and memory says no AI PRs to DXMT upstream.
12. D3D8 (fork roadmap item 7): is it in scope for the "9–12" goal, or does it stay on wined3d?

Nothing in the repo, the fork or upstream was changed. Today I added only read-only `gh api` reads of dappermint/winecx (compare `wine1117...arm64-1117`; `dlls/lsteamclient` and `server/msync.c` on both branches) and citi94 (both paths 404).