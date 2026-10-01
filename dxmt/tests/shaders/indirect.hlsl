// Indirect draws (ExecuteIndirect), as Unreal draws grass and GPU particles: each draw's StartInstanceLocation picks,
// through a per-instance vertex stream, a 2x2-pixel cell of a 64x64 target (32x32 cells, six vertices) to paint white.
float4 vsmain(uint id : SV_VertexID, uint cell : CELL) : SV_Position {
    float2 uv = float2(id == 1 || id == 4 || id == 5, id == 2 || id == 3 || id == 5);
    float2 pixel = float2(cell % 32, cell / 32) * 2 + uv * 2;
    return float4(pixel.x / 32 - 1, 1 - pixel.y / 32, 0, 1);
}
float4 psmain() : SV_Target0 { return 1; }
// Indirect dispatches, as Niagara simulates GPU particles: every thread counts itself.
RWByteAddressBuffer Counter : register(u0);
[numthreads(4, 1, 1)] void csmain() { Counter.InterlockedAdd(0, 1); }
