# Interface digest: wine.app build and bundle (sub-project 5)

Code at `69f0e4f` (main) plus the staged `build/wine-arm64/wine.app` and the applied tree `build/wine-arm64-src/dxmt`
(HEAD `f37f657` = DXMT_COMMIT `1fba8d2` + patch 0001). Read-only survey; no build run. All greps used `LC_ALL=C /usr/bin/grep`.

No Swift lives in this area. Its "tests" are shell scripts (`wine-arm64/tests/{mode,profile,licences}_test.sh`) plus
`presenter/tests/{present_loop.c,pixels.py}`. Swift tests that touch the presenter are listed in §9 so the launcher
digest can cross-reference them.

---

## 1. `wine-arm64/build.sh` (358 lines)

### Variables (lines 10-32)
`ROOT`, `B="${BUILD_DIR:-$ROOT/build}"`, `SRC="$B/wine-arm64-src"`, `OUT="$B/wine-arm64"`, `W="$SRC/wine"`, `F="$SRC/fex"`,
`D="$SRC/dxmt"`, `LSC="$SRC/lsteamclient"`, `DEPS="$SRC/deps"`, `PATCHES=wine-arm64/patches/wine`,
`FEX_PATCHES=…/fex`, `DXMT_PATCHES=…/dxmt`, `LSC_PATCHES=…/lsteamclient`. `FETCH_TAG=wine-arm64` (:15).
Sources: `wine-arm64/pins`, `dxmt/pins` (:12, comment "the Rosetta stack's pin, shared"), `wine-arm64/deps.pins`,
`wine-arm64/lib.sh`, `dxmt/fetch.sh`, `dxmt/llvm.sh`.
`PATH="$(sh "$ROOT/dxmt/toolchain.sh"):$PATH"` (:44). `export MACOSX_DEPLOYMENT_TARGET=27.0` (:46).

### Logical blocks
| Lines | Block |
|---|---|
| 34-46 | Step 1: tools (`need_tool`, `die_if_missing`), the Metal toolchain check, `check_signing`, PATH |
| 48-58 | `patch_tree <tmp-tree> <repo> <patch-dir> <series> <base>`: `git am` each patch, write `$SRC/<repo>.applied` and `.series`, `mv` into place |
| 59-67 | `fetch_wine` (shallow clone at `WINE_TAG`, checked against `WINE_COMMIT`) |
| 69-78 | `fetch_fex` (one-commit fetch, `submodule update --init --recursive --depth 1`) |
| 80-89 | `fetch_dxmt`: `rm -rf "$D.tmp" "$SRC/dxmt-build" "$SRC/dxmt-install"`; `git init`; `remote add origin "$DXMT_REPO"` (:84); fetch `--depth 1` of `DXMT_COMMIT`; `submodule update -q --init --depth 1` (:87, not recursive) |
| 92-104 | `fetch_lsteamclient` (blob-filtered sparse checkout, excludes `steamworks_sdk_*` and `gen_wrapper.py`) |
| 105-108 | series: `wine_series`/`fex_series` = `series_of wine-arm64/pins <patches>`; `dxmt_series = series_of dxmt/pins <dxmt patches>`; `lsc_series = lsteamclient_series deps.pins <patches>` |
| 109-115 | **stamp** (below) |
| 117-120 | `*_mode=$(build_mode <tree> <.applied> <.series> <series>)` for wine, fex, dxmt, lsteamclient |
| 122-134 | `prepare <repo> <mode>`: `reapply` deletes the tree; `reapply`/`pinned` remove `$OUT/version` and call `fetch_<repo>` |
| 138-140 | links `dlls/lsteamclient` into the Wine tree and adds it to `.git/info/exclude` |
| 143-145 | **MACNEUTRON_COMMIT and the `+dirty` pathspec** (below) |
| 147-162 | development or up-to-date decision (below) |
| 164-235 | Step 3: FreeType/gnutls/nettle/gmp from tarballs into `$DEPS` (hash in `deps/.complete`); `deps_post` at :190 is `strip -S "$f" && install_name_tool -id "@rpath/lib$l.dylib" "$f"` |
| 237-270 | Step 4: Wine configure (`--enable-archs=arm64ec,aarch64 --with-mingw=llvm-mingw …`), Homebrew-flag scan, SONAME check |
| 272-274 | Step 5: `make` |
| 276-301 | Step 6: FEX ARM64EC DLL + unixlib, import/TLS/builtin checks |
| 303-329 | Step 7: `build_llvm arm64`, DXMT `meson setup … --buildtype release --strip -Dwine_builtin_dll=false -Denable_d3d12=true` (:312-314, configured once per tree), compile, install into `dxmt-install`, write `dxmt-install/version` (`$DXMT_COMMIT+dev` or `printf '%s+%.12s'` commit+series, :321-325), `build_probe`/`build_translate` into `$OUT` (:327-329) |
| 331-350 | Step 8: write `$SRC/SOURCE` (below) |
| 351-352 | **`sh "$ROOT/wine-arm64/bundle.sh"`**: the only call site of bundle.sh (no args, no env beyond inherited `BUILD_DIR`) |
| 354-357 | Step 9: `echo "$stamp" > "$OUT/version"` unless `dev` |

### Stamp inputs, exact (lines 110-115)
```sh
stamp=$(stamp_of "$ROOT/wine-arm64/pins" "$PATCHES"/*.patch "$FEX_PATCHES"/*.patch "$ROOT/wine-arm64/build.sh" \
  "$ROOT/wine-arm64/lib.sh" "$ROOT/wine-arm64/bundle.sh" "$ROOT/wine-arm64/wine.entitlements" \
  "$ROOT/wine-arm64/Info.plist" "$ROOT/dxmt/pins" "$DXMT_PATCHES"/*.patch "$ROOT/dxmt/llvm.sh" \
  "$ROOT/dxmt/tools/dxil-probe.cpp" "$ROOT/dxmt/tools/dxil-translate.mm" "$ROOT/wine-arm64/licenses/NOTICES.md" \
  "$ROOT/wine-arm64/licenses/README" "$ROOT/wine-arm64/tests/licences_test.sh" "$ROOT/wine-arm64/deps.pins" \
  "$ROOT/dxmt/fetch.sh" "$ROOT/wine-arm64/x18-allow.txt" "$ROOT/wine-arm64/tools/x18scan.sh" "$LSC_PATCHES"/*.patch)
```
`stamp_of` (lib.sh:37-40) also hashes `$MACNEUTRON_SIGN_IDENTITY`. `dxmt/toolchain.sh` and `presenter/present.m` are
not inputs today.

### `+dirty` pathspec (lines 143-145)
```sh
mac=$(git -C "$ROOT" rev-parse HEAD)
[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal -- wine-arm64 dxmt bridge Makefile)" ] \
  || mac="$mac+dirty"
```

### Development / up-to-date exit (lines 147-162)
Any tree in `development` mode → `dev=1`, `rm -f "$OUT/version"`, message `wine-arm64: development build` (:149).
Otherwise:
```sh
if [ "$(cat "$OUT/version" 2> /dev/null)" = "$stamp" ] && [ -d "$OUT/wine.app" ] && { [ "${mac%+dirty}" != "$mac" ] \
  || ! LC_ALL=C /usr/bin/grep -q '^MACNEUTRON_COMMIT=.*+dirty$' "$OUT/wine.app/Contents/Resources/licenses/SOURCE"; }
then
  echo "wine-arm64: up to date" >&2
  exit 0
fi
```
(:156-161). The only machine-visible status is that stderr line and exit 0; there is no status-only mode.

### SOURCE keys build.sh writes (lines 334-350, to `$SRC/SOURCE` = `build/wine-arm64-src/SOURCE`)
In order: `MACNEUTRON_COMMIT` (:335), `WINE_COMMIT`, `WINE_SERIES`, `FEX_COMMIT`, `FEX_SERIES` (:336-339),
`FEX_SUBMODULE_<n>` for `fmt range-v3 rpmalloc unordered_dense xxhash cpp-optparse` (awk over `git -C "$F" submodule
status`, :341-342), `DXMT_COMMIT`, `DXMT_SERIES` (:343-344), `LLVM_TAG`, `LLVM_MINGW_SHA256` (:345-346),
`LSTEAMCLIENT_COMMIT`, `LSTEAMCLIENT_SERIES` (:347-348), then `deps_pins` (:349): `FREETYPE_URL FREETYPE_SHA256
GNUTLS_URL GNUTLS_SHA256 NETTLE_URL NETTLE_SHA256 GMP_URL GMP_SHA256` (matches the staged bundle's SOURCE).
`*_SERIES` is `dev` for a development tree (`series()` at :333). Note: `FEX_SUBMODULE_range-v3` and
`FEX_SUBMODULE_cpp-optparse` contain `-`, so SOURCE is not shell-sourceable; a release/R5 reader must parse with
`sed`/`awk`, not `.`.

**Where `DXMT_SUBMODULE_*` goes:** right after :344, mirroring :341-342:
```sh
  git -C "$D" submodule status | awk '{ c = $1; sub(/^[-+U]/, "", c); n = $2; sub(/.*\//, "", n)
    print "DXMT_SUBMODULE_" n "=" c }'
```
DXMT's submodules (`.gitmodules`; `git submodule status` in the applied tree): `external/nvapi` (d08488f…) and
`include/native/directx` (9df86f2…) → keys `DXMT_SUBMODULE_nvapi`, `DXMT_SUBMODULE_directx`. Add both to
`licences_test.sh:67-69`'s key list.

---

## 2. `wine-arm64/bundle.sh` (224 lines; takes no arguments today)

### Variables (lines 6-20)
`ROOT`; sources `lib.sh` and `dxmt/pins` (`DXMT_COMMIT`). `B="${BUILD_DIR:-$ROOT/build}"`, **`OUT="$B/wine-arm64"`** (:10),
`BUILD="$B/wine-arm64-src/wine-build"`, `FEX_DLL=…/fex-ec/Bin/libarm64ecfex.dll`, `FEX_SO=…/fex-unixlib/libarm64ecfex.so`,
`DXMT_IN=…/dxmt-install`, `DXMT_TREE=…/dxmt`, `DEPS=…/deps`, **`APP="$OUT/wine.app.tmp"`** (:17),
`R="$APP/Contents/Resources"`, `INSTALL="$OUT/install.tmp"`, `export MACOSX_DEPLOYMENT_TARGET=27.0`. Later: `U="$R/lib/wine/aarch64-unix"` (:62),
`L="$R/licenses"`, `S="$B/wine-arm64-src"` (:66-67), `DS="$S/deps-src"` (:86), `LOADER="$APP/Contents/MacOS/wine"` (:112),
`WD="$B/wine-arm64-src/wine/dlls"` (:149). Logs written to `$OUT/install.log`, `$OUT/sign.log`, `$OUT/macho.list`.

### Blocks
| Lines | Block |
|---|---|
| 22-29 | preconditions: `check_signing`; `$BUILD/loader/wine`, FEX DLL+SO, `$DXMT_IN`, `$DEPS/.complete`; `rm -rf "$APP" "$INSTALL"`; `trap` |
| 35-44 | layout: `make install DESTDIR="$INSTALL"`; move `bin lib share` under Resources (so no `include/`); loader copied to `MacOS/wine`; `bin/wine` and `lib/wine/aarch64-unix/wine` become symlinks to it; `MacOS/ntdll.so` → `Resources/lib/wine/aarch64-unix/ntdll.so` |
| 46-47 | FEX DLL into `aarch64-windows/`, SO into `aarch64-unix/` |
| 51-59 | `put <dir> <file> <dest>` (:51); `winemetal.dll` → aarch64-windows, `winemetal.so` → aarch64-unix; `d3d11 d3d10core dxgi d3d12 .dll` and `dxmt-replay.exe` → `DXMT/aarch64-windows/`; DXMT licence texts and `version` → `DXMT/` |
| 62-63 | `libfreetype.6.dylib`, `libgnutls.30.dylib` → `$U` |
| 66-106 | licences: `README`, `NOTICES.md`, `$S/SOURCE` → `licenses/`; wine, fex, llvm, llvm-mingw, freetype, gnutls, nettle, gmp, lsteamclient texts; heredoc `lsteamclient/NOTE` (:103-106) |
| 107 | `cp wine-arm64/Info.plist "$APP/Contents/Info.plist"` |
| 108 | `cp "$MACNEUTRON_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"` |
| 111 | `macho()`: `find "$APP" -type f -print0 \| xargs -0 file \| sed -n 's/: *Mach-O .*//p'` (symlinks excluded) |
| 114-119 | **signing** (below) |
| 121-219 | **assertions** (below) |
| 221-224 | stage: `rm -rf "$OUT/wine.app"; mv "$APP" "$OUT/wine.app"` |

### Signing block (lines 114-119)
```sh
macho | grep -vxF "$LOADER" | tr '\n' '\0' \
  | xargs -0 codesign -f -s "$MACNEUTRON_SIGN_IDENTITY" --options runtime > "$OUT/sign.log" 2>&1 || die …
codesign -f -s "$MACNEUTRON_SIGN_IDENTITY" --options runtime --entitlements "$ROOT/wine-arm64/wine.entitlements" "$APP" \
  >> "$OUT/sign.log" 2>&1 || die …
```
No explicit `--timestamp` (Developer ID signing timestamps by default; :133 asserts it). PE files aren't signed. Any
new Mach-O in the tree (the presenter) is signed by `macho()` automatically.

### Assertion blocks, with what each reads
| Lines | Check | Reads |
|---|---|---|
| 122 | `codesign --verify --strict --deep "$APP"` | the bundle |
| 123-124 | loader has `cross-architecture-support` | `codesign -d --entitlements - $LOADER` |
| 125-127 | loader lacks `get-task-allow` | same |
| 128 | `BUILD_DIR="$B" sh wine-arm64/tests/licences_test.sh "$APP"` | the bundle's licences + `$B/wine-arm64-src/fex-ec/External/*/` |
| 129-145 | per Mach-O in `$OUT/macho.list`: **minos** (:131-132, `otool -l` LC_BUILD_VERSION minos must equal `27.0`); secure timestamp (:133, `codesign -dvv` `^Timestamp=`); **deps** (:135-138: `skip=2`, or `skip=3` when `otool -D` prints an install name, i.e. a dylib/.so with an ID; remaining `otool -L` entries must match `^(/usr/lib/\|/System/\|@rpath/\|@loader_path/\|@executable_path/)`); **rpaths** (:141-144: every LC_RPATH path must start with `@`) | each Mach-O |
| 149-154 | `funcptrs <prefix> <source>…` (LOAD_FUNCPTR/MAKE_FUNCPTR names in Wine sources) | `$WD/*` |
| 155-166 | `lib_assert <dylib> <count> <symbols>`: install name `= @rpath/<name>` (`otool -D`); **no byte string `$B`** (`grep -a -c -F "$B"`); symbol count from Wine sources equals `<count>`; every symbol exported (`nm -gU`) | `$U/<dylib>` |
| 167 | `lib_assert libfreetype.6.dylib 46 …` (win32u/freetype.c, dwrite/freetype.c) | |
| 168-171 | `lib_assert libgnutls.30.dylib 70 …` (schannel_gnutls.c, crypt32/unixlib.c, plus `dlsym(libgnutls_handle,"gnutls_…")`) | |
| 175-183 | **x18 scan**: every arm64 Mach-O but `ntdll.so` through `tools/x18scan.sh -arch arm64`; hit counts per file+routine must equal `x18-allow.txt` (3 lines, all `libgnutls.30.dylib`) | otool -tV labels |
| 184 | `rm "$OUT/macho.list"` | |
| 185-190 | `lib/wine/aarch64-unix/wine` resolves to `MacOS/wine`; `MacOS/ntdll.so` resolves to the unix `ntdll.so`; `bin/wineserver` and `share/wine/wine.inf` exist | |
| 192-196 | `builtin()` = bytes 64-79 equal `Wine builtin DLL` (the DOS stub area): `winemetal.dll` has it; the 4 front ends and `dxmt-replay.exe` don't | |
| 197-200 | `DXMT/version` matches `$DXMT_COMMIT+?*`; `DXMT_COMMIT` is an ancestor of HEAD in `$DXMT_TREE` | |
| 204-215 | lsteamclient: both files exist; **CHPE**: `"$(sh dxmt/toolchain.sh)/llvm-readobj" --coff-load-config` shows `^CHPEMetadata [` (:206); `builtin` marker (:208); `lipo -archs lsteamclient.so = arm64`; exports `___wine_unix_call_funcs`; its `_Nt*`/`___wine_*` undefineds are exported by ntdll.so | |
| 216-217 | loader has `disable-library-validation` | |
| 218-219 | no other Mach-O named `wine` | |

Only `libfreetype.6.dylib` and `libgnutls.30.dylib` go through `lib_assert` (the "no build path in the two dylibs" of
spec §5.2). Every other dylib/.so gets only the generic :129-145 checks. `winemetal.so` names its build paths by design
(comment :146-147).

---

## 3. `wine-arm64/lib.sh` (83 lines; sourced by build.sh, bundle.sh, export.sh, tests)
- `die <msg>` (:2), prefix `wine-arm64: `.
- `need_tool <command> <brew formula> [keg]` (:6-15), `die_if_missing` (:16); global `missing`.
- `build_mode <src-dir> <applied-file> [<series-file> <series>]` → `pinned | applied | development | reapply` (:23-34).
  `development` if: dirty status, HEAD ≠ `.applied`, any stash, a second `refs/heads`, or a second worktree.
- `stamp_of <file>…` (:37-40): sha256 of contents + `$MACNEUTRON_SIGN_IDENTITY`; dies on a missing input.
- `series_of <file>…` (:43-45): `stamp_of` with the identity blanked.
- `lsteamclient_series <deps.pins> <patch>…` (:49-53).
- `APP_ID=49QMZXLR8S.net.authspot.macneutron.wine` (:56).
- `check_profile_plist <decoded-plist>` (:60-71): app id, `cross-architecture-support`, expiry (LC_ALL=C date).
- `check_signing` (:75-83): `MACNEUTRON_SIGN_IDENTITY`, `MACNEUTRON_PROVISIONING_PROFILE`, `security cms -D`.

## 4. `wine-arm64/export.sh` (36 lines)
Checks all four trees are on `macneutron` and clean (:13-18), then `export_tree <repo> <pinned commit> <series fn> <pins>`
(:19-32): `git format-patch -q --zero-commit -N -o "$SRC/export.tmp" "<pin>..macneutron"`, replaces
`wine-arm64/patches/<repo>/*.patch`, rewrites `<repo>.applied` and `<repo>.series`. Called for wine, fex, dxmt,
lsteamclient (:33-36): it re-exports **every** tree each time.

## 5. Pins, plist, entitlements
- `wine-arm64/pins`: `WINE_REPO`, `WINE_TAG=wine-11.19`, `WINE_COMMIT`, `FEX_REPO`, `FEX_COMMIT`, `FEX_MACOS_REPO`,
  `FEX_MACOS_COMMIT`.
- `wine-arm64/deps.pins`: `FREETYPE_URL/_SHA256`, `GNUTLS_*`, `NETTLE_*`, `GMP_*`, `LSTEAMCLIENT_REPO`, `LSTEAMCLIENT_COMMIT`.
- `dxmt/pins`: `DXMT_REPO` (chadouming/dxmt), `DXMT_COMMIT=1fba8d2…`, `LLVM_TAG=llvmorg-15.0.7`, `WINE_URL`/`WINE_SHA256`
  (3Shain Wine 8.16, used only by `dxmt/build.sh:31`), `DXC_URL`/`DXC_SHA256` (`dxmt/build.sh:32-42`, consumed by
  `dxmt/tests/shaders/compile.sh:8`), `LLVM_MINGW_URL`, `LLVM_MINGW_SHA256`. **The whole file is a DXMT series input**
  (`build.sh:107`).
- `wine-arm64/Info.plist` (:5-16): `CFBundleIdentifier=net.authspot.macneutron.wine`, `CFBundleExecutable=wine`,
  `CFBundleName=Wine`, `CFBundlePackageType=APPL`, `CFBundleInfoDictionaryVersion=6.0`, `LSMinimumSystemVersion=27.0`.
  **No `CFBundleShortVersionString` / `CFBundleVersion`.**
- `wine-arm64/wine.entitlements`: `application-identifier`, `team-identifier` (49QMZXLR8S),
  `cross-architecture-support`, `cs.allow-jit`, `cs.allow-unsigned-executable-memory`, `cs.disable-library-validation`.
  No `allow-dyld-environment-variables`.

## 6. `dxmt/toolchain.sh` and `dxmt/published.sh`
- `toolchain.sh` (17 lines): prints `build/dxmt-src/llvm-mingw/bin` (via `${BUILD_DIR:-$ROOT/build}/dxmt-src`), fetching
  `LLVM_MINGW_URL` once; completeness marker `bin/x86_64-w64-mingw32-clang`. That folder has `llvm-strip`,
  `llvm-objcopy` and `llvm-readobj` (checked), so `"$(sh dxmt/toolchain.sh)/llvm-strip" --strip-debug` works as §5.2 says.
  `build/dxmt-src/llvm-project` is cloned by `dxmt/llvm.sh:8-13` (`build_llvm`) itself if missing, so deleting
  `dxmt/build.sh` doesn't orphan it.
- `published.sh <fork clone> <commit>` (9 lines): `git -C clone fetch -q origin macneutron`, then
  `merge-base --is-ancestor <commit> FETCH_HEAD`; exit 1 with a `dxmt:` message. The comment at :4 says "`make app` runs it".
  Only call site: `Makefile:98` → `sh dxmt/published.sh build/dxmt-src/dxmt $$(cat build/dxmt/version)` (the Rosetta
  clone made by `dxmt/build.sh:46`, and the x86_64 build's version file).

## 7. Patch format (`wine-arm64/patches/dxmt/0001-d3d12-Read-the-ARM64-counter-on-arm64-builds.patch`)
`git format-patch --zero-commit -N` output: `From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001`,
`From: Chad Cormier Roussel <…>`, `Date:`, `Subject: [PATCH] d3d12: …` (DXMT-style `component: Sentence.` subject),
a body explaining the failure, a `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` trailer, the diff, and the
signature `-- \n2.54.0 (Apple Git-157)`. Made by committing on branch `macneutron` in `build/wine-arm64-src/dxmt`, then
`make wine-arm64-export`. 0002 will be named `0002-winemetal-…patch` by `-N`.

## 8. winemetal's unix side (`build/wine-arm64-src/dxmt/src/winemetal/`)
- **There is no unix initialisation today.** No `__attribute__((constructor))`, no init/process-attach function, in
  `unix/winemetal_unix.c` (3586 lines) or `unix/cache.c`. `__wine_unix_call_funcs[]` starts at
  `unix/winemetal_unix.c:3280`, and entry 0 is `_NSObject_retain`, not an init call.
- PE side: `main.c:5-11` `DllMain` on `DLL_PROCESS_ATTACH` → `DisableThreadLibraryCalls`, `return !__wine_init_unix_call();`.
  That ntdll call `dlopen`s `winemetal.so`, so a constructor in the .so runs exactly then, once per process that loads
  `winemetal.dll` (D3D processes only).
- `winemetal_unix.c` already has `#include <dlfcn.h>` at line 2 and uses `dlsym(RTLD_DEFAULT, …)` at :1713-1722, :1747-1750.
  It is compiled with `c_args: ['-ObjC']` and no ARC (`unix/meson.build:31`). Linked with `-install_name @rpath/winemetal.so`,
  `install_rpath: ''`, `build_rpath '@loader_path/:@loader_path/../../'` (`unix/meson.build:16-37`). `unix/install.sh`
  copies it and runs `strip -x` when meson's `--strip` is set (build.sh:312 passes `--strip`).
- **So patch 0002 has to add the initialisation itself.** Suggested: a `__attribute__((constructor)) static void
  load_presenter(void)` inserted in `unix/winemetal_unix.c` just before the `/* Definition from cache.c */` block
  (around :3271, before `__wine_unix_call_funcs` at :3280), or right after `execute_on_main` (:19-26):
  ```c
  const char *p = getenv("MACNEUTRON_PRESENT");
  if (p && !strcmp(p, "1") && !dlopen("@loader_path/libmacneutron-present.dylib", RTLD_NOW | RTLD_LOCAL))
    fprintf(stderr, "winemetal: can't load the MetalFX presenter: %s\n", dlerror());
  ```
  `dlopen`'s `@loader_path` resolves against the image that calls it (winemetal.so, in `lib/wine/aarch64-unix/`), which is
  what makes the spec's path work. dlopen from inside an initializer is supported by dyld.

## 9. Presenter (`presenter/present.m`, 297 lines)
- Header comment (:1) says "The launcher injects it … (DYLD_INSERT_LIBRARIES)"; update it.
- `__attribute__((constructor)) static void mnInit(void)` (:290-297): reads `MACNEUTRON_PRESENT_SCALE`, `MACNEUTRON_PRESENT_DUMP`,
  swizzles `-[CAMetalLayer nextDrawable]`. It doesn't read `MACNEUTRON_PRESENT`; the gate belongs in winemetal (§8).
- Log prefix `macneutron-present: ` (:40); `presenter/check.sh:37` counts `macneutron-present: MetalFX`.
- Today's build is `Makefile:41-43`: `clang -arch x86_64 -arch arm64 -fobjc-arc -O2 -dynamiclib -framework Foundation
  -framework AppKit -framework QuartzCore -framework Metal -framework MetalFX -o build/presenter/libmacneutron-present.dylib`.
  No min version, no install name.
- `presenter/check.sh` (81 lines) runs the installed tool folder with `MACNEUTRON_GRAPHICS=d3dmetal`,
  `DYLD_INSERT_LIBRARIES`, `MACNEUTRON_NO_METALFX=1` (:20-23): a full rewrite for L4 (outside this area's files).
- Swift cross-reference (launcher digest): `ToolLayout.presenterLibrary` / `presenterInstalled` (`ToolLayout.swift:45-47`),
  `Launcher.swift:157-167`, `RuntimeInstaller.swift:127-131`; tests `LauncherTests.swift`: `presenterIsInjectedByDefault`
  (:254), `presenterComesAfterTheUsersOwnLibraries` (:261), `optingOutLeavesThePresenterOut` (:270),
  `missingPresenterIsNoted` (:~278), `toolCommandsGetNoPresenter` (:288), `presenterAndSteamBridgeTravelTogether` (:295);
  `RuntimeInstallerTests.swift`: `installPutsThePresenterInTheToolFolder` (:~130); `Support.swift:124-126`
  `installFakePresenter`.

## 10. Licences
- `wine-arm64/licenses/README` (78 lines): component entries; lsteamclient entry :69-76, and :72-73 says "Whether a release
  bundle may include it is not decided yet (ship-base spec §1): this bundle is a local build." No MacNeutron entry.
- `NOTICES.md` (304 lines); its header (:5-6) lists the licence folders (add `macneutron/`).
- `tests/licences_test.sh` (99 lines). `check <wine.app> <build dir>` (:10-73): helper `miss`, `key <K>` (SOURCE line),
  `has <glob>` (in `aarch64-unix`). §1 verbatim files (:19-30); §2 NOTICES holders (:33-36); §3 FEX External drift
  (:39-43); §4 conditional libs: freetype (:47-51), gnutls (:52-57), tarball keys (:58-60), lsteamclient `LICENSE NOTE` +
  `LSTEAMCLIENT_COMMIT/SERIES` (:61-64); §5 SOURCE keys (:67-70). CLI: `licences_test.sh <wine.app>` or
  `--self-test <wine.app>` (:75-99; red cases: delete `fex/xxhash-LICENSE`, add `External/vixl`).
  Invoked by `bundle.sh:128`, `Makefile:151-152`.
- `mode_test.sh` (48 lines): `build_mode`, `series_of`, `stamp_of`, `need_tool`/`die_if_missing`. `profile_test.sh`
  (33 lines): `check_profile_plist` against `tests/fixtures/{good,wrong-app,no-entitlement,expired}.plist`, and
  `check_signing` messages. Invoked by `Makefile:149-150`. Neither needs changing unless new lib.sh functions are added.

## 11. Makefile (153 lines): relevant targets
| Lines | Target |
|---|---|
| 1 | `.PHONY` list (contains `dxmt`; add `release`) |
| 5-8 | `MINGW_BIN = $(shell sh dxmt/toolchain.sh)`, `MINGW` (x86_64), `MINGWXX`, `MINGW_A64` |
| 39-44 | `presenter`: the fat dylib (:41-43) + x64 `present_loop.exe` with `$(MINGW)` (:44) |
| 47-48 | `presenter-check: presenter` → `sh presenter/check.sh` |
| 52-53 | `dxmt: sh dxmt/build.sh` |
| 63-74 | `dxmt-tests-arm64ec` also builds `build/dxmt-tests-arm64ec/present_loop.exe` (:67, :73-74) |
| 77-78 | `dxil-corpus: dxmt` → `build/dxmt/dxil-translate` |
| 81-83 | `dxmt-check: build dxmt presenter dxmt-tests` |
| 86-104 | `app: build bridge presenter dxmt`: x64 `steam.exe` (:93), Frameworks presenter (:95-97), `published.sh` (:98), Rosetta DXMT (:99-103) |
| 109-110 | `wine-arm64: sh wine-arm64/build.sh` |
| 113-114 | `wine-arm64-export: sh wine-arm64/export.sh` |
| 144-153 | `wine-arm64-check: build bridge wine-arm64 wine-arm64-tests dxmt dxmt-tests presenter dxmt-tests-arm64ec`, then mode_test, profile_test, licences_test (+ self-test), `check.sh`; the comment at :144-147 describes the Rosetta baseline |

## 12. What of `Resources/bin` is used at run time (proved)
Staged `bin/`: `wineserver`, `wine` (→ loader), program links (`msidb msiexec notepad regedit regsvr32 wineboot winecfg
wineconsole winedbg winefile winemine winepath` → `wine`), and the developer tools `widl winebuild winedump winegcc
winemaker wmc wrc function_grep.pl` plus **`winecpp` → winegcc and `wineg++` → winegcc (symlinks)**.
- Wine's unix loader execs only `<bin_dir>/wineserver` (`dlls/ntdll/unix/loader.c:434` sets `bin_dir`; `:580`
  `exec_wineserver`; fallbacks `WINESERVER`, `PATH`, `BINDIR`). The loader re-execs `<ntdll.so dir>/wine` (`:436`,
  `lib/wine/aarch64-unix/wine`), not `bin/wine`.
- Grep of `dlls programs loader server libs` for `winegcc wineg++ winebuild winedump widl wrc wmc winemaker
  function_grep`: no exec or string use. The hits are comments (`krnl386.exe16/thunk.c:2081,2144`,
  `ntdll/unix/signal_i386.c:512`, `dbghelp/elf_module.c:706`, `shell32/shelllink.c:25-26`, `kernel32/resource.c:553`),
  `.idl`/tests, and `#include "wmcodecdsp.h"` (the `wmc` hits).
- Repo: only `Resources/bin/wineserver` is referenced (`bundle.sh:189`, `wine-arm64/check.sh:53-62,282,479`,
  `dxmt/check.sh:82,97`). DXMT's meson uses the *build tree's* `tools/winebuild` (`src/winemetal/meson.build:24`), never
  the bundle's.
- Conclusion: deleting the developer tools in release mode is safe. Also delete the `winecpp` and `wineg++` symlinks, or
  they dangle, and optionally `share/man/man1/{widl,winebuild,winecpp,winedump,wineg++,winegcc,winemaker,wmc,wrc}.1`.
- `.a` files: 249, all in `lib/wine/aarch64-windows/`. No `.def`/`.la`/`.pc` in the bundle. Staged size 1.3 GB
  (aarch64-windows 1.2 GB, aarch64-unix 37 MB).

---

## 13. Changes per spec section

### §5.1 Version and identity
- `bundle.sh`, after :107 (cp Info.plist) and before :114 (signing):
  `/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" -c "Add :CFBundleVersion string $build" "$APP/Contents/Info.plist"`,
  with `version=dev` by default and `$VERSION` in release mode. The stamp hashes the committed template (build.sh:111),
  so these additions don't change the stamp.
- Optional: print the identity at the end of bundle.sh (`codesign -dvvv "$OUT/wine.app" 2>&1 | sed -n 's/^CDHash=//p'`).
  Nothing prints it today.
- Add an assertion: `PlistBuddy -c 'Print :CFBundleShortVersionString'` equals the expected value.

### §5.2 Release mode
- `bundle.sh` gains argument parsing (it takes none today): `--release`, `--version <V>`, `--out <folder>`. `--out`
  replaces `OUT` (:10); `APP`, `INSTALL` and the logs follow it. Preconditions :22-26 still read `$B/wine-arm64-src`. In
  release mode, refuse unless `--version` and `--out` are given and `--out` ≠ `$B/wine-arm64`.
- **Placement: strip and delete go between :108 and :114** (after the layout, plist and profile; before signing), not
  just "before the assertions". Signing seals the files, and stripping after it would break the signatures.
  - PE: `"$(sh "$ROOT/dxmt/toolchain.sh")/llvm-strip" --strip-debug` on every PE in `$R/lib/wine/aarch64-windows/` and
    `$R/DXMT/aarch64-windows/` (pick by `file … | grep PE32` or by extension; skip `.a`, which are deleted anyway).
  - Mach-O: `strip -S` on `macho()`'s list restricted to `MacOS/`, `Resources/bin/`, `Resources/lib/` (that's every
    Mach-O). The loader is a regular file; the links are skipped by `find -type f`.
  - `find "$R/lib" -name '*.a' -delete`; `rm -f "$R/bin/"{winegcc,wineg++,winecpp,winebuild,winedump,widl,wrc,wmc,winemaker,function_grep.pl}`;
    optionally the matching man pages.
  - Record `du -sk "$APP"` before and after (release record).
- Evidence that `strip -S` keeps the x18 allow-list labels: `x18scan.sh` labels hits with `otool -tV` symbol labels
  (:17-24), and `libgnutls.30.dylib`, the only file in `x18-allow.txt`, is already `strip -S`'d (`build.sh:190`) and
  matches today.
- Not verified: that `llvm-strip` keeps the DOS stub (the builtin marker at bytes 64-79, checked at `bundle.sh:192-196,208`)
  and the ARM64X CHPE load config (`:206`). Those existing assertions are the canaries; R3 is what proves it.
- SOURCE in release mode: see the contradictions below. Also die if `$L/SOURCE` has `*_SERIES=dev` or `+dirty` (or
  leave that to release.sh, §6.3 step 2).

### §5.3 Presenter inside wine.app
- `build.sh`: a new block after :329 (end of step 7), before the SOURCE write at :333:
  ```sh
  mkdir -p "$SRC/presenter"
  /usr/bin/clang -arch arm64 -mmacosx-version-min=27.0 -fobjc-arc -O2 -dynamiclib \
    -install_name @rpath/libmacneutron-present.dylib -framework Foundation -framework AppKit -framework QuartzCore \
    -framework Metal -framework MetalFX -o "$SRC/presenter/libmacneutron-present.dylib" "$ROOT/presenter/present.m" \
    > "$SRC/presenter.log" 2>&1 || die "building the presenter failed; see $SRC/presenter.log"
  ```
  (`MACOSX_DEPLOYMENT_TARGET=27.0` from :46 would already give minos 27.0; the flag makes it explicit.)
- Stamp (:110-115): add `"$ROOT/presenter/present.m"` and `"$ROOT/LICENSE"` (bundle.sh copies it, §7.1). Pathspec
  (:144): `-- wine-arm64 dxmt bridge Makefile presenter LICENSE`.
- `bundle.sh`: precondition next to :23-26 (`[ -f "$B/wine-arm64-src/presenter/libmacneutron-present.dylib" ] || die …`);
  `put "$B/wine-arm64-src/presenter" libmacneutron-present.dylib "$U/"` near :62-63. Signing is automatic (`macho()`).
  The generic checks cover it: minos 27.0, timestamp, `/System` frameworks only, no rpaths, x18 (Apple clang never uses
  x18, so no new allow-list line). Optional assertion: `otool -D` = `@rpath/libmacneutron-present.dylib`.
- New DXMT patch 0002: the constructor from §8, in `src/winemetal/unix/winemetal_unix.c`. Commit it on `macneutron` in
  `build/wine-arm64-src/dxmt`, then `make wine-arm64-export`. Effect: `dxmt_series` changes → `reapply` → `fetch_dxmt`
  wipes `dxmt-build`/`dxmt-install` → a full DXMT rebuild, and `DXMT/version` gets a new series suffix (§3.8 replays once).
- Makefile `presenter` (:39-44): delete :41-43 (the dylib); keep present_loop.exe. The arm64ec copy already exists at
  `build/dxmt-tests-arm64ec/present_loop.exe` (:73-74); the x64 one at :44 runs under FEX, so either serves L4.
- `present.m:1` comment: "loaded by DXMT's winemetal.so (wine-arm64/patches/dxmt/0002)".

### §6.3 step 1 (refusals in this area)
- "`make wine-arm64` reporting all four trees applied and up to date": build.sh has no status-only mode. Its only
  signal is the stderr line `wine-arm64: up to date` plus exit 0 at :159-160, which needs **all** of: no development
  tree, stamp equal, `wine.app` present, SOURCE not stale-dirty. Either (a) release.sh runs `sh wine-arm64/build.sh` and
  requires that line (it builds if not current), or (b) add a `--status` flag that exits after :162 without building
  (exit 1 naming each tree's `*_mode` when not applied). (b) is testable in `mode_test.sh`.
- `dxmt/published.sh`: the clone argument must change. Use `build/wine-arm64-src/dxmt` (its `origin` is `DXMT_REPO`,
  build.sh:84) with `DXMT_COMMIT` from `dxmt/pins`. `fetch origin macneutron` adds `FETCH_HEAD` only, no `refs/heads`, so
  `build_mode` stays `applied` (lib.sh:25-27). The tree is shallow at `DXMT_COMMIT`, which is present, so `--is-ancestor`
  can be answered. Update its comment (:4) from "`make app` runs it" to "release.sh runs it".

### §6.3 step 2
- `bundle.sh --release --version <V> --out build/release/<V>/`, reading `build/wine-arm64-src/*` read-only (`make install`
  into its own `$OUT/install.tmp`).
- SOURCE checks: no `*_SERIES=dev`, no `+dirty`, `MACNEUTRON_COMMIT` = HEAD. See the staleness flag below.

### §7.1 Licences
- `wine-arm64/licenses/README`: rewrite the lsteamclient entry (:69-76; drop "not decided yet … local build" at :72-73)
  to "ships by the maintainer's decision of 2026-10-04 under Valve's Steamworks SDK licence (lsteamclient/)". Add the entry
  "MacNeutron (libmacneutron-present.dylib, the MetalFX presenter; the Wine, DXMT and FEX patch files): MIT,
  macneutron/LICENSE".
- `bundle.sh` (licences block :66-106): `mkdir -p "$L/macneutron"; put "$ROOT" LICENSE "$L/macneutron/"`.
- `licences_test.sh`: add `licenses/macneutron/LICENSE` to §1 (:19-29) (or under `if has libmacneutron-present.dylib`);
  in the lsteamclient block (:61-64), `g -qF "maintainer's decision of 2026-10-04" "$L/README"`; a MacNeutron README
  check (`g -qF 'macneutron/LICENSE' "$L/README"`); `DXMT_SUBMODULE_nvapi DXMT_SUBMODULE_directx` in §5 (:67-69).
  Self-test: add a red case (delete `licenses/macneutron/LICENSE`).
- App mode: a new CLI form (suggest `licences_test.sh --app <MacNeutron.app>`) that checks
  `Contents/Resources/licenses/{LICENSE, LICENSE.TXT, COPYING.MinGW-w64-runtime.txt, README}`, that the README names
  `Contents/Helpers/wine.app/Contents/Resources/licenses/`, then runs `check "<app>/Contents/Helpers/wine.app" "$B"`.
  Note: `check`'s §3 FEX-External drift reads `$B/wine-arm64-src/fex-ec/External`, so app mode needs the build tree too.
- `NOTICES.md:5-6`: add `macneutron/` to the folder list.

### §7.2 SOURCE keys
Covered above: `DXMT_SUBMODULE_*` after build.sh:344. No other new keys are needed for R5 (`LLVM_TAG`,
`LLVM_MINGW_SHA256` are already there).

### §7.3 `wine-arm64/README.md`
Lines that must change: :17-18 ("The shipped runtime is still the Rosetta one (`make dxmt`, the app)"); :55, :59-72
(`make … dxmt …`, "runtime-v4.7.3", "GPTK imported": now the frozen reference, `MACNEUTRON_REFERENCE`); :101-102 (the
D3DMetal reference on the installed runtime); :165-166 ("the Rosetta stack's pin; build/dxmt-src/dxmt, that stack's
clone"); :222-225 ("decided in sub-project 5; until then MacNeutron doesn't redistribute it", which release.sh's refusal
string matches); :240 ("our patches to it are too. 0001 is ours": add 0002). The root `README.md` has "Rosetta 2" at :6
and :10 and `import-gptk` at :52 and :56 (another digest's area).

### §8.2 Makefile
- :1 `.PHONY`: drop `dxmt`, add `release`.
- :52-53 `dxmt` deleted. :77-78 `dxil-corpus: wine-arm64` running `build/wine-arm64/dxil-translate`.
- :81 `dxmt-check: build wine-arm64 dxmt-tests dxmt-tests-arm64ec presenter`.
- :86-104 `app: build bridge wine-arm64`: delete :93 (x64 steam.exe → arm64 `$(BRIDGE)/arm64/steam.exe`) and :95-103;
  add `cp -c -R build/wine-arm64/wine.app $(APP)/Contents/Helpers/`; sign the outer app ad hoc without `--deep`.
- :148 `wine-arm64-check`: drop `dxmt`; rewrite the comment at :144-147.
- New `release: sh release/release.sh`.

---

## 14. Where the spec and the code don't line up

1. **SOURCE's `MACNEUTRON_COMMIT` goes stale with no rebuild path.** The up-to-date exit (`build.sh:156-157`) rebundles
   only when SOURCE's `MACNEUTRON_COMMIT` ends in `+dirty`. A commit that touches nothing in the `:144` pathspec (docs,
   `Sources/`, `App/`, all of this sub-project's launcher work) moves HEAD but not the stamp. `make wine-arm64` then
   says "up to date", SOURCE names an older commit, and §6.3 step 2's `MACNEUTRON_COMMIT == HEAD` refuses. Today the only
   way out is `rm build/wine-arm64/version`. Fix (pick one): extend the :156 condition to "SOURCE's `MACNEUTRON_COMMIT`
   ≠ `$mac`" (rebundles, about a minute of signing, after any commit), or have `bundle.sh --release` write
   `MACNEUTRON_COMMIT=$(git rev-parse HEAD)` into its own `$L/SOURCE` copy after checking the pathspec is clean (valid,
   since equal stamp inputs mean equal patches and pins). Also, the "+dirty" exit at :156 lets a dirty repo report "up
   to date". release.sh's own clean-tree check covers that.
2. **§5.2 places stripping "before signing" but says "then run every existing assertion"**. Code order: strip and delete
   must go between :108 and :114; the assertions at :121-219 then run unchanged. Fine, but the plan must say so.
3. **§5.2's tool list misses `winecpp` and `wineg++`**. Both are symlinks to `winegcc`; deleting only `winegcc` leaves
   them dangling inside a sealed bundle. (`wineg++` is on the spec's list, `winecpp` is not.) Delete both.
4. **§5.3 "winemetal.so's unix initialisation" does not exist**: no constructor or init entry (§8). Patch 0002 must add a
   constructor. "Nothing else in DXMT changes" still holds.
5. **`dxmt/published.sh`'s clone.** The spec keeps `published.sh` (§6.3 step 1), but its only caller passes
   `build/dxmt-src/dxmt`, the clone made by `dxmt/build.sh`, which §8.2 deletes. Retarget it to
   `build/wine-arm64-src/dxmt`.
6. **`dxmt/pins` is a DXMT series input as a whole file** (`build.sh:107`). If the plan trims `WINE_URL`/`WINE_SHA256`
   (only `dxmt/build.sh` uses them) or the "Rosetta stack" comments, the DXMT series changes, which forces a refetch and
   rebuild of DXMT and a new `DXMT/version`. Combine any such edit with patch 0002 so it costs one rebuild. `DXC_URL` is
   still needed by `dxmt/tests/shaders/compile.sh:8` (`build/dxmt-src/dxc`), which only `dxmt/build.sh:32-42` fetches:
   deleting `dxmt/build.sh` orphans that download. Move the DXC fetch into `compile.sh`, or note it.
7. **`export.sh` re-exports all four trees.** Each patch ends with the git version (`2.54.0 (Apple Git-157)`). If git
   has been updated since the last export, every series hash changes on the next `make wine-arm64-export`, causing a
   full Wine, FEX and lsteamclient rebuild for one DXMT patch. Check `git diff --stat wine-arm64/patches` after export and
   revert unrelated rewrites.
8. **`CFBundleVersion`'s value is unspecified** (§5.1 names only the short version: `$VERSION` or `dev`). Suggest
   `CFBundleVersion` = the same string. It only needs to be present.
9. **§6.3 step 1's "make wine-arm64 reporting …"** has no machine interface (§13 §6.3). Spec it as a `--status` flag or as
   a grep of the stderr line.
10. **§3.7 sets `MACNEUTRON_PRESENT=1` for every prefix process**, including the pre-cache replayer (`dxmt-replay.exe`
    loads winemetal → the presenter). Harmless (it passes frames through), but L1/L4 should know.
11. **`licences_test.sh` app mode needs `BUILD_DIR`'s FEX External folder** (`check` §3, :39-43). On a release machine
    that's fine; for a downloaded app (R4 in the fresh account) it isn't. Make the drift check optional in app mode, or
    run R4 on the build machine.
