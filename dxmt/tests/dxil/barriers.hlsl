// Task F2: barriers that fence memory without syncing the group (DXIL Barrier modes 8, 10 and 2: GroupMemoryBarrier,
// AllMemoryBarrier, DeviceMemoryBarrier), each followed by a synced one so the results don't depend on scheduling.
#include "common.hlsli"
groupshared uint Shared[64];
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID, uint gi : SV_GroupIndex) {
    Shared[gi] = InWord(gi); GroupMemoryBarrier(); GroupMemoryBarrierWithGroupSync();
    Put(id, 0, Shared[63 - gi]);
    RWTyped[gi] = gi * 3 + 1; DeviceMemoryBarrier(); DeviceMemoryBarrierWithGroupSync();
    Put(id, 1, RWTyped[(gi + 1) & 63]);
    Shared[gi] = gi + 7; RWTyped[gi] = gi * 5; AllMemoryBarrier(); AllMemoryBarrierWithGroupSync();
    Put(id, 2, Shared[(gi + 2) & 63] + RWTyped[(gi + 3) & 63]);
}
