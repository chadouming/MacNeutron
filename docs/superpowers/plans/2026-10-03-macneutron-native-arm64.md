# Native arm64 Stack, Sub-project 1 (arm64 Wine + FEX for x64) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `make wine-arm64` builds upstream Wine 11.19 plus FEX from committed pins and patches into an entitled, 4K-page, Developer ID-signed `wine.app`. In it, x64 Windows programs run correctly under FEX. `make wine-arm64-check` proves that with gates G1, G2, G3 and G5, and measures G4 against Rosetta.

**Architecture:** A new `wine-arm64/` folder, modelled on `dxmt/`:
- **Pins and patch files are the source of truth.** `build.sh` clones the pinned Wine and FEX into `build/wine-arm64-src/`, applies the patch files with `git am`, builds, and installs Wine's tree under `wine.app/Contents/Resources`.
- **`bundle.sh`** adds the entitled loader at `Contents/MacOS/wine`, plus two in-bundle symlinks, signs everything, and asserts the layout.
- **`check.sh`** runs the staged bundle from an APFS clone at a path with spaces, step by step. Each Wine patch, FEX patch and gate lands with the check step that proves it.

**Tech Stack:**
- POSIX sh and zsh
- GNU autotools (Wine)
- CMake + Ninja (FEX)
- Apple clang
- llvm-mingw 20260908: `aarch64-`, `arm64ec-` and `x86_64-w64-mingw32-clang`
- `codesign`, `security cms`
- Python 3 (report helpers)
- C/C++ test programs

**Spec:** `docs/superpowers/specs/2026-10-02-macneutron-native-arm64-design.md`. The evidence it cites is in `docs/research/2026-10-02-native-arm64/`; the trial's six patches are in `trial-patches/`.

## Global Constraints

- **Pins:**
  - Wine `https://gitlab.winehq.org/wine/wine.git` at `455e3509b98a6919fd4ad1def4803e08c41c03b2` (`wine-11.19`).
  - FEX `https://github.com/FEX-Emu/FEX.git` at `4ed80fd07176dce976a7351f559d59a47b68cbae`, with submodules.
  - llvm-mingw comes from `dxmt/pins` through `sh dxmt/toolchain.sh`; there is no second pin.
- **Identity:**
  - App ID `net.authspot.macneutron.wine`, team `49QMZXLR8S`.
  - Signing identity from `MACNEUTRON_SIGN_IDENTITY`, provisioning profile path from `MACNEUTRON_PROVISIONING_PROFILE`.
  - The profile is never committed or copied into the repo.
- **Entitlements, exactly:**
  - `com.apple.application-identifier` = `49QMZXLR8S.net.authspot.macneutron.wine`
  - `com.apple.developer.team-identifier` = `49QMZXLR8S`
  - `com.apple.developer.cross-architecture-support`
  - `com.apple.security.cs.allow-jit`, `com.apple.security.cs.allow-unsigned-executable-memory`, `com.apple.security.cs.disable-library-validation`

  Only `Contents/MacOS/wine` carries them. Everything is signed with the hardened runtime (`--options runtime`).
- **macOS 27:** deployment target `27.0` (`MACOSX_DEPLOYMENT_TARGET=27.0` for Wine, `CMAKE_OSX_DEPLOYMENT_TARGET=27.0` for FEX's unixlib); every Mach-O in the bundle has `minos 27.0`; `check.sh` refuses macOS below 27.
- **Wine configure line, exactly:**
  ```
  --enable-archs=arm64ec,aarch64 --with-mingw=llvm-mingw --disable-tests --without-x --without-wayland
  --without-oss --without-alsa --without-pulse --without-sane --without-usb --without-v4l2 --without-pcap
  --without-capi --without-opencl --without-cups CC=/usr/bin/clang
  ```
- **Boot environment:** `WINEDLLOVERRIDES="mscoree,mshtml="` for every `wineboot` the scripts run.
- **Cleanup:** stop Wine with `wineserver -k`, then kill the processes whose executable is one of the runtime's binaries (`lsof -t <binary>`). Never use `pkill -f <path>`: Wine rewrites argv.
- **FEX registration:** `HKLM\Software\Microsoft\Wow64\amd64`, default value `libarm64ecfex.dll`.
- **Licences:**
  - Wine stays LGPL.
  - FEX patches derived from Madeira (`willfaust/FEX`, branch `ios-port-2607`) are MIT, with attribution (amended 2026-10-03, as in the spec: every Madeira commit used is dated before 2026-08-28, which Madeira's `LICENSE-MADEIRA.md` grants under MIT irrevocably); each keeps the original author and names the source commit in its message.
  - Patch 6 keeps its original author.
- **Never:** push, fork, open MRs or PRs, or post anywhere. Ask in chat before every `brew install`, and before any download not pinned in `wine-arm64/pins` or `dxmt/pins`.
- **The Rosetta stack stays untouched:** `make test` and `make dxmt-check` pass after every task that touches shared files (`Makefile`, `README.md`).
- **Commits** end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Time box:** three weeks from Task 1. The week-1 checkpoint and the end-of-box outcomes are spec §8's.

## Plan-level decisions (beyond the spec's text)

1. **Check steps have names, not numbers.** Each task appends its steps to `check.sh`'s ordered list. `check.sh <name>…` runs only the named steps, after the setup they need. **Every run starts fresh:** `cleanup`, `rm -rf "$WORK"`, a new clone of the staged bundle, a new prefix; a named-step run that needs a prefix runs `boot` first. `step` exits on the first FAIL, so a task's RED step runs each failing step in its own invocation.
2. **Where the check runs.** `check.sh` clones `build/wine-arm64/wine.app` with `cp -cR` to `build/wine-arm64 check/Application Support/wine.app`. Both folder names contain a space on purpose: Sub-project 5 installs under `~/Library/Application Support`.
3. **One test-program rule.** The file-name prefix picks the compiler:
   - `arm64-*.c` → `aarch64-w64-mingw32-clang`
   - `arm64ec-*.c` → `arm64ec-w64-mingw32-clang`
   - `x64-*.c` → `x86_64-w64-mingw32-clang`
   - `x64-*.cpp` → `x86_64-w64-mingw32-clang++ -static`

   All use `-O1 -fms-extensions -D_WIN32_WINNT=0x0A00` (llvm-mingw defaults to 0x601, which hides `IsWow64Process2` and `MapViewOfFile3`); `arm64ec-viewec` also links `-lonecore`, and output goes to `build/wine-arm64-tests/<name>.exe`. Each test prints `PASS <name>` or `FAIL <name>: <why>` as its last line, and exits 0 or 1.
4. **Development mode.** After `git am`, `build.sh` writes the resulting HEAD to `build/wine-arm64-src/<repo>.applied` and the patch series' hash to `<repo>.series`. A source tree that is dirty (tracked files only), or whose HEAD differs from `.applied`, is a development build: no fetch, no `git am`, no stamp skip. A clean tree whose recorded series differs from the committed one is re-cloned and re-patched (`reapply`). The build is a development build if either tree (Wine or FEX) is.
5. **The dual-view pool is fixed:** one 1 GiB `SEC_COMMIT` section, mapped once RW and once RX, at FEX start. Executable allocations are carved from it first-fit. Pagefile-backed pages that are never touched cost nothing.
6. **Profile validation reads the decoded plist.** `bundle.sh` decodes it with `security cms -D`, then requires (PlistBuddy paths, as in the real decoded profile):
   - `:Entitlements:com.apple.application-identifier` = `49QMZXLR8S.net.authspot.macneutron.wine`;
   - `:Entitlements:com.apple.developer.cross-architecture-support` = true;
   - `:ExpirationDate` in the future (PlistBuddy prints it as `%a %b %d %T %Z %Y`).

   This lives in a testable function that takes a plist file.
7. **Report helpers are Python with a self-test:**
   - `wine-arm64/tools/cpuregs.py` decodes the CPU ID registry values (G3).
   - `wine-arm64/tools/bench_report.py` computes medians, ratios and geometric means (G4).

   Each has `--self-test`.
8. **Patch 3's comment is corrected when imported.** It says an unentitled exec "falls back to execv"; in fact the kernel SIGKILLs it. Patch 7 then adds the real check.
9. **Patches are named by subject, not number.** `git format-patch` numbers by commit order, so a bring-up fix from Tasks 5–7 shifts the numbers of patches added later. Spec patch numbers (7–12) identify patches in prose only.
10. **Patch sources.** Madeira's commits are in local clones: `build/arm64/madeira/wine` (`ac650deca3`, `d88d55eee0`) and `build/arm64/madeira/fex` (`fdf361f0e`, `ceabf254a`, and the six dual-map commits). dappermint's macOS unixlib commit is pinned in `wine-arm64/pins` as `FEX_MACOS_REPO=https://github.com/dappermint/FEX.git` and `FEX_MACOS_COMMIT=4efc3abc8aca…` (full SHA resolved with `git ls-remote`/`git fetch` once), so fetching it is a pinned download.

## Review Focus

- **A loader that lost its entitlement.** Examples: `make` relinked it in the development loop, or someone copied it by hand. Wine must exit within seconds with patch 7's message naming the binary, never be SIGKILLed silently or hang. Test: check step `unentitled` (Task 3).
- **The runtime at a path with spaces, reached through a clone.** It must boot, run every process at 4K, and still pass `codesign --verify --strict --deep` after `cp -cR`. Test: every check step runs from `…/build/wine-arm64 check/Application Support/wine.app` (Task 2). Step `signature` runs on that clone, not on the staged copy.
- **A wrong, expired or unrelated provisioning profile.** `bundle.sh` must stop before signing, naming what is wrong (another App ID, no cross-architecture entitlement, expired, not a profile at all). Test: `wine-arm64/tests/profile_test.sh` (Task 2).
- **Orphaned Wine processes after a failing or hanging step.** Nothing from either runtime may be left after `check.sh` exits, whatever the reason. Test: the `EXIT` trap runs `cleanup`, then asserts no process runs any runtime binary. Its last line is `PASS orphans` or `FAIL orphans`, printed even after an earlier failure (Task 2).
- **An edit in the development tree must rebuild, and a clean tree must reproduce the committed patches.** Test: `wine-arm64/tests/mode_test.sh` covers the `build_mode` decision (Task 1).

---

## File Structure

| Path | Responsibility |
|---|---|
| `wine-arm64/pins` | `WINE_REPO`, `WINE_COMMIT`, `FEX_REPO`, `FEX_COMMIT` |
| `wine-arm64/lib.sh` | Shared sh helpers: `die`, `need_tool`, `build_mode`, `stamp_of`, `check_profile_plist` |
| `wine-arm64/build.sh` | `make wine-arm64`: tools, fetch, `git am`, configure, make, install into the bundle tree, FEX, `bundle.sh`, stamp |
| `wine-arm64/bundle.sh` | Bundle layout, symlinks, profile, signing, every §7.2 and §4 assertion |
| `wine-arm64/export.sh` | `make wine-arm64-export`: `git format-patch` from the development branches into `patches/` |
| `wine-arm64/check.sh` | `make wine-arm64-check`: named steps, cleanup, the gates |
| `wine-arm64/wine.entitlements` | The six entitlements |
| `wine-arm64/Info.plist` | Bundle id, executable `wine`, `LSMinimumSystemVersion` 27.0 |
| `wine-arm64/patches/wine/00NN-*.patch` | Wine patches 1–12 (spec §5.2) |
| `wine-arm64/patches/fex/00NN-*.patch` | FEX patches (spec §6.1; numbered by commit order, decision 9) |
| `wine-arm64/tests/*.c`, `*.cpp` | Test programs (decision 3) |
| `wine-arm64/tests/mode_test.sh`, `profile_test.sh`, `fixtures/` | Unit tests for `lib.sh` |
| `wine-arm64/tools/cpuregs.py`, `bench_report.py` | Report helpers (decision 7) |
| `wine-arm64/README.md` | What it builds, what it needs, the development loop, licences |
| `Makefile` | `wine-arm64`, `wine-arm64-tests`, `wine-arm64-check`, `wine-arm64-export` |
| `docs/testing/acceptance-arm64-wine.md` | Spec §10 acceptance record |

---

### Task 1: Pins, patches 1–6 and `make wine-arm64` (Wine only)

**Files:**
- Create:
  - `wine-arm64/pins`
  - `wine-arm64/lib.sh`
  - `wine-arm64/build.sh`
  - `wine-arm64/export.sh`
  - `wine-arm64/patches/wine/0001-…0006-*.patch`
  - `wine-arm64/tests/mode_test.sh`
- Modify: `Makefile` (targets `wine-arm64`, `wine-arm64-export`; `.PHONY`)

**Interfaces:**
- Produces:
  - `build_mode <src-dir> <applied-file>` (lib.sh) prints `pinned` when `<src-dir>` doesn't exist. It prints `development` when the tree is dirty or HEAD ≠ the SHA in `<applied-file>`. Otherwise it prints `applied`.
  - `stamp_of <file>…` prints the SHA-256 of the files' contents in order, followed by `$MACNEUTRON_SIGN_IDENTITY`.
  - `die <msg>` prints `wine-arm64: <msg>` to stderr and exits 1.
  - `need_tool <cmd> <brew formula>`.
  - The Wine build tree is `build/wine-arm64-src/wine-build`; sources are in `build/wine-arm64-src/wine`, on branch `macneutron`.

- [ ] **Step 1: Write the failing test** `wine-arm64/tests/mode_test.sh`. It sources `lib.sh`, then builds a scratch repo in `$(mktemp -d)` with one commit, and asserts:
  ```sh
  [ "$(build_mode "$T/missing" "$T/a")" = pinned ]
  git -C "$T/r" rev-parse HEAD > "$T/a"; [ "$(build_mode "$T/r" "$T/a")" = applied ]
  echo x >> "$T/r/f";                    [ "$(build_mode "$T/r" "$T/a")" = development ]   # dirty
  git -C "$T/r" commit -qam e;           [ "$(build_mode "$T/r" "$T/a")" = development ]   # ahead of .applied
  [ "$(stamp_of "$T/r/f")" != "$(MACNEUTRON_SIGN_IDENTITY=other stamp_of "$T/r/f")" ]
  ```
  It prints `PASS mode_test` at the end.
- [ ] **Step 2: Run it and see it fail.** `sh wine-arm64/tests/mode_test.sh` should fail with `lib.sh: No such file or directory`.
- [ ] **Step 3: Write `wine-arm64/pins` and `wine-arm64/lib.sh`** (values from Global Constraints). `stamp_of` uses `shasum -a 256`.
- [ ] **Step 4: Run it again.** Expected: `PASS mode_test`.
- [ ] **Step 5: Import patches 1–6.**
  1. Copy `docs/research/2026-10-02-native-arm64/trial-patches/000[1-6]-*.patch` into `wine-arm64/patches/wine/`.
  2. In patch 3, replace the comment "else fall back to execv" with "an unentitled target is SIGKILLed; patch 7 checks first".
- [ ] **Step 6: Write `build.sh`.**
  - **Tools:**
    - `need_tool autoconf autoconf`, `bison bison`, `flex flex`, `cmake cmake`, `ninja ninja`;
    - bison and flex are keg-only: put `$(brew --prefix bison)/bin` and `$(brew --prefix flex)/bin` first on `PATH`;
    - the llvm-mingw `bin` from `sh dxmt/toolchain.sh` goes on `PATH` too.
  - **Mode** comes from `build_mode`.
    - `pinned`: `git clone --depth 1` at the pin, `git checkout -b macneutron`, `git am wine-arm64/patches/wine/*.patch`, then write `.applied`. A failing `git am` prints `die "patch <file> does not apply to <pin>"`.
    - `applied` with an unchanged stamp: print `wine-arm64: up to date` and exit 0.
    - `development`: print `wine-arm64: development build`.
  - **Configure** (once per build tree): `autoreconf` in the source, then out of tree, with Global Constraints' line and `MACOSX_DEPLOYMENT_TARGET=27.0`.
  - **Build:** `make -j"$(sysctl -n hw.ncpu)"`.
  - **Stamp:** `build/wine-arm64/version` gets `stamp_of` over `wine-arm64/pins`, the patch files, `build.sh`, `bundle.sh`, `lib.sh`, `wine.entitlements` and `Info.plist`, only after everything succeeds.
- [ ] **Step 7: Write `export.sh`.** It runs `git -C build/wine-arm64-src/wine format-patch --zero-commit -N -o wine-arm64/patches/wine <pin>..macneutron` into an emptied folder, then rewrites `.applied` to HEAD. FEX gets the same in Task 5.
- [ ] **Step 8: Add the Makefile targets.** `wine-arm64: ; sh wine-arm64/build.sh` and `wine-arm64-export: ; sh wine-arm64/export.sh`.
- [ ] **Step 9: Build.** Run `make wine-arm64`. Expected:
  - it ends without error;
  - `git -C build/wine-arm64-src/wine log --oneline 455e350..HEAD | wc -l` prints `6`;
  - `otool -l "build/wine-arm64-src/wine-build/dlls/ntdll/ntdll.so" | grep minos` prints `minos 27.0`.
- [ ] **Step 10: Check the stamp.** Run `make wine-arm64` again; it prints `wine-arm64: up to date`. Touch-edit a file under `build/wine-arm64-src/wine/dlls/ntdll/unix/`, run again: it prints `development build` and rebuilds. Then `git -C … checkout .`.
- [ ] **Step 11: Commit.** Message: "wine-arm64: pins, Wine 11.19 patches 1-6 and make wine-arm64". Run `make test` first.

### Task 2: `wine.app`, signing and `make wine-arm64-check` (boot, native ARM64)

**Files:**
- Create:
  - `wine-arm64/bundle.sh`
  - `wine-arm64/wine.entitlements`
  - `wine-arm64/Info.plist`
  - `wine-arm64/check.sh`
  - `wine-arm64/tests/profile_test.sh`
  - `wine-arm64/tests/fixtures/{good,wrong-app,no-entitlement,expired}.plist`
  - `wine-arm64/tests/arm64-hello.c`
- Modify:
  - `wine-arm64/lib.sh` (`check_profile_plist`)
  - `wine-arm64/build.sh` (install into the bundle tree, call `bundle.sh`)
  - `Makefile` (`wine-arm64-tests`, `wine-arm64-check`)

**Interfaces:**
- Consumes: Task 1's `lib.sh`, and the build tree.
- Produces:
  - `check_profile_plist <decoded-plist>` reads decision 6's three PlistBuddy paths and exits 0, or calls `die` with one of:
    - `profile is for <id>, not 49QMZXLR8S.net.authspot.macneutron.wine`
    - `profile lacks com.apple.developer.cross-architecture-support`
    - `profile expired on <date>`
  - The staged bundle `build/wine-arm64/wine.app` (layout in spec §4).
  - `check.sh`'s helpers, which later tasks use:
    - `step <name> <cap-seconds> <command…>`: prints `PASS <name>`, or `FAIL <name>: <last output line>` and then exits 1.
    - `wine_run <args…>`: runs the clone's `Contents/MacOS/wine` with `WINEPREFIX="$PFX"`.
    - `cleanup`.
  - Variables: `$WORK`, `$TOOL` (the clone's `.app`), `$PFX` (`$WORK/prefix arm64`), and `$TESTS` (`build/wine-arm64-tests`).

- [ ] **Step 1: Write the failing test** `profile_test.sh`. For each fixture it runs `check_profile_plist` in a subshell and asserts the exit code and message:
  - `good`: exit 0;
  - `wrong-app` (application-identifier `49QMZXLR8S.com.example.other`): message contains `profile is for 49QMZXLR8S.com.example.other`;
  - `no-entitlement`: message contains `lacks com.apple.developer.cross-architecture-support`;
  - `expired` (`ExpirationDate` 2020-01-01): message contains `expired`.

  The fixtures are plain XML plists with the real decoded profile's key layout (`Entitlements` dict holding `com.apple.application-identifier` and `com.apple.developer.cross-architecture-support`, top-level `ExpirationDate` as a `<date>`). Model `good.plist` on `security cms -D -i ~/Downloads/Mac_Neutron.provisionprofile`, trimmed to those keys; never commit the real profile.
- [ ] **Step 2: Run it and see it fail.** Expected: `check_profile_plist: not found`.
- [ ] **Step 3: Implement `check_profile_plist`** with `/usr/libexec/PlistBuddy`. The expiry check compares the date as `date -j -f`-parsed epoch seconds against `date +%s`.
- [ ] **Step 4: Run it again.** Expected: `PASS profile_test`.
- [ ] **Step 5: Write `arm64-hello.c`.** It prints `GetSystemInfo`'s `wProcessorArchitecture` and `dwPageSize`, and the `NtMajorVersion` read from `(const BYTE *)0x7ffe0000 + 0x26c`. It prints `PASS arm64-hello` when the architecture is 12 and the major version is 10.

  Add the Makefile target `wine-arm64-tests`, which builds every `wine-arm64/tests/*.c|*.cpp` per decision 3, in parallel like `dxmt-tests`.
- [ ] **Step 6: Write `check.sh`** with these steps, which fail now:
  - **`macos`:** `sw_vers -productVersion` must be ≥ 27.
  - **`signature`, on the clone:**
    - `codesign --verify --strict --deep`;
    - `codesign -d --entitlements - Contents/MacOS/wine` contains `cross-architecture-support`;
    - `realpath "$TOOL/Contents/Resources/lib/wine/aarch64-unix/wine"` is `$TOOL/Contents/MacOS/wine`.
  - **`boot`** (180 s): `WINEDLLOVERRIDES="mscoree,mshtml=" wine_run wineboot -i` exits 0.
  - **`arm64`** (60 s): `wine_run "$TESTS/arm64-hello.exe"` prints `PASS arm64-hello`.

  Also:
  - setup on every run (decision 1): `cleanup`, `rm -rf "$WORK"`, `cp -cR build/wine-arm64/wine.app "$TOOL"` when the staged bundle exists (the `signature` step fails with `no bundle at build/wine-arm64/wine.app` when it doesn't), a fresh `$PFX`;
  - an `EXIT`/`INT`/`TERM` trap runs `cleanup`, then the orphan assertion, which prints `PASS orphans` or `FAIL orphans: <pids>`;
  - `cleanup` runs `WINEPREFIX=… <runtime>/wineserver -k` for each prefix, then `kill -9 $(lsof -t <each runtime binary>)`.

  Add `wine-arm64-check: wine-arm64 wine-arm64-tests` to the Makefile.
- [ ] **Step 7: Run it and see it fail.** `make wine-arm64-check` stops at `FAIL signature` (no bundle yet), and prints `PASS orphans`.
- [ ] **Step 8: Write `wine.entitlements` and `Info.plist`, then `bundle.sh`.**
  1. Check the variables: `die "set MACNEUTRON_SIGN_IDENTITY"` or `"set MACNEUTRON_PROVISIONING_PROFILE"`. `build.sh` runs the same check (and the profile check) before fetching or building, so a missing variable costs seconds, not a full build (spec §5.4 step 1).
  2. Decode the profile with `security cms -D`. If that fails: `die "<path> is not a provisioning profile"`. Then `check_profile_plist`.
  3. Lay out the bundle:
     - `make install DESTDIR=<tmp>` with configure's default prefix, then move `<tmp>/usr/local/{bin,lib,share}` into `Contents/Resources` (configure's relative paths, such as `../lib/wine` from `bin`, then hold inside the bundle);
     - copy `wine-build/loader/wine` to `Contents/MacOS/wine`;
     - replace `Contents/Resources/bin/wine` (`make install`'s Mach-O launcher, which every `bin/` program symlink points at) with `ln -s ../../MacOS/wine`;
     - `ln -s ../Resources/lib/wine/aarch64-unix/ntdll.so Contents/MacOS/ntdll.so`;
     - replace `Contents/Resources/lib/wine/aarch64-unix/wine` with `ln -s ../../../../MacOS/wine`;
     - copy `Info.plist` and the profile (as `embedded.provisionprofile`).
  4. Sign every Mach-O except `MacOS/wine` (`codesign -f -s "$ID" --options runtime`).
  5. Sign the bundle with `--entitlements wine.entitlements`.
  6. Assert:
     - `codesign --verify --strict --deep`;
     - the loader shows the entitlement;
     - every Mach-O has `minos 27.0`;
     - the `wine` symlink resolves to `MacOS/wine`;
     - `Resources/bin/wineserver` and `Resources/share/wine/wine.inf` exist;
     - no other Mach-O named `wine` exists in the bundle.

     Each failure is a `die` naming the check.

  The bundle is assembled as `build/wine-arm64/wine.app.tmp` and moved to `wine.app` only after every assertion passes, so a failure stages nothing (spec §9). `build.sh` then calls `bundle.sh` after `make`.
- [ ] **Step 9: Run the check.** Run `make wine-arm64-check` with the two variables set. Expected: `PASS macos`, `PASS signature`, `PASS orphans`. Then run `sh wine-arm64/check.sh boot arm64` and record its result in the report: until patch 8 (Task 3) the installed layout's first process runs with 16K pages, which is untested (spec §3.3), so `boot` and `arm64` are required to pass only from Task 3 on.
- [ ] **Step 10: Run the failure path.** Run `MACNEUTRON_PROVISIONING_PROFILE=/etc/hosts sh wine-arm64/bundle.sh`. Expected: `wine-arm64: /etc/hosts is not a provisioning profile`, exit 1.
- [ ] **Step 11: Commit.** Message: "wine-arm64: entitled wine.app, signing and make wine-arm64-check". Run `make test` first.

### Task 3: Every process entitled and 4K in the installed layout (patches 7–8)

**Files:**
- Create:
  - `wine-arm64/patches/wine/*-ntdll-Refuse-to-exec-a-loader-without-the-cross-architecture-entitlement.patch` (spec patch 7)
  - `wine-arm64/patches/wine/*-ntdll-Re-exec-the-first-process-with-4K-pages-in-an-installed-layout.patch` (spec patch 8)
- Modify: `wine-arm64/check.sh` (steps `pages` and `unentitled`, inserted after `boot`)

**Interfaces:**
- Consumes: `step`, `wine_run`, `$TOOL`, `$PFX`.
- Produces, in `dlls/ntdll/unix/loader.c`:
  - `static BOOL loader_is_entitled( const char *path )`: true when the file at `path` is signed with `com.apple.developer.cross-architecture-support`. Computed once, with `SecStaticCodeCreateWithPath` → `SecCodeCopySigningInformation(kSecCSSigningInformation)` → `kSecCodeInfoEntitlementsDict`, then cached.
  - Exact fatal text: `wine: %s lacks the com.apple.developer.cross-architecture-support entitlement; re-sign the runtime (wine-arm64/bundle.sh)\n`.

- [ ] **Step 1: Write the failing steps.**
  - **`pages`** (120 s): rerun `wineboot -u` and `arm64-hello` with `WINEDEBUG=+virtual`. Every `host page size:` line must say `4k`, with at least one line per `wine_run`. With patch 8, the first process re-execs before `virtual_init`, so a 16K first process never traces.
  - **`unentitled`** (30 s):
    1. Clone `$TOOL` to `$WORK/unentitled.app`.
    2. Run `codesign -f -s - $WORK/unentitled.app/Contents/MacOS/wine`, which drops the entitlements.
    3. Run `wine wineboot` from it.
    4. Expect a non-zero exit within the cap, and stderr containing `lacks the com.apple.developer.cross-architecture-support entitlement`.
- [ ] **Step 2: Run them and see them fail.** Run `sh wine-arm64/check.sh pages`, then `sh wine-arm64/check.sh unentitled`. Expected:
  - `FAIL pages`: the first process traces `16k`;
  - `FAIL unentitled`: the process dies with no message, or hangs until the cap.
- [ ] **Step 3: Implement patch 7** in the development tree (`build/wine-arm64-src/wine`, branch `macneutron`).
  - Add `$(SECURITY_LIBS)` to `UNIX_LIBS` in `dlls/ntdll/Makefile.in:8`.
  - `preloader_exec` calls `loader_is_entitled( argv[1] )` before setting the 4K attribute, and calls `fatal_error` with the exact text when it returns false.
  - `loader_is_entitled( wineloader )` is computed once in `init_paths`, right after `wineloader` is built, and cached in a static. So every later exec, including the double-forked grandchild in `exec_wineloader`, reads the cached answer.
  - A non-zero `posix_spawn` return is logged with `ERR( "posix_spawn %s: %s\n", argv[1], strerror( ret ) )`, followed by `fatal_error`.
- [ ] **Step 4: Implement patch 8.** In `pre_exec`'s installed-layout branch (`dlls/ntdll/unix/loader.c:1979`), return 1 (re-exec) when `getpagesize() != 0x1000`. The re-exec goes through patch 7's checked `preloader_exec`.
- [ ] **Step 5: Run them again.** Run `make wine-arm64 && sh wine-arm64/check.sh boot pages unentitled arm64`. Expected: `PASS boot`, `PASS pages`, `PASS unentitled`, `PASS arm64`.
- [ ] **Step 6: Export and commit.** Run `make wine-arm64-export`, then the full `make wine-arm64-check` (all PASS). Commit with message "wine-arm64: every Windows process runs entitled with 4K pages (patches 7-8)".

### Task 4: Bitmap bounds and CPU ID registers (patches 9–10, gate G3)

**Files:**
- Create:
  - `wine-arm64/patches/wine/*-ntdll-Bound-ARM64EC-code-map-lookups-on-the-PE-side.patch` (spec patch 9)
  - `wine-arm64/patches/wine/*-ntdll-Report-the-arm64-CPU-ID-registers-on-macOS.patch` (spec patch 10)
  - `wine-arm64/tests/arm64ec-isec.c`
  - `wine-arm64/tools/cpuregs.py`
- Modify: `wine-arm64/check.sh` (steps `isec` and `g3-cpu`)

**Interfaces:**
- Produces: `cpuregs.py <exported .reg file>` prints one `feature name=0|1` line each for LSE, LRCPC, LRCPC2 and AFP, then `PASS g3-cpu` or `FAIL g3-cpu: <missing>`. Its decoding:
  - `CP 4030` bits 23:20 ≥ 2 → LSE
  - `CP 4031` bits 23:20 ≥ 1 → LRCPC; ≥ 2 → LRCPC2
  - `CP 4039` bits 47:44 ≥ 1 → AFP

  Values come from `wine reg export`: Wine's `reg query` prints nothing for REG_QWORD (`programs/reg/query.c` has no case for it), but `reg export` writes a UTF-16LE file with a BOM in which each value reads `"CP 4030"=hex(b):xx,xx,…` (8 bytes, little-endian).

- [ ] **Step 1: Write the failing tests.**
  - **`cpuregs.py --self-test`** asserts:
    ```python
    decode({'CP 4030': 0x0021100110212120, 'CP 4031': 0x0000000000200000, 'CP 4039': 0x0000100000000000}) \
        == {'LSE': 1, 'LRCPC': 1, 'LRCPC2': 1, 'AFP': 1}
    decode({}) == {'LSE': 0, 'LRCPC': 0, 'LRCPC2': 0, 'AFP': 0}
    parse('"CP 4039"=hex(b):00,00,00,00,00,10,00,00\r\n') == {'CP 4039': 0x0000100000000000}
    ```
    (`parse` takes the decoded text; `main` reads the file as UTF-16.)
  - **`arm64ec-isec.c`:** resolves `RtlIsEcCode` with `GetProcAddress(GetModuleHandleA("ntdll"), "RtlIsEcCode")`. It asserts:
    - `0xffff800000001000` and `0x800000000000` give `FALSE` without faulting (wrapped in `__try`);
    - its own `main` gives `TRUE`.
  - **Check steps:**
    - `isec` (60 s) runs it;
    - `g3-cpu` (60 s) runs `wine_run reg export 'HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0' "Z:$WORK/cpu.reg" /y`, then `python3 wine-arm64/tools/cpuregs.py "$WORK/cpu.reg"`.
- [ ] **Step 2: Run them and see them fail.**
  - `python3 wine-arm64/tools/cpuregs.py --self-test` fails until `decode` exists. Write `decode` now, then the self-test passes.
  - `sh wine-arm64/check.sh isec` gives `FAIL isec` (an access violation inside `RtlIsEcCode`), and `sh wine-arm64/check.sh g3-cpu` gives `FAIL g3-cpu: LSE LRCPC LRCPC2 AFP missing`.
- [ ] **Step 3: Implement patch 9** in `dlls/ntdll/signal_arm64ec.c`:
  - `RtlIsEcCode`: `if (!map || ptr >= 0x800000000000) return FALSE;` (from Madeira `ac650deca3`; its message names that commit).
  - `arm64x_check_call`: before the bitmap load, `lsr x16, x11, #47` then `cbnz x16, .Lexit`, placed before `ldr x16, [x18, #0x60]` (adapted from Madeira `d88d55eee0`, which shifts by 39). Branch to `.Lexit` only: the fall-through and `.Ljmp` paths still load from `[x11]` and would fault on the bad target.
- [ ] **Step 4: Implement patch 10.** Add `static DWORD get_core_id_regs_arm64( struct smbios_wine_id_reg_value_arm64 *regs, … )` for `__APPLE__`, replacing the stub at `dlls/ntdll/unix/system.c:2106`.
  - **Fields** come from `sysctlbyname("hw.optional.arm.FEAT_<X>")`, at Arm's ID-register positions, for: LSE, LSE2, LRCPC, LRCPC2, AFP, FlagM, FlagM2, SHA1, SHA256, SHA512, SHA3, AES, PMULL, CRC32, DotProd, FHM, FRINTTS, RPRES, ECV, BF16, I8MM. A sysctl that is missing reads as 0.
  - **Registers written:** `CP 4030`, `4031`, `4032`, `4020`, `4021`, `4038`, `4039`, `403A`, `4024` = 0, and `4000` = `0x61 << 24` (Apple, part 0).
  - **Never `CP 5801`, and no `mrs ctr_el0`:** reading CTR_EL0 is a SIGILL on macOS.
- [ ] **Step 5: Run them again.** Run `make wine-arm64`, then `sh wine-arm64/check.sh boot isec g3-cpu`. Expected: `PASS isec`, `feature LSE=1`, `LRCPC=1`, `LRCPC2=1`, `AFP=1`, `PASS g3-cpu`.
- [ ] **Step 6: Export and commit.** Run `make wine-arm64-export` and the full check, then commit with message "wine-arm64: bounded EC code map lookups and CPU ID registers for FEX (patches 9-10, G3)".

### Task 5: FEX built, registered, and the x64 hello (week-1 checkpoint)

**Files:**
- Modify:
  - `wine-arm64/pins` (add `FEX_MACOS_REPO`, `FEX_MACOS_COMMIT`, decision 10)
  - `wine-arm64/build.sh` (FEX)
  - `wine-arm64/bundle.sh` (install FEX into the bundle)
  - `wine-arm64/export.sh` (FEX)
  - `wine-arm64/check.sh` (steps `fex` and `g1-hello`)
- Create:
  - `wine-arm64/patches/fex/*-Windows-UnixLib-implement-the-unix-helpers-for-macOS.patch` (dappermint `4efc3abc8a`, fetched from the pinned `FEX_MACOS_REPO`)
  - `*-Windows-UnixLib-don-t-link-rt-on-Apple.patch`
  - two Madeira-derived patches (the spec's patch 3), from `build/arm64/madeira/fex`: `fdf361f0e` (applies cleanly), and a **port** of only the 128-bit CASPAL and call-return-stack guard parts of `ceabf254a`, which rejects 7 hunks at the pin and also carries unrelated CPU-area/dispatcher probes. Both keep Madeira's author and name the source commit (MIT under Madeira's pre-2026-08-28 grant; amended 2026-10-03)
  - `wine-arm64/tests/x64-hello.c`

**Interfaces:**
- Produces:
  - `build/wine-arm64-src/fex` on branch `macneutron`, with `fex.applied`;
  - build trees `build/wine-arm64-src/fex-ec` (ARM64EC DLL) and `fex-unixlib`;
  - in the bundle: `Contents/Resources/lib/wine/aarch64-windows/libarm64ecfex.dll` and `…/aarch64-unix/libarm64ecfex.so`.

- [ ] **Step 1: Write the failing test.** `x64-hello.c` calls `IsWow64Process2(GetCurrentProcess(), &p, &n)`, prints `native machine 0x%04x`, and prints `PASS x64-hello` when `n == 0xAA64`. Check steps:
  - `fex` (60 s): `wine_run reg add 'HKLM\Software\Microsoft\Wow64\amd64' /ve /d libarm64ecfex.dll /f`, then `wine_run reg query` of that key shows `libarm64ecfex.dll`;
  - `g1-hello` (60 s): `WINEDEBUG=+seh,+loaddll wine_run "$TESTS/x64-hello.exe"`.
- [ ] **Step 2: Run them and see them fail.** Running `sh wine-arm64/check.sh boot fex g1-hello` gives `FAIL g1-hello`: Wine's stub `xtajit64.dll` terminates the process at the first x64 entry, or FEX isn't installed.
- [ ] **Step 3: Build FEX in `build.sh`.**
  - **Clone** (FEX `main` has moved past the pin, so a depth-1 clone can't reach it): `git init`, `git fetch --depth 1 origin <FEX_COMMIT>`, `git checkout -b macneutron FETCH_HEAD`, `git submodule update --init --recursive --depth 1`, then `git am` the `patches/fex` series. Same modes as Wine (decision 4), with `fex.applied` and `fex.series`.
  - **The DLL:** `cmake -S fex -B fex-ec -G Ninja -DCMAKE_TOOLCHAIN_FILE="<absolute path to the FEX tree>/Data/CMake/toolchain_mingw.cmake" -DMINGW_TRIPLE=arm64ec-w64-mingw32 -DCMAKE_BUILD_TYPE=Release -DTUNE_CPU=none -DENABLE_LTO=False -DBUILD_TESTING=False -DBUILD_FEXCONFIG=False -DENABLE_JEMALLOC_GLIBC_ALLOC=False -DENABLE_CCACHE=False`, then `ninja -C fex-ec arm64ecfex`.
  - **The unixlib:** `cmake -S fex/Source/Windows/UnixLib -B fex-unixlib -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=/usr/bin/clang++ -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0`, then `ninja -C fex-unixlib`.
  - **Assert** that `llvm-objdump -p libarm64ecfex.dll`:
    - lists only `ntdll.dll` under `DLL Name`;
    - shows no TLS directory (`llvm-readobj --coff-tls-directory`);
    - carries Wine's builtin marker (`grep -c 'Wine builtin DLL'` on the DLL is 1). Wine ignores non-builtin DLLs in its own directories.

  `bundle.sh` copies the DLL and the `.so` in before signing. Add FEX to `export.sh`'s `format-patch` (absolute `-o`), and the `patches/fex` files to the stamp. Any new tool goes through `need_tool` followed by `die_if_missing`.
- [ ] **Step 4: Run the test.** Run `make wine-arm64 && sh wine-arm64/check.sh boot fex g1-hello`.
  - **On `PASS g1-hello`:** go to Step 6.
  - **On failure:** Step 5.
- [ ] **Step 5: Diagnose (spec §8, week-1 checkpoint).** Gather:
  - `WINEDEBUG=+seh,+virtual,+loaddll,+module` with `FEX_SILENTLOG=0`;
  - for each fault: the ESR's exception class (0x20/0x21 instruction abort, 0x24/0x25 data abort, 0x22 PC alignment);
  - whether the PC is in `libarm64ecfex.dll`, in a FEX code buffer, or in the x64 image;
  - `RtlIsEcCode(PC)`;
  - the 4K page protections around the fault address.

  Each fix becomes the next Wine or FEX patch in the development tree, with the observed failure in its message. Madeira's commits are the map: `willfaust/wine` branch `madeira-lgpl` (LGPL; local clone `build/arm64/madeira/wine`), and `willfaust/FEX` branch `ios-port-2607` (MIT with attribution for commits dated before 2026-08-28, GPL-3 after; amended 2026-10-03; local clone `build/arm64/madeira/fex`). Repeat Step 4.

  If the week-1 checkpoint arrives without a running hello, write the understood cause into `docs/testing/acceptance-arm64-wine.md` under "Week-1 checkpoint", and tell the maintainer.
- [ ] **Step 6: Export and commit.** Run `make wine-arm64-export` and the full check, then commit with message "wine-arm64: FEX for x64, registered; x64 hello runs (week-1 checkpoint)".

### Task 6: Gate G1 (exceptions, threads, KUSER, self-modifying code)

**Files:**
- Create:
  - `wine-arm64/tests/x64-seh.c`
  - `wine-arm64/tests/x64-seh-cpp.cpp`
  - `wine-arm64/tests/x64-threads.c`
  - `wine-arm64/tests/x64-kuser.c`
  - `wine-arm64/tests/x64-smc.c`
- Modify: `wine-arm64/check.sh` (steps `g1-seh`, `g1-threads`, `g1-kuser`, `g1-smc`, after `g1-hello`)

**Interfaces:**
- Consumes: Task 5's FEX in the bundle; `step`, `wine_run`.

- [ ] **Step 1: Write the tests.** Each prints its lines, then its `PASS`/`FAIL` line:
  - **`x64-seh`:** writing through `(int *)8` inside `__try` is caught by `__except` with `GetExceptionCode() == 0xC0000005`. A vectored handler added with `AddVectoredExceptionHandler` sees exactly one exception for a second access violation.
  - **`x64-seh-cpp`:** `try { throw 42; } catch (int v) { … }` gets `v == 42`.
  - **`x64-threads`:**
    - 32 threads each `TlsSetValue(i)` and read it back;
    - 32 × 100000 increments of a shared counter under one `CRITICAL_SECTION` end at `3200000`;
    - a manual-reset event releases all threads at once.
  - **`x64-kuser`:**
    - `*(volatile ULONG *)0x7ffe026c` (NtMajorVersion) is 10;
    - `*(volatile ULONG *)0x7ffe0320` (TickCount low part) is within 50 ms of `(ULONG)GetTickCount64()`. Read both twice, and accept a pass on either pair, because the server updates TickCount asynchronously.
  - **`x64-smc`:**
    1. `VirtualAlloc` RWX.
    2. Copy in `mov eax,1; ret` (`B8 01 00 00 00 C3`), call it, expect 1.
    3. Overwrite byte 1 with `02`, call it, expect 2.
- [ ] **Step 2: Add the four check steps** (60 s each; `g1-seh` runs both `x64-seh.exe` and `x64-seh-cpp.exe`) and build the tests: `make wine-arm64-tests`.
- [ ] **Step 3: Run them.** Run `sh wine-arm64/check.sh boot fex g1-seh g1-threads g1-kuser g1-smc`. Expected: `PASS` for all four. A failure is diagnosed as in Task 5, Step 5, and fixed with a new Wine or FEX patch.
- [ ] **Step 4: Export and commit.** Run `make wine-arm64-export` and the full check, then commit with message "wine-arm64: gate G1 (x64 exceptions, threads, KUSER, self-modifying code under FEX)".

### Task 7: Gate G2 (memory ordering)

**Files:**
- Create: `wine-arm64/tests/x64-litmus.c`
- Modify: `wine-arm64/check.sh` (step `g2-litmus`)

**Interfaces:**
- Produces: `x64-litmus.exe <iterations>` prints, per pattern, `litmus <MP|LB|2+2W|IRIW> forbidden=<n> runs=<m>`.

- [ ] **Step 1: Write `x64-litmus.c`.** Use the patterns below, with `volatile int` plain scalar accesses only (no `lock`, no fences, no intrinsics). Threads are created once per pattern, not pinned, and synchronized per iteration on a spin flag.
  - **MP** is the spin-read shape of `docs/research/2026-10-02-native-arm64/probes/entitlement-probe.c:40-50`.
    - The writer stores `data = i`, then `flag = i`.
    - The reader spins reading `flag`, then `data`, until it sees `flag == i` or the writer is done.
    - Forbidden outcome: `flag == i && data != i`.
  - **LB:** `r1 = x; y = 1` ‖ `r2 = y; x = 1`. Forbidden: `r1 == 1 && r2 == 1`.
  - **2+2W:** `x = 1; y = 2` ‖ `y = 1; x = 2`. Forbidden: final `x == 1 && y == 1`.
  - **IRIW:** two writers, `x = 1` and `y = 1`, and two readers:
    - reader 1: `r1 = x; r2 = y`;
    - reader 2: `r3 = y; r4 = x`.

    Forbidden: `r1 == 1 && r2 == 0 && r3 == 1 && r4 == 0`.

  `main` takes the iteration count from `argv[1]`.
- [ ] **Step 2: Write the check step** `g2-litmus` (1800 s):
  - **Default run:** `wine_run x64-litmus.exe 10000000`, with no `FEX_*` variables in the environment (`env -u` each one in case the caller set it). Every pattern must report `forbidden=0`.
  - **Control run:** `FEX_TSOENABLED=0 wine_run x64-litmus.exe 10000000`. MP must report `forbidden≥1`. LB, 2+2W and IRIW are printed as `info` lines and not gated.
  - Prints `PASS g2-litmus` or `FAIL g2-litmus: <pattern> forbidden=<n>` (default run), or `FAIL g2-litmus: control saw no MP violation` (control run).
- [ ] **Step 3: Run it.** Run `sh wine-arm64/check.sh boot fex g2-litmus`. Expected: `PASS g2-litmus`.

  A default-run violation is a real bug and blocks sub-project 1 (spec §8). Diagnose it with `FEX_SILENTLOG=0`, and report it to FEX if it reproduces on upstream FEX.

  A control run with no violation means the test can't detect reordering. Fix the test (more iterations, a longer spin window), not the gate.
- [ ] **Step 4: Commit.** Message: "wine-arm64: gate G2 (x64 litmus under FEX TSO, with a TSO-off control)".

### Task 8: Wine side of the dual view (patches 11–12)

**Files:**
- Create:
  - `wine-arm64/patches/wine/*-ntdll-Honour-MEM_EXTENDED_PARAMETER_EC_CODE-when-mapping-a-section-view.patch` (spec patch 11)
  - `wine-arm64/patches/wine/*-ntdll-Trace-W-X-page-flips-on-macOS.patch` (spec patch 12)
  - `wine-arm64/tests/arm64ec-viewec.c`
  - `wine-arm64/tests/arm64-wxflip.c`
- Modify: `wine-arm64/check.sh` (steps `viewec` and `wxflip`)

**Interfaces:**
- Produces:
  - **Patch 11:** `NtMapViewOfSectionEx` passes the parsed attribute flags into `virtual_map_section`. When `MEM_EXTENDED_PARAMETER_EC_CODE` is set and the mapping succeeds, it calls `commit_arm64ec_map( view )` and `set_arm64ec_range( base, size )`, as `allocate_virtual_memory` does at `dlls/ntdll/unix/virtual.c:5260-5263`.
  - **Patch 12:** the debug channel `wxflip`. Each flip prints exactly `trace:wxflip:virtual_handle_fault <page> -> rx` or `-> rw`, in both of patch 6's branches.

- [ ] **Step 1: Write the failing tests.**
  - **`arm64ec-viewec.c`:**
    1. `CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_EXECUTE_READWRITE, 0, 0x10000, NULL)`.
    2. Map the RW view with `MapViewOfFile3(…, PAGE_READWRITE, NULL, 0)`.
    3. Map the RX view with `MapViewOfFile3(…, PAGE_EXECUTE_READ, &p, 1)`, where `p.Type = MemExtendedParameterAttributeFlags` and `p.ULong64 = MEM_EXTENDED_PARAMETER_EC_CODE` (0x40, from the headers; `MapViewOfFile3` needs `-lonecore`, decision 3).
    4. Assert `RtlIsEcCode(rx) == TRUE` and `RtlIsEcCode(rw) == FALSE`.
    5. Write `mov w0,#7; ret` (`0x528000e0, 0xd65f03c0`) through RW, `FlushInstructionCache` on RX, call RX, and expect 7.
  - **`arm64-wxflip.c`:** rewrites and runs one `VirtualAlloc(PAGE_EXECUTE_READWRITE)` page 10 times, like `probes/dualmap.c`.
  - **Check steps:**
    - `viewec` (60 s) runs `arm64ec-viewec`;
    - `wxflip` (60 s) runs `WINEDEBUG=+wxflip arm64-wxflip.exe` and counts `trace:wxflip` lines, which must be ≥ 10. That proves the trace works.
- [ ] **Step 2: Run them and see them fail.** Running `sh wine-arm64/check.sh viewec` and `sh wine-arm64/check.sh wxflip` (separately) gives:
  - `FAIL viewec: RtlIsEcCode(rx) == FALSE`;
  - `FAIL wxflip: 0 trace lines`.
- [ ] **Step 3: Implement patches 11 and 12** in the development tree.
- [ ] **Step 4: Run them again.** Run `make wine-arm64 && sh wine-arm64/check.sh boot viewec wxflip`. Expected: both `PASS`.
- [ ] **Step 5: Export and commit.** Run `make wine-arm64-export` and the full check, then commit with message "wine-arm64: EC-marked section views and W^X flip tracing (patches 11-12)".

### Task 9: FEX's dual-view code memory (gate G5)

**Files:**
- Create: `wine-arm64/patches/fex/*-Windows-emit-JIT-code-through-a-writable-view-and-run-it-from-an-executable-view.patch` (spec FEX patch 4), built in `build/wine-arm64-src/fex`. Expected FEX files:
  - `Source/Windows/Common/Allocator.cpp` (the `HookPtrs` passed to `FEXCore::Allocator::SetupHooks`);
  - `Source/Windows/include/winternl.h` (declare `NtMapViewOfSectionEx`; `NtCreateSection` is already there);
  - a new `Source/Windows/Common/DualView.{h,cpp}`;
  - the code emitter buffer (`CodeEmitter/Buffer.h`);
  - the block linker and backpatching;
  - `CallRetStack`;
  - the register-spill patching;
  - `Arm64.cpp:2108-2160` (the SIGBUS unaligned-atomic backpatcher).
- Create: `wine-arm64/tests/x64-unaligned.c`
- Modify:
  - `wine-arm64/check.sh` (steps `g1-unaligned`, and `g5-jit` after it)
  - the G1 tests in `wine-arm64/tests/x64-*.c` and `x64-seh-cpp.cpp` (an `OutputDebugStringA("jit: start")` first line)

**Interfaces:**
- Consumes: Wine patch 11 (EC marking of views); patch 12's `wxflip` trace.
- Produces, in FEX:
  - **`FEX::Windows::DualView`:**
    - `void Init()`, called once in ARM64EC process init: creates the 1 GiB `SEC_COMMIT` section (`NtCreateSection(…, PAGE_EXECUTE_READWRITE, SEC_COMMIT)`). It maps the RW view, then the RX view (`NtMapViewOfSectionEx` with `MEM_EXTENDED_PARAMETER_EC_CODE`), and sets `WriteOffset = rw - rx`.
    - `void *AllocExec(size_t)` and `void FreeExec(void *, size_t)`: first-fit within the RX view; each returns RX addresses.
    - `uintptr_t WriteOffset`.
  - **The executable-allocation hook:** `AllocExec`/`FreeExec` join the existing `HookPtrs` that `Source/Windows/Common/Allocator.cpp` passes to `FEXCore::Allocator::SetupHooks`, gated on `ARCHITECTURE_arm64ec` (the WoW64 build has no dual view). `FEXCore/include/FEXCore/Utils/AllocatorHooks.h` (a public FEXCore header that can't include Windows code) only calls the hook for executable allocations, and its `VirtualFree(Ptr, Size)` routes to `FreeExec` when `Ptr` is inside the pool's RX range.
  - **Cache maintenance** goes through `NtFlushInstructionCache` on the RX address (spec §6.2).
  - **Every store into code** goes to `addr + DualView::WriteOffset`; every address and branch-target computation uses RX addresses.
  - **The guard page** at the end of each code buffer is set no-access in both views.

- [ ] **Step 1: Write the failing tests.**
  - **`x64-unaligned.c`:** `lock cmpxchg` on a 4-byte value that straddles a 16-byte boundary, through inline asm, 1000 times, with the expected final value. This reaches FEX's SIGBUS backpatcher, which rewrites code.
  - **`g1-unaligned`** (60 s) runs it.
  - **`g5-jit`** (600 s) runs every G1 test under `WINEDEBUG=+wxflip,warn+debugstr,warn+seh`. The x64 tests import kernel32's own `OutputDebugStringA`, which WARNs on `debugstr` (`dlls/kernel32/debugger.c`), printing `warn:debugstr:OutputDebugStringA "jit: start"`; kernelbase's logs on `seh`. Match the text `jit: start` on either channel. Task 10 switches the step to one full `x64-bench.exe` run (spec G5: "a full `x64-bench` run").
    - Each test calls `OutputDebugStringA("jit: start")` first; add that line to the G1 tests, the `.cpp` one included. (Removed again at the final review, 2026-10-03: once Task 10 moved the step to `x64-bench`, nothing read them.)
    - The step counts `trace:wxflip` lines after the first `jit: start` line in each log; the total must be 0, and a log with no marker is a FAIL (`FAIL g5-jit: no marker in <log>`).
- [ ] **Step 2: Run them and see `g5-jit` fail.** Run `sh wine-arm64/check.sh boot fex g1-unaligned g5-jit`. Expected: `PASS g1-unaligned` (FEX still uses RWX through patch 6) and `FAIL g5-jit: <n> flips`.
- [ ] **Step 3: Implement the dual-view FEX patch** in `build/wine-arm64-src/fex`.
  - Madeira's dual-mapped pool commits on `ios-port-2607` are the map: `fce78cefd`, `61f11e3cc`, `6084de076`, `83e12849f`, `87b40c220` and `db4f32768`. The patch message names them with attribution; MIT under Madeira's pre-2026-08-28 grant (amended 2026-10-03).
  - Replace Madeira's debugger-JIT pool source with `DualView::Init`.
  - Keep `IsAddressInCodeBuffer` and its users on RX addresses.
  - Leave `Module.cpp:629` (the x64 return-stub byte) and the guest-page SMC trap alone.
- [ ] **Step 4: Run them again.** Run `make wine-arm64 && sh wine-arm64/check.sh boot fex g1-hello g1-seh g1-threads g1-kuser g1-smc g1-unaligned g5-jit`. Expected: all `PASS`, and `g5-jit` with 0 flips. A G1 regression here is a dual-view bug: fix it in the dual-view patch.
- [ ] **Step 5: Export and commit.** Run `make wine-arm64-export` and the full check, then commit with message "wine-arm64: FEX emits through a writable view and runs from an executable view (G5)".

### Task 10: Gate G4 (speed against Rosetta)

**Files:**
- Create:
  - `wine-arm64/tests/x64-bench.cpp`
  - `wine-arm64/tools/bench_report.py`
- Modify: `wine-arm64/check.sh` (step `g4-bench`, last; and `g5-jit` switches to one full `x64-bench.exe` run)

**Interfaces:**
- Produces:
  - **`x64-bench.exe`:**
    - first prints `cpuid sse41=<0|1> avx=<0|1> avx2=<0|1> fma=<0|1>`;
    - calls `OutputDebugStringA("jit: start")`;
    - then prints one `row <name> <seconds>` per row.
  - **`bench_report.py <fex-dir> <rosetta-dir>`:** each directory holds `run1.txt`…`run5.txt`. It prints:
    - one table line per row: `<name> fex=<median s> rosetta=<median s> ratio=<fex/rosetta>`;
    - `geomean single-threaded=<x> multithreaded=<y> calls=<z>`;
    - `worst: <five row names with ratios>`;
    - the line `ratio > 1 means FEX is slower`.

- [ ] **Step 1: Write the failing test.** `bench_report.py --self-test` asserts:
  ```python
  median([3.0, 1.0, 2.0, 5.0, 4.0]) == 3.0
  geomean([2.0, 0.5]) == 1.0
  report({'a': [2.0]*5}, {'a': [1.0]*5})['a'] == 2.0
  ```
  Run `python3 wine-arm64/tools/bench_report.py --self-test`. Expected: it fails, then passes after writing `median`, `geomean` and `report`.
- [ ] **Step 2: Write `x64-bench.cpp`.** Each row runs a fixed amount of work, timed with `QueryPerformanceCounter`.
  - **The 29 single-threaded rows,** named exactly as in the gist the spec cites in §3.5 (names: `int_add_chain`, `int_mul_chain`, `int_div64`, `popcnt`, `bitops_mix`, `branch_predictable`, `branch_random`, `cmov_select`, `indirect_calls`, `direct_calls`, `sse_scalar_f32`, `sse_scalar_f64`, `sse_packed_ps`, `sse_int_paddd`, `sse_shuffle`, `cvttsd2si`, `sqrtps`, `divps`, `denormal_adds`, `sse41_dpps`, `avx2_packed_ps`, `fma256_ps`, `mem_seq_read`, `mem_seq_write`, `mem_random_chase`, `rep_movsb_64MB`, `memcpy_256B_hot`, `atomic_xadd`, `atomic_cmpxchg`). The AVX2/FMA rows are guarded by `cpuid` and print `skipped` when it's absent.
  - **Multithreaded rows, prefixed `mt_`:**
    - `mt_xadd_4` and `mt_xadd_8`: a contended `lock xadd` counter;
    - `mt_spsc_ring`: a 4096-entry single-producer/single-consumer ring of plain loads and stores, 50 million items;
    - `mt_memcpy_4`: four threads, 64 MB each.
  - **Call rows, prefixed `call_`:**
    - `call_chain64`: 64-deep `__attribute__((noinline))` direct calls;
    - `call_virtual`: C++ virtual calls through a base pointer;
    - `call_std_function`.

  Build it with `-O2` (override decision 3's `-O1` for this file in the Makefile rule).
- [ ] **Step 3: Write the check step** `g4-bench` (3600 s).
  - **Run** `x64-bench.exe` five times, as five separate processes, on each side.
  - **FEX side:** `wine_run`, saving to `$WORK/bench/fex/run<i>.txt`.
  - **Rosetta side:**
    1. Clone the installed tool folder (`$HOME/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron`, or `MACNEUTRON_TOOL`) with `cp -cR` into `$WORK/rosetta tool`.
    2. Require that its `runtime-version` is `runtime-v4.7.3`, or fail with that message.
    3. Copy `.build/release/macneutron` into its `bin/`.
    4. Run through `bin/macneutron launch waitforexitandrun`, with the same environment as `dxmt/check.sh`'s `run()`: `STEAM_COMPAT_DATA_PATH="$WORK/prefix rosetta"`, `SteamAppId=0`, `MACNEUTRON_NO_STEAM_BRIDGE=1`, `MACNEUTRON_NO_METALFX=1`.
    5. Save to `$WORK/bench/rosetta/run<i>.txt`.
  - **Report:** `python3 wine-arm64/tools/bench_report.py "$WORK/bench/fex" "$WORK/bench/rosetta"`, printed in full. The step prints `PASS g4-bench` whenever both sides produced all rows: G4 is measured, not gated.
  - **Cleanup** extends to the Rosetta clone: `wineserver -k` for `prefix rosetta`, and `lsof -t` on that clone's Wine binaries. The orphan assertion covers it.
  - Add `build` (the Swift CLI) to `wine-arm64-check`'s Makefile prerequisites.
- [ ] **Step 4: Run it.** Run `make wine-arm64-check`. Expected: every step `PASS`, ending with `g4-bench`'s report and `PASS orphans`.
- [ ] **Step 5: Commit.** Message: "wine-arm64: gate G4 (x64 benchmark under FEX vs Rosetta)".

### Task 11: README, acceptance, and the Rosetta stack unchanged

**Files:**
- Create:
  - `wine-arm64/README.md`
  - `docs/testing/acceptance-arm64-wine.md`
- Modify: `README.md` (the "Build and test" block)

- [ ] **Step 1: Write `wine-arm64/README.md`.** Cover:
  - what `make wine-arm64` builds (a link to the spec);
  - the requirements:
    - macOS 27;
    - Homebrew autoconf, bison, flex, cmake and ninja;
    - a Developer ID with the "Cross-architecture Compatibility Framework" capability granted for the App ID, and the two environment variables;
  - that anyone else needs their own App ID and grant;
  - the development loop (edit in `build/wine-arm64-src/<repo>`, `make wine-arm64`, `make wine-arm64-check <steps>`, `make wine-arm64-export`, commit);
  - licences: Wine LGPL-2.1+, FEX MIT, and our Madeira-derived FEX patches MIT too, under Madeira's pre-2026-08-28 grant (amended 2026-10-03), each naming its source commit.
- [ ] **Step 2: Add two lines to `README.md`'s "Build and test" block:**
  ```
  make wine-arm64        # native arm64 Wine + FEX in a signed wine.app (needs the Developer ID setup in wine-arm64/README.md)
  make wine-arm64-check  # its gates under real Wine
  ```
- [ ] **Step 3: Run the acceptance (spec §10)** on the maintainer's Mac:
  1. `rm -rf build/wine-arm64 build/wine-arm64-src && make wine-arm64`.
  2. `make wine-arm64-check 2>&1 | tee build/wine-arm64-acceptance.log` (outside `$WORK`, which every run deletes).
  3. `make test` and `make dxmt-check`.

  Record the following in `docs/testing/acceptance-arm64-wine.md`, with date, macOS build, Wine and FEX pins, and patch counts:
  - each step's result;
  - G2's counts for the default and control runs;
  - G3's feature lines;
  - G5's flip count;
  - G4's full table, the three geometric means and the worst five rows;
  - the week-1 checkpoint note, if Task 5 wrote one.
- [ ] **Step 4: Commit.** Message: "docs: native arm64 sub-project 1 acceptance".
