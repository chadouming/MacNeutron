// A triangle from SV_VertexID: the smallest vertex/pixel pair for DXIL pipeline tests.
struct VSOut { float4 pos : SV_Position; float3 color : COLOR; };

VSOut vsmain(uint id : SV_VertexID) {
    VSOut o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    o.color = float3(uv, 1 - uv.x);
    return o;
}

float4 psmain(VSOut i) : SV_Target { return float4(i.color, 1); }
