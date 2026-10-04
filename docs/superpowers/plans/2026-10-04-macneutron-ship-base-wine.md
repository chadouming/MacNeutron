# Native arm64 Stack, Sub-project 3 (Ship-base Wine) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `wine.app` ships every component's licence, renders text, does TLS, reaches the Steam API through an arm64 bridge, synchronises with msync, proves x64 JITs don't flip W^X, and follows Apple's x18 rule strictly.

**Architecture:**
- **Two new kinds of source:** pinned tarballs (FreeType, gnutls, nettle, gmp) built into `build/wine-arm64-src/deps`, and a fourth patched tree (Proton's `lsteamclient/`, sparse) linked into Wine's build. Both are pinned in a new `wine-arm64/deps.pins`.
- **Two Wine patches change, two arrive:** 0004 is rewritten in place as strict x18; 0015 is msync; 0016 registers lsteamclient.
- **The checks:** `wine-arm64/check.sh` gains `fonts-tls`, `msync`, `wxflip-x64`, `x18` and `steam-bridge`. `bundle.sh` gains the licence tree and the library asserts.

**Tech Stack:**
- POSIX sh
- autotools (gmp, nettle, gnutls, FreeType, Wine)
- Apple clang (`/usr/bin/clang`, `/usr/bin/clang++`)
- llvm-mingw 20260908 (aarch64-, arm64ec-, x86_64-w64-mingw32)
- git sparse checkout
- `otool`, `nm`, `llvm-readobj`, `codesign`

**Spec:** `docs/superpowers/specs/2026-10-04-macneutron-ship-base-wine-design.md`. Evidence: `docs/research/2026-10-04-ship-base/` (`brief.md` and its §10 corrections, `spec-review.md`, `licences_check.sh`, `msync-on-11.19-trial.diff`, `probes/`).

## Global Constraints

- **Branch:** `feat/native-arm64-ship-base`, from `main` at `71a65d4`.
- **Pins:** in `wine-arm64/deps.pins`, exactly:
  - `FREETYPE_URL=https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.xz`, `FREETYPE_SHA256=36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f`;
  - `GNUTLS_URL=https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz`, `GNUTLS_SHA256=ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e`;
  - `NETTLE_URL=https://ftp.gnu.org/gnu/nettle/nettle-4.0.tar.gz`, `NETTLE_SHA256=3addbc00da01846b232fb3bc453538ea5468da43033f21bb345cb1e9073f5094`;
  - `GMP_URL=https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz`, `GMP_SHA256=a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898`;
  - `LSTEAMCLIENT_REPO=https://github.com/ValveSoftware/Proton.git`, `LSTEAMCLIENT_COMMIT=db9e6ffbf24a95b104fb699dd62532c70a2f9a51`.

  `wine-arm64/pins` and `dxmt/pins` are not edited.
- **Downloads:** these five sources only (approved by the maintainer); no `.sig` or key downloads, no `brew install`.
- **Never commit** lsteamclient source (Steamworks-SDK-derived), the provisioning profile, a SteamID, a persona name, or the user's email outside git authorship lines.
- **macOS 27:** `MACOSX_DEPLOYMENT_TARGET=27.0`; every Mach-O in the bundle has `minos 27.0`; native code with `/usr/bin/clang`/`/usr/bin/clang++`.
- **Patches:** changes to Wine, FEX, DXMT or lsteamclient are commits in `build/wine-arm64-src/<tree>` on branch `macneutron`, exported with `make wine-arm64-export`. Patch numbers: 0004 rewritten in place (keep its file name's number), 0015 msync, 0016 lsteamclient registration. Adapted code credits its sources in the commit message and in `wine-arm64/README.md`'s licence section.
- **Order:** the tasks land in this order: licences, FreeType/gnutls, `wxflip-x64`, msync, the Steam bridge, strict x18. That differs from spec §10's order (bridge before msync) only so that the patch numbers match spec §1: 0015 msync, 0016 lsteamclient.
- **Scans:** any count that gates a decision uses `LC_ALL=C /usr/bin/grep` (the interactive `grep` here is a ugrep wrapper that can return 0).
- **msync agreement:** every run in `check.sh` sees `WINEMSYNC=1`, except inside the `msync` step, which owns its wineserver.
- **Cleanup:** `wineserver -k`, then `lsof -t <binary>` and kill; never `pkill -f`.
- **The Rosetta stack stays untouched:** after any task that touches `dxmt/`, `bridge/`, `presenter/` or the `Makefile`, `make test`, `sh dxmt/tests/build_test.sh`, `make bridge-check` and `make dxmt-check` pass.
- **Signing environment** for builds: `MACNEUTRON_SIGN_IDENTITY="Developer ID Application: Chad Cormier Roussel (49QMZXLR8S)"`, `MACNEUTRON_PROVISIONING_PROFILE="$HOME/Downloads/Mac_Neutron.provisionprofile"`.
- **Never** push, fork, open PRs, post, or propose reduced security.
- **Commits** end with the session's Co-Authored-By trailer.

## Review Focus

1. **A pin edit in `deps.pins` doesn't re-clone Wine or FEX.** Wine and FEX stay `applied` while only the deps (and the lsteamclient tree) are redone. Pinned in Task 2, Step 7.
2. **Homebrew present or absent changes nothing.** The deps and Wine's configure never read `/opt/homebrew`. Pinned in Task 2, Steps 4 and 5 (`otool -L` of the deps, Wine's `config.log` scan).
3. **The `msync` step leaves the prefix usable.** `check.sh msync dxmt` passes, so the step after `msync` starts a mode-1 server cleanly. Pinned in Task 4, Step 6.
4. **Steam not reachable fails clearly, not by hanging.** With `STEAM_COMPAT_CLIENT_INSTALL_PATH` pointing at an empty folder, `steam-bridge` fails within its cap and names Steam. Pinned in Task 5, Step 8.
5. **A development lsteamclient tree** (an extra commit) builds as development, `SOURCE` says `dev` for it, no stamp is written, and `make wine-arm64-export` brings it back to `applied`. Pinned in Task 5, Step 9.

---

### Task 1: The licence tree

**Files:**
- Create: `wine-arm64/licenses/NOTICES.md`, `wine-arm64/licenses/README`, `wine-arm64/tests/licences_test.sh`
- Modify: `wine-arm64/bundle.sh`, `wine-arm64/build.sh` (SOURCE, stamp), `Makefile` (`wine-arm64-check`), `README.md` (one line)

**Interfaces:**
- Produces:
  - `sh wine-arm64/tests/licences_test.sh <wine.app>`: prints `MISSING <what>` per gap, then `PASS licences_test` (exit 0) or `FAIL licences_test` (exit 1).
  - `sh wine-arm64/tests/licences_test.sh --self-test <wine.app>`: checks that a copy with `licenses/fex/xxhash-LICENSE` removed fails, and that an extra `External/` entry fails; prints `PASS licences_test self-test`.
  - `$SRC/SOURCE`, written by `build.sh` before `bundle.sh` runs, in `KEY=value` lines: `MACNEUTRON_COMMIT` (`git rev-parse HEAD` of the repo, with `+dirty` when `git status --porcelain` lists tracked changes), `WINE_COMMIT`, `WINE_SERIES`, `FEX_COMMIT`, `FEX_SERIES`, `FEX_SUBMODULE_<name>` for fmt, range-v3, rpmalloc, unordered_dense, xxhash and cpp-optparse, `DXMT_COMMIT`, `DXMT_SERIES`, `LLVM_TAG`, `LLVM_MINGW_SHA256`. Each `*_SERIES` is `dev` for a development tree. Later tasks add keys.
  - `bundle.sh` copies `$SRC/SOURCE` and the two committed files into `Resources/licenses/`.

- [ ] **Step 1: Write the failing test.** Make `wine-arm64/tests/licences_test.sh` from `docs/research/2026-10-04-ship-base/licences_check.sh`, with these changes:
  - the bundle comes from `$1` and the build folder from `${BUILD_DIR:-<repo>/build}`;
  - the gnutls rule is triggered by `libgnutls*` and requires `gnutls/COPYING.LESSERv2`, `gnutls/COPYING.LESSERv3`, `gnutls/COPYINGv3`, `nettle/COPYING.LESSERv3`, `nettle/COPYINGv3`, `gmp/COPYING.LESSERv3` and `gmp/COPYINGv3`;
  - `lsteamclient.so` requires `licenses/lsteamclient/LICENSE` plus the `SOURCE` keys `LSTEAMCLIENT_COMMIT` and `LSTEAMCLIENT_SERIES`;
  - `libfreetype*` or `libgnutls*` requires the tarball keys `<NAME>_URL` and `<NAME>_SHA256` for the four libraries;
  - the `SOURCE` key list is the Interfaces block's;
  - `--self-test` works on `cp -cR` copies in `$TMPDIR`;
  - every grep is `LC_ALL=C /usr/bin/grep`.
- [ ] **Step 2:** Run `sh wine-arm64/tests/licences_test.sh build/wine-arm64/wine.app`. Expected: `FAIL licences_test`, with the MISSING lines (about 37). Record the count.
- [ ] **Step 3: Write the two committed files.**
  - `NOTICES.md`: one section per notice that lives only in source headers. It names "Regents of the University of California" (SoftFloat-3e), "VIXL authors", "Rich Felker", "Arm Limited", "Will Faust" (Madeira's MIT grant), "Microsoft Corporation" (DXBCParser), "Alexander Bessonov", "Unicode, Inc." and "Henry Spencer", quoting each notice from the file it comes from (path given).
  - `README`: component → licence → where its source is (repo pins and patch files, upstream URLs, and `Resources/DXMT/` for DXMT), plus the FreeType credit sentence: "Portions of this software are copyright © The FreeType Project (www.freetype.org). All rights reserved."
- [ ] **Step 4: Fill the tree in `bundle.sh` step 1 with `put`.** Sources:
  - `wine/`: from the Wine tree's `LICENSE`, `COPYING.LIB`, `AUTHORS` and `NOTICES.md`, plus `libs/gsm/COPYRIGHT` → `gsm-COPYRIGHT` and `libs/faudio/LICENSE` → `faudio-LICENSE`;
  - `fex/`: FEX's `LICENSE`, plus `<ext>-LICENSE` from `External/<ext>/` (fmt, xxhash, tiny-json, unordered_dense, rpmalloc, cephes; range-v3's `LICENSE.txt`) and `Source/Common/cpp-optparse/`;
  - `llvm/`: from `build/dxmt-src/llvm-project/llvm/LICENSE.TXT` and its `COPYRIGHT.regex`;
  - `llvm-mingw/`: from `build/dxmt-src/llvm-mingw/`.
  
  After signing, `bundle.sh` runs `licences_test.sh "$APP"` and dies on failure. It also asserts that every Mach-O's `codesign -dvv` shows `Timestamp=` and that `codesign -d --entitlements -` of the loader has no `get-task-allow`.
- [ ] **Step 5:** In `build.sh`, write `$SRC/SOURCE` (the FEX submodule commits come from `git -C "$F" submodule status`). Add `wine-arm64/licenses/NOTICES.md`, `wine-arm64/licenses/README` and `wine-arm64/tests/licences_test.sh` to `stamp_of`. Add `sh wine-arm64/tests/licences_test.sh build/wine-arm64/wine.app` to the `wine-arm64-check` recipe, after `profile_test.sh`.
- [ ] **Step 6:** Run `make wine-arm64`. Expected: built; `licences_test.sh build/wine-arm64/wine.app` prints `PASS licences_test`; `--self-test` prints `PASS licences_test self-test`.
- [ ] **Step 7:** Add the FreeType credit line to `README.md`. Run `sh wine-arm64/tests/mode_test.sh`. Expected: pass. Commit: "wine-arm64: licence tree for every shipped component".

### Task 2: FreeType and gnutls

**Files:**
- Create: `wine-arm64/deps.pins`, `dxmt/fetch.sh`, `wine-arm64/x18-allow.txt`, `wine-arm64/tools/x18scan.sh`, `wine-arm64/tests/arm64-fonts-tls.c`, `wine-arm64/tests/fixtures/fonts-tls.pfx`
- Modify: `dxmt/lib.sh`, `wine-arm64/build.sh`, `wine-arm64/bundle.sh`, `wine-arm64/check.sh`, `wine-arm64/tests/licences_test.sh` (only if Task 1 left a gap), `Makefile`

**Interfaces:**
- Consumes: Task 1's `put`, `SOURCE`, `licences_test.sh`.
- Produces:
  - `fetch <url> <file> <sha256>` in `dxmt/fetch.sh`: uses the caller's `die`, and prints `"${FETCH_TAG:-dxmt}: downloading <url>"`. `dxmt/lib.sh` sources it; `wine-arm64/build.sh` sources it with `FETCH_TAG=wine-arm64`.
  - `sh wine-arm64/tools/x18scan.sh <mach-o>`: one line per hit, `<routine> <instruction>`, from `otool -tV` with `;` comments stripped and the regex of `docs/research/2026-10-02-native-arm64/probes/x18-cache-scan.sh`.
  - `wine-arm64/x18-allow.txt`: lines of `<file basename> <routine> <count>`.
  - `build/wine-arm64-src/deps/`: `lib/libfreetype.6.dylib`, `lib/libgnutls.30.dylib`, `deps/.complete`.
  - Step `fonts-tls`.

- [ ] **Step 1: Write the failing test** `wine-arm64/tests/arm64-fonts-tls.c` (aarch64 PE; Makefile `WA_FLAGS_arm64-fonts-tls = -lgdi32 -lsecur32 -ldwrite -lcrypt32`). Usage: `arm64-fonts-tls.exe <pfx path>`. It prints:
  - `font <height> <cx>x<cy> dbu <x>,<y>`: `CreateFontW` Tahoma 16 px, `GetTextMetricsW`, `GetTextExtentPoint32W(L"Hello")`, `GetDialogBaseUnits()`;
  - `dwrite families <n>`: `DWriteCreateFactory`, then the system font collection's family count;
  - `schannel: 0x%08lx`: `AcquireCredentialsHandleW(NULL, UNISP_NAME_W, SECPKG_CRED_OUTBOUND, …)`;
  - `pfx certs <n>`: `PFXImportCertStore` of the file with an empty password.
  
  It ends with `PASS arm64-fonts-tls` when all of these hold: height, cx, cy, both dbu values and families > 0; schannel = 0; certs = 1.
  
  Make the fixture once with macOS's `openssl`: a throwaway self-signed certificate, `CN=MacNeutron test`, exported as PKCS#12 with an empty password, committed.
- [ ] **Step 2:** Add the step `fonts-tls` (cap 60; before `dxmt` in `STEPS`; in `NEEDS_PREFIX`). It runs `exe_cmd arm64-fonts-tls` with the fixture as a `Z:` path, and fails if the output matches `cannot find the FreeType|failed to load libgnutls` (`/usr/bin/grep -iE`). Run `sh wine-arm64/check.sh fonts-tls`. Expected: FAIL, with `dbu 0,0` and `schannel: 0x80090305`. Record that output.
- [ ] **Step 3: Move `fetch`** into `dxmt/fetch.sh`. Run `sh dxmt/tests/build_test.sh`. Expected: all ok (it covers the checksum refusal).
- [ ] **Step 4: The deps step** in `build.sh`, after the trees are prepared and before Wine's configure.
  - Source `deps.pins`; fetch the four tarballs into `$SRC/`.
  - When `deps/.complete` doesn't hold the hash of `deps.pins` plus the step's configure lines: unpack into `$SRC/deps-src/`, then build gmp, nettle, gnutls and freetype as spec §5 says.
  - The whole step runs with: `CC=/usr/bin/clang`, `PKG_CONFIG_LIBDIR=$SRC/deps/lib/pkgconfig`, `PKG_CONFIG_PATH` unset, `CPPFLAGS=-I$SRC/deps/include`, `LDFLAGS=-L$SRC/deps/lib`.
  - Afterwards: `install_name_tool -id @rpath/<name>` on both dylibs. Then assert that `otool -L` of each names only `/usr/lib/…` and `/System/…`, that `libgnutls.30.dylib` names no nettle, hogweed or gmp, and that `freetype2.pc` has no `Requires.private`. Each failure names the library and its log, `$SRC/deps-<name>.log`.
  - Add `deps.pins` and `dxmt/fetch.sh` to `stamp_of`, not to any `series_of`.
- [ ] **Step 5: Wine's configure.**
  - Add `--with-freetype --with-gnutls`, and set `PKG_CONFIG_LIBDIR`, `FREETYPE_CFLAGS=-I$SRC/deps/include/freetype2`, `FREETYPE_LIBS="-L$SRC/deps/lib -lfreetype"`, `GNUTLS_CFLAGS=-I$SRC/deps/include` and `GNUTLS_LIBS="-L$SRC/deps/lib -lgnutls"`.
  - Record the configure inputs (the configure line and `deps/.complete`) in `$SRC/wine-build/.configure-inputs`, and reconfigure (`rm -rf wine-build`) when they change.
  - After configure, die if any `cflags:` or `libs:` line in `wine-build/config.log` contains `/opt/homebrew`.
- [ ] **Step 6: `bundle.sh`.**
  - Copy both dylibs to `lib/wine/aarch64-unix/`, and the licence texts from the unpacked tarballs to `licenses/{freetype,gnutls,nettle,gmp}/`: gnutls's LGPLv3 and GPLv3 texts come from nettle's `COPYING.LESSERv3` and `COPYINGv3`.
  - Add the tarball keys to `SOURCE`.
  - Assert, as spec §5 lists:
    - the install IDs;
    - every `otool -L` entry of every Mach-O starts with `/usr/lib/`, `/System/`, `@rpath/`, `@loader_path/` or `@executable_path/`;
    - `x18scan.sh` on every arm64 Mach-O except `ntdll.so` matches `x18-allow.txt` exactly;
    - the 70 gnutls and 46 FreeType symbols (lists in `docs/research/2026-10-04-ship-base/`, or regenerated from Wine's sources by `grep` of the `LOAD_FUNCPTR`/`MAKE_FUNCPTR` lines) are in `nm -gU`;
    - no shipped dylib's `strings` contains `$B`.
  - `x18-allow.txt` starts with `libgnutls.30.dylib gcm_ghash_v8_4x 1`, `libgnutls.30.dylib sha256_block_data_order 3` and `libgnutls.30.dylib sha512_block_data_order 3`. Confirm each by reading the routine's disassembly: the hits sit after its last `ret`.
- [ ] **Step 7: Build and check.** Run `make wine-arm64`. Expected: built; the deps built once (time recorded).
  - Run `sh wine-arm64/check.sh fonts-tls`. Expected: `PASS fonts-tls`, with non-zero font numbers, `schannel: 0x00000000` and `pfx certs 1`.
  - Then add a comment line to `deps.pins` and run `make wine-arm64` again. Expected: the deps are redone, Wine is reconfigured, and `build_mode` of `build/wine-arm64-src/wine` and of `fex` still prints `applied` (no re-clone). Remove the comment.
- [ ] **Step 8:** Run `make test`, `sh dxmt/tests/build_test.sh`, `make bridge-check` and `make dxmt-check`. Expected: pass. Commit: "wine-arm64: FreeType and gnutls built from pinned source and bundled".

### Task 3: `wxflip-x64`

**Files:**
- Modify: `wine-arm64/check.sh`

- [ ] **Step 1:** Add `wxflip_x64_cmd`. It runs `WINEDEBUG=+wxflip` `wine_run "$TESTS/x64-smc.exe"`. It requires the line `PASS x64-smc`, and `LC_ALL=C /usr/bin/grep -c trace:wxflip` = 0, and prints `info wxflip-x64: <n> flips`.
  - The step has cap 60, comes after `wxflip` in `STEPS`, and is in `NEEDS_PREFIX` and `NEEDS_FEX`.
  - Extend the line that pulls `wxflip` in for `g5-jit` so it also pulls it in for `wxflip-x64`.
- [ ] **Step 2:** Run `sh wine-arm64/check.sh wxflip-x64`. Expected: `PASS wxflip`, `PASS wxflip-x64`, `info wxflip-x64: 0 flips`. **If it shows flips, stop and report to the maintainer** (spec §8: the scope comes back).
- [ ] **Step 3:** Commit: "wine-arm64: check that x64 JIT memory under FEX never flips W^X".

### Task 4: msync (Wine patch 0015)

**Files:**
- Create: `wine-arm64/patches/wine/0015-*.patch` (exported), `wine-arm64/tests/x64-sync.c`
- Modify: `wine-arm64/check.sh`, `wine-arm64/README.md`, `wine-arm64/licenses/NOTICES.md`

**Interfaces:**
- Consumes: the Wine tree at `build/wine-arm64-src/wine`; the local winecx clone `build/arm64/crossover/wine` (`GIT_NO_LAZY_FETCH=1`; branch `cx/wine1117` at `e0aa380780`).
- Produces: step `msync`; `x64-sync.exe [rows]` printing `ok <row>` / `FAIL <row>: …` lines, `time <row> <ns>` lines, and `PASS x64-sync`.

- [ ] **Step 1: Write the failing test** `x64-sync.c`. It covers spec §6's gated rows, each printing `ok <name>`:
  - `event-pingpong`;
  - `semaphore-counts`;
  - `semaphore-too-many-posts`;
  - `mutex-not-owner`;
  - `mutex-abandoned`;
  - `wait-any-lowest`;
  - `wait-all-exclusive`;
  - `wait-process-handle`;
  - `timeouts`;
  - `alertable-apc`;
  - `named-cross-process` (the exe starts itself with `child` as a second process);
  - `duplicate-handle`;
  - `many-events-cross-process` (3,200 events);
  - `create-close-churn` (50,000).
  
  `pulse-event` is printed as `info`. The timing rows `time uncontended-wait`, `time uncontended-signal`, `time cross-process-wake` and `time create-close` print median ns.
- [ ] **Step 2:** Add `export WINEMSYNC=1` near the top of `check.sh`, and the step `msync` (cap 300; after `wxflip-x64`; in `NEEDS_PREFIX` and `NEEDS_FEX`):
  - It runs `wineserver -k`. Then, for m in 1 and 0: `WINEMSYNC=$m wineserver -p` with its stderr to `$WORK/msync-server-$m.log`, `WINEMSYNC=$m wine_run "$TESTS/x64-sync.exe"`, then `wineserver -k`.
  - The mode rows:
    - `msync: up and running.` is in the mode-1 log only;
    - no `msync: ` error line;
    - a mode-0 client against a mode-1 server exits non-zero with "Server is running with WINEMSYNC but this process is not";
    - a mode-1 client against a mode-0 server exits non-zero with "Failed bootstrap_look_up".
  - It ends with `wineserver -k`.
  
  Run `sh wine-arm64/check.sh msync`. Expected: FAIL (no `msync: up and running.`).
- [ ] **Step 3: The patch.** In the Wine tree, apply the msync hunks of `docs/research/2026-10-04-ship-base/msync-on-11.19-trial.diff`, and copy the 4 msync files from `cx/wine1117`. Then:
  - put `msync_init()` after `server_init_process( data )` in `loader.c`;
  - make `linux_wait_objs` take the wait type (`type != WaitAll`);
  - allocate `shm_addrs` once at full size, computed from `vm_kernel_page_size`, on both sides;
  - run `tools/make_requests`.
  
  Commit it. The message credits Zebediah Figura and Marc-Aurel Zent (msync), CodeWeavers CrossOver 26.3 as carried on `dappermint/winecx` `cx/wine1117` at `e0aa380780`, and millia ampora's commits `8df1826853` `9be392b3b4` `3a7a712d66` `307f90fdb1` `620d8c542f` `a7ef7b3b01` `ef72fdb55b` `6d316146c2`.
- [ ] **Step 4:** `make wine-arm64` (development build), then `sh wine-arm64/check.sh msync`. Expected: `PASS msync`, with the `time` rows as `info` lines.
- [ ] **Step 5:** `make wine-arm64-export` (expect `0015-…`), then `make wine-arm64` (applied). Add the msync credits to `README.md`'s licence section and its authors to `NOTICES.md`.
- [ ] **Step 6:** Run `sh wine-arm64/check.sh msync dxmt dxmt-present`. Expected: all PASS, `PASS orphans` (the step after `msync` starts cleanly in mode 1).
- [ ] **Step 7:** Commit: "wine-arm64: msync (patch 0015), on by default in the checks".

### Task 5: The Steam bridge (Wine patch 0016)

**Files:**
- Create: `wine-arm64/patches/lsteamclient/0001-0003-*.patch`, `wine-arm64/patches/wine/0016-*.patch` (exported)
- Modify: `wine-arm64/deps.pins`, `wine-arm64/build.sh`, `wine-arm64/export.sh`, `wine-arm64/bundle.sh`, `wine-arm64/check.sh`, `bridge/check.sh`, `bridge/probe.sh`, `bridge/probe.c`, `Makefile`, `wine-arm64/README.md`

**Interfaces:**
- Consumes: Task 2's `deps.pins`, `x18scan.sh`; Task 1's `SOURCE` and `licences_test.sh`.
- Produces:
  - tree `build/wine-arm64-src/lsteamclient` (branch `macneutron`; `lsteamclient.applied`, `lsteamclient.series` = `series_of deps.pins patches/lsteamclient/*.patch`);
  - `MACNEUTRON_ARM64_APP` arm64 modes in `bridge/check.sh` and `bridge/probe.sh`;
  - `steamprobe.exe <steam_api64.dll> [fault]`;
  - step `steam-bridge`.

- [ ] **Step 1: The tree.** `fetch_lsteamclient`, modelled on `fetch_fex`:
  - `git init`, `git remote add origin $LSTEAMCLIENT_REPO`;
  - `git -c protocol.version=2 fetch --depth 1 --filter=blob:none origin $LSTEAMCLIENT_COMMIT`;
  - sparse-checkout `lsteamclient/` with `!lsteamclient/steamworks_sdk_*` and `!lsteamclient/gen_wrapper.py`;
  - `checkout -b macneutron FETCH_HEAD`;
  - `patch_tree` with `patches/lsteamclient/`.
  
  Add it to the modes, the development test, `prepare`, `export.sh` (`export_tree lsteamclient "$LSTEAMCLIENT_COMMIT" "$ROOT/wine-arm64/deps.pins"`) and `SOURCE` (`LSTEAMCLIENT_COMMIT`, `LSTEAMCLIENT_SERIES`). After the trees are prepared, link it: `ln -sfn ../../lsteamclient/lsteamclient "$W/dlls/lsteamclient"`, and add `/dlls/lsteamclient` to `$W/.git/info/exclude` (the Wine tree stays `applied`).
- [ ] **Step 2: The three patches.** Port `winecx` `8d188ec0db` (NOMINMAX and the X11 keysym guard), `dada36ebab` (`-lc++`) and `6cfbd169a5` (the Proton-only client exports made optional) onto the sparse tree's `lsteamclient/` paths. Commit each in `build/wine-arm64-src/lsteamclient`, keeping millia ampora as author, with "From dappermint/winecx <sha>" in the message.
- [ ] **Step 3: Wine patch 0016.** In the Wine tree, register `dlls/lsteamclient`: the `WINE_CONFIG_MAKEFILE(dlls/lsteamclient)` line in `configure.ac`, and in `configure` the `enable_lsteamclient` variable and the `wine_fn_config_makefile dlls/lsteamclient enable_lsteamclient` line (the patches carry configure; no autoreconf). Commit. Add `CXX=/usr/bin/clang++` to `build.sh`'s configure line (this changes the configure inputs, so Wine reconfigures).
- [ ] **Step 4: `bundle.sh`.**
  - Copy lsteamclient's `LICENSE` to `licenses/lsteamclient/`, with a `NOTE` file saying its `cxx.h` is LGPL-2.1+ (CodeWeavers, from Wine).
  - Assert, as spec §7 lists:
    - `llvm-readobj --coff-load-config` of `aarch64-windows/lsteamclient.dll` shows CHPE metadata;
    - the dll carries the builtin marker;
    - the `.so` is arm64 and exports `___wine_unix_call_funcs`;
    - `nm -u` of the `.so` filtered to `_Nt*` and `___wine_*` is covered by `nm -gU` of `ntdll.so`;
    - `wine.entitlements` has `com.apple.security.cs.disable-library-validation`.
- [ ] **Step 5: Build.** `make wine-arm64-export` (expect `exported 3 lsteamclient patches`, Wine `0016-…`), then `make wine-arm64`. Expected: built applied; `licences_test.sh` passes, including lsteamclient's licence and keys.
- [ ] **Step 6: The bridge's arm64 parts.**
  - The `Makefile` `bridge` target also builds `steam.exe` and `tests/helper.exe` with `$(MINGW_BIN)/aarch64-w64-mingw32-clang` into `build/bridge/arm64/`.
  - `probe.c` gains the optional second argument `fault`: after the ticket rows, it writes through a NULL pointer inside `__try`/`__except` and prints `fault: caught`.
  - `bridge/check.sh` gains an arm64 mode when `MACNEUTRON_ARM64_APP` is set: `WINE=$MACNEUTRON_ARM64_APP/Contents/MacOS/wine`, the `steam.exe` and `helper.exe` from `build/bridge/arm64/`, the work folder from `${BRIDGE_CHECK_WORK:-…}`. Its checks are unchanged.
  - `bridge/probe.sh` gains an arm64 mode the same way: it copies the bundle's `aarch64-windows/lsteamclient.dll` as `steamclient64.dll`, runs the x64 `steamprobe.exe <dll> fault`, and with `PROBE_REDACT=1` replaces the `steamid:` and `persona:` lines by `steamid ok`/`steamid FAIL` and `persona ok`/`persona FAIL`.
- [ ] **Step 7: The step `steam-bridge`** (cap 300; last of the new steps, before `dxmt`; in `NEEDS_PREFIX` and `NEEDS_FEX`). It runs:
  - `bridge/check.sh` in arm64 mode, which must pass;
  - `PROBE_REDACT=1 bridge/probe.sh "$SMITE2_API"` in arm64 mode, with `SMITE2_API="$HOME/Library/Application Support/Steam/steamapps/common/SMITE 2/Windows/Engine/Binaries/ThirdParty/Steamworks/Steamv157/Win64/steam_api64.dll"`. It requires `init: ok`, `steamid ok`, `persona ok`, an `auth ticket: …, <n> bytes` line with n > 0, `auth ticket: callback, result 1` and `fault: caught`.
  
  It fails naming `Steam isn't running or logged in` when `pgrep -x steam_osx` finds nothing, and `SMITE 2 isn't installed` when the DLL is missing. It reports `info steam x18: <n> hits outside data` from `x18scan.sh` on the installed `steamclient.dylib`, not gated.
- [ ] **Step 8:** Run `sh wine-arm64/check.sh steam-bridge`. Expected: `PASS steam-bridge`, and no SteamID or persona name anywhere in `build/wine-arm64 check/steam-bridge.log`. Then, with `STEAM_COMPAT_CLIENT_INSTALL_PATH` pointed at an empty folder (`check.sh` passes it through when set), run it again. Expected: FAIL within the cap, naming the missing `steamclient.dylib`.
- [ ] **Step 9: A development lsteamclient tree.** Commit an empty change in `build/wine-arm64-src/lsteamclient` and run `make wine-arm64`. Expected: `development build`, `SOURCE` has `LSTEAMCLIENT_SERIES=dev`, no stamp. Then `git -C … reset --hard HEAD~1` and `make wine-arm64`. Expected: applied, stamp written.
- [ ] **Step 10:** Run `make bridge-check` (Rosetta) and `make test`. Expected: pass. README: the bridge on arm64, its prerequisites (Steam running and logged in, SMITE 2), and lsteamclient's licence note. Commit: "wine-arm64: the Steam bridge on arm64 (lsteamclient ARM64X, patch 0016)".

### Task 6: Strict x18 (patch 0004 rewritten)

**Files:**
- Modify: `wine-arm64/patches/wine/0004-*.patch` (re-exported, same number), `wine-arm64/check.sh`, `Makefile`
- Create: `wine-arm64/tests/arm64-x18v.c` (from `build/arm64/entitled/verify/x18v.c`), `wine-arm64/tests/arm64-x18path.c`

**Interfaces:**
- Produces: step `x18`; `arm64-x18path.exe [stress|time]` (also `x64-x18path.exe` from the same source) printing `ok <path>` per path and `PASS <its own exe name without .exe>` (so `exe_cmd` matches either build), or with `time` a line `time syscall <ns>`; the `WINE_X18_SELFTEST=double_on` hook.

- [ ] **Step 1: Write the failing tests.**
  - `arm64-x18v.c`: 16 threads, 1 s each, comparing x18 with `NtCurrentTeb()`; prints `PASS arm64-x18v`.
  - `arm64-x18path.c`: the paths of spec §9 T2, each `ok <path>` after checking x18 == TEB on return (200 thread cycles). `stress`: 4 threads × 3 s of `NtQuerySystemTime` and a no-op unix call (`NtYieldExecution`), while a fifth thread suspends, reads the context of and resumes them in a loop, and a `timeSetEvent` timer fires every 1 ms.
  - A Makefile rule builds `build/wine-arm64-tests/x64-x18path.exe` from `arm64-x18path.c` with the x86_64 compiler, listed in `wine-arm64-tests`.
- [ ] **Step 2: The step `x18`** (cap 180; after `msync`; in `NEEDS_PREFIX` and `NEEDS_FEX`):
  - T1: `exe_cmd arm64-x18v`;
  - T2: both `x18path` builds; T4: `arm64-x18path stress`;
  - T3: `WINE_X18_SELFTEST=double_on "$TOOL/Contents/MacOS/wine" "$TESTS/arm64-hello.exe"` must exit 133 with no `err:seh` line;
  - the static check: `otool -tV` of the bundle's `ntdll.so`, `;` comments stripped, shows x18 only inside `___wine_syscall_dispatcher`, `___wine_unix_call_dispatcher`, `_call_user_mode_callback` and `___wine_syscall_dispatcher_return`;
  - no `x18:` line anywhere.
  
  Run `sh wine-arm64/check.sh x18`. Expected: FAIL (T3 exits 0: no hook yet; the static check passes or fails as today).
- [ ] **Step 3: The patch.** In the Wine tree, rewrite patch 0004's commit in place:
  - note the SHAs of 0004 to 0016;
  - `git reset --hard <0004>`, edit, `git commit -a --amend` (keep the author; the message names the design doc);
  - `git cherry-pick <0005>..<tip>`;
  - check that only branch `macneutron` remains.
  
  Content, following `docs/research/2026-10-02-native-arm64/x18-boundaries.md` (its line numbers apply to pristine 11.19) and spec §9:
  - the toggles at the dispatchers' entry and exit and at callback entry, with registers parked;
  - `__wine_syscall_dispatcher_return` reads from `[sp,#0x90]`;
  - the nine-handler wrapper with the doc's rule; `SIGTRAP` with ESR immediate 1 and its PC inside the toggle routine goes to `SIG_DFL` and is re-raised;
  - the invariant on threads with a TEB (`write(2)` of `x18: PE stack running OFF`, then `abort()`);
  - `WINE_X18_SELFTEST=double_on`;
  - the once-per-thread hunk removed.
- [ ] **Step 4:** `make wine-arm64` (development), then `sh wine-arm64/check.sh x18`. Expected: `PASS x18`. Debug failures with superpowers:systematic-debugging.
- [ ] **Step 5:** `make wine-arm64-export`. Expected: `0004-…` changes, and `0005`–`0016` export byte-identical (`git diff --stat wine-arm64/patches/wine` shows only 0004). Then `make wine-arm64` (applied).
- [ ] **Step 6: M2.** Build the tree at the previous 0004 into a scratch `BUILD_DIR`, and time 10⁶ `NtQuerySystemTime` round trips in both bundles (`arm64-x18path time`, which prints `time syscall <ns>`). Record the difference; expected ≤ 4 ns.
- [ ] **Step 7:** Run `sh wine-arm64/check.sh`, every step. Expected: all PASS, `PASS orphans`. Commit: "wine-arm64: strict x18 toggling (patch 0004 rewritten)".

### Task 7: Acceptance and docs

**Files:**
- Create: `docs/testing/acceptance-arm64-ship-base.md`
- Modify: `wine-arm64/README.md`, `README.md`, the spec's status line

- [ ] **Step 1: A clean build.** `rm -rf build/wine-arm64-src build/wine-arm64`, then `make wine-arm64`. Record the time, the deps' time and the lsteamclient fetch.
- [ ] **Step 2:** `make wine-arm64-check 2>&1 | tee build/wine-arm64-ship-base-acceptance.log`. Expected: every step PASS, `PASS orphans`. Record the total time, M1's `time` rows (both modes) and the `info` lines (never the SteamID).
- [ ] **Step 3:** `make test`, `sh dxmt/tests/build_test.sh`, `make bridge-check`, `make dxmt-check`. Expected: pass.
- [ ] **Step 4:** Write the acceptance doc, covering everything spec §12 lists: the red runs from Tasks 1, 2 and 6, S1–S7, M1, M2, the bundle layout and licence tree, pins and patches.
  - `wine-arm64/README.md`: the new steps and prerequisites (Steam, SMITE 2, Screen Recording, GPTK), the deps, the credits, the check time.
  - The spec's status line: implemented.
  
  Commit: "docs: native arm64 sub-project 3 acceptance".
