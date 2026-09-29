# DXMT fork (sub-project 1) acceptance

Spec: `docs/superpowers/specs/2026-09-28-macneutron-dxmt-fork-design.md`.

## make dxmt-check, 2026-09-29

Fork commit `7579e39792732625569d07a03df1a73a70dd984b`, runtime-v4.7.3, GPTK 4.0b2, M5 Pro, macOS 27.

| Check | Result |
|---|---|
| 1. D3D11 `present_loop` 1280x720, 600 frames: ours vs DXMT 0.80 (best of 2) | 8.308 ms vs 8.306 ms |
| 2. `d3d12_clear` 300 frames | 300/300 presented, 8.372 ms; adapter Apple M5 Pro, shader model 0x51, binding tier 2 |
| 3. `d3d12_dxil` with `DXMT_DXIL_DUMP` | E_NOTIMPL x2; 3 shaders captured byte for byte; existing capture kept; unwritable folder ignored |
| 4. `present_loop` on D3DMetal | completes, 8.267 ms |
| 5. `dxil-probe` on the test shaders | see below |

In this run every result sat at the display's 120 Hz (8.3 ms) even with vsync off, so it compared pacing only. The
acceptance run below was not display-capped and compares throughput.

`dxil-probe` (LLVM 15.0.7):

```
ok compute.cs.dxil dxil=1.0 cs_6_0 entry=csmain ops=bufferLoad.f32:1,bufferStore.f32:1,createHandle:1,threadId.i32:1
ok triangle.ps.dxil dxil=1.0 ps_6_0 entry=psmain ops=storeOutput.f32:4,loadInput.f32:3
ok triangle.vs.dxil dxil=1.0 vs_6_0 entry=vsmain ops=storeOutput.f32:7,loadInput.i32:1
```

Building needed Xcode 27's Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`, 839 MB):
DXMT compiles its own Metal shaders with `xcrun metal`.

## Acceptance on the maintainer's Mac, 2026-09-29

1. `make dxmt`, `make app`: ok. Restarting MacNeutron from the new build installed DXMT
   `7579e39792732625569d07a03df1a73a70dd984b` (matches the pin): `d3d12.dll` is in `Libraries/DXMT/x64`, and Wine's
   `winemetal.dll` is ours.
2. `make dxmt-check`: 13/13 ok, plus `build_test.sh` 6/6. Not display-capped this time: D3D11 `present_loop`
   ours 4.115 ms vs DXMT 0.80 4.111 ms (best of 2 each); `d3d12_clear` 4.029 ms; D3DMetal `present_loop` 8.289 ms.
3. D3D11 game on our DXMT: SMITE 2 with `-dx11` on "Default (DXMT)" runs fine (maintainer's report; no FPS or GPU
   numbers recorded).
4. SMITE 2 (D3D12) on the default, first attempt (fork `7579e39`): the game stopped at start with "DirectX 12 is not
   supported on your system". Unreal's log reads `Max supported Feature Level 11_1, shader model 5.1, binding tier 2,
   wave ops unsupported, atomic64 unsupported` and `Adapter only supports up to Feature Level 'SM5', requested Feature
   Level was 'SM6'`. It creates no pipelines, so nothing was captured. The launch option also used `$HOME`, which
   Steam doesn't expand. Fix: fork `3dec1a8`'s capture mode reports what that check needs while `DXMT_DXIL_DUMP` is
   set, and creates the folder; the README asks for an absolute path.
   Second attempt, fork `a00c283`, with `DXMT_DXIL_DUMP=/Users/<maintainer>/dxil-smite2`:
   - Unreal passed its check: `Max supported Feature Level 12_1, shader model 6.7, binding tier 3, wave ops
     supported, atomic64 supported`, then `Creating D3D12 RHI with Max Feature Level SM6`.
   - It stopped at `ID3D12CommandQueue::GetClockCalibration` (E_NOTIMPL, fatal in D3D12Util.cpp). The fork now stubs
     it, like `GetTimestampFrequency`.
   - Third attempt: it stopped at the first failed pipeline ("Shader compilation failures are Fatal",
     PipelineStateCache.cpp:528), after **770 shaders were captured** (18 MB): 587 ps, 166 vs, 16 cs, 1 gs.
5. `dxil-probe` on SMITE 2's 770 shaders: **770 ok, 0 fail**.
   - DXIL 1.6 (768) and 1.4 (2); all Shader Model 6.6 (ps/vs/cs/gs_6_6).
   - Most-used `dx.op` calls: unary.f32 134083, tertiary.f32 71999, dot3.f32 41061, binary.f32 36933,
     cbufferLoadLegacy.f32 24244, dot4AddPacked.i32 23060, annotateHandle 19249, createHandleFromBinding 12982,
     sampleLevel.f32 12375, rawBufferLoad.i32 5440.
   - Test shaders: 3/3 ok (DXIL 1.0, SM 6.0; table above).

   **Consequence for sub-project 2:** LLVM 15, which DXMT's `airconv` already links, reads SMITE 2's DXIL as it
   ships. The DXIL translator can parse with LLVM 15 directly; no separate reader (such as dxil-spirv's) is needed.
   SM 6.6 resource handles (`createHandleFromBinding`/`annotateHandle`) are in almost every shader, so they come first.
6. SMITE 2 on the default: fails as expected (item 4). With Graphics: D3DMetal: to be confirmed by the maintainer.
