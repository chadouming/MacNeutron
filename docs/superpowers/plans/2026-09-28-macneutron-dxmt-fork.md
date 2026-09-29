# DXMT Fork, Sub-project 1 (Fork, Build, Capture) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** MacNeutron builds, ships and installs its own DXMT fork with Direct3D 12 enabled, makes it the default graphics backend for every game, captures the DXIL shaders DXMT can't translate yet, and records whether LLVM 15 can read them.

**Architecture:** A public fork (`chadouming/dxmt`, branch `macneutron`) carries two small changes: a README note and `DXMT_DXIL_DUMP`. `dxmt/build.sh` fetches the pinned inputs, builds LLVM 15 once, and cross-builds DXMT twice with meson (win64 with D3D12, win32). It stages the result in `build/dxmt`. The Swift side installs that build over the runtime's DXMT 0.80: at runtime install, at app start when the version differs, and through a new `install-dxmt` command. `GraphicsBackend` defaults to `dxmt` and takes over `d3d12` when our `d3d12.dll` is installed. `dxmt/check.sh` exercises all of it under real Wine.

**Tech Stack:** POSIX sh, meson + ninja, CMake, mingw-w64 (gcc/g++ cross), LLVM 15.0.7 (C++17), Swift 6 + swift-testing, DXC (Windows build, run under Wine).

**Spec:** `docs/superpowers/specs/2026-09-28-macneutron-dxmt-fork-design.md`

## Global Constraints

- Fork: `github.com/chadouming/dxmt`, branch `macneutron`, cut from upstream `main`. Nothing goes upstream except issue reports: DXMT refuses AI-authored contributions.
- Ask in chat before: creating the fork, pushing to it, every download (name, source and size), and every `brew install`. `dxmt/build.sh` never installs anything itself.
- LGPL-2.1+: every shipped DXMT binary travels with `COPYING.LIB`, `LICENSE` and `LICENSE.OLD`, and with a `version` file holding the fork commit it was built from. That commit is public on the fork.
- Pins: `llvmorg-15.0.7`; `https://github.com/3Shain/wine/releases/download/v8.16-3shain/wine.tar.gz` with its SHA-256; DXC `v1.9.2607` (`dxc_2026_07_29.zip`) with its SHA-256.
- Overrides, exactly:
  - `dxmt` with our `d3d12.dll`: `dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b`;
  - `dxmt` without it: `dxgi,d3d10core,d3d11=n,b;d3d9,d3d10,d3d12=b`;
  - `d3dmetal` and `dxvk`: unchanged.
- Default backend: `dxmt` whenever `MACNEUTRON_GRAPHICS` is missing or invalid, GPTK or not. `d3dmetal` without GPTK still falls back to `dxmt`, and `dxvk` with GPTK still falls back to `d3dmetal`.
- Never redistribute Apple GPTK files.
- Never commit SteamIDs, account IDs or persona names (acceptance notes included).
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`, on MacNeutron and on the fork alike.
- Swift 6 language mode, swift-testing; `swift test` stays green after every task.

## Plan-level decisions (beyond the spec's text)

Each of these carries out the spec; recorded so the final reviewer can weigh them:
1. **`-Dwine_builtin_dll=false`.** Upstream's default stamps `d3d11/dxgi/d3d10core/d3d12` with Wine's builtin marker. The runtime's DXMT 0.80 front ends carry no marker, while its `winemetal.dll` does (checked 2026-09-28). A marked DLL in `system32` makes Wine load its own builtin instead. `build.sh` asserts both facts when staging.
2. **`-Dwine_install_path`, not `wine_build_path`.** The 3Shain tarball is an install tree, and it's what DXMT's CI passes.
3. **32-bit without D3D12.** §5 installs no 32-bit `d3d12`, so the win32 build doesn't enable it.
4. **`LICENSE.OLD` shipped too.** It holds the MIT notice for code from DXMT ≤ 0.80.
5. **`macneutron install-dxmt [--tool-dir <dir>] <folder>`.** `check.sh` uses it, as do developers after `make dxmt`. It goes through the same `DXMTInstaller.install` as the app.
6. **D3D12 tests are C++ (`.cpp`), not C.** D3D12 methods returning structs have an ABI quirk in mingw's C headers. `WIDL_EXPLICIT_AGGREGATE_RETURNS` in C++ handles it.
7. **The capture test also creates a compute pipeline.** It checks three captured shaders, not two, so compute capture is exercised as well.
8. **`DXMT_DXIL_DUMP` accepts a Mac path.** A value starting with `/` gets `Z:` prepended, because launch options carry Mac paths.
9. **`check.sh` never touches the installed tool folder.** It works on two APFS clones: "stock", with DXMT 0.80 restored from the cached runtime tarball, and "ours", with `build/dxmt` installed. Both use the freshly built launcher.

## Review Focus

- **An install that fails part-way:** a missing front end or a copy error mid-install must not leave `dxmt-version` claiming the new build; the next app start retries. Test: `aFailedInstallLeavesNoVersionSoTheNextStartRetries` (Task 2).
- **A runtime reinstall with a launcher that ships no DXMT** (the CLI from `.build/release`): `dxmt-version` must go, because the fresh runtime brings DXMT 0.80 back. Test: `reinstallWithoutABundledDXMTForgetsTheOldOne` (Task 2).
- **A prefix still holding our `d3d12.dll` after DXMT lost it** (a runtime reinstall): `d3d12` must stay `=b`, so the stale native DLL is never loaded next to DXMT 0.80's `winemetal`. Test: `dxmtTakesD3D12OnlyWithOurD3D12` (Task 3).
- **A user's own `WINEDLLOVERRIDES=d3d12=b`** while our D3D12 is installed: the user wins. Test: `userOverridesWinOverOurD3D12` (Task 3).
- **`DXMT_DXIL_DUMP`:**
  - a Mac path containing a space (`/…/macneutron dxmt/dxil`) must capture;
  - an unwritable folder must not change what the game gets;
  - an existing capture must never be rewritten.

  Checks in `dxmt/check.sh` (Task 5).

---

## File Structure

| Path | Responsibility |
|---|---|
| `dxmt/pins` (new) | Fork repo and commit, LLVM tag, Wine and DXC URLs and checksums; sourced by `build.sh` |
| `dxmt/build.sh` (new) | `make dxmt`: tool check, fetch, LLVM, two meson builds, staging into `build/dxmt`, `dxil-probe` |
| `dxmt/tests/build_test.sh` (new) | `build.sh`'s refusals, without network: missing tool, bad checksum, up-to-date fast path |
| `dxmt/tools/dxil-probe.cpp` (new) | Reads DXIL containers with LLVM 15 and prints one ok/fail line per file |
| `dxmt/tests/d3d12_clear.cpp` (new) | D3D12 clear-and-present loop; prints adapter, shader model, binding tier, frame time |
| `dxmt/tests/d3d12_dxil.cpp` (new) | Creates a graphics and a compute pipeline from DXIL files; prints each HRESULT |
| `dxmt/tests/shaders/{triangle,compute}.hlsl`, `compile.sh`, `*.dxil` (new) | Test shaders and their committed DXIL (built by DXC under Wine) |
| `dxmt/check.sh` (new) | `make dxmt-check`: our DXMT under real Wine, on cloned tool folders |
| `Sources/MacNeutronCore/DXMTInstaller.swift` (new) | `DXMTBuild` (where a build is) and `DXMTInstaller` (installing it) |
| `Sources/MacNeutronCore/ToolLayout.swift` | `dxmtVersionFile`, `dxmtVersion`, `dxmtD3D12`, `dxmtHasD3D12` |
| `Sources/MacNeutronCore/RuntimeInstaller.swift` | Forget `dxmt-version` on reinstall; apply the bundled DXMT after the GPTK overlay |
| `Sources/MacNeutronCore/CommandLineTool.swift` | `install-dxmt` |
| `Sources/MacNeutronCore/GraphicsBackend.swift` | Default `dxmt`; `dllOverrides(layout:)`; `d3d12.dll` deployment |
| `Sources/MacNeutronCore/LaunchEnvironment.swift`, `Launcher.swift` | Pass the layout through to the overrides |
| `Sources/MacNeutronApp/AppModel.swift` | Install the bundled DXMT at start |
| `Sources/MacNeutronApp/GamesView.swift`, `SetupView.swift` | "Default (DXMT)"; the GPTK step's text |
| `Makefile` | `dxmt`, `dxmt-tests`, `dxmt-check`; `app` bundles DXMT |
| `README.md` | Graphics section, build requirements, launch-option row |
| `docs/testing/acceptance-dxmt-fork.md` (new) | Check results and the maintainer's acceptance run |
| Fork: `README.md`, `src/d3d12/d3d12_dxil_dump.{hpp,cpp}`, `src/d3d12/meson.build`, `src/d3d12/d3d12_pipeline_{graphics,compute}.cpp` | The fork's two changes |

---

### Task 1: The fork, the pins and `make dxmt`

**Files:**
- Create: `dxmt/pins`, `dxmt/build.sh`, `dxmt/tests/build_test.sh`, `dxmt/tools/dxil-probe.cpp`
- Modify: `Makefile`
- Fork (in `build/dxmt-src/dxmt`, branch `macneutron`): `README.md`

**Interfaces:**
- Produces:
  - `build/dxmt/`:
    - `x86_64-windows/{winemetal,d3d11,d3d10core,dxgi,d3d12}.dll` (plus whatever else DXMT installs);
    - `i386-windows/{winemetal,d3d11,d3d10core,dxgi}.dll`;
    - `x86_64-unix/winemetal.so`;
    - `COPYING.LIB`, `LICENSE`, `LICENSE.OLD`;
    - `version` (fork commit + newline);
    - `dxil-probe` (x86_64 Mach-O).
  - `build/dxmt-src/{dxmt,wine,dxc,llvm}`.
  - `make dxmt`.
  - `BUILD_DIR` overrides `build/` (tests only).

- [ ] **Step 1: Ask for approval (stop until the user answers)**

Send this in chat and wait for a yes:
> To build our DXMT I need to:
> 1. Create the public fork `github.com/chadouming/dxmt` (`gh repo fork 3Shain/dxmt --clone=false`) and push a `macneutron` branch to it.
> 2. Download:
>    - the fork (about 10 MB, github.com);
>    - `llvm-project` at `llvmorg-15.0.7`, shallow (about 250 MB download and 1.5 GB on disk, github.com/llvm/llvm-project);
>    - 3Shain's Wine 8.16 tree `wine.tar.gz` (219 MB, github.com/3Shain/wine releases);
>    - Microsoft's `dxc_2026_07_29.zip` (39 MB, github.com/microsoft/DirectXShaderCompiler releases).
>
>    All of it goes into `build/dxmt-src/`. The LLVM build then takes 30–60 minutes and a few GB.
> 3. `brew install meson` (not installed; cmake, ninja and mingw-w64 already are).
>
> OK to do all three?

- [ ] **Step 2: Install meson (after the yes)**

Run: `brew install meson && meson --version`
Expected: a version ≥ 1.4 printed.

- [ ] **Step 3: Write the failing build test**

Create `dxmt/tests/build_test.sh`:

```sh
#!/bin/sh
# dxmt/build.sh's refusals, without network or a real build (DXMT fork spec §7).
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="${TMPDIR:-/tmp}/macneutron dxmt-build-test"
rm -rf "$T"; mkdir -p "$T/bin"
fail=0
expect() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2], want [$3]"; fail=1; fi; }
. "$ROOT/dxmt/pins"

# A missing tool is named with its Homebrew formula: a PATH with every tool but meson.
for t in cmake ninja x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc; do ln -s "$(command -v $t)" "$T/bin/$t"; done
out=$(PATH="$T/bin:/usr/bin:/bin" BUILD_DIR="$T/b1" sh "$ROOT/dxmt/build.sh" 2>&1) && st=0 || st=$?
expect "a missing tool stops the build" "$st" 1
expect "and is named with its formula" "$(echo "$out" | grep -c 'meson (brew install meson)')" 1

# A download that doesn't match its pin stops before anything is built or staged.
mkdir -p "$T/b2/dxmt-src"; echo "not wine" > "$T/b2/dxmt-src/wine.tar.gz"
out=$(BUILD_DIR="$T/b2" sh "$ROOT/dxmt/build.sh" 2>&1) && st=0 || st=$?
expect "a bad checksum stops the build" "$st" 1
expect "and says so" "$(echo "$out" | grep -c 'checksum mismatch for wine.tar.gz')" 1
expect "and stages nothing" "$([ -e "$T/b2/dxmt" ] && echo staged || echo none)" none

# A build already at the pinned commit is left alone, even without the tools.
mkdir -p "$T/b3/dxmt"; echo "$DXMT_COMMIT" > "$T/b3/dxmt/version"; printf '#!/bin/sh\n' > "$T/b3/dxmt/dxil-probe"
chmod +x "$T/b3/dxmt/dxil-probe"
out=$(PATH="/usr/bin:/bin" BUILD_DIR="$T/b3" sh "$ROOT/dxmt/build.sh" 2>&1) && st=0 || st=$?
expect "an up-to-date build is kept" "$st:$(echo "$out" | grep -c 'is up to date')" "0:1"

exit $fail
```

- [ ] **Step 4: Run it to make sure it fails**

Run: `sh dxmt/tests/build_test.sh`
Expected: an error ending the run early, because `dxmt/pins` doesn't exist yet (`.: cannot open …/dxmt/pins`).

- [ ] **Step 5: Create the fork and its `macneutron` branch with the README note**

```bash
gh repo fork 3Shain/dxmt --clone=false
mkdir -p build/dxmt-src
git clone https://github.com/chadouming/dxmt.git build/dxmt-src/dxmt
git -C build/dxmt-src/dxmt remote set-url --push origin git@github.com:chadouming/dxmt.git
git -C build/dxmt-src/dxmt switch -c macneutron origin/main
```

Insert this block at the very top of `build/dxmt-src/dxmt/README.md`, followed by one blank line:

```markdown
> **MacNeutron's fork of DXMT.** This fork is maintained for [MacNeutron](https://github.com/chadouming/MacNeutron)
> and is not affiliated with the DXMT project. Changes on the `macneutron` branch are AI-assisted and, per DXMT's
> contribution policy, are never proposed upstream. Please report problems with this fork to MacNeutron, not to DXMT.
```

```bash
git -C build/dxmt-src/dxmt add README.md
git -C build/dxmt-src/dxmt commit -m "README: note that this is MacNeutron's fork

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git -C build/dxmt-src/dxmt push -u origin macneutron
git -C build/dxmt-src/dxmt rev-parse HEAD
```
Expected: the push succeeds, and the last line prints the 40-hex commit (call it `<FORK1>`).

- [ ] **Step 6: Write `dxmt/pins`**

With `<FORK1>` from Step 5:

```sh
# MacNeutron's DXMT build inputs (DXMT fork spec §5), sourced by dxmt/build.sh.
# DXMT_COMMIT is the head of the fork's `macneutron` branch that MacNeutron ships; LGPL: its source is public there.
DXMT_REPO=https://github.com/chadouming/dxmt.git
DXMT_COMMIT=<FORK1>
LLVM_TAG=llvmorg-15.0.7
# 3Shain's Wine 8.16 tree, which DXMT's CI builds against. SHA-256 recorded at first download, 2026-09-28.
WINE_URL=https://github.com/3Shain/wine/releases/download/v8.16-3shain/wine.tar.gz
WINE_SHA256=
# Microsoft's DirectXShaderCompiler, Windows build: compiles the test shaders. Development only; never shipped.
DXC_URL=https://github.com/microsoft/DirectXShaderCompiler/releases/download/v1.9.2607/dxc_2026_07_29.zip
DXC_SHA256=
```

- [ ] **Step 7: Write `dxmt/build.sh`**

```sh
#!/bin/sh
# Builds MacNeutron's DXMT fork, Direct3D 12 enabled, into build/dxmt (DXMT fork spec §5).
# Downloads each pinned input once into build/dxmt-src and never installs tools. BUILD_DIR replaces build/ (tests).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/dxmt/pins"
B="${BUILD_DIR:-$ROOT/build}"
SRC="$B/dxmt-src"
OUT="$B/dxmt"
LLVM="$SRC/llvm"
die() { echo "dxmt: $*" >&2; exit 1; }

if [ "$(cat "$OUT/version" 2> /dev/null)" = "$DXMT_COMMIT" ] && [ -x "$OUT/dxil-probe" ]; then
  echo "dxmt: $OUT is up to date ($DXMT_COMMIT)"
  exit 0
fi

# 1. Tools.
missing=""
need() { command -v "$1" > /dev/null 2>&1 || missing="$missing, $1 (brew install $2)"; }
need cmake cmake; need ninja ninja; need meson meson
need x86_64-w64-mingw32-gcc mingw-w64; need i686-w64-mingw32-gcc mingw-w64
[ -z "$missing" ] || die "missing tools: ${missing#, }"

# 2. Fetch. Checksummed archives first, so a bad download stops before anything is built or staged.
mkdir -p "$SRC"
fetch() {  # fetch <url> <file> <sha256>
  if [ ! -f "$2" ]; then
    echo "dxmt: downloading $1"
    curl -fL --retry 3 -o "$2.part" "$1" || die "download failed: $1"
    mv "$2.part" "$2"
  fi
  sum=$(shasum -a 256 "$2" | cut -d ' ' -f 1)
  [ "$sum" = "$3" ] || die "checksum mismatch for $(basename "$2"): expected $3, got $sum"
}
fetch "$WINE_URL" "$SRC/wine.tar.gz" "$WINE_SHA256"
fetch "$DXC_URL" "$SRC/dxc.zip" "$DXC_SHA256"
if [ ! -d "$SRC/wine" ]; then
  rm -rf "$SRC/wine.tmp"; mkdir -p "$SRC/wine.tmp"
  tar -xzf "$SRC/wine.tar.gz" -C "$SRC/wine.tmp" || die "can't unpack wine.tar.gz"
  mv "$SRC/wine.tmp" "$SRC/wine"
fi
if [ ! -d "$SRC/dxc" ]; then
  rm -rf "$SRC/dxc.tmp"
  unzip -q "$SRC/dxc.zip" -d "$SRC/dxc.tmp" || die "can't unpack dxc.zip"
  mv "$SRC/dxc.tmp" "$SRC/dxc"
fi

# The fork at the pinned commit. The clone is reused, so a commit made in it builds before it's pushed.
[ -d "$SRC/dxmt/.git" ] || git clone -q "$DXMT_REPO" "$SRC/dxmt" || die "can't clone $DXMT_REPO"
git -C "$SRC/dxmt" cat-file -e "$DXMT_COMMIT^{commit}" 2> /dev/null || git -C "$SRC/dxmt" fetch -q origin \
  || die "can't fetch $DXMT_REPO"
git -C "$SRC/dxmt" diff --quiet HEAD || die "uncommitted changes in $SRC/dxmt: commit them and pin that commit"
git -C "$SRC/dxmt" -c advice.detachedHead=false checkout -q --detach "$DXMT_COMMIT" \
  || die "commit $DXMT_COMMIT isn't in $DXMT_REPO"
git -C "$SRC/dxmt" submodule update -q --init --depth 1 || die "can't fetch DXMT's submodules"

# 3. LLVM 15: x86_64, static, with DXMT's CI flags. Built once.
if [ ! -f "$LLVM/lib/libLLVMCore.a" ]; then
  [ -d "$SRC/llvm-project/llvm" ] || git clone -q --depth 1 --branch "$LLVM_TAG" \
    https://github.com/llvm/llvm-project.git "$SRC/llvm-project" || die "can't clone llvm-project $LLVM_TAG"
  echo "dxmt: building LLVM $LLVM_TAG (30-60 minutes, once); log: $SRC/llvm.log"
  { cmake -B "$SRC/llvm-build" -S "$SRC/llvm-project/llvm" -G Ninja \
      -DCMAKE_INSTALL_PREFIX="$LLVM" -DCMAKE_OSX_ARCHITECTURES=x86_64 -DLLVM_HOST_TRIPLE=x86_64-apple-darwin \
      -DLLVM_ENABLE_ASSERTIONS=On -DLLVM_ENABLE_ZSTD=Off -DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD="" \
      -DLLVM_BUILD_TOOLS=Off -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off -DCMAKE_POLICY_VERSION_MINIMUM=3.5 &&
    cmake --build "$SRC/llvm-build" && cmake --install "$SRC/llvm-build"; } > "$SRC/llvm.log" 2>&1 \
    || die "LLVM build failed; see $SRC/llvm.log"
fi

# 4. DXMT: 64-bit with Direct3D 12, and 32-bit, which gets no D3D12 (spec §5).
# wine_builtin_dll=false keeps the front ends native, as in the runtime's DXMT 0.80: with Wine's builtin marker, a
# d3d11.dll copied into a prefix would make Wine load its own d3d11 instead.
meson_build() {  # meson_build <cross file> <name> <options...>
  cross=$1 name=$2; shift 2
  rm -rf "$SRC/$name" "$SRC/$name-install"
  { meson setup "$SRC/$name" "$SRC/dxmt" --cross-file "$SRC/dxmt/$cross" --buildtype release --strip \
      --prefix "$SRC/$name-install" -Dwine_builtin_dll=false -Dwine_install_path="$SRC/wine" "$@" &&
    meson compile -C "$SRC/$name" && meson install -C "$SRC/$name"; } > "$SRC/$name.log" 2>&1 \
    || die "DXMT $name build failed; see $SRC/$name.log"
}
echo "dxmt: building DXMT $DXMT_COMMIT"
meson_build build-win64.txt win64 -Denable_d3d12=true -Dnative_llvm_path="$LLVM"
meson_build build-win32.txt win32

# 5. Stage. build/dxmt is replaced only once everything is in place and checked.
I64="$SRC/win64-install" I32="$SRC/win32-install" T="$OUT.tmp"
rm -rf "$T"; mkdir -p "$T/x86_64-windows" "$T/i386-windows" "$T/x86_64-unix"
cp "$I64"/x86_64-windows/*.dll "$I64"/system32/*.dll "$T/x86_64-windows/"
cp "$I32"/i386-windows/*.dll "$I32"/syswow64/*.dll "$T/i386-windows/"
cp "$I64"/x86_64-unix/* "$T/x86_64-unix/"
cp "$SRC/dxmt/COPYING.LIB" "$SRC/dxmt/LICENSE" "$SRC/dxmt/LICENSE.OLD" "$T/"
builtin() { [ "$(dd if="$1" bs=1 skip=64 count=16 2> /dev/null)" = "Wine builtin DLL" ]; }
for f in x86_64-windows/winemetal.dll i386-windows/winemetal.dll; do
  builtin "$T/$f" || die "$f lacks Wine's builtin marker"
done
for f in x86_64-windows/d3d11.dll x86_64-windows/d3d10core.dll x86_64-windows/dxgi.dll x86_64-windows/d3d12.dll \
         i386-windows/d3d11.dll i386-windows/d3d10core.dll i386-windows/dxgi.dll; do
  [ -f "$T/$f" ] || die "the build has no $f"
  ! builtin "$T/$f" || die "$f carries Wine's builtin marker"
done
[ -f "$T/x86_64-unix/winemetal.so" ] || die "the build has no x86_64-unix/winemetal.so"
echo "$DXMT_COMMIT" > "$T/version"

# 6. The DXIL probe (spec §6), against the same LLVM. -fno-rtti matches LLVM's own build.
clang++ -arch x86_64 -std=c++17 -O1 -fno-rtti -I"$LLVM/include" "$ROOT/dxmt/tools/dxil-probe.cpp" -o "$T/dxil-probe" \
  -L"$LLVM/lib" -lLLVMBitReader -lLLVMCore -lLLVMRemarks -lLLVMBitstreamReader -lLLVMBinaryFormat -lLLVMSupport \
  -lLLVMDemangle -lz -lcurses > "$SRC/dxil-probe.log" 2>&1 || die "dxil-probe failed to build; see $SRC/dxil-probe.log"
rm -rf "$OUT"; mv "$T" "$OUT"
echo "dxmt: built $OUT ($DXMT_COMMIT)"
```

- [ ] **Step 8: Write `dxmt/tools/dxil-probe.cpp`**

```cpp
// dxil-probe: can LLVM 15 read DXIL? (DXMT fork spec §6)
//   dxil-probe <file.dxil>...
// One line per file:
//   ok <file> dxil=<major>.<minor> <stage>_<major>_<minor> entry=<names> ops=<dx.op callee>:<calls>,... (top 10)
//   fail <file> <reason, or LLVM's error>
// Exits 1 when any file fails.
#include <llvm/Bitcode/BitcodeReader.h>
#include <llvm/IR/Instructions.h>
#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/Metadata.h>
#include <llvm/IR/Module.h>
#include <llvm/Support/Error.h>
#include <llvm/Support/MemoryBuffer.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <map>
#include <string>
#include <vector>

static uint32_t read32(const std::vector<char> &blob, size_t at) {
  uint32_t value = 0;
  if (at + 4 <= blob.size()) memcpy(&value, blob.data() + at, 4);
  return value;
}

// DXIL's shader kinds (DxilProgramHeader's high 16 bits).
static const char *const stages[] = {"ps", "vs", "gs", "hs", "ds", "cs", "lib", "raygen",
                                     "intersection", "anyhit", "closesthit", "miss", "callable", "ms", "as", "node"};

// Fills `line` and returns "", or returns why the file can't be read.
static std::string probe(const std::vector<char> &blob, std::string &line) {
  if (blob.size() < 32 || memcmp(blob.data(), "DXBC", 4)) return "not a DXBC container";
  size_t part = 0;
  for (uint32_t i = 0, parts = read32(blob, 28); i < parts; i++) {
    size_t at = read32(blob, 32 + 4 * i);
    if (at + 8 <= blob.size() && !memcmp(blob.data() + at, "DXIL", 4)) { part = at + 8; break; }
  }
  if (!part) return "no DXIL part (a DXBC shader)";
  // DxilProgramHeader: ProgramVersion, SizeInUint32, then DxilBitcodeHeader: "DXIL", DxilVersion, BitcodeOffset, BitcodeSize.
  if (part + 24 > blob.size() || memcmp(blob.data() + part + 8, "DXIL", 4)) return "bad DXIL program header";
  uint32_t program = read32(blob, part), version = read32(blob, part + 12);
  uint64_t start = part + 8 + uint64_t(read32(blob, part + 16)), size = read32(blob, part + 20);
  if (size < 4 || start + size > blob.size()) return "bitcode lies outside the DXIL part";

  llvm::LLVMContext context;
  auto module = llvm::parseBitcodeFile(
      llvm::MemoryBufferRef(llvm::StringRef(blob.data() + start, size), "dxil"), context);
  if (!module) return "llvm: " + llvm::toString(module.takeError());

  std::string entries;
  if (auto *points = (*module)->getNamedMetadata("dx.entryPoints"))
    for (auto *node : points->operands())
      if (node->getNumOperands() > 1)
        if (auto *name = llvm::dyn_cast_or_null<llvm::MDString>(node->getOperand(1).get()))
          entries += (entries.empty() ? "" : ",") + name->getString().str();
  std::map<std::string, int> calls;
  for (auto &function : **module)
    if (function.getName().startswith("dx.op."))
      for (auto *user : function.users())
        if (llvm::isa<llvm::CallInst>(user)) calls[function.getName().str().substr(6)]++;
  std::vector<std::pair<std::string, int>> top(calls.begin(), calls.end());
  std::sort(top.begin(), top.end(), [](auto &a, auto &b) { return a.second > b.second; });
  if (top.size() > 10) top.resize(10);
  std::string ops;
  for (auto &[name, count] : top) ops += (ops.empty() ? "" : ",") + name + ":" + std::to_string(count);

  unsigned kind = program >> 16;
  char head[128];
  snprintf(head, sizeof head, "dxil=%u.%u %s_%u_%u", version >> 8, version & 0xff,
           kind < sizeof stages / sizeof *stages ? stages[kind] : "unknown", (program >> 4) & 0xf, program & 0xf);
  line = std::string(head) + " entry=" + entries + " ops=" + ops;
  return "";
}

int main(int argc, char **argv) {
  int failures = 0;
  for (int i = 1; i < argc; i++) {
    std::ifstream in(argv[i], std::ios::binary);
    std::vector<char> blob;
    if (in.is_open()) blob.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
    std::string line, reason = in.is_open() ? probe(blob, line) : "can't read the file";
    if (reason.empty()) {
      printf("ok %s %s\n", argv[i], line.c_str());
    } else {
      printf("fail %s %s\n", argv[i], reason.c_str());
      failures++;
    }
  }
  return failures ? 1 : 0;
}
```

- [ ] **Step 9: Record the archive checksums**

Run: `sh dxmt/build.sh`
Expected: it downloads `wine.tar.gz` and stops with `dxmt: checksum mismatch for wine.tar.gz: expected , got <64 hex>`: the pin is still empty.

Put that `<64 hex>` into `WINE_SHA256=` in `dxmt/pins`, then run `sh dxmt/build.sh` again.
Expected: it stops the same way for `dxc.zip`. Put that sum into `DXC_SHA256=`.

- [ ] **Step 10: Add the Makefile target and run the build test**

In `Makefile`, add `dxmt` to `.PHONY` and add after the `presenter-check` target:

```make
# MacNeutron's DXMT fork with Direct3D 12 (docs/superpowers/specs/2026-09-28-macneutron-dxmt-fork-design.md).
# First run: about 500 MB of downloads and a 30-60 minute LLVM build; see dxmt/build.sh.
dxmt:
	sh dxmt/build.sh
```

Run: `sh dxmt/tests/build_test.sh`
Expected: 6 `ok` lines, exit 0.

- [ ] **Step 11: Build it (long; run in the background and wait)**

Run: `make dxmt > build/dxmt-make.log 2>&1` in the background, then read the log's tail when it finishes.
Expected: the last line is `dxmt: built …/build/dxmt (<FORK1>)`.

If LLVM 15 fails to compile with Apple clang 21, look in `build/dxmt-src/llvm.log` for the first error. A missing standard include or a clang diagnostic that newer compilers make an error gets the smallest fix: a `-DCMAKE_CXX_FLAGS=...` in `build.sh`'s cmake line. Ledger it as a ruling. Do the same for `win64.log` and `win32.log`.

- [ ] **Step 12: Check the staged output**

Run:
```bash
ls build/dxmt build/dxmt/x86_64-windows build/dxmt/i386-windows build/dxmt/x86_64-unix
cat build/dxmt/version
file build/dxmt/x86_64-unix/winemetal.so build/dxmt/dxil-probe
build/dxmt/dxil-probe build/dxmt/version; echo "exit $?"
```
Expected:
- `x86_64-windows` includes `d3d12.dll`, `i386-windows` doesn't;
- `version` is `<FORK1>`;
- both files are `Mach-O 64-bit … x86_64`;
- the probe prints `fail build/dxmt/version not a DXBC container`, then `exit 1`.

- [ ] **Step 13: Commit**

```bash
git add dxmt/pins dxmt/build.sh dxmt/tests/build_test.sh dxmt/tools/dxil-probe.cpp Makefile
git commit -m "dxmt: build our DXMT fork with Direct3D 12 (make dxmt)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Installing our DXMT (`DXMTInstaller`, runtime install, app start, `install-dxmt`)

**Files:**
- Create: `Sources/MacNeutronCore/DXMTInstaller.swift`, `Tests/MacNeutronCoreTests/DXMTInstallerTests.swift`
- Modify:
  - `Sources/MacNeutronCore/ToolLayout.swift` (after `presenterInstalled`);
  - `Sources/MacNeutronCore/RuntimeInstaller.swift` (`install`);
  - `Sources/MacNeutronCore/CommandLineTool.swift`;
  - `Sources/MacNeutronApp/AppModel.swift:73-74`;
  - `Tests/MacNeutronCoreTests/Support.swift`, `RuntimeInstallerTests.swift`, `CommandLineToolTests.swift`.

**Interfaces:**
- Consumes: Task 1's `build/dxmt` layout (`version`, `x86_64-windows/`, `i386-windows/`, `x86_64-unix/`).
- Produces:
  - `ToolLayout`: `dxmtVersionFile: URL` (`<root>/dxmt-version`), `dxmtVersion: String?`, `dxmtD3D12: URL` (`Libraries/DXMT/x64/d3d12.dll`), `dxmtHasD3D12: Bool`.
  - `DXMTBuild`: `init?(windows: URL, unix: URL)`, `init?(folder: URL)`, `static func bundled(near launcherBinary: URL) -> DXMTBuild?`, `version: String`.
  - `DXMTInstaller.install(layout:from:) throws`, and `@discardableResult DXMTInstaller.installBundled(layout:launcherBinary:) throws -> Bool`.
  - `DXMTInstallError.notABuild(String)` and `.noRuntime(String)`.
  - CLI `macneutron install-dxmt [--tool-dir <dir>] <folder>`.
  - Test helper `makeDXMTBuild(in:unixFolder:version:omitting:) throws -> DXMTBuild`.

- [ ] **Step 1: Add the test helper**

Append to `Tests/MacNeutronCoreTests/Support.swift`:

```swift
/// A fake `make dxmt` output. Both halves go in `folder`, or the Mac half goes in `unixFolder`, as in MacNeutron.app.
/// `omitting` ("x86_64-windows/dxgi.dll") leaves one file out.
@discardableResult
func makeDXMTBuild(in folder: URL, unixFolder: URL? = nil, version: String = "abc123",
                   omitting: String? = nil) throws -> DXMTBuild {
    try write(version + "\n", to: folder.appending(path: "version"))
    for (arch, dlls) in [("x86_64-windows", ["winemetal.dll", "d3d11.dll", "d3d10core.dll", "dxgi.dll", "d3d12.dll"]),
                         ("i386-windows", ["winemetal.dll", "d3d11.dll", "d3d10core.dll", "dxgi.dll"])] {
        for dll in dlls where "\(arch)/\(dll)" != omitting {
            try write("ours \(arch) \(dll)", to: folder.appending(path: "\(arch)/\(dll)"))
        }
    }
    let unix = unixFolder ?? folder
    try write("ours winemetal.so", to: unix.appending(path: "x86_64-unix/winemetal.so"))
    guard let build = DXMTBuild(windows: folder, unix: unix) else { throw CocoaError(.fileNoSuchFile) }
    return build
}
```

- [ ] **Step 2: Write the failing installer tests**

Create `Tests/MacNeutronCoreTests/DXMTInstallerTests.swift`:

```swift
import Foundation
import Testing
@testable import MacNeutronCore

private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

@Test func installsBothHalvesAndTheFrontEnds() throws {
    let layout = try makeToolLayout()
    try DXMTInstaller.install(layout: layout, from: try makeDXMTBuild(in: try makeTempDir()))
    let wine = layout.wineLib.appending(path: "wine")
    #expect(try read(wine.appending(path: "x86_64-unix/winemetal.so")) == "ours winemetal.so")
    #expect(try read(wine.appending(path: "x86_64-windows/winemetal.dll")) == "ours x86_64-windows winemetal.dll")
    #expect(try read(wine.appending(path: "i386-windows/winemetal.dll")) == "ours i386-windows winemetal.dll")
    #expect(try read(layout.dxmt.appending(path: "x64/d3d12.dll")) == "ours x86_64-windows d3d12.dll")
    #expect(try read(layout.dxmt.appending(path: "x64/d3d11.dll")) == "ours x86_64-windows d3d11.dll")
    #expect(try read(layout.dxmt.appending(path: "x32/dxgi.dll")) == "ours i386-windows dxgi.dll")
    #expect(!exists(layout.dxmt.appending(path: "x32/d3d12.dll")))
    #expect(layout.dxmtVersion == "abc123")
    #expect(layout.dxmtHasD3D12)
}

@Test func dxmtPathsInTheToolFolder() {
    let layout = ToolLayout(root: URL(filePath: "/t/", directoryHint: .isDirectory))
    #expect(layout.dxmtVersionFile.path(percentEncoded: false) == "/t/dxmt-version")
    #expect(layout.dxmtD3D12.path(percentEncoded: false) == "/t/Libraries/DXMT/x64/d3d12.dll")
    #expect(!layout.dxmtHasD3D12)
    #expect(layout.dxmtVersion == nil)
}

@Test func aFailedInstallLeavesNoVersionSoTheNextStartRetries() throws {
    let layout = try makeToolLayout()
    try write("old", to: layout.dxmtVersionFile)
    let build = try makeDXMTBuild(in: try makeTempDir(), omitting: "x86_64-windows/dxgi.dll")
    #expect(throws: (any Error).self) { try DXMTInstaller.install(layout: layout, from: build) }
    #expect(layout.dxmtVersion == nil)
}

@Test func refusesAToolFolderWithoutARuntime() throws {
    let layout = ToolLayout(root: try makeTempDir().appending(path: "macneutron", directoryHint: .isDirectory))
    let build = try makeDXMTBuild(in: try makeTempDir())
    #expect(throws: DXMTInstallError.noRuntime(layout.root.path(percentEncoded: false))) {
        try DXMTInstaller.install(layout: layout, from: build)
    }
    #expect(!exists(layout.libraries))
}

@Test func findsTheBuildNextToTheLauncher() throws {
    let helpers = try makeTempDir()
    try makeDXMTBuild(in: helpers.appending(path: "DXMT", directoryHint: .isDirectory))
    let build = try #require(DXMTBuild.bundled(near: helpers.appending(path: "macneutron")))
    #expect(build.version == "abc123")
}

@Test func findsTheAppBundlesTwoHalves() throws {
    let contents = try makeTempDir().appending(path: "MacNeutron.app/Contents", directoryHint: .isDirectory)
    try makeDXMTBuild(in: contents.appending(path: "Resources/DXMT", directoryHint: .isDirectory),
                      unixFolder: contents.appending(path: "Frameworks/DXMT", directoryHint: .isDirectory))
    let build = try #require(DXMTBuild.bundled(near: contents.appending(path: "Helpers/macneutron")))
    #expect(build.windows.deletingLastPathComponent().lastPathComponent == "Resources")
    #expect(build.unix.deletingLastPathComponent().lastPathComponent == "Frameworks")
}

@Test func noBuildNearTheLauncherInstallsNothing() throws {
    let layout = try makeToolLayout()
    #expect(try DXMTInstaller.installBundled(layout: layout, launcherBinary: try makeTempDir().appending(path: "macneutron")) == false)
    #expect(layout.dxmtVersion == nil)
}

@Test func theBundledBuildIsInstalledOncePerVersion() throws {
    let layout = try makeToolLayout()
    let helpers = try makeTempDir()
    let launcher = helpers.appending(path: "macneutron")
    try makeDXMTBuild(in: helpers.appending(path: "DXMT", directoryHint: .isDirectory), version: "v1")
    #expect(try DXMTInstaller.installBundled(layout: layout, launcherBinary: launcher))
    #expect(try DXMTInstaller.installBundled(layout: layout, launcherBinary: launcher) == false)
    try makeDXMTBuild(in: helpers.appending(path: "DXMT", directoryHint: .isDirectory), version: "v2")
    #expect(try DXMTInstaller.installBundled(layout: layout, launcherBinary: launcher))
    #expect(layout.dxmtVersion == "v2")
}
```

Append to `Tests/MacNeutronCoreTests/RuntimeInstallerTests.swift`:

```swift
@Test func reinstallAppliesTheBundledDXMTAfterGPTK() throws {
    let (tarball, pin) = try makeRuntimeTarball()
    let layout = try makeToolLayout()
    // Stands in for any GPTK file at the same path: our DXMT is applied last (spec §5).
    try write("apple winemetal", to: layout.gptkStore.appending(path: "lib/wine/x86_64-windows/winemetal.dll"))
    let launcher = try makeEchoLauncher()
    try makeDXMTBuild(in: launcher.deletingLastPathComponent().appending(path: "DXMT", directoryHint: .isDirectory))
    try RuntimeInstaller.install(tarball: tarball, pin: pin, layout: layout, launcherBinary: launcher)
    #expect(layout.dxmtVersion == "abc123")
    #expect(try String(contentsOf: layout.wineLib.appending(path: "wine/x86_64-windows/winemetal.dll"), encoding: .utf8)
        == "ours x86_64-windows winemetal.dll")
}

@Test func reinstallWithoutABundledDXMTForgetsTheOldOne() throws {
    // The fresh runtime brings DXMT 0.80 back; dxmt-version must not keep claiming ours.
    let (tarball, pin) = try makeRuntimeTarball()
    let layout = try makeToolLayout()
    try write("abc123", to: layout.dxmtVersionFile)
    try RuntimeInstaller.install(tarball: tarball, pin: pin, layout: layout, launcherBinary: try makeEchoLauncher())
    #expect(layout.dxmtVersion == nil)
}
```

Append to `Tests/MacNeutronCoreTests/CommandLineToolTests.swift`:

```swift
@Test func installDXMTRejectsAFolderThatIsNotABuild() async throws {
    let status = await CommandLineTool.run(
        ["install-dxmt", "--tool-dir", try makeToolLayout().root.path(percentEncoded: false), try makeTempDir().path(percentEncoded: false)],
        environment: [:], executable: URL(filePath: "/x"))
    #expect(status == 1)
}

@Test func installDXMTInstallsABuild() async throws {
    let layout = try makeToolLayout()
    let folder = try makeTempDir()
    try makeDXMTBuild(in: folder)
    let status = await CommandLineTool.run(
        ["install-dxmt", "--tool-dir", layout.root.path(percentEncoded: false), folder.path(percentEncoded: false)],
        environment: [:], executable: URL(filePath: "/x"))
    #expect(status == 0)
    #expect(layout.dxmtVersion == "abc123")
}
```

- [ ] **Step 3: Run them to make sure they fail**

Run: `swift test 2>&1 | grep -E "error:|✘|Test run with" | head -20`
Expected: compile errors: `cannot find 'DXMTBuild' in scope`, `value of type 'ToolLayout' has no member 'dxmtVersionFile'`.

- [ ] **Step 4: Add the tool-folder paths**

In `Sources/MacNeutronCore/ToolLayout.swift`, after the `presenterInstalled` line:

```swift

    /// The fork commit of MacNeutron's DXMT, installed over the runtime's; nil while the runtime's DXMT 0.80 is in place.
    public var dxmtVersionFile: URL { root.appending(path: "dxmt-version") }
    public var dxmtVersion: String? {
        (try? String(contentsOf: dxmtVersionFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Our DXMT's Direct3D 12 front end; the runtime's DXMT 0.80 has none.
    public var dxmtD3D12: URL { dxmt.appending(path: "x64/d3d12.dll") }
    public var dxmtHasD3D12: Bool { FileManager.default.fileExists(atPath: dxmtD3D12.path(percentEncoded: false)) }
```

- [ ] **Step 5: Write `DXMTInstaller.swift`**

Create `Sources/MacNeutronCore/DXMTInstaller.swift`:

```swift
import Foundation

public enum DXMTInstallError: Error, Equatable, CustomStringConvertible {
    case notABuild(String)
    case noRuntime(String)

    public var description: String {
        switch self {
        case .notABuild(let path): "\(path) is not a DXMT build (`make dxmt` creates build/dxmt)"
        case .noRuntime(let path): "no Wine runtime in \(path); install the runtime first"
        }
    }
}

/// MacNeutron's DXMT build (DXMT fork spec §5): a Windows half (`x86_64-windows`, `i386-windows`, `version`) and a
/// Mac half (`x86_64-unix`). `make dxmt` puts both in `build/dxmt`. MacNeutron.app keeps the Windows half in
/// Contents/Resources/DXMT and the Mac half, which is signed code, in Contents/Frameworks/DXMT.
public struct DXMTBuild: Equatable, Sendable {
    public let windows: URL
    public let unix: URL

    public init?(windows: URL, unix: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: windows.appending(path: "version").path(percentEncoded: false)),
              fm.fileExists(atPath: unix.appending(path: "x86_64-unix/winemetal.so").path(percentEncoded: false))
        else { return nil }
        self.windows = windows
        self.unix = unix
    }

    /// Both halves in one folder, like `build/dxmt`.
    public init?(folder: URL) { self.init(windows: folder, unix: folder) }

    /// `DXMT/` next to the launcher, or MacNeutron.app's Resources/DXMT and Frameworks/DXMT.
    public static func bundled(near launcherBinary: URL) -> DXMTBuild? {
        let helpers = launcherBinary.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        return DXMTBuild(folder: helpers.appending(path: "DXMT", directoryHint: .isDirectory))
            ?? DXMTBuild(windows: contents.appending(path: "Resources/DXMT", directoryHint: .isDirectory),
                         unix: contents.appending(path: "Frameworks/DXMT", directoryHint: .isDirectory))
    }

    /// The fork commit it was built from.
    public var version: String {
        ((try? String(contentsOf: windows.appending(path: "version"), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Installs MacNeutron's DXMT over the runtime's DXMT 0.80.
public enum DXMTInstaller {
    /// Front ends that go into `Libraries/DXMT/<dir>`, where prefixes get them. Direct3D 12 is 64-bit only.
    static let frontEnds: [(arch: String, dir: String, dlls: [String])] = [
        ("x86_64-windows", "x64", ["d3d11.dll", "d3d10core.dll", "dxgi.dll", "d3d12.dll"]),
        ("i386-windows", "x32", ["d3d11.dll", "d3d10core.dll", "dxgi.dll"]),
    ]

    /// Installs, in order:
    /// - the Mac half into Wine's `x86_64-unix`;
    /// - `winemetal.dll` into Wine's PE folders;
    /// - the front ends into `Libraries/DXMT`;
    /// - `dxmt-version`.
    /// `dxmt-version` is removed first and written last, so an install that fails part-way is retried at the next app
    /// start instead of leaving mismatched halves that look current.
    public static func install(layout: ToolLayout, from build: DXMTBuild) throws {
        guard layout.runtimeVersion != nil else { throw DXMTInstallError.noRuntime(layout.root.path(percentEncoded: false)) }
        let fm = FileManager.default
        try? fm.removeItem(at: layout.dxmtVersionFile)
        let wine = layout.wineLib.appending(path: "wine", directoryHint: .isDirectory)
        let unix = build.unix.appending(path: "x86_64-unix", directoryHint: .isDirectory)
        for file in try fm.contentsOfDirectory(at: unix, includingPropertiesForKeys: nil) {
            try RuntimeInstaller.installFile(file, at: wine.appending(path: "x86_64-unix/\(file.lastPathComponent)"))
        }
        for (arch, dir, dlls) in frontEnds {
            let from = build.windows.appending(path: arch, directoryHint: .isDirectory)
            try RuntimeInstaller.installFile(from.appending(path: "winemetal.dll"),
                                             at: wine.appending(path: "\(arch)/winemetal.dll"))
            for dll in dlls {
                try RuntimeInstaller.installFile(from.appending(path: dll), at: layout.dxmt.appending(path: "\(dir)/\(dll)"))
            }
        }
        try build.version.write(to: layout.dxmtVersionFile, atomically: true, encoding: .utf8)
    }

    /// Installs the DXMT that ships with this launcher when the tool folder has a different one, or the runtime's own.
    @discardableResult
    public static func installBundled(layout: ToolLayout, launcherBinary: URL) throws -> Bool {
        guard let build = DXMTBuild.bundled(near: launcherBinary), build.version != layout.dxmtVersion else { return false }
        try install(layout: layout, from: build)
        return true
    }
}
```

- [ ] **Step 6: Apply it on runtime install**

In `Sources/MacNeutronCore/RuntimeInstaller.swift`, `install(tarball:pin:layout:launcherBinary:runner:)`:
- Change its doc comment's last line to: `/// Re-applies an imported GPTK, then MacNeutron's DXMT when one ships with the launcher, since the new Wine tree has neither.`
- After `try fm.moveItem(at: extracted.libraries, to: layout.libraries)`, add:
  ```swift
          try? fm.removeItem(at: layout.dxmtVersionFile)  // the new runtime brings its own DXMT 0.80
  ```
- After the GPTK `if` block at the end of the function, add:
  ```swift
          try DXMTInstaller.installBundled(layout: layout, launcherBinary: launcherBinary)
  ```

- [ ] **Step 7: Add `install-dxmt` to the CLI**

In `Sources/MacNeutronCore/CommandLineTool.swift`, append to `usage`:
```
               macneutron install-dxmt [--tool-dir <dir>] <build/dxmt>
```
and add before `default:`:

```swift
        case "install-dxmt":
            let layout = toolLayout(option("--tool-dir", in: &rest))
            guard rest.count == 1 else { return usageError() }
            do {
                guard let build = DXMTBuild(folder: URL(filePath: rest[0], directoryHint: .isDirectory)) else {
                    throw DXMTInstallError.notABuild(rest[0])
                }
                try DXMTInstaller.install(layout: layout, from: build)
                print("Installed DXMT \(build.version) into \(layout.root.path(percentEncoded: false))")
                return 0
            } catch {
                return failure(error)
            }
```

- [ ] **Step 8: Install the bundled DXMT at app start**

In `Sources/MacNeutronApp/AppModel.swift`, replace:
```swift
        // An updated app brings a new launcher and steam.exe: install them without a runtime reinstall.
        if layout.runtimeVersion != nil { try? RuntimeInstaller.writeToolFiles(layout: layout, launcherBinary: helper) }
```
with:
```swift
        // An updated app brings a new launcher, steam.exe and DXMT: install them without a runtime reinstall.
        if layout.runtimeVersion != nil {
            try? RuntimeInstaller.writeToolFiles(layout: layout, launcherBinary: helper)
            _ = try? DXMTInstaller.installBundled(layout: layout, launcherBinary: helper)
        }
```

- [ ] **Step 9: Run the tests to make sure they pass**

Run: `swift build 2>&1 | grep -E "error|warning: .*DXMT" ; swift test 2>&1 | grep -E "✘|Test run with"`
Expected: no errors, and `Test run with <N> tests passed`, with no `✘`.

- [ ] **Step 10: Commit**

```bash
git add Sources/MacNeutronCore/DXMTInstaller.swift Sources/MacNeutronCore/ToolLayout.swift \
  Sources/MacNeutronCore/RuntimeInstaller.swift Sources/MacNeutronCore/CommandLineTool.swift \
  Sources/MacNeutronApp/AppModel.swift Tests/MacNeutronCoreTests/DXMTInstallerTests.swift \
  Tests/MacNeutronCoreTests/Support.swift Tests/MacNeutronCoreTests/RuntimeInstallerTests.swift \
  Tests/MacNeutronCoreTests/CommandLineToolTests.swift
git commit -m "feat(dxmt): install our DXMT over the runtime's (runtime install, app start, install-dxmt)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: DXMT as the default backend, with Direct3D 12

**Files:**
- Modify:
  - `Sources/MacNeutronCore/GraphicsBackend.swift`;
  - `Sources/MacNeutronCore/LaunchEnvironment.swift:6-10`;
  - `Sources/MacNeutronCore/Launcher.swift:51`;
  - `Sources/MacNeutronApp/GamesView.swift:40`;
  - `Sources/MacNeutronApp/SetupView.swift:24`.
- Test: `Tests/MacNeutronCoreTests/GraphicsBackendTests.swift`, `LaunchEnvironmentTests.swift`, `PrefixManagerTests.swift`, `LauncherTests.swift`

**Interfaces:**
- Consumes: `ToolLayout.dxmtD3D12`, `ToolLayout.dxmtHasD3D12` (Task 2).
- Produces:
  - `GraphicsBackend.dllOverrides(layout: ToolLayout) -> String` (replaces the `dllOverrides` property);
  - `LaunchEnvironment.build(base:context:backend:layout:logging:)`.

- [ ] **Step 1: Write the failing tests**

In `Tests/MacNeutronCoreTests/GraphicsBackendTests.swift`:
- Replace `defaultsToD3DMetalWhenGPTKIsImported` with:

```swift
@Test func defaultsToDXMTEvenWithGPTK() {
    let choice = GraphicsBackend.select(requested: nil, gptkImported: true)
    #expect(choice.backend == .dxmt)
    #expect(choice.note == nil)
}

@Test func unknownRequestWithGPTKFallsBackToDXMT() {
    let choice = GraphicsBackend.select(requested: "vulkan", gptkImported: true)
    #expect(choice.backend == .dxmt)
    #expect(choice.note == "unknown MACNEUTRON_GRAPHICS 'vulkan', using dxmt")
}

@Test func d3dmetalStaysSelectableWithGPTK() {
    let choice = GraphicsBackend.select(requested: "d3dmetal", gptkImported: true)
    #expect(choice.backend == .d3dmetal)
    #expect(choice.note == nil)
}

/// A tool folder whose DXMT has, or lacks, our d3d12.dll.
private func dxmtLayout(d3d12: Bool) throws -> ToolLayout {
    let layout = ToolLayout(root: try makeTempDir())
    if d3d12 { try write("ours", to: layout.dxmtD3D12) }
    return layout
}

@Test func dxmtTakesD3D12OnlyWithOurD3D12() throws {
    // Without ours, a d3d12.dll an earlier DXMT left in the prefix must never load.
    #expect(GraphicsBackend.dxmt.dllOverrides(layout: try dxmtLayout(d3d12: false)) == "dxgi,d3d10core,d3d11=n,b;d3d9,d3d10,d3d12=b")
    #expect(GraphicsBackend.dxmt.dllOverrides(layout: try dxmtLayout(d3d12: true)) == "dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b")
    #expect(GraphicsBackend.d3dmetal.dllOverrides(layout: try dxmtLayout(d3d12: true)) == "dxgi,d3d9,d3d10,d3d10core,d3d11,d3d12=b")
}

@Test func dxmtDeploysOurD3D12To64BitOnly() throws {
    let layout = try dxmtLayout(d3d12: true)
    let dlls = GraphicsBackend.dxmt.prefixDLLs(layout: layout)
    #expect(dlls.count == 7)
    #expect(dlls.contains { $0.source == layout.dxmtD3D12 && $0.destination == "drive_c/windows/system32/d3d12.dll" })
    #expect(!dlls.contains { $0.destination == "drive_c/windows/syswow64/d3d12.dll" })
    #expect(!GraphicsBackend.dxvk.prefixDLLs(layout: layout).contains { $0.source.lastPathComponent == "d3d12.dll" })
}
```

- In `everyBackendOverridesTheSameDLLSet`, wrap the loop so that it runs for both layouts, and read the overrides through the new call:

```swift
@Test func everyBackendOverridesTheSameDLLSet() throws {
    let managed: Set = ["dxgi", "d3d9", "d3d10", "d3d10core", "d3d11", "d3d12"]
    for layout in [try dxmtLayout(d3d12: false), try dxmtLayout(d3d12: true)] {
        for backend in GraphicsBackend.allCases {
            let names = backend.dllOverrides(layout: layout).split(separator: ";").flatMap {
                $0.split(separator: "=")[0].split(separator: ",").map(String.init)
            }
            #expect(Set(names) == managed, "\(backend)")
            #expect(names.count == managed.count, "\(backend) repeats a DLL")
        }
    }
}
```

- In `dxvkUsesWinesDXGIAndOnlyTheDLLsTheRuntimeShips`, move the `let layout = …` line above the first `#expect`, and change it to `#expect(GraphicsBackend.dxvk.dllOverrides(layout: layout) == …)`.

In `Tests/MacNeutronCoreTests/LaunchEnvironmentTests.swift`, add below `context`:
```swift
private let layout = ToolLayout(root: URL(filePath: "/nonexistent/", directoryHint: .isDirectory))
```
Add `layout: layout,` after `backend: .dxmt,` in all four `LaunchEnvironment.build` calls, and append:

```swift
@Test func userOverridesWinOverOurD3D12() throws {
    let layout = ToolLayout(root: try makeTempDir())
    try write("ours", to: layout.dxmtD3D12)
    let env = LaunchEnvironment.build(base: ["WINEDLLOVERRIDES": "d3d12=b"], context: context, backend: .dxmt,
                                      layout: layout, logging: false)
    #expect(env["WINEDLLOVERRIDES"] == "dxgi=n,b;d3d10core=n,b;d3d11=n,b;d3d12=b;d3d9=b;d3d10=b")
}
```

In `Tests/MacNeutronCoreTests/PrefixManagerTests.swift`:
- In `makeManager`, pass `layout: layout` to `LaunchEnvironment.build`.
- Append:

```swift
@Test func dxmtDeploysOurD3D12WhenInstalled() throws {
    let (manager, env) = try makeManager(winebootCreatingPrefix())
    try write("ours x64 d3d12.dll", to: manager.layout.dxmtD3D12)
    try manager.prepare(backend: .dxmt, environment: env)
    let d3d12 = manager.context.prefix.appending(path: "drive_c/windows/system32/d3d12.dll")
    #expect(try String(contentsOf: d3d12, encoding: .utf8) == "ours x64 d3d12.dll")
}
```

Append to `Tests/MacNeutronCoreTests/LauncherTests.swift`:

```swift
@Test func defaultBackendIsDXMTEvenWithGPTKImported() throws {
    let f = try makeFixture()
    try write(#"{"version": "4.0b2"}"#, to: f.launcher.layout.gptkManifest)
    #expect(f.launcher.launch(["run", "/g/Game.exe"], environment: f.env) == 0)
    #expect(f.launcherLog.contains("backend=dxmt"))
    #expect(f.launcherLog.contains("gptk=4.0b2"))
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `swift test 2>&1 | grep -E "error:|✘|Test run with" | head -20`
Expected: compile errors: `value of type 'GraphicsBackend' has no member 'dllOverrides(layout:)'` / `extra argument 'layout' in call`.

- [ ] **Step 3: Implement**

In `Sources/MacNeutronCore/GraphicsBackend.swift`:
- `select`: change the doc comment's first line to `/// Honors `MACNEUTRON_GRAPHICS` when valid; otherwise DXMT, MacNeutron's default for every game.`
- `select`: replace `let fallback: GraphicsBackend = gptkImported ? .d3dmetal : .dxmt` with `let fallback = GraphicsBackend.dxmt`.
- Replace the `dllOverrides` property with:

```swift
    /// `WINEDLLOVERRIDES` for this backend. Every backend names every D3D DLL any backend
    /// manages, so DLLs a previous backend left in the prefix can never leak into this launch.
    /// DXMT takes Direct3D 12 only when our DXMT's d3d12.dll is installed; otherwise Wine's builtin keeps it, so a
    /// d3d12.dll an earlier DXMT left in the prefix never loads beside a different winemetal.
    public func dllOverrides(layout: ToolLayout) -> String {
        switch self {
        case .d3dmetal: "dxgi,d3d9,d3d10,d3d10core,d3d11,d3d12=b"
        case .dxmt: layout.dxmtHasD3D12 ? "dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b"
                                        : "dxgi,d3d10core,d3d11=n,b;d3d9,d3d10,d3d12=b"
        // The pinned DXVK-macOS ships d3d10core/d3d11 only and runs on Wine's own dxgi.
        case .dxvk: "d3d10core,d3d11=n,b;dxgi,d3d9,d3d10,d3d12=b"
        }
    }
```

- In `prefixDLLs(layout:)`, replace the final `return names.flatMap { … }` with:

```swift
        let dlls = names.flatMap { name in
            [
                (dir.appending(path: "x64/\(name)"), "drive_c/windows/system32/\(name)"),
                (dir.appending(path: "x32/\(name)"), "drive_c/windows/syswow64/\(name)"),
            ]
        }
        // Our DXMT's Direct3D 12 is 64-bit only.
        guard self == .dxmt, layout.dxmtHasD3D12 else { return dlls }
        return dlls + [(layout.dxmtD3D12, "drive_c/windows/system32/d3d12.dll")]
```

In `Sources/MacNeutronCore/LaunchEnvironment.swift`, change the signature to `build(base: [String: String], context: CompatContext, backend: GraphicsBackend, layout: ToolLayout, logging: Bool)` and the overrides line to `env["WINEDLLOVERRIDES"] = mergeOverrides(backend.dllOverrides(layout: layout), user: base["WINEDLLOVERRIDES"])`.

In `Sources/MacNeutronCore/Launcher.swift:51`: `var env = LaunchEnvironment.build(base: environment, context: context, backend: backend, layout: layout, logging: logging)`.

In `Sources/MacNeutronApp/GamesView.swift:40`: `Text("Default (DXMT)").tag("")`.

In `Sources/MacNeutronApp/SetupView.swift:24`, replace `"Drop Apple's Game_Porting_Toolkit .dmg here, or choose it. Without it, games use DXMT."` with `"Drop Apple's Game_Porting_Toolkit .dmg here, or choose it. Games use DXMT; GPTK adds D3DMetal, which modern Direct3D 12 games need for now (set it per game in the Games window)."`.

- [ ] **Step 4: Run the tests to make sure they pass**

Run: `swift build 2>&1 | grep -E "error" ; swift test 2>&1 | grep -E "✘|Test run with"`
Expected: no errors; `Test run with <N> tests passed`, no `✘`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacNeutronCore/GraphicsBackend.swift Sources/MacNeutronCore/LaunchEnvironment.swift \
  Sources/MacNeutronCore/Launcher.swift Sources/MacNeutronApp/GamesView.swift Sources/MacNeutronApp/SetupView.swift \
  Tests/MacNeutronCoreTests/GraphicsBackendTests.swift Tests/MacNeutronCoreTests/LaunchEnvironmentTests.swift \
  Tests/MacNeutronCoreTests/PrefixManagerTests.swift Tests/MacNeutronCoreTests/LauncherTests.swift
git commit -m "feat(graphics): DXMT is the default for every game; it takes D3D12 when ours is installed

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: D3D12 test programs, test shaders and `make dxmt-check`

**Files:**
- Create:
  - `dxmt/tests/d3d12_clear.cpp`, `dxmt/tests/d3d12_dxil.cpp`;
  - `dxmt/tests/shaders/triangle.hlsl`, `compute.hlsl`, `compile.sh`;
  - `dxmt/tests/shaders/triangle.vs.dxil`, `triangle.ps.dxil`, `compute.cs.dxil` (generated);
  - `dxmt/check.sh`, `docs/testing/acceptance-dxmt-fork.md`.
- Modify: `Makefile`

**Interfaces:**
- Consumes:
  - `build/dxmt` and `build/dxmt-src/dxc/bin/x64/dxc.exe` (Task 1);
  - `macneutron install-dxmt` (Task 2);
  - the `dxmt` backend with D3D12 (Task 3);
  - `build/presenter/present_loop.exe` (`make presenter`), args `<client_w> <client_h> <swap_w|0> <swap_h|0> <frames> <vsync>`, printing `avg frame <ms> ms`.
- Produces:
  - `build/dxmt-tests/d3d12_clear.exe [frames]`, printing:
    - `adapter <name>`;
    - `shader model 0x<hex> (hr 0x<8 hex>)`;
    - `resource binding tier <n>`;
    - `presented <n>/<n> frames, avg frame <ms> ms`.
  - `build/dxmt-tests/d3d12_dxil.exe <vs> <ps> <cs>`, printing `graphics hr=0x<8 hex>` and `compute hr=0x<8 hex>`.
  - `make dxmt-tests` and `make dxmt-check`.
  - `dxmt/check.sh`'s helper `run <tool: stock|ours> <name> <backend> <exe> [args...]` → `$WORK/<name>.txt`, which Task 5 extends.

- [ ] **Step 1: Write the test shaders and compile them with DXC**

`dxmt/tests/shaders/triangle.hlsl`:
```hlsl
// A triangle from SV_VertexID: the smallest vertex/pixel pair for DXIL pipeline tests.
struct VSOut { float4 pos : SV_Position; float3 color : COLOR; };

VSOut vsmain(uint id : SV_VertexID) {
    VSOut o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    o.color = float3(uv, 1 - uv.x);
    return o;
}

float4 psmain(VSOut i) : SV_Target { return float4(i.color, 1); }
```

`dxmt/tests/shaders/compute.hlsl`:
```hlsl
// Doubles a buffer in place: the smallest compute shader for DXIL pipeline tests.
RWStructuredBuffer<float> data : register(u0);

[numthreads(64, 1, 1)]
void csmain(uint3 id : SV_DispatchThreadID) { data[id.x] *= 2; }
```

`dxmt/tests/shaders/compile.sh`:
```sh
#!/bin/sh
# Compiles the test shaders to DXIL with Microsoft's dxc.exe under the installed runtime's Wine (DXMT fork spec §6).
# Needs `make dxmt`, which fetches DXC. The .dxil files are committed; rerun this after editing a shader.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
TOOL="${MACNEUTRON_TOOL:-$HOME/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron}"
DXC="$ROOT/build/dxmt-src/dxc/bin/x64/dxc.exe"
export WINEPREFIX="${TMPDIR:-/tmp}/macneutron dxc" WINEDEBUG=-all
cd "$HERE"  # relative paths: dxc.exe would read a leading / as an option
dxc() { "$TOOL/Libraries/Wine/bin/wine" "$DXC" "$@"; }
dxc -T vs_6_0 -E vsmain -Fo triangle.vs.dxil triangle.hlsl
dxc -T ps_6_0 -E psmain -Fo triangle.ps.dxil triangle.hlsl
dxc -T cs_6_0 -E csmain -Fo compute.cs.dxil compute.hlsl
ls -l ./*.dxil
```

Run: `sh dxmt/tests/shaders/compile.sh && build/dxmt/dxil-probe dxmt/tests/shaders/*.dxil`
Expected:
- three `.dxil` files of a few KB each;
- three probe lines, each `ok …` or `fail …`, not graded yet. Record them for Task 7.
- For the ok lines, `vs_6_0` has `entry=vsmain`, `ps_6_0` has `entry=psmain`, and `cs_6_0` has `entry=csmain`.

- [ ] **Step 2: Write `d3d12_clear.cpp`**

```cpp
// Clears and presents N frames through Direct3D 12 (DXMT fork spec §6):
//   d3d12_clear.exe [frames]
// Prints the adapter, the highest shader model, the resource binding tier and the average frame time.
#define WIDL_EXPLICIT_AGGREGATE_RETURNS  // D3D12 methods that return structs: the MSVC ABI under mingw
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <cstdio>
#include <cstdlib>

#define CHECK(expr) do { HRESULT hr_ = (expr); if (FAILED(hr_)) { \
    printf("%s failed 0x%08lx\n", #expr, (unsigned long)hr_); return 1; } } while (0)

static LRESULT CALLBACK proc(HWND h, UINT m, WPARAM w, LPARAM l) { return DefWindowProcA(h, m, w, l); }

int main(int argc, char **argv) {
    const int frames = argc > 1 ? atoi(argv[1]) : 300;
    const UINT width = 1280, height = 720, count = 2;
    WNDCLASSA wc = {};
    wc.lpfnWndProc = proc; wc.hInstance = GetModuleHandleA(nullptr); wc.lpszClassName = "d3d12_clear";
    RegisterClassA(&wc);
    RECT r = {0, 0, (LONG)width, (LONG)height};
    AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, FALSE);
    HWND hwnd = CreateWindowA("d3d12_clear", "d3d12_clear", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 40, 40,
                              r.right - r.left, r.bottom - r.top, nullptr, nullptr, wc.hInstance, nullptr);

    IDXGIFactory4 *factory; IDXGIAdapter1 *adapter; DXGI_ADAPTER_DESC1 ad; ID3D12Device *device;
    CHECK(CreateDXGIFactory1(__uuidof(IDXGIFactory4), (void **)&factory));
    CHECK(factory->EnumAdapters1(0, &adapter));
    CHECK(adapter->GetDesc1(&ad));
    CHECK(D3D12CreateDevice(adapter, D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device), (void **)&device));
    D3D12_FEATURE_DATA_SHADER_MODEL sm = {D3D_SHADER_MODEL_6_0};
    HRESULT smhr = device->CheckFeatureSupport(D3D12_FEATURE_SHADER_MODEL, &sm, sizeof sm);
    D3D12_FEATURE_DATA_D3D12_OPTIONS options = {};
    device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS, &options, sizeof options);
    printf("adapter %ls\nshader model 0x%x (hr 0x%08lx)\nresource binding tier %d\n",
           ad.Description, (unsigned)sm.HighestShaderModel, (unsigned long)smhr, (int)options.ResourceBindingTier);

    ID3D12CommandQueue *queue;
    D3D12_COMMAND_QUEUE_DESC qd = {D3D12_COMMAND_LIST_TYPE_DIRECT};
    CHECK(device->CreateCommandQueue(&qd, __uuidof(ID3D12CommandQueue), (void **)&queue));
    DXGI_SWAP_CHAIN_DESC1 sd = {};
    sd.Width = width; sd.Height = height; sd.Format = DXGI_FORMAT_R8G8B8A8_UNORM; sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; sd.BufferCount = count; sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    IDXGISwapChain1 *swap1; IDXGISwapChain3 *swap;
    CHECK(factory->CreateSwapChainForHwnd(queue, hwnd, &sd, nullptr, nullptr, &swap1));
    CHECK(swap1->QueryInterface(__uuidof(IDXGISwapChain3), (void **)&swap));

    ID3D12DescriptorHeap *heap;
    D3D12_DESCRIPTOR_HEAP_DESC hd = {D3D12_DESCRIPTOR_HEAP_TYPE_RTV, count};
    CHECK(device->CreateDescriptorHeap(&hd, __uuidof(ID3D12DescriptorHeap), (void **)&heap));
    const UINT stride = device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    ID3D12Resource *buffers[count]; D3D12_CPU_DESCRIPTOR_HANDLE rtv[count];
    for (UINT i = 0; i < count; i++) {
        CHECK(swap->GetBuffer(i, __uuidof(ID3D12Resource), (void **)&buffers[i]));
        rtv[i] = heap->GetCPUDescriptorHandleForHeapStart();
        rtv[i].ptr += i * stride;
        device->CreateRenderTargetView(buffers[i], nullptr, rtv[i]);
    }
    ID3D12CommandAllocator *allocator; ID3D12GraphicsCommandList *list; ID3D12Fence *fence;
    CHECK(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, __uuidof(ID3D12CommandAllocator), (void **)&allocator));
    CHECK(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator, nullptr,
                                    __uuidof(ID3D12GraphicsCommandList), (void **)&list));
    CHECK(list->Close());
    CHECK(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, __uuidof(ID3D12Fence), (void **)&fence));
    HANDLE done = CreateEventA(nullptr, FALSE, FALSE, nullptr);

    LARGE_INTEGER freq, t0, t1;
    QueryPerformanceFrequency(&freq); QueryPerformanceCounter(&t0);
    int presented = 0;
    for (int i = 0; i < frames; i++) {
        MSG msg; while (PeekMessageA(&msg, nullptr, 0, 0, PM_REMOVE)) DispatchMessageA(&msg);
        const UINT b = swap->GetCurrentBackBufferIndex();
        CHECK(allocator->Reset());
        CHECK(list->Reset(allocator, nullptr));
        D3D12_RESOURCE_BARRIER barrier = {};
        barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        barrier.Transition.pResource = buffers[b];
        barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT;
        barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_RENDER_TARGET;
        list->ResourceBarrier(1, &barrier);
        const float color[4] = {(i % 60) / 60.0f, 0.3f, 1.0f - (i % 120) / 120.0f, 1.0f};
        list->ClearRenderTargetView(rtv[b], color, 0, nullptr);
        barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
        barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT;
        list->ResourceBarrier(1, &barrier);
        CHECK(list->Close());
        ID3D12CommandList *lists[] = {list};
        queue->ExecuteCommandLists(1, lists);
        CHECK(swap->Present(0, 0));
        presented++;
        // One frame in flight: simple, and the frame time includes the GPU's work.
        CHECK(queue->Signal(fence, i + 1));
        if (fence->GetCompletedValue() < (UINT64)i + 1) {
            CHECK(fence->SetEventOnCompletion(i + 1, done));
            if (WaitForSingleObject(done, 5000) != WAIT_OBJECT_0) { printf("frame %d never finished\n", i); return 1; }
        }
    }
    QueryPerformanceCounter(&t1);
    printf("presented %d/%d frames, avg frame %.3f ms\n", presented, frames,
           (t1.QuadPart - t0.QuadPart) * 1000.0 / freq.QuadPart / frames);
    return 0;
}
```

- [ ] **Step 3: Write `d3d12_dxil.cpp`**

```cpp
// Creates a graphics and a compute pipeline from DXIL shaders (DXMT fork spec §6):
//   d3d12_dxil.exe <vs.dxil> <ps.dxil> <cs.dxil>
// Prints each HRESULT. DXMT returns E_NOTIMPL (0x80004001) until it can translate DXIL.
#define WIDL_EXPLICIT_AGGREGATE_RETURNS
#include <windows.h>
#include <d3d12.h>
#include <climits>
#include <cstdio>
#include <vector>

static std::vector<char> load(const char *path) {
    std::vector<char> data;
    if (FILE *f = fopen(path, "rb")) {
        char buffer[4096]; size_t n;
        while ((n = fread(buffer, 1, sizeof buffer, f)) > 0) data.insert(data.end(), buffer, buffer + n);
        fclose(f);
    }
    return data;
}

int main(int argc, char **argv) {
    if (argc != 4) { printf("usage: d3d12_dxil.exe <vs.dxil> <ps.dxil> <cs.dxil>\n"); return 2; }
    std::vector<char> vs = load(argv[1]), ps = load(argv[2]), cs = load(argv[3]);
    if (vs.empty() || ps.empty() || cs.empty()) { printf("can't read the shaders\n"); return 1; }

    ID3D12Device *device;
    HRESULT hr = D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device), (void **)&device);
    if (FAILED(hr)) { printf("D3D12CreateDevice hr=0x%08lx\n", (unsigned long)hr); return 1; }
    D3D12_ROOT_SIGNATURE_DESC rd = {};
    rd.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
    ID3DBlob *blob = nullptr, *error = nullptr;
    hr = D3D12SerializeRootSignature(&rd, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &error);
    if (FAILED(hr)) { printf("D3D12SerializeRootSignature hr=0x%08lx\n", (unsigned long)hr); return 1; }
    ID3D12RootSignature *root;
    hr = device->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(),
                                     __uuidof(ID3D12RootSignature), (void **)&root);
    if (FAILED(hr)) { printf("CreateRootSignature hr=0x%08lx\n", (unsigned long)hr); return 1; }

    D3D12_GRAPHICS_PIPELINE_STATE_DESC gd = {};
    gd.pRootSignature = root;
    gd.VS = {vs.data(), vs.size()};
    gd.PS = {ps.data(), ps.size()};
    gd.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    gd.SampleMask = UINT_MAX;
    gd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    gd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    gd.RasterizerState.DepthClipEnable = TRUE;
    gd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    gd.NumRenderTargets = 1;
    gd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
    gd.SampleDesc.Count = 1;
    ID3D12PipelineState *pso = nullptr;
    hr = device->CreateGraphicsPipelineState(&gd, __uuidof(ID3D12PipelineState), (void **)&pso);
    printf("graphics hr=0x%08lx\n", (unsigned long)hr);

    D3D12_COMPUTE_PIPELINE_STATE_DESC cd = {};
    cd.pRootSignature = root;
    cd.CS = {cs.data(), cs.size()};
    hr = device->CreateComputePipelineState(&cd, __uuidof(ID3D12PipelineState), (void **)&pso);
    printf("compute hr=0x%08lx\n", (unsigned long)hr);
    return 0;
}
```

- [ ] **Step 4: Add the Makefile targets and build the programs**

In `Makefile`, add `dxmt-tests dxmt-check` to `.PHONY` and add after the `dxmt` target:

```make
# D3D12 test programs for our DXMT.
dxmt-tests:
	@command -v x86_64-w64-mingw32-g++ >/dev/null || { echo "dxmt-tests: needs brew install mingw-w64" >&2; exit 1; }
	mkdir -p build/dxmt-tests
	x86_64-w64-mingw32-g++ -O2 -static -s -o build/dxmt-tests/d3d12_clear.exe dxmt/tests/d3d12_clear.cpp -ld3d12 -ldxgi -luser32
	x86_64-w64-mingw32-g++ -O2 -static -s -o build/dxmt-tests/d3d12_dxil.exe dxmt/tests/d3d12_dxil.cpp -ld3d12

# Our DXMT under the installed runtime (real Wine, no Steam); see dxmt/check.sh.
dxmt-check: build dxmt presenter dxmt-tests
	sh dxmt/tests/build_test.sh
	sh dxmt/check.sh
```

Run: `make dxmt-tests && file build/dxmt-tests/*.exe`
Expected: both files are `PE32+ executable (console) x86-64`.

- [ ] **Step 5: Write `dxmt/check.sh` (items 1, 2, 4, 5)**

```sh
#!/bin/sh
# Our DXMT build under real Wine, no Steam (DXMT fork spec §6). Needs `make build dxmt presenter dxmt-tests`, an
# installed runtime with GPTK imported, and that runtime's tarball in ~/Library/Caches/MacNeutron. MACNEUTRON_TOOL
# overrides the tool folder, which is never modified: the checks run on two APFS clones of it (instant, no space).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DXMT="$ROOT/build/dxmt"
TESTS="$ROOT/build/dxmt-tests"
S="$ROOT/dxmt/tests/shaders"
LOOP="$ROOT/build/presenter/present_loop.exe"
TOOL="${MACNEUTRON_TOOL:-$HOME/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron}"
WORK="${TMPDIR:-/tmp}/macneutron dxmt"
fail=0
expect() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2], want [$3]"; fail=1; fi; }
die() { echo "dxmt-check: $*" >&2; exit 1; }

[ -f "$TOOL/gptk.json" ] || die "import GPTK first (check 4 runs D3DMetal)"
TARBALL="$HOME/Library/Caches/MacNeutron/$(cat "$TOOL/runtime-version").tar.gz"
[ -f "$TARBALL" ] || die "the runtime tarball isn't cached at $TARBALL (reinstall the runtime once)"

# "stock": the runtime's own DXMT 0.80, restored from its tarball. "ours": build/dxmt installed over it.
# Both run the launcher just built, so only DXMT differs.
rm -rf "$WORK"; mkdir -p "$WORK/compat"
cp -cR "$TOOL" "$WORK/stock"
rm -rf "$WORK/stock/Libraries/DXMT" "$WORK/stock/dxmt-version"
tar -xzf "$TARBALL" -C "$WORK/stock" Libraries/DXMT Libraries/Wine/lib/wine/x86_64-unix/winemetal.so \
  Libraries/Wine/lib/wine/x86_64-windows/winemetal.dll Libraries/Wine/lib/wine/i386-windows/winemetal.dll
cp "$ROOT/.build/release/macneutron" "$WORK/stock/bin/macneutron"
cp -cR "$WORK/stock" "$WORK/ours"
"$ROOT/.build/release/macneutron" install-dxmt --tool-dir "$WORK/ours" "$DXMT" > /dev/null

# run <stock|ours> <name> <backend> <exe> [args...]  →  output in $WORK/<name>.txt
run() {
  tool=$1 name=$2 backend=$3; shift 3
  env STEAM_COMPAT_DATA_PATH="$WORK/compat/$tool" SteamAppId=0 MACNEUTRON_GRAPHICS="$backend" \
      MACNEUTRON_NO_STEAM_BRIDGE=1 MACNEUTRON_NO_METALFX=1 \
      "$WORK/$tool/bin/macneutron" launch waitforexitandrun "$@" > "$WORK/$name.out" 2>&1 &
  pid=$!
  ( sleep 120; kill "$pid" 2> /dev/null ) & dog=$!
  wait "$pid" || true
  kill "$dog" 2> /dev/null || true
  tr -d '\r' < "$WORK/$name.out" > "$WORK/$name.txt"
}
for tool in stock ours; do  # the prefixes, created outside the 120 s watchdog
  env STEAM_COMPAT_DATA_PATH="$WORK/compat/$tool" SteamAppId=0 \
      "$WORK/$tool/bin/macneutron" launch getcompatpath "$WORK" > /dev/null 2>&1
done

# 1. D3D11 on our DXMT is as fast as on DXMT 0.80: best of two runs each, within 10%.
for i in 1 2; do
  run stock "stock$i" dxmt "$LOOP" 1280 720 0 0 600 0
  run ours "ours$i" dxmt "$LOOP" 1280 720 0 0 600 0
done
best() { cat "$WORK/${1}1.txt" "$WORK/${1}2.txt" | grep -o 'avg frame [0-9.]*' | awk '{print $3}' | sort -n | head -1; }
expect "D3D11 frame time within 10% of DXMT 0.80" \
  "$(awk -v a="$(best ours)" -v b="$(best stock)" 'BEGIN { print (a != "" && b != "" && a <= b * 1.10) ? "yes" : "no (" a " vs " b " ms)" }')" "yes"
expect "the D3D11 game ran our d3d11.dll" \
  "$(cmp -s "$DXMT/x86_64-windows/d3d11.dll" "$WORK/compat/ours/pfx/drive_c/windows/system32/d3d11.dll" && echo yes || echo no)" "yes"

# 2. A D3D12 program presents through our d3d12.dll (D3DMetal would report shader model 6.x).
run ours clear dxmt "$TESTS/d3d12_clear.exe" 300
expect "d3d12_clear presents every frame" "$(grep -c 'presented 300/300 frames' "$WORK/clear.txt" || true)" 1
expect "the D3D12 device is our DXMT (shader model 5.1)" "$(grep -c '^shader model 0x51 ' "$WORK/clear.txt" || true)" 1

# 3. DXIL pipelines (Task 5 adds the capture checks).
run ours dxil dxmt "$TESTS/d3d12_dxil.exe" "Z:$S/triangle.vs.dxil" "Z:$S/triangle.ps.dxil" "Z:$S/compute.cs.dxil"
expect "DXIL pipelines return E_NOTIMPL" "$(grep -c 'hr=0x80004001' "$WORK/dxil.txt" || true)" 2

# 4. D3DMetal still works.
run ours d3dmetal d3dmetal "$LOOP" 1280 720 0 0 200 0
expect "present_loop completes on D3DMetal" "$(grep -c 'avg frame' "$WORK/d3dmetal.txt" || true)" 1

# 5. The DXIL probe: results recorded, not graded; one line per shader, and a non-container is refused.
"$DXMT/dxil-probe" "$S"/*.dxil > "$WORK/probe.txt" || true
cat "$WORK/probe.txt"
expect "the probe reports every shader" "$(grep -cE '^(ok|fail) ' "$WORK/probe.txt")" 3
expect "the probe refuses a non-container" "$("$DXMT/dxil-probe" "$DXMT/version" | cut -d ' ' -f 1)" fail

[ $fail = 0 ] && echo "dxmt-check: all passed"
exit $fail
```

- [ ] **Step 6: Run the check**

Run: `make dxmt-check 2>&1 | tail -20`
Expected:
- `build_test.sh`'s 6 `ok` lines;
- then `ok` for all nine checks (items 1–5) and `dxmt-check: all passed`.

If `d3d12_clear` doesn't present (item 2), read `$TMPDIR/macneutron dxmt/clear.txt`. Rerun with `MACNEUTRON_LOG=1` and read the game log. Fixing DXMT's D3D12 runtime belongs to sub-project 3, so stop there and report the log.
If item 1 is over 10%, rerun once; if it still fails, stop and report both numbers.

- [ ] **Step 7: Start the acceptance record and commit**

Create `docs/testing/acceptance-dxmt-fork.md`:

```markdown
# DXMT fork (sub-project 1) acceptance

Spec: `docs/superpowers/specs/2026-09-28-macneutron-dxmt-fork-design.md`.

## make dxmt-check, <date>

Fork commit `<version>`, runtime-v4.7.3, GPTK 4.0b2, M5 Pro, macOS 27.

| Check | Result |
|---|---|
| 1. D3D11 `present_loop` 1280x720, 600 frames: ours vs DXMT 0.80 (best of 2) | <ours> ms vs <stock> ms |
| 2. `d3d12_clear` 300 frames | <presented>, <avg> ms; adapter <name>, shader model 0x51, binding tier <n> |
| 3. `d3d12_dxil` | graphics and compute `0x80004001` |
| 4. `present_loop` on D3DMetal | completes, <avg> ms |
| 5. `dxil-probe` on the test shaders | <paste the three lines> |
```

Fill in the values from the run in Step 6 (`$TMPDIR/macneutron dxmt/*.txt`).

```bash
git add dxmt/tests/d3d12_clear.cpp dxmt/tests/d3d12_dxil.cpp dxmt/tests/shaders dxmt/check.sh Makefile \
  docs/testing/acceptance-dxmt-fork.md
git commit -m "test(dxmt): D3D12 test programs, DXIL test shaders and make dxmt-check

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: DXIL capture in the fork (`DXMT_DXIL_DUMP`)

**Files:**
- Fork (`build/dxmt-src/dxmt`, branch `macneutron`):
  - create `src/d3d12/d3d12_dxil_dump.hpp` and `d3d12_dxil_dump.cpp`;
  - modify `src/d3d12/meson.build` (the `d3d12_src` list);
  - modify `src/d3d12/d3d12_pipeline_graphics.cpp`: the top of `Initialize(const D3D12_GRAPHICS_PIPELINE_STATE_DESC *pDesc)`, about line 467 at upstream 7c8dee1c;
  - modify `src/d3d12/d3d12_pipeline_compute.cpp`: the top of `Initialize(const D3D12_COMPUTE_PIPELINE_STATE_DESC *pDesc)`, line 38.
- Modify: `dxmt/check.sh` (item 3), `dxmt/pins` (`DXMT_COMMIT`), `docs/testing/acceptance-dxmt-fork.md`

**Interfaces:**
- Consumes: `run` in `dxmt/check.sh`, `d3d12_dxil.exe`, and the committed `.dxil` files (Task 4).
- Produces:
  - `DXMT_DXIL_DUMP=<folder>` behaviour: `<folder>/<stage>-<16 lowercase hex FNV-1a 64 of the whole blob>.dxil`, where stage is `ps`, `vs`, `gs`, `hs`, `ds`, `cs`, …;
  - a new fork commit `<FORK2>` pinned in `dxmt/pins`.

- [ ] **Step 1: Add the capture checks to `check.sh`**

In `dxmt/check.sh`, replace the item-3 block (from `# 3. DXIL pipelines` through its `expect`) with:

```sh
# 3. DXIL pipelines return E_NOTIMPL, and DXMT_DXIL_DUMP captures each shader once, byte for byte.
#    $WORK has a space in it, like the Application Support paths users will pass.
dxil() { run ours "$1" dxmt "$TESTS/d3d12_dxil.exe" "Z:$S/triangle.vs.dxil" "Z:$S/triangle.ps.dxil" "Z:$S/compute.cs.dxil"; }
D="$WORK/dxil"; mkdir -p "$D"
export DXMT_DXIL_DUMP="$D"
dxil dxil
expect "DXIL pipelines return E_NOTIMPL" "$(grep -c 'hr=0x80004001' "$WORK/dxil.txt" || true)" 2
expect "three shaders captured" "$(ls "$D" | wc -l | tr -d ' ')" 3
expect "each capture is the shader, byte for byte" "$(for s in triangle.vs:vs triangle.ps:ps compute.cs:cs; do
    f=$(ls "$D/${s#*:}"-*.dxil 2> /dev/null | head -1)
    [ -n "$f" ] && cmp -s "$S/${s%%:*}.dxil" "$f" && printf y || printf n
  done)" yyy
expect "capture names are <stage>-<16 hex>.dxil" "$(ls "$D" | grep -cE '^(vs|ps|cs)-[0-9a-f]{16}\.dxil$')" 3
vs=$(ls "$D"/vs-*.dxil 2> /dev/null | head -1)
[ -z "$vs" ] || echo keep > "$vs"
dxil dxil-again
expect "an existing capture is left alone" "$(cat "$vs" 2> /dev/null)" keep
export DXMT_DXIL_DUMP="/nonexistent/macneutron dxil"
dxil dxil-unwritable
expect "an unwritable capture folder changes nothing for the game" "$(grep -c 'hr=0x80004001' "$WORK/dxil-unwritable.txt" || true)" 2
unset DXMT_DXIL_DUMP
```

- [ ] **Step 2: Run it to make sure the capture checks fail**

Run: `sh dxmt/check.sh 2>&1 | grep -E "^(ok|FAIL)"`
Expected:
- `FAIL three shaders captured: got [0], want [3]`;
- `FAIL each capture is …: got [nnn]`;
- `FAIL capture names …: got [0]`;
- `FAIL an existing capture is left alone: got [], want [keep]`;
- every other check `ok`.

- [ ] **Step 3: Write the capture in the fork**

`make dxmt` left the clone on a detached HEAD at the pinned commit; get back on the branch first:
```bash
git -C build/dxmt-src/dxmt switch macneutron
```

`build/dxmt-src/dxmt/src/d3d12/d3d12_dxil_dump.hpp`:
```cpp
#pragma once

#include "d3d12.h"

namespace dxmt {

// MacNeutron: with DXMT_DXIL_DUMP=<folder>, saves each DXIL shader a pipeline is created from as
// <folder>/<stage>-<FNV-1a 64 of the blob, 16 hex>.dxil. DXBC shaders are ignored, existing files are kept, and
// write errors are ignored, so capturing never changes what the game gets.
void DumpDXIL(const D3D12_SHADER_BYTECODE &Bytecode);

} // namespace dxmt
```

`build/dxmt-src/dxmt/src/d3d12/d3d12_dxil_dump.cpp`:
```cpp
#include "d3d12_dxil_dump.hpp"
#include "util_env.hpp"
#include <windows.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

namespace dxmt {

namespace {

uint32_t read32(const uint8_t *p) {
  uint32_t value;
  memcpy(&value, p, 4);
  return value;
}

// The stage in the DXIL part's program header, or nullptr for DXBC or a malformed container.
const char *DXILStage(const uint8_t *blob, size_t size) {
  static const char *const stages[] = {"ps", "vs", "gs", "hs", "ds", "cs", "lib", "raygen",
                                       "intersection", "anyhit", "closesthit", "miss", "callable", "ms", "as", "node"};
  if (size < 32 || memcmp(blob, "DXBC", 4))
    return nullptr;
  uint32_t parts = read32(blob + 28);
  for (uint64_t i = 0; i < parts && 32 + 4 * (i + 1) <= size; i++) {
    uint64_t offset = read32(blob + 32 + 4 * i);
    if (offset + 12 > size || memcmp(blob + offset, "DXIL", 4))
      continue;
    uint32_t kind = read32(blob + offset + 8) >> 16;
    return kind < sizeof(stages) / sizeof(*stages) ? stages[kind] : "unknown";
  }
  return nullptr;
}

} // namespace

void DumpDXIL(const D3D12_SHADER_BYTECODE &Bytecode) {
  static const std::string folder = [] {
    std::string value = env::getEnvVar("DXMT_DXIL_DUMP");
    // Launch options carry Mac paths; Wine's Z: drive is the Mac's root.
    return !value.empty() && value[0] == '/' ? "Z:" + value : value;
  }();
  if (folder.empty() || !Bytecode.pShaderBytecode)
    return;
  auto blob = static_cast<const uint8_t *>(Bytecode.pShaderBytecode);
  const char *stage = DXILStage(blob, Bytecode.BytecodeLength);
  if (!stage)
    return;
  uint64_t hash = 0xcbf29ce484222325ull;
  for (size_t i = 0; i < Bytecode.BytecodeLength; i++)
    hash = (hash ^ blob[i]) * 0x100000001b3ull;
  char name[64];
  snprintf(name, sizeof(name), "\\%s-%016llx.dxil", stage, (unsigned long long)hash);
  std::string path = folder + name;
  // CREATE_NEW keeps a capture made before; any failure only means this shader isn't captured.
  HANDLE file = CreateFileA(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE)
    return;
  DWORD written = 0;
  bool ok = WriteFile(file, blob, (DWORD)Bytecode.BytecodeLength, &written, nullptr) &&
            written == Bytecode.BytecodeLength;
  CloseHandle(file);
  if (!ok)
    DeleteFileA(path.c_str());
}

} // namespace dxmt
```

`src/d3d12/meson.build`: add `'d3d12_dxil_dump.cpp',` to `d3d12_src` after `'d3d12_device.cpp',`.

`src/d3d12/d3d12_pipeline_graphics.cpp`:
- Add `#include "d3d12_dxil_dump.hpp"` after `#include "d3d12_device.hpp"`.
- Make these the first lines of `Initialize(const D3D12_GRAPHICS_PIPELINE_STATE_DESC *pDesc) {`, before the `StreamOutput` check, so pipelines rejected for GS or tessellation are captured too:
  ```cpp
      for (auto *shader : {&pDesc->VS, &pDesc->PS, &pDesc->GS, &pDesc->HS, &pDesc->DS})
        DumpDXIL(*shader);
  ```

`src/d3d12/d3d12_pipeline_compute.cpp`:
- Add `#include "d3d12_dxil_dump.hpp"` after its last `#include`.
- Make `DumpDXIL(pDesc->CS);` the first line of `Initialize(const D3D12_COMPUTE_PIPELINE_STATE_DESC *pDesc) {`.

If the fork's `env::getEnvVar` or an include path differs from what's written here, adapt to the fork's actual names and ledger the change.

- [ ] **Step 4: Commit in the fork, pin it, rebuild, and run the check**

```bash
git -C build/dxmt-src/dxmt add src/d3d12/d3d12_dxil_dump.hpp src/d3d12/d3d12_dxil_dump.cpp src/d3d12/meson.build \
  src/d3d12/d3d12_pipeline_graphics.cpp src/d3d12/d3d12_pipeline_compute.cpp
git -C build/dxmt-src/dxmt commit -m "d3d12: DXMT_DXIL_DUMP saves the DXIL shaders pipelines are created from

MacNeutron fork only; never proposed upstream.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git -C build/dxmt-src/dxmt rev-parse HEAD
```
Put that commit (`<FORK2>`) into `DXMT_COMMIT=` in `dxmt/pins`, then:

Run: `make dxmt > build/dxmt-make.log 2>&1; tail -1 build/dxmt-make.log; sh dxmt/check.sh 2>&1 | grep -E "^(ok|FAIL)|all passed"`
Expected:
- `dxmt: built …/build/dxmt (<FORK2>)`;
- every check `ok`;
- `dxmt-check: all passed`.

- [ ] **Step 5: Push the fork (the push was approved in Task 1 Step 1)**

Run: `git -C build/dxmt-src/dxmt push origin macneutron`
Expected: `macneutron -> macneutron`. The pinned commit is now public, as the LGPL requires of what we ship.

- [ ] **Step 6: Record and commit**

In `docs/testing/acceptance-dxmt-fork.md`:
- change item 3's row to: `3. d3d12_dxil with DXMT_DXIL_DUMP | E_NOTIMPL x2; 3 shaders captured byte for byte; existing capture kept; unwritable folder ignored`;
- update the fork commit in the heading line to `<FORK2>`.

```bash
git add dxmt/check.sh dxmt/pins docs/testing/acceptance-dxmt-fork.md
git commit -m "feat(dxmt): capture DXIL shaders with DXMT_DXIL_DUMP (fork commit pinned)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: The app bundle and the README

**Files:**
- Modify: `Makefile` (`app`), `README.md`

**Interfaces:**
- Consumes: `build/dxmt` (Tasks 1 and 5); `DXMTBuild.bundled(near:)`, which expects `Contents/Resources/DXMT/{version,x86_64-windows,i386-windows}` and `Contents/Frameworks/DXMT/x86_64-unix/winemetal.so` (Task 2).
- Produces: `build/MacNeutron.app` carrying our DXMT.

- [ ] **Step 1: Check that today's app has no DXMT (the failing check)**

Run:
```bash
make app > /dev/null 2>&1; T="$TMPDIR/macneutron app-dxmt"; rm -rf "$T"
build/MacNeutron.app/Contents/Helpers/macneutron install-runtime --tool-dir "$T" \
  --tarball ~/Library/Caches/MacNeutron/runtime-v4.7.3.tar.gz && cat "$T/dxmt-version"
```
Expected: the runtime installs, then `cat: …/dxmt-version: No such file or directory`.

- [ ] **Step 2: Bundle DXMT**

In `Makefile`:
- Change `app: build bridge presenter` to `app: build bridge presenter dxmt`.
- Insert before the final `codesign --force --sign - $(APP)` line of the `app` recipe:

```make
	mkdir -p $(APP)/Contents/Resources/DXMT $(APP)/Contents/Frameworks/DXMT
	cp -R build/dxmt/x86_64-windows build/dxmt/i386-windows build/dxmt/version \
		build/dxmt/COPYING.LIB build/dxmt/LICENSE build/dxmt/LICENSE.OLD $(APP)/Contents/Resources/DXMT/
	cp -R build/dxmt/x86_64-unix $(APP)/Contents/Frameworks/DXMT/
	codesign --force --sign - $(APP)/Contents/Frameworks/DXMT/x86_64-unix/winemetal.so
```

- [ ] **Step 3: Run the check again, and verify the signature**

Run:
```bash
make app > build/app-make.log 2>&1 && codesign --verify --strict --verbose=1 build/MacNeutron.app
T="$TMPDIR/macneutron app-dxmt"; rm -rf "$T"
build/MacNeutron.app/Contents/Helpers/macneutron install-runtime --tool-dir "$T" \
  --tarball ~/Library/Caches/MacNeutron/runtime-v4.7.3.tar.gz && cat "$T/dxmt-version"; grep DXMT_COMMIT dxmt/pins
ls "$T/Libraries/DXMT/x64"
```
Expected:
- `build/MacNeutron.app: valid on disk` and `satisfies its Designated Requirement`;
- `dxmt-version` equal to the pinned `DXMT_COMMIT`;
- `d3d12.dll` listed in `Libraries/DXMT/x64`.

If `codesign --verify --strict` rejects the `Frameworks/DXMT/x86_64-unix` folder, move the Mac half to a layout codesign accepts. Change `DXMTBuild.bundled(near:)` and its test `findsTheAppBundlesTwoHalves` to match (test first), and ledger the ruling.

- [ ] **Step 4: README**

In `README.md`:
- Replace the opening paragraph's second line `client and translated by Wine and Apple's D3DMetal.` with `client and translated by Wine and DXMT (Apple's D3DMetal optional, per game).`
- In "Build and test", add after the `make smoke` line:
  ```sh
  make dxmt         # our DXMT fork with Direct3D 12 into build/dxmt; first run ~500 MB of downloads and a 30-60 min LLVM build
  make dxmt-check   # our DXMT under real Wine (needs GPTK imported)
  ```
  and below the code block: `` `make dxmt` and `make app` need `brew install cmake ninja meson mingw-w64`. ``
- In "Install the runtime from the command line", add to the code block:
  ```sh
  .build/release/macneutron install-dxmt build/dxmt          # after make dxmt: our DXMT instead of the runtime's 0.80
  ```
- Change the `MACNEUTRON_GRAPHICS` table row's effect to: `Pick the Direct3D backend (default `dxmt`; `dxvk` is unavailable while GPTK is imported and falls back to `d3dmetal`)`.
- Add this section before `## Steam API`:

```markdown
## Graphics

Games use DXMT by default, an open-source Direct3D → Metal translator. MacNeutron builds it from its own fork,
[chadouming/dxmt](https://github.com/chadouming/dxmt), with Direct3D 12 enabled. DXMT is LGPL-2.1+: the licences ship
in `MacNeutron.app/Contents/Resources/DXMT`, and the fork commit is in the tool folder's `dxmt-version`. The fork's
changes are AI-assisted and never go to DXMT upstream, per its contribution policy.

DXMT's Direct3D 12 is early. Games with Shader Model 6 (DXIL) shaders, which covers most Unreal Engine 5 and recent
titles, don't start on it yet. For those, import GPTK and set **Graphics: D3DMetal** for the game in the Games window
(or use `/usr/bin/env MACNEUTRON_GRAPHICS=d3dmetal %command%`).

For DXMT development, `/usr/bin/env DXMT_DXIL_DUMP=<folder> %command%` saves each DXIL shader a game creates.
```

- [ ] **Step 5: Run the unit tests and commit**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: `Test run with <N> tests passed`, no `✘`.

```bash
git add Makefile README.md
git commit -m "feat(app): bundle our DXMT; README: Graphics section

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Acceptance on the maintainer's Mac

**Files:**
- Modify: `docs/testing/acceptance-dxmt-fork.md`

**Interfaces:**
- Consumes: everything above; `build/MacNeutron.app`.

- [ ] **Step 1: Install through the app (item 1)**

Ask the user to quit MacNeutron and open `build/MacNeutron.app`. After it starts, run:
```bash
T="$HOME/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron"
cat "$T/dxmt-version"; grep DXMT_COMMIT dxmt/pins; ls "$T/Libraries/DXMT/x64"
```
Expected: `dxmt-version` equals the pin, and `d3d12.dll` is listed.

- [ ] **Step 2: `make dxmt-check` (item 2)**

Run: `make dxmt-check 2>&1 | tail -25`
Expected: `dxmt-check: all passed`. Copy the numbers into the table as in Task 4 Step 7.

- [ ] **Step 3: The game runs (items 3, 4 and 6; the user plays, you record)**

Ask the user to do the following. The accounts and names they see are not recorded.
- **Item 3 (a D3D11 game on our DXMT):**
  - Set SMITE 2's launch options to `/usr/bin/env MACNEUTRON_LOG=1 %command% -dx11`, with Graphics "Default (DXMT)".
  - Play one match or the practice range.
  - Report: does it run? FPS, and GPU time from the Metal HUD (`MTL_HUD_ENABLED=1` added before `%command%`).
  - If SMITE 2 has no D3D11 mode, use any D3D11 title they own.
- **Items 4 and 6 (D3D12 on the default):**
  - Set SMITE 2's launch options to `/usr/bin/env MACNEUTRON_LOG=1 DXMT_DXIL_DUMP=$HOME/dxil-smite2 %command%`, with Graphics "Default (DXMT)", and launch it.
  - Expected: it fails to reach the menu.
  - Record where it stopped: the last lines of `~/Library/Logs/MacNeutron/steam-<appid>.log`, with any account IDs removed.
  - Record the capture count: `ls ~/dxil-smite2 | wc -l`.
- **Item 6, continued:** set Graphics to "D3DMetal" for SMITE 2, remove the extra launch options, and play. Expected: plays as before.

- [ ] **Step 4: The probe on SMITE 2's shaders (item 5)**

Run:
```bash
build/dxmt/dxil-probe ~/dxil-smite2/*.dxil > build/probe-smite2.txt; echo "exit $?"
grep -c '^ok ' build/probe-smite2.txt; grep -c '^fail ' build/probe-smite2.txt
grep '^fail ' build/probe-smite2.txt | cut -d ' ' -f 3- | sort | uniq -c | sort -rn | head -10
grep '^ok ' build/probe-smite2.txt | grep -o ' [a-z]*_6_[0-9]' | sort | uniq -c
```
Expected: counts of ok and fail, the most common failure reasons, and the stage and shader-model mix. Not graded: this decides sub-project 2's approach (spec §9).

- [ ] **Step 5: Record and commit**

Append to `docs/testing/acceptance-dxmt-fork.md`:

```markdown
## Acceptance on the maintainer's Mac, <date>

1. `make dxmt`, `make app`: <ok>; the app installed DXMT `<commit>` (matches the pin).
2. `make dxmt-check`: <n>/<n> ok (table above).
3. D3D11 game on our DXMT (<title>, `-dx11`): <runs / doesn't>; <fps> FPS, GPU <ms> ms.
4. SMITE 2 (D3D12) on the default with `DXMT_DXIL_DUMP`: stopped at <where>; <n> shaders captured.
5. `dxil-probe` on SMITE 2's shaders: <ok> ok, <fail> fail. Most common LLVM errors: <list>. Shader mix: <list>.
   Test shaders: <the three lines>.
   **Consequence for sub-project 2:** <LLVM 15 reads DXIL, so the translator can build on LLVM 15 / it can't, so it needs
   a separate reader such as dxil-spirv's>.
6. SMITE 2 on the default: fails as expected (item 4). With Graphics: D3DMetal: <plays as before>.
```

```bash
git add docs/testing/acceptance-dxmt-fork.md
git commit -m "docs: DXMT fork acceptance recorded

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
