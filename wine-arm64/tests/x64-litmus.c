// Gate G2: x64 memory ordering under FEX (native arm64 spec §8). Four litmus patterns, each forbidden by x86's TSO:
// message passing (MP) in the spin-read shape of docs/research/2026-10-02-native-arm64/probes/entitlement-probe.c,
// load buffering (LB), 2+2W and IRIW. Plain volatile int loads and stores only: no lock prefix, no fence, no
// intrinsic. Each pattern's threads are created once, not pinned, and released once per iteration by a spin flag.
// Prints `litmus <pattern> forbidden=<n> runs=<iterations>` per pattern; check.sh decides what passes.
//
// A store writes the iteration's number (2+2W: twice it, plus one for the second value) where the textbook pattern
// writes 1 or 2, so nothing is reset between iterations and a stale read is never mistaken for this one's value. A
// reader reports what it saw in the same store that says it is done, so the main thread can't read a stale report
// even with TSO off.
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

// One 128-byte cache line per variable (Apple's line size): two on one line would be ordered by coherence alone.
static _Alignas(128) volatile int go, data, flag, x, y;
enum { MP_W, LB_0, LB_1, WW_0, WW_1, IRIW_WX, IRIW_WY, IRIW_R0, IRIW_R1, ROLES };
// Each role's slot: 4 × the last iteration it finished, plus 2 when its first load read that iteration's value and 1
// when its second did.
static struct { _Alignas(128) volatile int done; } w[ROLES];
static int n;

static DWORD WINAPI worker(void *arg) {
  int role = (int)(INT_PTR)arg;
  for (int i = 1; i <= n; i++) {
    while (go != i) {}
    int r1 = 0, r2 = 0;
    switch (role) {
      case MP_W: data = i; flag = i; break;
      case LB_0: r1 = x; y = i; break;
      case LB_1: r1 = y; x = i; break;
      case WW_0: x = 2 * i; y = 2 * i + 1; break;  // x = 1; y = 2
      case WW_1: y = 2 * i; x = 2 * i + 1; break;  // y = 1; x = 2
      case IRIW_WX: x = i; break;
      case IRIW_WY: y = i; break;
      case IRIW_R0: r1 = x; r2 = y; break;
      case IRIW_R1: r1 = y; r2 = x; break;
    }
    w[role].done = 4 * i + 2 * (r1 == i) + (r2 == i);
  }
  return 0;
}

// Runs the pattern whose roles are first..first+count-1; returns 0, or 1 when a thread can't start.
static int run(const char *name, int first, int count) {
  HANDLE t[4];
  long forbidden = 0, seen = 0;
  go = data = flag = x = y = 0;
  for (int k = 0; k < count; k++) {
    w[first + k].done = 0;
    t[k] = CreateThread(NULL, 0, worker, (void *)(INT_PTR)(first + k), 0, NULL);
    if (!t[k]) {
      printf("FAIL x64-litmus: %s: CreateThread failed with error %lu\n", name, GetLastError());
      return 1;
    }
  }
  for (int i = 1; i <= n; i++) {
    go = i;
    if (first == MP_W) {  // this thread reads, as in the probe: flag then data, until flag is i or the writer is done
      int f, d;
      do { f = flag; d = data; } while (f != i && w[MP_W].done != 4 * i);
      if (f == i) seen++;
      if (f == i && d != i) forbidden++;
      while (w[MP_W].done != 4 * i) {}
      continue;
    }
    for (int k = 0; k < count; k++) while (w[first + k].done >> 2 != i) {}
    if (first == LB_0) forbidden += (w[LB_0].done & 2) && (w[LB_1].done & 2);
    // 2+2W's final values: TSO orders these reads after both writers' stores. With TSO off a read can come early and
    // see a value that isn't final yet, so the control run's 2+2W count is only approximate.
    if (first == WW_0) forbidden += x == 2 * i && y == 2 * i;
    if (first == IRIW_WX) forbidden += (w[IRIW_R0].done & 3) == 2 && (w[IRIW_R1].done & 3) == 2;
  }
  WaitForMultipleObjects(count, t, TRUE, INFINITE);
  for (int k = 0; k < count; k++) CloseHandle(t[k]);
  if (first == MP_W) printf("MP: the reader saw flag before the writer was done in %ld runs\n", seen);
  printf("litmus %s forbidden=%ld runs=%d\n", name, forbidden, n);
  fflush(stdout);
  return 0;
}

int main(int argc, char **argv) {
  n = argc > 1 ? atoi(argv[1]) : 0;
  if (n <= 0) {
    printf("FAIL x64-litmus: usage: x64-litmus.exe <iterations>\n");
    return 1;
  }
  return run("MP", MP_W, 1) || run("LB", LB_0, 2) || run("2+2W", WW_0, 2) || run("IRIW", IRIW_WX, 4);
}
