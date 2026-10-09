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
prefix, a launch logged `note: carried the player's data from pfx.rosetta: 17 files, 1 registry keys`; SMITE 2's
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
command list. On a device without DXMT's interface `xessD3D12CreateContext` still returns -1 (the check's run passes an
object without it: under wined3d, Wine made no D3D12 device). `libxess_dx11.dll` keeps
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
a destroyed context -8) and `unsupported` (an object without DXMT's interface) all ok; Metal's validation layer logged nothing over
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
`macneutron install` with the dev `wine.app`, Steam bridge on, lobby only. The external display was off: every run below
is on the built-in display, where the game's fullscreen window makes XeSS's output 1728x1117 (balanced, input 864x559),
not the player's 2560x1440. The 2560x1440 runs are Task 3c (Ruling 15). *Corrected in Task F3:* run 3 left the lobby for
the Jungle Practice match (`game-m3.log:5485` LoadMap of the match lobby with transition tag JunglePractice, `:11790`
SeamlessTravel to the practice map), so its trace is an in-match frame, not an uncapped lobby; it is the only arm64
in-match trace (1728x1117 output, XeSS Balanced, input 864x559). By the resolution study's evidence (its leading
hypothesis, not a verdict), the in-game Resolution setting doesn't change the render size in borderless (windowed
fullscreen, `FullscreenMode=1`): the game saves it, but the back buffer stays at the desktop size, so only resolution
scale or the upscaler's quality changes what the GPU renders (the XeSS plan's resolution study; in the one logged
session with a real change, on 0.1.0, 2560x1440 → 1920x1080 and back, FPS stayed at 86-92 and the presenter saw no
smaller drawable).

**Logging run.** `MACNEUTRON_LOG=1` doesn't show the bridge's parameter dumps: its `WINEDEBUG=+err,+warn` turns on
channels named `err` and `warn`, not the warn class (`warn+xess` does; since Task 3b the launcher's logging mode sets
`warn+all,+loaddll,+steamclient`, Ruling 18; since Task FU that is `MACNEUTRON_LOG=2`, and `MACNEUTRON_LOG=1` sets
`warn+all,warn-seh,+loaddll,warn+steamclient`). Hemingway.log still has the bridge's one-time messages, through the
game's logging callback. The first run found the bridge refusing every frame:
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

and no failed Execute. Conventions from it (Ruling 16: the jitter's sign and the high-res motion vectors' units and sign
are settled in Task 5's captures, not from a log):
- Velocity in pixels (bit 4 clear), at the output size (bit 0): the motion texture is 1728x1117, R16G16_FLOAT, velocity
  scale 1. The bridge passes them as output pixels, current to previous (Ruling 2); their real units and sign, and the
  NDC Y sign, can't be read off one dump: the maintainer's captures judge them (Task 5).
- Jitter (-0.25, 0.17) in the first frame: input pixels within ±0.5, as XeSS defines it; its sign is likewise for the
  captures. Not jittered motion vectors (bit 7 clear), so the jitter's sign inside them doesn't arise.
- No depth, no inverted depth (bit 1 clear): `DepthReversed` doesn't arise; the bridge's depth is a constant 1.0.
- Exposure: auto (bit 8), no exposure texture (bit 2 clear), `exposureScale` 1.0, so `PreExposure` stays literal
  (Ruling 4): neutral.
- Formats: colour and output R11G11B10_FLOAT (26), motion R16G16_FLOAT; no responsive mask. Init's guessed upscaler
  (RGBA16F) never matched them: since Wine 0028 (Ruling 17) Init makes none and the first Execute makes it from the
  game's textures.
- Every base is 0, the output's included (`outputColorBase` 0,0; the output texture is 1728x1120 for a 1728x1117
  output): MetalFX's direct path with a non-zero output offset still hasn't run in a game.

**Measurements** (the same prefix after the logging run; the trace 6 s, `gpu-trace.py --label MetalFX_Temporal`;
lobby FPS by `fps4.py` from 20 s and from 100 s after the lobby's `LoadMap`, run 3's corrected by `dxmt/tools/fps.py`),
all at 1728x1117; the 2560x1440 runs are Task 3c (Ruling 15):

| Run | Lobby FPS (+20 s / +100 s) | Frame period, GPU busy (ms) | Upscale GPU ms per frame (p90) | GPU idle just before / after (ms) |
| --- | --- | --- | --- | --- |
| 1 | 32.04 / 59.37 (30 s window) | 19.73, 17.45 | 0.94 (0.98) | 0.00 / 0.00 |
| 2 | 59.98 / 59.80 | 16.66, 13.85 | 0.94 (0.97) | 0.00 / 0.00 |
| 3 (match) | — / 118.96 over the 8 s fps.py can count (118 by the trace) | 8.45, 8.20 | 1.01 (1.07) | 0.00 / 0.00 |
| 4 | 59.97 / 59.80 | 16.63, 14.41 | 0.93 (1.02) | 0.00 / 0.00 |
| `DXMT_STATS=1` | 59.97 / 59.80 | 16.64, 14.33 | 0.95 (1.03) | 0.00 / 0.00 |
| `DXMT_D3D12_PRIVATE=0` | 59.97 / 59.78 | 16.66, 14.59 | 0.97 (1.08) | 0.00 / 0.00 |

- - MetalFX labels its passes: the upscale is 3 compute passes a frame (`MetalFX_Temporal_BBR_Pre/Mid/PostProcessing`),
  0.95 ms end to end with no idle inside; the presenter's spatial scaler (`MetalFX_Scale`, `MetalFX_Sharpen`) adds 0.57
  ms. The lobby runs at its 60 FPS cap; run 1 was at ~32 for its first ~90 s. Run 3 was in the Jungle Practice match at
  about 118-121 FPS (the trace's 8.45 ms period; log samples of the draft and the match read 110-133), not an uncapped
  lobby, which explains its lighter frames. *Corrected in Task F3:* `fps4.py`'s 35.60 for run 3's +100 s window is a
  frame-counter wrap artefact, not a rate: Unreal logs the frame counter mod 1000, and fps4.py counted log gaps of 9-29
  s (over 1000 frames at 120 FPS) mod 1000. `dxmt/tools/fps.py` leaves out gaps that could hide a wrap: 118.96 for that
  window (over the 8 s of 72 it can count), and the lobby runs as before within 0.2 FPS. Its +20 s window (107.62) mixes
  the lobby's 60 FPS with draft and loading bursts of 120-310 (fps.py: 139.18 over the 19 s it can count), so it isn't a
  rate of either. Run 1's slow start is not explained.
- `DXMT_STATS=1`: `upscale output copied` 0 over 46 reports (MetalFX writes SMITE's output directly), 1.0 temporal
  upscale passes a frame. With `DXMT_D3D12_PRIVATE=0`: 12735 copied, FPS unchanged at the cap.
- XeSS init (`Loading XeSS library` to `XeSS successfully initialized`): 1 ms in every run; Intel's own XeSS took 15.0 s
  in the Gate S follow-up's prefix. The MetalFX upscaler is made at the first Execute (Ruling 17), outside that
  interval: ~13 ms warm, ~45 ms the first in a process.

**Split decision:** no split needed at 1728x1117 — the upscale costs ~0.95 ms of GPU time a frame and the GPU never
idles before or after it (the spike's ~2.2 ms commit-to-start wait doesn't appear inline). Task 4 doesn't run unless
the 2560x1440 runs say otherwise.

Also run after 0027: both lanes of `make dxmt-check` (`dxmt-check: all passed` twice, 236 ok per lane, no FAIL; every
other upscale and XeSS PSNR as in Task 2d), `make test` 239 passed, `make smoke` 15/15, `make bridge-check` 15 ok,
the Wine series from a fresh fetch (27 of 27, the applied tree), the translator key unchanged. `gpu-trace.py` gains
`--label SUBSTR`.

### Built-in display session (Task 3c)

2026-10-07, 12:13-12:39, the built-in display only (the external one is unavailable). SMITE 2 through a scratch tool
folder from `.build/release/macneutron install` with the current dev `wine.app` (DXMT 0029, Wine 0029), `env -i`,
Steam bridge on, main lobby only, camera idle. Prefixes are APFS clones of Task 3's `compat-l3` (fresh game defaults:
XeSS Balanced, borderless 1728x1117). Each run: wait for the lobby's `LoadMap`, bring the game window to the front
(System Events, every 10 s; the game was frontmost at the trace in every run but `blits1`), wait 60 s (150 s for
`bounds`), record a 6 s Metal System Trace, copy Hemingway.log, stop (`wineserver -k`/`-w`, `WINEMSYNC=1`; no
leftover pids after any run). Every run had `DXMT_STATS=1`; from `base2` on its report was saved under `DXMT_DXIL_DUMP`
(`base1`/`blits1` had no dump folder, so no report).
Frame period and GPU busy are `gpu-trace.py`'s medians (p90 from the same per-frame lists); FPS is `dxmt/tools/fps.py`
from 20 s after the lobby's `LoadMap` for 60 s (it includes the trace, except for `bounds`, whose trace ran ~150 s after
the lobby); the upscale is `--label MetalFX_Temporal`.

**Uncapping the lobby.** The fresh `.sav` has no `LobbyMaxFPS` entry, so the game applies its 60 FPS lobby cap. The
maintainer's old `.sav` (sp5/perf's `compat-x`) stores `LobbyMaxFPS` = `"0"` (version 1). The runs after `blits1`
use the fresh `.sav` with that one entry added to its `SavedSettingVersions` and `SavedSettingsConfig` maps (each
map's size and count adjusted; nothing else changed); the game loaded it and ran the lobby at 65-72 FPS. `base1` and
`blits1` ran before that, at the cap.

| Arm | Setup | FPS (fps.py / stats median) | Frame period ms (p90) | GPU busy ms (p90) | Upscale GPU ms (p90) | Timestamps given their own encoder per frame |
| --- | --- | --- | --- | --- | --- | --- |
| `base1` (capped) | default | 59.43 / — | 16.65 (17.07) | 13.50 (13.76) | 0.95 (0.98) | — |
| `blits1` (capped) | `DXMT_D3D12_TIMESTAMP_BLITS=1` | 59.30 / — | 16.62 (17.10) | 14.18 (14.53) | 0.94 (1.01) | — |
| `base2` | default | 67.96 / 65.5 | 14.59 (15.20) | 13.76 (14.12) | 0.95 (0.98) | 2.0 |
| `blits2` | `DXMT_D3D12_TIMESTAMP_BLITS=1` | 66.43 / 65.0 | 15.05 (15.65) | 13.90 (14.26) | 0.93 (0.97) | 100.6 |
| `base3` | default | 68.34 / 66.3 | 14.58 (15.20) | 13.75 (14.12) | 0.94 (0.97) | 2.0 |
| `blits3` | `DXMT_D3D12_TIMESTAMP_BLITS=1` | 66.92 / 65.1 | 15.03 (15.60) | 13.91 (14.24) | 0.85 (0.95) | 100.8 |
| `r-xess` | RetinaMode, ini windowed 2560x1440 (output inferred), XeSS Balanced | 55.93 / 55.9 | 17.76 (18.59) | 16.56 (16.96) | 1.76 (1.93) | 2.0 |
| `r-taa` | as `r-xess`, TAA | 36.63 / 36.9 | 26.45 (27.78) | 24.86 (25.34) | none (no temporal upscale) | 2.0 |
| `bounds` | `DXMT_DXIL_BOUNDS=off` | 68.52 / 67.7 | 14.54 (15.20) | 13.77 (14.13) | 0.93 (0.96) | 2.0 |

- **B4 (timestamps ride the next encoder) is kept.** Uncapped A/B/A/B: `DXMT_D3D12_TIMESTAMP_BLITS=1` gives 100.6-100.8
  timestamps their own encoder per frame (≈80 "several waiting", 16 "end of call", 4.7 "next encoder takes none")
  against 2.0 by default. It costs 0.45-0.47 ms of frame period (14.58-14.59 → 15.03-15.05), 0.15 ms of GPU busy and
  0.22-0.25 ms more GPU idle between encoders; 1.5 FPS by fps.py. The two default runs agree within 0.01 ms, as do
  the two blits runs; the GPU's clock state isn't controlled, though (the counter run below, same default settings,
  was 1.1 ms faster), so the 0.45 ms holds for this state and the sign for all. The capped pair isn't a measure of
  either (frame time is the cap's), and `blits1`'s window wasn't frontmost at the trace.
- **The split is still not needed (Task 4 doesn't run).** At 1728x1117 the upscale is 0.85-0.95 ms; at the 2560x1440
  arm (inferred output) it is 1.76 ms (p90 1.93), under the ≤ 5 ms criterion, and the GPU idle just before and just
  after it is 0.00 ms (p90 0.00) in every run with the upscale. The Retina arms' window and output size is the ini
  setting, not a logged 2560x1440: with RetinaMode the game saw a 3456x2234 desktop (`CacheSupportedResolutions`) and
  logged `ApplyResolution - Applying Resolution 1117,1728` four times in each Retina run (game-r-xess.log and
  game-r-taa.log :1401/1422/1454/1901), the same as `base2`; no log line says 2560x1440 (the `.sav`'s `Resolution`
  entry is an index, left alone, and `WINEDEBUG=warn+xess` printed nothing without the launcher's logging mode). The
  output is inferred at ≈3.6-3.7 MP: 1.76 ms is 1.85-1.89 times the 0.93-0.95 ms at 1728x1117 (2560x1440 predicts 1.81
  ms, a 1728x1117 output 0.95 ms, a 3456x2234 one ≈3.8 ms), and the TAA arm, the same prefix but for the `.sav`'s
  `XeSS` entry, runs at `p8`'s 2560x1440 TAA lobby numbers (26.45/24.86 against 26.17 p10/27.44 median and 25.23 ms
  frame/busy, resfps/bound.md:39). Even a 3456x2234 output stays under 5 ms.
- **XeSS Balanced vs native TAA at 2560x1440 (lobby; ini size, output inferred above):** 17.76 against 26.45 ms frame
  period, 16.56 against 24.86 ms GPU busy: XeSS through the bridge takes 8.7 ms off the lobby frame (55.9 against 36.6
  FPS). The TAA arm drops the `.sav`'s `XeSS` entry (both maps); no `MetalFX_Temporal` interval ran and DXMT counted
  no temporal upscale. Its 26.45/24.86 ms match sp5's `p8` 2560x1440 TAA lobby (26.17 p10 / 25.23 ms busy,
  resfps/bound.md:39). This is a lobby number: gframe's ≈ −2 ms estimate is for a match frame, which this session didn't
  measure.
- **Bounds checks: no-go for the `texture_buffer` form (gate 2).** `DXMT_DXIL_BOUNDS=off` keys its own shader cache
  (`d3d12_shader_cache.cpp`), so it compiled afresh: its first stats report ran 8.4 FPS, and FPS was mostly 67-70 (one
  61.7 report) for the last 40 s before the trace (150 s after the lobby; fps.py's 68.52 covers +20-80 s, the compile
  settling). Frame
  14.54 ms and GPU busy 13.77 ms against 14.58-14.59 and 13.75-13.76 for the default; the Vertex channel is 8.0 % of
  the window (≈1.16 ms a frame) against 7.8-7.9 % (≈1.14-1.15 ms): GPU busy and Vertex within ±0.03 ms (frame
  0.04-0.05 ms), far below the 0.15 ms threshold. This is the lobby, not the m3/E7 match spot gate 2 names; Ruling 35
  closes gate 2 on it (the static estimate, ≤ 0.1 ms, agrees).
- **GPU counters (gate 1): not obtained.** A run with `--instrument 'Metal GPU Counters'` added to the Metal System
  Trace template (`--attach`) recorded the `gpu-counter-info` and `gpu-counter-value` tables with no rows. Its frame was
  13.50 ms (GPU busy 12.78 ms, upscale 0.78 ms), faster than the default runs, which isn't explained. Gate 1 stays open.

## DXMT runtime fixes from the reviews and studies (XeSS plan, Task F1)

2026-10-06 (Ruling 21). DXMT patches 0010-0015, each with a row in `dxmt/check.sh`:
- 0010: ExecuteIndirect's resolver writes a VERTEX_BUFFER_VIEW argument at the slot's entry in the table of the slots
  the pipeline uses (it wrote the raw slot). `indirect vbv-gap` (slot 2 of a pipeline using slots 0 and 2) drew the
  IA-bound tags before (`2,0:207 3,0:200 2,1:208`) and draws D3DMetal's `2,0:107 3,0:300 2,1:108` now.
- 0011: a placed texture or buffer holds a private reference on its heap, so an app's release of the heap no longer
  takes it out of the residency set while its resources live (`Release` still answers 0, as on D3DMetal).
  `hazard heap-released` renders, samples and reads back 257 before and after (a destroyed heap showed nothing here);
  `DXMT_STATS` counted `heaps destroyed 1` before and none now.
- 0012: buffer `Map` refuses every heap the CPU can't see (a buffer placed in a CUSTOM heap with no CPU pages returned
  S_OK and a null pointer; D3DMetal maps it); `DXMT_D3D12_PRIVATE=0` also drops the RenderTarget usage 0009 gave
  renderable 2D UAVs (Ruling 14).
- 0013: the upscale's begin and end blits, and any blit or compute encoder left without commands, carry a 4-byte fill
  of a scratch buffer, as timestamp blits do, so Metal can't drop them with their fences.
- 0014: `DXMT_STATS` counts `upscale input copied` (a depth/stencil depth: 64 of 64; readable inputs: 0).
- 0015: ResizeBuffers keeps the swapchain flags it's given (`resize flags 0x2 0x2`; `0x0 0x0` before), and vsync
  pacing re-reads the window's display's refresh rate at ResizeBuffers and on leaving fullscreen (it was the creation
  display's, and off after leaving fullscreen). Not tested: no check moves a window between displays.

Bridge rows: `upscale direct` and `placed` match the copy path (`DXMT_D3D12_PRIVATE=0`) within 0.05 dB (24.90 each);
`upscale direct-offset` writes at (64, 32) of a 2624x1472 output directly (0 copies) at 24.90, as the copy path;
`xess nodepth` reads the bridge's own depth back: every texel 1.0 (inverted: 0.0).

Both lanes of `make dxmt-check`: `dxmt-check: all passed` twice, 244 ok per lane (Task 3b: 238), no FAIL; every
other upscale and XeSS PSNR as in Task 3b. The translator key is unchanged (no airconv change).

## Timestamps ride the next encoder (XeSS plan, Task F4)

2026-10-06 (Ruling 23; F1's leftovers, Rulings 24-25). DXMT patches 0016-0019, each with a row in `dxmt/check.sh`:
- 0016: ResizeBuffers keeps the FRAME_LATENCY_WAITABLE_OBJECT flag a swapchain was created with (DXGI can't add or
  remove it later): `resize waitable 0x42 1` (`0x2 0` before: the flag and the waitable object were lost).
- 0017: `DXMT_STATS` says why each lone timestamp blit was needed (`lone timestamps (another counter buffer)`,
  `(several waiting)`, `(next encoder takes none)`, `(end of call)`) and, for the base-pass merge (B6), why a render
  pass that could have joined the previous one's Metal pass didn't (`render pass merges refused (timestamps)`,
  `(resolver)`, `(barrier)`, `(attachments)`, `(other)`).
- 0018: each queue samples every timestamp, whatever its query heap, into one counter buffer (a 4096-slot ring: Metal
  allows 32 counter buffers per process, measured), so an encoder takes the timestamps waiting before it at its start
  and its own at its end in one attachment; those before a clear or resolve pass, or at the end of the call, ride the
  previous encoder's end. The queue writes each slot's value to its queries once the command buffer completes, and
  CPU resolves copy them. `DXMT_D3D12_TIMESTAMP_BLITS=1` restores the heaps' own counter buffers.
- 0019 (review fix): a call that samples timestamps owes that write on the CPU, as resolves already did, so its
  queue's fences signal after it (an app may release the query heap once the fence passed): `hazard sampled`, a
  timestamp sampled without a resolve, then Signal, counts `fence signals deferred to the CPU 1` (none on 0018).

Counts before (the same build with only 0017; `DXMT_STATS`, each run alone):

| Run | Lone timestamp blits | Why |
|---|---|---|
| `d3d12_hazards ts-many` (201 timestamps, two heaps, render/compute/copy, list start and end; the row's final form, 203 with a second heavy dispatch, counts 53 with the switch: + 1 several waiting) | 52 | 49 another counter buffer, 3 end of call |
| `d3d12_timestamp` | 3 | end of call (a list of timestamps alone) |
| `d3d12_hazards ts-start` | 2 | several waiting |
| `d3d12_hazards two-heaps` | 2 | another counter buffer |
| `d3d12_hazards after-own-blit` | 1 | another counter buffer |
| `d3d12_hazards deferred` | 1 | end of call (a list of a timestamp alone) |

After 0018: ts-many, ts-start, two-heaps and after-own-blit 0; d3d12_timestamp 1 and deferred 1 (calls with no other
encoder: one blit for all their timestamps). With `DXMT_D3D12_TIMESTAMP_BLITS=1`, the counts before. ts-many's 203
values are nonzero and in submission order, and the gap around its heavy dispatch is at least half the same dispatch's
time measured right after it in the list (about 134 000 ticks each; the GPU's clock moves the dispatch between 62 000
and 1 400 000 over runs, so a reference from another submission failed 1 run in 4 with DXMT_D3D12_OVERLAP=1).
`upscale timestamps` (two timestamps before each of 64 MetalFX upscales, one after) takes none of its own (128 with
the switch), in order, the upscale (about 7 ms) between the last two, and no validation message.

F1's leftovers: `hazard heap-released` places a texture in each of two heaps, releases both heaps, and the first
texture after the readback (`heaps destroyed 1`: held while it lives, freed after; 2 with the texture's hold removed,
measured on a dev build); `indirect vbv-gap` adds a VERTEX_BUFFER_VIEW for slot 5, above the pipeline's highest
used slot, and the next record still draws its own tags; `d3d12_xess`'s HookDepth table is pinned by a comment to
IMTLD3D12CommandListExt's 4 methods; the `d3d12_api library` row compares D3DMetal's lines but for its
`serialize-race` line, and pins ours to `overflow 0` (Ruling 25).

Both lanes of `make dxmt-check` on the applied build: `dxmt-check: all passed` twice, 246 ok per lane, no FAIL. The
translator key is unchanged (no airconv change).

## Shader translator fixes, one translator-key change (XeSS plan, Task F2)

2026-10-07 (Rulings 21-22; F4's leftovers). DXMT patches 0020-0026, each with a row in `dxmt/check.sh`. 0022-0025
change airconv, so the translator key changes once, on purpose (Ruling 22): `e66d8fd3…` → `b3eea49c…`; every user's
shader cache rebuilds once.
- 0020: a queue that never sampled timestamps (no counter ring) resolving timestamps another queue sampled read the
  heap's unused counter buffer: `hazard ts-queues` (queue A samples, queue B resolves behind a fence) read `0` before,
  `1` now. Only a queue whose ring couldn't be created falls back to the heap's buffer.
- 0021 and 0023: vertex buffer slots a pipeline reads but nobody bound point at a zeroed buffer with stride 0 (D3D12: a
  4 KB one, also for null VERTEX_BUFFER_VIEW arguments of ExecuteIndirect; D3D11: the zeroed dummy constant buffer),
  and pulled vertex attributes no longer check for a null buffer (the branch cost 3-5 % of vertex fetch in the
  vertex-fetch study). Unbound slots now read zeros widened by the format, as on D3DMetal: `vsread ia` and
  `d3d11 ia` (R32G32B32A32 bound, R32G32 and R32G32B32A32 never bound, R32_UINT a null view) read
  `1,2,3,4 0,0,0,1 0,0,0,0 0,0,0,1` (before: `0,0,0,0` for every unbound attribute; D3DMetal: as now).
  `indirect vbv-null` (a null view argument after a bound one): `3,0:300`, the stale tags not read. 0026 looks the
  zeroed buffer up once per vertex buffer table, not once per unbound slot and command (each lookup takes a lock).
- 0022: a non-precise `mad` (DXIL FMad without `!dx.precise`) becomes one `air.fma`, as Metal Shader Converter does;
  precise ones stay a multiply and an add. `dxil/mad.hlsl` (a = 1 + n 2^-13, b = 1 - n 2^-13, c = -1): against a CPU
  reference, `mad fused 64 precise 64 of 64` (before: 32, the odd threads rounding the product first); the group
  matches D3DMetal (it differed at word 0 before). Offline, four SMITE 2 shaders: a vertex shader 12 fma, a pixel
  shader 38, a compute shader 82, each replacing a multiply and an add.
- 0024: DXIL barriers without the sync bit (GroupMemoryBarrier 8, AllMemoryBarrier 10, DeviceMemoryBarrier 2)
  emit `air.atomic.fence` (they emitted nothing below Metal 3.2; mode 8 nothing at all). Offline: `dxil/barriers.hlsl`
  0 → 3 fences, SMITE 2's compute shader with 12 mode-8 barriers 0 → 12. The group matches D3DMetal (a guard: the
  results can't depend on a fence alone), so the fences have a row of their own: `dxil-translate --flags` now lists
  each `air.atomic.fence` (flags:scope) and counts `air.wg.barrier`, and dxmt-check wants `fence=2:1,5:3,7:3
  barrier=3` for `barriers.dxil` (RED against airconv at 0023: `fence=- barrier=3`).
- 0025: `DXMT_DXIL_BOUNDS=off` (measurement only) drops the typed `Buffer<>` read checks and the raw and structured
  ones; the shader cache keys it apart. `bounds` with it reads past views (`5 6 7 8 19 20 21 22 21 22 23 24 20 21 0 0
  13 14 15 16 17 18 19 20 20 19 20 0 1 2 3 4`, every read inside the test's buffer) and inside them as without it;
  `vsread` reads as without it. Offline, selects in SMITE 2's vertex shader 82 → 13, compute 79 → 24.

Both lanes of `make dxmt-check` on the applied build (0026): `dxmt-check: all passed` twice, 257 ok per lane (225
rows, 32 dxil-probe lines), no FAIL. `vbv-null` is one more ExecuteIndirect with a resolver pass, so the stats rows now
want 16390 calls, 3 resolve passes and 14 with `DXMT_D3D12_INDIRECT=icb`.

## Presenter, records and tools (XeSS plan, Task F3)

2026-10-07 (Rulings 21, 28). DXMT patch 0027; the translator key is unchanged (`b3eea49c…`).
- F2's open question: DXC's `-Gis` (IEEE strictness) marks every `mad` precise. `dxil/mad.hlsl` compiled with it has
  `!dx.precise` on both FMads (without it, one), and the entry point's shader flags read 16 in both (raw buffers;
  DisableMathRefactoring, 2, is never set), so 0022's `dx.precise` test already keeps `-Gis` shaders unfused and a
  module-flag gate would never fire. No airconv change. The dxmt-check row that counts the fast-math flags of vertex
  and geometry shaders is now named for what it checks: `vertex and geometry shaders carry no reassoc, contract or
  arcp flags` (a non-precise mad's `air.fma` is an explicit call).
- 0027: `IASetVertexBuffers` with no views unbinds the slots (it returned early, leaving the old views bound). `vsread
  unbind` (slots 1 and 3 bound to data, then `IASetVertexBuffers(1, 3, NULL)`) read `1,2,3,4 1,2,0,1 3,4,1,1.5
  1.07374e+09,0,0,1` before and reads `1,2,3,4 0,0,0,1 0,0,0,0 0,0,0,1` now, as unbound slots do. D3DMetal ignores
  such a call (it reads the old data), so the row has no D3DMetal twin.
- The presenter still scales into a texture of its own and copies it into the overlay's drawable (gframe's B1 not
  done): a CAMetalLayer drawable has managed storage (`framebufferOnly` or not; measured on this Mac), and MetalFX's
  spatial scaler wants a private output. Scaling straight into the drawable drew the right picture but 199 Metal
  validation messages in 200 frames ("outputTexture must have private storage mode"), so it isn't shipped.
- Task 3's section above is corrected: run 3 was the Jungle Practice match, `fps4.py`'s 35.60 is a counter-wrap
  artefact (about 118-121), and by the resolution study's evidence the in-game Resolution in borderless doesn't change
  the render size.
- `dxmt/tools/fps.py` (from `fps4.py`): frame rate from an Unreal log's mod-1000 frame counter, leaving out log gaps
  that could hide a wrap (longer than 1000 frames at 1.5x the window's highest rate between lines 0.5-2 s apart). Run 3
  +100 s: 118.96 (fps4.py 35.60); the lobby windows of Task 3 move by at most 0.2 FPS (run 1's +100 s reads 59.37
  under both tools).
- `dxmt/tools/gpu-trace.py` stops with `too few whole frames` when a trace has fewer than 2 whole frames (4 in all: the
  first and last are cut off, and a frame period needs two), instead of a `statistics` traceback.

Both lanes of `make dxmt-check` on the applied build (0027): `dxmt-check: all passed` twice, 264 ok per lane, no FAIL.

## The final review's findings (XeSS plan, Task FR)

2026-10-07 (Ruling 32). DXMT patches 0028-0029, Wine patch 0029; the translator key changes a second time before any
release: `b3eea49c…` → `735ba5c4…`.
- 0028: DeviceMemoryBarrierWithGroupSync and AllMemoryBarrierWithGroupSync fence device memory at Metal 3.1 (D3D12's
  version), then wait for the group, as Metal Shader Converter does; the fence used to come only at 3.2, so a group
  could read another group's stale results after the barrier. `dxil/barriers.hlsl` translates to
  `fence=2:1,5:3,5:3,7:3,7:3 barrier=3` (was `fence=2:1,5:3,7:3`). D3D11's DXBC sync does the same, and its
  GroupMemoryBarrier (a TGSM fence without the group sync) fences now (it emitted nothing): `dxbc/sync.hlsl`, compiled
  by Wine's D3DCompile into `sync.dxbc`, gave `fence=-` and gives the same line. `dxil-translate` takes DXBC compute
  shaders (`.dxbc`) for this.
- 0029: a command allocator released without a Reset runs its encoders' destructors. An XeSS Execute recorded into
  such an allocator's list kept its MetalFX upscaler from DXMT's pool: the next context's first Execute grew GPU
  memory by 232 MB; now by 0.
- Wine 0029 (`libxess`): Execute refuses (-4) a missing exposure texture or responsive mask that Init's flags ask for
  (it returned 0); the calls MetalFX has nothing for (exposure multiplier, responsive mask clip, legacy scale factors,
  network choice, dumps, profiling) answer a live context -7 NOT_IMPLEMENTED (was -8); native AA at 1728x1117 asks
  for 1728x1117 (was 1728x1116, a whole-frame resample: 35.26 dB against 31.83 now, 29.27 against 26.77 then); a
  callback registered at ERROR gets refusals at ERROR (it got none); xessGetPipelineBuildStatus answers -12 after Init
  (was 0).
- Tests that couldn't fail: `heap-released` no longer prints the heap's Release() answer (always 0, Ruling 24; the
  DXMT_STATS row discriminates); `nodepth` no longer reads the inverted depth back: fresh memory reads 0.0 uncleared
  too (a build that skipped that clear passed, even with a far plane at 1.0 released just before); the check's
  `lone` prints `no stats` when a run wrote none.
- The launcher's player-data carry: the rename writes `player-data-pending` before it moves `pfx`, and only that
  record carries, so an interrupted re-preparation of an arm64 prefix takes nothing from a `pfx.rosetta` beside it,
  and a launch stopped between the rename and the preparing stamp still carries; files are copied under a temporary
  name and renamed into place; several old users all go to the one user Wine reads.
- `licenses/NOTICES.md` quotes the Intel notice of the XeSS headers `libxess.dll` is built from; `licences_test.sh`
  checks for it.

Both lanes of `make dxmt-check` on the applied build (DXMT 0029, Wine 0029): `dxmt-check: all passed`, 264 ok per lane,
no FAIL. (The first ARM64EC run's replay row read 0: the launcher log rotated at 1 MB between that run's line count and
its replay, so the row read the new, one-line file; the replay line was in `launcher.log.1`, and the lane rerun passed.)

## CMAA2 post-AA in the presenter (XeSS plan, Task CMAA2; Ruling 36)

Per game, off by default: "Anti-aliasing (post): Off / CMAA2" in the Games window (`GameSettings.postAA`) or
`MACNEUTRON_POST_AA=cmaa2`. The presenter runs our Metal port of Intel's CMAA2 (`presenter/cmaa2.metal`, Apache-2.0,
Extra Sharpness, preset HIGH; `libmacneutron-present.metallib` beside the dylib) in place on every SDR frame, before
any MetalFX upscale: an 8-bit one through an sRGB view of the drawable, a 10-bit one (RGB10A2/BGR10A2, which have no
sRGB view) with the sRGB curve decoded and encoded in the shader and its blends kept at 10 bits (10:10:10:2 working
colours, a function constant). HDR layers pass through. With MetalFX off
the launcher still loads the presenter when post-AA is on, and the presenter skips only its upscale. Notices:
`licenses/macneutron/CMAA2-LICENSE.txt`, a NOTICES.md section, the README entry; `licences_test.sh` checks "CMAA2" and
the file (red before they existed, and its self-test deletes the file).

`make presenter-check` (the native part drives wine.app's presenter through its own present hook on layers outside any
window, `presenter/tests/cmaa2_check.m`; the Wine part runs `present_loop.exe` through the launcher), all ok:

| Check | Result |
| --- | --- |
| Off: dense and sparse test frames, 2560x1440 and 1728x1117 | byte for byte |
| Flat gradient frame, on | unchanged |
| Silhouette frame, on: pixels changed / more than 1 px from an edge | 6.70 ‰ / 0 (2560x1440); 6.72 ‰ / 0 (1728x1117) |
| 1-px glyph strokes, stroke-to-background contrast kept (through the sRGB view) | 83.3 % (2560x1440), 83.2 % (1728x1117); the study's raw-read probe: 85.9 % |
| RGB10A2 (10-bit SDR), both sizes: off / flat / silhouettes / glyphs | byte for byte / unchanged / 6.70 ‰ and 6.72 ‰, 0 far from edges / 83.3 % |
| RGB10A2: blended channel values that are codes no 8-bit value gives | 74.3 % (2560x1440), 74.4 % (1728x1117), ≥ 60 % required; blends packed through 8-bit sRGB (the 8-bit path's packing) give 27.6 % / 28.7 % |
| HDR (RGBA16Float) layer, on | unchanged, `left alone` logged, no CMAA2 |
| Upscale (640x360 to 1280x720): game-size drawable changed; MetalFX output against the off run | 30801 px changed; differs (CMAA2 runs before MetalFX) |
| Metal shader validation, then API validation, every native run | exit 0 (both layers at once crash inside MetalTools on a view of a drawable's texture, so they run one after the other) |
| Wine: full size, 640x360 upscaled, MetalFX off, fp16 | `CMAA2 1280x720` once; `CMAA2 640x360` before `MetalFX`, checkerboard intact; with `MACNEUTRON_NO_METALFX=1` CMAA2 and no MetalFX; fp16 no CMAA2 |

**Cost.** The check prints the GPU time of the present's command buffer, which holds only CMAA2: at 1728x1117 0.155 /
0.223 / 0.712 ms (flat / sparse / dense median), at 2560x1440 0.283 / 0.388 / 1.258 ms. That is 2.5-4x the study's
probe (0.059 / 0.090 / 0.330 at 2560x1440). The shader's own cost matches the probe: the same encoder, run from a
scratch bench on a drawable's texture that is not re-acquired each frame, costs 0.066 / 0.084 / 0.281 ms at 2560x1440.
Anything run on a freshly acquired, presented drawable of these offscreen layers is 3-5x slower (a plain 9-tap kernel:
0.13 ms, against 0.67 ms), and a blit into the drawable first in the same command buffer did not remove that. The
mechanism isn't pinned down, and a game acquires a fresh drawable every frame too, so the in-game cost is open: Phase
2's to measure (synthesis §6). On an RGB10A2 layer (the same harness): at 1728x1117 0.269 / 0.351 / 0.815 ms, at
2560x1440 0.492 / 0.581 / 1.411 ms; the shader's sRGB decode of every colour load is about 0.07-0.14 ms of that
(measured against a build without it).

Also: `make test` (246), `make smoke` 15/15, `make bridge-check` (all ok), `licences_test` and its self-test PASS. The
build is a development one (the DXMT and Wine trees carry another task's diagnostic commits), so `make wine-arm64`
rebuilds incrementally each time rather than saying up to date. Not yet seen in a game.

## Emulated fullscreen: background behaviour and per-size MetalFX fallback (XeSS plan, Task FS; Rulings 36-37)

- **EmulateModeset on by default.** Every prefix the launcher prepares gets `HKCU\Software\Wine\X11 Driver`
  `EmulateModeset=Y` beside `ShowCrashDialog` (`PrefixManager.prepareNew`): a game's exclusive Fullscreen changes
  Wine's virtual mode, scaled to the screen, never the Mac's display. Existing prefixes get it with the runtime that
  brings it (a new wine.app changes the prefix stamp, which prepares them again in place). RetinaMode stays off.
- **Black letterbox bars** (Wine 0030, `winemac: Fill fullscreen windows' letterbox area with black.`): exported as
  committed; seen only in the maintainer's game check.
- **Leaving fullscreen in the background minimises** (DXMT 0032, D3D11 and D3D12): when the game leaves fullscreen
  while its window isn't in front, the window goes to the Dock (`info:  Leaving fullscreen in the background:
  minimising`, once per leave) instead of sitting fullscreen-sized in a corner of the screen.
- **The windowed rect is saved before the mode change** (DXMT 0031): leaving fullscreen restores the window as it was,
  even when the game resized it on WM_DISPLAYCHANGE.
- **D3D12 presents to a minimised window are skipped** (DXMT 0033): S_OK (flip model), the back buffers rotate, the
  frame latency object is released, no drawable is asked for; a 60 Hz sleep stands in for the drawable's pacing.
- **Presenter:** a MetalFX refusal falls back to the linear filter for that drawable and target size only; the next
  size upscales again (was: the rest of the session).
- DXMT 0030 (`DXMT_MAX_ANISOTROPY`, a diagnostic switch, nothing changes when unset) is exported with them.

Checks (`dxmt/tests/d3d12_fullscreen.cpp`, run alone after the lanes; it refuses to run without EmulateModeset, so the
Mac's display never changes):

| Check | Before (red) | After |
| --- | --- | --- |
| Leave fullscreen in front (D3D12, D3D11; the window fits itself to each mode on WM_DISPLAYCHANGE) | `fg-leave 1 0 0,35,640,486` | `fg-leave 1 0 same` |
| Leave it with another window in front | `bg-leave 1 0`, no log line | `bg-leave 1 1`, one `Leaving fullscreen in the background` |
| 31 D3D12 frames to the minimised window, each waited on the latency object and fenced | presented through Metal (no skip counter) | `minimised presents 0x0 0 31 fast`, `presents skipped (window minimised) 31`, slowest ~20-26 ms |
| The restored window presents | `0x0` | `0x0` |
| Presenter: MetalFX made to refuse 1280x720 (`MACNEUTRON_PRESENT_REFUSE`, test-only), window resized to 960x540 | `linear filter` 1, `MetalFX 640x360 -> 960x540` 0 | 1, 1 |

`make dxmt-check` all passed in both lanes (x64 and ARM64EC programs), `make presenter-check` all ok (31), `make test`
(246), `make smoke` 15 PASS, `make bridge-check` all ok; translator key unchanged (`735ba5c4…`); Wine 30 of 30 and
DXMT 33 of 33 apply from the pins to the trees' exact trees. Not yet seen in a game: the maintainer's check is
bg-synthesis.md §3 (Cmd-Tab away and back twice, 30 s in the background, Dock and Mission Control, quit from the Dock),
plus the bar colour.

## Follow-ups before the push: anisotropic filtering, fullscreen, presenter, logging, gradient bias (XeSS plan, Task FU)

2026-10-08. DXMT patches 0034-0037; Wine unchanged (0030). Each item has a row that failed first, except 0035 (no
second display here) and the framebufferOnly gate (the test layers already have it off); the BGR10A2 rows are new
coverage.
- **Anisotropic filtering 16x by default** (maintainer's decision). `GameSettings.anisotropy`: none (16x), `game` (no
  override), `4`, `8`, `16`; anything else runs at 16x. It becomes `DXMT_MAX_ANISOTROPY` (DXMT 0030's floor on
  trilinear, non-comparison samplers; unset for `game`), under the launch options as every setting. Games window:
  "Anisotropic filtering: Game's choice / 4x / 8x / 16x (default)". Settings files from before load as 16x. dxmt-check:
  `lod k=8 s0 Sample` (a trilinear sampler, 8:1 footprint) is `1.00` through the launcher's default and `4.00` with
  `DXMT_MAX_ANISOTROPY=0` and on D3DMetal; every other `dxmt/check.sh` run passes `DXMT_MAX_ANISOTROPY=0`, so its
  comparisons with D3DMetal stay on the programs' own samplers.
- **Leaving fullscreen in the background is decided by process** (DXMT 0034): the game's own popup in front (a dialog,
  an overlay owned by its window) no longer minimises it; another process's window, or none, does. `popup-leave 1 1`
  before, `1 0` after (D3D12 and D3D11); `bg-leave 1 1` and the one log line unchanged. `dxgi.handleAltTab` keeps its
  exact-window check.
- **No minimise when fullscreen moves to another output** (DXMT 0035): `SetFullscreenState(TRUE, <other output>)`'s
  leave half. No row: this Mac has one display.
- **A skipped present to a minimised window counts as a frame** (DXMT 0036): DXMT_STATS's frame counts sum to 32 (the 31
  skipped and the restored one; 1 before), so its 5 s reports go on while the game is in the Dock.
- **Gradient samples keep the sampler's MipLODBias** (DXMT 0037, airconv): DXIL SampleGrad and DXBC sample_d scale both
  derivatives by 2^bias, as D3D adds the bias to their LOD and Metal's gradient sample takes none. `d3d12_lod` (the blur
  study's sweep): `k=8 s6 SampleGrad` (anisotropy 4, bias -1, 8:1) `2.00` → `1.00`, D3D's value (D3DMetal: 2);
  `k=1 s1` `1.00` → `0.00`, `k=1 s2` `1.00` → `2.00`; 84 cases, every one without a sampler bias or not by gradients
  as D3DMetal. Offline (`dxil-translate --flags`): `grad=7/7` for `lod.ps.dxil`, `grad=1/1` for `dxbc/grad.dxbc`
  (`0/1` before). This changes the translator key, `735ba5c4…` → `d6863ecc…` (unreleased: the last release's users
  rebuild their shader caches once with this one anyway).
- **The fullscreen test's guard** reads EmulateModeset as Wine does, the program's `AppDefaults` key first (`guard
  emulated` before, `guard not emulated` after).
- **Presenter**: a refused size asks MetalFX once (`test refusal at 1280x720` 1, before 0: no count); a refusal that
  doesn't depend on the size (no MetalFX on the GPU, a pixel format it can't scale; `MACNEUTRON_PRESENT_REFUSE=all`)
  lasts for the layer (`linear filter` 1, `MetalFX` 0; before: 0, 2). CMAA2: framebufferOnly is turned off only for
  the 8- and 10-bit layers CMAA2 handles; every frames run counts pixels whose alpha changed (0; a mutant writing
  alpha 0 counts 290673); BGR10A2 has its rows now. `postAA` values other than `cmaa2` are off in the launch variables
  and the Games window.
- **Logging**: `MACNEUTRON_LOG=1` sets `WINEDEBUG=warn+all,warn-seh,+loaddll,warn+steamclient` (no seh warnings,
  Unreal's OutputDebugString flood, and no per-frame steamclient trace: SMITE 2's log had reached 917 MB);
  `MACNEUTRON_LOG=2` keeps `warn+all,+loaddll,+steamclient`. `steam-<appid>.log` past 50 MB moves to
  `steam-<appid>.log.1` at the next launch (one old file kept).

`make dxmt-check` (dev build of 0034-0037): `dxmt-check: all passed` in both lanes (x64 and ARM64EC programs), 290
and 280 ok, the new rows in both. A first run failed one timing row in the x64 lane, `and with
DXMT_D3D12_TIMESTAMP_BLITS=1, 53 get blits of their own` (`hazard ts-many 0`: `heavy 133750 alone 1329583`, the
dispatch measured alone ten times its usual ~134000 ticks while other lanes ran); alone it passed 5 of 5 (`alone`
133833-220208) and the whole check passed on the rerun. `make presenter-check` 62 ok, `make test` 251 tests,
`make smoke` 15 PASS, `make bridge-check` 15 ok and `PASS probe redaction`, `licences_test` PASS. DXMT 37 of 37 and
Wine 30 of 30 apply from the pins to the trees' exact trees.

## The maintainer's gate (XeSS plan, Task 5)

2026-10-07/08, SMITE 2 in a scratch copy on the built-in display (the external display was unavailable; the maintainer
accepted judging there), the dev runtime of each step, Steam bridge on, practice and lobby only.

- **Image:** XeSS Balanced through the bridge at 1728x1117 and, with RetinaMode, 3456x2234; then emulated exclusive
  Fullscreen (EmulateModeset) at 1728x1080 and 2560x1440 with black letterbox bars, minimise on Cmd-Tab and a scaled
  return, and 16x anisotropic filtering: "looked pretty good". CMAA2 on SMITE's 10-bit swapchain (no 8-bit step):
  "Looks good to me". The earlier "textures are blurry" report traced to Metal's anisotropic filter cancelling
  Unreal's negative LOD bias on angled surfaces; 16x by default (Task FU) moves that loss to much steeper angles.
- **Memory:** several 10-15-minute runs, footprint flat after the lobby load (about 6.0-6.5 GB, GPU 0.8-1.1 GB) and
  clean quits. The 30-minute soak was waived by the maintainer (Ruling 42); one attempt recorded nothing because the
  sampler's process pattern didn't match Wine's command line.
- **Upscale cost:** 0.93-1.01 ms at 1728x1117 output and 1.76 ms at ~2560x1440 (Tasks 3, 3c): under the spec's 5 ms.

## msync wait-all fixes (batch Task 1)

2026-10-09. Wine patch 0031 (`msync: Fix wait-all wakeups, rollback and duplicate objects.`); DXMT, FEX unchanged.
`x64-sync` has 19 gated rows (5 new) and 7 time rows (3 new); `check.sh msync` also gates mode 1's duplicate answers
(`MSYNC_MODES` picks the modes; default `1 0`). Every new row failed first in mode 1 and passed in mode 0 on the 0030
runtime (`build/batch-msync/red10k-*.log`, `red-mode0-1.log`):
- **`wait-all-single-waiter`** (B1): `FAIL … auto-event round 0 (A first): the single waiter still asleep 100 ms after
  the signal` in 6 of 6 mode-1 runs; `ok` after.
- **`wait-all-rollback-wake`** (B2): `stalls 19`, `3`, `1` (2,000 releases: `0`, `2`, `6`, so `RELEASES` is 10,000);
  `stalls 0`, no timeouts after.
- **`wait-all-owned-mutex`** (B3): `probe-hits` 110672168, 125748292, 136435857 and `1 owner releases failed` (one
  rollback freed the owner's mutex for good); `probe-hits 0` after.
- **`wait-all-duplicate`** (B4): mode 1 `auto-event spun semaphore success mutex success` → `invalid-parameter` for
  all three; mode 0 `success` for all three, before and after (the wineserver has no duplicate check).
- **`wait-all-abandoned-mutex`** (B7): `still running after 1 s` → `ok` (`WAIT_ABANDONED_0`, the mutex released).
- B6 (a mutex taken abandoned goes back abandoned) has no deterministic trigger; it is read in the diff. R5 and R9,
  static: `_mach_port_mod_refs` in `ntdll.so`'s imports 0 → 1; `_msync_abandon_mutexes`: `stlr` 0 → 1, the merged
  `str d8, [x21]` 1 → 0.

**B1 shipped as option (a), wake-all for every type on both sides** (as CrossOver 26.3). Option (b), the Ruling R11
default (non-alertable wait-all legs parked through the pump), passed every row but failed the bar: mode 1's
`wait-all-wake` 10566-11288 ns against mode 0's 9139-9222 in the same three runs (`green-b-*.log`). Under (a) every
waiter parked on an object's word wakes at each signal and races for the object, so a wait-all leg that only looks at
it can no longer take the one wake a single waiter needed: who gets an auto-reset event or a mutex is settled by the
take, not by the kernel's choice of one sleeper, at the price of waking them all: `auto-handoff-8`, 8 threads on one
auto-reset event, 692 (681–713) ns per handoff against (b)'s wake-one 626 (617–633) in the same machine state.

| Row (ns), median (min–max) of 3 | mode 1 before | mode 1 after | mode 0 after |
|---|---|---|---|
| `wait-all-wake` | 4804 (3383–4918) | 5822 (5494–5845) | 9278 (9224–9386) |
| `wait-all-poll` | 113 (89–121) | 118 (118–118) | 8768 (8730–8850) |
| `auto-handoff-8` | 634 (631–657) | 692 (681–713) | 7632 (7550–7722) |

Option (b), same three-run format: mode 1 `wait-all-wake` 11274 (10566–11288), `wait-all-poll` 98 (96–101),
`auto-handoff-8` 626 (617–633); mode 0 9196 (9139–9222), 8644 (8618–8766), 7552 (7520–7624).

All on AC power, lid open, idle, each run under `caffeinate -i`, back to back ("before": the 10,000-release harness on
the 0030 runtime; "after": the dev build of 0031). The 2,000-release "before" runs measured `wait-all-wake` 3420
(3358–3430), `wait-all-poll` 86 (86–90), `auto-handoff-8` 614 (602–702); against them `wait-all-poll` after lies
wholly above. The machine moved between the sets: the control rows this patch doesn't touch read `uncontended-wait` /
`uncontended-signal` 62-65 / 44-46 in 2,000-release runs 1-2 and 10,000-release run 1, 114-125 / 77-91 in the other
three before runs, and 136-143 / 99-100 in every run after (the sync report's band: 102-143 / 77-101). The poll path
does strictly less work after (one index compare instead of a `single_waiters` increment and decrement), and (a) and
(b) run the same poll code yet measured 118 and 96-101: a build or machine effect, not the path's work.

`w1-wins` / `w2-wins` per run (10,000 releases):

| Run | rollback-wake | owned-mutex |
|---|---|---|
| before 1-3 (mode 1) | 1102/8899, 919/9082, 1042/8959 | 1023/8978, 938/9063, 1124/8877 |
| after (a) 1-3, mode 1 | 991/9010, 1006/8995, 913/9088 | 3346/6655, 3467/6534, 3600/6401 |
| after (a) 1-3, mode 0 | 4831/5170, 4850/5151, 4784/5217 | 5001/5000 ×3 |
| (b) 1-3, mode 1 | 1536/8465, 1483/8518, 1389/8612 | 7173/2828, 7366/2635, 7227/2774 |

(2,000 releases, before: rollback-wake 221/1780, 228/1773, 224/1777; owned-mutex 216/1785, 233/1768, 214/1787. The
wins add up to one more than the releases: the shutdown releases X once more.) The msync step, both modes, stays far
under its 300 s cap (a whole `check.sh msync` run, with `boot` and `fex`: 77-78 s).

`make wine-arm64-check` (dev build of 0031): every step `PASS`, then `PASS orphans` (2134 s), its `msync` step with
the 19 rows in both modes and mode 1's duplicate line; `make test` 251 tests, `make smoke` 15 PASS, `make bridge-check`
15 ok and `PASS probe redaction`; `make media-check` as before (`FAIL media-mf: FAIL arm64-media-mf: stage=video-type
hr=0xc00d5212; FAIL x64-media-mf: stage=video-type hr=0xc00d5212`). Wine 31 of 31 apply from the pin to the build
tree's exact tree.

## Measurement lanes: baseline (batch Task 2)

2026-10-09; no runtime change. The bundle measured is the applied build of Wine 0031 that Task 1 left (`wine.applied`
2c06186, `build/wine-arm64/version` `c12564359f1e…`, `SOURCE` at 8c3aa6e), staged by `make wine-arm64` before this
task's edits.

`make lanes-check` (`check.sh lanes`, run by name, outside the full run) runs each program from one source in three
lanes, ARM64, ARM64EC and x64 under FEX (its defaults: the caller's `FEX_*` variables are dropped), in mode 1 against
the prefix's server, with `WINEDEBUG=-all` and the crash dialog off. It passes when each program prints
`PASS <program>` and its 16 time rows, and writes each row as `info <program> <row> <ns>`:
- `x64-sync`, `arm64ec-sync`, `arm64-sync`: Task 1's 19 gated rows, which pass in all three lanes, and its 7 time rows,
  plus `cs-uncontended`, `srw-uncontended`, `cs-contended-4`, `srw-contended-4`, `waitonaddress-uncontended`,
  `waitonaddress-contended-4`, `wait-any-wake`, `alertable-wake` and `auto-pool-8` (Ruling R20). Each is the median of
  21 batches, in ns per operation. The PASS and FAIL lines name the program.
- `arm64-xcall`, `arm64ec-xcall`, `x64-xcall` (`-O2 -fno-builtin`, so each CRT routine is a call): 16 rows of calls
  into Wine's DLLs, each the median of 100 batches after one of warm-up, in ns per call.

The new `x64-sync` rows also run in the `msync` step's x64 lane, in both modes. The whole `check.sh msync` run (with
`boot` and `fex`) went from 77-78 s to 104-106 s (4 runs), so its 300 s cap stays.

The baseline is three runs of `caffeinate -i sh wine-arm64/check.sh lanes`, back to back (10:16-10:24). Each run was
on AC power at its start and end, with the lid open. Before each, `pgrep -lx wineserver` and
`pgrep -lf wine-arm64/check.sh` printed nothing. The load average was 4.2-4.6, from processes outside the task. The
logs are in `build/lanes/baseline/run{1,2,3}.log`. The table is
`python3 wine-arm64/tools/lanes_report.py build/lanes/baseline`, with cells `median (min–max)` of the three runs in ns
and the last two columns differences of medians:

| row | arm64 | arm64ec | x64 | arm64ec − arm64 | x64 − arm64ec |
|---|---|---|---|---|---|
| sync uncontended-wait | 83.0 (77.0–84.0) | 76.0 (73.0–78.0) | 127 (110–142) | -7.0 | +51.0 |
| sync uncontended-signal | 38.0 (37.0–38.0) | 42.0 (36.0–43.0) | 90.0 (84.0–99.0) | +4.0 | +48.0 |
| sync cross-process-wake | 4252 (553–4907) | 4245 (4140–4351) | 4366 (4246–4462) | -7.0 | +121 |
| sync create-close | 28048 (28030–28077) | 28292 (28232–28319) | 28710 (28653–28807) | +244 | +418 |
| sync wait-all-wake | 5903 (5820–6190) | 6148 (5854–6161) | 5953 (5640–6051) | +245 | -195 |
| sync wait-all-poll | 85.0 (77.0–85.0) | 89.0 (88.0–89.0) | 122 (120–130) | +4.0 | +33.0 |
| sync auto-handoff-8 | 642 (617–644) | 724 (638–740) | 703 (681–725) | +82.0 | -21.0 |
| sync cs-uncontended | 12.0 (12.0–13.0) | 13.0 (10.0–14.0) | 85.0 (77.0–87.0) | +1.0 | +72.0 |
| sync srw-uncontended | 31.0 (28.0–32.0) | 33.0 (26.0–34.0) | 108 (100–112) | +2.0 | +75.0 |
| sync cs-contended-4 | 30.0 (28.0–30.0) | 31.0 (28.0–31.0) | 200 (197–201) | +1.0 | +169 |
| sync srw-contended-4 | 96.0 (84.0–100) | 97.0 (95.0–102) | 192 (190–194) | +1.0 | +95.0 |
| sync waitonaddress-uncontended | 18.0 (17.0–18.0) | 17.0 (15.0–18.0) | 63.0 (63.0–64.0) | -1.0 | +46.0 |
| sync waitonaddress-contended-4 | 4652 (4630–4862) | 4616 (4598–4659) | 4617 (4593–4716) | -36.0 | +1.0 |
| sync wait-any-wake | 7899 (7652–8284) | 7676 (7484–7940) | 7729 (7668–7774) | -223 | +53.0 |
| sync alertable-wake | 7817 (7308–8016) | 7810 (7600–7888) | 7856 (7756–8014) | -7.0 | +46.0 |
| sync auto-pool-8 | 50943 (50940–50953) | 48953 (47954–49872) | 50954 (50946–50962) | -1990 | +2001 |
| xcall get-current-thread-id | 0.7 (0.7–0.7) | 1.7 (1.7–1.8) | 24.6 (24.3–24.8) | +1.0 | +22.9 |
| xcall get-last-error | 0.9 (0.9–0.9) | 2.8 (2.4–2.8) | 25.6 (25.6–25.7) | +1.9 | +22.8 |
| xcall tls-get-value | 0.9 (0.9–0.9) | 2.5 (2.2–2.5) | 25.2 (24.6–26.1) | +1.6 | +22.7 |
| xcall get-tick-count | 0.7 (0.7–0.7) | 1.8 (1.7–1.8) | 24.5 (24.4–24.8) | +1.1 | +22.7 |
| xcall qpc | 15.4 (15.4–15.4) | 16.8 (16.8–16.9) | 43.3 (43.0–43.4) | +1.4 | +26.5 |
| xcall istream-addref | 3.5 (3.5–3.5) | 3.5 (3.5–3.5) | 27.2 (27.1–27.2) | 0.0 | +23.7 |
| xcall memcpy-16 | 2.0 (1.9–2.2) | 3.0 (2.6–3.0) | 25.9 (25.7–25.9) | +1.0 | +22.9 |
| xcall memcpy-16-offset | 2.8 (2.8–3.3) | 3.6 (3.5–4.1) | 27.1 (26.9–27.4) | +0.8 | +23.5 |
| xcall memcpy-256 | 3.9 (3.7–4.3) | 4.6 (4.3–5.0) | 28.0 (27.8–28.1) | +0.7 | +23.4 |
| xcall memcpy-256-offset | 5.5 (5.0–7.8) | 6.2 (6.2–6.3) | 29.5 (29.3–29.7) | +0.7 | +23.3 |
| xcall memcpy-4k | 43.6 (43.5–43.9) | 45.2 (45.1–47.7) | 57.8 (57.8–58.0) | +1.6 | +12.6 |
| xcall memcpy-4k-offset | 45.7 (45.4–47.7) | 40.1 (40.0–46.5) | 74.0 (73.9–74.3) | -5.6 | +33.9 |
| xcall memcpy-1m | 15670 (15480–15710) | 15340 (15250–15700) | 15300 (15290–15320) | -330 | -40.0 |
| xcall memcpy-1m-offset | 15140 (14220–15320) | 15760 (15620–15770) | 16300 (16090–16350) | +620 | +540 |
| xcall strlen-1k | 235 (235–236) | 237 (237–237) | 262 (262–271) | +2.4 | +25.1 |
| xcall qsort-4k | 104860 (104720–106830) | 164640 (163050–168000) | 3552710 (3547900–3558450) | +59780 | +3388070 |

- x64 − arm64ec is FEX's entry and the x64→EC transition: +22.7 to +22.9 ns on the four trivial exports
  (`get-current-thread-id`, `get-last-error`, `tls-get-value`, `get-tick-count`).
- arm64ec − arm64 is the EC thunks and the aux-IAT checker: +1.0 to +1.9 ns on the same four.
- x64 `istream-addref`, 27.2 ns, is the bare crossing: a vtable slot with no fast-forward sequence. The body,
  `InterlockedIncrement`, is 3.5 ns in both native lanes.
- x64 `get-current-thread-id` − x64 `istream-addref` is the fast-forward sequence's cost: 24.6 − 27.2 = −2.6 ns. The
  two bodies differ by 2.8 ns (3.5 against 0.7 in the ARM64 lane), so the sequence costs about 0.2 ns, within the
  noise.
- x64 `get-last-error` − x64 `get-current-thread-id` is the alias hop: +1.0 ns (ARM64EC +1.1, ARM64 +0.2).

`qsort-4k`'s comparator is the program's own code. In the x64 lane each of its ~49,000 comparisons crosses back from
the ARM64EC `qsort` into x64 code: 3.55 ms against 0.16 ms in the ARM64EC lane, about 69 ns per comparison.

**`auto-pool-8` (Ruling R20)** measures what option (a), every wake a wake-all, costs a parked pool:
- 8 workers wait in `WaitForSingleObject(e, 1000)` on one auto-reset event.
- Main sets it every 50 µs, spinning on `QueryPerformanceCounter`, and only once the last set was taken.
- The worker that takes it does 10 µs of busy work.
- A batch is 10,000 sets.

The row is (process CPU − main's CPU) per set. R20 named `GetThreadTimes` for main's share, but Wine on macOS has no
per-thread CPU time: `get_thread_times()` in `dlls/ntdll/unix/thread.c` is implemented only for Linux and FreeBSD, and
`ThreadTimes` on the current thread falls back to the process's `times()`. Every run's `info auto-pool-8` line shows
`main-thread-cpu` equal to `process-cpu`. Main spins for the whole batch, so the row takes its wall time as its CPU
time. `times()` counts 10 ms ticks, so a 0.5 s batch resolves 1 µs per set.

A scratch check in the ARM64 and x64 lanes confirmed the method:
- The cost per set doesn't follow the period: 49.7, 52.0 and 54.9 µs at 25, 50 and 100 µs.
- It grows with the number of waiters: 13.0, 16.5, 25.5 and 52.0 µs with 1, 2, 4 and 8.
- It is 0.0 with main alone, or with 8 workers parked on an event nobody sets.

Under (a), then, each extra parked waiter costs about 5.6 µs of CPU per set. The 8-waiter pool spends about 51 µs per
set, of which 10 µs is the work, where a single waiter spends 13 µs.

In the `msync` step's x64 lane (three runs back to back, AC, idle), mode 1 measured 51945 (51944–51948) ns per set and
mode 0 12958 (12943–12961). Mode 0's number leaves out the wineserver's CPU, because the server is another process.

`make test` passed 251 tests. `check.sh msync` printed `PASS msync` and `PASS orphans` in all four runs, both modes,
with all 19 gated rows and the 16 time rows.
