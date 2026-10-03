// Gate G1: self-modifying x64 code under FEX, in the two places FEX tracks it.
// 1. A function in RWX memory returns 1; one immediate byte is rewritten, with no FlushInstructionCache (x86 needs
//    none), and the next call returns 2.
// 2. A function in the exe's own .text, made PAGE_EXECUTE_READWRITE with VirtualProtect, returns 1; its immediate is
//    patched to 2 and FlushInstructionCache called; the next call returns 2; the protection is restored.
#include <windows.h>
#include <stdio.h>
#include <string.h>

static const unsigned char code[] = {0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3};  // mov eax,1; ret

// In assembly so the compiler can neither inline nor fold it, and its bytes are exactly `code`.
__asm__(".text\n.globl smc_text_one\nsmc_text_one:\n  movl $1, %eax\n  ret\n");
int smc_text_one(void);

static int rwx(void) {
  volatile unsigned char *mem = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
  if (!mem) {
    printf("FAIL x64-smc: VirtualAlloc RWX failed with error %lu\n", GetLastError());
    return 0;
  }
  memcpy((void *)mem, code, sizeof(code));
  int (*fn)(void) = (int (*)(void))mem;
  int first = fn();
  mem[1] = 0x02;  // mov eax,2
  int second = fn();
  printf("RWX page: before the rewrite %d, after %d\n", first, second);
  if (first != 1 || second != 2) {
    printf("FAIL x64-smc: RWX page: wanted 1 then 2\n");
    return 0;
  }
  return 1;
}

static int text(void) {
  volatile unsigned char *fn = (volatile unsigned char *)smc_text_one;
  int (*volatile call)(void) = smc_text_one;
  if (memcmp((const void *)fn, code, sizeof(code))) {
    printf("FAIL x64-smc: smc_text_one is not mov eax,1; ret\n");
    return 0;
  }
  DWORD old;
  if (!VirtualProtect((void *)fn, sizeof(code), PAGE_EXECUTE_READWRITE, &old)) {
    printf("FAIL x64-smc: VirtualProtect .text RWX failed with error %lu\n", GetLastError());
    return 0;
  }
  int first = call();
  fn[1] = 0x02;
  FlushInstructionCache(GetCurrentProcess(), (void *)fn, sizeof(code));
  int second = call();
  DWORD rwx;
  BOOL restored = VirtualProtect((void *)fn, sizeof(code), old, &rwx);
  printf(".text (protection 0x%lx): before the rewrite %d, after %d\n", old, first, second);
  if (first != 1 || second != 2) {
    printf("FAIL x64-smc: .text: wanted 1 then 2\n");
    return 0;
  }
  if (!restored) {
    printf("FAIL x64-smc: restoring the .text protection failed with error %lu\n", GetLastError());
    return 0;
  }
  return 1;
}

int main(void) {
  OutputDebugStringA("jit: start");  // gate G5 counts W^X flips after this line (check.sh g5-jit)
  if (!rwx() || !text()) return 1;
  printf("PASS x64-smc\n");
  return 0;
}
