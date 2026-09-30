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
