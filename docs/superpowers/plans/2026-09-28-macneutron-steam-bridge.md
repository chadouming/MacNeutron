# MacNeutron Steam API Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Windows games launched from macOS Steam through MacNeutron can use the Steam API, because every launch wires the runtime's Steam client bridge into the prefix and starts the game through our `steam.exe`.

**Architecture:** The pinned runtime already ships Proton's `lsteamclient` built for macOS (spec §2.8). We add a small Windows program, `steam.exe`, that registers "Steam is running" in the prefix's registry and runs the game in a job. The Swift launcher copies `steam.exe` and the runtime's `lsteamclient.dll` into `C:\Program Files (x86)\Steam`, points the bridge at macOS Steam's `steamclient.dylib`, and starts `run`/`waitforexitandrun` through `steam.exe`. The app installs `steam.exe` into the tool folder with the launcher.

**Tech Stack:** Swift 6 (swift-testing), SwiftPM, C11 for Windows built with Homebrew `mingw-w64`, POSIX sh test scripts, the installed winecx-gptk runtime (`runtime-v4.7.3`).

**Spec:** `docs/superpowers/specs/2026-09-28-macneutron-steam-bridge-design.md` (read the Amendment at its top first).

## Global Constraints

- Apple Silicon, macOS 26+, Swift 6 language mode, swift-testing; `swift test` stays green after every task (128 tests before Task 3).
- No new Swift package dependencies. Windows helpers are plain C, built only with `x86_64-w64-mingw32-gcc -O2 -static -s` (Homebrew `mingw-w64`, already required by `make smoke`).
- Never commit Valve's DLLs, Steamworks SDK headers, or `lsteamclient` source; the runtime provides the bridge.
- Never write a SteamID, account ID, persona name or other personal data into a committed file. Acceptance records say "printed (redacted)".
- Steam's own files (`localconfig.vdf`, `config.vdf`) are edited only while Steam is closed, with a backup, and only after the user says yes in chat. Steam binaries are never modified.
- Windows paths inside every prefix: `C:\Program Files (x86)\Steam\steam.exe`, `…\steamclient64.dll`, `…\steamclient.dll`; prefix-relative folder `drive_c/Program Files (x86)/Steam`.
- Launcher log notes use the spec §8 wording exactly: `note: Steam bridge not installed`, `note: Steam bridge disabled by launch option`, `note: steamclient.dylib not found in <folder>`, `note: no Steam account found in loginusers.vdf`.
- Every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Shell commands in this repo run without the `rtk` prefix (`rtk` isn't installed).

## Review Focus

1. **Launcher-style games:** the first process starts the real game and exits, and the child calls `SteamAPI_Init` later. Steam must still look "running" to that child. Pinned by `check.sh` "launcher-style child still sees Steam" (Task 1).
2. **Game paths with spaces and non-ASCII letters** (every Steam library lives under "Application Support"). The `Z:` conversion and `steam.exe` must start them. Pinned by `check.sh`, which runs from `…/macneutron bridge ü/game dir/hélper.exe` (Task 1), and `windowsPathMapsUnixPathsToDriveZ` (Task 3).
3. **Game arguments with spaces, embedded quotes and empty strings** must reach the game unchanged through `steam.exe`. Pinned by `check.sh` "arguments arrive unchanged" (Task 1).
4. **`loginusers.vdf` without a `MostRecent` key** (the maintainer's real file) must still yield the account. Pinned by `newestTimestampWinsWithoutMostRecent` (Task 3).
5. **Steam passing a `STEAM_COMPAT_CLIENT_INSTALL_PATH` that doesn't contain `steamclient.dylib`** (e.g. the Steam root) must fall back to the Steam bundle, and the launcher log must show what Steam passed. Pinned by `clientDirectoryFallsBackToTheSteamBundle` (Task 3) and `steamsClientPathIsLoggedAndCheckedForTheLibrary` (Task 4).

## File Structure

| File | Responsibility |
|---|---|
| `bridge/steam.c` (new) | `steam.exe`: registry values, run the game in a job, wait, clear pid |
| `bridge/tests/helper.c` (new) | Test program `check.sh` runs through `steam.exe` |
| `bridge/check.sh` (new) | `steam.exe` behaviour under the real installed runtime, no Steam needed |
| `bridge/probe.c`, `bridge/probe.sh` (new) | Developer end-to-end probe through a game's `steam_api64.dll` and real Steam |
| `Makefile` | `bridge`, `bridge-check` targets; `app` bundles `steam.exe` |
| `Sources/MacNeutronCore/SteamBridge.swift` (new) | Bridge constants and pure decisions: Windows paths, Steam client folder, prefix files |
| `Sources/MacNeutronCore/SteamLocation.swift` | `loginUsers`, `activeAccountID()` |
| `Sources/MacNeutronCore/LaunchEnvironment.swift` | `+steamclient` in the logging `WINEDEBUG` |
| `Sources/MacNeutronCore/ToolLayout.swift` | `steamHelper`, `lsteamclient*` paths, `steamBridgeInstalled` |
| `Sources/MacNeutronCore/PrefixManager.swift` | Copy bridge files into the prefix |
| `Sources/MacNeutronCore/Launcher.swift` | Decide, configure and run through `steam.exe` |
| `Sources/MacNeutronCore/RuntimeInstaller.swift` | Install `steam.exe` with the launcher; atomic, skip-if-identical |
| `Sources/MacNeutronApp/AppModel.swift` | Refresh tool files at app start |
| `Tests/MacNeutronCoreTests/SteamBridgeTests.swift` (new), `Support.swift`, `LauncherTests.swift`, `PrefixManagerTests.swift`, `LaunchEnvironmentTests.swift`, `RuntimeInstallerTests.swift` | Tests |
| `docs/testing/acceptance-bridge.md` (new) | Feasibility gate results and acceptance record |
| `README.md` | Build prerequisite and launch option |

---

### Task 1: `steam.exe` and its real-Wine check

**Files:**
- Create: `bridge/steam.c`, `bridge/tests/helper.c`, `bridge/check.sh`
- Modify: `Makefile`

**Interfaces:**
- Consumes: the installed runtime at `~/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron` (override with `MACNEUTRON_TOOL`).
- Produces: `build/bridge/steam.exe` from `make bridge`; `make bridge-check`. Usage `steam.exe <Windows path of program> [args…]`; reads `MACNEUTRON_STEAM_ACCOUNT`.

- [ ] **Step 1: Write the test program**

`bridge/tests/helper.c`:

```c
/* Test program for bridge/check.sh: runs under steam.exe and reports what it sees. */
#include <windows.h>
#include <shellapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define ACTIVE_PROCESS_KEY L"Software\\Valve\\Steam\\ActiveProcess"

static void put(const WCHAR *s)
{
    char buf[4096];
    if (WideCharToMultiByte(CP_UTF8, 0, s, -1, buf, sizeof(buf), NULL, NULL)) fputs(buf, stdout);
}

static DWORD read_dword(const WCHAR *name)
{
    DWORD value = 0, size = sizeof(value);
    RegGetValueW(HKEY_CURRENT_USER, ACTIVE_PROCESS_KEY, name, RRF_RT_REG_DWORD, NULL, &value, &size);
    return value;
}

/* 1 when ActiveProcess\pid names a running process: the check steam_api.dll makes. */
static int steam_alive(void)
{
    DWORD pid = read_dword(L"pid"), code = 0;
    HANDLE process;

    if (!pid || !(process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid))) return 0;
    GetExitCodeProcess(process, &code);
    CloseHandle(process);
    return code == STILL_ACTIVE;
}

int main(void)
{
    int argc, i;
    WCHAR **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    const WCHAR *mode = argc > 1 ? argv[1] : L"";

    if (!wcscmp(mode, L"exit") && argc > 2) return _wtoi(argv[2]);
    if (!wcscmp(mode, L"args"))
    {
        for (i = 2; i < argc; i++) { fputs("[", stdout); put(argv[i]); fputs("]", stdout); }
        fputs("\n", stdout);
        return 0;
    }
    if (!wcscmp(mode, L"steam"))
    {
        WCHAR client[MAX_PATH] = L"";
        DWORD size = sizeof(client);
        RegGetValueW(HKEY_CURRENT_USER, ACTIVE_PROCESS_KEY, L"SteamClientDll64", RRF_RT_REG_SZ, NULL, client, &size);
        printf("alive=%d user=%lu client64=", steam_alive(), read_dword(L"ActiveUser"));
        put(client);
        fputs("\n", stdout);
        return 0;
    }
    if (!wcscmp(mode, L"pid"))
    {
        printf("%lu\n", read_dword(L"pid"));
        return 0;
    }
    if (!wcscmp(mode, L"spawn") && argc > 2)  /* a launcher: start the real game, then quit */
    {
        WCHAR self[MAX_PATH], cmd[3 * MAX_PATH];
        STARTUPINFOW si = { sizeof(si) };
        PROCESS_INFORMATION pi;

        GetModuleFileNameW(NULL, self, MAX_PATH);
        _snwprintf(cmd, ARRAYSIZE(cmd), L"\"%ls\" late \"%ls\"", self, argv[2]);
        cmd[ARRAYSIZE(cmd) - 1] = 0;
        return CreateProcessW(NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi) ? 0 : 2;
    }
    if (!wcscmp(mode, L"late") && argc > 2)  /* the real game, still running after its launcher quit */
    {
        FILE *out;

        Sleep(1500);
        if (!(out = _wfopen(argv[2], L"w"))) return 2;
        fprintf(out, "alive=%d\n", steam_alive());
        fclose(out);
        return 0;
    }
    fprintf(stderr, "helper: unknown mode\n");
    return 3;
}
```

- [ ] **Step 2: Write the check script**

`bridge/check.sh`:

```sh
#!/bin/sh
# Runs steam.exe under the installed MacNeutron runtime: real Wine, no Steam needed (bridge spec §9).
# Needs `make bridge` and an installed runtime; MACNEUTRON_TOOL overrides the default tool folder.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/build/bridge"
TOOL="${MACNEUTRON_TOOL:-$HOME/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron}"
WINE="$TOOL/Libraries/Wine/bin/wine"
WORK="${TMPDIR:-/tmp}/macneutron bridge ü"   # a space and a non-ASCII letter on purpose
export WINEPREFIX="$WORK/pfx" WINEDEBUG=-all WINEMSYNC=1

[ -x "$WINE" ] || { echo "check: no runtime at $TOOL" >&2; exit 1; }
[ -d "$WINEPREFIX" ] || "$WINE" wineboot -u >/dev/null 2>&1
STEAM="$WINEPREFIX/drive_c/Program Files (x86)/Steam"
mkdir -p "$STEAM" "$WORK/game dir"
cp "$B/steam.exe" "$STEAM/steam.exe"
cp "$B/tests/helper.exe" "$WORK/game dir/hélper.exe"
winpath() { printf 'Z:%s' "$1" | tr / '\\'; }
HELPER="$(winpath "$WORK/game dir/hélper.exe")"
STEAMEXE='C:\Program Files (x86)\Steam\steam.exe'

steam() { "$WINE" "$STEAMEXE" "$HELPER" "$@" 2>/dev/null | tr -d '\r'; }
fail=0
expect() { # name got want
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2], want [$3]"; fail=1; fi
}

set +e; "$WINE" "$STEAMEXE" "$HELPER" exit 7 >/dev/null 2>&1; got=$?; set -e
expect "exit code passes through" "$got" 7
expect "arguments arrive unchanged" "$(steam args 'a b' '--name="Player One"' '')" '[a b][--name="Player One"][]'
expect "registry names a live Steam" "$(MACNEUTRON_STEAM_ACCOUNT=12345 steam steam)" \
  'alive=1 user=12345 client64=C:\Program Files (x86)\Steam\steamclient64.dll'
rm -f "$WORK/late.txt"
steam spawn "$(winpath "$WORK/late.txt")" >/dev/null
expect "launcher-style child still sees Steam" "$(tr -d '\r' < "$WORK/late.txt" 2>/dev/null || true)" "alive=1"
expect "pid cleared afterwards" "$("$WINE" "$HELPER" pid 2>/dev/null | tr -d '\r')" 0
set +e; "$WINE" "$STEAMEXE" 'C:\missing.exe' >/dev/null 2>&1; got=$?; set -e
expect "missing program exits 1" "$got" 1

exit $fail
```

- [ ] **Step 3: Add the Makefile targets**

In `Makefile`, replace the first line and add the two targets below `smoke`:

```make
.PHONY: build test smoke app bridge bridge-check

MINGW = x86_64-w64-mingw32-gcc -O2 -static -s
BRIDGE = build/bridge
```

```make
# Windows helpers for the Steam bridge (docs/superpowers/specs/2026-09-28-macneutron-steam-bridge-design.md).
bridge:
	@command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "bridge: needs brew install mingw-w64" >&2; exit 1; }
	mkdir -p $(BRIDGE)/tests
	$(MINGW) -o $(BRIDGE)/steam.exe bridge/steam.c -ladvapi32
	$(MINGW) -o $(BRIDGE)/tests/helper.exe bridge/tests/helper.c -ladvapi32 -lshell32

# steam.exe under the installed runtime (real Wine, no Steam).
bridge-check: bridge
	sh bridge/check.sh
```

Keep the existing `APP = build/MacNeutron.app` line and the other targets unchanged.

- [ ] **Step 4: Run it to see it fail**

Run: `make bridge-check`
Expected: FAIL. The compiler reports that `bridge/steam.c` doesn't exist (`No such file or directory`), and make stops.

- [ ] **Step 5: Write `steam.exe`**

`bridge/steam.c`:

```c
/* steam.exe for MacNeutron: tells Windows games inside Wine that Steam is running.
 *
 *   steam.exe <program> [arguments...]      (<program> is a Windows path)
 *
 * steam_api(64).dll treats Steam as running when HKCU\Software\Valve\Steam\ActiveProcess\pid names a
 * live process, and loads the client DLL named next to it. This writes those values (pointing at the
 * runtime's Steam bridge, which the launcher copies into C:\Program Files (x86)\Steam), runs <program>
 * in a job, waits until every process in the job has exited (launchers start the real game and quit),
 * clears the pid, and exits with <program>'s exit code.
 * Spec: docs/superpowers/specs/2026-09-28-macneutron-steam-bridge-design.md §4.2.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define STEAM_DIR L"C:\\Program Files (x86)\\Steam"
#define STEAM_KEY L"Software\\Valve\\Steam"
#define ACTIVE_PROCESS_KEY STEAM_KEY L"\\ActiveProcess"

static HKEY create_key(HKEY root, const WCHAR *path)
{
    HKEY key;
    return RegCreateKeyExW(root, path, 0, NULL, 0, KEY_ALL_ACCESS, NULL, &key, NULL) ? NULL : key;
}

static void set_string(HKEY key, const WCHAR *name, const WCHAR *value)
{
    RegSetValueExW(key, name, 0, REG_SZ, (const BYTE *)value, (DWORD)((wcslen(value) + 1) * sizeof(WCHAR)));
}

static void set_dword(HKEY key, const WCHAR *name, DWORD value)
{
    RegSetValueExW(key, name, 0, REG_DWORD, (const BYTE *)&value, sizeof(value));
}

static void register_steam(DWORD pid)
{
    WCHAR account[16];
    HKEY key;

    if ((key = create_key(HKEY_CURRENT_USER, STEAM_KEY)))
    {
        set_string(key, L"SteamPath", STEAM_DIR);
        set_string(key, L"SteamExe", STEAM_DIR L"\\steam.exe");
        RegCloseKey(key);
    }
    if ((key = create_key(HKEY_CURRENT_USER, ACTIVE_PROCESS_KEY)))
    {
        set_dword(key, L"pid", pid);
        set_string(key, L"SteamClientDll64", STEAM_DIR L"\\steamclient64.dll");
        if (GetFileAttributesW(STEAM_DIR L"\\steamclient.dll") != INVALID_FILE_ATTRIBUTES)
            set_string(key, L"SteamClientDll", STEAM_DIR L"\\steamclient.dll");
        if (GetEnvironmentVariableW(L"MACNEUTRON_STEAM_ACCOUNT", account, ARRAYSIZE(account)))
            set_dword(key, L"ActiveUser", wcstoul(account, NULL, 10));
        RegCloseKey(key);
    }
    if ((key = create_key(HKEY_LOCAL_MACHINE, L"Software\\Wow6432Node\\Valve\\Steam")))
    {
        set_string(key, L"InstallPath", STEAM_DIR);
        RegCloseKey(key);
    }
}

/* A later steam.exe in the same prefix may own the pid by now: only clear our own. */
static void unregister_steam(DWORD pid)
{
    DWORD current = 0, size = sizeof(current);
    HKEY key;

    if (!(key = create_key(HKEY_CURRENT_USER, ACTIVE_PROCESS_KEY))) return;
    if (!RegQueryValueExW(key, L"pid", NULL, NULL, (BYTE *)&current, &size) && current == pid)
        set_dword(key, L"pid", 0);
    RegCloseKey(key);
}

/* Our command line minus our own name (argv[0] rules: quoted, or up to the first blank). */
static WCHAR *child_command_line(void)
{
    const WCHAR *p = GetCommandLineW();

    if (*p == '"')
    {
        for (p++; *p && *p != '"'; p++) ;
        if (*p) p++;
    }
    else
        while (*p && *p != ' ' && *p != '\t') p++;
    while (*p == ' ' || *p == '\t') p++;
    return *p ? _wcsdup(p) : NULL;
}

/* Waits until no process in the job is left; returns at once if the count can't be read. */
static void wait_for_job(HANDLE job)
{
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info;

    while (QueryInformationJobObject(job, JobObjectBasicAccountingInformation, &info, sizeof(info), NULL)
           && info.ActiveProcesses)
        Sleep(250);
}

int main(void)
{
    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    DWORD pid = GetCurrentProcessId(), code = 1;
    WCHAR *cmd = child_command_line();
    HANDLE job;

    if (!cmd)
    {
        fprintf(stderr, "usage: steam.exe <program> [arguments...]\n");
        return 1;
    }
    register_steam(pid);
    job = CreateJobObjectW(NULL, NULL);
    if (!CreateProcessW(NULL, cmd, NULL, NULL, TRUE, CREATE_SUSPENDED, NULL, NULL, &si, &pi))
    {
        fprintf(stderr, "steam.exe: could not start %ls (error %lu)\n", cmd, GetLastError());
        unregister_steam(pid);
        return 1;
    }
    if (job) AssignProcessToJobObject(job, pi.hProcess);
    ResumeThread(pi.hThread);
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    if (job) wait_for_job(job);
    unregister_steam(pid);
    return (int)code;
}
```

- [ ] **Step 6: Run the check**

Run: `make bridge-check`
Expected: PASS. The first run creates a scratch prefix, which takes up to a minute. Output ends with:

```
ok   exit code passes through
ok   arguments arrive unchanged
ok   registry names a live Steam
ok   launcher-style child still sees Steam
ok   pid cleared afterwards
ok   missing program exits 1
```

and `make` exits 0. If "launcher-style child still sees Steam" fails, use superpowers:systematic-debugging. Check first whether `QueryInformationJobObject` returns `ActiveProcesses` under this runtime by adding a temporary `fprintf(stderr, ...)` in `wait_for_job`. Don't weaken the check.

- [ ] **Step 7: Commit**

```bash
git add bridge/steam.c bridge/tests/helper.c bridge/check.sh Makefile
git commit -m "feat(bridge): steam.exe registers a running Steam and runs the game in a job

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Feasibility gate: probe through a real `steam_api64.dll`

**Files:**
- Create: `bridge/probe.c`, `bridge/probe.sh`, `docs/testing/acceptance-bridge.md`
- Modify: `Makefile` (one line in `bridge`)

**Interfaces:**
- Consumes: `build/bridge/steam.exe` (Task 1); the runtime's `lsteamclient` (`Libraries/Wine/lib/wine/{x86_64-windows,i386-windows}/lsteamclient.dll`, `x86_64-unix/lsteamclient.so`); SMITE 2's `steam_api64.dll`; the running, logged-in Mac Steam.
- Produces: the gate decision (spec §10), recorded in `docs/testing/acceptance-bridge.md`. **If the probe can't print a SteamID, stop here and report to the user. Tasks 3–6 are not started.**

- [ ] **Step 1: Write the probe**

`bridge/probe.c`:

```c
/* steamprobe.exe: checks the Steam bridge end to end through a game's own steam_api64.dll.
 * Run it with bridge/probe.sh, which prepares a prefix like the launcher does (SteamAppId=480).
 *   steamprobe.exe <Windows path of steam_api64.dll>
 * Uses only the DLL's flat C exports, so no Steamworks headers are needed.
 * Exits 0 only when init, the SteamID, the persona name and an auth-ticket callback all work. */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>

typedef struct { int32_t user; int32_t id; uint8_t *param; int32_t size; } CallbackMsg;  /* CallbackMsg_t */
enum { GET_AUTH_SESSION_TICKET_RESPONSE = 163 };                                          /* k_iSteamUserCallbacks + 63 */

static HMODULE api;

static void *find(const char *name) { return (void *)GetProcAddress(api, name); }

#define NEED(var, name) \
    if (!(*(void **)&(var) = find(name))) { printf("missing export %s\n", name); return 1; }

/* The newest SteamAPI_<interface>_v0NN accessor the DLL exports, called. */
static void *accessor(const char *interface)
{
    char name[64];
    int version;

    for (version = 40; version > 0; version--)
    {
        void *(*get)(void);
        snprintf(name, sizeof(name), "SteamAPI_%s_v%03d", interface, version);
        if ((*(void **)&get = find(name)))
        {
            printf("%s: %s\n", interface, name);
            return get();
        }
    }
    printf("%s: no accessor\n", interface);
    return NULL;
}

int main(int argc, char **argv)
{
    uint8_t (*init)(void);
    int (*init_flat)(char *);
    void (*dispatch_init)(void);
    int32_t (*get_pipe)(void);
    void (*run_frame)(int32_t);
    uint8_t (*next_callback)(int32_t, CallbackMsg *);
    void (*free_callback)(int32_t);
    uint64_t (*get_steam_id)(void *);
    const char *(*persona)(void *);
    uint32_t (*get_ticket)(void *, void *, int, uint32_t *, void *);  /* SDK >= 1.58 adds the last argument */
    void *user, *friends;
    uint8_t ticket[1024];
    uint32_t ticket_size = 0;
    uint64_t steam_id;
    const char *name;
    int ok, got_ticket = 0, i;

    if (argc < 2) { fprintf(stderr, "usage: steamprobe.exe <steam_api64.dll>\n"); return 2; }
    if (!(api = LoadLibraryA(argv[1]))) { printf("load: FAIL (error %lu)\n", GetLastError()); return 1; }

    NEED(dispatch_init, "SteamAPI_ManualDispatch_Init");
    dispatch_init();
    if ((*(void **)&init = find("SteamAPI_Init"))) ok = init();
    else
    {
        char message[1024] = "";
        NEED(init_flat, "SteamAPI_InitFlat");
        ok = init_flat(message) == 0;
        if (!ok) printf("init message: %s\n", message);
    }
    printf("init: %s\n", ok ? "ok" : "FAIL");
    if (!ok) return 1;

    NEED(get_pipe, "SteamAPI_GetHSteamPipe");
    NEED(run_frame, "SteamAPI_ManualDispatch_RunFrame");
    NEED(next_callback, "SteamAPI_ManualDispatch_GetNextCallback");
    NEED(free_callback, "SteamAPI_ManualDispatch_FreeLastCallback");
    NEED(get_steam_id, "SteamAPI_ISteamUser_GetSteamID");
    NEED(persona, "SteamAPI_ISteamFriends_GetPersonaName");
    NEED(get_ticket, "SteamAPI_ISteamUser_GetAuthSessionTicket");
    if (!(user = accessor("SteamUser")) || !(friends = accessor("SteamFriends"))) return 1;

    steam_id = get_steam_id(user);
    name = persona(friends);
    printf("steamid: %llu\n", (unsigned long long)steam_id);
    printf("persona: %s\n", name ? name : "(null)");

    get_ticket(user, ticket, sizeof(ticket), &ticket_size, NULL);
    for (i = 0; i < 100 && !got_ticket; i++)
    {
        int32_t pipe = get_pipe();
        CallbackMsg msg;

        run_frame(pipe);
        while (next_callback(pipe, &msg))
        {
            if (msg.id == GET_AUTH_SESSION_TICKET_RESPONSE)
            {
                got_ticket = 1;
                printf("auth ticket: callback, result %d\n", ((int32_t *)msg.param)[1]);
            }
            free_callback(pipe);
        }
        Sleep(100);
    }
    if (!got_ticket) printf("auth ticket: no callback within 10 s\n");
    return steam_id && name && *name && got_ticket ? 0 : 1;
}
```

- [ ] **Step 2: Write the probe script**

`bridge/probe.sh`:

```sh
#!/bin/sh
# Developer end-to-end check of the Steam bridge (bridge spec §4.3). Needs Steam running and logged in,
# an installed runtime, and `make bridge`. Prints your SteamID and persona name: don't paste them anywhere public.
#   bridge/probe.sh <path to a game's steam_api64.dll>
# ACCOUNT=<id> sets MACNEUTRON_STEAM_ACCOUNT; APPID=<id> replaces 480; WINEDEBUG=+steamclient shows the bridge's log.
set -eu
[ $# -eq 1 ] || { echo "usage: bridge/probe.sh <steam_api64.dll>" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/build/bridge"
DLL="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
TOOL="${MACNEUTRON_TOOL:-$HOME/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron}"
WINE="$TOOL/Libraries/Wine/bin/wine"
LIB="$TOOL/Libraries/Wine/lib/wine"
export WINEPREFIX="${TMPDIR:-/tmp}/macneutron probe/pfx" WINEDEBUG="${WINEDEBUG:--all}" WINEMSYNC=1
export SteamAppId="${APPID:-480}" SteamGameId="${APPID:-480}"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS"
if [ -n "${ACCOUNT:-}" ]; then export MACNEUTRON_STEAM_ACCOUNT="$ACCOUNT"; else unset MACNEUTRON_STEAM_ACCOUNT || true; fi

[ -d "$WINEPREFIX" ] || "$WINE" wineboot -u >/dev/null 2>&1
STEAM="$WINEPREFIX/drive_c/Program Files (x86)/Steam"
mkdir -p "$STEAM"
cp "$B/steam.exe" "$STEAM/steam.exe"
cp "$LIB/x86_64-windows/lsteamclient.dll" "$STEAM/steamclient64.dll"
[ ! -f "$LIB/i386-windows/lsteamclient.dll" ] || cp "$LIB/i386-windows/lsteamclient.dll" "$STEAM/steamclient.dll"
winpath() { printf 'Z:%s' "$1" | tr / '\\'; }
exec "$WINE" 'C:\Program Files (x86)\Steam\steam.exe' "$(winpath "$B/steamprobe.exe")" "$(winpath "$DLL")"
```

- [ ] **Step 3: Build the probe**

Add this line to the `bridge` target in `Makefile`, after the `steam.exe` line:

```make
	$(MINGW) -o $(BRIDGE)/steamprobe.exe bridge/probe.c
```

Run: `make bridge`
Expected: exits 0; `build/bridge/steamprobe.exe` exists.

- [ ] **Step 4: Run the probe with Steam running**

Check that Steam runs: `pgrep -x steam_osx`. If it prints nothing, ask the user to start Steam and log in, and wait for them to confirm. Tell the user the probe briefly shows them as playing "Spacewar" (app 480) on Steam.

Run: `bridge/probe.sh "$HOME/Library/Application Support/Steam/steamapps/common/SMITE 2/Windows/Engine/Binaries/ThirdParty/Steamworks/Steamv157/Win64/steam_api64.dll"; echo "exit=$?"`

Expected: PASS, printing in this order:

```
init: ok
SteamUser: SteamAPI_SteamUser_v021
SteamFriends: SteamAPI_SteamFriends_v017
steamid: 7656119…
persona: <your Steam name>
auth ticket: callback, result 1
exit=0
```

Decision rules (spec §10):
- `init: FAIL`: run again with `APPID=2437170` (SMITE 2, which the user owns), then with `WINEDEBUG=+steamclient,+loaddll`. Use superpowers:systematic-debugging on what the bridge logs.
  - If the log shows Wine didn't load `steamclient64.dll` from `C:\Program Files (x86)\Steam` or didn't find `lsteamclient.so`, take the spec's fallback: in `steam.c`, point `SteamClientDll64` at `C:\windows\system32\lsteamclient.dll` and drop the DLL copies from `probe.sh`. Re-run Task 1's check, ledger the ruling, and later drop the DLL entries from Task 4's `prefixFiles`.
  - If it still fails, **stop and report to the user** with the output. Don't start Task 3.
- `steamid: 0` or no auth-ticket callback: same diagnosis. A missing callback alone isn't a stop: record it, and continue only if the SteamID and name print.

- [ ] **Step 5: Check whether `ActiveUser` matters**

Compute the account ID without echoing it into any file:

`ACCOUNT=$(python3 -c 'import re,sys; ids=re.findall(r"\"(7656\d{13})\"", open(sys.argv[1]).read()); print(int(ids[0]) & 0xffffffff)' "$HOME/Library/Application Support/Steam/config/loginusers.vdf") bridge/probe.sh "<same dll path>"; echo "exit=$?"`

Expected: the same PASS output. Note whether step 4 (no account) and step 5 (with account) both passed; that answers spec §10's `ActiveUser` question.

- [ ] **Step 6: Record the gate**

Create `docs/testing/acceptance-bridge.md`:

```markdown
# Steam bridge acceptance

Spec: `docs/superpowers/specs/2026-09-28-macneutron-steam-bridge-design.md`. Personal data (SteamIDs, account IDs,
persona names) is never recorded here: "printed (redacted)".

## Feasibility gate (plan task 2), <date>

- Runtime: runtime-v4.7.3; Steam client build <from Steam > About Steam, or `grep -m1 "Client version" ~/Library/Application Support/Steam/logs/compat_log.txt`>.
- DLL: SMITE 2 `steam_api64.dll` (SDK 1.57).
- `SteamAPI_Init`: <ok/FAIL>. SteamID: <printed (redacted)/0>. Persona name: <printed (redacted)/empty>.
- Auth-ticket callback: <received, result N / not received>.
- Without `MACNEUTRON_STEAM_ACCOUNT`: <pass/fail>. With it: <pass/fail>. `ActiveUser` is <needed/not needed>.
- Wine loaded `steamclient64.dll` from `C:\Program Files (x86)\Steam`: <yes/no → fallback taken>.
- Decision: <continue / stop>.
```

Fill every `<…>` with what you observed. Replace the placeholders; don't leave any.

- [ ] **Step 7: Commit**

```bash
git add bridge/probe.c bridge/probe.sh Makefile docs/testing/acceptance-bridge.md
git commit -m "test(bridge): end-to-end probe through a game's steam_api64.dll; feasibility gate recorded

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Account, Steam client folder, Windows paths, debug channel

**Files:**
- Create: `Sources/MacNeutronCore/SteamBridge.swift`, `Tests/MacNeutronCoreTests/SteamBridgeTests.swift`
- Modify: `Sources/MacNeutronCore/SteamLocation.swift`, `Sources/MacNeutronCore/LaunchEnvironment.swift:11`, `Tests/MacNeutronCoreTests/Support.swift`, `Tests/MacNeutronCoreTests/LaunchEnvironmentTests.swift:17-20`, `Tests/MacNeutronCoreTests/LauncherTests.swift` (two `WINEDEBUG` strings)

**Interfaces:**
- Produces:
  - `public enum SteamBridge` with `static let steamExe: String` (`C:\Program Files (x86)\Steam\steam.exe`), `static func windowsPath(_ path: String) -> String`, `static func clientDirectory(steamValue: String?, steam: SteamLocation) -> String`;
  - `SteamLocation.loginUsers: URL`, `SteamLocation.activeAccountID() -> UInt32?`;
  - test helpers `makeSteamLocation(loginUsers:steamClient:) throws -> SteamLocation`, `loginUser(account:timestamp:mostRecent:) -> String`, `loginUsersFile(_:) -> String`.

- [ ] **Step 1: Add the test helpers**

Append to `Tests/MacNeutronCoreTests/Support.swift`:

```swift
/// A Steam root in a temp folder. `loginUsers` becomes config/loginusers.vdf; `steamClient` puts a
/// steamclient.dylib in the bundle's MacOS folder.
func makeSteamLocation(loginUsers: String? = nil, steamClient: Bool = true) throws -> SteamLocation {
    let steam = SteamLocation(root: try makeTempDir().appending(path: "Steam", directoryHint: .isDirectory))
    if let loginUsers { try write(loginUsers, to: steam.loginUsers) }
    if steamClient { try write("dylib", to: steam.bundleMacOS.appending(path: "steamclient.dylib")) }
    return steam
}

/// One user block of loginusers.vdf. SteamID64 76561197960265728 + n belongs to account n.
func loginUser(account: Int, timestamp: Int, mostRecent: Bool? = nil) -> String {
    var block = "\t\"\(76561197960265728 + account)\"\n\t{\n"
        + "\t\t\"AccountName\"\t\t\"user\(account)\"\n\t\t\"Timestamp\"\t\t\"\(timestamp)\"\n"
    if let mostRecent { block += "\t\t\"MostRecent\"\t\t\"\(mostRecent ? 1 : 0)\"\n" }
    return block + "\t}\n"
}

func loginUsersFile(_ users: String...) -> String { "\"users\"\n{\n" + users.joined() + "}\n" }
```

- [ ] **Step 2: Write the failing tests**

`Tests/MacNeutronCoreTests/SteamBridgeTests.swift`:

```swift
import Foundation
import Testing
@testable import MacNeutronCore

@Test func windowsPathMapsUnixPathsToDriveZ() {
    #expect(SteamBridge.windowsPath("/Users/me/Steam Library/Gäme/Game.exe") == #"Z:\Users\me\Steam Library\Gäme\Game.exe"#)
    #expect(SteamBridge.windowsPath(#"C:\Games\Game.exe"#) == #"C:\Games\Game.exe"#)
}

@Test func clientDirectoryKeepsSteamsValueWhenItHoldsTheLibrary() throws {
    let steam = try makeSteamLocation()
    let other = try makeTempDir()
    try write("dylib", to: other.appending(path: "steamclient.dylib"))
    let value = other.path(percentEncoded: false)
    #expect(SteamBridge.clientDirectory(steamValue: value, steam: steam) == value)
}

@Test func clientDirectoryFallsBackToTheSteamBundle() throws {
    let steam = try makeSteamLocation()
    let bundle = String(steam.bundleMacOS.path(percentEncoded: false).dropLast())  // no trailing slash
    #expect(SteamBridge.clientDirectory(steamValue: steam.root.path(percentEncoded: false), steam: steam) == bundle)
    #expect(SteamBridge.clientDirectory(steamValue: nil, steam: steam) == bundle)
}

@Test func mostRecentUserIsTheActiveAccount() throws {
    let steam = try makeSteamLocation(loginUsers: loginUsersFile(
        loginUser(account: 1, timestamp: 200, mostRecent: false),
        loginUser(account: 2, timestamp: 100, mostRecent: true)))
    #expect(steam.activeAccountID() == 2)
}

@Test func newestTimestampWinsWithoutMostRecent() throws {
    // The maintainer's loginusers.vdf has no MostRecent key at all.
    let steam = try makeSteamLocation(loginUsers: loginUsersFile(
        loginUser(account: 1, timestamp: 100), loginUser(account: 2, timestamp: 300), loginUser(account: 3, timestamp: 200)))
    #expect(steam.activeAccountID() == 2)
}

@Test func noLoginUsersMeansNoAccount() throws {
    #expect(try makeSteamLocation().activeAccountID() == nil)
    #expect(try makeSteamLocation(loginUsers: "\"users\"\n{\n}\n").activeAccountID() == nil)
}
```

Change the expected logging `WINEDEBUG` in three existing tests:
- `Tests/MacNeutronCoreTests/LaunchEnvironmentTests.swift`, `loggingTurnsOnWineDebugChannels`: `#expect(env["WINEDEBUG"] == "+err,+warn,+loaddll,+steamclient")`.
- `Tests/MacNeutronCoreTests/LauncherTests.swift`, `macneutronLogSendsGameOutputToPerGameLog`: `.contains("WINEDEBUG=+err,+warn,+loaddll,+steamclient")`.
- `Tests/MacNeutronCoreTests/LauncherTests.swift`, `gameSettingsApplyUnderneathLaunchOptions`: `#expect(wine["WINEDEBUG"] == "+err,+warn,+loaddll,+steamclient")`.

- [ ] **Step 3: Run them to see them fail**

Run: `swift test 2>&1 | tail -20`
Expected: FAIL to compile, with `cannot find 'SteamBridge' in scope` and `value of type 'SteamLocation' has no member 'loginUsers'`.

- [ ] **Step 4: Implement**

`Sources/MacNeutronCore/SteamBridge.swift`:

```swift
import Foundation

/// Where the Steam bridge lives inside a prefix, and the small decisions the launcher makes about it.
/// The bridge itself (Proton's lsteamclient) ships with the runtime; `steam.exe` ships with MacNeutron.
public enum SteamBridge {
    /// `steam.exe` inside every prefix.
    public static let steamExe = #"C:\Program Files (x86)\Steam\steam.exe"#

    /// `Z:` is Wine's mapping of `/`; Windows paths pass through.
    public static func windowsPath(_ path: String) -> String {
        path.hasPrefix("/") ? "Z:" + path.replacingOccurrences(of: "/", with: #"\"#) : path
    }

    /// Steam's `STEAM_COMPAT_CLIENT_INSTALL_PATH` when that folder holds `steamclient.dylib`,
    /// otherwise the Steam bundle's MacOS folder, where macOS Steam keeps it.
    public static func clientDirectory(steamValue: String?, steam: SteamLocation) -> String {
        if let steamValue, FileManager.default.fileExists(atPath: steamValue + "/steamclient.dylib") { return steamValue }
        var bundle = steam.bundleMacOS.path(percentEncoded: false)
        if bundle.hasSuffix("/") { bundle.removeLast() }
        return bundle
    }
}
```

In `Sources/MacNeutronCore/SteamLocation.swift`, add below `appInfo`:

```swift
    public var loginUsers: URL { root.appending(path: "config/loginusers.vdf") }
```

and below `installedAppIDs()`:

```swift
    /// The account Steam is logged in as: the user marked `MostRecent`, else the newest `Timestamp`.
    /// Returns its account ID, the low 32 bits of the SteamID64 that names the user's block.
    public func activeAccountID() -> UInt32? {
        guard let text = try? String(contentsOf: loginUsers, encoding: .utf8),
              let nodes = try? KeyValues.parse(text) else { return nil }
        let users = (nodes.node(at: ["users"])?.children ?? []).filter { UInt64($0.key) != nil }
        func number(_ user: KVNode, _ key: String) -> UInt64 { UInt64(user.children.node(at: [key])?.stringValue ?? "") ?? 0 }
        let chosen = users.first { number($0, "MostRecent") == 1 }
            ?? users.max { number($0, "Timestamp") < number($1, "Timestamp") }
        return chosen.flatMap { UInt64($0.key) }.map { UInt32(truncatingIfNeeded: $0) }
    }
```

In `Sources/MacNeutronCore/LaunchEnvironment.swift`, change the logging line to:

```swift
            env["WINEDEBUG"] = logging ? "+err,+warn,+loaddll,+steamclient" : "-all"
```

- [ ] **Step 5: Run the tests**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: PASS: `Test run with 134 tests in 0 suites passed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacNeutronCore/SteamBridge.swift Sources/MacNeutronCore/SteamLocation.swift Sources/MacNeutronCore/LaunchEnvironment.swift Tests/MacNeutronCoreTests
git commit -m "feat(core): Steam account lookup, Steam client folder, Windows paths for the bridge

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Wire the bridge into prefixes and launches

**Files:**
- Modify: `Sources/MacNeutronCore/ToolLayout.swift`, `Sources/MacNeutronCore/SteamBridge.swift`, `Sources/MacNeutronCore/PrefixManager.swift`, `Sources/MacNeutronCore/Launcher.swift`, `Tests/MacNeutronCoreTests/Support.swift`, `Tests/MacNeutronCoreTests/SteamBridgeTests.swift`, `Tests/MacNeutronCoreTests/PrefixManagerTests.swift`, `Tests/MacNeutronCoreTests/LauncherTests.swift`

**Interfaces:**
- Consumes: `SteamBridge.steamExe`, `windowsPath`, `clientDirectory`, `SteamLocation.activeAccountID()`, test helpers (Task 3).
- Produces:
  - `ToolLayout.steamHelper` (`<root>/bin/steam.exe`), `lsteamclientUnix`, `lsteamclient64`, `lsteamclient32`, `steamBridgeInstalled: Bool`;
  - `SteamBridge.prefixFolder`, `SteamBridge.prefixFiles(layout:) -> [(URL, String)]`;
  - `PrefixError.steamBridgeCopyFailed(String)`;
  - `PrefixManager.prepare(backend:environment:steamBridge:)`, with `steamBridge` defaulting to `false`;
  - `Launcher.steam: SteamLocation` and init parameter `steam: SteamLocation = SteamLocation()`;
  - test helper `installFakeSteamBridge(in:i386:)`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/MacNeutronCoreTests/Support.swift`:

```swift
/// The files `ToolLayout.steamBridgeInstalled` looks for; `i386: false` leaves out the 32-bit client.
func installFakeSteamBridge(in layout: ToolLayout, i386: Bool = true) throws {
    try write("steam.exe", to: layout.steamHelper)
    try write("lsteamclient.so", to: layout.lsteamclientUnix)
    try write("lsteamclient x86_64", to: layout.lsteamclient64)
    if i386 { try write("lsteamclient i386", to: layout.lsteamclient32) }
}
```

Append to `Tests/MacNeutronCoreTests/SteamBridgeTests.swift`:

```swift
@Test func bridgeNeedsSteamExeAndBothHalvesOfTheClient() throws {
    let layout = try makeToolLayout()
    #expect(!layout.steamBridgeInstalled)
    try installFakeSteamBridge(in: layout, i386: false)
    #expect(layout.steamBridgeInstalled)
    try FileManager.default.removeItem(at: layout.lsteamclientUnix)
    #expect(!layout.steamBridgeInstalled)
}
```

Append to `Tests/MacNeutronCoreTests/PrefixManagerTests.swift`:

```swift
private func steamFolder(_ manager: PrefixManager) -> URL {
    manager.context.prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
}

@Test func steamBridgeIsCopiedIntoTheSteamFolder() throws {
    let (manager, env) = try makeManager(winebootCreatingPrefix())
    try installFakeSteamBridge(in: manager.layout)
    try manager.prepare(backend: .dxmt, environment: env, steamBridge: true)
    let folder = steamFolder(manager)
    #expect(try String(contentsOf: folder.appending(path: "steam.exe"), encoding: .utf8) == "steam.exe")
    #expect(try String(contentsOf: folder.appending(path: "steamclient64.dll"), encoding: .utf8) == "lsteamclient x86_64")
    #expect(try String(contentsOf: folder.appending(path: "steamclient.dll"), encoding: .utf8) == "lsteamclient i386")
}

@Test func upToDatePrefixStillGetsTheSteamBridge() throws {
    // Prefixes prepared before the bridge existed (SMITE 2's on the maintainer's Mac) must get it too.
    let (manager, env) = try makeManager(winebootCreatingPrefix())
    try manager.prepare(backend: .dxmt, environment: env)
    try installFakeSteamBridge(in: manager.layout)
    try manager.prepare(backend: .dxmt, environment: env, steamBridge: true)
    #expect(FileManager.default.fileExists(
        atPath: steamFolder(manager).appending(path: "steamclient64.dll").path(percentEncoded: false)))
}

@Test func thirtyTwoBitClientIsSkippedWithoutAnI386Build() throws {
    let (manager, env) = try makeManager(winebootCreatingPrefix())
    try installFakeSteamBridge(in: manager.layout, i386: false)
    try manager.prepare(backend: .dxmt, environment: env, steamBridge: true)
    #expect(!FileManager.default.fileExists(
        atPath: steamFolder(manager).appending(path: "steamclient.dll").path(percentEncoded: false)))
}

@Test func prefixWithoutBridgeRequestGetsNoSteamFolder() throws {
    let (manager, env) = try makeManager(winebootCreatingPrefix())
    try installFakeSteamBridge(in: manager.layout)
    try manager.prepare(backend: .dxmt, environment: env)
    #expect(!FileManager.default.fileExists(atPath: steamFolder(manager).path(percentEncoded: false)))
}
```

In `Tests/MacNeutronCoreTests/LauncherTests.swift`, replace `Fixture` and `makeFixture` with:

```swift
private struct Fixture {
    let launcher: Launcher
    let runner: FakeRunner
    let notifier: RecordingNotifier
    let env: [String: String]
    var launcherLog: String { (try? String(contentsOf: launcher.log.launcherLog, encoding: .utf8)) ?? "" }
}

private func makeFixture(runner: FakeRunner = winebootCreatingPrefix(), rosetta: Bool = true,
                         bridge: Bool = false) throws -> Fixture {
    let notifier = RecordingNotifier()
    let layout = try makeToolLayout()
    if bridge { try installFakeSteamBridge(in: layout) }
    let steam = try makeSteamLocation(loginUsers: loginUsersFile(loginUser(account: 1, timestamp: 100, mostRecent: true)))
    let launcher = Launcher(layout: layout, runner: runner,
                            log: LauncherLog(directory: try makeTempDir().appending(path: "Logs")),
                            notifier: notifier, preflight: Preflight(rosettaAvailable: { rosetta }),
                            settings: GameSettingsStore(directory: try makeTempDir().appending(path: "games")),
                            steam: steam)
    let env = steamEnvironment(dataPath: try makeTempDir().appending(path: "compatdata/42"), appID: "42")
    return Fixture(launcher: launcher, runner: runner, notifier: notifier, env: env)
}
```

and append:

```swift
@Test func gameGoesThroughSteamExeWhenTheBridgeIsInstalled() throws {
    let f = try makeFixture(bridge: true)
    #expect(f.launcher.launch(["waitforexitandrun", "/Steam Library/My Game/Game.exe", "-windowed"], environment: f.env) == 0)
    let game = try #require(f.runner.calls.first { $0.arguments.first == SteamBridge.steamExe })
    #expect(game.arguments == [#"C:\Program Files (x86)\Steam\steam.exe"#, #"Z:\Steam Library\My Game\Game.exe"#, "-windowed"])
    #expect(game.environment["STEAM_COMPAT_CLIENT_INSTALL_PATH"]
        == String(f.launcher.steam.bundleMacOS.path(percentEncoded: false).dropLast()))
    #expect(game.environment["MACNEUTRON_STEAM_ACCOUNT"] == "1")
    let prefix = try CompatContext(environment: f.env).prefix
    #expect(FileManager.default.fileExists(
        atPath: prefix.appending(path: "drive_c/Program Files (x86)/Steam/steamclient64.dll").path(percentEncoded: false)))
}

@Test func runInPrefixNeverGoesThroughSteamExe() throws {
    let f = try makeFixture(bridge: true)
    _ = f.launcher.launch(["runinprefix", "/g/tool.exe"], environment: f.env)
    #expect(f.runner.calls.map(\.arguments) == [["/g/tool.exe"]])
}

@Test func escapeHatchStartsTheGameDirectly() throws {
    let f = try makeFixture(bridge: true)
    var env = f.env
    env["MACNEUTRON_NO_STEAM_BRIDGE"] = "1"
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: env)
    #expect(f.runner.calls.last?.arguments == ["/g/Game.exe"])
    #expect(f.launcherLog.contains("note: Steam bridge disabled by launch option"))
}

@Test func missingBridgeStartsTheGameDirectly() throws {
    let f = try makeFixture()
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: f.env)
    #expect(f.runner.calls.last?.arguments == ["/g/Game.exe"])
    #expect(f.launcherLog.contains("note: Steam bridge not installed"))
}

@Test func accountFromLaunchOptionsWins() throws {
    let f = try makeFixture(bridge: true)
    var env = f.env
    env["MACNEUTRON_STEAM_ACCOUNT"] = "99"
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: env)
    #expect(f.runner.calls.last?.environment["MACNEUTRON_STEAM_ACCOUNT"] == "99")
}

@Test func steamsClientPathIsLoggedAndCheckedForTheLibrary() throws {
    let f = try makeFixture(bridge: true)
    try FileManager.default.removeItem(at: f.launcher.steam.bundleMacOS.appending(path: "steamclient.dylib"))
    var env = f.env
    env["STEAM_COMPAT_CLIENT_INSTALL_PATH"] = "/nowhere"
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: env)
    #expect(f.launcherLog.contains("(Steam passed /nowhere)"))
    #expect(f.launcherLog.contains("note: steamclient.dylib not found in"))
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test 2>&1 | tail -20`
Expected: FAIL to compile, with `value of type 'ToolLayout' has no member 'steamHelper'`, `extra argument 'steamBridge' in call` and `extra argument 'steam' in call`.

- [ ] **Step 3: Implement `ToolLayout` and `SteamBridge.prefixFiles`**

In `Sources/MacNeutronCore/ToolLayout.swift`, add below `launcherBinary`:

```swift
    /// MacNeutron's `steam.exe`, installed next to the launcher.
    public var steamHelper: URL { root.appending(path: "bin/steam.exe") }
    /// The runtime's Steam client bridge (Proton's lsteamclient, built by the runtime).
    public var lsteamclientUnix: URL { wineLib.appending(path: "wine/x86_64-unix/lsteamclient.so") }
    public var lsteamclient64: URL { wineLib.appending(path: "wine/x86_64-windows/lsteamclient.dll") }
    public var lsteamclient32: URL { wineLib.appending(path: "wine/i386-windows/lsteamclient.dll") }

    /// `steam.exe` and both halves of the 64-bit bridge are present.
    public var steamBridgeInstalled: Bool {
        [steamHelper, lsteamclientUnix, lsteamclient64]
            .allSatisfy { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }
```

In `Sources/MacNeutronCore/SteamBridge.swift`, add inside `SteamBridge`:

```swift
    /// The folder `steam.exe` names in the registry, relative to the prefix.
    static let prefixFolder = "drive_c/Program Files (x86)/Steam"

    /// What the launcher copies into a prefix: (source, destination relative to the prefix).
    static func prefixFiles(layout: ToolLayout) -> [(URL, String)] {
        var files = [(layout.steamHelper, "\(prefixFolder)/steam.exe"),
                     (layout.lsteamclient64, "\(prefixFolder)/steamclient64.dll")]
        if FileManager.default.fileExists(atPath: layout.lsteamclient32.path(percentEncoded: false)) {
            files.append((layout.lsteamclient32, "\(prefixFolder)/steamclient.dll"))
        }
        return files
    }
```

- [ ] **Step 4: Implement the prefix copy**

In `Sources/MacNeutronCore/PrefixManager.swift`:

1. Add the error case and its description:

```swift
    case steamBridgeCopyFailed(String)
```

```swift
        case .steamBridgeCopyFailed(let detail): "could not install the Steam bridge: \(detail)"
```

2. Change `prepare`'s signature, doc comment and DLL line:

```swift
    /// Runs `wineboot -u` when needed, then installs the backend's DLLs and, when asked, the Steam bridge.
    /// Holds the prefix lock only for this preparation, never while the game runs. On failure the version
    /// is not recorded, so the next launch retries; nothing under `drive_c` is ever deleted.
    public func prepare(backend: GraphicsBackend, environment: [String: String], steamBridge: Bool = false) throws {
```

```swift
            try deployDLLs(for: backend)
            if steamBridge { try deploySteamBridge() }
```

3. Replace `deployDLLs` with the version below, which shares one copy helper:

```swift
    func deployDLLs(for backend: GraphicsBackend) throws {
        for (source, destination) in backend.prefixDLLs(layout: layout) {
            // A missing file must fail loudly: skipping one once left DXMT's dxgi paired with DXVK.
            guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
                throw PrefixError.dllCopyFailed("\(destination): missing from the runtime (\(source.path(percentEncoded: false)))")
            }
            do { try install(source, at: destination) } catch {
                throw PrefixError.dllCopyFailed("\(destination): \(error.localizedDescription)")
            }
        }
    }

    /// Every launch, like the DLLs: prefixes made before the bridge existed get it too.
    func deploySteamBridge() throws {
        for (source, destination) in SteamBridge.prefixFiles(layout: layout) {
            do { try install(source, at: destination) } catch {
                throw PrefixError.steamBridgeCopyFailed("\(destination): \(error.localizedDescription)")
            }
        }
    }

    private func install(_ source: URL, at destination: String) throws {
        let fm = FileManager.default
        let target = context.prefix.appending(path: destination)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path(percentEncoded: false)) { try fm.removeItem(at: target) }
        try fm.copyItem(at: source, to: target)
    }
```

- [ ] **Step 5: Implement the launcher wiring**

In `Sources/MacNeutronCore/Launcher.swift`:

1. Add the stored property `public let steam: SteamLocation` after `settings`. Add the init parameter `steam: SteamLocation = SteamLocation()` after `settings:`, and assign `self.steam = steam`.

2. In `launch`, replace the line `let env = LaunchEnvironment.build(...)` with:

```swift
        var env = LaunchEnvironment.build(base: environment, context: context, backend: backend, logging: logging)
        let steamBridge = usesSteamBridge(request.verb, env)
        if steamBridge { addSteamClient(to: &env) }
```

3. In the `switch`:
   - Pass `steamBridge: steamBridge` to both `prefix.prepare(backend: backend, environment: env)` calls in `.run` and `.waitforexitandrun`.
   - Call `runGame(request, env, gameLog, throughSteam: steamBridge)` in `.run` and `.waitforexitandrun`.
   - Call `runGame(request, env, gameLog, throughSteam: false)` in `.runinprefix`.
   - Leave `.getcompatpath`/`.getnativepath` unchanged.

4. Replace `runGame` and add the two helpers:

```swift
    private func runGame(_ request: LaunchRequest, _ env: [String: String], _ gameLog: URL?,
                         throughSteam: Bool) throws -> Int32 {
        let game = [request.target] + request.arguments
        let command = throughSteam ? [SteamBridge.steamExe, SteamBridge.windowsPath(request.target)] + request.arguments : game
        return try runner.run(layout.wine, command, environment: env, output: gameLog)
    }

    /// `run` and `waitforexitandrun` start the game through `steam.exe` when the bridge is installed,
    /// as Proton does; the log says why when they don't.
    private func usesSteamBridge(_ verb: Verb, _ environment: [String: String]) -> Bool {
        guard verb == .run || verb == .waitforexitandrun else { return false }
        if environment["MACNEUTRON_NO_STEAM_BRIDGE"] == "1" {
            log.append("note: Steam bridge disabled by launch option")
            return false
        }
        guard layout.steamBridgeInstalled else {
            log.append("note: Steam bridge not installed")
            return false
        }
        return true
    }

    /// Tells the runtime's lsteamclient where macOS Steam's client library is, and steam.exe who is logged in.
    private func addSteamClient(to env: inout [String: String]) {
        let passed = env["STEAM_COMPAT_CLIENT_INSTALL_PATH"]
        let client = SteamBridge.clientDirectory(steamValue: passed, steam: steam)
        env["STEAM_COMPAT_CLIENT_INSTALL_PATH"] = client
        log.append("note: Steam client folder \(client) (Steam passed \(passed ?? "nothing"))")
        if !FileManager.default.fileExists(atPath: client + "/steamclient.dylib") {
            log.append("note: steamclient.dylib not found in \(client)")
        }
        guard env["MACNEUTRON_STEAM_ACCOUNT"] == nil else { return }
        if let account = steam.activeAccountID() {
            env["MACNEUTRON_STEAM_ACCOUNT"] = String(account)
        } else {
            log.append("note: no Steam account found in loginusers.vdf")
        }
    }
```

- [ ] **Step 6: Run the tests**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: PASS: `Test run with 145 tests in 0 suites passed`.

- [ ] **Step 7: Commit**

```bash
git add Sources/MacNeutronCore Tests/MacNeutronCoreTests
git commit -m "feat(launcher): start games through steam.exe with the runtime's Steam bridge in the prefix

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Ship `steam.exe` with the app and keep the tool folder current

**Files:**
- Modify: `Sources/MacNeutronCore/RuntimeInstaller.swift`, `Sources/MacNeutronApp/AppModel.swift`, `Makefile`, `README.md`, `Tests/MacNeutronCoreTests/RuntimeInstallerTests.swift`

**Interfaces:**
- Consumes: `ToolLayout.steamHelper` (Task 4); `build/bridge/steam.exe` (Task 1).
- Produces: `public static func RuntimeInstaller.writeToolFiles(layout:launcherBinary:) throws`, which installs `steam.exe` from `launcherBinary`'s folder when present, and `static func installFile(_:at:) throws`.

- [ ] **Step 1: Write the failing tests**

In `Tests/MacNeutronCoreTests/RuntimeInstallerTests.swift`, add this line at the end of `installsRuntimeAndToolFiles`:

```swift
    #expect(!fm.fileExists(atPath: layout.steamHelper.path(percentEncoded: false)))  // none next to the echo launcher
```

and append:

```swift
@Test func installPutsSteamExeNextToTheLauncher() throws {
    let (tarball, pin) = try makeRuntimeTarball()
    let layout = ToolLayout(root: try makeTempDir().appending(path: "macneutron"))
    let launcher = try makeEchoLauncher()
    try write("steam.exe v1", to: launcher.deletingLastPathComponent().appending(path: "steam.exe"))
    try RuntimeInstaller.install(tarball: tarball, pin: pin, layout: layout, launcherBinary: launcher)
    #expect(try String(contentsOf: layout.steamHelper, encoding: .utf8) == "steam.exe v1")
}

@Test func toolFilesRefreshReplacesAChangedLauncher() throws {
    let layout = ToolLayout(root: try makeTempDir().appending(path: "macneutron"))
    let launcher = try makeEchoLauncher()
    try RuntimeInstaller.writeToolFiles(layout: layout, launcherBinary: launcher)
    try write("#!/bin/sh\necho v2\n", to: launcher, executable: true)
    try RuntimeInstaller.writeToolFiles(layout: layout, launcherBinary: launcher)
    #expect(try String(contentsOf: layout.launcherBinary, encoding: .utf8) == "#!/bin/sh\necho v2\n")
    #expect(FileManager.default.isExecutableFile(atPath: layout.launcherBinary.path(percentEncoded: false)))
}

@Test func identicalToolFilesAreLeftAlone() throws {
    // The app refreshes tool files at every start; a game Steam launches meanwhile must never
    // find bin/macneutron missing or half-written.
    let layout = ToolLayout(root: try makeTempDir().appending(path: "macneutron"))
    let launcher = try makeEchoLauncher()
    try RuntimeInstaller.writeToolFiles(layout: layout, launcherBinary: launcher)
    func inode() throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: layout.launcherBinary.path(percentEncoded: false))[.systemFileNumber]
            as? NSNumber)?.intValue
    }
    let before = try inode()
    try RuntimeInstaller.writeToolFiles(layout: layout, launcherBinary: launcher)
    #expect(try inode() == before)
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test 2>&1 | grep -E "✘|error:|Test run with" | head -20`
Expected: FAIL. The build fails because `writeToolFiles` isn't public, or, if it compiles in `@testable`, `installPutsSteamExeNextToTheLauncher` fails (no `bin/steam.exe`) and `identicalToolFilesAreLeftAlone` fails (the launcher is removed and copied again, so its inode changes).

- [ ] **Step 3: Implement**

In `Sources/MacNeutronCore/RuntimeInstaller.swift`, replace `writeToolFiles` with:

```swift
    /// Writes Steam's tool files, then installs the launcher and, when one sits next to it, `steam.exe`.
    /// Safe to repeat (the app calls it at every start): identical files are skipped, and new ones are
    /// renamed into place, so a game Steam launches meanwhile never finds the launcher missing.
    public static func writeToolFiles(layout: ToolLayout, launcherBinary: URL) throws {
        let fm = FileManager.default
        try compatibilityTool.write(to: layout.root.appending(path: "compatibilitytool.vdf"), atomically: true, encoding: .utf8)
        try toolManifest.write(to: layout.root.appending(path: "toolmanifest.vdf"), atomically: true, encoding: .utf8)
        let stub = layout.root.appending(path: "proton")
        try protonStub.write(to: stub, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path(percentEncoded: false))
        try installFile(launcherBinary, at: layout.launcherBinary)
        let steamExe = launcherBinary.deletingLastPathComponent().appending(path: "steam.exe")
        if fm.fileExists(atPath: steamExe.path(percentEncoded: false)) {
            try installFile(steamExe, at: layout.steamHelper)
        }
    }

    /// Copies `source` to `destination` through a temporary file and `rename(2)`, unless they already match.
    static func installFile(_ source: URL, at destination: URL) throws {
        let fm = FileManager.default
        guard source.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath() else { return }
        let contents = try Data(contentsOf: source)
        if (try? Data(contentsOf: destination)) == contents { return }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.appendingPathExtension("new")
        try? fm.removeItem(at: temporary)
        try fm.copyItem(at: source, to: temporary)
        guard rename(temporary.path(percentEncoded: false), destination.path(percentEncoded: false)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
```

In `Sources/MacNeutronApp/AppModel.swift` `init`, add after the `installNativeTool` line:

```swift
        // An updated app brings a new launcher and steam.exe: install them without a runtime reinstall.
        if layout.runtimeVersion != nil { try? RuntimeInstaller.writeToolFiles(layout: layout, launcherBinary: helper) }
```

- [ ] **Step 4: Run the tests**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: PASS: `Test run with 148 tests in 0 suites passed`.

- [ ] **Step 5: Bundle `steam.exe` in the app**

In `Makefile`, change the `app` target's first line to `app: build bridge`, and add this line after the `cp .build/release/macneutron …` line:

```make
	cp $(BRIDGE)/steam.exe $(APP)/Contents/Helpers/steam.exe
```

Run: `make app && ls build/MacNeutron.app/Contents/Helpers`
Expected: `macneutron` and `steam.exe` are listed, and the `codesign` lines succeed.

- [ ] **Step 6: Update the README**

In `README.md`:
- Change the `make app` line to: `make app                    # build/MacNeutron.app, ad-hoc signed, with the CLI and steam.exe inside (needs brew install mingw-w64)`.
- Add this row to the launch-options table:

```markdown
| `/usr/bin/env MACNEUTRON_NO_STEAM_BRIDGE=1 %command%` | Start the game without the Steam bridge (the game then can't reach Steam) |
```

- Add this section after "Per-game options":

```markdown
## Steam API

Windows games talk to your running Mac Steam through the runtime's Steam client bridge (Proton's `lsteamclient`,
built for macOS by the runtime). MacNeutron's `steam.exe` tells each game that Steam is running. Anti-cheat
that needs a Windows kernel driver (Easy Anti-Cheat, BattlEye, Vanguard and others) still won't run.
```

- [ ] **Step 7: Commit**

```bash
git add Sources/MacNeutronCore/RuntimeInstaller.swift Sources/MacNeutronApp/AppModel.swift Makefile README.md Tests/MacNeutronCoreTests/RuntimeInstallerTests.swift
git commit -m "feat(app): ship steam.exe and refresh the launcher in the tool folder at app start

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Acceptance on the maintainer's Mac

**Files:**
- Modify: `docs/testing/acceptance-bridge.md`

**Interfaces:**
- Consumes: everything above; the user's Steam library (SMITE 2, Bongo Cat, Timberborn); the user in chat for every game launch and every Steam config change.

- [ ] **Step 1: Install the new build**

Run: `make app`. Then quit the running MacNeutron with `osascript -e 'quit app id "io.github.chadouming.MacNeutron"'` and run `open build/MacNeutron.app`.
Then run: `T="$HOME/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron/bin"; cmp "$T/steam.exe" build/bridge/steam.exe && cmp "$T/macneutron" build/MacNeutron.app/Contents/Helpers/macneutron && echo installed`
Expected: `installed`. The app's start refreshed the tool folder.

- [ ] **Step 2: Probe (acceptance item 1)**

Run the Task 2 step 4 command again.
Expected: the same PASS output. Record it as redacted.

- [ ] **Step 3: SMITE 2 launch-option cleanup and escape hatch (acceptance item 4, second half)**

SMITE 2 still has the Metal-HUD launch option from 2026-09-28 (backup `~/Library/Application Support/Steam/userdata/<id>/config/localconfig.vdf.before-hud-20260928185158`). **Ask the user** before changing it. After a yes, with Steam closed (`pgrep -x steam_osx` prints nothing):
1. Back up `localconfig.vdf`.
2. Change SMITE 2's (`2437170`) `LaunchOptions` value to `/usr/bin/env MACNEUTRON_NO_STEAM_BRIDGE=1 %command%`.
3. Ask the user to launch SMITE 2 from Steam.

Expected: `~/Library/Logs/MacNeutron/launcher.log` gains `note: Steam bridge disabled by launch option` for appid 2437170, and the game again reports "Steam unavailable" (the user confirms). Then, with Steam closed again, remove SMITE 2's `LaunchOptions` line entirely.

- [ ] **Step 4: SMITE 2 through the bridge (acceptance items 2 and 5)**

Ask the user to launch SMITE 2 from Steam and report what the login screen says.
Expected: no "Steam unavailable". `launcher.log` has a line `note: Steam client folder … (Steam passed …)`: record Steam's value (spec §2.7). Record whether the game then logs in or its anti-cheat blocks it; that isn't graded.

- [ ] **Step 5: A Steam API game without anti-cheat (acceptance item 3)**

Ask the user to set Bongo Cat to "Runs as: Windows" in MacNeutron's Games window and let Steam download the Windows build. Then run: `find "$HOME/Library/Application Support/Steam/steamapps/common" -ipath "*bongo*" -iname "steam_api*.dll"`
- If a `steam_api64.dll` shows up: ask the user to launch Bongo Cat and confirm the cat and its inventory items load.
- If none shows up: Bongo Cat doesn't use the Steam API. Ask the user to name another owned Windows game that does, and repeat with it.

Afterwards, ask whether to switch Bongo Cat back to its Mac build.

- [ ] **Step 6: Mac games unaffected (acceptance item 4, first half)**

Ask the user to launch Timberborn.
Expected: it starts natively. `ps -o command= -p $(pgrep -f "Timberborn.app/Contents/MacOS" | head -1)` shows no `wine`.

- [ ] **Step 7: Record and commit**

Append an `## Acceptance, <date>` section to `docs/testing/acceptance-bridge.md`. It has one bullet per acceptance item 1–5 with the observed result, the value Steam passed in `STEAM_COMPAT_CLIENT_INSTALL_PATH`, and the Steam client build. Redact the SteamID, account ID and persona name, and leave no `<…>` placeholders.

```bash
git add docs/testing/acceptance-bridge.md
git commit -m "docs: Steam bridge acceptance results

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
