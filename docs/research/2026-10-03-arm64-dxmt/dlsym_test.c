/* Loads winemac.so the way ntdll does (dlopen, RTLD_NOW) and looks the table up the way
 * DXMT's winemetal.so does (dlsym RTLD_DEFAULT). Checks slots DXMT calls are non-NULL. */
#include <dlfcn.h>
#include <stdio.h>
#include <assert.h>
int main(int argc, char **argv)
{
    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { printf("dlopen: %s\n", dlerror()); return 1; }
    void **t = dlsym(RTLD_DEFAULT, "macdrv_functions");
    printf("macdrv_functions=%p get_win_data=%p\n", (void*)t, t ? t[1] : NULL);
    assert(t && t[1] && t[2] && t[6] && t[7] && t[8]);
    assert(!dlsym(RTLD_DEFAULT, "get_win_data"));  /* still hidden: only the table is new API */
    puts("ok");
    return 0;
}
