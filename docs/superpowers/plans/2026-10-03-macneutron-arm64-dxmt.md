# Native arm64 Stack, Sub-project 2 (DXMT for arm64) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `make wine-arm64` also builds our DXMT fork for ARM64X into the signed `wine.app`; D3D11/D3D12 programs put pixels on screen from the arm64 runtime in both lanes (ARM64EC, x64 under FEX); and every check `dxmt/check.sh` makes of our DXMT passes there against the same D3DMetal reference.

**Architecture:**
- **A third tree.** `wine-arm64/build.sh` fetches DXMT at `dxmt/pins` `DXMT_COMMIT` into `build/wine-arm64-src/dxmt`, applies `wine-arm64/patches/dxmt/*.patch`, and builds it with meson against sub-project 1's Wine build tree and an arm64 LLVM 15. Modes, stamp and export work as for Wine and FEX.
- **One LLVM recipe.** `dxmt/llvm.sh` holds the LLVM build and the two LLVM-linked host tools, by architecture, for both `dxmt/build.sh` (x86_64) and `wine-arm64/build.sh` (arm64).
- **Checks reuse `dxmt/check.sh`.** An arm64 mode in its `run()` sends our DXMT's runs to the arm64 runtime; D3DMetal's runs stay on Rosetta as the reference. `wine-arm64/check.sh` gains `dxmt`, `dxmt-present` (pixels read off the screen by `winshot`), `dxmt-arm64ec` and `dxmt-x64`.

**Tech Stack:**
- POSIX sh
- meson + ninja (DXMT)
- CMake + Ninja (LLVM 15)
- Apple clang (`/usr/bin/clang`, `/usr/bin/clang++`)
- llvm-mingw 20260908 (`arm64ec-`, `x86_64-w64-mingw32-clang`)
- CoreGraphics and ImageIO (`winshot`)
- Python 3 (existing check helpers)

**Spec:** `docs/superpowers/specs/2026-10-03-macneutron-arm64-dxmt-design.md`. Evidence: `docs/research/2026-10-03-arm64-dxmt/` (brief, maps, the draft Wine patch 13).

## Global Constraints

- **Pins:** DXMT `https://github.com/chadouming/dxmt.git` at `1fba8d25b5e29ab49012d633676a6b0d4b3b96c5` (`dxmt/pins` `DXMT_REPO`, `DXMT_COMMIT`); LLVM `llvmorg-15.0.7` (`LLVM_TAG`). `dxmt/pins` is not edited: the Rosetta stack builds the same pin.
- **Wine and FEX:** sub-project 1's pins and patches 1–12; the new Wine patch is 13.
- **macOS 27:** `MACOSX_DEPLOYMENT_TARGET=27.0`; every Mach-O in the bundle has `minos 27.0` (bundle.sh already asserts this).
- **DXMT overrides, exactly:** `dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b`.
- **Meson options, exactly:** `--cross-file build-arm64ec.txt --buildtype release --strip -Dwine_builtin_dll=false -Denable_d3d12=true -Dnative_llvm_path=<llvm-arm64> -Dwine_build_path=<wine-build>`.
- **Bundle layout and `DXMT/version`:** as spec §6. Version token `<DXMT_COMMIT>+<first 12 characters of the series hash>`, or `<DXMT_COMMIT>+dev`.
- **Mac code** (host tools, `winemetal.so`'s native parts are meson's) is compiled with `/usr/bin/clang`/`/usr/bin/clang++`, never the bare `clang++` on `PATH` (llvm-mingw's comes first in `wine-arm64/build.sh`).
- **Patches:** every DXMT, Wine or FEX change is a commit in its `build/wine-arm64-src/<tree>` exported with `make wine-arm64-export`; a bring-up fix's message names the failure it fixes. Wine patch 13's message names its sources (spec §5). Nothing goes upstream.
- **Cleanup:** `wineserver -k`, then `lsof -t <binary>` and kill; never `pkill -f`.
- **Never:** push, fork, open PRs or MRs, or post anywhere. Ask in chat before any `brew install` and before any download not pinned in `wine-arm64/pins` or `dxmt/pins` (the llvm-project clone at `LLVM_TAG` is pinned).
- **The Rosetta stack stays untouched:** `make test`, `sh dxmt/tests/build_test.sh` and `make dxmt-check` pass after every task that touches `dxmt/`, `presenter/` or the `Makefile`. `make dxmt-check` prints 214 `ok` lines since Task 1 (213 before, plus its new build test); Task 7 records the exact set as the baseline Rosetta mode must keep.
- **No reduced security:** nothing in this plan disables SIP, library validation beyond sub-project 1's entitlements, or uses kexts.
- **Commits** end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Signing environment** for every build: `MACNEUTRON_SIGN_IDENTITY="Developer ID Application: Chad Cormier Roussel (49QMZXLR8S)"`, `MACNEUTRON_PROVISIONING_PROFILE="$HOME/Downloads/Mac_Neutron.provisionprofile"`.
- **Time box:** three weeks from Task 1 (spec §1).

## Review Focus

1. **Paths with spaces.** `check.sh`'s work folder is `build/wine-arm64 check`, its prefix `prefix arm64`, and `dxmt/check.sh`'s work folder lives under it; every new path in `run()`'s arm64 branch, the prefix clones, `winshot`'s arguments and the `dxmt` step must survive them. Pinned by Task 7's arm64-mode runs, which use those paths.
2. **Rosetta mode unchanged under `set -eu`.** With no `MACNEUTRON_ARM64_*` set, `dxmt/check.sh` must behave exactly as before: no unset-variable abort, the same `ok` lines as Task 7's baseline. Pinned in Task 7, Step 6.
3. **An interrupt or step timeout during a DXMT lane** must leave no process of either runtime, including the Rosetta clones `dxmt/check.sh` makes under `check.sh`'s work folder. Pinned in Task 7, Step 9.
4. **A development DXMT tree** (an extra commit in `build/wine-arm64-src/dxmt`) builds as development, bundles with `+dev`, writes no stamp, and returns to `applied` after `make wine-arm64-export`. Pinned in Task 3, Step 5.
5. **A partial run** (`check.sh dxmt-x64` alone) pulls in `boot`, `fex` and `dxmt` and runs the lane as a full run would. Pinned in Task 7, Step 8.

---

### Task 1: One LLVM recipe for both architectures (`dxmt/llvm.sh`)

**Files:**
- Create: `dxmt/llvm.sh`
- Modify: `dxmt/build.sh` (lines 13-36 and 78-91 move out; calls change)
- Test: `dxmt/tests/build_test.sh`

**Interfaces:**
- Produces (sourced; uses the caller's `die` and `LLVM_TAG`; messages to stderr):
  - `build_llvm <arch> <install> <llvm-project>`: returns at once when `<install>/.complete` exists. Otherwise clones `llvm-project` at `LLVM_TAG` into `<llvm-project>.tmp` (removed first) and moves it into place if `<llvm-project>/llvm` is missing, then configures `<install>-build` with `dxmt/build.sh`'s current flags but `-DCMAKE_OSX_ARCHITECTURES=<arch> -DLLVM_HOST_TRIPLE=<arch>-apple-darwin`, builds, installs, logs to `<install>.log`, and touches `<install>/.complete` last.
  - `build_probe <arch> <llvm> <out-dir> <log-dir>` and `build_translate <arch> <llvm> <dxmt-src> <dxmt-build> <out-dir> <log-dir>`: today's two functions with `-arch <arch>`, `/usr/bin/clang++`, and `<dxmt-build>/src/airconv/darwin/libairconv.a`, `<dxmt-build>/libs/DXBCParser/libDXBCParserNative.a`.
- `dxmt/build.sh` calls `build_llvm x86_64 "$LLVM" "$SRC/llvm-project"`, `build_probe x86_64 "$LLVM" "$1" "$SRC"`, `build_translate x86_64 "$LLVM" "$SRC/dxmt" "$SRC/win64" "$1" "$SRC"`.

- [ ] **Step 1: Write the failing test** — append to `dxmt/tests/build_test.sh`, before its final status line:

```sh
# dxmt/llvm.sh reuses a finished LLVM install: with .complete present, nothing is cloned or built (stub cmake/git fail).
mkdir -p "$T/llvm/install" "$T/bin3"; touch "$T/llvm/install/.complete"
printf '#!/bin/sh\necho called >> "%s/called"; exit 1\n' "$T" > "$T/bin3/cmake"; cp "$T/bin3/cmake" "$T/bin3/git"
chmod +x "$T/bin3/cmake" "$T/bin3/git"
out=$(PATH="$T/bin3:/usr/bin:/bin" sh -c '. "$1/dxmt/pins"; die() { echo "$*"; exit 1; }; . "$1/dxmt/llvm.sh"
  build_llvm arm64 "$2/llvm/install" "$2/llvm/project" && echo reused' sh "$ROOT" "$T" 2>&1) || true
expect "a finished LLVM install is reused" "$out:$([ -f "$T/called" ] && echo called)" "reused:"
```

- [ ] **Step 2:** Run `sh dxmt/tests/build_test.sh`. Expected: `FAIL a finished LLVM install is reused` (no `dxmt/llvm.sh`).
- [ ] **Step 3:** Create `dxmt/llvm.sh` with the three functions; make `dxmt/build.sh` source it after `dxmt/lib.sh` and call it as above (its behaviour, folders and log names unchanged; the comment's "30-60 minutes" becomes "a few minutes").
- [ ] **Step 4:** Run `sh dxmt/tests/build_test.sh`. Expected: every line `ok`.
- [ ] **Step 5:** Run `rm build/dxmt/version && make dxmt`. Expected: `dxmt: built …/build/dxmt (1fba8d25…)` with no LLVM build message (reused), and `build/dxmt/dxil-probe`, `dxil-translate` rebuilt (`file` says x86_64).
- [ ] **Step 6:** Run `make test`. Expected: passes. Commit `dxmt/llvm.sh dxmt/build.sh dxmt/tests/build_test.sh`: "dxmt: one LLVM recipe for both architectures (dxmt/llvm.sh)".

### Task 2: DXMT patch 1 and the arm64 DXMT build

**Files:**
- Create: `wine-arm64/patches/dxmt/0001-d3d12-Read-the-ARM64-counter-on-arm64-builds.patch`
- Modify: `wine-arm64/build.sh`, `wine-arm64/export.sh`, `wine-arm64/README.md`

**Interfaces:**
- Consumes: Task 1's `build_llvm`, `build_probe`, `build_translate`.
- Produces:
  - `build/wine-arm64-src/dxmt` (branch `macneutron`), `dxmt.applied`, `dxmt.series`; `dxmt-build/` (meson, configured once per tree); `dxmt-install/` with `aarch64-unix/winemetal.so`, `aarch64-windows/winemetal.dll`, `system32/{d3d11,d3d10core,dxgi,d3d12}.dll`, `system32/dxmt-replay.exe`, and `version` (the spec §6 token, written by `build.sh`).
  - `build/wine-arm64-src/llvm-arm64/` (LLVM install); `build/wine-arm64/dxil-probe`, `build/wine-arm64/dxil-translate` (arm64).
  - `export_tree <repo> <pinned commit> <pins file>` in `export.sh`, called for `wine`, `fex`, `dxmt`.

- [ ] **Step 1: Make DXMT patch 1.** In a scratch clone at the pin (`git init`, `fetch --depth 1 origin 1fba8d25…`, `checkout -b macneutron FETCH_HEAD`), change `src/d3d12/d3d12_stats.cpp` as spec §4's table says (one `read_counter()` used at all four `__rdtsc` sites; `#include "util_bit.hpp"` after `d3d12_stats.hpp`; `<x86intrin.h>` only under `DXMT_ARCH_X86`). Commit with subject `d3d12: Read the ARM64 counter on arm64 builds.` and a body naming the arm64 compile error; `git format-patch --zero-commit -N -1 -o wine-arm64/patches/dxmt/`.
- [ ] **Step 2: Confirm both architectures compile it.** With `compile_commands.json` from the exploration build (`build/arm64/sp2-explore/full`) compile `d3d12_stats.cpp` for arm64ec; and in `build/dxmt-src/win64` (x86_64) compile the patched file with that build's command. Expected: both compile with no error.
- [ ] **Step 3: Add the tree to `build.sh`.** Source `dxmt/pins` and `dxmt/llvm.sh`; `need_tool meson meson` plus the Metal Toolchain check (`xcrun metal --version`, named `Metal Toolchain (xcodebuild -downloadComponent MetalToolchain)`) before `die_if_missing`; `fetch_dxmt` as spec §4 (removes `dxmt-build` and `dxmt-install` with the old tree); `dxmt_series=$(series_of "$ROOT/dxmt/pins" "$DXMT_PATCHES"/*.patch)`; the stamp gains `dxmt/pins`, the DXMT patches, `dxmt/llvm.sh`, `dxmt/tools/dxil-probe.cpp`, `dxmt/tools/dxil-translate.mm`; `dxmt_mode`, `prepare dxmt`, and the development test over all three modes. After FEX: `build_llvm arm64 "$SRC/llvm-arm64" "$B/dxmt-src/llvm-project"`; meson setup (once, when `dxmt-build/build.ninja` is missing) with the Global Constraints' options and `--prefix "$SRC/dxmt-install"`, `meson compile`, then `rm -rf dxmt-install && meson install`, all logged to `$SRC/dxmt.log`; write `dxmt-install/version`; `mkdir -p "$OUT"` (bundle.sh makes it later, and a clean `build/` has none); `build_probe arm64 …` and `build_translate arm64 "$SRC/llvm-arm64" "$SRC/dxmt" "$SRC/dxmt-build" "$OUT" "$SRC"`.
- [ ] **Step 4: Export three trees.** `export.sh` checks `wine fex dxmt` and calls `export_tree dxmt "$DXMT_COMMIT" "$ROOT/dxmt/pins"` (Wine and FEX pass `wine-arm64/pins`); it sources `dxmt/pins`.
- [ ] **Step 5: Build.** Run `make wine-arm64` (signing environment set). Expected: `wine-arm64: built …/wine.app`; `build_mode build/wine-arm64-src/dxmt build/wine-arm64-src/dxmt.applied` prints `applied`; `file build/wine-arm64-src/dxmt-install/aarch64-unix/winemetal.so build/wine-arm64/dxil-probe` says arm64; `cat build/wine-arm64-src/dxmt-install/version` matches `^1fba8d25b5e29ab49012d633676a6b0d4b3b96c5\+[0-9a-f]{12}$`.
- [ ] **Step 6: Host tools.** Run `build/wine-arm64/dxil-translate dxmt/tests/shaders | tail -1` and `build/wine-arm64/dxil-translate dxmt/tests/dxil | tail -1`. Expected: second field `31/31` and `11/12` (`dxmt/check.sh:682-684`'s values).
- [ ] **Step 7: Up to date and round trip.** Run `make wine-arm64` again. Expected: `wine-arm64: up to date`. Then `make wine-arm64-export` and `make wine-arm64`. Expected: `exported 1 dxmt patches`, no change under `wine-arm64/patches/` (`git status --short wine-arm64/patches` empty), and `up to date`.
- [ ] **Step 8:** README (`wine-arm64/README.md`): the DXMT tree in the development loop, one paragraph. Run `sh wine-arm64/tests/mode_test.sh`. Expected: passes. Commit: "wine-arm64: build DXMT for ARM64X (patch 1: the ARM64 counter in d3d12_stats)".

### Task 3: DXMT in the bundle (gate D1)

**Files:**
- Modify: `wine-arm64/bundle.sh`

**Interfaces:**
- Consumes: Task 2's `dxmt-install/` (including `version`) and the DXMT tree.
- Produces: spec §6's layout under `wine.app/Contents/Resources/`.

- [ ] **Step 1:** Run `make wine-arm64` after touching `wine-arm64/bundle.sh`'s comment only, then `ls build/wine-arm64/wine.app/Contents/Resources/DXMT`. Expected: missing (the failing state).
- [ ] **Step 2: Copy and assert.** In `bundle.sh` before signing: copy as spec §6's table; licences from the DXMT tree; `version` from `dxmt-install`. Assertions (each `die` names the file): `winemetal.dll` has the builtin marker (bytes 64-79 = `Wine builtin DLL`, as `dxmt/build.sh:119`); the five front-end files exist and lack it; `aarch64-unix/winemetal.so` exists; the version's part before `+` is `DXMT_COMMIT`; `git -C <dxmt tree> merge-base --is-ancestor "$DXMT_COMMIT" HEAD`.
- [ ] **Step 3:** Run `make wine-arm64`. Expected: staged; `codesign --verify --strict --deep build/wine-arm64/wine.app` exits 0; the layout matches spec §6.
- [ ] **Step 4: A bad bundle stops.** Copy `dxmt-install` aside, replace `system32/d3d11.dll` with `aarch64-windows/winemetal.dll`, run `sh wine-arm64/bundle.sh`. Expected: exit 1 naming `d3d11.dll` and the marker, and `build/wine-arm64/wine.app` unchanged (its mtime). Restore.
- [ ] **Step 5: A development tree.** Commit an empty change in `build/wine-arm64-src/dxmt` (`git commit --allow-empty -m test`); `make wine-arm64`. Expected: `development build`, the bundle's `DXMT/version` ends `+dev`, no `build/wine-arm64/version`. Then `git -C build/wine-arm64-src/dxmt reset --hard HEAD~1`, `make wine-arm64`. Expected: built as applied, stamp written.
- [ ] **Step 6: D1.** `rm -rf build/wine-arm64-src/dxmt build/wine-arm64-src/dxmt-build build/wine-arm64-src/dxmt-install build/wine-arm64-src/llvm-arm64 build/wine-arm64-src/llvm-arm64-build build/wine-arm64-src/llvm-arm64.log build/wine-arm64` then `make wine-arm64`. Expected: builds (LLVM arm64 included) and stages; record the wall time. Run `make wine-arm64-check` (sub-project 1 steps). Expected: all PASS, `PASS orphans`. Commit: "wine-arm64: DXMT in wine.app, asserted (gate D1)".

### Task 4: Test programs and the screen helper

**Files:**
- Modify: `Makefile`, `presenter/tests/present_loop.c`
- Create: `wine-arm64/tools/winshot.c`

**Interfaces:**
- Produces:
  - `make dxmt-tests-arm64ec` → `build/dxmt-tests-arm64ec/<19 d3d12_*>.exe` and `present_loop.exe` (ARM64EC).
  - `present_loop … cycles=N` (spec §7: odd rounds release then `DestroyWindow`, even rounds `DestroyWindow` then release; last line `cycles N ok`).
  - `build/wine-arm64-tests/winshot <title> <png>` → stdout `pixels <n> green <pct> white <pct>` (integers, percent of all pixels), exit 0; exit 1 with a message naming `System Settings > Privacy & Security > Screen Recording` when capture isn't allowed, or `no on-screen window titled <title>` after 30 s.
  - The measured shares, recorded in the ledger and later in the acceptance doc, from which Task 6 sets its thresholds.

- [ ] **Step 1:** Add the Makefile target (`arm64ec-w64-mingw32-clang++ -std=c++17 … -ld3d12 -ldxgi -luser32 -lpsapi` for the 19, `arm64ec-w64-mingw32-clang … -ld3d11 -ldxgi -luser32 -lgdi32 -ldxguid -luuid` for `present_loop`, parallel like `dxmt-tests`); run `make dxmt-tests-arm64ec`. Expected: 20 files; `llvm-readobj --file-headers` of one shows machine `ARM64EC` (or `ARM64X`/0xA641).
- [ ] **Step 2:** Add `cycles=N` to `present_loop.c` (the existing argument loop gains `cycles=`; the window/device/swap chain/frames block runs N times; default 1 keeps every current output line). Run `make presenter dxmt-tests-arm64ec`. Expected: both build with no warnings new to the file.
- [ ] **Step 3:** Write `winshot.c` (spec §7; capture into a `CGBitmapContext` made with `CGColorSpaceCreateWithName(kCGColorSpaceSRGB)`, RGBA8; green = G in 60..95, white = R, G and B > 200) and its rule `build/wine-arm64-tests/winshot` (`/usr/bin/clang -O1 … -framework CoreGraphics -framework ImageIO -framework CoreFoundation`), listed in `wine-arm64-tests`. Run `make wine-arm64-tests && build/wine-arm64-tests/winshot nosuchwindow "$TMPDIR/x.png"`. Expected after ~30 s: exit 1, `no on-screen window titled nosuchwindow`.
- [ ] **Step 4: Measure a window known to present.** Clone the installed tool folder (`cp -cR` from its resolved path) into a scratch folder, copy `.build/release/macneutron` into its `bin/`, install `build/dxmt` with `macneutron install-dxmt --tool-dir`, and with `STEAM_COMPAT_DATA_PATH=<scratch>/compat SteamAppId=0 MACNEUTRON_NO_STEAM_BRIDGE=1 MACNEUTRON_NO_METALFX=1 MACNEUTRON_GRAPHICS=dxmt` first create the prefix (`launch getcompatpath <scratch>`, so its boot isn't inside `winshot`'s 30 s), then launch `build/presenter/present_loop.exe 1280 720 1280 720 3000 0` (`launch waitforexitandrun`) while `winshot present_loop`; then `build/dxmt-tests/d3d12_clear.exe 3000` while `winshot d3d12_clear`. Expected: both programs finish (`frames 3000`, `presented 3000/3000 frames`); record both `winshot` lines. Clean up with the clone's `wineserver -k` and `lsof -t`.
- [ ] **Step 5:** Run `make test`, `sh dxmt/tests/build_test.sh`, `make presenter-check` and `make dxmt-check`. Expected: pass (`dxmt-check: all passed`). Commit: "tests: ARM64EC D3D test programs, present_loop cycles, winshot".

### Task 5: The `dxmt` step and bring-up

**Files:**
- Modify: `wine-arm64/check.sh`
- Possibly create: further patches in `wine-arm64/patches/{dxmt,wine,fex}/` (only from failures seen here)

**Interfaces:**
- Produces: step `dxmt` (`NEEDS_PREFIX`); `dxmt_run <wine args…>` = `WINEDLLOVERRIDES="dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b" wine_run …`; `NEEDS_DXMT` (empty until Task 6).

- [ ] **Step 1:** Add `dxmt_cmd` (spec §7's `dxmt` row; it sources `dxmt/pins` for `DXMT_COMMIT`; ends with `WINEPREFIX="$PFX" "$TOOL/Contents/Resources/bin/wineserver" -w`) and the step (cap 120) after `g5-jit`. Run `sh wine-arm64/check.sh dxmt`. Expected: `PASS boot`, `PASS dxmt`, `PASS orphans`.
- [ ] **Step 2: ARM64EC load.** With the check's prefix kept (run `check.sh dxmt`, then use a copy of its prefix), run `WINEDEBUG=+loaddll` `dxmt_run build/dxmt-tests-arm64ec/d3d12_null.exe "Z:<repo>/dxmt/tests/shaders/null.cs.dxil"`. Expected: `loaddll` lines show `system32\d3d12.dll` and `dxgi.dll` loaded as native and `winemetal.dll` as builtin; 18 lines starting `null `; exit 0.
- [ ] **Step 3: x64 load under FEX.** Same with `build/dxmt-tests/d3d12_null.exe` in a prefix where `fex` ran. Expected: the same lines.
- [ ] **Step 4: Fix what fails.** For each failure in Steps 2-3, use superpowers:systematic-debugging; the fix is a commit in the tree at fault, exported with `make wine-arm64-export`, its message naming the failure. Re-run Steps 2-3 until both pass.
- [ ] **Step 5:** Record the bring-up output (the `loaddll` lines, the 18 `null` lines, times) in the ledger for the acceptance doc. Commit: "wine-arm64: check step dxmt; DXMT loads in both lanes" (plus any patch files).

### Task 6: Wine patch 13 and the on-screen gate (gate D2)

**Files:**
- Modify: `wine-arm64/check.sh`
- Create: `wine-arm64/patches/wine/00NN-winemac.drv-Export-macdrv_functions-so-DXMT-can-present.patch` ("Wine patch 13" in the spec; its number is the next free one)

**Interfaces:**
- Consumes: Task 4's programs, `winshot` and measured shares; Task 5's `dxmt_run`.
- Produces: step `dxmt-present` (cap 600 s; in `NEEDS_PREFIX`, `NEEDS_FEX`, `NEEDS_DXMT`); thresholds as named constants in `check.sh` with a comment citing Task 4's measurement: `present_loop` green ≥ measured − 15 and white ≥ half the measured; `d3d12_clear` green ≥ measured − 15.

- [ ] **Step 1:** Write `dxmt_present_cmd` (spec §7's row: both lanes; each program in the background, `winshot` on its title, then `wait`; each check prints its shares as an `info` line; the cycles run in the ARM64EC lane). Run `sh wine-arm64/check.sh dxmt-present`. Expected: `FAIL dxmt-present` (no `macdrv_functions` yet: DXMT aborts, or the window is blank).
- [ ] **Step 2:** `git -C build/wine-arm64-src/wine am <repo>/docs/research/2026-10-03-arm64-dxmt/0013-*.patch`; `make wine-arm64` (development build). Run `sh wine-arm64/check.sh dxmt-present`. Expected: `PASS dxmt-present` with the `info` lines.
- [ ] **Step 3: If it fails,** debug with superpowers:systematic-debugging, then spec §1's fallbacks in order (each a commit in the tree it touches, message naming the failure). Stop only when every path is a guess (time box).
- [ ] **Step 4:** Amend the commit's message (`git commit --amend`) to name its sources as spec §5 says (the draft names only "CrossOver's d3dmetal.c"); keep the author. `make wine-arm64-export`; `make wine-arm64` (applied). Run `sh wine-arm64/check.sh dxmt-present`. Expected: `PASS dxmt-present`, `PASS orphans`; the window-binding patch exists in `wine-arm64/patches/wine/` (numbered in landing order: 0013 unless a Task 5 fix landed first), its message naming CodeWeavers' `d3dmetal.c` (Brendan Shanks, LGPL-2.1+, `athei/wine` `cx-26-patched`) and `dappermint/winecx` `713015fa9f`, `13e6a88a02`, `565f6386b7`.
- [ ] **Step 5:** Commit: "wine-arm64: Wine patch 13 (macdrv_functions + present report); check step dxmt-present (gate D2)".

### Task 7: `dxmt/check.sh` arm64 mode and the lane steps

**Files:**
- Modify: `dxmt/check.sh`, `wine-arm64/check.sh`, `Makefile`

**Interfaces:**
- Consumes: Tasks 4-6.
- Produces:
  - `dxmt/check.sh`: `DXMT_CHECK_WORK`; arm64 mode by `MACNEUTRON_ARM64_APP`, `_PREFIX`, `_TESTS`, `_LOOP`, `_TOOLS` (spec §7, every bullet), whose first output line is `info arm64 mode: <app>`. Its arm64 branch of `run` passes `WINEPREFIX`, `WINEDLLOVERRIDES` (Global Constraints' value), `WINEDEBUG="${WINEDEBUG:--all}"` (the launcher's default) and `DXMT_SHADER_CACHE_PATH` on the command (`env …`), never exported: an exported override would reach the D3DMetal launcher runs, which would then load DXMT and compare it with itself. Path mapping: `$TESTS/*` → `_TESTS`, `$LOOP` → `_LOOP`, `$RP` → the bundle's `DXMT/aarch64-windows/dxmt-replay.exe`; line 87's check compares the bundle's `DXMT/aarch64-windows/d3d11.dll` with the arm64 `ours` prefix clone's `system32/d3d11.dll`.
  - Tool `x86` is the Rosetta branch with tool folder `$WORK/ours` and compat folder `ours` (which the prefix loop already creates outside the watchdog).
  - A `TERM`/`EXIT` trap (both modes; the lane pids start empty for `set -u`) kills the five lane subshells and their children and, in arm64 mode, runs `wineserver -k` on each arm64 prefix clone. `wine-arm64/check.sh`'s `stop_step` TERMs `dxmt/check.sh` but can't reach its lanes (grandchildren, which ignore SIGINT as background jobs).
  - `invalid` prints `off` when a run has no `Metal API Validation Enabled` line (presence: a run can print it more than once, one per process).
  - `wine-arm64/check.sh`: steps `dxmt-arm64ec`, `dxmt-x64` (cap 3600 each); `NEEDS_DXMT="dxmt-present dxmt-arm64ec dxmt-x64"`; all DXMT steps in `NEEDS_PREFIX` and `NEEDS_FEX`; `runtime_pids` covers `$WORK/dxmt-*/{stock,ours}`'s `bin/macneutron`, `Libraries/Wine/lib/wine/x86_64-unix/wine`, `Libraries/Wine/bin/wineserver`; a failing lane's FAIL line is `<n> FAIL lines; first: <line>`, or the log's last line when there is no `FAIL` line (an early `die`).
  - `Makefile`: `wine-arm64-check: build wine-arm64 wine-arm64-tests dxmt dxmt-tests presenter dxmt-tests-arm64ec`.

- [ ] **Step 0: Baseline.** Before changing `dxmt/check.sh`, run `make dxmt-check 2>&1 | grep '^ok' | sort > .superpowers/sdd/2026-10-03-macneutron-arm64-dxmt/dxmt-check-baseline.txt`. Expected: `dxmt-check: all passed`, 214 lines.
- [ ] **Step 1: Write the failing test.** Add the `dxmt-arm64ec` step calling `dxmt/check.sh` with the arm64 variables (`DXMT_CHECK_WORK="$WORK/dxmt-arm64ec"`, prefix `$PFX`, tests `build/dxmt-tests-arm64ec`, loop `build/dxmt-tests-arm64ec/present_loop.exe`, tools `build/wine-arm64`, app `$TOOL`) and requiring both `info arm64 mode: ` and `dxmt-check: all passed`. Run `sh wine-arm64/check.sh dxmt-arm64ec`. Expected: FAIL (no arm64 mode line: the script ignores the variables and runs on Rosetta).
- [ ] **Step 2:** Implement arm64 mode in `dxmt/check.sh` per spec §7. The arm64 branch of `run` keeps the Rosetta branch's watchdog and output handling; every `MACNEUTRON_ARM64_*` read uses `${…:-}`.
- [ ] **Step 3:** Change `invalid` (both modes).
- [ ] **Step 4:** Add `dxmt-x64` (tests `build/dxmt-tests`, loop `build/presenter/present_loop.exe`; also requires the line `ok   the FSR 3 swapchain proxy presents on our DXMT`), the lists, `runtime_pids`, the FAIL line, and the Makefile prerequisites.
- [ ] **Step 5:** Run `sh wine-arm64/check.sh dxmt-arm64ec`. Expected: the step runs to its end (pass or fail); its log shows our DXMT's runs used the arm64 prefixes (`ls "build/wine-arm64 check/dxmt-arm64ec/arm64"` lists `ours` and `ours-A`…`ours-E`) and D3DMetal's used the Rosetta clone; `PASS orphans`. Record the `ok`/`FAIL` counts and the time.
- [ ] **Step 6: Rosetta mode unchanged.** Run `make dxmt-check 2>&1 | grep '^ok' | sort` and diff with Step 0's baseline. Expected: `dxmt-check: all passed`, no difference.
- [ ] **Step 7:** Run `sh wine-arm64/check.sh dxmt-x64`. Expected: runs to its end; counts and time recorded; `PASS orphans`.
- [ ] **Step 8: Partial run.** `sh wine-arm64/check.sh dxmt-x64` output starts `PASS boot`, `PASS fex`, `PASS dxmt` (in `STEPS` order).
- [ ] **Step 9: Interrupt.** Start `sh wine-arm64/check.sh dxmt-arm64ec`; once `build/wine-arm64 check/dxmt-arm64ec/lane-A.log` exists (the lanes are running), send SIGINT. Expected: last line `PASS orphans`; 30 s after exit, `lsof -t` on every binary `runtime_pids` lists finds nothing and no lane log has grown.
- [ ] **Step 10:** Commit: "dxmt/check.sh: arm64 mode; check steps dxmt-arm64ec and dxmt-x64".

### Task 8: Both lanes pass (gates D3, D4)

**Files:**
- Patches in `wine-arm64/patches/{dxmt,wine,fex}/` (from failures only); `wine-arm64/check.sh` only if a check's plumbing is wrong.

**Interfaces:**
- Consumes: Task 7's steps and their recorded failures.

- [ ] **Step 1:** List every `FAIL` line from Task 7's two runs in the ledger, grouped by cause (expected kinds: spec §11's host rounding, weak-memory races in lane B, ARM64EC/x64 call path, present path).
- [ ] **Step 2:** For each group: superpowers:systematic-debugging to the root cause; the fix is a commit in the tree at fault (for host rounding first `-ffp-contract=off` on DXMT's unix side), exported, its message naming the failing check. An expected string or tolerance changes only if the difference is proven to be the host's and is recorded with its reason in the acceptance doc.
- [ ] **Step 3:** Re-run the failing lane after each fix (`sh wine-arm64/check.sh dxmt-arm64ec`, `… dxmt-x64`). Expected at the end: `PASS dxmt-arm64ec`, `PASS dxmt-x64`, `PASS orphans`; `make dxmt-check` still matches Task 7's baseline.
- [ ] **Step 4:** Commit each fix with its patch file as it lands.

### Task 9: Acceptance (D1–D6) and docs

**Files:**
- Create: `docs/testing/acceptance-arm64-dxmt.md`
- Modify: `README.md`, `wine-arm64/README.md`, `docs/superpowers/specs/2026-10-03-macneutron-arm64-dxmt-design.md` (status line only)

- [ ] **Step 1: D1** from Task 3, Step 6's removal, with every patch in place; record the time.
- [ ] **Step 2:** `make wine-arm64-check`. Expected: every step PASS, `PASS orphans`; record the total time, the `winshot` lines, both lanes' `ok` counts, and section 1's `info` frame times (D6).
- [ ] **Step 3: D5.** `make test`; `make dxmt-check` (Task 7's baseline `ok` lines); `rm build/dxmt/version && make dxmt` (rebuilt through `dxmt/llvm.sh`, LLVM reused).
- [ ] **Step 4:** Write the acceptance doc (spec §10's list: build, bring-up, `winshot` on the Rosetta reference and both lanes, the steps, D6, D5's results, the orphan line, run time, DXMT commit and patch list, any recorded host differences). README: one line on DXMT in the arm64 runtime; `wine-arm64/README.md`: the new steps and `winshot`'s Screen Recording prerequisite. Spec status: implemented.
- [ ] **Step 5:** Commit: "docs: native arm64 sub-project 2 acceptance".
