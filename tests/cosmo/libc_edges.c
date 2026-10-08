/*
 * Calls functions of the libc of Cosmopolitan with buffers at the edges
 * of a mapping, and prints each function that faults (docs/UPSTREAM.md
 * C33 and C34). scripts/steps.sh (step_test) builds it with cosmocc two
 * times: without the wraps of the emulator, for the log, and with them
 * (-DBEAM_COM_LIBC_WRAPS and the --wrap flags of LIBC_WRAPS), where no
 * function must fault.
 *
 * END: the last byte of each buffer is the last byte of a mapping.
 * START: the first byte of each buffer is the first byte of a mapping,
 * after a page that is not mapped. Each length from 0 to 80.
 *
 * Build it with -fno-builtin: GCC gives the result of some calls with a
 * constant length at compile time, and then the libc does not run.
 */
#define _GNU_SOURCE
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wchar.h>

#ifdef BEAM_COM_LIBC_WRAPS
#include "../../c_src/cosmo/beam_com_libc.h"
#endif

#define MAX_LEN 80

static sigjmp_buf fault;
static long page;
static volatile size_t sink;

static void on_fault(int sig)
{
    (void)sig;
    siglongjmp(fault, 1);
}

/* Three pages: not mapped, readable and writable, not mapped. The result
 * is the start of the middle page. */
static char *guarded_page(void)
{
    char *m = mmap(NULL, 3 * page, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

    if (m == MAP_FAILED || mprotect(m + page, page, PROT_READ | PROT_WRITE) != 0) {
        perror("mmap");
        exit(2);
    }
    return m + page;
}

typedef void (*call_t)(char *a, char *b, size_t n);
static char out[4096];

#define CALL(name, body) static void name(char *a, char *b, size_t n) { (void)b; (void)n; body; }
CALL(c_memchr, sink += (size_t)memchr(a, '\n', n))
CALL(c_memrchr, sink += (size_t)memrchr(a, '\n', n))
CALL(c_memccpy, sink += (size_t)memccpy(out, a, '\n', n))
CALL(c_memcmp, sink += memcmp(a, b, n))
CALL(c_bcmp, sink += bcmp(a, b, n))
CALL(c_memmem, sink += (size_t)memmem(a, n, "a\n", 2))
CALL(c_memcpy, { memcpy(out, a, n); sink += out[0]; })
CALL(c_memmove, { memmove(out, a, n); sink += out[0]; })
CALL(c_strnlen, sink += strnlen(a, n))
CALL(c_strncmp, sink += strncmp(a, b, n))
CALL(c_strncasecmp, sink += strncasecmp(a, b, n))
CALL(c_strncpy, { strncpy(out, a, n); sink += out[0]; })
CALL(c_strndup, { char *p = strndup(a, n); sink += p[0]; free(p); })
CALL(c_wmemchr, sink += (size_t)wmemchr((wchar_t *)a, L'\n', n / sizeof(wchar_t)))
CALL(c_wcsnlen, sink += wcsnlen((wchar_t *)a, n / sizeof(wchar_t)))
/* No length: each string has its NUL at the last byte (END only). */
CALL(c_strlen, sink += strlen(a))
CALL(c_strchr, sink += (size_t)strchr(a, '\n'))
CALL(c_strrchr, sink += (size_t)strrchr(a, '\n'))
CALL(c_strstr, sink += (size_t)strstr(a, "a\n"))
CALL(c_strcmp, sink += strcmp(a, b))

static const struct {
    const char *name;
    call_t call;
    int string; /* 1: the buffer is a string with its NUL at the end */
} calls[] = {
    {"memchr", c_memchr, 0},   {"memrchr", c_memrchr, 0},
    {"memccpy", c_memccpy, 0}, {"memcmp", c_memcmp, 0},
    {"bcmp", c_bcmp, 0},       {"memmem", c_memmem, 0},
    {"memcpy", c_memcpy, 0},   {"memmove", c_memmove, 0},
    {"strnlen", c_strnlen, 0}, {"strncmp", c_strncmp, 0},
    {"strncasecmp", c_strncasecmp, 0}, {"strncpy", c_strncpy, 0},
    {"strndup", c_strndup, 0}, {"wmemchr", c_wmemchr, 0},
    {"wcsnlen", c_wcsnlen, 0}, {"strlen", c_strlen, 1},
    {"strchr", c_strchr, 1},   {"strrchr", c_strrchr, 1},
    {"strstr", c_strstr, 1},   {"strcmp", c_strcmp, 1},
};

/* 1 when the call faults, else 0. */
static int faults_in(call_t call, char *a, char *b, size_t n)
{
    if (sigsetjmp(fault, 1) == 0) {
        call(a, b, n);
        return 0;
    }
    signal(SIGSEGV, on_fault);
    signal(SIGBUS, on_fault);
    return 1;
}

/* The results of the wrapped functions, in normal buffers. */
static int check_results(void)
{
    static const char abc[] = "abc";
    char d[8];
    int ok = 1;

    ok &= memchr(abc, 'c', 3) == abc + 2;
    ok &= memchr(abc, 'z', 3) == NULL;
    ok &= memchr(abc, 'a', 0) == NULL;
    memset(d, 'x', sizeof d);
    ok &= strncpy(d, "abc", 6) == d && memcmp(d, "abc\0\0\0xx", 8) == 0;
    memset(d, 'x', sizeof d);
    ok &= strncpy(d, "abcdef", 3) == d && memcmp(d, "abcxxxxx", 8) == 0;
    memset(d, 'x', sizeof d);
    ok &= strncpy(d, "abc", 0) == d && memcmp(d, "xxxxxxxx", 8) == 0;
    printf("results: %s\n", ok ? "ok" : "wrong");
    return ok;
}

int main(void)
{
    char *pa, *pb;
    int bad = 0;

    if (!check_results())
        return 1;

    page = sysconf(_SC_PAGESIZE);
    pa = guarded_page();
    pb = guarded_page();
    signal(SIGSEGV, on_fault);
    signal(SIGBUS, on_fault);
    for (size_t i = 0; i < sizeof calls / sizeof calls[0]; i++) {
        int faults = 0;
        char first[64] = "";

        for (int start = 0; start <= 1; start++) {
            if (calls[i].string && start)
                continue;
            for (size_t n = 0; n <= MAX_LEN; n++) {
                char *a = start ? pa : pa + page - n;
                char *b = start ? pb : pb + page - n;

                if (calls[i].string && n == 0)
                    continue;
                memset(pa, 'a', page);
                memset(pb, 'a', page);
                if (calls[i].string)
                    a[n - 1] = b[n - 1] = '\0';
                if (faults_in(calls[i].call, a, b, n) && faults++ == 0)
                    snprintf(first, sizeof first, " (first: %s, n = %zu)",
                             start ? "START" : "END", n);
            }
        }
        if (faults)
            printf("%-12s fault in %d calls%s\n", calls[i].name, faults, first);
        else
            printf("%-12s ok\n", calls[i].name);
        bad += faults != 0;
    }
    printf("functions with a fault: %d\n", bad);
    return 0;
}
