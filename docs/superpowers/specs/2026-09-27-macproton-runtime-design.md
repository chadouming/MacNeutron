# MacProton — Architecture and Sub-project 1: Runtime

- **Date:** 2026-09-27
- **Status:** Draft for review
- **Scope of this spec:** overall v1 architecture (context for all sub-projects) and the full design of sub-project 1 (the `macproton` runtime). Sub-projects 2 (Steam API bridge) and 3 (Steam integration + menu-bar app) get their own specs.

## 1. Goal

A public, open-source "Proton for macOS": Windows games from the user's Steam library install and run from the native macOS Steam client's own Install/Play buttons, translated by Wine and Apple's D3DMetal (Game Porting Toolkit), the way Proton integrates with Steam on Linux.

**v1 is done when** a Windows-only Steam game that uses the Steam API (DRM, achievements) installs and launches from native macOS Steam's Play button, and Mac-native games in the same library keep working. v1 spans all three sub-projects.

### Decisions made during brainstorming

| Decision | Choice |
|---|---|
| Audience | Public open-source project |
| Steam integration | "Steam Play mode" (A) with a sidecar fallback (B) built in |
| D3DMetal sourcing | User imports Apple's GPTK; we never redistribute Apple files; DXMT bundled as fallback |
| Form factor | Native SwiftUI menu-bar app over a shared Swift core |
| v1 scope | Runtime + Steam API bridge + Steam integration |
| Platform | Apple Silicon, macOS 26+, Rosetta 2 required |

## 2. Evidence: what native macOS Steam allows

Verified on macOS 27, Steam client build 1788652215, with throwaway probe tools. No Steam binary was modified.

1. macOS `steamclient.dylib` contains Valve's full compat-tool system (`CCompatManager`, `compatibilitytools.d`, `toolmanifest.vdf`, `CompatToolMapping`, all `STEAM_COMPAT_*` variables).
2. Tools found via `STEAM_EXTRA_COMPAT_TOOLS_PATHS` register, and `CompatToolMapping` entries are honored. By default nothing is *applied*: Windows-only games stay `InvalidPlatform` (display_status 14), dual-platform games get Mac depots, Play runs the native binary.
3. Static analysis: the `CCompatManager` constructor enables compat only when the client platform string is `"linux"`. That string comes from `GetPlatformName()` unless the convar `@sSteamCmdForcePlatformType` is set, and it is latched at startup.
4. `@sSteamCmdForcePlatformType linux` in `Steam.AppBundle/Steam/Contents/MacOS/steam_dev.cfg` (the only location read; the Steam root is ignored) turns on "Steam Play mode". In that mode full Proton parity was observed:
   - Windows-only games become installable.
   - Windows depots are chosen automatically.
   - Play runs `<tool> waitforexitandrun <game.exe>` with `STEAM_COMPAT_DATA_PATH`, `STEAM_COMPAT_INSTALL_PATH`, `STEAM_COMPAT_CLIENT_INSTALL_PATH` and `SteamAppId` set.
5. Cost of that mode: installed games without a mapping for the active platform are **unmounted**, meaning their files are removed and fully redownloaded when switching back. Valve's Linux Protons also auto-map some appids at priority 100; user mappings use 250.
6. Mitigation, verified: a passthrough tool (`from_oslist "macos"`, `to_oslist "linux"`, script does `shift; exec "$@"`) mapped per app keeps Mac depots mounted and launches the native binary. Steam tracks the real process.
7. The Steam console's `download_depot <app> <depot>` fetches any platform's depot with no platform gate. It is the basis of the sidecar fallback.

## 3. v1 architecture

```
MacProton.app (SwiftUI menu bar)  ──uses──>  MacProtonCore (Swift package; also ships the `macproton` CLI)
                                                ├─ SteamPlay : steam_dev.cfg, tool registration, per-app mappings
                                                ├─ Sidecar   : fallback B (Windows depot download + non-Steam shortcuts)
                                                └─ Runtime   : pinned Wine download, GPTK/D3DMetal import, updates
~/Library/Application Support/MacProton/compatibilitytools.d/
   ├─ macproton/      windows → linux   launcher, Wine, D3DMetal (imported) / DXMT, lsteamclient bridge
   └─ macos-native/   macos → linux     passthrough: shift; exec "$@"
```

**Steam Play mode (sub-project 3):**
- **Enabling.** A login LaunchAgent runs `launchctl setenv STEAM_EXTRA_COMPAT_TOOLS_PATHS …` so Dock-launched Steam sees our tools. The app writes `steam_dev.cfg` into the Steam bundle.
- **Mappings.**
  - Every owned app with a `macos` build → `macos-native`, including Mac+Linux apps, which would otherwise get Linux depots.
  - Global mapping `"0"` → `macproton`, plus explicit mappings for Windows+Linux apps.
  - Mappings are refreshed from Steam's app cache before Steam starts. For games bought mid-session, users pick the tool in the game's Compatibility dropdown.
- **Steam updates.** `steam_dev.cfg` is re-checked on every Steam launch. If Steam no longer honors it (compat log shows the client is not in Linux mode), the app switches to Sidecar.
- **Mode is set-and-forget.** Turning it off unmounts Windows games, so turning it off is presented as uninstalling, with a warning.

**Build order (risk first, dependencies respected):**
1. Runtime (this spec).
2. Steam API bridge: port Proton's `lsteamclient` to macOS. It needs sub-project 1's Wine build and is the largest unknown. Cross-architecture communication (x86_64 game under Rosetta ↔ arm64 Steam) is already exercised by Intel-only Mac games.
3. Steam integration and the menu-bar app: mostly proven by the experiments.

## 4. Sub-project 1: Runtime components

Tool directory `~/Library/Application Support/MacProton/compatibilitytools.d/macproton/`:

| Item | Purpose |
|---|---|
| `compatibilitytool.vdf` | Tool `macproton`, `from_oslist "windows"`, `to_oslist "linux"`. The tool name must not contain `arm64`, because Steam ignores those names |
| `toolmanifest.vdf` | `version "2"`, `commandline "/proton %verb%"` |
| `proton` | Shell stub: `exec "$(dirname "$0")/bin/macproton" launch "$@"` |
| `bin/macproton` | arm64 Swift CLI from MacProtonCore (Apple Silicon only, so no universal binary). All launcher logic lives here, shared with the app |
| `Libraries/` | The winecx-gptk runtime tarball, unpacked: `Wine/{bin,lib}` (CrossOver 26.3 changes on Wine 11.17, x86_64, relocatable), `DXMT/{x64,x32}` (DXMT 0.80) and `DXVK/{x64,x32}` (DXVK-macOS 1.10.3). Pinned to release `runtime-v4.7.3`, SHA-256 `a4b5d63493f80698cce5cad8e7212d9a51c8292037b00c478f4652636fcfd331`, verified at install. Before the first public release we fork the pipeline to `github.com/chadouming/winecx-gptk` and publish binaries plus source (LGPL) |
| `runtime-version` | The installed pin's version; also the prefix version (§5) |
| GPTK overlay | `macproton import-gptk <volume \| redist \| redist/lib>` requires `external/{D3DMetal.framework,libd3dshared.dylib}` and `wine/x86_64-windows/{d3d10,d3d11,d3d12,dxgi}.dll`, and reads the version from the framework's `Info.plist` (`CFBundleShortVersionString`). Validation runs before anything is copied. It then keeps a pristine copy in `gptk/lib`, `ditto`s that over `Libraries/Wine/lib`, points `wine/x86_64-unix/{d3d10,d3d11,d3d12,dxgi}.so` at `../../external/libd3dshared.dylib`, and writes `gptk.json`. A runtime reinstall re-applies the overlay from `gptk/` |

D3DMetal runs only on CrossOver-derived Wine, which is why upstream Wine is not an option.

**Graphics backend.** `MACPROTON_GRAPHICS` is read from the environment and is settable per game through Steam launch options as `/usr/bin/env MACPROTON_GRAPHICS=dxmt %command%`. The `/usr/bin/env` prefix is required: macOS Steam runs launch options without a shell and treats their first word as the program to run, so the Linux-style `VAR=value %command%` fails with `OS Error 260` (verified 2026-09-27). An invalid value falls back to the default and is noted in the log.

| Value | Default when | Covers | `WINEDLLOVERRIDES` | DLLs copied into the prefix |
|---|---|---|---|---|
| `d3dmetal` | GPTK imported | D3D10/11/12 (D3D9 via Wine's builtin) | `dxgi,d3d9,d3d10,d3d10core,d3d11,d3d12=b` | none |
| `dxmt` | GPTK absent, or `d3dmetal` requested without GPTK | D3D10/11 | `dxgi,d3d10core,d3d11=n,b;d3d9,d3d10,d3d12=b` | DXMT `d3d11`, `d3d10core`, `dxgi` |
| `dxvk` | never | D3D10/11 through MoltenVK | `d3d10core,d3d11=n,b;dxgi,d3d9,d3d10,d3d12=b` | DXVK `d3d10core`, `d3d11` (the pinned DXVK-macOS ships only these and runs on Wine's own `dxgi`) |

Every backend names all six D3D DLLs, so DLLs a previous backend left in the prefix cannot leak into a launch; a runtime DLL missing at deploy time is an error, never skipped. D3D9 goes through Wine's builtin `d3d9` (wined3d) on every backend: GPTK has no d3d9 forwarder and the pinned DXVK has no `d3d9.dll`. The prefix copies go into `system32` (x64) and `syswow64` (x32). User-supplied `WINEDLLOVERRIDES` are merged by DLL name, the user winning, with no name repeated.

**Default environment:**
- `ROSETTA_ADVERTISE_AVX=1`; `MACPROTON_NO_AVX=1` opts out.
- `WINEMSYNC=1`, which the pinned build reads; `MACPROTON_NO_MSYNC=1` opts out.
- A value the user sets for any of these wins.

**Deferred** (add when users ask):
- Proton's prebuilt `default_pfx`. Without it, the first launch runs `wineboot` and takes about 20 seconds longer.
- Multiple side-by-side runtime versions. v1 ships one tool, updated in place.

## 5. Sub-project 1: Launch flow

Steam invokes `proton <verb> <exe> [args…]` with the variables listed in §2.4.

| Verb | Behaviour |
|---|---|
| `waitforexitandrun` | Prepare the prefix, then `wineserver -w` (wait for any other session in this prefix, e.g. the redistributable installers Steam starts with `run`), start Wine as a **child** process, then `wineserver -w` again so Steam sees the game running until every process in the prefix has exited (this covers launcher-then-game chains). This is Proton's order: a launch that queued on the prefix lock finds the other session's wineserver still alive. Exit with the game's exit code |
| `run` | Prepare the prefix, start Wine as a child, exit when it exits. Steam uses this for `iscriptevaluator.exe` |
| `runinprefix` | Run the given exe in the existing prefix with no prefix preparation |
| `getcompatpath` / `getnativepath` | Path conversion via `winepath` |
| other | Log it, exit 1 |

**Prefix lifecycle:**
1. The prefix is `$STEAM_COMPAT_DATA_PATH/pfx`, with `$STEAM_COMPAT_DATA_PATH/version` holding the runtime version that last prepared it.
2. If the prefix is missing, or `version` is older than the runtime, run `wineboot -u`, then write `version`.
3. A lock file (`$STEAM_COMPAT_DATA_PATH/macproton.lock`, via `flock`) is held **only during prefix preparation**, never while the game runs, so concurrent launches cannot race `wineboot` and `runinprefix` still works during a session.
4. Upgrades only touch Wine's own files. `drive_c/users` is never modified.
5. Steam deletes `compatdata/<appid>` on uninstall, so there is no `destroyprefix` verb.
6. The bridge (sub-project 2) adds its prefix setup (lsteamclient DLL, `steam.exe` stub, Steam registry keys) between preparation and launch. Sub-project 1 adds no placeholder for it.

**Environment per launch:**
- `WINEPREFIX`.
- `WINEDLLOVERRIDES` from the backend.
- `WINEDEBUG=-all`, unless logging is on.
- The defaults from §4.
- User-supplied variables from Steam launch options, passed through untouched.

Wine's x86_64 binaries run under Rosetta automatically. The `exec`-to-keep-PID trick is used only by the passthrough tool.

**Stop button.** On macOS, Steam's Stop asks the game to quit and it exits cleanly; the launcher's final `wineserver -w` then returns and it exits normally (verified 2026-09-27 with a Unity game). If the launcher itself receives SIGTERM or SIGINT, it runs `wineserver -k` for the game's prefix and exits with 128 + the signal number.

## 6. Sub-project 1: Errors and logging

Every failure is logged. Launch-blocking failures also post a macOS notification, because Steam gives no useful feedback when a compat tool fails.

| Situation | Behaviour |
|---|---|
| Rosetta missing | Notification with the install command (`softwareupdate --install-rosetta --agree-to-license`); exit 1 |
| Runtime missing or incomplete (`wine`, `wineserver` or `runtime-version` absent) | Notification "Repair it with: macproton install-runtime"; exit 1. The SHA-256 is checked at install, not on every launch |
| Runtime tarball fails its checksum, or lacks `Wine/bin/wine`/`wineserver` | Install aborts; the previously installed runtime is left untouched |
| GPTK not imported | Use DXMT; log it |
| GPTK import fails validation | Reject with a message naming the missing or unknown files. Validation runs before any copy, so nothing is half-copied |
| Prefix upgrade fails | Leave the prefix as is, log, exit 1. Never delete `drive_c` |

**Logging:**
- **Always on:** `~/Library/Logs/MacProton/launcher.log`, one line per launch (timestamp, verb, appid, backend, runtime and GPTK versions, exit code), rotated at 1 MB.
- **Opt-in per game:** `/usr/bin/env MACPROTON_LOG=1 %command%` writes `~/Library/Logs/MacProton/steam-<appid>.log` with `WINEDEBUG=+err,+warn,+loaddll` and the full launch environment. Bug reports attach this file.

## 7. Sub-project 1: Testing

- **Unit** (swift-testing, runs in CI):
  - verb parsing;
  - environment and `WINEDLLOVERRIDES` construction per backend;
  - prefix version and lock logic;
  - GPTK import validation against fixture folders (valid, missing file, unknown version).
  Wine is replaced by a fake script that records its arguments.
- **Smoke** (`make smoke`, real Wine, run on a developer Mac, not CI):
  - `exitcode.exe` prints its arguments and exits with their count, which proves arguments with spaces survive Steam → stub → launcher → Wine.
  - `d3d11probe.exe` creates a D3D11 device and a swap chain and exits 0 on success.
  Both are built with mingw-w64 from sources in `Tests/Smoke/`, and run through `macproton launch waitforexitandrun` with each backend. GitHub's macOS runners are not reliable for GPU work.
- **Acceptance** (manual, documented steps): enable Steam Play mode by hand (steam_dev.cfg, env var, mapping, as in §2), install a free Windows-only D3D11 game that does not require the Steam API, and launch it from Play with `d3dmetal` and with `dxmt`.

## 8. First plan tasks: verifications with decision rules

1. **Wine build: pinned and smoke-tested for DXMT and DXVK; D3DMetal still open.** Pinned to winecx-gptk `runtime-v4.7.3`.
   - **2026-09-27, macOS 27 on Apple Silicon:** `exitcode.exe` got both arguments intact and `d3d11probe.exe` created a D3D11 device and swap chain at feature level 11_0 through `dxmt` and through `dxvk`. The real tarball's layout matched the plan and the SHA-256 verified.
   - **`d3dmetal`: not run yet, because GPTK is not imported.** Rerun with `make smoke GPTK=<volume>`. If GPTK 3.0 fails but GPTK 4.0 beta works, support 4.0 only and require macOS 26.4.
2. **msync variable: resolved.** `WINEMSYNC` (winecx `server/msync.c`).
3. **DXMT: resolved.** DXMT 0.80 ships inside the pinned runtime.
4. **Acceptance game: open.** Pick a free, Windows-only D3D11 title on Steam whose executable does not import `steam_api64.dll`, checked by inspecting the downloaded depot's imports with `llvm-objdump -p`.

## 9. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Valve drops the `@sSteamCmdForcePlatformType` behaviour or the `steam_dev.cfg` read | Steam Play mode stops working | Detect it on every Steam launch; the Sidecar fallback (B) is part of v1 |
| A Steam update wipes `steam_dev.cfg` from the bundle | Mode silently off; Windows games unmounted | The app checks before each Steam launch and rewrites it |
| D3DMetal only runs on CrossOver-derived Wine | Tied to CodeWeavers' open-source drops | Fork the CI; DXMT fallback works on any Wine |
| Apple license changes or GPTK layout changes | Import breaks | Known-file-list validation per GPTK version, with a clear error |
| Steam API bridge infeasible | v1 goal unmet | Sub-project 2 comes right after the runtime, so a failure surfaces early |
| Rosetta 2 largely discontinued in macOS 28 (per winecx-gptk's README); D3DMetal ships x86_64 only | The whole x86_64 runtime, and every Rosetta-based Wine on the Mac, stops working unless Apple keeps Rosetta for games | Out of our hands. Track Apple's Rosetta policy for games. The successor path is an arm64 Wine running x86 code under FEX, which needs the `com.apple.developer.cross-architecture-support` entitlement that Apple grants at its discretion |
