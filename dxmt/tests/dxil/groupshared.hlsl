#include "common.hlsli"
groupshared uint Shared[64];
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID, uint gi : SV_GroupIndex, uint3 gtid : SV_GroupThreadID) {
    Shared[gi] = InWord(gi); GroupMemoryBarrierWithGroupSync();
    Put(id, 0, Shared[(gi + 1) & 63]); Put(id, 1, Shared[63 - gi] + gtid.x);
    GroupMemoryBarrierWithGroupSync();
    uint old; InterlockedAdd(Shared[0], 1, old); GroupMemoryBarrierWithGroupSync(); Put(id, 2, Shared[0] - InWord(0));
}
