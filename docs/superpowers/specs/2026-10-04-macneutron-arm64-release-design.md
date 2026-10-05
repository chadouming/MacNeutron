# MacNeutron — Native arm64 stack, sub-project 5: the arm64-only release

- **Date:** 2026-10-04 (revised the same day after an adversarial review: three lenses, each re-checked by a sceptic;
  `docs/research/2026-10-04-arm64-release/spec-review.md`)
- **Status:** Approved by the maintainer on 2026-10-04 ("yes, go ahead"), after the design was approved in conversation
  section by section the same day, with the maintainer's decisions in §1.
- **Builds on:**
  - `2026-10-02-macneutron-native-arm64-design.md` (the roadmap; this spec amends its §1, §2 and §11, see §13)
  - `2026-10-03-macneutron-arm64-dxmt-design.md` (DXMT in `wine.app`; its §6 says how a prefix gets DXMT)
  - `2026-10-04-macneutron-ship-base-wine-design.md` (the shippable `wine.app`, msync, the Steam bridge, licences)
  - `2026-09-27-macneutron-app-design.md` and `2026-09-28-macneutron-steam-bridge-design.md` (the launcher and app this
    spec changes)
- **Evidence:** `docs/research/2026-10-04-arm64-release/` (four maps of the code at `95f8883` with `file:line`
  citations, and the spec review).
- **Scope:**
  - **In:**
    - the launcher runs every game on the native arm64 runtime (`wine.app`); the Rosetta runtime, GPTK/D3DMetal, DXVK,
      the AVX switch, the Rosetta DXMT build and the Rosetta preflight are deleted (roadmap row 9's deletions, moved
      here);
    - `wine.app` installed by the app from inside `MacNeutron.app`; prefixes prepared with `check.sh`'s recipe; the
      arm64 Steam bridge, DXMT, msync and shader pre-caching wired through the launcher;
    - Steam's two tool entry points made native, so no MacNeutron process needs Rosetta (§3.1, R0b);
    - the MetalFX presenter loaded by DXMT's `winemetal.so` instead of `DYLD_INSERT_LIBRARIES`;
    - the first public release: an MIT licence, a release build that refuses development inputs and strips debug
      info, notarization of `wine.app` and of `MacNeutron.app`, the source archive, the documentation rewrite, and the
      release record;
    - the dev checks moved to arm64, with a frozen copy of today's Rosetta tool kept as their D3DMetal and timing
      reference.
  - **Out:**
    - 32-bit games (roadmap row 8) and DXMT's Direct3D 9 (row 7): they stop working with this release and come back
      with those rows;
    - frame-time and CPU-cost measurements (row 6; they no longer gate anything, §13);
    - media playback (row 10);
    - publishing: the release script stops before `git tag` / `gh release create`, which the maintainer runs;
    - installing the release on the maintainer's Mac (the maintainer's last step, §11).

## 1. Goal

Anyone with an Apple Silicon Mac on macOS 27 can download one notarized `MacNeutron-0.1.0.zip`, open the app, turn on
Steam Play mode, and play 64-bit Windows Steam games on the native arm64 runtime. Every process MacNeutron starts, from
Steam's tool entry point to the game, runs native: MacNeutron itself needs no Rosetta (proved per process in R6 and,
for the entry point, by R0b).

**Sub-project 5 is done when** §9's gates pass, the maintainer has run R6 and S, and `make release VERSION=0.1.0`
has produced the notarized zip, the source archive and `SHA256SUMS`, recorded in
`docs/testing/acceptance-arm64-release.md`. Publishing is the maintainer's step after that.

### Decisions (maintainer, 2026-10-04)

| Decision | Choice |
|---|---|
| Scope | One spec for the launcher wiring and the first release (not split) |
| Runtimes in the release | **arm64 only.** Rosetta, GPTK/D3DMetal, DXVK and the AVX switch leave the launcher and the release. The per-game cutover of the native spec §1 (a game moves when measured) is superseded: every game moves now |
| The Rosetta code in the repo | **Deleted** from the launcher, the app and the build (the x86_64 DXMT build too). The dev checks keep a Rosetta *reference* (D3DMetal pixels, Rosetta timing baselines) through a frozen copy of today's installed tool (§8.1), never shipped |
| lsteamclient in the release | **Shipped** inside `wine.app` as built today, with its licence text. The maintainer accepts the risk that the Steamworks SDK licence doesn't grant redistribution of the generated interface code (`map-release.md`; the ship-base spec's decisions) |
| lsteamclient's source | In the release source archive, as built (its `lsteamclient/` folder without the `steamworks_sdk_*` trees, which the build excludes too). Still never committed to this repo |
| MacNeutron's own licence | **MIT** for the launcher, app, scripts, tests and presenter. Patches keep their upstream licences: Wine and DXMT patches LGPL-2.1-or-later, FEX patches MIT, lsteamclient patches under lsteamclient's terms |
| How `wine.app` ships | **Nested in `MacNeutron.app`** (`Contents/Helpers/wine.app`); one download; the app installs it into the tool folder |
| MetalFX on arm64 | The presenter is built into `wine.app` and **loaded by `winemetal.so`** (a DXMT patch), not injected; no new entitlement |
| Launcher structure | **Swap in place**: one runtime, no runtime abstraction; `check.sh`'s prefix recipe moves into the launcher |
| Release version | `0.1.0` (the app's `CFBundleShortVersionString` already says so) |
| Publishing | The maintainer's step; the release script prints the commands and stops |

Choices made while writing and reviewing this spec, within those decisions:

- `wine.app`'s **build identity** is its loader's CDHash (§5.1).
- `wine.app` nests in `MacNeutron.app/Contents/Helpers/`, a code location (`Helpers/` already holds the CLI).
- `wine.app` is **notarized and stapled on its own** before it is nested, so the copy the app puts in the tool folder
  carries its own ticket (§6.3).
- The Rosetta DXMT lanes of `dxmt/check.sh` (the DXMT 0.80 `stock` lane and the `x86` frame-time lane) are dropped
  with the x86_64 DXMT build: they measured a runtime that no longer ships (§8.2).

## 2. Evidence (2026-10-04, code at `95f8883`)

- **One layout object holds every runtime path.** `CommandLineTool.swift:18` builds one `ToolLayout(executable:)`
  (the CLI's folder two levels up, `ToolLayout.swift:10-12`); every Rosetta path is read from it
  (`ToolLayout.swift:20-58`).
- **Per-game choice already has a channel.** `GameSettings.environment` (`GameSettings.swift:23-31`) is merged under
  the launch options (`Launcher.swift:48`) before preflight (`:53`).
- **The Rosetta runtime is required in three places:** preflight checks Rosetta 2 (`Preflight.swift:29-36`),
  `SteamPlayMode.enable` checks it (`SteamPlayMode.swift:44,93`), and the app's start-up gates on the Rosetta runtime's
  `runtime-version` file: the tool-file refresh (`AppModel.swift:74-77`), `setupComplete` (`:85`), the setup steps
  (`SetupView.swift:17-19,37`), the launcher's prefix stamp and log line (`Launcher.swift:68,117`).
- **Steam starts tools preferring x86_64** (`SteamPlayMode.swift:20-23`). The runtime tool's entry point is the
  universal `/bin/sh` stub `proton` (`RuntimeInstaller.swift:50-62`; `lipo -archs /bin/sh`: `x86_64 arm64e`), and the
  Mac-game tool's is `passthrough.sh` (`SteamPlayMode.swift:215-218`). Under a binary preference the first matching
  slice is chosen (`man posix_spawnattr_setbinpref_np`), so both shells run as x86_64 today. Steam itself is universal.
- **`wine.app`'s recipe lives in `wine-arm64/check.sh`:** install by `cp -cR` to a path with a space (`:19,615`); boot
  with `WINEDLLOVERRIDES="mscoree,mshtml=" wineboot -i` (`:156`; `wine.app` ships no Mono or Gecko); register FEX with
  `reg add HKLM\Software\Microsoft\Wow64\amd64 /ve /d libarm64ecfex.dll /f` (`:208`; the native spec §6 assigns it to
  this sub-project); copy `Resources/DXMT/aarch64-windows/*` into `system32` (`:467-468`); `WINEMSYNC=1` everywhere
  (`:32`); find running Wine processes with `lsof -t` on the loader and server, because Wine rewrites a client's argv
  (`:46-58`; native spec §3.3). The launcher boots without `mscoree,mshtml=` (`PrefixManager.swift:48`).
- **`wine.app`'s layout** (`bundle.sh:35-55`, verified on the staged bundle): `Contents/MacOS/wine` (the entitled
  loader); `Contents/Resources/bin/` (wineserver and Wine's developer tools); `Contents/Resources/lib/wine/aarch64-{windows,unix}/`
  (FEX, `winemetal`, `lsteamclient.dll` ARM64X 57 MB, `lsteamclient.so`, FreeType, gnutls);
  `Contents/Resources/DXMT/{aarch64-windows/{d3d10core,d3d11,d3d12,dxgi}.dll, dxmt-replay.exe, version}`;
  `Contents/Resources/licenses/`. No i386 part. 1.3 GB staged.
- **The arm64 Steam bridge** needs `build/bridge/arm64/steam.exe` (aarch64) and the bundle's ARM64X `lsteamclient.dll`
  copied as `steamclient64.dll`; there is no 32-bit half (`bridge/probe.sh:42-47,71-75`). `bridge/tests/helper.exe`
  is a test program, not a prefix file (roadmap row 5's wording was a slip).
- **The presenter is injected with `DYLD_INSERT_LIBRARIES`** (`Launcher.swift:159-167`), on unless
  `MACNEUTRON_NO_METALFX=1`; `wine.app` is hardened (`bundle.sh:116,118`) without
  `allow-dyld-environment-variables`, so dyld ignores the variable. The presenter turns itself on when loaded (its
  constructor, `presenter/present.m:290-297`). Wine patch 13's `WineMetalLayer` calls `[super nextDrawable]`
  (`winemac.drv/cocoa_window.m:839-856`), so the presenter's swizzle of `CAMetalLayer -nextDrawable` still fires.
- **`wine.app` has no version inside the bundle.** Its `CodeResources` seals every nested file but omits `Info.plist`
  and doesn't list the loader; the loader's code directory binds `Info.plist`, `CodeResources` and the entitlements
  (`codesign -dvvv`: `Info.plist entries=6`, `CDHash=…`).
- **Nothing has been released:** no tag, no GitHub release, no LICENSE file. `make app` signs ad hoc with no hardened
  runtime or timestamp (`Makefile:86-104`). Only the maintainer's team can build a working `wine.app` (no ad-hoc mode,
  `lib.sh:56-83`).
- **Most of `wine.app` is debug info:** Wine builds its PE side with `-g -O2 -gdwarf-4`; `lsteamclient.dll` is 4.4 MB
  of code and data against 52 MB of DWARF (`map-release.md`); 249 `.a` import libraries (36 MB) ship too.
- **The app quits Steam with `open steam://exit`** and posts notifications through `osascript`
  (`SteamLocation.swift:121-133`, `Preflight.swift:44-56`): separate processes, so the hardened runtime needs no Apple
  Events entitlement.
- **The dev checks use the installed Rosetta tool as a reference:** `dxmt/check.sh` clones it, copies the new CLI into
  the clones and installs our x86_64 DXMT with `install-dxmt` (`:31-44`); `wine-arm64/check.sh` measures Rosetta
  baselines with a clone into which it copies the new CLI (`:438-439`); `Tests/Smoke/smoke.sh` builds its tool folder
  with `install-runtime` and `import-gptk` (`:15-21`).
- **Steam's install scripts never ran here:** of 8,783 logged launches, 0 used the `run` verb (`launcher.log`), though
  Steam's redistributables (`VC_redist.x64.exe`, `DXSETUP.exe`) are i386 PE files.

## 3. The launcher

### 3.1 The tool folder

After this sub-project, `~/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron/` holds:

```
bin/macneutron            the CLI, arm64 only
bin/steam.exe             the aarch64 Steam bridge launcher (build/bridge/arm64/steam.exe)
toolmanifest.vdf          "commandline" "/bin/macneutron launch %verb%" (R0b), or "/proton %verb%"
compatibilitytool.vdf     unchanged
proton                    the /bin/sh stub, only if R0b fails
wine.app/                 cloned from MacNeutron.app/Contents/Helpers/wine.app (§3.9)
```

**Steam's entry points (R0b).** Steam spawns a tool with an x86_64 preference, so a universal file at the entry point
runs translated. The runtime tool's manifest points straight at the arm64-only CLI (`/bin/macneutron launch %verb%`),
and the `proton` stub goes. The Mac-game tool's `passthrough.sh` becomes a CLI verb, `macneutron passthrough %verb%
<command…>`, from a copy of the CLI in `macneutron-native/bin/`; it resolves an `.app` target as the script does and
`posix_spawn`s it with the binary preference arm64e, arm64, x86_64 (what `arch -arm64e -arm64 -x86_64` does today), with
`POSIX_SPAWN_SETEXEC` so Steam keeps tracking the same PID. R0b, run before the launcher work, proves Steam launches a
thin arm64 tool binary. If it doesn't, both entry points stay `/bin/sh` scripts and §1's claim narrows to "every
process after the entry point".

`ToolLayout` reads every runtime path from `wine.app`: `wine` = `Contents/MacOS/wine`, `wineserver` =
`Contents/Resources/bin/wineserver`, DXMT = `Contents/Resources/DXMT/aarch64-windows/`, DXMT's version =
`Contents/Resources/DXMT/version`, the replayer = `DXMT/aarch64-windows/dxmt-replay.exe`, lsteamclient =
`Contents/Resources/lib/wine/aarch64-windows/lsteamclient.dll` and `…/aarch64-unix/lsteamclient.so` (the bridge counts
as installed when both exist), the version = `CFBundleShortVersionString`, the identity per §5.1.

The Rosetta-era entries `Libraries/`, `gptk/`, `gptk.json`, `lib/`, `dxmt-version`, `runtime-version` and
`runtime.staging` are removed by the app (§3.9). `~/Library/Caches/MacNeutron/runtime-v*.tar.gz` is left alone; the
README says it can be deleted.

### 3.2 Per-game settings

`GameSettings` keeps `graphics`, `log`, `msync`, `runAs` and `metalFX`; `avx` is removed. `graphics` takes `dxmt` (the
default) or `wined3d` (Wine's built-in Direct3D 9-11 over OpenGL: an escape hatch for a Direct3D 11 game DXMT breaks;
Direct3D 12 needs DXMT). Settings files written by earlier builds still load: unknown keys are ignored, and any other
`graphics` value (`d3dmetal`, `dxvk`) reads as `dxmt` with a note on that launch's `launcher.log` line. Launch options
still override everything (`/usr/bin/env VAR=value %command%`).

### 3.3 Preflight (every launch)

In order, each failure ending the launch with §10's message:

1. macOS 27 or later, on Apple Silicon (`hw.optional.arm64`).
2. `wine.app/Contents/MacOS/wine` and `Contents/Resources/bin/wineserver` are executable and the identity is readable.
   The full signature check runs at install (§3.9), not here: on a bundle this size it takes seconds. A failure here
   writes `<tool>/runtime-damaged`, which makes the app reinstall (§3.9).
3. For `waitforexitandrun`: when the target parses as a PE file, its `Machine` must be `0x8664` (x64 and ARM64EC) or
   `0xAA64` (ARM64 and ARM64X). `0x14c` (i386) gets the 32-bit message; any other machine type gets a message naming
   it. A target that isn't PE (a script, a `.bat`) is not checked. For `run` (Steam's install scripts), an i386 target is
   logged as `skipped 32-bit installer <name>` and the verb exits 0, with no notification.

Rosetta is no longer checked anywhere: not here, not in `SteamPlayMode.enable`, not in the app.

### 3.4 Prefixes

The prefix stays `compatdata/<appid>/pfx`, with its stamp in `compatdata/<appid>/version`. The stamp becomes
`wine.app <identity> msync=<0|1>`. Holding `macneutron.lock` as today:

- **Identity differs, or `pfx` missing:** prepare.
  1. A `pfx` whose stamp is absent or doesn't start with `wine.app ` is a Rosetta-era prefix: rename it to
     `pfx.rosetta` (or `pfx.rosetta-2`, `-3`… if taken), never delete it, log it. An arm64 Wine doesn't adopt an
     x86_64 Wine's prefix. Only the maintainer's Mac has such prefixes.
  2. Write `wine.app preparing` to the stamp, so a failed or stopped preparation is retried in place, never renamed.
  3. `wine wineboot -u` with the game's overrides plus `mscoree,mshtml=` (no Mono or Gecko prompt).
  4. `wine reg add 'HKLM\Software\Microsoft\Wow64\amd64' /ve /d libarm64ecfex.dll /f` (x64 code runs on FEX; without
     it, on Wine's stub `xtajit64`).
  5. The existing `ShowCrashDialog=0` entry.
  6. Copy `DXMT/aarch64-windows/{d3d10core,d3d11,d3d12,dxgi}.dll` into `drive_c/windows/system32/` (no `syswow64`),
     whatever the game's graphics setting: `wined3d`'s overrides ignore them, and switching back to DXMT doesn't change
     the stamp.
  7. `wineserver -w`, then write the full stamp.
- **Only the msync field differs** (the setting changed while a server from the last launch lives on): run
  `wineserver -k` under the old mode's environment, then rewrite the field. A client and a server in different msync
  modes can't talk, and the client's error is hidden under `WINEDEBUG=-all` (ship-base spec §2, §11).

`OrphanPrefixes` is unchanged; it removes `compatdata/<appid>` folders of uninstalled games, `pfx.rosetta` included.

### 3.5 The Steam bridge

When the game runs through the bridge (as today, `Launcher.swift:142-155`), `SteamBridge` keeps
`drive_c/Program Files (x86)/Steam/steam.exe` equal to `bin/steam.exe` and `…/Steam/steamclient64.dll` equal to
`wine.app`'s `lsteamclient.dll`. **New:** it copies only when size or modification time differ, where today it deletes
and re-copies every launch; at 57 MB that matters. There is no `steamclient.dll` (32-bit). The game starts as
`wine 'C:\Program Files (x86)\Steam\steam.exe' <game> <args>`. The launcher sets `STEAM_COMPAT_CLIENT_INSTALL_PATH` and
`MACNEUTRON_STEAM_ACCOUNT` as today (`Launcher.swift:169-184`); `SteamAppId` comes from Steam. The escape hatch
`MACNEUTRON_NO_STEAM_BRIDGE=1` stays.

### 3.6 Graphics

`GraphicsBackend` has two cases. `dxmt`: `dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b` (as today and as the arm64 DXMT
spec §6 uses). `wined3d`: `dxgi,d3d9,d3d10,d3d10core,d3d11,d3d12=b` (Wine's builtins; every backend still names every
Direct3D DLL any backend manages, `GraphicsBackend.swift:28-29`). The D3DMetal and DXVK cases, their prefix files and
the GPTK lookup are deleted.

### 3.7 The environment

Every process the launcher starts in a prefix, `terminate`'s `wineserver -k` included, carries the same `WINEPREFIX`
and `WINEMSYNC`, so client and server always agree on msync. `WINEMSYNC=1` unless the game's msync is off
(`MACNEUTRON_NO_MSYNC=1`, then unset, which means off). `WINEDLLOVERRIDES` is the game's (§3.6), with `mscoree,mshtml=`
added for wineboot. `WINEDEBUG`, `MACNEUTRON_LOG` and `DXMT_PIPELINE_RECORD` behave as today. `ROSETTA_ADVERTISE_AVX`
and `DYLD_INSERT_LIBRARIES` are no longer set. `MACNEUTRON_PRESENT=1` is set unless `MACNEUTRON_NO_METALFX=1` (§5.3);
`MACNEUTRON_PRESENT_SCALE` and `MACNEUTRON_PRESENT_DUMP` pass through as today.

### 3.8 Shader pre-caching

Unchanged in shape (`ShaderPrecache.swift`): recordings in `compatdata/<appid>/dxmt-pipelines`, replayed before the
game when the stamp (DXMT version and macOS build) differs. The DXMT version now comes from `wine.app`'s `DXMT/version`
and the replayer is `wine.app`'s `dxmt-replay.exe`, run with `wine.app`'s `wine` in the game's prefix under §3.7's
environment. A Rosetta-era stamp differs (`1fba8d2…` against `1fba8d2…+63a4969e01ba`), so the first arm64 launch replays
once.

### 3.9 Installing `wine.app`

The install is one function in MacNeutronCore, `RuntimeInstaller.install(wineApp:toolFolder:force:)`, used by the app
and by a CLI verb, `macneutron install --tool-dir <dir> --wine-app <path>`, which the checks and `smoke.sh` use to
assemble cloned tool folders. The CLI verbs `install-runtime`, `import-gptk` and `install-dxmt` and their usage lines
are removed.

1. If any running process's executable (the kernel's path, `proc_pidpath`, not its argv, which Wine rewrites) lies
   inside the tool folder's `wine.app`, or inside a Rosetta-era `Libraries/`, defer: log it and return. A new client
   can't talk to an older running wineserver.
2. Delete leftover `wine.app.new` or `wine.app.old` from an interrupted run.
3. Unless `force`, or `<tool>/runtime-damaged` exists: compare the identity (§5.1) of the source `wine.app` with the
   installed one. Equal: skip to step 5.
4. Clone the source to `wine.app.new` (`cp -c -R`: an APFS clone, instant on the same volume; a full copy otherwise,
   e.g. under App Translocation), check it with `codesign --verify --strict`, then exchange it with the installed copy
   in one `renamex_np(RENAME_SWAP)` (no moment without a `wine.app`; on a first install, a plain rename), delete what is
   now `wine.app.new`, and delete `runtime-damaged`. The copy keeps the quarantine attribute it came with; `wine.app`'s
   own stapled ticket (§6.3) lets Gatekeeper accept it offline.
5. Write the tool files (`bin/macneutron`, `bin/steam.exe`, the manifests), always, so CLI and runtime change together.
6. Remove the Rosetta-era entries (§3.1).

The app runs it at every start in a background task (setup shows "Installing the runtime…"), and again from its
existing 3-second poll (`AppModel.swift:250-275`) while an install is deferred. Settings' **Repair runtime** calls it
with `force`. The menu's status line shows `Runtime <version> (<identity, 12 hex digits>)`.

### 3.10 Stopping and logs

Stop runs `wineserver -k` with the game's prefix and §3.7's environment; it loads the game's settings as launch does.
`launcher.log`'s line reports `runtime=<version> (<identity, 12 hex digits>)` instead of `runtime=` and `gptk=`. The
game log (`steam-<appid>.log`) is unchanged.

### 3.11 Binaries and the app

The CLI and the app build arm64 only (`swift build -c release --arch arm64`). `Package.swift`'s platform and the app's
`LSMinimumSystemVersion` become macOS 27.

`AppModel`'s `runtimeVersion` becomes the installed `wine.app`'s version and identity; `gptkVersion` goes;
`setupComplete` is "`wine.app` installed and Steam Play mode wanted", and the setup window follows it. Setup
(`SetupView`) becomes: requirements (macOS 27, Apple Silicon, Steam installed; the app explains and stops otherwise),
the runtime (installed automatically, §3.9; shows the version or the deferral), and Steam Play mode (unchanged). The
download and GPTK steps, `RuntimeInstaller`'s tarball pin and download, `GPTKDiskImage`, `GPTKImporter` and
`DXMTInstaller` are deleted. `GamesView` loses the AVX column; its graphics picker offers DXMT and wined3d.
`SteamPlayMode.enable` and its tests lose the Rosetta check.

## 4. What stays the same

Steam Play mode (`steam_dev.cfg`, the tool links, the per-game mappings), the verbs and their locking, `wineserver -w`
waits, the game log, orphan prefix cleanup, `ProcessRunner` and the tests' fake runner.

## 5. `wine.app` changes

### 5.1 Version and identity

`bundle.sh` writes `CFBundleShortVersionString` (`$VERSION` in a release build, `dev` otherwise) and `CFBundleVersion`
into `wine.app`'s Info.plist before signing. The **identity** is the loader's CDHash
(`SecStaticCodeCreateWithPath` + `SecCodeCopySigningInformation`, `kSecCodeInfoUnique`; `codesign -dvvv` prints it).
The loader's code directory hashes its own pages and binds `Info.plist`, `CodeResources` (which seals every other file)
and the entitlements, so the identity changes when anything in the bundle changes. Re-signing identical bits keeps it.
The app (§3.9), the prefix stamp (§3.4) and the log line (§3.10) use it.

### 5.2 Release mode

`bundle.sh --release --version <V> --out <folder>` (used only by §6) reads the existing build tree and stages into
`<folder>`, never over `build/wine-arm64/` (the dev bundle and the dev stamp are untouched). In release mode, before
signing:

- strip debug info: `"$(sh dxmt/toolchain.sh)/llvm-strip" --strip-debug` (llvm-mingw's, the toolchain that built the
  ARM64X and ARM64EC files, as `bundle.sh` already uses its `llvm-readobj`) on every PE file under
  `lib/wine/aarch64-windows/` and `DXMT/aarch64-windows/`, and `strip -S` on every Mach-O under `MacOS/`, `bin/` and
  `lib/` (`-S` keeps the local symbols the x18 allow-list names);
- delete the `.a` import libraries and Wine's developer tools (`winegcc`, `wineg++`, `winebuild`, `winedump`, `widl`,
  `wrc`, `wmc`, `winemaker`, `function_grep.pl`) after the plan confirms nothing at run time execs them;
- then run every existing assertion: the builtin marker, CHPE metadata, the x18 scan, the symbol lists, the install
  IDs, no build path in the two dylibs, `licences_test.sh`, the signing checks.

Development builds keep their debug info and tools. The release record notes the bundle's size before and after.

### 5.3 The presenter inside `wine.app`

`build.sh` builds the presenter itself (arm64, `-mmacosx-version-min=27.0`, install name
`@rpath/libmacneutron-present.dylib`); `presenter/present.m` joins the stamp inputs and `presenter` the `+dirty`
pathspec (`build.sh:110-115,144`). `bundle.sh` puts the dylib in `lib/wine/aarch64-unix/` and signs it with the rest.
A new DXMT patch (`wine-arm64/patches/dxmt/0002`) makes `winemetal.so`'s unix initialisation, when
`MACNEUTRON_PRESENT` is `1`, `dlopen` the presenter from its own folder (`@loader_path/libmacneutron-present.dylib`)
and log one line if that fails; nothing else in DXMT changes. The presenter's constructor installs its hooks as today;
`WineMetalLayer` calls `[super nextDrawable]` (§2), so the swizzle fires. `make presenter` keeps building the test
program `present_loop.exe`.

## 6. The release

### 6.1 Prerequisites (the maintainer's, once)

- `xcrun notarytool store-credentials macneutron` (an Apple ID with an app-specific password, or an App Store Connect
  API key). The script reads the profile name from `MACNEUTRON_NOTARY_PROFILE` (default `macneutron`).
- The provisioning profile at a stable path, given by `MACNEUTRON_PROVISIONING_PROFILE` (today it is only in
  `~/Downloads`). Never in the repo.
- `MACNEUTRON_SIGN_IDENTITY` as for `make wine-arm64`.

### 6.2 R0 and R0b: the trials (the first tasks)

**R0, notarization.** Before any release machinery: zip today's staged `wine.app` (`ditto -c -k --keepParent`), run
`syspolicy_check notary-submission`, submit with `notarytool submit --wait --output-format json` (Accepted required),
staple it, check `stapler validate` and `syspolicy_check distribution`. Then make the copy the shipped path makes: put
the stapled bundle in a folder, quarantine every file in it (`xattr -r -w com.apple.quarantine …`), clone it with
`cp -c -R` to a path with a space, and run the clone's loader on `arm64-hello.exe` in a fresh prefix, launched through
launchd (`launchctl submit`), not as a child of a terminal app (Developer Tools are exempt from Gatekeeper), once online
and once with the network off. This proves Apple notarizes a bundle with the restricted
`com.apple.developer.cross-architecture-support` entitlement and an embedded profile, and that Gatekeeper lets its
quarantined copy launch offline (native spec §11 lists this as unverified).

**R0b, Steam's entry points.** Two throwaway test tools, linked beside ours in Steam's `compatibilitytools.d` and each
mapped for one app only (Steam closed while mappings change, as `SteamPlayMode` does): `macneutron-r0b`, whose manifest
runs a thin arm64 binary that records its architecture and argv, mapped for Spacewar (480); and `macneutron-r0b-native`,
the same for a Mac game. Launch both from Steam, then remove the tools and mappings. The installed `macneutron` tools are
never touched. This proves Steam's binary preference falls back to a thin arm64 binary (an x86_64-only preference list
would fail with `EBADARCH` even with Rosetta installed, so this Mac can show it).

**If R0 fails (rejected, or Gatekeeper blocks the copy), work stops and the maintainer decides.** If R0b fails, §3.1's
fallback applies and §1 narrows.

### 6.3 `make release VERSION=0.1.0` (`release/release.sh`)

1. **Refuses development inputs**, naming each failure: a dirty repo or a HEAD not contained in `origin/main`; `make
   wine-arm64` not reporting all four patched trees applied and up to date; `DXMT_COMMIT` from `dxmt/pins` not
   published (`dxmt/published.sh`; our arm64 DXMT patches are never pushed, by design, and their source is in the
   archive); a `VERSION` that is already a tag or not `MAJOR.MINOR.PATCH`.
2. **Builds the release `wine.app`**: `bundle.sh --release --version <V> --out build/release/<V>/` (§5.2). Its own
   `licenses/SOURCE` must have no `*_SERIES=dev`, no `+dirty`, and `MACNEUTRON_COMMIT` equal to HEAD. Then it
   **notarizes and staples `wine.app` on its own**, as R0 does, so every copy carries its ticket.
3. **Builds `MacNeutron.app`** (arm64): `Contents/MacOS/MacNeutron`, `Contents/Helpers/macneutron`,
   `Contents/Helpers/wine.app` (copied with `ditto`, which keeps its signature, ticket and symlinks),
   `Contents/Resources/steam.exe` (aarch64), `Contents/Resources/licenses/` (§7.1). Info.plist gets the version and
   `LSMinimumSystemVersion` 27.0. Signs inside-out with `MACNEUTRON_SIGN_IDENTITY`, `--options runtime`, `--timestamp`:
   the CLI, then the app, never with `--deep`; `wine.app` is not re-signed (that would drop its profile, entitlements
   and ticket); the outer signature seals it. No entitlements on the outer app.
4. **Notarizes the app**: `syspolicy_check notary-submission`, `ditto -c -k --keepParent`,
   `notarytool submit --wait --output-format json` (Accepted required; otherwise `notarytool log <id>` and stop),
   `stapler staple MacNeutron.app`, `stapler validate`, `syspolicy_check distribution`, zip again, and
   `spctl -a -vvv -t exec MacNeutron.app` must say `accepted`. Output: `MacNeutron-<V>.zip`.
5. **Builds `MacNeutron-<V>-source.tar.gz`** (§7.2).
6. **Writes `SHA256SUMS`**, records the sizes, and prints the `git tag v<V>` and `gh release create` commands. It never
   tags, pushes or uploads.

`release.sh --self-test` runs step 1's refusals against prepared bad inputs (R1).

## 7. Licences and documentation

### 7.1 Licences

- A root `LICENSE`: MIT, "Copyright (c) 2026 Chad Cormier Roussel".
- `wine-arm64/licenses/README` (shipped in `wine.app`): the lsteamclient entry says it ships by the maintainer's
  decision of 2026-10-04 under Valve's Steamworks SDK licence (`licenses/lsteamclient/`); a new entry, "MacNeutron
  (`libmacneutron-present.dylib`, the MetalFX presenter; the Wine, DXMT and FEX patch files): MIT,
  `licenses/macneutron/LICENSE`", which `bundle.sh` copies from the root `LICENSE` (the ship-base spec §4's deferred
  MacNeutron line). `licences_test.sh` requires both.
- `MacNeutron.app/Contents/Resources/licenses/`: `LICENSE` (MIT), the llvm-mingw and mingw-w64 runtime texts for
  `steam.exe` (the same files as `wine.app`'s `licenses/llvm-mingw/`), and a README pointing to
  `Contents/Helpers/wine.app/Contents/Resources/licenses/`. `licences_test.sh` gains an app mode that checks these and
  runs the existing check on the nested `wine.app`.
- The Rosetta app's missing LLVM and mingw-w64 notices (parked in roadmap row 5) disappear with the x86_64 DXMT build.

### 7.2 The source archive

`MacNeutron-<V>-source.tar.gz` holds one nested tar per tree, each from `git archive --prefix=<name>/ HEAD` of the
tree as built (patches applied with `git am`, so HEAD contains them; `git get-tar-commit-id` names the commit):

- the repo at the release commit;
- Wine at `WINE_COMMIT` with patches 0001-0019;
- FEX at `FEX_COMMIT` with its patches, and each of the six submodules `SOURCE` lists (`FEX_SUBMODULE_*`), archived from
  the submodule at its recorded commit (`git archive` leaves submodules empty);
- DXMT at `DXMT_COMMIT` with its patches, and its two submodules (`include/native/directx`, `external/nvapi`), whose
  commits `build.sh` adds to `SOURCE` as `DXMT_SUBMODULE_*`;
- lsteamclient: `GIT_NO_LAZY_FETCH=1 git archive HEAD -- lsteamclient/ ':(exclude)lsteamclient/steamworks_sdk_*'
  ':(exclude)lsteamclient/gen_wrapper.py'` (the clone is a sparse, blob-less clone of all of Proton; the build uses
  only this);
- the four pinned tarballs (FreeType, gnutls, nettle, GMP) as downloaded.

LLVM 15 is linked into `winemetal.so` under Apache-2.0 with the LLVM exception (its licence ships in `licenses/llvm/`);
it and llvm-mingw's toolchain carry no source obligation and are cited by tag (`LLVM_TAG`) and tarball hash
(`LLVM_MINGW_SHA256`) in `SOURCE`. R5 checks the archive against `SOURCE`.

### 7.3 Documentation

- `README.md` is rewritten for the release: download the zip and move the app to Applications; requirements (macOS 27,
  Apple Silicon, Steam; no Rosetta); setup (requirements → runtime, automatic → Steam Play mode); per-game options
  (`MACNEUTRON_GRAPHICS=dxmt|wined3d`, `MACNEUTRON_LOG`, `MACNEUTRON_NO_MSYNC`, `MACNEUTRON_NO_METALFX`,
  `MACNEUTRON_NO_STEAM_BRIDGE`; `MACNEUTRON_NO_AVX` gone); 32-bit and Direct3D 9 games not supported in 0.1; where the
  licences are and that the Steam bridge ships under Valve's licence; the CLI's `install` verb instead of
  `install-runtime`/`import-gptk`/`install-dxmt`; building from source needs the Developer ID setup in
  `wine-arm64/README.md` (no ad-hoc `wine.app`); a Licence section (MacNeutron is MIT; the patch folders' licences).
- `wine-arm64/README.md`: the "shipped runtime is still the Rosetta one" and "MacNeutron doesn't redistribute
  lsteamclient" lines, and the Rosetta-baseline prerequisites (now the frozen reference, §8.1).
- `release.sh` refuses when either README still contains `Rosetta 2`, `import-gptk` or `doesn't redistribute`.

## 8. Development tooling

### 8.1 The frozen Rosetta reference (the first step after R0 and R0b)

`tools/freeze-rosetta-reference.sh` clones (`cp -c -R`) today's installed tool folder, which holds the Rosetta runtime,
the old `macneutron` binary and the imported D3DMetal, into
`~/Library/Application Support/MacNeutron Reference/rosetta-tool/` and writes what it copied (the runtime and GPTK
versions) beside it. It refuses if D3DMetal is missing or the destination exists, and never writes the installed tool
folder. The check scripts read `MACNEUTRON_REFERENCE` (default that path) and stop with a clear message when it is
missing. **Reference lanes run the frozen tool's own `bin/macneutron`, unchanged**: no check copies the new CLI into it.
It is never shipped or committed.

### 8.2 Checks and Makefile

| Check | After this sub-project |
|---|---|
| `dxmt/check.sh` | arm64 only. "Ours" lanes run through the new launcher in a tool folder assembled with `macneutron install`; the D3DMetal reference runs through the frozen tool. The DXMT 0.80 `stock` lane and the `x86` frame-time lane are dropped (D6 becomes historical). Section 10 and the `MACNEUTRON_LOG` check run (L1, L2) |
| `wine-arm64/check.sh` | Rosetta baselines (G4, M1, M2) from the frozen tool, with its own CLI |
| `bridge/check.sh`, `bridge/probe.sh` | arm64 only, plus runs through the launcher (L3) |
| `presenter/check.sh` | arm64: the presenter loaded by `winemetal.so` (L4) |
| `Tests/Smoke/smoke.sh` | the launcher on `wine.app`, tool folder from `macneutron install`; `d3d11probe.exe` built with the pinned llvm-mingw, not Homebrew's mingw gcc; lanes `dxmt` and `wined3d` (L5) |
| `dxmt/tests/run.sh` | retargeted at the arm64 lane, or removed |

| Target | After |
|---|---|
| `app` | depends on `build bridge wine-arm64`; clones `build/wine-arm64/wine.app` into `Contents/Helpers/` (`cp -c -R`), `build/bridge/arm64/steam.exe` into `Resources/`; no Frameworks, `Resources/DXMT` or `published.sh` lines; signs the outer app ad hoc without `--deep` |
| `bridge` | builds the arm64 `steam.exe` and `helper.exe` and the x64 `steamprobe.exe` (it runs under FEX); no x64 `steam.exe` or `helper.exe` |
| `presenter` | builds `present_loop.exe` only (the dylib comes from `build.sh`) |
| `dxmt`, `dxil-corpus` | `dxmt` (the x86_64 DXMT build) is deleted; `dxil-corpus` uses `build/wine-arm64/dxil-translate`. `build/dxmt-src` stays: it holds the `llvm-project` and llvm-mingw that `wine-arm64/build.sh` uses |
| `dxmt-check`, `wine-arm64-check` | lose `dxmt`; `dxmt-check` depends on `build wine-arm64 dxmt-tests dxmt-tests-arm64ec presenter` |
| `release` | new: `sh release/release.sh` (§6.3) |

No development step writes the installed tool folder: every launcher run uses an assembled tool folder. `make app` now
needs the signing variables (it builds `wine.app`).

## 9. Gates

**Unit tests (`make test`).** Deleted with their code: `DXMTInstallerTests`, `GPTKDiskImageTests`,
`GPTKImporterTests`, `RuntimeInstallerTests`' download and tarball cases, `CommandLineToolTests`' `install-dxmt` and
`import-gptk` cases, the Rosetta cases of `SteamPlayModeTests` (`rosettaAvailable`), `PreflightTests` and
`GraphicsBackendTests`. `Support.swift`'s fake tool folder becomes a fake `wine.app` tree. New: `ToolLayout` on a
`wine.app`; the identity (two ad-hoc-signed bundles that differ only in the loader, or only in Info.plist, differ);
preflight (macOS version, each PE machine type, a non-PE target, `run` with an i386 target, a missing `wine.app`, the
damaged marker); the prefix recipe through `FakeRunner`'s command record (overrides, FEX key, DXMT copy, `preparing`
then the full stamp, the Rosetta-era rename and its numbering, a failed preparation retried in place, an msync-only
change running `wineserver -k` under the old mode); the install (equal, different, forced, damaged, deferred, leftovers,
tool files always written, Rosetta-era entries removed); the bridge's copy-when-different; the pre-cache paths; both
graphics cases; old settings files; the `passthrough` verb's target resolution and binary preference.

**Launcher gates (L), in assembled tool folders:**

| Gate | Passes when |
|---|---|
| L1 | `dxmt/check.sh` section 10 on arm64: recordings land in the compat folder, the first session stamps the builds, a changed stamp replays before the game, which then only hits |
| L2 | With `MACNEUTRON_LOG=1`, the unsupported-op line reaches the game log on arm64 |
| L3 | `bridge/check.sh` on arm64 through the launcher (exit codes, arguments), and `bridge/probe.sh` through the launcher: `init: ok`, `steamid ok`, an auth ticket of more than 0 bytes, no SteamID printed |
| L4 | MetalFX through `winemetal.so`: `present_loop.exe` at a lower resolution gives an upscaled frame (pixel check as `presenter/check.sh` does today); with `MACNEUTRON_NO_METALFX=1`, none |
| L5 | `smoke.sh`: a 32-bit exe is refused with §10's message; a Rosetta-era prefix is renamed and a fresh one boots; an x64 and an ARM64EC test program exit with their codes; `wined3d` draws with `d3d11probe.exe` |
| L6 | `macneutron install` with a real `wine.app`: the first run installs it, the second does nothing, a real running `wine.app/Contents/MacOS/wine` process defers it, `--force` and the damaged marker reinstall over an equal identity, an interrupted swap is cleaned up; `spctl -a -vvv -t exec` and `stapler validate` on an installed copy of a notarized `wine.app` |

**Existing gates, in their arm64 forms:** `make test`, `make wine-arm64-check`, `make dxmt-check`, `make bridge-check`.

**Release gates (R):**

| Gate | Passes when |
|---|---|
| R0 | §6.2: `wine.app` notarized and stapled; its quarantined clone launches through launchd, online and offline |
| R0b | §6.2: Steam launches thin arm64 tool binaries (or §3.1's fallback is recorded) |
| R1 | `release.sh --self-test`: a dirty tree, a `dev` series, a `+dirty` SOURCE, an unpublished DXMT pin, an existing tag and a stale README are each refused by name |
| R2 | The app in the zip is notarized and stapled: `stapler validate`, `syspolicy_check distribution`, `spctl -a -vvv -t exec` accepted |
| R3 | The release `wine.app` passes every `bundle.sh` assertion after stripping, and L5's programs (x64, ARM64EC, a DXMT draw, the bridge probe) run on it; sizes recorded |
| R4 | `licences_test.sh` passes on `MacNeutron.app` (app mode) and its nested `wine.app`, including the lsteamclient and MacNeutron entries |
| R5 | Every tree in the archive matches its `*_COMMIT` / `*_SUBMODULE_*` commit (`git get-tar-commit-id`), the applied patches recompute each `*_SERIES`, every tarball matches its `*_SHA256`; `LLVM_TAG` and `LLVM_MINGW_SHA256` are cited only |
| R6 (maintainer) | In a fresh macOS user account: download the zip (quarantined), unzip, move the app to Applications, open it, complete setup, turn on Steam Play mode, launch Spacewar (480) from Steam through the bridge (R0 covers the offline Gatekeeper path); `spctl -a -vvv -t exec` accepts the installed `wine.app`; `sysctl.proc_translated` is 0 for every MacNeutron and Wine process |

**Gate S (maintainer), before tagging:** SMITE 2 reaches gameplay through the release candidate in R6's fresh account
(SMITE 2 installed there, or in a Steam library folder both accounts share), so the maintainer's own setup is untouched.
Frame times are row 6's, not a gate.

## 10. Errors

| Condition | What the player sees | Where |
|---|---|---|
| macOS below 27, or an Intel Mac | Setup explains and stops; a launch exits non-zero with the same text | app; `launcher.log`, notification |
| `wine.app` missing or unreadable | "MacNeutron's runtime is missing or damaged. Open MacNeutron to repair it." The damaged marker makes the next app start reinstall | `launcher.log`, game log, notification |
| `wine.app` fails `codesign --verify` at install | Not installed; the old copy stays; setup shows the error | app |
| The entitlement is refused (Wine patch 0007's message) | "MacNeutron's runtime signature was rejected. Download MacNeutron again." | game log, notification |
| A 32-bit game | "This game is 32-bit. MacNeutron 0.1 runs 64-bit games only; 32-bit support is planned." | `launcher.log`, game log, notification |
| Another PE machine type | "This game is built for <machine>, which MacNeutron can't run." | same |
| A 32-bit installer in an install script (`run`) | Nothing; `skipped 32-bit installer <name>`, exit 0 | `launcher.log` |
| Rosetta-era prefix | Renamed to `pfx.rosetta`, logged; the game starts in a fresh prefix | `launcher.log` |
| msync setting changed while a server lives | The old server is stopped, logged | `launcher.log` |
| Install deferred (a runtime process runs) | Setup says the runtime updates after the game exits; retried every 3 s | app, `launcher.log` |
| Presenter fails to load | One line; the game runs without upscaling | game log |
| Old settings value (`d3dmetal`, `dxvk`, `avx`) | Read as DXMT / ignored, noted on each launch | `launcher.log` |
| A release refusal or notarization rejection | The failing input by name; `notarytool log <id>` | `release.sh` output |

## 11. Acceptance

`docs/testing/acceptance-arm64-release.md` records: R0's and R0b's results (with the submission ID); every gate's
result; the release `wine.app` size before and after stripping; the zip and archive sizes and `SHA256SUMS`; the
maintainer's R6 and S notes. After that the maintainer publishes and installs the release on their own Mac: their
Rosetta prefixes become `pfx.rosetta`, kept; their 32-bit and Direct3D 9 games stop until rows 7 and 8, and can still
be run by hand from the frozen reference.

## 12. Risks

| Risk | Mitigation |
|---|---|
| Apple rejects notarization of the restricted entitlement, or Gatekeeper blocks the quarantined copy | R0 runs first; work stops for the maintainer's decision |
| Steam can't launch a thin arm64 tool binary | R0b runs first; §3.1's fallback keeps the shell entry points (they need Rosetta only on a Mac that has it) |
| SMITE 2 doesn't reach gameplay on arm64 (FEX, anti-cheat, an untested API) | Gate S before tagging; the release waits, the maintainer decides |
| lsteamclient's licence | The maintainer's accepted risk (§1); the binary and its licence text ship together; a later release can drop it |
| A Steam update or a newer Steamworks SDK breaks the bridge for a game | `MACNEUTRON_NO_STEAM_BRIDGE=1` per game (README); `LSTEAMCLIENT_COMMIT` moves in a point release |
| Stripping breaks a PE file Wine or FEX reads (CHPE metadata, the builtin marker) | §5.2 strips with the toolchain that built them and runs every assertion afterwards; R3 runs programs on the stripped bundle |
| `wined3d` on arm64 untested | L5 draws with it; if it fails, the `graphics` setting is dropped (DXMT only) |
| The installed `wine.app` replaced under a running game | §3.9 defers on any process whose executable is inside it, and swaps atomically |
| The app's macOS 27 minimum excludes macOS 26 users | `wine.app` needs 27 anyway (the native spec's decision) |
| A first start under App Translocation copies 1+ GB | The install runs in the background with progress; the README says to move the app to Applications |
| Steam changes the compat-tool gate (`steam_dev.cfg`) | Unchanged from today's app; out of scope |
| The provisioning profile expires (2044) | Checked at build time (`lib.sh`); noted in the README |

## 13. Amendments made with this spec

**The native arm64 spec:**

- **§1 decisions:** the per-game cutover ("a game moves once it runs at about 1.4x the Rosetta CPU cost or better";
  "32-bit and Direct3D 9 stay on Rosetta until their sub-projects land") is superseded on 2026-10-04: the first release
  is arm64-only, by the maintainer's decision.
- **§2 row 5:** points to this spec, with its scope.
- **§2 row 6:** frame-time and CPU-cost measurements stay planned but gate nothing.
- **§2 rows 7 and 8:** "restore Direct3D 9 / 32-bit support", which the arm64-only release drops.
- **§2 row 9:** folded into row 5 (GPTK, DXVK, the AVX switch and the Rosetta preflight are deleted there).
- **§11:** the notarization risk points to R0.

**Status lines added to earlier documents:** `2026-09-27-macproton-runtime-design.md`,
`2026-09-27-macneutron-app-design.md`, `2026-09-28-macneutron-metalfx-design.md`,
`2026-09-28-macneutron-metalfx-upscaler-design.md`, `2026-09-28-macneutron-steam-bridge-design.md` and
`2026-09-28-macneutron-dxmt-fork-design.md` get "Superseded in part by `2026-10-04-macneutron-arm64-release-design.md`
(the Rosetta runtime, GPTK, DXVK and the x86_64 DXMT build were removed in 0.1.0)". The Rosetta-era
`docs/testing/acceptance-*.md` records get "Historical: the Rosetta runtime was removed in 0.1.0; reproduce with the
frozen reference (`tools/freeze-rosetta-reference.sh`)".

## 14. Amendments made while planning (2026-10-04)

The interface digests written for the plan (`docs/research/2026-10-04-arm64-release/digest-*.md`) showed where this
spec's text didn't match the code. Where §§1-13 say otherwise, this section wins.

- **§3.1:** the Rosetta-era removal list also has `gptk.staging` and, when R0b passes, the old `proton` stub. R0b's
  throwaway tools are named `r0b-probe` and `r0b-probe-native`: `MappingPlanner.isOurs` treats any name starting with
  `macneutron` as ours. The runtime tool's CLI copy is `bin/macneutron`; `macneutron-native/bin/macneutron` is copied
  from it by `SteamPlayMode`. The `passthrough` verb sets its preference with `posix_spawnattr_setarchpref_np` (type
  and subtype, so arm64e comes before arm64).
- **§3.3:** a target that is missing or unreadable is "not PE" and isn't checked. The macOS 27 / Apple Silicon check
  stays (it carries §10's text and is tested), but an arm64-only binary built for macOS 27 can't even load elsewhere.
  A failed FEX registration fails the preparation (the stamp stays `wine.app preparing`; the next launch retries).
- **§3.7:** `MACNEUTRON_PRESENT=1` goes only to the game's processes (`run`, `waitforexitandrun`), as the presenter
  does today.
- **§3.9:** the install is `RuntimeInstaller.install(wineApp:layout:launcherBinary:steamExe:force:) ->
  RuntimeInstallOutcome` (`installed`, `unchanged`, `deferred(path)`), and the CLI verb is
  `macneutron install --tool-dir <dir> --wine-app <path> [--steam-exe <path>] [--force]`; it exits 0 when installed or
  unchanged, 3 when deferred (printing `deferred: <path> is running`), 1 on an error. `--steam-exe` is for tool folders
  assembled from a dev build (`.build/release/` has no `steam.exe` beside the CLI). The app's poll also reinstalls when
  `runtime-damaged` appears.
- **§3.9, §10:** step 1's scan is repeated right before the swap (after `codesign --verify`), and a hit defers the
  install as step 1 does. After a FAILED install (an error, not a deferral) the app's poll doesn't retry, even when
  `runtime-damaged` appears: it waits for Repair or the next start (re-copying a failing install every 3 s would thrash).
- **§3.11:** setup's requirements step checks Steam only: macOS refuses to open the app below macOS 27 or on Intel
  (its minimum is 27.0 and it is arm64 only). The host build (`swift build -c release`) is already thin arm64 on Apple
  Silicon; `release.sh` asserts `lipo -archs` is `arm64`. AVX is a per-game toggle, not a column.
- **§5.2:** release mode also deletes the `winecpp` and `wineg++` links (to `winegcc`). Stripping goes between the
  layout and the signing; every assertion runs after signing, as today, except the build-path check (no shipped file
  names the repository, the build folder or `$HOME/`; release mode, and `release.sh` on the assembled app), which runs
  between stripping and signing so a failure stops before anything is signed.
- **§5.3:** `winemetal.so` has no initialisation today; patch 0002 adds a constructor.
- **§6.3 step 1:** `release.sh` fetches `origin` first; it checks each tree with `lib.sh`'s `build_mode` (naming any
  tree not `applied`) and then requires `make wine-arm64` to say `up to date`; `dxmt/published.sh` runs on
  `build/wine-arm64-src/dxmt` with `DXMT_COMMIT`.
- **§6.3 step 2:** `bundle.sh --release` writes the bundle's `licenses/SOURCE` itself (a `lib.sh` function shared with
  `build.sh`) with `MACNEUTRON_COMMIT` = HEAD: the staged dev `SOURCE` lags HEAD after commits that change no build
  input.
- **§7.1:** the MacNeutron entry in `wine-arm64/licenses/README` names the presenter alone (MIT); the patch files keep
  the licence of the tree they patch, as §1's decision says (Wine and DXMT: LGPL-2.1-or-later; FEX: MIT; lsteamclient:
  Valve's terms), and the entry says so. `licences_test.sh` still requires it.
- **§7.2:** lsteamclient's blob-less clone can't be `git archive`d offline; the archive tars its clean sparse worktree
  (exactly the files the build used) and records the commit. Each patched tree's tar names its applied commit
  (`<tree>.applied`), not the pin; the archive carries `SOURCES.txt` (tree, pin, applied commit, patch count). R5 checks
  `git rev-parse <applied>~<patch count>` = `*_COMMIT`, recomputes each `*_SERIES` from the archived pins and patches,
  and checks the tarballs' SHA-256 and the submodules' commits.
- **§7.3:** the README names the new `install` verb without naming `import-gptk` (a refusal string).
- **§8.2:** only G4 uses a Rosetta baseline (M1 and M2 run on `wine.app`). In `dxmt/check.sh`, reference runs get their
  own compat folders (`compat/ref`, `compat/ref-A`…`-E`): the two launchers would otherwise wreck each other's prefixes.
  `dxmt/tests/run.sh` is removed. `dxmt/tests/shaders/compile.sh` runs DXC under the frozen reference's Wine and fetches
  DXC itself (it was `dxmt/build.sh`'s); `dxmt/build.sh` and its `build_test.sh` rows go with `make dxmt`.
- **§9:** L5's `d3d11probe.exe` creates a device and a swap chain on `wined3d` (it draws nothing). L3's "second
  steam.exe" row stays a direct run (a second `waitforexitandrun` waits in `wineserver -w`). L6's deferral is exit code 3.
- **§10:** row 1 becomes "macOS won't open the app (minimum macOS 27, Apple Silicon only); a launch exits non-zero
  with the text" (the launcher row stays for tests and stray binaries). The "entitlement refused" row is visible only in
  the game log with `MACNEUTRON_LOG=1` (Wine's message); there is no notification. Failure messages also go into the
  game log when one is being written.
- **§13:** every spec dated before 2026-10-04 that describes the Rosetta runtime, GPTK or `install-dxmt` gets the status
  line (not only the six named), and the native spec's lines on the Rosetta runtime staying until sub-project 5 and on
  per-game switching are marked superseded too. The three `acceptance-arm64-*` records get a one-line note that their
  Rosetta baselines now come from the frozen reference.
