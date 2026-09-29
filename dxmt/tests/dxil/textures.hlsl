#include "common.hlsli"
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint i = id.x; int2 xy = int2(i & 7, i >> 3); float2 uv = (float2(xy) + 0.37) / 8;
    float4 l = Tex.Load(int3(xy, 0)); PutF(id, 0, l.x + l.y * 2 + l.z * 4);
    float4 a = Tex.SampleLevel(Linear, uv, 0); PutF(id, 1, a.x); PutF(id, 2, a.y); PutF(id, 3, a.z);
    float4 b = Tex.SampleLevel(Point, uv, 0); PutF(id, 4, b.x + b.y + b.z);
    float4 r = Tex.GatherRed(Point, uv); PutF(id, 5, r.x + r.y * 2 + r.z * 4 + r.w * 8);
    uint w, h, m; Tex.GetDimensions(0, w, h, m); Put(id, 6, w * 100 + h * 10 + m);
    float4 o = Tex.SampleLevel(Linear, uv, 0, int2(1, -1)); PutF(id, 7, o.x + o.y);
    RWTex[xy] = float4(uv, 0.5, 1); DeviceMemoryBarrierWithGroupSync(); PutF(id, 8, RWTex[xy].x + RWTex[xy].y);
}
