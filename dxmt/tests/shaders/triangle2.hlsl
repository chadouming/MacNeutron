// Render test (DXIL translator plan, Task 3): constant buffer, texture sample, discard, derivatives, and an extra
// varying the pixel shader ignores, so its TEXCOORD0 is packed at a different row than the vertex shader's; and the
// render target array index (always 0: the target isn't an array), written by the vertex shader (Task 6).
cbuffer Constants : register(b0) { float2 scale; float2 offset; };
Texture2D<float4> Tex : register(t0);
SamplerState Point : register(s0);
struct VSOut {
    float4 pos : SV_Position; float2 extra : TEXCOORD1; float2 uv : TEXCOORD0; uint layer : SV_RenderTargetArrayIndex;
};
VSOut vsmain(uint id : SV_VertexID) {
    VSOut o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.pos = float4((uv * float2(2, -2) + float2(-1, 1)) * scale + offset, 0, 1);
    o.extra = uv * 3;
    o.uv = uv;
    o.layer = id / 8; // 0
    return o;
}
float4 psmain(float4 pos : SV_Position, float2 uv : TEXCOORD0, uint layer : SV_RenderTargetArrayIndex) : SV_Target {
    if (uv.x > 0.9) discard;
    float4 t = Tex.Sample(Point, uv * 0.5);
    return float4(t.rgb * (1 - uv.y) + ddx(uv.x) * 8, 1 - layer * 0.25);
}
