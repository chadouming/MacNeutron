// A 3D texture written through a RWTexture3D UAV by one dispatch, then read by another through an SRV (SampleLevel
// and Load), as Unreal's volumetric fog and translucency do (shaders/volume.hlsl):
//   d3d12_volume.exe <fill.dxil> <sample.dxil>
// An 8x8x4 R16G16B16A16_FLOAT volume; prints "volume ok <4 x (sampled rgba, loaded rgba), as float bits>" and
// "volume texels <texels (0,0,0) (7,7,3) (3,5,2) read back by a copy>". check.sh compares with D3DMetal.
#include "d3d12_common.hpp"

int main(int argc, char **argv) {
    if (argc != 3) { printf("usage: d3d12_volume.exe <fill.dxil> <sample.dxil>\n"); return 2; }
    std::vector<char> fill = Load(argv[1]), sample = Load(argv[2]);
    if (fill.empty() || sample.empty()) { printf("can't read the shaders\n"); return 1; }
    Gpu gpu;
    // Root: a table of u0 (the volume) and u1 (the output), a table of t0; a static linear clamp sampler.
    D3D12_DESCRIPTOR_RANGE uavs = {D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 2, 0, 0, 0};
    D3D12_DESCRIPTOR_RANGE srv = {D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 1, 0, 0, 0};
    D3D12_ROOT_PARAMETER params[2] = {};
    params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE; params[0].DescriptorTable = {1, &uavs};
    params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE; params[1].DescriptorTable = {1, &srv};
    D3D12_STATIC_SAMPLER_DESC sampler = {};
    sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
    sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    sampler.MaxLOD = D3D12_FLOAT32_MAX;
    D3D12_ROOT_SIGNATURE_DESC rd = {2, params, 1, &sampler, D3D12_ROOT_SIGNATURE_FLAG_NONE};
    ID3D12RootSignature *root = gpu.RootSignature(rd);
    ID3D12PipelineState *fill_pso, *sample_pso;
    D3D12_COMPUTE_PIPELINE_STATE_DESC cd = {root, {fill.data(), fill.size()}};
    CHECK(gpu.device->CreateComputePipelineState(&cd, __uuidof(ID3D12PipelineState), (void **)&fill_pso));
    cd.CS = {sample.data(), sample.size()};
    CHECK(gpu.device->CreateComputePipelineState(&cd, __uuidof(ID3D12PipelineState), (void **)&sample_pso));

    D3D12_RESOURCE_DESC td = {};
    td.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE3D; td.Width = 8; td.Height = 8; td.DepthOrArraySize = 4;
    td.MipLevels = 1; td.Format = DXGI_FORMAT_R16G16B16A16_FLOAT; td.SampleDesc.Count = 1;
    td.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    ID3D12Resource *volume = gpu.Texture(td, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    ID3D12Resource *out = gpu.Buffer(D3D12_HEAP_TYPE_DEFAULT, 128, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                                     D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    ID3D12Resource *results = gpu.Buffer(D3D12_HEAP_TYPE_READBACK, 128, D3D12_RESOURCE_STATE_COPY_DEST);
    ID3D12Resource *texels = gpu.Buffer(D3D12_HEAP_TYPE_READBACK, 256 * 8 * 4, D3D12_RESOURCE_STATE_COPY_DEST);

    ID3D12DescriptorHeap *heap;
    D3D12_DESCRIPTOR_HEAP_DESC hd = {D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 3, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE};
    CHECK(gpu.device->CreateDescriptorHeap(&hd, __uuidof(ID3D12DescriptorHeap), (void **)&heap));
    UINT step = gpu.device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    auto cpu = [&](UINT i) { auto h = heap->GetCPUDescriptorHandleForHeapStart(); h.ptr += i * step; return h; };
    auto gpu_handle = [&](UINT i) { auto h = heap->GetGPUDescriptorHandleForHeapStart(); h.ptr += i * step; return h; };
    D3D12_UNORDERED_ACCESS_VIEW_DESC uv = {};
    uv.Format = DXGI_FORMAT_R16G16B16A16_FLOAT; uv.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE3D;
    uv.Texture3D.MipSlice = 0; uv.Texture3D.FirstWSlice = 0; uv.Texture3D.WSize = 4;
    gpu.device->CreateUnorderedAccessView(volume, nullptr, &uv, cpu(0));
    D3D12_UNORDERED_ACCESS_VIEW_DESC ov = {};
    ov.Format = DXGI_FORMAT_R32_TYPELESS; ov.ViewDimension = D3D12_UAV_DIMENSION_BUFFER;
    ov.Buffer.NumElements = 32; ov.Buffer.Flags = D3D12_BUFFER_UAV_FLAG_RAW;
    gpu.device->CreateUnorderedAccessView(out, nullptr, &ov, cpu(1));
    D3D12_SHADER_RESOURCE_VIEW_DESC sv = {};
    sv.Format = DXGI_FORMAT_R16G16B16A16_FLOAT; sv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE3D;
    sv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING; sv.Texture3D.MipLevels = 1;
    gpu.device->CreateShaderResourceView(volume, &sv, cpu(2));

    ID3D12GraphicsCommandList *list = gpu.list;
    list->SetDescriptorHeaps(1, &heap);
    list->SetComputeRootSignature(root);
    list->SetComputeRootDescriptorTable(0, gpu_handle(0));
    list->SetComputeRootDescriptorTable(1, gpu_handle(2));
    list->SetPipelineState(fill_pso);
    list->Dispatch(2, 2, 1);
    gpu.Barrier(volume, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    list->SetPipelineState(sample_pso);
    list->Dispatch(1, 1, 1);
    gpu.Barrier(out, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
    list->CopyBufferRegion(results, 0, out, 0, 128);
    gpu.Barrier(volume, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION from = {volume, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}; from.SubresourceIndex = 0;
    D3D12_TEXTURE_COPY_LOCATION to = {texels, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT};
    to.PlacedFootprint.Footprint = {DXGI_FORMAT_R16G16B16A16_FLOAT, 8, 8, 4, 256};
    list->CopyTextureRegion(&to, 0, 0, 0, &from, nullptr);
    gpu.Submit();

    uint32_t *r; uint8_t *t; D3D12_RANGE all = {0, 128}, whole = {0, 256 * 8 * 4}, none = {0, 0};
    CHECK(results->Map(0, &all, (void **)&r));
    printf("volume ok");
    for (int i = 0; i < 32; i++) printf(" %08x", r[i]);
    printf("\n");
    results->Unmap(0, &none);
    CHECK(texels->Map(0, &whole, (void **)&t));
    printf("volume texels");
    const int at[3][3] = {{0, 0, 0}, {7, 7, 3}, {3, 5, 2}};
    for (auto &p : at) { uint64_t v; memcpy(&v, t + (p[2] * 8 + p[1]) * 256 + p[0] * 8, 8); printf(" %016llx", (unsigned long long)v); }
    printf("\n");
    texels->Unmap(0, &none);
    return 0;
}
