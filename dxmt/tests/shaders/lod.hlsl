// Mip selection (Task FU, from the blur study's sweep): every mip of T is a solid colour with R = mip*32, so R/32 of a
// trilinear sample is the LOD used. d3d12_lod.exe draws a full-target triangle, u stretched by u_scale.
cbuffer C : register(b0) { uint which_sampler; uint op; float u_scale; float arg; };
Texture2D<float4> T : register(t0);
SamplerState S0 : register(s0); SamplerState S1 : register(s1); SamplerState S2 : register(s2);
SamplerState S3 : register(s3); SamplerState S4 : register(s4); SamplerState S5 : register(s5);
SamplerState S6 : register(s6);

struct V { float4 pos : SV_Position; float2 uv : TEXCOORD0; };

V vsmain(uint id : SV_VertexID) {
    V v;
    float2 uv = float2((id << 1) & 2, id & 2);
    v.pos = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    v.uv = uv * float2(u_scale, 1);
    return v;
}

// op 1: SampleBias(arg); op 2: SampleGrad with the derivatives scaled by 2^arg (a bias through the gradients).
float4 Op(SamplerState s, float2 uv) {
    if (op == 1) return T.SampleBias(s, uv, arg);
    if (op == 2) return T.SampleGrad(s, uv, ddx(uv) * exp2(arg), ddy(uv) * exp2(arg));
    return T.Sample(s, uv);
}

float4 psmain(V v) : SV_Target0 {
    if (which_sampler == 1) return Op(S1, v.uv);
    if (which_sampler == 2) return Op(S2, v.uv);
    if (which_sampler == 3) return Op(S3, v.uv);
    if (which_sampler == 4) return Op(S4, v.uv);
    if (which_sampler == 5) return Op(S5, v.uv);
    if (which_sampler == 6) return Op(S6, v.uv);
    return Op(S0, v.uv);
}
