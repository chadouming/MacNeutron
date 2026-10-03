// The W^X flip (patch 6) and its trace (patch 12). macOS refuses a page that is writable and executable at once, so
// Wine keeps a VirtualAlloc(PAGE_EXECUTE_READWRITE) page read-write or read-exec and flips it on the fault: a write
// after a run, and a run after a write, are one flip each. This rewrites and runs one such page 10 times, as a JIT does.
#include <windows.h>
#include <stdio.h>

int main(void) {
  BYTE *page = VirtualAlloc(NULL, 0x1000, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
  int i;
  setvbuf(stdout, NULL, _IONBF, 0);  // a crash keeps what was printed before it
  if (!page) {
    printf("FAIL arm64-wxflip: VirtualAlloc: error %lu\n", GetLastError());
    return 1;
  }
  for (i = 1; i <= 10; i++) {
    DWORD code[2] = {0x52800000 | (i << 5), 0xd65f03c0};  // mov w0, #i; ret
    int got;
    memcpy(page, code, sizeof(code));
    FlushInstructionCache(GetCurrentProcess(), page, sizeof(code));
    got = ((int (*)(void))page)();
    if (got != i) {
      printf("FAIL arm64-wxflip: run %d returned %d\n", i, got);
      return 1;
    }
  }
  printf("PASS arm64-wxflip\n");
  return 0;
}
