// Gate G1: x64 code reading KUSER_SHARED_DATA directly under FEX. NtMajorVersion (0x7ffe026c) is 10; the TickCount
// low part (0x7ffe0320) is within 50 ms of GetTickCount64(), and keeps up with QueryPerformanceCounter across a
// Sleep(100). The server updates TickCount on its own clock, so the GetTickCount64 pair is read twice and either may
// pass.
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
  OutputDebugStringA("jit: start");  // gate G5 counts W^X flips after this line (check.sh g5-jit)
  ULONG major = *(volatile ULONG *)0x7ffe026c;
  printf("NtMajorVersion %lu\n", major);
  if (major != 10) {
    printf("FAIL x64-kuser: wanted NtMajorVersion 10\n");
    return 1;
  }
  LONG diff[2];
  for (int i = 0; i < 2; i++) {
    ULONG kuser = *(volatile ULONG *)0x7ffe0320;
    ULONG tick = (ULONG)GetTickCount64();
    diff[i] = (LONG)(tick - kuser);
    printf("TickCount %lu, GetTickCount64 %lu, difference %ld ms\n", kuser, tick, diff[i]);
    if (i == 0) Sleep(20);
  }
  if (labs(diff[0]) > 50 && labs(diff[1]) > 50) {
    printf("FAIL x64-kuser: TickCount is more than 50 ms from GetTickCount64 (%ld, %ld ms)\n", diff[0], diff[1]);
    return 1;
  }
  // Wine's GetTickCount64 reads the same word, so the check above can't see a stale page or a server that stopped
  // updating it. QueryPerformanceCounter is another clock: TickCount has to keep up with it (the server updates it
  // every ~16 ms, hence the 30 ms slack).
  LARGE_INTEGER freq, q0, q1;
  QueryPerformanceFrequency(&freq);
  ULONG k0 = *(volatile ULONG *)0x7ffe0320;
  QueryPerformanceCounter(&q0);
  Sleep(100);
  ULONG k1 = *(volatile ULONG *)0x7ffe0320;
  QueryPerformanceCounter(&q1);
  LONG ticked = (LONG)(k1 - k0), qpc = (LONG)((q1.QuadPart - q0.QuadPart) * 1000 / freq.QuadPart);
  printf("over Sleep(100): TickCount advanced %ld ms, QueryPerformanceCounter %ld ms\n", ticked, qpc);
  if (ticked <= 0) {
    printf("FAIL x64-kuser: TickCount did not advance across Sleep(100)\n");
    return 1;
  }
  if (labs(ticked - qpc) > 30) {
    printf("FAIL x64-kuser: TickCount advanced %ld ms, QueryPerformanceCounter %ld ms: more than 30 ms apart\n", ticked,
           qpc);
    return 1;
  }
  printf("PASS x64-kuser\n");
  return 0;
}
