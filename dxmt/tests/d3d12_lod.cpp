// Which mip a pixel shader's sample uses (Task FU, from the blur study's sweep):
//   d3d12_lod.exe <lod.vs.dxil> <lod.ps.dxil>
// A 128x128 RGBA8 texture with 8 mips, mip m solid R = 32m: the mean R of a trilinear sample over a 64x64 target, /32,
// is the LOD used. The target's u is stretched k times (k = 1, 8, 16: 2, 16 and 32 texels a pixel on u, 2 on v), so the
// footprint's anisotropy ratio is k. Static samplers, all WRAP, MaxLOD FLT_MAX: s0-s2 MIN_MAG_MIP_LINEAR with
// MipLODBias 0, -1 and +1; s3-s5 ANISOTROPIC 1, 4 and 16; s6 ANISOTROPIC 4 with bias -1 (an upscaler's bias on a game's
// 4x). Ops: Sample, SampleBias(-1), SampleGrad(ddx, ddy) and SampleGrad with both halved (bias -1 through them).
// Prints "lod k=<k> s<n> <op> <lod>" per case, then "lod done".
#include "d3d12_common.hpp"
#include <cfloat>

static const UINT kTex = 128, kMips = 8, kRT = 64;
static const auto RT = D3D12_RESOURCE_STATE_RENDER_TARGET, PSR = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,
                  COPY_DEST = D3D12_RESOURCE_STATE_COPY_DEST, COPY_SOURCE = D3D12_RESOURCE_STATE_COPY_SOURCE;

int main(int argc, char **argv) {
    if (argc < 3) { printf("usage: d3d12_lod.exe vs ps\n"); return 1; }
    auto vs = Load(argv[1]), ps = Load(argv[2]);
    if (vs.empty() || ps.empty()) { printf("fail no shaders\n"); return 1; }
    Gpu gpu;

    // [0] 4 root constants b0, [1] an SRV table t0; 7 static samplers.
    D3D12_DESCRIPTOR_RANGE srv_range = {D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 1, 0, 0, 0};
    D3D12_ROOT_PARAMETER p[2] = {};
    p[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS; p[0].Constants = {0, 0, 4};
    p[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE; p[1].DescriptorTable = {1, &srv_range};
    p[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    D3D12_STATIC_SAMPLER_DESC samplers[7] = {};
    static const float bias[7] = {0, -1, 1, 0, 0, 0, -1};
    static const UINT aniso[7] = {1, 1, 1, 1, 4, 16, 4};
    for (UINT n = 0; n < 7; n++) {
        auto &d = samplers[n];
        d.Filter = n >= 3 ? D3D12_FILTER_ANISOTROPIC : D3D12_FILTER_MIN_MAG_MIP_LINEAR;
        d.AddressU = d.AddressV = d.AddressW = D3D12_TEXTURE_ADDRESS_MODE_WRAP;
        d.MipLODBias = bias[n]; d.MaxAnisotropy = aniso[n];
        d.ComparisonFunc = D3D12_COMPARISON_FUNC_NEVER; d.MinLOD = 0; d.MaxLOD = FLT_MAX;
        d.ShaderRegister = n; d.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    }
    ID3D12RootSignature *root = gpu.RootSignature({2, p, 7, samplers, D3D12_ROOT_SIGNATURE_FLAG_NONE});
    ID3D12PipelineState *pso = QuadPipeline(gpu, root, vs, ps);

    // The texture, every mip uploaded (row pitch 512, one 64 KiB slot per mip).
    ID3D12Resource *tex = gpu.Texture(Tex2D(kTex, kTex, DXGI_FORMAT_R8G8B8A8_UNORM, kMips), COPY_DEST);
    ID3D12Resource *up = gpu.Buffer(D3D12_HEAP_TYPE_UPLOAD, 65536 * kMips, D3D12_RESOURCE_STATE_GENERIC_READ);
    uint8_t *u; CHECK(up->Map(0, nullptr, (void **)&u));
    for (UINT m = 0; m < kMips; m++) {
        UINT s = kTex >> m;
        for (UINT y = 0; y < s; y++)
            for (UINT x = 0; x < s; x++) {
                uint8_t *t = u + 65536 * m + 512 * y + 4 * x;
                t[0] = m * 32; t[1] = 255 - m * 32; t[2] = 0; t[3] = 255;
            }
        D3D12_TEXTURE_COPY_LOCATION dst = {tex, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}; dst.SubresourceIndex = m;
        D3D12_TEXTURE_COPY_LOCATION src = {up, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT};
        src.PlacedFootprint.Offset = 65536 * m;
        src.PlacedFootprint.Footprint = {DXGI_FORMAT_R8G8B8A8_UNORM, s, s, 1, 512};
        gpu.list->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
    }
    up->Unmap(0, nullptr);
    gpu.Barrier(tex, COPY_DEST, PSR);

    ID3D12DescriptorHeap *srv_heap, *rtv_heap;
    D3D12_DESCRIPTOR_HEAP_DESC hd = {D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 1, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE};
    CHECK(gpu.device->CreateDescriptorHeap(&hd, __uuidof(ID3D12DescriptorHeap), (void **)&srv_heap));
    hd = {D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 1, D3D12_DESCRIPTOR_HEAP_FLAG_NONE};
    CHECK(gpu.device->CreateDescriptorHeap(&hd, __uuidof(ID3D12DescriptorHeap), (void **)&rtv_heap));
    D3D12_SHADER_RESOURCE_VIEW_DESC sd = {};
    sd.Format = DXGI_FORMAT_R8G8B8A8_UNORM; sd.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
    sd.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
    sd.Texture2D.MipLevels = (UINT)-1;
    gpu.device->CreateShaderResourceView(tex, &sd, srv_heap->GetCPUDescriptorHandleForHeapStart());
    ID3D12Resource *target = gpu.Texture(Tex2D(kRT, kRT, DXGI_FORMAT_R8G8B8A8_UNORM, 1, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET), RT);
    auto rtv = rtv_heap->GetCPUDescriptorHandleForHeapStart();
    gpu.device->CreateRenderTargetView(target, nullptr, rtv);
    ID3D12Resource *rb = gpu.Buffer(D3D12_HEAP_TYPE_READBACK, 256 * kRT, COPY_DEST);
    gpu.Submit();

    static const char *ops[4] = {"Sample", "SampleBias(-1)", "SampleGrad", "SampleGrad/2"};
    static const UINT op_codes[4] = {0, 1, 2, 2};
    static const float args[4] = {0, -1, 0, -1};
    static const float ks[3] = {1, 8, 16};
    D3D12_VIEWPORT vp = {0, 0, (float)kRT, (float)kRT, 0, 1};
    D3D12_RECT sc = {0, 0, (LONG)kRT, (LONG)kRT};
    for (float k : ks)
        for (UINT s = 0; s < 7; s++)
            for (int op = 0; op < 4; op++) {
                ID3D12DescriptorHeap *heaps[1] = {srv_heap};
                gpu.list->SetDescriptorHeaps(1, heaps);
                gpu.list->SetGraphicsRootSignature(root);
                gpu.list->SetPipelineState(pso);
                UINT c[4] = {s, op_codes[op], 0, 0};
                memcpy(&c[2], &k, 4); memcpy(&c[3], &args[op], 4);
                gpu.list->SetGraphicsRoot32BitConstants(0, 4, c, 0);
                gpu.list->SetGraphicsRootDescriptorTable(1, srv_heap->GetGPUDescriptorHandleForHeapStart());
                float black[4] = {0, 0, 0, 0};
                gpu.list->ClearRenderTargetView(rtv, black, 0, nullptr);
                gpu.list->OMSetRenderTargets(1, &rtv, FALSE, nullptr);
                gpu.list->RSSetViewports(1, &vp);
                gpu.list->RSSetScissorRects(1, &sc);
                gpu.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
                gpu.list->DrawInstanced(3, 1, 0, 0);
                gpu.Barrier(target, RT, COPY_SOURCE);
                D3D12_TEXTURE_COPY_LOCATION src = {target, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX};
                D3D12_TEXTURE_COPY_LOCATION dst = {rb, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT};
                dst.PlacedFootprint.Footprint = {DXGI_FORMAT_R8G8B8A8_UNORM, kRT, kRT, 1, 256};
                gpu.list->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
                gpu.Barrier(target, COPY_SOURCE, RT);
                gpu.Submit();
                uint8_t *px; D3D12_RANGE all = {0, 256 * kRT}; CHECK(rb->Map(0, &all, (void **)&px));
                double sum = 0; int n = 0;  // a 2-pixel border left out (helper lanes at the edge)
                for (UINT y = 2; y < kRT - 2; y++)
                    for (UINT x = 2; x < kRT - 2; x++) { sum += px[256 * y + 4 * x]; n++; }
                D3D12_RANGE none = {0, 0}; rb->Unmap(0, &none);
                printf("lod k=%g s%u %s %.2f\n", k, s, ops[op], sum / n / 32);
            }
    printf("lod done\n");
    return 0;
}
