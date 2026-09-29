#include "common.hlsli"
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint i = id.x;
    Put(id, 0, InWord(i));
    uint2 two = In.Load2(i * 8); Put(id, 1, two.x ^ two.y);
    uint4 four = In.Load4(i * 16); Put(id, 2, four.x + four.y + four.z + four.w);
    float4 t = Typed[i]; PutF(id, 3, t.x + t.y * 2 + t.z * 3 + t.w * 4);
    S s = Structured[i]; PutF(id, 4, s.a.y + s.a.w); Put(id, 5, s.b);
    PutF(id, 6, k[i & 3].x * k[(i + 1) & 3].y); Put(id, 7, u[i & 3]);
    float4 a = Arr[NonUniformResourceIndex(i & 1)][i]; PutF(id, 8, a.x + a.y);
    RWTyped[i] = i * 3; AllMemoryBarrier(); Put(id, 9, RWTyped[i]);
    Out.Store((i * 16 + 10) * 4, InWord(i) >> 3);
    Out.Store2((i * 16 + 11) * 4, uint2(i, i + 1));
}
