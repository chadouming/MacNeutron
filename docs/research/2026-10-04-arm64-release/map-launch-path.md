# Sub-project 5 map: the LAUNCH PATH (Rosetta runtime today, seams for wine.app)

Read-only map, 2026-10-04, repo at `95f8883`. Paths are relative to `/Users/chad/Documents/MacProton` unless absolute.
"(I)" marks an inference; everything else is read from the cited line or observed with `ls`/`file`/`cat`.
Complements `docs/research/2026-10-02-native-arm64/stack-map.md:70-120`, which classified many of the same lines
(DIES / NEUTRAL / ARM64 TWIN) before sub-projects 2-3 landed; this map updates it with what those sub-projects built.

---

## 0. One-paragraph summary

Steam (forced into "Linux mode" by `steam_dev.cfg`) runs `<tool>/proton <verb> <target> [args]`; `proton` is a
`/bin/sh` stub that `exec`s `<tool>/bin/macneutron launch "$@"`. The Swift launcher derives ONE `ToolLayout` from its
own executable path, parses the Proton verb, reads `STEAM_COMPAT_DATA_PATH`/`SteamAppId`, merges per-game settings
under Steam's environment, runs a Rosetta+runtime preflight, picks a graphics backend, builds Wine's environment,
prepares `compatdata/<appid>/pfx` under a file lock (wineboot, backend DLLs, Steam bridge files), and runs
`Libraries/Wine/bin/wine` (x86_64, under Rosetta) either directly or through `steam.exe`, waiting on `wineserver -w`.
Every runtime-specific path flows through `ToolLayout`; the arm64 runtime (`wine.app`) differs in almost every one of
those paths, plus Rosetta preflight, presenter injection, FEX registration, DXMT source folder, and version identity.

---

## 1. How Steam invokes us

### 1.1 The gate (Linux mode)
- macOS Steam's `CCompatManager` only applies compat tools when the platform is "linux"; the only non-patching lever
  is `steam_dev.cfg` containing `@sSteamCmdForcePlatformType linux`, read only from
  `~/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_dev.cfg`
  (`~/.claude/projects/-Users-chad-Documents-MacProton/memory/macos-steam-compat-gate.md`, "Gate" and "Only
  non-patching lever" bullets). Cost: unmapped Mac-only games get unmounted (same note, "Cost of Linux mode").
- Written by `SteamPlayMode.devConfig = "@sSteamCmdForcePlatformType linux\n"` (`Sources/MacNeutronCore/SteamPlayMode.swift:18`),
  to `SteamLocation.steamDevConfig` = `<Steam>/Steam.AppBundle/Steam/Contents/MacOS/steam_dev.cfg`
  (`SteamLocation.swift:23,25`), written LAST in `enable` (`SteamPlayMode.swift:105`), removed FIRST in
  `disable`/`rollBack` (`SteamPlayMode.swift:124,237`).
- `enable` refuses without Rosetta: `guard rosettaAvailable() else { throw SteamPlayError.rosettaMissing }`
  (`SteamPlayMode.swift:44,93`; message `SteamLocation.swift:98`). This is a Rosetta hard-code on the Steam Play
  path, not only on launch.
- Verification reads `<Steam>/logs/compat_log.txt` (`SteamLocation.swift:27`) for `Registering tool macneutron,`,
  `Registering tool macneutron-native,` and `Recording non-user mapping` (`SteamPlayMode.swift:267-278`).

### 1.2 Tool registration (what Steam sees)
- Tool folders live in `~/Library/Application Support/MacNeutron/compatibilitytools.d/` (`SteamLocation.swift:5-9`,
  `SteamPlayMode.swift:49`), symlinked into `<Steam bundle MacOS>/compatibilitytools.d/<name>`
  (`SteamLocation.swift:24`, `SteamPlayMode.swift:57,222-230`). Observed: `macneutron` and `macneutron-native`.
- `macneutron` tool files, written by `RuntimeInstaller.writeToolFiles` (`RuntimeInstaller.swift:110-133`):
  - `compatibilitytool.vdf` (`RuntimeInstaller.swift:34-49`): name `macneutron`, `display_name "MacNeutron"`,
    `from_oslist "windows"`, `to_oslist "linux"`, `install_path "."`.
  - `toolmanifest.vdf` (`RuntimeInstaller.swift:50-57`): `"version" "2"`, `"commandline" "/proton %verb%"`.
  - `proton` (`RuntimeInstaller.swift:58-62`), mode 0755: `exec "$(dirname "$0")/bin/macneutron" launch "$@"`.
  - Installed copies match byte for byte (observed `cat` of the installed folder).
- `macneutron-native` (Mac games passthrough): `SteamPlayMode.installNativeTool` (`SteamPlayMode.swift:198-220`),
  `from_oslist "macos"` → `to_oslist "linux"`, `commandline "/passthrough.sh %verb%"`; the script `exec`s
  `/usr/bin/arch -arm64e -arm64 -x86_64 <target>` because "Steam starts tools preferring x86_64, which carries through
  exec" (`SteamPlayMode.swift:20-35`).
- Mappings: `MappingPlanner.plan` maps app `"0"` (global, priority 75) and every Windows app to `macneutron`
  (priority 250), Mac apps to `macneutron-native` unless `runAs == .windows` (`MappingPlanner.swift:21-43`).
  `isOurs(tool) = tool.hasPrefix("macneutron")` (`MappingPlanner.swift:82`) — any future `macneutron-*` tool name
  would already count as ours. `filesIntact` checks only the two tool names (`SteamPlayMode.swift:63-67`), and
  `verify` checks registration of exactly those two (`SteamPlayMode.swift:271`).

### 1.3 argv and env Steam passes
- Verbs: `run`, `waitforexitandrun`, `runinprefix`, `getcompatpath`, `getnativepath` (`Verb.swift:2-8`).
  `LaunchRequest.parse(argv)`: `argv[0]` verb, `argv[1]` target, rest passed untouched (`Verb.swift:32-37`).
- In Linux mode Steam runs `<tool> waitforexitandrun <game.exe>` with `STEAM_COMPAT_DATA_PATH`,
  `STEAM_COMPAT_INSTALL_PATH`, `STEAM_COMPAT_CLIENT_INSTALL_PATH` (= `.../Steam.AppBundle/Steam/Contents/MacOS`) and
  `SteamAppId` (memory note, "full Proton parity" bullet). The launcher reads only `STEAM_COMPAT_DATA_PATH`
  (required) and `SteamAppId` (default `"0"`) (`CompatContext.swift:18-24`), plus
  `STEAM_COMPAT_CLIENT_INSTALL_PATH` for the bridge (`Launcher.swift:171`). `STEAM_COMPAT_INSTALL_PATH` is unused.
- Comment in `Launcher.swift:81-83`: Steam first runs `run iscriptevaluator.exe` (install scripts) then
  `waitforexitandrun`; both share the prefix lock. Any per-game runtime choice must therefore be the same for every
  verb of an app ID (it is, if keyed on `SteamAppId`).

### 1.4 Process architecture
- `main.swift:4-7`: `executable = Bundle.main.executableURL ?? argv[0]`; `exit(await CommandLineTool.run(...))`.
- Installed `bin/macneutron` is `Mach-O 64-bit executable arm64` only (observed `file`); built by
  `swift build -c release` (`Makefile:12-13`), Package min macOS 26.0 (`Package.swift:6`). So Steam's x86_64
  preference ends at the `/bin/sh` stub; the launcher and its children start native. x86_64 Wine runs under Rosetta
  because its binary is x86_64-only (observed `file`); wine.app's loader and wineserver are arm64-only (observed
  `file build/wine-arm64/wine.app/Contents/MacOS/wine`, `.../Resources/bin/wineserver`). (I) `Process` spawns with
  the default native preference, so nothing needs `arch` for wine.app.

---

## 2. CLI entry and layout resolution

- `CommandLineTool.run` (`CommandLineTool.swift:13-60`). `launch` →
  `Launcher(layout: ToolLayout(executable: executable))`, `installTerminationHandlers`, `launcher.launch(rest, environment:)`
  (`CommandLineTool.swift:17-20`). Other subcommands: `import-gptk`, `install-runtime`, `install-dxmt`, each with
  `--tool-dir` (default `ToolLayout.defaultRoot`) (`CommandLineTool.swift:21-56,70-72`). There is no subcommand
  for wine.app.
- `ToolLayout(executable:)` = executable, symlinks resolved, two levels up (`<root>/bin/macneutron` → `<root>`)
  (`ToolLayout.swift:10-12`). `defaultRoot` = `~/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron`
  (`ToolLayout.swift:14-18`).
- `MACNEUTRON_TOOL` is NOT read by any Swift code (no hit in `Sources`); scripts implement it by cloning the tool
  folder and copying a launcher into its `bin/` (`wine-arm64/check.sh:26,436-438`, `dxmt/check.sh:15,38`).
- Signals: SIGTERM/SIGINT ignored then handled on a dispatch source: `launcher.terminate(environment:)` then
  `exit(128+sig)` (`CommandLineTool.swift:78-89`).

### 2.1 Every `ToolLayout` path (all Rosetta-runtime shaped)

| Property | Path under `<root>` | Line |
|---|---|---|
| `libraries` | `Libraries/` (the winecx-gptk tarball's `Libraries/{Wine,DXMT,DXVK}`) | `ToolLayout.swift:20-21` |
| `wineLib` | `Libraries/Wine/lib` | `:22` |
| `wine` | `Libraries/Wine/bin/wine` | `:23` |
| `wineserver` | `Libraries/Wine/bin/wineserver` | `:24` |
| `dxmt` / `dxvk` | `Libraries/DXMT`, `Libraries/DXVK` | `:25-26` |
| `gptkStore` / `gptkManifest` | `gptk/`, `gptk.json` | `:28-29` |
| `runtimeVersionFile` | `runtime-version` (installed: `runtime-v4.7.3`) | `:30`, `:60-63` |
| `launcherBinary` | `bin/macneutron` | `:31` |
| `steamHelper` | `bin/steam.exe` (x86-64 PE, observed) | `:33` |
| `lsteamclientUnix` | `Libraries/Wine/lib/wine/x86_64-unix/lsteamclient.so` | `:35` |
| `lsteamclient64` | `.../wine/x86_64-windows/lsteamclient.dll` | `:36` |
| `lsteamclient32` | `.../wine/i386-windows/lsteamclient.dll` | `:37` |
| `steamBridgeInstalled` | all of `steamHelper`, `lsteamclientUnix`, `lsteamclient64` exist | `:40-43` |
| `presenterLibrary` | `lib/libmacneutron-present.dylib` (universal x86_64+arm64, observed) | `:46-47` |
| `dxmtVersionFile` / `dxmtVersion` | `dxmt-version` (installed: bare commit `1fba8d25...c5`) | `:50-53` |
| `dxmtD3D12` / `dxmtHasD3D12` | `Libraries/DXMT/x64/d3d12.dll` | `:55-56` |
| `dxmtReplay` | `Libraries/DXMT/x64/dxmt-replay.exe` | `:58` |
| `gptkVersion` / `gptkImported` | `gptk.json` `"version"` | `:66-73` |

wine.app equivalents (observed in `build/wine-arm64/wine.app`, design in native arm64 spec §4,
`docs/superpowers/specs/2026-10-02-macneutron-native-arm64-design.md:191-208`):

| Role | wine.app path |
|---|---|
| loader (only entitled binary) | `Contents/MacOS/wine` (+ `Contents/MacOS/ntdll.so` symlink) |
| wineserver | `Contents/Resources/bin/wineserver` |
| unix libs | `Contents/Resources/lib/wine/aarch64-unix/` (`winemetal.so` 22 MB, `lsteamclient.so` 4.4 MB) |
| PE libs | `Contents/Resources/lib/wine/aarch64-windows/` (`libarm64ecfex.dll`, `winemetal.dll`, `lsteamclient.dll` 57 MB, ARM64X) |
| DXMT front ends | `Contents/Resources/DXMT/aarch64-windows/{d3d11,d3d10core,dxgi,d3d12}.dll, dxmt-replay.exe` |
| DXMT version | `Contents/Resources/DXMT/version` = `1fba8d25...c5+63a4969e01ba` (`<commit>+<series12>`, arm64 DXMT spec §6, `docs/superpowers/specs/2026-10-03-macneutron-arm64-dxmt-design.md:120`) |
| licences | `Contents/Resources/licenses/` |
| Runtime version | **none in the bundle**: `wine-arm64/Info.plist:1-18` has no `CFBundleVersion`/`CFBundleShortVersionString`; the build stamp `build/wine-arm64/version` (a hash) is outside the bundle (native spec §5.4 step 8, `...native-arm64-design.md:289-296`) |
| Mono / Gecko | **absent**: `Resources/share/wine` = `fonts nls wine.inf winmd`; the Rosetta runtime's `Libraries/Wine/share/wine` has `gecko` and `mono` too (observed `ls`) |
| No i386 | no `i386-windows`, no `syswow64` DXMT, no `steamclient.dll` (32-bit games are row 8) |

---

## 3. `Launcher.launch`, step by step (`Launcher.swift:36-124`)

1. `LaunchRequest.parse(argv)` and `CompatContext(environment:)`; failure → `fail(..., notify: false)`, exit 1
   (`:38-45`).
2. Per-game settings: `settings.load(appID).environment.merging(environment) { _, launchOption in launchOption }` —
   settings underneath, Steam/launch-option vars win; unreadable file logged and ignored (`:46-51`).
   Store: `~/Library/Application Support/MacNeutron/games/<appid>.json` (`GameSettings.swift:35-47`,
   `SteamLocation.swift:10`).
3. `preflight.check(layout)` (`:52-56`) → `Preflight.check` (`Preflight.swift:29-36`): Rosetta present
   (`/Library/Apple/usr/libexec/oah/libRosettaRuntime`, `:20,23-25`), `layout.wine` and `layout.wineserver`
   executable, `layout.runtimeVersion != nil`. Failure → notify + exit 1. **Runs before any backend/runtime choice,
   on the single layout.**
4. `GraphicsBackend.select(requested: env["MACNEUTRON_GRAPHICS"], gptkImported: layout.gptkImported)` (`:58-59`).
5. `logging = env["MACNEUTRON_LOG"] == "1"` (`:60`).
6. `LaunchEnvironment.build(base:context:backend:layout:logging:)` (`:61-62`, §4 below).
7. `steamBridge = usesSteamBridge(verb, env)`: only `run`/`waitforexitandrun`, not when
   `MACNEUTRON_NO_STEAM_BRIDGE=1`, only when `layout.steamBridgeInstalled` (`:63,144-155`); if on,
   `addSteamClient(to:)` (`:64,170-184`).
8. `run`/`waitforexitandrun` → `addPresenter(to:)` (`:65,159-167`).
9. Game log: `log.gameLog(appID:)` when logging; header with every env var, `MACNEUTRON_STEAM_ACCOUNT` redacted
   (`:66-67,186-199`).
10. `PrefixManager(context:layout:runtimeVersion: layout.runtimeVersion ?? "unknown", runner:)` (`:68-69`).
11. Verb switch (`:73-115`):
    - `runinprefix`: run game directly, no prepare, never through steam.exe (`:74-75`).
    - `run`: `prepare(backend:environment:steamBridge:)`; if no bridge `removeSteamBridge()`; run (`:76-79`).
    - `waitforexitandrun`: prepare (+remove bridge), `wineserver -w`, optional shader replay, run game,
      `wineserver -w`, `writeStampIfMissing` (`:80-110`). Stop during replay → status `128+SIGTERM`, nothing started
      (`:101-103`).
    - `getcompatpath`/`getnativepath`: `prepare(backend:environment:)` (no bridge), then
      `wine winepath.exe -w|-u <target>` (`:111-114`).
12. Launcher log line: `verb= appid= backend= runtime=<layout.runtimeVersion> gptk=<layout.gptkVersion> exit=` plus
    `note=` (`:116-119`).
13. `runGame` (`:135-140`): `wine <target> args` or, with the bridge,
    `wine 'C:\Program Files (x86)\Steam\steam.exe' <Z:\…target> args`; output → game log or inherited.
14. `terminate(environment:)` (`:127-133`): sets the stop flag, then `WINEPREFIX=<context.prefix>` and
    `layout.wineserver -k`. **It receives Steam's raw environment** (`CommandLineTool.swift:19,83`), not the
    settings-merged one, so it cannot see a per-game choice stored in `games/<appid>.json` unless it re-loads settings.

`ProcessRunner.run(executable, arguments, environment:, output:)` (`ProcessRunner.swift:4-8`): `Process` with an
explicit full environment; `output` appends stdout+stderr to a file (`:20-30`); returns `128+sig` on signal
(`:34-35`). Tests swap in `FakeRunner`, which records `executable.lastPathComponent` as `tool`
(`Tests/MacNeutronCoreTests/Support.swift:40-61`) — for wine.app the loader's last component is still `wine` and the
server's `wineserver`, so existing call-shape assertions (`LauncherTests.swift:47-53`) would carry over.

---

## 4. Every environment variable

### Read from Steam
| Var | Use | Line |
|---|---|---|
| `STEAM_COMPAT_DATA_PATH` | required; compatdata dir | `CompatContext.swift:19-22` |
| `SteamAppId` | app ID, default `"0"` | `CompatContext.swift:23` |
| `STEAM_COMPAT_CLIENT_INSTALL_PATH` | kept if it holds `steamclient.dylib`, else `<Steam>/Steam.AppBundle/Steam/Contents/MacOS` (no trailing `/`) | `SteamBridge.swift:29-34`, `Launcher.swift:171-177` |

### MacNeutron switches (from launch options or `GameSettings.environment`, `GameSettings.swift:23-31`)
| Var | Effect | Line | GameSettings field |
|---|---|---|---|
| `MACNEUTRON_GRAPHICS` | backend request | `Launcher.swift:58` | `graphics` |
| `MACNEUTRON_LOG=1` | game log + `WINEDEBUG` channels | `Launcher.swift:60`, `LaunchEnvironment.swift:12` | `log == true` |
| `MACNEUTRON_NO_AVX=1` | no `ROSETTA_ADVERTISE_AVX` | `LaunchEnvironment.swift:14` | `avx == false` |
| `MACNEUTRON_NO_MSYNC=1` | no `WINEMSYNC=1` | `LaunchEnvironment.swift:17` | `msync == false` |
| `MACNEUTRON_NO_METALFX=1` | no presenter | `Launcher.swift:160` | `metalFX == false` |
| `MACNEUTRON_NO_STEAM_BRIDGE=1` | start game directly | `Launcher.swift:146` | — (launch option only) |
| `MACNEUTRON_PRECACHE=0` | no record/replay | `ShaderPrecache.swift:20` | — |
| `MACNEUTRON_STEAM_ACCOUNT` | set from `loginusers.vdf` unless given; read by `steam.exe` (`bridge/steam.c:71`) | `Launcher.swift:178-183` | — |
`runAs` is not an env var; it feeds `MappingPlanner` only (`GameSettings.swift:22`).

### Set for Wine (`LaunchEnvironment.build`, `LaunchEnvironment.swift:6-24`; user values win)
| Var | Value | Line | arm64 note |
|---|---|---|---|
| `WINEPREFIX` | `<STEAM_COMPAT_DATA_PATH>/pfx` (always overwritten) | `:9`, `CompatContext.swift:26` | needs the arm64 prefix if prefixes are separate |
| `WINEDLLOVERRIDES` | backend's overrides merged by DLL name, user wins | `:10,28-44` | DXMT value is the arm64 one too (arm64 DXMT spec §6) |
| `WINEDEBUG` | `+err,+warn,+loaddll,+steamclient` if logging else `-all`, only if unset | `:11-13` | same channels exist (I) |
| `ROSETTA_ADVERTISE_AVX` | `1` unless `MACNEUTRON_NO_AVX=1` or set | `:14-16` | Rosetta-only; FEX equivalent unnamed (stack-map:74) |
| `WINEMSYNC` | `1` unless `MACNEUTRON_NO_MSYNC=1` or set | `:17-19` | row 5 wants `WINEMSYNC=1` for every arm64 run, `WINEMSYNC=0` as per-game off switch: already satisfied by this code path (I) |
| `DXMT_PIPELINE_RECORD` | `<compatdata>/dxmt-pipelines` when precache enabled | `:20-22` | |
| `STEAM_COMPAT_CLIENT_INSTALL_PATH` | see above (bridge only) | `Launcher.swift:173` | arm64 `lsteamclient.so` uses Steam's universal `steamclient.dylib` from the same folder (ship-base §7) |
| `MACNEUTRON_STEAM_ACCOUNT` | account ID (bridge only) | `Launcher.swift:180` | unchanged |
| `DYLD_INSERT_LIBRARIES` | user's value `:` presenter path (`run`/`waitforexitandrun` only) | `Launcher.swift:165-166` | **dead on wine.app**: signed `--options runtime` (`wine-arm64/bundle.sh:116,118`) and `wine-arm64/wine.entitlements` has no `com.apple.security.cs.allow-dyld-environment-variables` (only application-identifier, team-identifier, cross-architecture-support, allow-jit, allow-unsigned-executable-memory, disable-library-validation) |

Not set by the launcher anywhere: `MTL_*`, `WINEESYNC`, `DXMT_*` other than `DXMT_PIPELINE_RECORD`, any `FEX_*`
(grep of `Sources` for env keys). The presenter itself reads `MACNEUTRON_PRESENT_SCALE`, `MACNEUTRON_PRESENT_DUMP`
(`presenter/present.m:292-293`). Steam's whole environment is passed through to Wine (`LaunchEnvironment.swift:8`),
so any `FEX_*` a user puts in launch options would reach FEX (I; `wine-arm64/check.sh:139` strips them for its own
measurement runs).

msync agreement: client and wineserver must agree on `WINEMSYNC`, else the client exits with an `ERR` line hidden by
`WINEDEBUG=-all` (ship-base spec §11 table, `...ship-base-wine-design.md:229`; native spec §11). Because the launcher
computes `WINEMSYNC` per launch, toggling msync while that prefix's server is still alive would kill the new client
(I); `wineserver -k` is the documented switch step. Applies to the Rosetta runtime's msync too.

---

## 5. Prefix selection and preparation

- Prefix = `<STEAM_COMPAT_DATA_PATH>/pfx`; version stamp `<data>/version`; lock `<data>/macneutron.lock`
  (`CompatContext.swift:26-28`). The pipeline recordings live beside them in `<data>/dxmt-pipelines`
  (`ShaderPrecache.swift:16`).
- `PrefixManager.needsPreparation`: prefix missing, or `version` file ≠ `runtimeVersion` (`PrefixManager.swift:35-39`).
  `runtimeVersion` = `layout.runtimeVersion ?? "unknown"` (`Launcher.swift:68`).
- `prepare(backend:environment:steamBridge:)` (`PrefixManager.swift:44-59`), under `flock` on the lock file
  (`:104-111`): if needed `wine wineboot -u` with the full launch env (`:48`), fail on non-zero; `wine reg add
  HKCU\Software\Wine\WineDbg /v ShowCrashDialog /t REG_DWORD /d 0 /f` (best effort, `:52-53`); write `version`
  (`:54`). Then every time: `deployDLLs(for: backend)` (`:56,61-71`, missing source = hard error) and, if asked,
  `deploySteamBridge()` (`:57,74-80`).
- `removeSteamBridge()` deletes `steam.exe`, `steamclient64.dll`, `steamclient.dll` from the prefix Steam folder
  under the lock (`:85-91`).
- Two runtimes on one `compatdata/<appid>` would collide three ways: `pfx` (x86_64 prefix upgraded in place by aarch64
  `wineboot -u` is untested, stack-map:89), the single `version` file (each runtime sees the other's stamp → wineboot
  every switch), and `dxmt-pipelines` (stamp mismatch → replay every switch, §8).
- arm64 prefix creation needs more than today's `prepare`:
  - FEX registration: `reg add 'HKLM\Software\Microsoft\Wow64\amd64' /ve /d libarm64ecfex.dll /f`
    (`wine-arm64/check.sh:206-212`); native spec §6.3 says "Sub-project 5 makes this part of prefix creation"
    (`...native-arm64-design.md:360`); `wine.inf` writes `xtajit64.dll` there with don't-overwrite, so the value
    survives `wineboot -u` (same line).
  - Boot overrides: `check.sh` boots with `WINEDLLOVERRIDES="mscoree,mshtml="` (`wine-arm64/check.sh:156`); the
    launcher's `wineboot -u` gets only the backend overrides (`PrefixManager.swift:48`). wine.app ships no Mono/Gecko
    (§2.1). What arm64 `wineboot -u` does without them (addon-installer prompt? silent skip?) is unverified.
  - `check.sh` uses `wineboot -i`, the launcher `wineboot -u` (`PrefixManager.swift:48`); patch 8 re-execs the first
    process at 4K whatever the entry point (native spec §5.2 row 8, `...native-arm64-design.md:237`), so the launcher
    can invoke `Contents/MacOS/wine` directly.

---

## 6. Graphics backend

- `GraphicsBackend` = `d3dmetal | dxmt | dxvk` (`GraphicsBackend.swift:4-5`). `select(requested:gptkImported:)`
  (`:9-26`): empty → `.dxmt`; unknown → `.dxmt` + note; `d3dmetal` without GPTK → `.dxmt` + note; `dxvk` with GPTK →
  `.d3dmetal` + note.
- `dllOverrides(layout:)` (`:32-40`): `d3dmetal` `dxgi,d3d9,d3d10,d3d10core,d3d11,d3d12=b`; `dxmt`
  `dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b` when `layout.dxmtHasD3D12`, else d3d12 builtin; `dxvk`
  `d3d10core,d3d11=n,b;dxgi,d3d9,d3d10,d3d12=b`.
- `prefixDLLs(layout:)` (`:44-59`): from `<dir>/x64/<dll>` → `drive_c/windows/system32/<dll>` and `<dir>/x32/<dll>` →
  `drive_c/windows/syswow64/<dll>`; dxmt adds `x64/d3d12.dll` → system32 only.
- Installation into the tool folder: the runtime tarball brings DXMT 0.80 and DXVK; `DXMTInstaller.install` overlays
  our fork: Mac half into `Wine/lib/wine/x86_64-unix/`, `winemetal.dll` into Wine's `x86_64-windows`/`i386-windows`,
  front ends into `Libraries/DXMT/{x64,x32}`, then `dxmt-version` (`DXMTInstaller.swift:56-86`). Triggered by
  `RuntimeInstaller.install` (`RuntimeInstaller.swift:104`) and at every app start (`AppModel.swift:74-77`) via
  `installBundled` when the app's bundled build version differs (`DXMTInstaller.swift:90-94`; bundle sources
  `Contents/Resources/DXMT` + `Contents/Frameworks/DXMT`, `DXMTInstaller.swift:37-43`, `Makefile:99-103`).
- arm64: DXMT ships inside wine.app, already signed; no installer step. Prefix copy is
  `Resources/DXMT/aarch64-windows/*` → `system32` with the DXMT overrides above, no syswow64 (arm64 DXMT spec §6,
  `...arm64-dxmt-design.md:124`; `wine-arm64/check.sh:467-468`). Note `aarch64-windows/` also contains
  `dxmt-replay.exe`, which `check.sh` copies into system32 too (`check.sh:468`, `cp "$d/aarch64-windows/"*`); the
  Rosetta `prefixDLLs` never copies `dxmt-replay.exe`. D3DMetal (GPTK overlay onto x86_64 Wine builtins,
  `GPTKImporter.swift:31-34,98`) and DXVK (no MoltenVK in wine.app, native spec §5.4) have no arm64 form; only
  `dxmt` is meaningful there (stack-map:77-82).
- UI: `GamesView.swift:35-44` offers Default (DXMT) / D3DMetal / DXMT / DXVK; toggles Log, AVX, msync, MetalFX
  (`GamesView.swift:54-57`). No runtime picker exists.

---

## 7. Steam bridge (Rosetta today; `docs/superpowers/specs/2026-09-28-macneutron-steam-bridge-design.md`)

- Data flow (bridge spec §3, `...steam-bridge-design.md:48-75`): launcher copies `bin/steam.exe` →
  `C:\Program Files (x86)\Steam\steam.exe`, runtime x86_64 `lsteamclient.dll` → `…\Steam\steamclient64.dll`, i386 →
  `…\Steam\steamclient.dll` when present (`SteamBridge.swift:15-25`); sets `STEAM_COMPAT_CLIENT_INSTALL_PATH` and
  `MACNEUTRON_STEAM_ACCOUNT`; runs `wine steam.exe Z:\…\game.exe args` (`Launcher.swift:138`,
  `SteamBridge.swift:7,10-12`). `steam.exe` (`bridge/steam.c`) writes `HKCU\Software\Valve\Steam`
  (`SteamPath`, `SteamExe`, `ActiveProcess\{pid,SteamClientDll64,SteamClientDll,ActiveUser}`) and
  `HKLM\Software\Wow6432Node\Valve\Steam\InstallPath`, starts the game in a job, waits for the job, clears `pid`
  (bridge spec §4.2, `:83-102`). `lsteamclient.so` dlopens `steamclient.dylib` from the client folder.
- Account: `SteamLocation.activeAccountID()` from `config/loginusers.vdf`, `MostRecent == 1` else max `Timestamp`,
  low 32 bits (`SteamLocation.swift:62-70`); redacted in game-log headers (`Launcher.swift:188-191`).
- `steam.exe` shipping: `make app` copies only the x64 `build/bridge/steam.exe` to `Contents/Resources/steam.exe`
  (`Makefile:93`); `writeToolFiles` installs one `steam.exe` into `bin/` from next to the launcher or
  `../Resources/steam.exe` (`RuntimeInstaller.swift:121-126`).
- arm64 file set (what the launcher must reproduce), shown by `bridge/probe.sh:42-47,71-75` and
  `bridge/check.sh:10-15,27-29`: `build/bridge/arm64/steam.exe` (aarch64, built by `Makefile:30`) → prefix
  `…\Steam\steam.exe`; `wine.app/Contents/Resources/lib/wine/aarch64-windows/lsteamclient.dll` (ARM64X, 57 MB) →
  `…\Steam\steamclient64.dll`; no `steamclient.dll`. Both `steam.exe` builds are needed: "neither runs on the other
  runtime" (ship-base §7, `...ship-base-wine-design.md:168`). `steamprobe.exe` stays x64 (dev only).
- `tests/helper.exe`: row 5 lists it among files copied "into prefixes" (`...native-arm64-design.md:65`), but
  `bridge/check.sh:28-30` copies it into a fake game folder (`$WORK/game dir/hélper.exe`), never a prefix: it is the
  bridge check's stand-in game, not a runtime file.
- lsteamclient licence: Steamworks SDK licence; local builds bundle it with `licenses/lsteamclient/`; release
  inclusion undecided and assigned to sub-project 5 ("until then ... MacNeutron doesn't redistribute it")
  (ship-base §1 decisions, `...ship-base-wine-design.md:40`). If releases omit it, `steamBridgeInstalled`-style logic
  falls back to a direct start with `note: Steam bridge not installed` (`Launcher.swift:150-152`).
- Also: the Rosetta bridge spec dropped building lsteamclient because the pinned runtime ships it (amendment,
  `...steam-bridge-design.md:10-16`); on arm64 we build it ourselves.

---

## 8. Shader pre-caching (`ShaderPrecache.swift`)

- Enabled iff `backend == .dxmt && layout.dxmtHasD3D12 && MACNEUTRON_PRECACHE != "0"` (`:19-21`). Recording:
  `DXMT_PIPELINE_RECORD=<compatdata>/dxmt-pipelines` (`LaunchEnvironment.swift:20-22`).
- Stamp `dxmt-pipelines/replayed` = `"<layout.dxmtVersion ?? "none"> <kern.osversion>"` (`:11-14,23,101-107`);
  `needsReplay` when a stamp exists, differs, and recordings (`*.pipelines`) exist (`:37-40`).
- Replay (waitforexitandrun only, `Launcher.swift:88-100`): for each recording,
  `wine <layout.dxmtReplay unix path> Z:<recording>` with `DXMT_PIPELINE_RECORD` removed, output to
  `dxmt-pipelines/replay.log`, progress notifications per quarter (`:54-88`).
- arm64 seams: `dxmtHasD3D12`/`dxmtReplay` point at `Libraries/DXMT/x64/…` (`ToolLayout.swift:55,58`);
  `dxmtVersion` reads the tool folder's `dxmt-version` (bare commit) while wine.app's is `Resources/DXMT/version`
  (`<commit>+<series12>`), so the stamp strings differ per runtime → a shared `dxmt-pipelines` replays on every
  runtime switch, and recordings made by one DXMT build would be replayed by the other (I: compatible formats not
  verified). `dxmt/check.sh` section 10 (launcher records + stamps + replays) is skipped in arm64 mode "(sub-project 5)"
  (`dxmt/check.sh:792-812`), as is the `MACNEUTRON_LOG` check (`dxmt/check.sh:481-487`).

---

## 9. Logging (`LauncherLog.swift`)

- Directory `~/Library/Logs/MacNeutron` (`:10-13`); `launcher.log` one timestamped line per event, rotated to
  `launcher.log.1` past 1 MiB, under `launcher.log.lock`, single `O_APPEND` write (`:5,15,27-43`).
- `steam-<appid>.log` (`:18-21`) only with `MACNEUTRON_LOG=1`: env header (`Launcher.swift:186-199`) + all Wine
  stdout/stderr of the game run (`Launcher.swift:139`); prefix setup, `wineserver -w`, replay go elsewhere
  (`output: nil` or `replay.log`).
- Launch summary line carries `runtime=` from `layout.runtimeVersion` and `gptk=` (`Launcher.swift:116-117`): an arm64
  launch needs its own runtime identity here (none exists in the bundle, §2.1).

---

## 10. Installation and packaging facts relevant to a second runtime

- Rosetta runtime install: pinned tarball (`RuntimePin.current`, `runtime-v4.7.3`, URL + SHA-256,
  `RuntimeInstaller.swift:12-15`), cached in `~/Library/Caches/MacNeutron/<version>.tar.gz` (`:151-160`), extracted to
  `runtime.staging`, then `Libraries/` is replaced wholesale (`:96-98`), tool files + `runtime-version` written, GPTK
  overlay re-applied, bundled DXMT installed (`:99-104`). A wine.app placed under `<root>` but outside `Libraries/`
  survives a Rosetta runtime reinstall (I, from `:97-98`).
- `installFile` copies one file via a `.new` temp + `rename` and skips identical bytes (`RuntimeInstaller.swift:136-148`):
  not usable for a signed bundle with in-bundle symlinks (`MacOS/ntdll.so`, `aarch64-unix/wine → ../../../../MacOS/wine`,
  native spec §4). `check.sh` installs with `cp -cR` (APFS clone, keeps symlinks) to a path with spaces:
  `"$WORK/Application Support/wine.app"` (`wine-arm64/check.sh:19,615`).
- App start (`AppModel.swift:70-77`): rewrites tool files and installs bundled DXMT only when a runtime is installed.
  The app's "helper" is `Contents/Helpers/macneutron` (`AppModel.swift:89-95`). Setup completeness = Rosetta runtime
  version + Steam Play wanted (`AppModel.swift:85`); Setup's step text "Downloads the Wine runtime (461 MB)"
  (`SetupView.swift:17-19`).
- Signing: MacNeutron.app and everything in it is ad-hoc signed (`Makefile:94,97,103,104`); wine.app is Developer ID
  + hardened runtime + provisioning profile + restricted entitlement (`wine-arm64/bundle.sh:116,118`; native spec
  §7). Notarization of the entitled bundle is unverified (native spec §11, ship-base §13). wine.app requires
  macOS 27 (`wine-arm64/Info.plist:15-16`); the launcher/app target macOS 26 (`Package.swift:6`); native spec §9 says
  sub-project 5 turns "macOS below 27" into a preflight error (`...native-arm64-design.md:456`).
- Runtime check of the loader's entitlement is inside Wine (patch 7 `fatal_error`, native spec §5.2 row 7); the
  launcher does not check signatures today.

---

## 11. Seams: hard-coded to Rosetta vs already abstract

### Hard-coded to the Rosetta runtime
| Where | What |
|---|---|
| `CommandLineTool.swift:18` | one `ToolLayout(executable:)` per process; no runtime parameter |
| `ToolLayout.swift:20-58` | every runtime path (`Libraries/Wine/bin/wine`, `x86_64-unix`, `x86_64-windows`, `i386-windows`, `Libraries/DXMT/x64|x32`, `runtime-version`, `dxmt-version`, `bin/steam.exe`) |
| `Preflight.swift:29-36` | Rosetta required for every launch; runtime = `layout.wine` + `runtime-version` |
| `SteamPlayMode.swift:44,93` | Rosetta required to turn Steam Play on |
| `LaunchEnvironment.swift:14-16` | `ROSETTA_ADVERTISE_AVX=1` |
| `Launcher.swift:159-167` | presenter via `DYLD_INSERT_LIBRARIES` |
| `Launcher.swift:68`, `PrefixManager.swift:35-39,48-54` | single prefix/version per compatdata; no FEX registration; boot without `mscoree,mshtml=` |
| `Launcher.swift:127-133` | `terminate` uses `layout.wineserver` and `context.prefix` from Steam's raw env |
| `GraphicsBackend.swift:44-59` | `x64`→system32, `x32`→syswow64 |
| `GraphicsBackend.swift:9-26` | GPTK/DXVK fallbacks keyed on the Rosetta tool folder's `gptk.json` |
| `SteamBridge.swift:18-24`, `ToolLayout.swift:33-43` | x64 `steam.exe`, `x86_64-*` lsteamclient |
| `ShaderPrecache.swift:13,20,80-81` | stamp from tool `dxmt-version`; replayer `x64/dxmt-replay.exe` |
| `Launcher.swift:116-117` | log `runtime=`/`gptk=` from the one layout |
| `RuntimeInstaller.swift:110-133`, `Makefile:86-104` | one launcher, one `steam.exe`, presenter; no wine.app in the app bundle |

### Already abstract (reusable as-is)
- `ProcessRunner` protocol (`ProcessRunner.swift:4-8`) and `FakeRunner` (tests record `tool` by last path component).
- Verb parsing, `CompatContext`, prefix lock, the `wineserver -w` choreography, `steam.exe`-wrapped `runGame`
  (Windows paths only, `SteamBridge.swift:7,10-12`), `STEAM_COMPAT_CLIENT_INSTALL_PATH`/account logic.
- `LaunchEnvironment.mergeOverrides`, `WINEDEBUG`/`WINEMSYNC` defaults, DXMT override string (same for arm64).
- Per-game settings channel: `GameSettings.environment` merged under launch options (`GameSettings.swift:23-31`,
  `Launcher.swift:48`) — a per-game runtime choice can ride it without touching Steam's config; contrast `runAs`, the
  only setting that needs a Steam sync (`AppModel.swift:195-213`). Codable ignores unknown keys (stack-map:90).
- `MappingPlanner.isOurs` prefix match (`MappingPlanner.swift:82`) if a second Steam tool were ever wanted.
- `PrefixManager` takes `layout` + `runtimeVersion` as values (`PrefixManager.swift:27-32`): a second layout/version
  drops in.

### Smallest plug-in shape the code suggests (I)
`Launcher.layout` is the single pivot: every runtime-specific value is read from it. Choosing a second layout value per
launch (after settings merge, before preflight) and giving it arm64 paths covers wine/wineserver/DXMT/bridge/version;
the remaining differences are behavioural (preflight, presenter, FEX reg, boot overrides, no syswow64, prefix
location) and live in `Preflight`, `addPresenter`, `PrefixManager.prepare`, `prefixDLLs`, `CompatContext.prefix`.
`terminate` needs the same choice re-derived (settings re-loaded) from Steam's raw env.

---

## 12. Open design questions (with the evidence that makes each one)

1. **Runtime identity of wine.app.** No version in the bundle (`wine-arm64/Info.plist:1-18`; `Resources/` has no
   version file); the stamp is `build/wine-arm64/version` outside it. Needed by `PrefixManager.needsPreparation`
   (`PrefixManager.swift:35-39`), the launcher log (`Launcher.swift:116-117`) and `Preflight` (`:35`). Write a
   version file into the bundle at build time (re-sign), or beside it at install?
2. **Where wine.app is installed and how it ships.** Row 5: "installing wine.app (at a path with spaces, as
   wine-arm64/check.sh tests)" (`...native-arm64-design.md:65`); `check.sh` uses `.../Application Support/wine.app`
   (`check.sh:19`). Inside the `macneutron` tool folder (outside `Libraries/`, which reinstall wipes,
   `RuntimeInstaller.swift:97-98`) or a sibling? Downloaded like `RuntimePin` (`RuntimeInstaller.swift:12-15,151-160`)
   or embedded in MacNeutron.app (ad-hoc signed, `Makefile:104`) — nesting a Developer-ID/entitled bundle in an
   ad-hoc app, and notarizing either, is unverified.
3. **Per-game choice: setting vs second Steam tool.** `GameSettings` (env channel, no Steam restart) vs a
   `macneutron-arm64` tool (already "ours" by `MappingPlanner.swift:82`, but `filesIntact`/`verify` know only two
   tools, `SteamPlayMode.swift:63-67,271`, and a mapping change needs Steam closed, `SteamPlayMode.swift:161`).
   Also the default: roadmap §1 says a game moves when it meets ≤ ~1.4× CPU cost (`...native-arm64-design.md:47`) —
   so is the default Rosetta with arm64 opt-in until row 9?
4. **Separate prefix naming.** `pfx`, `version`, `macneutron.lock`, `dxmt-pipelines` are all fixed names under
   compatdata (`CompatContext.swift:26-28`, `ShaderPrecache.swift:16`). `pfx-arm64` beside `pfx`, or a subfolder?
   Unknown whether Steam itself reads anything under `compatdata/<id>/pfx` on macOS (e.g. cloud-save path
   translation) — docs have nothing on it (grep for cloud/steamuser: no hits). Shared or separate
   `dxmt-pipelines` (stamps differ per runtime, §8)? `OrphanPrefixes` measures the whole compatdata dir
   (`OrphanPrefixes.swift:15-21`), so either layout is cleaned up.
5. **Preflight split.** Today Rosetta is checked first for every launch (`Preflight.swift:30`) and for Steam Play enable
   (`SteamPlayMode.swift:93`). For arm64: macOS ≥ 27 (native spec §9), wine.app present/executable, maybe the
   entitlement (or leave to patch 7's `fatal_error`). Should Steam Play enable still require Rosetta while every
   game can run arm64? (Row 9 deletes the Rosetta preflight only at cutover, `...native-arm64-design.md:69`.)
6. **Presenter without `DYLD_INSERT_LIBRARIES`.** Hardened runtime, no `allow-dyld-environment-variables`
   (`bundle.sh:116,118`, `wine.entitlements`). Options seen: add that entitlement (stack-map:70 says it would be
   needed), or load it from `winemetal.so` (stack-map:70). The presenter swizzles `CAMetalLayer -nextDrawable` in a
   constructor (`presenter/present.m:279-297`), while Wine patch 13's layer posts `CLIENT_SURFACE_PRESENTED` from
   `nextDrawable` (arm64 DXMT spec §5, `...arm64-dxmt-design.md:106`) — their interaction is untested.
   `disable-library-validation` is set, so an ad-hoc-signed dylib could be dlopened (I).
7. **Mono/Gecko on arm64 boot.** wine.app has none; check.sh boots with `mscoree,mshtml=` (`check.sh:156`); the
   launcher boots with neither (`PrefixManager.swift:48`). Does arm64 `wineboot -u` prompt/hang, and should the
   launcher disable them for arm64 prefixes?
8. **`terminate` and Stop.** Uses Steam's raw env and `layout.wineserver` (`Launcher.swift:127-133`,
   `CommandLineTool.swift:19,83`). With a per-game runtime it must re-load settings to find the right prefix and
   server. (I) `wineserver -k` is lock-file based, so the x86_64 server binary may still kill an arm64 server, but it
   would target the wrong prefix if prefixes differ.
9. **AVX switch on arm64.** `ROSETTA_ADVERTISE_AVX` and the `avx` toggle (`LaunchEnvironment.swift:14-16`,
   `GamesView.swift:55`) are Rosetta-only; FEX's equivalent name is unknown (stack-map:74). Hide, relabel, or ignore?
10. **Graphics picker on arm64.** Only DXMT exists there; `select` would still honour `d3dmetal`/`dxvk` from settings
    (`GraphicsBackend.swift:9-26`). Force dxmt with a note when the runtime is arm64?
11. **lsteamclient in releases** (ship-base §1, `...ship-base-wine-design.md:40`): ship, ask Valve, or omit and leave
    Steam-API games on Rosetta. Also stripping builtin PEs (`lsteamclient.dll` 57 MB,
    `docs/testing/acceptance-arm64-ship-base.md:375`).
12. **Row 5's `tests/helper.exe` "into prefixes".** It is only the bridge check's fake game (`bridge/check.sh:28-30`);
    likely a wording slip — confirm it is not a runtime file.
13. **`dxmt-replay.exe` in system32.** `check.sh` copies all of `aarch64-windows/*`, replayer included
    (`check.sh:468`); the Rosetta path keeps the replayer in the tool folder (`ToolLayout.swift:58`,
    `GraphicsBackend.swift:47`). Copy only the four DLLs and run the replayer from the bundle?
14. **x64 `steam.exe` vs aarch64.** Which `steam.exe` the app ships and where (`Makefile:93` copies only x64;
    `writeToolFiles` knows one name, `RuntimeInstaller.swift:121-126`).
