// Layered rendering into a 3D texture, as Unreal fills its translucency lighting volume: each instance's triangle
// goes to the slice its vertex shader names in SV_RenderTargetArrayIndex (no geometry shader).
struct VSOut { float4 pos : SV_Position; float4 color : COLOR; uint layer : SV_RenderTargetArrayIndex; };
VSOut vsmain(uint id : SV_VertexID, uint inst : SV_InstanceID) {
    VSOut o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    o.color = float4((inst + 1) * 0.25, 1 - inst * 0.25, 0.5, 1);
    o.layer = inst;
    return o;
}
float4 psmain(VSOut i) : SV_Target { return i.color; }
