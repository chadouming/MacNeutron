/* msync primitive probe: the private/mach calls msync depends on, across two processes,
 * under the hardened runtime. Usage: msyncprobe server NAME & ; msyncprobe client NAME
 * Mirrors server/msync.c (bootstrap_register2, mach_make_memory_entry_64, VM_INHERIT_SHARE)
 * and dlls/ntdll/unix/msync.c (bootstrap_look_up, mach_vm_map of the entry, __ulock_wait2). */
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/vm_page_size.h>
#include <servers/bootstrap.h>
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define UL_COMPARE_AND_WAIT_SHARED 0x3
#define ULF_NO_ERRNO 0x01000000
extern int __ulock_wake( uint32_t op, void *addr, uint64_t wake_value );
extern int __ulock_wait2( uint32_t op, void *addr, uint64_t value, uint64_t timeout_ns, uint64_t value2 );
extern kern_return_t bootstrap_register2( mach_port_t bp, name_t service_name, mach_port_t sp, int flags );

typedef struct { mach_msg_header_t header; int entry; } req_t;
typedef struct { mach_msg_header_t header; mach_msg_body_t body; mach_msg_port_descriptor_t d; mach_msg_trailer_t t; } rep_t;
typedef struct { mach_msg_header_t header; mach_msg_body_t body; mach_msg_port_descriptor_t d; } rep_send_t;

#define N 20000
static uint64_t now_ns(void) { return clock_gettime_nsec_np( CLOCK_UPTIME_RAW ); }

int main( int argc, char **argv )
{
    mach_port_t bp; kern_return_t kr;
    if (argc < 3) return 2;
    task_get_special_port( mach_task_self(), TASK_BOOTSTRAP_PORT, &bp );
    printf( "[%s] pagesize=%d vm_page_size=%lu vm_kernel_page_size=%lu mach_msg2_trap=%s\n", argv[1], getpagesize(),
            (unsigned long)vm_page_size, (unsigned long)vm_kernel_page_size,
            dlsym( RTLD_DEFAULT, "mach_msg2_trap" ) ? "yes" : "no" );

    if (!strcmp( argv[1], "server" ))
    {
        mach_port_t port; mach_vm_address_t shm = 0; volatile int *w;
        mach_port_allocate( mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port );
        mach_port_insert_right( mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND );
        kr = bootstrap_register2( bp, argv[2], port, 0 );
        printf( "[server] bootstrap_register2=%d\n", kr ); if (kr) return 1;
        kr = mach_vm_map( mach_task_self(), &shm, vm_kernel_page_size, 0, VM_FLAGS_ANYWHERE, MACH_PORT_NULL, 0, FALSE,
                          VM_PROT_DEFAULT, VM_PROT_DEFAULT, VM_INHERIT_SHARE );
        printf( "[server] mach_vm_map=%d\n", kr ); if (kr) return 1;
        w = (volatile int *)shm;
        {   /* one request: hand out a memory entry for the page (send_shm_to_client) */
            struct { req_t r; mach_msg_trailer_t t; } in; rep_send_t out; mach_vm_size_t sz = vm_kernel_page_size; mach_port_t ent;
            memset( &in, 0, sizeof(in) );
            kr = mach_msg( &in.r.header, MACH_RCV_MSG, 0, sizeof(in), port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL );
            kr |= mach_make_memory_entry_64( mach_task_self(), &sz, shm, VM_PROT_DEFAULT, &ent, MACH_PORT_NULL );
            memset( &out, 0, sizeof(out) );
            out.header.msgh_bits = MACH_MSGH_BITS_SET( MACH_MSG_TYPE_COPY_SEND, 0, 0, MACH_MSGH_BITS_COMPLEX );
            out.header.msgh_size = sizeof(out); out.header.msgh_remote_port = in.r.header.msgh_remote_port;
            out.body.msgh_descriptor_count = 1; out.d.name = ent; out.d.disposition = MACH_MSG_TYPE_COPY_SEND;
            out.d.type = MACH_MSG_PORT_DESCRIPTOR;
            kr |= mach_msg( &out.header, MACH_SEND_MSG, sizeof(out), 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL );
            printf( "[server] served memory entry size=%llu kr=%d\n", sz, kr );
        }
        /* ping-pong: w[0] is "client's turn" word, w[1] is "server's turn" word */
        for (int i = 0; i < N; i++)
        {
            while (__atomic_load_n( &w[1], __ATOMIC_ACQUIRE ) == 0)
                __ulock_wait2( UL_COMPARE_AND_WAIT_SHARED | ULF_NO_ERRNO, (void *)&w[1], 0, 1000000000ull, 0 );
            __atomic_store_n( &w[1], 0, __ATOMIC_RELAXED );
            __atomic_store_n( &w[0], 1, __ATOMIC_RELEASE );
            __ulock_wake( UL_COMPARE_AND_WAIT_SHARED | ULF_NO_ERRNO, (void *)&w[0], 0 );
        }
        printf( "[server] done\n" );
        return 0;
    }
    else
    {
        mach_port_t sp, reply, ent; mach_vm_address_t addr = 0; volatile int *w; uint64_t t0, t1;
        for (int i = 0; i < 100 && (kr = bootstrap_look_up( bp, argv[2], &sp )); i++) usleep( 10000 );
        printf( "[client] bootstrap_look_up=%d\n", kr ); if (kr) return 1;
        mach_port_allocate( mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply );
        mach_port_insert_right( mach_task_self(), reply, reply, MACH_MSG_TYPE_MAKE_SEND );
        {
            req_t r; rep_t in; memset( &r, 0, sizeof(r) ); memset( &in, 0, sizeof(in) );
            r.header.msgh_bits = MACH_MSGH_BITS_SET( MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_COPY_SEND, 0, 0 );
            r.header.msgh_size = sizeof(r); r.header.msgh_remote_port = sp; r.header.msgh_local_port = reply;
            kr = mach_msg_overwrite( &r.header, MACH_SEND_MSG | MACH_RCV_MSG, sizeof(r), sizeof(in), reply,
                                     MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL, &in.header, 0 );
            ent = in.d.name;
            kr |= mach_vm_map( mach_task_self(), &addr, vm_kernel_page_size, 0, VM_FLAGS_ANYWHERE, ent, 0, FALSE,
                               VM_PROT_DEFAULT, VM_PROT_DEFAULT, VM_INHERIT_NONE );
            printf( "[client] mapped shared page at %#llx kr=%d\n", addr, kr ); if (kr) return 1;
        }
        w = (volatile int *)addr;
        t0 = now_ns();
        for (int i = 0; i < N; i++)
        {
            __atomic_store_n( &w[1], 1, __ATOMIC_RELEASE );
            __ulock_wake( UL_COMPARE_AND_WAIT_SHARED | ULF_NO_ERRNO, (void *)&w[1], 0 );
            while (__atomic_load_n( &w[0], __ATOMIC_ACQUIRE ) == 0)
                __ulock_wait2( UL_COMPARE_AND_WAIT_SHARED | ULF_NO_ERRNO, (void *)&w[0], 0, 1000000000ull, 0 );
            __atomic_store_n( &w[0], 0, __ATOMIC_RELAXED );
        }
        t1 = now_ns();
        printf( "[client] %d cross-process ulock round trips: %.2f us each\n", N, (t1 - t0) / 1000.0 / N );
        return 0;
    }
}
