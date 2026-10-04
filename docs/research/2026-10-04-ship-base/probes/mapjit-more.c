/* Throwaway: (1) once a MAP_JIT range has been raised to RWX, can it be lowered again? (2) in the handler of an
 * exec fault (write mode), does pthread_jit_write_protect_np(1) take effect inside the handler, and after return? */
#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#define PG 0x4000
#define RWX (PROT_READ | PROT_WRITE | PROT_EXEC)
#define TRY(x) do { int r_ = (x); printf("  %-52s %s\n", #x, r_ ? strerror(errno) : "ok"); } while (0)
static const uint32_t code42[] = { 0xd2800540, 0xd65f03c0 };
static char *j; static volatile long nf, inside; static sigjmp_buf jb;
static void h(int s, siginfo_t *si, void *u) {
    (void)s; (void)si; (void)u;
    if (++nf > 50) siglongjmp(jb, 1);
    pthread_jit_write_protect_np(1);
    if (nf == 1) inside = ((long (*)(void))j)();   /* run the page from inside the handler, after the toggle */
}
int main(void) {
    setvbuf(stdout, 0, _IONBF, 0);
    char *a = mmap(0, PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    printf("MAP_JIT created RW, then:\n");
    TRY(mprotect(a, PG, PROT_READ | PROT_EXEC));
    TRY(mprotect(a, PG, PROT_READ | PROT_WRITE));
    TRY(mprotect(a, PG, PROT_NONE));
    TRY(mprotect(a, PG, RWX));
    TRY(mprotect(a, PG, PROT_READ | PROT_WRITE));
    TRY(mprotect(a, PG, PROT_NONE));
    void *q = mmap(a, PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
    printf("  plain MAP_FIXED over it after RWX: %s\n", q == a ? "ok" : strerror(errno));
    struct sigaction sa = { .sa_sigaction = h, .sa_flags = SA_SIGINFO | SA_NODEFER };
    sigaction(SIGBUS, &sa, 0); sigaction(SIGSEGV, &sa, 0);
    j = mmap(0, PG, RWX, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    pthread_jit_write_protect_np(0); memcpy(j, code42, 8); sys_icache_invalidate(j, 8);
    long v = 0;
    if (!sigsetjmp(jb, 1)) { v = ((long (*)(void))j)(); printf("exec fault in write mode: resumed, got %ld after %ld faults\n", v, nf); }
    else printf("exec fault in write mode: handler toggled to exec; the page ran inside the handler (got %ld); after return: LIVELOCK (%ld faults)\n", inside, nf);
    return 0;
}
