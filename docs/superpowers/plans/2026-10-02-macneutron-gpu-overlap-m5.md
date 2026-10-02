# GPU Overlap M5 (GPU-Side Fence Waits) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A D3D12 queue waiting on another queue's fence is released by an `MTLEvent` (under 1 µs) instead of an `MTLSharedEvent` (130–150 µs), with D3D12's fence guarantees kept, and the pre-M5 deadlock on a late lower signal fixed.

**Architecture:** `dxmt::Fence` keeps a generation (shared event, `MTLEvent`, last value asked for) under a lock. Queue `Signal` encodes both events; `Wait` skips met values and otherwise waits on the `MTLEvent` and owes a CPU wait on the shared event, retired before the command buffer's deferred signals. CPU signals are forwarded to the `MTLEvent` through a helper queue.

**Tech Stack:** C++ (fork `build/dxmt-src/dxmt`, `macneutron`), mingw tests (`dxmt/tests/d3d12_hazards.cpp`), `dxmt/check.sh`.

**Spec:** `docs/superpowers/specs/2026-10-01-macneutron-gpu-overlap-design.md` (§3.7 findings, §3.11)

## Global Constraints

- DXMT refuses AI-authored contributions: fork commits on `macneutron`, pushed before `dxmt/pins` moves; no PR upstream.
- Every test's output equals D3DMetal's (or check.sh records the difference with its reason).
- After `make dxmt`/`make dxmt-check`, `git -C build/dxmt-src/dxmt switch macneutron` before committing in the fork.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A fence signaled by the CPU while a queue waits on it, with a second queue's signal stuck behind the CPU (`fence-cpu-late`).
2. The CPU seeing a fence reached through a second queue before the first queue's timestamps (`fence-transitive`).
3. A late, lower deferred signal after another queue signaled higher (`fence-reset`, fails before M5).
4. Timestamps resolved into a GPU-readable custom heap, read by another queue after a fence (`fence-custom`).
5. A Wait committed before its Signal (`fence-wait-first`), and fence values lowered by the CPU (`fence-lower`).

---

### Task 1: Tests, failing first

**Files:** `dxmt/tests/d3d12_hazards.cpp` (modes `fence-reset`, `fence-cpu-late`, `fence-transitive`, `fence-custom`, `fence-lower`, `fence-wait-first`), `dxmt/check.sh` (want lines; a `queues` stats check: 2 queue waits on the GPU event).

- [ ] Write the modes (a second queue, fences, CPU waits with a 10 s limit that print a failure value instead of hanging).
- [ ] Run on the pinned build: `fence-reset` fails (timeout, prints 0) on ours, 6 on D3DMetal; the others print D3DMetal's values; the stats counter is absent.

### Task 2: Fence generations (fork `src/dxmt/dxmt_fence.*`, `src/d3d12/d3d12_fence.cpp`, device)

- [ ] `Fence`: `Generation {shared, gpu}` and the last value asked for, under a mutex; `Ask(value)` (a lower value starts a new generation; returns the generation); `Current()`; CPU `signal(value)` sets the shared event then forwards to the `MTLEvent` on the device's helper queue; `completedValue`, CPU `wait` and the event listener read the current generation's shared event (retained).
- [ ] The D3D12 device owns the helper queue and passes it to fences.

### Task 3: Queue Signal and Wait (fork `src/d3d12/d3d12_command_queue.cpp`, `d3d12_command_list.cpp`)

- [ ] `InflightCommandBuffer`: `owes_cpu`, CPU waits `{shared event, value}`, deferred signals `{generation, value, forward}`; `cpu_work_` counted once per buffer that owes anything.
- [ ] `Signal`: ask the fence; encode the `MTLEvent` signal unless the queue has resolved into a custom heap and owes CPU work (then forward it on retire); shared signal encoded or deferred as before.
- [ ] `Wait`: met → nothing; else `MTLEvent` wait plus a CPU wait owed.
- [ ] Retire: CPU waits, then resolves, then shared signals (and forwarded `MTLEvent` signals).
- [ ] `ResolveQueryData` marks a list that resolves into a custom heap; `ExecuteCommandLists` makes the queue's flag sticky.
- [ ] `DXMT_STATS`: `#queue waits already met`, `#queue waits on the GPU event`, `#fence signals forwarded to the GPU event`.
- [ ] Every hazard mode equals D3DMetal in strict and overlap order; commit, push, pin.

### Task 4: Checks, review, acceptance

- [ ] `make dxmt-check`, `make test`; a fresh review of the fork diff; fix its findings test-first.
- [ ] SMITE 2 (user): a trace with the build and one with the previous pin at one spot; record in `docs/testing/acceptance-dxmt-gpu-overlap.md`.
