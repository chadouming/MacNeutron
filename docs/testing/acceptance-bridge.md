# Steam bridge acceptance

Spec: `docs/superpowers/specs/2026-09-28-macneutron-steam-bridge-design.md`. Personal data (SteamIDs, account IDs,
persona names) is never recorded here: "printed (redacted)".

## Feasibility gate (plan task 2), 2026-09-28

- Runtime: runtime-v4.7.3; Steam client build 1788652215 (Steam in Steam Play mode).
- DLL: SMITE 2 `steam_api64.dll` (SDK 1.57), `SteamAppId=480`, through `steam.exe` in a scratch prefix set up like the launcher's.
- `SteamAPI_Init`: ok. SteamID: printed (redacted). Persona name: printed (redacted). Accessors found: `SteamAPI_SteamUser_v021`, `SteamAPI_SteamFriends_v017`.
- Auth ticket: 234 bytes; `GetAuthSessionTicketResponse_t` callback received, result 1 (OK). Other callbacks (304, 1040011, 1270009, …) flowed through manual dispatch.
- Without `MACNEUTRON_STEAM_ACCOUNT`: pass. With it: pass. `ActiveUser` is not needed; `steam.exe` still writes it when known.
- Wine loaded `steamclient64.dll` from `C:\Program Files (x86)\Steam` and the runtime's `lsteamclient.so` loaded macOS Steam's `steamclient.dylib` from `STEAM_COMPAT_CLIENT_INSTALL_PATH` (`+steamclient` log): yes, no fallback.
- Bridge log notes: "host steamclient has no Steam_IsKnownInterface / Steam_NotifyMissingInterface, carrying on without it" (expected, spec §2.8); `Set_SteamAPI_CCheckCallbackRegisteredInProcess … not implemented!` (a stub Proton has too).
- Probe fix found here: `SteamAPI_ManualDispatch_Init` must be called after `SteamAPI_Init`; called before, no callback is ever delivered.
- Decision: continue.
