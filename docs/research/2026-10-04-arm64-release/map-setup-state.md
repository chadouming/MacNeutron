# Sub-project 5 map: setup, state and UI

Reader: setup/state/UI area. Read-only. Repo `/Users/chad/Documents/MacProton`, HEAD `95f8883`. All paths are relative to the repo unless absolute. Line numbers are from the files as of that commit.

Summary: the Swift side knows about exactly one runtime, the Rosetta tool folder (`ToolLayout`), and assumes it all the way through. That covers setup, preflight, prefix identity, the Steam bridge, DXMT install, the per-game UI and Steam Play mode's own Rosetta gate. nothing in `Sources/` refers to wine.app, `aarch64` or `MACNEUTRON_ARM64` (`grep -rn -E 'wine\.app|aarch64|MACNEUTRON_ARM64' Sources` matches only `wine.appending(...)` in `DXMTInstaller.swift:75,80`). `wine-arm64/check.sh` is the only code that installs it, prepares a prefix for it and runs it. Its recipe is the template the launcher has to take over.

---

## 1. On-disk state (where everything lives)

| What | Path | Source |
|---|---|---|
| MacNeutron's own root | `~/Library/Application Support/MacNeutron/` | `SteamLocation.swift:5-8` (`MacNeutronPaths.root`) |
| Compat tools folder | `<root>/compatibilitytools.d/` | `SteamLocation.swift:9` |
| Rosetta tool folder (`ToolLayout.defaultRoot`) | `<root>/compatibilitytools.d/macneutron/` (a path that contains a space, "Application Support") | `ToolLayout.swift:14-18` |
| Native passthrough tool | `<root>/compatibilitytools.d/macneutron-native/` | `SteamPlayMode.swift:49,56` |
| Per-game settings | `<root>/games/<appid>.json` | `SteamLocation.swift:10`, `GameSettings.swift:34-40` |
| config.vdf backups | `<root>/backups/` | `SteamLocation.swift:11`, `SteamPlayMode.swift:50` |
| Steam Play intent flag | `<root>/steam-play-enabled` (empty file) | `SteamPlayMode.swift:51,60` |
| Runtime tarball cache | `~/Library/Caches/MacNeutron/<pin.version>.tar.gz` = `runtime-v4.7.3.tar.gz` | `RuntimeInstaller.swift:150-160` |
| Logs | `~/Library/Logs/MacNeutron/launcher.log` (+`.1`), `steam-<appid>.log` | `LauncherLog.swift:3,10-18` |
| Steam links to our tools | `~/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/compatibilitytools.d/{macneutron,macneutron-native}` → symlinks into `<root>/compatibilitytools.d/` | `SteamLocation.swift:23-24`, `SteamPlayMode.swift:57,222-230` |
| Per-game prefix | `<library>/steamapps/compatdata/<appid>/pfx` (Steam picks `STEAM_COMPAT_DATA_PATH`) | `CompatContext.swift:18-28` |
| Prefix runtime stamp | `compatdata/<appid>/version` | `CompatContext.swift:27` |
| Prefix lock | `compatdata/<appid>/macneutron.lock` | `CompatContext.swift:28` |
| Shader recordings | `compatdata/<appid>/dxmt-pipelines/` (stamp `replayed`) | `ShaderPrecache.swift:16,23` |

### Tool folder layout (`ToolLayout`, `ToolLayout.swift`)
`<tool>/` holds:
- `compatibilitytool.vdf`
- `toolmanifest.vdf`
- `proton` (sh stub)
- `bin/macneutron` (launcher) and `bin/steam.exe` (x64 bridge helper)
- `lib/libmacneutron-present.dylib` (presenter)
- `Libraries/{Wine,DXMT,DXVK}` (tarball contents)
- `runtime-version`
- `gptk/` (pristine GPTK lib) and `gptk.json`
- `dxmt-version`

Lines: 20-37 for the paths, 46 for the presenter, 50 for `dxmt-version`. Every accessor is x86_64-shaped:
- `wineLib/wine/x86_64-unix/lsteamclient.so`, `x86_64-windows/lsteamclient.dll`, `i386-windows/lsteamclient.dll` (`:35-37`);
- `dxmt/x64/d3d12.dll`, `dxmt/x64/dxmt-replay.exe` (`:55,58`).

`ToolLayout(executable:)` resolves `<root>/bin/macneutron` → `<root>` (`:10-12`). The launcher Steam runs builds its layout this way (`CommandLineTool.swift:18`). **The launcher therefore knows only the tool folder it was copied into.**

---

## 2. How the Rosetta runtime is obtained

**Pin.** `RuntimePin.current` (`RuntimeInstaller.swift:12-15`):
- version `runtime-v4.7.3`;
- URL `https://github.com/dappermint/winecx-gptk/releases/download/runtime-v4.7.3/Libraries.tar.gz`;
- sha256 `a4b5d634…fd331`.

The ponytail note at `:11` says to point the URL at the `chadouming/winecx-gptk` fork before the first public release.

**Download.** `RuntimeInstaller.cachedDownload(_:)` (`:151-160`):
- caches the tarball in `~/Library/Caches/MacNeutron/<version>.tar.gz`;
- downloads only when that file is missing;
- `download` goes through a temp file and requires HTTP 200 (`:163-168`).

**Install.** `RuntimeInstaller.install(tarball:pin:layout:launcherBinary:runner:)` (`:74-105`):
1. Checks the sha256 (`:76-79`). This is the only checksum check; the preflight doesn't repeat it (`Preflight.swift:17-18`).
2. Runs `tar -xzf` into `<tool>/runtime.staging` (`:82-89`).
3. Requires `Libraries/Wine/bin/{wine,wineserver}` to be executable (`:90-94`).
4. Removes `dxmt-version`, swaps `Libraries` (`:96-98`).
5. Calls `writeToolFiles` (`:99`) and writes `runtime-version` (`:100`).
6. Re-applies the GPTK overlay when `gptk/` exists (`:101-103`).
7. Calls `DXMTInstaller.installBundled` (`:104`).

**Tool files.** `writeToolFiles(layout:launcherBinary:)` (`:110-133`) is idempotent and runs at every app start (`AppModel.swift:74-77`). It writes:
- `compatibilitytool.vdf`: tool `macneutron`, `from_oslist windows`, `to_oslist linux` (`:34-49`);
- `toolmanifest.vdf`: `commandline "/proton %verb%"` (`:50-57`);
- the `proton` stub: `exec "$(dirname "$0")/bin/macneutron" launch "$@"` (`:58-62`).

It then copies:
- the launcher into `bin/macneutron`;
- `steam.exe`, from next to the launcher or from `../Resources/steam.exe` (`:121-126`);
- the presenter, from next to the launcher or from `../Frameworks/` (`:128-132`).

Copies go through `installFile` (temp file plus `rename(2)`, skipped when the bytes are identical, `:136-148`).

**Callers.**
- App: `AppModel.installRuntime()` (`AppModel.swift:142-149`), with the busy text "Downloading and installing the runtime (461 MB, first time only)…". The launcher binary passed in is `AppModel.helper`, which is `Contents/Helpers/macneutron` in the bundle, or the file next to the executable in development (`:89-95`).
- CLI: `macneutron install-runtime [--tool-dir <dir>] [--tarball <file>]` (`CommandLineTool.swift:31-43`).

**GPTK.**
- `GPTKDiskImage.importGPTK(from:into:)` (`GPTKDiskImage.swift:19-31`) mounts the outer image and the nested "Evaluation environment*.dmg" read-only with stdin closed, so a licence prompt fails instead of being accepted (`:64-82`).
- `GPTKImporter.importGPTK` (`GPTKImporter.swift:73-92`) then validates the required files (`:28-35`), copies them with `ditto` into `<tool>/gptk/lib` and overlays them onto `Libraries/Wine/lib` (`:95-106`). The overlay symlinks `x86_64-unix/{d3d10,d3d11,d3d12,dxgi}.so` to `libd3dshared.dylib`.
- It writes `gptk.json` (version plus ISO date).
- GPTK is x86_64-only (roadmap §1, `2026-10-02-…-native-arm64-design.md:27`), so none of this applies to arm64.

**DXMT (Rosetta).**
- `DXMTBuild.bundled(near:)` (`DXMTInstaller.swift:37-43`) looks in `<helpers>/DXMT/`, then in MacNeutron.app's `Contents/Resources/DXMT` (Windows half) and `Contents/Frameworks/DXMT` (`x86_64-unix/winemetal.so`, signed code).
- `DXMTInstaller.install` (`:68-86`) installs:
  - `x86_64-unix/*` into `Wine/lib/wine/x86_64-unix`;
  - `winemetal.dll` into `Wine/lib/wine/{x86_64,i386}-windows`;
  - the front ends into `Libraries/DXMT/{x64,x32}`, where x64 also gets d3d12 and `dxmt-replay.exe` (`:56-59`);
  - `dxmt-version`, last.
- `installBundled` runs only when the version differs (`:90-94`).
- `make app` copies `build/dxmt/{x86_64-windows,i386-windows,version,licences}` into `Contents/Resources/DXMT/` and `build/dxmt/x86_64-unix` into `Contents/Frameworks/DXMT/`, each file ad-hoc signed (`Makefile:98-103`).
- This path is x86_64-only. arm64 DXMT ships inside wine.app (§9 below).

---

## 3. Preflight: what is actually checked

`Preflight.check(_ layout:)` (`Preflight.swift:29-36`) checks exactly two things, in this order:
1. Rosetta is present: `/Library/Apple/usr/libexec/oah/libRosettaRuntime` exists (`:20-25`). Failure → `.rosettaMissing`, "Run: softwareupdate --install-rosetta …" (`:10`).
2. `Libraries/Wine/bin/wine` and `wineserver` are executable, and `runtime-version` is readable. Failure → `.runtimeMissing`, "Repair it with: macneutron install-runtime" (`:12`).

**What is not a preflight check** (the task's list doesn't match the code):
- **macOS version:** nothing in `Sources/` reads it (no `operatingSystemVersion` and no `sw_vers` anywhere). The only floors are `LSMinimumSystemVersion 26.0` (`App/Info.plist:12`) and `platforms: [.macOS("26.0")]` (`Package.swift:6`). The macOS ≥ 27 check exists only in `wine-arm64/check.sh:141-144`. The roadmap's errors table says "Sub-project 5 turns this into a preflight error" (`native-arm64-design.md:456`).
- **GPTK:** not a preflight. It is a backend fallback: d3dmetal without GPTK becomes dxmt, and dxvk with GPTK becomes d3dmetal (`GraphicsBackend.swift:17-24`).
- **AVX:** not a preflight. It is an environment default: `ROSETTA_ADVERTISE_AVX=1` unless `MACNEUTRON_NO_AVX=1` or the user set it (`LaunchEnvironment.swift:14-16`).

**How preflight failures surface.**
- `Launcher.launch` merges the game settings into the environment first (`Launcher.swift:46-51`), then runs the preflight (`:52-56`).
- On failure, `fail(…, notify: true)` (`:201-206`):
  1. appends `error: <msg> argv=…` to `launcher.log`;
  2. writes the message to stderr;
  3. posts a macOS notification through `osascript display notification` (`AppleScriptNotifier`, `Preflight.swift:45-58`);
  4. returns exit 1 to Steam.
- The app UI never runs `Preflight`.

**A second Rosetta gate.** `SteamPlayMode.enable` throws `SteamPlayError.rosettaMissing` before touching Steam (`SteamPlayMode.swift:44,93`; message `SteamLocation.swift:98`). The test `turningOnWithoutRosettaLeavesSteamRunning` covers it (`AppModelTests.swift:83`). **Without Rosetta, Steam Play mode cannot be turned on at all**, whatever runtime a game would use.

**Ordering consequence.** Settings are merged before the preflight (`Launcher.swift:48`), so a per-game runtime choice stored in `GameSettings.environment` is already known when the preflight runs. But `Launcher` holds a single `layout: ToolLayout` (`:14`), and the preflight takes that layout.

---

## 4. Prefixes: creation, naming, reuse, cleanup

**Location.** Steam owns the location: `STEAM_COMPAT_DATA_PATH` is `compatdata/<appid>`, and the prefix is always `<that>/pfx` (`CompatContext.swift:19-26`). The app ID comes from `SteamAppId`, default `"0"` (`:23`). This gives **one prefix per game per Steam library, with no runtime in its name.**

**Reuse rule.** `PrefixManager.needsPreparation` (`PrefixManager.swift:35-39`) is true when `pfx` is missing or when `compatdata/<appid>/version` ≠ `runtimeVersion`. The launcher passes `layout.runtimeVersion ?? "unknown"` (`Launcher.swift:68-69`).

**`prepare(backend:environment:steamBridge:)`** (`PrefixManager.swift:44-59`):
1. Creates `dataPath` and takes a `flock` on `macneutron.lock`, held only for preparation (`:102-111`).
2. If preparation is needed:
   - runs `wine wineboot -u` with the full launch environment (`:48`). That environment carries the backend's `WINEDLLOVERRIDES`, but not check.sh's `mscoree,mshtml=`;
   - on a non-zero status, throws `.winebootFailed` and leaves the version unrecorded (`:49`);
   - sets `ShowCrashDialog=0` with best-effort `reg add` (`:52-53`);
   - writes the version (`:54`).
3. Always deploys the backend DLLs (`:56`, `:61-71`). Sources come from `GraphicsBackend.prefixDLLs` (`GraphicsBackend.swift:44-59`): `Libraries/{DXMT,DXVK}/{x64,x32}` → `drive_c/windows/{system32,syswow64}`, plus `dxmt/x64/d3d12.dll` → system32. A missing source is a hard error (`:63-66`).
4. If `steamBridge` is set, deploys the bridge (`:57`, `:74-80`). Files come from `SteamBridge.prefixFiles` (`SteamBridge.swift:18-25`): `bin/steam.exe`, the x86_64 `lsteamclient.dll` as `steamclient64.dll`, and optionally the i386 one as `steamclient.dll`. All go into `drive_c/Program Files (x86)/Steam/` (`:15`).
5. `removeSteamBridge()` deletes those three files when the bridge is off (`PrefixManager.swift:85-91`).
6. Nothing under `drive_c` is ever deleted (`:42-43`). A runtime change only re-runs `wineboot -u` over the existing prefix (`PrefixManagerTests.swift:42` `runtimeChangeUpgradesPrefix`).

**Where `terminate` points.** Steam's Stop runs `wineserver -k` with `WINEPREFIX=context.prefix`, using `layout.wineserver` (`Launcher.swift:127-133`). That is the Rosetta binary and the `pfx` path.

**Orphan cleanup.**
- `OrphanPrefixes.find(in:)` (`OrphanPrefixes.swift:11-25`) scans each library's `compatdata/` for numeric names that have no `appmanifest_<id>.acf`. It skips 0 and IDs ≥ 0x80000000 (non-Steam shortcuts).
- It sizes **the whole `compatdata/<appid>` folder** (`:21,31-40`).
- `delete` removes that whole folder (`:27-29`), so any second prefix family under the same folder is cleaned up for free.
- UI: `CleanupView` (`SettingsView.swift:43-76`); the menu item "Free up space (N MB)" (`MenuContent.swift:34-39`); `AppModel.cleanUp` (`AppModel.swift:216-220`).

---

## 5. GameSettings (per-game state)

**Struct** (`GameSettings.swift:4-20`). Every field is optional, and nil means default:
- `graphics: String?`
- `log: Bool?`
- `avx: Bool?`
- `msync: Bool?`
- `runAs: RunAs?` (`.mac` / `.windows`, `MappingPlanner.swift:15-17`)
- `metalFX: Bool?`

**Environment mapping** (`GameSettings.swift:23-31`):
- graphics → `MACNEUTRON_GRAPHICS=<value>`
- `log == true` → `MACNEUTRON_LOG=1`
- `avx == false` → `MACNEUTRON_NO_AVX=1`
- `msync == false` → `MACNEUTRON_NO_MSYNC=1`
- `metalFX == false` → `MACNEUTRON_NO_METALFX=1`
- `runAs` is used only by the mapping planner.

**Storage.** `GameSettingsStore` (`:35-75`):
- file `~/Library/Application Support/MacNeutron/games/<appid>.json`, JSON with `.sortedKeys`, written atomically (`:49-54`);
- a missing file gives defaults, and a corrupt file throws (`:43-47`);
- `all()` skips unreadable files (`:57-65`);
- `runAsOverrides()` feeds `MappingPlanner` (`:68-74`).

**The launcher reads it** at `Launcher.swift:48`. The merge is `settings.environment.merging(steamEnv) { _, launchOption in launchOption }`, so Steam launch-option variables win. An unreadable file is logged and ignored (`:49-51`).

**Effect of the defaults** (`LaunchEnvironment.swift:6-24`):
- `WINEPREFIX`;
- `WINEDLLOVERRIDES`, merged with the user's;
- `WINEDEBUG=-all` (or the log set when logging);
- `ROSETTA_ADVERTISE_AVX=1`;
- `WINEMSYNC=1`, unless `MACNEUTRON_NO_MSYNC=1` or the user set `WINEMSYNC`. **The off switch leaves `WINEMSYNC` unset; it never sets `0`** (`:17-19`);
- `DXMT_PIPELINE_RECORD` when precache is enabled.

**Other launch-option-only variables** that are not in GameSettings:
- `MACNEUTRON_NO_STEAM_BRIDGE` (`Launcher.swift:146`)
- `MACNEUTRON_PRECACHE=0` (`ShaderPrecache.swift:20`)
- `MACNEUTRON_STEAM_ACCOUNT` (`Launcher.swift:178`)

**How the UI edits settings.** `AppModel.update(_ appID:, _ change:)` (`AppModel.swift:195-214`):
1. bumps `generation`, so a stale snapshot can't revert the change (`:106-108,197`);
2. mutates `games[i].settings` and saves;
3. if the app list is readable and Steam is not running, calls `mode.sync(plan:)` right away; otherwise status becomes `.restartNeeded`.

In `GamesView`, every binding writes nil when the value equals the default (`GamesView.swift:26,39,90-93`).

---

## 6. What the user sees (SwiftUI)

**App shell** (`MacNeutronApp.swift:6-39`):
- a menu-bar app: `.accessory` policy (`:10`) and `LSUIElement` (`App/Info.plist:13`);
- scenes: `MenuBarExtra`, `Window "setup"` (shown at launch unless `setupComplete`, `:20-24`), `Window "games"`, `Window "cleanup"`, `Settings`.

**`AppModel`** (`AppModel.swift:39-276`, `@Observable @MainActor`):
- **State:** `runtimeVersion`, `gptkVersion`, `status: SteamPlayStatus`, `games: [GameRow]`, `orphans`, `appInfoError`, `loginItemStatus`, `busy`, `errorMessage`.
- **`setupComplete`** = `runtimeVersion != nil && mode.isWanted` (`:85`). This requires the Rosetta runtime.
- **`init`** (`:63-83`):
  - reinstalls the native passthrough tool when Steam Play mode is on (`:72`);
  - **when a runtime is installed, re-runs `writeToolFiles` and `DXMTInstaller.installBundled`** (`:74-77`), so an updated app pushes its launcher, steam.exe, presenter and DXMT into the tool folder without a reinstall;
  - starts the 3 s Steam poll (`:250-275`).
- **`Snapshot`/`loadSnapshot`** (`:27-36,125-134`): runs off the main thread and reads appinfo, installed IDs, settings, orphans and status.
- **`GameRow`** (`:7-16`): `isDualPlatform`, and `runsWithMacNeutron` = not macOS, or dual-platform with `runAs == .windows`.

**`SetupView`** (`SetupView.swift`). Three steps:
1. "Install runtime": detail "Downloads the Wine runtime (461 MB)." Button Install/Reinstall → `installRuntime` (`:17-20`).
2. "Import Game Porting Toolkit (optional)": drag a .dmg in or choose one (`:22-31,62-64`).
3. "Turn on Steam Play mode": disabled until the runtime is installed and Steam is present (`:33-38`).

It also shows a native vs MacNeutron games summary (`:39-53`). There is no step or text about Rosetta, the macOS version or a second runtime.

**`GamesView`** (`GamesView.swift`). A table with these columns:
- **Game**, with an "Installed" badge (`:16-21`).
- **Runs as**: a picker for dual-platform games only (`:22-34`).
- **Graphics**: a picker when `runsWithMacNeutron`. Options are "Default (DXMT)", D3DMetal, DXMT, and DXVK; the DXVK label explains that it falls back to D3DMetal while GPTK is imported (`:35-49`).

Selecting a row shows a detail bar with the toggles Log (default false), AVX (true), msync (true) and "MetalFX upscaling" (true) (`:51-62`). It also shows the error and a "Restart Steam" bar (`:63-78`). There is no runtime column.

**`MenuContent`** (`MenuContent.swift`):
- status title;
- "Runtime <version> · D3DMetal <version>" (`:11`);
- Restart/Restore Steam;
- "Finish setup…", Games…, Open Steam, Free up space, Show logs (which opens `~/Library/Logs/MacNeutron`);
- Settings…, Quit.

**`SettingsView`** (`SettingsView.swift:5-41`): the login item; "Repair runtime" (= `installRuntime`); "Run setup again"; "Turn off Steam Play mode", with a confirmation that warns Windows games will be removed from disk.

---

## 7. Steam Play mode and tool mapping (touches the runtime-choice design)

- **`MappingPlanner`** (`MappingPlanner.swift:20-83`):
  - `runtimeTool = "macneutron"`, `nativeTool = "macneutron-native"`;
  - the global entry `"0"` is `macneutron` at priority 75, and each app gets priority 250;
  - `isOurs(tool)` = `tool.hasPrefix("macneutron")` (`:82`). **A third tool named `macneutron-arm64` would already count as ours** for merge and claim logic.
- **`SteamPlayMode` hard-codes exactly two tools:**
  - `filesIntact` checks the `toolmanifest.vdf` of `macneutron` and `macneutron-native` through Steam's bundle links (`SteamPlayMode.swift:63-67`);
  - `linkTools`/`unlinkTools` iterate those two names (`:222-234`);
  - `verify(log:)` requires `Registering tool macneutron,` and `Registering tool macneutron-native,` in `compat_log.txt` (`:266-278`).
- **`enable`** checks Rosetta, then:
  1. quits Steam;
  2. backs up `config.vdf`;
  3. installs the native tool, links the tools and writes the mappings;
  4. writes `steam_dev.cfg` (`@sSteamCmdForcePlatformType linux`) last (`:91-120`);
  5. verifies through the compat log within 60 s, and rolls back on failure.
- **Arch note** (`SteamPlayMode.swift:20-23`): "Steam starts tools preferring x86_64, which carries through `exec`". The passthrough script forces `arch -arm64e -arm64 -x86_64`. The Swift binaries are arm64-only (`file .build/release/macneutron` → `Mach-O 64-bit executable arm64`), as is `build/MacNeutron.app/Contents/Helpers/macneutron`.

---

## 8. The app's packaging, signing, sandbox and entitlements

**`make app`** (`Makefile:85-104`) depends on `build bridge presenter dxmt` and produces `build/MacNeutron.app`:
- `Contents/MacOS/MacNeutron` (the SwiftUI app)
- `Contents/Helpers/macneutron` (the CLI/launcher, ad-hoc signed, `:94`)
- `Contents/Resources/steam.exe` (**x64 only**, from `build/bridge/steam.exe`, `:93`)
- `Contents/Frameworks/libmacneutron-present.dylib` (universal x86_64+arm64, `Makefile:41`; ad-hoc signed, `:97`)
- `Contents/Resources/DXMT/` and `Contents/Frameworks/DXMT/x86_64-unix/*` (each ad-hoc signed, `:103`), after `dxmt/published.sh` (`:98`)
- the bundle itself, ad-hoc signed: `codesign --force --sign - $(APP)` (`:104`)

**No entitlements file, no hardened runtime flag (`-o runtime`), no sandbox, no notarization.** There is no release or notarize target anywhere: `.PHONY` at `Makefile:1` lists none, and `notar` appears in no Makefile, script or Swift file. The app writes into Steam's bundle and `~/Library/...`, which a sandbox would forbid.

**`App/Info.plist`**: `io.github.chadouming.MacNeutron`, version 0.1.0 (1), `LSMinimumSystemVersion 26.0`, `LSUIElement`.

**arm64 bridge outputs that are not packaged.**
- `make bridge` also builds `build/bridge/arm64/steam.exe` and `build/bridge/arm64/tests/helper.exe` (`Makefile:30-31`). These exist on disk today, but `make app` packages neither.
- `writeToolFiles` looks only for `steam.exe` next to the launcher or in `Resources/` (`RuntimeInstaller.swift:121-126`). There is no arm64 name.

**wine.app** (`wine-arm64/`):
- **Identity:** `net.authspot.macneutron.wine`, executable `wine`, `LSMinimumSystemVersion 27.0` (`wine-arm64/Info.plist`). **There is no CFBundleVersion or CFBundleShortVersionString.**
- **Entitlements** (`wine-arm64/wine.entitlements`):
  - application-identifier `49QMZXLR8S.net.authspot.macneutron.wine`;
  - team ID;
  - `cross-architecture-support`;
  - `allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation`.
- **Signing:** Developer ID plus provisioning profile, through `MACNEUTRON_SIGN_IDENTITY` and `MACNEUTRON_PROVISIONING_PROFILE`. There is no ad-hoc mode (`native-arm64-design.md:364-385`). Every Mach-O has `minos 27.0`.
- **Staged at** `build/wine-arm64/wine.app`. It is **1.3 GB** (`du -sh`). `lsteamclient.dll` alone is 57,496,064 bytes.
- **Version:** the build stamp is **outside** the bundle, at `build/wine-arm64/version` (`wine-arm64/build.sh:20,356`). Inside, the only identifier is `Contents/Resources/licenses/SOURCE` (keys `MACNEUTRON_COMMIT`, `WINE_COMMIT`, `WINE_SERIES`, `FEX_COMMIT`, `FEX_SERIES`, …; `bundle.sh:70`), plus `Resources/DXMT/version` (`<DXMT_COMMIT>+<series|dev>`, `bundle.sh:197-198`).
- **Notarization** of an entitled bundle is unverified (`native-arm64-design.md:476`).

---

## 9. wine.app contents relevant to the launcher, and check.sh's install/prefix recipe

**Bundle paths** (`native-arm64-design.md:191-204`; `bundle.sh`):
- loader: `Contents/MacOS/wine`, the only entitled binary;
- `wineserver`: `Contents/Resources/bin/wineserver`;
- PE DLLs: `Contents/Resources/lib/wine/aarch64-windows/`, including `winemetal.dll`, `libarm64ecfex.dll` and `lsteamclient.dll` (ARM64X, builtin marker; `bundle.sh:53,204-208`);
- unix libraries: `Contents/Resources/lib/wine/aarch64-unix/`, including `winemetal.so` and `lsteamclient.so`;
- **DXMT front ends for prefixes:** `Contents/Resources/DXMT/aarch64-windows/{d3d11,d3d10core,dxgi,d3d12}.dll` and `dxmt-replay.exe` (`bundle.sh:55-57`). They are not builtin-marked, and they go into `system32`.

**check.sh as the install model** (`wine-arm64/check.sh`):
- **Install:** `cp -cR "$STAGED" "$TOOL"` (an APFS clone, which keeps the signature, `:615`). The destination is `TOOL="$WORK/Application Support/wine.app"`. A comment says the clone sits at a path with a space "as Sub-project 5 will install it" (`:9-10,19`).
- **Signature check after install:**
  - `codesign --verify --strict --deep`;
  - the loader's entitlements contain `cross-architecture-support`;
  - `realpath(Resources/lib/wine/aarch64-unix/wine) == <bundle>/Contents/MacOS/wine` (`:146-154`).
  - A hand-copied loader without the entitlement makes Wine `fatal_error` with a message (`:176-185`; spec `:453`).
- **Running:** `WINEPREFIX=… "$TOOL/Contents/MacOS/wine" …` (`:134`). The server is at `$TOOL/Contents/Resources/bin/wineserver` (`:62`).
- **msync:** `export WINEMSYNC=1` for every run, because client and server must agree (`:30-32`). The msync step shows that a mismatched client exits with "Server is running with WINEMSYNC but this process is not" (`:277-300`).
- **Prefix creation recipe:**
  1. `WINEDLLOVERRIDES="mscoree,mshtml=" wine wineboot -i` (`:156`);
  2. FEX registration: `reg add 'HKLM\Software\Microsoft\Wow64\amd64' /ve /d libarm64ecfex.dll /f` (`:206-210`). The spec says "Sub-project 5 makes this part of prefix creation" (`native-arm64-design.md:360`);
  3. the crash dialog off: `reg add HKCU\Software\Wine\WineDbg /v ShowCrashDialog …` (`:381`);
  4. DXMT: `cp "$TOOL/Contents/Resources/DXMT/aarch64-windows/"* "$PFX/drive_c/windows/system32/"`, then checks with `cmp` and for the missing builtin marker (`:465-477`). The overrides used are `dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b`, the same as `GraphicsBackend.dxmt` with d3d12 (`:135-136`).
- **Bridge:** the arm64 bridge is driven by `bridge/check.sh` and `bridge/probe.sh` with `MACNEUTRON_ARM64_APP` and `MACNEUTRON_ARM64_PREFIX` (`:382,387-388`). The probe copies the bundle's `lsteamclient.dll` as `steamclient64.dll` (ship-base spec §7).

---

## 10. What would change, by roadmap row 5 item

### 10.1 Per-game runtime choice (Rosetta vs native arm64)
- **Storage:** add a field to `GameSettings` (`GameSettings.swift:4-20`), e.g. `runtime: String?` (nil = Rosetta today). Whether it goes through `environment` as a launch-option variable (like `MACNEUTRON_GRAPHICS`, so Steam launch options can override it) or is read directly is a choice. The merge at `Launcher.swift:48` already happens before the preflight.
- **Launcher:** `Launcher` has one `layout` (`Launcher.swift:14`) and uses it for:
  - the preflight (`:53`);
  - the backend choice (`:58-59`);
  - the environment (`:61-62`);
  - the bridge check (`:150`);
  - the presenter (`:161`);
  - `PrefixManager` (`:68`);
  - `wineserver -w`/`-k` (`:86,108,132`);
  - `runGame` (`:139`);
  - `winepath` (`:114`);
  - precache.

  An arm64 run needs a different wine/wineserver/DLL source for each of these. `terminate` (`:127-133`) has no settings in hand: it would need to load the setting, or kill both servers.
- **Backend:** in arm64 mode only DXMT exists. D3DMetal is x86_64-only (roadmap `:27`), and DXVK is the Rosetta tarball's. `GraphicsBackend.select` (`GraphicsBackend.swift:9-26`) and `prefixDLLs` (`:44-59`) hard-code `Libraries/DXMT/{x64,x32}`; arm64 needs `DXMT/aarch64-windows/*` → system32 only.
- **Environment:** `ROSETTA_ADVERTISE_AVX` (`LaunchEnvironment.swift:14-16`) is meaningless on arm64. `WINEMSYNC` must be set explicitly to `0` or `1` there (row 5: "`WINEMSYNC=1` for every arm64 run (`WINEMSYNC=0` per game as the off switch …)"). Today the off switch leaves it unset (`:17-19`).
- **Presenter:** `DYLD_INSERT_LIBRARIES` (`Launcher.swift:159-167`) is ignored by wine.app's hardened runtime (row 5).
- **Steam bridge:** `SteamBridge.prefixFiles` (`SteamBridge.swift:18-25`) and `ToolLayout.lsteamclient*`/`steamHelper` (`ToolLayout.swift:33-43`) are x86_64. arm64 needs the aarch64 `steam.exe` (`build/bridge/arm64/steam.exe`, not packaged in the app) and `wine.app/…/aarch64-windows/lsteamclient.dll`.
- **UI:**
  - a "Runtime" picker column, or a control in the detail bar of `GamesView` (`GamesView.swift:15-62`), shown only when `runsWithMacNeutron`;
  - when Runtime = arm64: Graphics locked to DXMT (or hidden), the AVX toggle hidden, the MetalFX toggle hidden or disabled until the presenter loads without DYLD;
  - `MenuContent.swift:11` shows only one runtime version.
- **Mapping:** no change if the choice stays inside the single `macneutron` tool. A separate Steam tool `macneutron-arm64` would need changes in `MappingPlanner.plan` (`:29-43`), `SteamPlayMode.filesIntact`/`linkTools`/`unlinkTools`/`verify` (`:63-67,222-234,266-278`) and `RuntimeInstaller.compatibilityTool` (`:34-49`). It would also need a Steam restart for every runtime switch, the same as Runs-as today (`AppModel.swift:193-214`).

### 10.2 A second prefix family
- Today it is always `compatdata/<appid>/pfx` (`CompatContext.swift:26`), with the version stamp `compatdata/<appid>/version` (`:27`). A runtime switch only triggers `wineboot -u` over the same prefix (`PrefixManager.swift:35-39,48`; test `PrefixManagerTests.swift:42`). Running arm64 Wine over an x86_64 prefix (or the reverse) gives a mixed prefix: system32 holds x86_64 builtins plus DXMT x64 DLLs, while arm64 needs ARM64X builtins plus `aarch64-windows` DXMT.
- **Minimal shape:**
  - `CompatContext` grows a runtime-scoped prefix, e.g. `pfx-arm64`, with its own `version-arm64` and lock. Or the lock is shared, so that two runtimes can't prepare at once.
  - **Steam's `getcompatpath`/`getnativepath` and `STEAM_COMPAT_DATA_PATH` remain per app.** Paths Steam hands in, such as save paths under `pfx/drive_c/users/<user>`, would differ per family.
- **Orphans:** `OrphanPrefixes` deletes all of `compatdata/<appid>` (`OrphanPrefixes.swift:21,27-29`), so both families are covered. No UI exists to delete one family of an installed game.
- **Shader cache:** `dxmt-pipelines` is per `dataPath` (`ShaderPrecache.swift:16`). The stamp is `"<dxmtVersion> <macOS build>"` (`:13`). The arm64 DXMT version string has a different form (`<DXMT_COMMIT>+…`), so sharing the folder across runtimes would trigger a replay on every switch, and recordings may not be portable. It would need to be per-runtime or tagged. `ShaderPrecache.enabled` checks `layout.dxmtHasD3D12` (`:19-21`), an x86_64 path.
- **Prefix preparation for arm64 must add:**
  - the `HKLM\Software\Microsoft\Wow64\amd64` = `libarm64ecfex.dll` registration (spec `:360`; check.sh `:208`);
  - the aarch64 DXMT copy;
  - possibly `mscoree,mshtml=` during wineboot. check.sh uses it, and the launcher doesn't on Rosetta either.

### 10.3 Split preflight
Today:
- `Preflight.check(layout)` = Rosetta + Rosetta runtime files (`Preflight.swift:29-36`);
- `SteamPlayMode.enable` separately requires Rosetta (`SteamPlayMode.swift:93`).

For arm64:
- macOS ≥ 27. Nothing checks this today; `ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27` is the obvious check.
- wine.app present, `MacOS/wine` executable, `Resources/bin/wineserver` present.
- Optionally the signature or entitlement, which costs more than a few `stat`s (preflight's stated budget, `Preflight.swift:17-18`). Wine's patch 7 already fails loudly without the entitlement (spec `:453`).
- **Rosetta not required.**

Error surfacing can reuse `PreflightError` plus `fail(notify: true)` (`Launcher.swift:201-206`).

App side:
- `SteamPlayMode.enable`'s Rosetta gate (`:93`) and its test `AppModelTests.swift:83` must become "Rosetta or arm64 available";
- `AppModel.setupComplete` (`AppModel.swift:85`) and `SetupView` step 3's `.disabled(model.runtimeVersion == nil …)` (`SetupView.swift:37`) require the Rosetta runtime;
- `MacNeutronApp`'s `defaultLaunchBehavior` depends on `setupComplete` (`MacNeutronApp.swift:24`).

### 10.4 Installing wine.app
- **Existing seam:** `AppModel.init` refreshes tool files and bundled DXMT at every start (`AppModel.swift:74-77`). `DXMTInstaller.installBundled` compares versions (`DXMTInstaller.swift:90-94`). A `WineAppInstaller.installBundled` would follow the same pattern, but **wine.app has no in-bundle version to compare**. Only `licenses/SOURCE` and `DXMT/version` exist (§8).
- **Copy method:** must preserve the signature and the in-bundle symlinks. check.sh uses `cp -cR` (`:615`). `RuntimeInstaller.installFile` reads files into `Data` (`:136-148`) and is unsuitable. `GPTKImporter.ditto` (`GPTKImporter.swift:109-114`) keeps symlinks and signatures (`:108`). Use a staging folder plus a rename swap, as `RuntimeInstaller.install` does (`:82-98`).
- **Destination:** under `~/Library/Application Support/MacNeutron/…`, which already contains a space, as check.sh models it. The Rosetta side already has a test for spaces in the tool path, `protonStubForwardsArgumentsFromAPathWithSpaces` (`RuntimeInstallerTests.swift:45`). It could sit inside the `macneutron` tool folder (e.g. `<tool>/wine.app`), so that `ToolLayout(executable:)` finds it relative to `bin/macneutron`. Or it could go in a sibling folder, with a pointer the launcher can read. **The launcher Steam runs is the copy in `<tool>/bin/macneutron`**, found through `ToolLayout(executable:)` (`ToolLayout.swift:10-12`, `CommandLineTool.swift:18`). It can't see MacNeutron.app, so wine.app must be at a path derivable from the tool folder, or recorded in it.
- **Source options:**
  - (a) inside MacNeutron.app. That makes the app at least 1.3 GB, and its Developer-ID-signed, entitled nested bundle sits inside an outer app that is ad-hoc signed today (`Makefile:104`). Running wine.app in place from the app bundle is also possible. The path would then follow the app's location (unverified: app translocation, the user moving the app);
  - (b) a separate pinned download like `RuntimePin` (`RuntimeInstaller.swift:5-16`), cached in `~/Library/Caches/MacNeutron`, with the same sha256 flow.
- **Also needed beside it:** the aarch64 `steam.exe` (`build/bridge/arm64/steam.exe`). It is not in the app (`Makefile:93`), and `writeToolFiles` has no slot for it (`RuntimeInstaller.swift:121-126`).

---

## 11. Open design questions (with the evidence that makes each one a question)

1. **One Steam tool with a per-game setting, or a third tool `macneutron-arm64`?** `isOurs` already accepts any `macneutron*` prefix (`MappingPlanner.swift:82`). But `SteamPlayMode` hard-codes two tools in `filesIntact`, `linkTools` and `verify` (`SteamPlayMode.swift:63-67,222-234,266-278`). A setting avoids Steam restarts; a tool makes the choice visible in Steam's own UI.
2. **Where wine.app comes from: inside MacNeutron.app or a separate download.**
   - Size: 1.3 GB staged, with `lsteamclient.dll` at 57 MB and row 5 asking to strip builtin PE files.
   - Signing: MacNeutron.app is ad-hoc throughout (`Makefile:94,97,103,104`); wine.app is Developer ID, entitled and `minos 27`.
   - Notarization of either is unverified (spec `:476`).
   - Nesting an entitled bundle needs the outer app re-signed with Developer ID and the hardened runtime, which the repo has no target for.
3. **Install location and how the launcher finds it.** The installed launcher derives everything from its own path (`ToolLayout.swift:10-12`) and never sees MacNeutron.app. Is wine.app installed under the tool folder (e.g. `compatibilitytools.d/macneutron/wine.app`), or does the tool folder record a path? check.sh's model is only "a path with a space" (`check.sh:9-10,19`).
4. **How to tell whether the installed wine.app is current.** There is no CFBundleVersion (`wine-arm64/Info.plist`). The build stamp is outside the bundle (`build/wine-arm64/version`, `build.sh:356`). Only `licenses/SOURCE` and `DXMT/version` are inside. A pin or version file must be added to the bundle, or the `SOURCE` hash used.
5. **Shape of the prefix family:** a separate folder (`pfx-arm64`), or the version string tagged with the runtime? Today a runtime change only re-runs `wineboot -u` over the same `pfx` and never clears `drive_c` (`PrefixManager.swift:35-48`; `PrefixManagerTests.swift:42`). Switching back and forth would mix architectures. Separate prefixes split save data that lives in the prefix, and `getcompatpath` answers per family.
6. **What about saves and settings when a game switches runtime?** Nothing copies data between prefixes. The settings dialog text says "Saves inside their prefixes are kept" (`SettingsView.swift:38`), which shows the project already treats prefix data as user data.
7. **msync per game, given a live wineserver.** The client and server must agree or the client exits (spec `:472`; `check.sh:294-299`). The launcher never kills a running wineserver before launch, and `prepare` runs wine under the lock (`PrefixManager.swift:46-48`). A per-game toggle flip while a server is alive (for example during the `-w` wait or a game launcher) would fail. Today the off switch leaves `WINEMSYNC` unset, not `0` (`LaunchEnvironment.swift:17-19`).
8. **Default runtime per game, and gating on macOS 26.** The app's minimum is 26.0 (`App/Info.plist:12`, `Package.swift:6`), and the arm64 stack needs 27 (roadmap `:54`). Nothing checks the OS version today. Should the arm64 option be hidden or disabled below 27? The roadmap's per-game rule says a game moves only after its own measurements (`:47`, row 9), which suggests Rosetta stays the default in sub-project 5.
9. **A Mac without Rosetta.** `SteamPlayMode.enable` refuses (`:93`), `setupComplete` needs the Rosetta runtime (`AppModel.swift:85`), and the setup flow's step 1 is the 461 MB Rosetta download (`SetupView.swift:17-20`). Is a no-Rosetta setup path in scope for sub-project 5, or only the launcher split? Also unverified: whether Steam's tool launch, which "prefers x86_64" (`SteamPlayMode.swift:20-23`) through `/bin/sh` and the `proton` stub, works with Rosetta absent. All Swift binaries are arm64-only.
10. **lsteamclient redistribution.** `lsteamclient.dll` and `.so` are inside wine.app (`bundle.sh:204-210`), under Valve's Steamworks SDK licence. Row 5 says it is "not redistributed until decided". If the answer is no, a release wine.app must leave it out, and the bridge must be disabled in arm64 mode (as with `MACNEUTRON_NO_STEAM_BRIDGE`, `Launcher.swift:146`), or the user must obtain it some other way.
11. **Presenter in arm64 mode.** `DYLD_INSERT_LIBRARIES` (`Launcher.swift:159-167`) is ignored under wine.app's hardened runtime (row 5). Until another loading path exists, the MetalFX toggle (`GamesView.swift:57`) is a no-op on arm64. Should it be hidden?
12. **Shader pre-caching across runtimes.** `dxmt-pipelines` is per app (`ShaderPrecache.swift:16`), and the stamp is `dxmtVersion + macOS build` (`:13`) from the x86_64 layout. The replayer for arm64 is `wine.app/…/DXMT/aarch64-windows/dxmt-replay.exe` (`bundle.sh:55`). Per-runtime folders or a shared one?
13. **`terminate` needs the runtime.** Steam's Stop calls `wineserver -k` from the Rosetta layout on `pfx` (`Launcher.swift:127-133`) without loading settings. In arm64 mode it must use wine.app's `wineserver` and the arm64 prefix (and `WINEMSYNC` must match, see 7).
14. **App-start refresh cost.** `AppModel.init` synchronously re-runs `writeToolFiles` and the DXMT install on the main actor (`AppModel.swift:74-77`). Byte-comparing a 1.3 GB wine.app there would be too slow; a version-file compare is needed (see 4).
15. **Rosetta-app notices.** Row 5 also parks "the Rosetta app's missing LLVM and mingw-w64 notices". `make app` copies DXMT's licences only (`Makefile:100-101`), and there is no licences folder for the app itself.
