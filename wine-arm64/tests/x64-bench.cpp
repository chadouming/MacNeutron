// Gate G4 (native arm64 spec §8): x64 microbenchmarks, one .exe run under FEX and under Rosetta. Measured, not gated.
// Prints the CPUID features this side sees and MXCSR, then OutputDebugStringA("jit: start") (gate G5 counts W^X flips
// after it), then `row <name> <seconds>` per row, or `row <name> skipped` when CPUID lacks the row's instructions.
// Each row does a fixed amount of work, the same on both sides, timed with QueryPerformanceCounter; setup and the
// result checks of the rows that have one are outside the timing. A row that did the wrong work prints FAIL x64-bench.
// The 29 single-threaded rows carry the names of neo773's fex-vs-rosetta gist (its source isn't published, so the
// kernels are ours); mt_* rows are multithreaded, call_* rows call-heavy. Built -O2: opaque() hides a value from the
// optimizer (an empty asm that "changes" it), so no row is folded, hoisted, vectorized or turned into a library call.
// mem_seq_read and mem_seq_write stay out of line: check.sh's fex-vmd names their ranges.
#include <windows.h>
#include <cpuid.h>
#include <immintrin.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <functional>

typedef uint64_t u64;
#define opaque(v) asm volatile("" : "+r"(v))
#define opaque_x(v) asm volatile("" : "+x"(v))
#define NOINLINE __attribute__((noinline))
#define MB (1ull << 20)

static double freq;
static double now() {
  LARGE_INTEGER t;
  QueryPerformanceCounter(&t);
  return t.QuadPart / freq;
}
static volatile u64 sink;  // every row's result lands here, so its work is live
static void row(const char *name, u64 (*kernel)()) {
  double t0 = now();
  sink += kernel();
  printf("row %s %.6f\n", name, now() - t0);
}
static void skipped(const char *name) { printf("row %s skipped\n", name); }
static void fail(const char *name, const char *why) {  // a row that did the wrong work: no more rows
  printf("FAIL x64-bench: %s: %s\n", name, why);
  ExitProcess(1);
}

static u64 rng = 0x9E3779B97F4A7C15ull;
static u64 next_random() {  // xorshift64
  rng ^= rng << 13, rng ^= rng >> 7, rng ^= rng << 17;
  return rng;
}
static uint8_t random_bits[65536], pattern_bits[65536];  // 0/1 at random; 1 every 8th entry
static double doubles[1024];
static char *alloc(u64 bytes) {  // committed and touched, so no row pays page faults
  char *p = (char *)VirtualAlloc(NULL, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
  if (!p) {
    printf("FAIL x64-bench: VirtualAlloc %llu MB failed with error %lu\n", bytes / MB, GetLastError());
    exit(1);
  }
  for (u64 i = 0; i < bytes; i += 4096) p[i] = (char)i;
  return p;
}
static void release(void *p) { VirtualFree(p, 0, MEM_RELEASE); }

// ---- The 29 single-threaded rows ----

static u64 int_add_chain() {  // one dependent chain of adds
  u64 a = 1, b = 3;
  for (u64 i = 0; i < 1200000000; i++) {
    a += b; opaque(a);
    b += a; opaque(b);
    a += i; opaque(a);
    b += 7; opaque(b);
  }
  return a ^ b;
}

static u64 int_mul_chain() {  // one dependent chain of 64-bit imul
  u64 x = 12345;
  for (u64 i = 0; i < 750000000; i++) {
    x *= 0x9E3779B97F4A7C15ull; opaque(x);
    x *= 0xBF58476D1CE4E5B9ull; opaque(x);
  }
  return x;
}

static u64 int_div64() {  // one dependent chain of 64-bit div; the divisor is opaque, so no multiply-by-reciprocal
  u64 d = 1000003, x = ~0ull;
  opaque(d);
  for (u64 i = 0; i < 400000000; i++) {
    x = (x / d) | 0xF000000000000000ull;  // the dividend stays above 2^32: always the 64-bit div
    opaque(x);
  }
  return x;
}

__attribute__((target("popcnt"))) static u64 popcnt() {
  u64 acc = 0, x = 0x0123456789ABCDEFull;
  for (u64 i = 0; i < 800000000; i++) {
    acc += __builtin_popcountll(x) + __builtin_popcountll(x ^ i) + __builtin_popcountll(x + i)
         + __builtin_popcountll(x * i);
    x += 0x9E3779B97F4A7C15ull;
    opaque(acc); opaque(x);
  }
  return acc;
}

static u64 bitops_mix() {  // rol, shr, bswap, tzcnt (rep bsf, so bsf before BMI1), bsr, bt+adc, and/or/xor
  u64 x = 0x0123456789ABCDEFull, acc = 0;
  for (u64 i = 0; i < 700000000; i++) {
    x = __builtin_rotateleft64(x, 13) ^ (x >> 7);
    x = __builtin_bswap64(x) + i;
    acc += __builtin_ctzll(x | 1ull << 63) + __builtin_clzll(x | 1) + ((x >> (i & 63)) & 1);  // the bit test is a bt
    acc ^= (x & 0xF0F0F0F0F0F0F0F0ull) | (acc << 1);
    opaque(x); opaque(acc);
  }
  return acc ^ x;
}

// A real branch per iteration: each arm holds its own volatile asm, which can't be speculated into a select.
NOINLINE static u64 branchy(const uint8_t *bits, u64 n) {
  u64 a = 0, b = 0;
  for (u64 i = 0; i < n; i++) {
    if (bits[i & 65535]) {
      a += i; opaque(a);
    } else {
      b ^= i; opaque(b);
    }
  }
  return a ^ b;
}
static u64 branch_predictable() { return branchy(pattern_bits, 1500000000); }
static u64 branch_random() { return branchy(random_bits, 600000000); }

static u64 cmov_select() {  // the same random condition as branch_random, through cmovnz
  u64 a = 0, b = 1;
  for (u64 i = 0; i < 1800000000; i++) {
    u64 c = random_bits[i & 65535], t = a + i;
    asm("test %2, %2\n\tcmovnz %1, %0" : "+r"(a) : "r"(t), "r"(c) : "cc");
    b += a; opaque(b);
  }
  return a ^ b;
}

NOINLINE static u64 f_add(u64 x) { return x + 3; }
NOINLINE static u64 f_xor(u64 x) { return x ^ 0x55; }
NOINLINE static u64 f_mul(u64 x) { return x * 5; }
NOINLINE static u64 f_rot(u64 x) { return __builtin_rotateleft64(x, 9); }
static u64 (*fns[4])(u64) = {f_add, f_xor, f_mul, f_rot};

static u64 indirect_calls() {  // call [table + (i & 3) * 8]: four targets in turn
  u64 (**t)(u64) = fns, x = 1;
  asm volatile("" : "+r"(t) : : "memory");  // the table's contents are unknown: no promotion to direct calls
  for (u64 i = 0; i < 500000000; i++) x = t[i & 3](x);
  return x;
}

static u64 direct_calls() {
  u64 x = 1;
  for (u64 i = 0; i < 300000000; i++) {
    x = f_rot(f_mul(f_xor(f_add(x))));
    opaque(x);
  }
  return x;
}

static u64 sse_scalar_f32() {  // one dependent chain of mulss/addss/subss
  float x = 1.0f;
  for (u64 i = 0; i < 600000000; i++) {
    x = x * 0.999f + 0.5f;
    x = x - 0.25f;
    opaque_x(x);
  }
  return (u64)x;
}

static u64 sse_scalar_f64() {  // the same in mulsd/addsd/subsd
  double x = 1.0;
  for (u64 i = 0; i < 600000000; i++) {
    x = x * 0.999 + 0.5;
    x = x - 0.25;
    opaque_x(x);
  }
  return (u64)x;
}

static u64 sse_packed_ps() {  // four independent chains of mulps/addps
  __m128 m = _mm_set1_ps(0.999f), a = _mm_set1_ps(0.5f);
  __m128 v0 = _mm_set1_ps(1), v1 = _mm_set1_ps(2), v2 = _mm_set1_ps(3), v3 = _mm_set1_ps(4);
  for (u64 i = 0; i < 750000000; i++) {
    v0 = _mm_add_ps(_mm_mul_ps(v0, m), a);
    v1 = _mm_add_ps(_mm_mul_ps(v1, m), a);
    v2 = _mm_add_ps(_mm_mul_ps(v2, m), a);
    v3 = _mm_add_ps(_mm_mul_ps(v3, m), a);
    opaque_x(v0); opaque_x(v1); opaque_x(v2); opaque_x(v3);  // no chain folds
  }
  return (u64)_mm_cvtss_f32(_mm_add_ps(_mm_add_ps(v0, v1), _mm_add_ps(v2, v3)));
}

static u64 sse_int_paddd() {  // paddd/pxor chains (the subtraction of k compiles to a paddd of -k)
  __m128i k = _mm_set_epi32(1, 2, 3, 4), v0 = _mm_set1_epi32(5), v1 = _mm_set1_epi32(6), v2 = _mm_set1_epi32(7);
  for (u64 i = 0; i < 900000000; i++) {
    v0 = _mm_add_epi32(v0, k); opaque_x(v0);
    v1 = _mm_sub_epi32(_mm_add_epi32(v1, v0), k);
    v2 = _mm_xor_si128(_mm_add_epi32(v2, v1), v0);
    opaque_x(v1); opaque_x(v2);
  }
  return (u64)_mm_cvtsi128_si32(_mm_add_epi32(v0, _mm_add_epi32(v1, v2)));
}

static u64 sse_shuffle() {  // pshufd, pshuflw, shufps, unpcklps, each kept apart so none merge
  __m128i v = _mm_set_epi32(1, 2, 3, 4);
  __m128 f = _mm_set_ps(1, 2, 3, 4), g = _mm_set_ps(5, 6, 7, 8);
  for (u64 i = 0; i < 600000000; i++) {
    v = _mm_shuffle_epi32(v, 0x1B); opaque_x(v);
    v = _mm_shufflelo_epi16(v, 0xB1); opaque_x(v);
    f = _mm_shuffle_ps(f, g, 0x39); opaque_x(f);
    g = _mm_unpacklo_ps(g, f); opaque_x(g);
  }
  return (u64)_mm_cvtsi128_si32(v) + (u64)_mm_cvtss_f32(_mm_add_ps(f, g));
}

static u64 cvttsd2si() {  // double -> int64, truncating, from a table
  u64 acc = 0;
  for (u64 i = 0; i < 1000000000; i++) {
    const double *d = doubles + (i & 1020);
    acc += (int64_t)d[0] + (int64_t)d[1] + (int64_t)d[2] + (int64_t)d[3];
    opaque(acc);
  }
  return acc;
}

static u64 sqrtps() {  // four independent chains of addps + sqrtps
  __m128 c = _mm_set1_ps(2.0f), v0 = _mm_set1_ps(1), v1 = _mm_set1_ps(2), v2 = _mm_set1_ps(3), v3 = _mm_set1_ps(4);
  for (u64 i = 0; i < 300000000; i++) {
    v0 = _mm_sqrt_ps(_mm_add_ps(v0, c));
    v1 = _mm_sqrt_ps(_mm_add_ps(v1, c));
    v2 = _mm_sqrt_ps(_mm_add_ps(v2, c));
    v3 = _mm_sqrt_ps(_mm_add_ps(v3, c));
    opaque_x(v0); opaque_x(v1); opaque_x(v2); opaque_x(v3);  // v1 = 2 is sqrt(v1 + 2)'s fixed point
  }
  return (u64)_mm_cvtss_f32(_mm_add_ps(_mm_add_ps(v0, v1), _mm_add_ps(v2, v3)));
}

static u64 divps() {  // four independent chains of addps + divps
  __m128 c = _mm_set1_ps(3.0f), one = _mm_set1_ps(1.0f);
  __m128 v0 = _mm_set1_ps(1), v1 = _mm_set1_ps(2), v2 = _mm_set1_ps(3), v3 = _mm_set1_ps(4);
  for (u64 i = 0; i < 400000000; i++) {
    v0 = _mm_div_ps(c, _mm_add_ps(v0, one));
    v1 = _mm_div_ps(c, _mm_add_ps(v1, one));
    v2 = _mm_div_ps(c, _mm_add_ps(v2, one));
    v3 = _mm_div_ps(c, _mm_add_ps(v3, one));
    opaque_x(v0); opaque_x(v1); opaque_x(v2); opaque_x(v3);  // no chain folds
  }
  return (u64)(_mm_cvtss_f32(_mm_add_ps(_mm_add_ps(v0, v1), _mm_add_ps(v2, v3))) * 1000);
}

// addss/subss on denormal operands and results, with MXCSR as Wine sets it (printed with the CPUID line). All four
// values are below FLT_MIN (1.18e-38) and their sums are exact, so each chain ends where it started; flushing any input
// or result to zero (DAZ, FTZ) would end it at 0. main checks that, untimed.
static const float denormal_x = 1e-39f, denormal_y = 2e-39f;
static float denormal_end[2];
static u64 denormal_adds() {
  float x = denormal_x, y = denormal_y, d = 1e-40f, e = 3e-41f;
  opaque_x(x); opaque_x(y); opaque_x(d); opaque_x(e);
  for (u64 i = 0; i < 900000000; i++) {
    x = x + d; x = x - d; opaque_x(x);
    y = y + e; y = y - e; opaque_x(y);
  }
  denormal_end[0] = x, denormal_end[1] = y;
  return 0;
}

__attribute__((target("sse4.1"))) static u64 sse41_dpps() {  // four independent chains of dpps
  __m128 w = _mm_set1_ps(0.25f), v0 = _mm_set1_ps(1), v1 = _mm_set1_ps(2), v2 = _mm_set1_ps(3), v3 = _mm_set1_ps(4);
  for (u64 i = 0; i < 300000000; i++) {
    v0 = _mm_dp_ps(v0, w, 0xFF);
    v1 = _mm_dp_ps(v1, w, 0xFF);
    v2 = _mm_dp_ps(v2, w, 0xFF);
    v3 = _mm_dp_ps(v3, w, 0xFF);
    opaque_x(v0); opaque_x(v1); opaque_x(v2); opaque_x(v3);  // each start is a fixed point
  }
  return (u64)_mm_cvtss_f32(_mm_add_ps(_mm_add_ps(v0, v1), _mm_add_ps(v2, v3)));
}

__attribute__((target("avx2"))) static u64 avx2_packed_ps() {  // four independent chains of 256-bit vmulps/vaddps
  __m256 m = _mm256_set1_ps(0.999f), a = _mm256_set1_ps(0.5f);
  __m256 v0 = _mm256_set1_ps(1), v1 = _mm256_set1_ps(2), v2 = _mm256_set1_ps(3), v3 = _mm256_set1_ps(4);
  for (u64 i = 0; i < 200000000; i++) {
    v0 = _mm256_add_ps(_mm256_mul_ps(v0, m), a);
    v1 = _mm256_add_ps(_mm256_mul_ps(v1, m), a);
    v2 = _mm256_add_ps(_mm256_mul_ps(v2, m), a);
    v3 = _mm256_add_ps(_mm256_mul_ps(v3, m), a);
    opaque_x(v0); opaque_x(v1); opaque_x(v2); opaque_x(v3);  // no chain folds
  }
  __m256 s = _mm256_add_ps(_mm256_add_ps(v0, v1), _mm256_add_ps(v2, v3));
  return (u64)_mm_cvtss_f32(_mm256_castps256_ps128(s));
}

__attribute__((target("avx2,fma"))) static u64 fma256_ps() {  // eight independent chains of 256-bit vfmadd
  __m256 m = _mm256_set1_ps(0.999f), a = _mm256_set1_ps(0.5f), v[8];
  for (int k = 0; k < 8; k++) v[k] = _mm256_set1_ps((float)k);
  for (u64 i = 0; i < 400000000; i++) {
    for (int k = 0; k < 8; k++) {
      v[k] = _mm256_fmadd_ps(v[k], m, a);
      opaque_x(v[k]);  // no chain folds
    }
  }
  __m256 s = v[0];
  for (int k = 1; k < 8; k++) s = _mm256_add_ps(s, v[k]);
  return (u64)_mm_cvtss_f32(_mm256_castps256_ps128(s));
}

static char *buf_a, *buf_b;  // 64 MB each

NOINLINE static u64 mem_seq_read() {  // 8-byte loads over 64 MB, 400 passes
  const u64 *p = (const u64 *)buf_a;
  u64 s0 = 0, s1 = 0, s2 = 0, s3 = 0;
  for (int pass = 0; pass < 400; pass++) {
    for (u64 i = 0; i < 64 * MB / 8; i += 4) {
      s0 += p[i]; s1 += p[i + 1]; s2 += p[i + 2]; s3 += p[i + 3];
      asm volatile("" : "+r"(s0), "+r"(s1), "+r"(s2), "+r"(s3));
    }
  }
  return s0 ^ s1 ^ s2 ^ s3;
}

NOINLINE static u64 mem_seq_write() {  // 8-byte stores over 64 MB, 400 passes
  u64 *p = (u64 *)buf_b, v = 1;
  for (int pass = 0; pass < 400; pass++) {
    for (u64 i = 0; i < 64 * MB / 8; i += 4) {
      p[i] = v; opaque(v);
      p[i + 1] = v; opaque(v);
      p[i + 2] = v; opaque(v);
      p[i + 3] = v; v++; opaque(v);
    }
  }
  return p[12345];
}

static void **chase;  // a single random cycle through the 64 MB buffer's cache lines (Sattolo's shuffle)
static u64 mem_random_chase() {
  void **p = chase;
  for (u64 i = 0; i < 8000000; i++) p = (void **)*p;
  return (u64)p;
}

static u64 rep_movsb_64MB() {  // rep movsb, 64 MB each, 200 times
  for (int r = 0; r < 200; r++) {
    char *d = buf_b;
    const char *s = buf_a;
    u64 n = 64 * MB;
    asm volatile("rep movsb" : "+D"(d), "+S"(s), "+c"(n) : : "memory");
  }
  return (u64)buf_b[4321];
}

static u64 memcpy_256B_hot() {  // 256-byte copies in 16-byte movups, the way compilers inline them, within 4 KB
  static char hot[4096];
  char *h = hot;
  for (u64 i = 0; i < 400000000; i++) {
    char *d = h + 2048 + (i & 7) * 256, *s = h + (i & 7) * 256;
    for (int k = 0; k < 256; k += 16) {  // opaque_x keeps it from becoming a memcpy call or rep movsb
      __m128i v = _mm_loadu_si128((const __m128i *)(s + k));
      opaque_x(v);
      _mm_storeu_si128((__m128i *)(d + k), v);
    }
    opaque(h);
  }
  return (u64)hot[3000];
}

static volatile u64 shared_counter;
static u64 atomic_xadd() {  // lock xadd, uncontended
  u64 acc = 0;
  for (u64 i = 0; i < 500000000; i++) acc += __atomic_fetch_add(&shared_counter, i, __ATOMIC_SEQ_CST);
  return acc;
}

#define CMPXCHGS 250000000
static u64 cmpxchg_ok;  // how many succeeded; main checks all of them did
static u64 atomic_cmpxchg() {  // lock cmpxchg, uncontended: each one succeeds
  u64 old = shared_counter, ok = 0;
  for (u64 i = 0; i < CMPXCHGS; i++) {
    u64 want = old + 1;
    if (__atomic_compare_exchange_n(&shared_counter, &old, want, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST))
      old = want, ok++;
  }
  cmpxchg_ok = ok;
  return old;
}

// ---- Multithreaded rows: the threads start together on a flag; the time runs from the flag to the last join ----

static volatile LONG started, go;
static void wait_for_go() {
  InterlockedIncrement(&started);
  while (!__atomic_load_n(&go, __ATOMIC_ACQUIRE)) {}
}
static double threads(int n, LPTHREAD_START_ROUTINE fn, void **args) {
  HANDLE h[8];
  started = 0, go = 0;
  for (int k = 0; k < n; k++) {
    h[k] = CreateThread(NULL, 0, fn, args ? args[k] : NULL, 0, NULL);
    if (!h[k]) {
      printf("FAIL x64-bench: CreateThread failed with error %lu\n", GetLastError());
      exit(1);
    }
  }
  while (started < n) Sleep(0);
  double t0 = now();
  __atomic_store_n(&go, 1, __ATOMIC_RELEASE);
  WaitForMultipleObjects(n, h, TRUE, INFINITE);
  double t = now() - t0;
  for (int k = 0; k < n; k++) CloseHandle(h[k]);
  return t;
}

#define XADDS 20000000
static DWORD WINAPI xadd_worker(void *) {  // contended lock xadd on one counter
  wait_for_go();
  u64 acc = 0;
  for (u64 i = 0; i < XADDS; i++) acc += __atomic_fetch_add(&shared_counter, 1, __ATOMIC_SEQ_CST);
  opaque(acc);  // the old value is used: lock xadd, not lock add
  return 0;
}
static void mt_xadd(const char *name, int n) {
  shared_counter = 0;
  double t = threads(n, xadd_worker, NULL);
  if (shared_counter != (u64)n * XADDS) {
    printf("FAIL x64-bench: %s counted %llu, wanted %llu\n", name, (u64)shared_counter, (u64)n * XADDS);
    exit(1);
  }
  printf("row %s %.6f\n", name, t);
}

// Single producer, single consumer, 4096 entries. On x86 a release store and an acquire load are plain movs (TSO
// orders them); each side re-reads the other's index only when its cached copy says the ring is full or empty.
#define RING 4096
#define ITEMS 50000000
static struct {
  alignas(64) volatile u64 head;  // written by the producer
  alignas(64) volatile u64 tail;  // written by the consumer
  alignas(64) u64 slot[RING];
} ring;
static void producer() {
  u64 tail = 0;
  for (u64 i = 0; i < ITEMS; i++) {
    while (i - tail == RING) tail = __atomic_load_n(&ring.tail, __ATOMIC_ACQUIRE);
    ring.slot[i % RING] = i + 1;
    __atomic_store_n(&ring.head, i + 1, __ATOMIC_RELEASE);
  }
}
static void consumer() {
  u64 head = 0;
  for (u64 i = 0; i < ITEMS; i++) {
    while (head == i) head = __atomic_load_n(&ring.head, __ATOMIC_ACQUIRE);
    if (ring.slot[i % RING] != i + 1) {  // a slot read before the producer's store reached it
      printf("FAIL x64-bench: mt_spsc_ring: item %llu read out of order\n", i + 1);
      ExitProcess(1);  // now: the producer would wait for space forever
    }
    __atomic_store_n(&ring.tail, i + 1, __ATOMIC_RELEASE);
  }
}
static DWORD WINAPI ring_worker(void *consumes) {
  wait_for_go();
  consumes ? consumer() : producer();
  return 0;
}
static void mt_spsc_ring() {
  ring.head = ring.tail = 0;
  void *roles[2] = {NULL, (void *)1};
  printf("row mt_spsc_ring %.6f\n", threads(2, ring_worker, roles));
}

static DWORD WINAPI copy_worker(void *arg) {  // 256 passes of a 64 MB copy, 64 bytes per iteration in movups
  char *d = (char *)arg, *s = d + 64 * MB;
  wait_for_go();
  for (int pass = 0; pass < 256; pass++) {
    for (u64 i = 0; i < 64 * MB; i += 64) {
      __m128i a = _mm_loadu_si128((const __m128i *)(s + i)), b = _mm_loadu_si128((const __m128i *)(s + i + 16));
      __m128i c = _mm_loadu_si128((const __m128i *)(s + i + 32)), e = _mm_loadu_si128((const __m128i *)(s + i + 48));
      _mm_storeu_si128((__m128i *)(d + i), a), _mm_storeu_si128((__m128i *)(d + i + 16), b);
      _mm_storeu_si128((__m128i *)(d + i + 32), c), _mm_storeu_si128((__m128i *)(d + i + 48), e);
      opaque(i);  // no memcpy idiom
    }
  }
  return 0;
}
static void mt_memcpy_4() {
  void *bufs[4];
  for (int k = 0; k < 4; k++) bufs[k] = alloc(128 * MB);  // 64 MB destination, then 64 MB source
  double t = threads(4, copy_worker, bufs);
  for (int k = 0; k < 4; k++) release(bufs[k]);
  printf("row mt_memcpy_4 %.6f\n", t);
}

// ---- Call-heavy rows ----

template <int N> NOINLINE u64 chain(u64 x) { return chain<N - 1>(x + N) * 3 + 1; }  // not a tail call
template <> NOINLINE u64 chain<0>(u64 x) {  // opaque: an identity function's call would be dropped, noinline or not
  opaque(x);
  return x;
}
static u64 call_chain64() {  // chain<63> .. chain<0>: 64 nested direct calls per iteration
  u64 x = 1;
  for (u64 i = 0; i < 4000000; i++) x = chain<63>(x);
  return x;
}

struct Op { virtual u64 apply(u64 x) const = 0; };
struct Add : Op { u64 apply(u64 x) const override { return x + 3; } };
struct Xor : Op { u64 apply(u64 x) const override { return x ^ 0x55; } };
struct Mul : Op { u64 apply(u64 x) const override { return x * 5; } };
struct Rot : Op { u64 apply(u64 x) const override { return __builtin_rotateleft64(x, 9); } };
static u64 call_virtual() {  // four dynamic types in turn, through a base pointer
  static Add add; static Xor xor_; static Mul mul; static Rot rot;
  Op *ops[4] = {&add, &xor_, &mul, &rot}, **o = ops;
  asm volatile("" : "+r"(o) : : "memory");  // the dynamic types are unknown: no devirtualization
  u64 x = 1;
  for (u64 i = 0; i < 700000000; i++) x = o[i & 3]->apply(x);
  return x;
}

static u64 call_std_function() {
  std::function<u64(u64)> fs[2] = {[](u64 x) { return x + 3; }, [](u64 x) { return x ^ 0x55; }}, *f = fs;
  asm volatile("" : "+r"(f) : : "memory");  // the targets are unknown: no inlining through std::function
  u64 x = 1;
  for (u64 i = 0; i < 600000000; i++) x = f[i & 1](x);
  return x;
}

int main() {
  setvbuf(stdout, NULL, _IONBF, 0);  // a crash still leaves the rows that finished
  unsigned a, b, c, d, b7 = 0, a7, c7, d7;
  __get_cpuid(1, &a, &b, &c, &d);
  int osxsave = c >> 27 & 1;
  u64 xcr0 = 0;
  if (osxsave) {
    unsigned lo, hi;
    asm volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
    xcr0 = (u64)hi << 32 | lo;
  }
  if (!__get_cpuid_count(7, 0, &a7, &b7, &c7, &d7)) b7 = 0;
  int sse41 = c >> 19 & 1, avx = (c >> 28 & 1) && osxsave && (xcr0 & 6) == 6;
  int avx2 = avx && (b7 >> 5 & 1), fma = avx && (c >> 12 & 1);
  printf("cpuid sse41=%d avx=%d avx2=%d fma=%d mxcsr=0x%04x\n", sse41, avx, avx2, fma, _mm_getcsr());
  OutputDebugStringA("jit: start");  // gate G5 counts W^X flips after this line (check.sh g5-jit)

  LARGE_INTEGER f;
  QueryPerformanceFrequency(&f);
  freq = (double)f.QuadPart;
  for (int i = 0; i < 65536; i++) random_bits[i] = next_random() >> 63, pattern_bits[i] = (i & 7) == 0;
  for (int i = 0; i < 1024; i++) doubles[i] = (double)(next_random() >> 12) / 7.0 - 1e15;
  buf_a = alloc(64 * MB), buf_b = alloc(64 * MB);
  for (u64 i = 0; i < 64 * MB / 8; i++) ((u64 *)buf_a)[i] = i * 0x9E3779B97F4A7C15ull;  // rep_movsb_64MB's source
  u64 lines = 64 * MB / 64;
  char *chase_buf = alloc(64 * MB);
  u64 *order = (u64 *)buf_b;  // scratch for the shuffle
  for (u64 i = 0; i < lines; i++) order[i] = i;
  for (u64 i = lines - 1; i > 0; i--) {  // Sattolo: one cycle through every line
    u64 j = next_random() % i, t = order[i];
    order[i] = order[j], order[j] = t;
  }
  for (u64 i = 0; i < lines; i++) *(void **)(chase_buf + order[i] * 64) = chase_buf + order[(i + 1) % lines] * 64;
  chase = (void **)chase_buf;

  row("int_add_chain", int_add_chain);
  row("int_mul_chain", int_mul_chain);
  row("int_div64", int_div64);
  row("popcnt", popcnt);
  row("bitops_mix", bitops_mix);
  row("branch_predictable", branch_predictable);
  row("branch_random", branch_random);
  row("cmov_select", cmov_select);
  row("indirect_calls", indirect_calls);
  row("direct_calls", direct_calls);
  row("sse_scalar_f32", sse_scalar_f32);
  row("sse_scalar_f64", sse_scalar_f64);
  row("sse_packed_ps", sse_packed_ps);
  row("sse_int_paddd", sse_int_paddd);
  row("sse_shuffle", sse_shuffle);
  row("cvttsd2si", cvttsd2si);
  row("sqrtps", sqrtps);
  row("divps", divps);
  row("denormal_adds", denormal_adds);
  // The bits, not a float compare: under DAZ a compare would read both denormals as zero and call them equal.
  if (memcmp(denormal_end, &denormal_x, 4) || memcmp(denormal_end + 1, &denormal_y, 4))
    fail("denormal_adds", "denormals were flushed");
  if (sse41) row("sse41_dpps", sse41_dpps); else skipped("sse41_dpps");
  if (avx2) row("avx2_packed_ps", avx2_packed_ps); else skipped("avx2_packed_ps");
  if (avx2 && fma) row("fma256_ps", fma256_ps); else skipped("fma256_ps");
  row("mem_seq_read", mem_seq_read);
  row("mem_seq_write", mem_seq_write);
  row("mem_random_chase", mem_random_chase);
  memset(buf_b, 0, 64 * MB);  // so a copy that did nothing shows
  row("rep_movsb_64MB", rep_movsb_64MB);
  if (memcmp(buf_a, buf_b, 64 * MB)) fail("rep_movsb_64MB", "the destination differs from the source");
  row("memcpy_256B_hot", memcpy_256B_hot);
  row("atomic_xadd", atomic_xadd);
  u64 counter_before = shared_counter;
  row("atomic_cmpxchg", atomic_cmpxchg);
  if (cmpxchg_ok != CMPXCHGS || shared_counter != counter_before + CMPXCHGS)
    fail("atomic_cmpxchg", "a compare-exchange failed");
  release(chase_buf), release(buf_a), release(buf_b);

  mt_xadd("mt_xadd_4", 4);
  mt_xadd("mt_xadd_8", 8);
  mt_spsc_ring();
  mt_memcpy_4();

  row("call_chain64", call_chain64);
  row("call_virtual", call_virtual);
  row("call_std_function", call_std_function);
  return 0;
}
