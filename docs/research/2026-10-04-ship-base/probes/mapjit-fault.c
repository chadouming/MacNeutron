/* Throwaway: does a per-thread MAP_JIT toggle made inside a fault handler stick after the handler returns? */
#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#define PG 0x4000
#define RWX (PROT_READ | PROT_WRITE | PROT_EXEC)
static const uint32_t code42[] = { 0xd2800540, 0xd65f03c0 };
static char *jpage; static volatile long nf; static sigjmp_buf jb;
static uint64_t esrs[4], pcs[4];

static void h(int sig, siginfo_t *si, void *ucv) {
    ucontext_t *uc = ucv; (void)sig; (void)si;
    uint64_t esr = uc->uc_mcontext->__es.__esr, pc = uc->uc_mcontext->__ss.__pc;
    unsigned ec = (esr >> 26) & 0x3f;
    if (nf < 4) { esrs[nf] = esr; pcs[nf] = pc; }
    if (++nf > 1000) siglongjmp(jb, 1);
    if (ec == 0x20 || ec == 0x21) pthread_jit_write_protect_np(1);
    else pthread_jit_write_protect_np(0);
}
static void report(const char *name, int bailed) {
    printf("%s: %s after %ld faults; first ESRs:", name, bailed ? "LIVELOCK (bailed)" : "completed", nf);
    for (int i = 0; i < 4 && i < nf; i++) printf(" %#llx(EC %#llx, pc %s)", esrs[i], (esrs[i] >> 26) & 0x3f, pcs[i] - (uint64_t)jpage < PG ? "in page" : "outside");
    printf("\n");
}
static void run_in_write_mode(void) {
    pthread_jit_write_protect_np(0); memcpy(jpage, code42, 8); sys_icache_invalidate(jpage, 8);
    nf = 0; long v = 0;
    int b = sigsetjmp(jb, 1);
    if (!b) v = ((long (*)(void))jpage)();
    report("run an RWX MAP_JIT page in write mode, handler sets exec mode", b);
    if (!b) printf("  returned %ld\n", v);
}
static void store_in_exec_mode(void) {
    pthread_jit_write_protect_np(1);
    nf = 0;
    int b = sigsetjmp(jb, 1);
    if (!b) jpage[64] = 1;
    report("store to an RWX MAP_JIT page in exec mode, handler sets write mode", b);
}
static void both(void) {
    pthread_jit_write_protect_np(1);
    nf = 0; long sum = 0;
    int b = sigsetjmp(jb, 1);
    if (!b) for (int i = 0; i < 100; i++) { memcpy(jpage, code42, 8); sys_icache_invalidate(jpage, 8); sum += ((long (*)(void))jpage)(); }
    report("100 write-then-run cycles, both toggles in the handler", b);
}
static void fork_step(void (*f)(void)) {
    pid_t p = fork();
    if (!p) {
        setvbuf(stdout, 0, _IONBF, 0);
        struct sigaction sa = { .sa_sigaction = h, .sa_flags = SA_SIGINFO | SA_NODEFER };
        sigaction(SIGBUS, &sa, 0); sigaction(SIGSEGV, &sa, 0);
        jpage = mmap(0, PG, RWX, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
        f(); _exit(0);
    }
    int st; waitpid(p, &st, 0);
    if (WIFSIGNALED(st)) printf("  child killed by signal %d\n", WTERMSIG(st));
}
int main(void) {
    setvbuf(stdout, 0, _IONBF, 0);
    fork_step(store_in_exec_mode);
    fork_step(run_in_write_mode);
    fork_step(both);
    return 0;
}
