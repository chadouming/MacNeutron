/* x18 toggle cost + behaviour probe (unentitled). clang -O2 -mmacosx-version-min=27.0 x18cost.c -o x18cost */
#include <os/arch/arm64.h>
#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <spawn.h>
#include <sys/qos.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define BIT48 (1ULL << 48)
static inline int bit(void) { return (__builtin_arm_rsr64("TPIDR_EL0") & BIT48) != 0; }
static inline unsigned long long now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
__attribute__((noinline)) static void empty(int x) { __asm__ volatile("" ::"r"(x)); }
static pthread_key_t key;
/* option: a register-preserving wrapper (x0-x17, x30 kept) so dispatcher asm can toggle without parking registers */
void x18_on_keep(void), x18_off_keep(void);
#define KEEP(name, val) __asm__(".globl _" #name "\n_" #name ":\n" \
    "stp x0, x1, [sp, #-0xa0]!\n stp x2, x3, [sp, #0x10]\n stp x4, x5, [sp, #0x20]\n stp x6, x7, [sp, #0x30]\n" \
    "stp x8, x9, [sp, #0x40]\n stp x10, x11, [sp, #0x50]\n stp x12, x13, [sp, #0x60]\n stp x14, x15, [sp, #0x70]\n" \
    "stp x16, x17, [sp, #0x80]\n stp x29, x30, [sp, #0x90]\n mov w0, #" #val "\n bl _os_set_custom_x18_abi_enabled\n" \
    "ldp x2, x3, [sp, #0x10]\n ldp x4, x5, [sp, #0x20]\n ldp x6, x7, [sp, #0x30]\n ldp x8, x9, [sp, #0x40]\n" \
    "ldp x10, x11, [sp, #0x50]\n ldp x12, x13, [sp, #0x60]\n ldp x14, x15, [sp, #0x70]\n ldp x16, x17, [sp, #0x80]\n" \
    "ldp x29, x30, [sp, #0x90]\n ldp x0, x1, [sp], #0xa0\n ret\n")
KEEP(x18_on_keep, 1);
KEEP(x18_off_keep, 0);

enum { N = 200000, TRIALS = 21 }; /* short trials: unentitled, a context switch inside C3's guard window traps */
static int cmp(const void *a, const void *b) { double x = *(double *)a, y = *(double *)b; return x < y ? -1 : x > y; }

/* returns median ns/iteration; *worst = slowest trial; *lost = iterations where a context switch cleared the bit */
static double run(int c, double *worst, long *lost)
{
    double t[TRIALS]; *lost = 0;
    for (int k = 0; k < TRIALS; k++) {
        unsigned long long t0 = now();
        for (int i = 0; i < N; i++) switch (c) {
        case 0: empty(i); break;                                               /* call floor */
        case 1: empty(os_custom_x18_abi_enabled()); break;                     /* query */
        case 2: empty(bit()); break;                                           /* inline mrs guard */
        case 3: os_set_custom_x18_abi_enabled(true);                           /* pair + guard */
                if (bit()) os_set_custom_x18_abi_enabled(false); else ++*lost; break;
        case 6: x18_on_keep();                                                 /* pair via preserving wrappers + guard */
                if (bit()) x18_off_keep(); else ++*lost; break;
        case 4: empty(getppid()); break;                                       /* real syscall (getpid is cached in libc) */
        case 5: empty((int)(long)pthread_getspecific(key)); break;
        }
        t[k] = (double)(now() - t0) / N;
    }
    qsort(t, TRIALS, sizeof *t, cmp);
    *worst = t[TRIALS - 1];
    return t[TRIALS / 2];
}

static void bench(const char *label)
{
    static const char *name[] = { "C0 empty call", "C1 os_custom_x18_abi_enabled()", "C2 inline mrs TPIDR_EL0 bit",
                                  "C3 set(true)+guard+set(false)", "C8 getppid() syscall", "C8 pthread_getspecific()",
                                  "C4 C3 via register-preserving wrappers" };
    double w, m[7]; long lost;
    for (int c = 0; c < 7; c++) {
        m[c] = run(c, &w, &lost);
        printf("  %-34s median %6.2f ns  worst-trial %6.2f ns%s", name[c], m[c], w, c == 3 || c == 6 ? "" : "\n");
        if (c == 3 || c == 6) printf("  (bit lost to a context switch %ld/%d)\n", lost, N * TRIALS);
    }
    printf("  => per toggle (C3 - C2 + C0)/2 = %.2f ns, upper bound C3/2 = %.2f ns [%s]\n", (m[3] - m[2] + m[0]) / 2, m[3] / 2, label);
    printf("  => preserving wrapper adds (C4 - C3)/2 = %.2f ns per toggle\n", (m[6] - m[3]) / 2);
}

static void *bench_thread(void *qos)
{
    pthread_set_qos_class_self_np((qos_class_t)(long)qos, 0);
    for (volatile int i = 0; i < 50000000; i++) ; /* warm-up */
    bench(qos == (void *)QOS_CLASS_USER_INTERACTIVE ? "QOS_CLASS_USER_INTERACTIVE (perflevel0 Super cores)" : "QOS_CLASS_BACKGROUND (perflevel1 Performance cores on M5 Pro, no E-cores)");
    return 0;
}

static volatile int h_mode = -1;
static void handler(int s) { h_mode = os_custom_x18_abi_enabled(); }

static void *child_thread(void *p) { *(int *)p = os_custom_x18_abi_enabled(); return 0; }

int main(int argc, char **argv)
{
    Dl_info di;
    pthread_t t;
    pthread_key_create(&key, 0);
    if (argc > 1) { /* bench child */
        pthread_create(&t, 0, bench_thread, (void *)(long)atoi(argv[1])); pthread_join(t, 0);
        return 0;
    }
    if (dladdr((void *)os_set_custom_x18_abi_enabled, &di)) printf("os_set_custom_x18_abi_enabled lives in %s\n", di.dli_fname);
    printf("TPIDR_EL0 at start %#llx, enabled()=%d\n", __builtin_arm_rsr64("TPIDR_EL0"), os_custom_x18_abi_enabled());

    /* 1. unentitled call: does it abort, does the bit stick, does x18 survive? */
    os_set_custom_x18_abi_enabled(true);
    printf("after set(true): enabled()=%d TPIDR_EL0 %#llx\n", os_custom_x18_abi_enabled(), __builtin_arm_rsr64("TPIDR_EL0"));
    int child = -1;
    if (!bit()) os_set_custom_x18_abi_enabled(true);
    pthread_create(&t, 0, child_thread, &child); pthread_join(t, 0);
    printf("pthread_create from an ON thread: child enabled()=%d\n", child);
    signal(SIGUSR1, handler);
    if (!bit()) os_set_custom_x18_abi_enabled(true);
    raise(SIGUSR1);
    printf("signal raised while ON: handler saw enabled()=%d, after sigreturn enabled()=%d\n", h_mode, os_custom_x18_abi_enabled());
    int kept = 0, still = 0;
    for (int i = 0; i < 200; i++) {
        if (!bit()) os_set_custom_x18_abi_enabled(true);
        unsigned long long v = 0x7777000000000000ULL + i, r;
        __asm__ volatile("mov x18, %0" ::"r"(v));
        usleep(200);
        __asm__ volatile("mov %0, x18" : "=r"(r));
        kept += r == v; still += bit();
    }
    printf("200x (ON, x18=magic, usleep 200us): x18 kept %d/200, bit still set %d/200\n", kept, still);
    /* ponytail: no final set(false): unentitled, a context switch between our check and the library's own check traps */

    /* 2. toggling to the current state */
    for (int want = 0; want <= 1; want++) {
        pid_t pid = fork();
        if (!pid) { if (want) os_set_custom_x18_abi_enabled(true); os_set_custom_x18_abi_enabled(want); _exit(0); }
        int st; waitpid(pid, &st, 0);
        printf("set(%s) while already %s: %s %d\n", want ? "true" : "false", want ? "ON" : "OFF",
               WIFSIGNALED(st) ? "killed by signal" : "exit", WIFSIGNALED(st) ? WTERMSIG(st) : WEXITSTATUS(st));
    }

    /* 3. cost: only where the bit survives context switches (entitled), else C3's guard races and set(false) traps */
    if (still < 200) printf("bit not honoured across context switches (unentitled): bench runs in a child, retried if it traps\n");
    extern char **environ;
    for (int q = 0; q < 2; q++)
        for (int attempt = 1; attempt <= 5; attempt++) {
            char qos[16]; snprintf(qos, sizeof qos, "%d", q ? QOS_CLASS_BACKGROUND : QOS_CLASS_USER_INTERACTIVE);
            char *args[] = { argv[0], qos, 0 }; pid_t pid; int st;
            fflush(stdout);
            if (posix_spawn(&pid, argv[0], 0, 0, args, environ)) return 1;
            waitpid(pid, &st, 0);
            if (!WIFSIGNALED(st)) break;
            printf("  bench attempt %d killed by signal %d (context switch inside the guard window)\n", attempt, WTERMSIG(st));
        }
    return 0;
}
