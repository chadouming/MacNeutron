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
