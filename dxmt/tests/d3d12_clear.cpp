// Clears and presents N frames through Direct3D 12 (DXMT fork spec §6):
//   d3d12_clear.exe [frames]
// Prints the adapter, what Unreal Engine's SM6 check reads (shader model, binding tier, feature level, wave ops,
// 64-bit atomics) and the average frame time.
#define WIDL_EXPLICIT_AGGREGATE_RETURNS  // D3D12 methods that return structs: the MSVC ABI under mingw
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <cstdio>
#include <cstdlib>

#define CHECK(expr) do { HRESULT hr_ = (expr); if (FAILED(hr_)) { \
    printf("%s failed 0x%08lx\n", #expr, (unsigned long)hr_); return 1; } } while (0)

static LRESULT CALLBACK proc(HWND h, UINT m, WPARAM w, LPARAM l) { return DefWindowProcA(h, m, w, l); }

int main(int argc, char **argv) {
    const int frames = argc > 1 ? atoi(argv[1]) : 300;
    const UINT width = 1280, height = 720, count = 2;
    WNDCLASSA wc = {};
    wc.lpfnWndProc = proc; wc.hInstance = GetModuleHandleA(nullptr); wc.lpszClassName = "d3d12_clear";
    RegisterClassA(&wc);
    RECT r = {0, 0, (LONG)width, (LONG)height};
    AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, FALSE);
    HWND hwnd = CreateWindowA("d3d12_clear", "d3d12_clear", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 40, 40,
                              r.right - r.left, r.bottom - r.top, nullptr, nullptr, wc.hInstance, nullptr);

    IDXGIFactory4 *factory; IDXGIAdapter1 *adapter; DXGI_ADAPTER_DESC1 ad; ID3D12Device *device;
    CHECK(CreateDXGIFactory1(__uuidof(IDXGIFactory4), (void **)&factory));
    CHECK(factory->EnumAdapters1(0, &adapter));
    CHECK(adapter->GetDesc1(&ad));
    CHECK(D3D12CreateDevice(adapter, D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device), (void **)&device));
    D3D12_FEATURE_DATA_SHADER_MODEL sm = {D3D_SHADER_MODEL_6_6};
    HRESULT smhr = device->CheckFeatureSupport(D3D12_FEATURE_SHADER_MODEL, &sm, sizeof sm);
    D3D12_FEATURE_DATA_D3D12_OPTIONS options = {};
    device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS, &options, sizeof options);
    printf("adapter %ls\nshader model 0x%x (hr 0x%08lx)\nresource binding tier %d\n",
           ad.Description, (unsigned)sm.HighestShaderModel, (unsigned long)smhr, (int)options.ResourceBindingTier);
    const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_12_0,
                                        D3D_FEATURE_LEVEL_12_1};
    D3D12_FEATURE_DATA_FEATURE_LEVELS fl = {4, levels};
    D3D12_FEATURE_DATA_D3D12_OPTIONS1 options1 = {};
    D3D12_FEATURE_DATA_D3D12_OPTIONS9 options9 = {};
    device->CheckFeatureSupport(D3D12_FEATURE_FEATURE_LEVELS, &fl, sizeof fl);
    device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS1, &options1, sizeof options1);
    device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS9, &options9, sizeof options9);
    printf("feature level 0x%x, wave ops %d, atomic64 %d\n", (unsigned)fl.MaxSupportedFeatureLevel, (int)options1.WaveOps,
           (int)options9.AtomicInt64OnTypedResourceSupported);

    ID3D12CommandQueue *queue;
    D3D12_COMMAND_QUEUE_DESC qd = {D3D12_COMMAND_LIST_TYPE_DIRECT};
    CHECK(device->CreateCommandQueue(&qd, __uuidof(ID3D12CommandQueue), (void **)&queue));
    DXGI_SWAP_CHAIN_DESC1 sd = {};
    sd.Width = width; sd.Height = height; sd.Format = DXGI_FORMAT_R8G8B8A8_UNORM; sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; sd.BufferCount = count; sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    IDXGISwapChain1 *swap1; IDXGISwapChain3 *swap;
    CHECK(factory->CreateSwapChainForHwnd(queue, hwnd, &sd, nullptr, nullptr, &swap1));
    CHECK(swap1->QueryInterface(__uuidof(IDXGISwapChain3), (void **)&swap));

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

    LARGE_INTEGER freq, t0, t1;
    QueryPerformanceFrequency(&freq); QueryPerformanceCounter(&t0);
    int presented = 0;
    for (int i = 0; i < frames; i++) {
        MSG msg; while (PeekMessageA(&msg, nullptr, 0, 0, PM_REMOVE)) DispatchMessageA(&msg);
        const UINT b = swap->GetCurrentBackBufferIndex();
        CHECK(allocator->Reset());
        CHECK(list->Reset(allocator, nullptr));
        D3D12_RESOURCE_BARRIER barrier = {};
        barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        barrier.Transition.pResource = buffers[b];
        barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT;
        barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_RENDER_TARGET;
        list->ResourceBarrier(1, &barrier);
        const float color[4] = {(i % 60) / 60.0f, 0.3f, 1.0f - (i % 120) / 120.0f, 1.0f};
        list->ClearRenderTargetView(rtv[b], color, 0, nullptr);
        barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
        barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT;
        list->ResourceBarrier(1, &barrier);
        CHECK(list->Close());
        ID3D12CommandList *lists[] = {list};
        queue->ExecuteCommandLists(1, lists);
        CHECK(swap->Present(0, 0));
        presented++;
        // One frame in flight: simple, and the frame time includes the GPU's work.
        CHECK(queue->Signal(fence, i + 1));
        if (fence->GetCompletedValue() < (UINT64)i + 1) {
            CHECK(fence->SetEventOnCompletion(i + 1, done));
            if (WaitForSingleObject(done, 5000) != WAIT_OBJECT_0) { printf("frame %d never finished\n", i); return 1; }
        }
    }
    QueryPerformanceCounter(&t1);
    printf("presented %d/%d frames, avg frame %.3f ms\n", presented, frames,
           (t1.QuadPart - t0.QuadPart) * 1000.0 / freq.QuadPart / frames);
    return 0;
}
