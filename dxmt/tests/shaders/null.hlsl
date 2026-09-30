// Null descriptors (D3D12 stubs spec, batch 2): reads through null SRVs of every type and their sizes, and writes
// through null UAVs, into u0. Every value must be what D3DMetal gives.
Buffer<float4> TypedBuf : register(t0);
StructuredBuffer<uint> StructBuf : register(t1);
ByteAddressBuffer RawBuf : register(t2);
Texture1D<float4> Tex1D : register(t3);
Texture1DArray<float4> Tex1DArray : register(t4);
Texture2D<float4> Tex2D : register(t5);
Texture2DArray<float4> Tex2DArray : register(t6);
Texture2DMS<float4> Tex2DMS : register(t7);
Texture3D<float4> Tex3D : register(t8);
TextureCube<float4> TexCube : register(t9);
TextureCubeArray<float4> TexCubeArray : register(t10);
RWByteAddressBuffer Out : register(u0);
RWTexture2D<float4> NullUav2D : register(u1);
RWBuffer<float4> NullUavBuf : register(u2);
SamplerState Point : register(s0);

void put(uint slot, float4 v) { Out.Store4(slot * 16, asuint(v)); }
void put(uint slot, uint4 v) { Out.Store4(slot * 16, v); }

[numthreads(1, 1, 1)]
void main() {
    put(0, TypedBuf[0]);
    put(1, uint4(StructBuf[0], RawBuf.Load(0), 0, 0));
    put(2, Tex1D.Load(int2(0, 0)));
    put(3, Tex1DArray.Load(int3(0, 0, 0)));
    put(4, Tex2D.Load(int3(0, 0, 0)));
    put(5, Tex2DArray.Load(int4(0, 0, 0, 0)));
    put(6, Tex2DMS.Load(int2(0, 0), 0));
    put(7, Tex3D.Load(int4(0, 0, 0, 0)));
    put(8, TexCube.SampleLevel(Point, float3(1, 0, 0), 0));
    put(9, TexCubeArray.SampleLevel(Point, float4(1, 0, 0, 0), 0));
    put(10, Tex2D.SampleLevel(Point, float2(0.5, 0.5), 0));
    uint w, h, e, levels, samples;
    TypedBuf.GetDimensions(w);
    StructBuf.GetDimensions(h, e);
    put(11, uint4(w, h, e, 0));
    Tex2D.GetDimensions(0, w, h, levels);
    put(12, uint4(w, h, levels, 0));
    Tex2DArray.GetDimensions(0, w, h, e, levels);
    put(13, uint4(w, h, e, levels));
    Tex2DMS.GetDimensions(w, h, samples);
    put(14, uint4(w, h, samples, 0));
    Tex3D.GetDimensions(0, w, h, e, levels);
    put(15, uint4(w, h, e, levels));
    NullUav2D[uint2(0, 0)] = float4(1, 2, 3, 4);  // discarded
    NullUavBuf[0] = float4(5, 6, 7, 8);           // discarded
    put(16, NullUav2D[uint2(0, 0)]);
    put(17, NullUavBuf[0]);
}
