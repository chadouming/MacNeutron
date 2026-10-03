// Gate G1: atomics on a value that straddles a 16-byte boundary, under FEX. ARM64 can't access such a value atomically
// in one instruction: FEX's code for it raises a misaligned-access fault, and FEX's handler takes over. A plain load and
// store under FEX's TSO emulation (LDAPUR/STLUR) are rewritten in place into a plain access and a barrier (the handler
// writes into FEX's own code); lock cmpxchg (CASAL) is emulated. The counter is zeroed with a plain store, then
// incremented 1000 times by a plain load and a lock cmpxchg, and ends at 1000.
#include <windows.h>
#include <stdio.h>

static _Alignas(16) unsigned char buf[32];

int main(void) {
  volatile LONG *p = (volatile LONG *)(buf + 14);  // bytes 14..17: across the boundary at 16
  int failed = 0;
  buf[14] = buf[15] = buf[16] = buf[17] = 0xff;
  __asm__ volatile("movl $0, (%0)" : : "r"(p) : "memory");
  for (int i = 0; i < 1000; i++) {
    unsigned char ok;
    __asm__ volatile("movl (%[p]), %%eax\n\t"
                     "leal 1(%%rax), %%ecx\n\t"
                     "lock cmpxchgl %%ecx, (%[p])\n\t"
                     "sete %[ok]"
                     : [ok] "=q"(ok)
                     : [p] "r"(p)
                     : "rax", "rcx", "memory", "cc");
    failed += !ok;
  }
  LONG got = *p;
  printf("counter %ld after 1000 increments; %d lock cmpxchg failed\n", got, failed);
  if (got != 1000 || failed) {
    printf("FAIL x64-unaligned: wanted 1000 and no failed lock cmpxchg\n");
    return 1;
  }
  printf("PASS x64-unaligned\n");
  return 0;
}
