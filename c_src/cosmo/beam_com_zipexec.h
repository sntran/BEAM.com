/*
 * The programs of the zip of this file: see c_src/cosmo/beam_com_zipexec.c
 * and "priv files as real files" in docs/PROGRAMS.md.
 */
#ifndef BEAM_COM_ZIPEXEC_H
#define BEAM_COM_ZIPEXEC_H

#include <stddef.h>

/* 1 when PATH is /zip/bin/NAME of a helper program (this file, executed
 * again), else 0. The one place that decides it. */
int beam_com_zip_helper(const char *path);

/* PATH as a clean /zip path in OUT: "\" becomes "/", and the parts "",
 * "." and ".." go. 0, or EINVAL (not in /zip) or ENAMETOOLONG. */
int beam_com_zip_path(const char *path, char *out, size_t size);

/* 0 when PATH is a regular file with an execute bit, else an errno value
 * (ENOENT, or EACCES for a directory or a file with no execute bit). */
int beam_com_zip_program(const char *path);

/* The SHA-256 of the bytes of PATH, as 64 hex digits and a 0. 0, or an
 * errno value. The result for a /zip path stays in memory: the zip of a
 * process does not change (docs/UPSTREAM.md, C52). */
int beam_com_zip_hash(const char *path, char hex[65]);

/* The cache of beam.com: $BEAM_COM_CACHE, else the user cache directory,
 * as filename:basedir(user_cache, "beam.com"). 0, or an errno value. */
int beam_com_zip_cache_dir(char *out, size_t size);

/* The copy of the program PATH in the cache, CACHE/bin/SHA256/NAME, in
 * OUT. With WRITE, it makes the copy when there is none. 0, or an errno
 * value and a text for the user in MSG. */
int beam_com_zip_cache(const char *path, int write, char *out, size_t size,
                       char *msg, size_t msgsize);

/* Linux: a new memfd with the bytes of the ELF program PATH, sealed, and
 * with FD_CLOEXEC. -1 with errno: ENOEXEC for a file that is not ELF, and
 * the error of the kernel (ENOSYS, EINVAL, EACCES, EPERM). */
int beam_com_zip_memfd(const char *path);

/* Calls FN for each program of the zip in the /zip directory DIR and in
 * its subdirectories, except /zip/bin. */
void beam_com_zip_walk(const char *dir, void (*fn)(const char *path, void *arg), void *arg);

#endif
