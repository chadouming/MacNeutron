// Gate G1: self-modifying x64 code under FEX. A function in RWX memory returns 1; one immediate byte is rewritten, with
// no FlushInstructionCache (x86 needs none), and the next call returns 2.
#include <windows.h>
#include <stdio.h>
#include <string.h>

int main(void) {
  static const unsigned char code[] = {0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3};  // mov eax,1; ret
  volatile unsigned char *mem = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
  if (!mem) {
    printf("FAIL x64-smc: VirtualAlloc RWX failed with error %lu\n", GetLastError());
    return 1;
  }
  memcpy((void *)mem, code, sizeof(code));
  int (*fn)(void) = (int (*)(void))mem;
  int first = fn();
  mem[1] = 0x02;  // mov eax,2
  int second = fn();
  printf("before the rewrite %d, after %d\n", first, second);
  if (first != 1 || second != 2) {
    printf("FAIL x64-smc: wanted 1 then 2\n");
    return 1;
  }
  printf("PASS x64-smc\n");
  return 0;
}
