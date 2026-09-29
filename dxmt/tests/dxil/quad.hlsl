#include "common.hlsli"
// Quad operations in a compute shader (SM 6.6): a quad is four consecutive lanes (SMITE 2 uses QuadReadAcross*).
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint i = id.x, w = InWord(i); float f = InFloat(i); int s = (int)w;
    Put(id, 0, QuadReadAcrossX(w)); Put(id, 1, QuadReadAcrossY(w)); Put(id, 2, QuadReadAcrossDiagonal(w));
    PutF(id, 3, QuadReadAcrossX(f)); Put(id, 4, (uint)QuadReadAcrossY(s)); Put(id, 5, QuadReadLaneAt(w, 2));
    PutF(id, 6, QuadReadLaneAt(f, i & 3));
}
