// Gate S3 (ship-base spec §6): Windows synchronisation objects as msync (Wine patch 0015) or the plain wineserver
// serves them; check.sh's msync step runs it under FEX in both modes. One line per gated row, `ok <row>` or
// `FAIL <row>: <why>`; then the reported rows: `info pulse-event` (PulseEvent can miss a waiter under msync) and
// `time <row> <ns>` (the median of the batches, per operation); then `PASS x64-sync` when every gated row passed.
// The wait-all rows (Wine patch 0031) print their own `info` lines before their verdict: `info wait-all-duplicate`, each
// duplicate's answer (check.sh gates mode 1's), and the two races' counts. A time row whose wait times out prints
// `FAIL <row>: stuck` instead of its time and fails the run. Blocking waits in those rows run on worker threads with
// finite timeouts, so a wait that spins can't hang the program.
// The cross-process rows start this program again as `x64-sync.exe child <role> <args...>`: a child prints nothing (it
// shares the parent's stdout) and answers through its exit code, 0 for success.
#include <windows.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BATCHES 21  // timing: odd, so the median is one batch
#define MANY 3200   // more than three 16K chunks of 16-byte msync slots

static char self[MAX_PATH], why[256];
static double ns_per_tick;
static double t_wait, t_signal, t_wake, t_churn, t_all_wake, t_all_poll, t_handoff;  // the time rows, 0: not measured
static int failed;  // a gated row or a time row failed

// Sets the row's failure reason; returns 0, so a row can `return bad(...)`.
static int bad(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(why, sizeof why, fmt, ap);
  va_end(ap);
  return 0;
}
#define EXPECT(cond, ...) do { if (!(cond)) return bad(__VA_ARGS__); } while (0)

static LONGLONG ticks(void) {
  LARGE_INTEGER t;
  QueryPerformanceCounter(&t);
  return t.QuadPart;
}
static double ms_since(LONGLONG t0) { return (ticks() - t0) * ns_per_tick / 1e6; }

static int cmp_double(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return (x > y) - (x < y);
}
static double median(double *v, int n) {
  qsort(v, n, sizeof *v, cmp_double);
  return v[n / 2];
}

// A named object of this run: x64-sync-<parent pid>-<what><i>.
static const char *objname(DWORD pid, const char *what, unsigned i) {
  static char name[64];
  snprintf(name, sizeof name, "x64-sync-%lu-%s%u", pid, what, i);
  return name;
}

// Starts this program as `child <args>`; returns its process handle, or NULL.
static HANDLE spawn(const char *fmt, ...) {
  char cmd[MAX_PATH + 128];
  int n = snprintf(cmd, sizeof cmd, "\"%s\" child ", self);
  va_list ap;
  STARTUPINFOA si = {sizeof si};
  PROCESS_INFORMATION pi;
  va_start(ap, fmt);
  vsnprintf(cmd + n, sizeof cmd - n, fmt, ap);
  va_end(ap);
  if (!CreateProcessA(self, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) return NULL;
  CloseHandle(pi.hThread);
  return pi.hProcess;
}

// A child's exit code; one still running after 30 s is killed and gives 999.
static DWORD reap(HANDLE p) {
  DWORD code = 999;
  if (WaitForSingleObject(p, 30000) == WAIT_OBJECT_0) GetExitCodeProcess(p, &code);
  else TerminateProcess(p, 999);
  CloseHandle(p);
  return code;
}

// A thread's exit code; one still running after 15 s gives 0xdeadbeef.
static DWORD join(HANDLE t) {
  DWORD code = 0xdeadbeef;
  if (WaitForSingleObject(t, 15000) == WAIT_OBJECT_0) GetExitCodeThread(t, &code);
  CloseHandle(t);
  return code;
}
static HANDLE start(LPTHREAD_START_ROUTINE fn, void *arg) { return CreateThread(NULL, 0, fn, arg, 0, NULL); }

// Thread bodies: each returns what it is checked for.
static DWORD WINAPI waiter(void *h) { return WaitForSingleObject(h, 10000); }
static DWORD WINAPI releaser(void *m) { return ReleaseMutex(m) ? 0 : GetLastError(); }
struct multi { DWORD n; const HANDLE *h; BOOL all; };
static DWORD WINAPI multi_waiter(void *p) {
  struct multi *m = p;
  return WaitForMultipleObjects(m->n, m->h, m->all, 10000);
}

#define PINGPONGS 10000
static HANDLE ping, pong, held;
static volatile LONG seq, ack;
static DWORD WINAPI ponger(void *unused) {
  for (LONG i = 1; i <= PINGPONGS; i++) {
    if (WaitForSingleObject(ping, 10000) != WAIT_OBJECT_0) return 1;
    if (seq != i) return 2;
    ack = i;
    SetEvent(pong);
  }
  return 0;
}

// Two threads, two auto-reset events, 10000 round trips: each wake comes once, in order.
static int event_pingpong(void) {
  HANDLE t;
  ping = CreateEventA(NULL, FALSE, FALSE, NULL);
  pong = CreateEventA(NULL, FALSE, FALSE, NULL);
  t = start(ponger, NULL);
  EXPECT(ping && pong && t, "CreateEvent/CreateThread: error %lu", GetLastError());
  for (LONG i = 1; i <= PINGPONGS; i++) {
    seq = i;
    SetEvent(ping);
    EXPECT(WaitForSingleObject(pong, 10000) == WAIT_OBJECT_0, "round %ld: no pong in 10 s (ponger %lu)", i, join(t));
    EXPECT(ack == i, "round %ld: pong for round %ld", i, ack);
  }
  EXPECT(join(t) == 0, "the ponger failed");
  EXPECT(WaitForSingleObject(ping, 0) == WAIT_TIMEOUT && WaitForSingleObject(pong, 0) == WAIT_TIMEOUT,
         "an event stayed set after the last round");
  CloseHandle(ping);
  CloseHandle(pong);
  return 1;
}

// A semaphore gives as many waits as its count, a release returns the previous count, and a release of 2 wakes two
// blocked waiters.
static int semaphore_counts(void) {
  HANDLE s = CreateSemaphoreA(NULL, 2, 3, NULL), t[2];
  LONG prev = -1;
  EXPECT(s, "CreateSemaphore: error %lu", GetLastError());
  EXPECT(WaitForSingleObject(s, 0) == WAIT_OBJECT_0 && WaitForSingleObject(s, 0) == WAIT_OBJECT_0,
         "count 2 didn't give two waits");
  EXPECT(WaitForSingleObject(s, 0) == WAIT_TIMEOUT, "a wait passed at count 0");
  EXPECT(ReleaseSemaphore(s, 2, &prev) && prev == 0, "ReleaseSemaphore(2) at 0: previous count %ld", prev);
  EXPECT(ReleaseSemaphore(s, 1, &prev) && prev == 2, "ReleaseSemaphore(1) at 2: previous count %ld", prev);
  for (int i = 0; i < 3; i++) EXPECT(WaitForSingleObject(s, 0) == WAIT_OBJECT_0, "count 3 gave %d waits", i);
  EXPECT(WaitForSingleObject(s, 0) == WAIT_TIMEOUT, "count 3 gave a fourth wait");
  t[0] = start(waiter, s);
  t[1] = start(waiter, s);
  Sleep(100);  // both blocked
  EXPECT(ReleaseSemaphore(s, 2, &prev) && prev == 0, "ReleaseSemaphore(2) for 2 waiters: previous count %ld", prev);
  EXPECT(join(t[0]) == WAIT_OBJECT_0 && join(t[1]) == WAIT_OBJECT_0, "a release of 2 didn't wake both waiters");
  EXPECT(WaitForSingleObject(s, 0) == WAIT_TIMEOUT, "the woken waiters left a count");
  CloseHandle(s);
  return 1;
}

// A release past the maximum fails with ERROR_TOO_MANY_POSTS and leaves the count alone.
static int semaphore_too_many_posts(void) {
  HANDLE s = CreateSemaphoreA(NULL, 1, 2, NULL);
  LONG prev = -1;
  EXPECT(s, "CreateSemaphore: error %lu", GetLastError());
  EXPECT(!ReleaseSemaphore(s, 2, NULL) && GetLastError() == ERROR_TOO_MANY_POSTS,
         "ReleaseSemaphore(2) at 1 of 2: error %lu", GetLastError());
  EXPECT(ReleaseSemaphore(s, 1, &prev) && prev == 1, "the failed release changed the count to %ld", prev);
  EXPECT(!ReleaseSemaphore(s, 1, NULL) && GetLastError() == ERROR_TOO_MANY_POSTS,
         "ReleaseSemaphore(1) at the maximum: error %lu", GetLastError());
  EXPECT(WaitForSingleObject(s, 0) == WAIT_OBJECT_0 && WaitForSingleObject(s, 0) == WAIT_OBJECT_0
         && WaitForSingleObject(s, 0) == WAIT_TIMEOUT, "the count isn't 2 after the failed releases");
  CloseHandle(s);
  return 1;
}

// Only the owner releases a mutex, once per acquisition.
static int mutex_not_owner(void) {
  HANDLE m = CreateMutexA(NULL, TRUE, NULL);
  DWORD err;
  EXPECT(m, "CreateMutex: error %lu", GetLastError());
  err = join(start(releaser, m));
  EXPECT(err == ERROR_NOT_OWNER, "another thread's ReleaseMutex: error %lu", err);
  EXPECT(WaitForSingleObject(m, 0) == WAIT_OBJECT_0, "the owner couldn't take its mutex again");
  EXPECT(ReleaseMutex(m) && ReleaseMutex(m), "the owner's two releases: error %lu", GetLastError());
  EXPECT(!ReleaseMutex(m) && GetLastError() == ERROR_NOT_OWNER, "a third release: error %lu", GetLastError());
  CloseHandle(m);
  return 1;
}

static DWORD WINAPI take_and_quit(void *m) {
  DWORD r = WaitForSingleObject(m, 10000);
  SetEvent(held);
  Sleep(100);
  return r;  // without releasing m
}

// A thread that exits holding a mutex abandons it: the waiter blocked on it gets WAIT_ABANDONED, then owns it.
static int mutex_abandoned(void) {
  HANDLE m = CreateMutexA(NULL, FALSE, NULL), t;
  DWORD r;
  held = CreateEventA(NULL, FALSE, FALSE, NULL);
  t = start(take_and_quit, m);
  EXPECT(m && held && t, "CreateMutex/CreateEvent/CreateThread: error %lu", GetLastError());
  EXPECT(WaitForSingleObject(held, 10000) == WAIT_OBJECT_0, "the thread didn't take the mutex");
  r = WaitForSingleObject(m, 10000);
  EXPECT(r == WAIT_ABANDONED, "the wait on the abandoned mutex returned %#lx", r);
  EXPECT(join(t) == WAIT_OBJECT_0, "the thread's own wait failed");
  EXPECT(ReleaseMutex(m), "releasing the abandoned mutex: error %lu", GetLastError());
  r = WaitForSingleObject(m, 0);
  EXPECT(r == WAIT_OBJECT_0, "a later wait returned %#lx", r);
  ReleaseMutex(m);
  CloseHandle(m);
  CloseHandle(held);
  return 1;
}

// Wait-any returns the lowest signalled index and takes only that object; a blocked wait-any wakes with the index
// that was signalled.
static int wait_any_lowest(void) {
  HANDLE h[4] = {CreateEventA(NULL, FALSE, FALSE, NULL), CreateSemaphoreA(NULL, 0, 1, NULL),
                 CreateEventA(NULL, TRUE, FALSE, NULL), CreateEventA(NULL, FALSE, FALSE, NULL)};
  struct multi w = {4, h, FALSE};
  DWORD r;
  EXPECT(h[0] && h[1] && h[2] && h[3], "creating the objects: error %lu", GetLastError());
  SetEvent(h[3]);
  SetEvent(h[2]);
  ReleaseSemaphore(h[1], 1, NULL);
  r = WaitForMultipleObjects(4, h, FALSE, 0);
  EXPECT(r == WAIT_OBJECT_0 + 1, "1, 2 and 3 signalled: %#lx", r);
  r = WaitForMultipleObjects(4, h, FALSE, 0);
  EXPECT(r == WAIT_OBJECT_0 + 2, "2 (manual) and 3 signalled: %#lx", r);
  ResetEvent(h[2]);
  r = WaitForMultipleObjects(4, h, FALSE, 0);
  EXPECT(r == WAIT_OBJECT_0 + 3, "3 signalled: %#lx", r);
  r = WaitForMultipleObjects(4, h, FALSE, 0);
  EXPECT(r == WAIT_TIMEOUT, "none signalled: %#lx", r);
  HANDLE t = start(multi_waiter, &w);
  Sleep(100);
  SetEvent(h[3]);
  r = join(t);
  EXPECT(r == WAIT_OBJECT_0 + 3, "a blocked wait-any, 3 signalled: %#lx", r);
  for (int i = 0; i < 4; i++) CloseHandle(h[i]);
  return 1;
}

// Wait-all takes nothing until every object is signalled, a pending wait-all holds nothing, and a wait-all that
// returns has taken every object.
static int wait_all_exclusive(void) {
  HANDLE h[2] = {CreateSemaphoreA(NULL, 1, 1, NULL), CreateEventA(NULL, FALSE, FALSE, NULL)}, t;
  struct multi w = {2, h, TRUE};
  DWORD r;
  EXPECT(h[0] && h[1], "creating the objects: error %lu", GetLastError());
  r = WaitForMultipleObjects(2, h, TRUE, 0);
  EXPECT(r == WAIT_TIMEOUT, "wait-all with the event unset: %#lx", r);
  EXPECT(WaitForSingleObject(h[0], 0) == WAIT_OBJECT_0, "the failed wait-all took the semaphore");
  ReleaseSemaphore(h[0], 1, NULL);
  t = start(multi_waiter, &w);
  Sleep(100);
  EXPECT(WaitForSingleObject(t, 0) == WAIT_TIMEOUT, "wait-all returned with the event unset");
  EXPECT(WaitForSingleObject(h[0], 0) == WAIT_OBJECT_0, "a pending wait-all holds the semaphore");
  ReleaseSemaphore(h[0], 1, NULL);
  SetEvent(h[1]);
  r = join(t);
  EXPECT(r == WAIT_OBJECT_0, "wait-all once both are signalled: %#lx", r);
  EXPECT(WaitForSingleObject(h[0], 0) == WAIT_TIMEOUT && WaitForSingleObject(h[1], 0) == WAIT_TIMEOUT,
         "the wait-all didn't take both objects");
  CloseHandle(h[0]);
  CloseHandle(h[1]);
  return 1;
}

// A wait mixing an event and a process handle (signalled by the server when the child exits).
static int wait_process_handle(void) {
  HANDLE h[2] = {CreateEventA(NULL, TRUE, FALSE, NULL), spawn("exit")};
  DWORD r, code = 0;
  EXPECT(h[0] && h[1], "CreateEvent/CreateProcess: error %lu", GetLastError());
  r = WaitForMultipleObjects(2, h, FALSE, 0);
  EXPECT(r == WAIT_TIMEOUT, "nothing signalled yet: %#lx", r);
  SetEvent(h[0]);
  r = WaitForMultipleObjects(2, h, FALSE, 0);
  EXPECT(r == WAIT_OBJECT_0, "the event signalled: %#lx", r);
  ResetEvent(h[0]);
  r = WaitForMultipleObjects(2, h, FALSE, 30000);
  EXPECT(r == WAIT_OBJECT_0 + 1, "waiting for the child to exit: %#lx", r);
  EXPECT(GetExitCodeProcess(h[1], &code) && code == 7, "the child's exit code: %lu", code);
  r = WaitForMultipleObjects(2, h, TRUE, 0);
  EXPECT(r == WAIT_TIMEOUT, "wait-all, the process exited and the event unset: %#lx", r);
  SetEvent(h[0]);
  r = WaitForMultipleObjects(2, h, TRUE, 0);
  EXPECT(r == WAIT_OBJECT_0, "wait-all, both signalled: %#lx", r);
  CloseHandle(h[0]);
  CloseHandle(h[1]);
  return 1;
}

// A wait started at t0 returned WAIT_TIMEOUT after its 100 ms: not early, not seconds late.
static int timed_out(const char *what, DWORD r, LONGLONG t0) {
  double ms = ms_since(t0);
  EXPECT(r == WAIT_TIMEOUT && ms >= 90 && ms < 2000, "%s, 100 ms: %#lx after %.0f ms", what, r, ms);
  return 1;
}

// Relative timeouts (single, any, all) and an absolute one (NtWaitForSingleObject) expire, neither early nor late.
static int timeouts(void) {
  LONG(WINAPI * wait_abs)(HANDLE, BOOLEAN, LARGE_INTEGER *);  // NTSTATUS
  LONG(WINAPI * system_time)(LARGE_INTEGER *);
  HMODULE ntdll = GetModuleHandleA("ntdll.dll");
  HANDLE h[3] = {CreateEventA(NULL, TRUE, FALSE, NULL), CreateEventA(NULL, TRUE, FALSE, NULL),
                 CreateEventA(NULL, TRUE, TRUE, NULL)};
  LARGE_INTEGER when;
  LONGLONG t0;
  wait_abs = (void *)GetProcAddress(ntdll, "NtWaitForSingleObject");
  system_time = (void *)GetProcAddress(ntdll, "NtQuerySystemTime");
  EXPECT(h[0] && h[1] && h[2] && wait_abs && system_time, "setup: error %lu", GetLastError());
  t0 = ticks();
  DWORD r = WaitForSingleObject(h[0], 0);
  EXPECT(r == WAIT_TIMEOUT && ms_since(t0) < 1000, "a 0 ms wait: %#lx after %.0f ms", r, ms_since(t0));
  t0 = ticks();
  if (!timed_out("single", WaitForSingleObject(h[0], 100), t0)) return 0;
  t0 = ticks();
  if (!timed_out("any", WaitForMultipleObjects(2, h, FALSE, 100), t0)) return 0;
  t0 = ticks();
  if (!timed_out("all, one of two set", WaitForMultipleObjects(2, h + 1, TRUE, 100), t0)) return 0;
  system_time(&when);
  when.QuadPart += 1000000;  // 100 ms, in 100 ns units; STATUS_TIMEOUT is WAIT_TIMEOUT
  t0 = ticks();
  if (!timed_out("absolute", wait_abs(h[0], FALSE, &when), t0)) return 0;
  for (int i = 0; i < 3; i++) CloseHandle(h[i]);
  return 1;
}

static volatile DWORD apc_tid;
static void CALLBACK apc(ULONG_PTR unused) { apc_tid = GetCurrentThreadId(); }
static DWORD WINAPI alertable_waiter(void *e) { return WaitForSingleObjectEx(e, 10000, TRUE); }

// A user APC wakes an alertable wait and runs on its thread; a non-alertable wait doesn't run it.
static int alertable_apc(void) {
  HANDLE e = CreateEventA(NULL, TRUE, FALSE, NULL), t;
  DWORD tid, r;
  t = CreateThread(NULL, 0, alertable_waiter, e, 0, &tid);
  EXPECT(e && t, "CreateEvent/CreateThread: error %lu", GetLastError());
  Sleep(100);  // blocked, so the APC wakes a sleeping wait
  EXPECT(QueueUserAPC(apc, t, 0), "QueueUserAPC: error %lu", GetLastError());
  r = join(t);
  EXPECT(r == WAIT_IO_COMPLETION, "the alertable wait returned %#lx", r);
  EXPECT(apc_tid == tid, "the APC ran on thread %lu, not %lu", apc_tid, tid);
  apc_tid = 0;
  EXPECT(QueueUserAPC(apc, GetCurrentThread(), 0), "QueueUserAPC to itself: error %lu", GetLastError());
  r = WaitForSingleObjectEx(e, 50, FALSE);
  EXPECT(r == WAIT_TIMEOUT && !apc_tid, "a non-alertable wait: %#lx, the APC %s", r, apc_tid ? "ran" : "didn't run");
  r = SleepEx(0, TRUE);
  EXPECT(r == WAIT_IO_COMPLETION && apc_tid == GetCurrentThreadId(), "SleepEx(0, TRUE) after it: %#lx", r);
  CloseHandle(e);
  return 1;
}

// Named objects across processes: the child opens the parent's events and semaphore by name and answers each ping;
// the round trips give the cross-process wake time (half a round trip).
#define ROUNDS 100
static int named_cross_process(void) {
  DWORD pid = GetCurrentProcessId();
  HANDLE a = CreateEventA(NULL, FALSE, FALSE, objname(pid, "ping", 0));
  HANDLE b = CreateEventA(NULL, FALSE, FALSE, objname(pid, "pong", 0));
  HANDLE s = CreateSemaphoreA(NULL, 0, 2, objname(pid, "sem", 0)), p;
  double v[BATCHES];
  EXPECT(a && b && s, "creating the named objects: error %lu", GetLastError());
  p = spawn("named %lu %d", pid, BATCHES * ROUNDS);
  EXPECT(p, "CreateProcess: error %lu", GetLastError());
  for (int i = 0; i < BATCHES; i++) {
    LONGLONG t0 = ticks();
    for (int j = 0; j < ROUNDS; j++) {
      SetEvent(a);
      EXPECT(WaitForSingleObject(b, 10000) == WAIT_OBJECT_0, "round %d: no pong in 10 s (child exit %lu)",
             i * ROUNDS + j, reap(p));
    }
    v[i] = (ticks() - t0) * ns_per_tick / ROUNDS / 2;
  }
  EXPECT(WaitForSingleObject(s, 10000) == WAIT_OBJECT_0 && WaitForSingleObject(s, 0) == WAIT_OBJECT_0
         && WaitForSingleObject(s, 0) == WAIT_TIMEOUT, "the child's release of 2 on the named semaphore");
  DWORD code = reap(p);
  EXPECT(code == 0, "child exit %lu", code);
  t_wake = median(v, BATCHES);
  CloseHandle(a);
  CloseHandle(b);
  CloseHandle(s);
  return 1;
}

// A duplicate is the same object and outlives its closed source; a child duplicates two unnamed events out of this
// process by handle value, waits on one and sets the other.
static int duplicate_handle(void) {
  HANDLE me = GetCurrentProcess(), x = CreateEventA(NULL, FALSE, FALSE, NULL), y = NULL, p;
  HANDLE a = CreateEventA(NULL, FALSE, FALSE, NULL), b = CreateEventA(NULL, FALSE, FALSE, NULL);
  EXPECT(x && a && b, "CreateEvent: error %lu", GetLastError());
  SetEvent(x);
  EXPECT(DuplicateHandle(me, x, me, &y, 0, FALSE, DUPLICATE_SAME_ACCESS | DUPLICATE_CLOSE_SOURCE),
         "DuplicateHandle: error %lu", GetLastError());
  EXPECT(WaitForSingleObject(y, 0) == WAIT_OBJECT_0, "the duplicate didn't see the source's SetEvent");
  SetEvent(y);
  EXPECT(WaitForSingleObject(y, 0) == WAIT_OBJECT_0, "the duplicate died with its closed source");
  CloseHandle(y);
  p = spawn("dup %lu %lu %lu", GetCurrentProcessId(), (unsigned long)(ULONG_PTR)a, (unsigned long)(ULONG_PTR)b);
  EXPECT(p, "CreateProcess: error %lu", GetLastError());
  SetEvent(a);
  EXPECT(WaitForSingleObject(b, 30000) == WAIT_OBJECT_0, "the child didn't set its duplicate (child exit %lu)",
         reap(p));
  DWORD code = reap(p);
  EXPECT(code == 0, "child exit %lu", code);
  CloseHandle(a);
  CloseHandle(b);
  return 1;
}

// Wait-all on h[0..n) in batches of 64. Returns the first batch that didn't return WAIT_OBJECT_0 (or `want`), or -1.
static int batches(HANDLE *h, int n, BOOL all, DWORD ms, DWORD want) {
  for (int i = 0; i < n; i += MAXIMUM_WAIT_OBJECTS) {
    DWORD k = n - i < MAXIMUM_WAIT_OBJECTS ? n - i : MAXIMUM_WAIT_OBJECTS;
    if (WaitForMultipleObjects(k, h + i, all, ms) != want) return i;
  }
  return -1;
}

// 3,200 named auto-reset events, several chunks of msync's shared memory: a child sets them all while this process
// waits on them, then a second child waits on them all after this process set them.
static int many_events_cross_process(void) {
  static HANDLE ev[MANY];
  DWORD pid = GetCurrentProcessId(), code;
  HANDLE go = CreateEventA(NULL, TRUE, FALSE, objname(pid, "go", 0)), p;
  int bad_batch;
  for (int i = 0; i < MANY; i++) {
    ev[i] = CreateEventA(NULL, FALSE, FALSE, objname(pid, "ev", i));
    EXPECT(ev[i], "event %d: error %lu", i, GetLastError());
  }
  EXPECT(go, "CreateEvent: error %lu", GetLastError());
  p = spawn("many-set %lu", pid);
  EXPECT(p, "CreateProcess: error %lu", GetLastError());
  SetEvent(go);
  bad_batch = batches(ev, MANY, TRUE, 30000, WAIT_OBJECT_0);
  EXPECT(bad_batch < 0, "the child's SetEvent: events %d+ not all set in 30 s (child exit %lu)", bad_batch, reap(p));
  code = reap(p);
  EXPECT(code == 0, "the setting child: exit %lu", code);
  bad_batch = batches(ev, MANY, FALSE, 0, WAIT_TIMEOUT);
  EXPECT(bad_batch < 0, "events %d+: one stayed set after the wait-all", bad_batch);
  for (int i = 0; i < MANY; i++) SetEvent(ev[i]);
  code = reap(spawn("many-wait %lu", pid));
  EXPECT(code == 0, "the waiting child: exit %lu", code);
  bad_batch = batches(ev, MANY, FALSE, 0, WAIT_TIMEOUT);
  EXPECT(bad_batch < 0, "events %d+: one stayed set after the child's wait-all", bad_batch);
  for (int i = 0; i < MANY; i++) CloseHandle(ev[i]);
  CloseHandle(go);
  return 1;
}

// 50,000 cycles of create, use (so msync hands out a slot), wait and close, over events, semaphores and mutexes; the
// time row is one cycle.
static int create_close_churn(void) {
  double v[50];
  for (int b = 0; b < 50; b++) {
    LONGLONG t0 = ticks();
    for (int i = 0; i < 1000; i++) {
      HANDLE h;
      BOOL ok;
      switch (i % 3) {
        case 0: ok = (h = CreateEventA(NULL, FALSE, FALSE, NULL)) && SetEvent(h); break;
        case 1: ok = (h = CreateSemaphoreA(NULL, 0, 1, NULL)) && ReleaseSemaphore(h, 1, NULL); break;
        default: ok = (h = CreateMutexA(NULL, FALSE, NULL)) != NULL; break;
      }
      ok = ok && WaitForSingleObject(h, 0) == WAIT_OBJECT_0 && (i % 3 != 2 || ReleaseMutex(h)) && CloseHandle(h);
      EXPECT(ok, "cycle %d: error %lu", b * 1000 + i, GetLastError());
    }
    v[b] = (ticks() - t0) * ns_per_tick / 1000;
  }
  t_churn = median(v, 50);
  return 1;
}

static DWORD WINAPI pulse_waiter(void *e) { return WaitForSingleObject(e, 2000); }

// Reported, not gated: how many of 4 blocked waiters one PulseEvent of a manual-reset event wakes.
static void pulse_event(void) {
  HANDLE e = CreateEventA(NULL, TRUE, FALSE, NULL), t[4];
  int woke = 0;
  for (int i = 0; i < 4; i++) t[i] = start(pulse_waiter, e);
  Sleep(200);
  PulseEvent(e);
  for (int i = 0; i < 4; i++) woke += join(t[i]) == WAIT_OBJECT_0;
  printf("info pulse-event %d of 4 waiters woke, the event is %s\n", woke,
         WaitForSingleObject(e, 0) == WAIT_TIMEOUT ? "unset" : "still set");
  CloseHandle(e);
}

// The uncontended rows: a wait on a set manual-reset event, and a release of a semaphore nobody waits on.
static void uncontended(void) {
  HANDLE e = CreateEventA(NULL, TRUE, TRUE, NULL), s = CreateSemaphoreA(NULL, 0, 0x7fffffff, NULL);
  double w[BATCHES], r[BATCHES];
  for (int i = 0; i < BATCHES; i++) {
    LONGLONG t0 = ticks();
    for (int j = 0; j < 2000; j++) WaitForSingleObject(e, 0);
    w[i] = (ticks() - t0) * ns_per_tick / 2000;
    t0 = ticks();
    for (int j = 0; j < 2000; j++) ReleaseSemaphore(s, 1, NULL);
    r[i] = (ticks() - t0) * ns_per_tick / 2000;
  }
  t_wait = median(w, BATCHES);
  t_signal = median(r, BATCHES);
  CloseHandle(e);
  CloseHandle(s);
}

// The wait-all rows (Wine patch 0031). `stop` ends a row's threads.
static volatile LONG stop;

// wait-all-single-waiter (B1): A waits for all of {O, S}, B for O alone; O is signalled once. A wakes, finds S unset
// and parks again; the wake must still reach B. O: an auto-reset event, a mutex main owns, an auto-reset timer (the
// server signals it). 10 rounds each, A started first in the even ones.
enum { AUTO_EVENT, MUTEX, TIMER };
static const char *const kinds[] = {"auto-event", "mutex", "timer"};
struct pair { HANDLE h[2]; int kind; };
static DWORD WINAPI pair_all(void *p) {
  struct pair *a = p;
  DWORD r = WaitForMultipleObjects(2, a->h, TRUE, 5000);
  if (r == WAIT_OBJECT_0 && a->kind == MUTEX) ReleaseMutex(a->h[0]);
  return r;
}
static DWORD WINAPI pair_one(void *p) {
  struct pair *a = p;
  DWORD r = WaitForSingleObject(a->h[0], 2000);
  if (r == WAIT_OBJECT_0 && a->kind == MUTEX) ReleaseMutex(a->h[0]);
  return r;
}
static void signal_kind(HANDLE o, int kind) {
  LARGE_INTEGER due = {.QuadPart = -10000};  // 1 ms
  if (kind == AUTO_EVENT) SetEvent(o);
  else if (kind == MUTEX) ReleaseMutex(o);
  else SetWaitableTimer(o, &due, 0, NULL, NULL, FALSE);
}
static int wait_all_single_waiter(void) {
  for (int kind = AUTO_EVENT; kind <= TIMER; kind++) {
    for (int r = 0; r < 10; r++) {
      struct pair p = {{kind == AUTO_EVENT ? CreateEventA(NULL, FALSE, FALSE, NULL)
                        : kind == MUTEX    ? CreateMutexA(NULL, TRUE, NULL)
                                           : CreateWaitableTimerA(NULL, FALSE, NULL),
                        CreateSemaphoreA(NULL, 0, 1, NULL)},
                       kind};
      EXPECT(p.h[0] && p.h[1], "creating the objects: error %lu", GetLastError());
      HANDLE t1 = start(r % 2 ? pair_one : pair_all, &p);
      Sleep(50);
      HANDLE t2 = start(r % 2 ? pair_all : pair_one, &p);
      HANDLE a = r % 2 ? t2 : t1, b = r % 2 ? t1 : t2;
      Sleep(100);
      signal_kind(p.h[0], kind);
      int ok = WaitForSingleObject(b, kind == TIMER ? 101 : 100) == WAIT_OBJECT_0;
      ReleaseSemaphore(p.h[1], 1, NULL);  // cleanup, both outcomes: A can finish, then B
      if (kind != MUTEX) signal_kind(p.h[0], kind);
      DWORD ra = join(a);
      if (kind != MUTEX) signal_kind(p.h[0], kind);
      DWORD rb = join(b);
      CloseHandle(p.h[0]);
      CloseHandle(p.h[1]);
      EXPECT(ok && rb == WAIT_OBJECT_0, "%s round %d (%s first): the single waiter still asleep 100 ms after the signal",
             kinds[kind], r, r % 2 ? "B" : "A");
      EXPECT(ra == WAIT_OBJECT_0, "%s round %d: the wait-all returned %#lx", kinds[kind], r, ra);
    }
  }
  return 1;
}

// wait-all-rollback-wake (B2) and wait-all-owned-mutex (B3): W1 waits for all of {first, S[0..61], X}, W2 for all of
// {X, Z}, and main releases X RELEASES times. When W2 takes X inside W1's grab, W1 puts back what it took; the 62
// semaphores between `first` and X widen that window. Event row: `first` is an auto-reset event P keeps taking and
// setting; a rollback that puts it back without a wake leaves P asleep with it set, which main's sampler counts. Mutex
// row: W1 owns `first` throughout; a rollback that lets go of it lets P's probe take it.
#define RELEASES 10000
#define MIN_WINS (RELEASES / 100)
#define STALL_SAMPLES 3
static HANDLE race_first, race_s[62], race_x, race_z, race_ready;
static int race_mutex, w1_wins, w2_wins, p_timeouts, probe_hits, owner_release_failed;
static volatile LONG p_done, p_seq, p_waiting;
static DWORD WINAPI race_w1(void *unused) {
  HANDLE h[64];
  if (race_mutex) race_first = CreateMutexA(NULL, TRUE, NULL);
  h[0] = race_first;
  memcpy(h + 1, race_s, sizeof race_s);
  h[63] = race_x;
  SetEvent(race_ready);
  while (!stop) {
    if (WaitForMultipleObjects(64, h, TRUE, 100) != WAIT_OBJECT_0) continue;
    w1_wins++;
    if (!race_mutex) SetEvent(race_first);
    else if (!ReleaseMutex(race_first)) owner_release_failed++;
  }
  if (race_mutex) {  // after P is gone: the creation's ownership, released once, exactly
    while (!p_done) Sleep(1);
    if (!ReleaseMutex(race_first)) owner_release_failed++;
    if (ReleaseMutex(race_first) || GetLastError() != ERROR_NOT_OWNER) owner_release_failed++;
  }
  return 0;
}
static DWORD WINAPI race_w2(void *unused) {
  HANDLE h[2] = {race_x, race_z};
  while (!stop)
    if (WaitForMultipleObjects(2, h, TRUE, 100) == WAIT_OBJECT_0) w2_wins++;
  return 0;
}
static DWORD WINAPI race_p(void *unused) {
  while (!stop) {
    DWORD r;
    if (race_mutex) {
      r = WaitForSingleObject(race_first, 0);
      if (r == WAIT_OBJECT_0 || r == WAIT_ABANDONED) {
        probe_hits++;
        ReleaseMutex(race_first);
      }
      continue;
    }
    p_seq++;
    p_waiting = 1;
    r = WaitForSingleObject(race_first, 1000);
    p_waiting = 0;
    if (r == WAIT_OBJECT_0) SetEvent(race_first);
    else p_timeouts++;
  }
  return 0;
}
static int wait_all_race(int owned_mutex) {
  LONG(WINAPI * query_event)(HANDLE, int, void *, ULONG, ULONG *);  // NTSTATUS NtQueryEvent
  struct { LONG type, state; } info;
  LONG stall_seq[16], stall_len[16], run_seq = 0;
  int stalls = 0, run = 0;
  HANDLE w1, w2, p;
  stop = p_done = p_seq = p_waiting = 0;
  w1_wins = w2_wins = p_timeouts = probe_hits = owner_release_failed = 0;
  race_mutex = owned_mutex;
  query_event = (void *)GetProcAddress(GetModuleHandleA("ntdll.dll"), "NtQueryEvent");
  race_first = owned_mutex ? NULL : CreateEventA(NULL, FALSE, TRUE, NULL);
  for (int i = 0; i < 62; i++)
    EXPECT((race_s[i] = CreateSemaphoreA(NULL, 0x100000, 0x100000, NULL)), "semaphore %d: error %lu", i, GetLastError());
  race_x = CreateSemaphoreA(NULL, 0, 1, NULL);
  race_z = CreateEventA(NULL, TRUE, TRUE, NULL);
  race_ready = CreateEventA(NULL, TRUE, FALSE, NULL);
  EXPECT(query_event && race_x && race_z && race_ready && (owned_mutex || race_first), "setup: error %lu",
         GetLastError());
  w1 = start(race_w1, NULL);
  if (WaitForSingleObject(race_ready, 10000) != WAIT_OBJECT_0 || !race_first) {
    stop = 1;
    join(w1);
    return bad("W1 didn't start: error %lu", GetLastError());
  }
  w2 = start(race_w2, NULL);
  p = start(race_p, NULL);
  for (int i = 0; i < RELEASES; i++) {
    ReleaseSemaphore(race_x, 1, NULL);
    Sleep(1);
    if (owned_mutex) continue;
    // P asleep in one wait (same p_seq) with the event set, STALL_SAMPLES samples running: a stall.
    LONG seq = p_seq;
    int asleep = p_waiting && !query_event(race_first, 0 /* EventBasicInformation */, &info, sizeof info, NULL)
                 && info.state == 1 && p_waiting && p_seq == seq;
    if (!asleep) {
      run = 0;
      continue;
    }
    if (run && seq == run_seq) {
      run++;
    } else {
      run = 1;
      run_seq = seq;
    }
    if (run == STALL_SAMPLES && stalls < 16) stall_seq[stalls] = seq;
    if (run == STALL_SAMPLES) stalls++;
    if (run >= STALL_SAMPLES && stalls <= 16) stall_len[stalls - 1] = run;
  }
  stop = 1;
  join(p);
  p_done = 1;
  ReleaseSemaphore(race_x, 1, NULL);
  join(w1);
  join(w2);
  if (owned_mutex) {
    printf("info wait-all-owned-mutex releases %d w1-wins %d w2-wins %d probe-hits %d\n", RELEASES, w1_wins, w2_wins,
           probe_hits);
  } else {
    printf("info wait-all-rollback-wake releases %d w1-wins %d w2-wins %d stalls %d\n", RELEASES, w1_wins, w2_wins,
           stalls);
    for (int i = 0; i < stalls && i < 16; i++)
      printf("info wait-all-rollback-wake stall p-seq %ld state 1 for %ld samples\n", stall_seq[i], stall_len[i]);
  }
  CloseHandle(race_first);
  for (int i = 0; i < 62; i++) CloseHandle(race_s[i]);
  CloseHandle(race_x);
  CloseHandle(race_z);
  CloseHandle(race_ready);
  EXPECT(w2_wins >= MIN_WINS, "the race didn't run: W2 won %d of %d", w2_wins, RELEASES);
  if (!owned_mutex)
    EXPECT(stalls == 0 && p_timeouts == 0, "%d stalls, %d timeouts: the single waiter slept with the event set", stalls,
           p_timeouts);
  else
    EXPECT(probe_hits == 0 && owner_release_failed == 0,
           "another thread took the owner's mutex %d times; %d owner releases failed", probe_hits,
           owner_release_failed);
  return 1;
}
static int wait_all_rollback_wake(void) { return wait_all_race(0); }
static int wait_all_owned_mutex(void) { return wait_all_race(1); }

// wait-all-duplicate (B4): one object twice in a wait-all, {h, h}. Windows answers ERROR_INVALID_PARAMETER; the
// wineserver has no duplicate check, so check.sh gates mode 1's answers and this program only {E, E}'s spin.
struct dup { HANDLE h[2]; int mutex; DWORD r, err; };
static DWORD WINAPI dup_waiter(void *p) {
  struct dup *d = p;
  d->r = WaitForMultipleObjects(2, d->h, TRUE, 0);
  d->err = GetLastError();
  if (d->r == WAIT_OBJECT_0 && d->mutex) {
    ReleaseMutex(d->h[0]);
    ReleaseMutex(d->h[0]);
  }
  return 0;
}
// Writes the worker's answer to w; returns whether it ended within 1 s. A spinning worker is rescued: main takes h
// until the worker's wait finds it unsignalled and times out, or, after 5 s, ends it.
static int dup_case(HANDLE h, int mutex, char *w, size_t n) {
  static struct dup d;  // static: a terminated worker leaves no write to a gone stack frame
  d = (struct dup){{h, h}, mutex, 0xdeadbeef, 0};
  HANDLE t = start(dup_waiter, &d);
  int ended = WaitForSingleObject(t, 1000) == WAIT_OBJECT_0;
  for (LONGLONG t0 = ticks(); !ended && WaitForSingleObject(t, 0) == WAIT_TIMEOUT && ms_since(t0) < 5000;)
    WaitForSingleObject(h, 0);
  if (WaitForSingleObject(t, 0) == WAIT_TIMEOUT) TerminateThread(t, 0);
  WaitForSingleObject(t, 1000);
  CloseHandle(t);
  if (!ended) snprintf(w, n, "spun");
  else if (d.r == WAIT_OBJECT_0) snprintf(w, n, "success");
  else if (d.r == WAIT_FAILED && d.err == ERROR_INVALID_PARAMETER) snprintf(w, n, "invalid-parameter");
  else snprintf(w, n, "%#lx/%lu", d.r, d.err);
  return ended;
}
static int wait_all_duplicate(void) {
  HANDLE e = CreateEventA(NULL, FALSE, TRUE, NULL), m = CreateMutexA(NULL, FALSE, NULL);
  HANDLE s = CreateSemaphoreA(NULL, 2, 2, NULL);  // never count 1: {S(1), S(1)} aborts the mode-0 wineserver
  char we[32], ws[32], wm[32];
  EXPECT(e && s && m, "creating the objects: error %lu", GetLastError());
  int ended = dup_case(e, 0, we, sizeof we);
  dup_case(s, 0, ws, sizeof ws);
  dup_case(m, 1, wm, sizeof wm);
  printf("info wait-all-duplicate auto-event %s semaphore %s mutex %s\n", we, ws, wm);
  CloseHandle(e);
  CloseHandle(s);
  CloseHandle(m);
  EXPECT(ended, "{E, E}: the wait-all spun past 1 s");
  return 1;
}

// wait-all-abandoned-mutex (B7): a wait-all on {an abandoned mutex, a set manual event} takes the mutex and returns
// WAIT_ABANDONED_0. A spinning worker is rescued: main takes the mutex, so the worker's spent wait times out.
struct abandoned { HANDLE h[2]; DWORD r; BOOL released; };
static DWORD WINAPI abandoned_waiter(void *p) {
  struct abandoned *a = p;
  a->r = WaitForMultipleObjects(2, a->h, TRUE, 500);
  if (a->r == WAIT_ABANDONED_0) a->released = ReleaseMutex(a->h[0]);
  return 0;
}
static int wait_all_abandoned_mutex(void) {
  static struct abandoned a;  // static: the worker may outlive a failed rescue
  HANDLE m = CreateMutexA(NULL, FALSE, NULL), z = CreateEventA(NULL, TRUE, TRUE, NULL), t;
  held = CreateEventA(NULL, FALSE, FALSE, NULL);
  EXPECT(m && z && held, "creating the objects: error %lu", GetLastError());
  t = start(take_and_quit, m);
  EXPECT(WaitForSingleObject(held, 10000) == WAIT_OBJECT_0, "the thread didn't take the mutex");
  EXPECT(join(t) == WAIT_OBJECT_0, "the abandoning thread's wait failed");
  a = (struct abandoned){{m, z}, 0xdeadbeef, FALSE};
  t = start(abandoned_waiter, &a);
  int ended = WaitForSingleObject(t, 1000) == WAIT_OBJECT_0;
  if (ended) {
    CloseHandle(t);
  } else {
    WaitForSingleObject(m, 0);  // WAIT_ABANDONED: main owns it now
    join(t);
    ReleaseMutex(m);
  }
  CloseHandle(m);
  CloseHandle(z);
  CloseHandle(held);
  EXPECT(ended, "a wait-all with an abandoned mutex: still running after 1 s");
  EXPECT(a.r == WAIT_ABANDONED_0 && a.released, "a wait-all with an abandoned mutex returned %#lx", a.r);
  return 1;
}

// Time rows of the wait-all fixes, each the median of BATCHES batches. A wait that times out prints `FAIL <row>:
// stuck`, fails the run and leaves the row unmeasured.
static void stuck(const char *row) {
  printf("FAIL %s: stuck\n", row);
  failed = 1;
}

// wait-all-wake: half a round trip between two threads, each blocked in a wait-all on {its own auto-reset event, Z}.
static HANDLE wake_ev[2], wake_z;
static DWORD WINAPI wake_partner(void *unused) {
  HANDLE h[2] = {wake_ev[1], wake_z};
  while (!stop)
    if (WaitForMultipleObjects(2, h, TRUE, 1000) == WAIT_OBJECT_0 && !stop) SetEvent(wake_ev[0]);
  return 0;
}
static void wait_all_wake(void) {
  double v[BATCHES];
  HANDLE h[2], t;
  stop = 0;
  wake_ev[0] = CreateEventA(NULL, FALSE, FALSE, NULL);
  wake_ev[1] = CreateEventA(NULL, FALSE, FALSE, NULL);
  wake_z = CreateEventA(NULL, TRUE, TRUE, NULL);
  h[0] = wake_ev[0];
  h[1] = wake_z;
  t = start(wake_partner, NULL);
  for (int b = 0; b < BATCHES && !stop; b++) {
    LONGLONG t0 = ticks();
    for (int j = 0; j < 100 && !stop; j++) {
      SetEvent(wake_ev[1]);
      if (WaitForMultipleObjects(2, h, TRUE, 1000) != WAIT_OBJECT_0) stop = 1;
    }
    v[b] = (ticks() - t0) * ns_per_tick / 100 / 2;
  }
  if (stop) stuck("wait-all-wake");
  else t_all_wake = median(v, BATCHES);
  stop = 1;
  SetEvent(wake_ev[1]);  // the partner sees stop now, not after its timeout
  join(t);
  CloseHandle(wake_ev[0]);
  CloseHandle(wake_ev[1]);
  CloseHandle(wake_z);
}

// wait-all-poll: a 0 ms wait-all on {an unset auto-reset event, a set manual event}, per call.
static void wait_all_poll(void) {
  HANDLE h[2] = {CreateEventA(NULL, FALSE, FALSE, NULL), CreateEventA(NULL, TRUE, TRUE, NULL)};
  double v[BATCHES];
  for (int b = 0; b < BATCHES; b++) {
    LONGLONG t0 = ticks();
    for (int j = 0; j < 2000; j++) WaitForMultipleObjects(2, h, TRUE, 0);
    v[b] = (ticks() - t0) * ns_per_tick / 2000;
  }
  t_all_poll = median(v, BATCHES);
  CloseHandle(h[0]);
  CloseHandle(h[1]);
}

// auto-handoff-8: 8 threads pass one auto-reset event, 2,000 handoffs a batch, per handoff.
static HANDLE handoff_ev, handoff_done;
static volatile LONG handoffs;
static DWORD WINAPI handoff(void *unused) {
  while (!stop) {
    if (WaitForSingleObject(handoff_ev, 100) != WAIT_OBJECT_0) continue;
    if (InterlockedIncrement(&handoffs) == 2000) SetEvent(handoff_done);
    else SetEvent(handoff_ev);
  }
  return 0;
}
static void auto_handoff_8(void) {
  HANDLE t[8];
  double v[BATCHES];
  stop = 0;
  handoff_ev = CreateEventA(NULL, FALSE, FALSE, NULL);
  handoff_done = CreateEventA(NULL, FALSE, FALSE, NULL);
  for (int i = 0; i < 8; i++) t[i] = start(handoff, NULL);
  for (int b = 0; b < BATCHES && !stop; b++) {
    handoffs = 0;
    LONGLONG t0 = ticks();
    SetEvent(handoff_ev);
    if (WaitForSingleObject(handoff_done, 10000) != WAIT_OBJECT_0) stop = 1;
    v[b] = (ticks() - t0) * ns_per_tick / 2000;
  }
  if (stop) stuck("auto-handoff-8");
  else t_handoff = median(v, BATCHES);
  stop = 1;
  for (int i = 0; i < 8; i++) join(t[i]);
  CloseHandle(handoff_ev);
  CloseHandle(handoff_done);
}

// The child roles; each returns 0 on success, else the step that failed.
static int child(int argc, char **argv) {
  DWORD ppid = argc > 1 ? strtoul(argv[1], NULL, 10) : 0;
  if (!strcmp(argv[0], "exit")) {
    Sleep(500);
    return 7;
  }
  if (!strcmp(argv[0], "named") && argc == 3) {
    HANDLE a = OpenEventA(EVENT_ALL_ACCESS, FALSE, objname(ppid, "ping", 0));
    HANDLE b = OpenEventA(EVENT_ALL_ACCESS, FALSE, objname(ppid, "pong", 0));
    HANDLE s = OpenSemaphoreA(SEMAPHORE_ALL_ACCESS, FALSE, objname(ppid, "sem", 0));
    if (!a || !b || !s) return 2;
    for (int i = 0, n = atoi(argv[2]); i < n; i++) {
      if (WaitForSingleObject(a, 10000) != WAIT_OBJECT_0) return 3;
      SetEvent(b);
    }
    return ReleaseSemaphore(s, 2, NULL) ? 0 : 4;
  }
  if (!strcmp(argv[0], "dup") && argc == 4) {
    HANDLE parent = OpenProcess(PROCESS_DUP_HANDLE, FALSE, ppid), a, b;
    if (!parent) return 2;
    if (!DuplicateHandle(parent, (HANDLE)(ULONG_PTR)strtoul(argv[2], NULL, 10), GetCurrentProcess(), &a, 0, FALSE,
                         DUPLICATE_SAME_ACCESS)
        || !DuplicateHandle(parent, (HANDLE)(ULONG_PTR)strtoul(argv[3], NULL, 10), GetCurrentProcess(), &b, 0, FALSE,
                            DUPLICATE_SAME_ACCESS))
      return 3;
    if (WaitForSingleObject(a, 10000) != WAIT_OBJECT_0) return 4;
    return SetEvent(b) ? 0 : 5;
  }
  if ((!strcmp(argv[0], "many-set") || !strcmp(argv[0], "many-wait")) && argc == 2) {
    static HANDLE ev[MANY];
    for (int i = 0; i < MANY; i++)
      if (!(ev[i] = OpenEventA(EVENT_ALL_ACCESS, FALSE, objname(ppid, "ev", i)))) return 2;
    if (!strcmp(argv[0], "many-wait")) return batches(ev, MANY, TRUE, 10000, WAIT_OBJECT_0) < 0 ? 0 : 3;
    HANDLE go = OpenEventA(SYNCHRONIZE, FALSE, objname(ppid, "go", 0));
    if (!go || WaitForSingleObject(go, 10000) != WAIT_OBJECT_0) return 4;
    for (int i = 0; i < MANY; i++)
      if (!SetEvent(ev[i])) return 5;
    return 0;
  }
  return 9;
}

int main(int argc, char **argv) {
  static const struct {
    const char *name;
    int (*fn)(void);
  } rows[] = {
      {"event-pingpong", event_pingpong},
      {"semaphore-counts", semaphore_counts},
      {"semaphore-too-many-posts", semaphore_too_many_posts},
      {"mutex-not-owner", mutex_not_owner},
      {"mutex-abandoned", mutex_abandoned},
      {"wait-any-lowest", wait_any_lowest},
      {"wait-all-exclusive", wait_all_exclusive},
      {"wait-process-handle", wait_process_handle},
      {"timeouts", timeouts},
      {"alertable-apc", alertable_apc},
      {"named-cross-process", named_cross_process},
      {"duplicate-handle", duplicate_handle},
      {"many-events-cross-process", many_events_cross_process},
      {"create-close-churn", create_close_churn},
      {"wait-all-single-waiter", wait_all_single_waiter},
      {"wait-all-rollback-wake", wait_all_rollback_wake},
      {"wait-all-owned-mutex", wait_all_owned_mutex},
      {"wait-all-duplicate", wait_all_duplicate},
      {"wait-all-abandoned-mutex", wait_all_abandoned_mutex},
  };
  LARGE_INTEGER f;
  GetModuleFileNameA(NULL, self, sizeof self);
  if (argc >= 3 && !strcmp(argv[1], "child")) return child(argc - 2, argv + 2);
  setvbuf(stdout, NULL, _IONBF, 0);  // a crash or a timeout keeps what was printed before it
  QueryPerformanceFrequency(&f);
  ns_per_tick = 1e9 / f.QuadPart;
  for (int i = 0; i < (int)(sizeof rows / sizeof rows[0]); i++) {
    why[0] = 0;
    if (rows[i].fn()) {
      printf("ok %s\n", rows[i].name);
    } else {
      printf("FAIL %s: %s\n", rows[i].name, why);
      failed = 1;
    }
  }
  pulse_event();
  uncontended();
  wait_all_wake();
  wait_all_poll();
  auto_handoff_8();
  printf("time uncontended-wait %.0f\ntime uncontended-signal %.0f\n", t_wait, t_signal);
  if (t_wake > 0) printf("time cross-process-wake %.0f\n", t_wake);
  if (t_churn > 0) printf("time create-close %.0f\n", t_churn);
  if (t_all_wake > 0) printf("time wait-all-wake %.0f\n", t_all_wake);
  printf("time wait-all-poll %.0f\n", t_all_poll);
  if (t_handoff > 0) printf("time auto-handoff-8 %.0f\n", t_handoff);
  if (failed) {
    printf("FAIL x64-sync\n");
    return 1;
  }
  printf("PASS x64-sync\n");
  return 0;
}
