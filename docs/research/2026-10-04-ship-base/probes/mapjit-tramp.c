/* Throwaway (claim 4 check): is the exec-direction MAP_JIT toggle a hard wall, or only undone when made inside the handler?
 * The handler sends an exec fault to a trampoline that toggles after sigreturn, then branches back (clobbers x16: probe only). */
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#define PG 0x4000
static const uint32_t code42[] = { 0xd2800540, 0xd65f03c0 }, code7[] = { 0xd28000e0, 0xd65f03c0 };
static char *j; static __thread uint64_t resume; static volatile long nw, nx;
uint64_t get_resume(void) { return resume; }
void tramp(void);
__asm__(".globl _tramp\n_tramp:\n sub sp, sp, #320\n"
 " stp x0,x1,[sp,#0]\n stp x2,x3,[sp,#16]\n stp x4,x5,[sp,#32]\n stp x6,x7,[sp,#48]\n stp x8,x9,[sp,#64]\n"
 " stp x10,x11,[sp,#80]\n stp x12,x13,[sp,#96]\n stp x14,x15,[sp,#112]\n stp x17,x30,[sp,#128]\n mrs x9, nzcv\n str x9,[sp,#144]\n"
 " mov x0, #1\n bl _pthread_jit_write_protect_np\n bl _get_resume\n mov x16, x0\n ldr x9,[sp,#144]\n msr nzcv, x9\n"
 " ldp x0,x1,[sp,#0]\n ldp x2,x3,[sp,#16]\n ldp x4,x5,[sp,#32]\n ldp x6,x7,[sp,#48]\n ldp x8,x9,[sp,#64]\n"
 " ldp x10,x11,[sp,#80]\n ldp x12,x13,[sp,#96]\n ldp x14,x15,[sp,#112]\n ldp x17,x30,[sp,#128]\n add sp, sp, #320\n br x16\n");
static void h(int s, siginfo_t *si, void *u) {
    ucontext_t *uc = u; (void)s; (void)si;
    uint64_t esr = uc->uc_mcontext->__es.__esr; unsigned ec = (esr >> 26) & 0x3f;
    if (nw + nx > 1000000) _exit(9);
    if (ec == 0x20) { nx++; resume = uc->uc_mcontext->__ss.__pc; uc->uc_mcontext->__ss.__pc = (uint64_t)tramp; return; }
    nw++; pthread_jit_write_protect_np(0);   /* write fault: the direction that sticks */
}
int main(void) {
    setvbuf(stdout, 0, _IONBF, 0);
    struct sigaction sa = { .sa_sigaction = h, .sa_flags = SA_SIGINFO | SA_NODEFER };
    sigaction(SIGBUS, &sa, 0); sigaction(SIGSEGV, &sa, 0);
    j = mmap(0, PG, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    pthread_jit_write_protect_np(1);
    long sum = 0; int n = 20000; uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    for (int i = 0; i < n; i++) { memcpy(j, (i & 1) ? code7 : code42, 8); sys_icache_invalidate(j, 8); sum += ((long (*)(void))j)(); }
    double us = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1000.0 / n;
    printf("MAP_JIT write-then-run, faults only (write: toggle in handler; exec: trampoline toggles after return): "
           "sum %ld (want %ld), %ld write + %ld exec faults, %.2f us per cycle\n", sum, (long)(n / 2) * 49, nw, nx, us);
    return 0;
}
