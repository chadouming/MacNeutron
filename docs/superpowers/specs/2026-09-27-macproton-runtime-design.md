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
| `bin/macproton` | Universal Swift CLI from MacProtonCore. All launcher logic lives here, shared with the app |
| `wine/` | CrossOver-derived Wine (CrossOver 26.x changes on Wine 11.x), x86_64, relocatable. Built by our fork of the winecx-gptk GitHub Actions pipeline. Releases publish binaries plus source (LGPL). Pinned by version and SHA-256 |
| GPTK overlay | "Import GPTK" takes the mounted GPTK image: it validates `redist/lib/external` and `redist/lib/wine/{x86_64-unix,x86_64-windows}` against a known file list for supported GPTK versions, copies them over `wine/lib`, and records the GPTK version in `gptk.json`. Re-import overwrites; a Wine update re-applies the overlay from a kept copy under `gptk/` |
| `dxmt/` | Bundled DXMT (open source, D3D10/11), used when GPTK is not imported |

D3DMetal runs only on CrossOver-derived Wine, which is why upstream Wine is not an option.

**Graphics backend.** `MACPROTON_GRAPHICS` is read from the environment and is settable per game through Steam launch options, e.g. `MACPROTON_GRAPHICS=dxmt %command%`:

| Value | Default when | Covers | Overrides |
|---|---|---|---|
| `d3dmetal` | GPTK imported | D3D11, D3D12 | `dxgi,d3d11,d3d12,d3d10core` → GPTK's builtins |
| `dxmt` | GPTK absent | D3D10, D3D11 | `dxgi,d3d11,d3d10core` → DXMT (native) |
| `wined3d` | never | last resort; D3D9 path | Wine's own builtins |

**Default environment** (each has a `MACPROTON_NO_*` opt-out):
- `ROSETTA_ADVERTISE_AVX=1`.
- Wine msync enabled, using whatever variable the pinned build expects.

**Deferred** (add when users ask):
- Proton's prebuilt `default_pfx`. Without it, the first launch runs `wineboot` and takes about 20 seconds longer.
- Multiple side-by-side runtime versions. v1 ships one tool, updated in place.

## 5. Sub-project 1: Launch flow

Steam invokes `proton <verb> <exe> [args…]` with the variables listed in §2.4.

| Verb | Behaviour |
|---|---|
| `waitforexitandrun` | `wineserver -w` (wait for any prior session in this prefix, e.g. the redistributable installer), prepare the prefix, start Wine as a **child** process, then `wineserver -w` again so Steam sees the game running until every process in the prefix has exited (this covers launcher-then-game chains). Exit with the game's exit code |
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

## 6. Sub-project 1: Errors and logging

Every failure is logged. Launch-blocking failures also post a macOS notification, because Steam gives no useful feedback when a compat tool fails.

| Situation | Behaviour |
|---|---|
| Rosetta missing | Notification with the install command (`softwareupdate --install-rosetta --agree-to-license`); exit 1 |
| Wine missing or checksum mismatch | Notification "Repair runtime in MacProton"; exit 1 |
| GPTK not imported | Use DXMT; log it |
| GPTK import fails validation | Reject with a message naming the missing or unknown files. Validation runs before any copy, so nothing is half-copied |
| Prefix upgrade fails | Leave the prefix as is, log, exit 1. Never delete `drive_c` |

**Logging:**
- **Always on:** `~/Library/Logs/MacProton/launcher.log`, one line per launch (timestamp, verb, appid, backend, runtime and GPTK versions, exit code), rotated at 1 MB.
- **Opt-in per game:** `MACPROTON_LOG=1 %command%` writes `~/Library/Logs/MacProton/steam-<appid>.log` with `WINEDEBUG=+err,+warn,+loaddll` and the full launch environment. Bug reports attach this file.

## 7. Sub-project 1: Testing

- **Unit** (swift-testing, runs in CI):
  - verb parsing;
  - environment and `WINEDLLOVERRIDES` construction per backend;
  - prefix version and lock logic;
  - GPTK import validation against fixture folders (valid, missing file, unknown version).
  Wine is replaced by a fake script that records its arguments.
- **Smoke** (`make smoke`, real Wine, run on a developer Mac, not CI):
  - `exitcode.exe` is a console program that returns 0.
  - `d3d11probe.exe` creates a D3D11 device and a swap chain and exits 0 on success.
  Both are built with mingw-w64 from sources in `tests/smoke/`, and run through `macproton launch waitforexitandrun` with each backend. GitHub's macOS runners are not reliable for GPU work.
- **Acceptance** (manual, documented steps): enable Steam Play mode by hand (steam_dev.cfg, env var, mapping, as in §2), install a free Windows-only D3D11 game that does not require the Steam API, and launch it from Play with `d3dmetal` and with `dxmt`.

## 8. First plan tasks: verifications with decision rules

1. **Pin the Wine build.** Fork winecx-gptk. Confirm its current release runs `exitcode.exe` on macOS 26/27 and that GPTK 3.0's overlay creates a D3D11 device with `d3d11probe.exe`.
   - If GPTK 3.0 fails but GPTK 4.0 beta works, support 4.0 only and require macOS 26.4.
2. **msync variable.** Find the name the pinned build honors (check its source for `MSYNC`). If it has none, drop the default.
3. **DXMT.** Build or pin a DXMT release compatible with the pinned Wine, and confirm `d3d11probe.exe` passes with `MACPROTON_GRAPHICS=dxmt`.
4. **Acceptance game.** Pick a free, Windows-only D3D11 title on Steam whose executable does not import `steam_api64.dll`, checked by inspecting the downloaded depot's imports with `llvm-objdump -p`.

## 9. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Valve drops the `@sSteamCmdForcePlatformType` behaviour or the `steam_dev.cfg` read | Steam Play mode stops working | Detect it on every Steam launch; the Sidecar fallback (B) is part of v1 |
| A Steam update wipes `steam_dev.cfg` from the bundle | Mode silently off; Windows games unmounted | The app checks before each Steam launch and rewrites it |
| D3DMetal only runs on CrossOver-derived Wine | Tied to CodeWeavers' open-source drops | Fork the CI; DXMT fallback works on any Wine |
| Apple license changes or GPTK layout changes | Import breaks | Known-file-list validation per GPTK version, with a clear error |
| Steam API bridge infeasible | v1 goal unmet | Sub-project 2 comes right after the runtime, so a failure surfaces early |
