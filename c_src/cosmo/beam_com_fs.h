/*
 * The sandbox of the files where the system has none (Windows): see
 * c_src/cosmo/beam_com_fs.c.
 */
#ifndef BEAM_COM_FS_H
#define BEAM_COM_FS_H

/* A path that the program can read, or read and write (write 1). A
 * directory includes all that is in it. */
void beam_com_fs_allow(const char *path, int write);

/* All the files: read (write 0) or read and write (write 1). */
void beam_com_fs_allow_all(int write);

/* The check starts. Before it, each call goes on: beam.com writes its
 * files of the start (windows_setup()) and then gives control to ERTS.
 * Only a call after beam_com_fs_policy() gets a check. */
void beam_com_fs_policy(void);
void beam_com_fs_start(void);

/* 0 when the call can go on, else -1 with errno EACCES. */
int beam_com_fs_check(const char *path, int write);

#endif
