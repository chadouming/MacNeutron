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

`release/release.sh` (Task 12), 2026-10-04, at `b75a7e4`, with the signing variables and Steam running and logged in.
Nothing was submitted to Apple: the notarized run (R2, L6's notarized row on the release bundle) is Task 14's.

- `make release VERSION=0.0.1-rc`: make's prerequisites ran (`wine-arm64: up to date`), then release.sh printed only
  `release: VERSION 0.0.1-rc is not MAJOR.MINOR.PATCH` and exited 2.
- R1, `sh release/release.sh --self-test`: 20 `ok`, `PASS release self-test`. Each refusal on its own input in a
  temporary clone whose origin is a local bare clone (the DXMT case with a local bare repository as the fork): a version
  that isn't MAJOR.MINOR.PATCH, `v0.0.0` already a tag, each README string (`Rosetta 2`, `import-gptk`, `doesn't
  redistribute`), a dirty tree, a HEAD not in origin/main, a tree that isn't applied, a SOURCE with `WINE_SERIES=dev`,
  with a `+dirty` commit or with another commit than HEAD, an unpublished DXMT commit; and the passing case of each.
- `sh release/release.sh --rehearse 0.0.0` (2 min 15 s; `build/release/rehearse-0.0.0/`, with its `REHEARSAL` file):
  - Refusals: READMEs, the four trees `applied`, `DXMT_COMMIT` published on the fork, `wine-arm64: up to date`. The
    rehearsal skips the clean-tree and origin/main refusals.
  - The release `wine.app` (`bundle.sh --release`): every assertion passed after stripping (signature, entitlements,
    licences, minos, timestamps, links, x18 counts, builtin markers, CHPE metadata). Its `SOURCE` differs from the
    development one only in `MACNEUTRON_COMMIT` (HEAD `e23f131`; the development bundle's names `8da5fdb`, the last
    commit that changed a build input).
  - R3: `smoke.sh` on it (`info wine.app: …/build/release/rehearse-0.0.0/wine.app (0.0.0)`): every row PASS (the
    notarized row ran on `build/release/r0/wine.app`, R0's bundle); the bridge probe through an assembled tool folder:
    `init: ok`, `steamid ok`, auth ticket 234 bytes; `present_loop.exe 1280 720 0 0 120 0` on DXMT through it:
    `frames 120, avg frame 8.092 ms`.
  - R4: `licences_test.sh --app` on `MacNeutron.app`: `PASS licences_test`, `PASS licences_test --app` (and red by hand
    on a copy without `Contents/Resources/licenses/LICENSE`, and on one with neither the README's pointer nor
    `wine.app`'s `licenses/macneutron/LICENSE`). The app: both Swift binaries `arm64` and stripped (`strip -S`: no `OSO`
    entries, no path under `/Users/`), version `0.0.0`, minimum `27.0`, hardened runtime and a secure timestamp on the
    CLI and the app, no entitlements, `codesign --verify --strict --deep` passes, the nested `wine.app`'s CDHash equal
    to the release bundle's; `spctl` rejects it (`Unnotarized Developer ID`), as expected before notarization.
  - R5: `PASS sources`. `verify-sources.sh` was also red, by hand, on a wrong `WINE_SERIES`, `FEX_SUBMODULE_fmt`,
    `GMP_SHA256`, `MACNEUTRON_COMMIT` and `LLVM_TAG`, a missing `dxmt-nvapi.tar`, an edited lsteamclient file, an SDK
    file added to `lsteamclient.tar` and a wrong Wine patch count.

| Size | |
|---|---|
| `wine.app` before stripping | 1,373,232 KB |
| `wine.app` after stripping (unsigned; `.a` files and Wine's developer tools deleted) | 459,260 KB |
| `MacNeutron-0.0.0.zip` (rehearsal, not notarized) | 139,576,793 bytes |
| `MacNeutron-0.0.0-source.tar.gz` | 106,961,622 bytes |

The rehearsal's `SHA256SUMS` describe unpublished rehearsal files and aren't recorded; the release's go here in Task 14.
