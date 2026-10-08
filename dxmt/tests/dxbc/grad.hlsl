// Task FU: D3D11's sample_d for dxil-translate's offline row: airconv scales the derivatives by 2^(the sampler's
// MipLODBias), as Metal's gradient sample takes no bias (grad=1/1). grad.dxbc is this file compiled for cs_5_0 by
// `d3d11_vsia.exe compile` (D3DCompile under the launcher's Wine).
Texture2D<float4> T : register(t0);
Buffer<float4> In : register(t1);
SamplerState S : register(s0);
RWBuffer<float4> Out : register(u0);
[numthreads(64, 1, 1)]
void main(uint i : SV_DispatchThreadID) {
    float4 d = In[i];
    Out[i] = T.SampleGrad(S, d.xy, d.zw, d.wz);
}
