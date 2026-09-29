#include "common.hlsli"
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint i = id.x; float16_t a = (float16_t)InFloat(i); float16_t b = (float16_t)InFloat(i + 64);
    uint16_t u16 = (uint16_t)InWord(i); int16_t s = (int16_t)InWord(i + 1);
    Put(id, 0, asuint16(a * b + a)); Put(id, 1, asuint16(max(a, b))); PutF(id, 2, (float)(a / (abs(b) + (float16_t)1)));
    Put(id, 3, (uint)(u16 * (uint16_t)3 + (uint16_t)(s >> 2))); min16float m = (min16float)InFloat(i); PutF(id, 4, (float)(m * m));
    Put(id, 5, asuint16(dot(half2(a, 1), half2(1, b)))); // SMITE 2: a half dot aborted the process
}
