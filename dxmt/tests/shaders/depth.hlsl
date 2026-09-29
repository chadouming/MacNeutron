// Depth-stencil test (SMITE 2's lobby): quads at a depth, from a root CBV; and the depth read back through an SRV.
cbuffer Draw : register(b0) { float4 rect; float4 color; float z; };
Texture2D<float> Depth : register(t0);
float4 vsmain(uint id : SV_VertexID) : SV_Position {
    float2 c = float2((0x32u >> id) & 1, (0x2cu >> id) & 1); // two triangles: (0,0) (1,0) (0,1), (0,1) (1,0) (1,1)
    return float4(lerp(rect.xy, rect.zw, c), z, 1);
}
float4 psmain(float4 pos : SV_Position) : SV_Target { return color; }
float4 psdepth(float4 pos : SV_Position) : SV_Target {
    float d = Depth.Load(int3(pos.xy, 0));
    return float4(d, d, d, 1);
}
