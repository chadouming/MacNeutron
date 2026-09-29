# MacNeutron — DXMT Fork, Sub-project 3 (first slice): D3D12 Stubs

- **Date:** 2026-09-29
- **Status:** Draft for review
- **Builds on:**
  - `2026-09-28-macneutron-dxmt-fork-design.md`: roadmap §2 item 3; the fork, `make dxmt`, `make dxmt-check`, capture mode.
  - `2026-09-29-macneutron-dxil-translator-design.md`: DXIL shaders, SMITE 2 running on our DXMT, the occlusion-query fix (fork `66e1e1d`) and the pass dump (fork `ec3ce2d`).
- **Scope:**
  - **In:** the stubs in the fork's `src/d3d12` that abort the game or quietly do the wrong thing, in two batches:
    - **Batch 1:** calls that abort (`IMPLEMENT_ME`) or fail where D3DMetal succeeds.
    - **Batch 2:** calls that succeed but behave wrongly.
    
    Plus real GPU timestamps.
  - **Out (later specs):**
    - the mid-sized aborting stubs: `WriteBufferImmediate`, `ExecuteBundle`, `ResolveSubresourceRegion`, `SetSamplePositions`, `AtomicCopyBufferUINT*`, `SetPredication`, the buffer-to-buffer branch of `CopyTextureRegion`, the `IDXGISwapChain` getters and setters;
    - stream output, tiled (reserved) resources, tessellation, view instancing, raytracing, mesh shaders, sampler feedback, variable-rate shading;
    - real resource barriers;
    - the depth-bounds test (see §3.4);
    - the persistent shader cache (sub-project 4, which the pipeline library in §3.1 prepares for).

## 1. Goal

A D3D12 game never dies in one of these stubs, and gets what it gets on D3DMetal from each call this spec covers. How each call works is ours to choose: whatever uses Apple Silicon best and costs least.

**Done when** §7 passes:
- every fix has a test that failed first and now prints what D3DMetal prints (timestamps: D3D12's rules, §3.3);
- `make dxmt-check` is green;
- SMITE 2 still renders its lobby on our DXMT, and its log has no `unhandled feature` or `is not implemented` lines.

### Decisions made during brainstorming

| Decision | Choice |
|---|---|
| Split | Two batches: batch 1 is aborts and failures D3DMetal doesn't have; batch 2 is silent wrong behaviour. The mid-sized aborts are a later spec |
| Reference for tests | D3DMetal on the same Mac: each test prints the same output on both |
| Implementation freedom | Any mechanism that gives D3DMetal's result. Apple Silicon first: no allocation per call, no split render passes, results resolved on the GPU |
| GPU timestamps | Real ones, although D3DMetal has none (it logs `Unsupported: EndQuery`): Metal counter samples at encoder boundaries, resolved on the GPU. Tested against D3D12's rules, not D3DMetal |
| Capabilities | `CheckFeatureSupport` answers every query D3DMetal answers, with D3DMetal's return codes, and reports DXMT's own capabilities in them |
| Depth bounds | Stay ignored: Metal has no depth-bounds test, and emulating one in shaders costs more than the pixels it saves |

## 2. Evidence (2026-09-29; fork `ec3ce2d`, D3DMetal from GPTK on an M5 Pro)

1. **Stub survey** of `src/d3d12`:
   - **Aborts:** `IMPLEMENT_ME` logs and calls `abort()`, so a game that calls one dies. Batch 1 fixes the aborts D3D12 games commonly hit: command-list `BeginEvent`/`EndEvent`/`SetMarker` and `GetCachedBlob`.
   - **Silent:** `ResolveQueryData` was one (fixed in `66e1e1d`: Unreal culled the meshes whose occlusion results read 0). The others:
     - `CopyResource` skips copies between different formats, with only a warning;
     - read-only depth-stencil views are written to (their flags are stored but never read);
     - null SRV/UAV descriptors are zero-filled whatever their view type (the code's own TODO);
     - timestamps are 0, with a frequency of 1 and a GPU calibration of 0;
     - `PreDraw`'s `while (dsv.ptr)` loop spins forever on a depth view without a texture.
2. **What D3DMetal answers** (throwaway probes, same Mac):

   | Call | Our DXMT (`ec3ce2d`) | D3DMetal |
   |---|---|---|
   | `CheckFeatureSupport` | `E_NOTIMPL` for OPTIONS5, 6, 8–11, 13–15, 17, 18, EXISTING_HEAPS, CROSS_NODE, DISPLAYABLE, PROTECTED_RESOURCE_SESSION_SUPPORT, 48 and 53 | `S_OK` for OPTIONS to OPTIONS18, ARCHITECTURE1, GPU_VIRTUAL_ADDRESS_SUPPORT, SHADER_CACHE, EXISTING_HEAPS, PROTECTED_RESOURCE_SESSION_SUPPORT, 48 (40-byte struct) and 53 (16-byte struct); `E_INVALIDARG` for CROSS_NODE and DISPLAYABLE |
   | `CreateCommandList1`, `CreateHeap1` | `E_NOTIMPL` | `S_OK`; the new list is closed |
   | `Evict`, `MakeResident`, `SetResidencyPriority` | `Evict` and `SetResidencyPriority` return `E_NOTIMPL` | `S_OK` |
   | `EnqueueMakeResident` | `E_NOTIMPL` | `S_OK`; the fence reaches the value |
   | `SetEventOnMultipleFenceCompletion` | `E_NOTIMPL` | `S_OK`; the event fires |
   | `SetStablePowerState` | `E_NOTIMPL` | `E_NOTIMPL` (unchanged) |
   | `GetCachedBlob` | aborts | `S_OK`, a 0-byte blob, which `CachedPSO` accepts back |
   | Pipeline library (sequence below) | `CreatePipelineLibrary` `E_NOTIMPL` | a working library |
   | Timestamps | 0; frequency 1; calibration GPU 0, CPU `QueryPerformanceCounter` | 0 (logs `Unsupported: EndQuery`, `ResolveQueryData`); frequency 60; calibration GPU = CPU = the Mac's clock ticks |

   D3DMetal's pipeline library, in order:
   - an empty library is created (`S_OK`);
   - loading a missing name gets `E_INVALIDARG`;
   - `StorePipeline` returns `S_OK`, and storing the same name again gets `E_INVALIDARG`;
   - loading the stored name with the same description returns the same pipeline object;
   - loading it with a different description gets `E_INVALIDARG`;
   - `Serialize` returns `S_OK` (118 bytes here);
   - a library created from that blob loads the name (`S_OK`);
   - a library created from 64 junk bytes gets `D3D12_ERROR_DRIVER_VERSION_MISMATCH` (`0x887E0002`).
3. **SMITE 2** asks for OPTIONS5, OPTIONS6, OPTIONS11, 48 and 53 during startup; our DXMT logs `CheckFeatureSupport: unhandled feature` for each.
4. **Old header.** The fork's `include/native/directx/d3d12.h` lists features only up to OPTIONS7 and defines option structs only up to OPTIONS5. llvm-mingw's header, which the tests build with, has OPTIONS6 to OPTIONS18.

## 3. Design

All changes are in the fork (`chadouming/dxmt`, branch `macneutron`), mostly `src/d3d12`, with `winemetal` where Metal needs a new call. The tests are in MacNeutron's `dxmt/tests` and `dxmt/check.sh`.

### 3.1 Batch 1: aborts and failures D3DMetal doesn't have

1. **Event markers.** The command list's `BeginEvent`, `EndEvent` and `SetMarker` do nothing, as the queue's already do.
2. **`GetCachedBlob`** on graphics and compute pipelines returns an empty blob (`S_OK`, 0 bytes). A `CachedPSO` given at creation is accepted and ignored, as it is today.
3. **Residency.** `MakeResident`, `Evict` and `SetResidencyPriority` return `S_OK` and do nothing: on unified memory nothing is paged out, and DXMT's residency sets already keep heaps resident. `EnqueueMakeResident` signals its fence to the value at once, on the CPU.
4. **`SetEventOnMultipleFenceCompletion`.** Built on the device's existing shared-event listener (`event_listener`, which `SetEventOnCompletion` uses), with no new thread:
   - **ANY:** the event is registered on every fence.
   - **ALL:** a small shared countdown, decremented by each fence's notification, sets the event at zero.
   
   Fences already at their value count at once. With no event, the call waits on the CPU as `SetEventOnCompletion` does.
5. **`CreateCommandList1`** creates a closed list with no allocator, the same object `CreateCommandList` makes. **`CreateHeap1`** with no protected session is `CreateHeap`; with one, it stays `E_NOTIMPL`, as `CreateCommittedResource1` does.
6. **`CheckFeatureSupport`.**
   - **Queries answered:** the same as D3DMetal, with the same return codes (§2.2). The struct size must match, as D3D12 requires.
   - **Values:** DXMT's own capabilities. Raytracing, mesh shaders, variable-rate shading, sampler feedback, enhanced barriers and the other features the fork lacks are reported absent.
   - **Header:** the fork's `d3d12.h` gets the newer feature values and option structs it lacks, copied from the Agility SDK's layout (OPTIONS6 to OPTIONS21, and the 48 and 53 structs).
7. **Pipeline library** (`ID3D12Device1::CreatePipelineLibrary`, `ID3D12PipelineLibrary1`). Semantics are D3DMetal's (§2.2).
   - **Storage:** a map from name to the stored pipeline and the hash of its full description. The hash covers every field: shader bytes, the root signature's blob, the input layout, stream output and states, for graphics, compute and stream descriptions alike.
   - **Loading a stored pipeline** with a matching hash returns the same object (an AddRef, no work).
   - **Serialized form:** a small header (magic and version) followed by each name and its hash. No shaders are stored: the app passes the full description to `Load*` anyway.
   - **A library created from a blob** holds names without objects. Loading one of those names checks the hash, creates the pipeline through the normal path and keeps it.
   - **A blob with the wrong magic or version** gets `D3D12_ERROR_DRIVER_VERSION_MISMATCH`.
   - **Later:** sub-project 4's persistent cache can make those creations cheap without touching the library.
8. **The `PreDraw` depth-view loop** stops (`break`) when the view has no texture, instead of spinning.

### 3.2 Batch 2: silent wrong behaviour

1. **Read-only depth and stencil views.**
   - **The fix:** `CreateDepthStencilView` already keeps the view's flags (`MTL_RENDER_TARGET_DESC::Flags`), but `PreDraw` sets `dsv_readonly_flags` to 0. It will set them from `D3D12_DSV_FLAG_READ_ONLY_DEPTH` (1) and `D3D12_DSV_FLAG_READ_ONLY_STENCIL` (2), whose bits already match the read-only variants each pipeline builds (`GetDepthStencilState`).
   - **Cost:** no new Metal objects.
   - **Side effect:** the depth texture is no longer written while it's bound for reading (Metal counts that as a hazard).
2. **Format-reinterpreting copies**, in `CopyResource` and `CopyTextureRegion` alike (one helper). D3D12 allows copies between formats of the same bits per texel, and between block-compressed formats and integer formats of the same block size.
   - **Same bits per texel, neither compressed** (typeless ↔ typed, UNORM ↔ sRGB ↔ UINT, R32 ↔ RGBA8 and the like): one blit from a view of the source in the destination's pixel format. Every fork texture carries `PixelFormatView` usage, so there's no extra memory or pass.
   - **Compressed ↔ uncompressed** (BC1/BC4 ↔ 64-bit, BC2/3/5/6H/7 ↔ 128-bit): Metal views can't cross that line. The copy goes texture → buffer → texture in one blit encoder, through staging space from the command allocator's GPU heap. There's no allocation per copy, and the staging space is reused once the command buffer completes.
   - **Depth ↔ colour of the same size** (for example D32 ↔ R32): through a buffer with the depth blit option.
   - **Anything D3D12 doesn't allow** is skipped with a warning, as today.
3. **Null descriptors.**
   - **Shared resources:** the device creates, once, one tiny zeroed resource per view type: 1×1 textures of each type (1D, 1D array, 2D, 2D array, 2D multisample, 3D, cube, cube array) and a zeroed buffer. They join the device's residency set.
   - **Descriptors:** a null SRV or UAV descriptor (`pResource == nullptr`) of a given view dimension points at the matching one, so reads return zeros with nothing per descriptor.
   - **Writes:** writes through a null UAV are discarded: the null UAV's buffer is a separate scratch resource whose contents are never read back.
   - **Dimension queries** return what `d3d12_null` (§5.4) records D3DMetal answering. Where that differs from what the 1×1 resource reports (for example 0 instead of 1), a null flag in the descriptor's metadata word (the one `TextureMetadata` packs) makes the translated size query return D3DMetal's value.
4. **Depth bounds.** Unchanged: `OMSetDepthBounds` and `DepthBoundsTestEnable` are still ignored (see §1's decisions). Unreal only uses depth bounds to skip pixels whose lighting is zero anyway.

### 3.3 GPU timestamps

1. **Samples.** Apple GPUs sample counters only at stage boundaries (`MTLCounterSamplingPointAtStageBoundary`). Each timestamp query heap owns counter sample buffers with one sample index per query: Metal's size limit per buffer, as many buffers as the heap needs.
2. **`EndQuery(TIMESTAMP, i)`** asks the next encoder boundary in the command list to write sample `i`:
   - **An encoder is open:** at its end. For a render pass, that's the end of the fragment stage, so a timestamp between two draws reads the end of their pass: it's never split.
   - **None is open:** at the start of the next encoder.
   - **Nothing follows before `Close`:** an empty blit encoder carries it.
   
   One boundary holds up to Metal's per-pass limit of sample-buffer attachments. More timestamps at one boundary get empty blit encoders, each taking a start and an end sample per attachment.
3. **`ResolveQueryData(TIMESTAMP)`** is one GPU blit (`resolveCounters`) from the heap's sample buffer straight into the destination. There's no CPU readback, so the values are there when the app's fence signals.
4. **`GetTimestampFrequency`** is the GPU tick rate, measured once per device by correlating two readings of Metal's `sampleTimestamps` (CPU and GPU clocks) taken apart. The resolved values are raw GPU ticks, so no conversion pass runs.
5. **`GetClockCalibration`** returns Metal's GPU clock and the matching `QueryPerformanceCounter` value. The latter is read on either side of `sampleTimestamps` and averaged, so the error is under a microsecond.
6. **`winemetal`** gains:
   - sample-buffer attachments on render and compute pass descriptors (blit passes have them already);
   - `sampleTimestamps`;
   - the counter-sampling support check.
   
   A device without stage-boundary sampling keeps today's zeros.

### 3.4 Performance rules (every item)

- **No allocation per call.** Staging space comes from the command allocator's GPU heap, and null resources and counter sample buffers are created once.
- **No extra render passes.** Timestamps and queries attach to existing encoder boundaries; nothing splits a pass.
- **Results stay on the GPU timeline:** occlusion, timestamps and copies are resolved by the GPU, never read back on the CPU.
- **Existing Metal objects are reused:** depth-stencil variants, texture views, the listener thread.
- **Where unified memory makes a D3D12 concept meaningless** (residency, stable power), the call costs nothing.

## 4. Error handling

- **Returns** mirror D3DMetal's (§2.2). Anything outside the covered calls keeps today's behaviour.
- **No new aborts:** nothing in this spec adds an `IMPLEMENT_ME` path.
- **Copies:** a copy between incompatible formats warns once per format pair and is skipped, which is D3D12's undefined case.
- **Timestamps:** without counter sampling (not seen on Apple Silicon), they resolve to zeros with frequency 1, as today.

## 5. Tests

MacNeutron's `dxmt/tests` gain the following. Each prints lines that `check.sh` compares between our DXMT and D3DMetal, unless marked otherwise. Shaders are compiled by `compile.sh` and committed.

1. **`d3d12_api`: batch 1's calls.**
   - `CheckFeatureSupport` return codes for every query in §2.2.
   - `CreateCommandList1` (closed, resets), `CreateHeap1`.
   - Residency, and `EnqueueMakeResident`'s fence.
   - `SetEventOnMultipleFenceCompletion`, ANY and ALL, with fences done and not yet done.
   - `GetCachedBlob` and its blob accepted back.
   - The pipeline library sequence of §2.2, printing sizes only as nonzero.
   - A command list with event markers that executes.
   - A draw with a depth view whose texture is gone, which finishes.
   
   **Ours only:** the capabilities claim none of the features the fork lacks (OPTIONS5 raytracing tier, OPTIONS7 mesh shader tier, OPTIONS6 VRS tier, sampler feedback all absent).
2. **`d3d12_depth`, extended.** A depth-read-only view (stencil writable) and a stencil-read-only view, each under a pipeline that writes both: the read-only plane is unchanged. Pixels are compared.
3. **`d3d12_copy`.** Reinterpreting copies through `CopyResource` and `CopyTextureRegion`, read back byte for byte:
   - RGBA8 UNORM → sRGB;
   - R32 typeless → FLOAT;
   - R32G32_UINT → BC1;
   - R32G32B32A32_UINT → BC3 and → BC7;
   - BC1 → R32G32_UINT;
   - D32 → R32.
4. **`d3d12_null`.** A compute shader reads every null SRV type (typed, structured and raw buffers; 1D, 1D array, 2D, 2D array, multisample, 3D, cube, cube array), writes through null UAVs and queries their dimensions. The values are compared.
5. **`d3d12_timestamp` (ours only: D3D12's rules, as D3DMetal has no timestamps).**
   - The frequency is above 0.
   - Timestamps increase across a command list and across two command lists.
   - The one after 200 full-screen draws of a 1024×1024 target is later than the one before.
   - Each lies between two `GetClockCalibration` GPU readings taken around the submission.
   - A timestamp between two draws leaves their pass as one render pass: the pass dump counts one.
6. **Regression.** Every existing check stays green. SMITE 2, in capture mode on our DXMT, renders its lobby, and its game and MacNeutron logs have no `unhandled feature` or `is not implemented` lines.

## 6. Delivery

- **Fork commits** on `macneutron`, one per item or closely related group, each with its test. Pushed, then `dxmt/pins` updated.
- **MacNeutron:** one commit per batch with its tests, on a branch cut from the current `feat/dxil-translator` head.
- **Verification:** `make dxmt-check` green before each MacNeutron commit.

## 7. Acceptance

1. **Tests:** `make dxmt-check` passes with §5's tests: every D3DMetal comparison matches, and every rule in §5.1 (ours only) and §5.5 holds.
2. **SMITE 2 on our DXMT (the maintainer's run):**
   - reaches the lobby, which renders as on D3DMetal;
   - plays a match;
   - leaves no `unhandled feature` or `is not implemented` line in the game log or MacNeutron's log.
3. **Records:** the SDD ledger lists each ruling, and `docs/testing/acceptance-dxmt-d3d12-stubs.md` records the run.
