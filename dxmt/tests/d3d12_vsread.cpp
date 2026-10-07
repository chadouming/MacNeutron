// Resources read by a vertex shader (Niagara sprites, translucency fog), drawn offscreen through D3D12:
//   d3d12_vsread.exe <vs.dxil> <ps.dxil>   (shaders/vsread.hlsl)
// The vertex shader reads a half-float typed buffer (R16_FLOAT, FirstElement 3), a structured buffer (FirstElement
// 1), a 3D texture and a cube map (SampleLevel) and passes each to a render target (RGBA32F). Prints
// "vsread ok <typed> <structured> <volume> <cube>", four floats each. check.sh compares with D3DMetal.
//   d3d12_vsread.exe <vsia.dxil> <ps.dxil> ia   (Task F2) the vertex shader reads the input assembler instead: slot 0
// bound to (1, 2, 3, 4), slot 1 never bound (R32G32_FLOAT and R32G32B32A32_FLOAT), slot 3 a null view (R32_UINT).
// Prints "vsread ia <a> <b> <c> <d>"; D3D: unbound slots read zeros, widened by the format: (0,0,0,1) and (0,0,0,0).
#include "d3d12_common.hpp"

static uint16_t Half(float f) {  // exact for the small multiples of 1/4 used here
    if (f == 0) return 0;
    int e = 0; float m = f;
    while (m >= 2) { m /= 2; e++; }
    while (m < 1) { m *= 2; e--; }
    return (uint16_t)(((e + 15) << 10) | (uint16_t)((m - 1) * 1024));
}

int main(int argc, char **argv) {
    bool ia = argc == 4 && !strcmp(argv[3], "ia");
    if (argc != 3 && !ia) { printf("usage: d3d12_vsread.exe <vs.dxil> <ps.dxil> [ia]\n"); return 2; }
    std::vector<char> vs = Load(argv[1]), ps = Load(argv[2]);
    if (vs.empty() || ps.empty()) { printf("can't read the shaders\n"); return 1; }
    Gpu gpu;
    D3D12_DESCRIPTOR_RANGE srvs = {D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 4, 0, 0, 0};
    D3D12_ROOT_PARAMETER param = {};
    param.ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE; param.DescriptorTable = {1, &srvs};
    D3D12_STATIC_SAMPLER_DESC sampler = {};
    sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
    sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    sampler.MaxLOD = D3D12_FLOAT32_MAX;
    D3D12_ROOT_SIGNATURE_DESC rd = {1, &param, 1, &sampler,
                                    ia ? D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT : D3D12_ROOT_SIGNATURE_FLAG_NONE};
    ID3D12RootSignature *root = gpu.RootSignature(rd);
    D3D12_GRAPHICS_PIPELINE_STATE_DESC gd = {};
    gd.pRootSignature = root;
    gd.VS = {vs.data(), vs.size()};
    gd.PS = {ps.data(), ps.size()};
    D3D12_INPUT_ELEMENT_DESC layout[] = {
        {"A", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
        {"B", 0, DXGI_FORMAT_R32G32_FLOAT, 1, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
        {"C", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 1, 8, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
        {"D", 0, DXGI_FORMAT_R32_UINT, 3, 4, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0}};
    if (ia)
        gd.InputLayout = {layout, 4};
    for (int i = 0; i < 4; i++) {
        gd.BlendState.RenderTarget[i].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
        gd.RTVFormats[i] = DXGI_FORMAT_R32G32B32A32_FLOAT;
    }
    gd.BlendState.IndependentBlendEnable = TRUE;
    gd.SampleMask = UINT_MAX;
    gd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    gd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    gd.RasterizerState.DepthClipEnable = TRUE;
    gd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    gd.NumRenderTargets = 4;
    gd.SampleDesc.Count = 1;
    ID3D12PipelineState *pso;
    CHECK(gpu.device->CreateGraphicsPipelineState(&gd, __uuidof(ID3D12PipelineState), (void **)&pso));

    // Data: 16 halves i/4; 4 structs (i, i + 0.5, 2i, 1); a 4x4x4 volume (x/4, y/4, z/4, 1); cube faces coloured by face.
    ID3D12Resource *halves = gpu.Buffer(D3D12_HEAP_TYPE_UPLOAD, 256, D3D12_RESOURCE_STATE_GENERIC_READ);
    ID3D12Resource *structs = gpu.Buffer(D3D12_HEAP_TYPE_UPLOAD, 256, D3D12_RESOURCE_STATE_GENERIC_READ);
    ID3D12Resource *upload = gpu.Buffer(D3D12_HEAP_TYPE_UPLOAD, 4096 + 6 * 1024, D3D12_RESOURCE_STATE_GENERIC_READ);
    uint8_t *p; D3D12_RANGE none = {0, 0};
    CHECK(halves->Map(0, &none, (void **)&p));
    for (int i = 0; i < 16; i++) { uint16_t h = Half(i * 0.25f); memcpy(p + i * 2, &h, 2); }
    halves->Unmap(0, nullptr);
    CHECK(structs->Map(0, &none, (void **)&p));
    for (int i = 0; i < 4; i++) { float s[4] = {(float)i, i + 0.5f, 2.0f * i, 1}; memcpy(p + i * 16, s, 16); }
    structs->Unmap(0, nullptr);
    CHECK(upload->Map(0, &none, (void **)&p));
    for (int z = 0; z < 4; z++) for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) {
        uint16_t t[4] = {Half(x * 0.25f), Half(y * 0.25f), Half(z * 0.25f), Half(1)};
        memcpy(p + z * 1024 + y * 256 + x * 8, t, 8);
    }
    for (int f = 0; f < 6; f++) for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) {
        uint8_t t[4] = {(uint8_t)(f * 40), (uint8_t)(255 - f * 40), 100, 255};
        memcpy(p + 4096 + f * 1024 + y * 256 + x * 4, t, 4);
    }
    upload->Unmap(0, nullptr);
    D3D12_RESOURCE_DESC vd = {};
    vd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE3D; vd.Width = 4; vd.Height = 4; vd.DepthOrArraySize = 4;
    vd.MipLevels = 1; vd.Format = DXGI_FORMAT_R16G16B16A16_FLOAT; vd.SampleDesc.Count = 1;
    ID3D12Resource *volume = gpu.Texture(vd, D3D12_RESOURCE_STATE_COPY_DEST);
    ID3D12Resource *cube = gpu.Texture(Tex2D(4, 4, DXGI_FORMAT_R8G8B8A8_UNORM, 1, D3D12_RESOURCE_FLAG_NONE, 6),
                                       D3D12_RESOURCE_STATE_COPY_DEST);
    ID3D12GraphicsCommandList *list = gpu.list;
    D3D12_TEXTURE_COPY_LOCATION to = {volume, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}; to.SubresourceIndex = 0;
    D3D12_TEXTURE_COPY_LOCATION from = {upload, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT};
    from.PlacedFootprint = {0, {DXGI_FORMAT_R16G16B16A16_FLOAT, 4, 4, 4, 256}};
    list->CopyTextureRegion(&to, 0, 0, 0, &from, nullptr);
    for (UINT f = 0; f < 6; f++) {
        to = {cube, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}; to.SubresourceIndex = f;
        from.PlacedFootprint = {4096 + f * 1024, {DXGI_FORMAT_R8G8B8A8_UNORM, 4, 4, 1, 256}};
        list->CopyTextureRegion(&to, 0, 0, 0, &from, nullptr);
    }
    gpu.Barrier(volume, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    gpu.Barrier(cube, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);

    ID3D12DescriptorHeap *heap;
    D3D12_DESCRIPTOR_HEAP_DESC hd = {D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 4, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE};
    CHECK(gpu.device->CreateDescriptorHeap(&hd, __uuidof(ID3D12DescriptorHeap), (void **)&heap));
    UINT step = gpu.device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    auto cpu = [&](UINT i) { auto h = heap->GetCPUDescriptorHandleForHeapStart(); h.ptr += i * step; return h; };
    D3D12_SHADER_RESOURCE_VIEW_DESC sv = {};
    sv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
    sv.Format = DXGI_FORMAT_R16_FLOAT; sv.ViewDimension = D3D12_SRV_DIMENSION_BUFFER;
    sv.Buffer.FirstElement = 3; sv.Buffer.NumElements = 8;
    gpu.device->CreateShaderResourceView(halves, &sv, cpu(0));
    sv.Format = DXGI_FORMAT_UNKNOWN; sv.Buffer.FirstElement = 1; sv.Buffer.NumElements = 3; sv.Buffer.StructureByteStride = 16;
    gpu.device->CreateShaderResourceView(structs, &sv, cpu(1));
    D3D12_SHADER_RESOURCE_VIEW_DESC tv = {};
    tv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
    tv.Format = DXGI_FORMAT_R16G16B16A16_FLOAT; tv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE3D; tv.Texture3D.MipLevels = 1;
    gpu.device->CreateShaderResourceView(volume, &tv, cpu(2));
    tv.Format = DXGI_FORMAT_R8G8B8A8_UNORM; tv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURECUBE; tv.TextureCube.MipLevels = 1;
    gpu.device->CreateShaderResourceView(cube, &tv, cpu(3));

    ID3D12Resource *targets[4];
    ID3D12DescriptorHeap *rtv_heap;
    D3D12_DESCRIPTOR_HEAP_DESC rhd = {D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 4};
    CHECK(gpu.device->CreateDescriptorHeap(&rhd, __uuidof(ID3D12DescriptorHeap), (void **)&rtv_heap));
    UINT rtv_step = gpu.device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    D3D12_CPU_DESCRIPTOR_HANDLE rtvs[4];
    for (int i = 0; i < 4; i++) {
        targets[i] = gpu.Texture(Tex2D(4, 4, DXGI_FORMAT_R32G32B32A32_FLOAT, 1, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET),
                                 D3D12_RESOURCE_STATE_RENDER_TARGET);
        rtvs[i] = rtv_heap->GetCPUDescriptorHandleForHeapStart(); rtvs[i].ptr += i * rtv_step;
        gpu.device->CreateRenderTargetView(targets[i], nullptr, rtvs[i]);
    }
    ID3D12Resource *readback = gpu.Buffer(D3D12_HEAP_TYPE_READBACK, 4 * 1024, D3D12_RESOURCE_STATE_COPY_DEST);
    D3D12_VIEWPORT viewport = {0, 0, 4, 4, 0, 1};
    D3D12_RECT scissor = {0, 0, 4, 4};
    list->OMSetRenderTargets(4, rtvs, FALSE, nullptr);
    list->RSSetViewports(1, &viewport);
    list->RSSetScissorRects(1, &scissor);
    list->SetDescriptorHeaps(1, &heap);
    list->SetGraphicsRootSignature(root);
    list->SetGraphicsRootDescriptorTable(0, heap->GetGPUDescriptorHandleForHeapStart());
    list->SetPipelineState(pso);
    list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    if (ia) {  // slot 0: (1, 2, 3, 4) for every vertex (stride 0); slot 3: a null view; slot 1 never set
        float a[4] = {1, 2, 3, 4};
        CHECK(structs->Map(0, &none, (void **)&p)); memcpy(p, a, 16); structs->Unmap(0, nullptr);
        D3D12_VERTEX_BUFFER_VIEW views[4] = {{structs->GetGPUVirtualAddress(), 16, 0}, {}, {}, {0, 0, 64}};
        list->IASetVertexBuffers(0, 1, &views[0]);
        list->IASetVertexBuffers(3, 1, &views[3]);
    }
    list->DrawInstanced(3, 1, 0, 0);
    for (int i = 0; i < 4; i++) {
        gpu.Barrier(targets[i], D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_SOURCE);
        D3D12_TEXTURE_COPY_LOCATION src = {targets[i], D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}; src.SubresourceIndex = 0;
        D3D12_TEXTURE_COPY_LOCATION dst = {readback, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT};
        dst.PlacedFootprint = {(UINT64)i * 1024, {DXGI_FORMAT_R32G32B32A32_FLOAT, 4, 4, 1, 256}};
        list->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
    }
    gpu.Submit();
    float *r; D3D12_RANGE whole = {0, 4 * 1024};
    CHECK(readback->Map(0, &whole, (void **)&r));
    printf(ia ? "vsread ia" : "vsread ok");
    for (int i = 0; i < 4; i++) {
        const float *t = r + (i * 1024 + 2 * 256 + 2 * 16) / 4;  // texel (2,2)
        printf(" %g,%g,%g,%g", t[0], t[1], t[2], t[3]);
    }
    printf("\n");
    readback->Unmap(0, &none);
    return 0;
}
