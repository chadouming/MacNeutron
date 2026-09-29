#include "common.hlsli"
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint i = id.x; uint w = InWord(i) & 0xffff; float f = InFloat(i); bool odd = (w & 1) != 0;
    Put(id, 0, WaveGetLaneIndex()); Put(id, 1, WaveGetLaneCount()); Put(id, 2, WaveIsFirstLane() ? 1 : 0);
    Put(id, 3, WaveActiveSum(w)); Put(id, 4, WaveActiveMax(w)); Put(id, 5, WaveActiveMin(w));
    Put(id, 6, WaveActiveAllTrue(w > 3) ? 1 : 0); Put(id, 7, WaveActiveAnyTrue(w == 7) ? 1 : 0);
    uint4 b = WaveActiveBallot(odd); Put(id, 8, b.x); Put(id, 9, WaveReadLaneFirst(w)); Put(id, 10, WaveReadLaneAt(w, 5));
    Put(id, 11, WavePrefixSum(w)); PutF(id, 12, WaveActiveSum(f)); Put(id, 13, WaveActiveCountBits(odd));
    Put(id, 14, WaveActiveBitOr(w)); Put(id, 15, WavePrefixCountBits(odd));
}
