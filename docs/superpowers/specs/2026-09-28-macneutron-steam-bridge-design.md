# MacNeutron — Sub-project 2: Steam API Bridge

- **Date:** 2026-09-28
- **Status:** Draft for review
- **Builds on:** `2026-09-27-macproton-runtime-design.md` (architecture, runtime, launcher) and `2026-09-27-macneutron-app-design.md` (app, Steam Play mode).
- **Scope:**
  - **In:** a macOS port of Proton's `lsteamclient`; our own `steam.exe` stand-in; `make bridge`; bundling the bridge in the app and installing it into the runtime; launcher and prefix integration; a developer probe; acceptance.
  - **Out:** the Steam overlay; Easy Anti-Cheat and other anti-cheat runtimes; VR (`vrclient`); building releases in CI; choosing the repo's own license (see §11).

## 1. Goal

A Windows game started from native macOS Steam through MacNeutron can use the Steam API: `SteamAPI_Init` succeeds, and ownership/DRM checks, achievements, cloud saves, inventory and auth session tickets reach the user's running Mac Steam client. Games stop reporting "Steam unavailable".

**Done when** the acceptance run in §9 passes. This completes the v1 goal in the runtime spec: "a Windows-only Steam game that uses the Steam API (DRM, achievements) installs and launches from native macOS Steam's Play button".

### Decisions made during brainstorming

| Decision | Choice |
|---|---|
| Distribution | Fetch Proton's source at build time; never commit `lsteamclient` source; ship the built binaries with Valve's license file, as GE-Proton and other Proton forks do |
| Build approach | **A:** build `lsteamclient` with Wine's own build rules inside the exact Wine source tree of our runtime (rejected: a standalone Makefile; the Windows Steam client inside the prefix) |
| "Steam is running" | Our own `steam.exe` (open source, not Proton's `steam_helper`) |
| Shipping | Bundled inside `MacNeutron.app`, installed into the runtime by the app; no separate download |
| 32-bit games | Included if the WoW64 build works in plan task 1; otherwise 64-bit only, recorded |
| Escape hatch | `MACNEUTRON_NO_STEAM_BRIDGE=1` in a game's launch options starts the game directly |

## 2. Evidence (verified 2026-09-28)

1. macOS Steam's `Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib` is universal (`x86_64 arm64`), and so are its dependencies `libtier0_s.dylib`, `libvstdlib_s.dylib` and `libaudio.dylib`. Our x86_64 Wine (under Rosetta) can load it.
2. Its x86_64 slice exports `CreateInterface`, `Steam_BGetCallback`, `Steam_GetAPICallResult`, `Steam_FreeLastCallback`, `Steam_ReleaseThreadLocalMemory` and the other `Steam_*` entry points, but **not** `Steam_IsKnownInterface` or `Steam_NotifyMissingInterface` (absent from exports and strings).
3. Proton `proton_11.0` (`5b89db940e0ebe3a137a6009a3589232fe084c09`) `lsteamclient/unixlib.cpp` already has an `#ifdef __APPLE__` path that loads `$STEAM_COMPAT_CLIENT_INSTALL_PATH/steamclient.dylib`. It then requires all seven functions above, including the two macOS lacks, and fails without them.
4. `lsteamclient/LICENSE` is the Steamworks SDK license (the folder contains generated code and SDK headers). Proton's other directories carry their own licenses.
5. The runtime `runtime-v4.7.3` was built from `dappermint/winecx` commit `e0aa380780b73e20fabcfe78fd42713b94929a53` (public, LGPL). Its `lib/wine` has `x86_64-unix`, `x86_64-windows` and `i386-windows`, so WoW64 32-bit code exists.
6. SMITE 2 ships `Engine/Binaries/ThirdParty/Steamworks/Steamv157/Win64/steam_api64.dll` (SDK 1.57: `SteamClient017`, `SteamUser021`, `STEAMAPPS_INTERFACE_VERSION008`) and reports "Steam unavailable" under the current runtime.
7. Mac Steam sets `STEAM_COMPAT_CLIENT_INSTALL_PATH` for compat tools (runtime spec §2); its value on macOS has not been recorded.

## 3. Architecture

```
Mac Steam (Linux mode) ──Play──▶ macneutron launcher (Swift)
                                    │  STEAM_COMPAT_CLIENT_INSTALL_PATH → folder containing steamclient.dylib
                                    │  MACNEUTRON_STEAM_ACCOUNT ← account ID from Steam's loginusers.vdf
                                    ▼
                                 wine "C:\Program Files (x86)\Steam\steam.exe" <game.exe> <args>
                                    │  writes HKCU\Software\Valve\Steam (ActiveProcess pid, client DLL paths, user)
                                    │  starts the game, waits, clears pid
                                    ▼
game.exe ─▶ its own steam_api64.dll ─▶ steamclient64.dll  (= lsteamclient.dll, Windows side)
                                          │ Wine unixlib call
                                          ▼
                                       lsteamclient.so  (Mac x86_64, under Rosetta)
                                          │ dlopen
                                          ▼
                                       Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib (Valve's x86_64 slice)
                                          │ Steam's own local IPC
                                          ▼
                                       running Mac Steam client (arm64)
```

Only `run` and `waitforexitandrun` go through `steam.exe`, as in Proton. `runinprefix`, `getcompatpath` and `getnativepath` are unchanged.

## 4. Components

### 4.1 `lsteamclient` (Proton's, patched)

Fetched at the pinned Proton commit (§5). Our changes live in `bridge/patches/*.patch`, applied in order:

1. **Optional interface checks.** `Steam_IsKnownInterface` and `Steam_NotifyMissingInterface` are loaded with `dlsym` but are no longer required. When missing, `Steam_IsKnownInterface` returns 1 (known; `CreateInterface` decides) and `Steam_NotifyMissingInterface` does nothing.
2. **macOS build fixes** found while building in plan task 1, each its own patch with a one-line reason at the top.

Proton's generated thunks are used unchanged: macOS and Linux x86_64 share the SysV calling convention, the Itanium C++ ABI and the SDK's `VALVE_CALLBACK_PACK_SMALL` struct packing. Plan task 1 verifies this with the probe (§4.3).

### 4.2 `steam.exe` (ours)

`bridge/steam.c`, built with llvm-mingw as an x86_64 Windows console program (Wine opens no window for it), installed as `C:\Program Files (x86)\Steam\steam.exe`.

- **Usage:** `steam.exe <program> [args…]`.
- **Registry:** under `HKCU\Software\Valve\Steam`:
  - `SteamPath` = `C:\Program Files (x86)\Steam`;
  - `SteamExe` = `C:\Program Files (x86)\Steam\steam.exe`;
  - `ActiveProcess\pid` = its own process ID;
  - `ActiveProcess\SteamClientDll64` = `C:\Program Files (x86)\Steam\steamclient64.dll`;
  - `ActiveProcess\SteamClientDll` = `C:\Program Files (x86)\Steam\steamclient.dll`, written only when that file exists;
  - `ActiveProcess\ActiveUser` = `MACNEUTRON_STEAM_ACCOUNT`, when it is set.
- **Process:** starts `<program>` with its arguments quoted by the Windows rules and the current directory unchanged, waits for it, sets `ActiveProcess\pid` to 0, and exits with the program's exit code. If `<program>` can't be started, it prints the Windows error to stderr and exits 1.

### 4.3 `steamprobe.exe` (developer only, never shipped)

`bridge/probe.c`, built by `make bridge` into `build/bridge/probe/`. Run as `steam.exe steamprobe.exe <path-to-steam_api64.dll>` inside a MacNeutron prefix with `SteamAppId=480` (Valve's public test app). It uses only the flat C exports of `steam_api64.dll`, looked up with `GetProcAddress`, so no SDK headers are needed. It prints:

1. `SteamAPI_Init` result;
2. the SteamID from `SteamAPI_ISteamUser_GetSteamID`;
3. the persona name from `SteamAPI_ISteamFriends_GetPersonaName`;
4. whether a `GetAuthSessionTicketResponse_t` callback arrives within 10 s of `SteamAPI_ISteamUser_GetAuthSessionTicket`, pumping `SteamAPI_RunCallbacks`.

The accessor names (`SteamAPI_SteamUser_v0NN` and so on) are taken from the target DLL's exports.

## 5. Build: `make bridge`

`bridge/pins` records every input:

| Input | Pin | Size |
|---|---|---|
| Proton | `ValveSoftware/Proton` `5b89db940e0ebe3a137a6009a3589232fe084c09` (`proton_11.0`), sparse checkout of `lsteamclient/` only | 60 MB, 3,133 files |
| Wine | `dappermint/winecx` `e0aa380780b73e20fabcfe78fd42713b94929a53`, commit tarball | about 50 MB compressed |
| Cross compiler | `llvm-mingw-20260922-ucrt-macos-universal.tar.xz`, with SHA-256 | 118 MB |

Steps (`bridge/build.sh`):

1. **Fetch** each input into `build/bridge-src/` if absent, verifying tarball SHA-256s and the checked-out commit.
2. **Patch** a fresh copy of `lsteamclient/` with `bridge/patches/`.
3. **Configure** winecx for macOS x86_64 with `--enable-archs=i386,x86_64` and llvm-mingw for the PE side. Build only Wine's tools and the import libraries `lsteamclient` links against. Host prerequisites: Xcode command-line tools and Homebrew `bison` and `flex`; the script checks for them and names what's missing.
4. **Build** `lsteamclient` with Wine's `makedep` rules, as Proton does, then `steam.exe` and `steamprobe.exe` with llvm-mingw.
5. **Stage** into `build/bridge/`:
   - `x86_64-unix/lsteamclient.so`;
   - `x86_64-windows/lsteamclient.dll`;
   - `i386-windows/lsteamclient.dll`, when the WoW64 build works;
   - `steam.exe`;
   - `LICENSE.lsteamclient`, copied from Proton;
   - `NOTICE`, saying these binaries are built from Proton under the Steamworks SDK license;
   - `bridge-version`: `<proton short sha>-<first 8 hex of SHA-256 over bridge/patches/* and bridge/steam.c>`.
6. **Check** with `bridge/check.sh`: every staged file exists; `file` reports PE32+ (and PE32 for i386) for the DLLs and `steam.exe` and Mach-O x86_64 for `lsteamclient.so`; `lsteamclient.dll` exports `CreateInterface`, `Steam_BGetCallback`, `Steam_GetAPICallResult`, `Steam_FreeLastCallback`, `Steam_ReleaseThreadLocalMemory`, `Steam_IsKnownInterface` and `Steam_NotifyMissingInterface`.

The first build is expected to take 10–20 minutes; later builds reuse `build/bridge-src/`. `build/` stays git-ignored.

## 6. Shipping and installation

- **App bundle.** `make app` copies `build/bridge/` (except `probe/`) into `MacNeutron.app/Contents/Resources/Bridge/` when it exists. An app built without it runs games as today, and Setup shows "Steam bridge not included in this build".
- **Runtime.** `ToolLayout` gains `bridgeVersionFile` (`<root>/bridge-version`) and the three install locations under `wineLib/wine/`. `BridgeInstaller.install(from:layout:)` copies the files into the runtime's `x86_64-unix/`, `x86_64-windows/` (and `i386-windows/`), then `steam.exe` next to them in `x86_64-windows/`, then writes `bridge-version` last. It runs after every runtime install and at app start when the bundled version differs from the installed one.
- **Prefix.** `PrefixManager.prepare` copies `lsteamclient.dll` to `C:\Program Files (x86)\Steam\steamclient64.dll` (and the i386 build to `steamclient.dll`) and `steam.exe` to `C:\Program Files (x86)\Steam\steam.exe`. It records the bridge version in `<compatdata>/macneutron-bridge-version` and copies again only when it differs. A runtime without the bridge removes nothing and records nothing.

## 7. Launcher integration

- **Command.** When the runtime's bridge is installed and `MACNEUTRON_NO_STEAM_BRIDGE` isn't `1`, `run` and `waitforexitandrun` execute `wine "C:\Program Files (x86)\Steam\steam.exe" <target> <args…>`; otherwise `wine <target> <args…>` as today.
- **Steam's client path.** `LaunchEnvironment` sets `STEAM_COMPAT_CLIENT_INSTALL_PATH` to `SteamLocation`'s `Steam.AppBundle/Steam/Contents/MacOS` folder when Steam's value doesn't contain `steamclient.dylib`, and leaves it alone when it does. Either way the launcher log records the value used and whether the file exists.
- **Account.** `SteamLocation.activeAccountID()` reads `<steam root>/config/loginusers.vdf` with `KeyValues`, takes the user with `MostRecent` `1`, and returns the SteamID64's low 32 bits. The launcher sets `MACNEUTRON_STEAM_ACCOUNT` to it when found.
- **Logging.** `MACNEUTRON_LOG=1` adds `+steamclient` to `WINEDEBUG`.

## 8. Errors

| Condition | Behavior |
|---|---|
| Runtime has no bridge | Game starts directly; launcher log: `note: Steam bridge not installed` |
| `MACNEUTRON_NO_STEAM_BRIDGE=1` | Game starts directly; launcher log: `note: Steam bridge disabled by launch option` |
| `steamclient.dylib` missing at the path used | Launcher log names the path; the game still starts (its own "Steam unavailable" follows) |
| No readable `loginusers.vdf` or no `MostRecent` user | `ActiveUser` not written; launcher log notes it |
| Game crashes | `steam.exe` still clears `ActiveProcess\pid`; its exit code passes through |
| `steam.exe` killed | Stale pid is overwritten at the next launch |
| Copying bridge files into a prefix fails | Launch fails with the file error, as other prefix-preparation errors do today |

## 9. Testing

- **Swift unit tests** (test-first, in `Tests/MacNeutronCoreTests`):
  - the launch command uses `steam.exe` for `run` and `waitforexitandrun` when the bridge is installed, and not for `runinprefix`, when the bridge is missing, or when the escape hatch is set;
  - `STEAM_COMPAT_CLIENT_INSTALL_PATH` is replaced only when Steam's value lacks `steamclient.dylib`;
  - `activeAccountID()`: most recent user, low 32 bits, `nil` for a missing file or no `MostRecent` user;
  - `PrefixManager` copies the DLLs and `steam.exe`, and again only when the bridge version changes;
  - `BridgeInstaller` installs into a fake runtime, replaces an older version, and writes `bridge-version` last;
  - `WINEDEBUG` gains `+steamclient` only with logging on.
- **`bridge/check.sh`** after every `make bridge` (§5 step 6).
- **Probe** (§4.3) on a Mac with Steam running and logged in.

**Acceptance on the maintainer's Mac,** recorded in `docs/testing/acceptance-bridge.md`:

1. The probe prints `SteamAPI_Init` success, the account's SteamID and persona name, and receives the auth-ticket callback.
2. SMITE 2 no longer reports "Steam unavailable". Whether its anti-cheat then blocks login is recorded, not graded.
3. A Steam API game without anti-cheat works fully: Bongo Cat's Windows build (via "Runs as: Windows") loads its inventory. If that build doesn't use the Steam API, another owned Windows game that does is chosen and named in the record.
4. Timberborn (Mac native) still launches natively; `MACNEUTRON_NO_STEAM_BRIDGE=1` starts a game without `steam.exe` (visible in the launcher log).

## 10. First plan task: feasibility, with decision rules

Plan task 1 builds the bridge and runs the probe before any Swift change:

| Question | Result → decision |
|---|---|
| Does the probe print a SteamID? | Yes → continue. No after the patches in §4.1 → stop and report; the rest of the plan is not built on a guess |
| Does the i386 build work under the runtime's WoW64? (probe built for i386 against a 32-bit `steam_api.dll`, if one is available on the Mac) | Yes → ship `steamclient.dll`. No or untestable → 64-bit only; recorded in the acceptance file |
| Does `SteamAPI_Init` need `ActiveUser`? (probe run with and without `MACNEUTRON_STEAM_ACCOUNT`) | Needed → keep §7's account lookup. Not needed → still write it when available; it costs nothing |
| What does Mac Steam put in `STEAM_COMPAT_CLIENT_INSTALL_PATH`? (logged from a real launch) | Recorded in §2; §7's fallback stays either way |
| Does Wine load `lsteamclient.dll` from the prefix copy and find `lsteamclient.so`? | Yes → §6 as written. No → install the DLL only in the runtime's builtin folders and point `SteamClientDll64` there; record the change |

## 11. Risks

- **License.** `lsteamclient` binaries are distributed under the Steamworks SDK license, like every Proton fork. If Valve objects, the fallback is building on the user's Mac (the rejected option in §1), which `make bridge` already makes possible. Separately, the repo has no `LICENSE` file yet; our own code (`steam.c`, `probe.c`, patches) needs one before public release. That choice belongs to the maintainer and is not part of this plan.
- **Intel slice.** If Valve drops the x86_64 slice of `steamclient.dylib`, the bridge stops working; the launcher's missing-file log line makes that visible. There's no mitigation short of an arm64 Wine (see the arm64 spike).
- **SDK versions newer than the pinned Proton.** A game built against a newer Steamworks SDK than Proton's generated thunks may fail to get some interfaces. Updating is a new Proton pin plus `make bridge`.
- **Rosetta after macOS 27.** Apple has said that beyond macOS 27 it keeps only a subset of Rosetta aimed at games. The whole runtime depends on that; the bridge adds no new dependency.
