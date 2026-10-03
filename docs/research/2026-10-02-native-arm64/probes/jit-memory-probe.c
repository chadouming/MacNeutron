/* Throwaway: which JIT memory schemes does an entitled, hardened-runtime process get on macOS 27? */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <pthread.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <libkern/OSCacheControl.h>
#include <time.h>
static const uint32_t code42[] = { 0xd2800540, 0xd65f03c0 };   /* mov x0,#42; ret */
static const uint32_t code7[]  = { 0xd28000e0, 0xd65f03c0 };   /* mov x0,#7;  ret */
static int run(void *x) { return ((int (*)(void))x)(); }
static void dual(const char *name, int jitflag) {
    size_t sz = 0x4000;
    void *rw = mmap(0, sz, PROT_READ | PROT_WRITE | (jitflag ? PROT_EXEC : 0), MAP_ANON | MAP_PRIVATE | (jitflag ? MAP_JIT : 0), -1, 0);
    if (rw == MAP_FAILED) { printf("%s: base mmap failed %s\n", name, strerror(errno)); return; }
    mach_vm_address_t rx = 0; vm_prot_t cur, max;
    kern_return_t kr = mach_vm_remap(mach_task_self(), &rx, sz, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (mach_vm_address_t)rw, FALSE, &cur, &max, VM_INHERIT_NONE);
    if (kr) { printf("%s: mach_vm_remap kr=%d\n", name, kr); return; }
    printf("%s: alias cur=%d max=%d\n", name, cur, max);
    if (jitflag) pthread_jit_write_protect_np(0);
    if (!jitflag) { int r = mprotect((void *)rx, sz, PROT_READ | PROT_EXEC); printf("%s: mprotect alias RX -> %s\n", name, r ? strerror(errno) : "ok"); if (r) return; }
    else { kr = mach_vm_protect(mach_task_self(), rx, sz, FALSE, VM_PROT_READ | VM_PROT_EXECUTE); printf("%s: protect alias RX kr=%d\n", name, kr); }
    memcpy(rw, code42, 8); sys_icache_invalidate(rw, 8); sys_icache_invalidate((void *)rx, 8);
    if (jitflag) pthread_jit_write_protect_np(1);
    printf("%s: exec alias -> %d\n", name, run((void *)rx));
    if (jitflag) pthread_jit_write_protect_np(0);
    memcpy(rw, code7, 8); sys_icache_invalidate((void *)rx, 8);
    if (jitflag) pthread_jit_write_protect_np(1);
    printf("%s: rewrite via RW, exec alias -> %d\n", name, run((void *)rx));
}
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC_RAW, &t); return t.tv_sec * 1e9 + t.tv_nsec; }
int main(void) {
    setvbuf(stdout, 0, _IONBF, 0);
    dual("plain RW + RX alias", 0);
    dual("MAP_JIT + RX alias", 1);
    /* cost of the per-thread MAP_JIT toggle */
    void *j = mmap(0, 0x4000, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0);
    double t0 = now(); for (int i = 0; i < 10000000; i++) { pthread_jit_write_protect_np(0); pthread_jit_write_protect_np(1); }
    printf("pthread_jit_write_protect_np pair: %.1f ns\n", (now() - t0) / 1e7);
    (void)j; return 0;
}
