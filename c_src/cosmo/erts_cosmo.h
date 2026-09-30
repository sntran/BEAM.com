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

/* The JIT is C++: the declarations below have C linkage. */
#ifdef __cplusplus
extern "C" {
#endif

/* Do not include <string.h> or <cosmo.h> here: autoconf tests that
 * undeclared builtins such as strchr() give an error. */
char *GetProgramExecutableName(void);

/*
 * Cosmopolitan's IsWindows() (libc/dce.h) without its headers: __hostos
 * has the _HOSTWINDOWS bit when the program runs on Windows. Use it where
 * the Windows emulation of Cosmopolitan differs from Unix.
 */
extern const int __hostos;
#define BEAM_COM_HOSTWINDOWS 4 /* _HOSTWINDOWS in libc/dce.h */
static inline int beam_com_is_windows(void)
{
    return (__hostos & BEAM_COM_HOSTWINDOWS) != 0;
}

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

/*
 * Defined in beam_com.c. Ends the process with an exit status. On
 * Windows, Cosmopolitan's _Exit() gives the POSIX wait status (status
 * << 8) to Windows, so a Windows program sees 256 for 1; this gives the
 * status itself. flush: run the exit handlers first (exit()), or not
 * (_exit()).
 */
void beam_com_exit(int status, int flush)
    __attribute__((__weak__, __noreturn__));

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
 * helper programs that are linked into this executable.
 */
static inline int beam_com_is_zip(const char *path)
{
    return path && path[0] == '/' && path[1] == 'z' && path[2] == 'i'
        && path[3] == 'p' && path[4] == '/';
}

/* The file to check with access() for a program path. */
static inline const char *beam_com_exec_path(const char *path)
{
    return beam_com_is_zip(path) ? GetProgramExecutableName() : path;
}

/*
 * Defined in beam_com.c. Executes this file again as the helper program
 * of the /zip/bin path. The helper name goes in the environment
 * (BEAM_COM_PROGRAM), because argv[0] is not kept on all systems: the
 * Linux binfmt_misc APE loader gives the file path as argv[0]. When envp
 * is NULL, the current environment is used. Returns only on error.
 */
int beam_com_exec_helper(const char *path, char *const argv[],
                         char *const envp[]) __attribute__((__weak__));

/*
 * Defined in beam_com.c. execve() that starts an APE file with the APE
 * loader of this process when a loader runs it on Linux, so that the
 * kernel does not see the APE file (on WSL, binfmt_misc gives it to
 * Windows). Otherwise the same as execve(). Returns only on error.
 */
int beam_com_execve(const char *path, char *const argv[],
                    char *const envp[]) __attribute__((__weak__));

#ifdef __cplusplus
}
#endif

#endif /* __COSMOPOLITAN__ */
#endif /* BEAM_COM_ERTS_COSMO_H */
