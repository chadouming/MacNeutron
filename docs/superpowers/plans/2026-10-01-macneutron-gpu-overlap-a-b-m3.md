# DXMT Fork, GPU Overlap: Cheap Waits (A), Fewer Command Buffers (B) and Unsplit Render Passes (M3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn M1 and M2's GPU savings into frames. Three changes, each measured in SMITE 2 before the next:
- **A:** take out the idle that extra fence waits add between encoders;
- **B:** make about a third as many Metal command buffers;
- **M3:** stop splitting the base pass at command-list boundaries.

**Architecture:**
- **A (queue and allocator):**
  - A join render pass that draws updates an "early" fence after its first stage. The encoders of its group wait on that one fence instead of on everything the join waited on.
  - Dependency lists keep only the newest writer of each resource.
- **B (queue):** one open Metal command buffer per queue. `ExecuteCommandLists` and `Wait` encode into it; `Signal` and `Present` commit it.
- **M3 (queue):** before encoding a render pass that joins, the queue looks ahead through the rest of the `ExecuteCommandLists` call.
  - Later render passes into the same targets, with only list boundaries and timestamp-only blits between them, become part of the same Metal render pass.
  - Those timestamps' samples move to the pass's end.

**Tech Stack:**
- Fork: C++20.
- Tests: Windows C++ test programs built with llvm-mingw Clang, HLSL as DXIL, and POSIX sh for `check.sh`.
- Measurement: Python 3 and `xctrace`.

**Spec:** `docs/superpowers/specs/2026-10-01-macneutron-gpu-overlap-design.md` (§3.5, §3.8, §3.9, §3.10, §5, §7)

**Builds on:** `docs/superpowers/plans/2026-10-01-macneutron-gpu-overlap.md` (M1 and M2, done). This plan's code edits the fork as it stands after that plan: fork `57d99c8`, MacNeutron `feat/dxmt-gpu-overlap`.

## Global Constraints

- **Fork:** `github.com/chadouming/dxmt`, branch `macneutron`.
  - Never send anything upstream (DXMT refuses AI-authored contributions).
  - Before editing, run `git -C build/dxmt-src/dxmt switch macneutron`: `build.sh` leaves the clone detached at the pin, and so does every `make dxmt-check`.
  - To land fork work: commit it, `git -C build/dxmt-src/dxmt push origin macneutron`, then write the new head into `dxmt/pins` (`DXMT_COMMIT=`). `make dxmt-check` builds the pinned commit only.
  - Never edit `dxmt/check.sh` or fork files while `make dxmt-check` runs.
- **Commit trailer:** every fork and MacNeutron commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Reference:** D3DMetal on the same Mac, GPTK imported. Every `hazard` line must equal D3DMetal's and the fixed value in `check.sh`. The counters are ours only.
- **Dev loop:** `sh dxmt/tests/run.sh <test> [args]`. It rebuilds the fork's working tree, installs it into `check.sh`'s "ours" clone, and runs the test on our DXMT, then on D3DMetal. Extra variables go in `RUN_ENV="A=1 B=2"`.
  - Give stats folders a new literal absolute path each run. A guard refuses `rm -rf` on a path built from variables.
- **Full check:** `make dxmt-check > "$W/check-tN.log" 2>&1`, where `W=.superpowers/sdd/2026-10-01-macneutron-gpu-overlap-a-b-m3` is the plan's git-ignored workspace (`mkdir -p "$W"` once). Read its `FAIL` lines and its last line. Swift: `swift test 2>&1 | tail -5`.
- **Spec rules:**
  - Anything not provably safe is a join.
  - `DXMT_D3D12_SERIAL=1` keeps a single strict chain, and F9 dumps and pixel history always use it.
  - No core, GPU-model or core-count assumptions.
- **Installing into the tool folder:** `.build/release/macneutron install-dxmt build/dxmt`, only while SMITE 2 isn't running (`pgrep -f Hemingway-Win64` prints nothing).
- **Steam and privacy:**
  - The user changes launch options themselves.
  - Captures and dumps (`~/dxil-smite2`) never enter git.
- **Deletion:** delete nothing permanently; move files to `~/.Trash`.
- **Deliberate ceilings:** mark them with `// ponytail:` comments naming the upgrade path.
- **Choices:** pick the default option when a question comes up.

### Decisions this plan makes where the spec is silent or loose

- **Drawing joins only get the early fence.** The queue scans a join render pass's commands for a draw (any `WMTRenderCommand*Draw*`, `ExecuteCommandsInBuffer` or `DispatchThreadsPerTile`). This needs no recording change.
  - A render pass whose draws all have zero instances still counts as drawing.
  - The `nodraw` test pins the Metal behaviour this relies on: a fence updated after the vertex stage is never signalled before that stage's waits are met.
- **Groups wait only on the group fence.** With the group fence, nothing waits on what a join waited on, so the queue drops `pinned_`. The early fence is marked live (`fence_group_`) but not added to the frontier: the join's own fence covers it for the next join.
- **M3 merges within one `ExecuteCommandLists` call only.** Spec §3.5 also allows merging across calls that B coalesced. That would mean deferring all Metal encoding to commit time. This plan stays within a call and marks the ceiling with a `ponytail:` comment. SMITE submits about five lists per call, so the base pass segments of one call can merge.
- **M3's barrier rule is M1's strict version:** no barrier at all between the passes. Spec §3.5 allows M2's finer rule; the strict one is enough for the base pass.
- **No merging in strict mode.** M3 doesn't merge while `DXMT_D3D12_SERIAL=1` is set or while dumping, so dumps and pixel history keep D3D12's passes. M3's test therefore uses `DXMT_STATS` counters and pixels, not the F9 passes list from spec §5.
- **Lever 2 (faster CPU encoding) stays deferred,** as spec §1 says.

## Review Focus

- **A join render pass whose only draw has zero instances**, followed in its group by a pass sampling what the work before the join rendered. The sampling pass must see that work. Test: `hazard nodraw 257` (Task 2).
- **Work that waits on another queue in the middle of a command buffer.** Queue 1's next command buffer starts with a `Wait` on queue 2. No deadlock, right values. Test: `hazard queues 257 257` (Task 4).
- **Timestamps resolved on the CPU with coalesced command buffers.** A fence must still report work done only after its timestamps are written. Tests: the existing `timestamp rules 1 1 1 1 1 1` and `timestamp default-heap 1` checks stay green (Task 4).
- **A barrier between two lists' render passes into the same target:** no merge, right pixels. Test: `hazard unsplit-barrier 257` and the merged-pass counter (Task 6).
- **A timestamp sharing a counter buffer with a sample the merged pass already takes:** Metal can't sample a buffer twice in one pass. That boundary doesn't merge, and the pixels are right. Test: `hazard unsplit-samebuffer 257` and the merged-pass counter (Task 6).

---

### Task 1: The idle breakdown in gpu-trace.py

**Files:** Modify `dxmt/tools/gpu-trace.py`.

**Interfaces:**
- Produces: a trace report line `GPU idle per frame: between encoders X ms, between command buffers Y ms, waiting for the CPU Z ms`. Tasks 3, 5 and 7 record it.

- [ ] **Step 1: Watch the report lack it**

Run:

```bash
T=$(ls -d /var/folders/*/*/T/tmph_16yur4/gpu.trace 2>/dev/null | head -1); echo "${T:-no M2 trace}"
python3 dxmt/tools/gpu-trace.py "${T:-/private/tmp/claude-501/-Users-chad-Documents-MacProton/b56e92d0-84e3-4072-a071-4c3ba8d09535/scratchpad/prof/metal4.trace}" | grep -c 'GPU idle per frame'
```

Expected: `0`.

- [ ] **Step 2: Add the breakdown**

In `trace()`, keep each interval's command buffer. Replace:

```python
        start = int(r[0].text)
        by_process[r[10].attrib.get('fmt', '') if r[10] is not None else ''].append(
            (start, start + int(r[1].text), r[2].text, r[3].text))
```

with:

```python
        start = int(r[0].text)
        by_process[r[10].attrib.get('fmt', '') if r[10] is not None else ''].append(
            (start, start + int(r[1].text), r[2].text, r[3].text, r[15].text if len(r) > 15 and r[15] is not None else None))
```

Then update the unpacking that assumed four fields:
- `for a, b, _, f in mine:` becomes `for a, b, _, f, _ in mine:`;
- `sorted({c for _, _, c, _ in mine})` becomes `sorted({c for _, _, c, *_ in mine})`;
- both `for a, b, c, _ in mine if c == ch` become `for a, b, c, *_ in mine if c == ch`.

At the end of `trace()`, after the `print('channels ' ...)` call, add:

```python
    # Where the GPU idles: waiting for the CPU to commit the next command buffer (committed over 20 us after the GPU
    # went idle), between command buffers committed in time, or between encoders inside one command buffer.
    submissions = os.path.join(os.path.dirname(xml), 'submissions.xml')
    with open(submissions, 'w') as out:
        subprocess.run(['xcrun', 'xctrace', 'export', '--input', path, '--xpath',
                        '/trace-toc/run[@number="1"]/data/table[@schema="metal-application-command-buffer-submissions"]'],
                       check=True, stdout=out, stderr=subprocess.DEVNULL)
    committed = {}
    for r in rows(submissions):
        if len(r) > 14 and r[14] is not None and r[0] is not None:
            committed[r[14].text] = int(r[0].text) + (int(r[1].text) if r[1] is not None and r[1].text else 0)
    idle = collections.Counter()
    ordered = sorted(mine)
    end, before = ordered[0][1], ordered[0]
    for iv in ordered[1:]:
        if iv[0] > end:
            if committed.get(iv[4], 0) > end + 20000:
                idle['waiting for the CPU'] += iv[0] - end
            elif iv[4] != before[4]:
                idle['between command buffers'] += iv[0] - end
            else:
                idle['between encoders'] += iv[0] - end
        if iv[1] > end:
            end, before = iv[1], iv
    print('GPU idle per frame: ' + ', '.join(f"{k} {idle[k] / 1e6 / len(by_frame):.2f} ms"
                                             for k in ('between encoders', 'between command buffers', 'waiting for the CPU')))
```

In the header comment, after the line ending `(more: different channels side by side).`, add:

```python
# Then the GPU's idle time per frame by where it falls: between encoders, between command buffers, waiting for the CPU.
```

- [ ] **Step 3: Watch it report the M2 numbers**

Run Step 1's command again, without the `grep -c`.

Expected:
- With the M2 overlap trace still on disk: `GPU idle per frame: between encoders 2.92 ms, between command buffers 0.86 ms, waiting for the CPU 0.17 ms`, matching spec §2's amendment table.
- Without it: the same line with the baseline trace's own values. In that case, ledger that the M2 trace is gone.

- [ ] **Step 4: Commit**

```bash
git add dxmt/tools/gpu-trace.py
git commit -m "feat: gpu-trace splits GPU idle time by where it falls

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: A, cheap waits

**Files (fork, `build/dxmt-src/dxmt/src/d3d12/`):** `d3d12_command_queue.cpp` (group fence, early fence, `Draws`, `EncodeOrdered`, the counter), `d3d12_command_allocator.hpp` (newest-writer `Decide`)

**Files (MacNeutron):** `dxmt/tests/d3d12_hazards.cpp` (modes `onewait`, `newest`, `nodraw`), `dxmt/check.sh`, `dxmt/pins`

**Interfaces:**
- Consumes: plan 1's queue (`Order`, `CountOrder`, `EncodeOrdered`, `Encode`, `frontier_`, `pinned_`, `waits_`, `list_fences_`, `list_join_`) and allocator (`Decide`, `Overlap`, `Transitioned`, `group_`, `transitions_`, `deps_`).
- Produces:
  - Queue members `group_wait_` and `early_`, and `static constexpr uint16_t kNoFence = 0xffff`. `pinned_` is gone.
  - `Encode(WMT::RenderCommandEncoder &, uint16_t fence, WMTRenderStages before, wmtcmd_render_nop *head = nullptr, wmtcmd_base *tail = nullptr, uint16_t early = kNoFence)`, and `static bool Draws(RenderEncoderData *)`.
  - Allocator: `covered_`, `Lists(e, resource)`, and `Transitioned(g, e, resource)`, which replaces `Transitioned(g, e)` and `Overlap`.
  - Counter `encoder fence waits`. `encoder dependency waits` now counts waits beyond the group fence.
  - Hazard modes `onewait`, `newest` and `nodraw`, which Task 4's and Task 6's want lists keep.

- [ ] **Step 1: Write the new hazard modes**

In `dxmt/tests/d3d12_hazards.cpp`, before `int main(`, add:

```cpp
// T0 rendered (heavy), then T1 and T2 rendered in the same group (no barrier): with one wait (spec §3.9) the two later
// passes each wait on the first pass's early fence alone. DXMT_STATS, this mode alone: 10 fence waits (the clears 0,
// 1, 1; the passes 3, 1, 1; the read 3).
static void OneWait() {
    Clear(T[0]);
    Clear(T[1]);
    Clear(T[2]);
    g->Submit();
    Pass(T[0], add, 1, 256);
    Pass(T[1], set, 5, 1);
    Pass(T[2], set, 6, 1);
    g->Submit();
    Read(T[0], RT, 512, 512, 0);
    Read(T[1], RT, 512, 512, 1);
    Read(T[2], RT, 512, 512, 2);
    g->Submit();
    printf("hazard onewait %g %g %g\n", Texel(0), Texel(1), Texel(2));
}

// Three passes into T0 with no barrier: with newest-writer dependencies (spec §3.9) the third waits on the second
// alone. DXMT_STATS, this mode alone: 2 dependency waits.
static void Newest() {
    Clear(T[0]);
    g->Submit();
    Pass(T[0], add, 1, 1);
    Pass(T[0], add, 1, 1);
    Pass(T[0], add, 1, 1);
    g->Submit();
    Read(T[0], RT, 512, 512, 0);
    g->Submit();
    printf("hazard newest %g\n", Texel(0));
}

// T0 rendered (heavy); a barrier to PIXEL_SHADER_RESOURCE and a UAV barrier (a join); a pass into T2 whose only draw
// has no instances; then T1 = T0 sampled + 1, in that pass's group. The sampling pass must still see T0 done: a
// join's early fence (spec §3.9) is reached only after its waits, draws or not.
static void NoDraw() {
    Clear(T[0]);
    g->Submit();
    Pass(T[0], add, 1, 256);
    g->Barrier(T[0].texture, RT, PSR);
    D3D12_RESOURCE_BARRIER all = {D3D12_RESOURCE_BARRIER_TYPE_UAV};
    g->list->ResourceBarrier(1, &all);
    Pass(T[2], set, 1, 0);
    Pass(T[1], sample, 1, 1, &T[0]);
    g->Barrier(T[0].texture, PSR, RT);
    Read(T[1], RT, 512, 512, 0);
    g->Submit();
    printf("hazard nodraw %g\n", Texel(0));
}

```

In `kModes`, replace `{"wrap", Wrap}};` with:

```cpp
        {"wrap", Wrap}, {"onewait", OneWait}, {"newest", Newest}, {"nodraw", NoDraw}};
```

In `dxmt/check.sh`, replace `"signal 0" "wrap 4194304")` with `"signal 0" "wrap 4194304" "onewait 256 5 6" "newest 3" "nodraw 257")`.

After the M2 block (the line ending `"encoder dependency waits 3;encoders with a dependency list 2;"`), add:

```sh
# A (GPU overlap spec §3.9): encoders after a join wait on its early fence alone, and on the newest writer of what
# they write. d3d12_hazards onewait and newest, each alone.
for m in onewait newest; do
  rm -rf "$WORK/$m-stats"; export DXMT_DXIL_DUMP="$WORK/$m-stats" DXMT_STATS=1
  run ours "$m-stats" dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" $m
  unset DXMT_DXIL_DUMP DXMT_STATS
done
expect "encoders after a join wait on one fence" \
  "$(grep -oE 'encoder fence waits [0-9]+' "$WORK/onewait-stats/stats.txt" 2> /dev/null)" "encoder fence waits 10"
expect "and on the newest writer alone" \
  "$(grep -oE 'encoder dependency waits [0-9]+' "$WORK/newest-stats/stats.txt" 2> /dev/null)" "encoder dependency waits 2"
```

- [ ] **Step 2: Watch them fail**

```bash
make -s dxmt-tests
git -C build/dxmt-src/dxmt switch macneutron
sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" onewait newest nodraw | grep hazard
RUN_ENV="DXMT_DXIL_DUMP=$PWD/$W/a-red-1 DXMT_STATS=1" sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" onewait > /dev/null
RUN_ENV="DXMT_DXIL_DUMP=$PWD/$W/a-red-2 DXMT_STATS=1" sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" newest > /dev/null
grep -oE 'encoder (fence|dependency) waits [0-9]+' "$W/a-red-1/stats.txt" "$W/a-red-2/stats.txt"
```

Expected:
- `hazard onewait 256 5 6`, `hazard newest 3` and `hazard nodraw 257` on both backends: the values are right today.
- No `encoder fence waits` line, because the counter doesn't exist yet.
- `encoder dependency waits 3` for `newest`, because every earlier writer is a dependency.

- [ ] **Step 3: Newest-writer dependencies (allocator)**

In `d3d12_command_allocator.hpp`, replace:

```cpp
  std::vector<uint32_t> deps_; // scratch
```

with:

```cpp
  std::vector<uint32_t> deps_;         // scratch
  std::vector<const void *> covered_; // scratch: resources whose older writers a dependency already covers
```

Replace the whole `Overlap` function and the whole two-argument `Transitioned` function with:

```cpp
  static bool
  Lists(const EncoderData *e, const void *resource) {
    for (unsigned i = 0; i < e->write_count; i++)
      if (e->writes[i] == resource)
        return true;
    return false;
  }

  // M2: `resource`, which g writes, left its write state after g began and before e's last command.
  bool
  Transitioned(const EncoderData *g, const EncoderData *e, const void *resource) {
    for (auto &[r, at] : transitions_)
      if (r == resource && at > g->barriers && at <= e->barriers_last)
        return true;
    return false;
  }
```

In `Decide`, replace:

```cpp
      deps_.clear();
      for (auto *g : group_)
        if (g->writes_unknown || Overlap(g, e) || Transitioned(g, e))
          deps_.push_back(g->position);
```

with:

```cpp
      // Newest first, the newest writer of each resource only: an encoder taken has itself waited on the older
      // writers of everything it writes (GPU overlap spec §3.9).
      deps_.clear();
      covered_.clear();
      for (auto it = group_.rbegin(); it != group_.rend(); ++it) {
        auto *g = *it;
        bool needed = g->writes_unknown;
        for (unsigned i = 0; i < g->write_count && !needed; i++) {
          auto r = g->writes[i];
          needed = std::find(covered_.begin(), covered_.end(), r) == covered_.end() &&
                   (Lists(e, r) || Transitioned(g, e, r));
        }
        if (!needed)
          continue;
        deps_.push_back(g->position);
        covered_.insert(covered_.end(), g->writes, g->writes + g->write_count);
      }
```

Replace `Decide`'s comment lines:

```cpp
  // command. Otherwise, the encoders since the list's last join that write what it writes, may write anything, or
  // wrote a resource a barrier since moved out of its write state.
  // ponytail: every earlier writer, not only the newest, so waits grow with same-target passes in one group; keep
  // the newest writer per resource if dependency waits show in DXMT_STATS.
```

with:

```cpp
  // command. Otherwise, of the encoders since the list's last join, the newest that writes each resource it writes
  // or that a barrier since moved out of its write state, and any that may write anything.
```

- [ ] **Step 4: The group fence and the early fence (queue)**

In `d3d12_command_queue.cpp`, replace the comment block and declarations that begin `// MacNeutron: encoder ordering (GPU overlap spec §3.3).` and end with `std::vector<uint16_t> frontier_, pinned_, waits_;` with:

```cpp
  // MacNeutron: encoder ordering (GPU overlap spec §3.3, §3.9). Each encoder updates a fence of its own from this ring
  // and waits on fences of earlier encoders: a join on every encoder since the last join (frontier_), any other
  // encoder on its group's fence (group_wait_: the join's early fence, updated after its first stage when it draws,
  // else the join's own fence) and on its dependencies in its command list. A fence is taken again only once no later
  // encoder can need its last update: an encoder that would take it sooner joins first.
  static constexpr unsigned kFences = 256;
  static constexpr uint16_t kNoFence = 0xffff;
  std::array<WMT::Reference<WMT::Fence>, kFences> fences_;
  std::array<uint64_t, kFences> fence_group_ = {}; // the join group that last updated each fence
  uint64_t group_ = 2;                             // fences of this group and the previous one are live
  uint16_t next_fence_ = 0;
  std::vector<uint16_t> frontier_, waits_;
  uint16_t group_wait_ = kNoFence, early_ = kNoFence; // early_: the early fence the last Order gave its join
```

Replace the whole `Order` function with:

```cpp
  // Takes the fence the next encoder updates and fills waits_ with the fences it waits on (and early_ with the early
  // fence a drawing join render pass also updates). `e` null: the queue's own work (pass dumps, pixel history,
  // presents), which joins.
  uint16_t
  Order(EncoderData *e, bool serial) {
    uint16_t fence = next_fence_;
    next_fence_ = (next_fence_ + 1) % kFences;
    bool join = !e || e->join || serial || fence_group_[fence] + 1 >= group_;
    waits_.clear();
    early_ = kNoFence;
    if (join) {
      waits_ = frontier_;
      frontier_.clear();
      group_++;
      list_join_ = e ? e->position : UINT32_MAX;
      group_wait_ = fence;
      if (e && e->type == EncoderType::Render && Draws(static_cast<RenderEncoderData *>(e))) {
        early_ = group_wait_ = next_fence_; // live for the group; the join's own fence covers it for the next join
        next_fence_ = (next_fence_ + 1) % kFences;
        fence_group_[early_] = group_;
      }
    } else {
      waits_.assign(1, group_wait_);
      for (uint32_t i = 0; i < e->dep_count; i++)
        if (e->deps[i] >= list_join_) // earlier ones are behind the join, so behind the group fence
          waits_.push_back(list_fences_[e->deps[i]]);
    }
    if (e && g_stats_on)
      CountOrder(e, join);
    fence_group_[fence] = group_;
    frontier_.push_back(fence);
    if (e) {
      if (e->position >= list_fences_.size())
        list_fences_.resize(e->position + 1);
      list_fences_[e->position] = fence;
    }
    return fence;
  }

  // A draw among a render pass's commands: then its first stage, after its waits, proves them met (spec §3.9).
  static bool
  Draws(RenderEncoderData *data) {
    for (auto *cmd = (wmtcmd_base *)data->cmd_head.next.get(); cmd; cmd = (wmtcmd_base *)cmd->next.get())
      switch (cmd->type) {
      case WMTRenderCommandDraw:
      case WMTRenderCommandDrawIndexed:
      case WMTRenderCommandDrawIndirect:
      case WMTRenderCommandDrawIndexedIndirect:
      case WMTRenderCommandDrawMeshThreadgroups:
      case WMTRenderCommandDrawMeshThreadgroupsIndirect:
      case WMTRenderCommandDXMTGeometryDraw:
      case WMTRenderCommandDXMTGeometryDrawIndexed:
      case WMTRenderCommandDXMTGeometryDrawIndirect:
      case WMTRenderCommandDXMTGeometryDrawIndexedIndirect:
      case WMTRenderCommandDXMTTessellationMeshDraw:
      case WMTRenderCommandDXMTTessellationMeshDrawIndexed:
      case WMTRenderCommandDXMTTessellationMeshDrawIndirect:
      case WMTRenderCommandDXMTTessellationMeshDrawIndexedIndirect:
      case WMTRenderCommandDispatchThreadsPerTile:
      case WMTRenderCommandExecuteCommandsInBuffer:
        return true;
      default:
        break;
      }
    return false;
  }
```

Replace the whole `CountOrder` function with:

```cpp
  void
  CountOrder(const EncoderData *e, bool join) { // DXMT_STATS (GPU overlap spec §3.8)
    static const unsigned joins = StatId("#encoder full joins"), listed = StatId("#encoders with a dependency list"),
                          dep_waits = StatId("#encoder dependency waits"),
                          fence_waits = StatId("#encoder fence waits"),
                          free = StatId("#encoder boundaries free to overlap");
    StatCount(fence_waits, waits_.size());
    if (join) {
      StatCount(joins);
      return;
    }
    size_t deps = waits_.size() - 1; // beyond the group fence
    if (deps) {
      StatCount(listed);
      StatCount(dep_waits, deps);
    }
    if (std::find(waits_.begin(), waits_.end(), list_fences_[e->position - 1]) == waits_.end())
      StatCount(free);
  }
```

Replace the whole `EncodeOrdered` function and the render `Encode` overload with:

```cpp
  // The waits in waits_, an encoder's commands and the update of `fence` (and of `early`, after the `before` stages,
  // for a render pass) go to winemetal as one chained command list: each call crosses from Windows code to the Metal
  // side (several us under Rosetta). `head` null: the waits and the updates alone. The chain is unlinked again, as
  // pixel history re-encodes the commands. Render passes wait before `before` and update after the fragment stage.
  template <typename FenceOp, auto Wait, auto Update, typename Encoder, typename Nop>
  void
  EncodeOrdered(Encoder &encoder, std::vector<FenceOp> &ops, uint16_t fence, Nop *head, wmtcmd_base *tail,
                WMTRenderStages before = WMTRenderStageVertex, uint16_t early = kNoFence) {
    size_t n = waits_.size(), all = n + (early == kNoFence ? 1 : 2);
    ops.assign(all, FenceOp{});
    for (size_t i = 0; i < all; i++) {
      ops[i].type = i < n ? Wait : Update;
      ops[i].fence = fences_[i < n ? waits_[i] : i == n ? fence : early].handle;
      if constexpr (std::is_same_v<FenceOp, wmtcmd_render_fence_op>)
        ops[i].stages = i == n ? WMTRenderStageFragment : before;
      if (i + 1 < all && i + 1 != n)
        ops[i].next.set(&ops[i + 1]);
    }
    void *body = head ? (void *)head : (void *)&ops[n];
    if (n)
      ops[n - 1].next.set(body);
    if (tail)
      tail->next.set(&ops[n]);
    encoder.encodeCommands((const Nop *)(n ? (void *)ops.data() : body));
    if (tail)
      tail->next.set(nullptr);
  }

  void
  Encode(WMT::RenderCommandEncoder &encoder, uint16_t fence, WMTRenderStages before,
         wmtcmd_render_nop *head = nullptr, wmtcmd_base *tail = nullptr, uint16_t early = kNoFence) {
    EncodeOrdered<wmtcmd_render_fence_op, WMTRenderCommandWaitForFence, WMTRenderCommandUpdateFence>(
        encoder, render_ops_, fence, head, tail, before, early);
  }
```

In the `EncoderType::Render` case, replace:

```cpp
          uint16_t fence = Order(current, serial);
```

with:

```cpp
          uint16_t fence = Order(current, serial), early = early_;
```

and replace:

```cpp
          Encode(encoder, fence, data->use_geometry ? WMTRenderStagePreRaster : WMTRenderStageVertex, &data->cmd_head,
                 data->cmd_tail);
```

with:

```cpp
          Encode(encoder, fence, data->use_geometry ? WMTRenderStagePreRaster : WMTRenderStageVertex, &data->cmd_head,
                 data->cmd_tail, early);
```

Run: `grep -n 'pinned_' build/dxmt-src/dxmt/src/d3d12/d3d12_command_queue.cpp`
Expected: no output.

- [ ] **Step 5: Watch them pass**

```bash
RUN_ENV="DXMT_DXIL_DUMP=$PWD/$W/a-green-1 DXMT_STATS=1" sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" onewait | grep hazard
RUN_ENV="DXMT_DXIL_DUMP=$PWD/$W/a-green-2 DXMT_STATS=1" sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" newest | grep hazard
grep -oE 'encoder (fence|dependency) waits [0-9]+' "$W/a-green-1/stats.txt" "$W/a-green-2/stats.txt"
for i in 1 2; do sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" | grep '^dxmt: hazard'; done
RUN_ENV="DXMT_D3D12_SERIAL=1" sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" | grep '^dxmt: hazard'
```

Expected:
- `encoder fence waits 10` for `onewait`, and `encoder dependency waits 2` for `newest`.
- Each full run prints all 18 lines with the values in `check.sh`'s want list.

If `nodraw` prints less than 257, Metal reaches a fence updated after an empty vertex stage before that stage's waits are met. Then:
- make `Draws` return false whenever no draw has instances, or drop the early fence, so the group waits on the join's own fence;
- run again;
- ledger it as a ruling.

- [ ] **Step 6: Land the fork, check everything, commit**

```bash
git -C build/dxmt-src/dxmt add -A src/d3d12
git -C build/dxmt-src/dxmt commit -m "d3d12: encoders after a join wait on one fence and on the newest writer only (GPU overlap A)

A join render pass that draws updates an early fence after its first stage; the encoders of its group wait on that
fence instead of on every fence the join waited on. Dependency lists keep the newest writer of each resource.
DXMT_STATS counts every fence wait.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git -C build/dxmt-src/dxmt push origin macneutron
sed -i '' "s/^DXMT_COMMIT=.*/DXMT_COMMIT=$(git -C build/dxmt-src/dxmt rev-parse HEAD)/" dxmt/pins
make dxmt-check > "$W/check-t2.log" 2>&1; grep -E '^(FAIL|dxmt-check)' "$W/check-t2.log"
swift test 2>&1 | tail -3
git add dxmt/tests/d3d12_hazards.cpp dxmt/check.sh dxmt/pins
git commit -m "feat(dxmt): encoders after a join wait on one fence (GPU overlap A)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: `dxmt-check: all passed` with no `FAIL`, including the M2 check (`encoder dependency waits 3;encoders with a dependency list 2;`) and `independent passes are free to overlap`. Every Swift test passes.

---

### Task 3: A in SMITE 2 (measurement; needs the user)

**Files:** Modify `docs/testing/acceptance-dxmt-gpu-overlap.md` (Results).

**Interfaces:**
- Consumes: Task 1's idle line and Task 2's build.

- [ ] **Step 1: Install, and hand the runs to the user**

With SMITE 2 closed, run `.build/release/macneutron install-dxmt build/dxmt`.

Then ask the user to:
- set the launch options to `/usr/bin/env DXMT_D3D12_SM6=1 %command%`;
- start a practice match, stand still at their spot, and say when they're in place;
- play about two minutes and quit;
- do the same with `/usr/bin/env DXMT_D3D12_SM6=1 DXMT_D3D12_SERIAL=1 %command%`;
- say whether the picture looked the same.

While they stand still, run `python3 dxmt/tools/gpu-trace.py $(pgrep -f Hemingway-Win64-Shipping | head -1) > "$W/a-<run>.txt"`. For the strict run, confirm `DXMT_D3D12_SERIAL=1` reached the game with `ps -wwE -p <pid> -o command= | grep -o 'DXMT_D3D12_SERIAL=[^ ]*'`, over the game's `pgrep -f 'Hemingway|wine'` processes. After each run, run the tool on the newest `PEX_Timeline_*.csv` in SMITE's `Saved/Logs`.

- [ ] **Step 2: Record and commit**

Add an `A` row with both runs' period, busy and idle time, the idle breakdown, the channel sum against union, PEX median and p90, and notes (fork commit, spot, picture). Compare it with the M2 rows.

```bash
git add docs/testing/acceptance-dxmt-gpu-overlap.md
git commit -m "docs: GPU overlap A acceptance results

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

If the picture differed, stop and debug with superpowers:systematic-debugging, starting with a new `d3d12_hazards` mode that reproduces it.

---

### Task 4: B, fewer command buffers

**Files (fork):** `d3d12_command_queue.cpp` (`CommittingScope`, `StartCommitting`, `Open`, `Commit`, `open_`, the four callers, the destructor)

**Files (MacNeutron):** `dxmt/tests/d3d12_hazards.cpp` (mode `queues`), `dxmt/check.sh`, `dxmt/pins`

**Interfaces:**
- Consumes: Task 2's queue.
- Produces:
  - `CommittingScope StartCommitting(bool commit)`, `InflightCommandBuffer &Open()`, `void Commit()`, `bool open_`.
  - Counter `command buffers committed`.
  - Hazard mode `queues`.

- [ ] **Step 1: Write the test**

In `dxmt/tests/d3d12_hazards.cpp`, before `int main(`, add:

```cpp
// Two queues. Queue 1 renders T0 (heavy) and signals f = 1; queue 2 waits for it, samples T0 into T1 (+1), reads T1
// and signals done = 1; queue 1 waits for that, reads T1 again and signals f = 2, which the CPU waits for. With one
// open command buffer per queue (spec §3.10) nothing may wait on uncommitted work: no deadlock, 257 257. DXMT_STATS,
// this mode alone: 3 command buffers committed (Execute+Signal, Wait+Execute+Signal, Wait+Execute+Signal).
static void Queues() {
    ID3D12CommandQueue *q2;
    ID3D12CommandAllocator *a2, *a3;
    ID3D12GraphicsCommandList *l2, *l3;
    ID3D12Fence *f, *done;
    D3D12_COMMAND_QUEUE_DESC qd = {D3D12_COMMAND_LIST_TYPE_DIRECT};
    CHECK(g->device->CreateCommandQueue(&qd, __uuidof(ID3D12CommandQueue), (void **)&q2));
    CHECK(g->device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, __uuidof(ID3D12CommandAllocator), (void **)&a2));
    CHECK(g->device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, __uuidof(ID3D12CommandAllocator), (void **)&a3));
    CHECK(g->device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, a2, nullptr, __uuidof(ID3D12GraphicsCommandList), (void **)&l2));
    CHECK(g->device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, a3, nullptr, __uuidof(ID3D12GraphicsCommandList), (void **)&l3));
    CHECK(g->device->CreateFence(0, D3D12_FENCE_FLAG_NONE, __uuidof(ID3D12Fence), (void **)&f));
    CHECK(g->device->CreateFence(0, D3D12_FENCE_FLAG_NONE, __uuidof(ID3D12Fence), (void **)&done));
    auto *l1 = g->list;
    ID3D12CommandList *one[1];
    Clear(T[0]);
    Pass(T[0], add, 1, 256);
    CHECK(l1->Close());
    one[0] = l1;
    g->queue->ExecuteCommandLists(1, one);
    CHECK(g->queue->Signal(f, 1));
    g->list = l2;
    g->Barrier(T[0].texture, RT, PSR);
    Pass(T[1], sample, 1, 1, &T[0]);
    g->Barrier(T[0].texture, PSR, RT);
    Read(T[1], RT, 512, 512, 0);
    CHECK(l2->Close());
    one[0] = l2;
    CHECK(q2->Wait(f, 1));
    q2->ExecuteCommandLists(1, one);
    CHECK(q2->Signal(done, 1));
    g->list = l3;
    Read(T[1], RT, 512, 512, 1);
    CHECK(l3->Close());
    one[0] = l3;
    CHECK(g->queue->Wait(done, 1));
    g->queue->ExecuteCommandLists(1, one);
    CHECK(g->queue->Signal(f, 2));
    g->list = l1;
    HANDLE ev = CreateEventA(nullptr, FALSE, FALSE, nullptr);
    CHECK(f->SetEventOnCompletion(2, ev));
    if (WaitForSingleObject(ev, 10000) != WAIT_OBJECT_0) { printf("hazard queues timeout\n"); exit(1); }
    CloseHandle(ev);
    CHECK(g->allocator->Reset());
    CHECK(l1->Reset(g->allocator, nullptr));
    printf("hazard queues %g %g\n", Texel(0), Texel(1));
}

```

In `kModes`, replace `{"nodraw", NoDraw}};` with `{"nodraw", NoDraw}, {"queues", Queues}};`.

In `dxmt/check.sh`, replace `"newest 3" "nodraw 257")` with `"newest 3" "nodraw 257" "queues 257 257")`. After Task 2's A block, add:

```sh
# B (GPU overlap spec §3.10): Wait, ExecuteCommandLists and Signal go into one Metal command buffer. d3d12_hazards
# queues alone: three such sequences over two queues.
rm -rf "$WORK/queues-stats"; export DXMT_DXIL_DUMP="$WORK/queues-stats" DXMT_STATS=1
run ours queues-stats dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" queues
unset DXMT_DXIL_DUMP DXMT_STATS
expect "a Wait, its ExecuteCommandLists and its Signal make one command buffer" \
  "$(grep -oE 'command buffers committed [0-9]+' "$WORK/queues-stats/stats.txt" 2> /dev/null)" "command buffers committed 3"
```

- [ ] **Step 2: Watch it fail**

```bash
make -s dxmt-tests
git -C build/dxmt-src/dxmt switch macneutron
RUN_ENV="DXMT_DXIL_DUMP=$PWD/$W/b-red DXMT_STATS=1" sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" queues | grep hazard
grep -c 'command buffers committed' "$W/b-red/stats.txt"
```

Expected: `hazard queues 257 257` on both backends, then `0`, because the counter doesn't exist yet.

- [ ] **Step 3: One open command buffer (queue)**

In `d3d12_command_queue.cpp`, replace the whole `struct CommittingScope { ... };` and the whole `StartCommitting()` function with:

```cpp
  // MacNeutron (GPU overlap spec §3.10): one open Metal command buffer. ExecuteCommandLists and queue Wait encode into
  // it; Signal and Present commit it, and they are every way the CPU or another queue can wait on this queue's work.
  bool open_ = false;

  // The open command buffer, after taking one of the 32 slots for a new one when none is open (under mutex_commit_).
  InflightCommandBuffer &
  Open() {
    auto &inflight = inflight_cmdbuf_pool_[inflight_cmdbuf_seq_.load(std::memory_order_relaxed) % kCommandQueueSize];
    if (open_)
      return inflight;
    {
      DXMT_STAT_SCOPE("queue.(wait for one of 32 command buffer slots)");
      inflight_cmdbuf_count_.wait(kCommandQueueSize, std::memory_order_acquire);
    }
    DXMT_STAT_SCOPE("queue.(new command buffer)");
    inflight.cmdbuf = queue_.commandBuffer();
    open_ = true;
    return inflight;
  }

  void
  Commit() { // under mutex_commit_
    if (!open_)
      return;
    DXMT_STAT_SCOPE("queue.(commit)");
    DXMT_STAT_COUNT("#command buffers committed", 1);
    inflight_cmdbuf_pool_[inflight_cmdbuf_seq_.load(std::memory_order_relaxed) % kCommandQueueSize].cmdbuf.commit();
    open_ = false;
    inflight_cmdbuf_seq_.fetch_add(1, std::memory_order_release);
    inflight_cmdbuf_seq_.notify_one();
    inflight_cmdbuf_count_.fetch_add(1, std::memory_order_relaxed);
  }

  struct CommittingScope {
    MTLD3D12CommandQueueImpl *queue;
    std::lock_guard<dxmt::mutex> lock;
    WMT::Reference<WMT::Object> pool;
    bool commit;
    InflightCommandBuffer &inflight;

    CommittingScope(MTLD3D12CommandQueueImpl *queue, bool commit) :
        queue(queue),
        lock(queue->mutex_commit_),
        pool(WMT::MakeAutoreleasePool()),
        commit(commit),
        inflight(queue->Open()) {}

    ~CommittingScope() {
      if (commit)
        queue->Commit();
    }
  };

  CommittingScope
  StartCommitting(bool commit) {
    return CommittingScope(this, commit);
  }
```

Update the four callers:
- In `ExecuteCommandLists`, replace `auto scope = StartCommitting();` with `auto scope = StartCommitting(false);`.
- In `Signal`, with `StartCommitting(true)`.
- In `Wait`, with `StartCommitting(false)`.
- In `PresentFrame`, with `StartCommitting(true)`.

These are the only callers. Run `grep -n 'StartCommitting()' build/dxmt-src/dxmt/src/d3d12/d3d12_command_queue.cpp` and expect no output.

In the destructor, replace:

```cpp
    std::lock_guard<dxmt::mutex> lock(mutex_commit_);
    inflight_cmdbuf_stop_.store(inflight_cmdbuf_seq_.fetch_add(1));
```

with:

```cpp
    std::lock_guard<dxmt::mutex> lock(mutex_commit_);
    Commit(); // what ExecuteCommandLists left open
    inflight_cmdbuf_stop_.store(inflight_cmdbuf_seq_.fetch_add(1));
```

- [ ] **Step 4: Watch it pass**

```bash
RUN_ENV="DXMT_DXIL_DUMP=$PWD/$W/b-green DXMT_STATS=1" sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" queues | grep hazard
grep -oE 'command buffers committed [0-9]+' "$W/b-green/stats.txt"
for i in 1 2; do sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" | grep '^dxmt: hazard'; done
RUN_ENV="DXMT_D3D12_SERIAL=1" sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" | grep '^dxmt: hazard'
```

Expected:
- `hazard queues 257 257` on both backends, and `command buffers committed 3`.
- Every full run prints all 19 lines with the values in `check.sh`.

- [ ] **Step 5: Land the fork, check everything, commit**

```bash
git -C build/dxmt-src/dxmt add -A src/d3d12
git -C build/dxmt-src/dxmt commit -m "d3d12: one open Metal command buffer per queue, committed by Signal and Present (GPU overlap B)

ExecuteCommandLists and queue Wait encode into the open command buffer; Signal and Present commit it. D3D12 lets the
CPU and other queues wait only on fences, and every fence signal commits, so nothing waits on uncommitted work.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git -C build/dxmt-src/dxmt push origin macneutron
sed -i '' "s/^DXMT_COMMIT=.*/DXMT_COMMIT=$(git -C build/dxmt-src/dxmt rev-parse HEAD)/" dxmt/pins
make dxmt-check > "$W/check-t4.log" 2>&1; grep -E '^(FAIL|dxmt-check)' "$W/check-t4.log"
swift test 2>&1 | tail -3
git add dxmt/tests/d3d12_hazards.cpp dxmt/check.sh dxmt/pins
git commit -m "feat(dxmt): one Metal command buffer per Wait, ExecuteCommandLists and Signal (GPU overlap B)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected:
- `dxmt-check: all passed` with no `FAIL`.
- The timestamp checks still pass: `timestamp rules 1 1 1 1 1 1`, `timestamp default-heap 1`, and the leak and CPU-resolve checks.
- The FSR 3 swap chain test still passes.
- Every Swift test passes.

---

### Task 5: B in SMITE 2 (measurement; needs the user)

**Files:** Modify `docs/testing/acceptance-dxmt-gpu-overlap.md` (Results).

- [ ] **Step 1: Install, and hand the runs to the user**

Same as Task 3 Step 1, with outputs in `"$W/b-<run>.txt"`. Also ask the user to watch for hitches or stutters, since commits now wait for `Signal`.

- [ ] **Step 2: Record and commit**

Add a `B` row like Task 3's. Its notes include the change in command buffers per frame: the trace's command buffer count divided by its frames.

```bash
git add docs/testing/acceptance-dxmt-gpu-overlap.md
git commit -m "docs: GPU overlap B acceptance results

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: M3, unsplit render passes

**Files (fork):**
- `d3d12_command_encoder.hpp` (`timestamp_only`)
- `d3d12_device.hpp` (`MTLD3D12GraphicsCommandList::barrier_count`)
- `d3d12_command_list.cpp` (`Close`, `EndTimestamp`)
- `d3d12_command_queue.cpp` (`SameTarget`, `PlanMerge`, `merged_`, `folds_`, `skipped_`, the encode loop)

**Files (MacNeutron):** `dxmt/tests/d3d12_hazards.cpp` (modes `unsplit`, `unsplit-barrier`, `unsplit-samebuffer`), `dxmt/check.sh`, `dxmt/pins`

**Interfaces:**
- Consumes: Task 2's `Order`, `early_`, `Encode` with `early`, `list_fences_`, `list_join_`; and Task 4's `StartCommitting(false)` in `ExecuteCommandLists`.
- Produces:
  - `EncoderData::timestamp_only` and `MTLD3D12GraphicsCommandList::barrier_count`.
  - Queue `void PlanMerge(RenderEncoderData *base, unsigned list, ID3D12CommandList *const *lists, unsigned count, WMTRenderPassInfo &info)` and `static bool SameTarget(RenderEncoderData *a, RenderEncoderData *b)`.
  - Counters `render passes merged` and `timestamp blits folded`.

- [ ] **Step 1: Write the tests**

In `dxmt/tests/d3d12_hazards.cpp`, before `int main(`, add:

```cpp
// Two command lists in one ExecuteCommandLists call: the first renders T0 (heavy); the second starts with a
// timestamp, then renders into T0 again, loading it. M3 (spec §3.5) encodes both as one Metal render pass with the
// timestamp at its end (DXMT_STATS: 1 render pass merged, 1 timestamp blit folded). `barrier`: a barrier on T1 ends
// the first list and starts the second, so no merge. `same_buffer`: the first pass already takes a timestamp from the
// counter buffer the second list's timestamp uses (Metal samples a buffer once per pass), so no merge.
static void Unsplit(const char *name, bool barrier, bool same_buffer) {
    static ID3D12CommandAllocator *a2;
    static ID3D12GraphicsCommandList *l2;
    static ID3D12QueryHeap *heap;
    if (!l2) {
        CHECK(g->device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, __uuidof(ID3D12CommandAllocator), (void **)&a2));
        CHECK(g->device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, a2, nullptr, __uuidof(ID3D12GraphicsCommandList), (void **)&l2));
        D3D12_QUERY_HEAP_DESC qd = {D3D12_QUERY_HEAP_TYPE_TIMESTAMP, 2};
        CHECK(g->device->CreateQueryHeap(&qd, __uuidof(ID3D12QueryHeap), (void **)&heap));
    }
    Clear(T[0]);
    g->Submit();
    auto *l1 = g->list;
    Pass(T[0], add, 1, 256);
    if (same_buffer)
        l1->EndQuery(heap, D3D12_QUERY_TYPE_TIMESTAMP, 1); // at the open pass's end
    if (barrier)
        g->Barrier(T[1].texture, RT, PSR);
    g->list = l2;
    if (barrier)
        g->Barrier(T[1].texture, PSR, RT);
    l2->EndQuery(heap, D3D12_QUERY_TYPE_TIMESTAMP, 0); // a timestamp-only blit
    Pass(T[0], add, 1, 1);
    g->list = l1;
    CHECK(l1->Close());
    CHECK(l2->Close());
    ID3D12CommandList *lists[] = {l1, l2};
    g->queue->ExecuteCommandLists(2, lists);
    CHECK(g->queue->Signal(g->fence, ++g->value));
    HANDLE ev = CreateEventA(nullptr, FALSE, FALSE, nullptr);
    CHECK(g->fence->SetEventOnCompletion(g->value, ev));
    if (WaitForSingleObject(ev, 10000) != WAIT_OBJECT_0) { printf("hazard %s timeout\n", name); exit(1); }
    CloseHandle(ev);
    CHECK(g->allocator->Reset());
    CHECK(l1->Reset(g->allocator, nullptr));
    CHECK(a2->Reset());
    CHECK(l2->Reset(a2, nullptr));
    Read(T[0], RT, 512, 512, 0);
    g->Submit();
    printf("hazard %s %g\n", name, Texel(0));
}
static void UnsplitPlain() { Unsplit("unsplit", false, false); }
static void UnsplitBarrier() { Unsplit("unsplit-barrier", true, false); }
static void UnsplitSameBuffer() { Unsplit("unsplit-samebuffer", false, true); }

```

In `kModes`, replace `{"queues", Queues}};` with:

```cpp
        {"queues", Queues}, {"unsplit", UnsplitPlain}, {"unsplit-barrier", UnsplitBarrier},
        {"unsplit-samebuffer", UnsplitSameBuffer}};
```

In `dxmt/check.sh`, replace `"nodraw 257" "queues 257 257")` with `"nodraw 257" "queues 257 257" "unsplit 257" "unsplit-barrier 257" "unsplit-samebuffer 257")`. After Task 4's B block, add:

```sh
# M3 (GPU overlap spec §3.5): two lists' passes into one target with only a timestamp between them are one Metal render
# pass; not across a barrier, nor when the timestamp's counter buffer is already sampled at that pass's end.
rm -rf "$WORK/m3-stats"; export DXMT_DXIL_DUMP="$WORK/m3-stats" DXMT_STATS=1
run ours m3-stats dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" unsplit unsplit-barrier unsplit-samebuffer
unset DXMT_DXIL_DUMP DXMT_STATS
expect "render passes into one target across lists are one Metal render pass" \
  "$(grep -oE '(render passes merged|timestamp blits folded) [0-9]+' "$WORK/m3-stats/stats.txt" 2> /dev/null | tr '\n' ';')" \
  "render passes merged 1;timestamp blits folded 1;"
```

- [ ] **Step 2: Watch it fail**

```bash
make -s dxmt-tests
git -C build/dxmt-src/dxmt switch macneutron
RUN_ENV="DXMT_DXIL_DUMP=$PWD/$W/m3-red DXMT_STATS=1" sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" unsplit unsplit-barrier unsplit-samebuffer | grep hazard
grep -cE 'render passes merged|timestamp blits folded' "$W/m3-red/stats.txt"
```

Expected: the three lines with `257` on both backends, then `0`.

- [ ] **Step 3: Record what M3 needs (encoder, list, timestamps)**

In `d3d12_command_encoder.hpp`, after `const uint32_t *deps = nullptr; ...`, add:

```cpp
  bool timestamp_only = false; // MacNeutron: an empty blit holding timestamps alone (M3 moves them into a render pass)
```

In `d3d12_device.hpp`, in `class MTLD3D12GraphicsCommandList`, after `size_t encoder_count = 0; // SIZE_MAX while recording`, add:

```cpp
  uint32_t barrier_count = 0; // its barrier calls (MacNeutron: M3 merges render passes only with none between)
```

In `d3d12_command_list.cpp`'s `Close`, replace:

```cpp
    return allocator_->EndRecord(&encoder_count);
```

with:

```cpp
    barrier_count = allocator_->barriers_;
    return allocator_->EndRecord(&encoder_count);
```

In `EndTimestamp`, replace:

```cpp
      fill.length = 4;
      fill.value = 0;
    }
```

with:

```cpp
      fill.length = 4;
      fill.value = 0;
      current->timestamp_only = true;
    }
```

- [ ] **Step 4: Plan merges and encode them (queue)**

In `d3d12_command_queue.cpp`, after the `Draws` function, add:

```cpp
  // M3 (GPU overlap spec §3.5): passes encodable as one Metal render pass: the same attachments, the later loading
  // them all and the earlier storing them all, with the same size, sample count, geometry and query heap.
  static bool
  SameTarget(RenderEncoderData *a, RenderEncoderData *b) {
    auto same = [](auto &x, auto &y) {
      return x.attachment.ptr() == y.attachment.ptr() && x.level == y.level && x.slice == y.slice &&
             x.depth_plane == y.depth_plane && (!y.attachment || y.load_action == WMTLoadActionLoad) &&
             (!x.attachment || x.store_action == WMTStoreActionStore);
    };
    for (unsigned i = 0; i < a->colors.size(); i++)
      if (!same(a->colors[i], b->colors[i]))
        return false;
    return same(a->depth, b->depth) && same(a->stencil, b->stencil) &&
           a->render_target_width == b->render_target_width && a->render_target_height == b->render_target_height &&
           a->render_target_array_length == b->render_target_array_length &&
           a->default_raster_sample_count == b->default_raster_sample_count &&
           a->dsv_planar_flags == b->dsv_planar_flags && a->dsv_readonly_flags == b->dsv_readonly_flags &&
           a->visibility_buffer == b->visibility_buffer && a->use_geometry == b->use_geometry;
  }

  std::vector<EncoderData *> merged_, folds_;               // PlanMerge's result and scratch
  std::vector<std::pair<EncoderData *, uint16_t>> skipped_; // encoders M3 already encoded, with their fence
  size_t skip_ = 0;

  // M3: the render passes encoded inside `base`'s Metal render pass, and the timestamp-only blits whose samples move
  // to its end, from the encoders after base in this ExecuteCommandLists call (lists[list] is base's). A pass joins
  // when only list boundaries and timestamp-only blits come between, with no barrier, its targets are base's
  // (SameTarget), it resolves no indirect commands, and the samples fit (4 counter buffers, one sample each). Base
  // must be its group's join. Fills merged_ in order, and `info` with the moved samples.
  // ponytail: one ExecuteCommandLists call; merging across calls B coalesced would defer encoding to commit time.
  void
  PlanMerge(RenderEncoderData *base, unsigned list, ID3D12CommandList *const *lists, unsigned count,
            WMTRenderPassInfo &info) {
    merged_.clear();
    folds_.clear();
    if (!base->join)
      return;
    unsigned samples = base->num_samples;
    auto fits = [&](EncoderData *e, unsigned &n) {
      for (unsigned k = 0; k < e->num_samples; k++) {
        if (n == std::size(info.sample_buffers))
          return false;
        for (unsigned j = 0; j < n; j++)
          if (info.sample_buffers[j].buffer == e->samples[k].buffer)
            return false;
        info.sample_buffers[n++] = {e->samples[k].buffer, e->samples[k].index};
      }
      return true;
    };
    EncoderData *last = base, *cursor = base->next;
    unsigned l = list, last_list = list;
    auto barriers = [&]() { return l == last_list ? last->barriers_last : 0u; }; // allowed before cursor, in list l
    for (;;) {
      if (!cursor) { // the end of list l: no barrier after `last` (or anywhere in a list of timestamps alone)
        if (static_cast<MTLD3D12GraphicsCommandList *>(lists[l])->barrier_count != barriers() || ++l == count)
          break;
        cursor = static_cast<MTLD3D12GraphicsCommandList *>(lists[l])->entry;
        continue;
      }
      if (cursor->type == EncoderType::Null) {
        cursor = cursor->next;
        continue;
      }
      if (cursor->barriers != barriers())
        break;
      if (cursor->type == EncoderType::Blit && cursor->timestamp_only) {
        folds_.push_back(cursor);
        cursor = cursor->next;
        continue;
      }
      if (cursor->type != EncoderType::Render)
        break;
      auto *next = static_cast<RenderEncoderData *>(cursor);
      unsigned n = samples;
      bool ok = !next->pre_tail && SameTarget(base, next);
      for (auto *f : folds_)
        ok = ok && fits(f, n);
      ok = ok && fits(next, n);
      if (!ok) { // put back what `fits` wrote past the samples kept
        for (unsigned j = samples; j < n; j++)
          info.sample_buffers[j] = {};
        break;
      }
      samples = n;
      merged_.insert(merged_.end(), folds_.begin(), folds_.end());
      merged_.push_back(next);
      folds_.clear();
      last = next;
      last_list = l;
      cursor = next->next;
    }
  }
```

In `ExecuteCommandLists`, after `bool serial = serial_ || dumping; ...`, add:

```cpp
    skipped_.clear();
    skip_ = 0;
```

Right after `EncoderData *current = pCommandList->entry, *previous = nullptr;`, add:

```cpp
      list_join_ = 0; // a list's first encoder joins, even one M3 already encoded
```

At the top of the `while (current) {` body, before `unsigned pass = 0;`, add:

```cpp
        if (skip_ < skipped_.size() && skipped_[skip_].first == current) { // encoded inside an earlier render pass
          if (current->position >= list_fences_.size())
            list_fences_.resize(current->position + 1);
          list_fences_[current->position] = skipped_[skip_++].second;
          if (current->type == EncoderType::Render) // DXMT_STAT_COUNT keeps one counter id per call site
            DXMT_STAT_COUNT("#render passes merged", 1);
          else
            DXMT_STAT_COUNT("#timestamp blits folded", 1);
          current = current->next;
          continue;
        }
```

In the `EncoderType::Render` case, right before `auto resolve_icbs = ...`, add:

```cpp
          if (!serial)
            PlanMerge(data, i, ppCommandLists, Count, render_pass_info);
          else
            merged_.clear();
```

Then replace:

```cpp
          Encode(encoder, fence, data->use_geometry ? WMTRenderStagePreRaster : WMTRenderStageVertex, &data->cmd_head,
                 data->cmd_tail, early);
```

with:

```cpp
          // Merged passes' commands follow this pass's, in one chain, unlinked again after.
          wmtcmd_base *tail = data->cmd_tail;
          for (auto *m : merged_)
            if (m->type == EncoderType::Render) {
              tail->next.set(&static_cast<RenderEncoderData *>(m)->cmd_head);
              tail = static_cast<RenderEncoderData *>(m)->cmd_tail;
            }
          Encode(encoder, fence, data->use_geometry ? WMTRenderStagePreRaster : WMTRenderStageVertex, &data->cmd_head,
                 tail, early);
          tail = data->cmd_tail;
          for (auto *m : merged_) {
            if (m->type == EncoderType::Render) {
              tail->next.set(nullptr);
              tail = static_cast<RenderEncoderData *>(m)->cmd_tail;
            }
            skipped_.push_back({m, fence});
          }
```

`EncodeOrdered` unlinks the last tail itself.

- [ ] **Step 5: Watch it pass**

```bash
RUN_ENV="DXMT_DXIL_DUMP=$PWD/$W/m3-green DXMT_STATS=1" sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" unsplit unsplit-barrier unsplit-samebuffer | grep hazard
grep -oE '(render passes merged|timestamp blits folded) [0-9]+' "$W/m3-green/stats.txt" | tr '\n' ';'; echo
for i in 1 2; do sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" | grep '^dxmt: hazard'; done
RUN_ENV="DXMT_D3D12_SERIAL=1" sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" | grep '^dxmt: hazard'
```

Expected:
- `hazard unsplit 257`, `hazard unsplit-barrier 257` and `hazard unsplit-samebuffer 257` on both backends.
- `render passes merged 1;timestamp blits folded 1;`.
- Every full run prints all 22 lines with the values in `check.sh`.

- [ ] **Step 6: Land the fork, check everything, commit**

```bash
git -C build/dxmt-src/dxmt add -A src/d3d12
git -C build/dxmt-src/dxmt commit -m "d3d12: render passes into the same targets across command lists are one Metal render pass (GPU overlap M3)

Within one ExecuteCommandLists call, a render pass into the same attachments as the join pass before it, with only
list boundaries and timestamp-only blits between and no barrier, is encoded inside that pass; the timestamps move to
its end. Not in strict order or while dumping.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git -C build/dxmt-src/dxmt push origin macneutron
sed -i '' "s/^DXMT_COMMIT=.*/DXMT_COMMIT=$(git -C build/dxmt-src/dxmt rev-parse HEAD)/" dxmt/pins
make dxmt-check > "$W/check-t6.log" 2>&1; grep -E '^(FAIL|dxmt-check)' "$W/check-t6.log"
swift test 2>&1 | tail -3
git add dxmt/tests/d3d12_hazards.cpp dxmt/check.sh dxmt/pins
git commit -m "feat(dxmt): render passes split at command lists are one Metal render pass again (GPU overlap M3)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected:
- `dxmt-check: all passed` with no `FAIL`.
- `timestamp rules` and `a timestamp between draws keeps them one render pass` still pass.
- Every Swift test passes.

---

### Task 7: M3 in SMITE 2 (measurement; needs the user)

**Files:** Modify `docs/testing/acceptance-dxmt-gpu-overlap.md` (Results).

- [ ] **Step 1: Install, and hand the runs to the user**

Same as Task 3 Step 1, with outputs in `"$W/m3-<run>.txt"`. Also ask for one more overlap run with `/usr/bin/env DXMT_D3D12_SM6=1 DXMT_DXIL_DUMP=/Users/chad/dxil-smite2 DXMT_STATS=1 %command%`. Its `~/dxil-smite2/stats.txt` gives:
- render passes merged and timestamp blits folded per frame;
- render passes per frame, against the 2026-10-01 baseline, which had about 6 per base pass.

- [ ] **Step 2: Record and commit**

Add an `M3` row like Task 3's, plus the merge counters.

```bash
git add docs/testing/acceptance-dxmt-gpu-overlap.md
git commit -m "docs: GPU overlap M3 acceptance results

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## After this plan

- M4 (folded clears) and M5 (idle gaps) follow, per the spec's order, using Task 1's idle breakdown.
- Lever 2 (one winemetal call per `ExecuteCommandLists`) stays deferred unless the "waiting for the CPU" idle grows.
