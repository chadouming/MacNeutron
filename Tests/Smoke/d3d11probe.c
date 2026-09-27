/* Creates a D3D11 device and swap chain on a small window; exits 0 on success. */
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>

int main(void) {
    WNDCLASSA wc = {0};
    wc.lpfnWndProc = DefWindowProcA;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "d3d11probe";
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA("d3d11probe", "d3d11probe", WS_OVERLAPPEDWINDOW, 0, 0, 64, 64,
                              NULL, NULL, wc.hInstance, NULL);

    DXGI_SWAP_CHAIN_DESC sd = {0};
    sd.BufferCount = 1;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    IDXGISwapChain *swap = NULL;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    D3D_FEATURE_LEVEL level = 0;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                               D3D11_SDK_VERSION, &sd, &swap, &device, &level, &context);
    printf("D3D11CreateDeviceAndSwapChain: hr=0x%08lx feature_level=0x%x\n", (unsigned long)hr, (unsigned)level);
    return FAILED(hr) ? 1 : 0;
}
