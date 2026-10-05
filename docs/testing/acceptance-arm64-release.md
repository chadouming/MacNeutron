# Acceptance: sub-project 5, the arm64-only release

Spec: `docs/superpowers/specs/2026-10-04-macneutron-arm64-release-design.md` (§6.2 R0 and R0b, §9; §14 wins on
conflict). Manual, on the maintainer's Mac (macOS 27, Apple Silicon), with the notary profile `macneutron` (an App Store
Connect API key), the Developer ID identity and the provisioning profile for `net.authspot.macneutron.wine`.

## R0

`release/r0.sh` (Task 1), 2026-10-04, on the staged `build/wine-arm64/wine.app` built at `f386639` (version `dev`, the
MetalFX presenter inside).

- `sh release/r0.sh notarize` (`release/lib.sh` `notarize_and_staple`):
  - `syspolicy_check notary-submission`: 56 warnings, no errors, all "Resources directory contains Mach-o binaries"
    (Wine's `Contents/Resources/bin/*` and `lib/wine/aarch64-unix/*`). Warnings don't stop the script; errors do.
  - Submission `c4a00d9d-aa15-4765-a5a9-07915318f370`: `Accepted` ("Processing complete"). The only submission.
  - `stapler staple`: "The staple and validate action worked!"; `stapler validate`: "The validate action worked!".
  - `syspolicy_check distribution`: "App passed all pre-distribution checks and is ready for distribution."
  - Also checked by hand: `codesign --verify --strict --deep` passes; `spctl -a -vvv -t exec`: `accepted`,
    `source=Notarized Developer ID`.
  - The loader's CDHash, before and after stapling (equal):
    - `before staple: CDHash=58b87f8cf286b82eef4afad6581ce788571e640c`
    - `after staple: CDHash=58b87f8cf286b82eef4afad6581ce788571e640c`
  - Quarantine on `build/release/r0/quarantined/wine.app`: `0081;6ac2f042;Safari;C97E0BFF-657D-4FD2-B401-0B9D5232E03C`.
- `sh release/r0.sh online`: the quarantined copy cloned to `build/release/r0/online/Application Support/wine.app`,
  `arm64-hello.exe` run with the clone's loader as a launchd job (`gui/<uid>`, `net.authspot.macneutron.r0`) in a fresh
  prefix: `wProcessorArchitecture=12 dwPageSize=4096 NtMajorVersion=10`, `PASS arm64-hello`, `status=0`. Afterwards
  the clone's quarantine flags read `00c1` (0x0040 set: Gatekeeper assessed it and let it run), the job was gone and no
  process ran the clone's binaries.
- Offline (2026-10-05T00:45:40Z, run by the maintainer with Wi-Fi and Ethernet disconnected; the guard required
  `api.apple-cloudkit.com` and `ocsp.apple.com` to be Not Reachable): a fresh clone of the quarantined copy at
  `…/offline/Application Support/wine.app` ran `arm64-hello.exe` through launchd: `PASS arm64-hello`, `status=0`.
  Caveat: the online run had already assessed this CDHash, so syspolicyd may have answered from its cache; this proves
  the copy launches with Apple unreachable, not that the stapled ticket alone was used.

## R0b

2026-10-04, with the maintainer. Steam on macOS has no Compatibility tab, so the two mappings were switched in
`config.vdf` with Steam closed (backup kept; restored and checked afterwards): SMITE 2 (2437170) to `r0b-probe`,
Timberborn (1062090) to `r0b-probe-native`, priority 250. Play on each ran only the probe, a thin arm64 binary:

- `r0b-probe`: `arch=arm64 translated=0 argv=…/compatibilitytools.d/r0b-probe/./bin/r0b-probe|launch|waitforexitandrun|…/SMITE 2/Windows/Hemingway.exe|…`
- `r0b-probe-native`: `arch=arm64 translated=0 argv=…/compatibilitytools.d/r0b-probe-native/./bin/r0b-probe-native|passthrough|waitforexitandrun|…/Timberborn/Timberborn.app`

R0b: PASS

## R1, R3, R4, R5: `release/release.sh` and its rehearsal

`release/release.sh` (Task 12, then Task 12b: no build path in the release, and the hardening of Rulings 20 and 22),
2026-10-05, with the signing variables and Steam running and logged in. The runs below were made at `d1972a4`, and
again after the final review's fixes at `83b1c15` (the self-test's four new rows, the zip's unzip check and the
numbers in the table are from `83b1c15`). Nothing was submitted to Apple: the notarized run (R2, L6's notarized row on
the release bundle) is Task 14's.

- `make release VERSION=0.0.1-rc` (at `d1972a4`): `release.sh --check-version` runs before make's prerequisites, so it
  printed only `release: VERSION 0.0.1-rc is not MAJOR.MINOR.PATCH` and make's own `make: *** [release] Error 2`, built
  nothing, and exited 2. `make release VERSION=01.0.0` the same (exit 2).
- R1, `sh release/release.sh --self-test` (at `d1972a4`): 35 `ok`, `PASS release self-test`. Each refusal on its own
  input in a temporary clone whose origin is a local bare clone (the DXMT case with a local bare repository as the
  fork): a version that isn't MAJOR.MINOR.PATCH, one with a leading zero (`01.0.0`, `0.00.1`), `v0.0.0` already a tag,
  `v0.0.2` a tag on origin only (pushed to the local origin, deleted locally), release.sh exiting 2 with only the version
  line (`0.0.1-rc`, `--check-version 01.0.0`) or only the usage line (`0.1.0 --rehearse`, `--rehearse 0.1.0 x`,
  `--self-test x`, `--check-version`, `--rehearse`, `--bogus`, no argument), each README string (`Rosetta 2`,
  `import-gptk`, `doesn't redistribute`), a dirty tree, a HEAD not in origin/main, a tree that isn't applied, a SOURCE
  with `WINE_SERIES=dev`, with a `+dirty` commit or with another commit than HEAD, an unpublished DXMT commit; and the
  passing case of each (`0.10.0` among them). At `83b1c15`: 39 `ok`, the four new ones through a PATH shim for `xcrun`
  (never the real notarytool): a notary profile notarytool can't use (refused with the other exit-1 refusals), a usable
  one, a staple that fails twice and is retried, a staple that keeps failing and stops after six tries.
- `sh release/release.sh --rehearse 0.0.0` (at `d1972a4`, 2 min 20 s; `build/release/rehearse-0.0.0/`, with its
  `REHEARSAL` file):
  - Refusals: READMEs, the four trees `applied`, `DXMT_COMMIT` published on the fork, `wine-arm64: up to date`. The
    rehearsal skips the clean-tree, origin/main and origin tag refusals.
  - The release `wine.app` (`bundle.sh --release`): every assertion passed after stripping (signature, entitlements,
    licences, minos, timestamps, links, x18 counts, builtin markers, CHPE metadata). Its `SOURCE` names HEAD.
  - No build path (Ruling 20): no file in the stripped `wine.app` (bundle.sh, before signing) or in `MacNeutron.app`
    (release.sh, before signing) contains the repository's path, the build folder's or `$HOME/`. Wine's unix and PE
    compiles map `build/wine-arm64-src/` away (`-ffile-prefix-map`: its critical-section names read
    `wine\dlls\kernel32\profile.c: PROFILE_CritSect`); DXMT's `.metal` files compile on stdin
    (`wine-arm64/tools/xcrun-metal.sh`): metal wrote each file's absolute path into the AIR module's
    `air.source_file_name`, which airconv erases before linking (never read), and ignores the prefix maps. Before the
    maps (the assertion added to `ce3e06d`, on the trees built without them), the rehearsal stopped at bundle.sh on 247
    files (`winemetal.so`, `msi.dll`, `d3dx9_33.dll`, …). After: `grep -rlaF -e <repository> -e "$HOME/" MacNeutron.app` → 0 files. What remains under
    `/Users/` is 71 `/Users/runner/…` strings in 6 files (FEX's `libarm64ecfex.dll`, DXMT's front ends and
    `dxmt-replay.exe`), from the downloaded llvm-mingw runtime, built elsewhere.
  - R3: `smoke.sh` on it (`info wine.app: …/build/release/rehearse-0.0.0/wine.app (0.0.0)`): every row PASS (the
    notarized row names the bundle it checked, `build/release/r0/wine.app`, R0's); the bridge probe through an assembled
    tool folder: `init: ok`, `steamid ok`, auth ticket 234 bytes; `present_loop.exe 1280 720 0 0 120 0` on DXMT through
    it: `frames 120, avg frame 8.104 ms` (`8.089 ms` at `83b1c15`).
  - R4: `licences_test.sh --app` on `MacNeutron.app`: `PASS licences_test`, `PASS licences_test --app` (and red by hand
    on a copy without `Contents/Resources/licenses/LICENSE`, on one with neither the README's pointer nor `wine.app`'s
    `licenses/macneutron/LICENSE`, and on one whose `LICENSE.TXT` differs from `wine.app`'s `llvm-mingw/` copy). The
    app: both Swift binaries `arm64` and stripped (`strip -S`: no `OSO` entries, no path under `/Users/`), version
    `0.0.0`, minimum `27.0`, hardened runtime and a secure timestamp on the CLI and the app, no entitlements,
    `codesign --verify --strict --deep` passes, the nested `wine.app`'s CDHash equal to the release bundle's; `spctl`
    rejects it (`Unnotarized Developer ID`), as expected before notarization.
  - The zip (at `83b1c15`): written with `ditto -c -k --norsrc`, so it holds no AppleDouble (`._*`) entries; release.sh
    unzips it with `/usr/bin/unzip` into a temporary folder and `codesign --verify --strict --deep` passes on the
    extracted `MacNeutron.app` and its `wine.app` (`PASS MacNeutron-0.0.0.zip unzips (unzip) to a MacNeutron.app and
    wine.app that verify`; in release mode also `stapler validate` on both). The embedded provisioning profile carries
    no download metadata (`kMDItemWhereFroms`) or quarantine.
  - R5: `PASS sources`. `verify-sources.sh` was also red, by hand, on a wrong `WINE_SERIES`, `FEX_SUBMODULE_fmt`,
    `GMP_SHA256`, `MACNEUTRON_COMMIT` and `LLVM_TAG`, a missing `dxmt-nvapi.tar`, an edited lsteamclient file, an SDK
    file added to `lsteamclient.tar`, a wrong Wine patch count, and a submodule row that names another submodule's
    commit and tar (with SOURCE to match): its commit isn't the gitlink FEX records at its applied commit.

| Size (rehearsal at `83b1c15`) | |
|---|---|
| `wine.app` before stripping | 1,368,024 KB |
| `wine.app` after stripping (unsigned; `.a` files and Wine's developer tools deleted) | 459,108 KB |
| `MacNeutron-0.0.0.zip` (rehearsal, not notarized, no AppleDouble entries) | 139,129,246 bytes |
| `MacNeutron-0.0.0-source.tar.gz` | 106,953,079 bytes |

The rehearsal's `SHA256SUMS` describe unpublished rehearsal files and aren't recorded; the release's go here in Task 14.

## Full runs (Task 14 Step 1)

2026-10-05, with the signing variables and Steam running and logged in; logs in `build/sp5-acceptance/` (first run)
and `build/sp5-acceptance-2/` (second run).

| | `21f2cb4` (before the final review) | `83b1c15` (after its fixes) |
|---|---|---|
| `make test` | 213 passed | 219 passed |
| `make smoke` | 15/15 (notarized row PASS) | 15/15 (notarized row PASS) |
| `make bridge-check` | 15 `ok` | 15 `ok` |
| `make presenter-check` | 12 `ok` | 12 `ok` |
| `make wine-arm64-check` | every step PASS, `dxmt-arm64ec` and `g4-bench` included (17 min) | every step to `dxmt` PASS; `dxmt-present` FAIL (see below) |
| `release.sh --self-test` | 35 `ok` | 39 `ok` |
| `release.sh --rehearse 0.0.0` | — | PASS (above) |

At `83b1c15`, `dxmt-present` failed with `winshot: screencapture of window … failed`: the Mac's screen had locked
(`CGSSessionScreenIsLocked` true at 02:11), and a window capture needs an unlocked screen. `make wine-arm64-check` stops
at a failed step, so `dxmt-present`, `dxmt-arm64ec`, `dxmt-x64` and `g4-bench` were rerun at `83b1c15` with the screen
unlocked (`sh wine-arm64/check.sh dxmt-present dxmt-arm64ec dxmt-x64 g4-bench`, after `make build wine-arm64
wine-arm64-tests dxmt-tests presenter dxmt-tests-arm64ec`: `wine-arm64: up to date`; 15 min): PASS boot, fex, dxmt,
dxmt-present, dxmt-arm64ec, dxmt-x64, g4-bench, orphans. With the first run, every step of `make wine-arm64-check`
passed at `83b1c15`. `PASS orphans` held in both.


## Gate S: SMITE 2

2026-10-05. SMITE 2 (Unreal Engine 5.5.4) on 0.1.0 stopped at "The following component(s) are required to run this
program: Microsoft Visual C++ Runtime". Its bootstrap, `Hemingway.exe`, reads the file version of
`C:\windows\system32\vcruntime140_1.dll` (Wine maps its own builtin for that, whatever the prefix's copy is), and the
builtin had no version resource (`GetFileVersionInfoSize` fails; under the Rosetta-era x86_64 Wine it was 14.50.35719).

Cause: Wine's `tools/makedep.c`. `vcruntime140_1` (and `dpnsvr`) are enabled for `x86_64,arm64ec` only, so in the
`arm64ec,aarch64` build the module is linked for the disabled aarch64 with arm64ec as its link arch, and
`output_module` linked aarch64's resource list, which is empty: the `.res` built from the `VER_` variables went only
into arm64ec's. Fix: Wine patch 0020 links the link arch's resources when the arch is disabled (an ARM64X module is
unchanged and gets its resources once). `bundle.sh` now fails naming any shipped module whose `Makefile.in` sets
`VER_` and that has no `VS_FIXEDFILEINFO`; before the patch it named `vcruntime140_1.dll dpnsvr.exe`.

Verified at the patch's commit: the rebuild relinked only those two modules; `vcruntime140_1.dll` carries 14.50.35719.0
and `dpnsvr.exe` 5.3.0.900; `msvcp140_2.dll` and `kernel32.dll` (ARM64X) still have one `VERSIONINFO`
(`llvm-readobj --coff-resources`). SMITE 2's bootstrap, run with Steam's arguments through a scratch tool folder and
prefix (no Steam bridge), reads `vcruntime140_1.dll`'s version (14.50.35719.0), shows no message box and starts
`Hemingway-Win64-Shipping.exe`. The game then stops at its own error dialog: its log says `Adapter only supports up to
Feature Level 'SM5', requested Feature Level was 'SM6'` (DXMT reports shader model 5.1 by default). `make test` 219
passed, `make smoke` 15/15, `sh dxmt/check.sh` 200 `ok` (all passed), `make bridge-check` 15 `ok`.
