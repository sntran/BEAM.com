/*
 * --- Sandbox: --allow-net with a list of hosts ---------------------------
 *
 * The permission "net=HOST,..." (beam.com build --allow-net=HOST,...)
 * allows the network only for these hosts. The kernel cannot filter by
 * host: seccomp cannot read the address of connect(), and Landlock knows
 * TCP ports only. So the check is here, in the process:
 *
 * 1. A resolver of DNS on 127.0.0.1 (UDP and TCP, one port), in threads
 *    of this process. BEAM_COM_DNS gives its address to kernel
 *    (patches/otp/0004-sandbox-resolver.patch), which then uses only this
 *    name server. The resolver sends a query to the name servers of the
 *    system only for a name of the list, and gives "nxdomain" for each
 *    other name. For each address in an answer, it records the entries
 *    of the list that allow its name, with the CNAME chain of the
 *    answer. The names of the hosts file count too.
 *
 * 2. The wraps of connect(), sendto(), sendmsg() and bind() (the link has
 *    -Wl,--wrap for each one) allow an address only when it is the
 *    resolver, an address of the list, or an address that the resolver
 *    recorded for an allowed name, each with an allowed port. Else the
 *    call gives EACCES. bind() to port 0 is always allowed.
 *
 * Thus kernel and the check get the same answer of DNS, and a name that
 * the list does not allow never goes to a name server.
 *
 * 3. On Linux 6.7 and later, when each entry has a port, Landlock allows
 *    TCP connect() and bind() only for the ports of the list (and of the
 *    resolver). This limit is in the kernel, also for native code.
 *
 * Caution: a program of --allow-run is not limited by the host list, only
 * by the ports of Landlock. Native code that makes the system call
 * itself does not go through the wraps.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE /* prctl() */
#endif
#include <arpa/inet.h>
#include <errno.h>
#include <stddef.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#ifndef BEAM_COM_NET_TEST
#include <cosmo.h>
#include "libc/calls/landlock.h"            /* landlock_create_ruleset() */
#include "libc/calls/struct/filter.internal.h" /* struct sock_filter */
#include "libc/calls/struct/bpf.internal.h"
#include "libc/calls/sysdir.internal.h"     /* GetHostsTxtPath() */
#include "libc/dce.h"                       /* IsLinux() */
#include "third_party/musl/lookup.internal.h" /* __get_resolv_conf() */
#endif
#include "beam_com_net.h"

int __real_connect(int, const struct sockaddr *, socklen_t);
int __real_bind(int, const struct sockaddr *, socklen_t);
ssize_t __real_sendto(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
ssize_t __real_sendmsg(int, const struct msghdr *, int);
int __wrap_connect(int, const struct sockaddr *, socklen_t);
int __wrap_bind(int, const struct sockaddr *, socklen_t);
ssize_t __wrap_sendto(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
ssize_t __wrap_sendmsg(int, const struct msghdr *, int);

/* The most addresses that the resolver keeps, the most threads that
 * answer at one time, and the time of each try of a name server. */
#define NET_ADDRS 1024
#define NET_WORKERS 32
#define NET_TRY_MS 2000
/* An address stays this long after the TTL of its answer, because
 * kernel and the programs keep an address for some time. */
#define NET_KEEP 3600
#define NET_MSG 65535

struct net_rule {
    char name[256];         /* lower case; "" for an address */
    int wildcard;           /* "*.name": each name under name */
    int family;             /* AF_INET or AF_INET6 for an address */
    unsigned char addr[16];
    int port;               /* 0: each port */
};

struct net_addr {
    int family;
    unsigned char addr[16];
    uint64_t rules;         /* bit i: net_rules[i] allows a name of it */
    int64_t expire;         /* seconds of CLOCK_MONOTONIC */
};

struct net_ns {
    int family;
    unsigned char addr[16];
    int port;
};

static struct net_rule net_rules[BEAM_COM_NET_RULES];
static int net_nrules;
static int net_on;
static int net_verbose;
static struct net_addr net_addrs[NET_ADDRS];
static int net_naddrs;
static pthread_mutex_t net_lock = PTHREAD_MUTEX_INITIALIZER;
static struct net_ns net_ns[3];
static int net_nns;
static int net_udp = -1, net_tcp = -1, net_port;
static atomic_int net_workers;

static int64_t net_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec;
}

static unsigned get16(const unsigned char *p)
{
    return (unsigned)p[0] << 8 | p[1];
}

static uint32_t get32(const unsigned char *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static void put16(unsigned char *p, unsigned v)
{
    p[0] = v >> 8;
    p[1] = v;
}

/* --- The list -------------------------------------------------------- */

/* A name of DNS: labels of a-z, 0-9, "-" and "_", of 1 to 63 bytes, with
 * 253 bytes or fewer in all. The name is in lower case. */
static int net_name_ok(const char *name)
{
    size_t n = strlen(name), label = 0, i;

    if (n == 0 || n > 253)
        return 0;
    for (i = 0; i <= n; i++) {
        char c = name[i];
        if (c == '.' || c == '\0') {
            if (label == 0 || label > 63)
                return 0;
            label = 0;
        } else if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_') {
            label++;
        } else {
            return 0;
        }
    }
    return 1;
}

static int net_set_error(char *error, size_t size, const char *text, const char *entry)
{
    snprintf(error, size, "%s: %s", text, entry);
    return -1;
}

int beam_com_net_rule(const char *text, char *error, size_t size)
{
    struct net_rule r;
    char host[300], *colon, *end;
    const char *p = text, *port = NULL;
    size_t n;
    long v;
    struct in6_addr a6;

    memset(&r, 0, sizeof(r));
    while (*p == ' ' || *p == '\t')
        p++;
    n = strlen(p);
    while (n && (p[n - 1] == ' ' || p[n - 1] == '\t' || p[n - 1] == '\r'))
        n--;
    if (n == 0 || n >= sizeof(host))
        return net_set_error(error, size, "a bad host", text);
    memcpy(host, p, n);
    host[n] = '\0';
    if (host[0] == '[') {
        /* [IPv6] or [IPv6]:PORT */
        end = strchr(host, ']');
        if (!end || (end[1] && end[1] != ':'))
            return net_set_error(error, size, "a bad IPv6 address", text);
        *end = '\0';
        if (end[1] == ':')
            port = end + 2;
        if (inet_pton(AF_INET6, host + 1, &a6) != 1)
            return net_set_error(error, size, "a bad IPv6 address", text);
        r.family = AF_INET6;
        memcpy(r.addr, &a6, 16);
    } else {
        colon = strchr(host, ':');
        if (colon && strchr(colon + 1, ':')) {
            /* IPv6 with no port */
            if (inet_pton(AF_INET6, host, &a6) != 1)
                return net_set_error(error, size, "a bad IPv6 address", text);
            r.family = AF_INET6;
            memcpy(r.addr, &a6, 16);
        } else {
            if (colon) {
                *colon = '\0';
                port = colon + 1;
            }
            for (end = host; *end; end++)
                if (*end >= 'A' && *end <= 'Z')
                    *end += 'a' - 'A';
            n = strlen(host);
            if (n > 1 && host[n - 1] == '.')
                host[n - 1] = '\0';
            if (inet_pton(AF_INET, host, r.addr) == 1) {
                r.family = AF_INET;
            } else if (host[0] == '*' && host[1] == '.') {
                if (!net_name_ok(host + 2) || !strchr(host + 2, '.'))
                    return net_set_error(error, size,
                                         "a bad domain (*.DOMAIN needs two labels or more)", text);
                r.wildcard = 1;
                strcpy(r.name, host + 2);
            } else if (net_name_ok(host)) {
                /* A name of digits and dots is a bad address. */
                if (strspn(host, "0123456789.") == strlen(host))
                    return net_set_error(error, size, "a bad IPv4 address", text);
                strcpy(r.name, host);
            } else {
                return net_set_error(error, size, "a bad host", text);
            }
        }
    }
    if (r.family == AF_INET6 && IN6_IS_ADDR_V4MAPPED(&a6)) {
        r.family = AF_INET;
        memcpy(r.addr, a6.s6_addr + 12, 4);
    }
    if (port) {
        if (!*port || strspn(port, "0123456789") != strlen(port) || strlen(port) > 5)
            return net_set_error(error, size, "a bad port", text);
        v = strtol(port, NULL, 10);
        if (v < 1 || v > 65535)
            return net_set_error(error, size, "a bad port", text);
        r.port = (int)v;
    }
    if (net_nrules >= BEAM_COM_NET_RULES)
        return net_set_error(error, size, "too many hosts (64 or fewer)", text);
    net_rules[net_nrules++] = r;
    return 0;
}

/* The entries of the list that allow the name. */
static uint64_t net_name_rules(const char *name)
{
    uint64_t mask = 0;
    size_t n = strlen(name), m;
    int i;

    for (i = 0; i < net_nrules; i++) {
        const struct net_rule *r = &net_rules[i];
        if (!r->name[0])
            continue;
        if (!r->wildcard) {
            if (strcmp(name, r->name) == 0)
                mask |= (uint64_t)1 << i;
        } else {
            m = strlen(r->name);
            if (n > m + 1 && name[n - m - 1] == '.' && strcmp(name + n - m, r->name) == 0)
                mask |= (uint64_t)1 << i;
        }
    }
    return mask;
}

/* --- The addresses ---------------------------------------------------- */

static void net_record(int family, const unsigned char *addr, uint64_t rules, int64_t expire)
{
    int i, len = family == AF_INET ? 4 : 16, slot = -1;

    if (!rules)
        return;
    pthread_mutex_lock(&net_lock);
    for (i = 0; i < net_naddrs; i++)
        if (net_addrs[i].family == family && memcmp(net_addrs[i].addr, addr, len) == 0) {
            net_addrs[i].rules |= rules;
            if (expire > net_addrs[i].expire)
                net_addrs[i].expire = expire;
            pthread_mutex_unlock(&net_lock);
            return;
        }
    if (net_naddrs < NET_ADDRS) {
        slot = net_naddrs++;
    } else {
        /* The address that ends first. */
        slot = 0;
        for (i = 1; i < NET_ADDRS; i++)
            if (net_addrs[i].expire < net_addrs[slot].expire)
                slot = i;
    }
    memset(&net_addrs[slot], 0, sizeof(net_addrs[slot]));
    net_addrs[slot].family = family;
    memcpy(net_addrs[slot].addr, addr, len);
    net_addrs[slot].rules = rules;
    net_addrs[slot].expire = expire;
    pthread_mutex_unlock(&net_lock);
}

static int net_port_ok(const struct net_rule *r, int port)
{
    return r->port == 0 || r->port == port;
}

/* Is the address allowed? bind: for bind(), where port 0 is always
 * allowed. */
static int net_allowed(int family, const unsigned char *addr, int port, int bind)
{
    static const unsigned char loopback[4] = {127, 0, 0, 1};
    int i, len = family == AF_INET ? 4 : 16, ok = 0;
    uint64_t rules = 0;
    int64_t now;

    if (bind && port == 0)
        return 1;
    if (!bind && family == AF_INET && port == net_port && memcmp(addr, loopback, 4) == 0)
        return 1;
    for (i = 0; i < net_nrules; i++)
        if (net_rules[i].family == family && memcmp(net_rules[i].addr, addr, len) == 0 &&
            net_port_ok(&net_rules[i], port))
            return 1;
    now = net_now();
    pthread_mutex_lock(&net_lock);
    for (i = 0; i < net_naddrs; i++)
        if (net_addrs[i].family == family && memcmp(net_addrs[i].addr, addr, len) == 0 &&
            net_addrs[i].expire >= now)
            rules = net_addrs[i].rules;
    pthread_mutex_unlock(&net_lock);
    for (i = 0; i < net_nrules && !ok; i++)
        if ((rules >> i & 1) && net_port_ok(&net_rules[i], port))
            ok = 1;
    return ok;
}

/* The check of an address of a call: 1 when it is allowed. Other
 * families than IPv4 and IPv6 (a Unix socket, AF_UNSPEC) are not the
 * network of this check. */
static int net_check(const struct sockaddr *sa, socklen_t len, int bind)
{
    const struct sockaddr_in *in;
    const struct sockaddr_in6 *in6;

    if (!net_on || !sa)
        return 1;
    if (len >= sizeof(struct sockaddr_in) && sa->sa_family == AF_INET) {
        in = (const struct sockaddr_in *)sa;
        return net_allowed(AF_INET, (const unsigned char *)&in->sin_addr, ntohs(in->sin_port), bind);
    }
    if (sa->sa_family == AF_INET6) {
        if (len < sizeof(struct sockaddr_in6))
            return 0;
        in6 = (const struct sockaddr_in6 *)sa;
        if (IN6_IS_ADDR_V4MAPPED(&in6->sin6_addr))
            return net_allowed(AF_INET, in6->sin6_addr.s6_addr + 12, ntohs(in6->sin6_port), bind);
        return net_allowed(AF_INET6, in6->sin6_addr.s6_addr, ntohs(in6->sin6_port), bind);
    }
    if (sa->sa_family == AF_INET)
        return 0;
    return 1;
}

int __wrap_connect(int fd, const struct sockaddr *sa, socklen_t len)
{
    if (!net_check(sa, len, 0)) {
        errno = EACCES;
        return -1;
    }
    return __real_connect(fd, sa, len);
}

int __wrap_bind(int fd, const struct sockaddr *sa, socklen_t len)
{
    if (!net_check(sa, len, 1)) {
        errno = EACCES;
        return -1;
    }
    return __real_bind(fd, sa, len);
}

ssize_t __wrap_sendto(int fd, const void *buf, size_t n, int flags,
                      const struct sockaddr *sa, socklen_t len)
{
    if (sa && !net_check(sa, len, 0)) {
        errno = EACCES;
        return -1;
    }
    return __real_sendto(fd, buf, n, flags, sa, len);
}

ssize_t __wrap_sendmsg(int fd, const struct msghdr *msg, int flags)
{
    if (msg && msg->msg_name && !net_check(msg->msg_name, msg->msg_namelen, 0)) {
        errno = EACCES;
        return -1;
    }
    return __real_sendmsg(fd, msg, flags);
}

/* --- Messages of DNS --------------------------------------------------- */

/* Read the name at *off of the message m (n bytes), with its pointers,
 * into out (lower case, with no dot at the end). *off moves to the byte
 * after the name. Gives 0, or -1 for a bad name or a name with other
 * bytes than those of net_name_ok(). */
static int dns_name(const unsigned char *m, size_t n, size_t *off, char out[256])
{
    size_t o = *off, len = 0, i;
    int jumped = 0, hops = 0;
    unsigned c;

    for (;;) {
        if (o >= n)
            return -1;
        c = m[o];
        if (c == 0) {
            if (!jumped)
                *off = o + 1;
            break;
        }
        if ((c & 0xc0) == 0xc0) {
            if (o + 1 >= n || ++hops > 32)
                return -1;
            if (!jumped)
                *off = o + 2;
            jumped = 1;
            o = (c & 0x3f) << 8 | m[o + 1];
            continue;
        }
        if (c & 0xc0)
            return -1;
        if (o + 1 + c > n || len + (len ? 1 : 0) + c > 253)
            return -1;
        if (len)
            out[len++] = '.';
        for (i = 0; i < c; i++) {
            char ch = (char)m[o + 1 + i];
            if (ch >= 'A' && ch <= 'Z')
                ch += 'a' - 'A';
            /* Only the bytes of net_name_ok(): a "." in a label would
             * make the text of another name. */
            if (!((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '-' || ch == '_'))
                return -1;
            out[len++] = ch;
        }
        o += 1 + c;
    }
    out[len] = '\0';
    return len == 0 || net_name_ok(out) ? 0 : -1;
}

/* Skip a resource record at *off. Gives the offset of its data, or 0. */
static size_t dns_skip_rr(const unsigned char *m, size_t n, size_t *off, char name[256],
                          unsigned *type, unsigned *class, uint32_t *ttl, unsigned *rdlen)
{
    size_t o = *off, data;

    if (dns_name(m, n, &o, name) || o + 10 > n)
        return 0;
    *type = get16(m + o);
    *class = get16(m + o + 2);
    *ttl = get32(m + o + 4);
    *rdlen = get16(m + o + 8);
    data = o + 10;
    if (data + *rdlen > n)
        return 0;
    *off = data + *rdlen;
    return data;
}

/* One walk of the answers of the message m (n bytes). Without rules, it
 * adds the targets of the CNAME records of the names of chain to chain,
 * and gives 1 when it added one. With rules, it records the addresses of
 * the A and AAAA records of the names of chain. */
static int dns_walk(const unsigned char *m, size_t n, char chain[][256], int *nchain,
                    uint64_t rules)
{
    char name[256], target[256];
    unsigned ancount = get16(m + 6), type, class, rdlen, k;
    uint32_t ttl;
    size_t off = 12, data, t;
    int i, changed = 0;
    int64_t expire;

    if (dns_name(m, n, &off, name) || off + 4 > n)
        return 0;
    off += 4;
    for (k = 0; k < ancount; k++) {
        if (!(data = dns_skip_rr(m, n, &off, name, &type, &class, &ttl, &rdlen)))
            break;
        if (class != 1)
            continue;
        for (i = 0; i < *nchain; i++)
            if (strcmp(chain[i], name) == 0)
                break;
        if (i == *nchain)
            continue;
        if (!rules && type == 5 && *nchain < 16) {
            t = data;
            if (dns_name(m, data + rdlen, &t, target) == 0 && target[0]) {
                for (i = 0; i < *nchain; i++)
                    if (strcmp(chain[i], target) == 0)
                        break;
                if (i == *nchain) {
                    strcpy(chain[(*nchain)++], target);
                    changed = 1;
                }
            }
        } else if (rules) {
            if (ttl > 604800)
                ttl = 604800;
            expire = net_now() + (ttl < 60 ? 60 : ttl) + NET_KEEP;
            if (type == 1 && rdlen == 4)
                net_record(AF_INET, m + data, rules, expire);
            else if (type == 28 && rdlen == 16)
                net_record(AF_INET6, m + data, rules, expire);
        }
    }
    return changed;
}

/* Record the addresses of an answer (n bytes) to the name qname: the A
 * and AAAA records of qname and of the names of its CNAME chain. */
static void dns_record(const unsigned char *m, size_t n, const char *qname, uint64_t rules)
{
    char chain[16][256];
    int nchain = 1, pass;

    if (n < 12 || (m[3] & 0x0f) != 0)
        return;
    strcpy(chain[0], qname);
    for (pass = 0; pass < 16 && dns_walk(m, n, chain, &nchain, 0); pass++)
        ;
    dns_walk(m, n, chain, &nchain, rules);
}

/* The entries of the list that allow the question of the query q (n
 * bytes): one question of the class IN. 0 for another message. name gets
 * the name of the question. */
static uint64_t dns_query_rules(const unsigned char *q, size_t n, char name[256])
{
    size_t off = 12;

    if (n < 12 || (q[2] & 0x80) || ((q[2] >> 3) & 0x0f) != 0 || get16(q + 4) != 1)
        return 0;
    if (dns_name(q, n, &off, name) || off + 4 > n || get16(q + off + 2) != 1)
        return 0;
    return net_name_rules(name);
}

/* An answer with no records: the header and the question of the query
 * q, with the flags QR, RD of q, RA and the code rcode. */
static size_t dns_empty(const unsigned char *q, size_t qend, unsigned char *out, unsigned rcode,
                        int tc)
{
    memcpy(out, q, qend);
    out[2] = 0x80 | (q[2] & 0x01) | (tc ? 0x02 : 0);
    out[3] = 0x80 | rcode;
    put16(out + 4, qend > 12 ? 1 : 0);
    put16(out + 6, 0);
    put16(out + 8, 0);
    put16(out + 10, 0);
    return qend;
}

/* The answer for "localhost": 127.0.0.1 or ::1 (RFC 6761). */
static size_t dns_localhost(const unsigned char *q, size_t qend, unsigned qtype, unsigned char *out)
{
    static const unsigned char v4[4] = {127, 0, 0, 1};
    static const unsigned char v6[16] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    size_t n = dns_empty(q, qend, out, 0, 0);
    unsigned len = qtype == 1 ? 4 : 16;

    if (qtype != 1 && qtype != 28)
        return n;
    put16(out + 6, 1);
    out[n++] = 0xc0;
    out[n++] = 12;
    put16(out + n, qtype);
    put16(out + n + 2, 1);
    memset(out + n + 4, 0, 4);
    put16(out + n + 8, len);
    memcpy(out + n + 10, qtype == 1 ? v4 : v6, len);
    return n + 10 + len;
}

/* --- The name servers ---------------------------------------------- */

static int net_sockaddr(const struct net_ns *ns, struct sockaddr_storage *ss, socklen_t *len)
{
    memset(ss, 0, sizeof(*ss));
    if (ns->family == AF_INET) {
        struct sockaddr_in *in = (struct sockaddr_in *)ss;
        in->sin_family = AF_INET;
        in->sin_port = htons(ns->port);
        memcpy(&in->sin_addr, ns->addr, 4);
        *len = sizeof(*in);
    } else {
        struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)ss;
        in6->sin6_family = AF_INET6;
        in6->sin6_port = htons(ns->port);
        memcpy(&in6->sin6_addr, ns->addr, 16);
        *len = sizeof(*in6);
    }
    return 0;
}

/* Is the answer r (rn bytes) the answer of the query q (question ends
 * at qend)? */
static int dns_matches(const unsigned char *q, size_t qend, const unsigned char *r, size_t rn)
{
    char qn[256], rname[256];
    size_t qo = 12, ro = 12;

    if (rn < qend || get16(r) != get16(q) || !(r[2] & 0x80) || get16(r + 4) != 1)
        return 0;
    if (dns_name(q, qend, &qo, qn) || dns_name(r, rn, &ro, rname) || ro + 4 > rn)
        return 0;
    return strcmp(qn, rname) == 0 && memcmp(q + qo, r + ro, 4) == 0;
}

static int net_full(int fd, unsigned char *buf, size_t n, int out)
{
    size_t done = 0;
    ssize_t k;

    while (done < n) {
        k = out ? send(fd, buf + done, n - done, MSG_NOSIGNAL) : recv(fd, buf + done, n - done, 0);
        if (k <= 0) {
            if (k < 0 && errno == EINTR)
                continue;
            return -1;
        }
        done += k;
    }
    return 0;
}

static void net_timeouts(int fd, int ms)
{
    struct timeval tv;
    tv.tv_sec = ms / 1000;
    tv.tv_usec = ms % 1000 * 1000;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

/* The query over TCP. Gives the length of the answer, or 0. */
static size_t net_ask_tcp(const struct net_ns *ns, const unsigned char *q, size_t qn, size_t qend,
                          unsigned char *r)
{
    struct sockaddr_storage ss;
    socklen_t len;
    unsigned char head[2];
    size_t rn = 0;
    int fd;

    net_sockaddr(ns, &ss, &len);
    if ((fd = socket(ns->family, SOCK_STREAM, 0)) < 0)
        return 0;
    net_timeouts(fd, NET_TRY_MS * 2);
    put16(head, qn);
    if (__real_connect(fd, (struct sockaddr *)&ss, len) == 0 &&
        net_full(fd, head, 2, 1) == 0 && net_full(fd, (unsigned char *)q, qn, 1) == 0 &&
        net_full(fd, head, 2, 0) == 0 && net_full(fd, r, get16(head), 0) == 0 &&
        dns_matches(q, qend, r, get16(head)))
        rn = get16(head);
    close(fd);
    return rn;
}

/* The query over UDP, and over TCP when the answer is cut. Gives the
 * length of the answer, or 0. */
static size_t net_ask(const unsigned char *q, size_t qn, size_t qend, unsigned char *r)
{
    struct sockaddr_storage ss;
    socklen_t len;
    struct pollfd p;
    int round, i, fd;
    ssize_t k;
    int64_t end;
    struct timespec ts;

    for (round = 0; round < 2; round++)
        for (i = 0; i < net_nns; i++) {
            net_sockaddr(&net_ns[i], &ss, &len);
            if ((fd = socket(net_ns[i].family, SOCK_DGRAM, 0)) < 0)
                continue;
            if (__real_connect(fd, (struct sockaddr *)&ss, len) || send(fd, q, qn, 0) < 0) {
                close(fd);
                continue;
            }
            clock_gettime(CLOCK_MONOTONIC, &ts);
            end = (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000 + NET_TRY_MS;
            for (;;) {
                int64_t left;
                clock_gettime(CLOCK_MONOTONIC, &ts);
                left = end - ((int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
                if (left <= 0)
                    break;
                p.fd = fd;
                p.events = POLLIN;
                p.revents = 0;
                if (poll(&p, 1, (int)left) <= 0)
                    continue;
                if ((k = recv(fd, r, NET_MSG, 0)) <= 0)
                    break;
                if (!dns_matches(q, qend, r, k))
                    continue;
                close(fd);
                if (r[2] & 0x02)
                    return net_ask_tcp(&net_ns[i], q, qn, qend, r);
                return k;
            }
            close(fd);
        }
    return 0;
}

/* --- The resolver --------------------------------------------------------- */

/* The answer to the query q (n bytes), in out (NET_MSG bytes). tcp: the
 * client has no limit of size. Gives the length, or 0 to send nothing. */
static size_t net_answer(const unsigned char *q, size_t n, int tcp, unsigned char *out)
{
    char name[256], other[256];
    unsigned qtype, qclass, type, class, rdlen, arcount, k, id, limit = 512;
    uint32_t ttl;
    size_t off = 12, qend, rn, a;
    uint64_t rules;
    unsigned char *ask;

    if (n < 12 || (q[2] & 0x80))
        return 0;
    if (((q[2] >> 3) & 0x0f) != 0 || get16(q + 4) != 1 || get16(q + 6) || get16(q + 8))
        return dns_empty(q, 12, out, 4, 0);
    if (dns_name(q, n, &off, name) || off + 4 > n)
        return dns_empty(q, 12, out, 1, 0);
    qtype = get16(q + off);
    qclass = get16(q + off + 2);
    qend = off + 4;
    /* The size that the client takes: the OPT record of EDNS. */
    arcount = get16(q + 10);
    a = qend;
    for (k = 0; k < arcount; k++) {
        if (!dns_skip_rr(q, n, &a, other, &type, &class, &ttl, &rdlen))
            break;
        if (type == 41 && class > limit)
            limit = class;
    }
    rules = qclass == 1 ? net_name_rules(name) : 0;
    if (!rules) {
        if (net_verbose)
            fprintf(stderr, "beam.com: the sandbox refused the name %s (--allow-net)\n", name);
        return dns_empty(q, qend, out, 3, 0);
    }
    if (strcmp(name, "localhost") == 0)
        return dns_localhost(q, qend, qtype, out);
    if (!(ask = malloc(n + NET_MSG)))
        return dns_empty(q, qend, out, 2, 0);
    memcpy(ask, q, n);
    if (getrandom(&id, sizeof(id), 0) != sizeof(id))
        id = (unsigned)rand();
    put16(ask, id & 0xffff);
    rn = net_ask(ask, n, qend, ask + n);
    if (!rn) {
        free(ask);
        return dns_empty(q, qend, out, 2, 0);
    }
    dns_record(ask + n, rn, name, rules);
    memcpy(out, ask + n, rn);
    free(ask);
    put16(out, get16(q));
    if (!tcp && rn > limit)
        return dns_empty(q, qend, out, out[3] & 0x0f, 1);
    return rn;
}

struct net_job {
    int fd;                 /* a TCP client, or -1 for UDP */
    struct sockaddr_storage from;
    socklen_t fromlen;
    size_t n;
    unsigned char msg[4096];
};

static void *net_worker(void *arg)
{
    struct net_job *job = arg;
    unsigned char *out = malloc(NET_MSG + 2);
    unsigned char head[2];
    size_t len, n;

    if (out && job->fd < 0) {
        if ((len = net_answer(job->msg, job->n, 0, out)))
            __real_sendto(net_udp, out, len, 0, (struct sockaddr *)&job->from, job->fromlen);
    } else if (out) {
        unsigned char *q = malloc(NET_MSG);
        net_timeouts(job->fd, 10000);
        while (q && net_full(job->fd, head, 2, 0) == 0) {
            n = get16(head);
            if (net_full(job->fd, q, n, 0) || !(len = net_answer(q, n, 1, out + 2)))
                break;
            put16(out, len);
            if (net_full(job->fd, out, len + 2, 1))
                break;
        }
        free(q);
    }
    if (job->fd >= 0)
        close(job->fd);
    free(out);
    free(job);
    atomic_fetch_sub(&net_workers, 1);
    return NULL;
}

static void net_spawn(struct net_job *job)
{
    pthread_t t;
    pthread_attr_t attr;

    if (atomic_fetch_add(&net_workers, 1) >= NET_WORKERS) {
        atomic_fetch_sub(&net_workers, 1);
        if (job->fd >= 0)
            close(job->fd);
        free(job);
        return;
    }
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&t, &attr, net_worker, job)) {
        atomic_fetch_sub(&net_workers, 1);
        if (job->fd >= 0)
            close(job->fd);
        free(job);
    }
    pthread_attr_destroy(&attr);
}

static void *net_loop(void *arg)
{
    struct pollfd p[2];
    struct net_job *job;
    ssize_t k;
    int fd;

    (void)arg;
    for (;;) {
        p[0].fd = net_udp;
        p[0].events = POLLIN;
        p[0].revents = 0;
        p[1].fd = net_tcp;
        p[1].events = POLLIN;
        p[1].revents = 0;
        if (poll(p, 2, -1) < 0) {
            if (errno == EINTR)
                continue;
            return NULL;
        }
        if (p[0].revents & POLLIN) {
            if (!(job = malloc(sizeof(*job))))
                continue;
            job->fd = -1;
            job->fromlen = sizeof(job->from);
            k = recvfrom(net_udp, job->msg, sizeof(job->msg), 0,
                         (struct sockaddr *)&job->from, &job->fromlen);
            if (k <= 0) {
                free(job);
                continue;
            }
            job->n = k;
            net_spawn(job);
        }
        if (p[1].revents & POLLIN) {
            if ((fd = accept(net_tcp, NULL, NULL)) < 0)
                continue;
            if (!(job = malloc(sizeof(*job)))) {
                close(fd);
                continue;
            }
            job->fd = fd;
            job->n = 0;
            net_spawn(job);
        }
    }
}

/* --- Start ------------------------------------------------------------- */

#ifndef BEAM_COM_NET_TEST

/* --- Linux: the supervisor of the calls of the network ---------------- *
 *
 * The wraps of the libc see only the calls of the libc, and native code
 * can make a system call itself. On Linux 5.6 and later, a process of its
 * own checks each call (seccomp user notification):
 *
 * 1. Before the sandbox, beam.com forks. The parent is the supervisor,
 *    with the resolver and the table of addresses. The child goes on as
 *    the VM. The supervisor is an ancestor of the VM and of the programs
 *    of --allow-run, so Yama (ptrace_scope 1) lets it read their memory
 *    and get their sockets.
 * 2. The VM installs a seccomp filter: connect(), bind(), sendto() with
 *    an address, sendmsg() and sendmmsg() wait for the supervisor. The
 *    supervisor takes the listener of the filter with pidfd_getfd(), and
 *    the VM closes its own copy. The children of the VM keep the filter.
 * 3. For a socket of IPv4 or IPv6, the supervisor copies the address and
 *    the data (process_vm_readv()), checks the copy, and makes the call
 *    itself, on a copy of the socket (pidfd_getfd()). So the process
 *    cannot change the address after the check. For another socket, the
 *    kernel goes on with the call (SECCOMP_USER_NOTIF_FLAG_CONTINUE): the
 *    family of a socket does not change.
 * 4. A program of --allow-run asks the name servers of the system. For a
 *    query over UDP to them, the supervisor checks the name, asks the
 *    name server itself first and records the answer, and then sends the
 *    query of the program. A name that the list does not allow gets
 *    EACCES. The program cannot use TCP to them.
 *
 * Without these features (an older kernel, ptrace_scope 2 or 3, or a
 * container that refuses pidfd_getfd()), the wraps of the libc and the
 * Landlock ports do the check, as on the other systems.
 *
 * Caution: a query that a program sends with send() on a socket that it
 * connected to a name server (glibc for one question) is not visible: the
 * supervisor allows the connect(), and it records no address for the
 * name. The program then cannot connect to the address of its answer.
 */

#ifdef __x86_64__
#define NETD_ARCH 0xc000003eu
enum { NR_IOCTL = 16, NR_CONNECT = 42, NR_SENDTO = 44, NR_SENDMSG = 46, NR_BIND = 49,
       NR_GETSOCKOPT = 55, NR_GETPEERNAME = 52, NR_PRCTL = 157, NR_SENDMMSG = 307,
       NR_VM_READV = 310, NR_VM_WRITEV = 311, NR_SECCOMP = 317 };
#else
#define NETD_ARCH 0xc00000b7u
enum { NR_IOCTL = 29, NR_CONNECT = 203, NR_SENDTO = 206, NR_SENDMSG = 211, NR_BIND = 200,
       NR_GETSOCKOPT = 209, NR_GETPEERNAME = 205, NR_PRCTL = 167, NR_SENDMMSG = 269,
       NR_VM_READV = 270, NR_VM_WRITEV = 271, NR_SECCOMP = 277 };
#endif
enum { NR_PIDFD_OPEN = 434, NR_PIDFD_GETFD = 438 };

/* The ioctl() of the listener (linux/seccomp.h). */
#define NOTIF_RECV 0xc0502100ul
#define NOTIF_SEND 0xc0182101ul
#define NOTIF_ID_VALID 0x40082102ul
#define NOTIF_CONTINUE 1u
#define NETD_FLAG_NEW_LISTENER 8u
#define NETD_FLAG_WAIT_KILLABLE_RECV 32u
#define NETD_RET_USER_NOTIF 0x7fc00000u

/* The most data of one call that the supervisor copies: a stream sends
 * a part of it, a datagram gets EMSGSIZE. */
#define NETD_DATA (1 << 20)
#define NETD_WORKERS 128

struct netd_data {
    int32_t nr;
    uint32_t arch;
    uint64_t ip;
    uint64_t args[6];
};
struct netd_notif {
    uint64_t id;
    uint32_t pid;
    uint32_t flags;
    struct netd_data data;
};
struct netd_resp {
    uint64_t id;
    int64_t val;
    int32_t error;
    uint32_t flags;
};
/* struct msghdr, struct iovec and struct mmsghdr of 64-bit Linux, as the
 * memory of the process has them. */
struct netd_msghdr {
    uint64_t name;
    uint32_t namelen, pad;
    uint64_t iov, iovlen, control, controllen;
    int32_t flags;
    uint32_t pad2;
};
struct netd_iovec {
    uint64_t base, len;
};
struct netd_mmsghdr {
    struct netd_msghdr hdr;
    uint32_t len, pad;
};

static int netd_on;          /* the VM: the supervisor checks its calls */
static pid_t netd_vm;        /* the supervisor: the process of the VM */
static atomic_int netd_workers;

/* A system call: the result, or -errno. */
static long netd_sys(long n, long a, long b, long c, long d, long e, long f)
{
#ifdef __x86_64__
    register long r10 asm("r10") = d;
    register long r8 asm("r8") = e;
    register long r9 asm("r9") = f;
    long rc;
    asm volatile("syscall"
                 : "=a"(rc)
                 : "0"(n), "D"(a), "S"(b), "d"(c), "r"(r10), "r"(r8), "r"(r9)
                 : "rcx", "r11", "memory");
    return rc;
#else
    register long x8 asm("x8") = n;
    register long x0 asm("x0") = a;
    register long x1 asm("x1") = b;
    register long x2 asm("x2") = c;
    register long x3 asm("x3") = d;
    register long x4 asm("x4") = e;
    register long x5 asm("x5") = f;
    asm volatile("svc\t0"
                 : "+r"(x0)
                 : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5)
                 : "memory");
    return x0;
#endif
}

static int netd_read(pid_t pid, uint64_t remote, void *local, size_t n)
{
    struct iovec l = {local, n}, r = {(void *)(uintptr_t)remote, n};
    return n == 0 || netd_sys(NR_VM_READV, pid, (long)&l, 1, (long)&r, 1, 0) == (long)n ? 0 : -1;
}

static int netd_write(pid_t pid, uint64_t remote, const void *local, size_t n)
{
    struct iovec l = {(void *)local, n}, r = {(void *)(uintptr_t)remote, n};
    return netd_sys(NR_VM_WRITEV, pid, (long)&l, 1, (long)&r, 1, 0) == (long)n ? 0 : -1;
}

/* The process of a thread: the Tgid of /proc/TID/status. */
static pid_t netd_tgid(pid_t tid)
{
    char path[64], line[128];
    pid_t tgid = -1;
    FILE *f;

    snprintf(path, sizeof(path), "/proc/%d/status", (int)tid);
    if (!(f = fopen(path, "r")))
        return -1;
    while (fgets(line, sizeof(line), f))
        if (strncmp(line, "Tgid:", 5) == 0) {
            tgid = atoi(line + 5);
            break;
        }
    fclose(f);
    return tgid;
}

/* The address of a sockaddr of Linux (a copy): 0 when it is IPv4 or
 * IPv6, with an IPv4-mapped address as IPv4. */
static int netd_addr(const unsigned char *sa, size_t len, int *family, unsigned char addr[16],
                     int *port)
{
    unsigned f = sa[0] | sa[1] << 8;
    static const unsigned char mapped[12] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff};

    if (len >= 16 && f == 2) {
        *family = AF_INET;
        *port = sa[2] << 8 | sa[3];
        memcpy(addr, sa + 4, 4);
        return 0;
    }
    if (len >= 24 && f == 10) {
        *port = sa[2] << 8 | sa[3];
        if (memcmp(sa + 8, mapped, 12) == 0) {
            *family = AF_INET;
            memcpy(addr, sa + 20, 4);
        } else {
            *family = AF_INET6;
            memcpy(addr, sa + 8, 16);
        }
        return 0;
    }
    return -1;
}

static int netd_is_ns(int family, const unsigned char *addr, int port)
{
    int i;
    for (i = 0; i < net_nns; i++)
        if (net_ns[i].family == family && net_ns[i].port == port &&
            memcmp(net_ns[i].addr, addr, family == AF_INET ? 4 : 16) == 0)
            return 1;
    return 0;
}

/* A query of a program to a name server: 0 when the list allows its
 * name. The supervisor asks the name server first, and records the
 * addresses of its answer, so that they are in the table before the
 * program gets its own answer. */
static int netd_dns(const unsigned char *q, size_t n)
{
    char name[256];
    uint64_t rules = dns_query_rules(q, n, name);
    unsigned char *ask;
    size_t qend, rn, off = 12;
    unsigned id;

    if (!rules) {
        if (net_verbose)
            fprintf(stderr, "beam.com: the sandbox refused a query of a program (--allow-net)\n");
        return -1;
    }
    if (dns_name(q, n, &off, name) || !(ask = malloc(n + NET_MSG)))
        return 0;
    qend = off + 4;
    memcpy(ask, q, qend);
    put16(ask + 6, 0);
    put16(ask + 8, 0);
    put16(ask + 10, 0);
    if (getrandom(&id, sizeof(id), 0) != sizeof(id))
        id = (unsigned)rand();
    put16(ask, id & 0xffff);
    if ((rn = net_ask(ask, qend, qend, ask + n)))
        dns_record(ask + n, rn, name, rules);
    free(ask);
    return 0;
}

/* The check of a destination: 0, or the errno. dgram: a socket of
 * datagrams. data: the data of a send, or NULL (connect(), bind()). */
static int netd_check(const unsigned char *sa, size_t len, int bind, int child, int dgram,
                      const unsigned char *data, size_t n)
{
    unsigned char addr[16];
    int family, port;

    if (len >= 2 && (sa[0] | sa[1] << 8) == 0)
        return bind ? EACCES : 0; /* AF_UNSPEC: connect() undoes the peer */
    if (netd_addr(sa, len, &family, addr, &port))
        return EAFNOSUPPORT;
    if (child && !bind && netd_is_ns(family, addr, port)) {
        if (!dgram)
            return EACCES;
        return data && netd_dns(data, n) ? EACCES : 0;
    }
    return net_allowed(family, addr, port, bind) ? 0 : EACCES;
}

/* The data of iovecs of the process, in one buffer. */
static unsigned char *netd_gather(pid_t pid, uint64_t iov, uint64_t iovlen, int dgram,
                                  size_t *n, int *err)
{
    struct netd_iovec *v;
    unsigned char *buf;
    size_t total = 0, i, take;

    *n = 0;
    if (iovlen > 1024) {
        *err = EMSGSIZE;
        return NULL;
    }
    v = calloc(iovlen ? iovlen : 1, sizeof(*v));
    if (!v || netd_read(pid, iov, v, iovlen * sizeof(*v))) {
        free(v);
        *err = EFAULT;
        return NULL;
    }
    for (i = 0; i < iovlen; i++)
        total += v[i].len > NETD_DATA ? NETD_DATA + 1 : v[i].len;
    if (total > NETD_DATA && dgram) {
        free(v);
        *err = EMSGSIZE;
        return NULL;
    }
    if (!(buf = malloc(total > NETD_DATA ? NETD_DATA : total ? total : 1))) {
        free(v);
        *err = ENOMEM;
        return NULL;
    }
    for (i = 0; i < iovlen && *n < NETD_DATA; i++) {
        take = v[i].len < NETD_DATA - *n ? v[i].len : NETD_DATA - *n;
        if (netd_read(pid, v[i].base, buf + *n, take)) {
            free(v);
            free(buf);
            *err = EFAULT;
            return NULL;
        }
        *n += take;
    }
    free(v);
    return buf;
}

/* One sendmsg() of the process: the result, or -errno. peer: the peer of
 * the socket (for a message with no address). */
static long netd_sendmsg(pid_t pid, int fd, const struct netd_msghdr *h, int flags, int child,
                         int dgram, const unsigned char *peer, size_t peerlen)
{
    unsigned char name[128], *data, *control = NULL;
    struct msghdr m;
    struct iovec io;
    size_t n;
    long rc;
    int err = 0;

    memset(&m, 0, sizeof(m));
    if (h->name && h->namelen) {
        if (h->namelen > sizeof(name))
            return -EINVAL;
        if (netd_read(pid, h->name, name, h->namelen))
            return -EFAULT;
    }
    if (!(data = netd_gather(pid, h->iov, h->iovlen, dgram, &n, &err)))
        return -err;
    if (h->name && h->namelen)
        err = netd_check(name, h->namelen, 0, child, dgram, data, n);
    else if (peer)
        err = netd_check(peer, peerlen, 0, child, dgram, data, n);
    if (!err && h->controllen) {
        if (h->controllen > 65536)
            err = ENOBUFS;
        else if (!(control = malloc(h->controllen)) ||
                 netd_read(pid, h->control, control, h->controllen))
            err = EFAULT;
    }
    if (err) {
        free(data);
        free(control);
        return -err;
    }
    io.iov_base = data;
    io.iov_len = n;
    m.msg_name = h->name && h->namelen ? name : NULL;
    m.msg_namelen = h->name ? h->namelen : 0;
    m.msg_iov = &io;
    m.msg_iovlen = 1;
    m.msg_control = control;
    m.msg_controllen = control ? h->controllen : 0;
    rc = netd_sys(NR_SENDMSG, fd, (long)&m, flags, 0, 0, 0);
    free(data);
    free(control);
    return rc;
}

static void netd_reply(int listener, uint64_t id, long rc, int cont)
{
    struct netd_resp r;

    memset(&r, 0, sizeof(r));
    r.id = id;
    if (cont)
        r.flags = NOTIF_CONTINUE;
    else if (rc < 0)
        r.error = (int32_t)rc;
    else
        r.val = rc;
    netd_sys(NR_IOCTL, listener, NOTIF_SEND, (long)&r, 0, 0, 0);
}

/* One call of a process: check it, and make it, or let the kernel go on
 * with it. */
static void netd_handle(int listener, const struct netd_notif *req)
{
    const uint64_t *a = req->data.args;
    long nr = req->data.nr, rc = -EACCES;
    pid_t tid = req->pid, pid = netd_tgid(tid);
    int pidfd, fd = -1, child = pid != netd_vm, domain = 0, type = 0, dgram;
    unsigned char sa[128], peer[128], *data = NULL;
    socklen_t ol = sizeof(int), pl = sizeof(peer);
    uint64_t id = req->id;
    size_t n = 0;

    if (pid <= 0 || (pidfd = (int)netd_sys(NR_PIDFD_OPEN, pid, 0, 0, 0, 0, 0)) < 0)
        goto reply;
    if (netd_sys(NR_IOCTL, listener, NOTIF_ID_VALID, (long)&id, 0, 0, 0) < 0) {
        close(pidfd);
        return;
    }
    fd = (int)netd_sys(NR_PIDFD_GETFD, pidfd, (long)a[0], 0, 0, 0, 0);
    close(pidfd);
    if (fd < 0) {
        rc = fd == -EBADF ? -EBADF : -EACCES;
        goto reply;
    }
    if (netd_sys(NR_GETSOCKOPT, fd, SOL_SOCKET, 39 /* SO_DOMAIN */, (long)&domain, (long)&ol, 0) ||
        (domain != AF_INET && domain != AF_INET6)) {
        /* Not a socket of the network: the kernel goes on (ENOTSOCK for
         * a file). */
        close(fd);
        netd_reply(listener, id, 0, 1);
        return;
    }
    ol = sizeof(int);
    netd_sys(NR_GETSOCKOPT, fd, SOL_SOCKET, 3 /* SO_TYPE */, (long)&type, (long)&ol, 0);
    dgram = type == SOCK_DGRAM;
    if (nr == NR_CONNECT || nr == NR_BIND) {
        if (a[2] > sizeof(sa)) {
            rc = -EINVAL;
        } else if (netd_read(tid, a[1], sa, a[2])) {
            rc = -EFAULT;
        } else if ((rc = -netd_check(sa, a[2], nr == NR_BIND, child, dgram, NULL, 0)) == 0) {
            rc = netd_sys(nr, fd, (long)sa, (long)a[2], 0, 0, 0);
        }
    } else if (nr == NR_SENDTO) {
        size_t len = a[2] > NETD_DATA ? NETD_DATA : a[2];
        if (a[2] > NETD_DATA && dgram)
            rc = -EMSGSIZE;
        else if (a[5] > sizeof(sa))
            rc = -EINVAL;
        else if (!(data = malloc(len ? len : 1)) || netd_read(tid, a[1], data, len) ||
                 netd_read(tid, a[4], sa, a[5]))
            rc = -EFAULT;
        else if ((rc = -netd_check(sa, a[5], 0, child, dgram, data, len)) == 0)
            rc = netd_sys(NR_SENDTO, fd, (long)data, (long)len, (long)a[3], (long)sa, (long)a[5]);
        n = len;
    } else if (nr == NR_SENDMSG || nr == NR_SENDMMSG) {
        int has_peer = netd_sys(NR_GETPEERNAME, fd, (long)peer, (long)&pl, 0, 0, 0) == 0;
        if (nr == NR_SENDMSG) {
            struct netd_msghdr h;
            rc = netd_read(tid, a[1], &h, sizeof(h))
                     ? -EFAULT
                     : netd_sendmsg(tid, fd, &h, (int)a[2], child, dgram, has_peer ? peer : NULL, pl);
        } else {
            struct netd_mmsghdr h;
            uint64_t i, vlen = a[2] > 64 ? 64 : a[2];
            uint32_t sent;
            for (i = 0, rc = 0; i < vlen; i++) {
                long one;
                if (netd_read(tid, a[1] + i * sizeof(h), &h, sizeof(h))) {
                    one = -EFAULT;
                } else {
                    one = netd_sendmsg(tid, fd, &h.hdr, (int)a[3], child, dgram,
                                       has_peer ? peer : NULL, pl);
                }
                if (one < 0) {
                    if (i == 0)
                        rc = one;
                    break;
                }
                sent = (uint32_t)one;
                netd_write(tid, a[1] + i * sizeof(h) + offsetof(struct netd_mmsghdr, len), &sent,
                           sizeof(sent));
                rc = (long)(i + 1);
            }
        }
    }
    (void)n;
reply:
    free(data);
    if (fd >= 0)
        close(fd);
    netd_reply(listener, id, rc, 0);
}

struct netd_job {
    int listener;
    struct netd_notif req;
};

static void *netd_worker(void *arg)
{
    struct netd_job *job = arg;
    netd_handle(job->listener, &job->req);
    free(job);
    atomic_fetch_sub(&netd_workers, 1);
    return NULL;
}

static void *netd_loop(void *arg)
{
    int listener = (int)(intptr_t)arg;
    struct pollfd p;
    struct netd_job *job;
    pthread_t t;
    pthread_attr_t attr;

    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    for (;;) {
        p.fd = listener;
        p.events = POLLIN;
        p.revents = 0;
        if (poll(&p, 1, -1) < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (!(p.revents & POLLIN)) {
            if (p.revents & (POLLHUP | POLLERR | POLLNVAL))
                break;
            continue;
        }
        if (!(job = calloc(1, sizeof(*job))))
            continue;
        job->listener = listener;
        if (netd_sys(NR_IOCTL, listener, NOTIF_RECV, (long)&job->req, 0, 0, 0) < 0) {
            free(job);
            continue;
        }
        /* A call can wait (a connect() of a blocking socket): each one in
         * a thread, and in this thread when there are too many. */
        if (atomic_fetch_add(&netd_workers, 1) >= NETD_WORKERS ||
            pthread_create(&t, &attr, netd_worker, job)) {
            atomic_fetch_sub(&netd_workers, 1);
            netd_handle(listener, &job->req);
            free(job);
        }
    }
    pthread_attr_destroy(&attr);
    return NULL;
}

/* The features of the supervisor: NULL, or the reason that it is not
 * there. */
static const char *netd_probe(void)
{
    uint16_t sizes[3];
    char buf[8];
    int pidfd, fd;
    FILE *f;

    if (getenv("BEAM_COM_NET_NO_SUPERVISOR"))
        return "BEAM_COM_NET_NO_SUPERVISOR";
    if (netd_sys(NR_SECCOMP, 3 /* SECCOMP_GET_NOTIF_SIZES */, 0, (long)sizes, 0, 0, 0) ||
        sizes[0] != sizeof(struct netd_notif) || sizes[1] != sizeof(struct netd_resp))
        return "no seccomp user notification (Linux 5.0)";
    if ((pidfd = (int)netd_sys(NR_PIDFD_OPEN, getpid(), 0, 0, 0, 0, 0)) < 0)
        return "no pidfd_open() (Linux 5.3)";
    fd = (int)netd_sys(NR_PIDFD_GETFD, pidfd, pidfd, 0, 0, 0, 0);
    close(pidfd);
    if (fd < 0)
        return "no pidfd_getfd() (Linux 5.6, or a container that refuses it)";
    close(fd);
    if (netd_read(getpid(), (uint64_t)(uintptr_t)&sizes, buf, 2))
        return "no process_vm_readv()";
    if ((f = fopen("/proc/sys/kernel/yama/ptrace_scope", "r"))) {
        int scope = fgetc(f);
        fclose(f);
        if (scope >= '2')
            return "Yama ptrace_scope 2 or 3";
    }
    return NULL;
}

/* The filter of the VM. Another architecture (32-bit calls, x32) gets
 * EACCES. */
static int netd_filter(void)
{
    struct sock_filter f[24];
    struct sock_fprog prog;
    int n = 0, k, allow, notif;
    long fd;

#define NETD_TO(t) ((unsigned char)((t) - n - 1))
    f[n++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, 4);
    f[n++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, NETD_ARCH, 1, 0);
    f[n++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, 0x00050000u | EACCES);
    f[n++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, 0);
#ifdef __x86_64__
    f[n++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, 0x40000000u, 0, 1);
    f[n++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, 0x00050000u | EACCES);
#endif
    k = n;
    allow = k + 9;
    notif = k + 10;
    f[n] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, NR_CONNECT, NETD_TO(notif), 0);
    n++;
    f[n] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, NR_BIND, NETD_TO(notif), 0);
    n++;
    f[n] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, NR_SENDMSG, NETD_TO(notif), 0);
    n++;
    f[n] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, NR_SENDMMSG, NETD_TO(notif), 0);
    n++;
    f[n] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, NR_SENDTO, 0, NETD_TO(allow));
    n++;
    /* sendto() with an address: args[4], at 16 + 4 * 8. */
    f[n++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, 48);
    f[n] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 0, 0, NETD_TO(notif));
    n++;
    f[n++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, 52);
    f[n] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 0, NETD_TO(allow), NETD_TO(notif));
    n++;
    f[n++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, 0x7fff0000u);
    f[n++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, NETD_RET_USER_NOTIF);
#undef NETD_TO
    prog.len = (unsigned short)n;
    prog.filter = f;
    if (netd_sys(NR_PRCTL, PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0, 0))
        return -1;
    fd = netd_sys(NR_SECCOMP, 1 /* SECCOMP_SET_MODE_FILTER */,
                  NETD_FLAG_NEW_LISTENER | NETD_FLAG_WAIT_KILLABLE_RECV, (long)&prog, 0, 0, 0);
    if (fd == -EINVAL)
        fd = netd_sys(NR_SECCOMP, 1, NETD_FLAG_NEW_LISTENER, (long)&prog, 0, 0, 0);
    return fd < 0 ? -1 : (int)fd;
}

static volatile sig_atomic_t netd_signal;

static void netd_forward(int sig)
{
    kill(netd_vm, sig);
}

/* The supervisor: the resolver and the checks, until the VM ends. It
 * then ends with the status of the VM. */
static void netd_parent(pid_t vm, int sock) __attribute__((__noreturn__));
static void netd_parent(pid_t vm, int sock)
{
    /* The signals of Cosmopolitan are not constants. */
    const int forward[] = {SIGTERM, SIGHUP, SIGUSR1, SIGUSR2, SIGWINCH};
    struct sigaction sa;
    sigset_t all, old;
    pthread_t t;
    pthread_attr_t attr;
    int fd = -1, pidfd, listener = -1, status, i, null;

    netd_vm = vm;
    /* The VM and its programs cannot attach to the supervisor. */
    prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);
    if (read(sock, &fd, sizeof(fd)) == sizeof(fd) && fd >= 0 &&
        (pidfd = (int)netd_sys(NR_PIDFD_OPEN, vm, 0, 0, 0, 0, 0)) >= 0) {
        listener = (int)netd_sys(NR_PIDFD_GETFD, pidfd, fd, 0, 0, 0, 0);
        close(pidfd);
    }
    if (listener < 0) {
        fprintf(stderr, "beam.com: --allow-net: the supervisor did not get the filter\n");
        kill(vm, SIGKILL);
    }
    if (write(sock, "", 1) != 1)
        kill(vm, SIGKILL);
    close(sock);
    if ((null = open("/dev/null", O_RDWR)) >= 0) {
        dup2(null, 0);
        dup2(null, 1);
        if (null > 2)
            close(null);
    }
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = netd_forward;
    sigemptyset(&sa.sa_mask);
    for (i = 0; i < (int)(sizeof(forward) / sizeof(*forward)); i++)
        sigaction(forward[i], &sa, NULL);
    signal(SIGINT, SIG_IGN);
    signal(SIGQUIT, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);
    if (listener >= 0) {
        sigfillset(&all);
        pthread_sigmask(SIG_SETMASK, &all, &old);
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&t, &attr, net_loop, NULL) ||
            pthread_create(&t, &attr, netd_loop, (void *)(intptr_t)listener)) {
            fprintf(stderr, "beam.com: --allow-net: the supervisor did not start\n");
            kill(vm, SIGKILL);
        }
        pthread_attr_destroy(&attr);
        pthread_sigmask(SIG_SETMASK, &old, NULL);
    }
    while (waitpid(vm, &status, 0) < 0)
        if (errno != EINTR)
            _exit(127);
    if (WIFSIGNALED(status)) {
        signal(WTERMSIG(status), SIG_DFL);
        sigemptyset(&all);
        sigprocmask(SIG_SETMASK, &all, NULL);
        kill(getpid(), WTERMSIG(status));
        _exit(128 + WTERMSIG(status));
    }
    _exit(WIFEXITED(status) ? WEXITSTATUS(status) : 127);
}

/* Fork: the parent is the supervisor (it does not return), the child the
 * VM, with the filter. Gives NULL in the VM, or the step that failed. */
static const char *netd_fork(void)
{
    int sv[2], listener;
    pid_t parent = getpid(), pid;
    char ack;

    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv))
        return "socketpair";
    if ((pid = fork()) < 0)
        return "fork";
    if (pid > 0) {
        close(sv[1]);
        netd_parent(pid, sv[0]);
    }
    close(sv[0]);
    if (prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) || getppid() != parent)
        _exit(127);
    if ((listener = netd_filter()) < 0) {
        listener = -1;
        if (write(sv[1], &listener, sizeof(listener)) < 0) {
        }
        return "seccomp";
    }
    if (write(sv[1], &listener, sizeof(listener)) != sizeof(listener) ||
        read(sv[1], &ack, 1) != 1)
        _exit(127);
    /* Caution: the VM must not keep the listener, else it could answer
     * for its own calls. */
    close(listener);
    close(sv[1]);
    return NULL;
}

/* The names of the hosts file that the list allows, for all time: kernel
 * reads this file before it asks the resolver. */
static void net_hosts_file(void)
{
    char buf[512], line[1024], *tok, *save, *hash;
    const char *path = IsWindows() ? GetHostsTxtPath(buf, sizeof(buf)) : "/etc/hosts";
    unsigned char addr[16];
    int family, lines = 0;
    size_t n;
    FILE *f;

    if (!path || !(f = fopen(path, "r")))
        return;
    while (fgets(line, sizeof(line), f) && lines++ < 10000) {
        if ((hash = strchr(line, '#')))
            *hash = '\0';
        if (!(tok = strtok_r(line, " \t\r\n", &save)))
            continue;
        if ((hash = strchr(tok, '%')))
            *hash = '\0';
        if (inet_pton(AF_INET, tok, addr) == 1)
            family = AF_INET;
        else if (inet_pton(AF_INET6, tok, addr) == 1)
            family = AF_INET6;
        else
            continue;
        while ((tok = strtok_r(NULL, " \t\r\n", &save))) {
            for (hash = tok; *hash; hash++)
                if (*hash >= 'A' && *hash <= 'Z')
                    *hash += 'a' - 'A';
            n = strlen(tok);
            if (n > 1 && tok[n - 1] == '.')
                tok[n - 1] = '\0';
            if (net_name_ok(tok))
                net_record(family, addr, net_name_rules(tok), INT64_MAX);
        }
    }
    fclose(f);
}

/* The name servers of the system (resolv.conf, or the registry of
 * Windows), or of BEAM_COM_DNS_UPSTREAM ("IP:PORT", for the tests). */
static void net_name_servers(int from_env)
{
    struct resolvconf rc;
    const char *up = from_env ? getenv("BEAM_COM_DNS_UPSTREAM") : NULL;
    char host[64], *colon;
    unsigned i;

    if (up && strlen(up) < sizeof(host)) {
        strcpy(host, up);
        if ((colon = strrchr(host, ':'))) {
            *colon = '\0';
            if (inet_pton(AF_INET, host, net_ns[0].addr) == 1) {
                net_ns[0].family = AF_INET;
                net_ns[0].port = atoi(colon + 1);
                net_nns = 1;
                return;
            }
        }
    }
    memset(&rc, 0, sizeof(rc));
    if (__get_resolv_conf(&rc, NULL, 0) != 0)
        return;
    for (i = 0; i < rc.nns && i < MAXNS && net_nns < 3; i++)
        if (rc.ns[i].family == AF_INET || rc.ns[i].family == AF_INET6) {
            net_ns[net_nns].family = rc.ns[i].family;
            memcpy(net_ns[net_nns].addr, rc.ns[i].addr, rc.ns[i].family == AF_INET ? 4 : 16);
            net_ns[net_nns].port = 53;
            net_nns++;
        }
}

/* The sockets of the resolver: UDP and TCP on 127.0.0.1, on one port. */
static int net_sockets(void)
{
    struct sockaddr_in in;
    socklen_t len = sizeof(in);
    int tries, one = 1;

    for (tries = 0; tries < 20; tries++) {
        if ((net_udp = socket(AF_INET, SOCK_DGRAM, 0)) < 0)
            return -1;
        memset(&in, 0, sizeof(in));
        in.sin_family = AF_INET;
        in.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (__real_bind(net_udp, (struct sockaddr *)&in, sizeof(in)) ||
            getsockname(net_udp, (struct sockaddr *)&in, &len))
            return -1;
        if ((net_tcp = socket(AF_INET, SOCK_STREAM, 0)) < 0)
            return -1;
        setsockopt(net_tcp, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        if (__real_bind(net_tcp, (struct sockaddr *)&in, sizeof(in)) == 0 &&
            listen(net_tcp, 16) == 0) {
            net_port = ntohs(in.sin_port);
            return 0;
        }
        close(net_udp);
        close(net_tcp);
        len = sizeof(in);
    }
    return -1;
}

/* Landlock of the network (ABI 4 and later): TCP connect() and bind()
 * only for the ports of the list, when each entry has a port. */
#define LL_NET_BIND_TCP 1ul
#define LL_NET_CONNECT_TCP 2ul
#define LL_RULE_NET_PORT 2
struct ll_ruleset_attr {
    uint64_t handled_access_fs;
    uint64_t handled_access_net;
};
struct ll_net_port_attr {
    uint64_t allowed_access;
    uint64_t port;
};

static int net_landlock_port(int fd, uint64_t access, int port)
{
    struct ll_net_port_attr p;
    p.allowed_access = access;
    p.port = (uint64_t)port;
    return landlock_add_rule(fd, (enum landlock_rule_type)LL_RULE_NET_PORT, &p, 0);
}

static const char *net_landlock(void)
{
    struct ll_ruleset_attr attr;
    int abi, fd, i;

    if (!IsLinux())
        return NULL;
    for (i = 0; i < net_nrules; i++)
        if (net_rules[i].port == 0)
            return NULL;
    abi = landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    if (abi < 4)
        return NULL;
    memset(&attr, 0, sizeof(attr));
    attr.handled_access_net = LL_NET_BIND_TCP | LL_NET_CONNECT_TCP;
    fd = landlock_create_ruleset((const struct landlock_ruleset_attr *)&attr, sizeof(attr), 0);
    if (fd < 0)
        return "landlock_create_ruleset";
    /* bind() to port 0 (a port of the system), the resolver, and its
     * name servers over TCP. */
    if (net_landlock_port(fd, LL_NET_BIND_TCP, 0) ||
        net_landlock_port(fd, LL_NET_CONNECT_TCP, net_port))
        return "landlock_add_rule";
    for (i = 0; i < net_nns; i++)
        if (net_landlock_port(fd, LL_NET_CONNECT_TCP, net_ns[i].port))
            return "landlock_add_rule";
    for (i = 0; i < net_nrules; i++)
        if (net_landlock_port(fd, LL_NET_BIND_TCP | LL_NET_CONNECT_TCP, net_rules[i].port))
            return "landlock_add_rule";
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) || landlock_restrict_self(fd, 0))
        return "landlock_restrict_self";
    close(fd);
    return NULL;
}

const char *beam_com_net_prepare(int from_env)
{
    const char *why = NULL, *step;

    net_verbose = getenv("BEAM_COM_VERBOSE") != NULL;
    net_name_servers(from_env);
    net_hosts_file();
    if (net_sockets())
        return "the socket of the resolver";
    if (IsLinux() && !(why = netd_probe())) {
        /* Only the VM returns. The resolver is in the supervisor. */
        if ((step = netd_fork()))
            return step;
        close(net_udp);
        close(net_tcp);
        netd_on = 1;
        if (net_verbose)
            fprintf(stderr, "beam.com: --allow-net: the supervisor checks the calls\n");
    } else {
        if (why && net_verbose)
            fprintf(stderr, "beam.com: --allow-net: no supervisor: %s\n", why);
        net_on = 1;
    }
    return net_landlock();
}

const char *beam_com_net_start(void)
{
    char addr[32];
    pthread_t t;
    pthread_attr_t attr;
    sigset_t all, old;

    snprintf(addr, sizeof(addr), "127.0.0.1:%d", net_port);
    setenv("BEAM_COM_DNS", addr, 1);
    if (netd_on)
        return NULL;
    /* The threads of the resolver take no signals: ERTS handles them. */
    sigfillset(&all);
    pthread_sigmask(SIG_SETMASK, &all, &old);
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    errno = pthread_create(&t, &attr, net_loop, NULL);
    pthread_attr_destroy(&attr);
    pthread_sigmask(SIG_SETMASK, &old, NULL);
    return errno ? "pthread_create" : NULL;
}

#endif
