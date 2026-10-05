// R0b probe: records how Steam launched it. Appends one line to r0b.log next to this binary.
// Build: clang -arch arm64 -mmacosx-version-min=27.0 -o r0b-probe r0b-probe.c
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libgen.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <mach-o/dyld.h>

int main(int argc, char **argv) {
    char raw[PATH_MAX], real[PATH_MAX], log[PATH_MAX + 16];
    uint32_t n = sizeof raw;
    if (_NSGetExecutablePath(raw, &n) != 0 || !realpath(raw, real)) return 1;
    snprintf(log, sizeof log, "%s/r0b.log", dirname(real));
    FILE *f = fopen(log, "a");
    if (!f) return 1;
    struct utsname u;
    uname(&u);
    int translated = 0;
    size_t sz = sizeof translated;
    if (sysctlbyname("sysctl.proc_translated", &translated, &sz, NULL, 0) != 0) translated = 0;
    fprintf(f, "arch=%s translated=%d argv=", u.machine, translated);
    for (int i = 0; i < argc; i++) fprintf(f, "%s%s", i ? "|" : "", argv[i]);
    fputc('\n', f);
    return fclose(f) ? 1 : 0;
}
