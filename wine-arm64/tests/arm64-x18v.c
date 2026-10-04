// Gate S5's T1 (ship-base spec §9), from the sub-project 1 trial's x18v.c: does x18 == this thread's TEB survive
// preemption? 16 threads spin for 1 s, each comparing raw x18 with its TEB as the kernel reports it
// (NtQueryInformationThread, read once per thread; NtCurrentTeb() would read x18 itself). x18 is read, never
// dereferenced, so a clobbered x18 is counted instead of crashing.
#include <windows.h>
#include <winternl.h>
#include <stdio.h>

#define THREADS 16

static volatile LONG stop;
static volatile LONG64 checks, bad, badzero, threads, badstart;

static inline void *read_x18(void) {
  void *v;
  __asm__ volatile("mov %0, x18" : "=r"(v));
  return v;
}

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

static DWORD WINAPI spin(void *arg) {
  void *teb = kernel_teb();
  LONG64 c = 0, b = 0, z = 0;
  if (!teb || read_x18() != teb) InterlockedIncrement64(&badstart);
  while (!stop) {
    for (int i = 0; i < 100000; i++) {
      void *v = read_x18();
      if (v != teb) {
        b++;
        if (!v) z++;
      }
    }
    c += 100000;
  }
  InterlockedAdd64(&checks, c);
  InterlockedAdd64(&bad, b);
  InterlockedAdd64(&badzero, z);
  InterlockedIncrement64(&threads);
  return 0;
}

int main(void) {
  HANDLE th[THREADS];
  for (int i = 0; i < THREADS; i++) th[i] = CreateThread(NULL, 0, spin, NULL, 0, NULL);
  Sleep(1000);
  stop = 1;
  WaitForMultipleObjects(THREADS, th, TRUE, INFINITE);
  printf("info x18v: %lld checks, %lld zero, %lld bad at start\n", checks, badzero, badstart);
  printf("x18v: %lld threads, %lld mismatches\n", threads, bad + badstart);
  if (threads != THREADS || bad || badstart) {
    printf("FAIL arm64-x18v\n");
    return 1;
  }
  printf("PASS arm64-x18v\n");
  return 0;
}
