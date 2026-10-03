# MacNeutron — Native arm64 stack: roadmap and sub-project 1 (arm64 Wine + FEX for x64)

- **Date:** 2026-10-02
- **Status:** Draft for review
- **Builds on:**
  - `2026-09-27-macproton-runtime-design.md` (tool folder, launcher, prefixes)
  - `2026-09-28-macneutron-dxmt-fork-design.md` (our DXMT fork, `dxmt/` build layout)
- **Scope:**
  - **In:**
    - the roadmap from today's stack (x86_64 Wine + DXMT under Rosetta) to one native arm64 process;
    - the full design of sub-project 1: upstream Wine 11.19 built as an entitled, 4K-page, Developer ID-signed `wine.app`, with FEX running x64 Windows code inside it;
    - sub-project 1's go/kill measurements.
  - **Out:**
    - sub-projects 2–9 (§2), each with its own spec;
    - shipping any of this to players: the Rosetta runtime stays the only shipped runtime until sub-project 5;
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
- FEX's CPU cost against Rosetta is known. ≤ 1.4× (geometric mean) is the bar a game must clear to switch (sub-project 9), not a condition for finishing sub-project 1.

### Decisions made during brainstorming

| Decision | Choice |
|---|---|
| Shape | One process, layered: FEX ARM64EC + Wine ARM64EC + DXMT ARM64X. Rejected: a fused x86 + Win32 + D3D translator (no precedent, person-years) |
| Priority | The main workstream, as fast as possible. DXMT GPU-efficiency work pauses |
| When a game switches | Per game. 64-bit D3D11/12 games move once they run on the arm64 stack at ≤ ~1.4× Rosetta's CPU cost. 32-bit and D3D9 games stay on Rosetta until their own sub-projects land |
| Apple entitlement | **Granted** on 2026-10-02: the "Cross-architecture Compatibility Framework" capability (`com.apple.developer.cross-architecture-support`) for App ID `net.authspot.macneutron.wine`, team `49QMZXLR8S`, through a Developer ID provisioning profile. The entitled path is the design; the unentitled design survives only in the research notes (§3.7) |
| Wine base | Upstream `wine-11.19`, not citi94's port, CrossOver's tree or Madeira's |
| x18 (Windows TEB) | Apple's public `os_set_custom_x18_abi_enabled`. Once per thread for sub-project 1; strict toggling at every Windows↔Unix transition before shipping (sub-project 3). No old-SDK linking |
| GPL-3 | Allowed in our FEX fork, so Madeira's GPL-3 FEX changes may be imported with attribution. Wine and DXMT stay LGPL |
| FEX JIT memory | FEX emits into a code buffer mapped twice (writable view + executable view), never into RWX pages (§3.4) |
| Patches | Patch files committed in this repo are the source of truth, applied to pinned upstream commits. No public Wine or FEX fork until the maintainer decides otherwise |
| Minimum macOS for the arm64 stack | 26.6 (`os_cross_arch_is_supported` appeared in 26.6; the x18 call in 26.4) |
| CrossOver Preview | Not used: it needs a paid CrossOver licence |

## 2. Roadmap

| # | Sub-project | Depends on | Notes |
|---|---|---|---|
| 1 | **arm64 Wine + FEX for x64:** this spec | — | Durable build, signing, FEX bring-up, go/kill gates |
| 2 | **DXMT for arm64:** ARM64X PE side, aarch64 `winemetal.so`, arm64 LLVM 15 | Wine build tree from 1 | Runs alongside 1. Known blockers: `__rdtsc` in `src/d3d12/d3d12_stats.cpp` (the only compile error), and Wine 11.19 builds `winemac.drv` with hidden symbols, so DXMT's `dlsym("macdrv_functions")` fails and nothing presents; fixed by a small `macdrv_functions` shim table in our winemac patch. Testable with ARM64EC-built test programs, no FEX needed |
| 3 | **Ship-base Wine** | 1 | Strict x18 toggling (§5.3); msync ported from CrossOver `wine1117`; freetype and gnutls bundled in `wine.app`; lsteamclient; W^X via MAP_JIT for RWX allocations other than FEX's |
| 4 | **Steam path** | 3 | aarch64 `steam.exe`; ARM64X lsteamclient against Steam's arm64 `steamclient.dylib` |
| 5 | **Launcher: a second runtime** | 3 | Per-game runtime choice, separate prefixes, preflight split, notarization of the entitled bundle, the presenter loaded without `DYLD_INSERT_LIBRARIES` (the hardened runtime ignores `DYLD_*`) |
| 6 | **SMITE 2 parity and measurements** | 2, 4, 5 | Frame time vs the Rosetta stack; the cost of x64↔ARM64EC crossings; a CPU-bound title |
| 7 | **Direct3D 9** (optional, can start now on Rosetta) | — | Import dacevedo12/dxmt `v0.4-d3d9` (LGPL) into our fork; Wine's wined3d stays the fallback |
| 8 | **32-bit games** | 3, 7 | Standard WoW64: i386 in `--enable-archs` and FEX's `libwow64fex.dll`. The entitlement makes the low 4 GB usable, so Madeira's guest-window redesign isn't needed |
| 9 | **Per-game cutover** | 6 (+8 for 32-bit) | A game moves when it passes the parity set; then delete GPTK, DXVK, the AVX switch and the Rosetta preflight |

## 3. Evidence (verified 2026-10-02 on an M5 Pro, macOS 27.0.1, unless marked)

### 3.1 The entitlement

A probe (bundle + embedded profile, Developer ID, hardened runtime) compared against the same probe ad-hoc signed:

| | Without | With the entitlement |
|---|---|---|
| Memory below 4 GB (0x10000, 0x7ffe0000, 0xfff00000) | ENOMEM | Mappable. The 4 GB hard page zero becomes a one-page hard zero plus a soft reservation (prot 0/0) that `MAP_FIXED` overrides |
| A child spawned with `posix_spawnattr_set_4k_page_size_np` (SDK `spawn.h`, macOS 26+) | Rejected (errno 88) | Runs with `getpagesize() == 4096`. The child binary itself must carry the entitlement |
| x18 after `os_set_custom_x18_abi_enabled(true)` (SDK `os/arch/arm64.h`) | Lost 200/200 | Kept 200/200, across context switches, page faults and signal return |
| Plain RWX `mmap`/`mprotect` | EACCES | EACCES (`MAP_JIT` works in both) |
| Hardware TSO (message-passing litmus, plain loads and stores) | ~41% forbidden outcomes | ~38%: none |
| Linking with `-pagezero_size 0x1000` or `-segalign 0x1000` | SIGKILL | SIGKILL: keep the default 4 GB `__PAGEZERO` and let the entitlement soften it |

Also verified:
- `os_cross_arch_is_supported(OS_CROSS_ARCH_X86_64)` returns 1. Its header documents it as "the set of cross-architecture features required by a user-space compatibility layer".
- In XNU, the entitlement makes a task eligible for the x18 toggle (`osfmk/arm64/machine_task.c:333-337`). The x18 mode is bit 48 of TPIDR_EL0, per thread, and starts off in new threads. Apps built for SDKs before 13.0 get x18 preserved always, as a "temporary override" (`:347-354`).
- The public XNU source stubs `ml_satisfies_x86_64_requirements` (returns false); the shipping kernel contains the real check and both entitlement names.

### 3.2 Upstream Wine 11.19 on macOS arm64

- Builds as ARM64X (`--enable-archs=arm64ec,aarch64`) in about 2.5 minutes, with no errors.
- **Already upstream:**
  - the Unix-side TEB through pthread TSD;
  - Apple signal contexts and fault classification;
  - a runtime host page size;
  - the ARM64EC code bitmap and the bug 60331 fix (11.18);
  - AMD64 advertised as a supported machine on aarch64 (the 2026-09-27 spike's server patch only undid citi94's own change);
  - every host `PROT_EXEC` going through `mprotect_exec` (`dlls/ntdll/unix/virtual.c:1968`).
- **Missing:** loader link flags that run on arm64, x18 handling, W^X handling, CPU ID registers for FEX on macOS (`dlls/ntdll/unix/system.c:2106-2112` is a stub), and bounds checks before the PE side reads the ARM64EC code bitmap.

### 3.3 The entitled trial

Throwaway, in `build/arm64/entitled/`, checked by a second agent that re-ran it:
- `wine-11.19` plus six patches runs as `wine.app`, signed with the Developer ID and the hardened runtime on.
- `wineboot -i` and `wineboot -u` return 0.
- All 18 Wine processes run with 4K pages; `wineserver` stays an unsigned 16K process.
- KUSER_SHARED_DATA sits at the real 0x7ffe0000.
- A native ARM64 PE hello works.
- x18 matched the TEB in 1.19e11 checks across 72 threads (`CreateThread`, thread-pool workers and the main thread).

The six patches (local commits; exported to `build/arm64/entitled/patches/0001-0006`):

| # | Change | What failed without it |
|---|---|---|
| 1 | `configure.ac`: an aarch64-darwin loader case without `-segalign`/`-pagezero_size` | The kernel kills the loader (rc 137), even entitled |
| 2 | `virtual_init` registers the entitled soft page-zero reservation with `mmap_add_reserved_area` (instead of CrossOver's `free_pagezero`, which would let malloc and frameworks into the low 4 GB) | `failed to map the shared user data: c0000018` |
| 3 | The loader exec uses `posix_spawn(POSIX_SPAWN_SETEXEC)` with `posix_spawnattr_set_4k_page_size_np` | Processes stay 16K; `failed to set 60000020 protection on ... .text` |
| 4 | `os_set_custom_x18_abi_enabled(true)` at the top of `init_syscall_frame` (every thread that runs PE code passes there) | PE code loses its TEB: `stack overflow 1088 bytes` |
| 5 | `exec_wineloader` keeps two environment strings in static buffers | `execve` returns EFAULT for any environment string within ARG_MAX (1 MB) of the 0x7ffffe000000 ceiling; `services.exe` fails with error 731. Independent of the entitlement |
| 6 | citi94 `4a50ce17c8`: `mprotect_exec` downgrades RWX to RW, and the fault handler flips the page RX↔RW | `HeapCreate(HEAP_CREATE_ENABLE_EXECUTE)` fails with 0xc0000022, then a NULL-heap crash in `winedevice.exe` |

**Corrections the verifier made, which this design carries:**
- Patch 3 has no fallback: a 4K spawn of an unentitled binary is SIGKILLed with no message. So `make` relinking `loader/wine` without re-signing breaks every launch silently.
- Wine rewrites a client's argv, so `pkill -f <path>` misses it. Only `wineserver -k` or killing by executable path cleans up; the trial left 32 orphans.
- In an installed layout (not the build tree), the first process skips the re-exec (`pre_exec` returns 0) and would stay 16K.
- `vmmap` prints "VM page size: 16384" even for 4K processes. Use region boundaries, or Wine's own trace, to check.

### 3.4 Memory for FEX's JIT

Measured inside the entitled Wine, from an ARM64 PE:

| Scheme | Cost of one write-then-execute cycle |
|---|---|
| One `VirtualAlloc(PAGE_EXECUTE_READWRITE)` page, through patch 6's fault flip | 8.46 µs (two faults plus two `mprotect`) |
| One section (`CreateFileMapping(PAGE_EXECUTE_READWRITE)`) mapped twice: an RW view for writing, an RX view for executing | 0.10 µs, mostly `FlushInstructionCache`. No Wine change needed |

Also measured, natively: `mach_vm_remap` gives an RW buffer an RX alias in an entitled hardened-runtime process; a `MAP_JIT` region can't be remapped; a `pthread_jit_write_protect_np` on/off pair costs 23 ns.

### 3.5 FEX's speed

- neo773's gist ([fex-vs-rosetta-std64](https://gist.github.com/neo773/f1f02698ad65f0b9b3218f4a73f67fc4)) measured CrossOver Preview on an M1 Max, macOS 27 beta, with 29 single-threaded x64 microbenchmarks:
  - FEX ≈ Rosetta overall.
  - Slower on direct calls (0.60×), scalar SSE (~0.65×), `cvttsd2si` (0.63×) and denormals (0.60×). The author blames the M1's missing FEAT_AFP.
  - Faster on AVX2 (1.46×), vector integer (1.38×), indirect calls (1.41×) and `rep movsb` (1.70×).
  - Single-threaded only, so it doesn't show the cost of FEX's software TSO.
- This M5 Pro has FEAT_AFP. FPCR.FIZ/AH/NEP are writable from user mode and behave the x86 way (scalar ops keep the upper lanes; denormal inputs flush).
- FEX on Windows reads CPU features only from `HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0\CP xxxx` registry values (`Source/Windows/Common/CPUFeatures.cpp`). Wine writes those only from the stub above, so today FEX sees zeros: no LSE, no LRCPC, no AFP.

### 3.6 What a fused translator would buy

Only the x64↔ARM64EC crossing cost, about 100–200 cycles per round trip on Microsoft's xtajit64 (FEX unmeasured). At 15k draws × 3–8 crossings it is 1.7–4.5 ms per frame at most, and nothing for a GPU-bound game. Valve's Proton for ARM uses the same layered design.

### 3.7 Where the research lives

- Mapping workflow brief (every x86_64/Rosetta assumption in this repo, D3D9 and 32-bit options): session scratchpad `synthesis.md`.
- Wine 11.19 survey: `w1119-brief.md`.
- Entitled trial: `ent-trial.md`; x18 boundary design: `ent-x18.md`.

Scratchpads are temporary; the facts this design needs are in §3.

## 4. Architecture

```
 One game process (native arm64, 4K pages, entitled wine.app executable)
 ┌────────────────────────────────────────────────────────────────────┐
 │ x64 game code ── FEX ARM64EC JIT (libarm64ecfex.dll) ─┐             │
 │                     emits via RW view, runs RX view   │ x64→EC call │
 │ ARM64EC/ARM64X Wine DLLs (ntdll, kernel32, user32 …) ◄─┘             │
 │ ARM64X DXMT (d3d11, d3d12, dxgi) ── winemetal.so ── Metal            │ (sub-project 2)
 │ ntdll.so / win32u.so / winemac.so ── libSystem, AppKit                │
 └────────────────────────────────────────────────────────────────────┘
          │ Wine server protocol
 wineserver (native arm64, 16K pages, not entitled)
```

**`wine.app`.** The whole runtime lives in one bundle so it can be signed and verified as a unit:
- `Contents/MacOS/wine`: the loader, the bundle's executable, carrying the entitlements of §7.2;
- `Contents/embedded.provisionprofile`;
- `wineserver`, `ntdll.so`, the other Unix libraries and the PE DLLs inside the bundle, at paths Wine finds from the loader's own location.

The exact directory layout is the plan's choice, constrained by: `codesign --verify --strict` passes, every Mach-O is signed, and no Wine patch is needed to find the libraries.

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
| 1–6 | §3.3's six patches | The trial's commits, re-reviewed; patch 6 keeps citi94's authorship |
| 7 | Patch 3 checks once that the loader carries the entitlement before using the 4K attribute (`SecTaskCopyValueForEntitlement`, or an equivalent check), and logs an error if `posix_spawn` fails. Without the entitlement it execs with 16K pages and warns | New |
| 8 | Installed layout: `pre_exec` re-execs the first process when `getpagesize() != 4096` and patch 7's check passes, so every entry point (game launch, `wineboot`, `winepath`) runs 4K | New |
| 9 | Bounds checks before the PE side reads the ARM64EC code bitmap: in `RtlIsEcCode`, `if (!map \|\| ptr >= 0x800000000000) return FALSE`, and the same bound in `arm64x_check_call` (`lsr x16, x11, #47; cbnz`) | Madeira `ac650deca3` and `d88d55eee0`, adapted (LGPL branch `madeira-lgpl`) |
| 10 | `get_core_id_regs_arm64` for macOS, from the `hw.optional.arm.FEAT_*` sysctls that `system.c` already reads:<br>• ID_AA64ISAR0/1/2 (CP 4030/4031/4032) with LSE, LRCPC and the rest;<br>• PFR0/1 (4020/4021);<br>• MMFR0/1/2 (4038/4039/403A), with MMFR1's AFP field set from `FEAT_AFP`;<br>• ZFR0 (4024) = 0;<br>• CTR_EL0 (CP 5801) read with `mrs`;<br>• MIDR (CP 4000) from `hw.cpufamily`, or 0 | New |

Patches beyond these come from failures observed during bring-up, each with the failure in its message.

Not ported, and why:
- KUSER relocation, KUSER read emulation and the ENOMEM fix: the entitlement makes 0x7ffe0000 mappable.
- citi94's x18 commits and old-SDK linking: replaced by patch 4.
- CrossOver's CW 24945/25719: they fault forever on native arm64.
- MR !11638: it conflicts with 11.19, and its process-wide `current_teb` can race.

### 5.3 x18

Patch 4 turns the mode on once per thread, which behaves like Apple's legacy path for old SDKs. That breaks the header's rule against calling macOS code with the mode on. Today it does no harm: a disassembly scan of all 4,086 shared-cache images found no code that depends on x18's value.

Sub-project 3 replaces it with toggling at every transition. That is about 80–100 lines in `signal_arm64.c`:
- off on syscall and unix-call entry, and on again on return;
- on before user-callback entry;
- a wrapper on the nine signal handlers;
- the x18 reads that would run while off moved earlier.

Its stress tests are in the x18 design note (§3.7).

### 5.4 Build

`wine-arm64/build.sh` (`make wine-arm64`):
1. **Tools.** Checks for `autoconf`, `bison` and `flex` (Homebrew, keg-only) and `ninja`/`cmake` (for FEX), and names any that are missing. It never installs them.
2. **Fetch.** Shallow clones into `build/wine-arm64-src/{wine,fex}` at the pins.
3. **Patch.** A branch `macneutron` at the pin, with `git am` of the series. A patch that fails to apply stops the build and names it.
4. **Configure:**
   ```
   autoreconf
   configure --enable-archs=arm64ec,aarch64 --with-mingw=llvm-mingw CC=/usr/bin/clang
   ```
   Also `--disable-tests` and the `--without-…` set from the trial; `--with-mingw=llvm-mingw` stops configure picking Homebrew's `x86_64-w64-mingw32-gcc` for the x86_64 helper objects.
5. **Make,** then install into the bundle layout.
6. **FEX** (§6.3).
7. **Bundle and sign** (§7.2).
8. **Stamp:** `build/wine-arm64/version` holds a hash of the pins and every patch file. An unchanged stamp skips the build.

**Development loop:**
1. Edit on the `macneutron` branch in `build/wine-arm64-src/wine`.
2. Run `make wine-arm64`, which re-signs after every link.
3. Export with `git format-patch` into `wine-arm64/patches/wine/`.

## 6. FEX

### 6.1 Pin and patches

**Pin:** upstream FEX-Emu/FEX `4ed80fd07176dce976a7351f559d59a47b68cbae` (2026-08-26, the merge of #5855), with submodules at that commit.

`wine-arm64/patches/fex/`:
1. dappermint `4efc3abc8a`: the macOS unixlib helpers. It reports hardware TSO as unsupported, maps `madvise` values, makes naming anonymous mappings a no-op, and stubs the stats shared memory.
2. On Apple, `Source/Windows/UnixLib/CMakeLists.txt` stops linking `rt`.
3. Madeira (`willfaust/FEX`, branch `ios-port-2607`) `fdf361f0e` (variadic `ret_sp_misaligned` off by 8) and `ceabf254a` (128-bit CASPAL, plus a call-return-stack guard). Both are marked not iOS-specific; GPL-3 with attribution.
4. **Dual-view code buffers** (§6.2).
5. Any debug-only patch needed for G3: a one-line log of the host features FEX detected, if FEX has no such log.

Madeira's other FEX commits are iOS-specific (debugger-attached JIT, alias tables, iOS address-space bands) and are not taken. Its WoW64 commits wait for sub-project 8.

### 6.2 Dual-view code buffers

Every FEX code buffer is one pagefile-backed section with two views:
- `NtCreateSection(SEC_COMMIT, PAGE_EXECUTE_READWRITE)`;
- one `NtMapViewOfSection` view with `PAGE_READWRITE`, which FEX writes;
- one with `PAGE_EXECUTE_READ`, which runs.

The emitter computes branch targets and PC-relative addresses from the execute view, while it stores bytes through the write view. Cache maintenance goes through `NtFlushInstructionCache` on the execute view. Madeira's dual-mapped pool commits are the map for which emitter paths need the split (pointer arithmetic, block linking, `CallRetStack`, register-spill patching). On iOS the pool comes from a debugger-attached JIT; here it comes from the section.

FEX's few other RWX allocations stay as they are, through patch 6's flip: its return stub (`Source/Windows/ARM64EC/Module.cpp:629`) is written once. So does FEX's detection of self-modifying x64 code, which traps guest code pages to `PAGE_EXECUTE_READ`; that is guest memory, not the code cache.

### 6.3 Build and registration

- **Build:**
  - `libarm64ecfex.dll`: CMake + Ninja with `Data/CMake/toolchain_mingw.cmake`, `MINGW_TRIPLE=arm64ec-w64-mingw32` and `TUNE_CPU=none` (the default reads `/proc/cpuinfo`).
  - The unixlib: Apple clang.
- **Checks after every build:** `llvm-objdump -p` lists only `ntdll.dll` as an import, and there is no TLS directory. Upstream links libc++ statically.
- **Install:** the DLL goes into the runtime's `aarch64-windows`, the unixlib into `aarch64-unix`; both are signed with the bundle.
- **Registration:** after `wineboot`, `HKLM\Software\Microsoft\Wow64\amd64` (default value) = `libarm64ecfex.dll`. `wine.inf` writes `xtajit64.dll` there with "don't overwrite", so the value survives `wineboot -u`. Sub-project 5 makes this part of prefix creation; here `check.sh` does it.

## 7. Signing and checks

### 7.1 Identity

- **Signing identity:** `MACNEUTRON_SIGN_IDENTITY` (the maintainer's "Developer ID Application: … (49QMZXLR8S)").
- **Profile:** `MACNEUTRON_PROVISIONING_PROFILE` (a path). The profile is not committed.
- **Missing either:** `make wine-arm64` stops and says which. An ad-hoc build would be killed at its first 4K re-exec, so there is no ad-hoc fallback.
- **Other builders:** only a team with the capability granted can produce a working runtime. Anyone else needs their own App ID and grant; `wine-arm64/README.md` says so.

### 7.2 Entitlements and signing

`wine-arm64/wine.entitlements`, committed:
- `com.apple.application-identifier` = `49QMZXLR8S.net.authspot.macneutron.wine`
- `com.apple.developer.team-identifier` = `49QMZXLR8S`
- `com.apple.developer.cross-architecture-support` = true
- `com.apple.security.cs.allow-jit`, `…allow-unsigned-executable-memory` and `…disable-library-validation` = true

`bundle.sh`:
1. Signs every Mach-O inside the bundle except the loader, with the identity and the hardened runtime.
2. Signs the bundle with the entitlements, so they land on `Contents/MacOS/wine`.
3. Checks `codesign --verify --strict`.
4. Checks that `codesign -d --entitlements -` on the loader shows the cross-architecture entitlement.

A failed check stops the build.

### 7.3 `wine-arm64/check.sh` (`make wine-arm64-check`)

- **Clean up first:** `wineserver -k`, then any process whose executable is under the staged runtime (`lsof -t`). The same cleanup runs on exit, including on failure.
- **A fresh prefix:** under `build/wine-arm64-check/`.

Steps, in order:
1. **Signature and entitlement** (§7.2's checks, on the staged copy).
2. **Boot:** `wineboot -i` with Mono and Gecko overrides off, within 3 minutes.
3. **4K pages:** `WINEDEBUG=+virtual` shows `host page size: 4k` in every process started, and 16K in none.
4. **Native ARM64:** an ARM64 PE prints its machine, `GetSystemInfo` page size 4096, and KUSER_SHARED_DATA read at 0x7ffe0000.
5. **FEX registration.**
6. **The x64 tests and the measurements of §8.**

Each step prints one PASS or FAIL line, and the script exits non-zero on the first failure.

Test programs live in `wine-arm64/tests/`, built with the pinned llvm-mingw:
- ARM64 tests: `aarch64-w64-mingw32`.
- x64 tests: `x86_64-w64-mingw32`.

## 8. Measurements and go/kill gates

**Time box:** three weeks from the start of implementation.

**Week-1 checkpoint:** `make wine-arm64` reproduces the trial from committed patches, steps 1–5 of §7.3 pass, and either the x64 hello runs or its crash is understood. If FEX still dies at its first guest instruction, the readable cause comes first: the fault class from the ESR, the PC against the code bitmap, the FEX buffer or the x64 image, and the page protection.

| Gate | Test (`wine-arm64/tests/`) | Pass |
|---|---|---|
| **G1 Correctness** | `x64-hello`; `x64-seh` (an access violation caught by `__try`/`__except`, a C++ throw/catch, a vectored handler); `x64-threads` (32 threads with TLS, events, critical sections); `x64-kuser` (reads 0x7ffe0008/0x7ffe0320 directly, compared with `GetTickCount64`); `x64-smc` (rewrites its own code, then runs it) | All print their expected output under FEX |
| **G2 Memory ordering** | `x64-litmus`: message passing, load buffering, 2+2W and IRIW across pinned threads, 10 million iterations each, plain loads and stores (no `lock`) | 0 TSO-forbidden outcomes with FEX's default (TSO on). With FEX's TSO turned off the same test must show forbidden outcomes; that proves it can detect them |
| **G3 CPU features** | FEX's host-feature log | AFP, LSE and LRCPC detected |
| **G4 Speed** (measured; ≤ 1.4 is the cutover bar) | `x64-bench`: the gist's 29 rows (§3.5); 4- and 8-thread rows (a contended `lock xadd` counter, a single-producer/single-consumer ring of plain loads and stores, a parallel `memcpy`); call-heavy rows (a 64-deep direct call chain, C++ virtual calls, `std::function`). Run under FEX on this stack and under the shipped Rosetta runtime (winecx-gptk) on the same Mac in the same session, 5 runs each, medians | Every row has a FEX/Rosetta time ratio and the geometric mean is recorded, with the worst five rows. A geometric mean ≤ 1.4 clears the bar |
| **G5 JIT** | `x64-bench`'s full run, with a debug counter in patch 6's fault flip | 0 flips on FEX code-buffer pages |

**When a gate fails:**
- **G1:** import more of Madeira's FEX ARM64EC changes, and diff Wine's dispatch against Madeira's Wine.
- **G2:** the stack doesn't ship until it passes. Report upstream FEX if the bug is theirs.
- **G3:** fix patch 10.
- **G4 above 1.4:** find where the cost is (TSO fences, call/return handling, or JIT churn) before deciding anything. Sub-project 1 still lands, but cutover (sub-project 9) waits.
- **G5:** fix §6.2.

**Kill:** if, at the end of the three weeks, G1 still fails with no understood cause, stop and bring the decision back to the maintainer. The options at that point are a deeper Madeira port or waiting for upstream FEX/Wine.

## 9. Errors

| Condition | Behavior |
|---|---|
| Signing identity or profile not given | `make wine-arm64` stops and names the variable |
| The loader lacks the entitlement after signing | `bundle.sh` stops; nothing is staged |
| A patch fails to apply to the pin | The build stops and names the patch |
| The loader relinked but not re-signed | Prevented: the build always signs after linking. At runtime, patch 7 sees no entitlement, runs 16K and warns, instead of being SIGKILLed |
| `posix_spawn` with the 4K attribute fails | Patch 7 logs `err:process` with the errno |
| A test hangs | `check.sh` caps each step (3 minutes), kills by executable path and `wineserver -k`, and reports FAIL |
| macOS below 26.6, or `os_cross_arch_is_supported` false | `check.sh` stops before running anything. Sub-project 5 turns this into a preflight error |

## 10. Acceptance on the maintainer's Mac

Recorded in `docs/testing/acceptance-arm64-wine.md`:
1. `make wine-arm64` succeeds from a clean `build/`, and `codesign --verify --strict` passes.
2. `make wine-arm64-check` passes every step, with G1–G5's numbers, the G4 table, and the worst five rows.
3. The Rosetta stack is unchanged: `make test` and `make dxmt-check` pass as before.
4. The orphan check: no process under the staged runtime is left after `check.sh` exits, whether it passed or failed.

## 11. Risks

- **x18 under the once-per-thread mode** breaks Apple's documented rule until sub-project 3 makes it strict. If Apple gives x18 a meaning for system code, it fails silently. Rerun the shared-cache scan on every macOS beta.
- **Software TSO** is FEX's only option, because the entitlement grants no hardware TSO. G2 and G4 measure it, and the multithreaded rows decide whether games stay within 1.4×.
- **Games with their own JIT** (Mono, .NET, LuaJIT) write and run RWX pages, which go through patch 6's flip at about 8.5 µs per switch. Sub-project 3 moves RWX allocations to `MAP_JIT` (23 ns toggles), or to a dual view.
- **Restricted entitlement:**
  - It ties working builds to the maintainer's team.
  - Notarization of a bundle with it is unverified (sub-project 5).
  - Apple could revoke it; the unentitled design (§3.7) is the fallback, at months of cost.
- **The FEX dual-view port** touches FEX's emitter. Madeira's changes are iOS-shaped, so expect adaptation, not a cherry-pick.
- **Upstream churn:** Wine and FEX move weekly. We rebase on our own schedule; patch files keep each rebase reviewable.
- **wineserver's 16K rounding** of shared mappings is believed harmless (inferred).
- **The first process in an installed layout** depends on patch 8; untested until §7.3 runs against the staged bundle.
- **GPL-3 in the runtime:** the FEX fork's Madeira-derived changes are GPL-3, in a process that also loads Valve's `steamclient` (sub-project 4). The maintainer accepted this; it is not legal advice.
