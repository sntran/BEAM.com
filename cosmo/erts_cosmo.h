/*
 * Forced-include compatibility header for building ERTS with cosmocc.
 *
 * Cosmopolitan Libc defines some BSD macros without the matching
 * types, and some constants are only known at run time. This header
 * is passed with `-include` so that the OTP sources need fewer patches.
 *
 * It also holds the small helpers that make BEAM.com a multi-call
 * binary (see beam_com.c).
 */
#ifndef BEAM_COM_ERTS_COSMO_H
#define BEAM_COM_ERTS_COSMO_H
#ifdef __COSMOPOLITAN__

#include <sys/socket.h>
#include <netinet/in.h>
#include <poll.h>

/* Do not include <string.h> or <cosmo.h> here: autoconf tests that
 * undeclared builtins such as strchr() give an error. */
char *GetProgramExecutableName(void);

/* AF_LINK is defined, but struct sockaddr_dl is not. */
#undef AF_LINK

/* SCTP is not supported, but inet_drv uses the protocol number. */
#ifndef IPPROTO_SCTP
#define IPPROTO_SCTP 132
#endif

/* gethostid() is declared, but not defined. erl_interface only uses it
 * as one input for a random challenge. */
static inline long beam_com_gethostid(void) { return 0; }
#define gethostid beam_com_gethostid

/* There is no mkfifo(). Only run_erl uses it, and BEAM.com does not
 * include run_erl. */
static inline int beam_com_mkfifo(const char *path, unsigned mode)
{
    (void)path;
    (void)mode;
    return -1;
}
#define mkfifo beam_com_mkfifo

/* Defined in beam_com.c. Changes argc/argv, or runs a helper program. */
void beam_com_main(int *argcp, char ***argvp) __attribute__((__weak__));

static inline const char *beam_com_basename(const char *path)
{
    const char *base = path;
    for (; *path; path++)
        if (*path == '/' || *path == '\\')
            base = path + 1;
    return base;
}

/*
 * Programs in /zip/bin are not real files. They are names for the
 * helper programs that are linked into this executable. To start one,
 * we execute ourselves and let argv[0] select the helper.
 */
static inline const char *beam_com_exec_path(const char *path)
{
    if (path && path[0] == '/' && path[1] == 'z' && path[2] == 'i'
        && path[3] == 'p' && path[4] == '/')
        return GetProgramExecutableName();
    return path;
}

#endif /* __COSMOPOLITAN__ */
#endif /* BEAM_COM_ERTS_COSMO_H */
