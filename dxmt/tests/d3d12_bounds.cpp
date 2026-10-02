// GPU efficiency spec E5: raw and structured buffer loads through descriptor-table views, in bounds, straddling a
// view's end, and out of it (shaders/bounds.hlsl). The memory past each view holds nonzero data, so a load that isn't
// bounds-checked reads it. Prints "bounds <32 dwords>"; check.sh compares them with D3DMetal's.
//   d3d12_bounds.exe <bounds.cs.dxil>
#include "d3d12_common.hpp"

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: d3d12_bounds.exe <bounds.cs.dxil>\n"); return 2; }
    auto cs = Load(argv[1]);
    if (cs.empty()) { printf("bounds fail: no shader\n"); return 1; }
    Gpu gpu;
    D3D12_DESCRIPTOR_RANGE ranges[2] = {{D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 2, 0, 0, 0},
                                        {D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 1, 0, 0, 2}};
    D3D12_ROOT_PARAMETER param = {};
    param.ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    param.DescriptorTable = {2, ranges};
    D3D12_ROOT_SIGNATURE_DESC rd = {1, &param, 0, nullptr, D3D12_ROOT_SIGNATURE_FLAG_NONE};
    auto root = gpu.RootSignature(rd);
    D3D12_COMPUTE_PIPELINE_STATE_DESC cd = {root, {cs.data(), cs.size()}};
    ID3D12PipelineState *pso;
    CHECK(gpu.device->CreateComputePipelineState(&cd, __uuidof(ID3D12PipelineState), (void **)&pso));

    // Source: 32 dwords holding 1..32; a default-heap copy of it; the result (32 dwords) and its readback.
    auto upload = gpu.Buffer(D3D12_HEAP_TYPE_UPLOAD, 128, D3D12_RESOURCE_STATE_GENERIC_READ);
    uint32_t *u;
    CHECK(upload->Map(0, nullptr, (void **)&u));
    for (int i = 0; i < 32; i++)
        u[i] = i + 1;
    upload->Unmap(0, nullptr);
    auto source = gpu.Buffer(D3D12_HEAP_TYPE_DEFAULT, 128, D3D12_RESOURCE_STATE_COPY_DEST);
    auto result = gpu.Buffer(D3D12_HEAP_TYPE_DEFAULT, 128, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                             D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    auto readback = gpu.Buffer(D3D12_HEAP_TYPE_READBACK, 128, D3D12_RESOURCE_STATE_COPY_DEST);
    gpu.list->CopyBufferRegion(source, 0, upload, 0, 128);
    gpu.Barrier(source, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);

    ID3D12DescriptorHeap *heap;
    D3D12_DESCRIPTOR_HEAP_DESC hd = {D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 3, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE};
    CHECK(gpu.device->CreateDescriptorHeap(&hd, __uuidof(ID3D12DescriptorHeap), (void **)&heap));
    UINT step = gpu.device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    auto at = [&](UINT i) { auto h = heap->GetCPUDescriptorHandleForHeapStart(); h.ptr += i * step; return h; };
    D3D12_SHADER_RESOURCE_VIEW_DESC raw = {DXGI_FORMAT_R32_TYPELESS, D3D12_SRV_DIMENSION_BUFFER,
                                           D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING};
    raw.Buffer = {4, 16, 0, D3D12_BUFFER_SRV_FLAG_RAW}; // dwords 4..19: 1..4 before it, 21.. after
    gpu.device->CreateShaderResourceView(source, &raw, at(0));
    D3D12_SHADER_RESOURCE_VIEW_DESC structured = {DXGI_FORMAT_UNKNOWN, D3D12_SRV_DIMENSION_BUFFER,
                                                  D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING};
    structured.Buffer = {0, 4, 16, D3D12_BUFFER_SRV_FLAG_NONE};
    gpu.device->CreateShaderResourceView(source, &structured, at(1));
    D3D12_UNORDERED_ACCESS_VIEW_DESC uav = {DXGI_FORMAT_R32_TYPELESS, D3D12_UAV_DIMENSION_BUFFER};
    uav.Buffer = {0, 32, 0, 0, D3D12_BUFFER_UAV_FLAG_RAW};
    gpu.device->CreateUnorderedAccessView(result, nullptr, &uav, at(2));

    gpu.list->SetDescriptorHeaps(1, &heap);
    gpu.list->SetComputeRootSignature(root);
    gpu.list->SetPipelineState(pso);
    gpu.list->SetComputeRootDescriptorTable(0, heap->GetGPUDescriptorHandleForHeapStart());
    gpu.list->Dispatch(1, 1, 1);
    gpu.Barrier(result, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
    gpu.list->CopyBufferRegion(readback, 0, result, 0, 128);
    gpu.Submit();
    uint32_t *r;
    D3D12_RANGE whole = {0, 128}, none = {0, 0};
    CHECK(readback->Map(0, &whole, (void **)&r));
    printf("bounds");
    for (int i = 0; i < 32; i++)
        printf(" %u", r[i]);
    printf("\n");
    readback->Unmap(0, &none);
    return 0;
}
