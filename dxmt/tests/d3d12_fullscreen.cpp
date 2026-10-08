// Exclusive fullscreen and leaving it (Task FS, Rulings 36-37), on Wine's emulated modes only:
//   d3d12_fullscreen.exe [d3d11]
// Refuses to run ("not emulated") unless HKCU\Software\Wine\X11 Driver\EmulateModeset is on, so a fullscreen mode
// change is Wine's virtual one and never the Mac's display. The game window fits itself to each new mode on
// WM_DISPLAYCHANGE, as games may. Prints:
//   "fg-leave <foreground> <iconic> <rect>": leaving fullscreen while in front keeps the window up, at the rect it had
//   before the mode change ("same"), not the one it took after it;
//   "bg-leave <foreground> <iconic>": leaving while another window is in front minimises it;
//   D3D12 only, on the window minimised (by then, or by the test), "minimised presents <worst hr> <latency
//   timeouts> <present count advance> <fast|slow>": 31 frames, each waited for on the frame latency object, presented
//   and fenced, return S_OK, count as presents and take under 100 ms each; then "restored present <hr>" once the
//   window is restored. Whether a present reached Metal is DXMT_STATS's count of presents skipped.
#define WIDL_EXPLICIT_AGGREGATE_RETURNS  // D3D12 methods that return structs: the MSVC ABI under mingw
#include <windows.h>
#include <d3d11.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <cstdio>
#include <cstring>

#define CHECK(expr) do { HRESULT hr_ = (expr); if (FAILED(hr_)) { \
    printf("%s failed 0x%08lx\n", #expr, (unsigned long)hr_); return 1; } } while (0)

static HWND game;
static LRESULT CALLBACK proc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (h == game && m == WM_DISPLAYCHANGE)
        SetWindowPos(h, nullptr, 0, 0, LOWORD(l), HIWORD(l), SWP_NOZORDER | SWP_NOACTIVATE);
    return DefWindowProcA(h, m, w, l);
}

static void pump(DWORD ms) {
    for (DWORD start = GetTickCount(); GetTickCount() - start < ms; Sleep(10)) {
        MSG msg;
        while (PeekMessageA(&msg, nullptr, 0, 0, PM_REMOVE)) DispatchMessageA(&msg);
    }
}

static bool emulated() {
    char v[8] = {}; DWORD size = sizeof v;
    if (RegGetValueA(HKEY_CURRENT_USER, "Software\\Wine\\X11 Driver", "EmulateModeset", RRF_RT_REG_SZ, nullptr, v,
                     &size))
        return false;
    return strchr("yYtT1", v[0]) && v[0];
}

int main(int argc, char **argv) {
    const bool d3d11 = argc > 1 && !strcmp(argv[1], "d3d11");
    if (!emulated()) { printf("not emulated\n"); return 1; }
    const UINT width = 640, height = 360, count = 2;
    WNDCLASSA wc = {};
    wc.lpfnWndProc = proc; wc.hInstance = GetModuleHandleA(nullptr); wc.lpszClassName = "d3d12_fullscreen";
    RegisterClassA(&wc);
    RECT r = {0, 0, (LONG)width, (LONG)height};
    AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, FALSE);
    game = CreateWindowA("d3d12_fullscreen", "d3d12_fullscreen", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 60, 60,
                         r.right - r.left, r.bottom - r.top, nullptr, nullptr, wc.hInstance, nullptr);
    HWND other = CreateWindowA("d3d12_fullscreen", "other", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 300, 300, 320, 180,
                               nullptr, nullptr, wc.hInstance, nullptr);

    IDXGIFactory2 *factory;
    CHECK(CreateDXGIFactory1(__uuidof(IDXGIFactory2), (void **)&factory));
    DXGI_SWAP_CHAIN_DESC1 sd = {};
    sd.Width = width; sd.Height = height; sd.Format = DXGI_FORMAT_R8G8B8A8_UNORM; sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; sd.BufferCount = count; sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    sd.Flags = DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH;  // fullscreen at the swapchain's size, not the desktop's
    IDXGISwapChain1 *swap1;
    ID3D12Device *device = nullptr; ID3D12CommandQueue *queue = nullptr;
    if (d3d11) {
        ID3D11Device *device11;
        CHECK(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, nullptr, 0, D3D11_SDK_VERSION, &device11,
                                nullptr, nullptr));
        CHECK(factory->CreateSwapChainForHwnd(device11, game, &sd, nullptr, nullptr, &swap1));
    } else {
        CHECK(D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device), (void **)&device));
        D3D12_COMMAND_QUEUE_DESC qd = {D3D12_COMMAND_LIST_TYPE_DIRECT};
        CHECK(device->CreateCommandQueue(&qd, __uuidof(ID3D12CommandQueue), (void **)&queue));
        sd.Flags |= DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
        CHECK(factory->CreateSwapChainForHwnd(queue, game, &sd, nullptr, nullptr, &swap1));
    }

    SetForegroundWindow(game);
    pump(300);
    RECT windowed, now;
    GetWindowRect(game, &windowed);
    CHECK(swap1->SetFullscreenState(TRUE, nullptr));
    pump(300);
    bool front = GetForegroundWindow() == game;
    CHECK(swap1->SetFullscreenState(FALSE, nullptr));
    pump(500);
    GetWindowRect(game, &now);
    char rect[64] = "same";
    if (memcmp(&now, &windowed, sizeof now))
        snprintf(rect, sizeof rect, "%ld,%ld,%ld,%ld", now.left, now.top, now.right, now.bottom);
    printf("fg-leave %d %d %s\n", front, (int)IsIconic(game), rect);

    CHECK(swap1->SetFullscreenState(TRUE, nullptr));
    pump(300);
    SetForegroundWindow(other);
    pump(300);
    front = GetForegroundWindow() == other;
    CHECK(swap1->SetFullscreenState(FALSE, nullptr));
    pump(500);
    printf("bg-leave %d %d\n", front, (int)IsIconic(game));
    if (d3d11) return 0;
    if (!IsIconic(game)) {  // the presents below are checked on a minimised window whatever bg-leave found
        ShowWindow(game, SW_MINIMIZE);
        pump(500);
    }

    IDXGISwapChain3 *swap;
    CHECK(swap1->QueryInterface(__uuidof(IDXGISwapChain3), (void **)&swap));
    HANDLE latency = swap->GetFrameLatencyWaitableObject();
    ID3D12DescriptorHeap *heap;
    D3D12_DESCRIPTOR_HEAP_DESC hd = {D3D12_DESCRIPTOR_HEAP_TYPE_RTV, count};
    CHECK(device->CreateDescriptorHeap(&hd, __uuidof(ID3D12DescriptorHeap), (void **)&heap));
    const UINT stride = device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    ID3D12Resource *buffers[count]; D3D12_CPU_DESCRIPTOR_HANDLE rtv[count];
    for (UINT i = 0; i < count; i++) {
        CHECK(swap->GetBuffer(i, __uuidof(ID3D12Resource), (void **)&buffers[i]));
        rtv[i] = heap->GetCPUDescriptorHandleForHeapStart();
        rtv[i].ptr += i * stride;
        device->CreateRenderTargetView(buffers[i], nullptr, rtv[i]);
    }
    ID3D12CommandAllocator *allocator; ID3D12GraphicsCommandList *list; ID3D12Fence *fence;
    CHECK(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, __uuidof(ID3D12CommandAllocator), (void **)&allocator));
    CHECK(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator, nullptr,
                                    __uuidof(ID3D12GraphicsCommandList), (void **)&list));
    CHECK(list->Close());
    CHECK(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, __uuidof(ID3D12Fence), (void **)&fence));
    HANDLE done = CreateEventA(nullptr, FALSE, FALSE, nullptr);
    UINT64 value = 0;
    auto frame = [&](UINT sync) -> HRESULT {  // one cleared frame, presented and fenced
        const UINT b = swap->GetCurrentBackBufferIndex();
        allocator->Reset();
        list->Reset(allocator, nullptr);
        D3D12_RESOURCE_BARRIER barrier = {};
        barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        barrier.Transition.pResource = buffers[b];
        barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT;
        barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_RENDER_TARGET;
        list->ResourceBarrier(1, &barrier);
        const float color[4] = {0.2f, 0.4f, 0.8f, 1.0f};
        list->ClearRenderTargetView(rtv[b], color, 0, nullptr);
        barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
        barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT;
        list->ResourceBarrier(1, &barrier);
        list->Close();
        ID3D12CommandList *lists[] = {list};
        queue->ExecuteCommandLists(1, lists);
        HRESULT hr = swap->Present(sync, 0);
        queue->Signal(fence, ++value);
        if (fence->GetCompletedValue() < value) {
            fence->SetEventOnCompletion(value, done);
            if (WaitForSingleObject(done, 5000) != WAIT_OBJECT_0) { printf("frame %llu never finished\n", value); exit(1); }
        }
        return hr;
    };
    HRESULT worst = S_OK;
    int timeouts = 0;
    double slowest = 0;
    UINT before = 0, after = 0;
    LARGE_INTEGER freq, t0, t1;
    QueryPerformanceFrequency(&freq);
    swap->GetLastPresentCount(&before);
    for (int i = 0; i < 31; i++) {
        timeouts += WaitForSingleObject(latency, 1000) != WAIT_OBJECT_0;
        QueryPerformanceCounter(&t0);
        HRESULT hr = frame(1);
        QueryPerformanceCounter(&t1);
        if (hr != S_OK) worst = hr;
        const double ms = (t1.QuadPart - t0.QuadPart) * 1000.0 / freq.QuadPart;
        if (ms > slowest) slowest = ms;
    }
    swap->GetLastPresentCount(&after);
    printf("minimised presents 0x%lx %d %u %s\n", (unsigned long)worst, timeouts, after - before,
           slowest < 100 ? "fast" : "slow");
    printf("info slowest minimised present %.1f ms (iconic %d)\n", slowest, (int)IsIconic(game));
    ShowWindow(game, SW_RESTORE);
    SetForegroundWindow(game);
    pump(500);
    WaitForSingleObject(latency, 1000);
    printf("restored present 0x%lx\n", (unsigned long)frame(1));
    return 0;
}
