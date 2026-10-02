# MacNeutron — DXMT Fork, Sub-project 4 (third slice): GPU Efficiency

- **Date:** 2026-10-02
- **Status:** approved order (user, 2026-10-02): E1 → E2 → E3 → E4 → E5, then E6 → E7 → E8 → E9
- **Builds on:** `2026-10-01-macneutron-gpu-overlap-design.md` (M1–M5 done: the GPU idles 0.3 ms per frame in SMITE 2, so frame time is GPU work), `2026-09-28-macneutron-dxmt-fork-design.md` (`make dxmt-check`, capture mode).
- **Scope:** the GPU work our D3D12 path asks for, against what D3DMetal asks for, with no added input latency: no frame generation, no deeper frame queues.
- **Out:** the translation-layer redesigns (research 2026-10-02: no frame-time gain on GPU-bound games; Rosetta stays per the user's assumption), D3D11, game settings.

## 1. Goal

SMITE 2 (and other D3D12 games) render the same frames with less GPU time on our DXMT, approaching D3DMetal at the same spot, on any Mac.

**Done when**, per milestone: its tests failed first and pass, `make dxmt-check` and `make test` are green, and SMITE 2 at the M4/M5 spot is measured against the previous milestone (a milestone that measures no gain is recorded as such).

## 2. Evidence (2026-10-02, M4/M5 spot, 2560×1440 render targets, TSR, M5 Pro, macOS 27)

| Per frame | D3DMetal | DXMT (fork 72193e9) |
|---|---|---|
| Frame period | 10.14 ms (99 fps) | 14.22 ms (70 fps) |
| GPU busy | 9.87 ms | 13.70 ms |
| Fragment / vertex / compute | 6.2 / 2.9 / 0.9 ms | 8.2 / 3.4 / 1.6 ms |

- The game renders the same work: its 102 scalability settings are identical, Nanite, Lumen and virtual shadow maps are off on both, and reporting D3DMetal's adapter identity changes nothing (14.19 ms).
- Our GPU time by pass: base pass (7 colour + depth) 4.77 ms as about 6 Metal render passes (D3DMetal: 3 encoders, 3.3 ms); full-screen one-colour passes 2.38 ms; one colour + depth 1.95 ms; depth-only 1.40 ms; compute 1.31 ms; about 10 clear-only passes 0.78 ms (7 of them G-buffer clears in a command list before the base pass; D3DMetal has none); about 96 blit encoders 0.29 ms (mostly lone timestamps); 13 indirect-resolve passes 0.1 ms.
- **Compression.** `PixelFormatView` usage, which our D3D12 textures all get, turns Apple's lossless compression off for every colour format on the M5 (storage mode, heaps and `shaderWrite` don't matter; depth stays compressed). D3DMetal keeps `PixelFormatView` but calls the private `-[MTLTextureDescriptor setCompressionMode:1]` on every texture except UAVs and row-major layouts. Measured with SMITE's own attachment contents at 2560×1440: a 7-colour + depth load/store pass 1.17–1.34 → 0.33–0.42 ms; a clear-only pass 0.16–0.26 → 0.01 ms; a one-colour post pass 0.27–0.31 → 0.13–0.18 ms. Writes through a different-layout view (D3D12's R32 UAV on a 32-bpp typeless texture) corrupt a compressed texture.
- **Shaders** (real SMITE shaders, ours against Apple's Metal Shader Converter, fragment only): 0.3–0.6 ms, almost all from a per-component bounds check on every raw or structured buffer load; fast-math flags, unfused vertex math, descriptor indirection and LOD clamps cost about nothing. Vertex cost not measured.
- **Passes:** unmerged base-pass segments about 0.75 ms; the 7 unfolded G-buffer clears about 0.3 ms (less once compressed); discard and depth-store mapping 0.05 ms or less.

## 3. Milestones

### E1. Compressed textures

- A D3D12 texture is created with lossless compression requested (`setCompressionMode:1`, when the descriptor responds to it) unless it allows unordered access, has a row-major or standard-swizzle layout, or is shared across adapters or processes. The same descriptor sizes placed resources (`heapTextureSizeAndAlign`, `GetResourceAllocationInfo`), so heap offsets stay consistent.
- `DXMT_D3D12_COMPRESSION=0` turns it off (triage). `DXMT_STATS` counts textures created compressed.
- The private selector is guarded (`respondsToSelector:`); without it textures stay as today.
- **Tests:** a clear-heavy GPU timing measured with D3D12 timestamps, at least 3× faster than with the switch off; a typeless RGBA8 target rendered through a UNORM view and read through UINT and sRGB views, equal to D3DMetal; placed textures in one heap at the offsets `GetResourceAllocationInfo` gives, equal to D3DMetal; every existing test.

### E2. One base pass

- **Measured after E1 (design workflow, 2026-10-02):** SMITE's six base-pass segments come from one `ExecuteCommandLists` call; every boundary fails M3's timestamp check (each segment's two timestamps share a counter buffer) and four fail on ExecuteIndirect's resolvers. The M5 Pro samples counters only at stage boundaries (no sample between draws). With compressed targets a segment boundary costs little (the last segment's whole fragment stage: 37 µs median), so merging S3–S6 is worth at most about 0.14 ms per frame (0.3 ms if the earlier segments' barriers allow it), while folding several timestamps onto one sample risks stale, zero or backwards values (resolves in later calls, overlap order), which Unreal's GPU timing (dynamic resolution, stat gpu) reads.
- **Decision:** the merge extension is not built (recorded as measured-small). E2 keeps the prerequisite fix it found:
- **One counter buffer per encoder.** Apple GPUs write only the last counter buffer attached to an encoder (render, blit or compute; Metal validation is silent), so a render pass sampled from two timestamp heaps (or M3's merged pass with folded timestamps) lost all but one sample. The pass keeps its first sample; each other one's sample is taken by a blit of its own right after the pass (about 1 µs each). `DXMT_STATS` counts them.
- **Tests:** `d3d12_hazards two-heaps`: a pass sampled from two heaps, two frames: both heaps' timestamps nonzero and increasing (`1 1`; before: `0 1`).

### E3. Position invariance

- Vertex and geometry shaders contract their math (FMA) again; the output position is computed invariantly instead (Metal's `[[invariant]]` with invariance preserved at compile time), which keeps a depth prepass and the base pass bit-identical (the reason for today's unfused rule).
- **Tests:** check.sh's depth-EQUAL and grass cases with the new rule; the "unfused" check becomes "position invariant".

### E4. Timestamp blits

- A lone timestamp no longer opens its own blit encoder: its sample goes to the previous encoder's end, or the next one's start, in the same command buffer (Metal samples at stage boundaries), the resolve reading that sample.
- **Tests:** timestamp order and monotonicity as D3DMetal's (d3d12_timestamp), encoder counts in `DXMT_STATS`.

### E5. Buffer bounds checks

- A raw or structured buffer load is bounds-checked once per load, not per component, and not at all where D3D12 guarantees robustness doesn't apply (no robust buffer access requested for root descriptors).
- **Tests:** out-of-bounds loads return zeros as D3DMetal's, in a new shader test; translated shader counts unchanged.

### E6. Targeted NaN handling

- Measure first: our fast-math flags cost about nothing in fragment shaders. If a vertex or compute measurement shows a gain, allow fast math with D3DMetal-style targeted fixes (D3DMetal's `D3DM_FLUSH_POS_INF_TO_NAN`, `D3DM_SAMPLE_NAN_TO_ZERO`); otherwise record "no gain" and stop.

### E7. Remaining clears

- A clear in an earlier command list of the same call (or a coalesced call) folds into the first pass that binds the view, when no barrier or other use of that texture comes between.

### E8. Discard load/store

- `DiscardResource` (and render-pass discard flags) map to `DontCare` store on the last pass before and load on the first pass after.

### E9. Metal 4

- First measure what Metal 4 is worth to D3DMetal on SMITE (`D3DM_MTL4` on and off at the same spot). Only if it is worth more than about 0.5 ms is a Metal 4 back end designed, in its own spec.

## 4. Error handling

- Each milestone has an off switch (`DXMT_D3D12_COMPRESSION=0`, and per milestone after it); a picture problem is triaged by turning switches off.
- A private Metal selector missing on a future macOS falls back to today's behaviour.

## 5. Delivery

- Fork commits on `macneutron`, pushed before `dxmt/pins` moves; MacNeutron: tests, `check.sh`, the pin, README switches, and per milestone a row in `docs/testing/acceptance-dxmt-gpu-efficiency.md`.
