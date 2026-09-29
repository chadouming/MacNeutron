#include "common.hlsli"
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint i = id.x; float f = InFloat(i) * 0.5; float p = abs(f) + 0.01;
    PutF(id, 0, sin(f)); PutF(id, 1, cos(f)); PutF(id, 2, tan(f * 0.5)); PutF(id, 3, asin(clamp(f, -1, 1)));
    PutF(id, 4, acos(clamp(f, -1, 1))); PutF(id, 5, atan(f)); PutF(id, 6, atan2(f, 0.7)); PutF(id, 7, exp(f * 0.5));
    PutF(id, 8, exp2(f)); PutF(id, 9, log(p)); PutF(id, 10, log2(p)); PutF(id, 11, pow(p, 1.7));
    PutF(id, 12, sinh(f * 0.25)); PutF(id, 13, cosh(f * 0.25)); PutF(id, 14, tanh(f)); PutF(id, 15, sqrt(p));
}
