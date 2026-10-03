// Gate G1: x64 code reading KUSER_SHARED_DATA directly under FEX. NtMajorVersion (0x7ffe026c) is 10; the TickCount
// low part (0x7ffe0320) is within 50 ms of GetTickCount64(). The server updates TickCount on its own clock, so the
// pair is read twice and either may pass.
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
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
  printf("PASS x64-kuser\n");
  return 0;
}
