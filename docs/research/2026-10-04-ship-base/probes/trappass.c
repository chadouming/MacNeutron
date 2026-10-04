/* does returning from a SIGTRAP handler that reset SIGTRAP to SIG_DFL re-execute the toggle's brk #1 and kill the process? */
#include <os/arch/arm64.h>
#include <signal.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>
static volatile int hits;
static void h(int s) { hits++; signal(SIGTRAP, SIG_DFL); write(2, "handler: passing the trap through\n", 34); }
int main(void)
{
    pid_t pid = fork();
    if (!pid) { signal(SIGTRAP, h); os_set_custom_x18_abi_enabled(false); _exit(0); } /* already OFF -> brk #1 */
    int st; waitpid(pid, &st, 0);
    printf("child: %s %d\n", WIFSIGNALED(st) ? "killed by signal" : "exit", WIFSIGNALED(st) ? WTERMSIG(st) : WEXITSTATUS(st));
    return 0;
}
