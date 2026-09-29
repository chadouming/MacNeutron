#include "common.hlsli"
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint i = id.x; float f = InFloat(i); float g = InFloat(i + 64); uint w = InWord(i); int s = (int)w;
    PutF(id, 0, f * g + f / (abs(g) + 1)); PutF(id, 1, mad(f, g, 0.5)); PutF(id, 2, min(f, g) - max(f, g));
    PutF(id, 3, saturate(f) + abs(g)); PutF(id, 4, floor(f) + ceil(g) + round(f) + trunc(g));
    PutF(id, 5, frac(f) + sqrt(abs(g)) + rsqrt(abs(f) + 1)); PutF(id, 6, dot(float3(f, g, 1), float3(g, f, 2)));
    Put(id, 7, countbits(w) + firstbitlow(w) * 64 + firstbithigh(w) * 4096); Put(id, 8, reversebits(w));
    Put(id, 9, (uint)(s / 7) + (uint)(s % 7) + w / 13 + w % 13); Put(id, 10, (uint)min(s, 5) + max(w, 9u));
    Put(id, 11, f32tof16(f) | (f32tof16(g) << 16)); PutF(id, 12, f16tof32(w & 0xffff));
    PutF(id, 13, (float)s * 1e-9 + (float)w * 1e-9); Put(id, 14, (uint)(int)(f * 10) + (uint)abs(g * 10));
    PutF(id, 15, clamp(f, -1, 1) + lerp(f, g, 0.25) + step(0, f) + sign(g));
}
