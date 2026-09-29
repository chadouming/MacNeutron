# MacNeutron — DXMT Fork, Sub-project 2: DXIL Shader Translator

- **Date:** 2026-09-29
- **Status:** Draft for review
- **Builds on:** `2026-09-28-macneutron-dxmt-fork-design.md` (roadmap §2 item 2; the fork, `make dxmt`, `make dxmt-check`, capture mode), with its acceptance in `docs/testing/acceptance-dxmt-fork.md`.
- **Scope:**
  - **In:** a DXIL front end in the fork's `airconv` that turns Shader Model 6.0–6.6 vertex, pixel and compute shaders into Metal libraries, for every operation SMITE 2's captured shaders use; behaviour tests against D3DMetal; an offline corpus tool; the SMITE 2 run that finds the next runtime gap.
  - **Out (later sub-projects):**
    - geometry, hull and domain shaders in DXIL; mesh, amplification and ray tracing shaders;
    - `ResourceDescriptorHeap`/`SamplerDescriptorHeap` (dynamic resources, `createHandleFromHeap`);
    - 64-bit atomics;
    - reporting shader model 6.x outside capture mode;
    - every D3D12 runtime gap (sub-project 3);
    - caching translated shaders and performance work (sub-project 4).

## 1. Goal

DXMT runs Shader Model 6 shaders. A D3D12 pipeline built from DXIL vertex, pixel or compute shaders is created and behaves the same as it does on D3DMetal.

**Done when** §8 passes:
- the behaviour and render tests match D3DMetal;
- all 770 captured SMITE 2 shaders translate and Metal accepts them;
- SMITE 2 in capture mode gets past pipeline creation, and where it stops next is recorded for sub-project 3.

### Decisions made during brainstorming

| Decision | Choice |
|---|---|
| Split | Sub-project 2 (this spec, shaders) before sub-project 3 (D3D12 runtime); nothing renders until shaders translate |
| Done means | Corpus + tests: the tests match D3DMetal, 770/770 SMITE 2 shaders reach a Metal pipeline, SMITE 2 reaches its next runtime gap |
| Approach | **A:** load DXIL with LLVM 15 and rewrite it into AIR inside `airconv`, reusing its signature handlers, root-signature binding, AIR builder and metallib writer (rejected: **B**, lowering DXIL into `airconv`'s DXBC instruction form; **C**, dxil-spirv + SPIRV-Cross to Metal Shading Language) |
| Integration | `SM50Initialize`/`SM50Compile` accept DXIL containers; `winemetal` and the D3D12 runtime are unchanged apart from removing the DXIL rejection |
| Feature reporting | Unchanged: shader model 5.1 and binding tier 2, except in capture mode |
| Reference for tests | D3DMetal on the same GPU (GPTK imported) |

## 2. Evidence (2026-09-29; fork commit `9d97fe9`)

1. **LLVM 15 reads DXIL.** `dxil-probe` parsed all 770 shaders SMITE 2 created in capture mode with `parseBitcodeFile`: DXIL 1.6 (768) and 1.4 (2), all Shader Model 6.6. By stage: 587 pixel, 166 vertex, 16 compute, 1 geometry.
2. **What they use.** `dxil-probe` lists each shader's ten most-called `dx.op` functions, so these counts are lower bounds:
   - `createHandleFromBinding` and `annotateHandle` (SM 6.6's handle style for ordinary bindings) in 764 shaders; `createHandleFromHeap` in none;
   - sampling in 452, `discard` in 32, `textureLoad` in 17, `dot4AddPacked` in 13, `textureStore` in 7, `rawBufferStore` in 2, wave operations in 2 and barriers in 2.
   - The most-called operations overall: `unary.f32`, `tertiary.f32`, `dot3.f32`, `binary.f32`, `cbufferLoadLegacy.f32`, `dot4AddPacked.i32`, `annotateHandle`, `createHandleFromBinding` and `sampleLevel.f32`.
3. **`airconv` today:**
   - **API:** DXBC goes through `SM50Initialize` (parse and reflect: `MTL_SHADER_REFLECTION`) and `SM50Compile` (a chain of arguments: common data, root signature, vertex input layout, pixel data). `winemetal` forwards both calls from Windows to the Mac side.
   - **Reusable parts:**
     - `air_signature` (`FunctionSignatureBuilder`) and the DXBC signature handlers, which produce vertex fetch, system values and outputs in a prologue and epilogue;
     - `RootSignatureBindingMap`, the SM 5.1 space/range to argument-buffer layout the D3D12 runtime uses;
     - `nt/air_builder` and the transforms `lower_16bit_texread` and `simdgroup_implicit_membarrier`;
     - `metallib_writer`.
4. **Signatures:** `libs/DXBCParser` already reads the SM 5.1+ signature parts `ISG1`, `OSG1` and `PSG1`, which DXC writes into DXIL containers next to `DXIL` and `PSV0`.
5. **D3D12's shader entry:** `MTLD3D12PipelineState::InitializeShader` rejects any container with a `DXIL` part (`E_NOTIMPL`). D3D12 compiles through `SM50Compile` directly and doesn't use DXMT's shader cache, which D3D11 does.
6. **Unreal Engine's SM6 check** (SMITE 2 log) requires:
   - feature level 12_0;
   - shader model 6.6;
   - binding tier 3;
   - wave ops;
   - 64-bit atomics.

   Capture mode reports these today (fork `3dec1a8`).

## 3. Architecture

**Where:** `src/airconv/dxil/` in the fork, beside the DXBC converter, with LGPL headers like the rest of DXMT.

**Units:**
- **Container:** finds the `DXIL`, `ISG1`, `OSG1` and `PSV0` parts with DXMT's DXBC container parser, and validates the DXIL program header (version, bitcode offset and size inside the part).
- **Module:** loads the bitcode with LLVM 15 into `airconv`'s context with typed pointers, as AIR needs. It reads the entry point from `dx.entryPoints`: stage, name, `numthreads`, the resource list (`dx.resources`: SRV, UAV, CBV and sampler ranges with space, lower bound, size and kind) and the shader flags.
- **Lowering** turns each `dx.op` family into AIR through `nt/air_builder`:
  - **I/O:** `loadInput`, `storeOutput`, and the system values (vertex, instance, thread and group IDs, position, front face, sample index, coverage) → the registers the DXBC signature handlers fill and read.
  - **Resources:** `createHandleFromBinding`, `annotateHandle` and `createHandle` → descriptor loads through `RootSignatureBindingMap`, keyed by resource class, space and register.
  - **Buffers and textures:**
    - constant buffers (`cbufferLoadLegacy`, `cbufferLoad`);
    - typed buffers (`bufferLoad`, `bufferStore`);
    - raw and structured buffers (`rawBufferLoad`, `rawBufferStore`);
    - texture reads and writes (`textureLoad`, `textureStore`);
    - sampling (`sample`, `sampleBias`, `sampleLevel`, `sampleGrad`, `sampleCmp`, `sampleCmpLevelZero`);
    - `textureGather` and `textureGatherCmp`;
    - `getDimensions`;
    - `calculateLOD`.
  - **Math:** the unary, binary, tertiary and quaternary families; dot products; `dot4AddPacked` and `dot2AddHalf`; bit operations; conversions; `legacyF16ToF32` and `legacyF32ToF16`.
  - **Control:** `discard`, derivatives (coarse and fine), barriers and groupshared memory (DXIL address space 3 is AIR's threadgroup space).
  - **Wave:** `WaveGetLaneIndex`, `WaveGetLaneCount`, `WaveIsFirstLane`, `WaveActiveAllTrue`/`AnyTrue`, `WaveActiveBallot`, `WaveReadLaneFirst`/`ReadLaneAt`, `WaveActiveSum`/`Min`/`Max`, plus any other wave op SMITE 2's corpus uses. They map to Metal simdgroup functions (32 lanes on Apple GPUs).
- **Converter:**
  - builds the AIR entry function with the signature handlers;
  - moves the DXIL entry body into it;
  - runs the lowerings and replaces DXIL's types (`dx.types.Handle`, the ResRet and CBufRet structs) with AIR's;
  - strips DXIL metadata, sets the AIR triple and data layout;
  - runs LLVM's verifier, then the passes and transforms the DXBC path uses;
  - writes a metallib.

**Integration:**
- `SM50Initialize` recognises a DXIL container and returns a DXIL shader behind the same `sm50_shader_t`, with `MTL_SHADER_REFLECTION` filled the same way: `numthreads`, pixel-shader outputs and resource slot masks.
- `SM50Compile` dispatches on the shader kind and reads the same argument chain.
- `InitializeShader` in `d3d12_pipeline_graphics.cpp` no longer rejects DXIL. Capture (`DumpDXIL`) stays where it is.
- Geometry and tessellation pipelines with DXIL shaders return `E_NOTIMPL` as today.

**Unsupported input:** an operation with no lowering, or a module the verifier rejects, makes `SM50Compile` fail with an error naming it, for example `DXIL: dx.op.waveMatch not supported`. D3D12 logs that and returns `E_NOTIMPL`.

## 4. Feature reporting

Unchanged by default: shader model 5.1, binding tier 2, no wave ops, no 64-bit atomics.

Capture mode (`DXMT_DXIL_DUMP`) keeps reporting what Unreal Engine's SM6 check needs, and that's how SMITE 2 loads its shaders for §8's game run. Honest SM 6.x reporting needs 64-bit atomics and binding tier 3; that's sub-project 3's decision.

## 5. Tests and tools (MacNeutron repo)

- **Behaviour tests:** `dxmt/tests/dxil/*.hlsl`, compute shaders grouped by feature. Each reads inputs from a buffer, so DXC can't fold them, and writes results to a UAV:
  - math and conversions;
  - typed, raw and structured buffers;
  - constant buffers;
  - texture loads, `SampleLevel` and `Gather`;
  - groupshared memory and barriers;
  - wave operations;
  - 16-bit types;
  - `dot4AddPacked`.

  Their `.dxil` files are built by `dxmt/tests/shaders/compile.sh` (DXC under Wine) and committed.
- **`dxmt/tests/d3d12_dxil_exec.cpp`:** runs every behaviour test through D3D12 and prints each result buffer, one line per test.
- **`dxmt/tests/d3d12_triangle.cpp`:**
  - draws the test triangle offscreen through DXIL vertex and pixel shaders, with a constant buffer, a sampled texture and `discard`;
  - reads the image back and prints a checksum and eight sampled pixels.
- **`dxmt/tools/dxil-translate.mm`:** a native Mac tool, x86_64, linking `airconv`'s Mac static library and Metal. For each `.dxil` file in a folder it:
  - builds a root signature from the shader's own resource list (one descriptor table range per resource range), and an input layout from a vertex shader's inputs;
  - runs `SM50Initialize` and `SM50Compile`;
  - creates a Metal library, then a pipeline:
    - compute: a compute pipeline;
    - vertex: a vertex pipeline with rasterization off;
    - pixel: a render pipeline with a pass-through vertex function generated from its inputs.
  - prints `ok <file> <stage> <ms>` or `fail <file> <reason>`, and a summary.

  `make dxmt` builds it; `make dxil-corpus DIR=<folder>` runs it. SMITE 2's shaders stay on the maintainer's Mac and are never committed.
- **`dxmt/check.sh`** gains:
  - `d3d12_dxil_exec` on our DXMT and on D3DMetal: the outputs match, within 4 ULP for transcendental functions (`sin`, `cos`, `exp`, `log`, `pow`, `rsqrt` and the like) and exactly everywhere else;
  - `d3d12_triangle` on both: the sampled pixels match within 1/255;
  - `d3d12_dxil`'s pipelines are created (`S_OK`), and capture still saves them.

## 6. Errors

| Condition | Behavior |
|---|---|
| DXIL op with no lowering | `SM50Compile` fails naming the op; D3D12 logs it and returns `E_NOTIMPL` |
| Module fails LLVM's verifier after lowering | Same, with the verifier's message |
| DXIL geometry, hull or domain shader | `E_NOTIMPL` as today, logged |
| `createHandleFromHeap` (dynamic resources) | Fails naming the op (out of scope) |
| Malformed container or bitcode | `SM50Initialize` fails with the reason; D3D12 returns `E_FAIL`, as for malformed DXBC |
| LLVM assertion on odd input | The process aborts (our LLVM keeps assertions on). The offline corpus run is where these are found and fixed |

## 7. Build order

1. **DXIL recognition and a minimal compute path:** container, module, reflection, compute IDs, buffers and the D3D12 hookup, with the first behaviour tests (buffers, math) matching D3DMetal.
2. **Vertex and pixel shaders:** signatures through the DXBC handlers, constant buffers, sampling and `discard`, with `d3d12_triangle` matching D3DMetal.
3. **`dxil-translate` and coverage:** run it on SMITE 2's 770 shaders and add lowerings, each with a behaviour test where the operation can be exercised in a compute shader, until 770/770.
4. **SMITE 2 in capture mode and the acceptance record.**

## 8. Acceptance on the maintainer's Mac

Recorded in `docs/testing/acceptance-dxil-translator.md`:

1. `make dxmt-check` passes, including the new D3DMetal comparisons.
2. `make dxil-corpus DIR=~/dxil-smite2`: 770/770 ok. Record the translation time per shader (mean and slowest) as input for sub-project 4.
3. **SMITE 2 in capture mode on the `dxmt` backend** gets past pipeline creation. Record where it stops next (the first runtime error or unimplemented call in Unreal's log) and how many pipelines it created: this opens sub-project 3.
4. With "Graphics: D3DMetal", SMITE 2 plays as before.

## 9. Risks

- **The breadth of DXIL:** SM 6.6 has about 200 `dx.op` functions. Scope follows SMITE 2's corpus, so other games will hit missing lowerings, each reported by name.
- **LLVM 3.7-era bitcode in LLVM 15:** attributes, metadata and intrinsics that AIR's compiler rejects. The verifier plus Metal pipeline creation in `dxil-translate` catch these offline.
- **Assertions:** malformed or unusual input can abort the game process. The corpus run finds these; a release build without assertions is a sub-project 4 choice.
- **Semantics:**
  - precision (`precise`, denormals, fast-math flags);
  - pixel-shader helper lanes for derivatives;
  - wave size (Metal's 32 against HLSL's `WaveGetLaneCount`);
  - 16-bit behaviour.

  The D3DMetal comparisons are the check.
- **Binding differences in the corpus tool:** it builds root signatures from each shader's resources, not the game's. The game run (§8 item 3) and the tests' real root signatures cover the actual layouts.
- **Translation time at game start:** Unreal creates hundreds of pipelines at start. Times are recorded here; caching is sub-project 4.
