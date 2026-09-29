// Out of scope on purpose (dynamic resources): DXMT must fail this pipeline with E_NOTIMPL and name the op.
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    RWByteAddressBuffer o = ResourceDescriptorHeap[0];
    o.Store(id.x * 4, id.x);
}
