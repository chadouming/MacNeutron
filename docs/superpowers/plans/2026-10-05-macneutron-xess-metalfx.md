# XeSS Answered by MetalFX — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A game's XeSS calls on MacNeutron's arm64 runtime run MetalFX's temporal upscaler, silently, at a few ms per
frame instead of ~250.

**Architecture:** DXMT patch 0004 gives D3D12 a private interface (device: scale range + upscaler factory; command
list: `TemporalUpscale`) that records a fenced MetalFX encode into the game's command stream, reusing
`dxmt::TemporalScaler` and winemetal's temporal-scaler calls (extended). Wine patch 0024 turns X1's builtin
`libxess.dll` into a real XeSS implementation on that interface. The launcher keeps `libxess,libxess_dx11=b`; the
bridge is the default, `MACNEUTRON_XESS=1` keeps Intel's XeSS.

**Tech stack:** DXMT (C++20, meson, winemetal PE↔unix calls), Wine builtin DLL (C, .spec), MetalFX (macOS 27 SDK),
D3D12 test programs (llvm-mingw, `dxmt/tests`), `dxmt/check.sh`, Swift launcher.

**Spec:** `docs/superpowers/specs/2026-10-05-macneutron-xess-metalfx-design.md`. Code map with exact lines:
`.superpowers/sdd/2026-10-04-macneutron-arm64-release/xess-map/*.md` (read the file for your task's area).

## Global Constraints

- XeSS on D3D12 only. No FSR, DLSS, frame generation (XeFG, XeLL), XeSS on D3D11 (`libxess_dx11` keeps X1's stubs),
  Metal 4 command buffers, tensor-hardware work.
- No Intel code, binaries, weights or shaders. XeSS declarations are copied only from `github.com/intel/xess` branch
  `main` (`inc/xess/xess.h`, `xess_d3d12.h`; MIT since commit de0fb9c), keeping Intel's MIT notice — never from a
  release tag (those headers are proprietary). Read the licence before copying.
- Default: the bridge answers XeSS. `MACNEUTRON_XESS=1` loads the game's own Intel XeSS. Without DXMT's interface
  (Wine's `wined3d`), `xessD3D12CreateContext` returns `XESS_RESULT_ERROR_UNSUPPORTED_DEVICE` (-1) with a NULL context.
- Never crash on a bad call: return the `xess.h` error code, encode nothing, log once (`WARN`/`ERR` behind a once-flag;
  TRACE is never on in the launcher's logging mode).
- One MetalFX upscaler per XeSS context; a per-context lock; the encoder data keeps the upscaler alive until the
  command allocator is reset.
- DXMT's translator key must not change: the new header goes in `src/d3d12/d3d12_interfaces.hpp`; no meson option, no
  `include/` change, no `airconv_thunks.*` change. Check `build/wine-arm64-src/dxmt-install/translator` before/after.
- Patch series: add commits (DXMT 0004, Wine 0024); never rewrite an exported patch; export with
  `make wine-arm64-export`; afterwards `git status` shows only the new patch files; prove each series applies from a
  fresh fetch (`.superpowers/sdd/…/xess-map/x1-and-patch-workflow.md` §6).
- winemetal: append struct fields at the end; a new unix call is index 150 in both `__wine_unix_call_funcs` and
  `__wine_unix_call_wow64_funcs`; Info/Props hold only `uint32_t`/`float`/`bool`/enum.
- Builds need `MACNEUTRON_SIGN_IDENTITY="Developer ID Application: Chad Cormier Roussel (49QMZXLR8S)"
  MACNEUTRON_PROVISIONING_PROFILE="$HOME/Downloads/Mac_Neutron.provisionprofile"`. Game runs launch under `env -i`
  (HOME, USER, LOGNAME, PATH, TMPDIR, LANG + the run's variables) through a scratch tool folder made by
  `.build/release/macneutron install … --steam-exe build/bridge/arm64/steam.exe`; Steam bridge on; lobby only; never
  touch `~/Library/Application Support/MacNeutron/`, SMITE 2's install or `steamapps/compatdata/`; stop runs with
  `wineserver -k`/`-w` (WINEMSYNC=1) and an empty `lsof -t`.
- Never push, tag, `gh`, notarize; never open a built MacNeutron.app; commits end with the model's Co-Authored-By line.
- Upstream DXMT doesn't take AI-written changes: 0004 stays in our series.

## Review Focus

1. **The game re-initialises XeSS** (resolution or quality change, XeSS toggled off and on): `xessD3D12Init` runs again
   on a live context; the old upscaler is released (no 220-290 MB leak per change) and the next Execute uses a new one.
   Test: `d3d12_xess` mode `cycles` (Task 2).
2. **Destroy right after Execute** (game shutdown, toggling XeSS): the command list still references the upscaler until
   the allocator resets. Test: `cycles` destroys the context before `Submit` and checks the output (Task 2).
3. **Inputs MetalFX can't take directly**: a `D32_FLOAT_S8X24`/`D24_UNORM_S8_UINT` depth, an output without UAV
   (render-target only). Test: `d3d12_upscale` modes `depthstencil` and `rtoutput` (Task 1).
4. **XeSS recorded on a COMPUTE command list** (async compute): works like DIRECT. Test: `d3d12_upscale` mode
   `compute` (Task 1).
5. **Init flags beyond the mapped ones**: bit 5 (`EXTERNAL_DESCRIPTOR_HEAP`) and bit 30 (`XESS_DEBUG_ENABLE_PROFILING`)
   accepted; any other unknown bit → `XESS_RESULT_ERROR_INVALID_ARGUMENT`. Test: `d3d12_xess` mode `flags` (Task 2).

---

### Task 1: DXMT patch 0004 — D3D12 temporal upscale interface

**Files** (DXMT tree `build/wine-arm64-src/dxmt`, branch `macneutron`, new commit; exported to
`wine-arm64/patches/dxmt/0004-*.patch`):
- Modify: `src/winemetal/winemetal.h` (Info/Props fields, new call decl), `src/winemetal/winemetal_thunks.h`,
  `src/winemetal/winemetal_thunks.c`, `src/winemetal/unix/winemetal_unix.c`, `src/winemetal/Metal.hpp`
- Modify: `src/d3d11/d3d11_context_impl.cpp:5258` (`WMTFXTemporalScalerInfo info{};` only)
- Create: `src/d3d12/d3d12_interfaces.hpp`
- Modify: `src/d3d12/d3d12_device.cpp` (ext + scaler object), `src/d3d12/d3d12_command_list.cpp`,
  `src/d3d12/d3d12_command_encoder.hpp`, `src/d3d12/d3d12_command_queue.cpp`, `src/d3d12/d3d12_command_allocator.cpp`
- Create (repo): `dxmt/tests/d3d12_upscale.cpp`; Modify: `dxmt/check.sh` (lane E rows)
- Modify (repo): `wine-arm64/README.md` (Licences: DXMT 0001-0004 are ours)

**Interfaces — Produces** (`src/d3d12/d3d12_interfaces.hpp`; plain POD; fresh GUIDs from `uuidgen`, written as
strings; vtable order is ABI — Task 2 copies it):
```cpp
struct MTL_TEMPORAL_SCALER_D3D12_DESC {
  UINT InputWidth, InputHeight;          // the colour/depth/motion textures' size
  UINT OutputWidth, OutputHeight;
  DXGI_FORMAT ColorFormat, DepthFormat, MotionFormat, OutputFormat;
  DXGI_FORMAT ReactiveMaskFormat;        // DXGI_FORMAT_UNKNOWN: no reactive mask
  BOOL AutoExposure, OutputResolutionMotionVectors, JitteredMotionVectors;
  FLOAT InputContentMinScale, InputContentMaxScale;
};
struct MTL_TEMPORAL_UPSCALE_D3D12_DESC {
  ID3D12Resource *Color, *Depth, *MotionVector, *Exposure /*may be null*/, *ReactiveMask /*may be null*/, *Output;
  UINT InputContentWidth, InputContentHeight;
  UINT ColorOffsetX, ColorOffsetY, DepthOffsetX, DepthOffsetY, MotionOffsetX, MotionOffsetY,
       ReactiveOffsetX, ReactiveOffsetY, OutputOffsetX, OutputOffsetY;
  FLOAT JitterOffsetX, JitterOffsetY, MotionVectorScaleX, MotionVectorScaleY, PreExposure;
  BOOL Reset, DepthReversed;
};
DEFINE_COM_INTERFACE("<uuid>", IMTLD3D12TemporalScaler) : public IUnknown {};
DEFINE_COM_INTERFACE("<uuid>", IMTLD3D12DeviceExt) : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE GetTemporalScalerScaleRange(FLOAT *pMin, FLOAT *pMax) = 0;
  virtual HRESULT STDMETHODCALLTYPE CreateTemporalScaler(const MTL_TEMPORAL_SCALER_D3D12_DESC *pDesc,
                                                         IMTLD3D12TemporalScaler **ppScaler) = 0;
};
DEFINE_COM_INTERFACE("<uuid>", IMTLD3D12CommandListExt) : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE TemporalUpscale(IMTLD3D12TemporalScaler *pScaler,
                                                    const MTL_TEMPORAL_UPSCALE_D3D12_DESC *pDesc) = 0;
};
```
Return codes: `S_OK`; `E_INVALIDARG` for a null/mismatched resource, a size outside the range, an unsupported
format; `E_OUTOFMEMORY` when MetalFX returns no upscaler; `DXGI_ERROR_UNSUPPORTED` when the device has no MetalFX
temporal scaler (QueryInterface for `IMTLD3D12DeviceExt` itself fails then).

- [ ] **Step 1: Write the failing test** `dxmt/tests/d3d12_upscale.cpp` (one mode per run, like `d3d12_hazards.cpp`;
  frames generated on the CPU and uploaded, no new `.dxil`; its own copy of the interface declarations). For each
  mode it renders 64 frames of moving synthetic content with Halton jitter at the input size, upscales to 2560x1440,
  reads back the last output and prints one line. Modes and lines:
  - `ratio <r>` for r in 1.5, 2.0, 3.0: `upscale ratio <r> ok psnr <scaler> bilinear <bilinear>`, scaler > bilinear
    (the spike's PSNR method against the unjittered full-size ground truth; conventions: `JitterOffset` = −sample
    offset, motion vectors = −velocity in motion-texture pixels).
  - `depthstencil` (depth `DXGI_FORMAT_D32_FLOAT_S8X24_UINT`), `rtoutput` (output with
    `ALLOW_RENDER_TARGET` only), `compute` (recorded on a `D3D12_COMMAND_LIST_TYPE_COMPUTE` list):
    `upscale <mode> ok psnr …`.
  - `bad`: a null output, then a 4.0x input: both `TemporalUpscale` return `E_INVALIDARG`; then a valid upscale on
    the same list works: `upscale bad ok`.
  - `range`: `GetTemporalScalerScaleRange` prints `range 1.000 3.000`.
- [ ] **Step 2: Run it to see it fail.** `make dxmt-tests && sh dxmt/check.sh` after adding lane E rows (check.sh
  lane E, before `exit $fail`): `run ours upscale-<mode> dxmt "$TESTS/d3d12_upscale.exe" <mode>` and
  `expect "DXMT upscales <mode>" "$(…grep '^upscale <mode> ok' …)" yes`, plus a validation row
  (`MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=nslog`, `expect "Metal's validation rejects nothing in the upscale"
  "$(invalid upscale-val)" 0`). Expected: FAIL (QueryInterface for `IMTLD3D12DeviceExt` fails).
- [ ] **Step 3: winemetal.** Append to `WMTFXTemporalScalerInfo`: `bool reactive_mask_enabled; enum WMTPixelFormat
  reactive_mask_format; bool output_resolution_motion_vectors; bool jittered_motion_vectors;`. Append to
  `WMTFXTemporalScalerProps`: ten `uint32_t` content offsets (colour, depth, motion, reactive, output; x then y).
  Append `obj_handle_t reactive_mask;` to `struct unixcall_mtlcommandbuffer_temporal_scale`, and extend
  `MTLCommandBuffer_encodeTemporalScale`/`CommandBuffer::encodeTemporalScale` with a trailing `reactive_mask` handle.
  New call 150: `WINEMETAL_API void MTLDevice_temporalScalerScaleRange(obj_handle_t device, float *min, float *max);`
  (`struct unixcall_mtldevice_fxtemporalscaler_scale { obj_handle_t device; float min_scale; float max_scale; }`,
  `+supportedInputContentMinScaleForDevice:`/`MaxScale…`), `Device::temporalScalerScaleRange(float&, float&)`.
  The unix side sets the new descriptor properties and the scaler's `reactiveMaskTexture` and `*ContentOffsetX/Y`
  (macOS 27 APIs; the deployment target is 27.0). D3D11's `info` gets `{}`.
- [ ] **Step 4: The device ext and the upscaler object** in `d3d12_device.cpp`: `MTLD3D12DeviceImpl` gains
  `IMTLD3D12DeviceExt` (QueryInterface succeeds only if `GetMTLDevice().supportsFXTemporalScaler()`).
  `CreateTemporalScaler` validates, maps DXGI→Metal formats (depth/stencil formats map to `Depth32Float`, which the
  conversion in Step 6 produces), fills `WMTFXTemporalScalerInfo` (min/max from the desc, clamped to the device's range;
  `input_content_properties_enabled = true`; `requires_synchronous_initialization = false`), creates
  `Rc<TemporalScaler>`, and returns `E_OUTOFMEMORY` if `!scaler->scaler()`. The object is a standalone
  `ComObject<IMTLD3D12TemporalScaler>` (pattern `d3d10/d3d10_blob.cpp:7`) holding the `Rc` and its desc.
- [ ] **Step 5: The command list** gains `IMTLD3D12CommandListExt`. `TemporalUpscale` validates everything first
  (textures non-null and `MTLD3D12Resource::texture` set; sizes match the upscaler's desc; content size within its
  scale range; formats equal to the desc's) and returns `E_INVALIDARG` before any `AllocatePass`. Then:
  `allocator_->InvalidateCurrentPass(); auto e = allocator_->AllocatePass<TemporalUpscaleEncoderData>();
  e->type = EncoderType::TemporalUpscale;` fill views and props, `allocator_->InvalidateCurrentPass();`.
  `struct TemporalUpscaleEncoderData : EncoderData { Rc<TemporalScaler> scaler; TextureViewRef color, depth, motion,
  exposure, reactive, output; Rc<Texture> depth_scratch, output_scratch; WMTFXTemporalScalerProps props; };`
  (`d3d12_command_encoder.hpp`; `EncoderType::TemporalUpscale` appended after `Resolve`; never include
  `dxmt/dxmt_context.hpp`).
- [ ] **Step 6: Conversions.** A depth/stencil depth: copy to a scratch `Depth32Float` texture owned by the encoder
  data (texture → temp buffer with `WMTBlitOptionDepthFromDepthStencil` → texture; pattern
  `d3d12_command_list.cpp:843-872`). An output without `ShaderWrite`/`RenderTarget` usage: upscale into a scratch output,
  then blit it to the real output. Motion vectors in a format MetalFX can't read: copy to `RG16Float`/`RG32Float`
  scratch (no reinterpreting views — lossless compression breaks them).
- [ ] **Step 7: The queue** (`d3d12_command_queue.cpp`): a `case EncoderType::TemporalUpscale:` that does
  `FlushPending(cmdbuf)`, `Order(current, strict)`, a blit encoder that waits `waits_`, runs the scratch copies and
  `updateFence(scaler->fence())`, then `cmdbuf.encodeTemporalScale(…, scaler->fence(), props, reactive)`, then a blit
  encoder that waits `scaler->fence()`, runs the output write-back copy, and `updateFence(fences_[fence])` (pattern
  `dxmt/dxmt_context.cpp:1195-1215`). If the validation layer shows an empty fence-only encoder dropped, add the 4-byte
  fill of `SampleAfter`. Append `StatId("#temporal upscale passes")` to `kinds[]` and `"upscale"` to `DumpPass`'s names
  (guard `< 7`). `d3d12_command_allocator.cpp` `Reset()`: a case running `~TemporalUpscaleEncoderData()`.
- [ ] **Step 8: Run the tests.** `make wine-arm64` (dev build), `make dxmt-tests`, `sh dxmt/check.sh`: every
  `upscale` row ok, the validation row 0, the rest of check.sh unchanged (`dxmt-check: all passed`).
  `dxmt-install/translator` equals its value before the change.
- [ ] **Step 9: Commit and export.** DXMT commit `d3d12: Add a private MetalFX temporal upscale interface.`;
  `make wine-arm64-export` (only `patches/dxmt/0004-*.patch` new); applied build; repo commit (patch, test,
  check.sh, README); rebuild → `wine-arm64: up to date`; fresh-fetch proof for DXMT (4 of 4 apply, trees equal).

### Task 2: Wine patch 0024 — the XeSS bridge

**Files** (Wine tree `build/wine-arm64-src/wine`, branch `macneutron`, new commit; exported to
`wine-arm64/patches/wine/0024-*.patch`):
- Create: `dlls/libxess/xess.h` (declarations copied from intel/xess `main`, with Intel's MIT notice: the result,
  quality, init-flag, logging enums; `xess_version_t`, `xess_2d_t`, `xess_properties_t`, `xess_app_log_callback_t`,
  `xess_d3d12_init_params_t`, `xess_d3d12_execute_params_t`), `dlls/libxess/dxmt_d3d12_ext.h` (C copy of Task 1's
  interface: `DEFINE_GUID`s, `DECLARE_INTERFACE_`, POD structs; pattern `dlls/ddrawex/ddrawex_private.h:21-45`),
  `dlls/libxess/d3d12.c`
- Modify: `dlls/libxess/Makefile.in` (`SOURCES = main.c d3d12.c`), `dlls/libxess/libxess.spec`
- Create (repo): `dxmt/tests/d3d12_xess.cpp`; Modify: `dxmt/check.sh` (lane E rows),
  `Sources/MacNeutronCore/LaunchEnvironment.swift` (comment), `Tests/MacNeutronCoreTests/LaunchEnvironmentTests.swift`
  (rename `xessStandInsAreTheDefaultUnlessOptedOut` → `xessBridgeIsTheDefaultUnlessOptedOut`), `README.md`
  (`MACNEUTRON_XESS=1` row), `wine-arm64/README.md` (Licences: 0024 ours), `docs/testing/acceptance-arm64-release.md`

**Interfaces — Consumes:** Task 1's `IMTLD3D12DeviceExt`, `IMTLD3D12CommandListExt`, `IMTLD3D12TemporalScaler`,
the two desc structs, exact GUIDs and method order.
**Produces** (spec lines; internal names so `main.c`'s symbols stay for `libxess_dx11`; line order unchanged):
```
@ cdecl xessD3D12CreateContext(ptr ptr) d3d12_create_context
@ cdecl xessD3D12BuildPipelines(ptr ptr long long) d3d12_build_pipelines
@ cdecl xessD3D12Init(ptr ptr) d3d12_init
@ cdecl xessD3D12GetInitParams(ptr ptr) d3d12_get_init_params
@ cdecl xessD3D12Execute(ptr ptr ptr) d3d12_execute
@ cdecl xessDestroyContext(ptr) d3d12_destroy_context
@ cdecl xessGetOptimalInputResolution(ptr ptr long ptr ptr ptr) d3d12_get_optimal_input_resolution
@ cdecl xessGetInputResolution(ptr ptr long ptr) d3d12_get_input_resolution
@ cdecl xessGetIntelXeFXVersion(ptr ptr) d3d12_get_xefx_version
@ cdecl xessSetLoggingCallback(ptr long ptr) d3d12_set_logging_callback
@ cdecl xessSetJitterScale(ptr float float) d3d12_set_jitter_scale
@ cdecl xessSetVelocityScale(ptr float float) d3d12_set_velocity_scale
@ cdecl xessGetJitterScale(ptr ptr ptr) d3d12_get_jitter_scale
@ cdecl xessGetVelocityScale(ptr ptr ptr) d3d12_get_velocity_scale
@ cdecl xessGetProperties(ptr ptr ptr) d3d12_get_properties
@ cdecl xessIsOptimalDriver(ptr) d3d12_is_optimal_driver
@ cdecl xessGetPipelineBuildStatus(ptr) d3d12_get_pipeline_build_status
```
`d3d12_destroy_context` also accepts a NULL handle (SUCCESS) like X1's `xessDestroyContext`, which stays in `main.c`
for `libxess_dx11`.

- [ ] **Step 1: Read Intel's licence and headers** (read-only, `gh api` raw): `LICENSE.txt`, `inc/MIT.txt` and
  `inc/xess/{xess.h,xess_d3d12.h}` on `main`; confirm the MIT notice and copy only the declarations listed above. If
  the Developer Guide 2.0's ratio table is readable the same way, use it; otherwise the ratios below.
- [ ] **Step 2: Write the failing test** `dxmt/tests/d3d12_xess.cpp`: `LoadLibraryA(argv[1])` with a full path, the
  game's way (check.sh passes `Z:$WORK/xess/libxess.dll`, a copy of `d3d12_xess.exe` under that name: a valid PE that
  isn't XeSS, so the row fails unless the launcher's `libxess=b` makes Wine load the builtin instead), `GetProcAddress` for the functions above, then per mode:
  - `mode <m>` for m in `aa`, `quality`, `balanced`, `performance`, `ultraperf`: CreateContext, GetOptimalInputResolution
    for 2560x1440 (prints `xess <m> input <w>x<h>`), BuildPipelines (SUCCESS at once), Init, 64 Execute frames as in
    Task 1's test, readback → `xess <m> ok psnr <s> bilinear <b>` with s > b.
  - `cycles`: Init twice with different output sizes; Execute; DestroyContext before `Submit`, then Submit and read the
    output (valid); 20 create/destroy cycles; reset history (`resetHistory=1`) then 1 frame gives a PSNR close to
    bilinear (fresh history) → `xess cycles ok`.
  - `flags`: Init with bits 5 and 30 set → SUCCESS; with bit 9 → `XESS_RESULT_ERROR_INVALID_ARGUMENT` (-4);
    GetIntelXeFXVersion → 0.0.0 SUCCESS; GetVersion → 2.0.1; a stale handle → -8 → `xess flags ok`.
  - `unsupported` (run with backend `wined3d`): CreateContext → -1 and NULL → `xess unsupported ok`.
  check.sh lane E: `run ours xess-<m> dxmt "$TESTS/d3d12_xess.exe" "Z:$WORK/xess/libxess.dll" <m>` with `expect` rows, one validation
  row, and `run ours xess-wd wined3d … unsupported`. Run: FAIL (X1 returns -1).
- [ ] **Step 3: `d3d12.c`.** Context: `struct xess_d3d12 { DWORD magic; SRWLOCK lock; IMTLD3D12DeviceExt *ext;
  xess_d3d12_init_params_t init; BOOL initialized, built; float jitter_x, jitter_y, velocity_x, velocity_y;
  IMTLD3D12TemporalScaler *scaler; MTL_TEMPORAL_SCALER_D3D12_DESC scaler_desc; xess_app_log_callback_t log;
  xess_logging_level_t log_level; }`; contexts live in a list guarded by one lock so a stale handle is found, never
  dereferenced. Behaviour:
  - CreateContext: `ID3D12Device_QueryInterface(&IID_IMTLD3D12DeviceExt)`; failure → -1, NULL, one `WARN`.
  - Init: reject unknown bits (outside 0-8 and 30) with -4; store params; release any upscaler. XeSS's Init carries
    no texture formats, so Init creates the upscaler from the expected ones (input = the mode's optimal size, colour
    and output `R16G16B16A16_FLOAT`, depth `D32_FLOAT`, motion `R16G16_FLOAT`); if that fails, Init returns -5 and
    Unreal falls back to its own anti-aliasing (spec §6). Execute recreates it when the real textures differ.
    Bit 6 (LDR input) needs no MetalFX setting.
  - GetOptimalInputResolution / GetInputResolution: ratio per mode — AA 1.0, Ultra Quality Plus 1.3, Ultra Quality
    1.5, Quality 1.7, Balanced 2.0, Performance 2.3, Ultra Performance 3.0 (or the Developer Guide's table) — divided
    into the output, rounded down to even, keeping the output's aspect; min = output / 3.0, max = output; clamped to
    `GetTemporalScalerScaleRange`.
  - Execute: validate (initialized; colour, velocity, output non-null; depth non-null — MetalFX needs it; input size
    within the range) → -4 with one `WARN`. Create or recreate the upscaler when the textures' sizes or formats differ
    from `scaler_desc` (formats from `ID3D12Resource_GetDesc`; `ReactiveMaskFormat` from the mask or UNKNOWN;
    `AutoExposure` = flag bit 8; `OutputResolutionMotionVectors` = bit 0; `JitteredMotionVectors` = bit 7). Fill the
    upscale desc: `JitterOffset = -(jitterOffset × jitter scale)`; `MotionVectorScale = -velocity scale`, times
    (0.5 × motion texture width, −0.5 × motion texture height) when bit 4 (NDC velocity) is set; `DepthReversed` = bit 1;
    `PreExposure` = `exposureScale` (0 when the exposure texture is used, bit 2); offsets from the `*Base` fields;
    `Reset` = `resetHistory`. `ID3D12GraphicsCommandList_QueryInterface(&IID_IMTLD3D12CommandListExt)` →
    `TemporalUpscale` → map `E_INVALIDARG`→-4, `E_OUTOFMEMORY`→-5, other failures→-6.
  - The first Init and first Execute log their parameters once with `WARN` (flags, sizes, formats, jitter, scales,
    which textures are present) — Task 3 reads them.
  - GetIntelXeFXVersion → 0.0.0 SUCCESS; GetProperties → zeros SUCCESS; IsOptimalDriver → SUCCESS;
    GetPipelineBuildStatus → SUCCESS after BuildPipelines else `XESS_RESULT_ERROR_WRONG_CALL_ORDER`;
    SetLoggingCallback stores the callback (called for WARN-level events at or above its level).
  - `C_ASSERT(sizeof(xess_d3d12_execute_params_t) == 136); C_ASSERT(offsetof(xess_d3d12_execute_params_t,
    pDescriptorHeap) == 120); C_ASSERT(sizeof(xess_d3d12_init_params_t) == 64); C_ASSERT(sizeof(xess_properties_t) ==
    24);` and size asserts for the two DXMT desc structs matching Task 1's.
- [ ] **Step 4: Run the tests:** `make wine-arm64`, `make dxmt-tests`, `sh dxmt/check.sh` — every `xess` row ok,
  validation 0, `dxmt-check: all passed`; `make test` (the renamed launcher test passes unchanged in behaviour).
- [ ] **Step 5: Commit and export.** Wine commit `libxess: Answer XeSS on D3D12 with MetalFX through DXMT.`;
  `make wine-arm64-export` (only `patches/wine/0024-*.patch` new); applied build; repo commit (patch, test, check.sh,
  launcher comment, tests, READMEs, acceptance note); rebuild → up to date; fresh-fetch proof (Wine 24 of 24, DXMT 4 of
  4); `make smoke` 15/15; `make bridge-check`.

### Task 3: SMITE 2 — logging run, conventions and measurements

**Files:** Modify `dxmt/tools/gpu-trace.py` (a `--label SUBSTR` per-frame sum, or the MetalFX intervals by their own
labels found in the first trace); Modify `docs/testing/acceptance-arm64-release.md` (an "XeSS on MetalFX" section).
**Consumes:** Tasks 1-2 (dev `build/wine-arm64/wine.app`).

- [ ] **Step 1: Logging run.** A fresh scratch prefix (APFS clone of `scratchpad/sp5/perf/compat-x`, then set the
  game's upscaler to XeSS: the fresh-prefix default already is XeSS — use a fresh prefix if the clone keeps FSR),
  `MACNEUTRON_LOG=1`, lobby. Record from the game log the bridge's one-time Init/Execute lines (no IDs or names).
- [ ] **Step 2: Check the conventions** against the log: velocity units (pixels or NDC, bit 4), high-res motion
  vectors (bit 0), jittered motion vectors (bit 7), inverted depth (bit 1), exposure source (bits 2/8), texture formats,
  jitter range. If any mapping in Task 2 Step 3 disagrees with what Unreal passes, fix it in a new Wine commit (0025),
  re-run Task 2's tests and this step.
- [ ] **Step 3: Measure** at the maintainer's settings (2560x1440, the external display), 3 runs: the upscale's GPU ms
  per frame and the GPU idle per frame around it (`python3 dxmt/tools/gpu-trace.py <pid> 6`), lobby FPS
  (`scratchpad/sp5/perf/fps4.py`), XeSS init time (Hemingway.log, "XeSS successfully initialized" minus "Loading XeSS
  library"). Expected: upscale ≤ 5 ms; record the idle.
- [ ] **Step 4: Decide the split.** If GPU idle attributable to the upscale's commit→start wait is ≥ 1 ms per frame,
  Task 4 runs; otherwise record "no split needed" with the numbers. Commit the acceptance note.

### Task 4 (only if Task 3 Step 4 says so): split DXMT's command buffer after the upscale

**Files:** DXMT tree `src/d3d12/d3d12_command_queue.cpp` (new commit → DXMT patch 0005).
- [ ] **Step 1:** Re-measure Task 3 Step 3 as the baseline.
- [ ] **Step 2:** In `ExecuteCommandLists`, after encoding a `TemporalUpscale` case, `Commit()` the current
  `MTLCommandBuffer` and `Open()` a new one, re-binding `cmdbuf` and moving the owed timestamp resolves and signals
  (attached at `d3d12_command_queue.cpp:1222-1227`) to the final buffer; `fences_` keep their order across buffers.
- [ ] **Step 3:** `sh dxmt/check.sh` (all passed, upscale and xess rows ok, validation 0); re-measure Task 3 Step 3:
  GPU idle per frame drops by ≥ 1 ms, FPS not lower. Commit, export, applied build, fresh-fetch proof.

### Task 5: The maintainer's gate

**Consumes:** everything above, installed into a scratch tool folder the maintainer's session uses, or a re-cut build
(the controller decides with the maintainer).
- [ ] **Step 1:** The maintainer plays a short SMITE 2 practice match with XeSS (Balanced) on the bridge; captures of
  the practice map with `screencapture -l<window id>` (or the maintainer's own screenshots) at several moments of
  motion; the maintainer judges ghosting, shimmer and jitter.
- [ ] **Step 2:** A 30-minute practice-mode soak with the bridge: no crash; the game process's memory and the GPU's
  allocated size sampled every minute show no growth trend.
- [ ] **Step 3:** Record the verdict and numbers in the acceptance doc; spec status line "Implemented <date>" only if
  every ship criterion in spec §7 holds; otherwise record what failed and stop for the maintainer.
