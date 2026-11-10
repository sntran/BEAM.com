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
 * A path in /zip is not a real file, so the kernel cannot start it.
 * beam_com_exec_helper() starts it: a path /zip/bin/NAME of a helper
 * program (beam_com_zip_helper()) is a name of this executable, and
 * another program of the zip runs from a real file.
 */
static inline int beam_com_is_zip(const char *path)
{
    return path && path[0] == '/' && path[1] == 'z' && path[2] == 'i'
        && path[3] == 'p' && path[4] == '/';
}

/* Defined in beam_com_zipexec.c: 1 for /zip/bin/NAME of a helper. */
int beam_com_zip_helper(const char *path) __attribute__((__weak__));

/* The file to check with access() for a program path: this executable
 * for a helper. A program of the zip is its zip entry, which access()
 * of Cosmopolitan checks (an execute bit). */
static inline const char *beam_com_exec_path(const char *path)
{
    return beam_com_is_zip(path) && (!beam_com_zip_helper || beam_com_zip_helper(path))
        ? GetProgramExecutableName() : path;
}

/*
 * Defined in beam_com.c. Executes the program of a /zip path. A helper
 * program of /zip/bin is this file, executed again. The helper name goes
 * in the environment (BEAM_COM_PROGRAM), because argv[0] is not kept on
 * all systems: the Linux binfmt_misc APE loader gives the file path as
 * argv[0]. Another program of the zip runs from a memfd (Linux) or from
 * its copy in the cache (docs/PROGRAMS.md). When envp is NULL, the
 * current environment is used. Returns only on error.
 */
int beam_com_exec_helper(const char *path, char *const argv[],
                         char *const envp[]) __attribute__((__weak__));

/*
 * Defined in beam_com.c. On Windows, starts a port program with
 * posix_spawn() in place of erl_child_setup (docs/UPSTREAM.md, C16):
 * argv == NULL runs cmd with "sh -c". Returns 0 and the pid, or an errno
 * value.
 */
int beam_com_spawn_nt(const char *cmd, char *const argv[], char *const envp[],
                      const char *cwd, const char *wd, int in_fd, int out_fd,
                      int err_fd, int use_stdio, int *pid)
    __attribute__((__weak__));

/*
 * Defined in beam_com.c. execve() that starts an APE file with the APE
 * loader of this process when a loader runs it on Linux, so that the
 * kernel does not see the APE file (on WSL, binfmt_misc gives it to
 * Windows). Otherwise the same as execve(). Returns only on error.
 */
int beam_com_execve(const char *path, char *const argv[],
                    char *const envp[]) __attribute__((__weak__));

/*
 * Defined in beam_com.c. execle() for erl_child_setup (the shell of a
 * port of {spawn, Command}, see beam_com_child_setup.c): the same as
 * beam_com_execve() with the arguments of execle(). Returns only on
 * error.
 */
int beam_com_execle(const char *path, const char *arg, ...);

/*
 * Defined in beam_com.c. On macOS arm64, starts the helper program of the
 * /zip/bin path with posix_spawn() of libSystem (fd3 at fd 3, other and
 * fd3 closed, a new session), because the child of fork() can hang in
 * the fork handlers of libSystem (docs/UPSTREAM.md, C32). Returns the
 * pid, or -1 on the other systems, for a path that is not a helper, and
 * on an error.
 */
int beam_com_spawn_helper(const char *path, char *const argv[], int fd3,
                          int other) __attribute__((__weak__));

/*
 * Defined in beam_com.c. fork() for erl_child_setup: on macOS arm64, the
 * fork() of libSystem, with no change to the list of threads in the child
 * (docs/UPSTREAM.md, C36). On the other systems, fork().
 */
int beam_com_helper_fork(void) __attribute__((__weak__));

#ifdef __cplusplus
}
#endif

#endif /* __COSMOPOLITAN__ */
#endif /* BEAM_COM_ERTS_COSMO_H */
