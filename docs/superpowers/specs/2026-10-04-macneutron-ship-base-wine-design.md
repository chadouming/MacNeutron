# MacNeutron — Native arm64 stack, sub-project 3: Ship-base Wine

- **Date:** 2026-10-04
- **Status:** Written for the maintainer's review. The design was approved in conversation on 2026-10-04 ("Go"), with four decisions taken by the maintainer (§1, Decisions). The implementation plan comes after the maintainer approves this file.
- **Builds on:**
  - `2026-10-02-macneutron-native-arm64-design.md` (sub-project 1 and the roadmap; this spec amends its §2, §3.4, §5.3 and §11, see §13)
  - `2026-10-03-macneutron-arm64-dxmt-design.md` (sub-project 2: DXMT in `wine.app`, the check steps this spec extends)
- **Evidence:** `docs/research/2026-10-04-ship-base/` (the decision brief with its skeptic verification, the probes, the msync trial merge, the scratch licence check).
- **Scope:**
  - **In:**
    - licence and notice files for every component `wine.app` ships;
    - FreeType and gnutls built from pinned source and bundled;
    - msync, ported from CrossOver `cx/wine1117`, on by default;
    - a check proving x64 JITs under FEX cause no W^X flips;
    - strict x18 toggling, replacing patch 0004.
  - **Out:**
    - lsteamclient and the whole Steam path, including the Steamworks licence decision (sub-project 4, which now depends only on sub-project 1);
    - media playback: FFmpeg for `winedmo`, GStreamer for `winegstreamer` (a new roadmap row, §13);
    - `MAP_JIT` or a dual view for native ARM64 JITs (dropped; §7 records the accepted cost);
    - FEX's 32-bit WoW64 JIT dual view (sub-project 8);
    - notarization, release source archives, and refusing development inputs in release bundles (sub-project 5);
    - the Rosetta app's missing LLVM and mingw-w64 notices (a separate small change);
    - pushing anything anywhere.

## 1. Goal

`wine.app` becomes a base that could ship: Windows text and dialogs render, TLS through Windows APIs works, synchronisation is as fast as on the Rosetta runtime, x18 follows Apple's documented rule, and every component's licence travels with it.

**Sub-project 3 is done when** §9's gates S1–S6 pass on the maintainer's Mac, M1–M2 are measured, and the result is recorded in `docs/testing/acceptance-arm64-ship-base.md`.

### Decisions

| Decision | Choice |
|---|---|
| lsteamclient | **Moved to sub-project 4** with the Steamworks licence question (lsteamclient is under Valve's Steamworks SDK licence, not BSD) (maintainer, 2026-10-04) |
| `MAP_JIT` for RWX memory other than FEX's | **Dropped.** Replaced by the `wxflip-x64` check; native ARM64 JITs stay on patch 0006's flip as an accepted cost (maintainer) |
| Downloads | **Approved:** freetype 2.14.3, gnutls 3.8.13, nettle 4.0, gmp 6.3.0 from their canonical hosts, SHA-256 pinned (maintainer). Nothing else is downloaded |
| msync default | **On**, matching the Rosetta runtime (maintainer). `WINEMSYNC=1` is set by whatever starts the runtime: `check.sh` here, the launcher in sub-project 5; `WINEMSYNC=0` per game stays the off switch |
| msync source | CrossOver `cx/wine1117` (26.3) with dappermint `winecx`'s 2026-08-21 race and tuning commits: the code the Rosetta runtime runs. Plus a one-time `shm_addrs` allocation that removes a realloc race |
| Where the libraries live | `Contents/Resources/lib/wine/aarch64-unix/`, beside the unix `.so` files that load them: Wine loads them by bare name and every caller carries `LC_RPATH @loader_path/`, so no Wine or loader change |
| Library packaging | nettle, hogweed and gmp linked statically into `libgnutls.30.dylib`: 2 dylibs. Fallback if libtool won't fold them: 5 dylibs with `@rpath` names |
| FreeType options | No libpng, harfbuzz or brotli (colour-emoji glyphs aren't worth a fifth download) |
| Licence elections | FreeType under the FTL; nettle, gmp and gnutls's included libunistring under LGPL-3+; gnutls and its included libtasn1 under LGPL-2.1+ |
| Wine configure | Against our deps only (`PKG_CONFIG_LIBDIR`), with `--with-freetype --with-gnutls` so a missing header fails configure |
| x18 dispatch code | Registers parked in the dispatchers (about 3 ns per round trip); register-preserving helpers are the fallback |
| A toggle imbalance | Kills the process (`SIGTRAP` passed through with Apple's annotation), never becomes a Windows exception |
| "PE stack implies x18 ON" invariant | Always checked in the signal wrapper (one comparison per signal); a violation logs and aborts |
| Patch authorship | The maintainer as author; the commit message credits the sources (msync: Marc-Aurel Zent, CodeWeavers CrossOver 26.3, dappermint `winecx` `e0aa380780`) |
| Wine conformance tests | Not built; `x64-sync.c` gates msync |
| Time box | Three weeks from the start of implementation (estimate 8–9 working days) |

## 2. Evidence (verified 2026-10-03/04 on the M5 Pro, macOS 27.0.1, unless marked)

- **No FreeType, no gnutls today.** Wine 11.19 was configured against Homebrew's headers (`config.h`: `SONAME_LIBFREETYPE "libfreetype.6.dylib"`, `SONAME_LIBGNUTLS "libgnutls.30.dylib"`), but `wine.app` ships neither. Wine `dlopen`s them by bare name from `win32u/freetype.c:1457`, `dwrite/freetype.c:118`, `secur32/schannel_gnutls.c:1474` and `crypt32/unixlib.c:111`, so all four loads fail: dialog base units are 0,0, and `AcquireCredentialsHandleW(UNISP_NAME_W)` returns `0x80090305`. bcrypt runs on PE-side SymCrypt and root certificates come from Security.framework, so p11-kit, libidn2 and a CA bundle aren't needed.
- **Bundling works without a patch.** All four callers carry `LC_RPATH @loader_path/`; a hardened-runtime probe found a dylib beside the calling `.so`, and that dylib's own `@rpath` dependency. A hardened main ignores `DYLD_LIBRARY_PATH` and `DYLD_FALLBACK_LIBRARY_PATH`.
- **Homebrew bottles don't fit as they are:** four have `minos 26.0`, and `libgnutls.30` names 8 dependencies by absolute `/opt/homebrew` paths, with Homebrew paths compiled in for its trust store and modules. A pinned source build also makes the LGPL source obligations simple.
- **gmp 6.2.1's arm64 assembly used x18** as a loop counter (fixed after 6.2.1, gmplib changeset `5f32dbc41afc`). Under strict toggling, unix code runs with the mode OFF and the kernel zeroes x18 at exception return, so a library that uses it breaks. gmp ≥ 6.3.0, and a scan of every bundled dylib, are required from §8 on.
- **Licences:** `wine.app` ships only DXMT's 3 files. The scratch check (`licences_check.sh`) prints 37 MISSING lines: 19 are copies of texts already in `build/` (Wine, FEX and its 8 compiled externals, LLVM, llvm-mingw); 18 must be written (README, SOURCE, a NOTICES file for notices that live only in source headers). Wine's own `NOTICES.md` covers its vendored code except GSM and FAudio, which both ship.
- **msync:** in CrossOver it is 4 new files (2,202 lines) and about 270 lines of hooks in 11 files, LGPL-2.1+. It fills upstream Wine's in-process sync framework on macOS (upstream only has Linux ntsync, so every wait on our runtime is a wineserver round trip). A trial merge onto 11.19 + patches 0001-0014 had one conflict (`loader.c`), and the 7 touched files compile with `-Wall` and no warnings. Every private API it uses works across two hardened-runtime processes on Darwin 27 arm64. Client and wineserver must agree on `WINEMSYNC`, or the client exits. Whether msync has ever run natively on arm64 is not known.
- **msync is for speed.** Cross-process wake latency is about the same either way (about 6.3 µs with `__ulock` against 5.2 µs for a pipe round trip). The gain is in uncontended operations and in keeping the single-threaded wineserver off the hot path (inferred; §9's M1 measures it). Known correctness gaps: PulseEvent can miss a waiter; wait-all isn't atomic.
- **x18:** one toggle costs 1.41–1.54 ns (userspace path, the same entitled or not), so about 3 ns per syscall or unix-call round trip, against 82.6 ns for a `getppid()` syscall. FEX never allocates x18, reads it only as the TEB, and reaches unix code only through Wine's two dispatchers, so ARM64EC and FEX add no boundary. Three sites `x18-boundaries.md` lacks: `__wine_syscall_dispatcher_return` reads x18 while OFF; Wine's trap handler would turn the toggle's `brk #1` into a Windows exception; and an invariant check makes a missed ON site loud.
- **MAP_JIT doesn't fit Windows memory:** `MAP_JIT|MAP_FIXED` fails (EINVAL); once a MAP_JIT range is RWX, every `mprotect` on it fails (EACCES); a switch to execute inside the fault handler is undone on return. At best a trampoline design costs 5.6 µs per write-then-run cycle against patch 0006's 12.8 µs.
- **x64 JITs under FEX probably never flip (inferred).** FEX reads guest code as data; patch 0006 keeps guest RWX without the EC_CODE flag as host RW. Gate G5 doesn't prove it (x64-bench allocates only RW memory); §7's check does.

## 3. What changes in the bundle

```
wine.app/Contents/Resources/
  lib/wine/aarch64-unix/libfreetype.6.dylib     (new: FreeType 2.14.3, arm64, minos 27.0, @rpath id)
  lib/wine/aarch64-unix/libgnutls.30.dylib      (new: gnutls 3.8.13 + nettle 4.0 + gmp 6.3.0, same)
  lib/wine/aarch64-unix/ntdll.so, wineserver    (msync; strict x18)
  licenses/README  licenses/NOTICES.md  licenses/SOURCE
  licenses/{wine,fex,llvm,llvm-mingw,freetype,gnutls,nettle,gmp}/…
  DXMT/…                                        (unchanged)
```

Wine patches after this sub-project: 0001–0003 and 0005–0014 unchanged; 0004 replaced by the strict x18 patch; one new patch for msync. Numbers follow landing order.

## 4. Licences (no downloads)

- **One tree:** `Resources/licenses/<component>/`, filled by `bundle.sh` with its `put` helper:
  - `wine/`: `LICENSE`, `COPYING.LIB`, `AUTHORS`, `NOTICES.md`, `gsm-COPYRIGHT`, `faudio-LICENSE`;
  - `fex/`: `LICENSE` and one `<external>-LICENSE` per compiled external (fmt, xxhash, tiny-json, cpp-optparse, unordered_dense, rpmalloc, range-v3, cephes);
  - `llvm/`: `LICENSE.TXT`, `COPYRIGHT.regex` (LLVM 15 is linked statically into `winemetal.so`);
  - `llvm-mingw/`: `LICENSE.TXT`, `COPYING.MinGW-w64-runtime.txt` (in DXMT's DLLs and `winemetal.dll`);
  - `freetype/`, `gnutls/`, `nettle/`, `gmp/` once §5 lands, from the source tarballs (FreeType's `LICENSE.TXT` and `FTL.TXT`; the LGPL and GPL texts the elections name).
- **Committed** `wine-arm64/licenses/NOTICES.md`: the notices that exist only in source headers (SoftFloat's Regents of the University of California, VIXL, musl, Arm, Will Faust (Madeira's MIT grant), Microsoft's DXBCParser, and the others the brief lists). **Committed** `wine-arm64/licenses/README`: component → licence → where its source is (this repository's pins and patch files, and the upstream URLs), plus the FreeType credit sentence. MacNeutron's own code gets a line once the repository has a licence (to be decided before sub-project 5's first release).
- **Generated** `licenses/SOURCE` by `build.sh`: each pin (Wine, FEX with the 8 externals' submodule commits, DXMT, LLVM, llvm-mingw, the four tarballs with URL and SHA-256) and each tree's patch-series hash.
- **`bundle.sh` asserts:** every listed file exists and is non-empty; `NOTICES.md` names each expected holder; `fex-ec/External` holds only the 8 allowlisted externals (a new one fails the build until its licence is added); each bundled third-party dylib has its folder; `SOURCE` has every key.
- **Test:** `licences_check.sh` becomes `wine-arm64/tests/licences_test.sh`, run by `make wine-arm64-check` before `check.sh` (like `mode_test.sh`): red today (37 MISSING), green after.
- The repository README gets the FreeType credit line.

## 5. FreeType and gnutls

- **Pins** in `wine-arm64/pins`: URL and SHA-256 for each tarball:

  | Pin | URL | SHA-256 |
  |---|---|---|
  | freetype 2.14.3 | `https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.xz` | `36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f` |
  | gnutls 3.8.13 | `https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz` | `ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e` |
  | nettle 4.0 | `https://ftp.gnu.org/gnu/nettle/nettle-4.0.tar.gz` | `3addbc00da01846b232fb3bc453538ea5468da43033f21bb345cb1e9073f5094` |
  | gmp 6.3.0 | `https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz` | `a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898` |

  The SHA-256 values come from Homebrew's API cache on this Mac; the first fetch also checks each tarball against its upstream signature, and the plan records how. Fallback if nettle 4.0 won't build with gnutls 3.8.13: nettle 3.10.2 (a fifth pin, approved only if needed).
- **Fetch:** the download-and-checksum helper `fetch` moves from `dxmt/lib.sh` into a sourced file both build scripts use (it calls the caller's `die`), as `dxmt/llvm.sh` did for LLVM. Tarballs go to `build/wine-arm64-src/`.
- **Build** (a new `build.sh` step before Wine's configure; `/usr/bin/clang`, `MACOSX_DEPLOYMENT_TARGET=27.0`, prefix `build/wine-arm64-src/deps`; redone only when these pins change, recorded in `deps/.complete`):
  - gmp and nettle: static, PIC;
  - gnutls: shared, `--with-included-libtasn1 --with-included-unistring --without-p11-kit --without-idn --without-tpm --without-tpm2 --without-zlib --without-brotli --without-zstd --without-leancrypto --disable-nls --disable-tools --disable-cxx --disable-doc --disable-tests --disable-libdane`, nettle, hogweed and gmp folded in;
  - freetype: shared, system zlib and bzip2, `--without-png --without-harfbuzz --without-brotli`;
  - `install_name_tool -id @rpath/<name>` on both dylibs.
- **Wine's configure** runs with `PKG_CONFIG_LIBDIR=<deps>/lib/pkgconfig` and `--with-freetype --with-gnutls`. `build.sh` records the configure inputs (the line, the deps' `.complete`) in `wine-build/` and reconfigures when they change (this forces one full Wine rebuild).
- **`bundle.sh`** copies both dylibs to `lib/wine/aarch64-unix/` before signing, and asserts:
  - `otool -D` is `@rpath/libfreetype.6.dylib` and `@rpath/libgnutls.30.dylib`;
  - every `otool -L` entry of every Mach-O in the bundle starts with `/usr/lib/`, `/System/`, `@rpath/`, `@loader_path/` or `@executable_path/` (also catches a Homebrew leak anywhere);
  - no x18 use in either dylib (the regex of `docs/research/2026-10-02-native-arm64/probes/x18-cache-scan.sh` over `otool -tV`);
  - every symbol Wine resolves from them (70 for gnutls, 46 for FreeType) is exported (`nm -gU`);
  - `minos 27.0` (the existing loop already covers them).
- **Check step `fonts-tls`:** `wine-arm64/tests/arm64-fonts-tls.c` (aarch64 PE) creates `Tahoma`, prints `GetTextMetricsW`'s height, `GetTextExtentPoint32W(L"Hello")` and `GetDialogBaseUnits()`, all > 0, and `schannel: 0x00000000` from `AcquireCredentialsHandleW(UNISP_NAME_W, SECPKG_CRED_OUTBOUND)`; it ends `PASS arm64-fonts-tls`. The step also fails if the run's output holds `cannot find the FreeType` or `Failed to load libgnutls`. Before §5 lands, the same program shows dialog base units 0,0 and `0x80090305` (the red run, recorded).
- **Patch 0014 stays** as a safety net: a missing font library then degrades to no text, not a crash.

## 6. msync

- **One Wine patch**, server and ntdll together (they share a protocol change):
  - the 4 msync files verbatim from `cx/wine1117`;
  - the msync hunks of the trial merge (`msync-on-11.19-trial.diff`), with `msync_init()` after `server_init_process( data )` in `loader.c`;
  - `linux_wait_objs` takes the wait type and passes `type != WaitAll` (it works today only by accident);
  - the one-time `shm_addrs` allocation (a 2 MB table, no realloc) on both sides;
  - `tools/make_requests` regenerated, with the `SERVER_PROTOCOL_VERSION` bump (a reply grows from 16 to 24 bytes).
- **Enabling:** `WINEMSYNC=1`, as on the Rosetta runtime; the patch keeps CrossOver's semantics (off when unset). `check.sh` sets `WINEMSYNC=1` for every run (`wine_run`, the DXMT lanes through `dxmt/check.sh`'s arm64 runner, every direct `wine` call), so the server and every client agree; the `msync` step switches modes with `wineserver -k` between them.
- **Check step `msync`:** `wine-arm64/tests/x64-sync.c`, built as x64 (under FEX) and, by an extra Makefile rule, as ARM64EC (`arm64ec-sync.exe`); each runs with `WINEMSYNC=1` and with `WINEMSYNC=0`:
  - gated rows: event ping-pong; semaphore counts and `ERROR_TOO_MANY_POSTS`; mutex `ERROR_NOT_OWNER` and `WAIT_ABANDONED`; wait-any returns the lowest signalled index; wait-all exclusivity; a mixed wait with a process handle; timeouts; an alertable APC; cross-process named objects and `DuplicateHandle`; more than 3,000 events (several shared-memory chunks) across processes; 200,000 create/close cycles with no `msync: error` line;
  - mode rows: `msync: up and running.` appears only with `WINEMSYNC=1`; a client started with the other mode against a running server exits non-zero with msync's own message;
  - reported, not gated: PulseEvent, and the timing rows (§9, M1).
- **Rebuild cost:** the protocol bump and the reconfigure of §5 each force a full Wine rebuild; the plan may take both in one rebuild.

## 7. JIT memory: the zero-flip check

- **Check step `wxflip-x64`** (in `NEEDS_FEX`): `WINEDEBUG=+wxflip` `x64-smc.exe` under FEX prints `PASS x64-smc`, with 0 `trace:wxflip` lines. `x64-smc` allocates `PAGE_EXECUTE_READWRITE` memory and makes its own `.text` RWX, then rewrites and runs code in both. `arm64-wxflip`'s 19 flips remain the positive control.
- **If the check shows flips,** the inference in §2 is wrong and the plan stops to re-scope this item with the maintainer (the dropped `MAP_JIT` work would come back, as a new decision).
- **Accepted and documented:** native ARM64/ARM64EC JITs (rare in games today) stay on patch 0006's flip; and patch 0006 loops forever on native ARM64 code that stores into its own RWX page (verified natively; inferred inside Wine; no target game does this).

## 8. Strict x18 (replaces patch 0004)

One patch to `dlls/ntdll/unix/signal_arm64.c`, following `docs/research/2026-10-02-native-arm64/x18-boundaries.md` (whose line numbers predate patches 0001–0014: add 3 for its lines 58–1621 and 8 after them):
- **OFF** on syscall and unix-call entry, at the dispatchers' kernel-stack labels; **ON** before the x18 reloads on return to PE code, and before user-callback entry.
- The x18 reads that would run while OFF move earlier; `__wine_syscall_dispatcher_return` reads the TEB from the frame (`[sp,#0x90]`), not x18.
- Registers are parked in the dispatchers around each toggle.
- **A wrapper on the nine signal handlers:** it turns the mode ON when the interrupted code ran PE (and back for the handler's own unix work as the doc defines); it passes the toggle's `brk #1` through (`SIGTRAP` back to `SIG_DFL`, then return) so an imbalance kills the process with Apple's annotation; and it checks "PE stack implies ON" on every signal (`ERR` and `abort` on a violation). The wrapper lands in the same patch as the dispatcher toggles, because handlers that run OFF redirect into PE code.
- About 110–140 lines (the earlier 80–100 missed the three additions).
- **Check step `x18`:**
  - T1: `arm64-x18v.exe`, 72 threads for 3 s each, 0 x18 mismatches;
  - T2: `x18path`, built aarch64 and x86_64 (under FEX), one line `ok <path>` per path: SEH access violation, `__debugbreak`, SIGILL, Suspend/Get/SetThreadContext, a SendMessage callback, `NtReadFile` into an unmapped buffer, an APC, 1,000 thread create/exit cycles, a raw `syscall`, a FEX-suspended thread; 0 mismatches and no `PE stack running OFF` lines;
  - T3: a negative program that enables the mode twice must die by `SIGTRAP` with Apple's annotation (exit 133 or a signal status), not as a Windows exception;
  - a static check: `otool -tV ntdll.so` shows x18 used only inside the dispatcher, callback and dispatcher-return routines, each within an ON window.
- **Measured, not gated (M2):** the round-trip cost against patch 0004 (an A/B on two builds, once, during development), expected ≤ 4 ns per syscall round trip.
- `probes/x18-cache-scan.sh` keeps running on every macOS beta (it still guards `_sigtramp`).

## 9. Gates

| Gate | Pass |
|---|---|
| **S1 Licences** | `licences_test.sh` passes; `bundle.sh`'s licence asserts pass |
| **S2 Text and TLS** | `fonts-tls` passes; `bundle.sh`'s library asserts (install names, dependency paths, x18 scan, symbols) pass |
| **S3 msync** | `msync` passes in both lanes and both modes |
| **S4 No flips** | `wxflip-x64` shows 0 flips and `PASS x64-smc` |
| **S5 Strict x18** | `x18` passes (T1–T3 and the static check); patch 0004 is gone |
| **S6 No regressions** | Every sub-project 1 and 2 step passes under `WINEMSYNC=1`, including both DXMT lanes and `dxmt-present`; `make test` and `make dxmt-check` pass; `PASS orphans` |
| **M1 msync** (measured) | `x64-sync`'s timing rows in both modes: uncontended wait and signal, a cross-process wake, create/close |
| **M2 x18** (measured) | The round-trip A/B of §8 |

**Order of work:** licences (no downloads) → FreeType and gnutls (the first change a user can see) → msync → `wxflip-x64` → strict x18 (last, with everything else green).

## 10. Errors

| Condition | Behaviour |
|---|---|
| A tarball's checksum doesn't match its pin | The build stops, names the file and moves it aside (the `fetch` helper's behaviour) |
| A dependency fails to build | The build stops and names the library and its log |
| Wine's configure can't find FreeType or gnutls headers | configure fails (`--with-…`), naming the library |
| A bundled Mach-O depends on a path outside `/usr/lib`, `/System` and `@…` | `bundle.sh` stops, naming the file and the path; nothing is staged |
| x18 instructions in a bundled dylib | `bundle.sh` stops, naming the library and the first instruction |
| A licence file missing, or a new FEX external | `bundle.sh` stops, naming it |
| Client and wineserver disagree on `WINEMSYNC` | The client exits with msync's message (CrossOver's behaviour); `check.sh` never mixes modes in one prefix without `wineserver -k` |
| An x18 toggle imbalance | The process dies by `SIGTRAP` with Apple's annotation |
| PE code found running with x18 OFF in a signal | `ERR` line, then `abort` |

## 11. Acceptance

Recorded in `docs/testing/acceptance-arm64-ship-base.md`: the clean build with its time (including the deps), every check step, S1–S6, M1's timing rows in both modes, M2's A/B, the red runs before each change (37 MISSING; dbu 0,0 and `0x80090305`), the bundle's new layout and its licence tree, and the pins and patch list.

## 12. Risks

- **The gnutls build:** folding static nettle and gmp into the shared gnutls is untested (fallback: 5 dylibs); nettle 4.0 is about 8 months old with a soname change (fallback: 3.10.2, a fifth pin).
- **msync** has not been seen running natively on arm64; its known correctness gaps (PulseEvent, wait-all) stay; a wineserver left in the other mode kills new clients; the protocol bump makes old servers and new clients refuse each other.
- **x18:** subtle assembly; a signal can land between a toggle and its neighbour (T1–T2 stress it); every Wine rebase touches `signal_arm64.c`.
- **The zero-flip inference** (§7) is untested until the check runs; if it fails, the scope comes back to the maintainer.
- **Notarization** with the restricted entitlement stays unknown until sub-project 5.
- **Licence completeness:** the asserts catch missing files and new FEX externals, not a wrong licence choice; the elections and the README are reviewed by the maintainer. Not legal advice.

## 13. Amendments to the native arm64 spec (made with this spec)

1. §2 row 3: "Strict x18 toggling (§5.3); msync from CrossOver wine1117; FreeType and gnutls built from pinned source and bundled; licence and notice files for every shipped component."
2. §2 row 4: depends on 1, not 3; owns lsteamclient end to end, including the Steamworks licence decision.
3. §2: a new row, "Media: FFmpeg for `winedmo` and/or GStreamer for `winegstreamer`" (today `winedmo` builds as a stub and `winegstreamer` isn't built; game intro movies and cutscenes are the impact).
4. §2 row 8: adds FEX's WoW64 JIT dual view.
5. §3.4: the 23 ns `MAP_JIT` figure is for JITs that switch modes themselves; Windows RWX memory can't use `MAP_JIT` (§2 above).
6. §5.3: about 110–140 lines, the three additions, and the line-number offset.
7. §11: "Games with their own JIT" rewritten (x64 JITs go through FEX, checked by `wxflip-x64`; native ARM64 JITs keep patch 0006's flip and its same-page livelock); new risks: a Homebrew leak through configure (closed by §5), and the `WINEMSYNC` agreement rule.
