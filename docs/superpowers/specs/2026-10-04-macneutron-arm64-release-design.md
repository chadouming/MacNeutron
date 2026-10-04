# MacNeutron — Native arm64 stack, sub-project 5: the arm64-only release

- **Date:** 2026-10-04
- **Status:** Draft, awaiting the maintainer's review. The design was approved in conversation section by section on
  2026-10-04, with the maintainer's decisions in §1.
- **Builds on:**
  - `2026-10-02-macneutron-native-arm64-design.md` (the roadmap; this spec amends its §1, §2 and §11, see §13)
  - `2026-10-03-macneutron-arm64-dxmt-design.md` (DXMT in `wine.app`; its §6 says how a prefix gets DXMT)
  - `2026-10-04-macneutron-ship-base-wine-design.md` (the shippable `wine.app`, msync, the Steam bridge, licences)
  - `2026-09-27-macneutron-app-design.md` and `2026-09-28-macneutron-steam-bridge-design.md` (the launcher and app this
    spec changes)
- **Evidence:** `docs/research/2026-10-04-arm64-release/` (four maps of the code at `95f8883`, with `file:line` citations).
- **Scope:**
  - **In:**
    - the launcher runs every game on the native arm64 runtime (`wine.app`); the Rosetta runtime, GPTK/D3DMetal, DXVK,
      the AVX switch and the Rosetta preflight are deleted (roadmap row 9's deletions, moved here);
    - `wine.app` installed by the app from inside `MacNeutron.app`; prefixes prepared with `check.sh`'s recipe; the
      arm64 Steam bridge, DXMT, msync and shader pre-caching wired through the launcher;
    - the MetalFX presenter loaded by DXMT's `winemetal.so` instead of `DYLD_INSERT_LIBRARIES`;
    - the first public release: an MIT licence, a release build that refuses development inputs and strips debug
      info, Developer ID signing of `MacNeutron.app`, notarization, the source archive, and the release record;
    - the dev checks moved to arm64, with a frozen copy of today's Rosetta tool kept as their reference.
  - **Out:**
    - 32-bit games (roadmap row 8) and DXMT's Direct3D 9 (row 7): they stop working with this release and come back
      with those rows;
    - frame-time and CPU-cost measurements (row 6; they no longer gate anything, §13);
    - media playback (row 10);
    - publishing: the release script stops before `git tag` / `gh release create`, which the maintainer runs;
    - installing the release on the maintainer's Mac (the maintainer's last step, §11).

## 1. Goal

Anyone with an Apple Silicon Mac on macOS 27 can download one notarized `MacNeutron-0.1.0.zip`, open the app, turn on
Steam Play mode, and play 64-bit Windows Steam games on the native arm64 runtime, with no Rosetta installed.

**Sub-project 5 is done when** §9's gates pass, the maintainer has run R6 and S, and `make release VERSION=0.1.0`
has produced the notarized zip, the source archive and `SHA256SUMS`, recorded in
`docs/testing/acceptance-arm64-release.md`. Publishing is the maintainer's step after that.

### Decisions (maintainer, 2026-10-04)

| Decision | Choice |
|---|---|
| Scope | One spec for the launcher wiring and the first release (not split) |
| Runtimes in the release | **arm64 only.** Rosetta, GPTK/D3DMetal, DXVK and the AVX switch leave the launcher and the release. The per-game cutover of the native spec §1 (a game moves when measured) is superseded: every game moves now |
| The Rosetta code in the repo | **Deleted** from the launcher and the app. The dev checks keep a Rosetta *reference* (D3DMetal pixels, Rosetta timing baselines) through a frozen copy of today's installed tool (§8), never shipped |
| lsteamclient in the release | **Shipped** inside `wine.app` as built today, with its licence text. The maintainer accepts the risk that the Steamworks SDK licence doesn't grant redistribution of the generated interface code (`map-release.md` §lsteamclient; the ship-base spec's decisions) |
| lsteamclient's source | In the release source archive (it is public in Proton at the pinned commit; it follows from shipping the binary). Still never committed to this repo |
| MacNeutron's own licence | **MIT** for the launcher, app, scripts, tests and presenter. Patches keep their upstream licences: Wine and DXMT patches LGPL-2.1-or-later, FEX patches MIT, lsteamclient patches under lsteamclient's terms |
| How `wine.app` ships | **Nested in `MacNeutron.app`** (`Contents/Helpers/wine.app`); one notarized download; the app installs it into the tool folder |
| MetalFX on arm64 | The presenter is built into `wine.app` and **loaded by `winemetal.so`** (a DXMT patch), not injected; no new entitlement |
| Launcher structure | **Swap in place**: one runtime, no runtime abstraction; `check.sh`'s prefix recipe moves into the launcher |
| Release version | `0.1.0` (the app's `CFBundleShortVersionString` already says so) |
| Publishing | The maintainer's step; the release script prints the commands and stops |

Two refinements made while writing this spec (not changes of direction):

- `wine.app`'s **build identity** is the SHA-256 of its sealed `Contents/_CodeSignature/CodeResources`, not a new
  Info.plist key: it changes whenever any file in the bundle changes, needs no build plumbing, and works for
  development builds (§5.1).
- `wine.app` nests in `MacNeutron.app/Contents/Helpers/`, not `Resources/`: nested code belongs in a code location
  for signing and notarization (`Helpers/` already holds the `macneutron` CLI).

## 2. Evidence (2026-10-04, code at `95f8883`)

- **One layout object holds every runtime path.** `CommandLineTool.swift:18` builds one `ToolLayout(executable:)`
  (the CLI's folder two levels up, `ToolLayout.swift:10-12`); every Rosetta path is read from it
  (`ToolLayout.swift:20-58`): `Libraries/Wine/bin/{wine,wineserver}`, DXMT `x64`/`x32`, `dxmt-version`, the x86_64
  lsteamclient files, `bin/steam.exe`, the presenter, `runtime-version`.
- **Per-game choice already has a channel.** `GameSettings.environment` (`GameSettings.swift:23-31`) is merged under
  the launch options (`Launcher.swift:48`) before preflight (`:53`). Only `runAs` needs a Steam config sync
  (`AppModel.swift:195-213`).
- **Rosetta is required in three places:** preflight (`Preflight.swift:29-36`), `SteamPlayMode.enable`
  (`SteamPlayMode.swift:44,93`) and `AppModel.setupComplete` (`AppModel.swift:85`).
- **Steam starts tools preferring x86_64** (`SteamPlayMode.swift:20-23`); a universal CLI would run translated.
- **`wine.app`'s recipe lives in `wine-arm64/check.sh`:** install by `cp -cR` to a path with a space (`:19,615`);
  boot with `WINEDLLOVERRIDES="mscoree,mshtml="` (`:156`; `wine.app` ships no Mono or Gecko); register FEX with
  `reg add HKLM\Software\Microsoft\Wow64\amd64 /ve /d libarm64ecfex.dll /f` (`:208`; the native spec §6 assigns it to
  this sub-project); copy `Resources/DXMT/aarch64-windows/*` into `system32` (`:467-468`); `WINEMSYNC=1` everywhere
  (`:32`). The launcher boots without `mscoree,mshtml=` (`PrefixManager.swift:48`).
- **`wine.app`'s layout** (`bundle.sh:35-55`, verified on the staged bundle): `Contents/MacOS/wine` (the entitled
  loader); `Contents/Resources/bin/wineserver`; `Contents/Resources/lib/wine/aarch64-{windows,unix}/` (FEX,
  `winemetal`, `lsteamclient.dll` ARM64X 57 MB, `lsteamclient.so`, FreeType, gnutls);
  `Contents/Resources/DXMT/{aarch64-windows/{d3d10core,d3d11,d3d12,dxgi}.dll, dxmt-replay.exe, version}`;
  `Contents/Resources/licenses/`. No i386 part. 1.3 GB staged.
- **The arm64 Steam bridge** needs `build/bridge/arm64/steam.exe` (aarch64) and the bundle's ARM64X `lsteamclient.dll`
  copied as `steamclient64.dll`; there is no 32-bit half (`bridge/probe.sh:42-47,71-75`). `make app` ships only the
  x64 `steam.exe` (`Makefile:93`). `bridge/tests/helper.exe` is a test program, not a prefix file (the roadmap row 5
  wording that copies it into prefixes was a slip).
- **The presenter is injected with `DYLD_INSERT_LIBRARIES`** (`Launcher.swift:159-167`) and is on unless
  `MACNEUTRON_NO_METALFX=1`; `wine.app` is hardened (`bundle.sh:116,118`) without
  `allow-dyld-environment-variables`, so dyld ignores the variable. The presenter turns itself on when loaded (its
  constructor swizzles `CAMetalLayer -nextDrawable`, `presenter/present.m:289-296`).
- **`wine.app` has no version inside the bundle** (`wine-arm64/Info.plist` has no `CFBundleVersion`; the stamp is
  `build/wine-arm64/version`, outside it).
- **Nothing has been released:** no tag, no GitHub release, no LICENSE file; the README says to build from source.
  `make app` signs ad hoc with no hardened runtime or timestamp (`Makefile:94-104`), so `MacNeutron.app` cannot be
  notarized as built. Only the maintainer's team can build a working `wine.app` (no ad-hoc mode, `lib.sh:56-83`).
- **Most of `wine.app` is debug info:** Wine builds its PE side with `-g -O2 -gdwarf-4`; `lsteamclient.dll` is 4.4 MB
  of code and data against 52 MB of DWARF, `icu.dll` 8.4 MB against 70 MB (`map-release.md`). 249 `.a` import
  libraries (36 MB) ship too.
- **The app quits Steam with `open steam://exit`** and posts notifications through `osascript`
  (`SteamLocation.swift:121-133`, `Preflight.swift:44-56`): separate processes, so the hardened runtime needs no Apple
  Events entitlement.
- **The dev checks use the Rosetta tool as a reference:** `dxmt/check.sh` compares our DXMT against D3DMetal through
  clones of the installed tool folder (`:36-47`), and `wine-arm64/check.sh` measures Rosetta baselines with a clone of
  it (`:438`). Installing the release over that folder would remove both references.

## 3. The launcher

### 3.1 The tool folder

After this sub-project, `~/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron/` holds:

```
bin/macneutron            the CLI, arm64 only
bin/steam.exe             the aarch64 Steam bridge launcher (build/bridge/arm64/steam.exe)
toolmanifest.vdf, compatibilitytool.vdf    unchanged
wine.app/                 cloned from MacNeutron.app/Contents/Helpers/wine.app (§3.9)
```

`ToolLayout` reads every runtime path from `wine.app`: `wine` = `wine.app/Contents/MacOS/wine`, `wineserver` =
`wine.app/Contents/Resources/bin/wineserver`, DXMT = `wine.app/Contents/Resources/DXMT/aarch64-windows/`, DXMT's
version = `…/DXMT/version`, the replayer = `…/DXMT/aarch64-windows/dxmt-replay.exe`, lsteamclient =
`wine.app/Contents/Resources/lib/wine/aarch64-windows/lsteamclient.dll`, the build identity (§5.1) from
`wine.app/Contents/_CodeSignature/CodeResources`. The Rosetta-era entries (`Libraries/`, `x64/`, `x32/`,
`dxmt-version`, `runtime-version`, `gptk-version`, the x86_64 lsteamclient copies, the presenter) are gone; the app
removes any it finds in the tool folder (§3.9). The `macneutron-native` passthrough tool is unchanged.

### 3.2 Per-game settings

`GameSettings` keeps `graphics`, `log`, `msync`, `runAs` and `metalFX`; `avx` is removed. `graphics` takes `dxmt` (the
default) or `wined3d` (Wine's built-in Direct3D 9-11 over OpenGL: an escape hatch for a Direct3D 11 game DXMT
breaks; Direct3D 12 needs DXMT). Settings files written by earlier builds still load: unknown keys are ignored and any
other `graphics` value (`d3dmetal`, `dxvk`) reads as `dxmt`, logged once per game. Launch options still override
everything (`/usr/bin/env VAR=value %command%`).

### 3.3 Preflight (every launch)

In order, each failure ending the launch with a message (§10):

1. macOS 27 or later, on Apple Silicon (`hw.optional.arm64`).
2. `wine.app/Contents/MacOS/wine` and `Contents/Resources/bin/wineserver` are executable and the build identity is
   readable. The full signature check runs at install (§3.9), not here: on a bundle this size it takes seconds.
3. The game: when the target parses as a PE file, its `Machine` field must not be `IMAGE_FILE_MACHINE_I386`
   (`0x14c`): `wine.app` has no i386 part. A target that isn't PE (a script, a `.bat`) is not checked.

Rosetta is no longer checked anywhere: not here, not in `SteamPlayMode.enable`, not in the app's setup.

### 3.4 Prefixes

The prefix stays `compatdata/<appid>/pfx` with its stamp in `compatdata/<appid>/version`. The stamp becomes
`wine.app <identity>` (§5.1). When the stamp differs, or `pfx` is missing, the launcher prepares the prefix, holding
`macneutron.lock` as today:

1. **A Rosetta-era prefix** (a `pfx` whose stamp doesn't start with `wine.app `) is renamed to `pfx.rosetta` (or
   `pfx.rosetta-2`, `-3`… if taken) and never deleted; the rename is logged. An arm64 Wine does not adopt an x86_64
   Wine's prefix. Only the maintainer's Mac has such prefixes (nothing was released before).
2. `wine wineboot -u` with `WINEDLLOVERRIDES="mscoree,mshtml="` (no Mono or Gecko prompt) and the game's own
   `WINEMSYNC` (§3.7).
3. `wine reg add 'HKLM\Software\Microsoft\Wow64\amd64' /ve /d libarm64ecfex.dll /f` (x64 code runs on FEX; without
   it, on Wine's stub `xtajit64`).
4. The existing `ShowCrashDialog=0` entry.
5. Copy `DXMT/aarch64-windows/{d3d10core,d3d11,d3d12,dxgi}.dll` into `drive_c/windows/system32/` (no `syswow64`: no
   32-bit part), whatever the game's graphics setting: `wined3d`'s overrides ignore them, and switching back to DXMT
   doesn't change the stamp.
6. `wineserver -w`, then write the stamp.

`OrphanPrefixes` is unchanged; it removes `compatdata/<appid>` folders of uninstalled games, `pfx.rosetta` included.

### 3.5 The Steam bridge

When the game runs through the bridge (as today, `Launcher.swift:142-155`), `SteamBridge` keeps
`drive_c/Program Files (x86)/Steam/steam.exe` equal to `bin/steam.exe` and `…/Steam/steamclient64.dll` equal to
`wine.app`'s `lsteamclient.dll`, copying when they differ. There is no `steamclient.dll` (32-bit). The game starts as
`wine 'C:\Program Files (x86)\Steam\steam.exe' <game> <args>`, with `SteamAppId`, `SteamGameId` and
`MACNEUTRON_STEAM_ACCOUNT` set as today (`Launcher.swift:169-184`); `STEAM_COMPAT_CLIENT_INSTALL_PATH` comes from
Steam.

### 3.6 Graphics

`GraphicsBackend` has two cases. `dxmt`: `WINEDLLOVERRIDES` `dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b` (as today
and as the arm64 DXMT spec §6 uses). `wined3d`: `dxgi,d3d10core,d3d11,d3d9,d3d10=b` (Wine's builtins; the DXMT files
in `system32` are then ignored). The D3DMetal and DXVK cases, their prefix files and the GPTK lookup are deleted.

### 3.7 The environment

Every process the launcher starts in a prefix (wineboot, reg, the replayer, `steam.exe` and the game, `wineserver -w`
and `-k`) carries the same `WINEPREFIX`, `WINEDLLOVERRIDES` and `WINEMSYNC`, so client and server always agree on msync
(ship-base spec §6, §11). `WINEMSYNC=1` unless the game's msync is off (`MACNEUTRON_NO_MSYNC=1`, then unset, which
means off). `WINEDEBUG`, `MACNEUTRON_LOG` and `DXMT_PIPELINE_RECORD` behave as today. `ROSETTA_ADVERTISE_AVX` and
`DYLD_INSERT_LIBRARIES` are no longer set. `MACNEUTRON_PRESENT=1` is set unless `MACNEUTRON_NO_METALFX=1` (§5.3);
`MACNEUTRON_PRESENT_SCALE` and `MACNEUTRON_PRESENT_DUMP` pass through as today.

### 3.8 Shader pre-caching

Unchanged in shape (`ShaderPrecache.swift`): recordings in `compatdata/<appid>/dxmt-pipelines`, replayed before the
game when the stamp (DXMT version and macOS build) differs. The DXMT version now comes from `wine.app`'s `DXMT/version`
and the replayer is `wine.app`'s `dxmt-replay.exe`, run with `wine.app`'s `wine` in the game's prefix under §3.7's
environment. A Rosetta-era stamp differs, so the first arm64 launch replays once.

### 3.9 Installing `wine.app` (the app, at every start)

`AppModel.init` already refreshes the tool files at every start (`AppModel.swift:74-77`). It now also installs
`wine.app`:

1. Compare the build identity (§5.1) of `MacNeutron.app/Contents/Helpers/wine.app` with the tool folder's
   `wine.app`. Equal: done.
2. If any process runs an executable inside the tool folder's `wine.app` (found by its path, e.g. `pgrep -f`), defer to
   the next start and log it: a new client cannot talk to an older running wineserver.
3. Clone the nested copy to `wine.app.new` (`cp -c -R`: an APFS clone, instant; a full copy elsewhere), check it with
   `codesign --verify --strict`, rename the old `wine.app` to `wine.app.old`, rename `wine.app.new` to `wine.app`, and
   delete `wine.app.old`. Leftover `.new` or `.old` folders from an interrupted start are deleted first.
4. Remove the Rosetta-era entries listed in §3.1 if present.

The tool folder's path has spaces (`Application Support`), as `check.sh` tests.

### 3.10 Stopping and logs

Stop runs `wineserver -k` with the game's prefix (`Launcher.swift:127-133`); with one runtime there is no other prefix
to pick. `launcher.log`'s line reports `runtime=<CFBundleShortVersionString> (<identity, 12 hex digits>)` instead of
`runtime=` and `gptk=`. The game log (`steam-<appid>.log`) is unchanged.

### 3.11 Binaries and the app

The CLI and the app build arm64 only (`swift build -c release --arch arm64`), so Steam's x86_64 preference has
nothing to pick. `Package.swift`'s platform and the app's `LSMinimumSystemVersion` become macOS 27.

Setup (`SetupView`) becomes: requirements (macOS 27, Apple Silicon, Steam installed; the app explains and stops
otherwise), the runtime (installed automatically, §3.9; the step shows `wine.app`'s version, or the deferral), and
Steam Play mode (unchanged). The "Install runtime" download and "Import Game Porting Toolkit" steps and their views,
`RuntimeInstaller`'s tarball pin, `GPTKDiskImage`, `GPTKImporter` and `DXMTInstaller` are deleted. `GamesView` loses the
AVX column and its graphics picker offers DXMT and wined3d. `SteamPlayMode.enable` no longer checks for Rosetta.

## 4. What stays the same

Steam Play mode (`steam_dev.cfg`, the two tool links, the per-game mappings, the passthrough for Mac games), the verbs
and their locking, `wineserver -w` waits, the game log, orphan prefix cleanup, `ProcessRunner` and the tests' fake
runner.

## 5. `wine.app` changes

### 5.1 Version and identity

`bundle.sh` writes `CFBundleShortVersionString` (`$VERSION` in a release build, `dev` otherwise) and `CFBundleVersion`
into `wine.app`'s Info.plist before signing. The **build identity** is the SHA-256 of
`Contents/_CodeSignature/CodeResources`, which seals every file's hash and the Info.plist; the app (§3.9), the prefix
stamp (§3.4) and the log line (§3.10) all use it. No key carries it, so nothing in the build has to compute it.

### 5.2 Release mode

`bundle.sh --release` (used only by §6) additionally, before signing:

- strips debug info: `llvm-strip --strip-debug` (from the arm64 LLVM build) on every PE file under
  `lib/wine/aarch64-windows/` and `DXMT/aarch64-windows/`, and `strip -S` on every Mach-O under `lib/` and `MacOS/`;
- deletes the `.a` import libraries under `lib/wine/`;
- and then runs every existing assertion: the builtin marker, CHPE metadata, the x18 scan, the symbol lists, the
  install IDs, no build path in the two dylibs, `licences_test.sh`, the signing checks.

Development builds keep their debug info. The release record notes the bundle's size before and after.

### 5.3 The presenter inside `wine.app`

`make presenter` builds the presenter for arm64 only. `bundle.sh` copies `libmacneutron-present.dylib` into
`lib/wine/aarch64-unix/` and signs it with the rest. A new DXMT patch (`wine-arm64/patches/dxmt/0002`) makes
`winemetal.so`'s unix initialisation, when `MACNEUTRON_PRESENT` is `1`, `dlopen` the presenter from its own folder
(`@loader_path/libmacneutron-present.dylib`) and log one line if that fails; nothing else changes in DXMT. The
presenter's constructor then installs its hooks as today. Library validation is already disabled for the loader, and
the dylib carries the bundle's Developer ID signature anyway.

The presenter swizzles `CAMetalLayer -nextDrawable`; Wine patch 13's `WineMetalLayer` (a `CAMetalLayer` subclass)
overrides `nextDrawable` to post its present report. Gate L4 proves upscaled frames still come out. If the subclass
override bypasses the swizzle, the presenter also swizzles `WineMetalLayer` when that class exists.

## 6. The release

### 6.1 Prerequisites (the maintainer's, once)

- `xcrun notarytool store-credentials macneutron` (an Apple ID with an app-specific password, or an App Store Connect
  API key). The script reads the profile name from `MACNEUTRON_NOTARY_PROFILE` (default `macneutron`).
- The provisioning profile at a stable path, given by `MACNEUTRON_PROVISIONING_PROFILE` (today it is only in
  `~/Downloads`). Never in the repo.
- `MACNEUTRON_SIGN_IDENTITY` as for `make wine-arm64`.

### 6.2 R0: the notarization trial (the first task)

Before any release machinery: zip today's staged `wine.app` (`ditto -c -k --keepParent`), `notarytool submit --wait`,
staple it, put a quarantined copy (`xattr -w com.apple.quarantine …`) at a path with a space, and run its loader on
`arm64-hello.exe` in a fresh prefix. This proves Apple notarizes a bundle with the restricted
`com.apple.developer.cross-architecture-support` entitlement and an embedded profile, and that Gatekeeper lets it
launch (native spec §11 lists this as unverified). **If Apple rejects it, or Gatekeeper blocks the launch, work stops
and the maintainer decides**; nothing else in this spec depends on a workaround.

### 6.3 `make release VERSION=0.1.0` (`release/release.sh`)

1. **Refuses development inputs**, naming each failure: a dirty repo or a HEAD not on `origin/main`; any of the four
   patched trees not in applied mode (`lib.sh`'s `build_mode`); `+dirty` or any `*_SERIES=dev` in the staged
   `licenses/SOURCE`; a DXMT commit not published (`dxmt/published.sh`); a `VERSION` that is already a tag, or not
   `MAJOR.MINOR.PATCH`.
2. **Builds a release `wine.app`**: `make wine-arm64` with `VERSION` and `bundle.sh --release` (§5.2), into
   `build/release/<VERSION>/`, never over the dev bundle.
3. **Builds `MacNeutron.app`** (arm64): `Contents/MacOS/MacNeutron`, `Contents/Helpers/macneutron`,
   `Contents/Helpers/wine.app` (copied with `ditto`, which keeps its signature and symlinks),
   `Contents/Resources/steam.exe` (aarch64), `Contents/Resources/licenses/` (§7). Info.plist gets the version and
   `LSMinimumSystemVersion` 27.0. Signs inside-out with `MACNEUTRON_SIGN_IDENTITY`, `--options runtime`, `--timestamp`:
   the CLI, then the app; `wine.app` is **not** re-signed (that would drop its profile and entitlements), the outer
   signature seals it. No entitlements on the outer app.
4. **Notarizes**: `ditto -c -k --keepParent` → `notarytool submit --wait` (on rejection, prints `notarytool log <id>`
   and stops) → `stapler staple MacNeutron.app` → zip again → `spctl -a -vvv -t exec MacNeutron.app` must say
   `accepted`. Output: `MacNeutron-<VERSION>.zip`.
5. **Builds `MacNeutron-<VERSION>-source.tar.gz`** (§7.2).
6. **Writes `SHA256SUMS`** for both files, records the sizes, and prints the `git tag v<VERSION>` and
   `gh release create` commands. It never tags, pushes or uploads.

`make app` stays the development build: ad-hoc signed outer app with the dev `wine.app` nested in `Helpers/`.

## 7. Licences

### 7.1 MacNeutron's own

A root `LICENSE` (MIT, "Copyright (c) 2026 Chad Cormier Roussel"). README gets a Licence section: MacNeutron's own
code is MIT; `wine-arm64/patches/wine/` and `wine-arm64/patches/dxmt/` are LGPL-2.1-or-later like their upstreams;
`wine-arm64/patches/fex/` is MIT; `wine-arm64/patches/lsteamclient/` follows lsteamclient's terms; `wine.app`'s
components are listed in its own `licenses/`.

`MacNeutron.app/Contents/Resources/licenses/` holds `LICENSE` (MIT), the llvm-mingw and mingw-w64 runtime texts for
`steam.exe` (the same files as `wine.app`'s `licenses/llvm-mingw/`), and a README pointing to
`Contents/Helpers/wine.app/Contents/Resources/licenses/` for everything else. `licences_test.sh` gains an app mode
that checks these files and runs the existing check on the nested `wine.app`. The Rosetta app's missing LLVM and
mingw-w64 notices (parked in roadmap row 5) disappear with the Rosetta DXMT build: the release ships no x86_64 DXMT.

### 7.2 The source archive

`MacNeutron-<VERSION>-source.tar.gz` contains: the repo at the release commit (`git archive`); the exact patched trees
as built (Wine at `WINE_COMMIT` with patches 0001-0019 applied, FEX at `FEX_COMMIT` with its submodules and patches,
DXMT at its pinned commit with its patches, lsteamclient at Proton `db9e6ff` with its patches), each from `git archive`
of the applied tree; and the four pinned tarballs (FreeType, gnutls, nettle, GMP). LLVM 15 (Apache-2.0 with the LLVM
exception) and llvm-mingw's toolchain carry no source obligation and are cited by commit in `licenses/SOURCE`. Gate R5
checks the archive holds every input `SOURCE` names, with matching hashes.

## 8. Development tooling

### 8.1 The frozen Rosetta reference (the first implementation step, after R0)

`tools/freeze-rosetta-reference.sh` clones (`cp -cR`) today's installed tool folder, which holds the Rosetta runtime,
the old `macneutron` binary and the imported D3DMetal, into
`~/Library/Application Support/MacNeutron Reference/rosetta-tool/` and writes what it copied (the runtime and GPTK
versions) beside it. It refuses if D3DMetal is missing or the destination exists; it never writes the installed tool
folder. The check scripts read `MACNEUTRON_REFERENCE` (default that path) and stop with a clear message when it is
missing. It is never shipped and never committed.

### 8.2 Checks

| Check | Before | After |
|---|---|---|
| `dxmt/check.sh` | Rosetta mode (default) and arm64 mode | arm64 only; "ours" lanes run through the launcher (the new CLI in a cloned tool folder holding the dev `wine.app`); the D3DMetal reference runs through the frozen tool; sections 10 and the `MACNEUTRON_LOG` check run (L1, L2) |
| `wine-arm64/check.sh` | Rosetta baselines from a clone of the installed tool | the same baselines from the frozen tool |
| `bridge/check.sh` | Rosetta and arm64 modes | arm64 only, plus a run through the launcher (L3) |
| `presenter/check.sh` | presenter injected under Rosetta on D3DMetal | arm64: loaded by `winemetal.so` (L4) |
| `Tests/Smoke/smoke.sh` | the launcher on the Rosetta runtime | the launcher on `wine.app` (L5) |
| Swift tests | Rosetta paths | §9's unit tests |

No development step writes the installed tool folder: every launcher run uses a cloned tool folder, as
`dxmt/check.sh` does today. `make dxil-corpus` switches to `build/wine-arm64/dxil-translate`; then `make dxmt`'s x86_64
DXMT build is deleted if nothing reads it any more (`build/dxmt-src` stays: it holds the `llvm-project` and llvm-mingw
that `wine-arm64/build.sh` uses). The x64 test programs (`make dxmt-tests`) stay: they run under FEX.

## 9. Gates

**Unit tests (`make test`):** the Rosetta tests go with their code. New: `ToolLayout` on a `wine.app`; preflight
(macOS version, a 32-bit PE header, a non-PE target, a missing `wine.app`); the prefix recipe through `FakeRunner`'s
command record (the boot overrides, the FEX key, the DXMT copy, the stamp, the Rosetta-era rename and its numbering);
the install swap (identity equal, different, deferred while a process runs, leftovers cleaned) on temporary folders;
the arm64 bridge files; the pre-cache paths; the graphics cases; old settings files.

**Launcher gates (L), against a cloned tool folder:**

| Gate | Passes when |
|---|---|
| L1 | `dxmt/check.sh` section 10 in arm64 mode: recordings land in the compat folder, the first session stamps the builds, a changed stamp replays before the game, which then only hits |
| L2 | With `MACNEUTRON_LOG=1`, the unsupported-op line reaches the game log in arm64 mode |
| L3 | `bridge/check.sh` through the launcher: `init: ok` and an auth ticket, with no SteamID printed |
| L4 | MetalFX through `winemetal.so`: `present_loop.exe` at a lower resolution produces an upscaled frame (pixel check as `presenter/check.sh` does today), and with `MACNEUTRON_NO_METALFX=1` none |
| L5 | `smoke.sh` on `wine.app`: a 32-bit exe is refused with §10's message; a Rosetta-era prefix is renamed to `pfx.rosetta` and a fresh prefix boots; an x64 and an ARM64EC test program exit with their codes; `wined3d` draws with `d3d11probe.exe` |
| L6 | The app's install, with a real `wine.app` on temporary folders: the first start installs it, the second does nothing, a running process from it defers the swap, an interrupted swap is cleaned up |

**Existing gates, in their arm64 forms:** `make test`, `make wine-arm64-check`, `make dxmt-check`, `make bridge-check`.

**Release gates (R):**

| Gate | Passes when |
|---|---|
| R0 | §6.2: notarized, stapled, a quarantined copy launches |
| R1 | `release.sh --self-test` feeds it a dirty tree, a `dev` series, a `+dirty` SOURCE and an existing tag, and each is refused by name |
| R2 | The zip is notarized and stapled; `spctl -a -vvv -t exec` says `accepted` |
| R3 | The release `wine.app` passes every `bundle.sh` assertion after stripping; its size is recorded |
| R4 | `licences_test.sh` passes on `MacNeutron.app` (app mode) and its nested `wine.app` |
| R5 | The source archive holds every input `SOURCE` names, with matching hashes |
| R6 (maintainer) | In a fresh macOS user account: download the zip (quarantined), unzip, open the app, complete setup, turn on Steam Play mode, and launch Spacewar (480) from Steam through the bridge |

**Gate S (maintainer), before tagging:** SMITE 2 reaches gameplay through the release candidate, in R6's fresh account
(SMITE 2 installed there, or in a Steam library folder both accounts share), so the maintainer's own setup is untouched.
Frame times are row 6's, not a gate.

## 10. Errors

| Condition | What the player sees | Where |
|---|---|---|
| macOS below 27, or an Intel Mac | Setup explains and stops; a launch exits non-zero with the same text | app setup; `launcher.log`, notification |
| `wine.app` missing or unreadable | "MacNeutron's runtime is missing or damaged: open MacNeutron to repair it." | `launcher.log`, game log, notification |
| `wine.app` fails `codesign --verify` at install | Not installed; the old copy stays; setup shows the error | app |
| The entitlement is refused (Wine patch 0007's message) | Same text as "damaged", with Wine's line in the game log | game log |
| A 32-bit game | "This game is 32-bit. MacNeutron 0.1 runs 64-bit games only; 32-bit support is planned." | `launcher.log`, game log, notification |
| Rosetta-era prefix | Renamed to `pfx.rosetta`, logged; the game starts in a fresh prefix | `launcher.log` |
| Install deferred (a runtime process runs) | Setup says the runtime updates after the game exits | app, `launcher.log` |
| Presenter fails to load | One line; the game runs without upscaling | game log |
| Old settings value (`d3dmetal`, `dxvk`, `avx`) | Read as DXMT / ignored, logged once | `launcher.log` |
| A release refusal or notarization rejection | The failing input by name; `notarytool log <id>` | `release.sh` output |

## 11. Acceptance

`docs/testing/acceptance-arm64-release.md` records: R0's notarization submission ID and result; every gate's result;
the release `wine.app` size before and after stripping; the zip and archive sizes and `SHA256SUMS`; the maintainer's R6
and S notes. After that the maintainer publishes and installs the release on their own Mac: their Rosetta prefixes
become `pfx.rosetta`, kept; their 32-bit and Direct3D 9 games stop until rows 7 and 8, and can still be run by hand
from the frozen reference.

## 12. Risks

| Risk | Mitigation |
|---|---|
| Apple rejects notarization of the restricted entitlement, or Gatekeeper blocks a quarantined `wine.app` | R0 runs first; work stops for the maintainer's decision |
| SMITE 2 doesn't reach gameplay on arm64 (FEX, anti-cheat, an untested API) | Gate S before tagging; the release waits, the maintainer decides |
| lsteamclient's licence | The maintainer's accepted risk (§1); the binary and its licence text ship together; a later release can drop it |
| Stripping breaks a PE file Wine or FEX reads (CHPE metadata, the builtin marker) | §5.2 runs every assertion after stripping; R3 |
| The presenter and Wine patch 13's layer subclass | L4; the fallback swizzle in §5.3 |
| `wined3d` on arm64 untested | L5 draws with it; if it fails, the `graphics` setting is dropped (DXMT only) |
| The installed `wine.app` replaced under a running game | §3.9 defers while any of its processes runs |
| The app's macOS 27 minimum excludes macOS 26 users | `wine.app` needs 27 anyway (the native spec's decision) |
| Steam changes the compat-tool gate (`steam_dev.cfg`) | Unchanged from today's app; out of scope |
| The provisioning profile expires (2044) | Checked at build time (`lib.sh`); noted in the README |

## 13. Amendments to the native arm64 spec (made with this spec)

- **§1 decisions:** the per-game cutover ("a game moves once it runs at about 1.4x the Rosetta CPU cost or better";
  "32-bit and Direct3D 9 stay on Rosetta until their sub-projects land") is superseded on 2026-10-04: the first release
  is arm64-only, by the maintainer's decision.
- **§2 row 5:** points to this spec, with its scope.
- **§2 row 6:** frame-time and CPU-cost measurements stay planned but gate nothing.
- **§2 rows 7 and 8:** "restore Direct3D 9 / 32-bit support", which the arm64-only release drops.
- **§2 row 9:** folded into row 5 (the deletions of GPTK, DXVK, the AVX switch and the Rosetta preflight happen there).
- **§11:** the notarization risk points to R0.
