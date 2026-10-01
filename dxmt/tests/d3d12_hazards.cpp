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

// Large copies into X (word 0 = 77, the rest 0); a dispatch elsewhere opens a compute encoder; inside it, a barrier X
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
    for (int i = 0; i < 8; i++) // heavy: 1 GB copied, in order (one blit encoder)
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

// T0 rendered (heavy); a barrier RENDER_TARGET -> COPY_SOURCE; 16 copies of all of T0 into a readback buffer; then a
// light clear of T1 that waits on none of them and may finish first. The D3D12 fence (Submit) must still wait for
// every copy: prints how many copied texel channels aren't 256 (0).
static void Signal() {
    const UINT pitch = kSize * 8, copies = 16;
    const UINT64 size = (UINT64)pitch * kSize;
    ID3D12Resource *big = g->Buffer(D3D12_HEAP_TYPE_READBACK, size * copies, COPY_DEST);
    Clear(T[0]);
    Pass(T[0], add, 1, 256);
    g->Barrier(T[0].texture, RT, COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION src = {T[0].texture, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX};
    src.SubresourceIndex = 0;
    for (UINT i = 0; i < copies; i++) {
        D3D12_TEXTURE_COPY_LOCATION dst = {big, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT};
        dst.PlacedFootprint = {size * i, {kFormat, kSize, kSize, 1, pitch}};
        g->list->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
    }
    Clear(T[1]);
    g->Barrier(T[0].texture, COPY_SOURCE, RT);
    g->Submit();
    uint16_t *p;
    D3D12_RANGE whole = {0, (SIZE_T)(size * copies)}, none = {0, 0};
    CHECK(big->Map(0, &whole, (void **)&p));
    unsigned long long wrong = 0;
    for (UINT64 i = 0; i < size * copies / 2; i++)
        wrong += p[i] != 0x5C00; // 256.0
    big->Unmap(0, &none);
    big->Release();
    printf("hazard signal %llu\n", wrong);
}

// A dispatch adds 1 per thread to word 0 (heavy), then 300 timestamps in empty encoders of their own, then a UAV
// barrier and a dispatch copying word 0 to word 1. The queue's 256 fences wrap while the heavy dispatch may still run:
// its fence must not be handed on while the barrier's join still has to wait on it.
static void Wrap() {
    ID3D12Resource *b = Zeroed(256, UA);
    ID3D12QueryHeap *heap;
    D3D12_QUERY_HEAP_DESC qd = {D3D12_QUERY_HEAP_TYPE_TIMESTAMP, 300};
    CHECK(g->device->CreateQueryHeap(&qd, __uuidof(ID3D12QueryHeap), (void **)&heap));
    Dispatch(fill, b, 65536);
    for (UINT i = 0; i < 300; i++)
        g->list->EndQuery(heap, D3D12_QUERY_TYPE_TIMESTAMP, i);
    D3D12_RESOURCE_BARRIER barrier = {D3D12_RESOURCE_BARRIER_TYPE_UAV};
    barrier.UAV.pResource = b;
    g->list->ResourceBarrier(1, &barrier);
    Dispatch(count, b, 1);
    ReadBuffer(b, UA, 4, 4, 0);
    g->Submit();
    printf("hazard wrap %llu\n", Word(0, 4));
}

// T0 rendered (heavy), then T1 and T2 rendered in the same group (no barrier): with one wait (spec §3.9) the two later
// passes each wait on the first pass's early fence alone. DXMT_STATS, this mode alone: 10 fence waits (the clears 0,
// 1, 1; the passes 3, 1, 1; the read 3).
static void OneWait() {
    Clear(T[0]);
    Clear(T[1]);
    Clear(T[2]);
    g->Submit();
    Pass(T[0], add, 1, 256);
    Pass(T[1], set, 5, 1);
    Pass(T[2], set, 6, 1);
    g->Submit();
    Read(T[0], RT, 512, 512, 0);
    Read(T[1], RT, 512, 512, 1);
    Read(T[2], RT, 512, 512, 2);
    g->Submit();
    printf("hazard onewait %g %g %g\n", Texel(0), Texel(1), Texel(2));
}

// Three passes into T0 with no barrier: with newest-writer dependencies (spec §3.9) the third waits on the second
// alone. DXMT_STATS, this mode alone: 2 dependency waits.
static void Newest() {
    Clear(T[0]);
    g->Submit();
    Pass(T[0], add, 1, 1);
    Pass(T[0], add, 1, 1);
    Pass(T[0], add, 1, 1);
    g->Submit();
    Read(T[0], RT, 512, 512, 0);
    g->Submit();
    printf("hazard newest %g\n", Texel(0));
}

// T0 rendered (heavy); a barrier to PIXEL_SHADER_RESOURCE and a UAV barrier (a join); a pass into T2 whose only draw
// has no instances; then T1 = T0 sampled + 1, in that pass's group. The sampling pass must still see T0 done: a
// join's early fence (spec §3.9) is reached only after its waits, draws or not.
static void NoDraw() {
    Clear(T[0]);
    g->Submit();
    Pass(T[0], add, 1, 256);
    g->Barrier(T[0].texture, RT, PSR);
    D3D12_RESOURCE_BARRIER all = {D3D12_RESOURCE_BARRIER_TYPE_UAV};
    g->list->ResourceBarrier(1, &all);
    Pass(T[2], set, 1, 0);
    Pass(T[1], sample, 1, 1, &T[0]);
    g->Barrier(T[0].texture, PSR, RT);
    Read(T[1], RT, 512, 512, 0);
    g->Submit();
    printf("hazard nodraw %g\n", Texel(0));
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
        {"many", Many},              {"clear-rects", ClearRects}, {"signal", Signal},
        {"wrap", Wrap}, {"onewait", OneWait}, {"newest", Newest}, {"nodraw", NoDraw}};
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
