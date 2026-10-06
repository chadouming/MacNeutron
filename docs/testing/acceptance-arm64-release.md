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

## Gate S follow-up: loading time and the player's settings (Task P2)

2026-10-05. With its settings back, SMITE 2's frame rate recovered (from ~4 FPS), but its engine took 31-97 s to
initialise on 0.1.0 against 16 s on the Rosetta-era runtime.

**Loading.** Each `NtCreateThreadEx` maps a stack and thread data through `map_free_area` → `try_map_free_area`
(`dlls/ntdll/unix/virtual.c`), which tries one fixed `mach_vm_map` per 64 KB step through every range the host owns
without Wine tracking it as a view. A benchmark creating 2,000 threads (`CreateThread`, each sleeping; x64 under FEX,
through `macneutron launch` in a scratch tool folder) made 500 in 0.36 s and only 978 in 600 s on the 0.1.0 Wine;
`WINEDEBUG=+virtual` showed ~2,960 failed probes per allocation through a 185 MB host range above `0x100230000` and 3,567
per process start through the reserved area under the top of the address space, and the perf investigation saw ~7.2
million per allocation once the 385 GB guard region under `0x7000000000` was in the way. Wine patch 0021 asks
`mach_vm_region` for the region in the way after a failed probe and continues past it (to its end bottom-up, to its
start minus the size top-down, aligned; every skipped candidate overlaps it). The benchmark now makes 2,000 threads in
0.71-0.77 s (x64) and 0.22-0.25 s (arm64; Rosetta-era runtime: 0.57 s). Under `+virtual`, a 2,000-thread x64 run
showed at most 345 failed probes per allocation; a second run, summarised with a count of the patch's "skipping host
region" lines, had 622,451 failed probes, each followed by a whole-region skip (none by a 64 KB step), at most 324 per
allocation.

SMITE 2, scratch prefix cloned from one with the good settings, Steam bridge on, `env -i` (engine initialised = from the
log's first line to `Engine is initialized`; lobby = launch to `Took … to LoadMap(…L_MainLobby_P)`):

| Runtime | Engine initialised | Launch to lobby | Lobby FPS (60 s window) |
| --- | --- | --- | --- |
| 0.1.0 | 96.8 s, 44.7 s | 102.4 s, 49.3 s | 35.9, 36.3 |
| with patch 0021 | 9.2 s, 8.9 s | 26.3 s, 24.8 s (includes preparing the prefix in place) | 36.0 |

(Rosetta-era DXMT: 14.5 s. Every run logged in through the bridge (`Result=Success`). In one patched run the game
moved on to the Jungle Practice match lobby 9 s after the main lobby without input from the test, so that run's frame
rate is left out; the 59 FPS measured earlier in this prefix came from a window that also covered that match lobby.
In the main lobby alone, both runtimes run at ~36 FPS.)

**Settings.** The fresh prefix that replaces a Rosetta-era one (renamed `pfx.rosetta`) started SMITE 2 with its
defaults (XeSS, ~4 FPS). The launcher now carries the player's data into it (spec §14, amending §3.4 step 1): the user
folders' `AppData/Local`, `AppData/LocalLow`, `AppData/Roaming`, `Documents` and `Saved Games` files it lacks, cloned,
never overwriting, and the games' `HKCU\Software\<Vendor>` keys from `user.reg`. On a clone of the scratch Rosetta-era
prefix, a launch logged `note: carried the player's data from pfx.rosetta (17 files, 1 registry keys)`; SMITE 2's
`Saved` folder matched the old one, and the Unreal Engine key survived the wineserver's next save of `user.reg`.

## XeSS default (Task X1)

2026-10-05. XeSS's path for GPUs other than Intel's (DP4a) is emulated on Apple GPUs: SMITE 2 with XeSS ran at ~3.8
FPS on every translator, and a fresh prefix makes XeSS its default. Wine patch 0022 adds builtin `libxess.dll` and
`libxess_dx11.dll` with the exports of SMITE 2's (XeSS SDK 2.0.1.41: 72 and 51, same names and order in both views of
the ARM64X module) that report the device unsupported; the launcher loads them (`libxess,libxess_dx11=b`) unless
`MACNEUTRON_XESS=1` (spec §14, amending §§3.6-3.7).

SMITE 2, each run in a fresh scratch compat folder (no settings carried), Steam bridge on (`Result=Success`), `env -i`,
tool folder from `macneutron install` with the new `wine.app`; lobby FPS from 20 s after the lobby's
`LoadMap` (`fps4.py`; its windows, bounded by the log's lines, were 51.4 s and 53.8 s):

| Run | Hemingway.log | Upscaler | Lobby FPS |
| --- | --- | --- | --- |
| default | `LogXeSSRHI: Loading XeSS library 2.0.1 on Apple RHI D3D12`, then `LogXeSSRHI: Intel XeSS effect NOT supported, result: -1`; the process maps the stand-in from `wine.app`, not the game's `libxess.dll` | FSR 3 (`r.FidelityFX.FSR3.Enabled = "1"`) | 60.0 |
| `MACNEUTRON_XESS=1` | `LogXeSSRHI: Intel XeSS effect supported`, `LogXeSSModule: XeSS successfully initialized`; the game's `libxess.dll` is mapped | XeSS (`CallApplySettingFunction XeSS`) | 4.1 |

(The game's defaults differ from the player's settings measured in Task P2, ~36 FPS at 2560x1440 High.) Also run:
`make test` (236 passed), `wine-arm64: up to date` after the rebuild, `bundle.sh`'s assertions (the version-resource
one included: both stand-ins set `VER_`), `make smoke` 15/15, `dxmt/check.sh` (x64 lane) 200 ok 0 FAIL,
`make bridge-check` 15 ok.

## msync shm pages (Task M1)

2026-10-05. A benchmark creating 1,500 threads after a D3D12 device (`allocbench` x64, through the launcher, `env -i`,
msync on, 60 s watchdog per run) hung in 7 of 41 runs on the dev `wine.app` with patches through 0022. Each hang
printed `msync: error: mach_vm_map failed with 3: (os/kern) no space available`, then `wineserver crashed`: the
server's `get_shm()` mapped a new shm page with `VM_FLAGS_ANYWHERE` from an uninitialized address (the kernel searches
from it), and its memset then wrote through that address. 0.1.0 has the same code. Wine patch 0023 starts the search
at 0 and ends the server with a message naming the page if a mapping still fails; on the client side, a failed or empty
reply is never mapped or released, and a page that can't be mapped ends the process instead of handing out NULL plus
an offset. With it, msync on, none of 82 runs hung or printed `mach_vm_map failed` (60 on the development build of
the patch, 20 on the build of the commit that adds it, plus each prefix's first run). Also run on that build:
`wine-arm64: up to date`, `check.sh boot fex g1-threads g1-seh msync x18 dxmt` all PASS, `make smoke` 15/15,
`dxmt/check.sh` (x64 lane) 200 ok 0 FAIL, `make bridge-check` 15 ok.

## Translator-keyed shader cache and replay stamp (Task C1)

2026-10-05. DXMT's translation cache was keyed on `git describe` of its tree and the launcher's replay stamp on
`DXMT/version`: a re-fetch of the same DXMT patches (git am makes new commits) missed every translated function and
forced the replay, and an uncommitted airconv edit kept serving the old translations. Both now follow `lib.sh`'s
`translator_key` (DXMT patch 0003; `DXMT/translator`; spec §14). `wine-arm64/tests/translator_key_test.sh` 17 ok (red
on today's `git describe` keying: 12 FAIL). Two re-fetches of the real DXMT tree (HEADs `a41a976`, `89c7bd7`) gave
one key, `148014f4…`, as did the dev and applied builds (`DXMT/version` `+dev` → `+5bb2319a456d`); a byte in
`src/d3d12` kept it, one in `src/airconv` changed it. A key change without a meson setup regenerated
`dxmt_translator_key.h` and recompiled `dxmt_shader_cache.cpp` alone (17 ninja steps).

SMITE 2 on a clone of the perf study's compat folder (stamp `1fba8d2…+cd6d4065e615 26A434`), `env -i`, bridge on,
`DXMT_SHADER_CACHE_PATH` in scratch, tool folder from `macneutron install`: the first launch logged
`precache: Hemingway-Win64-Shipping.exe.pipelines exit=0 replay: 20730 pipelines (17408 graphics, 3322 compute),
20730 created, 0 failed, 0 bad records, 6375 ms`, stamped `148014f4… 26A434`, and reached the lobby; the cache's one
table is `cache_1987945399250107254` (FNV-1a of the key and `AIRCONV_VERSION`), 27,178 entries. The relaunch logged no
`precache:` line, reached the lobby (bridge `Result=Success`), and left the table at 27,178 entries. Also run:
`make test` 239 passed, `wine-arm64: up to date`, `make smoke` 15/15, `dxmt/check.sh` (x64 lane) 200 ok 0 FAIL,
`make bridge-check` 15 ok.

## XeSS answered by MetalFX: the bridge (XeSS plan, Task 2)

2026-10-06. Wine patch 0024 gives the builtin `libxess.dll` real D3D12 calls: a context per
`xessD3D12CreateContext` on a device with DXMT's `IMTLD3D12DeviceExt` (DXMT patches 0004-0005), one MetalFX temporal
upscaler per context made at `xessD3D12Init`, and `xessD3D12Execute` recording `TemporalUpscale` into the game's
command list. Without DXMT (Wine's own D3D12) `xessD3D12CreateContext` still returns -1. `libxess_dx11.dll` keeps
0022's stand-ins. Jitter and motion vectors follow Intel's XeSS-SR Developer Guide 2.0 (the jitter moves the samples
by -jitter; motion vectors point from the current frame to the previous one) and pass to MetalFX unchanged; the
plan's negated mapping scored below bilinear on the test (2.0x: 18.75 dB against 22.17; 24.68 with Intel's). SMITE 2's
logging run (Task 3) still has to confirm what Unreal passes.

`dxmt/tests/d3d12_xess.cpp` loads `libxess.dll` by full path from a copy of itself (only `libxess=b` makes that the
builtin) and drives XeSS's API at 2560x1440, 64 jittered frames of the spike's scene. On the applied build
(`dxmt/check.sh`, x64 lane, 223 ok 0 FAIL, `dxmt-check: all passed`):

| Mode | Input | PSNR (dB) | Bilinear (dB) |
| --- | --- | --- | --- |
| aa (against each pixel's average) | 2560x1440 | 34.86 | 31.68 |
| quality | 1504x846 | 26.38 | 22.04 |
| balanced | 1280x720 | 24.68 | 22.17 |
| performance | 1112x626 | 25.45 | 21.01 |
| ultraperf | 854x480 | 23.66 | 19.18 |

`cycles` (re-initialised context, destroyed before its list runs, 20 more made and destroyed, a history reset: 22.56
dB against 24.68 converged and 22.17 bilinear), `flags` (bits 5 and 30 accepted, bit 9 -4, XeFX 0.0.0, version 2.0.1,
a destroyed context -8) and `unsupported` on wined3d all ok; Metal's validation layer logged nothing over
`performance cycles`. MetalFX on macOS 27.0.1 never returns a temporal upscaler's memory: a native program creating
and releasing one keeps ~232 MB per upscaler (`currentAllocatedSize`; retain count 2 at creation), so the 20 contexts
grow the GPU memory by ~5.2 GB whatever the bridge releases. Also run: `make test` 239 passed, `make smoke` 15/15,
`make bridge-check` 15 ok, both series applied from a fresh fetch (Wine 24 of 24, DXMT 5 of 5), the translator key
unchanged.

## XeSS answered by MetalFX: before the game run (XeSS plan, Task 2b)

2026-10-06. DXMT patch 0006 keeps the last 4 MetalFX temporal upscalers a device made and hands one that only the
device still holds (its D3D12 object released, every allocator that recorded it reset) to the next
`CreateTemporalScaler` of the same Metal description: macOS 27.0.1's MetalFX never frees one (~232 MB each), so a
game re-initialising XeSS now reuses instead of growing. A reused upscaler's first upscale resets its history. A
TYPELESS colour or output (R16G16B16A16, R32G32B32A32, R10G10B10A2, R8G8B8A8, B8G8R8A8) is read as its float or unorm
variant through a same-layout view; other TYPELESS formats stay refused. Wine patch 0025 only adds notes: the bridge's
lock limit (a destroy waits for at most one call inside that context) and the rulings Task 3 checks (pass-through
jitter and velocity signs, the optimal input as the dynamic minimum, the literal pre-exposure).

New rows, both lanes of `make dxmt-check` (226 ok each, `dxmt-check: all passed`): `upscale typeless` 24.90 dB against
22.17 bilinear (already passed before 0006: DXMT maps R16G16B16A16_TYPELESS to RGBA16Float), `upscale typeless32`
24.90 (refused before 0006), `xess cycles` with the GPU memory judged (a context made while the destroyed one's
upscaler is still in the unsubmitted list gets a new one: +231 MB; 20 contexts made and destroyed: +28 MB, was +5194;
balanced and performance alternating 10 times: +255 MB, was +2572), `xess reuse` (1440x810 textures, content
1280x720 → 1152x648 → 1024x576 kept the upscaler, 23.84 against 20.93; RG32F motion vectors made one new one, 24.66
against 22.17; `recreates 1`), and `xess flags` with real frames for bits 1, 4, 7 and 0 (24.68, 24.68, 24.68, 24.69
against 22.17). Without their Init bits the same frames score 19.09 (NDC), 21.86 (jittered) and 20.52 (high-res), all
below bilinear; inverted depth scores 24.66 either way: this scene barely depends on depth.

## XeSS answered by MetalFX: the pool cap (XeSS plan, Task 2c)

2026-10-06. DXMT patch 0007 caps the upscaler pool by released upscalers (Ruling 7): every upscaler in use stays
pooled, and at most 4 released ones beside them; past that the oldest released one is dropped. 0006 kept the last 4
made, so a live context's upscaler could be pushed out and, once released, never reused. A `static_assert` on
`WMTFXTemporalScalerInfo`'s size (52) makes a new field join `SameTemporalScaler`'s comparison. Wine patch 0026 rewords
the bridge's lock note: a destroy, and the lookups queued behind it, wait for every call whose lookup already holds
the list lock, each one pass or at most one upscaler creation.

Both lanes of `make dxmt-check`: 227 ok each, `dxmt-check: all passed`. `xess cycles` now also keeps one context live
while 5 other settings (aa, quality, performance, ultra performance at 2560x1440, balanced at 1920x1080) are made and
released in turn, then makes the first 4 again: `five 879 rerun 0` MB (0006: `five 1106 rerun 978`), and the live
context still upscales after it, 24.68 against 22.17 bilinear. New rows: `upscale typeless10` (R10G10B10A2_TYPELESS
colour and output) 24.34 against 21.91, and `upscale bad` refusing a B8G8R8X8_TYPELESS and an R16G16_TYPELESS colour
with E_INVALIDARG; both already passed on 0006 (they pin its behaviour). Metal's validation: 0 messages, 6 upscale
modes and 2 XeSS modes ok.

## XeSS answered by MetalFX: compressed scratch, private storage (XeSS plan, Task 2d)

2026-10-06. DXMT patch 0008 gives the bridge's depth, motion vector and output scratch textures lossless compression
(every access uses the scratch's own layout; `DXMT_D3D12_COMPRESSION=0` turns it off). DXMT patch 0009 (Rulings 11
and 12) makes heaps the CPU can't see (DEFAULT, CUSTOM with no CPU pages) Private, with the committed textures on such
heaps and the textures and buffers placed in them; committed buffers and CPU-visible heaps stay Shared; sizes are
still asked for Shared (Private measured the same on the M5 Pro). A 2D UAV texture of a format Metal renders to also
gets RenderTarget usage (MetalFX's output usage is 0x7), so MetalFX writes a UAV-only output directly; the scratch and
copy stay for the outputs it can't write, counted by `DXMT_STATS` as `upscale output copied`.
`DXMT_D3D12_PRIVATE=0` keeps everything Shared. Write/ReadFromSubresource refuse textures on GPU-only heaps.

Both lanes of `make dxmt-check`: `dxmt-check: all passed`, no FAIL. New rows: `upscale direct` (committed UAV-only
output) and `upscale placed` (placed in a DEFAULT heap) 24.90 against 22.17 bilinear with 0 outputs copied (the
scratch path gave 24.90 in Task 2c); `upscale direct` with `DXMT_D3D12_PRIVATE=0` copies (64). `hazard placed-uav`
(a buffer placed in a DEFAULT heap, written by a dispatch, copied to READBACK, mapped) reads 1048576, on our DXMT and
on D3DMetal. Every other upscale and XeSS PSNR is unchanged; `xess cycles` reports `growth 0 ab 227` MB (Task 2c:
`growth 28 ab 255`). Metal's validation: 0 messages in the upscale (8 modes), XeSS (2) and hazards runs.

## XeSS on MetalFX in SMITE 2 (XeSS plan, Task 3)

2026-10-06. SMITE 2 in a scratch prefix (an APFS clone of the Gate S follow-up's player-settings prefix with the fresh
game defaults' `HWGameUserSettings.sav`, which selects XeSS; the clone alone keeps TAA), `env -i`, a tool folder from
`macneutron install` with the dev `wine.app`, Steam bridge on, lobby only. The external display was off: every run
below is on the built-in display, where the game's fullscreen window makes XeSS's output 1728x1117 (balanced, input
864x559), not the player's 2560x1440. The 2560x1440 runs are still owed.

**Logging run.** `MACNEUTRON_LOG=1` doesn't show the bridge's parameter dumps: its `WINEDEBUG=+err,+warn` turns on
channels named `err` and `warn`, not the warn class (`warn+xess` does). Hemingway.log still has the bridge's one-time
messages, through the game's logging callback. The first run found the bridge refusing every frame:
`LogXeSSSDK: Warning: xessD3D12Execute: … depth 0000000000000000, … input 864x559`, then `Failed to execute XeSS,
result: -4` about 50 times a second. Unreal's XeSS plugin initialises with flags 0x101 (high-res motion vectors, auto
exposure) and passes no depth texture, which XeSS's header allows with high-res motion vectors. Wine patch 0027 makes a
colour-sized far-plane depth for MetalFX when the game passes none (MetalFX's validation wants depth and colour the
same size; an output-sized one drew 2 messages a frame). `d3d12_xess`'s `flags` gains Unreal's call (`nodepth`: 24.67
dB against 22.17 bilinear; it failed with -4 before the fix) and runs under Metal's validation in a row of its own (0
messages). With 0027, a fresh clone, `WINEDEBUG=+err,+warn,+loaddll,+steamclient,warn+xess` (pointers and floats
shortened):

```
warn:xess:init output 1728x1117, quality 102, flags 0x101, temp heaps 0 0, pipeline library 0
warn:xess:execute flags 0x101, input 864x559, output 1728x1117; formats colour 26 depth 40 motion 34 output 26
  mask 0; sizes colour 864x560 depth 864x560 motion 1728x1117 output 1728x1120; bases colour 0,0 depth 0,0 motion
  0,0 mask 0,0 output 0,0; depth texture 0, exposure texture 0, mask 0; jitter -0.250000,0.166667 scale 1,1;
  velocity scale 1,1; exposure 1.000000; reset 1
```

and no failed Execute. Conventions from it:
- Velocity in pixels (bit 4 clear), at the output size (bit 0): the motion texture is 1728x1117, R16G16_FLOAT, velocity
  scale 1. The bridge passes them as output pixels, current to previous (Ruling 2); their real units and sign, and the
  NDC Y sign, can't be read off one dump: the maintainer's captures judge them (Task 5).
- Jitter (-0.25, 0.17) in the first frame: input pixels within ±0.5, as XeSS defines it; its sign is likewise for the
  captures. Not jittered motion vectors (bit 7 clear), so the jitter's sign inside them doesn't arise.
- No depth, no inverted depth (bit 1 clear): `DepthReversed` doesn't arise; the bridge's depth is a constant 1.0.
- Exposure: auto (bit 8), no exposure texture (bit 2 clear), `exposureScale` 1.0, so `PreExposure` stays literal
  (Ruling 4): neutral.
- Formats: colour and output R11G11B10_FLOAT (26), motion R16G16_FLOAT; no responsive mask. Init's guessed upscaler
  (RGBA16F) is replaced at the first Execute, once.
- Every base is 0, the output's included (`outputColorBase` 0,0; the output texture is 1728x1120 for a 1728x1117
  output): MetalFX's direct path with a non-zero output offset still hasn't run in a game.

**Measurements** (the same prefix after the logging run; the trace 6 s, `gpu-trace.py --label MetalFX_Temporal`;
lobby FPS by `fps4.py` from 20 s and from 100 s after the lobby's `LoadMap`):

| Run | Lobby FPS (+20 s / +100 s) | Frame period, GPU busy (ms) | Upscale GPU ms per frame (p90) | GPU idle just before / after (ms) |
| --- | --- | --- | --- | --- |
| 1 | 32.04 / 59.36 | 19.73, 17.45 | 0.94 (0.98) | 0.00 / 0.00 |
| 2 | 59.98 / 59.80 | 16.66, 13.85 | 0.94 (0.97) | 0.00 / 0.00 |
| 3 | (118 by the trace) | 8.45, 8.20 | 1.01 (1.07) | 0.00 / 0.00 |
| 4 | 59.97 / 59.80 | 16.63, 14.41 | 0.93 (1.02) | 0.00 / 0.00 |
| `DXMT_STATS=1` | 59.97 / 59.80 | 16.64, 14.33 | 0.95 (1.03) | 0.00 / 0.00 |
| `DXMT_D3D12_PRIVATE=0` | 59.97 / 59.78 | 16.66, 14.59 | 0.97 (1.08) | 0.00 / 0.00 |

- MetalFX labels its passes: the upscale is 3 compute passes a frame (`MetalFX_Temporal_BBR_Pre/Mid/PostProcessing`),
  0.95 ms end to end with no idle inside; the presenter's spatial scaler (`MetalFX_Scale`, `MetalFX_Sharpen`) adds
  0.57 ms. The lobby runs at its 60 FPS cap; run 1 was at ~32 for its first ~90 s, run 3 uncapped (`fps4.py`'s
  frame-counter unwrap fails above ~100 FPS: 107.62 / 35.60). Run 3's lighter frames and run 1's slow start are not
  explained.
- `DXMT_STATS=1`: `upscale output copied` 0 over 46 reports (MetalFX writes SMITE's output directly), 1.0 temporal
  upscale passes a frame. With `DXMT_D3D12_PRIVATE=0`: 12735 copied, FPS unchanged at the cap.
- XeSS init (`Loading XeSS library` to `XeSS successfully initialized`): 1 ms in every run; Intel's own XeSS took 15.0 s
  in the Gate S follow-up's prefix.

**Split decision:** no split needed at 1728x1117 — the upscale costs ~0.95 ms of GPU time a frame and the GPU never
idles before or after it (the spike's ~2.2 ms commit-to-start wait doesn't appear inline). Task 4 doesn't run unless
the 2560x1440 runs say otherwise.

Also run after 0027: both lanes of `make dxmt-check` (`dxmt-check: all passed` twice, 236 ok per lane, no FAIL; every
other upscale and XeSS PSNR as in Task 2d), `make test` 239 passed, `make smoke` 15/15, `make bridge-check` 15 ok,
the Wine series from a fresh fetch (27 of 27, the applied tree), the translator key unchanged. `gpu-trace.py` gains
`--label SUBSTR`.
