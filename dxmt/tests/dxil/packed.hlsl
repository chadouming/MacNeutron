#include "common.hlsli"
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint i = id.x; uint a = InWord(i), b = InWord(i + 1);
    Put(id, 0, dot4add_u8packed(a, b, 7u)); Put(id, 1, (uint)dot4add_i8packed(a, b, -7));
    PutF(id, 2, dot2add(half2(InFloat(i), InFloat(i + 1)), half2(0.5, -2), 1.0));
    // SM 6.6 pack/unpack, every mode (SMITE 2 uses unpack_s8s32 and pack_u8).
    int4 s = unpack_s8s32((int8_t4_packed)a); uint4 u = unpack_u8u32((uint8_t4_packed)b);
    Put(id, 3, s.x); Put(id, 4, s.w); Put(id, 5, u.y); Put(id, 6, (uint)(int)unpack_s8s16((int8_t4_packed)b).z);
    Put(id, 7, pack_u8(u + (uint4)s)); Put(id, 8, pack_s8(s * 3));
    Put(id, 9, pack_clamp_u8(s * 3)); Put(id, 10, pack_clamp_s8(s * 3));
}
