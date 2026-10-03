/* Throwaway probe: what does com.apple.developer.cross-architecture-support give a native arm64 process? */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <errno.h>
#include <unistd.h>
#include <spawn.h>
#include <pthread.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld.h>
#include <os/arch/arm64.h>
extern char **environ;

static void try_map(const char *what, uintptr_t addr, size_t len) {
    void *p = mmap((void *)addr, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_FIXED, -1, 0);
    if (p == MAP_FAILED) printf("  map %-26s at %#11lx: FAILED errno=%d (%s)\n", what, (unsigned long)addr, errno, strerror(errno));
    else { *(volatile int *)p = 1; printf("  map %-26s at %#11lx: ok\n", what, (unsigned long)addr); munmap(p, len); }
}
static void lowest_region(void) {
    mach_vm_address_t a = 0; mach_vm_size_t s = 0; vm_region_basic_info_data_64_t info; mach_msg_type_number_t n = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t obj;
    kern_return_t kr = mach_vm_region(mach_task_self(), &a, &s, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &n, &obj);
    printf("  lowest region: kr=%d start=%#llx size=%#llx prot=%d/%d\n", kr, a, s, info.protection, info.max_protection);
}
static inline void set18(uint64_t v) { __asm__ volatile("mov x18, %0" ::"r"(v)); }
static inline uint64_t get18(void) { uint64_t v; __asm__ volatile("mov %0, x18" : "=r"(v)); return v; }
static void *x18thr(void *a) {
    os_set_custom_x18_abi_enabled(true);
    int lost = 0; for (int i = 0; i < 200; i++) { set18(0x4242000000000000ULL + i); usleep(200); sched_yield(); if (get18() != 0x4242000000000000ULL + i) lost++; }
    if (os_custom_x18_abi_enabled()) os_set_custom_x18_abi_enabled(false);
    return (void *)(intptr_t)lost;
}
/* Message-passing litmus: TSO forbids (flag==1 && data==0); plain Arm ordering allows it. */
static volatile int go, done_w, *data, *flag; static long viol, seen;
static void *writer(void *a) { for (long i = 1; i <= (long)a; i++) { while (go != i) {} *data = (int)i; *flag = (int)i; done_w = (int)i; } return 0; }
static void litmus(long iters) {
    int *mem = aligned_alloc(256, 256); data = mem; flag = mem + 32; *data = *flag = 0;
    pthread_t t; pthread_create(&t, 0, writer, (void *)iters);
    for (long i = 1; i <= iters; i++) {
        go = (int)i; int f, d;
        do { f = *flag; d = *data; } while (f != i && done_w != i);
        if (f == i) { seen++; if (d != i) viol++; }
        while (done_w != i) ;
    }
    pthread_join(t, 0); printf("  MP litmus: %ld observed, %ld TSO violations\n", seen, viol);
}
static void report(const char *who) {
    printf("[%s] pid %d getpagesize=%d vm_page_size=%lu os_cross_arch_is_supported=%d\n", who, getpid(), getpagesize(), (unsigned long)vm_page_size, os_cross_arch_is_supported(OS_CROSS_ARCH_X86_64));
    lowest_region();
    try_map("low (64K)", 0x10000, 0x4000);
    try_map("KUSER_SHARED_DATA 0x7ffe0000", 0x7ffe0000, 0x4000);
    try_map("just under 4 GB", 0xfff00000, 0x4000);
    void *rwx = mmap(0, 0x4000, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
    printf("  plain RWX mmap: %s\n", rwx == MAP_FAILED ? strerror(errno) : "ok");
    void *jit = mmap(0, 0x4000, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0);
    printf("  MAP_JIT RWX mmap: %s\n", jit == MAP_FAILED ? strerror(errno) : "ok");
    pthread_t t; void *r; pthread_create(&t, 0, x18thr, 0); pthread_join(t, &r);
    printf("  x18 with os_set_custom_x18_abi_enabled: lost %ld/200\n", (long)r);
    litmus(2000000);
}
int main(int argc, char **argv) {
    setvbuf(stdout, 0, _IONBF, 0);
    if (argc > 1 && !strcmp(argv[1], "child")) { report("4K child"); return 0; }
    report("default");
    char path[4096]; uint32_t sz = sizeof path; _NSGetExecutablePath(path, &sz);
    posix_spawnattr_t at; posix_spawnattr_init(&at);
    int rc = posix_spawnattr_set_4k_page_size_np(&at);
    printf("posix_spawnattr_set_4k_page_size_np: %d\n", rc);
    pid_t pid; char *cargv[] = { path, "child", 0 };
    rc = posix_spawn(&pid, path, 0, &at, cargv, environ);
    if (rc) { printf("posix_spawn 4K child: %d (%s)\n", rc, strerror(rc)); return 0; }
    int st; waitpid(pid, &st, 0);
    printf("4K child exit: %s %d\n", WIFSIGNALED(st) ? "signal" : "status", WIFSIGNALED(st) ? WTERMSIG(st) : WEXITSTATUS(st));
    return 0;
}
