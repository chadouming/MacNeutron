# MacNeutron: XeSS answered by MetalFX

Status: approved by the maintainer (2026-10-05).

## 1. Goal

When a game asks for Intel XeSS on MacNeutron's arm64 runtime, it gets fast upscaling from Apple's MetalFX temporal
upscaler, silently, under XeSS's own name. The game's XeSS option works and costs a few milliseconds per frame
instead of ~250.

## 2. Why, and what we measured

- XeSS's non-Intel path runs Intel's int8 network as DP4a instructions. Apple GPUs have none; DXMT's airconv emulates
  each one (`src/airconv/dxil/dxil_lower_math.cpp`). SMITE 2 with XeSS: ~3.8 FPS, ~250 ms of GPU compute per frame,
  the same on DXMT, Rosetta+DXMT and D3DMetal.
- Task X1 (Wine patch 0022) made XeSS report "unsupported" so games fall back (SMITE 2: FSR 3, 60 FPS lobby on the
  game's defaults, against 4.1 with XeSS).
- Spike, M5 Pro, 2560x1440 output (`.superpowers/sdd/…/xess-spike-result.json`):
  - MetalFX temporal upscaler GPU time per frame: 2.96 ms at 1.0x (anti-aliasing only), 2.26 at 1.5x (from 1707x960),
    2.13 at 1.7x (1506x848), 1.99 at 2.0x (1280x720), 1.83 at 3.0x (854x480). The device's range is 1.0x-3.0x. The reactive mask, macOS 27's motion-vector options and
    Metal 4's variant change it by 0.2 ms or less.
  - A fixed ~2.2 ms passes between commit and the upscale's GPU start (probably the Neural Engine); serialized, a frame
    holds the queue 4.2-5.8 ms. Whether a game's other GPU work overlaps it is measured in-game (§6).
  - Creation ~13 ms warm (~45 ms first in a process); 220-290 MB of GPU memory per upscaler at 1440p.
  - Conventions validated by PSNR: MetalFX `jitterOffset` = −(the game's sample offset); motion vectors = −velocity in
    pixels of the motion texture; with `jitteredMotionVectorsEnabled`, vectors include +(jitter now − jitter before).
  - Running Intel's own network on the M5's tensor hardware was ruled out: per-instruction DP4a is already ~87 % of the
    GPU's integer ceiling, and tensor operations (≈31 TMAC/s int8) help only if XeSS's layers are rewritten, which
    means re-implementing Intel's proprietary model.

## 3. Decisions (maintainer, 2026-10-05)

- XeSS only. FSR, DLSS and frame generation (XeFG, XeLL) are out; the DXMT interface stays API-neutral so they can be
  added later without rework.
- The bridge replaces XeSS by default ("silently replace XeSS: it's useless at 250 ms/frame"). `MACNEUTRON_XESS=1`
  loads Intel's real XeSS for debugging or comparison.
- No A/B against FSR. The bridge is measured on its own and judged by the maintainer's eyes.
- Approach: implement XeSS's public API on MetalFX (no Intel code, weights or shaders).

## 4. Architecture

1. **DXMT patch 0004: a private D3D12 interface** (precedent: DXMT's D3D11 DLSS bridge, `src/nvngx/`,
   `IMTLD3D11ContextExt::TemporalUpscale`).
   - `IMTLD3D12DeviceExt` (QueryInterface on the device, a private IID): the supported scale range, and a factory for a
     COM-wrapped MetalFX temporal upscaler created from a description (input and output sizes, formats, flags).
   - `IMTLD3D12CommandListExt::TemporalUpscale(scaler, inputs)`: records an upscale into the game's own command list as
     a new encoder type (after `ResolveSubresource`'s pattern). At `ExecuteCommandLists` DXMT encodes it into its
     `MTLCommandBuffer` in order with the game's work, fenced like DXMT's other hazard-untracked texture use; the new
     type gets its `Reset()` case, its stats slot and its pass-dump name.
   - winemetal's temporal-scaler structs gain, appended: the reactive mask, `outputResolutionMotionVectorsEnabled`,
     `jitteredMotionVectorsEnabled`, input content offsets, and a min/max-scale query; the hardcoded 1.0/3.0 and the
     synchronous-only creation go.
2. **The bridge: X1's builtin `libxess.dll` grows real code** (Wine patch series). It must stay a Wine builtin: the
   game loads XeSS by full path, and only Wine's prefer-builtin override replaces a full-path load. It carries a small
   header matching DXMT's private interface.
   - Real: the 9 functions SMITE 2's Unreal plugin resolves — `xessGetVersion`, `xessGetIntelXeFXVersion`,
     `xessGetOptimalInputResolution`, `xessDestroyContext`, `xessSetLoggingCallback`, `xessD3D12CreateContext`,
     `xessD3D12Init`, `xessD3D12BuildPipelines`, `xessD3D12Execute` — plus the setters Unreal may call later
     (`xessSetJitterScale`, `xessSetVelocityScale`, `xessGetProperties` if cheap). The other exports stay X1's stubs.
     `libxess_dx11.dll` stays X1's stub (Intel-only on D3D11; no D3D11 XeSS game is in scope).
   - No DXMT interface (Wine's `wined3d`): "unsupported", as X1 does now.
3. **The launcher**: unchanged default (`libxess,libxess_dx11=b`, now the bridge); `MACNEUTRON_XESS=1` keeps Intel's
   XeSS.

## 5. Per frame

- `xessD3D12CreateContext(device)`: QueryInterface for `IMTLD3D12DeviceExt`; a context with its own lock (Unreal may
  call from its render and RHI threads).
- `xessD3D12Init(params)`: records output size, quality mode and flags (HDR, inverted depth, NDC or pixel velocity,
  high-res or render-res motion vectors, jittered motion vectors, exposure texture or auto exposure, responsive mask)
  and creates one MetalFX upscaler for the context. `xessD3D12BuildPipelines` returns success at once.
- `xessGetOptimalInputResolution(output, mode)`: XeSS 2.x's ratio per mode — Native AA 1.0, Ultra Quality Plus 1.3,
  Ultra Quality 1.5, Quality 1.7, Balanced 2.0, Performance 2.3, Ultra Performance 3.0 (from general knowledge;
  confirmed by §9 question 1 or the logging run) — within the device's 1.0x-3.0x; min and max as XeSS reports them.
- `xessD3D12Execute(ctx, commandList, params)`: converts colour, depth, motion vectors, exposure and responsive-mask
  textures, jitter (times the jitter scale), velocity scale, input size and reset into MetalFX's terms (§2's
  conventions; inverted depth → `depthReversed`; NDC velocity scaled to pixels), and records one
  `TemporalUpscale` into the command list.
- A size or flag change recreates the upscaler (~13 ms); `xessDestroyContext` frees it.
- **First implementation step: a logging run.** The bridge logs, once, the exact `xessD3D12Init` flags and
  `xessD3D12Execute` parameters (formats, sizes, jitter, scales, which textures are present) from SMITE 2, before any
  pixel is trusted. That settles units and signs from observed calls.

## 6. Errors and edge cases

- A texture MetalFX can't take directly (a depth/stencil format, a packed colour format, an output without write
  usage): DXMT converts it into a scratch texture first and writes the output back; a supported mode never fails.
- A bad call (size outside 1.0x-3.0x, a missing required texture, an unknown flag): Execute returns XeSS's error code
  without encoding anything, logged once to the game log. Never a crash. Init checks the device and the scale range;
  the upscaler itself is made at the first Execute, from the formats the game really passes (amended 2026-10-06:
  Unreal's Init can't tell the bridge its formats, so an Init-time upscaler was a wasted ~230 MB). A failed creation
  fails each Execute, logged once, instead of Init.
- History lives per context; it resets when the game passes reset or the size changes.
- One upscaler per context (~220-290 MB at 1440p).
- **The 2.2 ms wait:** the upscale is encoded inline first (ordering first). Measured in SMITE 2 with a Metal System
  Trace: if the GPU idles ≥ 1 ms per frame because of it, DXMT ends its command buffer right after the upscale, so the
  upscale is submitted on its own and later work isn't held behind it.

## 7. Testing and shipping

Automated, no game:
- A D3D12 test program (x64, DXMT's test tree) renders synthetic jittered frames, loads `libxess.dll` by path and
  drives it through XeSS's API like Unreal: every quality mode beats bilinear on the spike's PSNR measure;
  create/destroy, resize and reset cycles; history fresh after reset; "unsupported" under `wined3d`; Metal's
  validation layer clean. It runs in `dxmt/check.sh`'s x64 lane.
- Launcher unit tests for `MACNEUTRON_XESS=1`.
- The usual gates: `make test`, smoke, DXMT checks, bridge check, the patch series applying from a fresh checkout.

In SMITE 2 (scratch prefix, the maintainer's settings, Steam bridge on, lobby or practice only):
1. The logging run (§5).
2. Measurements at the maintainer's output size (2560x1440 on the external display): the upscale's GPU ms per frame
   and the wait's effect (Metal System Trace), lobby FPS, XeSS start-up time.
3. Captures of a practice map with the bridge, from a session the maintainer drives, for the maintainer to judge.

Ships as the default when: the upscale costs ≤ 5 ms of GPU time per frame at 1440p and the wait is handled (§6);
the maintainer sees no defect they reject (ghosting, shimmer, wrong jitter) in captures and in a short practice match
they play themselves; a 30-minute practice-mode soak shows no crash or memory growth; every gate passes.

## 8. Risks

- **XeSS's struct layouts and constants:** no XeSS header is on disk; X1's values came from memory. A wrong offset in
  the execute parameters reads garbage pointers. Mitigation: the logging run's raw parameter dumps, checked against
  Unreal's plugin behaviour; or Intel's public header if the maintainer allows reading it (§9).
- **Conventions:** jitter/velocity signs and units, exposure, reactive-mask meaning — wrong ones show as ghosting or
  shimmer, not crashes. The logging run and the captures catch them.
- **The 2.2 ms wait** may cost more in a real frame than in the spike; §6's trigger handles it.
- **Anti-cheat:** a non-Intel `libxess.dll` in a game with active anti-cheat is untested (X1 has the same exposure).
  SMITE 2's Steam launch passes `-NOEAC`.
- **Upstream:** DXMT doesn't take AI-written changes; patch 0004 stays in our series.

## 9. Answers from the maintainer (2026-10-05)

1. The implementation reads Intel's public `xess.h` and its licence (GitHub, read-only) for exact struct layouts and
   constants, licence checked first; the logging run (§5) still confirms them against SMITE 2's real calls.
2. Quality captures use a practice map only (motion and particles matter most for temporal upscaling). A practice
   match needs input in the game's menus, so captures come from a session the maintainer drives (their own practice
   match, §7), taken with the presenter's frame dump or a screen capture.

## 10. Out of scope

Frame generation (XeFG, XeLL; SMITE 2 ships both, and they still load), FSR and DLSS, XeSS on D3D11, Metal 4 command
buffers, running Intel's network on tensor hardware.
