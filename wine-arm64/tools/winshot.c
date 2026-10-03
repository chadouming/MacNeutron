/* winshot <window title> <png>: reads an on-screen window's pixels (arm64 DXMT spec §7). Waits up to 30 s for an
 * on-screen window with that title (layer 0, the first match), 2 s more for it to present, captures it with
 * screencapture into <png>, draws that into an sRGB bitmap so the display's profile doesn't move the values, and prints
 * "pixels <n> green <pct> white <pct>": the share of pixels with green 60-95 (the test programs' background green, 0.3,
 * is 77) and with every channel above 200 (percent of all pixels, rounded down). Needs Screen Recording permission. */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static int find_window(CFStringRef title)
{
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    int id = 0;
    for (CFIndex i = 0; list && !id && i < CFArrayGetCount(list); i++) {
        CFDictionaryRef w = CFArrayGetValueAtIndex(list, i);
        CFStringRef name = CFDictionaryGetValue(w, kCGWindowName);
        CFNumberRef layer = CFDictionaryGetValue(w, kCGWindowLayer), num = CFDictionaryGetValue(w, kCGWindowNumber);
        int l = -1;
        if (layer) CFNumberGetValue(layer, kCFNumberIntType, &l);
        if (name && l == 0 && num && CFEqual(name, title)) CFNumberGetValue(num, kCFNumberIntType, &id);
    }
    if (list) CFRelease(list);
    return id;
}

int main(int argc, char **argv)
{
    if (argc != 3) { fprintf(stderr, "usage: winshot <window title> <png>\n"); return 1; }
    if (!CGPreflightScreenCaptureAccess()) {
        fprintf(stderr, "winshot: screen capture is not allowed; grant it in System Settings > Privacy & Security > "
                        "Screen Recording\n");
        return 1;
    }
    CFStringRef title = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
    int id = 0;
    for (int i = 0; i < 120 && !(id = find_window(title)); i++) usleep(250000);
    if (!id) { fprintf(stderr, "winshot: no on-screen window titled %s\n", argv[1]); return 1; }
    sleep(2);

    char l[32];
    snprintf(l, sizeof l, "-l%d", id);
    char *args[] = {"/usr/sbin/screencapture", "-x", "-o", l, argv[2], NULL};
    pid_t pid;
    int st = 0;
    if (posix_spawn(&pid, args[0], NULL, NULL, args, environ) || waitpid(pid, &st, 0) < 0 || !WIFEXITED(st) ||
        WEXITSTATUS(st)) {
        fprintf(stderr, "winshot: screencapture of window %d failed\n", id);
        return 1;
    }

    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[2], strlen(argv[2]), false);
    CGImageSourceRef src = CGImageSourceCreateWithURL(url, NULL);
    CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    if (!img) { fprintf(stderr, "winshot: can't read %s\n", argv[2]); return 1; }
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, srgb, kCGImageAlphaPremultipliedLast);
    if (!ctx || !w || !h) { fprintf(stderr, "winshot: can't make a %zux%zu bitmap\n", w, h); return 1; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
    const unsigned char *p = CGBitmapContextGetData(ctx);  /* R, G, B, A */
    size_t n = w * h, green = 0, white = 0;
    for (size_t i = 0; i < n; i++, p += 4) {
        green += p[1] >= 60 && p[1] <= 95;
        white += p[0] > 200 && p[1] > 200 && p[2] > 200;
    }
    printf("pixels %zu green %zu white %zu\n", n, green * 100 / n, white * 100 / n);
    return 0;
}
