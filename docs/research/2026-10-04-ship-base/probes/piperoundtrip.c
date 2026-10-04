/* Baseline for server-based sync: a cross-process request/reply over pipes (wineserver's transport shape). */
#include <stdio.h>
#include <time.h>
#include <unistd.h>
#define N 20000
int main(void)
{
    int a[2], b[2]; char c = 0; pipe( a ); pipe( b );
    if (!fork()) { for (int i = 0; i < N; i++) { read( a[0], &c, 1 ); write( b[1], &c, 1 ); } _exit( 0 ); }
    unsigned long long t0 = clock_gettime_nsec_np( CLOCK_UPTIME_RAW );
    for (int i = 0; i < N; i++) { write( a[1], &c, 1 ); read( b[0], &c, 1 ); }
    unsigned long long t1 = clock_gettime_nsec_np( CLOCK_UPTIME_RAW );
    printf( "%d cross-process pipe round trips: %.2f us each\n", N, (t1 - t0) / 1000.0 / N );
    return 0;
}
