/*
 * pthreads on JSPI: green threads on one host thread.
 *
 * Each thread is one call of the promising export jspi_thread_entry (the
 * main thread is the call of jspi_main). A thread that must wait calls
 * the suspending import jspi_suspend: JSPI keeps its stack, and the event
 * loop of the host runs the other threads. jspi_resume resolves the
 * promise of a waiting thread, which continues later.
 *
 * The engine keeps the stack of each call, but the shadow stack pointer
 * (the global __stack_pointer, for the locals in linear memory) is one
 * global: each thread has its own shadow stack, and puts its own value
 * back after each wait.
 *
 * Threads switch only when one waits (a mutex, a condition variable, a
 * join, sched_yield, a sleep, poll, select, fsync, a file of the host).
 * There is no shared memory and no atomic operation: one host thread runs
 * all of them.
 */
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* The host side is jspi_lib.js (an Emscripten JS library). */
struct __pthread;
void jspi_spawn(struct __pthread *);
int jspi_suspend(struct __pthread *, int timeout_ms);
void jspi_resume(struct __pthread *);
void jspi_yield(void);
void jspi_host_turn(void);
uintptr_t jspi_get_sp(void);
void jspi_set_sp(uintptr_t);

#define KEYS 128
#define STACK (256 * 1024)

struct __pthread {
    char *stack_top; /* first: jspi_thread_entry (sp.S) reads it */
    void *(*fn)(void *);
    void *arg, *ret;
    int done, detached;
    struct __pthread *joiner;
    char *stack;
    size_t stack_size;
    struct __pthread *next; /* in a wait queue */
    int woken;              /* resumed by a signal, not by a timeout */
    void *keys[KEYS];
    /* A snapshot: the thread returned to the host (jspi_park), and starts
     * again in resume_fn(resume_arg) (jspi_resume_all). */
    int parked;
    void *(*resume_fn)(void *);
    void *resume_arg;
    struct __pthread *all_next; /* all the threads (not joined) */
    char name[32];              /* ethread: the name of the thread */
};

static struct __pthread main_thread;
static struct __pthread *all_threads;
static struct __pthread *cur = &main_thread;
static void (*key_dtors[KEYS])(void *);
static int key_used[KEYS];

/* Wait until jspi_resume (1), or until the timeout (0). */
static int block(int timeout_ms)
{
    struct __pthread *self = cur;
    uintptr_t sp = jspi_get_sp();
    int woken;

    self->woken = 0;
    woken = jspi_suspend(self, timeout_ms);
    jspi_set_sp(sp);
    cur = self;
    return woken;
}

/* A wait of the host outside of block() (nif_wasm_host.c): the thread
 * saves its state before, and puts it back after. */
void *jspi_save(uintptr_t *sp)
{
    *sp = jspi_get_sp();
    return cur;
}

void jspi_restore(void *self, uintptr_t sp)
{
    jspi_set_sp(sp);
    cur = self;
}

static void wake(struct __pthread *t)
{
    t->woken = 1;
    jspi_resume(t);
}

struct queue { struct __pthread *head, *tail; };

static void enqueue(struct queue *q, struct __pthread *t)
{
    t->next = NULL;
    if (q->tail)
        q->tail->next = t;
    else
        q->head = t;
    q->tail = t;
}

static struct __pthread *dequeue(struct queue *q)
{
    struct __pthread *t = q->head;
    if (t) {
        q->head = t->next;
        if (!q->head)
            q->tail = NULL;
    }
    return t;
}

static void unqueue(struct queue *q, struct __pthread *t)
{
    struct __pthread **p = &q->head, *prev = NULL;
    for (; *p; prev = *p, p = &(*p)->next) {
        if (*p == t) {
            *p = t->next;
            if (q->tail == t)
                q->tail = prev;
            return;
        }
    }
}

/* --- threads ------------------------------------------------------------ */

/* Called by jspi_thread_entry (sp.S), on the stack of the new thread. */
void jspi_thread_run(struct __pthread *t)
{
    int i;

    cur = t;
    t->ret = t->fn(t->arg);
    if (t->parked) /* keep its keys: it starts again */
        return;
    for (i = 0; i < KEYS; i++)
        if (key_used[i] && key_dtors[i] && t->keys[i])
            key_dtors[i](t->keys[i]);
    t->done = 1;
    if (t->joiner)
        wake(t->joiner);
    /* The stack of a detached thread is freed by the next join or create. */
}

int pthread_create(pthread_t *out, const pthread_attr_t *attr, void *(*fn)(void *), void *arg)
{
    struct __pthread *t = calloc(1, sizeof(*t));
    size_t size = attr && attr->__u.__s[0] ? attr->__u.__s[0] : STACK;

    if (!t || !(t->stack = malloc(size))) {
        free(t);
        return EAGAIN;
    }
    t->fn = fn;
    t->arg = arg;
    /* The compiler takes the shadow stack pointer as aligned to 16 bytes
     * (it can compute sp + 10 as sp | 10), and malloc() aligns to 8. */
    t->stack_size = size;
    t->stack_top = (char *)(((uintptr_t)t->stack + size) & ~(uintptr_t)15);
    t->detached = attr && attr->__u.__s[1];
    t->all_next = all_threads;
    all_threads = t;
    *out = t;
    jspi_spawn(t);
    return 0;
}

int pthread_join(pthread_t t, void **ret)
{
    if (!t->done) {
        t->joiner = cur;
        while (!t->done)
            block(-1);
    }
    if (ret)
        *ret = t->ret;
    for (struct __pthread **p = &all_threads; *p; p = &(*p)->all_next) {
        if (*p == t) {
            *p = t->all_next;
            break;
        }
    }
    free(t->stack);
    free(t);
    return 0;
}

int pthread_detach(pthread_t t) { t->detached = 1; return 0; }
pthread_t pthread_self(void) { return cur; }
int (pthread_equal)(pthread_t a, pthread_t b) { return a == b; }
int sched_yield(void)
{
    struct __pthread *self = cur;
    uintptr_t sp = jspi_get_sp();

    jspi_yield();
    jspi_set_sp(sp);
    cur = self;
    return 0;
}

/* A turn of the event loop of the host: its I/O and timers run (the
 * scheduler of ERTS calls it after a count of reductions). sched_yield()
 * gives only a task, for the spin waits of ERTS. */
void jspi_host_yield(void)
{
    struct __pthread *self = cur;
    uintptr_t sp = jspi_get_sp();

    jspi_host_turn();
    jspi_set_sp(sp);
    cur = self;
}

void pthread_exit(void *ret)
{
    /* Not needed by the tests; ERTS threads return from their function. */
    (void)ret;
    abort();
}

int pthread_attr_init(pthread_attr_t *a) { memset(a, 0, sizeof(*a)); return 0; }
int pthread_attr_destroy(pthread_attr_t *a) { (void)a; return 0; }
int pthread_attr_setstacksize(pthread_attr_t *a, size_t s) { a->__u.__s[0] = s; return 0; }
int pthread_attr_getstacksize(const pthread_attr_t *a, size_t *s) { *s = a->__u.__s[0] ? a->__u.__s[0] : STACK; return 0; }
int pthread_attr_setdetachstate(pthread_attr_t *a, int d) { a->__u.__s[1] = d; return 0; }

/* --- mutexes ------------------------------------------------------------ */

struct mutex { struct __pthread *owner; int count, type; struct queue waiters; };
_Static_assert(sizeof(struct mutex) <= sizeof(pthread_mutex_t), "pthread_mutex_t");

int pthread_mutexattr_init(pthread_mutexattr_t *a) { a->__attr = 0; return 0; }
int pthread_mutexattr_destroy(pthread_mutexattr_t *a) { (void)a; return 0; }
int pthread_mutexattr_settype(pthread_mutexattr_t *a, int type) { a->__attr = type; return 0; }

int pthread_mutex_init(pthread_mutex_t *m, const pthread_mutexattr_t *a)
{
    struct mutex *x = (struct mutex *)m;
    memset(m, 0, sizeof(*m));
    x->type = a ? (int)a->__attr : 0;
    return 0;
}

int pthread_mutex_destroy(pthread_mutex_t *m) { (void)m; return 0; }

int pthread_mutex_trylock(pthread_mutex_t *m)
{
    struct mutex *x = (struct mutex *)m;
    if (x->owner == cur && x->type == PTHREAD_MUTEX_RECURSIVE) {
        x->count++;
        return 0;
    }
    if (x->owner)
        return EBUSY;
    x->owner = cur;
    x->count = 1;
    return 0;
}

int pthread_mutex_lock(pthread_mutex_t *m)
{
    struct mutex *x = (struct mutex *)m;
    if (x->owner == cur) {
        if (x->type == PTHREAD_MUTEX_RECURSIVE) {
            x->count++;
            return 0;
        }
        return EDEADLK;
    }
    while (x->owner) {
        enqueue(&x->waiters, cur);
        block(-1);
    }
    x->owner = cur;
    x->count = 1;
    return 0;
}

int pthread_mutex_unlock(pthread_mutex_t *m)
{
    struct mutex *x = (struct mutex *)m;
    struct __pthread *t;

    if (x->owner != cur)
        return EPERM;
    if (--x->count > 0)
        return 0;
    x->owner = NULL;
    if ((t = dequeue(&x->waiters)))
        wake(t);
    return 0;
}

/* --- condition variables ------------------------------------------------ */

struct cond { struct queue waiters; clockid_t clock; };
_Static_assert(sizeof(struct cond) <= sizeof(pthread_cond_t), "pthread_cond_t");

/* __attr: 1 for CLOCK_MONOTONIC (clockid_t is a pointer in WASI). */
int pthread_condattr_init(pthread_condattr_t *a) { a->__attr = 0; return 0; }
int pthread_condattr_destroy(pthread_condattr_t *a) { (void)a; return 0; }
int pthread_condattr_setclock(pthread_condattr_t *a, clockid_t c) { a->__attr = c == CLOCK_MONOTONIC; return 0; }

int pthread_cond_init(pthread_cond_t *c, const pthread_condattr_t *a)
{
    struct cond *x = (struct cond *)c;
    memset(c, 0, sizeof(*c));
    x->clock = a && a->__attr ? CLOCK_MONOTONIC : CLOCK_REALTIME;
    return 0;
}

int pthread_cond_destroy(pthread_cond_t *c) { (void)c; return 0; }

static int cond_wait(pthread_cond_t *c, pthread_mutex_t *m, int timeout_ms)
{
    struct cond *x = (struct cond *)c;
    struct __pthread *self = cur;
    int woken;

    enqueue(&x->waiters, self);
    pthread_mutex_unlock(m);
    block(timeout_ms);
    /* A signal can come after the timeout, before this thread runs: then
     * the signal took the thread from the queue. The flag of wake() is the
     * answer, not the result of the suspend (specs/GreenThreads.tla). */
    woken = self->woken;
    if (!woken)
        unqueue(&x->waiters, self);
    pthread_mutex_lock(m);
    return woken ? 0 : ETIMEDOUT;
}

int pthread_cond_wait(pthread_cond_t *c, pthread_mutex_t *m) { return cond_wait(c, m, -1); }

int pthread_cond_timedwait(pthread_cond_t *c, pthread_mutex_t *m, const struct timespec *abs)
{
    struct cond *x = (struct cond *)c;
    struct timespec now;
    long long ms;

    clock_gettime(x->clock, &now);
    ms = (abs->tv_sec - now.tv_sec) * 1000LL + (abs->tv_nsec - now.tv_nsec) / 1000000;
    return cond_wait(c, m, ms < 0 ? 0 : (int)ms);
}

int pthread_cond_signal(pthread_cond_t *c)
{
    struct __pthread *t = dequeue(&((struct cond *)c)->waiters);
    if (t)
        wake(t);
    return 0;
}

int pthread_cond_broadcast(pthread_cond_t *c)
{
    struct __pthread *t;
    while ((t = dequeue(&((struct cond *)c)->waiters)))
        wake(t);
    return 0;
}

/* --- keys and once ------------------------------------------------------ */

int pthread_key_create(pthread_key_t *k, void (*dtor)(void *))
{
    int i;
    for (i = 0; i < KEYS; i++) {
        if (!key_used[i]) {
            key_used[i] = 1;
            key_dtors[i] = dtor;
            *k = i;
            return 0;
        }
    }
    return EAGAIN;
}

int pthread_key_delete(pthread_key_t k) { key_used[k] = 0; return 0; }
void *pthread_getspecific(pthread_key_t k) { return cur->keys[k]; }
int pthread_setspecific(pthread_key_t k, const void *v) { cur->keys[k] = (void *)v; return 0; }

int pthread_once(pthread_once_t *o, void (*fn)(void))
{
    if (*o == 0) {
        *o = 1;
        fn();
        *o = 2;
    }
    while (*o == 1)
        sched_yield();
    return 0;
}


/* --- calls that wait ---------------------------------------------------- */

#include <poll.h>
#include <emscripten/emscripten.h>
#include <emscripten/syscalls.h>

/* The files of the host (sqlite_vfs.c): an operation of the host, which
 * the calling thread waits for (jspi_lib.js, Module.beamHost.files). */
int jspi_file_wait(int op, int id, double offset, void *buf, int n);

int jspi_host_file(int op, int id, double offset, void *buf, int n)
{
    struct __pthread *self = cur;
    uintptr_t sp = jspi_get_sp();
    int r = jspi_file_wait(op, id, offset, buf, n);
    jspi_set_sp(sp);
    cur = self;
    return r;
}

/* poll(): a check of the files, and if none is ready, a wait (it suspends
 * under JSPI) until one of them changes or the timeout; then check again.
 * The wait is ours, not Emscripten's __syscall_poll, so that its timer
 * goes through jspiSchedule (jspi_lib.js). The other threads run
 * meanwhile, so put the shadow stack pointer and the current thread back
 * after it. A zero timeout does not suspend. */
int jspi_poll_wait(struct pollfd *fds, int n, int timeout);

int poll(struct pollfd *fds, nfds_t n, int timeout)
{
    struct __pthread *self = cur;
    double end = timeout > 0 ? emscripten_get_now() + timeout : 0;
    uintptr_t sp;
    int r;

    for (;;) {
        r = __syscall_poll_nonblocking(fds, n);
        if (r != 0 || timeout == 0)
            break;
        sp = jspi_get_sp();
        r = jspi_poll_wait(fds, n, timeout);
        jspi_set_sp(sp);
        cur = self;
        if (r == 0) {
            r = __syscall_poll_nonblocking(fds, n);
            break;
        }
        if (timeout > 0) {
            timeout = (int)(end - emscripten_get_now());
            if (timeout <= 0)
                timeout = 0;
        }
    }
    if (r < 0) {
        errno = -r;
        return -1;
    }
    return r;
}

/* Under JSPI, Emscripten makes some imports of its libc suspend: fd_sync
 * (fsync) and __syscall_poll (select). Its libc does not put the shadow
 * stack pointer and the current thread back after them. A thread that
 * waits there then continues with the values of the thread that ran last.
 * Then a mutex can have an owner that is not the current thread. These
 * two functions replace the ones of its libc. wasm/erts/build.sh stops
 * when the JS of Emscripten has another import that suspends. */
#include <limits.h>
#include <sys/select.h>
#include <wasi/api.h>

/* SQLite calls it at each commit, on a dirty I/O scheduler. */
int fsync(int fd)
{
    struct __pthread *self = cur;
    uintptr_t sp = jspi_get_sp();
    __wasi_errno_t e = __wasi_fd_sync(fd);

    jspi_set_sp(sp);
    cur = self;
    if (e) {
        errno = e;
        return -1;
    }
    return 0;
}

/* select() with the poll() above. ERTS calls it in erts_milli_sleep(),
 * and the main thread of ERTS waits in it in Node.js. */
int select(int n, fd_set *rfds, fd_set *wfds, fd_set *efds, struct timeval *tv)
{
    struct pollfd *fds;
    long long ms;
    int i, k = 0, r, count = 0;

    if (n < 0 || n > FD_SETSIZE || (tv && (tv->tv_sec < 0 || tv->tv_usec < 0))) {
        errno = EINVAL;
        return -1;
    }
    if (!(fds = calloc(n ? n : 1, sizeof(*fds)))) {
        errno = ENOMEM;
        return -1;
    }
    for (i = 0; i < n; i++) {
        short events = (rfds && FD_ISSET(i, rfds) ? POLLIN : 0) |
                       (wfds && FD_ISSET(i, wfds) ? POLLOUT : 0) |
                       (efds && FD_ISSET(i, efds) ? POLLPRI : 0);
        if (events) {
            fds[k].fd = i;
            fds[k].events = events;
            k++;
        }
    }
    ms = tv ? tv->tv_sec * 1000LL + tv->tv_usec / 1000 : -1;
    r = poll(fds, k, ms > INT_MAX ? INT_MAX : (int)ms);
    for (i = 0; r > 0 && i < k; i++) {
        if (fds[i].revents & POLLNVAL) {
            errno = EBADF;
            r = -1;
            break;
        }
    }
    if (r < 0) {
        free(fds);
        return -1;
    }
    if (rfds)
        FD_ZERO(rfds);
    if (wfds)
        FD_ZERO(wfds);
    if (efds)
        FD_ZERO(efds);
    for (i = 0; i < k; i++) {
        short ev = fds[i].revents;
        if (rfds && (ev & (POLLIN | POLLHUP | POLLERR))) {
            FD_SET(fds[i].fd, rfds);
            count++;
        }
        if (wfds && (ev & (POLLOUT | POLLERR))) {
            FD_SET(fds[i].fd, wfds);
            count++;
        }
        if (efds && (ev & POLLPRI)) {
            FD_SET(fds[i].fd, efds);
            count++;
        }
    }
    free(fds);
    return count;
}

/* A sleep suspends the thread on a timer (no busy wait). */
int nanosleep(const struct timespec *req, struct timespec *rem)
{
    struct timespec now, end;
    long long ms;

    clock_gettime(CLOCK_MONOTONIC, &end);
    end.tv_sec += req->tv_sec;
    end.tv_nsec += req->tv_nsec;
    if (end.tv_nsec >= 1000000000) {
        end.tv_sec++;
        end.tv_nsec -= 1000000000;
    }
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        ms = (end.tv_sec - now.tv_sec) * 1000LL + (end.tv_nsec - now.tv_nsec + 999999) / 1000000;
        if (ms <= 0)
            break;
        block(ms > 0x7fffffff ? 0x7fffffff : (int)ms);
    }
    if (rem)
        rem->tv_sec = rem->tv_nsec = 0;
    return 0;
}

/* --- no sockets (yet) --------------------------------------------------- */

/* Emscripten emulates sockets with WebSockets (a bind starts a WebSocket
 * server in Node.js). No sockets for now: the network of the host comes
 * later. */
int socket(int domain, int type, int protocol)
{
    (void)domain; (void)type; (void)protocol;
    errno = EAFNOSUPPORT;
    return -1;
}

/* --- a snapshot of the memory ------------------------------------------- */

/* The current thread returns to the host now (it has nothing to do), and
 * starts again in fn(arg), on its own stack, with its keys: the same
 * struct __pthread. Its callers return at once (ethread: no exit cleanup). */
void jspi_park(void *(*fn)(void *), void *arg)
{
    cur->resume_fn = fn;
    cur->resume_arg = arg;
    cur->parked = 1;
}

int jspi_self_parked(void) { return cur->parked; }

/* Start the parked threads again: in this instance, or in a new instance
 * with the memory of a snapshot. The number of threads. */
EMSCRIPTEN_KEEPALIVE int jspi_resume_all(void)
{
    struct __pthread *t;
    int n = 0;

    for (t = all_threads; t; t = t->all_next) {
        if (!t->parked)
            continue;
        t->parked = 0;
        t->fn = t->resume_fn;
        t->arg = t->resume_arg;
        t->done = 0;
        jspi_spawn(t);
        n++;
    }
    return n;
}

/* The threads that run or wait (not parked, not ended): 0 when all of them
 * returned for a snapshot. */
EMSCRIPTEN_KEEPALIVE int jspi_live_threads(void)
{
    struct __pthread *t;
    int n = 0;

    for (t = all_threads; t; t = t->all_next)
        n += !t->parked && !t->done;
    return n;
}

/* Grow the memory to size bytes (a restore of a larger snapshot), through
 * Emscripten, so that its views of the memory (HEAPU8, ...) follow. */
#include <emscripten/heap.h>
EMSCRIPTEN_KEEPALIVE int jspi_snapshot_grow(size_t size)
{
    return size <= emscripten_get_heap_size() || emscripten_resize_heap(size);
}

/* A pipe, for the host that makes the files of a snapshot again: the two
 * file descriptors (read | write << 16), or -1. */
#include <unistd.h>
EMSCRIPTEN_KEEPALIVE int jspi_snapshot_pipe(void)
{
    int fds[2];
    return pipe(fds) ? -1 : fds[0] | fds[1] << 16;
}

/* ethread gives the name of its threads (for jspi_report_live). */
void jspi_set_name(const char *name)
{
    if (name) {
        strncpy(cur->name, name, sizeof(cur->name) - 1);
        cur->name[sizeof(cur->name) - 1] = 0;
    }
}

/* Print the threads that run or wait (the ones that did not park). */
EMSCRIPTEN_KEEPALIVE void jspi_report_live(void)
{
    struct __pthread *t;
    for (t = all_threads; t; t = t->all_next)
        if (!t->parked && !t->done)
            fprintf(stderr, "jspi: thread %s did not park\n", t->name[0] ? t->name : "?");
}
