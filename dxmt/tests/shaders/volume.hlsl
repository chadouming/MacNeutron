// A 3D texture written by compute and sampled in a later dispatch, as Unreal's volumetric fog fills its light
// scattering volume and translucency samples it (the SMITE 2 black particle glitch).
RWTexture3D<float4> Volume : register(u0);
Texture3D<float4> VolumeIn : register(t0);
SamplerState Linear : register(s0);
RWByteAddressBuffer Out : register(u1);
[numthreads(4, 4, 4)]
void fill(uint3 id : SV_DispatchThreadID) { Volume[id] = float4(id.x / 8.0, id.y / 8.0, id.z / 4.0, 0.25 + id.z / 8.0); }
[numthreads(4, 1, 1)]
void sample(uint3 id : SV_DispatchThreadID) {
    float3 uvw = float3((id.x * 2 + 0.5) / 8.0, (id.x + 0.5) / 8.0, (id.x + 0.5) / 4.0); // texel centres
    float4 v = VolumeIn.SampleLevel(Linear, uvw, 0);
    float4 l = VolumeIn.Load(int4(id.x * 2, id.x, id.x, 0));
    Out.Store4(id.x * 32, asuint(v));
    Out.Store4(id.x * 32 + 16, asuint(l));
}
