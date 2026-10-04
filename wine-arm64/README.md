# wine-arm64: native arm64 Wine and FEX

`make wine-arm64` builds the first stage of MacNeutron's native arm64 stack: upstream Wine 11.19 (ARM64EC and arm64),
with our patches, FEX, which runs x64 Windows code inside it, and our DXMT built for arm64 (Direct3D 11/12; D3D10's front end bundled, untested),
staged as one signed, entitled `build/wine-arm64/wine.app`. Every Windows process runs natively on arm64 with 4K
pages; only the game's x86-64 code is translated.

Design, gates and risks: [`docs/superpowers/specs/2026-10-02-macneutron-native-arm64-design.md`](../docs/superpowers/specs/2026-10-02-macneutron-native-arm64-design.md)
(Wine and FEX) and [`docs/superpowers/specs/2026-10-03-macneutron-arm64-dxmt-design.md`](../docs/superpowers/specs/2026-10-03-macneutron-arm64-dxmt-design.md) (DXMT).
Results on the maintainer's Mac: [`docs/testing/acceptance-arm64-wine.md`](../docs/testing/acceptance-arm64-wine.md) and
[`docs/testing/acceptance-arm64-dxmt.md`](../docs/testing/acceptance-arm64-dxmt.md).

This is a development build for sub-projects 1 and 2. The shipped runtime is still the Rosetta one (`make dxmt`, the
app).

## Requirements

- Apple Silicon, **macOS 27**, and Xcode (Apple clang).
- Homebrew `autoconf`, `bison`, `flex`, `cmake`, `ninja` and `meson`. The build names whatever is missing and never
  installs it. The build itself doesn't run `autoconf`; the development loop needs it for a patch that changes `configure.ac`.
- Xcode's Metal Toolchain, for DXMT's shaders (`xcodebuild -downloadComponent MetalToolchain`).
- Windows-side code is built with the pinned llvm-mingw, which `dxmt/toolchain.sh` fetches once.
- **A Developer ID with the "Cross-architecture Compatibility Framework" capability** (`com.apple.developer.cross-architecture-support`)
  granted for the App ID `net.authspot.macneutron.wine` (team `49QMZXLR8S`), and a Developer ID provisioning profile for it.
  Without the entitlement the loader can't map the low 4 GB or get 4K pages, so there is no ad-hoc mode.

```sh
export MACNEUTRON_SIGN_IDENTITY="Developer ID Application: … (49QMZXLR8S)"
export MACNEUTRON_PROVISIONING_PROFILE=/path/to/the.provisionprofile   # never committed
```

**Anyone else needs their own App ID and their own grant** from Apple: only a team with the capability can produce a
working runtime. Then change `APP_ID` in `lib.sh` and the identifiers in `wine.entitlements` and `Info.plist` (the
profile check's test, `tests/profile_test.sh`, and its fixtures name the App ID too), and use your team's identity and
profile.

## Build and check

```sh
make wine-arm64        # fetch Wine, FEX and DXMT at the pins, patch, build, sign; build/wine-arm64/wine.app (a few minutes the first time)
                       # a cold first build includes the arm64 LLVM (about 2 min here)
make wine-arm64-check  # boot, 4K pages, native ARM64, FEX, gates G1-G5, DXMT gates D2-D4 (about 15 min)

make build wine-arm64-tests dxmt dxmt-tests presenter dxmt-tests-arm64ec  # what check.sh needs besides the runtime
sh wine-arm64/check.sh g2-litmus   # named steps only (and the steps they need); see STEPS in check.sh
```

`make wine-arm64-check` builds the launcher (`make build`), the test programs (`make wine-arm64-tests`) and what the
DXMT steps run (`make dxmt dxmt-tests presenter dxmt-tests-arm64ec`: our Rosetta DXMT, the x64 and ARM64EC D3D test
programs and `present_loop`) itself, but `make wine-arm64` does not, and `check.sh` run on its own needs them all (G4
runs the launcher). Gate G4's Rosetta baseline runs MacNeutron's installed runtime-v4.7.3 (`MACNEUTRON_TOOL` names
another tool folder). Each run starts from a clean prefix under `build/wine-arm64 check/`, and ends by checking that
no process of either runtime is left.

The DXMT steps, after `g5-jit`:

| Step | What |
|---|---|
| `dxmt` | Copies the bundle's front ends into the prefix's system32, turns the crash dialog off, checks the builtin markers and `DXMT/version` |
| `dxmt-present` | Gate D2: `present_loop` (D3D11) and `d3d12_clear` (D3D12) windows on screen in both lanes, each read by `winshot`; then 20 window cycles (ARM64EC) |
| `dxmt-arm64ec` | Gate D3: `dxmt/check.sh` in arm64 mode with the ARM64EC test programs |
| `dxmt-x64` | Gate D4: the same with the x64 test programs under FEX, the FSR 3 check included |

`winshot` (`tools/winshot.c`) captures a window, so the app that runs the check (Terminal, or whatever starts `make`)
needs System Settings › Privacy & Security › Screen Recording; without it `dxmt-present` fails and names that setting.
The lanes compare our DXMT with D3DMetal on the installed Rosetta runtime, as `make dxmt-check` does, so they need
what it needs: runtime-v4.7.3 installed with its tarball cached in `~/Library/Caches/MacNeutron/`, and GPTK imported.
`dxmt-x64`'s FSR 3 swap chain check also needs SMITE 2 installed in Steam's default library (its `amd_fidelityfx_dx12.dll` is read
from `~/Library/Application Support/Steam/steamapps/common/SMITE 2`, never copied): without it `dxmt-x64` fails naming the skip, and the steps after it (`g4-bench`) don't
run.

### The Steam bridge

`wine.app` carries the Steam bridge on arm64 (ship-base spec §7): Proton's `lsteamclient` (pinned in `deps.pins`, with
`patches/lsteamclient/`), built by Wine's own build as an ARM64X `lsteamclient.dll` and an arm64 `lsteamclient.so`
that loads the arm64 slice of Mac Steam's universal `steamclient.dylib`. `make bridge` also builds an aarch64
`steam.exe` and its test helper into `build/bridge/arm64/` (one `steam.exe` per runtime, as spec §7 has it). Copying
the DLL into game prefixes is the launcher's, later (sub-project 5).

The `steam-bridge` step (before `dxmt`) runs `bridge/check.sh` in arm64 mode (no Steam needed), then
`bridge/probe.sh` in arm64 mode: the x64 `steamprobe.exe` under FEX loads SMITE 2's `steam_api64.dll` in place, with
the bundle's `lsteamclient.dll` as `steamclient64.dll`. It needs **Steam running and logged in** and **SMITE 2
installed** in Steam's default library; without either it fails naming what is missing. It passes on `init: ok`,
`steamid ok`, `persona ok`, an auth ticket of more than 0 bytes with its callback, and `fault: caught` (an access
violation after `SteamAPI_Init` still reaches SEH). The probe runs with `PROBE_REDACT=1`, so the log never holds the
SteamID or the persona name; run it by hand the same way. The x18 hits in Valve's arm64 code are reported, not gated.

## Layout

| Path | What |
|---|---|
| `pins` | Wine tag and commit, FEX commit, and the source of FEX's macOS unixlib |
| `deps.pins` | The FreeType and gnutls tarballs, and lsteamclient's repository and commit |
| `patches/wine/`, `patches/fex/`, `patches/dxmt/`, `patches/lsteamclient/` | The patch series (`git format-patch` output, applied with `git am`): the source of truth |
| `build.sh`, `bundle.sh` | Build, then assemble and sign `wine.app`, and check the result |
| `wine.entitlements`, `Info.plist` | The loader's entitlements and the bundle's identity |
| `check.sh`, `tests/`, `tools/` | The checks, the test programs (`x64-*`, `arm64*`), and the helpers behind G3, G4 and D2 (`winshot`) |
| `export.sh` | Writes commits made in the source trees back to `patches/` |

## Development loop

The patch files are applied to the pins in `build/wine-arm64-src/wine`, `fex` and `dxmt` (git trees on branch
`macneutron`).

1. Edit and commit in `build/wine-arm64-src/<wine, fex or dxmt>`. Any change there makes the next build a "development
   build", which builds the tree as it is and skips the fetch, the patching and the up-to-date check. So does a stash,
   a second branch or a second worktree in that tree. If your patch changes `configure.ac`, run `autoreconf` with
   autoconf 2.73 and commit `configure` in the same patch (as Wine patch 0001 does): the build doesn't run it.
2. `make wine-arm64`, and once (or after a change to a test program or the Swift sources) `make build wine-arm64-tests`.
3. `sh wine-arm64/check.sh <steps>` while working; `make wine-arm64-check` before committing.
4. `make wine-arm64-export` writes the commits back to `wine-arm64/patches/`.
5. Commit the patches in this repo. A commit message says why the change exists, with the failure that made it necessary.

DXMT works the same way. Its tree is `dxmt/pins`' `DXMT_COMMIT` (the Rosetta stack's pin; `build/dxmt-src/dxmt`, that
stack's clone, is never touched) plus `patches/dxmt/`, built for ARM64X with DXMT's own `build-arm64ec.txt` against
this Wine's build tree, with an arm64 LLVM 15 built once into `build/wine-arm64-src/llvm-arm64` by `dxmt/llvm.sh`.
`make wine-arm64` also builds the arm64 `dxil-probe` and `dxil-translate` into `build/wine-arm64/`. A commit in
`build/wine-arm64-src/dxmt` makes the build a development build, and DXMT's version token
(`build/wine-arm64-src/dxmt-install/version`) ends in `+dev` instead of the series hash; `make wine-arm64-export`
writes the commits to `patches/dxmt/`. A DXMT patch's message names the arm64 failure it fixes. Folding the patches
into the fork (and moving the pin) is a separate maintainer step.

lsteamclient works the same way. Its tree, `build/wine-arm64-src/lsteamclient`, is a sparse, blob-filtered checkout of
Proton's `lsteamclient/` folder at `deps.pins`' `LSTEAMCLIENT_COMMIT` (without the Steamworks SDK folders), linked
into the Wine tree as `dlls/lsteamclient` (ignored there, so the Wine tree stays applied; Wine patch 0016 registers
it). Its series is `deps.pins`' `LSTEAMCLIENT_` lines and `patches/lsteamclient/`: a tarball pin doesn't re-fetch it.
Its source is never committed here, only the patches.

Changing the pins or a patch file makes a tree with no work of its own (no change, commit, stash, other branch or
worktree) start over from the series: it is deleted and fetched again.

## Licences

- **Wine** is LGPL-2.1+; our patches to it are too.
  - 0006: citi94's `citi94/wine-macos-arm64` commit `4a50ce17c8` ("ntdll: Handle macOS Apple Silicon W^X ..."), applied
    with `git am`, author kept. Its message has no `Source:` line; this is where it comes from
    (`docs/research/2026-10-02-native-arm64/entitled-trial.md`).
  - 0009: adapted from Madeira's LGPL Wine commits `ac650deca3` and `d88d55eee0` (branch `madeira-lgpl`).
  - 0013: adapted from CodeWeavers' `dlls/winemac.drv/d3dmetal.c` (Brendan Shanks, LGPL-2.1+) and `d3dmetal_objc.m`,
    as published in `athei/wine` branch `cx-26-patched`, and `dappermint/winecx` `713015fa9f`, `13e6a88a02`,
    `565f6386b7` (LGPL).
  - 0015: msync, by Zebediah Figura and Marc-Aurel Zent (LGPL-2.1+): CodeWeavers' CrossOver 26.3 msync as carried on
    `dappermint/winecx` branch `cx/wine1117` at `e0aa380780`, with millia ampora's msync commits there (`8df1826853`,
    `9be392b3b4`, `3a7a712d66`, `307f90fdb1`, `620d8c542f`, `a7ef7b3b01`, `ef72fdb55b`, `6d316146c2`), merged onto
    Wine 11.19. The patch's message lists our changes to it.
  - 0016 (registering `dlls/lsteamclient` in configure) and the other Wine patches are ours.
- **lsteamclient** is Steamworks-SDK-derived: Valve's Steamworks SDK licence (its `LICENSE`), except `cxx.h`, which is
  LGPL-2.1+ (CodeWeavers, from Wine); the bundle carries both in `licenses/lsteamclient/` (`LICENSE`, `NOTE`). Its
  patches are dappermint/winecx's three Mac fixes by millia ampora (`8d188ec0db`, `dada36ebab`, `6cfbd169a5`), each
  naming its source commit, author kept. Whether a release bundle may include it is decided in sub-project 5; until
  then MacNeutron doesn't redistribute it (local builds only). This is not legal advice.
- **FEX** is MIT, and so are our patches to it.
  - 0001: the macOS unixlib helpers, from dappermint's FEX fork, commit `4efc3abc8a`. MIT: the file it patches,
    `Source/Windows/UnixLib/FEXUnixLib.cpp`, keeps its `SPDX-License-Identifier: MIT` header, and the fork carries
    FEX's MIT `LICENSE` at that commit.
  - 0003: Madeira (`willfaust/FEX`, branch `ios-port-2607`) `fdf361f0e`, applied unchanged.
  - 0004: the CASPAL part of Madeira's `ceabf254a`, ported to our pin.
  - 0005: the dual-view JIT memory, derived from Madeira's dual-map commits `fce78cefd`, `61f11e3cc` and `6084de076`
    (the others it lists, `83e12849f`, `87b40c220` and `db4f32768`, are named there as not taken).
  - 0002 is ours.
  - Madeira's commits we use are dated before 2026-08-28. Its `LICENSE-MADEIRA.md` says modifications published before
    then were granted under MIT, irrevocably. A Madeira commit published on or after that date would be GPL-3, so check
    the date before importing another. This is not legal advice.
- Each patch taken or derived from another tree names its source in its message (0006's is given above, since its message
  doesn't). Patch files keep their original authors.
- **DXMT** is LGPL-2.1+; our patches to it are too. 0001 is ours.
- Upstream FEX and DXMT refuse AI-authored contributions: no patches go upstream (issue reports only).
