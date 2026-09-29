// Creates a graphics and a compute pipeline from DXIL shaders (DXMT fork spec §6):
//   d3d12_dxil.exe <vs.dxil> <ps.dxil> <cs.dxil>
// Prints each HRESULT. DXMT returns E_NOTIMPL (0x80004001) until it can translate DXIL.
#define WIDL_EXPLICIT_AGGREGATE_RETURNS
#include <windows.h>
#include <d3d12.h>
#include <climits>
#include <cstdio>
#include <vector>

static std::vector<char> load(const char *path) {
    std::vector<char> data;
    if (FILE *f = fopen(path, "rb")) {
        char buffer[4096]; size_t n;
        while ((n = fread(buffer, 1, sizeof buffer, f)) > 0) data.insert(data.end(), buffer, buffer + n);
        fclose(f);
    }
    return data;
}

int main(int argc, char **argv) {
    if (argc != 4) { printf("usage: d3d12_dxil.exe <vs.dxil> <ps.dxil> <cs.dxil>\n"); return 2; }
    std::vector<char> vs = load(argv[1]), ps = load(argv[2]), cs = load(argv[3]);
    if (vs.empty() || ps.empty() || cs.empty()) { printf("can't read the shaders\n"); return 1; }

    ID3D12Device *device;
    HRESULT hr = D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device), (void **)&device);
    if (FAILED(hr)) { printf("D3D12CreateDevice hr=0x%08lx\n", (unsigned long)hr); return 1; }
    // One root UAV at u0, which compute.hlsl writes; the triangle binds nothing.
    D3D12_ROOT_PARAMETER uav = {};
    uav.ParameterType = D3D12_ROOT_PARAMETER_TYPE_UAV;
    uav.Descriptor.ShaderRegister = 0;
    uav.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    D3D12_ROOT_SIGNATURE_DESC rd = {};
    rd.NumParameters = 1;
    rd.pParameters = &uav;
    rd.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
    ID3DBlob *blob = nullptr, *error = nullptr;
    hr = D3D12SerializeRootSignature(&rd, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &error);
    if (FAILED(hr)) { printf("D3D12SerializeRootSignature hr=0x%08lx\n", (unsigned long)hr); return 1; }
    ID3D12RootSignature *root;
    hr = device->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(),
                                     __uuidof(ID3D12RootSignature), (void **)&root);
    if (FAILED(hr)) { printf("CreateRootSignature hr=0x%08lx\n", (unsigned long)hr); return 1; }

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
    ID3D12PipelineState *pso = nullptr;
    hr = device->CreateGraphicsPipelineState(&gd, __uuidof(ID3D12PipelineState), (void **)&pso);
    printf("graphics hr=0x%08lx\n", (unsigned long)hr);

    D3D12_COMPUTE_PIPELINE_STATE_DESC cd = {};
    cd.pRootSignature = root;
    cd.CS = {cs.data(), cs.size()};
    hr = device->CreateComputePipelineState(&cd, __uuidof(ID3D12PipelineState), (void **)&pso);
    printf("compute hr=0x%08lx\n", (unsigned long)hr);
    return 0;
}
