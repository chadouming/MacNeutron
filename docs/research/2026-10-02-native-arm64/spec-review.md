## facts
Of the 11 findings, 10 survive: 9 confirmed with my own evidence and 1 (finding 9) downgraded to plausible. Two of the four minor misquotes in finding 11 are dropped as nits. I found two new problems while checking. Nothing was edited and Wine was not run. The only new files are a test program and a probe binary in `scratchpad/skeptic2/`.

**1. CONFIRMED. §6.2 / §3.4: a mapped section view never gets the ARM64EC code mark**
- **FEX side:** at `4ed80fd`, `AllocatorHooks.h:49-61` passes `MEM_EXTENDED_PARAMETER_EC_CODE` on every executable `VirtualAlloc`.
  - The main JIT buffer is `SharedCodeBufferManager.cpp:21`. The original finding missed it, and it is the one §6.2's dual view replaces.
  - Other executable allocations: `Dispatcher.cpp:40` and `CodeCache.cpp:617/863`.
  - Strike `atomic_segmented_bitmap_allocator.h:63`: `git grep` shows it is used only in `unittests/APITests/AtomicBitmapAllocator.cpp`.
- **Wine side:** `virtual.c:5260-5263` marks EC code only inside `allocate_virtual_memory`. `NtMapViewOfSectionEx` (`:6433-6520`) parses `attributes` but never passes it on: `virtual_map_section(..., protect, machine)` has no attribute argument.
- **Consequence (PLAUSIBLE):** JIT PCs would be classed as x64 code by the `RtlIsEcCode` checks in `unwind.c:267/2070/2254/2330` and `signal_arm64ec.c:1416/1500/1648/1762`.
- **The Wine patch is the right fix, not a workaround.** FEX's own `ImageTracker.cpp:253-257` has a commented-out `NtMapViewOfSectionEx` call with `EC_CODE`, which shows Windows accepts the attribute on a mapped view.
- **The re-commit alternative is reachable by reading the code, but untested.** A pagefile-backed view is `SEC_COMMIT` without `SEC_FILE` (`server/mapping.c:1055-1056`), so a `MEM_COMMIT` on it doesn't stop at `:5245`.
- **New sub-point:** `Module.cpp:629` uses a plain `::VirtualAlloc` with no EC attribute. It holds one x64 byte (`0xc3`) and the host never executes it. So §6.2's "written once … through patch 6's flip" describes a flip that never happens on that page.
- **Fix:** keep the original fix. List `SharedCodeBufferManager`, `Dispatcher` and `CodeCache` as the buffers G5 counts.

**2. CONFIRMED. §5.2 patch 10: reading CTR_EL0 kills the process, and `hw.cpufamily` is not a MIDR**
- I compiled a fresh test (`skeptic2/ctr2.c`) and `mrs ctr_el0` exited with code 132 (SIGILL). `dczid_el0` reads 0x4 and FPCR bits 0-2 go from 0 to 0x7.
- The read would sit in the SMBIOS builder, and `wineboot.c:792` calls `GetSystemFirmwareTable(RSMB)`, so `wineboot` crashes.
- `hw.cpufamily` is -143893734, which is 0xF76C5B1A. `system.c:703` already uses implementer 0x61 on Apple.
- **Caveat on the fix:** `hw.cachelinesize` is 128 here. Building CTR from it tells FEX 128-byte lines; leaving CP 5801 out makes FEX assume 64 (`HostFeatures.cpp:545-550`). Under Wine, FEX uses only `DCacheLineLog2` from CTR, because `SupportsCacheMaintenanceOps = !IsWine`. The spec should pick one. Omitting CP 5801 is the safer choice.

**3. CONFIRMED. §5.2 patch 7 / §9 / §3.1: the 16K fallback can't run, and `os_cross_arch_is_supported` doesn't test the entitlement**
- I rebuilt `xarch/probe.c` without the entitlement (ad-hoc, linker-signed). It printed:
  - `os_cross_arch_is_supported=1`;
  - ENOMEM at 0x10000, 0x7ffe0000 and 0xfff00000;
  - x18 lost 200/200;
  - `posix_spawn 4K child: 88`.
- The SDK header `os/arch/arm64.h` says the value is "constant for the lifetime of the system".
- `w1119-brief.md:124` shows the boot failure without the entitlement: `map_fixed_area out of memory for 0x7ffe0000`.
- `ent-trial.md:25-26`: with `SETEXEC`, a 4K spawn gives 137 or a silent child death, never errno 88.
- **Fix:** keep the original: a fatal `err:` line, require `SecTaskCopyValueForEntitlement`, and mark errno 88 in §3.1 as the non-`SETEXEC` case.

**4. CONFIRMED. §3.3 patch 3 row: the failure listed belongs to patch 6's case**
- `ent-trial.md:23`: the `failed to set 60000020 protection` line came from `run02`, which predates patch 6. Whether 16K with patch 6 boots is untested.
- **Fix:** as in the original finding.

**5. CONFIRMED. §3.5: a single-threaded benchmark still pays FEX's software TSO cost**
- `Context.h:460-470` turns software TSO on based only on `SupportsHardwareTSO` and `Config.TSOEnabled` (default true, `Config.json.in:467-469`).
- `git grep` finds no thread-count condition anywhere in FEX at the pin. `TSOHandlerConfig.h:20` is the only place it tries hardware TSO.
- Whether CrossOver's FEX build had hardware TSO is still unknown.
- **Fix:** as in the original finding.

**6. CONFIRMED. §5.2 patch 10: Wine doesn't already read most of the sysctls FEX needs**
- Running `grep -o '"FEAT_…"'` on `system.c` finds LSE, LSE2 and LRCPC. It finds none of AFP, LRCPC2, FlagM, FlagM2, SHA1, SHA256, PMULL, FRINTTS, RPRES or ECV. All of these are 1 on this Mac.
- `HostFeatures.cpp:360/496`: LRCPC2 sets FEX's `SupportsTSOImm9`.
- **Fix:** as in the original finding. Add LRCPC2 to G3's pass list.

**7. CONFIRMED. §7.3 step 2: "overrides off" can be read two ways**
- `ent-rawTrial.md:36`: without `WINEDLLOVERRIDES="mscoree,mshtml="`, wineboot waits at the Mono/Gecko dialog until the 180 s cap.
- **Fix:** write out that exact variable.

**8. CONFIRMED, with stronger evidence. §2 sub-project 2: the reason given for the DXMT presentation failure is wrong**
- `grep macdrv_functions` finds nothing in `wine-11.19/dlls/winemac.drv`. The only hit under `build/arm64` is `crossover/diffs/cx-full.diff`.
- `nm -gU` on the trial's `winemac.so` lists 2 exported symbols in total. `get_win_data`, `release_win_data` and the `macdrv_view_*` functions are not among them, so DXMT's fallback lookups at `winemetal_unix.c:1719-1722` fail.
- **Fix:** keep the original wording fix, and note that the shim table needs default visibility.

**9. PLAUSIBLE (downgraded). §4: "no Wine patch is needed" is untested, but the claim that it limits the layout is too strong**
- These parts are right:
  - The loader loads `<realpath dir of exe>/ntdll.so` (`loader/main.c:149-158`).
  - If `ntdll.so` is a real file in `Contents/MacOS`, `init_paths` sets `dll_dir = Contents/MacOS`. The default `../../bin` relative path then puts `bin_dir` and `data_dir` outside `Contents` (`dlls/ntdll/unix/loader.c:397-400`).
  - The trial's `ntdll.so` is a symlink pointing outside the bundle, and strict verify fails on it (`ent-rawTrial.md:25`).
- **Where it overreaches:** `init_paths` calls `realpath_dirname(dli_fname)`, which resolves symlinks. So this layout keeps everything inside `Contents` with default `--prefix`-relative paths and no patch:
  - the install tree under `Contents/{bin,lib,share}`;
  - `Contents/MacOS/ntdll.so` as a symlink to `../lib/wine/aarch64-unix/ntdll.so`;
  - `Contents/lib/wine/aarch64-unix/wine` as a symlink to `../../../MacOS/wine`, which is what `wineloader` resolves to.
- The trial showed the kernel honours the entitlement through such a symlink. No one has tested whether `codesign --strict` accepts these in-bundle links.
- **Fix:** mark the claim untested and name this layout in §4.

**10. CONFIRMED. §3.6: the "at most" figure isn't the upper bound**
- `synthesis.md:335` used 150 cycles. 15k × 8 × 200 ÷ 4 GHz = 6.0 ms.
- **Fix:** as in the original finding.

**11a. CONFIRMED. §5.4: autoconf is not keg-only**
- `brew info --json` shows autoconf `keg_only=False`; bison and flex are `True`.
- The trial's `build.sh:5` puts only bison and flex on `PATH`.

**11b. CONFIRMED. §5.3: the shared-cache scan covered 4,086 of 4,088 images**
- `ent-x18.md:77`: the two skipped are iOSSupport bundles with spaces in their paths. The per-beta rerun should cover them.

**Dropped:**
- **11c, patch 6 authorship:** the original `4a50ce17c8` in the citi94 tree is itself authored by `vcds-on-mac`, with the same trailer. The patch keeps that authorship, and "citi94's" names the tree. Style nit.
- **11d, wineserver "unsigned":** it is `adhoc,linker-signed`, which I confirmed with `codesign -dv`. Every arm64 Mach-O is at least ad-hoc signed, and §7.2's `bundle.sh` re-signs it anyway, so no decision changes. Nit.

**New findings:**
- **N1. §6.2 doesn't name FEX's real code buffer.** The JIT buffer is `SharedCodeBufferManager.cpp:21`: 16 MB at first, up to 128 MB, with its last page set to no access as a guard. The dual-view port has to replace this allocation and keep the guard page on the write view. Without naming it, G5's "FEX code-buffer pages" is not well defined.
- **N2. §6.2's `Module.cpp:629` example is wrong.** That page holds x64 code that the host never executes, so it never flips. §6.2's "few other RWX allocations" should list `Dispatcher.cpp:40` instead: host code written once at startup, carrying the EC attribute, and today going through patch 6's flip. G5 should say whether dispatcher pages count.

Files are in /private/tmp/claude-501/-Users-chad-Documents-MacProton/4df1af36-0116-433f-917f-5078e899b9af/scratchpad/skeptic2/:
- ctr2.c
- ctr2
- probe_unsigned
- HostFeatures.cpp

## consistency
**Skeptic pass on the consistency findings for the native arm64 spec**

All 17 findings survive. Four sub-claims are refuted or corrected (listed at the end), and none of them changes the ranking. I found one new candidate while checking and dropped it, because FEX already handles it. "spec:N" means line N of `/Users/chad/Documents/MacProton/docs/superpowers/specs/2026-10-02-macneutron-native-arm64-design.md`.

### 1. CONFIRMED: the bundle layout decides which binary every child process runs (blocks the plan)
- **Sections:** §4 (spec:171-176), §7.2 (spec:297-299)
- **Quote:** "The exact directory layout is the plan's choice …"
- **Problem:**
  - In an installed layout, `init_paths` sets these paths:
    - `wineloader = <realpath dir of ntdll.so>/wine`
    - `dll_dir = ntdll_dir` minus `/aarch64-unix`
    - `bin_dir` and `data_dir`, built relative to `dll_dir` from configure-time `LIBDIR`, `BINDIR` and `DATADIR`
  - `make install` puts a second copy of the loader at `$(libdir)/wine/aarch64-unix/wine`. Under §7.2 step 1 that copy is signed without entitlements. Every child process and the patch-8 re-exec go through `loader_exec` → `wineloader`, so they would run that copy and be SIGKILLed with no message.
  - Four things float on "the plan's choice": the exec target, wineserver, `wine.inf`, and the `aarch64-windows` PE directory.
- **Evidence:**
  - `wine-11.19/dlls/ntdll/unix/loader.c:383-400` (`init_paths`), `:470-481` (`loader_exec`), `:505-524` (`exec_wineserver` falls back to `$WINESERVER`, then `$PATH`, then `BINDIR`).
  - `build/arm64/entitled/build/Makefile:286119`: `-t $(DESTDIR)$(libdir)/wine/aarch64-unix loader/wine`.
  - ent-rawTrial.md:22: the trial worked only because `build/loader/wine` was a symlink to the bundle executable.
- **Correction to the suggested fix:** do not put `ntdll.so` physically beside `Contents/MacOS/wine`.
  - Then `remove_tail` fails and `dll_dir` becomes `Contents/MacOS`.
  - `bin_dir` becomes `Contents/MacOS/../../bin`, which is `wine.app/bin`, outside `Contents/`.
  - The roughly 600 PE DLLs would have to live under `Contents/MacOS/aarch64-windows`.
- **Fix:**
  - Mirror the `make install` relative tree under `Contents/Resources`.
  - Make `Contents/MacOS/ntdll.so` an in-bundle symlink to `Resources/lib/wine/aarch64-unix/ntdll.so`.
  - Replace the installed `Resources/lib/wine/aarch64-unix/wine` with a symlink to `../../../../MacOS/wine`. The trial verified that the kernel honours the entitlement through a symlink.
  - Have `bundle.sh` assert that `realpath(<ntdll dir>/wine)` is `Contents/MacOS/wine`, and that `bin_dir/wineserver` and `data_dir/wine.inf` resolve inside `Contents/`.

### 2. CONFIRMED: patch 7's 16K fallback isn't a working mode, and the suggested check is the wrong one
- **Sections:** spec:198, :286, :354
- **Problem:**
  - **(a) The fallback still dies.** An unentitled loader keeps the hard 4 GB page zero. Patch 2 registers a reservation only when `addr && addr < 0x100000000 && !info.max_protection`, so nothing is registered and KUSER fails with `map_fixed_area out of memory for 0x7ffe0000`. The process dies at KUSER instead of being SIGKILLed. That also contradicts §7.1's "killed at its first 4K re-exec".
  - **(b) Wrong check.** ent-trial.md:69 proposes `os_cross_arch_is_supported()` as the entitlement check. It reports a system capability, not this process's entitlement.
  - **(c) Self or target?** The spec doesn't say whether patch 7 checks itself or the exec target. They differ under finding 1.
- **Evidence:**
  - I compiled a 3-line ad-hoc, unentitled binary in `scratchpad/skeptic-cons/xa`. It printed `os_cross_arch_is_supported=1` (rc=0).
  - SDK `os/arch/arm64.h`: "only reports whether the underlying kernel features … are present"; "constant for the lifetime of the system".
  - `patches/0002`: the guard condition above.
  - w1119-brief.md:124: the unentitled failure at 0x7ffe0000.
  - ent-trial.md:24-28: an unentitled 4K `SETEXEC` exits with 137.
- **Fix:**
  - Use `SecTaskCopyValueForEntitlement` on self, plus `realpath(wineloader) == realpath(self)`.
  - On failure, call `fatal_error` with a clear message. Drop the 16K mode and "or an equivalent check".
  - Rewrite spec:354 and spec:286 to match.

### 3. G2 can't be run as written
- **Section:** spec:333
- **CONFIRMED:**
  - **Pinning is a no-op.** `wine-11.19/server/thread.c:740-759` calls `sched_setaffinity` only `#ifdef HAVE_SCHED_SETAFFINITY`. The trial's `config.h:365` has `/* #undef HAVE_SCHED_SETAFFINITY */`.
  - **"FEX's default" is four settings.** At FEX 4ed80fd (`git show HEAD:FEXCore/Source/Interface/Config/Config.json.in`): `TSOEnabled=true`, `HalfBarrierTSOEnabled=true`, `VectorTSOEnabled=false`, `MemcpySetTSOEnabled=false`. So G2 covers scalar accesses only.
  - **"TSO turned off" names no setting.** FEX reads `FEX_*` variables (`Source/Common/Config.cpp:291-295,523`; ARM64EC `Module.cpp:588`), so the control can be named exactly.
- **PLAUSIBLE:** read per pattern, the control could fail for LB or IRIW, which have never been observed on Apple cores here. Message passing will show violations: the unpinned probe in §3.1 saw about 41%.
- **Fix:**
  - Drop "pinned".
  - Default = no `FEX_*` variables; control = `FEX_TSOENABLED=0`.
  - The control passes on ≥ 1 message-passing violation. Other patterns are reported, not gated.
  - Say G2 is scalar-only.

### 4. G4's cutover criteria disagree
- **CONFIRMED (a), two cutover criteria:**
  - Per game: the decisions table (spec:40, "≤ ~1.4×") and roadmap row 9 (spec:62, "parity set").
  - Stack-wide microbenchmark geomean: spec:32 and spec:342 ("cutover (sub-project 9) waits").
- **PLAUSIBLE (b):**
  - With 38 rows, 6 of them multithreaded, all six at 2× gives a geomean of 2^(6/38) ≈ 1.12; at 3× it is ≈ 1.19.
  - So the geomean can't reflect §11's "the multithreaded rows decide" (spec:370). §11 may mean games rather than the geomean; the arithmetic holds either way.
- **CONFIRMED (d), opposite ratio directions:** fex-vs-rosetta.md:7 says "Ratio = FEX/Rosetta throughput, so >1 = FEX faster". G4 is a time ratio, so above 1 means FEX is slower.
- **Fix:**
  - Say sub-project 9 decides per game from game measurements.
  - Report single-threaded and multithreaded geomeans separately.
  - Label the direction in §3.5.

### 5. CONFIRMED (with a correction): G4's Rosetta baseline is underspecified
- **Section:** spec:335
- **Problem:**
  - FEX always advertises AVX: `Source/Common/HostFeatures.cpp:540` has `HostFeatures.SupportsAVX = true;` with no condition. The original finding's "default off, meaning detect" is wrong. The `HostFeatures` setting is only an override.
  - Rosetta advertises AVX only with `ROSETTA_ADVERTISE_AVX=1`, which the launcher sets (`Sources/MacNeutronCore/LaunchEnvironment.swift:14-18`, along with `WINEMSYNC=1`).
  - The gist's AVX2/FMA rows are guarded by cpuid (fex-vs-rosetta.md:51). If the Rosetta run calls the runtime's `wine` directly, those rows take a different path.
  - Precedent: `dxmt/check.sh:11,37-40` runs the installed tool folder (any version) through `macneutron launch`.
  - The spec also leaves open:
    - which runtime copy is the baseline (`RuntimePin` runtime-v4.7.3, `RuntimeInstaller.swift:12-15`, or whatever is installed);
    - which prefix the Rosetta run uses;
    - what "5 runs" means;
    - whether G4 runs before G5.
- **Fix:**
  - Run the Rosetta side through `macneutron launch`, with `MACNEUTRON_TOOL` set to a verified runtime-v4.7.3.
  - Use the same .exe on both sides, 5 separate processes, and record cpuid per side.
  - Run G4 only after G5.

### 6. CONFIRMED (one sub-claim refuted): G5 can't be measured as written
- **Section:** spec:336
- **Problem:**
  - No patch in §5.2 adds the counter.
  - Both flip branches in `patches/0006` are guarded by `is_vprot_exec_write(vprot)` and have no TRACE.
  - Dual-view RW and RX pages can't flip, so "0 on code-buffer pages" is true by construction.
  - ntdll can't tell which pages are FEX's. Today FEX's code buffers come from `FEXCore/include/FEXCore/Utils/AllocatorHooks.h:58,61` as `VirtualAlloc(..., PAGE_EXECUTE_READWRITE)`, which is exactly the path that flips if the port misses one.
- **Refuted sub-claim:** "the return stub flips". `Module.cpp:629-632` writes `0xc3`, an x64 `ret` that FEX translates. The host never executes that page, so it never flips.
- **Fix:**
  - Add a TRACE to both flip branches in patch 6.
  - Gate G5 on the total number of flips in the `x64-bench` process: zero, or not growing between a one-iteration run and the full run.

### 7. CONFIRMED (lower severity): G3's log prints nothing by default
- **Section:** spec:334, spec:256
- **Problem:**
  - `Source/Windows/Common/Logging.cpp:36-40`: `Init()` returns before installing any handler when `SilentLog` is set, and it defaults to true. Even a patched log line prints nothing without `FEX_SILENTLOG=0`.
  - The spec's "if FEX has no such log" is already answered: there is none. The only feature message is the negative `WARN_ONCE` at `HostFeatures.cpp:553`, printed when LSE is missing.
- **Fix:** gate G3 on the registry values patch 10 writes, decoded in check.sh:
  - ISAR0[23:20] ≥ 2 (LSE)
  - ISAR1[23:20] ≥ 1 (LRCPC)
  - MMFR1[47:44] ≥ 1 (AFP)

  Optionally, also enable the FEX log with `FEX_SILENTLOG=0`.

### 8. CONFIRMED: "minimum macOS 26.6" doesn't match the build
- **Section:** spec:47, :357
- **Problem:** §5.4 sets no deployment target. The 26.6 branch in §9 can never run, because the binaries won't load below 27.0.
- **Evidence:**
  - `otool -l` on the trial's `ntdll.so`, `wine.unsigned`, `MacOS/wine` and `wineserver` shows `minos 27.0 sdk 27.0` for all four.
  - `xcrun --show-sdk-version` prints 27.0.
  - The patched `configure.ac` has no `-mmacosx-version-min` for aarch64; it sets one only on the preloader path (configure.ac:999-1004).
- **Fix:** either set `MACOSX_DEPLOYMENT_TARGET=26.6` for Wine and `CMAKE_OSX_DEPLOYMENT_TARGET` for FEX, and have bundle.sh check `minos`; or state 27.0 as the minimum.

### 9. check.sh's structure doesn't fit step 6
- **CONFIRMED:**
  - "One PASS or FAIL line" per step (spec:318) can't report five gates in step 6.
  - Cleanup and the §10 orphan check (spec:307, :365) cover only processes under the staged runtime. G4 also starts Rosetta-runtime processes, which nothing cleans up.
- **PLAUSIBLE:** a 3-minute cap on step 6 (spec:356) is too short for G1, G2 (80 million handshakes), G4 (10 Wine launches plus a fresh Rosetta prefix) and G5. I couldn't time it.
- **Fix:**
  - Give each gate its own step, with its own cap.
  - Extend cleanup and the orphan check to the Rosetta runtime and its prefix.

### 10. CONFIRMED: the build stamp conflicts with the development loop
- **Section:** spec:228, :238, :240-243
- **Problem:**
  - The stamp hashes pins and patch files, and patch files only change at the export step. So in the loop (edit, `make`, export), the build is skipped after an edit.
  - Step 3 (`git am` onto a fresh branch) would throw away commits that haven't been exported.
  - The stamp also ignores `wine.entitlements`, the scripts, and the signing identity.
- **Evidence:** the precedent works differently. `dxmt/build.sh:38` keys on a pinned fork commit, and `:72` refuses a dirty tree.
- **Fix:** add a development mode that builds the branch's HEAD as it is, and hash every build input in the stamp.

### 11. CONFIRMED: "with Mono and Gecko overrides off" reads two ways
- **Section:** spec:312
- **Evidence:** the trial needed `WINEDLLOVERRIDES="mscoree,mshtml="`. Without it, wineboot sat at the `install_mono` dialog and hit the 180 s cap (ent-trial.md:55, ent-rawTrial.md:32,36).
- **Fix:** write the exact environment string.

### 12. PLAUSIBLE: no time-box outcome except for G1, and no gate order
- **Section:** spec:326-345
- **Problem:**
  - The kill rule covers only G1. Nothing says what happens at three weeks if G2, G3 or G5 is still failing.
  - The week-1 `make wine-arm64` is meant to build from committed patches, so FEX patch 4 (dual view) would already have to exist by week 1. FEX could also be brought up first through patch 6's flip.
- **Fix:**
  - State the order: G1–G3 without FEX patch 4, then patch 4, then G5, then G4.
  - State the end-of-time-box outcome for each gate.

### 13. CONFIRMED: the spec relies on scratchpad files it calls temporary
- **Section:** spec:154, :221, :369, :375, :234
- **Evidence:**
  - `.gitignore:3` is `build/`, so `build/arm64/entitled/build.sh` holds the only copy of the configure flags (`--disable-tests`, `--without-x/wayland/oss/alsa/pulse/sane/usb/v4l2/pcap/capi/opencl/cups`, and the molten-vk `LDFLAGS`/`CPPFLAGS`).
  - The shared-cache scan tool exists only in `scratchpad/x18scan/`.
  - synthesis.md:174 records that an earlier spike's scratchpad was already wiped.
- **Fix:**
  - Commit the x18 design, its stress-test plan and the scan script.
  - List the configure flags in §5.4.

### 14. PLAUSIBLE (minor): G1 has no defined expected output
- **Section:** spec:332
- **Problem:** `x64-kuser` compares InterruptTime (100 ns units) and TickCount (ms) with `GetTickCount64`, which reads the same TickCount (`dlls/kernelbase/sync.c:191-199`). Wineserver updates that value asynchronously.
- **Fix:** for each test, state the expected lines, the unit conversion and the tolerance.

### 15. CONFIRMED (minor): roadmap row 9 misses a dependency
- **Section:** spec:62 versus spec:40
- **Problem:** row 9 depends on "6 (+8 for 32-bit)", but the decisions table also keeps D3D9 games on Rosetta until sub-project 7.
- **Fix:** make it "6 (+7 for D3D9, +8 for 32-bit)".

### 16. CONFIRMED (minor): §3.6's "at most" isn't an upper bound
- **Section:** spec:146
- **Problem:** 1.7–4.5 ms uses 150 cycles (synthesis.md:335). At 200 cycles the range is 2.25–6.0 ms.
- **Fix:** say "at 150 cycles", or quote 2.25–6 ms as the bound.

### 17. CONFIRMED (minor): patch 10's MIDR source is ambiguous
- **Section:** spec:201
- **Problem:**
  - On this Mac `sysctl hw.cpufamily` returns -143893734 (0xF76C5B1A), a hash. Used as a MIDR, its implementer byte would be 0xF7, not Apple's 0x61.
  - FEX decodes implementer and part from that value (`FEXCore/Source/Interface/Core/CPUID.cpp:273-279`) and compares it across cores to detect hybrid CPUs (`:161-172`).
- **Fix:** always 0, or implementer 0x61 with part number 0.

### Refuted sub-claims (the findings above still stand)
- **4(c), "G4 has no FAIL condition":** the Pass column already says "Every row has a FEX/Rosetta time ratio …", and §1 says ≤ 1.4 isn't a completion condition.
- **6, "the return stub flips":** it is x64 guest code and the host never executes it.
- **1, the "ntdll.so beside the loader" fix option:** it pushes `bin_dir` outside `Contents/`.
- **5, "FEX `HostFeatures` default off, meaning detect":** FEX advertises AVX on every host.

### New candidate, dropped
§6.3 installs `libarm64ecfex.dll` into Wine's builtin path, and Wine ignores DLLs there that lack the builtin marker (`virtual.c:3808-3812`). FEX already stamps that marker (`Source/Windows/CMakeLists.txt:13-15`, `ARM64EC/CMakeLists.txt:7`), so this is not a problem.

## feasibility
Refuted: 0 of 11. One sub-claim inside finding 3 (that the spec misses the cursor-address path) and some line numbers and wording in findings 1, 3 and 6 are corrected below. I re-checked every claim myself. Wine was not run, nothing in the repo was edited, and the compiles I did in `seh/` were deleted afterwards.

Line numbers: the original findings cite the trial tree `build/arm64/entitled/wine`. Pristine `src/wine-11.19` is about 50 lines lower in `virtual.c`. Below I give pristine numbers unless I say otherwise.

**1. CONFIRMED: §4 and §7.2, the installed layout runs every child process from an unentitled loader copy**
- **Problem:** in an installed layout, `wineloader` is `<real dir of ntdll.so>/wine`, not `Contents/MacOS/wine`. That is where `make install` puts its own copy of the loader. §7.2 step 1 signs that copy without the entitlement, so patch 3's 4K spawn kills every child. The first-process re-exec added by patch 8 hits the same copy.
- **Evidence:**
  - `src/wine-11.19/dlls/ntdll/unix/loader.c:386-400`: `ntdll_dir = realpath_dirname(...)`, then `wineloader = build_path( ntdll_dir, "wine" )`. `:467` gives `argv[1] = strdup( wineloader )`.
  - `tools/makedep.c:4231` and `:5157`, plus the generated `entitled/build/Makefile:287945`: the loader installs to `$(DESTDIR)$(libdir)/wine/aarch64-unix/wine`.
  - `bin/wine` is `tools/wine/wine.c`, which is a launcher that dlopens ntdll itself.
  - Trial patch `0003` spawns `argv[1]`.
  - `ent-trial.md:22-26`: an unentitled 4K spawn exits 137 with no message.
  - The trial only worked because `mkbundle.sh` symlinks `build/loader/wine` to the bundle (build-tree path).
  - Codesign check, re-run: `Res.app` and `Top.app` pass `--strict` and `--deep --strict`. In `Res.app`, `MacOS/ntdll.so` points to `../Resources/lib/wine/aarch64-unix/ntdll.so`, and `aarch64-unix/wine` points to `../../../../MacOS/wine`. `Fw.app`, `Hlp.app` and `Mac.app` fail with "code has no resources but signature indicates they must be present". I did not reproduce the "kernel32.dll not signed" text quoted in the original finding.
- **Fix:** keep the finding's layout. Add a constraint to §4: `realpath(<ntdll dir>/wine)` must equal `Contents/MacOS/wine`. Have `bundle.sh` check it.

**2. CONFIRMED (code facts); runtime effect in Wine PLAUSIBLE: §6.2 and §3.4, the RX view carries no ARM64EC code mark, and "No Wine change needed" is unproven for ARM64EC**
- **Evidence:**
  - At the pin, FEX's `AllocatorHooks.h` passes `MemExtendedParameterAttributeFlags = MEM_EXTENDED_PARAMETER_EC_CODE` whenever `Execute` is set. `CodeCache.cpp:616` says "The executed code must have MEM_EXTENDED_PARAMETER_EC_CODE set". `ImageTracker.cpp:253-257` has the same TODO.
  - Wine applies the mark only in the allocation path (`virtual.c:5260-5264`). `NtMapViewOfSectionEx` (`:6433-6504`) parses `attributes` and never uses them.
  - `llvm-objdump -f entitled/dualmap/dualmap.exe` gives `coff-arm64`, a plain ARM64 PE.
  - The bitmap drives Wine's EC-versus-x64 decisions (`signal_arm64ec.c:1039/1416/1500/1762`, `unwind.c:267/2070`).
- **Fix:** add a Wine patch that passes the EC attribute through `virtual_map_section`, mirroring `5260-5264`. Alternatively, first run an ARM64EC version of `dualmap` with an unwind or exception through the RX view. Either way, drop "No Wine change needed" until that is measured.

**3. CONFIRMED (backpatcher and offset model); "missing path 2" REFUTED: §6.2**
- **Evidence:**
  - Executable-allocation callers at the pin (`git grep`): `CodeCache.cpp:617` and `:863`, `Dispatcher.cpp:40`, `SharedCodeBufferManager.cpp:21`. A fifth, `atomic_segmented_bitmap_allocator.h:63`, is used only by unittests.
  - The unaligned-atomic handler at `Arm64.cpp:2108-2160` stores to `PC[0]`, `PC[1]` and `PC[-1]` at the faulting PC, which is the RX view. It is reached from `Module.cpp:719-721`, which is the TSO path, on by default.
  - Madeira HEAD still does the same (madeira `Arm64.cpp:~2398-2440`). Its Wine has `ios_emulate_store` handling (`mad/signal_arm64_ios.c:1430,1903`), which we will not have.
  - Madeira uses one global `DualMap::WriteOffset` (`CodeEmitter/Buffer.h:121,131`), while the spec maps a separate pair of views per buffer.
  - The "cursor address" path is not missing. §6.2 already says targets are computed from the execute view and bytes are stored through the write view, and it lists block linking. For the record, `GetCursorAddress` has about 86 non-test uses, not 62.
- **Fix:**
  - Name the four callers and say which get dual views. The dispatcher and the code cache are ambiguous today.
  - Add the SIGBUS backpatcher and the `IsAddressInCodeBuffer` users to the list.
  - Choose between one reserved pool with a fixed delta and a per-buffer delta carried in `Buffer`.

**4. CONFIRMED: §5.2 patch 7 and §9, the entitlement check is underspecified and can check the wrong binary**
- **Evidence:**
  - `otool -L entitled/build/dlls/ntdll/ntdll.so` lists only IOKit, CoreFoundation, CoreServices and libSystem. `dlls/ntdll/Makefile.in:8` has no Security framework.
  - Re-run `scratchpad/ca/ca` (ad-hoc signed) prints `os_cross_arch_is_supported=1` and `SecTask entitlement=absent`, so the cross-arch API is not a substitute.
  - SecTask checks the running process, but the 4K attribute applies to the exec target. With the trial's layout, launching through the entitled bundle after `make` has relinked `build/loader/wine` gives an entitled parent and an unentitled target.
  - The exec happens in a double-forked grandchild (`process.c:418/420/444`).
- **Fix:**
  - Check the target file with `SecStaticCodeCreateWithPath(wineloader)`, then `SecCodeCopySigningInformation`, then `kSecCodeInfoEntitlementsDict`.
  - Compute this once, before any fork.
  - Add `$(SECURITY_LIBS)` to ntdll's `UNIX_LIBS`. That variable exists (`configure.ac:981`, used by crypt32 and mountmgr).

**5. CONFIRMED: §8 G2 can't be run as written**
- **Evidence:**
  - Affinity is never applied: `entitled/build/include/config.h:365` has `HAVE_SCHED_SETAFFINITY` undefined, and `server/thread.c:740-758` only stores the value.
  - The switch is `FEX_TSOENABLED`: `config_generator.py` uppercases option names, `Config.cpp` reads `"FEX_" #enum`, and `TSOEnabled` defaults to true (`Config.json.in:467`).
  - `VectorTSOEnabled` and `MemcpySetTSOEnabled` default to false (`:475-489`).
  - Re-run `scratchpad/lit/lit` (native, weakly ordered, barrier-synchronized): LB 0, 2+2W 0, IRIW 0 and MP 0 out of 2M each. A "TSO off must show forbidden outcomes" check built this way would fail even though the hardware is weak.
  - The spin-read MP in `xarch/probe.c:40-50` is the shape that shows violations (§3.1 reports about 41%).
- **Fix:** take the original finding's fix: drop "pinned", name `FEX_TSOENABLED=0`, require violations only for the probe-style MP shape, and use scalar volatile variables.

**6. CONFIRMED, with one correction: §6.1 item 5 and G3**
- **Evidence:**
  - FEX has no host-feature log. The only related message is `HostFeatures.cpp:552-553`, `WARN_ONCE` "Host CPU doesn't support atomics".
  - `SilentLog` defaults to true (`Config.json.in:415`), and `Windows/Common/Logging.cpp:37-38` returns early when it is set.
  - Correction to the original finding: FEX reads 11 values, not three. They are `CP 4030/4020/4021/4031/4038/403A/4024/4039/4032/5801/4000` (`CPUFeatures.cpp:44-62`). The fields G3 needs are in 4030 (LSE), 4031 (LRCPC) and 4039 (AFP).
- **Fix:** measure G3 by reading and decoding those three registry values. Otherwise make FEX patch 5 mandatory and state `FEX_SILENTLOG=0`.

**7. CONFIRMED: §8 G4, the benchmark is undefined and the ratio direction is inverted**
- **Evidence:**
  - `gh api gists/f1f02698…` lists only `["fex-vs-rosetta-std64.md"]`, which names `fexbench2.c` but does not include it.
  - `scratchpad/fex-vs-rosetta.md:7`: "Ratio = FEX/Rosetta throughput, so >1 = FEX faster". G4's ratio is time, where above 1 means FEX is slower.
  - `Sources/MacNeutronCore/LaunchEnvironment.swift:14-15` sets `ROSETTA_ADVERTISE_AVX=1` only on the launcher path, and the gist's AVX2 paths are chosen by cpuid at run time.
  - The shipped runtime's `Libraries/Wine/bin/wine` is x86_64. `dxmt/check.sh:33-40` shows how to run an exe on it through `macneutron launch waitforexitandrun`.
- **Fix:** take the original finding's fix.

**8. CONFIRMED: §8 G5, "0 flips on FEX code-buffer pages" can't be measured as worded**
- **Evidence:**
  - Patch 6 (`entitled/patches/0006`, hunk at virtual.c `4772+`) flips only pages that pass `is_vprot_exec_write(vprot)`. Dual-view pages are RW or RX, so they never flip, and the gate passes by construction.
  - Pages that can still flip are the executable allocations that were left RWX by mistake. ntdll has no way to tell which of those belong to FEX.
  - I checked the advisor's suggestion that the return stub causes a flip at init, and it does not hold. `Module.cpp:629-632` writes the single x64 byte `0xc3`. `Module.S:93-97` uses it only as an x64 return address, which the emulator runs, so it is never executed natively and never flips. §6.2's statement that it "stays … through patch 6's flip" is harmless but inaccurate.
- **Fix:** take the original finding's fix: log each flip address and require 0 flips after FEX init during `x64-bench`. Alternatively, assert that FEX makes no executable `VirtualAlloc` except the return stub.

**9. CONFIRMED: §5.4, the development loop contradicts the stamp and patch steps**
- **Evidence:** spec lines 228 and 238 against 240-243. The stamp hashes only the pins and the patch files, so an edit on the branch leaves it unchanged and step 8 skips the build. If the build did run, step 3 would re-create the `macneutron` branch with `git am`.
- **Fix:** take the original finding's fix: when the tree is dirty or ahead of the exported patches, skip fetch, patch and the stamp check.

**10. CONFIRMED: §7.3, x64 tests need two flags with the pinned llvm-mingw**
- **Evidence:**
  - `x86_64-w64-mingw32-clang` (clang 23.1.1) on `seh/seh.c` fails with "use of undeclared identifier '__try'" and builds with `-fms-extensions`.
  - `seh/cpp.exe` imports `libc++.dll` and `libunwind.dll`. Rebuilt with `-static`, those imports are gone.
- **Fix:** x64 tests build with `-fms-extensions`, and C++ tests link with `-static`.

**11. CONFIRMED: §7.3 step 4, the page-size check can't fail**
- **Evidence:** `unix_private.h:181` defines `page_size = 0x1000`, and `virtual.c:3776` sets `info->PageSize = page_size`, whatever the host page size. The real check is the `virtual_init` trace at `virtual.c:3693`: the trial logs contain 72 "host page size: 4k" lines and 2 "16k" lines.
- **Fix:** treat the `GetSystemInfo` value as information only. Step 3's trace is the check.

**No new blocking findings.** One item I checked and cleared: Wine ignores non-builtin DLLs found in its own DLL directories (`virtual.c:3808`). FEX's build already stamps the builtin marker (`Source/Windows/CMakeLists.txt:15`, `wine_builtin.bin`), so the §6.3 install into `aarch64-windows` is fine.