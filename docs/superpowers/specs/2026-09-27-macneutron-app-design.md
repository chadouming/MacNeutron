# MacNeutron — Sub-project 3a: Menu-bar App and Steam Play Mode Manager

- **Date:** 2026-09-27
- **Status:** Draft for review
- **Builds on:** `2026-09-27-macproton-runtime-design.md` (overall architecture, runtime, and the verified Steam behaviour in its §2).
- **Scope:**
  - **In:** the MacNeutron rename; a SwiftUI menu-bar app with first-run setup; safe management of Steam Play mode; automatic protection of Mac games; per-game settings; cleanup of orphaned prefixes.
  - **Out:** the sidecar fallback (sub-project 3b); the Steam API bridge (sub-project 2); Developer ID signing and notarization; MetalFX/NVAPI enablement.

## 1. Goal

A user installs MacNeutron.app, walks through a three-step setup window, and from then on plays Windows games from native macOS Steam's Play button. Their Mac games keep working natively, and the app keeps Steam's configuration correct without the user ever editing a file.

**Done when** the acceptance run in §9 passes on a Mac with at least one installed Mac-only game.

### Decisions made during brainstorming

| Decision | Choice |
|---|---|
| Product name | **MacNeutron** (avoids Valve's "Proton" trademark); the rename is the first task |
| First run | Guided setup window, then the app lives in the menu bar |
| Per-game settings | In the app (graphics backend, logging, AVX, msync, "Runs as") |
| Routing | Automatic. Games with a Mac build run natively; everything else runs through MacNeutron; a dual-platform game can be switched to its Windows version |
| How Steam finds the tools | **Approach B:** tool symlinks in Steam's bundle `compatibilitytools.d/`, next to `steam_dev.cfg`. Verified in plan task 1; if that fails, fall back to **C** (a LaunchAgent running `launchctl setenv` at login) |

## 2. Rename

MacProton → MacNeutron everywhere. Nothing has shipped, so there is no compatibility layer.

| Old | New |
|---|---|
| Package `MacProton`, module `MacProtonCore`, CLI `macproton` | `MacNeutron`, `MacNeutronCore`, `macneutron` |
| Steam tool `macproton` (display "MacProton") | `macneutron` (display "MacNeutron") |
| — (new) | Passthrough tool `macneutron-native` (display "macOS native") |
| `~/Library/Application Support/MacProton/…` | `~/Library/Application Support/MacNeutron/…` |
| `~/Library/Logs/MacProton`, `~/Library/Caches/MacProton` | `…/MacNeutron` |
| `MACPROTON_GRAPHICS`, `_LOG`, `_NO_AVX`, `_NO_MSYNC` | `MACNEUTRON_*` |

The existing install on the developer's Mac is migrated by hand once: move the folder and reinstall the runtime. No migration code ships.

## 3. Architecture

```
MacNeutron.app (SwiftUI; SwiftPM executable target, assembled by `make app`)
 ├─ MenuBarExtra ─┐
 ├─ SetupWindow ──┼── AppModel (@Observable, @MainActor) ── NSWorkspace launch/quit observer for Steam
 ├─ GamesWindow ──┤         │
 ├─ Settings ─────┘         ▼
 └─ Contents/Helpers/macneutron   MacNeutronCore (Swift package, no UI, unit-tested)
```

New units in `MacNeutronCore`:

| Unit | Responsibility | Depends on |
|---|---|---|
| `SteamLocation` | Steam root (`~/Library/Application Support/Steam`), `bundleMacOS` (`Steam.AppBundle/Steam/Contents/MacOS`), library folders from `steamapps/libraryfolders.vdf`, `compat_log.txt`, `config/config.vdf` | `KeyValues` |
| `KeyValues` | Parse and serialize Valve's text VDF. Unrelated keys are preserved; only the requested subtree is replaced; output uses Steam's tab style | — |
| `AppInfoReader` | Read binary `appcache/appinfo.vdf` **v29** (magic `0x07564429`, string table). Returns `[AppInfo(appID, name, type, oslist)]`. Any other magic throws `unsupportedFormat` | — |
| `MappingPlanner` | Pure function: `(apps, overrides) → [appID: ToolMapping]` (§5) | — |
| `SteamPlayMode` | `status()`, `enable(plan)`, `disable()`, `applyMappings(plan)`, `verifyAfterLaunch()`. Owns the write order and rollback (§4) | `SteamLocation`, `KeyValues`, `ToolLayout`, `SteamProcess` |
| `SteamProcess` | `isRunning`, `quit()` (`open steam://exit`, then wait for `steam_osx` to exit with a timeout), `launch()` | — |
| `GameSettings` | Read and write `games/<appid>.json` atomically; `environment(for:)` for the launcher (§7) | — |
| `OrphanPrefixes` | `compatdata/<appid>` folders with no `appmanifest_<appid>.acf` in any library, with their sizes; `delete(_:)` | `SteamLocation` |

The existing units (`Launcher`, `RuntimeInstaller`, `GPTKImporter`, …) are renamed and otherwise unchanged, apart from the `GameSettings` hook in `Launcher` (§7).

**App bundle.** Built without an Xcode project: the SwiftPM executable target `MacNeutronApp` is assembled by `make app` into `build/MacNeutron.app` with `App/Info.plist`, so there is no project file to maintain. Bundle identifier `io.github.chadouming.MacNeutron`; `LSUIElement = YES` (menu-bar app, no Dock icon). `MacNeutron.app` embeds the release `macneutron` CLI in `Contents/Helpers/`. Setup and "Repair runtime" call `RuntimeInstaller` in-process, passing that path as `launcherBinary`, so the tool folder receives the same binary. The bundle is signed ad-hoc; Developer ID signing and notarization are a release task, out of scope here.

## 4. Steam Play mode lifecycle

Paths: `B = SteamLocation.bundleMacOS`; `T = ~/Library/Application Support/MacNeutron/compatibilitytools.d`.

**Enable** (setup step 3):
1. **Preconditions.** The runtime is installed (`ToolLayout.runtimeVersion` is not nil) and Rosetta is present. `AppInfoReader` succeeds; otherwise refuse, because Mac games cannot be protected without it.
2. **Plan and preview.** `MappingPlanner` produces the plan. The UI lists the games that "stay native" and those that "run with MacNeutron", installed games first.
3. **Quit Steam** after asking the user, via `SteamProcess.quit()`. If the user declines, stop with nothing changed.
4. **Back up** `config/config.vdf` to `~/Library/Application Support/MacNeutron/backups/config-<ISO8601>.vdf`, keeping the newest 10.
5. **Write, in this order:**
   1. install `T/macneutron-native`: `compatibilitytool.vdf`, `toolmanifest.vdf`, and `passthrough.sh`. The script resolves an `.app` target to its `CFBundleExecutable` and execs through `arch -arm64e -arm64 -x86_64`, because Steam starts tools preferring x86_64. The app rewrites it at every launch;
   2. symlink `B/compatibilitytools.d/macneutron` → `T/macneutron` and `B/compatibilitytools.d/macneutron-native` → `T/macneutron-native`;
   3. `applyMappings(plan)`;
   4. **`B/steam_dev.cfg` last**, containing `@sSteamCmdForcePlatformType linux`.
6. **Launch Steam and verify.** Wait up to 60 s for new lines in `compat_log.txt` showing `Registering tool macneutron` and `Registering tool macneutron-native`, no `Ignoring tool macneutron`, and at least one `Recording non-user mapping`, which proves Linux mode.
   - **On failure:** delete `steam_dev.cfg` first, quit Steam, remove the symlinks, restore the backup, relaunch Steam, and report which check failed.

**Steady state** (the `AppModel` observer):
- **`steam_osx` terminates:** re-run `MappingPlanner`. If the plan differs from what is in `config.vdf`, back up and `applyMappings`. Clear "restart needed".
- **`steam_osx` launches:** after 20 s, `verifyAfterLaunch()`. If `steam_dev.cfg` or a symlink is missing, or the log shows Mac mode, set status **lost** (red icon) and offer Restore, which repeats enable steps 3–6. The menu says that Windows games may need re-downloading.
- **A per-game "Runs as" change while Steam is running:** set "restart needed" (amber icon). The menu shows "Restart Steam to apply N changes".
- **Games bought while Steam is running:** each time the menu opens, the app re-reads `appinfo.vdf` (about 1 MB) and re-runs the planner. Any app whose planned mapping is not yet in `config.vdf` also counts toward "restart needed". Known limitation: a dual-platform or Mac+Linux game installed before that restart may download the wrong platform's files. The menu note says so.

**Disable** (Settings → Turn off Steam Play mode):
1. Confirm with: "Windows games will be removed from disk and need downloading again if you turn this back on. Saves inside their prefixes are kept."
2. Quit Steam.
3. Delete `steam_dev.cfg` **first**, then the symlinks.
4. Remove the MacNeutron entries from `CompatToolMapping`, after a backup.
5. Relaunch Steam.

**Cleanup:** "Free up space" lists `OrphanPrefixes` with their sizes. The user ticks entries and confirms; only the ticked folders are deleted.

## 5. Mapping rules (`MappingPlanner`)

Inputs:
- the apps from `appinfo.vdf`, restricted to `type` ∈ {`game`, `demo`, `application`}, so that tools such as Steam Linux Runtime or Proton are never mapped;
- per-game `runAs` overrides.

| App's oslist | Default mapping | With `runAs = windows` |
|---|---|---|
| contains `macos` | `macneutron-native` | `macneutron` (only if it also contains `windows`) |
| `windows` (with or without `linux`), no `macos` | `macneutron` | — |
| none of `windows` or `macos` | none | — |
| global entry `"0"` | `macneutron` | — |

- **Priorities:** per-app mappings use `250` and `"0"` uses `75`. Valve's own automatic mappings use 100, so explicit per-app entries always win.
- **Why Windows-only apps get explicit entries** (not just `"0"`): Valve maps some appids to its Linux Protons at priority 100, which beats `"0"`.
- **`applyMappings`** replaces only the entries whose tool name starts with `macneutron`. Any entry naming another tool is left alone. Apps claimed by another tool are also left out of "restart needed" counts. A game switched in Steam's own Compatibility dropdown to one of MacNeutron's tools is overwritten by the plan at the next sync; the Games window's "Runs as" is the supported control.

## 6. UI

Mockups were reviewed in brainstorming. Every visible string uses sentence case with no trailing punctuation on labels.

**Setup window** (shown on first launch and via "Run setup again"):
1. **Install runtime:** a progress bar during download, checksum and extract. "Repair runtime" appears when the runtime is already installed but broken.
2. **Import Game Porting Toolkit (optional):**
   - The user drops the GPTK `.dmg` or picks it with a file dialog.
   - The app mounts it read-only with `hdiutil attach -nobrowse -readonly`, finds the nested "Evaluation environment" image and mounts it too, runs `GPTKImporter`, then unmounts both.
   - If a disk image shows a license agreement, the app does not accept it; it tells the user to open the image in Finder once.
3. **Turn on Steam Play mode:** the preview lists and "Turn on and restart Steam" (§4).

**Menu-bar extra:**
- **Status line:** "Steam Play mode on" in green, "Restart Steam to apply N changes" in amber, or "Steam Play mode was turned off by a Steam update" with Restore in red. Underneath: the runtime and D3DMetal versions.
- **Items:** Games…, Open Steam, Free up space (size), Show logs (opens `~/Library/Logs/MacNeutron`), Settings…, Quit MacNeutron.

**Games window:**
- **Contents:** a searchable list, installed games first, with columns Game, Runs as and Graphics.
  - The "Runs as" picker appears only for games with both `macos` and `windows` in their oslist.
  - The Graphics picker (Default, D3DMetal, DXMT, DXVK) appears for games that run through MacNeutron. DXVK stays selectable while GPTK is imported, with the note "Falls back to D3DMetal while GPTK is imported".
- **Toggles for the selected game:** Log, AVX and msync.
- **Saving:** each change is written immediately with `GameSettings`. A "Runs as" change marks "restart needed".

**Settings:** launch at login (`SMAppService.mainApp`), Repair runtime, Run setup again, Turn off Steam Play mode.

## 7. Per-game settings

**File:** `~/Library/Application Support/MacNeutron/games/<appid>.json`:

```json
{ "graphics": "dxmt", "log": false, "avx": true, "msync": true, "runAs": "windows" }
```

- Every key is optional; a missing file means defaults.
- Writes go to a temporary file, then `rename`, so readers never see a partial file.

**Launcher hook:** at the start of `Launcher.launch`, once the app ID is known, merge `GameSettings.environment(for: appID)` underneath the incoming environment. Keys already set, for example from Steam launch options, win.

| File value | Environment produced |
|---|---|
| `graphics` | `MACNEUTRON_GRAPHICS` |
| `log: true` | `MACNEUTRON_LOG=1` |
| `avx: false` | `MACNEUTRON_NO_AVX=1` |
| `msync: false` | `MACNEUTRON_NO_MSYNC=1` |

- `runAs` produces nothing here; only the planner reads it.
- An unreadable file is logged to `launcher.log` and ignored.

## 8. Errors and safety

| Situation | Behaviour |
|---|---|
| `config.vdf` fails to parse | Do not write; show "Steam's settings file couldn't be read. MacNeutron didn't change it." |
| Any `config.vdf` write | Back up → edit only `CompatToolMapping` → serialize → re-parse the output and compare → write atomically |
| Steam is running when a write is needed | Never write; queue it and show "restart needed" |
| `appinfo.vdf` magic is not v29 | Refuse to enable; say which version was found |
| Enable verification fails | Roll back in the order given in §4 |
| Steam update removes `steam_dev.cfg` or the symlinks | "Lost" status and Restore (§4) |
| Runtime download or GPTK import fails | Alert showing the existing `description` text of the error |

**Invariant:** `steam_dev.cfg` is never present unless both tools resolve through `B/compatibilitytools.d` **and** every installed app with `macos` in its oslist has a mapping. Enable, Restore and Disable are ordered to preserve it.

## 9. Testing

**Unit tests** (swift-testing, run in CI):
- `KeyValues`: round-trips a Steam-shaped `config.vdf` fixture byte for byte; edits `CompatToolMapping` without touching other keys; handles escaped quotes and nested blocks.
- `AppInfoReader`: a synthetic v29 fixture built by a test-support writer (header, string table, two apps with nested `common.oslist`); an unknown magic throws.
- `MappingPlanner`: a table test covering Mac-only, Windows-only, Mac+Windows, Mac+Linux, Windows+Linux, all three, Linux-only, tool-type apps, and `runAs` overrides.
- `SteamPlayMode`: runs against a temporary fake Steam folder with a fake `SteamProcess`. Checks that `steam_dev.cfg` is written last and removed first on rollback and disable; that a backup exists before every write; and that verification parses `compat_log.txt` fixtures correctly for success, "Ignoring tool" and Mac mode.
- `GameSettings` and the `Launcher` hook: launch-option variables win over the file; a corrupt file is ignored and logged.
- `OrphanPrefixes`: compatdata folders without manifests are listed with sizes; installed ones are never listed.
- `AppModel`: status transitions (on, restart needed, lost) driven by fake observers.

**Developer-only test** (skipped unless `MACNEUTRON_REAL_STEAM=1`): parse the real `appinfo.vdf` read-only and assert that it contains Timberborn (1062090) with `windows,macos`.

**Manual acceptance** on the developer's Mac, with Timberborn installed and GPTK imported: *(2026-09-27: steps 1–5 pass. Steps 3–4 were done with SMITE 2 and Bongo Cat. Step 6 was skipped so the user's Windows games stay installed. See `docs/testing/acceptance-app.md`.)*
1. Setup runs end to end.
2. Timberborn stays installed with no redownload and launches natively.
3. "Cats" installs and plays on D3DMetal.
4. Changing Cats's graphics setting to DXMT takes effect on the next launch.
5. A "Runs as" change for a dual-platform game shows "restart needed" and applies after the restart.
6. Turning Steam Play mode off restores Mac mode with Timberborn intact.

## 10. First plan tasks: verifications with decision rules

1. **Approach B probe.**
   - **Verified 2026-09-27:** with no environment variable set anywhere, Steam registered a tool symlinked into `Steam.AppBundle/Steam/Contents/MacOS/compatibilitytools.d` ("Processing local tool list at …/Contents/MacOS/compatibilitytools.d/macneutron-probe/…", then "Registering tool macneutron-probe") in Linux mode. **B is kept.**
   - Test: with no environment variable set, place a probe tool at `B/compatibilitytools.d/<probe>` (a symlink to a folder outside the bundle), start Steam in Linux mode (Timberborn's manifest hidden), and check `compat_log.txt` for `Registering tool <probe>`.
   - **If it registers:** keep B.
   - **If not:** switch §4 step 5.2 to C, `~/Library/LaunchAgents/io.github.chadouming.macneutron.env.plist` running `launchctl setenv STEAM_EXTRA_COMPAT_TOOLS_PATHS` at load. Record the result in this spec.
2. **appinfo v29 layout.** Parse the real file with the prototype reader. Confirm that `common/oslist` and `common/type` are where the planner expects them, and count the mappable apps. If more than 5,000, restrict the planner to installed apps plus apps listed in `localconfig.vdf`, and record that here.
   - **Resolved 2026-09-27:** magic `0x07564429` (v29). `common/type` and `common/oslist` are where the planner expects them (Timberborn: `game`, `windows,macos`). Of 517 apps, 117 are mappable, so no restriction is needed.

## 11. Risks

| Risk | Mitigation |
|---|---|
| A Steam update wipes files in its bundle | Detected at the next Steam launch; red status with Restore; Windows-game redownloads are unavoidable and stated in the UI |
| Valve changes `appinfo.vdf` format again | Fails closed: enable is refused rather than risking Mac games |
| A future Steam no longer scans bundle `compatibilitytools.d` | Plan task 1 establishes today's behaviour; fallback C is designed |
| `config.vdf` corruption | Backups before every write, re-parse check, atomic replace |
| Many mappings slow Steam's startup | Measured in task 2; restrict the planner if needed |
