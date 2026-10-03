// GPU efficiency spec E1: textures created with Apple's lossless compression. Prints
//   "compress clear <us>"            GPU microseconds per clear-only pass of a 3840x2160 RGBA16F target, from timestamps:
//                                    check.sh wants it 3x faster than with DXMT_D3D12_COMPRESSION=0 (a pass also costs
//                                    about 20 us that compression doesn't touch: the larger target keeps the ratio clear)
//   "compress views <a> <b> <c>"     a typeless RGBA8 target cleared to 0.5 through its sRGB view (a) and its UNORM view
//                                    (b), then copied into an R8G8B8A8_UINT texture (c): red bytes 188 128 128
//   "compress placed <a> <b> <c> <d>" two such targets placed back to back in one heap at GetResourceAllocationInfo's
//                                    offsets, cleared to 1 and 2, read at two corners each: 1 1 2 2
// check.sh compares the views and placed lines with D3DMetal's.
#include "d3d12_common.hpp"
#include <algorithm>
#include <cmath>

static const UINT kW = 2560, kH = 1440;

static Gpu *g;
static ID3D12Resource *readback; // 16 slots of 256 bytes
static ID3D12DescriptorHeap *rtv_heap;
static UINT rtvs;

static D3D12_CPU_DESCRIPTOR_HANDLE Rtv(ID3D12Resource *r, DXGI_FORMAT format) {
    D3D12_CPU_DESCRIPTOR_HANDLE h = rtv_heap->GetCPUDescriptorHandleForHeapStart();
    h.ptr += rtvs++ * g->device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    D3D12_RENDER_TARGET_VIEW_DESC vd = {format, D3D12_RTV_DIMENSION_TEXTURE2D};
    g->device->CreateRenderTargetView(r, &vd, h);
    return h;
}

// One texel of `r` (in `state`) into readback slot `slot`.
static void Read(ID3D12Resource *r, D3D12_RESOURCE_STATES state, DXGI_FORMAT format, UINT x, UINT y, UINT slot) {
    if (state != D3D12_RESOURCE_STATE_COPY_SOURCE)
        g->Barrier(r, state, D3D12_RESOURCE_STATE_COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION src = {r, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX};
    src.SubresourceIndex = 0;
    D3D12_TEXTURE_COPY_LOCATION dst = {readback, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT};
    dst.PlacedFootprint = {(UINT64)slot * 256, {format, 1, 1, 1, 256}};
    D3D12_BOX box = {x, y, 0, x + 1, y + 1, 1};
    g->list->CopyTextureRegion(&dst, 0, 0, 0, &src, &box);
    if (state != D3D12_RESOURCE_STATE_COPY_SOURCE)
        g->Barrier(r, D3D12_RESOURCE_STATE_COPY_SOURCE, state);
}

static const uint8_t *Slots() {
    static uint8_t copy[16 * 256];
    void *p;
    D3D12_RANGE whole = {0, sizeof copy}, none = {0, 0};
    CHECK(readback->Map(0, &whole, &p));
    memcpy(copy, p, sizeof copy);
    readback->Unmap(0, &none);
    return copy;
}

static float Half(uint16_t h) {
    int e = h >> 10 & 31, m = h & 1023;
    return e ? ldexpf(1024.0f + m, e - 25) : ldexpf((float)m, -24);
}

static void Clear() {
    auto rt = D3D12_RESOURCE_STATE_RENDER_TARGET;
    ID3D12Resource *t = g->Texture(Tex2D(3840, 2160, DXGI_FORMAT_R16G16B16A16_FLOAT, 1, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET), rt);
    auto h = Rtv(t, DXGI_FORMAT_R16G16B16A16_FLOAT);
    ID3D12QueryHeap *heap;
    D3D12_QUERY_HEAP_DESC qd = {D3D12_QUERY_HEAP_TYPE_TIMESTAMP, 2};
    CHECK(g->device->CreateQueryHeap(&qd, __uuidof(ID3D12QueryHeap), (void **)&heap));
    const UINT n = 40;
    double best = 1e30;
    for (int round = 0; round < 5; round++) { // the fastest of 5: other GPU work only slows a round down
        g->list->EndQuery(heap, D3D12_QUERY_TYPE_TIMESTAMP, 0);
        for (UINT i = 0; i < n; i++) {
            const float v[4] = {i % 2 ? 0.25f : 0.75f, 0.5f, 0.125f, 1.0f};
            g->list->ClearRenderTargetView(h, v, 0, nullptr);
        }
        g->list->EndQuery(heap, D3D12_QUERY_TYPE_TIMESTAMP, 1);
        g->list->ResolveQueryData(heap, D3D12_QUERY_TYPE_TIMESTAMP, 0, 2, readback, 15 * 256);
        g->Submit();
        UINT64 ticks[2], freq;
        memcpy(ticks, Slots() + 15 * 256, sizeof ticks);
        CHECK(g->queue->GetTimestampFrequency(&freq));
        best = std::min(best, (double)(ticks[1] - ticks[0]) / freq * 1e6 / n);
    }
    printf("compress clear %.1f\n", best);
}

static void Views() {
    auto rt = D3D12_RESOURCE_STATE_RENDER_TARGET;
    ID3D12Resource *t = g->Texture(Tex2D(256, 256, DXGI_FORMAT_R8G8B8A8_TYPELESS, 1, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET), rt);
    ID3D12Resource *u = g->Texture(Tex2D(256, 256, DXGI_FORMAT_R8G8B8A8_UINT), D3D12_RESOURCE_STATE_COPY_DEST);
    const float half[4] = {0.5f, 0.5f, 0.5f, 1.0f};
    g->list->ClearRenderTargetView(Rtv(t, DXGI_FORMAT_R8G8B8A8_UNORM_SRGB), half, 0, nullptr);
    Read(t, rt, DXGI_FORMAT_R8G8B8A8_UNORM, 100, 100, 0);
    g->list->ClearRenderTargetView(Rtv(t, DXGI_FORMAT_R8G8B8A8_UNORM), half, 0, nullptr);
    Read(t, rt, DXGI_FORMAT_R8G8B8A8_UNORM, 100, 100, 1);
    g->Barrier(t, rt, D3D12_RESOURCE_STATE_COPY_SOURCE);
    g->list->CopyResource(u, t);
    g->Barrier(t, D3D12_RESOURCE_STATE_COPY_SOURCE, rt);
    Read(u, D3D12_RESOURCE_STATE_COPY_DEST, DXGI_FORMAT_R8G8B8A8_UINT, 100, 100, 2);
    g->Submit();
    auto s = Slots();
    printf("compress views %u %u %u\n", s[0], s[256], s[512]);
}

static void Placed() {
    auto rt = D3D12_RESOURCE_STATE_RENDER_TARGET;
    D3D12_RESOURCE_DESC d = Tex2D(kW, kH, DXGI_FORMAT_R16G16B16A16_FLOAT, 1, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET);
    D3D12_RESOURCE_ALLOCATION_INFO info = g->device->GetResourceAllocationInfo(0, 1, &d);
    UINT64 second = (info.SizeInBytes + info.Alignment - 1) / info.Alignment * info.Alignment;
    D3D12_HEAP_DESC hd = {second + info.SizeInBytes, {D3D12_HEAP_TYPE_DEFAULT}, info.Alignment,
                          D3D12_HEAP_FLAG_ALLOW_ONLY_RT_DS_TEXTURES};
    ID3D12Heap *heap;
    CHECK(g->device->CreateHeap(&hd, __uuidof(ID3D12Heap), (void **)&heap));
    ID3D12Resource *a, *b;
    CHECK(g->device->CreatePlacedResource(heap, 0, &d, rt, nullptr, __uuidof(ID3D12Resource), (void **)&a));
    CHECK(g->device->CreatePlacedResource(heap, second, &d, rt, nullptr, __uuidof(ID3D12Resource), (void **)&b));
    const float one[4] = {1, 1, 1, 1}, two[4] = {2, 2, 2, 2};
    g->list->ClearRenderTargetView(Rtv(a, DXGI_FORMAT_R16G16B16A16_FLOAT), one, 0, nullptr);
    g->list->ClearRenderTargetView(Rtv(b, DXGI_FORMAT_R16G16B16A16_FLOAT), two, 0, nullptr);
    Read(a, rt, DXGI_FORMAT_R16G16B16A16_FLOAT, 0, 0, 3);
    Read(a, rt, DXGI_FORMAT_R16G16B16A16_FLOAT, kW - 1, kH - 1, 4);
    Read(b, rt, DXGI_FORMAT_R16G16B16A16_FLOAT, 0, 0, 5);
    Read(b, rt, DXGI_FORMAT_R16G16B16A16_FLOAT, kW - 1, kH - 1, 6);
    g->Submit();
    auto s = Slots();
    uint16_t h[4];
    for (int i = 0; i < 4; i++)
        memcpy(&h[i], s + (3 + i) * 256, 2);
    printf("compress placed %g %g %g %g\n", Half(h[0]), Half(h[1]), Half(h[2]), Half(h[3]));
}

int main() {
    g = new Gpu();
    readback = g->Buffer(D3D12_HEAP_TYPE_READBACK, 16 * 256, D3D12_RESOURCE_STATE_COPY_DEST);
    D3D12_DESCRIPTOR_HEAP_DESC dd = {D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 16};
    CHECK(g->device->CreateDescriptorHeap(&dd, __uuidof(ID3D12DescriptorHeap), (void **)&rtv_heap));
    Clear();
    Views();
    Placed();
    return 0;
}
