// Gate G1: x64 structured exceptions under FEX. A write through (int *)8 inside __try reaches __except with
// 0xC0000005; a vectored handler, added after that, sees exactly one exception for a second access violation.
#include <windows.h>
#include <stdio.h>

static LONG seen;

static LONG CALLBACK vectored(EXCEPTION_POINTERS *e) {
  InterlockedIncrement(&seen);
  printf("vectored handler saw 0x%08lx\n", e->ExceptionRecord->ExceptionCode);
  return EXCEPTION_CONTINUE_SEARCH;  // the __except below still has to run
}

// Clang's __try only covers faults at call sites, so the store sits in its own function.
__declspec(noinline) static void poke(volatile int *p) { *p = 1; }

static DWORD fault(void) {
  DWORD code = 0;
  __try {
    poke((volatile int *)8);
  } __except (code = GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) {
  }
  return code;
}

int main(void) {
  OutputDebugStringA("jit: start");  // gate G5 counts W^X flips after this line (check.sh g5-jit)
  DWORD code = fault();
  printf("__except caught 0x%08lx\n", code);
  if (code != 0xC0000005) {
    printf("FAIL x64-seh: wanted 0xc0000005 from __except, got 0x%08lx\n", code);
    return 1;
  }
  void *handler = AddVectoredExceptionHandler(1, vectored);
  if (!handler) {
    printf("FAIL x64-seh: AddVectoredExceptionHandler failed\n");
    return 1;
  }
  code = fault();
  RemoveVectoredExceptionHandler(handler);
  printf("second __except caught 0x%08lx; the vectored handler saw %ld exceptions\n", code, seen);
  if (code != 0xC0000005 || seen != 1) {
    printf("FAIL x64-seh: wanted 0xc0000005 seen once by the vectored handler\n");
    return 1;
  }
  printf("PASS x64-seh\n");
  return 0;
}
