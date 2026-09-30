// Infinity and NaN built from data the compiler can't see (u.x - 3 is 0 at run time): D3D keeps IEEE specials, so
// compares, min/max and arithmetic see them, whatever fast-math flags DXC puts on the instructions.
#include "common.hlsli"
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint zero = u.x - 3; float z = (float)zero; float f = InFloat(id.x);
    float inf = asfloat(0x7f800000u | zero), nan = asfloat(0x7fc00000u | zero), nan2 = asfloat(0x7fc00001u | zero);
    Put(id, 0, nan != nan2 ? 1u : 0u);
    Put(id, 1, (nan < f) || (nan >= f) ? 1u : 0u);
    Put(id, 2, isnan(inf * z) ? 1u : 0u);
    PutF(id, 3, max(nan, f));
    PutF(id, 4, min(inf, f));
    Put(id, 5, isinf(1.0 / z) ? 1u : 0u);
    Put(id, 6, isinf(log(z)) ? 1u : 0u);
    PutF(id, 7, exp(-inf));
    Put(id, 8, isnan(sqrt(f - 1000)) ? 1u : 0u);
    PutF(id, 9, saturate(nan));
    Put(id, 10, (nan > f) ? 1u : 0u);
    Put(id, 11, (f + inf) > 3.0e38 ? 1u : 0u);
    Put(id, 12, isnan(inf - inf * (z + 1)) ? 1u : 0u);
    PutF(id, 13, clamp(nan, 0, 1));
    Put(id, 14, !(nan <= f) ? 1u : 0u);
    Put(id, 15, (nan == nan2) ? 1u : 0u);
}
