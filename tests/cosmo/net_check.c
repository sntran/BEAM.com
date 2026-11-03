/*
 * The checks of c_src/cosmo/beam_com_net.c that need no network: the
 * entries of the list, the names of DNS, the CNAME chain of an answer,
 * the check of an address, and random messages. step_test of
 * scripts/steps.sh compiles it with cosmocc and runs it. The last line is
 * "net_check: ok".
 */
#define BEAM_COM_NET_TEST
#define __real_connect connect
#define __real_bind bind
#define __real_sendto sendto
#define __real_sendmsg sendmsg
#define __real_socket socket
#include "../../c_src/cosmo/beam_com_net.c"

static int failures;

#define CHECK(cond)                                                          \
    do {                                                                     \
        if (!(cond)) {                                                       \
            fprintf(stderr, "net_check: line %d: %s\n", __LINE__, #cond);    \
            failures++;                                                      \
        }                                                                    \
    } while (0)

static void reset(void)
{
    net_nrules = 0;
    net_naddrs = 0;
    net_port = 0;
    net_on = 1;
}

static int rule(const char *text)
{
    char error[256];
    return beam_com_net_rule(text, error, sizeof(error));
}

static void check_rules(void)
{
    static const char *good[] = {"example.com", "Example.COM.", "*.example.com",
                                 "*.example.com:443", "a-b_c.example:1", "10.0.0.1",
                                 "10.0.0.1:5432", "[::1]", "[::1]:8080", "::1",
                                 "[::ffff:10.0.0.2]:80", "localhost", "db"};
    static const char *bad[] = {"", "*", "*.com", "*.a..b", "a..b", "a b", "1.2.3",
                                "a.example:0", "a.example:65536", "a.example:",
                                "a.example:12a", "a.example:000080", "[::1",
                                "[::g]:80", "[::1]x", "1::2::3", "a/b.example"};
    char longname[300];
    size_t i;

    reset();
    for (i = 0; i < sizeof(good) / sizeof(*good); i++)
        CHECK(rule(good[i]) == 0);
    CHECK(strcmp(net_rules[1].name, "example.com") == 0);
    CHECK(net_rules[2].wildcard && strcmp(net_rules[2].name, "example.com") == 0);
    CHECK(net_rules[3].port == 443);
    CHECK(net_rules[5].family == AF_INET && net_rules[5].port == 0);
    CHECK(net_rules[8].family == AF_INET6 && net_rules[8].port == 8080);
    /* An IPv4-mapped address is the IPv4 address. */
    CHECK(net_rules[10].family == AF_INET && net_rules[10].addr[3] == 2);
    reset();
    for (i = 0; i < sizeof(bad) / sizeof(*bad); i++)
        CHECK(rule(bad[i]) == -1);
    CHECK(net_nrules == 0);
    /* A label of 64 bytes, a name of 254 bytes. */
    memset(longname, 'a', 64);
    strcpy(longname + 64, ".example");
    CHECK(rule(longname) == -1);
    for (i = 0; i < 254; i++)
        longname[i] = i % 2 ? '.' : 'a';
    longname[253] = '\0';
    CHECK(rule(longname) == 0);
    longname[253] = 'a';
    longname[254] = '\0';
    CHECK(rule(longname) == -1);
    reset();
    for (i = 0; i < BEAM_COM_NET_RULES; i++)
        CHECK(rule("a.example") == 0);
    CHECK(rule("a.example") == -1);
}

static void check_names(void)
{
    reset();
    rule("api.example.com");
    rule("*.example.org:443");
    CHECK(net_name_rules("api.example.com") == 1);
    CHECK(net_name_rules("example.com") == 0);
    CHECK(net_name_rules("x.api.example.com") == 0);
    CHECK(net_name_rules("a.example.org") == 2);
    CHECK(net_name_rules("a.b.example.org") == 2);
    CHECK(net_name_rules("example.org") == 0);
    CHECK(net_name_rules("xexample.org") == 0);
    CHECK(net_name_rules(".example.org") == 0);
}

/* A message: the bytes, and the length. */
static size_t put_name(unsigned char *m, const char *name)
{
    size_t n = 0, len;
    const char *dot;

    while (*name) {
        dot = strchr(name, '.');
        len = dot ? (size_t)(dot - name) : strlen(name);
        m[n++] = len;
        memcpy(m + n, name, len);
        n += len;
        name += len + (dot ? 1 : 0);
    }
    m[n++] = 0;
    return n;
}

static size_t put_rr(unsigned char *m, const char *name, unsigned type, const void *data,
                     unsigned len)
{
    size_t n = put_name(m, name);
    put16(m + n, type);
    put16(m + n + 2, 1);
    memset(m + n + 4, 0, 4);
    m[n + 7] = 30;
    put16(m + n + 8, len);
    memcpy(m + n + 10, data, len);
    return n + 10 + len;
}

static size_t query(unsigned char *m, const char *name, unsigned type)
{
    size_t n = 12;
    memset(m, 0, 12);
    put16(m, 0x1234);
    m[2] = 0x01;
    put16(m + 4, 1);
    n += put_name(m + n, name);
    put16(m + n, type);
    put16(m + n + 2, 1);
    return n + 4;
}

static void check_dns_name(void)
{
    unsigned char m[600];
    char out[256];
    size_t off, n;

    n = put_name(m + 12, "A.Example.COM") + 12;
    off = 12;
    CHECK(dns_name(m, n, &off, out) == 0 && strcmp(out, "a.example.com") == 0 && off == n);
    /* A pointer to the name. */
    m[n] = 0xc0;
    m[n + 1] = 12;
    off = n;
    CHECK(dns_name(m, n + 2, &off, out) == 0 && strcmp(out, "a.example.com") == 0 &&
          off == n + 2);
    /* A pointer to itself. */
    m[0] = 0xc0;
    m[1] = 0;
    off = 0;
    CHECK(dns_name(m, 2, &off, out) == -1);
    /* A label past the end, a label type 01, and a byte that is not of a
     * name ("." in a label). */
    m[0] = 5;
    memcpy(m + 1, "ab", 2);
    off = 0;
    CHECK(dns_name(m, 3, &off, out) == -1);
    m[0] = 0x40;
    off = 0;
    CHECK(dns_name(m, 3, &off, out) == -1);
    n = put_name(m, "a");
    m[0] = 3;
    memcpy(m + 1, "a.b", 3);
    m[4] = 0;
    off = 0;
    CHECK(dns_name(m, 5, &off, out) == -1);
}

static void check_chain(void)
{
    static const unsigned char a1[4] = {192, 0, 2, 1}, a2[4] = {192, 0, 2, 2},
                               a3[4] = {192, 0, 2, 3};
    static const unsigned char a6[16] = {0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
                                         0, 0, 0, 0, 0, 0, 0, 1};
    unsigned char m[1024], cname[64];
    size_t n, cn;

    reset();
    rule("*.example.com:443");
    rule("192.0.2.9");
    /* api.example.com CNAME edge.cdn.example, edge.cdn.example CNAME
     * x.cdn.example A 192.0.2.1 and AAAA 2001:db8::1, and an A record of
     * another name. */
    n = query(m, "api.example.com", 1);
    m[2] |= 0x80;
    put16(m + 6, 5);
    cn = put_name(cname, "edge.cdn.example");
    n += put_rr(m + n, "x.cdn.example", 1, a1, 4);
    n += put_rr(m + n, "evil.example", 1, a2, 4);
    n += put_rr(m + n, "api.example.com", 5, cname, cn);
    cn = put_name(cname, "x.cdn.example");
    n += put_rr(m + n, "edge.cdn.example", 5, cname, cn);
    n += put_rr(m + n, "x.cdn.example", 28, a6, 16);
    dns_record(m, n, "api.example.com", net_name_rules("api.example.com"));
    CHECK(net_allowed(AF_INET, a1, 443, 0));
    CHECK(!net_allowed(AF_INET, a1, 80, 0));
    CHECK(net_allowed(AF_INET6, a6, 443, 0));
    CHECK(!net_allowed(AF_INET, a2, 443, 0));
    CHECK(!net_allowed(AF_INET, a3, 443, 0));
    /* An address of the list, with each port. */
    CHECK(net_allowed(AF_INET, (const unsigned char *)"\xc0\x00\x02\x09", 1, 0));
    /* bind() to port 0, but not to another port. */
    CHECK(net_allowed(AF_INET, a3, 0, 1));
    CHECK(!net_allowed(AF_INET, a3, 8080, 1));
    /* An answer with an error records nothing. */
    reset();
    rule("*.example.com");
    m[3] = 3;
    dns_record(m, n, "api.example.com", 1);
    CHECK(net_naddrs == 0);
}

static void check_sockaddr(void)
{
    struct sockaddr_in in;
    struct sockaddr_in6 in6;
    struct sockaddr sa;

    reset();
    rule("10.0.0.1:5432");
    memset(&in, 0, sizeof(in));
    in.sin_family = AF_INET;
    in.sin_port = htons(5432);
    in.sin_addr.s_addr = htonl(0x0a000001);
    CHECK(net_check((struct sockaddr *)&in, sizeof(in), 0));
    in.sin_port = htons(5433);
    CHECK(!net_check((struct sockaddr *)&in, sizeof(in), 0));
    CHECK(!net_check((struct sockaddr *)&in, 4, 0));
    /* The same address as IPv4-mapped IPv6. */
    memset(&in6, 0, sizeof(in6));
    in6.sin6_family = AF_INET6;
    in6.sin6_port = htons(5432);
    in6.sin6_addr.s6_addr[10] = 0xff;
    in6.sin6_addr.s6_addr[11] = 0xff;
    in6.sin6_addr.s6_addr[12] = 10;
    in6.sin6_addr.s6_addr[15] = 1;
    CHECK(net_check((struct sockaddr *)&in6, sizeof(in6), 0));
    CHECK(!net_check((struct sockaddr *)&in6, sizeof(in6) - 1, 0));
    /* The resolver. */
    net_port = 5353;
    in.sin_port = htons(5353);
    in.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    CHECK(net_check((struct sockaddr *)&in, sizeof(in), 0));
    CHECK(!net_check((struct sockaddr *)&in, sizeof(in), 1));
    /* A Unix socket is not this check. */
    memset(&sa, 0, sizeof(sa));
    sa.sa_family = AF_UNIX;
    CHECK(net_check(&sa, sizeof(sa), 0));
    /* Without a list, each address. */
    net_on = 0;
    in.sin_port = htons(1);
    CHECK(net_check((struct sockaddr *)&in, sizeof(in), 0));
}

static void check_answer(void)
{
    static unsigned char q[600], out[NET_MSG];
    size_t n, len;

    reset();
    rule("*.example.com");
    rule("localhost");
    /* A name that the list does not allow: nxdomain, with the id and the
     * question of the query. */
    n = query(q, "other.example", 1);
    len = net_answer(q, n, 0, out);
    CHECK(len == n && get16(out) == 0x1234 && (out[2] & 0x80) && (out[3] & 0x0f) == 3);
    CHECK(get16(out + 4) == 1 && memcmp(out + 12, q + 12, n - 12) == 0);
    /* No name server: servfail. */
    n = query(q, "a.example.com", 1);
    len = net_answer(q, n, 0, out);
    CHECK(len == n && (out[3] & 0x0f) == 2);
    /* localhost: 127.0.0.1. */
    n = query(q, "localhost", 1);
    len = net_answer(q, n, 0, out);
    CHECK(len == n + 16 && get16(out + 6) == 1 && out[len - 4] == 127 && out[len - 1] == 1);
    /* A response, a query of two questions, a bad name: no answer, or
     * an error. */
    q[2] |= 0x80;
    CHECK(net_answer(q, n, 0, out) == 0);
    q[2] &= 0x7f;
    put16(q + 4, 2);
    CHECK(net_answer(q, n, 0, out) == 12 && (out[3] & 0x0f) == 4);
    put16(q + 4, 1);
    q[12] = 0x3f;
    CHECK(net_answer(q, n, 0, out) == 12 && (out[3] & 0x0f) == 1);
    CHECK(net_answer(q, 5, 0, out) == 0);
}

/* Random messages, and random changes of a good answer: no crash, and
 * no read out of the buffer (the buffer has the exact length). */
static void check_random(void)
{
    static unsigned char good[512], out[NET_MSG];
    unsigned char *m;
    unsigned seed = 1;
    size_t n, gn, k, j;
    char name[256];

    reset();
    rule("*.example.com");
    gn = query(good, "api.example.com", 1);
    good[2] |= 0x80;
    put16(good + 6, 2);
    gn += put_rr(good + gn, "api.example.com", 1, "\xc0\x00\x02\x01", 4);
    good[gn++] = 0xc0;
    good[gn++] = 12;
    put16(good + gn, 1);
    put16(good + gn + 2, 1);
    memset(good + gn + 4, 0, 4);
    put16(good + gn + 8, 4);
    memcpy(good + gn + 10, "\xc0\x00\x02\x02", 4);
    gn += 14;
    for (k = 0; k < 200000; k++) {
        seed = seed * 1103515245 + 12345;
        n = k % 2 ? gn : (seed >> 16) % 300;
        m = malloc(n ? n : 1);
        for (j = 0; j < n; j++) {
            seed = seed * 1103515245 + 12345;
            m[j] = k % 2 ? good[j] : (unsigned char)(seed >> 16);
        }
        if (k % 2) {
            seed = seed * 1103515245 + 12345;
            m[(seed >> 16) % n] = (unsigned char)(seed >> 8);
        }
        dns_record(m, n, "api.example.com", 1);
        j = 12;
        dns_name(m, n, &j, name);
        if (n >= 12)
            m[2] &= 0x7f;
        if (net_answer(m, n, 0, out) > NET_MSG)
            failures++;
        free(m);
    }
}

int main(void)
{
    check_rules();
    check_names();
    check_dns_name();
    check_chain();
    check_sockaddr();
    check_answer();
    check_random();
    if (failures) {
        printf("net_check: %d failures\n", failures);
        return 1;
    }
    printf("net_check: ok\n");
    return 0;
}
