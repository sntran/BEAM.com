/*
 * ssh_agent_bridge, linked into BEAM.com: the connection of the git
 * client (beam_com_git_ssh) to an SSH agent.
 *
 *   ssh_agent_bridge AGENT
 *
 * The program copies each message of its standard input to the agent, and
 * the answer of the agent to its standard output. A message of the agent
 * protocol has a length of 4 bytes (big-endian) before it, as a port with
 * {packet, 4}. The program exits with 0 when its input closes, and with 1
 * when the agent fails.
 *
 * On Windows, AGENT is a named pipe, for example the agent of Windows
 * OpenSSH, \\.\pipe\openssh-ssh-agent. Erlang cannot open a named pipe:
 * the path functions of Cosmopolitan change "\\.\pipe\NAME" (C55 of
 * docs/UPSTREAM.md). On the other systems, AGENT is a Unix socket (as
 * SSH_AUTH_SOCK), for the tests of the bridge.
 *
 * With BEAM_COM_AGENT_MAIN, this file is a program of its own (main()),
 * for the tests.
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <cosmo.h>
#include "libc/dce.h"
#include "libc/nt/createfile.h"
#include "libc/nt/enum/accessmask.h"
#include "libc/nt/enum/creationdisposition.h"
#include "libc/nt/errors.h"
#include "libc/nt/runtime.h"

/* An answer of an agent (a list of keys, or a signature) is small. */
#define AGENT_MAX (256 * 1024)
#define AGENT_PATH 512

/* The flags of CreateFile() for the security quality of service of a
 * client of a pipe (SECURITY_SQOS_PRESENT and SECURITY_IDENTIFICATION of
 * winbase.h). Cosmopolitan has no names for them. With these flags, the
 * server of the pipe can identify this client, but cannot impersonate it.
 * Windows OpenSSH sets the same flags for its agent. */
#define AGENT_SQOS_PRESENT 0x00100000u
#define AGENT_SQOS_IDENTIFICATION 0x00010000u

/* The agent: a handle of Windows, or a socket. */
struct agent {
    int64_t handle;
    int fd;
};

static int agent_open(const char *path, struct agent *a)
{
    a->handle = kNtInvalidHandleValue;
    a->fd = -1;
    if (IsWindows()) {
        char16_t name[AGENT_PATH];
        size_t i;
        int tries;
        for (i = 0; path[i] && i < AGENT_PATH - 1; i++) {
            if ((unsigned char)path[i] > 127)
                return -1; /* The name of a pipe is ASCII. */
            name[i] = path[i] == '/' ? '\\' : path[i];
        }
        if (path[i])
            return -1;
        name[i] = 0;
        for (tries = 0; tries < 50; tries++) {
            a->handle = CreateFile(name, kNtGenericRead | kNtGenericWrite, 0, 0,
                                   kNtOpenExisting,
                                   AGENT_SQOS_PRESENT | AGENT_SQOS_IDENTIFICATION,
                                   0);
            if (a->handle != kNtInvalidHandleValue)
                return 0;
            /* All the instances of the pipe are in use: try again after
             * 100 ms, for 5 s. Cosmopolitan has no WaitNamedPipe(). */
            if (GetLastError() != kNtErrorPipeBusy)
                return -1;
            usleep(100000);
        }
        return -1;
    } else {
        struct sockaddr_un sa;
        memset(&sa, 0, sizeof(sa));
        sa.sun_family = AF_UNIX;
        if (strlen(path) >= sizeof(sa.sun_path))
            return -1;
        strcpy(sa.sun_path, path);
        if ((a->fd = socket(AF_UNIX, SOCK_STREAM, 0)) < 0)
            return -1;
        if (connect(a->fd, (struct sockaddr *)&sa, sizeof(sa)) < 0)
            return -1;
        return 0;
    }
}

/* All N bytes of the agent, or -1. */
static int agent_read(struct agent *a, unsigned char *p, size_t n)
{
    while (n > 0) {
        if (IsWindows()) {
            uint32_t got = 0;
            if (!ReadFile(a->handle, p, n, &got, 0) || got == 0)
                return -1;
            p += got;
            n -= got;
        } else {
            ssize_t got = read(a->fd, p, n);
            if (got < 0 && errno == EINTR)
                continue;
            if (got <= 0)
                return -1;
            p += got;
            n -= got;
        }
    }
    return 0;
}

static int agent_write(struct agent *a, const unsigned char *p, size_t n)
{
    while (n > 0) {
        if (IsWindows()) {
            uint32_t put = 0;
            if (!WriteFile(a->handle, p, n, &put, 0) || put == 0)
                return -1;
            p += put;
            n -= put;
        } else {
            ssize_t put = write(a->fd, p, n);
            if (put < 0 && errno == EINTR)
                continue;
            if (put <= 0)
                return -1;
            p += put;
            n -= put;
        }
    }
    return 0;
}

/* All N bytes of the file descriptor FD: 1, 0 at the end of the input
 * before the first byte, or -1. */
static int fd_read(int fd, unsigned char *p, size_t n, int first)
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

static int fd_write(int fd, const unsigned char *p, size_t n)
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

static uint32_t get32(const unsigned char *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

/* One message with its length: from the input to the agent, or from the
 * agent to the output. 1, 0 at the end of the input, or -1. Buf has
 * 4 + AGENT_MAX bytes. */
static int relay(struct agent *a, unsigned char *buf, int from_agent)
{
    uint32_t len;
    int rc;

    /* agent_read() gives 0 or -1; fd_read() gives 1, 0 or -1. */
    rc = from_agent ? (agent_read(a, buf, 4) < 0 ? -1 : 1) : fd_read(0, buf, 4, 1);
    if (rc <= 0)
        return rc;
    len = get32(buf);
    if (len > AGENT_MAX)
        return -1;
    rc = from_agent ? agent_read(a, buf + 4, len) : fd_read(0, buf + 4, len, 0);
    if (rc < 0)
        return -1;
    return (from_agent ? fd_write(1, buf, 4 + len) : agent_write(a, buf, 4 + len)) < 0 ? -1 : 1;
}

int beam_com_ssh_agent_main(int argc, char **argv);

int beam_com_ssh_agent_main(int argc, char **argv)
{
    struct agent a;
    unsigned char *buf;
    int rc;

    if (argc != 2) {
        fprintf(stderr, "usage: ssh_agent_bridge AGENT\n");
        return 2;
    }
    if (agent_open(argv[1], &a) < 0) {
        fprintf(stderr, "ssh_agent_bridge: cannot connect to the agent %s\n", argv[1]);
        return 1;
    }
    if (!(buf = malloc(4 + AGENT_MAX)))
        return 1;
    for (;;) {
        rc = relay(&a, buf, 0);
        if (rc == 0)
            return 0;
        if (rc < 0 || relay(&a, buf, 1) <= 0) {
            fprintf(stderr, "ssh_agent_bridge: the agent %s failed\n", argv[1]);
            return 1;
        }
    }
}

#ifdef BEAM_COM_AGENT_MAIN
int main(int argc, char **argv)
{
    return beam_com_ssh_agent_main(argc, argv);
}
#endif
