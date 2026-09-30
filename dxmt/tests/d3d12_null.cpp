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
