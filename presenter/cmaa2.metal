///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2018, Intel Corporation
//
// Licensed under the Apache License, Version 2.0 ( the "License" );
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//
// Conservative Morphological Anti-Aliasing, version: 2.3
//
// Author(s):       Filip Strugar
//
// More info:       https://github.com/GameTechDev/CMAA2
//
// Please see https://github.com/GameTechDev/CMAA2/README.md for additional information and a basic integration guide.
//
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//
// MODIFIED: ported to the Metal Shading Language by MacNeutron from Projects/CMAA2/CMAA2/CMAA2.hlsl (GameTechDev/CMAA2,
// commit 071c6b0), for MacNeutron's presenter (presenter/present.m), which runs it in place on a game's frame through an
// sRGB view. The changes from the HLSL:
//  - the single-sample path only, at upstream's defaults: luma path 1 (sqrt luma computed in place), preset HIGH
//    (threshold 0.07), c_maxLineLength 86, edges packed 2x4 bit into a half-width R8Uint texture, the 768-item
//    threadgroup expansion, float precision, typed store; with CMAA2_EXTRA_SHARPNESS 1, its constants written in;
//  - a blend colour is packed with Metal's pack_float_to_srgb_unorm4x8, not MiniEngine's R11G11B10_E4 packing, and
//    carries the pixel's own alpha, which the apply pass writes back (upstream writes alpha 0);
//  - the R32_UINT list-heads texture is a device atomic_uint buffer (the same traffic, no texture atomics);
//  - D3D drops out-of-bounds UAV writes and returns 0 for out-of-bounds loads, Metal does neither: colour loads are
//    clamped, loadEdge returns 0 off the image, every write is bounds-guarded, and the apply pass stops at a list index
//    past the item buffer.
#include <metal_stdlib>
using namespace metal;

constant float kThr = 0.07;    // edge threshold, preset HIGH
constant float kLCA = 0.15;    // local contrast adaptation (extra sharpness)
constant float kSSB = 0.07;    // simple shape blurriness (extra sharpness)
constant float kDamp = 0.11;   // dampening effect (extra sharpness)
constant float kSym = 0.22;
constant uint kMaxLine = 86;
#define SLM_ITEMS 768

struct Caps { uint candCap, itemCap, locCap, headsW, W, H; };

static inline uint packEdges(float4 e) { return (uint)dot(e, float4(1, 2, 4, 8)); }
static inline float4 unpackEdgesF(uint v) { return float4((v & 1) != 0, (v & 2) != 0, (v & 4) != 0, (v & 8) != 0); }
static inline float3 loadColor(texture2d<float> s, int2 p) {
  return s.read(uint2(clamp(p, int2(0), int2(s.get_width() - 1, s.get_height() - 1)))).rgb;
}
static inline uint loadEdge(texture2d<uint> e, int2 p, constant Caps &cp) {
  if (p.x < 0 || p.y < 0 || p.x >= int(cp.W) || p.y >= int(cp.H)) return 0;   // D3D OOB load returns 0
  uint v = e.read(uint2(uint(p.x) / 2, uint(p.y))).x;
  return (v >> ((uint(p.x) % 2) * 4)) & 0xF;
}

static void storeColorSample(int2 p, float3 color, bool complexShape, texture2d<float> src, device atomic_uint *ctrl,
                             device atomic_uint *heads, device uint2 *items, device uint *locs, constant Caps &cp) {
  if (p.x < 0 || p.y < 0 || p.x >= int(cp.W) || p.y >= int(cp.H)) return;
  uint idx = atomic_fetch_add_explicit(&ctrl[12], 1u, memory_order_relaxed);
  if (idx >= cp.itemCap) return;
  uint2 q = uint2(p) / 2;
  uint offXY = (uint(p.y) % 2) * 2 + (uint(p.x) % 2);
  uint header = (offXY << 30) | (uint(complexShape) << 26);
  uint orig = atomic_exchange_explicit(&heads[q.y * cp.headsW + q.x], idx | header, memory_order_relaxed);
  items[idx] = uint2(orig, pack_float_to_srgb_unorm4x8(float4(saturate(color), src.read(uint2(p)).a)));
  if (orig == 0xFFFFFFFFu) {
    uint e = atomic_fetch_add_explicit(&ctrl[8], 1u, memory_order_relaxed);
    if (e < cp.locCap) locs[e] = (q.x << 16) | q.y;
  }
}

// ---------------------------------------------------------------- EdgesColor2x2CS (16x16 threads, 14x14 2x2 output)
static inline void ldq(threadgroup float4 *sH, threadgroup float4 *sV, int a, thread float2 &e00, thread float2 &e10,
                       thread float2 &e01, thread float2 &e11) {
  float4 h = sH[a]; e00.y = h.x; e10.y = h.y; e01.y = h.z; e11.y = h.w;
  float4 v = sV[a]; e00.x = v.x; e10.x = v.y; e01.x = v.z; e11.x = v.w;
}
static inline float lcaV(int x, int y, thread float2 (&n)[4][4]) {
  return max(max(n[x + 1][y + 0].y, n[x + 1][y + 1].y), max(n[x + 2][y + 0].y, n[x + 2][y + 1].y)) * kLCA;
}
static inline float lcaH(int x, int y, thread float2 (&n)[4][4]) {
  return max(max(n[x + 0][y + 1].x, n[x + 1][y + 1].x), max(n[x + 0][y + 2].x, n[x + 1][y + 2].x)) * kLCA;
}

kernel void cmaa2_edges(texture2d<float> src [[texture(0)]], texture2d<uint, access::write> edgesOut [[texture(1)]],
                        device atomic_uint *ctrl [[buffer(0)]], device uint *cands [[buffer(1)]],
                        device atomic_uint *heads [[buffer(4)]], constant Caps &cp [[buffer(6)]],
                        uint2 gid [[threadgroup_position_in_grid]], uint2 tid [[thread_position_in_threadgroup]]) {
  threadgroup float4 sV[256], sH[256];
  int2 pixelPos = (int2(gid) * 14 + int2(tid) - 1) * 2;
  const int2 qo[4] = {int2(0, 0), int2(1, 0), int2(0, 1), int2(1, 1)};
  const int rs = 16, ca = int(tid.x + tid.y * 16);
  bool inOut = !(tid.x == 15 || tid.x == 0 || tid.y == 15 || tid.y == 0);
  uint4 outEdges = 0;

  float l[8];
  for (int i = 0; i < 8; i++) l[i] = dot(sqrt(loadColor(src, pixelPos + int2(i % 3, i / 3))), float3(0.299, 0.587, 0.114));
  float2 qe0 = float2(abs(l[0] - l[1]), abs(l[0] - l[3]));
  float2 qe1 = float2(abs(l[1] - l[2]), abs(l[1] - l[4]));
  float2 qe2 = float2(abs(l[3] - l[4]), abs(l[3] - l[6]));
  float2 qe3 = float2(abs(l[4] - l[5]), abs(l[4] - l[7]));
  sV[ca] = float4(qe0.x, qe1.x, qe2.x, qe3.x);
  sH[ca] = float4(qe0.y, qe1.y, qe2.y, qe3.y);
  threadgroup_barrier(mem_flags::mem_threadgroup);

  if (inOut) {
    float2 topRow = sH[ca - rs].zw, leftCol = sV[ca - 1].yw;
    bool someNonZero = any((float4(qe0, qe1) + float4(qe2, qe3) + float4(topRow, leftCol)) != 0.0);
    if (someNonZero) {
      if (pixelPos.x < int(cp.W) && pixelPos.y < int(cp.H))
        atomic_store_explicit(&heads[uint(pixelPos.y / 2) * cp.headsW + uint(pixelPos.x / 2)], 0xFFFFFFFFu, memory_order_relaxed);
      float2 d0, d1, d2, n[4][4];
      ldq(sH, sV, ca - rs - 1, d0, d1, d2, n[0][0]);
      ldq(sH, sV, ca - rs, d0, d1, n[1][0], n[2][0]);
      ldq(sH, sV, ca - rs + 1, d0, d1, n[3][0], d2);
      ldq(sH, sV, ca - 1, d0, n[0][1], d1, n[0][2]);
      ldq(sH, sV, ca + 1, n[3][1], d0, n[3][2], d1);
      ldq(sH, sV, ca - 1 + rs, d0, n[0][3], d1, d2);
      ldq(sH, sV, ca + rs, n[1][3], n[2][3], d0, d1);
      n[1][0].y = topRow[0]; n[2][0].y = topRow[1]; n[0][1].x = leftCol[0]; n[0][2].x = leftCol[1];
      n[1][1] = qe0; n[2][1] = qe1; n[1][2] = qe2; n[2][2] = qe3;

      topRow[0] = (topRow[0] - lcaH(0, -1, n)) > kThr;
      topRow[1] = (topRow[1] - lcaH(1, -1, n)) > kThr;
      leftCol[0] = (leftCol[0] - lcaV(-1, 0, n)) > kThr;
      leftCol[1] = (leftCol[1] - lcaV(-1, 1, n)) > kThr;
      float4 ce[4];
      ce[0].x = (qe0.x - lcaV(0, 0, n)) > kThr; ce[0].y = (qe0.y - lcaH(0, 0, n)) > kThr;
      ce[1].x = (qe1.x - lcaV(1, 0, n)) > kThr; ce[1].y = (qe1.y - lcaH(1, 0, n)) > kThr;
      ce[2].x = (qe2.x - lcaV(0, 1, n)) > kThr; ce[2].y = (qe2.y - lcaH(0, 1, n)) > kThr;
      ce[3].x = (qe3.x - lcaV(1, 1, n)) > kThr; ce[3].y = (qe3.y - lcaH(1, 1, n)) > kThr;
      ce[0].z = leftCol[0]; ce[1].z = ce[0].x; ce[2].z = leftCol[1]; ce[3].z = ce[2].x;
      ce[0].w = topRow[0]; ce[1].w = topRow[1]; ce[2].w = ce[0].y; ce[3].w = ce[1].y;
      for (int i = 0; i < 4; i++) {
        int2 lp = pixelPos + qo[i];
        float4 e = ce[i];
        bool cand = (e.x * e.y + e.y * e.z + e.z * e.w + e.w * e.x) != 0;
        if (cand && lp.x < int(cp.W) && lp.y < int(cp.H)) {
          uint ci = atomic_fetch_add_explicit(&ctrl[4], 1u, memory_order_relaxed);
          if (ci < cp.candCap) cands[ci] = (uint(lp.x) << 18) | uint(lp.y);
        }
        outEdges[i] = packEdges(e);
      }
    }
  }
  if (inOut) {
    uint ex = uint(pixelPos.x) / 2;
    if (ex < edgesOut.get_width()) {
      if (uint(pixelPos.y) < cp.H) edgesOut.write(uint4((outEdges[1] << 4) | outEdges[0]), uint2(ex, pixelPos.y));
      if (uint(pixelPos.y) + 1 < cp.H) edgesOut.write(uint4((outEdges[3] << 4) | outEdges[2]), uint2(ex, pixelPos.y + 1));
    }
  }
}

// ---------------------------------------------------------------- ComputeDispatchArgsCS
kernel void cmaa2_args(device atomic_uint *ctrl [[buffer(0)]], device uint *args [[buffer(5)]], constant Caps &cp [[buffer(6)]],
                       uint2 gid [[threadgroup_position_in_grid]]) {
  if (gid.x == 1) {
    uint n = min(atomic_load_explicit(&ctrl[4], memory_order_relaxed), cp.candCap);
    args[0] = (n + 127) / 128; args[1] = 1; args[2] = 1;
    atomic_store_explicit(&ctrl[3], n, memory_order_relaxed);
  } else if (gid.y == 1) {
    uint n = min(atomic_load_explicit(&ctrl[8], memory_order_relaxed), cp.locCap);
    args[0] = 1; args[1] = (n + 31) / 32; args[2] = 1;
    atomic_store_explicit(&ctrl[3], n, memory_order_relaxed);
    atomic_store_explicit(&ctrl[4], 0u, memory_order_relaxed);
    atomic_store_explicit(&ctrl[8], 0u, memory_order_relaxed);
    atomic_store_explicit(&ctrl[12], 0u, memory_order_relaxed);
  }
}

// ---------------------------------------------------------------- ProcessCandidatesCS (128 threads)
static float4 simpleShapeBlend(float4 edges, float4 eL, float4 eR, float4 eT, float4 eB) {
  float fromRight = edges.r, fromBelow = edges.g, fromLeft = edges.b, fromAbove = edges.a;
  float blur = kSSB;
  float nE = dot(edges, float4(1));
  float nAll = dot(eL.bga + eR.rga + eT.rba + eB.rgb, float3(1));
  if (nE == 2) {   // dontTestShapeValidity == true at the only call site
    blur *= 0.75;
    float k = 0.9f;
    fromRight += k * (edges.g * eT.r * (1.0 - eL.g) + edges.a * eB.r * (1.0 - eL.a));
    fromBelow += k * (edges.b * eR.g * (1.0 - eT.b) + edges.r * eL.g * (1.0 - eT.r));
    fromLeft  += k * (edges.a * eB.b * (1.0 - eR.a) + edges.g * eT.b * (1.0 - eR.g));
    fromAbove += k * (edges.r * eL.a * (1.0 - eB.r) + edges.b * eR.a * (1.0 - eB.b));
  }
  blur *= saturate(1.15 - nAll / 8.0);
  return float4(fromLeft, fromAbove, fromRight, fromBelow) * blur;
}
static void detectZsH(float4 e, float4 m1, float4 p1, float4 p2, thread float &inv, thread float &nor) {
  inv = e.r * e.g * p1.a;
  inv *= 2.0 + ((m1.g + p2.a)) - (e.a + p1.g) - 0.7 * (p2.g + m1.a + e.b + p1.r);
  nor = e.r * e.a * p1.g;
  nor *= 2.0 + ((m1.a + p2.g)) - (e.g + p1.a) - 0.7 * (p2.a + m1.g + e.b + p1.r);
}
static void findZLineLengths(thread float &lenL, thread float &lenR, int2 sp, bool horizontal, bool invZ, float2 stepRight,
                             texture2d<uint> edges, constant Caps &cp) {
  uint mL = horizontal ? 0x08u : 0x04u, mR = horizontal ? 0x02u : 0x01u;
  if (invZ) { uint t = mL; mL = mR; mR = t; }
  bool cL = true, cR = true;
  lenL = 1; lenR = 1;
  for (;;) {
    uint eL = loadEdge(edges, int2(float2(sp) - stepRight * lenL), cp);
    uint eR = loadEdge(edges, int2(float2(sp) + stepRight * (lenR + 1)), cp);
    cL = cL && ((eL & mL) == mL);
    cR = cR && ((eR & mR) == mR);
    lenL += cL; lenR += cR;
    float maxLR = max(lenR, lenL);
    if (!cL && !cR) maxLR = (float)kMaxLine;
    if (maxLR >= min((float)kMaxLine, 1.20 * min(lenR, lenL) - 0.20)) break;
  }
}
static bool collectBlendZs(int2 sp, bool horizontal, bool invZ, float sqs, float lenL, float lenR, threadgroup atomic_uint &cnt,
                           threadgroup uint2 *slm) {
  float leftOdd = kSym * fmod(lenL, 2.0), rightOdd = kSym * fmod(lenR, 2.0);
  float dampen = saturate((lenL + lenR - sqs) * kDamp);
  float loopFrom = -floor((lenL + 1) / 2) + 1.0, loopTo = floor((lenR + 1) / 2);
  uint n = uint(loopTo - loopFrom + 1);
  uint idx = atomic_fetch_add_explicit(&cnt, n, memory_order_relaxed);
  if (idx + n > SLM_ITEMS) return false;
  float total = (loopTo - loopFrom) + 1 - leftOdd - rightOdd, step = 1.0 / total;
  float fromK = (0.5 - leftOdd - loopFrom) * step;
  uint hdr = (uint(sp.x) << 18) | uint(sp.y), stat = (uint(horizontal) << 31) | (uint(invZ) << 30);
  for (float i = loopFrom; i <= loopTo; i++) {
    float second = (i > 0), srcOff = 1.0 - second * 2.0;
    float k = ((step * i + fromK) * srcOff + second) * dampen;
    slm[idx++] = uint2(hdr, stat | (uint(i + 256) << 20) | (uint(srcOff + 256) << 10) | uint(saturate(k) * 1023 + 0.5));
  }
  return true;
}
static void blendZs(int2 sp, bool horizontal, bool invZ, float sqs, float lenL, float lenR, float2 stepRight, texture2d<float> src,
                    device atomic_uint *ctrl, device atomic_uint *heads, device uint2 *items, device uint *locs, constant Caps &cp) {
  float2 dir = horizontal ? float2(0, -1) : float2(-1, 0);
  if (invZ) dir = -dir;
  float leftOdd = kSym * fmod(lenL, 2.0), rightOdd = kSym * fmod(lenR, 2.0);
  float dampen = saturate((lenL + lenR - sqs) * kDamp);
  float loopFrom = -floor((lenL + 1) / 2) + 1.0, loopTo = floor((lenR + 1) / 2);
  float total = (loopTo - loopFrom) + 1 - leftOdd - rightOdd, step = 1.0 / total;
  float fromK = (0.5 - leftOdd - loopFrom) * step;
  for (float i = loopFrom; i <= loopTo; i++) {
    float second = (i > 0), srcOff = 1.0 - second * 2.0;
    float k = ((step * i + fromK) * srcOff + second) * dampen;
    float2 pp = float2(sp) + stepRight * i;
    float3 c0 = loadColor(src, int2(pp)), c1 = loadColor(src, int2(pp + dir * srcOff));
    storeColorSample(int2(pp), mix(c0, c1, k), true, src, ctrl, heads, items, locs, cp);
  }
}

kernel void cmaa2_process(texture2d<float> src [[texture(0)]], texture2d<uint> edges [[texture(1)]],
                          device atomic_uint *ctrl [[buffer(0)]], device uint *cands [[buffer(1)]], device uint *locs [[buffer(2)]],
                          device uint2 *items [[buffer(3)]], device atomic_uint *heads [[buffer(4)]], constant Caps &cp [[buffer(6)]],
                          uint gtid [[thread_position_in_grid]], uint ltid [[thread_position_in_threadgroup]]) {
  threadgroup atomic_uint sCount;
  threadgroup uint2 sItems[SLM_ITEMS];
  if (ltid == 0) atomic_store_explicit(&sCount, 0u, memory_order_relaxed);
  threadgroup_barrier(mem_flags::mem_threadgroup);

  uint num = atomic_load_explicit(&ctrl[3], memory_order_relaxed);
  if (gtid < num) {
    uint id = cands[gtid];
    int2 p = int2(id >> 18, id & 0x3FFF);
    float4 e = unpackEdgesF(loadEdge(edges, p, cp));
    float4 eL = unpackEdgesF(loadEdge(edges, p + int2(-1, 0), cp)), eR = unpackEdgesF(loadEdge(edges, p + int2(1, 0), cp));
    float4 eB = unpackEdgesF(loadEdge(edges, p + int2(0, 1), cp)), eT = unpackEdgesF(loadEdge(edges, p + int2(0, -1), cp));
    {
      float4 bv = simpleShapeBlend(e, eL, eR, eT, eB);
      float3 oc = loadColor(src, p) * (1.0 - dot(bv, float4(1)));
      if (bv.x > 0.0) oc += bv.x * loadColor(src, p + int2(-1, 0));
      if (bv.y > 0.0) oc += bv.y * loadColor(src, p + int2(0, -1));
      if (bv.z > 0.0) oc += bv.z * loadColor(src, p + int2(1, 0));
      if (bv.w > 0.0) oc += bv.w * loadColor(src, p + int2(0, 1));
      storeColorSample(p, oc, false, src, ctrl, heads, items, locs, cp);
    }
    float inv, nor, maxScore;
    bool horizontal = true, invZ = false;
    {
      float4 p2 = unpackEdgesF(loadEdge(edges, p + int2(2, 0), cp));
      detectZsH(e, eL, eR, p2, inv, nor);
      maxScore = max(inv, nor);
      if (maxScore > 0) invZ = inv > nor;
    }
    {
      float4 p2 = unpackEdgesF(loadEdge(edges, p + int2(0, -2), cp));
      detectZsH(e.argb, eB.argb, eT.argb, p2.argb, inv, nor);
      float vs = max(inv, nor);
      if (vs > maxScore) { maxScore = vs; horizontal = false; invZ = inv > nor; }
    }
    if (maxScore > 0) {
      float sqs = round(clamp(4.0 - maxScore, 0.0, 3.0));
      float2 stepRight = horizontal ? float2(1, 0) : float2(0, -1);
      float lenL, lenR;
      findZLineLengths(lenL, lenR, p, horizontal, invZ, stepRight, edges, cp);
      lenL -= sqs; lenR -= sqs;
      if ((lenL + lenR) >= 5.0) {
        if (!collectBlendZs(p, horizontal, invZ, sqs, lenL, lenR, sCount, sItems))
          blendZs(p, horizontal, invZ, sqs, lenL, lenR, stepRight, src, ctrl, heads, items, locs, cp);
      }
    }
  }
  threadgroup_barrier(mem_flags::mem_threadgroup);
  uint total = min((uint)SLM_ITEMS, atomic_load_explicit(&sCount, memory_order_relaxed));
  uint loops = (total + 127 - ltid) / 128;
  for (uint lp = 0; lp < loops; lp++) {
    uint2 v = sItems[lp * 128 + ltid];
    int2 start = int2(v.x >> 18, v.x & 0x3FFF);
    bool h = (v.y >> 31) & 1, iz = (v.y >> 30) & 1;
    float stepIdx = float((v.y >> 20) & 0x3FF) - 256.0, srcOff = float((v.y >> 10) & 0x3FF) - 256.0;
    float k = float(v.y & 0x3FF) / 1023.0;
    float2 sr = h ? float2(1, 0) : float2(0, -1), dir = h ? float2(0, -1) : float2(-1, 0);
    if (iz) dir = -dir;
    int2 pp = int2(float2(start) + sr * stepIdx);
    float3 c0 = loadColor(src, pp), c1 = loadColor(src, int2(float2(pp) + dir * srcOff));
    storeColorSample(pp, mix(c0, c1, k), true, src, ctrl, heads, items, locs, cp);
  }
}

// ---------------------------------------------------------------- DeferredColorApply2x2CS (4x32 threads, swapped)
kernel void cmaa2_apply(texture2d<float, access::write> out [[texture(0)]], device atomic_uint *ctrl [[buffer(0)]],
                        device uint *locs [[buffer(2)]], device uint2 *items [[buffer(3)]], device atomic_uint *heads [[buffer(4)]],
                        constant Caps &cp [[buffer(6)]], uint2 dtid [[thread_position_in_grid]], uint2 ltid [[thread_position_in_threadgroup]]) {
  uint num = atomic_load_explicit(&ctrl[3], memory_order_relaxed);
  uint cand = dtid.y, qoff = ltid.x;
  if (cand >= num) return;
  uint id = locs[cand];
  uint2 q = uint2(id >> 16, id & 0xFFFF);
  const uint2 qo[4] = {uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 1)};
  uint2 p = q * 2 + qo[qoff];
  uint head = atomic_load_explicit(&heads[q.y * cp.headsW + q.x], memory_order_relaxed);
  float4 acc = 0;
  float weights = 0;
  for (uint i = 0; head != 0xFFFFFFFFu && i < 32; i++) {
    uint off = (head >> 30) & 3, at = head & ((1u << 26) - 1);
    bool cx = (head >> 26) & 1;
    if (at >= cp.itemCap) break;
    uint2 v = items[at];
    head = v.x;
    if (off == qoff) { float w = 0.8 + 1.0 * float(cx); acc += unpack_unorm4x8_srgb_to_float(v.y) * w; weights += w; }
  }
  if (weights == 0 || p.x >= cp.W || p.y >= cp.H) return;
  out.write(acc / weights, p);
}
