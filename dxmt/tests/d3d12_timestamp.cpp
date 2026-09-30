// GPU timestamps by D3D12's rules (D3DMetal has none, so this isn't compared with it):
//   d3d12_timestamp.exe <vs.dxil> <ps.dxil> [leak | latency]
// Prints "timestamp rules <freq>0> <increasing> <advanced> <calibrated> <two lists> <chunks>" as 0/1 flags, then
// the raw values.
#include "d3d12_common.hpp"
#include <psapi.h>
#include <string>

static double WorkingSetMB() {
    PROCESS_MEMORY_COUNTERS pmc = {sizeof pmc};
    GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof pmc);
    return pmc.WorkingSetSize / 1048576.0;
}

int main(int argc, char **argv) {
    if (argc != 3 && argc != 4) { printf("usage: d3d12_timestamp.exe <vs.dxil> <ps.dxil> [leak | latency]\n"); return 2; }
    auto vs = Load(argv[1]), ps = Load(argv[2]);
    std::string mode = argc == 4 ? argv[3] : "";
    Gpu gpu;
    ID3D12RootSignature *root = CbvRootSignature(gpu);
    ID3D12PipelineState *pso = QuadPipeline(gpu, root, vs, ps);
    ID3D12Resource *target = gpu.Texture(Tex2D(1024, 1024, DXGI_FORMAT_R8G8B8A8_UNORM, 1, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET),
                                         D3D12_RESOURCE_STATE_RENDER_TARGET);
    ID3D12DescriptorHeap *rh; D3D12_DESCRIPTOR_HEAP_DESC rd = {D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 1};
    CHECK(gpu.device->CreateDescriptorHeap(&rd, __uuidof(ID3D12DescriptorHeap), (void **)&rh));
    auto rtv = rh->GetCPUDescriptorHandleForHeapStart();
    gpu.device->CreateRenderTargetView(target, nullptr, rtv);
    float draw[64] = {-1, -1, 1, 1, 1, 0, 0, 1, 0};
    ID3D12Resource *cb = gpu.Buffer(D3D12_HEAP_TYPE_UPLOAD, 256, D3D12_RESOURCE_STATE_GENERIC_READ);
    void *p; CHECK(cb->Map(0, nullptr, &p)); memcpy(p, draw, sizeof draw); cb->Unmap(0, nullptr);
    ID3D12QueryHeap *qh; D3D12_QUERY_HEAP_DESC qhd = {D3D12_QUERY_HEAP_TYPE_TIMESTAMP, 5000};
    CHECK(gpu.device->CreateQueryHeap(&qhd, __uuidof(ID3D12QueryHeap), (void **)&qh));
    ID3D12Resource *res = gpu.Buffer(D3D12_HEAP_TYPE_READBACK, 64, D3D12_RESOURCE_STATE_COPY_DEST);
    const auto TS = D3D12_QUERY_TYPE_TIMESTAMP;
    if (mode == "leak") { // 1500 submits each resolving 4096 timestamps: memory must not grow with them
        ID3D12Resource *big = gpu.Buffer(D3D12_HEAP_TYPE_READBACK, 4096 * 8, D3D12_RESOURCE_STATE_COPY_DEST);
        double before = 0;
        for (int i = 0; i < 1500; i++) {
            gpu.list->EndQuery(qh, TS, 0);
            gpu.list->ResolveQueryData(qh, TS, 0, 4096, big, 0);
            gpu.Submit();
            if (i == 100) before = WorkingSetMB(); // after warm-up
        }
        double growth = WorkingSetMB() - before;
        printf("timestamp leak growth %.0f MB ok %d\n", growth, growth < 16);
        return 0;
    }
    if (mode == "latency") { // fence round trips with and without a timestamp resolve in the list
        ID3D12Resource *small = gpu.Buffer(D3D12_HEAP_TYPE_READBACK, 64, D3D12_RESOURCE_STATE_COPY_DEST);
        double us[2];
        for (int with = 0; with < 2; with++) {
            LARGE_INTEGER f, t0, t1;
            QueryPerformanceFrequency(&f);
            for (int i = 0; i < 20; i++) gpu.Submit(); // warm-up
            QueryPerformanceCounter(&t0);
            for (int i = 0; i < 300; i++) {
                if (with) {
                    gpu.list->EndQuery(qh, TS, 0);
                    gpu.list->ResolveQueryData(qh, TS, 0, 1, small, 0);
                }
                gpu.Submit();
            }
            QueryPerformanceCounter(&t1);
            us[with] = (double)(t1.QuadPart - t0.QuadPart) * 1e6 / f.QuadPart / 300;
        }
        printf("timestamp latency round-trip without %.0f us with %.0f us\n", us[0], us[1]);
        return 0;
    }
    UINT64 freq = 0; CHECK(gpu.queue->GetTimestampFrequency(&freq));
    UINT64 g0, c0; CHECK(gpu.queue->GetClockCalibration(&g0, &c0));

    // List 1: 0 at its start, 1 after 200 full-screen draws, 2 between those and 200 more (mid-pass).
    gpu.list->EndQuery(qh, TS, 0);
    D3D12_VIEWPORT vp = {0, 0, 1024, 1024, 0, 1}; D3D12_RECT sc = {0, 0, 1024, 1024};
    gpu.list->OMSetRenderTargets(1, &rtv, FALSE, nullptr);
    gpu.list->RSSetViewports(1, &vp); gpu.list->RSSetScissorRects(1, &sc);
    gpu.list->SetGraphicsRootSignature(root); gpu.list->SetPipelineState(pso);
    gpu.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    gpu.list->SetGraphicsRootConstantBufferView(0, cb->GetGPUVirtualAddress());
    for (int i = 0; i < 200; i++) gpu.list->DrawInstanced(6, 1, 0, 0);
    gpu.list->EndQuery(qh, TS, 1);
    for (int i = 0; i < 200; i++) gpu.list->DrawInstanced(6, 1, 0, 0);
    gpu.list->EndQuery(qh, TS, 2);
    gpu.list->ResolveQueryData(qh, TS, 0, 3, res, 0);
    gpu.Submit();
    // List 2: 3, then 4095 and 4096 across the first counter buffer's end, resolved from 4094.
    gpu.list->EndQuery(qh, TS, 3);
    gpu.list->EndQuery(qh, TS, 4095);
    gpu.list->EndQuery(qh, TS, 4096);
    gpu.list->ResolveQueryData(qh, TS, 3, 1, res, 24);
    gpu.list->ResolveQueryData(qh, TS, 4095, 2, res, 32);
    gpu.Submit();
    UINT64 g1, c1; CHECK(gpu.queue->GetClockCalibration(&g1, &c1));
    UINT64 *t; CHECK(res->Map(0, nullptr, (void **)&t));
    int increasing = t[0] <= t[1] && t[1] <= t[2];
    int advanced = t[1] > t[0];
    int calibrated = g0 <= t[0] && t[2] <= g1 && t[4] <= g1 && t[5] <= g1;
    int two_lists = t[3] >= t[2];
    int chunks = t[3] <= t[4] && t[4] <= t[5] && t[5] != ~0ull && t[4] != ~0ull;
    printf("timestamp rules %d %d %d %d %d %d\n", freq > 0, increasing, advanced, calibrated, two_lists, chunks);
    res->Unmap(0, nullptr);
    // A resolve into GPU-only memory, copied to a readback buffer, twice: never the previous submission's value (zeros:
    // the CPU resolve reaches readback heaps only).
    ID3D12Resource *def = gpu.Buffer(D3D12_HEAP_TYPE_DEFAULT, 64, D3D12_RESOURCE_STATE_COPY_DEST);
    ID3D12Resource *rb2 = gpu.Buffer(D3D12_HEAP_TYPE_READBACK, 64, D3D12_RESOURCE_STATE_COPY_DEST);
    for (int round = 0; round < 2; round++) {
        gpu.list->EndQuery(qh, TS, 10);
        gpu.list->ResolveQueryData(qh, TS, 10, 1, def, 0);
        gpu.Barrier(def, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_COPY_SOURCE);
        gpu.list->CopyBufferRegion(rb2, 0, def, 0, 8);
        gpu.Barrier(def, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_COPY_DEST);
        gpu.Submit();
    }
    UINT64 *d; CHECK(rb2->Map(0, nullptr, (void **)&d));
    printf("timestamp default-heap %d\n", d[0] == 0);
    rb2->Unmap(0, nullptr);
    printf("timestamp values freq %llu calib %llu..%llu ts %llu %llu %llu %llu %llu %llu\n", (unsigned long long)freq,
           (unsigned long long)g0, (unsigned long long)g1, (unsigned long long)t[0], (unsigned long long)t[1],
           (unsigned long long)t[2], (unsigned long long)t[3], (unsigned long long)t[4], (unsigned long long)t[5]);
    gpu.queue->Release(); // DXMT's capture mode saves a frame-0 pass dump (DXMT_DUMP_FRAME=0) as the queue goes
    return 0;
}
