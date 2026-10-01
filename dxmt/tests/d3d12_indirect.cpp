// Many indirect draws in one render pass, as Unreal draws grass and GPU particles:
//   d3d12_indirect.exe <vs.dxil> <ps.dxil> <cs.dxil>   (shaders/indirect.hlsl)
// Each frame clears a 64x64 target and paints its 1024 cells with one ExecuteIndirect each (one draw command, its
// StartInstanceLocation picks the cell from a per-instance vertex stream, as Unreal's instance ids), then runs 1024
// indirect dispatches of 1 to 4 groups whose threads count themselves (as Niagara's GPU simulation). Prints "indirect ok <frames> <cells left unpainted over all frames>" and
// "indirect dispatch <threads counted> <threads dispatched>".
#include "d3d12_common.hpp"

int main(int argc, char **argv) {
    if (argc != 4) { printf("usage: d3d12_indirect.exe <vs.dxil> <ps.dxil> <cs.dxil>\n"); return 2; }
    std::vector<char> vs = Load(argv[1]), ps = Load(argv[2]), cs = Load(argv[3]);
    if (vs.empty() || ps.empty() || cs.empty()) { printf("can't read the shaders\n"); return 1; }
    const UINT cells = 1024, frames = 8, size = 64, pitch = size * 4;
    Gpu gpu;
    D3D12_ROOT_SIGNATURE_DESC rd = {0, nullptr, 0, nullptr, D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT};
    ID3D12RootSignature *root = gpu.RootSignature(rd);
    D3D12_INPUT_ELEMENT_DESC cell = {"CELL", 0, DXGI_FORMAT_R32_UINT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA, 1};
    D3D12_GRAPHICS_PIPELINE_STATE_DESC gd = {};
    gd.pRootSignature = root;
    gd.VS = {vs.data(), vs.size()};
    gd.PS = {ps.data(), ps.size()};
    gd.InputLayout = {&cell, 1};
    gd.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    gd.SampleMask = UINT_MAX;
    gd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    gd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    gd.RasterizerState.DepthClipEnable = TRUE;
    gd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    gd.NumRenderTargets = 1;
    gd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
    gd.SampleDesc.Count = 1;
    ID3D12PipelineState *pso;
    CHECK(gpu.device->CreateGraphicsPipelineState(&gd, __uuidof(ID3D12PipelineState), (void **)&pso));
    D3D12_INDIRECT_ARGUMENT_DESC arg = {D3D12_INDIRECT_ARGUMENT_TYPE_DRAW};
    D3D12_COMMAND_SIGNATURE_DESC sd = {sizeof(D3D12_DRAW_ARGUMENTS), 1, &arg, 0};
    ID3D12CommandSignature *sig;
    CHECK(gpu.device->CreateCommandSignature(&sd, nullptr, __uuidof(ID3D12CommandSignature), (void **)&sig));

    ID3D12Resource *args = gpu.Buffer(D3D12_HEAP_TYPE_UPLOAD, cells * sizeof(D3D12_DRAW_ARGUMENTS),
                                      D3D12_RESOURCE_STATE_GENERIC_READ);
    D3D12_DRAW_ARGUMENTS *a; D3D12_RANGE none = {0, 0};
    CHECK(args->Map(0, &none, (void **)&a));
    for (UINT i = 0; i < cells; i++) a[i] = {6, 1, 0, i};
    args->Unmap(0, nullptr);
    ID3D12Resource *ids = gpu.Buffer(D3D12_HEAP_TYPE_UPLOAD, cells * 4, D3D12_RESOURCE_STATE_GENERIC_READ);
    UINT *id;
    CHECK(ids->Map(0, &none, (void **)&id));
    for (UINT i = 0; i < cells; i++) id[i] = i;
    ids->Unmap(0, nullptr);
    D3D12_VERTEX_BUFFER_VIEW vbv = {ids->GetGPUVirtualAddress(), cells * 4, 4};

    ID3D12Resource *target = gpu.Texture(Tex2D(size, size, DXGI_FORMAT_R8G8B8A8_UNORM, 1, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET),
                                         D3D12_RESOURCE_STATE_RENDER_TARGET);
    ID3D12DescriptorHeap *rtv_heap;
    D3D12_DESCRIPTOR_HEAP_DESC rhd = {D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 1};
    CHECK(gpu.device->CreateDescriptorHeap(&rhd, __uuidof(ID3D12DescriptorHeap), (void **)&rtv_heap));
    D3D12_CPU_DESCRIPTOR_HANDLE rtv = rtv_heap->GetCPUDescriptorHandleForHeapStart();
    gpu.device->CreateRenderTargetView(target, nullptr, rtv);
    ID3D12Resource *readback = gpu.Buffer(D3D12_HEAP_TYPE_READBACK, frames * size * pitch + 4, D3D12_RESOURCE_STATE_COPY_DEST);

    D3D12_ROOT_PARAMETER uav = {};
    uav.ParameterType = D3D12_ROOT_PARAMETER_TYPE_UAV;
    D3D12_ROOT_SIGNATURE_DESC crd = {1, &uav, 0, nullptr, D3D12_ROOT_SIGNATURE_FLAG_NONE};
    ID3D12RootSignature *croot = gpu.RootSignature(crd);
    D3D12_COMPUTE_PIPELINE_STATE_DESC cd = {croot, {cs.data(), cs.size()}};
    ID3D12PipelineState *cpso;
    CHECK(gpu.device->CreateComputePipelineState(&cd, __uuidof(ID3D12PipelineState), (void **)&cpso));
    D3D12_INDIRECT_ARGUMENT_DESC darg = {D3D12_INDIRECT_ARGUMENT_TYPE_DISPATCH};
    D3D12_COMMAND_SIGNATURE_DESC dsd = {sizeof(D3D12_DISPATCH_ARGUMENTS), 1, &darg, 0};
    ID3D12CommandSignature *dsig;
    CHECK(gpu.device->CreateCommandSignature(&dsd, nullptr, __uuidof(ID3D12CommandSignature), (void **)&dsig));
    ID3D12Resource *dargs = gpu.Buffer(D3D12_HEAP_TYPE_UPLOAD, cells * sizeof(D3D12_DISPATCH_ARGUMENTS) + 4,
                                       D3D12_RESOURCE_STATE_GENERIC_READ);
    D3D12_DISPATCH_ARGUMENTS *d;
    UINT threads = 0;
    CHECK(dargs->Map(0, &none, (void **)&d));
    for (UINT i = 0; i < cells; i++) { d[i] = {i % 4 + 1, 1, 1}; threads += (i % 4 + 1) * 4; }
    memset(d + cells, 0, 4);  // the counter's starting value
    dargs->Unmap(0, nullptr);
    ID3D12Resource *counter = gpu.Buffer(D3D12_HEAP_TYPE_DEFAULT, 4, D3D12_RESOURCE_STATE_COPY_DEST,
                                         D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    gpu.list->CopyBufferRegion(counter, 0, dargs, cells * sizeof(D3D12_DISPATCH_ARGUMENTS), 4);
    gpu.Barrier(counter, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);

    D3D12_VIEWPORT viewport = {0, 0, (float)size, (float)size, 0, 1};
    D3D12_RECT scissor = {0, 0, (LONG)size, (LONG)size};
    const float black[4] = {0, 0, 0, 0};
    for (UINT f = 0; f < frames; f++) {
        ID3D12GraphicsCommandList *list = gpu.list;
        list->ClearRenderTargetView(rtv, black, 0, nullptr);
        list->OMSetRenderTargets(1, &rtv, FALSE, nullptr);
        list->RSSetViewports(1, &viewport);
        list->RSSetScissorRects(1, &scissor);
        list->SetGraphicsRootSignature(root);
        list->SetPipelineState(pso);
        list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        list->IASetVertexBuffers(0, 1, &vbv);
        for (UINT i = 0; i < cells; i++)
            list->ExecuteIndirect(sig, 1, args, i * sizeof(D3D12_DRAW_ARGUMENTS), nullptr, 0);
        gpu.Barrier(target, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_SOURCE);
        D3D12_TEXTURE_COPY_LOCATION src = {target, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}; src.SubresourceIndex = 0;
        D3D12_TEXTURE_COPY_LOCATION dst = {readback, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT};
        dst.PlacedFootprint = {(UINT64)f * size * pitch, {DXGI_FORMAT_R8G8B8A8_UNORM, size, size, 1, pitch}};
        list->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
        gpu.Barrier(target, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET);
        list->SetComputeRootSignature(croot);
        list->SetPipelineState(cpso);
        list->SetComputeRootUnorderedAccessView(0, counter->GetGPUVirtualAddress());
        for (UINT i = 0; i < cells; i++)
            list->ExecuteIndirect(dsig, 1, dargs, i * sizeof(D3D12_DISPATCH_ARGUMENTS), nullptr, 0);
        gpu.Submit();
    }
    gpu.Barrier(counter, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
    gpu.list->CopyBufferRegion(readback, frames * size * pitch, counter, 0, 4);
    gpu.Submit();
    uint8_t *r; D3D12_RANGE whole = {0, (SIZE_T)frames * size * pitch + 4};
    CHECK(readback->Map(0, &whole, (void **)&r));
    UINT missing = 0;
    for (UINT f = 0; f < frames; f++)
        for (UINT c = 0; c < cells; c++) {
            UINT x = c % 32 * 2, y = c / 32 * 2;
            bool painted = true;
            for (UINT dy = 0; dy < 2; dy++)
                for (UINT dx = 0; dx < 2; dx++)
                    painted &= r[f * size * pitch + (y + dy) * pitch + (x + dx) * 4] == 255;
            missing += !painted;
        }
    UINT counted;
    memcpy(&counted, r + frames * size * pitch, 4);
    readback->Unmap(0, &none);
    printf("indirect ok %u %u\n", frames, missing);
    printf("indirect dispatch %u %u\n", counted, threads * frames);
    return 0;
}
