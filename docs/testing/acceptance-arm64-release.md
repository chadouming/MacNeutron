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
