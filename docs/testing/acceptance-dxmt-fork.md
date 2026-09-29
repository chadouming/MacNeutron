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

Every run is paced to the display's 120 Hz (8.3 ms) even with vsync off, so check 1 shows that our build paces
like DXMT 0.80. It doesn't measure throughput beyond the refresh rate.

`dxil-probe` (LLVM 15.0.7):

```
ok compute.cs.dxil dxil=1.0 cs_6_0 entry=csmain ops=bufferLoad.f32:1,bufferStore.f32:1,createHandle:1,threadId.i32:1
ok triangle.ps.dxil dxil=1.0 ps_6_0 entry=psmain ops=storeOutput.f32:4,loadInput.f32:3
ok triangle.vs.dxil dxil=1.0 vs_6_0 entry=vsmain ops=storeOutput.f32:7,loadInput.i32:1
```

Building needed Xcode 27's Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`, 839 MB):
DXMT compiles its own Metal shaders with `xcrun metal`.
