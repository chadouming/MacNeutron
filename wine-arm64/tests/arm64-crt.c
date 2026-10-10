// msvcrt's string routines (batch Task 6, Wine patch 0035): memmove, memcpy, strlen, strnlen, strchr, strrchr, strcmp
// and memchr against byte loops. One source built as ARM64 (arm64-crt.exe), ARM64EC (arm64ec-crt.exe) and x64
// (x64-crt.exe, under FEX), -fno-builtin so every call reaches the CRT DLL. Each routine has a byte-loop reference
// (ref_*); the harness does its own string work with those and its own loops, never with the routines under test
// (printf still uses the DLL's). Every length to 300, every alignment (0-31 for strlen, strnlen and memchr, which work
// in aligned 32-byte chunks; 0-15 for the rest), memmove's overlaps, and both sides of a no-access host page. The bytes
// a routine may read but must ignore hold what it looks for. Prints `ok <routine> <cases>` or, at a routine's first
// mismatch, `FAIL <routine>: <case>: got <x>, wanted <y>`; then `PASS <name>` or `FAIL <name>: <n> of 8 routines
// failed` (<name>: the exe's file name without .exe). A crash prints `FAIL <name>: <routine> <case>: exception <code>`
// and exits 1.
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define KB 1024
#define MAXLEN 300

static __declspec(align(64)) unsigned char buf1[KB], buf2[KB], want[KB];
// Two allocations of 96 KB, [0, 32K) and [64K, 96K) no access: Wine protects whole host pages (16K here), so a guard
// has to cover whole host pages. Data at an end guard ends on base + 64K - 1, at a start guard begins at base + 32K.
static unsigned char *guard[2];
#define END(g) (guard[g] + 64 * KB)
#define START(g) (guard[g] + 32 * KB)

static char name[MAX_PATH];
static const char *routine = "setup", *where = "", *cfmt = "";
static long long cv[6];
static int failed;

// The case, for a FAIL line: where it runs, a printf format and up to six numbers.
#define CASE(...) set_case(__VA_ARGS__, 0, 0, 0, 0, 0, 0)
static void set_case(const char *fmt, long long a, long long b, long long c, long long d, long long e, long long f,
                     ...) {
  cfmt = fmt;
  cv[0] = a, cv[1] = b, cv[2] = c, cv[3] = d, cv[4] = e, cv[5] = f;
}
static long long al(const void *p) { return (long long)((uintptr_t)p % 64); }

// The start of a routine's FAIL line; its first failure ends its cases.
static void fail_begin(void) {
  failed = 1;
  printf("FAIL %s: %s", routine, where);
  printf(cfmt, cv[0], cv[1], cv[2], cv[3], cv[4], cv[5]);
}
static void show_ptr(const void *x, const void *p) {
  if (!x) printf("NULL");
  else printf("p%+lld", (long long)((const char *)x - (const char *)p));
}
static int check_ptr(const void *got, const void *exp, const void *p) {
  if (got == exp) return 1;
  fail_begin();
  printf(": got ");
  show_ptr(got, p);
  printf(", wanted ");
  show_ptr(exp, p);
  printf("\n");
  return 0;
}
static int check_num(long long got, long long exp) {
  if (got == exp) return 1;
  fail_begin();
  printf(": got %lld, wanted %lld\n", got, exp);
  return 0;
}

static LONG WINAPI on_exception(EXCEPTION_POINTERS *e) {
  printf("FAIL %s: %s %s", name, routine, where);
  printf(cfmt, cv[0], cv[1], cv[2], cv[3], cv[4], cv[5]);
  printf(": exception %#lx\n", e->ExceptionRecord->ExceptionCode);
  ExitProcess(1);
}

// The references: byte loops, as Wine's C versions (ref_strcmp answers -1/0/1 over unsigned bytes).
static __declspec(noinline) void *ref_memmove(void *dst, const void *src, size_t n) {
  unsigned char *d = dst;
  const unsigned char *s = src;
  if ((uintptr_t)d < (uintptr_t)s)
    for (size_t i = 0; i < n; i++) d[i] = s[i];
  else
    for (size_t i = n; i--;) d[i] = s[i];
  return dst;
}
static __declspec(noinline) size_t ref_strlen(const char *s) {
  size_t i = 0;
  while (s[i]) i++;
  return i;
}
static __declspec(noinline) size_t ref_strnlen(const char *s, size_t max) {
  size_t i = 0;
  while (i < max && s[i]) i++;
  return i;
}
static __declspec(noinline) char *ref_strchr(const char *s, int c) {
  for (;; s++) {
    if (*s == (char)c) return (char *)s;
    if (!*s) return NULL;
  }
}
static __declspec(noinline) char *ref_strrchr(const char *s, int c) {
  const char *r = NULL;
  for (;; s++) {
    if (*s == (char)c) r = s;
    if (!*s) return (char *)r;
  }
}
static __declspec(noinline) int ref_strcmp(const char *a, const char *b) {
  const unsigned char *x = (const unsigned char *)a, *y = (const unsigned char *)b;
  while (*x && *x == *y) x++, y++;
  return (*x > *y) - (*x < *y);
}
static __declspec(noinline) void *ref_memchr(const void *p, int c, size_t n) {
  for (const unsigned char *q = p; n; n--, q++)
    if (*q == (unsigned char)c) return (void *)q;
  return NULL;
}

// A string body's byte i: 0x01, 0x7f, 0x80 and 0xff in turn at the even indexes (all four in every 8 bytes), the odd
// ones counting through 0x01-0xff. Never 0.
static const unsigned char specials[4] = {0x01, 0x7f, 0x80, 0xff};
static unsigned char pat(int i) { return i % 2 ? 1 + i / 2 % 255 : specials[i / 2 % 4]; }
// The same with the byte c taken out (memchr's searched byte is only where a case puts it).
static unsigned char pat_without(int i, int c) {
  unsigned char v = pat(i);
  return v != (unsigned char)c ? v : (unsigned char)c == 1 ? 2 : 1;
}
static void set(unsigned char *p, int n, int v) {
  for (int i = 0; i < n; i++) p[i] = (unsigned char)v;
}

// A string of len bytes at p (pat(i + len)) in [lo, hi): pre in the 64 bytes before it, post in the 64 after its
// terminator (post < 0: nonzero bytes), as far as [lo, hi) goes.
static void layout(unsigned char *lo, unsigned char *hi, unsigned char *p, int len, int pre, int post) {
  for (unsigned char *q = p - 64 > lo ? p - 64 : lo; q < p; q++) *q = (unsigned char)pre;
  for (int i = 0; i < len; i++) p[i] = pat(i + len);
  if (p + len < hi) p[len] = 0;
  for (int i = len + 1; i <= len + 64 && p + i < hi; i++) p[i] = post < 0 ? pat(i) : (unsigned char)post;
}

// memmove (which 0) or memcpy (which 1): n bytes from src to dst inside a window of wn bytes the caller filled (src
// inside it or not). The window has to come out as ref_memmove leaves a copy of it, and the result is dst.
static int copy_case(int which, unsigned char *win, int wn, unsigned char *dst, const unsigned char *src, size_t n) {
  for (int i = 0; i < wn; i++) want[i] = win[i];
  int inside = (uintptr_t)src >= (uintptr_t)win && (uintptr_t)src < (uintptr_t)(win + wn);
  ref_memmove(want + (dst - win), inside ? want + (src - win) : src, n);
  void *r = which ? memcpy(dst, src, n) : memmove(dst, src, n);
  if (!check_ptr(r, dst, dst)) return 0;
  for (int i = 0; i < wn; i++)
    if (win[i] != want[i]) {
      fail_begin();
      printf(", byte dst%+lld: got 0x%02x, wanted 0x%02x\n", (long long)(win + i - dst), win[i], want[i]);
      return 0;
    }
  return 1;
}

static long long test_copy(int which) {
  long long cases = 0;
  for (int i = 0; i < KB; i++) buf1[i] = pat(i);
  for (int n = 0; n <= MAXLEN; n++)
    for (int s = 0; s < 16; s++)
      for (int d = 0; d < 16; d++, cases++) {
        CASE("n %lld src+%lld dst+%lld", n, s, d);
        set(buf2, KB, 0xee);
        if (!copy_case(which, buf2, KB, buf2 + 64 + d, buf1 + 64 + s, n)) return cases;
      }
  if (!which)
    for (int n = 0; n <= MAXLEN; n++)
      for (int k = -64; k <= 64; k++, cases++) {
        CASE("overlap n %lld dst=src%+lld", n, k);
        for (int i = 0; i < KB; i++) buf1[i] = pat(i + n);
        if (!copy_case(0, buf1, KB, buf1 + 256 + k, buf1 + 256, n)) return cases;
      }
  // The page edges: the source in one guarded allocation, the destination in the other.
  for (int n = 0; n <= MAXLEN; n++, cases += 2) {
    for (int i = 0; i < n; i++) END(0)[i - n] = START(0)[i] = pat(i);
    where = "end guards, ";
    CASE("n %lld", n);
    set(END(1) - KB, KB, 0xee);
    if (!copy_case(which, END(1) - KB, KB, END(1) - n, END(0) - n, n)) return cases;
    where = "start guards, ";
    set(START(1), KB, 0xee);
    if (!copy_case(which, START(1), KB, START(1), START(0), n)) return cases;
  }
  // memmove's backward overlaps there (dst = src + k): the destination ends on the end guard, the source begins on
  // the start guard.
  if (!which)
    for (int n = 0; n <= MAXLEN; n++)
      for (int k = 1; k <= 64; k++, cases += 2) {
        CASE("overlap n %lld dst=src+%lld", n, k);
        where = "end guard, ";
        for (int i = 0; i < KB; i++) END(0)[i - KB] = START(0)[i] = pat(i + k);
        if (!copy_case(0, END(0) - KB, KB, END(0) - n, END(0) - n - k, n)) return cases;
        where = "start guard, ";
        if (!copy_case(0, START(0), KB, START(0) + k, START(0), n)) return cases;
      }
  where = "";
  if (!which) {
    CASE("memmove(NULL, NULL, 0)");
    if (!check_ptr(memmove(NULL, NULL, 0), NULL, NULL)) return cases;
    cases++;
  }
  return cases;
}

// strlen (strn 0), or strnlen at maxlen 0, len / 2, len, len + 1 and SIZE_MAX, on the layout() string at p, 0 before
// it and nonzero bytes after its terminator; below len, strnlen also gets 0s after p + maxlen + 1 (p[maxlen] stays
// nonzero, so a count past maxlen shows).
static int len_cases(int strn, unsigned char *p, int len, long long *cases) {
  if (!strn) {
    CASE("len %lld +%lld", len, al(p));
    ++*cases;
    return check_num(strlen((char *)p), ref_strlen((char *)p));
  }
  size_t maxes[5] = {0, len / 2, len, len + 1, (size_t)-1};
  for (int j = 0; j < 5; j++, ++*cases) {
    size_t m = maxes[j];
    int z = (int)m + 1, ze = (int)m + 65 < len ? (int)m + 65 : len;
    for (int i = z; m < (size_t)len && i < ze; i++) p[i] = 0;
    CASE("len %lld +%lld maxlen %lld", len, al(p), (long long)m);
    if (!check_num(strnlen((char *)p, m), ref_strnlen((char *)p, m))) return 0;
    for (int i = z; m < (size_t)len && i < ze; i++) p[i] = pat(i + len);
  }
  return 1;
}

static long long test_strlen(int strn) {
  long long cases = 0;
  for (int len = 0; len <= MAXLEN; len++)
    for (int off = 0; off < 32; off++) {
      unsigned char *p = buf1 + 64 + off;
      layout(buf1, buf1 + KB, p, len, 0, -1);
      if (!len_cases(strn, p, len, &cases)) return cases;
    }
  for (int len = 0; len <= MAXLEN; len++) {
    where = "end guard, ";
    layout(START(0), END(0), END(0) - 1 - len, len, 0, -1);
    if (!len_cases(strn, END(0) - 1 - len, len, &cases)) return cases;
    where = "start guard, ";
    layout(START(0), END(0), START(0), len, 0, -1);
    if (!len_cases(strn, START(0), len, &cases)) return cases;
  }
  where = "";
  if (strn) {
    where = "end guard, unterminated, ";
    for (int m = 0; m <= MAXLEN; m++, cases++) {
      unsigned char *p = END(0) - m;
      set(p - 64, 64, 0);
      for (int i = 0; i < m; i++) p[i] = pat(i);
      CASE("strnlen(p, %lld)", m);
      if (!check_num(strnlen((char *)p, m), ref_strnlen((char *)p, m))) return cases;
    }
    where = "";
    CASE("strnlen(NULL, 0)");
    if (!check_num(strnlen(NULL, 0), 0)) return cases;
    cases++;
  }
  return cases;
}

// strchr (last 0) or strrchr on the string at p (len bytes, already laid out) for each c: (char)c in the 64 bytes
// before it and after its terminator.
static int chr_cases(int last, unsigned char *lo, unsigned char *hi, unsigned char *p, int len, const int *cs, int nc,
                     long long *cases) {
  for (int j = 0; j < nc; j++, ++*cases) {
    int c = cs[j];
    layout(lo, hi, p, len, c, c);
    CASE("len %lld +%lld c 0x%llx", len, al(p), c);
    char *got = last ? strrchr((char *)p, c) : strchr((char *)p, c);
    if (!check_ptr(got, last ? ref_strrchr((char *)p, c) : ref_strchr((char *)p, c), p)) return 0;
  }
  return 1;
}

// c = 0, 0x01, 0x7f, 0x80, 0xff, an absent byte, the first, a middle and the last character, the first byte >= 0x80
// present, and 0x100 + a present character ((char)c decides). Returns how many.
static int chars_of(int len, int *cs) {
  unsigned char present[256] = {0};
  int n = 0, absent = 1, high = 0x80;
  for (int i = 0; i < len; i++) present[pat(i + len)] = 1;
  while (present[absent]) absent++;
  for (int i = len - 1; i >= 0; i--)
    if (pat(i + len) >= 0x80) high = pat(i + len);
  cs[n++] = 0, cs[n++] = 0x01, cs[n++] = 0x7f, cs[n++] = 0x80, cs[n++] = 0xff, cs[n++] = absent;
  if (len) {
    cs[n++] = pat(len), cs[n++] = pat(len / 2 + len), cs[n++] = pat(len - 1 + len), cs[n++] = high;
    cs[n++] = 0x100 + pat(len / 2 + len);
  }
  return n;
}

static long long test_chr(int last) {
  long long cases = 0;
  int cs[16], nc;
  for (int len = 0; len <= 64; len++) {
    nc = chars_of(len, cs);
    for (int off = 0; off < 16; off++)
      if (!chr_cases(last, buf1, buf1 + KB, buf1 + 64 + off, len, cs, nc, &cases)) return cases;
  }
  for (int len = 0; len <= MAXLEN; len++) {
    nc = chars_of(len, cs);
    where = "end guard, ";
    if (!chr_cases(last, START(0), END(0), END(0) - 1 - len, len, cs, nc, &cases)) return cases;
    where = "start guard, ";
    if (!chr_cases(last, START(0), END(0), START(0), len, cs, nc, &cases)) return cases;
  }
  where = "";
  return cases;
}

// strcmp of two equal strings at s1 and s2 (laid out: their bytes before and after differ), then with one difference
// at 0, len / 2 and len - 1, each byte pair; results compared exactly.
static int cmp_cases(unsigned char *s1, unsigned char *s2, int len, long long *cases) {
  static const unsigned char pairs[4][2] = {{'a', 'b'}, {0x01, 0xff}, {0xff, 0x01}, {'a', 0}};
  CASE("len %lld s1+%lld s2+%lld", len, al(s1), al(s2));
  ++*cases;
  if (!check_num(strcmp((char *)s1, (char *)s2), ref_strcmp((char *)s1, (char *)s2))) return 0;
  for (int j = 0; len && j < 3; j++) {
    int d = j == 0 ? 0 : j == 1 ? len / 2 : len - 1;
    for (int k = 0; k < 4; k++, ++*cases) {
      s1[d] = pairs[k][0], s2[d] = pairs[k][1];
      CASE("len %lld s1+%lld s2+%lld, 0x%llx/0x%llx at %lld", len, al(s1), al(s2), pairs[k][0], pairs[k][1], d);
      if (!check_num(strcmp((char *)s1, (char *)s2), ref_strcmp((char *)s1, (char *)s2))) return 0;
      s1[d] = s2[d] = pat(d + len);
    }
  }
  return 1;
}

static long long test_strcmp(int unused) {
  long long cases = 0;
  (void)unused;
  for (int len = 0; len <= MAXLEN; len++)
    for (int o1 = 0; o1 < 16; o1++)
      for (int o2 = 0; o2 < 16; o2++) {
        layout(buf1, buf1 + KB, buf1 + 64 + o1, len, 0x5a, 0x33);
        layout(buf2, buf2 + KB, buf2 + 64 + o2, len, 0xa5, 0x44);
        if (!cmp_cases(buf1 + 64 + o1, buf2 + 64 + o2, len, &cases)) return cases;
      }
  // One string in each guarded allocation.
  for (int len = 0; len <= MAXLEN; len++) {
    where = "end guards, ";
    layout(START(0), END(0), END(0) - 1 - len, len, 0x5a, 0x33);
    layout(START(1), END(1), END(1) - 1 - len, len, 0xa5, 0x44);
    if (!cmp_cases(END(0) - 1 - len, END(1) - 1 - len, len, &cases)) return cases;
    where = "start guards, ";
    layout(START(0), END(0), START(0), len, 0x5a, 0x33);
    layout(START(1), END(1), START(1), len, 0xa5, 0x44);
    if (!cmp_cases(START(0), START(1), len, &cases)) return cases;
  }
  where = "";
  return cases;
}

// memchr over n bytes at p for the byte b, passed as 0x100 + b, put at `at` (-1: absent); b fills the 64 bytes before
// p and after p + n, as far as [lo, hi) goes.
static int memchr_case(unsigned char *lo, unsigned char *hi, unsigned char *p, int n, int b, int at) {
  for (unsigned char *q = p - 64 > lo ? p - 64 : lo; q < p; q++) *q = (unsigned char)b;
  for (int i = 0; i < n; i++) p[i] = pat_without(i + n, b);
  if (at >= 0) p[at] = (unsigned char)b;
  for (int i = n; i < n + 64 && p + i < hi; i++) p[i] = (unsigned char)b;
  CASE("n %lld +%lld c 0x%llx at %lld", n, al(p), 0x100 + b, at);
  return check_ptr(memchr(p, 0x100 + b, n), ref_memchr(p, 0x100 + b, n), p);
}

static long long test_memchr(int unused) {
  static const int bytes[5] = {0x00, 0x01, 0x7f, 0x80, 0xff};
  long long cases = 0;
  (void)unused;
  for (int n = 0; n <= MAXLEN; n++)
    for (int off = 0; off < 32; off++)
      for (int j = 0; j < 5; j++)
        for (int k = 0; k < 4; k++) {
          int at = k == 0 ? 0 : k == 1 ? n / 2 : k == 2 ? n - 1 : -1;
          if (!n && at >= 0) continue;
          cases++;
          if (!memchr_case(buf1, buf1 + KB, buf1 + 64 + off, n, bytes[j], at)) return cases;
        }
  for (int n = 0; n <= MAXLEN; n++)
    for (int j = 0; j < 5; j++)
      for (int k = n ? 0 : 1; k < 2; k++, cases += 2) {  // the byte last, or absent
        int at = k ? -1 : n - 1;
        where = "end guard, ";
        if (!memchr_case(START(0), END(0), END(0) - n, n, bytes[j], at)) return cases;
        where = "start guard, ";
        if (!memchr_case(START(0), END(0), START(0), n, bytes[j], at)) return cases;
      }
  // SIZE_MAX bytes, the byte present on the end guard's last readable byte.
  where = "end guard, ";
  for (int k = 0; k <= MAXLEN; k++, cases++) {
    unsigned char *p = END(0) - 1 - k;
    set(p - 64, 64, 0x80);
    for (int i = 0; i < k; i++) p[i] = pat_without(i, 0x80);
    p[k] = 0x80;
    CASE("memchr(p, 0x180, SIZE_MAX), c at %lld, +%lld", k, al(p));
    if (!check_ptr(memchr(p, 0x180, (size_t)-1), ref_memchr(p, 0x180, (size_t)-1), p)) return cases;
  }
  where = "";
  CASE("memchr(NULL, 0x141, 0)");
  if (!check_ptr(memchr(NULL, 0x141, 0), NULL, NULL)) return cases;
  return cases + 1;
}

static int run(const char *r, long long (*fn)(int), int arg) {
  routine = r, where = "", cfmt = "", failed = 0;
  long long n = fn(arg);
  if (!failed) printf("ok %s %lld\n", r, n);
  return failed;
}

int main(void) {
  char self[MAX_PATH];
  const char *base;
  int n = 0, dot = -1, bad = 0;
  setvbuf(stdout, NULL, _IONBF, 0);  // a crash keeps what was printed before it
  GetModuleFileNameA(NULL, self, sizeof self);
  base = self;
  for (const char *q = self; *q; q++)
    if (*q == '\\' || *q == '/') base = q + 1;
  for (; base[n] && n < MAX_PATH - 1; n++) {
    name[n] = base[n];
    if (base[n] == '.') dot = n;
  }
  name[dot >= 0 ? dot : n] = 0;
  for (int i = 0; i < 2; i++) {
    DWORD old;
    guard[i] = VirtualAlloc(NULL, 96 * KB, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!guard[i] || !VirtualProtect(guard[i], 32 * KB, PAGE_NOACCESS, &old)
        || !VirtualProtect(guard[i] + 64 * KB, 32 * KB, PAGE_NOACCESS, &old)) {
      printf("FAIL %s: setup: error %lu\n", name, GetLastError());
      return 1;
    }
  }
  for (int i = 0; i < 2; i++)
    if (!IsBadReadPtr(END(i), 1) || !IsBadReadPtr(START(i) - 1, 1)) {
      printf("FAIL %s: the guard pages are readable (host page size)\n", name);
      return 1;
    }
  SetUnhandledExceptionFilter(on_exception);
  bad += run("memmove", test_copy, 0);
  bad += run("memcpy", test_copy, 1);
  bad += run("strlen", test_strlen, 0);
  bad += run("strnlen", test_strlen, 1);
  bad += run("strchr", test_chr, 0);
  bad += run("strrchr", test_chr, 1);
  bad += run("strcmp", test_strcmp, 0);
  bad += run("memchr", test_memchr, 0);
  if (bad) {
    printf("FAIL %s: %d of 8 routines failed\n", name, bad);
    return 1;
  }
  printf("PASS %s\n", name);
  return 0;
}
