# DXMT Fork, Sub-project 2 (DXIL Shader Translator) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** DXMT's shader compiler (`airconv`) translates Shader Model 6.0–6.6 vertex, pixel and compute DXIL shaders into Metal libraries. The results match D3DMetal in behaviour tests, all 770 captured SMITE 2 shaders reach a Metal pipeline, and SMITE 2 in capture mode gets past pipeline creation.

**Architecture:** A new `src/airconv/dxil/` front end in our DXMT fork.
- **`SM50Initialize`** recognises a DXIL container. It reads the entry point's metadata (stage, `numthreads`, signatures, resources) with LLVM 15, fills the same `SM50ShaderInternal` the DXBC path uses (resource maps, signature handlers, reflection) and keeps the bitcode.
- **`SM50Compile`** loads that bitcode into its per-compile typed-pointer context. It builds the Metal entry point with airconv's `FunctionSignatureBuilder`, moves the DXIL body into it and lowers every `dx.op` call through the root-signature binding map and `AIRBuilder`. Then it runs airconv's usual passes and writes a metallib.

**Tech Stack:** C++20, LLVM 15.0.7 (typed pointers), airconv (`nt/air_builder`, `air_signature`, `dxbc_binding_rootsig`, `metallib_writer`), Microsoft DXC under Wine for test shaders, mingw-w64 C++ for D3D12 test programs, and Objective-C++ with Metal for the corpus tool.

**Spec:** `docs/superpowers/specs/2026-09-29-macneutron-dxil-translator-design.md`

## Global Constraints

- The fork is `github.com/chadouming/dxmt`, branch `macneutron`. Nothing is sent upstream (DXMT refuses AI-authored contributions); issue reports only.
- New fork files carry the LGPL-2.1+ notice with `Copyright 2026 MacNeutron contributors`. Never write "for CodeWeavers" on our files.
- Every fork commit ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`, as do MacNeutron commits.
- Commit in the fork on the branch, not on a detached HEAD: `git -C build/dxmt-src/dxmt switch macneutron` before editing, since `build.sh` leaves the clone detached. Push the fork before `make app`: `dxmt/published.sh` refuses unpushed commits.
- After each fork commit, write its hash into `dxmt/pins` (`DXMT_COMMIT=`) and run `make dxmt` so `build/dxmt` holds it.
- Default feature reporting doesn't change: shader model 5.1, binding tier 2, no wave ops, no 64-bit atomics. Only capture mode (`DXMT_DXIL_DUMP`) reports more.
- In scope: DXIL vertex, pixel and compute shaders. Geometry, hull and domain shaders in DXIL, `createHandleFromHeap` and 64-bit atomics fail with an error naming them.
- An unsupported op or a verifier failure makes `SM50Compile` fail with an `UnsupportedFeature` error whose message names it. D3D12 logs the message and returns `E_NOTIMPL`. A malformed DXIL container makes `SM50Initialize` fail; D3D12 returns `E_FAIL`.
- SMITE 2's captured shaders (`~/dxil-smite2`) never enter git.
- Behaviour tests use D3DMetal as the reference and require GPTK imported. The comparison is exact, except within 4 ULP for the transcendental group.

## Review Focus

- **Pipelines compiled on many threads at once.** Unreal creates PSOs from worker threads. Two compiles of the same DXIL shader must not share mutable state. Test: `d3d12_dxil_exec` `threads` mode compiles one compute PSO on 8 threads (Task 2).
- **Vertex and pixel shaders packed differently.** A vertex shader can output more semantics than the pixel shader reads, at different rows. They must link by semantic. Test: `d3d12_triangle` outputs an extra `TEXCOORD1`, so the pixel shader's `TEXCOORD0` sits at a different row than in the vertex shader (Task 3).
- **Resource arrays indexed at run time** (`Buffer<float4> arr[2] : register(t4)` indexed dynamically) must fetch the right descriptor, with the register absolute and not range-relative. Test: behaviour group `buffers` reads `arr[i & 1]` (Task 2).
- **An out-of-scope op in one shader.** It must fail only that pipeline, with the op named in the log. Test: `d3d12_dxil` compiles `heap.cs.dxil` (`ResourceDescriptorHeap`), expects `E_NOTIMPL`, and `check.sh` greps the log for `createHandleFromHeap` (Task 2).
- **Min-precision and native 16-bit shaders** (`min16float`, `-enable-16bit-types`) must match D3DMetal. Test: behaviour group `half` (Task 4).

---

## File Structure

**Fork (`build/dxmt-src/dxmt`, branch `macneutron`):**

| Path | Responsibility |
|---|---|
| `src/airconv/dxil/dxil_types.hpp` (new) | DXIL enums (shader kind, resource class and kind, component type, semantic kind, interpolation, opcodes) and the parsed-entry structs |
| `src/airconv/dxil/dxil_container.{hpp,cpp}` (new) | Find the `DXIL` part in a container and validate its program header |
| `src/airconv/dxil/dxil_metadata.{hpp,cpp}` (new) | Load bitcode into a context; read `dx.entryPoints`/`dx.shaderModel`/`dx.resources` into `EntryInfo` |
| `src/airconv/dxil/dxil_initialize.cpp` (new) | The DXIL branch of `SM50Initialize`: fill `SM50ShaderInternal` (resource maps, signature handlers, reflection) |
| `src/airconv/dxil/dxil_signature.{hpp,cpp}` (new) | Signature handlers for VS/PS/CS built from DXIL signature metadata with airconv's IO helpers; element lookup for `loadInput`/`storeOutput` |
| `src/airconv/dxil/dxil_converter.cpp` (new) | The DXIL branch of `SM50Compile`: build the AIR entry, move the body, lower, clean up |
| `src/airconv/dxil/dxil_lower.{hpp,cpp}` (new) | Lowering context, handle resolution, the opcode dispatcher, IO/thread/control/wave lowerings |
| `src/airconv/dxil/dxil_lower_resources.cpp` (new) | Constant buffers, buffers, textures, sampling, gather, dimensions, LOD |
| `src/airconv/dxil/dxil_lower_math.cpp` (new) | The unary/binary/tertiary/quaternary families, dots, bits, conversions, packed dots |
| `src/airconv/dxil/dxil_public.h` (new) | Test-only API: compile a pass-through vertex function for a DXIL pixel shader |
| `src/airconv/nt/air_builder.{hpp,cpp}` | Add simdgroup (wave) methods |
| `src/airconv/dxbc_converter.hpp` | `SM50ShaderInternal` gains `std::shared_ptr<const dxil::DXILShader> dxil` |
| `src/airconv/dxbc_converter.cpp` | `SM50Initialize` and `SM50Compile` branch to the DXIL path |
| `src/airconv/meson.build` | New sources |
| `src/d3d12/d3d12_pipeline_graphics.cpp` | Drop the DXIL rejection; fill `ref_ps` before `InitializePSO` reads it |

**MacNeutron:**

| Path | Responsibility |
|---|---|
| `dxmt/tests/dxil/*.hlsl` (new) | Behaviour groups: `buffers`, `math`, `transcendental`, `textures`, `groupshared`, `wave`, `half`, `packed`; `heap.hlsl` (out of scope on purpose) |
| `dxmt/tests/shaders/triangle2.hlsl` (new) | The render test's vertex/pixel pair |
| `dxmt/tests/shaders/compile.sh` | Also builds `dxmt/tests/dxil/*.dxil` and the triangle2 pair |
| `dxmt/tests/d3d12_dxil_exec.cpp` (new) | Run behaviour groups through D3D12 and print results; `threads` mode |
| `dxmt/tests/d3d12_triangle.cpp` (new) | Render the triangle offscreen and print pixels |
| `dxmt/tests/compare.py` (new) | Compare two runs' outputs (exact or within 4 ULP) |
| `dxmt/tools/dxil-probe.cpp` | `-S` prints a module as LLVM IR text (development aid) |
| `dxmt/tools/dxil-translate.mm` (new) | Offline corpus tool |
| `dxmt/build.sh`, `Makefile` | Build `dxil-translate`; `make dxil-corpus DIR=` |
| `dxmt/check.sh`, `dxmt/tests/d3d12_dxil.cpp` | New comparisons; pipelines now succeed; `heap` stays `E_NOTIMPL` |
| `docs/testing/acceptance-dxil-translator.md` (new) | Results |

---

### Task 1: Verify typed-pointer loading and build the behaviour-test harness (all RED on DXMT)

This task proves the one assumption the design rests on and creates every test the later tasks turn green. It changes nothing in the fork.

**Files:**
- Modify: `dxmt/tools/dxil-probe.cpp`, `dxmt/tests/shaders/compile.sh`, `dxmt/check.sh`, `Makefile`
- Create:
  - `dxmt/tests/dxil/{buffers,math,transcendental,textures,groupshared,wave,half,packed,heap}.hlsl`
  - `dxmt/tests/dxil/*.dxil` (generated)
  - `dxmt/tests/d3d12_dxil_exec.cpp`
  - `dxmt/tests/compare.py`

**Interfaces:**
- Produces:
  - `build/dxmt-tests/d3d12_dxil_exec.exe <shader folder> [group...]` prints `group <name> ok <word0> … <word1023>` (hex) or `group <name> fail <hr>`.
  - `d3d12_dxil_exec.exe <shader folder> threads` prints `threads ok 8/8` or `threads fail <n>/8`.
  - `python3 dxmt/tests/compare.py <ours.txt> <reference.txt> <group>` exits 0 and prints `match` or `differ: word <i> ours <x> ref <y>`.
  - `dxil-probe -S <file>` prints IR.
  - Shared harness layout (every behaviour shader relies on it; see Step 3).

- [ ] **Step 1: Check that DXIL loads into a typed-pointer context**

In `dxmt/tools/dxil-probe.cpp`:
- In `probe()`, after `llvm::LLVMContext context;`, add `context.setOpaquePointers(false);  // airconv's contexts use typed pointers (AIR needs them)`.
- Add a `-S` mode: when `argv[1]` is `-S`, parse `argv[2]` the same way and print the module with `(*module)->print(llvm::outs(), nullptr);` instead of the summary line. Add `#include <llvm/Support/raw_ostream.h>`.

Run: `make dxmt && build/dxmt/dxil-probe ~/dxil-smite2/*.dxil | grep -c '^ok '; build/dxmt/dxil-probe dxmt/tests/shaders/*.dxil`
Expected: `770`, then three `ok` lines. If any file fails, stop and report: the design depends on it (spec §9).

- [ ] **Step 2: Write the behaviour shaders**

Every file is a `cs_6_6` compute shader with entry `main` and `[numthreads(64, 1, 1)]`. The resource layout is shared by all of them and set up by the harness (Step 3):

```hlsl
// dxmt/tests/dxil/common.hlsli — the harness's resources (d3d12_dxil_exec.cpp sets them up)
cbuffer Constants : register(b0) { float4 k[4]; uint4 u; };               // k[i] = (i+1, -(i+1)/2, (i+1)*0.25, 7), u = (3, 5, 7, 11)
ByteAddressBuffer In : register(t0);                                       // words 0..1023: word i = i * 2654435761; bytes 4096..8191: floats (i-512)/37.0
Texture2D<float4> Tex : register(t1);                                      // 8x8 RGBA8 UNORM, texel (x*32, y*32, (x+y)*16, 255)/255
Buffer<float4> Typed : register(t2);                                       // 64 elements, element i = (i, i*0.5, -i, 1)
struct S { float4 a; uint b; };
StructuredBuffer<S> Structured : register(t3);                             // 64 elements, a = (i, 2i, 3i, 4i), b = i ^ 0x5a5a
Buffer<float4> Arr[2] : register(t4);                                      // t4: element i = (i,0,0,0); t5: element i = (0,i,0,0)
RWByteAddressBuffer Out : register(u0);                                    // 64 threads x 16 words, zeroed
RWBuffer<uint> RWTyped : register(u1);                                     // 64 elements, zeroed
RWTexture2D<float4> RWTex : register(u2);                                  // 8x8 RGBA32F, zeroed
SamplerState Linear : register(s0);                                        // static: linear, clamp
SamplerState Point : register(s1);                                         // static: point, clamp
uint InWord(uint i) { return In.Load(i * 4); }
float InFloat(uint i) { return asfloat(In.Load(4096 + i * 4)); }
void Put(uint3 id, uint slot, uint v) { Out.Store((id.x * 16 + slot) * 4, v); }
void PutF(uint3 id, uint slot, float v) { Put(id, slot, asuint(v)); }
```

`dxmt/tests/dxil/buffers.hlsl`:
```hlsl
#include "common.hlsli"
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint i = id.x;
    Put(id, 0, InWord(i));
    uint2 two = In.Load2(i * 8); Put(id, 1, two.x ^ two.y);
    uint4 four = In.Load4(i * 16); Put(id, 2, four.x + four.y + four.z + four.w);
    float4 t = Typed[i]; PutF(id, 3, t.x + t.y * 2 + t.z * 3 + t.w * 4);
    S s = Structured[i]; PutF(id, 4, s.a.y + s.a.w); Put(id, 5, s.b);
    PutF(id, 6, k[i & 3].x * k[(i + 1) & 3].y); Put(id, 7, u[i & 3]);
    float4 a = Arr[i & 1][i]; PutF(id, 8, a.x + a.y);
    RWTyped[i] = i * 3; AllMemoryBarrier(); Put(id, 9, RWTyped[i ^ 0]);
    Out.Store((i * 16 + 10) * 4, InWord(i) >> 3);
    Out.Store2((i * 16 + 11) * 4, uint2(i, i + 1));
}
```

`dxmt/tests/dxil/math.hlsl`:
```hlsl
#include "common.hlsli"
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint i = id.x; float f = InFloat(i); float g = InFloat(i + 64); uint w = InWord(i); int s = (int)w;
    PutF(id, 0, f * g + f / (abs(g) + 1)); PutF(id, 1, mad(f, g, 0.5)); PutF(id, 2, min(f, g) - max(f, g));
    PutF(id, 3, saturate(f) + abs(g)); PutF(id, 4, floor(f) + ceil(g) + round(f) + trunc(g));
    PutF(id, 5, frac(f) + sqrt(abs(g)) + rsqrt(abs(f) + 1)); PutF(id, 6, dot(float3(f, g, 1), float3(g, f, 2)));
    Put(id, 7, countbits(w) + firstbitlow(w) * 64 + firstbithigh(w) * 4096); Put(id, 8, reversebits(w));
    Put(id, 9, (uint)(s / 7) + (uint)(s % 7) + w / 13 + w % 13); Put(id, 10, (uint)min(s, 5) + max(w, 9u));
    Put(id, 11, f32tof16(f) | (f32tof16(g) << 16)); PutF(id, 12, f16tof32(w & 0xffff));
    PutF(id, 13, (float)s * 1e-9 + (float)w * 1e-9); Put(id, 14, (uint)(int)(f * 10) + (uint)abs(g * 10));
    PutF(id, 15, clamp(f, -1, 1) + lerp(f, g, 0.25) + step(0, f) + sign(g));
}
```

`dxmt/tests/dxil/transcendental.hlsl` (compared within 4 ULP):
```hlsl
#include "common.hlsli"
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint i = id.x; float f = InFloat(i) * 0.5; float p = abs(f) + 0.01;
    PutF(id, 0, sin(f)); PutF(id, 1, cos(f)); PutF(id, 2, tan(f * 0.5)); PutF(id, 3, asin(clamp(f, -1, 1)));
    PutF(id, 4, acos(clamp(f, -1, 1))); PutF(id, 5, atan(f)); PutF(id, 6, atan2(f, 0.7)); PutF(id, 7, exp(f * 0.5));
    PutF(id, 8, exp2(f)); PutF(id, 9, log(p)); PutF(id, 10, log2(p)); PutF(id, 11, pow(p, 1.7));
    PutF(id, 12, sinh(f * 0.25)); PutF(id, 13, cosh(f * 0.25)); PutF(id, 14, tanh(f)); PutF(id, 15, sqrt(p));
}
```

`dxmt/tests/dxil/textures.hlsl`:
```hlsl
#include "common.hlsli"
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint i = id.x; int2 xy = int2(i & 7, i >> 3); float2 uv = (float2(xy) + 0.37) / 8;
    float4 l = Tex.Load(int3(xy, 0)); PutF(id, 0, l.x + l.y * 2 + l.z * 4);
    float4 a = Tex.SampleLevel(Linear, uv, 0); PutF(id, 1, a.x); PutF(id, 2, a.y); PutF(id, 3, a.z);
    float4 b = Tex.SampleLevel(Point, uv, 0); PutF(id, 4, b.x + b.y + b.z);
    float4 r = Tex.GatherRed(Point, uv); PutF(id, 5, r.x + r.y * 2 + r.z * 4 + r.w * 8);
    uint w, h, m; Tex.GetDimensions(0, w, h, m); Put(id, 6, w * 100 + h * 10 + m);
    float4 o = Tex.SampleLevel(Linear, uv, 0, int2(1, -1)); PutF(id, 7, o.x + o.y);
    RWTex[xy] = float4(uv, 0.5, 1); DeviceMemoryBarrierWithGroupSync(); PutF(id, 8, RWTex[xy].x + RWTex[xy].y);
}
```

`dxmt/tests/dxil/groupshared.hlsl`:
```hlsl
#include "common.hlsli"
groupshared uint Shared[64];
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID, uint gi : SV_GroupIndex, uint3 gtid : SV_GroupThreadID) {
    Shared[gi] = InWord(gi); GroupMemoryBarrierWithGroupSync();
    Put(id, 0, Shared[(gi + 1) & 63]); Put(id, 1, Shared[63 - gi] + gtid.x);
    uint old; InterlockedAdd(Shared[0], 1, old); GroupMemoryBarrierWithGroupSync(); Put(id, 2, Shared[0] - InWord(0));
}
```

`dxmt/tests/dxil/wave.hlsl`:
```hlsl
#include "common.hlsli"
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint i = id.x; uint w = InWord(i) & 0xffff; float f = InFloat(i);
    Put(id, 0, WaveGetLaneIndex()); Put(id, 1, WaveGetLaneCount()); Put(id, 2, WaveIsFirstLane() ? 1 : 0);
    Put(id, 3, WaveActiveSum(w)); Put(id, 4, WaveActiveMax(w)); Put(id, 5, WaveActiveMin(w));
    Put(id, 6, WaveActiveAllTrue(w > 3) ? 1 : 0); Put(id, 7, WaveActiveAnyTrue(w == 7) ? 1 : 0);
    uint4 b = WaveActiveBallot(w & 1); Put(id, 8, b.x); Put(id, 9, WaveReadLaneFirst(w)); Put(id, 10, WaveReadLaneAt(w, 5));
    Put(id, 11, WavePrefixSum(w)); PutF(id, 12, WaveActiveSum(f)); Put(id, 13, WaveActiveCountBits(w & 1));
    Put(id, 14, WaveActiveBitOr(w)); Put(id, 15, WavePrefixCountBits(w & 1));
}
```

`dxmt/tests/dxil/half.hlsl` (compiled with `-enable-16bit-types`):
```hlsl
#include "common.hlsli"
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint i = id.x; float16_t a = (float16_t)InFloat(i); float16_t b = (float16_t)InFloat(i + 64);
    uint16_t u = (uint16_t)InWord(i); int16_t s = (int16_t)InWord(i + 1);
    Put(id, 0, asuint16(a * b + a)); Put(id, 1, asuint16(max(a, b))); PutF(id, 2, (float)(a / (abs(b) + (float16_t)1)));
    Put(id, 3, (uint)(u * (uint16_t)3 + (uint16_t)(s >> 2))); min16float m = (min16float)InFloat(i); PutF(id, 4, (float)(m * m));
}
```

`dxmt/tests/dxil/packed.hlsl`:
```hlsl
#include "common.hlsli"
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint i = id.x; uint a = InWord(i), b = InWord(i + 1);
    Put(id, 0, dot4add_u8packed(a, b, 7u)); Put(id, 1, (uint)dot4add_i8packed(a, b, -7));
    PutF(id, 2, dot2add(half2(InFloat(i), InFloat(i + 1)), half2(0.5, -2), 1.0));
}
```

`dxmt/tests/dxil/heap.hlsl` (out of scope, expected to fail with `E_NOTIMPL`):
```hlsl
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    RWByteAddressBuffer o = ResourceDescriptorHeap[0];
    o.Store(id.x * 4, id.x);
}
```

- [ ] **Step 3: Write `d3d12_dxil_exec.cpp`**

Build it like `d3d12_clear.cpp` (C++, `WIDL_EXPLICIT_AGGREGATE_RETURNS`, `CHECK` macro). Structure:

```cpp
// Runs DXIL behaviour groups through D3D12 and prints each group's output (DXIL translator plan, Task 1):
//   d3d12_dxil_exec.exe <shader folder> [group...]   one line per group: "group <name> ok <1024 hex words>" or "group <name> fail 0x<hr>"
//   d3d12_dxil_exec.exe <shader folder> threads      compiles buffers.dxil on 8 threads at once: "threads ok 8/8"
// Resources follow dxmt/tests/dxil/common.hlsli. check.sh runs it on our DXMT and on D3DMetal and compares.
```

The harness, in order:
1. **Device:** D3D12 device, direct queue, allocator, list, fence, via the same `D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_11_0, …)` as `d3d12_dxil.cpp`.
2. **Root signature, 1.0:**
   - `param0`: root CBV `b0`;
   - `param1`: a descriptor table of SRV range `t0`–`t5` (6 descriptors) followed by UAV range `u0`–`u2` (3 descriptors);
   - static samplers `s0` (`D3D12_FILTER_MIN_MAG_MIP_LINEAR`, clamp) and `s1` (`D3D12_FILTER_MIN_MAG_MIP_POINT`, clamp).
3. **Resources:**
   - **Upload buffers, bound directly** (upload heap, `GENERIC_READ`):
     - `In` (8192 bytes, raw SRV);
     - `Typed` (64 × `DXGI_FORMAT_R32G32B32A32_FLOAT`);
     - `Structured` (64 × 20 bytes, stride 20);
     - `Arr[0]` and `Arr[1]` (64 × float4 each);
     - the constant buffer (256 bytes).
   - **`Tex`:** an 8×8 `DXGI_FORMAT_R8G8B8A8_UNORM` default-heap texture filled with `CopyTextureRegion` from an upload buffer.
   - **UAVs** (default heap, zeroed with an upload + copy, then transitioned to `UNORDERED_ACCESS`):
     - `Out` (4096 bytes, raw);
     - `RWTyped` (64 × `R32_UINT`);
     - `RWTex` (8×8 `R32G32B32A32_FLOAT`).
   - Fill every resource exactly as the `common.hlsli` comments say.
4. **Descriptors:** a shader-visible CBV_SRV_UAV heap with 9 descriptors in the table order above.
5. **Per group** (default: all groups in `buffers math transcendental textures groupshared wave half packed`):
   - read `<folder>/<group>.dxil` and `CreateComputePipelineState` with the root signature. On failure, print `group <name> fail 0x%08lx` and continue;
   - zero `Out`, `Dispatch(1, 1, 1)`, copy `Out` to a readback buffer, signal the fence and wait;
   - print `group <name> ok` followed by the 1024 words, each ` %08x`.
6. **`threads`:** 8 `std::thread`s each call `CreateComputePipelineState` on `buffers.dxil` at once. Print `threads ok N/8`, where N is the number of `S_OK` results.

Add to `Makefile`'s `dxmt-tests` recipe:
```make
	x86_64-w64-mingw32-g++ -O2 -static -s -std=c++17 -o build/dxmt-tests/d3d12_dxil_exec.exe dxmt/tests/d3d12_dxil_exec.cpp -ld3d12 -ldxgi
```

- [ ] **Step 4: Write `compare.py`**

```python
#!/usr/bin/env python3
"""compare.py <ours.txt> <reference.txt> <group>: compare one behaviour group's words between two d3d12_dxil_exec runs.
Exact, except the 'transcendental' group, whose words are float32 compared within 4 ULP (DXIL translator plan)."""
import struct, sys

def words(path, group):
    for line in open(path, encoding="utf-8", errors="replace"):
        parts = line.split()
        if parts[:2] == ["group", group]:
            return parts[3:] if parts[2] == "ok" else None
    return None

def ulp_distance(a, b):
    ia, ib = struct.unpack("<i", struct.pack("<I", a))[0], struct.unpack("<i", struct.pack("<I", b))[0]
    if ia < 0: ia = -0x80000000 - ia
    if ib < 0: ib = -0x80000000 - ib
    return abs(ia - ib)

ours, ref, group = words(sys.argv[1], sys.argv[3]), words(sys.argv[2], sys.argv[3]), sys.argv[3]
if ref is None: sys.exit(print(f"no reference output for {group}") or 2)
if ours is None: sys.exit(print(f"differ: {group} failed on ours") or 1)
for i, (x, y) in enumerate(zip(ours, ref)):
    a, b = int(x, 16), int(y, 16)
    if a != b and (group != "transcendental" or ulp_distance(a, b) > 4):
        sys.exit(print(f"differ: word {i} ours {x} ref {y}") or 1)
print("match")
```

- [ ] **Step 5: Compile the shaders and add the check**

In `dxmt/tests/shaders/compile.sh`, after the existing three `dxc` lines, add:
```sh
cd "$HERE/../dxil"
for g in buffers math transcendental textures groupshared wave packed heap; do dxc -T cs_6_6 -E main -Fo "$g.dxil" "$g.hlsl"; done
dxc -T cs_6_6 -E main -enable-16bit-types -Fo half.dxil half.hlsl
ls -l ./*.dxil
```

In `dxmt/check.sh`, add a new item after item 3:
```sh
# 3b. DXIL behaviour groups: our DXMT against D3DMetal on the same GPU.
X="$ROOT/dxmt/tests/dxil"
run ours exec-ours dxmt "$TESTS/d3d12_dxil_exec.exe" "Z:$X"
run ours exec-ref d3dmetal "$TESTS/d3d12_dxil_exec.exe" "Z:$X"
for g in buffers math transcendental textures groupshared wave half packed; do
  expect "DXIL $g matches D3DMetal" "$(python3 "$ROOT/dxmt/tests/compare.py" "$WORK/exec-ours.txt" "$WORK/exec-ref.txt" $g)" match
done
run ours exec-threads dxmt "$TESTS/d3d12_dxil_exec.exe" "Z:$X" threads
expect "DXIL pipelines compile on 8 threads at once" "$(grep -o 'threads ok 8/8' "$WORK/exec-threads.txt" || true)" "threads ok 8/8"
```

Run: `sh dxmt/tests/shaders/compile.sh && make dxmt-tests && sh dxmt/check.sh 2>&1 | grep -E "DXIL|FAIL"`
Expected:
- the DXC run lists 9 `.dxil` files in `dxmt/tests/dxil`;
- in `check.sh`, every "DXIL <group> matches D3DMetal" check FAILs with `differ: <group> failed on ours`, and the threads check fails;
- `exec-ref.txt` has `ok` for all eight groups.

If D3DMetal fails a group, that group's shader or harness is wrong: fix it until D3DMetal runs it.

- [ ] **Step 6: Commit**

```bash
git add dxmt/tools/dxil-probe.cpp dxmt/tests/dxil dxmt/tests/shaders/compile.sh dxmt/tests/d3d12_dxil_exec.cpp dxmt/tests/compare.py dxmt/check.sh Makefile
git commit -m "test(dxil): behaviour groups against D3DMetal (red on DXMT until the translator lands)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: DXIL recognition and the compute path (`buffers`, `math`, `transcendental` green)

**Files (fork unless noted):**
- Create:
  - `src/airconv/dxil/dxil_types.hpp`, `dxil_container.{hpp,cpp}`, `dxil_metadata.{hpp,cpp}`, `dxil_initialize.cpp`;
  - `dxil_signature.{hpp,cpp}` (compute part only);
  - `dxil_converter.cpp`, `dxil_lower.{hpp,cpp}`, `dxil_lower_resources.cpp` (buffers and constant buffers), `dxil_lower_math.cpp`.
- Modify:
  - `src/airconv/dxbc_converter.hpp`, `src/airconv/dxbc_converter.cpp`, `src/airconv/meson.build`;
  - `src/d3d12/d3d12_pipeline_graphics.cpp:243-244`;
  - MacNeutron: `dxmt/tests/d3d12_dxil.cpp`, `dxmt/check.sh`, `dxmt/pins`.

**Interfaces:**
- Consumes: the Task 1 harness and checks.
- Produces (namespace `dxmt::dxil`):
  - `struct DXILShader { std::vector<char> bitcode; EntryInfo entry; };`
  - `SM50ShaderInternal::dxil` (`std::shared_ptr<const DXILShader>`);
  - `llvm::Error InitializeDXIL(const Container &, SM50ShaderInternal *, MTL_SHADER_REFLECTION *)`;
  - `llvm::Expected<std::unique_ptr<llvm::Module>> ConvertDXIL(SM50ShaderInternal *, const char *name, llvm::LLVMContext &, SM50_SHADER_COMPILATION_ARGUMENT_DATA *)`;
  - `class Lowering` with `llvm::Error Lower(llvm::CallInst *)`;
  - `HandleInfo ResolveHandle(llvm::Value *)`.

- [ ] **Step 1: Make `d3d12_dxil` expect success, and the out-of-scope case to fail (RED)**

In `dxmt/tests/d3d12_dxil.cpp`, add a fourth argument, the path of `heap.dxil`. After the compute pipeline, create a compute PSO from it with the same root signature and print `heap hr=0x%08lx`. Change the usage line accordingly.

In `dxmt/check.sh`, item 3:
- The `dxil()` function passes `"Z:$ROOT/dxmt/tests/dxil/heap.dxil"` as the fourth argument.
- Replace the two `E_NOTIMPL` expectations (in the first run and in the unwritable-folder run) with:
  ```sh
  expect "DXIL pipelines are created" "$(grep -cE '^(graphics|compute) hr=0x00000000$' "$WORK/dxil.txt" || true)" 2
  expect "an out-of-scope DXIL op fails only its pipeline" "$(grep -c '^heap hr=0x80004001$' "$WORK/dxil.txt" || true)" 1
  ```
  (use `dxil-unwritable.txt` in the second).
- The capture-count check becomes 4: `heap` is captured too. The byte-for-byte loop is unchanged.

Run: `make dxmt-tests && sh dxmt/check.sh 2>&1 | grep -E "DXIL pipelines are created|out-of-scope"`
Expected: `FAIL DXIL pipelines are created: got [0], want [2]`; the out-of-scope check is `ok` (E_NOTIMPL today).

- [ ] **Step 2: DXIL types**

`src/airconv/dxil/dxil_types.hpp` (values from DXC's `DxilConstants.h`; confirm any doubtful one against `dxc -Fc` listings, whose comments name every op):
```cpp
/* LGPL-2.1+ notice, Copyright 2026 MacNeutron contributors (as in the other new files) */
#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace dxmt::dxil {

enum class ShaderKind : uint32_t { Pixel = 0, Vertex = 1, Geometry = 2, Hull = 3, Domain = 4, Compute = 5, Library = 6, Invalid = ~0u };
enum class ResourceClass : uint32_t { SRV = 0, UAV = 1, CBuffer = 2, Sampler = 3 };
enum class ResourceKind : uint32_t {
  Invalid = 0, Texture1D, Texture2D, Texture2DMS, Texture3D, TextureCube, Texture1DArray, Texture2DArray, Texture2DMSArray,
  TextureCubeArray, TypedBuffer, RawBuffer, StructuredBuffer, CBuffer, Sampler, TBuffer, RTAccelerationStructure
};
enum class ComponentType : uint32_t {
  Invalid = 0, I1, I16, U16, I32, U32, I64, U64, F16, F32, F64, SNormF16, UNormF16, SNormF32, UNormF32, SNormF64, UNormF64
};
enum class SemanticKind : uint32_t {
  Arbitrary = 0, VertexID, InstanceID, Position, RenderTargetArrayIndex, ViewPortArrayIndex, ClipDistance, CullDistance,
  OutputControlPointID, DomainLocation, PrimitiveID, GSInstanceID, SampleIndex, IsFrontFace, Coverage, InnerCoverage,
  Target, Depth, DepthLessEqual, DepthGreaterEqual, StencilRef, DispatchThreadID, GroupID, GroupIndex, GroupThreadID
};
enum class Interpolation : uint32_t {
  Undefined = 0, Constant, Linear, LinearCentroid, LinearNoperspective, LinearNoperspectiveCentroid, LinearSample,
  LinearNoperspectiveSample
};

namespace op {  // dx.op opcodes (first argument of every dx.op call)
enum : uint32_t {
  LoadInput = 4, StoreOutput = 5, FAbs = 6, Saturate = 7, IsNaN = 8, IsInf = 9, IsFinite = 10, IsNormal = 11,
  Cos = 12, Sin = 13, Tan = 14, Acos = 15, Asin = 16, Atan = 17, Hcos = 18, Hsin = 19, Htan = 20, Exp = 21, Frc = 22,
  Log = 23, Sqrt = 24, Rsqrt = 25, Round_ne = 26, Round_ni = 27, Round_pi = 28, Round_z = 29, Bfrev = 30,
  Countbits = 31, FirstbitLo = 32, FirstbitHi = 33, FirstbitSHi = 34, FMax = 35, FMin = 36, IMax = 37, IMin = 38,
  UMax = 39, UMin = 40, IMul = 41, UMul = 42, UDiv = 43, UAddc = 44, USubb = 45, FMad = 46, Fma = 47, IMad = 48,
  UMad = 49, Msad = 50, Ibfe = 51, Ubfe = 52, Bfi = 53, Dot2 = 54, Dot3 = 55, Dot4 = 56, CreateHandle = 57,
  CBufferLoad = 58, CBufferLoadLegacy = 59, Sample = 60, SampleBias = 61, SampleLevel = 62, SampleGrad = 63,
  SampleCmp = 64, SampleCmpLevelZero = 65, TextureLoad = 66, TextureStore = 67, BufferLoad = 68, BufferStore = 69,
  BufferUpdateCounter = 70, CheckAccessFullyMapped = 71, GetDimensions = 72, TextureGather = 73, TextureGatherCmp = 74,
  AtomicBinOp = 78, AtomicCompareExchange = 79, Barrier = 80, CalculateLOD = 81, Discard = 82, DerivCoarseX = 83,
  DerivCoarseY = 84, DerivFineX = 85, DerivFineY = 86, SampleIndex = 90, Coverage = 91, ThreadId = 93, GroupId = 94,
  ThreadIdInGroup = 95, FlattenedThreadIdInGroup = 96, MakeDouble = 101, SplitDouble = 102, PrimitiveID = 108,
  WaveIsFirstLane = 110, WaveGetLaneIndex = 111, WaveGetLaneCount = 112, WaveAnyTrue = 113, WaveAllTrue = 114,
  WaveActiveAllEqual = 115, WaveActiveBallot = 116, WaveReadLaneAt = 117, WaveReadLaneFirst = 118, WaveActiveOp = 119,
  WaveActiveBit = 120, WavePrefixOp = 121, BitcastI16toF16 = 124, BitcastF16toI16 = 125, BitcastI32toF32 = 126,
  BitcastF32toI32 = 127, LegacyF32ToF16 = 130, LegacyF16ToF32 = 131, WaveAllBitCount = 135, WavePrefixBitCount = 136,
  RawBufferLoad = 139, RawBufferStore = 140, Dot2AddHalf = 162, Dot4AddI8Packed = 163, Dot4AddU8Packed = 164,
  AnnotateHandle = 216, CreateHandleFromBinding = 217, CreateHandleFromHeap = 218, IsHelperLane = 221
};
}

struct SignatureElement {
  uint32_t id;
  std::string name;                 // semantic name, e.g. "TEXCOORD"
  std::vector<uint32_t> semantic_indices;  // one per row
  ComponentType type;
  SemanticKind kind;
  Interpolation interpolation;
  uint32_t rows, cols;
  int32_t start_row;                // -1: system value that isn't packed
  int32_t start_col;
};

struct Resource {
  uint32_t id;                      // the range ID (createHandle's rangeId; our RangeId)
  ResourceClass cls;
  ResourceKind kind;
  uint32_t space, lower_bound, size;  // size ~0u = unbounded
  ComponentType element_type = ComponentType::Invalid;  // typed textures and buffers
  uint32_t stride = 0;              // structured buffers
  bool globally_coherent = false, has_counter = false, rasterizer_ordered = false, comparison_sampler = false;
};

struct EntryInfo {
  ShaderKind kind = ShaderKind::Invalid;
  uint32_t sm_major = 0, sm_minor = 0;
  std::string name;
  uint32_t numthreads[3] = {0, 0, 0};
  std::vector<SignatureElement> inputs, outputs;
  std::vector<Resource> resources;  // all four classes
};

struct DXILShader {
  std::vector<char> bitcode;        // the DXIL part's bitcode, parsed again in every SM50Compile (per-compile contexts)
  EntryInfo entry;
};

} // namespace dxmt::dxil
```

- [ ] **Step 3: Container and metadata reader**

`dxil_container.hpp/.cpp`:
```cpp
namespace dxmt::dxil {
struct Container { const char *bitcode; size_t bitcode_size; };
// The DXIL part's bitcode, std::nullopt for a DXBC container, or an error for a malformed DXIL part.
llvm::Expected<std::optional<Container>> FindDXIL(const void *bytecode, size_t size);
}
```
```cpp
llvm::Expected<std::optional<Container>> FindDXIL(const void *bytecode, size_t size) {
  microsoft::CDXBCParser parser;
  if (FAILED(parser.ReadDXBC(bytecode, (UINT32)size)))
    return std::nullopt;  // the DXBC path reports its own error
  UINT32 index = parser.FindNextMatchingBlob(microsoft::DXBC_DXIL);
  if (index == DXBC_BLOB_NOT_FOUND)
    return std::nullopt;
  auto part = static_cast<const char *>(parser.GetBlob(index));
  size_t part_size = parser.GetBlobSize(index);
  // DxilProgramHeader: ProgramVersion, SizeInUint32, then DxilBitcodeHeader: "DXIL", DxilVersion, BitcodeOffset, BitcodeSize.
  uint32_t header[6];
  if (part_size < sizeof(header))
    return llvm::make_error<UnsupportedFeature>("DXIL: program header truncated");
  memcpy(header, part, sizeof(header));
  if (memcmp(part + 8, "DXIL", 4))
    return llvm::make_error<UnsupportedFeature>("DXIL: bad program header");
  uint64_t start = 8 + uint64_t(header[4]), length = header[5];
  if (length < 4 || start + length > part_size)
    return llvm::make_error<UnsupportedFeature>("DXIL: bitcode lies outside the DXIL part");
  return Container{part + start, (size_t)length};
}
```
(`UnsupportedFeature` is airconv's error type in `airconv_error.hpp`; use its existing constructor.)

`dxil_metadata.hpp/.cpp`:
```cpp
namespace dxmt::dxil {
// Parses bitcode into `context` (the caller sets typed pointers).
llvm::Expected<std::unique_ptr<llvm::Module>> LoadModule(llvm::LLVMContext &context, const char *bitcode, size_t size);
llvm::Expected<EntryInfo> ReadEntry(const llvm::Module &module);
}
```
`ReadEntry` reads:
- **`!dx.shaderModel`** = `!{!{!"cs", i32 6, i32 6}}`: the stage from the string (`ps`, `vs`, `gs`, `hs`, `ds`, `cs`, `lib`), and the major and minor versions.
- **`!dx.entryPoints`**, operand 0 = `!{void ()* @main, !"main", !sigs, !resources, !props}`:
  - **`!sigs`** = `!{!inputs, !outputs, !patchconst}`, each null or a list of elements.
    - An element is `!{i32 ID, !"Name", i8 CompType, i8 SemanticKind, !{i32 SemIdx...}, i8 Interp, i32 Rows, i8 Cols, i32 StartRow, i8 StartCol, ...}`.
    - Read every integer with `mdconst::extract<ConstantInt>(op)->getSExtValue()`, so the widths don't matter.
  - **`!resources`** = `!{!srvs, !uavs, !cbvs, !samplers}`, each null or a list:
    - SRV `!{i32 ID, ptr, !"name", i32 space, i32 LB, i32 size, i32 kind, i32 sampleCount, !extra}`;
    - UAV `!{i32 ID, ptr, !"name", i32 space, i32 LB, i32 size, i32 kind, i1 globallyCoherent, i1 hasCounter, i1 ROV, !extra}`;
    - CBV `!{i32 ID, ptr, !"name", i32 space, i32 LB, i32 size, i32 sizeInBytes, !extra}`;
    - sampler `!{i32 ID, ptr, !"name", i32 space, i32 LB, i32 size, i32 samplerType(1 = comparison), !extra}`.
    - `!extra` is tag/value pairs: tag 0 is the element type, tag 1 the structured stride.
    - A size of `-1` means unbounded; store it as `~0u`.
  - **`!props`** is tag/value pairs; tag 4 is `NumThreads` `!{i32 x, i32 y, i32 z}`.

It returns `UnsupportedFeature("DXIL: <what> missing")` if `dx.entryPoints` or `dx.shaderModel` is absent.

- [ ] **Step 4: The DXIL branch of `SM50Initialize`**

In `dxbc_converter.hpp`, add to `SM50ShaderInternal` (and `#include "dxil/dxil_types.hpp"`):
```cpp
  /* set for a DXIL shader: then bbs/shader_type are unused and SM50Compile takes the DXIL path */
  std::shared_ptr<const dxmt::dxil::DXILShader> dxil;
```

In `dxbc_converter.cpp`'s `SM50Initialize`, before the SHEX/SHDR lookup (around line 1011):
```cpp
  auto dxil_container = dxmt::dxil::FindDXIL(pBytecode, BytecodeSize);
  if (!dxil_container) { /* malformed DXIL part */
    *ppError = /* build the error object exactly as the existing "shader blob not found" branch does, with
                  llvm::toString(dxil_container.takeError()) as the message */;
    return 1;
  }
  if (*dxil_container) {
    auto sm50_shader = new SM50ShaderInternal();
    if (auto err = dxmt::dxil::InitializeDXIL(**dxil_container, sm50_shader, pRefl)) {
      delete sm50_shader;
      *ppError = /* same, with llvm::toString(std::move(err)) */;
      return 1;
    }
    *ppShader = (sm50_shader_t)sm50_shader;
    return 0;
  }
```

`dxil_initialize.cpp`:
```cpp
llvm::Error InitializeDXIL(const Container &container, SM50ShaderInternal *shader, MTL_SHADER_REFLECTION *refl) {
  llvm::LLVMContext context;
  context.setOpaquePointers(false);
  auto module = LoadModule(context, container.bitcode, container.bitcode_size);
  if (!module) return module.takeError();
  auto entry = ReadEntry(**module);
  if (!entry) return entry.takeError();
  switch (entry->kind) {
  case ShaderKind::Vertex: shader->shader_type = microsoft::D3D10_SB_VERTEX_SHADER; break;
  case ShaderKind::Pixel: shader->shader_type = microsoft::D3D10_SB_PIXEL_SHADER; break;
  case ShaderKind::Compute: shader->shader_type = microsoft::D3D11_SB_COMPUTE_SHADER; break;
  default: return llvm::make_error<UnsupportedFeature>("DXIL: only vertex, pixel and compute shaders are supported");
  }
  FillResourceMaps(*entry, **module, shader->shader_info);                // below
  if (auto err = AddSignatureHandlers(*entry, **module, shader)) return err;  // dxil_signature.cpp
  if (entry->kind == ShaderKind::Compute) {
    std::copy(entry->numthreads, entry->numthreads + 3, shader->threadgroup_size);
    shader->func_signature.UseMaxWorkgroupSize(entry->numthreads[0] * entry->numthreads[1] * entry->numthreads[2]);
  }
  auto dxil = std::make_shared<DXILShader>();
  dxil->bitcode.assign(container.bitcode, container.bitcode + container.bitcode_size);
  dxil->entry = std::move(*entry);
  shader->dxil = dxil;
  if (refl) {
    *refl = {};
    refl->ConstanttBufferTableBindIndex = ~0u; refl->ArgumentBufferBindIndex = ~0u;
    if (shader->shader_type == microsoft::D3D11_SB_COMPUTE_SHADER)
      std::copy(shader->threadgroup_size, shader->threadgroup_size + 3, refl->ThreadgroupSize);
    if (shader->shader_type == microsoft::D3D10_SB_PIXEL_SHADER) {
      refl->PixelShader.ValidRenderTargets = shader->pso_valid_output_reg_mask;
      refl->PixelShader.HasCoverageOutput = shader->ps_has_coverage_output;
    }
    refl->NumOutputElement = shader->max_output_register;
  }
  return llvm::Error::success();
}
```

`FillResourceMaps` fills `shader_info.srvMap`, `uavMap`, `cbufferMap` and `samplerMap`, keyed by `Resource::id`, with the same structs the DXBC path uses (`ResourceRange{range_id = id, lower_bound, size, space}`):
- **Resource type:** `ResourceType` is set from `ResourceKind`, following the DXBC `dcl_resource` mapping in `dxbc_converter_cfg.cpp:325-487`:
  - `TypedBuffer` → typed-buffer type;
  - `RawBuffer` and `StructuredBuffer` → `ResourceType::NonApplicable`, with `structure_stride` = `stride` (0 for raw);
  - texture kinds → their counterparts.
- **Scalar type:** `scaler_type` comes from `element_type` (F32/F16/SNorm/UNorm → float, I32/I16 → sint, U32/U16 → uint).
- **Usage flags:** scan the module's `dx.op` calls once. For every call whose handle resolves to a resource (the same resolution as Step 6, run over metadata IDs):
  - `sample*`, `textureGather*` and `calculateLOD` set `sampled`;
  - `sampleCmp*` and `textureGatherCmp` set `compared`;
  - loads set `read`;
  - stores and atomics set `written`.
- **UAV extras:** `global_coherent`, `rasterizer_order` and `with_counter` come from the UAV metadata.

- [ ] **Step 5: Compute signature handlers**

`dxil_signature.cpp`, compute part. Compute IDs aren't signature elements, so the handlers come from the ops the module calls:
```cpp
llvm::Error AddSignatureHandlers(const EntryInfo &entry, const llvm::Module &module, SM50ShaderInternal *shader) {
  auto uses = [&](uint32_t opcode) { return ModuleCallsOp(module, opcode); };  // any dx.op.* call whose first arg == opcode
  if (entry.kind == ShaderKind::Compute) {
    // Same inputs and prologue assignments as handle_signature_cs (dxbc_signature.cpp:980-1056).
    if (uses(op::ThreadId)) {
      auto idx = shader->func_signature.DefineInput(air::InputThreadPositionInGrid{});
      shader->signature_handlers.push_back([=](SignatureContext &ctx) {
        ctx.prologue << make_effect_bind([=](struct context c) { c.resource.thread_id_arg = c.function->getArg(idx); return make_effect(std::monostate{}); });
      });
    }
    // ... likewise GroupId -> InputThreadgroupPositionInGrid (thread_group_id_arg),
    //     ThreadIdInGroup -> InputThreadPositionInThreadgroup (thread_id_in_group_arg),
    //     FlattenedThreadIdInGroup -> InputThreadIndexInThreadgroup (thread_id_in_group_flat_arg)
    return llvm::Error::success();
  }
  return AddGraphicsSignatureHandlers(entry, shader);  // Task 3; until then: UnsupportedFeature("DXIL: vertex/pixel shaders")
}
```
Copy the prologue-assignment lambdas from `handle_signature_cs` rather than paraphrasing them: `make_effect_bind` and friends are airconv's monad helpers.

- [ ] **Step 6: Lowering core, handles, buffers and constant buffers**

`dxil_lower.hpp`:
```cpp
namespace dxmt::dxil {
struct HandleInfo { ResourceClass cls; uint32_t range; llvm::Value *index; };  // index: the absolute register

class Lowering {
public:
  Lowering(const EntryInfo &entry, dxbc::context &ctx);  // ctx: the DXBC converter context (builder, air, binding, resource)
  // Replaces `call` (a dx.op.* call) and erases it; returns an UnsupportedFeature error naming the op if it has no lowering.
  llvm::Error Lower(llvm::CallInst *call);
  HandleInfo ResolveHandle(llvm::Value *handle);  // through annotateHandle; errors on phi/select
private:
  llvm::Error LowerResource(uint32_t opcode, llvm::CallInst *call);  // dxil_lower_resources.cpp
  llvm::Error LowerMath(uint32_t opcode, llvm::CallInst *call);      // dxil_lower_math.cpp
  llvm::Error LowerOther(uint32_t opcode, llvm::CallInst *call);     // dxil_lower.cpp: IO, IDs, control, wave
  const EntryInfo &entry;
  dxbc::context &ctx;
  llvm::DenseMap<llvm::Value *, HandleInfo> handles;
};
}
```

**Handle resolution.** `createHandle(57, i8 class, i32 rangeId, i32 index, i1)` gives `{class, rangeId, index}`. `createHandleFromBinding(217, %dx.types.ResBind {LB, UB, space, i8 class}, i32 index, i1)` looks up the `Resource` of that class and space whose `[lower_bound, lower_bound+size)` contains `LB`, and gives `{class, resource.id, index}`. `annotateHandle(216, h, props)` resolves to `h`. A handle that reaches a use through a phi or select returns `UnsupportedFeature("DXIL: resource handle through phi/select")`. `createHandleFromHeap(218, …)` returns `UnsupportedFeature("DXIL: dx.op.createHandleFromHeap (dynamic resources) not supported")`. Handle calls are erased after their uses are lowered.

**Result structs.** `%dx.types.ResRet.T` = `{T, T, T, T, i32}` and `%dx.types.CBufRet.T` = `{T x 4}` (8 for 16-bit types). Build the replacement with `insertvalue` into `UndefValue::get(call->getType())` and `replaceAllUsesWith`; InstCombine folds the extracts.

**Lowerings for this step** (`dxil_lower_resources.cpp`):

| DXIL | Lowering |
|---|---|
| `cbufferLoadLegacy(59, h, row)` | `d = ctx.binding.GetConstantBuffer(air, h.range, h.index)`; `ptr = GEP(<4 x i32>, d->Pointer, {row, c})` for c in 0..3; `load i32`, bitcast to T (for f64, pair two i32; for 16-bit, split with shifts); no descriptor → zeros (as `nt/dxbc_converter_base.cpp:64-85`) |
| `cbufferLoad(58, h, byteOffset, align)` | Same, with `row = off >> 4`, `c = (off >> 2) & 3` |
| `rawBufferLoad(139, h, index, elementOffset, mask, align)` | Byte offset = raw buffers: `index`; structured: `index * stride + elementOffset`. `b = GetSRVBuffer`/`GetUAVBuffer`; per component set in `mask`: `load` from `CreateGEPInt32WithBoundCheck(b, (offset >> 2) + c)`, reproducing that helper's logic from the DXBC converter base (the bound comes from `b->Metadata`). Use `air.CreateDeviceCoherentLoad` when `b->GlobalCoherent`. 16-bit T: load the i32 and extract the half |
| `rawBufferStore(140, h, index, elementOffset, v0..v3, mask, align)` | Mirror image with `store`, or `CreateDeviceCoherentStore` |
| `bufferLoad(68, h, index, off)` | Kind `TypedBuffer`: `t = GetSRVTexture`/`GetUAVTexture` (kind `texture_buffer`), `air.CreateRead(tex, t->ResourceHandle, index, nullptr, nullptr, nullptr)`. Raw/structured (SM 6.0/6.1 form): as `rawBufferLoad` with mask 0xf |
| `bufferStore(69, h, index, off, v0..v3, mask)` | Typed: `air.CreateWrite(tex, handle, index, nullptr, nullptr, nullptr, vec4)`. Raw/structured: as `rawBufferStore` |
| `annotateHandle`, `createHandle*` | Resolved as above; erased after their uses |

**Math for this step** (`dxil_lower_math.cpp`):

| DXIL | Lowering |
|---|---|
| `unary.T`: FAbs 6, Saturate 7, Frc 22, Sqrt 24, Rsqrt 25, Round_ni 27, Round_pi 28, Round_z 29, Round_ne 26, Cos 12, Sin 13 | `air.CreateFPUnOp(fabs / saturate / fract / sqrt / rsqrt / floor / ceil / trunc / rint / cos / sin, x, /*FastVariant=*/false)` |
| Exp 21, Log 23 | `CreateFPUnOp(exp2 / log2, x, false)` (DXIL's Exp and Log are base 2) |
| Tan 14, Acos 15, Asin 16, Atan 17, Hcos 18, Hsin 19, Htan 20 | Call the AIR intrinsic for the precise variant by name. Get the exact names and signatures from `xcrun metal -S -emit-llvm -o - probe.metal` on a file calling `metal::precise::tan/acos/asin/atan/cosh/sinh/tanh` for float and half. Add them to `AIRBuilder` as `FPUnOp` members |
| `isSpecialFloat.T`: IsNaN 8, IsInf 9, IsFinite 10, IsNormal 11 | `CreateIsNaN`; inf: `fabs(x) == +inf`; finite: `fabs(x) < +inf`; normal: `fabs(x) >= FLT_MIN && fabs(x) < +inf` (fp compares) |
| `binary.T`: FMax 35, FMin 36 | `CreateFPBinOp(fmax/fmin, a, b, false)` |
| IMax 37, IMin 38, UMax 39, UMin 40 | `CreateIntBinOp(max/min, a, b, /*Signed=*/opcode == IMax or IMin)` |
| `binaryWithTwoOuts`: IMul 41, UMul 42 | `{hi, lo}`: widen to i64 (sext/zext), multiply, split |
| UDiv 43 | `{quotient, remainder}`: `udiv`/`urem`; divisor 0 gives `~0u` for both (D3D semantics): `select` |
| `binaryWithCarryOrBorrow`: UAddc 44, USubb 45 | `llvm.uadd.with.overflow` / `llvm.usub.with.overflow` → `{result, zext carry}` |
| `tertiary.T`: FMad 46 | `fmul` + `fadd` (not fused, like D3D's mad) |
| Fma 47 | `air.CreateFMA` |
| IMad 48, UMad 49 | `mul` + `add` |
| Ibfe 51, Ubfe 52 | `(width, offset, value)`: width&31, offset&31; width==0 → 0; offset+width<32 → `shl` then `ashr`/`lshr`; else `ashr`/`lshr` by offset |
| `quaternary`: Bfi 53 | `(width, offset, insert, base)`: `mask = ((1<<w)-1)<<o`; `(base & ~mask) | ((insert<<o) & mask)`, width&31, offset&31 |
| `unaryBits`: Bfrev 30 | `CreateIntUnOp(reverse_bits)` |
| Countbits 31 | `CreateIntUnOp(popcount)` |
| FirstbitLo 32 | `x==0 ? ~0u : CreateCountZero(x, /*Trailing=*/true)` |
| FirstbitHi 33 | `x==0 ? ~0u : 31 - CreateCountZero(x, false)` |
| FirstbitSHi 34 | Same on `x < 0 ? ~x : x` |
| `dot2/3/4`: 54–56 | `air.CreateDotProduct` of vectors built from the scalar pairs |
| `legacyF32ToF16` 130 | `fptrunc` to half, bitcast to i16, `zext` i32 |
| `legacyF16ToF32` 131 | `trunc` i16, bitcast half, `fpext` |
| Bitcast 124–127 | `bitcast` |
| `makeDouble` 101, `splitDouble` 102 | `bitcast` via `<2 x i32>` |

- [ ] **Step 7: The converter and `SM50Compile`**

`dxil_converter.cpp`, `ConvertDXIL`:
```cpp
llvm::Expected<std::unique_ptr<llvm::Module>>
ConvertDXIL(SM50ShaderInternal *shader, const char *name, llvm::LLVMContext &context, SM50_SHADER_COMPILATION_ARGUMENT_DATA *pArgs) {
  auto &dxil = *shader->dxil;
  auto loaded = LoadModule(context, dxil.bitcode.data(), dxil.bitcode.size());
  if (!loaded) return loaded.takeError();
  auto module = std::move(*loaded);
  llvm::Function *dxil_main = module->getFunction(dxil.entry.name);
  // Drop everything DXIL-specific before the module becomes AIR.
  for (auto *md : {"dx.version", "dx.valver", "dx.shaderModel", "dx.resources", "dx.entryPoints", "dx.typeAnnotations",
                   "dx.viewIdState", "llvm.ident", "dx.source.contents", "dx.source.defines", "dx.source.mainFileName",
                   "dx.source.args"})
    if (auto *n = module->getNamedMetadata(md)) module->eraseNamedMetadata(n);
  initializeModule(*module);  // AIR triple, data layout, SDK version, module flags (airconv_context.cpp:40)
  // From here, mirror convert_dxbc_compute_shader (dxbc_converter.cpp:477-577) line by line, with these differences:
  //  - no setup_tgsm: DXIL groupshared are already addrspace(3) globals;
  //  - no setup_temp_register / setup_immediate_constant_buffer;
  //  - after CreateFunction and prologue.build(ctx), instead of convert_basicblocks:
  //      move dxil_main's blocks into the AIR function after `entry` (splice the basic-block list), branch from
  //      `entry` to the first moved block, and replace every `ret void` with `br epilogue_bb`;
  //      then collect every call to a function whose name starts with "dx.op." and run Lowering::Lower on each
  //      (collect first, then lower: lowering erases instructions);
  //  - erase dxil_main and every "dx.op.*" declaration; rename remaining named struct types "dx.types.*" to "dxil.*".
  // Keep: COMMON/ROOT_SIGNATURE lookup, setup_binding_rootsig (or setup_binding_table2 without a root signature),
  // setup_metal_version, the AIRBuilder options, epilogue construction and the air.kernel metadata.
  // Finally run llvm::verifyModule(*module, &errs) and return UnsupportedFeature("DXIL: " + message) on failure.
  return module;
}
```

In `SM50Compile` (`dxbc_converter.cpp:1344-1402`), after `context.setOpaquePointers(false);`:
```cpp
  if (sm50_shader->dxil) {
    auto converted = dxmt::dxil::ConvertDXIL(sm50_shader, FunctionName, context, pArgs);
    if (!converted) { /* report exactly as the existing handleAllErrors(UnsupportedFeature) branch does */ return 1; }
    pModule = std::move(*converted);  // then fall through to linkMSAD/linkSamplePos, runOptimizationPasses, MetallibWriter
  } else { /* existing convertDXBC call */ }
```

Add every new `.cpp` to `airconv_src` in `src/airconv/meson.build`.

In `src/d3d12/d3d12_pipeline_graphics.cpp`, delete the two lines that return `E_NOTIMPL` for a `DXBC_DXIL` part in `InitializeShader`.

- [ ] **Step 8: Build, pin, check**

```bash
git -C build/dxmt-src/dxmt add -A src/airconv src/d3d12
git -C build/dxmt-src/dxmt commit -m "airconv: DXIL front end, compute path (buffers, constant buffers, math)

MacNeutron fork only; never proposed upstream.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
Pin the new commit in `dxmt/pins`, then:

Run: `make dxmt > build/dxmt-make.log 2>&1; tail -1 build/dxmt-make.log; sh dxmt/check.sh 2>&1 | grep -E "^(ok|FAIL)"`
Expected:
- `ok` for `DXIL buffers/math/transcendental matches D3DMetal`, the 8-thread check, `DXIL pipelines are created` (both graphics and compute) and `an out-of-scope DXIL op fails only its pipeline`;
- still FAIL for `textures`, `groupshared`, `wave`, `half`, `packed` (Task 4). The graphics pipeline may still fail until Task 3; if it does, the "pipelines are created" check waits for Task 3 (ledger it);
- every pre-existing check `ok`.

If a group differs, `compare.py` names the first differing word: word `i` is thread `i / 16`, slot `i % 16` of the group's `.hlsl`. Fix the lowering for that slot's operation.

Also add to `dxmt/check.sh` item 3:
```sh
expect "the unsupported op is named in the log" "$(grep -c 'createHandleFromHeap' "$WORK/dxil.txt" || true)" 1
```
This needs `MACNEUTRON_LOG=1` in that run's environment, so `DXMT`'s `ERR` reaches the output: add it to the `dxil()` helper's `run` call.

- [ ] **Step 9: Push the fork, commit MacNeutron**

```bash
git -C build/dxmt-src/dxmt push origin macneutron
git add dxmt/pins dxmt/tests/d3d12_dxil.cpp dxmt/check.sh
git commit -m "feat(dxil): compute shaders translate (fork <short hash>)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Vertex and pixel shaders (`d3d12_triangle` matches D3DMetal)

**Files:**
- Fork:
  - `src/airconv/dxil/dxil_signature.cpp` (graphics handlers);
  - `dxil_lower.cpp` (`loadInput`, `storeOutput`, pixel system values, `discard`, derivatives, `sampleIndex`, `coverage`);
  - `dxil_lower_resources.cpp` (sampling);
  - `src/d3d12/d3d12_pipeline_graphics.cpp` (`ref_ps` ordering).
- MacNeutron: create `dxmt/tests/shaders/triangle2.hlsl` and `dxmt/tests/d3d12_triangle.cpp`; modify `compile.sh`, `Makefile`, `check.sh`.

**Interfaces:**
- Consumes: `Lowering`, `ResolveHandle`, `AddSignatureHandlers` (Task 2).
- Produces:
  - `const SignatureElement *FindElement(const std::vector<SignatureElement> &, uint32_t id)`;
  - the varying naming rule `UserName(element, row)` = `name + std::to_string(semantic_indices[row])`, upper-cased, e.g. `TEXCOORD0`;
  - `d3d12_triangle.exe <vs.dxil> <ps.dxil>` prints `triangle ok <checksum> <8 pixels>` or `triangle fail 0x<hr>`.

- [ ] **Step 1: The render test (RED)**

`dxmt/tests/shaders/triangle2.hlsl`:
```hlsl
// Render test (DXIL translator plan, Task 3): constant buffer, texture sample, discard, an extra varying the PS ignores.
cbuffer Constants : register(b0) { float2 scale; float2 offset; };
Texture2D<float4> Tex : register(t0);
SamplerState Point : register(s0);
struct VSOut { float4 pos : SV_Position; float2 extra : TEXCOORD1; float2 uv : TEXCOORD0; };
VSOut vsmain(uint id : SV_VertexID) {
    VSOut o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.pos = float4((uv * float2(2, -2) + float2(-1, 1)) * scale + offset, 0, 1);
    o.extra = uv * 3;
    o.uv = uv;
    return o;
}
float4 psmain(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    if (uv.x > 0.9) discard;
    float4 t = Tex.Sample(Point, uv * 0.5);
    return float4(t.rgb * (1 - uv.y) + ddx(uv.x) * 8, 1);
}
```
Add to `compile.sh`:
```sh
cd "$HERE"
dxc -T vs_6_6 -E vsmain -Fo triangle2.vs.dxil triangle2.hlsl
dxc -T ps_6_6 -E psmain -Fo triangle2.ps.dxil triangle2.hlsl
```

`dxmt/tests/d3d12_triangle.cpp` (header comment as in `d3d12_dxil_exec.cpp`):
- **Resources:** device, queue and fence as before; a 64×64 `R8G8B8A8_UNORM` render target (default heap, `RENDER_TARGET`); a 2×2 `R8G8B8A8_UNORM` texture with texels red (255,0,0), green (0,255,0), blue (0,0,255) and white, uploaded with `CopyTextureRegion`.
- **Root signature:** root CBV `b0` (scale `(0.9, 0.9)`, offset `(0.05, -0.05)`); a table with SRV `t0`; static point sampler `s0`.
- **PSO:** the two DXIL files; `R8G8B8A8_UNORM`; no depth; triangle list.
- **Draw:** clear the target to (0, 0, 0, 1), draw 3 vertices, copy the target to a readback buffer.
- **Output:** `triangle ok <FNV-1a 64 of all pixels, 16 hex> <pixels at (8,8) (20,8) (40,8) (8,20) (20,20) (8,40) (30,30) (50,50), each %08x>`. On a failed `CreateGraphicsPipelineState`, print `triangle fail 0x%08lx`.

Add to `Makefile` `dxmt-tests`:
```make
	x86_64-w64-mingw32-g++ -O2 -static -s -std=c++17 -o build/dxmt-tests/d3d12_triangle.exe dxmt/tests/d3d12_triangle.cpp -ld3d12 -ldxgi
```
Add to `check.sh` after item 3b:
```sh
run ours tri-ours dxmt "$TESTS/d3d12_triangle.exe" "Z:$S/triangle2.vs.dxil" "Z:$S/triangle2.ps.dxil"
run ours tri-ref d3dmetal "$TESTS/d3d12_triangle.exe" "Z:$S/triangle2.vs.dxil" "Z:$S/triangle2.ps.dxil"
expect "DXIL triangle matches D3DMetal (8 pixels within 1/255)" "$(python3 - "$WORK/tri-ours.txt" "$WORK/tri-ref.txt" <<'PY'
import sys
def px(p):
    for l in open(p):
        s = l.split()
        if s[:2] == ["triangle", "ok"]: return [int(x, 16) for x in s[3:11]]
a, b = px(sys.argv[1]), px(sys.argv[2])
print("yes" if a and b and all(abs(((x >> k) & 255) - ((y >> k) & 255)) <= 1 for x, y in zip(a, b) for k in (0, 8, 16, 24)) else f"no {a} {b}")
PY
)" yes
```
Run: `sh dxmt/tests/shaders/compile.sh && make dxmt-tests && sh dxmt/check.sh 2>&1 | grep triangle`
Expected: `FAIL DXIL triangle matches D3DMetal`, since the translator rejects vertex and pixel shaders. `tri-ref.txt` has `triangle ok`.

- [ ] **Step 2: Graphics signature handlers**

`dxil_signature.cpp`, `AddGraphicsSignatureHandlers`. Mirror `handle_signature_vs`/`handle_signature_ps` (`dxbc_signature.cpp`) using the same helpers (`init_input_reg`, `init_input_reg_with_interpolation`, `pop_output_reg`, `pop_output_reg_fix_unorm`, `pop_output_reg_sanitize_pos`, `pull_vertex_input`), keyed by DXIL elements:

- **Register file.** For element `e` and row `r`, the register is `e.start_row + r` and the mask is `((1 << e.cols) - 1) << e.start_col`. `max_input_register` and `max_output_register` are the highest register + 1 (unpacked system values, `start_row == -1`, don't count).
- **Vertex shader inputs:**
  - arbitrary elements behave as `DCL_INPUT` (`dxbc_signature.cpp:120-155`): with `ctx.ia_layout`, `pull_vertex_input` for the element whose `reg` matches; without, `DefineInput(InputVertexStageIn{attribute = reg, type, name})` + `init_input_reg`;
  - `VertexID` and `InstanceID` come from `ctx.resource.vertex_id` and `instance_id`, computed in the prologue as `convert_dxbc_vertex_shader` does (`dxbc_converter.cpp:694-751`): copy that prologue.
- **Vertex shader outputs:**
  - arbitrary: `DefineOutput(OutputVertex{.user = UserName(e, r), .type = float4/int4/uint4 by component type})` + `epilogue >> pop_output_reg(reg, 0xf, idx)`. Always four components, so a pixel shader reading fewer still links;
  - `Position`: `OutputPosition` + `pop_output_reg_sanitize_pos`;
  - `ClipDistance`: fail with `UnsupportedFeature("DXIL: SV_ClipDistance")` unless the corpus needs it (Task 6).
- **Pixel shader inputs:**
  - arbitrary: `InputFragmentStageIn{.user = UserName(e, r), .type = the same float4/int4/uint4, .interpolation = from e.interpolation}` + `init_input_reg`, or `init_input_reg_with_interpolation` for sample/centroid (as `DCL_INPUT_PS` does);
  - `Position` → `InputPosition`;
  - `IsFrontFace` → `InputFrontFacing`;
  - `SampleIndex` → `InputSampleIndex`;
  - `PrimitiveID` → `InputPrimitiveID`;
  - `Coverage` → `InputInputCoverage`.
- **Pixel shader outputs:**
  - `Target` with semantic index n → `OutputRenderTarget{.index = n, .type from ctx.pixel_formats[n], or the element type}`; set `pso_valid_output_reg_mask |= 1 << n`; `pop_output_reg` or `_fix_unorm` from register `e.start_row`. Use n, not the register, as the render-target index;
  - `Depth`, `DepthLessEqual`, `DepthGreaterEqual` → `depth_output_reg` + `OutputDepth` (as `dxbc_signature.cpp:495-535`);
  - `Coverage` → `OutputCoverageMask`, `ps_has_coverage_output = 1`;
  - `StencilRef` → `OutputStencilRef`.

- [ ] **Step 3: IO and pixel-shader lowerings**

In `dxil_lower.cpp`, `LowerOther`:

| DXIL | Lowering |
|---|---|
| `loadInput(4, id, row, col, gsaxis)` | `e = FindElement(entry.inputs, id)`: VertexID/InstanceID → `ctx.resource.vertex_id` / `instance_id`; other unpacked SVs from their prologue values; otherwise load i32 at `GEP(res.input.ptr_int4, {0, e.start_row + row, e.start_col + col})` and bitcast to the call's type (16-bit: `trunc`) |
| `storeOutput(5, id, row, col, v)` | Depth → `store float` to `ctx.resource.depth_output_reg`; otherwise bitcast/extend `v` to i32 and store at `GEP(res.output.ptr_int4, {0, e.start_row + row, e.start_col + col})` |
| `discard(82, cond)` | `if (cond) air.CreateDiscard()` (split the block) |
| Unary DerivCoarseX/Y 83–84, DerivFineX/Y 85–86 | `air.CreateDerivative(x, /*YAxis=*/opcode == 84 or 86)` |
| `sampleIndex(90)`, `coverage(91)`, `primitiveID(108)` | The prologue values defined by the handlers |
| `isHelperLane(221)` | `air.simd_is_helper_thread` (name via `xcrun metal -S -emit-llvm` on `simd_is_helper_thread()`) |

In `dxil_lower_resources.cpp`:
- **Setup for every sampling op:** resolve the SRV and sampler handles; `t = ctx.binding.GetSRVTexture(air, …)`; `s = ctx.binding.GetSampler(air, …)`. The coordinate and array index are per texture kind, as `sample_l` builds them (`nt/dxbc_converter_base.cpp` around 1640–1667). Cube kinds use `s->CubeSamplerHandle`. The sampler's LOD bias comes from `s->Metadata` (low 32 bits as a float).
- **Offsets** are immediates in DXIL (constant i32 arguments). Pass them as `int32_t[3]`, and fail on non-constant offsets.

| DXIL | Lowering |
|---|---|
| `sample(60, …, clamp)` | `CreateSample(..., sample_bias{bias}, sample_min_lod_clamp{clamp})` with the sampler's bias; `clamp` undef → the plain overload |
| `sampleBias(61, …, bias, clamp)` | `sample_bias{bias + sampler bias}` |
| `sampleLevel(62, …, lod)` | `sample_level{lod + sampler bias}` |
| `sampleGrad(63, …, ddx0-2, ddy0-2, clamp)` | `CreateSampleGrad` with vectors from the used components |
| `sampleCmp(64, …, ref, clamp)` | `CreateSampleCmp(..., ref, offset, sample_bias{sampler bias}, min lod)` |
| `sampleCmpLevelZero(65, …, ref)` | `CreateSampleCmp(..., ref, offset, sample_level{0})` |
| `textureLoad(66, h, mipOrSample, c0, c1, c2, o0, o1, o2)` | `CreateRead(tex, handle, coord + offset, array index, sample index for MS kinds, mip level)` |
| `textureStore(67, h, c0, c1, c2, v0..v3, mask)` | `CreateWrite(tex, handle, pos, array index, nullptr, 0, vec4)` |
| `textureGather(73, …, o0, o1, channel)` | `CreateGather(..., offset, channel)` |
| `textureGatherCmp(74, …, channel, ref)` | `CreateGatherCompare(...)` |
| `getDimensions(72, h, mip)` | `%dx.types.Dimensions {w, h, d/array, mips}` from `CreateTextureQuery` (width, height, depth or array_length, num_mip_levels) per kind. Buffers: element count from the descriptor metadata, as the DXBC `resinfo`/`bufinfo` lowering does |
| `calculateLOD(81, …, clamped)` | `CreateCalculateLOD(...)`, `.first` if clamped else `.second` |

In the result structs, `ResRet`'s fifth field (status) is `i32 1` (fully mapped). `checkAccessFullyMapped(71, s)` → `s != 0`.

- [ ] **Step 4: Fix the `ref_ps` ordering**

In `d3d12_pipeline_graphics.cpp`, `InitializePSO` (called at line ~560) reads `ref_ps.PixelShader.HasCoverageOutput` before `ref_ps` is filled (line ~568). Move the `InitializePSO(...)` call after the pixel shader's `InitializeShader` block, so it reads a filled `ref_ps`.

- [ ] **Step 5: Build, check, commit, push**

Commit in the fork (`"airconv: DXIL vertex and pixel shaders; d3d12: read ref_ps after filling it"`), pin, then:

Run: `make dxmt > build/dxmt-make.log 2>&1; sh dxmt/check.sh 2>&1 | grep -E "^(ok|FAIL)"`
Expected: `ok DXIL triangle matches D3DMetal`, `ok DXIL pipelines are created`, and every earlier check `ok` except Task 4's groups.

If the pipeline fails to link varyings, compare the vertex output and pixel input names in `SM50Compile`'s module: `MACNEUTRON_LOG=1` plus the ERR text. Both must be `TEXCOORD0` float4.

```bash
git -C build/dxmt-src/dxmt push origin macneutron
git add dxmt/pins dxmt/tests/shaders/triangle2.hlsl dxmt/tests/shaders/triangle2.*.dxil dxmt/tests/shaders/compile.sh \
  dxmt/tests/d3d12_triangle.cpp dxmt/check.sh Makefile
git commit -m "feat(dxil): vertex and pixel shaders translate; triangle matches D3DMetal (fork <short hash>)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Textures in compute, groupshared, wave, 16-bit and packed ops (all behaviour groups green)

**Files:**
- Fork: `src/airconv/nt/air_builder.{hpp,cpp}` (simdgroup methods), `src/airconv/air_signature.{hpp,cpp}` (`InputThreadIndexInSimdgroup`, `InputThreadsPerSimdgroup`), `dxil_signature.cpp` (define them when the module calls wave ops), `dxil_lower.cpp` (barrier, atomics, wave), `dxil_lower_math.cpp` (16-bit, packed dots).
- MacNeutron: `dxmt/pins`.

**Interfaces:**
- Consumes: Tasks 2–3.
- Produces:
  - `AIRBuilder::CreateSimdReduce(SimdOp, Value*, bool Signed)`;
  - `CreateSimdPrefix(SimdOp, Value*, bool Signed)`;
  - `CreateSimdBallot(Value *Pred)`;
  - `CreateSimdBroadcast(Value*, Value *Lane)`;
  - `CreateSimdBroadcastFirst(Value*)`;
  - `CreateSimdAll/Any(Value*)`;
  - `CreateSimdIsFirst()`;
  - `CreateSimdLaneId()`;
  - `CreateSimdSize()`.

  Here `enum class SimdOp { Sum, Product, Min, Max, And, Or, Xor }`.

- [ ] **Step 1: Confirm which groups fail (RED)**

Run: `sh dxmt/check.sh 2>&1 | grep -E "DXIL (textures|groupshared|wave|half|packed)"`
Expected: FAIL for each, with `differ: … failed on ours` for groups whose ops have no lowering yet. `textures` may already partly pass through Task 3's lowerings.

- [ ] **Step 2: Get the AIR names of the simdgroup functions**

Create a scratch file (not committed):
```metal
#include <metal_stdlib>
using namespace metal;
kernel void k(device uint *o [[buffer(0)]], device float *f [[buffer(1)]], uint l [[thread_index_in_simdgroup]]) {
  uint v = o[l]; float x = f[l];
  o[0] = simd_sum(v); o[1] = simd_max(v); o[2] = simd_min(v); o[3] = simd_prefix_exclusive_sum(v);
  o[4] = simd_or(v); o[5] = simd_and(v); o[6] = simd_xor(v); o[7] = (uint)simd_ballot(v & 1);
  o[8] = simd_broadcast(v, 5); o[9] = simd_broadcast_first(v); o[10] = simd_all(v > 3); o[11] = simd_any(v == 7);
  o[12] = simd_is_first(); o[13] = simd_product(v); o[14] = (uint)simd_sum((int)v); f[0] = simd_sum(x);
  o[15] = simd_max((int)v); f[1] = simd_prefix_exclusive_sum(x); o[16] = simd_is_helper_thread();
}
```
Run: `xcrun -sdk macosx metal -S -emit-llvm -o - simd.metal | grep -E "declare .*air\.simd"`
Expected: one `declare` per function, for example `air.simd_sum.u.i32`. Copy the exact names and types into the new `AIRBuilder` methods. Each method builds the overload name from the value type with `getTypeOverloadSuffix(Type*, Signedness)`, as the existing methods do. Lane ID and size are function inputs (`thread_index_in_simdgroup`, `threads_per_simdgroup`). Add them as `air::InputThreadIndexInSimdgroup` / `InputThreadsPerSimdgroup` `FunctionInput`s, defined by the DXIL signature step whenever the module calls wave ops. Take their `air.*` argument attribute strings from the same listing.

- [ ] **Step 3: Lowerings**

| DXIL | Lowering |
|---|---|
| `barrier(80, mode)` | `mode & 1` (SyncThreadGroup) → execution barrier. `mode & 8` (TGSMFence) → `MemFlags::Threadgroup`. `mode & (2|4)` (UAV fence) → `MemFlags::Device | MemFlags::Texture`. Emit exactly like the DXBC `sync` lowering in `nt/dxbc_converter_base.cpp` (the `InstSync` handler: `CreateAtomicFence` when `SupportsNonExecutionBarrier()`, i.e. metal_version ≥ 320, and `CreateBarrier(flags)` otherwise) |
| `atomicBinOp(78, h, op, c0, c1, c2, v)` | Buffers: `air.CreateAtomicRMW(binop, gep, v)` on the i32 pointer. Textures: `CreateAtomicRMW(tex, …)`. Groupshared atomics are LLVM `atomicrmw` in DXIL already (keep). Ops 0–7 = Add, And, Or, Xor, IMin, IMax, UMin, UMax; 8 = Exchange |
| `atomicCompareExchange(79, …)` | `CreateAtomicCmpXchg` / `cmpxchg` |
| `waveIsFirstLane(110)` | `CreateSimdIsFirst()` |
| `waveGetLaneIndex(111)` | `CreateSimdLaneId()` |
| `waveGetLaneCount(112)` | `CreateSimdSize()` |
| `waveAnyTrue(113, c)` | `CreateSimdAny(c)` |
| `waveAllTrue(114, c)` | `CreateSimdAll(c)` |
| `waveActiveAllEqual(115, v)` | `v == CreateSimdBroadcastFirst(v)`, then `CreateSimdAll` |
| `waveActiveBallot(116, c)` | `%dx.types.fouri32 {lo32(ballot), hi32(ballot), 0, 0}`, from the 64-bit `simd_ballot` |
| `waveReadLaneAt(117, v, lane)` | `CreateSimdBroadcast(v, lane)`. Metal requires a uniform lane; if AIR rejects a non-constant one, use `simd_shuffle` (take its name from the listing) |
| `waveReadLaneFirst(118, v)` | `CreateSimdBroadcastFirst(v)` |
| `waveActiveOp(119, v, op, sign)` | op 0 Sum, 1 Product, 2 Min, 3 Max; sign 0 signed, 1 unsigned → `CreateSimdReduce` |
| `waveActiveBit(120, v, op)` | op 0 And, 1 Or, 2 Xor → `CreateSimdReduce` |
| `wavePrefixOp(121, v, op, sign)` | Sum/Product → `CreateSimdPrefix` (exclusive) |
| `waveAllBitCount(135, c)` | `popcount(ballot)` |
| `wavePrefixBitCount(136, c)` | `popcount(ballot & ((1ull << lane) - 1))` |
| 16-bit types | `half`/`i16` overloads use the same lowerings. Where an `AIRBuilder` helper only takes 32-bit values, `fpext`/`zext` in and `fptrunc`/`trunc` out |
| `dot4AddPacked(163 i8 / 164 u8, acc, a, b)` | `acc + Σ ext(byte_k(a)) * ext(byte_k(b))`, with `ashr`/`lshr` byte extraction for i8/u8 |
| `dot2AddHalf(162, acc, ax, ay, bx, by)` | `acc + fpext(ax)*fpext(bx) + fpext(ay)*fpext(by)` in float |

- [ ] **Step 4: Build, check, commit, push**

Commit in the fork (`"airconv: DXIL barriers, atomics, wave ops, 16-bit, packed dots"`), pin, `make dxmt`.

Run: `sh dxmt/check.sh 2>&1 | grep -E "^(ok|FAIL)"`
Expected: all eight `DXIL <group> matches D3DMetal` are `ok`, and so are the triangle and every earlier check.

```bash
git -C build/dxmt-src/dxmt push origin macneutron
git add dxmt/pins
git commit -m "feat(dxil): every behaviour group matches D3DMetal (fork <short hash>)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: The offline corpus tool (`dxil-translate`)

**Files:**
- Fork: create `src/airconv/dxil/dxil_public.h` and `dxil_passthrough.cpp`; modify `meson.build`.
- MacNeutron: create `dxmt/tools/dxil-translate.mm`; modify `dxmt/build.sh`, `Makefile`, `dxmt/check.sh`, `dxmt/tests/build_test.sh` (nothing new there beyond the probe rebuild rule).

**Interfaces:**
- Consumes: the whole DXIL path.
- Produces:
  - `extern "C" int DXILCompilePassThroughVertex(sm50_shader_t PixelShader, sm50_bitcode_t *ppBitcode, sm50_error_t *ppError)`, test-only, in `dxil_public.h`;
  - `build/dxmt/dxil-translate <folder>`, printing `ok <file> <stage> <ms>` or `fail <file> <reason>`, then `summary <ok>/<total> ok, mean <ms> ms, slowest <ms> ms <file>`;
  - `make dxil-corpus DIR=<folder>`.

- [ ] **Step 1: The check (RED)**

Add to `dxmt/check.sh` item 5:
```sh
"$DXMT/dxil-translate" "$ROOT/dxmt/tests/dxil" > "$WORK/translate.txt" 2>&1 || true
expect "dxil-translate accepts every behaviour shader but heap" "$(tail -1 "$WORK/translate.txt" | cut -d ' ' -f 2)" "8/9"
"$DXMT/dxil-translate" "$S" > "$WORK/translate-shaders.txt" 2>&1 || true
expect "dxil-translate accepts the test shaders" "$(tail -1 "$WORK/translate-shaders.txt" | cut -d ' ' -f 2)" "5/5"
```
Run: `sh dxmt/check.sh 2>&1 | grep dxil-translate`
Expected: two FAILs (the tool doesn't exist).

- [ ] **Step 2: The pass-through vertex API**

`dxil_public.h` (test-only; not included by `winemetal`):
```c
#pragma once
#include "airconv_public.h"
// Compiles a vertex function whose outputs are exactly `PixelShader`'s inputs (same names and types, zeros, plus a
// position), so a pixel shader can be put in a Metal pipeline on its own (dxil-translate). Test use only.
AIRCONV_API int DXILCompilePassThroughVertex(sm50_shader_t PixelShader, sm50_bitcode_t *ppBitcode, sm50_error_t *ppError);
```
`dxil_passthrough.cpp`:
- create a context and module (`setOpaquePointers(false)`, `initializeModule`);
- run a `FunctionSignatureBuilder` with `OutputPosition` and, for each arbitrary input element and row of the pixel shader, `OutputVertex{UserName(e, r), same type}`;
- `CreateFunction("vs_passthrough", …)`; return a struct of zeros with position (0, 0, 0, 1);
- add `air.vertex` metadata as `convert_dxbc_vertex_shader` does;
- `runOptimizationPasses`; `MetallibWriter` into an `SM50CompiledBitcodeInternal`.

It must use the same `UserName` and type rule as Task 3; call the shared function, don't copy it.

- [ ] **Step 3: `dxil-translate.mm`**

```objc
// dxil-translate <folder>: translates every .dxil in <folder> with airconv and hands it to Metal (DXIL translator
// plan, Task 5). Compute: a compute pipeline; vertex: a vertex pipeline with rasterization off; pixel: a render
// pipeline with a pass-through vertex function. The root signature comes from each shader's own resources.
#import <Metal/Metal.h>
#include "airconv_public.h"
#include "dxil/dxil_public.h"
```
The tool, in order:
1. **List** `<folder>/*.dxil`, sorted.
2. **Initialize:** `SM50Initialize`. On failure, print `fail <file> <message>` (`SM50GetErrorMessage`).
3. **Root signature.** Build a root signature 1.0 container from the shader's resources, one descriptor table per resource range: SRV/UAV/CBV ranges in one table, samplers in their own. The shader's resources come from `((SM50ShaderInternal *)shader)->dxil->entry.resources`; include `dxbc_converter.hpp`, since the tool is built against airconv's sources. The layout:
   - an `RTS0` part: header `{1, numParams, 24, 0, 0, 0}`;
   - parameters `{0 /*table*/, 0 /*all*/, payloadOffset}`;
   - tables `{numRanges, rangesOffset}`;
   - ranges `{type (SRV 0, UAV 1, CBV 2, SAMPLER 3), count (unbounded → 64), base, space, 0xffffffff}`;
   - wrapped in a DXBC container: `"DXBC"`, 16 zero bytes, `1`, total size, `1` part, offset `36`, then `"RTS0"`, size, data.
4. **Compile** with `COMMON{metal_version = 310}` → `ROOT_SIGNATURE`. For a vertex shader, add an `IA_INPUT_LAYOUT` with one `R32G32B32A32_FLOAT` element per input register, slot 0, offset 16×reg. For a pixel shader, add `PSO_PIXEL_SHADER` with `R8G8B8A8_UNORM` for every render target.
5. **Library:** `newLibraryWithData:` (dispatch data from the bitcode).
6. **Pipeline:** by stage:
   - compute: `newComputePipelineStateWithFunction:`;
   - vertex: a render pipeline with `rasterizationEnabled = NO`;
   - pixel: a render pipeline with `DXILCompilePassThroughVertex`'s function and the pixel function, colour attachments `RGBA8Unorm`.
7. **Report:** time steps 2–6 per file and print `ok <file> <vs|ps|cs> <ms>` or `fail <file> <reason>`: the airconv error, or the `NSError` description, first line.
8. **Summary:** `summary <ok>/<total> ok, mean <ms> ms, slowest <ms> ms <file>`. Exit 0 only when every file is ok.

In `dxmt/build.sh`, after `build_probe`, add a `build_translate` function mirroring it:
```sh
build_translate() {  # build_translate <folder>
  W="$SRC/win64"
  clang++ -arch x86_64 -std=c++20 -O1 -fno-rtti -fno-exceptions -fobjc-arc -I"$LLVM/include" -I"$SRC/dxmt/src/airconv" \
    -I"$SRC/dxmt/include" -I"$SRC/dxmt/libs" -I"$SRC/dxmt/include/native/windows" -I"$SRC/dxmt/include/native/directx" \
    "$ROOT/dxmt/tools/dxil-translate.mm" -o "$1/dxil-translate" \
    "$W/src/airconv/darwin/libairconv.a" "$W/libs/DXBCParser/libDXBCParserNative.a" \
    -L"$LLVM/lib" -lLLVMPasses -lLLVMTarget -lLLVMObjCARCOpts -lLLVMCoroutines -lLLVMipo -lLLVMInstrumentation -lLLVMVectorize -lLLVMLinker -lLLVMIRReader -lLLVMAsmParser -lLLVMFrontendOpenMP -lLLVMScalarOpts -lLLVMInstCombine -lLLVMAggressiveInstCombine -lLLVMTransformUtils -lLLVMBitWriter -lLLVMAnalysis -lLLVMProfileData -lLLVMSymbolize -lLLVMDebugInfoPDB -lLLVMDebugInfoMSF -lLLVMDebugInfoDWARF -lLLVMObject -lLLVMTextAPI -lLLVMMCParser -lLLVMMC -lLLVMDebugInfoCodeView -lLLVMBitReader -lLLVMCore -lLLVMRemarks -lLLVMBitstreamReader -lLLVMBinaryFormat -lLLVMSupport -lLLVMDemangle -lm -lz -lcurses -lxml2 \
    -framework Metal -framework Foundation > "$SRC/dxil-translate.log" 2>&1 || die "dxil-translate failed to build; see $SRC/dxil-translate.log"
}
```
The `-lLLVM*` list is `src/airconv/meson.build`'s `llvm_deps`, in order; update it if that list changes. Call it next to each `build_probe` call. Rebuild it in the up-to-date shortcut when `dxil-translate.mm` is newer, like the probe.

In `Makefile`, add `dxil-corpus` to `.PHONY` and:
```make
# Translate a folder of captured DXIL shaders offline (DIR=~/dxil-smite2); never commit a game's shaders.
dxil-corpus: dxmt
	build/dxmt/dxil-translate "$(DIR)"
```

- [ ] **Step 4: Build and check**

Commit in the fork (`"airconv: test-only pass-through vertex function for DXIL pixel shaders"`), pin, `make dxmt`.

Run: `sh dxmt/check.sh 2>&1 | grep -E "dxil-translate|^FAIL"`
Expected: both `dxil-translate` checks `ok`, with `heap.dxil` the one failure, and no other FAIL.

- [ ] **Step 5: Commit and push**

```bash
git -C build/dxmt-src/dxmt push origin macneutron
git add dxmt/pins dxmt/tools/dxil-translate.mm dxmt/build.sh Makefile dxmt/check.sh
git commit -m "feat(dxil): dxil-translate, the offline corpus tool (fork <short hash>)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: SMITE 2 corpus to 770/770

**Files:** fork `dxil_*.cpp` as needed; MacNeutron `dxmt/tests/dxil/*.hlsl` (new behaviour cases); `dxmt/pins`.

**Interfaces:** Consumes everything above. Produces `make dxil-corpus DIR=~/dxil-smite2` → `summary 770/770 ok`.

- [ ] **Step 1: The baseline (RED)**

Run: `make dxil-corpus DIR=~/dxil-smite2 > build/corpus.txt; tail -1 build/corpus.txt; grep '^fail' build/corpus.txt | cut -d ' ' -f 3- | sort | uniq -c | sort -rn | head -20`
Expected: a summary below 770/770 and a ranked list of failure reasons. Keep this output; the ledger records the counts.

- [ ] **Step 2: Work the list, most common failure first**

For each failure reason, in order of count:
1. **Understand it:** `build/dxmt/dxil-probe -S <one failing file>` shows the DXIL around the op.
2. **Test first:**
   - if the operation can run in a compute shader, add a case to the matching behaviour group (or a new group file plus its name in `compile.sh`, `d3d12_dxil_exec.cpp`'s group list and `check.sh`'s loop);
   - run `check.sh` and watch that group differ from D3DMetal (RED).
3. **Fix:** add or fix the lowering, following the patterns of Tasks 2–4. Unpacked system values, `ClipDistance`, extra sampling forms and 64-bit are the likely ones.
4. **Verify:** rerun `check.sh` (GREEN) and `make dxil-corpus DIR=~/dxil-smite2`.
5. **Commit:** in the fork (`"airconv: DXIL <op/feature>"`), pin, then commit MacNeutron.

Metal pipeline failures (not airconv errors) usually mean invalid AIR. Compare the module with what DXBC produces for a similar shader, then fix the lowering.

Out-of-scope features (geometry shader, `createHandleFromHeap`, 64-bit atomics) stay failures. The corpus goal is then "770 minus those", and each exception is a ledger ruling. The one SMITE 2 geometry shader is expected to be such an exception, so the gate becomes 769/770 with that ruling.

- [ ] **Step 3: Record**

Run: `make dxil-corpus DIR=~/dxil-smite2 | tail -1`
Expected: `summary 770/770 ok, mean <ms> ms, slowest <ms> ms <file>`, or 769/770 with the geometry-shader ruling.

Push the fork and commit MacNeutron.

---

### Task 7: SMITE 2 in capture mode and acceptance

**Files:** create `docs/testing/acceptance-dxil-translator.md`; modify `README.md` (Graphics section).

- [ ] **Step 1: Install and run**

`make app`, restart MacNeutron so it installs the pinned DXMT, and confirm `dxmt-version` matches the pin. Then ask the maintainer to:
- set SMITE 2's Graphics to "Default (DXMT)" with launch options `/usr/bin/env MACNEUTRON_LOG=1 DXMT_DXIL_DUMP=/Users/<them>/dxil-smite2 %command%`;
- launch it, wait until it stops, crashes or hangs, and quit it.

Record from Unreal's log (`…/compatdata/2437170/pfx/drive_c/users/crossover/AppData/Local/SMITE2Alpha/Saved/Logs/Hemingway.log`):
- the first fatal error, or the last `LogD3D12RHI` lines;
- how many pipelines were created: count `SM50Compile` successes in the MacNeutron game log if logged, otherwise the captures;
- any `DXIL:` errors in `~/Library/Logs/MacNeutron/steam-2437170.log`.

Then ask them to set Graphics back to "D3DMetal", clear the launch options, and confirm it plays.

- [ ] **Step 2: The acceptance record**

`docs/testing/acceptance-dxil-translator.md`:
```markdown
# DXIL translator (sub-project 2) acceptance

Spec: `docs/superpowers/specs/2026-09-29-macneutron-dxil-translator-design.md`.

1. `make dxmt-check`: <n>/<n> ok, including the 8 behaviour groups and the triangle against D3DMetal.
2. `make dxil-corpus DIR=~/dxil-smite2`: <ok>/770 ok; mean <ms> ms, slowest <ms> ms (<stage>). Exceptions: <list with rulings>.
3. SMITE 2 in capture mode on DXMT: got past pipeline creation (<n> pipelines); stopped at <where>, with <error>. This is sub-project 3's starting point.
4. SMITE 2 with Graphics: D3DMetal: <plays as before>.
```

In `README.md`'s Graphics section, replace the sentence about Shader Model 6 games not starting on DXMT with:
```markdown
DXMT now translates Shader Model 6 (DXIL) vertex, pixel and compute shaders, but its Direct3D 12 runtime is still
incomplete, so games with SM6 shaders, which covers most Unreal Engine 5 and recent titles, don't run on it yet. For
those, import GPTK and set **Graphics: D3DMetal** for the game in the Games window.
```

- [ ] **Step 3: Commit and push**

```bash
git add docs/testing/acceptance-dxil-translator.md README.md
git commit -m "docs: DXIL translator acceptance

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push
```
