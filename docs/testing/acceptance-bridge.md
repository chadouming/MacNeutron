# Steam bridge acceptance

Spec: `docs/superpowers/specs/2026-09-28-macneutron-steam-bridge-design.md`. Personal data (SteamIDs, account IDs,
persona names) is never recorded here: "printed (redacted)".

## Feasibility gate (plan task 2), 2026-09-28

- Runtime: runtime-v4.7.3; Steam client build 1788652215
 (Steam in Steam Play mode).
- DLL: SMITE 2 `steam_api64.dll` (SDK 1.57), `SteamAppId=480`, through `steam.exe` in a scratch prefix set up like the launcher's.
- `SteamAPI_Init`: ok. SteamID: printed (redacted). Persona name: printed (redacted). Accessors found: `SteamAPI_SteamUser_v021`, `SteamAPI_SteamFriends_v017`.
- Auth ticket: 234 bytes; `GetAuthSessionTicketResponse_t` callback received, result 1 (OK). Other callbacks (304, 1040011, 1270009, …) flowed through manual dispatch.
- Without `MACNEUTRON_STEAM_ACCOUNT`: pass. With it: pass. `ActiveUser` is not needed; `steam.exe` still writes it when known.
- Wine loaded `steamclient64.dll` from `C:\Program Files (x86)\Steam` and the runtime's `lsteamclient.so` loaded macOS Steam's `steamclient.dylib` from `STEAM_COMPAT_CLIENT_INSTALL_PATH` (`+steamclient` log): yes, no fallback.
- Bridge log notes: "host steamclient has no Steam_IsKnownInterface / Steam_NotifyMissingInterface, carrying on without it" (expected, spec §2.8); `Set_SteamAPI_CCheckCallbackRegisteredInProcess … not implemented!` (a stub Proton has too).
- Probe fix found here: `SteamAPI_ManualDispatch_Init` must be called after `SteamAPI_Init`; called before, no callback is ever delivered.
- Decision: continue.

## Acceptance (plan task 6), 2026-09-28

- Build: `feat/steam-bridge` app build; the app's start installed the new launcher and `steam.exe` into the tool folder (`cmp` identical).
- Item 1, probe: through `bridge/probe.sh` and again through the real installed launcher (`proton waitforexitandrun steamprobe.exe …`, which set up the prefix, the client path and `steam.exe` itself): `SteamAPI_Init` ok, SteamID and persona name printed (redacted), auth ticket 234 bytes, callback result 1.
- Item 2, SMITE 2 from Steam (maintainer): no "Steam unavailable"; logs in and plays. Easy Anti-Cheat did not block it.
- Item 3: not run. Bongo Cat is not installed on this Mac. SMITE 2 (item 2) proves Steam auth tickets end to end, but a Unity/Steamworks.NET game and a Steam inventory load remain untested.
- Item 4: Timberborn still launches natively (maintainer). `MACNEUTRON_NO_STEAM_BRIDGE=1` through the real launcher: `note: Steam bridge disabled by launch option`, game started directly, clean `SteamAPI_Init` failure. That check found a crash, now fixed: the hatch first left the prefix's client DLL in place, and the bridge aborted the game.
- Item 5: Mac Steam passes `STEAM_COMPAT_CLIENT_INSTALL_PATH=~/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS`, which contains `steamclient.dylib`; the launcher's fallback isn't needed with this client.
- Also found and fixed during acceptance: reading `appinfo.vdf` memory-mapped crashed with SIGBUS when the file was rewritten mid-read.
- Not tested: 32-bit games (no 32-bit Steam API game on this Mac); `steamclient.dll` is still copied.
