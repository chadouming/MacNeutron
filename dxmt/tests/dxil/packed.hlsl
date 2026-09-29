#include "common.hlsli"
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint i = id.x; uint a = InWord(i), b = InWord(i + 1);
    Put(id, 0, dot4add_u8packed(a, b, 7u)); Put(id, 1, (uint)dot4add_i8packed(a, b, -7));
    PutF(id, 2, dot2add(half2(InFloat(i), InFloat(i + 1)), half2(0.5, -2), 1.0));
}
