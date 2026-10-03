// GPU efficiency spec E5: buffer loads in, straddling and out of their views' bounds (d3d12_bounds).
// raw: a 16-dword view, from dword 4, of a 32-dword buffer holding 1..32; structured: a 4-element view (uint4) of an 8-element buffer.
ByteAddressBuffer raw : register(t0);
StructuredBuffer<uint4> structured : register(t1);
RWByteAddressBuffer result : register(u0);

[numthreads(1, 1, 1)]
void csmain() {
    result.Store4(0, raw.Load4(0));    // in
    result.Store4(16, raw.Load4(56));  // straddling: dwords 14 and 15 in, 16 and 17 out
    result.Store4(32, raw.Load4(64));  // out
    result.Store2(48, raw.Load2(60));  // straddling, two wide
    result.Store4(64, structured[3]);  // in
    result.Store4(80, structured[4]);  // out
    result.Store(96, raw.Load(60));    // in, the view's last dword (SM 6.0 loads name all four components)
    result.Store2(100, raw.Load2(56)); // in, the view's last two dwords
    result.Store4(112, raw.Load4(0xFFFFFFF0)); // out: an offset whose end wraps 32 bits
}
