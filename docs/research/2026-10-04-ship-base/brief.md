# Sub-project 3 "Ship-base Wine": decision brief for the spec

Based on six investigations (x18, msync, FreeType/gnutls, lsteamclient, JIT/RWX, licences), checked against `docs/superpowers/specs/2026-10-02-macneutron-native-arm64-design.md` (§2 row 3, §3.4, §5.3, §11). Each claim is marked **[V]** verified (with file:line, command output or URL in the source finding) or **[I]** inferred. No inferred number is given here as measured. Probe sources are in `probes/` (outputs were in a session scratchpad and are not kept; the numbers are quoted where used).

## 0. The scope test, and the verdict for each item

Test: **is the item needed for "a real x64 D3D11/12 game runs well in the arm64 runtime, with text, TLS and Steam where needed"?** I also say where an item stays for another reason.

| Item | Passes the test? | Verdict |
|---|---|---|
| FreeType | Yes. Without it GDI text and dialogs don't render; patch 0014 only stops the crash [V] | **Keep, do first** |
| gnutls | Yes. Without it schannel is never registered, so HTTPS through Windows APIs fails [V] | **Keep, same step as FreeType** |
| Licence files | Yes, for shipping: wine.app has only DXMT's notices today [V] | **Keep** |
| msync | Not proven. The speed gain is **inferred** and has not been measured in Wine | **Keep**, mainly for parity with the Rosetta runtime (which runs msync by default), so SP6's frame-time comparison doesn't mix in a sync difference |
| Strict x18 toggling | No game-visible effect today: no shared-cache code depends on x18 [V] | **Keep as a ship gate, not a game gate.** Roadmap row 3 and §11 already commit against shipping the once-per-thread mode. Do it last |
| MAP_JIT / dual view for non-FEX RWX | No. Guest RWX under FEX never needs to be executable on the host (G5: 0 flips) [V], and MAP_JIT as specified does not work [V] | **Drop.** Replace with a zero-flip check and spec amendments |
| lsteamclient | Not in SP3: nothing in SP3 runs Steam; the first game that needs the Steam API (SMITE 2) is SP6 [V] | **Move to SP4.** SP4's dependency changes from 3 to 1, so it runs in parallel with SP3. This reorganizes the Steam path; it does not drop Steam from the bar |
| Media (FFmpeg/GStreamer) | Partly: UE4/UE5 WmfMedia intro movies and some cutscenes need it [I] | **New roadmap row**, not SP3 |

## 1. FreeType and gnutls (do first)

**Current state [V].** Wine 11.19 was configured against Homebrew's headers (configure.log:270-279; config.h:755 `SONAME_LIBFREETYPE "libfreetype.6.dylib"`, :764 `SONAME_LIBGNUTLS "libgnutls.30.dylib"`), but wine.app ships no `.dylib` at all. Wine loads both libraries only by `dlopen` of a bare filename (win32u/freetype.c:1457, dwrite/freetype.c:118, secur32/schannel_gnutls.c:1474, crypt32/unixlib.c:111), so all four loads fail.
- Without gnutls, schannel never registers (schannel.c:1890-1893), and crypt32 loses PFX import.
- bcrypt runs on PE-side SymCrypt and needs no gnutls.
- Root certificates come from Security.framework (crypt32/unixlib.c:962-980), so p11-kit, libidn2 and a CA bundle can be left out.
- The Rosetta runtime ships the full x86_64 set (gnutls 3.8.9, nettle 3.10, FreeType, plus FFmpeg, GStreamer, MoltenVK, krb5) with no licence files [V]. That is not a precedent to copy.

**Recommended design.** Build from pinned source tarballs in `build.sh` and place 2 dylibs in `Contents/Resources/lib/wine/aarch64-unix/`. No Wine patch is needed:
- **Why it works without a patch [V]:** every unix `.so` already carries `LC_RPATH @loader_path/` (otool -l), and probe A (`sp3/dlprobe`) showed a bare-name dlopen from such a `.so` under the hardened runtime finds the dylib beside it, including the dylib's own `@rpath` dependency.
- **What does not work [V]:** `DYLD_LIBRARY_PATH` and `DYLD_FALLBACK_LIBRARY_PATH` are ignored (probe D), and `/opt/homebrew` and `/usr/local/lib` are never searched.
- **Pins** go in a new `wine-arm64/pins`, fetched with the existing `fetch` helper (dxmt/lib.sh) into `build/wine-arm64-src/deps`. Build with `MACOSX_DEPLOYMENT_TARGET=27.0` and `/usr/bin/clang`:
  - gmp 6.3.0 and nettle 4.0: static, PIC.
  - gnutls 3.8.13: shared, with `--with-included-libtasn1 --with-included-unistring --without-p11-kit --without-idn --without-tpm --without-tpm2 --without-zlib --without-brotli --without-zstd --without-leancrypto --disable-nls --disable-tools --disable-cxx --disable-doc --disable-tests --disable-libdane`. nettle, hogweed and gmp are folded into `libgnutls.30.dylib`.
  - freetype 2.14.3: system zlib and bzip2, `--without-png --without-harfbuzz --without-brotli`.
  - `install_name_tool -id @rpath/<leaf>` on both dylibs.
- **Configure Wine with `PKG_CONFIG_LIBDIR=<deps>/lib/pkgconfig`**, so the headers match what ships and Homebrew can't leak in. Today configure reads every Homebrew `.pc` file: if a brew `ffmpeg` or `sdl2` were present, `winedmo.so` would link `/opt/homebrew` paths, and bundle.sh (which checks only minos) would not notice [I]. This forces one reconfigure (`rm -rf wine-build`).
- **Patch 0014 stays** as a safety net: a missing dylib then gives a silent fallback, not a crash. Note it in the rebase notes.

**GMP must be at least 6.3.0, permanently [V/I].** gmplib.org lists 6.2.1's arm64 assembly as using x18 [V]. This is not a stopgap until strict toggling: with the mode OFF, the kernel zeroes x18 at exception return (locore.s:1918-1922, XNU 12377 [V]), so a library that uses x18 as scratch breaks in both modes [I]. Make the bundled-dylib x18 scan a **permanent** bundle.sh gate. Homebrew's builds of the same versions scan at 0 x18 instructions [V].

**Alternatives.**
- **(2)** Ship nettle, hogweed and gmp as separate dylibs (5 in total) with install-name rewrites. This is the fallback if libtool refuses to fold static archives into the shared gnutls (unverified).
- **(3)** Put the dylibs in `Resources/lib` and add an `LC_RPATH` to the loader. Probe B shows this works. It is tidier once FFmpeg, SDL2 or MoltenVK arrive, but it touches the custom-linked loader (patch 0001). Not needed yet.
- **Rejected: Homebrew bottles [V].** freetype, libunistring, libpng and libintl have minos 26.0, which fails bundle.sh's 27.0 check; gnutls pulls in 10 dylibs with absolute `/opt/homebrew` install names; versions are unpinned.
- **Rejected:** the `allow-dyld-environment-variables` entitlement (reopens dyld injection), and mini-gmp (up to 10× slower bignum maths, same licence).

**Effort [I].** About 1 day plus one rebuild:
- pins: ~10 lines;
- build.sh: ~50 lines;
- bundle.sh: ~25 lines;
- one PE test program: ~120 lines;
- check.sh step: ~20 lines.
The first deps build takes an estimated 4-6 minutes and is cached after that.

**Test and gate.**
- **bundle.sh, static:**
  - both dylibs exist, with `otool -D` = `@rpath/...`;
  - every `otool -L` entry of every Mach-O in the bundle starts with `/usr/lib/`, `/System/`, `@rpath/` or `@loader_path/` (this also catches a Homebrew leak);
  - minos 27.0 (the existing loop covers the new files);
  - x18 scan = 0 for both dylibs (regex from `probes/x18-cache-scan.sh`);
  - every symbol Wine resolves (70 for gnutls, 46 for FreeType [V]) appears in `nm -gU`;
  - a licence folder exists for each library.
- **check.sh step `fonts-tls`** (offline, arm64 PE test program; an x64 build under FEX is optional):
  - `CreateFontW("Tahoma")`, then `GetTextMetricsW`, `GetTextExtentPoint32W(L"Hello")` and `GetDialogBaseUnits()`: all must be > 0. Today dbu is 0,0.
  - `AcquireCredentialsHandleW(UNISP_NAME_W, OUTBOUND)` must print exactly `schannel: 0x00000000`. Today it returns 0x80090305.
  - Optional: PFX import of an embedded fixture.
  - The log must not contain "Failed to load libgnutls" or "cannot find the FreeType".
- **Negative control:** a clone of wine.app with the two dylibs deleted must give dbu=0,0 and 0x80090305.

**Downloads (maintainer approval needed).** The SHA-256 values come from Homebrew's signed API cache on this Mac [I]. Check each against the upstream `.sig` at first fetch.

| Pin | Canonical URL | Alternate host | SHA-256 | Why |
|---|---|---|---|---|
| freetype 2.14.3 | https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.xz | https://downloads.sourceforge.net/project/freetype/freetype2/2.14.3/freetype-2.14.3.tar.xz | `36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f` | GDI and dwrite text |
| gnutls 3.8.13 | https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz | (none) | `ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e` | schannel TLS, crypt32 PFX |
| nettle 4.0 | https://ftp.gnu.org/gnu/nettle/nettle-4.0.tar.gz | ftpmirror.gnu.org | `3addbc00da01846b232fb3bc453538ea5468da43033f21bb345cb1e9073f5094` | gnutls crypto backend (needs ≥ 3.10). Fallback: nettle-3.10.2 |
| gmp 6.3.0 | https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz | ftpmirror.gnu.org | `a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898` | hogweed bignum maths; ≥ 6.3.0 because of x18 |

libpng 1.6.58 is needed only if FreeType gets PNG support; I recommend not adding it.

**Licences** (not legal advice):
- FreeType under the FTL: ship LICENSE.TXT and FTL.TXT, plus a credit sentence in the documentation.
- gnutls: LGPL-2.1+ (COPYING.LESSERv2). Its included libtasn1 is LGPL-2.1+.
- nettle, gmp and the included libunistring: elect LGPL-3+. Ship both the LGPLv3 and GPLv3 texts.
- LGPL obligations: the exact source of each must be available, and `libgnutls.30.dylib` must stay rebuildable from what we publish.

## 2. Licence files (no downloads; do while the download approval is pending)

**Current state [V].** wine.app has exactly 3 licence files, DXMT's (bundle.sh:56). Missing:
- Wine (LGPL-2.1+);
- FEX (MIT) and its 8 linked externals (fmt, xxhash, tiny-json, cpp-optparse, unordered_dense, rpmalloc, range-v3, cephes), plus SoftFloat-3e, VIXL-derived code, musl and Arm code compiled from source headers;
- the Madeira MIT grant;
- LLVM 15.0.7, statically linked in winemetal.so (`_llvm_regcomp` present);
- the llvm-mingw runtime and the mingw-w64 runtime (in DXMT's DLLs and winemetal.dll);
- DXBCParser (MIT, Microsoft) and com_guid.

Wine 11.19's own `NOTICES.md` covers almost all of Wine's vendored code, **except GSM** (whose COPYRIGHT must travel with it) and FAudio. Wine's vendored FFmpeg is LGPL-only (`CONFIG_GPL 0`). The scratch check `sp3/licences_check.sh` is red on today's bundle: 36 MISSING lines, exit 1.

**Recommended design.** One `Resources/licenses/<component>/` tree, filled with the existing `put` helper (about 25 lines in bundle.sh step 1). `Resources/DXMT/` stays where it is.
- **Folders:**
  - `wine/`: LICENSE, COPYING.LIB, AUTHORS, NOTICES.md, gsm-COPYRIGHT, faudio-LICENSE.
  - `fex/`: LICENSE plus one `<external>-LICENSE` per linked external.
  - `llvm/`: LICENSE.TXT, COPYRIGHT.regex.
  - `llvm-mingw/`: LICENSE.TXT, COPYING.MinGW-w64-runtime.txt.
  - Later items add their own folders (freetype, gnutls, nettle, gmp).
- **Committed `wine-arm64/licenses/NOTICES.md`:** the notices that exist only in source headers (UC Regents, VIXL, musl, Arm, Will Faust/Madeira, Microsoft DXBCParser, Bessonov, Unicode ConvertUTF, Henry Spencer).
- **Generated `licenses/SOURCE`:** the Wine, FEX (with the 8 linked submodule SHAs), DXMT, MacNeutron, LLVM and llvm-mingw pins, each with its patch-series hash, plus each tarball's URL and SHA-256.
- **Committed `licenses/README`:** component → licence → source location, plus the FreeType credit line.
- **bundle.sh step 3 asserts:**
  - every licence file is non-empty;
  - NOTICES.md names each copyright holder;
  - a drift gate: `fex-ec/External` contains only the 8 allowlisted directories;
  - any shipped libfreetype, gnutls, nettle or gmp has its licence folder;
  - SOURCE has every key.
- **LGPL source access:** a public repo at a tagged commit (the repo is PUBLIC [V]), plus source archives attached to the same release as wine.app. That release step belongs to SP5. A written offer is not needed [I].
- **Notarization stays in SP5.** All prerequisites are met today (Developer ID, hardened runtime, secure timestamp, no get-task-allow) [V]. Whether a bundle with the restricted entitlement notarizes stays unknown until a real submission [I].

**Alternatives.**
- No SOURCE file and no release archives: weaker under LGPL-2.1 §4.
- A single generated THIRD-PARTY-NOTICES file: more code that drifts silently.
- Pulling a one-off manual `notarytool submit` into SP3: fine as an experiment; the pipeline stays in SP5.

**Effort [I].** About 1 day. Each later library adds 2-3 lines.

**Test and gate.** `sp3/licences_check.sh` becomes `wine-arm64/tests/licences_test.sh`:
- Today: red, `FAIL licences_check`, exit 1 [V]. After the change: `PASS licences_check`, exit 0.
- Red-proof: delete `licenses/fex/xxhash-LICENSE` from a copy of the bundle → MISSING line; add a fake `External/vixl` to a copy of the fex-ec tree → drift failure.
- Signing asserts: `codesign -dvv` shows `Timestamp=` on every Mach-O, and the loader has no get-task-allow.

**Downloads:** none; every text is already local.

**Side note:** MacNeutron.app (the Rosetta path, Makefile `app` target) has the same gap: its x86_64 winemetal.so contains LLVM, and its DXMT DLLs and steam.exe contain the mingw-w64 runtime [V]. That is a small separate change, outside SP3.

## 3. msync (patch 0015)

**Current state [V].**
- **Rosetta runtime-v4.7.3:** runs cx/wine1117's msync, including dappermint's 2026-08-21 commits (strings: `WINEMSYNC_QLIMIT`, `WINEMSYNC_SPINS`). The launcher turns it on by default (LaunchEnvironment.swift:17-18).
- **arm64 Wine 11.19:** has the inproc-sync framework, but its only backend is Linux ntsync (sync.c:311). On macOS, `get_inproc_device_fd()` returns -1, so every Wait, SetEvent and ReleaseX is a wineserver round trip.

**Recommended design (option A).** Port cx/wine1117's msync as **one** patch, server and ntdll together, because they share a protocol change:
- copy the 4 files verbatim (2,202 lines, identical on cx/wine1117 and arm64-1117, all present locally);
- apply the msync-only hunks (`sp3/msync-on-11.19-trial.diff`);
- the one loader.c conflict: `msync_init()` goes after `server_init_process( data )`;
- `linux_wait_objs` takes `WAIT_TYPE` and passes `type != WaitAll` (it works today only by accident);
- **regenerate with `tools/make_requests`, including the SERVER_PROTOCOL_VERSION bump** (the reply struct grows from 16 to 24 bytes);
- credit Zent, CodeWeavers and dappermint e0aa380780.

Default **on**, to match the Rosetta runtime, with the existing per-game off switch.

**What is already known:**
- The trial merge onto 11.19 + 0001-0014 had 1 conflict, and all 7 touched files pass `-Wall -fsyntax-only` with no warnings [V].
- Every private API msync uses works on Darwin 27 arm64 under the hardened runtime, across two processes (`sp3/probe/msyncprobe.c`, ad-hoc signed with `-o runtime`) [V].
- 4K/16K agreement: both sides size their shared memory with `vm_kernel_page_size`. A 4K Rosetta client worked against a 16K server [V]. That the **entitled arm64 4K** process also reads 16384 is [I], not probed.
- Strict x18, ARM64EC, WoW64 and FEX do not affect msync: it lives only in ntdll.so and wineserver, and `GetCurrentThreadId` goes through `pthread_getspecific` [V].
- Whether this code has ever run on native arm64 is unconfirmed [I].

**Hard rule [V].** The client and wineserver must agree on WINEMSYNC, otherwise the client calls `exit(1)` (ntdll msync.c:636-655, :690-694). Every arm64 entry point (check.sh steps, wineboot, winepath, later the launcher) must pass the same value, and an A/B test needs `wineserver -k` between modes.

**What msync buys.**
- Measured [V]: cross-process wake latency is about the same either way, about 6.3 µs with ulock against 5.2 µs for a pipe round trip.
- Inferred [I]: the gain is in uncontended operations (atomics instead of a server round trip of 5 µs or more) and in keeping the single-threaded wineserver off the hot path. The 10-100× figure for uncontended ops is an **estimate, not measured in Wine**.

**Known correctness gaps [V]:** PulseEvent can miss a waiter; wait-all is not atomic; the wait-all rollback forgets an abandoned mutex. CodeWeavers ships msync off by default and says some apps break.

**Alternatives.**
- **(B)** Default off: safer, but then SP6's comparison against Rosetta mixes in a sync difference.
- **(C)** CodeWeavers' unmodified crossover-26.3.0: lacks dappermint's race fixes, and the Rosetta runtime doesn't run it.
- **(D)** No msync: correct, but wineserver becomes the bottleneck [I].
- **(E)** A clean ulock-only upstream backend: best long-term, out of scope.
- **Optional hardening:** allocate the full shm_addrs table (2 MB) once on both sides, removing a realloc race that triggers only past about 131k live objects [I].

**Effort [I].** About 3 days: port 0.5-1, native bring-up 1, stress test 1, plus under 0.5 if the hardening is included.

**Test and gate.** `wine-arm64/tests/x64-sync.c`, built x64 (run under FEX) and native, each run with and without WINEMSYNC (`wineserver -k` between):
- **Gated correctness rows:** event ping-pong; semaphore counts and ERROR_TOO_MANY_POSTS; mutex with ERROR_NOT_OWNER and WAIT_ABANDONED; wait-any lowest index; wait-all exclusivity; mixed wait with a process handle; timeouts; alertable APC; cross-process named objects plus DuplicateHandle; more than 3,000 events spanning 3 or more 16K chunks across processes; 200k create/close churn with no `msync: error`. PulseEvent is recorded, not gated.
- **Mode rows:** `msync: up and running.` appears only with WINEMSYNC=1; a mismatched client exits non-zero with the "Server is running with WINEMSYNC but this process is not" message.
- **Timing rows, reported not gated:** these give the first real measurement of the msync gain.
- **pages step:** print `vm_kernel_page_size` inside the entitled bundle; expect 16384.

**Downloads:** none (source is in the local winecx clone). **Licence:** LGPL-2.1+, covered by Wine's texts; name the authors in NOTICES and the commit message.

## 4. RWX memory other than FEX's: drop MAP_JIT from SP3

**Findings.**
- **Not needed [V]:** guest RWX under FEX never runs natively. Patch 0006 lowers it to host read-write; FEX catches self-modifying code with its own PAGE_EXECUTE_READ trap (InvalidationTracker.cpp:219-246, [I] that it never reaches 0006's flip, because x64-smc has not been run with +wxflip yet). The G5 x64-bench log has **0** wxflip lines for the whole process, including Wine's startup [V]. .NET AnyCPU executables already run as x64 under FEX (mapping.c:1682-1684) [V].
- **Doesn't work as specified [V]** (probes `sp3/mapjit-*.c`, unentitled, 16K pages):
  - `MAP_JIT|MAP_FIXED`, shared MAP_JIT and file-backed MAP_JIT all fail with EINVAL.
  - Once a MAP_JIT range is RWX, every mprotect on it fails with EACCES.
  - Switching back to execute inside the fault handler is undone on return, so the fault repeats forever.
  - At best a fault-driven MAP_JIT design is about 2× better than 0006 (about 4.4 µs against 9.0 µs per cycle). §3.4's 23 ns applies only to JITs that switch modes themselves.
- **Latent 0006 bug:** native ARM64 code that stores into its own RWX page loops forever. Verified natively; that it behaves the same inside Wine's handler is [I]. No current target game triggers it.

**Recommended design.**
- Keep 0006.
- Add check.sh step `wxflip-x64`: `WINEDEBUG=+wxflip` x64-smc.exe under FEX must print `PASS x64-smc` with `grep -c trace:wxflip` = 0. The existing arm64-wxflip positive control (19 flips) stays.
- Spec amendments:
  - §2 row 3: drop MAP_JIT.
  - §3.4's 23 ns note: correct it.
  - §11's "Games with their own JIT" risk: wrong for x64 games; rewrite it.
- FEX's 32-bit WoW64 JIT is still RWX (Allocator.cpp:26-31), so its dual-view port goes to **SP8** (about 2-3 days [I]).

**Effort [I]:** about 0.5-1 day. **Downloads and licences:** none.

## 5. Strict x18 toggling (last)

**Current state [V].** Patch 0004 turns the mode ON once per thread (signal_arm64.c:1627-1630 in the patched tree), so libc, Metal, AppKit, winemetal and pthread_exit all run ON, against the SDK header's rule (`os/arch/arm64.h:66-82`). It is harmless today: a scan of all 4,086 shared-cache images found no code that depends on x18.

**Measured cost [V]** (M5 Pro, unentitled; the userspace path is identical when entitled):
- 1.41-1.54 ns per toggle;
- about 3 ns per syscall or unix-call round trip with parked registers;
- about 6 ns with register-preserving helpers;
- for comparison, a getppid() syscall costs 82.6 ns.

The research doc's 5-20 ns estimate was pessimistic. Wine's own unix-call cost is unmeasured, so no DXMT percentage is claimed until test W2.

**Recommended design (b).** One patch replacing 0004, only in `dlls/ntdll/unix/signal_arm64.c`, following x18-boundaries.md. That doc uses pre-patch line numbers: add 3 for lines 58-1621 and 8 after that. Contents:
- OFF on syscall and unix-call entry (at the kernel_stack labels :1780 and :1934), ON before the x18 reloads on return;
- ON before user-callback entry (:925/:927);
- move the x18 reads that would run while OFF (:1785, :1803, :910-922, :928/:936);
- delete 0004's hunk.

Three additions the doc lacks:
1. :1893 in the global `__wine_syscall_dispatcher_return` must read the TEB from `[sp,#0x90]` [V].
2. The signal wrapper must pass the toggle's `brk #1` through (SIGTRAP → SIG_DFL, then return), so an imbalance kills the process with Apple's annotation instead of becoming a Windows ILLEGAL_INSTRUCTION that SEH could swallow (verified by `sp3/trappass.c`).
3. A gated "PE stack implies ON" invariant check in the wrapper (an untested proposal [I]).

The wrapper must land in the same patch as the dispatcher toggles, because OFF handlers (usr2 slow path, abrt) redirect into PE [I].

ARM64EC and FEX add no new boundary [V]: FEX never allocates x18, reads it only as the TEB, imports only ntdll, and reaches unix code only through Wine's dispatchers.

§5.3's "80-100 lines" becomes about 110-140 [I].

**Alternatives.**
- Register-preserving helpers (`__wine_x18_on/off`): about 6 ns per round trip, a smaller and safer assembly diff.
- Keep (a) plus a cache scan on every macOS beta: zero cost, but the spec commits against shipping it.
- Rejected: staging the wrapper after the dispatchers.

**Effort [I].** About 2-3 days, plus `x18path.c` (150-200 lines), plus one check.sh step. Ongoing: rebasing signal_arm64.c on each Wine update.

**Test and gate.**
- **Static check:** `otool -tV ntdll.so` x18 hits appear only in the dispatcher, callback and dispatcher_return routines, each inside an ON window (beware matches on `#0x18`). `nm -m` shows 2 non-weak imports.
- **T1:** x18v, 72 threads × 3 s, 0 mismatches.
- **T2:** x18path.exe (aarch64 and x86_64 under FEX), every path prints `ok`: SEH access violation, `__debugbreak`, SIGILL, Suspend/Get/SetThreadContext, SendMessage callback, NtReadFile into an unmapped buffer, APC, 1000 thread cycles, raw `syscall`, FEX-suspended thread. 0 mismatches, no "PE stack running OFF" ERR lines.
- **T3:** a negative test that double-enables the mode must die by SIGTRAP with Apple's annotation.
- **T4:** A/B against (a): at most 4 ns (parked) or 8 ns (preserving) per round trip, and DXMT frame-time p50 within 1%.
- **T5:** S2/S3 stress tests entitled, 0 failures. These should also cover a signal landing inside a toggle [I].

**Downloads and licences:** none (SDK header only; the patch stays LGPL-2.1+).

**Not yet run entitled:** the toggle cost probe and S2/S3. No decision depends on them, because the userspace path is the same.

## 6. lsteamclient: move to SP4

**Findings.**
- Row 3's "lsteamclient" and row 4's "ARM64X lsteamclient" are the same artifact. The split dates from when the base was going to be CrossOver arm64-1117 [V].
- It builds for arm64 without source changes [V]:
  - all 44 PE files compile for arm64ec and aarch64;
  - all 219 unix .cpp files compile, and all 7,251 struct-layout asserts pass;
  - a probe link of the unix side needs only symbols that our ntdll.so exports.
  Linking and running the PE side were not tested.
- Mac Steam's `steamclient.dylib` is universal [V]. Its arm64 slice loads in a native process, hands out SteamClient006-023, and installs no crash handlers up to `CreateInterface` [V].
- The x18 scan of Steam's dylibs finds 0 sites in clean code; the method is a heuristic [V].
- **Licence blocker [V]:** lsteamclient is under Valve's Steamworks SDK licence, not BSD-3. Bundling it would make MacNeutron the distributor, reversing the bridge spec's position at line 187.

**Recommendation.** Row 4 becomes the whole Steam path and depends on SP1, not SP3:
- pinned build-time sparse fetch of Proton `lsteamclient/` at `db9e6ffbf24a95b104fb699dd62532c70a2f9a51`;
- winecx's 3 Mac fixes plus configure registration;
- aarch64 steam.exe;
- probe and check scripts in an arm64 mode;
- the x18-steam scan.
Launcher wiring goes to SP5, i386 to SP8, the overlay to SP6. **The licence decision moves with it.**

For the SP4 spec, not decided here: the overlay scope conflict (the stack map's SP6 gate against the bridge spec), and `CXX=/usr/bin/clang++` in build.sh.

The download (Proton repo at that commit, or the alternative dappermint/winecx e0aa380780) belongs to SP4.

## 7. Spec and roadmap amendments to write

1. §2 row 3 → "Strict x18 toggling (§5.3); msync from CrossOver wine1117; FreeType and gnutls built from pinned source and bundled; licence and notice files for every shipped component."
2. §2 row 4 → depends on 1; owns lsteamclient end to end, including the Steamworks licence decision.
3. New row: "Media: FFmpeg for winedmo and/or GStreamer for winegstreamer". Today winedmo builds as a stub and winegstreamer is not built [V]; UE WmfMedia movies are the impact [I].
4. §3.4: the 23 ns MAP_JIT figure applies only to JITs that switch modes themselves; give the fault-driven numbers.
5. §5.3: about 110-140 lines; the three additions; replace x18-boundaries.md's pre-patch line numbers with the patched-tree ones.
6. §11: rewrite "Games with their own JIT" (x64 JITs go through FEX's trap, not 0006); add the same-page livelock in 0006; add the Homebrew pkg-config leak; add the WINEMSYNC agreement rule.
7. Row 8 (SP8): add the WoW64 FEX dual view.

## 8. Order of work (about 8-9 working days [I])

| # | Step | Days [I] | Needs | Delivers |
|---|---|---|---|---|
| 1 | Licence tree, NOTICES.md, SOURCE, bundle.sh asserts, licences_test | 1 | Nothing; start while the download approval is pending | A bundle that can be shipped legally (minus SP3's new libraries) |
| 2 | FreeType + gnutls deps step, PKG_CONFIG_LIBDIR, otool -L and x18 gates, `fonts-tls` | 1 + rebuild | Approval of the 4 downloads | Text and dialogs render; HTTPS works. **First visible user value** |
| 3 | msync patch 0015 and x64-sync | 3 | — | Rosetta parity; first measurement of server sync against msync |
| 4 | `wxflip-x64` check and spec amendments | 0.5 | — (any time; can run in parallel) | Proof that MAP_JIT is unnecessary |
| 5 | Strict x18 (replaces 0004), x18path, T1-T5 | 2-3 | Everything else green | The ship-gate contract |

**Rebuild cost.** Step 2 forces a reconfigure (`rm -rf wine-build`), and step 3 forces `make_requests` plus a protocol bump, which is another full Wine rebuild. To save a full build, write msync before step 2's rebuild and take both in one reconfigure, at the price of a later first visible result.

**Parallel work:** SP4 (Steam) can run in parallel off SP1's tree.

## 9. Risks

- **gnutls build:** libtool folding static nettle and gmp into the shared libgnutls is unverified. Fallback: option 2 (5 dylibs). nettle 4.0 is about 8 months old with a soname bump; fallback 3.10.2.
- **Homebrew leak:** configure reads Homebrew `.pc` files [I]. Closed by PKG_CONFIG_LIBDIR plus the otool -L gate.
- **msync:**
  - never confirmed on native arm64 [I];
  - the WINEMSYNC agreement rule means a stale wineserver in the other mode kills new clients [V];
  - the protocol bump means an old wineserver and a new ntdll refuse each other;
  - known correctness gaps (PulseEvent, wait-all) [V];
  - a realloc race past about 131k objects [I].
- **x18:**
  - subtle assembly;
  - a signal can land inside a toggle [I] (S3 should cover it);
  - rebase churn in signal_arm64.c.
- **0006 same-page livelock:** verified natively, inferred in Wine; it affects only native ARM64 JITs.
- **Entitled probes not run** (x18 cost, MAP_JIT at 4K, vm_kernel_page_size at 4K): no decision depends on them; they go into gates or the pages step.
- **Notarization with the restricted entitlement:** unknown until SP5 [I].
- **lsteamclient licence:** if the answer is no, Steam-API games stay on Rosetta. Kept out of SP3 so it cannot block the ship-base.

## 10. Skeptic verification of the load-bearing claims

Each claim was given to an independent verifier told to refute it. Every conclusion held; five claims were marked refuted for overstated or wrong supporting evidence. The corrections below supersede the text above where they differ.

### Claim 1: refuted (correction below)

[Verified] No Wine patch is needed to bundle FreeType and gnutls. Wine dlopens libfreetype.6.dylib and libgnutls.30.dylib by bare name (win32u/freetype.c:1457, schannel_gnutls.c:1474, crypt32/unixlib.c:111; config.h:755/:764). Every unix .so in wine.app carries LC_RPATH @loader_path/ (otool -l). Probe A (scratchpad/sp3/dlprobe) showed that under the hardened runtime a dylib beside the calling .so is found, while DYLD_LIBRARY_PATH and DYLD_FALLBACK_LIBRARY_PATH are ignored (probe D).

**Correction:** The conclusion stands: no Wine patch is needed to bundle FreeType and gnutls, provided the dylibs (and their rewritten dependencies) sit in lib/wine/aarch64-unix/ beside the calling .so files. Corrected evidence: Wine dlopens libfreetype.6.dylib and libgnutls.30.dylib by bare name at win32u/freetype.c:1457, dwrite/freetype.c:118, secur32/schannel_gnutls.c:1474 and crypt32/unixlib.c:111 (config.h:755/:764). All four callers (win32u.so, dwrite.so, secur32.so, crypt32.so) carry LC_RPATH @loader_path/, as do 28 of the 29 unix .so files in aarch64-unix and MacOS/ntdll.so. The exception, libarm64ecfex.so (FEX), has no LC_RPATH but loads neither library. Probe A (adhoc + runtime + disable-library-validation) finds a dylib beside the calling .so, and that dylib's @rpath dependency as well. Probe C's hardened main ignores DYLD_LIBRARY_PATH and DYLD_FALLBACK_LIBRARY_PATH. Probe D's main is not hardened (flags=0x2) and honours both variables, so do not cite it as evidence that they are ignored. Applying the ad-hoc probe results to Developer ID signing is an inference.

### Claim 2: refuted (correction below)

[Verified] Homebrew bottles cannot be bundled, so a pinned source build is required. freetype, libunistring, libpng and libintl have minos 26.0, which bundle.sh's 27.0 check rejects; gnutls links 10 dylibs by absolute /opt/homebrew install names (otool -l / otool -L).

**Correction:** [Verified] Homebrew bottles cannot be bundled unchanged. The freetype, libunistring, libpng and libintl (gettext) bottles have minos 26.0, which bundle.sh:78-79 rejects. libgnutls.30 refers to its own ID and its 8 Homebrew dependencies by absolute /opt/homebrew/opt names (13 load commands in all). [Verified] Both problems can be fixed with tools already installed: install_name_tool to switch to @rpath names, vtool to set minos, then a re-sign. This was tested on freetype and libpng, which then load and pass the 27.0 check. [Design choice / inferred] A pinned source build is still preferred, though not strictly required, because: (a) gnutls and p11-kit have /opt/homebrew/etc and Cellar paths for the trust store, config, PKCS#11 modules and locales built in, which no install-name rewrite changes, and they do not exist on users' Macs (whether this matters at runtime under Wine is unchecked); (b) vtool only changes the minos label on code built for macOS 26, so the 27.0 check no longer means "built for 27" (setting sdk 27.0 as well would misstate the SDK too); (c) bottles change whenever Homebrew updates, so they are not pinned, and meeting the LGPL source/relink obligations for gnutls, nettle, gmp, libidn2, libunistring and libtasn1 is simpler with pinned source tarballs.

### Claim 3: held

Claim 3 [Verified]: strict x18 toggling is cheap. It costs 1.41-1.54 ns per toggle on the M5 Pro, about 3 ns per syscall or unix-call round trip, against 82.6 ns for getppid() (scratchpad/sp3/x18cost.out, 21 x 200k iterations). The userspace path (libsystem_kernel plus a commpage routine) is the same entitled and unentitled; only the kernel's preservation of the bit differs.

**Correction:** No refutation; optional wording precision: "1.41-1.54 ns per toggle on M5 Pro P-cores (1.30-1.41 ns at background QoS; reproduced 1.47-1.58 ns on rerun), measured unentitled in a hot loop; two toggles about 3 ns per syscall/unix-call round trip, plus the register parking §5.3 adds (about 10 instructions). Userspace path entitlement-independent per XNU xnu-12377.121.6 source (x18.c:41-58, _libkernel_init.c:99-131, kern_exec.c:7068-7078) and live symbols; kernel gating per pcb.c:379-410 (live 27.0.1 kernel inferred to match)."

### Claim 4: refuted (correction below)

Claim 4: [Verified] Guest RWX memory under FEX never needs to be executable on the host: the G5 x64-bench log has 0 trace:wxflip lines for the whole process, and patch 0006 lowers RWX to read-write (virtual.c:1987-1990). [Verified] MAP_JIT as specified fails: MAP_JIT|MAP_FIXED gives EINVAL, mprotect on an RWX MAP_JIT range gives EACCES, and switching back to execute inside the fault handler is undone on return (scratchpad/sp3/mapjit-*.c). Dropping MAP_JIT from SP3 rests on both.

**Correction:** Suggested rewrite:

"[Inferred] FEX reads guest x64 code as data and never runs it on the host. Guest RWX memory without the EC_CODE flag therefore never needs host execute, and patch 0006 keeps it RW (virtual.c:1987-1990). G5 doesn't test this: x64-bench allocates only RW memory (x64-bench.cpp:50). Its 0 flips show only that FEX's own code memory, the dual view, doesn't flip. To verify this point, run x64-smc.exe under WINEDEBUG=+wxflip and expect 0 lines.

[Verified] MAP_JIT has these limits:
- MAP_JIT|MAP_FIXED gives EINVAL. A hint into a newly freed hole does work, but it races other allocators.
- Once a MAP_JIT range has been raised to RWX, every mprotect on it gives EACCES. VirtualProtect away from RWX, including FEX's write-protection for self-modifying-code tracking, can't be honoured without replacing the mapping.
- A switch to execute made inside the signal handler is undone on return. A switch to write sticks. A switch to execute made just after return, through a stub (sp3/c4/tramp.c), works at 5.6 us per write-then-run cycle, against 12.8 us for patch 0006's flip.

Dropping MAP_JIT for x64 guests rests on the inferred point above. Native ARM64/ARM64EC JIT memory, which does need host execute, stays on patch 0006's flips. SP3 should record that as an accepted cost or as deferred work, not count it as covered."

### Claim 5: held

Claim 5: [Verified] msync ports mechanically. A trial merge of cx/wine1117's msync onto Wine 11.19 + 0001-0014 had one conflict (loader.c, server_init_process(data)), and all 7 touched files pass -Wall -fsyntax-only (msync-on-11.19-trial.diff, syncheck.sh). Its private APIs work on Darwin 27 arm64 under the hardened runtime (msyncprobe.c). [Inferred] The performance gain (uncontended ops skip a wineserver round trip of 5 us or more) has not been measured in Wine. Measured cross-process wake latency is about equal: 6.3 us with ulock, 5.2 us with a pipe.

**Correction:** Not refuted. Suggested wording for precision: "A trial merge of cx/wine1117's msync (CrossOver 26.3 msync plus 8 msync commits from the dappermint/winecx fork) onto Wine 11.19 + 0001-0014 had one conflict. It is in loader.c start_main_thread: 11.19 calls server_init_process(data). Resolving it puts msync_init() before dbg_init(), which is safe because debug channels set themselves up on first use. The msync-only changes were picked by hand from CX's sync.c, loader.c and server_protocol.h. The diff touches 15 files. The 7 .c files, plus request.c and trace.c (which include the merged generated headers), pass -Wall -fsyntax-only. The private primitives work under the hardened runtime: ulock, bootstrap_register2/look_up, memory entries and direct mach_msg2_trap. This holds for a 16K client and for a 4K Rosetta client of a 16K server. It has not been tested with the real entitled posix_spawn 4K wine.app." The licence and credits row should name the fork's commits as well as CrossOver.

### Claim 6: held

Claim 6: [Verified] lsteamclient is under Valve's Steamworks SDK licence, not BSD-3 (local LICENSE blob 16381609e5 and Proton's proton_10.0 lsteamclient/LICENSE), and nothing in SP3's gate uses Steam; the first game that needs the Steam API, SMITE 2, is in SP6 (stack-map.md:358-359). Moving it to SP4 keeps that licence decision off the ship-base.

**Correction:** Not refuted. Precision fixes:
(a) Cite SMITE 2/SP6 as stack-map.md:361 and design doc :66, not stack-map.md:358-359. Those lines are the SP3 gate (358) and the SP4 gate (359).
(b) Write "nothing in SP3's gate uses the Steam API". If SP3's check reuses SP2's dxmt-x64 step, it still reads a DLL from SMITE 2's Steam install (acceptance-arm64-dxmt.md:9-10). That needs no lsteamclient.
(c) Mark "first game that needs the Steam API" as inferred from acceptance-app.md:23 (SMITE 2 can't find Steam) and acceptance-runtime.md:80 (Cats, SP5's gate, calls SteamAPI_Init and keeps running when it fails).
(d) Stronger framing: the first gate that needs lsteamclient is SP4's own (stack-map.md:359, steamprobe SteamAPI_Init), and design row 4 (:64) already lists ARM64X lsteamclient. So the change is really "drop lsteamclient from row 3". Upstream wine-11.19 has no dlls/lsteamclient, so keeping it in SP3 would mean importing winecx's four 2026-08-25 commits and their Steamworks-SDK-licensed directory into the ship-base wine.app.

### Claim 7: refuted (correction below)

Claim 7 [Verified]: closing the licence gap is mostly a matter of copying files that are already on disk. wine.app ships only DXMT's 3 licence files (bundle.sh:56). scratchpad/sp3/licences_check.sh prints 36 MISSING lines and exits 1. Wine 11.19 already ships a NOTICES.md that covers almost all of its vendored code, with GSM the only exception. Every other text is already local in the build trees.

**Correction:** wine.app ships only DXMT's 3 licence files (bundle.sh:56), and licences_check.sh prints 37 MISSING lines and exits 1. Of those, 19 are copies of texts already in build/: Wine LICENSE, COPYING.LIB and AUTHORS; Wine's own NOTICES.md; libs/gsm/COPYRIGHT and libs/faudio/LICENSE; FEX and its 8 compiled externals including cpp-optparse; LLVM LICENSE.TXT and COPYRIGHT.regex from build/dxmt-src/llvm-project; llvm-mingw LICENSE.TXT and COPYING.MinGW-w64-runtime.txt from build/dxmt-src/llvm-mingw. The other 18 lines have to be written: README, SOURCE with 6 keys, and a top-level NOTICES.md with 9 copyright holders taken from source headers (SoftFloat's Regents of UC, VIXL, Madeira's Will Faust, and others). Wine 11.19's NOTICES.md covers its vendored libraries except GSM and FAudio. Both of those ship (msgsm32.acm, xaudio2_7.dll), and both texts are in wine/libs. Sub-project 3's new libraries are not covered by texts on disk. FreeType FTL.TXT and nettle COPYINGv3 are not on disk, lsteamclient's LICENSE exists only in the scratchpad, and the gnutls chain (libtasn1, libidn2, libunistring, p11-kit, libintl) plus FreeType's libpng is not in the check at all. So the gap grows when those dylibs are added, and their texts must come with the pinned source tarballs.

### Claim 8: refuted (correction below)

Claim 8: GMP must stay at 6.3.0 or later and the bundled-dylib x18 scan is a permanent gate. GMP 6.2.1's arm64 assembly used x18. With the custom-x18 mode OFF, the kernel zeroes x18 at exception return (locore.s:1918-1922, XNU 12377), so a library that uses x18 as scratch breaks under both the current and the strict design.

**Correction:** GMP must stay at 6.3.0 or later, and the bundled-dylib x18 scan stays a permanent gate, because sub-project 3's strict design runs unix calls with the x18 mode OFF.

GMP 6.2.1's mpn/arm64 assembly used x18 as a loop counter. The fix (gmplib changeset 5f32dbc41afc, 2020-11-29) came after 6.2.1 was released. Verified absent in 6.3 for aors_n.asm and lshift.asm; the other nine changed files are inferred.

With the mode OFF, the kernel zeroes x18 at exception return and reloads it only when the TPIDR_EL0 preserve bit is set. Source: xnu-12377.121.6 locore.s:1924-1929. On macOS 27 (xnu-13432, no source available), the project's OFF/ON probe shows this directly: x18 lost 200/200 OFF, kept 200/200 ON.

Under the current once-per-thread design (signal_arm64.c:1628-1629), such a library is harmless on PE threads:
- the kernel preserves x18 while the mode is ON;
- Wine's unix side gets the TEB from pthread TLS;
- the dispatchers reload x18 from the frame before returning to PE code.

Today it would break only on threads that never turn the mode ON. So the GMP pin and the scan become required when strict toggling lands; they are not already required.

