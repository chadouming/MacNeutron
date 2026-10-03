// A section view mapped with MEM_EXTENDED_PARAMETER_EC_CODE is ARM64EC code (patch 11). This is how a JIT gets code it
// can rewrite and run: one RWX section, mapped twice, a view to write and a view to run. The run view has to be EC
// code, or the call below goes to the x64 emulator and the ARM64 instructions in it are not x64.
#include <windows.h>
#include <stdio.h>

typedef BOOLEAN(WINAPI *is_ec_code_fn)(ULONG_PTR);

int main(void) {
  is_ec_code_fn is_ec_code = (is_ec_code_fn)GetProcAddress(GetModuleHandleA("ntdll"), "RtlIsEcCode");
  static const DWORD code[] = {0x528000e0, 0xd65f03c0};  // mov w0, #7; ret
  MEM_EXTENDED_PARAMETER p = {0};
  HANDLE section;
  BYTE *rw, *rx;
  int got;
  setvbuf(stdout, NULL, _IONBF, 0);  // a crash keeps what was printed before it
  if (!is_ec_code) {
    printf("FAIL arm64ec-viewec: ntdll has no RtlIsEcCode\n");
    return 1;
  }
  section = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_EXECUTE_READWRITE, 0, 0x10000, NULL);
  if (!section) {
    printf("FAIL arm64ec-viewec: CreateFileMapping: error %lu\n", GetLastError());
    return 1;
  }
  rw = MapViewOfFile3(section, GetCurrentProcess(), NULL, 0, 0, 0, PAGE_READWRITE, NULL, 0);
  p.Type = MemExtendedParameterAttributeFlags;
  p.ULong64 = MEM_EXTENDED_PARAMETER_EC_CODE;
  rx = MapViewOfFile3(section, GetCurrentProcess(), NULL, 0, 0, 0, PAGE_EXECUTE_READ, &p, 1);
  if (!rw || !rx) {
    printf("FAIL arm64ec-viewec: MapViewOfFile3: RW %p, RX %p, error %lu\n", rw, rx, GetLastError());
    return 1;
  }
  printf("RW view %p, RX view %p\n", rw, rx);
  printf("RtlIsEcCode(rx) = %u, RtlIsEcCode(rw) = %u\n", is_ec_code((ULONG_PTR)rx), is_ec_code((ULONG_PTR)rw));
  if (!is_ec_code((ULONG_PTR)rx)) {
    printf("FAIL arm64ec-viewec: RtlIsEcCode(rx) == FALSE\n");
    return 1;
  }
  if (is_ec_code((ULONG_PTR)rw)) {
    printf("FAIL arm64ec-viewec: RtlIsEcCode(rw) == TRUE\n");
    return 1;
  }
  memcpy(rw, code, sizeof(code));
  FlushInstructionCache(GetCurrentProcess(), rx, sizeof(code));
  got = ((int (*)(void))rx)();
  printf("the RX view returned %d\n", got);
  if (got != 7) {
    printf("FAIL arm64ec-viewec: wanted 7\n");
    return 1;
  }
  printf("PASS arm64ec-viewec\n");
  return 0;
}
