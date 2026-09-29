/*
 * A SQLite VFS for exqlite in the WebAssembly runtime: the files of a
 * database are in the JavaScript host (Module.beamHost.files of
 * worker.js), which keeps their pages where it can (Deno KV in deno.js).
 * SQLite calls it through the default VFS: this one, when the host has
 * files, else the memory files of Emscripten.
 *
 * Only the main database files go to the host. A journal (and each other
 * file with a name) is a memory file of this VM (MemFile). The unix VFS
 * of Emscripten cannot open a journal, because it reads the mode of the
 * main file, and the main file is not in the memory files. A file with
 * no name (a temporary file) goes to the memory files of Emscripten.
 *
 * The host commits all the writes between two syncs at once. When the
 * database has pages, SQLite writes a transaction as one batch
 * (SQLITE_IOCAP_BATCH_ATOMIC) and keeps its journal in memory. A commit
 * that another VM made first fails with SQLITE_BUSY, and the transaction
 * does not change the database. A journal never outlives its VM, and a
 * new VM needs none, because the host keeps no partial commit.
 *
 * Each call to the host waits for its promise (jspi_host_file in
 * jspi_pthread.c): only the calling thread waits (a dirty I/O scheduler
 * for the NIF calls of exqlite).
 *
 * SQLITE_EXTRA_INIT=beam_vfs_init: sqlite3_initialize() calls it.
 */
#include <stdlib.h>
#include <string.h>
#include "sqlite3.h"

/* The operations of the host files (worker.js, HostFiles). */
enum {
    F_OPEN = 1, F_CLOSE, F_READ, F_WRITE, F_TRUNCATE, F_SYNC, F_SIZE, F_LOCK,
    F_UNLOCK, F_DELETE, F_ACCESS, F_BEGIN_BATCH, F_COMMIT_BATCH, F_ROLLBACK_BATCH
};

int jspi_host_file(int op, int id, double offset, void *buf, int n);
int jspi_host_files(void);

typedef struct {
    sqlite3_file base;
    int id; /* the file of the host */
} HostFile;

static sqlite3_vfs *orig; /* the VFS of the memory files */

/* A journal in the memory of this VM. A journal does not outlive the VM,
 * but the host keeps no partial commit, so a new VM needs no journal.
 * The thread that uses a MemFile does not wait, so no other thread
 * changes the list while it runs. */
typedef struct Mem Mem;
struct Mem {
    Mem *next;
    char *name;
    unsigned char *data;
    sqlite3_int64 size, cap;
    int refs, gone; /* gone: deleted, freed at the last close */
};

typedef struct {
    sqlite3_file base;
    Mem *mem;
    int delete_on_close;
} MemFile;

static Mem *mems;

static Mem *mem_find(const char *name)
{
    for (Mem *m = mems; m; m = m->next)
        if (!m->gone && strcmp(m->name, name) == 0)
            return m;
    return 0;
}

static void mem_free(Mem *m)
{
    for (Mem **p = &mems; *p; p = &(*p)->next)
        if (*p == m) {
            *p = m->next;
            break;
        }
    sqlite3_free(m->data);
    sqlite3_free(m->name);
    sqlite3_free(m);
}

static void mem_remove(Mem *m)
{
    m->gone = 1;
    if (m->refs == 0)
        mem_free(m);
}

static int mem_close(sqlite3_file *f)
{
    MemFile *h = (MemFile *)f;
    h->mem->refs--;
    if (h->delete_on_close)
        h->mem->gone = 1;
    if (h->mem->gone && h->mem->refs == 0)
        mem_free(h->mem);
    return SQLITE_OK;
}

static int mem_read(sqlite3_file *f, void *buf, int n, sqlite3_int64 off)
{
    Mem *m = ((MemFile *)f)->mem;
    sqlite3_int64 got = off >= m->size ? 0 : m->size - off < n ? m->size - off : n;
    if (got > 0)
        memcpy(buf, m->data + off, got);
    if (got < n) {
        memset((char *)buf + got, 0, n - got);
        return SQLITE_IOERR_SHORT_READ;
    }
    return SQLITE_OK;
}

static int mem_grow(Mem *m, sqlite3_int64 size)
{
    if (size > m->cap) {
        sqlite3_int64 cap = m->cap ? m->cap : 8192;
        while (cap < size)
            cap *= 2;
        unsigned char *d = sqlite3_realloc64(m->data, cap);
        if (!d)
            return SQLITE_IOERR_NOMEM;
        m->data = d;
        m->cap = cap;
    }
    if (size > m->size) {
        memset(m->data + m->size, 0, size - m->size);
        m->size = size;
    }
    return SQLITE_OK;
}

static int mem_write(sqlite3_file *f, const void *buf, int n, sqlite3_int64 off)
{
    Mem *m = ((MemFile *)f)->mem;
    int rc = mem_grow(m, off + n);
    if (rc == SQLITE_OK)
        memcpy(m->data + off, buf, n);
    return rc;
}

static int mem_truncate(sqlite3_file *f, sqlite3_int64 size)
{
    Mem *m = ((MemFile *)f)->mem;
    if (size < m->size)
        m->size = size;
    return SQLITE_OK;
}

static int mem_sync(sqlite3_file *f, int flags)
{
    (void)f;
    (void)flags;
    return SQLITE_OK;
}

static int mem_size(sqlite3_file *f, sqlite3_int64 *size)
{
    *size = ((MemFile *)f)->mem->size;
    return SQLITE_OK;
}

static int mem_lock(sqlite3_file *f, int level)
{
    (void)f;
    (void)level;
    return SQLITE_OK;
}

static int mem_check_reserved(sqlite3_file *f, int *out)
{
    (void)f;
    *out = 0;
    return SQLITE_OK;
}

static int mem_file_control(sqlite3_file *f, int op, void *arg)
{
    (void)f;
    (void)op;
    (void)arg;
    return SQLITE_NOTFOUND;
}

static int mem_sector_size(sqlite3_file *f)
{
    (void)f;
    return 4096;
}

static int mem_device(sqlite3_file *f)
{
    (void)f;
    return SQLITE_IOCAP_POWERSAFE_OVERWRITE | SQLITE_IOCAP_SAFE_APPEND | SQLITE_IOCAP_SEQUENTIAL;
}

static const sqlite3_io_methods mem_methods = {
    1, mem_close, mem_read, mem_write, mem_truncate, mem_sync, mem_size,
    mem_lock, mem_lock, mem_check_reserved, mem_file_control,
    mem_sector_size, mem_device, 0, 0, 0, 0, 0, 0
};

static int mem_open(const char *name, sqlite3_file *f, int flags, int *out)
{
    MemFile *h = (MemFile *)f;
    Mem *m = mem_find(name);
    if (!m) {
        if (!(flags & SQLITE_OPEN_CREATE))
            return SQLITE_CANTOPEN;
        m = sqlite3_malloc(sizeof *m);
        if (!m)
            return SQLITE_NOMEM;
        memset(m, 0, sizeof *m);
        m->name = sqlite3_mprintf("%s", name);
        if (!m->name) {
            sqlite3_free(m);
            return SQLITE_NOMEM;
        }
        m->next = mems;
        mems = m;
    }
    m->refs++;
    h->mem = m;
    h->delete_on_close = (flags & SQLITE_OPEN_DELETEONCLOSE) != 0;
    h->base.pMethods = &mem_methods;
    if (out)
        *out = flags;
    return SQLITE_OK;
}

static int host_close(sqlite3_file *f)
{
    jspi_host_file(F_CLOSE, ((HostFile *)f)->id, 0, 0, 0);
    return SQLITE_OK;
}

static int host_read(sqlite3_file *f, void *buf, int n, sqlite3_int64 off)
{
    int got = jspi_host_file(F_READ, ((HostFile *)f)->id, (double)off, buf, n);
    if (got < 0)
        return SQLITE_IOERR_READ;
    if (got < n) {
        memset((char *)buf + got, 0, n - got);
        return SQLITE_IOERR_SHORT_READ;
    }
    return SQLITE_OK;
}

static int host_write(sqlite3_file *f, const void *buf, int n, sqlite3_int64 off)
{
    return jspi_host_file(F_WRITE, ((HostFile *)f)->id, (double)off, (void *)buf, n) == 0
        ? SQLITE_OK : SQLITE_IOERR_WRITE;
}

static int host_truncate(sqlite3_file *f, sqlite3_int64 size)
{
    return jspi_host_file(F_TRUNCATE, ((HostFile *)f)->id, (double)size, 0, 0) == 0
        ? SQLITE_OK : SQLITE_IOERR_TRUNCATE;
}

/* A commit of the writes since the last one. The host gives an error
 * code of SQLite (SQLITE_BUSY when another VM committed first). */
static int host_sync(sqlite3_file *f, int flags)
{
    (void)flags;
    return jspi_host_file(F_SYNC, ((HostFile *)f)->id, 0, 0, 0);
}

static int host_size(sqlite3_file *f, sqlite3_int64 *size)
{
    double d = 0;
    if (jspi_host_file(F_SIZE, ((HostFile *)f)->id, 0, &d, sizeof d) != 0)
        return SQLITE_IOERR_FSTAT;
    *size = (sqlite3_int64)d;
    return SQLITE_OK;
}

/* A shared lock starts a read: the host takes the last version of the
 * database. The other levels are the business of the commit. */
static int host_lock(sqlite3_file *f, int level)
{
    return jspi_host_file(F_LOCK, ((HostFile *)f)->id, 0, 0, level);
}

static int host_unlock(sqlite3_file *f, int level)
{
    return jspi_host_file(F_UNLOCK, ((HostFile *)f)->id, 0, 0, level);
}

static int host_check_reserved(sqlite3_file *f, int *out)
{
    (void)f;
    *out = 0;
    return SQLITE_OK;
}

static int host_file_control(sqlite3_file *f, int op, void *arg)
{
    int id = ((HostFile *)f)->id;
    (void)arg;
    switch (op) {
    case SQLITE_FCNTL_BEGIN_ATOMIC_WRITE:
        return jspi_host_file(F_BEGIN_BATCH, id, 0, 0, 0);
    case SQLITE_FCNTL_COMMIT_ATOMIC_WRITE:
        return jspi_host_file(F_COMMIT_BATCH, id, 0, 0, 0);
    case SQLITE_FCNTL_ROLLBACK_ATOMIC_WRITE:
        return jspi_host_file(F_ROLLBACK_BATCH, id, 0, 0, 0);
    }
    return SQLITE_NOTFOUND;
}

static int host_sector_size(sqlite3_file *f)
{
    (void)f;
    return 4096;
}

static int host_device(sqlite3_file *f)
{
    (void)f;
    return SQLITE_IOCAP_BATCH_ATOMIC | SQLITE_IOCAP_POWERSAFE_OVERWRITE
        | SQLITE_IOCAP_SAFE_APPEND | SQLITE_IOCAP_SEQUENTIAL;
}

/* Version 1: no shared memory, so no WAL (journal_mode=WAL keeps the
 * mode that there is). */
static const sqlite3_io_methods host_methods = {
    1, host_close, host_read, host_write, host_truncate, host_sync, host_size,
    host_lock, host_unlock, host_check_reserved, host_file_control,
    host_sector_size, host_device, 0, 0, 0, 0, 0, 0
};

static int is_main(const char *name)
{
    size_t n = name ? strlen(name) : 0;
    static const char *const sfx[] = {"-journal", "-wal", "-shm"};
    for (size_t i = 0; i < 3; i++) {
        size_t m = strlen(sfx[i]);
        if (n >= m && strcmp(name + n - m, sfx[i]) == 0)
            return 0;
    }
    return n > 0;
}

static int host_open(sqlite3_vfs *vfs, const char *name, sqlite3_file *f, int flags, int *out)
{
    HostFile *h = (HostFile *)f;
    int id;

    (void)vfs;
    if (!name)
        return orig->xOpen(orig, name, f, flags, out);
    if (!(flags & SQLITE_OPEN_MAIN_DB) || !is_main(name))
        return mem_open(name, f, flags, out);
    id = jspi_host_file(F_OPEN, 0, 0, (void *)name, flags);
    if (id <= 0)
        return SQLITE_CANTOPEN;
    h->id = id;
    h->base.pMethods = &host_methods;
    if (out)
        *out = flags;
    return SQLITE_OK;
}

static int host_delete(sqlite3_vfs *vfs, const char *name, int sync)
{
    (void)vfs;
    if (!is_main(name)) {
        Mem *m = mem_find(name);
        (void)sync;
        if (!m)
            return SQLITE_IOERR_DELETE_NOENT;
        mem_remove(m);
        return SQLITE_OK;
    }
    return jspi_host_file(F_DELETE, 0, 0, (void *)name, 0) == 0 ? SQLITE_OK : SQLITE_IOERR_DELETE;
}

static int host_access(sqlite3_vfs *vfs, const char *name, int flags, int *out)
{
    (void)vfs;
    if (!is_main(name)) {
        *out = mem_find(name) != 0;
        return SQLITE_OK;
    }
    *out = jspi_host_file(F_ACCESS, 0, 0, (void *)name, flags) > 0;
    return SQLITE_OK;
}

static int host_full_pathname(sqlite3_vfs *vfs, const char *name, int n, char *out)
{
    (void)vfs;
    return orig->xFullPathname(orig, name, n, out);
}

static int host_randomness(sqlite3_vfs *vfs, int n, char *out)
{
    (void)vfs;
    return orig->xRandomness(orig, n, out);
}

static int host_sleep(sqlite3_vfs *vfs, int us)
{
    (void)vfs;
    return orig->xSleep(orig, us);
}

static int host_current_time(sqlite3_vfs *vfs, double *t)
{
    (void)vfs;
    return orig->xCurrentTime(orig, t);
}

static int host_last_error(sqlite3_vfs *vfs, int n, char *out)
{
    (void)vfs;
    return orig->xGetLastError ? orig->xGetLastError(orig, n, out) : 0;
}

static sqlite3_vfs host_vfs = {
    1, 0, 512, 0, "beam", 0,
    host_open, host_delete, host_access, host_full_pathname,
    0, 0, 0, 0, host_randomness, host_sleep, host_current_time, host_last_error
};

/* SQLITE_EXTRA_INIT: sqlite3_initialize() calls it with a null pointer. */
int beam_vfs_init(const char *unused)
{
    (void)unused;
    if (orig || !jspi_host_files())
        return SQLITE_OK;
    orig = sqlite3_vfs_find(0);
    if (!orig)
        return SQLITE_ERROR;
    host_vfs.szOsFile = orig->szOsFile;
    if (host_vfs.szOsFile < (int)sizeof(HostFile))
        host_vfs.szOsFile = sizeof(HostFile);
    if (host_vfs.szOsFile < (int)sizeof(MemFile))
        host_vfs.szOsFile = sizeof(MemFile);
    host_vfs.mxPathname = orig->mxPathname;
    return sqlite3_vfs_register(&host_vfs, 1);
}
