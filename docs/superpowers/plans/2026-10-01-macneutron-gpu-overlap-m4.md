# GPU Overlap M4 (Folded Clears) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A clear-only render pass followed, in the same command list with no barrier between, by a render pass that has the cleared view as an attachment becomes that pass's clear load action.

**Architecture:** At recording time. When `PreDraw` opens a render pass, the allocator looks at the clear encoders at the end of the list recorded since the last barrier call. It unlinks them, moves each one that matches an attachment of the new pass into that attachment's load action, and appends the others again through `InvalidateCurrentPass`, so `Decide` re-derives their ordering. The queue needs no change: folded clears are no longer in the list.

**Tech Stack:** C++ (fork `build/dxmt-src/dxmt`, branch `macneutron`), mingw test programs (`dxmt/tests`), `dxmt/check.sh`.

**Spec:** `docs/superpowers/specs/2026-10-01-macneutron-gpu-overlap-design.md` (§3.6, §5 row M4, §7)

## Global Constraints

- Public repo; DXMT refuses AI-authored contributions: fork commits on `macneutron`, pushed before `dxmt/pins` moves; never a PR upstream.
- No core, GPU-model or core-count assumptions.
- `DXMT_D3D12_MERGE=0` (triage) turns off folding as well as M3's merging.
- After `make dxmt`/`make dxmt-check`, run `git -C build/dxmt-src/dxmt switch macneutron` before committing in the fork.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A clear whose view is the same texture but a different mip or slice than the pass's attachment: not folded (view pointers differ).
2. A cleared view larger than the pass's render area (attachments of different sizes): not folded, since a Metal clear load action covers only the render area.
3. A clear of a target the pass doesn't use, between foldable clears: it stays, re-decided, and its ordering is unchanged (d3d12_depth's clears of RT1 and RT2).
4. Two clears of one view before the pass: the later value wins.
5. A barrier between the clear and the pass, or any other encoder (a copy, a rect clear, a timestamp) between them: no fold.

---

### Task 1: The test, failing first

**Files:**
- Modify: `dxmt/tests/d3d12_hazards.cpp` (new mode `fold`)
- Modify: `dxmt/check.sh` (section 8 `want`, plus an M4 stats check)

- [ ] **Step 1: Write the mode**

```cpp
// M4 (GPU overlap spec §3.6): T0 cleared to 2, then 4 additive draws into its left half (scissor): one Metal render
// pass, its clear the load action. T1 cleared to 5, a barrier (on T2), then the same draws: the clear stays a pass.
// Prints T0 left, T0 right, T1 left, T1 right: 6 2 9 5.
static void Fold() {
    const float two[4] = {2, 2, 2, 2}, five[4] = {5, 5, 5, 5};
    D3D12_RECT left = {0, 0, (LONG)kSize / 2, (LONG)kSize};
    g->list->ClearRenderTargetView(T[0].rtv, two, 0, nullptr);
    Bind(T[0], add, 1);
    g->list->RSSetScissorRects(1, &left);
    g->list->DrawInstanced(3, 4, 0, 0);
    g->list->ClearRenderTargetView(T[1].rtv, five, 0, nullptr);
    g->Barrier(T[2].texture, RT, PSR);
    Bind(T[1], add, 1);
    g->list->RSSetScissorRects(1, &left);
    g->list->DrawInstanced(3, 4, 0, 0);
    g->Barrier(T[2].texture, PSR, RT);
    Read(T[0], RT, 100, 512, 0);
    Read(T[0], RT, 900, 512, 1);
    Read(T[1], RT, 100, 512, 2);
    Read(T[1], RT, 900, 512, 3);
    g->Submit();
    printf("hazard fold %g %g %g %g\n", Texel(0), Texel(1), Texel(2), Texel(3));
}
```

Register `{"fold", Fold}` in `kModes`. In `check.sh` add `"fold 6 2 9 5"` to `want`, and after the M3 checks:

```sh
# M4 (GPU overlap spec §3.6): a clear then a pass into the cleared target, no barrier between: one Metal render pass
# with the clear as its load action. Not across a barrier, nor with DXMT_D3D12_MERGE=0.
rm -rf "$WORK/m4-stats"; export DXMT_DXIL_DUMP="$WORK/m4-stats" DXMT_STATS=1
run ours m4-stats dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" fold
unset DXMT_DXIL_DUMP DXMT_STATS
expect "a clear before a pass into its target is the pass's load action" \
  "$(grep -oE '(clears folded|clear passes) [0-9]+' "$WORK/m4-stats/stats.txt" 2> /dev/null | tr '\n' ';')" \
  "clear passes 1;clears folded 1;"
rm -rf "$WORK/m4-off-stats"; export DXMT_DXIL_DUMP="$WORK/m4-off-stats" DXMT_STATS=1 DXMT_D3D12_MERGE=0
run ours m4-off-stats dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" fold
unset DXMT_DXIL_DUMP DXMT_STATS DXMT_D3D12_MERGE
expect "and none with DXMT_D3D12_MERGE=0" \
  "$(grep -oE '(clears folded|clear passes) [0-9]+' "$WORK/m4-off-stats/stats.txt" 2> /dev/null | tr '\n' ';'):$(grep '^hazard ' "$WORK/m4-off-stats.txt")" \
  "clear passes 2;:hazard fold 6 2 9 5"
```

(Check the order `grep -o` prints the two counters in against the stats file and write the expectation in that order.)

- [ ] **Step 2: Run it**

Run: `sh dxmt/tests/run.sh d3d12_hazards fold` and the stats check by hand (`DXMT_STATS=1`).
Expected: `hazard fold 6 2 9 5` on both backends; stats `clear passes 2`, no `clears folded` line (RED).

### Task 2: Fold the clears (fork)

**Files:**
- Modify: `src/d3d12/d3d12_command_allocator.hpp` (run tracking in `InvalidateCurrentPass`, `FoldClears`)
- Modify: `src/d3d12/d3d12_command_list.cpp` (`PreDraw` calls it, counts `#clears folded`)

- [ ] **Step 1: Track the trailing clears.** In `InvalidateCurrentPass`, before linking: `if (encoder_current->type == EncoderType::Clear && encoder_last->type != EncoderType::Clear) clears_from_ = encoder_last;` (the encoder before the run of clears that ends the list).

- [ ] **Step 2: `FoldClears(RenderEncoderData *r)`.** Returns the number folded; 0 when `DXMT_D3D12_MERGE=0` or the list doesn't end in clears.
  - The run: the clears after `clears_from_` whose `barriers == r->barriers` (no barrier since); `before` is the encoder before them.
  - A clear matches when its view is one of `r`'s attachments (colors by `attachment.ptr()` and `depth_plane`; depth and stencil each by `attachment.ptr()` for the planes it clears), its `width`, `height` and `array_length` equal `r`'s render target width, height and array length.
  - None matches: return 0. Otherwise unlink the run (`encoder_last = before`, `before->next = nullptr`, `encoder_count_` and `group_` back by its length), set each match's attachment to `WMTLoadActionClear` with its value (in order: a later clear of a view wins), then append each other clear again (`next`, `deps`, `dep_count` reset; `encoder_current = it; InvalidateCurrentPass();`) and restore `encoder_current = r`.

- [ ] **Step 3: Call it** in `PreDraw` after the attachments and render target size are set: `if (unsigned n = allocator_->FoldClears(render)) DXMT_STAT_COUNT("#clears folded", n);`

- [ ] **Step 4: Run** `sh dxmt/tests/run.sh d3d12_hazards` (every mode) and `d3d12_depth`.
Expected: every hazard line as `want`, including `hazard fold 6 2 9 5`; d3d12_depth pixels equal D3DMetal's.

- [ ] **Step 5: Commit** in the fork (`switch macneutron` first), push, move `dxmt/pins`.

### Task 3: Existing expectations, the README, acceptance

- [ ] **Step 1:** `make dxmt-check`. Folding removes clear passes from many tests; for each changed expectation (pass numbers in the depth dump and pixel history, encoder and fence-wait counts in section 8), confirm the new value follows from the clears now gone, then update it with its comment.
- [ ] **Step 2:** `make test`.
- [ ] **Step 3:** README: the `DXMT_D3D12_MERGE=0` sentence also covers folded clears.
- [ ] **Step 4:** Commit MacNeutron (tests, check.sh, pin, README).
- [ ] **Step 5:** Acceptance (spec §7), with the user in SMITE 2: a Metal trace and PEX against M3's row; `DXMT_STATS` clear passes per frame before and after. Record in `docs/testing/acceptance-dxmt-gpu-overlap.md`.
