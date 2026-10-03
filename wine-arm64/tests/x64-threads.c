// Gate G1: x64 threads under FEX. 32 threads each keep their own TLS value, both a TlsAlloc slot and a
// __declspec(thread) variable; all of them park on one manual-reset event, which a single SetEvent releases; then
// each adds 100000 to a counter under one critical section.
#include <windows.h>
#include <stdio.h>

#define THREADS 32
#define ADDS 100000

static DWORD tls;
static HANDLE go;
static CRITICAL_SECTION cs;
static volatile LONG ready;
static volatile LONG counter;
static __declspec(thread) volatile ULONG_PTR implicit;  // the exe's TLS directory: one copy per thread, from the loader

// Returns 0, or 3 when the TlsAlloc slot isn't this thread's value, 4 when the __declspec(thread) one isn't.
static DWORD mine(ULONG_PTR i) {
  if ((ULONG_PTR)TlsGetValue(tls) != i) return 3;
  return implicit == i ? 0 : 4;
}

// Returns 0, or a non-zero step that went wrong.
static DWORD WINAPI worker(void *arg) {
  ULONG_PTR i = (ULONG_PTR)arg;  // 1..THREADS: 0 is what an unset slot reads
  if (!TlsSetValue(tls, (void *)i)) return 1;
  implicit = i;
  InterlockedIncrement(&ready);
  if (WaitForSingleObject(go, 10000) != WAIT_OBJECT_0) return 2;
  DWORD rc = mine(i);
  if (rc) return rc;
  for (int n = 0; n < ADDS; n++) {
    EnterCriticalSection(&cs);
    counter = counter + 1;  // not atomic: only the critical section keeps it right
    LeaveCriticalSection(&cs);
  }
  return mine(i);
}

int main(void) {
  OutputDebugStringA("jit: start");  // gate G5 counts W^X flips after this line (check.sh g5-jit)
  HANDLE threads[THREADS];
  tls = TlsAlloc();
  go = CreateEventW(NULL, TRUE, FALSE, NULL);
  InitializeCriticalSection(&cs);
  if (tls == TLS_OUT_OF_INDEXES || !go) {
    printf("FAIL x64-threads: TlsAlloc or CreateEvent failed with error %lu\n", GetLastError());
    return 1;
  }
  for (ULONG_PTR i = 1; i <= THREADS; i++) {
    threads[i - 1] = CreateThread(NULL, 0, worker, (void *)i, 0, NULL);
    if (!threads[i - 1]) {
      printf("FAIL x64-threads: CreateThread %lu failed with error %lu\n", (ULONG)i, GetLastError());
      return 1;
    }
  }
  for (int ms = 0; ready < THREADS && ms < 10000; ms++) Sleep(1);
  printf("%ld threads parked on the event, counter %ld\n", ready, counter);
  if (ready != THREADS || counter != 0) {
    printf("FAIL x64-threads: wanted %d threads parked and the counter at 0 before SetEvent\n", THREADS);
    return 1;
  }
  SetEvent(go);  // once: a manual-reset event releases every waiter
  if (WaitForMultipleObjects(THREADS, threads, TRUE, 30000) != WAIT_OBJECT_0) {
    printf("FAIL x64-threads: the threads did not all finish within 30 s\n");
    return 1;
  }
  for (int i = 0; i < THREADS; i++) {
    DWORD rc = 99;
    GetExitCodeThread(threads[i], &rc);
    if (rc) {
      printf("FAIL x64-threads: thread %d failed at step %lu (1 TlsSetValue, 2 wait, 3 TlsGetValue, 4 __declspec(thread))\n", i + 1, rc);
      return 1;
    }
  }
  printf("every thread read back its own TLS values; counter %ld\n", counter);
  if (counter != THREADS * ADDS) {
    printf("FAIL x64-threads: wanted counter %d\n", THREADS * ADDS);
    return 1;
  }
  printf("PASS x64-threads\n");
  return 0;
}
