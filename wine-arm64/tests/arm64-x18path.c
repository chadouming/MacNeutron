// Gate S5's T2 and T4 and measurement M2 (ship-base spec §9): the ways a thread crosses between PE and unix code,
// each followed by a check that x18 is still this thread's TEB. The TEB comes from the kernel (NtQueryInformationThread,
// read once per thread), never from NtCurrentTeb(), which reads x18 itself; x18 is read raw, never dereferenced. Also
// built as x64-x18path.exe, which runs under FEX: x64 code has no x18, so there the rows and the PASS line are the gate.
//   (no argument)  one row `ok <path>` per path;
//   stress         4 threads alternate a syscall and a unix call for 3 s while a fifth suspends them, reads their
//                  context and resumes them (SIGUSR1), over and over;
//   time           the median ns per call of 10^6 NtQuerySystemTime (`time syscall`) and 10^6
//                  GetSystemTimePreciseAsFileTime (`time unixcall`), in 100 timed batches.
#include <windows.h>
#include <winternl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef __aarch64__
#define NAME "arm64-x18path"
#else
#define NAME "x64-x18path"
#endif

NTSTATUS NTAPI NtQuerySystemTime(LARGE_INTEGER *);
NTSTATUS NTAPI NtReadFile(HANDLE, HANDLE, PIO_APC_ROUTINE, void *, IO_STATUS_BLOCK *, void *, ULONG, LARGE_INTEGER *,
                          ULONG *);

static volatile LONG mismatches;

// ThreadBasicInformation's layout (mingw's winternl.h lacks it).
typedef struct {
  LONG ExitStatus;
  void *TebBaseAddress;
  CLIENT_ID ClientId;
  ULONG_PTR AffinityMask;
  LONG Priority, BasePriority;
} TBI;
static void *kernel_teb(void) {
  TBI tbi;
  if (NtQueryInformationThread(GetCurrentThread(), (THREADINFOCLASS)0, &tbi, sizeof(tbi), NULL)) return NULL;
  return tbi.TebBaseAddress;
}

// Counts a mismatch when x18 isn't teb (this thread's, from kernel_teb()). x64 code has no x18 to check.
static void x18_check(void *teb) {
#ifdef __aarch64__
  void *v;
  __asm__ volatile("mov %0, x18" : "=r"(v));
  if (v != teb || !teb) InterlockedIncrement(&mismatches);
#else
  (void)teb;
#endif
}

// Clang's __try only covers faults at call sites, so each faulting instruction sits in its own function.
__declspec(noinline) static void poke(volatile int *p) { *p = 1; }
__declspec(noinline) static void breakpoint(void) { __debugbreak(); }
__declspec(noinline) static void illegal(void) {
#ifdef __aarch64__
  __asm__ volatile("udf #0");
#else
  __asm__ volatile("ud2");
#endif
}

// A structured exception from one of the above: the code __except saw.
static DWORD seh(void (*f)(void)) {
  DWORD code = 0;
  __try {
    f();
  } __except (code = GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) {
  }
  return code;
}
static void av(void) { poke((volatile int *)16); }

static const char *path_av(void) { return seh(av) == EXCEPTION_ACCESS_VIOLATION ? NULL : "no access violation"; }
static const char *path_debugbreak(void) { return seh(breakpoint) == EXCEPTION_BREAKPOINT ? NULL : "no breakpoint"; }
static const char *path_sigill(void) {
  return seh(illegal) == EXCEPTION_ILLEGAL_INSTRUCTION ? NULL : "no illegal instruction";
}

// Suspend/Get/SetThreadContext on a thread that loops through a syscall and its own x18 check (under FEX in the x64
// build: a FEX-suspended thread). Setting the context it read sends it back through the dispatcher's slow path.
struct busy {
  volatile LONG stop;
  volatile LONG64 loops;
};
static DWORD WINAPI busy_loop(void *arg) {
  struct busy *b = arg;
  void *teb = kernel_teb();
  LARGE_INTEGER t;
  while (!b->stop) {
    NtQuerySystemTime(&t);
    x18_check(teb);
    for (volatile int i = 0; i < 100; i++) {}
    x18_check(teb);
    b->loops++;
  }
  return 0;
}
static const char *path_suspend(void) {
  struct busy b = {0};
  HANDLE h = CreateThread(NULL, 0, busy_loop, &b, 0, NULL);
  const char *err = NULL;
  CONTEXT ctx;
  if (!h) return "CreateThread failed";
  while (!b.loops) Sleep(1);
  for (int i = 0; i < 200 && !err; i++) {
    if (SuspendThread(h) == (DWORD)-1) err = "SuspendThread failed";
    memset(&ctx, 0, sizeof(ctx));
    ctx.ContextFlags = CONTEXT_FULL;
    if (!err && !GetThreadContext(h, &ctx)) err = "GetThreadContext failed";
    if (!err && !SetThreadContext(h, &ctx)) err = "SetThreadContext failed";
    if (ResumeThread(h) == (DWORD)-1 && !err) err = "ResumeThread failed";
  }
  LONG64 seen = b.loops;
  Sleep(10);
  if (!err && b.loops == seen) err = "the thread stopped running";
  b.stop = 1;
  WaitForSingleObject(h, INFINITE);
  CloseHandle(h);
  return err;
}

// SendMessage to a window of this thread: win32u (unix) calls the window procedure through KeUserModeCallback.
static void *callback_teb;
static LONG callbacks;
static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg != WM_USER) return DefWindowProcA(hwnd, msg, wp, lp);
  x18_check(callback_teb);
  callbacks++;
  return 42;
}
static const char *path_callback(void) {
  WNDCLASSA wc = {.lpfnWndProc = wndproc, .lpszClassName = NAME};
  const char *err = NULL;
  HWND hwnd;
  callback_teb = kernel_teb();
  if (!RegisterClassA(&wc)) return "RegisterClass failed";
  if (!(hwnd = CreateWindowExA(0, NAME, NAME, 0, 0, 0, 0, 0, HWND_MESSAGE, NULL, NULL, NULL))) return "CreateWindow failed";
  for (int i = 0; i < 100 && !err; i++)
    if (SendMessageA(hwnd, WM_USER, 0, 0) != 42) err = "SendMessage didn't return the window procedure's result";
  DestroyWindow(hwnd);
  if (!err && callbacks != 100) err = "the window procedure didn't run 100 times";
  return err;
}

// NtReadFile into reserved memory: tests the error return. read() into the reserved buffer fails with EFAULT, no
// signal, and NtReadFile returns STATUS_ACCESS_VIOLATION. The fault path through __wine_syscall_dispatcher_return
// is the raw-syscall row's.
static const char *path_ntreadfile(void) {
  char exe[MAX_PATH];
  IO_STATUS_BLOCK io;
  void *buf = VirtualAlloc(NULL, 0x10000, MEM_RESERVE, PAGE_NOACCESS);
  HANDLE f;
  NTSTATUS s;
  if (!buf || !GetModuleFileNameA(NULL, exe, sizeof(exe))) return "no buffer or no exe path";
  f = CreateFileA(exe, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
  if (f == INVALID_HANDLE_VALUE) return "can't open the exe";
  s = NtReadFile(f, NULL, NULL, NULL, &io, buf, 4096, NULL, NULL);
  CloseHandle(f);
  VirtualFree(buf, 0, MEM_RELEASE);
  return s == STATUS_ACCESS_VIOLATION ? NULL : "NtReadFile didn't return STATUS_ACCESS_VIOLATION";
}

// A user APC, delivered by the dispatcher on the way out of an alertable wait.
static LONG apcs;
static void CALLBACK apc(ULONG_PTR teb) {
  x18_check((void *)teb);
  apcs++;
}
static const char *path_apc(void) {
  if (!QueueUserAPC(apc, GetCurrentThread(), (ULONG_PTR)kernel_teb())) return "QueueUserAPC failed";
  if (SleepEx(0, TRUE) != WAIT_IO_COMPLETION || apcs != 1) return "the APC didn't run";
  return NULL;
}

// 200 threads, one after the other, each checking its own x18 once it runs.
static DWORD WINAPI short_thread(void *arg) {
  x18_check(kernel_teb());
  return 7;
}
static const char *path_threads(void) {
  for (int i = 0; i < 200; i++) {
    DWORD rc = 0;
    HANDLE h = CreateThread(NULL, 0, short_thread, NULL, 0, NULL);
    if (!h) return "CreateThread failed";
    WaitForSingleObject(h, INFINITE);
    GetExitCodeThread(h, &rc);
    CloseHandle(h);
    if (rc != 7) return "a thread didn't run";
  }
  return NULL;
}

// A syscall issued by hand, not through ntdll's stub: NtQuerySystemTime into a good buffer, into an unmapped one (the
// fault returns through the dispatcher's return path) and an invalid syscall number.
#ifdef __aarch64__
// raw_syscall(arg, id, dispatcher): what ntdll's aarch64 stub does.
NTSTATUS raw_syscall(void *arg, ULONG id, void *dispatcher);
__asm__(".text\n\t.p2align 2\n\t.globl raw_syscall\n\t.def raw_syscall\n\t.scl 2\n\t.type 32\n\t.endef\n"
        "raw_syscall:\n\tmov x8, x1\n\tmov x9, x30\n\tblr x2\n\tret");
static void *dispatcher;
static NTSTATUS sys(void *arg, ULONG id) { return raw_syscall(arg, id, dispatcher); }
// The stub's first instruction is mov x8, #id (movz).
static const char *syscall_id(const BYTE *stub, ULONG *id) {
  void **p = (void **)GetProcAddress(GetModuleHandleA("ntdll.dll"), "__wine_syscall_dispatcher");
  ULONG insn = *(const ULONG *)stub;
  if (!p || !*p) return "no __wine_syscall_dispatcher";
  dispatcher = *p;
  if ((insn & 0xffe0001f) != 0xd2800008) return "NtQuerySystemTime doesn't start with mov x8, #id";
  *id = (insn >> 5) & 0xffff;
  return NULL;
}
#else
// The x64 stub: mov %rcx,%r10; mov $id,%eax; ...; syscall. FEX turns the instruction into a syscall.
static NTSTATUS sys(void *arg, ULONG id) {
  ULONG64 ret = id;
  register void *r10 __asm__("r10") = arg;
  __asm__ volatile("syscall"
                   : "+a"(ret), "+r"(r10)
                   :
                   : "rcx", "rdx", "r8", "r9", "r11", "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "memory", "cc");
  return (NTSTATUS)ret;
}
// The export may be a fast-forward sequence (mov %rsp,%rax; mov %rbx,0x20(%rax); push %rbp; pop %rbp; jmp <stub>).
static const char *syscall_id(const BYTE *stub, ULONG *id) {
  for (int hop = 0; hop < 2; hop++) {
    if (!memcmp(stub, "\x4c\x8b\xd1\xb8", 4)) {
      *id = *(const ULONG *)(stub + 4);
      return NULL;
    }
    if (memcmp(stub, "\x48\x8b\xc4", 3) || stub[9] != 0xe9) break;
    stub += 14 + *(const LONG *)(stub + 10);
  }
  return "NtQuerySystemTime is neither the x64 syscall stub nor a jump to it";
}
#endif
static const char *path_raw_syscall(void) {
  LARGE_INTEGER t = {0};
  ULONG id;
  const char *err = syscall_id((const BYTE *)GetProcAddress(GetModuleHandleA("ntdll.dll"), "NtQuerySystemTime"), &id);
  if (err) return err;
  if (sys(&t, id) || !t.QuadPart) return "NtQuerySystemTime failed";
  if (sys((void *)16, id) != STATUS_ACCESS_VIOLATION) return "NtQuerySystemTime((void *)16) didn't fault";
  if (sys(&t, 0xfff) != (NTSTATUS)0xc000001c /* STATUS_INVALID_SYSTEM_SERVICE */) return "syscall 0xfff wasn't refused";
  return NULL;
}

// T4: 4 threads alternate a syscall and a unix call while a fifth suspends them, reads their context and resumes
// them, over and over, for 3 s.
#define WORKERS 4
static volatile LONG stress_stop;
static volatile LONG64 stress_calls;
static DWORD WINAPI stress_worker(void *arg) {
  void *teb = kernel_teb();
  LONG64 n = 0;
  LARGE_INTEGER t;
  FILETIME ft;
  while (!stress_stop) {
    NtQuerySystemTime(&t);
    x18_check(teb);
    GetSystemTimePreciseAsFileTime(&ft);
    x18_check(teb);
    n++;
  }
  InterlockedAdd64(&stress_calls, 2 * n);
  return 0;
}
static const char *path_stress(void) {
  HANDLE h[WORKERS];
  const char *err = NULL;
  LONG64 suspends = 0;
  DWORD end;
  CONTEXT ctx;
  for (int i = 0; i < WORKERS; i++)
    if (!(h[i] = CreateThread(NULL, 0, stress_worker, NULL, 0, NULL))) return "CreateThread failed";
  end = GetTickCount() + 3000;
  while ((LONG)(GetTickCount() - end) < 0 && !err)
    for (int i = 0; i < WORKERS && !err; i++) {
      if (SuspendThread(h[i]) == (DWORD)-1) err = "SuspendThread failed";
      memset(&ctx, 0, sizeof(ctx));
      ctx.ContextFlags = CONTEXT_FULL;
      if (!err && !GetThreadContext(h[i], &ctx)) err = "GetThreadContext failed";
      if (ResumeThread(h[i]) == (DWORD)-1 && !err) err = "ResumeThread failed";
      suspends++;
    }
  stress_stop = 1;
  WaitForMultipleObjects(WORKERS, h, TRUE, INFINITE);
  printf("info stress: %lld calls, %lld suspends\n", stress_calls, suspends);
  return err;
}

// M2: the median ns per call over 100 timed batches of 10^4 calls, after one batch of warm-up.
static int cmp(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return x < y ? -1 : x > y;
}
static double median_ns(int unixcall) {
  enum { BATCHES = 100, N = 10000 };
  double t[BATCHES];
  LARGE_INTEGER f, a, b, st;
  FILETIME ft;
  QueryPerformanceFrequency(&f);
  for (int k = -1; k < BATCHES; k++) {
    QueryPerformanceCounter(&a);
    for (int i = 0; i < N; i++)
      if (unixcall) GetSystemTimePreciseAsFileTime(&ft);
      else NtQuerySystemTime(&st);
    QueryPerformanceCounter(&b);
    if (k >= 0) t[k] = (double)(b.QuadPart - a.QuadPart) * 1e9 / (double)f.QuadPart / N;
  }
  qsort(t, BATCHES, sizeof(*t), cmp);
  return t[BATCHES / 2];
}

static int failures;
// Runs a path, then checks this thread's x18; ok <path> when the path did what it should and no thread saw a
// mismatch meanwhile.
static void row(const char *path, const char *(*f)(void), void *teb) {
  LONG before = mismatches;
  const char *err = f();
  x18_check(teb);
  if (!err && mismatches != before) err = "x18 was not the TEB";
  if (err) {
    printf("FAIL %s: %s\n", path, err);
    failures++;
  } else
    printf("ok %s\n", path);
  fflush(stdout);
}

int main(int argc, char **argv) {
  void *teb = kernel_teb();
  const char *mode = argc > 1 ? argv[1] : "";
  if (!strcmp(mode, "time")) {
    printf("time syscall %.1f\n", median_ns(0));
    printf("time unixcall %.1f\n", median_ns(1));
  } else if (!strcmp(mode, "stress"))
    row("stress", path_stress, teb);
  else if (!*mode) {
    row("seh-av", path_av, teb);
    row("debugbreak", path_debugbreak, teb);
    row("sigill", path_sigill, teb);
    row("suspend", path_suspend, teb);
    row("callback", path_callback, teb);
    row("ntreadfile", path_ntreadfile, teb);
    row("apc", path_apc, teb);
    row("threads", path_threads, teb);
    row("raw-syscall", path_raw_syscall, teb);
  } else {
    printf("FAIL " NAME ": usage: " NAME " [stress|time]\n");
    return 1;
  }
#ifdef __aarch64__
  printf("x18path: %ld mismatches\n", mismatches);
#endif
  if (failures) {
    printf("FAIL " NAME ": %d paths failed\n", failures);
    return 1;
  }
  printf("PASS " NAME "\n");
  return 0;
}
