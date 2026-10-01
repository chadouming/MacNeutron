// Layered rendering into a 3D texture (Unreal's translucency lighting volume), drawn offscreen through D3D12:
//   d3d12_layered.exe <vs.dxil> <ps.dxil>   (shaders/layered.hlsl)
// An 8x8x4 R8G8B8A8_UNORM Texture3D, cleared to (0,0,0,0) through an RTV of all 4 W-slices, then 4 instances of a
// full-screen triangle, each routed by its vertex shader's SV_RenderTargetArrayIndex to slice `instance`.
// Prints "layered ok <texel (4,4) of slices 0..3>" (hex, RGBA bytes). check.sh compares with D3DMetal.
#include "d3d12_common.hpp"

int main(int argc, char **argv) {
    if (argc != 3) { printf("usage: d3d12_layered.exe <vs.dxil> <ps.dxil>\n"); return 2; }
    std::vector<char> vs = Load(argv[1]), ps = Load(argv[2]);
    if (vs.empty() || ps.empty()) { printf("can't read the shaders\n"); return 1; }
    const UINT size = 8, slices = 4;
    Gpu gpu;
    D3D12_ROOT_SIGNATURE_DESC rd = {};
    ID3D12RootSignature *root = gpu.RootSignature(rd);
    D3D12_GRAPHICS_PIPELINE_STATE_DESC gd = {};
    gd.pRootSignature = root;
    gd.VS = {vs.data(), vs.size()};
    gd.PS = {ps.data(), ps.size()};
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

    D3D12_RESOURCE_DESC td = {};
    td.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE3D; td.Width = size; td.Height = size; td.DepthOrArraySize = slices;
    td.MipLevels = 1; td.Format = DXGI_FORMAT_R8G8B8A8_UNORM; td.SampleDesc.Count = 1;
    td.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    ID3D12Resource *volume = gpu.Texture(td, D3D12_RESOURCE_STATE_RENDER_TARGET);
    ID3D12DescriptorHeap *rtv_heap;
    D3D12_DESCRIPTOR_HEAP_DESC hd = {D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 1};
    CHECK(gpu.device->CreateDescriptorHeap(&hd, __uuidof(ID3D12DescriptorHeap), (void **)&rtv_heap));
    D3D12_CPU_DESCRIPTOR_HANDLE rtv = rtv_heap->GetCPUDescriptorHandleForHeapStart();
    D3D12_RENDER_TARGET_VIEW_DESC rv = {};
    rv.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    rv.ViewDimension = D3D12_RTV_DIMENSION_TEXTURE3D;
    rv.Texture3D.MipSlice = 0; rv.Texture3D.FirstWSlice = 0; rv.Texture3D.WSize = slices;
    gpu.device->CreateRenderTargetView(volume, &rv, rtv);
    const UINT pitch = 256;
    ID3D12Resource *readback = gpu.Buffer(D3D12_HEAP_TYPE_READBACK, pitch * size * slices, D3D12_RESOURCE_STATE_COPY_DEST);

    ID3D12GraphicsCommandList *list = gpu.list;
    const float clear[4] = {0, 0, 0, 0};
    D3D12_VIEWPORT viewport = {0, 0, (float)size, (float)size, 0, 1};
    D3D12_RECT scissor = {0, 0, (LONG)size, (LONG)size};
    list->ClearRenderTargetView(rtv, clear, 0, nullptr);
    list->OMSetRenderTargets(1, &rtv, FALSE, nullptr);
    list->RSSetViewports(1, &viewport);
    list->RSSetScissorRects(1, &scissor);
    list->SetGraphicsRootSignature(root);
    list->SetPipelineState(pso);
    list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    list->DrawInstanced(3, slices, 0, 0);
    gpu.Barrier(volume, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION from = {volume, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}; from.SubresourceIndex = 0;
    D3D12_TEXTURE_COPY_LOCATION to = {readback, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT};
    to.PlacedFootprint.Footprint = {DXGI_FORMAT_R8G8B8A8_UNORM, size, size, slices, pitch};
    list->CopyTextureRegion(&to, 0, 0, 0, &from, nullptr);
    gpu.Submit();

    uint8_t *px; D3D12_RANGE whole = {0, pitch * size * slices}, none = {0, 0};
    CHECK(readback->Map(0, &whole, (void **)&px));
    printf("layered ok");
    for (UINT s = 0; s < slices; s++) {
        uint32_t texel; memcpy(&texel, px + (s * size + 4) * pitch + 4 * 4, 4);
        printf(" %08x", texel);
    }
    printf("\n");
    readback->Unmap(0, &none);
    return 0;
}
