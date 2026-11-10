/*
 * git_sha1dc, linked into BEAM.com: the SHA-1 check of the git client
 * (beam_com_git). It finds the objects of a pack that have the mark of a
 * SHA-1 collision attack, as git does.
 *
 *   git_sha1dc
 *
 * Each message of the standard input is the bytes that git hashes for one
 * object: "TYPE SIZE", a NUL byte, then the data. A message has a length
 * of 4 bytes (big-endian) before it, as a port with {packet, 4}. For each
 * message, the program writes one answer of 21 bytes, also with a length
 * of 4 bytes before it:
 *
 *   - 1 byte: 1 when the data has the mark of a collision attack, else 0.
 *   - 20 bytes: the digest of SHA1DCFinal(). With no attack, this is the
 *     SHA-1 of the data. With an attack, the safe hash mode gives another
 *     digest, so the name of the object is not correct.
 *
 * The program reads a message in parts of SHA1DC_PART bytes, so it does
 * not keep an object in memory. It exits with 0 at the end of its input,
 * and with 1 on a read error, a write error, or an end of the input in a
 * message.
 *
 * The check is the library sha1collisiondetection of Marc Stevens and Dan
 * Shumow (c_src/cosmo/sha1dc/, MIT License), the check of git. The program uses
 * its defaults: the safe hash mode and the check of unavoidable bit
 * conditions (UBC) are on.
 *
 * With BEAM_COM_SHA1DC_MAIN, this file is a program of its own (main()),
 * for the tests.
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

/* cosmocc makes code for x86_64 and aarch64, which are little-endian.
 * With SHA1DC_FORCE_LITTLEENDIAN, sha1.c does not compare the macros of
 * the byte order: one of them is not defined, and a compile with
 * -Werror=undef (as ERTS can have) refuses that comparison. */
#if !defined(__BYTE_ORDER__) || __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "git_sha1dc: the CPU must be little-endian"
#endif
#define SHA1DC_FORCE_LITTLEENDIAN

/* The library, with no change. One object for its two files, so the
 * build of the emulator needs no other path. */
#include "sha1dc/sha1.c"
#include "sha1dc/ubc_check.c"

/* A multiple of 64 bytes: each part except the last is a full number of
 * SHA-1 blocks, so SHA1DCUpdate() reads aligned blocks of the buffer. */
#define SHA1DC_PART (64 * 1024)

/* All N bytes of the file descriptor FD: 1, 0 at the end of the input
 * before the first byte (when FIRST), or -1. */
static int sha1dc_read(int fd, unsigned char *p, size_t n, int first)
{
    size_t done = 0;
    while (done < n) {
        ssize_t got = read(fd, p + done, n - done);
        if (got < 0 && errno == EINTR)
            continue;
        if (got == 0 && done == 0 && first)
            return 0;
        if (got <= 0)
            return -1;
        done += got;
    }
    return 1;
}

static int sha1dc_write(int fd, const unsigned char *p, size_t n)
{
    while (n > 0) {
        ssize_t put = write(fd, p, n);
        if (put < 0 && errno == EINTR)
            continue;
        if (put <= 0)
            return -1;
        p += put;
        n -= put;
    }
    return 0;
}

/* One message and its answer: 1, 0 at the end of the input, or -1. Buf
 * has SHA1DC_PART bytes. */
static int sha1dc_message(unsigned char *buf, int in, int out)
{
    unsigned char head[4], answer[4 + 21];
    uint32_t len;
    SHA1_CTX ctx;
    int rc;

    rc = sha1dc_read(in, head, 4, 1);
    if (rc <= 0)
        return rc;
    len = (uint32_t)head[0] << 24 | (uint32_t)head[1] << 16 | (uint32_t)head[2] << 8 | head[3];
    SHA1DCInit(&ctx);
    while (len > 0) {
        size_t n = len < SHA1DC_PART ? len : SHA1DC_PART;
        if (sha1dc_read(in, buf, n, 0) < 0)
            return -1;
        SHA1DCUpdate(&ctx, (const char *)buf, n);
        len -= n;
    }
    answer[0] = 0;
    answer[1] = 0;
    answer[2] = 0;
    answer[3] = 21;
    answer[4] = SHA1DCFinal(answer + 5, &ctx) ? 1 : 0;
    return sha1dc_write(out, answer, sizeof(answer)) < 0 ? -1 : 1;
}

int beam_com_sha1dc_main(int argc, char **argv);

int beam_com_sha1dc_main(int argc, char **argv)
{
    unsigned char *buf;
    int rc;

    (void)argv;
    if (argc != 1) {
        fprintf(stderr, "usage: git_sha1dc (the SHA-1 check of the git client)\n");
        return 2;
    }
    if (!(buf = malloc(SHA1DC_PART)))
        return 1;
    while ((rc = sha1dc_message(buf, 0, 1)) > 0)
        ;
    free(buf);
    if (rc < 0) {
        fprintf(stderr, "git_sha1dc: a read or a write failed\n");
        return 1;
    }
    return 0;
}

#ifdef BEAM_COM_SHA1DC_MAIN
int main(int argc, char **argv)
{
    return beam_com_sha1dc_main(argc, argv);
}
#endif
