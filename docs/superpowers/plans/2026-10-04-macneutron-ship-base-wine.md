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

- **Branch:** `feat/native-arm64-ship-base`, from `main` at `3abe687`. The plan was revised after an independent review (2026-10-04); Task 1 was already done (`3dfbf87`).
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
- **Order:** the tasks land in this order: licences, FreeType/gnutls, `wxflip-x64`, msync, the Steam bridge, strict x18. That differs from spec §10's order (bridge before msync, `wxflip-x64` after msync) so that the patch numbers match spec §1 (0015 msync, 0016 lsteamclient) and the cheap check runs early.
- **Scans:** any count that gates a decision uses `LC_ALL=C /usr/bin/grep` (the interactive `grep` here is a ugrep wrapper that can return 0).
- **msync agreement:** every run in `check.sh` sees `WINEMSYNC=1`, except inside the `msync` step, which owns its wineserver.
- **Cleanup:** `wineserver -k`, then `lsof -t <binary>` and kill; never `pkill -f`.
- **The Rosetta stack stays untouched:** after any task that touches `dxmt/`, `bridge/`, `presenter/` or the `Makefile`, `make test`, `sh dxmt/tests/build_test.sh`, `make bridge-check` and `make dxmt-check` pass.
- **Signing environment** for builds: `MACNEUTRON_SIGN_IDENTITY="Developer ID Application: Chad Cormier Roussel (49QMZXLR8S)"`, `MACNEUTRON_PROVISIONING_PROFILE="$HOME/Downloads/Mac_Neutron.provisionprofile"`.
- **Never** push, fork, open PRs, post, or propose reduced security.
- **Commits** end with the session's Co-Authored-By trailer.

## Review Focus

1. **A pin edit in `deps.pins` doesn't re-clone Wine or FEX.** Wine and FEX stay `applied` while only the deps (and the lsteamclient tree) are redone. Pinned in Task 2, Step 7 (a comment in `deps.pins` redoes nothing).
2. **Homebrew present or absent changes nothing.** The deps and Wine's configure never read `/opt/homebrew`. Pinned in Task 2, Steps 4 and 5 (`otool -L` of the deps, Wine's `config.log` scan).
3. **The `msync` step leaves the prefix usable.** `check.sh msync dxmt` passes, so the step after `msync` starts a mode-1 server cleanly. Pinned in Task 4, Step 6.
4. **Steam not reachable fails clearly, not by hanging.** With `STEAM_COMPAT_CLIENT_INSTALL_PATH` pointing at an empty folder, `steam-bridge` fails within its cap and names Steam. Pinned in Task 5, Step 8.
5. **A development lsteamclient tree** (an extra commit) builds as development, `SOURCE` says `dev` for it, no stamp is written, `make wine-arm64-export` brings it back to `applied`, and removing the patch file re-applies the tree. Pinned in Task 5, Step 9.

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
- Modify: `dxmt/lib.sh`, `wine-arm64/build.sh`, `wine-arm64/bundle.sh`, `wine-arm64/check.sh`, `wine-arm64/licenses/README`, `Makefile`

**Interfaces:**
- Consumes: Task 1's `put`, `$SRC/SOURCE`, `licences_test.sh`.
- Produces:
  - `fetch <url> <file> <sha256>` in `dxmt/fetch.sh`: uses the caller's `die`, prints `"${FETCH_TAG:-dxmt}: downloading <url>"`. `dxmt/lib.sh` sources it; `wine-arm64/build.sh` sources it with `FETCH_TAG=wine-arm64`.
  - `exe_cmd <name> [args…]` in `check.sh`: runs `$TESTS/<name>.exe` with the arguments, stdout through `tr -d '\r'` (printed), stderr to `$WORK/<name>.err`, passing on the line `PASS <name>`.
  - `sh wine-arm64/tools/x18scan.sh [-arch <a>] <mach-o>`: one line per hit, `<label> <instruction>`, where `<label>` is the enclosing `otool -tV` label without its `:`. It reads `otool [-arch <a>] -tV` with `;` comments stripped, matched by `LC_ALL=C /usr/bin/grep -E` with the regex of `docs/research/2026-10-02-native-arm64/probes/x18-cache-scan.sh`.
  - `wine-arm64/x18-allow.txt`: lines of `<file basename> <label> <count>`.
  - `build/wine-arm64-src/deps/`: `lib/libfreetype.6.dylib`, `lib/libgnutls.30.dylib`, `.complete`.
  - Step `fonts-tls`.

- [ ] **Step 1: Write the failing test** `wine-arm64/tests/arm64-fonts-tls.c` (aarch64 PE; Makefile `WA_FLAGS_arm64-fonts-tls = -lgdi32 -lsecur32 -ldwrite -lcrypt32`). Usage: `arm64-fonts-tls.exe <pfx path>`. It prints:
  - `font <height> <cx>x<cy> dbu <x>,<y>` (`CreateFontW` Tahoma 16 px, `GetTextMetricsW`, `GetTextExtentPoint32W(L"Hello")`, `GetDialogBaseUnits()`);
  - `dwrite families <n>` (`DWriteCreateFactory`, then the system font collection's family count);
  - `schannel: 0x%08lx` (`AcquireCredentialsHandleW(NULL, UNISP_NAME_W, SECPKG_CRED_OUTBOUND, …)`);
  - `pfx certs <n>` (`PFXImportCertStore` of the file with an empty password).

  It ends with `PASS arm64-fonts-tls` when all hold: height, cx, cy, both dbu values and families > 0; schannel = 0; certs = 1. Make the fixture with macOS's `openssl` (a throwaway self-signed `CN=MacNeutron test`, PKCS#12, empty password, the default MAC; if gnutls later refuses it, re-export with `-certpbe AES-256-CBC -keypbe AES-256-CBC -macalg sha256`), and commit it.
- [ ] **Step 2: Extend `exe_cmd`** as the Interfaces block says (every existing caller still passes; they take no arguments). Add the step `fonts-tls` (cap 60; before `dxmt` in `STEPS`; in `NEEDS_PREFIX`). It runs `exe_cmd arm64-fonts-tls "Z:$ROOT/wine-arm64/tests/fixtures/fonts-tls.pfx"`, and fails if `$WORK/arm64-fonts-tls.err` matches `cannot find the FreeType|failed to load libgnutls` (`LC_ALL=C /usr/bin/grep -iE`). Run `sh wine-arm64/check.sh fonts-tls`. Expected: FAIL, with `dbu 0,0` and `schannel: 0x80090305`. Record that output.
- [ ] **Step 3: Move `fetch`** into `dxmt/fetch.sh`. Run `sh dxmt/tests/build_test.sh`. Expected: all ok (it covers the checksum refusal).
- [ ] **Step 4: The deps step** in `build.sh`, after the trees are prepared and before Wine's configure:
  - `need_tool pkg-config pkg-config` joins the up-front tool list;
  - source `deps.pins` (the four tarballs' `<NAME>_URL`/`<NAME>_SHA256` lines); fetch the tarballs into `$SRC/`;
  - redo the step when `deps/.complete` doesn't hold the hash of `deps.pins`' `FREETYPE_`, `GNUTLS_`, `NETTLE_` and `GMP_` lines plus the step's configure lines. To redo: unpack into `$SRC/deps-src/`, then build gmp, nettle, gnutls (with `--sysconfdir=/etc`) and freetype as spec §5 says. The whole step runs with `CC=/usr/bin/clang`, `PKG_CONFIG_LIBDIR=$SRC/deps/lib/pkgconfig`, `PKG_CONFIG_PATH` unset, `CPPFLAGS=-I$SRC/deps/include` and `LDFLAGS=-L$SRC/deps/lib`;
  - afterwards, on both dylibs: `strip -S`, then `install_name_tool -id @rpath/<name>`;
  - assert, naming the library and its log (`$SRC/deps-<name>.log`) on failure:
    - `otool -L <dylib> | tail -n +3` names only `/usr/lib/…` and `/System/…`;
    - `libgnutls.30.dylib` names no nettle, hogweed or gmp;
    - `sed -n 's/^Requires.private: *//p' freetype2.pc` is empty;
  - `deps.pins` and `dxmt/fetch.sh` join `stamp_of`, not any `series_of`.
- [ ] **Step 5: Wine's configure.**
  - Add `--with-freetype --with-gnutls`, plus `PKG_CONFIG_LIBDIR`, `FREETYPE_CFLAGS=-I$SRC/deps/include/freetype2`, `FREETYPE_LIBS="-L$SRC/deps/lib -lfreetype"`, `GNUTLS_CFLAGS=-I$SRC/deps/include` and `GNUTLS_LIBS="-L$SRC/deps/lib -lgnutls"`.
  - Record the configure inputs (the configure line and `deps/.complete`) in `$SRC/wine-build/.configure-inputs`, and reconfigure (`rm -rf wine-build`) when they change.
  - After configure, die if any `cflags:` or `libs:` line in `wine-build/config.log` contains `/opt/homebrew`.
- [ ] **Step 6: `bundle.sh`.**
  - Copy both dylibs to `lib/wine/aarch64-unix/`. Copy the licence texts from the unpacked tarballs to `licenses/{freetype,gnutls,nettle,gmp}/`: FreeType's `LICENSE.TXT` and `docs/FTL.TXT`; gnutls's `COPYING.LESSERv2`, and its LGPLv3 and GPLv3 texts from nettle's `COPYING.LESSERv3` and `COPYINGv3`.
  - Add the tarball keys to `SOURCE`. Add rows to `licenses/README` for FreeType (FTL), gnutls (LGPL-2.1+, with its included libtasn1, and libunistring under LGPL-3+), nettle and gmp (LGPL-3+), each with its source URL.
  - Assert as spec §5 lists:
    - the install IDs;
    - every `otool -L` entry (after the ID line) of every Mach-O starts with `/usr/lib/`, `/System/`, `@rpath/`, `@loader_path/` or `@executable_path/`;
    - `x18scan.sh` on every arm64 Mach-O except `ntdll.so`, counted per file and label, equals `x18-allow.txt` exactly;
    - the symbol lists are in `nm -gU`. Regenerate them from Wine's sources at assert time: gnutls, the `^gnutls_` names on the non-`#define` `LOAD_FUNCPTR`/`MAKE_FUNCPTR` lines of `secur32/schannel_gnutls.c` and `crypt32/unixlib.c` plus the names in `dlsym(libgnutls_handle, "…")` calls (expected 70); FreeType, the `^FT_` names on those lines in `win32u/freetype.c` and `dwrite/freetype.c` (expected 46). Assert those counts too;
    - `LC_ALL=C /usr/bin/grep -a -c -F "$B"` = 0 on the two dylibs only (DXMT's `winemetal.so` names build paths by design).
  - `x18-allow.txt` holds `libgnutls.30.dylib gcm_ghash_v8_4x 1`, `libgnutls.30.dylib _sha256_block_data_order 3` and `libgnutls.30.dylib _sha512_block_data_order 3`. Confirm each by reading the routine's disassembly: the hits sit after its last `ret`.
  - `x18-allow.txt` and `x18scan.sh` join `stamp_of`.
- [ ] **Step 7: Build and check.**
  - Run `make wine-arm64`. Expected: built; the deps built once (time recorded).
  - Run `sh wine-arm64/check.sh fonts-tls`. Expected: `PASS fonts-tls`, with non-zero font numbers, `schannel: 0x00000000` and `pfx certs 1`.
  - Then add a comment line to `deps.pins` and run `make wine-arm64` again. Expected: neither the deps nor Wine's configure is redone (only the stamp changes), and `build_mode` of the Wine and FEX trees still prints `applied`.
  - Change gmp's pin to a deliberately wrong SHA-256 and run `make wine-arm64`. Expected: it stops naming `gmp-6.3.0.tar.xz` and moves it aside. Restore the pin.
- [ ] **Step 8: Makefile and provenance.**
  - `wine-arm64-check` gains `bridge` as a prerequisite, and the line `sh wine-arm64/tests/licences_test.sh --self-test build/wine-arm64/wine.app` after the plain test.
  - In `build.sh`, `MACNEUTRON_COMMIT` gets `+dirty` when `git status --porcelain -- wine-arm64 dxmt bridge Makefile` lists anything, untracked files included.
  - Run `make test`, `sh dxmt/tests/build_test.sh`, `make bridge-check` and `make dxmt-check`. Expected: pass.
  - Commit: "wine-arm64: FreeType and gnutls built from pinned source and bundled".

### Task 3: `wxflip-x64`

**Files:**
- Modify: `wine-arm64/check.sh`

- [ ] **Step 1:** Add `wxflip_x64_cmd`, modelled on `wxflip_cmd` (output captured with `2>&1`). It runs `WINEDEBUG=+wxflip` `wine_run "$TESTS/x64-smc.exe"`, requires the line `PASS x64-smc` and `LC_ALL=C /usr/bin/grep -c trace:wxflip` = 0, and prints `info wxflip-x64: <n> flips`.
  - The step has cap 60, comes after `wxflip` in `STEPS`, and is in `NEEDS_PREFIX` and `NEEDS_FEX`.
  - Extend the line that pulls `wxflip` in for `g5-jit` so it also pulls it in for `wxflip-x64`.
- [ ] **Step 2:** Run `sh wine-arm64/check.sh wxflip-x64`. Expected: `PASS wxflip`, `PASS wxflip-x64`, `info wxflip-x64: 0 flips`. **If it shows flips, stop and report to the maintainer** (spec §8: the scope comes back).
- [ ] **Step 3:** Commit: "wine-arm64: check that x64 JIT memory under FEX never flips W^X".

### Task 4: msync (Wine patch 0015)

**Files:**
- Create: `wine-arm64/patches/wine/0015-*.patch` (exported), `wine-arm64/tests/x64-sync.c`
- Modify: `wine-arm64/check.sh`, `wine-arm64/README.md`, `wine-arm64/licenses/NOTICES.md`, `wine-arm64/tests/licences_test.sh`

**Interfaces:**
- Consumes:
  - the Wine tree `build/wine-arm64-src/wine`;
  - the local winecx clone `build/arm64/crossover/wine`, branch `cx/wine1117` at `e0aa380780`, always read with `GIT_NO_LAZY_FETCH=1`;
  - Task 2's `exe_cmd`.
- Produces:
  - step `msync`;
  - `x64-sync.exe [child]`, printing `ok <row>` or `FAIL <row>: …` lines, `time <row> <ns>` lines, and `PASS x64-sync`.

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
  - `named-cross-process` (the exe starts itself with `child`);
  - `duplicate-handle`;
  - `many-events-cross-process` (3,200 events);
  - `create-close-churn` (50,000).

  `pulse-event` is printed as `info`. The timing rows `time uncontended-wait`, `time uncontended-signal`, `time cross-process-wake` and `time create-close` print median ns.
- [ ] **Step 2: The step `msync`.** Add `export WINEMSYNC=1` near the top of `check.sh`. The step has cap 300, comes after `wxflip-x64`, and is in `NEEDS_PREFIX` and `NEEDS_FEX`. With `S="$TOOL/Contents/Resources/bin/wineserver"` and `WINEPREFIX="$PFX"` on every server command, it runs:
  1. `"$S" -k`;
  2. `WINEMSYNC=1 "$S" -p 2> "$WORK/msync-server-1.log"`;
  3. `WINEMSYNC=1 exe_cmd x64-sync`;
  4. the mismatch client `WINEMSYNC=0 wine_run "$TESTS/x64-sync.exe"`: it must exit non-zero with "Server is running with WINEMSYNC but this process is not" in its stderr;
  5. `"$S" -k`;
  6. `WINEMSYNC=0 "$S" -p 2> "$WORK/msync-server-0.log"`;
  7. `WINEMSYNC=0 exe_cmd x64-sync`;
  8. the mismatch client `WINEMSYNC=1 wine_run "$TESTS/x64-sync.exe"`: it must exit non-zero with "Failed bootstrap_look_up";
  9. `"$S" -k`.

  The mode rows: `msync: up and running.` is in `msync-server-1.log` only, and neither log matches `msync: (error|failed|couldn't)`. Print the `time` rows as `info msync <mode> <row> <ns>`. Run `sh wine-arm64/check.sh msync`. Expected: FAIL (no `msync: up and running.`).
- [ ] **Step 3: The patch.** In the Wine tree:
  - `git apply --exclude=include/wine/server_protocol.h --exclude=server/request_handlers.h --exclude=server/request_trace.h docs/research/2026-10-04-ship-base/msync-on-11.19-trial.diff`;
  - copy the 4 msync files from `cx/wine1117` (`GIT_NO_LAZY_FETCH=1 git -C build/arm64/crossover/wine show cx/wine1117:<path>`);
  - put `msync_init()` after `server_init_process( data )` in `loader.c`;
  - make `linux_wait_objs` take the wait type (`type != WaitAll`);
  - allocate `shm_addrs` once at full size, computed from `vm_kernel_page_size`, on both sides;
  - run `perl tools/make_requests`, and check that `git diff` raises `SERVER_PROTOCOL_VERSION` by exactly one (962 → 963).

  Commit with a message that credits Zebediah Figura and Marc-Aurel Zent (msync), CodeWeavers CrossOver 26.3 as carried on `dappermint/winecx` `cx/wine1117` at `e0aa380780`, and millia ampora's commits `8df1826853` `9be392b3b4` `3a7a712d66` `307f90fdb1` `620d8c542f` `a7ef7b3b01` `ef72fdb55b` `6d316146c2`.
- [ ] **Step 4:** Run `make wine-arm64` (a development build), then `sh wine-arm64/check.sh msync`. Expected: `PASS msync`, with the `info msync` timing lines.
- [ ] **Step 5:** Run `make wine-arm64-export` (expect `0015-…`), then `make wine-arm64` (applied). Add the msync credits to `wine-arm64/README.md`'s licence section and the authors to `NOTICES.md`. `licences_test.sh` then requires "Zebediah Figura" and "Marc-Aurel Zent" in `NOTICES.md`.
- [ ] **Step 6:** Run `sh wine-arm64/check.sh msync dxmt dxmt-present`. Expected: all PASS, `PASS orphans` (the step after `msync` starts cleanly in mode 1).
- [ ] **Step 7:** Commit: "wine-arm64: msync (patch 0015), on by default in the checks".

### Task 5: The Steam bridge (Wine patch 0016)

**Files:**
- Create: `wine-arm64/patches/lsteamclient/0001-0003-*.patch`, `wine-arm64/patches/wine/0016-*.patch` (exported)
- Modify: `wine-arm64/deps.pins`, `wine-arm64/build.sh`, `wine-arm64/export.sh`, `wine-arm64/bundle.sh`, `wine-arm64/check.sh`, `wine-arm64/licenses/README`, `wine-arm64/tests/licences_test.sh`, `bridge/check.sh`, `bridge/probe.sh`, `bridge/probe.c`, `Makefile`, `wine-arm64/README.md`

**Interfaces:**
- Consumes: Task 2's `deps.pins`, `x18scan.sh` and `exe_cmd`; Task 1's `SOURCE` and `licences_test.sh`.
- Produces:
  - tree `build/wine-arm64-src/lsteamclient` (branch `macneutron`; `lsteamclient.applied`, and `lsteamclient.series` = the hash of `deps.pins`' `LSTEAMCLIENT_` lines plus `patches/lsteamclient/*.patch`);
  - `MACNEUTRON_ARM64_APP` arm64 modes of `bridge/check.sh` and `bridge/probe.sh`, both using `WINEPREFIX="$MACNEUTRON_ARM64_PREFIX"`;
  - `steamprobe.exe <steam_api64.dll> [fault]`;
  - step `steam-bridge`.

- [ ] **Step 1: The three patches first**, in a scratch sparse clone of Proton at the pin (Step 2's recipe, outside `build/`). Each "after" file comes from the winecx clone (`GIT_NO_LAZY_FETCH=1`; the blobs `190447ca` `Makefile.in`, `a6626286` and `095846d9` are present; the "before" files are Proton's own at `db9e6ff`). Commits, each with `--author="millia ampora <198710911+dappermint@users.noreply.github.com>"` and "From dappermint/winecx <sha>" in the message:
  1. `8d188ec0db`: NOMINMAX (`-DNOMINMAX` in `Makefile.in`) and the X11 keysym guard;
  2. `dada36ebab`: `UNIX_LIBS = -lc++` in `Makefile.in`;
  3. `6cfbd169a5`: the Proton-only client exports made optional.

  Export them with `git format-patch --zero-commit -N` into `wine-arm64/patches/lsteamclient/`.
- [ ] **Step 2: The tree.** `fetch_lsteamclient`, modelled on `fetch_fex`, with `GIT_NO_LAZY_FETCH` unset:
  - `git init`, `git remote add origin $LSTEAMCLIENT_REPO`;
  - `git fetch --depth 1 --filter=blob:none origin $LSTEAMCLIENT_COMMIT`;
  - `git sparse-checkout set --no-cone '/lsteamclient/' '!/lsteamclient/steamworks_sdk_*/' '!/lsteamclient/gen_wrapper.py'`;
  - `checkout -b macneutron FETCH_HEAD`;
  - `patch_tree` with `patches/lsteamclient/`.

  Add `LSTEAMCLIENT_REPO`/`LSTEAMCLIENT_COMMIT` to `deps.pins`. Add the tree to the modes, the development test, `prepare`, `export.sh` (its pre-export check loop and `export_tree lsteamclient "$LSTEAMCLIENT_COMMIT" …` with the same series rule) and `SOURCE` (`LSTEAMCLIENT_COMMIT`, `LSTEAMCLIENT_SERIES`). After the trees are prepared, link it with `ln -sfn ../../lsteamclient/lsteamclient "$W/dlls/lsteamclient"`, and add `/dlls/lsteamclient` to `$W/.git/info/exclude` (the Wine tree stays `applied`).
- [ ] **Step 3: Wine patch 0016.** In the Wine tree, register `dlls/lsteamclient`: in `configure.ac` the `WINE_CONFIG_MAKEFILE(dlls/lsteamclient)` line, and in `configure` the `enable_lsteamclient` variable and the `wine_fn_config_makefile dlls/lsteamclient enable_lsteamclient` line, following `lz32`'s pattern (the patches carry configure; no autoreconf). Commit. Add `CXX=/usr/bin/clang++` to `build.sh`'s configure line (a configure-inputs change, so Wine reconfigures).
- [ ] **Step 4: `bundle.sh`.**
  - Copy lsteamclient's `LICENSE` to `licenses/lsteamclient/`, with a `NOTE` saying its `cxx.h` is LGPL-2.1+ (CodeWeavers, from Wine).
  - Add a `licenses/README` row (Valve's Steamworks SDK licence; source: Proton at the pin plus our patches; release redistribution is undecided, spec §1). `licences_test.sh` requires `lsteamclient/NOTE` once `lsteamclient.so` is present.
  - Assert as spec §7 lists:
    - CHPE metadata in `llvm-readobj --coff-load-config` of `aarch64-windows/lsteamclient.dll`, and the builtin marker;
    - the `.so` is arm64 and exports `___wine_unix_call_funcs`;
    - `nm -u` of the `.so`, filtered to `_Nt*` and `___wine_*`, is covered by `nm -gU` of `ntdll.so`;
    - `wine.entitlements` has `com.apple.security.cs.disable-library-validation`.
- [ ] **Step 5: Build.** Run `make wine-arm64-export` (expect `exported 3 lsteamclient patches` and Wine's `0016-…`), then `make wine-arm64`. Expected: built applied; `licences_test.sh` passes, including lsteamclient's licence, note and keys.
- [ ] **Step 6: The bridge's arm64 parts.**
  - The `Makefile` `bridge` target also builds `steam.exe` and `tests/helper.exe` with `$(MINGW_BIN)/aarch64-w64-mingw32-clang` into `build/bridge/arm64/`, and the `steamprobe.exe` line gains `-fms-extensions`.
  - `probe.c`'s optional second argument `fault`: after the ticket rows, a `__declspec(noinline)` helper stores through a NULL pointer, called inside `__try`/`__except`, then it prints `fault: caught`.
  - `bridge/check.sh` gains an arm64 mode when `MACNEUTRON_ARM64_APP` is set: `WINE=$MACNEUTRON_ARM64_APP/Contents/MacOS/wine`, `WINEPREFIX="$MACNEUTRON_ARM64_PREFIX"` (no boot), `steam.exe` and `helper.exe` from `build/bridge/arm64/`, and helper paths under `${BRIDGE_CHECK_WORK:-…}`. Its checks are unchanged.
  - `bridge/probe.sh` gains the same arm64 mode: it uses `${STEAM_COMPAT_CLIENT_INSTALL_PATH:-<Mac Steam's path>}`, copies the bundle's `aarch64-windows/lsteamclient.dll` as `steamclient64.dll`, and runs the x64 `steamprobe.exe <dll> fault`.
  - With `PROBE_REDACT=1`, `probe.sh` sets `WINEDEBUG=-all`, keeps only lines starting with `load|init|SteamUser|SteamFriends|auth ticket|callback|fault|missing export|steamid|persona`, and rewrites them through `sed -E 's/^steamid: [1-9][0-9]*$/steamid ok/; s/^steamid: 0$/steamid FAIL/; s/^persona: .+/persona ok/; s/7656119[0-9]{10}/<steamid>/g'`.
- [ ] **Step 7: The step `steam-bridge`** (cap 300; last of the new steps, before `dxmt`; in `NEEDS_PREFIX` and `NEEDS_FEX`). It:
  - sets `ShowCrashDialog=0` in `$PFX` (as `dxmt_cmd` does);
  - fails with `Steam's steamclient.dylib not found at <path>` when the file is missing, and with `SMITE 2 isn't installed` when `$SMITE2_API` is missing. `SMITE2_API` is `$HOME/Library/Application Support/Steam/steamapps/common/SMITE 2/Windows/Engine/Binaries/ThirdParty/Steamworks/Steamv157/Win64/steam_api64.dll`;
  - runs `bridge/check.sh` in arm64 mode, which must pass;
  - runs `PROBE_REDACT=1 bridge/probe.sh "$SMITE2_API"` in arm64 mode. It requires `init: ok`, `steamid ok`, `persona ok`, an `auth ticket: handle …, <n> bytes` line with n > 0, `auth ticket: callback, result 1` and `fault: caught`. An `init: FAIL` is reported as `SteamAPI_Init failed: is Steam running and logged in?`;
  - reports `info steam x18: <n> hits` from `x18scan.sh -arch arm64` on the installed `steamclient.dylib`, not gated.
- [ ] **Step 8:** Run `sh wine-arm64/check.sh steam-bridge`. Expected: `PASS steam-bridge`, and `LC_ALL=C /usr/bin/grep -cE '7656119[0-9]{10}' "build/wine-arm64 check/steam-bridge.log"` = 0. Then, with `STEAM_COMPAT_CLIENT_INSTALL_PATH` pointed at an empty folder (the step passes it through when set), run it again. Expected: FAIL within the cap, naming the missing `steamclient.dylib`.
- [ ] **Step 9: A development lsteamclient tree, out and back.**
  1. Commit a comment-only change in `build/wine-arm64-src/lsteamclient` and run `make wine-arm64`. Expected: `development build`, `SOURCE` has `LSTEAMCLIENT_SERIES=dev`, no stamp.
  2. Run `make wine-arm64-export` (a fourth lsteamclient patch appears) and `make wine-arm64`. Expected: applied, stamp written.
  3. Delete that patch file and run `make wine-arm64`. Expected: `reapply`, then applied with the three patches.
- [ ] **Step 10:** Run `make test`, `sh dxmt/tests/build_test.sh`, `make bridge-check` and `make dxmt-check`. Expected: pass. Update the README: the bridge on arm64, its prerequisites (Steam running and logged in, SMITE 2), and lsteamclient's licence note. Commit: "wine-arm64: the Steam bridge on arm64 (lsteamclient ARM64X, patch 0016)".

### Task 6: Strict x18 (patch 0004 rewritten)

**Files:**
- Modify: `wine-arm64/patches/wine/0004-*.patch` (re-exported; same number), `wine-arm64/check.sh`, `Makefile`
- Create: `wine-arm64/tests/arm64-x18v.c` (from `build/arm64/entitled/verify/x18v.c`), `wine-arm64/tests/arm64-x18path.c`

**Interfaces:**
- Consumes: Task 2's `exe_cmd`.
- Produces:
  - step `x18`;
  - `arm64-x18path.exe [stress|time]`, also built as `x64-x18path.exe` from the same source. It prints `ok <path>` per path and `PASS <its own exe name without .exe>`; `time` prints `time syscall <ns>` and `time unixcall <ns>`;
  - the `WINE_X18_SELFTEST=double_on` hook.

- [ ] **Step 1: Write the failing tests.** Both read the thread's TEB once per thread through `NtQueryInformationThread(ThreadBasicInformation).TebBaseAddress` (x18v.c's `kernel_teb()`), and compare raw x18 (read with inline asm under `#ifdef __aarch64__`) against that. They never use `NtCurrentTeb()`, which reads x18 itself.
  - `arm64-x18v.c`: 16 threads for 1 s each. Its summary line is `x18v: <threads> threads, <mismatches> mismatches`, then `PASS arm64-x18v`.
  - `arm64-x18path.c`: the paths of spec §9 T2 (200 thread cycles), each `ok <path>` after an x18 check on return. In the x64 build there's no x18 to read: its gate is the `ok` rows, its PASS line, and no invariant line.
  - `stress`: 4 threads × 3 s alternate `NtQuerySystemTime` (a syscall) and `GetSystemTimePreciseAsFileTime` (a unix call), while a fifth thread suspends, reads the context of and resumes them in a loop (`SIGUSR1`).
  - `time`: the median ns of 10⁶ `NtQuerySystemTime` and 10⁶ `GetSystemTimePreciseAsFileTime`.
  - Makefile: `WA_FLAGS_arm64-x18path = -lntdll`, and a rule building `build/wine-arm64-tests/x64-x18path.exe` from `arm64-x18path.c` with the x86_64 compiler and the same flag, listed in `wine-arm64-tests`.
- [ ] **Step 2: The step `x18`** (cap 180; after `msync`; in `NEEDS_PREFIX` and `NEEDS_FEX`):
  - T1: `exe_cmd arm64-x18v`;
  - T2: `exe_cmd arm64-x18path` and `exe_cmd x64-x18path`;
  - T4: `exe_cmd arm64-x18path stress`;
  - T3: `WINE_X18_SELFTEST=double_on wine_run "$TESTS/arm64-hello.exe" > "$WORK/x18-t3.log" 2>&1 && rc=0 || rc=$?` (no pipe) must give rc 133 with no `err:seh` line in the log;
  - the static check: in `otool -tV` of the bundle's `ntdll.so` with `;` comments stripped, x18 appears only under the labels `___wine_syscall_dispatcher`, `___wine_unix_call_dispatcher`, `_call_user_mode_callback` and `___wine_syscall_dispatcher_return`;
  - no line `x18: PE stack running OFF` in any of the step's `.err` files or logs.

  Then run M2's "A" now, on the current bundle (old patch 0004): `exe_cmd arm64-x18path time`, recording both `time` lines. Run `sh wine-arm64/check.sh x18`. Expected: FAIL (T3 exits 0: no hook yet).
- [ ] **Step 3: The patch.** In the Wine tree, rewrite patch 0004's commit in place:
  - note the SHAs of the old 0004 and of the tip (0016);
  - `git reset --hard <old 0004>`, edit, then `git commit -a --amend -F <msgfile>` (keep the author; the message names the design doc);
  - `git cherry-pick <old 0004>..<old tip>` (this range starts at 0005);
  - check that only branch `macneutron` remains.

  Content, following `docs/research/2026-10-02-native-arm64/x18-boundaries.md` (its line numbers apply to pristine 11.19) and spec §9:
  - the toggles at the dispatchers' entry and exit and at callback entry, with registers parked;
  - `__wine_syscall_dispatcher_return` reads the TEB from `[sp,#0x90]`;
  - the nine-handler wrapper with the doc's rule. A `SIGTRAP` with ESR immediate 1 and its PC inside the toggle routine goes to `SIG_DFL` and is re-raised;
  - the invariant on threads with a TEB: `write(2)` of `x18: PE stack running OFF`, then `abort()`;
  - `WINE_X18_SELFTEST=double_on`;
  - the once-per-thread hunk removed.
- [ ] **Step 4:** Run `make wine-arm64` (development), then `sh wine-arm64/check.sh x18`. Expected: `PASS x18`. Debug failures with superpowers:systematic-debugging.
- [ ] **Step 5:** Run `make wine-arm64-export`. Expected: `git status --short wine-arm64/patches/wine` shows only 0004 changed (renamed, if its subject changed); 0005–0016 are byte-identical. Then `make wine-arm64` (applied).
- [ ] **Step 6: M2's "B".** Run `exe_cmd arm64-x18path time` on the new bundle. Record the difference against A for both rows; the syscall row is expected to differ by ≤ 4 ns.
- [ ] **Step 7:** Run `sh wine-arm64/check.sh` (every step), `make test`, `sh dxmt/tests/build_test.sh`, `make bridge-check` and `make dxmt-check`. Expected: all PASS, `PASS orphans`. Commit: "wine-arm64: strict x18 toggling (patch 0004 rewritten)".

### Task 7: Acceptance and docs

**Files:**
- Create: `docs/testing/acceptance-arm64-ship-base.md`
- Modify: `wine-arm64/README.md`, `README.md`, the spec's status line

- [ ] **Step 1: A clean build** of what this sub-project adds: `rm -rf build/wine-arm64-src/wine-build build/wine-arm64-src/deps build/wine-arm64-src/deps-src build/wine-arm64-src/lsteamclient build/wine-arm64`, then `make wine-arm64`. The Wine, FEX and DXMT trees and the LLVM builds stay; the deps tarballs are reused. Record the time, the deps' time and the lsteamclient fetch.
- [ ] **Step 2:** Run `make wine-arm64-check 2>&1 | tee build/wine-arm64-ship-base-acceptance.log`. Expected: every step PASS, including the licence test's `--self-test`, and `PASS orphans`. Record the total time, M1's `info msync` rows (both modes), and the `info` lines (never a SteamID: check the log with the `7656119` grep).
- [ ] **Step 3:** Run `make test`, `sh dxmt/tests/build_test.sh`, `make bridge-check` and `make dxmt-check`. Expected: pass.
- [ ] **Step 4: Write the acceptance doc**, with everything spec §12 lists:
  - the red runs: Task 1's 46 MISSING, Task 2's fonts, Task 4's msync and Task 6's x18;
  - S1–S7, M1 and M2;
  - the bundle layout and the licence tree;
  - the pins and the patches.

  `wine-arm64/README.md`: the new steps and prerequisites (Steam, SMITE 2, Screen Recording, GPTK), the deps, the credits and the check time. Set the spec's status line to implemented, and its §12 red count to 46. Commit: "docs: native arm64 sub-project 3 acceptance".
