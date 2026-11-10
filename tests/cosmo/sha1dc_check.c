/*
 * The check of git_sha1dc (c_src/cosmo/beam_com_sha1dc.c), the SHA-1 check
 * of the git client:
 *
 *   sha1dc_check tests/programs/sha1dc_vectors.txt
 *
 * The program runs the helper in a child process with pipes, as a port
 * does, and checks its answers and its exit status:
 *
 *   - Several messages in one input: the empty message, "abc", and 55,
 *     56, 63, 64, 65 and 1,000,000 bytes, with the SHA-1 of FIPS 180 and
 *     of other programs, and the flag 0.
 *   - A message of 196,864 bytes, more than 3 parts of the helper.
 *   - The vectors of the file: the flag 1, and a digest that is not the
 *     SHA-1 of the data (the safe hash mode).
 *   - The end of the input: before a message (status 0), in the length or
 *     in the data of a message (status 1), and an argument (status 2).
 *
 * Linux and the other Unix systems only: Windows has no fork(). The last
 * line is "sha1dc_check: ok".
 */
#include "../../c_src/cosmo/beam_com_sha1dc.c"

#include <signal.h>
#include <string.h>
#include <sys/wait.h>
#include <cosmo.h>
#include "libc/dce.h"

static int failures;

static void check(int ok, const char *what)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok)
        failures++;
}

/* A growing buffer. */
struct buf {
    unsigned char *p;
    size_t n, size;
};

static void put(struct buf *b, const void *p, size_t n)
{
    if (b->n + n > b->size) {
        b->size = (b->n + n) * 2;
        if (!(b->p = realloc(b->p, b->size))) {
            perror("realloc");
            exit(1);
        }
    }
    memcpy(b->p + b->n, p, n);
    b->n += n;
}

/* A message: the length (4 bytes, big-endian), then the data. */
static void put_message(struct buf *b, const unsigned char *p, uint32_t n)
{
    unsigned char head[4] = {n >> 24, n >> 16, n >> 8, n};
    put(b, head, 4);
    put(b, p, n);
}

/* Run the helper with the input IN and ARGC arguments. The output goes
 * to OUT. The result is the exit status, or -1. */
static int run(const struct buf *in, int argc, struct buf *out)
{
    int to[2], from[2], status;
    char *argv[] = {"git_sha1dc", "extra", 0};
    pid_t pid;
    unsigned char chunk[4096];
    ssize_t got;

    if (pipe(to) < 0 || pipe(from) < 0)
        return -1;
    if ((pid = fork()) < 0)
        return -1;
    if (pid == 0) {
        dup2(to[0], 0);
        dup2(from[1], 1);
        close(to[0]);
        close(to[1]);
        close(from[0]);
        close(from[1]);
        argv[argc] = 0;
        _exit(beam_com_sha1dc_main(argc, argv));
    }
    close(to[0]);
    close(from[1]);
    /* The answers (25 bytes each) fit in the buffer of the pipe, so the
     * whole input goes first. A helper that stops early closes its end:
     * then the write fails, and the exit status tells the result. */
    signal(SIGPIPE, SIG_IGN);
    sha1dc_write(to[1], in->p, in->n);
    close(to[1]);
    out->n = 0;
    while ((got = read(from[0], chunk, sizeof(chunk))) > 0)
        put(out, chunk, got);
    close(from[0]);
    if (waitpid(pid, &status, 0) < 0 || !WIFEXITED(status))
        return -1;
    return WEXITSTATUS(status);
}

static void hex(const unsigned char *p, size_t n, char *text)
{
    size_t i;
    for (i = 0; i < n; i++)
        sprintf(text + 2 * i, "%02x", p[i]);
}

/* The answer I of OUT: the flag 0 and the digest SHA1 (in hex), or with
 * ATTACK, the flag 1 and another digest. */
static void check_answer(const struct buf *out, size_t i, int attack, const char *sha1,
                         const char *what)
{
    const unsigned char *a = out->p + 25 * i;
    char text[41], line[200];
    int ok;

    if (out->n < 25 * (i + 1)) {
        snprintf(line, sizeof(line), "%s: no answer", what);
        check(0, line);
        return;
    }
    hex(a + 5, 20, text);
    ok = a[0] == 0 && a[1] == 0 && a[2] == 0 && a[3] == 21 && a[4] == (attack ? 1 : 0) &&
         (attack ? strcmp(text, sha1) != 0 : strcmp(text, sha1) == 0);
    snprintf(line, sizeof(line), "%s: flag %d, digest %s", what, a[4], text);
    check(ok, line);
}

static int nibble(char c)
{
    return c >= 'a' ? c - 'a' + 10 : c - '0';
}

/* The vectors: lines "NAME HEX", and the lines with "#". */
struct vector {
    char name[32];
    unsigned char *data;
    size_t n;
};

static int read_vectors(const char *path, struct vector *v, int max)
{
    FILE *f = fopen(path, "r");
    static char line[8192];
    int count = 0;

    if (!f) {
        perror(path);
        exit(1);
    }
    while (count < max && fgets(line, sizeof(line), f)) {
        char *sp = strchr(line, ' ');
        size_t len, i;
        if (line[0] == '#' || line[0] == '\n' || !sp)
            continue;
        *sp = 0;
        snprintf(v[count].name, sizeof(v[count].name), "%.31s", line);
        len = strcspn(sp + 1, "\r\n");
        v[count].n = len / 2;
        v[count].data = malloc(v[count].n);
        for (i = 0; i < v[count].n; i++)
            v[count].data[i] = nibble(sp[1 + 2 * i]) << 4 | nibble(sp[2 + 2 * i]);
        count++;
    }
    fclose(f);
    return count;
}

int main(int argc, char **argv)
{
    static const struct {
        size_t n;
        const char *sha1;
    } plain[] = {
        {55, "c1c8bbdc22796e28c0e15163d20899b65621d65a"},
        {56, "c2db330f6083854c99d4b5bfb6e8f29f201be699"},
        {63, "03f09f5b158a7a8cdad920bddc29b81c18a551f5"},
        {64, "0098ba824b5c16427bd7a1122a5a442a25ec644d"},
        {65, "11655326c708d70319be2610e8a57d9a5b959d3b"},
        {1000000, "34aa973cd4c4daa4f61eeb2bdbad27316534016f"},
    };
    /* The SHA-1 of the data of the vectors, with no detection. */
    static const char *shattered = "f92d74e3874587aaf443d1db961d4e26dde13e9c";
    static const char *shambles = "8ac60ba76f1999a1ab70223f225aefdc78d4ddc0";
    struct buf in = {0}, out = {0};
    struct vector v[8];
    unsigned char *a, *big;
    size_t i, k, nplain = sizeof(plain) / sizeof(plain[0]);
    int count, status;
    char what[64];

    if (IsWindows()) {
        printf("sha1dc_check: ok (not Windows)\n");
        return 0;
    }
    if (argc != 2) {
        fprintf(stderr, "usage: sha1dc_check VECTORS\n");
        return 2;
    }
    count = read_vectors(argv[1], v, 8);
    check(count == 4, "the file has 4 vectors");

    a = malloc(1000000);
    memset(a, 'a', 1000000);
    big = malloc(196864);
    for (i = 0; i < 196864; i++)
        big[i] = i & 255;

    /* All the messages in one input. */
    put_message(&in, (const unsigned char *)"", 0);
    put_message(&in, (const unsigned char *)"abc", 3);
    for (i = 0; i < nplain; i++)
        put_message(&in, a, plain[i].n);
    put_message(&in, big, 196864);
    for (k = 0; k < (size_t)count; k++)
        put_message(&in, v[k].data, v[k].n);
    status = run(&in, 1, &out);
    check(status == 0, "the end of the input after a message: status 0");
    check(out.n == 25 * (3 + nplain + count), "one answer of 25 bytes for each message");
    check_answer(&out, 0, 0, "da39a3ee5e6b4b0d3255bfef95601890afd80709", "the empty message");
    check_answer(&out, 1, 0, "a9993e364706816aba3e25717850c26c9cd0d89d", "abc");
    for (i = 0; i < nplain; i++) {
        snprintf(what, sizeof(what), "%zu bytes", plain[i].n);
        check_answer(&out, 2 + i, 0, plain[i].sha1, what);
    }
    check_answer(&out, 2 + nplain, 0, "56a420c3b5ca82c067190756f314b908f9b15395",
                 "196864 bytes in parts");
    for (k = 0; k < (size_t)count; k++)
        check_answer(&out, 3 + nplain + k, 1,
                     strncmp(v[k].name, "shattered", 9) == 0 ? shattered : shambles, v[k].name);

    /* The vectors one at a time, also after a message with no attack:
     * each message starts a new check. */
    in.n = 0;
    put_message(&in, v[0].data, v[0].n);
    put_message(&in, (const unsigned char *)"abc", 3);
    status = run(&in, 1, &out);
    check(status == 0 && out.n == 50, "a vector, then abc: two answers");
    check_answer(&out, 0, 1, shattered, "the vector before abc");
    check_answer(&out, 1, 0, "a9993e364706816aba3e25717850c26c9cd0d89d", "abc after a vector");

    /* The end of the input. */
    in.n = 0;
    status = run(&in, 1, &out);
    check(status == 0 && out.n == 0, "no input: status 0, no answer");
    put(&in, "\0\0", 2);
    status = run(&in, 1, &out);
    check(status == 1 && out.n == 0, "the end of the input in the length: status 1");
    in.n = 0;
    put_message(&in, (const unsigned char *)"abc", 3);
    put(&in, "\0\0\0\x10" "0123456789", 14);
    status = run(&in, 1, &out);
    check(status == 1 && out.n == 25, "the end of the input in the data: status 1, after one answer");
    in.n = 0;
    status = run(&in, 2, &out);
    check(status == 2, "an argument: status 2");

    if (failures) {
        printf("sha1dc_check: %d failures\n", failures);
        return 1;
    }
    printf("sha1dc_check: ok\n");
    return 0;
}
