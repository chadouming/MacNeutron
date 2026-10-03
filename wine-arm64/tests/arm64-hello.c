// A native ARM64 Windows process under the arm64 Wine: the architecture GetSystemInfo reports (12 = ARM64), the page
// size (printed for information), and the Windows major version read from KUSER_SHARED_DATA at its real address.
#include <windows.h>
#include <stdio.h>

int main(void) {
  SYSTEM_INFO si;
  DWORD major = 0;
  GetSystemInfo(&si);
  __try {
    major = *(const volatile DWORD *)((const BYTE *)0x7ffe0000 + 0x26c);  // NtMajorVersion
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    printf("FAIL arm64-hello: KUSER_SHARED_DATA is not readable at 0x7ffe0000\n");
    return 1;
  }
  printf("wProcessorArchitecture=%u dwPageSize=%lu NtMajorVersion=%lu\n", si.wProcessorArchitecture,
         (unsigned long)si.dwPageSize, (unsigned long)major);
  if (si.wProcessorArchitecture != 12 || major != 10) {
    printf("FAIL arm64-hello: wanted architecture 12 and major version 10\n");
    return 1;
  }
  printf("PASS arm64-hello\n");
  return 0;
}
