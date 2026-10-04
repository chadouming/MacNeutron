/* Throwaway: mprotect on MAP_JIT ranges, one step per forked child so a kill doesn't hide the rest. */
#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
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
static volatile int faults;
static void h(int sig, siginfo_t *si, void *uc) { (void)sig; (void)si; (void)uc; faults++; _exit(50 + faults); }

static char *jit(size_t n) { return mmap(0, n, RWX, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0); }
static void step(const char *name, void (*f)(void)) {
    pid_t p = fork();
    if (!p) { struct sigaction sa = { .sa_sigaction = h, .sa_flags = SA_SIGINFO }; sigaction(SIGBUS, &sa, 0); sigaction(SIGSEGV, &sa, 0); setvbuf(stdout, 0, _IONBF, 0); f(); _exit(0); }
    int st; waitpid(p, &st, 0);
    if (WIFSIGNALED(st)) printf("%s: killed by signal %d\n", name, WTERMSIG(st));
    else if (WEXITSTATUS(st) > 50) printf("%s: faulted\n", name);
    else printf("%s: exit %d\n", name, WEXITSTATUS(st));
}
#define TRY(x) do { int r_ = (x); printf("  %-58s %s\n", #x, r_ ? strerror(errno) : "ok"); } while (0)

static void whole(void) {
    char *j = jit(4 * PG);
    TRY(mprotect(j, 4 * PG, PROT_READ | PROT_WRITE));
    TRY(mprotect(j, 4 * PG, RWX));
    TRY(mprotect(j, 4 * PG, PROT_READ | PROT_EXEC));
    TRY(mprotect(j, 4 * PG, RWX));
    TRY(mprotect(j, 4 * PG, PROT_NONE));
    TRY(mprotect(j, 4 * PG, RWX));
}
static void sub(void) {
    char *j = jit(4 * PG);
    TRY(mprotect(j + PG, PG, PROT_NONE));
    TRY(mprotect(j + PG, PG, RWX));
    TRY(mprotect(j + PG, PG, PROT_READ));
    TRY(mprotect(j + PG, PG, PROT_READ | PROT_WRITE));
    TRY(mprotect(j + PG, PG, PROT_READ | PROT_EXEC));
    TRY(mprotect(j + PG, PG, RWX));
}
static void initial_rw(void) {   /* MAP_JIT mapped RW (no exec) first, later raised to RWX: the VirtualAlloc(RW) then VirtualProtect(RWX) shape */
    char *j = mmap(0, PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    printf("  MAP_JIT mapped RW: %s\n", j == MAP_FAILED ? strerror(errno) : "ok");
    if (j != MAP_FAILED) TRY(mprotect(j, PG, RWX));
    char *n = mmap(0, PG, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    printf("  MAP_JIT mapped PROT_NONE (MEM_RESERVE shape): %s\n", n == MAP_FAILED ? strerror(errno) : "ok");
    if (n != MAP_FAILED) TRY(mprotect(n, PG, RWX));
}
static void plain_rw_then_rx(void) {
    char *p = mmap(0, PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    TRY(mprotect(p, PG, PROT_READ | PROT_EXEC));
    TRY(mprotect(p, PG, PROT_READ | PROT_WRITE));
}
static void exec_rw_page_in_exec_mode(void) {   /* a MAP_JIT page set RW: does the thread's exec mode still block stores? */
    char *j = jit(PG);
    if (mprotect(j, PG, PROT_READ | PROT_WRITE)) { printf("  mprotect RW failed: %s\n", strerror(errno)); return; }
    pthread_jit_write_protect_np(1); j[100] = 1; printf("  store ok\n");
}
static void exec_rx_page_in_write_mode(void) {
    char *j = jit(PG);
    pthread_jit_write_protect_np(0); memcpy(j, code42, 8); sys_icache_invalidate(j, 8);
    if (mprotect(j, PG, PROT_READ | PROT_EXEC)) { printf("  mprotect RX failed: %s\n", strerror(errno)); return; }
    printf("  ran: %ld\n", ((long (*)(void))j)());
}
static void exec_write_mode(void) {   /* RWX MAP_JIT page, thread in write mode, execute it */
    char *j = jit(PG);
    pthread_jit_write_protect_np(0); memcpy(j, code42, 8); sys_icache_invalidate(j, 8);
    printf("  ran: %ld\n", ((long (*)(void))j)());
}
static void default_mode(void) {      /* a fresh thread's mode: store into an RWX MAP_JIT page without toggling */
    char *j = jit(PG); j[0] = 1; printf("  store ok in the default mode\n");
}
static void *tstore(void *j) { ((char *)j)[0] = 1; printf("  store ok in a new thread's default mode\n"); return 0; }
static void thread_default(void) {
    char *j = jit(PG); pthread_jit_write_protect_np(0); pthread_t t; pthread_create(&t, 0, tstore, j); pthread_join(t, 0);
}

int main(void) {
    setvbuf(stdout, 0, _IONBF, 0);
    step("whole range", whole);
    step("one page of four", sub);
    step("MAP_JIT created RW or PROT_NONE", initial_rw);
    step("plain page RW <-> RX", plain_rw_then_rx);
    step("MAP_JIT page mprotected RW, store in exec mode", exec_rw_page_in_exec_mode);
    step("MAP_JIT page mprotected RX, run in write mode", exec_rx_page_in_write_mode);
    step("RWX MAP_JIT page, run in write mode", exec_write_mode);
    step("RWX MAP_JIT page, store in the main thread's default mode", default_mode);
    step("RWX MAP_JIT page, store in a new thread (parent in write mode)", thread_default);
    return 0;
}
