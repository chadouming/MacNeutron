# msync wait-all fixes, measurement lanes and the PE M1 baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** msync's wait-all stops losing wakeups, breaking mutual exclusion and spinning; three lanes (ARM64, ARM64EC,
x64) measure sync and call-crossing costs; then every PE binary is built for the Apple M1 instruction set with real
acquire/release in ARM64EC code, measured before and after.

**Architecture:** Task 1 is one test-first Wine patch (0031) to msync's wait-all in `dlls/ntdll/unix/msync.c` and
`server/msync.c`: non-alertable legs park through the pump, the rollback puts back only what it took and wakes its
waiters, and duplicate objects and abandoned mutexes stop spinning. Task 2 builds `x64-sync.c` and a new
`arm64-xcall.c` for three lanes, run by an opt-in `check.sh lanes` step, and records a baseline. Task 3 is one full
rebuild with the `winnt.h` ARM64EC guard (Wine 0032) and `-march=armv8.5-a+fp16fml+aes+sha3` on every PE build (Wine,
FEX, DXMT 0038, the Makefile's `MINGW_*`), guarded after the build, then re-measures the lanes.

**Tech Stack:** C (Wine's unix and PE sides, the wineserver), Mach ulock/IPC, llvm-mingw 23.1.1 (aarch64, arm64ec and
x86_64 triples), meson cross files, CMake (FEX), POSIX sh (`build.sh`, `lib.sh`, `check.sh`), make, Python 3
(`lanes_report.py`).

**Spec:**
- `.superpowers/brainstorm-sync/REPORT.md` §3.3 (B1-B6) and §4 (R1, R4, R5, R9, "R1 in detail", "R4 in detail");
  background in `.superpowers/brainstorm-sync/msync-today.md`.
- `.superpowers/brainstorm-native/REPORT.md` §3 (R0, R1, R2) and §5 item 8 (the licence re-scan); per-file edits in
  `.superpowers/brainstorm-native/codegen-baseline.md` §9.
- The maintainer's decisions, `.superpowers/sdd/2026-10-08-macneutron-video-playback/progress.md:62-65` (2026-10-09,
  "Proceed in that order and also fix B1"): Ruling R11 makes B1 option (b) with (a) as the fallback; Ruling R12 sets
  the scope. Batch Tasks 4-7 (`progress.md:67-71`) come from a second plan and consume Task 2's lanes.

All file:line references are at Wine tree HEAD 38640fe (patch 0030), DXMT tree HEAD 5ed2a79 (patch 0037) and repo HEAD
bb65ef0.

## Global Constraints

- **Platform and trees:** macOS 27 minimum, arm64 only. Wine 11.19 is `build/wine-arm64-src/wine` (branch
  `macneutron`); DXMT is `build/wine-arm64-src/dxmt`, FEX `build/wine-arm64-src/fex`.
- **Patch series:** `wine-arm64/patches/{wine,dxmt,fex,lsteamclient}`; new commits only, never rewrite an exported
  patch. Export with `make wine-arm64-export`; afterwards `git status --short wine-arm64/patches` shows only the new
  patch files. Fresh-fetch proof: a shallow clone of the pin, `git am` of every patch (N/N) by absolute path, and a
  `HEAD^{tree}` equal to the build tree's.
- **Patch numbers:** this batch owns Wine 0031 (Task 1) and 0032 (Task 3), and DXMT 0038 (Task 3). The video plan
  (`docs/superpowers/plans/2026-10-08-macneutron-video-playback.md`) resumes after this batch with the next free
  numbers. Edits to `check.sh`, `Makefile` and `build.sh` sit on bb65ef0.
- **No upstream submission, ever** (Wine, FEX, DXMT): every new patch is "ours and stays local".
- **The PE flag** is exactly `-march=armv8.5-a+fp16fml+aes+sha3`. Never `-mcpu=apple-m1`, `-mtune=apple-*` or
  `-falign-loops=16` (Apple tuning crashes llvm-mingw's SEH unwind emitter). FEX keeps `-DTUNE_CPU=none` and gets the
  flag as one token. DXMT gets it through its cross file (a patch), never `-Dc_args`. The programs in
  `wine-arm64/tests` keep their flags, so before/after measures the runtime, not the harness.
- **msync:** stays on by default; the client/server mode-agreement rule and `MSYNC_REGISTER_SPINS` are unchanged. B5
  (PulseEvent), sync R6/R7/R8, WFUSync and native R3-R7 are out of scope.
- **Signing and bundle gates:** builds need
  `MACNEUTRON_SIGN_IDENTITY="Developer ID Application: Chad Cormier Roussel (49QMZXLR8S)"` and
  `MACNEUTRON_PROVISIONING_PROFILE="$HOME/Downloads/Mac_Neutron.provisionprofile"`. The bundle gates (signing, minos
  27.0, `@rpath`-only, the x18 scan) stay green.
- **Never:** push, tag, use `gh` or notarize; open MacNeutron.app, or start or quit Steam; touch
  `~/Library/Application Support/MacNeutron/`, any game install or `steamapps/compatdata/`; use `pkill -f`
  (`wineserver -k`/`-w` only); use the maintainer's Terminal panel. Games are launched only by the controller; none
  are needed here.
- **Full gate:** `make wine-arm64-check` runs `steam-bridge`, which needs Steam running and logged in with SMITE 2
  installed (`check.sh:6-8`). Ask the controller before each full gate run; run it only once the controller says Steam
  is up. `make media-check` stays as it is:
  `FAIL media-mf: FAIL arm64-media-mf: stage=video-type hr=0xc00d5212; FAIL x64-media-mf: stage=video-type hr=0xc00d5212`.
- **Timing:** a comparison is three idle runs, reported as `median (min–max)`. Idle: `pgrep -lx wineserver` and
  `pgrep -lf wine-arm64/check.sh` print nothing, the Mac is on AC power with the lid open, each run is wrapped in
  `caffeinate -i`, and the runs are back to back. "Outside the band" means the two min–max ranges don't overlap.
- **Scans** use `/usr/bin/grep` (the interactive `grep` is a wrapper that can silently return 0).
- **Commits** end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Duplicate handles in a wait-all** (a mutex, or a semaphore whose count covers the copies, wrongly *succeed* today)
   → mode 1 returns `WAIT_FAILED` with `ERROR_INVALID_PARAMETER`, as Windows does (Task 1 Step 2's mode-1 gate).
2. **A wait-all that includes an abandoned mutex** (B7, found while planning: 100% CPU, timeout ignored) →
   `WAIT_ABANDONED_0` within 1 s, the caller then owns the mutex (Task 1 row `wait-all-abandoned-mutex`).
3. **An auto-reset timer (server-signalled) or a mutex release racing a wait-all** → the single waiter wakes (the timer
   and mutex rounds of Task 1 row `wait-all-single-waiter`).
4. **A 0 ms or expired wait-all poll under option (b)** → still answered without a pump round trip (Task 1 time row
   `wait-all-poll` and Step 5's bar).
5. **Contended locks under the new LSE codegen** → mutual exclusion holds (the counters of Task 2's `cs-contended-4` and
   `srw-contended-4`, the `waitonaddress-contended-4` ring; re-run on the new build in Task 3 Step 9).

---

### Task 1: msync wait-all correctness (Wine patch 0031)

**Files:**
- Modify: `wine-arm64/tests/x64-sync.c`: header `:1-6`; the time statics `:18`; `failed` (`:566`) moves to file scope;
  new row functions before `child` (`:502`); `rows[]` `:549-564`; time block `:583-585`.
- Modify: `wine-arm64/check.sh`: `msync_cmd` loop `:296`, a gate after `:302`; the `msync` cap at `:636` only if
  Step 5's runs take more than 240 s.
- Modify (Wine tree): `dlls/ntdll/unix/msync.c`: `:568`, `:880-899`, `:1065-1072`, `:1085`, `:1131-1191`,
  `:1195-1226`.
- Modify (Wine tree): `server/msync.c`: `:826-827`; `:422-433` only on fallback (a).
- Modify: `wine-arm64/README.md`: `:84` ("14 gated rows" becomes "19"); an 0031 line after the 0029 entry (`:251-253`).
- Modify: `docs/testing/acceptance-arm64-release.md`: a new last section, "msync wait-all fixes (batch Task 1)".
- Create, by export: `wine-arm64/patches/wine/0031-*.patch`.

**Interfaces:**
- **Produces:** `x64-sync` with 19 gated rows: the 14 at `:550-563`, then `wait-all-single-waiter`,
  `wait-all-rollback-wake`, `wait-all-owned-mutex`, `wait-all-duplicate`, `wait-all-abandoned-mutex`. Seven `time`
  rows: the four of `:583-585`, then `wait-all-wake`, `wait-all-poll`, `auto-handoff-8`. On a PASS every time row is
  printed (the two conditional ones are set by rows that passed).
- **Reported lines:** `info wait-all-duplicate auto-event <w> semaphore <w> mutex <w>`;
  `info wait-all-rollback-wake releases <n> w1-wins <n> w2-wins <n> stalls <n>`;
  `info wait-all-owned-mutex releases <n> w1-wins <n> w2-wins <n> probe-hits <n>`.
- **check.sh:** `MSYNC_MODES` (default `1 0`) selects the msync step's modes.

- [ ] **Step 1: Write the failing rows** in `x64-sync.c`. Blocking waits run on worker threads, so a spin cannot hang
  the harness; workers are ended with `join()` (`:78-83`, 15 s), whose return is the thread's exit code (it closes the
  handle). Every wait in a new row or time row has a finite timeout.

  **`wait-all-single-waiter` (B1, gated).** For each kind `auto-event`, `mutex`, `timer`, run 10 rounds; even rounds
  start A first, odd rounds B first, 50 ms between the starts and 100 ms before the signal. Each round creates its own
  objects and closes them after both joins:
  - O: `CreateEventA(NULL, FALSE, FALSE, NULL)`, or `CreateMutexA(NULL, TRUE, NULL)` (owned by main), or
    `CreateWaitableTimerA(NULL, FALSE, NULL)`. S: `CreateSemaphoreA(NULL, 0, 1, NULL)`.
  - A: `WaitForMultipleObjects(2, {O, S}, TRUE, 5000)`. B: `WaitForSingleObject(O, 2000)`. A thread that got the mutex
    releases it before returning.
  - Signal: `SetEvent(O)`, `ReleaseMutex(O)`, or `SetWaitableTimer(O, -10000 /* 1 ms */, 0, NULL, NULL, FALSE)`.
  - Then, in this order:
    ```c
    int ok = WaitForSingleObject(b, kind == timer ? 101 : 100) == WAIT_OBJECT_0;
    /* cleanup, both outcomes: ReleaseSemaphore(S, 1, NULL); re-signal O (not for the mutex); */
    DWORD ra = join(a);
    /* re-signal O (not for the mutex) */
    DWORD rb = join(b);
    EXPECT(ok && rb == WAIT_OBJECT_0,
           "%s round %d (%s first): the single waiter still asleep 100 ms after the signal", kind, r, first);
    EXPECT(ra == WAIT_OBJECT_0, "%s round %d: the wait-all returned %#lx", kind, r, ra);
    ```

  **`wait-all-rollback-wake` (B2, gated) and `wait-all-owned-mutex` (B3, gated)** share
  `static int wait_all_race(int owned_mutex)`. Knobs: `#define RELEASES 2000`, `#define MIN_WINS (RELEASES / 100)`,
  `#define STALL_SAMPLES 3`.
  - Objects: `first` is `CreateEventA(NULL, FALSE, TRUE, NULL)` (event row), or a mutex W1 creates owned before it
    signals ready (mutex row). `S[62]`: `CreateSemaphoreA(NULL, 0x100000, 0x100000, NULL)`, between `first` and X in
    W1's wait-all, so W1's grab-to-rollback window spans about 124 atomics. X: `CreateSemaphoreA(NULL, 0, 1, NULL)`.
    Z: `CreateEventA(NULL, TRUE, TRUE, NULL)`.
  - **W1** loops `WaitForMultipleObjects(64, {first, S[0..61], X}, TRUE, 100)` until `stop`. On `WAIT_OBJECT_0`:
    `w1_wins++`, then gives `first` back (`SetEvent`; or `ReleaseMutex`, a failure counted in `owner_release_failed`).
    In the mutex row, after `p_done`, its final `ReleaseMutex` must succeed and a second must fail with
    `ERROR_NOT_OWNER`; anything else counts in `owner_release_failed`.
  - **W2** loops `WaitForMultipleObjects(2, {X, Z}, TRUE, 100)` until `stop`, counting `w2_wins`. As a wait-all it
    parks the way W1 does in every build (on X's word with the semaphore's wake-all today and under (a), on the pump
    under (b)), so the race keeps its shape from RED to GREEN. W1 need not win: a rollback happens whenever W1 passes
    the check loop with X set and loses X to W2 inside its grab. RED's stalls and probe hits prove the race runs;
    `w1-wins` is recorded, not gated.
  - **P (event row)** loops until `stop`: `p_seq++; p_waiting = 1; r = WaitForSingleObject(first, 1000);
    p_waiting = 0;`; on `WAIT_OBJECT_0` it calls `SetEvent(first)`, else `p_timeouts++`.
    **P (mutex row)** loops `WaitForSingleObject(first, 0)`; `WAIT_OBJECT_0` or `WAIT_ABANDONED` counts
    `probe_hits++`, then `ReleaseMutex`.
  - **Main** releases X `RELEASES` times: `ReleaseSemaphore(X, 1, NULL); Sleep(1);`. Event row sampler, each
    iteration: read `EventState` with `NtQueryEvent(first, 0 /* EventBasicInformation */, &info, sizeof info, NULL)`
    (resolved with `GetProcAddress` as `timeouts` does, `:297-306`; local `struct { LONG type, state; }`). A stall is
    `p_waiting` set and `state == 1` on `STALL_SAMPLES` consecutive iterations with the same `p_seq`; keep each
    stall's `p_seq` and sampled states for the log.
  - **Shutdown:** set `stop`, join P, then set `p_done` (mutex row: W1's final releases come only now, so a probe
    can't count a legitimate take), `ReleaseSemaphore(X, 1, NULL)`, join W1 and W2.
  - Print the row's `info` line, then:
    ```c
    EXPECT(w2_wins >= MIN_WINS, "the race didn't run: W2 won %d of %d", w2_wins, RELEASES);
    /* event row */ EXPECT(stalls == 0 && p_timeouts == 0,
                           "%d stalls, %d timeouts: the single waiter slept with the event set", stalls, p_timeouts);
    /* mutex row */ EXPECT(probe_hits == 0 && owner_release_failed == 0,
                           "another thread took the owner's mutex %d times; %d owner releases failed",
                           probe_hits, owner_release_failed);
    ```

  **`wait-all-duplicate` (B4).** Each case's worker runs `WaitForMultipleObjects(2, {h, h}, TRUE, 0)` and keeps `r`
  and `GetLastError()`:
  - `auto-event`: `CreateEventA(NULL, FALSE, TRUE, NULL)`. Gated in x64-sync:
    `EXPECT(ended_within_1s, "{E, E}: the wait-all spun past 1 s");`. A spinning worker is rescued first: main loops
    `WaitForSingleObject(E, 0)` for up to 5 s until the worker ends, then `TerminateThread` if it still runs.
  - `semaphore`: `CreateSemaphoreA(NULL, 2, 2, NULL)`. Never count 1: `{S(1), S(1)}` aborts the mode-0 wineserver
    (`server/semaphore.c:114` `assert( sem->count )`, reached twice from `server/thread.c:1033-1036`).
  - `mutex`: `CreateMutexA(NULL, FALSE, NULL)`; the worker releases it twice when it got `WAIT_OBJECT_0`.
  - x64-sync only reports the semaphore and mutex cases (mode 0 has no duplicate check, so there is no program-level
    reference); `check.sh` gates mode 1's answer for all three (Step 2).
  - `<w>`: `success` for `WAIT_OBJECT_0`; `invalid-parameter` for `WAIT_FAILED` with error 87; `spun` when the worker
    didn't end within 1 s; otherwise `%#lx/%lu`.

  **`wait-all-abandoned-mutex` (B7, gated).** M is `CreateMutexA(NULL, FALSE, NULL)`, abandoned by `take_and_quit`
  (`:182-187`, with `held`) and joined; Z is `CreateEventA(NULL, TRUE, TRUE, NULL)`. The worker runs
  `r = WaitForMultipleObjects(2, {M, Z}, TRUE, 500)` and on `WAIT_ABANDONED_0` records `ReleaseMutex(M)`. On a spin,
  main rescues it: `WaitForSingleObject(M, 0)` (`WAIT_ABANDONED`), join the worker, `ReleaseMutex(M)`. Then:
  ```c
  EXPECT(ended_within_1s, "a wait-all with an abandoned mutex: still running after 1 s");
  EXPECT(r == WAIT_ABANDONED_0 && released, "a wait-all with an abandoned mutex returned %#lx", r);
  ```

  **Time rows (reported),** each the median of `BATCHES` (21) batches. A wait that times out ends the row with
  `FAIL <row>: stuck` and sets `failed`; threads see `stop` and exit within 100 ms.
  - `wait-all-wake`: half a round trip. Main and one worker each block in
    `WaitForMultipleObjects(2, {its own auto event, Z manual and set}, TRUE, 1000)`, then set the other's event; 100
    round trips per batch, `ns / 100 / 2`.
  - `wait-all-poll`: `WaitForMultipleObjects(2, {an unset auto event, a set manual event}, TRUE, 0)`, 2,000 calls per
    batch, ns per call.
  - `auto-handoff-8`: 8 threads pass one auto event: `WaitForSingleObject(e, 100)` (on `WAIT_TIMEOUT` re-check `stop`),
    `InterlockedIncrement(&n)`, then `SetEvent(e)`; the thread that makes the batch's 2,000th handoff sets `batch_done`
    instead. Main starts a batch with `SetEvent(e)` and waits on `batch_done` for 10 s. ns per handoff.

- [ ] **Step 2: The `check.sh` edits.**
  - `:296`: `for m in 1 0; do` becomes `for m in ${MSYNC_MODES:-1 0}; do`, commented "MSYNC_MODES=1 (or 0) runs one
    mode: the red runs".
  - After `:302`:
    ```sh
        dup='info wait-all-duplicate auto-event invalid-parameter semaphore invalid-parameter mutex invalid-parameter'
        [ "$m" = 0 ] || echo "$out" | LC_ALL=C /usr/bin/grep -qx "$dup" \
          || { echo "FAIL msync: WINEMSYNC=1: a duplicate in a wait-all isn't ERROR_INVALID_PARAMETER"; return 1; }
    ```

- [ ] **Step 3: Run the tests and see them fail.**
  1. `make wine-arm64-tests`, then three times
     `caffeinate -i env MSYNC_MODES=1 sh wine-arm64/check.sh msync`, copying `build/wine-arm64 check/msync.log` to
     `build/batch-msync/red-$i.log` after each (check.sh deletes its work folder at start).

     Expected last line (round and order vary):
     `FAIL msync: WINEMSYNC=1: FAIL wait-all-single-waiter: auto-event round 0 (A first): the single waiter still asleep 100 ms after the signal`.
     Each log also shows `FAIL wait-all-owned-mutex: another thread took the owner's mutex <n> times; …`,
     `FAIL wait-all-duplicate: {E, E}: the wait-all spun past 1 s`,
     `FAIL wait-all-abandoned-mutex: a wait-all with an abandoned mutex: still running after 1 s`, and
     `info msync 1 wait-all-duplicate auto-event spun semaphore success mutex success`.

     `wait-all-rollback-wake` is a race: expect `FAIL wait-all-rollback-wake: <n> stalls, …`. If either race row
     passes in any run, raise `RELEASES` to 10000 and run three times again. Still green: record the counts and ask the
     controller before Step 4 (the fix ships on the code evidence, REPORT §3.3).

     Record each run's `w1-wins`/`w2-wins` and the `time` rows `wait-all-wake`, `wait-all-poll`, `auto-handoff-8` as
     "mode 1 before".
  2. `caffeinate -i env MSYNC_MODES=0 sh wine-arm64/check.sh msync`. Expected: `PASS msync`, `PASS orphans`, and
     `info msync 0 wait-all-duplicate auto-event success semaphore success mutex success`.
  3. Static checks for R5 and R9, with `A=build/wine-arm64/wine.app/Contents/Resources`:
     `nm -u "$A/lib/wine/aarch64-unix/ntdll.so" | /usr/bin/grep -c '_mach_port_mod_refs$'` prints `0`;
     `xcrun llvm-objdump --disassemble-symbols=_msync_abandon_mutexes "$A/bin/wineserver" | /usr/bin/grep -cE '\sstlr\s'`
     prints `0`, and the same pipe with `'str\s+d[0-9]+, \['` prints `1` (today's merged `str d8, [x21]`).

- [ ] **Step 4: Implement, in `build/wine-arm64-src/wine`.**

  **`dlls/ntdll/unix/msync.c`**
  - **B1, option (b).** `do_single_wait` (`:880-899`; its only callers are the wait-all first step, `:1087`, `:1099`)
    parks every leg through the pump, as alertable legs already do, and answers a spent timeout before registering
    (`msync_wait_multiple` registers before it looks at `end`, `:409-451`, so without that line a 0 ms or expired
    wait-all would pay a pump round trip; it also removes that cost from alertable legs today):
    ```c
    static NTSTATUS do_single_wait( int obj, void *obj_shm, int alert_obj, void *alert_obj_shm, ULONGLONG *end, int tid )
    {
        NTSTATUS status;

        if (alert_obj && __atomic_load_n( (int *)alert_obj_shm, __ATOMIC_SEQ_CST )) return STATUS_USER_APC;
        if (end && !update_timeout( *end )) return STATUS_TIMEOUT;
        status = msync_wait_multiple( &obj, &obj_shm, alert_obj, alert_obj_shm, 1, end, tid );
        if (alert_obj && __atomic_load_n( (int *)alert_obj_shm, __ATOMIC_SEQ_CST )) return STATUS_USER_APC;
        return status;
    }
    ```
    The pump takes a count of 1 (`server/msync.c:523-546`: one iteration, `i == count - 1` acks). `msync_wait_multiple`
    returns `STATUS_SUCCESS` after a pump wake, `STATUS_PENDING` when an object was already signalled (`:422-426`) or
    the register message failed, `STATUS_TIMEOUT` on expiry; the first step re-checks the object on SUCCESS and PENDING
    alike (its loops exit only on TIMEOUT and USER_APC, and `:1109-1129` re-checks everything). `wake_flags` is
    unchanged on both sides, so wake-one stays for single waiters.
  - **B7.** The first step's mutex loop (`:1085`) waits only while another live thread owns the mutex: loop while
    `tid != 0 && tid != ~0` (the caller's own ownership is skipped at `:1082-1083`).
  - **B4.** At the top of the wait-all branch, before `while (1)` (`:1067`): any `objs[i] == objs[j]` with `i < j`
    returns `STATUS_INVALID_PARAMETER` (at most 2,016 compares, ntsync's rule; `objs[]` are shm indices, so two handles
    to one object match).
  - **B3 and B6.** `ULONG64 taken` and `ULONG64 from_abandoned` replace `BOOL abandoned` (`:1069`, `:1072`,
    `:1146-1147`) and are cleared at `tryagain:`. Bits are `(ULONG64)1 << i` (count ≤ 64,
    `dlls/ntdll/unix/sync.c:2382`). The grab loop (`:1131-1178`) sets bit i in `taken` when this pass changed object i:
    a mutex CAS from 0 or `~0`, a semaphore decrement, an auto event 1 → 0; and in `from_abandoned` for a mutex taken
    from `~0`. The success return becomes `if (from_abandoned) return STATUS_ABANDONED;` (`:1191`). `tooslow:`
    (`:1195-1226`) loops `for (i = 0; i < count; i++) if (taken >> i & 1)`: a mutex goes back to
    `from_abandoned >> i & 1 ? ~0 : 0`, a semaphore gets `+1`, an auto event goes back to `1`; owned mutexes and manual
    events are never written. Remove the HACK comment (`:1203-1205`). B6 has no deterministic trigger (the rollback
    needs a lost race, and before this patch B7 spins first): its restore is checked by reading the diff
    (`from_abandoned` set only on a CAS from `~0`, restored only for `taken` bits); `wait-all-owned-mutex` exercises
    the `taken` mask.
  - **B2.** `tooslow:` calls `signal_all( objs_shm[i], objs[i] )` after restoring each object.
  - **R5.** After `:568`, add `mach_port_mod_refs( mach_task_self(), reply_port, MACH_PORT_RIGHT_RECEIVE, -1 );`. Keep
    `:568`: replacing it leaves dead names.

  **`server/msync.c`**
  - **R9.** `:826-827` become `mutex->count = 0;` then `__atomic_store_n( &mutex->tid, ~0, __ATOMIC_SEQ_CST );`.

  **The commit** on `macneutron`, subject `msync: Fix wait-all wakeups, rollback and duplicate objects.`, one body line
  per item:
  - B1: non-alertable wait-all legs park through the pump, which wakes every registered waiter; before, they parked on
    the object word, where a wake-one could pick a leg that only observes, so a single waiter slept with the object
    signalled. A spent timeout returns before registering.
  - B2: the rollback wakes the waiters of what it puts back. B3: it puts back only what it took, so an owned mutex stays
    owned. B6: a mutex taken from abandoned goes back abandoned.
  - B4: a repeated object returns `STATUS_INVALID_PARAMETER`, as on Windows; before, it spun or wrongly succeeded.
  - B7: an abandoned mutex no longer spins the first step.
  - R5: the shm reply port's receive right is released. R9: the abandon store is SEQ_CST.

  Then the Co-Authored-By line.

- [ ] **Step 5: Run the tests and see them pass, then rule on (b).**
  1. `make wine-arm64 wine-arm64-tests` (a development build: incremental, no configure).
  2. Three times `caffeinate -i sh wine-arm64/check.sh msync`, copying each log to `build/batch-msync/green-$i.log`.
     Expected each time: `PASS msync`, `PASS orphans`, 19 `ok` lines per mode, the mode-1 duplicate line equal to
     `$dup`, `stalls 0` and `probe-hits 0`, `w2-wins` at or above `MIN_WINS`. A failing run: re-run once before
     blaming the fix. If stalls recur, report each stall's `p_seq` and sampled states to the controller; don't change
     `STALL_SAMPLES` or `MIN_WINS` without a ruling.
  3. The static checks of Step 3.3 now print `1`, `≥ 1` and `0`.
  4. **The bar for (b)** (Ruling R11), over the three runs:
     - Fall back to (a) only if `wait-all-single-waiter` fails under (b), or mode 1's `wait-all-wake` range lies wholly
       above mode 0's (mode 1 min > mode 0 max).
     - Any other failing row, or `wait-all-poll` mode 1 after wholly above mode 1 before's range, is a bug in this
       patch: fix it; it is never a reason for (a).
     - Fallback (a): `wake_flags` returns `ULF_WAKE_ALL` for every type at `dlls/ntdll/unix/msync.c:722-733` and
       `server/msync.c:422-433`, as CrossOver 26.3.0 does; `do_single_wait` calls `msync_wait_single` for
       non-alertable legs again (the spent-timeout line stays); B2-B7, R5 and R9 stay. Amend the commit and its B1 line,
       record why, and repeat sub-steps 1-3.
  5. Record in the acceptance section, whichever way the ruling goes:

     | Row (ns), median (min–max) of 3 | mode 1 before | mode 1 after | mode 0 after |
     |---|---|---|---|
     | `wait-all-wake` | | | |
     | `wait-all-poll` | | | |
     | `auto-handoff-8` | | | |

     Also each run's `w1-wins`/`w2-wins` before and after, the option shipped, and one sentence on
     wait-all-versus-single-waiter fairness under it. If the msync step took more than 240 s, raise its cap at `:636`
     to 600.

- [ ] **Step 6: Gates.** `make wine-arm64-check`, scheduled by the controller (every step `PASS`, then
  `PASS orphans`); `make test`; `make smoke` (15/15); `make bridge-check`; `make media-check` (unchanged, Global
  Constraints).

- [ ] **Step 7: Export, prove and commit.**
  1. `make wine-arm64-export`; `git status --short wine-arm64/patches` shows one
     line, `?? wine-arm64/patches/wine/0031-msync-Fix-wait-all-…patch`.
  2. The fresh-fetch proof:
     ```sh
     t=$(mktemp -d); P="$PWD/wine-arm64/patches/wine"; . wine-arm64/pins
     git clone -q --depth 1 --branch "$WINE_TAG" "$WINE_REPO" "$t/w" && [ "$(git -C "$t/w" rev-parse HEAD)" = "$WINE_COMMIT" ] \
       && git -C "$t/w" am -q "$P"/*.patch && echo "applied $(ls "$P"/*.patch | wc -l | tr -d ' ')/31"
     [ "$(git -C "$t/w" rev-parse 'HEAD^{tree}')" = "$(git -C build/wine-arm64-src/wine rev-parse 'HEAD^{tree}')" ] && echo tree-equal
     ```
     Expected: `applied 31/31`, `tree-equal`.
  3. The README edits from Files; the 0031 line says "ours and stays local".
  4. `git add wine-arm64/tests/x64-sync.c wine-arm64/check.sh wine-arm64/README.md docs/testing/acceptance-arm64-release.md wine-arm64/patches/wine/0031-*.patch`;
     `git commit -m "msync: wait-all wakeups, rollback, duplicates and abandoned mutexes (Wine patch 0031)"` with the
     Co-Authored-By line.

### Task 2: Measurement lanes and the baseline (no runtime change)

**Files:**
- Modify: `wine-arm64/tests/x64-sync.c`: the header (three lanes); the program's name from `self` (`:567`) for
  `FAIL <name>` (`:587`) and `PASS <name>` (`:590`); new time-row functions after `uncontended` (`:484-500`); the time
  block.
- Create: `wine-arm64/tests/arm64-xcall.c`.
- Create: `wine-arm64/tools/lanes_report.py`.
- Modify: `Makefile`: `:1` (`.PHONY` gets `lanes-check`); after `:124`, the flags; `:130`, the four new targets; after
  `:141`, the explicit rules; after `:163`, `lanes-check`.
- Modify: `wine-arm64/check.sh`: after `:52`, `LANES`; `lanes_cmd` before `run_step` (`:615`); the `run_step` case after
  `:649`; `:656` and `:676` (`$STEPS $MEDIA` becomes `$STEPS $MEDIA $LANES`).
- Modify: `wine-arm64/README.md` (one line after the step table, `:87`).
- Modify: `docs/testing/acceptance-arm64-release.md` (a section, "Measurement lanes: baseline (batch Task 2)").

**Interfaces:**
- **Consumes:** Task 1's `x64-sync.c`; all 19 rows must pass in the arm64 and arm64ec lanes too.
- **Produces:**
  - `make lanes-check` = `sh wine-arm64/check.sh lanes`: a step outside `STEPS`, run by name, in `NEEDS_PREFIX` and
    `NEEDS_FEX`, mode 1 against the prefix's server. The lanes stay out of the msync step (the 2026-10-04 lightening
    holds); Task 2's new rows do add to the msync step's time in the x64 lane, in both modes.
  - Log lines `info <exe> <row> <ns>`, `<exe>` in `arm64-sync arm64ec-sync x64-sync arm64-xcall arm64ec-xcall x64-xcall`.
  - Row counts, checked by `lanes_cmd`: `SYNC_ROWS=15` time rows per `*-sync` (Task 1's 7 + this task's 8),
    `XCALL_ROWS=16` per `*-xcall`.
  - `wine-arm64/tools/lanes_report.py <dir> [<after-dir>] | --self-test`: reads `info <exe> <row> <ns>` from
    `<dir>/run1.log..run3.log` (`RUNS = 3`) and exits non-zero unless every run has the same `(exe, row)` set. The lane
    is the exe's prefix (`arm64`, `arm64ec`, `x64`), the program the rest (`sync`, `xcall`). One directory: a markdown
    table `| <program> <row> | arm64 | arm64ec | x64 | arm64ec − arm64 | x64 − arm64ec |`, cells `median (min–max)`,
    differences on medians. Two: `| <program> <row> | <lane> | before | after | Δ % | outside the band |`, Δ % =
    (after − before) / before × 100 on medians, `yes` when the ranges don't overlap.
  - The baseline table, which Task 3 (and batch Tasks 4-7, `progress.md:71`) compare against.
  - The harness contract: each program prints exactly `PASS <exe basename>`, which `exe_cmd` matches with
    `-qx "PASS $t"` (`check.sh:205`).

- [ ] **Step 1: The harness first.**
  - **Makefile.** After `:124`: `WA_FLAGS_x64-sync = -lsynchronization` and
    `WA_FLAGS_arm64-xcall = -O2 -fno-builtin -lshlwapi`. After `:141`, four explicit rules modelled on `x64-x18path.exe`
    (`:140-141`), each `$(MINGW_BIN)/<triple>-w64-mingw32-clang $(WA_FLAGS) -o $@ $< <flags>`:
    `build/wine-arm64-tests/arm64-sync.exe` (aarch64) and `arm64ec-sync.exe` (arm64ec) from
    `wine-arm64/tests/x64-sync.c` with `$(WA_FLAGS_x64-sync)`; `arm64ec-xcall.exe` and `x64-xcall.exe` from
    `wine-arm64/tests/arm64-xcall.c` with `$(WA_FLAGS_arm64-xcall)` (`arm64-xcall.exe` comes from the `arm64-%` rule,
    `:131-132`). Add the four to `:130`. Add `lanes-check: wine-arm64 wine-arm64-tests` with recipe
    `sh wine-arm64/check.sh lanes`.
  - **check.sh.** After `:52`: `LANES="lanes"`, `NEEDS_PREFIX="$NEEDS_PREFIX $LANES"`, `NEEDS_FEX="$NEEDS_FEX $LANES"`,
    commented "measured, not gated beyond each program's PASS and row count; run by name". `lanes_cmd` starts with
    `export WINEDEBUG=-all` and drops the caller's `FEX_*` variables (as G4 does, `:150-151`, `:473`; the step runs in a
    subshell): `for v in $(env | sed -n 's/^\(FEX_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done`. Then for each
    `<exe>`: `out=$(exe_cmd "$t") || { echo "$out"; echo "FAIL lanes: $t"; return 1; }`;
    `n=$(echo "$out" | LC_ALL=C /usr/bin/grep -c '^time ' || true)`; compare with `SYNC_ROWS` (`*-sync`) or
    `XCALL_ROWS` (`*-xcall`), failing with `FAIL lanes: $t printed $n of <N> time rows`; then
    `echo "$out" | sed -n "s/^time /info $t /p"`. The case: `lanes) step lanes 900 lanes_cmd; grep '^info ' "$WORK/lanes.log" ;;`.
  - A stub `arm64-xcall.c` that prints only `PASS <name>`, so the build succeeds.

- [ ] **Step 2: Run it to see it fail.** `sh -n wine-arm64/check.sh`, then
  `make wine-arm64-tests && sh wine-arm64/check.sh lanes`. Expected: `FAIL lanes: arm64-sync` (the program prints
  `PASS x64-sync`).

- [ ] **Step 3: Name the program, see the row count fail.** In `x64-sync.c`, the name is `self` without its folder and
  `.exe`. Run Step 2's command again. Expected: `FAIL lanes: arm64-sync printed 7 of 15 time rows`.

- [ ] **Step 4: Write the rows.** Each wait has a finite timeout; a batch whose threads aren't done in 10 s prints
  `FAIL <row>: stuck`, sets `failed` and ends the row.

  **`x64-sync.c`** (reported; median of 21 batches; ns per operation):
  - `cs-uncontended`, `srw-uncontended`: an `EnterCriticalSection`/`Leave` pair, or `AcquireSRWLockExclusive`/release;
    2,000 pairs per batch.
  - `cs-contended-4`, `srw-contended-4`: 4 threads park on a manual `go` event, then each does 10,000
    lock/`counter++`/unlock cycles; from `SetEvent(go)` to the 4th exit, divided by 40,000. After the batches:
    ```c
    if (counter != 40000 * BATCHES) printf("FAIL %s: counter %ld of %d\n", row, counter, 40000 * BATCHES), failed = 1;
    ```
  - `waitonaddress-uncontended`: `WaitOnAddress(&v, &other, 4, INFINITE)` with `v != other` plus
    `WakeByAddressSingle(&v)`, per pair.
  - `waitonaddress-contended-4`: 4 threads pass a turn around a ring; thread i waits with
    `WaitOnAddress(&turn, &seen, 4, 5000)` until `turn == i`, sets `turn = (i + 1) % 4`, calls
    `WakeByAddressAll(&turn)`; 2,000 handoffs per batch, ns per handoff.
  - `wait-any-wake`: half a round trip, both sides in
    `WaitForMultipleObjects(2, {own auto event, never-set}, FALSE, 5000)` (msync's pump path).
  - `alertable-wake`: the same with `WaitForSingleObjectEx(own auto event, 5000, TRUE)`.

  **`arm64-xcall.c`** (about 90 lines; `#define COBJMACROS` before `<windows.h>`, plus `<shlwapi.h>`; no inline asm
  other than `#define opaque(v) __asm__ volatile("" : "+r"(v))`). It prints `time <row> <ns>`, the median of 100
  batches after one warm-up batch (`median_ns`'s pattern, `arm64-x18path.c:293-312`), then `PASS <name>`. N = 10⁴
  calls per batch unless noted:
  - `get-current-thread-id`, `get-last-error`, `tls-get-value`, `get-tick-count`, `qpc`;
  - `istream-addref`: `IStream_AddRef` on `SHCreateMemStream(NULL, 0)`, an EC vtable slot with no fast-forward
    sequence: the bare crossing;
  - `memcpy-16`, `memcpy-256`, `memcpy-4k` (N 10³), `memcpy-1m` (N 10), each also as `-offset` (source and destination
    +1);
  - `strlen-1k`; `qsort-4k`: 4,096 ints with a comparator, N 10, copied fresh each call.

  R0's `EnterCriticalSection` pair and `mt_cs4` are left out: `x64-sync`'s `cs-uncontended` and `cs-contended-4` measure
  them in the same three lanes.

- [ ] **Step 5: Run it to see it pass.**
  - `make wine-arm64-tests && sh wine-arm64/check.sh lanes`: `PASS lanes`, 93 `info <exe> <row> <ns>` lines (3 × 15 +
    3 × 16), `PASS orphans`.
  - `sh wine-arm64/check.sh msync`: `PASS msync`, the new `time` rows in both modes. Note the step's duration; over
    240 s, raise its cap at `:636` to 600.

- [ ] **Step 6: The report script.** Write `lanes_report.py`'s `--self-test` first (inline asserts: the median of
  three, the min–max cell format, Δ %, the overlap rule, and a run with a missing row rejected), run
  `python3 wine-arm64/tools/lanes_report.py --self-test` and see it fail, implement, see
  `PASS lanes_report self-test`.

- [ ] **Step 7: The baseline.** On the build after Task 1, three idle runs of `caffeinate -i sh wine-arm64/check.sh lanes`,
  copying each `lanes.log` to `build/lanes/baseline/run$i.log`. Paste
  `python3 wine-arm64/tools/lanes_report.py build/lanes/baseline` into the acceptance section, with one line each
  below it: x64 − arm64ec is FEX's entry and the x64→EC transition; arm64ec − arm64 is the EC thunks and the aux-IAT
  checker; x64 `istream-addref` is the bare crossing; x64 `get-current-thread-id` − x64 `istream-addref` is the
  fast-forward sequence's cost; x64 `get-last-error` − x64 `get-current-thread-id` is the alias hop.

- [ ] **Step 8: Commit.** `git add` the two test sources, `lanes_report.py`, `Makefile`, `check.sh`, `README.md` and
  the acceptance doc; message
  `tests: ARM64, ARM64EC and x64 sync and call-crossing lanes (make lanes-check) and their baseline`, with the
  Co-Authored-By line.

### Task 3: ARM64EC acquire/release and the PE M1 baseline (Wine 0032, DXMT 0038)

**Files:**
- Modify (Wine tree): `include/winnt.h:7973` and its `#endif` comment at `:7984`.
- Modify (DXMT tree): `build-arm64ec.txt:12-13`.
- Modify: `wine-arm64/lib.sh` (`pe_baseline_check` after `translator_key`, `:154-169`).
- Modify: `wine-arm64/build.sh`: after `:46`, `PE_MARCH=-march=armv8.5-a+fp16fml+aes+sha3` with a comment on Apple
  tuning; `:328`, `CROSSCFLAGS="-g -O2 -ffile-prefix-map=$SRC/= $PE_MARCH"`; after `:355` (the
  `make -C "$SRC/wine-build" …` line), `pe_baseline_check "$SRC/wine-build"`, so the guard reads what this make built;
  `:373`, `-DCMAKE_C_FLAGS=$PE_MARCH -DCMAKE_CXX_FLAGS=$PE_MARCH`, keeping `-DTUNE_CPU=none`; `:412`, `"$D/build-arm64ec.txt"`
  added to the `cat` in `inputs`, so a changed cross file sets DXMT up afresh.
- Modify: `Makefile`: `PE_MARCH = -march=armv8.5-a+fp16fml+aes+sha3` after `:5`, appended to `MINGW_A64` (`:8`),
  `MINGW_EC` (`:57`) and `MINGWXX_EC` (`:58`). The `wine-arm64/tests` rules (`:131-143`) stay as they are.
- Modify: `wine-arm64/README.md`: one sentence in the llvm-mingw bullet (`:31-33`) on the PE instruction set and the
  Apple-tuning ban; `:281`, "0001-0038 are ours"; an 0032 line after the 0031 entry.
- Modify: `docs/testing/acceptance-arm64-release.md` (a section, "PE M1 baseline (batch Task 3)").
- Create, by export: `wine-arm64/patches/wine/0032-*.patch`, `wine-arm64/patches/dxmt/0038-*.patch`.

**Interfaces:**
- **Consumes:** Task 2's `check.sh lanes`, `lanes_report.py` and `build/lanes/baseline/`.
- **Produces:** `pe_baseline_check <wine-build dir>` in `lib.sh`: returns 0, or calls `die`. R1 is checked on
  `dlls/ntdll/arm64ec-windows/sync.o` (0 acquire, 0 release today; ntdll.dll's EC range already holds 1 acquire, so a
  DLL count could not catch an R1 regression); LSE on ntdll.dll's ARM64 and ARM64EC code, as the maintainer's decision
  names it, found through its CHPE CodeMap (`llvm-readobj --coff-load-config`; today `0x73000 - 0xE0028  ARM64EC`,
  ImageBase `0x180000000`). Counts use `|| true` (`build.sh` runs `set -eu`, and `grep -c` exits 1 on 0). Patterns:
  LSE `\s(cas|casp|ldadd|ldclr|ldeor|ldset|ldsmax|ldsmin|ldumax|ldumin|swp)(a|l|al)?[bh]?\s`; acquire
  `\s(ldar|ldapr|ldapur)[bh]?\s`; release `\s(stlr|stlur)[bh]?\s` (with the flag, release stores can be `stlur`);
  LL/SC, reported only, `\s(ldaxr|stlxr)[bh]?\s`. The CodeMap parse is the one part the patterns don't fix (probed
  under `/bin/sh -eu` on today's build):
  ```sh
  pe_baseline_check() {  # pe_baseline_check <wine-build dir>
    _pb_o="$1/dlls/ntdll/arm64ec-windows/sync.o" _pb_f="$1/dlls/ntdll/aarch64-windows/ntdll.dll"
    _pb_lse='\s(cas|casp|ldadd|ldclr|ldeor|ldset|ldsmax|ldsmin|ldumax|ldumin|swp)(a|l|al)?[bh]?\s'
    for _pb in "$_pb_o" "$_pb_f"; do [ -f "$_pb" ] || die "no $_pb: run pe_baseline_check after make"; done
    _pb_a=$(llvm-objdump -d "$_pb_o" | LC_ALL=C /usr/bin/grep -cE '\s(ldar|ldapr|ldapur)[bh]?\s' || true)
    _pb_r=$(llvm-objdump -d "$_pb_o" | LC_ALL=C /usr/bin/grep -cE '\s(stlr|stlur)[bh]?\s' || true)
    [ "$_pb_a" -gt 0 ] && [ "$_pb_r" -gt 0 ] \
      || die "ntdll's arm64ec sync.o: $_pb_a acquire loads, $_pb_r release stores (include/winnt.h's ARM64EC guard)"
    _pb_base=$(llvm-readobj --file-headers "$_pb_f" | awk '/ImageBase:/ { print $2; exit }')
    for _pb_k in ARM64 ARM64EC; do
      # shellcheck disable=SC2046  # the range's two ends
      set -- $(llvm-readobj --coff-load-config "$_pb_f" \
        | awk -v k="$_pb_k" '/CodeMap \[/ { m = 1; next } m && /\]/ { exit } m && $4 == k { print $1, $3 }')
      [ $# = 2 ] || die "ntdll.dll's CodeMap has no $_pb_k range"
      _pb_n=$(llvm-objdump -d --start-address=$((_pb_base + $1)) --stop-address=$((_pb_base + $2)) "$_pb_f" \
        | LC_ALL=C /usr/bin/grep -cE "$_pb_lse" || true)
      [ "$_pb_n" -gt 0 ] || die "ntdll.dll's $_pb_k code: 0 LSE atomics (the PE side isn't on the M1 baseline)"
    done
  }
  ```

- [ ] **Step 1: Write the failing guard** (`pe_baseline_check` above, in `lib.sh`; `build.sh` doesn't call it until
  Step 4).

- [ ] **Step 2: Run it to see it fail.**
  ```sh
  PATH="$(sh dxmt/toolchain.sh):$PATH" sh -euc '. wine-arm64/lib.sh; pe_baseline_check build/wine-arm64-src/wine-build'
  ```
  Expected: `wine-arm64: ntdll's arm64ec sync.o: 0 acquire loads, 0 release stores (include/winnt.h's ARM64EC guard)`.

- [ ] **Step 3: R1.** In the Wine tree, `include/winnt.h:7973` becomes
  `#if (defined(__x86_64__) && !defined(__arm64ec__)) || defined(__i386__)` (the idiom at `:8076`); the `#endif`
  comment at `:7984` matches. Commit with the subject
  `include: Use acquire/release for ReadAcquire and WriteRelease on ARM64EC.`; the body names the sites: RtlRunOnce,
  RtlBarrier, the LFH bin flag, GetOverlappedResult, the msvcp/concrt queue-lock unlock.

  The R1 codegen check: rebuild the one object,
  `PATH="$(sh dxmt/toolchain.sh):$PATH" make -C build/wine-arm64-src/wine-build dlls/ntdll/arm64ec-windows/sync.o`,
  and re-run Step 2's command. Expected:
  `wine-arm64: ntdll.dll's ARM64 code: 0 LSE atomics (the PE side isn't on the M1 baseline)` (the R1 check passes; a
  compile probe gave 14 `ldar`, 3 `stlr`). Record the object's acquire and release counts.

- [ ] **Step 4: R2.**
  - Apply the `build.sh` and `Makefile` edits from Files.
  - In the DXMT tree, `build-arm64ec.txt:12-13` become `c_args = ['-marm64x', '-march=armv8.5-a+fp16fml+aes+sha3']`
    and the same for `cpp_args`; link args unchanged. Commit with the subject
    `build: Target the Apple M1 instruction set in the ARM64X cross file.`
  - DXMT's translator key (`lib.sh:154-169`) doesn't hash the cross file, and airconv is built with Apple clang, so
    shader caches stay valid.

- [ ] **Step 5: The full rebuild.**
  - `rm -f build/dxmt-tests-arm64ec/*.exe`: their rules (`Makefile:64-67`) depend only on the sources, so the gate
    would otherwise run the old binaries.
  - `make wine-arm64`: Wine configures afresh (`CROSSCFLAGS` changes `.configure-inputs`), FEX and DXMT set up afresh.
    Expected: `wine-arm64: built …/wine.app`, the guard passing silently after Wine's `make`.
  - If llvm-mingw fails on a source (`Failed to evaluate function length in SEH unwind info`, or any backend error),
    stop and report the file. Never add `-mcpu=apple-m1`, `-mtune=apple-*` or `-falign-loops`.

- [ ] **Step 6: Verify the codegen and the licence.** Record before → after (before measured at bb65ef0):

  | Binary | LSE | LL/SC | acquire | release |
  |---|---|---|---|---|
  | `wine-build/dlls/ntdll/aarch64-windows/ntdll.dll`, ARM64 range | 0 → > 0 | 236 → | 19 → | 4 → |
  | the same, ARM64EC range | 0 → > 0 | 236 → | 1 → | 0 → |
  | `wine-build/dlls/ntdll/arm64ec-windows/sync.o` | 0 → > 0 (a probe gave 62) | 114 → | 0 → > 0 | 0 → > 0 |
  | `fex-ec/Bin/libarm64ecfex.dll` | 0 → > 0 | | | |
  | `wine.app/Contents/Resources/DXMT/aarch64-windows/d3d11.dll` | 0 → > 0 | | | |

  Also:
  - `/usr/bin/grep -c 'march=armv8.5-a+fp16fml+aes+sha3' build/wine-arm64-src/dxmt-build/build.ninja` is > 0.
  - `make -n -B build/dxmt-tests-arm64ec/present_loop.exe build/dxmt-tests-arm64ec/d3d12_api.exe bridge | /usr/bin/grep -c 'march=armv8.5-a+fp16fml+aes+sha3'`
    prints `4` (present_loop, d3d12_api, steam.exe, helper.exe).
  - **The licence re-scan** (native REPORT §5 item 8). The flag can't change what is linked: `ff_crc32_aarch64` is
    referenced whenever a module uses `av_crc` (`libs/ffmpeg/libavutil/crc.c:421-422`, `aarch64/crc.h:41-43`,
    `HAVE_ARM_CRC 1` at `config.h:42`, `ARCH_AARCH64` forced at `:836-839`), and zlib's CRC32 path stays off because
    Wine builds zlib with `-DZ_SOLO` (`configure.ac:1235`). The flag changes only runtime-dispatched FFmpeg paths. So
    this re-confirms the existing state:
    ```sh
    N="$(sh dxmt/toolchain.sh)/llvm-nm"; AW=build/wine-arm64/wine.app/Contents/Resources/lib/wine/aarch64-windows
    "$N" "$AW/colorcnv.dll" | wc -l   # positive control: thousands of symbols (15,029 today), not 0
    n=0; for f in "$AW"/*; do n=$((n+1)); "$N" "$f" 2>/dev/null | /usr/bin/grep -q ff_crc32_aarch64 && echo "HIT $f"; done; echo "scanned $n"
    ```
    Expected: no `HIT`, `scanned` about 1,003. A count far below that, or a control of 0, means the tool or the glob
    failed, not a pass. A `HIT` is a pre-existing exposure, not one this batch caused: stop and report it to the
    controller (the fix would be a Wine patch dropping `libavutil/aarch64/crc.S` and `libavutil/arm64ec/crc.S`,
    `libs/ffmpeg/Makefile.in:7`, `:23`; its number is the controller's ruling).

- [ ] **Step 7: Gates.** `make wine-arm64-check`, scheduled by the controller: every step passes (it rebuilds the
  ARM64EC DXMT tests with `PE_MARCH`), `translator_key_test` passes, and `DXMT/version` reads `<DXMT_COMMIT>+dev` (the
  DXMT tree stays development until Step 8's export). `make test`; `make smoke` (15/15); `make bridge-check` (`steam.exe`
  is now built with `PE_MARCH`); `make media-check` (unchanged).

- [ ] **Step 8: Export and prove.**
  1. `make wine-arm64-export`; `git status --short wine-arm64/patches` shows only the 0032 and 0038 files.
  2. Wine: Task 1 Step 7.2's commands (they start a new `t=$(mktemp -d)`) with `/32`, expecting `applied 32/32` and
     `tree-equal`.
  3. DXMT, mirroring `fetch_dxmt` (`build.sh:80-88`):
     ```sh
     t=$(mktemp -d); P="$PWD/wine-arm64/patches/dxmt"; . dxmt/pins
     git init -q "$t/d" && git -C "$t/d" fetch -q --depth 1 "$DXMT_REPO" "$DXMT_COMMIT" && git -C "$t/d" checkout -q FETCH_HEAD \
       && git -C "$t/d" am -q "$P"/*.patch && echo "applied $(ls "$P"/*.patch | wc -l | tr -d ' ')/38"
     [ "$(git -C "$t/d" rev-parse 'HEAD^{tree}')" = "$(git -C build/wine-arm64-src/dxmt rev-parse 'HEAD^{tree}')" ] && echo tree-equal
     ```
     Expected: `applied 38/38`, `tree-equal`.
  4. One `make wine-arm64` (the trees are now `applied`); `DXMT/version` reads `<DXMT_COMMIT>+<series>`; record it.

- [ ] **Step 9: Measure again.** Three idle runs of `caffeinate -i sh wine-arm64/check.sh lanes`, logs to
  `build/lanes/m1/run$i.log` (the test programs are Task 2's binaries: their sources and flags didn't change). Paste
  `python3 wine-arm64/tools/lanes_report.py build/lanes/baseline build/lanes/m1` into the acceptance section. The prose
  under it names the contended CS/SRW/WaitOnAddress rows and the `xcall` rows that moved outside the band, and says
  plainly if nothing did.

- [ ] **Step 10: Commit.** `git add wine-arm64/build.sh wine-arm64/lib.sh Makefile wine-arm64/README.md docs/testing/acceptance-arm64-release.md wine-arm64/patches/wine/0032-*.patch wine-arm64/patches/dxmt/0038-*.patch`;
  message `PE side on the Apple M1 instruction set, ARM64EC acquire/release (Wine 0032, DXMT 0038), measured`, with
  the Co-Authored-By line.
