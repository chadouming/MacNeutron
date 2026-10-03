// RtlIsEcCode on addresses the ARM64EC code bitmap doesn't cover (patch 9): a kernel address and the first
// non-canonical user one answer FALSE instead of reading past the end of the bitmap, and EC code still answers TRUE.
#include <windows.h>
#include <stdio.h>

typedef BOOLEAN(WINAPI *is_ec_code_fn)(ULONG_PTR);

static int check(is_ec_code_fn is_ec_code, ULONG_PTR ptr, BOOLEAN want) {
  BOOLEAN got = 0;
  DWORD code = 0;
  __try {
    got = is_ec_code(ptr);
  } __except (code = GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) {
    printf("FAIL arm64ec-isec: RtlIsEcCode(%#llx) raised %#lx\n", (unsigned long long)ptr, (unsigned long)code);
    return 0;
  }
  printf("RtlIsEcCode(%#llx) = %u\n", (unsigned long long)ptr, got);
  if (!got != !want) {
    printf("FAIL arm64ec-isec: RtlIsEcCode(%#llx) is %u, wanted %u\n", (unsigned long long)ptr, got, want);
    return 0;
  }
  return 1;
}

int main(void) {
  is_ec_code_fn is_ec_code = (is_ec_code_fn)GetProcAddress(GetModuleHandleA("ntdll"), "RtlIsEcCode");
  setvbuf(stdout, NULL, _IONBF, 0);  // a crash keeps what was printed before it
  if (!is_ec_code) {
    printf("FAIL arm64ec-isec: ntdll has no RtlIsEcCode\n");
    return 1;
  }
  printf("started: RtlIsEcCode at %p\n", (void *)is_ec_code);
  if (check(is_ec_code, 0xffff800000001000, FALSE) && check(is_ec_code, 0x800000000000, FALSE) &&
      check(is_ec_code, (ULONG_PTR)main, TRUE)) {
    printf("PASS arm64ec-isec\n");
    return 0;
  }
  return 1;
}
