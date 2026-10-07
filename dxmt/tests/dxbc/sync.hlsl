// Task FR: D3D11's barriers for dxil-translate's offline row (airconv's DXBC sync lowering): GroupMemoryBarrier,
// DeviceMemoryBarrier and AllMemoryBarrier, each without and with the group sync, in dxil/barriers.hlsl's order.
// sync.dxbc is this file compiled for cs_5_0 by `d3d11_vsia.exe compile` (D3DCompile under the launcher's Wine).
groupshared uint Shared[64];
RWBuffer<uint> Out : register(u0);
[numthreads(64, 1, 1)]
void main(uint gi : SV_GroupIndex) {
    Shared[gi] = gi; GroupMemoryBarrier(); GroupMemoryBarrierWithGroupSync();
    Out[gi] = Shared[63 - gi]; DeviceMemoryBarrier(); DeviceMemoryBarrierWithGroupSync();
    Shared[gi] = Out[(gi + 1) & 63] + gi; AllMemoryBarrier(); AllMemoryBarrierWithGroupSync();
    Out[gi] = Shared[(gi + 2) & 63];
}
