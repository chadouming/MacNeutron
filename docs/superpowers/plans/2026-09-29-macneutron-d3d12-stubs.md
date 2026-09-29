# DXMT Fork, Sub-project 3 (first slice: D3D12 Stubs) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The D3D12 stubs in our DXMT fork that abort a game or quietly misbehave give D3DMetal's results instead: batch 1 (aborts and failures D3DMetal doesn't have), batch 2 (silent wrong behaviour), plus real GPU timestamps.

**Architecture:** Fixes in the fork's `src/d3d12` (and `winemetal` where Metal needs a new call), each proved by a D3D12 test program in MacNeutron's `dxmt/tests`. `check.sh` runs each program on our DXMT and on D3DMetal and compares their lines. Mechanisms favour Apple Silicon:
- no allocation per call;
- no split render passes;
- results resolved on the GPU;
- existing Metal objects reused.

**Tech Stack:** C++20 (fork), Objective-C (`winemetal` unix side), llvm-mingw Clang for every Windows binary, Microsoft DXC under Wine for test shaders, POSIX sh for `check.sh`.

**Spec:** `docs/superpowers/specs/2026-09-29-macneutron-d3d12-stubs-design.md`

## Global Constraints

- **Fork:** `github.com/chadouming/dxmt`, branch `macneutron`.
  - Never send anything upstream (DXMT refuses AI-authored contributions).
  - Before editing, run `git -C build/dxmt-src/dxmt switch macneutron`: `build.sh` leaves the clone detached.
  - Push the fork, then write the new head into `dxmt/pins` (`DXMT_COMMIT=`) before a MacNeutron commit.
- **Commit trailer:** every fork and MacNeutron commit ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **New fork files** carry the LGPL-2.1+ notice with `Copyright 2026 MacNeutron contributors`.
- **Reference:** D3DMetal on the same Mac, GPTK imported. Each test prints the same lines on both; `check.sh` compares them. The exceptions are the ours-only rules in `d3d12_api`'s `caps` line and in `d3d12_timestamp`.
- **Performance rules (spec §3.4):**
  - no allocation per call: staging comes from the command allocator's `AllocateTempBuffer`, and null resources and counter sample buffers are created once;
  - nothing splits a render pass;
  - resolves run on the GPU;
  - existing Metal objects are reused.
- **Capabilities:** `CheckFeatureSupport` reports DXMT's real capabilities. The return codes match D3DMetal's (spec §2.2).
- **Unchanged:**
  - no new `IMPLEMENT_ME`;
  - `SetStablePowerState` stays `E_NOTIMPL`;
  - depth bounds stay ignored.
- SMITE 2's captured files (`~/dxil-smite2`) never enter git.
- **Commits, a ruling on spec §6:** its "one MacNeutron commit per batch" is read as one pin per batch. Each task commits its tests to MacNeutron as it lands, and each batch ends with a commit that moves `dxmt/pins` (Tasks 5 and 10). Cost if wrong: more MacNeutron commits than the spec meant.
- **Out of scope** (spec, Scope: Out): `WriteBufferImmediate`, `ExecuteBundle`, `ResolveSubresourceRegion`, `SetSamplePositions`, `AtomicCopyBufferUINT*`, `SetPredication`, stream output, tiled resources, tessellation, raytracing, mesh shaders.

## Review Focus

- **Timestamps in a heap larger than one counter sample buffer** (4096 samples). A resolve across the boundary must return every value. Test: `d3d12_timestamp` uses a 5000-query heap, writes queries 4095 and 4096, and resolves 4094..4097 (Task 9).
- **A read-only depth view that is also sampled** in the same pass (Unreal's lighting pattern). Reads see the depth; nothing is written. Test: `d3d12_depth` pass 4 draws `psdepth` with the depth-read-only view bound (Task 6).
- **A reinterpreting copy of a sub-region at mip 1 with offsets.** Only that region changes. Test: `d3d12_copy` case `mip1` (Task 7).
- **A pipeline loaded from a library after the app released its own reference** is still valid. Test: `d3d12_api` `library load-after-release` (Task 5).
- **`SetEventOnMultipleFenceCompletion` with no event** (it waits on the CPU) **and with zero fences**. Neither hangs; both answer as D3DMetal. Test: `d3d12_api` `multifence wait` and `none` (Task 3).

---

## File Structure

**Fork (`build/dxmt-src/dxmt/src`):**
- `winemetal/winemetal.h`, `winemetal_thunks.h`, `winemetal_thunks.c`, `unix/winemetal_unix.c`, `Metal.hpp`:
  - `MTLSharedEvent_setWin32EventAtValues` (Task 3);
  - render-pass sample buffers, `MTLCommandBuffer_computeCommandEncoderWithSampleBuffers` and `MTLDevice_sampleTimestamps` (Task 9).
- `dxmt/dxmt_fence.hpp/.cpp`: `EventListener::setEventOnValues` (Task 3).
- `d3d12/d3d12_device.hpp`:
  - `MTLD3D12PipelineState::desc_hash` (Task 5);
  - `MTLD3D12QueryHeap` timestamp storage (Task 9);
  - `CreateClosedCommandList` and `CreatePipelineLibrary` declarations;
  - null-resource accessors (Task 8).
- `d3d12/d3d12_device.cpp`: Tasks 2, 3, 4, 5, 8 and 9 (device methods, `CheckFeatureSupport`, the pipeline stream parser as a function, null resources, timestamp frequency).
- `d3d12/d3d12_feature_data.hpp` (new, Task 4): the OPTIONS19 and OPTIONS21 structs llvm-mingw's header lacks.
- `d3d12/d3d12_pipeline_library.cpp` (new, Task 5): the pipeline library and description hashing.
- `d3d12/d3d12_command_list.cpp`:
  - markers, the `PreDraw` depth-view loop (Task 1);
  - `CreateClosedCommandList` (Task 2);
  - read-only views (Task 6);
  - reinterpreting copies (Task 7);
  - timestamps (Task 9).
- `d3d12/d3d12_pipeline_graphics.cpp`, `d3d12_pipeline_compute.cpp`: `GetCachedBlob` (Task 1), `desc_hash` (Task 5).
- `d3d12/d3d12_descriptor_heap.cpp`: null SRV and UAV descriptors (Task 8).
- `d3d12/d3d12_query_heap.cpp`, `d3d12_command_encoder.hpp`, `d3d12_command_queue.cpp`: timestamps (Task 9).
- `airconv/dxil/dxil_lower_resources.cpp`: null size queries, only if Task 8 finds D3DMetal reports 0.

**MacNeutron:**
- `dxmt/tests/run.sh` (new, Task 0): the dev loop. It rebuilds the fork incrementally, installs it into `check.sh`'s "ours" runtime clone and runs one test on both backends.
- `dxmt/tests/d3d12_common.hpp` (new, Task 0): helpers the new tests share.
- **Tests (new):**
  - `dxmt/tests/d3d12_api.cpp`: batch 1 (Tasks 1–5);
  - `dxmt/tests/d3d12_copy.cpp` (Task 7);
  - `dxmt/tests/d3d12_null.cpp` and `dxmt/tests/shaders/null.hlsl` (Task 8);
  - `dxmt/tests/d3d12_timestamp.cpp` (Task 9).
- `dxmt/tests/d3d12_depth.cpp`: read-only views (Task 6).
- `dxmt/tests/shaders/compile.sh`, `Makefile` (`dxmt-tests`), `dxmt/check.sh`.
- `docs/testing/acceptance-dxmt-d3d12-stubs.md` (new, Task 10).

---

### Task 0: Branch, dev loop and shared test helpers

**Files:**
- Create: `dxmt/tests/run.sh`, `dxmt/tests/d3d12_common.hpp`

**Interfaces:**
- Produces:
  - `sh dxmt/tests/run.sh <test> [args…]` rebuilds the fork, installs it and runs `build/dxmt-tests/<test>.exe args…` on our DXMT, then on D3DMetal. Each output line is prefixed `dxmt: ` or `d3dmetal: `. A 120 s alarm ends a hung run.
  - `d3d12_common.hpp`: `Gpu` (device, queue, allocator, open list, fence; `Submit()`, `Buffer()`, `Texture()`, `RootSignature()`, `Barrier()`), `Tex2D()`, `Load()`, `CHECK`.

- [ ] **Step 1: Branch.** MacNeutron: `git switch -c feat/d3d12-stubs` (from `feat/dxil-translator`, head `cccacb1`). Fork: `git -C build/dxmt-src/dxmt switch macneutron && git -C build/dxmt-src/dxmt status --short` shows a clean tree.

- [ ] **Step 2: Write `dxmt/tests/run.sh`**

```sh
#!/bin/sh
# Dev loop for the fork's D3D12 tests (check.sh runs them for real): rebuilds the fork incrementally, installs it
# into check.sh's "ours" runtime clone, and runs build/dxmt-tests/<test>.exe on our DXMT, then on D3DMetal.
#   sh dxmt/tests/run.sh <test> [args...]   (pass shader paths as Z:<absolute Mac path>)
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; SRC="$ROOT/build/dxmt-src"; WORK="${TMPDIR:-/tmp}/macneutron dxmt"
[ -x "$WORK/ours/bin/macneutron" ] || { echo "run.sh: run make dxmt-check once first (it creates $WORK/ours)"; exit 1; }
( PATH="$SRC/llvm-mingw/bin:$PATH"; ninja -C "$SRC/win64" > "$WORK/run-ninja.log" 2>&1 \
    && meson install -C "$SRC/win64" > "$WORK/run-install.log" 2>&1 ) \
  || { grep -E "error|Error" "$WORK/run-ninja.log" "$WORK/run-install.log" | head -20; exit 1; }
cp "$SRC"/win64-install/system32/*.dll "$SRC"/win64-install/x86_64-windows/*.dll "$ROOT/build/dxmt/x86_64-windows/"
cp "$SRC"/win64-install/x86_64-unix/* "$ROOT/build/dxmt/x86_64-unix/"
"$ROOT/.build/release/macneutron" install-dxmt --tool-dir "$WORK/ours" "$ROOT/build/dxmt" > /dev/null
make -C "$ROOT" -s dxmt-tests > /dev/null
test=$1; shift
for backend in dxmt d3dmetal; do
  env STEAM_COMPAT_DATA_PATH="$WORK/compat/ours" SteamAppId=0 MACNEUTRON_GRAPHICS=$backend \
      MACNEUTRON_NO_STEAM_BRIDGE=1 MACNEUTRON_NO_METALFX=1 ${RUN_ENV:-} \
      perl -e 'alarm 120; exec @ARGV' "$WORK/ours/bin/macneutron" launch waitforexitandrun \
      "$ROOT/build/dxmt-tests/$test.exe" "$@" 2>&1 | tr -d '\r' \
    | grep -E '^[a-z0-9-]+ ' | grep -vE '^(msync|err|warn|fixme):' | sed "s/^/$backend: /" || true
done
```

- [ ] **Step 3: Write `dxmt/tests/d3d12_common.hpp`**

```cpp
// Helpers shared by the D3D12 stub tests (d3d12_api, d3d12_copy, d3d12_null, d3d12_timestamp).
#pragma once
#define WIDL_EXPLICIT_AGGREGATE_RETURNS  // D3D12 methods that return structs: the MSVC ABI under mingw
#include <windows.h>
#include <d3d12.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#define CHECK(expr) do { HRESULT hr_ = (expr); if (FAILED(hr_)) { \
    printf("%s failed 0x%08lx\n", #expr, (unsigned long)hr_); exit(1); } } while (0)

inline std::vector<char> Load(const char *path) {
    std::vector<char> data;
    if (FILE *f = fopen(path, "rb")) {
        char buffer[4096]; size_t n;
        while ((n = fread(buffer, 1, sizeof buffer, f)) > 0) data.insert(data.end(), buffer, buffer + n);
        fclose(f);
    }
    return data;
}

inline D3D12_RESOURCE_DESC Tex2D(UINT w, UINT h, DXGI_FORMAT format, UINT16 mips = 1,
                                 D3D12_RESOURCE_FLAGS flags = D3D12_RESOURCE_FLAG_NONE, UINT16 array = 1) {
    D3D12_RESOURCE_DESC d = {};
    d.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D; d.Width = w; d.Height = h; d.DepthOrArraySize = array;
    d.MipLevels = mips; d.Format = format; d.SampleDesc.Count = 1; d.Flags = flags;
    return d;
}

struct Gpu {
    ID3D12Device *device = nullptr;
    ID3D12CommandQueue *queue = nullptr;
    ID3D12CommandAllocator *allocator = nullptr;
    ID3D12GraphicsCommandList *list = nullptr;
    ID3D12Fence *fence = nullptr;
    UINT64 value = 0;

    Gpu() {
        CHECK(D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device), (void **)&device));
        D3D12_COMMAND_QUEUE_DESC qd = {D3D12_COMMAND_LIST_TYPE_DIRECT};
        CHECK(device->CreateCommandQueue(&qd, __uuidof(ID3D12CommandQueue), (void **)&queue));
        CHECK(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, __uuidof(ID3D12CommandAllocator), (void **)&allocator));
        CHECK(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator, nullptr,
                                        __uuidof(ID3D12GraphicsCommandList), (void **)&list));
        CHECK(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, __uuidof(ID3D12Fence), (void **)&fence));
    }

    // Closes the list, runs it, waits (10 s at most) and reopens it.
    void Submit() {
        CHECK(list->Close());
        ID3D12CommandList *lists[] = {list};
        queue->ExecuteCommandLists(1, lists);
        CHECK(queue->Signal(fence, ++value));
        HANDLE done = CreateEventA(nullptr, FALSE, FALSE, nullptr);
        CHECK(fence->SetEventOnCompletion(value, done));
        if (WaitForSingleObject(done, 10000) != WAIT_OBJECT_0) { printf("fail timeout\n"); exit(1); }
        CloseHandle(done);
        CHECK(allocator->Reset());
        CHECK(list->Reset(allocator, nullptr));
    }

    ID3D12Resource *Buffer(D3D12_HEAP_TYPE type, UINT64 size, D3D12_RESOURCE_STATES state,
                           D3D12_RESOURCE_FLAGS flags = D3D12_RESOURCE_FLAG_NONE) {
        D3D12_RESOURCE_DESC d = {};
        d.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; d.Width = size; d.Height = 1; d.DepthOrArraySize = 1;
        d.MipLevels = 1; d.SampleDesc.Count = 1; d.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR; d.Flags = flags;
        D3D12_HEAP_PROPERTIES heap = {type};
        ID3D12Resource *r;
        CHECK(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &d, state, nullptr, __uuidof(ID3D12Resource), (void **)&r));
        return r;
    }

    ID3D12Resource *Texture(const D3D12_RESOURCE_DESC &desc, D3D12_RESOURCE_STATES state,
                            const D3D12_CLEAR_VALUE *clear = nullptr) {
        D3D12_HEAP_PROPERTIES heap = {D3D12_HEAP_TYPE_DEFAULT};
        ID3D12Resource *r;
        CHECK(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc, state, clear, __uuidof(ID3D12Resource), (void **)&r));
        return r;
    }

    ID3D12RootSignature *RootSignature(const D3D12_ROOT_SIGNATURE_DESC &desc) {
        ID3DBlob *blob = nullptr, *error = nullptr;
        CHECK(D3D12SerializeRootSignature(&desc, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &error));
        ID3D12RootSignature *root;
        CHECK(device->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(), __uuidof(ID3D12RootSignature), (void **)&root));
        return root;
    }

    void Barrier(ID3D12Resource *r, D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after) {
        D3D12_RESOURCE_BARRIER b = {};
        b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION; b.Transition.pResource = r;
        b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        b.Transition.StateBefore = before; b.Transition.StateAfter = after;
        list->ResourceBarrier(1, &b);
    }
};

// A root CBV b0 and a quad pipeline from shaders/depth.hlsl (vsmain, psmain) drawing to one RGBA8 target.
inline ID3D12PipelineState *QuadPipeline(Gpu &gpu, ID3D12RootSignature *root, const std::vector<char> &vs,
                                         const std::vector<char> &ps, D3D12_GRAPHICS_PIPELINE_STATE_DESC *out = nullptr) {
    D3D12_GRAPHICS_PIPELINE_STATE_DESC gd = {};
    gd.pRootSignature = root;
    gd.VS = {vs.data(), vs.size()};
    gd.PS = {ps.data(), ps.size()};
    gd.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    gd.SampleMask = UINT_MAX;
    gd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    gd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    gd.RasterizerState.DepthClipEnable = TRUE;
    gd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    gd.NumRenderTargets = 1;
    gd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
    gd.SampleDesc.Count = 1;
    if (out)
        *out = gd;
    ID3D12PipelineState *pso;
    CHECK(gpu.device->CreateGraphicsPipelineState(&gd, __uuidof(ID3D12PipelineState), (void **)&pso));
    return pso;
}

inline ID3D12RootSignature *CbvRootSignature(Gpu &gpu) {
    D3D12_ROOT_PARAMETER param = {};
    param.ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;
    D3D12_ROOT_SIGNATURE_DESC rd = {1, &param, 0, nullptr, D3D12_ROOT_SIGNATURE_FLAG_NONE};
    return gpu.RootSignature(rd);
}
```

- [ ] **Step 4: Make `run.sh` runnable and check it.** `chmod +x dxmt/tests/run.sh`, then run `sh dxmt/tests/run.sh d3d12_query "Z:$PWD/dxmt/tests/shaders/depth.vs.dxil" "Z:$PWD/dxmt/tests/shaders/depth.ps.dxil"`.
  Expected: `dxmt: query ok 256 64 0 1 320 128 64` and `d3dmetal: query ok 256 64 0 1 320 128 64`.

- [ ] **Step 5: Commit**

```bash
git add dxmt/tests/run.sh dxmt/tests/d3d12_common.hpp
git commit -m "test(dxmt): run.sh dev loop and shared D3D12 test helpers

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 1: `d3d12_api` test, event markers, `GetCachedBlob`, and the depth-view hang

**Files:**
- Create: `dxmt/tests/d3d12_api.cpp`
- Modify: `Makefile` (`dxmt-tests`), `dxmt/check.sh`
- Fork modify:
  - `src/d3d12/d3d12_command_list.cpp` (`BeginEvent`, `EndEvent`, `SetMarker`, the `while (dsv.ptr)` loop in `PreDraw`);
  - `src/d3d12/d3d12_pipeline_graphics.cpp` and `d3d12_pipeline_compute.cpp` (`GetCachedBlob`).

**Interfaces:**
- Produces:
  - `d3d12_api.exe <vs.dxil> <ps.dxil> [section]`, where section is one of `markers cachedblob nulldsv list1 heap1 residency multifence features library`, and all sections when omitted.
  - Output lines start with the section name. `check.sh` gains `same_lines <prefix>`, comparing the lines of `$WORK/api-ours.txt` and `$WORK/api-ref.txt` that start with the prefix.

- [ ] **Step 1: Write `dxmt/tests/d3d12_api.cpp`** (every section. Tasks 2–5 turn theirs green; this task, the first three)

```cpp
// Batch 1 of the D3D12 stubs spec: calls that aborted, hung or failed where D3DMetal succeeds.
//   d3d12_api.exe <vs.dxil> <ps.dxil> [section]   (shaders/depth.hlsl's vsmain and psmain)
// Each line starts with its section; check.sh compares them with D3DMetal's. "caps" is checked on our DXMT only.
#include "d3d12_common.hpp"
#include <string>

static Gpu *gpu;
static std::vector<char> vs, ps;
static const char *only;
static bool Section(const char *name) { return !only || !strcmp(only, name); }

static void Markers() {  // PIX-style events on a command list, then the list runs
    const char text[] = "event";
    gpu->list->BeginEvent(1, text, sizeof text);
    gpu->list->SetMarker(1, text, sizeof text);
    gpu->list->EndEvent();
    gpu->Submit();
    printf("markers ok\n");
}

static void CachedBlob(ID3D12RootSignature *root) {
    D3D12_GRAPHICS_PIPELINE_STATE_DESC gd;
    ID3D12PipelineState *pso = QuadPipeline(*gpu, root, vs, ps, &gd);
    ID3DBlob *blob = nullptr;
    HRESULT hr = pso->GetCachedBlob(&blob);
    HRESULT again = E_FAIL;
    if (blob) {
        gd.CachedPSO = {blob->GetBufferPointer(), blob->GetBufferSize()};
        ID3D12PipelineState *second = nullptr;
        again = gpu->device->CreateGraphicsPipelineState(&gd, __uuidof(ID3D12PipelineState), (void **)&second);
    }
    printf("cachedblob %08lx %zu %08lx\n", (unsigned long)hr, blob ? (size_t)blob->GetBufferSize() : (size_t)0,
           (unsigned long)again);
}

static void NullDsv(ID3D12RootSignature *root) {  // a depth view with no resource: the draw must finish
    ID3D12PipelineState *pso = QuadPipeline(*gpu, root, vs, ps);
    ID3D12DescriptorHeap *rtv_heap, *dsv_heap;
    D3D12_DESCRIPTOR_HEAP_DESC rd = {D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 1}, dd = {D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 1};
    CHECK(gpu->device->CreateDescriptorHeap(&rd, __uuidof(ID3D12DescriptorHeap), (void **)&rtv_heap));
    CHECK(gpu->device->CreateDescriptorHeap(&dd, __uuidof(ID3D12DescriptorHeap), (void **)&dsv_heap));
    ID3D12Resource *target = gpu->Texture(Tex2D(16, 16, DXGI_FORMAT_R8G8B8A8_UNORM, 1, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET),
                                          D3D12_RESOURCE_STATE_RENDER_TARGET);
    auto rtv = rtv_heap->GetCPUDescriptorHandleForHeapStart(), dsv = dsv_heap->GetCPUDescriptorHandleForHeapStart();
    gpu->device->CreateRenderTargetView(target, nullptr, rtv);
    D3D12_DEPTH_STENCIL_VIEW_DESC dv = {DXGI_FORMAT_D32_FLOAT, D3D12_DSV_DIMENSION_TEXTURE2D};
    gpu->device->CreateDepthStencilView(nullptr, &dv, dsv);
    float draw[64] = {-1, -1, 1, 1, 1, 0, 0, 1, 0};
    ID3D12Resource *cb = gpu->Buffer(D3D12_HEAP_TYPE_UPLOAD, 256, D3D12_RESOURCE_STATE_GENERIC_READ);
    void *p; CHECK(cb->Map(0, nullptr, &p)); memcpy(p, draw, sizeof draw); cb->Unmap(0, nullptr);
    D3D12_VIEWPORT vp = {0, 0, 16, 16, 0, 1}; D3D12_RECT sc = {0, 0, 16, 16};
    gpu->list->OMSetRenderTargets(1, &rtv, FALSE, &dsv);
    gpu->list->RSSetViewports(1, &vp); gpu->list->RSSetScissorRects(1, &sc);
    gpu->list->SetGraphicsRootSignature(root); gpu->list->SetPipelineState(pso);
    gpu->list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    gpu->list->SetGraphicsRootConstantBufferView(0, cb->GetGPUVirtualAddress());
    gpu->list->DrawInstanced(6, 1, 0, 0);
    gpu->Submit();
    printf("nulldsv ok\n");
}

static void List1() {
    ID3D12Device4 *d4;
    CHECK(gpu->device->QueryInterface(__uuidof(ID3D12Device4), (void **)&d4));
    ID3D12GraphicsCommandList *list = nullptr;
    HRESULT hr = d4->CreateCommandList1(0, D3D12_COMMAND_LIST_TYPE_DIRECT, D3D12_COMMAND_LIST_FLAG_NONE,
                                        __uuidof(ID3D12GraphicsCommandList), (void **)&list);
    ID3D12CommandAllocator *allocator;
    CHECK(gpu->device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, __uuidof(ID3D12CommandAllocator), (void **)&allocator));
    HRESULT reset = list ? list->Reset(allocator, nullptr) : E_FAIL;
    HRESULT close = list ? list->Close() : E_FAIL;
    printf("list1 %08lx reset %08lx close %08lx\n", (unsigned long)hr, (unsigned long)reset, (unsigned long)close);
}

static void Heap1() {
    ID3D12Device4 *d4;
    CHECK(gpu->device->QueryInterface(__uuidof(ID3D12Device4), (void **)&d4));
    D3D12_HEAP_DESC hd = {65536, {D3D12_HEAP_TYPE_DEFAULT}, 0, D3D12_HEAP_FLAG_ALLOW_ONLY_BUFFERS};
    ID3D12Heap *heap = nullptr;
    printf("heap1 %08lx\n", (unsigned long)d4->CreateHeap1(&hd, nullptr, __uuidof(ID3D12Heap), (void **)&heap));
}

static void Residency() {
    ID3D12Device1 *d1; ID3D12Device3 *d3;
    CHECK(gpu->device->QueryInterface(__uuidof(ID3D12Device1), (void **)&d1));
    CHECK(gpu->device->QueryInterface(__uuidof(ID3D12Device3), (void **)&d3));
    ID3D12Fence *fence;
    CHECK(gpu->device->CreateFence(0, D3D12_FENCE_FLAG_NONE, __uuidof(ID3D12Fence), (void **)&fence));
    ID3D12Pageable *objects[] = {fence};
    D3D12_RESIDENCY_PRIORITY priority = D3D12_RESIDENCY_PRIORITY_NORMAL;
    HRESULT evict = gpu->device->Evict(1, objects), resident = gpu->device->MakeResident(1, objects);
    HRESULT prio = d1->SetResidencyPriority(1, objects, &priority);
    HRESULT enqueue = d3->EnqueueMakeResident(D3D12_RESIDENCY_FLAG_NONE, 1, objects, fence, 5);
    HANDLE e = CreateEventA(nullptr, FALSE, FALSE, nullptr);
    fence->SetEventOnCompletion(5, e);
    WaitForSingleObject(e, 1000);
    printf("residency evict %08lx resident %08lx priority %08lx enqueue %08lx fence %llu\n", (unsigned long)evict,
           (unsigned long)resident, (unsigned long)prio, (unsigned long)enqueue, (unsigned long long)fence->GetCompletedValue());
}

static void MultiFence() {
    ID3D12Device1 *d1;
    CHECK(gpu->device->QueryInterface(__uuidof(ID3D12Device1), (void **)&d1));
    ID3D12Fence *a, *b;
    CHECK(gpu->device->CreateFence(1, D3D12_FENCE_FLAG_NONE, __uuidof(ID3D12Fence), (void **)&a));  // done
    CHECK(gpu->device->CreateFence(0, D3D12_FENCE_FLAG_NONE, __uuidof(ID3D12Fence), (void **)&b));  // not yet
    ID3D12Fence *fences[] = {a, b};
    UINT64 values[] = {1, 1};
    HANDLE any = CreateEventA(nullptr, FALSE, FALSE, nullptr), all = CreateEventA(nullptr, FALSE, FALSE, nullptr);
    HRESULT hr_any = d1->SetEventOnMultipleFenceCompletion(fences, values, 2, D3D12_MULTIPLE_FENCE_WAIT_FLAG_ANY, any);
    int any_set = WaitForSingleObject(any, 1000) == WAIT_OBJECT_0;
    HRESULT hr_all = d1->SetEventOnMultipleFenceCompletion(fences, values, 2, D3D12_MULTIPLE_FENCE_WAIT_FLAG_ALL, all);
    int all_early = WaitForSingleObject(all, 200) == WAIT_OBJECT_0;
    CHECK(b->Signal(1));
    int all_late = WaitForSingleObject(all, 1000) == WAIT_OBJECT_0;
    HRESULT wait = d1->SetEventOnMultipleFenceCompletion(fences, values, 2, D3D12_MULTIPLE_FENCE_WAIT_FLAG_ALL, nullptr);
    HANDLE none = CreateEventA(nullptr, FALSE, FALSE, nullptr);
    HRESULT hr_none = d1->SetEventOnMultipleFenceCompletion(fences, values, 0, D3D12_MULTIPLE_FENCE_WAIT_FLAG_ALL, none);
    int none_set = WaitForSingleObject(none, 200) == WAIT_OBJECT_0;
    printf("multifence any %08lx %d all %08lx %d %d wait %08lx none %08lx %d\n", (unsigned long)hr_any, any_set,
           (unsigned long)hr_all, all_early, all_late, (unsigned long)wait, (unsigned long)hr_none, none_set);
}

template <typename T> static void Feature(int id) {
    T data = {};
    printf("feature %d %08lx\n", id, (unsigned long)gpu->device->CheckFeatureSupport((D3D12_FEATURE)id, &data, sizeof data));
}
struct Raw40 { UINT v[10]; };  // OPTIONS19 (48)
struct Raw16 { UINT v[4]; };   // OPTIONS21 (53)

static void Features() {
    Feature<D3D12_FEATURE_DATA_D3D12_OPTIONS>(0); Feature<D3D12_FEATURE_DATA_GPU_VIRTUAL_ADDRESS_SUPPORT>(6);
    Feature<D3D12_FEATURE_DATA_D3D12_OPTIONS1>(8); Feature<D3D12_FEATURE_DATA_PROTECTED_RESOURCE_SESSION_SUPPORT>(10);
    Feature<D3D12_FEATURE_DATA_ARCHITECTURE1>(16); Feature<D3D12_FEATURE_DATA_D3D12_OPTIONS2>(18);
    Feature<D3D12_FEATURE_DATA_SHADER_CACHE>(19); Feature<D3D12_FEATURE_DATA_D3D12_OPTIONS3>(21);
    Feature<D3D12_FEATURE_DATA_EXISTING_HEAPS>(22); Feature<D3D12_FEATURE_DATA_D3D12_OPTIONS4>(23);
    Feature<D3D12_FEATURE_DATA_CROSS_NODE>(25); Feature<D3D12_FEATURE_DATA_D3D12_OPTIONS5>(27);
    Feature<D3D12_FEATURE_DATA_DISPLAYABLE>(28); Feature<D3D12_FEATURE_DATA_D3D12_OPTIONS6>(30);
    Feature<D3D12_FEATURE_DATA_D3D12_OPTIONS7>(32); Feature<D3D12_FEATURE_DATA_D3D12_OPTIONS8>(36);
    Feature<D3D12_FEATURE_DATA_D3D12_OPTIONS9>(37); Feature<D3D12_FEATURE_DATA_D3D12_OPTIONS10>(39);
    Feature<D3D12_FEATURE_DATA_D3D12_OPTIONS11>(40); Feature<D3D12_FEATURE_DATA_D3D12_OPTIONS12>(41);
    Feature<D3D12_FEATURE_DATA_D3D12_OPTIONS13>(42); Feature<D3D12_FEATURE_DATA_D3D12_OPTIONS14>(43);
    Feature<D3D12_FEATURE_DATA_D3D12_OPTIONS15>(44); Feature<D3D12_FEATURE_DATA_D3D12_OPTIONS16>(45);
    Feature<D3D12_FEATURE_DATA_D3D12_OPTIONS17>(46); Feature<D3D12_FEATURE_DATA_D3D12_OPTIONS18>(47);
    Feature<Raw40>(48); Feature<Raw16>(53);
    // Our DXMT only (check.sh): no claim of what the fork lacks.
    D3D12_FEATURE_DATA_D3D12_OPTIONS5 o5 = {}; D3D12_FEATURE_DATA_D3D12_OPTIONS6 o6 = {};
    D3D12_FEATURE_DATA_D3D12_OPTIONS7 o7 = {};
    gpu->device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS5, &o5, sizeof o5);
    gpu->device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS6, &o6, sizeof o6);
    gpu->device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS7, &o7, sizeof o7);
    printf("caps rt=%d mesh=%d vrs=%d sfb=%d\n", (int)o5.RaytracingTier, (int)o7.MeshShaderTier,
           (int)o6.VariableShadingRateTier, (int)o7.SamplerFeedbackTier);
}

static void Library(ID3D12RootSignature *root) {
    ID3D12Device1 *d1;
    CHECK(gpu->device->QueryInterface(__uuidof(ID3D12Device1), (void **)&d1));
    D3D12_GRAPHICS_PIPELINE_STATE_DESC gd;
    ID3D12PipelineState *pso = QuadPipeline(*gpu, root, vs, ps, &gd), *got = nullptr;
    auto step = [](const char *name, HRESULT hr) { printf("library %s %08lx\n", name, (unsigned long)hr); };
    ID3D12PipelineLibrary *lib = nullptr;
    step("create", d1->CreatePipelineLibrary(nullptr, 0, __uuidof(ID3D12PipelineLibrary), (void **)&lib));
    if (!lib)
        return;
    step("load-missing", lib->LoadGraphicsPipeline(L"a", &gd, __uuidof(ID3D12PipelineState), (void **)&got));
    step("store", lib->StorePipeline(L"a", pso));
    step("store-again", lib->StorePipeline(L"a", pso));
    HRESULT hr = lib->LoadGraphicsPipeline(L"a", &gd, __uuidof(ID3D12PipelineState), (void **)&got);
    printf("library load-stored %08lx same %d\n", (unsigned long)hr, got == pso);
    if (got) got->Release();
    D3D12_GRAPHICS_PIPELINE_STATE_DESC other = gd;
    other.RTVFormats[0] = DXGI_FORMAT_R16G16B16A16_FLOAT;
    step("load-other", lib->LoadGraphicsPipeline(L"a", &other, __uuidof(ID3D12PipelineState), (void **)&got));
    pso->Release();  // the library still holds the stored pipeline
    got = nullptr;
    hr = lib->LoadGraphicsPipeline(L"a", &gd, __uuidof(ID3D12PipelineState), (void **)&got);
    printf("library load-after-release %08lx valid %d\n", (unsigned long)hr, got != nullptr);
    SIZE_T size = lib->GetSerializedSize();
    std::vector<char> blob(size);
    hr = lib->Serialize(blob.data(), size);
    printf("library serialize %08lx nonzero %d\n", (unsigned long)hr, size > 0);
    ID3D12PipelineLibrary *lib2 = nullptr;
    step("from-blob", d1->CreatePipelineLibrary(blob.data(), size, __uuidof(ID3D12PipelineLibrary), (void **)&lib2));
    if (lib2)
        step("load-from-blob", lib2->LoadGraphicsPipeline(L"a", &gd, __uuidof(ID3D12PipelineState), (void **)&got));
    char junk[64] = {1, 2, 3};
    step("junk", d1->CreatePipelineLibrary(junk, sizeof junk, __uuidof(ID3D12PipelineLibrary), (void **)&lib2));
}

int main(int argc, char **argv) {
    if (argc < 3) { printf("usage: d3d12_api.exe <vs.dxil> <ps.dxil> [section]\n"); return 2; }
    vs = Load(argv[1]); ps = Load(argv[2]); only = argc > 3 ? argv[3] : nullptr;
    if (vs.empty() || ps.empty()) { printf("can't read the shaders\n"); return 1; }
    gpu = new Gpu();
    ID3D12RootSignature *root = CbvRootSignature(*gpu);
    if (Section("features")) Features();
    if (Section("list1")) List1();
    if (Section("heap1")) Heap1();
    if (Section("residency")) Residency();
    if (Section("multifence")) MultiFence();
    if (Section("library")) Library(root);
    if (Section("markers")) Markers();
    if (Section("cachedblob")) CachedBlob(root);
    if (Section("nulldsv")) NullDsv(root);
    return 0;
}
```

- [ ] **Step 2: Build it.** Add to `Makefile`'s `dxmt-tests`, after the `d3d12_query` line:

```make
	$(MINGWXX) -std=c++17 -o build/dxmt-tests/d3d12_api.exe dxmt/tests/d3d12_api.cpp -ld3d12 -ldxgi
```

- [ ] **Step 3: Run the three sections RED.** `S="Z:$PWD/dxmt/tests/shaders"`, then for each of `markers`, `cachedblob`, `nulldsv`: `sh dxmt/tests/run.sh d3d12_api "$S/depth.vs.dxil" "$S/depth.ps.dxil" <section>`.
  - **Expected, our DXMT:**
    - `markers`: no `markers ok` line (`BeginEvent` aborts);
    - `cachedblob`: no line (`GetCachedBlob` aborts);
    - `nulldsv`: no line (the draw spins until the 120 s alarm).
  - **Expected, D3DMetal:** `markers ok`, `cachedblob 00000000 0 00000000`, `nulldsv ok`.

- [ ] **Step 4: Markers.** In the fork's `d3d12_command_list.cpp`, replace the three `IMPLEMENT_ME` bodies:

```cpp
  // Debugger annotations (PIX events): nothing to do here, as on the queue.
  void STDMETHODCALLTYPE SetMarker(UINT Metadata, const void *data, UINT size) {};

  void STDMETHODCALLTYPE BeginEvent(UINT Metadata, const void *data, UINT size) {};

  void STDMETHODCALLTYPE EndEvent() {};
```

- [ ] **Step 5: `GetCachedBlob`.** In `d3d12_pipeline_graphics.cpp` and `d3d12_pipeline_compute.cpp`, replace `IMPLEMENT_ME return E_NOTIMPL;` with the code below, and add `#include "../d3d10/d3d10_blob.hpp"` to both files.

```cpp
  virtual HRESULT STDMETHODCALLTYPE
  GetCachedBlob(ID3DBlob **blob) {
    // An empty blob, as D3DMetal: a CachedPSO is accepted and ignored at creation.
    if (!blob)
      return E_POINTER;
    return CreateBlobFromMalloc(0, blob);
  }
```

  If `CreateBlobFromMalloc` isn't visible in namespace `dxmt`, qualify it as `d3d10_blob.hpp` declares it.

- [ ] **Step 6: The depth-view loop.** In `PreDraw` (`d3d12_command_list.cpp`), the `while (dsv.ptr)` block `continue`s when the view has no texture, which re-tests `dsv.ptr` forever. Change that `continue` to `break`:

```cpp
        auto AttachmentDesc = Heap->GetRenderTarget(Index);
        if (!AttachmentDesc.Texture)
          break; // a null depth view: no depth attachment
```

- [ ] **Step 7: Run GREEN.** Run the three sections as in Step 3.
  Expected: our DXMT prints the same three lines as D3DMetal: `markers ok`, `cachedblob 00000000 0 00000000`, `nulldsv ok`.

- [ ] **Step 8: `check.sh`.** After the occlusion-query block, add:

```sh
# Batch 1 of the D3D12 stubs spec: calls that aborted, hung or failed where D3DMetal succeeds (d3d12_api).
run ours api-ours dxmt "$TESTS/d3d12_api.exe" "Z:$S/depth.vs.dxil" "Z:$S/depth.ps.dxil"
run ours api-ref d3dmetal "$TESTS/d3d12_api.exe" "Z:$S/depth.vs.dxil" "Z:$S/depth.ps.dxil"
same_lines() {  # same_lines <prefix>: d3d12_api's lines starting with <prefix> are the same on both, and present
  a=$(grep "^$1 " "$WORK/api-ours.txt" || true); b=$(grep "^$1 " "$WORK/api-ref.txt" || true)
  [ -n "$a" ] && [ "$a" = "$b" ] && echo yes || echo "no: ours [$a] D3DMetal [$b]"
}
for s in markers cachedblob nulldsv; do expect "d3d12_api $s answers as D3DMetal" "$(same_lines $s)" yes; done
```

  Only `IMPLEMENT_ME` aborts, so the other sections already run and print today's failure codes. `check.sh` compares just the sections done so far; Tasks 2–5 add theirs to the loop.

- [ ] **Step 9: Commit (fork, then MacNeutron)**

```bash
git -C build/dxmt-src/dxmt add src/d3d12/d3d12_command_list.cpp src/d3d12/d3d12_pipeline_graphics.cpp src/d3d12/d3d12_pipeline_compute.cpp
git -C build/dxmt-src/dxmt commit -m "d3d12: event markers, GetCachedBlob, a null depth view no longer hangs

Command-list BeginEvent/EndEvent/SetMarker and GetCachedBlob aborted the game (IMPLEMENT_ME); they do nothing
and return an empty blob, as D3DMetal. PreDraw spun forever on a depth view without a texture.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git add Makefile dxmt/check.sh dxmt/tests/d3d12_api.cpp
git commit -m "test(dxmt): d3d12_api, batch 1 of the D3D12 stubs (markers, cached blob, null depth view)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Residency, `EnqueueMakeResident`, `CreateCommandList1`, `CreateHeap1`

**Files:**
- Fork modify:
  - `src/d3d12/d3d12_device.cpp` (`Evict`, `SetResidencyPriority`, `EnqueueMakeResident`, `CreateCommandList1`, `CreateHeap1`);
  - `src/d3d12/d3d12_device.hpp` (`encoder_count` initial value, `CreateClosedCommandList` declaration);
  - `src/d3d12/d3d12_command_list.cpp` (`CreateClosedCommandList`).
- Modify: `dxmt/check.sh`

**Interfaces:**
- Produces: `HRESULT CreateClosedCommandList(MTLD3D12Device *pDevice, REFIID riid, void **ppCommandList);` in namespace `dxmt`.

- [ ] **Step 1: RED.** Run `sh dxmt/tests/run.sh d3d12_api "$S/depth.vs.dxil" "$S/depth.ps.dxil"` with each of `list1`, `heap1`, `residency`.
  - **Expected, our DXMT:**
    - `list1 80004001 reset 80004005 close 80004005`
    - `heap1 80004001`
    - `residency evict 80004001 resident 00000000 priority 80004001 enqueue 80004001 fence 0`
  - **Expected, D3DMetal:** `list1 00000000 reset 00000000 …`, `heap1 00000000`, `residency … enqueue 00000000 fence 5`.
  - Record D3DMetal's exact `list1` line in the ledger: our result must match it.

- [ ] **Step 2: Residency.** In `d3d12_device.cpp`:

```cpp
  // Unified memory never pages a resource out, and DXMT's residency sets keep heaps resident: residency calls do
  // nothing, as on D3DMetal.
  HRESULT STDMETHODCALLTYPE
  Evict(UINT ObjectCount, ID3D12Pageable *const *objects) {
    return S_OK;
  };
```

```cpp
  HRESULT STDMETHODCALLTYPE
  SetResidencyPriority(UINT ObjectCount, ID3D12Pageable *const *pObjects, const D3D12_RESIDENCY_PRIORITY *pPriorities) {
    return S_OK;
  };
```

```cpp
  HRESULT STDMETHODCALLTYPE
  EnqueueMakeResident(
      D3D12_RESIDENCY_FLAGS Flags, UINT NumObjects, ID3D12Pageable *const *ppObjects, ID3D12Fence *pFence,
      UINT64 FenceValue
  ) {
    if (!pFence)
      return E_INVALIDARG;
    return pFence->Signal(FenceValue); // already resident: the fence reaches the value at once
  }
```

- [ ] **Step 3: `CreateCommandList1`.**
  - In `d3d12_device.hpp`, give the list base's `size_t encoder_count;` (line 46) an initial value of 0: a list made closed has no recording.

```cpp
  size_t encoder_count = 0; // SIZE_MAX while recording
```

  - Add the declaration next to the other `Create*` free functions in `d3d12_device.hpp`:

```cpp
HRESULT CreateClosedCommandList(MTLD3D12Device *pDevice, REFIID riid, void **ppCommandList);
```

  - At the end of `d3d12_command_list.cpp`, next to `MTLD3D12CommandAllocatorImpl::CreateCommandList`:

```cpp
// ID3D12Device4::CreateCommandList1: a closed list with no allocator until its first Reset.
HRESULT
CreateClosedCommandList(MTLD3D12Device *pDevice, REFIID riid, void **ppCommandList) {
  auto cmd_list = Com(new MTLD3D12GraphicsCommandListImpl(pDevice));
  return cmd_list->QueryInterface(riid, ppCommandList);
}
```

  - In `d3d12_device.cpp`:

```cpp
  HRESULT STDMETHODCALLTYPE
  CreateCommandList1(
      UINT NodeMask, D3D12_COMMAND_LIST_TYPE Type, D3D12_COMMAND_LIST_FLAGS Flags, REFIID riid, void **ppCommandList
  ) {
    InitReturnPtr(ppCommandList);
    if (Type != D3D12_COMMAND_LIST_TYPE_DIRECT && Type != D3D12_COMMAND_LIST_TYPE_COMPUTE &&
        Type != D3D12_COMMAND_LIST_TYPE_COPY)
      return E_INVALIDARG;
    return CreateClosedCommandList(this, riid, ppCommandList);
  }
```

- [ ] **Step 4: `CreateHeap1`.**

```cpp
  HRESULT STDMETHODCALLTYPE
  CreateHeap1(const D3D12_HEAP_DESC *pDesc, ID3D12ProtectedResourceSession *pSession, REFIID riid, void **ppHeap) {
    if (pSession)
      return E_NOTIMPL; // protected sessions: none, as CreateCommittedResource1
    return CreateHeap(pDesc, riid, ppHeap);
  }
```

- [ ] **Step 5: GREEN.** Run the three sections again.
  Expected: each line equals D3DMetal's. If `list1`'s `close` differs (D3DMetal returned `S_OK` for `Close` on a closed list in the probe), rule on it in the ledger. D3D12 says `E_FAIL`, and matching D3DMetal means making `Close` on an unrecorded list return `S_OK`: `if (encoder_count == 0 && !allocator_) return S_OK;` at the top of `Close`.

- [ ] **Step 6: `check.sh`.** Extend the loop from Task 1 to `markers cachedblob nulldsv list1 heap1 residency`.

- [ ] **Step 7: Commit**

```bash
git -C build/dxmt-src/dxmt add src/d3d12/d3d12_device.cpp src/d3d12/d3d12_device.hpp src/d3d12/d3d12_command_list.cpp
git -C build/dxmt-src/dxmt commit -m "d3d12: residency calls, EnqueueMakeResident, CreateCommandList1, CreateHeap1

Evict, SetResidencyPriority and EnqueueMakeResident returned E_NOTIMPL; on unified memory they do nothing (the
fence reaches its value at once), as on D3DMetal. CreateCommandList1 makes a closed list; CreateHeap1 without a
protected session is CreateHeap.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git add dxmt/check.sh
git commit -m "test(dxmt): d3d12_api residency, CreateCommandList1, CreateHeap1

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `SetEventOnMultipleFenceCompletion`

**Files:**
- Fork modify:
  - `src/winemetal/winemetal.h`, `winemetal_thunks.h`, `winemetal_thunks.c`, `unix/winemetal_unix.c`;
  - `src/dxmt/dxmt_fence.hpp`, `dxmt_fence.cpp`;
  - `src/d3d12/d3d12_device.cpp`.
- Modify: `dxmt/check.sh`

**Interfaces:**
- Produces:
  - `WINEMETAL_API void MTLSharedEvent_setWin32EventAtValues(obj_handle_t shared_event_listener, const obj_handle_t *shared_events, const uint64_t *values, uint32_t count, uint32_t needed, obj_handle_t event_handle);`: the event is set once `needed` of the `count` shared events reach their values. Unix call 146.
  - `void EventListener::setEventOnValues(Fence const *const *fences, const uint64_t *values, uint32_t count, bool all, HANDLE event);`

- [ ] **Step 1: RED.** Run the `multifence` section.
  - Expected, our DXMT: `multifence any 80004001 0 all 80004001 0 0 wait 80004001 none 80004001 0`.
  - Expected, D3DMetal: `S_OK` codes, `any … 1`, `all … 0 1`. Record D3DMetal's full line.

- [ ] **Step 2: winemetal.**
  - In `winemetal_thunks.h`, next to `struct unixcall_mtlsharedevent_setevent`:

```c
struct unixcall_mtlsharedevent_seteventatvalues {
  obj_handle_t shared_event_listener;
  struct WMTConstMemoryPointer shared_events; // obj_handle_t[count]
  struct WMTConstMemoryPointer values;        // uint64_t[count]
  uint32_t count;
  uint32_t needed;
  obj_handle_t event_handle;
};
```

  - In `winemetal.h`, next to `MTLSharedEvent_setWin32EventAtValue`:

```c
// Sets the Win32 event once `needed` of the `count` shared events reach their values (all: count, any: 1).
WINEMETAL_API void MTLSharedEvent_setWin32EventAtValues(
    obj_handle_t shared_event_listener, const obj_handle_t *shared_events, const uint64_t *values, uint32_t count,
    uint32_t needed, obj_handle_t event_handle
);
```

  - In `winemetal_thunks.c` (after the last thunk, `MTLTexture_getBytes`):

```c
WINEMETAL_API void
MTLSharedEvent_setWin32EventAtValues(
    obj_handle_t shared_event_listener, const obj_handle_t *shared_events, const uint64_t *values, uint32_t count,
    uint32_t needed, obj_handle_t event_handle
) {
  struct unixcall_mtlsharedevent_seteventatvalues params;
  params.shared_event_listener = shared_event_listener;
  WMT_MEMPTR_SET(params.shared_events, shared_events);
  WMT_MEMPTR_SET(params.values, values);
  params.count = count;
  params.needed = needed;
  params.event_handle = event_handle;
  UNIX_CALL(146, &params);
}
```

  - In `unix/winemetal_unix.c`, after `_MTLSharedEvent_setWin32EventAtValue`, inside the same `#if` branch that has the listener:

```objc
static NTSTATUS
_MTLSharedEvent_setWin32EventAtValues(void *obj) {
  struct unixcall_mtlsharedevent_seteventatvalues *params = obj;
  shared_event_listener_t q = (shared_event_listener_t)params->shared_event_listener;
  const obj_handle_t *events = params->shared_events.ptr;
  const uint64_t *values = params->values.ptr;
  void *nt_event_handle = (void *)params->event_handle;
  // Counts notifications down on the listener's own queue: no thread. `refs` frees it after the last one.
  struct countdown {
    _Atomic uint32_t needed;
    _Atomic uint32_t refs;
  } *c = malloc(sizeof(*c));
  atomic_init(&c->needed, params->needed);
  atomic_init(&c->refs, params->count);
  for (uint32_t i = 0; i < params->count; i++) {
    [(id<MTLSharedEvent>)events[i]
        notifyListener:q->shared_listener
               atValue:values[i]
                 block:^(id<MTLSharedEvent> _e, uint64_t _v) {
                   while (!atomic_load_explicit(&q->runloop_ref, memory_order_acquire)) {
#if defined(__x86_64__)
                     _mm_pause();
#elif defined(__aarch64__)
                     __asm__ __volatile__("yield");
#endif
                   }
                   if (atomic_fetch_sub(&c->needed, 1) == 1) {
                     CFRunLoopPerformBlock(q->runloop_ref, kCFRunLoopCommonModes, ^{
                       NtSetEvent(nt_event_handle, NULL);
                     });
                     CFRunLoopWakeUp(q->runloop_ref);
                   }
                   if (atomic_fetch_sub(&c->refs, 1) == 1)
                     free(c);
                 }];
  }
  return STATUS_SUCCESS;
}
```

  - In the other `#else` branch (no listener), add a `nop` twin. Append `&_MTLSharedEvent_setWin32EventAtValues,` to the end of both `__wine_unix_call_funcs` and `__wine_unix_call_wow64_funcs` (index 146; `_MTLTexture_getBytes` is 145).

- [ ] **Step 3: `EventListener`.**
  - In `dxmt_fence.hpp`, declare:

```cpp
  void setEventOnValues(Fence const *const *fences, const uint64_t *values, uint32_t count, bool all, HANDLE event);
```

  - In `dxmt_fence.cpp`:

```cpp
void
EventListener::setEventOnValues(Fence const *const *fences, const uint64_t *values, uint32_t count, bool all, HANDLE event) {
  std::vector<obj_handle_t> events(count);
  for (uint32_t i = 0; i < count; i++)
    events[i] = fences[i]->sharedEvent().handle;
  MTLSharedEvent_setWin32EventAtValues(
      shared_event_listener_, events.data(), values, count, all ? count : 1, (obj_handle_t)event
  );
}
```

  (Add `#include <vector>`.)

- [ ] **Step 4: The device method** (`d3d12_device.cpp`)

```cpp
  HRESULT STDMETHODCALLTYPE
  SetEventOnMultipleFenceCompletion(
      ID3D12Fence *const *pFences, const UINT64 *pValues, UINT FenceCount, D3D12_MULTIPLE_FENCE_WAIT_FLAGS Flags,
      HANDLE hEvent
  ) {
    if (!FenceCount) {
      if (hEvent)
        SetEvent(hEvent);
      return S_OK;
    }
    if (!pFences || !pValues)
      return E_INVALIDARG;
    std::vector<Fence const *> fences(FenceCount);
    for (UINT i = 0; i < FenceCount; i++)
      fences[i] = static_cast<MTLD3D12Fence *>(pFences[i])->fence.ptr();
    bool all = Flags == D3D12_MULTIPLE_FENCE_WAIT_FLAG_ALL;
    // No event: wait here, as SetEventOnCompletion does.
    HANDLE event = hEvent ? hEvent : CreateEventW(nullptr, FALSE, FALSE, nullptr);
    event_listener.setEventOnValues(fences.data(), pValues, FenceCount, all, event);
    if (!hEvent) {
      WaitForSingleObject(event, INFINITE);
      CloseHandle(event);
    }
    return S_OK;
  };
```

  `MTLD3D12Fence` is declared in `d3d12_fence.cpp`. If it isn't visible from `d3d12_device.cpp`, add a small accessor to `d3d12_device.hpp`, `Fence *GetDXMTFence(ID3D12Fence *)`, implemented in `d3d12_fence.cpp`, and use it here.

- [ ] **Step 5: GREEN.** Run the `multifence` section.
  Expected: our DXMT's line equals D3DMetal's (for example `multifence any 00000000 1 all 00000000 0 1 wait 00000000 none 00000000 1`).

- [ ] **Step 6: `check.sh`.** Add `multifence` to the `same_lines` loop.

- [ ] **Step 7: Commit**

```bash
git -C build/dxmt-src/dxmt add src/winemetal src/dxmt/dxmt_fence.hpp src/dxmt/dxmt_fence.cpp src/d3d12/d3d12_device.cpp
git -C build/dxmt-src/dxmt commit -m "d3d12: SetEventOnMultipleFenceCompletion

Built on the shared-event listener SetEventOnCompletion uses: a winemetal call registers the event on each fence
and counts notifications down on the listener's run loop (all: every fence, any: the first), with no thread.
Without an event it waits, as SetEventOnCompletion does.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git add dxmt/check.sh
git commit -m "test(dxmt): d3d12_api multi-fence events

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `CheckFeatureSupport` answers what D3DMetal answers

**Files:**
- Fork create: `src/d3d12/d3d12_feature_data.hpp`
- Fork modify: `src/d3d12/d3d12_device.cpp` (`CheckFeatureSupport`)
- Modify: `dxmt/check.sh`

**Interfaces:**
- Produces: `D3D12_FEATURE_DATA_D3D12_OPTIONS19_MN` (40 bytes) and `D3D12_FEATURE_DATA_D3D12_OPTIONS21_MN` (16 bytes), plus feature values `kFeatureOptions19 = 48` and `kFeatureOptions21 = 53`.

- [ ] **Step 1: RED.** Run the `features` section.
  - **Expected, our DXMT:** `80004001` for 10, 22, 25, 27, 28, 30, 36, 39, 40, 42, 43, 44, 46, 47, 48 and 53; 37 too outside capture mode.
  - **Expected, D3DMetal:** `00000000` for all of them except 25 and 28 (`80070057`).
  
  `caps rt=0 mesh=0 vrs=0 sfb=0` on ours.

- [ ] **Step 2: `d3d12_feature_data.hpp`** (LGPL notice, `Copyright 2026 MacNeutron contributors`)

```cpp
#pragma once
// D3D12 option structs newer than llvm-mingw's d3d12.h, as the Agility SDK lays them out.
#include "d3d12.h"

namespace dxmt {

constexpr D3D12_FEATURE kFeatureOptions19 = (D3D12_FEATURE)48;
constexpr D3D12_FEATURE kFeatureOptions21 = (D3D12_FEATURE)53;

struct D3D12_FEATURE_DATA_D3D12_OPTIONS19_MN {
  BOOL MismatchingOutputDimensionsSupported;
  UINT SupportedSampleCountsWithNoOutputs;
  BOOL PointSamplingAddressesNeverRoundUp;
  BOOL RasterizerDesc2Supported;
  BOOL NarrowQuadrilateralLinesSupported;
  BOOL AnisoFilterWithPointMipSupported;
  UINT MaxSamplerDescriptorHeapSize;
  UINT MaxSamplerDescriptorHeapSizeWithStaticSamplers;
  UINT MaxViewDescriptorHeapSize;
  BOOL ComputeOnlyCustomHeapSupported;
};
static_assert(sizeof(D3D12_FEATURE_DATA_D3D12_OPTIONS19_MN) == 40);

struct D3D12_FEATURE_DATA_D3D12_OPTIONS21_MN {
  UINT WorkGraphsTier;         // D3D12_WORK_GRAPHS_TIER: 0, not supported
  UINT ExecuteIndirectTier;    // D3D12_EXECUTE_INDIRECT_TIER: 10, tier 1.0
  BOOL SampleCmpGradientAndBiasSupported;
  BOOL ExtendedCommandInfoSupported;
};
static_assert(sizeof(D3D12_FEATURE_DATA_D3D12_OPTIONS21_MN) == 16);

} // namespace dxmt
```

- [ ] **Step 3: The answers.** Include it in `d3d12_device.cpp`, then add cases before `default:`. Each validates the size as the existing cases do, then writes DXMT's own capabilities:

```cpp
#define FEATURE_DATA(T)                                                                                                \
  if (DataSize != sizeof(T))                                                                                           \
    return E_INVALIDARG;                                                                                               \
  auto *out = reinterpret_cast<T *>(pFeatureData);                                                                     \
  *out = {};
    case D3D12_FEATURE_PROTECTED_RESOURCE_SESSION_SUPPORT: {
      if (DataSize != sizeof(D3D12_FEATURE_DATA_PROTECTED_RESOURCE_SESSION_SUPPORT))
        return E_INVALIDARG;
      auto *out = reinterpret_cast<D3D12_FEATURE_DATA_PROTECTED_RESOURCE_SESSION_SUPPORT *>(pFeatureData);
      if (out->NodeIndex)
        return E_INVALIDARG;
      out->Support = D3D12_PROTECTED_RESOURCE_SESSION_SUPPORT_FLAG_NONE;
      return S_OK;
    }
    case D3D12_FEATURE_EXISTING_HEAPS: { // OpenExistingHeapFrom* are E_NOTIMPL
      FEATURE_DATA(D3D12_FEATURE_DATA_EXISTING_HEAPS)
      return S_OK;
    }
    case D3D12_FEATURE_CROSS_NODE:
    case D3D12_FEATURE_DISPLAYABLE:
      return E_INVALIDARG; // as D3DMetal
    case D3D12_FEATURE_D3D12_OPTIONS5: { // no raytracing, render passes tier 0
      FEATURE_DATA(D3D12_FEATURE_DATA_D3D12_OPTIONS5)
      out->RenderPassesTier = D3D12_RENDER_PASS_TIER_0;
      out->RaytracingTier = D3D12_RAYTRACING_TIER_NOT_SUPPORTED;
      return S_OK;
    }
    case D3D12_FEATURE_D3D12_OPTIONS6: { // no variable-rate shading
      FEATURE_DATA(D3D12_FEATURE_DATA_D3D12_OPTIONS6)
      return S_OK;
    }
    case D3D12_FEATURE_D3D12_OPTIONS8: {
      FEATURE_DATA(D3D12_FEATURE_DATA_D3D12_OPTIONS8)
      return S_OK;
    }
    case D3D12_FEATURE_D3D12_OPTIONS10: {
      FEATURE_DATA(D3D12_FEATURE_DATA_D3D12_OPTIONS10)
      return S_OK;
    }
    case D3D12_FEATURE_D3D12_OPTIONS11: {
      FEATURE_DATA(D3D12_FEATURE_DATA_D3D12_OPTIONS11)
      return S_OK;
    }
    case D3D12_FEATURE_D3D12_OPTIONS13: {
      FEATURE_DATA(D3D12_FEATURE_DATA_D3D12_OPTIONS13)
      return S_OK;
    }
    case D3D12_FEATURE_D3D12_OPTIONS14: {
      FEATURE_DATA(D3D12_FEATURE_DATA_D3D12_OPTIONS14)
      return S_OK;
    }
    case D3D12_FEATURE_D3D12_OPTIONS15: {
      FEATURE_DATA(D3D12_FEATURE_DATA_D3D12_OPTIONS15)
      return S_OK;
    }
    case D3D12_FEATURE_D3D12_OPTIONS17: {
      FEATURE_DATA(D3D12_FEATURE_DATA_D3D12_OPTIONS17)
      return S_OK;
    }
    case D3D12_FEATURE_D3D12_OPTIONS18: {
      FEATURE_DATA(D3D12_FEATURE_DATA_D3D12_OPTIONS18)
      return S_OK;
    }
    case kFeatureOptions19: {
      FEATURE_DATA(D3D12_FEATURE_DATA_D3D12_OPTIONS19_MN)
      out->MaxSamplerDescriptorHeapSize = 2048;
      out->MaxSamplerDescriptorHeapSizeWithStaticSamplers = 2048;
      out->MaxViewDescriptorHeapSize = 1000000;
      return S_OK;
    }
    case kFeatureOptions21: {
      FEATURE_DATA(D3D12_FEATURE_DATA_D3D12_OPTIONS21_MN)
      out->ExecuteIndirectTier = 10; // D3D12_EXECUTE_INDIRECT_TIER_1_0
      return S_OK;
    }
#undef FEATURE_DATA
```

  In the existing `D3D12_FEATURE_D3D12_OPTIONS9` case, drop `if (!DXILCaptureMode()) break;`. It answers always; the 64-bit atomics fields stay `DXILCaptureMode()`:

```cpp
      out->AtomicInt64OnTypedResourceSupported = DXILCaptureMode();
      out->AtomicInt64OnGroupSharedSupported = DXILCaptureMode();
```

- [ ] **Step 4: GREEN.** Run the `features` section.
  Expected: every `feature <id>` line equals D3DMetal's, and `caps rt=0 mesh=0 vrs=0 sfb=0` on ours.

- [ ] **Step 5: `check.sh`.** Add `feature` to the `same_lines` loop, then:

```sh
expect "our DXMT claims no raytracing, mesh shaders, VRS or sampler feedback" \
  "$(grep '^caps ' "$WORK/api-ours.txt" || true)" "caps rt=0 mesh=0 vrs=0 sfb=0"
```

- [ ] **Step 6: Commit**

```bash
git -C build/dxmt-src/dxmt add src/d3d12/d3d12_feature_data.hpp src/d3d12/d3d12_device.cpp
git -C build/dxmt-src/dxmt commit -m "d3d12: CheckFeatureSupport answers every query D3DMetal answers

OPTIONS5 to OPTIONS21, protected sessions and existing heaps returned E_NOTIMPL (SMITE 2 asks for five of them);
they answer S_OK with DXMT's own capabilities (no raytracing, mesh shaders, VRS or sampler feedback), and cross
node and displayable get E_INVALIDARG, as on D3DMetal. OPTIONS19 and 21 are newer than llvm-mingw's header.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git add dxmt/check.sh
git commit -m "test(dxmt): d3d12_api features

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Pipeline library (end of batch 1)

**Files:**
- Fork create: `src/d3d12/d3d12_pipeline_library.cpp` (add to `src/d3d12/meson.build`)
- Fork modify:
  - `src/d3d12/d3d12_device.hpp`: `MTLD3D12PipelineState::desc_hash`, and the `CreatePipelineLibrary`, `HashGraphicsDesc`, `HashComputeDesc` and `ParsePipelineStream` declarations;
  - `src/d3d12/d3d12_device.cpp`: `CreatePipelineLibrary`, and `CreatePipelineState` using `ParsePipelineStream`;
  - `src/d3d12/d3d12_pipeline_graphics.cpp`, `d3d12_pipeline_compute.cpp`: set `desc_hash`.
- Modify: `dxmt/check.sh`

**Interfaces:**
- Produces:
  - `uint64_t HashGraphicsDesc(const D3D12_GRAPHICS_PIPELINE_STATE_DESC &)` and `uint64_t HashComputeDesc(const D3D12_COMPUTE_PIPELINE_STATE_DESC &)`: stable within one DXMT build.
  - `HRESULT ParsePipelineStream(const D3D12_PIPELINE_STATE_STREAM_DESC *, D3D12_GRAPHICS_PIPELINE_STATE_DESC &, D3D12_COMPUTE_PIPELINE_STATE_DESC &, bool &compute)`.
  - `HRESULT CreatePipelineLibrary(MTLD3D12Device *, const void *blob, SIZE_T size, REFIID, void **)`.
  - `MTLD3D12PipelineState::desc_hash`.

- [ ] **Step 1: RED.** Run the `library` section.
  - Expected, our DXMT: `library create 80004001` only.
  - Expected, D3DMetal: `create 00000000`, `load-missing 80070057`, `store 00000000`, `store-again 80070057`, `load-stored 00000000 same 1`, `load-other 80070057`, `load-after-release …`, `serialize 00000000 nonzero 1`, `from-blob 00000000`, `load-from-blob 00000000`, `junk 887e0002`. Record D3DMetal's `load-after-release` line.

- [ ] **Step 2: Parse streams once.** In `d3d12_device.cpp`, move the body of `CreatePipelineState`, from the `desc_cs`/`desc_graphics` declarations to the end of the `while` loop (today's lines 885–1090), unchanged, into a free function above the device class:

```cpp
// Fills either description from a pipeline stream, with D3D12's defaults for what the stream leaves out.
HRESULT
ParsePipelineStream(
    const D3D12_PIPELINE_STATE_STREAM_DESC *pDesc, D3D12_GRAPHICS_PIPELINE_STATE_DESC &desc_graphics,
    D3D12_COMPUTE_PIPELINE_STATE_DESC &desc_cs, bool &compute
) {
  // ... the moved stream loop, returning its errors as before ...
  compute = desc_cs.CS.pShaderBytecode != nullptr;
  if (compute && (defined_type & ((1 << D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_VS) | (1 << D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_AS) |
                                  (1 << D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_MS)))) {
    ERR("CreatePipelineState: invalid compute pipeline state stream");
    return E_INVALIDARG;
  }
  return S_OK;
}
```

  `CreatePipelineState` becomes:

```cpp
  HRESULT STDMETHODCALLTYPE
  CreatePipelineState(const D3D12_PIPELINE_STATE_STREAM_DESC *pDesc, REFIID riid, void **ppPipelineState) {
    D3D12_COMPUTE_PIPELINE_STATE_DESC desc_cs{};
    D3D12_GRAPHICS_PIPELINE_STATE_DESC desc_graphics{};
    bool compute = false;
    HRESULT hr = ParsePipelineStream(pDesc, desc_graphics, desc_cs, compute);
    if (FAILED(hr))
      return hr;
    return compute ? CreateComputePipelineState(&desc_cs, riid, ppPipelineState)
                   : CreateGraphicsPipelineState(&desc_graphics, riid, ppPipelineState);
  }
```

  Build, then run `sh dxmt/tests/run.sh d3d12_depth …` (the depth test creates its pipelines from streams).
  Expected: `depth ok …` unchanged on our DXMT.

- [ ] **Step 3: Description hashes.**
  - Add `uint64_t desc_hash = 0;` to `MTLD3D12PipelineState` in `d3d12_device.hpp`, with the declarations from the Interfaces block.
  - In `d3d12_pipeline_library.cpp`, add the hashes:

```cpp
namespace {
// std::hash over bytes: fast, and stable within one DXMT build (a library serialized by another build no longer
// matches, and the app recreates its pipelines).
struct Hasher {
  uint64_t h = 0;
  void bytes(const void *p, size_t n) {
    h = h * 1099511628211ull ^ std::hash<std::string_view>{}(std::string_view((const char *)p, n));
  }
  template <typename T> void pod(const T &v) { bytes(&v, sizeof v); }
  void str(const char *s) { bytes(s ? s : "", s ? strlen(s) : 0); }
  void shader(const D3D12_SHADER_BYTECODE &b) { bytes(b.pShaderBytecode, b.pShaderBytecode ? b.BytecodeLength : 0); }
  void root(ID3D12RootSignature *rs) {
    const void *blob = nullptr;
    size_t size = rs ? static_cast<MTLD3D12RootSignature *>(rs)->GetBlob(&blob) : 0;
    bytes(blob, size);
  }
};
} // namespace

uint64_t
HashGraphicsDesc(const D3D12_GRAPHICS_PIPELINE_STATE_DESC &d) {
  Hasher x;
  x.root(d.pRootSignature);
  for (auto *s : {&d.VS, &d.PS, &d.DS, &d.HS, &d.GS})
    x.shader(*s);
  for (UINT i = 0; i < d.StreamOutput.NumEntries; i++) {
    auto &e = d.StreamOutput.pSODeclaration[i];
    x.str(e.SemanticName);
    x.pod(e.Stream); x.pod(e.SemanticIndex); x.pod(e.StartComponent); x.pod(e.ComponentCount); x.pod(e.OutputSlot);
  }
  x.bytes(d.StreamOutput.pBufferStrides, d.StreamOutput.NumStrides * sizeof(UINT));
  x.pod(d.StreamOutput.RasterizedStream);
  x.pod(d.BlendState); x.pod(d.SampleMask); x.pod(d.RasterizerState); x.pod(d.DepthStencilState);
  for (UINT i = 0; i < d.InputLayout.NumElements; i++) {
    auto &e = d.InputLayout.pInputElementDescs[i];
    x.str(e.SemanticName);
    x.pod(e.SemanticIndex); x.pod(e.Format); x.pod(e.InputSlot); x.pod(e.AlignedByteOffset);
    x.pod(e.InputSlotClass); x.pod(e.InstanceDataStepRate);
  }
  x.pod(d.IBStripCutValue); x.pod(d.PrimitiveTopologyType); x.pod(d.NumRenderTargets); x.pod(d.RTVFormats);
  x.pod(d.DSVFormat); x.pod(d.SampleDesc); x.pod(d.NodeMask); x.pod(d.Flags);
  return x.h;
}

uint64_t
HashComputeDesc(const D3D12_COMPUTE_PIPELINE_STATE_DESC &d) {
  Hasher x;
  x.root(d.pRootSignature);
  x.shader(d.CS);
  x.pod(d.NodeMask); x.pod(d.Flags);
  return x.h ^ 1; // never equal to a graphics description's
}
```

  - In `dxmt::CreateGraphicsPipelineState` and `dxmt::CreateComputePipelineState` (`d3d12_pipeline_graphics.cpp`, `d3d12_pipeline_compute.cpp`), set the hash on the new object before returning it: `pipeline->desc_hash = HashGraphicsDesc(*pDesc);` and `pipeline->desc_hash = HashComputeDesc(*pDesc);`. That's one hash per creation, a few microseconds, and no allocation.

- [ ] **Step 4: The library** (rest of `d3d12_pipeline_library.cpp`, LGPL notice)

```cpp
#include "d3d12_device.hpp"
#include "d3d12_device_child.hpp"
#include "com/com_pointer.hpp"
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <string_view>

namespace dxmt {

// ... Hasher, HashGraphicsDesc, HashComputeDesc (Step 3) ...

namespace {
constexpr char kMagic[8] = {'D', 'X', 'M', 'T', 'P', 'L', 'B', '1'};

class MTLD3D12PipelineLibraryImpl : public MTLD3D12DeviceChild<ID3D12PipelineLibrary1> {
  struct Entry {
    uint64_t hash;
    Com<ID3D12PipelineState> pso; // null for a name read from a serialized library until its first load
  };
  std::mutex mutex_;
  std::map<std::wstring, Entry> entries_;

  // A stored or serialized name with this description's hash: the pipeline, created on first load.
  HRESULT
  Load(LPCWSTR name, uint64_t hash, const std::function<HRESULT(ID3D12PipelineState **)> &create, REFIID riid, void **pp) {
    InitReturnPtr(pp);
    if (!name)
      return E_INVALIDARG;
    std::lock_guard lock(mutex_);
    auto it = entries_.find(name);
    if (it == entries_.end() || it->second.hash != hash)
      return E_INVALIDARG;
    if (!it->second.pso) {
      ID3D12PipelineState *pso = nullptr;
      HRESULT hr = create(&pso);
      if (FAILED(hr))
        return hr;
      it->second.pso = pso;
      pso->Release(); // the Com holds it
    }
    return it->second.pso->QueryInterface(riid, pp);
  }

public:
  MTLD3D12PipelineLibraryImpl(MTLD3D12Device *pDevice) : MTLD3D12DeviceChild<ID3D12PipelineLibrary1>(pDevice) {}

  HRESULT
  Initialize(const void *blob, SIZE_T size) {
    if (!blob || !size)
      return S_OK;
    auto p = static_cast<const char *>(blob), end = p + size;
    uint32_t version, count;
    if (size < 16 || memcmp(p, kMagic, 8))
      return D3D12_ERROR_DRIVER_VERSION_MISMATCH;
    memcpy(&version, p + 8, 4);
    memcpy(&count, p + 12, 4);
    if (version != 1)
      return D3D12_ERROR_DRIVER_VERSION_MISMATCH;
    p += 16;
    for (uint32_t i = 0; i < count; i++) {
      uint32_t chars;
      if (end - p < 4)
        return E_INVALIDARG;
      memcpy(&chars, p, 4);
      p += 4;
      if ((size_t)(end - p) < chars * sizeof(WCHAR) + 8)
        return E_INVALIDARG;
      std::wstring name((const wchar_t *)p, chars);
      p += chars * sizeof(WCHAR);
      uint64_t hash;
      memcpy(&hash, p, 8);
      p += 8;
      entries_[name] = {hash, nullptr};
    }
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE
  QueryInterface(REFIID riid, void **ppvObject) {
    if (!ppvObject)
      return E_POINTER;
    *ppvObject = nullptr;
    if (riid == __uuidof(IUnknown) || riid == __uuidof(ID3D12Object) || riid == __uuidof(ID3D12DeviceChild) ||
        riid == __uuidof(ID3D12PipelineLibrary) || riid == __uuidof(ID3D12PipelineLibrary1)) {
      *ppvObject = ref(this);
      return S_OK;
    }
    return E_NOINTERFACE;
  }

  HRESULT STDMETHODCALLTYPE
  StorePipeline(LPCWSTR pName, ID3D12PipelineState *pPipeline) {
    if (!pName || !pPipeline)
      return E_INVALIDARG;
    std::lock_guard lock(mutex_);
    if (entries_.count(pName))
      return E_INVALIDARG;
    entries_[pName] = {static_cast<MTLD3D12PipelineState *>(pPipeline)->desc_hash, pPipeline};
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE
  LoadGraphicsPipeline(LPCWSTR pName, const D3D12_GRAPHICS_PIPELINE_STATE_DESC *pDesc, REFIID riid, void **pp) {
    if (!pDesc)
      return E_INVALIDARG;
    return Load(pName, HashGraphicsDesc(*pDesc), [&](ID3D12PipelineState **pso) {
      return device_->CreateGraphicsPipelineState(pDesc, __uuidof(ID3D12PipelineState), (void **)pso);
    }, riid, pp);
  }

  HRESULT STDMETHODCALLTYPE
  LoadComputePipeline(LPCWSTR pName, const D3D12_COMPUTE_PIPELINE_STATE_DESC *pDesc, REFIID riid, void **pp) {
    if (!pDesc)
      return E_INVALIDARG;
    return Load(pName, HashComputeDesc(*pDesc), [&](ID3D12PipelineState **pso) {
      return device_->CreateComputePipelineState(pDesc, __uuidof(ID3D12PipelineState), (void **)pso);
    }, riid, pp);
  }

  HRESULT STDMETHODCALLTYPE
  LoadPipeline(LPCWSTR pName, const D3D12_PIPELINE_STATE_STREAM_DESC *pDesc, REFIID riid, void **pp) {
    D3D12_GRAPHICS_PIPELINE_STATE_DESC graphics{};
    D3D12_COMPUTE_PIPELINE_STATE_DESC compute{};
    bool is_compute = false;
    HRESULT hr = pDesc ? ParsePipelineStream(pDesc, graphics, compute, is_compute) : E_INVALIDARG;
    if (FAILED(hr))
      return hr;
    return is_compute ? LoadComputePipeline(pName, &compute, riid, pp) : LoadGraphicsPipeline(pName, &graphics, riid, pp);
  }

  SIZE_T STDMETHODCALLTYPE
  GetSerializedSize() {
    std::lock_guard lock(mutex_);
    SIZE_T size = 16;
    for (auto &[name, entry] : entries_)
      size += 4 + name.size() * sizeof(WCHAR) + 8;
    return size;
  }

  HRESULT STDMETHODCALLTYPE
  Serialize(void *pData, SIZE_T DataSizeInBytes) {
    SIZE_T size = GetSerializedSize();
    if (!pData || DataSizeInBytes < size)
      return E_INVALIDARG;
    std::lock_guard lock(mutex_);
    auto p = static_cast<char *>(pData);
    uint32_t version = 1, count = entries_.size();
    memcpy(p, kMagic, 8);
    memcpy(p + 8, &version, 4);
    memcpy(p + 12, &count, 4);
    p += 16;
    for (auto &[name, entry] : entries_) {
      uint32_t chars = name.size();
      memcpy(p, &chars, 4);
      memcpy(p + 4, name.data(), chars * sizeof(WCHAR));
      p += 4 + chars * sizeof(WCHAR);
      memcpy(p, &entry.hash, 8);
      p += 8;
    }
    return S_OK;
  }
};
} // namespace

HRESULT
CreatePipelineLibrary(MTLD3D12Device *pDevice, const void *blob, SIZE_T size, REFIID riid, void **ppLibrary) {
  InitReturnPtr(ppLibrary);
  auto library = Com(new MTLD3D12PipelineLibraryImpl(pDevice));
  HRESULT hr = library->Initialize(blob, size);
  if (FAILED(hr))
    return hr;
  return ppLibrary ? library->QueryInterface(riid, ppLibrary) : S_FALSE;
}

} // namespace dxmt
```

  Check the details against the fork's other device children when compiling:
  - `MTLD3D12DeviceChild`'s constructor and `device_` member name;
  - `InitReturnPtr`;
  - `ID3D12PipelineLibrary`'s `GetPrivateData`/`SetName`, which the base provides.
  
  Add `#include <functional>`. In `d3d12_device.cpp`, `CreatePipelineLibrary` returns `dxmt::CreatePipelineLibrary(this, blob, blob_size, iid, lib)`. Add `'d3d12_pipeline_library.cpp',` to `src/d3d12/meson.build`, and re-run `meson setup --reconfigure` if ninja doesn't pick it up.

- [ ] **Step 5: GREEN.** Run the `library` section.
  Expected: every `library` line equals D3DMetal's.

- [ ] **Step 6: The whole of batch 1.** Run `sh dxmt/tests/run.sh d3d12_api "$S/depth.vs.dxil" "$S/depth.ps.dxil"` with no section.
  Expected: all sections print on both, and every line but `caps` is identical. In `check.sh`, the `same_lines` loop becomes `markers cachedblob nulldsv list1 heap1 residency multifence feature library`.

- [ ] **Step 7: Commit, push, pin, check, commit batch 1**

```bash
git -C build/dxmt-src/dxmt add src/d3d12
git -C build/dxmt-src/dxmt commit -m "d3d12: pipeline libraries

CreatePipelineLibrary returned E_NOTIMPL; it now keeps D3DMetal's semantics: names map to a pipeline and the hash of
its full description, a stored pipeline loads back as the same object, a name read from a serialized library
creates its pipeline on first load when the description matches, and another build's blob is a driver version
mismatch. Pipeline streams are parsed by one function the library shares with CreatePipelineState.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git -C build/dxmt-src/dxmt push origin macneutron
sed -i '' "s/^DXMT_COMMIT=.*/DXMT_COMMIT=$(git -C build/dxmt-src/dxmt rev-parse HEAD)/" dxmt/pins
make dxmt-check        # Expected: "dxmt-check: all passed"
git add dxmt/pins dxmt/check.sh
git commit -m "fix(dxmt): batch 1 of the D3D12 stubs (fork $(git -C build/dxmt-src/dxmt rev-parse --short HEAD))

Markers, cached blobs, null depth views, residency, CreateCommandList1, CreateHeap1, multi-fence events,
CheckFeatureSupport and pipeline libraries answer as D3DMetal (d3d12_api).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Read-only depth and stencil views

**Files:**
- Fork modify: `src/d3d12/d3d12_command_list.cpp` (`PreDraw`)
- Modify:
  - `dxmt/tests/d3d12_depth.cpp` (a second output line, `depth2 ok …`);
  - `dxmt/check.sh` (`same_pixels` takes a prefix).

**Interfaces:**
- Consumes: `MTL_RENDER_TARGET_DESC::Flags` (set by `CreateDepthStencilView`), and `GetDepthStencilState(planar, readonly)`, whose readonly bits are 1 = depth and 2 = stencil.
- Produces: `same_pixels <ours> <ref> [prefix]` in `check.sh`, comparing the 12 pixels of the first line that starts with `<prefix> ok` (default: any `… ok` line).

- [ ] **Step 1: Extend `d3d12_depth.cpp`.**
  - **Setup:** after pass 2, before pass 3, create two more DSVs on `depth`: `dsv_depth_ro` (flags `READ_ONLY_DEPTH`) and `dsv_stencil_ro` (flags `READ_ONLY_STENCIL`). Grow the DSV heap to 4 descriptors. Add a pipeline `pso_both` that writes both planes:

```cpp
    auto both = Depth(TRUE, D3D12_DEPTH_WRITE_MASK_ALL, D3D12_COMPARISON_FUNC_ALWAYS);
    both.StencilEnable = TRUE;
    both.FrontFace.StencilPassOp = both.BackFace.StencilPassOp = D3D12_STENCIL_OP_REPLACE;
    ID3D12PipelineState *pso_both = Pipeline(root, vs, ps, both, D32S8);
    auto sampled = Depth(TRUE, D3D12_DEPTH_WRITE_MASK_ZERO, D3D12_COMPARISON_FUNC_ALWAYS);
    ID3D12PipelineState *pso_sampled = Pipeline(root, vs, psdepth, sampled, D32S8); // reads the depth it's bound to
```

  - **Draws**, appended to `draws[]` (indices 5–8):

```cpp
        {{-1, -1, 0, 1}, {0, 0, 1, 1}, 0.9f},       // 5: blue, left half, depth 0.9, stencil 2 (depth read-only)
        {{0, -1, 1, 1}, {0, 1, 1, 1}, 0.6f},        // 6: cyan, right half, depth 0.6, stencil 3 (stencil read-only)
        {{-1, -1, 1, 1}, {1, 1, 1, 1}, 0},          // 7: the depth, sampled while bound read-only
        {{-1, -1, 1, 1}, {1, 1, 1, 1}, 0},          // 8: white where stencil is 2
```

  - **Pass 4:** a third target, `rtvs[2]` (grow the RTV heap and `targets` to 3):
    - bind `dsv_depth_ro`: `OMSetStencilRef(2)`, draw 5 with `pso_both`, so depth stays and stencil becomes 2;
    - bind `dsv_stencil_ro`: `OMSetStencilRef(3)`, draw 6 with `pso_both`, so stencil stays and depth becomes 0.6;
    - bind `dsv_depth_ro` again and draw 7 with `pso_sampled` (the depth sampled while bound);
    - draw 8 with `pso_stencil` and `OMSetStencilRef(2)`: white where stencil is 2, which is only the left half.
    
    The depth texture moves to `DEPTH_READ | PIXEL_SHADER_RESOURCE` before draw 7, and back to `DEPTH_WRITE` after.
  - **Output:** read back `targets[2]`, then print a second line with its own 12 sample points, keeping the first line unchanged:

```cpp
    // Pass 4: left half, where the depth-read-only view kept depth and stencil became 2; right half, where the
    // stencil-read-only view kept stencil and depth became 0.6.
    const int at2[12][2] = {{8, 8}, {24, 8}, {8, 32}, {24, 32}, {8, 56}, {24, 56}, {40, 8}, {56, 8}, {40, 32}, {56, 32}, {40, 56}, {56, 56}};
    printf("depth2 ok %016llx", ...hash of target 2...);
    for (auto &t : at2) { uint32_t px; memcpy(&px, &pixels[2 * 256 * size + t[1] * 256 + t[0] * 4], 4); printf(" %08x", px); }
    printf("\n");
```

  Resize `readback` to `3 * 256 * size`, and add the third `CopyTextureRegion`.

- [ ] **Step 2: RED.** Run `sh dxmt/tests/run.sh d3d12_depth "$S/depth.vs.dxil" "$S/depth.ps.dxil" "$S/depth.psdepth.dxil"`.
  Expected: the `depth ok` lines are identical, and the `depth2 ok` lines differ. Ours writes depth through the depth-read-only view and stencil through the stencil-read-only view.

- [ ] **Step 3: Read the view's flags.** In `PreDraw`, where the DSV attachment is set up (after `render->dsv_planar_flags = dsv_planar_flags;`):

```cpp
        // D3D12_DSV_FLAG_READ_ONLY_DEPTH (1) and _STENCIL (2) are GetDepthStencilState's read-only bits.
        render->dsv_readonly_flags =
            AttachmentDesc.Flags & (D3D12_DSV_FLAG_READ_ONLY_DEPTH | D3D12_DSV_FLAG_READ_ONLY_STENCIL);
```

  If `GetRenderTarget`'s result doesn't expose `Flags`, add it from `MTL_RENDER_TARGET_DESC` (`CreateDepthStencilView` already sets `RenderTargetDesc.Flags = ViewDesc.Flags`).

- [ ] **Step 4: `check.sh`'s `same_pixels` takes a prefix.**

```sh
same_pixels() {  # same_pixels <ours> <ref> [prefix]: yes when both drew ("<prefix> ok") and 12 pixels are within 1/255
  python3 - "$1" "$2" "${3:-}" <<'PY'
import sys
def px(p, prefix):
    for l in open(p):
        s = l.split()
        if s[1:2] == ["ok"] and (not prefix or s[0] == prefix): return [int(x, 16) for x in s[3:15]]
a, b = px(sys.argv[1], sys.argv[3]), px(sys.argv[2], sys.argv[3])
print("yes" if a and b and len(a) == len(b) == 12 and all(abs(((x >> k) & 255) - ((y >> k) & 255)) <= 1 for x, y in zip(a, b) for k in (0, 8, 16, 24)) else f"no {a} {b}")
PY
}
```

  After the existing depth check, add:

```sh
expect "read-only depth and stencil views match D3DMetal (12 pixels within 1/255)" \
  "$(same_pixels "$WORK/depth-ours.txt" "$WORK/depth-ref.txt" depth2)" yes
```

  and give the existing depth check the prefix `depth`.

- [ ] **Step 5: GREEN.** Run as in Step 2.
  Expected: both lines identical on the two backends. Then run the full `check.sh` depth and pass-dump expectations. The pass dump now counts 4 render passes (pass 4 adds one): update its expectation from `"3 5"` to what the new test gives, and ledger the change.

- [ ] **Step 6: Commit**

```bash
git -C build/dxmt-src/dxmt add src/d3d12/d3d12_command_list.cpp
git -C build/dxmt-src/dxmt commit -m "d3d12: read-only depth and stencil views

A DSV's READ_ONLY_DEPTH and READ_ONLY_STENCIL flags were kept but never read, so passes wrote the plane D3D12 says
is read-only (and the depth texture was written while sampled). PreDraw picks the pipeline's read-only depth
stencil state from them; no new Metal objects.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git add dxmt/tests/d3d12_depth.cpp dxmt/check.sh
git commit -m "test(dxmt): read-only depth and stencil views, sampled while bound

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Format-reinterpreting copies

**Files:**
- Create: `dxmt/tests/d3d12_copy.cpp`
- Modify: `Makefile`, `dxmt/check.sh`
- Fork modify: `src/d3d12/d3d12_command_list.cpp` (`CopyResource`, `CopyTextureRegion`, a new private `CopyReinterpret`)

**Interfaces:**
- Produces: `void CopyReinterpret(Texture *src, const MTL_DXGI_FORMAT_DESC &src_format, uint32_t src_level, uint32_t src_slice, WMTOrigin src_origin, WMTSize src_size, Texture *dst, const MTL_DXGI_FORMAT_DESC &dst_format, uint32_t dst_level, uint32_t dst_slice, WMTOrigin dst_origin);` on the command list. `src_size` is in source units: texels, or blocks for a block-compressed source.

- [ ] **Step 1: Write `dxmt/tests/d3d12_copy.cpp`**

```cpp
// Copies between formats D3D12 lets reinterpret, read back byte for byte (D3D12 stubs spec, batch 2).
//   d3d12_copy.exe   Prints "copy <case> ok <FNV-1a 64 of the destination> <first 16 bytes>" per case.
#include "d3d12_common.hpp"

static Gpu *gpu;

static uint64_t Fnv(const uint8_t *p, size_t n) {
    uint64_t h = 0xcbf29ce484222325ull;
    for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * 0x100000001b3ull;
    return h;
}

// Uploads `bytes` into subresource 0 of `tex` (rows of `row` bytes, `rows` of them), from COPY_DEST to `after`.
static void Upload(ID3D12Resource *tex, DXGI_FORMAT format, UINT w, UINT h, const std::vector<uint8_t> &bytes, UINT row,
                   UINT rows, D3D12_RESOURCE_STATES after) {
    ID3D12Resource *up = gpu->Buffer(D3D12_HEAP_TYPE_UPLOAD, 256 * rows, D3D12_RESOURCE_STATE_GENERIC_READ);
    uint8_t *p; CHECK(up->Map(0, nullptr, (void **)&p));
    for (UINT r = 0; r < rows; r++) memcpy(p + r * 256, bytes.data() + r * row, row);
    up->Unmap(0, nullptr);
    D3D12_TEXTURE_COPY_LOCATION dst = {tex, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}; dst.SubresourceIndex = 0;
    D3D12_TEXTURE_COPY_LOCATION src = {up, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT};
    src.PlacedFootprint.Footprint = {format, w, h, 1, 256};
    gpu->list->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
    gpu->Barrier(tex, D3D12_RESOURCE_STATE_COPY_DEST, after);
}

// Reads subresource `sub` of `tex` (rows of `row` bytes) back and prints the case line.
static void Print(const char *name, ID3D12Resource *tex, UINT sub, DXGI_FORMAT format, UINT w, UINT h, UINT row, UINT rows) {
    ID3D12Resource *rb = gpu->Buffer(D3D12_HEAP_TYPE_READBACK, 256 * rows, D3D12_RESOURCE_STATE_COPY_DEST);
    D3D12_TEXTURE_COPY_LOCATION src = {tex, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}; src.SubresourceIndex = sub;
    D3D12_TEXTURE_COPY_LOCATION dst = {rb, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT};
    dst.PlacedFootprint.Footprint = {format, w, h, 1, 256};
    gpu->list->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
    gpu->Submit();
    uint8_t *p; CHECK(rb->Map(0, nullptr, (void **)&p));
    std::vector<uint8_t> bytes(row * rows);
    for (UINT r = 0; r < rows; r++) memcpy(bytes.data() + r * row, p + r * 256, row);
    rb->Unmap(0, nullptr);
    printf("copy %s ok %016llx", name, (unsigned long long)Fnv(bytes.data(), bytes.size()));
    for (int i = 0; i < 16; i++) printf("%s%02x", i % 4 ? "" : " ", bytes[i]);
    printf("\n");
}

static std::vector<uint8_t> Pattern(size_t n, uint8_t seed) {
    std::vector<uint8_t> v(n);
    for (size_t i = 0; i < n; i++) v[i] = (uint8_t)(i * 37 + seed);
    return v;
}

int main() {
    gpu = new Gpu();
    const auto SRC = D3D12_RESOURCE_STATE_COPY_SOURCE, DST = D3D12_RESOURCE_STATE_COPY_DEST;

    // srgb: RGBA8 UNORM -> RGBA8 UNORM_SRGB, CopyResource (same bits, reinterpreted).
    ID3D12Resource *a = gpu->Texture(Tex2D(16, 16, DXGI_FORMAT_R8G8B8A8_UNORM), DST);
    ID3D12Resource *b = gpu->Texture(Tex2D(16, 16, DXGI_FORMAT_R8G8B8A8_UNORM_SRGB), DST);
    Upload(a, DXGI_FORMAT_R8G8B8A8_UNORM, 16, 16, Pattern(16 * 16 * 4, 1), 64, 16, SRC);
    gpu->list->CopyResource(b, a);
    gpu->Barrier(b, DST, SRC);
    Print("srgb", b, 0, DXGI_FORMAT_R8G8B8A8_UNORM_SRGB, 16, 16, 64, 16);

    // float: R32 TYPELESS -> R32 FLOAT, CopyResource.
    a = gpu->Texture(Tex2D(16, 16, DXGI_FORMAT_R32_TYPELESS), DST);
    b = gpu->Texture(Tex2D(16, 16, DXGI_FORMAT_R32_FLOAT), DST);
    Upload(a, DXGI_FORMAT_R32_TYPELESS, 16, 16, Pattern(16 * 16 * 4, 2), 64, 16, SRC);
    gpu->list->CopyResource(b, a);
    gpu->Barrier(b, DST, SRC);
    Print("float", b, 0, DXGI_FORMAT_R32_FLOAT, 16, 16, 64, 16);

    // bc1: R32G32_UINT 4x4 -> BC1 16x16 (one block per texel), CopyTextureRegion.
    struct Case { const char *name; DXGI_FORMAT from; DXGI_FORMAT to; UINT bytes; };
    for (Case c : {Case{"bc1", DXGI_FORMAT_R32G32_UINT, DXGI_FORMAT_BC1_UNORM, 8},
                   Case{"bc3", DXGI_FORMAT_R32G32B32A32_UINT, DXGI_FORMAT_BC3_UNORM, 16},
                   Case{"bc7", DXGI_FORMAT_R32G32B32A32_UINT, DXGI_FORMAT_BC7_UNORM, 16}}) {
        a = gpu->Texture(Tex2D(4, 4, c.from), DST);
        b = gpu->Texture(Tex2D(16, 16, c.to), DST);
        Upload(a, c.from, 4, 4, Pattern(4 * 4 * c.bytes, 3), 4 * c.bytes, 4, SRC);
        D3D12_TEXTURE_COPY_LOCATION to = {b, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}; to.SubresourceIndex = 0;
        D3D12_TEXTURE_COPY_LOCATION from = {a, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}; from.SubresourceIndex = 0;
        gpu->list->CopyTextureRegion(&to, 0, 0, 0, &from, nullptr);
        gpu->Barrier(b, DST, SRC);
        Print(c.name, b, 0, c.to, 16, 16, 4 * c.bytes, 4);
    }

    // unbc1: BC1 16x16 -> R32G32_UINT 4x4, CopyTextureRegion.
    a = gpu->Texture(Tex2D(16, 16, DXGI_FORMAT_BC1_UNORM), DST);
    b = gpu->Texture(Tex2D(4, 4, DXGI_FORMAT_R32G32_UINT), DST);
    Upload(a, DXGI_FORMAT_BC1_UNORM, 16, 16, Pattern(4 * 4 * 8, 4), 32, 4, SRC);
    {
        D3D12_TEXTURE_COPY_LOCATION to = {b, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}; to.SubresourceIndex = 0;
        D3D12_TEXTURE_COPY_LOCATION from = {a, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}; from.SubresourceIndex = 0;
        gpu->list->CopyTextureRegion(&to, 0, 0, 0, &from, nullptr);
    }
    gpu->Barrier(b, DST, SRC);
    Print("unbc1", b, 0, DXGI_FORMAT_R32G32_UINT, 4, 4, 32, 4);

    // depth: D32 (cleared to 0.25) -> R32 FLOAT, CopyResource.
    D3D12_CLEAR_VALUE clear = {DXGI_FORMAT_D32_FLOAT}; clear.DepthStencil = {0.25f, 0};
    a = gpu->Texture(Tex2D(16, 16, DXGI_FORMAT_R32_TYPELESS, 1, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL),
                     D3D12_RESOURCE_STATE_DEPTH_WRITE, &clear);
    b = gpu->Texture(Tex2D(16, 16, DXGI_FORMAT_R32_FLOAT), DST);
    ID3D12DescriptorHeap *dh; D3D12_DESCRIPTOR_HEAP_DESC dd = {D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 1};
    CHECK(gpu->device->CreateDescriptorHeap(&dd, __uuidof(ID3D12DescriptorHeap), (void **)&dh));
    D3D12_DEPTH_STENCIL_VIEW_DESC dv = {DXGI_FORMAT_D32_FLOAT, D3D12_DSV_DIMENSION_TEXTURE2D};
    gpu->device->CreateDepthStencilView(a, &dv, dh->GetCPUDescriptorHandleForHeapStart());
    gpu->list->ClearDepthStencilView(dh->GetCPUDescriptorHandleForHeapStart(), D3D12_CLEAR_FLAG_DEPTH, 0.25f, 0, 0, nullptr);
    gpu->Barrier(a, D3D12_RESOURCE_STATE_DEPTH_WRITE, SRC);
    gpu->list->CopyResource(b, a);
    gpu->Barrier(b, DST, SRC);
    Print("depth", b, 0, DXGI_FORMAT_R32_FLOAT, 16, 16, 64, 16);

    // mip1: an 8x8 region of mip 1 at (4, 4), RGBA8 UINT -> UNORM, into mip 1 of a 32x32 at (8, 0); the rest
    // stays as uploaded.
    a = gpu->Texture(Tex2D(32, 32, DXGI_FORMAT_R8G8B8A8_UINT, 2), DST);
    b = gpu->Texture(Tex2D(32, 32, DXGI_FORMAT_R8G8B8A8_UNORM, 2), DST);
    for (ID3D12Resource *t : {a, b}) {  // mip 1 of both, from a pattern each
        ID3D12Resource *up = gpu->Buffer(D3D12_HEAP_TYPE_UPLOAD, 256 * 16, D3D12_RESOURCE_STATE_GENERIC_READ);
        uint8_t *p; CHECK(up->Map(0, nullptr, (void **)&p));
        auto bytes = Pattern(16 * 16 * 4, t == a ? 5 : 6);
        for (int r = 0; r < 16; r++) memcpy(p + r * 256, bytes.data() + r * 64, 64);
        up->Unmap(0, nullptr);
        D3D12_TEXTURE_COPY_LOCATION to = {t, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}; to.SubresourceIndex = 1;
        D3D12_TEXTURE_COPY_LOCATION from = {up, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT};
        from.PlacedFootprint.Footprint = {t == a ? DXGI_FORMAT_R8G8B8A8_UINT : DXGI_FORMAT_R8G8B8A8_UNORM, 16, 16, 1, 256};
        gpu->list->CopyTextureRegion(&to, 0, 0, 0, &from, nullptr);
    }
    gpu->Barrier(a, DST, SRC);
    {
        D3D12_TEXTURE_COPY_LOCATION to = {b, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}; to.SubresourceIndex = 1;
        D3D12_TEXTURE_COPY_LOCATION from = {a, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}; from.SubresourceIndex = 1;
        D3D12_BOX box = {4, 4, 0, 12, 12, 1};
        gpu->list->CopyTextureRegion(&to, 8, 0, 0, &from, &box);
    }
    gpu->Barrier(b, DST, SRC);
    Print("mip1", b, 1, DXGI_FORMAT_R8G8B8A8_UNORM, 16, 16, 64, 16);
    return 0;
}
```

  Add to `Makefile`: `$(MINGWXX) -std=c++17 -o build/dxmt-tests/d3d12_copy.exe dxmt/tests/d3d12_copy.cpp -ld3d12 -ldxgi`

- [ ] **Step 2: RED.** Run `sh dxmt/tests/run.sh d3d12_copy`.
  - **Expected:** D3DMetal prints seven `copy … ok` lines.
  - **Expected, ours:**
    - `srgb`, `float` and `depth` differ (the copy is skipped, so the destination keeps its initial contents);
    - `bc*`, `unbc1` and `mip1` differ or are missing.
  
  Record D3DMetal's seven lines.

- [ ] **Step 3: `CopyReinterpret`** (private, in the command list class)

```cpp
  // A copy between formats D3D12 lets reinterpret (same bits per texel or block). Same size, neither compressed:
  // one blit from a view of the source in the destination's pixel format (every texture allows format views).
  // Compressed and not, or a depth format: through staging from the allocator's temp buffer, no allocation.
  void
  CopyReinterpret(
      Texture *src, const MTL_DXGI_FORMAT_DESC &src_format, uint32_t src_level, uint32_t src_slice, WMTOrigin src_origin,
      WMTSize src_size, Texture *dst, const MTL_DXGI_FORMAT_DESC &dst_format, uint32_t dst_level, uint32_t dst_slice,
      WMTOrigin dst_origin
  ) {
    bool src_bc = src_format.Flag & MTL_DXGI_FORMAT_BC, dst_bc = dst_format.Flag & MTL_DXGI_FORMAT_BC;
    if (src_format.BytesPerTexel != dst_format.BytesPerTexel) {
      WARN("CopyReinterpret: ", src_format.PixelFormat, " -> ", dst_format.PixelFormat, " differ in size, skipped");
      return;
    }
    bool depth = src_format.PlanarCount > 1 || dst_format.PlanarCount > 1 ||
                 IsDepthPixelFormat(src->pixelFormat()) || IsDepthPixelFormat(dst->pixelFormat());
    if (!src_bc && !dst_bc && !depth) {
      TextureViewDescriptor view{.format = dst_format.PixelFormat, .type = src->textureType()};
      view.firstMiplevel = 0;
      view.miplevelCount = src->mipLevelCount();
      view.firstArraySlice = 0;
      view.arraySize = src->arrayLength();
      auto key = src->createView(view);
      auto &cmd = allocator_->EncodeBlitCommand<wmtcmd_blit_copy_from_texture_to_texture>();
      cmd.type = WMTBlitCommandCopyFromTextureToTexture;
      cmd.src = src->view(key).texture;
      cmd.src_level = src_level;
      cmd.src_slice = src_slice;
      cmd.src_origin = src_origin;
      cmd.src_size = src_size;
      cmd.dst = dst->current()->texture();
      cmd.dst_level = dst_level;
      cmd.dst_slice = dst_slice;
      cmd.dst_origin = dst_origin;
      return;
    }
    // Units: a block of a compressed format is one texel of the other. Sizes in texels of each side.
    uint32_t src_scale = src_bc ? 4 : 1, dst_scale = dst_bc ? 4 : 1;
    uint32_t units_w = src_size.width / src_scale, units_h = src_size.height / src_scale;
    uint32_t bytes_per_row = align(units_w * src_format.BytesPerTexel, 256);
    uint32_t bytes_per_image = bytes_per_row * units_h;
    auto [temp, temp_offset] = allocator_->AllocateTempBuffer(bytes_per_image * src_size.depth, 256);
    auto &to_buffer = allocator_->EncodeBlitCommand<wmtcmd_blit_copy_from_texture_to_buffer_withblitoption>();
    to_buffer.type = WMTBlitCommandCopyFromTextureToBufferWithBlitOption;
    to_buffer.src = src->current()->texture();
    to_buffer.level = src_level;
    to_buffer.slice = src_slice;
    to_buffer.origin = src_origin;
    to_buffer.size = src_size;
    to_buffer.dst = temp;
    to_buffer.offset = temp_offset;
    to_buffer.bytes_per_row = bytes_per_row;
    to_buffer.bytes_per_image = bytes_per_image;
    to_buffer.options = src_format.PlanarCount > 1 ? WMTBlitOptionDepthFromDepthStencil : WMTBlitOptionNone;
    auto &to_texture = allocator_->EncodeBlitCommand<wmtcmd_blit_copy_from_buffer_to_texture_withblitoption>();
    to_texture.type = WMTBlitCommandCopyFromBufferToTextureWithBlitOption;
    to_texture.src = temp;
    to_texture.src_offset = temp_offset;
    to_texture.bytes_per_row = bytes_per_row;
    to_texture.bytes_per_image = bytes_per_image;
    to_texture.size = {units_w * dst_scale, units_h * dst_scale, src_size.depth};
    to_texture.dst = dst->current()->texture();
    to_texture.level = dst_level;
    to_texture.slice = dst_slice;
    to_texture.origin = dst_origin;
    to_texture.options = dst_format.PlanarCount > 1 ? WMTBlitOptionDepthFromDepthStencil : WMTBlitOptionNone;
  }
```

  Before compiling, check the names against `dxmt_texture.hpp`:
  - `mipLevelCount()`/`arrayLength()` (or `info()`'s fields) and the `TextureViewDescriptor` bitfields;
  - add `IsDepthPixelFormat(WMTPixelFormat)` to `dxmt_format.hpp` if there is none: true for `Depth16Unorm`, `Depth32Float`, `Depth24Unorm_Stencil8`, `Depth32Float_Stencil8`, `X32_Stencil8`, `X24_Stencil8`, `Stencil8`.
  
  Compressed textures of 1×1 or 2×2 mips aren't block-aligned: size the copy with `max(units, 1)` and leave such mips to the plain path, ledgering it if the test shows it.

- [ ] **Step 4: Call it.**
  - **`CopyResource`:** replace the `WARN("CopyResource: TODO: reinterpret copy"); return;` block with a loop over subresources:

```cpp
    if (pDst->texture->pixelFormat() != pSrc->texture->pixelFormat()) {
      MTL_DXGI_FORMAT_DESC src_format, dst_format;
      if (FAILED(MTLQueryDXGIFormat(device_->GetMTLDevice(), SrcDesc.Format, src_format)) ||
          FAILED(MTLQueryDXGIFormat(device_->GetMTLDevice(), DstDesc.Format, dst_format)))
        return;
      uint32_t levels = SrcDesc.MipLevels, slices = SrcDesc.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D ? 1 : SrcDesc.DepthOrArraySize;
      for (uint32_t slice = 0; slice < slices; slice++)
        for (uint32_t level = 0; level < levels; level++) {
          uint32_t w = std::max<uint32_t>(SrcDesc.Width >> level, 1), h = std::max<uint32_t>(SrcDesc.Height >> level, 1);
          uint32_t d = SrcDesc.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D ? std::max<uint32_t>(SrcDesc.DepthOrArraySize >> level, 1) : 1;
          CopyReinterpret(pSrc->texture.ptr(), src_format, level, slice, {0, 0, 0}, {w, h, d}, pDst->texture.ptr(),
                          dst_format, level, slice, {0, 0, 0});
        }
      return;
    }
```

  - **`CopyTextureRegion`:** in the texture-to-texture branch, before the plain `wmtcmd_blit_copy_from_texture_to_texture`, and before the depth-stencil temp-buffer branch when the formats differ:

```cpp
        if (src->pixelFormat() != dst->pixelFormat()) {
          CopyReinterpret(src.ptr(), src_format, src_level, src_slice, {src_box.left, src_box.top, src_box.front},
                          {src_box.right - src_box.left, src_box.bottom - src_box.top, src_box.back - src_box.front},
                          dst.ptr(), dst_format, dst_level, dst_slice, {DstX, DstY, DstZ});
          return;
        }
```

  Here `src`/`dst` are the resources' `Rc<Texture>` members. Use `.ptr()` or `get()`, whichever the fork's `Rc` has.

- [ ] **Step 5: GREEN.** Run `sh dxmt/tests/run.sh d3d12_copy`.
  Expected: the seven lines on our DXMT equal D3DMetal's. The same-format copies elsewhere are unchanged: re-run `d3d12_triangle`, whose texture upload goes through `CopyTextureRegion`.

- [ ] **Step 6: `check.sh`**

```sh
run ours copy-ours dxmt "$TESTS/d3d12_copy.exe"
run ours copy-ref d3dmetal "$TESTS/d3d12_copy.exe"
expect "reinterpreting copies match D3DMetal byte for byte" \
  "$(grep '^copy ' "$WORK/copy-ours.txt" | tr '\n' ' ')" "$(grep '^copy ' "$WORK/copy-ref.txt" | tr '\n' ' ')"
expect "d3d12_copy ran its seven cases" "$(grep -c '^copy .* ok ' "$WORK/copy-ours.txt" || true)" 7
```

- [ ] **Step 7: Commit**

```bash
git -C build/dxmt-src/dxmt add src/d3d12/d3d12_command_list.cpp src/dxmt/dxmt_format.hpp
git -C build/dxmt-src/dxmt commit -m "d3d12: copies between formats D3D12 lets reinterpret

CopyResource skipped copies between different formats, and CopyTextureRegion handed Metal mismatched ones. Same
size and uncompressed: one blit through a view of the source in the destination's format. Block-compressed and
uncompressed, or a depth format: through the allocator's staging buffer, with no allocation per copy.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git add Makefile dxmt/check.sh dxmt/tests/d3d12_copy.cpp
git commit -m "test(dxmt): d3d12_copy, reinterpreting copies against D3DMetal

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Null descriptors

**Files:**
- Create: `dxmt/tests/shaders/null.hlsl`, `dxmt/tests/d3d12_null.cpp`
- Modify: `dxmt/tests/shaders/compile.sh`, `Makefile`, `dxmt/check.sh`
- Fork modify:
  - `src/d3d12/d3d12_device.cpp`/`.hpp`: null resources, created once;
  - `src/d3d12/d3d12_descriptor_heap.cpp`: `AddShaderResourceView(Index, pDesc)` and `AddUnorderedAccessView(Index, pDesc)`;
  - only if Step 2 shows D3DMetal's sizes are 0: `src/airconv/dxil/dxil_lower_resources.cpp` and the descriptor metadata.

**Interfaces:**
- Produces:
  - `std::pair<Texture *, TextureViewKey> MTLD3D12Device::NullTexture(WMTTextureType type, bool writable)`;
  - `std::pair<Buffer *, BufferViewKey> MTLD3D12Device::NullTexelBuffer()`.

- [ ] **Step 1: The shader and the test.** `dxmt/tests/shaders/null.hlsl`:

```hlsl
// Null descriptors (D3D12 stubs spec, batch 2): reads through null SRVs of every type and their sizes, and writes
// through null UAVs, into u0. Every value must be what D3DMetal gives.
Buffer<float4> TypedBuf : register(t0);
StructuredBuffer<uint> StructBuf : register(t1);
ByteAddressBuffer RawBuf : register(t2);
Texture1D<float4> Tex1D : register(t3);
Texture1DArray<float4> Tex1DArray : register(t4);
Texture2D<float4> Tex2D : register(t5);
Texture2DArray<float4> Tex2DArray : register(t6);
Texture2DMS<float4> Tex2DMS : register(t7);
Texture3D<float4> Tex3D : register(t8);
TextureCube<float4> TexCube : register(t9);
TextureCubeArray<float4> TexCubeArray : register(t10);
RWByteAddressBuffer Out : register(u0);
RWTexture2D<float4> NullUav2D : register(u1);
RWBuffer<float4> NullUavBuf : register(u2);
SamplerState Point : register(s0);

void put(uint slot, float4 v) { Out.Store4(slot * 16, asuint(v)); }
void put(uint slot, uint4 v) { Out.Store4(slot * 16, v); }

[numthreads(1, 1, 1)]
void main() {
    put(0, TypedBuf[0]);
    put(1, uint4(StructBuf[0], RawBuf.Load(0), 0, 0));
    put(2, Tex1D.Load(int2(0, 0)));
    put(3, Tex1DArray.Load(int3(0, 0, 0)));
    put(4, Tex2D.Load(int3(0, 0, 0)));
    put(5, Tex2DArray.Load(int4(0, 0, 0, 0)));
    put(6, Tex2DMS.Load(int2(0, 0), 0));
    put(7, Tex3D.Load(int4(0, 0, 0, 0)));
    put(8, TexCube.SampleLevel(Point, float3(1, 0, 0), 0));
    put(9, TexCubeArray.SampleLevel(Point, float4(1, 0, 0, 0), 0));
    put(10, Tex2D.SampleLevel(Point, float2(0.5, 0.5), 0));
    uint w, h, e, levels, samples;
    TypedBuf.GetDimensions(w);
    StructBuf.GetDimensions(h, e);
    put(11, uint4(w, h, e, 0));
    Tex2D.GetDimensions(0, w, h, levels);
    put(12, uint4(w, h, levels, 0));
    Tex2DArray.GetDimensions(0, w, h, e, levels);
    put(13, uint4(w, h, e, levels));
    Tex2DMS.GetDimensions(w, h, samples);
    put(14, uint4(w, h, samples, 0));
    Tex3D.GetDimensions(0, w, h, e, levels);
    put(15, uint4(w, h, e, levels));
    NullUav2D[uint2(0, 0)] = float4(1, 2, 3, 4);  // discarded
    NullUavBuf[0] = float4(5, 6, 7, 8);           // discarded
    put(16, NullUav2D[uint2(0, 0)]);
    put(17, NullUavBuf[0]);
}
```

  In `compile.sh`, after the DXIL groups loop, add a line compiling it into `dxmt/tests/shaders`: `dxc -T cs_6_0 -E main -Fo null.cs.dxil null.hlsl` (from `$HERE`).
  
  `dxmt/tests/d3d12_null.cpp`:

```cpp
// Null SRV and UAV descriptors of every type (D3D12 stubs spec, batch 2): d3d12_null.exe <null.cs.dxil>
// Prints "null <slot> <4 words>" for each of null.hlsl's 18 slots.
#include "d3d12_common.hpp"

int main(int argc, char **argv) {
    if (argc != 2) { printf("usage: d3d12_null.exe <null.cs.dxil>\n"); return 2; }
    auto cs = Load(argv[1]);
    if (cs.empty()) { printf("can't read the shader\n"); return 1; }
    Gpu gpu;
    // One table: t0-t10, then u0-u2; a static point sampler s0.
    D3D12_DESCRIPTOR_RANGE ranges[2] = {{D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 11, 0, 0, 0},
                                        {D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 3, 0, 0, 11}};
    D3D12_ROOT_PARAMETER param = {};
    param.ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    param.DescriptorTable = {2, ranges};
    D3D12_STATIC_SAMPLER_DESC sampler = {};
    sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_POINT;
    sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    sampler.MaxLOD = D3D12_FLOAT32_MAX;
    D3D12_ROOT_SIGNATURE_DESC rd = {1, &param, 1, &sampler, D3D12_ROOT_SIGNATURE_FLAG_NONE};
    ID3D12RootSignature *root = gpu.RootSignature(rd);
    D3D12_COMPUTE_PIPELINE_STATE_DESC cd = {root, {cs.data(), cs.size()}};
    ID3D12PipelineState *pso;
    CHECK(gpu.device->CreateComputePipelineState(&cd, __uuidof(ID3D12PipelineState), (void **)&pso));

    ID3D12DescriptorHeap *heap;
    D3D12_DESCRIPTOR_HEAP_DESC hd = {D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 14, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE};
    CHECK(gpu.device->CreateDescriptorHeap(&hd, __uuidof(ID3D12DescriptorHeap), (void **)&heap));
    UINT step = gpu.device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    auto at = [&](int i) { auto h = heap->GetCPUDescriptorHandleForHeapStart(); h.ptr += i * step; return h; };
    const DXGI_FORMAT F = DXGI_FORMAT_R32G32B32A32_FLOAT;
    D3D12_SHADER_RESOURCE_VIEW_DESC s[11] = {};
    for (auto &v : s) { v.Format = F; v.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING; }
    s[0].ViewDimension = D3D12_SRV_DIMENSION_BUFFER; s[0].Buffer.NumElements = 1;
    s[1].ViewDimension = D3D12_SRV_DIMENSION_BUFFER; s[1].Format = DXGI_FORMAT_UNKNOWN;
    s[1].Buffer.NumElements = 1; s[1].Buffer.StructureByteStride = 4;
    s[2].ViewDimension = D3D12_SRV_DIMENSION_BUFFER; s[2].Format = DXGI_FORMAT_R32_TYPELESS;
    s[2].Buffer.NumElements = 1; s[2].Buffer.Flags = D3D12_BUFFER_SRV_FLAG_RAW;
    s[3].ViewDimension = D3D12_SRV_DIMENSION_TEXTURE1D; s[3].Texture1D.MipLevels = 1;
    s[4].ViewDimension = D3D12_SRV_DIMENSION_TEXTURE1DARRAY; s[4].Texture1DArray = {0, 1, 0, 1};
    s[5].ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D; s[5].Texture2D.MipLevels = 1;
    s[6].ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2DARRAY; s[6].Texture2DArray = {0, 1, 0, 1};
    s[7].ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2DMS;
    s[8].ViewDimension = D3D12_SRV_DIMENSION_TEXTURE3D; s[8].Texture3D.MipLevels = 1;
    s[9].ViewDimension = D3D12_SRV_DIMENSION_TEXTURECUBE; s[9].TextureCube.MipLevels = 1;
    s[10].ViewDimension = D3D12_SRV_DIMENSION_TEXTURECUBEARRAY; s[10].TextureCubeArray = {0, 1, 0, 1};
    for (int i = 0; i < 11; i++) gpu.device->CreateShaderResourceView(nullptr, &s[i], at(i));
    ID3D12Resource *out = gpu.Buffer(D3D12_HEAP_TYPE_DEFAULT, 18 * 16, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                                     D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    D3D12_UNORDERED_ACCESS_VIEW_DESC u = {DXGI_FORMAT_R32_TYPELESS, D3D12_UAV_DIMENSION_BUFFER};
    u.Buffer.NumElements = 18 * 4; u.Buffer.Flags = D3D12_BUFFER_UAV_FLAG_RAW;
    gpu.device->CreateUnorderedAccessView(out, nullptr, &u, at(11));
    D3D12_UNORDERED_ACCESS_VIEW_DESC u2 = {F, D3D12_UAV_DIMENSION_TEXTURE2D};
    gpu.device->CreateUnorderedAccessView(nullptr, nullptr, &u2, at(12));
    D3D12_UNORDERED_ACCESS_VIEW_DESC u3 = {F, D3D12_UAV_DIMENSION_BUFFER}; u3.Buffer.NumElements = 1;
    gpu.device->CreateUnorderedAccessView(nullptr, nullptr, &u3, at(13));

    ID3D12Resource *rb = gpu.Buffer(D3D12_HEAP_TYPE_READBACK, 18 * 16, D3D12_RESOURCE_STATE_COPY_DEST);
    gpu.list->SetComputeRootSignature(root);
    gpu.list->SetDescriptorHeaps(1, &heap);
    gpu.list->SetComputeRootDescriptorTable(0, heap->GetGPUDescriptorHandleForHeapStart());
    gpu.list->SetPipelineState(pso);
    gpu.list->Dispatch(1, 1, 1);
    gpu.Barrier(out, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
    gpu.list->CopyBufferRegion(rb, 0, out, 0, 18 * 16);
    gpu.Submit();
    uint32_t *v; CHECK(rb->Map(0, nullptr, (void **)&v));
    for (int i = 0; i < 18; i++)
        printf("null %d %08x %08x %08x %08x\n", i, v[i * 4], v[i * 4 + 1], v[i * 4 + 2], v[i * 4 + 3]);
    return 0;
}
```

  Add to `Makefile`: `$(MINGWXX) -std=c++17 -o build/dxmt-tests/d3d12_null.exe dxmt/tests/d3d12_null.cpp -ld3d12 -ldxgi`

- [ ] **Step 2: RED.** Run `sh dxmt/tests/compile.sh` (or just its `null.hlsl` line under Wine's dxc), then `sh dxmt/tests/run.sh d3d12_null "Z:$PWD/dxmt/tests/shaders/null.cs.dxil"`.
  - **Expected:** D3DMetal prints 18 `null` lines. Record them in the ledger: they settle whether sizes (slots 11–15) are 0.
  - **Expected, ours:** texture and typed-buffer slots differ (a nil texture handle) or the dispatch faults.

- [ ] **Step 3: Null resources, once per device.**
  - **Members** (`MTLD3D12Device`, `d3d12_device.hpp`/`.cpp`):

```cpp
  // Null SRVs and UAVs point at these: one zeroed 1x1 texture per Metal texture type a view can have (UAVs get
  // their own, as their writes are discarded), and a zeroed texel buffer. Created once; nothing per descriptor.
  std::pair<Texture *, TextureViewKey> NullTexture(WMTTextureType type, bool writable);
  std::pair<Buffer *, BufferViewKey> NullTexelBuffer();
```

  - **Implementation:** lazily, under a mutex, keyed by `(type, writable)`. Create a `Texture` with this `WMTTextureInfo`:
    - `pixel_format = WMTPixelFormatRGBA32Float` (all four channels read 0; any format's zero is 0);
    - width, height and depth 1;
    - `array_length = 1`;
    - `mipmap_level_count = 1`;
    - `sample_count = 4` for the multisample types, else 1;
    - `usage = ShaderRead | PixelFormatView | (writable ? ShaderWrite : 0)`;
    - `options = WMTResourceStorageModePrivate | WMTResourceHazardTrackingModeUntracked`.
    
    Then `rename(allocate({}))` and `RegisterResidency(texture->current()->texture())`. Take the default view key (the texture's full view).
  - **Zeroing:**
    - Every type but the multisample ones uses `WMTResourceStorageModeShared` instead of private, and is zeroed once with `texture->current()->texture().replaceRegion(...)`: one call per slice or face, from a 16-byte zero array.
    - The multisample ones can't be shared or replaced; they stay private and rely on fresh GPU memory being zero-filled by the OS. `d3d12_null`'s slot 6 checks that.
  - **Types to support:** `2D`, `2DArray`, `Cube` (array_length 1 × 6 faces), `CubeArray`, `2DMultisample`, `2DMultisampleArray`, `3D`. Those are the types `d3d12_texture.cpp`'s SRV/UAV creation uses; 1D views are lowered to 2D there.
  - **The texel buffer:** a 16-byte `Buffer` allocated once, with a `createView(BufferViewDescriptor{WMTPixelFormatRGBA32Float})` view.

- [ ] **Step 4: The descriptors.** In `d3d12_descriptor_heap.cpp`, `AddShaderResourceView(Index, pDesc)` and `AddUnorderedAccessView(Index, pDesc)` stop zero-filling. They map `pDesc->ViewDimension` to the Metal type exactly as `d3d12_texture.cpp`'s views do, then reuse the existing typed paths:

```cpp
  virtual HRESULT
  AddShaderResourceView(UINT Index, D3D12_SHADER_RESOURCE_VIEW_DESC const *pDesc) {
    if (Index >= descriptors_.size() || !pDesc)
      return E_INVALIDARG;
    // A null descriptor reads zeros: raw and structured buffers through a zero length, the rest through the
    // device's null resources of the view's type.
    switch (pDesc->ViewDimension) {
    case D3D12_SRV_DIMENSION_BUFFER:
      if (pDesc->Format == DXGI_FORMAT_UNKNOWN || (pDesc->Buffer.Flags & D3D12_BUFFER_SRV_FLAG_RAW))
        return AddShaderResourceView(Index, (Buffer *)nullptr, BufferSlice{});
      {
        auto [buffer, view] = device_->NullTexelBuffer();
        return AddShaderResourceView(Index, buffer, view, BufferSlice{}); // 0 elements: every read out of bounds
      }
    default: {
      auto type = NullViewType(pDesc->ViewDimension); // TEXTURE1D/2D -> 2D, 1DARRAY/2DARRAY -> 2DArray, ...
      auto [texture, view] = device_->NullTexture(type, false);
      return AddShaderResourceView(Index, texture, view, 0.0f);
    }
    }
  }
```

  `AddUnorderedAccessView(Index, pDesc)` is the same with `writable = true`. Raw and structured buffers take the existing `(Buffer *)nullptr` path; typed buffers take `NullTexelBuffer()` through the `(Buffer *, BufferViewKey, BufferSlice)` overload. `NullViewType` is a small static function next to them, mirroring `d3d12_texture.cpp`'s switch.

- [ ] **Step 5: Run.** Run as in Step 2.
  Expected: reads (slots 0–10, 16, 17) equal D3DMetal's. For sizes (slots 11–15): if D3DMetal's are 0 and ours are 1 (the 1×1 texture), do Step 6; if they already match, skip it and ledger that D3DMetal reports the null resource's size.

- [ ] **Step 6: (only if Step 5 found 0 sizes on D3DMetal) Null sizes.**
  - Mark null texture descriptors with bit 63 of their metadata word: `metadata | (1ull << 63)`, set in the null path above.
  - Clear that bit wherever the array length is decoded, in `DecodeTextureArrayLength` (airconv, `nt/dxbc_converter_base.cpp`'s helpers): mask the upper word with `0x7fffffff`.
  - In `Lowering::LowerDimensions` (`dxil_lower_resources.cpp`), after computing `{x, y, z, last}`, zero them when the flag is set:

```cpp
  auto is_null = ir.CreateICmpSLT(d->Metadata, ir.getInt64(0)); // bit 63: a null descriptor (D3D12 null views)
  auto zero_if_null = [&](llvm::Value *v) { return ir.CreateSelect(is_null, ir.getInt32(0), v); };
  Replace(call, Aggregate(ty, {zero_if_null(x), zero_if_null(y), zero_if_null(z), zero_if_null(last)}));
```

  Re-run as in Step 2. Expected: all 18 lines equal D3DMetal's.

- [ ] **Step 7: `check.sh`**

```sh
run ours null-ours dxmt "$TESTS/d3d12_null.exe" "Z:$S/null.cs.dxil"
run ours null-ref d3dmetal "$TESTS/d3d12_null.exe" "Z:$S/null.cs.dxil"
expect "null descriptors read and report as on D3DMetal" \
  "$(grep '^null ' "$WORK/null-ours.txt" | tr '\n' ' ')" "$(grep '^null ' "$WORK/null-ref.txt" | tr '\n' ' ')"
expect "d3d12_null ran its 18 slots" "$(grep -c '^null ' "$WORK/null-ours.txt" || true)" 18
```

  `dxil-translate`'s test-shader count grows by one (`9/9` → `10/10`): update `check.sh`'s expectation.

- [ ] **Step 8: Commit**

```bash
git -C build/dxmt-src/dxmt add src/d3d12 src/airconv
git -C build/dxmt-src/dxmt commit -m "d3d12: null descriptors by view type

Null SRVs and UAVs were zero-filled whatever their type, handing shaders a nil texture. They now point at the
device's zeroed resources of the view's Metal type (created once; UAVs get their own), and raw and structured
buffers read zero through a zero length.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git add Makefile dxmt/check.sh dxmt/tests/d3d12_null.cpp dxmt/tests/shaders/null.hlsl dxmt/tests/shaders/null.cs.dxil dxmt/tests/shaders/compile.sh
git commit -m "test(dxmt): d3d12_null, null descriptors of every type against D3DMetal

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: GPU timestamps

**Files:**
- Create: `dxmt/tests/d3d12_timestamp.cpp`
- Modify: `Makefile`, `dxmt/check.sh`
- Fork modify:
  - `src/winemetal/winemetal.h`, `winemetal_thunks.h/.c`, `unix/winemetal_unix.c`, `Metal.hpp`;
  - `src/d3d12/d3d12_device.hpp` (`MTLD3D12QueryHeap` counters);
  - `src/d3d12/d3d12_query_heap.cpp`;
  - `src/d3d12/d3d12_command_encoder.hpp` (`EncoderData::samples`);
  - `src/d3d12/d3d12_command_list.cpp` (`EndQuery`, `ResolveQueryData` for timestamps);
  - `src/d3d12/d3d12_command_queue.cpp` (encoders with sample buffers, `GetTimestampFrequency`, `GetClockCalibration`);
  - `src/d3d12/d3d12_device.cpp` (the frequency, measured once).

**Interfaces:**
- Produces (winemetal):
  - `WMTRenderPassInfo::sample_buffers[4]` (`{obj_handle_t sample_buffer; uint64_t end_of_fragment_sample_index;}`, skipped when null);
  - `MTLCommandBuffer_computeCommandEncoderWithSampleBuffers(cmdbuf, concurrent, WMTSampleBufferAttachmentInfo *, n)` (unix call 147);
  - `MTLDevice_sampleTimestamps(device, uint64_t *cpu, uint64_t *gpu)` (unix call 148).
- Produces (d3d12):
  - `static constexpr uint32_t kTimestampsPerBuffer = 4096`;
  - `MTLD3D12QueryHeap::counters` (`std::vector<WMT::Reference<WMT::CounterSampleBuffer>>`, empty when the device can't sample);
  - `EncoderData::samples[4]` (`{obj_handle_t buffer; uint32_t index;}`) and `num_samples`;
  - `uint64_t MTLD3D12Device::TimestampFrequency()`.

- [ ] **Step 1: Write `dxmt/tests/d3d12_timestamp.cpp`**

```cpp
// GPU timestamps by D3D12's rules (D3DMetal has none, so this isn't compared with it):
//   d3d12_timestamp.exe <vs.dxil> <ps.dxil>
// Prints "timestamp rules <freq>0> <increasing> <advanced> <calibrated> <two lists> <chunks>" as 0/1 flags, then
// the raw values.
#include "d3d12_common.hpp"

int main(int argc, char **argv) {
    if (argc != 3) { printf("usage: d3d12_timestamp.exe <vs.dxil> <ps.dxil>\n"); return 2; }
    auto vs = Load(argv[1]), ps = Load(argv[2]);
    Gpu gpu;
    ID3D12RootSignature *root = CbvRootSignature(gpu);
    ID3D12PipelineState *pso = QuadPipeline(gpu, root, vs, ps);
    ID3D12Resource *target = gpu.Texture(Tex2D(1024, 1024, DXGI_FORMAT_R8G8B8A8_UNORM, 1, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET),
                                         D3D12_RESOURCE_STATE_RENDER_TARGET);
    ID3D12DescriptorHeap *rh; D3D12_DESCRIPTOR_HEAP_DESC rd = {D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 1};
    CHECK(gpu.device->CreateDescriptorHeap(&rd, __uuidof(ID3D12DescriptorHeap), (void **)&rh));
    auto rtv = rh->GetCPUDescriptorHandleForHeapStart();
    gpu.device->CreateRenderTargetView(target, nullptr, rtv);
    float draw[64] = {-1, -1, 1, 1, 1, 0, 0, 1, 0};
    ID3D12Resource *cb = gpu.Buffer(D3D12_HEAP_TYPE_UPLOAD, 256, D3D12_RESOURCE_STATE_GENERIC_READ);
    void *p; CHECK(cb->Map(0, nullptr, &p)); memcpy(p, draw, sizeof draw); cb->Unmap(0, nullptr);
    ID3D12QueryHeap *qh; D3D12_QUERY_HEAP_DESC qhd = {D3D12_QUERY_HEAP_TYPE_TIMESTAMP, 5000};
    CHECK(gpu.device->CreateQueryHeap(&qhd, __uuidof(ID3D12QueryHeap), (void **)&qh));
    ID3D12Resource *res = gpu.Buffer(D3D12_HEAP_TYPE_READBACK, 64, D3D12_RESOURCE_STATE_COPY_DEST);
    const auto TS = D3D12_QUERY_TYPE_TIMESTAMP;
    UINT64 freq = 0; CHECK(gpu.queue->GetTimestampFrequency(&freq));
    UINT64 g0, c0; CHECK(gpu.queue->GetClockCalibration(&g0, &c0));

    // List 1: 0 at its start, 1 after 200 full-screen draws, 2 between those and 200 more (mid-pass).
    gpu.list->EndQuery(qh, TS, 0);
    D3D12_VIEWPORT vp = {0, 0, 1024, 1024, 0, 1}; D3D12_RECT sc = {0, 0, 1024, 1024};
    gpu.list->OMSetRenderTargets(1, &rtv, FALSE, nullptr);
    gpu.list->RSSetViewports(1, &vp); gpu.list->RSSetScissorRects(1, &sc);
    gpu.list->SetGraphicsRootSignature(root); gpu.list->SetPipelineState(pso);
    gpu.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    gpu.list->SetGraphicsRootConstantBufferView(0, cb->GetGPUVirtualAddress());
    for (int i = 0; i < 200; i++) gpu.list->DrawInstanced(6, 1, 0, 0);
    gpu.list->EndQuery(qh, TS, 1);
    for (int i = 0; i < 200; i++) gpu.list->DrawInstanced(6, 1, 0, 0);
    gpu.list->EndQuery(qh, TS, 2);
    gpu.list->ResolveQueryData(qh, TS, 0, 3, res, 0);
    gpu.Submit();
    // List 2: 3, then 4095 and 4096 across the first counter buffer's end, resolved from 4094.
    gpu.list->EndQuery(qh, TS, 3);
    gpu.list->EndQuery(qh, TS, 4095);
    gpu.list->EndQuery(qh, TS, 4096);
    gpu.list->ResolveQueryData(qh, TS, 3, 1, res, 24);
    gpu.list->ResolveQueryData(qh, TS, 4095, 2, res, 32);
    gpu.Submit();
    UINT64 g1, c1; CHECK(gpu.queue->GetClockCalibration(&g1, &c1));
    UINT64 *t; CHECK(res->Map(0, nullptr, (void **)&t));
    int increasing = t[0] <= t[1] && t[1] <= t[2];
    int advanced = t[1] > t[0];
    int calibrated = g0 <= t[0] && t[2] <= g1 && t[4] <= g1 && t[5] <= g1;
    int two_lists = t[3] >= t[2];
    int chunks = t[3] <= t[4] && t[4] <= t[5] && t[5] != ~0ull && t[4] != ~0ull;
    printf("timestamp rules %d %d %d %d %d %d\n", freq > 0, increasing, advanced, calibrated, two_lists, chunks);
    printf("timestamp values freq %llu calib %llu..%llu ts %llu %llu %llu %llu %llu %llu\n", (unsigned long long)freq,
           (unsigned long long)g0, (unsigned long long)g1, (unsigned long long)t[0], (unsigned long long)t[1],
           (unsigned long long)t[2], (unsigned long long)t[3], (unsigned long long)t[4], (unsigned long long)t[5]);
    return 0;
}
```

  Add to `Makefile`: `$(MINGWXX) -std=c++17 -o build/dxmt-tests/d3d12_timestamp.exe dxmt/tests/d3d12_timestamp.cpp -ld3d12 -ldxgi`

- [ ] **Step 2: RED.** Run `sh dxmt/tests/run.sh d3d12_timestamp "$S/depth.vs.dxil" "$S/depth.ps.dxil"`.
  Expected: ours prints `timestamp rules 1 1 0 0 1 0` (all zeros, frequency 1); D3DMetal prints zeros too, for reference only.

- [ ] **Step 3: winemetal.**
  - **Render passes:** in `winemetal.h`, add after `obj_handle_t visibility_buffer;` in `WMTRenderPassInfo`:

```c
  struct WMTRenderPassSampleBufferInfo {
    obj_handle_t sample_buffer;            // null: unused
    uint64_t end_of_fragment_sample_index; // a timestamp at the end of the pass
  } sample_buffers[4];
```

  - **Unix side:** in `_MTLCommandBuffer_renderCommandEncoder`'s descriptor setup:

```objc
  for (unsigned i = 0; i < 4; i++) {
    if (!info->sample_buffers[i].sample_buffer)
      continue;
    MTLRenderPassSampleBufferAttachmentDescriptor *s = descriptor.sampleBufferAttachments[i];
    s.sampleBuffer = (id<MTLCounterSampleBuffer>)info->sample_buffers[i].sample_buffer;
    s.startOfVertexSampleIndex = MTLCounterDontSample;
    s.endOfVertexSampleIndex = MTLCounterDontSample;
    s.startOfFragmentSampleIndex = MTLCounterDontSample;
    s.endOfFragmentSampleIndex = info->sample_buffers[i].end_of_fragment_sample_index;
  }
```

  - **Compute encoder with sample buffers** (unix call 147): the same shape as `_MTLCommandBuffer_blitCommandEncoderWithSampleBuffers`, with `MTLComputePassDescriptor`. Set `dispatchType = concurrent ? MTLDispatchTypeConcurrent : MTLDispatchTypeSerial`, `startOfEncoderSampleIndex`/`endOfEncoderSampleIndex` from `WMTSampleBufferAttachmentInfo` (`~0ull` = `MTLCounterDontSample`), then `[cmdbuf computeCommandEncoderWithDescriptor:]`.
  - **`sampleTimestamps`** (unix call 148):

```objc
static NTSTATUS
_MTLDevice_sampleTimestamps(void *obj) {
  struct unixcall_mtldevice_sampletimestamps *params = obj; // {device; uint64_t cpu; uint64_t gpu;}
  MTLTimestamp cpu = 0, gpu = 0;
  [(id<MTLDevice>)params->device sampleTimestamps:&cpu gpuTimestamp:&gpu];
  params->cpu = cpu;
  params->gpu = gpu;
  return STATUS_SUCCESS;
}
```

  - **Registration:** add both to the two call tables (147, 148), their thunks, `winemetal.h` declarations, and `Metal.hpp` wrappers:
    - `CommandBuffer::computeCommandEncoderWithSampleBuffers(bool, WMTSampleBufferAttachmentInfo *, uint64_t)`;
    - `Device::sampleTimestamps(uint64_t &cpu, uint64_t &gpu)`.

- [ ] **Step 4: Query heap counters.** In `d3d12_query_heap.cpp`, for `D3D12_QUERY_HEAP_TYPE_TIMESTAMP`, create `ceil(Count / kTimestampsPerBuffer)` sample buffers:

```cpp
    if (pDesc->Type == D3D12_QUERY_HEAP_TYPE_TIMESTAMP) {
      auto metal = device_->GetMTLDevice();
      for (uint32_t first = 0; first < pDesc->Count; first += kTimestampsPerBuffer) {
        auto samples = metal.newCounterSampleBuffer(std::min(kTimestampsPerBuffer, pDesc->Count - first), false);
        if (!samples) { // no stage-boundary sampling: timestamps resolve to zeros, as before
          counters.clear();
          break;
        }
        counters.push_back(std::move(samples));
      }
    }
```

  `false` is private storage, which `resolveCounters` reads on the GPU. Declare `counters` and `kTimestampsPerBuffer` in `MTLD3D12QueryHeap` (`d3d12_device.hpp`).

- [ ] **Step 5: Encoders carry samples.** In `d3d12_command_encoder.hpp`'s `EncoderData`:

```cpp
  // Timestamps written at this encoder's end (MacNeutron; Metal samples only at stage boundaries).
  struct { obj_handle_t buffer; uint32_t index; } samples[4];
  uint8_t num_samples = 0;
```

  In `d3d12_command_queue.cpp`'s `ExecuteCommandLists`:
  - **Render:** copy `data->samples[i]` into `render_pass_info.sample_buffers[i]`.
  - **Compute:** when `data->num_samples`, create the encoder with `cmdbuf.computeCommandEncoderWithSampleBuffers(false, …)`, with `start = ~0ull` and `end = index`.
  - **Blit:** likewise with `blitCommandEncoderWithSampleBuffers`.
  
  `Clear` and `Resolve` encoders never carry samples.

- [ ] **Step 6: `EndQuery` and `ResolveQueryData`** (command list)

```cpp
  // A timestamp is sampled at an encoder boundary: the end of the open render pass (never split: a timestamp between
  // draws reads its pass's end), else the end of the open blit or compute encoder, which then closes, or an empty
  // blit encoder's end.
  void
  EndTimestamp(MTLD3D12QueryHeap *heap, UINT Index) {
    if (heap->counters.empty())
      return;
    auto buffer = heap->counters[Index / kTimestampsPerBuffer].handle;
    auto current = allocator_->encoder_current;
    bool render = current && current->type == EncoderType::Render;
    if (!render && (!current || (current->type != EncoderType::Blit && current->type != EncoderType::Compute))) {
      PreBlit();
      current = allocator_->encoder_current;
    }
    if (current->num_samples == std::size(current->samples)) { // four per encoder: an empty blit encoder takes more
      allocator_->InvalidateCurrentPass();
      PreBlit();
      current = allocator_->encoder_current;
      render = false;
    }
    current->samples[current->num_samples++] = {buffer, Index % kTimestampsPerBuffer};
    if (!render)
      allocator_->InvalidateCurrentPass(); // later work goes to a new encoder, so this sample marks this point
  }
```

  `EndQuery` calls `EndTimestamp(static_cast<MTLD3D12QueryHeap *>(pHeap), Index)` for `D3D12_QUERY_TYPE_TIMESTAMP`. In `ResolveQueryData`, for `D3D12_QUERY_TYPE_TIMESTAMP` with counters, replace the copy with one `resolveCounters` per sample buffer the range touches:

```cpp
    if (Type == D3D12_QUERY_TYPE_TIMESTAMP && !heap->counters.empty()) {
      auto dst = static_cast<MTLD3D12Resource *>(pDstBuffer)->buffer->current()->buffer();
      for (UINT i = StartIndex; i < StartIndex + QueryCount;) {
        UINT chunk = i / kTimestampsPerBuffer, first = i % kTimestampsPerBuffer;
        UINT n = std::min<UINT>(kTimestampsPerBuffer - first, StartIndex + QueryCount - i);
        auto &cmd = allocator_->EncodeBlitCommand<wmtcmd_blit_resolvecounters>();
        cmd.type = WMTBlitCommandResolveCounters;
        cmd.sample_buffer = heap->counters[chunk].handle;
        cmd.range = {first, n};
        cmd.dst = dst;
        cmd.dst_offset = AlignedDstBufferOffset + (i - StartIndex) * sizeof(UINT64);
        i += n;
      }
      return;
    }
```

  Use the actual field names of `wmtcmd_blit_resolvecounters` in `winemetal.h`.

- [ ] **Step 7: Frequency and calibration.**
  - **`MTLD3D12Device::TimestampFrequency()`:** measured once, under a `std::once_flag`, against `QueryPerformanceCounter`, whose frequency is known. Taking `sampleTimestamps` 10 ms apart gives GPU ticks per second, not Metal's CPU clock units:

```cpp
  uint64_t
  TimestampFrequency() {
    std::call_once(timestamp_once_, [&] {
      uint64_t cpu0, gpu0, cpu1, gpu1;
      LARGE_INTEGER q0, q1, qf;
      QueryPerformanceFrequency(&qf);
      QueryPerformanceCounter(&q0); GetMTLDevice().sampleTimestamps(cpu0, gpu0);
      Sleep(10);
      QueryPerformanceCounter(&q1); GetMTLDevice().sampleTimestamps(cpu1, gpu1);
      timestamp_frequency_ = gpu1 > gpu0 && q1.QuadPart > q0.QuadPart
                                 ? (uint64_t)((double)(gpu1 - gpu0) * qf.QuadPart / (q1.QuadPart - q0.QuadPart) + 0.5)
                                 : 1;
    });
    return timestamp_frequency_;
  }
```

  - **The queue:** `GetTimestampFrequency` returns `device_->TimestampFrequency()`. `GetClockCalibration` reads `QueryPerformanceCounter`, then `sampleTimestamps`, then `QueryPerformanceCounter` again, and returns the GPU value with the two QPC readings averaged.

- [ ] **Step 8: GREEN.** Run as in Step 2.
  Expected: ours prints `timestamp rules 1 1 1 1 1 1`. Then check the pass-dump rule: `RUN_ENV="DXMT_DXIL_DUMP=$TMPDIR/ts DXMT_DUMP_FRAME=0" sh dxmt/tests/run.sh d3d12_timestamp …`, then `grep -c ' render ' $TMPDIR/ts/passes.txt`. Expected: 1, so the 400 draws with a timestamp between them stay one render pass.

- [ ] **Step 9: `check.sh`**

```sh
# GPU timestamps by D3D12's rules (D3DMetal has none), and a timestamp between draws never splits their pass.
rm -rf "$WORK/ts"; export DXMT_DXIL_DUMP="$WORK/ts" DXMT_DUMP_FRAME=0
run ours ts-ours dxmt "$TESTS/d3d12_timestamp.exe" "Z:$S/depth.vs.dxil" "Z:$S/depth.ps.dxil"
unset DXMT_DXIL_DUMP DXMT_DUMP_FRAME
expect "timestamps: frequency, increasing, advancing, calibrated, across lists and counter buffers" \
  "$(grep '^timestamp rules' "$WORK/ts-ours.txt" || true)" "timestamp rules 1 1 1 1 1 1"
expect "a timestamp between draws keeps them one render pass" "$(grep -c ' render ' "$WORK/ts/passes.txt" 2> /dev/null || true)" 1
```

- [ ] **Step 10: Commit**

```bash
git -C build/dxmt-src/dxmt add src/winemetal src/d3d12
git -C build/dxmt-src/dxmt commit -m "d3d12: GPU timestamps

Timestamps were zeros with a frequency of 1. EndQuery samples Metal's GPU clock at an encoder boundary (the end of
the open render pass, never splitting it; the end of a blit or compute encoder; an empty blit encoder), into the
query heap's counter sample buffers; ResolveQueryData resolves them on the GPU straight into the destination. The
frequency is measured once against QueryPerformanceCounter, and GetClockCalibration pairs Metal's GPU clock with
QPC. winemetal gains render and compute pass sample buffers and sampleTimestamps.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git add Makefile dxmt/check.sh dxmt/tests/d3d12_timestamp.cpp
git commit -m "test(dxmt): d3d12_timestamp, GPU timestamps by D3D12's rules

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Batch 2 delivery, SMITE 2 and acceptance

**Files:**
- Create: `docs/testing/acceptance-dxmt-d3d12-stubs.md`
- Modify: `dxmt/pins`

- [ ] **Step 1: Push, pin, check.**

```bash
git -C build/dxmt-src/dxmt push origin macneutron
sed -i '' "s/^DXMT_COMMIT=.*/DXMT_COMMIT=$(git -C build/dxmt-src/dxmt rev-parse HEAD)/" dxmt/pins
make dxmt-check
```

  Expected: `dxmt-check: all passed`. Install the runtime: `.build/release/macneutron install-dxmt build/dxmt`.

- [ ] **Step 2: SMITE 2 (the maintainer's run).** Ask the maintainer to launch SMITE 2 on our DXMT (launch options `/usr/bin/env DXMT_DXIL_DUMP=/Users/chad/dxil-smite2 %command%`), reach the lobby, play a match and quit. Then check:
  - **Grep:** `grep -c "unhandled feature\|is not implemented" ~/Library/Logs/MacNeutron/steam-2437170.log` over this run's lines. Expected: 0.
  - **Game log:** has no `GetResourceAllocationInfo failed` beyond the four known small-alignment lines.
  - **Lobby:** renders as on D3DMetal.

- [ ] **Step 3: Acceptance record.** Write `docs/testing/acceptance-dxmt-d3d12-stubs.md` in the style of `docs/testing/acceptance-dxil-translator.md`:
  - the fork commit;
  - `make dxmt-check`'s result;
  - each test's comparison;
  - the SMITE 2 run (date, lobby, match, the grep counts).

- [ ] **Step 4: Commit batch 2**

```bash
git add dxmt/pins docs/testing/acceptance-dxmt-d3d12-stubs.md
git commit -m "fix(dxmt): batch 2 of the D3D12 stubs and GPU timestamps (fork $(git -C build/dxmt-src/dxmt rev-parse --short HEAD))

Read-only depth and stencil views, reinterpreting copies, null descriptors and real GPU timestamps; SMITE 2's
acceptance run recorded.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
