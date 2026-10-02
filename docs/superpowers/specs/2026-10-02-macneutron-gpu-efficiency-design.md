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

- **Measured: no gain (2026-10-02).** An experiment build let SMITE's vertex and geometry shaders fuse and reassociate freely (`DXMT_DXIL_VS_FAST=1`, no invariance: an upper bound), or keep strict math with Metal's late-invariance encoding (`=late`: the function attributes `invariance-late-contract`, `-reassoc` and `-unsafe-fp-math` and `llvm.fmuladd`, as MSL's `-fpreserve-invariance` emits; our position output already carries `air.invariant`). The base pass's vertex time was 2.43 ms by default, 2.45 with `late`, 2.35 even fully fused; no flicker either way. Unfused vertex math isn't why our vertex work exceeds D3DMetal's: E3 is not built and the switch is gone. The remaining base-pass vertex gap (about 0.4 ms) is left for a later investigation (vertex fetch, varyings).

### E4. Timestamp blits

- SMITE's lone timestamps are mostly a command list's first timestamp, and lists of timestamps alone (`null blit blit null` in the passes list); there is no earlier encoder in the list to carry them.
- So the queue doesn't encode a timestamp-only blit: its sample waits, in order, and is taken at the start of the next encoder it encodes (render pass: start of vertex, a new index in winemetal's render pass sample attachments; blit and compute: start of encoder), in a later list of the call if need be. Only the latest waiting sample rides, so values stay in order; the earlier ones, or one whose counter buffer the encoder can't take beside its own (one per encoder, E2), get blits of their own first. A list-start join waiting with them carries to that encoder. Leftovers at the end of the call get blits of their own, and so do samples waiting for an encoder whose start isn't ordered after earlier work (a clear or resolve pass waits before its fragment stage only; a pass's indirect resolvers run first) or that Metal drops (no commands). After the queue's own join inside a list (these blits, E2's), the next list encoder anchors dependencies again (overlap order). Off with `DXMT_D3D12_MERGE=0` and while dumping.
- **Tests:** `d3d12_hazards ts-start` (three lists in one call: in order, `DXMT_STATS` 2 taken at the next encoder's start); the timestamp, `two-heaps` and M3 modes unchanged.

### E5. Buffer bounds checks

- A raw or structured buffer load is bounds-checked once for all the components the shader reads (Metal Shader Converter's form; a SM 6.0/6.1 BufferLoad names all four, so the ones it extracts count) instead of per component; one straddling its view's end reads zeros (D3DMetal reads past the view there). The bounds math is 64-bit: an offset near 4 GiB doesn't wrap past the check. Stores keep per-component checks. `DXMT_DXIL_BOUNDS=component` restores per-component loads (triage); the shader cache keys it apart.
- **Measured** with an experiment build: fragment work 6.37 → 6.20 ms per frame, base-pass fragment 1.57 → 1.38 ms.
- **Tests:** `d3d12_bounds` (shaders/bounds.hlsl): loads in bounds (the view's last dwords too), straddling, out of bounds and at a wrapping offset, through 16-dword and 4-element views over larger buffers; all but the straddling ones equal D3DMetal's. `d3d12_hazards after-own-blit` pins overlap order after the queue's own blit.

### E6. Targeted NaN handling

- **Measured: no gain; not built (2026-10-02).** Fast-math flags cost about nothing in SMITE's fragment shaders (ours against Metal Shader Converter's on real shaders), E3 found no math cost in vertex shaders, and the comparison with D3DMetal's Metal 3 path puts lighting, full-screen and post passes at parity; the compute gap (1.4-3x per dispatch) is too large for float flags. Ceiling about 0.05 ms.

### E7. Remaining clears

- **Measured:** after M4, SMITE encodes 10 clear-only passes per frame; each is in the same `ExecuteCommandLists` call as the first pass binding its view, mostly in an earlier list (the G-buffer clears, the prepass depth), with only timestamp blits, empty lists and the target's ICB resolver between. D3DMetal has none. Expected gain about 0.08-0.13 ms (the cleared stores of the targets E1 leaves uncompressed move into the base pass rather than disappear).
- **At execution, per call:** from a clear-only pass the queue walks past list boundaries, timestamp-only blits and other textures' clears to the first encoder. If it is a render pass binding the view (M4's match, `ClearSlot`, shared) and no barrier call between names the texture (lists log the resources each barrier call names; an unknown or resourceless aliasing or UAV barrier counts as naming it), the clear is skipped and becomes that pass's load action for this execution only, unless the pass already clears that plane (a later clear, M4's, wins). The pass joins, as the clear would have. In D3D12 a render target can only be read through an encoder after a transition naming it, so nothing between can see the clear done late. Off with `DXMT_D3D12_MERGE=0` and while dumping. `DXMT_STATS`: clears folded at execute; refused (barrier, no target, mismatch).
- **Measured in SMITE 2:** 9 of 10 clears fold per frame, but the clear passes' 0.17 ms moved into the base pass (the cleared stores of its UAV-capable targets, which E1 leaves uncompressed): no net gain. Kept, as it costs nothing and leaves the clears where a compressed target makes them free.
- **Tests:** `d3d12_hazards` fold-lists (across lists and a barrier on another texture: folds), fold-lists-barrier (a barrier on the texture: refused), fold-m4 (a later clear M4 folded wins), fold-twice (a list executed twice in one call, then again), fold-copy (a copy of the texture between: refused); pixels equal D3DMetal's.

### E8. Discard load/store

- **Measured: not indicated; not built (2026-10-02).** The costly stores are between the base pass's split pieces, where the data is still needed, and full-screen passes are at parity with D3DMetal's; DiscardResource and depth-store mapping are worth 0.05 ms or less. Revisit once the base pass is one Metal pass.

### E9. Metal 4

- **Measured (2026-10-02):** D3DMetal at the spot runs 10.55 ms per frame with its Metal 4 back end (`D3DM_MTL4=1`, its default) and 9.26 ms without it (`D3DM_MTL4=0`): Metal 4 is slower for SMITE 2, so no Metal 4 back end is built. The comparison target becomes D3DMetal's Metal 3 path (fragment 5.6, vertex 2.8, compute 0.9 ms per frame).

## 4. Error handling

- Each milestone has an off switch (`DXMT_D3D12_COMPRESSION=0`, and per milestone after it); a picture problem is triaged by turning switches off.
- A private Metal selector missing on a future macOS falls back to today's behaviour.

## 5. Delivery

- Fork commits on `macneutron`, pushed before `dxmt/pins` moves; MacNeutron: tests, `check.sh`, the pin, README switches, and per milestone a row in `docs/testing/acceptance-dxmt-gpu-efficiency.md`.
