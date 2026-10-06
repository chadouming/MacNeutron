// XeSS answered by MetalFX (spec §4.2, §7): Wine's builtin libxess.dll driven through XeSS's own API, as Unreal does.
// The library is loaded by full path, the game's way: check.sh passes a copy of this program named libxess.dll (a PE
// that isn't XeSS), so the run fails unless the launcher's libxess=b makes Wine load its builtin instead.
//   d3d12_xess.exe <path to libxess.dll> <mode>...
//   aa | quality | balanced | performance | ultraperf
//       "xess <m> input <w>x<h>" (xessGetOptimalInputResolution for 2560x1440), then 64 jittered frames of the
//       spike's scene (d3d12_upscale.cpp's) through xessD3D12Execute: "xess <m> ok psnr <xess> bilinear <bilinear>"
//       (ok: the upscale beats a bilinear upscale of the last input against the scene: unjittered, or for aa, whose
//       "bilinear" is the last input itself, each pixel's average)
//   cycles
//       Init twice on one context (1920x1080, then 2560x1440), 64 frames, the context destroyed after the last Execute
//       and before its list is submitted: the output is still right. 20 contexts made, upscaling a frame and destroyed.
//       A history reset on a converged context's last frame: closer to bilinear than to the converged upscale.
//       "xess cycles ok psnr <s> bilinear <b> reset <r> growth <MB>". The GPU memory's growth over the 20 contexts is
//       printed, not judged: macOS 27.0.1's MetalFX never frees a temporal upscaler (natively too: one released at
//       once keeps its ~230 MB), so it can't tell an upscaler the bridge released from one it leaked.
//   flags
//       Init with bits 5 and 30 (external descriptor heap, profiling): SUCCESS; with bit 9: INVALID_ARGUMENT;
//       xessGetIntelXeFXVersion 0.0.0, xessGetVersion 2.0.1; a destroyed context: INVALID_CONTEXT. "xess flags ok"
//   unsupported
//       (Wine's wined3d) xessD3D12CreateContext: UNSUPPORTED_DEVICE and a NULL context. "xess unsupported ok"
// Anything else prints "xess <mode> FAIL ..." or a failed call.
//
// The inputs follow Intel's XeSS-SR Developer Guide 2.0: jitterOffset is the projection matrix's (Jx, Jy), which
// moves the samples by -(Jx, Jy) input pixels; motion vectors are the motion from the current frame to the previous
// one, in pixels of the motion texture (low-res, so input pixels).
#include "d3d12_common.hpp"
#include <dxgi1_4.h>
#include <algorithm>
#include <cmath>
#include <string>
#include <thread>
#include <type_traits>

/* The XeSS declarations below (types and values) are from Intel's public inc/xess/xess.h and xess_d3d12.h
 * (github.com/intel/xess, branch main):
 *
 * Copyright (c) 2026 Intel Corporation
 * SPDX-License-Identifier: MIT
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
 * documentation files (the "Software"), to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all copies or substantial portions of
 * the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
 * THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 * TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
#pragma pack(push, 8)
typedef struct _xess_context_handle_t *xess_context_handle_t;
typedef struct _xess_version_t { uint16_t major; uint16_t minor; uint16_t patch; uint16_t reserved; } xess_version_t;
typedef struct _xess_2d_t { uint32_t x; uint32_t y; } xess_2d_t;
typedef xess_2d_t xess_coord_t;
typedef struct _xess_d3d12_execute_params_t {
    ID3D12Resource *pColorTexture;
    ID3D12Resource *pVelocityTexture;
    ID3D12Resource *pDepthTexture;
    ID3D12Resource *pExposureScaleTexture;
    ID3D12Resource *pResponsivePixelMaskTexture;
    ID3D12Resource *pOutputTexture;
    float jitterOffsetX;
    float jitterOffsetY;
    float exposureScale;
    uint32_t resetHistory;
    uint32_t inputWidth;
    uint32_t inputHeight;
    xess_coord_t inputColorBase;
    xess_coord_t inputMotionVectorBase;
    xess_coord_t inputDepthBase;
    xess_coord_t inputResponsiveMaskBase;
    xess_coord_t reserved0;
    xess_coord_t outputColorBase;
    ID3D12DescriptorHeap *pDescriptorHeap;
    uint32_t descriptorHeapOffset;
} xess_d3d12_execute_params_t;
typedef struct _xess_d3d12_init_params_t {
    xess_2d_t outputResolution;
    int qualitySetting; /* xess_quality_settings_t */
    uint32_t initFlags;
    uint32_t creationNodeMask;
    uint32_t visibleNodeMask;
    ID3D12Heap *pTempBufferHeap;
    uint64_t bufferHeapOffset;
    ID3D12Heap *pTempTextureHeap;
    uint64_t textureHeapOffset;
    ID3D12PipelineLibrary *pPipelineLibrary;
} xess_d3d12_init_params_t;
#pragma pack(pop)
enum { XESS_QUALITY_SETTING_ULTRA_PERFORMANCE = 100, XESS_QUALITY_SETTING_PERFORMANCE = 101,
       XESS_QUALITY_SETTING_BALANCED = 102, XESS_QUALITY_SETTING_QUALITY = 103, XESS_QUALITY_SETTING_AA = 106 };
enum { XESS_RESULT_SUCCESS = 0, XESS_RESULT_ERROR_UNSUPPORTED_DEVICE = -1, XESS_RESULT_ERROR_INVALID_ARGUMENT = -4,
       XESS_RESULT_ERROR_INVALID_CONTEXT = -8 };
/* End of Intel's declarations. */
static_assert(sizeof(xess_d3d12_execute_params_t) == 136 && sizeof(xess_d3d12_init_params_t) == 64, "XeSS layout");

static struct {
    int (*CreateContext)(ID3D12Device *, xess_context_handle_t *);
    int (*BuildPipelines)(xess_context_handle_t, ID3D12PipelineLibrary *, bool, uint32_t);
    int (*Init)(xess_context_handle_t, const xess_d3d12_init_params_t *);
    int (*Execute)(xess_context_handle_t, ID3D12GraphicsCommandList *, const xess_d3d12_execute_params_t *);
    int (*DestroyContext)(xess_context_handle_t);
    int (*GetOptimalInputResolution)(xess_context_handle_t, const xess_2d_t *, int, xess_2d_t *, xess_2d_t *, xess_2d_t *);
    int (*GetIntelXeFXVersion)(xess_context_handle_t, xess_version_t *);
    int (*GetVersion)(xess_version_t *);
} X;

static const UINT OW = 2560, OH = 1440, kFrames = 64;
static const auto COPY_DEST = D3D12_RESOURCE_STATE_COPY_DEST, READ = D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                  COPY_SOURCE = D3D12_RESOURCE_STATE_COPY_SOURCE, UAV = D3D12_RESOURCE_STATE_UNORDERED_ACCESS;

// From here to Psnr: d3d12_upscale.cpp's scene and measure, the scale per axis.
static uint16_t ToHalf(float f) { // finite values well inside half's range; tiny ones flush to 0
    uint32_t x;
    memcpy(&x, &f, 4);
    uint32_t sign = x >> 16 & 0x8000;
    int e = (int)(x >> 23 & 255) - 112;
    if (e <= 0)
        return sign;
    return sign | ((e << 10) + (((x & 0x7fffff) + 0x1000) >> 13));
}
static float FromHalf(uint16_t h) {
    int e = h >> 10 & 31, m = h & 1023;
    float v = e ? std::ldexp(1024.0f + m, e - 25) : std::ldexp((float)m, -24);
    return e == 31 ? NAN : (h & 0x8000 ? -v : v);
}

// The spike's scene, in output pixels, at frame t: colour, depth, velocity (output px per frame).
struct Sample { float c[3], d, vx, vy; };
static Sample Scene(float qx, float qy, float t) {
    Sample s;
    float bx = qx - 3.0f * t, by = qy - 1.25f * t;
    int cx = (int)std::floor(bx / 5.0f), cy = (int)std::floor(by / 5.0f);
    float chk = ((cx + cy) & 1) ? 1.0f : 0.15f;
    float rings = 0.5f + 0.5f * std::sin(std::hypot(bx - 1280.0f, by - 720.0f) * 0.37f);
    s.c[0] = chk * 0.8f + 0.2f * rings; s.c[1] = 0.3f + 0.5f * rings * chk; s.c[2] = chk * 0.4f + 0.1f;
    s.d = 0.9f; s.vx = 3.0f; s.vy = 1.25f;
    static const float V[3][2] = {{-6.0f, 2.5f}, {4.5f, -3.5f}, {9.0f, 0.0f}}, C[3][3] = {{4, 3, 1}, {0.1f, 0.8f, 0.3f}, {0.9f, 0.2f, 0.9f}};
    for (int i = 0; i < 3; i++) {
        float px = 640.0f + 600.0f * i + V[i][0] * t, py = 400.0f + 250.0f * i + V[i][1] * t;
        px -= std::floor(px / OW) * OW; // wrap (motion is wrong only at the wrap frame)
        py -= std::floor(py / OH) * OH;
        float dx = qx - px, dy = qy - py, depth = 0.2f + 0.15f * i;
        if (std::hypot(dx, dy) < 150.0f + 40.0f * i && depth < s.d) {
            float st = 0.6f + 0.4f * std::sin(dx * 0.9f + dy * 0.5f);
            for (int k = 0; k < 3; k++) s.c[k] = C[i][k] * st;
            s.d = depth; s.vx = V[i][0]; s.vy = V[i][1];
        }
    }
    return s;
}

static double Halton(int i, int b) { double f = 1, r = 0; while (i > 0) { f /= b; r += f * (i % b); i /= b; } return r; }

// Rows [0, h) split over the CPU's cores (FEX runs x64 threads in parallel).
template <typename F> static void Rows(UINT h, F f) {
    unsigned n = std::max(1u, std::thread::hardware_concurrency());
    std::vector<std::thread> threads;
    for (unsigned k = 0; k < n; k++)
        threads.emplace_back([=] { for (UINT y = k; y < h; y += n) f(y); });
    for (auto &t : threads) t.join();
}

static UINT Pitch(UINT bytes) { return (bytes + 255) & ~255u; }

struct Staging {
    ID3D12Resource *buffer;
    uint8_t *p;
    UINT pitch;
};
static Staging MakeStaging(Gpu &g, UINT row, UINT rows) {
    Staging s = {g.Buffer(D3D12_HEAP_TYPE_UPLOAD, (UINT64)Pitch(row) * rows, D3D12_RESOURCE_STATE_GENERIC_READ), nullptr, Pitch(row)};
    CHECK(s.buffer->Map(0, nullptr, (void **)&s.p));
    return s;
}
static void Copy(Gpu &g, ID3D12Resource *tex, const Staging &s, DXGI_FORMAT format, UINT w, UINT h) {
    D3D12_TEXTURE_COPY_LOCATION dst = {tex, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX};
    dst.SubresourceIndex = 0;
    D3D12_TEXTURE_COPY_LOCATION src = {s.buffer, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT};
    src.PlacedFootprint.Footprint = {format, w, h, 1, s.pitch};
    g.list->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
}

static double Psnr(const std::vector<float> &a, const std::vector<float> &b) { // RGB of RGBA, after x/(1+x)
    auto tm = [](float x) { x = std::max(x, 0.0f); return x / (1.0f + x); };
    double se = 0;
    size_t n = 0;
    for (size_t i = 0; i < a.size(); i += 4)
        for (int c = 0; c < 3; c++) {
            double d = tm(a[i + c]) - tm(b[i + c]);
            se += d * d;
            n++;
        }
    return 10 * std::log10(1.0 / (se / n));
}

static std::string mode; // for messages
[[noreturn]] static void Fail(const char *what, int r) {
    printf("xess %s FAIL %s %d\n", mode.c_str(), what, r);
    exit(1);
}
#define XESS(call) do { int r_ = (call); if (r_ != XESS_RESULT_SUCCESS) Fail(#call, r_); } while (0)

// One input size's textures (colour RGBA16F, D32 depth, RG16F motion vectors) and a 2560x1440 RGBA16F UAV output.
struct Frames {
    Gpu &g;
    UINT iw, ih;
    float sx, sy;
    int phases;
    ID3D12Resource *color, *depth, *motion, *output;
    Staging sc, sd, sm;
    std::vector<float> last; // the last frame's colour as uploaded
    bool uploaded = false;

    Frames(Gpu &g, xess_2d_t in) : g(g), iw(in.x), ih(in.y), sx((float)OW / iw), sy((float)OH / ih), last(iw * ih * 4) {
        phases = (int)std::ceil(8 * sx * sy);
        color = g.Texture(Tex2D(iw, ih, DXGI_FORMAT_R16G16B16A16_FLOAT), COPY_DEST);
        depth = g.Texture(Tex2D(iw, ih, DXGI_FORMAT_D32_FLOAT, 1, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL), COPY_DEST);
        motion = g.Texture(Tex2D(iw, ih, DXGI_FORMAT_R16G16_FLOAT), COPY_DEST);
        output = g.Texture(Tex2D(OW, OH, DXGI_FORMAT_R16G16B16A16_FLOAT, 1, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS), UAV);
        sc = MakeStaging(g, iw * 8, ih);
        sd = MakeStaging(g, iw * 4, ih);
        sm = MakeStaging(g, iw * 4, ih);
    }

    // Frame f's inputs uploaded on the list (not submitted), and the execute parameters for them.
    xess_d3d12_execute_params_t Record(UINT f, bool reset) {
        int i = f % phases + 1;
        float jx = Halton(i, 2) - 0.5, jy = Halton(i, 3) - 0.5; // the projection's jitter: samples move by -(jx, jy)
        Rows(ih, [&](UINT y) {
            auto *c = (uint16_t *)(sc.p + (size_t)y * sc.pitch);
            auto *d = (float *)(sd.p + (size_t)y * sd.pitch);
            auto *m = (uint16_t *)(sm.p + (size_t)y * sm.pitch);
            for (UINT x = 0; x < iw; x++) {
                Sample s = Scene((x + 0.5f - jx) * sx, (y + 0.5f - jy) * sy, (float)f);
                for (int ch = 0; ch < 4; ch++) {
                    c[x * 4 + ch] = ToHalf(ch < 3 ? s.c[ch] : 1.0f);
                    last[((size_t)y * iw + x) * 4 + ch] = FromHalf(c[x * 4 + ch]);
                }
                d[x] = s.d;
                m[x * 2] = ToHalf(-s.vx / sx); // current to previous, in input pixels
                m[x * 2 + 1] = ToHalf(-s.vy / sy);
            }
        });
        if (uploaded)
            for (auto *r : {color, depth, motion})
                g.Barrier(r, READ, COPY_DEST);
        Copy(g, color, sc, DXGI_FORMAT_R16G16B16A16_FLOAT, iw, ih);
        Copy(g, depth, sd, DXGI_FORMAT_R32_TYPELESS, iw, ih);
        Copy(g, motion, sm, DXGI_FORMAT_R16G16_FLOAT, iw, ih);
        for (auto *r : {color, depth, motion})
            g.Barrier(r, COPY_DEST, READ);
        uploaded = true;
        xess_d3d12_execute_params_t p = {};
        p.pColorTexture = color; p.pVelocityTexture = motion; p.pDepthTexture = depth; p.pOutputTexture = output;
        p.jitterOffsetX = jx; p.jitterOffsetY = jy;
        p.exposureScale = 1.0f;
        p.resetHistory = reset;
        p.inputWidth = iw; p.inputHeight = ih;
        return p;
    }

    // The output (submitted), against the scene at frame t and a bilinear upscale of the last input: {xess, bilinear}.
    std::pair<double, double> Read(UINT t) {
        UINT pitch = OW * 8;
        ID3D12Resource *rb = g.Buffer(D3D12_HEAP_TYPE_READBACK, (UINT64)pitch * OH, COPY_DEST);
        g.Barrier(output, UAV, COPY_SOURCE);
        D3D12_TEXTURE_COPY_LOCATION src = {output, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX};
        src.SubresourceIndex = 0;
        D3D12_TEXTURE_COPY_LOCATION dst = {rb, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT};
        dst.PlacedFootprint.Footprint = {DXGI_FORMAT_R16G16B16A16_FLOAT, OW, OH, 1, pitch};
        g.list->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
        g.Barrier(output, COPY_SOURCE, UAV);
        g.Submit();
        uint16_t *p;
        CHECK(rb->Map(0, nullptr, (void **)&p));
        std::vector<float> out((size_t)OW * OH * 4), truth(out.size()), bilinear(out.size());
        for (size_t k = 0; k < out.size(); k++) out[k] = FromHalf(p[k]);
        rb->Unmap(0, nullptr);
        rb->Release();
        Rows(OH, [&](UINT y) {
            for (UINT x = 0; x < OW; x++) {
                // Native AA's target is the pixel's average (4x4 samples), an upscale's its centre (the spike's).
                Sample s = Scene(x + 0.5f, y + 0.5f, (float)t);
                if (sx == 1.0f && sy == 1.0f) {
                    s.c[0] = s.c[1] = s.c[2] = 0;
                    for (int k = 0; k < 16; k++) {
                        Sample q = Scene(x + (k % 4 + 0.5f) / 4, y + (k / 4 + 0.5f) / 4, (float)t);
                        for (int ch = 0; ch < 3; ch++) s.c[ch] += q.c[ch] / 16;
                    }
                }
                float fx = (x + 0.5f) / sx - 0.5f, fy = (y + 0.5f) / sy - 0.5f;
                int x0 = std::clamp((int)std::floor(fx), 0, (int)iw - 1), y0 = std::clamp((int)std::floor(fy), 0, (int)ih - 1);
                int x1 = std::min(x0 + 1, (int)iw - 1), y1 = std::min(y0 + 1, (int)ih - 1);
                float ax = std::clamp(fx - x0, 0.0f, 1.0f), ay = std::clamp(fy - y0, 0.0f, 1.0f);
                size_t o = ((size_t)y * OW + x) * 4;
                for (int ch = 0; ch < 4; ch++) {
                    auto at = [&](int xx, int yy) { return last[((size_t)yy * iw + xx) * 4 + ch]; };
                    truth[o + ch] = ch < 3 ? s.c[ch] : 1.0f;
                    bilinear[o + ch] = (at(x0, y0) * (1 - ax) + at(x1, y0) * ax) * (1 - ay) + (at(x0, y1) * (1 - ax) + at(x1, y1) * ax) * ay;
                }
            }
        });
        for (size_t k = 0; k < out.size(); k++)
            if (!std::isfinite(out[k])) { printf("xess %s FAIL non-finite output\n", mode.c_str()); exit(1); }
        return {Psnr(out, truth), Psnr(bilinear, truth)};
    }
};

static xess_context_handle_t Create(Gpu &g) {
    xess_context_handle_t ctx = nullptr;
    XESS(X.CreateContext(g.device, &ctx));
    return ctx;
}
static void Init(xess_context_handle_t ctx, int quality, UINT w = OW, UINT h = OH, uint32_t flags = 0) {
    xess_d3d12_init_params_t p = {{w, h}, quality, flags};
    XESS(X.Init(ctx, &p));
}
static xess_2d_t Optimal(xess_context_handle_t ctx, int quality) {
    xess_2d_t out = {OW, OH}, opt = {}, lo = {}, hi = {};
    XESS(X.GetOptimalInputResolution(ctx, &out, quality, &opt, &lo, &hi));
    return opt;
}
// Frames [from, to) executed and submitted one by one; the last one's list is submitted after `before_last` runs.
template <typename F> static void Run(Frames &fr, xess_context_handle_t ctx, UINT from, UINT to, F before_last) {
    for (UINT f = from; f < to; f++) {
        auto p = fr.Record(f, f == 0);
        XESS(X.Execute(ctx, fr.g.list, &p));
        if (f + 1 == to) before_last();
        fr.g.Submit();
    }
}

// The GPU memory in use (DXMT: the Metal device's currentAllocatedSize, which MetalFX's upscalers count in).
static double GpuMB() {
    IDXGIFactory1 *factory;
    IDXGIAdapter *adapter;
    IDXGIAdapter3 *adapter3;
    DXGI_QUERY_VIDEO_MEMORY_INFO info = {};
    CHECK(CreateDXGIFactory1(__uuidof(IDXGIFactory1), (void **)&factory));
    CHECK(factory->EnumAdapters(0, &adapter));
    CHECK(adapter->QueryInterface(__uuidof(IDXGIAdapter3), (void **)&adapter3));
    CHECK(adapter3->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &info));
    adapter3->Release(); adapter->Release(); factory->Release();
    return info.CurrentUsage / 1048576.0;
}

static void Quality(int quality) {
    Gpu g;
    xess_context_handle_t ctx = Create(g);
    xess_2d_t in = Optimal(ctx, quality);
    printf("xess %s input %ux%u\n", mode.c_str(), in.x, in.y);
    XESS(X.BuildPipelines(ctx, nullptr, true, 0));
    Init(ctx, quality);
    Frames fr(g, in);
    Run(fr, ctx, 0, kFrames, [] {});
    auto [s, b] = fr.Read(kFrames - 1);
    XESS(X.DestroyContext(ctx));
    printf("xess %s %s psnr %.2f bilinear %.2f\n", mode.c_str(), s > b ? "ok" : "FAIL", s, b);
}

static void Cycles() {
    Gpu g;
    // Re-initialised (another output size), then destroyed before the last list runs.
    xess_context_handle_t ctx = Create(g);
    Init(ctx, XESS_QUALITY_SETTING_BALANCED, 1920, 1080);
    Init(ctx, XESS_QUALITY_SETTING_BALANCED);
    Frames fr(g, Optimal(ctx, XESS_QUALITY_SETTING_BALANCED));
    Run(fr, ctx, 0, kFrames, [&] { XESS(X.DestroyContext(ctx)); });
    auto [s, b] = fr.Read(kFrames - 1);
    // Contexts made, used and destroyed.
    double before = GpuMB();
    for (int i = 0; i < 20; i++) {
        ctx = Create(g);
        Init(ctx, XESS_QUALITY_SETTING_BALANCED);
        Run(fr, ctx, 0, 1, [] {});
        XESS(X.DestroyContext(ctx));
    }
    double growth = GpuMB() - before;
    // A converged history reset on the last frame: what's left is the frame itself.
    ctx = Create(g);
    Init(ctx, XESS_QUALITY_SETTING_BALANCED);
    Run(fr, ctx, 0, kFrames - 1, [] {});
    auto p = fr.Record(kFrames - 1, true);
    XESS(X.Execute(ctx, g.list, &p));
    g.Submit();
    auto [r, rb] = fr.Read(kFrames - 1);
    XESS(X.DestroyContext(ctx));
    bool ok = s > b && r < (s + b) / 2;
    printf("xess cycles %s psnr %.2f bilinear %.2f reset %.2f growth %.0f\n", ok ? "ok" : "FAIL", s, b, r, growth);
}

static void Flags() {
    Gpu g;
    xess_context_handle_t ctx = Create(g);
    xess_d3d12_init_params_t p = {{OW, OH}, XESS_QUALITY_SETTING_BALANCED, 1u << 5 | 1u << 30};
    int known = X.Init(ctx, &p);
    p.initFlags = 1u << 9;
    int unknown = X.Init(ctx, &p);
    xess_version_t fx = {1, 1, 1, 1}, v = {};
    int fxr = X.GetIntelXeFXVersion(ctx, &fx), vr = X.GetVersion(&v);
    XESS(X.DestroyContext(ctx));
    int stale = X.Init(ctx, &p), stale_destroy = X.DestroyContext(ctx), null_destroy = X.DestroyContext(nullptr);
    bool ok = known == XESS_RESULT_SUCCESS && unknown == XESS_RESULT_ERROR_INVALID_ARGUMENT && !fxr && !fx.major &&
              !fx.minor && !fx.patch && !vr && v.major == 2 && !v.minor && v.patch == 1 &&
              stale == XESS_RESULT_ERROR_INVALID_CONTEXT && stale_destroy == XESS_RESULT_ERROR_INVALID_CONTEXT &&
              null_destroy == XESS_RESULT_SUCCESS;
    printf("xess flags %s", ok ? "ok\n" : "FAIL");
    if (!ok)
        printf(" init %d %d xefx %d %u.%u.%u version %d %u.%u.%u stale %d %d null %d\n", known, unknown, fxr, fx.major,
               fx.minor, fx.patch, vr, v.major, v.minor, v.patch, stale, stale_destroy, null_destroy);
}

// A device without DXMT's interface: Wine's own D3D12, or, where it makes none (no Vulkan), an object answering only
// IUnknown, which is all xessD3D12CreateContext asks of it.
struct Bare : IUnknown {
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, void **out) override { *out = nullptr; return E_NOINTERFACE; }
    ULONG STDMETHODCALLTYPE AddRef() override { return 1; }
    ULONG STDMETHODCALLTYPE Release() override { return 1; }
};
static void Unsupported() {
    ID3D12Device *device = nullptr;
    static Bare bare;
    HRESULT hr = D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device), (void **)&device);
    if (FAILED(hr)) {
        printf("info no D3D12 device (0x%08lx): a bare IUnknown instead\n", (unsigned long)hr);
        device = (ID3D12Device *)&bare;
    }
    xess_context_handle_t ctx = (xess_context_handle_t)1;
    int r = X.CreateContext(device, &ctx);
    bool ok = r == XESS_RESULT_ERROR_UNSUPPORTED_DEVICE && !ctx;
    printf("xess unsupported %s", ok ? "ok\n" : "FAIL");
    if (!ok) printf(" %d %p\n", r, (void *)ctx);
}

int main(int argc, char **argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    if (argc < 3) { printf("usage: d3d12_xess.exe <libxess.dll> <mode>...\n"); return 2; }
    HMODULE xess = LoadLibraryA(argv[1]);
    if (!xess) { printf("xess FAIL LoadLibrary %s: %lu\n", argv[1], GetLastError()); return 1; }
    static const char *const exports[] = {
        "xessD3D12CreateContext", "xessD3D12BuildPipelines", "xessD3D12Init", "xessD3D12GetInitParams",
        "xessD3D12Execute", "xessDestroyContext", "xessGetOptimalInputResolution", "xessGetInputResolution",
        "xessGetIntelXeFXVersion", "xessSetLoggingCallback", "xessSetJitterScale", "xessSetVelocityScale",
        "xessGetJitterScale", "xessGetVelocityScale", "xessGetProperties", "xessIsOptimalDriver",
        "xessGetPipelineBuildStatus", "xessGetVersion"};
    for (auto *name : exports)
        if (!GetProcAddress(xess, name)) { printf("xess FAIL no export %s\n", name); return 1; }
    auto get = [&](auto &f, const char *name) { f = (std::remove_reference_t<decltype(f)>)GetProcAddress(xess, name); };
    get(X.CreateContext, "xessD3D12CreateContext");
    get(X.BuildPipelines, "xessD3D12BuildPipelines");
    get(X.Init, "xessD3D12Init");
    get(X.Execute, "xessD3D12Execute");
    get(X.DestroyContext, "xessDestroyContext");
    get(X.GetOptimalInputResolution, "xessGetOptimalInputResolution");
    get(X.GetIntelXeFXVersion, "xessGetIntelXeFXVersion");
    get(X.GetVersion, "xessGetVersion");
    for (int a = 2; a < argc; a++) {
        mode = argv[a];
        if (mode == "aa") Quality(XESS_QUALITY_SETTING_AA);
        else if (mode == "quality") Quality(XESS_QUALITY_SETTING_QUALITY);
        else if (mode == "balanced") Quality(XESS_QUALITY_SETTING_BALANCED);
        else if (mode == "performance") Quality(XESS_QUALITY_SETTING_PERFORMANCE);
        else if (mode == "ultraperf") Quality(XESS_QUALITY_SETTING_ULTRA_PERFORMANCE);
        else if (mode == "cycles") Cycles();
        else if (mode == "flags") Flags();
        else if (mode == "unsupported") Unsupported();
        else { printf("unknown mode %s\n", mode.c_str()); return 2; }
    }
    return 0;
}
