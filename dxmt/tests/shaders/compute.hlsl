// Doubles a buffer in place: the smallest compute shader for DXIL pipeline tests.
RWStructuredBuffer<float> data : register(u0);

[numthreads(64, 1, 1)]
void csmain(uint3 id : SV_DispatchThreadID) { data[id.x] *= 2; }
