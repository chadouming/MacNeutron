/* Test program for presenter/check.sh: presents a checkerboard from a D3D11 swap chain and reports the
 * average frame time.
 *   present_loop.exe <client_w> <client_h> <swap_w|0> <swap_h|0> <frames> <vsync 0|1> [resize=F:WxH] [grow=F] [fp16]
 * Swap size 0 means the window's client size. resize= resizes the window at frame F; grow= resizes the swap chain
 * to the window at frame F; fp16 uses a float swap chain, which D3DMetal shows through an extended-range layer. */
#include <windows.h>
#include <d3d11_1.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static LRESULT CALLBACK proc(HWND h, UINT m, WPARAM w, LPARAM l) { return DefWindowProcA(h, m, w, l); }

static void target(IDXGISwapChain *swap, ID3D11Device *dev, ID3D11RenderTargetView **rtv, DXGI_SWAP_CHAIN_DESC *sd)
{
    ID3D11Texture2D *back = NULL;
    swap->lpVtbl->GetBuffer(swap, 0, &IID_ID3D11Texture2D, (void **)&back);
    dev->lpVtbl->CreateRenderTargetView(dev, (ID3D11Resource *)back, NULL, rtv);
    back->lpVtbl->Release(back);
    swap->lpVtbl->GetDesc(swap, sd);
}

int main(int argc, char **argv)
{
    int cw = atoi(argv[1]), ch = atoi(argv[2]), sw = atoi(argv[3]), sh = atoi(argv[4]);
    int frames = atoi(argv[5]), vsync = atoi(argv[6]), resize_at = -1, rw = 0, rh = 0, grow_at = -1, fp16 = 0;
    for (int i = 7; i < argc; i++) {
        if (!strncmp(argv[i], "resize=", 7)) sscanf(argv[i] + 7, "%d:%dx%d", &resize_at, &rw, &rh);
        else if (!strncmp(argv[i], "grow=", 5)) grow_at = atoi(argv[i] + 5);
        else if (!strcmp(argv[i], "fp16")) fp16 = 1;
    }
    WNDCLASSA wc = {0};
    RECT r = {0, 0, cw, ch};
    wc.lpfnWndProc = proc; wc.hInstance = GetModuleHandleA(NULL); wc.lpszClassName = "present_loop";
    RegisterClassA(&wc);
    AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, FALSE);
    HWND hwnd = CreateWindowA("present_loop", "present_loop", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 40, 40,
                              r.right - r.left, r.bottom - r.top, NULL, NULL, wc.hInstance, NULL);

    DXGI_SWAP_CHAIN_DESC sd = {0};
    sd.BufferCount = 2;
    sd.BufferDesc.Width = sw; sd.BufferDesc.Height = sh;
    sd.BufferDesc.Format = fp16 ? DXGI_FORMAT_R16G16B16A16_FLOAT : DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd; sd.SampleDesc.Count = 1; sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    IDXGISwapChain *swap = NULL; ID3D11Device *dev = NULL; ID3D11DeviceContext *ctx = NULL; ID3D11DeviceContext1 *ctx1 = NULL;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                               D3D11_SDK_VERSION, &sd, &swap, &dev, NULL, &ctx);
    if (FAILED(hr)) { printf("create failed 0x%08lx\n", (unsigned long)hr); return 1; }
    ctx->lpVtbl->QueryInterface(ctx, &IID_ID3D11DeviceContext1, (void **)&ctx1);
    ID3D11RenderTargetView *rtv = NULL;
    target(swap, dev, &rtv, &sd);
    printf("window client %dx%d, swap chain %ux%u\n", cw, ch, sd.BufferDesc.Width, sd.BufferDesc.Height);

    static D3D11_RECT rects[2048];
    LARGE_INTEGER f, t0, t1; QueryPerformanceFrequency(&f); QueryPerformanceCounter(&t0);
    for (int i = 0; i < frames; i++) {
        MSG msg; while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageA(&msg);
        if (i == resize_at) {
            RECT nr = {0, 0, rw, rh};
            AdjustWindowRect(&nr, WS_OVERLAPPEDWINDOW, FALSE);
            SetWindowPos(hwnd, NULL, 0, 0, nr.right - nr.left, nr.bottom - nr.top, SWP_NOMOVE | SWP_NOZORDER);
        }
        if (i == grow_at) {
            rtv->lpVtbl->Release(rtv); rtv = NULL;
            swap->lpVtbl->ResizeBuffers(swap, 0, 0, 0, DXGI_FORMAT_UNKNOWN, 0);
            target(swap, dev, &rtv, &sd);
        }
        /* The background never has all channels above 200; the 16px squares on a 32px pitch are white. */
        float bg[4] = { (i % 60) / 60.0f, 0.3f, 1.0f - (i % 120) / 120.0f, 1.0f }, white[4] = {1, 1, 1, 1};
        int n = 0;
        ctx->lpVtbl->OMSetRenderTargets(ctx, 1, &rtv, NULL);
        ctx->lpVtbl->ClearRenderTargetView(ctx, rtv, bg);
        for (int y = 0; y < (int)sd.BufferDesc.Height && n < 2040; y += 32)
            for (int x = (y / 32 % 2) * 16; x < (int)sd.BufferDesc.Width && n < 2040; x += 32)
                rects[n++] = (D3D11_RECT){x, y, x + 16, y + 16};
        if (ctx1) ctx1->lpVtbl->ClearView(ctx1, (ID3D11View *)rtv, white, rects, n);
        swap->lpVtbl->Present(swap, vsync, 0);
    }
    QueryPerformanceCounter(&t1);
    printf("frames %d, avg frame %.3f ms\n", frames, (t1.QuadPart - t0.QuadPart) * 1000.0 / f.QuadPart / frames);
    return 0;
}
