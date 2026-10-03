// An x86_64 Windows process under the arm64 Wine, run by FEX (gate G1): it prints a line, then the native machine
// IsWow64Process2 reports, which is ARM64 (0xAA64) when x64 code runs emulated on an arm64 host.
#include <windows.h>
#include <stdio.h>

int main(void) {
  USHORT process = 0, native = 0;
  printf("hello from x86_64\n");
  if (!IsWow64Process2(GetCurrentProcess(), &process, &native)) {
    printf("FAIL x64-hello: IsWow64Process2 failed with error %lu\n", GetLastError());
    return 1;
  }
  printf("native machine 0x%04x\n", native);
  if (native != 0xAA64) {
    printf("FAIL x64-hello: wanted native machine 0xaa64 (ARM64)\n");
    return 1;
  }
  printf("PASS x64-hello\n");
  return 0;
}
