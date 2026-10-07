// Task F2: mad() fuses to one rounding unless the result is precise (DXIL FMad with or without !dx.precise; Metal
// Shader Converter does the same). a = 1 + n 2^-13, b = 1 - n 2^-13, c = -1 (n = thread + 1): a*b = 1 - n^2 2^-26, which
// a separate multiply rounds to 1 for odd n (0 after the add), and a fused one keeps (-n^2 2^-26).
#include "common.hlsli"
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    float one = k[0].x, n = (float)(id.x + 1), step = one / 8192;
    float a = one + n * step, b = one - n * step, c = -one;
    PutF(id, 0, mad(a, b, c));
    precise float p = mad(b, a, c); // operands swapped: DXC would share one call between the two
    PutF(id, 1, p);
    PutF(id, 2, a); PutF(id, 3, b);
}
