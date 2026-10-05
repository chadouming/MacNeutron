# MacNeutron — Native arm64 stack: roadmap and sub-project 1 (arm64 Wine + FEX for x64)

- **Date:** 2026-10-02
- **Status:** Approved 2026-10-03. Sub-project 1 implemented 2026-10-03: G1, G2, G3 and G5 pass and G4 is measured (`docs/testing/acceptance-arm64-wine.md`). Sub-projects 2 and 3 are done too (§2). Amended by `2026-10-04-macneutron-arm64-release-design.md` §13 on 2026-10-04: the first release is arm64-only.
- **Builds on:**
  - `2026-09-27-macproton-runtime-design.md` (tool folder, launcher, prefixes)
  - `2026-09-28-macneutron-dxmt-fork-design.md` (our DXMT fork, `dxmt/` build layout)
- **Evidence:** `docs/research/2026-10-02-native-arm64/`:
  - the stack map;
  - the Wine 11.19 survey;
  - the entitled trial, with its patches and a second agent's verification;
  - the x18 boundary design;
  - this spec's review;
  - the probe sources.
- **Scope:**
  - **In:**
    - the roadmap from today's stack (x86_64 Wine + DXMT under Rosetta) to one native arm64 process;
    - the full design of sub-project 1: upstream Wine 11.19 built as an entitled, 4K-page, Developer ID-signed `wine.app`, with FEX running x64 Windows code inside it;
    - sub-project 1's gates.
  - **Out:**
    - sub-projects 2–9 (§2), each with its own spec;
    - shipping any of this to players: the Rosetta runtime stays the only shipped runtime until sub-project 5 (superseded 2026-10-04: sub-project 5 ships arm64 only, and removes the Rosetta runtime);
    - upstream contributions of any kind, other than issue reports.

## 1. Goal

MacNeutron must keep running Windows games after Rosetta: Apple keeps general Rosetta only through macOS 27, and D3DMetal is x86_64-only. The target is one native arm64 process per game:
- FEX translates only the game's x86-64 code;
- Wine, built ARM64EC/ARM64X, runs as native arm64 code;
- our DXMT, built ARM64X, sends Direct3D 10/11/12 straight to Metal.

Each x86 instruction is translated once, and Windows and Direct3D calls land in native code. This is the "one pass" the stack can have; a fused translator would remove only the x64↔ARM64EC call crossings (§3.6).

This is a survival move, not a speed one. GPU-bound games such as SMITE 2 will not get a shorter frame from it.

**Sub-project 1 is done when** §8's gates G1, G2, G3 and G5 pass on the maintainer's Mac, G4 is measured, and the result is recorded in `docs/testing/acceptance-arm64-wine.md`:
- `make wine-arm64` builds, signs and stages the runtime from committed pins and patches;
- x64 Windows programs run correctly under FEX in it;
- FEX's CPU cost against Rosetta is known. A game's switch is decided per game from that game's own measurements (sub-project 9), not by G4. (Superseded 2026-10-04: there is no per-game switch; the first release is arm64-only, `2026-10-04-macneutron-arm64-release-design.md` §13.)

### Decisions made during brainstorming

| Decision | Choice |
|---|---|
| Shape | One process, layered: FEX ARM64EC + Wine ARM64EC + DXMT ARM64X. Rejected: a fused x86 + Win32 + D3D translator (no precedent, person-years) |
| Priority | The main workstream, as fast as possible. DXMT GPU-efficiency work pauses |
| When a game switches | ~~Per game. A 64-bit D3D11/12 game moves once it runs on the arm64 stack at ≤ ~1.4× the CPU cost it has under Rosetta. 32-bit and D3D9 games stay on Rosetta until their own sub-projects land~~ Superseded 2026-10-04 by the maintainer: the first release is arm64-only; 32-bit and D3D9 games stop working with it and come back with rows 7 and 8 (`2026-10-04-macneutron-arm64-release-design.md` §13) |
| Apple entitlement | **Granted** on 2026-10-02: the "Cross-architecture Compatibility Framework" capability (`com.apple.developer.cross-architecture-support`) for App ID `net.authspot.macneutron.wine`, team `49QMZXLR8S`, through a Developer ID provisioning profile. The entitled path is the design; the unentitled design survives only in the research (`wine-11.19-survey.md`) |
| Wine base | Upstream `wine-11.19`, not citi94's port, CrossOver's tree or Madeira's |
| x18 (Windows TEB) | Apple's public `os_set_custom_x18_abi_enabled`. Once per thread for sub-project 1; strict toggling at every Windows↔Unix transition before shipping (sub-project 3). No old-SDK linking |
| GPL-3 | Allowed in our FEX fork, so Madeira's GPL-3 FEX changes may be imported with attribution. Wine and DXMT stay LGPL. (Amended 2026-10-03: every Madeira commit we use is dated before 2026-08-28, and Madeira's `LICENSE-MADEIRA.md` says such modifications were granted under MIT irrevocably, so our FEX patches stay MIT, with attribution.) |
| FEX JIT memory | FEX emits into code mapped twice (a writable view and an executable view), never into RWX pages (§3.4, §6.2) |
| Patches | Patch files committed in this repo are the source of truth, applied to pinned upstream commits. No public Wine or FEX fork until the maintainer decides otherwise |
| Minimum macOS for the arm64 stack | 27, the maintainer's choice. The APIs would allow 26.6 (`os_cross_arch_is_supported` appeared in 26.6; the x18 call in 26.4), but 27 is what we test. Binaries are built with a 27.0 deployment target |
| CrossOver Preview | Not used: it needs a paid CrossOver licence |

## 2. Roadmap

| # | Sub-project | Depends on | Notes |
|---|---|---|---|
| 1 | **arm64 Wine + FEX for x64:** this spec | — | Durable build, signing, FEX bring-up, gates<br>**Done** 2026-10-03: `docs/testing/acceptance-arm64-wine.md` |
| 2 | **DXMT for arm64:** ARM64X PE side, aarch64 `winemetal.so`, arm64 LLVM 15 | Wine build tree from 1 | Runs alongside 1. Testable with ARM64EC-built test programs, no FEX needed. Blockers (fixed by DXMT patch 0001 and Wine patch 0013):<br>• `__rdtsc` in `src/d3d12/d3d12_stats.cpp`, the only compile error;<br>• Wine 11.19's `winemac.so` has no `macdrv_functions` and exports only two symbols, so both of DXMT's lookups (`winemetal_unix.c:1713-1722`) fail and nothing presents. Fix: a `macdrv_functions` shim table with default visibility in a winemac patch<br>**Done** 2026-10-03: `2026-10-03-macneutron-arm64-dxmt-design.md`, `docs/testing/acceptance-arm64-dxmt.md` |
| 3 | **Ship-base Wine** | 1 | Strict x18 toggling (§5.3); msync from CrossOver `wine1117`; FreeType and gnutls built from pinned source and bundled; the Steam bridge (lsteamclient ARM64X against Steam's universal `steamclient.dylib`, an aarch64 `steam.exe`); licence and notice files for every shipped component. Spec: `2026-10-04-macneutron-ship-base-wine-design.md` (amended 2026-10-04: row 4 folded in; `MAP_JIT` dropped, see §3.4)<br>**Done** 2026-10-04: `docs/testing/acceptance-arm64-ship-base.md` (Wine 0004 and 0015-0019, lsteamclient 0001-0003) |
| 4 | **Steam path** | — | Folded into row 3 (2026-10-04). The launcher's arm64 Steam wiring and the decision whether release bundles may include lsteamclient (it is under Valve's Steamworks SDK licence) moved to row 5 |
| 5 | **Launcher: the arm64-only release** | 3 | Scope and decisions: `2026-10-04-macneutron-arm64-release-design.md` (it replaces the per-game runtime choice and the preflight split below: every game runs on `wine.app`, and the Rosetta runtime, GPTK, DXVK, the AVX switch and the Rosetta preflight are deleted). Originally: per-game runtime choice, separate prefixes, preflight split; installing `wine.app` (at a path with spaces, as `wine-arm64/check.sh` tests); `WINEMSYNC=1` for every arm64 run (`WINEMSYNC=0` per game as the off switch; client and server must agree, §11); the arm64 Steam bridge wiring (copying `lsteamclient.dll`, and `build/bridge/arm64/`'s `steam.exe` and `tests/helper.exe`, into prefixes); installing DXMT into arm64 prefixes (`DXMT/aarch64-windows/*` into system32, with the DXMT overrides; sub-project 2 spec §6); whether releases may include lsteamclient (Steamworks SDK licence; not redistributed until decided); release packaging: notarization of the entitled bundle (unverified, §11), release source archives, refusing development inputs in release bundles, stripping builtin PE files (`lsteamclient.dll` is 57 MB); the presenter loaded without `DYLD_INSERT_LIBRARIES` (the hardened runtime ignores `DYLD_*`); shader pre-caching from the launcher in arm64 mode; `dxmt/check.sh`'s launcher checks (section 10, `MACNEUTRON_LOG`) in arm64 mode. Deferred from sub-projects 2 and 3: the sub-project 2 spec's scope and §6, the sub-project 3 spec's scope and §13, `docs/testing/acceptance-arm64-ship-base.md` "Found on the way". Parked here, with no owner in the sub-project 3 spec ("a separate small change"): the Rosetta app's missing LLVM and mingw-w64 notices |
| 6 | **SMITE 2 parity and measurements** | 2, 3, 5 | Planned, but gates nothing (arm64-only release, `2026-10-04-macneutron-arm64-release-design.md` §13). Frame time vs the Rosetta stack (now the frozen reference); the cost of x64↔ARM64EC crossings; per-game CPU cost; a CPU-bound title; classify the x18 hits in Steam's arm64 `steamclient.dylib` (552, counted, not classified, in sub-project 3) |
| 7 | **Restore Direct3D 9** (the arm64-only release drops it; optional) | — | Import dacevedo12/dxmt `v0.4-d3d9` (LGPL) into our fork; Wine's wined3d stays the fallback |
| 8 | **Restore 32-bit support** (the arm64-only release drops 32-bit games) | 3, 7 | Standard WoW64: i386 in `--enable-archs` and FEX's `libwow64fex.dll`. The entitlement makes the low 4 GB usable, so Madeira's guest-window redesign isn't needed. FEX's WoW64 JIT still allocates RWX, so its dual-view port belongs here |
| 9 | **Per-game cutover** (folded into row 5, `2026-10-04-macneutron-arm64-release-design.md` §13) | 6 (+7 for D3D9, +8 for 32-bit) | A game moves when its own measurements clear the bar in §1's decisions; the deletion of GPTK, DXVK, the AVX switch and the Rosetta preflight moved to row 5 |
| 10 | **Media** (added 2026-10-04) | 3 | FFmpeg for `winedmo` and/or GStreamer for `winegstreamer`: today `winedmo` builds as a stub and `winegstreamer` isn't built, so game intro movies and cutscenes don't play |

## 3. Evidence (verified 2026-10-02 on an M5 Pro, macOS 27.0.1, unless marked)

### 3.1 The entitlement

A probe (`probes/entitlement-probe.c`: bundle + embedded profile, Developer ID, hardened runtime) compared with the same probe ad-hoc signed:

| | Without | With the entitlement |
|---|---|---|
| Memory below 4 GB (0x10000, 0x7ffe0000, 0xfff00000) | ENOMEM | Mappable. The 4 GB hard page zero becomes a one-page hard zero plus a soft reservation (prot 0/0) that `MAP_FIXED` overrides |
| A child spawned with `posix_spawnattr_set_4k_page_size_np` (SDK `spawn.h`, macOS 26+) | `posix_spawn` returns 88. With `POSIX_SPAWN_SETEXEC` the process is SIGKILLed (137), or the child dies silently | Runs with `getpagesize() == 4096`. The spawned binary itself must carry the entitlement |
| x18 after `os_set_custom_x18_abi_enabled(true)` (SDK `os/arch/arm64.h`) | Lost 200/200 | Kept 200/200, across context switches, page faults and signal return |
| Plain RWX `mmap`/`mprotect` | EACCES | EACCES (`MAP_JIT` works in both) |
| Hardware TSO (message-passing litmus, plain loads and stores, spin-read shape) | ~41% forbidden outcomes | ~38%: none |
| Linking with `-pagezero_size 0x1000` or `-segalign 0x1000` | SIGKILL | SIGKILL: keep the default 4 GB `__PAGEZERO` and let the entitlement soften it |

Also verified:
- `os_cross_arch_is_supported(OS_CROSS_ARCH_X86_64)` returns 1 with and without the entitlement. It reports a system capability that is "constant for the lifetime of the system", not whether this process is entitled.
- In XNU, the entitlement makes a task eligible for the x18 toggle (`osfmk/arm64/machine_task.c:333-337`). The x18 mode is bit 48 of TPIDR_EL0, per thread, and starts off in new threads. Apps built for SDKs before 13.0 get x18 preserved always, as a "temporary override" (`:347-354`).
- The public XNU source stubs `ml_satisfies_x86_64_requirements` (returns false); the shipping kernel contains the real check and both entitlement names.
- Reading CTR_EL0 with `mrs` from user mode kills the process (SIGILL). DCZID_EL0 and FPCR are readable.

### 3.2 Upstream Wine 11.19 on macOS arm64

- Builds as ARM64X (`--enable-archs=arm64ec,aarch64`) in about 2.5 minutes, with no errors.
- **Already upstream:**
  - the Unix-side TEB through pthread TSD;
  - Apple signal contexts and fault classification;
  - a runtime host page size;
  - the ARM64EC code bitmap and the bug 60331 fix (11.18);
  - AMD64 advertised as a supported machine on aarch64 (the 2026-09-27 spike's server patch only undid citi94's own change);
  - every host `PROT_EXEC` going through `mprotect_exec` (`dlls/ntdll/unix/virtual.c:1968`).
- **Missing:**
  - loader link flags that run on arm64;
  - x18 handling;
  - W^X handling;
  - CPU ID registers for FEX on macOS (`dlls/ntdll/unix/system.c:2106-2112` is a stub);
  - bounds checks before the PE side reads the ARM64EC code bitmap;
  - ARM64EC marking of mapped section views (§3.4).

### 3.3 The entitled trial

Throwaway, in `build/arm64/entitled/`; patches preserved in `docs/research/…/trial-patches/`; checked by a second agent that re-ran it:
- `wine-11.19` plus six patches runs as `wine.app`, signed with the Developer ID and the hardened runtime on.
- `wineboot -i` and `wineboot -u` return 0.
- All 18 Wine processes run with 4K pages; `wineserver` is ad-hoc linker-signed and keeps 16K.
- KUSER_SHARED_DATA sits at the real 0x7ffe0000.
- A native ARM64 PE hello works.
- x18 matched the TEB in 1.19e11 checks across 72 threads (`CreateThread`, thread-pool workers and the main thread).

| # | Change | What failed without it |
|---|---|---|
| 1 | `configure.ac`: an aarch64-darwin loader case without `-segalign`/`-pagezero_size` | The kernel kills the loader (rc 137), even entitled |
| 2 | `virtual_init` registers the entitled soft page-zero reservation with `mmap_add_reserved_area` (instead of CrossOver's `free_pagezero`, which would let malloc and frameworks into the low 4 GB) | `failed to map the shared user data: c0000018` |
| 3 | The loader exec uses `posix_spawn(POSIX_SPAWN_SETEXEC)` with `posix_spawnattr_set_4k_page_size_np` | Processes stay 16K. A 16K run failed with `failed to set 60000020 protection on ... .text`, but that run predates patch 6, so whether 16K plus patch 6 boots is untested. 4K is the design because it makes protections page-exact |
| 4 | `os_set_custom_x18_abi_enabled(true)` at the top of `init_syscall_frame` (every thread that runs PE code passes there) | PE code loses its TEB: `stack overflow 1088 bytes` |
| 5 | `exec_wineloader` keeps two environment strings in static buffers | `execve` returns EFAULT for any environment string within ARG_MAX (1 MB) of the 0x7ffffe000000 ceiling; `services.exe` fails with error 731. Independent of the entitlement |
| 6 | citi94-tree `4a50ce17c8`: `mprotect_exec` downgrades RWX to RW, and the fault handler flips the page RX↔RW | `HeapCreate(HEAP_CREATE_ENABLE_EXECUTE)` fails with 0xc0000022, then a NULL-heap crash in `winedevice.exe` |

**Lessons the design carries:**
- A 4K `SETEXEC` exec of an unentitled binary is SIGKILLed with no message, so the exec target's signature matters (§4, patch 7).
- Wine rewrites a client's argv, so `pkill -f <path>` misses it. Only `wineserver -k` or killing by executable path (`lsof -t`) cleans up; the trial left 32 orphans.
- In an installed layout, `wineloader` is `<real directory of ntdll.so>/wine` (`dlls/ntdll/unix/loader.c:386-400`), and `make install` puts its own unentitled copy of the loader there.
- `vmmap` prints "VM page size: 16384" even for 4K processes, and `GetSystemInfo` always says 4096. Wine's own `virtual_init` trace ("host page size: 4k") is the check.

### 3.4 Memory for FEX's JIT

Measured inside the entitled Wine, from a plain ARM64 PE (`probes/dualmap.c`):

| Scheme | Cost of one write-then-execute cycle |
|---|---|
| One `VirtualAlloc(PAGE_EXECUTE_READWRITE)` page, through patch 6's fault flip | 8.46 µs (two faults plus two `mprotect`) |
| One section (`CreateFileMapping(PAGE_EXECUTE_READWRITE)`) mapped twice: an RW view for writing, an RX view for executing | 0.10 µs, mostly `FlushInstructionCache` |

The dual view works with no Wine change for plain ARM64 code. FEX's generated code must also be marked ARM64EC code, and Wine doesn't do that for views:
- FEX allocates every executable buffer with `MEM_EXTENDED_PARAMETER_EC_CODE` (`FEXCore/include/FEXCore/Utils/AllocatorHooks.h:49-61`).
- Wine marks EC code only in `allocate_virtual_memory` (`virtual.c:5260-5263`). `NtMapViewOfSectionEx` parses the attributes and drops them (`:6433-6520`).
- Without the mark, Wine's `RtlIsEcCode` checks (unwinding, exception dispatch, `arm64x_check_call`) would treat JIT code as x64.
- So §5.2 adds patch 11.

Also measured natively (`probes/jit-memory-probe.c`):
- `mach_vm_remap` gives an RW buffer an RX alias in an entitled hardened-runtime process.
- A `MAP_JIT` region can't be remapped.
- A `pthread_jit_write_protect_np` on/off pair costs 23 ns, for a JIT that switches modes itself. Windows RWX memory can't use `MAP_JIT` (amended 2026-10-04): `MAP_JIT|MAP_FIXED` fails, a MAP_JIT range made RWX refuses every later `mprotect`, and a switch to execute inside a fault handler is undone on return; see the sub-project 3 spec §2.

### 3.5 FEX's speed

- **neo773's gist** ([fex-vs-rosetta-std64](https://gist.github.com/neo773/f1f02698ad65f0b9b3218f4a73f67fc4)) measured CrossOver Preview on an M1 Max, macOS 27 beta, with 29 single-threaded x64 microbenchmarks. Its ratios are throughput (above 1 = FEX faster):
  - FEX ≈ Rosetta overall.
  - FEX lower on direct calls (0.60), scalar SSE (~0.65), `cvttsd2si` (0.63) and denormals (0.60). The author blames the M1's missing FEAT_AFP.
  - FEX higher on AVX2 (1.46), vector integer (1.38), indirect calls (1.41) and `rep movsb` (1.70).
  - Its benchmark source (`fexbench2.c`) is not published.
  - FEX turns on software TSO regardless of thread count (`FEXCore/Source/Interface/Context/Context.h:460-470`; no thread-count condition anywhere at the pin). Whether CrossOver's FEX ran with it is unknown.
- **This M5 Pro has FEAT_AFP.** FPCR.FIZ/AH/NEP are writable from user mode and behave the x86 way: scalar ops keep the upper lanes, and denormal inputs flush.
- **FEX on Windows reads CPU features only from registry values** under `HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0`:
  - `CP 4030/4020/4021/4031/4038/403A/4024/4039/4032/5801/4000` (`Source/Windows/Common/CPUFeatures.cpp:44-62`);
  - DCZID via `mrs`.
  Wine writes those values only from the stub above, so today FEX sees zeros: no LSE, no LRCPC, no AFP. With no `CP 5801`, FEX assumes 64-byte cache lines. Under Wine it uses only the line size, because its cache-maintenance path is off.
- **FEX always advertises AVX** (`Source/Common/HostFeatures.cpp:540`). Rosetta advertises it only with `ROSETTA_ADVERTISE_AVX=1`, which MacNeutron's launcher sets.
- **FEX logs nothing by default.** `SilentLog` defaults to true, and it has no host-feature log.

### 3.6 What a fused translator would buy

Only the x64↔ARM64EC crossing cost, about 100–200 cycles per round trip on Microsoft's xtajit64 (FEX unmeasured). At 15k draws × 3–8 crossings, that is 1.7–4.5 ms per frame at 150 cycles, and up to 6 ms at 200. A GPU-bound game gains nothing. Valve's Proton for ARM uses the same layered design.

## 4. Architecture

```
 One game process (native arm64, 4K pages, executable = wine.app/Contents/MacOS/wine)
 ┌────────────────────────────────────────────────────────────────────┐
 │ x64 game code ── FEX ARM64EC JIT (libarm64ecfex.dll) ─┐             │
 │                  writes the RW view, runs the RX view │ x64→EC call │
 │ ARM64EC/ARM64X Wine DLLs (ntdll, kernel32, user32 …) ◄─┘             │
 │ ARM64X DXMT (d3d11, d3d12, dxgi) ── winemetal.so ── Metal            │ (sub-project 2)
 │ ntdll.so / win32u.so / winemac.so ── libSystem, AppKit                │
 └────────────────────────────────────────────────────────────────────┘
          │ Wine server protocol
 wineserver (native arm64, 16K pages, not entitled)
```

**`wine.app`.** The whole runtime lives in one bundle, signed and verified as a unit. `make install`'s tree goes under `Contents/Resources`, and two in-bundle symlinks tie it to the entitled executable:

```
wine.app/Contents/
  Info.plist                      CFBundleIdentifier net.authspot.macneutron.wine, CFBundleExecutable wine
  embedded.provisionprofile
  MacOS/wine                      the loader: the only entitled binary
  MacOS/ntdll.so  -> ../Resources/lib/wine/aarch64-unix/ntdll.so
  Resources/bin/                  wineserver and the rest of bindir
  Resources/lib/wine/aarch64-unix/  ntdll.so, the other unix libraries, the FEX unixlib,
                                  wine -> ../../../../MacOS/wine   (replaces make install's unentitled copy)
  Resources/lib/wine/aarch64-windows/  the PE DLLs, libarm64ecfex.dll
  Resources/share/wine/           wine.inf, nls
```

How Wine finds things in this layout:
1. **The first process.** The loader loads `<real directory of the executable>/ntdll.so`. That is `MacOS/ntdll.so`, which resolves to the real `ntdll.so` (`loader/main.c:149-158`).
2. **Paths.** `init_paths` takes `ntdll.so`'s real directory. From it come `dll_dir`, then `bin_dir` and `data_dir` through configure's relative paths, and `wineloader = <ntdll dir>/wine` (`dlls/ntdll/unix/loader.c:383-400`). That `wine` is the symlink back to `MacOS/wine`.
3. **Every exec** (each new Windows process, and patch 8's re-exec) therefore runs the entitled loader. The kernel honours the entitlement through a symlink (verified in the trial).

`codesign --verify --strict --deep` accepts this layout with in-bundle symlinks; this was verified on a test bundle during review. `bundle.sh` asserts the paths below, and stops the build if any is wrong:
- `realpath(Resources/lib/wine/aarch64-unix/wine)` is `Contents/MacOS/wine`;
- `bin_dir/wineserver` and `data_dir/wine.inf` resolve inside `Contents/`;
- no other Mach-O named `wine` is left in the bundle.

**Pages.** Every Windows process runs with 4K pages; `wineserver` keeps 16K. Shared mappings rounded up to 16K by the server (`server/mapping.c:226`) are believed harmless (§11).

**Memory below 4 GB.** Owned by Wine (patch 2): the low area stays reserved, so neither malloc nor frameworks land there, and Wine maps from it as it does on x86_64.

## 5. Wine

### 5.1 Pins

`wine-arm64/pins`:
- `WINE_REPO=https://gitlab.winehq.org/wine/wine.git`, `WINE_COMMIT=455e3509b98a6919fd4ad1def4803e08c41c03b2` (tag `wine-11.19`);
- FEX's repo and commit (§6.1);
- llvm-mingw: reused from `dxmt/pins` through `dxmt/toolchain.sh` (20260908, which has the `arm64ec-` and `aarch64-w64-mingw32` wrappers). No second pin.

### 5.2 Patch series

In `wine-arm64/patches/wine/`, `git format-patch` output applied with `git am` in order. Each patch is one commit with a message saying why.

| # | Patch | Source |
|---|---|---|
| 1–6 | §3.3's six patches | `docs/research/…/trial-patches/`, re-reviewed; patch 6 keeps its original authorship |
| 7 | **The exec target must be entitled.**<br>• Once per process, before any fork, check that `wineloader` carries `com.apple.developer.cross-architecture-support`: `SecStaticCodeCreateWithPath`, `SecCodeCopySigningInformation`, then `kSecCodeInfoEntitlementsDict`. Link `$(SECURITY_LIBS)` into ntdll (the variable exists for crypt32 and mountmgr).<br>• If the entitlement is missing, `fatal_error` names the path and says to re-sign the runtime. There is no 16K fallback: an unentitled loader can't map KUSER either.<br>• A failed `posix_spawn` is logged with its errno.<br>`os_cross_arch_is_supported` is not a substitute (§3.1) | New |
| 8 | **Installed layout:** `pre_exec` re-execs the first process when `getpagesize() != 4096`, after patch 7's check. So every entry point (game launch, `wineboot`, `winepath`) runs 4K. Today it re-execs only from the build tree | New |
| 9 | **Bounds checks** before the PE side reads the ARM64EC code bitmap:<br>• in `RtlIsEcCode`, `if (!map \|\| ptr >= 0x800000000000) return FALSE`;<br>• the same bound in `arm64x_check_call` (`lsr x16, x11, #47; cbnz`) | Madeira `ac650deca3` and `d88d55eee0`, adapted (LGPL branch `madeira-lgpl`) |
| 10 | **`get_core_id_regs_arm64` for macOS.** The values come from `hw.optional.arm.FEAT_*` sysctls. `system.c` reads only LSE, LSE2 and LRCPC today; add the rest, including AFP, LRCPC2, FlagM/FlagM2, SHA1/SHA256/SHA512/SHA3, AES/PMULL, CRC32, DotProd, FHM, FRINTTS, RPRES, ECV, BF16 and I8MM.<br>• ID_AA64ISAR0/1/2 (CP 4030/4031/4032)<br>• PFR0/1 (4020/4021)<br>• MMFR0/1/2 (4038/4039/403A), with MMFR1's AFP field (bits 47:44) set<br>• ZFR0 (4024) = 0<br>• MIDR (CP 4000) with implementer 0x61 (Apple) and part number 0, never `hw.cpufamily` (a hash)<br>• No `CP 5801`: CTR_EL0 can't be read on macOS (SIGILL), and FEX's default is fine | New |
| 11 | **ARM64EC marking of mapped views.** `NtMapViewOfSectionEx` honours `MEM_EXTENDED_PARAMETER_EC_CODE`: `virtual_map_section` marks the view's pages in the code bitmap, as `allocate_virtual_memory` does (`virtual.c:5260-5263`). FEX's own `ImageTracker.cpp:253-257` shows Windows accepts the attribute on views | New |
| 12 | **Trace W^X flips:** one `TRACE` per flip in patch 6's two branches (address, direction), on a `wxflip` debug channel, for G5 | New |

Patches beyond these come from failures observed during bring-up, each with the failure in its message.

Not ported, and why:
- KUSER relocation, KUSER read emulation and the ENOMEM fix: the entitlement makes 0x7ffe0000 mappable.
- citi94's x18 commits and old-SDK linking: replaced by patch 4.
- CrossOver's CW 24945/25719: they fault forever on native arm64.
- MR !11638: it conflicts with 11.19, and its process-wide `current_teb` can race.

### 5.3 x18

Patch 4 turns the mode on once per thread, which behaves like Apple's legacy path for old SDKs. That breaks the header's rule against calling macOS code with the mode on. Today it does no harm: a disassembly scan of all 4,088 shared-cache images on macOS 27.0.1 (1,021 matches, all classified in `x18-boundaries.md`) found no code that depends on x18's value. The scan is `probes/x18-cache-scan.sh` (about 2.5 minutes), to be rerun on every macOS beta.

Sub-project 3 replaces it with toggling at every transition. That is about 110–140 lines in `signal_arm64.c` (amended 2026-10-04: the earlier 80–100 left out passing the toggle's `brk #1` through Wine's trap handler, a "PE stack implies ON" check, and a test hook; see the sub-project 3 spec §9):
- off on syscall and unix-call entry, and on again on return;
- on before user-callback entry;
- a wrapper on the nine signal handlers;
- the x18 reads that would run while off moved earlier.

The transition table, the design and its stress tests are in `x18-boundaries.md`.

### 5.4 Build

`wine-arm64/build.sh` (`make wine-arm64`):
1. **Tools.** Checks for:
   - `autoconf` (Homebrew);
   - `bison` and `flex` (Homebrew, keg-only: the script puts `$(brew --prefix bison)/bin` and `$(brew --prefix flex)/bin` on `PATH`);
   - `cmake` and `ninja`;
   - the signing variables (§7.1).

   It names anything missing and never installs it.
2. **Fetch.** Shallow clones into `build/wine-arm64-src/{wine,fex}` at the pins.
3. **Patch.** A branch `macneutron` at the pin, with `git am` of the series. A patch that fails to apply stops the build and names it.
4. **Configure** with `MACOSX_DEPLOYMENT_TARGET=27.0`:
   ```
   configure --enable-archs=arm64ec,aarch64 --with-mingw=llvm-mingw --disable-tests \
     --without-x --without-wayland --without-oss --without-alsa --without-pulse --without-sane --without-usb \
     --without-v4l2 --without-pcap --without-capi --without-opencl --without-cups CC=/usr/bin/clang
   ```
   - It runs out of tree, with the llvm-mingw `bin` on `PATH`.
   - No `autoreconf` (amended 2026-10-03): a patch that changes `configure.ac` carries the regenerated `configure`, as patch 1 does. Running `autoreconf` at build time rewrote `configure` whenever Homebrew's autoconf differed from the one Wine used, which turned every build into a development build and stopped new patches from being applied.
   - `--with-mingw=llvm-mingw` stops configure picking Homebrew's `x86_64-w64-mingw32-gcc` for the x86_64 helper objects.
   - MoltenVK isn't needed until something uses Vulkan.
5. **Make,** then `make install` into the `Contents/Resources` tree (§4). The loader binary is copied to `Contents/MacOS/wine`, and the installed loader copy is replaced by the symlink.
6. **FEX** (§6.3).
7. **Bundle and sign** (§7.2).
8. **Stamp.** `build/wine-arm64/version` holds a hash of every build input:
   - the pins;
   - the patch files;
   - `wine.entitlements`;
   - the build scripts;
   - the signing identity's name.

   An unchanged stamp skips the build.

**Development mode.** If `build/wine-arm64-src/wine` (or `fex`) has uncommitted changes or commits beyond the exported patches:
- the build skips fetch, patch and the stamp check;
- it builds the branch's HEAD as it is, and prints "development build";
- it still signs.

`make wine-arm64-export` runs `git format-patch` into `wine-arm64/patches/`. The development loop:
1. Edit on the branch.
2. `make wine-arm64`.
3. Test.
4. `make wine-arm64-export`.
5. Commit.

## 6. FEX

### 6.1 Pin and patches

**Pin:** upstream FEX-Emu/FEX `4ed80fd07176dce976a7351f559d59a47b68cbae` (2026-08-26, the merge of #5855), with submodules at that commit.

`wine-arm64/patches/fex/`:
1. dappermint `4efc3abc8a`: the macOS unixlib helpers. It reports hardware TSO as unsupported, maps `madvise` values, makes naming anonymous mappings a no-op, and stubs the stats shared memory.
2. On Apple, `Source/Windows/UnixLib/CMakeLists.txt` stops linking `rt`.
3. Madeira (`willfaust/FEX`, branch `ios-port-2607`) `fdf361f0e` (variadic `ret_sp_misaligned` off by 8) and `ceabf254a` (128-bit CASPAL). Both are marked not iOS-specific; MIT with attribution (Madeira's pre-2026-08-28 MIT grant). (Amended 2026-10-03: `ceabf254a`'s call-return-stack guard is not taken. Its hunks only change an inline check added by Madeira's iOS-only `707f213f5`, which isn't at the pin; the pin's own guard pages bound the stack on our 4K-page Wine.)
4. **Dual-view code memory** (§6.2).

Madeira's other FEX commits are iOS-specific (debugger-attached JIT, alias tables, iOS address-space bands) and are not taken. Its WoW64 commits wait for sub-project 8.

### 6.2 Dual-view code memory

**What changes.** At the pin, FEX's executable allocations all go through `AllocatorHooks.h`'s `VirtualAlloc(..., PAGE_EXECUTE_READWRITE)` with the EC attribute:
- `SharedCodeBufferManager.cpp:21`: the JIT code buffers (16 MB, growing to 128 MB, with the last page set to no access as a guard);
- `CodeCache.cpp:617` and `:863`: the code cache;
- `Dispatcher.cpp:40`: the dispatcher's host code, written once at startup.

That executable path is replaced by one dual-view pool, so there is one code path:
- **The pool:** one pagefile-backed section created with `NtCreateSection(PAGE_EXECUTE_READWRITE)`, mapped twice:
  - an RW view that FEX writes;
  - an RX view that runs, mapped with `MEM_EXTENDED_PARAMETER_EC_CODE`, which Wine patch 11 honours.
- **The write delta is fixed** (RX address + delta = RW address), as in Madeira's `DualMap::WriteOffset` (`CodeEmitter/Buffer.h`). The plan sizes the pool. If Wine's section commit can't grow views on demand, the plan reserves the whole pool up front.
- **Failure** (amended 2026-10-03): a pool that can't be created is fatal (it means the platform or Wine patch 11 is broken). An allocation the full pool can't serve falls back to an RWX page, through patch 6's flip, and logs one ERROR per process: a game that outgrows 1 GiB of JIT code runs slower rather than crashing. Both messages go through FEX's log, which is silent unless `FEX_SILENTLOG=0`; a failed pool still ends the process visibly (Wine reports the unhandled exception), and G5's flip count catches a full pool.
- **Guard pages** stay on both views.

**Code that must store through the write delta,** while it computes addresses and branch targets from the execute view:
- the emitter's stores;
- block linking and backpatching;
- `CallRetStack`;
- register-spill patching;
- the SIGBUS unaligned-atomic backpatcher (`Arm64.cpp:2108-2160`, which writes at the faulting PC, an RX address). It is reached from `Module.cpp:719-721` on the default TSO path.

`IsAddressInCodeBuffer` and its users keep comparing RX addresses. Cache maintenance goes through `NtFlushInstructionCache` on the RX view. Madeira's dual-mapped pool commits are the map. On iOS the pool comes from a debugger-attached JIT; here it comes from the section.

**What stays as it is:**
- `Module.cpp:629`, FEX's return stub. It holds a single x64 `ret` byte that FEX translates; the host never executes it.
- FEX's detection of self-modifying x64 code, which traps guest code pages to `PAGE_EXECUTE_READ`. That is guest memory, not FEX's.

### 6.3 Build and registration

- **Build:**
  - `libarm64ecfex.dll`: CMake + Ninja with `Data/CMake/toolchain_mingw.cmake`, `MINGW_TRIPLE=arm64ec-w64-mingw32` and `TUNE_CPU=none` (the default reads `/proc/cpuinfo`).
  - The unixlib: Apple clang, with `CMAKE_OSX_DEPLOYMENT_TARGET=27.0`.
- **Checks after every build:**
  - `llvm-objdump -p` lists only `ntdll.dll` as an import, and there is no TLS directory (upstream links libc++ statically);
  - the builtin marker is present. FEX's build stamps it; Wine ignores non-builtin DLLs in its own directories.
- **Install:** the DLL goes into `aarch64-windows` and the unixlib into `aarch64-unix`; both are signed with the bundle.
- **Registration:** after `wineboot`, `HKLM\Software\Microsoft\Wow64\amd64` (default value) = `libarm64ecfex.dll`. `wine.inf` writes `xtajit64.dll` there with "don't overwrite", so the value survives `wineboot -u`. Sub-project 5 makes this part of prefix creation; here `check.sh` does it.

## 7. Signing and checks

### 7.1 Identity

- **Signing identity:** `MACNEUTRON_SIGN_IDENTITY` (the maintainer's "Developer ID Application: … (49QMZXLR8S)").
- **Profile:** `MACNEUTRON_PROVISIONING_PROFILE` (a path). The profile is not committed.
- **Missing either:** `make wine-arm64` stops and says which. There is no ad-hoc mode: an unentitled loader can't map the low 4 GB or get 4K pages, so it can't boot.
- **Other builders:** only a team with the capability granted can produce a working runtime. Anyone else needs their own App ID and grant; `wine-arm64/README.md` says so.

### 7.2 Entitlements and signing

`wine-arm64/wine.entitlements`, committed:
- `com.apple.application-identifier` = `49QMZXLR8S.net.authspot.macneutron.wine`
- `com.apple.developer.team-identifier` = `49QMZXLR8S`
- `com.apple.developer.cross-architecture-support` = true
- `com.apple.security.cs.allow-jit`, `…allow-unsigned-executable-memory` and `…disable-library-validation` = true

`bundle.sh` stops the build if any step fails:
1. Signs every Mach-O inside the bundle except the loader, with the identity and the hardened runtime.
2. Signs the bundle with the entitlements, so they land on `Contents/MacOS/wine`.
3. Checks `codesign --verify --strict --deep`.
4. Checks that `codesign -d --entitlements -` on the loader shows the cross-architecture entitlement.
5. Checks that every Mach-O has `minos 27.0`.
6. Checks §4's path assertions.

### 7.3 `wine-arm64/check.sh` (`make wine-arm64-check`)

**Prefixes:** both fresh, under `build/wine-arm64-check/`: `arm64/` for this stack, and `rosetta/` for G4's baseline.

**Cleanup**, at the start and on any exit, including failure:
- `wineserver -k` for both runtimes;
- then any process whose executable is under either runtime (`lsof -t`).

Each step prints `PASS`/`FAIL <step>` with its numbers, runs under its own time cap, and the script exits non-zero after the first failing step.

| Step | Cap | Check |
|---|---|---|
| 0 macOS | — | macOS ≥ 27 |
| 1 Signature | — | §7.2's checks on the staged copy |
| 2 Boot | 3 min | `WINEDLLOVERRIDES="mscoree,mshtml=" wineboot -i` |
| 3 Pages | 1 min | Every process started in steps 2 and 4 traced `host page size: 4k` in `WINEDEBUG=+virtual`; none 16K |
| 4 Native ARM64 | 1 min | `arm64-hello` prints `PROCESSOR_ARCHITECTURE_ARM64` (12) and KUSER_SHARED_DATA read at 0x7ffe0000; `GetSystemInfo`'s page size is printed for information only |
| 5 FEX registration | 1 min | The registry value from §6.3 is set |
| 6–10 | per gate | §8's gates, in §8's order |

Test programs live in `wine-arm64/tests/`, built with the pinned llvm-mingw:
- ARM64 tests: `aarch64-w64-mingw32-clang`.
- x64 tests: `x86_64-w64-mingw32-clang -fms-extensions` (for `__try`/`__except`); C++ tests also get `-static` (otherwise they import `libc++.dll` and `libunwind.dll`).

## 8. Gates

**Order:**
1. G1, G3 and G2 run first, with FEX patches 1–3 only: FEX's code goes through patch 6's flips while it is brought up.
2. Then the dual view (FEX patch 4 + Wine patch 11).
3. Then G5.
4. Then G4, so the speed numbers aren't polluted by flips.

**Time box:** three weeks from the start of implementation.

**Week-1 checkpoint:**
- `make wine-arm64` builds Wine patches 1–10 from committed files;
- FEX with patches 1–3 is built and registered;
- steps 0–5 pass;
- the x64 hello runs, or its crash is understood: the fault class from the ESR, the PC against the code bitmap, the FEX buffer or the x64 image, and the page protection.

| Gate | Test (`wine-arm64/tests/`) | Pass |
|---|---|---|
| **G1 Correctness** | • `x64-hello`: prints a line, plus `IsWow64Process2`'s native machine (ARM64)<br>• `x64-seh`: an access violation caught by `__try`/`__except` with code 0xC0000005; a C++ throw/catch; a vectored handler that sees one exception<br>• `x64-threads`: 32 threads, each with a distinct TLS value; events and a critical section; a shared counter that ends at the expected total<br>• `x64-kuser`: reads KUSER directly. `NtMajorVersion` (0x7ffe026c) is 10, and `TickCount` (0x7ffe0320) is within 50 ms of `GetTickCount64()`<br>• `x64-smc`: rewrites one of its own functions, then calls it and gets the new result | Each prints its expected lines and `PASS` under FEX |
| **G2 Memory ordering** (scalar accesses) | `x64-litmus`: message passing in the spin-read shape that showed ~40% violations natively (§3.1), plus load buffering, 2+2W and IRIW. 10 million iterations each, plain scalar loads and stores (no `lock`), threads not pinned (Wine can't set affinity on macOS) | • Default run, with no `FEX_*` variables (FEX's defaults: `TSOEnabled` and `HalfBarrierTSOEnabled` on; vector and memcpy TSO off): 0 forbidden outcomes in every pattern<br>• Control run with `FEX_TSOENABLED=0`: at least one message-passing violation, which proves the test can detect them. The other patterns are reported, not gated |
| **G3 CPU features** | `check.sh` reads and decodes the registry values patch 10 writes | ISAR0[23:20] ≥ 2 (LSE), ISAR1[23:20] ≥ 2 (LRCPC2) and MMFR1[47:44] ≥ 1 (AFP). An optional `FEX_SILENTLOG=0` run is kept for diagnosis |
| **G5 JIT** | A full `x64-bench` run with `WINEDEBUG=+wxflip` (patch 12) | 0 flips after FEX's initialization |
| **G4 Speed** (measured, not gated) | `x64-bench`, our own (the gist's source isn't published):<br>• the gist's 29 single-threaded rows (§3.5);<br>• 4- and 8-thread rows: a contended `lock xadd` counter, a single-producer/single-consumer ring of plain loads and stores, a parallel `memcpy`;<br>• call-heavy rows: a 64-deep direct call chain, C++ virtual calls, `std::function`.<br>The FEX side runs on this stack. The Rosetta side runs through `macneutron launch waitforexitandrun` with `MACNEUTRON_TOOL` pointing at a tool folder with the pinned runtime-v4.7.3, as `dxmt/check.sh` does. That gives the launcher's normal environment (`ROSETTA_ADVERTISE_AVX=1`, `WINEMSYNC=1`), in the `rosetta/` prefix.<br>Both sides run the same `.exe`, 5 separate processes per side, on the same Mac in the same session. Each side records the CPUID features it saw | A table of every row's time ratio (FEX ÷ Rosetta; above 1 = FEX slower). Also: the geometric means of the single-threaded rows, the multithreaded rows and the call-heavy rows, separately, and the worst five rows |

**At the end of the three weeks:**

| Gate state | Outcome |
|---|---|
| G1 fails with no understood cause | Stop, and bring the decision back to the maintainer: a deeper Madeira port, or waiting for upstream FEX/Wine |
| G1 fails with an understood cause | Continue on that cause; the box is extended by agreement |
| G2 fails | Sub-project 1 isn't done and the stack doesn't ship; the bug is fixed (or reported to FEX if it is theirs) |
| G3 fails | Fix patch 10 (small) |
| G5 fails | Continue the dual-view work; G4 is measured anyway, with the flip count recorded next to it |
| G4 is poor | Find where the cost is (TSO fences, call/return handling, JIT churn) and record it. It informs sub-projects 6 and 9 |

## 9. Errors

| Condition | Behavior |
|---|---|
| Signing identity or profile not given | `make wine-arm64` stops and names the variable |
| The loader lacks the entitlement after signing, a path assertion fails, or `minos` is wrong | `bundle.sh` stops; nothing is staged |
| A patch fails to apply to the pin | The build stops and names the patch |
| The exec target lacks the entitlement at runtime (e.g. a hand-copied or relinked loader) | Patch 7: `fatal_error` names the path and says to re-sign the runtime. No silent SIGKILL |
| `posix_spawn` with the 4K attribute fails | Patch 7 logs `err:process` with the errno |
| A check step hangs | Its cap ends it; cleanup kills by executable path and `wineserver -k`; the step reports FAIL |
| macOS below 27 | `check.sh` stops at step 0. Sub-project 5 turns this into a preflight error |

## 10. Acceptance on the maintainer's Mac

Recorded in `docs/testing/acceptance-arm64-wine.md`:
1. `make wine-arm64` succeeds from a clean `build/`, and `codesign --verify --strict --deep` passes.
2. `make wine-arm64-check` passes steps 0–5 and gates G1, G2, G3 and G5, and records G4's table, geometric means and worst five rows.
3. The Rosetta stack is unchanged: `make test` and `make dxmt-check` pass as before.
4. **Orphan check:** no process under either runtime is left after `check.sh` exits, whether it passed or failed.

## 11. Risks

- **x18 under the once-per-thread mode** breaks Apple's documented rule until sub-project 3 makes it strict. If Apple gives x18 a meaning for system code, it fails silently. `probes/x18-cache-scan.sh` is rerun on every macOS beta. Resolved 2026-10-04: sub-project 3's patches 0004 and 0017-0019 toggle at every transition (`docs/testing/acceptance-arm64-ship-base.md`).
- **Software TSO** is FEX's only option, because the entitlement grants no hardware TSO. G2 measures correctness for scalar accesses only, since vector and memcpy TSO are off by default. G4 and sub-project 6 measure the cost.
- **Games with their own JIT** (Mono, .NET, LuaJIT): x64 JIT code runs under FEX, which reads guest code as data, so its RWX pages don't need host execute (inferred; sub-project 3's `wxflip-x64` check proves it). Native ARM64/ARM64EC JITs (rare) go through patch 6's flip at about 8.5 µs per switch, and patch 6 loops forever on native code that stores into its own RWX page; both are accepted and documented (amended 2026-10-04).
- **A Homebrew leak through configure:** Wine's configure reads whatever `.pc` files Homebrew has, so a library could be linked from `/opt/homebrew` without notice. Sub-project 3 configures against its own deps only and asserts every bundled dependency path.
- **msync mode agreement:** the client and wineserver must agree on `WINEMSYNC`, or the client exits; everything that starts the runtime sets it the same way, and switching needs `wineserver -k`.
- **The dual-view port** touches FEX's emitter, linker and the SIGBUS backpatcher. Madeira's changes are iOS-shaped, so expect adaptation, not a cherry-pick. Wine's handling of section views (commit on demand, patch 11's EC marking) is new territory.
- **Restricted entitlement:**
  - It ties working builds to the maintainer's team.
  - Notarization of a bundle with it is unverified (sub-project 5): trial R0 of `2026-10-04-macneutron-arm64-release-design.md` notarizes and launches it (§6.2).
  - Apple could revoke it; the unentitled design is the fallback, at months of cost.
- **16K with patch 6** is untested. If 4K pages ever had to go, that is the first thing to try.
- **Upstream churn:** Wine and FEX move weekly. We rebase on our own schedule; patch files keep each rebase reviewable.
- **wineserver's 16K rounding** of shared mappings is believed harmless (inferred).
- **Licences in the runtime:** the FEX fork's Madeira-derived changes are MIT under Madeira's pre-2026-08-28 grant (all commits used are dated earlier). A Madeira commit published on or after 2026-08-28 would be GPL-3; check the date before importing one. Not legal advice.
