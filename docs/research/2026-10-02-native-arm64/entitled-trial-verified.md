# Skeptical verification of the entitled wine-11.19 trial (build/arm64/entitled)

**Verdict:** The main result holds up when re-run. The bundle is signed with the entitlement and every Windows process runs entitled with 4K pages. `wineboot` (`-i` on a fresh prefix, `-u` on a copy) returns rc=0, and the ARM64 hello works. Three claims are wrong:
- **"No processes are left running" is false.** I found 32 orphaned Wine processes from the trial and killed them.
- **Patch 3 has no fallback to `execv`.** When the target binary lacks the entitlement, the 4K spawn attribute makes the kernel SIGKILL the process. The fallback never runs.
- **The trial's own x18 test is weak.** A stronger test I wrote passes, so the conclusion stands, but the trial's evidence did not show it.

## Current state
- **Signature: CONFIRMED.** `codesign -dv wine.app` shows `Identifier=net.authspot.macneutron.wine`, `flags=0x10000(runtime)`, `TeamIdentifier=49QMZXLR8S`, the Developer ID authority chain, and all six entitlements. A normal `--verify` passes. `--verify --strict` fails with "invalid destination for symbolic link in bundle", as the report says.
- **Live processes are entitled, not ad-hoc: CONFIRMED (new evidence).** `codesign -dv` and `codesign -d --entitlements -` on 6 live process IDs show the Developer ID team, the runtime flag and `cross-architecture-support`. `wineserver` is `adhoc,linker-signed`.
- **Provisioning profile: CONFIRMED.** `embedded.provisionprofile` is byte-identical to `~/Downloads/Mac_Neutron.provisionprofile`. The original's modification time (22:29:59) is earlier than the bundle. The profile grants `cross-architecture-support` for `49QMZXLR8S.net.authspot.macneutron.wine`.
- **`wine --version`: CONFIRMED, with a newer string.** It now prints `wine-11.19-6-g40e0056`, which includes all six patches. The report quoted the string from after patch 1. The build is current: `ntdll.so` is newer than every patched source file.
- **Loader link: CONFIRMED.** `__PAGEZERO` is the default 4 GB, and only the `-sectcreate __info_plist` flag is kept.

## Patches marked "needed"
1. **configure.ac:994 (link flags): CONFIRMED, re-run.** I relinked `build/loader/main.o` with the original configure.ac:984 flags into `verify/Old.app` and signed it with the same identity and entitlements (`__PAGEZERO` vmsize 0x1000). It exits 137. The current bundle exits 0.
2. **virtual.c:3708-3726 (soft pagezero reserve): CONFIRMED.**
   - The failure without it is in trial log `run01`: `failed to map the shared user data: c0000018`. I did not re-run that.
   - The mechanism checks out: `map_fixed_area` (virtual.c:2194-2226) uses `anon_mmap_fixed` inside reserved areas.
   - All 18 + 15 + 8 + 8 traced processes start at `lowest region 0x1000-...`, which only an entitled 4K process shows. `run02` (entitled, 16K) shows `0x4000-`.
   - From PE code, `VirtualAlloc(0x40000000)` succeeds.
3. **loader.c:455-466 (4K exec): needed for 4K pages, CONFIRMED. Fallback: REFUTED. Whether it's needed to boot: UNVERIFIED.**
   - The `run02` 16K failure (`failed to set 60000020 protection ... .text`) is in the trial log. But `run02` came before patch 6, and that failure is exactly the mixed-page W^X case patch 6 handles. So 4K is needed for the design goal; whether 16K plus patch 6 would boot is untested.
   - The comment at loader.c:457-458 and the report's "falls back to `execv`" are wrong. I re-ran `xtest/xtest` (unentitled, ad-hoc):
     - Same-process exec with 4K (mode 2): exits 137.
     - Fork, then exec with 4K (mode 0): the child disappears silently, printing neither its own line nor "SETEXEC failed".
     - Control without the 4K attribute (mode 6): runs to depth 4.
   - So a `build/loader/wine` that is unentitled (for example, relinked by `make` without re-running `mkbundle.sh`) kills every launch with 137 and no message. It does not fall back to 16K. A `posix_spawn` failure would also go unlogged.
4. **signal_arm64.c:1627-1630 (custom x18): CONFIRMED.**
   - Trial logs `run03`/`run04` show `stack overflow 1088 bytes addr 0x6fffff9dec34`; `run05` has none. That with/without pairing is inferred from timestamps (runs at 22:44:28/40/56, commit at 22:45:08), not from labels.
   - The trial's hello test is weak for two reasons:
     - It calls `Sleep(0)` every 64 iterations, and the syscall dispatcher reloads x18 from the frame (signal_arm64.c:1827), so it mostly tests the syscall path.
     - `GetCurrentThreadId()` reads the same x18-derived TEB it is compared against, so a wrong but non-null x18 would go unnoticed.
   - My test, `verify/x18v.exe`, compares raw x18 with the TEB returned by `NtQueryInformationThread`, in a 3 s spin with no syscalls. It ran 72 threads (63 `CreateThread`, 8 thread-pool workers, and the main thread) on 18 CPUs: about 1.19e11 checks, 0 mismatches, 0 bad at start.
   - "Only some threads": every kind of thread that runs PE code goes through `signal_start_thread` → `init_syscall_frame` (server.c:1771/1805, signal_arm64.c:1723). The real main thread stays in `CFRunLoopRun`/`run_cocoa_app` (from a sample I took) and never enables custom x18. That is the right scope, not a gap.
5. **loader.c:495-497 (static env strings): CONFIRMED.**
   - Trial log `run13` shows `posix_spawn rc 14` and `execv errno 14` for `env[61]`/`env[62]` at 0x7ffffdfff8d0/0x7ffffdfff890. The "error 731" message is in `run05`–`run07`.
   - I re-ran `xtest/xthr` (ad-hoc, 16K): the first distance that works is 0x100000, which equals `getconf ARG_MAX` (1048576). So this doesn't depend on the entitlement.
   - Static buffers are safe here because the only caller is the grandchild after a double fork (process.c:444).
   - The first-spawn gap the report mentions is UNVERIFIED.
6. **citi94 W^X patch (virtual.c:1979-1990, 4775-4795): CONFIRMED.**
   - Trial log `run15` shows `allocate_region Could not commit 0x10000 bytes, status 0xc0000022`, then `Unhandled page fault on read access to 00000000000008A0`, then winedbg starting. The source line heap.c:2051 is UNVERIFIED; the log shows only the address.
   - I re-ran the probe: plain RWX `mmap` fails with EACCES even with `allow-unsigned-executable-memory`, in both 16K and 4K. `MAP_JIT` works.
   - My hello run shows `degrading w^x protection` at 0x6f0000 and 0x710000. The result 42/7 matches the report.

## Runs and page size (all CONFIRMED)
| Run | Result | Time | Processes traced | 4K pages | Lowest region 0x1000 | 16K |
|---|---|---|---|---|---|---|
| Fresh prefix, `wineboot -i` (with overrides) | rc=0 | 4 s run + 8 s drain | 18 (16 created + first + syswow64 attempt) | 18 | 18 | 0 |
| Copied prefix, `wineboot -u` (with overrides) | rc=0 | 4 s + 4 s | 15 | 15 | 15 | 0 |
| `hello.exe` | rc=0 | — | 8 | 8 | 8 | 0 |
| `x18v.exe` | rc=0 | — | 8 | 8 | 8 | 0 |

- `hello.exe` prints the same output as in the report.
- **Copied prefix without `WINEDLLOVERRIDES`:** hits the 180 s cap. `control.exe appwiz.cpl install_mono` runs, then `SYSLINK_SetFont`. The "dialog waiting for input" explanation stays INFERRED; I didn't inspect any window.
- **How to read page size: vmmap's header is misleading.** `vmmap` prints `VM page size: 16384` for every target, including processes traced as 4K. Region boundaries are the reliable signal:
  - 6 live Wine processes: 120–242 private regions each that aren't 16K-aligned (for example `140001000-140003000`).
  - `wineserver`: 0 of 34.
- **Low 4 GB:** no malloc or framework regions there in a live process. That fits the report's reasoning for preferring patch 2 over `free_pagezero`, but doesn't prove `free_pagezero` would let them in.

## Warnings and other claims
- **Homebrew libraries: CONFIRMED (re-ran).** With `DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib`, FreeType still fails 4 times, though the libraries exist there. MoltenVK and gnutls fail the same way. A third option, not tested: the `com.apple.security.cs.allow-dyld-environment-variables` entitlement.
- **Hidden warnings:** `WINEDEBUG=warn+all` on hello shows nothing about virtual memory, heap, exceptions or signals. Only HID, RPC and file noise.
- **`get_core_id_regs_arm64` (system.c:2106-2109): CONFIRMED, with a correction.** It prints 18 times because there are 18 logical CPUs. It only appears in processes that build the SMBIOS table (2 of 18 in `wineboot`), not in every process.
- **Errors the report didn't list:** the fresh run also had `RpcServerAssoc_FindContextHandle` and fault `0x1c00001a`, plus `MountMgr` failing with 1053. All are teardown noise (INFERRED).
- **Apple's x18 contract: CONFIRMED** (header lines 78-96). One correction: for signal handlers, the header says to avoid macOS code or wrap those calls with the switch, not "switch it off first".
- **wineserver: unsigned and 16K, CONFIRMED.** Rounding to 16K at server/mapping.c:226 is confirmed in code; that it's harmless is INFERRED.
- **Installed layout keeps the first process at 16K: CONFIRMED in code.** In the patched tree, `pre_exec` is at loader.c:1993-2008: the `build_dir` branch is 1995-2002, `return 0` is at 2005-2007, `DYLD_LIBRARY_PATH` is set at 1997-2000. `reexec_loader` returns early at loader.c:2029 because the loader exports `wine_main_preload_info` (checked with `nm`). The report's line numbers come from the unpatched tree.
- **The proposed fix `return getpagesize() != 0x1000;` needs more.** It would re-exec an unentitled install straight into a SIGKILL. It also has to check that the entitlement is present (for example `os_cross_arch_is_supported()`) and log an error when the spawn fails.
- **Other line numbers:** `process.c:418` is the first `fork`; `exec_wineloader` is called at process.c:444. All other citations I checked are correct.

## REFUTED: "no wine or wineserver processes are left running"
At the start there were 32 orphaned processes: `wineboot`, `services`, `explorer`, `winedevice`, `rundll32`, `svchost`, `plugplay` and `control.exe install_mono`. All had parent ID 1 and were running `entitled/wine.app/Contents/MacOS/wine`. They started between 22:48 and 23:05 and came from runs that failed or timed out. There is no `run12.log` for the pair that started at 22:48:34. None came from `wineboot-final` or `hello`.

The cause is in run.sh:11-12. `pkill -f build/arm64/entitled/...` can't match Wine clients, because Wine overwrites their command line with the Windows one (`C:\windows\system32\...`). So only `wineserver` was killed. Without the server, clients block forever in `read(wait_fd[0])` (server.c:357), because each client still holds its own `wait_fd[1]` (server.c:1572/1684/1794).

The fix is `wineserver -k`, or killing by executable path with `lsof -t <binary>`. I killed all 32 by PID after checking their executable path. My runner, `verify/vrun.sh`, does the same.

**Not checked:** "about 10 builds and 20 runs".

## Corrected summary
wine-11.19 with six patches runs as an entitled, hardened-runtime, Developer ID-signed arm64 process. All six patches are needed:
- Patch 1 (re-run: 137 without it).
- Patch 2 (trial log).
- Patch 3, for 4K pages. Whether 16K would boot with patch 6 is untested.
- Patch 4 (trial logs, plus my 72-thread test).
- Patch 5 (trial log, plus the `xthr` re-run).
- Patch 6 (trial log, plus the probe re-run).

In the build tree, every Windows process gets 4K pages, the low 4 GB and KUSER at 0x7ffe0000 are usable, and x18 survives preemption in every thread that runs PE code. `wineboot -i` takes about 4 s plus about 8 s draining wineserver, and hello works.

Corrections to the report:
- **Process cleanup:** the trial's runner left 32 orphans because Wine rewrites argv; they are now killed.
- **No graceful fallback:** patch 3 gives none. An unentitled loader is SIGKILLed when it re-execs, so `mkbundle.sh` must run after every relink of `loader/wine`. Any installed-layout re-exec fix must also check that the entitlement is present.
- **x18 test:** the trial's test was weak; my stronger one passes.
- **vmmap:** its "VM page size" line can't show 4K pages; use region boundaries.

Also still true: shipping needs `ntdll.so`, `lib/wine` and the Homebrew libraries inside the bundle (strict verify fails, and `DYLD_*` is ignored). Running with custom x18 on while calling macOS code breaks Apple's documented rules: it works today, but Apple could break it.

**Cleanup:** `lsof -t` on the bundle binary, `verify/Old.app`, `wineserver` and `xtest` returns nothing, and `pgrep` finds no Windows or `wineserver` processes. The tracked repo is unchanged.

These leftovers are safe to delete: `verify/pfx-copy` and `verify/pfx-fresh` (1.2 GB each), and `verify/Old.app` (a second signed bundle with the same ID that is SIGKILLed on launch).

Files are in /Users/chad/Documents/MacProton/build/arm64/entitled/verify:
- vrun.sh
- x18v.c
- x18v.exe
- logs/wbi-fresh.log
- logs/wbu-copy.log
- logs/wbu-copy2.log
- logs/hello-default.log
- logs/hello-virt.log
- logs/hello-warn.log
- logs/hello-dyld.log
- logs/x18v-sleep.log