// Creates AMD's FSR 3 frame-generation swapchain proxy as Unreal's FSR3 plugin does (ffxCreateContext with a
// FRAMEGENERATIONSWAPCHAIN_FOR_HWND_DX12 description), then clears and presents through it (DXIL translator plan,
// Task 7: SMITE 2 creates its swapchain this way, even with frame generation off).
//   d3d12_ffx_swapchain.exe <amd_fidelityfx_dx12.dll from a game's install> [frames]
// Prints "ffxCreateContext rc=<code> ..." and "presented <n>/<frames> through the FSR 3 proxy". The DLL is the game's,
// read where it's installed; it is never copied.
#define WIDL_EXPLICIT_AGGREGATE_RETURNS
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <cstdio>
#include <cstdlib>
#include <cstdint>

struct ffxApiHeader { uint64_t type; ffxApiHeader *pNext; };
struct SwapChainForHwndDesc {
    ffxApiHeader header; IDXGISwapChain4 **swapchain; HWND hwnd; DXGI_SWAP_CHAIN_DESC1 *desc;
    DXGI_SWAP_CHAIN_FULLSCREEN_DESC *fullscreenDesc; IDXGIFactory *dxgiFactory; ID3D12CommandQueue *gameQueue;
};
typedef uint32_t (*PfnCreate)(void **context, ffxApiHeader *desc, const void *memCb);

static LRESULT CALLBACK proc(HWND h, UINT m, WPARAM w, LPARAM l) { return DefWindowProcA(h, m, w, l); }

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: d3d12_ffx_swapchain.exe <amd_fidelityfx_dx12.dll> [frames]\n"); return 2; }
    int frames = argc > 2 ? atoi(argv[2]) : 120;
    WNDCLASSA wc = {}; wc.lpfnWndProc = proc; wc.hInstance = GetModuleHandleA(nullptr); wc.lpszClassName = "d3d12_ffx_swapchain";
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA("d3d12_ffx_swapchain", "d3d12_ffx_swapchain", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 40, 40, 800, 600, nullptr, nullptr, wc.hInstance, nullptr);
    IDXGIFactory4 *factory; ID3D12Device *device; ID3D12CommandQueue *queue;
    if (FAILED(CreateDXGIFactory2(0, __uuidof(IDXGIFactory4), (void **)&factory))) { printf("factory failed\n"); return 1; }
    if (FAILED(D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device), (void **)&device))) { printf("device failed\n"); return 1; }
    D3D12_COMMAND_QUEUE_DESC qd = {D3D12_COMMAND_LIST_TYPE_DIRECT};
    device->CreateCommandQueue(&qd, __uuidof(ID3D12CommandQueue), (void **)&queue);
    HMODULE ffx = LoadLibraryA(argv[1]);
    if (!ffx) { printf("can't load %s (%lu)\n", argv[1], GetLastError()); return 1; }
    auto create = (PfnCreate)GetProcAddress(ffx, "ffxCreateContext");
    if (!create) { printf("no ffxCreateContext\n"); return 1; }
    RECT r; GetClientRect(hwnd, &r);
    DXGI_SWAP_CHAIN_DESC1 desc = {};
    desc.Width = r.right - r.left; desc.Height = r.bottom - r.top; desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1; desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; desc.BufferCount = 3;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    desc.Flags = DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING | DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
    DXGI_SWAP_CHAIN_FULLSCREEN_DESC fs = {}; fs.Windowed = TRUE;
    IDXGISwapChain4 *swapchain = nullptr;
    SwapChainForHwndDesc sd = {{0x00030006ull, nullptr}, &swapchain, hwnd, &desc, &fs, factory, queue};
    void *context = nullptr;
    uint32_t rc = create(&context, &sd.header, nullptr);
    printf("ffxCreateContext rc=%u swapchain=%p\n", rc, (void *)swapchain);
    if (rc || !swapchain) return 1;

    ID3D12DescriptorHeap *rtv_heap; D3D12_DESCRIPTOR_HEAP_DESC hd = {D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 3};
    device->CreateDescriptorHeap(&hd, __uuidof(ID3D12DescriptorHeap), (void **)&rtv_heap);
    UINT inc = device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    D3D12_CPU_DESCRIPTOR_HANDLE base; rtv_heap->GetCPUDescriptorHandleForHeapStart(&base);
    ID3D12Resource *buffers[3];
    for (UINT i = 0; i < 3; i++) {
        if (FAILED(swapchain->GetBuffer(i, __uuidof(ID3D12Resource), (void **)&buffers[i]))) { printf("GetBuffer %u failed\n", i); return 1; }
        D3D12_CPU_DESCRIPTOR_HANDLE h = base; h.ptr += i * inc;
        device->CreateRenderTargetView(buffers[i], nullptr, h);
    }
    ID3D12CommandAllocator *alloc; ID3D12GraphicsCommandList *list; ID3D12Fence *fence;
    device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, __uuidof(ID3D12CommandAllocator), (void **)&alloc);
    device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, nullptr, __uuidof(ID3D12GraphicsCommandList), (void **)&list);
    list->Close();
    device->CreateFence(0, D3D12_FENCE_FLAG_NONE, __uuidof(ID3D12Fence), (void **)&fence);
    HANDLE ev = CreateEventA(nullptr, FALSE, FALSE, nullptr);
    int presented = 0;
    for (int f = 0; f < frames; f++) {
        MSG m; while (PeekMessageA(&m, nullptr, 0, 0, PM_REMOVE)) DispatchMessageA(&m);
        UINT b = swapchain->GetCurrentBackBufferIndex();
        alloc->Reset(); list->Reset(alloc, nullptr);
        D3D12_RESOURCE_BARRIER bar = {}; bar.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION; bar.Transition.pResource = buffers[b];
        bar.Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT; bar.Transition.StateAfter = D3D12_RESOURCE_STATE_RENDER_TARGET;
        list->ResourceBarrier(1, &bar);
        D3D12_CPU_DESCRIPTOR_HANDLE h = base; h.ptr += b * inc;
        const float color[4] = {0.9f, 0.1f, 0.5f, 1.0f};
        list->ClearRenderTargetView(h, color, 0, nullptr);
        bar.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET; bar.Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT;
        list->ResourceBarrier(1, &bar);
        list->Close();
        ID3D12CommandList *lists[] = {list}; queue->ExecuteCommandLists(1, lists);
        HRESULT hr = swapchain->Present(0, 0);
        if (SUCCEEDED(hr)) presented++;
        queue->Signal(fence, f + 1); fence->SetEventOnCompletion(f + 1, ev); WaitForSingleObject(ev, 5000);
    }
    printf("presented %d/%d through the FSR 3 proxy\n", presented, frames);
    return 0;
}
