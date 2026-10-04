## x18
The strict x18 toggle is cheap: about 1.4-1.5 ns per toggle on this M5 Pro, so about 3 ns per syscall or unix-call round trip (about 6 ns with register-preserving helpers), against 83 ns for a real getppid() syscall. The toggle runs in userspace: the function in libsystem_kernel plus a commpage routine, with a syscall only when a preemption is pending. It can be called without the entitlement, but the kernel then clears the bit at every context switch, so only the entitled wine.app benefits. The cost numbers hold for it because the userspace path is the same. The transition map in x18-boundaries.md is correct but uses pre-patch line numbers; the remapped list and three additions are above. The additions: (1) the global __wine_syscall_dispatcher_return reads x18 while OFF (:1893); (2) Wine's trap_handler would turn a toggle-imbalance brk #1 into a Windows exception, so the wrapper must pass it through (verified by probe); (3) a gated 'PE stack must be ON' check makes missed ON sites loud. ARM64EC and FEX add no new boundary: FEX never allocates x18, reads it only as the TEB, imports only ntdll, and reaches unix code only through Wine's two dispatchers. Signals are the only asynchronous Apple entry on a PE thread: handlers inherit the mode, and sigreturn leaves it unchanged. Metal and Cocoa completion handlers run on their own threads, which start OFF. The wrapper cannot ship later than the dispatcher toggles, because OFF handlers redirect into PE. Recommendation: one patch of about 120 lines replacing 0004, plus a per-path test program. No downloads and no new licences. Artifacts: /private/tmp/claude-501/-Users-chad-Documents-MacProton/4df1af36-0116-433f-917f-5078e899b9af/scratchpad/sp3/x18cost.c, x18cost.out, x18cost.dis, trappass.c, trappass.out.

## msync
msync is a small, self-contained macOS backend for the in-process sync framework that upstream Wine already has (server/inproc_sync.c plus the inproc_* paths in ntdll/unix/sync.c). Upstream only implements that framework on Linux, through ntsync. msync fills the same `#elif defined(__APPLE__)` slot with shared memory, __ulock_wait2/__ulock_wake and a Mach message pump in wineserver. In CrossOver's tree (cx/wine1117; the files are byte-identical on arm64-1117) it is 4 new files of 2,202 lines, plus about 270 lines of hooks in 11 existing files. It is LGPL-2.1-or-later (Zebediah Figura 2018, Marc-Aurel Zent 2023) and is on only when WINEMSYNC=1 is set. The Rosetta runtime-v4.7.3 is the same code, including dappermint's 2026-08-21 tuning commits.

I trial-merged an msync-only extract onto the build tree's HEAD (11.19 plus patches 0001-0014). There was one conflict, a one-line fix in loader.c because server_init_process now takes `data`. All 7 touched files then pass a syntax-only compile (`-Wall -fsyntax-only`) against the tree's config.h, with no warnings.

The arm64 concerns check out:
- **Native and hardened runtime:** a probe built ad-hoc with `-o runtime` ran every private call msync uses on Darwin 27 arm64.
- **4K/16K pages:** both sides size their shared memory with vm_kernel_page_size, which is read system-wide. A 4K Rosetta client reports 16384 and works against a 16K server.
- **x18:** `GetCurrentThreadId()` in unix code goes through `pthread_getspecific`, not x18, so strict x18 toggling does not affect it.
- **ARM64EC, WoW64, FEX:** msync runs only in ntdll.so and wineserver, so these are not affected.

msync is for speed, not correctness. Upstream's server-based sync is the correct reference. msync knowingly gives up some correctness (PulseEvent can be lost; wait-all can briefly take objects), and CodeWeavers ships it off by default.

Its gain is in operations with no contention, and in keeping the single-threaded wineserver out of the hot path. It does not make a sleeping wake faster: cross-process wake latency was about 6.3 µs with ulock against 5.2 µs with pipes.

Recommendation: ship it as patch 0015, default-on to match the Rosetta runtime, with the existing per-game toggle. Two hard rules come with it: the client and wineserver must agree on WINEMSYNC (otherwise the client exits), and an A/B test needs `wineserver -k` between modes. Gate it with a sync stress test. Effort is about 3 days. Nothing needs downloading.

## freetype-gnutls
Recommendation: build FreeType 2.14.3 and gnutls 3.8.13 (with nettle 4.0 and gmp 6.3.0) from pinned source tarballs as arm64 libraries with minos 27.0. Fold nettle and gmp into libgnutls statically, give both libraries @rpath install names, and copy them into Contents/Resources/lib/wine/aarch64-unix/. That needs no Wine patch: Wine loads them by bare filename (libfreetype.6.dylib, libgnutls.30.dylib), and dyld finds them through the `@loader_path/` rpath every unix .so already carries. A native probe confirmed this, and also that DYLD_FALLBACK_LIBRARY_PATH and DYLD_LIBRARY_PATH are ignored under our hardened runtime.

Today Wine 11.19 is configured against Homebrew's headers, but wine.app ships neither library, so both loads fail. Without FreeType, GDI text and dialogs don't render; patch 0014 only covers the crash. Without gnutls, the schannel TLS provider is never registered, so HTTPS through Windows APIs fails, and crypt32 loses PFX import. bcrypt now runs on bundled SymCrypt and needs no gnutls. Root certificates come from Security.framework, so p11-kit, libidn2 and a CA bundle can all be left out.

Homebrew bottles are rejected: four have minos 26.0, which fails bundle.sh, and gnutls drags in ten libraries with absolute /opt/homebrew paths. mini-gmp is rejected: up to 10× slower, with no licence gain. GMP must be at least 6.3.0 because 6.2.1's arm64 assembly uses x18, which matters while x18 still holds the TEB. The same versions built by Homebrew show zero x18 instructions, and I propose an x18 scan of the bundled libraries in bundle.sh.

The x86_64 Rosetta runtime ships the full set, all x86_64 with minos 11.3: gnutls 3.8.9 with nettle 3.10, gmp, tasn1, idn2, unistring, p11-kit and intl; FreeType with png, brotli and bz2; plus FFmpeg, GStreamer, MoltenVK and krb5. It carries no licence files for them.

Of the other optional features the arm64 build lacks, only media playback (FFmpeg/GStreamer) has high game impact, and I suggest a separate roadmap item for it. Vulkan, SDL2 and inotify are low, and the rest don't matter for games.

Licences: FreeType under the FTL, which requires a credit line. gnutls is LGPL-2.1+, and nettle and gmp are LGPL-3+ or GPL-2+. Ship each licence text under Resources/licenses/ (along with the still-missing Wine and FEX texts), and publish the exact source tarballs and build scripts.

## lsteamclient
The roadmap names lsteamclient twice, but row 3's "lsteamclient" and row 4's "ARM64X lsteamclient" are the same artifact. Once lsteamclient is in Wine's tree, the normal `--enable-archs=arm64ec,aarch64` build produces both the ARM64X DLL and the aarch64 .so. The split comes from when the base was going to be CrossOver arm64-1117, which already carries lsteamclient.

**Recommended boundary:**
- Take lsteamclient out of sub-project 3. Nothing there uses it: SP3's gate runs wineboot and present_loop with no Steam, and the first game that needs the Steam API (SMITE 2) comes in sub-project 6.
- Sub-project 4 owns the rest:
  - a pinned build-time fetch of Proton's lsteamclient, without the SDK header folders;
  - winecx's three small Mac patches and the configure registration;
  - the bundle, with its LICENSE;
  - an aarch64 steam.exe;
  - the probe and check scripts in an arm64 mode;
  - a scan of Steam's arm64 code for x18 use.
- Sub-project 4 builds on sub-project 1 and can run alongside sub-project 3.
- Launcher wiring goes to sub-project 5, the 32-bit client to sub-project 8, and the overlay to sub-project 6.

**What I checked:**
- Mac Steam's `steamclient.dylib` and its dependencies are universal (x86_64 + arm64). The arm64 slice loads in a native arm64 process and hands out `SteamClient006`–`023`. Loading it installs no crash handlers, at least up to the point of asking for an interface.
- lsteamclient builds for arm64 without source changes. All 44 PE source files compile for arm64ec and aarch64. All 219 unix C++ files compile for macOS arm64, including 7,251 struct-layout asserts that all pass. A probe link of the unix side needs only symbols that our ntdll.so already exports. I did not link or run the PE side.
- Valve's arm64 code does not use x18: all 552 x18 sites in `steamclient.dylib` are crypto constant tables or other data, so calling it under sub-project 1's once-per-thread x18 mode is safe.
- `disable-library-validation`, which is already in `wine.entitlements`, is required for this path, because Valve signs the dylib with its own team ID.

**The main blocker is the licence.** lsteamclient is under Valve's Steamworks SDK licence, not BSD-3. winecx's import commit calls it LGPL-2.1, which contradicts the LICENSE file that commit adds. Shipping it in our signed `wine.app` would reverse the bridge spec's position that MacNeutron doesn't redistribute it. The maintainer has to decide this before any import. If the answer is no, Steam-API games stay on Rosetta.

lsteamclient is about 398,000 lines (18.4 MB), almost all generated; it wraps every Steam interface version. The work is about one week.

Probe scripts and outputs are in `/private/tmp/claude-501/-Users-chad-Documents-MacProton/4df1af36-0116-433f-917f-5078e899b9af/scratchpad/sp3`:
- `probe-pe.sh` and `probe-unix.sh` (compile probes)
- `scload.c` and `schandlers.c` (load and crash-handler probes)
- `x18-steam-scan.py` (the x18 scan)
- `lsteamclient/` (the extracted source)

## jit-rwx
You don't need this item for 64-bit x64 games, and the planned MAP_JIT design doesn't work, so I recommend taking it out of SP3. Guest PAGE_EXECUTE_READWRITE (RWX) memory under FEX never needs to be executable on the host. Wine's patch 0006 already turns it into host read-write memory. FEX handles self-modifying code by protecting such a page read-execute and catching the access violation on the next write, and that never goes through 0006's flip. The whole G5 x64-bench process logged 0 wxflip lines, including Wine's own startup. Probes on this Mac (macOS 27.0.1, M5 Pro, unentitled, ad-hoc signed, 16K pages) found three problems with "MAP_JIT plus a per-thread toggle on fault": (1) switching back to execute inside the fault handler is undone when the handler returns, so the fault repeats forever; (2) once a MAP_JIT range is RWX, every mprotect on it fails with EACCES, which breaks VirtualProtect, guard pages and FEX's own self-modifying-code trap; (3) MAP_JIT combined with MAP_FIXED fails with EINVAL, and so do shared and file-backed MAP_JIT, so it can't go at the fixed addresses Windows asks for, nor into sections or images. Even if it did work, it would be at best about 2x faster for JITs that don't know about MAP_JIT (two faults at about 2.2 µs each, against 9 µs for 0006's flip). The 23 ns figure only applies to a JIT that switches modes itself. A dual view can't serve memory the game itself writes and runs through the same pointer; it only helps for a JIT we control. What still goes through 0006's flips: FEX's own 32-bit (WoW64) build, which still uses RWX code memory (so SP8 should port the dual view to it); native ARM64 JITs, which are rare (AnyCPU .NET apps already run as x64 under FEX); and minor Wine cases (missing-import stubs, executable heaps). I also found a latent correctness bug in 0006: native code that stores into its own page loops forever. Recommendation: keep 0006, drop MAP_JIT from roadmap row 3, add one check step showing that x64 self-modifying code causes 0 flips, and decide whether the same-page loop should be documented or fixed. Effort: about 1 day. No downloads, no new licences.

## licences
wine.app ships notices only for DXMT. It lacks those for Wine, FEX and its 8 compiled externals, LLVM 15 (statically in winemetal.so) and the mingw-w64 runtime (inside DXMT's DLLs), plus code that FEX and DXMT vendor in source headers (SoftFloat, VIXL, musl, DXBCParser). Wine 11.19's NOTICES.md covers almost all of Wine's own vendored code, except GSM.

Recommendation:
- **Layout:** a per-component `Resources/licenses/` tree copied from the source trees, plus one committed NOTICES.md for the header-only notices, a generated SOURCE file naming every pinned input, and `DXMT/` left where it is.
- **bundle.sh asserts:** each file is present, each holder is named, a drift gate on FEX's externals, a licence directory for any newly added dylib, timestamps on every Mach-O, and no get-task-allow.
- **LGPL source:** satisfied by the public repo plus source archives in the same release. No written offer is needed.
- **Notarization:** stays in sub-project 5. All prerequisites are already met today (Developer ID, hardened runtime, timestamps, a Developer ID profile); only a real submission can settle the restricted-entitlement risk.

The ready check script is in the scratchpad: red on today's bundle (36 gaps), with only DXMT passing.

