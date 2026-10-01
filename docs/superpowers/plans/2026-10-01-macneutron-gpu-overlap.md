# DXMT Fork, Sub-project 4 (second slice, M1 + M2: GPU Work Overlap) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On our DXMT, a D3D12 game's Metal encoders stop waiting on every earlier encoder: work between two `ResourceBarrier` calls may overlap (M1), and a barrier that ends a render target, depth, copy or resolve write waits only on that resource's writers (M2). The picture stays the same.

**Architecture:**
- **Recording (command list and allocator):** every encoder lists the resources it writes. When it closes, the allocator decides what it waits on, from the barriers recorded since the previous encoder began:
  - a **join**: all earlier work;
  - or a **dependency list**: positions of earlier encoders of its list, since the list's last join.
- **Encoding (queue):** each encoder updates its own fence, from a ring of 256 per queue.
  - A join waits on every encoder since the last join.
  - Any other encoder waits on what that join waited on, plus its dependencies' fences.
  - `DXMT_D3D12_SERIAL=1`, F9 dumps and pixel history make every encoder a join: today's strict chain.
- **Milestones:**
  - **M1 (Tasks 1–3):** hazard tests; then barrier groups, where every barrier is a join; then SMITE 2 numbers.
  - **M2 (Tasks 4–5):** barriers are classified; then SMITE 2 numbers.
  - M3–M5 get their own plans after Task 5, per the spec's order.

**Tech Stack:**
- Fork: C++20.
- Tests: Windows C++ test programs built with llvm-mingw Clang, HLSL compiled to DXIL by DXC under Wine, and POSIX sh for `check.sh`.
- Measurement: Python 3 and `xctrace`.

**Spec:** `docs/superpowers/specs/2026-10-01-macneutron-gpu-overlap-design.md`

## Global Constraints

- **Fork:** `github.com/chadouming/dxmt`, branch `macneutron`.
  - Never send anything upstream (DXMT refuses AI-authored contributions).
  - Before editing, run `git -C build/dxmt-src/dxmt switch macneutron`: `build.sh` leaves the clone detached at the pin, and so does every `make dxmt-check`.
  - To land fork work: commit it, `git -C build/dxmt-src/dxmt push origin macneutron`, then write the new head into `dxmt/pins` (`DXMT_COMMIT=`). `make dxmt-check` builds the pinned commit only.
  - Never edit `dxmt/check.sh` or fork files while `make dxmt-check` runs: `sh` reads the script as it goes, and the build compiles the fork tree.
- **Commit trailer:** every fork and MacNeutron commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Reference:** D3DMetal on the same Mac, GPTK imported. Every `hazard` line must equal D3DMetal's and the fixed value in `check.sh`. The counters are ours only.
- **Dev loop:** `sh dxmt/tests/run.sh <test> [args]`. It rebuilds the fork's working tree, installs it into `check.sh`'s "ours" clone, and runs the test on our DXMT, then on D3DMetal. Extra variables go in `RUN_ENV="A=1 B=2"`, which reaches both runs.
- **Full check:** `make dxmt-check > "$W/check-tN.log" 2>&1`, where `W=.superpowers/sdd/2026-10-01-macneutron-gpu-overlap` is the plan's git-ignored workspace (`mkdir -p "$W"` once). Read its `FAIL` lines and its last line. Swift: `swift test 2>&1 | tail -5`.
- **Spec rules:**
  - Anything not provably safe is a join.
  - `DXMT_D3D12_SERIAL=1` keeps a single strict chain, and F9 dumps and pixel history always use it.
  - No core, GPU-model or core-count assumptions: everything follows from what the game recorded.
  - Timestamps become coarser with overlap (spec §3.5). The existing `timestamp rules` check must stay green.
- **Installing into the tool folder:** `.build/release/macneutron install-dxmt build/dxmt`, only while SMITE 2 isn't running (`pgrep -f Hemingway-Win64` prints nothing).
- **Privacy and Steam:**
  - SMITE 2's captures and dumps (`~/dxil-smite2`) never enter git.
  - Never edit Steam's config: the user changes launch options themselves.
- **Deliberate ceilings:** mark them with `// ponytail:` comments naming the upgrade path.
- **Choices:** pick the default option when a question comes up.

### Decisions this plan makes where the spec is silent or loose

- **Where dependencies are decided.** Spec §3.2 puts the decision in `AllocatePass`. This plan decides when the encoder closes (`InvalidateCurrentPass`), because only then is its write set complete: copies keep adding destinations to an open blit encoder.
- **What a group's later encoders wait on.** They wait on what the group's join waited on, not on the join itself. A group is the encoders after a join, until the next one. Waiting on the join would serialize the first two encoders of every group, and most groups in SMITE 2 have two or three encoders.
- **Barriers inside an open encoder.** Consecutive dispatches share one compute encoder, and consecutive copies share one blit encoder. A barrier recorded before an encoder's last command binds that whole encoder. The command funnels record the barrier count at each command for this.
- **A queue `Wait`.** Spec §3.3 has the first encoder after it join. That needs no code: the next encoder is always a command list's first, which joins.
- **F9 comparison.** Dumps and pixel history run in strict order, so an F9 dump can't show an M1 or M2 ordering bug. M1 and M2's picture check is an A/B by eye against `DXMT_D3D12_SERIAL=1`. The F9 comparison of §7 belongs to M3 and M4, which change the passes.
- **The hazard tests' failing run.** Task 1's tests guard behaviour that is correct today, because today every encoder waits on the previous one. Their failing run is a temporary mutation that removes the waits (Task 1, Step 6).

## Review Focus

- **A barrier inside an open encoder.** For example: a copy into X; a dispatch elsewhere opens a compute encoder; a barrier on X; a dispatch reading X in that same encoder. The second dispatch must see the copy. Test: `hazard mid-pass 77` (Task 1). Code: `barriers_last` in the command funnels (Task 2).
- **One command list executed twice back to back.** Positions repeat, and fences come from the queue, not the list. Test: `hazard twice 514` (Task 1).
- **More encoders in one list than the queue has fences (256).** The ring must force a join, never reuse a fence someone may still wait on. Test: `hazard many 1200 1200` (Task 1).
- **Passes DXMT records for itself.** Rectangle clears and UAV clears declare no writes, so they must join, and later encoders must wait on them. Test: `hazard clear-rects 3 256` (Task 1).
- **F9 dumps and pixel history while overlap is on.** The queue's own encoders must join, and the game's encoders must still wait on them. Test: the `hazards-dump` run in `check.sh` (Task 1), which exercises `Join` (Task 2).

---

### Task 1: Hazard tests (M1 and M2 regression guards)

**Files:**
- Create: `dxmt/tests/shaders/hazards.hlsl`, and its six compiled shaders `dxmt/tests/shaders/hazards.{vsfull,psvalue,pssample,csfill,cscount,csargs}.dxil`
- Create: `dxmt/tests/d3d12_hazards.cpp`
- Modify: `dxmt/tests/shaders/compile.sh` (6 lines), `dxmt/tests/d3d12_common.hpp` (`Submit`), `Makefile` (`dxmt-tests`), `dxmt/check.sh` (a new section 8, and section 6's shader counts)

**Interfaces:**
- Produces:
  - `d3d12_hazards.exe <shader folder> [mode...]`. With no mode, it runs every mode in order: `rt-read same-target uav copy-read indirect aliasing occlusion independent precise mid-pass twice many clear-rects`.
  - Each mode prints one line, `hazard <mode> <values>`. Tasks 2 and 4 run `independent` and `precise` with `DXMT_STATS` and read `stats.txt`.
  - `Gpu::Submit(int times = 1)`: runs the list `times` times back to back.

- [ ] **Step 1: Write the shaders**

Create `dxmt/tests/shaders/hazards.hlsl`:

```hlsl
// Encoder ordering tests (d3d12_hazards.cpp): heavy work, then work that reads, overwrites or reuses what it wrote.
cbuffer Constants : register(b0) { float value; uint loops; };
Texture2D<float4> Source : register(t0);
RWByteAddressBuffer Data : register(u0);

// A triangle covering the whole target.
float4 vsfull(uint id : SV_VertexID) : SV_Position {
    float2 uv = float2((id << 1) & 2, id & 2);
    return float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
}
// `value` everywhere (with additive blending, each instance adds it).
float4 psvalue() : SV_Target0 { return value; }
// The source texel under the pixel, plus `value`.
float4 pssample(float4 pos : SV_Position) : SV_Target0 { return Source.Load(int3(pos.xy, 0)) + value; }
// Every thread adds 1 to word 0.
[numthreads(64, 1, 1)] void csfill() { Data.InterlockedAdd(0, 1); }
// Copies word 0 to word 1.
[numthreads(1, 1, 1)] void cscount() { Data.Store(4, Data.Load(0)); }
// Spins `loops` times, then writes one draw's arguments: 3 vertices, 1 instance.
[numthreads(1, 1, 1)] void csargs() {
    uint x = 1;
    for (uint i = 0; i < loops; i++)
        x = x * 1664525 + 1013904223;
    Data.Store4(0, uint4(3, x == 0 ? 2 : 1, 0, 0));
}
```

In `dxmt/tests/shaders/compile.sh`, after the line `dxc -T cs_6_6 -E csmain -Fo indirect.cs.dxil indirect.hlsl`, add:

```sh
dxc -T vs_6_6 -E vsfull -Fo hazards.vsfull.dxil hazards.hlsl
dxc -T ps_6_6 -E psvalue -Fo hazards.psvalue.dxil hazards.hlsl
dxc -T ps_6_6 -E pssample -Fo hazards.pssample.dxil hazards.hlsl
dxc -T cs_6_6 -E csfill -Fo hazards.csfill.dxil hazards.hlsl
dxc -T cs_6_6 -E cscount -Fo hazards.cscount.dxil hazards.hlsl
dxc -T cs_6_6 -E csargs -Fo hazards.csargs.dxil hazards.hlsl
```

Run: `sh dxmt/tests/shaders/compile.sh 2>&1 | grep -c 'hazards\.'`
Expected: `6` (six `ls -l` lines for the new files), and `git status --short dxmt/tests/shaders` lists only `hazards.hlsl`, `compile.sh` and the six new `.dxil` files. The other shaders recompile to the same bytes.

- [ ] **Step 2: Let a test run a list twice**

In `dxmt/tests/d3d12_common.hpp`, replace:

```cpp
    // Closes the list, runs it, waits (10 s at most) and reopens it.
    void Submit() {
        CHECK(list->Close());
        ID3D12CommandList *lists[] = {list};
        queue->ExecuteCommandLists(1, lists);
```

with:

```cpp
    // Closes the list, runs it `times` times back to back, waits (10 s at most) and reopens it.
    void Submit(int times = 1) {
        CHECK(list->Close());
        ID3D12CommandList *lists[] = {list};
        for (int i = 0; i < times; i++)
            queue->ExecuteCommandLists(1, lists);
```

- [ ] **Step 3: Write the test program**

Create `dxmt/tests/d3d12_hazards.cpp`:

```cpp
// Encoder ordering (GPU overlap spec §5): each mode's first pass is heavy, so work after it that doesn't wait for it
// reads or overwrites its results too early. Shaders: shaders/hazards.hlsl, one .dxil per entry point.
//   d3d12_hazards.exe <shader folder> [mode...]   (no mode: every mode)
// Prints "hazard <mode> <values>" per mode. check.sh compares them with fixed values, on our DXMT (with overlap, in
// strict order, and while dumping passes) and on D3DMetal.
#include "d3d12_common.hpp"
#include <cmath>
#include <string>

static const UINT kSize = 1024;
static const DXGI_FORMAT kFormat = DXGI_FORMAT_R16G16B16A16_FLOAT; // blendable on every Mac; exact integers to 2048
static const auto RT = D3D12_RESOURCE_STATE_RENDER_TARGET, PSR = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,
                  UA = D3D12_RESOURCE_STATE_UNORDERED_ACCESS, COPY_DEST = D3D12_RESOURCE_STATE_COPY_DEST,
                  COPY_SOURCE = D3D12_RESOURCE_STATE_COPY_SOURCE;

struct Target {
    ID3D12Resource *texture;
    D3D12_CPU_DESCRIPTOR_HANDLE rtv;
    D3D12_GPU_DESCRIPTOR_HANDLE srv;
};

static Gpu *g;
static ID3D12RootSignature *root, *croot;
static ID3D12PipelineState *add, *set, *sample, *add_sample, *fill, *count, *args;
static ID3D12CommandSignature *draw_signature;
static ID3D12DescriptorHeap *rtv_heap, *srv_heap;
static UINT targets_made;
static ID3D12Resource *readback; // 64 slots of 512 bytes
static Target T[3];

static float Half(uint16_t h) { // the positive halfs these tests write
    int e = h >> 10 & 31, m = h & 1023;
    return e ? std::ldexp(1024.0f + m, e - 25) : std::ldexp((float)m, -24);
}

static Target MakeTarget(ID3D12Resource *texture = nullptr) {
    if (!texture)
        texture = g->Texture(Tex2D(kSize, kSize, kFormat, 1, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET), RT);
    UINT rs = g->device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    UINT ss = g->device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    Target t = {texture, rtv_heap->GetCPUDescriptorHandleForHeapStart(), srv_heap->GetGPUDescriptorHandleForHeapStart()};
    D3D12_CPU_DESCRIPTOR_HANDLE srv = srv_heap->GetCPUDescriptorHandleForHeapStart();
    t.rtv.ptr += targets_made * rs;
    t.srv.ptr += targets_made * ss;
    srv.ptr += targets_made * ss;
    targets_made++;
    g->device->CreateRenderTargetView(texture, nullptr, t.rtv);
    g->device->CreateShaderResourceView(texture, nullptr, srv);
    return t;
}

static ID3D12PipelineState *Graphics(const std::vector<char> &vs, const std::vector<char> &ps, bool additive) {
    D3D12_GRAPHICS_PIPELINE_STATE_DESC gd = {};
    gd.pRootSignature = root;
    gd.VS = {vs.data(), vs.size()};
    gd.PS = {ps.data(), ps.size()};
    auto &blend = gd.BlendState.RenderTarget[0];
    blend.RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    if (additive) {
        blend.BlendEnable = TRUE;
        blend.SrcBlend = blend.DestBlend = blend.SrcBlendAlpha = blend.DestBlendAlpha = D3D12_BLEND_ONE;
        blend.BlendOp = blend.BlendOpAlpha = D3D12_BLEND_OP_ADD;
    }
    gd.SampleMask = UINT_MAX;
    gd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    gd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    gd.RasterizerState.DepthClipEnable = TRUE;
    gd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    gd.NumRenderTargets = 1;
    gd.RTVFormats[0] = kFormat;
    gd.SampleDesc.Count = 1;
    ID3D12PipelineState *pso;
    CHECK(g->device->CreateGraphicsPipelineState(&gd, __uuidof(ID3D12PipelineState), (void **)&pso));
    return pso;
}

static ID3D12PipelineState *Compute(const std::vector<char> &cs) {
    D3D12_COMPUTE_PIPELINE_STATE_DESC cd = {croot, {cs.data(), cs.size()}};
    ID3D12PipelineState *pso;
    CHECK(g->device->CreateComputePipelineState(&cd, __uuidof(ID3D12PipelineState), (void **)&pso));
    return pso;
}

static void Clear(Target &t) {
    const float zero[4] = {0, 0, 0, 0};
    g->list->ClearRenderTargetView(t.rtv, zero, 0, nullptr);
}

// Sets up a full-screen draw into `t` with `pso` and its constant `value` (sampling `from`, for the sample pipelines).
static void Bind(Target &t, ID3D12PipelineState *pso, float value, Target *from = nullptr) {
    auto *l = g->list;
    D3D12_VIEWPORT vp = {0, 0, (float)kSize, (float)kSize, 0, 1};
    D3D12_RECT sc = {0, 0, (LONG)kSize, (LONG)kSize};
    l->OMSetRenderTargets(1, &t.rtv, FALSE, nullptr);
    l->RSSetViewports(1, &vp);
    l->RSSetScissorRects(1, &sc);
    l->SetDescriptorHeaps(1, &srv_heap);
    l->SetGraphicsRootSignature(root);
    l->SetPipelineState(pso);
    l->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    UINT constants[2] = {0, 0};
    memcpy(&constants[0], &value, 4);
    l->SetGraphicsRoot32BitConstants(0, 2, constants, 0);
    if (from)
        l->SetGraphicsRootDescriptorTable(1, from->srv);
}

// `instances` full-screen triangles into `t` (with additive blending, each adds `value`).
static void Pass(Target &t, ID3D12PipelineState *pso, float value, UINT instances, Target *from = nullptr) {
    Bind(t, pso, value, from);
    g->list->DrawInstanced(3, instances, 0, 0);
}

// `groups` groups of `pso` on buffer `b` (u0), spinning `loops` times where the shader does.
static void Dispatch(ID3D12PipelineState *pso, ID3D12Resource *b, UINT groups, UINT loops = 0) {
    auto *l = g->list;
    UINT constants[2] = {0, loops};
    l->SetComputeRootSignature(croot);
    l->SetPipelineState(pso);
    l->SetComputeRoot32BitConstants(0, 2, constants, 0);
    l->SetComputeRootUnorderedAccessView(1, b->GetGPUVirtualAddress());
    l->Dispatch(groups, 1, 1);
}

// A default-heap buffer of `size` zero bytes (UAV-capable), left in `state`.
static ID3D12Resource *Zeroed(UINT64 size, D3D12_RESOURCE_STATES state) {
    ID3D12Resource *upload = g->Buffer(D3D12_HEAP_TYPE_UPLOAD, size, D3D12_RESOURCE_STATE_GENERIC_READ);
    void *p;
    CHECK(upload->Map(0, nullptr, &p));
    memset(p, 0, size);
    upload->Unmap(0, nullptr);
    ID3D12Resource *b = g->Buffer(D3D12_HEAP_TYPE_DEFAULT, size, COPY_DEST, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    g->list->CopyBufferRegion(b, 0, upload, 0, size);
    if (state != COPY_DEST)
        g->Barrier(b, COPY_DEST, state);
    g->Submit();
    upload->Release();
    return b;
}

// Copies texel (x, y) of `t` (in `state`) into readback slot `slot`.
static void Read(Target &t, D3D12_RESOURCE_STATES state, UINT x, UINT y, UINT slot) {
    g->Barrier(t.texture, state, COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION src = {t.texture, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX};
    src.SubresourceIndex = 0;
    D3D12_TEXTURE_COPY_LOCATION dst = {readback, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT};
    dst.PlacedFootprint = {(UINT64)slot * 512, {kFormat, 1, 1, 1, 256}};
    D3D12_BOX box = {x, y, 0, x + 1, y + 1, 1};
    g->list->CopyTextureRegion(&dst, 0, 0, 0, &src, &box);
    g->Barrier(t.texture, COPY_SOURCE, state);
}

// Copies `bytes` at `offset` of buffer `b` (in `state`) into readback slot `slot`.
static void ReadBuffer(ID3D12Resource *b, D3D12_RESOURCE_STATES state, UINT64 offset, UINT bytes, UINT slot) {
    g->Barrier(b, state, COPY_SOURCE);
    g->list->CopyBufferRegion(readback, slot * 512, b, offset, bytes);
    g->Barrier(b, COPY_SOURCE, state);
}

// After the list ran: slot `slot`'s first channel, or its first `bytes` as an integer.
static float Texel(UINT slot) {
    uint8_t *r;
    D3D12_RANGE whole = {0, 64 * 512}, none = {0, 0};
    CHECK(readback->Map(0, &whole, (void **)&r));
    uint16_t h;
    memcpy(&h, r + slot * 512, 2);
    readback->Unmap(0, &none);
    return Half(h);
}
static unsigned long long Word(UINT slot, UINT bytes) {
    uint8_t *r;
    D3D12_RANGE whole = {0, 64 * 512}, none = {0, 0};
    CHECK(readback->Map(0, &whole, (void **)&r));
    unsigned long long v = 0;
    memcpy(&v, r + slot * 512, bytes);
    readback->Unmap(0, &none);
    return v;
}

// T0 rendered (heavy); a barrier RENDER_TARGET -> PIXEL_SHADER_RESOURCE; T1 = T0 sampled + 1.
static void RtRead() {
    Clear(T[0]);
    Pass(T[0], add, 1, 256);
    g->Barrier(T[0].texture, RT, PSR);
    Pass(T[1], sample, 1, 1, &T[0]);
    g->Barrier(T[0].texture, PSR, RT);
    Read(T[1], RT, 512, 512, 0);
    g->Submit();
    printf("hazard rt-read %g\n", Texel(0));
}

// No barrier: T0 (heavy), T1, then T0 again, replacing it. The last pass into T0 wins.
static void SameTarget() {
    Clear(T[0]);
    Pass(T[0], add, 1, 256);
    Pass(T[1], set, 5, 1);
    Pass(T[0], set, 7, 1);
    Read(T[0], RT, 512, 512, 0);
    Read(T[1], RT, 512, 512, 1);
    g->Submit();
    printf("hazard same-target %g %g\n", Texel(0), Texel(1));
}

// A dispatch adds 1 per thread to word 0 (heavy); a copy elsewhere; a UAV barrier; a dispatch copies word 0 to word 1.
static void Uav() {
    ID3D12Resource *b = Zeroed(256, UA), *elsewhere = Zeroed(256, COPY_DEST), *zeros = Zeroed(256, COPY_SOURCE);
    Dispatch(fill, b, 16384);
    g->list->CopyBufferRegion(elsewhere, 0, zeros, 0, 256);
    D3D12_RESOURCE_BARRIER barrier = {D3D12_RESOURCE_BARRIER_TYPE_UAV};
    barrier.UAV.pResource = b;
    g->list->ResourceBarrier(1, &barrier);
    Dispatch(count, b, 1);
    ReadBuffer(b, UA, 4, 4, 0);
    g->Submit();
    printf("hazard uav %llu\n", Word(0, 4));
}

// 16 copies of 5s into T2; a barrier COPY_DEST -> PIXEL_SHADER_RESOURCE; T1 = T2 sampled + 1.
static void CopyRead() {
    const UINT pitch = kSize * 8;
    ID3D12Resource *upload = g->Buffer(D3D12_HEAP_TYPE_UPLOAD, (UINT64)pitch * kSize, D3D12_RESOURCE_STATE_GENERIC_READ);
    uint16_t *p;
    CHECK(upload->Map(0, nullptr, (void **)&p));
    for (UINT i = 0; i < kSize * kSize * 4; i++)
        p[i] = 0x4500; // 5.0
    upload->Unmap(0, nullptr);
    g->Barrier(T[2].texture, RT, COPY_DEST);
    D3D12_TEXTURE_COPY_LOCATION src = {upload, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT};
    src.PlacedFootprint = {0, {kFormat, kSize, kSize, 1, pitch}};
    D3D12_TEXTURE_COPY_LOCATION dst = {T[2].texture, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX};
    dst.SubresourceIndex = 0;
    for (int i = 0; i < 16; i++)
        g->list->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
    g->Barrier(T[2].texture, COPY_DEST, PSR);
    Pass(T[1], sample, 1, 1, &T[2]);
    g->Barrier(T[2].texture, PSR, RT);
    Read(T[1], RT, 512, 512, 0);
    g->Submit();
    printf("hazard copy-read %g\n", Texel(0));
}

// A dispatch spins, then writes one draw's arguments; a barrier UNORDERED_ACCESS -> INDIRECT_ARGUMENT; ExecuteIndirect
// draws 9 into T0 with them (arguments read too early are zeros: no draw).
static void Indirect() {
    ID3D12Resource *a = Zeroed(16, UA);
    Clear(T[0]);
    Dispatch(args, a, 1, 1u << 22);
    g->Barrier(a, UA, D3D12_RESOURCE_STATE_INDIRECT_ARGUMENT);
    Bind(T[0], set, 9);
    g->list->ExecuteIndirect(draw_signature, 1, a, 0, nullptr, 0);
    g->Barrier(a, D3D12_RESOURCE_STATE_INDIRECT_ARGUMENT, UA);
    Read(T[0], RT, 512, 512, 0);
    g->Submit();
    printf("hazard indirect %g\n", Texel(0));
}

// P and Q share one heap's memory: P rendered (heavy); an aliasing barrier P -> Q; Q cleared, then 2 drawn: 2.
static void Aliasing() {
    D3D12_RESOURCE_DESC desc = Tex2D(kSize, kSize, kFormat, 1, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET);
    D3D12_HEAP_DESC hd = {};
    hd.SizeInBytes = 32 << 20;
    hd.Properties.Type = D3D12_HEAP_TYPE_DEFAULT;
    hd.Alignment = D3D12_DEFAULT_RESOURCE_PLACEMENT_ALIGNMENT;
    hd.Flags = D3D12_HEAP_FLAG_ALLOW_ONLY_RT_DS_TEXTURES;
    ID3D12Heap *heap;
    CHECK(g->device->CreateHeap(&hd, __uuidof(ID3D12Heap), (void **)&heap));
    ID3D12Resource *p, *q;
    CHECK(g->device->CreatePlacedResource(heap, 0, &desc, RT, nullptr, __uuidof(ID3D12Resource), (void **)&p));
    CHECK(g->device->CreatePlacedResource(heap, 0, &desc, RT, nullptr, __uuidof(ID3D12Resource), (void **)&q));
    Target P = MakeTarget(p), Q = MakeTarget(q);
    Clear(P);
    Pass(P, add, 1, 256);
    D3D12_RESOURCE_BARRIER barrier = {D3D12_RESOURCE_BARRIER_TYPE_ALIASING};
    barrier.Aliasing.pResourceBefore = p;
    barrier.Aliasing.pResourceAfter = q;
    g->list->ResourceBarrier(1, &barrier);
    Clear(Q);
    Pass(Q, add, 2, 1);
    Read(Q, RT, 512, 512, 0);
    g->Submit();
    printf("hazard aliasing %g\n", Texel(0));
}

// A heavy pass counts its samples (256 x 1024 x 1024); ResolveQueryData on the GPU, which no barrier orders.
static void Occlusion() {
    ID3D12QueryHeap *heap;
    D3D12_QUERY_HEAP_DESC qd = {D3D12_QUERY_HEAP_TYPE_OCCLUSION, 1};
    CHECK(g->device->CreateQueryHeap(&qd, __uuidof(ID3D12QueryHeap), (void **)&heap));
    ID3D12Resource *result = g->Buffer(D3D12_HEAP_TYPE_DEFAULT, 8, COPY_DEST);
    Clear(T[0]);
    Bind(T[0], add, 1);
    g->list->BeginQuery(heap, D3D12_QUERY_TYPE_OCCLUSION, 0);
    g->list->DrawInstanced(3, 256, 0, 0);
    g->list->EndQuery(heap, D3D12_QUERY_TYPE_OCCLUSION, 0);
    g->list->ResolveQueryData(heap, D3D12_QUERY_TYPE_OCCLUSION, 0, 1, result, 0);
    ReadBuffer(result, COPY_DEST, 0, 8, 0);
    g->Submit();
    printf("hazard occlusion %llu\n", Word(0, 8));
}

// Two heavy passes into different targets with no barrier between them (free to overlap): both complete.
static void Independent() {
    Clear(T[0]);
    Clear(T[1]);
    Pass(T[0], add, 1, 256);
    Pass(T[1], add, 1, 256);
    Read(T[0], RT, 512, 512, 0);
    Read(T[1], RT, 512, 512, 1);
    g->Submit();
    printf("hazard independent %g %g\n", Texel(0), Texel(1));
}

// T0 rendered (heavy), T1 rendered, a barrier for T0 alone, T2 = T0 sampled + 1, T2 read. With precise transitions
// (M2) the sampling pass waits on T0's pass and not T1's, and the read on T0's and T2's: DXMT_STATS counts 2 encoders
// with a dependency list and 3 dependency waits.
static void Precise() {
    Clear(T[0]);
    Clear(T[1]);
    Clear(T[2]);
    g->Submit();
    Pass(T[0], add, 1, 256);
    Pass(T[1], set, 5, 1);
    g->Barrier(T[0].texture, RT, PSR);
    Pass(T[2], sample, 1, 1, &T[0]);
    Read(T[2], RT, 512, 512, 0);
    g->Barrier(T[0].texture, PSR, RT);
    g->Submit();
    printf("hazard precise %g\n", Texel(0));
}

// A large copy into X (word 0 = 77, the rest 0); a dispatch elsewhere opens a compute encoder; inside it, a barrier X
// COPY_DEST -> UNORDERED_ACCESS and a dispatch copying X's word 0 to word 1: 77 (0 if it ran before the copy).
static void MidPass() {
    const UINT64 size = 128 << 20;
    ID3D12Resource *upload = g->Buffer(D3D12_HEAP_TYPE_UPLOAD, size, D3D12_RESOURCE_STATE_GENERIC_READ);
    uint32_t *p;
    CHECK(upload->Map(0, nullptr, (void **)&p));
    memset(p, 0, size);
    p[0] = 77;
    upload->Unmap(0, nullptr);
    ID3D12Resource *x = g->Buffer(D3D12_HEAP_TYPE_DEFAULT, size, COPY_DEST, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    ID3D12Resource *elsewhere = Zeroed(256, UA);
    g->list->CopyBufferRegion(x, 0, upload, 0, size);
    Dispatch(fill, elsewhere, 1);
    g->Barrier(x, COPY_DEST, UA);
    Dispatch(count, x, 1);
    ReadBuffer(x, UA, 4, 4, 0);
    g->Submit();
    printf("hazard mid-pass %llu\n", Word(0, 4));
}

// One list run twice back to back: T0 cleared and rendered, then sampled into T1, adding (T1 += 257), then back to
// RENDER_TARGET.
static void Twice() {
    Clear(T[1]);
    g->Submit();
    Clear(T[0]);
    Pass(T[0], add, 1, 256);
    g->Barrier(T[0].texture, RT, PSR);
    Pass(T[1], add_sample, 1, 1, &T[0]);
    g->Barrier(T[0].texture, PSR, RT);
    g->Submit(2);
    Read(T[1], RT, 512, 512, 0);
    g->Submit();
    printf("hazard twice %g\n", Texel(0));
}

// 300 passes, into T0 and T1 in turn, 8 instances of 1 each, no barrier: more encoders in one list than the queue's
// fences (256).
static void Many() {
    Clear(T[0]);
    Clear(T[1]);
    for (int i = 0; i < 300; i++)
        Pass(T[i % 2], add, 1, 8);
    Read(T[0], RT, 512, 512, 0);
    Read(T[1], RT, 512, 512, 1);
    g->Submit();
    printf("hazard many %g %g\n", Texel(0), Texel(1));
}

// T0 rendered (heavy), then a rectangle of it cleared to 3 (DXMT clears rectangles with a pass of its own).
static void ClearRects() {
    Clear(T[0]);
    Pass(T[0], add, 1, 256);
    const float three[4] = {3, 3, 3, 3};
    D3D12_RECT rect = {500, 500, 600, 600};
    g->list->ClearRenderTargetView(T[0].rtv, three, 1, &rect);
    Read(T[0], RT, 512, 512, 0);
    Read(T[0], RT, 0, 0, 1);
    g->Submit();
    printf("hazard clear-rects %g %g\n", Texel(0), Texel(1));
}

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: d3d12_hazards.exe <shader folder> [mode...]\n"); return 2; }
    std::string dir = argv[1];
    auto shader = [&](const char *entry) {
        auto code = Load((dir + "/hazards." + entry + ".dxil").c_str());
        if (code.empty()) { printf("can't read hazards.%s.dxil\n", entry); exit(1); }
        return code;
    };
    Gpu gpu;
    g = &gpu;
    D3D12_ROOT_PARAMETER params[2] = {};
    params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
    params[0].Constants.Num32BitValues = 2;
    D3D12_DESCRIPTOR_RANGE srvs = {D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 1, 0, 0, 0};
    params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    params[1].DescriptorTable = {1, &srvs};
    D3D12_ROOT_SIGNATURE_DESC rd = {2, params, 0, nullptr, D3D12_ROOT_SIGNATURE_FLAG_NONE};
    root = gpu.RootSignature(rd);
    params[1] = {};
    params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_UAV;
    croot = gpu.RootSignature(rd);
    auto vs = shader("vsfull"), value = shader("psvalue"), sampled = shader("pssample");
    add = Graphics(vs, value, true);
    set = Graphics(vs, value, false);
    sample = Graphics(vs, sampled, false);
    add_sample = Graphics(vs, sampled, true);
    fill = Compute(shader("csfill"));
    count = Compute(shader("cscount"));
    args = Compute(shader("csargs"));
    D3D12_INDIRECT_ARGUMENT_DESC arg = {D3D12_INDIRECT_ARGUMENT_TYPE_DRAW};
    D3D12_COMMAND_SIGNATURE_DESC sd = {sizeof(D3D12_DRAW_ARGUMENTS), 1, &arg, 0};
    CHECK(gpu.device->CreateCommandSignature(&sd, nullptr, __uuidof(ID3D12CommandSignature), (void **)&draw_signature));
    D3D12_DESCRIPTOR_HEAP_DESC hd = {D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 16};
    CHECK(gpu.device->CreateDescriptorHeap(&hd, __uuidof(ID3D12DescriptorHeap), (void **)&rtv_heap));
    hd = {D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 16, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE};
    CHECK(gpu.device->CreateDescriptorHeap(&hd, __uuidof(ID3D12DescriptorHeap), (void **)&srv_heap));
    readback = gpu.Buffer(D3D12_HEAP_TYPE_READBACK, 64 * 512, COPY_DEST);
    for (auto &t : T)
        t = MakeTarget();
    static const struct { const char *name; void (*run)(); } kModes[] = {
        {"rt-read", RtRead},         {"same-target", SameTarget}, {"uav", Uav},       {"copy-read", CopyRead},
        {"indirect", Indirect},      {"aliasing", Aliasing},      {"occlusion", Occlusion},
        {"independent", Independent}, {"precise", Precise},       {"mid-pass", MidPass}, {"twice", Twice},
        {"many", Many},              {"clear-rects", ClearRects}};
    std::vector<std::string> modes(argv + 2, argv + argc);
    if (modes.empty())
        for (auto &m : kModes)
            modes.push_back(m.name);
    for (auto &m : modes) {
        bool found = false;
        for (auto &k : kModes)
            if (m == k.name) {
                k.run();
                found = true;
            }
        if (!found) { printf("unknown mode %s\n", m.c_str()); return 2; }
    }
    return 0;
}
```

In the `Makefile`'s `dxmt-tests` target, after the `d3d12_indirect.exe` line, add:

```make
	$(MINGWXX) -std=c++17 -o build/dxmt-tests/d3d12_hazards.exe dxmt/tests/d3d12_hazards.cpp -ld3d12 -ldxgi
```

- [ ] **Step 4: Run every mode on today's DXMT and on D3DMetal**

Run: `sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders"`
Expected: these 13 lines, first with `dxmt: `, then with `d3dmetal: `:

```
hazard rt-read 257
hazard same-target 7 5
hazard uav 1048576
hazard copy-read 6
hazard indirect 9
hazard aliasing 2
hazard occlusion 268435456
hazard independent 256 256
hazard precise 257
hazard mid-pass 77
hazard twice 514
hazard many 1200 1200
hazard clear-rects 3 256
```

If a line differs on DXMT and not on D3DMetal, today's DXMT has a bug outside ordering, because today every encoder waits on the previous one. Debug it with superpowers:systematic-debugging, fix it in the fork with a commit of its own, and ledger it as a ruling before going on. If a line differs on D3DMetal, the test is wrong: fix the test.

- [ ] **Step 5: Add the checks**

In `dxmt/check.sh`, section 6, replace `"22/22"` with `"28/28"`, `"22:22"` with `"28:28"`, and the `8` at the end of the `vertex and geometry shaders keep their math unfused` check with `9`. These are the six new shaders, one of them a vertex shader.

Then, before the final line `[ $fail = 0 ] && echo "dxmt-check: all passed"`, add:

```sh
# 8. Encoder ordering (GPU overlap spec §5): each mode's first pass is heavy, so work after it that doesn't wait for it
#    reads or overwrites its results early. Our DXMT with overlap, in strict order, and in strict order while dumping
#    passes and pixel history (the queue's own encoders), and D3DMetal print the same lines.
hazards() { grep '^hazard ' "$WORK/$1.txt" || echo "no hazard lines in $1"; }
want=$(printf 'hazard %s\n' "rt-read 257" "same-target 7 5" "uav 1048576" "copy-read 6" "indirect 9" "aliasing 2" \
  "occlusion 268435456" "independent 256 256" "precise 257" "mid-pass 77" "twice 514" "many 1200 1200" "clear-rects 3 256")
run ours hazards dxmt "$TESTS/d3d12_hazards.exe" "Z:$S"
export DXMT_D3D12_SERIAL=1
run ours hazards-serial dxmt "$TESTS/d3d12_hazards.exe" "Z:$S"
unset DXMT_D3D12_SERIAL
run ours hazards-ref d3dmetal "$TESTS/d3d12_hazards.exe" "Z:$S"
expect "work after a heavy pass waits for it" "$(hazards hazards)" "$want"
expect "and in strict order (DXMT_D3D12_SERIAL=1)" "$(hazards hazards-serial)" "$want"
expect "and on D3DMetal" "$(hazards hazards-ref)" "$want"
rm -rf "$WORK/hz-dump"; export DXMT_DXIL_DUMP="$WORK/hz-dump" DXMT_DUMP_FRAME=0 DXMT_DUMP_PIXEL=512,512,0,40
run ours hazards-dump dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" rt-read indirect precise
unset DXMT_DXIL_DUMP DXMT_DUMP_FRAME DXMT_DUMP_PIXEL
expect "and while dumping passes and pixel history" "$(hazards hazards-dump)" \
  "$(printf 'hazard %s\n' "rt-read 257" "indirect 9" "precise 257")"
```

- [ ] **Step 6: Watch the tests catch missing waits (temporary mutation)**

Run `git -C build/dxmt-src/dxmt switch macneutron`. In `build/dxmt-src/dxmt/src/d3d12/d3d12_command_queue.cpp`, make three temporary edits:
- In `EncodeFenced` for render encoders, replace `encoder.encodeCommands((const wmtcmd_render_nop *)&wait);` with `encoder.encodeCommands((const wmtcmd_render_nop *)wait.next.get());`.
- In `EncodeFencedSimple`, replace `encoder.encodeCommands((const Nop *)&wait);` with `encoder.encodeCommands((const Nop *)wait.next.get());`.
- In the `EncoderType::Resolve` case, delete the line `encoder.waitForFence(fence_, WMTRenderStageFragment);`.

Every encoder now updates the fence and waits on nothing.

Run: `sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" 2>&1 | grep '^dxmt:'`
Expected: several lines differ from Step 4's, at least `rt-read`, `copy-read`, `indirect` and `mid-pass`. Ledger which modes caught the mutation. For a mode that never does, run it 3 more times. If it still never fails, quadruple its heavy pass (`256` instances to `1024` and its expected value accordingly, or `16384` groups to `65536`). If it still never fails, ledger it as a guard against gross breakage only.

Then revert, rebuild and confirm:

```bash
git -C build/dxmt-src/dxmt checkout -- src/d3d12/d3d12_command_queue.cpp
sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" 2>&1 | grep '^dxmt:'
```

Expected: Step 4's 13 lines again, and `git -C build/dxmt-src/dxmt status --short` prints nothing.

- [ ] **Step 7: Full check and commit**

```bash
mkdir -p "$W"; make dxmt-check > "$W/check-t1.log" 2>&1; grep -E '^(FAIL|dxmt-check)' "$W/check-t1.log"
git add dxmt/tests/shaders/hazards.hlsl dxmt/tests/shaders/hazards.*.dxil dxmt/tests/shaders/compile.sh \
  dxmt/tests/d3d12_hazards.cpp dxmt/tests/d3d12_common.hpp Makefile dxmt/check.sh
git commit -m "test(dxmt): encoder ordering hazards, compared with D3DMetal

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: `dxmt-check: all passed` and no `FAIL` line.

---

### Task 2: M1 — barrier groups

**Files (fork, `build/dxmt-src/dxmt/src/d3d12/`):**
- Modify: `d3d12_command_encoder.hpp` (`EncoderData`)
- Modify: `d3d12_command_allocator.hpp` (ordering state, `Barrier`, `Writes`, `Decide`, the command funnels, `AllocatePass`, `InvalidateCurrentPass`, `StartRecord`)
- Modify: `d3d12_command_list.cpp` (`ResourceKey`, `PreDraw`, `PreDispatch`, `PreBlit` and its callers, the clears, `ResolveSubresource`, `ResolveQueryData`, `ResourceBarrier`)
- Modify: `d3d12_command_queue.cpp` (the fence ring, `Order`, `Join`, `Encode`, the encode loop, dumps, pixel history, `PresentFrame`)

**Files (MacNeutron):** `dxmt/check.sh`, `dxmt/pins`, `README.md`

**Interfaces:**
- Consumes: Task 1's `d3d12_hazards.exe` and its `independent` mode.
- Produces:
  - `EncoderData` fields: `barriers_last`, `position`, `join`, `writes_unknown`, `write_count`, `writes[16]`, `dep_count`, `deps`.
  - Allocator methods:
    - `void Barrier(bool join)`, called once per barrier call;
    - `void Writes(const void *resource)`, which marks the current encoder as writing `resource`;
    - `void Decide(EncoderData *e)`, called by `InvalidateCurrentPass`;
    - members `joins_`, `group_`, `deps_`.
  - Command list: `static const void *ResourceKey(ID3D12Resource *)` and `bool PreBlit(ID3D12Resource *dst)`.
  - Queue members:
    - `uint16_t Order(const EncoderData *e, bool serial)`;
    - `template <...> uint16_t Join(Encoder &, Stage...)`;
    - three `Encode(...)` overloads;
    - `fences_[256]`, `waits_`, `frontier_`, `pinned_`.
  - Environment: `DXMT_D3D12_SERIAL=1`.
  - Counters in `stats.txt`: `encoder full joins`, `encoders with a dependency list`, `encoder dependency waits`, `encoder boundaries free to overlap`.

- [ ] **Step 1: Write the failing check**

In `dxmt/check.sh`, right after Task 1's section 8 block, add:

```sh
# Overlap happens (GPU overlap spec §3.8): passes into different targets with no barrier between them leave their
# boundaries free to overlap; in strict order, none is, and every encoder joins.
rm -rf "$WORK/ov-stats" "$WORK/ov-serial"; export DXMT_DXIL_DUMP="$WORK/ov-stats" DXMT_STATS=1
run ours ov-stats dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" independent
export DXMT_DXIL_DUMP="$WORK/ov-serial" DXMT_D3D12_SERIAL=1
run ours ov-serial dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" independent
unset DXMT_DXIL_DUMP DXMT_STATS DXMT_D3D12_SERIAL
expect "independent passes are free to overlap" \
  "$(grep -cE '^  encoder boundaries free to overlap [1-9]' "$WORK/ov-stats/stats.txt" 2> /dev/null || true)" 1
expect "and never in strict order" \
  "$(grep -c '^  encoder boundaries free to overlap' "$WORK/ov-serial/stats.txt" 2> /dev/null || true):$(grep -c '^  encoder full joins' "$WORK/ov-serial/stats.txt" 2> /dev/null || true)" "0:1"
```

- [ ] **Step 2: Watch it fail**

Run:

```bash
rm -rf "$PWD/$W/ov"; RUN_ENV="DXMT_DXIL_DUMP=$PWD/$W/ov DXMT_STATS=1" sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" independent
grep -c 'encoder boundaries free to overlap' "$W/ov/stats.txt"
```

Expected: `dxmt: hazard independent 256 256`, then `0`. The counter doesn't exist yet.

- [ ] **Step 3: Encoders carry their ordering**

Run `git -C build/dxmt-src/dxmt switch macneutron`. In `d3d12_command_encoder.hpp`, replace:

```cpp
  uint32_t barriers = 0; // the allocator's barrier count when this encoder began (DXMT_STATS)
};
```

with:

```cpp
  uint32_t barriers = 0; // the list's barrier calls before this encoder began (DXMT_STATS, ordering)
  // MacNeutron: what this encoder waits on (GPU overlap spec §3.1), decided as it closes; the queue turns it into
  // fence waits. Resources are DXMT Texture or Buffer objects, or a query heap's Metal results buffer.
  uint32_t barriers_last = 0;  // the barrier calls before its last command: one recorded inside it binds it all
  uint32_t position = 0;       // its index among its command list's encoders
  bool join = false;           // waits on all earlier work
  bool writes_unknown = true;  // may write anything (DXMT's own passes); cleared where an encoder lists its writes
  uint8_t write_count = 0;
  const void *writes[16];
  uint32_t dep_count = 0;
  const uint32_t *deps = nullptr; // positions of the encoders since its list's last join that it waits on
};
```

- [ ] **Step 4: The allocator decides as each encoder closes**

In `d3d12_command_allocator.hpp`:

Add `#include <algorithm>` after `#include "dxmt_ring_bump_allocator.hpp"`.

Replace:

```cpp
  uint32_t barriers_ = 0; // ResourceBarrier calls recorded (DXMT_STATS: encoder boundaries with no barrier)
```

with:

```cpp
  uint32_t barriers_ = 0; // this list's ResourceBarrier calls (and GPU query resolves, which order as one)

  // MacNeutron: encoder ordering (GPU overlap spec §3.1-3.2), decided as each encoder closes. joins_[n]: how many of
  // the list's first n barrier calls order all earlier work before all later work (M1: every one). group_: the
  // list's encoders since its last join.
  std::vector<uint32_t> joins_ = {0};
  std::vector<EncoderData *> group_;
  std::vector<uint32_t> deps_; // scratch
```

In `InvalidateCurrentPass()`, replace:

```cpp
    if (!encoder_current)
      return;
    encoder_last->next = encoder_current;
```

with:

```cpp
    if (!encoder_current)
      return;
    Decide(encoder_current);
    encoder_last->next = encoder_current;
```

In `StartRecord`, replace:

```cpp
    if (encoder_last)
      return E_INVALIDARG;
    *pStartEncoder = encoder_last =
```

with:

```cpp
    if (encoder_last)
      return E_INVALIDARG;
    barriers_ = 0;
    joins_.assign(1, 0);
    group_.clear();
    *pStartEncoder = encoder_last =
```

In `AllocatePass`, replace `p->barriers = barriers_;` with `p->barriers = p->barriers_last = barriers_;`.

Replace all four occurrences of:

```cpp
    storage->next.set(nullptr);
    return *storage;
```

(in `EncodeRenderPreCommand`, `EncodeRenderCommand`, `EncodeBlitCommand` and `EncodeComputeCommand`) with:

```cpp
    storage->next.set(nullptr);
    encoder->barriers_last = barriers_; // a barrier recorded before this command binds the whole encoder
    return *storage;
```

After the `AllocatePass` template, add:

```cpp
  // A barrier call: `join` when it orders all earlier work before all later work.
  void
  Barrier(bool join) {
    barriers_++;
    joins_.push_back(joins_.back() + join);
  }

  // MacNeutron: the current encoder writes `resource` (GPU overlap spec §3.2): a DXMT Texture or Buffer object, or a
  // query heap's Metal results buffer. Null, or more than an encoder lists: it may write anything.
  void
  Writes(const void *resource) {
    auto e = encoder_current;
    if (!resource || e->write_count == std::size(e->writes)) {
      e->writes_unknown = true;
      return;
    }
    for (unsigned i = 0; i < e->write_count; i++)
      if (e->writes[i] == resource)
        return;
    e->writes[e->write_count++] = resource;
  }

  static bool
  Overlap(const EncoderData *a, const EncoderData *b) {
    for (unsigned i = 0; i < a->write_count; i++)
      for (unsigned j = 0; j < b->write_count; j++)
        if (a->writes[i] == b->writes[j])
          return true;
    return false;
  }

  // What the closing encoder `e` waits on (GPU overlap spec §3.1). A join (all earlier work) when it is the list's
  // first, may write anything, or a joining barrier came after the previous encoder began and before e's last
  // command. Otherwise, the encoders since the list's last join that write what it writes or may write anything.
  // ponytail: every earlier writer, not only the newest, so waits grow with same-target passes in one group; keep
  // the newest writer per resource if dependency waits show in DXMT_STATS.
  void
  Decide(EncoderData *e) {
    auto prev = encoder_last; // the list's previous encoder, or its Null head
    e->position = encoder_count_;
    e->join = prev->type == EncoderType::Null || e->writes_unknown || joins_[e->barriers_last] > joins_[prev->barriers];
    if (e->join) {
      group_.clear();
    } else {
      deps_.clear();
      for (auto *g : group_)
        if (g->writes_unknown || Overlap(g, e))
          deps_.push_back(g->position);
      if (!deps_.empty()) {
        auto deps = AllocateCommandData<uint32_t>(deps_.size());
        std::copy(deps_.begin(), deps_.end(), deps);
        e->deps = deps;
        e->dep_count = deps_.size();
      }
    }
    group_.push_back(e);
  }
```

The helper passes in `d3d12_command_allocator.cpp` (`startRenderPass`, `startComputePass`: rectangle clears and UAV clears) keep the default `writes_unknown = true`, so they join, and later encoders wait on them.

- [ ] **Step 5: The command list declares writes and barriers**

In `d3d12_command_list.cpp`:

Before the line `// \`Graphics\`CommandList is a really confusing name`, add:

```cpp
// A resource's identity for encoder ordering (GPU overlap spec §3.2): its DXMT texture or buffer; null if neither.
static const void *
ResourceKey(ID3D12Resource *resource) {
  auto r = static_cast<MTLD3D12Resource *>(resource);
  if (!r)
    return nullptr;
  if (r->texture)
    return r->texture.ptr();
  return r->buffer.ptr();
}
```

In `PreDraw`:
- After `auto render = allocator_->AllocatePass<RenderEncoderData>();`, add `render->writes_unknown = false;`.
- Replace:

  ```cpp
          if (!AttachmentDesc.Texture)
            continue;
  ```

  with:

  ```cpp
          if (!AttachmentDesc.Texture)
            continue;
          allocator_->Writes(AttachmentDesc.Texture);
  ```

- Replace:

  ```cpp
          if (!AttachmentDesc.Texture)
            break; // a null depth view: no depth attachment
  ```

  with:

  ```cpp
          if (!AttachmentDesc.Texture)
            break; // a null depth view: no depth attachment
          allocator_->Writes(AttachmentDesc.Texture);
  ```

- Replace:

  ```cpp
        if (query_heap_ && !render->visibility_buffer)
          render->visibility_buffer = query_heap_->results.handle;
  ```

  with:

  ```cpp
        if (query_heap_ && !render->visibility_buffer) {
          render->visibility_buffer = query_heap_->results.handle;
          allocator_->Writes((const void *)(uintptr_t)render->visibility_buffer); // the pass counts samples into it
        }
  ```

In `PreDispatch`, after `auto compute = allocator_->AllocatePass<ComputeEncoderData>();`, add `compute->writes_unknown = false; // its UAV writes are ordered by the game's barriers`.

Replace `PreBlit` with:

```cpp
  // The open blit encoder, or a new one; it writes `dst` (null: nothing a D3D12 resource shows, as a timestamp's fill).
  bool
  PreBlit(ID3D12Resource *dst) {
    if (!allocator_->encoder_current || allocator_->encoder_current->type != EncoderType::Blit) {
      allocator_->InvalidateCurrentPass();
      auto render = allocator_->AllocatePass<BlitEncoderData>();
      render->type = EncoderType::Blit;
      render->cmd_head.type = WMTBlitCommandNop;
      render->cmd_head.next.set(0);
      render->cmd_tail = (wmtcmd_base *)&render->cmd_head;
      render->writes_unknown = false;
    }
    if (dst)
      allocator_->Writes(ResourceKey(dst));
    return true;
  }
```

Update its callers:
- In `CopyBufferRegion`, replace `if (!PreBlit())` with `if (!PreBlit(pDstBuffer))`.
- In `CopyTextureRegion`, replace `if (!PreBlit())` with `if (!PreBlit(pDst->pResource))`.
- In `CopyResource`, replace `if (!PreBlit())` with `if (!PreBlit(pDstResource))`.
- In `EndTimestamp`, replace both:

  ```cpp
        PreBlit();
        current = allocator_->encoder_current;
  ```

  with:

  ```cpp
        PreBlit(nullptr); // a timestamp's own encoder writes nothing
        current = allocator_->encoder_current;
  ```

- In `ResolveQueryData`, replace `PreBlit(); // only now: a CPU resolve above needs no encoder (an empty blit each, Unreal resolves ~27 a frame)` with:

  ```cpp
      // Only now: a CPU resolve above needs no encoder (an empty blit each, Unreal resolves ~27 a frame). Query heaps
      // have no barriers, so this resolve waits on all earlier work (GPU overlap spec §3.4).
      allocator_->Barrier(true);
      PreBlit(pDstBuffer);
      allocator_->Writes((const void *)(uintptr_t)heap->results.handle); // it zeroes the counts it read
  ```

In `ClearDepthStencilView` and `ClearRenderTargetView`, replace both:

```cpp
    auto encoder_info = allocator_->AllocatePass<ClearEncoderData>();
    encoder_info->type = EncoderType::Clear;
```

with:

```cpp
    auto encoder_info = allocator_->AllocatePass<ClearEncoderData>();
    encoder_info->type = EncoderType::Clear;
    encoder_info->writes_unknown = false;
    allocator_->Writes(AttachmentDesc.Texture);
```

In `ResolveSubresource`, replace:

```cpp
    auto resolve = allocator_->AllocatePass<ResolveEncoderData>();
    resolve->type = EncoderType::Resolve;
```

with:

```cpp
    auto resolve = allocator_->AllocatePass<ResolveEncoderData>();
    resolve->type = EncoderType::Resolve;
    resolve->writes_unknown = false;
    allocator_->Writes(pDst->texture.ptr());
```

Replace `ResourceBarrier` with:

```cpp
  void STDMETHODCALLTYPE ResourceBarrier(UINT Count, const D3D12_RESOURCE_BARRIER *barriers) {
    DXMT_STAT_SCOPE("list.ResourceBarrier");
    DXMT_STAT_COUNT("#resource barriers", Count);
    allocator_->Barrier(true); // M1: every barrier orders all earlier work before all later work (GPU overlap §3.1)
  };
```

- [ ] **Step 6: The queue orders encoders with a fence ring**

In `d3d12_command_queue.cpp`:

Add `#include <algorithm>`, `#include <array>`, `#include <type_traits>` and `#include <vector>` after `#include <atomic>`.

Delete everything from the comment line `// MacNeutron: the fence wait, an encoder's commands and the fence update go to winemetal as one chained command list:` down to the line before `class MTLD3D12CommandQueueImpl`. That removes both `EncodeFenced` overloads, `EncodeFencedSimple`, and the blit and compute `EncodeFenced`.

Replace the member `WMT::Reference<WMT::Fence> fence_;` with:

```cpp
  // MacNeutron: encoder ordering (GPU overlap spec §3.3). Each encoder updates a fence of its own from this ring and
  // waits on fences of earlier encoders: a join on every encoder since the last join (frontier_), any other encoder on
  // what that join waited on (pinned_) and on its dependencies in its command list. A fence is taken again only once
  // no later encoder can need its last update: an encoder that would take it sooner joins first.
  // ponytail: each encoder after a join re-waits on everything that join waited on; if wait counts show in Metal
  // traces, wait on the join's fence instead for groups whose predecessor group is large.
  static constexpr unsigned kFences = 256;
  std::array<WMT::Reference<WMT::Fence>, kFences> fences_;
  std::array<uint64_t, kFences> fence_group_ = {}; // the join group that last updated each fence
  uint64_t group_ = 2;                             // fences of this group and the previous one are live
  uint16_t next_fence_ = 0;
  std::vector<uint16_t> frontier_, pinned_, waits_;
  std::vector<uint16_t> list_fences_; // by position in the command list being encoded
  uint32_t list_join_ = 0;            // that list's last join, by position (UINT32_MAX: the queue's own work)
  // DXMT_D3D12_SERIAL=1: every encoder joins, the strict order DXMT used before (dumps and pixel history always do).
  bool serial_ = env::getEnvVar("DXMT_D3D12_SERIAL") == "1";
  std::vector<wmtcmd_render_fence_op> render_ops_;
  std::vector<wmtcmd_blit_fence_op> blit_ops_;
  std::vector<wmtcmd_compute_fence_op> compute_ops_;

  // Takes the fence the next encoder updates and fills waits_ with the fences it waits on. `e` null: the queue's own
  // work (pass dumps, pixel history, presents), which joins.
  uint16_t
  Order(const EncoderData *e, bool serial) {
    uint16_t fence = next_fence_;
    next_fence_ = (next_fence_ + 1) % kFences;
    bool join = !e || e->join || serial || fence_group_[fence] + 1 >= group_;
    waits_.clear();
    if (join) {
      waits_ = frontier_;
      pinned_.swap(frontier_);
      frontier_.clear();
      group_++;
      list_join_ = e ? e->position : UINT32_MAX;
    } else {
      waits_ = pinned_;
      for (uint32_t i = 0; i < e->dep_count; i++)
        if (e->deps[i] >= list_join_) // earlier ones are behind the join, so behind pinned_
          waits_.push_back(list_fences_[e->deps[i]]);
    }
    if (e && g_stats_on)
      CountOrder(e, join);
    fence_group_[fence] = group_;
    frontier_.push_back(fence);
    if (e) {
      if (e->position >= list_fences_.size())
        list_fences_.resize(e->position + 1);
      list_fences_[e->position] = fence;
    }
    return fence;
  }

  void
  CountOrder(const EncoderData *e, bool join) { // DXMT_STATS (GPU overlap spec §3.8)
    static const unsigned joins = StatId("#encoder full joins"), listed = StatId("#encoders with a dependency list"),
                          dep_waits = StatId("#encoder dependency waits"),
                          free = StatId("#encoder boundaries free to overlap");
    if (join) {
      StatCount(joins);
      return;
    }
    size_t deps = waits_.size() - pinned_.size();
    if (deps) {
      StatCount(listed);
      StatCount(dep_waits, deps);
    }
    if (std::find(waits_.begin(), waits_.end(), list_fences_[e->position - 1]) == waits_.end())
      StatCount(free);
  }

  // The queue's own encoders (pass dumps, pixel history, presents) join. Returns the fence the encoder then updates.
  template <typename Encoder, typename... Stage>
  uint16_t
  Join(Encoder &encoder, Stage... before) {
    uint16_t fence = Order(nullptr, true);
    for (auto wait : waits_)
      encoder.waitForFence(fences_[wait], before...);
    return fence;
  }

  // The waits in waits_, an encoder's commands and the update of `fence` go to winemetal as one chained command list:
  // each call crosses from Windows code to the Metal side (several us under Rosetta). `head` null: the waits and the
  // update alone. The chain is unlinked again, as pixel history re-encodes the commands. Render passes wait before
  // `before` and update after the fragment stage.
  template <typename FenceOp, auto Wait, auto Update, typename Encoder, typename Nop>
  void
  EncodeOrdered(Encoder &encoder, std::vector<FenceOp> &ops, uint16_t fence, Nop *head, wmtcmd_base *tail,
                WMTRenderStages before = WMTRenderStageVertex) {
    size_t n = waits_.size();
    ops.assign(n + 1, FenceOp{});
    for (size_t i = 0; i <= n; i++) {
      ops[i].type = i < n ? Wait : Update;
      ops[i].fence = fences_[i < n ? waits_[i] : fence].handle;
      if constexpr (std::is_same_v<FenceOp, wmtcmd_render_fence_op>)
        ops[i].stages = i < n ? before : WMTRenderStageFragment;
      if (i + 1 < n)
        ops[i].next.set(&ops[i + 1]);
    }
    void *body = head ? (void *)head : (void *)&ops[n];
    if (n)
      ops[n - 1].next.set(body);
    if (tail)
      tail->next.set(&ops[n]);
    encoder.encodeCommands((const Nop *)(n ? (void *)ops.data() : body));
    if (tail)
      tail->next.set(nullptr);
  }

  void
  Encode(WMT::RenderCommandEncoder &encoder, uint16_t fence, WMTRenderStages before,
         wmtcmd_render_nop *head = nullptr, wmtcmd_base *tail = nullptr) {
    EncodeOrdered<wmtcmd_render_fence_op, WMTRenderCommandWaitForFence, WMTRenderCommandUpdateFence>(
        encoder, render_ops_, fence, head, tail, before);
  }

  void
  Encode(WMT::BlitCommandEncoder &encoder, uint16_t fence, wmtcmd_blit_nop *head, wmtcmd_base *tail) {
    EncodeOrdered<wmtcmd_blit_fence_op, WMTBlitCommandWaitForFence, WMTBlitCommandUpdateFence>(encoder, blit_ops_,
                                                                                               fence, head, tail);
  }

  void
  Encode(WMT::ComputeCommandEncoder &encoder, uint16_t fence, wmtcmd_compute_nop *head, wmtcmd_base *tail) {
    EncodeOrdered<wmtcmd_compute_fence_op, WMTComputeCommandWaitForFence, WMTComputeCommandUpdateFence>(
        encoder, compute_ops_, fence, head, tail);
  }
```

In `Initialize`, replace `fence_ = metal_device.newFence();` with:

```cpp
    for (auto &fence : fences_)
      fence = metal_device.newFence();
```

In `DumpAttachment`, replace:

```cpp
    auto blit = cmdbuf.blitCommandEncoder();
    blit.waitForFence(fence_);
    blit.encodeCommands((const wmtcmd_blit_nop *)&cmd);
    blit.updateFence(fence_);
```

with:

```cpp
    auto blit = cmdbuf.blitCommandEncoder();
    auto fence = Join(blit);
    blit.encodeCommands((const wmtcmd_blit_nop *)&cmd);
    blit.updateFence(fences_[fence]);
```

In `PixelHistory`, make four replacements:
1. In the block commented `// The pixels (and the whole depth) as they are before the pass.`, replace `blit.waitForFence(fence_);` with `auto before = Join(blit);`, and `blit.updateFence(fence_);` with `blit.updateFence(fences_[before]);`.
2. In the `for (size_t k = 0; k <= draws.size(); k++)` loop's first blit, replace `blit.waitForFence(fence_);` with `auto restored = Join(blit);`, and its `blit.updateFence(fence_);` with `blit.updateFence(fences_[restored]);`.
3. Replace:

   ```cpp
         encoder.waitForFence(fence_, data->use_geometry ? WMTRenderStagePreRaster : WMTRenderStageVertex);
         encoder.encodeCommands(&data->cmd_head);
         encoder.updateFence(fence_, WMTRenderStageFragment);
   ```

   with:

   ```cpp
         auto drawn = Join(encoder, data->use_geometry ? WMTRenderStagePreRaster : WMTRenderStageVertex);
         encoder.encodeCommands(&data->cmd_head);
         encoder.updateFence(fences_[drawn], WMTRenderStageFragment);
   ```

4. Replace `readback.waitForFence(fence_);` with `auto copied = Join(readback);`, and `readback.updateFence(fence_);` with `readback.updateFence(fences_[copied]);`.

In `ExecuteCommandLists`, after `bool dumping = Dumps().frames == Dumps().frame;`, add:

```cpp
    bool serial = serial_ || dumping; // F9 dumps and pixel history see the strict order
```

In the `EncoderType::Clear` case, replace `EncodeFenced(encoder, fence_.handle, WMTRenderStageFragment);` with `Encode(encoder, Order(current, serial), WMTRenderStageFragment);`.

In the `EncoderType::Render` case, replace everything from `if (data->pre_tail) { // ExecuteIndirect's resolvers, writing the pass's ICBs` to the end of the `EncodeFenced(encoder, ...)` call (the line ending `&data->cmd_head, data->cmd_tail);`) with:

```cpp
          auto resolve_icbs = [&](uint16_t fence) { // ExecuteIndirect's resolvers, writing the pass's ICBs
            DXMT_STAT_COUNT("#indirect resolve passes", 1);
            auto pre = cmdbuf.computeCommandEncoder(true);
            LabelPass(pre, pass, "indirect resolve");
            Encode(pre, fence, &data->pre_head, data->pre_tail);
            pre.endEncoding();
          };
          if (dumping) { // strict order: the resolvers, the pass's pixel history, then the pass
            if (data->pre_tail)
              resolve_icbs(Order(nullptr, true));
            PixelHistory(cmdbuf, data, render_pass_info);
          }
          uint16_t fence = Order(current, serial);
          if (data->pre_tail && !dumping) { // the resolvers wait as the pass would; the pass waits on them alone
            resolve_icbs(fence);
            waits_.assign(1, fence);
          }
          auto encoder = cmdbuf.renderCommandEncoder(render_pass_info);
          LabelPass(encoder, pass, "render", data);
          // Geometry shader draws (MacNeutron) read resources in the object and mesh stages too.
          Encode(encoder, fence, data->use_geometry ? WMTRenderStagePreRaster : WMTRenderStageVertex, &data->cmd_head,
                 data->cmd_tail);
```

In the `EncoderType::Blit` and `EncoderType::Compute` cases, replace both occurrences of `EncodeFenced(encoder, fence_.handle, &data->cmd_head, data->cmd_tail);` with `Encode(encoder, Order(current, serial), &data->cmd_head, data->cmd_tail);`.

In the `EncoderType::Resolve` case, replace:

```cpp
          auto encoder = cmdbuf.renderCommandEncoder(info);
          encoder.waitForFence(fence_, WMTRenderStageFragment);
          encoder.setLabel(WMT::String::string("ResolvePass", WMTUTF8StringEncoding));
          encoder.updateFence(fence_, WMTRenderStageFragment);
          encoder.endEncoding();
```

with:

```cpp
          auto encoder = cmdbuf.renderCommandEncoder(info);
          encoder.setLabel(WMT::String::string("ResolvePass", WMTUTF8StringEncoding));
          Encode(encoder, Order(current, serial), WMTRenderStageFragment);
          encoder.endEncoding();
```

In `PresentFrame`, replace:

```cpp
        [&](auto encoder) { encoder.waitForFence(fence_, WMTRenderStageFragment); },
        [&](auto encoder) { encoder.updateFence(fence_, WMTRenderStageFragment); }
```

with:

```cpp
        [&](auto encoder) { fence = Join(encoder, WMTRenderStageFragment); },
        [&](auto encoder) { encoder.updateFence(fences_[fence], WMTRenderStageFragment); }
```

and add `uint16_t fence = 0;` on the line before `auto drawable = presenter->encodeCommands(`.

Run: `grep -n 'fence_\b\|EncodeFenced' build/dxmt-src/dxmt/src/d3d12/d3d12_command_queue.cpp`
Expected: no output.

- [ ] **Step 7: Watch it pass, with overlap and in strict order**

```bash
rm -rf "$PWD/$W/ov"; RUN_ENV="DXMT_DXIL_DUMP=$PWD/$W/ov DXMT_STATS=1" sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" independent
grep -E '^  encoder (boundaries free|full joins)|^  encoders with' "$W/ov/stats.txt"
sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" | grep '^dxmt:'
RUN_ENV="DXMT_D3D12_SERIAL=1" sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" | grep '^dxmt:'
```

Expected:
- The stats lines include `  encoder boundaries free to overlap N`, with N at least 1.
- Both hazard runs print Task 1 Step 4's 13 lines, prefixed `dxmt: `.

A build error or a different line means the code is wrong: use superpowers:systematic-debugging.

- [ ] **Step 8: The README's troubleshooting**

In `README.md`'s Per-game options table, after the `DXMT_D3D12_SM6=1` row, add:

```markdown
| `/usr/bin/env DXMT_D3D12_SERIAL=1 %command%` | On DXMT, run a Direct3D 12 game's GPU passes in strict order (troubleshooting flicker or corrupted surfaces) |
```

In the Graphics section, after the shader pre-caching troubleshooting list (the line ending `clears the recordings.`), add:

```markdown

**GPU work overlap.** DXMT lets a Direct3D 12 game's GPU passes run side by side wherever the game's barriers allow
it. If a game flickers or shows corrupted surfaces, launch it with `/usr/bin/env DXMT_D3D12_SERIAL=1 %command%`,
which runs every pass in strict order, as earlier versions did. If that fixes it, the cause is DXMT's ordering:
please report it.
```

- [ ] **Step 9: Land the fork, check everything, commit**

```bash
git -C build/dxmt-src/dxmt add -A src/d3d12
git -C build/dxmt-src/dxmt commit -m "d3d12: encoders wait only on what D3D12's barriers order before them (GPU overlap M1)

Each Metal encoder updates a fence of its own from a ring of 256 per queue. A barrier, a list start, a GPU query
resolve or an encoder that may write anything joins (waits on all earlier work); other encoders wait on what that
join waited on and on earlier encoders writing what they write. DXMT_D3D12_SERIAL=1, F9 dumps and pixel history keep
the strict order. DXMT_STATS counts joins, dependency lists and boundaries free to overlap.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git -C build/dxmt-src/dxmt push origin macneutron
sed -i '' "s/^DXMT_COMMIT=.*/DXMT_COMMIT=$(git -C build/dxmt-src/dxmt rev-parse HEAD)/" dxmt/pins
make dxmt-check > "$W/check-t2.log" 2>&1; grep -E '^(FAIL|dxmt-check)' "$W/check-t2.log"
swift test 2>&1 | tail -5
git add dxmt/check.sh dxmt/pins README.md
git commit -m "feat(dxmt): GPU work overlaps between D3D12 barriers (M1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: `dxmt-check: all passed` with no `FAIL`, including section 8, the overlap checks, `timestamp rules 1 1 1 1 1 1`, and the indirect and stats checks. Every Swift test passes.

---

### Task 3: M1 in SMITE 2 (measurement; needs the user)

**Files:**
- Create: `dxmt/tools/gpu-trace.py`
- Create: `docs/testing/acceptance-dxmt-gpu-overlap.md`

**Interfaces:**
- Consumes: Task 2's build and `DXMT_D3D12_SERIAL=1`.
- Produces:
  - `python3 dxmt/tools/gpu-trace.py <pid> [seconds] | <file.trace> | <PEX_Timeline_*.csv>`, which Task 5 reuses.
  - The acceptance doc's results table, which gets one row per milestone.

- [ ] **Step 1: Write the measurement tool**

Create `dxmt/tools/gpu-trace.py`:

```python
#!/usr/bin/env python3
# GPU time per frame of a running game, from a Metal System Trace (GPU overlap spec §7):
#   python3 dxmt/tools/gpu-trace.py <pid> [seconds]         records <seconds> (default 5) of the process, then reports
#   python3 dxmt/tools/gpu-trace.py <file.trace>            reports an existing trace
#   python3 dxmt/tools/gpu-trace.py <PEX_Timeline_*.csv>    Unreal's frame times: median and 90th percentile
# A trace report: frame period and GPU busy and idle time per frame (medians), and each GPU channel's share of the
# window with their sum against their union. A sum above the union is work running side by side.
import collections, csv, os, statistics as st, subprocess, sys, tempfile, xml.etree.ElementTree as ET


def rows(path):
    ids = {}
    for _, el in ET.iterparse(path, events=('end',)):
        if 'id' in el.attrib:
            ids[el.attrib['id']] = el
        if el.tag == 'row':
            yield [ids.get(c.attrib['ref']) if 'ref' in c.attrib else c for c in el]
            el.clear()


def union(intervals):
    total, start, end = 0, None, None
    for a, b in sorted(intervals):
        if start is None or a > end:
            total += end - start if start is not None else 0
            start, end = a, b
        else:
            end = max(end, b)
    return total + (end - start if start is not None else 0)


def pex(path):
    frames = sorted(float(r['FrameTime']) for r in csv.DictReader(open(path)) if r['IgnoredForSummary'] == '0')
    print(f"frames {len(frames)}, frame time median {st.median(frames):.2f} ms, "
          f"p90 {frames[int(0.9 * (len(frames) - 1))]:.2f} ms")


def trace(path):
    xml = os.path.join(tempfile.mkdtemp(), 'intervals.xml')
    with open(xml, 'w') as out:
        subprocess.run(['xcrun', 'xctrace', 'export', '--input', path, '--xpath',
                        '/trace-toc/run[@number="1"]/data/table[@schema="metal-gpu-intervals"]'],
                       check=True, stdout=out, stderr=subprocess.DEVNULL)
    by_process = collections.defaultdict(list)  # top-level intervals: (start, end, channel, frame)
    for r in rows(xml):
        if len(r) <= 10 or r[3] is None or (r[5] is not None and r[5].text not in ('0', None)):
            continue
        start = int(r[0].text)
        by_process[r[10].attrib.get('fmt', '') if r[10] is not None else ''].append((start, start + int(r[1].text), r[2].text, r[3].text))
    if not by_process:
        sys.exit('no GPU intervals in the trace')
    mine = max(by_process.values(), key=lambda v: sum(b - a for a, b, *_ in v))  # the game: the most GPU time
    window = max(b for _, b, *_ in mine) - min(a for a, *_ in mine)
    by_frame = collections.defaultdict(list)
    for a, b, _, f in mine:
        by_frame[f].append((a, b))
    frames = sorted((min(a for a, _ in v), union(v)) for v in by_frame.values())[1:-1]  # whole frames only
    period = [(b[0] - a[0]) / 1e6 for a, b in zip(frames, frames[1:])]
    busy = [u / 1e6 for _, u in frames[:-1]]
    idle = [p - u for p, u in zip(period, busy)]
    print(f"frames {len(frames)}, frame period median {st.median(period):.2f} ms ({1000 / st.median(period):.0f} fps)")
    print(f"GPU busy per frame median {st.median(busy):.2f} ms, idle {st.median(idle):.2f} ms")
    shares = {ch: 100 * union([(a, b) for a, b, c, _ in mine if c == ch]) / window
              for ch in sorted({c for _, _, c, _ in mine})}
    print('channels ' + ', '.join(f"{ch} {s:.1f}%" for ch, s in shares.items()) +
          f"; sum {sum(shares.values()):.1f}%, union {100 * union([(a, b) for a, b, *_ in mine]) / window:.1f}%")


arg = sys.argv[1]
if arg.endswith('.csv'):
    pex(arg)
elif arg.endswith('.trace'):
    trace(arg)
else:
    out = os.path.join(tempfile.mkdtemp(), 'gpu.trace')
    subprocess.run(['xcrun', 'xctrace', 'record', '--template', 'Metal System Trace', '--attach', arg,
                    '--time-limit', f"{sys.argv[2] if len(sys.argv) > 2 else 5}s", '--output', out],
                   check=True, stdout=subprocess.DEVNULL)
    trace(out)
```

- [ ] **Step 2: Check it against the spec's baseline**

The §2 baseline trace may still be on disk.

Run:

```bash
B=/private/tmp/claude-501/-Users-chad-Documents-MacProton/b56e92d0-84e3-4072-a071-4c3ba8d09535/scratchpad/prof
for t in "$B"/metal*.trace; do echo "$t"; python3 dxmt/tools/gpu-trace.py "$t"; done
```

Expected: one of the traces reports a frame period near 15.0 ms, GPU busy near 12.5 ms and idle near 2.4 ms, and channels `Compute ~8.4%, Fragment ~44.1%, Vertex ~16.2%` with sum ~68.7% and union ~68.5%, each within 0.3. That confirms the tool computes what §2 reported. If no trace is left, ledger that, and rely on the overlap and strict runs below, which are measured the same way.

- [ ] **Step 3: Write the acceptance doc**

Create `docs/testing/acceptance-dxmt-gpu-overlap.md`:

```markdown
# GPU work overlap acceptance test (DXMT fork, sub-project 4, second slice)

Spec: `docs/superpowers/specs/2026-10-01-macneutron-gpu-overlap-design.md` §7. Manual, once per milestone, on a Mac
with D3DMetal (GPTK imported) and SMITE 2 installed. Record results at the bottom.

## Steps

1. **Tests:** `make dxmt-check` and `make test` pass.
2. **Install:** with SMITE 2 closed, `.build/release/macneutron install-dxmt build/dxmt`.
3. **Overlap run:** SMITE 2 with launch options `/usr/bin/env DXMT_D3D12_SM6=1 %command%`.
   - Start a practice match and stand still in one spot, the same spot in every run of the milestone (note it in the
     results).
   - Meanwhile: `python3 dxmt/tools/gpu-trace.py $(pgrep -f Hemingway-Win64-Shipping | head -1)`.
   - Play about two minutes, then quit to the desktop.
   - Run `python3 dxmt/tools/gpu-trace.py "<PEX_Timeline csv>"` with the newest `PEX_Timeline_*.csv` in
     `~/Library/Application Support/Steam/steamapps/compatdata/2437170/pfx/drive_c/users/crossover/AppData/Local/SMITE2Alpha/Saved/Logs`.
4. **Strict run (control):** the same, with `/usr/bin/env DXMT_D3D12_SM6=1 DXMT_D3D12_SERIAL=1 %command%`.
5. **Pass:**
   - The picture is the same in both runs, by eye: no flicker, no missing or corrupted surfaces.
   - GPU busy per frame is lower in step 3 than in step 4, and lower than §2's 12.5 ms. The channel sum exceeds the
     union by more in step 3 than in step 4.
   - The frame period is shorter in step 3 than in step 4.
   - A milestone that measures no gain is recorded as such, and the next milestone's plan says whether it still goes
     ahead.

F9 dumps run in strict order, so they can't show an M1 or M2 ordering bug. M3 and M4, which change the passes,
compare F9 dumps.

## Results

| Milestone | Date | Overlap (step 3) | Strict (step 4) | Notes |
|---|---|---|---|---|
```

Then commit:

```bash
git add dxmt/tools/gpu-trace.py docs/testing/acceptance-dxmt-gpu-overlap.md
git commit -m "docs: GPU overlap acceptance test and its Metal trace tool

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 4: Install, and hand the runs to the user**

With SMITE 2 closed (`pgrep -f Hemingway-Win64` prints nothing), run `.build/release/macneutron install-dxmt build/dxmt`.

Then ask the user to:
- set SMITE 2's launch options to `/usr/bin/env DXMT_D3D12_SM6=1 %command%`;
- start a practice match, stand still, and say when they're in place, so the trace can be recorded;
- play about two minutes and quit;
- do the same with `/usr/bin/env DXMT_D3D12_SM6=1 DXMT_D3D12_SERIAL=1 %command%`;
- say whether the picture looked the same in both runs.

While they stand still, run `python3 dxmt/tools/gpu-trace.py $(pgrep -f Hemingway-Win64-Shipping | head -1) > "$W/m1-<run>.txt"`. After each run, run the tool on the newest PEX CSV. Wait for the user; don't poll the game.

- [ ] **Step 5: Record and commit the results**

Add a row to the Results table: `M1`, the date, both runs' numbers (period, busy, idle, channel sum against union, PEX median and p90), and the notes (fork commit, macOS build, the spot, picture same or not).

```bash
git add docs/testing/acceptance-dxmt-gpu-overlap.md
git commit -m "docs: GPU overlap M1 acceptance results

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

If the picture differed, stop: that's an ordering bug. Debug it with superpowers:systematic-debugging, starting from a `DXMT_STATS` Metal trace with the pass labels, and turn the failing pattern into a new `d3d12_hazards` mode before fixing it.

---

### Task 4: M2 — precise transitions

**Files (fork):** `d3d12_command_allocator.hpp` (`Barrier`, `Decide`, `transitions_`, `StartRecord`), `d3d12_command_list.cpp` (`ResourceBarrier`, `ReadOnly`, `WriteEnds`, `transitioned_`)

**Files (MacNeutron):** `dxmt/check.sh`, `dxmt/pins`

**Interfaces:**
- Consumes: Task 2's `Barrier(bool)`, `Decide`, `Writes`, `ResourceKey`, and the counters; Task 1's `precise` mode.
- Produces: `void Barrier(bool join, const void *const *transitioned = nullptr, size_t count = 0)`, and `transitions_`: pairs of resource and barrier-call index.

- [ ] **Step 1: Write the failing check**

In `dxmt/check.sh`, after Task 2's overlap block, add:

```sh
# M2 (GPU overlap spec §3.1): a barrier ending one render target's writes makes later work wait on that target's
# writer alone. d3d12_hazards precise: the sampling pass waits on T0's pass (not T1's), the read on T0's and T2's.
rm -rf "$WORK/precise-stats"; export DXMT_DXIL_DUMP="$WORK/precise-stats" DXMT_STATS=1
run ours precise-stats dxmt "$TESTS/d3d12_hazards.exe" "Z:$S" precise
unset DXMT_DXIL_DUMP DXMT_STATS
expect "a transition waits on the transitioned resource's writers alone" \
  "$(grep -oE '(encoders with a dependency list|encoder dependency waits) [0-9]+' "$WORK/precise-stats/stats.txt" 2> /dev/null | tr '\n' ';')" \
  "encoder dependency waits 3;encoders with a dependency list 2;"
```

- [ ] **Step 2: Watch it fail**

Run:

```bash
git -C build/dxmt-src/dxmt switch macneutron
rm -rf "$PWD/$W/pr"; RUN_ENV="DXMT_DXIL_DUMP=$PWD/$W/pr DXMT_STATS=1" sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" precise
grep -oE '(encoders with a dependency list|encoder dependency waits) [0-9]+' "$W/pr/stats.txt" | tr '\n' ';'; echo
```

Expected: `dxmt: hazard precise 257`, then an empty line. Under M1, both barriers make joins, so no encoder has a dependency list.

- [ ] **Step 3: The allocator keeps transitions**

In `d3d12_command_allocator.hpp`, replace:

```cpp
  std::vector<uint32_t> deps_; // scratch
```

with:

```cpp
  std::vector<uint32_t> deps_; // scratch
  // M2: resources leaving a write state, with the barrier call (1-based) that moved them, since the list's last join.
  std::vector<std::pair<const void *, uint32_t>> transitions_;
```

Replace `Barrier` with:

```cpp
  // A barrier call: `join` when it orders all earlier work before all later work; otherwise the resources it moves
  // out of a write state, whose writers later work waits on (M2).
  void
  Barrier(bool join, const void *const *transitioned = nullptr, size_t count = 0) {
    barriers_++;
    joins_.push_back(joins_.back() + join);
    if (!join)
      for (size_t i = 0; i < count; i++)
        transitions_.push_back({transitioned[i], barriers_});
  }

  // M2: a resource `g` writes left its write state after g began and before e's last command.
  bool
  Transitioned(const EncoderData *g, const EncoderData *e) {
    for (auto &[resource, at] : transitions_)
      if (at > g->barriers && at <= e->barriers_last)
        for (unsigned i = 0; i < g->write_count; i++)
          if (g->writes[i] == resource)
            return true;
    return false;
  }
```

In `Decide`, replace:

```cpp
    if (e->join) {
      group_.clear();
    } else {
      deps_.clear();
      for (auto *g : group_)
        if (g->writes_unknown || Overlap(g, e))
```

with:

```cpp
    if (e->join) {
      group_.clear();
      // Transitions before e began have their writers behind e, and so behind everything that waits after e.
      transitions_.erase(std::remove_if(transitions_.begin(), transitions_.end(),
                                        [&](auto &t) { return t.second <= e->barriers; }),
                         transitions_.end());
    } else {
      deps_.clear();
      for (auto *g : group_)
        if (g->writes_unknown || Overlap(g, e) || Transitioned(g, e))
```

Update `Decide`'s comment's last sentence to: `Otherwise, the encoders since the list's last join that write what it writes, may write anything, or wrote a resource a barrier since moved out of its write state.`

In `StartRecord`, after `group_.clear();`, add `transitions_.clear();`.

- [ ] **Step 4: The command list classifies barriers**

In `d3d12_command_list.cpp`, after `ResourceKey`, add:

```cpp
// A read state, or several (GENERIC_READ): what a transition between two of them orders is nothing.
static bool
ReadOnly(D3D12_RESOURCE_STATES state) {
  const unsigned reads = (unsigned)D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER |
                         (unsigned)D3D12_RESOURCE_STATE_INDEX_BUFFER | (unsigned)D3D12_RESOURCE_STATE_DEPTH_READ |
                         (unsigned)D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE |
                         (unsigned)D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE |
                         (unsigned)D3D12_RESOURCE_STATE_INDIRECT_ARGUMENT | (unsigned)D3D12_RESOURCE_STATE_COPY_SOURCE |
                         (unsigned)D3D12_RESOURCE_STATE_RESOLVE_SOURCE |
                         (unsigned)D3D12_RESOURCE_STATE_SHADING_RATE_SOURCE;
  return state && !((unsigned)state & ~reads);
}

// A write state whose writers encoders list (GPU overlap spec §3.2): leaving it waits on them alone.
static bool
WriteEnds(D3D12_RESOURCE_STATES state) {
  return state == D3D12_RESOURCE_STATE_RENDER_TARGET || state == D3D12_RESOURCE_STATE_DEPTH_WRITE ||
         state == D3D12_RESOURCE_STATE_COPY_DEST || state == D3D12_RESOURCE_STATE_RESOLVE_DEST;
}
```

In the command list class, next to the other members (after `Com<MTLD3D12CommandAllocatorImpl, false> allocator_;`), add:

```cpp
  std::vector<const void *> transitioned_; // ResourceBarrier's scratch
```

Replace `ResourceBarrier` with:

```cpp
  // GPU overlap spec §3.4. A transition out of RENDER_TARGET, DEPTH_WRITE, COPY_DEST or RESOLVE_DEST orders that
  // resource's writers before later work (M2); one between read states orders nothing. Anything else orders all
  // earlier work before all later work: UAV and aliasing barriers, transitions out of UNORDERED_ACCESS or into a write
  // state from a read state, COMMON, a split barrier's end (its begin is skipped), a resource we don't know, or one
  // several queues may use at once. A barrier on some subresources counts for the whole resource.
  void STDMETHODCALLTYPE ResourceBarrier(UINT Count, const D3D12_RESOURCE_BARRIER *barriers) {
    DXMT_STAT_SCOPE("list.ResourceBarrier");
    DXMT_STAT_COUNT("#resource barriers", Count);
    transitioned_.clear();
    bool join = false;
    for (UINT i = 0; i < Count && !join; i++) {
      auto &b = barriers[i];
      if (b.Flags & D3D12_RESOURCE_BARRIER_FLAG_BEGIN_ONLY)
        continue;
      auto key = b.Type == D3D12_RESOURCE_BARRIER_TYPE_TRANSITION ? ResourceKey(b.Transition.pResource) : nullptr;
      if (!key || (b.Flags & D3D12_RESOURCE_BARRIER_FLAG_END_ONLY) ||
          (static_cast<MTLD3D12Resource *>(b.Transition.pResource)->GetDesc().Flags &
           D3D12_RESOURCE_FLAG_ALLOW_SIMULTANEOUS_ACCESS)) {
        join = true;
        break;
      }
      auto before = b.Transition.StateBefore, after = b.Transition.StateAfter;
      if (ReadOnly(before) && ReadOnly(after))
        continue;
      if (!WriteEnds(before) || after == D3D12_RESOURCE_STATE_COMMON) {
        join = true;
        break;
      }
      transitioned_.push_back(key);
    }
    allocator_->Barrier(join, transitioned_.data(), transitioned_.size());
  };
```

- [ ] **Step 5: Watch it pass**

```bash
rm -rf "$PWD/$W/pr"; RUN_ENV="DXMT_DXIL_DUMP=$PWD/$W/pr DXMT_STATS=1" sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" precise
grep -oE '(encoders with a dependency list|encoder dependency waits) [0-9]+' "$W/pr/stats.txt" | tr '\n' ';'; echo
sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" | grep '^dxmt:'
RUN_ENV="DXMT_D3D12_SERIAL=1" sh dxmt/tests/run.sh d3d12_hazards "Z:$PWD/dxmt/tests/shaders" | grep '^dxmt:'
```

Expected:
- `dxmt: hazard precise 257`, then `encoder dependency waits 3;encoders with a dependency list 2;`.
- Both hazard runs print Task 1 Step 4's 13 lines, prefixed `dxmt: `.

- [ ] **Step 6: Land the fork, check everything, commit**

```bash
git -C build/dxmt-src/dxmt add -A src/d3d12
git -C build/dxmt-src/dxmt commit -m "d3d12: a transition out of a write state waits on that resource's writers alone (GPU overlap M2)

Barriers are classified: a transition out of RENDER_TARGET, DEPTH_WRITE, COPY_DEST or RESOLVE_DEST makes later
encoders of the list wait on the encoders that wrote that resource; between read states, nothing; anything else
still joins.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git -C build/dxmt-src/dxmt push origin macneutron
sed -i '' "s/^DXMT_COMMIT=.*/DXMT_COMMIT=$(git -C build/dxmt-src/dxmt rev-parse HEAD)/" dxmt/pins
make dxmt-check > "$W/check-t4.log" 2>&1; grep -E '^(FAIL|dxmt-check)' "$W/check-t4.log"
swift test 2>&1 | tail -5
git add dxmt/check.sh dxmt/pins
git commit -m "feat(dxmt): transitions out of a write state wait on that resource's writers alone (M2)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: `dxmt-check: all passed` with no `FAIL`, and every Swift test passes.

---

### Task 5: M2 in SMITE 2 (measurement; needs the user)

**Files:** Modify `docs/testing/acceptance-dxmt-gpu-overlap.md` (Results).

**Interfaces:**
- Consumes: Task 3's tool and procedure, and Task 4's build.

- [ ] **Step 1: Install, and hand the runs to the user**

With SMITE 2 closed, run `.build/release/macneutron install-dxmt build/dxmt`. Then ask the user for the same two runs as Task 3 Step 4, at the same spot, and record them the same way: `$W/m2-<run>.txt` and the PEX CSVs.

- [ ] **Step 2: Record and commit the results**

Add an `M2` row to the Results table, comparing against M1's overlap row as well as the strict control.

```bash
git add docs/testing/acceptance-dxmt-gpu-overlap.md
git commit -m "docs: GPU overlap M2 acceptance results

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

If the picture differed, debug it as in Task 3 Step 5.

---

## After this plan

- M3 (unsplit render passes), M4 (folded clears) and M5 (idle gaps) each get their own plan, written once M2's numbers are recorded, in the spec's order.
- Then the no-Rosetta research (FEX and arm64 Wine), per the user's "Both, FPS first".
