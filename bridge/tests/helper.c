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
