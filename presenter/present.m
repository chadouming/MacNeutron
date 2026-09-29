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
                o.maximumDrawableCount = l.maximumDrawableCount;
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
    // The overlay paces like the game's own layer: a game presenting without vsync turns display sync off there.
    if (st.overlay.displaySyncEnabled != layer.displaySyncEnabled) st.overlay.displaySyncEnabled = layer.displaySyncEnabled;
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
    if (!upscaled) origPresent(self, _cmd, drawable);  // an upscaled frame shows only the overlay
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
    const char *scale = getenv("MACNEUTRON_PRESENT_SCALE");
    dumpPath = getenv("MACNEUTRON_PRESENT_DUMP");
    scaleOverride = scale ? atof(scale) : 0;
    Method m = class_getInstanceMethod(CAMetalLayer.class, @selector(nextDrawable));
    if (m) origNextDrawable = (void *)method_setImplementation(m, (IMP)mnNextDrawable);
}
