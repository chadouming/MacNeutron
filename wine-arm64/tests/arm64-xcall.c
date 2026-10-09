// Measurement lanes (batch Task 2): calls out of a program into Wine's DLLs, one source built as ARM64
// (arm64-xcall.exe), ARM64EC (arm64ec-xcall.exe) and x64 (x64-xcall.exe, under FEX), -O2 -fno-builtin so every memcpy,
// strlen and qsort is a call into the CRT. Prints `time <row> <ns>`, the median ns per call over 100 timed batches
// after one batch of warm-up, then `PASS <program>` (the exe's file name without .exe). In the x64 lane each call crosses
// into ARM64EC code: istream-addref through a vtable slot with no fast-forward sequence (the bare crossing), the
// exports through theirs; qsort's comparator crosses back for every comparison.
#define COBJMACROS
#include <windows.h>
#include <shlwapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define opaque(v) __asm__ volatile("" : "+r"(v))
#define BATCHES 100

static double ns_per_tick, t[BATCHES];
static char src[(1 << 20) + 1], dst[(1 << 20) + 1], str[1024];
static int sorted[4096], unsorted[4096];

static int cmp_double(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return (x > y) - (x < y);
}
static int cmp_int(const void *a, const void *b) {
  int x = *(const int *)a, y = *(const int *)b;
  return (x > y) - (x < y);
}

// time <row> <ns>: n runs of the statements per batch.
#define TIME(row, n, ...)                                                 \
  do {                                                                    \
    for (int k = -1; k < BATCHES; k++) {                                  \
      LARGE_INTEGER a, b;                                                 \
      QueryPerformanceCounter(&a);                                        \
      for (int i = 0; i < (n); i++) { __VA_ARGS__; }                      \
      QueryPerformanceCounter(&b);                                        \
      if (k >= 0) t[k] = (double)(b.QuadPart - a.QuadPart) * ns_per_tick / (n); \
    }                                                                     \
    qsort(t, BATCHES, sizeof *t, cmp_double);                             \
    printf("time %s %.1f\n", (row), t[BATCHES / 2]);                      \
  } while (0)

int main(void) {
  static const struct { const char *row; int size, n; } copies[] = {
      {"memcpy-16", 16, 10000}, {"memcpy-256", 256, 10000}, {"memcpy-4k", 4096, 1000}, {"memcpy-1m", 1 << 20, 10}};
  char self[MAX_PATH], *name, *dot;
  LARGE_INTEGER f;
  DWORD tls = TlsAlloc();
  IStream *s = SHCreateMemStream(NULL, 0);
  unsigned x = 1;
  GetModuleFileNameA(NULL, self, sizeof self);
  name = strrchr(self, '\\') ? strrchr(self, '\\') + 1 : self;
  if ((dot = strrchr(name, '.'))) *dot = 0;
  setvbuf(stdout, NULL, _IONBF, 0);
  if (tls == TLS_OUT_OF_INDEXES || !TlsSetValue(tls, str) || !s) {
    printf("FAIL %s: setup: error %lu\n", name, GetLastError());
    return 1;
  }
  QueryPerformanceFrequency(&f);
  ns_per_tick = 1e9 / (double)f.QuadPart;
  memset(src, 'a', sizeof src);
  memset(str, 'a', sizeof str - 1);
  for (int i = 0; i < 4096; i++) unsorted[i] = (int)(x = x * 1103515245 + 12345) >> 1;

  TIME("get-current-thread-id", 10000, DWORD v = GetCurrentThreadId(); opaque(v));
  TIME("get-last-error", 10000, DWORD v = GetLastError(); opaque(v));
  TIME("tls-get-value", 10000, void *v = TlsGetValue(tls); opaque(v));
  TIME("get-tick-count", 10000, DWORD v = GetTickCount(); opaque(v));
  TIME("qpc", 10000, LARGE_INTEGER v; QueryPerformanceCounter(&v));
  TIME("istream-addref", 10000, ULONG v = IStream_AddRef(s); opaque(v));
  for (int c = 0; c < 4; c++) {
    for (int off = 0; off < 2; off++) {
      char row[32], *d = dst + off;
      const char *p = src + off;
      size_t size = copies[c].size;
      snprintf(row, sizeof row, "%s%s", copies[c].row, off ? "-offset" : "");
      TIME(row, copies[c].n, opaque(d); memcpy(d, p, size));
    }
  }
  TIME("strlen-1k", 10000, const char *p = str; opaque(p); size_t v = strlen(p); opaque(v));
  TIME("qsort-4k", 10, memcpy(sorted, unsorted, sizeof sorted); qsort(sorted, 4096, sizeof *sorted, cmp_int));
  for (int i = 1; i < 4096; i++)
    if (sorted[i - 1] > sorted[i]) {
      printf("FAIL %s: qsort left %d before %d\n", name, sorted[i - 1], sorted[i]);
      return 1;
    }
  printf("PASS %s\n", name);
  return 0;
}
