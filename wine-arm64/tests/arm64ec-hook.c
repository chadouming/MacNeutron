// The ARM64EC auxiliary IAT (Wine patch 0034): the loader fills an ARM64EC program's import entries with their EC
// targets, and puts an entry back on its check stub when a page it was resolved through is made writable, so a hook
// applied after load (on the export, or on the regular IAT entry) still runs for ARM64EC callers. An unloaded DLL's
// entries are dropped: a later allocation at its old range isn't written. One line per row, `ok <row>` or
// `FAIL <row>: <why>`, then PASS or FAIL arm64ec-hook.
//
// In ARM64EC naming (lld) `__imp_X` is the auxiliary IAT entry and `__imp_aux_X` the regular one. The targets are
// chosen so that no hook row's page carries another row's entry: in the built kernel32.dll's x64 view GetTickCount is
// an FFS on page 0x59000, GetLastError an `ff 25` alias at 0x566C0 through IAT slot 0x5B8E0, TlsGetValue an alias at
// 0x57E30 through slot 0x5C6C8.
#include <windows.h>
#include <stdio.h>

extern void *__imp_GetTickCount, *__imp_aux_GetTickCount, *__imp_GetLastError;
extern void *__imp_TlsGetValue, *__imp_aux_TlsGetValue;

typedef BOOLEAN(WINAPI *is_ec_code_fn)(ULONG_PTR);
static is_ec_code_fn is_ec_code;
static ULONG_PTR exe_base, exe_end;
static const char *row, *first_failed;
static int row_failed, rows_failed;

static void fail(const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  printf("FAIL %s: ", row);
  vprintf(fmt, args);
  printf("\n");
  va_end(args);
  row_failed = 1;
}
#define EXPECT(cond, ...) \
  do {                    \
    if (!(cond)) fail(__VA_ARGS__); \
  } while (0)

static void begin(const char *name) {
  row = name;
  row_failed = 0;
}

static void end(void) {
  if (!row_failed) {
    printf("ok %s\n", row);
    return;
  }
  if (!rows_failed++) first_failed = row;
}

// EC code outside this exe: the loader's target, not the import's check stub in this image.
static int filled(void *p) {
  return is_ec_code((ULONG_PTR)p) && ((ULONG_PTR)p < exe_base || (ULONG_PTR)p >= exe_end);
}

static void *fake_tls(DWORD index) {
  (void)index;
  return (void *)0x7eed;
}

static void row_filled(void) {
  begin("filled");
  EXPECT(filled(__imp_GetTickCount), "GetTickCount's auxiliary IAT entry is %p: not EC code outside arm64ec-hook.exe",
         __imp_GetTickCount);
  EXPECT(filled(__imp_GetLastError), "GetLastError's auxiliary IAT entry is %p: not EC code outside arm64ec-hook.exe",
         __imp_GetLastError);
  end();
}

// A detour on the export: kernel32's FFS for GetTickCount (the loader stores exports as they are) gets x64 code that
// FEX runs, `mov eax, 0x5eed; ret`.
static void row_ffs_hook(void) {
  static const BYTE hook[] = {0xb8, 0xed, 0x5e, 0x00, 0x00, 0xc3};
  BYTE saved[16];
  BYTE *p;
  DWORD old, r;

  begin("ffs-hook");
  if (!filled(__imp_GetTickCount)) {
    fail("GetTickCount's auxiliary IAT entry isn't filled before the hook (%p): the row can't test the revert",
         __imp_GetTickCount);
    end();
    return;
  }
  p = __imp_aux_GetTickCount;
  memcpy(saved, p, sizeof(saved));
  if (!VirtualProtect(p, sizeof(saved), PAGE_EXECUTE_READWRITE, &old)) {
    fail("VirtualProtect(%p) failed (error %lu)", p, GetLastError());
    end();
    return;
  }
  memcpy(p, hook, sizeof(hook));
  FlushInstructionCache(GetCurrentProcess(), p, sizeof(saved));
  r = GetTickCount();
  memcpy(p, saved, sizeof(saved));
  VirtualProtect(p, sizeof(saved), old, &old);
  FlushInstructionCache(GetCurrentProcess(), p, sizeof(saved));
  EXPECT(r == 0x5eed, "GetTickCount() returned %lu after its export was hooked: the ARM64EC call skipped the hook", r);
  EXPECT(GetTickCount() != 0x5eed, "GetTickCount() still answers 0x5eed after its export was restored");
  end();
}

static void row_per_entry(void) {
  begin("per-entry");
  EXPECT(filled(__imp_GetLastError),
         "GetLastError's auxiliary IAT entry is %p after GetTickCount's export was hooked: the revert took entries the "
         "hook doesn't touch",
         __imp_GetLastError);
  end();
}

// A hook on the regular IAT entry. Its protect of this exe's IAT page puts back every entry resolved through that
// page, which is the design: this row runs after per-entry.
static void row_iat_hook(void) {
  void *saved, *r;
  DWORD old;

  begin("iat-hook");
  if (!filled(__imp_TlsGetValue)) {
    fail("TlsGetValue's auxiliary IAT entry isn't filled before the hook (%p): the row can't test the revert",
         __imp_TlsGetValue);
    end();
    return;
  }
  if (!VirtualProtect(&__imp_aux_TlsGetValue, sizeof(void *), PAGE_READWRITE, &old)) {
    fail("VirtualProtect(%p) failed (error %lu)", (void *)&__imp_aux_TlsGetValue, GetLastError());
    end();
    return;
  }
  saved = __imp_aux_TlsGetValue;
  __imp_aux_TlsGetValue = (void *)fake_tls;
  r = TlsGetValue(0);
  __imp_aux_TlsGetValue = saved;
  VirtualProtect(&__imp_aux_TlsGetValue, sizeof(void *), old, &old);
  EXPECT(r == (void *)0x7eed, "TlsGetValue() returned %p with its IAT entry hooked: the ARM64EC call skipped the hook",
         r);
  end();
}

// An unloaded DLL's entries: version.dll (ARM64X; its imports are loaded already) loaded and freed, then its old range
// allocated, filled and made writable again. Nothing may write there.
static void row_unload(void) {
  HMODULE mod;
  BYTE *base, *mem;
  SIZE_T size, i;
  DWORD old;

  begin("unload");
  if (GetModuleHandleA("version.dll")) {
    fail("version.dll is already loaded");
    end();
    return;
  }
  if (!(mod = LoadLibraryA("version.dll"))) {
    fail("can't load version.dll (error %lu)", GetLastError());
    end();
    return;
  }
  base = (BYTE *)mod;
  size = ((IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew))->OptionalHeader.SizeOfImage;
  FreeLibrary(mod);
  if (GetModuleHandleA("version.dll")) {
    fail("version.dll stayed loaded");
    end();
    return;
  }
  if (!(mem = VirtualAlloc(base, size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE))) {
    fail("can't allocate version.dll's old range (error %lu)", GetLastError());
    end();
    return;
  }
  memset(mem, 0x5a, size);
  VirtualProtect(mem, size, PAGE_READWRITE, &old);
  for (i = 0; i < size && mem[i] == 0x5a; i++);
  EXPECT(i == size, "version.dll's old range changed at +%#zx after FreeLibrary: a stale auxiliary IAT entry was written",
         i);
  VirtualFree(mem, 0, MEM_RELEASE);
  end();
}

int main(void) {
  BYTE *exe = (BYTE *)GetModuleHandleA(NULL);

  setvbuf(stdout, NULL, _IONBF, 0);  // a crash keeps what was printed before it
  is_ec_code = (is_ec_code_fn)GetProcAddress(GetModuleHandleA("ntdll"), "RtlIsEcCode");
  if (!is_ec_code) {
    printf("FAIL arm64ec-hook: ntdll has no RtlIsEcCode\n");
    return 1;
  }
  exe_base = (ULONG_PTR)exe;
  exe_end = exe_base + ((IMAGE_NT_HEADERS *)(exe + ((IMAGE_DOS_HEADER *)exe)->e_lfanew))->OptionalHeader.SizeOfImage;

  row_filled();
  row_ffs_hook();
  row_per_entry();
  row_iat_hook();
  row_unload();
  if (!rows_failed) {
    printf("PASS arm64ec-hook\n");
    return 0;
  }
  printf("FAIL arm64ec-hook: %d of 5 rows failed (first: %s)\n", rows_failed, first_failed);
  return 1;
}
