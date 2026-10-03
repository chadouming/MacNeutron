wine-11.19 now runs as an entitled, 4K-page native arm64 process on this Mac. `wineboot -i` finished with rc=0 in about 5 s (12.7 s including waiting for wineserver to exit), all 18 Wine processes ran with 4K pages, and a native ARM64 hello world worked. It took six local patches; the 4K spawner and every workaround from the unentitled plan turned out to be unnecessary. It took about 10 builds and 20 runs, and no wine or wineserver processes are left running.

### Changes that were needed (branch `entitled`, exported to `patches/0001`–`0006`)

| # | Patch | Where (patched tree) | Size | Why it's needed | What failed without it |
|---|---|---|---|---|---|
| 1 | `configure: Link the aarch64 macOS loader without -segalign/-pagezero_size` | configure.ac:994 (new `aarch64)` case, only the `__info_plist` sectcreate kept); configure regenerated with autoreconf | +9 | The default 11.19 link flags (configure.ac:984) get the loader SIGKILLed | VERIFIED: the loader relinked with the old flags, bundled and signed exits 137 even with the entitlement |
| 2 | `ntdll: Reserve the soft pagezero of an entitled macOS arm64 loader` | virtual.c:3707-3725 in `virtual_init`, after `host_page_size` is set and before `mmap_init` | +20 | With the entitlement, the low region is a prot 0/0 reservation (0x1000 or 0x4000 up to just above 4 GB). Registering it with `mmap_add_reserved_area` makes `map_fixed_area` use plain MAP_FIXED there, the same way x86_64 handles its zerofill reserve. It also traces the lowest region. | VERIFIED: `err:virtual:virtual_alloc_first_thread_data wine: failed to map the shared user data: c0000018` (the KUSER page at 0x7ffe0000) |
| 3 | `ntdll: Exec the macOS arm64 loader with 4K pages` | loader.c:454-466 in `preloader_exec`: `posix_spawn(POSIX_SPAWN_SETEXEC)` plus `posix_spawnattr_set_4k_page_size_np`, falling back to `execv` | +12 | Every loader exec goes through here: the first process re-executing itself, and each new Windows process (process.c:418 fork → `exec_wineloader` → `loader_exec`) | Processes stay 16K. In 16K mode (run02) ntdll.dll fails with `failed to set 60000020 protection on ... section .text` (W^X on mixed code+data pages). |
| 4 | `ntdll: Enable the custom x18 ABI on macOS arm64 threads before running PE code` | signal_arm64.c:1627-1630 at the top of `init_syscall_frame`, plus the `<os/arch/arm64.h>` include. Guarded with `if (!os_custom_x18_abi_enabled())`. | +8 | `init_syscall_frame` runs on every Wine thread, main and new, right before PE code (through `signal_start_thread`, server.c:1771/1805) | VERIFIED by A/B: `virtual_setup_exception stack overflow 1088 bytes addr 0x6fffff9dec34` — PE code loses the TEB in x18 and faults recursively |
| 5 | `ntdll: Keep the exec_wineloader environment strings off the stack` | loader.c:495-497: `static char preloader_reserve[64], socket_env[64]` | +3/-1 | `putenv` keeps the pointer. On macOS arm64, `execve` fails with EFAULT for any environment string within ARG_MAX (0x100000) of the address-space ceiling 0x7ffffe000000, and the first thread's kernel stack is allocated at 0x7ffffdef0000-0x7ffffe000000. | VERIFIED: `Couldn't start services.exe: error 731` (child `_exit(1)`); instrumented `posix_spawn rc 14` / `execv errno 14`, caused by env[61]/[62] at 0x7ffffdfff8d0/0x7ffffdfff890 |
| 6 | citi94 4a50ce17c8 `ntdll: Handle macOS Apple Silicon W^X ...` (applied with `git am`, authorship kept) | virtual.c:1979-1990 (`mprotect_exec` downgrades RWX to RW), virtual.c:4775-4795 (`virtual_handle_fault` flips the page RX↔RW) | +31 | Writable-and-executable (RWX) memory, now caused by executable heaps rather than the 16K mixed pages the commit message describes | VERIFIED: in winedevice.exe, `HeapCreate(HEAP_CREATE_ENABLE_EXECUTE)` (ntoskrnl.c:5108) gives `allocate_region Could not commit 0x10000 bytes, status 0xc0000022`. That leaves a NULL heap and a page fault at 0x8A0 in `RtlAllocateHeap` (heap.c:2051); winedbg starts and wineboot hits the 180 s cap. |

Notes on these:
- **Patch 5 doesn't depend on the entitlement (VERIFIED).** `xtest/xthr.c` reproduces the EFAULT in a plain unsigned 16K process; the first working distance below the ceiling is exactly 0x100000. The alternative fix is moving the top-down reserve (virtual.c `mmap_init`, 0x7ffff0000000-0x7ffffe000000) down by 1 MB. My guess is that x86_64 doesn't hit this because its address ceiling is higher (INFERRED).
- **One gap in patch 5's story.** The very first spawn, from the first process to wineboot, succeeded anyway; I didn't investigate why.
- **Patch 2 is used instead of CrossOver's `free_pagezero`** (deallocating the pagezero). Keeping the region reserved stops malloc and system frameworks from landing in the low 4 GB.

### Bundle layout (no Wine patch needed)
- **`wine.app/Contents/`:** `MacOS/wine` (a copy of the linked loader), `MacOS/ntdll.so` as a symlink to `../../../build/dlls/ntdll/ntdll.so`, `Info.plist` with id `net.authspot.macneutron.wine`, and `embedded.provisionprofile` (copied from `~/Downloads`; the original is untouched).
- **Why the `ntdll.so` symlink works:** loader/main.c:149-158 takes the real path of the executable and loads `<dir>/ntdll.so`.
- **Why new processes run the bundle:** ntdll takes the real path of `ntdll.so` to find `build_dir` (loader.c:387-392) and execs `build_dir/loader/wine` for every new process. `mkbundle.sh` moves the linked binary to `build/loader/wine.unsigned` and turns `build/loader/wine` into a symlink to the bundle executable.
- **The kernel honours the entitlement through that symlink (VERIFIED):** every process traces `lowest region 0x1000-... prot 0/0`.
- **Signature check:** `codesign -d --entitlements - wine.app` shows all six entitlements, with `Identifier=net.authspot.macneutron.wine`, `flags=0x10000(runtime)` and `TeamIdentifier=49QMZXLR8S`. `build/loader/wine --version` printed `wine-11.19-1-ga164268` (run after patch 1).
- **Strict verify fails.** `codesign --verify --strict` reports "invalid destination for symbolic link in bundle", because the symlink points outside the bundle. Normal verify passes and the kernel accepts it, but notarization would not. A shipped build has to put `ntdll.so` and `lib/wine` inside the bundle.

### Commands (in `/Users/chad/Documents/MacProton/build/arm64/entitled`)
```
./build.sh       # configure once (exact recipe, out of tree in build/, source in wine/) + make -j16
./mkbundle.sh    # wine.app + codesign -f -s "Developer ID Application: Chad Cormier Roussel (49QMZXLR8S)" --options runtime --entitlements ent.plist wine.app + build/loader/wine symlink; rerun if make ever relinks loader/wine
codesign -d --entitlements - wine.app; build/loader/wine --version
rm -rf pfx; WINEDLLOVERRIDES="mscoree,mshtml=" WINEDEBUG=+process,+virtual ./run.sh wineboot-final wineboot -i
PATH=/Users/chad/Documents/MacProton/build/dxmt-src/llvm-mingw/bin:$PATH aarch64-w64-mingw32-clang -O1 -o hello/hello.exe hello/hello.c
./run.sh hello hello/hello.exe
```
`run.sh` caps each run at 180 s, waits up to 60 s for wineserver to exit, kills only `build/arm64/entitled` paths, and writes `logs/<name>.rc`. Without `WINEDLLOVERRIDES="mscoree,mshtml="`, wineboot reaches the 180 s cap at the Mono/Gecko install dialog (`SYSLINK_SetFont`). That is a dialog waiting for input, not a hang in Wine (INFERRED).

### Page size per process (VERIFIED, `logs/wineboot-final.log` + `.rc` = rc=0)
- **wineboot:** 18 × `host page size: 4k`, 0 × 16k. That is the first process, the 16 created processes (wineboot ×2, services ×2, rundll32 ×2, explorer ×2, winedevice ×4, iexplore, svchost, plugplay, winemenubuilder), and the syswow64 rundll32 attempt.
- **hello run:** 8 of 8 processes 4k (`logs/hello-virt.log`).
- **The original 16K process** re-executes itself before `virtual_init`, so it never maps anything.
- **wineserver** stays an unsigned 16K process.

### Output
- **wineboot -i:** rc=0. The remaining err/fixme lines are listed in the warnings section below.
- **hello.exe** (rc=0):
```
hello from ARM64 PE: machine 0xc
GetTickCount64 = 313557385 ms
GetSystemInfo: dwPageSize = 4096, granularity = 0x10000, min addr 0000000000010000
KUSER_SHARED_DATA @ 000000007FFE0000: TickCount.LowPart = 313557385, TickCountMultiplier = 0x1000000, NtMajor/Minor = 10.0, NtBuild = 19045
KUSER InterruptTime = 3135573855903 (100ns)
x18/TEB check over 5 threads x 20000 iterations with Sleep(0): 0 mismatches
RWX VirtualAlloc 00000000006F0000: first run 42, after rewrite 7
```

### Warnings and FIXMEs that look relevant
- **x18 breaks Apple's documented contract (INFERRED risk).** The SDK header (`os/arch/arm64.h`, roughly lines 78-96) says a thread with custom x18 enabled must not call macOS libraries, and signal handlers must switch it off first. Wine's unix side and its signal handlers do both, all the time. It works today (VERIFIED), but Apple could break it.
- **First process in an installed layout (INFERRED, untested).** The first process gets 4K here only because `pre_exec` returns 1 when `build_dir` is set (loader.c:1981-1988). In an installed layout it returns 0 (loader.c:1989-1993) and the first process would stay 16K. The untested one-line fix is `return getpagesize() != 0x1000;` in the `#else` branch.
- **4K on an unentitled target (INFERRED).** I didn't test what the 4K attribute does when the exec target lacks the entitlement; patch 3 falls back to `execv`.
- **Homebrew libraries don't load.** MoltenVK, FreeType and gnutls are opened by bare name (config.h:773 `SONAME_LIBMOLTENVK "libMoltenVK.dylib"`), and `/opt/homebrew/lib` isn't on the default search path. The hardened runtime strips `DYLD_*` variables: VERIFIED that `DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib` changed nothing. This matters for MoltenVK and DXMT; those libraries need to go in the bundle or be loaded by absolute path. The `DYLD_LIBRARY_PATH` that `pre_exec` sets (loader.c:1983-1986) is ignored too, which is harmless.
- **W^X flip cost (INFERRED).** Each RWX page takes a fault on every switch between writing and executing, which will be slow for JITs like FEX. MAP_JIT RWX works according to your probe.
- **`get_core_id_regs_arm64` stub** prints 18 times per process (system.c:2106-2109); the CPU-ID reader only exists for Linux.
- **wineserver rounds to 16K (INFERRED harmless).** It computes `host_page_mask` from its own 16K page size (server/mapping.c:226), so shared mappings are rounded up to 16K.
- **Probably unrelated to this platform (INFERRED):**
  - `syswow64\rundll32.exe: c0000135` — expected, since no i386 PE is built.
  - winebth driver fails to load with c00000e5.
  - In the two early explorer.exe processes, OLE marshalling fails with `E_NOINTERFACE` and RpcSs fails to start.
  - Seven auto-start services fail at teardown, mostly with 1115 (shutdown in progress).

### Not needed from the unentitled plan
- **KUSER relocation and KUSER fault emulation:** the real 0x7ffe0000 page maps and is readable (VERIFIED).
- **The ENOMEM fix:** no mapping failure ever occurred (VERIFIED by absence).
- **The old-SDK x18 link:** replaced by `os_set_custom_x18_abi_enabled` (0 mismatches).
- **CrossOver `free_pagezero`:** replaced by patch 2.
- **The external 4K spawner:** VERIFIED unnecessary in the build-tree layout.
- **A preloader.**
- **citi94 for its original 16K mixed-page reason:** 4K mode avoids that; the patch is still needed for RWX memory.

Everything is in `/Users/chad/Documents/MacProton/build/arm64/entitled/`:
- `patches/0001`–`0006`
- `wine/` (local commits on top of 455e350)
- `build/`, `wine.app/`, `ent.plist`
- `build.sh`, `mkbundle.sh`, `run.sh`
- `pfx/` (prefix after the final wineboot)
- `hello/`
- `xtest/` (`xtest.c`, `xtop.c`, `xthr.c`, signed `XTest.app`)
- `logs/` — the main ones are `wineboot-final`, `hello`, `hello-virt`, `run03`/`run04` (x18), `run13` (EFAULT), `run15` (the W^X crash) and `wineboot-dyld`.

The tracked repo is unchanged.