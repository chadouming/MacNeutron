// The translation cache test (d3d12_cache): a quad from a vertex buffer, coloured from a root CBV, and a compute shader
// that carries its own root signature. A different render target format, input layout or root signature changes the
// translated functions.
cbuffer Draw : register(b0) { float4 color; };
float4 vsmain(float2 pos : POSITION) : SV_Position { return float4(pos, 0.5, 1); }
float4 psmain(float4 pos : SV_Position) : SV_Target { return color; }
RWStructuredBuffer<float> data : register(u0);
[RootSignature("UAV(u0)")]
[numthreads(64, 1, 1)]
void csmain(uint3 id : SV_DispatchThreadID) { data[id.x] = data[id.x] * 2 + 1; }
