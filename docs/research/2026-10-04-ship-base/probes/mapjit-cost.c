/* Throwaway (SP3 RWX item): what MAP_JIT can do for Wine's PAGE_EXECUTE_READWRITE, unentitled, 16K pages.
 * Placement (MAP_FIXED, hints into a reservation), protections, per-thread toggling from a fault handler,
 * and the native cost of a fault+toggle vs a fault+mprotect flip (patch 0006's mechanism). */
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define PG 0x4000
static const uint32_t code42[] = { 0xd2800540, 0xd65f03c0 };          /* mov x0,#42; ret */
static const uint32_t code7[]  = { 0xd28000e0, 0xd65f03c0 };          /* mov x0,#7;  ret */
static const uint32_t codelit[] = { 0x18000040, 0xd65f03c0, 0 };      /* ldr w0,[pc,#8]; ret; .word lit */
static const uint32_t codestr[] = { 0xb9000001, 0xd65f03c0 };         /* str w1,[x0]; ret */
typedef long (*fn0)(void);
typedef void (*fnstr)(void *, int);

static const char *e(int r) { return r ? strerror(errno) : "ok"; }
static double now(void) { return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

/* ---- fault handler: one strategy for every region it knows ---- */
enum { TOGGLE, MPROTECT };
static int strategy;
static char *regions[4]; static int nregions;   /* fault regions handled */
static _Atomic long faults_w, faults_x, faults_other;
static __thread long tfaults;
static __thread sigjmp_buf *bail; static __thread long bound;

static int in_regions(uintptr_t a) {
    for (int i = 0; i < nregions; i++) if (a - (uintptr_t)regions[i] < PG) return 1;
    return 0;
}
static void handler(int sig, siginfo_t *si, void *ucv) {
    ucontext_t *uc = ucv;
    uint64_t esr = uc->uc_mcontext->__es.__esr, far = uc->uc_mcontext->__es.__far, pc = uc->uc_mcontext->__ss.__pc;
    unsigned ec = (esr >> 26) & 0x3f;
    int exec = (ec == 0x20 || ec == 0x21), write = (ec == 0x24 || ec == 0x25) && (esr & (1 << 6));
    uintptr_t addr = exec ? pc : far;
    if (bound && ++tfaults > bound) siglongjmp(*bail, 1);
    if (!in_regions(addr)) { faults_other++; fprintf(stderr, "unexpected sig %d esr %llx far %llx pc %llx\n", sig, esr, far, pc); _exit(3); }
    if (strategy == TOGGLE) {
        if (write) { pthread_jit_write_protect_np(0); faults_w++; return; }
        if (exec)  { pthread_jit_write_protect_np(1); faults_x++; return; }
    } else {
        char *page = (char *)(addr & ~(uintptr_t)(PG - 1));
        if (write && !mprotect(page, PG, PROT_READ | PROT_WRITE)) { faults_w++; return; }
        if (exec && !mprotect(page, PG, PROT_READ | PROT_EXEC)) { faults_x++; return; }
    }
    fprintf(stderr, "unhandled fault esr %llx\n", esr); _exit(4);
}

static void *jit(void) { return mmap(0, PG, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0); }

/* ---- placement ---- */
static void placement(void) {
    printf("== placement\n");
    void *probe = mmap(0, 1 << 20, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); munmap(probe, 1 << 20);
    void *p = mmap(probe, PG, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT | MAP_FIXED, -1, 0);
    printf("MAP_JIT|MAP_FIXED at a free address %p: %s\n", probe, p == MAP_FAILED ? strerror(errno) : (p == probe ? "placed" : "elsewhere"));

    char *r = mmap(0, 64 << 20, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);       /* like a Wine reserved area */
    char *want = r + (1 << 20);
    p = mmap(want, 1 << 20, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT | MAP_FIXED, -1, 0);
    printf("MAP_JIT|MAP_FIXED over a PROT_NONE reservation: %s\n", p == MAP_FAILED ? strerror(errno) : "placed");
    p = mmap(want, 1 << 20, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    printf("MAP_JIT hint inside the reservation (occupied): %s\n", p == MAP_FAILED ? strerror(errno) : (p == want ? "at hint" : "elsewhere"));
    if (p != MAP_FAILED && p != want) munmap(p, 1 << 20);
    munmap(want, 1 << 20);
    p = mmap(want, 1 << 20, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    printf("MAP_JIT hint into a hole punched in the reservation: %s\n", p == MAP_FAILED ? strerror(errno) : (p == want ? "at hint" : "elsewhere"));
    if (p == want) {
        /* a Windows VirtualFree(MEM_DECOMMIT)/re-commit: can the hole go back to a plain reservation and to MAP_JIT again? */
        void *q = mmap(want, 1 << 20, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
        printf("  plain MAP_FIXED back over the MAP_JIT range: %s\n", q == want ? "ok" : strerror(errno));
    }
    void *low = mmap((void *)0x10000000, PG, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    printf("MAP_JIT hint 0x10000000 (below 4 GB, unentitled): %p\n", low);
    p = mmap(0, PG, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_SHARED | MAP_ANON | MAP_JIT, -1, 0);
    printf("MAP_JIT|MAP_SHARED: %s\n", p == MAP_FAILED ? strerror(errno) : "ok");
    char path[] = "/private/tmp/claude-501/-Users-chad-Documents-MacProton/4df1af36-0116-433f-917f-5078e899b9af/scratchpad/sp3/fileXXXXXX";
    int fd = mkstemp(path); ftruncate(fd, PG); unlink(path);
    p = mmap(0, PG, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_JIT, fd, 0);
    printf("MAP_JIT on a file: %s\n", p == MAP_FAILED ? strerror(errno) : "ok");
    int n = 0; for (; n < 256; n++) if (jit() == MAP_FAILED) break;
    printf("separate MAP_JIT regions: %d of 256\n", n);

    /* mach routes: can a fixed-address entry become JIT-capable? */
    mach_vm_address_t a = (mach_vm_address_t)(r + (8 << 20));
    kern_return_t kr = mach_vm_allocate(mach_task_self(), &a, PG, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE);
    printf("mach_vm_allocate FIXED|OVERWRITE in the reservation: kr=%d\n", kr);
    kr = mach_vm_protect(mach_task_self(), a, PG, FALSE, VM_PROT_ALL);
    printf("  mach_vm_protect RWX on it: kr=%d\n", kr);
    void *j = jit();
    a = (mach_vm_address_t)(r + (9 << 20)); vm_prot_t cur, max;
    kr = mach_vm_remap(mach_task_self(), &a, PG, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(), (mach_vm_address_t)j, FALSE, &cur, &max, VM_INHERIT_NONE);
    printf("mach_vm_remap of a MAP_JIT region to a fixed address (move, copy=FALSE): kr=%d\n", kr);
    kr = mach_vm_remap(mach_task_self(), &a, PG, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(), (mach_vm_address_t)j, TRUE, &cur, &max, VM_INHERIT_NONE);
    printf("mach_vm_remap of a MAP_JIT region to a fixed address (copy=TRUE): kr=%d cur=%d max=%d\n", kr, cur, max);
}

/* ---- protections on a MAP_JIT range (VirtualProtect) ---- */
static void protections(void) {
    printf("== protections\n");
    char *j = mmap(0, 4 * PG, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    printf("mprotect one page of a MAP_JIT range: none %s, r %s, rw %s, rx %s, rwx %s\n",
           e(mprotect(j + PG, PG, PROT_NONE)), e(mprotect(j + PG, PG, PROT_READ)), e(mprotect(j + PG, PG, PROT_READ | PROT_WRITE)),
           e(mprotect(j + PG, PG, PROT_READ | PROT_EXEC)), e(mprotect(j + PG, PG, PROT_READ | PROT_WRITE | PROT_EXEC)));
    printf("mprotect 4K inside a MAP_JIT page (16K process): %s\n", e(mprotect(j + 0x1000, 0x1000, PROT_READ)));
    char *plain = mmap(0, PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    printf("mprotect RWX on a plain page: %s\n", e(mprotect(plain, PG, PROT_READ | PROT_WRITE | PROT_EXEC)));
    mach_vm_address_t a = (mach_vm_address_t)j; mach_vm_size_t sz; vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t obj;
    mach_vm_region(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt, &obj);
    printf("vm_region of a MAP_JIT range: prot %d max %d\n", info.protection, info.max_protection);
    /* a MAP_JIT page set RW: does the thread's exec mode still block writes? a page set RX: does write mode block exec? */
    pthread_jit_write_protect_np(0); memcpy(j, code42, 8); memcpy(j + 2 * PG, code42, 8);
    sys_icache_invalidate(j, 8); sys_icache_invalidate(j + 2 * PG, 8);
    mprotect(j, PG, PROT_READ | PROT_WRITE); mprotect(j + 2 * PG, PG, PROT_READ | PROT_EXEC);
    regions[0] = j; regions[1] = j + 2 * PG; nregions = 2; strategy = TOGGLE; faults_w = faults_x = 0;
    pthread_jit_write_protect_np(1);
    j[100] = 1;
    printf("exec mode, store to a MAP_JIT page mprotected RW: %s\n", faults_w ? "faulted" : "no fault");
    pthread_jit_write_protect_np(0); faults_x = 0;
    long v = ((fn0)(j + 2 * PG))();
    printf("write mode, exec a MAP_JIT page mprotected RX: %s (got %ld)\n", faults_x ? "faulted" : "no fault", v);
    pthread_jit_write_protect_np(1); nregions = 0;
}

/* ---- the fault-driven cycle, one thread: write code, run it ---- */
static void cycle(const char *name, int strat, char *page, int n) {
    regions[0] = page; nregions = 1; strategy = strat; faults_w = faults_x = 0;
    if (strat == TOGGLE) pthread_jit_write_protect_np(1);
    long sum = 0; double t0 = now();
    for (int i = 0; i < n; i++) {
        memcpy(page, (i & 1) ? code7 : code42, 8);
        sys_icache_invalidate(page, 8);
        sum += ((fn0)page)();
    }
    double t = (now() - t0) / n;
    printf("%s: %d cycles, sum %ld (want %ld), %ld write + %ld exec faults, %.2f us per cycle\n",
           name, n, sum, (long)(n / 2) * 49, (long)faults_w, (long)faults_x, t / 1000);
    nregions = 0;
}

/* ---- two threads: A rewrites a literal in the page while B runs code from it ---- */
static char *shared; static _Atomic int stop; static _Atomic long b_runs;
static void *runner(void *arg) {
    long f0 = tfaults; (void)arg;
    if (strategy == TOGGLE) pthread_jit_write_protect_np(1);
    while (!stop) { ((fn0)shared)(); b_runs++; }
    return (void *)(tfaults - f0);
}
static void concurrent(const char *name, int strat, char *page) {
    regions[0] = page; nregions = 1; strategy = strat;
    if (strat == TOGGLE) pthread_jit_write_protect_np(0); else mprotect(page, PG, PROT_READ | PROT_WRITE);
    memcpy(page, codelit, 12); sys_icache_invalidate(page, 12);
    if (strat == TOGGLE) pthread_jit_write_protect_np(1); else mprotect(page, PG, PROT_READ | PROT_EXEC);
    shared = page; stop = 0; b_runs = 0; faults_w = faults_x = 0;
    pthread_t t; pthread_create(&t, 0, runner, 0);
    while (b_runs < 1000) ;
    double t0 = now();
    for (int i = 0; i < 100000; i++) ((volatile uint32_t *)page)[2] = i;
    double ta = (now() - t0) / 100000;
    stop = 1; pthread_join(t, 0);
    printf("%s: A wrote 100000 times (%.2f us each), B ran %ld times; faults: %ld write, %ld exec\n",
           name, ta / 1000, (long)b_runs, (long)faults_w, (long)faults_x);
    nregions = 0;
}

/* ---- code on a fault-handled page storing into fault-handled memory ---- */
static void selfstore(const char *name, int strat, char *code, char *target) {
    regions[0] = code; regions[1] = target; nregions = (target - code >= PG || code - target >= PG) ? 2 : 1; strategy = strat;
    if (strat == TOGGLE) pthread_jit_write_protect_np(0); else mprotect(code, PG, PROT_READ | PROT_WRITE);
    memcpy(code, codestr, 8); sys_icache_invalidate(code, 8);
    if (strat == TOGGLE) pthread_jit_write_protect_np(1);
    sigjmp_buf jb; bail = &jb; tfaults = 0; bound = 10000;
    if (!sigsetjmp(jb, 1)) { ((fnstr)code)(target, 5); printf("%s: completed after %ld faults\n", name, tfaults); }
    else printf("%s: LIVELOCK (gave up after %ld faults)\n", name, bound);
    bound = 0; nregions = 0;
    if (strat == TOGGLE) pthread_jit_write_protect_np(1);
}

int main(void) {
    setvbuf(stdout, 0, _IONBF, 0);
    struct sigaction sa = { .sa_sigaction = handler, .sa_flags = SA_SIGINFO | SA_NODEFER };
    sigaction(SIGBUS, &sa, 0); sigaction(SIGSEGV, &sa, 0);
    printf("== one thread, write then run (the RWX JIT pattern), native\n");
    char *plain = mmap(0, PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    cycle("fault + mprotect flip (patch 0006's mechanism)", MPROTECT, plain, 20000);
    char *j = jit();
    double t0 = now();
    for (int i = 0; i < 20000; i++) {
        pthread_jit_write_protect_np(0); memcpy(j, (i & 1) ? code7 : code42, 8); pthread_jit_write_protect_np(1);
        sys_icache_invalidate(j, 8); ((fn0)j)();
    }
    printf("MAP_JIT, explicit toggles around each write, no faults: %.3f us per cycle\n", (now() - t0) / 20000 / 1000);
    /* one direction that does work from a handler: a write fault that switches the thread to write mode */
    char *w = jit(); regions[0] = w; nregions = 1; strategy = TOGGLE; faults_w = 0;
    t0 = now();
    for (int i = 0; i < 20000; i++) { pthread_jit_write_protect_np(1); w[64] = i; }
    printf("MAP_JIT write fault -> handler sets write mode (+1 explicit toggle back): %.2f us per cycle, %ld faults\n", (now() - t0) / 20000 / 1000, (long)faults_w);
    nregions = 0;
    printf("== two threads (A writes, B runs the same page)\n");
    concurrent("mprotect flip", MPROTECT, mmap(0, PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0));
    printf("== code on a flipped page that stores to flipped memory\n");
    char *p1 = mmap(0, 2 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    selfstore("mprotect flip, store into another page", MPROTECT, p1, p1 + PG);
    mprotect(p1, 2 * PG, PROT_READ | PROT_WRITE);
    selfstore("mprotect flip, store into the same page", MPROTECT, p1, p1 + 0x100);
    return 0;
}
