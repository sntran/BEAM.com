/*
 * Non-blocking sends on a socket on Windows (beam_com_sock.c, C60 of
 * docs/UPSTREAM.md).
 */
#ifndef BEAM_COM_SOCK_H
#define BEAM_COM_SOCK_H

#include <stddef.h>
#include <sys/types.h>
#include <sys/uio.h>

/* 1 when FD is a socket with O_NONBLOCK on Windows: the sends of FD must
 * go to beam_com_sock_send(). */
int beam_com_sock_nonblock(int fd);

/* A send of IOV (IOVCNT parts) on the socket FD that never waits. FLAGS
 * are the flags of send(). Gives the count of the bytes that went into
 * the socket, or -1 with errno (EAGAIN when no byte fits). */
ssize_t beam_com_sock_send(int fd, const struct iovec *iov, int iovcnt, int flags);

/* Before the close of FD (__wrap_close() of beam_com.c). */
void beam_com_sock_close(int fd);

#endif
