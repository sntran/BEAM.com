/*
 * Wraps of functions of the libc of Cosmopolitan that read past the end
 * of their buffer (docs/UPSTREAM.md C33 and C34). The emulator is linked
 * with the --wrap flags of LIBC_WRAPS in scripts/steps.sh, and beam_com.c
 * includes this file once. tests/cosmo/libc_edges.c includes it too, and
 * calls the functions with buffers at the edges of a mapping.
 */
#ifndef BEAM_COM_LIBC_H
#define BEAM_COM_LIBC_H

#include <stddef.h>
#include <string.h>

/* memchr() of 0 bytes (C33). On x86_64, the memchr() of Cosmopolitan
 * reads the aligned 16 bytes at s also when n is 0, so memchr(end, c, 0)
 * faults when end is the first byte after a mapping. ERTS makes this call
 * for an empty binary in decode_packet/3. The C standard permits the
 * call, and the result is NULL. memccpy() calls memchr(), so this wrap
 * also covers it. */
void *__real_memchr(const void *s, int c, size_t n);

void *__wrap_memchr(const void *s, int c, size_t n)
{
    return n == 0 ? NULL : __real_memchr(s, c, n);
}

/* strncpy() (C34). The strncpy() of Cosmopolitan calls strlen(src), so
 * it reads the source up to its NUL, also past n bytes. The C standard
 * lets the source be an array with no NUL in its first n bytes, and a
 * read past them faults at the end of a mapping. This one reads at most
 * n bytes of the source. */
char *__wrap_strncpy(char *dst, const char *src, size_t n)
{
    size_t len = strnlen(src, n);

    memcpy(dst, src, len);
    memset(dst + len, 0, n - len);
    return dst;
}

#endif
