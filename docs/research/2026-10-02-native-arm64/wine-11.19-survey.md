Eight claims checked: 6 confirmed (some with corrections), 1 refuted and 1 partly refuted. The refuted one is the W4 design, which would livelock as written. Scratch work is in `/Users/chad/Documents/MacProton/build/arm64/skeptic/`: `wine/` is a wine-11.19 copy with W2–W4 applied, `patches/` holds the citi94 patches, `rwx12` is the 12.0-SDK probe, and `fex/` is a sparse checkout of FEX at 4ed80fd071.

## Claim check

**C1. W1: the stock loader link flags get the loader SIGKILLed; only the default 4 GB pagezero runs — CONFIRMED**
- configure.ac:984 is `-Wl,-segalign,0x1000,-pagezero_size,0x1000,...`.
- I re-ran `trial-11.19/diag`:
  - `h` and `h_pz4g` (4 GB pagezero) exit 0.
  - `h_pz4k` and `h_pz16k` (16K pagezero) exit 137.
  - `h_seg` (4 GB pagezero plus segalign) exits 137.
- The relinked `trial-11.19/loader/wine` has minos/sdk 12.0 and a 4 GB `__PAGEZERO`. `wineboot-pz4g.log` shows the 0x7ffe0000 ENOMEM.
- Line fixes: the KUSER `map_view` is at virtual.c:4119, not :4116, and the remap `mmap` is at :4558, not :4556.

**C2. The "already upstream" set — CONFIRMED (VERIFIED)**
- All 14 cited SHAs are ancestors of wine-11.19: 188f1fef35, f12bd89a4b, d3b41a854a, 3b6b0cedd9, 56ba8d233c, f286074aaf, 2f69c014dc, 4bbb05e4d5, 8ad6011269, 6d7b98b62d, fc2ba3ffce, 6ddac4544f, 27da578141, 9b0165a385. Checked with `git merge-base --is-ancestor` in the full-history clone `crossover/wine`.
- 188f1fef35 carries `Wine-Bug: …60331`. It is in 11.18 and not in 11.17.
- server/registry.c:1813-1820 adds AMD64 (and I386) under `__aarch64__` for 64-bit prefixes.
- 4bbb05e4d5 was already in 11.10. citi94 38165ac3f9 (touches server/registry.c, +16/-1) is what removed it, so the spike's server patch only undid citi94's own change.

**C3. The KUSER site list, W2 fix (a) and fix (b) — CONFIRMED, one correction**
- A tree-wide grep shows the 8 listed sites are complete for 64-bit macOS. The other hits don't matter here:
  - virtual.c:713 is under `#ifndef _WIN64`; :4089 is under `#ifndef __APPLE__`.
  - winternl.h:3491 is an unused macro.
  - asm.h:278/296 and signal_arm64ec.c:1976 are x64 byte patterns.
  - signal_x86_64.c and signal_i386.c are not built for this target.
- Fix (a): `arm64ec-w64-mingw32-clang -dM -E` defines `__arm64ec__` and `__x86_64__` but not `__aarch64__`. citi94 0853f419ce guards the PE sites with `#ifdef __aarch64__`, so the ARM64EC half keeps 0x7ffe0000.
- Fix (b): 60aeddb736 and 0853f419ce don't touch kernelbase/memory.c.
- Correction: kernelbase/memory.c:43 comes from 6d7b98b62d, which first shipped in wine-11.16, not 11.19. It is absent from citi94's 11.10 base.
- FEX at 4ed80fd071 has no KUSER references in `Source/Windows` (grep).

**C4. W2/W3/W4 conflict estimates — CONFIRMED, cause corrected**
- I applied 60aeddb736 → 0853f419ce → 5f36b75fd8 → 4a50ce17c8 in order with `patch -p1` on a wine-11.19 copy. Exactly one hunk was rejected: the `address_space_start` hunk of 60aeddb736 in virtual.c.
- Everything else applied, including the configure.ac hunk.
- 0853f419ce on its own fails 7 of 7 hunks: it needs 60aeddb736's context, so squash the two.
- Cause correction: the variable did not move. In 11.19 it is an unconditional `static void *address_space_start = (void *)0x10000;` at virtual.c:185. Only the i386 DOS-area bump to 0x110000 moved into `set_large_address_space` (:4071, assignment at :4103), so the `#if __i386__||__x86_64__` context is gone.
- W2 size is about +55/-0 (using 0853's `#if/#else` style, plus memory.c), not +60/-10.

**C5. W4 design (move the downgrade into `get_unix_prot`; mmap paths uncovered) — REFUTED**
- What holds: 11.19 has no W^X handling. `get_unix_prot` (:1363-1375) produces RWX, and there is no `MAP_JIT` or `pthread_jit_write_protect_np` anywhere in dlls/ntdll, loader or server.
- Probe re-run (`trial-11.19/diag/rwx`, SDK 27): RWX `mprotect`/`mmap` fail with EACCES; MAP_JIT RWX works; `MAP_FIXED` at 0x7ffe0000 gives ENOMEM.
- I also re-ran it as `rwx12`, linked with minos/sdk 12.0 and the same entitlements: identical results. The brief's UNKNOWN on this point is now VERIFIED.
- Refuted: "every mmap path goes through `get_unix_prot`… neither citi94 nor CrossOver covered the mmap paths."
  - `map_view` strips `PROT_EXEC` before any mmap (virtual.c:2276; ea68c902dd "Always rely on mprotect() to set PROT_EXEC", already in 11.10).
  - `map_file_into_view` maps RW.
  - The only `mprotect` calls in ntdll/unix are inside `mprotect_exec` (:1973, :1978) and one RW call at :2410.
  - So `mprotect_exec` (:1968) is the single place `PROT_EXEC` reaches the host, and citi94's downgrade there already covers every path.
- Moving the downgrade into `get_unix_prot` would livelock. 4a50ce17c8's exec-fault flip does `mprotect(page, host_page_size, get_unix_prot(vprot) & ~PROT_WRITE)`. With the moved line, `get_unix_prot(W|X)` returns RW, the result is `PROT_READ`, the handler returns `STATUS_SUCCESS`, and the refetch faults forever.
- 4a50ce17c8 already satisfies both placement rules:
  - The write flip sits after the write-watch block and tests `get_page_vprot(addr)`.
  - The exec flip tests `get_page_vprot(addr) & VPROT_EXEC`.
- Correction: W4 = cherry-pick 4a50ce17c8 unchanged (+31, applies cleanly). `get_unix_prot` also has a ninth caller at :2675 (`allocate_dos_memory`, i386 only, already masks EXEC).

**C6. W5: the PE side has no code-bitmap bounds check — CONFIRMED**
- `RtlIsEcCode` (signal_arm64ec.c:1393-1398) indexes the map without a bound.
- `arm64x_check_call` (from :1897) does `ldr x16,[x16,x17,lsl #3]` without a bound. Only the Unix side got one (2f69c014dc).
- The Madeira sources match the brief:
  - ac650deca3 is exactly `if (!map || ptr >= 0x800000000000ULL) return FALSE;`.
  - 0b041df945 has `ec_code_map_limit()`, buried in a large iOS debug commit.
  - d88d55eee0 has `lsr x16, x11, #39; cbnz x16, .Lexit`.
- Simplification (INFERRED): with upstream's bitmap sizing the 0x800000000000 constant is exact, so the 0b041df945 part isn't needed.

**C7. W7: registering FEX needs no Wine patch — CONFIRMED, with a nuance**
- wine.inf.in:404 is `HKLM,Software\Microsoft\Wow64\amd64,,2,"xtajit64.dll"` (flag 2 means don't overwrite).
- loader.c:4284-4316 reads that default value, falls back to `system32\xtajit64.dll`, and terminates if loading it or `arm64ec_process_init` fails.
- Nuance: the xtajit64 stub loads fine. Its `DispatchJump`, `RetToEntryThunk`, `ExitToX64` and `BeginSimulation` call `NtTerminateProcess` on the first x64 entry (xtajit64/cpu.c:38-76).
- signal_arm64ec.c:194-216 resolves 3 + 17 = 20 exports.

**C8. W6: the CPU ID registers are a stub on macOS — CONFIRMED**
- The Linux reader is system.c:2045-2104. Other hosts get the stub at :2106-2112 (`FIXME("stub"); return 0;`).
- On Apple, `create_smbios_data` tries `get_smbios_from_iokit` (:2424 → :2348) and falls back to `create_smbios_processors` (:2475).
- `ioreg -r -c AppleSMBIOS` finds 0 objects on this M5 Pro, and wineboot.c:625-645 writes `CP %04X` only from SMBIOS.
- FEX `CPUFeatures.cpp` is identical at FEX-2607 and 4ed80fd071. It reads:
  - `CP 4030/4020/4021/4031/4038/403A/4024/4039/4032`;
  - `CP 5801` (CTR) and `CP 4000` (MIDR);
  - DCZID via `mrs`.
- It dies only if the CentralProcessor\0 key is missing.
- Correction: W6 should also write 4024 (ZFR0; 0 is fine), 5801 and 4000.

**Extra checks (beyond the 8)**
- **FEX tree** (VERIFIED with `gh api` compare):
  - dappermint 4efc3abc8a is 4ed80fd071 plus 1 commit (only `FEXUnixLib.cpp`); FEX-2607...4efc3abc8a is 436 ahead, 0 behind.
  - 4ed80fd071 is the 2026-08-26 merge of #5855.
- **FEX build files:**
  - `-lrt`: UnixLib/CMakeLists.txt:9 links `rt` unconditionally, so the CMake patch is needed.
  - Correction for the link mode: ARM64EC/CMakeLists.txt:22 also statically links `-lc++ -lc++abi -lunwind`.
- **FEX RWX paths:** besides `Module.cpp:629`, `InvalidationTracker.cpp:321-326` restores pages to `PAGE_EXECUTE_READWRITE` via `NtProtectVirtualMemory` (:239, :308, :366). The trap protection is `PAGE_EXECUTE_READ` (:314-319).
- **citi94 commit counts:** 17 x18 commits (7c3445dfff…0cc8848b60) and 38 commits in total (VERIFIED).
- **Lines in Missing #5 and next failure #2:**
  - virtual.c:754 `reserve_area(0x10000, 0x68000000)` is real; it is in the `_WIN64` branch of `mmap_init`. On Apple, `reserve_area` walks `mach_vm_region` and finds the pagezero covering that range, so the call does nothing (INFERRED).
  - `try_map_free_area` is at :1545. :616 is where the Mach branch of `anon_mmap_tryfixed` sets ENOMEM (`KERN_NO_SPACE ? EEXIST : ENOMEM`). The same code was already in citi94's base, so W3 still applies.
- **Toolchain:** `config.log` shows `x86_64_CC='x86_64-w64-mingw32-gcc'`, used for 9 objects. `x86_64-w64-mingw32-clang` exists in the llvm-mingw bin directory, so `--with-mingw=llvm-mingw` works.

---

# Porting brief: native arm64 Wine 11.19 on macOS 27, unentitled, then x64 under FEX ARM64EC

Copy of the original (uncorrected) brief: `/private/tmp/claude-501/-Users-chad-Documents-MacProton/4df1af36-0116-433f-917f-5078e899b9af/scratchpad/porting-brief.md`. Skeptic pass artifacts: `/Users/chad/Documents/MacProton/build/arm64/skeptic/`.

**Base pin:** wine-11.19 commit `455e3509b98a6919fd4ad1def4803e08c41c03b2` (VERIFIED). The crossover survey's `d417ce293c9a` is the annotated tag object for the same release, not a different base (VERIFIED with `git cat-file -t`).

**Scratch tree:** `/Users/chad/Documents/MacProton/build/arm64/`. Line numbers refer to `src/wine-11.19` unless another tree is named.

**Labels:** VERIFIED means read in source, or run or probed on this M5 Pro / macOS 27.0.1. INFERRED means reasoned but not yet run.

**URL patterns for the SHAs below:**

| Source | URL pattern |
|---|---|
| Upstream Wine | `https://gitlab.winehq.org/wine/wine/-/commit/<sha>` |
| MR !11638 | https://gitlab.winehq.org/wine/wine/-/merge_requests/11638 |
| citi94 | `https://github.com/citi94/wine-macos-arm64/commit/<sha>` |
| CrossOver (dappermint) | `https://github.com/dappermint/winecx/commit/<sha>` |
| dappermint FEX | `https://github.com/dappermint/FEX/commit/<sha>` |
| Upstream FEX | `https://github.com/FEX-Emu/FEX/commit/<sha>` |
| Madeira Wine and FEX | `https://github.com/willfaust/{wine,FEX}/commit/<sha>` |
| Madeira superproject | `https://github.com/willfaust/Madeira/blob/ca3183ea3d/<path>#L<n>` |

## 1. Where 11.19 stands on macOS arm64

| Stage | Result |
|---|---|
| Configure + build (ARM64X, `arm64ec,aarch64`) | Passes (VERIFIED, `trial-11.19/make.log`). Configure takes 28 s; `make -j16` takes 138 s with 0 errors and 114 warnings. `ntdll.dll` is COFF-ARM64X with CHPE metadata. `ntdll.so`, `wineserver` and `winemac.so` are arm64 Mach-O. 592 DLLs are built. |
| Loader start with stock link flags | The kernel kills it (SIGKILL, exit 137) before it prints anything (VERIFIED, re-run 2026-10-02: `h_pz4k`/`h_pz16k` 137, `h_seg` with 4 GB pagezero 137, `h`/`h_pz4g` 0). Cause: `configure.ac:984` links every darwin loader with `-segalign,0x1000,-pagezero_size,0x1000`, and either flag alone is enough. Only the default 4 GB pagezero runs; a 16K pagezero is killed too. |
| Diagnostic relink (default 4 GB pagezero, `-Wl,-platform_version,macos,12.0,12.0`) | `wine --version` prints `wine-11.19`. `wineboot -i` exits 1 at the first allocation: `map_fixed_area out of memory for 0x7ffe0000-0x7ffe1000` (virtual.c:4119 → :2218). `MAP_FIXED` at 0x7ffe0000 returns ENOMEM because that address is inside the 4 GB pagezero (VERIFIED). |
| wineboot, native PE, x64 | Not reached on 11.19. The 2026-09-27 spike got wineboot and a native ARM64 PE hello working on citi94's 11.10 branch with the same KUSER, W^X and x18 approach (VERIFIED). |

**Toolchain caveat (VERIFIED):**
- Configure adds x86_64 as an extra arch for arm64ec (configure.ac:410, :450).
- It picked Homebrew's `x86_64-w64-mingw32-gcc` 16.2.0 (`config.log`: `x86_64_CC='x86_64-w64-mingw32-gcc'`), which compiled 9 objects, including `dlls/ntdll/arm64ec-windows/signal_x86_64.o`.
- Fix: pass `--with-mingw=llvm-mingw`. That sets `${cpu}-w64-mingw32-clang` for every PE arch (configure.ac:429-431). `x86_64-w64-mingw32-clang` is present in llvm-mingw 20260908.

**Already upstream, nothing to port (VERIFIED; all SHAs are ancestors of wine-11.19):**
- Unix-side TEB lookup through pthread TSD (unix_private.h:111-139).
- Apple signal-context access, including the ESR from `__es.__esr` (signal_arm64.c:125-141, 276-304, 1531-1534).
- Fault classification (signal_arm64.c:1138-1162).
- 4K pages on 16K host pages, with a runtime `host_page_size` (virtual.c:176-181, 1108-1122, 1987-2008).
- Mach address-space reservation, with the limit hard-coded to 0x7ffffe000000 (virtual.c:604-702, 2762; 8ad6011269).
- The ARM64EC code bitmap (virtual.c:1290-1330, 2797-2821).
- The fix for bug 60331, 188f1fef35 (`Wine-Bug: 60331`, first in 11.18; virtual.c:4173).
- AMD64 is advertised as a supported machine on aarch64 without a server patch (server/registry.c:1813-1820; 4bbb05e4d5, already in 11.10).
- The ARM64EC dispatch MRs !11697 and !11860: f12bd89a4b, d3b41a854a, 3b6b0cedd9, 56ba8d233c, f286074aaf.
- Early allocations moved above 4 GB; the first TEB is placed high (virtual.c:4153, `limit_low = limit_4g`).
- Every host `PROT_EXEC` goes through `mprotect_exec` (virtual.c:1968-1979): `map_view` strips `PROT_EXEC` before mmap (:2276, ea68c902dd, already in 11.10) and `map_file_into_view` maps RW.
- Argument-extension wrappers, CPU features from `hw.optional.arm.*`, `pthread_cpu_number_np`.

**Missing (VERIFIED by grep or reading, unless marked):**
1. Loader link flags that work on arm64 (configure.ac:984).
2. The old-SDK link that makes the kernel preserve x18. 11.19's dispatchers rely on x18, e.g. `[x18,#0x380]` at signal_arm64.c:919 and `[x18,#0x60]` in `arm64x_check_call`.
3. KUSER relocation. 0x7ffe0000 is hard-coded at the sites below. The list is complete for 64-bit macOS; the other grep hits are `#ifndef _WIN64` (virtual.c:713), `#ifndef __APPLE__` (:4089), an unused macro (winternl.h:3491), and x64 byte patterns (asm.h:278/296, signal_arm64ec.c:1976) covered by W8.
   - unix/virtual.c:201 (used at :4119 and :4558)
   - ntdll/thread.c:38
   - kernelbase/memory.c:43
   - kernelbase/sync.c:42
   - kernel32/process.c:42
   - kernel32/sync.c:45
   - win32u/message.c:48
   - ntoskrnl.exe/instr.c:493 (x64 driver emulation; later)
4. W^X handling. There is no MAP_JIT and no page flipping.
   - `get_unix_prot` (virtual.c:1363-1375) produces RWX, and `mprotect_exec` (:1968), the only place `PROT_EXEC` reaches the host, passes it through.
   - A 16K host page holding a 4K RX page and a 4K RW page gets the union, RWX.
   - VERIFIED by probe: unentitled RWX `mmap`/`mprotect` fails with EACCES; MAP_JIT RWX works. This holds for binaries linked for SDK 27 and for 12.0 (`skeptic/rwx12`).
5. Requests for memory below 4 GB: `zero_bits` / `limit_4g` callers fail (INFERRED). The `reserve_area(0x10000, 0x68000000)` at virtual.c:754 is a no-op on Apple: `mach_vm_region` finds the pagezero covering it (INFERRED from reading :632-702).
6. A bounds check before the PE side reads the code bitmap, in `RtlIsEcCode` (signal_arm64ec.c:1393-1398) and `arm64x_check_call` (:1897ff). Only the Unix side got one (2f69c014dc).
7. Fault emulation for x64 guest code that reads 0x7ffe0xxx directly.
8. CPU ID registers for FEX. `get_core_id_regs_arm64` is a stub returning 0 on non-Linux hosts (dlls/ntdll/unix/system.c:2106-2112), so wineboot writes no `CP xxxx` registry values (wineboot.c:625-645).
9. arm64 debug registers in `server/mach.c` (178-180, 264-266). Minor.

**Likely next failures once KUSER is fixed (INFERRED, in order):**
1. W^X EACCES: the first PE image with a 16K page mixing RX and RW, or `HeapCreate(HEAP_CREATE_ENABLE_EXECUTE)` in winedevice. CrossOver needed 88ca5b254b for the latter.
2. ENOMEM in `try_map_free_area` (virtual.c:1545). The errno comes from the Mach branch of `anon_mmap_tryfixed` (:616, `KERN_NO_SPACE ? EEXIST : ENOMEM`).

## 2. Patch series onto wine-11.19 (shortest path to "x64 hello under FEX")

Every row works without the entitlement. The only entitled candidate, CrossOver 82b2ee5415 (`free_pagezero`), is excluded. Unentitled, it reports `KERN_SUCCESS`, yet 0x7ffe0000 stays unmappable (VERIFIED).

| # | Purpose | Source | Size | Expected conflicts | Needed for | Needs entitlement? |
|---|---|---|---|---|---|---|
| W1 | Loader link flags | CrossOver 236d597f89 configure.ac hunk (≈ citi94 60aeddb736). The old-SDK flag is new (from the spike). | ~8 lines | none (the 60aeddb736 configure.ac hunk applies to 11.19, VERIFIED) | build, wineboot, native ARM64 PE, x64 under FEX, later i386 | no |
| W2 | Move KUSER to 0x17ffe0000; start the address space above 4 GB | citi94 60aeddb736 (KUSER and `address_space_start` parts only) + 0853f419ce, squashed, with two fixes | ~+55/-0 | 1 trivial hunk in virtual.c:185 (VERIFIED by applying); 0853f419ce does not apply without 60aeddb736 | wineboot, native ARM64 PE, x64 under FEX | no |
| W3 | Treat ENOMEM from `try_map_free_area` as "range occupied" | citi94 5f36b75fd8 | +6 | clean (VERIFIED) | wineboot (INFERRED) and everything after | no |
| W4 | W^X: never ask the host for RWX; flip page protection on fault | citi94 4a50ce17c8, unchanged | +31 | clean (VERIFIED) | wineboot, native ARM64 PE, x64 under FEX | no |
| W5 | Bounds checks on the PE-side code bitmap (for diagnosis) | Madeira ac650deca3 + the `arm64x_check_call` bound from d88d55eee0 | ~+10 | hand-port; `signal_arm64ec.c` changed a lot between 11.4 and 11.19 | x64 under FEX | no |
| W6 | Real CPU ID registers on macOS | new | ~+50 | none | x64 under FEX (recommended) | no |
| W7 | Register FEX as the AMD64 emulator | no Wine patch; done by the build script | 0 | none | x64 under FEX | no |
| W8 | Emulate x64 reads of KUSER | new, modelled on Madeira `signal_arm64_ios.c:10490-10600` (gate at :9905-9930) | ~+120 | none | x64 under FEX for real apps (not for a mingw hello) | no |

**W1 details:**
- Add an `aarch64` case at configure.ac:984.
- Keep `-sectcreate,...wine_info.plist`.
- Drop `-segalign 0x1000` and `-pagezero_size 0x1000`, which leaves the default 4 GB pagezero.
- Add `-Wl,-platform_version,macos,12.0,12.0`.
- Regenerate `configure` in the build script instead of carrying it in the patch.

**W2 details:**
- From 60aeddb736, drop the generated `configure` hunk and the ntoskrnl hunk. Squash 0853f419ce in: it only applies on top of 60aeddb736 (VERIFIED, 7 of 7 hunks fail alone).
- Fix (a): guard the PE sites with `defined(__aarch64__) || defined(__arm64ec__)`. `arm64ec-w64-mingw32-clang` defines `__arm64ec__` and `__x86_64__` but not `__aarch64__` (VERIFIED with `-dM -E`), so with citi94's guard the ARM64EC half of every DLL would silently keep 0x7ffe0000. The Unix-side guard in virtual.c (`__APPLE__ && __aarch64__`) stays.
- Fix (b): add the kernelbase/memory.c:43 site. It comes from 6d7b98b62d (first in wine-11.16), which is after citi94's 11.10 base, so citi94 doesn't cover it.
- Leave i386 at 0x7ffe0000. 32-bit code needs it below 4 GB, which is a problem for the later i386 work.
- The one conflict hunk is the `address_space_start` definition. 11.19 has an unconditional `static void *address_space_start = (void *)0x10000;` at virtual.c:185. The i386 DOS-area start (0x110000) moved into `set_large_address_space` (:4071, assignment at :4103), so citi94's `#if __i386__||__x86_64__` context is gone. Re-add it as an `#if defined(__APPLE__) && defined(__aarch64__)` around line 185 (VERIFIED by applying).

**W4 details (VERIFIED by reading and applying, unless marked):**
- **The change:** take 4a50ce17c8 as it is.
  - Hunk 1: `mprotect_exec` downgrades W|X to RW. In 11.19 this covers every host path. `mprotect_exec` is the only place `PROT_EXEC` reaches the host: `map_view` strips `PROT_EXEC` before mmap (:2276, ea68c902dd), `map_file_into_view` maps RW, and the only other `mprotect` is RW (:2410).
  - Hunk 2: on an exec fault, `mprotect` the host page to RX. On a write fault, `mprotect` it to RW.
- **Don't move the downgrade into `get_unix_prot`.** The exec-fault flip computes `get_unix_prot(vprot) & ~PROT_WRITE`. With the downgrade inside `get_unix_prot`, that becomes `PROT_READ`, the handler returns `STATUS_SUCCESS`, and the refetch faults forever. If the downgrade ever moves, the exec flip must set `PROT_READ|PROT_EXEC` explicitly.
- **Runs early enough:** `segv_handler` calls `virtual_handle_fault` before setting up any exception (signal_arm64.c:1168). So the harmless "exception outside of stack limits" warning (virtual.c:4765) can't skip the flip.
- **Placement rule 1 (already met by 4a50ce17c8):** the write-fault flip comes after the existing `VPROT_WRITEWATCH` / write-exception branch (virtual.c:4721-4741). Write-watch and `enable_write_exceptions` (237, 2026, 4725) must see write faults first. Nothing in our stack turns write exceptions on: neither 11.19's PE ntdll nor FEX 4ed80fd071 sets `ProcessEnableWriteExceptions` (VERIFIED by grep). Keep the order anyway.
- **Placement rule 2 (already met by 4a50ce17c8):** decide the flip from the faulting 4K page's own protection (`get_page_vprot(addr)`, virtual.c:1089), not from the 16K union `get_host_page_vprot` that line 4699 reads.
  - FEX detects self-modifying x64 code by trapping translated 4K pages to `PAGE_EXECUTE_READ` with `NtProtectVirtualMemory` and catching the resulting access violation (`Source/Windows/Common/InvalidationTracker.cpp:314-319, 366`, VERIFIED at FEX 4ed80fd071).
  - If the flip used the union, a write to such a page with a writable 16K neighbour would be quietly made writable, and FEX would never see the code change.
- **Rosetta workaround:** the `__APPLE__` read-fault-to-write-fault reclassification at 4701-4708 should not fire under W4 (INFERRED). If it does, gate it on `__x86_64__`.
- **What needs it:**
  - wineboot: mixed 16K pages and executable heaps.
  - FEX:
    - its return stub `VirtualAlloc(MEM_COMMIT, PAGE_EXECUTE_READWRITE)` (`Source/Windows/ARM64EC/Module.cpp:629`);
    - its untrap path, which sets `PAGE_EXECUTE_READWRITE` (`InvalidationTracker.cpp:321-326`, used at :239, :308, :366);
    - its code buffers.

**W5 details:**
- Madeira ac650deca3 is exactly `if (!map || ptr >= 0x800000000000ULL) return FALSE;` in `RtlIsEcCode` (VERIFIED).
- Rewrite the d88d55eee0 bound (`lsr x16,x11,#39; cbnz x16,.Lexit`) for macOS as `lsr x16,x11,#47`.
- With upstream's bitmap sizing the constant bound is exact, so 0b041df945's `ec_code_map_limit()`, which is iOS-sized and inside a large iOS debug commit, is not needed (INFERRED).
- It turns the spike's recursive access violation into one readable fault. It does not fix the first fault.

**W6 details:**
- Add an `__APPLE__` version of `get_core_id_regs_arm64` (the stub is system.c:2106-2112) that builds:
  - ID_AA64ISAR0/1/2 (CP 4030/4031/4032), PFR0/1 (4020/4021), MMFR0/1/2 (4038/4039/403A) and ZFR0 (4024, may be 0), from the `hw.optional.arm.FEAT_*` sysctls that system.c:621-640 already reads;
  - CTR_EL0 as `CP 5801` via `mrs` (INFERRED readable from user mode; FEX reads ctr_el0 the same way);
  - MIDR as `CP 4000` from `hw.cpufamily`, or 0.
- No other change is needed (VERIFIED):
  - On Apple, `create_smbios_data` tries the IOKit `AppleSMBIOS` service first (system.c:2424 → 2348).
  - `ioreg -r -c AppleSMBIOS` finds no such service on this M5 Pro.
  - The fallback calls `create_smbios_processors` (2475), which calls `append_smbios_wine_core_id_regs_arm64` under `__aarch64__` (2174-2178, 2195-2201).
- Why FEX cares: on Windows, FEX reads CPU features only from `CentralProcessor\0\CP xxxx`, plus DCZID via `mrs` (`Source/Windows/Common/CPUFeatures.cpp:42-70`, identical in FEX-2607 and 4ed80fd071, VERIFIED). With zeros it assumes no LSE atomics, no LRCPC and CTR=0. It dies only if the key is missing.
- That isn't fatal: the spike got past FEX's ProcessInit with zeros. Do it before crash triage anyway, to rule out a code-generation mismatch (INFERRED).

**W7 details:**
- After wineboot, the build script runs `wine reg add 'HKLM\Software\Microsoft\Wow64\amd64' /ve /d libarm64ecfex.dll /f`.
- wine.inf.in:404 writes its default with flag 2 (don't overwrite), so this value survives `wineboot -u` (VERIFIED).
- The script also places `libarm64ecfex.dll` in system32 and the FEX unixlib in `aarch64-unix`, as in the spike.
- Without the registry value, ntdll loads the stub `xtajit64.dll` (loader.c:4284-4316). The stub loads fine, but its `DispatchJump`, `RetToEntryThunk`, `ExitToX64` and `BeginSimulation` call `NtTerminateProcess` on the first x64 entry (xtajit64/cpu.c:38-76).
- ntdll resolves 20 exports from the module (3 + 17 at signal_arm64ec.c:194-216, VERIFIED).

**W8 details:**
- In `segv_handler`, when the fault address is in [0x7ffe0000, 0x7ffe1000):
  1. Decode the faulting load: LDR/LDUR/LDRB/LDRH/LDRSx in immediate and register forms, LDP, and LDAR/LDAPR/LDAPUR. FEX's software memory-ordering mode uses acquire loads (INFERRED).
  2. Read from 0x17ffe0000 + offset.
  3. Write the destination register and advance PC by 4.
- Madeira allows this only outside JIT code because its x18 trampoline clobbers x17. We have no trampoline, so JIT code is safe (INFERRED).
- What needs it:
  - x64 apps that read SharedUserData.
  - x64 apps that call ntdll `Nt*` x64 thunks directly. Those thunks execute `testb $1,0x7ffe0308` (include/wine/asm.h:278-296), and FEX has no special case for KUSER: no reference in `Source/Windows` at 4ed80fd071 (VERIFIED by grep).
  - Native ARM64 PE code that hard-codes 0x7ffe0000.
- The `.Lsyscall_seq` bytes at signal_arm64ec.c:1973-1982 are only a pattern that `arm64x_check_call` compares against (`ldr w17/x17, .Lsyscall_seq` at 1928-1937). They are never executed (VERIFIED).
- A mingw x64 hello that only calls kernel32 and msvcrt shouldn't need W8 (INFERRED). Build it right after the hello works.

**Minimum set for x64 hello:**
- W1-W5 and W7, with W6 recommended.
- About +160 lines of Wine changes (W4 is a straight cherry-pick).
- No server change and no x18 change.

**Only if the symptom shows up:**
- CrossOver 67167eb255 (NULL-heap check, heap.c:2046).
- CrossOver 88ca5b254b (redundant once W4 is in).
- Madeira's high placement for RELOCS_STRIPPED images with a base below 4 GB (virtual_ios.c:16093-16170).
- citi94 1dc0dc259c, a8f8c655c6, 74be918281. Only re-test on matching services, rpcrt4 or win32u symptoms; they are likely x18 symptoms that W1 removes.
- citi94 fcd02ef7b7 (hang on stack overflow), kept as a debug-only patch.
- Madeira FEX-glue commits 5a139a03f6, 06143656ec, 948212bd97, d7c576059c, f3339da9f6 (loader part) and a052a7f8e3. Only needed if `libarm64ecfex.dll` imports more than ntdll or has a TLS directory.

**Excluded:**

| Excluded | Why |
|---|---|
| citi94's 17 x18 commits (7c3445dfff … 0cc8848b60; count VERIFIED) | W1 makes them unnecessary. 6b590f26eb, 6c3f06f915, 2c4cf08905 and 0cc8848b60 also hide NULL dereferences. |
| citi94's 8 out-of-scope (Rosetta) commits | 38165ac3f9 breaks ARM64EC (it rewrites server/registry.c's supported machines); 7d72f383d3's `#ifdef __x86_64__` would be active in ARM64EC ntdll. |
| citi94 dc2296f6c3 and af8d0714ed | Already fixed upstream (dc2296f6c3's VA probe is superseded by 8ad6011269). |
| CrossOver CW 24945/25719 | They fault forever on native arm64. |
| CrossOver eb6cb20f00 | W4 replaces it; with it, `NtProtectVirtualMemory(RWX)` still fails. |
| MR !11638 | Conflicts on 11.19, uses a process-wide `current_teb` that can race between threads, and handles native ARM64 only. |
| Madeira's x18-loss redirects and its iOS-only commits | Not applicable on macOS with W1. |

**After the hello works (not in the series yet):**
- msync:
  - Port it from CrossOver `wine1117`.
  - The server files merge with 0 conflicts. `unix/loader.c` has 1: put `msync_init()` after `server_init_process`.
  - Add the `shm_open` and `ppoll` configure checks.
  - The current product runs with `WINEMSYNC=1`.
- DXMT window binding: option B, a `macdrv_functions` shim table, is smaller than porting `d3dmetal.c`.
- i386 support (each 32-bit process in its own 4 GB window):
  - Wine: 970dac54a4, db62a71199, 2ebe9374b2, plus the macOS-relevant parts of 059cb1923c and e928905164.
  - FEX: d8f9d483c, b8cd63b23, 4585944ba.
- KUSER in ntoskrnl instr.c:493, and arm64 debug registers in `server/mach.c`.
- winemac Dock-name cosmetics: citi94 75012b19bb (uses private SPI); CrossOver's CW 13438 needs an arm64 rework.

## 3. Design choices where the sources differ

**x18 and the Windows-side TEB**
- **Adopt:** upstream's x18 TEB, kept intact by linking only the loader with `-Wl,-platform_version,macos,12.0,12.0`.
- **Evidence:**
  - The x18 probe preserved x18 in 200/200 runs each across page faults, signal return, signal return with x18 written into the context, and timeslice switches. With the default SDK-27 link it was 0/200 (VERIFIED).
  - Signal return uses the context's x18, so 11.19's `save_context` / `restore_context` work as they do on Linux (signal_arm64.c:318).
  - The spike relinked only the loader, and wineboot plus a native PE worked.
- **Rejected:**
  - citi94's TPIDRRO_EL0 slot and trampolines: unnecessary, its heuristics hide NULL dereferences, and the trampoline clobbers x16 (see §5).
  - !11638's TPIDR_EL0 plus process-wide `current_teb`: can race between threads (INFERRED).
  - Madeira's emulation of `[x18,#imm]` accesses: only needed because iOS zeroes x18.
- **Keep this exact flag.** `-mmacosx-version-min=12` leaves the SDK field at 27, and whether the kernel keys on the minimum version or the SDK version is UNKNOWN.

**Unix-side TEB**
- Adopt upstream's pthread TSD lookup. It is already there.

**KUSER**
- **Adopt:** a fixed 0x17ffe0000 for native ARM64 and ARM64EC code (W2). Only x64 guest reads of 0x7ffe0xxx are emulated (W8). The PE-side guard is per architecture, so this is a macOS-port-only ABI choice.
- **Why:** native hot paths (GetTickCount, the sync code in kernelbase, kernel32 and win32u) never take a signal. 0x7ffe0000 itself can't be mapped under the 4 GB pagezero (VERIFIED).
- **Rejected:**
  - Madeira's "emulate every access at 0x7ffe0000": one signal per native read.
  - !11638's runtime address exported to PE code: more PE-side changes, conflicts, an unreviewed 245-line dispatcher, and x64 thunks would still need emulation.
- **Later performance step:** have FEX rewrite absolute 32-bit addresses in the KUSER range when it translates code. This is Madeira's own documented upgrade path (`signal_arm64_ios.c:10528-10533`).

**W^X**
- **Adopt:** citi94 4a50ce17c8 as is. It downgrades RWX to RW in `mprotect_exec`, which in 11.19 is the only host path for `PROT_EXEC`, and flips on fault (W4). Don't move the downgrade into `get_unix_prot`; that livelocks the exec flip (§2 W4).
- **Phase 2:** use `MAP_JIT` for anonymous `PAGE_EXECUTE_READWRITE` allocations and toggle `pthread_jit_write_protect_np` per thread in the fault handler.
- **Why:**
  - The flip is the smallest change that makes `NtProtectVirtualMemory` and `NtAllocateVirtualMemory` with RWX succeed on every path.
  - Its weakness is two threads fighting over one page. That happens on a FEX code-cache page, and on 16K pages that mix `.text` and `.data`.
  - MAP_JIT RWX works unentitled (VERIFIED), and its toggle is per thread, so threads don't fight.
- **Probe before phase 2:**
  - Does a toggle made inside a signal handler survive signal return? (UNKNOWN)
  - RWX and MAP_JIT under a 12.0-linked binary: done. RWX gives EACCES and MAP_JIT works, the same as with SDK 27 (VERIFIED, `skeptic/rwx12`, minos/sdk 12.0, same entitlements).
- Phase 1 isn't blocked: the spike's wineboot ran with an old-SDK loader and flipping.
- Madeira's dual-mapped pool exists because iOS JIT needs an attached debugger; macOS doesn't need it.
- x64 image pages never run natively under FEX, so downgrading their RWX union to RW does no harm (INFERRED).

**4K pages on 16K host pages**
- Adopt 11.19 as is: runtime host page size, per-4K protection, union on the host page.
- Limits: guard pages, write-watch, FEX's 4K self-modifying-code tracking and FEX's call-return-stack guard can't be exact inside a 16K page. Madeira hit this with its call-return-stack guard (707f213f5, ceabf254a).
- If it becomes a problem, link our builtin DLLs with 16K section alignment (INFERRED).

**ARM64EC code bitmap**
- Adopt upstream's sizing (a 4 GB view covering 128 TB) plus W5.
- Madeira's 16 MB bitmap covering 512 GB is an iOS address-space-budget choice.
- With upstream sizing, ac650deca3's 0x800000000000 bound is exact.

**Pagezero and low memory**
- Keep the default 4 GB pagezero and never free it. Unentitled freeing reports success falsely (VERIFIED).
- 11.18/11.19 already moved early allocations above 4 GB.
- x64 EXEs default to base 0x140000000, which is above 4 GB.
- Low-base images without relocations, and i386, need the Madeira-style fixes later.

**Server supported machines**
- Leave upstream unpatched: it advertises AMD64 unconditionally on aarch64 64-bit prefixes (registry.c:1819, VERIFIED; 4bbb05e4d5, already in 11.10).
- The spike's `WINEARM64EC` patch only undid citi94's own 38165ac3f9.

## 4. FEX side

**Which tree.** Checked with `gh api` compare and `gh api repos/FEX-Emu/FEX/commits/4ed80fd071` (VERIFIED, re-checked 2026-10-02):
- dappermint `main@4efc3abc8a` is upstream FEX main at `4ed80fd071` (2026-08-26, merge of #5855) plus one commit.
- It is 436 commits ahead of FEX-2607 and 0 behind.
- The extra commit is "Windows/UnixLib: implement the unix helpers for macOS" (`Source/Windows/UnixLib/FEXUnixLib.cpp`, +63/-9). It:
  - reports hardware TSO and kernel unaligned-atomic control as unsupported;
  - maps Linux `madvise` values to macOS ones (MADV_FREE is 8 on Linux, 5 on macOS);
  - makes naming anonymous mappings a no-op;
  - stubs the stats shared memory.
- willfaust `ios-port-2607@26859e184` is FEX-2607 plus 76 commits, mostly iOS-specific, built as a CRT-linked DLL.

**Recommendation:** pin upstream FEX `4ed80fd071` and carry:
1. dappermint 4efc3abc8a (macOS unixlib).
2. The spike's one-line CMake change that stops linking the unixlib with `-lrt` on Apple. `Source/Windows/UnixLib/CMakeLists.txt:9` links `rt` unconditionally (VERIFIED). This is new; 4efc3abc8a only touches `FEXUnixLib.cpp`.
3. willfaust fdf361f0e and ceabf254a:
   - fdf361f0e: variadic `ret_sp_misaligned` is off by 8.
   - ceabf254a: 128-bit CASPAL, plus a call-return-stack guard.
   - The author marks both as not iOS-specific, and neither is in upstream main@79a7afe7e (VERIFIED, Madeira survey).
4. Only if the symptom appears:
   - 707f213f5: call-return-stack bounds; the 16K guard-page issue.
   - 4cc0b431f: sets `gs_cached` to the TEB in ThreadInit. Relevance INFERRED.

Upstream FEX is MIT and willfaust's changes are GPL-3; the user has said GPL-3 is acceptable.
Superseded (2026-10-03): Madeira's FEX commits used here are MIT under its pre-2026-08-28 grant; see the spec.

**Keep upstream's link mode:** `-static -nostdlib -nostartfiles -nodefaultlibs` with static `-lc++ -lc++abi -lunwind`, and `ntdll_ex` as the only DLL import library (`Source/Windows/ARM64EC/CMakeLists.txt:14-22`, VERIFIED). Then none of Madeira's six Wine glue commits apply. Check after each build:
- `llvm-objdump -p libarm64ecfex.dll | grep 'DLL Name'` lists only `ntdll.dll`.
- `llvm-readobj --coff-tls-directory` shows no TLS directory. Static libc++ makes this worth checking.

**Export interface:**
- 11.19 expects 20 exports: 3 at signal_arm64ec.c:194-196 plus 17 `GET_PTR` at :199-215 (VERIFIED). Upstream, dappermint and willfaust FEX all provide them (VERIFIED).
- willfaust's extra `BTCpu64Ios*` and `NotifyImageMap` exports are ignored by upstream Wine.

**willfaust commits not needed (iOS-only):**

| Area | willfaust commits |
|---|---|
| x18 via TPIDRRO | 1587b0084, d21da240b |
| Rethrowing faults from off the emulator stack (Mach exceptions) | 8f0243b30 |
| Dual-mapped JIT pool and runtime patching of register spills | fce78cefd, 61f11e3cc, 6084de076, 83e12849f, 87b40c220, db4f32768 |
| Alias tables | 981b08522, 3228ed587, 13488326b, 2cf88d675 |
| Address-space bands and memory footprint | b648df337, b8368fe0a, c77105fa3, 38dddb320, 89db11f58 |
| JIT locks | 156653c06, d6d49752e |
| Mono backpatcher | 43659eb9f, 04cbb90c7 |
| JIT-pool address fix on the exception path | b64c4c252 |
| CRT linking and build | a38fb5b4e, acb015c25, 412d12118, c78110486 |
| Hand-written host feature detection | 16cae7306, 30f31d07b (fixed on the Wine side by W6 instead) |
| Probably only needed because of their trampoline | 48f7eb413 (reload x17 before CALL), 49a7b55ec, e05e7b7f6 |

WoW64 commits, only for later i386: 479da619c, d8f9d483c, c97be2836, b8cd63b23, 4585944ba, da7addf5a.

**Build:**
- Use `arm64ec-w64-mingw32` from llvm-mingw 20260908 (via `dxmt/toolchain.sh`), CMake + Ninja, and `TUNE_CPU=none` as in the spike, with submodules at the pin.
- Build the unixlib with Apple clang. Wine finds it through `WINEDLLPATH` / `aarch64-unix`, as in the spike.
- Expect lower performance: without the entitlement there is no hardware TSO, so FEX enforces x86 memory ordering in software (INFERRED).

## 5. Crash diagnosis plan

**The spike's crash, in order:**
1. A write/exec fault at x64 `.text` address `0x14000138B`, raised on FEX's stack.
2. A garbage RIP.
3. A recursive access violation in `RtlIsEcCode` through a garbage code-bitmap pointer, ending in a stack overflow.

**Step 0: the first run on 11.19 is the main diagnostic.** Three suspects are gone by construction (INFERRED):
- **citi94's x18 trampoline clobbered x16 every time it resumed after a handled fault.**
  - It is at citi94 signal_arm64.c:794-845. It runs when `virtual_handle_fault` succeeds (:1422) and when a suspended thread resumes (:1687, :1729).
  - FEX-2607 uses x16 as a working register (`Arm64Emitter.cpp:146`) and x17 as its call-return stack pointer (VERIFIED).
  - So the first W^X flip or stack-guard commit inside JIT code corrupts a live register.
  - W1 makes the trampoline unnecessary, and we don't port it.
- **Dispatcher context bugs:** fc2ba3ffce, 6ddac4544f and 27da578141 are all in 11.19 (VERIFIED). So is 56ba8d233c, which routes resumes into x64 code through KiUserEmulationDispatcher in `restore_context`. citi94's `restore_context` set PC directly (citi94 :339-350).
- **The garbage bitmap pointer:** fixed by 188f1fef35, and `is_emulated_code` now reads `arm64ec_view->base` with a `user_space_limit` check (virtual.c:2796-2801).

**First instrumentation (with W5 applied, so faults aren't buried under recursion):**
1. A debug patch in `virtual_handle_fault` / `segv_handler` that prints one ERR line per fault with:
   - PC, fault address, ESR and SP. In the ESR, exception class 0x20/0x21 is an instruction abort, 0x24/0x25 a data abort, 0x22 a PC-alignment fault; bit 6 of ISS says whether it was a write.
   - x16, x17, x18 and the TEB.
   - `RtlIsEcCode(PC)`, and whether PC is in libarm64ecfex `.text`, in a FEX code buffer, or in the x64 image.
   - The protection of the four 4K pages in the faulting 16K page, and the host protection from `mach_vm_region`.
2. `WINEDEBUG=+seh,+virtual,+loaddll,+module`, plus FEX logging. winedbg can't see faults inside FEX because debug events are suppressed while emulating (9b0165a385, in 11.19), so logs are the main tool.
3. lldb, with a debug-only `get-task-allow` signing (INFERRED). To let Wine's own handlers run (INFERRED):
   - `settings set platform.plugin.darwin.ignored-exceptions EXC_BAD_ACCESS|EXC_BAD_INSTRUCTION`
   - `process handle -p true -s false SIGSEGV SIGBUS SIGILL`
4. `vmmap <pid>` together with a hang-on-fault switch like fcd02ef7b7.

**What each observation points to:**

| Observation | Likely cause | Fix |
|---|---|---|
| PC == 0x14000138B (an odd address, so a PC-alignment or instruction abort) | Native code branched into x64 bytes: ARM64EC dispatch or the code bitmap misclassified it. This is the open "false positive" in Madeira b003f37676. | Dump the bitmap bits for the x64 image (must be 0) and the `__os_arm64x_dispatch_*` pointers (must be FEX exports). W5 bounds the lookups. |
| PC in a FEX code buffer, instruction abort on that page | The code buffer is RW and was never flipped to executable (the `VirtualAlloc(RWX)` path) | W4. Check that the flip tests the page's Windows protection for X, not the host protection. |
| PC in FEX code, data read of 0x14000138B | x64 `.text` can't be read: mapping the image failed on the RWX union with EACCES and left the page inaccessible | W4 (the `mprotect_exec` downgrade covers image protection too) |
| Data write to an x64 image page | A page was flipped to RX after a stray native execution, or FEX's code-change tracking is fighting the 16K union | Flip to RX only on host exec faults. Compare FEX's `NotifyMemoryProtect` calls with the protection of the four 4K pages. |
| Same exec fault repeating at one PC, no progress | The exec flip computed a non-executable protection (e.g. downgrade moved into `get_unix_prot`) | Keep 4a50ce17c8 unchanged, or flip to `PROT_READ\|PROT_EXEC` explicitly |
| Fault address in 0x7ffe0000-0x7ffe0fff | x64 code reading KUSER | W8 |
| Registers hold garbage right after a handled fault | The resume path clobbered state | Compare the saved and restored contexts. With no trampoline this should be gone. |
| FEX keeps running old translations after the guest rewrites its code | The W4 flip swallowed an access violation FEX needed: it used the 16K union, or ran before the write-watch branch | W4 placement rules 1 and 2 |
| Recursive access violation in `RtlIsEcCode` | A symptom of a garbage RIP | W5 bounds it; then find where the RIP comes from |
| "exception outside of stack limits" | A harmless warning for any SP off the thread's normal stack (virtual.c:4765, VERIFIED) | none |

## 6. Risks, unknowns and effort

**Risks and unknowns:**
- **x18 rests on a legacy-binary compatibility path.** This has the highest impact.
  - If a future macOS stops preserving x18 for old-SDK binaries, there is no unentitled fallback; we would need the cross-architecture entitlement.
  - `custom-x18-abi-toggle` was accepted ad-hoc but had no effect in the spike.
- **W^X flipping may thrash or livelock** when FEX JITs on several threads, or on 16K pages mixing code and data. Whether MAP_JIT toggling from a signal handler works is UNKNOWN.
- **The spike crash's root cause is unconfirmed** (§5), and the estimates below depend on it.
- **16K vs 4K pages:** guard pages, `GetWriteWatch`, FEX's code-change tracking and its call-return-stack guard are all imprecise.
- **KUSER under FEX:** which load instructions FEX generates for these reads is INFERRED, and each read costs a signal until FEX rewrites them at translation time.
- **No hardware TSO without the entitlement,** so FEX is slower. W6 is needed for FEX to use LSE and LRCPC (INFERRED).
- **Mixed toolchain** until `--with-mingw=llvm-mingw` is in the configure line.
- **Upstream churn** is low, because no dispatcher patches are ported. If !11638 or an equivalent lands, W1 and W2 need reconciling.
- **i386:**
  - The 4 GB pagezero leaves no address space below 4 GB.
  - That needs the guest-window series (about +1500 Wine lines) plus its FEX counterparts.
  - Low-base x64 images without relocations also fail until Madeira-style placement exists.
- **Product parity:** no msync (performance), and no DXMT presentation until the winemac shim exists.

**Effort (ESTIMATE, one engineer, including debugging):**

| Milestone | Estimate | Basis |
|---|---|---|
| Build + wineboot (W1-W4) | 2-4 days | Small patches; W3 and W4 apply cleanly, W2 has one trivial hunk (VERIFIED); unknown failures may follow W^X |
| Native ARM64 PE hello | +1-2 days | The same design already ran in the spike on 11.10 |
| x64 hello under FEX (W5-W7, FEX build, debugging) | +1-3 weeks | Depends on the crash's root cause; the low end assumes step 0 makes it disappear |
| W8 + MAP_JIT phase 2 | +1 week | |
| i386 (later) | 4-8 weeks | |

## 7. Durable build layout

Mirror `dxmt/`, which has `build.sh`, `check.sh`, `pins`, `lib.sh` and `toolchain.sh` (VERIFIED in the repo).

```
wine-arm64/                       committed
  pins                            WINE_REPO=https://gitlab.winehq.org/wine/wine.git
                                  WINE_COMMIT=455e3509b98a6919fd4ad1def4803e08c41c03b2   # wine-11.19
                                  FEX_REPO=https://github.com/FEX-Emu/FEX.git
                                  FEX_COMMIT=4ed80fd07176dce976a7351f559d59a47b68cbae   # upstream main, 2026-08-26
                                  (llvm-mingw: reuse dxmt/pins LLVM_MINGW_* via dxmt/toolchain.sh; no second pin)
  build.sh                        clone at pins → git am patches → autoreconf → configure (spike recipe +
                                  --with-mingw=llvm-mingw) → make → check the loader with otool -l
                                  (minos/sdk 12.0, __PAGEZERO 4 GB) → codesign with wine.entitlements → build FEX →
                                  stage build/wine-arm64/ → stamp = hash(pins + patches)
  check.sh                        wine --version; wineboot -i; arm64 hello; x64 hello; FEX DLL import/TLS check
  wine.entitlements               allow-jit, allow-unsigned-executable-memory, disable-library-validation
                                  (get-task-allow only in a dev variant)
  patches/wine/0001-*.patch …     git format-patch output (W1-W8, one commit per row; W2 = 60aeddb736+0853f419ce squashed;
                                  W4 = 4a50ce17c8 verbatim; debug patches in patches/wine-debug/)
  patches/fex/0001-*.patch …      4efc3abc8a, -lrt fix, fdf361f0e, ceabf254a
  tests/hello-arm64.c, hello-x64.c
build/wine-arm64-src/{wine,fex}   clones; dev branch `macneutron-11.19` = wine-11.19 + git am
build/wine-arm64/                 staged runtime + version stamp
```

**The patch files in the repo are the source of truth, not a branch:**
- Pushing and forking aren't allowed for now.
- Patches can be reviewed and diffed in this repo's history.
- With the pinned upstream SHA, they serve as the LGPL source offer for shipped binaries.
- Moving to 11.20 means running `git am` on the new pin and fixing whatever fails.

**Development loop:**
1. Edit on the `macneutron-11.19` branch in `build/wine-arm64-src/wine`.
2. Export with `git format-patch wine-11.19.. -o wine-arm64/patches/wine`.

A public fork, like `chadouming/dxmt`, can mirror that branch later; that's the user's call. The patches directory stays the authoritative copy.

**Other build notes:**
- Reuse `fetch` from `dxmt/lib.sh`.
- The build needs `autoconf` (from Homebrew), bison and flex (already on the spike's PATH), and the molten-vk flags.
- Missing tools should fail fast, as in `dxmt/build.sh`.