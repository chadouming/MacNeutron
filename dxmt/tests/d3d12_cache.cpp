// The D3D12 translation cache (shader pre-caching spec §5.1), drawn offscreen through D3D12:
//   d3d12_cache.exe <vs.dxil> <ps.dxil> <cs.dxil> <a|rt|layout|root>   (shaders/cache.hlsl)
// Mode a: a quad over the left half of a 32x32 R32G32B32A32_FLOAT target, from a vertex buffer (POSITION at offset
// 0), coloured from a root CBV (root parameter 0); and csmain over 64 floats, with the root signature embedded in it.
// Each other mode changes one thing that a reused translated function would get wrong:
//   rt      an R16G16B16A16_FLOAT target;
//   layout  POSITION at offset 8 of 16-byte vertices, whose first 8 bytes would put the quad on the right half;
//   root    a root constant first, so the CBV is root parameter 1.
// Prints "cache <mode> ok <texel (8,16)> <texel (24,16)> <data[0]> <data[1]> <data[63]>", texels as the target's bytes
// in hex, then "timing <ms creating the two pipelines>". check.sh compares the cache line with D3DMetal's.
#include "d3d12_common.hpp"
#include <string>

int main(int argc, char **argv) {
    if (argc != 5) { printf("usage: d3d12_cache.exe <vs.dxil> <ps.dxil> <cs.dxil> <a|rt|layout|root>\n"); return 2; }
    std::vector<char> vs = Load(argv[1]), ps = Load(argv[2]), cs = Load(argv[3]);
    if (vs.empty() || ps.empty() || cs.empty()) { printf("can't read the shaders\n"); return 1; }
    const std::string mode = argv[4];
    const bool rt = mode == "rt", layout = mode == "layout", rootmode = mode == "root";
    if (mode != "a" && !rt && !layout && !rootmode) { printf("unknown mode %s\n", argv[4]); return 2; }
    const UINT size = 32, texel = rt ? 8 : 16, pitch = size * texel;  // 256 or 512: both 256-aligned
    const DXGI_FORMAT format = rt ? DXGI_FORMAT_R16G16B16A16_FLOAT : DXGI_FORMAT_R32G32B32A32_FLOAT;
    Gpu gpu;

    D3D12_ROOT_PARAMETER params[2] = {};
    params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
    params[0].Constants = {1, 0, 1};  // b1, one value; no shader reads it
    params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;  // b0
    D3D12_ROOT_SIGNATURE_DESC rd = {};
    rd.NumParameters = rootmode ? 2 : 1;
    rd.pParameters = rootmode ? params : &params[1];
    rd.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
    ID3D12RootSignature *root = gpu.RootSignature(rd), *croot;
    CHECK(gpu.device->CreateRootSignature(0, cs.data(), cs.size(), __uuidof(ID3D12RootSignature), (void **)&croot));

    D3D12_INPUT_ELEMENT_DESC element = {"POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, layout ? 8u : 0u,
                                        D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0};
    D3D12_GRAPHICS_PIPELINE_STATE_DESC gd = {};
    gd.pRootSignature = root;
    gd.VS = {vs.data(), vs.size()};
    gd.PS = {ps.data(), ps.size()};
    gd.InputLayout = {&element, 1};
    gd.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    gd.SampleMask = UINT_MAX;
    gd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    gd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    gd.RasterizerState.DepthClipEnable = TRUE;
    gd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    gd.NumRenderTargets = 1;
    gd.RTVFormats[0] = format;
    gd.SampleDesc.Count = 1;
    D3D12_COMPUTE_PIPELINE_STATE_DESC cd = {};
    cd.CS = {cs.data(), cs.size()};  // no pRootSignature: the one embedded in cs.dxil
    LARGE_INTEGER frequency, start, end;
    QueryPerformanceFrequency(&frequency);
    QueryPerformanceCounter(&start);
    ID3D12PipelineState *pso, *cpso;
    CHECK(gpu.device->CreateGraphicsPipelineState(&gd, __uuidof(ID3D12PipelineState), (void **)&pso));
    CHECK(gpu.device->CreateComputePipelineState(&cd, __uuidof(ID3D12PipelineState), (void **)&cpso));
    QueryPerformanceCounter(&end);

    // The left half of the target; layout mode also stores the right half where offset 0 would read.
    const float left[6][2] = {{-1, -1}, {0, -1}, {-1, 1}, {-1, 1}, {0, -1}, {0, 1}};
    float wide[6][4];
    for (int i = 0; i < 6; i++) {
        wide[i][0] = left[i][0] + 1; wide[i][1] = left[i][1];
        wide[i][2] = left[i][0]; wide[i][3] = left[i][1];
    }
    const void *vdata = layout ? (const void *)wide : (const void *)left;
    const UINT vsize = layout ? sizeof wide : sizeof left;
    const float color[64] = {0.25f, 0.5f, 0.75f, 1};  // 256 bytes, a CBV's unit
    float values[64];
    for (int i = 0; i < 64; i++) values[i] = (float)i;
    ID3D12Resource *vbuf = gpu.Buffer(D3D12_HEAP_TYPE_UPLOAD, vsize, D3D12_RESOURCE_STATE_GENERIC_READ);
    ID3D12Resource *cbuf = gpu.Buffer(D3D12_HEAP_TYPE_UPLOAD, sizeof color, D3D12_RESOURCE_STATE_GENERIC_READ);
    ID3D12Resource *upload = gpu.Buffer(D3D12_HEAP_TYPE_UPLOAD, sizeof values, D3D12_RESOURCE_STATE_GENERIC_READ);
    void *p; D3D12_RANGE none = {0, 0};
    CHECK(vbuf->Map(0, &none, &p)); memcpy(p, vdata, vsize); vbuf->Unmap(0, nullptr);
    CHECK(cbuf->Map(0, &none, &p)); memcpy(p, color, sizeof color); cbuf->Unmap(0, nullptr);
    CHECK(upload->Map(0, &none, &p)); memcpy(p, values, sizeof values); upload->Unmap(0, nullptr);
    ID3D12Resource *data = gpu.Buffer(D3D12_HEAP_TYPE_DEFAULT, sizeof values, D3D12_RESOURCE_STATE_COPY_DEST,
                                      D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    ID3D12Resource *target = gpu.Texture(Tex2D(size, size, format, 1, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET),
                                         D3D12_RESOURCE_STATE_RENDER_TARGET);
    ID3D12Resource *pixels = gpu.Buffer(D3D12_HEAP_TYPE_READBACK, pitch * size, D3D12_RESOURCE_STATE_COPY_DEST);
    ID3D12Resource *result = gpu.Buffer(D3D12_HEAP_TYPE_READBACK, sizeof values, D3D12_RESOURCE_STATE_COPY_DEST);
    ID3D12DescriptorHeap *rtv_heap;
    D3D12_DESCRIPTOR_HEAP_DESC hd = {D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 1};
    CHECK(gpu.device->CreateDescriptorHeap(&hd, __uuidof(ID3D12DescriptorHeap), (void **)&rtv_heap));
    D3D12_CPU_DESCRIPTOR_HANDLE rtv = rtv_heap->GetCPUDescriptorHandleForHeapStart();
    gpu.device->CreateRenderTargetView(target, nullptr, rtv);

    ID3D12GraphicsCommandList *list = gpu.list;
    const float clear[4] = {0, 0, 0, 0};
    D3D12_VIEWPORT viewport = {0, 0, (float)size, (float)size, 0, 1};
    D3D12_RECT scissor = {0, 0, (LONG)size, (LONG)size};
    D3D12_VERTEX_BUFFER_VIEW vbv = {vbuf->GetGPUVirtualAddress(), vsize, layout ? 16u : 8u};
    list->ClearRenderTargetView(rtv, clear, 0, nullptr);
    list->OMSetRenderTargets(1, &rtv, FALSE, nullptr);
    list->RSSetViewports(1, &viewport);
    list->RSSetScissorRects(1, &scissor);
    list->SetGraphicsRootSignature(root);
    if (rootmode) list->SetGraphicsRoot32BitConstant(0, 0x3f800000, 0);  // 1.0f
    list->SetGraphicsRootConstantBufferView(rootmode ? 1 : 0, cbuf->GetGPUVirtualAddress());
    list->SetPipelineState(pso);
    list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    list->IASetVertexBuffers(0, 1, &vbv);
    list->DrawInstanced(6, 1, 0, 0);
    gpu.Barrier(target, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION from = {target, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}; from.SubresourceIndex = 0;
    D3D12_TEXTURE_COPY_LOCATION to = {pixels, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT};
    to.PlacedFootprint.Footprint = {format, size, size, 1, pitch};
    list->CopyTextureRegion(&to, 0, 0, 0, &from, nullptr);
    list->CopyBufferRegion(data, 0, upload, 0, sizeof values);
    gpu.Barrier(data, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    list->SetComputeRootSignature(croot);
    list->SetComputeRootUnorderedAccessView(0, data->GetGPUVirtualAddress());
    list->SetPipelineState(cpso);
    list->Dispatch(1, 1, 1);
    gpu.Barrier(data, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
    list->CopyBufferRegion(result, 0, data, 0, sizeof values);
    gpu.Submit();

    uint8_t *px; float *out;
    D3D12_RANGE whole = {0, pitch * size}, all = {0, sizeof values};
    CHECK(pixels->Map(0, &whole, (void **)&px));
    CHECK(result->Map(0, &all, (void **)&out));
    auto hex = [&](UINT x, UINT y) {
        std::string s; char b[3];
        for (UINT i = 0; i < texel; i++) { snprintf(b, sizeof b, "%02x", px[y * pitch + x * texel + i]); s += b; }
        return s;
    };
    printf("cache %s ok %s %s %g %g %g\n", argv[4], hex(8, 16).c_str(), hex(24, 16).c_str(), out[0], out[1], out[63]);
    printf("timing %.1f\n", (end.QuadPart - start.QuadPart) * 1000.0 / frequency.QuadPart);
    fflush(stdout);
    pixels->Unmap(0, &none);
    result->Unmap(0, &none);
    return 0;
}
