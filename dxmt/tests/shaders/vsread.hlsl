// Resources read by a vertex shader, as Unreal's Niagara sprite and translucency vertex shaders read particle data
// and fog volumes: a half-float typed buffer, a structured buffer, a 3D texture and a cube map (SampleLevel).
Buffer<float> Halves : register(t0);                  // R16_FLOAT view, FirstElement 3
StructuredBuffer<float4> Structs : register(t1);      // stride 16, FirstElement 1
Texture3D<float4> Volume : register(t2);              // 4x4x4 RGBA16F
TextureCube<float4> Sky : register(t3);               // 4x4 RGBA8 faces
SamplerState Linear : register(s0);
struct VSOut { float4 pos : SV_Position; float4 a : TEXCOORD0; float4 b : TEXCOORD1; float4 c : TEXCOORD2; float4 d : TEXCOORD3; };
VSOut vsmain(uint id : SV_VertexID) {
    VSOut o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    o.a = float4(Halves[0], Halves[1], Halves[2], Halves[3]);
    o.b = Structs[1];
    o.c = Volume.SampleLevel(Linear, float3(0.375, 0.625, 0.875), 0);
    o.d = Sky.SampleLevel(Linear, float3(1, 0.25, -0.5), 0);
    return o;
}
struct PSOut { float4 a : SV_Target0; float4 b : SV_Target1; float4 c : SV_Target2; float4 d : SV_Target3; };
PSOut psmain(VSOut i) { PSOut o; o.a = i.a; o.b = i.b; o.c = i.c; o.d = i.d; return o; }
