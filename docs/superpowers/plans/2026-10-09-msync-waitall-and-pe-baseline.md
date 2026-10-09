# msync wait-all fixes, measurement lanes and the PE M1 baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** msync's wait-all stops losing wakeups, breaking mutual exclusion and spinning; three lanes (ARM64, ARM64EC,
x64) measure sync and call-crossing costs; then every PE binary is built for the Apple M1 instruction set with real
acquire/release in ARM64EC code, measured before and after.

**Goal, Tasks 4-7:** four native levers, each measured on the same lanes: FEX drops software TSO wherever a module's
volatile metadata allows it, ARM64EC import calls skip the call checker until their target is hooked, the CRT's string
routines become Arm's SIMD ones, and the redistributables' builtins are guarded against drift.

**Architecture:** Task 1 is one test-first Wine patch (0031) to msync's wait-all in `dlls/ntdll/unix/msync.c` and
`server/msync.c`: non-alertable legs park through the pump, the rollback puts back only what it took and wakes its
waiters, and duplicate objects and abandoned mutexes stop spinning. Task 2 builds `x64-sync.c` and a new
`arm64-xcall.c` for three lanes, run by an opt-in `check.sh lanes` step, and records a baseline. Task 3 is one full
rebuild with the `winnt.h` ARM64EC guard (Wine 0032) and `-march=armv8.5-a+fp16fml+aes+sha3` on every PE build (Wine,
FEX, DXMT 0038, the Makefile's `MINGW_*`), guarded after the build, then re-measures the lanes.

**Architecture, Tasks 4-7:** Task 4 is FEX patch 0006: a block inside a volatile-metadata range runs without TSO except
for its listed accesses (and MonoHacks' flagged ones), whether or not one falls in it (`Core.cpp:576-583`, `:667-676`);
`VolatileMetadata` is read again, and FEX logs each image's coverage. Task 5 is Wine 0033: the loader fills an ARM64EC
importer's auxiliary IAT once its imports are bound, reading only loaded images, and an entry goes back to its check
stub once a page it was resolved through is made writable, in this process or from another (Ruling R13). Task 6 is
Wine 0034: msvcrt's memmove, strlen, strnlen, strchr, strrchr, strcmp and memchr run Arm Optimized Routines v26.07
(MIT) on both PE halves, with an ARM64EC register gate after the build. Task 7 is a bundle guard against prefer-native
drift, and a redistributable forwarder only if the controller's log audit asks for one and the game runs with it
(Ruling R14).

**Tech Stack:** C (Wine's unix and PE sides, the wineserver), Mach ulock/IPC, llvm-mingw 23.1.1 (aarch64, arm64ec and
x86_64 triples), meson cross files, CMake (FEX), POSIX sh (`build.sh`, `lib.sh`, `check.sh`), make, Python 3
(`lanes_report.py`).
Tasks 4-7 add FEX's C++ (`Core.cpp`, `ImageTracker`), Wine's ARM64EC loader code (`signal_arm64ec.c`, `loader.c`) and
Arm Optimized Routines' AArch64 assembly (MIT).

**Spec:**
- `.superpowers/brainstorm-sync/REPORT.md` §3.3 (B1-B6) and §4 (R1, R4, R5, R9, "R1 in detail", "R4 in detail");
  background in `.superpowers/brainstorm-sync/msync-today.md`.
- `.superpowers/brainstorm-native/REPORT.md` §3 (R0, R1, R2) and §5 item 8 (the licence re-scan); per-file edits in
  `.superpowers/brainstorm-native/codegen-baseline.md` §9.
- The maintainer's decisions, `.superpowers/sdd/2026-10-08-macneutron-video-playback/progress.md:62-65` (2026-10-09,
  "Proceed in that order and also fix B1"): Ruling R11 makes B1 option (b) with (a) as the fallback; Ruling R12 sets
  the scope. Batch Tasks 4-7 (`progress.md:67-71`) come from a second plan and consume Task 2's lanes.
- Tasks 4-7: `.superpowers/brainstorm-native/REPORT.md` §2.2, §2.5, §2.6, §3 (R3, R4, R5, R7), §4 and §5, with
  `fex-arm64ec.md` §2.2, `builtin-overrides.md` §5.2 and `inventory.md` §6.2-6.3 in the same folder; the maintainer's
  decision of 2026-10-09 ("Also do R4 and the additional levers") and Rulings R13-R15, `progress.md:67-71`.

All file:line references are at Wine tree HEAD 38640fe (patch 0030), DXMT tree HEAD 5ed2a79 (patch 0037) and repo HEAD
bb65ef0.

Tasks 4-7 cite the same Wine tree (the files they touch are not in 0031, and 0032's one-line `winnt.h` edit moves no
line, so 38640fe's numbers hold), FEX tree HEAD 4adb8a1 (patch 0005), the built `build/wine-arm64-src/wine-build` and
`build/wine-arm64/wine.app` of bb65ef0, and Arm Optimized Routines tag v26.07
(`4be260a5117480382690c6d8c300bc784e927d76`). Their edits to `check.sh`, `Makefile`, `lib.sh`, `build.sh`, `bundle.sh`,
`README.md` and the acceptance doc land after Tasks 1-3's: line numbers there are bb65ef0's, and each edit also names
the text it goes beside, which is what counts once Tasks 1-3 have moved lines.

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
- **Patch numbers, Tasks 4-7:** FEX 0006 (Task 4); Wine 0033 (Task 5) and 0034 (Task 6); Wine 0035 (Task 7's
  `xaudio2_9redist` forwarder) only if Task 7's audit asks for it, and an `amd_ags_x64` module only after a ruling, on
  the next number. The video plan's numbers start after the last of these.
- **No upstream submission, ever** (Wine, FEX, DXMT): every new patch is "ours and stays local".
- **The PE flag** is exactly `-march=armv8.5-a+fp16fml+aes+sha3`. Never `-mcpu=apple-m1`, `-mtune=apple-*` or
  `-falign-loops=16` (Apple tuning crashes llvm-mingw's SEH unwind emitter). FEX keeps `-DTUNE_CPU=none` and gets the
  flag as one token. DXMT gets it through its cross file (a patch), never `-Dc_args`. The programs in
  `wine-arm64/tests` keep their flags, so before/after measures the runtime, not the harness.
- **msync:** stays on by default; the client/server mode-agreement rule and `MSYNC_REGISTER_SPINS` are unchanged. B5
  (PulseEvent), sync R6/R7/R8, WFUSync and native R3-R7 are out of scope.
- **Scope, Tasks 4-7** (maintainer, 2026-10-09): native R4, R3, R5 and R7 come in as Tasks 4-7, so the bullet above's
  "native R3-R7 are out of scope" holds for Tasks 1-3 only. Native R6 (a note at most, if Task 2's baseline shows more
  than ~5 ns per crossing), WFUSync and any upstream submission stay out; FEX 0006 is local only (Ruling R15).
- **Controller steps and downloads, Tasks 4-7:** a step marked **STOP (controller)** is the controller's alone up to
  its hand-over (Task 4 Steps 1 and 8, Task 7 Steps 3 and 6); the implementer never reads a game install or a game log
  and never launches a game. Nothing is downloaded without the maintainer's OK: Task 6 Step 5 stops for it.
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

**Tasks 4-7:**

1. **A program with no volatile metadata** (every mingw build; MSVC from VS 2022 18.6) → full software TSO as before:
   G2's default `x64-litmus` run stays at 0 forbidden (Task 4 Steps 5 and 7), and no lane row moves (Task 4 Step 6).
2. **A title whose code carries MSVC volatile metadata** → its listed accesses keep TSO (Task 4's listed-instruction
   control, `x64-litmus listed` at 0 forbidden before and after 0006) and SMITE 2 plays with its metadata on (Task 4
   Step 8, when its `VolatileMetadataPointer` isn't 0).
3. **A Unity title whose UnityPlayer.dll has volatile metadata** → its ring-buffer accesses keep TSO (`FLAG_FORCE_TSO`
   wins inside a range, Task 4 Step 4; checked by reading the diff).
4. **A detour or an IAT hook applied after load** (an overlay, ReShade, anti-cheat) → an ARM64EC caller still reaches
   the hook (Task 5 rows `ffs-hook`, `iat-hook`), and entries resolved through other pages stay filled (row
   `per-entry`).
5. **A hook installed while another thread loads a DLL** → the new DLL's ARM64EC calls reach the hook (Task 5 Step 3's
   order: bits published, pages queried, the target resolved twice; Step 4's revert after the protect; checked by
   reading the diff).
6. **A DLL unloaded after its auxiliary IAT was filled, its range then reused** → nothing is written there (Task 5 row
   `unload`).
7. **Strings and buffers that end on the last byte before a `PAGE_NOACCESS` host page, or start right after one, at
   any alignment, or overlap (memmove)** → no fault, and the byte loop's answer, in all three lanes (Task 6 step `crt`).
8. **`strcmp` on bytes ≥ 0x80** → exactly -1, 0 or 1, as Wine's C version answers (Task 6 `crt` row `strcmp`).
9. **A Wine rebase where a CRT or DirectX redistributable builtin gains `--prefer-native`, or `version_heuristics`
   stops sending Microsoft DLLs to `LO_DEFAULT`** → `bundle.sh` stages nothing (Task 7 `prefer_native_check`;
   `prefer_native_test` items 2-3); and, if the forwarder ships, a game's own `xaudio2_9redist.dll` is replaced by it,
   with every export the game's copy has, and the game keeps its audio (Task 7 Steps 3-6).

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

### Task 4: Volatile-metadata ranges run every covered block without TSO (FEX patch 0006)

**Files:**
- Modify (FEX tree): `FEXCore/Source/Interface/Core/Core.cpp:576-583` (the block rule) and `:667-676` (the
  per-instruction choice).
- Modify (FEX tree): `Source/Windows/Common/ImageTracker.h:66` (one option after it); `Source/Windows/Common/ImageTracker.cpp:188`
  (the PE tables' switch) and `:196-199` (the coverage line).
- Modify: `wine-arm64/tests/x64-bench.cpp`: the header `:1-8`; `NOINLINE` on `mem_seq_read` (`:311`) and
  `mem_seq_write` (`:323`).
- Modify: `wine-arm64/check.sh`: `BATCH` after Task 2's `NEEDS_FEX="$NEEDS_FEX $LANES"`; `VMD_RATIO` and `fex_vmd_cmd`
  after `g5_jit_cmd` (`:440-451`); the case after Task 2's `lanes)` case.
- Modify: `wine-arm64/README.md`: a row after the `steam-bridge` row of the ship-base step table (`:87`); an 0006 line
  after `- 0002 is ours.` (`:275`); `:279`'s "(0006's is given above" becomes "(Wine 0006's is given above".
- Modify: `docs/testing/acceptance-arm64-release.md`: a new last section, "FEX volatile metadata (batch Task 4)".
- Create, by export: `wine-arm64/patches/fex/0006-*.patch`.

**Interfaces:**
- **Consumes:** Task 2's `check.sh lanes` and `lanes_report.py`; Task 3's `build/lanes/m1/`.
- **Produces:**
  - `BATCH` in `check.sh` (Tasks 5-7 add to it): steps in `STEPS`, `NEEDS_PREFIX` and `NEEDS_FEX`, run after the rest.
  - Step `fex-vmd`, log lines `info fex-vmd x64-litmus MP forbidden=<n>`, `info fex-vmd x64-litmus listed MP forbidden=<n>`,
    `info fex-vmd ranges <EVMD string>`, `info fex-vmd <row> default <s> ranges <s>` (with ` tso-off <s>` appended
    under `VMD_CALIBRATE=1`). Every check runs; the last line names each one that failed.
  - FEX with `FEX_SILENTLOG=0` (the only way its log handler is installed, `Source/Windows/Common/Logging.cpp:37-48`):
    one stderr line per image that has metadata or EVMD,
    `I <tid> volatile metadata: <module> at <base hex>: <n> instructions, <r> ranges, <b> bytes`.
  - `FEX_VOLATILEMETADATA=0` skips an image's PE tables; EVMD, an explicit setting, still applies.
  - `build/lanes/t4/`, which Task 5 compares against.

- [ ] **Step 1: STOP (controller only, Ruling R15).** SMITE 2's metadata, read-only. The implementer doesn't touch the
  game install and goes on with Step 2:
  ```sh
  E=$(find "$HOME/Library/Application Support/Steam/steamapps/common/SMITE 2" -name 'Hemingway-Win64-Shipping.exe' | head -n 1)
  "$(sh dxmt/toolchain.sh)/llvm-readobj" --coff-load-config "$E" | LC_ALL=C /usr/bin/grep -E 'VolatileMetadataPointer'
  ```
  The controller hands the value over for Steps 8 and 10. `0x0`: SMITE 2 gains only through a hand-made EVMD, and
  Step 8 is skipped; anything else: its MSVC tables now take effect, and Step 8 runs the game both ways before 0006 is
  exported.

- [ ] **Step 2: Write the failing step.**
  - `x64-bench.cpp`: `NOINLINE` on `mem_seq_read` and `mem_seq_write`, so each keeps a symbol of its own
    (`_ZL12mem_seq_readv`, `_ZL13mem_seq_writev`; today both are inlined into `main`: a probe build with the change
    has both, back to back). The header gains "mem_seq_read and mem_seq_write stay out of line: check.sh's fex-vmd
    names their ranges". G4's layout-sensitive `call_*` rows may move with the new layout
    (`docs/testing/acceptance-arm64-wine.md` warns of it); that is not a regression.
  - `check.sh`, after Task 2's `NEEDS_FEX="$NEEDS_FEX $LANES"`:
    ```sh
    # The batch's gated steps (batch Tasks 4-7): each needs the prefix with FEX; they run after the rest.
    BATCH="fex-vmd"
    STEPS="$STEPS $BATCH" NEEDS_PREFIX="$NEEDS_PREFIX $BATCH" NEEDS_FEX="$NEEDS_FEX $BATCH"
    ```
    and the case `fex-vmd) step fex-vmd 900 fex_vmd_cmd; grep '^info ' "$WORK/fex-vmd.log" ;;`. Two litmus runs
    (about 8 s each, `docs/testing/acceptance-arm64-dxmt.md:127`) and six x64-bench runs (nine under `VMD_CALIBRATE=1`;
    G4's ten, five of them under FEX, took 6 min 5 s, `:161`) fit the 900 s cap.
  - `fex_vmd_cmd`, after `g5_jit_cmd`, commented "FEX patch 0006 (batch Task 4): EVMD ranges turn TSO off in every block
    inside them, as FEX documents (`Config.json.in:582-597`), and listed instructions keep it. Every check runs; the
    last line names each failure. VMD_CALIBRATE=1 adds three x64-bench runs with TSO off everywhere (reported, not
    gated)". `VMD_RATIO=0.75` above it. Every run drops the caller's `FEX_*` (`env $(unfex)`, as G4) and sets only its
    own; `T="$(sh "$ROOT/dxmt/toolchain.sh")"`; each failed check appends its text to `fails` as `media_run` does
    (`:594-603`): `fails="$fails${fails:+; }<text>"`. The step ends
    `[ -z "$fails" ] || { echo "FAIL fex-vmd: $fails"; return 1; }`. In this order, each always:
    1. x64-litmus with the whole module as its range:
       `env $(unfex) FEX_SILENTLOG=0 FEX_EXTENDEDVOLATILEMETADATA=x64-litmus.exe WINEPREFIX="$PFX" "$TOOL/Contents/MacOS/wine" "$TESTS/x64-litmus.exe" 10000000 2> "$WORK/fex-vmd-module.err"`.
       `f` is its `litmus MP forbidden=<n> runs=10000000` count, printed as `info fex-vmd x64-litmus MP forbidden=$f`
       (G2's control saw 8,594 with TSO off and completed in 6 s, `docs/testing/acceptance-arm64-dxmt.md:127-132`: the
       program's own handshake and CRT run without TSO here too, and that run shows they cope); `size` is
       `"$T/llvm-readobj" --file-headers`'s `SizeOfImage` (decimal, 98304 today). Checks, each appending to `fails`:
       ```sh
       [ "${f:-0}" -ge 1 ] || fails="$fails${fails:+; }x64-litmus with EVMD over the whole module: MP forbidden=${f:-none}: the range didn't turn TSO off"
       tr -d '\r' < "$WORK/fex-vmd-module.err" | LC_ALL=C /usr/bin/grep -qE "volatile metadata: x64-litmus\.exe at [0-9A-F]+: 0 instructions, 1 ranges, $size bytes\$" \
         || fails="$fails${fails:+; }FEX logged no coverage line for x64-litmus.exe (0 instructions, 1 range, $size bytes)"
       ```
    2. The listed-instruction control: the same module range, with every instruction of the litmus kernels `run` and
       `worker` listed (262 today, an EVMD of about 1.8 KB):
       ```sh
       base=$("$T/llvm-readobj" --file-headers "$TESTS/x64-litmus.exe" | awk '/ImageBase:/ { print $2; exit }')
       listed=$("$T/llvm-objdump" -d --no-show-raw-insn --disassemble-symbols=run,worker "$TESTS/x64-litmus.exe" | awk -v b=$((base)) '
         function hex(s,  i, v) { for (i = 1; i <= length(s); i++) v = v * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1; return v }
         /^[[:space:]]*[0-9a-f]+:/ { sub(/:.*/, ""); sub(/^[[:space:]]*/, ""); printf "%s0x%x", k++ ? "," : "", hex($0) - b }')
       k=$(echo "$listed" | tr ',' '\n' | LC_ALL=C /usr/bin/grep -c . || true)
       ```
       `k` of 0 fails the check (`x64-litmus.exe has no run and worker of its own`). Otherwise the run is step 1's with
       `FEX_EXTENDEDVOLATILEMETADATA="x64-litmus.exe;0x0-$(printf 0x%x "$size");$listed"` and stderr in
       `$WORK/fex-vmd-listed.err`, printed as `info fex-vmd x64-litmus listed MP forbidden=$f`; it fails unless `f` is
       `0` (`x64-litmus with run and worker listed: MP forbidden=${f:-none}: a listed access lost TSO`) and unless the
       coverage line reads `$k instructions, 1 ranges, $size bytes`. This is the path every title with MSVC metadata
       relies on once 0006 relaxes its other accesses (`Core.cpp:668-673`); it passes before 0006 and must after.
    3. x64-bench's two kernels, each range running to the next symbol (the probe build gave
       `x64-bench.exe;0x38e0-0x3950,0x3950-0x39b0`):
       ```sh
       base=$("$T/llvm-readobj" --file-headers "$TESTS/x64-bench.exe" | awk '/ImageBase:/ { print $2; exit }')
       # shellcheck disable=SC2046  # each kernel's start and the next symbol's
       set -- $("$T/llvm-nm" -n "$TESTS/x64-bench.exe" | awk 'p { print a, $1; p = 0 } $3 ~ /mem_seq_(read|write)v$/ { a = $1; p = 1 }')
       evmd=$(printf 'x64-bench.exe;0x%x-0x%x,0x%x-0x%x' $((0x$1 - base)) $((0x$2 - base)) $((0x$3 - base)) $((0x$4 - base)))
       ```
       (the `printf` only when `[ $# = 4 ]`; else `fails` gains
       `x64-bench.exe has no mem_seq_read and mem_seq_write of their own` and the bench runs are skipped).
       `info fex-vmd ranges $evmd`; then three x64-bench runs with FEX's defaults and three with
       `FEX_EXTENDEDVOLATILEMETADATA="$evmd"` (and, under `VMD_CALIBRATE=1`, three with `FEX_TSOENABLED=0`, G2's
       control switch, `:252`), alternating, `WINEDEBUG=-all`, into `$WORK/vmd/{default,ranges,tso-off}/run$i.txt`;
       a run that fails `bench_rows` (`:361-366`) appends its message to `fails` (`msg=$(bench_rows "$f") || …`). Per
       row, the median of three (`sort -n | sed -n 2p` over the `row` lines), printed as
       `info fex-vmd $r default $d ranges $v` (plus ` tso-off $o`), then:
       ```sh
       { [ -n "$d" ] && [ -n "$v" ] && awk -v v="$v" -v d="$d" -v m="$VMD_RATIO" 'BEGIN { exit !(v <= m * d) }'; } \
         || fails="$fails${fails:+; }$r took ${v:-no} s with its range, ${d:-no} s without: the range didn't turn TSO off"
       ```

- [ ] **Step 3: Run it, see it fail, and calibrate the bar.** `sh -n wine-arm64/check.sh`;
  `make wine-arm64-tests && VMD_CALIBRATE=1 sh wine-arm64/check.sh fex-vmd`. Expected: `info fex-vmd x64-litmus MP forbidden=0`;
  `info fex-vmd x64-litmus listed MP forbidden=0`; both `info fex-vmd mem_seq_* default <d> ranges <v> tso-off <o>`
  with `v` about `d` (EVMD's range-only and module forms list no instruction, so no block qualifies,
  `Core.cpp:578-582`); then the last line naming five failures, in order: the whole-module litmus count, the two
  missing coverage lines (today's line is a `DFmt`, compiled out), and both `mem_seq_*` ratios; and `PASS orphans`.
  Record the medians and both ratios `o / d`. If either `o / d` is above `VMD_RATIO`, stop and report to the
  controller before Step 4: the bar can't pass even with TSO off everywhere, so it needs a ruling, not the patch.

- [ ] **Step 4: Implement, in `build/wine-arm64-src/fex`.**
  - `Core.cpp:576-583` become:
    ```cpp
          // A block inside a valid range runs without TSO except for its listed and MonoHacks-flagged accesses (batch Task 4).
          const bool BlockInForceTSOValidRange = ForceTSOValidRanges.Contains({Block.Entry, Block.Entry + Block.Size});
          auto InstForceTSOIt = BlockInForceTSOValidRange ? ForceTSOInstructions.lower_bound(Block.Entry) : ForceTSOInstructions.end();
    ```
    The walk (`:691-693`) stays: an iterator at `end()` or past the block never equals an instruction's address. A
    block that straddles a range's edge keeps the default (TSO on).
  - The per-instruction choice (`:667-676`) becomes:
    ```cpp
              IR::ForceTSOMode ForceTSO = IR::ForceTSOMode::NoOverride;
              const bool Flagged = DecodedInfo->Flags & X86Tables::DecodeFlags::FLAG_FORCE_TSO;
              if (BlockInForceTSOValidRange) {
                const bool Listed = InstForceTSOIt != ForceTSOInstructions.end() && *InstForceTSOIt == InstAddress;
                ForceTSO = Listed || Flagged ? IR::ForceTSOMode::ForceEnabled : IR::ForceTSOMode::ForceDisabled;
              } else if (Flagged) {
                ForceTSO = IR::ForceTSOMode::ForceEnabled;
              }
    ```
    `FLAG_FORCE_TSO` is set only by MonoHacks (on by default, `Config.json.in:559-565`), on Unity's SPSC ring-buffer
    `mov`s (`Frontend.cpp:1119-1132`): today the in-range branch ignores it, which was harmless while only blocks with a
    listed access took that branch; after the rule change every covered block does, so the flag has to win there too.
  - `ImageTracker.h:66`: add `FEX_CONFIG_OPT(VolatileMetadataConfig, VOLATILEMETADATA);` after it. `ImageTracker.cpp:188`:
    call `LoadImageVolatileMetadata` only `if (VolatileMetadataConfig())` (47a8fc4b4 removed the option's last reader;
    `FEX_VOLATILEMETADATA=0` is a per-game A/B again). EVMD (`:189-194`) stays outside the switch. No binary in the
    repository carries PE metadata, so this line is checked by reading it; Step 8 uses it in the game.
  - `:196-199`: the `DFmt` becomes one `IFmt` per image, computed before `AddForceTSOInformation` moves the set: the
    number of ranges and the sum of `End - Offset` over `VolatileValidRanges` (`IntervalList::begin()`/`end()`,
    `Interval{Offset, End}`), then
    `LogMan::Msg::IFmt("volatile metadata: {} at {:X}: {} instructions, {} ranges, {} bytes", ModuleName, Address, VolatileInstructions.size(), Ranges, Bytes);`.
    (With no handler `MFmtImpl` prints nothing, `FEXCore/Source/Utils/LogManager.cpp:42-47`.)
  - Commit on `macneutron`, subject `Core: Run every block a volatile-metadata range covers without TSO.`; body: the
    rule needed a listed volatile access inside the block, so a block the metadata marks safe kept TSO and EVMD's
    documented range and module forms did nothing (852e93a made the no-instruction case deterministic); listed
    accesses and MonoHacks' `FLAG_FORCE_TSO` accesses keep TSO inside a range; `VolatileMetadata` is read again; one
    coverage line per image at INFO; ours and local only (FEX refuses AI-written code, `AGENTS.md:1`; Ruling R15).
    Then the Co-Authored-By line.

- [ ] **Step 5: Run it and see it pass.** `make wine-arm64` (FEX rebuilds from its development tree), then
  `sh wine-arm64/check.sh fex-vmd g2-litmus`. Expected: `info fex-vmd x64-litmus MP forbidden=<n ≥ 1>`,
  `info fex-vmd x64-litmus listed MP forbidden=0`, both `info fex-vmd mem_seq_* default <d> ranges <v>` with `v` near
  Step 3's `tso-off` median for that kernel, `PASS fex-vmd`; G2's default run `forbidden=0` on all four patterns,
  `PASS g2-litmus`; `PASS orphans`. A ratio above 0.75 while the litmus checks pass: report the six runs and Step 3's
  calibration to the controller; `VMD_RATIO` doesn't move without a ruling.

- [ ] **Step 6: Measure.** Three idle runs of `caffeinate -i sh wine-arm64/check.sh lanes`, each `lanes.log` copied to
  `build/lanes/t4/run$i.log`; `python3 wine-arm64/tools/lanes_report.py build/lanes/m1 build/lanes/t4`. Expected: no
  row outside the band (the lane programs are mingw builds: no metadata). A row that moves is reported, not explained
  away.
  **R6 note.** From Task 2's baseline table: x64 `get-last-error` − x64 `get-current-thread-id`, and x64
  `get-current-thread-id` − x64 `istream-addref` (medians). If either is above 5 ns, one sentence in the section: R6's
  threshold (native REPORT §3 R6) is met at <values>, and R6 stays outside this batch (maintainer, 2026-10-09).
  Otherwise one sentence saying both are below it.

- [ ] **Step 7: Gates.** Task 3 Step 7's: `make wine-arm64-check`, scheduled by the controller (every step `PASS`,
  `fex-vmd` among them and `g2-litmus` at 0 forbidden, then `PASS orphans`); `make test`; `make smoke` (15/15);
  `make bridge-check`; `make media-check` (unchanged, Global Constraints).

- [ ] **Step 8: STOP (controller, with the maintainer present): SMITE 2 with and without its metadata.** Only if Step
  1's `VolatileMetadataPointer` isn't `0x0` (else record "no metadata: A/B not run" and go on). SMITE 2's scratch copy
  on this build, as for the XeSS plan's gate (`docs/testing/acceptance-arm64-release.md:805-808`), to the lobby and
  through one practice match, twice: launch line `/usr/bin/env MACNEUTRON_LOG=1 FEX_SILENTLOG=0 %command%`, then
  `/usr/bin/env MACNEUTRON_LOG=1 FEX_SILENTLOG=0 FEX_VOLATILEMETADATA=0 %command%`. Before each launch the controller
  notes the game log's length (`L=~/Library/Logs/MacNeutron/steam-2437170.log; n0=$(wc -l < "$L" 2> /dev/null || echo 0)`)
  and afterwards reads only the new lines (`tail -n +$((n0 + 1)) "$L"`, or the whole file if it is now shorter than
  `n0`: the launcher rotated it), grepping `volatile metadata:` for the coverage lines. The controller hands over:
  hangs, crashes or visual faults in either run, the maintainer's frame-rate impression of each, and the coverage
  lines. A regression with the metadata on and not with it off stops the batch for a ruling; 0006 isn't exported
  until then.

- [ ] **Step 9: Export and prove.**
  1. `make wine-arm64-export`; `git status --short wine-arm64/patches` shows one line,
     `?? wine-arm64/patches/fex/0006-Core-Run-every-block-…patch`.
  2. The fresh-fetch proof, mirroring `fetch_fex` (`build.sh:69-78`; the trees compare submodules by commit, so none
     are fetched):
     ```sh
     t=$(mktemp -d); P="$PWD/wine-arm64/patches/fex"; . wine-arm64/pins
     git init -q "$t/f" && git -C "$t/f" fetch -q --depth 1 "$FEX_REPO" "$FEX_COMMIT" && git -C "$t/f" checkout -q FETCH_HEAD \
       && git -C "$t/f" am -q "$P"/*.patch && echo "applied $(ls "$P"/*.patch | wc -l | tr -d ' ')/6"
     [ "$(git -C "$t/f" rev-parse 'HEAD^{tree}')" = "$(git -C build/wine-arm64-src/fex rev-parse 'HEAD^{tree}')" ] && echo tree-equal
     ```
     Expected: `applied 6/6`, `tree-equal`.
  3. README: the step row
     ``| `fex-vmd` | FEX patch 0006 (batch Task 4): EVMD over x64-litmus shows MP reordering, listed instructions keep TSO, FEX logs its coverage; x64-bench's scalar-memory kernels run in at most 0.75 of their time with their ranges |``;
     after `- 0002 is ours.`, `- 0006 (volatile-metadata ranges run every block they cover without TSO, listed and MonoHacks-flagged accesses keep it; the VolatileMetadata switch is read again; a coverage line per image) is ours and stays local.`;
     and `:279`'s "(0006's is given above" becomes "(Wine 0006's is given above".

- [ ] **Step 10: Record and commit.** The section: the controller's `VolatileMetadataPointer` (Step 1); Step 3's
  calibration and Step 5's runs:

  | Row (s, median of 3) | before 0006: default | before 0006: with its range | before 0006: `FEX_TSOENABLED=0` | 0006: default | 0006: with its range | ratio |
  |---|---|---|---|---|---|---|
  | x64-bench `mem_seq_read` | | | | | | |
  | x64-bench `mem_seq_write` | | | | | | |

  | x64-litmus, MP forbidden of 10⁷ | before 0006 (Step 3) | 0006 (Step 5) |
  |---|---|---|
  | no EVMD (G2's default run) | 0 | |
  | EVMD over the whole module | | |
  | the same, `run` and `worker` listed | | |

  then Step 6's `lanes_report.py` table and the R6 sentence, and Step 8's outcome.
  `git add wine-arm64/tests/x64-bench.cpp wine-arm64/check.sh wine-arm64/README.md docs/testing/acceptance-arm64-release.md wine-arm64/patches/fex/0006-*.patch`;
  `git commit -m "FEX: volatile-metadata ranges run every covered block without TSO (FEX patch 0006), measured"` with
  the Co-Authored-By line.

### Task 5: The ARM64EC auxiliary IAT, filled at load and reverted per entry (Wine patch 0033)

**Files:**
- Modify (Wine tree): `dlls/ntdll/signal_arm64ec.c`: new code after `arm64ec_update_hybrid_metadata` (`:287-327`);
  the `NtProtectVirtualMemory` wrapper (`:775-796`); `ProcessPendingCrossProcessEmulatorWork` (`:961-1024`).
- Modify (Wine tree): `dlls/ntdll/ntdll_misc.h`: two declarations after `:167-168`.
- Modify (Wine tree): `dlls/ntdll/loader.c`: `fixup_imports` before its final `return status;` (`:1522`); `free_modref`
  before its `NtUnmapViewOfSection` (`:4060`).
- Create: `wine-arm64/tests/arm64ec-hook.c` (built by the `arm64ec-%` rule, `Makefile:133-134`).
- Modify: `wine-arm64/check.sh`: `BATCH` gains `ec-hook`; the case after `fex-vmd)`.
- Modify: `wine-arm64/README.md`: a row after `fex-vmd`'s; an 0033 line after the 0032 entry.
- Modify: `docs/testing/acceptance-arm64-release.md`: "ARM64EC auxiliary IAT (batch Task 5)".
- Create, by export: `wine-arm64/patches/wine/0033-*.patch`.

**Interfaces:**
- **Consumes:** Task 4's `build/lanes/t4/` and `BATCH`.
- **Produces:**
  - ntdll's ARM64EC half (`ntdll_misc.h`, inside its `#ifdef __arm64ec__`): `void arm64ec_fill_aux_iat( HMODULE module );`
    (the loader, once a module's imports are bound) and `void arm64ec_forget_aux_iat( HMODULE module, SIZE_T size );`
    (the loader, before it unmaps a module).
  - Step `ec-hook`: `arm64ec-hook` prints `ok <row>` or `FAIL <row>: <why>` for `filled`, `ffs-hook`, `per-entry`,
    `iat-hook`, `unload`, then `PASS arm64ec-hook` or `FAIL arm64ec-hook: <n> of 5 rows failed (first: <row>)`.
  - `build/lanes/t5/`.

- [ ] **Step 1: Write the failing test,** `arm64ec-hook.c` (`<windows.h>`, `<stdio.h>`, unbuffered stdout, `RtlIsEcCode`
  through `GetProcAddress` as `arm64ec-isec.c` does). In ARM64EC naming `__imp_X` is the auxiliary IAT entry and
  `__imp_aux_X` the regular one (lld; a probe exe has `__imp_GetTickCount` at aux IAT + 0x118 and
  `__imp_aux_GetTickCount` at IAT + 0x118):
  ```c
  extern void *__imp_GetTickCount, *__imp_aux_GetTickCount, *__imp_GetLastError;
  extern void *__imp_TlsGetValue, *__imp_aux_TlsGetValue;
  ```
  `filled(p)`: `p` is EC code and lies outside this exe's image (`GetModuleHandleA(NULL)`, its `SizeOfImage`). The
  targets are chosen so that no hook row's page carries another row's entry. In the built kernel32.dll's x64 view,
  `GetTickCount` (0x59C40) is an FFS on page 0x59000 (with `GetCurrentThreadId`'s, 0x597E0, which is why that export
  isn't used here); `GetLastError` is an `ff 25` alias at 0x566C0 through IAT slot 0x5B8E0; `TlsGetValue` an alias at
  0x57E30 through slot 0x5C6C8. Rows, in this order, each printing all its failures:
  - `filled`: `filled(__imp_GetTickCount)` (an FFS export) and `filled(__imp_GetLastError)` (kernel32's `ff 25` alias
    to kernelbase's FFS), each failing as
    `FAIL filled: GetTickCount's auxiliary IAT entry is %p: not EC code outside arm64ec-hook.exe`.
  - `ffs-hook`, a detour on the export. First `filled(__imp_GetTickCount)`, else
    `FAIL ffs-hook: GetTickCount's auxiliary IAT entry isn't filled before the hook (%p): the row can't test the revert`
    and the row ends. Then `p = __imp_aux_GetTickCount` (kernel32's export, its FFS: the loader stores exports as they
    are, `loader.c:1022-1055`); save its 16 bytes; `VirtualProtect(p, 16, PAGE_EXECUTE_READWRITE, &old)`; write
    `b8 ed 5e 00 00 c3` (`mov eax, 0x5eed; ret`, run by FEX, no jump to reach); `FlushInstructionCache`;
    `r = GetTickCount()`; put the bytes and the protection back and flush. Then
    `EXPECT(r == 0x5eed, "GetTickCount() returned %lu after its export was hooked: the ARM64EC call skipped the hook")`
    and `EXPECT(GetTickCount() != 0x5eed, "GetTickCount() still answers 0x5eed after its export was restored")`.
  - `per-entry`: `filled(__imp_GetLastError)` still, else
    `FAIL per-entry: GetLastError's auxiliary IAT entry is %p after GetTickCount's export was hooked: the revert took entries the hook doesn't touch`.
  - `iat-hook`, after `per-entry` (its protect of the exe's IAT page puts every entry resolved through that page back,
    which is the design). First `filled(__imp_TlsGetValue)`, else the `ffs-hook` pre-check's message for TlsGetValue.
    Then `VirtualProtect(&__imp_aux_TlsGetValue, 8, PAGE_READWRITE, &old)`, store `fake_tls` (an EC function
    `void *fake_tls(DWORD)` returning `(void *)0x7eed`), `r = TlsGetValue(0)`, put entry and protection back;
    `EXPECT(r == (void *)0x7eed, "TlsGetValue() returned %p with its IAT entry hooked: the ARM64EC call skipped the hook")`.
  - `unload`: `GetModuleHandleA("version.dll")` is NULL (else `FAIL unload: version.dll is already loaded`);
    `LoadLibraryA("version.dll")` (ARM64X, aux IAT at 0xC000, imports kernelbase, ucrtbase, kernel32 and ntdll, all
    loaded already); keep its base and `SizeOfImage`; `FreeLibrary`; NULL again (else
    `FAIL unload: version.dll stayed loaded`); `VirtualAlloc(base, size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE)`
    (NULL: `FAIL unload: can't allocate version.dll's old range (error %lu)`, which goes to the controller, never
    around the row); fill it with 0x5a; `VirtualProtect(base, size, PAGE_READWRITE, &old)`; every byte still 0x5a,
    else `FAIL unload: version.dll's old range changed at +%#zx after FreeLibrary: a stale auxiliary IAT entry was written`.

  `check.sh`: `BATCH="fex-vmd ec-hook"`; the case `ec-hook) step ec-hook 60 exe_cmd arm64ec-hook ;;`.

- [ ] **Step 2: Run it and see it fail.** `make wine-arm64-tests && sh wine-arm64/check.sh ec-hook`. Expected:
  `FAIL filled: …` (twice), `FAIL ffs-hook: GetTickCount's auxiliary IAT entry isn't filled before the hook …`,
  `FAIL per-entry: …`, `FAIL iat-hook: TlsGetValue's auxiliary IAT entry isn't filled before the hook …`, `ok unload`,
  and the last line `FAIL ec-hook: FAIL arm64ec-hook: 4 of 5 rows failed (first: filled)`: nothing writes the
  auxiliary IAT (outside winedump, `include/winnt.h:4203,4211` are its only mentions in the tree).

- [ ] **Step 3: The fill,** in `signal_arm64ec.c` after `arm64ec_update_hybrid_metadata`.
  - State: `struct aux_entry { void **slot; void *stub; ULONG_PTR dep[4]; }` (the entry, its `AuxiliaryIATCopy` value,
    and the addresses its resolution read: the importer's regular IAT entry, then each code address and `ff 25` slot
    on the way; unused `dep` slots are 0, which the hash and the scans skip); a growable array of them, its count read
    with `__atomic_load_n` outside the lock; `static RTL_SRWLOCK aux_lock` (zeroed is initialised);
    `static UINT64 aux_pages[1024]`, a 65,536-bit hash of the dependencies' pages (bit `(addr >> 12) & 0xffff`), set
    with `__atomic_fetch_or` and read with `__atomic_load_n`, both `__ATOMIC_SEQ_CST`, so a protect anywhere else costs
    no scan.
  - `aux_in_image( p, len )`: `LdrFindEntryForAddress( p, &mod )` succeeds and `p + len` doesn't pass
    `mod->DllBase + mod->SizeOfImage` (the fill holds the loader lock, which that walk needs).
  - `aux_resolve` mirrors `arm64x_check_call` (`:1899-1975`) in C, one `ff 25` hop at most, and reads only memory
    inside a loaded image; NULL keeps the check stub:
    ```c
    static void *aux_resolve( const BYTE *p, ULONG_PTR dep[4] )
    {
        static const BYTE ffs[10] = { 0x48, 0x8b, 0xc4, 0x48, 0x89, 0x58, 0x20, 0x55, 0x5d, 0xe9 };
        unsigned int n = 1;

        for (;;)
        {
            if (RtlIsEcCode( (ULONG_PTR)p )) return (void *)p;
            if (!aux_in_image( p, 14 )) return NULL;  /* allocate_stub's 0xdeadbeef, an unbound slot's RVA, ... */
            dep[n++] = (ULONG_PTR)p;
            if (!((ULONG_PTR)p & 15) && !memcmp( p, ffs, sizeof(ffs) ))
            {
                const BYTE *ec = p + 14 + *(const INT32 *)(p + 10);
                return RtlIsEcCode( (ULONG_PTR)ec ) ? (void *)ec : NULL;
            }
            if (n > 2 || p[0] != 0xff || p[1] != 0x25) return NULL;  /* syscall stubs and the rest keep the checker */
            dep[n] = (ULONG_PTR)(p + 6 + *(const INT32 *)(p + 2));
            if (!aux_in_image( (const void *)dep[n], 8 )) return NULL;
            p = *(const BYTE **)dep[n++];
        }
    }
    ```
  - `aux_resolve` answers what `arm64x_check_call` would branch to, with the same page-granular EC test. An import the
    loader couldn't resolve points at an `allocate_stub` stub (`loader.c:450-500`): x64 bytes in a plain
    `PAGE_EXECUTE_READWRITE` allocation outside any image, or `0xdeadbeef` once its 64 KiB is used up (`:456`); both
    keep the checker without a read. So does an `ff 25` alias whose module's imports aren't bound yet (an import
    cycle): its slot still holds an RVA.
  - `arm64ec_fill_aux_iat( module )`: the module's metadata (`arm64ec_get_module_metadata`, `:258-270`), taken only
    when the pointer lies inside the image, as `loader.c:2167-2169` checks it, with `AuxiliaryIAT` and
    `AuxiliaryIATCopy` set and a non-empty `IMAGE_DIRECTORY_ENTRY_IAT`, else return. For every thunk of every import
    descriptor (walked as `fixup_imports` walks them), `i` = its index in the IAT directory (skip a thunk outside it),
    `aux = module + AuxiliaryIAT`, `copy = module + AuxiliaryIATCopy`. A candidate is an entry with `aux[i] == copy[i]`
    and that value inside the importer's image (both hold the import's check stub; a probe exe's 45 entries all do,
    and the zero terminators and the copy table's tail fail the test). The array is sized for the module's candidates
    before `aux_lock` is taken (grown by doubling; the old one freed after the lock is released): under `aux_lock`
    nothing calls the heap or the wrapper. Then, holding `aux_lock` exclusively, per candidate:
    1. `t = aux_resolve( iat[i], dep )` with `dep` zeroed and `dep[0] = (ULONG_PTR)&iat[i]`; NULL keeps the stub;
    2. set each dependency's bit in `aux_pages`;
    3. for each dependency page not yet queried in this fill (a small per-fill list),
       `NtQueryVirtualMemory( NtCurrentProcess(), page, MemoryBasicInformation, … )`; a page that is `PAGE_READWRITE`,
       `PAGE_WRITECOPY`, `PAGE_EXECUTE_READWRITE` or `PAGE_EXECUTE_WRITECOPY` keeps the stub;
    4. resolve again; a different answer keeps the stub;
    5. record `{ &aux[i], copy[i], dep }` and write `aux[i] = t`. The aux IAT is read-only (`.rdata`, page-aligned,
       kernel32's at 0x89000): `syscall_NtProtectVirtualMemory` unprotects it and puts the old protection back, never
       the wrapper.

    Why the order: the fill runs under the loader lock on the loading thread, and a hooker on another thread (an
    overlay, anti-cheat) doesn't hold it. A hooker whose protect saw the bits waits on `aux_lock` and reverts the entry
    after the fill (Step 4); one whose protect missed them came before step 3's query (Wine's protect and query
    serialize on the unix side's virtual lock), so step 3 sees its page writable, or, if it already wrote and put the
    protection back, step 4 sees the patched bytes. A page that is writable when the fill looks keeps the checker:
    "already writable" is no gap.
  - `loader.c`, before `fixup_imports`' final `return status;` (`:1522`):
    ```c
    #ifdef __arm64ec__
        if (!status && !TRACE_ON(relay) && !TRACE_ON(snoop)) arm64ec_fill_aux_iat( wm->ldr.DllBase );
    #endif
    ```
    Every `import_dll` has re-protected its IAT by then (`:1264`), so the loader's own protects never reach a filled
    entry of this module; relay and snoop runs keep today's path.

  Rebuild (`make wine-arm64`) and run Step 2's command. Expected: `ok filled`,
  `FAIL ffs-hook: GetTickCount() returned <n> after its export was hooked: …`, `ok per-entry`,
  `FAIL iat-hook: TlsGetValue() returned <p> with its IAT entry hooked: …`, `ok unload`, last line
  `FAIL ec-hook: FAIL arm64ec-hook: 2 of 5 rows failed (first: ffs-hook)`. With the fill alone, hooks applied after
  load miss ARM64EC callers: the two rows test the revert.

- [ ] **Step 4: The revert (Ruling R13).**
  - `static void aux_revert( const void *addr, SIZE_T size )`: the page-rounded range; nothing filled: return; a range
    of 64 pages or fewer with no bit set in `aux_pages`: return. Else, holding `aux_lock` exclusively, every entry
    with a dependency in the range gets `*slot = stub` (through `syscall_NtProtectVirtualMemory`) and leaves the array
    (swapped with the last). Entries resolved through other pages stay filled: one hooked page puts back only the
    entries resolved through it. `aux_revert( NULL, 0x800000000000 )` puts back everything. The revert reads only its
    own array (the `dep[]` recorded at fill time), never `aux_resolve` or `aux_in_image`: its cross-process callers run
    on FEX's syscall path without the loader lock.
  - The wrapper (`:775-796`) reverts after a successful protect, on both of its paths:
    ```c
    #define AUX_WRITABLE (PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)
        if (!enter_syscall_callback())
        {
            status = syscall_NtProtectVirtualMemory( process, addr_ptr, size_ptr, new_prot, old_prot );
            if (!status && is_current && (new_prot & AUX_WRITABLE)) aux_revert( *addr_ptr, *size_ptr );
            return status;
        }
        ...
        status = syscall_NtProtectVirtualMemory( process, addr_ptr, size_ptr, new_prot, old_prot );
        if (!status && is_current && (new_prot & AUX_WRITABLE)) aux_revert( *addr_ptr, *size_ptr );
    ```
    After the protect, not before: the hooker writes only once the call has returned, so the entry is back before the
    write, and a fill that races the protect is settled by Step 3's order. Every in-process protect ends here (x64
    code's `VirtualProtect` and direct syscalls too; kernelbase's `WriteProcessMemory` protects first unless the page
    is already writable, `dlls/kernelbase/memory.c:636-660`, which the fill already treats as unfillable).
  - `ProcessPendingCrossProcessEmulatorWork` (`:961-1024`), for protects and writes from another process: before the
    `switch`'s per-id handling (whose cases `break` early when FEX's callback is NULL),
    `CrossProcessPostVirtualProtect` with a writable `entry->args[0]` and a zero `entry->args[1]` (the status),
    `CrossProcessFlushCache` and `CrossProcessMemoryWrite` call `aux_revert( (void *)entry->addr, entry->size )`; the
    overflowed list (`flush`) path calls `aux_revert( NULL, 0x800000000000 )`. The in-process
    `NtFlushInstructionCache` wrapper gets nothing: an in-process write needs a writable page, and the fill keeps the
    stub for a page that is writable and the protect wrapper reverts for one made writable, so its flush adds nothing;
    another process's protects and flushes arrive here only as work-list entries, so those are hooked.

  Rebuild, run. Expected: `ok` for `filled`, `ffs-hook`, `per-entry` and `iat-hook`;
  `FAIL unload: version.dll's old range changed at +0x… after FreeLibrary: a stale auxiliary IAT entry was written`;
  last line `FAIL ec-hook: FAIL arm64ec-hook: 1 of 5 rows failed (first: unload)`.

- [ ] **Step 5: The forget.** `arm64ec_forget_aux_iat( module, size )`: holding `aux_lock`, drop (without writing)
  every entry whose slot lies in `[module, module + size)`. `loader.c`, in `free_modref` before its
  `NtUnmapViewOfSection`: `#ifdef __arm64ec__`, `arm64ec_forget_aux_iat( wm->ldr.DllBase, wm->ldr.SizeOfImage );`,
  `#endif`. A dropped entry's dependencies need no clean-up: they lie in the freed image or in modules it held, and the
  entry they would revert is gone (a stale bit only costs a scan). Both declarations in `ntdll_misc.h` after
  `arm64ec_update_hybrid_metadata`'s. Rebuild, run. Expected: five `ok` lines, `PASS arm64ec-hook`, `PASS ec-hook`,
  `PASS orphans`.
  The gaps left, for the commit and the section: a protect or write from another process takes effect here before
  FEX next processes the work list (on its next syscall, FEX's `Source/Windows/ARM64EC/Module.cpp:520`), so calls in
  that window still skip the hook; delay-load IATs (not filled); syscall stubs (left on the checker).

- [ ] **Step 6: Commit in the Wine tree,** subject
  `ntdll: Fill the ARM64EC auxiliary IAT and revert an entry when what it was resolved through is made writable.`;
  body: an ARM64EC import call ran 39-67 instructions of checking (`__icall_helper_arm64ec`, `arm64x_check_call`) where
  a filled entry runs `adrp; ldr; blr`; the fill reads only loaded images and keeps the checker for anything that
  isn't EC code, an FFS or one `ff 25` hop, and for anything resolved through a writable page; a protect that makes
  writable a page an entry was resolved through, in this process or from another, puts that entry back to its
  `AuxiliaryIATCopy` stub before the hooker writes (LLVM dec0781 places the IAT on its own 4 KiB pages at the start of
  `.rdata` so the OS can detect runtime patching and revert the auxiliary IAT to call checking; reverting per entry,
  and following the FFS and `ff 25` pages, is ours); an unloaded module's entries are dropped; the gaps; ours and
  stays local. Then the Co-Authored-By line.

- [ ] **Step 7: Measure.** Three idle runs into `build/lanes/t5/`; `lanes_report.py build/lanes/t4 build/lanes/t5`.
  Expected: the arm64ec lane's `get-current-thread-id`, `get-last-error`, `tls-get-value` and `get-tick-count` lower and
  outside the band, toward the arm64 lane. If none of them moves, stop and report: row `filled` says the entries are
  filled, so the lane would be measuring something else. Besides the report:

  | Row (ns), median (min–max) of 3 | arm64, t4 | arm64ec, t4 | arm64ec, t5 | arm64ec − arm64, t4 → t5 |
  |---|---|---|---|---|
  | xcall `get-current-thread-id` | | | | |
  | xcall `get-last-error` | | | | |
  | xcall `tls-get-value` | | | | |
  | xcall `get-tick-count` | | | | |
  | xcall `qpc` | | | | |
  | xcall `memcpy-16` | | | | |
  | sync `cs-uncontended` | | | | |

- [ ] **Step 8: Gates.** As Task 4 Step 7; `isec`, `viewec`, `x18`, `dxmt-arm64ec` and `dxmt-x64` run ARM64EC code
  through filled entries.

- [ ] **Step 9: Export, prove, commit.**
  1. `make wine-arm64-export`; one line, `?? wine-arm64/patches/wine/0033-ntdll-Fill-the-ARM64EC-auxiliary-IAT-…patch`.
  2. Task 1 Step 7.2's commands with `/33`: `applied 33/33`, `tree-equal`.
  3. README: the row
     ``| `ec-hook` | Wine patch 0033 (batch Task 5): an ARM64EC program's import entries are filled; a hooked export, a hooked IAT entry and an unloaded DLL's reused range behave as without the fill |``;
     after the 0032 entry, `- 0033 (the ARM64EC auxiliary IAT filled at load, and an entry put back when a page it was resolved through is made writable) is ours and stays local.`
  4. The section: Step 7's report and table, and the gaps.
     `git add wine-arm64/tests/arm64ec-hook.c wine-arm64/check.sh wine-arm64/README.md docs/testing/acceptance-arm64-release.md wine-arm64/patches/wine/0033-*.patch`;
     `git commit -m "ARM64EC auxiliary IAT filled at load, reverted per entry on a hook (Wine patch 0033), measured"`
     with the Co-Authored-By line.

### Task 6: CRT string routines from Arm Optimized Routines (Wine patch 0034)

**Files:**
- Create (Wine tree): `dlls/msvcrt/aor_string.h`.
- Modify (Wine tree): `dlls/msvcrt/string.c`: the include after `:35`; `strlen` `:1565-1570`, `strnlen` `:1575-1583`,
  `memmove` `:3053-3155`, `strchr` `:3250-3257`, `strrchr` `:3262-3267`, `memchr` `:3272-3278`, `strcmp` `:3283-3289`.
  ucrtbase and msvcr80-120 build this file too (`PARENTSRC = ../msvcrt`).
- Create: `wine-arm64/tests/arm64-crt.c`.
- Modify: `Makefile`: `WA_FLAGS_arm64-crt` beside Task 2's `WA_FLAGS_` lines; two explicit rules after Task 2's; both
  targets in `wine-arm64-tests`' list (`:130`).
- Modify: `wine-arm64/lib.sh` (`ec_regs_check` after Task 3's `pe_baseline_check`); `wine-arm64/build.sh` (a call
  after Task 3's `pe_baseline_check "$SRC/wine-build"`).
- Modify: `wine-arm64/check.sh`: `BATCH` gains `crt`; `crt_cmd` after `media_mf_cmd` (`:607-613`); the case after
  `ec-hook)`.
- Modify: `wine-arm64/licenses/NOTICES.md` (a section before `## The MIT licence`, `:411`); `wine-arm64/licenses/README`
  (a line after `:13`); `wine-arm64/tests/licences_test.sh` (the header `:6-7`, after `:40`, after `:142`).
- Modify: `wine-arm64/README.md` (a row; an 0034 line after the 0033 one).
- Modify: `docs/testing/acceptance-arm64-release.md`: "CRT string routines from Arm Optimized Routines (batch Task 6)".
- Create, by export: `wine-arm64/patches/wine/0034-*.patch`.

**Interfaces:**
- **Consumes:** `build/lanes/t5/`, `BATCH`, the place of Task 3's `pe_baseline_check` call in `build.sh`.
- **Produces:**
  - `aor_string.h`, under `#if defined(__aarch64__) || defined(__arm64ec__)`: `static` naked, 64-byte-aligned helpers
    `void *aor_memmove( void *, const void *, size_t )`, `size_t aor_strlen( const char * )`,
    `size_t aor_strnlen( const char *, size_t )`, `char *aor_strchr( const char *, int )`,
    `char *aor_strrchr( const char *, int )`, `int aor_strcmp( const char *, const char * )` (a byte difference, any
    magnitude), `void *aor_memchr( const void *, int, size_t )`.
  - `ec_regs_check <wine-build dir>` in `lib.sh`: returns 0 or calls `die`.
  - Step `crt`; `arm64-crt` prints `ok <routine> <cases>` or `FAIL <routine>: <case>: got <x>, wanted <y>` for
    `memmove memcpy strlen strnlen strchr strrchr strcmp memchr`, then `PASS <name>` or
    `FAIL <name>: <n> of 8 routines failed`.
  - `build/lanes/t6/`.

- [ ] **Step 1: The correctness test,** `arm64-crt.c`, built `-fno-builtin` so every call reaches the DLL. Its name
  comes from `GetModuleFileNameA(NULL, …)` (as `x64-sync.c:567` does), cut after the last `\` or `/` and before `.exe`
  with the file's own loops: the harness does its own string work with the `ref_*` routines only, never the CRT
  routines under test (printf's internals still use the DLL's, so a broken routine can garble a line; check.sh's exact
  `PASS <name>` match then fails, and Step 2 shows the harness clean on today's routines). Each routine has a byte-loop
  reference in the file (`ref_*`, `noinline`; `ref_strcmp` answers -1/0/1 over unsigned bytes, as
  `string.c:3283-3289` does); the first mismatch per routine prints its `FAIL` line, with the case (length, offsets,
  c). An unhandled-exception filter prints `FAIL <name>: <routine> <case>: exception <code>` and exits 1.

  Buffers: 1 KB ones, 64-byte aligned (`__declspec(align(64))`), at offsets 0-31 for `strlen`, `strnlen` and `memchr`
  (AOR's `strlen.S` and `memchr.S` work in aligned 32-byte chunks, `bic src, srcin, 31`) and 0-15 for the rest. Two
  guard allocations, each one `VirtualAlloc` of 96 KB (`MEM_RESERVE | MEM_COMMIT`, `PAGE_READWRITE`) with `[0, 32K)` and
  `[64K, 96K)` made `PAGE_NOACCESS` by `VirtualProtect`. Wine protects whole host pages and ORs the 4K pages inside one
  (`dlls/ntdll/unix/virtual.c:1111-1127`, `:2051-2072`; 16K on this Mac, `sysctl hw.pagesize`), so a single 4K guard
  page inside a readable host page never faults: these guards are 32 KB, two host pages each. Data at the end guard
  ends on `base + 64K - 1`; data at the start guard begins at `base + 32K`. Before any case the program checks
  `IsBadReadPtr(base + 64K, 1)` and `IsBadReadPtr(base + 32K - 1, 1)` on both allocations, all TRUE, else
  `FAIL <name>: the guard pages are readable (host page size)` and exit 1. Cases:
  - **Poisoning,** in every case: the bytes a routine may read but must ignore hold what it looks for. Up to 64 bytes
    before the start: 0 for `strlen`/`strnlen`, `(char)c` for `strchr`/`strrchr`/`memchr`; after `p + n`: `(char)c`
    for `memchr`, 0 for `strnlen`; for `strcmp`, s1 and s2 differ before their starts and after their terminators.
    String bodies cycle through the bytes 0x01-0xff (so 0x01, 0x7f, 0x80 and 0xff fall in every 8- and 16-byte
    word), and the searched `c` is taken from 0x00, 0x01, 0x7f, 0x80 and 0xff as well as characters present in the
    string.
  - **Page edges,** for every routine: every length 0-300 ending on the end guard's `base + 64K - 1` (for `strlen`
    this runs AOR's page-cross path, taken when the start lies in a 4K page's last 32 bytes), and every length 0-300
    starting on the start guard's `base + 32K`; `memmove` also runs backward overlaps there, and `memmove`/`memcpy`
    and `strcmp` put one operand in each allocation.
  - `memmove`: n 0-300 × source offset 0-15 × destination offset 0-15, the destination buffer pre-filled with 0xee and
    compared whole (a write outside `[dst, dst + n)` shows); overlaps `dst = src + k`, k -64…64, n 0-300; the return
    value is `dst`; `memmove(NULL, NULL, 0)`.
  - `memcpy` (its own export with its own ARM64EC entry thunk, `ucrtbase.spec:2428`, `msvcrt.spec:1392`; a C wrapper
    of `memmove`, `string.c:3161-3164`): n 0-300 × source offset 0-15 × destination offset 0-15, non-overlapping, the
    destination pre-filled with 0xee and compared whole; the return value is `dst`.
  - `strlen`, `strnlen`: length 0-300 × offset 0-31, the bytes after the terminator nonzero; maxlen 0, L/2, L, L+1 and
    `(size_t)-1`; `strnlen(base + 64K - m, m)` over unterminated bytes for m 0-300 at the end guard (answer `m`, no
    fault); `strnlen(p, (size_t)-1)` with the terminator on the end guard's last readable byte; `strnlen(NULL, 0)`.
  - `strchr`, `strrchr`: length 0-64 × offset 0-15; c = 0, the first, a middle and the last character, an absent one,
    a byte ≥ 0x80 present in the string, and 0x100 + a present character (`(char)c` decides).
  - `strcmp`: equal strings of 0-300 at offsets 0-15 × 0-15; one difference at 0, L/2 and L-1, with the byte pairs
    ('a','b'), (0x01,0xff), (0xff,0x01) and ('a',0); both strings ending at an end guard; results compared exactly.
  - `memchr`: n 0-300 × offset 0-31; c at 0, n/2, n-1 or absent, passed as 0x100 + the byte; `memchr(p, c, (size_t)-1)`
    with `c` present before the end guard (AOR's `adds cntin, cntin, tmp` path); `memchr(NULL, c, 0)`.

  Wine's C versions accept the NULL, zero-length calls today (`string.c:3062-3066`, `:3272-3278`, `:1575-1583`).

  `Makefile`: `WA_FLAGS_arm64-crt = -fno-builtin`; `build/wine-arm64-tests/arm64ec-crt.exe` (arm64ec clang) and
  `x64-crt.exe` (x86_64 clang) from `wine-arm64/tests/arm64-crt.c` with `$(WA_FLAGS_arm64-crt)`, modelled on Task 2's
  rules (`arm64-crt.exe` comes from the `arm64-%` rule), both added to `wine-arm64-tests`' list. `check.sh`:
  `BATCH="fex-vmd ec-hook crt"`; `crt_cmd` turns the crash dialog off (as `media_mf_cmd` does) and runs `arm64-crt`,
  `arm64ec-crt` and `x64-crt` through `exe_cmd`, each always, collecting failures as `media_run` does (`:594-603`),
  last line `FAIL crt: <each failing program's FAIL line>`; the case `crt) step crt 300 crt_cmd ;;`.

- [ ] **Step 2: Run it on today's byte loops.** `make wine-arm64-tests && sh wine-arm64/check.sh crt`. Expected:
  `PASS arm64-crt`, `PASS arm64ec-crt`, `PASS x64-crt`, `PASS crt`. This is the oracle check: the references agree
  with Wine's routines before they change, so a later failure is the new code's. A failure here is a bug in the test,
  or a Wine bug to report to the controller.

- [ ] **Step 3: The register gate, red on purpose.** `lib.sh`:
  ```sh
  # ARM64EC code must not use what an x64 context can't hold: x13, x14, x23, x24, x28, v16-v31; a context round trip
  # zeroes them (Wine's dlls/ntdll/unwind.h:147-168). Clang never picks them; hand-written assembly can, and llvm-mingw
  # only warns. The msvcrt family's string.o carries Arm Optimized Routines (batch Task 6).
  ec_regs_check() {  # ec_regs_check <wine-build dir>
    for _er_m in msvcrt ucrtbase msvcr80 msvcr90 msvcr100 msvcr110 msvcr120; do
      _er_o="$1/dlls/$_er_m/arm64ec-windows/string.o"
      [ -f "$_er_o" ] || die "no $_er_o: run ec_regs_check after make"
      _er_h=$(llvm-objdump -d --no-show-raw-insn --no-leading-addr "$_er_o" | sed -n 's|//.*||; s/<[^>]*>//g; /^[[:space:]]/p' \
        | LC_ALL=C /usr/bin/grep -m 1 -E '[[:space:],[{]([xw](13|14|23|24|28)|[vqdsbh](1[6-9]|2[0-9]|3[01]))([^0-9]|$)' || true)
      [ -z "$_er_h" ] || die "$_er_m's ARM64EC string.o uses a register x64 code can't hold:$_er_h"
    done
  }
  ```
  (Probed: 0 hits on today's seven objects; an object with `mov x14, x0` and `mov v16.16b, v0.16b` gives 2. The raw
  encoding and address columns are left out on purpose: they matched as `d28` and `b18`. One file per objdump call:
  in a batch, the `arm64ec_x64` objects, which are x86-64, decoded as ARM64.) `build.sh`: `ec_regs_check "$SRC/wine-build"` after `pe_baseline_check "$SRC/wine-build"`. Then:
  ```sh
  t=$(mktemp -d); mkdir -p "$t/dlls/msvcrt/arm64ec-windows"
  echo 'void f(void) { __asm__ volatile("mov x14, x0"); }' > "$t/x14.c"
  PATH="$(sh dxmt/toolchain.sh):$PATH" sh -euc "arm64ec-w64-mingw32-clang -c -o '$t/dlls/msvcrt/arm64ec-windows/string.o' '$t/x14.c'; . wine-arm64/lib.sh; ec_regs_check '$t'"
  ```
  Expected (run here): the warning `register X14 is disallowed on ARM64EC`, then
  `wine-arm64: msvcrt's ARM64EC string.o uses a register x64 code can't hold:` ending in `mov	x14, x0`, exit 1. On
  today's tree,
  `PATH="$(sh dxmt/toolchain.sh):$PATH" sh -euc '. wine-arm64/lib.sh; ec_regs_check build/wine-arm64-src/wine-build'`
  prints nothing.

- [ ] **Step 4: The codegen check, red.**
  `"$(sh dxmt/toolchain.sh)/llvm-objdump" -d --disassemble-symbols=aor_strlen build/wine-arm64/wine.app/Contents/Resources/lib/wine/aarch64-windows/ucrtbase.dll | /usr/bin/grep -c uminp`
  prints `0`: there is no such routine, and `#strlen` is the 6-instruction byte loop.

- [ ] **Step 5: STOP: the maintainer's OK to fetch.** Ask the controller, who asks the maintainer: Arm Optimized
  Routines, `https://github.com/ARM-software/optimized-routines`, tag `v26.07`, commit
  `4be260a5117480382690c6d8c300bc784e927d76`, from
  `https://raw.githubusercontent.com/ARM-software/optimized-routines/4be260a5117480382690c6d8c300bc784e927d76/`:
  `LICENSE` (13,491 bytes), and in `string/aarch64/`: `asmdefs.h` (2,102 bytes), `memcpy-advsimd.S` (4,598),
  `strlen.S` (4,928), `strnlen.S` (2,023), `strchr-mte.S` (2,408), `strrchr-mte.S` (3,250), `strcmp.S` (4,129),
  `memchr.S` (3,787). Their git blob SHA-1s at that commit (read through the GitHub API while planning; the controller
  re-reads them from
  `https://api.github.com/repos/ARM-software/optimized-routines/contents/string/aarch64?ref=4be260a5117480382690c6d8c300bc784e927d76`
  and the repository root's listing before giving the OK):

  | File | blob SHA-1 |
  |---|---|
  | `LICENSE` | `20a4b7717cf5e46e2def2ecd47756baf3061d2bd` |
  | `asmdefs.h` | `7a0a2ef39cbea4e02478d40f96486c2ae6e5096d` |
  | `memcpy-advsimd.S` | `cbf4c581500e40e5f78eef8e143c61c6bb4d213c` |
  | `strlen.S` | `0ebb26be844c1ab37832be741e4c621b09a2ea19` |
  | `strnlen.S` | `6a96ec268f1a6d404b3c2d0f66312525ab068dd6` |
  | `strchr-mte.S` | `42b747311bc6f573d4c1cbf8371e3793bc071b44` |
  | `strrchr-mte.S` | `8668ce6d2916202bfd0e0d0d42cada0366d8cf81` |
  | `strcmp.S` | `7c0d0485a89ba175d3be64e32fc28e31364c467a` |
  | `memchr.S` | `d12a38abbc30094183cefdda921726c0b8f3e4a1` |

  The licence is "MIT OR Apache-2.0 WITH LLVM-exception", taken under MIT (Apache-2.0 stays out of the LGPL tree). Not
  `memcpy.S` (x13 and x14 with x0-x17 all in use), not the plain `strchr.S`/`strrchr.S` (v16-v18), not `strcpy.S`
  (in the directory, outside the research's set). Wait for the OK. Then, into a new empty folder outside the repository:
  ```sh
  A=$(mktemp -d)/aor; R=https://raw.githubusercontent.com/ARM-software/optimized-routines/4be260a5117480382690c6d8c300bc784e927d76
  for f in LICENSE string/aarch64/asmdefs.h string/aarch64/memcpy-advsimd.S string/aarch64/strlen.S string/aarch64/strnlen.S \
    string/aarch64/strchr-mte.S string/aarch64/strrchr-mte.S string/aarch64/strcmp.S string/aarch64/memchr.S
  do curl -fsSL --create-dirs -o "$A/$f" "$R/$f" || echo "FAILED $f"; done
  (cd "$A" && for f in LICENSE string/aarch64/*; do echo "$(git hash-object "$f") $f"; done; shasum -a 256 LICENSE string/aarch64/*)
  ```
  Expected: no `FAILED`; every `git hash-object` (no repository needed) equal to its row above, a mismatch being a STOP
  for the controller; `LICENSE` begins `MIT OR Apache-2.0 WITH LLVM-exception`. Keep the SHA-256 list for Step 11. The
  files are read, never built or run, and stay out of the repository.

- [ ] **Step 6: Transcribe, in `build/wine-arm64-src/wine`.** `dlls/msvcrt/aor_string.h`, all under
  `#if defined(__aarch64__) || defined(__arm64ec__)`. Its header's own licence line is `SPDX-License-Identifier: MIT`
  (as `dlls/libxess/xess.h:8`); below it, as provenance: the repository, tag, commit and the seven files, "upstream
  offers MIT OR Apache-2.0 WITH LLVM-exception; taken under MIT", each file's copyright line as fetched (the planning
  summaries read 2019-2023 for `memcpy-advsimd.S`; 2020-2022 for `strlen.S`, `strnlen.S`, `strchr-mte.S`; 2020-2023
  for `strrchr-mte.S`; 2012-2022 for `strcmp.S`; 2014-2022 for `memchr.S`; the fetched files decide; their upstream SPDX
  lines aren't copied), the MIT text, and the changes below. One `static` helper per routine (Interfaces), declared
  `__attribute__((naked, aligned(64)))` (AOR's dropped `ENTRY` aligned each routine to 64 bytes, `ENTRY_ALIGN(name, 6)`
  in `asmdefs.h`, and its padding `nop`s assume it; probed: the helper's section gets `IMAGE_SCN_ALIGN_64BYTES` in both
  triples), its body one `asm()` of the routine, rewritten mechanically:
  - each `#define <name> <register>` → `<name> .req <register>` at the top, `.unreq <name>` at the end (probed in both
    halves); a constant `#define` → `.set`; `__AARCH64EB__` and `TEST_PAGE_CROSS` blocks → the little-endian,
    production branch (`LS_FW` → `lsr`, `MIN_PAGE_SIZE` 4096);
  - `L(x)` → `.L<routine>_x` (the helpers share one assembly file);
  - `ENTRY`, `ENTRY_ALIAS`, `END`, `.cfi_*`, BTI and `#include "asmdefs.h"` dropped; every instruction and `.p2align`
    kept;
  - in `memcpy-advsimd.S`, `tmp1` is `x11`, not `x14`: the one register change, in both halves (x11 is free in that
    file and legal in ARM64EC, `include/winnt.h:1987-1995`);
  - no `.seh_proc`: a `.p2align` inside a `.seh_proc` body crashes llvm-mingw (`Failed to evaluate function length in
    SEH unwind info`, probed on both triples; six of the seven files align loops), and these are leaf routines that
    touch neither sp nor lr, which the unwinder handles without unwind data.

  The exported functions stay C and keep the entry thunks the compiler makes for them (probe: `#my_strlen` with
  `$ientry_thunk$cdecl$i8$i8`, its body `b aor_strlen`), so x64 callers enter through a thunk and ARM64EC callers
  branch to the helper. In `string.c`: `#include "aor_string.h"` after `:35`; under
  `#if defined(__aarch64__) || defined(__arm64ec__)`, `strlen`, `strnlen`, `strchr`, `strrchr` and `memchr` return
  their helper's result, `memmove` gains an `#elif` between its x86-64 branch (`:3055-3056`) and the C code, and
  `strcmp` keeps its contract: `int r = aor_strcmp( str1, str2 ); return (r > 0) - (r < 0);`. `memcpy`
  (`:3161-3164`) already calls `memmove`.

- [ ] **Step 7: Run it and see it pass.** `make wine-arm64` (`ec_regs_check` passes silently after Wine's make), then
  `sh wine-arm64/check.sh crt`: `PASS arm64-crt`, `PASS arm64ec-crt`, `PASS x64-crt`, `PASS crt`, `PASS orphans`.
  Step 4's command prints at least `1`. A blocked register stops the build with Step 3's message: fix the
  transcription, never the gate.

- [ ] **Step 8: Commit in the Wine tree,** subject
  `msvcrt: Use Arm Optimized Routines for memmove, strlen, strnlen, strchr, strrchr, strcmp and memchr on ARM64.`;
  body: byte loops and a scalar shift-merge memmove become AdvSIMD (16-32 bytes a step); taken from AOR v26.07 under
  MIT, the notice in `aor_string.h`; for ARM64EC, x11 for x14, the -mte strchr/strrchr, no SEH directives, helpers
  behind the C exports; strcmp still answers -1/0/1; ours and stays local. Then the Co-Authored-By line.

- [ ] **Step 9: Licences.**
  - `licences_test.sh`, after `:40`:
    `g -q '^## Arm Optimized Routines (in Wine' "$L/NOTICES.md" 2> /dev/null || miss "NOTICES.md section for Wine's Arm Optimized Routines"`
    ("Arm Limited" alone already passes on FEX's section, `:37`); in the self-test after the FFmpeg one (`:139-142`),
    the same rename, red, restore:
    `sed -i '' 's/^## Arm Optimized Routines (in Wine/## Arm Optimized Routines-less (in Wine/' "$N"` and
    `red "a NOTICES.md without Wine's Arm Optimized Routines section" "NOTICES.md section for Wine's Arm Optimized Routines"`;
    the header (`:6-7`) names it. Run `sh wine-arm64/tests/licences_test.sh build/wine-arm64/wine.app`: it prints
    `MISSING NOTICES.md section for Wine's Arm Optimized Routines` and `FAIL licences_test`.
  - `NOTICES.md`, before `## The MIT licence`:
    `## Arm Optimized Routines (in Wine: msvcrt.dll, ucrtbase.dll, msvcr80.dll-msvcr120.dll)`, naming Wine patch
    0034's `dlls/msvcrt/aor_string.h`, the repository, tag and commit, the seven files, that they are modified, the MIT
    election, the LICENSE's MIT copyright line `Copyright (c) 1999-2022, Arm Limited.` and the fetched per-file
    copyright lines in a code block.
  - `licenses/README`, after `:13`:
    `  The ARM64 string routines in msvcrt.dll, ucrtbase.dll and msvcr80-120.dll come from Arm Optimized Routines (MIT): NOTICES.md.`
  - `make wine-arm64` (both licence files are build inputs, `build.sh:113`), then `licences_test.sh` on the bundle and
    with `--self-test`: `PASS licences_test`, `PASS licences_test self-test`.

- [ ] **Step 10: Measure.** Three idle runs into `build/lanes/t6/`; `lanes_report.py build/lanes/t5 build/lanes/t6`.
  Expected: `strlen-1k` lower and outside the band in all three lanes; if not in the arm64 lane, stop and report. The
  `memcpy-*` rows are recorded as they fall (`-offset` moves source and destination together, so the lanes measure
  co-aligned copies, not the mutually misaligned case where the C loop was weakest). Besides the report, for
  `strlen-1k` and every `memcpy-*` row: `| row (ns), median (min–max) of 3 | arm64 t5 → t6 | arm64ec t5 → t6 | x64 t5 → t6 |`.

- [ ] **Step 11: Gates, export, prove, commit.** Gates as Task 4 Step 7 (`crt` among them). `make wine-arm64-export`;
  one line, `?? wine-arm64/patches/wine/0034-msvcrt-Use-Arm-Optimized-Routines-…patch`. Task 1 Step 7.2's commands with
  `/34`: `applied 34/34`, `tree-equal`. README: the row
  ``| `crt` | Wine patch 0034 (batch Task 6): msvcrt's string routines and memcpy against byte loops in all three lanes: every length to 300, every alignment, overlaps, both sides of a no-access host page |``;
  after the 0033 entry,
  `- 0034 (msvcrt's memmove, strlen, strnlen, strchr, strrchr, strcmp and memchr on ARM64 and ARM64EC from Arm Optimized Routines v26.07, MIT: licenses/NOTICES.md) is ours and stays local.`
  The section: Step 5's blob check and SHA-256 list, Step 4's count before and after, Step 10's report and table.
  `git add wine-arm64/tests/arm64-crt.c Makefile wine-arm64/lib.sh wine-arm64/build.sh wine-arm64/check.sh wine-arm64/licenses/NOTICES.md wine-arm64/licenses/README wine-arm64/tests/licences_test.sh wine-arm64/README.md docs/testing/acceptance-arm64-release.md wine-arm64/patches/wine/0034-*.patch`;
  `git commit -m "CRT string routines from Arm Optimized Routines on ARM64 and ARM64EC (Wine patch 0034), measured"`
  with the Co-Authored-By line.

### Task 7: The redistributables' builtins: drift guard and audit (Ruling R14)

**Files:**
- Modify: `wine-arm64/lib.sh` (`CRT_BUILTINS` and `prefer_native_check` after Task 6's `ec_regs_check`).
- Modify: `wine-arm64/bundle.sh` (after the version-resource check, `:307-318`).
- Create: `wine-arm64/tests/prefer_native_test.sh`; Modify: `Makefile` (`wine-arm64-check`'s recipe, after its
  `translator_key_test.sh` line, `:154`).
- Only if Step 3 asks for it: (Wine tree) `dlls/xaudio2_9redist/Makefile.in`, `dlls/xaudio2_9redist/xaudio2_9redist.spec`,
  `configure.ac` after `:3529`, `configure`; `wine-arm64/tests/x64-redist.c`;
  `wine-arm64/tests/fixtures/redist-standin.c` and `wine-arm64/tests/fixtures/redist-standin.rc`; `Makefile` (the
  stand-in's rule, and its target in `wine-arm64-tests`' list, `:130`); `check.sh` (`BATCH` gains `redist`); by export
  `wine-arm64/patches/wine/0035-*.patch`.
- Modify: `wine-arm64/README.md` (a bullet at the end of "Next Wine rebase", `:198-217`); the acceptance doc,
  "Redistributable builtins (batch Task 7)".

**Interfaces:**
- **Consumes:** `build/lanes/t6/`, `BATCH`.
- **Produces:** `CRT_BUILTINS` and `prefer_native_check <aarch64-windows dir> <Wine source tree>` in `lib.sh` (returns 0
  or calls `die`; the caller sets ROOT); `build/lanes/t7/`; if built, `xaudio2_9redist.dll` (ARM64X, forwarding to
  `xaudio2_9` every export the game's copy has), the test stand-in `build/wine-arm64-tests/xaudio2_9redist.dll`, and
  step `redist`.

- [ ] **Step 1: The failing test,** `prefer_native_test.sh <wine.app>` (`set -eu`, `. lib.sh`, a temp folder removed on
  exit, as `mode_test.sh`), with `A=<wine.app>/Contents/Resources/lib/wine/aarch64-windows` and
  `W=${BUILD_DIR:-$ROOT/build}/wine-arm64-src/wine`:
  1. `( prefer_native_check "$A" "$W" )` passes;
  2. on a copy (`cp -c`) of the guarded DLLs with `ucrtbase.dll` replaced by `mfplat.dll` (a builtin that prefers
     native: DllCharacteristics 0x170) it fails, saying `ucrtbase.dll prefers native`;
  3. on a temp tree holding copies of `dlls/ntdll/unix/unix_private.h` and `dlls/ntdll/unix/loadorder.c`, the latter
     edited by
     `sed "s/{'M','i','c','r','o','s','o','f','t',0}, LO_DEFAULT }/{'M','i','c','r','o','s','o','f','t',0}, LO_NATIVE_BUILTIN }/"`:
     `cmp -s` against the original must report a difference (else `FAIL prefer_native_test: the Microsoft row moved`),
     then the guard fails, saying `version_heuristics no longer sends`;
  then `PASS prefer_native_test`. `Makefile`: `sh wine-arm64/tests/prefer_native_test.sh build/wine-arm64/wine.app`
  after the `translator_key_test.sh` line. Run that line: it fails, `prefer_native_check` isn't defined.

- [ ] **Step 2: The guard.** `lib.sh`:
  ```sh
  # The CRT and DirectX redistributables' builtins replace a game's own x64 copies: version_heuristics sends a Microsoft
  # DLL to LO_DEFAULT (Wine's dlls/ntdll/unix/loadorder.c:431), and none of these prefers native, Wine's 0x10 in the
  # DllCharacteristics (set by tools/winebuild/build.h:210, read by dlls/ntdll/unix/unix_private.h:430). A rebase that
  # changes either moves them under FEX (native REPORT §3 R7; batch Task 7).
  CRT_BUILTINS="ucrtbase vcruntime140 vcruntime140_1 msvcp140 msvcp140_1 msvcp140_2 msvcp140_atomic_wait msvcp140_codecvt_ids"
  CRT_BUILTINS="$CRT_BUILTINS concrt140 vcomp140 msvcr120 msvcp120 msvcr100 msvcp100 d3dcompiler_43 d3dcompiler_47 d3dx9_43"
  CRT_BUILTINS="$CRT_BUILTINS d3dx10_43 d3dx11_43 xaudio2_7 xaudio2_9 x3daudio1_7 xapofx1_5 xinput1_3 xinput1_4 xinput9_1_0"
  prefer_native_check() {  # prefer_native_check <aarch64-windows dir> <Wine source tree>
    _pn_ro="$(sh "$ROOT/dxmt/toolchain.sh")/llvm-readobj"
    for _pn in $CRT_BUILTINS; do
      _pn_c=$("$_pn_ro" --file-headers "$1/$_pn.dll" \
        | awk '/ImageOptionalHeader/ { o = 1 } o && /Characteristics \[/ { gsub(/[()]/, "", $3); print $3; exit }')
      [ -n "$_pn_c" ] || die "can't read $_pn.dll's DllCharacteristics"
      [ $((_pn_c & 0x10)) = 0 ] || die "$_pn.dll prefers native ($_pn_c): a game's x64 copy would run under FEX"
    done
    LC_ALL=C /usr/bin/grep -qE '^#define IMAGE_DLLCHARACTERISTICS_PREFER_NATIVE[[:space:]]+0x0010' "$2/dlls/ntdll/unix/unix_private.h" \
      || die "ntdll no longer reads prefer-native as 0x0010 (dlls/ntdll/unix/unix_private.h)"
    LC_ALL=C /usr/bin/grep -qF "{'M','i','c','r','o','s','o','f','t',0}, LO_DEFAULT }" "$2/dlls/ntdll/unix/loadorder.c" \
      || die "loadorder.c's version_heuristics no longer sends Microsoft DLLs to LO_DEFAULT"
  }
  ```
  (A dry run on today's bundle reads `0x160` for all 26 and `0x170` for `mfplat.dll`; of the 106 redistributable-family
  builtins only `msvcp60` prefers native, upstream's choice, and it isn't listed.) `bundle.sh`, after `:318`:
  `prefer_native_check "$R/lib/wine/aarch64-windows" "$S/wine"`. Run the test: `PASS prefer_native_test`. README, at
  the end of "Next Wine rebase": `- bundle.sh's prefer_native_check fails if a CRT or DirectX redistributable builtin
  prefers native, ntdll reads another prefer-native bit, or version_heuristics stops sending Microsoft DLLs to
  LO_DEFAULT: read upstream's reason before changing CRT_BUILTINS.` `make wine-arm64` stages the bundle with the guard
  passing.

- [ ] **Step 3: STOP (controller, with the maintainer present): the log audit.** SMITE 2 in its scratch copy, as for
  the XeSS plan's gate (`docs/testing/acceptance-arm64-release.md:805-808`), with logging on (the game's log setting,
  or the launch line `/usr/bin/env MACNEUTRON_LOG=1 %command%`, whose `+loaddll` writes the `Loaded` lines), to the
  lobby and out. The log appends across launches and rotates only at a launch past its size limit
  (`Sources/MacNeutronCore/LauncherLog.swift:20-33`), so the controller notes its length first and reads only the new
  lines:
  ```sh
  L=~/Library/Logs/MacNeutron/steam-2437170.log; n0=$(wc -l < "$L" 2> /dev/null || echo 0)
  # ... the run ...
  [ "$(wc -l < "$L")" -ge "$n0" ] || n0=0  # rotated at launch: the whole file is this run
  tail -n +$((n0 + 1)) "$L" | LC_ALL=C /usr/bin/grep -aE 'Loaded L.*: native'
  tail -n +$((n0 + 1)) "$L" | LC_ALL=C /usr/bin/grep -aiE 'Loaded L.*(xaudio2_9redist|xaudio2_9|amd_ags_x64)\.dll'
  ```
  The controller hands over the lines (the home folder written as `~`) and the decision:

  | The audit shows | Then |
  |---|---|
  | `xaudio2_9redist.dll … : native` and no `xaudio2_9.dll … : builtin` | Steps 4-6 build the forwarder (Wine 0035), with the game copy's export list (below) |
  | `xaudio2_9redist.dll … : native` and `xaudio2_9.dll … : builtin` | the redist already hands its work to our builtin (builtin-overrides §5.2 rank 4: only its creation entry runs under FEX); the controller asks the maintainer whether to build the forwarder anyway (Ruling R14 allows it) and records the answer; if built, as the row above |
  | `amd_ags_x64.dll … : native` | stop for a ruling: Proton's module isn't ~20 lines, its CompanyName isn't Microsoft so it needs a launcher override (`LaunchEnvironment.swift:10-14`), and it would take the next Wine number |
  | neither | skip Steps 4-6; record "not loaded native in the SMITE 2 lobby log of <date>" |

  When the forwarder is built, the controller also reads the game copy's exports, read-only, and hands the list over:
  ```sh
  R=$(find "$HOME/Library/Application Support/Steam/steamapps/common/SMITE 2" -iname 'xaudio2_9redist.dll' | head -n 1)
  "$(sh dxmt/toolchain.sh)/llvm-readobj" --coff-exports "$R" | LC_ALL=C /usr/bin/grep -E 'Ordinal|Name'
  ```

- [ ] **Step 4 (only if Step 3 says so): the failing test.** A stand-in for the game's copy, so the test takes the path
  the forwarder exists for: a Microsoft-vendor DLL in the program's folder, which `version_heuristics` sends to
  `LO_DEFAULT` (`loadorder.c:528-544` runs it only for non-system paths) and the loader then replaces with a builtin of
  that name, if there is one.
  - `wine-arm64/tests/fixtures/redist-standin.c`: `__declspec(dllexport) HRESULT WINAPI XAudio2Create(void **p, UINT32 flags, UINT32 proc)`
    that sets `*p = NULL` and returns `E_NOTIMPL`. `wine-arm64/tests/fixtures/redist-standin.rc`: a `VERSIONINFO` with
    a `FILEVERSION` and a `StringFileInfo` block `040904B0` whose `CompanyName` is `Microsoft Corporation`.
  - `Makefile`: `build/wine-arm64-tests/xaudio2_9redist.dll: wine-arm64/tests/fixtures/redist-standin.c wine-arm64/tests/fixtures/redist-standin.rc`
    with recipe
    `$(MINGW_BIN)/x86_64-w64-mingw32-windres -o $@.res.o wine-arm64/tests/fixtures/redist-standin.rc && $(MINGW_BIN)/x86_64-w64-mingw32-clang $(WA_FLAGS) -shared -o $@ $< $@.res.o`,
    and the target added to `wine-arm64-tests`' list (`WA_TESTS` globs only `tests/*.c`).
  - `x64-redist.c`: `h = LoadLibraryA("xaudio2_9redist.dll")` (the program's folder is searched first, so it finds the
    stand-in; NULL: `FAIL x64-redist: LoadLibraryA("xaudio2_9redist.dll") failed with error %lu`); `XAudio2Create`
    through `GetProcAddress` as `HRESULT (WINAPI *)(void **, UINT32, UINT32)`, called with `(&xa, 0, 0)`; then
    `!memcmp((char *)h + 64, "Wine builtin DLL", 16)` (`bundle.sh:277`'s marker), else
    `FAIL x64-redist: xaudio2_9redist.dll is the folder's copy (XAudio2Create returned %#lx): the builtin didn't replace it`;
    the call `S_OK`, the object released through `IUnknown`; `GetModuleHandleA("xaudio2_9.dll")` non-NULL (the forward
    loaded it); `PASS x64-redist`.
  - `check.sh`: `BATCH` gains `redist`; `redist) step redist 60 exe_cmd x64-redist ;;`.

  `make wine-arm64-tests && sh wine-arm64/check.sh redist`. Expected:
  `FAIL redist: FAIL x64-redist: xaudio2_9redist.dll is the folder's copy (XAudio2Create returned 0x80004001): the builtin didn't replace it`
  (the heuristic gives `LO_DEFAULT`, but with no builtin of that name the native mapping stays).

- [ ] **Step 5 (only if Step 3 says so): the forwarder,** in the Wine tree. `dlls/xaudio2_9redist/Makefile.in` is
  `MODULE = xaudio2_9redist.dll` alone (a spec-only module, as `dlls/msvcr120_app/Makefile.in`).
  `xaudio2_9redist.spec` lists exactly the names and ordinals of Step 3's export list, each forwarding by name with
  the signature `dlls/xaudio2_9/xaudio2_9.spec:1-7` gives it, e.g.
  `1 stdcall -ordinal XAudio2Create(ptr long long) xaudio2_9.XAudio2Create`; a name `xaudio2_9.spec` lacks stops for a
  ruling. `WINE_CONFIG_MAKEFILE(dlls/xaudio2_9redist)` after `configure.ac:3529`, and `autoreconf` run with autoconf
  2.73 and `configure` committed with it (`wine-arm64/README.md:166-167`). Subject
  `xaudio2_9redist: Add a forwarder to xaudio2_9.`, the Co-Authored-By line. `xaudio2_9redist` joins `CRT_BUILTINS`.
  `make wine-arm64` (the build folder's Makefile re-runs `config.status --recheck` when `configure` changes,
  `wine-build/Makefile:1599-1600`); then `"$(sh dxmt/toolchain.sh)/llvm-readobj" --coff-exports` of the bundled
  `xaudio2_9redist.dll` shows `ForwardedTo: xaudio2_9.<name>` for every name of the list (as `msvcr120_app.dll`'s
  exports do today), and `sh wine-arm64/check.sh redist` gives `PASS x64-redist`, `PASS redist`. Nothing is exported
  yet.

- [ ] **Step 6 (only if Step 3 says so): STOP (controller, with the maintainer present): the game with the forwarder,
  then export.** SMITE 2's scratch copy on this build, to the lobby with logging on, the log read as in Step 3: its new
  lines show `Loaded L"…xaudio2_9redist.dll" … : builtin`, and the maintainer hears the lobby's audio; both go into
  the section. No audio, a crash or no builtin line: stop for a ruling, with the 0035 commit unexported. Then
  `make wine-arm64-export` (only the 0035 file); Task 1 Step 7.2's commands with `/35`: `applied 35/35`, `tree-equal`.
  README: a step row for `redist`, and after the 0034 entry
  `- 0035 (dlls/xaudio2_9redist forwards to xaudio2_9, so a game's x64 copy is replaced by the builtin) is ours and stays local.`

- [ ] **Step 7: Measure.** Three idle runs into `build/lanes/t7/`; `lanes_report.py build/lanes/t6 build/lanes/t7`.
  Expected: no row outside the band (nothing here changes what the lane programs run); paste the report.

- [ ] **Step 8: Gates and commit.** Gates as Task 4 Step 7, `prefer_native_test` now inside `make wine-arm64-check`.
  The section: Step 3's lines and decision, the guard's list, Step 6's outcome if it ran, the report.
  `git add wine-arm64/lib.sh wine-arm64/bundle.sh wine-arm64/tests/prefer_native_test.sh Makefile wine-arm64/README.md docs/testing/acceptance-arm64-release.md`,
  with `wine-arm64/tests/x64-redist.c`, `wine-arm64/tests/fixtures/redist-standin.c`,
  `wine-arm64/tests/fixtures/redist-standin.rc`, `wine-arm64/check.sh` and `wine-arm64/patches/wine/0035-*.patch` when
  Steps 4-6 ran; `git commit -m "bundle: redistributable builtins guarded against prefer-native drift, R7 audit recorded (batch Task 7)"`
  with the Co-Authored-By line.
