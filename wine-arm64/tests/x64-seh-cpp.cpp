// Gate G1: a C++ throw/catch in x64 code under FEX (libunwind's SEH personality unwinds through RtlUnwindEx).
#include <windows.h>
#include <stdio.h>

__attribute__((noinline)) static void raise(int v) { throw v; }

int main() {
  OutputDebugStringA("jit: start");  // gate G5 counts W^X flips after this line (check.sh g5-jit)
  int got = 0;
  try {
    raise(42);
  } catch (int v) {
    got = v;
  }
  printf("caught %d\n", got);
  if (got != 42) {
    printf("FAIL x64-seh-cpp: wanted 42\n");
    return 1;
  }
  printf("PASS x64-seh-cpp\n");
  return 0;
}
