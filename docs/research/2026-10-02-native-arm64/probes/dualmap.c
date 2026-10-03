/* Throwaway: can PE code get a fault-free JIT buffer from one section mapped twice (RW + RX)? */
#include <windows.h>
#include <stdio.h>
static const DWORD code42[] = { 0xd2800540, 0xd65f03c0 }, code7[] = { 0xd28000e0, 0xd65f03c0 };
int main(void) {
    HANDLE s = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_EXECUTE_READWRITE, 0, 0x10000, NULL);
    printf("CreateFileMapping(PAGE_EXECUTE_READWRITE): %p err %lu\n", s, s ? 0 : GetLastError());
    if (!s) return 1;
    BYTE *rw = MapViewOfFile(s, FILE_MAP_WRITE, 0, 0, 0);
    BYTE *rx = MapViewOfFile(s, FILE_MAP_READ | FILE_MAP_EXECUTE, 0, 0, 0);
    printf("RW view %p, RX view %p (err %lu)\n", rw, rx, rx ? 0 : GetLastError());
    if (!rw || !rx) return 1;
    LARGE_INTEGER f, t0, t1; QueryPerformanceFrequency(&f);
    memcpy(rw, code42, 8); FlushInstructionCache(GetCurrentProcess(), rx, 8);
    printf("exec RX view -> %d\n", ((int (*)(void))rx)());
    QueryPerformanceCounter(&t0);
    int sum = 0;
    for (int i = 0; i < 100000; i++) { memcpy(rw, (i & 1) ? code7 : code42, 8); FlushInstructionCache(GetCurrentProcess(), rx, 8); sum += ((int (*)(void))rx)(); }
    QueryPerformanceCounter(&t1);
    printf("100000 rewrite+exec cycles: sum %d, %.2f us each\n", sum, (t1.QuadPart - t0.QuadPart) * 1e6 / f.QuadPart / 100000);
    /* compare: one RWX VirtualAlloc page, which goes through the W^X fault flip */
    BYTE *x = VirtualAlloc(NULL, 0x1000, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    QueryPerformanceCounter(&t0);
    for (int i = 0; i < 2000; i++) { memcpy(x, (i & 1) ? code7 : code42, 8); FlushInstructionCache(GetCurrentProcess(), x, 8); sum += ((int (*)(void))x)(); }
    QueryPerformanceCounter(&t1);
    printf("2000 rewrite+exec cycles on an RWX page (fault flip): %.2f us each\n", (t1.QuadPart - t0.QuadPart) * 1e6 / f.QuadPart / 2000);
    return 0;
}
