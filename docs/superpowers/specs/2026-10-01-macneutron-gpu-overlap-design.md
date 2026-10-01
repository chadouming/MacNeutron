# MacNeutron — DXMT Fork, Sub-project 4 (second slice): GPU Work Overlap and Pass Structure

- **Date:** 2026-10-01
- **Status:** M1 and M2 done (`docs/testing/acceptance-dxmt-gpu-overlap.md`); amended 2026-10-01 after their measurements with A (cheap waits) and B (fewer command buffers), and two M3 details
- **Builds on:**
  - `2026-09-28-macneutron-dxmt-fork-design.md`: roadmap §2 item 4 (performance); `make dxmt-check`, capture mode.
  - `2026-09-30-macneutron-pipeline-cache-design.md`: the first performance slice (shader pre-caching), and `DXMT_STATS`, the pass labels and the measurements below.
- **Scope:** the GPU side of our D3D12 path, in this order (biggest gain first):
  - **M1, barrier groups:** Metal encoders stop waiting on every earlier encoder; within a command list, work between two `ResourceBarrier` calls may overlap.
  - **M2, precise transitions:** a barrier that ends a render target, depth, copy or resolve write makes the next encoder wait only on that resource's writers.
  - **A, cheap waits:** an encoder after a join waits on one fence, not on everything the join waited on, and only on the newest writer of each resource it writes.
  - **B, fewer command buffers:** `ExecuteCommandLists` and queue `Wait` encode into an open Metal command buffer; `Signal` and `Present` commit it.
  - **M3, unsplit render passes:** the base pass no longer breaks into several Metal render passes at Unreal's per-command-list timestamp blits.
  - **M4, folded clears:** a clear-only pass becomes the next render pass's load action.
  - **M5, idle gaps:** the GPU idle time left after M1–M4, traced to its causes, then fixed or explained.
  - **Out:** faster encoding on the CPU (one winemetal call per `ExecuteCommandLists`: deferred, the GPU waits for the CPU 0.17 ms per frame, §2), anything Mac-model specific, D3D11, and any change to the game or its settings.

## 1. Goal

SMITE 2 (and other D3D12 games) render more frames per second on our DXMT when the GPU is the limit, with exactly the same picture, on any Mac.

**Done when** §7 passes: the tests of §5 failed first and now pass with overlap on and off; `make dxmt-check` and `make test` are green; in SMITE 2's practice-match scene the GPU time per frame drops and the frame rate rises against the §2 baseline, with no visible difference and none in an F9 dump.

### Decisions made during brainstorming

| Decision | Choice |
|---|---|
| Order | One spec, biggest gain first: M1 → M2 → M3 → M4 → M5, each measured in SMITE 2 before the next |
| Overlap model | D3D12's barriers decide waits (approach B), built in two steps: barrier groups (M1), then resource-precise transitions (M2) |
| Unknowns | Anything not provably safe is a full join (wait on all earlier work): UAV and aliasing barriers, transitions out of the UAV state or into a write state, unknown resources, command-list starts, GPU query resolves |
| Off switch | `DXMT_D3D12_SERIAL=1` keeps today's single strict chain; F9 dumps and pixel history always use it |
| Portability | No core, GPU-model or core-count assumptions: everything follows from what the game recorded |
| Order after M1 and M2 (amendment) | A → B → M3 → M4 → M5, each measured in SMITE 2 before the next; faster CPU encoding deferred |

## 2. Evidence (2026-10-01; fork `b31e856`, M5 Pro, SMITE 2 practice match, `DXMT_D3D12_SM6=1`)

**The GPU is the limit.** A 5-second System Trace: no game thread is busy more than 36% of the time (game thread 36%, our submission thread 24%, render thread 16%), and the busy ones run on the fastest (Super) cores 97–100% of the time. A Metal System Trace of the same scene:

| Measure | Value |
|---|---|
| Frame period (GPU start to start), median | 15.0 ms (67 fps) |
| GPU busy per frame (any channel), median | 12.5 ms |
| GPU idle within a frame | about 2.4 ms |
| Fragment / vertex / compute share of wall time | 44.1% / 16.2% / 8.4% |
| Overlap between channels | none: they add up to 68.7%, the union is 68.5% |

**Why nothing overlaps.** `d3d12_command_queue.cpp` makes every Metal encoder `waitForFence(fence_)` (render passes before the vertex stage) and `updateFence(fence_)` after it (render passes after the fragment stage), one fence for the whole queue. `ResourceBarrier` records nothing (it only counts, for `DXMT_STATS`).

**The frame's shape** (F9 dumps `f9-5`, `f9-6`): about 200 encoders and 68 command lists per frame; about two-thirds of encoder boundaries fall inside a command list. `DXMT_STATS` (2026-09-30): 139 in-list encoder boundaries per frame, 46 of them with no barrier between the two encoders; 447 barriers per frame. In the passes list, the base pass (7 color targets + depth, 1728×1120) splits into about 6 Metal render passes at command-list boundaries, each separated by Unreal's timestamp blits ("null blit blit null blit"); there are about 16 clear-only passes per frame.

**After M1 and M2** (Metal traces of the acceptance runs; GPU idle per frame by where it falls):

| GPU idle per frame | M2 with overlap | M2 strict (`DXMT_D3D12_SERIAL=1`) |
|---|---|---|
| Between encoders inside one command buffer | 2.92 ms | 2.02 ms |
| Between command buffers (committed in time) | 0.86 ms | 0.87 ms |
| Waiting for the CPU to commit | 0.17 ms | 0.13 ms |

Overlap took 1.3 ms of GPU work out of each frame and added 0.9 ms of idle between encoders: an encoder after a join re-waits on every fence the join waited on. About 32 Metal command buffers per frame, 10 with GPU work. The GPU, not the CPU, sets the pace.

**Expected gains** (estimates; M1's measurement calibrates them): M1 0.5–1 ms, M2 another 1–2 ms, M3 1–2 ms, M4 about 0.3 ms per frame, so about 15 → 10–12 ms of GPU time per frame in this scene, 20–40% more frames per second while the GPU limits. Fragment work (about 6.6 ms) is the floor this slice doesn't touch.

## 3. Design

### 3.1 The ordering model

Each Metal encoder updates its own fence and waits only on the fences of the encoders it depends on. Its dependencies are decided when the game records the command list (§3.2) and turned into fence waits when the queue encodes it (§3.3).

- **Full join:** wait on every encoder since the queue's last full join. Covers everything earlier, transitively.
- **Dependency list:** wait on some earlier encoders of the same command list.
- **Rules (M1):**
  - The first encoder of a command list does a full join.
  - The first encoder after one or more barriers does a full join.
  - Any other encoder waits on the earlier encoders of its list that write a resource it also writes (render or depth attachment, clear, resolve or copy destination). D3D12 orders writes to one resource in one state without a barrier, and a render pass's load action reads its attachments.
- **Rules (M2):** the first encoder after barriers does a full join only if one of them needs it (§3.4). Otherwise it waits on the encoders of its list that wrote a resource those barriers transition out of a write state (RENDER_TARGET, DEPTH_WRITE, COPY_DEST, RESOLVE_DEST), plus the write-write rule above.
- Render passes wait before their first stage (vertex, or pre-raster for geometry-shader pipelines) and update after the fragment stage, as today. Compute and blit encoders wait at their start and update at their end.

### 3.2 Recording (command list)

| Unit | Where (fork) | Does |
|---|---|---|
| Barrier summary | `d3d12_command_list.cpp` `ResourceBarrier`, the allocator | Accumulates the barriers recorded since the last encoder: a full-join flag, or the set of resources moving out of a write state (M2) |
| Encoder write set | `EncoderData` (`d3d12_command_encoder.hpp`), filled where encoders and copies are recorded | The resources an encoder writes: render/depth attachments (from `MTL_RENDER_TARGET_DESC::Texture`), clear and resolve targets, copy destinations |
| Dependency decision | `AllocatePass` | When an encoder starts: full join, or a small list of earlier encoder positions in the same command list (§3.1) |

- **Resource identity:** DXMT's `Texture *` for textures and the buffer object for buffers, the objects `ID3D12Resource`s and descriptors already point at. A barrier's resource maps to the same object.
- Everything stays inside one command list, whose start is a full join: no global tracking, and a list executed twice or reused works unchanged.
- An encoder whose write set grows after a later encoder started cannot happen: starting an encoder closes the previous one.

### 3.3 Encoding (queue)

| Unit | Where (fork) | Does |
|---|---|---|
| Fence ring | `d3d12_command_queue.cpp` | A ring of Metal fences per queue (256); each encoder takes the next one |
| Wait translation | the encode loop | Turns an encoder's dependency positions into the fences those encoders took; a full join waits on every fence since the last full join |
| Forced join | same | If the next fence is still uncovered by a full join, the encoder does a full join first (always correct, less overlap) |
| Serial mode | same | With `DXMT_D3D12_SERIAL=1`, while dumping an F9 frame or pixel history: one fence for everything, as today |

- The chained wait-commands-update encode (one winemetal call per encoder) carries the wait list and the update.
- The indirect pre-pass (ExecuteIndirect resolvers) waits on exactly its render pass's dependencies; the render pass also waits on the pre-pass's fence.
- Cross-queue `Signal` and `Wait` and `Present` stay command-buffer events, as today. The first encoder after a queue `Wait` does a full join.

### 3.4 What needs a full join

- Command-list starts, and the first encoder after a queue `Wait`.
- M1: any barrier.
- M2: a barrier that is a UAV barrier, an aliasing barrier, a transition out of UNORDERED_ACCESS, a transition into a write state from a read state (its readers are invisible: shaders read through bindless descriptors), a split barrier's END (BEGIN is ignored), a barrier on a resource we don't recognise, or a resource created with `D3D12_RESOURCE_FLAG_ALLOW_SIMULTANEOUS_ACCESS`.
- A barrier on some subresources counts for the whole resource.
- A GPU `ResolveQueryData` (occlusion results: query heaps have no barriers). Timestamp resolves run on the CPU after completion and are unaffected.
- Indirect arguments written by compute reach `ExecuteIndirect` through a transition out of UNORDERED_ACCESS: a full join.

### 3.5 Unsplit render passes (M3)

- **Within one Metal command buffer.** A Metal render pass can't span command buffers, so passes merge only among the encoders of one command buffer: one `ExecuteCommandLists` call's lists, or several calls B coalesced with no `Signal` between them.
- **Planned before encoding.** The queue first collects the command buffer's encoders, decides which render passes merge and which timestamp-only blits fold into them, then creates the Metal encoders: a merged pass's timestamp samples are attachments it is created with. The merged pass takes the earlier pass's waits; positions of the later pass's list that depended on the later pass resolve to the merged pass's fence.

- **Timestamp-only blits:** `EndTimestamp` marks the blit encoder it opens for a lone timestamp (its only command is the 4-byte fill that keeps Metal from dropping it) as timestamp-only.
- **Merge rule:** the queue encodes two render-pass encoders as one Metal render pass when everything between them is command-list boundaries and timestamp-only blits, and:
  - their attachments are identical (same textures, levels, slices and planes) and the later one loads every attachment;
  - no barrier summary between them asks for a wait (M2: none names their attachments; M1: no barrier at all);
  - no encoder other than the earlier pass has been encoded since the earlier pass's own full join, so the later pass's full join (a command-list start) is already satisfied by the merged pass's start.
- **Folding the timestamps:** each timestamp-only blit's samples move to the merged pass's end-of-pass sample attachment when that counter buffer has no sample there yet; if one does, the passes are not merged at that boundary (correct, less merging). Timestamp values become coarser, as with overlap.
- The merged pass keeps the earlier pass's load actions and the later pass's store actions, and its commands are the two command streams in order.

### 3.6 Folded clears (M4)

A clear-only render pass followed, in the same command list and with no barrier between, by a render pass whose attachments include the cleared one becomes that pass's clear load action. Other clear-only passes stay as they are.

### 3.7 Idle gaps (M5)

With M1–M4 in place, a Metal trace of the SMITE scene lists the GPU idle intervals with the encoder labels on either side. Each cause found is fixed in this slice if it is in our encoding, or recorded with its evidence if it is not (for example presentation pacing).

### 3.9 Cheap waits (A)

- **A join's early fence.** A join render pass also updates a second fence, from the ring, after its first stage (vertex, or pre-raster for geometry-shader pipelines): by then every fence it waited on before that stage has been reached. The encoders of its group wait on that fence instead of on the join's whole wait list. A join's waits are always before its first stage (a join clear pass waits before the vertex stage; it has no vertex work). A compute or blit join has no earlier stage: its group waits on its own fence.
- **Newest writer only.** An encoder's dependency list names, per resource, only the newest earlier encoder of its group that writes it (or wrote it before the transition that orders it): that writer itself waited on the older ones. An encoder that may write anything stays a dependency of everything after it in its group.

### 3.10 Fewer command buffers (B)

- The queue keeps one open Metal command buffer. `ExecuteCommandLists` encodes into it (opening one if none is open) and doesn't commit; a queue `Wait` encodes its event wait into it and doesn't commit either.
- `Signal` encodes its event signal (or its deferred CPU signal, behind timestamps) into the open command buffer and commits it; `Present` does the same with its present.
- Nothing can wait on uncommitted work: D3D12 lets the CPU and other queues wait only on fences, and every fence signal commits. A queue's destruction commits what is open.

### 3.8 Counters

`DXMT_STATS` adds: encoder full joins, encoders with a dependency list, dependency-list waits, and encoder boundaries left free to overlap (no wait on the previous encoder). With `DXMT_D3D12_SERIAL=1` the last is zero. A adds every fence wait encoded (`encoder fence waits`); B, the Metal command buffers committed; M3, the render passes merged and the timestamp blits folded.

## 4. Error handling

- A dependency we fail to see shows as corruption or flicker in some passes. Triage: relaunch with `DXMT_D3D12_SERIAL=1` (if the problem goes away, it's ordering), then an F9 dump (strict order) and a Metal trace with pass labels to find the pass.
- Unknown barrier types, resources or flags: full join (§3.4).
- Fence ring exhaustion: forced full join (§3.3).
- No new failure modes reach the game: nothing in this slice fails a D3D12 call.

## 5. Tests

All in `make dxmt-check`, test-first, compared with D3DMetal's pixels. Every hazard test runs with overlap on and with `DXMT_D3D12_SERIAL=1`; both must equal D3DMetal. Each makes its first pass heavy enough (many full-screen draws or a long dispatch) that a missing wait corrupts the result, not just sometimes.

| Test | Checks |
|---|---|
| Render target → shader read | pass A renders into texture T; barrier RENDER_TARGET → PIXEL_SHADER_RESOURCE; pass B samples T: B's pixels |
| Same target, no barrier | several render passes into one target, split by work on other resources, no barrier: the last draw wins |
| UAV | a dispatch accumulates into a buffer; UAV barrier; a dispatch reads it: exact sums |
| Copy → read | a copy into texture T; barrier COPY_DEST → shader resource; a pass samples T |
| Indirect | compute writes ExecuteIndirect arguments; barrier UNORDERED_ACCESS → INDIRECT_ARGUMENT; the draws use them (extends `d3d12_indirect`) |
| Aliasing | two placed resources in one heap, an aliasing barrier between their uses: the second use reads its own data |
| Occlusion | a render pass counts samples; `ResolveQueryData` on the GPU: the count |
| Overlap happens | two independent render passes in one list: `DXMT_STATS` reports boundaries free to overlap; zero with `DXMT_D3D12_SERIAL=1` |
| M2 precision | a barrier transitioning one render target: the next encoder's wait is a dependency list naming only that target's writer |
| A: one wait | a join then two encoders in its group: each waits on one fence (`encoder fence waits`); every hazard mode unchanged |
| A: newest writer | three passes into one target, no barrier: the third waits on the second alone |
| B: one command buffer | Wait, ExecuteCommandLists, Signal: one Metal command buffer committed |
| B: queues | a second queue waits on a fence the first signals mid-stream, then the CPU waits: no deadlock, right values |
| M3 | the same-target test with a timestamp between passes: one Metal render pass in the F9 passes list, pixels unchanged |
| M4 | a clear then a draw to the same target: no clear-only pass in the passes list, pixels unchanged |

**Existing tests:** every D3D12 and D3D11 test still passes.

## 6. Delivery

- Fork commits on `macneutron`, pushed before `dxmt/pins` moves (LGPL); MacNeutron: tests, `check.sh`, the pin, and per milestone a results section in `docs/testing/acceptance-dxmt-gpu-overlap.md`.
- Each milestone lands with its tests green and its SMITE 2 numbers recorded before the next starts.
- The README's troubleshooting gets `DXMT_D3D12_SERIAL=1`.

## 7. Acceptance

Manual, per milestone, recorded in `docs/testing/acceptance-dxmt-gpu-overlap.md`:

1. `make dxmt-check` and `make test` pass.
2. Install the build; SMITE 2 with `/usr/bin/env DXMT_D3D12_SM6=1 %command%`, the same practice-match scene as §2.
3. A 5-second Metal System Trace: GPU busy and idle time per frame, channel sum against union (overlap), frame period. UE's `PEX_Timeline` CSV: frame time median and 90th percentile.
4. The same with `DXMT_D3D12_SERIAL=1` as the control.
5. **Pass:** the picture is the same (by eye, and an F9 dump's passes compare equal); GPU time per frame is lower than the control's and §2's; the frame rate is higher. A milestone that measures no gain is recorded as such, and the next milestone's plan says whether it still goes ahead.
