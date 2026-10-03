// Gate G1: RDTSC under FEX. Each of 8 threads reads it 1e6 times and never sees it go backwards; its rate against
// QueryPerformanceCounter over 200 ms is within 2% of the TSC frequency CPUID reports (leaf 0x15: crystal × EBX / EAX,
// else leaf 0x16's base MHz; with neither, the rate is only printed). Games calibrate RDTSC. FEX's RDTSC is a plain
// CNTVCT_EL0 read and leaf 0x15 is CNTFRQ_EL0: an ordinary macOS 27 process sees that counter tick ~4.8 GHz against a
// CNTFRQ of 1 GHz; this runtime's processes see both at 1 GHz, and this test keeps it that way.
#include <windows.h>
#include <intrin.h>
#include <math.h>
#include <stdio.h>

#define THREADS 8
#define READS 1000000

// Returns 0, or the read at which the counter went backwards.
static DWORD WINAPI reader(void *arg) {
  (void)arg;
  unsigned long long last = __rdtsc();
  for (DWORD n = 1; n < READS; n++) {
    unsigned long long t = __rdtsc();
    if (t < last) return n;
    last = t;
  }
  return 0;
}

int main(void) {
  HANDLE threads[THREADS];
  for (int i = 0; i < THREADS; i++) threads[i] = CreateThread(NULL, 0, reader, NULL, 0, NULL);
  if (WaitForMultipleObjects(THREADS, threads, TRUE, 30000) != WAIT_OBJECT_0) {
    printf("FAIL x64-tsc: the reader threads did not finish within 30 s\n");
    return 1;
  }
  for (int i = 0; i < THREADS; i++) {
    DWORD at = 99;
    GetExitCodeThread(threads[i], &at);
    if (at) {
      printf("FAIL x64-tsc: thread %d saw RDTSC go backwards at read %lu\n", i, at);
      return 1;
    }
  }
  printf("%d threads x %d reads: RDTSC never went backwards\n", THREADS, READS);

  int r[4];
  double want = 0;
  __cpuid(r, 0);
  int max = r[0];
  if (max >= 0x15) {
    __cpuid(r, 0x15);
    printf("info CPUID 0x15: eax %u ebx %u ecx %u\n", r[0], r[1], r[2]);
    if (r[0] && r[1] && r[2]) want = (double)(unsigned)r[2] * (unsigned)r[1] / (unsigned)r[0];
  }
  if (!want && max >= 0x16) {
    __cpuid(r, 0x16);
    printf("info CPUID 0x16: eax %u\n", r[0]);
    want = (r[0] & 0xffff) * 1e6;
  }

  LARGE_INTEGER freq, q0, q1;
  QueryPerformanceFrequency(&freq);
  QueryPerformanceCounter(&q0);
  unsigned long long t0 = __rdtsc();
  Sleep(200);
  QueryPerformanceCounter(&q1);
  unsigned long long t1 = __rdtsc();
  double secs = (double)(q1.QuadPart - q0.QuadPart) / freq.QuadPart;
  double hz = (t1 - t0) / secs;
  printf("info QueryPerformanceFrequency %lld Hz; RDTSC ran at %.0f Hz over %.1f ms\n", freq.QuadPart, hz, secs * 1e3);
  if (!want) {
    printf("info CPUID reports no TSC frequency: monotonic only\n");
  } else {
    printf("info CPUID says %.0f Hz; measured / CPUID = %.4f\n", want, hz / want);
    if (fabs(hz / want - 1) > 0.02) {
      printf("FAIL x64-tsc: RDTSC runs at %.4f x the CPUID frequency (more than 2%% off)\n", hz / want);
      return 1;
    }
  }
  printf("PASS x64-tsc\n");
  return 0;
}
