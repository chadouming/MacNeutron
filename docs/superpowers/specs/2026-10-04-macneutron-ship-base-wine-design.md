# MacNeutron — Native arm64 stack, sub-project 3: Ship-base Wine

- **Date:** 2026-10-04 (revised the same day after an adversarial review: three lenses, each re-checked by a sceptic)
- **Status:** Approved by the maintainer on 2026-10-04, with two changes folded in: the Steam bridge moves into this sub-project, and the tests are lightened. The design was approved in conversation the same day ("Go"), with the maintainer's decisions in §1.
- **Builds on:**
  - `2026-10-02-macneutron-native-arm64-design.md` (sub-project 1 and the roadmap; this spec amends its §2, §3.4, §5.3 and §11, see §14)
  - `2026-10-03-macneutron-arm64-dxmt-design.md` (sub-project 2: DXMT in `wine.app`, the check steps this spec extends)
- **Evidence:** `docs/research/2026-10-04-ship-base/` (the decision brief with its skeptic verification, the spec review, the probes, the msync trial merge, the scratch licence check).
- **Scope:**
  - **In:**
    - licence and notice files for every component `wine.app` ships;
    - FreeType and gnutls built from pinned source and bundled;
    - msync, ported from CrossOver `cx/wine1117`, on by default;
    - the Steam bridge on arm64: lsteamclient built as ARM64X with an aarch64 unix side against Steam's universal `steamclient.dylib`, an aarch64 `steam.exe`, and arm64 modes of the bridge's checks;
    - a check proving x64 JITs under FEX cause no W^X flips;
    - strict x18 toggling, rewriting patch 0004.
  - **Out:**
    - the launcher's Steam wiring on arm64 (copying the bridge DLL into prefixes, the arm64 paths) and the decision whether release bundles may include lsteamclient (sub-project 5, before the first release);
    - the Steam overlay (sub-project 6) and the 32-bit Steam client (sub-project 8);
    - media playback: FFmpeg for `winedmo`, GStreamer for `winegstreamer` (a new roadmap row, §14);
    - `MAP_JIT` or a dual view for native ARM64 JITs (dropped; §8 records the accepted cost);
    - FEX's 32-bit WoW64 JIT dual view (sub-project 8);
    - notarization, release source archives, and refusing development inputs in release bundles (sub-project 5);
    - the Rosetta app's missing LLVM and mingw-w64 notices (a separate small change);
    - verifying the tarballs' upstream signatures (it needs `.sig` files and keys that aren't approved downloads; §5);
    - pushing anything anywhere.

## 1. Goal

`wine.app` becomes a base that could ship: Windows text and dialogs render, TLS through Windows APIs works, games reach the Steam API through the bridge, synchronisation is as fast as on the Rosetta runtime, x18 follows Apple's documented rule, and every component's licence travels with it.

**Sub-project 3 is done when** §10's gates S1–S7 pass on the maintainer's Mac, M1–M2 are measured, and the result is recorded in `docs/testing/acceptance-arm64-ship-base.md`.

### Decisions

| Decision | Choice |
|---|---|
| The Steam bridge | **In this sub-project** (maintainer, 2026-10-04, reversing an earlier move to sub-project 4; roadmap row 4 folds into row 3) |
| lsteamclient's source | Proton's `lsteamclient/` at `db9e6ffbf24a95b104fb699dd62532c70a2f9a51` (the commit CrossOver's `winecx` imported, and the Rosetta runtime runs), fetched at build time as a sparse, blob-filtered checkout of that folder only, without the `steamworks_sdk_*` trees or `gen_wrapper.py`; never committed (it is Steamworks-SDK-derived source and 18.4 MB). Our changes to it, `winecx`'s three Mac fixes, are patch files |
| lsteamclient's licence | It is under Valve's Steamworks SDK licence, not BSD. Local builds bundle it with that licence text in `licenses/lsteamclient/`. Whether a **release** bundle may include it (ship it, ask Valve, or release without it and leave Steam-API games on Rosetta) is decided in sub-project 5 before the first release; until then the bridge spec's position stands for releases: MacNeutron doesn't redistribute it |
| `MAP_JIT` for RWX memory other than FEX's | **Dropped.** Replaced by the `wxflip-x64` check; native ARM64 JITs stay on patch 0006's flip as an accepted cost (maintainer) |
| Downloads | **Approved:** freetype 2.14.3, gnutls 3.8.13, nettle 4.0, gmp 6.3.0 from their canonical hosts, SHA-256 pinned; and, with the Steam bridge, Proton's `lsteamclient/` folder from `https://github.com/ValveSoftware/Proton.git` at the pinned commit (maintainer). Nothing else is downloaded |
| msync default | **On**, matching the Rosetta runtime (maintainer). The patch keeps CrossOver's semantics (on only with `WINEMSYNC=1`); whatever starts the runtime sets it: `check.sh` here, the launcher in sub-project 5. `WINEMSYNC=0` per game stays the off switch |
| msync source | CrossOver 26.3's msync as carried on `cx/wine1117` (at `e0aa380780`), with dappermint `winecx`'s 8 msync commits of 2026-08-21 (`8df1826853`, `9be392b3b4`, `3a7a712d66`, `307f90fdb1`, `620d8c542f`, `a7ef7b3b01`, `ef72fdb55b`, `6d316146c2`): the code the Rosetta runtime runs. Plus a one-time `shm_addrs` allocation that removes a realloc race |
| Patch numbering | Patch 0004 is rewritten in place as the strict x18 patch (only 0004 touches `signal_arm64.c`, so 0005–0014 export unchanged); msync is 0015; the lsteamclient configure registration is 0016 |
| Third-party source pins | A new `wine-arm64/deps.pins` (the four tarballs, and lsteamclient's repository and commit), in the build stamp but not in the Wine or FEX patch series (editing `wine-arm64/pins` would make both trees re-clone) |
| Where the libraries live | `Contents/Resources/lib/wine/aarch64-unix/`, beside the unix `.so` files that load them: Wine loads them by bare name and every caller carries `LC_RPATH @loader_path/`, so no Wine or loader change |
| Library packaging | nettle, hogweed and gmp linked statically into `libgnutls.30.dylib`: 2 dylibs (shown to work in a scratch build) |
| FreeType options | No libpng, harfbuzz or brotli (colour-emoji glyphs aren't worth a fifth download) |
| Licence elections | FreeType under the FTL; nettle, gmp and gnutls's included libunistring under LGPL-3+; gnutls and its included libtasn1 under LGPL-2.1+ |
| Wine configure | Against our deps only (`PKG_CONFIG_LIBDIR`, explicit `FREETYPE_*`/`GNUTLS_*` flags), with `--with-freetype --with-gnutls` so a missing library fails configure |
| The x18 scan of bundled code | Comments stripped; a committed allowlist names the only accepted hits (gnutls's data words after `ret`, §5); `ntdll.so` is checked by §9's routine-level check instead |
| x18 dispatch code | Registers parked in the dispatchers (about 3 ns per round trip); register-preserving helpers are the fallback |
| A toggle imbalance | Kills the process (`SIGTRAP` passed through), never becomes a Windows exception |
| "PE stack implies x18 ON" invariant | Always checked in the signal wrapper on threads that have a TEB; a violation writes a message with `write(2)` and aborts |
| Patch authorship | The maintainer as author, as for patches 0009 and 0013; the commit message and `wine-arm64/README.md` credit the sources (msync: Zebediah Figura, Marc-Aurel Zent, CodeWeavers CrossOver 26.3, millia ampora's `winecx` commits) |
| Wine conformance tests | Not built; `x64-sync.c` gates msync |
| Tests | Lightened to keep the check fast: msync runs in the x64 lane only (its code is in `ntdll.so` and `wineserver`, the same for both lanes); x18's thread and stress runs are shorter; the bridge's end-to-end probe runs in the x64 lane only (maintainer, 2026-10-04) |
| Time box | Three weeks from the start of implementation (estimate 13–14 working days) |

## 2. Evidence (2026-10-03/04, M5 Pro, macOS 27.0.1)

Marked **[V]** verified or **[I]** inferred; "unentitled" or "ad hoc" says how a probe ran.

- **[V] No FreeType, no gnutls today.** Wine 11.19 was configured against Homebrew's headers (`config.h`: `SONAME_LIBFREETYPE "libfreetype.6.dylib"`, `SONAME_LIBGNUTLS "libgnutls.30.dylib"`), but `wine.app` ships no dylib. Wine `dlopen`s them by bare name from `win32u/freetype.c:1457`, `dwrite/freetype.c:118`, `secur32/schannel_gnutls.c:1474` and `crypt32/unixlib.c:111`, so all four loads fail: dialog base units are 0,0, and `AcquireCredentialsHandleW(UNISP_NAME_W)` returns `0x80090305`. bcrypt runs on PE-side SymCrypt and root certificates come from Security.framework, so p11-kit, libidn2 and a CA bundle aren't needed.
- **Bundling works without a patch.** [V] All four callers carry `LC_RPATH @loader_path/` (28 of the 29 unix `.so` files do; FEX's unixlib, which loads neither library, doesn't). [V, ad hoc + hardened runtime + library validation off] a probe found a dylib beside the calling `.so`, and that dylib's own `@rpath` dependency; a hardened main ignores `DYLD_LIBRARY_PATH` and `DYLD_FALLBACK_LIBRARY_PATH`. [I] The same holds under Developer ID signing.
- **[V] The library stack builds** (a scratch build during the spec review): gmp 6.3.0 and nettle 4.0 static, gnutls 3.8.13 shared with them folded in, FreeType 2.14.3. `libgnutls.30.dylib` links only Security, CoreFoundation and libSystem, has `minos 27.0`, exports no nettle or gmp symbols and exports all 70 symbols Wine resolves; FreeType exports all 46 and links only `/usr/lib` zlib and bzip2. gnutls's configure requires nettle ≥ 3.10 and its NEWS says it supports nettle 4.0. The four tarballs' SHA-256 values match two sources: Homebrew's API cache and a fetch from the canonical hosts. gnutls compiles in its `sysconfdir` path (the build machine's, unless set).
- **[V] Homebrew can leak into the deps build too, not only into Wine's configure:** without `PKG_CONFIG_LIBDIR`, gnutls's configure picked Homebrew's shared nettle 4.0, and FreeType's would record Homebrew's `zlib`/`bzip2` in `freetype2.pc`.
- **[V] gnutls's ARMv8 assembly keeps data in `__text`:** its CRYPTOGAMS routines `gcm_ghash_v8_4x`, `sha256_block_data_order` and `sha512_block_data_order` end with constant tables and an ID string, which `otool -tV` decodes as 7 instructions naming x18 (in our build and in Homebrew's). Elsewhere in today's bundle the x18 regex matches only `ntdll.so` (its 4 dispatch routines, plus one otool comment) and two otool comments in `wineserver`.
- **gmp 6.2.1's arm64 assembly used x18** as a loop counter ([V] fixed after 6.2.1, gmplib changeset `5f32dbc41afc`). [V] With the mode OFF the kernel zeroes x18 at exception return. Under today's once-per-thread mode such a library would be harmless on PE threads; under strict toggling unix code runs OFF and it would break [I]. So gmp ≥ 6.3.0, and the scan, are required from §9 on.
- **[V] Licences:** `wine.app` ships only DXMT's 3 files. The scratch check (`licences_check.sh`) prints 37 MISSING lines: 19 are copies of texts already in `build/` (Wine, FEX and its compiled externals, LLVM, llvm-mingw); 18 must be written (README, SOURCE keys, NOTICES holders). Wine's own `NOTICES.md` covers its vendored code except GSM and FAudio, which both ship. `fex-ec/External` holds SoftFloat-3e, cephes, fmt, range-v3, rpmalloc, tiny-json, unordered_dense and xxhash; cpp-optparse is built from `Source/Common/`; only fmt, range-v3, rpmalloc, unordered_dense, xxhash and cpp-optparse are submodules.
- **msync:** [V] in CrossOver it is 4 new files (2,202 lines) and about 270 lines of hooks; the trial diff touches 15 files. It is LGPL-2.1+ (Zebediah Figura 2018, Marc-Aurel Zent 2023). It fills upstream Wine's in-process sync framework on macOS; upstream only has Linux ntsync, so every wait on our runtime is a wineserver round trip. [V] A trial merge onto 11.19 + patches 0001–0014 had one conflict (`loader.c`), and the 7 touched `.c` files pass `-Wall -fsyntax-only` with no warnings. [V, ad hoc 16K process and a 4K Rosetta client] every private API it uses works across two hardened-runtime processes; [I] the same holds for the entitled 4K `wine.app` (its workers run at 4K, `wineserver` at 16K; both size shared memory with the system-wide `vm_kernel_page_size`). [V] Client and wineserver must agree on `WINEMSYNC`: a `WINEMSYNC=0` client facing an msync server prints "Server is running with WINEMSYNC but this process is not" and exits; a `WINEMSYNC=1` client facing a plain server prints "Failed bootstrap_look_up" and exits; both are `ERR` lines, hidden under `WINEDEBUG=-all`. [V] `msync: up and running.` and msync's error lines are written by `wineserver` to the stderr of the client that started it. [I] Whether msync has run natively on arm64 is unknown.
- **msync is for speed.** [V] Cross-process wake latency is about the same either way (about 6.3 µs with `__ulock` against 5.2 µs for a pipe round trip). [I] The gain is in uncontended operations and in keeping the single-threaded wineserver off the hot path; §10's M1 measures it. [V] Known correctness gaps: PulseEvent can miss a waiter; wait-all isn't atomic.
- **x18:** [V, unentitled; the userspace path is the same entitled] one toggle costs 1.41–1.54 ns, so about 3 ns per syscall or unix-call round trip, against 82.6 ns for a `getppid()` syscall. [V] FEX never allocates x18, reads it only as the TEB, and reaches unix code only through Wine's dispatchers, so ARM64EC and FEX add no boundary. [V] `x18-boundaries.md` (whose line numbers are pristine Wine 11.19's) already covers `__wine_syscall_dispatcher_return`; it lacks two things: passing the toggle's `brk #1` through Wine's trap handler (which turns every `brk` into a Windows exception, `signal_arm64.c:1215-1250`), and a check that makes a missed ON site loud [I: untested proposal]. [V] A native double enable dies by `SIGTRAP` (exit status 133); Apple's annotation appears only in the crash report.
- **The Steam bridge on arm64** (the brief's lsteamclient investigation): [V] the Rosetta runtime's bridge is `winecx`'s `dlls/lsteamclient` (Proton's `lsteamclient/` at `db9e6ff…` plus three Mac fixes: `8d188ec0db` NOMINMAX and an X11 keysym guard, `dada36ebab` `-lc++`, `6cfbd169a5` the two Proton-only client exports made optional). [V] Mac Steam's `steamclient.dylib` and its dependencies are universal; the arm64 slice loads in a plain native arm64 process, hands out `SteamClient006`–`023`, and installs no crash or signal handlers up to `CreateInterface`. [V] lsteamclient's unix side already builds the `steamclient.dylib` path from `STEAM_COMPAT_CLIENT_INSTALL_PATH`, so an aarch64 `.so` picks the arm64 slice. [V] All 44 PE files compile for arm64ec and aarch64, and all 219 unix `.cpp` files for macOS arm64 at 27.0, with all 7,251 struct-layout asserts passing; the unix side needs only symbols `ntdll.so` exports. [V] Its callbacks are pulled by the PE side, so Steam's threads never run PE code. [V] `bridge/steam.c` builds as an aarch64 PE unchanged. [V] Valve's arm64 code shows no x18 use outside data after `ret` (552 hits, all constant tables). [I] Library validation would refuse Valve's team-signed dylib without `disable-library-validation`, already in `wine.entitlements`. [I] Whether the arm64 `steamclient.dylib` and the frameworks it pulls in (OpenAL, IOBluetooth, CoreAudio, DiskArbitration, CFNetwork) behave in a 4K-page entitled process, and leave Wine's fault handling alone after `SteamAPI_Init`, is unknown until §7's checks run. Wine 11.19 has no `dlls/lsteamclient`, and the Wine build has no C++ compiler set (`CXX` defaults to `g++`).
- **MAP_JIT doesn't fit Windows memory** [V, unentitled, 16K pages]: `MAP_JIT|MAP_FIXED` fails (EINVAL); once a MAP_JIT range is RWX, every `mprotect` on it fails (EACCES); a switch to execute inside the fault handler is undone on return. A trampoline design costs 5.6 µs per write-then-run cycle against 12.8 µs for patch 0006's flip, measured in the same run (earlier figures in the brief are superseded).
- **[I] x64 JITs under FEX never flip.** FEX reads guest code as data; patch 0006 keeps guest RWX without the EC_CODE flag as host RW. Gate G5 doesn't prove it (x64-bench allocates only RW memory); §8's check does.

## 3. What changes in the bundle

```
wine.app/Contents/Resources/
  lib/wine/aarch64-unix/libfreetype.6.dylib   (new: FreeType 2.14.3, arm64, minos 27.0, @rpath id)
  lib/wine/aarch64-unix/libgnutls.30.dylib    (new: gnutls 3.8.13 + nettle 4.0 + gmp 6.3.0, same)
  lib/wine/aarch64-unix/ntdll.so              (msync; strict x18)
  lib/wine/aarch64-windows/lsteamclient.dll   (new: ARM64X, Wine builtin)
  lib/wine/aarch64-unix/lsteamclient.so       (new: arm64, against Steam's steamclient.dylib at run time)
  bin/wineserver                              (msync)
  licenses/README  licenses/NOTICES.md  licenses/SOURCE
  licenses/{wine,fex,llvm,llvm-mingw,freetype,gnutls,nettle,gmp,lsteamclient}/…
  DXMT/…                                      (unchanged; its licence files stay here, and licenses/README points to them)
```

Wine patches after this sub-project: 0001–0003 and 0005–0014 unchanged; 0004 rewritten in place as the strict x18 patch; 0015 msync; 0016 registering `dlls/lsteamclient` in configure; 0017 a follow-up to 0004 (the trap check without `dladdr`; added as its own patch because an in-place history rewrite was refused by the session's permission rules). lsteamclient's own patches live in `wine-arm64/patches/lsteamclient/`. Outside the bundle: `build/bridge/arm64/steam.exe` (aarch64), placed into prefixes by the launcher in sub-project 5.

## 4. Licences (no downloads)

- **One tree:** `Resources/licenses/<component>/`, filled by `bundle.sh` with its `put` helper:
  - `wine/`: `LICENSE`, `COPYING.LIB`, `AUTHORS`, `NOTICES.md`, `gsm-COPYRIGHT`, `faudio-LICENSE`;
  - `fex/`: `LICENSE`, and the licence file of each compiled external that has one: the 6 submodules (fmt, range-v3, rpmalloc, unordered_dense, xxhash, cpp-optparse) and the in-tree tiny-json and cephes. SoftFloat-3e has no licence file; `NOTICES.md` carries its notice;
  - `llvm/`: `LICENSE.TXT`, `COPYRIGHT.regex` (LLVM 15 is linked statically into `winemetal.so`);
  - `llvm-mingw/`: `LICENSE.TXT`, `COPYING.MinGW-w64-runtime.txt` (in DXMT's DLLs and `winemetal.dll`);
  - `lsteamclient/`: its `LICENSE` (Valve's Steamworks SDK licence) and a note that its `cxx.h` is LGPL-2.1+ (CodeWeavers, from Wine);
  - `freetype/`: `LICENSE.TXT`, `FTL.TXT`; `gnutls/`: `COPYING.LESSERv2`, and the LGPLv3 and GPLv3 texts for its included libunistring; `nettle/` and `gmp/`: `COPYING.LESSERv3`, `COPYINGv3` (all from the tarballs). These are required whenever `libgnutls.30.dylib` is present: nettle and gmp have no dylib of their own once folded in.
- **Committed** `wine-arm64/licenses/NOTICES.md`: the notices that exist only in source headers (SoftFloat-3e's Regents of the University of California, VIXL, musl, Arm, Will Faust (Madeira's MIT grant), Microsoft's DXBCParser, and the others in the brief) and msync's authors. **Committed** `wine-arm64/licenses/README`: component → licence → where its source is (this repository's pins and patch files, the upstream URLs, and `Resources/DXMT/` for DXMT's texts), plus the FreeType credit sentence. MacNeutron's own code gets a line once the repository has a licence (to be decided before sub-project 5's first release). Both files are build inputs (in the stamp).
- **Generated** `licenses/SOURCE` by `build.sh`, one `KEY=value` line each: `MACNEUTRON_COMMIT` (the repository commit the bundle was built from; an up-to-date build keeps it, since its inputs haven't changed since), `WINE_COMMIT`, `FEX_COMMIT` and the 6 submodule commits (the in-tree externals are covered by `FEX_COMMIT`), `DXMT_COMMIT`, `LLVM_TAG`, `LLVM_MINGW`, `LSTEAMCLIENT_COMMIT`, the four tarballs' URL and SHA-256, and each tree's patch-series hash (`dev` for a development tree).
- **One check, one list:** `licences_check.sh` becomes `wine-arm64/tests/licences_test.sh <bundle>`; `bundle.sh` runs it against `wine.app.tmp` before staging, and `make wine-arm64-check` runs it against the staged bundle. It checks: every file above exists and is non-empty; `NOTICES.md` names each expected holder; `fex-ec/External` holds exactly the 8 directories listed in §2 (a new one fails until its licence is added); every `SOURCE` key is present. It also proves itself red: it must fail on a copy with one licence file deleted, and on a copy of the External list with an extra directory.
- **Signing asserts** in `bundle.sh`: every Mach-O carries a secure timestamp (`codesign -dvv` shows `Timestamp=`), and the loader has no `get-task-allow`.
- The repository README gets the FreeType credit line.

## 5. FreeType and gnutls

- **Pins** in the new `wine-arm64/deps.pins` (URL and SHA-256; the same file holds lsteamclient's pin, §7):

  | Pin | URL | SHA-256 |
  |---|---|---|
  | freetype 2.14.3 | `https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.xz` | `36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f` |
  | gnutls 3.8.13 | `https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz` | `ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e` |
  | nettle 4.0 | `https://ftp.gnu.org/gnu/nettle/nettle-4.0.tar.gz` | `3addbc00da01846b232fb3bc453538ea5468da43033f21bb345cb1e9073f5094` |
  | gmp 6.3.0 | `https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz` | `a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898` |

  Checked by SHA-256 only. The values match two independent sources (§2); checking upstream signatures would need `.sig` files and signing keys, which aren't approved downloads.
- **Fetch:** the download-and-checksum helper `fetch` moves from `dxmt/lib.sh` into a sourced file, `dxmt/fetch.sh`, that calls the caller's `die` and prints the caller's message prefix. `dxmt/lib.sh` sources it (so `dxmt/build.sh` and `dxmt/toolchain.sh` keep working) and `wine-arm64/build.sh` sources it directly. The file joins `wine-arm64/build.sh`'s stamp. Tarballs go to `build/wine-arm64-src/`.
- **Build** (a new `build.sh` step before Wine's configure). The whole step runs with `CC=/usr/bin/clang`, `MACOSX_DEPLOYMENT_TARGET=27.0`, `PKG_CONFIG_LIBDIR=<deps>/lib/pkgconfig`, `PKG_CONFIG_PATH` unset, `CPPFLAGS=-I<deps>/include` and `LDFLAGS=-L<deps>/lib`, prefix `build/wine-arm64-src/deps`. It is redone when `deps.pins` or the step's configure lines change (their hash is recorded in `deps/.complete`):
  - gmp and nettle: static, PIC;
  - gnutls: shared, `--sysconfdir=/etc --with-included-libtasn1 --with-included-unistring --without-p11-kit --without-idn --without-tpm --without-tpm2 --without-zlib --without-brotli --without-zstd --without-leancrypto --disable-nls --disable-tools --disable-cxx --disable-doc --disable-tests --disable-libdane`, with nettle, hogweed and gmp folded in;
  - freetype: shared, `--without-png --without-harfbuzz --without-brotli`, zlib and bzip2 from `/usr/lib`;
  - `install_name_tool -id @rpath/<name>` on both dylibs;
  - right after building: `otool -L libgnutls.30.dylib` names no nettle, hogweed or gmp, and both dylibs depend only on `/usr/lib` and `/System`; `freetype2.pc` has no `Requires.private`.
- **Wine's configure** runs with `PKG_CONFIG_LIBDIR=<deps>/lib/pkgconfig`, `FREETYPE_CFLAGS`/`FREETYPE_LIBS` and `GNUTLS_CFLAGS`/`GNUTLS_LIBS` pointing at the deps, and `--with-freetype --with-gnutls`. The build fails if a `cflags:` or `libs:` line in Wine's `config.log` contains `/opt/homebrew`. `build.sh` records the configure inputs (the line, the deps' `.complete`) in `wine-build/` and reconfigures when they change (one full Wine rebuild).
- **`bundle.sh`** copies both dylibs to `lib/wine/aarch64-unix/` before signing, and asserts:
  - `otool -D` is `@rpath/libfreetype.6.dylib` and `@rpath/libgnutls.30.dylib`;
  - every `otool -L` entry of every Mach-O in the bundle starts with `/usr/lib/`, `/System/`, `@rpath/`, `@loader_path/` or `@executable_path/`;
  - **the x18 scan:** for every arm64 Mach-O in the bundle except `ntdll.so`, `otool -tV` with comments stripped (`sed 's/;.*//'`), matched with `LC_ALL=C grep -E` against the regex of `docs/research/2026-10-02-native-arm64/probes/x18-cache-scan.sh`, gives only the hits listed in the committed `wine-arm64/x18-allow.txt` (file, routine, count; today: `libgnutls.30.dylib` — 1 in `gcm_ghash_v8_4x`, 3 in `sha256_block_data_order`, 3 in `sha512_block_data_order`, each the data words after the routine's last `ret`). Any other hit, or a changed count, fails;
  - every symbol Wine resolves from the two libraries (70 for gnutls, 46 for FreeType) is exported (`nm -gU`);
  - neither new dylib contains the build folder's path (after `strip -S`; DXMT's `winemetal.so` names build paths by design);
  - `minos 27.0` (the existing loop already covers them).
- **Check step `fonts-tls`:** `wine-arm64/tests/arm64-fonts-tls.c` (aarch64 PE; `WA_FLAGS_arm64-fonts-tls = -lgdi32 -lsecur32 -ldwrite -lcrypt32`) prints and requires:
  - `CreateFontW(L"Tahoma")`: `GetTextMetricsW` height, `GetTextExtentPoint32W(L"Hello")` and `GetDialogBaseUnits()`, all > 0 (win32u's FreeType load);
  - `DWriteCreateFactory` and the system font collection's family count > 0 (dwrite's FreeType load);
  - `schannel: 0x00000000` from `AcquireCredentialsHandleW(UNISP_NAME_W, SECPKG_CRED_OUTBOUND)` (secur32's gnutls load);
  - `PFXImportCertStore` of a small committed test PFX (no secret material: a throwaway self-signed certificate made for the test) returns a store with one certificate (crypt32's gnutls load);
  - the last line `PASS arm64-fonts-tls`.
  The step also fails if the run's output contains, ignoring case, `cannot find the FreeType` or `failed to load libgnutls`. Before §5 lands the same program shows dialog base units 0,0 and `0x80090305` (the red run, recorded).
- **Patch 0014 stays** as a safety net: a missing font library then degrades to no text, not a crash.

## 6. msync (patch 0015)

- **One Wine patch**, server and ntdll together (they share a protocol change):
  - the 4 msync files verbatim from `cx/wine1117`;
  - the msync hunks of the trial merge (`msync-on-11.19-trial.diff`), with `msync_init()` after `server_init_process( data )` in `loader.c`;
  - `linux_wait_objs` takes the wait type and passes `type != WaitAll` (it works today only by accident);
  - the `shm_addrs` table allocated once at its full size, computed from `vm_kernel_page_size` at init (2 MiB at 16K pages), on both sides: no realloc;
  - `tools/make_requests` regenerated, with its `SERVER_PROTOCOL_VERSION` bump (a reply grows from 16 to 24 bytes).
- **`check.sh` exports `WINEMSYNC=1`** at the top, so every run in every step (`wine_run`, the direct `wine` calls, `wineboot`, the DXMT lanes through `dxmt/check.sh`'s arm64 runner, which passes the environment on) agrees with the server.
- **Check step `msync`:** `wine-arm64/tests/x64-sync.c`, built as x64 and run under FEX (msync lives in `ntdll.so` and `wineserver`, so the lane doesn't change what is tested). The step:
  - starts and ends with `wineserver -k`, so no server outlives it in either mode;
  - for each mode (`WINEMSYNC=1`, then `WINEMSYNC=0`): starts the server itself (`WINEMSYNC=<m> wineserver -p`, its stderr to the step's own log), runs the program, then `wineserver -k`;
  - gated rows: event ping-pong; semaphore counts and `ERROR_TOO_MANY_POSTS`; mutex `ERROR_NOT_OWNER` and `WAIT_ABANDONED`; wait-any returns the lowest signalled index; wait-all exclusivity; a mixed wait with a process handle; timeouts; an alertable APC; cross-process named objects and `DuplicateHandle`; more than 3,000 events (several shared-memory chunks) across processes; 50,000 create/close cycles;
  - mode rows (from the server's log): `msync: up and running.` only in mode 1, and no `msync: ` error line; both mismatch directions exit non-zero with their own `ERR` message (run without `WINEDEBUG=-all`);
  - reported, not gated: PulseEvent, and the timing rows (§10, M1).

## 7. The Steam bridge

- **A fourth source tree,** `build/wine-arm64-src/lsteamclient`: a sparse, blob-filtered clone of `https://github.com/ValveSoftware/Proton.git` at `LSTEAMCLIENT_COMMIT` (`db9e6ffbf24a95b104fb699dd62532c70a2f9a51`, pinned with its repository in `wine-arm64/deps.pins`), checking out only `lsteamclient/` without the `steamworks_sdk_*` folders and `gen_wrapper.py`. Branch `macneutron`, its own patches in `wine-arm64/patches/lsteamclient/` (`winecx`'s three Mac fixes, each naming its source commit and author), and the same modes, stamp and export as the other trees (`export_tree` takes the tree's pins file).
- **Into Wine's build:** the tree's `lsteamclient/` is linked into the Wine tree as `dlls/lsteamclient` (a symlink listed in the Wine tree's `.git/info/exclude`, so the Wine tree stays clean and its source never enters a Wine patch). **Wine patch 0016** registers it in `configure.ac` and in the configure the patches carry. Wine's configure gets `CXX=/usr/bin/clang++` (the unix side is C++, the tree's first C++ unix module). The normal build then produces the ARM64X `lsteamclient.dll` and the arm64 `lsteamclient.so`.
- **`bundle.sh` asserts:** `aarch64-windows/lsteamclient.dll` carries ARM64X metadata (`llvm-readobj --coff-load-config`) and the builtin marker; `aarch64-unix/lsteamclient.so` is arm64 and exports `__wine_unix_call_funcs`; every `Nt*` and `__wine_*` symbol it needs is exported by `ntdll.so`; `licenses/lsteamclient/` exists; and `wine.entitlements` keeps `disable-library-validation` (Valve signs `steamclient.dylib` with its own team).
- **aarch64 `steam.exe`:** the Makefile's `bridge` target also builds `bridge/steam.c` and `bridge/tests/helper.c` for aarch64 into `build/bridge/arm64/`. Two `steam.exe` builds are needed: neither runs on the other runtime.
- **Check step `steam-bridge`:**
  - `bridge/check.sh` in an arm64 mode (set by `MACNEUTRON_ARM64_APP`, as `dxmt/check.sh`'s is): the aarch64 `steam.exe` passes the script's existing checks (exit codes, arguments, paths with spaces and non-ASCII letters) on the arm64 runtime. No Steam needed;
  - `bridge/probe.sh` in an arm64 mode, x64 lane only: the bundle's `lsteamclient.dll` copied into the prefix as `steamclient64.dll`, the x64 `steamprobe.exe` under FEX with SMITE 2's `steam_api64.dll` (read in place) and `STEAM_COMPAT_CLIENT_INSTALL_PATH` pointing at Mac Steam. `SteamAPI_Init` succeeds, the SteamID is non-zero, and an auth ticket of more than 0 bytes comes back. The step never prints the SteamID or the persona name: it reports `steamid ok` and `ticket <n> bytes`;
  - fault survival: after `SteamAPI_Init`, `steamprobe.exe` (a new mode behind an argument) raises an access violation in PE code and catches it with SEH, so Steam's crash handler hasn't taken over Wine's faults;
  - it needs Steam running and logged in, and SMITE 2 installed (as `dxmt-x64` already does); without them it fails naming what's missing;
  - reported, not gated: the x18 scan of the arm64 slice of the installed `steamclient.dylib` (Valve's code, outside our control); its hits are data after `ret` today.
- **Not here:** the launcher copying the DLL into game prefixes and its arm64 paths, and the release-bundle licence decision (sub-project 5); the overlay (6); the 32-bit client (8).

## 8. JIT memory: the zero-flip check

- **Check step `wxflip-x64`:** `WINEDEBUG=+wxflip` `x64-smc.exe` under FEX prints `PASS x64-smc`, with 0 `trace:wxflip` lines. `x64-smc` allocates `PAGE_EXECUTE_READWRITE` memory and makes its own `.text` RWX, then rewrites and runs code in both. It pulls in `wxflip` (whose 19 flips in `arm64-wxflip` prove the trace works), as `g5-jit` does.
- **If the check shows flips,** the inference in §2 is wrong and the plan stops to re-scope this item with the maintainer (the dropped `MAP_JIT` work would come back as a new decision).
- **Accepted and documented:** native ARM64/ARM64EC JITs (rare in games today) stay on patch 0006's flip; and patch 0006 loops forever on native ARM64 code that stores into its own RWX page ([V] natively; [I] inside Wine; no target game does this).

## 9. Strict x18 (patch 0004, rewritten)

One patch to `dlls/ntdll/unix/signal_arm64.c`, following `docs/research/2026-10-02-native-arm64/x18-boundaries.md` (its line numbers are pristine Wine 11.19's and apply directly: only patch 0004 touches this file):
- **OFF** on syscall and unix-call entry, at the dispatchers' kernel-stack labels; **ON** before the x18 reloads on return to PE code, and before user-callback entry. The x18 reads that would run while OFF move earlier, and `__wine_syscall_dispatcher_return` reads the TEB from `[sp,#0x90]`. Registers are parked in the dispatchers around each toggle.
- **A wrapper on the nine signal handlers**, with the doc's rule: at entry, if the mode is ON, turn it OFF; at exit, turn it ON only when the PC the handler returns to is PE code (the handlers for `SIGUSR1` and `SIGINT` keep the entry mode, as the doc says). Threads without a TEB (Cocoa, Metal, GCD) are left alone.
- **The toggle's own trap passes through:** a `SIGTRAP` whose ESR immediate is 1 and whose PC lies inside the toggle routine (`os_set_custom_x18_abi_enabled` in libsystem_kernel, its address taken once at init: no `dladdr` in the signal path) goes back to `SIG_DFL` and is re-raised, so an imbalance kills the process instead of becoming a Windows exception.
- **The invariant:** on threads with a TEB, PE code must be running with the mode ON; a violation writes `x18: PE stack running OFF` with `write(2)` (visible under `WINEDEBUG=-all`) and aborts.
- **A test hook:** with `WINE_X18_SELFTEST=double_on`, ntdll enables the mode twice at process start (for T3).
- About 110–140 lines: the doc's 80–100 plus the trap pass-through, the invariant, and the test hook.
- **Check step `x18`:**
  - T1: `wine-arm64/tests/arm64-x18v.c` (committed from the sub-project 1 trial's `x18v.c`): 16 threads for 1 s each, 0 x18 mismatches;
  - T2: `wine-arm64/tests/arm64-x18path.c`, also built as `x64-x18path.exe` (under FEX) by an extra Makefile rule; one line `ok <path>` per path: SEH access violation, `__debugbreak`, SIGILL, Suspend/Get/SetThreadContext, a SendMessage callback, `NtReadFile` into an unmapped buffer, an APC, 200 thread create/exit cycles, a raw `syscall`, a FEX-suspended thread; 0 mismatches and no `x18:` line;
  - T3: `wine` run directly (not through `exe_cmd`) on `arm64-hello.exe` with `WINE_X18_SELFTEST=double_on` must exit with status 133 (`SIGTRAP`), with no `err:seh` line; Apple's annotation is reported from the crash report if one appears, not gated;
  - T4 (stress): `arm64-x18path.exe stress`: 4 threads loop `NtQuerySystemTime` and a no-op unix call for 3 s while another thread hammers `SuspendThread`/`GetThreadContext`/`ResumeThread` and a timer signal fires every millisecond; 0 mismatches, no trap. (Amended 2026-10-04 with the lighter tests: T4's asynchronous signal is the suspend `SIGUSR1` only, no extra 1 ms timer; T3's crash-report annotation is not read back.)
  - a static check: in `otool -tV ntdll.so` with comments stripped, x18 appears only in `__wine_syscall_dispatcher`, `__wine_unix_call_dispatcher`, `call_user_mode_callback` and `__wine_syscall_dispatcher_return`. (Amended 2026-10-04 with the lighter tests: whether each use sits inside an ON window is proven at run time by T1–T4 and the invariant, not by a static ordering check.)
- **Measured, not gated (M2):** the round-trip cost against today's patch 0004 (an A/B on two builds, once, during development), expected ≤ 4 ns per syscall round trip. DXMT frame time isn't used: it is paced by the display (sub-project 2's acceptance).
- `probes/x18-cache-scan.sh` keeps running on every macOS beta (it still guards `_sigtramp`).

## 10. Gates

New steps go before `dxmt` in `STEPS`: `fonts-tls`, `msync`, `wxflip-x64`, `x18`, then `steam-bridge` (which, like `dxmt-x64`, needs Steam and SMITE 2). All five join `NEEDS_PREFIX`; `msync`, `wxflip-x64`, `x18` and `steam-bridge` join `NEEDS_FEX`.

| Gate | Pass |
|---|---|
| **S1 Licences** | `licences_test.sh` passes on the staged bundle and proves itself red; `bundle.sh`'s licence and signing asserts pass |
| **S2 Text and TLS** | `fonts-tls` passes; `bundle.sh`'s library asserts (install names, dependency paths, x18 scan with the allowlist, symbols, no build paths) pass |
| **S3 msync** | `msync` passes in both modes |
| **S4 No flips** | `wxflip-x64` shows 0 flips and `PASS x64-smc` |
| **S5 Strict x18** | `x18` passes (T1–T4 and the static check); the once-per-thread hunk is gone |
| **S6 No regressions** | Every sub-project 1 and 2 step passes under `WINEMSYNC=1`, including both DXMT lanes and `dxmt-present`; `make bridge-check` (the Rosetta bridge) passes; `make test`, `sh dxmt/tests/build_test.sh` (which covers the moved `fetch`'s checksum refusal) and `make dxmt-check` pass; `PASS orphans` |
| **S7 Steam bridge** | `steam-bridge` passes; `bundle.sh`'s lsteamclient asserts pass |
| **M1 msync** (measured) | `x64-sync`'s timing rows in both modes: uncontended wait and signal, a cross-process wake, create/close |
| **M2 x18** (measured) | The round-trip A/B of §9 |

**Order of work:** licences (no downloads) → FreeType and gnutls (the first change a user can see) → the Steam bridge → msync → `wxflip-x64` → strict x18 (last, with everything else green). §5's reconfigure, §7's configure registration and §6's protocol bump each force a full Wine rebuild; the plan may take them in one.

## 11. Errors

| Condition | Behaviour |
|---|---|
| A tarball's checksum doesn't match its pin | The build stops, names the file and moves it aside (the `fetch` helper's behaviour) |
| A dependency fails to build, or links something outside `/usr/lib` and `/System` | The build stops and names the library and its log |
| Wine's configure can't find FreeType or gnutls, or Homebrew shows up in its flags | configure fails (`--with-…`) or the build stops, naming the library |
| A bundled Mach-O depends on a path outside `/usr/lib`, `/System` and `@…` | `bundle.sh` stops, naming the file and the path; nothing is staged |
| An x18 hit not in `x18-allow.txt`, or a changed count | `bundle.sh` stops, naming the file, the routine and the instruction |
| A licence file missing, or a new FEX external | `bundle.sh` stops, naming it |
| Client and wineserver disagree on `WINEMSYNC` | The client exits (CrossOver's behaviour); its message is an `ERR` line, silent under `WINEDEBUG=-all`. `check.sh` never mixes modes in one prefix without `wineserver -k` |
| An lsteamclient patch fails to apply to the pin | The build stops and names the patch |
| Steam isn't running or logged in, or SMITE 2 isn't installed | `steam-bridge` fails, naming what's missing |
| An x18 toggle imbalance | The process dies by `SIGTRAP` (status 133) |
| PE code found running with x18 OFF in a signal | `x18: PE stack running OFF` on stderr, then `abort` |

## 12. Acceptance

Recorded in `docs/testing/acceptance-arm64-ship-base.md`: the clean build with its time (including the deps), every check step, S1–S7, M1's timing rows in both modes, M2's A/B, the bridge's results (`steamid ok`, the ticket size; never the SteamID or persona name), the red runs before each change (46 MISSING; dbu 0,0 and `0x80090305`; msync; x18), the bundle's new layout and its licence tree, and the pins and patch list. `wine-arm64/README.md` gains the new steps, the deps, the msync and x18 credits in its licence section, and the check's new run time.

## 13. Risks

- **msync** has not been seen running natively on arm64; its known correctness gaps (PulseEvent, wait-all) stay; a wineserver left in the other mode kills new clients; the protocol bump makes old servers and new clients refuse each other.
- **x18:** subtle assembly; a signal can land between a toggle and its neighbour (T4 stresses it); every Wine rebase touches `signal_arm64.c`.
- **Steam on arm64:** whether the arm64 `steamclient.dylib` and the frameworks it loads behave in a 4K-page entitled process is unknown until `steam-bridge` runs; Steam updates change Valve's code outside our pins; games built against a newer Steamworks SDK than the pinned lsteamclient may miss interfaces until the pin moves.
- **lsteamclient's licence:** local builds are covered by the Steamworks SDK licence's development grant; shipping it in a release is not decided (sub-project 5).
- **The x18 allowlist** names gnutls's CRYPTOGAMS data words by routine and count; a gnutls update that changes them fails the build until the allowlist is re-checked (by reading the routine, not by raising the count).
- **The zero-flip inference** (§8) is untested until the check runs; if it fails, the scope comes back to the maintainer.
- **Library updates:** a newer nettle, gnutls or FreeType may need configure changes; the deps step's asserts catch a leak or a new dependency.
- **Notarization** with the restricted entitlement stays unknown until sub-project 5.
- **Licence completeness:** the asserts catch missing files and new FEX externals, not a wrong licence choice; the elections and the README are reviewed by the maintainer. Not legal advice.

## 14. Amendments to the native arm64 spec (made with this spec)

1. §2 row 3: "Strict x18 toggling (§5.3); msync from CrossOver wine1117; FreeType and gnutls built from pinned source and bundled; licence and notice files for every shipped component."
2. §2 row 4 (Steam path): folded into row 3 (maintainer, 2026-10-04). Row 5 (launcher) gains the arm64 Steam wiring and the decision whether release bundles may include lsteamclient.
3. §2: a new row 10, "Media: FFmpeg for `winedmo` and/or GStreamer for `winegstreamer`" (today `winedmo` builds as a stub and `winegstreamer` isn't built; game intro movies and cutscenes are the impact).
4. §2 row 8: adds FEX's WoW64 JIT dual view.
5. §3.4: the 23 ns `MAP_JIT` figure is for JITs that switch modes themselves; Windows RWX memory can't use `MAP_JIT` (§2 above).
6. §5.3: about 110–140 lines: the trap pass-through, the invariant and a test hook added to the doc's design.
7. §11: "Games with their own JIT" rewritten (x64 JITs go through FEX, checked by `wxflip-x64`; native ARM64 JITs keep patch 0006's flip and its same-page livelock); new risks: a Homebrew leak through configure (closed by §5), and the `WINEMSYNC` agreement rule.
