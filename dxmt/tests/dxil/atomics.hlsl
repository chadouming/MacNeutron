#include "common.hlsli"
// UAV atomics on typed, structured, texture and raw resources (SMITE 2 uses the first three). Contended locations are
// output after a barrier; returned old values only where one thread owns the location.
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint i = id.x, w = InWord(i), old; int olds;
    InterlockedAdd(RWTyped[0], i + 1); InterlockedMax(RWTyped[1], w); InterlockedOr(RWTyped[2], 1u << (i & 31));
    AtomicS[i] = int2(i, 100);
    InterlockedAdd(AtomicS[i].x, 5, olds); Put(id, 0, olds);
    InterlockedExchange(AtomicS[i].y, -7, olds); Put(id, 1, olds);
    InterlockedCompareExchange(AtomicS[i].x, (int)i + 5, 42, olds); Put(id, 2, olds); // swaps
    InterlockedCompareExchange(AtomicS[i].y, 0, 43, olds); Put(id, 3, olds);          // doesn't
    InterlockedMin(AtomicS[64].x, (int)w); InterlockedMax(AtomicS[64].y, (int)w);
    uint2 t = uint2(i & 7, i >> 3);
    InterlockedAdd(AtomicTex[t], w, old); Put(id, 4, old);
    InterlockedMax(AtomicTex[t], 5, old); Put(id, 5, old);
    InterlockedMin(AtomicTex[t], 3, old); Put(id, 6, old);
    Out.InterlockedAdd((i * 16 + 7) * 4, 9, old); Put(id, 8, old);
    DeviceMemoryBarrierWithGroupSync();
    Put(id, 9, RWTyped[0]); Put(id, 10, RWTyped[1]); Put(id, 11, RWTyped[2]);
    Put(id, 12, AtomicS[i].x); Put(id, 13, AtomicS[i].y); Put(id, 14, AtomicS[64].x); Put(id, 15, AtomicS[64].y);
}
