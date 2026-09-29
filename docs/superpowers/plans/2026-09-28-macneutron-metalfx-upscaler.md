# MacNeutron MetalFX Upscaler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Games whose image is smaller than the pixels their window covers are upscaled with Apple's MetalFX spatial scaler instead of macOS's nearest-neighbour stretch. It's on by default and can be turned off per game.

**Architecture:** A universal Objective-C library, `libmacneutron-present.dylib`, is injected by MacNeutron's launcher into a game's Wine processes. It swaps `-[CAMetalLayer nextDrawable]` at load, and on first use `presentDrawable:` of the device's command buffer class. When a drawable is smaller than its layer's bounds times the window's backing scale, it MetalFX-upscales the drawable into an overlay sublayer and presents that. MacNeutron ships the library in the app, installs it into the tool folder, and adds it to `DYLD_INSERT_LIBRARIES` unless the game opts out.

**Tech Stack:** Objective-C (ARC), Metal, MetalFX, QuartzCore, AppKit; Swift 6 (swift-testing); mingw-w64 for the D3D11 test program; the installed winecx-gptk runtime with GPTK 4.0b2.

**Spec:** `docs/superpowers/specs/2026-09-28-macneutron-metalfx-upscaler-design.md`

## Global Constraints

- Swift 6 language mode, swift-testing; `swift test` stays green (153 tests before Task 2).
- The presenter:
  - is Objective-C with ARC, universal (`-arch x86_64 -arch arm64`), and links only Apple frameworks;
  - never creates Metal objects at load;
  - never alters HDR/EDR layers;
  - never blanks a game: any failure passes the frame through.
- `DYLD_*` variables survive only when they're set directly on a non-protected binary. The launcher sets them on Wine. Test scripts pass them as arguments to `/usr/bin/env`, never through `perl`, `sh -c` or an exported variable.
- Exact strings:
  - log prefix `macneutron-present: `;
  - messages `MetalFX <w>x<h> -> <w>x<h>`, `pass-through (full size)`, `pass-through (no overlay drawable)`, `linear filter (<reason>)`, `left alone (HDR/extended-range layer)`;
  - launcher note `note: MetalFX presenter not installed`;
  - toggle "MetalFX upscaling", with help "Upscales with Apple's MetalFX when the game renders below its window or the display's pixel density.";
  - launch option `MACNEUTRON_NO_METALFX=1`;
  - test-only variables `MACNEUTRON_PRESENT_DUMP`, `MACNEUTRON_PRESENT_SCALE`, and `MACNEUTRON_PRESENT_BOTH` (Task 1 only).
- Steam's files are edited only after the user says yes in chat, with Steam closed, after a backup.
- Every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Creating a fresh Wine prefix with the library loaded** (every first launch of a game) must still work. The spike's first version broke it. Pinned by `check.sh` "prefix setup works with the library loaded" (Task 1).
2. **A player's own `DYLD_INSERT_LIBRARIES`** must be kept, with the presenter added after it. Pinned by `presenterComesAfterTheUsersOwnLibraries` (Task 2).
3. **A game switching from a reduced to full resolution mid-game** must drop the overlay and pass frames through. Pinned by `check.sh` "overlay goes away at full size" (Task 1).
4. **Float (HDR-capable) swap chains** must be left untouched. Pinned by `check.sh` "HDR layers are left alone" (Task 1).
5. **Games started through `steam.exe`** (the Steam bridge) must still get the presenter. Pinned by `presenterAndSteamBridgeTravelTogether` (Task 2).

## File Structure

| File | Responsibility |
|---|---|
| `presenter/present.m` (new) | The presenter library |
| `presenter/tests/present_loop.c` (new) | D3D11 test program: checkerboard, resize, grow, fp16, average frame time |
| `presenter/tests/pixels.py` (new) | Samples eight pixels of a dumped frame |
| `presenter/check.sh` (new) | Real-Wine checks (spec §6) |
| `Makefile` | `presenter`, `presenter-check`; `app` bundles the library |
| `Sources/MacNeutronCore/ToolLayout.swift` | `presenterLibrary`, `presenterInstalled` |
| `Sources/MacNeutronCore/RuntimeInstaller.swift` | Installs the library with the tool files |
| `Sources/MacNeutronCore/GameSettings.swift` | `metalFX` |
| `Sources/MacNeutronCore/Launcher.swift` | Injection |
| `Sources/MacNeutronApp/GamesView.swift`, `README.md` | Toggle and docs |
| `docs/testing/acceptance-upscaler.md` (new) | Pacing decision and acceptance record |

---

### Task 1: The presenter library and its real-Wine check

**Files:**
- Create: `presenter/present.m`, `presenter/tests/present_loop.c`, `presenter/tests/pixels.py`, `presenter/check.sh`, `docs/testing/acceptance-upscaler.md`
- Modify: `Makefile`

**Interfaces:**
- Consumes: the installed runtime with GPTK imported; the tool's `bin/macneutron` launcher (on `main`: honours `MACNEUTRON_NO_STEAM_BRIDGE`, and passes the caller's environment to Wine).
- Produces: `build/presenter/libmacneutron-present.dylib`, `build/presenter/present_loop.exe`, `make presenter`, `make presenter-check`, and the pacing decision (spec §9).

- [ ] **Step 1: Write the test program**

`presenter/tests/present_loop.c`:

```c
/* Test program for presenter/check.sh: presents a checkerboard from a D3D11 swap chain and reports the
 * average frame time.
 *   present_loop.exe <client_w> <client_h> <swap_w|0> <swap_h|0> <frames> <vsync 0|1> [resize=F:WxH] [grow=F] [fp16]
 * Swap size 0 means the window's client size. resize= resizes the window at frame F; grow= resizes the swap chain
 * to the window at frame F; fp16 uses a float swap chain, which D3DMetal shows through an extended-range layer. */
#include <windows.h>
#include <d3d11_1.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static LRESULT CALLBACK proc(HWND h, UINT m, WPARAM w, LPARAM l) { return DefWindowProcA(h, m, w, l); }

static void target(IDXGISwapChain *swap, ID3D11Device *dev, ID3D11RenderTargetView **rtv, DXGI_SWAP_CHAIN_DESC *sd)
{
    ID3D11Texture2D *back = NULL;
    swap->lpVtbl->GetBuffer(swap, 0, &IID_ID3D11Texture2D, (void **)&back);
    dev->lpVtbl->CreateRenderTargetView(dev, (ID3D11Resource *)back, NULL, rtv);
    back->lpVtbl->Release(back);
    swap->lpVtbl->GetDesc(swap, sd);
}

int main(int argc, char **argv)
{
    int cw = atoi(argv[1]), ch = atoi(argv[2]), sw = atoi(argv[3]), sh = atoi(argv[4]);
    int frames = atoi(argv[5]), vsync = atoi(argv[6]), resize_at = -1, rw = 0, rh = 0, grow_at = -1, fp16 = 0;
    for (int i = 7; i < argc; i++) {
        if (!strncmp(argv[i], "resize=", 7)) sscanf(argv[i] + 7, "%d:%dx%d", &resize_at, &rw, &rh);
        else if (!strncmp(argv[i], "grow=", 5)) grow_at = atoi(argv[i] + 5);
        else if (!strcmp(argv[i], "fp16")) fp16 = 1;
    }
    WNDCLASSA wc = {0};
    RECT r = {0, 0, cw, ch};
    wc.lpfnWndProc = proc; wc.hInstance = GetModuleHandleA(NULL); wc.lpszClassName = "present_loop";
    RegisterClassA(&wc);
    AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, FALSE);
    HWND hwnd = CreateWindowA("present_loop", "present_loop", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 40, 40,
                              r.right - r.left, r.bottom - r.top, NULL, NULL, wc.hInstance, NULL);

    DXGI_SWAP_CHAIN_DESC sd = {0};
    sd.BufferCount = 2;
    sd.BufferDesc.Width = sw; sd.BufferDesc.Height = sh;
    sd.BufferDesc.Format = fp16 ? DXGI_FORMAT_R16G16B16A16_FLOAT : DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd; sd.SampleDesc.Count = 1; sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    IDXGISwapChain *swap = NULL; ID3D11Device *dev = NULL; ID3D11DeviceContext *ctx = NULL; ID3D11DeviceContext1 *ctx1 = NULL;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                               D3D11_SDK_VERSION, &sd, &swap, &dev, NULL, &ctx);
    if (FAILED(hr)) { printf("create failed 0x%08lx\n", (unsigned long)hr); return 1; }
    ctx->lpVtbl->QueryInterface(ctx, &IID_ID3D11DeviceContext1, (void **)&ctx1);
    ID3D11RenderTargetView *rtv = NULL;
    target(swap, dev, &rtv, &sd);
    printf("window client %dx%d, swap chain %ux%u\n", cw, ch, sd.BufferDesc.Width, sd.BufferDesc.Height);

    static D3D11_RECT rects[2048];
    LARGE_INTEGER f, t0, t1; QueryPerformanceFrequency(&f); QueryPerformanceCounter(&t0);
    for (int i = 0; i < frames; i++) {
        MSG msg; while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageA(&msg);
        if (i == resize_at) {
            RECT nr = {0, 0, rw, rh};
            AdjustWindowRect(&nr, WS_OVERLAPPEDWINDOW, FALSE);
            SetWindowPos(hwnd, NULL, 0, 0, nr.right - nr.left, nr.bottom - nr.top, SWP_NOMOVE | SWP_NOZORDER);
        }
        if (i == grow_at) {
            rtv->lpVtbl->Release(rtv); rtv = NULL;
            swap->lpVtbl->ResizeBuffers(swap, 0, 0, 0, DXGI_FORMAT_UNKNOWN, 0);
            target(swap, dev, &rtv, &sd);
        }
        /* The background never has all channels above 200; the 16px squares on a 32px pitch are white. */
        float bg[4] = { (i % 60) / 60.0f, 0.3f, 1.0f - (i % 120) / 120.0f, 1.0f }, white[4] = {1, 1, 1, 1};
        int n = 0;
        ctx->lpVtbl->OMSetRenderTargets(ctx, 1, &rtv, NULL);
        ctx->lpVtbl->ClearRenderTargetView(ctx, rtv, bg);
        for (int y = 0; y < (int)sd.BufferDesc.Height && n < 2040; y += 32)
            for (int x = (y / 32 % 2) * 16; x < (int)sd.BufferDesc.Width && n < 2040; x += 32)
                rects[n++] = (D3D11_RECT){x, y, x + 16, y + 16};
        if (ctx1) ctx1->lpVtbl->ClearView(ctx1, (ID3D11View *)rtv, white, rects, n);
        swap->lpVtbl->Present(swap, vsync, 0);
    }
    QueryPerformanceCounter(&t1);
    printf("frames %d, avg frame %.3f ms\n", frames, (t1.QuadPart - t0.QuadPart) * 1000.0 / f.QuadPart / frames);
    return 0;
}
```

`presenter/tests/pixels.py`:

```python
"""Prints W or N for eight pixels of a 1280x720 PPM frame: whether each is white (all channels > 200).

The samples sit in the middle of present_loop's checkerboard squares and gaps as they appear after a 2x upscale
of a 640x360 swap chain. The last two are near the bottom-right, so only a whole-frame upscale gets them right."""
import sys

SAMPLES = [(16, 16), (48, 16), (80, 16), (16, 48), (48, 80), (16, 80), (1232, 656), (1264, 656)]

with open(sys.argv[1], "rb") as f:
    data = f.read()
magic, width, height, maxval, pixels = data.split(maxsplit=4)
width = int(width)
print("".join("W" if min(pixels[(y * width + x) * 3:(y * width + x) * 3 + 3]) > 200 else "N" for x, y in SAMPLES))
```

- [ ] **Step 2: Write the check script and the Makefile targets**

`presenter/check.sh`:

```sh
#!/bin/sh
# Runs the MetalFX presenter under the installed runtime on D3DMetal: real Wine, no Steam (upscaler spec §6).
# Needs `make presenter` and an installed runtime with GPTK imported; MACNEUTRON_TOOL overrides the tool folder.
# DYLD_INSERT_LIBRARIES goes straight to the launcher through env's arguments: macOS strips DYLD_* variables when
# a protected binary (sh, perl, ...) sits in between.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/build/presenter"
LIB="$B/libmacneutron-present.dylib"
TOOL="${MACNEUTRON_TOOL:-$HOME/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron}"
WORK="${TMPDIR:-/tmp}/macneutron presenter"
mkdir -p "$WORK/compat"
fail=0
expect() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2], want [$3]"; fail=1; fi; }

# run_loop <name> <inject 0|1> <scale> <present_loop args...>  →  output in $WORK/<name>.txt
run_loop() {
  name=$1 inject=$2 scale=$3; shift 3
  lib=""; [ "$inject" = 1 ] && lib="$LIB"
  env STEAM_COMPAT_DATA_PATH="$WORK/compat/0" SteamAppId=0 MACNEUTRON_GRAPHICS=d3dmetal \
      MACNEUTRON_NO_STEAM_BRIDGE=1 MACNEUTRON_NO_METALFX=1 DYLD_INSERT_LIBRARIES="$lib" \
      MACNEUTRON_PRESENT_SCALE="$scale" MACNEUTRON_PRESENT_DUMP="$WORK/frame.ppm" \
      MACNEUTRON_PRESENT_BOTH="${PRESENT_BOTH:-0}" \
      "$TOOL/bin/macneutron" launch waitforexitandrun "$B/present_loop.exe" "$@" > "$WORK/$name.out" 2>&1 &
  pid=$!
  ( sleep 120; kill "$pid" 2>/dev/null ) & dog=$!
  wait "$pid" || true
  kill "$dog" 2>/dev/null || true
  tr -d '\r' < "$WORK/$name.out" > "$WORK/$name.txt"
}
frame_ms() { grep -o 'avg frame [0-9.]*' "$WORK/$1.txt" | awk '{print $3}'; }

# The prefix, created without the library (check 4 covers creating one with it).
[ -d "$WORK/compat/0/pfx" ] || env STEAM_COMPAT_DATA_PATH="$WORK/compat/0" SteamAppId=0 \
    "$TOOL/bin/macneutron" launch getcompatpath "$WORK" > /dev/null 2>&1

run_loop pass 1 1 1280 720 0 0 200 0
expect "full-size game passes through" "$(grep -c 'macneutron-present: MetalFX' "$WORK/pass.txt" || true)" 0

rm -f "$WORK/frame.ppm"
run_loop up 1 1 1280 720 640 360 300 0
expect "small swap chain is upscaled" "$(grep -c 'macneutron-present: MetalFX 640x360 -> 1280x720' "$WORK/up.txt" || true)" 1
expect "upscaled frame shows the whole checkerboard" \
  "$( [ -f "$WORK/frame.ppm" ] && python3 "$ROOT/presenter/tests/pixels.py" "$WORK/frame.ppm" || echo none)" "WNWNWNWN"

run_loop retina 1 2 1280 720 0 0 200 0
expect "Retina density is upscaled" "$(grep -c 'macneutron-present: MetalFX 1280x720 -> 2560x1440' "$WORK/retina.txt" || true)" 1

rm -rf "$WORK/compat/fresh"
env STEAM_COMPAT_DATA_PATH="$WORK/compat/fresh" SteamAppId=0 DYLD_INSERT_LIBRARIES="$LIB" \
    "$TOOL/bin/macneutron" launch getcompatpath "$WORK" > /dev/null 2>&1 && st=0 || st=$?
expect "prefix setup works with the library loaded" \
  "$st:$( [ -d "$WORK/compat/fresh/pfx/drive_c" ] && echo yes || echo no)" "0:yes"

run_loop resize 1 1 1280 720 640 360 300 0 resize=150:960x540
expect "overlay follows a window resize" "$(grep -c 'macneutron-present: MetalFX 640x360 -> 960x540' "$WORK/resize.txt" || true)" 1

run_loop grow 1 1 1280 720 640 360 300 0 grow=150
expect "overlay goes away at full size" "$(grep -c 'macneutron-present: pass-through (full size)' "$WORK/grow.txt" || true)" 1

run_loop hdr 1 1 1280 720 640 360 200 0 fp16
expect "HDR layers are left alone" \
  "$(grep -c 'left alone (HDR/extended-range layer)' "$WORK/hdr.txt" || true):$(grep -c 'macneutron-present: MetalFX' "$WORK/hdr.txt" || true)" "1:0"

run_loop base 0 1 1280 720 640 360 600 0
run_loop pace 1 1 1280 720 640 360 600 0
expect "pacing within 1 ms of no library" \
  "$(awk -v a="$(frame_ms pace)" -v b="$(frame_ms base)" 'BEGIN { print (a != "" && b != "" && a <= b + 1.0) ? "yes" : "no (" a " vs " b " ms)" }')" "yes"

exit $fail
```

In `Makefile`, add `presenter presenter-check` to `.PHONY`, add `PRESENTER = build/presenter` under `BRIDGE = build/bridge`, and add these targets after `bridge-check`:

```make
# MetalFX presenter (docs/superpowers/specs/2026-09-28-macneutron-metalfx-upscaler-design.md) and its test program.
presenter:
	@command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "presenter: needs brew install mingw-w64" >&2; exit 1; }
	mkdir -p $(PRESENTER)
	clang -arch x86_64 -arch arm64 -fobjc-arc -O2 -dynamiclib -framework Foundation -framework AppKit \
		-framework QuartzCore -framework Metal -framework MetalFX \
		-o $(PRESENTER)/libmacneutron-present.dylib presenter/present.m
	$(MINGW) -o $(PRESENTER)/present_loop.exe presenter/tests/present_loop.c -ld3d11 -ldxgi -luser32 -lgdi32 -ldxguid -luuid

# The presenter under the installed runtime on D3DMetal (real Wine, no Steam).
presenter-check: presenter
	sh presenter/check.sh
```

- [ ] **Step 3: Run it to see it fail**

Run: `chmod +x presenter/check.sh && make presenter-check 2>&1 | tail -4`
Expected: FAIL. `clang` reports that `presenter/present.m` doesn't exist, and make stops.

- [ ] **Step 4: Write the library**

`presenter/present.m`:

```objc
// MacNeutron's MetalFX presenter. The launcher injects it into a game's Wine processes (DYLD_INSERT_LIBRARIES).
// When a game's drawable is smaller than the pixels its layer covers (a lower in-game resolution, or Wine's
// half-density rendering on a Retina screen), it upscales the frame with MetalFX into an overlay layer on top,
// instead of Core Animation's nearest-neighbour stretch. Any failure passes the frame through untouched.
// Spec: docs/superpowers/specs/2026-09-28-macneutron-metalfx-upscaler-design.md
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

@interface MNLayerState : NSObject
@property CAMetalLayer *overlay;       // over the game's layer while upscaling
@property CGSize overlaySize;          // drawable size the overlay was last given
@property BOOL updating;               // an overlay change is queued on the main thread
@property CGFloat scale;               // backing scale of the layer's window; 0 until known
@property id<MTLFXSpatialScaler> scaler;
@property id<MTLTexture> output;
@property NSUInteger inWidth, inHeight, outWidth, outHeight;
@property MTLPixelFormat format;
@property NSUInteger frames;
@property BOOL linear, hdr, dumped;    // linear/hdr: permanent for this layer
@property NSString *lastNote;
@end
@implementation MNLayerState
@end

static const void *kState = &kState, *kIsOverlay = &kIsOverlay;
static id<CAMetalDrawable> (*origNextDrawable)(CAMetalLayer *, SEL);
static void (*origPresent)(id<MTLCommandBuffer>, SEL, id<MTLDrawable>);
static BOOL presentBoth;          // test-only (plan task 1): also present the game's own drawable
static const char *dumpPath;      // test-only: write the 120th upscaled frame as a PPM
static double scaleOverride;      // test-only: pretend the window has this backing scale

static void note(MNLayerState *st, NSString *message)
{
    if ([message isEqualToString:st.lastNote]) return;
    st.lastNote = message;
    fprintf(stderr, "macneutron-present: %s\n", message.UTF8String);
}

/* The window's backing scale, read on the main thread where AppKit belongs. */
static void refreshScale(CAMetalLayer *layer, MNLayerState *st)
{
    if (scaleOverride > 0) { st.scale = scaleOverride; return; }
    __weak CAMetalLayer *weak = layer;
    dispatch_async(dispatch_get_main_queue(), ^{
        CAMetalLayer *l = weak;
        if (!l) return;
        id delegate = l.delegate;
        NSWindow *window = [delegate isKindOfClass:NSView.class] ? ((NSView *)delegate).window : nil;
        st.scale = window ? window.backingScaleFactor : NSScreen.mainScreen.backingScaleFactor;
    });
}

static MNLayerState *stateFor(CAMetalLayer *layer)
{
    MNLayerState *st = objc_getAssociatedObject(layer, kState);
    if (st) return st;
    @synchronized (layer) {
        st = objc_getAssociatedObject(layer, kState);
        if (!st) {
            st = [MNLayerState new];
            objc_setAssociatedObject(layer, kState, st, OBJC_ASSOCIATION_RETAIN);
            refreshScale(layer, st);
        }
    }
    return st;
}

static BOOL isHDR(CAMetalLayer *layer)
{
    switch (layer.pixelFormat) {
    case MTLPixelFormatRGBA16Float: case MTLPixelFormatBGRA10_XR: case MTLPixelFormatBGRA10_XR_sRGB:
    case MTLPixelFormatBGR10_XR: case MTLPixelFormatBGR10_XR_sRGB:
        return YES;
    default:
        return layer.wantsExtendedDynamicRangeContent;
    }
}

static CGSize targetSize(CAMetalLayer *layer, MNLayerState *st)
{
    CGSize b = layer.bounds.size;
    return CGSizeMake(round(b.width * st.scale), round(b.height * st.scale));
}

static BOOL wantsUpscale(CAMetalLayer *layer, MNLayerState *st, CGSize drawable)
{
    if (st.scale <= 0 || st.linear || st.hdr) return NO;
    CGSize t = targetSize(layer, st);
    return drawable.width >= 16 && drawable.width < t.width && drawable.height < t.height;
}

static void removeOverlay(MNLayerState *st)
{
    CAMetalLayer *o = st.overlay;
    st.overlay = nil; st.overlaySize = CGSizeZero; st.scaler = nil; st.output = nil;
    if (!o) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        [o removeFromSuperlayer];
        [CATransaction commit];
    });
}

/* Creates or resizes the overlay on the main thread; frames pass through until it's in place. */
static void placeOverlay(CAMetalLayer *layer, MNLayerState *st, CGSize target)
{
    if (st.updating) return;
    st.updating = YES;
    CGFloat scale = st.scale;
    __weak CAMetalLayer *weak = layer;
    dispatch_async(dispatch_get_main_queue(), ^{
        CAMetalLayer *l = weak;
        if (l) {
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            CAMetalLayer *o = st.overlay;
            if (!o) {
                o = [CAMetalLayer layer];
                objc_setAssociatedObject(o, kIsOverlay, @YES, OBJC_ASSOCIATION_RETAIN);
                o.device = l.device; o.pixelFormat = l.pixelFormat; o.framebufferOnly = NO; o.opaque = YES;
                [l addSublayer:o];
            }
            o.frame = l.bounds; o.contentsScale = scale; o.drawableSize = target;
            [CATransaction commit];
            st.overlaySize = target;
            st.overlay = o;
        }
        st.updating = NO;
    });
}

static void useLinear(CAMetalLayer *layer, MNLayerState *st, NSString *reason)
{
    st.linear = YES;
    removeOverlay(st);
    __weak CAMetalLayer *weak = layer;
    dispatch_async(dispatch_get_main_queue(), ^{ weak.magnificationFilter = kCAFilterLinear; });
    note(st, [NSString stringWithFormat:@"linear filter (%@)", reason]);
}

/* A MetalFX spatial scaler and output texture for this input and output, cached per layer. */
static NSString *prepareScaler(id<MTLDevice> device, MNLayerState *st, id<MTLTexture> src, CGSize target)
{
    NSUInteger ow = (NSUInteger)target.width, oh = (NSUInteger)target.height;
    if (st.scaler && st.inWidth == src.width && st.inHeight == src.height && st.outWidth == ow && st.outHeight == oh
        && st.format == src.pixelFormat)
        return nil;
    if (![MTLFXSpatialScalerDescriptor supportsDevice:device]) return @"MetalFX isn't available on this GPU";
    MTLFXSpatialScalerDescriptor *desc = [MTLFXSpatialScalerDescriptor new];
    desc.inputWidth = src.width; desc.inputHeight = src.height; desc.outputWidth = ow; desc.outputHeight = oh;
    desc.colorTextureFormat = src.pixelFormat; desc.outputTextureFormat = src.pixelFormat;
    desc.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
    id<MTLFXSpatialScaler> scaler = [desc newSpatialScalerWithDevice:device];
    if (!scaler)
        return [NSString stringWithFormat:@"MetalFX can't scale pixel format %lu", (unsigned long)src.pixelFormat];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
                                                                                    width:ow height:oh mipmapped:NO];
    td.usage = scaler.outputTextureUsage; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> output = [device newTextureWithDescriptor:td];
    if (!output) return @"no memory for the MetalFX output";
    st.scaler = scaler; st.output = output; st.format = src.pixelFormat;
    st.inWidth = src.width; st.inHeight = src.height; st.outWidth = ow; st.outHeight = oh;
    return nil;
}

/* Test-only: the 120th upscaled frame of a layer as a PPM (BGRA8 only). */
static void dumpFrame(id<MTLCommandBuffer> cb, id<MTLTexture> t, MNLayerState *st)
{
    if (!dumpPath || st.dumped || st.frames < 120 || t.pixelFormat != MTLPixelFormatBGRA8Unorm) return;
    st.dumped = YES;
    NSUInteger w = t.width, h = t.height;
    NSString *path = @(dumpPath);
    id<MTLBuffer> buf = [cb.device newBufferWithLength:w * h * 4 options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
                 toBuffer:buf destinationOffset:0 destinationBytesPerRow:w * 4 destinationBytesPerImage:w * h * 4];
    [blit endEncoding];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        FILE *f = fopen(path.fileSystemRepresentation, "wb");
        if (!f) return;
        fprintf(f, "P6 %lu %lu 255\n", (unsigned long)w, (unsigned long)h);
        const uint8_t *px = buf.contents;
        for (NSUInteger i = 0; i < w * h; i++) { uint8_t rgb[3] = {px[i * 4 + 2], px[i * 4 + 1], px[i * 4]}; fwrite(rgb, 1, 3, f); }
        fclose(f);
    }];
}

/* Upscales the game's drawable into the overlay and presents the overlay. NO: present the game's drawable as usual. */
static BOOL upscaleInto(id<MTLCommandBuffer> cb, id<CAMetalDrawable> drawable)
{
    CAMetalLayer *layer = drawable.layer;
    id<MTLTexture> src = drawable.texture;
    if (!layer || !src || objc_getAssociatedObject(layer, kIsOverlay)) return NO;
    MNLayerState *st = stateFor(layer);
    st.frames += 1;
    if (st.frames % 120 == 0) refreshScale(layer, st);  // the window may have moved to another screen
    if (!wantsUpscale(layer, st, CGSizeMake(src.width, src.height))) {
        if (st.overlay) removeOverlay(st);
        if (st.scale > 0 && !st.linear && !st.hdr) note(st, @"pass-through (full size)");
        return NO;
    }
    if (src.framebufferOnly) return NO;  // switched this frame: the next drawable is readable
    CGSize target = targetSize(layer, st);
    if (!st.overlay || !CGSizeEqualToSize(st.overlaySize, target)) {
        placeOverlay(layer, st, target);
        if (!st.overlay) return NO;
    }
    NSString *failure = prepareScaler(cb.device, st, src, st.overlaySize);
    if (failure) { useLinear(layer, st, failure); return NO; }
    id<CAMetalDrawable> out = [st.overlay nextDrawable];
    if (!out || out.texture.width != st.outWidth || out.texture.height != st.outHeight) {
        note(st, @"pass-through (no overlay drawable)");
        return NO;
    }
    st.scaler.colorTexture = src;
    st.scaler.outputTexture = st.output;
    [st.scaler encodeToCommandBuffer:cb];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:st.output toTexture:out.texture];
    [blit endEncoding];
    dumpFrame(cb, out.texture, st);
    note(st, [NSString stringWithFormat:@"MetalFX %lux%lu -> %lux%lu", (unsigned long)src.width,
              (unsigned long)src.height, (unsigned long)st.outWidth, (unsigned long)st.outHeight]);
    origPresent(cb, @selector(presentDrawable:), out);
    return YES;
}

static void mnPresent(id<MTLCommandBuffer> self, SEL _cmd, id<MTLDrawable> drawable)
{
    BOOL upscaled = [drawable conformsToProtocol:@protocol(CAMetalDrawable)] && upscaleInto(self, (id<CAMetalDrawable>)drawable);
    if (!upscaled || presentBoth) origPresent(self, _cmd, drawable);
}

/* Hooks presentation on this device's command buffers, once per process, the first time something draws. */
static void hookPresent(id<MTLDevice> device)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id<MTLCommandBuffer> cb = [[device newCommandQueue] commandBuffer];
        Method m = cb ? class_getInstanceMethod(object_getClass(cb), @selector(presentDrawable:)) : NULL;
        if (m) origPresent = (void *)method_setImplementation(m, (IMP)mnPresent);
    });
}

static id<CAMetalDrawable> mnNextDrawable(CAMetalLayer *self, SEL _cmd)
{
    if (objc_getAssociatedObject(self, kIsOverlay)) return origNextDrawable(self, _cmd);
    MNLayerState *st = stateFor(self);
    if (!st.hdr && isHDR(self)) { st.hdr = YES; note(st, @"left alone (HDR/extended-range layer)"); }
    if (wantsUpscale(self, st, self.drawableSize) && self.framebufferOnly) self.framebufferOnly = NO;
    id<CAMetalDrawable> drawable = origNextDrawable(self, _cmd);
    if (self.device) hookPresent(self.device);
    return drawable;
}

__attribute__((constructor)) static void mnInit(void)
{
    const char *both = getenv("MACNEUTRON_PRESENT_BOTH"), *scale = getenv("MACNEUTRON_PRESENT_SCALE");
    presentBoth = both && both[0] == '1';
    dumpPath = getenv("MACNEUTRON_PRESENT_DUMP");
    scaleOverride = scale ? atof(scale) : 0;
    Method m = class_getInstanceMethod(CAMetalLayer.class, @selector(nextDrawable));
    if (m) origNextDrawable = (void *)method_setImplementation(m, (IMP)mnNextDrawable);
}
```

- [ ] **Step 5: Run the check**

Run: `make presenter-check 2>&1 | tail -10`
Expected: PASS. The library builds (`lipo -archs build/presenter/libmacneutron-present.dylib` prints `x86_64 arm64`) and the output ends with:

```
ok   full-size game passes through
ok   small swap chain is upscaled
ok   upscaled frame shows the whole checkerboard
ok   Retina density is upscaled
ok   prefix setup works with the library loaded
ok   overlay follows a window resize
ok   overlay goes away at full size
ok   HDR layers are left alone
ok   pacing within 1 ms of no library
```

For any `FAIL`, use superpowers:systematic-debugging with `$TMPDIR/macneutron presenter/<name>.txt`. The spike's notes on what does and doesn't work are in spec §2. Don't loosen a check to make it pass.

- [ ] **Step 6: Decide how frames are presented (spec §9)**

Run the pacing comparison: overlay only (the default) against both drawables presented (`PRESENT_BOTH=1`), for two cases, each against no library:

```bash
W="$TMPDIR/macneutron presenter"; B=build/presenter; TOOL="$HOME/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron"
for s w h in 1 640 360 2 0 0; do for mode in none overlay both; do
  lib="$PWD/$B/libmacneutron-present.dylib"; both=0; [ $mode = none ] && lib=""; [ $mode = both ] && both=1
  env STEAM_COMPAT_DATA_PATH="$W/compat/0" SteamAppId=0 MACNEUTRON_GRAPHICS=d3dmetal MACNEUTRON_NO_STEAM_BRIDGE=1 \
      MACNEUTRON_NO_METALFX=1 DYLD_INSERT_LIBRARIES="$lib" MACNEUTRON_PRESENT_SCALE=$s MACNEUTRON_PRESENT_BOTH=$both \
      "$TOOL/bin/macneutron" launch waitforexitandrun "$PWD/$B/present_loop.exe" 1280 720 $w $h 900 0 > "$W/pace-$mode.out" 2>&1 &
  pid=$!; ( sleep 120; kill $pid 2>/dev/null ) & dog=$!; wait $pid; kill $dog 2>/dev/null
  echo "scale=$s swap=${w}x$h $mode: $(tr -d '\r' < "$W/pace-$mode.out" | grep -o 'avg frame [0-9.]* ms' || echo STALLED)"
done; done
```

(zsh syntax: `for s w h in …` takes three values per pass. The session's shell is zsh.)

Expected: six lines with a frame time each. Decide by spec §9:
- **Overlay only never stalls and is within 1 ms of `none`:** keep overlay only. Delete `presentBoth`, its `getenv`, the `|| presentBoth` term in `mnPresent`, and `MACNEUTRON_PRESENT_BOTH` from `check.sh`.
- **Overlay only stalls and `both` is within 1 ms:** make presenting both permanent. Replace `if (!upscaled || presentBoth)` with an unconditional `origPresent(self, _cmd, drawable);`, then delete `presentBoth`, its `getenv` and the `check.sh` line.
- **Neither:** **stop and report** the six numbers to the user.

Rebuild and re-run `make presenter-check` after the edit.
Expected: all nine checks `ok`.

- [ ] **Step 7: Record the decision**

Create `docs/testing/acceptance-upscaler.md`:

```markdown
# MetalFX upscaler acceptance

Spec: `docs/superpowers/specs/2026-09-28-macneutron-metalfx-upscaler-design.md`.

## Pacing decision (plan task 1), <date>

| Case | No library | Overlay only | Both presented |
|---|---|---|---|
| 640x360 → 1280x720 (scale 1) | <ms> | <ms> | <ms> |
| 1280x720 → 2560x1440 (scale 2) | <ms> | <ms> | <ms> |

Decision: <overlay only / both>, because <reason per spec §9>.
`make presenter-check`: <n>/9 ok.
```

Fill every `<…>` with measured values.

- [ ] **Step 8: Commit**

```bash
git add presenter Makefile docs/testing/acceptance-upscaler.md
git commit -m "feat(presenter): MetalFX spatial upscaling for games rendering below their window

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Launcher injection, the per-game setting, tool install

**Files:**
- Modify: `Sources/MacNeutronCore/ToolLayout.swift`, `Sources/MacNeutronCore/RuntimeInstaller.swift`, `Sources/MacNeutronCore/GameSettings.swift`, `Sources/MacNeutronCore/Launcher.swift`, `Tests/MacNeutronCoreTests/Support.swift`, `Tests/MacNeutronCoreTests/LauncherTests.swift`, `Tests/MacNeutronCoreTests/RuntimeInstallerTests.swift`, `Tests/MacNeutronCoreTests/GameSettingsTests.swift`

**Interfaces:**
- Consumes: `RuntimeInstaller.installFile(_:at:)`, `writeToolFiles(layout:launcherBinary:)`; `makeFixture(runner:rosetta:bridge:)` in `LauncherTests`.
- Produces:
  - `ToolLayout.presenterLibrary: URL` (`<root>/lib/libmacneutron-present.dylib`) and `presenterInstalled: Bool`;
  - `GameSettings.metalFX: Bool?`, with init parameter `metalFX: Bool? = nil` added last;
  - launcher injection for `run` and `waitforexitandrun`;
  - test helper `installFakePresenter(in:)`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/MacNeutronCoreTests/Support.swift`:

```swift
/// A stand-in for the MetalFX presenter library in the tool folder.
func installFakePresenter(in layout: ToolLayout) throws {
    try write("presenter", to: layout.presenterLibrary)
}
```

In `Tests/MacNeutronCoreTests/LauncherTests.swift`, give `makeFixture` a `presenter: Bool = false` parameter after `bridge`, and add after its `if bridge { … }` line:

```swift
    if presenter { try installFakePresenter(in: layout) }
```

Then append:

```swift
@Test func presenterIsInjectedByDefault() throws {
    let f = try makeFixture(presenter: true)
    _ = f.launcher.launch(["waitforexitandrun", "/g/Game.exe"], environment: f.env)
    let game = try #require(f.runner.calls.first { $0.arguments == ["/g/Game.exe"] })
    #expect(game.environment["DYLD_INSERT_LIBRARIES"] == f.launcher.layout.presenterLibrary.path(percentEncoded: false))
}

@Test func presenterComesAfterTheUsersOwnLibraries() throws {
    let f = try makeFixture(presenter: true)
    var env = f.env
    env["DYLD_INSERT_LIBRARIES"] = "/opt/mine.dylib"
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: env)
    #expect(f.runner.calls.last?.environment["DYLD_INSERT_LIBRARIES"]
        == "/opt/mine.dylib:" + f.launcher.layout.presenterLibrary.path(percentEncoded: false))
}

@Test func optingOutLeavesThePresenterOut() throws {
    let f = try makeFixture(presenter: true)
    var env = f.env
    env["MACNEUTRON_NO_METALFX"] = "1"
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: env)
    #expect(f.runner.calls.last?.environment["DYLD_INSERT_LIBRARIES"] == nil)
    try f.launcher.settings.save(GameSettings(metalFX: false), for: "42")
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: f.env)
    #expect(f.runner.calls.last?.environment["DYLD_INSERT_LIBRARIES"] == nil)
}

@Test func missingPresenterIsNoted() throws {
    let f = try makeFixture()
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: f.env)
    #expect(f.runner.calls.last?.environment["DYLD_INSERT_LIBRARIES"] == nil)
    #expect(f.launcherLog.contains("note: MetalFX presenter not installed"))
}

@Test func toolCommandsGetNoPresenter() throws {
    let f = try makeFixture(presenter: true)
    _ = f.launcher.launch(["runinprefix", "/g/tool.exe"], environment: f.env)
    _ = f.launcher.launch(["getcompatpath", "/g/save"], environment: f.env)
    #expect(f.runner.calls.allSatisfy { $0.environment["DYLD_INSERT_LIBRARIES"] == nil })
}

@Test func presenterAndSteamBridgeTravelTogether() throws {
    let f = try makeFixture(bridge: true, presenter: true)
    _ = f.launcher.launch(["run", "/g/Game.exe"], environment: f.env)
    let game = try #require(f.runner.calls.last)
    #expect(game.arguments.first == SteamBridge.steamExe)
    #expect(game.environment["DYLD_INSERT_LIBRARIES"] == f.launcher.layout.presenterLibrary.path(percentEncoded: false))
}
```

Append to `Tests/MacNeutronCoreTests/RuntimeInstallerTests.swift`:

```swift
@Test func installPutsThePresenterInTheToolFolder() throws {
    let layout = ToolLayout(root: try makeTempDir().appending(path: "macneutron"))
    let launcher = try makeEchoLauncher()
    #expect(!layout.presenterInstalled)
    try write("presenter v1", to: launcher.deletingLastPathComponent().appending(path: "libmacneutron-present.dylib"))
    try RuntimeInstaller.writeToolFiles(layout: layout, launcherBinary: launcher)
    #expect(try String(contentsOf: layout.presenterLibrary, encoding: .utf8) == "presenter v1")
    #expect(layout.presenterInstalled)
}

@Test func installFindsThePresenterInTheAppsFrameworks() throws {
    // In MacNeutron.app the launcher is Contents/Helpers/macneutron and the library is in Contents/Frameworks.
    let contents = try makeTempDir().appending(path: "MacNeutron.app/Contents", directoryHint: .isDirectory)
    let launcher = contents.appending(path: "Helpers/macneutron")
    try write("#!/bin/sh\n", to: launcher, executable: true)
    try write("presenter from frameworks", to: contents.appending(path: "Frameworks/libmacneutron-present.dylib"))
    let layout = ToolLayout(root: try makeTempDir().appending(path: "macneutron"))
    try RuntimeInstaller.writeToolFiles(layout: layout, launcherBinary: launcher)
    #expect(try String(contentsOf: layout.presenterLibrary, encoding: .utf8) == "presenter from frameworks")
}
```

In `Tests/MacNeutronCoreTests/GameSettingsTests.swift`, replace `settingsBecomeLaunchVariables` with:

```swift
@Test func settingsBecomeLaunchVariables() {
    #expect(GameSettings(graphics: "dxmt", log: true, avx: false, msync: false, runAs: .windows, metalFX: false).environment == [
        "MACNEUTRON_GRAPHICS": "dxmt", "MACNEUTRON_LOG": "1", "MACNEUTRON_NO_AVX": "1", "MACNEUTRON_NO_MSYNC": "1",
        "MACNEUTRON_NO_METALFX": "1",
    ])
    #expect(GameSettings(log: false, avx: true, msync: true, metalFX: true).environment.isEmpty)
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift build --build-tests 2>&1 | grep error: | sort -u | head`
Expected: FAIL to compile, with `value of type 'ToolLayout' has no member 'presenterLibrary'` and `extra argument 'metalFX' in call`.

- [ ] **Step 3: Implement**

In `Sources/MacNeutronCore/ToolLayout.swift`, add after `steamBridgeInstalled`:

```swift
    /// MacNeutron's MetalFX presenter, which the launcher injects into games' Wine processes.
    public var presenterLibrary: URL { root.appending(path: "lib/libmacneutron-present.dylib") }
    public var presenterInstalled: Bool { FileManager.default.fileExists(atPath: presenterLibrary.path(percentEncoded: false)) }
```

In `Sources/MacNeutronCore/RuntimeInstaller.swift` `writeToolFiles`, add after the `steam.exe` block:

```swift
        // The presenter is Mach-O code, so in MacNeutron.app it lives in Contents/Frameworks.
        let presenters = [helpers.appending(path: "libmacneutron-present.dylib"),
                          helpers.deletingLastPathComponent().appending(path: "Frameworks/libmacneutron-present.dylib")]
        if let presenter = presenters.first(where: { fm.fileExists(atPath: $0.path(percentEncoded: false)) }) {
            try installFile(presenter, at: layout.presenterLibrary)
        }
```

In `Sources/MacNeutronCore/GameSettings.swift`:
- Add `public var metalFX: Bool?` after `runAs`.
- Extend the init with a last parameter `metalFX: Bool? = nil`, assigning `self.metalFX = metalFX`.
- In `environment`, after the msync line, add `if metalFX == false { env["MACNEUTRON_NO_METALFX"] = "1" }`.

In `Sources/MacNeutronCore/Launcher.swift`, after `if steamBridge { addSteamClient(to: &env) }`, add:

```swift
        if request.verb == .run || request.verb == .waitforexitandrun { addPresenter(to: &env) }
```

and add next to `addSteamClient`:

```swift
    /// Loads the MetalFX presenter into the game's Wine processes, after any libraries the player set,
    /// unless the game opts out.
    private func addPresenter(to env: inout [String: String]) {
        guard env["MACNEUTRON_NO_METALFX"] != "1" else { return }
        guard layout.presenterInstalled else {
            log.append("note: MetalFX presenter not installed")
            return
        }
        let libraries = [env["DYLD_INSERT_LIBRARIES"], layout.presenterLibrary.path(percentEncoded: false)]
        env["DYLD_INSERT_LIBRARIES"] = libraries.compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ":")
    }
```

- [ ] **Step 4: Run the tests**

Run: `swift test 2>&1 | grep -E "✘|Test run with"`
Expected: PASS: `Test run with 161 tests in 0 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacNeutronCore Tests/MacNeutronCoreTests
git commit -m "feat(launcher): inject the MetalFX presenter unless a game opts out; install it with the tool files

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: App bundle, Games window toggle, README

**Files:**
- Modify: `Makefile` (`app`), `Sources/MacNeutronApp/GamesView.swift`, `README.md`

**Interfaces:**
- Consumes: `make presenter` (Task 1); `GameSettings.metalFX` (Task 2).

- [ ] **Step 1: Bundle the library**

In `Makefile`, change the `app` target's first line to `app: build bridge presenter`, and add these lines before the final `codesign --force --sign - $(APP)`:

```make
	mkdir -p $(APP)/Contents/Frameworks
	cp $(PRESENTER)/libmacneutron-present.dylib $(APP)/Contents/Frameworks/libmacneutron-present.dylib
	codesign --force --sign - $(APP)/Contents/Frameworks/libmacneutron-present.dylib
```

Run: `make app 2>&1 | tail -1 && codesign --verify --deep --strict build/MacNeutron.app && ls build/MacNeutron.app/Contents/Frameworks`
Expected: `libmacneutron-present.dylib` is listed, and verification prints nothing.

- [ ] **Step 2: The toggle and the README**

In `Sources/MacNeutronApp/GamesView.swift`, add after `Toggle("msync", …)`:

```swift
                    Toggle("MetalFX upscaling", isOn: binding(row, \.metalFX, default: true))
                        .help("Upscales with Apple's MetalFX when the game renders below its window or the display's pixel density.")
```

In `README.md`, add this row to the launch-options table:

```markdown
| `/usr/bin/env MACNEUTRON_NO_METALFX=1 %command%` | Don't upscale with MetalFX (macOS then stretches smaller images with its nearest-neighbour filter) |
```

and this section after "## Steam API":

```markdown
## Upscaling

When a game renders below the size of its window, or below your display's pixel density (Retina screens),
MacNeutron upscales each frame with Apple's MetalFX instead of the blocky stretch macOS would apply. To trade
sharpness for frame rate, pick a lower resolution in the game's windowed or borderless mode. It costs about 1 ms of
GPU time per frame while active and nothing when the game renders at full size; switch "MetalFX upscaling" off for a
game in the Games window if it misbehaves.
```

Run: `swift build 2>&1 | tail -1 && make app 2>&1 | tail -1`
Expected: `Build complete!` and a signed app.

- [ ] **Step 3: Install and confirm**

Run: `osascript -e 'quit app id "io.github.chadouming.MacNeutron"'; sleep 2; open build/MacNeutron.app; sleep 4; cmp "$HOME/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron/lib/libmacneutron-present.dylib" build/presenter/libmacneutron-present.dylib && echo installed`
Expected: `installed`.

- [ ] **Step 4: Commit**

```bash
git add Makefile Sources/MacNeutronApp/GamesView.swift README.md
git commit -m "feat(app): bundle the MetalFX presenter; per-game MetalFX upscaling toggle

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Acceptance on the maintainer's Mac

**Files:**
- Modify: `docs/testing/acceptance-upscaler.md`

**Interfaces:**
- Consumes: everything above; the user in chat for each game session.

- [ ] **Step 1: SMITE 2 at a lower resolution (acceptance item 1)**

Ask the user to start SMITE 2 (its launch options show the Metal display), set windowed or borderless mode with a resolution below the display's (for example 1920×1080 on the 2560×1440 display), and play a minute at the same spot twice:
- once with "MetalFX upscaling" on in MacNeutron's Games window;
- once with it off.

Toggle changes apply at the next launch. Each time, ask for the Metal display's FPS and GPU time and how sharp it looks.

After each run: `grep -a "macneutron-present" "$HOME/Library/Logs/MacNeutron/steam-2437170.log" | tail -3` if the user has game logging on; otherwise the launcher log shows the launch.
Expected: with MetalFX on, a `MetalFX 1920x1080 -> 2560x1440` line (or the actual sizes) when logging is on; visibly sharper than off.

- [ ] **Step 2: The built-in Retina display (acceptance item 2)**

Ask the user to move a game window (SMITE 2 or any Windows game) to the built-in display and compare sharpness with the toggle on and off.
Expected: sharper with it on (`MetalFX … -> …` at 2× density in the game log).

- [ ] **Step 3: Opt-out and regressions (acceptance items 3–4)**

Confirm with the user:
- with the toggle off, the old look returns;
- SMITE 2 still logs in (Steam bridge);
- Timberborn still starts natively.

- [ ] **Step 4: Record and commit**

Append `## Acceptance, <date>` to `docs/testing/acceptance-upscaler.md` with one bullet per item. Include the FPS and GPU-time numbers and the user's impressions, leave no `<…>` placeholders, and include nothing personal.

```bash
git add docs/testing/acceptance-upscaler.md
git commit -m "docs: MetalFX upscaler acceptance results

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
